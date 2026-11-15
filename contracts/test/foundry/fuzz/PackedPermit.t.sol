// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {BaseTest} from "../Base.t.sol";
import {PermitAccount} from "../../../src/PermitAccount.sol";
import {IPermitAccount, Permit} from "../../../src/interfaces/IPermitAccount.sol";
import {MockStandardToken} from "../mocks/Tokens.sol";

/// @title Differential fuzzing for the energy diet
/// @notice The diet introduced two places where one logical operation now has
/// two implementations: a hand-rolled packed-calldata decoder beside the ABI
/// entrypoint, and a packed hot slot beside the mapping used for every other
/// token. Hand-rolled decoders and divergent accounting paths are exactly
/// where silent mismatches hide, so both are fuzzed against their reference
/// implementation rather than spot-checked.
contract PackedPermitFuzzTest is BaseTest {
    PermitAccount internal account;
    MockStandardToken internal other;

    function setUp() public override {
        super.setUp();
        account = PermitAccount(payable(factory.deployAccount(owner, 0)));
        other = new MockStandardToken();
    }

    function _packed(Permit memory p, uint256 relayerFee, address feeRecipient_, bytes32 r, bytes32 vs)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            PermitAccount.permitTransferPacked.selector,
            p.token,
            p.to,
            uint96(p.value),
            uint96(p.maxFee),
            p.relayer,
            uint40(p.deadline),
            uint64(p.nonce),
            uint96(relayerFee),
            feeRecipient_,
            r,
            vs
        );
    }

    /// Both entrypoints must accept the same signature and leave identical
    /// state. Two accounts are driven in lockstep: one through the ABI call,
    /// one through the packed call.
    struct Lockstep {
        PermitAccount b;
        address to;
        address feeTo;
        uint256 value;
        uint256 relayerFee;
        uint256 maxFee;
    }

    function testFuzz_packedMatchesAbi(uint96 value, uint96 relayerFee, uint256 toSeed, bool bindRelayer) public {
        Lockstep memory s;
        s.value = bound(value, 1, 50_000_000);
        s.relayerFee = bound(relayerFee, 0, 2_000_000);
        s.b = PermitAccount(payable(factory.deployAccount(owner, 1)));
        s.to = address(uint160(bound(toSeed, 0x1000, type(uint160).max)));
        // Foundry seeds the fuzzer from addresses it finds in state, so it will
        // propose the accounts themselves. Sending to the account under test is
        // refused by design (`InvalidRecipient`) and is covered by its own unit
        // test; here it would also make the recipient assertion vacuous, since
        // the account already holds the minted balance.
        vm.assume(s.to != address(account) && s.to != address(s.b));
        s.feeTo = bindRelayer ? relayer : feeRecipient;
        s.maxFee = s.relayerFee + factory.protocolFee(address(usdt), s.value);
        usdt.mint(address(account), 100_000_000);
        usdt.mint(address(s.b), 100_000_000);

        {
            Permit memory pa = _permit(address(account), s.to, s.value, s.maxFee);
            pa.relayer = bindRelayer ? relayer : address(0);
            (bytes32 ra, bytes32 va) = _sign(ownerKey, address(account), pa);
            account.permitTransfer(pa, s.relayerFee, s.feeTo, ra, va);
        }
        {
            Permit memory pb = _permit(address(s.b), s.to, s.value, s.maxFee);
            pb.relayer = bindRelayer ? relayer : address(0);
            (bytes32 rb, bytes32 vb) = _sign(ownerKey, address(s.b), pb);
            (bool ok,) = address(s.b).call(_packed(pb, s.relayerFee, s.feeTo, rb, vb));
            assertTrue(ok, "packed call reverted where the ABI call succeeded");
        }

        // Identical observable state on both accounts.
        assertEq(s.b.nonce(), account.nonce(), "nonce");
        assertEq(s.b.totalOwed(address(usdt)), account.totalOwed(address(usdt)), "totalOwed");
        assertEq(s.b.protocolOwed(address(usdt)), account.protocolOwed(address(usdt)), "protocolOwed");
        assertEq(s.b.feeOwed(address(usdt), s.feeTo), account.feeOwed(address(usdt), s.feeTo), "feeOwed");
        assertEq(s.b.available(address(usdt)), account.available(address(usdt)), "available");
        assertEq(usdt.balanceOf(s.to), s.value * 2, "recipient received exactly value from each");
    }

    /// The packed decoder must reject anything that is not exactly its layout,
    /// rather than silently reading adjacent bytes.
    function testFuzz_packedRejectsMalformedLength(uint8 lengthDelta) public {
        vm.assume(lengthDelta != 0);
        usdt.mint(address(account), 10_000_000);
        Permit memory p = _permit(address(account), alice, 1_000_000, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        bytes memory good = _packed(p, 0, relayer, r, vs);

        // Shorter or longer by any amount: never accepted.
        bytes memory bad;
        if (lengthDelta % 2 == 0 && good.length > lengthDelta) {
            bad = new bytes(good.length - lengthDelta);
            for (uint256 i; i < bad.length; i++) bad[i] = good[i];
        } else {
            bad = new bytes(good.length + lengthDelta);
            for (uint256 i; i < good.length; i++) bad[i] = good[i];
        }
        (bool ok, bytes memory ret) = address(account).call(bad);
        assertFalse(ok, "malformed packed calldata was accepted");
        if (bad.length >= 4) assertEq(bytes4(ret), PermitAccount.InvalidPackedCalldata.selector);
    }

    /// Flipping any single bit of the payload must break the signature check
    /// (or the field bounds) — never silently execute a different transfer.
    function testFuzz_packedIsTamperEvident(uint16 bitIndex) public {
        usdt.mint(address(account), 50_000_000);
        Permit memory p = _permit(address(account), alice, 5_000_000, 1_000_000);
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        bytes memory good = _packed(p, 100_000, relayer, r, vs);

        // Non-vacuity: the untampered payload must actually work, or this test
        // would "pass" merely because every call reverts for an unrelated reason.
        {
            PermitAccount twin = PermitAccount(payable(factory.deployAccount(owner, 9)));
            usdt.mint(address(twin), 50_000_000);
            Permit memory tp = _permit(address(twin), alice, 5_000_000, 1_000_000);
            (bytes32 tr, bytes32 tvs) = _sign(ownerKey, address(twin), tp);
            (bool controlOk,) = address(twin).call(_packed(tp, 100_000, relayer, tr, tvs));
            assertTrue(controlOk, "control: the untampered packed payload must succeed");
        }

        // Skip the 4-byte selector; tamper with exactly one bit of the payload.
        uint256 payloadBits = (good.length - 4) * 8;
        uint256 bit = bound(bitIndex, 0, payloadBits - 1);
        uint256 byteIdx = 4 + bit / 8;
        good[byteIdx] = bytes1(uint8(good[byteIdx]) ^ uint8(1 << (bit % 8)));

        uint256 balanceBefore = usdt.balanceOf(alice);
        (bool ok,) = address(account).call(good);
        if (ok) {
            // The only benign flip is one the contract treats as equivalent;
            // nothing may move except the exact signed transfer.
            assertEq(usdt.balanceOf(alice) - balanceBefore, 5_000_000, "a tampered permit moved a different amount");
        } else {
            assertEq(usdt.balanceOf(alice), balanceBefore, "a rejected permit still moved funds");
            assertEq(account.nonce(), 0, "a rejected permit consumed the nonce");
        }
    }

    /// The fee token uses the packed hot slot; every other token uses the
    /// mapping. Accounting and payouts must be indistinguishable.
    function testFuzz_feeTokenAndOtherTokenAgree(uint96 value, uint96 relayerFee) public {
        value = uint96(bound(value, 1, 10_000_000));
        relayerFee = uint96(bound(relayerFee, 1, 1_000_000));

        PermitAccount b = PermitAccount(payable(factory.deployAccount(owner, 2)));
        usdt.mint(address(account), 100_000_000);
        other.mint(address(b), 100_000_000);

        // The protocol fee only applies to FEE_TOKEN, so compare like with like.
        uint256 protoA = factory.protocolFee(address(usdt), value);
        assertEq(factory.protocolFee(address(other), value), 0, "non-fee token must not be charged");

        Permit memory pa = _permit(address(account), alice, value, uint256(relayerFee) + protoA);
        (bytes32 ra, bytes32 va) = _sign(ownerKey, address(account), pa);
        account.permitTransfer(pa, relayerFee, relayer, ra, va);

        Permit memory pb = _permit(address(b), alice, value, relayerFee);
        pb.token = address(other);
        (bytes32 rb, bytes32 vb) = _sign(ownerKey, address(b), pb);
        b.permitTransfer(pb, relayerFee, relayer, rb, vb);

        // The relayer's credit is identical in both storage layouts.
        assertEq(b.feeOwed(address(other), relayer), account.feeOwed(address(usdt), relayer), "relayer credit diverges");
        assertEq(b.totalOwed(address(other)), relayerFee, "mapping path totalOwed");
        assertEq(account.totalOwed(address(usdt)), uint256(relayerFee) + protoA, "hot-slot path totalOwed");

        // And both pay out fully.
        vm.prank(relayer);
        assertEq(account.claimFees(address(usdt), relayer, relayer), relayerFee);
        vm.prank(relayer);
        assertEq(b.claimFees(address(other), relayer, relayer), relayerFee);
    }

    /// The fee fold must never let FEE_RECIPIENT collect more or less than the
    /// sum of what it was credited.
    function testFuzz_feeFoldConservesValue(uint96 value, uint96 relayerFee, bool foldToProtocol) public {
        value = uint96(bound(value, 1, 10_000_000));
        relayerFee = uint96(bound(relayerFee, 0, 1_000_000));
        usdt.mint(address(account), 100_000_000);

        uint256 proto = factory.protocolFee(address(usdt), value);
        address feeTo = foldToProtocol ? feeRecipient : relayer;
        Permit memory p = _permit(address(account), alice, value, uint256(relayerFee) + proto);
        p.relayer = feeTo;
        (bytes32 r, bytes32 vs) = _sign(ownerKey, address(account), p);
        account.permitTransfer(p, relayerFee, feeTo, r, vs);

        // Whichever path was taken, the account owes exactly the fees charged.
        assertEq(account.totalOwed(address(usdt)), uint256(relayerFee) + proto, "totalOwed must equal fees charged");

        uint256 paid;
        vm.prank(feeRecipient);
        paid += account.claimFees(address(usdt), feeRecipient, feeRecipient);
        if (!foldToProtocol) {
            vm.prank(relayer);
            paid += account.claimFees(address(usdt), relayer, relayer);
        }
        assertEq(paid, uint256(relayerFee) + proto, "claims must drain exactly what was owed");
        assertEq(account.totalOwed(address(usdt)), 0, "nothing may remain owed");
    }
}
