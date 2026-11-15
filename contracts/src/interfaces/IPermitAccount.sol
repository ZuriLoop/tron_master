// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @notice A signed instruction to move `value` of `token` from the account to `to`.
/// @dev The recipient receives exactly `value`. Fees are debited separately and
/// capped by `maxFee` (relayer fee + protocol fee). `relayer` binds the fee
/// credit to one relayer; zero means any relayer may submit.
struct Permit {
    address token;
    address owner;
    address to;
    uint256 value;
    uint256 maxFee;
    address relayer;
    uint256 deadline;
    uint256 nonce;
}

interface IPermitAccount {
    /// @dev protocolFee and feeRecipient are derivable (factory config and the
    /// submitting transaction's calldata) and intentionally not emitted.
    event PermitExecuted(uint256 indexed nonce, address indexed token, address indexed to, uint256 value, uint256 relayerFee);
    event FeesClaimed(address indexed token, address indexed beneficiary, address to, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event NoncesInvalidated(uint256 newNonce);
    event SignerUpdated(address signer);

    error Expired();
    error BadNonce();
    error BadOwner();
    error BadSignature();
    error RelayerMismatch();
    error FeeExceedsMax();
    error InsufficientAvailable();
    error NotOwner();
    error NotAuthorized();
    error InvalidRecipient();
    error ZeroValue();
    error InvalidNonce();
    error DirectCallForbidden();

    function permitTransfer(Permit calldata p, uint256 relayerFee, address feeRecipient, bytes32 r, bytes32 vs)
        external;
    function withdraw(address token, address to, uint256 amount) external;
    function withdrawTRX(address payable to, uint256 amount) external;
    function claimFees(address token, address beneficiary, address to) external returns (uint256 amount);
    function invalidateNonces(uint256 newNonce) external;
    function setSigner(address newSigner) external;

    function owner() external view returns (address);
    function signer() external view returns (address);
    function nonce() external view returns (uint256);
    function totalOwed(address token) external view returns (uint256);
    function protocolOwed(address token) external view returns (uint256);
    function feeOwed(address token, address beneficiary) external view returns (uint256);
    function available(address token) external view returns (uint256);
    function domainSeparator() external view returns (bytes32);
    function hashPermit(Permit calldata p) external view returns (bytes32);
}
