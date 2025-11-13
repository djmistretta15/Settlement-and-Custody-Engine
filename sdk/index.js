/**
 * Settlement and Custody Engine SDK
 * Modular SDK for integration into banks, protocols, and wallets
 */

const { ethers } = require('ethers');
const axios = require('axios');

class SettlementEngineSDK {
    /**
     * Initialize the SDK
     * @param {Object} config - Configuration object
     * @param {string} config.rpcUrl - RPC endpoint URL
     * @param {string} config.privateKey - Private key for signing transactions
     * @param {string} config.apiUrl - API endpoint URL (optional)
     * @param {Object} config.contractAddresses - Contract addresses
     */
    constructor(config) {
        this.config = config;
        this.provider = new ethers.JsonRpcProvider(config.rpcUrl);
        this.wallet = new ethers.Wallet(config.privateKey, this.provider);
        this.apiUrl = config.apiUrl;

        // Initialize contract instances
        this._initializeContracts(config.contractAddresses);
    }

    _initializeContracts(addresses) {
        // Load ABIs (in production, these would be imported from artifacts)
        const settlementABI = require('../artifacts/contracts/solidity/SettlementEngine.sol/SettlementEngine.json');
        const lightClientABI = require('../artifacts/contracts/solidity/finality/ZKLightClient.sol/ZKLightClient.json');
        const vaultABI = require('../artifacts/contracts/solidity/custody/MPCVault.sol/MPCVault.json');
        const kycABI = require('../artifacts/contracts/solidity/identity/ZKKYCRegistry.sol/ZKKYCRegistry.json');

        this.settlementEngine = new ethers.Contract(
            addresses.settlementEngine,
            settlementABI.abi,
            this.wallet
        );

        this.lightClient = new ethers.Contract(
            addresses.lightClient,
            lightClientABI.abi,
            this.wallet
        );

        this.vault = new ethers.Contract(
            addresses.vault,
            vaultABI.abi,
            this.wallet
        );

        this.kycRegistry = new ethers.Contract(
            addresses.kycRegistry,
            kycABI.abi,
            this.wallet
        );
    }

    // ============ SETTLEMENT METHODS ============

    /**
     * Initiates a cross-chain settlement
     * @param {Object} params - Settlement parameters
     * @returns {Promise<Object>} - Transaction result with instruction ID
     */
    async initiateSettlement(params) {
        const {
            beneficiary,
            sourceChain,
            targetChain,
            asset,
            amount,
            vaultId,
            metadata = {}
        } = params;

        try {
            const tx = await this.settlementEngine.initiateSettlement(
                beneficiary,
                sourceChain,
                targetChain,
                asset,
                ethers.parseUnits(amount.toString(), 18),
                ethers.id(vaultId),
                ethers.hexlify(ethers.toUtf8Bytes(JSON.stringify(metadata)))
            );

            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment?.name === 'SettlementInitiated');
            const instructionId = event ? event.args.instructionId : null;

            return {
                success: true,
                instructionId,
                transactionHash: receipt.hash,
                gasUsed: receipt.gasUsed.toString()
            };
        } catch (error) {
            return {
                success: false,
                error: error.message
            };
        }
    }

    /**
     * Executes a settlement with finality and compliance verification
     * @param {Object} params - Execution parameters
     * @returns {Promise<Object>} - Transaction result
     */
    async executeSettlement(params) {
        const {
            instructionId,
            blockHeight,
            blockProof,
            kycProof,
            travelRuleProof
        } = params;

        try {
            const tx = await this.settlementEngine.settleAndVerify(
                instructionId,
                blockHeight,
                blockProof,
                kycProof,
                travelRuleProof
            );

            const receipt = await tx.wait();

            return {
                success: true,
                transactionHash: receipt.hash,
                gasUsed: receipt.gasUsed.toString()
            };
        } catch (error) {
            return {
                success: false,
                error: error.message
            };
        }
    }

    /**
     * Gets settlement instruction details
     * @param {string} instructionId - Instruction ID
     * @returns {Promise<Object>} - Settlement details
     */
    async getSettlement(instructionId) {
        try {
            const settlement = await this.settlementEngine.getSettlement(instructionId);

            return {
                instructionId: settlement.instructionId,
                originator: settlement.originator,
                beneficiary: settlement.beneficiary,
                sourceChain: settlement.sourceChain.toString(),
                targetChain: settlement.targetChain.toString(),
                asset: settlement.asset,
                amount: ethers.formatUnits(settlement.amount, 18),
                status: settlement.status,
                createdAt: new Date(Number(settlement.createdAt) * 1000),
                settledAt: settlement.settledAt > 0 ? new Date(Number(settlement.settledAt) * 1000) : null
            };
        } catch (error) {
            throw new Error(`Failed to get settlement: ${error.message}`);
        }
    }

    // ============ CUSTODY METHODS ============

    /**
     * Creates a new MPC vault
     * @param {Object} params - Vault parameters
     * @returns {Promise<Object>} - Transaction result
     */
    async createVault(params) {
        const { vaultId, threshold, signers } = params;

        try {
            const tx = await this.vault.createVault(
                ethers.id(vaultId),
                threshold,
                signers
            );

            const receipt = await tx.wait();

            return {
                success: true,
                vaultId: ethers.id(vaultId),
                transactionHash: receipt.hash
            };
        } catch (error) {
            return {
                success: false,
                error: error.message
            };
        }
    }

    /**
     * Proposes a transaction from the vault
     * @param {Object} params - Proposal parameters
     * @returns {Promise<Object>} - Transaction result with proposal ID
     */
    async proposeTransaction(params) {
        const { vaultId, to, value, data = '0x', chainId } = params;

        try {
            const tx = await this.vault.proposeTransaction(
                ethers.id(vaultId),
                to,
                ethers.parseEther(value.toString()),
                data,
                chainId
            );

            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment?.name === 'ProposalCreated');
            const proposalId = event ? event.args.proposalId.toString() : null;

            return {
                success: true,
                proposalId,
                transactionHash: receipt.hash
            };
        } catch (error) {
            return {
                success: false,
                error: error.message
            };
        }
    }

    /**
     * Approves a vault proposal with threshold signature
     * @param {Object} params - Approval parameters
     * @returns {Promise<Object>} - Transaction result
     */
    async approveProposal(params) {
        const { vaultId, proposalId, signature } = params;

        try {
            const tx = await this.vault.approveProposal(
                ethers.id(vaultId),
                proposalId,
                signature
            );

            const receipt = await tx.wait();

            return {
                success: true,
                transactionHash: receipt.hash
            };
        } catch (error) {
            return {
                success: false,
                error: error.message
            };
        }
    }

    // ============ KYC METHODS ============

    /**
     * Issues a KYC credential
     * @param {Object} params - Credential parameters
     * @returns {Promise<Object>} - Transaction result
     */
    async issueKYCCredential(params) {
        const { did, wallet, credentialHash, kycLevel, validityPeriod } = params;

        try {
            const tx = await this.kycRegistry.issueCredential(
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
            return {
                success: false,
                error: error.message
            };
        }
    }

    /**
     * Verifies KYC compliance using zero-knowledge proof
     * @param {Object} params - Verification parameters
     * @returns {Promise<Object>} - Verification result
     */
    async verifyKYCCompliance(params) {
        const { did, zkProof, publicInputs } = params;

        try {
            const tx = await this.kycRegistry.verifyKYCCompliance(
                ethers.id(did),
                zkProof,
                publicInputs
            );

            const receipt = await tx.wait();

            return {
                success: true,
                transactionHash: receipt.hash
            };
        } catch (error) {
            return {
                success: false,
                error: error.message
            };
        }
    }

    /**
     * Checks if a wallet is KYC verified
     * @param {string} walletAddress - Wallet address
     * @returns {Promise<boolean>} - Verification status
     */
    async isWalletKYCVerified(walletAddress) {
        return await this.kycRegistry.isWalletKYCVerified(walletAddress);
    }

    /**
     * Gets KYC status for a wallet
     * @param {string} walletAddress - Wallet address
     * @returns {Promise<Object>} - KYC status
     */
    async getKYCStatus(walletAddress) {
        try {
            const [credential, status] = await this.kycRegistry.getKYCStatus(walletAddress);

            return {
                credential: {
                    credentialHash: credential.credentialHash,
                    issuedAt: new Date(Number(credential.issuedAt) * 1000),
                    expiresAt: new Date(Number(credential.expiresAt) * 1000),
                    kycLevel: Number(credential.kycLevel),
                    isRevoked: credential.isRevoked,
                    issuer: credential.issuer
                },
                status: {
                    isKYCVerified: status.isKYCVerified,
                    isOFACClear: status.isOFACClear,
                    isFATFCompliant: status.isFATFCompliant,
                    lastChecked: new Date(Number(status.lastChecked) * 1000)
                }
            };
        } catch (error) {
            throw new Error(`Failed to get KYC status: ${error.message}`);
        }
    }

    // ============ FINALITY METHODS ============

    /**
     * Verifies a block using the light client
     * @param {Object} params - Verification parameters
     * @returns {Promise<Object>} - Verification result
     */
    async verifyBlock(params) {
        const { chainId, blockProof } = params;

        try {
            const tx = await this.lightClient.verifyBlock(chainId, blockProof);
            const receipt = await tx.wait();

            return {
                success: true,
                transactionHash: receipt.hash
            };
        } catch (error) {
            return {
                success: false,
                error: error.message
            };
        }
    }

    /**
     * Checks if a block is finalized
     * @param {number} chainId - Chain identifier
     * @param {number} blockHeight - Block height
     * @returns {Promise<boolean>} - Finalization status
     */
    async isBlockFinalized(chainId, blockHeight) {
        return await this.lightClient.isBlockFinalized(chainId, blockHeight);
    }

    /**
     * Gets the latest finality checkpoint
     * @param {number} chainId - Chain identifier
     * @returns {Promise<Object>} - Checkpoint data
     */
    async getLatestCheckpoint(chainId) {
        try {
            const checkpoint = await this.lightClient.getLatestCheckpoint(chainId);

            return {
                chainId: checkpoint.chainId.toString(),
                blockHeight: checkpoint.blockHeight.toString(),
                blockHash: checkpoint.blockHash,
                stateRoot: checkpoint.stateRoot,
                timestamp: new Date(Number(checkpoint.timestamp) * 1000),
                isFinalized: checkpoint.isFinalized,
                confirmations: checkpoint.confirmations.toString()
            };
        } catch (error) {
            throw new Error(`Failed to get checkpoint: ${error.message}`);
        }
    }

    // ============ API METHODS (if API URL provided) ============

    /**
     * Makes an API request
     * @param {string} method - HTTP method
     * @param {string} endpoint - API endpoint
     * @param {Object} data - Request data
     * @returns {Promise<Object>} - API response
     */
    async _apiRequest(method, endpoint, data = null) {
        if (!this.apiUrl) {
            throw new Error('API URL not configured');
        }

        try {
            const response = await axios({
                method,
                url: `${this.apiUrl}${endpoint}`,
                data,
                headers: {
                    'Content-Type': 'application/json'
                }
            });

            return response.data;
        } catch (error) {
            throw new Error(`API request failed: ${error.message}`);
        }
    }

    /**
     * Initiates settlement via API
     * @param {Object} params - Settlement parameters
     * @returns {Promise<Object>} - API response
     */
    async initiateSettlementAPI(params) {
        return await this._apiRequest('POST', '/api/v1/settlement/initiate', params);
    }

    /**
     * Gets settlement via API
     * @param {string} instructionId - Instruction ID
     * @returns {Promise<Object>} - API response
     */
    async getSettlementAPI(instructionId) {
        return await this._apiRequest('GET', `/api/v1/settlement/${instructionId}`);
    }
}

module.exports = SettlementEngineSDK;

// Example usage
if (require.main === module) {
    const sdk = new SettlementEngineSDK({
        rpcUrl: 'http://localhost:8545',
        privateKey: '0x' + '0'.repeat(64), // Example private key
        apiUrl: 'http://localhost:3000',
        contractAddresses: {
            settlementEngine: '0x' + '1'.repeat(40),
            lightClient: '0x' + '2'.repeat(40),
            vault: '0x' + '3'.repeat(40),
            kycRegistry: '0x' + '4'.repeat(40)
        }
    });

    console.log('SDK initialized successfully');
    console.log('Available methods:', Object.getOwnPropertyNames(SettlementEngineSDK.prototype));
}
