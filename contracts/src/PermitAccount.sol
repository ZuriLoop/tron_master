// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/tron-contracts/proxy/Clones.sol";
import {ECDSA} from "@openzeppelin/tron-contracts/utils/cryptography/ECDSA.sol";
import {TIP712} from "@openzeppelin/tron-contracts/utils/cryptography/TIP712.sol";
import {SafeCast} from "@openzeppelin/tron-contracts/utils/math/SafeCast.sol";
import {IPermitAccount, Permit} from "./interfaces/IPermitAccount.sol";
import {IPaymasterFactory} from "./interfaces/IPaymasterFactory.sol";
import {ITRC20} from "./interfaces/ITRC20.sol";
import {TokenTransfer} from "./libraries/TokenTransfer.sol";

/// @title PermitAccount
/// @notice A non-custodial account that moves tokens on its owner's TIP-712
/// signature, submitted by any relayer that pays the energy.
/// @dev Runs behind an ImplementationRouter clone whose immutable args are the
/// owner (20 bytes). No initializer: the owner is part of the clone's code and
/// therefore of its CREATE2 address. State lives in ERC-7201 namespaced
/// storage so implementations can be upgraded through the factory timelock.
///
/// Fees are taken in the transferred token and accrue in this account's
/// storage (`totalOwed`) instead of being transferred per permit; relayers and
/// the protocol fee recipient claim them later. Accrued fees are excluded from
/// what the owner can withdraw, and `balanceOf(this) >= totalOwed` holds after
/// every call.
///
/// Pausing (factory) blocks `permitTransfer` only. `withdraw`, `withdrawTRX`,
/// `setSigner`, `invalidateNonces` and `claimFees` never consult the pause.
contract PermitAccount is IPermitAccount, TIP712 {
    using SafeCast for uint256;

    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "PermitTransfer(address token,address owner,address to,uint256 value,uint256 maxFee,address relayer,uint256 deadline,uint256 nonce)"
    );

    /// @dev keccak256(abi.encode(uint256(keccak256("tronpaymaster.storage.PermitAccount")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_SLOT = 0x9b298f66baf0113f5795ca7dceb38688244830ed8291fad50819ba3a60641e00;

    address public immutable FACTORY;

    /// @notice Which implementation slot this contract is valid for; checked by
    /// `queueUpgrade` so an account implementation can never be queued as a forwarder (or vice versa).
    IPaymasterFactory.Kind public constant KIND = IPaymasterFactory.Kind.Account;
    address public immutable FEE_RECIPIENT;
    /// @notice The token whose fee accounting lives in the packed hot slot.
    address public immutable FEE_TOKEN;
    address private immutable SELF;

    /// @dev One storage word holding everything a FEE_TOKEN permit must write:
    /// a permit in the protocol's fee token (the dominant traffic, e.g. USDT)
    /// costs a single storage write instead of two or three.
    ///
    /// Bounds, both checked rather than truncating: uint96 covers 7.9e28 base
    /// units of accrued fees (eleven orders of magnitude above USDT's entire
    /// supply) and uint64 covers 1.8e19 nonces. A fee token whose unclaimed
    /// fees could exceed uint96 would make permits revert until they are
    /// claimed — fail-safe, never a silent wrap — so FEE_TOKEN should be a
    /// token whose supply fits comfortably below that.
    struct Hot {
        uint64 nonce;
        uint96 totalOwed; // FEE_TOKEN only
        uint96 protocolOwed; // FEE_TOKEN only
    }

    struct TokenFees {
        uint128 totalOwed;
        uint128 protocolOwed;
    }

    /// @custom:storage-location erc7201:tronpaymaster.storage.PermitAccount
    struct AccountStorage {
        Hot hot;
        address signer; // 0 = owner; its own (read-mostly) slot
        mapping(address token => TokenFees) fees; // tokens other than FEE_TOKEN
        mapping(address token => mapping(address beneficiary => uint256)) feeOwed;
    }

    constructor(address factory, address feeRecipient, address feeToken) TIP712("TronPaymaster", "1") {
        FACTORY = factory;
        FEE_RECIPIENT = feeRecipient;
        FEE_TOKEN = feeToken;
        SELF = address(this);
    }

    modifier onlyOwner() {
        if (msg.sender != _owner()) revert NotOwner();
        _;
    }

    /// @dev Accepts TRX on clones so the owner can fund or recover it.
    receive() external payable {
        if (address(this) == SELF) revert DirectCallForbidden();
    }

    // ---------------------------------------------------------------- permits

    /// @inheritdoc IPermitAccount
    function permitTransfer(Permit calldata p, uint256 relayerFee, address feeRecipient, bytes32 r, bytes32 vs)
        external
    {
        _permitTransfer(p, relayerFee, feeRecipient, r, vs);
    }

    /// @notice `permitTransfer` with tightly packed calldata: 197 bytes instead
    /// of 388, almost halving the per-transaction bandwidth (1 sun-point per
    /// byte on Tron). The digest is identical to `permitTransfer`'s, so the
    /// same TIP-712 signature works for either entrypoint; `owner` is read
    /// from the clone's immutable args instead of being sent.
    /// Layout after the selector (big-endian, no ABI padding):
    /// token:20 | to:20 | value:12 | maxFee:12 | relayer:20 | deadline:5 |
    /// nonce:8 | relayerFee:12 | feeRecipient:20 | r:32 | vs:32
    function permitTransferPacked() external {
        bytes calldata d = msg.data[4:];
        if (d.length != 193) revert InvalidPackedCalldata();
        Permit memory p;
        p.token = address(bytes20(d[0:20]));
        p.owner = _owner();
        p.to = address(bytes20(d[20:40]));
        p.value = uint96(bytes12(d[40:52]));
        p.maxFee = uint96(bytes12(d[52:64]));
        p.relayer = address(bytes20(d[64:84]));
        p.deadline = uint40(bytes5(d[84:89]));
        p.nonce = uint64(bytes8(d[89:97]));
        _permitTransfer(p, uint96(bytes12(d[97:109])), address(bytes20(d[109:129])), bytes32(d[129:161]), bytes32(d[161:193]));
    }

    function _permitTransfer(Permit memory p, uint256 relayerFee, address feeRecipient, bytes32 r, bytes32 vs) private {
        AccountStorage storage $ = _s();
        Hot memory hot = $.hot; // one read of the packed slot

        // Cheapest checks first: a relayer simulating a bad permit learns fast.
        if (block.timestamp > p.deadline) revert Expired();
        if (p.nonce != hot.nonce) revert BadNonce();
        {
            // Scoped: legacy codegen (required for the Tron build) has no via-IR
            // stack relief, so short-lived locals must not outlive the checks.
            address accountOwner = _owner();
            if (p.owner != accountOwner) revert BadOwner();
            if (p.relayer != address(0) && feeRecipient != p.relayer) revert RelayerMismatch();
            if (relayerFee != 0 && (feeRecipient == address(0) || feeRecipient == address(this))) revert InvalidRecipient();
            if (p.to == address(0) || p.to == address(this)) revert InvalidRecipient();
            if (p.value == 0) revert ZeroValue();

            address signer_ = $.signer;
            if (ECDSA.recover(_hashTypedDataV4(_structHash(p)), r, vs) != (signer_ == address(0) ? accountOwner : signer_)) {
                revert BadSignature();
            }
        }

        // Reverts while the protocol is paused.
        uint256 protocolFee = IPaymasterFactory(FACTORY).activeProtocolFee(p.token, p.value);
        if (relayerFee + protocolFee > p.maxFee) revert FeeExceedsMax();

        // Effects.
        // Checked on purpose: at type(uint64).max this reverts instead of
        // wrapping to 0, which would re-enable every previously executed permit.
        hot.nonce = hot.nonce + 1;
        // The protocol's own relayer accrues into protocolOwed, which shares a
        // slot with totalOwed (and, for FEE_TOKEN, with the nonce): a fee-token
        // permit through the protocol relayer makes ONE storage write where the
        // naive layout made three, and an account's first permit avoids two
        // 20k zero->nonzero slots. claimFees already pays protocolOwed to
        // FEE_RECIPIENT, so payouts are identical; only the
        // feeOwed(token, FEE_RECIPIENT) view reads 0.
        bool toProtocol = feeRecipient == FEE_RECIPIENT;
        uint256 owedAfter;
        if (p.token == FEE_TOKEN) {
            owedAfter = uint256(hot.totalOwed) + relayerFee + protocolFee;
            hot.totalOwed = owedAfter.toUint96();
            hot.protocolOwed = (uint256(hot.protocolOwed) + (toProtocol ? relayerFee + protocolFee : protocolFee)).toUint96();
        } else {
            // Read unconditionally: the post-transfer backing check below must
            // count this token's PREVIOUS accruals even on a zero-fee permit.
            TokenFees memory f = $.fees[p.token];
            owedAfter = uint256(f.totalOwed) + relayerFee + protocolFee;
            if (relayerFee != 0 || protocolFee != 0) {
                f.totalOwed = owedAfter.toUint128();
                f.protocolOwed = (uint256(f.protocolOwed) + (toProtocol ? relayerFee + protocolFee : protocolFee)).toUint128();
                $.fees[p.token] = f;
            }
        }
        $.hot = hot; // single packed write
        if (relayerFee != 0 && !toProtocol) $.feeOwed[p.token][feeRecipient] += relayerFee;

        // Interaction, then prove accrued fees are still backed. send() returns
        // the post-transfer balance, saving a third balanceOf call (on mainnet
        // USDT every call into the token pays the dynamic-energy penalty).
        if (TokenTransfer.send(p.token, p.to, p.value) < owedAfter) revert InsufficientAvailable();

        emit PermitExecuted(p.nonce, p.token, p.to, p.value, relayerFee);
    }

    // ------------------------------------------------------------ owner exits

    /// @inheritdoc IPermitAccount
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        if (amount > available(token)) revert InsufficientAvailable();
        if (amount != 0) TokenTransfer.send(token, to, amount);
        emit Withdrawn(token, to, amount);
    }

    /// @inheritdoc IPermitAccount
    function withdrawTRX(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        if (amount > address(this).balance) revert InsufficientAvailable();
        if (amount != 0) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TokenTransfer.TransferFailed();
        }
        emit Withdrawn(address(0), to, amount);
    }

    /// @inheritdoc IPermitAccount
    function invalidateNonces(uint256 newNonce) external onlyOwner {
        AccountStorage storage $ = _s();
        // < max: the max nonce stays unreachable, so the checked increment in
        // permitTransfer can never be one step from wrapping.
        if (newNonce <= $.hot.nonce || newNonce >= type(uint64).max) revert InvalidNonce();
        $.hot.nonce = uint64(newNonce);
        emit NoncesInvalidated(newNonce);
    }

    /// @inheritdoc IPermitAccount
    /// @dev Gated on `msg.sender`, which follows Tron account permissions: an
    /// owner whose account has moved to multi-signature can revoke the original
    /// key's permit authority here. `address(0)` restores the owner key.
    function setSigner(address newSigner) external onlyOwner {
        _s().signer = newSigner;
        emit SignerUpdated(newSigner);
    }

    // ----------------------------------------------------------------- fees

    /// @inheritdoc IPermitAccount
    /// @dev Callable by the beneficiary itself, or by the factory on behalf of
    /// its caller (`claimMany`). Pays only that beneficiary's accrual; the fee
    /// recipient additionally collects the protocol fee.
    function claimFees(address token, address beneficiary, address to) external returns (uint256 amount) {
        if (address(this) == SELF) revert DirectCallForbidden();
        if (msg.sender != beneficiary && msg.sender != FACTORY) revert NotAuthorized();
        if (to == address(0) || to == address(this)) revert InvalidRecipient();

        AccountStorage storage $ = _s();
        amount = $.feeOwed[token][beneficiary];
        if (token == FEE_TOKEN) {
            Hot memory hot = $.hot;
            if (beneficiary == FEE_RECIPIENT) {
                amount += hot.protocolOwed;
                hot.protocolOwed = 0;
            }
            if (amount == 0) return 0;
            if ($.feeOwed[token][beneficiary] != 0) $.feeOwed[token][beneficiary] = 0;
            hot.totalOwed = uint96(uint256(hot.totalOwed) - amount); // amount is a component of totalOwed
            $.hot = hot;
        } else {
            TokenFees memory f = $.fees[token];
            if (beneficiary == FEE_RECIPIENT) {
                amount += f.protocolOwed;
                f.protocolOwed = 0;
            }
            if (amount == 0) return 0;
            $.feeOwed[token][beneficiary] = 0;
            f.totalOwed -= uint128(amount); // amount is a component of totalOwed
            $.fees[token] = f;
        }

        TokenTransfer.send(token, to, amount);
        emit FeesClaimed(token, beneficiary, to, amount);
    }

    // ----------------------------------------------------------------- views

    function owner() external view returns (address) {
        return _owner();
    }

    function signer() external view returns (address) {
        address s = _s().signer;
        return s == address(0) ? _owner() : s;
    }

    function nonce() external view returns (uint256) {
        return _s().hot.nonce;
    }

    function totalOwed(address token) public view returns (uint256) {
        return token == FEE_TOKEN ? _s().hot.totalOwed : _s().fees[token].totalOwed;
    }

    function protocolOwed(address token) external view returns (uint256) {
        return token == FEE_TOKEN ? _s().hot.protocolOwed : _s().fees[token].protocolOwed;
    }

    function feeOwed(address token, address beneficiary) external view returns (uint256) {
        return _s().feeOwed[token][beneficiary];
    }

    /// @notice Balance the owner can withdraw: everything not owed as fees.
    function available(address token) public view returns (uint256) {
        uint256 bal = ITRC20(token).balanceOf(address(this));
        uint256 owed = totalOwed(token);
        return bal > owed ? bal - owed : 0;
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function hashPermit(Permit calldata p) external view returns (bytes32) {
        return _hashTypedDataV4(_structHash(p));
    }

    error InvalidPackedCalldata();

    // -------------------------------------------------------------- internal

    function _structHash(Permit memory p) private pure returns (bytes32) {
        return keccak256(
            abi.encode(PERMIT_TYPEHASH, p.token, p.owner, p.to, p.value, p.maxFee, p.relayer, p.deadline, p.nonce)
        );
    }

    function _s() private pure returns (AccountStorage storage $) {
        assembly ("memory-safe") {
            $.slot := STORAGE_SLOT
        }
    }

    function _owner() private view returns (address o) {
        if (address(this) == SELF) revert DirectCallForbidden();
        bytes memory a = Clones.fetchCloneArgs(address(this));
        assembly ("memory-safe") {
            o := shr(96, mload(add(a, 0x20)))
        }
    }
}
