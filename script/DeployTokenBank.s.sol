// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ScriptBase} from "./ScriptBase.sol";
import {TokenBank} from "../src/TokenBank.sol";

/// @notice Deploys TokenBank for an existing ERC-20 token.
contract DeployTokenBank is ScriptBase {
    function run() external returns (TokenBank tokenBank) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);
        tokenBank = new TokenBank(tokenAddress);
        vm.stopBroadcast();
    }
}
