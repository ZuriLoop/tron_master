// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {BaseTest} from "../Base.t.sol";
import {stdError} from "forge-std/Test.sol";
import {PermitAccount} from "../../../src/PermitAccount.sol";
import {ImplementationRouter} from "../../../src/ImplementationRouter.sol";
import {IPaymasterFactory} from "../../../src/interfaces/IPaymasterFactory.sol";
import {IPermitAccount, Permit} from "../../../src/interfaces/IPermitAccount.sol";
import {ECDSA} from "@openzeppelin/tron-contracts/utils/cryptography/ECDSA.sol";
import {MockReentrantToken} from "../mocks/Tokens.sol";

contract PermitAccountTest is BaseTest {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    PermitAccount internal account;

    function setUp() public override {
        super.setUp();
        account = _account();
        usdt.mint(address(account), 100_000_000); // 100 USDT
    }

    function _submit(Permit memory p, uint256 relayerFee) internal {
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        vm.prank(relayer);
        account.permitTransfer(p, relayerFee, relayer, r, vs);
    }

    // -------------------------------------------------------------- basics

    function test_predictMatchesDeploy() public view {
        assertEq(factory.predictAccount(owner, 0), address(account));
        assertEq(account.owner(), owner);
        assertEq(account.signer(), owner);
        assertTrue(factory.predictAccount(owner, 1) != address(account));
    }

    function test_digestMatchesSpec() public view {
        Permit memory p = _permit(address(account), alice, 1, 1);
        assertEq(account.hashPermit(p), _specDigest(address(account), p));
    }

    function test_permitTransfer_creditsFeesLazily() public {
        uint256 value = 10_000_000; // 10 USDT -> protocol fee 0.1% = 10_000
        uint256 protocolFee = factory.protocolFee(address(usdt), value);
        assertEq(protocolFee, 10_000);
        Permit memory p = _permit(address(account), alice, value, 600_000);
        _submit(p, 500_000);

        assertEq(usdt.balanceOf(alice), value, "recipient gets exactly value");
        assertEq(account.nonce(), 1);
        assertEq(account.feeOwed(address(usdt), relayer), 500_000);
        assertEq(account.protocolOwed(address(usdt)), protocolFee);
        assertEq(account.totalOwed(address(usdt)), 500_000 + protocolFee);
        assertEq(account.available(address(usdt)), 100_000_000 - value - 500_000 - protocolFee);
    }

    function test_protocolFeeCapped() public {
        uint256 value = 90_000_000; // 0.1% = 90_000 < cap; raise bps to hit cap
        vm.prank(admin);
        factory.setProtocolFee(MAX_BPS, CAP);
        assertEq(factory.protocolFee(address(usdt), value), CAP);
    }

    function test_replayFails() public {
        Permit memory p = _permit(address(account), alice, 1_000_000, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        account.permitTransfer(p, 0, relayer, r, vs);
        vm.expectRevert(IPermitAccount.BadNonce.selector);
        account.permitTransfer(p, 0, relayer, r, vs);
    }

    function test_expired() public {
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        vm.warp(p.deadline + 1);
        vm.expectRevert(IPermitAccount.Expired.selector);
        account.permitTransfer(p, 0, relayer, r, vs);
    }

    function test_relayerBinding() public {
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        // A front-runner cannot redirect the fee.
        vm.prank(stranger);
        vm.expectRevert(IPermitAccount.RelayerMismatch.selector);
        account.permitTransfer(p, 1, stranger, r, vs);
        // Anyone may still submit with the bound recipient; the fee goes to the relayer.
        vm.prank(stranger);
        account.permitTransfer(p, 1, relayer, r, vs);
        assertEq(account.feeOwed(address(usdt), relayer), 1);
    }

    function test_unboundRelayer() public {
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        p.relayer = address(0);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        account.permitTransfer(p, 5, stranger, r, vs);
        assertEq(account.feeOwed(address(usdt), stranger), 5);
    }

    function test_feeRecipientRequiredWhenFeeCharged() public {
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        p.relayer = address(0);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        vm.expectRevert(IPermitAccount.InvalidRecipient.selector);
        account.permitTransfer(p, 5, address(0), r, vs);
    }

    function test_feeExceedsMax() public {
        Permit memory p = _permit(address(account), alice, 10_000_000, 500_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        // relayer 495_000 + protocol 10_000 > 500_000
        vm.expectRevert(IPermitAccount.FeeExceedsMax.selector);
        account.permitTransfer(p, 495_000, relayer, r, vs);
    }

    function test_badSignature_wrongKey() public {
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(0xBAD, address(account), p);
        vm.expectRevert(IPermitAccount.BadSignature.selector);
        account.permitTransfer(p, 0, relayer, r, vs);
    }

    function test_badSignature_tamperedField() public {
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        p.to = stranger;
        vm.expectRevert(IPermitAccount.BadSignature.selector);
        account.permitTransfer(p, 0, relayer, r, vs);
    }

    function test_highSRejected() public {
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, account.hashPermit(p));
        uint256 highS = SECP256K1_N - uint256(s);
        // The malleable twin (n - s, flipped v). In the 64-byte form bit 255 is
        // the parity bit, so the twin either fails OZ's low-s check or recovers
        // a different address; both must revert.
        bytes32 vs = bytes32(highS | (uint256(v == 27 ? 1 : 0) << 255));
        vm.expectRevert();
        account.permitTransfer(p, 0, relayer, r, vs);
        // And the full-width (r, s, v) twin is rejected by ECDSA directly.
        bytes32 digest = account.hashPermit(p);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, bytes32(highS)));
        this.recoverFull(digest, v == 27 ? 28 : 27, r, bytes32(highS));
    }

    function recoverFull(bytes32 h, uint8 v, bytes32 r, bytes32 s) external pure returns (address) {
        return ECDSA.recover(h, v, r, s);
    }

    function test_crossAccountReplay() public {
        PermitAccount other = PermitAccount(payable(factory.deployAccount(owner, 1)));
        usdt.mint(address(other), 10_000_000);
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        vm.expectRevert(IPermitAccount.BadSignature.selector);
        other.permitTransfer(p, 0, relayer, r, vs);
    }

    function test_badOwner() public {
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        p.owner = alice;
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        vm.expectRevert(IPermitAccount.BadOwner.selector);
        account.permitTransfer(p, 0, relayer, r, vs);
    }

    function test_invalidRecipients() public {
        Permit memory p = _permit(address(account), address(account), 1, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        vm.expectRevert(IPermitAccount.InvalidRecipient.selector);
        account.permitTransfer(p, 0, relayer, r, vs);

        p = _permit(address(account), alice, 0, 1_000_000);
        (r, vs) = _sign(ownerKey, address(account), p);
        vm.expectRevert(IPermitAccount.ZeroValue.selector);
        account.permitTransfer(p, 0, relayer, r, vs);
    }

    function test_cannotSpendAccruedFees() public {
        // Accrue 1 USDT of relayer fees, then try to send everything else plus 1.
        Permit memory p = _permit(address(account), alice, 1_000_000, 2_000_000);
        _submit(p, 1_000_000);
        uint256 avail = account.available(address(usdt));
        uint256 fee = factory.protocolFee(address(usdt), avail);
        // Spending everything available would leave this permit's own fee unbacked.
        p = _permit(address(account), alice, avail, fee);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        vm.expectRevert(IPermitAccount.InsufficientAvailable.selector);
        account.permitTransfer(p, 0, relayer, r, vs);
        // Leaving room for it succeeds and drains `available` to (near) zero.
        p = _permit(address(account), alice, avail - fee, fee);
        _submit(p, 0);
        assertLe(account.available(address(usdt)), fee);
        assertGe(usdt.balanceOf(address(account)), account.totalOwed(address(usdt)));
        assertEq(account.feeOwed(address(usdt), relayer), 1_000_000, "accrued fees untouched");
    }

    function test_overspendReverts() public {
        uint256 bal = usdt.balanceOf(address(account));
        Permit memory p = _permit(address(account), alice, bal, CAP);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        // Transfer of the whole balance leaves the protocol fee unbacked.
        vm.expectRevert(IPermitAccount.InsufficientAvailable.selector);
        account.permitTransfer(p, 0, relayer, r, vs);
    }

    // ---------------------------------------------------------- signer / nonce

    function test_signerRotation() public {
        uint256 newKey = 0xB0B;
        vm.prank(owner);
        account.setSigner(vm.addr(newKey));
        assertEq(account.signer(), vm.addr(newKey));

        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        vm.expectRevert(IPermitAccount.BadSignature.selector);
        account.permitTransfer(p, 0, relayer, r, vs);

        (r, vs) = _sign(newKey, address(account), p);
        account.permitTransfer(p, 0, relayer, r, vs);

        vm.prank(owner);
        account.setSigner(address(0));
        assertEq(account.signer(), owner);
    }

    function test_onlyOwnerAdminFunctions() public {
        vm.startPrank(stranger);
        vm.expectRevert(IPermitAccount.NotOwner.selector);
        account.setSigner(stranger);
        vm.expectRevert(IPermitAccount.NotOwner.selector);
        account.invalidateNonces(5);
        vm.expectRevert(IPermitAccount.NotOwner.selector);
        account.withdraw(address(usdt), stranger, 1);
        vm.expectRevert(IPermitAccount.NotOwner.selector);
        account.withdrawTRX(payable(stranger), 0);
        vm.stopPrank();
    }

    function test_invalidateNonces() public {
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        vm.prank(owner);
        account.invalidateNonces(3);
        vm.expectRevert(IPermitAccount.BadNonce.selector);
        account.permitTransfer(p, 0, relayer, r, vs);

        vm.startPrank(owner);
        vm.expectRevert(IPermitAccount.InvalidNonce.selector);
        account.invalidateNonces(3);
        vm.expectRevert(IPermitAccount.InvalidNonce.selector);
        account.invalidateNonces(uint256(type(uint96).max) + 1);
        vm.stopPrank();
    }

    function test_nonceCanNeverWrap() public {
        // The max nonce is not settable...
        vm.prank(owner);
        vm.expectRevert(IPermitAccount.InvalidNonce.selector);
        account.invalidateNonces(type(uint64).max);

        // ...and from max-1 (the highest settable), executing one permit lands
        // on max, where the checked increment makes execution impossible —
        // instead of wrapping to 0 and resurrecting every executed permit.
        uint256 last = uint256(type(uint64).max) - 1;
        vm.prank(owner);
        account.invalidateNonces(last);
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        assertEq(p.nonce, last);
        _submit(p, 0);
        assertEq(account.nonce(), uint256(type(uint64).max));

        Permit memory wrap = _permit(address(account), alice, 1, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), wrap);
        vm.prank(relayer);
        vm.expectRevert(stdError.arithmeticError);
        account.permitTransfer(wrap, 0, relayer, r, vs);

        // A replay of the very first permit stays dead.
        Permit memory old = _permit(address(account), alice, 1, 1_000_000);
        old.nonce = 0;
        (bytes32 r2, bytes32 vs2) = _sign(ownerKey, address(account), old);
        vm.prank(relayer);
        vm.expectRevert(IPermitAccount.BadNonce.selector);
        account.permitTransfer(old, 0, relayer, r2, vs2);

        // The owner is never locked in.
        vm.prank(owner);
        account.withdraw(address(usdt), owner, 1);
    }

    function test_feeRecipientCannotBeTheAccount() public {
        // Only reachable with an any-relayer permit (a bound one trips RelayerMismatch first).
        Permit memory p = _permit(address(account), alice, 1_000_000, 600_000);
        p.relayer = address(0);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        vm.prank(relayer);
        vm.expectRevert(IPermitAccount.InvalidRecipient.selector);
        account.permitTransfer(p, 500_000, address(account), r, vs);
    }

    function _packed(Permit memory p, uint256 relayerFee, address feeRecipient, bytes32 r, bytes32 vs) internal pure returns (bytes memory) {
        return abi.encodePacked(
            PermitAccount.permitTransferPacked.selector,
            p.token, p.to, uint96(p.value), uint96(p.maxFee), p.relayer,
            uint40(p.deadline), uint64(p.nonce), uint96(relayerFee), feeRecipient, r, vs
        );
    }

    function test_permitTransferPacked_sameSignatureSameEffects() public {
        Permit memory p = _permit(address(account), alice, 3_000_000, 600_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        bytes memory call_ = _packed(p, 200_000, relayer, r, vs);
        assertEq(call_.length, 197, "packed call must be 197 bytes");
        vm.prank(relayer);
        (bool ok,) = address(account).call(call_);
        assertTrue(ok, "packed permit failed");
        assertEq(usdt.balanceOf(alice), 3_000_000);
        assertEq(account.nonce(), 1);
        assertEq(account.feeOwed(address(usdt), relayer), 200_000);

        // A replay through the ABI entrypoint is dead: same nonce space.
        (bool replayOk,) = address(account).call(
            abi.encodeCall(account.permitTransfer, (p, 200_000, relayer, r, vs))
        );
        assertFalse(replayOk);
    }

    function test_permitTransferPacked_rejectsWrongLength() public {
        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        bytes memory call_ = _packed(p, 0, relayer, r, vs);
        bytes memory truncated = new bytes(call_.length - 1);
        for (uint256 i; i < truncated.length; i++) truncated[i] = call_[i];
        (bool ok, bytes memory ret) = address(account).call(truncated);
        assertFalse(ok);
        assertEq(bytes4(ret), PermitAccount.InvalidPackedCalldata.selector);
    }

    // -------------------------------------------------------------- exits

    function test_withdrawAvailableOnly() public {
        _submit(_permit(address(account), alice, 1_000_000, 1_000_000), 400_000);
        uint256 avail = account.available(address(usdt));
        vm.startPrank(owner);
        vm.expectRevert(IPermitAccount.InsufficientAvailable.selector);
        account.withdraw(address(usdt), owner, avail + 1);
        account.withdraw(address(usdt), owner, avail);
        vm.stopPrank();
        assertEq(usdt.balanceOf(owner), avail);
        assertEq(usdt.balanceOf(address(account)), account.totalOwed(address(usdt)));
    }

    function test_withdrawTRX() public {
        vm.deal(address(account), 2 ether);
        vm.prank(owner);
        account.withdrawTRX(payable(alice), 2 ether);
        assertEq(alice.balance, 2 ether);
    }

    function test_pauseNeverBlocksExits() public {
        vm.prank(guardian);
        factory.pause();

        Permit memory p = _permit(address(account), alice, 1, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        vm.expectRevert(IPaymasterFactory.ProtocolPaused.selector);
        account.permitTransfer(p, 0, relayer, r, vs);

        vm.startPrank(owner);
        account.withdraw(address(usdt), owner, 1_000);
        account.setSigner(address(1));
        account.invalidateNonces(9);
        vm.stopPrank();
        assertEq(usdt.balanceOf(owner), 1_000);
    }

    // --------------------------------------------------------------- claims

    function test_claimFees() public {
        _submit(_permit(address(account), alice, 10_000_000, 1_000_000), 300_000);
        uint256 proto = account.protocolOwed(address(usdt));

        vm.prank(stranger);
        assertEq(account.claimFees(address(usdt), stranger, stranger), 0);
        vm.prank(stranger);
        vm.expectRevert(IPermitAccount.NotAuthorized.selector);
        account.claimFees(address(usdt), relayer, stranger);

        vm.prank(relayer);
        assertEq(account.claimFees(address(usdt), relayer, relayer), 300_000);
        assertEq(usdt.balanceOf(relayer), 300_000);

        vm.prank(feeRecipient);
        assertEq(account.claimFees(address(usdt), feeRecipient, feeRecipient), proto);
        assertEq(account.totalOwed(address(usdt)), 0);
    }

    function test_feeRecipientAsRelayer_noCollision() public {
        Permit memory p = _permit(address(account), alice, 10_000_000, 1_000_000);
        p.relayer = feeRecipient;
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        account.permitTransfer(p, 200_000, feeRecipient, r, vs);
        // The protocol relayer's fee folds into protocolOwed (one storage slot):
        // the feeOwed view reads 0, totals and payouts are unchanged.
        uint256 protocolFee = factory.protocolFee(address(usdt), 10_000_000);
        assertEq(account.feeOwed(address(usdt), feeRecipient), 0);
        assertEq(account.protocolOwed(address(usdt)), 200_000 + protocolFee);
        assertEq(account.totalOwed(address(usdt)), 200_000 + protocolFee);
        vm.prank(feeRecipient);
        assertEq(account.claimFees(address(usdt), feeRecipient, feeRecipient), 200_000 + protocolFee);
        assertEq(account.totalOwed(address(usdt)), 0);
    }

    function test_claimMany() public {
        PermitAccount b = PermitAccount(payable(factory.deployAccount(owner, 7)));
        usdt.mint(address(b), 10_000_000);
        _submit(_permit(address(account), alice, 1_000_000, 1_000_000), 100_000);
        Permit memory p = _permit(address(b), alice, 1_000_000, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(b), p);
        b.permitTransfer(p, 50_000, relayer, r, vs);

        address[] memory accts = new address[](2);
        accts[0] = address(account);
        accts[1] = address(b);
        vm.prank(relayer);
        assertEq(factory.claimMany(accts, address(usdt), relayer), 150_000);
        assertEq(usdt.balanceOf(relayer), 150_000);

        // A stranger claiming through the factory only reaches their own (zero) accrual.
        vm.prank(stranger);
        assertEq(factory.claimMany(accts, address(usdt), stranger), 0);
    }

    // --------------------------------------------------------- deployAndPermit

    function test_deployAndPermit() public {
        address predicted = factory.predictAccount(owner, 3);
        usdt.mint(predicted, 5_000_000);
        Permit memory p = Permit({
            token: address(usdt),
            owner: owner,
            to: alice,
            value: 1_000_000,
            maxFee: 500_000,
            relayer: relayer,
            deadline: block.timestamp + 180,
            nonce: 0
        });
        (bytes32 r, bytes32 vs) = _signDigest(ownerKey, _specDigest(predicted, p));
        vm.prank(relayer);
        address deployed = factory.deployAndPermit(3, p, 400_000, relayer, r, vs);
        assertEq(deployed, predicted);
        assertEq(usdt.balanceOf(alice), 1_000_000);
        assertEq(PermitAccount(payable(deployed)).feeOwed(address(usdt), relayer), 400_000);
    }

    // ------------------------------------------------------------ reentrancy

    function test_reentrantTokenCannotDoublePermit() public {
        MockReentrantToken t = new MockReentrantToken();
        t.mint(address(account), 10);
        Permit memory p = _permit(address(account), alice, 1, 0);
        p.token = address(t);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        t.arm(address(account), abi.encodeCall(IPermitAccount.permitTransfer, (p, 0, relayer, r, vs)));
        account.permitTransfer(p, 0, relayer, r, vs);
        assertFalse(t.lastReentrySucceeded());
        assertEq(t.balanceOf(alice), 1);
    }

    // ------------------------------------------------------------- inertness

    function test_implementationInert() public {
        PermitAccount impl = PermitAccount(payable(factory.implementation(IPaymasterFactory.Kind.Account)));
        vm.expectRevert(IPermitAccount.DirectCallForbidden.selector);
        impl.owner();
        Permit memory p = _permit(address(account), alice, 1, 1);
        vm.expectRevert(IPermitAccount.DirectCallForbidden.selector);
        impl.permitTransfer(p, 0, relayer, bytes32(0), bytes32(0));
        vm.expectRevert(IPermitAccount.DirectCallForbidden.selector);
        impl.claimFees(address(usdt), stranger, stranger);

        PermitAccount router = PermitAccount(payable(factory.ACCOUNT_ROUTER()));
        vm.expectRevert(ImplementationRouter.DirectCallForbidden.selector);
        router.owner();
    }

    function test_storageSlotIsErc7201() public pure {
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("tronpaymaster.storage.PermitAccount")) - 1))
            & ~bytes32(uint256(0xff));
        assertEq(expected, 0x9b298f66baf0113f5795ca7dceb38688244830ed8291fad50819ba3a60641e00);
    }
}
