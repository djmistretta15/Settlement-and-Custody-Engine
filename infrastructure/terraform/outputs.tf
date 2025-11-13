/**
 * Terraform Outputs
 * Settlement and Custody Engine Infrastructure
 */

# ============================================================================
# EKS Outputs
# ============================================================================

output "eks_cluster_id" {
  description = "EKS cluster ID"
  value       = module.eks.cluster_id
}

output "eks_cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.eks.cluster_security_group_id
}

output "eks_cluster_oidc_issuer_url" {
  description = "The URL on the EKS cluster OIDC Issuer"
  value       = module.eks.cluster_oidc_issuer_url
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_id}"
}

# ============================================================================
# VPC Outputs
# ============================================================================

output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "The CIDR block of the VPC"
  value       = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  description = "List of IDs of public subnets"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "List of IDs of private subnets"
  value       = module.vpc.private_subnet_ids
}

output "nat_gateway_ids" {
  description = "List of NAT Gateway IDs"
  value       = module.vpc.nat_gateway_ids
}

# ============================================================================
# RDS Outputs
# ============================================================================

output "rds_instance_id" {
  description = "The RDS instance ID"
  value       = module.rds.db_instance_id
}

output "rds_instance_endpoint" {
  description = "The connection endpoint"
  value       = module.rds.db_instance_endpoint
  sensitive   = true
}

output "rds_instance_arn" {
  description = "The ARN of the RDS instance"
  value       = module.rds.db_instance_arn
}

output "rds_database_name" {
  description = "The database name"
  value       = var.db_name
}

# ============================================================================
# Redis Outputs
# ============================================================================

output "redis_cluster_id" {
  description = "The ID of the ElastiCache cluster"
  value       = module.redis.cluster_id
}

output "redis_primary_endpoint" {
  description = "The primary endpoint of the Redis cluster"
  value       = module.redis.primary_endpoint_address
  sensitive   = true
}

output "redis_port" {
  description = "The port of the Redis cluster"
  value       = 6379
}

# ============================================================================
# Secrets Manager Outputs
# ============================================================================

output "db_credentials_secret_arn" {
  description = "ARN of the database credentials secret"
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "redis_auth_secret_arn" {
  description = "ARN of the Redis auth token secret"
  value       = aws_secretsmanager_secret.redis_auth.arn
}

# ============================================================================
# IAM Outputs
# ============================================================================

output "custody_engine_role_arn" {
  description = "ARN of the custody engine IAM role"
  value       = aws_iam_role.custody_engine.arn
}

# ============================================================================
# Connection Information
# ============================================================================

output "connection_info" {
  description = "Connection information for services"
  value = {
    eks = {
      cluster_name = module.eks.cluster_id
      region       = var.aws_region
    }
    database = {
      host   = module.rds.db_instance_address
      port   = 5432
      dbname = var.db_name
    }
    redis = {
      host = module.redis.primary_endpoint_address
      port = 6379
    }
  }
  sensitive = true
}

# ============================================================================
# Quick Start Commands
# ============================================================================

output "quick_start_commands" {
  description = "Quick start commands for deployment"
  value = <<-EOT
    # Configure kubectl
    aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_id}

    # Verify cluster access
    kubectl cluster-info

    # Get database credentials
    aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.db_credentials.name} --region ${var.aws_region}

    # Get Redis auth token
    aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.redis_auth.name} --region ${var.aws_region}

    # Deploy application
    kubectl apply -f ../kubernetes/namespaces/
    kubectl apply -f ../kubernetes/deployments/
    kubectl apply -f ../kubernetes/services/
    kubectl apply -f ../kubernetes/ingress/
  EOT
}
