// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {BaseTest, TestPaymasterFactory} from "../Base.t.sol";
import {PermitAccount} from "../../../src/PermitAccount.sol";
import {Permit} from "../../../src/interfaces/IPermitAccount.sol";

/// @notice SDK <-> contract parity on the shared vectors (sdk/vectors/vectors.json).
/// The SDK computes both TVM (0x41) and EVM (0xff) addresses; this harness can
/// only check the EVM ones; TVM parity is checked against a real node in the
/// tre end-to-end test.
contract VectorsTest is BaseTest {
    string internal json;
    address internal vFactory;

    function setUp() public override {
        super.setUp();
        json = vm.readFile("../sdk/vectors/vectors.json");
        address deployer = vm.parseJsonAddress(json, ".deployer");
        vm.setNonce(deployer, 0);
        vm.prank(deployer);
        vFactory = address(new TestPaymasterFactory(_config(address(usdt))));
        assertEq(vFactory, vm.parseJsonAddress(json, ".factory"), "vector factory address");
    }

    function _f() internal view returns (TestPaymasterFactory) {
        return TestPaymasterFactory(vFactory);
    }

    function _k(string memory arr, uint256 i, string memory field) internal pure returns (string memory) {
        return string.concat(".", arr, "[", vm.toString(i), "].", field);
    }

    function test_routersAtExpectedAddresses() public view {
        assertEq(_f().FORWARDER_ROUTER(), vm.parseJsonAddress(json, ".evmForwarderRouter"));
        assertEq(_f().ACCOUNT_ROUTER(), vm.parseJsonAddress(json, ".evmAccountRouter"));
    }

    function test_forwarderVectors() public {
        uint256 n = 6;
        for (uint256 i; i < n; ++i) {
            address treasury_ = vm.parseJsonAddress(json, _k("forwarders", i, "treasury"));
            address sweeper_ = vm.parseJsonAddress(json, _k("forwarders", i, "sweeper"));
            bytes32 salt = vm.parseJsonBytes32(json, _k("forwarders", i, "salt"));
            address expected = vm.parseJsonAddress(json, _k("forwarders", i, "evm"));
            assertEq(_f().predictForwarder(treasury_, sweeper_, salt), expected, "predict");
            assertEq(_f().deployForwarder(treasury_, sweeper_, salt), expected, "deploy");
            // Deployed runtime = the 45-byte proxy + args, i.e. init code minus its 10-byte constructor.
            bytes memory initCode = vm.parseJsonBytes(json, _k("forwarders", i, "initCode"));
            assertEq(keccak256(expected.code), keccak256(_slice(initCode, 10)), "runtime");
        }
    }

    function test_accountVectors() public {
        for (uint256 i; i < 3; ++i) {
            address owner_ = vm.parseJsonAddress(json, _k("accounts", i, "owner"));
            uint256 index = vm.parseJsonUint(json, _k("accounts", i, "index"));
            address expected = vm.parseJsonAddress(json, _k("accounts", i, "evm"));
            assertEq(_f().predictAccount(owner_, index), expected);
            assertEq(_f().deployAccount(owner_, index), expected);
        }
    }

    function test_permitVectors() public {
        address owner_ = vm.parseJsonAddress(json, ".owner");
        PermitAccount acct = PermitAccount(payable(_f().deployAccount(owner_, 0)));
        for (uint256 i; i < 4; ++i) {
            vm.chainId(vm.parseJsonUint(json, _k("permits", i, "chainId")));
            assertEq(address(acct), vm.parseJsonAddress(json, _k("permits", i, "account")));
            string memory pk = string.concat(".permits[", vm.toString(i), "].permit.");
            Permit memory p = Permit({
                token: vm.parseJsonAddress(json, string.concat(pk, "token")),
                owner: vm.parseJsonAddress(json, string.concat(pk, "owner")),
                to: vm.parseJsonAddress(json, string.concat(pk, "to")),
                value: vm.parseJsonUint(json, string.concat(pk, "value")),
                maxFee: vm.parseJsonUint(json, string.concat(pk, "maxFee")),
                relayer: vm.parseJsonAddress(json, string.concat(pk, "relayer")),
                deadline: vm.parseJsonUint(json, string.concat(pk, "deadline")),
                nonce: vm.parseJsonUint(json, string.concat(pk, "nonce"))
            });
            bytes32 digest = vm.parseJsonBytes32(json, _k("permits", i, "digest"));
            assertEq(acct.hashPermit(p), digest, "digest");
            assertEq(_specDigest(address(acct), p), digest, "spec digest");
            // The SDK's (r, vs) recovers to the owner under the contract's ECDSA.
            bytes32 r = vm.parseJsonBytes32(json, _k("permits", i, "r"));
            bytes32 vs = vm.parseJsonBytes32(json, _k("permits", i, "vs"));
            assertEq(ecrecoverCompact(digest, r, vs), owner_, "signature");
        }
    }

    function ecrecoverCompact(bytes32 h, bytes32 r, bytes32 vs) internal pure returns (address) {
        bytes32 s = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
        uint8 v = uint8((uint256(vs) >> 255) + 27);
        return ecrecover(h, v, r, s);
    }

    function test_addressVectors() public view {
        for (uint256 i; i < 3; ++i) {
            address hexAddr = vm.parseJsonAddress(json, _k("addresses", i, "hex"));
            string memory tronHex = vm.parseJsonString(json, _k("addresses", i, "tronHex"));
            assertEq(string.concat("41", _lowerHex(hexAddr)), tronHex);
        }
    }

    function _lowerHex(address a) internal pure returns (string memory) {
        bytes memory s = bytes(vm.toLowercase(vm.toString(a)));
        bytes memory out = new bytes(40);
        for (uint256 i; i < 40; ++i) out[i] = s[i + 2];
        return string(out);
    }

    function _slice(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i; i < out.length; ++i) out[i] = b[i + from];
    }
}
