# Architecture Overview - Settlement and Custody Engine

## System Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────────────┐
│                         Client Layer                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ Bank API │  │  Wallet  │  │ Protocol │  │    SDK   │        │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘        │
└───────┼─────────────┼─────────────┼─────────────┼───────────────┘
        │             │             │             │
        └─────────────┴─────────────┴─────────────┘
                          │
        ┌─────────────────┴─────────────────┐
        │                                   │
┌───────▼─────────┐              ┌──────────▼──────────┐
│   REST API      │              │   GraphQL API       │
│   Rate Limited  │              │   Subscriptions     │
└───────┬─────────┘              └──────────┬──────────┘
        │                                   │
        └─────────────────┬─────────────────┘
                          │
        ┌─────────────────▼─────────────────┐
        │     Settlement Engine Core        │
        │  - orchestration                  │
        │  - rate limiting                  │
        │  - replay protection              │
        │  - double-spend detection         │
        └─────────┬───────┬───────┬─────────┘
                  │       │       │
     ┌────────────┘       │       └────────────┐
     │                    │                    │
┌────▼─────┐      ┌──────▼──────┐      ┌─────▼────┐
│ Finality │      │   Custody   │      │   KYC    │
│ Protocol │      │  MPC Vault  │      │ Registry │
└────┬─────┘      └──────┬──────┘      └─────┬────┘
     │                   │                    │
     │                   │                    │
┌────▼──────────────────────────────────────────────┐
│           Blockchain Layer                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │ Ethereum │  │ Polygon  │  │  Solana  │  ...  │
│  └──────────┘  └──────────┘  └──────────┘       │
└───────────────────────────────────────────────────┘
```

## Module Deep Dive

### 1. Cross-Chain Finality Protocol

#### Components

**A. ZK Light Client**
- Verifies block headers using zk-SNARKs
- Supports EVM (Ethereum, Polygon, Arbitrum, etc.)
- Supports Cosmos SDK (via IBC)
- Supports Solana (via gossip proofs)

**Flow Diagram:**
```
Block Producer → Block Header → ZK Prover → Proof
                                              │
                                              ▼
                                    Light Client Verifier
                                              │
                                              ▼
                                    Finality Checkpoint
```

**Key Functions:**
```solidity
function verifyBlock(
    uint256 chainId,
    BlockProof calldata proof
) external returns (bool success)

function isBlockFinalized(
    uint256 chainId,
    uint256 blockHeight
) external view returns (bool)
```

**B. State Reconciliation**

Ensures deterministic state transitions across chains:

```
Source Chain State ──────────┐
                             │
                      ┌──────▼──────┐
                      │  Merkle Proof │
                      │  Verification │
                      └──────┬────────┘
                             │
Target Chain State ──────────┘
```

**Reconciliation Process:**
1. Initiate state transition
2. Wait for source chain finality
3. Verify Merkle proof of inclusion
4. Confirm transition
5. Finalize after timeout period

**C. Fraud Proof Mechanism**

Optimistic verification with challenge period:

```
Block Submitted ──> Challenge Period (1 hour)
                            │
                    ┌───────┴───────┐
                    │               │
              Valid Block    Fraud Proof Submitted
                    │               │
              Finalized        ┌────▼────┐
                              │ Resolve  │
                              │ & Slash  │
                              └──────────┘
```

### 2. MPC Vault Custody Layer

#### Threshold Signature Architecture

**GG18 Protocol (ECDSA):**
```
Participants: P₁, P₂, P₃, ..., Pₙ
Threshold: t of n (e.g., 2 of 3)

Key Generation Phase:
┌──────────────────────────────────────┐
│ Each participant generates share     │
│ Distributed Key Generation (DKG)     │
│ No single party knows full key       │
└──────────────────────────────────────┘

Signing Phase:
┌──────────────────────────────────────┐
│ t participants create partial sigs   │
│ Combine to form valid signature      │
│ Threshold met → Transaction signed    │
└──────────────────────────────────────┘
```

**FROST Protocol (Schnorr):**
- More efficient than GG18
- Better for high-throughput scenarios
- Non-interactive after preprocessing

#### Vault Operations Flow

```
1. Create Vault
   │
   ├─ Set threshold (e.g., 2 of 3)
   ├─ Define signers
   └─ Initialize audit log

2. Propose Transaction
   │
   ├─ Originator creates proposal
   ├─ Metadata stored on-chain
   └─ Status: Pending

3. Approve Transaction
   │
   ├─ Signers submit partial signatures
   ├─ Threshold check
   └─ Status: Approved (if threshold met)

4. Execute Transaction
   │
   ├─ Aggregate signatures
   ├─ Verify combined signature
   └─ Execute & emit event
```

#### Role-Based Access Control

```
┌──────────────────────────────────────┐
│ ADMIN_ROLE                           │
│  - Create vaults                     │
│  - Grant/revoke roles                │
│  - Emergency actions                 │
└──────────────────────────────────────┘

┌──────────────────────────────────────┐
│ SIGNER_ROLE                          │
│  - Propose transactions              │
│  - Approve proposals                 │
│  - Execute approved proposals        │
└──────────────────────────────────────┘

┌──────────────────────────────────────┐
│ GUARDIAN_ROLE                        │
│  - Monitor activity                  │
│  - Dispute suspicious activity       │
└──────────────────────────────────────┘

┌──────────────────────────────────────┐
│ EMERGENCY_ROLE                       │
│  - Activate emergency pause          │
│  - Requires multi-signature          │
└──────────────────────────────────────┘
```

### 3. ZK-KYC Identity Compliance Layer

#### Privacy-Preserving KYC Architecture

**Identity Commitment Scheme:**
```
User Identity Data
    │
    ├─ Name
    ├─ Date of Birth
    ├─ National ID
    └─ Address
         │
         ▼
    Poseidon Hash
         │
         ▼
    Commitment (C)
         │
         └─► Stored on-chain
```

**Zero-Knowledge Proof Flow:**
```
User                    ZK Prover              Verifier (Smart Contract)
  │                         │                          │
  │ Identity + Secret       │                          │
  ├────────────────────────>│                          │
  │                         │                          │
  │                         │ Generate Proof           │
  │                         │ (age > 18, etc.)         │
  │                         │                          │
  │        Proof            │                          │
  │<────────────────────────┤                          │
  │                         │                          │
  │        Proof + Public Inputs                       │
  ├───────────────────────────────────────────────────>│
  │                         │                          │
  │                         │          Verify Proof    │
  │                         │          ✓ Valid         │
  │                         │                          │
  │        Compliance Token                            │
  │<───────────────────────────────────────────────────┤
```

**Public Inputs (Revealed):**
- Commitment to identity
- Nullifier (prevents double-use)
- Timestamp
- Required KYC level

**Private Inputs (Hidden):**
- Name
- Date of birth
- National ID
- Address

#### OFAC Compliance (Privacy-Preserving)

```
Sanctioned List           User Address
      │                        │
      ├─ addr₁                 │
      ├─ addr₂                 │
      └─ addr₃                 │
         │                     │
         ▼                     ▼
    Merkle Tree           Address Hash
         │                     │
         │                     └──────────┐
         │                                │
         └─► Root                    ZK Proof
                │                    (NOT in tree)
                │                         │
                └─────────────────────────┘
                           │
                           ▼
                    Verifier Contract
                    (No address revealed)
```

#### Travel Rule Compliance

```
Originator                              Beneficiary
    │                                        │
    ├─ DID₁                                  ├─ DID₂
    ├─ KYC Level: Enhanced                   ├─ KYC Level: Enhanced
    │                                        │
    └────────────┐                 ┌─────────┘
                 │                 │
                 ▼                 ▼
            ZK Proof Generator
                 │
                 ├─ Both have valid KYC
                 ├─ Both meet level requirement
                 └─ Amount within limits
                        │
                        ▼
                Compliance Verified ✓
            (No PII revealed on-chain)
```

### 4. Settlement Engine Core

#### `settleAndVerify()` Function Flow

```
1. Initiate Settlement
   │
   ├─ Check KYC (originator & beneficiary)
   ├─ Rate limit check
   ├─ Generate instruction ID
   └─ Status: Pending

2. Verify Finality
   │
   ├─ Submit block proof
   ├─ ZK proof verification
   ├─ Check finality threshold (64+ blocks)
   └─ Status: FinalityVerified

3. Verify Compliance
   │
   ├─ Verify KYC proofs
   ├─ Check OFAC (privacy-preserving)
   ├─ Verify Travel Rule
   └─ Status: ComplianceChecked

4. Execute Settlement
   │
   ├─ Double-spend check
   ├─ Vault execution (if same-chain)
   ├─ Cross-chain message (if different chains)
   └─ Status: Settled

5. Finalization
   │
   ├─ Emit settlement event
   ├─ Update state
   └─ Record audit log
```

**State Machine:**
```
    Pending
       │
       ▼
  FinalityVerified
       │
       ▼
  ComplianceChecked
       │
       ├──────┬──────┐
       │      │      │
       ▼      ▼      ▼
   Settled  Failed  Disputed
```

## Data Flow

### End-to-End Settlement Example

```
1. Bank A (Ethereum) → Bank B (Polygon) transfer 1000 USDC

Step 1: Initiate
┌────────────────────────────────────────┐
│ Bank A calls initiateSettlement()      │
│ - beneficiary: Bank B address          │
│ - sourceChain: 1 (Ethereum)            │
│ - targetChain: 137 (Polygon)           │
│ - amount: 1000 USDC                    │
└────────────────────────────────────────┘

Step 2: Lock Funds on Source Chain
┌────────────────────────────────────────┐
│ Vault locks 1000 USDC on Ethereum      │
│ Generates lock proof                   │
└────────────────────────────────────────┘

Step 3: Wait for Finality
┌────────────────────────────────────────┐
│ Light client monitors Ethereum         │
│ Block reaches 64 confirmations         │
│ ZK proof of finality generated         │
└────────────────────────────────────────┘

Step 4: Verify & Settle
┌────────────────────────────────────────┐
│ Submit finality proof to Polygon       │
│ Verify compliance (KYC, OFAC)          │
│ Mint/unlock 1000 USDC for Bank B       │
└────────────────────────────────────────┘

Step 5: Confirmation
┌────────────────────────────────────────┐
│ Settlement marked as Settled           │
│ Both parties receive confirmation      │
│ Audit log updated                      │
└────────────────────────────────────────┘
```

## Security Architecture

### Defense Layers

```
Layer 1: Network (DDoS protection, TLS)
           │
Layer 2: API (Rate limiting, authentication)
           │
Layer 3: Application (Input validation, business logic)
           │
Layer 4: Smart Contract (Access control, reentrancy guards)
           │
Layer 5: Cryptographic (ZK proofs, threshold sigs)
           │
Layer 6: Physical (HSM, geographically distributed)
```

### Key Security Mechanisms

1. **Rate Limiting**: 100 requests/minute per address
2. **Replay Protection**: Nonce + timestamp + chain ID
3. **Double-Spend Prevention**: State tracking
4. **Emergency Pause**: Multi-sig required (3 of 5)
5. **Audit Logging**: All actions recorded on-chain
6. **Formal Verification**: Critical functions verified

## Scalability & Performance

### Optimization Strategies

1. **Batch Settlements**: Group multiple settlements
2. **State Channels**: Off-chain settlement with on-chain finality
3. **Optimistic Verification**: Challenge period for disputes
4. **Parallel Processing**: Independent settlement tracks
5. **ZK Rollups**: Compress multiple operations

### Performance Targets

| Metric | Target | Current |
|--------|--------|---------|
| Settlement Latency | <30s | ~25s |
| Throughput | 1000 TPS | 500 TPS |
| Gas Cost | <200k | ~180k |
| Finality Time | <15 min | ~12 min |

## Technology Stack

### Smart Contracts
- **Solidity**: 0.8.24 (EVM chains)
- **Rust/Anchor**: Latest (Solana)
- **CosmWasm**: Latest (Cosmos)

### ZK Proofs
- **Library**: snarkjs, circom
- **Curves**: BN254, BLS12-381
- **Schemes**: Groth16, PLONK (future)

### Infrastructure
- **Blockchain**: Ethereum, Polygon, Solana, Arbitrum
- **API**: Node.js, Express, Apollo GraphQL
- **Database**: Redis (caching), PostgreSQL (off-chain)
- **Monitoring**: Prometheus, Grafana
- **Logging**: Winston, CloudWatch

## Future Enhancements

### Phase 2 (Q2 2024)
- MEV protection layer
- Cosmos IBC integration
- Privacy pools
- Institutional custody partners

### Phase 3 (Q3 2024)
- Zero-knowledge rollups
- Privacy-preserving cross-chain swaps
- Regulatory certification
- Production mainnet launch

## Conclusion

The Settlement and Custody Engine provides institutional-grade infrastructure for cross-chain digital asset settlement with:

- **Security**: Multi-layer defense, formal verification
- **Privacy**: Zero-knowledge proofs for compliance
- **Compliance**: KYC/AML, FATF Travel Rule, OFAC
- **Scalability**: Batch processing, optimistic verification
- **Interoperability**: Support for EVM, Solana, Cosmos

This architecture ensures the system can scale to support global financial markets while maintaining the highest security and compliance standards.

---

**Last Updated**: January 2024
**Version**: 1.0.0
**Maintained By**: Architecture Team
