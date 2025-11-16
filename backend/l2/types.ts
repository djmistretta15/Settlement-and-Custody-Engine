/**
 * Layer 2 Integration Types
 *
 * @module L2Types
 */

import { EventEmitter } from 'events';

// ============================================================================
// Network Configuration
// ============================================================================

export enum L2Network {
  ZKSYNC_ERA = 'zksync-era',
  OPTIMISM = 'optimism',
  ARBITRUM_ONE = 'arbitrum-one',
  BASE = 'base',
}

export enum L1Network {
  ETHEREUM_MAINNET = 'ethereum-mainnet',
  ETHEREUM_GOERLI = 'ethereum-goerli',
  ETHEREUM_SEPOLIA = 'ethereum-sepolia',
}

export interface NetworkConfig {
  chainId: number;
  name: string;
  rpcUrl: string;
  wsUrl?: string;
  explorerUrl: string;
  nativeToken: string;
  l1Network: L1Network;
  l1ChainId: number;
  bridgeAddress?: string;
  finality: {
    type: 'zk' | 'optimistic' | 'instant';
    confirmations: number;
    challengePeriod?: number; // seconds for optimistic rollups
  };
}

export const NETWORK_CONFIGS: Record<L2Network, NetworkConfig> = {
  [L2Network.ZKSYNC_ERA]: {
    chainId: 324,
    name: 'zkSync Era',
    rpcUrl: 'https://mainnet.era.zksync.io',
    wsUrl: 'wss://mainnet.era.zksync.io/ws',
    explorerUrl: 'https://explorer.zksync.io',
    nativeToken: 'ETH',
    l1Network: L1Network.ETHEREUM_MAINNET,
    l1ChainId: 1,
    bridgeAddress: '0x32400084C286CF3E17e7B677ea9583e60a000324',
    finality: {
      type: 'zk',
      confirmations: 1,
    },
  },
  [L2Network.OPTIMISM]: {
    chainId: 10,
    name: 'Optimism',
    rpcUrl: 'https://mainnet.optimism.io',
    wsUrl: 'wss://mainnet.optimism.io',
    explorerUrl: 'https://optimistic.etherscan.io',
    nativeToken: 'ETH',
    l1Network: L1Network.ETHEREUM_MAINNET,
    l1ChainId: 1,
    bridgeAddress: '0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1',
    finality: {
      type: 'optimistic',
      confirmations: 1,
      challengePeriod: 604800, // 7 days
    },
  },
  [L2Network.ARBITRUM_ONE]: {
    chainId: 42161,
    name: 'Arbitrum One',
    rpcUrl: 'https://arb1.arbitrum.io/rpc',
    wsUrl: 'wss://arb1.arbitrum.io/feed',
    explorerUrl: 'https://arbiscan.io',
    nativeToken: 'ETH',
    l1Network: L1Network.ETHEREUM_MAINNET,
    l1ChainId: 1,
    bridgeAddress: '0x8315177aB297bA92A06054cE80a67Ed4DBd7ed3a',
    finality: {
      type: 'optimistic',
      confirmations: 1,
      challengePeriod: 604800, // 7 days
    },
  },
  [L2Network.BASE]: {
    chainId: 8453,
    name: 'Base',
    rpcUrl: 'https://mainnet.base.org',
    wsUrl: 'wss://mainnet.base.org',
    explorerUrl: 'https://basescan.org',
    nativeToken: 'ETH',
    l1Network: L1Network.ETHEREUM_MAINNET,
    l1ChainId: 1,
    bridgeAddress: '0x49048044D57e1C92A77f79988d21Fa8fAF74E97e',
    finality: {
      type: 'optimistic',
      confirmations: 1,
      challengePeriod: 604800, // 7 days
    },
  },
};

// ============================================================================
// Transaction Types
// ============================================================================

export interface L2Transaction {
  hash: string;
  from: string;
  to: string;
  value: bigint;
  data: string;
  nonce: number;
  gasLimit: bigint;
  gasPrice?: bigint;
  maxFeePerGas?: bigint;
  maxPriorityFeePerGas?: bigint;
  chainId: number;
  status: L2TransactionStatus;
  blockNumber?: number;
  blockHash?: string;
  timestamp?: number;
  l1BatchNumber?: number;
  l1TxHash?: string;
}

export enum L2TransactionStatus {
  PENDING = 'pending',
  INCLUDED = 'included', // Included in L2 block
  COMMITTED = 'committed', // State committed to L1
  PROVEN = 'proven', // ZK proof verified (zkSync)
  FINALIZED = 'finalized', // Finalized on L1
  FAILED = 'failed',
}

export interface GasEstimate {
  l2GasLimit: bigint;
  l2GasPrice: bigint;
  l1GasLimit?: bigint; // For L1 data availability
  l1GasPrice?: bigint;
  totalCostWei: bigint;
  totalCostEth: string;
  estimatedSavingsPercent: number;
}

// ============================================================================
// Bridge Types
// ============================================================================

export enum BridgeDirection {
  L1_TO_L2 = 'l1-to-l2',
  L2_TO_L1 = 'l2-to-l1',
  L2_TO_L2 = 'l2-to-l2', // Cross-L2 via L1
}

export interface BridgeRequest {
  direction: BridgeDirection;
  sourceNetwork: L1Network | L2Network;
  destinationNetwork: L1Network | L2Network;
  token: string;
  amount: bigint;
  recipient: string;
  sender: string;
}

export interface BridgeReceipt {
  id: string;
  request: BridgeRequest;
  l1TxHash?: string;
  l2TxHash?: string;
  status: BridgeStatus;
  timestamp: number;
  estimatedCompletion?: number;
  proof?: string;
}

export enum BridgeStatus {
  INITIATED = 'initiated',
  L1_PENDING = 'l1-pending',
  L1_CONFIRMED = 'l1-confirmed',
  L2_PENDING = 'l2-pending',
  L2_CONFIRMED = 'l2-confirmed',
  CHALLENGE_PERIOD = 'challenge-period', // For optimistic rollups
  CLAIMABLE = 'claimable',
  COMPLETED = 'completed',
  FAILED = 'failed',
}

// ============================================================================
// Settlement Types
// ============================================================================

export interface L2Settlement {
  id: string;
  sender: string;
  receiver: string;
  amount: bigint;
  token: string;
  sourceL2: L2Network;
  destL2: L2Network;
  status: L2SettlementStatus;
  l2TxHash?: string;
  l1ProofTxHash?: string;
  createdAt: number;
  completedAt?: number;
  gasUsed?: bigint;
  gasCost?: bigint;
}

export enum L2SettlementStatus {
  PENDING = 'pending',
  ROUTING = 'routing', // Selecting optimal L2
  BRIDGING = 'bridging', // Assets moving cross-layer
  EXECUTING = 'executing', // Settlement on destination L2
  PROVING = 'proving', // ZK proof or optimistic challenge
  COMPLETED = 'completed',
  FAILED = 'failed',
}

// ============================================================================
// Provider Interface
// ============================================================================

export interface IL2Provider extends EventEmitter {
  network: L2Network;
  config: NetworkConfig;

  // Connection
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  isConnected(): boolean;

  // Account
  getBalance(address: string): Promise<bigint>;
  getNonce(address: string): Promise<number>;

  // Transactions
  sendTransaction(tx: Partial<L2Transaction>): Promise<string>;
  getTransaction(hash: string): Promise<L2Transaction | null>;
  waitForTransaction(hash: string, confirmations?: number): Promise<L2Transaction>;
  getTransactionReceipt(hash: string): Promise<L2TransactionReceipt | null>;

  // Gas
  estimateGas(tx: Partial<L2Transaction>): Promise<GasEstimate>;
  getGasPrice(): Promise<bigint>;

  // Blocks
  getBlockNumber(): Promise<number>;
  getBlock(blockHashOrNumber: string | number): Promise<L2Block | null>;

  // L1 Finality
  getL1BatchNumber(): Promise<number>;
  isFinalized(txHash: string): Promise<boolean>;
  getProof(txHash: string): Promise<string | null>;

  // Bridge
  deposit(request: BridgeRequest): Promise<BridgeReceipt>;
  withdraw(request: BridgeRequest): Promise<BridgeReceipt>;
  getBridgeStatus(receiptId: string): Promise<BridgeReceipt>;
}

export interface L2TransactionReceipt {
  transactionHash: string;
  blockNumber: number;
  blockHash: string;
  from: string;
  to: string;
  contractAddress?: string;
  gasUsed: bigint;
  effectiveGasPrice: bigint;
  status: number; // 1 = success, 0 = failure
  logs: L2Log[];
  l1BatchNumber?: number;
}

export interface L2Log {
  address: string;
  topics: string[];
  data: string;
  blockNumber: number;
  transactionHash: string;
  logIndex: number;
}

export interface L2Block {
  number: number;
  hash: string;
  parentHash: string;
  timestamp: number;
  transactions: string[];
  gasUsed: bigint;
  gasLimit: bigint;
  l1BatchNumber?: number;
}

// ============================================================================
// Router Types
// ============================================================================

export interface RoutingStrategy {
  network: L2Network;
  estimatedCost: bigint;
  estimatedTime: number; // seconds
  finalityType: 'zk' | 'optimistic';
  score: number; // Higher is better
  reasons: string[];
}

export interface RoutingCriteria {
  prioritizeCost: number; // 0-100
  prioritizeSpeed: number; // 0-100
  prioritizeFinality: number; // 0-100
  maxCostWei?: bigint;
  maxTimeSeconds?: number;
  preferredNetworks?: L2Network[];
  excludedNetworks?: L2Network[];
}

// ============================================================================
// Metrics
// ============================================================================

export interface L2Metrics {
  network: L2Network;
  totalTransactions: number;
  successfulTransactions: number;
  failedTransactions: number;
  totalGasSaved: bigint;
  averageConfirmationTime: number; // seconds
  lastBlockNumber: number;
  lastL1BatchNumber: number;
}
