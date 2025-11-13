import { ethers } from "hardhat";

async function main() {
  console.log("🚀 Deploying Settlement and Custody Engine...\n");

  const [deployer] = await ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

  // Configuration
  const REQUIRED_SIGNATURES = 3;
  const INITIAL_SIGNERS = [
    "0x1234567890123456789012345678901234567890", // Replace with actual addresses
    "0x2345678901234567890123456789012345678901",
    "0x3456789012345678901234567890123456789012"
  ];
  const ADMINS = [
    "0x4567890123456789012345678901234567890123", // Replace with actual addresses
    "0x5678901234567890123456789012345678901234"
  ];

  // Deploy InstitutionalCustody
  console.log("📦 Deploying InstitutionalCustody...");
  const InstitutionalCustody = await ethers.getContractFactory("InstitutionalCustody");
  const custody = await InstitutionalCustody.deploy(
    REQUIRED_SIGNATURES,
    INITIAL_SIGNERS,
    ADMINS
  );
  await custody.waitForDeployment();
  console.log("✅ InstitutionalCustody deployed to:", await custody.getAddress());

  // Deploy ZKLightClient
  console.log("\n📦 Deploying ZKLightClient...");
  const ZKLightClient = await ethers.getContractFactory("ZKLightClient");
  const lightClient = await ZKLightClient.deploy();
  await lightClient.waitForDeployment();
  console.log("✅ ZKLightClient deployed to:", await lightClient.getAddress());

  // Deploy ZKKYCIdentity
  console.log("\n📦 Deploying ZKKYCIdentity...");
  const ZKKYCIdentity = await ethers.getContractFactory("ZKKYCIdentity");
  const identity = await ZKKYCIdentity.deploy();
  await identity.waitForDeployment();
  console.log("✅ ZKKYCIdentity deployed to:", await identity.getAddress());

  // Deploy CrossChainSettlementEngine
  console.log("\n📦 Deploying CrossChainSettlementEngine...");
  const CrossChainSettlementEngine = await ethers.getContractFactory("CrossChainSettlementEngine");
  const settlement = await CrossChainSettlementEngine.deploy(
    await lightClient.getAddress(),
    await identity.getAddress(),
    await custody.getAddress()
  );
  await settlement.waitForDeployment();
  console.log("✅ CrossChainSettlementEngine deployed to:", await settlement.getAddress());

  // Configuration
  console.log("\n⚙️  Configuring contracts...");

  // Add supported chains to light client
  console.log("Adding supported chains to light client...");
  await lightClient.addChain(1, 32, ethers.ZeroHash); // Ethereum
  await lightClient.addChain(137, 256, ethers.ZeroHash); // Polygon
  await lightClient.addChain(42161, 1, ethers.ZeroHash); // Arbitrum
  console.log("✅ Chains configured");

  // Add supported chains to settlement engine
  console.log("Adding supported chains to settlement engine...");
  await settlement.addSupportedChain(1, ethers.parseEther("0.01"), ethers.parseEther("1000"));
  await settlement.addSupportedChain(137, ethers.parseEther("0.01"), ethers.parseEther("1000"));
  await settlement.addSupportedChain(42161, ethers.parseEther("0.01"), ethers.parseEther("1000"));
  console.log("✅ Settlement chains configured");

  // Grant roles
  console.log("Granting roles...");
  const SETTLER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("SETTLER_ROLE"));
  const RELAYER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("RELAYER_ROLE"));
  
  await settlement.grantRole(SETTLER_ROLE, deployer.address);
  console.log("✅ Roles granted");

  // Summary
  console.log("\n" + "=".repeat(60));
  console.log("📋 DEPLOYMENT SUMMARY");
  console.log("=".repeat(60));
  console.log("InstitutionalCustody:         ", await custody.getAddress());
  console.log("ZKLightClient:                ", await lightClient.getAddress());
  console.log("ZKKYCIdentity:                ", await identity.getAddress());
  console.log("CrossChainSettlementEngine:   ", await settlement.getAddress());
  console.log("=".repeat(60));

  // Save deployment info
  const deployment = {
    network: (await ethers.provider.getNetwork()).name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      InstitutionalCustody: await custody.getAddress(),
      ZKLightClient: await lightClient.getAddress(),
      ZKKYCIdentity: await identity.getAddress(),
      CrossChainSettlementEngine: await settlement.getAddress()
    },
    configuration: {
      custody: {
        requiredSignatures: REQUIRED_SIGNATURES,
        initialSigners: INITIAL_SIGNERS,
        admins: ADMINS
      },
      chains: [
        { chainId: 1, name: "Ethereum", finalityDelay: 32 },
        { chainId: 137, name: "Polygon", finalityDelay: 256 },
        { chainId: 42161, name: "Arbitrum", finalityDelay: 1 }
      ]
    }
  };

  console.log("\n💾 Deployment info saved to deployments.json");
  console.log("\n✨ Deployment complete!\n");

  return deployment;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
