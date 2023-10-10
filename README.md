# KycBeacon
KycBeacon is a private, on-chain, registry for user's KYC/AML/RegD status built on the Oasis Sapphire network. We give user's the power to choose who they share their data with and help create a smoother onboarding experience for 3rd party Dapps.

## Setup
Install dependencies
```shell
npm i
```

Create a .env file the root of the project with at least a PRIVATE_KEY.  If you plan on running tests you will also need public keys for KYC_ADMIN_PUB_KEY and KYC_CERTIFIER_PUB_KEY. 

The kycAdmin is the admin of the mock 3rd party dapp in the tests.
The kycCertifier is a test credentialing authorithy whitelisted by KycBeacon.


```shell
PRIVATE_KEY="YOUR_WALLET_PRIVATE_KEY"
KYC_ADMIN_PUB_KEY="YOUR_KYC_ADMIN_PUB_KEY"
KYC_CERTIFIER_PUB_KEY="YOUR_KYC_CERTIFIER_PUB_KEY"
```

## Install, Compile and Test
```shell
npx hardhat test
```

## Deploy Testnet Contracts 
```shell
npx hardhat run --network sapphire_testnet scripts/deploy.ts
```
After running, a file named index.ts will be generated in the root of this project containing useful addresses and abi's that can be imported elsewhere.