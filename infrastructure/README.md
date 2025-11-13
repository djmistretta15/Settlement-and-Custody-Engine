# Infrastructure as Code
## Settlement and Custody Engine

Production-grade infrastructure for deploying the Settlement and Custody Engine on AWS with Kubernetes.

---

## 📁 Structure

```
infrastructure/
├── terraform/                 # Infrastructure provisioning
│   ├── main.tf               # Main Terraform configuration
│   ├── variables.tf          # Input variables
│   ├── outputs.tf            # Output values
│   └── modules/
│       ├── vpc/              # VPC with public/private subnets
│       ├── eks/              # EKS cluster with managed node groups
│       ├── rds/              # PostgreSQL RDS instance
│       └── redis/            # ElastiCache Redis cluster
└── kubernetes/               # Kubernetes manifests
    ├── namespaces/           # Namespace definitions
    ├── deployments/          # Application deployments
    ├── services/             # Service definitions
    └── ingress/              # Ingress rules and TLS
```

---

## 🚀 Quick Start

### Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.6.0
- kubectl >= 1.28
- Helm >= 3.0 (optional, for Helm charts)

### 1. Provision Infrastructure

```bash
cd infrastructure/terraform

# Initialize Terraform
terraform init

# Create a workspace for your environment
terraform workspace new production

# Review the plan
terraform plan -var-file=environments/production.tfvars

# Apply the configuration
terraform apply -var-file=environments/production.tfvars

# Save outputs for later use
terraform output -json > outputs.json
```

### 2. Configure kubectl

```bash
# Get the command from Terraform output
aws eks update-kubeconfig --region us-east-1 --name settlement-engine-production-eks

# Verify cluster access
kubectl cluster-info
kubectl get nodes
```

### 3. Deploy Application

```bash
cd ../kubernetes

# Create namespace and resource quotas
kubectl apply -f namespaces/

# Deploy services
kubectl apply -f deployments/
kubectl apply -f services/
kubectl apply -f ingress/

# Verify deployments
kubectl get pods -n settlement
kubectl get svc -n settlement
kubectl get ingress -n settlement
```

---

## 🏗️ Architecture

### AWS Resources Created

| Resource | Type | Purpose |
|----------|------|---------|
| VPC | Network | Isolated network with 3 public + 3 private subnets |
| NAT Gateway | Network | Outbound internet access for private subnets |
| EKS Cluster | Compute | Managed Kubernetes control plane |
| EKS Node Groups | Compute | Worker nodes (general + compute-intensive) |
| RDS PostgreSQL | Database | Persistent data storage |
| ElastiCache Redis | Cache | Session storage and pub/sub |
| Secrets Manager | Security | Encrypted credential storage |
| KMS Keys | Security | Encryption at rest |
| IAM Roles | Security | IRSA for service accounts |
| VPC Endpoints | Network | Private AWS service access |
| CloudWatch | Observability | Logs and metrics |

### Kubernetes Resources

| Resource | Count | Purpose |
|----------|-------|---------|
| Namespace | 1 | Logical isolation |
| Deployment | 1+ | Application workloads |
| Service | 2+ | Internal/external networking |
| Ingress | 1 | HTTPS routing with TLS |
| HPA | 1+ | Auto-scaling |
| PDB | 1+ | High availability |
| ServiceAccount | 1+ | IRSA integration |
| ConfigMap | 1+ | Application configuration |
| PVC | 1+ | Persistent storage |

---

## ⚙️ Configuration

### Environment Variables

Create a `environments/production.tfvars` file:

```hcl
project_name = "settlement-engine"
environment  = "production"
aws_region   = "us-east-1"

vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]

eks_cluster_version         = "1.28"
eks_node_group_desired_size = 5
eks_node_group_min_size     = 3
eks_node_group_max_size     = 20

rds_instance_class      = "db.r6g.xlarge"
rds_allocated_storage   = 500
rds_max_allocated_storage = 2000

redis_node_type      = "cache.r6g.large"
redis_num_cache_nodes = 3
```

### Kubernetes Secrets

Create secrets for database and Redis credentials:

```bash
# Get credentials from Terraform
DB_CREDS=$(aws secretsmanager get-secret-value \
  --secret-id settlement-engine-production-db-credentials \
  --query SecretString --output text)

REDIS_AUTH=$(aws secretsmanager get-secret-value \
  --secret-id settlement-engine-production-redis-auth \
  --query SecretString --output text)

# Create Kubernetes secrets
kubectl create secret generic db-credentials \
  --from-literal=host=$(echo $DB_CREDS | jq -r .host) \
  --from-literal=port=$(echo $DB_CREDS | jq -r .port) \
  --from-literal=dbname=$(echo $DB_CREDS | jq -r .dbname) \
  --from-literal=username=$(echo $DB_CREDS | jq -r .username) \
  --from-literal=password=$(echo $DB_CREDS | jq -r .password) \
  -n settlement

kubectl create secret generic redis-credentials \
  --from-literal=host=$(echo $REDIS_AUTH | jq -r .host) \
  --from-literal=port=$(echo $REDIS_AUTH | jq -r .port) \
  --from-literal=auth_token=$(echo $REDIS_AUTH | jq -r .auth_token) \
  -n settlement
```

---

## 🔒 Security

### Best Practices Implemented

✅ **Network Isolation**
- Private subnets for all application workloads
- NAT Gateways for controlled outbound access
- Security groups with least privilege
- VPC endpoints for AWS services

✅ **Encryption**
- EKS secrets encryption with KMS
- RDS encryption at rest
- Redis encryption in transit and at rest
- TLS/HTTPS for all external traffic

✅ **Identity & Access**
- IRSA (IAM Roles for Service Accounts)
- No long-lived credentials in pods
- Secrets Manager for credential storage
- Multi-factor authentication required

✅ **High Availability**
- Multi-AZ deployment
- Auto-scaling (HPA + Cluster Autoscaler)
- Pod Disruption Budgets
- RDS automated backups with 30-day retention

✅ **Compliance**
- SOC 2 Type II controls
- PCI DSS requirements
- Resource quotas and limits
- Audit logging enabled

---

## 📊 Monitoring & Observability

### CloudWatch Integration

```bash
# View EKS control plane logs
aws logs tail /aws/eks/settlement-engine-production-eks/cluster --follow

# View RDS performance metrics
aws rds describe-db-instances \
  --db-instance-identifier settlement-engine-production-postgres \
  --query 'DBInstances[0].PerformanceInsightsEnabled'
```

### Prometheus Metrics

All pods expose metrics on port 9090:

```bash
kubectl port-forward -n settlement svc/custody-engine 9090:9090
curl http://localhost:9090/metrics
```

---

## 🔄 Operations

### Scaling

```bash
# Manual scaling
kubectl scale deployment custody-engine -n settlement --replicas=10

# Check HPA status
kubectl get hpa -n settlement

# View autoscaler logs
kubectl logs -n kube-system -l app=cluster-autoscaler
```

### Rolling Updates

```bash
# Update image
kubectl set image deployment/custody-engine \
  custody-engine=settlement-engine/custody-engine:v1.1.0 \
  -n settlement

# Monitor rollout
kubectl rollout status deployment/custody-engine -n settlement

# Rollback if needed
kubectl rollout undo deployment/custody-engine -n settlement
```

### Backup & Restore

```bash
# RDS automated backups are enabled
# Manual snapshot
aws rds create-db-snapshot \
  --db-instance-identifier settlement-engine-production-postgres \
  --db-snapshot-identifier manual-snapshot-$(date +%Y%m%d)

# Restore from snapshot
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier settlement-engine-restored \
  --db-snapshot-identifier manual-snapshot-20240115
```

---

## 💰 Cost Optimization

### Estimated Monthly Costs (Production)

| Resource | Instance Type | Cost/Month |
|----------|---------------|------------|
| EKS Cluster | Control Plane | $72 |
| EKS Nodes (5x) | t3.xlarge | $750 |
| RDS | db.r6g.xlarge | $350 |
| Redis | cache.r6g.large | $200 |
| NAT Gateway (3x) | - | $100 |
| Data Transfer | ~1TB | $90 |
| **Total** | | **~$1,562/month** |

### Cost Savings

- Use Spot instances for non-critical workloads (60% savings)
- Enable RDS Reserved Instances (40% savings)
- Configure Cluster Autoscaler to scale down during off-hours
- Use S3 lifecycle policies for log retention

---

## 🧪 Testing

### Infrastructure Tests

```bash
# Validate Terraform
terraform validate
terraform fmt -check

# Plan with different environments
terraform plan -var-file=environments/dev.tfvars
terraform plan -var-file=environments/staging.tfvars
terraform plan -var-file=environments/production.tfvars
```

### Kubernetes Tests

```bash
# Dry-run deployments
kubectl apply -f deployments/ --dry-run=client

# Validate manifests
kubectl apply -f deployments/ --validate=true --dry-run=server
```

---

## 🚨 Troubleshooting

### Common Issues

**EKS nodes not joining cluster**
```bash
# Check IAM role permissions
aws eks describe-cluster --name settlement-engine-production-eks

# View node group status
aws eks describe-nodegroup \
  --cluster-name settlement-engine-production-eks \
  --nodegroup-name general
```

**Pods stuck in Pending**
```bash
# Check events
kubectl describe pod <pod-name> -n settlement

# Check resource availability
kubectl top nodes
kubectl describe nodes
```

**Database connection failures**
```bash
# Verify security group rules
aws ec2 describe-security-groups --group-ids <db-security-group-id>

# Test connection from pod
kubectl run -it --rm debug --image=postgres:15 --restart=Never -- \
  psql -h <db-endpoint> -U postgres
```

---

## 📝 Maintenance

### Regular Tasks

**Daily**
- Monitor CloudWatch dashboards
- Review autoscaling events
- Check pod health and restarts

**Weekly**
- Review RDS Performance Insights
- Update security group rules if needed
- Check for EKS/add-on updates

**Monthly**
- Review and optimize costs
- Update Kubernetes manifests
- Rotate access credentials
- Test disaster recovery procedures

---

## 🔗 Additional Resources

- [Terraform AWS Provider Docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/)
- [Kubernetes Documentation](https://kubernetes.io/docs/home/)
- [AWS Well-Architected Framework](https://aws.amazon.com/architecture/well-architected/)

---

**Last Updated**: January 2025
**Maintained By**: Infrastructure Team
**Version**: 1.0.0
