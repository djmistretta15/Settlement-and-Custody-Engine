/**
 * Terraform Variables
 * Settlement and Custody Engine Infrastructure
 */

# ============================================================================
# General Variables
# ============================================================================

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "settlement-engine"
}

variable "environment" {
  description = "Environment (dev, staging, production)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be dev, staging, or production."
  }
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cost_center" {
  description = "Cost center for billing"
  type        = string
  default     = "engineering"
}

# ============================================================================
# VPC Variables
# ============================================================================

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

# ============================================================================
# EKS Variables
# ============================================================================

variable "eks_cluster_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.28"
}

variable "eks_node_group_desired_size" {
  description = "Desired number of nodes in EKS node group"
  type        = number
  default     = 3
}

variable "eks_node_group_min_size" {
  description = "Minimum number of nodes in EKS node group"
  type        = number
  default     = 2
}

variable "eks_node_group_max_size" {
  description = "Maximum number of nodes in EKS node group"
  type        = number
  default     = 10
}

# ============================================================================
# RDS Variables
# ============================================================================

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.large"
}

variable "rds_allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 100
}

variable "rds_max_allocated_storage" {
  description = "Maximum allocated storage for autoscaling (GB)"
  type        = number
  default     = 1000
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "settlement_engine"
}

variable "db_username" {
  description = "Database master username"
  type        = string
  default     = "postgres"
  sensitive   = true
}

# ============================================================================
# Redis Variables
# ============================================================================

variable "redis_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.medium"
}

variable "redis_num_cache_nodes" {
  description = "Number of cache nodes"
  type        = number
  default     = 2
}

# ============================================================================
# Environment-Specific Defaults
# ============================================================================

variable "environment_configs" {
  description = "Environment-specific configurations"
  type = map(object({
    eks_node_group_desired_size = number
    eks_node_group_min_size     = number
    eks_node_group_max_size     = number
    rds_instance_class          = string
    rds_multi_az               = bool
    redis_node_type            = string
  }))

  default = {
    dev = {
      eks_node_group_desired_size = 2
      eks_node_group_min_size     = 1
      eks_node_group_max_size     = 4
      rds_instance_class          = "db.t3.medium"
      rds_multi_az               = false
      redis_node_type            = "cache.t3.small"
    }

    staging = {
      eks_node_group_desired_size = 3
      eks_node_group_min_size     = 2
      eks_node_group_max_size     = 8
      rds_instance_class          = "db.t3.large"
      rds_multi_az               = true
      redis_node_type            = "cache.t3.medium"
    }

    production = {
      eks_node_group_desired_size = 5
      eks_node_group_min_size     = 3
      eks_node_group_max_size     = 20
      rds_instance_class          = "db.r6g.xlarge"
      rds_multi_az               = true
      redis_node_type            = "cache.r6g.large"
    }
  }
}
