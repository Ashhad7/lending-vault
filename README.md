## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

The invariant suite is split into two campaigns because a single one would have to assert something false. Campaign one holds the price non-decreasing and proves user actions alone cannot create insolvency or push any position below a health factor of 1. Campaign two lets the price move freely, including deliberate crashes, and asserts instead that any insolvency which arises must trace back to a position the protocol has already flagged as liquidatable.

Writing these surfaced three incorrect assumptions before any contract bug: that over-collateralisation could be guaranteed through arbitrary price movement, that a price floor was equivalent to non-decreasing prices, and that a handler's call counts reflect how often a path actually executed. Liquidation is rare under random play, so it is covered primarily by dedicated unit tests rather than by the invariant campaign.

Liquidation always improves a position but does not always restore it above a health factor of 1. Past roughly a 30% drop from the liquidation threshold, a single partial liquidation is insufficient and the position requires repeated rounds.

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
