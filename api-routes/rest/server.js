/**
 * REST API Server for Settlement and Custody Engine
 */

const express = require('express');
const rateLimit = require('rate-limiter-flexible');
const Redis = require('ioredis');
const jwt = require('jsonwebtoken');
const { ethers } = require('ethers');
const winston = require('winston');
require('dotenv').config();

const app = express();
const redis = new Redis(process.env.REDIS_URL || 'redis://localhost:6379');

// Logging configuration
const logger = winston.createLogger({
    level: 'info',
    format: winston.format.json(),
    transports: [
        new winston.transports.File({ filename: 'error.log', level: 'error' }),
        new winston.transports.File({ filename: 'combined.log' }),
        new winston.transports.Console({ format: winston.format.simple() })
    ]
});

// Middleware
app.use(express.json());

// Rate limiting
const rateLimiter = new rateLimit.RateLimiterRedis({
    storeClient: redis,
    keyPrefix: 'rate_limit',
    points: 100, // Number of requests
    duration: 60, // Per 60 seconds
});

const rateLimitMiddleware = async (req, res, next) => {
    try {
        await rateLimiter.consume(req.ip);
        next();
    } catch (error) {
        logger.warn(`Rate limit exceeded for IP: ${req.ip}`);
        res.status(429).json({ error: 'Too many requests' });
    }
};

app.use(rateLimitMiddleware);

// JWT authentication middleware
const authenticateJWT = (req, res, next) => {
    const authHeader = req.headers.authorization;

    if (authHeader) {
        const token = authHeader.split(' ')[1];

        jwt.verify(token, process.env.JWT_SECRET || 'secret', (err, user) => {
            if (err) {
                return res.sendStatus(403);
            }

            req.user = user;
            next();
        });
    } else {
        res.sendStatus(401);
    }
};

// Contract instances (initialize with your deployed addresses)
let settlementEngine, lightClient, vault, kycRegistry;

function initializeContracts() {
    const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
    const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

    // Load contract ABIs and addresses
    const settlementABI = require('../../artifacts/contracts/solidity/SettlementEngine.sol/SettlementEngine.json');
    const lightClientABI = require('../../artifacts/contracts/solidity/finality/ZKLightClient.sol/ZKLightClient.json');
    const vaultABI = require('../../artifacts/contracts/solidity/custody/MPCVault.sol/MPCVault.json');
    const kycABI = require('../../artifacts/contracts/solidity/identity/ZKKYCRegistry.sol/ZKKYCRegistry.json');

    settlementEngine = new ethers.Contract(process.env.SETTLEMENT_ENGINE_ADDRESS, settlementABI.abi, wallet);
    lightClient = new ethers.Contract(process.env.LIGHT_CLIENT_ADDRESS, lightClientABI.abi, wallet);
    vault = new ethers.Contract(process.env.VAULT_ADDRESS, vaultABI.abi, wallet);
    kycRegistry = new ethers.Contract(process.env.KYC_REGISTRY_ADDRESS, kycABI.abi, wallet);
}

// Initialize contracts on startup
try {
    initializeContracts();
    logger.info('Contracts initialized successfully');
} catch (error) {
    logger.error('Failed to initialize contracts:', error);
}

// ============ SETTLEMENT ENDPOINTS ============

/**
 * POST /api/v1/settlement/initiate
 * Initiates a new settlement instruction
 */
app.post('/api/v1/settlement/initiate', authenticateJWT, async (req, res) => {
    try {
        const {
            beneficiary,
            sourceChain,
            targetChain,
            asset,
            amount,
            vaultId,
            metadata
        } = req.body;

        logger.info('Initiating settlement', { beneficiary, amount, sourceChain, targetChain });

        const tx = await settlementEngine.initiateSettlement(
            beneficiary,
            sourceChain,
            targetChain,
            asset,
            amount,
            ethers.id(vaultId),
            ethers.hexlify(ethers.toUtf8Bytes(JSON.stringify(metadata)))
        );

        const receipt = await tx.wait();
        const event = receipt.logs.find(log => log.fragment?.name === 'SettlementInitiated');

        const instructionId = event ? event.args.instructionId : null;

        logger.info('Settlement initiated', { instructionId });

        res.json({
            success: true,
            instructionId: instructionId,
            transactionHash: receipt.hash
        });
    } catch (error) {
        logger.error('Settlement initiation failed:', error);
        res.status(500).json({ error: error.message });
    }
});

/**
 * POST /api/v1/settlement/execute
 * Executes settlement with finality and compliance verification
 */
app.post('/api/v1/settlement/execute', authenticateJWT, async (req, res) => {
    try {
        const {
            instructionId,
            blockHeight,
            blockProof,
            kycProof,
            travelRuleProof
        } = req.body;

        logger.info('Executing settlement', { instructionId });

        const tx = await settlementEngine.settleAndVerify(
            instructionId,
            blockHeight,
            blockProof,
            kycProof,
            travelRuleProof
        );

        const receipt = await tx.wait();

        logger.info('Settlement executed successfully', { instructionId });

        res.json({
            success: true,
            transactionHash: receipt.hash,
            gasUsed: receipt.gasUsed.toString()
        });
    } catch (error) {
        logger.error('Settlement execution failed:', error);
        res.status(500).json({ error: error.message });
    }
});

/**
 * GET /api/v1/settlement/:instructionId
 * Gets settlement instruction details
 */
app.get('/api/v1/settlement/:instructionId', authenticateJWT, async (req, res) => {
    try {
        const { instructionId } = req.params;

        const settlement = await settlementEngine.getSettlement(instructionId);

        res.json({
            success: true,
            settlement: {
                instructionId: settlement.instructionId,
                originator: settlement.originator,
                beneficiary: settlement.beneficiary,
                sourceChain: settlement.sourceChain.toString(),
                targetChain: settlement.targetChain.toString(),
                asset: settlement.asset,
                amount: settlement.amount.toString(),
                status: settlement.status,
                createdAt: settlement.createdAt.toString(),
                settledAt: settlement.settledAt.toString()
            }
        });
    } catch (error) {
        logger.error('Failed to get settlement:', error);
        res.status(500).json({ error: error.message });
    }
});

// ============ CUSTODY ENDPOINTS ============

/**
 * POST /api/v1/custody/vault/create
 * Creates a new MPC vault
 */
app.post('/api/v1/custody/vault/create', authenticateJWT, async (req, res) => {
    try {
        const { vaultId, threshold, signers } = req.body;

        logger.info('Creating vault', { vaultId, threshold });

        const tx = await vault.createVault(
            ethers.id(vaultId),
            threshold,
            signers
        );

        const receipt = await tx.wait();

        logger.info('Vault created successfully', { vaultId });

        res.json({
            success: true,
            vaultId: ethers.id(vaultId),
            transactionHash: receipt.hash
        });
    } catch (error) {
        logger.error('Vault creation failed:', error);
        res.status(500).json({ error: error.message });
    }
});

/**
 * POST /api/v1/custody/proposal/create
 * Creates a transaction proposal
 */
app.post('/api/v1/custody/proposal/create', authenticateJWT, async (req, res) => {
    try {
        const { vaultId, to, value, data, chainId } = req.body;

        logger.info('Creating proposal', { vaultId, to, value });

        const tx = await vault.proposeTransaction(
            ethers.id(vaultId),
            to,
            ethers.parseEther(value.toString()),
            data || '0x',
            chainId
        );

        const receipt = await tx.wait();
        const event = receipt.logs.find(log => log.fragment?.name === 'ProposalCreated');

        const proposalId = event ? event.args.proposalId : null;

        logger.info('Proposal created', { proposalId });

        res.json({
            success: true,
            proposalId: proposalId?.toString(),
            transactionHash: receipt.hash
        });
    } catch (error) {
        logger.error('Proposal creation failed:', error);
        res.status(500).json({ error: error.message });
    }
});

/**
 * POST /api/v1/custody/proposal/approve
 * Approves a transaction proposal with threshold signature
 */
app.post('/api/v1/custody/proposal/approve', authenticateJWT, async (req, res) => {
    try {
        const { vaultId, proposalId, signature } = req.body;

        logger.info('Approving proposal', { vaultId, proposalId });

        const tx = await vault.approveProposal(
            ethers.id(vaultId),
            proposalId,
            signature
        );

        const receipt = await tx.wait();

        logger.info('Proposal approved', { proposalId });

        res.json({
            success: true,
            transactionHash: receipt.hash
        });
    } catch (error) {
        logger.error('Proposal approval failed:', error);
        res.status(500).json({ error: error.message });
    }
});

// ============ KYC ENDPOINTS ============

/**
 * POST /api/v1/kyc/credential/issue
 * Issues a KYC credential to a DID
 */
app.post('/api/v1/kyc/credential/issue', authenticateJWT, async (req, res) => {
    try {
        const { did, wallet, credentialHash, kycLevel, validityPeriod } = req.body;

        logger.info('Issuing KYC credential', { did, wallet, kycLevel });

        const tx = await kycRegistry.issueCredential(
            ethers.id(did),
            wallet,
            ethers.id(credentialHash),
            kycLevel,
            validityPeriod
        );

        const receipt = await tx.wait();

        logger.info('KYC credential issued', { did });

        res.json({
            success: true,
            transactionHash: receipt.hash
        });
    } catch (error) {
        logger.error('KYC credential issuance failed:', error);
        res.status(500).json({ error: error.message });
    }
});

/**
 * POST /api/v1/kyc/verify
 * Verifies KYC compliance using zero-knowledge proof
 */
app.post('/api/v1/kyc/verify', authenticateJWT, async (req, res) => {
    try {
        const { did, zkProof, publicInputs } = req.body;

        logger.info('Verifying KYC compliance', { did });

        const tx = await kycRegistry.verifyKYCCompliance(
            ethers.id(did),
            zkProof,
            publicInputs
        );

        const receipt = await tx.wait();

        logger.info('KYC verification complete', { did });

        res.json({
            success: true,
            isVerified: true,
            transactionHash: receipt.hash
        });
    } catch (error) {
        logger.error('KYC verification failed:', error);
        res.status(500).json({ error: error.message });
    }
});

/**
 * GET /api/v1/kyc/status/:wallet
 * Gets KYC status for a wallet
 */
app.get('/api/v1/kyc/status/:wallet', authenticateJWT, async (req, res) => {
    try {
        const { wallet } = req.params;

        const [credential, status] = await kycRegistry.getKYCStatus(wallet);

        res.json({
            success: true,
            credential: {
                credentialHash: credential.credentialHash,
                issuedAt: credential.issuedAt.toString(),
                expiresAt: credential.expiresAt.toString(),
                kycLevel: credential.kycLevel,
                isRevoked: credential.isRevoked,
                issuer: credential.issuer
            },
            status: {
                isKYCVerified: status.isKYCVerified,
                isOFACClear: status.isOFACClear,
                isFATFCompliant: status.isFATFCompliant,
                lastChecked: status.lastChecked.toString()
            }
        });
    } catch (error) {
        logger.error('Failed to get KYC status:', error);
        res.status(500).json({ error: error.message });
    }
});

// ============ FINALITY ENDPOINTS ============

/**
 * POST /api/v1/finality/verify-block
 * Verifies a block using light client
 */
app.post('/api/v1/finality/verify-block', authenticateJWT, async (req, res) => {
    try {
        const { chainId, blockProof } = req.body;

        logger.info('Verifying block', { chainId, blockHeight: blockProof.blockHeight });

        const tx = await lightClient.verifyBlock(chainId, blockProof);
        const receipt = await tx.wait();

        logger.info('Block verified', { chainId, blockHeight: blockProof.blockHeight });

        res.json({
            success: true,
            transactionHash: receipt.hash
        });
    } catch (error) {
        logger.error('Block verification failed:', error);
        res.status(500).json({ error: error.message });
    }
});

/**
 * GET /api/v1/finality/checkpoint/:chainId
 * Gets latest finality checkpoint
 */
app.get('/api/v1/finality/checkpoint/:chainId', async (req, res) => {
    try {
        const { chainId } = req.params;

        const checkpoint = await lightClient.getLatestCheckpoint(chainId);

        res.json({
            success: true,
            checkpoint: {
                chainId: checkpoint.chainId.toString(),
                blockHeight: checkpoint.blockHeight.toString(),
                blockHash: checkpoint.blockHash,
                stateRoot: checkpoint.stateRoot,
                timestamp: checkpoint.timestamp.toString(),
                isFinalized: checkpoint.isFinalized,
                confirmations: checkpoint.confirmations.toString()
            }
        });
    } catch (error) {
        logger.error('Failed to get checkpoint:', error);
        res.status(500).json({ error: error.message });
    }
});

// ============ HEALTH CHECK ============

app.get('/health', (req, res) => {
    res.json({ status: 'healthy', timestamp: new Date().toISOString() });
});

// ============ ERROR HANDLING ============

app.use((err, req, res, next) => {
    logger.error('Unhandled error:', err);
    res.status(500).json({ error: 'Internal server error' });
});

// ============ START SERVER ============

const PORT = process.env.PORT || 3000;

app.listen(PORT, () => {
    logger.info(`Settlement Engine API running on port ${PORT}`);
    console.log(`🚀 Server ready at http://localhost:${PORT}`);
});

module.exports = app;
