###############################################################################
# Veilborn — Terraform Outputs
###############################################################################

output "nlb_dns_name" {
  description = "DNS name of the Network Load Balancer (point your clients here)"
  value       = aws_lb.game.dns_name
}

output "nlb_zone_id" {
  description = "Zone ID of the NLB (for Route53 alias records)"
  value       = aws_lb.game.zone_id
}

output "game_server_connect_string" {
  description = "Host:port string for game clients to connect to"
  value       = "${aws_lb.game.dns_name}:${var.game_port}"
}

output "db_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = aws_db_instance.main.endpoint
  sensitive   = false
}

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret containing DB credentials"
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "redis_primary_endpoint" {
  description = "ElastiCache Redis primary endpoint"
  value       = aws_elasticache_replication_group.session.primary_endpoint_address
}

output "s3_chunks_bucket" {
  description = "S3 bucket name for chunk data"
  value       = aws_s3_bucket.chunks.id
}

output "s3_backups_bucket" {
  description = "S3 bucket name for backups"
  value       = aws_s3_bucket.backups.id
}

output "s3_mods_bucket" {
  description = "S3 bucket name for mod distribution"
  value       = aws_s3_bucket.mods.id
}

output "asg_name" {
  description = "Auto Scaling Group name"
  value       = aws_autoscaling_group.game_servers.name
}

output "log_group_name" {
  description = "CloudWatch Log Group for game server logs"
  value       = aws_cloudwatch_log_group.game_server.name
}

output "cloudwatch_dashboard_url" {
  description = "URL to the CloudWatch dashboard"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=Veilborn-${var.environment}"
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}
