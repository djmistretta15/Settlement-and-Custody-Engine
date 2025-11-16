/**
 * Layer 2 Integration Module
 *
 * Production-grade L2 scaling solutions for Settlement and Custody Engine:
 * - zkSync Era (ZK-rollup)
 * - Optimism (Optimistic rollup)
 * - Arbitrum One (Optimistic rollup)
 * - Base (OP Stack)
 * - Cross-layer bridging
 * - Settlement routing optimization
 *
 * Benefits:
 * - 95%+ transaction cost reduction
 * - Sub-second finality (zkSync)
 * - High throughput (2000+ TPS)
 * - EVM compatibility
 *
 * @module L2Integration
 */

export * from './types';
export * from './providers/zksync';
export * from './providers/optimism';
export * from './providers/arbitrum';
export * from './providers/base';
export * from './bridge';
export * from './router';
