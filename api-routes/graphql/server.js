/**
 * GraphQL API Server for Settlement and Custody Engine
 */

const express = require('express');
const { ApolloServer, gql } = require('apollo-server-express');
const { ethers } = require('ethers');
const winston = require('winston');
require('dotenv').config();

const app = express();

// Logging
const logger = winston.createLogger({
    level: 'info',
    format: winston.format.json(),
    transports: [
        new winston.transports.Console({ format: winston.format.simple() })
    ]
});

// Contract instances
let settlementEngine, lightClient, vault, kycRegistry, provider;

function initializeContracts() {
    provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
    const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

    const settlementABI = require('../../artifacts/contracts/solidity/SettlementEngine.sol/SettlementEngine.json');
    const lightClientABI = require('../../artifacts/contracts/solidity/finality/ZKLightClient.sol/ZKLightClient.json');
    const vaultABI = require('../../artifacts/contracts/solidity/custody/MPCVault.sol/MPCVault.json');
    const kycABI = require('../../artifacts/contracts/solidity/identity/ZKKYCRegistry.sol/ZKKYCRegistry.json');

    settlementEngine = new ethers.Contract(process.env.SETTLEMENT_ENGINE_ADDRESS, settlementABI.abi, wallet);
    lightClient = new ethers.Contract(process.env.LIGHT_CLIENT_ADDRESS, lightClientABI.abi, wallet);
    vault = new ethers.Contract(process.env.VAULT_ADDRESS, vaultABI.abi, wallet);
    kycRegistry = new ethers.Contract(process.env.KYC_REGISTRY_ADDRESS, kycABI.abi, wallet);
}

try {
    initializeContracts();
    logger.info('Contracts initialized successfully');
} catch (error) {
    logger.error('Failed to initialize contracts:', error);
}

// GraphQL Schema
const typeDefs = gql`
    type Settlement {
        instructionId: ID!
        originator: String!
        beneficiary: String!
        sourceChain: String!
        targetChain: String!
        asset: String!
        amount: String!
        vaultId: String!
        status: SettlementStatus!
        createdAt: String!
        settledAt: String
        stateTransitionId: String
    }

    enum SettlementStatus {
        Pending
        FinalityVerified
        ComplianceChecked
        Settled
        Failed
        Disputed
    }

    type SettlementResult {
        success: Boolean!
        instructionId: ID
        transactionHash: String
        error: String
    }

    type Vault {
        vaultId: ID!
        threshold: Int!
        totalSigners: Int!
        signers: [String!]!
        isActive: Boolean!
        createdAt: String!
    }

    type Proposal {
        proposalId: ID!
        vaultId: ID!
        to: String!
        value: String!
        chainId: String!
        status: ProposalStatus!
        approvalCount: Int!
        createdAt: String!
        executedAt: String
    }

    enum ProposalStatus {
        Pending
        Approved
        Executed
        Rejected
        Expired
    }

    type KYCCredential {
        credentialHash: String!
        issuedAt: String!
        expiresAt: String!
        kycLevel: KYCLevel!
        isRevoked: Boolean!
        issuer: String!
    }

    enum KYCLevel {
        None
        Basic
        Enhanced
        Institutional
    }

    type ComplianceStatus {
        isKYCVerified: Boolean!
        isOFACClear: Boolean!
        isFATFCompliant: Boolean!
        lastChecked: String!
    }

    type KYCStatus {
        credential: KYCCredential!
        status: ComplianceStatus!
    }

    type FinalityCheckpoint {
        chainId: String!
        blockHeight: String!
        blockHash: String!
        stateRoot: String!
        timestamp: String!
        isFinalized: Boolean!
        confirmations: String!
    }

    input BlockProofInput {
        blockHeight: String!
        blockHash: String!
        stateRoot: String!
        receiptsRoot: String!
        timestamp: String!
        proof: [String!]!
        zkProof: String!
    }

    input InitiateSettlementInput {
        beneficiary: String!
        sourceChain: String!
        targetChain: String!
        asset: String!
        amount: String!
        vaultId: String!
        metadata: String
    }

    input ExecuteSettlementInput {
        instructionId: ID!
        blockHeight: String!
        blockProof: BlockProofInput!
        kycProof: String!
        travelRuleProof: String!
    }

    type Query {
        # Settlement queries
        settlement(instructionId: ID!): Settlement
        settlements(limit: Int, offset: Int): [Settlement!]!

        # Custody queries
        vault(vaultId: ID!): Vault
        proposal(vaultId: ID!, proposalId: ID!): Proposal

        # KYC queries
        kycStatus(wallet: String!): KYCStatus
        isWalletKYCVerified(wallet: String!): Boolean!

        # Finality queries
        checkpoint(chainId: String!): FinalityCheckpoint
        isBlockFinalized(chainId: String!, blockHeight: String!): Boolean!

        # Health
        health: String!
    }

    type Mutation {
        # Settlement mutations
        initiateSettlement(input: InitiateSettlementInput!): SettlementResult!
        executeSettlement(input: ExecuteSettlementInput!): SettlementResult!

        # Custody mutations
        createVault(vaultId: String!, threshold: Int!, signers: [String!]!): SettlementResult!
        createProposal(vaultId: String!, to: String!, value: String!, data: String, chainId: String!): SettlementResult!
        approveProposal(vaultId: String!, proposalId: String!, signature: String!): SettlementResult!

        # KYC mutations
        issueCredential(did: String!, wallet: String!, credentialHash: String!, kycLevel: Int!, validityPeriod: String!): SettlementResult!
        verifyKYCCompliance(did: String!, zkProof: String!, publicInputs: [String!]!): SettlementResult!

        # Finality mutations
        verifyBlock(chainId: String!, blockProof: BlockProofInput!): SettlementResult!
    }
`;

// Resolvers
const resolvers = {
    Query: {
        settlement: async (_, { instructionId }) => {
            try {
                const settlement = await settlementEngine.getSettlement(instructionId);
                return formatSettlement(settlement);
            } catch (error) {
                logger.error('Failed to get settlement:', error);
                throw new Error(error.message);
            }
        },

        vault: async (_, { vaultId }) => {
            try {
                const vaultData = await vault.vaults(ethers.id(vaultId));
                const signers = await vault.getVaultSigners(ethers.id(vaultId));

                return {
                    vaultId,
                    threshold: vaultData.threshold.toString(),
                    totalSigners: vaultData.totalSigners.toString(),
                    signers,
                    isActive: vaultData.isActive,
                    createdAt: vaultData.createdAt.toString()
                };
            } catch (error) {
                logger.error('Failed to get vault:', error);
                throw new Error(error.message);
            }
        },

        kycStatus: async (_, { wallet }) => {
            try {
                const [credential, status] = await kycRegistry.getKYCStatus(wallet);

                return {
                    credential: {
                        credentialHash: credential.credentialHash,
                        issuedAt: credential.issuedAt.toString(),
                        expiresAt: credential.expiresAt.toString(),
                        kycLevel: ['None', 'Basic', 'Enhanced', 'Institutional'][credential.kycLevel],
                        isRevoked: credential.isRevoked,
                        issuer: credential.issuer
                    },
                    status: {
                        isKYCVerified: status.isKYCVerified,
                        isOFACClear: status.isOFACClear,
                        isFATFCompliant: status.isFATFCompliant,
                        lastChecked: status.lastChecked.toString()
                    }
                };
            } catch (error) {
                logger.error('Failed to get KYC status:', error);
                throw new Error(error.message);
            }
        },

        isWalletKYCVerified: async (_, { wallet }) => {
            try {
                return await kycRegistry.isWalletKYCVerified(wallet);
            } catch (error) {
                logger.error('Failed to check KYC verification:', error);
                throw new Error(error.message);
            }
        },

        checkpoint: async (_, { chainId }) => {
            try {
                const checkpoint = await lightClient.getLatestCheckpoint(chainId);

                return {
                    chainId: checkpoint.chainId.toString(),
                    blockHeight: checkpoint.blockHeight.toString(),
                    blockHash: checkpoint.blockHash,
                    stateRoot: checkpoint.stateRoot,
                    timestamp: checkpoint.timestamp.toString(),
                    isFinalized: checkpoint.isFinalized,
                    confirmations: checkpoint.confirmations.toString()
                };
            } catch (error) {
                logger.error('Failed to get checkpoint:', error);
                throw new Error(error.message);
            }
        },

        isBlockFinalized: async (_, { chainId, blockHeight }) => {
            try {
                return await lightClient.isBlockFinalized(chainId, blockHeight);
            } catch (error) {
                logger.error('Failed to check block finality:', error);
                throw new Error(error.message);
            }
        },

        health: () => 'OK'
    },

    Mutation: {
        initiateSettlement: async (_, { input }) => {
            try {
                const {
                    beneficiary,
                    sourceChain,
                    targetChain,
                    asset,
                    amount,
                    vaultId,
                    metadata
                } = input;

                logger.info('Initiating settlement via GraphQL', { beneficiary, amount });

                const tx = await settlementEngine.initiateSettlement(
                    beneficiary,
                    sourceChain,
                    targetChain,
                    asset,
                    amount,
                    ethers.id(vaultId),
                    ethers.hexlify(ethers.toUtf8Bytes(metadata || '{}'))
                );

                const receipt = await tx.wait();
                const event = receipt.logs.find(log => log.fragment?.name === 'SettlementInitiated');

                return {
                    success: true,
                    instructionId: event ? event.args.instructionId : null,
                    transactionHash: receipt.hash
                };
            } catch (error) {
                logger.error('Settlement initiation failed:', error);
                return {
                    success: false,
                    error: error.message
                };
            }
        },

        executeSettlement: async (_, { input }) => {
            try {
                const {
                    instructionId,
                    blockHeight,
                    blockProof,
                    kycProof,
                    travelRuleProof
                } = input;

                logger.info('Executing settlement via GraphQL', { instructionId });

                const tx = await settlementEngine.settleAndVerify(
                    instructionId,
                    blockHeight,
                    blockProof,
                    kycProof,
                    travelRuleProof
                );

                const receipt = await tx.wait();

                return {
                    success: true,
                    transactionHash: receipt.hash
                };
            } catch (error) {
                logger.error('Settlement execution failed:', error);
                return {
                    success: false,
                    error: error.message
                };
            }
        },

        createVault: async (_, { vaultId, threshold, signers }) => {
            try {
                logger.info('Creating vault via GraphQL', { vaultId, threshold });

                const tx = await vault.createVault(
                    ethers.id(vaultId),
                    threshold,
                    signers
                );

                const receipt = await tx.wait();

                return {
                    success: true,
                    transactionHash: receipt.hash
                };
            } catch (error) {
                logger.error('Vault creation failed:', error);
                return {
                    success: false,
                    error: error.message
                };
            }
        },

        issueCredential: async (_, { did, wallet, credentialHash, kycLevel, validityPeriod }) => {
            try {
                logger.info('Issuing KYC credential via GraphQL', { did, wallet });

                const tx = await kycRegistry.issueCredential(
                    ethers.id(did),
                    wallet,
                    ethers.id(credentialHash),
                    kycLevel,
                    validityPeriod
                );

                const receipt = await tx.wait();

                return {
                    success: true,
                    transactionHash: receipt.hash
                };
            } catch (error) {
                logger.error('KYC credential issuance failed:', error);
                return {
                    success: false,
                    error: error.message
                };
            }
        },

        verifyBlock: async (_, { chainId, blockProof }) => {
            try {
                logger.info('Verifying block via GraphQL', { chainId });

                const tx = await lightClient.verifyBlock(chainId, blockProof);
                const receipt = await tx.wait();

                return {
                    success: true,
                    transactionHash: receipt.hash
                };
            } catch (error) {
                logger.error('Block verification failed:', error);
                return {
                    success: false,
                    error: error.message
                };
            }
        }
    }
};

// Helper functions
function formatSettlement(settlement) {
    return {
        instructionId: settlement.instructionId,
        originator: settlement.originator,
        beneficiary: settlement.beneficiary,
        sourceChain: settlement.sourceChain.toString(),
        targetChain: settlement.targetChain.toString(),
        asset: settlement.asset,
        amount: settlement.amount.toString(),
        vaultId: settlement.vaultId,
        status: ['Pending', 'FinalityVerified', 'ComplianceChecked', 'Settled', 'Failed', 'Disputed'][settlement.status],
        createdAt: settlement.createdAt.toString(),
        settledAt: settlement.settledAt.toString(),
        stateTransitionId: settlement.stateTransitionId
    };
}

// Create Apollo Server
const server = new ApolloServer({
    typeDefs,
    resolvers,
    context: ({ req }) => {
        // Add authentication context here if needed
        return { user: req.user };
    },
    formatError: (error) => {
        logger.error('GraphQL Error:', error);
        return error;
    }
});

// Start server
async function startServer() {
    await server.start();
    server.applyMiddleware({ app, path: '/graphql' });

    const PORT = process.env.GRAPHQL_PORT || 4000;

    app.listen(PORT, () => {
        logger.info(`GraphQL server running on port ${PORT}`);
        console.log(`🚀 Server ready at http://localhost:${PORT}${server.graphqlPath}`);
    });
}

startServer();

module.exports = { server, app };
