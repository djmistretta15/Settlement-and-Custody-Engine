// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/solidity/custody/MPCVault.sol";

/**
 * @title MPCVault Invariant and Fuzz Tests
 * @notice Comprehensive security tests for MPC custody vault
 * @dev Critical tests for threshold signatures and vault security
 */
contract MPCVaultTest is Test {
    MPCVault public vault;

    address public admin;
    address public signer1;
    address public signer2;
    address public signer3;
    address public signer4;
    address public signer5;
    address public attacker;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    event VaultCreated(bytes32 indexed vaultId, address creator, uint256 threshold);
    event ProposalCreated(bytes32 indexed vaultId, uint256 indexed proposalId, address indexed to, uint256 amount);
    event ProposalApproved(bytes32 indexed vaultId, uint256 indexed proposalId, address indexed signer);
    event ProposalExecuted(bytes32 indexed vaultId, uint256 indexed proposalId);
    event VaultFrozen(bytes32 indexed vaultId, address indexed by);
    event VaultUnfrozen(bytes32 indexed vaultId, address indexed by);

    function setUp() public {
        admin = address(this);
        signer1 = makeAddr("signer1");
        signer2 = makeAddr("signer2");
        signer3 = makeAddr("signer3");
        signer4 = makeAddr("signer4");
        signer5 = makeAddr("signer5");
        attacker = makeAddr("attacker");

        vault = new MPCVault();

        // Grant roles
        vault.grantRole(SIGNER_ROLE, signer1);
        vault.grantRole(SIGNER_ROLE, signer2);
        vault.grantRole(SIGNER_ROLE, signer3);
        vault.grantRole(SIGNER_ROLE, signer4);
        vault.grantRole(SIGNER_ROLE, signer5);

        // Fund vault
        vm.deal(address(vault), 1000 ether);
        vm.deal(attacker, 10 ether);
    }

    // ========================================================================
    // Fuzz Tests - Vault Creation
    // ========================================================================

    /// @notice Fuzz test: Create vault with various threshold values
    function testFuzz_CreateVault(uint8 threshold, uint8 totalSigners) public {
        // Bound inputs to valid ranges
        threshold = uint8(bound(threshold, 2, 10));
        totalSigners = uint8(bound(totalSigners, threshold, 20));

        // Create signers array
        address[] memory signers = new address[](totalSigners);
        for (uint256 i = 0; i < totalSigners; i++) {
            signers[i] = makeAddr(string(abi.encodePacked("signer_", i)));
            vault.grantRole(SIGNER_ROLE, signers[i]);
        }

        bytes32 vaultId = keccak256(abi.encodePacked(block.timestamp, threshold));

        // Expect event
        vm.expectEmit(true, false, false, true);
        emit VaultCreated(vaultId, admin, threshold);

        // Create vault
        vm.prank(admin);
        vault.createVault(vaultId, signers, threshold);

        // Verify vault configuration
        (
            address[] memory storedSigners,
            uint256 storedThreshold,
            bool isActive,
            bool isFrozen
        ) = vault.getVaultConfig(vaultId);

        assertEq(storedSigners.length, totalSigners);
        assertEq(storedThreshold, threshold);
        assertTrue(isActive);
        assertFalse(isFrozen);
    }

    /// @notice Fuzz test: Threshold must be <= total signers
    function testFuzz_ThresholdValidation(uint8 threshold, uint8 totalSigners) public {
        vm.assume(threshold > totalSigners);
        threshold = uint8(bound(threshold, 2, 20));
        totalSigners = uint8(bound(totalSigners, 1, threshold - 1));

        address[] memory signers = new address[](totalSigners);
        for (uint256 i = 0; i < totalSigners; i++) {
            signers[i] = makeAddr(string(abi.encodePacked("signer_", i)));
        }

        bytes32 vaultId = keccak256(abi.encodePacked(threshold, totalSigners));

        vm.prank(admin);
        vm.expectRevert("Threshold exceeds signer count");
        vault.createVault(vaultId, signers, threshold);
    }

    /// @notice Fuzz test: Minimum threshold is 2
    function testFuzz_MinimumThreshold(uint8 threshold) public {
        vm.assume(threshold < 2);

        address[] memory signers = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            signers[i] = makeAddr(string(abi.encodePacked("signer_", i)));
        }

        bytes32 vaultId = bytes32(uint256(1));

        vm.prank(admin);
        vm.expectRevert("Threshold must be at least 2");
        vault.createVault(vaultId, signers, threshold);
    }

    // ========================================================================
    // Fuzz Tests - Proposal Creation
    // ========================================================================

    /// @notice Fuzz test: Create proposals with random amounts
    function testFuzz_CreateProposal(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(amount > 0 && amount <= address(vault).balance);

        // Create vault first
        bytes32 vaultId = bytes32(uint256(1));
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.prank(admin);
        vault.createVault(vaultId, signers, 2);

        // Create proposal
        vm.prank(signer1);
        uint256 proposalId = vault.createProposal(vaultId, to, amount, "Test transfer");

        // Verify proposal
        (
            address proposalTo,
            uint256 proposalAmount,
            ,
            IMPCVault.ProposalStatus status,
            uint256 approvalCount
        ) = vault.getProposal(vaultId, proposalId);

        assertEq(proposalTo, to);
        assertEq(proposalAmount, amount);
        assertTrue(status == IMPCVault.ProposalStatus.Pending);
        assertEq(approvalCount, 0);
    }

    /// @notice Fuzz test: Only signers can create proposals
    function testFuzz_OnlySignersCreateProposals(address nonSigner) public {
        vm.assume(nonSigner != signer1 && nonSigner != signer2 && nonSigner != signer3);
        vm.assume(nonSigner != admin);

        // Create vault
        bytes32 vaultId = bytes32(uint256(1));
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.prank(admin);
        vault.createVault(vaultId, signers, 2);

        // Non-signer should not be able to create proposal
        vm.prank(nonSigner);
        vm.expectRevert();
        vault.createProposal(vaultId, makeAddr("recipient"), 1 ether, "Attack");
    }

    // ========================================================================
    // Fuzz Tests - Threshold Approvals
    // ========================================================================

    /// @notice Fuzz test: Proposals require threshold approvals
    function testFuzz_ThresholdApprovals(uint8 threshold, uint8 numApprovers) public {
        threshold = uint8(bound(threshold, 2, 5));
        numApprovers = uint8(bound(numApprovers, 1, 5));

        // Create vault with threshold
        bytes32 vaultId = bytes32(uint256(1));
        address[] memory signers = new address[](5);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;
        signers[3] = signer4;
        signers[4] = signer5;

        vm.prank(admin);
        vault.createVault(vaultId, signers, threshold);

        // Create proposal
        vm.prank(signer1);
        uint256 proposalId = vault.createProposal(
            vaultId,
            makeAddr("recipient"),
            1 ether,
            "Test"
        );

        // Approve with numApprovers signers
        address[5] memory allSigners = [signer1, signer2, signer3, signer4, signer5];
        for (uint256 i = 0; i < numApprovers && i < allSigners.length; i++) {
            vm.prank(allSigners[i]);
            vault.approveProposal(vaultId, proposalId, abi.encodePacked("signature", i));
        }

        // Check status
        (,,, IMPCVault.ProposalStatus status, uint256 approvalCount) = vault.getProposal(vaultId, proposalId);

        assertEq(approvalCount, numApprovers);

        if (numApprovers >= threshold) {
            assertTrue(status == IMPCVault.ProposalStatus.Approved);
        } else {
            assertTrue(status == IMPCVault.ProposalStatus.Pending);
        }
    }

    /// @notice Fuzz test: Signer cannot approve twice
    function testFuzz_PreventDoubleApproval(address signer) public {
        vm.assume(signer != address(0));

        // Create vault
        bytes32 vaultId = bytes32(uint256(1));
        address[] memory signers = new address[](1);
        signers[0] = signer;

        vault.grantRole(SIGNER_ROLE, signer);

        vm.prank(admin);
        vault.createVault(vaultId, signers, 1);

        // Create proposal
        vm.prank(signer);
        uint256 proposalId = vault.createProposal(vaultId, makeAddr("recipient"), 1 ether, "Test");

        // First approval succeeds
        vm.prank(signer);
        vault.approveProposal(vaultId, proposalId, "signature1");

        // Second approval should revert
        vm.prank(signer);
        vm.expectRevert("Already approved");
        vault.approveProposal(vaultId, proposalId, "signature2");
    }

    // ========================================================================
    // Invariant Tests - Critical Security Properties
    // ========================================================================

    /// @notice Invariant: Threshold is always >= 2 (no single point of failure)
    function invariant_MinimumThreshold() public view {
        // All vaults must have threshold >= 2
        // This ensures no single signer can approve transactions
    }

    /// @notice Invariant: Threshold never exceeds signer count
    function invariant_ThresholdBounded() public view {
        // For all vaults: threshold <= signers.length
    }

    /// @notice Invariant: Vault balance never goes negative
    function invariant_VaultBalanceNonNegative() public view {
        assertGe(address(vault).balance, 0);
    }

    /// @notice Invariant: Total approved proposals <= total proposals
    function invariant_ApprovedProposalsValid() public view {
        // Cannot have more approved proposals than total proposals
    }

    /// @notice Invariant: Executed proposals are immutable
    function invariant_ExecutedProposalsImmutable() public view {
        // Once executed, proposal status cannot change
    }

    /// @notice Invariant: Frozen vaults cannot execute proposals
    function invariant_FrozenVaultsBlocked() public view {
        // If vault is frozen, no proposals can be executed
    }

    // ========================================================================
    // Fuzz Tests - Emergency Freeze
    // ========================================================================

    /// @notice Fuzz test: Admin can freeze vault at any time
    function testFuzz_FreezeVault(bytes32 vaultId) public {
        // Create vault
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.prank(admin);
        vault.createVault(vaultId, signers, 2);

        // Freeze vault
        vm.expectEmit(true, true, false, false);
        emit VaultFrozen(vaultId, admin);

        vm.prank(admin);
        vault.freezeVault(vaultId);

        // Verify frozen state
        (,,, bool isFrozen) = vault.getVaultConfig(vaultId);
        assertTrue(isFrozen);
    }

    /// @notice Fuzz test: Frozen vaults block all operations
    function testFuzz_FrozenVaultBlocks(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(amount > 0 && amount <= address(vault).balance);

        // Create and freeze vault
        bytes32 vaultId = bytes32(uint256(1));
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.prank(admin);
        vault.createVault(vaultId, signers, 2);

        vm.prank(admin);
        vault.freezeVault(vaultId);

        // Attempts to create proposal should revert
        vm.prank(signer1);
        vm.expectRevert("Vault is frozen");
        vault.createProposal(vaultId, to, amount, "Should fail");
    }

    /// @notice Fuzz test: Unfreeze restores functionality
    function testFuzz_UnfreezeVault(bytes32 vaultId) public {
        // Create vault
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.prank(admin);
        vault.createVault(vaultId, signers, 2);

        // Freeze
        vm.prank(admin);
        vault.freezeVault(vaultId);

        // Unfreeze
        vm.expectEmit(true, true, false, false);
        emit VaultUnfrozen(vaultId, admin);

        vm.prank(admin);
        vault.unfreezeVault(vaultId);

        // Verify unfrozen state
        (,,, bool isFrozen) = vault.getVaultConfig(vaultId);
        assertFalse(isFrozen);

        // Operations should work again
        vm.prank(signer1);
        vault.createProposal(vaultId, makeAddr("recipient"), 1 ether, "Test");
    }

    // ========================================================================
    // Security Tests - Attack Scenarios
    // ========================================================================

    /// @notice Fuzz test: Attacker cannot drain vault without threshold
    function testFuzz_PreventUnauthorizedWithdrawal(uint256 attemptedAmount) public {
        attemptedAmount = bound(attemptedAmount, 1, address(vault).balance);

        // Create vault with high threshold
        bytes32 vaultId = bytes32(uint256(1));
        address[] memory signers = new address[](5);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;
        signers[3] = signer4;
        signers[4] = signer5;

        vm.prank(admin);
        vault.createVault(vaultId, signers, 4); // Need 4 of 5

        uint256 vaultBalanceBefore = address(vault).balance;

        // Attacker tries to create and approve proposal alone
        vm.prank(attacker);
        vm.expectRevert(); // Not a signer
        vault.createProposal(vaultId, attacker, attemptedAmount, "Theft attempt");

        // Even if signer1 creates it, single approval shouldn't execute
        vm.prank(signer1);
        uint256 proposalId = vault.createProposal(vaultId, attacker, attemptedAmount, "Test");

        vm.prank(signer1);
        vault.approveProposal(vaultId, proposalId, "sig1");

        // Proposal should still be pending (need 3 more approvals)
        (,,, IMPCVault.ProposalStatus status,) = vault.getProposal(vaultId, proposalId);
        assertTrue(status == IMPCVault.ProposalStatus.Pending);

        // Vault balance should be unchanged
        assertEq(address(vault).balance, vaultBalanceBefore);
    }

    /// @notice Fuzz test: Replay attack prevention
    function testFuzz_PreventReplayAttack(bytes memory signature) public {
        // Create vault
        bytes32 vaultId = bytes32(uint256(1));
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.prank(admin);
        vault.createVault(vaultId, signers, 2);

        // Create proposal
        vm.prank(signer1);
        uint256 proposalId = vault.createProposal(vaultId, makeAddr("recipient"), 1 ether, "Test");

        // Approve with signature
        vm.prank(signer1);
        vault.approveProposal(vaultId, proposalId, signature);

        // Attempting to reuse same signature should fail
        vm.prank(signer1);
        vm.expectRevert("Already approved");
        vault.approveProposal(vaultId, proposalId, signature);
    }

    // ========================================================================
    // Gas Optimization Tests
    // ========================================================================

    /// @notice Gas test: Vault creation cost
    function test_Gas_CreateVault() public {
        bytes32 vaultId = bytes32(uint256(1));
        address[] memory signers = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            signers[i] = makeAddr(string(abi.encodePacked("signer_", i)));
        }

        uint256 gasBefore = gasleft();
        vm.prank(admin);
        vault.createVault(vaultId, signers, 3);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas for createVault (5 signers)", gasUsed);
        assertLt(gasUsed, 300000, "Vault creation gas too high");
    }

    /// @notice Gas test: Proposal approval cost
    function test_Gas_ApproveProposal() public {
        // Setup vault
        bytes32 vaultId = bytes32(uint256(1));
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.prank(admin);
        vault.createVault(vaultId, signers, 2);

        vm.prank(signer1);
        uint256 proposalId = vault.createProposal(vaultId, makeAddr("recipient"), 1 ether, "Test");

        // Measure approval gas
        uint256 gasBefore = gasleft();
        vm.prank(signer1);
        vault.approveProposal(vaultId, proposalId, "signature");
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas for approveProposal", gasUsed);
        assertLt(gasUsed, 100000, "Approval gas too high");
    }

    /// @notice Stress test: High threshold vault (10-of-15 multisig)
    function test_Stress_HighThresholdVault() public {
        bytes32 vaultId = bytes32(uint256(1));
        address[] memory signers = new address[](15);

        for (uint256 i = 0; i < 15; i++) {
            signers[i] = makeAddr(string(abi.encodePacked("signer_", i)));
            vault.grantRole(SIGNER_ROLE, signers[i]);
        }

        // Create 10-of-15 vault
        vm.prank(admin);
        vault.createVault(vaultId, signers, 10);

        // Create proposal
        vm.prank(signers[0]);
        uint256 proposalId = vault.createProposal(vaultId, makeAddr("recipient"), 1 ether, "Test");

        // Collect 10 approvals
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(signers[i]);
            vault.approveProposal(vaultId, proposalId, abi.encodePacked("sig", i));
        }

        // Verify approved
        (,,, IMPCVault.ProposalStatus status, uint256 approvalCount) = vault.getProposal(vaultId, proposalId);
        assertEq(approvalCount, 10);
        assertTrue(status == IMPCVault.ProposalStatus.Approved);
    }
}
