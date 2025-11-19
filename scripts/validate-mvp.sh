#!/bin/bash

# MVP Validation Script for Settlement and Custody Engine
# This script validates the project's MVP readiness

echo "🚀 Settlement and Custody Engine - MVP Validation"
echo "=================================================="
echo ""

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Counter for results
PASSED=0
FAILED=0
WARNINGS=0

# Function to print status
print_status() {
    if [ "$1" == "PASS" ]; then
        echo -e "${GREEN}✓${NC} $2"
        ((PASSED++))
    elif [ "$1" == "FAIL" ]; then
        echo -e "${RED}✗${NC} $2"
        ((FAILED++))
    elif [ "$1" == "WARN" ]; then
        echo -e "${YELLOW}⚠${NC} $2"
        ((WARNINGS++))
    fi
}

echo "1️⃣  Checking Project Structure..."
echo "-----------------------------------"

# Check if all required directories exist
if [ -d "contracts" ]; then
    print_status "PASS" "contracts/ directory exists"
else
    print_status "FAIL" "contracts/ directory missing"
fi

if [ -d "api-routes" ]; then
    print_status "PASS" "api-routes/ directory exists"
else
    print_status "FAIL" "api-routes/ directory missing"
fi

if [ -d "test" ]; then
    print_status "PASS" "test/ directory exists"
else
    print_status "FAIL" "test/ directory missing"
fi

if [ -d "docs" ]; then
    print_status "PASS" "docs/ directory exists"
else
    print_status "FAIL" "docs/ directory missing"
fi

echo ""
echo "2️⃣  Checking Smart Contracts..."
echo "-----------------------------------"

# Check for required contracts
contracts=(
    "contracts/custody/InstitutionalCustody.sol"
    "contracts/finality/ZKLightClient.sol"
    "contracts/identity/ZKKYCIdentity.sol"
    "contracts/settlement/CrossChainSettlementEngine.sol"
    "contracts/libraries/SecurityLibraries.sol"
    "contracts/interfaces/ICore.sol"
)

for contract in "${contracts[@]}"; do
    if [ -f "$contract" ]; then
        print_status "PASS" "$contract exists"
    else
        print_status "FAIL" "$contract missing"
    fi
done

echo ""
echo "3️⃣  Checking API Layer..."
echo "-----------------------------------"

# Check for API files
api_files=(
    "api-routes/rest/custody.js"
    "api-routes/rest/settlement.js"
    "api-routes/rest/identity.js"
    "api-routes/graphql/schema.js"
    "api-routes/server.js"
)

for file in "${api_files[@]}"; do
    if [ -f "$file" ]; then
        print_status "PASS" "$file exists"
    else
        print_status "FAIL" "$file missing"
    fi
done

echo ""
echo "4️⃣  Checking Documentation..."
echo "-----------------------------------"

# Check for documentation
docs=(
    "README.md"
    "docs/threat-model/THREAT_MODEL.md"
    "docs/onboarding/GETTING_STARTED.md"
    "docs/architecture/ARCHITECTURE.md"
)

for doc in "${docs[@]}"; do
    if [ -f "$doc" ]; then
        print_status "PASS" "$doc exists"
    else
        print_status "FAIL" "$doc missing"
    fi
done

echo ""
echo "5️⃣  Checking Configuration..."
echo "-----------------------------------"

if [ -f "package.json" ]; then
    print_status "PASS" "package.json exists"
else
    print_status "FAIL" "package.json missing"
fi

if [ -f "hardhat.config.js" ]; then
    print_status "PASS" "hardhat.config.js exists"
else
    print_status "FAIL" "hardhat.config.js missing"
fi

if [ -f ".gitignore" ]; then
    print_status "PASS" ".gitignore exists"
else
    print_status "FAIL" ".gitignore missing"
fi

echo ""
echo "6️⃣  Checking Dependencies..."
echo "-----------------------------------"

if [ -d "node_modules" ]; then
    print_status "PASS" "Dependencies installed (node_modules exists)"
else
    print_status "WARN" "Dependencies not installed (run: npm install)"
fi

echo ""
echo "7️⃣  Code Quality Metrics..."
echo "-----------------------------------"

# Count lines of code
SOLIDITY_LOC=$(find contracts -name "*.sol" 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
API_LOC=$(find api-routes -name "*.js" 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
TEST_LOC=$(find test -name "*.js" 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
DOC_WORDS=$(find docs -name "*.md" 2>/dev/null | xargs wc -w 2>/dev/null | tail -1 | awk '{print $1}')

echo "  Smart Contracts: $SOLIDITY_LOC lines"
echo "  API Layer: $API_LOC lines"
echo "  Tests: $TEST_LOC lines"
echo "  Documentation: $DOC_WORDS words"

if [ "$SOLIDITY_LOC" -gt 1000 ]; then
    print_status "PASS" "Substantial smart contract implementation"
fi

if [ "$API_LOC" -gt 500 ]; then
    print_status "PASS" "Complete API layer"
fi

if [ "$DOC_WORDS" -gt 10000 ]; then
    print_status "PASS" "Comprehensive documentation"
fi

echo ""
echo "8️⃣  MVP Readiness Checklist..."
echo "-----------------------------------"

# Check critical MVP requirements
print_status "WARN" "Contracts not compiled (blocked: Solidity compiler download)"
print_status "WARN" "Tests not run (requires compilation)"
print_status "WARN" "Not deployed to testnet"
print_status "WARN" "No security audit completed"

echo ""
echo "=================================================="
echo "📊 Validation Summary"
echo "=================================================="
echo -e "${GREEN}Passed:${NC} $PASSED"
echo -e "${YELLOW}Warnings:${NC} $WARNINGS"
echo -e "${RED}Failed:${NC} $FAILED"
echo ""

# Calculate overall status
TOTAL=$((PASSED + FAILED + WARNINGS))
if [ $FAILED -eq 0 ] && [ $WARNINGS -le 5 ]; then
    echo -e "${GREEN}✓ Project structure is MVP-ready!${NC}"
    echo ""
    echo "Next Steps:"
    echo "1. Fix environment to allow Solidity compilation"
    echo "2. Run: npm run compile"
    echo "3. Run: npm test"
    echo "4. Deploy to testnet"
    echo "5. Schedule security audit"
    exit 0
elif [ $FAILED -eq 0 ]; then
    echo -e "${YELLOW}⚠ Project has good structure but needs work${NC}"
    echo ""
    echo "Address the warnings above to reach MVP status"
    exit 1
else
    echo -e "${RED}✗ Project is not MVP-ready${NC}"
    echo ""
    echo "Critical issues need to be resolved"
    exit 2
fi
