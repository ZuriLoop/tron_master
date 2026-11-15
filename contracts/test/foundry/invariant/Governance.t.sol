// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest, TestPaymasterFactory} from "../Base.t.sol";
import {PermitAccount} from "../../../src/PermitAccount.sol";
import {IPaymasterFactory} from "../../../src/interfaces/IPaymasterFactory.sol";

/// @dev Drives random governance actions by admin, guardian and strangers.
contract GovHandler is Test {
    TestPaymasterFactory internal f;
    address internal admin;
    address internal guardian;
    address[] internal impls;

    // ghosts
    uint256 public lastQueuedEta; // eta of the account upgrade currently pending
    address public lastQueuedImpl;
    bool public implChangedEarly; // set if the implementation ever changed before its eta
    bool public pauseTooLong; // set if pausedUntil ever exceeded now + PAUSE_DURATION
    uint256 public guardianPauses;
    uint256 public pauses;
    uint256 public upgrades;
    uint256 public lastGuardianPauseAt;
    bool public guardianPausedInCooldown;

    constructor(TestPaymasterFactory f_, address admin_, address guardian_, address[] memory impls_) {
        f = f_;
        admin = admin_;
        guardian = guardian_;
        impls = impls_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        uint256 k = seed % 3;
        return k == 0 ? f.admin() : k == 1 ? f.guardian() : address(uint160(0xBEEF + seed % 7));
    }

    function queueUpgrade(uint256 who, uint256 implIdx) external {
        address impl = impls[implIdx % impls.length];
        vm.prank(_actor(who));
        try f.queueUpgrade(IPaymasterFactory.Kind.Account, impl) {
            lastQueuedEta = block.timestamp + f.UPGRADE_DELAY();
            lastQueuedImpl = impl;
        } catch {}
    }

    function cancelUpgrade(uint256 who) external {
        vm.prank(_actor(who));
        try f.cancelUpgrade(IPaymasterFactory.Kind.Account) {
            lastQueuedEta = 0;
        } catch {}
    }

    function executeUpgrade(uint256 who) external {
        address before = f.implementation(IPaymasterFactory.Kind.Account);
        vm.prank(_actor(who));
        try f.executeUpgrade(IPaymasterFactory.Kind.Account) {
            if (lastQueuedEta == 0 || block.timestamp < lastQueuedEta) implChangedEarly = true;
            lastQueuedEta = 0;
            upgrades++;
        } catch {}
        if (f.implementation(IPaymasterFactory.Kind.Account) != before && lastQueuedEta != 0) implChangedEarly = true;
    }

    function pause(uint256 who) external {
        address a = _actor(who);
        bool wasPaused = f.paused();
        vm.prank(a);
        try f.pause() {
            pauses++;
            if (a == f.guardian() && a != f.admin()) {
                if (wasPaused || (guardianPauses > 0 && block.timestamp < lastGuardianPauseAt + 2 * f.PAUSE_DURATION())) {
                    guardianPausedInCooldown = true;
                }
                guardianPauses++;
                lastGuardianPauseAt = block.timestamp;
            }
        } catch {}
        if (f.pausedUntil() > block.timestamp + f.PAUSE_DURATION()) pauseTooLong = true;
    }

    function unpause(uint256 who) external {
        vm.prank(_actor(who));
        try f.unpause() {} catch {}
    }

    function setFee(uint256 who, uint16 bps, uint128 cap) external {
        vm.prank(_actor(who));
        try f.setProtocolFee(bps, cap) {} catch {}
    }

    function queueRoles(uint256 who, uint256 seed) external {
        vm.prank(_actor(who));
        try f.queueRoles(address(uint160(0xA000 + seed % 3)), address(uint160(0xB000 + seed % 3))) {} catch {}
    }

    function executeRoles(uint256 seed) external {
        (address next,,) = f.pendingRoles();
        vm.prank(seed % 2 == 0 ? next : _actor(seed));
        try f.executeRoles() {} catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 3 days));
    }
}

/// forge-config: default.invariant.depth = 256
/// forge-config: default.invariant.runs = 128
contract GovernanceInvariantTest is BaseTest {
    GovHandler internal handler;
    uint16 internal maxBps;
    uint128 internal maxCap;
    address internal feeToken;
    address internal feeRecipientAtDeploy;
    address internal forwarderRouter;
    address internal accountRouter;

    function setUp() public override {
        super.setUp();
        address[] memory impls = new address[](2);
        impls[0] = address(new PermitAccount(address(factory), feeRecipient, address(usdt)));
        impls[1] = address(new PermitAccount(address(factory), feeRecipient, address(usdt)));
        handler = new GovHandler(factory, admin, guardian, impls);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](9);
        sel[0] = GovHandler.queueUpgrade.selector;
        sel[1] = GovHandler.cancelUpgrade.selector;
        sel[2] = GovHandler.executeUpgrade.selector;
        sel[3] = GovHandler.pause.selector;
        sel[4] = GovHandler.unpause.selector;
        sel[5] = GovHandler.setFee.selector;
        sel[6] = GovHandler.queueRoles.selector;
        sel[7] = GovHandler.executeRoles.selector;
        sel[8] = GovHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        maxBps = factory.MAX_BPS();
        maxCap = factory.MAX_CAP();
        feeToken = factory.FEE_TOKEN();
        feeRecipientAtDeploy = factory.FEE_RECIPIENT();
        forwarderRouter = factory.FORWARDER_ROUTER();
        accountRouter = factory.ACCOUNT_ROUTER();
    }

    /// I6: fee never exceeds the immutable maxima; immutables never change.
    function invariant_feeBoundedAndImmutablesFixed() public view {
        assertLe(factory.bps(), maxBps);
        assertLe(factory.cap(), maxCap);
        assertEq(factory.FEE_TOKEN(), feeToken);
        assertEq(factory.FEE_RECIPIENT(), feeRecipientAtDeploy);
        assertEq(factory.FORWARDER_ROUTER(), forwarderRouter);
        assertEq(factory.ACCOUNT_ROUTER(), accountRouter);
    }

    /// Upgrades only ever apply after their timelock.
    function invariant_noEarlyUpgrade() public view {
        assertFalse(handler.implChangedEarly());
    }

    /// A pause never extends beyond one PAUSE_DURATION from now.
    function invariant_pauseBounded() public view {
        assertFalse(handler.pauseTooLong());
        assertLe(factory.pausedUntil(), block.timestamp + factory.PAUSE_DURATION());
    }

    /// The guardian alone cannot pause back-to-back.
    function invariant_guardianCooldown() public view {
        assertFalse(handler.guardianPausedInCooldown());
    }

    function afterInvariant() external view {
        assertGt(handler.pauses(), 0, "no pause happened in this run");
    }

    /// Admin and guardian are never the zero address.
    function invariant_rolesNonZero() public view {
        assertTrue(factory.admin() != address(0));
        assertTrue(factory.guardian() != address(0));
    }
}
