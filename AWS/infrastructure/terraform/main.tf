###############################################################################
# Veilborn RPG — AWS Infrastructure (Terraform)
# 
# Architecture:
#   - EC2 Auto Scaling Group for game server instances
#   - Application Load Balancer (TCP/UDP via NLB for game traffic)
#   - RDS PostgreSQL for persistent world/player data
#   - ElastiCache Redis for session data and leaderboards
#   - S3 for chunk data, backups, and mod distribution
#   - CloudWatch for metrics, alarms, and log aggregation
#   - VPC with public/private subnets across 2 AZs
#   - Route53 for DNS
#   - ACM for SSL (REST API / admin panel)
#
# Usage:
#   terraform init
#   terraform plan -var-file="prod.tfvars"
#   terraform apply -var-file="prod.tfvars"
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # Remote state — create this S3 bucket manually first
  backend "s3" {
    bucket         = "veilborn-terraform-state"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "veilborn-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "veilborn"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

###############################################################################
# DATA SOURCES
###############################################################################
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

###############################################################################
# VPC & NETWORKING
###############################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "veilborn-${var.environment}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = var.public_subnet_cidrs
  private_subnets = var.private_subnet_cidrs

  enable_nat_gateway     = true
  single_nat_gateway     = var.environment != "prod"  # Multi-NAT in prod
  enable_dns_hostnames   = true
  enable_dns_support     = true

  # VPC Flow Logs
  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true
  flow_log_max_aggregation_interval    = 60
}

###############################################################################
# SECURITY GROUPS
###############################################################################

# Game server — accepts game traffic from internet
resource "aws_security_group" "game_server" {
  name        = "veilborn-game-server-${var.environment}"
  description = "Game server instances — ENet UDP game traffic + SSH"
  vpc_id      = module.vpc.vpc_id

  # ENet game traffic (UDP)
  ingress {
    from_port   = var.game_port
    to_port     = var.game_port
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "ENet game traffic"
  }

  # Admin REST API (TCP) — restricted to admin CIDR
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
    description = "Admin REST API"
  }

  # SSH — admin only
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
    description = "SSH admin"
  }

  # Metrics (Prometheus scrape from monitoring subnet)
  ingress {
    from_port       = 9090
    to_port         = 9090
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
    description     = "Prometheus metrics"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound"
  }
}

# RDS — only reachable from game servers
resource "aws_security_group" "database" {
  name        = "veilborn-database-${var.environment}"
  description = "RDS PostgreSQL — game servers only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.game_server.id]
    description     = "PostgreSQL from game servers"
  }
}

# Redis — only reachable from game servers
resource "aws_security_group" "redis" {
  name        = "veilborn-redis-${var.environment}"
  description = "ElastiCache Redis — game servers only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.game_server.id]
    description     = "Redis from game servers"
  }
}

# Monitoring
resource "aws_security_group" "monitoring" {
  name        = "veilborn-monitoring-${var.environment}"
  description = "Prometheus / Grafana monitoring instance"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
    description = "Grafana UI"
  }

  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
    description = "Prometheus UI"
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

###############################################################################
# NETWORK LOAD BALANCER (UDP game traffic)
###############################################################################
resource "aws_lb" "game" {
  name               = "veilborn-nlb-${var.environment}"
  internal           = false
  load_balancer_type = "network"
  subnets            = module.vpc.public_subnets

  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = var.environment == "prod"
}

resource "aws_lb_target_group" "game_udp" {
  name        = "veilborn-game-udp-${var.environment}"
  port        = var.game_port
  protocol    = "UDP"
  target_type = "instance"
  vpc_id      = module.vpc.vpc_id

  health_check {
    protocol            = "TCP"
    port                = "8080"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }
}

resource "aws_lb_listener" "game_udp" {
  load_balancer_arn = aws_lb.game.arn
  port              = var.game_port
  protocol          = "UDP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.game_udp.arn
  }
}

###############################################################################
# IAM — EC2 Instance Role
###############################################################################
resource "aws_iam_role" "game_server" {
  name = "veilborn-game-server-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "game_server" {
  name = "veilborn-game-server-policy"
  role = aws_iam_role.game_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ChunkAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject",
          "s3:DeleteObject", "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.chunks.arn,
          "${aws_s3_bucket.chunks.arn}/*",
          aws_s3_bucket.backups.arn,
          "${aws_s3_bucket.backups.arn}/*",
          aws_s3_bucket.mods.arn,
          "${aws_s3_bucket.mods.arn}/*",
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:CreateLogStream",
          "logs:PutLogEvents", "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Sid    = "SSMParameterAccess"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/veilborn/*"
      },
      {
        Sid    = "SecretsManagerAccess"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.db_credentials.arn
      },
      {
        Sid    = "EC2Describe"
        Effect = "Allow"
        Action = ["ec2:DescribeInstances", "ec2:DescribeTags"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "game_server" {
  name = "veilborn-game-server-${var.environment}"
  role = aws_iam_role.game_server.name
}

###############################################################################
# AUTO SCALING GROUP
###############################################################################
resource "aws_launch_template" "game_server" {
  name_prefix   = "veilborn-${var.environment}-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type
  key_name      = var.key_pair_name

  vpc_security_group_ids = [aws_security_group.game_server.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.game_server.name
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      throughput            = 125
      iops                  = 3000
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring { enabled = true }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    environment        = var.environment
    aws_region         = var.aws_region
    s3_chunks_bucket   = aws_s3_bucket.chunks.id
    s3_mods_bucket     = aws_s3_bucket.mods.id
    db_secret_arn      = aws_secretsmanager_secret.db_credentials.arn
    redis_endpoint     = aws_elasticache_replication_group.session.primary_endpoint_address
    game_port          = var.game_port
    world_seed         = var.world_seed
    max_players        = var.max_players_per_instance
    server_region      = var.server_region_name
    log_group          = aws_cloudwatch_log_group.game_server.name
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "veilborn-game-server-${var.environment}"
      Role = "game-server"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "game_servers" {
  name                = "veilborn-${var.environment}-asg"
  vpc_zone_identifier = module.vpc.public_subnets
  target_group_arns   = [aws_lb_target_group.game_udp.arn]

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_size

  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.game_server.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 120
    }
  }

  tag {
    key                 = "Name"
    value               = "veilborn-game-server-${var.environment}"
    propagate_at_launch = true
  }
}

# Scale out when average CPU > 70%
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "veilborn-scale-out"
  autoscaling_group_name = aws_autoscaling_group.game_servers.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 300
}

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "veilborn-high-cpu-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Scale out game servers on high CPU"
  alarm_actions       = [aws_autoscaling_policy.scale_out.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.game_servers.name
  }
}

# Scale in when CPU < 30%
resource "aws_autoscaling_policy" "scale_in" {
  name                   = "veilborn-scale-in"
  autoscaling_group_name = aws_autoscaling_group.game_servers.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 300
}

resource "aws_cloudwatch_metric_alarm" "low_cpu" {
  alarm_name          = "veilborn-low-cpu-${var.environment}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 5
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 30
  alarm_actions       = [aws_autoscaling_policy.scale_in.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.game_servers.name
  }
}

###############################################################################
# RDS — POSTGRESQL (persistent world & player data)
###############################################################################
resource "aws_db_subnet_group" "main" {
  name       = "veilborn-${var.environment}"
  subnet_ids = module.vpc.private_subnets
}

resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}:?"
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "veilborn/${var.environment}/db-credentials"
  recovery_window_in_days = var.environment == "prod" ? 7 : 0
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = "veilborn_admin"
    password = random_password.db_password.result
    host     = aws_db_instance.main.address
    port     = 5432
    dbname   = "veilborn"
  })
}

resource "aws_db_instance" "main" {
  identifier = "veilborn-${var.environment}"

  engine               = "postgres"
  engine_version       = "16.1"
  instance_class       = var.db_instance_class
  allocated_storage    = 50
  max_allocated_storage = 500
  storage_type         = "gp3"
  storage_encrypted    = true

  db_name  = "veilborn"
  username = "veilborn_admin"
  password = random_password.db_password.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false
  multi_az               = var.environment == "prod"

  backup_retention_period   = var.environment == "prod" ? 14 : 3
  backup_window             = "03:00-04:00"
  maintenance_window        = "Mon:04:00-Mon:05:00"
  auto_minor_version_upgrade = true

  deletion_protection = var.environment == "prod"
  skip_final_snapshot = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "veilborn-final-snapshot" : null

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = { Name = "veilborn-${var.environment}-postgres" }
}

###############################################################################
# ELASTICACHE — REDIS (sessions, pub/sub, leaderboards)
###############################################################################
resource "aws_elasticache_subnet_group" "main" {
  name       = "veilborn-${var.environment}"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_elasticache_replication_group" "session" {
  replication_group_id = "veilborn-${var.environment}"
  description          = "Veilborn session store and pub/sub"

  node_type               = var.redis_node_type
  num_cache_clusters      = var.environment == "prod" ? 2 : 1
  automatic_failover_enabled = var.environment == "prod"
  multi_az_enabled        = var.environment == "prod"

  engine_version          = "7.2"
  port                    = 6379

  subnet_group_name       = aws_elasticache_subnet_group.main.name
  security_group_ids      = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result

  snapshot_retention_limit = 3
  snapshot_window          = "02:00-03:00"
  maintenance_window       = "sun:05:00-sun:06:00"

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.redis.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }
}

resource "random_password" "redis_auth" {
  length  = 64
  special = false
}

###############################################################################
# S3 BUCKETS
###############################################################################

# Chunk data (world terrain)
resource "aws_s3_bucket" "chunks" {
  bucket = "veilborn-chunks-${var.environment}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "chunks" {
  bucket = aws_s3_bucket.chunks.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "chunks" {
  bucket = aws_s3_bucket.chunks.id
  rule {
    id     = "expire-old-chunk-versions"
    status = "Enabled"
    noncurrent_version_expiration { noncurrent_days = 30 }
    filter { prefix = "chunks/" }
  }
}

# Backups (world saves, DB snapshots)
resource "aws_s3_bucket" "backups" {
  bucket = "veilborn-backups-${var.environment}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    id     = "transition-to-glacier"
    status = "Enabled"
    transition {
      days          = 30
      storage_class = "GLACIER"
    }
    expiration { days = 365 }
    filter {}
  }
}

# Mods (player-uploaded mod content)
resource "aws_s3_bucket" "mods" {
  bucket = "veilborn-mods-${var.environment}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_cors_configuration" "mods" {
  bucket = aws_s3_bucket.mods.id
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"]
    max_age_seconds = 3600
  }
}

# Block public access on all buckets except mods
resource "aws_s3_bucket_public_access_block" "chunks" {
  bucket = aws_s3_bucket.chunks.id
  block_public_acls   = true
  block_public_policy = true
  ignore_public_acls  = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id
  block_public_acls   = true
  block_public_policy = true
  ignore_public_acls  = true
  restrict_public_buckets = true
}

data "aws_caller_identity" "current" {}

###############################################################################
# CLOUDWATCH LOGGING & MONITORING
###############################################################################
resource "aws_cloudwatch_log_group" "game_server" {
  name              = "/veilborn/${var.environment}/game-server"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "redis" {
  name              = "/veilborn/${var.environment}/redis"
  retention_in_days = 7
}

# Custom metric: active player count (pushed by game server)
resource "aws_cloudwatch_metric_alarm" "player_count_low" {
  alarm_name          = "veilborn-no-players-${var.environment}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 10
  metric_name         = "ActivePlayerCount"
  namespace           = "Veilborn/GameServer"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "No players online — consider scaling in"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "Veilborn-${var.environment}"
  dashboard_body = templatefile("${path.module}/dashboard.json.tpl", {
    region      = var.aws_region
    environment = var.environment
    asg_name    = aws_autoscaling_group.game_servers.name
    db_id       = aws_db_instance.main.id
    redis_id    = aws_elasticache_replication_group.session.id
  })
}

###############################################################################
# ROUTE53 (optional — set var.hosted_zone_id to enable)
###############################################################################
resource "aws_route53_record" "game" {
  count   = var.hosted_zone_id != "" ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = "game.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.game.dns_name
    zone_id                = aws_lb.game.zone_id
    evaluate_target_health = true
  }
}

###############################################################################
# SSM PARAMETERS (non-secret config for game servers to read at boot)
###############################################################################
resource "aws_ssm_parameter" "game_port" {
  name  = "/veilborn/${var.environment}/game_port"
  type  = "String"
  value = tostring(var.game_port)
}

resource "aws_ssm_parameter" "max_players" {
  name  = "/veilborn/${var.environment}/max_players"
  type  = "String"
  value = tostring(var.max_players_per_instance)
}

resource "aws_ssm_parameter" "world_seed" {
  name  = "/veilborn/${var.environment}/world_seed"
  type  = "String"
  value = tostring(var.world_seed)
}

resource "aws_ssm_parameter" "redis_endpoint" {
  name  = "/veilborn/${var.environment}/redis_endpoint"
  type  = "String"
  value = aws_elasticache_replication_group.session.primary_endpoint_address
}
