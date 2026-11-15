// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {BaseTest} from "../Base.t.sol";
import {PaymasterFactory} from "../../../src/PaymasterFactory.sol";
import {PermitAccount} from "../../../src/PermitAccount.sol";
import {DepositForwarder} from "../../../src/DepositForwarder.sol";
import {IPaymasterFactory} from "../../../src/interfaces/IPaymasterFactory.sol";
import {Permit} from "../../../src/interfaces/IPermitAccount.sol";
import {TestPaymasterFactory} from "../Base.t.sol";

contract PermitAccountV2 is PermitAccount {
    constructor(address f, address r, address t) PermitAccount(f, r, t) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract ForeignImpl {
    address public FACTORY = address(0xdead);
}

contract GovernanceTest is BaseTest {
    IPaymasterFactory.Kind internal constant ACCOUNT = IPaymasterFactory.Kind.Account;
    IPaymasterFactory.Kind internal constant FORWARDER = IPaymasterFactory.Kind.Forwarder;

    function _v2() internal returns (address) {
        return address(new PermitAccountV2(address(factory), feeRecipient, address(usdt)));
    }

    // ----------------------------------------------------------- constructor

    function test_constructorValidation() public {
        PaymasterFactory.Config memory c = _config(address(usdt));

        c.admin = address(0);
        vm.expectRevert(IPaymasterFactory.InvalidConfig.selector);
        new TestPaymasterFactory(c);

        c = _config(address(usdt));
        c.upgradeDelay = 2 days - 1;
        vm.expectRevert(IPaymasterFactory.InvalidConfig.selector);
        new TestPaymasterFactory(c);

        c = _config(address(usdt));
        c.pauseDuration = 15 days;
        vm.expectRevert(IPaymasterFactory.InvalidConfig.selector);
        new TestPaymasterFactory(c);

        c = _config(address(usdt));
        c.bps = MAX_BPS + 1;
        vm.expectRevert(IPaymasterFactory.InvalidConfig.selector);
        new TestPaymasterFactory(c);

        c = _config(address(usdt));
        c.feeRecipient = address(0);
        vm.expectRevert(IPaymasterFactory.InvalidConfig.selector);
        new TestPaymasterFactory(c);

        c = _config(address(0)); // fee token missing while fees enabled
        vm.expectRevert(IPaymasterFactory.InvalidConfig.selector);
        new TestPaymasterFactory(c);

        // Fee-free factory is valid.
        c = _config(address(0));
        c.maxBps = 0;
        c.maxCap = 0;
        c.bps = 0;
        c.cap = 0;
        c.feeRecipient = address(0);
        TestPaymasterFactory free = new TestPaymasterFactory(c);
        assertEq(free.protocolFee(address(usdt), 1e12), 0);
    }

    // -------------------------------------------------------------- upgrades

    function test_upgradeTimelock() public {
        PermitAccount acct = _account();
        address v2 = _v2();

        vm.prank(stranger);
        vm.expectRevert(IPaymasterFactory.NotAdmin.selector);
        factory.queueUpgrade(ACCOUNT, v2);

        vm.prank(admin);
        factory.queueUpgrade(ACCOUNT, v2);
        (address pending, uint256 eta) = factory.pendingUpgrade(ACCOUNT);
        assertEq(pending, v2);
        assertEq(eta, block.timestamp + DELAY);

        vm.expectRevert(IPaymasterFactory.TooEarly.selector);
        factory.executeUpgrade(ACCOUNT);

        vm.warp(eta);
        vm.prank(stranger); // anyone may execute
        factory.executeUpgrade(ACCOUNT);
        assertEq(factory.implementation(ACCOUNT), v2);
        assertEq(PermitAccountV2(payable(address(acct))).version(), 2);
    }

    function test_upgradePreservesAddressAndState() public {
        PermitAccount acct = _account();
        usdt.mint(address(acct), 10_000_000);
        Permit memory p = _permit(address(acct), alice, 1_000_000, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(acct), p);
        acct.permitTransfer(p, 123, relayer, r, vs);
        vm.prank(owner);
        acct.setSigner(address(0xB0B));

        address v2 = _v2();
        vm.prank(admin);
        factory.queueUpgrade(ACCOUNT, v2);
        vm.warp(block.timestamp + DELAY);
        factory.executeUpgrade(ACCOUNT);

        assertEq(factory.predictAccount(owner, 0), address(acct));
        assertEq(acct.owner(), owner);
        assertEq(acct.nonce(), 1);
        assertEq(acct.signer(), address(0xB0B));
        assertEq(acct.feeOwed(address(usdt), relayer), 123);
    }

    function test_ownerCanExitDuringUpgradeWindow() public {
        PermitAccount acct = _account();
        usdt.mint(address(acct), 10_000_000);
        address v2 = _v2();
        vm.prank(admin);
        factory.queueUpgrade(ACCOUNT, v2);
        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(owner);
        acct.withdraw(address(usdt), owner, 10_000_000);
        assertEq(usdt.balanceOf(owner), 10_000_000);
    }

    function test_guardianVeto() public {
        address v2 = _v2();
        vm.prank(admin);
        factory.queueUpgrade(ACCOUNT, v2);

        vm.prank(stranger);
        vm.expectRevert(IPaymasterFactory.NotAuthorized.selector);
        factory.cancelUpgrade(ACCOUNT);

        vm.prank(guardian);
        factory.cancelUpgrade(ACCOUNT);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(IPaymasterFactory.NothingQueued.selector);
        factory.executeUpgrade(ACCOUNT);
    }

    function test_upgradeLapses() public {
        address v2 = _v2();
        vm.prank(admin);
        factory.queueUpgrade(ACCOUNT, v2);
        vm.warp(block.timestamp + DELAY + factory.EXECUTION_WINDOW() + 1);
        vm.expectRevert(IPaymasterFactory.TooLate.selector);
        factory.executeUpgrade(ACCOUNT);
    }

    function test_requeueRestartsDelay() public {
        address v2 = _v2();
        vm.startPrank(admin);
        factory.queueUpgrade(ACCOUNT, v2);
        vm.warp(block.timestamp + DELAY - 1);
        factory.queueUpgrade(ACCOUNT, v2);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        vm.expectRevert(IPaymasterFactory.TooEarly.selector);
        factory.executeUpgrade(ACCOUNT);
    }

    function test_rejectsForeignOrEmptyImplementation() public {
        vm.startPrank(admin);
        vm.expectRevert(IPaymasterFactory.InvalidImplementation.selector);
        factory.queueUpgrade(ACCOUNT, address(0x1234));
        address foreign = address(new ForeignImpl());
        vm.expectRevert(IPaymasterFactory.InvalidImplementation.selector);
        factory.queueUpgrade(ACCOUNT, foreign);
        vm.expectRevert(IPaymasterFactory.InvalidImplementation.selector);
        factory.queueUpgrade(FORWARDER, address(usdt)); // has code, no FACTORY()
        vm.stopPrank();
    }

    function test_forwarderUpgradeKeepsAddress() public {
        bytes32 salt = keccak256("x");
        address f = factory.deployForwarder(treasury, address(0), salt);
        address v2 = address(new DepositForwarder(address(factory)));
        vm.prank(admin);
        factory.queueUpgrade(FORWARDER, v2);
        vm.warp(block.timestamp + DELAY);
        factory.executeUpgrade(FORWARDER);
        assertEq(factory.predictForwarder(treasury, address(0), salt), f);
        usdt.mint(f, 9);
        DepositForwarder(payable(f)).sweep(address(usdt));
        assertEq(usdt.balanceOf(treasury), 9);
    }

    // ----------------------------------------------------------------- roles

    function test_rolesTimelockAndAcceptance() public {
        address newAdmin = makeAddr("newAdmin");
        address newGuardian = makeAddr("newGuardian");

        vm.prank(admin);
        factory.queueRoles(newAdmin, newGuardian);

        vm.prank(guardian);
        vm.expectRevert(IPaymasterFactory.NotAdmin.selector);
        factory.cancelRoles(); // guardian cannot block its own replacement

        vm.warp(block.timestamp + DELAY);
        vm.prank(admin);
        vm.expectRevert(IPaymasterFactory.NotAdmin.selector);
        factory.executeRoles(); // only the incoming admin

        vm.prank(newAdmin);
        factory.executeRoles();
        assertEq(factory.admin(), newAdmin);
        assertEq(factory.guardian(), newGuardian);
    }

    function test_rolesEarlyAndCancel() public {
        vm.prank(admin);
        factory.queueRoles(stranger, stranger);
        vm.prank(stranger);
        vm.expectRevert(IPaymasterFactory.TooEarly.selector);
        factory.executeRoles();
        vm.prank(admin);
        factory.cancelRoles();
        vm.warp(block.timestamp + DELAY);
        vm.prank(stranger);
        vm.expectRevert(IPaymasterFactory.NothingQueued.selector);
        factory.executeRoles();
    }

    // ----------------------------------------------------------------- pause

    function test_pauseExpires() public {
        vm.prank(guardian);
        factory.pause();
        assertTrue(factory.paused());
        vm.warp(block.timestamp + PAUSE - 1);
        assertTrue(factory.paused());
        vm.warp(block.timestamp + 1);
        assertFalse(factory.paused());
    }

    function test_guardianCannotPausePerpetually() public {
        vm.startPrank(guardian);
        factory.pause();
        vm.expectRevert(IPaymasterFactory.AlreadyPaused.selector);
        factory.pause();
        vm.warp(block.timestamp + PAUSE); // expired
        vm.expectRevert(IPaymasterFactory.PauseCooldown.selector);
        factory.pause();
        vm.warp(block.timestamp + PAUSE); // cooldown over
        factory.pause();
        vm.stopPrank();
    }

    function test_adminCanRepauseAndUnpause() public {
        vm.startPrank(admin);
        factory.pause();
        factory.pause();
        factory.unpause();
        vm.stopPrank();
        assertFalse(factory.paused());

        vm.prank(stranger);
        vm.expectRevert(IPaymasterFactory.NotAuthorized.selector);
        factory.pause();
    }

    function test_guardianCannotUnpauseAdminPause() public {
        vm.prank(admin);
        factory.pause();
        assertTrue(factory.adminPaused());
        vm.prank(guardian);
        vm.expectRevert(IPaymasterFactory.NotAuthorized.selector);
        factory.unpause();
        // The admin still can, and the flag clears.
        vm.prank(admin);
        factory.unpause();
        assertFalse(factory.adminPaused());
    }

    function test_guardianCanUnpauseItsOwnPause() public {
        vm.prank(guardian);
        factory.pause();
        assertFalse(factory.adminPaused());
        vm.prank(guardian);
        factory.unpause();
        assertFalse(factory.paused());
    }

    function test_adminPauseFlagDoesNotOutliveItsPause() public {
        // Admin pause expires on its own; a later guardian pause must remain
        // unpausable by the guardian.
        vm.prank(admin);
        factory.pause();
        vm.warp(block.timestamp + PAUSE);
        assertFalse(factory.paused());
        vm.prank(guardian);
        factory.pause();
        vm.prank(guardian);
        factory.unpause();
        assertFalse(factory.paused());
    }

    function test_queueUpgradeRejectsWrongKind() public {
        address accountImpl = _v2(); // KIND() == Account
        vm.prank(admin);
        vm.expectRevert(IPaymasterFactory.InvalidImplementation.selector);
        factory.queueUpgrade(FORWARDER, accountImpl);

        // A router has FACTORY() but no KIND(): rejected instead of looping forever.
        address router = factory.ACCOUNT_ROUTER();
        vm.prank(admin);
        vm.expectRevert(IPaymasterFactory.InvalidImplementation.selector);
        factory.queueUpgrade(ACCOUNT, router);
    }

    function test_executeUpgradeRejectsDestroyedImplementation() public {
        address impl = _v2();
        vm.prank(admin);
        factory.queueUpgrade(ACCOUNT, impl);
        vm.etch(impl, ""); // code destroyed during the delay
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(IPaymasterFactory.InvalidImplementation.selector);
        factory.executeUpgrade(ACCOUNT);
    }

    // ------------------------------------------------------------------ fees

    function test_feeBounds() public {
        vm.startPrank(admin);
        vm.expectRevert(IPaymasterFactory.FeeAboveMax.selector);
        factory.setProtocolFee(MAX_BPS + 1, CAP);
        vm.expectRevert(IPaymasterFactory.FeeAboveMax.selector);
        factory.setProtocolFee(BPS, MAX_CAP + 1);
        factory.setProtocolFee(MAX_BPS, MAX_CAP);
        factory.setProtocolFee(0, 0);
        vm.stopPrank();
        assertEq(factory.protocolFee(address(usdt), 1e12), 0);

        vm.prank(stranger);
        vm.expectRevert(IPaymasterFactory.NotAdmin.selector);
        factory.setProtocolFee(0, 0);
    }

    function testFuzz_protocolFeeBounded(uint256 value, uint16 b, uint128 c, address token) public {
        b = uint16(bound(b, 0, MAX_BPS));
        c = uint128(bound(c, 0, MAX_CAP));
        value = bound(value, 0, type(uint128).max);
        vm.prank(admin);
        factory.setProtocolFee(b, c);
        uint256 fee = factory.protocolFee(token, value);
        if (token != address(usdt)) assertEq(fee, 0);
        assertLe(fee, c);
        assertLe(fee, value * b / 10_000);
    }

    /// @dev A raised fee can never exceed what a signed permit allows.
    function test_feeRaiseBoundedBySignedMaxFee() public {
        PermitAccount acct = _account();
        usdt.mint(address(acct), 10_000_000);
        Permit memory p = _permit(address(acct), alice, 10_000_000 / 2, 10_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(acct), p);
        vm.prank(admin);
        factory.setProtocolFee(MAX_BPS, MAX_CAP); // 0.5% of 5 USDT = 25_000 > 10_000
        vm.expectRevert();
        acct.permitTransfer(p, 0, relayer, r, vs);
    }
}
