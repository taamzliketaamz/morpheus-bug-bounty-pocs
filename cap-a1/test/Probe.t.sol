// SPDX-License-Identifier: MIT
// Minimal probe: fork, pin prices, warp to gate, distribute, log per-pool deltas.
// No stakes, no donations - isolates whether the W1 yield-split anomaly is
// inherent to fork state / deployed code or caused by the CapA1 test setup.
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
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

contract ProbeTest is Test {
    uint256 constant FORK_BLOCK = 26424044;
    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant WBTC_POOL = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address constant WETH_POOL = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address constant USDC_POOL = 0x6cCE082851Add4c535352f596662521B4De4750E;
    address constant USDT_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;

    IDistributor dist = IDistributor(DIST);

    function test_Probe_W1_NoStakes() public {
        vm.createSelectFork("https://eth.drpc.org", FORK_BLOCK);
        address consumer_ = dist.chainLinkDataConsumer();
        address[5] memory pools_ = [STETH_POOL, WBTC_POOL, WETH_POOL, USDC_POOL, USDT_POOL];
        for (uint256 i = 0; i < pools_.length; i++) {
            (, string memory path_,,,,,, bool isExist_) = dist.depositPools(0, pools_[i]);
            if (!isExist_) continue;
            bytes32 pid_ = IPriceConsumer(consumer_).getPathId(path_);
            uint256 px_ = IPriceConsumer(consumer_).getChainLinkDataFeedLatestAnswer(pid_);
            console.log("captured price", i);
            console.log("price:", px_);
            vm.mockCall(
                consumer_,
                abi.encodeWithSelector(IPriceConsumer.getChainLinkDataFeedLatestAnswer.selector, pid_),
                abi.encode(px_)
            );
        }
        uint128 lastCalc_ = dist.rewardPoolLastCalculatedTimestamp(0);
        uint256 gate1_ = uint256(lastCalc_) + dist.minRewardsDistributePeriod();
        uint256[5] memory before_;
        for (uint256 i = 0; i < 5; i++) before_[i] = dist.distributedRewards(0, pools_[i]);
        // log inputs
        for (uint256 i = 0; i < 5; i++) {
            (address token_,, uint256 price_,, uint256 lub_, uint8 strat_, address aToken_,) =
                dist.depositPools(0, pools_[i]);
            address yt_ = strat_ == 2 ? aToken_ : token_;
            console.log("pool", i);
            console.log("bal:", IERC20(yt_).balanceOf(DIST));
            console.log("lub:", lub_);
            console.log("stored price:", price_);
        }
        vm.warp(gate1_ + 1);
        dist.distributeRewards(0);
        uint256 total_;
        for (uint256 i = 0; i < 5; i++) {
            uint256 d_ = dist.distributedRewards(0, pools_[i]) - before_[i];
            total_ += d_;
            console.log("delta", i);
            console.log("delta MOR wei:", d_);
        }
        console.log("total tranche MOR wei:", total_);
    }
}
