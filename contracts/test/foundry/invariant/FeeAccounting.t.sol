// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "../Base.t.sol";
import {PermitAccount} from "../../../src/PermitAccount.sol";
import {TestPaymasterFactory} from "../Base.t.sol";
import {Permit} from "../../../src/interfaces/IPermitAccount.sol";
import {MockUSDT} from "../mocks/Tokens.sol";

contract FeeHandler is Test {
    TestPaymasterFactory internal factory;
    PermitAccount internal account;
    MockUSDT internal usdt;
    uint256 internal ownerKey;
    address internal owner;
    address internal feeRecipient;
    address[3] internal relayers = [address(0x1001), address(0x1002), address(0x1003)];

    uint256 public ghostProtocolAccrued;
    uint256 public ghostProtocolClaimed;
    uint256 public ghostLastNonce;
    uint256 public ghostPermitFailures;

    constructor(TestPaymasterFactory f, PermitAccount a, MockUSDT t, uint256 key, address recipient) {
        factory = f;
        account = a;
        usdt = t;
        ownerKey = key;
        owner = vm.addr(key);
        feeRecipient = recipient;
    }

    function relayer(uint256 i) external view returns (address) {
        return relayers[i];
    }

    /// @dev Bounded to keep cumulative fee accrual inside the packed uint96
    /// accumulators. 1e24 base units is 10^18 USDT per deposit — far beyond any
    /// real supply — while 256 such deposits still cannot overflow uint96, so
    /// the invariant exercises reachable states instead of impossible ones.
    function deposit(uint96 amount) external {
        usdt.mint(address(account), bound(amount, 0, 1e24));
    }

    function permit(uint256 value, uint256 relayerFee, uint256 relayerIdx, address to) public {
        if (to == address(0) || to == address(account)) to = address(0xCAFE);
        address r = relayers[relayerIdx % 3];
        if (account.available(address(usdt)) < 1_000) usdt.mint(address(account), 1_000_000_000);
        uint256 avail = account.available(address(usdt));
        value = bound(value, 1, avail / 2);
        relayerFee = bound(relayerFee, 0, avail / 4);
        uint256 proto = factory.protocolFee(address(usdt), value);
        Permit memory p = Permit({
            token: address(usdt),
            owner: owner,
            to: to,
            value: value,
            maxFee: relayerFee + proto,
            relayer: r,
            deadline: block.timestamp + 60,
            nonce: account.nonce()
        });
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(ownerKey, account.hashPermit(p));
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
        uint256 before = usdt.balanceOf(to);
        try account.permitTransfer(p, relayerFee, r, rr, vs) {
            assertEq(usdt.balanceOf(to) - before, value, "I4: recipient gets exactly value");
            ghostProtocolAccrued += proto;
            assertGt(account.nonce(), ghostLastNonce, "I5: nonce monotonic");
            ghostLastNonce = account.nonce();
        } catch {
            ghostPermitFailures++;
        }
    }

    function withdrawAll() external {
        uint256 avail = account.available(address(usdt));
        vm.prank(owner);
        account.withdraw(address(usdt), owner, avail); // I3: must never revert
    }

    function claimRelayer(uint256 idx) external {
        address r = relayers[idx % 3];
        vm.prank(r);
        account.claimFees(address(usdt), r, r);
    }

    function claimProtocol() external {
        uint256 owed = account.protocolOwed(address(usdt)) + account.feeOwed(address(usdt), feeRecipient);
        vm.prank(feeRecipient);
        uint256 got = account.claimFees(address(usdt), feeRecipient, feeRecipient);
        assertEq(got, owed);
        ghostProtocolClaimed += got;
    }

    function setFee(uint16 b, uint128 c) external {
        b = uint16(bound(b, 0, factory.MAX_BPS()));
        c = uint128(bound(c, 0, factory.MAX_CAP()));
        vm.prank(factory.admin());
        factory.setProtocolFee(b, c);
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 1 days));
    }
}

contract FeeAccountingInvariantTest is BaseTest {
    FeeHandler internal handler;
    PermitAccount internal account;

    function setUp() public override {
        super.setUp();
        account = _account();
        usdt.mint(address(account), 1_000_000_000);
        handler = new FeeHandler(factory, account, usdt, ownerKey, feeRecipient);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = FeeHandler.deposit.selector;
        selectors[1] = FeeHandler.permit.selector;
        selectors[2] = FeeHandler.withdrawAll.selector;
        selectors[3] = FeeHandler.claimRelayer.selector;
        selectors[4] = FeeHandler.claimProtocol.selector;
        selectors[5] = FeeHandler.setFee.selector;
        selectors[6] = FeeHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// I1: accrued fees are always backed by the account's balance.
    function invariant_feesBacked() public view {
        assertGe(usdt.balanceOf(address(account)), account.totalOwed(address(usdt)));
    }

    /// I2: totalOwed == protocolOwed + sum of per-beneficiary accruals.
    function invariant_totalOwedIsSum() public view {
        uint256 sum = account.protocolOwed(address(usdt));
        for (uint256 i; i < 3; ++i) {
            sum += account.feeOwed(address(usdt), handler.relayer(i));
        }
        assertEq(account.totalOwed(address(usdt)), sum);
    }

    /// Guard against vacuous runs: well-formed permits must actually execute.
    function afterInvariant() external view {
        // Every generated permit is valid by construction, so none may fail.
        assertEq(handler.ghostPermitFailures(), 0, "a valid permit failed");
    }

    /// Protocol fees are neither lost nor double paid.
    function invariant_protocolConservation() public view {
        assertEq(
            handler.ghostProtocolAccrued(), handler.ghostProtocolClaimed() + account.protocolOwed(address(usdt))
        );
    }
}
