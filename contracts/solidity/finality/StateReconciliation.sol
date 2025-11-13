// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ILightClient.sol";

/**
 * @title StateReconciliation
 * @notice Handles deterministic state reconciliation across chains
 * @dev Ensures eventual consistency with asynchronous confirmation
 */
contract StateReconciliation {
    /// @notice State transition structure
    struct StateTransition {
        uint256 sourceChain;
        uint256 targetChain;
        bytes32 stateRoot;
        bytes32 transactionHash;
        uint256 nonce;
        uint256 timestamp;
        ReconciliationStatus status;
        bytes payload;
    }

    /// @notice Reconciliation status enum
    enum ReconciliationStatus {
        Pending,
        Confirmed,
        Finalized,
        Disputed,
        Reverted
    }

    /// @notice Mapping of transition ID => state transition
    mapping(bytes32 => StateTransition) public stateTransitions;

    /// @notice Mapping of chainId => nonce counter
    mapping(uint256 => uint256) public chainNonces;

    /// @notice Reference to the light client
    ILightClient public immutable lightClient;

    /// @notice Minimum confirmations required
    uint256 public constant MIN_CONFIRMATIONS = 12;

    /// @notice Events
    event StateTransitionInitiated(
        bytes32 indexed transitionId,
        uint256 indexed sourceChain,
        uint256 indexed targetChain,
        bytes32 stateRoot
    );

    event StateTransitionConfirmed(bytes32 indexed transitionId);
    event StateTransitionFinalized(bytes32 indexed transitionId);
    event StateTransitionDisputed(bytes32 indexed transitionId, string reason);

    constructor(address _lightClient) {
        lightClient = ILightClient(_lightClient);
    }

    /**
     * @notice Initiates a state transition
     * @param sourceChain Source chain identifier
     * @param targetChain Target chain identifier
     * @param stateRoot State root to reconcile
     * @param transactionHash Transaction hash on source chain
     * @param payload Additional data payload
     * @return transitionId The unique transition identifier
     */
    function initiateStateTransition(
        uint256 sourceChain,
        uint256 targetChain,
        bytes32 stateRoot,
        bytes32 transactionHash,
        bytes calldata payload
    ) external returns (bytes32 transitionId) {
        uint256 nonce = chainNonces[sourceChain]++;

        transitionId = keccak256(
            abi.encodePacked(
                sourceChain,
                targetChain,
                stateRoot,
                transactionHash,
                nonce,
                block.timestamp
            )
        );

        StateTransition memory transition = StateTransition({
            sourceChain: sourceChain,
            targetChain: targetChain,
            stateRoot: stateRoot,
            transactionHash: transactionHash,
            nonce: nonce,
            timestamp: block.timestamp,
            status: ReconciliationStatus.Pending,
            payload: payload
        });

        stateTransitions[transitionId] = transition;

        emit StateTransitionInitiated(
            transitionId,
            sourceChain,
            targetChain,
            stateRoot
        );

        return transitionId;
    }

    /**
     * @notice Confirms a state transition using light client proof
     * @param transitionId The transition identifier
     * @param blockHeight Block height on source chain
     * @param proof Merkle proof of inclusion
     */
    function confirmStateTransition(
        bytes32 transitionId,
        uint256 blockHeight,
        bytes32[] calldata proof
    ) external {
        StateTransition storage transition = stateTransitions[transitionId];
        require(
            transition.status == ReconciliationStatus.Pending,
            "Invalid status"
        );

        // Verify block is finalized on source chain
        require(
            lightClient.isBlockFinalized(transition.sourceChain, blockHeight),
            "Block not finalized"
        );

        // Verify state root inclusion (simplified)
        bool isValid = _verifyMerkleProof(
            transition.stateRoot,
            proof,
            transition.transactionHash
        );

        require(isValid, "Invalid merkle proof");

        transition.status = ReconciliationStatus.Confirmed;
        emit StateTransitionConfirmed(transitionId);
    }

    /**
     * @notice Finalizes a confirmed state transition
     * @param transitionId The transition identifier
     */
    function finalizeStateTransition(bytes32 transitionId) external {
        StateTransition storage transition = stateTransitions[transitionId];
        require(
            transition.status == ReconciliationStatus.Confirmed,
            "Not confirmed"
        );

        // Check time elapsed for deterministic finalization
        require(
            block.timestamp >= transition.timestamp + 30 minutes,
            "Finalization period not reached"
        );

        transition.status = ReconciliationStatus.Finalized;
        emit StateTransitionFinalized(transitionId);
    }

    /**
     * @notice Disputes a state transition
     * @param transitionId The transition identifier
     * @param reason Dispute reason
     */
    function disputeStateTransition(
        bytes32 transitionId,
        string calldata reason
    ) external {
        StateTransition storage transition = stateTransitions[transitionId];
        require(
            transition.status != ReconciliationStatus.Finalized,
            "Already finalized"
        );

        transition.status = ReconciliationStatus.Disputed;
        emit StateTransitionDisputed(transitionId, reason);
    }

    /**
     * @notice Verifies a merkle proof
     * @param root The merkle root
     * @param proof The merkle proof path
     * @param leaf The leaf to verify
     * @return isValid True if proof is valid
     */
    function _verifyMerkleProof(
        bytes32 root,
        bytes32[] calldata proof,
        bytes32 leaf
    ) internal pure returns (bool isValid) {
        bytes32 computedHash = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];

            if (computedHash <= proofElement) {
                computedHash = keccak256(
                    abi.encodePacked(computedHash, proofElement)
                );
            } else {
                computedHash = keccak256(
                    abi.encodePacked(proofElement, computedHash)
                );
            }
        }

        return computedHash == root;
    }

    /**
     * @notice Gets the status of a state transition
     * @param transitionId The transition identifier
     * @return transition The state transition
     */
    function getStateTransition(bytes32 transitionId)
        external
        view
        returns (StateTransition memory transition)
    {
        return stateTransitions[transitionId];
    }

    /**
     * @notice Checks if a transition is finalized
     * @param transitionId The transition identifier
     * @return isFinalized True if finalized
     */
    function isTransitionFinalized(bytes32 transitionId)
        external
        view
        returns (bool isFinalized)
    {
        return stateTransitions[transitionId].status ==
            ReconciliationStatus.Finalized;
    }
}
