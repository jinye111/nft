# <h1 align="center"> Forge Template </h1>

**Template repository for getting started quickly with Foundry projects**

## Deploy MyToken to Sepolia

`MyToken` mints its fixed supply of 1,000 tokens to the account that deploys it.

1. Install Foundry and make sure `forge` is available in your terminal.
2. Copy `.env.example` to `.env`, then set `SEPOLIA_RPC_URL`, `PRIVATE_KEY`, and `ETHERSCAN_API_KEY`. Keep `.env` private.
3. Deploy with automatic Etherscan verification:

```powershell
forge script script/DeployMyToken.s.sol:DeployMyToken `
  --rpc-url sepolia `
  --broadcast `
  --verify
```

When the command finishes, it prints the deployed address and the Etherscan verification result. The source code will be available at `https://sepolia.etherscan.io/address/<DEPLOYED_ADDRESS>#code`.

## Deploy TokenBank locally

Start Anvil in a separate terminal with `anvil`. Set `TOKEN_ADDRESS` in `.env` to the address of an ERC-20 already deployed to that local Anvil chain, such as the local `MyToken` address. `DeployTokenBank` reads the signing key from `PRIVATE_KEY`.

```powershell
forge script script/DeployTokenBank.s.sol:DeployTokenBank `
  --rpc-url anvil `
  --broadcast
```

![Github Actions](https://github.com/foundry-rs/forge-template/workflows/CI/badge.svg)

## Getting Started

Click "Use this template" on [GitHub](https://github.com/foundry-rs/forge-template) to create a new repository with this repo as the initial state.

Or, if your repo already exists, run:
```sh
forge init
forge build
forge test
```

## Writing your first test

All you need is to `import forge-std/Test.sol` and then inherit it from your test contract. Forge-std's Test contract comes with a pre-instatiated [cheatcodes environment](https://book.getfoundry.sh/cheatcodes/), the `vm`. It also has support for [ds-test](https://book.getfoundry.sh/reference/ds-test.html)-style logs and assertions. Finally, it supports Hardhat's [console.log](https://github.com/brockelmore/forge-std/blob/master/src/console.sol). The logging functionalities require `-vvvv`.

```solidity
pragma solidity 0.8.10;

import "forge-std/Test.sol";

contract ContractTest is Test {
    function testExample() public {
        vm.roll(100);
        console.log(1);
        emit log("hi");
        assertTrue(true);
    }
}
```

## Development

This project uses [Foundry](https://getfoundry.sh). See the [book](https://book.getfoundry.sh/getting-started/installation.html) for instructions on how to install and use Foundry.
