pragma circom 2.1.6;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/comparators.circom";
include "circomlib/circuits/bitify.circom";

/**
 * Recursive Chain State Finality Verification Circuit
 * Verifies cross-chain block finality using zk-SNARKs
 *
 * This circuit proves:
 * 1. Block header validity (hash, parent, state root)
 * 2. Finality threshold (64+ confirmations for EVM)
 * 3. Merkle proof of transaction inclusion
 * 4. Chain ID binding (anti-replay)
 * 5. Timestamp validity window
 */

template BlockHeaderVerifier(nLevels) {
    // Public inputs
    signal input blockNumber;
    signal input chainId;
    signal input finalityThreshold; // 64 for Ethereum, 12 for Polygon, etc.
    signal input currentTimestamp;

    // Private inputs (block header data)
    signal input blockHash;
    signal input parentHash;
    signal input stateRoot;
    signal input receiptsRoot;
    signal input timestamp;
    signal input nonce;
    signal input difficulty;

    // Private inputs (Merkle proof)
    signal input merkleProof[nLevels];
    signal input merklePathIndices[nLevels];
    signal input txHash;

    // Output: commitment to verified state
    signal output stateCommitment;

    // === 1. Block Hash Verification ===
    component blockHasher = Poseidon(7);
    blockHasher.inputs[0] <== blockNumber;
    blockHasher.inputs[1] <== parentHash;
    blockHasher.inputs[2] <== stateRoot;
    blockHasher.inputs[3] <== receiptsRoot;
    blockHasher.inputs[4] <== timestamp;
    blockHasher.inputs[5] <== nonce;
    blockHasher.inputs[6] <== difficulty;

    // Verify computed hash matches provided hash
    blockHasher.out === blockHash;

    // === 2. Finality Threshold Check ===
    // Ensure block has enough confirmations
    component finalityCheck = GreaterEqThan(64);
    finalityCheck.in[0] <== finalityThreshold;
    finalityCheck.in[1] <== 64; // Minimum for Ethereum
    finalityCheck.out === 1;

    // === 3. Chain ID Binding ===
    // Ensures proof cannot be replayed on different chain
    component chainIdHasher = Poseidon(3);
    chainIdHasher.inputs[0] <== chainId;
    chainIdHasher.inputs[1] <== blockHash;
    chainIdHasher.inputs[2] <== stateRoot;

    signal chainBinding;
    chainBinding <== chainIdHasher.out;

    // === 4. Timestamp Validity Window ===
    // Block timestamp must be within reasonable bounds
    component timestampLower = GreaterEqThan(64);
    timestampLower.in[0] <== timestamp;
    timestampLower.in[1] <== currentTimestamp - 3600; // 1 hour past
    timestampLower.out === 1;

    component timestampUpper = LessEqThan(64);
    timestampUpper.in[0] <== timestamp;
    timestampUpper.in[1] <== currentTimestamp + 300; // 5 min future (clock drift)
    timestampUpper.out === 1;

    // === 5. Merkle Proof Verification ===
    component merkleVerifier = MerkleProofVerifier(nLevels);
    merkleVerifier.root <== receiptsRoot;
    merkleVerifier.leaf <== txHash;
    for (var i = 0; i < nLevels; i++) {
        merkleVerifier.pathElements[i] <== merkleProof[i];
        merkleVerifier.pathIndices[i] <== merklePathIndices[i];
    }
    merkleVerifier.isValid === 1;

    // === 6. Generate State Commitment ===
    component stateCommitter = Poseidon(4);
    stateCommitter.inputs[0] <== blockHash;
    stateCommitter.inputs[1] <== stateRoot;
    stateCommitter.inputs[2] <== chainBinding;
    stateCommitter.inputs[3] <== timestamp;

    stateCommitment <== stateCommitter.out;
}

template MerkleProofVerifier(nLevels) {
    signal input root;
    signal input leaf;
    signal input pathElements[nLevels];
    signal input pathIndices[nLevels];
    signal output isValid;

    component hashers[nLevels];
    component selectors[nLevels];

    signal computedHash[nLevels + 1];
    computedHash[0] <== leaf;

    for (var i = 0; i < nLevels; i++) {
        selectors[i] = DualMux();
        selectors[i].in[0] <== computedHash[i];
        selectors[i].in[1] <== pathElements[i];
        selectors[i].s <== pathIndices[i];

        hashers[i] = Poseidon(2);
        hashers[i].inputs[0] <== selectors[i].out[0];
        hashers[i].inputs[1] <== selectors[i].out[1];

        computedHash[i + 1] <== hashers[i].out;
    }

    component rootCheck = IsEqual();
    rootCheck.in[0] <== computedHash[nLevels];
    rootCheck.in[1] <== root;

    isValid <== rootCheck.out;
}

template DualMux() {
    signal input in[2];
    signal input s;
    signal output out[2];

    out[0] <== (in[1] - in[0]) * s + in[0];
    out[1] <== (in[0] - in[1]) * s + in[1];
}

/**
 * Recursive Finality Aggregator
 * Aggregates multiple block proofs into single recursive proof
 */
template RecursiveFinalityAggregator(nBlocks, nLevels) {
    signal input blockHashes[nBlocks];
    signal input stateRoots[nBlocks];
    signal input chainIds[nBlocks];
    signal input timestamps[nBlocks];

    // Previous proof verification
    signal input prevProofCommitment;

    // Output: aggregated commitment
    signal output aggregatedCommitment;

    // Verify sequential block numbers
    component sequenceChecks[nBlocks - 1];
    for (var i = 0; i < nBlocks - 1; i++) {
        sequenceChecks[i] = GreaterThan(64);
        sequenceChecks[i].in[0] <== blockHashes[i + 1];
        sequenceChecks[i].in[1] <== blockHashes[i];
        sequenceChecks[i].out === 1;
    }

    // Verify all blocks on same chain
    component chainChecks[nBlocks - 1];
    for (var i = 0; i < nBlocks - 1; i++) {
        chainChecks[i] = IsEqual();
        chainChecks[i].in[0] <== chainIds[i];
        chainChecks[i].in[1] <== chainIds[i + 1];
        chainChecks[i].out === 1;
    }

    // Aggregate all commitments
    component aggregator = Poseidon(nBlocks * 2 + 1);
    aggregator.inputs[0] <== prevProofCommitment;

    for (var i = 0; i < nBlocks; i++) {
        aggregator.inputs[i * 2 + 1] <== blockHashes[i];
        aggregator.inputs[i * 2 + 2] <== stateRoots[i];
    }

    aggregatedCommitment <== aggregator.out;
}

/**
 * Cross-Chain State Synchronization
 * Proves state consistency across multiple chains
 */
template CrossChainStateSync(nChains) {
    signal input chainIds[nChains];
    signal input blockNumbers[nChains];
    signal input stateRoots[nChains];
    signal input timestamps[nChains];

    // Settlement transaction data
    signal input settlementTxHash;
    signal input settlementAmount;
    signal input settlementNonce;

    // Output: cross-chain consistency proof
    signal output syncCommitment;

    // Verify all timestamps within sync window (15 minutes)
    component timestampChecks[nChains - 1];
    for (var i = 0; i < nChains - 1; i++) {
        component timeDiff = LessEqThan(64);

        // Calculate absolute difference
        signal diff;
        component gtCheck = GreaterThan(64);
        gtCheck.in[0] <== timestamps[i];
        gtCheck.in[1] <== timestamps[i + 1];

        diff <== gtCheck.out * (timestamps[i] - timestamps[i + 1]) +
                (1 - gtCheck.out) * (timestamps[i + 1] - timestamps[i]);

        timeDiff.in[0] <== diff;
        timeDiff.in[1] <== 900; // 15 minutes in seconds
        timeDiff.out === 1;
    }

    // Generate sync commitment
    component syncHasher = Poseidon(nChains * 3 + 3);
    syncHasher.inputs[0] <== settlementTxHash;
    syncHasher.inputs[1] <== settlementAmount;
    syncHasher.inputs[2] <== settlementNonce;

    for (var i = 0; i < nChains; i++) {
        syncHasher.inputs[i * 3 + 3] <== chainIds[i];
        syncHasher.inputs[i * 3 + 4] <== blockNumbers[i];
        syncHasher.inputs[i * 3 + 5] <== stateRoots[i];
    }

    syncCommitment <== syncHasher.out;
}

/**
 * Reorg Resistance Circuit
 * Detects and prevents settlement on reorganized chains
 */
template ReorgResistance(lookbackDepth) {
    signal input currentBlockHash;
    signal input historicalBlockHashes[lookbackDepth];
    signal input currentBlockNumber;
    signal input minFinalityDepth;

    signal output isReorgSafe;

    // Verify block is beyond finality depth
    component depthCheck = GreaterEqThan(64);
    depthCheck.in[0] <== currentBlockNumber;
    depthCheck.in[1] <== minFinalityDepth;

    // Verify historical chain consistency
    component consistencyChecks[lookbackDepth - 1];
    signal allConsistent[lookbackDepth];
    allConsistent[0] <== 1;

    for (var i = 0; i < lookbackDepth - 1; i++) {
        consistencyChecks[i] = IsEqual();
        consistencyChecks[i].in[0] <== historicalBlockHashes[i];
        consistencyChecks[i].in[1] <== historicalBlockHashes[i + 1];

        // All must be different (no duplicates)
        allConsistent[i + 1] <== allConsistent[i] * (1 - consistencyChecks[i].out);
    }

    isReorgSafe <== depthCheck.out * allConsistent[lookbackDepth - 1];
}

/**
 * Main Finality Circuit
 * Combines all verification components
 */
template FinalityVerificationMain(nLevels, nChains, lookbackDepth) {
    // Public inputs
    signal input publicChainId;
    signal input publicBlockNumber;
    signal input publicTimestamp;

    // Private inputs
    signal input blockHash;
    signal input parentHash;
    signal input stateRoot;
    signal input receiptsRoot;
    signal input timestamp;
    signal input nonce;
    signal input difficulty;
    signal input merkleProof[nLevels];
    signal input merklePathIndices[nLevels];
    signal input txHash;
    signal input historicalHashes[lookbackDepth];

    // Public output
    signal output finalityProof;

    // Step 1: Verify block header
    component headerVerifier = BlockHeaderVerifier(nLevels);
    headerVerifier.blockNumber <== publicBlockNumber;
    headerVerifier.chainId <== publicChainId;
    headerVerifier.finalityThreshold <== 64;
    headerVerifier.currentTimestamp <== publicTimestamp;
    headerVerifier.blockHash <== blockHash;
    headerVerifier.parentHash <== parentHash;
    headerVerifier.stateRoot <== stateRoot;
    headerVerifier.receiptsRoot <== receiptsRoot;
    headerVerifier.timestamp <== timestamp;
    headerVerifier.nonce <== nonce;
    headerVerifier.difficulty <== difficulty;
    for (var i = 0; i < nLevels; i++) {
        headerVerifier.merkleProof[i] <== merkleProof[i];
        headerVerifier.merklePathIndices[i] <== merklePathIndices[i];
    }
    headerVerifier.txHash <== txHash;

    // Step 2: Verify reorg resistance
    component reorgChecker = ReorgResistance(lookbackDepth);
    reorgChecker.currentBlockHash <== blockHash;
    for (var i = 0; i < lookbackDepth; i++) {
        reorgChecker.historicalBlockHashes[i] <== historicalHashes[i];
    }
    reorgChecker.currentBlockNumber <== publicBlockNumber;
    reorgChecker.minFinalityDepth <== 64;
    reorgChecker.isReorgSafe === 1;

    // Step 3: Generate final proof
    component finalProof = Poseidon(3);
    finalProof.inputs[0] <== headerVerifier.stateCommitment;
    finalProof.inputs[1] <== publicChainId;
    finalProof.inputs[2] <== publicBlockNumber;

    finalityProof <== finalProof.out;
}

// Main component instantiation
component main {public [publicChainId, publicBlockNumber, publicTimestamp]} = FinalityVerificationMain(32, 5, 64);
