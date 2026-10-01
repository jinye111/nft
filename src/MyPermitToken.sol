// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title MyPermitToken
 * @dev 实现 EIP-2612 (ERC20Permit) 标准的 ERC20 代币
 * 支持通过签名进行 gasless approve（permit）
 */
contract MyPermitToken is ERC20, ERC20Permit {
    /**
     * @dev 构造函数
     * @param initialSupply 初始发行量（按最小单位计算，不包含 decimals）
     * 例如：传入 1_000_000 表示 100 万个代币
     */
    constructor(uint256 initialSupply)
        ERC20("MyPermitToken", "MPT")
        ERC20Permit("MyPermitToken")
    {
        _mint(msg.sender, initialSupply * 10 ** decimals());
    }

    /**
     * @dev 可选：允许合约所有者继续铸造（如需开放增发可取消注释并加上 Ownable）
     */
    // function mint(address to, uint256 amount) external onlyOwner {
    //     _mint(to, amount);
    // }
}