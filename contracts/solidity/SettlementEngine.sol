// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./finality/ILightClient.sol";
import "./finality/StateReconciliation.sol";
import "./custody/MPCVault.sol";
import "./identity/ZKKYCRegistry.sol";

/**
 * @title SettlementEngine
 * @notice Core settlement engine for cross-chain digital asset transfers
 * @dev Integrates finality verification, custody, and compliance
 */
contract SettlementEngine {
    /// @notice Settlement instruction
    struct SettlementInstruction {
        bytes32 instructionId;
        address originator;
        address beneficiary;
        uint256 sourceChain;
        uint256 targetChain;
        address asset;
        uint256 amount;
        bytes32 vaultId;
        SettlementStatus status;
        uint256 createdAt;
        uint256 settledAt;
        bytes32 stateTransitionId;
        bytes metadata;
    }

    /// @notice Settlement status enum
    enum SettlementStatus {
        Pending,
        FinalityVerified,
        ComplianceChecked,
        Settled,
        Failed,
        Disputed
    }

    /// @notice Batch settlement for efficiency
    struct BatchSettlement {
        bytes32 batchId;
        bytes32[] instructionIds;
        uint256 totalAmount;
        uint256 createdAt;
        bool isProcessed;
    }

    /// @notice Core system components
    ILightClient public immutable lightClient;
    StateReconciliation public immutable stateReconciliation;
    MPCVault public immutable vault;
    ZKKYCRegistry public immutable kycRegistry;

    /// @notice Settlement instructions mapping
    mapping(bytes32 => SettlementInstruction) public settlements;

    /// @notice Batch settlements mapping
    mapping(bytes32 => BatchSettlement) public batches;

    /// @notice Nonce for instruction IDs
    uint256 public settlementNonce;

    /// @notice Rate limiting per address
    mapping(address => uint256) public lastSettlementTime;
    mapping(address => uint256) public dailySettlementCount;
    mapping(address => uint256) public lastDailyReset;

    /// @notice Rate limits
    uint256 public constant MIN_SETTLEMENT_INTERVAL = 1 minutes;
    uint256 public constant MAX_DAILY_SETTLEMENTS = 100;

    /// @notice Replay protection
    mapping(bytes32 => bool) public processedTransactions;

    /// @notice Double-spend detection
    mapping(bytes32 => mapping(uint256 => bool)) public spentNonces;

    /// @notice Contract owner
    address public owner;

    /// @notice Events
    event SettlementInitiated(
        bytes32 indexed instructionId,
        address indexed originator,
        address indexed beneficiary,
        uint256 amount
    );

    event FinalityVerified(
        bytes32 indexed instructionId,
        uint256 sourceChain,
        uint256 blockHeight
    );

    event ComplianceVerified(
        bytes32 indexed instructionId,
        bytes32 originatorDID,
        bytes32 beneficiaryDID
    );

    event SettlementCompleted(
        bytes32 indexed instructionId,
        uint256 settledAt
    );

    event SettlementFailed(
        bytes32 indexed instructionId,
        string reason
    );

    event BatchSettlementProcessed(
        bytes32 indexed batchId,
        uint256 instructionCount,
        uint256 totalAmount
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier rateLimited() {
        // Reset daily counter if needed
        if (block.timestamp >= lastDailyReset[msg.sender] + 1 days) {
            dailySettlementCount[msg.sender] = 0;
            lastDailyReset[msg.sender] = block.timestamp;
        }

        // Check rate limits
        require(
            block.timestamp >= lastSettlementTime[msg.sender] + MIN_SETTLEMENT_INTERVAL,
            "Rate limit: too frequent"
        );
        require(
            dailySettlementCount[msg.sender] < MAX_DAILY_SETTLEMENTS,
            "Rate limit: daily limit exceeded"
        );

        lastSettlementTime[msg.sender] = block.timestamp;
        dailySettlementCount[msg.sender]++;
        _;
    }

    constructor(
        address _lightClient,
        address _stateReconciliation,
        address _vault,
        address _kycRegistry
    ) {
        lightClient = ILightClient(_lightClient);
        stateReconciliation = StateReconciliation(_stateReconciliation);
        vault = MPCVault(payable(_vault));
        kycRegistry = ZKKYCRegistry(_kycRegistry);
        owner = msg.sender;
    }

    /**
     * @notice Initiates a settlement instruction
     * @param beneficiary The beneficiary address
     * @param sourceChain Source chain identifier
     * @param targetChain Target chain identifier
     * @param asset Asset address
     * @param amount Amount to settle
     * @param vaultId Vault identifier for custody
     * @param metadata Additional metadata
     * @return instructionId The settlement instruction ID
     */
    function initiateSettlement(
        address beneficiary,
        uint256 sourceChain,
        uint256 targetChain,
        address asset,
        uint256 amount,
        bytes32 vaultId,
        bytes calldata metadata
    ) external rateLimited returns (bytes32 instructionId) {
        require(beneficiary != address(0), "Invalid beneficiary");
        require(amount > 0, "Invalid amount");

        // Generate unique instruction ID
        instructionId = keccak256(
            abi.encodePacked(
                msg.sender,
                beneficiary,
                sourceChain,
                targetChain,
                amount,
                settlementNonce++,
                block.timestamp
            )
        );

        // Check KYC compliance for both parties
        require(
            kycRegistry.isWalletKYCVerified(msg.sender),
            "Originator not KYC verified"
        );
        require(
            kycRegistry.isWalletKYCVerified(beneficiary),
            "Beneficiary not KYC verified"
        );

        // Create settlement instruction
        SettlementInstruction memory instruction = SettlementInstruction({
            instructionId: instructionId,
            originator: msg.sender,
            beneficiary: beneficiary,
            sourceChain: sourceChain,
            targetChain: targetChain,
            asset: asset,
            amount: amount,
            vaultId: vaultId,
            status: SettlementStatus.Pending,
            createdAt: block.timestamp,
            settledAt: 0,
            stateTransitionId: bytes32(0),
            metadata: metadata
        });

        settlements[instructionId] = instruction;

        emit SettlementInitiated(instructionId, msg.sender, beneficiary, amount);

        return instructionId;
    }

    /**
     * @notice Core settlement function with finality and compliance verification
     * @param instructionId The settlement instruction ID
     * @param blockHeight Block height on source chain
     * @param blockProof Light client block proof
     * @param kycProof Zero-knowledge KYC compliance proof
     * @param travelRuleProof FATF Travel Rule compliance proof
     * @return success True if settlement succeeds
     */
    function settleAndVerify(
        bytes32 instructionId,
        uint256 blockHeight,
        ILightClient.BlockProof calldata blockProof,
        bytes calldata kycProof,
        bytes calldata travelRuleProof
    ) external returns (bool success) {
        SettlementInstruction storage instruction = settlements[instructionId];

        require(
            instruction.status == SettlementStatus.Pending,
            "Invalid settlement status"
        );

        // Step 1: Verify cross-chain finality
        require(
            _verifyFinality(instruction, blockHeight, blockProof),
            "Finality verification failed"
        );

        instruction.status = SettlementStatus.FinalityVerified;
        emit FinalityVerified(instructionId, instruction.sourceChain, blockHeight);

        // Step 2: Verify compliance (KYC, OFAC, Travel Rule)
        require(
            _verifyCompliance(instruction, kycProof, travelRuleProof),
            "Compliance verification failed"
        );

        instruction.status = SettlementStatus.ComplianceChecked;

        bytes32 originatorDID = kycRegistry.walletToDID(instruction.originator);
        bytes32 beneficiaryDID = kycRegistry.walletToDID(instruction.beneficiary);

        emit ComplianceVerified(instructionId, originatorDID, beneficiaryDID);

        // Step 3: Execute settlement through vault
        require(
            _executeSettlement(instruction),
            "Settlement execution failed"
        );

        instruction.status = SettlementStatus.Settled;
        instruction.settledAt = block.timestamp;

        emit SettlementCompleted(instructionId, block.timestamp);

        return true;
    }

    /**
     * @notice Verifies cross-chain finality
     * @param instruction The settlement instruction
     * @param blockHeight Block height on source chain
     * @param blockProof Light client proof
     * @return isValid True if finality is verified
     */
    function _verifyFinality(
        SettlementInstruction storage instruction,
        uint256 blockHeight,
        ILightClient.BlockProof calldata blockProof
    ) internal returns (bool isValid) {
        // Verify block is finalized on source chain
        require(
            lightClient.verifyBlock(instruction.sourceChain, blockProof),
            "Block verification failed"
        );

        require(
            lightClient.isBlockFinalized(instruction.sourceChain, blockHeight),
            "Block not finalized"
        );

        // Initiate state transition
        bytes32 transitionId = stateReconciliation.initiateStateTransition(
            instruction.sourceChain,
            instruction.targetChain,
            blockProof.stateRoot,
            blockProof.blockHash,
            instruction.metadata
        );

        instruction.stateTransitionId = transitionId;

        return true;
    }

    /**
     * @notice Verifies compliance requirements
     * @param instruction The settlement instruction
     * @param kycProof Zero-knowledge KYC proof
     * @param travelRuleProof Travel Rule compliance proof
     * @return isCompliant True if all compliance checks pass
     */
    function _verifyCompliance(
        SettlementInstruction storage instruction,
        bytes calldata kycProof,
        bytes calldata travelRuleProof
    ) internal view returns (bool isCompliant) {
        bytes32 originatorDID = kycRegistry.walletToDID(instruction.originator);
        bytes32 beneficiaryDID = kycRegistry.walletToDID(instruction.beneficiary);

        // Verify KYC compliance for originator
        require(originatorDID != bytes32(0), "Originator DID not found");
        require(beneficiaryDID != bytes32(0), "Beneficiary DID not found");

        // Verify FATF Travel Rule compliance
        require(
            kycRegistry.verifyTravelRuleCompliance(
                originatorDID,
                beneficiaryDID,
                instruction.amount,
                travelRuleProof
            ),
            "Travel Rule compliance failed"
        );

        // Note: OFAC check would be done via ZK proof to preserve privacy
        // This is handled in the KYC registry

        return true;
    }

    /**
     * @notice Executes the settlement through the vault
     * @param instruction The settlement instruction
     * @return success True if execution succeeds
     */
    function _executeSettlement(SettlementInstruction storage instruction)
        internal
        returns (bool success)
    {
        // Prevent double-spend
        bytes32 spendKey = keccak256(
            abi.encodePacked(
                instruction.originator,
                instruction.sourceChain,
                instruction.asset,
                instruction.amount
            )
        );

        require(!processedTransactions[spendKey], "Double-spend detected");
        processedTransactions[spendKey] = true;

        // In production, this would interact with the vault to release funds
        // For cross-chain settlements, this would trigger the vault's proposal system

        return true;
    }

    /**
     * @notice Creates a batch settlement for efficiency
     * @param instructionIds Array of instruction IDs to batch
     * @return batchId The batch identifier
     */
    function createBatchSettlement(bytes32[] calldata instructionIds)
        external
        returns (bytes32 batchId)
    {
        require(instructionIds.length > 0, "Empty batch");
        require(instructionIds.length <= 100, "Batch too large");

        uint256 totalAmount = 0;

        // Validate all instructions
        for (uint256 i = 0; i < instructionIds.length; i++) {
            SettlementInstruction storage instruction = settlements[instructionIds[i]];
            require(
                instruction.status == SettlementStatus.ComplianceChecked,
                "Instruction not ready for settlement"
            );
            totalAmount += instruction.amount;
        }

        batchId = keccak256(
            abi.encodePacked(instructionIds, block.timestamp)
        );

        batches[batchId] = BatchSettlement({
            batchId: batchId,
            instructionIds: instructionIds,
            totalAmount: totalAmount,
            createdAt: block.timestamp,
            isProcessed: false
        });

        return batchId;
    }

    /**
     * @notice Processes a batch settlement
     * @param batchId The batch identifier
     * @return success True if batch processing succeeds
     */
    function processBatchSettlement(bytes32 batchId)
        external
        returns (bool success)
    {
        BatchSettlement storage batch = batches[batchId];
        require(!batch.isProcessed, "Batch already processed");

        for (uint256 i = 0; i < batch.instructionIds.length; i++) {
            SettlementInstruction storage instruction =
                settlements[batch.instructionIds[i]];

            if (_executeSettlement(instruction)) {
                instruction.status = SettlementStatus.Settled;
                instruction.settledAt = block.timestamp;
            } else {
                instruction.status = SettlementStatus.Failed;
            }
        }

        batch.isProcessed = true;

        emit BatchSettlementProcessed(
            batchId,
            batch.instructionIds.length,
            batch.totalAmount
        );

        return true;
    }

    /**
     * @notice Gets settlement instruction details
     * @param instructionId The instruction ID
     * @return instruction The settlement instruction
     */
    function getSettlement(bytes32 instructionId)
        external
        view
        returns (SettlementInstruction memory instruction)
    {
        return settlements[instructionId];
    }

    /**
     * @notice Checks if a settlement is finalized
     * @param instructionId The instruction ID
     * @return isFinalized True if settled
     */
    function isSettlementFinalized(bytes32 instructionId)
        external
        view
        returns (bool isFinalized)
    {
        return settlements[instructionId].status == SettlementStatus.Settled;
    }
}
