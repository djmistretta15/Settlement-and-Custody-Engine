# System Architecture

## Overview

The Settlement and Custody Engine is designed as a modular, distributed system with clear separation of concerns across custody, settlement, identity, and finality verification layers.

## High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                     External Systems                              │
│  Banks · Exchanges · DeFi Protocols · Wallets · Trading Platforms│
└────────────────────────┬─────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│                      API Gateway Layer                            │
│                                                                   │
│  ┌───────────┐  ┌────────────┐  ┌──────────────┐                │
│  │  REST API │  │  GraphQL   │  │  WebSocket   │                │
│  │           │  │            │  │  (Real-time) │                │
│  └───────────┘  └────────────┘  └──────────────┘                │
│                                                                   │
│  • Authentication & Authorization                                 │
│  • Rate Limiting                                                  │
│  • Request Validation                                             │
│  • Response Formatting                                            │
└────────────────────────┬─────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│                     Service Layer                                 │
│                                                                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │  Identity    │  │  Settlement  │  │  Custody             │  │
│  │  Service     │  │  Orchestrator│  │  Manager             │  │
│  │              │  │              │  │                      │  │
│  │ • KYC Verify │  │ • Create     │  │ • Deposit            │  │
│  │ • OFAC Check │  │ • Coordinate │  │ • Withdraw Propose   │  │
│  │ • Travel Rule│  │ • Execute    │  │ • Multi-sig Approve  │  │
│  │ • Revocation │  │ • Monitor    │  │ • Time-lock Execute  │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
└────────────────────────┬─────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│                  Smart Contract Layer                             │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │               InstitutionalCustody.sol                    │   │
│  │  • Threshold Signatures (MPC)                             │   │
│  │  • Time-locked Withdrawals                                │   │
│  │  • Admin Override                                         │   │
│  │  • ERC-20/721 Support                                     │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │          CrossChainSettlementEngine.sol                   │   │
│  │  • Atomic Settlement Coordination                         │   │
│  │  • Nonce-based Replay Protection                          │   │
│  │  • Double-spend Detection                                 │   │
│  │  • Rate Limiting                                          │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │               ZKLightClient.sol                           │   │
│  │  • ZK-SNARK Finality Verification                         │   │
│  │  • Fraud Proof Window                                     │   │
│  │  • Relayer Staking/Slashing                               │   │
│  │  • Multi-chain Support                                    │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              ZKKYCIdentity.sol                            │   │
│  │  • Zero-knowledge KYC Verification                        │   │
│  │  • DID Credential Management                              │   │
│  │  • OFAC Blacklist                                         │   │
│  │  • Travel Rule Recording                                  │   │
│  └──────────────────────────────────────────────────────────┘   │
└────────────────────────┬─────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│                  Blockchain Networks                              │
│                                                                   │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐    │
│  │ Ethereum │  │ Polygon  │  │ Arbitrum │  │   Cosmos     │    │
│  │  (EVM)   │  │  (EVM)   │  │  (EVM)   │  │   (Tendermint)│   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────────┘    │
│                                                                   │
│  ┌──────────┐  ┌──────────┐                                     │
│  │ Optimism │  │  Solana  │                                     │
│  │  (EVM)   │  │  (SVM)   │                                     │
│  └──────────┘  └──────────┘                                     │
└──────────────────────────────────────────────────────────────────┘
```

## Component Details

### 1. API Gateway Layer

**Responsibilities:**
- Route requests to appropriate services
- Authenticate and authorize users
- Rate limit requests
- Transform and validate data
- Aggregate responses

**Technologies:**
- Express.js for REST
- Apollo Server for GraphQL
- Socket.io for WebSockets
- JWT for authentication
- Redis for rate limiting

### 2. Identity Service

**Responsibilities:**
- Verify zero-knowledge KYC proofs
- Manage DID credentials
- Check OFAC compliance
- Record Travel Rule data
- Handle credential revocation

**Key Functions:**
```typescript
interface IdentityService {
  verifyKYCProof(proof: ZKProof): Promise<boolean>
  isKYCVerified(wallet: Address): Promise<boolean>
  checkOFAC(identityHash: string): Promise<boolean>
  recordTravelRule(data: TravelRuleData): Promise<string>
  revokeKYC(wallet: Address): Promise<void>
}
```

### 3. Settlement Orchestrator

**Responsibilities:**
- Coordinate cross-chain settlements
- Verify finality proofs
- Manage atomic locks
- Collect attestations
- Handle settlement execution

**Settlement Flow:**
```
1. User initiates settlement
   ↓
2. Verify KYC/OFAC compliance
   ↓
3. Check rate limits and nonce
   ↓
4. Create settlement request
   ↓
5. Verify source chain finality
   ↓
6. Acquire atomic lock
   ↓
7. Collect required attestations
   ↓
8. Execute on destination chain
   ↓
9. Release atomic lock
   ↓
10. Emit completion event
```

### 4. Custody Manager

**Responsibilities:**
- Manage MPC key shares
- Coordinate threshold signatures
- Enforce time-locks
- Handle admin overrides
- Process deposits/withdrawals

**Threshold Signature Flow:**
```
1. Withdrawal proposed
   ↓
2. Generate request ID
   ↓
3. Start time-lock countdown
   ↓
4. Collect signer approvals
   ↓
5. Verify threshold met
   ↓
6. Wait for time-lock expiry
   ↓
7. Execute withdrawal
   ↓
8. Log event for audit
```

## Data Flow

### Cross-Chain Settlement Example

```
┌─────────┐         ┌──────────┐         ┌──────────┐
│  User   │         │    API   │         │Settlement│
│ Wallet  │         │ Gateway  │         │  Engine  │
└────┬────┘         └────┬─────┘         └────┬─────┘
     │                   │                    │
     │ 1. POST /settlement/create             │
     ├──────────────────>│                    │
     │                   │ 2. Verify KYC      │
     │                   ├───────────────────>│
     │                   │                    │
     │                   │ 3. Check finality  │
     │                   │<───────────────────┤
     │                   │                    │
     │ 4. Return request │                    │
     │<──────────────────┤                    │
     │                   │                    │
     │                   │ 5. Monitor status  │
     │                   │<───────────────────┤
     │                   │                    │
     │ 6. WebSocket update                    │
     │<──────────────────┤                    │
     │                   │                    │
     │                   │ 7. Execute         │
     │                   │───────────────────>│
     │                   │                    │
     │ 8. Completion event                    │
     │<──────────────────┤<───────────────────┤
     │                   │                    │
```

## Security Architecture

### Defense in Depth

**Layer 1: Network**
- DDoS protection (Cloudflare)
- Geographic distribution
- VPN for admin access

**Layer 2: Application**
- Input validation
- Rate limiting
- Session management
- CSRF protection

**Layer 3: Authentication**
- Multi-factor authentication
- JWT tokens
- Hardware key support
- Role-based access control

**Layer 4: Smart Contracts**
- Threshold signatures
- Time-locked operations
- Reentrancy guards
- Access control modifiers

**Layer 5: Cryptography**
- MPC key management
- Zero-knowledge proofs
- Hardware security modules
- Secure enclaves

### Key Management

```
┌─────────────────────────────────────────────────┐
│           MPC Key Share Distribution             │
├─────────────────────────────────────────────────┤
│                                                  │
│  Signer 1 (YubiHSM)    Signer 2 (Ledger)        │
│        │                      │                  │
│        ├──────────┬───────────┤                  │
│                   │                              │
│              Signer 3 (Cloud HSM)                │
│                                                  │
│  Threshold: 2-of-3                               │
│  Recovery: 3-of-5 (includes backup shares)      │
└─────────────────────────────────────────────────┘
```

## Scalability

### Horizontal Scaling

- **API Gateway**: Load balanced across multiple instances
- **Services**: Stateless, can scale independently
- **Database**: Sharded by chain ID
- **Cache**: Redis cluster for session data

### Vertical Optimization

- **Smart Contracts**: Optimized gas usage
- **ZK Proofs**: Batched verification
- **State Queries**: Indexed by block number
- **Events**: Filtered by relevant addresses

## Monitoring & Observability

### Metrics

- Transaction throughput
- Settlement latency
- API response times
- Error rates
- Gas prices
- Signature collection time

### Logging

- Structured JSON logs
- Log levels: DEBUG, INFO, WARN, ERROR
- Request tracing with correlation IDs
- Audit trail for compliance

### Alerting

- Failed settlements
- Unusual withdrawal patterns
- Rate limit violations
- Contract anomalies
- Security events

## Disaster Recovery

### Backup Strategy

- **Smart Contracts**: Immutable, but admin keys backed up
- **API State**: Database replication with point-in-time recovery
- **Key Shares**: Encrypted backups in geographically distributed locations
- **Audit Logs**: Append-only, replicated to multiple regions

### Recovery Procedures

1. **Service Outage**: Auto-failover to backup region
2. **Contract Bug**: Pause → Audit → Deploy fix → Unpause
3. **Key Compromise**: Emergency freeze → Social recovery → New keys
4. **Chain Reorganization**: Fraud proof submission → Settlement reversal

## Future Enhancements

- **Sharding**: Separate custody vaults per asset class
- **L2 Integration**: Deploy to Optimism, zkSync
- **Governance**: DAO-controlled parameter updates
- **Insurance**: On-chain coverage for settlements
- **Privacy**: Confidential transactions using zk-STARKs

---

**Document Version**: 1.0  
**Last Updated**: 2025-11-13  
**Maintainer**: Architecture Team
