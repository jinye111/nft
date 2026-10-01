// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title MyToken
/// @notice A fixed-supply ERC-20 token with 1,000 tokens minted at deployment.
contract MyToken is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000 * 10 ** 18;

    constructor() ERC20("MyToken", "MTK") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
