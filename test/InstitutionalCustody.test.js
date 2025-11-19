import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Test Suite for InstitutionalCustody Contract
 * Tests threshold signatures, time-locks, and admin controls
 */
describe("InstitutionalCustody", function () {
  // Fixture for deploying the contract
  async function deployInstitutionalCustodyFixture() {
    const [owner, signer1, signer2, signer3, admin1, admin2, user1, user2] = 
      await ethers.getSigners();

    const requiredSignatures = 2;
    const initialSigners = [signer1.address, signer2.address, signer3.address];
    const admins = [admin1.address, admin2.address];

    const InstitutionalCustody = await ethers.getContractFactory("InstitutionalCustody");
    const custody = await InstitutionalCustody.deploy(
      requiredSignatures,
      initialSigners,
      admins
    );

    return { custody, owner, signer1, signer2, signer3, admin1, admin2, user1, user2 };
  }

  describe("Deployment", function () {
    it("Should set the correct threshold", async function () {
      const { custody } = await loadFixture(deployInstitutionalCustodyFixture);
      const config = await custody.getThresholdConfig();
      expect(config.requiredSignatures).to.equal(2);
    });

    it("Should initialize signers correctly", async function () {
      const { custody, signer1, signer2, signer3 } = 
        await loadFixture(deployInstitutionalCustodyFixture);
      
      expect(await custody.isAuthorizedSigner(signer1.address)).to.be.true;
      expect(await custody.isAuthorizedSigner(signer2.address)).to.be.true;
      expect(await custody.isAuthorizedSigner(signer3.address)).to.be.true;
    });

    it("Should initialize admins correctly", async function () {
      const { custody, admin1, admin2 } = 
        await loadFixture(deployInstitutionalCustodyFixture);
      
      expect(await custody.isAdmin(admin1.address)).to.be.true;
      expect(await custody.isAdmin(admin2.address)).to.be.true;
    });

    it("Should set super admin to deployer", async function () {
      const { custody, owner } = await loadFixture(deployInstitutionalCustodyFixture);
      expect(await custody.getSuperAdmin()).to.equal(owner.address);
    });
  });

  describe("Deposits", function () {
    it("Should receive ETH deposits", async function () {
      const { custody, user1 } = await loadFixture(deployInstitutionalCustodyFixture);
      
      const depositAmount = ethers.parseEther("1.0");
      
      await expect(
        user1.sendTransaction({
          to: custody.target,
          value: depositAmount
        })
      ).to.emit(custody, "DepositReceived")
        .withArgs(ethers.ZeroAddress, depositAmount, user1.address, anyValue, false);
      
      expect(await ethers.provider.getBalance(custody.target)).to.equal(depositAmount);
    });

    // Additional deposit tests would be here
  });

  describe("Withdrawals", function () {
    it("Should allow authorized signer to propose withdrawal", async function () {
      const { custody, signer1, user1 } = 
        await loadFixture(deployInstitutionalCustodyFixture);
      
      // First deposit some ETH
      await user1.sendTransaction({
        to: custody.target,
        value: ethers.parseEther("10.0")
      });
      
      const withdrawAmount = ethers.parseEther("1.0");
      
      await expect(
        custody.connect(signer1).proposeWithdrawal(
          ethers.ZeroAddress,
          withdrawAmount,
          user1.address,
          false
        )
      ).to.emit(custody, "WithdrawalProposed");
    });

    it("Should require authorized signer to propose", async function () {
      const { custody, user1 } = await loadFixture(deployInstitutionalCustodyFixture);
      
      await expect(
        custody.connect(user1).proposeWithdrawal(
          ethers.ZeroAddress,
          ethers.parseEther("1.0"),
          user1.address,
          false
        )
      ).to.be.revertedWith("Not authorized signer");
    });

    it("Should allow threshold approvals", async function () {
      const { custody, signer1, signer2, user1 } = 
        await loadFixture(deployInstitutionalCustodyFixture);
      
      // Deposit ETH
      await user1.sendTransaction({
        to: custody.target,
        value: ethers.parseEther("10.0")
      });
      
      // Propose withdrawal
      const tx = await custody.connect(signer1).proposeWithdrawal(
        ethers.ZeroAddress,
        ethers.parseEther("1.0"),
        user1.address,
        false
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === 'WithdrawalProposed');
      const requestId = event.args[0];
      
      // Second signer approves
      await expect(
        custody.connect(signer2).approveWithdrawal(requestId)
      ).to.emit(custody, "WithdrawalApproved");
      
      const request = await custody.getWithdrawalRequest(requestId);
      expect(request.approvalCount).to.equal(2);
    });

    it("Should enforce time-lock delay", async function () {
      const { custody, signer1, signer2, user1 } = 
        await loadFixture(deployInstitutionalCustodyFixture);
      
      // Deposit and propose
      await user1.sendTransaction({
        to: custody.target,
        value: ethers.parseEther("10.0")
      });
      
      const tx = await custody.connect(signer1).proposeWithdrawal(
        ethers.ZeroAddress,
        ethers.parseEther("1.0"),
        user1.address,
        false
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === 'WithdrawalProposed');
      const requestId = event.args[0];
      
      // Approve with second signer
      await custody.connect(signer2).approveWithdrawal(requestId);
      
      // Try to execute immediately - should fail
      await expect(
        custody.executeWithdrawal(requestId)
      ).to.be.revertedWith("Time-lock not expired");
    });
  });

  describe("Admin Functions", function () {
    it("Should allow super admin to add signer", async function () {
      const { custody, owner, user1 } = 
        await loadFixture(deployInstitutionalCustodyFixture);
      
      await expect(
        custody.connect(owner).addSigner(user1.address)
      ).to.emit(custody, "SignerAdded")
        .withArgs(user1.address, anyValue, owner.address);
      
      expect(await custody.isAuthorizedSigner(user1.address)).to.be.true;
    });

    it("Should allow super admin to remove signer", async function () {
      const { custody, owner, signer3 } = 
        await loadFixture(deployInstitutionalCustodyFixture);
      
      await expect(
        custody.connect(owner).removeSigner(signer3.address)
      ).to.emit(custody, "SignerRemoved");
      
      expect(await custody.isAuthorizedSigner(signer3.address)).to.be.false;
    });

    it("Should allow super admin to update threshold", async function () {
      const { custody, owner } = 
        await loadFixture(deployInstitutionalCustodyFixture);
      
      await expect(
        custody.connect(owner).updateThreshold(3)
      ).to.emit(custody, "ThresholdUpdated")
        .withArgs(2, 3, anyValue, owner.address);
      
      const config = await custody.getThresholdConfig();
      expect(config.requiredSignatures).to.equal(3);
    });

    it("Should allow admin to pause contract", async function () {
      const { custody, admin1 } = 
        await loadFixture(deployInstitutionalCustodyFixture);
      
      await expect(
        custody.connect(admin1).pause()
      ).to.emit(custody, "EmergencyPaused");
      
      expect(await custody.paused()).to.be.true;
    });

    it("Should prevent operations when paused", async function () {
      const { custody, admin1, signer1, user1 } = 
        await loadFixture(deployInstitutionalCustodyFixture);
      
      // Pause contract
      await custody.connect(admin1).pause();
      
      // Try to propose withdrawal
      await expect(
        custody.connect(signer1).proposeWithdrawal(
          ethers.ZeroAddress,
          ethers.parseEther("1.0"),
          user1.address,
          false
        )
      ).to.be.revertedWith("Pausable: paused");
    });
  });

  describe("Access Control", function () {
    it("Should prevent non-super-admin from adding signers", async function () {
      const { custody, user1, user2 } = 
        await loadFixture(deployInstitutionalCustodyFixture);
      
      await expect(
        custody.connect(user1).addSigner(user2.address)
      ).to.be.revertedWith("Only super admin");
    });

    it("Should prevent non-admin from pausing", async function () {
      const { custody, user1 } = 
        await loadFixture(deployInstitutionalCustodyFixture);
      
      await expect(
        custody.connect(user1).pause()
      ).to.be.revertedWith("Only admin");
    });
  });
});

// Helper to match any value in events
const anyValue = {
  [Symbol.for("chai.match.any")]: true
};
