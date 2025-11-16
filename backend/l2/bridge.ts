/**
 * Cross-Layer Bridge Orchestrator
 *
 * Manages asset transfers between L1 and L2, and L2 to L2:
 * - L1 → L2 deposits
 * - L2 → L1 withdrawals (with challenge period handling)
 * - L2 → L2 transfers (via L1 as intermediary)
 * - Multi-asset support
 *
 * @module BridgeOrchestrator
 */

import { EventEmitter } from 'events';
import { createHash } from 'crypto';
import {
  L2Network,
  L1Network,
  BridgeDirection,
  BridgeRequest,
  BridgeReceipt,
  BridgeStatus,
  IL2Provider,
} from './types';
import { ZkSyncEraProvider } from './providers/zksync';
import { OptimismProvider } from './providers/optimism';
import { ArbitrumProvider } from './providers/arbitrum';
import { BaseProvider } from './providers/base';

export interface CrossLayerTransfer {
  id: string;
  sourceNetwork: L1Network | L2Network;
  destinationNetwork: L1Network | L2Network;
  sender: string;
  recipient: string;
  token: string;
  amount: bigint;
  status: CrossLayerStatus;
  receipts: BridgeReceipt[];
  createdAt: number;
  completedAt?: number;
  estimatedCompletion: number;
}

export enum CrossLayerStatus {
  INITIATED = 'initiated',
  L1_DEPOSIT_PENDING = 'l1-deposit-pending',
  L1_WITHDRAWAL_PENDING = 'l1-withdrawal-pending',
  CROSS_L2_ROUTING = 'cross-l2-routing',
  IN_PROGRESS = 'in-progress',
  CHALLENGE_PERIOD = 'challenge-period',
  CLAIMABLE = 'claimable',
  COMPLETED = 'completed',
  FAILED = 'failed',
}

export class BridgeOrchestrator extends EventEmitter {
  private providers: Map<L2Network, IL2Provider> = new Map();
  private transfers: Map<string, CrossLayerTransfer> = new Map();
  private pendingClaims: Map<string, BridgeReceipt> = new Map();

  constructor() {
    super();
    this.initializeProviders();
  }

  private initializeProviders(): void {
    this.providers.set(L2Network.ZKSYNC_ERA, new ZkSyncEraProvider());
    this.providers.set(L2Network.OPTIMISM, new OptimismProvider());
    this.providers.set(L2Network.ARBITRUM_ONE, new ArbitrumProvider());
    this.providers.set(L2Network.BASE, new BaseProvider());
  }

  async connectAll(): Promise<void> {
    for (const [network, provider] of this.providers) {
      await provider.connect();
      this.setupProviderEvents(network, provider);
      console.log(`[Bridge] Connected to ${network}`);
    }
  }

  private setupProviderEvents(network: L2Network, provider: IL2Provider): void {
    provider.on('bridgeCompleted', (receipt: BridgeReceipt) => {
      this.handleBridgeCompletion(network, receipt);
    });

    provider.on('bridgeClaimable', (receipt: BridgeReceipt) => {
      this.pendingClaims.set(receipt.id, receipt);
      this.emit('claimAvailable', { network, receipt });
    });

    provider.on('bridgeChallengePeriod', (receipt: BridgeReceipt) => {
      console.log(`[Bridge] ${receipt.id} entering challenge period on ${network}`);
      this.emit('challengePeriodStarted', { network, receipt });
    });
  }

  private handleBridgeCompletion(network: L2Network, receipt: BridgeReceipt): void {
    // Find associated transfer
    for (const [id, transfer] of this.transfers) {
      const hasReceipt = transfer.receipts.some((r) => r.id === receipt.id);
      if (hasReceipt) {
        this.checkTransferCompletion(transfer);
        break;
      }
    }
  }

  private checkTransferCompletion(transfer: CrossLayerTransfer): void {
    const allCompleted = transfer.receipts.every(
      (r) => r.status === BridgeStatus.COMPLETED
    );

    if (allCompleted) {
      transfer.status = CrossLayerStatus.COMPLETED;
      transfer.completedAt = Date.now();
      this.emit('transferCompleted', transfer);
      console.log(`[Bridge] Transfer completed: ${transfer.id}`);
    }
  }

  // ============================================================================
  // L1 to L2 Deposit
  // ============================================================================

  async depositToL2(
    l2Network: L2Network,
    sender: string,
    recipient: string,
    token: string,
    amount: bigint
  ): Promise<CrossLayerTransfer> {
    const provider = this.providers.get(l2Network);
    if (!provider) {
      throw new Error(`Provider not found for ${l2Network}`);
    }

    const transfer: CrossLayerTransfer = {
      id: this.generateHash(`deposit-${Date.now()}-${Math.random()}`),
      sourceNetwork: L1Network.ETHEREUM_MAINNET,
      destinationNetwork: l2Network,
      sender,
      recipient,
      token,
      amount,
      status: CrossLayerStatus.INITIATED,
      receipts: [],
      createdAt: Date.now(),
      estimatedCompletion: Date.now() + this.getEstimatedDepositTime(l2Network),
    };

    this.transfers.set(transfer.id, transfer);
    this.emit('transferCreated', transfer);

    // Initiate deposit
    transfer.status = CrossLayerStatus.L1_DEPOSIT_PENDING;

    const bridgeRequest: BridgeRequest = {
      direction: BridgeDirection.L1_TO_L2,
      sourceNetwork: L1Network.ETHEREUM_MAINNET,
      destinationNetwork: l2Network,
      token,
      amount,
      recipient,
      sender,
    };

    const receipt = await provider.deposit(bridgeRequest);
    transfer.receipts.push(receipt);
    transfer.status = CrossLayerStatus.IN_PROGRESS;

    this.emit('depositInitiated', { transfer, receipt });
    console.log(`[Bridge] L1 → ${l2Network} deposit initiated: ${transfer.id}`);

    return transfer;
  }

  private getEstimatedDepositTime(l2Network: L2Network): number {
    switch (l2Network) {
      case L2Network.ZKSYNC_ERA:
        return 15 * 60 * 1000; // 15 minutes
      case L2Network.OPTIMISM:
      case L2Network.BASE:
        return 20 * 60 * 1000; // 20 minutes
      case L2Network.ARBITRUM_ONE:
        return 10 * 60 * 1000; // 10 minutes
      default:
        return 30 * 60 * 1000;
    }
  }

  // ============================================================================
  // L2 to L1 Withdrawal
  // ============================================================================

  async withdrawFromL2(
    l2Network: L2Network,
    sender: string,
    recipient: string,
    token: string,
    amount: bigint
  ): Promise<CrossLayerTransfer> {
    const provider = this.providers.get(l2Network);
    if (!provider) {
      throw new Error(`Provider not found for ${l2Network}`);
    }

    const transfer: CrossLayerTransfer = {
      id: this.generateHash(`withdrawal-${Date.now()}-${Math.random()}`),
      sourceNetwork: l2Network,
      destinationNetwork: L1Network.ETHEREUM_MAINNET,
      sender,
      recipient,
      token,
      amount,
      status: CrossLayerStatus.INITIATED,
      receipts: [],
      createdAt: Date.now(),
      estimatedCompletion: Date.now() + this.getEstimatedWithdrawalTime(l2Network),
    };

    this.transfers.set(transfer.id, transfer);
    this.emit('transferCreated', transfer);

    transfer.status = CrossLayerStatus.L1_WITHDRAWAL_PENDING;

    const bridgeRequest: BridgeRequest = {
      direction: BridgeDirection.L2_TO_L1,
      sourceNetwork: l2Network,
      destinationNetwork: L1Network.ETHEREUM_MAINNET,
      token,
      amount,
      recipient,
      sender,
    };

    const receipt = await provider.withdraw(bridgeRequest);
    transfer.receipts.push(receipt);
    transfer.status = CrossLayerStatus.IN_PROGRESS;

    // For optimistic rollups, set challenge period status
    if (provider.config.finality.type === 'optimistic') {
      transfer.status = CrossLayerStatus.CHALLENGE_PERIOD;
      this.emit('challengePeriodStarted', { transfer, receipt });
    }

    this.emit('withdrawalInitiated', { transfer, receipt });
    console.log(`[Bridge] ${l2Network} → L1 withdrawal initiated: ${transfer.id}`);

    return transfer;
  }

  private getEstimatedWithdrawalTime(l2Network: L2Network): number {
    const provider = this.providers.get(l2Network);
    if (!provider) return 7 * 24 * 60 * 60 * 1000; // Default 7 days

    if (provider.config.finality.type === 'zk') {
      return 24 * 60 * 60 * 1000; // 24 hours for zkSync
    }

    // Optimistic rollups: 7-day challenge period
    return 7 * 24 * 60 * 60 * 1000;
  }

  // ============================================================================
  // L2 to L2 Transfer
  // ============================================================================

  async transferL2ToL2(
    sourceL2: L2Network,
    destL2: L2Network,
    sender: string,
    recipient: string,
    token: string,
    amount: bigint
  ): Promise<CrossLayerTransfer> {
    if (sourceL2 === destL2) {
      throw new Error('Source and destination L2 must be different');
    }

    const sourceProvider = this.providers.get(sourceL2);
    const destProvider = this.providers.get(destL2);

    if (!sourceProvider || !destProvider) {
      throw new Error('Provider not found for one or both networks');
    }

    const transfer: CrossLayerTransfer = {
      id: this.generateHash(`l2-transfer-${Date.now()}-${Math.random()}`),
      sourceNetwork: sourceL2,
      destinationNetwork: destL2,
      sender,
      recipient,
      token,
      amount,
      status: CrossLayerStatus.INITIATED,
      receipts: [],
      createdAt: Date.now(),
      estimatedCompletion:
        Date.now() +
        this.getEstimatedWithdrawalTime(sourceL2) +
        this.getEstimatedDepositTime(destL2),
    };

    this.transfers.set(transfer.id, transfer);
    this.emit('transferCreated', transfer);

    transfer.status = CrossLayerStatus.CROSS_L2_ROUTING;
    console.log(`[Bridge] ${sourceL2} → ${destL2} transfer initiated: ${transfer.id}`);

    // Step 1: Withdraw from source L2 to L1
    const withdrawalRequest: BridgeRequest = {
      direction: BridgeDirection.L2_TO_L1,
      sourceNetwork: sourceL2,
      destinationNetwork: L1Network.ETHEREUM_MAINNET,
      token,
      amount,
      recipient: sender, // Send to self on L1
      sender,
    };

    const withdrawalReceipt = await sourceProvider.withdraw(withdrawalRequest);
    transfer.receipts.push(withdrawalReceipt);

    this.emit('l2ToL2WithdrawalStarted', { transfer, receipt: withdrawalReceipt });

    // Monitor withdrawal and initiate deposit when claimable
    this.monitorL2ToL2Transfer(transfer, destProvider, recipient);

    return transfer;
  }

  private async monitorL2ToL2Transfer(
    transfer: CrossLayerTransfer,
    destProvider: IL2Provider,
    finalRecipient: string
  ): Promise<void> {
    // Wait for withdrawal to complete
    const withdrawalReceipt = transfer.receipts[0];

    const checkWithdrawal = async () => {
      const sourceProvider = this.providers.get(transfer.sourceNetwork as L2Network);
      if (!sourceProvider) return;

      const currentReceipt = await sourceProvider.getBridgeStatus(withdrawalReceipt.id);

      if (currentReceipt.status === BridgeStatus.COMPLETED) {
        // Withdrawal complete, initiate deposit to destination L2
        const depositRequest: BridgeRequest = {
          direction: BridgeDirection.L1_TO_L2,
          sourceNetwork: L1Network.ETHEREUM_MAINNET,
          destinationNetwork: transfer.destinationNetwork as L2Network,
          token: transfer.token,
          amount: transfer.amount,
          recipient: finalRecipient,
          sender: transfer.sender,
        };

        const depositReceipt = await destProvider.deposit(depositRequest);
        transfer.receipts.push(depositReceipt);
        transfer.status = CrossLayerStatus.IN_PROGRESS;

        this.emit('l2ToL2DepositStarted', { transfer, receipt: depositReceipt });
        console.log(`[Bridge] L2-to-L2 deposit phase started: ${transfer.id}`);
      } else if (currentReceipt.status === BridgeStatus.FAILED) {
        transfer.status = CrossLayerStatus.FAILED;
        this.emit('transferFailed', transfer);
      } else {
        // Check again later
        setTimeout(checkWithdrawal, 5000);
      }
    };

    checkWithdrawal();
  }

  // ============================================================================
  // Claim Management
  // ============================================================================

  async claimWithdrawal(receiptId: string, l2Network: L2Network): Promise<string> {
    const receipt = this.pendingClaims.get(receiptId);
    if (!receipt) {
      throw new Error(`No claimable receipt found: ${receiptId}`);
    }

    if (receipt.status !== BridgeStatus.CLAIMABLE) {
      throw new Error(`Receipt not claimable: ${receipt.status}`);
    }

    // In production, this would call the L1 bridge contract
    const claimTxHash = this.generateHash(`claim-${receiptId}`);
    console.log(`[Bridge] Withdrawal claimed: ${claimTxHash}`);

    receipt.status = BridgeStatus.COMPLETED;
    receipt.l1TxHash = claimTxHash;
    this.pendingClaims.delete(receiptId);

    this.emit('withdrawalClaimed', { receiptId, claimTxHash });

    return claimTxHash;
  }

  getPendingClaims(): BridgeReceipt[] {
    return Array.from(this.pendingClaims.values());
  }

  // ============================================================================
  // Transfer Status
  // ============================================================================

  getTransfer(id: string): CrossLayerTransfer | undefined {
    return this.transfers.get(id);
  }

  getAllTransfers(): CrossLayerTransfer[] {
    return Array.from(this.transfers.values());
  }

  getTransfersByStatus(status: CrossLayerStatus): CrossLayerTransfer[] {
    return Array.from(this.transfers.values()).filter((t) => t.status === status);
  }

  // ============================================================================
  // Utility
  // ============================================================================

  private generateHash(input: string): string {
    return '0x' + createHash('sha256').update(input).digest('hex');
  }

  async disconnectAll(): Promise<void> {
    for (const provider of this.providers.values()) {
      await provider.disconnect();
    }
  }
}

// ============================================================================
// Example Usage
// ============================================================================

async function main() {
  console.log('Cross-Layer Bridge Orchestrator Example\n');

  const bridge = new BridgeOrchestrator();

  bridge.on('transferCompleted', (transfer) => {
    console.log(`\n✅ Transfer completed: ${transfer.id}`);
  });

  bridge.on('challengePeriodStarted', ({ transfer }) => {
    console.log(`\n⏳ Challenge period started for ${transfer.id}`);
  });

  await bridge.connectAll();

  // L1 to L2 deposit
  console.log('Step 1: Deposit from L1 to zkSync');
  const deposit = await bridge.depositToL2(
    L2Network.ZKSYNC_ERA,
    '0x742d35Cc6634C0532925a3b844Bc9e7595f8fE2',
    '0x742d35Cc6634C0532925a3b844Bc9e7595f8fE2',
    'ETH',
    BigInt('1000000000000000000')
  );
  console.log(`  Transfer ID: ${deposit.id}`);
  console.log(`  Status: ${deposit.status}`);

  // L2 to L1 withdrawal
  console.log('\nStep 2: Withdraw from Optimism to L1');
  const withdrawal = await bridge.withdrawFromL2(
    L2Network.OPTIMISM,
    '0x742d35Cc6634C0532925a3b844Bc9e7595f8fE2',
    '0x742d35Cc6634C0532925a3b844Bc9e7595f8fE2',
    'ETH',
    BigInt('500000000000000000')
  );
  console.log(`  Transfer ID: ${withdrawal.id}`);
  console.log(`  Status: ${withdrawal.status}`);
  console.log(`  Est. completion: ${Math.round((withdrawal.estimatedCompletion - Date.now()) / (24 * 60 * 60 * 1000))} days`);

  // L2 to L2 transfer
  console.log('\nStep 3: Transfer from Arbitrum to Base');
  const l2Transfer = await bridge.transferL2ToL2(
    L2Network.ARBITRUM_ONE,
    L2Network.BASE,
    '0x742d35Cc6634C0532925a3b844Bc9e7595f8fE2',
    '0x8ba1f109551bD432803012645Ac136ddd64DBA72',
    'ETH',
    BigInt('250000000000000000')
  );
  console.log(`  Transfer ID: ${l2Transfer.id}`);
  console.log(`  Status: ${l2Transfer.status}`);

  console.log('\n✅ Cross-layer bridge orchestration complete!');
  console.log('   - L1 → L2 deposits');
  console.log('   - L2 → L1 withdrawals (with challenge periods)');
  console.log('   - L2 → L2 transfers via L1');
  console.log('   - Multi-network support');

  await bridge.disconnectAll();
}

if (require.main === module) {
  main().catch(console.error);
}

export default BridgeOrchestrator;
