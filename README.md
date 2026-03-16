# Bond Token — Government Bond Tokenization Platform

A Solidity smart contract that tokenizes government bonds on the Ethereum blockchain using the ERC-1155 multi-token standard. Each bond issuance is represented as a unique token ID, with fungible units within the same series — mirroring how real-world government bonds work.

## Features

- **Bond Issuance** — Authorized issuers create bond series with configurable face value, coupon rate, maturity date, price, and supply
- **Bond Purchase** — Investors buy bond units with native ETH; exact payment validation enforced on-chain
- **Bond Redemption** — Holders redeem matured bonds by burning ERC-1155 tokens
- **Document Verification** — Register and verify cryptographic hashes (keccak256/SHA-256) of off-chain documents (prospectus, legal approval, certificate, terms)
- **Role-Based Access Control** — Admin, Issuer, Verifier, and Auditor roles via OpenZeppelin AccessControl
- **Lifecycle Management** — Bonds transition through ACTIVE, PAUSED, MATURED, REDEEMED, and CLOSED states
- **Emergency Pause** — Platform-wide and per-bond circuit breakers
- **On-Chain Audit Trail** — Comprehensive events for every state change, purchase, redemption, and verification

## Architecture

| Component | Details |
|-----------|---------|
| Token Standard | ERC-1155 (multi-token) |
| Solidity Version | ^0.8.27 |
| Framework | Hardhat |
| Dependencies | OpenZeppelin Contracts v5 |
| EVM Target | Cancun |

### Why ERC-1155?

- **ERC-20** would require a separate contract per bond series — expensive and complex
- **ERC-721** treats every unit as unique — incorrect for fungible bond units
- **ERC-1155** supports multiple token types in one contract with fungible units per type — the ideal fit

## Quick Start

### Prerequisites

- Node.js >= 16.x
- npm >= 8.x

### Installation

```bash
git clone https://github.com/nathanbanda148/bond-token.git
cd bond-token
npm install
```

### Compile

```bash
npx hardhat compile
```

### Run Tests

```bash
npx hardhat test
```

### Deploy (Local Hardhat Network)

```bash
npx hardhat node
npx hardhat run scripts/deploy.js --network localhost
```

## Smart Contract Overview

### Roles

| Role | Permissions |
|------|------------|
| `DEFAULT_ADMIN_ROLE` | Full platform control, fund withdrawal, pause/unpause |
| `ISSUER_ROLE` | Create bond issuances, register document hashes |
| `VERIFIER_ROLE` | Verify bond records and documents, update bond status |
| `AUDITOR_ROLE` | Audit bond records, verify documents with on-chain proof |

### Bond Lifecycle

```
ACTIVE → PAUSED → ACTIVE (reactivate)
ACTIVE → MATURED → REDEEMED → CLOSED
```

### Key Functions

| Function | Description |
|----------|-------------|
| `createBondIssuance()` | Create a new bond series |
| `buyBond()` | Purchase bond units with ETH |
| `redeemBond()` | Redeem matured bond units (burns tokens) |
| `registerDocumentHash()` | Store document hash on-chain |
| `verifyDocumentHash()` | Verify a document hash (view, no gas) |
| `verifyDocumentHashWithAudit()` | Verify with on-chain audit event |
| `setBondStatus()` | Update bond lifecycle status |
| `getBondDetails()` | Query full bond metadata |
| `getInvestorHolding()` | Query investor position |
| `withdrawFunds()` | Admin withdraws collected ETH |

## Security

- OpenZeppelin `ReentrancyGuard` on all payable/burn functions
- OpenZeppelin `Pausable` for emergency stops
- Checks-Effects-Interactions pattern throughout
- Custom errors for gas-efficient reverts
- Input validation on all external functions

## License

MIT
