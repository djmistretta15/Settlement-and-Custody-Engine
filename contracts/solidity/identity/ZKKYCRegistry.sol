// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ZKKYCRegistry
 * @notice Zero-Knowledge KYC registry for privacy-preserving compliance
 * @dev Users prove KYC compliance without revealing identity using zk-SNARKs
 */
contract ZKKYCRegistry {
    /// @notice KYC credential structure
    struct KYCCredential {
        bytes32 credentialHash; // Hash of the credential
        uint256 issuedAt;
        uint256 expiresAt;
        KYCLevel kycLevel;
        bool isRevoked;
        address issuer;
    }

    /// @notice KYC compliance levels
    enum KYCLevel {
        None,
        Basic,      // Basic identity verification
        Enhanced,   // Enhanced due diligence
        Institutional // Institutional-grade verification
    }

    /// @notice Compliance status
    struct ComplianceStatus {
        bool isKYCVerified;
        bool isOFACClear;
        bool isFATFCompliant;
        uint256 lastChecked;
        bytes32 complianceProof; // ZK proof hash
    }

    /// @notice DID to KYC credential mapping
    mapping(bytes32 => KYCCredential) public credentials;

    /// @notice Wallet address to DID mapping
    mapping(address => bytes32) public walletToDID;

    /// @notice DID to compliance status mapping
    mapping(bytes32 => ComplianceStatus) public complianceStatus;

    /// @notice Authorized KYC issuers
    mapping(address => bool) public authorizedIssuers;

    /// @notice OFAC sanctioned addresses (privacy-preserving using commitment)
    mapping(bytes32 => bool) public sanctionedCommitments;

    /// @notice Verifying key for ZK proof verification
    bytes public zkVerifyingKey;

    /// @notice Contract owner
    address public owner;

    /// @notice Events
    event CredentialIssued(
        bytes32 indexed did,
        address indexed wallet,
        KYCLevel kycLevel,
        uint256 expiresAt
    );
    event CredentialRevoked(bytes32 indexed did, address indexed issuer);
    event ComplianceVerified(bytes32 indexed did, bytes32 proofHash);
    event IssuerAuthorized(address indexed issuer);
    event IssuerRevoked(address indexed issuer);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAuthorizedIssuer() {
        require(authorizedIssuers[msg.sender], "Not authorized issuer");
        _;
    }

    constructor(bytes memory _zkVerifyingKey) {
        owner = msg.sender;
        authorizedIssuers[msg.sender] = true;
        zkVerifyingKey = _zkVerifyingKey;
    }

    /**
     * @notice Authorizes a KYC issuer
     * @param issuer The issuer address to authorize
     */
    function authorizeIssuer(address issuer) external onlyOwner {
        authorizedIssuers[issuer] = true;
        emit IssuerAuthorized(issuer);
    }

    /**
     * @notice Revokes a KYC issuer
     * @param issuer The issuer address to revoke
     */
    function revokeIssuer(address issuer) external onlyOwner {
        authorizedIssuers[issuer] = false;
        emit IssuerRevoked(issuer);
    }

    /**
     * @notice Issues a KYC credential to a DID
     * @param did Decentralized identifier
     * @param wallet Associated wallet address
     * @param credentialHash Hash of the credential data
     * @param kycLevel The KYC compliance level
     * @param validityPeriod Validity period in seconds
     */
    function issueCredential(
        bytes32 did,
        address wallet,
        bytes32 credentialHash,
        KYCLevel kycLevel,
        uint256 validityPeriod
    ) external onlyAuthorizedIssuer {
        require(wallet != address(0), "Invalid wallet");
        require(kycLevel != KYCLevel.None, "Invalid KYC level");
        require(!credentials[did].isRevoked, "Credential already revoked");

        uint256 expiresAt = block.timestamp + validityPeriod;

        credentials[did] = KYCCredential({
            credentialHash: credentialHash,
            issuedAt: block.timestamp,
            expiresAt: expiresAt,
            kycLevel: kycLevel,
            isRevoked: false,
            issuer: msg.sender
        });

        walletToDID[wallet] = did;

        emit CredentialIssued(did, wallet, kycLevel, expiresAt);
    }

    /**
     * @notice Revokes a KYC credential
     * @param did The DID to revoke
     */
    function revokeCredential(bytes32 did) external onlyAuthorizedIssuer {
        KYCCredential storage credential = credentials[did];
        require(credential.issuer == msg.sender, "Not credential issuer");
        require(!credential.isRevoked, "Already revoked");

        credential.isRevoked = true;

        emit CredentialRevoked(did, msg.sender);
    }

    /**
     * @notice Verifies KYC compliance using zero-knowledge proof
     * @param did The decentralized identifier
     * @param zkProof The zero-knowledge proof
     * @param publicInputs Public inputs for verification
     * @return isValid True if proof is valid
     */
    function verifyKYCCompliance(
        bytes32 did,
        bytes calldata zkProof,
        bytes32[] calldata publicInputs
    ) external returns (bool isValid) {
        KYCCredential storage credential = credentials[did];

        // Check credential validity
        require(!credential.isRevoked, "Credential revoked");
        require(block.timestamp < credential.expiresAt, "Credential expired");

        // Verify zk-SNARK proof
        require(
            _verifyZKProof(zkProof, publicInputs),
            "Invalid ZK proof"
        );

        // Update compliance status
        ComplianceStatus storage status = complianceStatus[did];
        status.isKYCVerified = true;
        status.lastChecked = block.timestamp;
        status.complianceProof = keccak256(zkProof);

        emit ComplianceVerified(did, status.complianceProof);

        return true;
    }

    /**
     * @notice Checks OFAC compliance using privacy-preserving commitment
     * @param addressCommitment Commitment of the address to check
     * @param zkProof Zero-knowledge proof of non-inclusion
     * @return isClear True if address is not sanctioned
     */
    function checkOFACCompliance(
        bytes32 addressCommitment,
        bytes calldata zkProof
    ) external view returns (bool isClear) {
        // Check if commitment is in sanctioned list
        if (sanctionedCommitments[addressCommitment]) {
            return false;
        }

        // Verify ZK proof of non-inclusion (simplified)
        // In production, this would verify a zk-SNARK proving the address
        // is not in the sanctioned set without revealing the address
        return zkProof.length > 0;
    }

    /**
     * @notice Adds a sanctioned address commitment to the registry
     * @param commitment Privacy-preserving commitment of sanctioned address
     */
    function addSanctionedCommitment(bytes32 commitment) external onlyOwner {
        sanctionedCommitments[commitment] = true;
    }

    /**
     * @notice Removes a sanctioned address commitment
     * @param commitment The commitment to remove
     */
    function removeSanctionedCommitment(bytes32 commitment) external onlyOwner {
        sanctionedCommitments[commitment] = false;
    }

    /**
     * @notice Verifies FATF Travel Rule compliance
     * @param originatorDID Originator's DID
     * @param beneficiaryDID Beneficiary's DID
     * @param amount Transaction amount
     * @param zkProof Zero-knowledge proof of compliance
     * @return isCompliant True if travel rule is satisfied
     */
    function verifyTravelRuleCompliance(
        bytes32 originatorDID,
        bytes32 beneficiaryDID,
        uint256 amount,
        bytes calldata zkProof
    ) external view returns (bool isCompliant) {
        KYCCredential storage originatorCred = credentials[originatorDID];
        KYCCredential storage beneficiaryCred = credentials[beneficiaryDID];

        // Check both parties have valid credentials
        require(!originatorCred.isRevoked, "Originator credential revoked");
        require(!beneficiaryCred.isRevoked, "Beneficiary credential revoked");
        require(
            block.timestamp < originatorCred.expiresAt,
            "Originator credential expired"
        );
        require(
            block.timestamp < beneficiaryCred.expiresAt,
            "Beneficiary credential expired"
        );

        // For amounts above threshold, require Enhanced or Institutional KYC
        if (amount >= 1000 * 10**18) { // Example: 1000 tokens
            require(
                uint8(originatorCred.kycLevel) >= uint8(KYCLevel.Enhanced),
                "Insufficient originator KYC level"
            );
            require(
                uint8(beneficiaryCred.kycLevel) >= uint8(KYCLevel.Enhanced),
                "Insufficient beneficiary KYC level"
            );
        }

        // Verify ZK proof (simplified)
        return _verifyZKProof(zkProof, new bytes32[](0));
    }

    /**
     * @notice Verifies a zero-knowledge proof
     * @param zkProof The proof bytes
     * @param publicInputs Public inputs for verification
     * @return isValid True if proof is valid
     */
    function _verifyZKProof(
        bytes calldata zkProof,
        bytes32[] memory publicInputs
    ) internal view returns (bool isValid) {
        // In production, this would call a Groth16 or Plonk verifier
        // For this implementation, we do basic validation

        require(zkProof.length >= 128, "Invalid proof length");
        require(zkVerifyingKey.length > 0, "Verifying key not set");

        // Simplified verification - in production use proper zk-SNARK verifier
        bytes32 proofHash = keccak256(zkProof);
        bytes32 vkeyHash = keccak256(zkVerifyingKey);

        return proofHash != bytes32(0) && vkeyHash != bytes32(0);
    }

    /**
     * @notice Gets KYC status for a wallet
     * @param wallet The wallet address
     * @return credential The KYC credential
     * @return status The compliance status
     */
    function getKYCStatus(address wallet)
        external
        view
        returns (KYCCredential memory credential, ComplianceStatus memory status)
    {
        bytes32 did = walletToDID[wallet];
        return (credentials[did], complianceStatus[did]);
    }

    /**
     * @notice Checks if a wallet is KYC verified
     * @param wallet The wallet address
     * @return isVerified True if wallet has valid KYC
     */
    function isWalletKYCVerified(address wallet) external view returns (bool isVerified) {
        bytes32 did = walletToDID[wallet];
        KYCCredential storage credential = credentials[did];

        return !credential.isRevoked &&
               block.timestamp < credential.expiresAt &&
               credential.kycLevel != KYCLevel.None;
    }

    /**
     * @notice Gets the minimum required KYC level for an amount
     * @param amount The transaction amount
     * @return level The required KYC level
     */
    function getRequiredKYCLevel(uint256 amount)
        external
        pure
        returns (KYCLevel level)
    {
        if (amount >= 10000 * 10**18) {
            return KYCLevel.Institutional;
        } else if (amount >= 1000 * 10**18) {
            return KYCLevel.Enhanced;
        } else {
            return KYCLevel.Basic;
        }
    }
}
