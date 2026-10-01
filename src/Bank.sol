// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice 一个简单的 ETH 银行合约，记录每个存款地址的余额，并追踪存款金额前 3 名。
/// 只有管理员可以提取合约中的资金。
contract Bank {
    address public admin;
    mapping( address => uint256) public balances;
    address[] public depositors;
    mapping(address => bool) public isDepositor;
    address[3] public topDepositors;
    uint256[3] public topAmounts;

    event Deposited(address indexed depositor, uint256 amount);
    event Withdrawn(address indexed admin, uint256 amount);
    event TopDepositorsUpdated(address[3] topDepositors, uint256[3] topAmounts);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function deposit() public payable virtual {
        require(msg.value > 0, "Deposit amount must be greater than 0");
        
        // 更新余额
        balances[msg.sender] += msg.value;
        
        // 如果是首次存款，添加到depositors列表
        if (!isDepositor[msg.sender]) {
            isDepositor[msg.sender] = true;
            depositors.push(msg.sender);
        }
        
        // 更新排行榜
        updateTopDepositors();
        
        
        emit Deposited(msg.sender, msg.value);
    }

    function updateTopDepositors() internal {
        // 如果存款人数少于3人，特殊处理
        uint256 count = depositors.length;
        uint256 limit = count < 3 ? count : 3;
        
        // 如果depositors为空，清空排行榜
        if (count == 0) {
            for (uint256 i = 0; i < 3; i++) {
                topDepositors[i] = address(0);
                topAmounts[i] = 0;
            }
            return;
        }
        
        // 创建临时数组存储所有地址及其余额
        address[] memory tempAddresses = new address[](count);
        uint256[] memory tempAmounts = new uint256[](count);
        
        for (uint256 i = 0; i < count; i++) {
            tempAddresses[i] = depositors[i];
            tempAmounts[i] = balances[depositors[i]];
        }
        
        // 使用冒泡排序找出前3名
        for (uint256 i = 0; i < limit; i++) {
            uint256 maxIndex = i;
            for (uint256 j = i + 1; j < count; j++) {
                if (tempAmounts[j] > tempAmounts[maxIndex]) {
                    maxIndex = j;
                }
            }
            
            // 交换位置
            if (maxIndex != i) {
                (tempAddresses[i], tempAddresses[maxIndex]) = (tempAddresses[maxIndex], tempAddresses[i]);
                (tempAmounts[i], tempAmounts[maxIndex]) = (tempAmounts[maxIndex], tempAmounts[i]);
            }
            
            // 更新排行榜
            topDepositors[i] = tempAddresses[i];
            topAmounts[i] = tempAmounts[i];
        }
        
        // 如果存款人数少于3，清空剩余位置
        for (uint256 i = limit; i < 3; i++) {
            topDepositors[i] = address(0);
            topAmounts[i] = 0;
        }
        
        emit TopDepositorsUpdated(topDepositors, topAmounts);
    }

    function withdraw() external virtual  onlyAdmin {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        
        (bool success, ) = payable(admin).call{value: balance}("");
        require(success, "Transfer failed");
        
        emit Withdrawn(admin, balance);
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}