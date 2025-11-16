# Kong API Gateway for Settlement and Custody Engine

Production-grade API management infrastructure providing security, rate limiting, observability, and traffic management for the Settlement and Custody Engine.

## Overview

This Kong API Gateway configuration delivers enterprise-grade API management with:

- **Multi-tier Rate Limiting**: Per-consumer, per-service, and global rate limits
- **JWT/API Key Authentication**: Secure authentication with signature verification
- **Request Validation**: Schema-based validation for settlement requests
- **Circuit Breaking**: Automatic failover and service protection
- **Load Balancing**: Health-check-based load distribution
- **Observability**: Comprehensive metrics, logging, and alerting
- **Security Headers**: OWASP-compliant security configurations

## Architecture

```
                          ┌─────────────────────┐
                          │   Load Balancer     │
                          │  (AWS NLB/ALB)      │
                          └─────────┬───────────┘
                                    │
                          ┌─────────▼───────────┐
                          │   Kong Gateway      │
                          │   (3+ replicas)     │
                          └─────────┬───────────┘
                                    │
         ┌──────────────────────────┼──────────────────────────┐
         │                          │                          │
┌────────▼────────┐      ┌──────────▼────────┐      ┌─────────▼─────────┐
│  Settlement     │      │   Custody         │      │   Finality        │
│   Service       │      │    Service        │      │    Service        │
│  (3 replicas)   │      │  (2 replicas)     │      │  (2 replicas)     │
└─────────────────┘      └───────────────────┘      └───────────────────┘
```

## Quick Start

### Local Development

```bash
# 1. Set environment variables
export KONG_PG_PASSWORD=your_secure_password
export REDIS_PASSWORD=your_redis_password
export GRAFANA_PASSWORD=your_grafana_password

# 2. Start all services
docker-compose up -d

# 3. Wait for services to be healthy
docker-compose ps

# 4. Access services
# Kong Proxy: http://localhost:8000
# Kong Admin: http://localhost:8001
# Kong Manager: http://localhost:8002
# Konga Dashboard: http://localhost:1337
# Analytics: http://localhost:8080
# Prometheus: http://localhost:9090
# Grafana: http://localhost:3100
```

### Kubernetes Deployment

```bash
# 1. Create namespace
kubectl create namespace kong-gateway

# 2. Create secrets
kubectl create secret generic kong-secrets \
  --from-literal=REDIS_PASSWORD=$REDIS_PASSWORD \
  --from-literal=ANALYTICS_TOKEN=$ANALYTICS_TOKEN \
  -n kong-gateway

# 3. Apply configuration
kubectl apply -f kubernetes/kong-deployment.yaml

# 4. Verify deployment
kubectl get pods -n kong-gateway
kubectl get services -n kong-gateway

# 5. Get external endpoint
kubectl get svc kong-proxy -n kong-gateway
```

## Configuration

### Services

| Service | URL | Timeout | Retries | Purpose |
|---------|-----|---------|---------|---------|
| Settlement Engine | settlement-engine:3000 | 60s | 3 | Cross-chain settlement processing |
| Custody Engine | custody-engine:3001 | 120s | 2 | Multi-sig vault operations |
| Finality Verifier | finality-verifier:3002 | 30s | 5 | Chain finality verification |
| KYC Service | kyc-service:3003 | 60s | 2 | Compliance and credential checks |

### Rate Limits

| Consumer Type | Requests/Second | Requests/Minute | Requests/Hour |
|---------------|-----------------|-----------------|---------------|
| **Global** | 100 | 3,000 | 50,000 |
| **Institutional** | 1,000 | 30,000 | 500,000 |
| **Retail** | 50 | 1,500 | 25,000 |
| **Internal** | 10,000 | 600,000 | 36,000,000 |

### Plugins

**Global Plugins:**
- Rate Limiting (Redis-backed)
- Request Size Limiting (10MB max)
- CORS
- Request/Response Transformation
- HTTP Logging
- Prometheus Metrics
- Bot Detection
- Security Headers

**Service-Specific Plugins:**
- JWT Authentication (Settlement Service)
- Request Validation (Settlement Service)
- Stricter Rate Limiting (Custody Service)
- ACL Authorization (Custody Service)
- Proxy Caching (Finality Service)
- Response Masking (KYC Service)

## Custom Plugins

### Settlement Authentication Plugin

**Features:**
- API Key + Signature verification
- HMAC-SHA256 request signing
- Timestamp-based replay protection
- Institutional client identification
- Audit logging

**Usage:**
```bash
# Request signing example
TIMESTAMP=$(date +%s)
MESSAGE="${TIMESTAMP}.{\"sender\":\"0x123...\",\"amount\":\"1000\"}"
SIGNATURE=$(echo -n "$MESSAGE" | openssl dgst -sha256 -hmac "$SECRET" | cut -d' ' -f2)

curl -X POST https://api.settlement-engine.com/api/v1/settlements \
  -H "X-API-Key: inst_sk_live_xxx" \
  -H "X-Settlement-Timestamp: $TIMESTAMP" \
  -H "X-Settlement-Signature: $SIGNATURE" \
  -d '{"sender": "0x123...", "amount": "1000"}'
```

### Settlement Validator Plugin

**Validations:**
- Ethereum address format (0x + 40 hex chars)
- Amount range (minimum to uint256 max)
- Chain ID whitelist (Ethereum, Polygon, Arbitrum, Optimism, Base)
- Blocked address screening (sanctions compliance)
- Same-chain restriction enforcement
- KYC verification integration

**Error Response Example:**
```json
{
  "error": "VALIDATION_ERROR",
  "field": "amount",
  "message": "Amount is below minimum threshold"
}
```

## Monitoring

### Analytics Service

The analytics service provides real-time metrics and alerting:

```bash
# Get current metrics
curl http://localhost:8080/metrics

# Get recent logs
curl http://localhost:8080/logs?count=100

# Get active alerts
curl http://localhost:8080/alerts

# Prometheus-compatible endpoint
curl http://localhost:8080/prometheus
```

**Metrics:**
- Total requests
- Success/failure rates
- Latency percentiles (p50, p95, p99)
- Bandwidth (ingress/egress)
- Requests by service, consumer, status code
- Error categorization

**Alerts:**
- High error rate (>5%)
- High P99 latency (>5s)
- Excessive rate limiting (>10% blocked)
- Server errors (>10 occurrences)

### Grafana Dashboard

Pre-configured dashboard includes:
- Request rate (5-minute average)
- Error rate gauge
- P99 latency
- Bandwidth utilization
- Latency distribution (P50, P95, P99)
- Response status code breakdown
- Requests by service
- Requests by consumer
- Top 10 routes by volume

**Access:** http://localhost:3100 (admin/settlement_grafana)

### Prometheus Metrics

Kong exposes 100+ metrics including:
- `kong_http_requests_total`
- `kong_latency_ms`
- `kong_bandwidth_bytes`
- `kong_upstream_target_health`
- Custom settlement metrics

## Security

### OWASP Compliance

Security headers automatically added:
- `Strict-Transport-Security` (HSTS)
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `X-XSS-Protection: 1; mode=block`
- `Content-Security-Policy`
- `Referrer-Policy`

### Request Signing

All settlement requests require:
1. Valid API key
2. Request timestamp (within 5 minutes)
3. HMAC-SHA256 signature of timestamp + body

### IP Restriction

Optional IP whitelisting for production:
```yaml
- name: ip-restriction
  enabled: true
  config:
    allow:
      - 10.0.0.0/8
      - 172.16.0.0/12
```

## High Availability

### Kubernetes Configuration

- **Replicas**: 3 minimum (scales to 20)
- **HPA**: Auto-scale on CPU (70%) and Memory (80%)
- **PDB**: Minimum 2 pods available during maintenance
- **Anti-affinity**: Pods spread across nodes
- **Health Checks**: Liveness and readiness probes

### Load Balancing

- **Algorithm**: Round-robin with health checks
- **Active Health Checks**: HTTP GET /health every 10s
- **Passive Health Checks**: Track success/failure rates
- **Circuit Breaker**: Automatic failover on 3 consecutive failures

### Redis HA

Rate limiting uses Redis with:
- Persistence (AOF)
- LRU eviction policy
- 2GB memory limit
- Automatic reconnection

## API Versioning

```
/api/v1/settlements  - Current stable version
/api/v2/settlements  - Next version (when available)
```

Versioning strategy:
- URL path versioning (`/api/v1/`, `/api/v2/`)
- Header versioning support (`Accept-Version`)
- Backward compatibility maintained
- Deprecation notices via response headers

## Performance

### Benchmarks

Expected performance (3-node Kong cluster):
- **Throughput**: 10,000+ requests/second
- **Latency (P99)**: <50ms (excluding backend)
- **Memory**: 512MB-2GB per instance
- **CPU**: 2-4 cores per instance

### Optimization Tips

1. **Enable proxy caching** for read-heavy endpoints
2. **Use Redis clustering** for high-volume rate limiting
3. **Adjust worker processes** based on CPU cores
4. **Enable keepalive** connections to upstream
5. **Use gzip compression** for large responses

## Troubleshooting

### Common Issues

**1. Rate Limit Exceeded (429)**
```bash
# Check rate limit headers
curl -I http://localhost:8000/api/v1/settlements
# X-RateLimit-Limit-Second: 100
# X-RateLimit-Remaining-Second: 95
```

**2. Authentication Failed (401)**
- Verify API key format
- Check signature calculation
- Ensure timestamp is fresh (<5 minutes)

**3. Validation Error (400)**
- Review request body schema
- Check address format (0x + 40 hex)
- Verify chain ID is allowed

**4. Service Unavailable (503)**
- Check upstream health
- Review circuit breaker status
- Verify network connectivity

### Debugging

```bash
# Check Kong logs
docker logs kong-gateway -f

# Admin API status
curl http://localhost:8001/status

# Check upstream health
curl http://localhost:8001/upstreams/settlement-upstream/health

# Validate configuration
kong config parse /opt/kong/kong.yml
```

## Deployment Checklist

### Pre-Production

- [ ] Configure TLS certificates
- [ ] Set strong Redis password
- [ ] Enable IP restriction whitelist
- [ ] Configure alert notifications (PagerDuty, Slack)
- [ ] Review rate limits for expected traffic
- [ ] Set up log aggregation (ELK, CloudWatch)
- [ ] Configure backup for Redis persistence
- [ ] Test failover scenarios
- [ ] Load test with realistic traffic patterns

### Production

- [ ] Enable HTTPS-only traffic
- [ ] Configure DDoS protection
- [ ] Set up WAF (Web Application Firewall)
- [ ] Enable audit logging
- [ ] Configure secrets rotation
- [ ] Set up monitoring dashboards
- [ ] Configure auto-scaling policies
- [ ] Enable multi-region deployment (optional)

## File Structure

```
infrastructure/kong/
├── kong.yml                          # Main Kong declarative config (900+ LoC)
├── docker-compose.yml                # Local development setup (200+ LoC)
├── README.md                         # This documentation
├── kubernetes/
│   └── kong-deployment.yaml          # K8s manifests (600+ LoC)
├── plugins/
│   ├── settlement-auth.lua           # Custom auth plugin (400+ LoC)
│   └── settlement-validator.lua      # Request validation (500+ LoC)
├── analytics/
│   └── server.js                     # Log aggregation service (600+ LoC)
└── monitoring/
    ├── prometheus.yml                # Prometheus config (100+ LoC)
    └── grafana/
        ├── dashboards/
        │   └── kong-dashboard.json   # Grafana dashboard
        └── datasources/
            └── prometheus.yml        # Datasource config
```

**Total Lines of Code: 3,300+**

## Integration with Settlement Engine

```typescript
// Example: Creating a settlement via Kong Gateway
import axios from 'axios';
import crypto from 'crypto';

const API_KEY = process.env.SETTLEMENT_API_KEY;
const API_SECRET = process.env.SETTLEMENT_API_SECRET;
const GATEWAY_URL = 'https://api.settlement-engine.com';

async function createSettlement(settlement) {
  const timestamp = Math.floor(Date.now() / 1000);
  const body = JSON.stringify(settlement);
  const message = `${timestamp}.${body}`;

  const signature = crypto
    .createHmac('sha256', API_SECRET)
    .update(message)
    .digest('hex');

  const response = await axios.post(
    `${GATEWAY_URL}/api/v1/settlements`,
    settlement,
    {
      headers: {
        'Content-Type': 'application/json',
        'X-API-Key': API_KEY,
        'X-Settlement-Timestamp': timestamp,
        'X-Settlement-Signature': signature,
      },
    }
  );

  return response.data;
}

// Usage
const settlement = {
  sender: '0x742d35Cc6634C0532925a3b844Bc9e7595f8fE2',
  receiver: '0x8ba1f109551bD432803012645Ac136ddd64DBA72',
  amount: '1000000000000000000', // 1 ETH
  sourceChain: 1,  // Ethereum
  destChain: 137,  // Polygon
};

createSettlement(settlement)
  .then(result => console.log('Settlement created:', result))
  .catch(error => console.error('Error:', error.response?.data));
```

## Support

- **Documentation**: This README and inline code comments
- **Monitoring**: Grafana dashboard at http://localhost:3100
- **Logs**: `docker logs kong-gateway` or Kubernetes logs
- **Metrics**: http://localhost:8080/metrics (analytics service)
- **Health**: http://localhost:8000/health

---

**Version**: 1.0.0
**Last Updated**: January 2024
**Maintainer**: Infrastructure Team
