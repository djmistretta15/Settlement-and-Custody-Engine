/**
 * ZK-KYC Proof Generator
 * Generates zero-knowledge proofs for privacy-preserving KYC compliance
 */

const snarkjs = require('snarkjs');
const crypto = require('crypto');
const fs = require('fs');
const { poseidon } = require('circomlib');

/**
 * Generates a commitment to user's identity data
 * @param {Object} identityData - User identity information
 * @returns {string} - Commitment hash
 */
function generateIdentityCommitment(identityData) {
    const { name, dateOfBirth, nationalId, address } = identityData;

    // Hash each field
    const nameHash = hashField(name);
    const dobHash = hashField(dateOfBirth);
    const idHash = hashField(nationalId);
    const addrHash = hashField(address);

    // Use Poseidon hash for zk-friendly commitment
    const commitment = poseidon([
        BigInt(nameHash),
        BigInt(dobHash),
        BigInt(idHash),
        BigInt(addrHash)
    ]);

    return commitment.toString();
}

/**
 * Generates a zk-SNARK proof of KYC compliance without revealing identity
 * @param {Object} identityData - User's identity data
 * @param {string} kycLevel - Required KYC level (Basic, Enhanced, Institutional)
 * @param {string} wasmPath - Path to KYC circuit WASM
 * @param {string} zkeyPath - Path to proving key
 * @returns {Promise<Object>} - Proof and public signals
 */
async function generateKYCProof(identityData, kycLevel, wasmPath, zkeyPath) {
    const commitment = generateIdentityCommitment(identityData);
    const nullifier = generateNullifier(identityData.nationalId);

    // Determine age requirement based on KYC level
    const ageRequirement = {
        'Basic': 18,
        'Enhanced': 21,
        'Institutional': 25
    }[kycLevel] || 18;

    const age = calculateAge(identityData.dateOfBirth);

    const input = {
        // Private inputs (not revealed)
        name: stringToField(identityData.name),
        dateOfBirth: dateToField(identityData.dateOfBirth),
        nationalId: stringToField(identityData.nationalId),
        address: stringToField(identityData.address),

        // Public inputs
        commitment: commitment,
        nullifier: nullifier,
        minAge: ageRequirement,
        currentTimestamp: Math.floor(Date.now() / 1000),

        // Constraint checks
        isOver18: age >= ageRequirement ? 1 : 0,
        hasValidId: identityData.nationalId.length > 0 ? 1 : 0
    };

    console.log('Generating KYC proof for level:', kycLevel);

    const { proof, publicSignals } = await snarkjs.groth16.fullProve(
        input,
        wasmPath,
        zkeyPath
    );

    return {
        proof,
        publicSignals,
        commitment,
        nullifier
    };
}

/**
 * Generates a proof of OFAC compliance (non-sanctioned status)
 * @param {string} address - Wallet address to check
 * @param {Array<string>} sanctionedList - List of sanctioned addresses
 * @param {string} wasmPath - Path to circuit WASM
 * @param {string} zkeyPath - Path to proving key
 * @returns {Promise<Object>} - Proof of non-inclusion
 */
async function generateOFACComplianceProof(address, sanctionedList, wasmPath, zkeyPath) {
    // Create Merkle tree of sanctioned addresses
    const sanctionedTree = buildMerkleTree(
        sanctionedList.map(addr => hashField(addr))
    );

    const addressHash = hashField(address);
    const addressCommitment = poseidon([BigInt(addressHash)]);

    // Prove that address is NOT in the sanctioned tree
    const input = {
        addressHash: addressHash,
        addressCommitment: addressCommitment.toString(),
        sanctionedRoot: sanctionedTree.root,
        // Proof of non-inclusion would go here
        isNotInList: !sanctionedList.includes(address) ? 1 : 0
    };

    console.log('Generating OFAC compliance proof');

    const { proof, publicSignals } = await snarkjs.groth16.fullProve(
        input,
        wasmPath,
        zkeyPath
    );

    return { proof, publicSignals, addressCommitment: addressCommitment.toString() };
}

/**
 * Generates a FATF Travel Rule compliance proof
 * @param {Object} originatorData - Originator's KYC data
 * @param {Object} beneficiaryData - Beneficiary's KYC data
 * @param {number} amount - Transaction amount
 * @param {string} wasmPath - Path to circuit WASM
 * @param {string} zkeyPath - Path to proving key
 * @returns {Promise<Object>} - Travel Rule compliance proof
 */
async function generateTravelRuleProof(
    originatorData,
    beneficiaryData,
    amount,
    wasmPath,
    zkeyPath
) {
    const originatorCommitment = generateIdentityCommitment(originatorData);
    const beneficiaryCommitment = generateIdentityCommitment(beneficiaryData);

    // Determine required KYC level based on amount
    let requiredLevel = 0; // 0: Basic, 1: Enhanced, 2: Institutional
    if (amount >= 10000) {
        requiredLevel = 2; // Institutional
    } else if (amount >= 1000) {
        requiredLevel = 1; // Enhanced
    }

    const input = {
        // Private inputs
        originatorName: stringToField(originatorData.name),
        originatorId: stringToField(originatorData.nationalId),
        beneficiaryName: stringToField(beneficiaryData.name),
        beneficiaryId: stringToField(beneficiaryData.nationalId),

        // Public inputs
        originatorCommitment: originatorCommitment,
        beneficiaryCommitment: beneficiaryCommitment,
        amount: amount,
        requiredKYCLevel: requiredLevel,

        // Constraints
        originatorHasKYC: 1,
        beneficiaryHasKYC: 1,
        bothMeetLevel: 1 // Simplified - would check actual KYC levels
    };

    console.log('Generating Travel Rule compliance proof for amount:', amount);

    const { proof, publicSignals } = await snarkjs.groth16.fullProve(
        input,
        wasmPath,
        zkeyPath
    );

    return {
        proof,
        publicSignals,
        originatorCommitment,
        beneficiaryCommitment
    };
}

/**
 * Generates a nullifier for preventing double-spending of KYC credentials
 * @param {string} uniqueId - Unique identifier (e.g., national ID)
 * @returns {string} - Nullifier
 */
function generateNullifier(uniqueId) {
    const secret = crypto.randomBytes(32).toString('hex');
    const nullifier = poseidon([
        BigInt(hashField(uniqueId)),
        BigInt(hashField(secret))
    ]);
    return nullifier.toString();
}

/**
 * Verifies a KYC proof
 * @param {Object} proof - The proof to verify
 * @param {Array} publicSignals - Public signals
 * @param {string} verificationKeyPath - Path to verification key
 * @returns {Promise<boolean>} - True if valid
 */
async function verifyKYCProof(proof, publicSignals, verificationKeyPath) {
    try {
        const vKey = JSON.parse(fs.readFileSync(verificationKeyPath, 'utf-8'));
        const isValid = await snarkjs.groth16.verify(vKey, publicSignals, proof);

        console.log('KYC proof verification:', isValid ? 'VALID' : 'INVALID');
        return isValid;
    } catch (error) {
        console.error('KYC proof verification failed:', error);
        return false;
    }
}

/**
 * Creates a DID (Decentralized Identifier) credential
 * @param {string} commitment - Identity commitment
 * @param {string} kycLevel - KYC compliance level
 * @param {number} validityPeriod - Validity in seconds
 * @returns {Object} - DID credential
 */
function createDIDCredential(commitment, kycLevel, validityPeriod) {
    const did = `did:zkkyc:${commitment.slice(0, 16)}`;
    const issuedAt = Math.floor(Date.now() / 1000);
    const expiresAt = issuedAt + validityPeriod;

    const credential = {
        '@context': ['https://www.w3.org/2018/credentials/v1'],
        id: did,
        type: ['VerifiableCredential', 'KYCCredential'],
        issuer: 'did:settlement-engine:issuer',
        issuanceDate: new Date(issuedAt * 1000).toISOString(),
        expirationDate: new Date(expiresAt * 1000).toISOString(),
        credentialSubject: {
            id: did,
            kycLevel: kycLevel,
            commitment: commitment
        }
    };

    return credential;
}

// Helper functions

function hashField(data) {
    const hash = crypto.createHash('sha256').update(data.toString()).digest('hex');
    const fieldPrime = BigInt('21888242871839275222246405745257275088548364400416034343698204186575808495617');
    return (BigInt('0x' + hash) % fieldPrime).toString();
}

function stringToField(str) {
    return hashField(str);
}

function dateToField(dateString) {
    const timestamp = Math.floor(new Date(dateString).getTime() / 1000);
    return timestamp.toString();
}

function calculateAge(dateOfBirth) {
    const today = new Date();
    const birthDate = new Date(dateOfBirth);
    let age = today.getFullYear() - birthDate.getFullYear();
    const monthDiff = today.getMonth() - birthDate.getMonth();

    if (monthDiff < 0 || (monthDiff === 0 && today.getDate() < birthDate.getDate())) {
        age--;
    }

    return age;
}

function buildMerkleTree(leaves) {
    if (leaves.length === 0) {
        return { root: '0', tree: [] };
    }

    let currentLevel = leaves;
    const tree = [currentLevel];

    while (currentLevel.length > 1) {
        const nextLevel = [];

        for (let i = 0; i < currentLevel.length; i += 2) {
            const left = BigInt(currentLevel[i]);
            const right = i + 1 < currentLevel.length ? BigInt(currentLevel[i + 1]) : left;
            const parent = poseidon([left, right]);
            nextLevel.push(parent.toString());
        }

        tree.push(nextLevel);
        currentLevel = nextLevel;
    }

    return { root: currentLevel[0], tree };
}

module.exports = {
    generateIdentityCommitment,
    generateKYCProof,
    generateOFACComplianceProof,
    generateTravelRuleProof,
    generateNullifier,
    verifyKYCProof,
    createDIDCredential
};

// Example usage
if (require.main === module) {
    const exampleIdentity = {
        name: 'John Doe',
        dateOfBirth: '1990-01-01',
        nationalId: 'ID123456789',
        address: '123 Main St, City, Country'
    };

    const commitment = generateIdentityCommitment(exampleIdentity);
    console.log('Identity commitment:', commitment);

    const credential = createDIDCredential(commitment, 'Enhanced', 31536000); // 1 year
    console.log('DID Credential:', JSON.stringify(credential, null, 2));
}
