// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract SimpleMultiSigWallet {
    address[] public owners;
    uint256 public required;
    mapping(address => bool) public isOwner;
    mapping(uint256 => mapping(address => bool)) public confirmations;

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmCount;
    }

    Transaction[] public transactions;

    event Deposit(address indexed sender, uint256 amount);
    event Submission(uint256 indexed transactionId);
    event Confirmation(address indexed sender, uint256 indexed transactionId);
    event Execution(uint256 indexed transactionId);
    event ExecutionFailure(uint256 indexed transactionId);
    event OwnerAddition(address indexed owner);
    event OwnerRemoval(address indexed owner);
    event RequirementChange(uint256 required);

    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not an owner");
        _;
    }

    modifier transactionExists(uint256 transactionId) {
        require(transactionId < transactions.length, "Transaction does not exist");
        _;
    }

    modifier confirmed(uint256 transactionId, address owner) {
        require(confirmations[transactionId][owner], "Transaction not confirmed by this owner");
        _;
    }

    modifier notConfirmed(uint256 transactionId, address owner) {
        require(!confirmations[transactionId][owner], "Transaction already confirmed");
        _;
    }

    modifier notExecuted(uint256 transactionId) {
        require(!transactions[transactionId].executed, "Transaction already executed");
        _;
    }

    constructor(address[] memory _owners, uint256 _required) {
        require(_owners.length > 0, "Owners required");
        require(_required > 0 && _required <= _owners.length, "Invalid required number");

        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(owner != address(0), "Invalid owner");
            require(!isOwner[owner], "Duplicate owner");

            isOwner[owner] = true;
            owners.push(owner);
        }
        required = _required;
    }

    receive() external payable {
        if (msg.value > 0) {
            emit Deposit(msg.sender, msg.value);
        }
    }

    function addOwner(address owner) public onlyOwner {
        require(owner != address(0), "Invalid owner");
        require(!isOwner[owner], "Already an owner");

        isOwner[owner] = true;
        owners.push(owner);
        emit OwnerAddition(owner);
    }

    function removeOwner(address owner) public onlyOwner {
        require(isOwner[owner], "Not an owner");
        require(owners.length > required, "Cannot remove owner below required");

        isOwner[owner] = false;

        for (uint256 i = 0; i < owners.length - 1; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                break;
            }
        }
        owners.pop();
        emit OwnerRemoval(owner);
    }

    function replaceOwner(address owner, address newOwner) public onlyOwner {
        require(isOwner[owner], "Not an owner");
        require(newOwner != address(0), "Invalid new owner");
        require(!isOwner[newOwner], "Already an owner");

        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = newOwner;
                break;
            }
        }

        isOwner[owner] = false;
        isOwner[newOwner] = true;
        emit OwnerRemoval(owner);
        emit OwnerAddition(newOwner);
    }

    function changeRequirement(uint256 _required) public onlyOwner {
        require(_required > 0 && _required <= owners.length, "Invalid required");
        required = _required;
        emit RequirementChange(_required);
    }

    function submitTransaction(address to, uint256 value, bytes memory data)
        public
        onlyOwner
        returns (uint256 transactionId)
    {
        transactionId = transactions.length;
        transactions.push(Transaction({
            to: to,
            value: value,
            data: data,
            executed: false,
            confirmCount: 0
        }));

        emit Submission(transactionId);
        confirmTransaction(transactionId);
    }

    function confirmTransaction(uint256 transactionId)
        public
        onlyOwner
        transactionExists(transactionId)
        notConfirmed(transactionId, msg.sender)
        notExecuted(transactionId)
    {
        confirmations[transactionId][msg.sender] = true;
        transactions[transactionId].confirmCount++;
        emit Confirmation(msg.sender, transactionId);

        if (transactions[transactionId].confirmCount >= required) {
            executeTransaction(transactionId);
        }
    }

    function executeTransaction(uint256 transactionId)
        public
        onlyOwner
        transactionExists(transactionId)
        notExecuted(transactionId)
    {
        require(transactions[transactionId].confirmCount >= required, "Not enough confirmations");

        Transaction storage txn = transactions[transactionId];
        txn.executed = true;

        (bool success, ) = txn.to.call{value: txn.value}(txn.data);
        if (success) {
            emit Execution(transactionId);
        } else {
            emit ExecutionFailure(transactionId);
            txn.executed = false;
        }
    }

    function revokeConfirmation(uint256 transactionId)
        public
        onlyOwner
        confirmed(transactionId, msg.sender)
        notExecuted(transactionId)
    {
        confirmations[transactionId][msg.sender] = false;
        transactions[transactionId].confirmCount--;
    }

    function getOwners() public view returns (address[] memory) {
        return owners;
    }

    function getTransactionCount() public view returns (uint256) {
        return transactions.length;
    }

    function getTransaction(uint256 transactionId)
        public
        view
        transactionExists(transactionId)
        returns (address to, uint256 value, bytes memory data, bool executed, uint256 confirmCount)
    {
        Transaction storage txn = transactions[transactionId];
        return (txn.to, txn.value, txn.data, txn.executed, txn.confirmCount);
    }

    function getConfirmations(uint256 transactionId)
        public
        view
        transactionExists(transactionId)
        returns (address[] memory)
    {
        address[] memory confirmationsList = new address[](transactions[transactionId].confirmCount);
        uint256 count = 0;
        for (uint256 i = 0; i < owners.length; i++) {
            address owner = owners[i];
            if (confirmations[transactionId][owner]) {
                confirmationsList[count] = owner;
                count++;
            }
        }
        return confirmationsList;
    }

    function isConfirmed(uint256 transactionId)
        public
        view
        transactionExists(transactionId)
        returns (bool)
    {
        return transactions[transactionId].confirmCount >= required;
    }
}