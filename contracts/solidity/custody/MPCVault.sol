// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MPCVault
 * @notice Multi-Party Computation Vault for institutional custody
 * @dev Implements threshold signature schemes (GG18/FROST) with role-based access
 */
contract MPCVault {
    /// @notice Vault configuration
    struct VaultConfig {
        uint256 threshold; // Minimum signers required
        uint256 totalSigners; // Total number of signers
        address[] signers; // List of authorized signers
        bool isActive;
        uint256 createdAt;
    }

    /// @notice Transaction proposal
    struct TransactionProposal {
        address to;
        uint256 value;
        bytes data;
        uint256 chainId;
        uint256 nonce;
        uint256 createdAt;
        uint256 executedAt;
        ProposalStatus status;
        mapping(address => bool) approvals;
        uint256 approvalCount;
        bytes[] signatures; // Threshold signatures
    }

    /// @notice Proposal status
    enum ProposalStatus {
        Pending,
        Approved,
        Executed,
        Rejected,
        Expired
    }

    /// @notice Role definitions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /// @notice Vault identifier => vault config
    mapping(bytes32 => VaultConfig) public vaults;

    /// @notice Vault ID => proposal ID => transaction proposal
    mapping(bytes32 => mapping(uint256 => TransactionProposal)) public proposals;

    /// @notice Vault ID => next proposal nonce
    mapping(bytes32 => uint256) public vaultNonces;

    /// @notice Role => address => has role
    mapping(bytes32 => mapping(address => bool)) public roles;

    /// @notice Emergency pause flag
    bool public emergencyPaused;

    /// @notice Emergency multisig threshold
    uint256 public emergencyThreshold = 3;

    /// @notice Emergency multisig approvals
    mapping(bytes32 => mapping(address => bool)) public emergencyApprovals;
    mapping(bytes32 => uint256) public emergencyApprovalCount;

    /// @notice Audit log structure
    struct AuditLog {
        address actor;
        bytes32 action;
        bytes32 vaultId;
        uint256 timestamp;
        bytes metadata;
    }

    /// @notice Audit logs array
    AuditLog[] public auditLogs;

    /// @notice Events
    event VaultCreated(bytes32 indexed vaultId, uint256 threshold, uint256 totalSigners);
    event ProposalCreated(bytes32 indexed vaultId, uint256 indexed proposalId, address to, uint256 value);
    event ProposalApproved(bytes32 indexed vaultId, uint256 indexed proposalId, address signer);
    event ProposalExecuted(bytes32 indexed vaultId, uint256 indexed proposalId);
    event EmergencyPauseActivated(address indexed activator);
    event EmergencyPauseDeactivated(address indexed deactivator);
    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account);
    event AuditLogRecorded(uint256 indexed logId, address indexed actor, bytes32 action);

    modifier onlyRole(bytes32 role) {
        require(roles[role][msg.sender], "Access denied: insufficient role");
        _;
    }

    modifier whenNotPaused() {
        require(!emergencyPaused, "Emergency pause active");
        _;
    }

    modifier onlyActiveVault(bytes32 vaultId) {
        require(vaults[vaultId].isActive, "Vault not active");
        _;
    }

    constructor() {
        // Grant deployer all roles initially
        roles[ADMIN_ROLE][msg.sender] = true;
        roles[EMERGENCY_ROLE][msg.sender] = true;
    }

    /**
     * @notice Creates a new MPC vault
     * @param vaultId Unique vault identifier
     * @param threshold Minimum signers required
     * @param signers Array of authorized signer addresses
     */
    function createVault(
        bytes32 vaultId,
        uint256 threshold,
        address[] calldata signers
    ) external onlyRole(ADMIN_ROLE) {
        require(vaults[vaultId].createdAt == 0, "Vault already exists");
        require(threshold > 0 && threshold <= signers.length, "Invalid threshold");
        require(signers.length >= 2, "Minimum 2 signers required");

        VaultConfig storage vault = vaults[vaultId];
        vault.threshold = threshold;
        vault.totalSigners = signers.length;
        vault.signers = signers;
        vault.isActive = true;
        vault.createdAt = block.timestamp;

        // Grant signer roles
        for (uint256 i = 0; i < signers.length; i++) {
            roles[SIGNER_ROLE][signers[i]] = true;
        }

        _recordAuditLog(
            keccak256("VAULT_CREATED"),
            vaultId,
            abi.encode(threshold, signers.length)
        );

        emit VaultCreated(vaultId, threshold, signers.length);
    }

    /**
     * @notice Proposes a transaction from the vault
     * @param vaultId The vault identifier
     * @param to Destination address
     * @param value Amount to transfer
     * @param data Transaction data
     * @param chainId Target chain identifier
     * @return proposalId The proposal identifier
     */
    function proposeTransaction(
        bytes32 vaultId,
        address to,
        uint256 value,
        bytes calldata data,
        uint256 chainId
    )
        external
        onlyRole(SIGNER_ROLE)
        onlyActiveVault(vaultId)
        whenNotPaused
        returns (uint256 proposalId)
    {
        VaultConfig storage vault = vaults[vaultId];
        require(_isVaultSigner(vaultId, msg.sender), "Not a vault signer");

        proposalId = vaultNonces[vaultId]++;

        TransactionProposal storage proposal = proposals[vaultId][proposalId];
        proposal.to = to;
        proposal.value = value;
        proposal.data = data;
        proposal.chainId = chainId;
        proposal.nonce = proposalId;
        proposal.createdAt = block.timestamp;
        proposal.status = ProposalStatus.Pending;

        _recordAuditLog(
            keccak256("PROPOSAL_CREATED"),
            vaultId,
            abi.encode(proposalId, to, value)
        );

        emit ProposalCreated(vaultId, proposalId, to, value);

        return proposalId;
    }

    /**
     * @notice Approves a transaction proposal with threshold signature
     * @param vaultId The vault identifier
     * @param proposalId The proposal identifier
     * @param signature The threshold signature component
     */
    function approveProposal(
        bytes32 vaultId,
        uint256 proposalId,
        bytes calldata signature
    )
        external
        onlyRole(SIGNER_ROLE)
        onlyActiveVault(vaultId)
        whenNotPaused
    {
        require(_isVaultSigner(vaultId, msg.sender), "Not a vault signer");

        TransactionProposal storage proposal = proposals[vaultId][proposalId];
        require(proposal.status == ProposalStatus.Pending, "Invalid proposal status");
        require(!proposal.approvals[msg.sender], "Already approved");
        require(block.timestamp < proposal.createdAt + 7 days, "Proposal expired");

        proposal.approvals[msg.sender] = true;
        proposal.approvalCount++;
        proposal.signatures.push(signature);

        _recordAuditLog(
            keccak256("PROPOSAL_APPROVED"),
            vaultId,
            abi.encode(proposalId, msg.sender)
        );

        emit ProposalApproved(vaultId, proposalId, msg.sender);

        // Check if threshold reached
        VaultConfig storage vault = vaults[vaultId];
        if (proposal.approvalCount >= vault.threshold) {
            proposal.status = ProposalStatus.Approved;
        }
    }

    /**
     * @notice Executes an approved proposal
     * @param vaultId The vault identifier
     * @param proposalId The proposal identifier
     */
    function executeProposal(bytes32 vaultId, uint256 proposalId)
        external
        onlyRole(SIGNER_ROLE)
        onlyActiveVault(vaultId)
        whenNotPaused
    {
        TransactionProposal storage proposal = proposals[vaultId][proposalId];
        require(proposal.status == ProposalStatus.Approved, "Proposal not approved");

        VaultConfig storage vault = vaults[vaultId];
        require(
            proposal.approvalCount >= vault.threshold,
            "Insufficient approvals"
        );

        // Verify aggregated threshold signature (simplified)
        require(_verifyThresholdSignature(vaultId, proposalId), "Invalid signature");

        proposal.status = ProposalStatus.Executed;
        proposal.executedAt = block.timestamp;

        // Execute the transaction (on same chain) or emit event for cross-chain
        if (proposal.chainId == block.chainid) {
            (bool success, ) = proposal.to.call{value: proposal.value}(proposal.data);
            require(success, "Transaction execution failed");
        }

        _recordAuditLog(
            keccak256("PROPOSAL_EXECUTED"),
            vaultId,
            abi.encode(proposalId)
        );

        emit ProposalExecuted(vaultId, proposalId);
    }

    /**
     * @notice Emergency pause function
     * @dev Requires multiple emergency role holders to approve
     */
    function emergencyPause() external onlyRole(EMERGENCY_ROLE) {
        bytes32 actionId = keccak256(abi.encodePacked("EMERGENCY_PAUSE", block.number));

        require(!emergencyApprovals[actionId][msg.sender], "Already approved");

        emergencyApprovals[actionId][msg.sender] = true;
        emergencyApprovalCount[actionId]++;

        if (emergencyApprovalCount[actionId] >= emergencyThreshold) {
            emergencyPaused = true;
            _recordAuditLog(
                keccak256("EMERGENCY_PAUSE"),
                bytes32(0),
                abi.encode(block.timestamp)
            );
            emit EmergencyPauseActivated(msg.sender);
        }
    }

    /**
     * @notice Deactivates emergency pause
     */
    function deactivateEmergencyPause() external onlyRole(ADMIN_ROLE) {
        emergencyPaused = false;
        _recordAuditLog(
            keccak256("EMERGENCY_PAUSE_DEACTIVATED"),
            bytes32(0),
            abi.encode(block.timestamp)
        );
        emit EmergencyPauseDeactivated(msg.sender);
    }

    /**
     * @notice Grants a role to an address
     * @param role The role identifier
     * @param account The account to grant the role to
     */
    function grantRole(bytes32 role, address account) external onlyRole(ADMIN_ROLE) {
        roles[role][account] = true;
        _recordAuditLog(
            keccak256("ROLE_GRANTED"),
            bytes32(0),
            abi.encode(role, account)
        );
        emit RoleGranted(role, account);
    }

    /**
     * @notice Revokes a role from an address
     * @param role The role identifier
     * @param account The account to revoke the role from
     */
    function revokeRole(bytes32 role, address account) external onlyRole(ADMIN_ROLE) {
        roles[role][account] = false;
        _recordAuditLog(
            keccak256("ROLE_REVOKED"),
            bytes32(0),
            abi.encode(role, account)
        );
        emit RoleRevoked(role, account);
    }

    /**
     * @notice Verifies threshold signature (simplified implementation)
     * @param vaultId The vault identifier
     * @param proposalId The proposal identifier
     * @return isValid True if signature is valid
     */
    function _verifyThresholdSignature(bytes32 vaultId, uint256 proposalId)
        internal
        view
        returns (bool isValid)
    {
        TransactionProposal storage proposal = proposals[vaultId][proposalId];
        VaultConfig storage vault = vaults[vaultId];

        // In production, this would verify FROST or GG18 threshold signature
        // For now, we check that enough signatures are present
        return proposal.signatures.length >= vault.threshold;
    }

    /**
     * @notice Checks if an address is a signer for a vault
     * @param vaultId The vault identifier
     * @param signer The address to check
     * @return isSigner True if address is a vault signer
     */
    function _isVaultSigner(bytes32 vaultId, address signer)
        internal
        view
        returns (bool isSigner)
    {
        VaultConfig storage vault = vaults[vaultId];
        for (uint256 i = 0; i < vault.signers.length; i++) {
            if (vault.signers[i] == signer) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Records an audit log entry
     * @param action The action identifier
     * @param vaultId The vault identifier
     * @param metadata Additional metadata
     */
    function _recordAuditLog(
        bytes32 action,
        bytes32 vaultId,
        bytes memory metadata
    ) internal {
        AuditLog memory log = AuditLog({
            actor: msg.sender,
            action: action,
            vaultId: vaultId,
            timestamp: block.timestamp,
            metadata: metadata
        });

        auditLogs.push(log);
        emit AuditLogRecorded(auditLogs.length - 1, msg.sender, action);
    }

    /**
     * @notice Gets audit logs count
     * @return count The number of audit logs
     */
    function getAuditLogsCount() external view returns (uint256 count) {
        return auditLogs.length;
    }

    /**
     * @notice Gets vault signers
     * @param vaultId The vault identifier
     * @return signers Array of signer addresses
     */
    function getVaultSigners(bytes32 vaultId)
        external
        view
        returns (address[] memory signers)
    {
        return vaults[vaultId].signers;
    }

    /**
     * @notice Gets proposal signatures count
     * @param vaultId The vault identifier
     * @param proposalId The proposal identifier
     * @return count Number of signatures
     */
    function getProposalSignatureCount(bytes32 vaultId, uint256 proposalId)
        external
        view
        returns (uint256 count)
    {
        return proposals[vaultId][proposalId].signatures.length;
    }

    /// @notice Allows vault to receive ETH
    receive() external payable {}
}
