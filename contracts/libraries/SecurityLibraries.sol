// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MerkleVerifier
 * @dev Library for Merkle proof verification
 */
library MerkleVerifier {
    function verify(
        bytes32[] memory proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        bytes32 computedHash = leaf;
        
        for (uint256 i = 0; i < proof.length; i++) {
            computedHash = hashPair(computedHash, proof[i]);
        }
        
        return computedHash == root;
    }
    
    function hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}

/**
 * @title NonceManager
 * @dev Library for managing nonces to prevent replay attacks
 */
library NonceManager {
    struct NonceState {
        mapping(address => uint256) nonces;
        mapping(bytes32 => bool) usedHashes;
    }
    
    function incrementNonce(NonceState storage state, address account) internal returns (uint256) {
        uint256 current = state.nonces[account];
        state.nonces[account] = current + 1;
        return current;
    }
    
    function getCurrentNonce(NonceState storage state, address account) internal view returns (uint256) {
        return state.nonces[account];
    }
    
    function markHashUsed(NonceState storage state, bytes32 hash) internal {
        require(!state.usedHashes[hash], "Hash already used");
        state.usedHashes[hash] = true;
    }
    
    function isHashUsed(NonceState storage state, bytes32 hash) internal view returns (bool) {
        return state.usedHashes[hash];
    }
}

/**
 * @title RateLimiter
 * @dev Library for implementing rate limiting
 */
library RateLimiter {
    struct RateLimit {
        uint256 maxAmount;
        uint256 windowSize;
        mapping(address => uint256) lastUpdate;
        mapping(address => uint256) accumulated;
    }
    
    function checkAndUpdate(
        RateLimit storage limit,
        address account,
        uint256 amount
    ) internal returns (bool) {
        uint256 currentTime = block.timestamp;
        uint256 lastUpdate = limit.lastUpdate[account];
        
        // Reset if window has passed
        if (currentTime >= lastUpdate + limit.windowSize) {
            limit.accumulated[account] = amount;
            limit.lastUpdate[account] = currentTime;
            return amount <= limit.maxAmount;
        }
        
        // Check within window
        uint256 newAccumulated = limit.accumulated[account] + amount;
        if (newAccumulated > limit.maxAmount) {
            return false;
        }
        
        limit.accumulated[account] = newAccumulated;
        return true;
    }
    
    function getRemaining(
        RateLimit storage limit,
        address account
    ) internal view returns (uint256) {
        uint256 currentTime = block.timestamp;
        uint256 lastUpdate = limit.lastUpdate[account];
        
        if (currentTime >= lastUpdate + limit.windowSize) {
            return limit.maxAmount;
        }
        
        return limit.maxAmount - limit.accumulated[account];
    }
}

/**
 * @title ECDSAMultisig
 * @dev Library for ECDSA multisig verification
 */
library ECDSAMultisig {
    function recoverSigner(
        bytes32 messageHash,
        bytes memory signature
    ) internal pure returns (address) {
        require(signature.length == 65, "Invalid signature length");
        
        bytes32 r;
        bytes32 s;
        uint8 v;
        
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        
        if (v < 27) {
            v += 27;
        }
        
        require(v == 27 || v == 28, "Invalid signature v value");
        
        return ecrecover(messageHash, v, r, s);
    }
    
    function verifyMultiSignature(
        bytes32 messageHash,
        bytes[] memory signatures,
        address[] memory expectedSigners,
        uint256 threshold
    ) internal pure returns (bool) {
        require(signatures.length >= threshold, "Insufficient signatures");
        require(signatures.length == expectedSigners.length, "Signature count mismatch");
        
        for (uint256 i = 0; i < threshold; i++) {
            address recovered = recoverSigner(messageHash, signatures[i]);
            
            bool found = false;
            for (uint256 j = 0; j < expectedSigners.length; j++) {
                if (recovered == expectedSigners[j]) {
                    found = true;
                    break;
                }
            }
            
            if (!found) {
                return false;
            }
        }
        
        return true;
    }
}
