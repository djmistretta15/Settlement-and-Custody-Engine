/**
 * Hardhat Tests for Settlement Engine
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('SettlementEngine', function () {
    let settlementEngine;
    let lightClient;
    let stateReconciliation;
    let vault;
    let kycRegistry;
    let owner, originator, beneficiary, relayer;

    const CHAIN_ID_ETH = 1;
    const CHAIN_ID_POLYGON = 137;

    before(async function () {
        [owner, originator, beneficiary, relayer] = await ethers.getSigners();

        // Deploy ZKLightClient
        const ZKLightClient = await ethers.getContractFactory('ZKLightClient');
        lightClient = await ZKLightClient.deploy();
        await lightClient.waitForDeployment();

        // Deploy StateReconciliation
        const StateReconciliation = await ethers.getContractFactory('StateReconciliation');
        stateReconciliation = await StateReconciliation.deploy(await lightClient.getAddress());
        await stateReconciliation.waitForDeployment();

        // Deploy MPCVault
        const MPCVault = await ethers.getContractFactory('MPCVault');
        vault = await MPCVault.deploy();
        await vault.waitForDeployment();

        // Deploy ZKKYCRegistry
        const ZKKYCRegistry = await ethers.getContractFactory('ZKKYCRegistry');
        const mockVerifyingKey = ethers.hexlify(ethers.randomBytes(128));
        kycRegistry = await ZKKYCRegistry.deploy(mockVerifyingKey);
        await kycRegistry.waitForDeployment();

        // Deploy SettlementEngine
        const SettlementEngine = await ethers.getContractFactory('SettlementEngine');
        settlementEngine = await SettlementEngine.deploy(
            await lightClient.getAddress(),
            await stateReconciliation.getAddress(),
            await vault.getAddress(),
            await kycRegistry.getAddress()
        );
        await settlementEngine.waitForDeployment();

        console.log('All contracts deployed successfully');
    });

    describe('Deployment', function () {
        it('Should set the correct addresses', async function () {
            expect(await settlementEngine.lightClient()).to.equal(await lightClient.getAddress());
            expect(await settlementEngine.vault()).to.equal(await vault.getAddress());
            expect(await settlementEngine.kycRegistry()).to.equal(await kycRegistry.getAddress());
        });

        it('Should set correct owner', async function () {
            expect(await settlementEngine.owner()).to.equal(owner.address);
        });
    });

    describe('KYC Registration', function () {
        it('Should issue KYC credentials', async function () {
            const did = ethers.id('did:example:originator');
            const credentialHash = ethers.id('credential_hash');
            const kycLevel = 2; // Enhanced
            const validityPeriod = 365 * 24 * 60 * 60; // 1 year

            await kycRegistry.issueCredential(
                did,
                originator.address,
                credentialHash,
                kycLevel,
                validityPeriod
            );

            const isVerified = await kycRegistry.isWalletKYCVerified(originator.address);
            expect(isVerified).to.be.true;
        });

        it('Should issue KYC credential for beneficiary', async function () {
            const did = ethers.id('did:example:beneficiary');
            const credentialHash = ethers.id('beneficiary_credential');
            const kycLevel = 2; // Enhanced
            const validityPeriod = 365 * 24 * 60 * 60;

            await kycRegistry.issueCredential(
                did,
                beneficiary.address,
                credentialHash,
                kycLevel,
                validityPeriod
            );

            const isVerified = await kycRegistry.isWalletKYCVerified(beneficiary.address);
            expect(isVerified).to.be.true;
        });
    });

    describe('Vault Creation', function () {
        it('Should create an MPC vault', async function () {
            const vaultId = ethers.id('test_vault');
            const threshold = 2;
            const signers = [owner.address, relayer.address, originator.address];

            await vault.createVault(vaultId, threshold, signers);

            const vaultConfig = await vault.vaults(vaultId);
            expect(vaultConfig.threshold).to.equal(threshold);
            expect(vaultConfig.totalSigners).to.equal(signers.length);
            expect(vaultConfig.isActive).to.be.true;
        });
    });

    describe('Settlement Initiation', function () {
        let instructionId;

        it('Should initiate a settlement instruction', async function () {
            const amount = ethers.parseEther('100');
            const vaultId = ethers.id('test_vault');
            const metadata = ethers.hexlify(ethers.toUtf8Bytes('{"memo": "test settlement"}'));

            const tx = await settlementEngine.connect(originator).initiateSettlement(
                beneficiary.address,
                CHAIN_ID_ETH,
                CHAIN_ID_POLYGON,
                ethers.ZeroAddress, // ETH
                amount,
                vaultId,
                metadata
            );

            const receipt = await tx.wait();
            const event = receipt.logs.find(
                log => log.fragment && log.fragment.name === 'SettlementInitiated'
            );

            expect(event).to.not.be.undefined;
            instructionId = event.args.instructionId;

            const settlement = await settlementEngine.getSettlement(instructionId);
            expect(settlement.originator).to.equal(originator.address);
            expect(settlement.beneficiary).to.equal(beneficiary.address);
            expect(settlement.amount).to.equal(amount);
            expect(settlement.status).to.equal(0); // Pending
        });

        it('Should fail for non-KYC verified originator', async function () {
            const nonKYCUser = (await ethers.getSigners())[4];
            const amount = ethers.parseEther('100');
            const vaultId = ethers.id('test_vault');

            await expect(
                settlementEngine.connect(nonKYCUser).initiateSettlement(
                    beneficiary.address,
                    CHAIN_ID_ETH,
                    CHAIN_ID_POLYGON,
                    ethers.ZeroAddress,
                    amount,
                    vaultId,
                    '0x'
                )
            ).to.be.revertedWith('Originator not KYC verified');
        });

        it('Should enforce rate limiting', async function () {
            const amount = ethers.parseEther('10');
            const vaultId = ethers.id('test_vault');

            // This should fail due to rate limiting (second call too soon)
            await expect(
                settlementEngine.connect(originator).initiateSettlement(
                    beneficiary.address,
                    CHAIN_ID_ETH,
                    CHAIN_ID_POLYGON,
                    ethers.ZeroAddress,
                    amount,
                    vaultId,
                    '0x'
                )
            ).to.be.revertedWith('Rate limit: too frequent');
        });
    });

    describe('Light Client Integration', function () {
        it('Should register verifying key for a chain', async function () {
            const mockVerifyingKey = ethers.hexlify(ethers.randomBytes(128));

            await lightClient.registerVerifyingKey(CHAIN_ID_ETH, mockVerifyingKey);

            const storedKey = await lightClient.verifyingKeys(CHAIN_ID_ETH);
            expect(storedKey).to.equal(mockVerifyingKey);
        });

        it('Should verify a block proof', async function () {
            await lightClient.addRelayer(relayer.address);

            const blockProof = {
                blockHeight: 1000,
                blockHash: ethers.randomBytes(32),
                stateRoot: ethers.randomBytes(32),
                receiptsRoot: ethers.randomBytes(32),
                timestamp: Math.floor(Date.now() / 1000),
                proof: [ethers.randomBytes(32), ethers.randomBytes(32)],
                zkProof: ethers.hexlify(ethers.randomBytes(128))
            };

            await lightClient.connect(relayer).verifyBlock(CHAIN_ID_ETH, blockProof);

            const checkpoint = await lightClient.getCheckpoint(CHAIN_ID_ETH, 1000);
            expect(checkpoint.blockHeight).to.equal(1000);
        });
    });

    describe('Gas Optimization', function () {
        it('Should measure gas for settlement initiation', async function () {
            const amount = ethers.parseEther('50');
            const vaultId = ethers.id('test_vault');

            // Wait for rate limit
            await ethers.provider.send('evm_increaseTime', [61]);
            await ethers.provider.send('evm_mine');

            const tx = await settlementEngine.connect(originator).initiateSettlement(
                beneficiary.address,
                CHAIN_ID_ETH,
                CHAIN_ID_POLYGON,
                ethers.ZeroAddress,
                amount,
                vaultId,
                '0x'
            );

            const receipt = await tx.wait();
            console.log('Gas used for initiation:', receipt.gasUsed.toString());

            expect(receipt.gasUsed).to.be.lessThan(500000); // Should be optimized
        });
    });
});

describe('MPCVault', function () {
    let vault, owner, signer1, signer2, signer3;

    before(async function () {
        [owner, signer1, signer2, signer3] = await ethers.getSigners();

        const MPCVault = await ethers.getContractFactory('MPCVault');
        vault = await MPCVault.deploy();
        await vault.waitForDeployment();
    });

    describe('Transaction Proposals', function () {
        it('Should create and approve a transaction proposal', async function () {
            const vaultId = ethers.id('proposal_vault');
            const threshold = 2;
            const signers = [signer1.address, signer2.address, signer3.address];

            await vault.createVault(vaultId, threshold, signers);

            // Grant signer roles
            await vault.grantRole(await vault.SIGNER_ROLE(), signer1.address);
            await vault.grantRole(await vault.SIGNER_ROLE(), signer2.address);

            // Create proposal
            const proposalTx = await vault.connect(signer1).proposeTransaction(
                vaultId,
                owner.address,
                ethers.parseEther('1'),
                '0x',
                1
            );

            const receipt = await proposalTx.wait();
            const event = receipt.logs.find(
                log => log.fragment && log.fragment.name === 'ProposalCreated'
            );

            const proposalId = event.args.proposalId;

            // Approve with threshold signatures
            const mockSig1 = ethers.hexlify(ethers.randomBytes(65));
            const mockSig2 = ethers.hexlify(ethers.randomBytes(65));

            await vault.connect(signer1).approveProposal(vaultId, proposalId, mockSig1);
            await vault.connect(signer2).approveProposal(vaultId, proposalId, mockSig2);

            const signatureCount = await vault.getProposalSignatureCount(vaultId, proposalId);
            expect(signatureCount).to.equal(2);
        });

        it('Should track audit logs', async function () {
            const logsCount = await vault.getAuditLogsCount();
            expect(logsCount).to.be.greaterThan(0);

            const log = await vault.auditLogs(0);
            expect(log.actor).to.equal(owner.address);
        });
    });
});
