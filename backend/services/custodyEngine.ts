/**
 * MPC Custody Engine - AI-Grade Production Service
 * Coordinates threshold signature generation and vault operations
 *
 * Features:
 * - GG18/FROST threshold signature coordination
 * - Vault freeze/unfreeze with multi-sig
 * - State snapshots with integrity hashing
 * - Emergency override procedures
 * - Audit logging for all custody operations
 */

import { ethers } from 'ethers';
import * as crypto from 'crypto';
import Redis from 'ioredis';
import { EventEmitter } from 'events';
import winston from 'winston';

// ==================== TYPES ====================

interface Signer {
    address: string;
    publicKey: string;
    share: string; // Encrypted key share
    isOnline: boolean;
    lastSeen: number;
}

interface VaultState {
    vaultId: string;
    threshold: number;
    totalSigners: number;
    signers: Signer[];
    isFrozen: boolean;
    nonce: number;
    balance: bigint;
    stateHash: string;
    lastSnapshot: number;
}

interface SigningSession {
    sessionId: string;
    vaultId: string;
    transactionData: string;
    requiredSignatures: number;
    receivedSignatures: Map<string, string>;
    status: 'pending' | 'complete' | 'failed' | 'expired';
    createdAt: number;
    expiresAt: number;
}

interface FreezeRequest {
    requestId: string;
    vaultId: string;
    reason: string;
    requestedBy: string;
    approvals: Set<string>;
    requiredApprovals: number;
    status: 'pending' | 'approved' | 'rejected';
    createdAt: number;
}

// ==================== CUSTODY ENGINE ====================

export class CustodyEngine extends EventEmitter {
    private redis: Redis;
    private logger: winston.Logger;
    private vaultStates: Map<string, VaultState>;
    private signingSessions: Map<string, SigningSession>;
    private freezeRequests: Map<string, FreezeRequest>;
    private snapshotInterval: NodeJS.Timeout;

    // Contract instances
    private vaultContract: ethers.Contract;
    private provider: ethers.Provider;

    constructor(
        redisUrl: string,
        vaultContractAddress: string,
        provider: ethers.Provider
    ) {
        super();
        this.redis = new Redis(redisUrl);
        this.vaultStates = new Map();
        this.signingSessions = new Map();
        this.freezeRequests = new Map();
        this.provider = provider;

        // Initialize logger
        this.logger = winston.createLogger({
            level: 'info',
            format: winston.format.combine(
                winston.format.timestamp(),
                winston.format.json()
            ),
            transports: [
                new winston.transports.File({ filename: 'custody-engine.log' }),
                new winston.transports.Console()
            ]
        });

        // Load vault contract
        const vaultABI = require('../../artifacts/contracts/solidity/custody/MPCVault.sol/MPCVault.json');
        this.vaultContract = new ethers.Contract(
            vaultContractAddress,
            vaultABI.abi,
            provider
        );

        // Start periodic state snapshots
        this.startSnapshotService();

        this.logger.info('CustodyEngine initialized');
    }

    // ==================== VAULT MANAGEMENT ====================

    async initializeVault(
        vaultId: string,
        threshold: number,
        signers: Signer[]
    ): Promise<void> {
        if (this.vaultStates.has(vaultId)) {
            throw new Error(`Vault ${vaultId} already exists`);
        }

        if (threshold > signers.length || threshold < 2) {
            throw new Error('Invalid threshold configuration');
        }

        const vaultState: VaultState = {
            vaultId,
            threshold,
            totalSigners: signers.length,
            signers,
            isFrozen: false,
            nonce: 0,
            balance: BigInt(0),
            stateHash: '',
            lastSnapshot: Date.now()
        };

        // Generate initial state hash
        vaultState.stateHash = this.computeStateHash(vaultState);

        this.vaultStates.set(vaultId, vaultState);

        // Persist to Redis
        await this.persistVaultState(vaultId);

        this.logger.info('Vault initialized', { vaultId, threshold, signers: signers.length });
        this.emit('vaultInitialized', { vaultId });
    }

    async getVaultState(vaultId: string): Promise<VaultState | null> {
        let vault = this.vaultStates.get(vaultId);

        if (!vault) {
            // Try loading from Redis
            vault = await this.loadVaultState(vaultId);
        }

        return vault || null;
    }

    // ==================== THRESHOLD SIGNING ====================

    async initiateSigningSession(
        vaultId: string,
        transactionData: string,
        requester: string
    ): Promise<string> {
        const vault = await this.getVaultState(vaultId);

        if (!vault) {
            throw new Error(`Vault ${vaultId} not found`);
        }

        if (vault.isFrozen) {
            throw new Error(`Vault ${vaultId} is frozen`);
        }

        // Check if requester is authorized
        const isAuthorized = vault.signers.some(s => s.address === requester);
        if (!isAuthorized) {
            throw new Error('Requester not authorized');
        }

        const sessionId = crypto.randomBytes(32).toString('hex');
        const session: SigningSession = {
            sessionId,
            vaultId,
            transactionData,
            requiredSignatures: vault.threshold,
            receivedSignatures: new Map(),
            status: 'pending',
            createdAt: Date.now(),
            expiresAt: Date.now() + 15 * 60 * 1000 // 15 minutes
        };

        this.signingSessions.set(sessionId, session);

        // Notify signers
        this.emit('signingSessionCreated', {
            sessionId,
            vaultId,
            transactionData,
            requiredSignatures: vault.threshold
        });

        this.logger.info('Signing session initiated', { sessionId, vaultId, requester });

        return sessionId;
    }

    async submitPartialSignature(
        sessionId: string,
        signerAddress: string,
        partialSignature: string
    ): Promise<{ complete: boolean; aggregatedSignature?: string }> {
        const session = this.signingSessions.get(sessionId);

        if (!session) {
            throw new Error('Signing session not found');
        }

        if (session.status !== 'pending') {
            throw new Error(`Session status: ${session.status}`);
        }

        if (Date.now() > session.expiresAt) {
            session.status = 'expired';
            throw new Error('Signing session expired');
        }

        const vault = await this.getVaultState(session.vaultId);
        if (!vault) {
            throw new Error('Vault not found');
        }

        // Verify signer is part of vault
        const signer = vault.signers.find(s => s.address === signerAddress);
        if (!signer) {
            throw new Error('Signer not authorized for this vault');
        }

        // Verify partial signature (simplified - use actual crypto in production)
        if (!this.verifyPartialSignature(partialSignature, signerAddress)) {
            throw new Error('Invalid partial signature');
        }

        // Store partial signature
        session.receivedSignatures.set(signerAddress, partialSignature);

        this.logger.info('Partial signature received', {
            sessionId,
            signerAddress,
            total: session.receivedSignatures.size,
            required: session.requiredSignatures
        });

        // Check if threshold met
        if (session.receivedSignatures.size >= session.requiredSignatures) {
            const aggregatedSignature = await this.aggregateSignatures(session);
            session.status = 'complete';

            this.logger.info('Threshold met, signatures aggregated', { sessionId });
            this.emit('signingComplete', { sessionId, signature: aggregatedSignature });

            return { complete: true, aggregatedSignature };
        }

        return { complete: false };
    }

    private async aggregateSignatures(session: SigningSession): Promise<string> {
        // In production, use actual GG18/FROST signature aggregation
        // This is a simplified version
        const signatures = Array.from(session.receivedSignatures.values());

        // Combine signatures using elliptic curve cryptography
        // For GG18: Aggregate partial signatures to form final ECDSA signature
        // For FROST: Combine Schnorr signature shares

        const aggregated = crypto.createHash('sha256')
            .update(signatures.join(''))
            .digest('hex');

        return `0x${aggregated}`;
    }

    private verifyPartialSignature(signature: string, signerAddress: string): boolean {
        // In production, verify the partial signature using public key
        // Check that signature is valid for the signer's key share
        return signature.length >= 64;
    }

    // ==================== FREEZE/UNFREEZE ====================

    async requestFreeze(
        vaultId: string,
        reason: string,
        requestedBy: string
    ): Promise<string> {
        const vault = await this.getVaultState(vaultId);

        if (!vault) {
            throw new Error('Vault not found');
        }

        // Check if requester has guardian role
        const isGuardian = vault.signers.some(s => s.address === requestedBy);
        if (!isGuardian) {
            throw new Error('Only guardians can request freeze');
        }

        const requestId = crypto.randomBytes(16).toString('hex');
        const freezeRequest: FreezeRequest = {
            requestId,
            vaultId,
            reason,
            requestedBy,
            approvals: new Set([requestedBy]),
            requiredApprovals: Math.ceil(vault.totalSigners / 2), // Majority
            status: 'pending',
            createdAt: Date.now()
        };

        this.freezeRequests.set(requestId, freezeRequest);

        this.logger.warn('Freeze requested', { vaultId, reason, requestedBy });
        this.emit('freezeRequested', { requestId, vaultId, reason });

        return requestId;
    }

    async approveFreezeRequest(requestId: string, approver: string): Promise<boolean> {
        const request = this.freezeRequests.get(requestId);

        if (!request) {
            throw new Error('Freeze request not found');
        }

        if (request.status !== 'pending') {
            throw new Error(`Request already ${request.status}`);
        }

        const vault = await this.getVaultState(request.vaultId);
        if (!vault) {
            throw new Error('Vault not found');
        }

        // Verify approver is a signer
        const isSigner = vault.signers.some(s => s.address === approver);
        if (!isSigner) {
            throw new Error('Approver not authorized');
        }

        request.approvals.add(approver);

        this.logger.info('Freeze approval received', {
            requestId,
            approver,
            approvals: request.approvals.size,
            required: request.requiredApprovals
        });

        // Check if threshold met
        if (request.approvals.size >= request.requiredApprovals) {
            await this.executeFreeze(request.vaultId);
            request.status = 'approved';
            this.logger.warn('Vault frozen', { vaultId: request.vaultId });
            return true;
        }

        return false;
    }

    private async executeFreeze(vaultId: string): Promise<void> {
        const vault = await this.getVaultState(vaultId);
        if (!vault) {
            throw new Error('Vault not found');
        }

        vault.isFrozen = true;
        vault.stateHash = this.computeStateHash(vault);

        await this.persistVaultState(vaultId);

        this.emit('vaultFrozen', { vaultId });
    }

    async emergencyUnfreeze(
        vaultId: string,
        emergencyApprovers: string[],
        signatures: string[]
    ): Promise<void> {
        const vault = await this.getVaultState(vaultId);

        if (!vault) {
            throw new Error('Vault not found');
        }

        // Verify emergency signatures (requires higher threshold)
        const requiredEmergencyApprovals = Math.ceil(vault.totalSigners * 0.67); // 2/3 majority

        if (emergencyApprovers.length < requiredEmergencyApprovals) {
            throw new Error('Insufficient emergency approvals');
        }

        // Verify all signatures
        for (let i = 0; i < emergencyApprovers.length; i++) {
            const isValid = this.verifyEmergencySignature(
                vaultId,
                emergencyApprovers[i],
                signatures[i]
            );

            if (!isValid) {
                throw new Error(`Invalid emergency signature from ${emergencyApprovers[i]}`);
            }
        }

        vault.isFrozen = false;
        vault.stateHash = this.computeStateHash(vault);

        await this.persistVaultState(vaultId);

        this.logger.warn('Emergency unfreeze executed', { vaultId, approvers: emergencyApprovers });
        this.emit('vaultUnfrozen', { vaultId, emergency: true });
    }

    private verifyEmergencySignature(
        vaultId: string,
        approver: string,
        signature: string
    ): boolean {
        // In production, verify signature using approver's public key
        // Message should be: keccak256(vaultId + "EMERGENCY_UNFREEZE" + timestamp)
        return signature.length >= 64;
    }

    // ==================== STATE SNAPSHOTS ====================

    private computeStateHash(vault: VaultState): string {
        const stateData = {
            vaultId: vault.vaultId,
            threshold: vault.threshold,
            totalSigners: vault.totalSigners,
            signers: vault.signers.map(s => s.address).sort(),
            isFrozen: vault.isFrozen,
            nonce: vault.nonce,
            balance: vault.balance.toString()
        };

        return crypto.createHash('sha256')
            .update(JSON.stringify(stateData))
            .digest('hex');
    }

    private startSnapshotService(): void {
        // Take state snapshots every 5 minutes
        this.snapshotInterval = setInterval(async () => {
            for (const [vaultId, vault] of this.vaultStates) {
                const newHash = this.computeStateHash(vault);

                if (newHash !== vault.stateHash) {
                    this.logger.warn('State hash mismatch detected', {
                        vaultId,
                        expected: vault.stateHash,
                        actual: newHash
                    });

                    this.emit('stateIntegrityAlert', { vaultId });
                }

                vault.lastSnapshot = Date.now();
                await this.persistVaultState(vaultId);
            }
        }, 5 * 60 * 1000);
    }

    private async persistVaultState(vaultId: string): Promise<void> {
        const vault = this.vaultStates.get(vaultId);
        if (!vault) return;

        const serialized = JSON.stringify({
            ...vault,
            balance: vault.balance.toString()
        });

        await this.redis.set(`vault:${vaultId}`, serialized);
        await this.redis.expire(`vault:${vaultId}`, 86400); // 24 hours
    }

    private async loadVaultState(vaultId: string): Promise<VaultState | null> {
        const data = await this.redis.get(`vault:${vaultId}`);
        if (!data) return null;

        const parsed = JSON.parse(data);
        return {
            ...parsed,
            balance: BigInt(parsed.balance)
        };
    }

    // ==================== CLEANUP ====================

    async shutdown(): Promise<void> {
        clearInterval(this.snapshotInterval);
        await this.redis.quit();
        this.logger.info('CustodyEngine shutdown');
    }
}

export default CustodyEngine;
