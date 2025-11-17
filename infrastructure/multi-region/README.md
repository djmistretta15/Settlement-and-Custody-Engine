# Multi-Region Deployment

Production-grade geographic redundancy and disaster recovery for the Settlement and Custody Engine.

## Architecture

```
                    ┌─────────────────────────────┐
                    │   AWS Global Accelerator    │
                    │      (Static Anycast IPs)   │
                    └─────────────┬───────────────┘
                                  │
         ┌────────────────────────┼────────────────────────┐
         │                        │                        │
    US-East-1              EU-West-1              AP-Southeast-1
    (Primary)              (Secondary)              (Tertiary)
         │                        │                        │
    ┌────▼────┐              ┌────▼────┐              ┌────▼────┐
    │   EKS   │              │   EKS   │              │   EKS   │
    │ Cluster │              │ Cluster │              │ Cluster │
    └────┬────┘              └────┬────┘              └────┬────┘
         │                        │                        │
    ┌────▼────┐              ┌────▼────┐              ┌────▼────┐
    │  Aurora │──Replication─│  Aurora │──Replication─│  Aurora │
    │ Primary │              │ Replica │              │ Replica │
    └─────────┘              └─────────┘              └─────────┘
```

## Features

- **AWS Global Accelerator**: Static anycast IPs with automatic routing to nearest healthy region
- **Aurora Global Database**: Sub-second cross-region replication
- **Automated Failover**: Health-based automatic failover with configurable thresholds
- **VPC Peering**: Secure cross-region communication
- **Centralized Monitoring**: CloudWatch dashboard for all regions

## Quick Start

### Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform 1.5.0+
- kubectl configured for EKS access

### Deployment

```bash
# 1. Initialize Terraform
cd terraform
terraform init

# 2. Plan deployment
terraform plan -var-file=production.tfvars

# 3. Apply configuration
terraform apply -var-file=production.tfvars

# 4. Configure kubectl for each cluster
aws eks update-kubeconfig --name settlement-engine-production-us-east --region us-east-1
aws eks update-kubeconfig --name settlement-engine-production-eu-west --region eu-west-1
aws eks update-kubeconfig --name settlement-engine-production-ap-southeast --region ap-southeast-1
```

### Variables

Create `production.tfvars`:

```hcl
environment                      = "production"
project_name                     = "settlement-engine"
domain_name                      = "settlement-engine.com"
enable_global_accelerator        = true
enable_cross_region_replication  = true
db_master_password               = "your-secure-password"
```

## Failover Manager

The TypeScript failover manager provides:

- **Health Monitoring**: Continuous health checks across all regions
- **Automatic Failover**: Intelligent failover based on failure thresholds
- **Database Promotion**: Automated Aurora replica promotion
- **Traffic Rerouting**: Dynamic traffic management via Global Accelerator
- **Rollback Support**: Safe rollback to previous configuration

### Usage

```typescript
import { FailoverManager, FailoverConfig } from './failover-manager';

const config: FailoverConfig = {
  healthCheckInterval: 30000,  // 30 seconds
  failureThreshold: 3,         // 3 consecutive failures
  recoveryThreshold: 5,        // 5 consecutive successes
  minHealthyRegions: 2,
  autoFailover: true,
  autoRecovery: true,
  cooldownPeriod: 300000,      // 5 minutes
};

const manager = new FailoverManager(config);

// Start monitoring
manager.startHealthMonitoring();

// Event handlers
manager.on('failoverInitiated', (event) => {
  console.log(`Failover: ${event.sourceRegion} → ${event.targetRegion}`);
});

manager.on('failoverCompleted', (event) => {
  console.log(`Failover completed in ${event.duration}ms`);
});
```

## Regions

| Region | Role | Database | Traffic Weight |
|--------|------|----------|----------------|
| US-East-1 | Primary | Read/Write | 100 |
| EU-West-1 | Secondary | Read-only replica | 100 |
| AP-Southeast-1 | Tertiary | Read-only replica | 100 |

## Failover Scenarios

### Automatic Failover

1. Health checks detect primary region failure
2. After N consecutive failures (configurable), failover initiates
3. Secondary region database is promoted to primary
4. DNS and Global Accelerator updated
5. Traffic rerouted to new primary

### Manual Failover

```typescript
const failoverEvent = await manager.initiateFailover('us-east-1');
console.log(`Failover completed: ${failoverEvent.status}`);
```

### Rollback

```typescript
await manager.initiateRollback(failoverEvent.id);
```

## Monitoring

### CloudWatch Dashboard

The Terraform configuration creates a comprehensive dashboard with:
- Database CPU utilization
- Global Accelerator traffic
- EKS node counts per region
- Cross-region latency

### Alerts

Configure CloudWatch alarms for:
- Database failover events
- High latency (>500ms cross-region)
- Node count below minimum
- Health check failures

## Disaster Recovery

### RTO (Recovery Time Objective)

- Automatic failover: 2-5 minutes
- Manual failover: 5-10 minutes
- Database promotion: ~2 minutes

### RPO (Recovery Point Objective)

- Aurora Global Database: <1 second replication lag
- Asynchronous replication with sub-second latency

## Cost Estimation

| Component | Monthly Cost (Est.) |
|-----------|---------------------|
| Global Accelerator | $18 + $0.015/GB |
| Aurora Primary (3 instances) | $1,200 |
| Aurora Secondary EU (2 instances) | $600 |
| Aurora Secondary AP (2 instances) | $600 |
| EKS Clusters (3) | $219 |
| VPC Peering | Data transfer costs |
| **Total** | ~$2,800/month |

## Security

- All database traffic encrypted with TLS
- VPC peering with private routing
- IAM roles for cross-region access
- KMS encryption for data at rest
- Network policies restricting cross-VPC traffic

## File Structure

```
infrastructure/multi-region/
├── terraform/
│   └── main.tf                    # Main Terraform configuration (800+ LoC)
├── failover-manager.ts            # Failover orchestration (700+ LoC)
├── package.json                   # Dependencies
└── README.md                      # This documentation
```

**Total Lines of Code: 1,500+**

## Best Practices

1. **Test failover regularly** - Monthly DR drills
2. **Monitor replication lag** - Alert on >100ms lag
3. **Maintain capacity** - Keep secondary regions warm
4. **Document runbooks** - Clear procedures for manual intervention
5. **Review costs** - Optimize instance sizes based on load

---

**Version**: 1.0.0
**Last Updated**: January 2024
