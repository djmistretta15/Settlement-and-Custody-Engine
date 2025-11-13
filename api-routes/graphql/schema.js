export const typeDefs = `#graphql
  # Scalar types
  scalar DateTime
  scalar BigInt
  scalar Address

  # Enums
  enum SettlementStatus {
    PENDING
    FINALITY_VERIFIED
    EXECUTING
    COMPLETED
    FAILED
    CANCELLED
  }

  enum KYCLevel {
    NONE
    BASIC
    ENHANCED
    INSTITUTIONAL
  }

  enum ChainType {
    EVM
    COSMOS
    SOLANA
  }

  # Types
  type CustodyVault {
    address: Address!
    totalAssets: Int!
    supportedAssets: [Asset!]!
    thresholdConfig: ThresholdConfig!
  }

  type ThresholdConfig {
    requiredSignatures: Int!
    totalSigners: Int!
    signers: [Address!]!
  }

  type Asset {
    address: Address!
    symbol: String!
    name: String!
    decimals: Int!
    balance: BigInt!
  }

  type WithdrawalRequest {
    requestId: ID!
    asset: Address!
    amount: BigInt!
    recipient: Address!
    isNFT: Boolean!
    status: String!
    timeLock: TimeLock!
    approvalCount: Int!
    requiredApprovals: Int!
    approvers: [Address!]!
    createdAt: DateTime!
  }

  type TimeLock {
    proposedAt: DateTime!
    delay: Int!
    executeAfter: DateTime!
    executed: Boolean!
    cancelled: Boolean!
  }

  type Settlement {
    requestId: ID!
    sourceChain: Int!
    destChain: Int!
    asset: Address!
    amount: BigInt!
    sender: Address!
    recipient: Address!
    status: SettlementStatus!
    finalityProof: FinalityProof
    attestations: [Attestation!]!
    createdAt: DateTime!
    executedAt: DateTime
  }

  type FinalityProof {
    verified: Boolean!
    blockNumber: BigInt!
    blockHash: String!
    stateRoot: String!
    timestamp: DateTime!
  }

  type Attestation {
    id: ID!
    attestation: String!
    attester: Address!
    timestamp: DateTime!
  }

  type Chain {
    chainId: String!
    name: String!
    type: ChainType!
    finalityDelay: Int!
    isActive: Boolean!
    minSettlementAmount: BigInt
    maxSettlementAmount: BigInt
  }

  type KYCCredential {
    wallet: Address!
    credentialHash: String!
    kycLevel: KYCLevel!
    isActive: Boolean!
    issuedAt: DateTime!
    expiresAt: DateTime!
    jurisdictionHash: String
  }

  type OFACCheck {
    identityHash: String!
    isCompliant: Boolean!
    onBlacklist: Boolean!
    checkedAt: DateTime!
  }

  type TravelRuleRecord {
    recordId: ID!
    originatorHash: String!
    beneficiaryHash: String!
    amount: BigInt!
    verified: Boolean!
    timestamp: DateTime!
  }

  # Queries
  type Query {
    # Custody queries
    custodyVault: CustodyVault!
    assetBalance(asset: Address!): Asset
    withdrawalRequest(requestId: ID!): WithdrawalRequest
    withdrawalRequests(status: String, limit: Int, offset: Int): [WithdrawalRequest!]!
    
    # Settlement queries
    settlement(requestId: ID!): Settlement
    settlements(
      sourceChain: Int
      destChain: Int
      sender: Address
      status: SettlementStatus
      limit: Int
      offset: Int
    ): [Settlement!]!
    supportedChains: [Chain!]!
    chain(chainId: String!): Chain
    
    # Identity queries
    kycStatus(wallet: Address!): KYCCredential
    checkOFAC(identityHash: String!): OFACCheck!
    travelRuleRecord(recordId: ID!): TravelRuleRecord
    batchKYCStatus(wallets: [Address!]!): [KYCCredential!]!
  }

  # Mutations
  type Mutation {
    # Custody mutations
    depositAsset(asset: Address!, amount: BigInt!): DepositResult!
    proposeWithdrawal(
      asset: Address!
      amount: BigInt!
      recipient: Address!
      isNFT: Boolean
    ): WithdrawalRequest!
    approveWithdrawal(requestId: ID!): ApprovalResult!
    executeWithdrawal(requestId: ID!): ExecutionResult!
    cancelWithdrawal(requestId: ID!): CancellationResult!
    
    # Settlement mutations
    createSettlement(input: SettlementInput!): Settlement!
    executeSettlement(requestId: ID!): ExecutionResult!
    cancelSettlement(requestId: ID!, reason: String): CancellationResult!
    addAttestation(requestId: ID!, attestation: String!): Attestation!
    
    # Identity mutations
    verifyKYC(input: KYCVerificationInput!): KYCCredential!
    revokeKYC(wallet: Address!, reason: String): RevocationResult!
    addToOFACBlacklist(identityHash: String!, reason: String): OFACUpdateResult!
    removeFromOFACBlacklist(identityHash: String!): OFACUpdateResult!
    recordTravelRule(
      originatorHash: String!
      beneficiaryHash: String!
      amount: BigInt!
    ): TravelRuleRecord!
  }

  # Input types
  input SettlementInput {
    sourceChain: Int!
    destChain: Int!
    asset: Address!
    amount: BigInt!
    sender: Address!
    recipient: Address!
    deadline: DateTime
  }

  input KYCVerificationInput {
    wallet: Address!
    proof: String!
    publicInputHash: String!
    proofType: Int
  }

  # Result types
  type DepositResult {
    success: Boolean!
    depositId: ID!
    txHash: String
  }

  type ApprovalResult {
    success: Boolean!
    requestId: ID!
    approvalCount: Int!
    requiredApprovals: Int!
  }

  type ExecutionResult {
    success: Boolean!
    txHash: String!
    timestamp: DateTime!
  }

  type CancellationResult {
    success: Boolean!
    requestId: ID!
    reason: String
  }

  type RevocationResult {
    success: Boolean!
    wallet: Address!
    reason: String
  }

  type OFACUpdateResult {
    success: Boolean!
    identityHash: String!
  }

  # Subscriptions for real-time updates
  type Subscription {
    withdrawalProposed: WithdrawalRequest!
    withdrawalApproved: WithdrawalRequest!
    withdrawalExecuted: WithdrawalRequest!
    
    settlementCreated: Settlement!
    settlementStatusChanged(requestId: ID): Settlement!
    settlementCompleted: Settlement!
    
    kycVerified: KYCCredential!
    kycRevoked: KYCCredential!
  }
`;
