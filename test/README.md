# Tests

Unit and integration tests for the GovernmentBondPlatform contract.

## Running Tests

```bash
npx hardhat test
```

### With Gas Reporting

```bash
REPORT_GAS=true npx hardhat test
```

### Run a Specific Test File

```bash
npx hardhat test test/GovernmentBondPlatform.test.js
```

## Test Coverage Areas

Tests should cover the following scenarios:

### Bond Issuance
- Create a bond with valid parameters
- Reject duplicate bond IDs
- Reject invalid date ranges, zero supply, zero price, zero address
- Only ISSUER_ROLE can create bonds

### Bond Purchase
- Buy bond units with correct ETH payment
- Reject incorrect payment amounts
- Reject purchases exceeding remaining supply
- Reject purchases of paused, matured, or non-active bonds
- Verify ERC-1155 token balances after purchase

### Bond Redemption
- Redeem matured bond units
- Reject redemption of non-matured bonds
- Reject redemption exceeding holdings
- Verify tokens are burned after redemption

### Document Verification
- Register document hashes for all document types
- Verify matching hashes return true
- Verify non-matching hashes return false
- Reject empty hashes

### Access Control
- Verify role-based restrictions on all protected functions
- Test role granting and revoking

### Lifecycle Management
- Test all status transitions
- Test platform pause/unpause
- Test per-bond pause/activate

### Fund Withdrawal
- Admin can withdraw collected ETH
- Reject withdrawal to zero address
- Reject withdrawal when no funds available
