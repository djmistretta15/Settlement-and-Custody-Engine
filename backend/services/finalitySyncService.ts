/**
 * Finality Sync Service - Cross-Chain Proof Ingestion
 * Continuously monitors multiple chains for finality and generates zk-proofs
 *
 * Features:
 * - Multi-chain block monitoring (Ethereum, Polygon, Arbitrum, Solana)
 * - zk-SNARK proof generation for finality
 * - Reorg detection and handling
 * - Light client state synchronization
 * - Automatic proof submission to settlement engine
 */

import { ethers } from 'ethers';
import { Connection, PublicKey } from '@solana/web3.js';
import * as snarkjs from 'snarkjs';
import Redis from 'ioredis';
import winston from 'winston';
import { EventEmitter } from 'events';
import * as fs from 'fs';
import * as path from 'path';

// ==================== TYPES ====================

interface ChainConfig {
    chainId: number;
    rpcUrl: string;
    finalityThreshold: number;
    blockTime: number; // Average block time in seconds
    type: 'evm' | 'solana' | 'cosmos';
}

interface BlockFinality {
    chainId: number;
    blockNumber: number;
    blockHash: string;
    stateRoot: string;
    receiptsRoot: string;
    timestamp: number;
    isFinalized: boolean;
    confirmations: number;
    proof?: string; // zk-SNARK proof
}

interface ReorgEvent {
    chainId: number;
    fromBlock: number;
    toBlock: number;
    detectedAt: number;
    severity: 'minor' | 'major' | 'critical';
}

// ==================== FINALITY SYNC SERVICE ====================

export class FinalitySyncService extends EventEmitter {
    private redis: Redis;
    private logger: winston.Logger;
    private chains: Map<number, ChainConfig>;
    private providers: Map<number, ethers.Provider>;
    private solanaConnection?: Connection;
    private syncIntervals: Map<number, NodeJS.Timeout>;
    private finalityCache: Map<string, BlockFinality>;
    private reorgDetector: ReorgDetector;

    // Circuit files
    private wasmPath: string;
    private zkeyPath: string;
    private vkeyPath: string;

    constructor(redisUrl: string, chains: ChainConfig[]) {
        super();

        this.redis = new Redis(redisUrl);
        this.chains = new Map();
        this.providers = new Map();
        this.syncIntervals = new Map();
        this.finalityCache = new Map();

        // Initialize logger
        this.logger = winston.createLogger({
            level: 'debug',
            format: winston.format.combine(
                winston.format.timestamp(),
                winston.format.json()
            ),
            transports: [
                new winston.transports.File({ filename: 'finality-sync.log' }),
                new winston.transports.Console()
            ]
        });

        // Load circuit files
        this.wasmPath = path.join(__dirname, '../../zk-circuits/build/finality.wasm');
        this.zkeyPath = path.join(__dirname, '../../zk-circuits/build/finality_final.zkey');
        this.vkeyPath = path.join(__dirname, '../../zk-circuits/build/verification_key.json');

        // Initialize chains
        chains.forEach(chain => this.addChain(chain));

        // Initialize reorg detector
        this.reorgDetector = new ReorgDetector(this.logger);

        this.logger.info('FinalitySyncService initialized', { chains: chains.length });
    }

    // ==================== CHAIN MANAGEMENT ====================

    addChain(config: ChainConfig): void {
        this.chains.set(config.chainId, config);

        if (config.type === 'evm') {
            const provider = new ethers.JsonRpcProvider(config.rpcUrl);
            this.providers.set(config.chainId, provider);
        } else if (config.type === 'solana') {
            this.solanaConnection = new Connection(config.rpcUrl, 'confirmed');
        }

        this.logger.info('Chain added', { chainId: config.chainId, type: config.type });
    }

    startSync(chainId: number): void {
        const config = this.chains.get(chainId);
        if (!config) {
            throw new Error(`Chain ${chainId} not configured`);
        }

        // Start monitoring loop
        const interval = setInterval(async () => {
            try {
                await this.syncChain(chainId);
            } catch (error) {
                this.logger.error('Sync error', { chainId, error: (error as Error).message });
            }
        }, config.blockTime * 1000);

        this.syncIntervals.set(chainId, interval);
        this.logger.info('Sync started', { chainId });
    }

    stopSync(chainId: number): void {
        const interval = this.syncIntervals.get(chainId);
        if (interval) {
            clearInterval(interval);
            this.syncIntervals.delete(chainId);
            this.logger.info('Sync stopped', { chainId });
        }
    }

    // ==================== CHAIN SYNCHRONIZATION ====================

    private async syncChain(chainId: number): Promise<void> {
        const config = this.chains.get(chainId);
        if (!config) return;

        if (config.type === 'evm') {
            await this.syncEVMChain(chainId, config);
        } else if (config.type === 'solana') {
            await this.syncSolanaChain(config);
        }
    }

    private async syncEVMChain(chainId: number, config: ChainConfig): Promise<void> {
        const provider = this.providers.get(chainId);
        if (!provider) return;

        // Get current block
        const currentBlockNumber = await provider.getBlockNumber();

        // Get last synced block
        const lastSynced = await this.getLastSyncedBlock(chainId);
        const startBlock = lastSynced + 1;

        // Check if we're caught up
        if (startBlock > currentBlockNumber - config.finalityThreshold) {
            this.logger.debug('Caught up', { chainId, currentBlock: currentBlockNumber });
            return;
        }

        // Sync blocks in batches
        const batchSize = 100;
        const endBlock = Math.min(startBlock + batchSize, currentBlockNumber - config.finalityThreshold);

        this.logger.info('Syncing blocks', { chainId, startBlock, endBlock });

        for (let blockNum = startBlock; blockNum <= endBlock; blockNum++) {
            try {
                const block = await provider.getBlock(blockNum);
                if (!block) continue;

                // Check for reorg
                const isReorg = await this.reorgDetector.checkReorg(
                    chainId,
                    blockNum,
                    block.hash
                );

                if (isReorg) {
                    await this.handleReorg(chainId, blockNum);
                    return; // Stop syncing and reprocess
                }

                // Process finalized block
                await this.processBlock(chainId, block, config);

                // Update last synced
                await this.setLastSyncedBlock(chainId, blockNum);

            } catch (error) {
                this.logger.error('Block processing error', {
                    chainId,
                    blockNum,
                    error: (error as Error).message
                });
            }
        }
    }

    private async syncSolanaChain(config: ChainConfig): Promise<void> {
        if (!this.solanaConnection) return;

        try {
            const slot = await this.solanaConnection.getSlot('finalized');
            const block = await this.solanaConnection.getBlock(slot, {
                maxSupportedTransactionVersion: 0
            });

            if (!block) return;

            // Process Solana block
            const finalityData: BlockFinality = {
                chainId: config.chainId,
                blockNumber: slot,
                blockHash: block.blockhash,
                stateRoot: block.blockhash, // Solana doesn't have state root
                receiptsRoot: block.blockhash,
                timestamp: block.blockTime || Math.floor(Date.now() / 1000),
                isFinalized: true,
                confirmations: config.finalityThreshold
            };

            await this.storeFinalityData(finalityData);

        } catch (error) {
            this.logger.error('Solana sync error', { error: (error as Error).message });
        }
    }

    // ==================== BLOCK PROCESSING ====================

    private async processBlock(
        chainId: number,
        block: ethers.Block,
        config: ChainConfig
    ): Promise<void> {
        const confirmations = await this.getConfirmations(chainId, block.number);

        const finalityData: BlockFinality = {
            chainId,
            blockNumber: block.number,
            blockHash: block.hash!,
            stateRoot: block.stateRoot || '',
            receiptsRoot: '', // Would need to fetch from provider
            timestamp: block.timestamp,
            isFinalized: confirmations >= config.finalityThreshold,
            confirmations
        };

        // Generate zk-proof if finalized
        if (finalityData.isFinalized) {
            try {
                const proof = await this.generateFinalityProof(finalityData);
                finalityData.proof = proof;

                this.logger.info('Finality proof generated', {
                    chainId,
                    blockNumber: block.number
                });

                // Emit event for settlement engine
                this.emit('finalityProved', finalityData);

            } catch (error) {
                this.logger.error('Proof generation failed', {
                    chainId,
                    blockNumber: block.number,
                    error: (error as Error).message
                });
            }
        }

        await this.storeFinalityData(finalityData);
    }

    private async getConfirmations(chainId: number, blockNumber: number): Promise<number> {
        const provider = this.providers.get(chainId);
        if (!provider) return 0;

        const currentBlock = await provider.getBlockNumber();
        return currentBlock - blockNumber;
    }

    // ==================== ZK-PROOF GENERATION ====================

    private async generateFinalityProof(finality: BlockFinality): Promise<string> {
        // Prepare circuit inputs
        const input = {
            publicChainId: finality.chainId.toString(),
            publicBlockNumber: finality.blockNumber.toString(),
            publicTimestamp: finality.timestamp.toString(),
            blockHash: this.hashToField(finality.blockHash),
            parentHash: this.hashToField('0x' + '0'.repeat(64)), // Simplified
            stateRoot: this.hashToField(finality.stateRoot),
            receiptsRoot: this.hashToField(finality.receiptsRoot),
            timestamp: finality.timestamp.toString(),
            nonce: '0',
            difficulty: '0',
            merkleProof: Array(32).fill('0'),
            merklePathIndices: Array(32).fill(0),
            txHash: '0',
            historicalHashes: Array(64).fill('0')
        };

        // Generate proof
        const { proof, publicSignals } = await snarkjs.groth16.fullProve(
            input,
            this.wasmPath,
            this.zkeyPath
        );

        // Verify proof
        const vkey = JSON.parse(fs.readFileSync(this.vkeyPath, 'utf-8'));
        const isValid = await snarkjs.groth16.verify(vkey, publicSignals, proof);

        if (!isValid) {
            throw new Error('Generated invalid proof');
        }

        // Convert proof to hex string for on-chain usage
        return this.proofToHex(proof);
    }

    private hashToField(hash: string): string {
        const cleanHash = hash.startsWith('0x') ? hash.slice(2) : hash;
        const fieldPrime = BigInt('21888242871839275222246405745257275088548364400416034343698204186575808495617');
        return (BigInt('0x' + cleanHash) % fieldPrime).toString();
    }

    private proofToHex(proof: any): string {
        const proofArray = [
            ...proof.pi_a.slice(0, 2),
            ...proof.pi_b[0],
            ...proof.pi_b[1],
            ...proof.pi_c.slice(0, 2)
        ];

        return '0x' + proofArray.map((val: string) => {
            const hex = BigInt(val).toString(16);
            return hex.padStart(64, '0');
        }).join('');
    }

    // ==================== REORG HANDLING ====================

    private async handleReorg(chainId: number, blockNumber: number): Promise<void> {
        this.logger.warn('Reorg detected', { chainId, blockNumber });

        const reorgEvent: ReorgEvent = {
            chainId,
            fromBlock: blockNumber,
            toBlock: blockNumber, // Will be updated
            detectedAt: Date.now(),
            severity: 'minor'
        };

        // Emit reorg event
        this.emit('reorgDetected', reorgEvent);

        // Clear cached finality data after reorg point
        for (const [key, finality] of this.finalityCache) {
            if (finality.chainId === chainId && finality.blockNumber >= blockNumber) {
                this.finalityCache.delete(key);
            }
        }

        // Reset last synced block
        await this.setLastSyncedBlock(chainId, blockNumber - 100); // Go back 100 blocks

        this.logger.info('Reorg handled, resyncing', { chainId, fromBlock: blockNumber - 100 });
    }

    // ==================== PERSISTENCE ====================

    private async storeFinalityData(finality: BlockFinality): Promise<void> {
        const key = `finality:${finality.chainId}:${finality.blockNumber}`;
        this.finalityCache.set(key, finality);

        await this.redis.set(key, JSON.stringify(finality));
        await this.redis.expire(key, 7 * 24 * 60 * 60); // 7 days
    }

    private async getLastSyncedBlock(chainId: number): Promise<number> {
        const key = `last_synced:${chainId}`;
        const value = await this.redis.get(key);
        return value ? parseInt(value) : 0;
    }

    private async setLastSyncedBlock(chainId: number, blockNumber: number): Promise<void> {
        const key = `last_synced:${chainId}`;
        await this.redis.set(key, blockNumber.toString());
    }

    // ==================== CLEANUP ====================

    async shutdown(): Promise<void> {
        for (const [chainId, interval] of this.syncIntervals) {
            clearInterval(interval);
        }

        await this.redis.quit();
        this.logger.info('FinalitySyncService shutdown');
    }
}

// ==================== REORG DETECTOR ====================

class ReorgDetector {
    private blockHistory: Map<string, string[]>; // chainId => block hashes
    private readonly maxHistory = 1000;

    constructor(private logger: winston.Logger) {
        this.blockHistory = new Map();
    }

    async checkReorg(chainId: number, blockNumber: number, blockHash: string): Promise<boolean> {
        const key = `${chainId}`;
        const history = this.blockHistory.get(key) || [];

        // Check if we've seen this block before
        if (history[blockNumber] && history[blockNumber] !== blockHash) {
            this.logger.warn('Reorg detected - block hash mismatch', {
                chainId,
                blockNumber,
                expected: history[blockNumber],
                actual: blockHash
            });
            return true;
        }

        // Store block hash
        history[blockNumber] = blockHash;

        // Trim history if too large
        if (history.length > this.maxHistory) {
            history.splice(0, history.length - this.maxHistory);
        }

        this.blockHistory.set(key, history);
        return false;
    }
}

export default FinalitySyncService;
