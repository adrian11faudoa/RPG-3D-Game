#!/bin/bash
###############################################################################
# Veilborn Game Server — EC2 User Data Bootstrap Script
# Runs on every new instance launched by the ASG.
# Template variables filled by Terraform.
###############################################################################
set -euo pipefail
exec > >(tee /var/log/veilborn-bootstrap.log | logger -t veilborn-bootstrap) 2>&1

echo "=== Veilborn Bootstrap Starting: $(date) ==="

ENVIRONMENT="${environment}"
AWS_REGION="${aws_region}"
S3_CHUNKS="${s3_chunks_bucket}"
S3_MODS="${s3_mods_bucket}"
DB_SECRET_ARN="${db_secret_arn}"
REDIS_ENDPOINT="${redis_endpoint}"
GAME_PORT="${game_port}"
WORLD_SEED="${world_seed}"
MAX_PLAYERS="${max_players}"
SERVER_REGION="${server_region}"
LOG_GROUP="${log_group}"
INSTALL_DIR="/opt/veilborn"
DATA_DIR="/var/lib/veilborn"
LOG_DIR="/var/log/veilborn"

###############################################################################
# 1. SYSTEM SETUP
###############################################################################
echo "--- System setup ---"
dnf update -y -q
dnf install -y \
  docker \
  awscli \
  amazon-cloudwatch-agent \
  jq \
  htop \
  iotop \
  net-tools \
  unzip

# Enable and start Docker
systemctl enable --now docker
usermod -aG docker ec2-user

# Create directories
mkdir -p "$INSTALL_DIR" "$DATA_DIR/chunks" "$DATA_DIR/mods" "$LOG_DIR"
chown -R ec2-user:ec2-user "$DATA_DIR" "$LOG_DIR"

###############################################################################
# 2. CLOUDWATCH AGENT CONFIG
###############################################################################
echo "--- CloudWatch Agent setup ---"
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << EOF
{
  "agent": {
    "metrics_collection_interval": 30,
    "run_as_user": "root"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/veilborn/server.log",
            "log_group_name": "$LOG_GROUP",
            "log_stream_name": "{instance_id}/server",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/veilborn/error.log",
            "log_group_name": "$LOG_GROUP",
            "log_stream_name": "{instance_id}/error",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/veilborn-bootstrap.log",
            "log_group_name": "$LOG_GROUP",
            "log_stream_name": "{instance_id}/bootstrap",
            "timezone": "UTC"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "Veilborn/GameServer",
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
        "metrics_collection_interval": 30
      },
      "disk": {
        "measurement": ["used_percent", "disk_used", "disk_free"],
        "resources": ["/", "/var/lib/veilborn"],
        "metrics_collection_interval": 60
      },
      "mem": {
        "measurement": ["mem_used_percent", "mem_available"],
        "metrics_collection_interval": 30
      },
      "net": {
        "measurement": ["bytes_sent", "bytes_recv", "packets_sent", "packets_recv"],
        "resources": ["eth0"],
        "metrics_collection_interval": 30
      }
    },
    "append_dimensions": {
      "InstanceId": "$${aws:InstanceId}",
      "Environment": "$ENVIRONMENT"
    }
  }
}
EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s

###############################################################################
# 3. FETCH DB CREDENTIALS FROM SECRETS MANAGER
###############################################################################
echo "--- Fetching DB credentials ---"
DB_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "$DB_SECRET_ARN" \
  --region "$AWS_REGION" \
  --query SecretString \
  --output text)

DB_HOST=$(echo "$DB_SECRET" | jq -r '.host')
DB_PORT=$(echo "$DB_SECRET" | jq -r '.port')
DB_NAME=$(echo "$DB_SECRET" | jq -r '.dbname')
DB_USER=$(echo "$DB_SECRET" | jq -r '.username')
DB_PASS=$(echo "$DB_SECRET" | jq -r '.password')

# Build DSN for the game server
DATABASE_URL="postgres://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=require"

###############################################################################
# 4. PULL GAME SERVER DOCKER IMAGE
###############################################################################
echo "--- Pulling game server Docker image ---"
# Login to ECR
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="$AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com"
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

GAME_IMAGE="$ECR_REGISTRY/veilborn-server:latest"
docker pull "$GAME_IMAGE"

###############################################################################
# 5. SYNC MODS FROM S3
###############################################################################
echo "--- Syncing mods from S3 ---"
aws s3 sync "s3://$S3_MODS/mods/" "$DATA_DIR/mods/" \
  --region "$AWS_REGION" \
  --quiet \
  --no-progress

###############################################################################
# 6. GET INSTANCE METADATA (for instance-specific config)
###############################################################################
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)

echo "Instance: $INSTANCE_ID | IP: $PRIVATE_IP | AZ: $AZ"

###############################################################################
# 7. WRITE SERVER CONFIG
###############################################################################
cat > "$INSTALL_DIR/server.env" << EOF
VEILBORN_ENV=$ENVIRONMENT
VEILBORN_PORT=$GAME_PORT
VEILBORN_MAX_PLAYERS=$MAX_PLAYERS
VEILBORN_WORLD_SEED=$WORLD_SEED
VEILBORN_REGION=$SERVER_REGION
VEILBORN_INSTANCE_ID=$INSTANCE_ID
VEILBORN_PRIVATE_IP=$PRIVATE_IP
VEILBORN_DATABASE_URL=$DATABASE_URL
VEILBORN_REDIS_URL=rediss://$REDIS_ENDPOINT:6379
VEILBORN_S3_CHUNKS=$S3_CHUNKS
VEILBORN_AWS_REGION=$AWS_REGION
VEILBORN_LOG_DIR=$LOG_DIR
EOF
chmod 600 "$INSTALL_DIR/server.env"

###############################################################################
# 8. CREATE SYSTEMD SERVICE
###############################################################################
cat > /etc/systemd/system/veilborn-server.service << EOF
[Unit]
Description=Veilborn Game Server
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=10
StartLimitInterval=120
StartLimitBurst=5

EnvironmentFile=$INSTALL_DIR/server.env

ExecStartPre=-/usr/bin/docker stop veilborn-server 2>/dev/null
ExecStartPre=-/usr/bin/docker rm veilborn-server 2>/dev/null
ExecStart=/usr/bin/docker run \
  --name veilborn-server \
  --rm \
  --network host \
  --env-file $INSTALL_DIR/server.env \
  -v $DATA_DIR:/data \
  -v $LOG_DIR:/logs \
  --ulimit nofile=65535:65535 \
  --memory="6g" \
  --cpus="3.5" \
  $GAME_IMAGE \
  --headless \
  --port \$VEILBORN_PORT \
  --max-players \$VEILBORN_MAX_PLAYERS \
  --world-seed \$VEILBORN_WORLD_SEED \
  --region "\$VEILBORN_REGION" \
  --data-dir /data \
  --log-dir /logs

ExecStop=/usr/bin/docker stop -t 30 veilborn-server

# Graceful shutdown: flush world state before stopping
ExecStopPost=/opt/veilborn/scripts/graceful_shutdown.sh

StandardOutput=append:$LOG_DIR/server.log
StandardError=append:$LOG_DIR/error.log

# Security hardening
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=$DATA_DIR $LOG_DIR

[Install]
WantedBy=multi-user.target
EOF

###############################################################################
# 9. CHUNK SYNC SERVICE (syncs local chunks to/from S3)
###############################################################################
cat > /etc/systemd/system/veilborn-chunk-sync.service << EOF
[Unit]
Description=Veilborn Chunk Sync to S3
After=veilborn-server.service

[Service]
Type=oneshot
ExecStart=/opt/veilborn/scripts/sync_chunks.sh
EOF

cat > /etc/systemd/system/veilborn-chunk-sync.timer << EOF
[Unit]
Description=Sync chunks to S3 every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=veilborn-chunk-sync.service

[Install]
WantedBy=timers.target
EOF

###############################################################################
# 10. CREATE HELPER SCRIPTS
###############################################################################
mkdir -p /opt/veilborn/scripts

# Graceful shutdown — flush world state before instance termination
cat > /opt/veilborn/scripts/graceful_shutdown.sh << 'SCRIPT'
#!/bin/bash
echo "Graceful shutdown: syncing chunks to S3..."
aws s3 sync /var/lib/veilborn/chunks/ "s3://$VEILBORN_S3_CHUNKS/chunks/" \
  --region "$VEILBORN_AWS_REGION" \
  --quiet
echo "Chunk sync complete."
SCRIPT

# Chunk sync script
cat > /opt/veilborn/scripts/sync_chunks.sh << 'SCRIPT'
#!/bin/bash
source /opt/veilborn/server.env
aws s3 sync /var/lib/veilborn/chunks/ "s3://$VEILBORN_S3_CHUNKS/chunks/" \
  --region "$VEILBORN_AWS_REGION" \
  --quiet \
  --no-progress
SCRIPT

# Status script
cat > /opt/veilborn/scripts/status.sh << 'SCRIPT'
#!/bin/bash
echo "=== Veilborn Server Status ==="
systemctl status veilborn-server --no-pager
echo ""
echo "=== Docker Container ==="
docker ps --filter name=veilborn-server --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "=== Recent Logs ==="
tail -30 /var/log/veilborn/server.log
SCRIPT

# Push custom metrics to CloudWatch
cat > /opt/veilborn/scripts/push_metrics.sh << 'SCRIPT'
#!/bin/bash
# Called by the game server itself via exec, or run on a cron
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
PLAYER_COUNT=${1:-0}

aws cloudwatch put-metric-data \
  --namespace "Veilborn/GameServer" \
  --metric-data "[
    {\"MetricName\":\"ActivePlayerCount\",\"Value\":$PLAYER_COUNT,\"Unit\":\"Count\",\"Dimensions\":[{\"Name\":\"InstanceId\",\"Value\":\"$INSTANCE_ID\"}]},
    {\"MetricName\":\"MemoryUsedPercent\",\"Value\":$(free | awk '/Mem:/{printf \"%.1f\", $3/$2*100}'),\"Unit\":\"Percent\",\"Dimensions\":[{\"Name\":\"InstanceId\",\"Value\":\"$INSTANCE_ID\"}]}
  ]" \
  --region "$REGION"
SCRIPT

chmod +x /opt/veilborn/scripts/*.sh

###############################################################################
# 11. CONFIGURE LIFECYCLE HOOK (drain before ASG termination)
###############################################################################
# Register a lifecycle action — the game server sends CONTINUE when drained
cat > /etc/systemd/system/veilborn-lifecycle.service << EOF
[Unit]
Description=Veilborn ASG Lifecycle Hook Handler

[Service]
Type=oneshot
ExecStart=/opt/veilborn/scripts/lifecycle_hook.sh
EOF

cat > /opt/veilborn/scripts/lifecycle_hook.sh << 'SCRIPT'
#!/bin/bash
# Triggered by ASG termination hook via EventBridge
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

echo "Lifecycle hook: draining instance $INSTANCE_ID"

# Signal game server to stop accepting new connections
docker exec veilborn-server \
  godot --script /server/drain.gd --instance-id "$INSTANCE_ID" 2>/dev/null || true

# Wait up to 90 seconds for players to migrate
sleep 90

# Sync chunks before death
/opt/veilborn/scripts/sync_chunks.sh

# Complete the lifecycle action
ASG_NAME=$(aws ec2 describe-tags \
  --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=aws:autoscaling:groupName" \
  --query "Tags[0].Value" --output text --region "$REGION")

aws autoscaling complete-lifecycle-action \
  --lifecycle-action-result CONTINUE \
  --lifecycle-hook-name veilborn-termination-hook \
  --auto-scaling-group-name "$ASG_NAME" \
  --instance-id "$INSTANCE_ID" \
  --region "$REGION"

echo "Lifecycle hook: complete"
SCRIPT
chmod +x /opt/veilborn/scripts/lifecycle_hook.sh

###############################################################################
# 12. START SERVICES
###############################################################################
echo "--- Starting services ---"
systemctl daemon-reload
systemctl enable veilborn-server
systemctl enable veilborn-chunk-sync.timer
systemctl start veilborn-chunk-sync.timer
systemctl start veilborn-server

echo "=== Bootstrap Complete: $(date) ==="
echo "Game server starting on port $GAME_PORT"
echo "Connect: $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):$GAME_PORT"
