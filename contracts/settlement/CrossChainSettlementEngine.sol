// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/ICore.sol";
import "../libraries/SecurityLibraries.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title CrossChainSettlementEngine
 * @dev Institutional-grade settlement engine for cross-chain atomic settlements
 * Integrates with finality verification and identity compliance
 */
contract CrossChainSettlementEngine is ISettlementEngine, AccessControl, ReentrancyGuard, Pausable {
    using NonceManager for NonceManager.NonceState;
    using RateLimiter for RateLimiter.RateLimit;
    using ECDSAMultisig for bytes32;
    
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    
    IFinalityVerifier public finalityVerifier;
    IIdentityVerifier public identityVerifier;
    ICustodyVault public custodyVault;
    
    // Settlement states
    enum SettlementStatus {
        Pending,
        FinalityVerified,
        Executing,
        Completed,
        Failed,
        Cancelled
    }
    
    struct Settlement {
        bytes32 requestId;
        SettlementRequest request;
        SettlementStatus status;
        uint256 createdAt;
        uint256 executedAt;
        bytes32 finalityProof;
        bool atomicLockAcquired;
        bytes32[] attestations;
    }
    
    // Atomic swap lock for cross-chain coordination
    struct AtomicLock {
        bytes32 settlementId;
        uint256 lockedAt;
        uint256 timeout;
        bool released;
    }
    
    mapping(bytes32 => Settlement) public settlements;
    mapping(bytes32 => AtomicLock) public atomicLocks;
    mapping(address => mapping(uint256 => bytes32[])) public userSettlements; // user => chainId => settlementIds
    
    NonceManager.NonceState private nonceState;
    RateLimiter.RateLimit private settlementRateLimit;
    
    // Double-spend prevention
    mapping(bytes32 => bool) public processedTransactions;
    
    // Chain-specific configurations
    mapping(uint256 => bool) public supportedChains;
    mapping(uint256 => uint256) public minSettlementAmount;
    mapping(uint256 => uint256) public maxSettlementAmount;
    
    uint256 public settlementTimeout = 1 hours;
    uint256 public minAttestations = 2;
    
    // Real-time attestation tracking
    event SettlementCreated(bytes32 indexed requestId, address indexed sender, uint256 sourceChain, uint256 destChain);
    event FinalityVerified(bytes32 indexed requestId, uint256 blockNumber, bytes32 stateRoot);
    event SettlementExecuting(bytes32 indexed requestId, uint256 timestamp);
    event SettlementCompleted(bytes32 indexed requestId, uint256 timestamp, bytes32 txHash);
    event SettlementFailed(bytes32 indexed requestId, string reason);
    event SettlementCancelled(bytes32 indexed requestId, address indexed cancelledBy);
    event AttestationAdded(bytes32 indexed requestId, bytes32 attestation, address indexed attester);
    event AtomicLockAcquired(bytes32 indexed settlementId, uint256 timeout);
    event AtomicLockReleased(bytes32 indexed settlementId);
    event DoubleSpendDetected(bytes32 indexed txHash, address indexed sender);
    
    constructor(
        address _finalityVerifier,
        address _identityVerifier,
        address _custodyVault
    ) {
        finalityVerifier = IFinalityVerifier(_finalityVerifier);
        identityVerifier = IIdentityVerifier(_identityVerifier);
        custodyVault = ICustodyVault(_custodyVault);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(SETTLER_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
        
        // Initialize rate limiter: max 100 settlements per hour per address
        settlementRateLimit.maxAmount = 100;
        settlementRateLimit.windowSize = 1 hours;
    }
    
    /**
     * @dev Create and verify cross-chain settlement
     * This is the main entry point for settlement operations
     */
    function settleAndVerify(SettlementRequest calldata request) external override nonReentrant whenNotPaused returns (bool) {
        // 1. Validate request
        require(supportedChains[request.sourceChain], "Source chain not supported");
        require(supportedChains[request.destChain], "Dest chain not supported");
        require(request.sender == msg.sender, "Invalid sender");
        require(request.deadline > block.timestamp, "Request expired");
        require(request.amount > 0, "Invalid amount");
        
        // 2. Verify KYC compliance
        require(identityVerifier.isKYCVerified(msg.sender), "Sender not KYC verified");
        require(identityVerifier.isKYCVerified(request.recipient), "Recipient not KYC verified");
        
        // 3. Check rate limits
        require(
            settlementRateLimit.checkAndUpdate(msg.sender, 1),
            "Rate limit exceeded"
        );
        
        // 4. Verify nonce and prevent replay
        uint256 currentNonce = nonceState.getCurrentNonce(msg.sender);
        require(request.nonce == currentNonce, "Invalid nonce");
        nonceState.incrementNonce(msg.sender);
        
        // 5. Check for double-spend
        bytes32 txHash = keccak256(abi.encode(request));
        require(!processedTransactions[txHash], "Transaction already processed");
        
        if (nonceState.isHashUsed(txHash)) {
            emit DoubleSpendDetected(txHash, msg.sender);
            revert("Double-spend detected");
        }
        
        nonceState.markHashUsed(txHash);
        processedTransactions[txHash] = true;
        
        // 6. Verify amount limits
        require(
            request.amount >= minSettlementAmount[request.sourceChain],
            "Below minimum amount"
        );
        require(
            request.amount <= maxSettlementAmount[request.sourceChain],
            "Exceeds maximum amount"
        );
        
        // 7. Create settlement record
        bytes32 requestId = request.requestId;
        
        settlements[requestId] = Settlement({
            requestId: requestId,
            request: request,
            status: SettlementStatus.Pending,
            createdAt: block.timestamp,
            executedAt: 0,
            finalityProof: request.finalityProofHash,
            atomicLockAcquired: false,
            attestations: new bytes32[](0)
        });
        
        userSettlements[msg.sender][request.sourceChain].push(requestId);
        
        emit SettlementCreated(requestId, msg.sender, request.sourceChain, request.destChain);
        
        // 8. Verify finality asynchronously
        _verifyFinality(requestId);
        
        return true;
    }
    
    /**
     * @dev Verify cross-chain finality for settlement
     */
    function _verifyFinality(bytes32 requestId) internal {
        Settlement storage settlement = settlements[requestId];
        
        // Get finality proof from the verifier
        IFinalityVerifier.FinalityProof memory proof = IFinalityVerifier.FinalityProof({
            blockHash: settlement.finalityProof,
            blockNumber: 0, // Would be provided in actual implementation
            stateRoot: bytes32(0),
            proof: "",
            chainId: settlement.request.sourceChain,
            timestamp: block.timestamp
        });
        
        // Verify finality (in production, this would be called separately with actual proof)
        // For now, we mark as verified if the proof hash exists
        if (settlement.finalityProof != bytes32(0)) {
            settlement.status = SettlementStatus.FinalityVerified;
            emit FinalityVerified(requestId, proof.blockNumber, proof.stateRoot);
        }
    }
    
    /**
     * @dev Execute settlement after finality verification
     */
    function executeSettlement(bytes32 requestId) external onlyRole(SETTLER_ROLE) nonReentrant {
        Settlement storage settlement = settlements[requestId];
        
        require(settlement.status == SettlementStatus.FinalityVerified, "Finality not verified");
        require(settlement.createdAt + settlementTimeout > block.timestamp, "Settlement timeout");
        require(settlement.attestations.length >= minAttestations, "Insufficient attestations");
        
        // Acquire atomic lock
        if (!settlement.atomicLockAcquired) {
            _acquireAtomicLock(requestId);
            settlement.atomicLockAcquired = true;
        }
        
        settlement.status = SettlementStatus.Executing;
        emit SettlementExecuting(requestId, block.timestamp);
        
        // Execute the actual settlement
        bool success = _performSettlement(settlement.request);
        
        if (success) {
            settlement.status = SettlementStatus.Completed;
            settlement.executedAt = block.timestamp;
            
            bytes32 txHash = keccak256(abi.encode(settlement.request, block.timestamp));
            emit SettlementCompleted(requestId, block.timestamp, txHash);
            
            // Release atomic lock
            _releaseAtomicLock(requestId);
        } else {
            settlement.status = SettlementStatus.Failed;
            emit SettlementFailed(requestId, "Execution failed");
            
            // Release atomic lock
            _releaseAtomicLock(requestId);
        }
    }
    
    /**
     * @dev Perform the actual settlement
     */
    function _performSettlement(SettlementRequest memory request) internal returns (bool) {
        // In production, this would interact with the custody vault and bridge
        // For now, we simulate a successful settlement
        
        try IERC20(request.asset).transfer(request.recipient, request.amount) returns (bool success) {
            return success;
        } catch {
            return false;
        }
    }
    
    /**
     * @dev Acquire atomic lock for cross-chain coordination
     */
    function _acquireAtomicLock(bytes32 settlementId) internal {
        bytes32 lockId = keccak256(abi.encodePacked(settlementId, "lock"));
        
        require(!atomicLocks[lockId].released, "Lock already acquired");
        
        atomicLocks[lockId] = AtomicLock({
            settlementId: settlementId,
            lockedAt: block.timestamp,
            timeout: block.timestamp + settlementTimeout,
            released: false
        });
        
        emit AtomicLockAcquired(settlementId, atomicLocks[lockId].timeout);
    }
    
    /**
     * @dev Release atomic lock
     */
    function _releaseAtomicLock(bytes32 settlementId) internal {
        bytes32 lockId = keccak256(abi.encodePacked(settlementId, "lock"));
        
        atomicLocks[lockId].released = true;
        
        emit AtomicLockReleased(settlementId);
    }
    
    /**
     * @dev Add real-time attestation to settlement
     */
    function addAttestation(bytes32 requestId, bytes32 attestation) external onlyRole(SETTLER_ROLE) {
        Settlement storage settlement = settlements[requestId];
        
        require(settlement.status == SettlementStatus.FinalityVerified, "Invalid status");
        
        settlement.attestations.push(attestation);
        
        emit AttestationAdded(requestId, attestation, msg.sender);
    }
    
    /**
     * @dev Cancel settlement (guardian only)
     */
    function cancelSettlement(bytes32 requestId) external onlyRole(GUARDIAN_ROLE) {
        Settlement storage settlement = settlements[requestId];
        
        require(
            settlement.status == SettlementStatus.Pending || 
            settlement.status == SettlementStatus.FinalityVerified,
            "Cannot cancel"
        );
        
        settlement.status = SettlementStatus.Cancelled;
        
        // Release lock if acquired
        if (settlement.atomicLockAcquired) {
            _releaseAtomicLock(requestId);
        }
        
        emit SettlementCancelled(requestId, msg.sender);
    }
    
    /**
     * @dev Get settlement status
     */
    function getSettlementStatus(bytes32 requestId) external view override returns (uint8) {
        return uint8(settlements[requestId].status);
    }
    
    /**
     * @dev Get settlement details
     */
    function getSettlement(bytes32 requestId) external view returns (Settlement memory) {
        return settlements[requestId];
    }
    
    /**
     * @dev Add supported chain
     */
    function addSupportedChain(
        uint256 chainId,
        uint256 minAmount,
        uint256 maxAmount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        supportedChains[chainId] = true;
        minSettlementAmount[chainId] = minAmount;
        maxSettlementAmount[chainId] = maxAmount;
    }
    
    /**
     * @dev Get user's settlements for a chain
     */
    function getUserSettlements(address user, uint256 chainId) external view returns (bytes32[] memory) {
        return userSettlements[user][chainId];
    }
    
    /**
     * @dev Emergency pause
     */
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @dev Get current nonce for user
     */
    function getNonce(address user) external view returns (uint256) {
        return nonceState.getCurrentNonce(user);
    }
}
