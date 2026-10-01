// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ScriptBase} from "./ScriptBase.sol";
import {MyToken} from "../src/MyToken.sol";

/// @notice Deploys MyToken and mints its fixed supply to the broadcasting account.
contract DeployMyToken is ScriptBase {
    function run() external returns (MyToken token) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        token = new MyToken();
        vm.stopBroadcast();
    }
}
