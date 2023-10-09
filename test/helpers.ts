// @ts-nocheck
import { time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { ethers } from "hardhat";

export async function deployFixture() {
  const [owner, kycAdmin, user, kycServiceProvider] = await ethers.getSigners();

  // Deploy KycBeacon
  const KycBeacon = await ethers.getContractFactory("KycBeacon");
  const kycBeacon = await KycBeacon.deploy(
    BigInt(10 ** 17).toString(),
    BigInt(10 ** 19).toString()
  );
  await kycBeacon.waitForDeployment();

  // Register and approve kyc provider
  await (
    await kycBeacon.registerCertifier(
      kycServiceProvider.address,
      "kycaml.xyz",
      "tax_12345678"
    )
  ).wait();

  await (
    await kycBeacon.editCertifierWhitelist(kycServiceProvider.address, true)
  ).wait();

  // Deploy asset token used in PermissionedVault
  const Asset = await ethers.getContractFactory("Asset");
  const asset = await Asset.deploy();
  await asset.waitForDeployment();

  // Deploy PermissionedVault
  const PermissionedVault = await ethers.getContractFactory(
    "PermissionedVault"
  );
  const permissionedVault = await PermissionedVault.deploy(
    asset.target,
    kycAdmin.address,
    kycBeacon.target
  );
  await permissionedVault.waitForDeployment();

  // Mint asset tokens to user
  await (await asset.connect(user).mint(BigInt(10 ** 20).toString())).wait();

  return {
    owner,
    kycAdmin,
    user,
    kycServiceProvider,
    kycBeacon,
    asset,
    permissionedVault,
  };
}

export async function uploadDocs(_user, _kycBeacon) {
  const abiCoder = ethers.AbiCoder.defaultAbiCoder();

  const supportingDocs = abiCoder.encode(
    ["string", "string", "string", "string", "string", "string", "string"],
    [
      "Lil Jon",
      "get_low2002@hotmail.com",
      "123-456-7890",
      "Q369DMTHNGFNE",
      "QFTWTTW",
      "QSKTSKTSKT",
      "randomStringForEncryption",
    ]
  );

  await (
    await _kycBeacon.connect(_user).submitSupportingDocs(supportingDocs, 3)
  ).wait();
}

export async function signAuthMessage(_signer) {
  const message = "Requesting user data";
  const messageHash = ethers.hashMessage(message);
  const signature = await _signer.signMessage(message);
  return { messageHash, signature };
}

export async function passCertification(
  _certType,
  _user,
  _kycBeacon,
  _kycServiceProvider
) {
  await (
    await _kycBeacon
      .connect(_kycServiceProvider)
      .initiate(_user.address, _certType)
  ).wait();

  await (
    await _kycBeacon
      .connect(_kycServiceProvider)
      .pass(_user.address, _certType, (await time.latest()) + 365 * 24 * 3600)
  ).wait();
}

export async function failCertification(
  _certType,
  _user,
  _kycBeacon,
  _kycServiceProvider
) {
  await (
    await _kycBeacon
      .connect(_kycServiceProvider)
      .initiate(_user.address, _certType)
  ).wait();

  await (
    await _kycBeacon.connect(_kycServiceProvider).fail(_user.address, _certType)
  ).wait();
}

export async function registerDapp(_kycAdmin, _kycBeacon, _dappAddress) {
  const visibility = [0, 1, 2]; // certifications, name, email
  const options = { value: BigInt(6 * 10 ** 19).toString() };

  await (
    await _kycBeacon
      .connect(_kycAdmin)
      .registerDapp(6, _dappAddress, visibility, true, options)
  ).wait();
}
