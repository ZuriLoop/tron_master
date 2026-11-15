// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {BaseTest} from "../Base.t.sol";
import {DepositForwarder} from "../../../src/DepositForwarder.sol";
import {ImplementationRouter} from "../../../src/ImplementationRouter.sol";
import {IPaymasterFactory} from "../../../src/interfaces/IPaymasterFactory.sol";
import {TokenTransfer} from "../../../src/libraries/TokenTransfer.sol";
import {MockSilentFailToken, MockStandardToken} from "../mocks/Tokens.sol";

contract DepositForwarderTest is BaseTest {
    bytes32 internal constant SALT = keccak256("user-42");

    function test_predictMatchesDeploy() public {
        address predicted = factory.predictForwarder(treasury, address(0), SALT);
        assertEq(predicted.code.length, 0);
        address deployed = factory.deployForwarder(treasury, address(0), SALT);
        assertEq(deployed, predicted);
        assertGt(deployed.code.length, 0);
    }

    function test_deployIsIdempotent() public {
        address a = factory.deployForwarder(treasury, address(0), SALT);
        vm.recordLogs();
        address b = factory.deployForwarder(treasury, address(0), SALT);
        assertEq(a, b);
        assertEq(vm.getRecordedLogs().length, 0, "no second ForwarderDeployed");
    }

    function test_addressCommitsToTreasuryAndSweeper() public view {
        address a = factory.predictForwarder(treasury, address(0), SALT);
        assertTrue(a != factory.predictForwarder(stranger, address(0), SALT));
        assertTrue(a != factory.predictForwarder(treasury, relayer, SALT));
        assertTrue(a != factory.predictForwarder(treasury, address(0), bytes32(uint256(SALT) + 1)));
    }

    function test_rejectsZeroTreasury() public {
        vm.expectRevert(IPaymasterFactory.InvalidTreasury.selector);
        factory.deployForwarder(address(0), address(0), SALT);
    }

    function test_depositBeforeDeploy_thenSweepViaFactory() public {
        address f = factory.predictForwarder(treasury, address(0), SALT);
        usdt.mint(f, 1_000_000);
        vm.prank(stranger);
        uint256 moved = factory.sweep(treasury, address(0), SALT, address(usdt));
        assertEq(moved, 1_000_000);
        assertEq(usdt.balanceOf(treasury), 1_000_000);
        assertEq(usdt.balanceOf(f), 0);
    }

    function test_args() public {
        DepositForwarder f = DepositForwarder(payable(factory.deployForwarder(treasury, relayer, SALT)));
        assertEq(f.treasury(), treasury);
        assertEq(f.sweeper(), relayer);
        assertEq(f.FACTORY(), address(factory));
    }

    function test_permissionlessSweep_directOnForwarder() public {
        DepositForwarder f = DepositForwarder(payable(factory.deployForwarder(treasury, address(0), SALT)));
        usdt.mint(address(f), 5);
        vm.prank(stranger);
        assertEq(f.sweep(address(usdt)), 5);
        assertEq(usdt.balanceOf(treasury), 5);
    }

    function test_gatedSweep() public {
        DepositForwarder f = DepositForwarder(payable(factory.deployForwarder(treasury, relayer, SALT)));
        usdt.mint(address(f), 5);

        vm.prank(stranger);
        vm.expectRevert(DepositForwarder.NotAuthorized.selector);
        f.sweep(address(usdt));

        vm.prank(stranger);
        vm.expectRevert(IPaymasterFactory.NotAuthorized.selector);
        factory.sweep(treasury, relayer, SALT, address(usdt));

        vm.prank(relayer);
        factory.sweep(treasury, relayer, SALT, address(usdt));
        assertEq(usdt.balanceOf(treasury), 5);
    }

    function test_sweepTRX() public {
        address f = factory.predictForwarder(treasury, address(0), SALT);
        vm.deal(f, 3 ether);
        factory.sweep(treasury, address(0), SALT, address(0));
        assertEq(treasury.balance, 3 ether);
        assertEq(f.balance, 0);
    }

    function test_receiveTRXAfterDeploy() public {
        address f = factory.deployForwarder(treasury, address(0), SALT);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = f.call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(f.balance, 1 ether);
    }

    function test_sweepEmptyIsNoop() public {
        address f = factory.deployForwarder(treasury, address(0), SALT);
        assertEq(DepositForwarder(payable(f)).sweep(address(usdt)), 0);
        assertEq(DepositForwarder(payable(f)).sweepTRX(), 0);
    }

    function test_standardTokenWorks() public {
        MockStandardToken t = new MockStandardToken();
        address f = factory.predictForwarder(treasury, address(0), SALT);
        t.mint(f, 7);
        factory.sweep(treasury, address(0), SALT, address(t));
        assertEq(t.balanceOf(treasury), 7);
    }

    function test_silentFailTokenReverts() public {
        MockSilentFailToken t = new MockSilentFailToken();
        address f = factory.predictForwarder(treasury, address(0), SALT);
        t.mint(f, 7);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        factory.sweep(treasury, address(0), SALT, address(t));
    }

    function test_sweepMany() public {
        IPaymasterFactory.SweepItem[] memory items = new IPaymasterFactory.SweepItem[](3);
        for (uint256 i; i < 3; ++i) {
            bytes32 salt = bytes32(i);
            usdt.mint(factory.predictForwarder(treasury, address(0), salt), 100 * (i + 1));
            items[i] = IPaymasterFactory.SweepItem(treasury, address(0), salt, address(usdt));
        }
        factory.sweepMany(items);
        assertEq(usdt.balanceOf(treasury), 600);
    }

    function test_pausedBlocksSweep() public {
        address f = factory.predictForwarder(treasury, address(0), SALT);
        usdt.mint(f, 1);
        vm.prank(guardian);
        factory.pause();
        vm.expectRevert(IPaymasterFactory.ProtocolPaused.selector);
        factory.sweep(treasury, address(0), SALT, address(usdt));

        vm.warp(block.timestamp + PAUSE);
        factory.sweep(treasury, address(0), SALT, address(usdt));
        assertEq(usdt.balanceOf(treasury), 1);
    }

    function test_implementationAndRouterInert() public {
        DepositForwarder impl = DepositForwarder(payable(factory.implementation(IPaymasterFactory.Kind.Forwarder)));
        vm.expectRevert(DepositForwarder.DirectCallForbidden.selector);
        impl.sweep(address(usdt));
        vm.expectRevert(DepositForwarder.DirectCallForbidden.selector);
        impl.treasury();

        address router = factory.FORWARDER_ROUTER();
        vm.expectRevert(ImplementationRouter.DirectCallForbidden.selector);
        DepositForwarder(payable(router)).sweep(address(usdt));
    }

    /// @dev I7: whatever the caller and calldata, value only reaches the treasury.
    function testFuzz_fundsOnlyReachTreasury(address caller, bytes calldata data, uint96 amount) public {
        vm.assume(caller != treasury);
        address f = factory.deployForwarder(treasury, address(0), SALT);
        usdt.mint(f, amount);
        vm.deal(f, amount);
        vm.prank(caller);
        (bool ok,) = f.call(data);
        ok;
        assertEq(usdt.balanceOf(f) + usdt.balanceOf(treasury), amount);
        assertEq(f.balance + treasury.balance, amount);
    }
}
