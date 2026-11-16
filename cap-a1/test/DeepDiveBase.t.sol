// SPDX-License-Identifier: MIT
// CAP-A1 deep-dive (2026-11-16), task 4 (Base side): does a MOR donation to
// BuildersV4 or BuildersTreasuryV2 change any rate / accounting?
// Fork: Base mainnet block 58011568, RPC https://mainnet.base.org.
// Local fork only. No privileged accounts. Nothing is submitted anywhere.
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IBuildersV4 {
    function getCurrentSubnetsRewards() external view returns (uint256);
    function buildersTreasury() external view returns (address);
}

interface IBuildersTreasuryV2 {
    function distributedRewards() external view returns (uint256);
    function rewardToken() external view returns (address);
}

contract DeepDiveBaseTest is Test {
    uint256 constant FORK_BLOCK = 58011568;
    string constant RPC_URL = "https://mainnet.base.org";

    address constant BUILDERS_V4 = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant TREASURY_V2 = 0x9eba628581896ce086cb8f1A513ea6097A8FC561;
    address constant MOR_BASE = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    address attacker = makeAddr("deepBaseAttacker");

    function test_BuildersV4_MorDonation_NoEffect() public {
        vm.createSelectFork(RPC_URL, FORK_BLOCK);
        IBuildersV4 builders = IBuildersV4(BUILDERS_V4);
        uint256 rewardsBefore_ = builders.getCurrentSubnetsRewards();
        console.log("getCurrentSubnetsRewards before donation:", rewardsBefore_);

        deal(MOR_BASE, attacker, 10000 ether);
        vm.startPrank(attacker);
        IERC20(MOR_BASE).transfer(BUILDERS_V4, 10000 ether);
        vm.stopPrank();

        uint256 rewardsAfter_ = builders.getCurrentSubnetsRewards();
        console.log("getCurrentSubnetsRewards after 10k MOR donation:", rewardsAfter_);
        assertEq(rewardsAfter_, rewardsBefore_, "MOR donation to BuildersV4 must not change the rate");
        assertGe(IERC20(MOR_BASE).balanceOf(BUILDERS_V4), 10000 ether, "donation must sit in BuildersV4");
    }

    function test_BuildersTreasury_MorDonation_NoEffect() public {
        vm.createSelectFork(RPC_URL, FORK_BLOCK);
        IBuildersTreasuryV2 treasury = IBuildersTreasuryV2(TREASURY_V2);
        uint256 distBefore_ = treasury.distributedRewards();
        console.log("treasury distributedRewards before donation:", distBefore_);

        deal(MOR_BASE, attacker, 10000 ether);
        vm.startPrank(attacker);
        IERC20(MOR_BASE).transfer(TREASURY_V2, 10000 ether);
        vm.stopPrank();

        uint256 distAfter_ = treasury.distributedRewards();
        console.log("treasury distributedRewards after 10k MOR donation:", distAfter_);
        assertEq(distAfter_, distBefore_, "MOR donation to the treasury must not change accounting");
        assertGe(IERC20(MOR_BASE).balanceOf(TREASURY_V2), 10000 ether, "donation must sit in the treasury");
    }
}
