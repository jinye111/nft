// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ============ Permit2 接口定义（来自 Uniswap permit2 仓库） ============
// 参考: https://github.com/Uniswap/permit2/blob/main/src/interfaces/ISignatureTransfer.sol
interface ISignatureTransfer {
    /// @notice Token 与对应的可转账金额
    struct TokenPermissions {
        // ERC20 代币地址
        address token;
        // 允许 spender 转账的最大数量
        uint256 amount;
    }

    /// @notice 用户签名的单笔转账许可信息
    struct PermitTransferFrom {
        TokenPermissions permitted;
        // 防止签名重放的 unordered nonce
        uint256 nonce;
        // 签名过期时间
        uint256 deadline;
    }

    /// @notice 调用方（本合约）实际请求转账的目标地址与数量
    struct SignatureTransferDetails {
        // 接收方地址
        address to;
        // 实际请求转账的数量（必须 ≤ permitted.amount）
        uint256 requestedAmount;
    }

    /// @notice 使用签名许可转账代币
    /// @dev 内部会校验 deadline、nonce、签名者 = owner
    function permitTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

// Permit2 主合约接口（继承 AllowanceTransfer 与 SignatureTransfer）
interface IPermit2 is ISignatureTransfer {}

// ============ 其他原有接口（保持不变） ============
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IERC20Permit is IERC20 {
    function permit(
        address owner, address spender, uint256 value,
        uint256 deadline, uint8 v, bytes32 r, bytes32 s
    ) external;
    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface ITokenReceiver {
    function tokensReceived(address from, uint256 amount) external returns (bool);
}

// （ExtendedERC20 合约保持原样，此处省略）...
contract ExtendedERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) balances;
    mapping(address => mapping(address => uint256)) allowances;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        name = "ExtendedERC20"; symbol = "EERC20"; decimals = 18;
        totalSupply = 100000000 * 10**uint256(decimals);
        balances[msg.sender] = totalSupply;
    }

    function balanceOf(address _owner) public view returns (uint256) { return balances[_owner]; }

    function transfer(address _to, uint256 _value) public returns (bool) {
        require(balances[msg.sender] >= _value, "ERC20: transfer amount exceeds balance");
        require(_to != address(0), "ERC20: transfer to the zero address");
        balances[msg.sender] -= _value;
        balances[_to] += _value;
        emit Transfer(msg.sender, _to, _value);
        return true;
    }

    function transferWithCallback(address _to, uint256 _value) public returns (bool) {
        require(balances[msg.sender] >= _value, "ERC20: transfer amount exceeds balance");
        require(_to != address(0), "ERC20: transfer to the zero address");
        balances[msg.sender] -= _value;
        balances[_to] += _value;
        emit Transfer(msg.sender, _to, _value);
        if (isContract(_to)) {
            try ITokenReceiver(_to).tokensReceived(msg.sender, _value) returns (bool) {}
            catch {}
        }
        return true;
    }

    function transferFrom(address _from, address _to, uint256 _value) public returns (bool) {
        require(balances[_from] >= _value, "ERC20: transfer amount exceeds balance");
        require(allowances[_from][msg.sender] >= _value, "ERC20: transfer amount exceeds allowance");
        require(_to != address(0), "ERC20: transfer to the zero address");
        balances[_from] -= _value;
        balances[_to] += _value;
        allowances[_from][msg.sender] -= _value;
        emit Transfer(_from, _to, _value);
        return true;
    }

    function approve(address _spender, uint256 _value) public returns (bool) {
        require(_spender != address(0), "ERC20: approve to the zero address");
        allowances[msg.sender][_spender] = _value;
        emit Approval(msg.sender, _spender, _value);
        return true;
    }

    function allowance(address _owner, address _spender) public view returns (uint256) {
        return allowances[_owner][_spender];
    }

    function isContract(address _addr) private view returns (bool) {
        uint32 size;
        assembly { size := extcodesize(_addr) }
        return (size > 0);
    }
}

// ============ TokenBank（保持原样） ============
contract TokenBank {
    IERC20Permit public token;
    mapping(address => uint256) public deposits;
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    constructor(address _tokenAddress) {
        require(_tokenAddress != address(0), "TokenBank: token address cannot be zero");
        token = IERC20Permit(_tokenAddress);
    }

    function deposit(uint256 _amount) external {
        require(_amount > 0, "TokenBank: deposit amount must be greater than zero");
        require(token.balanceOf(msg.sender) >= _amount, "TokenBank: insufficient token balance");
        bool success = token.transferFrom(msg.sender, address(this), _amount);
        require(success, "TokenBank: transfer failed");
        deposits[msg.sender] += _amount;
        emit Deposit(msg.sender, _amount);
    }

    function permitDeposit(
        uint256 _amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s
    ) external {
        require(_amount > 0, "TokenBank: deposit amount must be greater than zero");
        token.permit(msg.sender, address(this), _amount, deadline, v, r, s);
        bool success = token.transferFrom(msg.sender, address(this), _amount);
        require(success, "TokenBank: transfer failed");
        deposits[msg.sender] += _amount;
        emit Deposit(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) external {
        require(_amount > 0, "TokenBank: withdraw amount must be greater than zero");
        require(deposits[msg.sender] >= _amount, "TokenBank: insufficient deposit balance");
        deposits[msg.sender] -= _amount;
        bool success = token.transfer(msg.sender, _amount);
        require(success, "TokenBank: transfer failed");
        emit Withdraw(msg.sender, _amount);
    }

    function balanceOf(address _user) external view returns (uint256) {
        return deposits[_user];
    }
}

// ============ TokenBankV2（新增 depositWithPermit2） ============
contract TokenBankV2 is TokenBank, ITokenReceiver {
    ExtendedERC20 public extendedToken;

    // Permit2 合约的固定部署地址（在所有支持的链上都相同）
    address public constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    IPermit2 public immutable permit2;

    constructor(address _tokenAddress) TokenBank(_tokenAddress) {
        extendedToken = ExtendedERC20(_tokenAddress);
        // 绑定 Permit2 合约
        permit2 = IPermit2(PERMIT2_ADDRESS);
    }

    /// @notice 通过 Uniswap Permit2 进行签名授权转账存款
    /// @param _amount        用户希望存入的数量（必须 ≤ permit.permitted.amount）
    /// @param _nonce         用户签名中的 unordered nonce（防止重放）
    /// @param _deadline      签名过期时间戳
    /// @param _signature     用户对 PermitTransferFrom 结构的 65/64/… 字节签名
    ///
    /// 前置条件：用户必须先一次性执行 token.approve(PERMIT2_ADDRESS, type(uint256).max)
    ///           之后 Permit2 才能代表用户搬运代币
    function depositWithPermit2(
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature
    ) external {
        require(_amount > 0, "TokenBank: deposit amount must be greater than zero");

        // 1. 构造签名对应的数据结构
        //    用户签名时必须对 TokenPermissions{token, amount} + nonce + deadline 进行 EIP-712 签名
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({
                token: address(token),   // 关键：必须限定为本 Bank 支持的代币
                amount: _amount          // 最大可转账数量
            }),
            nonce: _nonce,
            deadline: _deadline
        });

        // 2. 构造实际转账细节：把代币转入本 Bank 合约
        //    SignatureTransferDetails.to 必须是 address(this)，否则签名会被 Permit2 校验拒绝或被绕过
        ISignatureTransfer.SignatureTransferDetails memory transferDetails = ISignatureTransfer.SignatureTransferDetails({
            to: address(this),
            requestedAmount: _amount
        });

        // 3. 调用 Permit2 的 permitTransferFrom
        //    Permit2 内部会：
        //    - 校验 block.timestamp <= _deadline
        //    - 使用 unordered nonce bitmap 防止签名重放
        //    - 用 EIP-712 / EIP-1271 验签，恢复出 owner = msg.sender
        //    - 通过 token.transferFrom(owner, transferDetails.to, requestedAmount) 转账
        //      （前提：用户已预先 approve 过 Permit2 合约）
        permit2.permitTransferFrom(
            permit,
            transferDetails,
            msg.sender,     // owner：必须等于签名者
            _signature
        );

        // 4. Permit2 内部执行 transferFrom 时，Transfer 事件中的 from 是 msg.sender
        //    为了保险起见，再校验一下本合约确实收到了代币（防御非标准 ERC20）
        require(
            extendedToken.balanceOf(address(this)) >= _amount,
            "TokenBankV2: permit2 transfer did not deliver tokens"
        );

        // 5. 更新存款记录并触发事件
        deposits[msg.sender] += _amount;
        emit Deposit(msg.sender, _amount);
    }

    function tokensReceived(address from, uint256 amount) external override returns (bool) {
        require(msg.sender == address(token), "TokenBankV2: caller is not the token contract");
        deposits[from] += amount;
        emit Deposit(from, amount);
        return true;
    }
}
