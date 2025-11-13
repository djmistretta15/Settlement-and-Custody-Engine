// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ILightClient.sol";

/**
 * @title ZKLightClient
 * @notice zk-SNARK based light client for cross-chain finality verification
 * @dev Supports EVM, Cosmos SDK, and Solana chains
 */
contract ZKLightClient is ILightClient {
    /// @notice Minimum confirmations required for finality
    uint256 public constant MIN_CONFIRMATIONS = 64;

    /// @notice Maximum age of a valid proof (in seconds)
    uint256 public constant MAX_PROOF_AGE = 1 hours;

    /// @notice Mapping of chainId => blockHeight => checkpoint
    mapping(uint256 => mapping(uint256 => FinalityCheckpoint)) public checkpoints;

    /// @notice Mapping of chainId => latest finalized block height
    mapping(uint256 => uint256) public latestFinalizedHeight;

    /// @notice Mapping of chainId => verifying key for zk-SNARK
    mapping(uint256 => bytes) public verifyingKeys;

    /// @notice Mapping to prevent replay attacks
    mapping(bytes32 => bool) public processedProofs;

    /// @notice Access control for authorized relayers
    mapping(address => bool) public authorizedRelayers;

    /// @notice Contract owner
    address public owner;

    /// @notice Fraud proof challenge period (in blocks)
    uint256 public challengePeriod = 300; // ~1 hour on Ethereum

    /// @notice Fraud proof challenges
    struct FraudChallenge {
        address challenger;
        uint256 chainId;
        uint256 blockHeight;
        bytes32 disputedBlockHash;
        bytes fraudProof;
        uint256 challengeBlock;
        bool resolved;
    }

    mapping(bytes32 => FraudChallenge) public fraudChallenges;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAuthorizedRelayer() {
        require(authorizedRelayers[msg.sender], "Not authorized relayer");
        _;
    }

    constructor() {
        owner = msg.sender;
        authorizedRelayers[msg.sender] = true;
    }

    /**
     * @notice Registers a verifying key for a chain
     * @param chainId The chain identifier
     * @param vKey The zk-SNARK verifying key
     */
    function registerVerifyingKey(uint256 chainId, bytes calldata vKey)
        external
        onlyOwner
    {
        verifyingKeys[chainId] = vKey;
    }

    /**
     * @notice Adds an authorized relayer
     * @param relayer Address of the relayer
     */
    function addRelayer(address relayer) external onlyOwner {
        authorizedRelayers[relayer] = true;
    }

    /**
     * @notice Removes an authorized relayer
     * @param relayer Address of the relayer
     */
    function removeRelayer(address relayer) external onlyOwner {
        authorizedRelayers[relayer] = false;
    }

    /**
     * @inheritdoc ILightClient
     */
    function verifyBlock(uint256 chainId, BlockProof calldata proof)
        external
        override
        onlyAuthorizedRelayer
        returns (bool success)
    {
        // Prevent replay attacks
        bytes32 proofHash = keccak256(
            abi.encodePacked(
                chainId,
                proof.blockHeight,
                proof.blockHash,
                proof.stateRoot
            )
        );
        require(!processedProofs[proofHash], "Proof already processed");

        // Verify proof age
        require(
            block.timestamp <= proof.timestamp + MAX_PROOF_AGE,
            "Proof too old"
        );

        // Verify sequential block height
        uint256 latestHeight = latestFinalizedHeight[chainId];
        require(
            proof.blockHeight > latestHeight,
            "Block height not sequential"
        );

        // Verify zk-SNARK proof
        require(
            _verifyZKProof(chainId, proof),
            "Invalid zk-SNARK proof"
        );

        // Store checkpoint
        FinalityCheckpoint memory checkpoint = FinalityCheckpoint({
            chainId: chainId,
            blockHeight: proof.blockHeight,
            blockHash: proof.blockHash,
            stateRoot: proof.stateRoot,
            timestamp: proof.timestamp,
            isFinalized: false,
            confirmations: 1
        });

        checkpoints[chainId][proof.blockHeight] = checkpoint;
        processedProofs[proofHash] = true;

        emit BlockVerified(chainId, proof.blockHeight, proof.blockHash, proof.stateRoot);

        // Check if enough confirmations for finality
        _checkFinality(chainId, proof.blockHeight);

        return true;
    }

    /**
     * @notice Verifies the zk-SNARK proof
     * @param chainId The chain identifier
     * @param proof The block proof
     * @return isValid True if proof is valid
     */
    function _verifyZKProof(uint256 chainId, BlockProof calldata proof)
        internal
        view
        returns (bool isValid)
    {
        bytes memory vKey = verifyingKeys[chainId];
        require(vKey.length > 0, "Verifying key not registered");

        // In production, this would call a zk-SNARK verifier contract
        // For now, we simulate verification with basic checks
        bytes32 computedHash = keccak256(
            abi.encodePacked(
                proof.blockHeight,
                proof.stateRoot,
                proof.receiptsRoot,
                proof.timestamp
            )
        );

        // Simplified verification - in production use Groth16 or Plonk verifier
        return computedHash != bytes32(0) && proof.zkProof.length >= 128;
    }

    /**
     * @notice Checks and updates finality status
     * @param chainId The chain identifier
     * @param blockHeight The block height
     */
    function _checkFinality(uint256 chainId, uint256 blockHeight) internal {
        FinalityCheckpoint storage checkpoint = checkpoints[chainId][blockHeight];

        // Simple confirmation counter (in production, use validator signatures)
        checkpoint.confirmations++;

        if (checkpoint.confirmations >= MIN_CONFIRMATIONS && !checkpoint.isFinalized) {
            checkpoint.isFinalized = true;
            latestFinalizedHeight[chainId] = blockHeight;

            emit FinalityAchieved(chainId, blockHeight, checkpoint.blockHash);
        }
    }

    /**
     * @notice Submits a fraud proof challenge
     * @param chainId The chain identifier
     * @param blockHeight The disputed block height
     * @param disputedHash The disputed block hash
     * @param fraudProof The fraud proof data
     */
    function submitFraudProof(
        uint256 chainId,
        uint256 blockHeight,
        bytes32 disputedHash,
        bytes calldata fraudProof
    ) external {
        bytes32 challengeId = keccak256(
            abi.encodePacked(chainId, blockHeight, disputedHash)
        );

        require(!fraudChallenges[challengeId].resolved, "Challenge already resolved");

        FinalityCheckpoint storage checkpoint = checkpoints[chainId][blockHeight];
        require(checkpoint.blockHash != bytes32(0), "Block not found");
        require(!checkpoint.isFinalized, "Block already finalized");

        fraudChallenges[challengeId] = FraudChallenge({
            challenger: msg.sender,
            chainId: chainId,
            blockHeight: blockHeight,
            disputedBlockHash: disputedHash,
            fraudProof: fraudProof,
            challengeBlock: block.number,
            resolved: false
        });
    }

    /**
     * @notice Resolves a fraud proof challenge
     * @param challengeId The challenge identifier
     * @param isValid True if fraud proof is valid
     */
    function resolveFraudProof(bytes32 challengeId, bool isValid)
        external
        onlyOwner
    {
        FraudChallenge storage challenge = fraudChallenges[challengeId];
        require(!challenge.resolved, "Already resolved");
        require(
            block.number >= challenge.challengeBlock + challengePeriod,
            "Challenge period not ended"
        );

        if (isValid) {
            // Revert the fraudulent checkpoint
            FinalityCheckpoint storage checkpoint =
                checkpoints[challenge.chainId][challenge.blockHeight];

            checkpoint.isFinalized = false;
            checkpoint.confirmations = 0;

            // Slash the relayer's stake (if implemented)
        }

        challenge.resolved = true;
    }

    /**
     * @inheritdoc ILightClient
     */
    function isBlockFinalized(uint256 chainId, uint256 blockHeight)
        external
        view
        override
        returns (bool)
    {
        return checkpoints[chainId][blockHeight].isFinalized;
    }

    /**
     * @inheritdoc ILightClient
     */
    function getLatestCheckpoint(uint256 chainId)
        external
        view
        override
        returns (FinalityCheckpoint memory)
    {
        uint256 latestHeight = latestFinalizedHeight[chainId];
        return checkpoints[chainId][latestHeight];
    }

    /**
     * @notice Gets a specific checkpoint
     * @param chainId The chain identifier
     * @param blockHeight The block height
     * @return checkpoint The finality checkpoint
     */
    function getCheckpoint(uint256 chainId, uint256 blockHeight)
        external
        view
        returns (FinalityCheckpoint memory)
    {
        return checkpoints[chainId][blockHeight];
    }
}
