// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest, TestPaymasterFactory} from "../Base.t.sol";
import {DepositForwarder} from "../../../src/DepositForwarder.sol";
import {IPaymasterFactory} from "../../../src/interfaces/IPaymasterFactory.sol";
import {MockUSDT} from "../mocks/Tokens.sol";

/// @dev Random deposits, sweeps (direct, via factory, batched) and arbitrary calls by anyone.
contract ForwarderHandler is Test {
    TestPaymasterFactory internal f;
    MockUSDT internal usdt;
    address public treasury;
    address public sweeper;
    bytes32[4] internal salts = [bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3)), bytes32(uint256(4))];

    uint256 public minted;
    uint256 public sweeps;
    uint256 public trxDeposited;

    constructor(TestPaymasterFactory f_, MockUSDT usdt_, address treasury_, address sweeper_) {
        f = f_;
        usdt = usdt_;
        treasury = treasury_;
        sweeper = sweeper_;
    }

    function _sw(uint256 i) internal view returns (address) {
        return i % 2 == 0 ? address(0) : sweeper; // half the forwarders are gated
    }

    function forwarder(uint256 i) public view returns (address) {
        return f.predictForwarder(treasury, _sw(i), salts[i % 4]);
    }

    function deposit(uint256 i, uint96 amount) external {
        usdt.mint(forwarder(i), amount);
        minted += amount;
    }

    function depositTRX(uint256 i, uint64 amount) external {
        vm.deal(address(this), amount);
        (bool ok,) = payable(forwarder(i)).call{value: amount}("");
        if (!ok) {
            // undeployed address: plain value transfer always succeeds on EVM
        }
        trxDeposited += ok ? amount : 0;
    }

    function sweepViaFactory(uint256 i, uint256 who, bool trx) external {
        address caller = who % 3 == 0 ? sweeper : address(uint160(0xC000 + who % 5));
        vm.prank(caller);
        try f.sweep(treasury, _sw(i), salts[i % 4], trx ? address(0) : address(usdt)) returns (uint256 amt) {
            if (amt > 0) sweeps++;
        } catch {}
    }

    function sweepDirect(uint256 i, uint256 who) external {
        address fwd = forwarder(i);
        if (fwd.code.length == 0) return;
        address caller = who % 3 == 0 ? sweeper : address(uint160(0xC000 + who % 5));
        vm.prank(caller);
        try DepositForwarder(payable(fwd)).sweep(address(usdt)) returns (uint256 amt) {
            if (amt > 0) sweeps++;
        } catch {}
    }

    function arbitraryCall(uint256 i, uint256 who, bytes calldata data) external {
        address fwd = forwarder(i);
        vm.prank(address(uint160(0xC000 + who % 5)));
        (bool ok,) = fwd.call(data);
        ok;
    }

    function deploy(uint256 i) external {
        f.deployForwarder(treasury, _sw(i), salts[i % 4]);
    }
}

/// forge-config: default.invariant.depth = 256
/// forge-config: default.invariant.runs = 128
contract ForwarderInvariantTest is BaseTest {
    ForwarderHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ForwarderHandler(factory, usdt, treasury, relayer);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](6);
        sel[0] = ForwarderHandler.deposit.selector;
        sel[1] = ForwarderHandler.depositTRX.selector;
        sel[2] = ForwarderHandler.sweepViaFactory.selector;
        sel[3] = ForwarderHandler.sweepDirect.selector;
        sel[4] = ForwarderHandler.arbitraryCall.selector;
        sel[5] = ForwarderHandler.deploy.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    function afterInvariant() external view {
        assertGt(handler.sweeps(), 0, "no non-empty sweep happened in this run");
    }

    /// I7: deposited value is either still in a forwarder or in the treasury — never anywhere else.
    function invariant_valueOnlyReachesTreasury() public view {
        uint256 inForwarders;
        uint256 trxInForwarders;
        for (uint256 i; i < 4; ++i) {
            inForwarders += usdt.balanceOf(handler.forwarder(i));
            trxInForwarders += handler.forwarder(i).balance;
        }
        assertEq(inForwarders + usdt.balanceOf(treasury), handler.minted());
        assertEq(usdt.totalSupply(), handler.minted());
        assertEq(trxInForwarders + treasury.balance, handler.trxDeposited());
    }
}
