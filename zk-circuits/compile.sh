#!/bin/bash
# Circom Circuit Compilation and Trusted Setup
# Production-grade zk-SNARK key generation

set -e

echo "🔧 Compiling Circom circuits..."

# Install circom if not present
if ! command -v circom &> /dev/null; then
    echo "Installing circom..."
    git clone https://github.com/iden3/circom.git
    cd circom
    cargo build --release
    cargo install --path circom
    cd ..
fi

# Compile finality circuit
echo "Compiling finality.circom..."
circom zk-circuits/finality.circom \
    --r1cs --wasm --sym \
    --output zk-circuits/build

echo "✅ Circuit compiled successfully"
echo "📊 Circuit stats:"
circom zk-circuits/finality.circom --r1cs --wasm --sym --inspect

# Powers of Tau ceremony (Phase 1 - universal setup)
echo "🔐 Starting Powers of Tau ceremony..."

if [ ! -f zk-circuits/build/powersOfTau28_hez_final_16.ptau ]; then
    echo "Downloading Powers of Tau file..."
    wget -P zk-circuits/build \
        https://hermez.s3-eu-west-1.amazonaws.com/powersOfTau28_hez_final_16.ptau
fi

# Phase 2 - circuit-specific setup
echo "Generating zkey (Phase 2)..."
snarkjs groth16 setup \
    zk-circuits/build/finality.r1cs \
    zk-circuits/build/powersOfTau28_hez_final_16.ptau \
    zk-circuits/build/finality_0000.zkey

# Contribute to ceremony
echo "Contributing to ceremony..."
snarkjs zkey contribute \
    zk-circuits/build/finality_0000.zkey \
    zk-circuits/build/finality_0001.zkey \
    --name="First contribution" \
    -v -e="$(openssl rand -hex 64)"

# Second contribution for security
snarkjs zkey contribute \
    zk-circuits/build/finality_0001.zkey \
    zk-circuits/build/finality_final.zkey \
    --name="Second contribution" \
    -v -e="$(openssl rand -hex 64)"

# Export verification key
echo "Exporting verification key..."
snarkjs zkey export verificationkey \
    zk-circuits/build/finality_final.zkey \
    zk-circuits/build/verification_key.json

# Generate Solidity verifier
echo "Generating Solidity verifier contract..."
snarkjs zkey export solidityverifier \
    zk-circuits/build/finality_final.zkey \
    contracts/solidity/finality/FinalityVerifier.sol

# Verify the setup
echo "Verifying setup..."
snarkjs zkey verify \
    zk-circuits/build/finality.r1cs \
    zk-circuits/build/powersOfTau28_hez_final_16.ptau \
    zk-circuits/build/finality_final.zkey

echo "✅ Trusted setup complete!"
echo "📦 Files generated:"
echo "   - finality.r1cs (R1CS constraints)"
echo "   - finality.wasm (WASM circuit)"
echo "   - finality_final.zkey (Proving key)"
echo "   - verification_key.json (Verification key)"
echo "   - FinalityVerifier.sol (Solidity verifier)"

# Generate test proof
echo "🧪 Generating test proof..."
cat > zk-circuits/build/input.json <<EOF
{
  "publicChainId": "1",
  "publicBlockNumber": "18000000",
  "publicTimestamp": "1704067200",
  "blockHash": "12345678901234567890123456789012",
  "parentHash": "98765432109876543210987654321098",
  "stateRoot": "11111111111111111111111111111111",
  "receiptsRoot": "22222222222222222222222222222222",
  "timestamp": "1704067200",
  "nonce": "12345",
  "difficulty": "1000000",
  "merkleProof": $(node -e "console.log(JSON.stringify(Array(32).fill('0')))"),
  "merklePathIndices": $(node -e "console.log(JSON.stringify(Array(32).fill(0)))"),
  "txHash": "33333333333333333333333333333333",
  "historicalHashes": $(node -e "console.log(JSON.stringify(Array(64).fill('0')))")
}
EOF

snarkjs groth16 fullprove \
    zk-circuits/build/input.json \
    zk-circuits/build/finality.wasm \
    zk-circuits/build/finality_final.zkey \
    zk-circuits/build/proof.json \
    zk-circuits/build/public.json

echo "Verifying test proof..."
snarkjs groth16 verify \
    zk-circuits/build/verification_key.json \
    zk-circuits/build/public.json \
    zk-circuits/build/proof.json

echo "✅ Test proof verified successfully!"
echo "🎉 Circuit compilation complete and ready for production"
