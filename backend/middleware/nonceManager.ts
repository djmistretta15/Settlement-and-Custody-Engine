/**
 * Nonce Manager - Replay Protection Service
 * Prevents double-spending and replay attacks with deterministic nonce tracking
 *
 * Features:
 * - Per-address nonce tracking
 * - ChainID-bound nonce validation
 * - Timestamp-based expiration
 * - Hashed nonce verification (privacy-preserving)
 * - Concurrent transaction support
 */

import Redis from 'ioredis';
import * as crypto from 'crypto';
import winston from 'winston';

interface NonceRecord {
    address: string;
    chainId: number;
    nonce: number;
    timestamp: number;
    txHash?: string;
}

export class NonceManager {
    private redis: Redis;
    private logger: winston.Logger;
    private readonly nonceExpiry = 24 * 60 * 60; // 24 hours
    private readonly maxConcurrent = 5; // Max pending txs per address

    constructor(redisUrl: string) {
        this.redis = new Redis(redisUrl);

        this.logger = winston.createLogger({
            level: 'info',
            format: winston.format.combine(
                winston.format.timestamp(),
                winston.format.json()
            ),
            transports: [
                new winston.transports.File({ filename: 'nonce-manager.log' }),
                new winston.transports.Console()
            ]
        });

        this.logger.info('NonceManager initialized');
    }

    /**
     * Get next available nonce for address on chain
     */
    async getNextNonce(address: string, chainId: number): Promise<number> {
        const key = this.getNonceKey(address, chainId);
        const current = await this.redis.get(key);

        if (!current) {
            // Initialize nonce for new address
            await this.redis.set(key, '0');
            return 0;
        }

        const nonce = parseInt(current) + 1;
        await this.redis.set(key, nonce.toString());
        await this.redis.expire(key, this.nonceExpiry);

        this.logger.debug('Nonce allocated', { address, chainId, nonce });
        return nonce;
    }

    /**
     * Validate nonce for replay protection
     */
    async validateNonce(
        address: string,
        chainId: number,
        nonce: number,
        timestamp: number
    ): Promise<{ valid: boolean; reason?: string }> {
        // Check timestamp (must be within 5 minutes)
        const now = Date.now();
        const timeDiff = Math.abs(now - timestamp);

        if (timeDiff > 5 * 60 * 1000) {
            return { valid: false, reason: 'Timestamp expired' };
        }

        // Check if nonce already used
        const usedKey = this.getUsedNonceKey(address, chainId, nonce);
        const isUsed = await this.redis.exists(usedKey);

        if (isUsed) {
            this.logger.warn('Replay attack detected', { address, chainId, nonce });
            return { valid: false, reason: 'Nonce already used (replay attack)' };
        }

        // Check if nonce is sequential
        const currentKey = this.getNonceKey(address, chainId);
        const current = await this.redis.get(currentKey);

        if (current) {
            const currentNonce = parseInt(current);

            // Allow some flexibility for concurrent transactions
            if (nonce < currentNonce || nonce > currentNonce + this.maxConcurrent) {
                return { valid: false, reason: 'Invalid nonce sequence' };
            }
        }

        return { valid: true };
    }

    /**
     * Mark nonce as used
     */
    async markNonceUsed(
        address: string,
        chainId: number,
        nonce: number,
        txHash: string
    ): Promise<void> {
        const usedKey = this.getUsedNonceKey(address, chainId, nonce);

        const record: NonceRecord = {
            address,
            chainId,
            nonce,
            timestamp: Date.now(),
            txHash
        };

        await this.redis.set(usedKey, JSON.stringify(record));
        await this.redis.expire(usedKey, this.nonceExpiry);

        this.logger.info('Nonce marked as used', { address, chainId, nonce, txHash });
    }

    /**
     * Generate deterministic nonce hash for privacy
     */
    generateNonceHash(
        address: string,
        chainId: number,
        nonce: number,
        salt: string
    ): string {
        return crypto
            .createHash('sha256')
            .update(`${address}:${chainId}:${nonce}:${salt}`)
            .digest('hex');
    }

    /**
     * Verify hashed nonce
     */
    verifyNonceHash(
        hash: string,
        address: string,
        chainId: number,
        nonce: number,
        salt: string
    ): boolean {
        const computed = this.generateNonceHash(address, chainId, nonce, salt);
        return crypto.timingSafeEqual(
            Buffer.from(hash),
            Buffer.from(computed)
        );
    }

    /**
     * Get all pending nonces for address
     */
    async getPendingNonces(address: string, chainId: number): Promise<number[]> {
        const pattern = `used:nonce:${address}:${chainId}:*`;
        const keys = await this.redis.keys(pattern);

        const nonces = keys.map(key => {
            const parts = key.split(':');
            return parseInt(parts[parts.length - 1]);
        });

        return nonces.sort((a, b) => a - b);
    }

    /**
     * Reset nonce for address (admin only)
     */
    async resetNonce(address: string, chainId: number, newNonce: number): Promise<void> {
        const key = this.getNonceKey(address, chainId);
        await this.redis.set(key, newNonce.toString());

        this.logger.warn('Nonce reset', { address, chainId, newNonce });
    }

    private getNonceKey(address: string, chainId: number): string {
        return `nonce:${address.toLowerCase()}:${chainId}`;
    }

    private getUsedNonceKey(address: string, chainId: number, nonce: number): string {
        return `used:nonce:${address.toLowerCase()}:${chainId}:${nonce}`;
    }

    async shutdown(): Promise<void> {
        await this.redis.quit();
        this.logger.info('NonceManager shutdown');
    }
}

export default NonceManager;
