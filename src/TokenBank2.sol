// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// 基础 IERC20 接口
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

// 支持 EIP-2612 Permit 的接口
interface IERC20Permit is IERC20 {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

// 定义接收代币回调的接口
interface ITokenReceiver {
    function tokensReceived(address from, uint256 amount) external returns (bool);
}

// 扩展的ERC20合约，添加带有回调功能的转账函数
contract ExtendedERC20 {
    string public name; 
    string public symbol; 
    uint8 public decimals; 

    uint256 public totalSupply; 

    mapping (address => uint256) balances; 

    mapping (address => mapping (address => uint256)) allowances; 

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        name = "ExtendedERC20";
        symbol = "EERC20";
        decimals = 18;
        totalSupply = 100000000 * 10**uint256(decimals); // 100,000,000 tokens
        
        balances[msg.sender] = totalSupply;  
    }

    function balanceOf(address _owner) public view returns (uint256 balance) {
        return balances[_owner];
    }

    function transfer(address _to, uint256 _value) public returns (bool success) {
        require(balances[msg.sender] >= _value, "ERC20: transfer amount exceeds balance");
        require(_to != address(0), "ERC20: transfer to the zero address");
        
        balances[msg.sender] -= _value;
        balances[_to] += _value;

        emit Transfer(msg.sender, _to, _value);  
        return true;   
    }
    
    // 添加带有回调功能的转账函数
    function transferWithCallback(address _to, uint256 _value) public returns (bool success) {
        require(balances[msg.sender] >= _value, "ERC20: transfer amount exceeds balance");
        require(_to != address(0), "ERC20: transfer to the zero address");
        
        balances[msg.sender] -= _value;
        balances[_to] += _value;

        emit Transfer(msg.sender, _to, _value);
        
        // 如果接收方是合约，调用其tokensReceived方法
        if (isContract(_to)) {
            try ITokenReceiver(_to).tokensReceived(msg.sender, _value) returns (bool) {
                // 回调成功
            } catch {
                // 回调失败，但不回滚交易
            }
        }
        
        return true;
    }

    function transferFrom(address _from, address _to, uint256 _value) public returns (bool success) {
        require(balances[_from] >= _value, "ERC20: transfer amount exceeds balance");
        require(allowances[_from][msg.sender] >= _value, "ERC20: transfer amount exceeds allowance");
        require(_to != address(0), "ERC20: transfer to the zero address");
        
        balances[_from] -= _value;
        balances[_to] += _value;
        allowances[_from][msg.sender] -= _value;
        
        emit Transfer(_from, _to, _value); 
        return true; 
    }

    function approve(address _spender, uint256 _value) public returns (bool success) {
        require(_spender != address(0), "ERC20: approve to the zero address");
        
        allowances[msg.sender][_spender] = _value;

        emit Approval(msg.sender, _spender, _value); 
        return true; 
    }

    function allowance(address _owner, address _spender) public view returns (uint256 remaining) {   
        return allowances[_owner][_spender];
    }
    
    // 检查地址是否为合约
    function isContract(address _addr) private view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }
        return (size > 0);
    }
}

contract TokenBank {
    // 代币合约地址（支持 Permit）
    IERC20Permit public token;
    
    // 记录每个用户存入的代币数量
    mapping(address => uint256) public deposits;
    
    // 存款和取款事件
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    
    // 构造函数，设置代币合约地址
    constructor(address _tokenAddress) {
        require(_tokenAddress != address(0), "TokenBank: token address cannot be zero");
        token = IERC20Permit(_tokenAddress);
    }
    
    // 普通存款（需要先 approve）
    function deposit(uint256 _amount) external {
        require(_amount > 0, "TokenBank: deposit amount must be greater than zero");
        require(token.balanceOf(msg.sender) >= _amount, "TokenBank: insufficient token balance");
        
        bool success = token.transferFrom(msg.sender, address(this), _amount);
        require(success, "TokenBank: transfer failed");
        
        deposits[msg.sender] += _amount;
        
        emit Deposit(msg.sender, _amount);
    }

    /**
     * @dev 使用 EIP-2612 Permit 进行存款（离线签名授权）
     * @param _amount 存款金额
     * @param deadline 签名过期时间
     * @param v 签名参数
     * @param r 签名参数
     * @param s 签名参数
     */
    function permitDeposit(
        uint256 _amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(_amount > 0, "TokenBank: deposit amount must be greater than zero");
        
        // 1. 调用 token 的 permit，使用签名完成授权（spender = 本合约）
        token.permit(
            msg.sender,      // owner
            address(this),   // spender
            _amount,         // value
            deadline,
            v,
            r,
            s
        );
        
        // 2. 执行转账
        bool success = token.transferFrom(msg.sender, address(this), _amount);
        require(success, "TokenBank: transfer failed");
        
        // 3. 更新存款记录
        deposits[msg.sender] += _amount;
        
        emit Deposit(msg.sender, _amount);
    }
    
    // 提取代币
    function withdraw(uint256 _amount) external {
        require(_amount > 0, "TokenBank: withdraw amount must be greater than zero");
        require(deposits[msg.sender] >= _amount, "TokenBank: insufficient deposit balance");
        
        // 先减少记录，再转账，防止重入
        deposits[msg.sender] -= _amount;
        
        bool success = token.transfer(msg.sender, _amount);
        require(success, "TokenBank: transfer failed");
        
        emit Withdraw(msg.sender, _amount);
    }
    
    // 查询用户在银行中的存款余额
    function balanceOf(address _user) external view returns (uint256) {
        return deposits[_user];
    }
}

// TokenBankV2合约，支持直接通过transferWithCallback存入代币
contract TokenBankV2 is TokenBank, ITokenReceiver {
    // 扩展的ERC20代币合约地址
    ExtendedERC20 public extendedToken;
    
    // 构造函数，设置扩展的ERC20代币合约地址
    constructor(address _tokenAddress) TokenBank(_tokenAddress) {
        extendedToken = ExtendedERC20(_tokenAddress);
    }
    
    // 实现tokensReceived接口，处理通过transferWithCallback接收到的代币
    function tokensReceived(address from, uint256 amount) external override returns (bool) {
        // 检查调用者是否为代币合约
        require(msg.sender == address(token), "TokenBankV2: caller is not the token contract");
        
        // 更新用户的存款记录
        deposits[from] += amount;
        
        // 触发存款事件
        emit Deposit(from, amount);
        
        return true;
    }
}