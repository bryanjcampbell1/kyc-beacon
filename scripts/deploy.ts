import hre, { ethers } from "hardhat";
import "dotenv/config";
const fs = require("fs");

const CERTIFIER = process.env.KYC_CERTIFIER_PUB_KEY as string;
const KYC_ADMIN = process.env.KYC_ADMIN_PUB_KEY as string;
const CERTIFIER_FEE = BigInt(10 ** 15);
const SUBSCRIPTION_FEE = BigInt(10 ** 16);

async function main() {
  // Deploy KycBeacon
  const kycBeacon = await ethers.deployContract("KycBeacon", [
    CERTIFIER_FEE,
    SUBSCRIPTION_FEE,
  ]);

  await kycBeacon.waitForDeployment();
  console.log("kycBeacon.target: ", kycBeacon.target);

  // Register and approve certifier
  await (
    await kycBeacon.registerCertifier(CERTIFIER, "kycaml.xyz", "tax_12345678")
  ).wait();

  await (await kycBeacon.editCertifierWhitelist(CERTIFIER, true)).wait();

  // Deploy asset token used in PermissionedVault
  const Asset = await ethers.getContractFactory("Asset");
  const asset = await Asset.deploy();
  await asset.waitForDeployment();

  console.log("asset.target: ", asset.target);

  // Deploy PermissionedVault
  const PermissionedVault = await ethers.getContractFactory(
    "PermissionedVault"
  );
  const permissionedVault = await PermissionedVault.deploy(
    asset.target,
    KYC_ADMIN,
    kycBeacon.target
  );
  await permissionedVault.waitForDeployment();
  console.log("permissionedVault.target: ", permissionedVault.target);

  // Register Dapp to use KycBeacon with 6 month subscription
  const visibility = [0, 1, 2]; // certifications, name, email
  const options = { value: 6n * SUBSCRIPTION_FEE };

  await(
    await kycBeacon.registerDapp(
      6,
      permissionedVault.target,
      visibility,
      true,
      options
    )
  ).wait();

  // Prepare data and write to file
  const kyc_beacon_abi = (
    await hre.artifacts.readArtifact("contracts/KycBeacon.sol:KycBeacon")
  ).abi;

  const asset_abi = (
    await hre.artifacts.readArtifact("contracts/Tokens.sol:Asset")
  ).abi;

  const vault_abi = (
    await hre.artifacts.readArtifact(
      "contracts/PermissionedVault.sol:PermissionedVault"
    )
  ).abi;

  const _kyc_beacon = `export const KYC_BEACON_ADDRRESS = '${kycBeacon.target}' \n`;
  const _vault = `export const VAULT_ADDRRESS = '${permissionedVault.target}' \n`;
  const _asset = `export const ASSET_ADDRRESS = '${asset.target}' \n`;

  const _kyc_beacon_abi = `export const KYC_BEACON_ABI = ${JSON.stringify(
    kyc_beacon_abi
  )} \n`;
  const _asset_abi = `export const ASSET_ABI = ${JSON.stringify(asset_abi)} \n`;
  const _vault_abi = `export const VAULT_ABI = ${JSON.stringify(vault_abi)} \n`;

  const data =
    _kyc_beacon + _vault + _asset + _kyc_beacon_abi + _asset_abi + _vault_abi;

  fs.writeFileSync("index.ts", data);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
