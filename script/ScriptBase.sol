// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Minimal subset of Foundry cheatcodes used by this project's scripts.
interface Vm {
    function envAddress(string calldata name) external returns (address value);

    function envUint(string calldata name) external returns (uint256 value);

    function startBroadcast(uint256 privateKey) external;

    function stopBroadcast() external;
}

/// @dev Lightweight replacement for forge-std's Script base contract.
abstract contract ScriptBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
}
