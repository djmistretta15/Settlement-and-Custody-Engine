###############################################################################
# Multi-Region Deployment - Main Configuration
#
# Production-grade geographic redundancy for Settlement and Custody Engine:
# - AWS Global Accelerator for global traffic distribution
# - Multi-region EKS clusters
# - Cross-region database replication
# - Automated failover
# - Regional health monitoring
#
# Regions:
# - US-East-1 (Primary)
# - EU-West-1 (Secondary)
# - AP-Southeast-1 (Tertiary)
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "settlement-engine-terraform-state"
    key            = "multi-region/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "settlement-engine-terraform-locks"
  }
}

###############################################################################
# Provider Configurations - Multi-Region
###############################################################################

provider "aws" {
  region = "us-east-1"
  alias  = "us_east"

  default_tags {
    tags = {
      Project     = "settlement-engine"
      Environment = var.environment
      ManagedBy   = "terraform"
      Team        = "infrastructure"
    }
  }
}

provider "aws" {
  region = "eu-west-1"
  alias  = "eu_west"

  default_tags {
    tags = {
      Project     = "settlement-engine"
      Environment = var.environment
      ManagedBy   = "terraform"
      Team        = "infrastructure"
    }
  }
}

provider "aws" {
  region = "ap-southeast-1"
  alias  = "ap_southeast"

  default_tags {
    tags = {
      Project     = "settlement-engine"
      Environment = var.environment
      ManagedBy   = "terraform"
      Team        = "infrastructure"
    }
  }
}

###############################################################################
# Variables
###############################################################################

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "production"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "settlement-engine"
}

variable "primary_region" {
  description = "Primary AWS region"
  type        = string
  default     = "us-east-1"
}

variable "secondary_region" {
  description = "Secondary AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "tertiary_region" {
  description = "Tertiary AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "domain_name" {
  description = "Primary domain name"
  type        = string
  default     = "settlement-engine.com"
}

variable "enable_global_accelerator" {
  description = "Enable AWS Global Accelerator"
  type        = bool
  default     = true
}

variable "enable_cross_region_replication" {
  description = "Enable cross-region database replication"
  type        = bool
  default     = true
}

###############################################################################
# Regional VPC Configurations
###############################################################################

module "vpc_us_east" {
  source = "./modules/vpc"
  providers = {
    aws = aws.us_east
  }

  region           = var.primary_region
  environment      = var.environment
  project_name     = var.project_name
  vpc_cidr         = "10.0.0.0/16"
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

  private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnet_cidrs  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false  # HA NAT gateways

  tags = {
    Region = "us-east-1"
    Role   = "primary"
  }
}

module "vpc_eu_west" {
  source = "./modules/vpc"
  providers = {
    aws = aws.eu_west
  }

  region           = var.secondary_region
  environment      = var.environment
  project_name     = var.project_name
  vpc_cidr         = "10.1.0.0/16"
  availability_zones = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]

  private_subnet_cidrs = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]
  public_subnet_cidrs  = ["10.1.101.0/24", "10.1.102.0/24", "10.1.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false

  tags = {
    Region = "eu-west-1"
    Role   = "secondary"
  }
}

module "vpc_ap_southeast" {
  source = "./modules/vpc"
  providers = {
    aws = aws.ap_southeast
  }

  region           = var.tertiary_region
  environment      = var.environment
  project_name     = var.project_name
  vpc_cidr         = "10.2.0.0/16"
  availability_zones = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]

  private_subnet_cidrs = ["10.2.1.0/24", "10.2.2.0/24", "10.2.3.0/24"]
  public_subnet_cidrs  = ["10.2.101.0/24", "10.2.102.0/24", "10.2.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false

  tags = {
    Region = "ap-southeast-1"
    Role   = "tertiary"
  }
}

###############################################################################
# VPC Peering for Cross-Region Communication
###############################################################################

resource "aws_vpc_peering_connection" "us_to_eu" {
  provider = aws.us_east

  vpc_id        = module.vpc_us_east.vpc_id
  peer_vpc_id   = module.vpc_eu_west.vpc_id
  peer_region   = var.secondary_region
  auto_accept   = false

  tags = {
    Name = "${var.project_name}-us-to-eu-peering"
  }
}

resource "aws_vpc_peering_connection_accepter" "eu_accept_us" {
  provider = aws.eu_west

  vpc_peering_connection_id = aws_vpc_peering_connection.us_to_eu.id
  auto_accept               = true

  tags = {
    Name = "${var.project_name}-eu-accept-us-peering"
  }
}

resource "aws_vpc_peering_connection" "us_to_ap" {
  provider = aws.us_east

  vpc_id        = module.vpc_us_east.vpc_id
  peer_vpc_id   = module.vpc_ap_southeast.vpc_id
  peer_region   = var.tertiary_region
  auto_accept   = false

  tags = {
    Name = "${var.project_name}-us-to-ap-peering"
  }
}

resource "aws_vpc_peering_connection_accepter" "ap_accept_us" {
  provider = aws.ap_southeast

  vpc_peering_connection_id = aws_vpc_peering_connection.us_to_ap.id
  auto_accept               = true

  tags = {
    Name = "${var.project_name}-ap-accept-us-peering"
  }
}

resource "aws_vpc_peering_connection" "eu_to_ap" {
  provider = aws.eu_west

  vpc_id        = module.vpc_eu_west.vpc_id
  peer_vpc_id   = module.vpc_ap_southeast.vpc_id
  peer_region   = var.tertiary_region
  auto_accept   = false

  tags = {
    Name = "${var.project_name}-eu-to-ap-peering"
  }
}

resource "aws_vpc_peering_connection_accepter" "ap_accept_eu" {
  provider = aws.ap_southeast

  vpc_peering_connection_id = aws_vpc_peering_connection.eu_to_ap.id
  auto_accept               = true

  tags = {
    Name = "${var.project_name}-ap-accept-eu-peering"
  }
}

###############################################################################
# Regional EKS Clusters
###############################################################################

module "eks_us_east" {
  source = "./modules/eks"
  providers = {
    aws = aws.us_east
  }

  cluster_name    = "${var.project_name}-${var.environment}-us-east"
  cluster_version = "1.28"
  vpc_id          = module.vpc_us_east.vpc_id
  subnet_ids      = module.vpc_us_east.private_subnet_ids

  node_groups = {
    settlement = {
      instance_types = ["m6i.xlarge"]
      min_size       = 3
      max_size       = 10
      desired_size   = 3
      labels = {
        workload = "settlement"
      }
    }
    custody = {
      instance_types = ["m6i.xlarge"]
      min_size       = 2
      max_size       = 8
      desired_size   = 2
      labels = {
        workload = "custody"
      }
    }
  }

  tags = {
    Region = "us-east-1"
    Role   = "primary"
  }
}

module "eks_eu_west" {
  source = "./modules/eks"
  providers = {
    aws = aws.eu_west
  }

  cluster_name    = "${var.project_name}-${var.environment}-eu-west"
  cluster_version = "1.28"
  vpc_id          = module.vpc_eu_west.vpc_id
  subnet_ids      = module.vpc_eu_west.private_subnet_ids

  node_groups = {
    settlement = {
      instance_types = ["m6i.xlarge"]
      min_size       = 2
      max_size       = 8
      desired_size   = 2
      labels = {
        workload = "settlement"
      }
    }
    custody = {
      instance_types = ["m6i.xlarge"]
      min_size       = 2
      max_size       = 6
      desired_size   = 2
      labels = {
        workload = "custody"
      }
    }
  }

  tags = {
    Region = "eu-west-1"
    Role   = "secondary"
  }
}

module "eks_ap_southeast" {
  source = "./modules/eks"
  providers = {
    aws = aws.ap_southeast
  }

  cluster_name    = "${var.project_name}-${var.environment}-ap-southeast"
  cluster_version = "1.28"
  vpc_id          = module.vpc_ap_southeast.vpc_id
  subnet_ids      = module.vpc_ap_southeast.private_subnet_ids

  node_groups = {
    settlement = {
      instance_types = ["m6i.xlarge"]
      min_size       = 2
      max_size       = 6
      desired_size   = 2
      labels = {
        workload = "settlement"
      }
    }
    custody = {
      instance_types = ["m6i.large"]
      min_size       = 1
      max_size       = 4
      desired_size   = 1
      labels = {
        workload = "custody"
      }
    }
  }

  tags = {
    Region = "ap-southeast-1"
    Role   = "tertiary"
  }
}

###############################################################################
# Aurora Global Database (Cross-Region Replication)
###############################################################################

resource "aws_rds_global_cluster" "settlement_global" {
  provider = aws.us_east

  global_cluster_identifier = "${var.project_name}-global-db"
  engine                    = "aurora-postgresql"
  engine_version            = "15.4"
  database_name             = "settlement_engine"
  storage_encrypted         = true
  deletion_protection       = true
}

resource "aws_rds_cluster" "primary" {
  provider = aws.us_east

  cluster_identifier        = "${var.project_name}-primary-db"
  engine                    = "aurora-postgresql"
  engine_version            = "15.4"
  global_cluster_identifier = aws_rds_global_cluster.settlement_global.id
  master_username           = "settlement_admin"
  master_password           = var.db_master_password
  database_name             = "settlement_engine"

  db_subnet_group_name   = aws_db_subnet_group.primary.name
  vpc_security_group_ids = [aws_security_group.rds_primary.id]

  backup_retention_period = 35
  preferred_backup_window = "03:00-04:00"
  skip_final_snapshot     = false
  final_snapshot_identifier = "${var.project_name}-primary-final-snapshot"

  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = {
    Name   = "${var.project_name}-primary-db"
    Region = "us-east-1"
    Role   = "primary"
  }
}

resource "aws_rds_cluster_instance" "primary" {
  provider = aws.us_east
  count    = 3

  identifier         = "${var.project_name}-primary-db-${count.index}"
  cluster_identifier = aws_rds_cluster.primary.id
  instance_class     = "db.r6g.xlarge"
  engine             = "aurora-postgresql"
  engine_version     = "15.4"

  performance_insights_enabled = true
  monitoring_interval          = 60

  tags = {
    Name = "${var.project_name}-primary-db-instance-${count.index}"
  }
}

resource "aws_rds_cluster" "secondary_eu" {
  provider = aws.eu_west
  count    = var.enable_cross_region_replication ? 1 : 0

  cluster_identifier        = "${var.project_name}-secondary-eu-db"
  engine                    = "aurora-postgresql"
  engine_version            = "15.4"
  global_cluster_identifier = aws_rds_global_cluster.settlement_global.id

  db_subnet_group_name   = aws_db_subnet_group.secondary_eu[0].name
  vpc_security_group_ids = [aws_security_group.rds_secondary_eu[0].id]

  skip_final_snapshot = true

  tags = {
    Name   = "${var.project_name}-secondary-eu-db"
    Region = "eu-west-1"
    Role   = "secondary"
  }

  depends_on = [aws_rds_cluster_instance.primary]
}

resource "aws_rds_cluster_instance" "secondary_eu" {
  provider = aws.eu_west
  count    = var.enable_cross_region_replication ? 2 : 0

  identifier         = "${var.project_name}-secondary-eu-db-${count.index}"
  cluster_identifier = aws_rds_cluster.secondary_eu[0].id
  instance_class     = "db.r6g.large"
  engine             = "aurora-postgresql"
  engine_version     = "15.4"

  performance_insights_enabled = true
  monitoring_interval          = 60

  tags = {
    Name = "${var.project_name}-secondary-eu-db-instance-${count.index}"
  }
}

resource "aws_rds_cluster" "secondary_ap" {
  provider = aws.ap_southeast
  count    = var.enable_cross_region_replication ? 1 : 0

  cluster_identifier        = "${var.project_name}-secondary-ap-db"
  engine                    = "aurora-postgresql"
  engine_version            = "15.4"
  global_cluster_identifier = aws_rds_global_cluster.settlement_global.id

  db_subnet_group_name   = aws_db_subnet_group.secondary_ap[0].name
  vpc_security_group_ids = [aws_security_group.rds_secondary_ap[0].id]

  skip_final_snapshot = true

  tags = {
    Name   = "${var.project_name}-secondary-ap-db"
    Region = "ap-southeast-1"
    Role   = "tertiary"
  }

  depends_on = [aws_rds_cluster_instance.primary]
}

resource "aws_rds_cluster_instance" "secondary_ap" {
  provider = aws.ap_southeast
  count    = var.enable_cross_region_replication ? 2 : 0

  identifier         = "${var.project_name}-secondary-ap-db-${count.index}"
  cluster_identifier = aws_rds_cluster.secondary_ap[0].id
  instance_class     = "db.r6g.large"
  engine             = "aurora-postgresql"
  engine_version     = "15.4"

  performance_insights_enabled = true
  monitoring_interval          = 60

  tags = {
    Name = "${var.project_name}-secondary-ap-db-instance-${count.index}"
  }
}

###############################################################################
# AWS Global Accelerator
###############################################################################

resource "aws_globalaccelerator_accelerator" "settlement" {
  provider = aws.us_east
  count    = var.enable_global_accelerator ? 1 : 0

  name            = "${var.project_name}-global-accelerator"
  ip_address_type = "IPV4"
  enabled         = true

  attributes {
    flow_logs_enabled   = true
    flow_logs_s3_bucket = aws_s3_bucket.global_accelerator_logs[0].id
    flow_logs_s3_prefix = "flow-logs/"
  }

  tags = {
    Name = "${var.project_name}-global-accelerator"
  }
}

resource "aws_globalaccelerator_listener" "settlement_https" {
  provider = aws.us_east
  count    = var.enable_global_accelerator ? 1 : 0

  accelerator_arn = aws_globalaccelerator_accelerator.settlement[0].id
  client_affinity = "SOURCE_IP"
  protocol        = "TCP"

  port_range {
    from_port = 443
    to_port   = 443
  }
}

resource "aws_globalaccelerator_endpoint_group" "us_east" {
  provider = aws.us_east
  count    = var.enable_global_accelerator ? 1 : 0

  listener_arn                  = aws_globalaccelerator_listener.settlement_https[0].id
  endpoint_group_region         = var.primary_region
  health_check_interval_seconds = 30
  health_check_path             = "/health"
  health_check_port             = 443
  health_check_protocol         = "HTTPS"
  threshold_count               = 3
  traffic_dial_percentage       = 100

  endpoint_configuration {
    endpoint_id                    = module.eks_us_east.nlb_arn
    weight                         = 100
    client_ip_preservation_enabled = true
  }

  port_override {
    endpoint_port = 443
    listener_port = 443
  }
}

resource "aws_globalaccelerator_endpoint_group" "eu_west" {
  provider = aws.us_east
  count    = var.enable_global_accelerator ? 1 : 0

  listener_arn                  = aws_globalaccelerator_listener.settlement_https[0].id
  endpoint_group_region         = var.secondary_region
  health_check_interval_seconds = 30
  health_check_path             = "/health"
  health_check_port             = 443
  health_check_protocol         = "HTTPS"
  threshold_count               = 3
  traffic_dial_percentage       = 100

  endpoint_configuration {
    endpoint_id                    = module.eks_eu_west.nlb_arn
    weight                         = 100
    client_ip_preservation_enabled = true
  }
}

resource "aws_globalaccelerator_endpoint_group" "ap_southeast" {
  provider = aws.us_east
  count    = var.enable_global_accelerator ? 1 : 0

  listener_arn                  = aws_globalaccelerator_listener.settlement_https[0].id
  endpoint_group_region         = var.tertiary_region
  health_check_interval_seconds = 30
  health_check_path             = "/health"
  health_check_port             = 443
  health_check_protocol         = "HTTPS"
  threshold_count               = 3
  traffic_dial_percentage       = 100

  endpoint_configuration {
    endpoint_id                    = module.eks_ap_southeast.nlb_arn
    weight                         = 100
    client_ip_preservation_enabled = true
  }
}

###############################################################################
# Route 53 Health Checks and Failover
###############################################################################

resource "aws_route53_health_check" "us_east" {
  provider = aws.us_east

  fqdn              = "us-east.${var.domain_name}"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30

  regions = ["us-east-1", "eu-west-1", "ap-southeast-1"]

  tags = {
    Name = "${var.project_name}-us-east-health-check"
  }
}

resource "aws_route53_health_check" "eu_west" {
  provider = aws.us_east

  fqdn              = "eu-west.${var.domain_name}"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30

  regions = ["us-east-1", "eu-west-1", "ap-southeast-1"]

  tags = {
    Name = "${var.project_name}-eu-west-health-check"
  }
}

resource "aws_route53_health_check" "ap_southeast" {
  provider = aws.us_east

  fqdn              = "ap-southeast.${var.domain_name}"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30

  regions = ["us-east-1", "eu-west-1", "ap-southeast-1"]

  tags = {
    Name = "${var.project_name}-ap-southeast-health-check"
  }
}

###############################################################################
# CloudWatch Cross-Region Dashboard
###############################################################################

resource "aws_cloudwatch_dashboard" "multi_region" {
  provider = aws.us_east

  dashboard_name = "${var.project_name}-multi-region-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBClusterIdentifier", aws_rds_cluster.primary.cluster_identifier],
          ]
          period = 300
          stat   = "Average"
          region = var.primary_region
          title  = "Primary DB CPU Utilization"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/GlobalAccelerator", "ProcessedBytesIn", "Accelerator", aws_globalaccelerator_accelerator.settlement[0].id],
            ["AWS/GlobalAccelerator", "ProcessedBytesOut", "Accelerator", aws_globalaccelerator_accelerator.settlement[0].id],
          ]
          period = 300
          stat   = "Sum"
          region = "us-west-2"  # Global Accelerator metrics are in us-west-2
          title  = "Global Accelerator Traffic"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["AWS/EKS", "cluster_node_count", "ClusterName", module.eks_us_east.cluster_name],
          ]
          period = 300
          stat   = "Average"
          region = var.primary_region
          title  = "US-East Node Count"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["AWS/EKS", "cluster_node_count", "ClusterName", module.eks_eu_west.cluster_name],
          ]
          period = 300
          stat   = "Average"
          region = var.secondary_region
          title  = "EU-West Node Count"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["AWS/EKS", "cluster_node_count", "ClusterName", module.eks_ap_southeast.cluster_name],
          ]
          period = 300
          stat   = "Average"
          region = var.tertiary_region
          title  = "AP-Southeast Node Count"
        }
      },
    ]
  })
}

###############################################################################
# Outputs
###############################################################################

output "global_accelerator_dns" {
  description = "Global Accelerator DNS name"
  value       = var.enable_global_accelerator ? aws_globalaccelerator_accelerator.settlement[0].dns_name : null
}

output "global_accelerator_ips" {
  description = "Global Accelerator static IPs"
  value       = var.enable_global_accelerator ? aws_globalaccelerator_accelerator.settlement[0].ip_sets : null
}

output "primary_db_endpoint" {
  description = "Primary Aurora cluster endpoint"
  value       = aws_rds_cluster.primary.endpoint
}

output "primary_db_reader_endpoint" {
  description = "Primary Aurora reader endpoint"
  value       = aws_rds_cluster.primary.reader_endpoint
}

output "secondary_eu_db_endpoint" {
  description = "Secondary EU Aurora cluster endpoint"
  value       = var.enable_cross_region_replication ? aws_rds_cluster.secondary_eu[0].endpoint : null
}

output "secondary_ap_db_endpoint" {
  description = "Secondary AP Aurora cluster endpoint"
  value       = var.enable_cross_region_replication ? aws_rds_cluster.secondary_ap[0].endpoint : null
}

output "eks_us_east_endpoint" {
  description = "US-East EKS cluster endpoint"
  value       = module.eks_us_east.cluster_endpoint
}

output "eks_eu_west_endpoint" {
  description = "EU-West EKS cluster endpoint"
  value       = module.eks_eu_west.cluster_endpoint
}

output "eks_ap_southeast_endpoint" {
  description = "AP-Southeast EKS cluster endpoint"
  value       = module.eks_ap_southeast.cluster_endpoint
}

###############################################################################
# Additional Variables (for sensitive data)
###############################################################################

variable "db_master_password" {
  description = "Master password for Aurora database"
  type        = string
  sensitive   = true
}

###############################################################################
# Security Groups (simplified - would be in modules)
###############################################################################

resource "aws_security_group" "rds_primary" {
  provider = aws.us_east

  name_prefix = "${var.project_name}-rds-primary-"
  vpc_id      = module.vpc_us_east.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
    description = "PostgreSQL from VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rds-primary-sg"
  }
}

resource "aws_security_group" "rds_secondary_eu" {
  provider = aws.eu_west
  count    = var.enable_cross_region_replication ? 1 : 0

  name_prefix = "${var.project_name}-rds-secondary-eu-"
  vpc_id      = module.vpc_eu_west.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
    description = "PostgreSQL from VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rds-secondary-eu-sg"
  }
}

resource "aws_security_group" "rds_secondary_ap" {
  provider = aws.ap_southeast
  count    = var.enable_cross_region_replication ? 1 : 0

  name_prefix = "${var.project_name}-rds-secondary-ap-"
  vpc_id      = module.vpc_ap_southeast.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
    description = "PostgreSQL from VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rds-secondary-ap-sg"
  }
}

###############################################################################
# DB Subnet Groups
###############################################################################

resource "aws_db_subnet_group" "primary" {
  provider = aws.us_east

  name       = "${var.project_name}-primary-db-subnet"
  subnet_ids = module.vpc_us_east.private_subnet_ids

  tags = {
    Name = "${var.project_name}-primary-db-subnet-group"
  }
}

resource "aws_db_subnet_group" "secondary_eu" {
  provider = aws.eu_west
  count    = var.enable_cross_region_replication ? 1 : 0

  name       = "${var.project_name}-secondary-eu-db-subnet"
  subnet_ids = module.vpc_eu_west.private_subnet_ids

  tags = {
    Name = "${var.project_name}-secondary-eu-db-subnet-group"
  }
}

resource "aws_db_subnet_group" "secondary_ap" {
  provider = aws.ap_southeast
  count    = var.enable_cross_region_replication ? 1 : 0

  name       = "${var.project_name}-secondary-ap-db-subnet"
  subnet_ids = module.vpc_ap_southeast.private_subnet_ids

  tags = {
    Name = "${var.project_name}-secondary-ap-db-subnet-group"
  }
}

###############################################################################
# S3 Bucket for Global Accelerator Logs
###############################################################################

resource "aws_s3_bucket" "global_accelerator_logs" {
  provider = aws.us_east
  count    = var.enable_global_accelerator ? 1 : 0

  bucket = "${var.project_name}-global-accelerator-logs-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.project_name}-global-accelerator-logs"
  }
}

resource "aws_s3_bucket_versioning" "global_accelerator_logs" {
  provider = aws.us_east
  count    = var.enable_global_accelerator ? 1 : 0

  bucket = aws_s3_bucket.global_accelerator_logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_caller_identity" "current" {
  provider = aws.us_east
}

###############################################################################
# End of Configuration
###############################################################################
