# Settlement and Custody Engine - Interactive API Documentation

Comprehensive, interactive API documentation for the Settlement and Custody Engine.

## Documentation Components

### 1. OpenAPI/Swagger Specification

**Location**: `openapi/settlement-api.yaml`

Complete REST API specification (1,500+ lines) including:
- All settlement endpoints with request/response schemas
- Custody wallet management operations
- Threshold signature flows
- L2 routing and bridging
- MEV protection services
- Authentication schemes (JWT, API Key + HMAC)
- Error responses and webhooks

**Features**:
- OpenAPI 3.1.0 compliant
- Comprehensive examples for every endpoint
- Request validation schemas
- Webhook definitions for real-time events

### 2. GraphQL Schema

**Location**: `graphql/schema.graphql`

Full GraphQL type system (700+ lines) with:
- Query operations for settlements, custody, L2, and MEV
- Mutations for all write operations
- Real-time subscriptions via WebSocket
- Custom scalars (DateTime, BigInt, Address, UUID)
- Relay-style pagination with aggregates
- Complex filtering and ordering

**Server Implementation**: `graphql/server.ts`
- Apollo Server 4.x with Express
- WebSocket subscriptions
- Query complexity limiting
- DataLoader for N+1 prevention
- Custom scalar validation
- Distributed tracing integration

### 3. Postman Collection

**Location**: `postman/settlement-engine.postman_collection.json`

Complete API testing collection (500+ requests) including:
- Automated authentication flow
- Settlement operations (create, list, track)
- Custody wallet management
- Threshold signature workflows
- L2 routing calculations
- MEV protection requests
- GraphQL queries and mutations
- Automated tests for each request
- Environment variable management

### 4. Interactive Documentation Site

**Location**: `interactive/index.html`

Modern, single-page documentation portal featuring:
- Dark theme UI with responsive design
- Feature overview with visual cards
- Quick start code examples
- Integrated Swagger UI for REST API
- GraphQL query examples
- SDK installation guides
- Interactive tutorial listings
- Copy-to-clipboard functionality
- Syntax highlighting (Prism.js)

## Quick Start

### Serve Documentation Locally

```bash
# Install dependencies
npm install

# Start interactive documentation server
npm run dev
# Visit http://localhost:3001

# Or serve all docs
npm run docs:serve
# Visit http://localhost:8080
```

### Validate OpenAPI Specification

```bash
# Lint and validate OpenAPI spec
npm run validate:openapi

# Build standalone documentation
npm run build:openapi
```

### Generate TypeScript Types

```bash
# Generate types from OpenAPI spec
npm run generate:types
# Output: generated/api-types.ts
```

### Run GraphQL Server

```bash
# Start GraphQL development server
npm run graphql:server
# GraphQL Playground: http://localhost:4000/graphql
# WebSocket: ws://localhost:4000/graphql
```

### Test API with Postman

```bash
# Run Postman collection tests
npm run postman:test

# Or import into Postman GUI
# File > Import > postman/settlement-engine.postman_collection.json
```

## API Overview

### Base URLs

| Environment | REST API | GraphQL |
|-------------|----------|---------|
| Production | https://api.settlement-engine.io/v1 | https://api.settlement-engine.io/graphql |
| Staging | https://staging-api.settlement-engine.io/v1 | https://staging-api.settlement-engine.io/graphql |
| Sandbox | https://sandbox-api.settlement-engine.io/v1 | https://sandbox-api.settlement-engine.io/graphql |

### Authentication

**JWT Bearer Token** (recommended):
```bash
curl -H "Authorization: Bearer eyJhbGc..."
```

**API Key + HMAC Signature** (high-security operations):
```bash
curl -H "X-API-Key: your-key" \
     -H "X-Timestamp: 1705320000" \
     -H "X-Signature: hmac-sha256-signature"
```

### Core Endpoints

#### Settlements
- `POST /settlements` - Create settlement
- `GET /settlements` - List settlements
- `GET /settlements/{id}` - Get settlement details
- `GET /settlements/{id}/finality` - Check finality status

#### Custody
- `POST /custody/wallets` - Create custody wallet
- `GET /custody/wallets` - List wallets
- `POST /custody/wallets/{id}/sign` - Request signature
- `POST /custody/wallets/{id}/keys/rotate` - Rotate keys

#### Layer 2
- `POST /l2/routes` - Calculate optimal L2 route
- `POST /l2/bridge` - Initiate bridge transfer

#### MEV Protection
- `POST /mev/protect` - Submit protected transaction
- `POST /mev/bundles` - Create transaction bundle

### GraphQL Operations

#### Query Example
```graphql
query GetSettlements($filter: SettlementFilter!) {
  settlements(filter: $filter, pagination: { first: 10 }) {
    edges {
      node {
        id
        amount
        status
        finality {
          status
          finalityType
        }
      }
    }
    aggregates {
      totalVolumeUsd
      successRate
    }
  }
}
```

#### Subscription Example
```graphql
subscription WatchSettlement($id: UUID!) {
  settlementUpdated(id: $id) {
    status
    txHash
    finality {
      confirmations
    }
  }
}
```

## SDK Examples

### JavaScript/TypeScript

```typescript
import { SettlementEngine } from '@settlement-engine/sdk';

const client = new SettlementEngine({
  apiKey: process.env.API_KEY,
  environment: 'production'
});

// Create settlement
const settlement = await client.settlements.create({
  sender: '0x742d35Cc...',
  receiver: '0x8ba1f109...',
  amount: '1000000000000000000',
  chain: 'ethereum',
  mevProtection: true
});

// Subscribe to updates
client.settlements.subscribe(settlement.id, (update) => {
  console.log('Status:', update.status);
  console.log('Finality:', update.finality);
});
```

### Python

```python
from settlement_engine import SettlementClient

client = SettlementClient(api_key=os.environ['API_KEY'])

# Create custody wallet
wallet = await client.custody.create_wallet(
    name="Treasury",
    scheme="frost",
    threshold=3,
    participants=5,
    participant_ids=["alice", "bob", "charlie", "dave", "eve"]
)

# Request signature
session = await client.custody.request_signature(
    wallet_id=wallet.id,
    message="0x4d7920746573742074782e"
)
```

### Go

```go
import "github.com/settlement-engine/go-sdk"

client := settlement.NewClient(settlement.Config{
    APIKey: os.Getenv("API_KEY"),
})

// Calculate L2 route
routes, err := client.L2.CalculateRoutes(ctx, settlement.L2RoutingInput{
    Amount:              "10000000000000000000",
    Urgency:             settlement.PriorityMedium,
    FinalityRequirement: settlement.FinalityZK,
    MaxCostUSD:          10.0,
})
```

## Error Handling

All errors follow a consistent format:

```json
{
  "code": "VALIDATION_ERROR",
  "message": "Request validation failed",
  "details": {
    "amount": "Must be positive integer"
  },
  "requestId": "req_123abc"
}
```

Common error codes:
- `INVALID_REQUEST` - Malformed request
- `UNAUTHORIZED` - Authentication failed
- `NOT_FOUND` - Resource not found
- `VALIDATION_ERROR` - Schema validation failed
- `POLICY_VIOLATION` - Custody policy violated
- `RATE_LIMITED` - Rate limit exceeded
- `INTERNAL_ERROR` - Server error

## Webhooks

Register webhooks to receive real-time event notifications:

```bash
POST /webhooks
{
  "url": "https://your-app.com/webhook",
  "events": [
    "settlement.finalized",
    "signature.completed",
    "bridge.completed"
  ]
}
```

Webhook payload example:
```json
{
  "event": "settlement.finalized",
  "data": {
    "id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "status": "finalized",
    "txHash": "0x123...",
    "finality": {
      "status": "finalized",
      "finalityType": "zk",
      "proof": "0xabc..."
    }
  },
  "timestamp": "2024-01-15T10:35:00Z",
  "signature": "sha256=..."
}
```

## Rate Limits

| Tier | Requests/min | Description |
|------|--------------|-------------|
| Standard | 1,000 | Default for API keys |
| Institutional | 10,000 | High-volume clients |
| Internal | Unlimited | Internal services |

Rate limit headers:
```
X-RateLimit-Limit: 1000
X-RateLimit-Remaining: 987
X-RateLimit-Reset: 1705320060
```

## Best Practices

1. **Use idempotency keys** for settlement creation
2. **Subscribe to webhooks** instead of polling
3. **Implement exponential backoff** for retries
4. **Cache L2 gas prices** (update every 30s)
5. **Validate Ethereum addresses** client-side
6. **Use GraphQL subscriptions** for real-time updates
7. **Monitor rate limit headers** to avoid throttling

## Support

- **API Status**: https://status.settlement-engine.io
- **Developer Discord**: https://discord.gg/settlement-engine
- **GitHub Issues**: https://github.com/settlement-engine/api-docs/issues
- **Email**: api-support@settlement-engine.io

## Total Implementation

- **OpenAPI Specification**: 1,500+ lines
- **GraphQL Schema**: 700+ lines
- **GraphQL Server**: 500+ lines
- **Postman Collection**: 600+ lines
- **Interactive Site**: 800+ lines
- **Total**: 4,100+ lines of documentation infrastructure

---

Built with production-grade standards for institutional DeFi operations.
