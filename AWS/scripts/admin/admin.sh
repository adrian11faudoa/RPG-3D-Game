#!/bin/bash
###############################################################################
# Veilborn AWS — Admin Toolkit
#
# Usage:
#   ./admin.sh <command> [args]
#
# Commands:
#   status              Show all running instances and player counts
#   players             List online players
#   kick <username>     Kick a player from all servers
#   ban <username>      Ban a player
#   unban <username>    Unban a player
#   give <user> <item>  Give an item to a player
#   broadcast <msg>     Send a message to all online players
#   backup              Trigger manual world backup to S3
#   scale <n>           Set desired instance count
#   logs [instance]     Tail live server logs
#   ssh [instance]      SSH into a game server instance
#   db                  Connect to the PostgreSQL database
###############################################################################
set -euo pipefail

ENVIRONMENT="${VEILBORN_ENV:-prod}"
AWS_REGION="${AWS_REGION:-us-east-1}"
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/terraform" && pwd)"

# Get infrastructure info from Terraform outputs (cached for 5 minutes)
CACHE_FILE="/tmp/veilborn-infra-cache-$ENVIRONMENT"
if [[ ! -f "$CACHE_FILE" ]] || [[ $(find "$CACHE_FILE" -mmin +5 2>/dev/null | wc -l) -gt 0 ]]; then
  if [[ -d "$INFRA_DIR" ]]; then
    terraform -chdir="$INFRA_DIR" output -json > "$CACHE_FILE" 2>/dev/null || echo '{}' > "$CACHE_FILE"
  else
    echo '{}' > "$CACHE_FILE"
  fi
fi

get_output() {
  local key="$1"
  jq -r ".${key}.value // \"\"" "$CACHE_FILE" 2>/dev/null || echo ""
}

ASG_NAME=$(get_output "asg_name")
LOG_GROUP=$(get_output "log_group_name")
DB_SECRET_ARN=$(get_output "db_secret_arn")
S3_CHUNKS=$(get_output "s3_chunks_bucket")
S3_BACKUPS=$(get_output "s3_backups_bucket")
NLB_DNS=$(get_output "nlb_dns_name")

# ─── Helper: Get running instances ────────────────────────────────────────────
get_instances() {
  aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
      "Name=tag:aws:autoscaling:groupName,Values=$ASG_NAME" \
      "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress,PrivateIpAddress,LaunchTime]' \
    --output json
}

# ─── Helper: Call admin API on all instances ──────────────────────────────────
admin_api() {
  local endpoint="$1"
  local method="${2:-GET}"
  local body="${3:-}"
  
  local instances
  instances=$(get_instances)
  
  echo "$instances" | jq -r '.[] | .[1]' | while read -r ip; do
    if [[ -z "$ip" || "$ip" == "null" ]]; then
      continue
    fi
    echo "→ $ip:"
    if [[ -n "$body" ]]; then
      curl -s -X "$method" \
        -H "Content-Type: application/json" \
        -H "X-Admin-Token: $(get_admin_token)" \
        -d "$body" \
        "http://$ip:8080/admin/$endpoint" | jq . 2>/dev/null || echo "No response"
    else
      curl -s -X "$method" \
        -H "X-Admin-Token: $(get_admin_token)" \
        "http://$ip:8080/admin/$endpoint" | jq . 2>/dev/null || echo "No response"
    fi
  done
}

get_admin_token() {
  # Fetch admin token from SSM Parameter Store
  aws ssm get-parameter \
    --name "/veilborn/$ENVIRONMENT/admin_token" \
    --with-decryption \
    --region "$AWS_REGION" \
    --query 'Parameter.Value' \
    --output text 2>/dev/null || echo ""
}

# ─── Commands ─────────────────────────────────────────────────────────────────
CMD="${1:-help}"

case "$CMD" in

  status)
    echo "=== Veilborn Server Status ($ENVIRONMENT) ==="
    echo ""
    echo "NLB: $NLB_DNS"
    echo ""
    echo "--- Running Instances ---"
    get_instances | jq -r '.[] | "  \(.[0])  \(.[1])  launched: \(.[3])"'
    echo ""
    echo "--- ASG Status ---"
    aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --region "$AWS_REGION" \
      --query 'AutoScalingGroups[0].{Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,Running:Instances[?LifecycleState==`InService`]|length(@)}' \
      --output table
    echo ""
    echo "--- Online Players (from admin API) ---"
    admin_api "players/count"
    ;;

  players)
    echo "=== Online Players ==="
    admin_api "players/list"
    ;;

  kick)
    USERNAME="${2:-}"
    if [[ -z "$USERNAME" ]]; then echo "Usage: $0 kick <username>"; exit 1; fi
    echo "Kicking player: $USERNAME"
    admin_api "players/kick" "POST" "{\"username\":\"$USERNAME\"}"
    ;;

  ban)
    USERNAME="${2:-}"
    REASON="${3:-Admin ban}"
    if [[ -z "$USERNAME" ]]; then echo "Usage: $0 ban <username> [reason]"; exit 1; fi
    echo "Banning player: $USERNAME ($REASON)"
    # Update DB directly
    DB_SECRET=$(aws secretsmanager get-secret-value \
      --secret-id "$DB_SECRET_ARN" \
      --region "$AWS_REGION" \
      --query SecretString --output text)
    DB_URL="postgres://$(echo "$DB_SECRET" | jq -r '.username'):$(echo "$DB_SECRET" | jq -r '.password')@$(echo "$DB_SECRET" | jq -r '.host'):$(echo "$DB_SECRET" | jq -r '.port')/$(echo "$DB_SECRET" | jq -r '.dbname')"
    psql "$DB_URL" -c "UPDATE players SET is_banned=TRUE, ban_reason='$REASON' WHERE username='$USERNAME'"
    # Also kick immediately
    admin_api "players/kick" "POST" "{\"username\":\"$USERNAME\"}"
    echo "✓ Banned and kicked: $USERNAME"
    ;;

  unban)
    USERNAME="${2:-}"
    if [[ -z "$USERNAME" ]]; then echo "Usage: $0 unban <username>"; exit 1; fi
    DB_SECRET=$(aws secretsmanager get-secret-value \
      --secret-id "$DB_SECRET_ARN" \
      --region "$AWS_REGION" \
      --query SecretString --output text)
    DB_URL="postgres://$(echo "$DB_SECRET" | jq -r '.username'):$(echo "$DB_SECRET" | jq -r '.password')@$(echo "$DB_SECRET" | jq -r '.host'):$(echo "$DB_SECRET" | jq -r '.port')/$(echo "$DB_SECRET" | jq -r '.dbname')"
    psql "$DB_URL" -c "UPDATE players SET is_banned=FALSE, ban_reason=NULL WHERE username='$USERNAME'"
    echo "✓ Unbanned: $USERNAME"
    ;;

  give)
    USERNAME="${2:-}"
    ITEM="${3:-}"
    AMOUNT="${4:-1}"
    if [[ -z "$USERNAME" || -z "$ITEM" ]]; then
      echo "Usage: $0 give <username> <item_id> [amount]"
      exit 1
    fi
    echo "Giving $AMOUNT x $ITEM to $USERNAME"
    admin_api "players/give" "POST" "{\"username\":\"$USERNAME\",\"item_id\":\"$ITEM\",\"amount\":$AMOUNT}"
    ;;

  broadcast)
    MESSAGE="${2:-}"
    if [[ -z "$MESSAGE" ]]; then echo "Usage: $0 broadcast <message>"; exit 1; fi
    echo "Broadcasting: $MESSAGE"
    admin_api "chat/broadcast" "POST" "{\"message\":\"$MESSAGE\"}"
    ;;

  backup)
    echo "=== Manual World Backup ==="
    TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
    BACKUP_KEY="manual/world_backup_$TIMESTAMP"
    
    echo "Syncing chunks to S3 backup..."
    # Trigger chunk flush on all servers
    admin_api "world/flush" "POST"
    sleep 5
    
    # Snapshot S3 chunks to backup bucket
    aws s3 cp \
      "s3://$S3_CHUNKS/" \
      "s3://$S3_BACKUPS/$BACKUP_KEY/" \
      --recursive \
      --region "$AWS_REGION"
    
    # RDS snapshot
    DB_INSTANCE="veilborn-$ENVIRONMENT"
    SNAPSHOT_ID="veilborn-manual-$TIMESTAMP"
    aws rds create-db-snapshot \
      --db-instance-identifier "$DB_INSTANCE" \
      --db-snapshot-identifier "$SNAPSHOT_ID" \
      --region "$AWS_REGION" \
      --query 'DBSnapshot.{Id:DBSnapshotIdentifier,Status:Status}' \
      --output table
    
    echo "✓ Backup complete: s3://$S3_BACKUPS/$BACKUP_KEY"
    echo "✓ RDS Snapshot: $SNAPSHOT_ID"
    ;;

  scale)
    COUNT="${2:-}"
    if [[ -z "$COUNT" ]]; then echo "Usage: $0 scale <instance_count>"; exit 1; fi
    echo "Scaling $ASG_NAME to $COUNT instances..."
    aws autoscaling set-desired-capacity \
      --auto-scaling-group-name "$ASG_NAME" \
      --desired-capacity "$COUNT" \
      --region "$AWS_REGION"
    echo "✓ Desired capacity set to $COUNT"
    ;;

  logs)
    INSTANCE="${2:-}"
    if [[ -z "$INSTANCE" ]]; then
      # Tail CloudWatch logs from all instances
      echo "Tailing CloudWatch logs from $LOG_GROUP..."
      aws logs tail "$LOG_GROUP" \
        --follow \
        --format short \
        --region "$AWS_REGION"
    else
      # SSH and tail local logs
      IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
      ssh -i ~/.ssh/veilborn.pem ec2-user@"$IP" \
        "tail -f /var/log/veilborn/server.log"
    fi
    ;;

  ssh)
    INSTANCE="${2:-}"
    if [[ -z "$INSTANCE" ]]; then
      # Pick first running instance
      INSTANCE=$(aws autoscaling describe-auto-scaling-instances \
        --region "$AWS_REGION" \
        --query "AutoScalingInstances[?AutoScalingGroupName=='$ASG_NAME'&&LifecycleState=='InService'].InstanceId" \
        --output text | awk '{print $1}')
    fi
    IP=$(aws ec2 describe-instances \
      --instance-ids "$INSTANCE" \
      --region "$AWS_REGION" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' \
      --output text)
    echo "SSHing to $INSTANCE ($IP)..."
    ssh -i ~/.ssh/veilborn.pem ec2-user@"$IP"
    ;;

  db)
    echo "Connecting to PostgreSQL ($ENVIRONMENT)..."
    DB_SECRET=$(aws secretsmanager get-secret-value \
      --secret-id "$DB_SECRET_ARN" \
      --region "$AWS_REGION" \
      --query SecretString --output text)
    PGPASSWORD=$(echo "$DB_SECRET" | jq -r '.password') \
    psql \
      --host="$(echo "$DB_SECRET" | jq -r '.host')" \
      --port="$(echo "$DB_SECRET" | jq -r '.port')" \
      --username="$(echo "$DB_SECRET" | jq -r '.username')" \
      --dbname="$(echo "$DB_SECRET" | jq -r '.dbname')" \
      --set=sslmode=require
    ;;

  help|*)
    echo ""
    echo "Veilborn Admin Toolkit"
    echo ""
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  status              Show all running instances"
    echo "  players             List online players"
    echo "  kick <username>     Kick a player"
    echo "  ban <username>      Ban a player"
    echo "  unban <username>    Unban a player"
    echo "  give <user> <item>  Give item to player"
    echo "  broadcast <msg>     Broadcast message"
    echo "  backup              Manual world backup"
    echo "  scale <n>           Set instance count"
    echo "  logs [instance-id]  Tail server logs"
    echo "  ssh [instance-id]   SSH into server"
    echo "  db                  Connect to database"
    echo ""
    ;;
esac
