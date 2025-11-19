// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IFinalityVerifier
 * @dev Interface for cross-chain finality verification
 */
interface IFinalityVerifier {
    struct FinalityProof {
        bytes32 blockHash;
        uint256 blockNumber;
        bytes32 stateRoot;
        bytes proof;
        uint256 chainId;
        uint256 timestamp;
    }
    
    function verifyFinality(FinalityProof calldata proof) external view returns (bool);
    function getLatestFinalizedBlock(uint256 chainId) external view returns (uint256);
}

/**
 * @title IThresholdSigner
 * @dev Interface for threshold signature operations
 */
interface IThresholdSigner {
    function verifyThresholdSignature(
        bytes32 messageHash,
        bytes[] calldata signatures,
        address[] calldata signers
    ) external view returns (bool);
    
    function getThreshold() external view returns (uint256);
}

/**
 * @title IIdentityVerifier
 * @dev Interface for ZK-KYC identity verification
 */
interface IIdentityVerifier {
    struct ZKProof {
        bytes proof;
        bytes32 publicInputHash;
        uint256 proofType; // 0 = zkSNARK, 1 = zk-STARK
    }
    
    function verifyKYCProof(ZKProof calldata proof) external view returns (bool);
    function isKYCVerified(address wallet) external view returns (bool);
    function checkOFACCompliance(bytes32 identityHash) external view returns (bool);
}

/**
 * @title ISettlementEngine
 * @dev Interface for cross-chain settlement operations
 */
interface ISettlementEngine {
    struct SettlementRequest {
        bytes32 requestId;
        uint256 sourceChain;
        uint256 destChain;
        address asset;
        uint256 amount;
        address sender;
        address recipient;
        bytes32 finalityProofHash;
        uint256 nonce;
        uint256 deadline;
    }
    
    function settleAndVerify(SettlementRequest calldata request) external returns (bool);
    function getSettlementStatus(bytes32 requestId) external view returns (uint8);
}

/**
 * @title ICustodyVault
 * @dev Interface for MPC custody vault operations
 */
interface ICustodyVault {
    function deposit(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount, address recipient) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}
