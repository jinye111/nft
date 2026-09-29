// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title AirdropToken
/// @notice 支持 EIP-2612 permit 的固定发行量 ERC20 代币。
contract AirdropToken is ERC20, ERC20Permit {
    uint256 public constant INITIAL_SUPPLY = 1_000 * 10 ** 18;

    constructor() ERC20("AirdropToken", "ADT") ERC20Permit("AirdropToken") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
