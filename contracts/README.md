# Contracts

## GovernmentBondPlatform.sol

The core smart contract implementing the tokenized bond platform.

### Contract Inheritance

```
GovernmentBondPlatform
  ├── ERC1155          — Multi-token standard (OpenZeppelin)
  ├── AccessControl    — Role-based permissions (OpenZeppelin)
  ├── Pausable         — Emergency stop mechanism (OpenZeppelin)
  └── ReentrancyGuard  — Reentrancy protection (OpenZeppelin)
```

### Data Structures

**Bond** — On-chain representation of a bond issuance:
- `bondId` / `bondName` / `issuerName` — Identity
- `faceValue` — Par value in smallest currency unit
- `couponRateBps` — Annual coupon rate in basis points (750 = 7.50%)
- `issueDate` / `maturityDate` — UNIX timestamps
- `tokenPriceWei` — Price per unit in wei
- `maxSupply` / `unitsSold` — Supply tracking
- `status` — Lifecycle enum (ACTIVE, PAUSED, MATURED, REDEEMED, CLOSED)

**DocumentHashes** — Cryptographic hashes for off-chain document verification:
- `prospectusHash` — Bond prospectus
- `legalApprovalHash` — Legal approval
- `certificateHash` — Bond certificate
- `termsHash` — Terms and conditions

**InvestorPosition** — Per-investor tracking per bond:
- `purchased` — Total units bought
- `redeemed` — Total units redeemed

### Custom Errors

All revert conditions use custom errors instead of string messages for gas optimization. See the contract source for the full list.

### Events (Audit Trail)

Every state-changing operation emits an indexed event for off-chain monitoring and frontend integration:
- `BondIssued` — New bond created
- `BondPurchased` — Units purchased
- `BondRedeemed` — Units redeemed (burned)
- `BondStatusChanged` — Lifecycle transition
- `BondDocumentHashRegistered` — Document hash stored
- `DocumentHashVerificationPerformed` — Verification with audit proof
- `BondVerified` — Bond record verified
- `FundsWithdrawn` — ETH withdrawn by admin
