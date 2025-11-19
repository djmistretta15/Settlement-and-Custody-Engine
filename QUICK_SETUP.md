# Quick Setup Guide for MVP Deployment

This guide helps you get the Settlement and Custody Engine compiled, tested, and deployed to testnet.

## Prerequisites

- Node.js 22.x or higher (LTS)
- Git
- Testnet ETH (from faucet)
- Infura or Alchemy API key

## Step 1: Clone and Install (5 minutes)

```bash
# Clone the repository
git clone https://github.com/djmistretta15/Settlement-and-Custody-Engine.git
cd Settlement-and-Custody-Engine

# Install dependencies
npm install --legacy-peer-deps

# Verify installation
npm run --help
```

## Step 2: Configure Environment (2 minutes)

Create a `.env` file in the root directory:

```env
# Testnet Configuration (Sepolia recommended)
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_INFURA_KEY
PRIVATE_KEY=your_testnet_private_key_here

# Optional: Polygon Mumbai for cross-chain testing
MUMBAI_RPC_URL=https://polygon-mumbai.infura.io/v3/YOUR_INFURA_KEY

# Optional: Etherscan for contract verification
ETHERSCAN_API_KEY=your_etherscan_api_key

# API Configuration
API_PORT=3000
API_SECRET=generate_random_secret_here

# Security
ENABLE_2FA=true
SESSION_TIMEOUT=3600
```

**Security Notes:**
- ⚠️ **NEVER** commit `.env` to git
- ⚠️ Use testnet keys only (never mainnet keys)
- ⚠️ Get testnet ETH from: https://sepoliafaucet.com/

## Step 3: Compile Contracts (2 minutes)

```bash
# Compile all smart contracts
npm run compile

# Expected output:
# Compiled 6 contracts successfully
# - InstitutionalCustody
# - ZKLightClient
# - ZKKYCIdentity
# - CrossChainSettlementEngine
# - SecurityLibraries
# - ICore
```

If compilation fails:
- Check Node.js version: `node --version` (should be 22.x+)
- Try: `npm run clean && npm run compile`
- Check internet connectivity to binaries.soliditylang.org

## Step 4: Run Tests (5 minutes)

```bash
# Run all tests
npm test

# Run with gas reporting
npm run test:gas

# Run with coverage
npm run test:coverage

# Expected: All tests should pass
```

Test coverage goals:
- ✅ Custody operations (deposit, withdraw, approve)
- ✅ Time-lock enforcement
- ✅ Admin functions
- ✅ Access control
- ✅ Settlement flows (coming soon)

## Step 5: Deploy to Testnet (10 minutes)

### Option A: Automated Deployment

```bash
# Deploy to Sepolia testnet
npm run deploy:testnet

# Expected output:
# 🚀 Deploying Settlement and Custody Engine...
# ✅ InstitutionalCustody deployed to: 0x...
# ✅ ZKLightClient deployed to: 0x...
# ✅ ZKKYCIdentity deployed to: 0x...
# ✅ CrossChainSettlementEngine deployed to: 0x...
```

### Option B: Manual Deployment

```bash
# Start local Hardhat network (for testing)
npm run node

# In another terminal, deploy
npm run deploy:local

# Verify contracts on Etherscan (after testnet deployment)
npm run verify -- <CONTRACT_ADDRESS> --network sepolia
```

## Step 6: Verify Deployment (5 minutes)

Check your contracts on Sepolia Etherscan:
- https://sepolia.etherscan.io/address/YOUR_CONTRACT_ADDRESS

Verify functionality:

```javascript
// Connect to deployed contract
const { ethers } = require("hardhat");

async function verifyDeployment() {
  const custody = await ethers.getContractAt(
    "InstitutionalCustody",
    "YOUR_DEPLOYED_ADDRESS"
  );
  
  // Check threshold config
  const config = await custody.getThresholdConfig();
  console.log("Required signatures:", config.requiredSignatures);
  console.log("Total signers:", config.totalSigners);
  
  // Check super admin
  const admin = await custody.getSuperAdmin();
  console.log("Super admin:", admin);
}

verifyDeployment();
```

## Step 7: Start API Server (2 minutes)

```bash
# Start the API server
npm run api:start

# Or for development with auto-reload
npm run api:dev

# Test the API
curl http://localhost:3000/health

# Expected response:
# {
#   "status": "healthy",
#   "version": "1.0.0",
#   "timestamp": "2025-11-19T..."
# }
```

## Step 8: Integration Testing (30 minutes)

### Test Custody Flow

```bash
# 1. Deposit test tokens
node scripts/test-deposit.js

# 2. Propose withdrawal
node scripts/test-withdraw-propose.js

# 3. Approve withdrawal (multiple signers)
node scripts/test-withdraw-approve.js

# 4. Execute after time-lock
# Wait 24 hours or adjust time-lock for testing
node scripts/test-withdraw-execute.js
```

### Test Settlement Flow

```bash
# 1. Verify KYC
node scripts/test-kyc-verify.js

# 2. Create cross-chain settlement
node scripts/test-settlement-create.js

# 3. Monitor settlement status
node scripts/test-settlement-monitor.js
```

## Common Issues & Solutions

### Issue: "Contracts not compiling"

**Solution:**
```bash
# Clear cache and rebuild
npm run clean
rm -rf cache artifacts
npm run compile
```

### Issue: "Out of gas during deployment"

**Solution:**
- Increase gas limit in hardhat.config.js
- Check testnet ETH balance
- Use gas estimation: `--gas-price 20`

### Issue: "Tests failing"

**Solution:**
```bash
# Run tests with verbose output
npm test -- --verbose

# Run specific test file
npm test -- test/InstitutionalCustody.test.js

# Check Hardhat network is clean
npm run clean && npm test
```

### Issue: "API not starting"

**Solution:**
- Check port 3000 is available: `lsof -i :3000`
- Check .env file exists and is configured
- Verify dependencies: `npm install`

## Production Deployment Checklist

Before deploying to mainnet:

- [ ] All tests passing (100% coverage target)
- [ ] Security audit completed (2-3 firms)
- [ ] Bug bounty program run (2-4 weeks)
- [ ] Testnet deployment successful (2+ weeks)
- [ ] Integration testing complete
- [ ] Monitoring and alerting set up
- [ ] Incident response plan documented
- [ ] Insurance coverage arranged
- [ ] Multi-sig wallet for admin functions
- [ ] Hardware wallets for critical keys
- [ ] Team training on operations
- [ ] Legal review completed

## Getting Help

### Documentation
- Full docs: `/docs`
- Threat model: `/docs/threat-model/THREAT_MODEL.md`
- Architecture: `/docs/architecture/ARCHITECTURE.md`
- Onboarding: `/docs/onboarding/GETTING_STARTED.md`

### Community
- GitHub Issues: https://github.com/djmistretta15/Settlement-and-Custody-Engine/issues
- Discussions: https://github.com/djmistretta15/Settlement-and-Custody-Engine/discussions

### Professional Support
For security audits, contact:
- OpenZeppelin: https://openzeppelin.com/security-audits
- Trail of Bits: https://www.trailofbits.com/
- Consensys Diligence: https://consensys.net/diligence/

## Timeline to MVP

| Phase | Duration | Status |
|-------|----------|--------|
| Setup & Install | 10 min | ⚡ Ready now |
| Compile & Test | 10 min | ⚡ Ready now |
| Deploy to Testnet | 15 min | ⚡ Ready now |
| Integration Testing | 1-2 days | ⏳ Pending |
| Bug Fixes | 3-5 days | ⏳ Pending |
| Security Audit | 4-6 weeks | ⏳ Pending |
| **Total to Production** | **6-8 weeks** | 🎯 Target |

## Success Metrics

### MVP Success Criteria
- ✅ All contracts compiled
- ✅ All tests passing
- ✅ Deployed to testnet
- ✅ API endpoints functional
- ✅ Sample transactions completed

### Production Success Criteria
- ✅ Security audit passed
- ✅ Bug bounty completed
- ✅ Insurance coverage
- ✅ Monitoring active
- ✅ Team trained

---

**Ready to start?** Run: `npm install && npm run compile && npm test`

**Questions?** Open an issue on GitHub

**Next:** See `MVP_READINESS_REPORT.md` for detailed status
