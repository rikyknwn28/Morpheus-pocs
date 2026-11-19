// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IL2MRFork {
    function lzReceive(uint16 senderChainId_, bytes memory senderAndReceiverAddresses_, uint64 nonce_, bytes memory payload_) external;
    function retryMessage(uint16 senderChainId_, bytes memory senderAndReceiverAddresses_, uint64 nonce_, bytes memory payload_) external;
    function failedMessages(uint16, bytes memory, uint64) external view returns (bytes32);
    function rewardToken() external view returns (address);
}

interface IERC20Fork {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Fork PoC against the LIVE L2MessageReceiver on Arbitrum One.
/// Same defect as the etched PoC, but executed against the real deployed
/// proxy (0xd4a8ECcBe696295e68572A98b1aA70Aa9277d427) at a pinned block, with
/// the real MOR token and the real on-chain config. No repo source is used.
/// The LZ endpoint (gateway) is pranked, exactly as the etched test does:
/// the endpoint is the only caller of lzReceive, and it delivers the
/// 40-byte path L1SenderV2 passed to Endpoint.send(), i.e.
/// abi.encodePacked(receiver, sender).
contract L2MessageReceiverForkTest is Test {
    address constant L2MR = 0xd4a8ECcBe696295e68572A98b1aA70Aa9277d427;
    address constant L1_SENDER = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;
    address constant GATEWAY = 0x3c2269811836af69497E5F486A85D7316753cf62; // LZ Endpoint V1, Arbitrum
    uint16 constant SRC_CHAIN_ID = 101; // Ethereum
    uint256 constant FORK_BLOCK = 525696000; // Arbitrum One, 2026-11-20

    function setUp() public {
        vm.createSelectFork("https://arbitrum.publicnode.com", FORK_BLOCK);
    }

    function test_fork_realPathFailsNoMint() public {
        address user = address(0xBEEF);
        uint256 amount = 1000 ether;
        bytes memory path = abi.encodePacked(L2MR, L1_SENDER);
        bytes memory payload = abi.encode(user, amount);
        uint64 nonce = 424242;

        address mor = IL2MRFork(L2MR).rewardToken();
        uint256 beforeBal = IERC20Fork(mor).balanceOf(user);

        vm.prank(GATEWAY);
        IL2MRFork(L2MR).lzReceive(SRC_CHAIN_ID, path, nonce, payload);

        assertEq(IERC20Fork(mor).balanceOf(user), beforeBal, "no MOR minted on real path");
        assertEq(IL2MRFork(L2MR).failedMessages(SRC_CHAIN_ID, path, nonce), keccak256(payload), "message stored as failed");
    }

    function test_fork_retryAlwaysReverts() public {
        address user = address(0xBEEF);
        bytes memory path = abi.encodePacked(L2MR, L1_SENDER);
        bytes memory payload = abi.encode(user, 1000 ether);
        uint64 nonce = 424243;

        vm.prank(GATEWAY);
        IL2MRFork(L2MR).lzReceive(SRC_CHAIN_ID, path, nonce, payload);

        vm.expectRevert();
        IL2MRFork(L2MR).retryMessage(SRC_CHAIN_ID, path, nonce, payload);
        assertTrue(IL2MRFork(L2MR).failedMessages(SRC_CHAIN_ID, path, nonce) != bytes32(0), "still stored");
    }

    function test_fork_reversedPathMints() public {
        address user = address(0xBEEF);
        uint256 amount = 1000 ether;
        bytes memory reversedPath = abi.encodePacked(L1_SENDER, L2MR);
        bytes memory payload = abi.encode(user, amount);
        uint64 nonce = 424244;

        address mor = IL2MRFork(L2MR).rewardToken();
        uint256 beforeBal = IERC20Fork(mor).balanceOf(user);

        vm.prank(GATEWAY);
        IL2MRFork(L2MR).lzReceive(SRC_CHAIN_ID, reversedPath, nonce, payload);

        assertEq(IERC20Fork(mor).balanceOf(user), beforeBal + amount, "reversed path mints: defect is only the extraction");
        assertEq(IL2MRFork(L2MR).failedMessages(SRC_CHAIN_ID, reversedPath, nonce), bytes32(0));
    }
}
