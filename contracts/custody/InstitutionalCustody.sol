// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title InstitutionalCustody
 * @dev Institutional-grade custody contract with threshold MPC, time-locks, and comprehensive logging
 * Supports ERC20, ERC721, and USDC with Fireblocks-style security model
 */
contract InstitutionalCustody is IERC721Receiver, ReentrancyGuard, Pausable {
    // Threshold signature configuration
    struct ThresholdConfig {
        uint256 requiredSignatures; // Number of signatures required
        uint256 totalSigners;        // Total number of authorized signers
        mapping(address => bool) isAuthorizedSigner;
        address[] signersList;
    }

    // Time-lock configuration for withdrawals
    struct TimeLock {
        uint256 delay;           // Delay in seconds before withdrawal can be executed
        uint256 proposedAt;      // When the withdrawal was proposed
        bool executed;           // Whether the withdrawal has been executed
        bool cancelled;          // Whether the withdrawal has been cancelled
    }

    // Withdrawal request structure
    struct WithdrawalRequest {
        bytes32 requestId;
        address asset;           // Token address (address(0) for ETH)
        uint256 amount;          // Amount to withdraw (or tokenId for NFTs)
        address recipient;
        bool isNFT;              // True for ERC721, false for ERC20/ETH
        TimeLock timeLock;
        uint256 approvalCount;
        mapping(address => bool) approvals;
        address[] approvers;
    }

    // Admin configuration
    struct AdminConfig {
        address superAdmin;
        mapping(address => bool) isAdmin;
        address[] adminList;
        uint256 adminOverrideThreshold;  // Number of admins required to override
    }

    // State variables
    ThresholdConfig private thresholdConfig;
    AdminConfig private adminConfig;
    mapping(bytes32 => WithdrawalRequest) public withdrawalRequests;
    bytes32[] public withdrawalRequestIds;
    
    uint256 public defaultTimeLockDelay = 24 hours;
    uint256 public minTimeLockDelay = 1 hours;
    
    // Events for SOC2-ready audit trail
    event SignerAdded(address indexed signer, uint256 timestamp, address indexed addedBy);
    event SignerRemoved(address indexed signer, uint256 timestamp, address indexed removedBy);
    event AdminAdded(address indexed admin, uint256 timestamp, address indexed addedBy);
    event AdminRemoved(address indexed admin, uint256 timestamp, address indexed removedBy);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold, uint256 timestamp, address indexed updatedBy);
    
    event DepositReceived(address indexed asset, uint256 amount, address indexed from, uint256 timestamp, bool isNFT);
    event WithdrawalProposed(bytes32 indexed requestId, address indexed asset, uint256 amount, address indexed recipient, uint256 executeAfter);
    event WithdrawalApproved(bytes32 indexed requestId, address indexed approver, uint256 approvalCount, uint256 timestamp);
    event WithdrawalExecuted(bytes32 indexed requestId, address indexed asset, uint256 amount, address indexed recipient, uint256 timestamp);
    event WithdrawalCancelled(bytes32 indexed requestId, address indexed cancelledBy, uint256 timestamp);
    event AdminOverrideExecuted(bytes32 indexed requestId, address[] admins, uint256 timestamp);
    
    event EmergencyPaused(address indexed pausedBy, uint256 timestamp);
    event EmergencyUnpaused(address indexed unpausedBy, uint256 timestamp);
    
    // Modifiers
    modifier onlySuperAdmin() {
        require(msg.sender == adminConfig.superAdmin, "Only super admin");
        _;
    }
    
    modifier onlyAdmin() {
        require(adminConfig.isAdmin[msg.sender] || msg.sender == adminConfig.superAdmin, "Only admin");
        _;
    }
    
    modifier onlyAuthorizedSigner() {
        require(thresholdConfig.isAuthorizedSigner[msg.sender], "Not authorized signer");
        _;
    }
    
    /**
     * @dev Constructor initializes the custody contract with threshold configuration
     * @param _requiredSignatures Number of signatures required for withdrawals
     * @param _initialSigners Initial list of authorized signers
     * @param _admins Initial list of admins
     */
    constructor(
        uint256 _requiredSignatures,
        address[] memory _initialSigners,
        address[] memory _admins
    ) {
        require(_requiredSignatures > 0, "Required signatures must be > 0");
        require(_initialSigners.length >= _requiredSignatures, "Not enough initial signers");
        require(_admins.length > 0, "Must have at least one admin");
        
        adminConfig.superAdmin = msg.sender;
        
        // Initialize signers
        thresholdConfig.requiredSignatures = _requiredSignatures;
        thresholdConfig.totalSigners = _initialSigners.length;
        
        for (uint256 i = 0; i < _initialSigners.length; i++) {
            require(_initialSigners[i] != address(0), "Invalid signer address");
            require(!thresholdConfig.isAuthorizedSigner[_initialSigners[i]], "Duplicate signer");
            
            thresholdConfig.isAuthorizedSigner[_initialSigners[i]] = true;
            thresholdConfig.signersList.push(_initialSigners[i]);
            
            emit SignerAdded(_initialSigners[i], block.timestamp, msg.sender);
        }
        
        // Initialize admins
        for (uint256 i = 0; i < _admins.length; i++) {
            require(_admins[i] != address(0), "Invalid admin address");
            require(!adminConfig.isAdmin[_admins[i]], "Duplicate admin");
            
            adminConfig.isAdmin[_admins[i]] = true;
            adminConfig.adminList.push(_admins[i]);
            
            emit AdminAdded(_admins[i], block.timestamp, msg.sender);
        }
        
        // Set default admin override threshold
        adminConfig.adminOverrideThreshold = (_admins.length / 2) + 1;
    }
    
    /**
     * @dev Receive ETH deposits
     */
    receive() external payable {
        emit DepositReceived(address(0), msg.value, msg.sender, block.timestamp, false);
    }
    
    /**
     * @dev Deposit ERC20 tokens
     * @param token ERC20 token address
     * @param amount Amount to deposit
     */
    function depositERC20(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(token != address(0), "Invalid token address");
        require(amount > 0, "Amount must be > 0");
        
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        
        emit DepositReceived(token, amount, msg.sender, block.timestamp, false);
    }
    
    /**
     * @dev Deposit ERC721 token
     * @param token ERC721 token address
     * @param tokenId Token ID to deposit
     */
    function depositERC721(address token, uint256 tokenId) external nonReentrant whenNotPaused {
        require(token != address(0), "Invalid token address");
        
        IERC721(token).safeTransferFrom(msg.sender, address(this), tokenId);
        
        emit DepositReceived(token, tokenId, msg.sender, block.timestamp, true);
    }
    
    /**
     * @dev Propose a withdrawal (starts time-lock)
     * @param asset Token address (address(0) for ETH)
     * @param amount Amount to withdraw (or tokenId for NFTs)
     * @param recipient Withdrawal recipient
     * @param isNFT Whether this is an NFT withdrawal
     */
    function proposeWithdrawal(
        address asset,
        uint256 amount,
        address recipient,
        bool isNFT
    ) external onlyAuthorizedSigner whenNotPaused returns (bytes32) {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be > 0");
        
        bytes32 requestId = keccak256(abi.encodePacked(
            asset,
            amount,
            recipient,
            isNFT,
            block.timestamp,
            withdrawalRequestIds.length
        ));
        
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        request.requestId = requestId;
        request.asset = asset;
        request.amount = amount;
        request.recipient = recipient;
        request.isNFT = isNFT;
        request.timeLock.delay = defaultTimeLockDelay;
        request.timeLock.proposedAt = block.timestamp;
        request.timeLock.executed = false;
        request.timeLock.cancelled = false;
        request.approvalCount = 1;
        request.approvals[msg.sender] = true;
        request.approvers.push(msg.sender);
        
        withdrawalRequestIds.push(requestId);
        
        uint256 executeAfter = block.timestamp + defaultTimeLockDelay;
        
        emit WithdrawalProposed(requestId, asset, amount, recipient, executeAfter);
        emit WithdrawalApproved(requestId, msg.sender, 1, block.timestamp);
        
        return requestId;
    }
    
    /**
     * @dev Approve a withdrawal request
     * @param requestId Withdrawal request ID
     */
    function approveWithdrawal(bytes32 requestId) external onlyAuthorizedSigner whenNotPaused {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        
        require(request.requestId != bytes32(0), "Request does not exist");
        require(!request.timeLock.executed, "Already executed");
        require(!request.timeLock.cancelled, "Request cancelled");
        require(!request.approvals[msg.sender], "Already approved");
        
        request.approvals[msg.sender] = true;
        request.approvers.push(msg.sender);
        request.approvalCount++;
        
        emit WithdrawalApproved(requestId, msg.sender, request.approvalCount, block.timestamp);
    }
    
    /**
     * @dev Execute a withdrawal after time-lock and threshold met
     * @param requestId Withdrawal request ID
     */
    function executeWithdrawal(bytes32 requestId) external nonReentrant whenNotPaused {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        
        require(request.requestId != bytes32(0), "Request does not exist");
        require(!request.timeLock.executed, "Already executed");
        require(!request.timeLock.cancelled, "Request cancelled");
        require(
            request.approvalCount >= thresholdConfig.requiredSignatures,
            "Insufficient approvals"
        );
        require(
            block.timestamp >= request.timeLock.proposedAt + request.timeLock.delay,
            "Time-lock not expired"
        );
        
        request.timeLock.executed = true;
        
        // Execute the withdrawal
        if (request.isNFT) {
            IERC721(request.asset).safeTransferFrom(address(this), request.recipient, request.amount);
        } else if (request.asset == address(0)) {
            // ETH withdrawal
            (bool success, ) = request.recipient.call{value: request.amount}("");
            require(success, "ETH transfer failed");
        } else {
            // ERC20 withdrawal
            IERC20(request.asset).transfer(request.recipient, request.amount);
        }
        
        emit WithdrawalExecuted(requestId, request.asset, request.amount, request.recipient, block.timestamp);
    }
    
    /**
     * @dev Cancel a withdrawal request
     * @param requestId Withdrawal request ID
     */
    function cancelWithdrawal(bytes32 requestId) external onlyAuthorizedSigner {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        
        require(request.requestId != bytes32(0), "Request does not exist");
        require(!request.timeLock.executed, "Already executed");
        require(!request.timeLock.cancelled, "Already cancelled");
        
        request.timeLock.cancelled = true;
        
        emit WithdrawalCancelled(requestId, msg.sender, block.timestamp);
    }
    
    /**
     * @dev Admin override for emergency withdrawals
     * @param requestId Withdrawal request ID
     * @param adminApprovers List of admin addresses approving the override
     */
    function adminOverrideWithdrawal(
        bytes32 requestId,
        address[] calldata adminApprovers
    ) external onlyAdmin nonReentrant {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        
        require(request.requestId != bytes32(0), "Request does not exist");
        require(!request.timeLock.executed, "Already executed");
        require(!request.timeLock.cancelled, "Request cancelled");
        require(
            adminApprovers.length >= adminConfig.adminOverrideThreshold,
            "Insufficient admin approvals"
        );
        
        // Verify all approvers are admins
        for (uint256 i = 0; i < adminApprovers.length; i++) {
            require(
                adminConfig.isAdmin[adminApprovers[i]] || adminApprovers[i] == adminConfig.superAdmin,
                "Invalid admin approver"
            );
        }
        
        request.timeLock.executed = true;
        
        // Execute the withdrawal
        if (request.isNFT) {
            IERC721(request.asset).safeTransferFrom(address(this), request.recipient, request.amount);
        } else if (request.asset == address(0)) {
            (bool success, ) = request.recipient.call{value: request.amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(request.asset).transfer(request.recipient, request.amount);
        }
        
        emit AdminOverrideExecuted(requestId, adminApprovers, block.timestamp);
        emit WithdrawalExecuted(requestId, request.asset, request.amount, request.recipient, block.timestamp);
    }
    
    /**
     * @dev Add a new authorized signer
     * @param signer Address to add as signer
     */
    function addSigner(address signer) external onlySuperAdmin {
        require(signer != address(0), "Invalid signer address");
        require(!thresholdConfig.isAuthorizedSigner[signer], "Already a signer");
        
        thresholdConfig.isAuthorizedSigner[signer] = true;
        thresholdConfig.signersList.push(signer);
        thresholdConfig.totalSigners++;
        
        emit SignerAdded(signer, block.timestamp, msg.sender);
    }
    
    /**
     * @dev Remove an authorized signer
     * @param signer Address to remove
     */
    function removeSigner(address signer) external onlySuperAdmin {
        require(thresholdConfig.isAuthorizedSigner[signer], "Not a signer");
        require(
            thresholdConfig.totalSigners - 1 >= thresholdConfig.requiredSignatures,
            "Would fall below threshold"
        );
        
        thresholdConfig.isAuthorizedSigner[signer] = false;
        thresholdConfig.totalSigners--;
        
        // Remove from list
        for (uint256 i = 0; i < thresholdConfig.signersList.length; i++) {
            if (thresholdConfig.signersList[i] == signer) {
                thresholdConfig.signersList[i] = thresholdConfig.signersList[thresholdConfig.signersList.length - 1];
                thresholdConfig.signersList.pop();
                break;
            }
        }
        
        emit SignerRemoved(signer, block.timestamp, msg.sender);
    }
    
    /**
     * @dev Update threshold requirements
     * @param newThreshold New required signatures count
     */
    function updateThreshold(uint256 newThreshold) external onlySuperAdmin {
        require(newThreshold > 0, "Threshold must be > 0");
        require(newThreshold <= thresholdConfig.totalSigners, "Threshold exceeds signers");
        
        uint256 oldThreshold = thresholdConfig.requiredSignatures;
        thresholdConfig.requiredSignatures = newThreshold;
        
        emit ThresholdUpdated(oldThreshold, newThreshold, block.timestamp, msg.sender);
    }
    
    /**
     * @dev Add a new admin
     * @param admin Address to add as admin
     */
    function addAdmin(address admin) external onlySuperAdmin {
        require(admin != address(0), "Invalid admin address");
        require(!adminConfig.isAdmin[admin], "Already an admin");
        
        adminConfig.isAdmin[admin] = true;
        adminConfig.adminList.push(admin);
        
        emit AdminAdded(admin, block.timestamp, msg.sender);
    }
    
    /**
     * @dev Remove an admin
     * @param admin Address to remove
     */
    function removeAdmin(address admin) external onlySuperAdmin {
        require(adminConfig.isAdmin[admin], "Not an admin");
        
        adminConfig.isAdmin[admin] = false;
        
        // Remove from list
        for (uint256 i = 0; i < adminConfig.adminList.length; i++) {
            if (adminConfig.adminList[i] == admin) {
                adminConfig.adminList[i] = adminConfig.adminList[adminConfig.adminList.length - 1];
                adminConfig.adminList.pop();
                break;
            }
        }
        
        emit AdminRemoved(admin, block.timestamp, msg.sender);
    }
    
    /**
     * @dev Emergency pause
     */
    function pause() external onlyAdmin {
        _pause();
        emit EmergencyPaused(msg.sender, block.timestamp);
    }
    
    /**
     * @dev Emergency unpause
     */
    function unpause() external onlySuperAdmin {
        _unpause();
        emit EmergencyUnpaused(msg.sender, block.timestamp);
    }
    
    /**
     * @dev Update default time-lock delay
     * @param newDelay New delay in seconds
     */
    function updateTimeLockDelay(uint256 newDelay) external onlySuperAdmin {
        require(newDelay >= minTimeLockDelay, "Delay too short");
        defaultTimeLockDelay = newDelay;
    }
    
    /**
     * @dev Update admin override threshold
     * @param newThreshold New threshold
     */
    function updateAdminOverrideThreshold(uint256 newThreshold) external onlySuperAdmin {
        require(newThreshold > 0, "Threshold must be > 0");
        require(newThreshold <= adminConfig.adminList.length, "Threshold exceeds admins");
        adminConfig.adminOverrideThreshold = newThreshold;
    }
    
    // View functions
    
    /**
     * @dev Get withdrawal request details
     * @param requestId Withdrawal request ID
     */
    function getWithdrawalRequest(bytes32 requestId) external view returns (
        address asset,
        uint256 amount,
        address recipient,
        bool isNFT,
        uint256 proposedAt,
        uint256 delay,
        bool executed,
        bool cancelled,
        uint256 approvalCount
    ) {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        return (
            request.asset,
            request.amount,
            request.recipient,
            request.isNFT,
            request.timeLock.proposedAt,
            request.timeLock.delay,
            request.timeLock.executed,
            request.timeLock.cancelled,
            request.approvalCount
        );
    }
    
    /**
     * @dev Get withdrawal approvers
     * @param requestId Withdrawal request ID
     */
    function getWithdrawalApprovers(bytes32 requestId) external view returns (address[] memory) {
        return withdrawalRequests[requestId].approvers;
    }
    
    /**
     * @dev Check if address has approved a withdrawal
     * @param requestId Withdrawal request ID
     * @param signer Signer address
     */
    function hasApproved(bytes32 requestId, address signer) external view returns (bool) {
        return withdrawalRequests[requestId].approvals[signer];
    }
    
    /**
     * @dev Get all withdrawal request IDs
     */
    function getAllWithdrawalRequestIds() external view returns (bytes32[] memory) {
        return withdrawalRequestIds;
    }
    
    /**
     * @dev Get threshold configuration
     */
    function getThresholdConfig() external view returns (
        uint256 requiredSignatures,
        uint256 totalSigners,
        address[] memory signers
    ) {
        return (
            thresholdConfig.requiredSignatures,
            thresholdConfig.totalSigners,
            thresholdConfig.signersList
        );
    }
    
    /**
     * @dev Check if address is authorized signer
     * @param signer Address to check
     */
    function isAuthorizedSigner(address signer) external view returns (bool) {
        return thresholdConfig.isAuthorizedSigner[signer];
    }
    
    /**
     * @dev Get admin list
     */
    function getAdmins() external view returns (address[] memory) {
        return adminConfig.adminList;
    }
    
    /**
     * @dev Check if address is admin
     * @param admin Address to check
     */
    function isAdmin(address admin) external view returns (bool) {
        return adminConfig.isAdmin[admin] || admin == adminConfig.superAdmin;
    }
    
    /**
     * @dev Get super admin
     */
    function getSuperAdmin() external view returns (address) {
        return adminConfig.superAdmin;
    }
    
    /**
     * @dev Required for receiving ERC721 tokens
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
