/**
 * zk-SNARK Light Client Verifier
 * Uses snarkjs for Groth16 proof verification
 */

const snarkjs = require('snarkjs');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

/**
 * Verifies a zk-SNARK proof for block finality
 * @param {Object} proof - The Groth16 proof
 * @param {Object} publicSignals - Public inputs to the circuit
 * @param {string} verificationKeyPath - Path to verification key
 * @returns {Promise<boolean>} - True if proof is valid
 */
async function verifyBlockProof(proof, publicSignals, verificationKeyPath) {
    try {
        const vKey = JSON.parse(fs.readFileSync(verificationKeyPath, 'utf-8'));
        const isValid = await snarkjs.groth16.verify(vKey, publicSignals, proof);

        console.log('Block proof verification:', isValid ? 'VALID' : 'INVALID');
        return isValid;
    } catch (error) {
        console.error('Proof verification failed:', error);
        return false;
    }
}

/**
 * Generates a zk-SNARK proof for EVM block header
 * @param {Object} blockHeader - Block header data
 * @param {string} wasmPath - Path to circuit WASM
 * @param {string} zkeyPath - Path to proving key
 * @returns {Promise<Object>} - Proof and public signals
 */
async function generateEVMBlockProof(blockHeader, wasmPath, zkeyPath) {
    const input = {
        blockNumber: blockHeader.number,
        blockHash: hashToField(blockHeader.hash),
        stateRoot: hashToField(blockHeader.stateRoot),
        receiptsRoot: hashToField(blockHeader.receiptsRoot),
        timestamp: blockHeader.timestamp,
        parentHash: hashToField(blockHeader.parentHash),
        nonce: blockHeader.nonce
    };

    console.log('Generating proof for block:', blockHeader.number);

    const { proof, publicSignals } = await snarkjs.groth16.fullProve(
        input,
        wasmPath,
        zkeyPath
    );

    return { proof, publicSignals };
}

/**
 * Generates a zk-SNARK proof for Solana block
 * @param {Object} blockData - Solana block data
 * @param {string} wasmPath - Path to circuit WASM
 * @param {string} zkeyPath - Path to proving key
 * @returns {Promise<Object>} - Proof and public signals
 */
async function generateSolanaBlockProof(blockData, wasmPath, zkeyPath) {
    const input = {
        slot: blockData.slot,
        blockHash: hashToField(blockData.blockhash),
        previousBlockhash: hashToField(blockData.previousBlockhash),
        parentSlot: blockData.parentSlot,
        timestamp: blockData.blockTime,
        transactionsRoot: hashToField(calculateTransactionsRoot(blockData.transactions))
    };

    console.log('Generating proof for Solana block at slot:', blockData.slot);

    const { proof, publicSignals } = await snarkjs.groth16.fullProve(
        input,
        wasmPath,
        zkeyPath
    );

    return { proof, publicSignals };
}

/**
 * Generates a zk-SNARK proof for Cosmos block
 * @param {Object} blockData - Cosmos block data
 * @param {string} wasmPath - Path to circuit WASM
 * @param {string} zkeyPath - Path to proving key
 * @returns {Promise<Object>} - Proof and public signals
 */
async function generateCosmosBlockProof(blockData, wasmPath, zkeyPath) {
    const input = {
        height: blockData.header.height,
        chainId: stringToField(blockData.header.chain_id),
        blockHash: hashToField(blockData.block_id.hash),
        dataHash: hashToField(blockData.header.data_hash),
        validatorsHash: hashToField(blockData.header.validators_hash),
        appHash: hashToField(blockData.header.app_hash),
        timestamp: Math.floor(new Date(blockData.header.time).getTime() / 1000)
    };

    console.log('Generating proof for Cosmos block at height:', blockData.header.height);

    const { proof, publicSignals } = await snarkjs.groth16.fullProve(
        input,
        wasmPath,
        zkeyPath
    );

    return { proof, publicSignals };
}

/**
 * Batch verifies multiple block proofs
 * @param {Array<Object>} proofs - Array of proof objects
 * @param {string} verificationKeyPath - Path to verification key
 * @returns {Promise<boolean>} - True if all proofs are valid
 */
async function batchVerifyProofs(proofs, verificationKeyPath) {
    const vKey = JSON.parse(fs.readFileSync(verificationKeyPath, 'utf-8'));

    const results = await Promise.all(
        proofs.map(async ({ proof, publicSignals }) => {
            return await snarkjs.groth16.verify(vKey, publicSignals, proof);
        })
    );

    const allValid = results.every(result => result === true);
    console.log(`Batch verification: ${results.filter(r => r).length}/${results.length} valid`);

    return allValid;
}

/**
 * Exports proof to Solidity-compatible format
 * @param {Object} proof - The Groth16 proof
 * @param {Array} publicSignals - Public signals
 * @returns {Object} - Solidity-compatible proof data
 */
function exportSolidityProof(proof, publicSignals) {
    const proofData = {
        pi_a: [proof.pi_a[0], proof.pi_a[1]],
        pi_b: [
            [proof.pi_b[0][1], proof.pi_b[0][0]],
            [proof.pi_b[1][1], proof.pi_b[1][0]]
        ],
        pi_c: [proof.pi_c[0], proof.pi_c[1]],
        publicSignals: publicSignals
    };

    return proofData;
}

/**
 * Exports proof to bytes for on-chain storage
 * @param {Object} proof - The Groth16 proof
 * @returns {string} - Hex-encoded proof bytes
 */
function proofToBytes(proof) {
    const proofArray = [
        ...proof.pi_a,
        ...proof.pi_b[0],
        ...proof.pi_b[1],
        ...proof.pi_c
    ];

    // Convert to bytes (simplified - actual implementation would properly encode)
    const proofBytes = Buffer.from(JSON.stringify(proofArray));
    return '0x' + proofBytes.toString('hex');
}

// Helper functions

function hashToField(hash) {
    // Remove 0x prefix if present
    const cleanHash = hash.startsWith('0x') ? hash.slice(2) : hash;
    // Convert to BigInt and mod by the field prime (BN254 scalar field)
    const fieldPrime = BigInt('21888242871839275222246405745257275088548364400416034343698204186575808495617');
    return (BigInt('0x' + cleanHash) % fieldPrime).toString();
}

function stringToField(str) {
    const hash = crypto.createHash('sha256').update(str).digest('hex');
    return hashToField(hash);
}

function calculateTransactionsRoot(transactions) {
    // Simplified Merkle root calculation
    if (!transactions || transactions.length === 0) {
        return '0x0000000000000000000000000000000000000000000000000000000000000000';
    }

    const leaves = transactions.map(tx =>
        crypto.createHash('sha256').update(JSON.stringify(tx)).digest('hex')
    );

    return merkleRoot(leaves);
}

function merkleRoot(leaves) {
    if (leaves.length === 0) {
        return '0x0000000000000000000000000000000000000000000000000000000000000000';
    }

    if (leaves.length === 1) {
        return leaves[0];
    }

    const newLevel = [];
    for (let i = 0; i < leaves.length; i += 2) {
        const left = leaves[i];
        const right = i + 1 < leaves.length ? leaves[i + 1] : left;
        const combined = crypto.createHash('sha256')
            .update(Buffer.from(left + right, 'hex'))
            .digest('hex');
        newLevel.push(combined);
    }

    return merkleRoot(newLevel);
}

module.exports = {
    verifyBlockProof,
    generateEVMBlockProof,
    generateSolanaBlockProof,
    generateCosmosBlockProof,
    batchVerifyProofs,
    exportSolidityProof,
    proofToBytes
};

// Example usage
if (require.main === module) {
    const exampleBlockHeader = {
        number: 15000000,
        hash: '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
        stateRoot: '0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890',
        receiptsRoot: '0x9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba',
        timestamp: Math.floor(Date.now() / 1000),
        parentHash: '0xfedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
        nonce: 12345
    };

    console.log('Example block header:', exampleBlockHeader);
    console.log('Ready to generate proofs - provide WASM and zkey paths');
}
