# CI/CD Pipeline Documentation
## Settlement and Custody Engine

Production-grade CI/CD pipeline using GitHub Actions for automated testing, security scanning, and deployment.

---

## 📁 Workflow Files

```
.github/workflows/
├── ci.yml          # Continuous Integration (build, test, scan)
├── cd.yml          # Continuous Deployment (staging, canary, production)
├── security.yml    # Security scanning (SAST, DAST, secrets)
└── README.md       # This documentation
```

---

## 🔄 Pipeline Overview

### Continuous Integration (`ci.yml`)

**Triggers**:
- Push to `main`, `develop`, `release/**`
- Pull requests to `main`, `develop`
- Manual workflow dispatch

**Jobs**:

| Job | Purpose | Duration |
|-----|---------|----------|
| `smart-contracts` | Compile, test, fuzz (100k runs) | ~10 min |
| `security-scan` | Slither + Mythril analysis | ~15 min |
| `backend-services` | TypeScript tests with PostgreSQL/Redis | ~5 min |
| `zk-circuits` | Circom compilation and verification | ~8 min |
| `docker-build` | Multi-service container builds | ~12 min |
| `quality-gate` | Final validation checkpoint | ~2 min |

**Features**:
- Matrix testing (unit, fuzz, invariant, gas)
- 10,000+ fuzz runs (100k on manual trigger)
- Gas regression detection
- Coverage enforcement (80% minimum)
- SARIF security reports

### Continuous Deployment (`cd.yml`)

**Triggers**:
- Version tags (`v*`)
- Manual workflow dispatch with environment selection

**Deployment Strategy**:

```
Pre-Checks → Staging → Canary (10%) → Full Production
     ↓           ↓           ↓              ↓
   Validate   Smoke Test   Monitor      Health Check
```

**Environments**:
- **Staging**: All changes deployed automatically
- **Production-Canary**: 10% traffic for 10 minutes
- **Production**: Full rollout after canary success

**Features**:
- Zero-downtime rolling updates
- Automatic rollback on canary failure
- Post-deployment validation
- Slack notifications
- GitHub release creation

### Security Scanning (`security.yml`)

**Triggers**:
- Daily at 2 AM UTC (scheduled)
- Push to `main`
- Pull requests to `main`

**Scans**:

| Scan Type | Tool | Target |
|-----------|------|--------|
| Dependency Audit | NPM, Snyk, OWASP | Dependencies |
| SAST | CodeQL, Semgrep | Source code |
| Smart Contracts | Slither, Mythril | Solidity |
| Infrastructure | tfsec, Checkov, Kubesec | Terraform/K8s |
| Secrets | TruffleHog, Gitleaks | All files |

---

## 🚀 Quick Start

### Running CI Pipeline

```bash
# Automatic on push/PR
git push origin feature-branch

# Manual with custom fuzz runs
gh workflow run ci.yml -f fuzz_runs=50000
```

### Deploying to Production

```bash
# Create release tag
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0

# Manual deployment
gh workflow run cd.yml -f environment=production -f version=v1.0.0
```

### Running Security Scan

```bash
# Manual trigger
gh workflow run security.yml

# Check results
gh run view --log
```

---

## ⚙️ Configuration

### Required Secrets

Configure in repository settings → Secrets and variables → Actions:

```
# AWS Deployment
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_DEPLOY_ROLE_ARN

# Container Registry
GITHUB_TOKEN (automatic)

# Security Tools
SNYK_TOKEN
SONAR_TOKEN (optional)

# Notifications
SLACK_WEBHOOK_URL

# External Services
ETHERSCAN_API_KEY
ARBISCAN_API_KEY
MAINNET_RPC_URL
```

### Environment Protection

Configure environments with required reviewers:

- **staging**: Automatic deployment
- **production-canary**: Requires 1 reviewer
- **production**: Requires 2 reviewers + manager approval

### Branch Protection

Recommended settings for `main`:

- ✅ Require pull request reviews (2 reviewers)
- ✅ Require status checks to pass
- ✅ Require branches to be up to date
- ✅ Require signed commits
- ✅ Include administrators

Required status checks:
- `smart-contracts (unit)`
- `smart-contracts (fuzz)`
- `security-scan`
- `backend-services`
- `quality-gate`

---

## 📊 Quality Gates

### Automatic Failure Conditions

| Check | Threshold | Action |
|-------|-----------|--------|
| Critical vulnerabilities | > 0 | Block merge |
| High vulnerabilities | > 5 | Warning |
| Code coverage | < 80% | Block merge |
| Gas regression | > 10% | Warning |
| Canary error rate | > 5% | Auto-rollback |

### Performance Benchmarks

| Metric | Target | Actual |
|--------|--------|--------|
| CI pipeline duration | < 15 min | ~12 min |
| Deployment to staging | < 5 min | ~3 min |
| Production canary | 10 min observation | ✅ |
| Full production rollout | < 10 min | ~8 min |

---

## 🔒 Security Features

### Smart Contract Scanning

```yaml
- Slither static analysis
  - Reentrancy detection
  - Unchecked transfers
  - Arbitrary sends
  - Locked ether
  - Uninitialized state

- Mythril symbolic execution
  - Integer overflow/underflow
  - Delegatecall vulnerabilities
  - Self-destruct risks

- Foundry invariant testing
  - Critical property validation
  - Stateful fuzzing
```

### Infrastructure Security

```yaml
- Terraform security (tfsec)
  - AWS best practices
  - Encryption validation
  - IAM policy review

- Kubernetes security (Kubesec)
  - Pod security policies
  - Resource limits
  - Network policies

- Secret detection
  - Pre-commit hooks
  - Git history scanning
  - Entropy analysis
```

---

## 🐛 Troubleshooting

### Common Issues

**CI Pipeline Fails on Fuzz Test**

```bash
# Reproduce with same seed
forge test --fuzz-seed <seed_from_log>

# Increase timeout
forge test --fuzz-runs 10000 --timeout 600
```

**Docker Build Cache Miss**

```bash
# Clear and rebuild
docker builder prune
gh workflow run ci.yml
```

**Canary Deployment Fails**

```bash
# Check metrics
kubectl logs -n settlement -l track=canary

# Manual rollback
kubectl delete deployment custody-engine-canary -n settlement
```

**Security Scan False Positive**

Add to `.slither.config.json`:
```json
{
  "detectors_to_exclude": ["low-level-calls"],
  "filter_paths": ["node_modules", "lib"]
}
```

---

## 📈 Metrics & Monitoring

### CI/CD Metrics

- **Pipeline success rate**: Target > 95%
- **Mean time to recovery**: < 30 minutes
- **Deployment frequency**: Multiple per day
- **Change failure rate**: < 5%

### Dashboard

Monitor at: https://github.com/org/repo/actions

Key indicators:
- Recent workflow runs
- Average duration trends
- Failure patterns
- Resource utilization

---

## 🔄 Maintenance

### Weekly Tasks

- [ ] Review security scan results
- [ ] Update dependencies
- [ ] Check for deprecated actions
- [ ] Review gas snapshots

### Monthly Tasks

- [ ] Rotate secrets
- [ ] Update base images
- [ ] Performance optimization review
- [ ] Disaster recovery drill

### Quarterly Tasks

- [ ] Action version upgrades
- [ ] Security audit
- [ ] Pipeline efficiency review
- [ ] Documentation update

---

## 🎯 Roadmap

### Coming Soon

- [ ] Multi-region deployment support
- [ ] Blue/green deployment strategy
- [ ] A/B testing framework
- [ ] Performance regression testing
- [ ] Load testing integration

### Future Enhancements

- [ ] GitOps with ArgoCD
- [ ] Service mesh integration
- [ ] Chaos engineering
- [ ] ML-based anomaly detection

---

**Pipeline Version**: 1.0.0
**Last Updated**: January 2025
**Maintained By**: Infrastructure Team

---

*This CI/CD pipeline represents production-grade DevOps practices for mission-critical financial infrastructure.*
