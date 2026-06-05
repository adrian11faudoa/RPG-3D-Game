# Veilborn RPG — AWS Deployment Guide

> Deploy and run the Veilborn dedicated game server on AWS in under 30 minutes.

---

## Architecture Overview

```
Internet
   │
   ▼
┌──────────────────────────────────────────────────────┐
│  Network Load Balancer (NLB)                         │
│  UDP :7777 game traffic ─────────────────────────┐   │
│  TCP :8080 health / admin API                    │   │
└──────────────────────────────────────────────────│───┘
                                                   │
┌──────────────────────────────────────────────────▼───┐
│  Auto Scaling Group (EC2 c6i.xlarge)                 │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │ Game Server │  │ Game Server │  │ Game Server │  │
│  │  Docker     │  │  Docker     │  │  Docker     │  │
│  │  Godot 4.3  │  │  Godot 4.3  │  │  Godot 4.3  │  │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  │
└─────────│────────────────│────────────────│──────────┘
          │                │                │
     ┌────▼────────────────▼────────────────▼────┐
     │            Private Subnet                  │
     │                                            │
     │   ┌──────────────┐  ┌─────────────────┐   │
     │   │  RDS Postgres │  │ ElastiCache     │   │
     │   │  (Multi-AZ)   │  │ Redis           │   │
     │   └──────────────┘  └─────────────────┘   │
     └────────────────────────────────────────────┘
          │
     ┌────▼──────────────────────┐
     │  S3 Buckets               │
     │  ├── veilborn-chunks-*    │  ← World terrain data
     │  ├── veilborn-backups-*   │  ← World/DB backups
     │  └── veilborn-mods-*      │  ← Mod distribution
     └───────────────────────────┘
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| AWS CLI | >= 2.0 | `brew install awscli` |
| Terraform | >= 1.6 | `brew tap hashicorp/tap && brew install terraform` |
| Docker | >= 24.0 | [docker.com](https://docker.com) |
| Godot | 4.3 stable | [godotengine.org](https://godotengine.org) |

---

## Quick Start (30 minutes)

### Step 1 — Configure AWS CLI

```bash
aws configure
# Enter: Access Key ID, Secret Key, Region (us-east-1), Output (json)

# Verify it works:
aws sts get-caller-identity
```

### Step 2 — Create EC2 Key Pair

```bash
aws ec2 create-key-pair \
  --key-name veilborn-prod \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/veilborn.pem

chmod 400 ~/.ssh/veilborn.pem
```

### Step 3 — Get your IP address

```bash
MY_IP=$(curl -s ifconfig.me)
echo "Your IP: $MY_IP"
```

### Step 4 — Configure tfvars

```bash
cd infrastructure/terraform
cp prod.tfvars.example prod.tfvars

# Edit prod.tfvars:
#   key_pair_name = "veilborn-prod"
#   admin_cidrs   = ["YOUR_IP/32"]
nano prod.tfvars
```

### Step 5 — Deploy infrastructure

```bash
# Bootstrap Terraform state bucket (first time only):
aws s3api create-bucket \
  --bucket veilborn-terraform-state \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket veilborn-terraform-state \
  --versioning-configuration Status=Enabled

aws dynamodb create-table \
  --table-name veilborn-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1

# Deploy:
cd infrastructure/terraform
terraform init
terraform apply -var-file="prod.tfvars"
```

### Step 6 — Build and push Docker image

```bash
# Export Godot server (run from your Godot project directory):
godot --headless \
  --export-release "Linux/X11" \
  /path/to/veilborn-aws/server/docker/export/veilborn_server.x86_64

# Build and push to ECR:
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR="$AWS_ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/veilborn-server"

aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin "$AWS_ACCOUNT.dkr.ecr.us-east-1.amazonaws.com"

docker build -t "$ECR:latest" server/docker/
docker push "$ECR:latest"
```

### Step 7 — Trigger rolling update

```bash
ASG=$(terraform -chdir=infrastructure/terraform output -raw asg_name)
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "$ASG" \
  --region us-east-1
```

### Step 8 — Connect your client

```bash
# Get the server address:
terraform -chdir=infrastructure/terraform output game_server_connect_string
# Output: veilborn-nlb-prod-xxxx.elb.amazonaws.com:7777

# Point your Godot client to that address and port
```

---

## Deployment Script (Automated)

Instead of running steps manually, use the deploy script:

```bash
chmod +x scripts/deploy/deploy.sh

# Set GAME_DIR to your Veilborn Godot project
export GAME_DIR=/path/to/veilborn-godot-project

./scripts/deploy/deploy.sh prod
```

---

## Admin Operations

```bash
chmod +x scripts/admin/admin.sh
export VEILBORN_ENV=prod

# Show server status and online players
./scripts/admin/admin.sh status

# Kick a player
./scripts/admin/admin.sh kick BadPlayer123

# Ban a player
./scripts/admin/admin.sh ban Griefer "Repeated griefing"

# Give item to player
./scripts/admin/admin.sh give HeroPlayer mithril_sword 1

# Broadcast server message
./scripts/admin/admin.sh broadcast "Server maintenance in 10 minutes!"

# Manual world backup
./scripts/admin/admin.sh backup

# Scale to 3 instances
./scripts/admin/admin.sh scale 3

# Tail live logs
./scripts/admin/admin.sh logs

# SSH into a server
./scripts/admin/admin.sh ssh

# Connect to the database
./scripts/admin/admin.sh db
```

---

## Local Development

Run the full stack locally (no AWS needed):

```bash
cd server/docker

# Start game server + PostgreSQL + Redis:
docker compose --profile dev up

# With monitoring (Prometheus + Grafana):
docker compose --profile dev --profile monitoring up

# Access:
# Game server:  localhost:7777
# Admin API:    http://localhost:8080/health
# Grafana:      http://localhost:3000  (admin / veilborn_admin)
# Prometheus:   http://localhost:9090
```

---

## CI/CD with GitHub Actions

1. Add these GitHub secrets to your repository:

| Secret | Value |
|--------|-------|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID |
| `EC2_KEY_PAIR_NAME` | `veilborn-staging` |
| `EC2_KEY_PAIR_NAME_PROD` | `veilborn-prod` |
| `ADMIN_CIDRS` | `["1.2.3.4/32"]` |
| `ADMIN_CIDRS_PROD` | `["1.2.3.4/32"]` |
| `WORLD_SEED` | `42069` |
| `SLACK_BOT_TOKEN` | Optional — for deploy notifications |
| `SLACK_CHANNEL_ID` | Optional |

2. Create GitHub OIDC role in AWS (replaces long-lived keys):

```bash
# Run once to create the OIDC trust:
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# Then create role veilborn-github-actions with OIDC trust
# and permissions matching the IAM policy in main.tf
```

3. Deploy flow:
   - **PR opened** → Terraform plan posted as comment
   - **Push to `main`** → Auto-deploys to staging
   - **Push tag `v1.2.3`** → Manual approval → deploys to prod

---

## Cost Estimate

| Resource | Spec | Monthly Cost |
|----------|------|-------------|
| EC2 (2× c6i.xlarge) | 4 vCPU, 8 GB | ~$250 |
| RDS db.r7g.large | Multi-AZ | ~$200 |
| ElastiCache cache.r7g.large | 1 node | ~$130 |
| NLB | Per LCU | ~$20 |
| S3 (chunks + backups) | ~50 GB | ~$5 |
| CloudWatch | Logs + metrics | ~$15 |
| NAT Gateway | 2 AZs | ~$65 |
| **Total** | | **~$685/month** |

**Dev/staging** (t3/t3 instances, single-AZ): ~$80/month

---

## Monitoring

After deploying the monitoring stack:

| Dashboard | URL |
|-----------|-----|
| Grafana | http://monitoring-ip:3000 |
| Prometheus | http://monitoring-ip:9090 |
| CloudWatch | AWS Console → CloudWatch → Dashboards → Veilborn-prod |

Key metrics to watch:
- `veilborn_active_players` — concurrent players per instance
- `veilborn_server_tick_rate` — should stay at 20/s (dips = lag)
- `veilborn_chunk_generation_queue` — backlog of ungenerated chunks
- `node_memory_MemAvailable_bytes` — memory pressure
- RDS `DatabaseConnections` — connection pool health

---

## Troubleshooting

**Server not starting:**
```bash
# SSH in and check logs:
./scripts/admin/admin.sh ssh
sudo journalctl -u veilborn-server -f
sudo cat /var/log/veilborn-bootstrap.log
```

**Players can't connect:**
```bash
# Check NLB health targets:
aws elbv2 describe-target-health \
  --target-group-arn $(terraform -chdir=infrastructure/terraform output -raw nlb_target_group_arn)

# Check security groups allow UDP 7777 from 0.0.0.0/0
# Check instance is passing health check on TCP 8080
```

**Out of disk space:**
```bash
# Chunks bucket full — clear old unmodified chunks:
aws s3 ls s3://veilborn-chunks-prod-$ACCOUNT/ --recursive | sort -k1 | head -100
# Lifecycle policies auto-expire old versions after 30 days
```

**Database connection errors:**
```bash
# Check RDS is running:
aws rds describe-db-instances --db-instance-identifier veilborn-prod

# Check connection from game server:
./scripts/admin/admin.sh ssh
psql $VEILBORN_DATABASE_URL -c "SELECT version();"
```
