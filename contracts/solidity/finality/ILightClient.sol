// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ILightClient
 * @notice Interface for zk-SNARK-based light clients
 * @dev Supports verification of cross-chain state transitions
 */
interface ILightClient {
    /// @notice Represents a block header proof
    struct BlockProof {
        uint256 blockHeight;
        bytes32 blockHash;
        bytes32 stateRoot;
        bytes32 receiptsRoot;
        uint256 timestamp;
        bytes32[] proof; // Merkle proof path
        bytes zkProof; // zk-SNARK proof
    }

    /// @notice Represents a finality checkpoint
    struct FinalityCheckpoint {
        uint256 chainId;
        uint256 blockHeight;
        bytes32 blockHash;
        bytes32 stateRoot;
        uint256 timestamp;
        bool isFinalized;
        uint256 confirmations;
    }

    /// @notice Emitted when a new block is verified
    event BlockVerified(
        uint256 indexed chainId,
        uint256 indexed blockHeight,
        bytes32 blockHash,
        bytes32 stateRoot
    );

    /// @notice Emitted when finality is achieved
    event FinalityAchieved(
        uint256 indexed chainId,
        uint256 indexed blockHeight,
        bytes32 blockHash
    );

    /**
     * @notice Verifies a block proof using zk-SNARK
     * @param chainId The source chain identifier
     * @param proof The block proof structure
     * @return success True if verification succeeds
     */
    function verifyBlock(uint256 chainId, BlockProof calldata proof)
        external
        returns (bool success);

    /**
     * @notice Checks if a block has reached finality
     * @param chainId The source chain identifier
     * @param blockHeight The block height to check
     * @return isFinalized True if block is finalized
     */
    function isBlockFinalized(uint256 chainId, uint256 blockHeight)
        external
        view
        returns (bool isFinalized);

    /**
     * @notice Gets the latest finalized checkpoint
     * @param chainId The source chain identifier
     * @return checkpoint The latest finality checkpoint
     */
    function getLatestCheckpoint(uint256 chainId)
        external
        view
        returns (FinalityCheckpoint memory checkpoint);
}
