// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @dev Minimal TRC-20 base used by the mocks.
abstract contract MockTokenBase {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint8 public constant decimals = 6;
    string public constant symbol = "MOCK";

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @dev Mirrors Tron USDT: moves the funds, then returns `false`.
contract MockUSDT is MockTokenBase {
    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return false;
    }
}

/// @dev A standard token that returns `true`.
contract MockStandardToken is MockTokenBase {
    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }
}

/// @dev Fails silently: returns `false` and moves nothing.
contract MockSilentFailToken is MockTokenBase {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev Takes a 1% fee on transfer, so the sender loses more than the
/// recipient gains. The sender still loses `amount`, so it passes the
/// balance check; listed to document that such tokens are unsupported.
contract MockFeeOnTransferToken is MockTokenBase {
    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 fee = amount / 100;
        _move(msg.sender, to, amount - fee);
        _move(msg.sender, address(0xdead), fee);
        return true;
    }
}

/// @dev Calls back into an arbitrary target during `transfer`.
contract MockReentrantToken is MockTokenBase {
    address public target;
    bytes public payload;
    bool public lastReentrySucceeded;
    bytes public lastReentryData;

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        address t = target;
        if (t != address(0)) {
            target = address(0);
            (lastReentrySucceeded, lastReentryData) = t.call(payload);
        }
        return true;
    }
}
