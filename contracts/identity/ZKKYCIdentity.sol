// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/ICore.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ZKKYCIdentity
 * @dev Privacy-preserving KYC verification using zero-knowledge proofs
 * Compliant with FATF Travel Rule and OFAC screening
 */
contract ZKKYCIdentity is IIdentityVerifier, AccessControl, ReentrancyGuard {
    bytes32 public constant COMPLIANCE_OFFICER_ROLE = keccak256("COMPLIANCE_OFFICER_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    
    // DID (Decentralized Identifier) credential
    struct DIDCredential {
        bytes32 credentialHash;
        uint256 issuedAt;
        uint256 expiresAt;
        bool isActive;
        uint8 kycLevel; // 0 = none, 1 = basic, 2 = enhanced, 3 = institutional
        bytes32 jurisdictionHash; // Privacy-preserving jurisdiction identifier
    }
    
    // KYC status per wallet
    mapping(address => DIDCredential) public kycCredentials;
    mapping(bytes32 => bool) public revokedCredentials;
    
    // OFAC screening
    mapping(bytes32 => bool) public ofacBlacklist;
    mapping(bytes32 => uint256) public ofacAddedTime;
    
    // Travel Rule compliance tracking
    struct TravelRuleData {
        bytes32 originatorHash; // Encrypted originator info
        bytes32 beneficiaryHash; // Encrypted beneficiary info
        uint256 amount;
        uint256 timestamp;
        bool verified;
    }
    
    mapping(bytes32 => TravelRuleData) public travelRuleRecords;
    
    // ZK proof verification keys (simplified - use real zkSNARK/STARK verifiers in production)
    struct ProofVerificationKey {
        bytes32 vkHash;
        uint8 proofSystem; // 0 = Groth16, 1 = PLONK, 2 = STARK
        bool isActive;
    }
    
    mapping(uint256 => ProofVerificationKey) public verificationKeys;
    
    // Events
    event KYCVerified(address indexed wallet, bytes32 credentialHash, uint8 kycLevel, uint256 timestamp);
    event KYCRevoked(address indexed wallet, bytes32 credentialHash, uint256 timestamp);
    event OFACEntityAdded(bytes32 indexed identityHash, uint256 timestamp);
    event OFACEntityRemoved(bytes32 indexed identityHash, uint256 timestamp);
    event TravelRuleRecorded(bytes32 indexed recordId, uint256 amount, uint256 timestamp);
    event ProofVerified(address indexed wallet, uint256 proofType, bool success, uint256 timestamp);
    
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMPLIANCE_OFFICER_ROLE, msg.sender);
        _grantRole(VERIFIER_ROLE, msg.sender);
    }
    
    /**
     * @dev Verify KYC using zero-knowledge proof
     * User proves they are KYC-compliant without revealing identity
     */
    function verifyKYCProof(ZKProof calldata proof) external override returns (bool) {
        // Verify the ZK proof
        bool isValid = _verifyZKProof(proof);
        
        if (!isValid) {
            emit ProofVerified(msg.sender, proof.proofType, false, block.timestamp);
            return false;
        }
        
        // Extract KYC level from public input (privacy-preserving)
        uint8 kycLevel = _extractKYCLevel(proof.publicInputHash);
        
        // Create/update DID credential
        kycCredentials[msg.sender] = DIDCredential({
            credentialHash: proof.publicInputHash,
            issuedAt: block.timestamp,
            expiresAt: block.timestamp + 365 days,
            isActive: true,
            kycLevel: kycLevel,
            jurisdictionHash: _extractJurisdiction(proof.publicInputHash)
        });
        
        emit KYCVerified(msg.sender, proof.publicInputHash, kycLevel, block.timestamp);
        emit ProofVerified(msg.sender, proof.proofType, true, block.timestamp);
        
        return true;
    }
    
    /**
     * @dev Check if wallet is KYC verified
     */
    function isKYCVerified(address wallet) external view override returns (bool) {
        DIDCredential storage cred = kycCredentials[wallet];
        
        if (!cred.isActive) return false;
        if (cred.expiresAt < block.timestamp) return false;
        if (revokedCredentials[cred.credentialHash]) return false;
        
        return cred.kycLevel > 0;
    }
    
    /**
     * @dev Check OFAC compliance
     */
    function checkOFACCompliance(bytes32 identityHash) external view override returns (bool) {
        return !ofacBlacklist[identityHash];
    }
    
    /**
     * @dev Add entity to OFAC blacklist
     */
    function addToOFACBlacklist(bytes32 identityHash) external onlyRole(COMPLIANCE_OFFICER_ROLE) {
        require(!ofacBlacklist[identityHash], "Already blacklisted");
        
        ofacBlacklist[identityHash] = true;
        ofacAddedTime[identityHash] = block.timestamp;
        
        emit OFACEntityAdded(identityHash, block.timestamp);
    }
    
    /**
     * @dev Remove entity from OFAC blacklist
     */
    function removeFromOFACBlacklist(bytes32 identityHash) external onlyRole(COMPLIANCE_OFFICER_ROLE) {
        require(ofacBlacklist[identityHash], "Not blacklisted");
        
        ofacBlacklist[identityHash] = false;
        
        emit OFACEntityRemoved(identityHash, block.timestamp);
    }
    
    /**
     * @dev Record Travel Rule data for compliance
     */
    function recordTravelRule(
        bytes32 originatorHash,
        bytes32 beneficiaryHash,
        uint256 amount
    ) external onlyRole(VERIFIER_ROLE) returns (bytes32) {
        bytes32 recordId = keccak256(abi.encodePacked(
            originatorHash,
            beneficiaryHash,
            amount,
            block.timestamp
        ));
        
        travelRuleRecords[recordId] = TravelRuleData({
            originatorHash: originatorHash,
            beneficiaryHash: beneficiaryHash,
            amount: amount,
            timestamp: block.timestamp,
            verified: true
        });
        
        emit TravelRuleRecorded(recordId, amount, block.timestamp);
        
        return recordId;
    }
    
    /**
     * @dev Revoke KYC credential
     */
    function revokeKYC(address wallet) external onlyRole(COMPLIANCE_OFFICER_ROLE) {
        DIDCredential storage cred = kycCredentials[wallet];
        require(cred.isActive, "Credential not active");
        
        cred.isActive = false;
        revokedCredentials[cred.credentialHash] = true;
        
        emit KYCRevoked(wallet, cred.credentialHash, block.timestamp);
    }
    
    /**
     * @dev Get KYC level for wallet
     */
    function getKYCLevel(address wallet) external view returns (uint8) {
        DIDCredential storage cred = kycCredentials[wallet];
        
        if (!cred.isActive || cred.expiresAt < block.timestamp || revokedCredentials[cred.credentialHash]) {
            return 0;
        }
        
        return cred.kycLevel;
    }
    
    /**
     * @dev Get credential expiry
     */
    function getCredentialExpiry(address wallet) external view returns (uint256) {
        return kycCredentials[wallet].expiresAt;
    }
    
    /**
     * @dev Verify enhanced KYC for institutional operations
     */
    function verifyEnhancedKYC(address wallet, uint8 requiredLevel) external view returns (bool) {
        DIDCredential storage cred = kycCredentials[wallet];
        
        if (!cred.isActive) return false;
        if (cred.expiresAt < block.timestamp) return false;
        if (revokedCredentials[cred.credentialHash]) return false;
        
        return cred.kycLevel >= requiredLevel;
    }
    
    /**
     * @dev Set verification key for ZK proof system
     */
    function setVerificationKey(
        uint256 proofType,
        bytes32 vkHash,
        uint8 proofSystem
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        verificationKeys[proofType] = ProofVerificationKey({
            vkHash: vkHash,
            proofSystem: proofSystem,
            isActive: true
        });
    }
    
    /**
     * @dev Internal: Verify ZK proof (simplified)
     * In production, use actual zkSNARK/STARK verifier
     */
    function _verifyZKProof(ZKProof calldata proof) internal view returns (bool) {
        ProofVerificationKey storage vk = verificationKeys[proof.proofType];
        
        if (!vk.isActive) return false;
        if (proof.proof.length == 0) return false;
        
        // In production, call actual verifier contract based on proof system
        // For Groth16: verify pairing equation
        // For PLONK: verify polynomial commitments
        // For STARK: verify FRI protocol
        
        return true;
    }
    
    /**
     * @dev Internal: Extract KYC level from public input
     */
    function _extractKYCLevel(bytes32 publicInputHash) internal pure returns (uint8) {
        // Extract KYC level from the first byte of the hash
        // In production, this would be properly encoded in the ZK circuit output
        uint8 level = uint8(uint256(publicInputHash) & 0xFF);
        return level > 3 ? 3 : level;
    }
    
    /**
     * @dev Internal: Extract jurisdiction from public input
     */
    function _extractJurisdiction(bytes32 publicInputHash) internal pure returns (bytes32) {
        // Extract jurisdiction hash (privacy-preserving)
        // In production, this comes from ZK circuit public outputs
        return keccak256(abi.encodePacked(publicInputHash, "jurisdiction"));
    }
    
    /**
     * @dev Batch verify multiple KYC credentials
     */
    function batchVerifyKYC(address[] calldata wallets) external view returns (bool[] memory) {
        bool[] memory results = new bool[](wallets.length);
        
        for (uint256 i = 0; i < wallets.length; i++) {
            DIDCredential storage cred = kycCredentials[wallets[i]];
            results[i] = cred.isActive && 
                        cred.expiresAt >= block.timestamp && 
                        !revokedCredentials[cred.credentialHash] &&
                        cred.kycLevel > 0;
        }
        
        return results;
    }
}
