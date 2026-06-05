###############################################################################
# Veilborn — Terraform Variables
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "game_port" {
  description = "UDP port for ENet game traffic"
  type        = number
  default     = 7777
}

variable "instance_type" {
  description = "EC2 instance type for game servers"
  type        = string
  default     = "c6i.xlarge"
  # Recommendations:
  #   dev:     t3.medium   (2 vCPU, 4 GB)
  #   staging: c6i.large   (2 vCPU, 4 GB)
  #   prod:    c6i.xlarge  (4 vCPU, 8 GB) or c6i.2xlarge (8 vCPU, 16 GB)
}

variable "key_pair_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
}

variable "admin_cidrs" {
  description = "CIDR blocks allowed to access admin endpoints and SSH"
  type        = list(string)
  # Example: ["203.0.113.10/32"]
}

variable "asg_min_size" {
  description = "Minimum number of game server instances"
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "Maximum number of game server instances"
  type        = number
  default     = 10
}

variable "asg_desired_size" {
  description = "Desired number of game server instances at launch"
  type        = number
  default     = 1
}

variable "max_players_per_instance" {
  description = "Max concurrent players per game server instance"
  type        = number
  default     = 64
}

variable "world_seed" {
  description = "Seed for procedural world generation"
  type        = number
  default     = 42069
}

variable "server_region_name" {
  description = "Display name of this server's region (shown in server browser)"
  type        = string
  default     = "Ironmarch Reaches"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
  # Recommendations:
  #   dev:     db.t3.micro
  #   staging: db.t3.medium
  #   prod:    db.r7g.large
}

variable "redis_node_type" {
  description = "ElastiCache Redis node type"
  type        = string
  default     = "cache.t3.medium"
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID (leave empty to skip DNS)"
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Base domain name (e.g. veilborn.io)"
  type        = string
  default     = ""
}
