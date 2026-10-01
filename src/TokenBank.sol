pragma solidity ^0.8.0;

// 导入IERC20接口，用于与BERC20代币交互
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
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
    // 代币合约地址
    IERC20 public token;
    
    // 记录每个用户存入的代币数量
    mapping(address => uint256) public deposits;
    
    // 存款和取款事件
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    
    // 构造函数，设置代币合约地址
    constructor(address _tokenAddress) {
        require(_tokenAddress != address(0), "TokenBank: token address cannot be zero");
        token = IERC20(_tokenAddress);
    }
    
    // 存入代币
    function deposit(uint256 _amount) external {
        // 检查金额是否大于0
        require(_amount > 0, "TokenBank: deposit amount must be greater than zero");
        
        // 检查用户是否有足够的代币
        require(token.balanceOf(msg.sender) >= _amount, "TokenBank: insufficient token balance");
        
        // 将代币从用户转移到合约
        // 注意：用户需要先调用token.approve(tokenBank地址, 金额)来授权TokenBank合约
        bool success = token.transferFrom(msg.sender, address(this), _amount);
        require(success, "TokenBank: transfer failed");
        
        // 更新用户的存款记录
        deposits[msg.sender] += _amount;
        
        // 触发存款事件
        emit Deposit(msg.sender, _amount);
    }
    
    // 提取代币
    function withdraw(uint256 _amount) external {
        // 检查金额是否大于0
        require(_amount > 0, "TokenBank: withdraw amount must be greater than zero");
        
        // 检查用户是否有足够的存款
        require(deposits[msg.sender] >= _amount, "TokenBank: insufficient deposit balance");
        
        // 更新用户的存款记录（先减少记录，再转账，防止重入攻击）
        deposits[msg.sender] -= _amount;
        
        // 将代币从合约转移回用户
        bool success = token.transfer(msg.sender, _amount);
        require(success, "TokenBank: transfer failed");
        
        // 触发提款事件
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