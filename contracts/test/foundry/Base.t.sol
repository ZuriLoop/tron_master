// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PaymasterFactory} from "../../src/PaymasterFactory.sol";
import {PermitAccount} from "../../src/PermitAccount.sol";
import {DepositForwarder} from "../../src/DepositForwarder.sol";
import {IPaymasterFactory} from "../../src/interfaces/IPaymasterFactory.sol";
import {IPermitAccount, Permit} from "../../src/interfaces/IPermitAccount.sol";
import {MockUSDT} from "./mocks/Tokens.sol";

/// @dev The only tested-vs-deployed difference: EVM CREATE2 uses 0xff, TVM 0x41.
contract TestPaymasterFactory is PaymasterFactory {
    constructor(Config memory c) PaymasterFactory(c) {}

    function _create2Prefix() internal pure override returns (bytes1) {
        return 0xff;
    }
}

abstract contract BaseTest is Test {
    uint16 internal constant BPS = 10; // 0.10%
    uint128 internal constant CAP = 250_000; // 0.25 USDT (6 dp)
    uint16 internal constant MAX_BPS = 50;
    uint128 internal constant MAX_CAP = 1_000_000;
    uint256 internal constant DELAY = 3 days;
    uint256 internal constant PAUSE = 7 days;

    TestPaymasterFactory internal factory;
    MockUSDT internal usdt;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal treasury = makeAddr("treasury");
    address internal relayer = makeAddr("relayer");
    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");

    uint256 internal ownerKey = 0xA11CE;
    address internal owner;

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        owner = vm.addr(ownerKey);
        usdt = new MockUSDT();
        factory = new TestPaymasterFactory(_config(address(usdt)));
    }

    function _config(address feeToken) internal view returns (PaymasterFactory.Config memory) {
        return PaymasterFactory.Config({
            feeToken: feeToken,
            feeRecipient: feeRecipient,
            maxBps: MAX_BPS,
            maxCap: MAX_CAP,
            bps: BPS,
            cap: CAP,
            admin: admin,
            guardian: guardian,
            upgradeDelay: DELAY,
            pauseDuration: PAUSE
        });
    }

    // ------------------------------------------------------------ permits

    function _permit(address account, address to, uint256 value, uint256 maxFee) internal view returns (Permit memory) {
        return Permit({
            token: address(usdt),
            owner: owner,
            to: to,
            value: value,
            maxFee: maxFee,
            relayer: relayer,
            deadline: block.timestamp + 180,
            nonce: PermitAccount(payable(account)).nonce()
        });
    }

    function _sign(uint256 key, address account, Permit memory p) internal view returns (bytes32 r, bytes32 vs) {
        bytes32 digest = PermitAccount(payable(account)).hashPermit(p);
        return _signDigest(key, digest);
    }

    function _signDigest(uint256 key, bytes32 digest) internal pure returns (bytes32 r, bytes32 vs) {
        (uint8 v, bytes32 r_, bytes32 s) = vm.sign(key, digest);
        r = r_;
        vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
    }

    /// @dev Digest computed independently of the contract (TIP-712 spec).
    function _specDigest(address account, Permit memory p) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("TronPaymaster"),
                keccak256("1"),
                block.chainid & 0xffffffff,
                account
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "PermitTransfer(address token,address owner,address to,uint256 value,uint256 maxFee,address relayer,uint256 deadline,uint256 nonce)"
                ),
                p.token,
                p.owner,
                p.to,
                p.value,
                p.maxFee,
                p.relayer,
                p.deadline,
                p.nonce
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    function _account() internal returns (PermitAccount) {
        return PermitAccount(payable(factory.deployAccount(owner, 0)));
    }
}
