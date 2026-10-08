// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ScriptBase} from "./ScriptBase.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Vesting} from "../src/Vesting.sol";

/// @notice 部署 Vesting 合约，并转入 100 万 ERC20（Cliff 从部署时刻开始计算）。
/// @dev 需要的环境变量：PRIVATE_KEY、TOKEN_ADDRESS（锁定的 ERC20）、BENEFICIARY（受益人）。
///      部署者的账户需要持有至少 100 万 ERC20，脚本会自动 approve 并调用 fund() 完成转入。
contract DeployVesting is ScriptBase {
    function run() external returns (Vesting vesting) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address beneficiary = vm.envAddress("BENEFICIARY");
        IERC20 lockedToken = IERC20(tokenAddress);

        vm.startBroadcast(deployerPrivateKey);
        vesting = new Vesting(beneficiary, lockedToken);

        // 授权并转入 100 万 ERC20，Cliff 从部署这一刻开始计算。
        lockedToken.approve(address(vesting), vesting.LOCKED_AMOUNT());
        vesting.fund();
        vm.stopBroadcast();
    }
}
