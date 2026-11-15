// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {BaseTest} from "../Base.t.sol";
import {PermitAccount} from "../../../src/PermitAccount.sol";
import {IPermitAccount, Permit} from "../../../src/interfaces/IPermitAccount.sol";

contract PermitFuzzTest is BaseTest {
    PermitAccount internal account;

    function setUp() public override {
        super.setUp();
        account = _account();
        usdt.mint(address(account), 1_000_000_000);
    }

    /// Any change to any signed field invalidates the signature (or fails an earlier check).
    function testFuzz_tamperedFieldRejected(uint8 field, uint256 delta, address other) public {
        field = uint8(bound(field, 0, 7));
        delta = bound(delta, 1, 1e9);
        Permit memory p = _permit(address(account), alice, 1_000_000, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        vm.assume(other != p.token && other != p.owner && other != p.to && other != p.relayer && other != address(0));
        vm.assume(other != address(account));

        if (field == 0) p.token = other;
        else if (field == 1) p.owner = other;
        else if (field == 2) p.to = other;
        else if (field == 3) p.value += delta;
        else if (field == 4) p.maxFee += delta;
        else if (field == 5) p.relayer = other;
        else if (field == 6) p.deadline += delta;
        else p.nonce += delta;

        address feeTo = field == 5 ? other : relayer;
        vm.expectRevert();
        account.permitTransfer(p, 0, feeTo, r, vs);
        assertEq(account.nonce(), 0);
        assertEq(usdt.balanceOf(alice), 0);
    }

    /// The recipient receives exactly value; fees are bounded by maxFee and accrue, never leave.
    function testFuzz_feesBounded(uint256 value, uint256 relayerFee, uint256 maxFee) public {
        value = bound(value, 1, 100_000_000);
        relayerFee = bound(relayerFee, 0, 100_000_000);
        maxFee = bound(maxFee, 0, 300_000_000);
        uint256 proto = factory.protocolFee(address(usdt), value);
        Permit memory p = _permit(address(account), alice, value, maxFee);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        uint256 before = usdt.balanceOf(address(account));

        if (relayerFee + proto > maxFee) {
            vm.expectRevert(IPermitAccount.FeeExceedsMax.selector);
            account.permitTransfer(p, relayerFee, relayer, r, vs);
            return;
        }
        account.permitTransfer(p, relayerFee, relayer, r, vs);
        assertEq(usdt.balanceOf(alice), value);
        assertEq(before - usdt.balanceOf(address(account)), value, "only value leaves");
        assertEq(account.totalOwed(address(usdt)), relayerFee + proto);
        assertLe(relayerFee + proto, maxFee);
    }

    /// I3: the owner can always withdraw exactly `available`, never more.
    function testFuzz_withdrawBounds(uint256 relayerFee, uint256 extra) public {
        relayerFee = bound(relayerFee, 0, 500_000_000);
        Permit memory p = _permit(address(account), alice, 1, relayerFee + factory.protocolFee(address(usdt), 1));
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        account.permitTransfer(p, relayerFee, relayer, r, vs);

        uint256 avail = account.available(address(usdt));
        extra = bound(extra, 1, 1e18);
        vm.startPrank(owner);
        vm.expectRevert(IPermitAccount.InsufficientAvailable.selector);
        account.withdraw(address(usdt), owner, avail + extra);
        account.withdraw(address(usdt), owner, avail);
        vm.stopPrank();
        assertEq(usdt.balanceOf(address(account)), account.totalOwed(address(usdt)));
    }

    /// Deadline: valid through block.timestamp == deadline, invalid after.
    function testFuzz_deadline(uint256 ttl, uint256 wait) public {
        ttl = bound(ttl, 0, 365 days);
        wait = bound(wait, 0, 400 days);
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        p.deadline = block.timestamp + ttl;
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        vm.warp(block.timestamp + wait);
        if (wait > ttl) vm.expectRevert(IPermitAccount.Expired.selector);
        account.permitTransfer(p, 0, relayer, r, vs);
    }

    /// Only the beneficiary (or the factory acting for msg.sender) can claim an accrual.
    function testFuzz_claimOnlyOwn(address caller, address beneficiary) public {
        vm.assume(caller != address(factory) && caller != beneficiary);
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        account.permitTransfer(p, 500, relayer, r, vs);
        vm.prank(caller);
        vm.expectRevert(IPermitAccount.NotAuthorized.selector);
        account.claimFees(address(usdt), beneficiary, caller);
    }

    /// Signatures from any key other than the configured signer fail.
    function testFuzz_wrongKey(uint256 key) public {
        key = bound(key, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        vm.assume(key != ownerKey);
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(key, address(account), p);
        vm.expectRevert(IPermitAccount.BadSignature.selector);
        account.permitTransfer(p, 0, relayer, r, vs);
    }

    /// Cross-chain replay: a signature for one chain id fails on another.
    function testFuzz_crossChainReplay(uint64 otherChain) public {
        vm.assume(uint256(otherChain) & 0xffffffff != block.chainid & 0xffffffff);
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        vm.chainId(otherChain);
        vm.expectRevert(IPermitAccount.BadSignature.selector);
        account.permitTransfer(p, 0, relayer, r, vs);
    }
}
