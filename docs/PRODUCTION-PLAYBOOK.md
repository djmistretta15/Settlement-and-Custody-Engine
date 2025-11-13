# Production Deployment Playbook
## Decentralized Settlement and Custody Engine

**Version**: 1.0.0
**Last Updated**: January 2024
**Maintainer**: Infrastructure Team

---

## Table of Contents

1. [Pre-Deployment Checklist](#pre-deployment-checklist)
2. [Infrastructure Setup](#infrastructure-setup)
3. [Smart Contract Deployment](#smart-contract-deployment)
4. [ZK Circuit Setup](#zk-circuit-setup)
5. [Backend Services Deployment](#backend-services-deployment)
6. [Monitoring & Alerting](#monitoring--alerting)
7. [Security Hardening](#security-hardening)
8. [Disaster Recovery](#disaster-recovery)
9. [Runbook](#runbook)

---

## Pre-Deployment Checklist

### ✅ Code Quality
- [ ] All tests passing (unit, integration, e2e)
- [ ] Code coverage > 80%
- [ ] Security audits completed (Trail of Bits, OpenZeppelin)
- [ ] Formal verification passed (Certora)
- [ ] Static analysis clean (Slither, Mythril)
- [ ] Gas optimization verified
- [ ] Documentation up-to-date

### ✅ Infrastructure
- [ ] AWS/GCP account configured
- [ ] Domain and SSL certificates ready
- [ ] Redis cluster provisioned
- [ ] PostgreSQL database with replication
- [ ] S3/GCS for backups
- [ ] CloudWatch/Stackdriver logging
- [ ] PagerDuty integration configured

### ✅ Security
- [ ] Hardware Security Modules (HSMs) procured
- [ ] Multi-signature wallets configured (3-of-5)
- [ ] Private keys generated in air-gapped environment
- [ ] Key shares distributed to signers
- [ ] Emergency response team identified
- [ ] Bug bounty program launched (Immunefi)

### ✅ Compliance
- [ ] Legal review completed
- [ ] Terms of Service finalized
- [ ] Privacy Policy published
- [ ] KYC/AML procedures documented
- [ ] Regulatory licenses obtained (if required)

---

## Infrastructure Setup

### Step 1: Provision Cloud Resources

```bash
# AWS Example
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Verify resources
aws ec2 describe-instances --filters "Name=tag:Project,Values=SettlementEngine"
aws rds describe-db-instances --db-instance-identifier settlement-postgres
```

### Step 2: Configure Kubernetes Cluster (Production)

```bash
# Create EKS cluster
eksctl create cluster \
  --name settlement-engine-prod \
  --version 1.28 \
  --region us-east-1 \
  --nodegroup-name standard-workers \
  --node-type t3.xlarge \
  --nodes 3 \
  --nodes-min 3 \
  --nodes-max 10 \
  --managed

# Install ingress controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/aws/deploy.yaml

# Install cert-manager for SSL
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
```

### Step 3: Setup Secrets Management

```bash
# AWS Secrets Manager
aws secretsmanager create-secret \
  --name settlement-engine/private-keys \
  --secret-string file://secrets.json

# Kubernetes secrets
kubectl create secret generic settlement-secrets \
  --from-env-file=.env.production \
  --namespace settlement-engine
```

---

## Smart Contract Deployment

### Step 1: Deploy to Testnet (Sepolia)

```bash
# Compile contracts
npm run compile:hardhat

# Run deployment script
npx hardhat run scripts/deploy.ts --network sepolia

# Verify contracts
npx hardhat verify --network sepolia \
  $SETTLEMENT_ENGINE_ADDRESS \
  $LIGHT_CLIENT_ADDRESS \
  $VAULT_ADDRESS \
  $KYC_REGISTRY_ADDRESS
```

### Step 2: Testnet Validation

```bash
# Run integration tests against testnet
npm run test:testnet

# Simulate settlement flows
npm run simulate:cross-chain-settlement

# Verify finality proofs
npm run verify:finality-proofs
```

### Step 3: Mainnet Deployment (CRITICAL)

**⚠️ WARNING: Triple-check all parameters before mainnet deployment**

```bash
# Final checklist
- [ ] All constructor parameters verified
- [ ] Multi-sig owners confirmed
- [ ] Gas price appropriate
- [ ] Sufficient ETH for deployment
- [ ] Backup plan in place

# Deploy to mainnet
export NETWORK=mainnet
npx hardhat run scripts/deploy-mainnet.ts --network $NETWORK

# IMMEDIATELY verify on Etherscan
npx hardhat verify --network $NETWORK $CONTRACT_ADDRESS [args]

# Transfer ownership to multi-sig
npx hardhat run scripts/transfer-ownership.ts --network $NETWORK
```

### Step 4: Contract Initialization

```bash
# Initialize contracts (via multi-sig)
1. Register verifying keys for each chain
2. Add initial relayers
3. Set finality thresholds
4. Create initial vaults
5. Issue first KYC credentials (test users)

# Verify initialization
npx hardhat run scripts/verify-init.ts --network $NETWORK
```

---

## ZK Circuit Setup

### Step 1: Trusted Setup Ceremony

```bash
# Powers of Tau (Phase 1 - Universal)
# Use existing ceremony or conduct new one
wget https://hermez.s3-eu-west-1.amazonaws.com/powersOfTau28_hez_final_16.ptau

# Phase 2 - Circuit-specific setup
cd zk-circuits
./compile.sh

# Multi-party ceremony (3-5 participants minimum)
for i in {1..5}; do
  snarkjs zkey contribute \
    finality_${i}.zkey \
    finality_$((i+1)).zkey \
    --name="Participant $i" \
    -v
done

# Verify ceremony
snarkjs zkey verify \
  finality.r1cs \
  powersOfTau28_hez_final_16.ptau \
  finality_final.zkey
```

### Step 2: Export Verification Key

```bash
# Generate Solidity verifier
snarkjs zkey export solidityverifier \
  finality_final.zkey \
  ../contracts/solidity/finality/FinalityVerifier.sol

# Deploy verifier contract
npx hardhat run scripts/deploy-verifier.ts --network $NETWORK
```

### Step 3: Generate Test Proofs

```bash
# Generate and verify test proof
npm run zk:test-proof

# Expected output:
# ✓ Proof generated successfully
# ✓ Proof verified successfully
# ✓ On-chain verification passed
```

---

## Backend Services Deployment

### Step 1: Build Docker Images

```bash
# Build all images
docker-compose build

# Tag for registry
docker tag settlement-custody-engine:latest \
  registry.example.com/settlement/custody-engine:v1.0.0

# Push to registry
docker push registry.example.com/settlement/custody-engine:v1.0.0
```

### Step 2: Deploy with Docker Compose (Staging)

```bash
# Copy environment file
cp .env.example .env.production
# Edit .env.production with production values

# Start services
docker-compose -f docker-compose.yml -f docker-compose.prod.yml up -d

# Check health
docker-compose ps
docker-compose logs -f custody-engine
```

### Step 3: Deploy to Kubernetes (Production)

```bash
# Apply Kubernetes manifests
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmaps/
kubectl apply -f k8s/secrets/
kubectl apply -f k8s/deployments/
kubectl apply -f k8s/services/
kubectl apply -f k8s/ingress.yaml

# Verify deployments
kubectl get pods -n settlement-engine
kubectl get svc -n settlement-engine

# Check logs
kubectl logs -f deployment/custody-engine -n settlement-engine
```

---

## Monitoring & Alerting

### Step 1: Prometheus Setup

```yaml
# prometheus-config.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'settlement-engine'
    static_configs:
      - targets: ['api-rest:3000', 'custody-engine:3001']

  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']
```

### Step 2: Grafana Dashboards

Import dashboards:
1. **Settlement Engine Overview** (ID: 12345)
2. **Custody Operations** (ID: 12346)
3. **Cross-Chain Finality** (ID: 12347)
4. **Security Alerts** (ID: 12348)

### Step 3: PagerDuty Integration

```bash
# Create PagerDuty service
curl -X POST https://api.pagerduty.com/services \
  -H 'Authorization: Token token=YOUR_API_KEY' \
  -H 'Content-Type: application/json' \
  -d '{
    "service": {
      "name": "Settlement Engine",
      "escalation_policy": {"id": "POLICY_ID", "type": "escalation_policy_reference"}
    }
  }'

# Configure alerts
kubectl apply -f k8s/alertmanager-config.yaml
```

---

## Security Hardening

### Network Security

```bash
# Configure VPC and security groups
- Allow only necessary ports (80, 443, 22 from bastion)
- Enable VPC Flow Logs
- Configure WAF rules
- Enable DDoS protection (AWS Shield/Cloudflare)

# Firewall rules
sudo ufw enable
sudo ufw allow 22/tcp   # SSH (from bastion only)
sudo ufw allow 80/tcp   # HTTP
sudo ufw allow 443/tcp  # HTTPS
sudo ufw deny 3000/tcp  # Block direct API access
```

### Application Security

```bash
# Enable rate limiting
- API: 100 req/min per IP
- GraphQL: Query complexity limits
- Settlement: 10 per hour per address

# Configure CORS
ALLOWED_ORIGINS=https://app.yourdomain.com,https://dashboard.yourdomain.com

# Enable security headers
Strict-Transport-Security: max-age=31536000; includeSubDomains
X-Frame-Options: DENY
X-Content-Type-Options: nosniff
Content-Security-Policy: default-src 'self'
```

### Audit Logging

```bash
# Enable comprehensive logging
LOG_LEVEL=info
AUDIT_LOG_ENABLED=true
AUDIT_LOG_RETENTION=90  # days

# Ship logs to SIEM
- AWS CloudWatch Logs
- Datadog
- Splunk
```

---

## Disaster Recovery

### Backup Strategy

```bash
# Database backups (daily)
pg_dump settlement_engine | gzip > backup_$(date +%Y%m%d).sql.gz
aws s3 cp backup_$(date +%Y%m%d).sql.gz s3://settlement-backups/

# Contract state backups (hourly)
npm run backup:contract-state

# Redis backups (every 6 hours)
redis-cli BGSAVE
```

### Recovery Procedures

#### Scenario 1: Database Failure

```bash
# 1. Promote read replica to primary
aws rds promote-read-replica --db-instance-identifier settlement-postgres-replica

# 2. Update connection strings
kubectl set env deployment/api-rest \
  POSTGRES_URL=postgresql://user:pass@new-primary:5432/db

# 3. Verify data integrity
npm run verify:database-integrity
```

#### Scenario 2: Contract Exploit

```bash
# 1. IMMEDIATE: Trigger emergency pause
cast send $SETTLEMENT_ENGINE_ADDRESS \
  "emergencyPause()" \
  --private-key $EMERGENCY_KEY

# 2. Assess damage
npm run audit:contract-state

# 3. Prepare hotfix
# 4. Deploy new contracts
# 5. Migrate state (if possible)
# 6. Resume operations
```

#### Scenario 3: Key Compromise

```bash
# 1. Freeze all affected vaults
# 2. Rotate compromised keys
# 3. Transfer funds to new vault
# 4. Notify users
# 5. Post-mortem analysis
```

---

## Runbook

### Common Operations

#### Check System Health

```bash
# Overall system status
curl https://api.yourdomain.com/health

# Individual services
docker-compose ps
kubectl get pods -n settlement-engine

# Database connectivity
psql -h localhost -U settlement_admin -c "SELECT 1"
```

#### Restart Services

```bash
# Docker Compose
docker-compose restart custody-engine

# Kubernetes
kubectl rollout restart deployment/custody-engine -n settlement-engine
```

#### View Logs

```bash
# Docker
docker-compose logs -f --tail=100 custody-engine

# Kubernetes
kubectl logs -f deployment/custody-engine -n settlement-engine --tail=100

# Grep for errors
kubectl logs deployment/custody-engine -n settlement-engine | grep ERROR
```

#### Scale Services

```bash
# Kubernetes horizontal scaling
kubectl scale deployment/custody-engine --replicas=5 -n settlement-engine

# Verify scaling
kubectl get hpa -n settlement-engine
```

---

## Emergency Contacts

| Role | Name | Phone | Email |
|------|------|-------|-------|
| On-Call Engineer | - | - | oncall@yourdomain.com |
| Security Lead | - | - | security@yourdomain.com |
| CTO | - | - | cto@yourdomain.com |
| AWS Support | - | - | Case via Console |

---

## Post-Deployment Checklist

- [ ] All services healthy
- [ ] Monitoring dashboards configured
- [ ] Alerts firing correctly
- [ ] Backup jobs running
- [ ] Security scans passed
- [ ] Performance benchmarks met
- [ ] Documentation updated
- [ ] Team trained on runbook
- [ ] Incident response plan tested

---

**🎉 Deployment Complete!**

Monitor the system closely for the first 72 hours. Run synthetic transactions to verify end-to-end functionality.

---

*Last Updated: January 2024*
*Version: 1.0.0*
*Maintained by: Infrastructure Team*
