# Scripts

Deployment and interaction scripts for the GovernmentBondPlatform contract.

## Usage

### Deploy to Local Hardhat Network

```bash
npx hardhat node
npx hardhat run scripts/deploy.js --network localhost
```

### Deploy to a Testnet

1. Create a `.env` file with your private key and RPC URL (see `requirements.txt` in the project root)
2. Add the network to `hardhat.config.js`
3. Run:

```bash
npx hardhat run scripts/deploy.js --network <network-name>
```

## Writing a Deploy Script

Example `deploy.js`:

```javascript
const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  const BondPlatform = await ethers.getContractFactory("GovernmentBondPlatform");
  const platform = await BondPlatform.deploy("https://api.example.com/metadata/", deployer.address);
  await platform.waitForDeployment();

  console.log("GovernmentBondPlatform deployed to:", await platform.getAddress());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
```
