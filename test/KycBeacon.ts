//@ts-nocheck

import {
  time,
  loadFixture,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import { ethers } from "hardhat";

describe("KycBeacon", function () {
  async function deployFixture() {
    const [owner, kycAdmin, user, kycServiceProvider] =
      await ethers.getSigners();

    // Deploy KycBeacon
    const KycBeacon = await ethers.getContractFactory("KycBeacon");
    const kycBeacon = await KycBeacon.deploy(
      BigInt(10 ** 17).toString(),
      BigInt(10 ** 19).toString()
    );
    await kycBeacon.waitForDeployment();

    // Register and approve kyc provider
    await(
      await kycBeacon.registerCertifier(
        kycServiceProvider.address,
        "kycaml.xyz",
        "tax_12345678"
      )
    ).wait();

    await(
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
    await(await asset.connect(user).mint(BigInt(10 ** 20).toString())).wait();

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

  async function uploadDocs(_user, _kycBeacon) {
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();

    const supportingDocs = abiCoder.encode(
      ["string", "string", "string", "string", "string", "string"],
      [
        "Lil Jon",
        "get_low2002@hotmail.com",
        "123-456-7890",
        "Q369DMTHNGFNE",
        "QFTWTTW",
        "QSKTSKTSKT",
      ]
    );

    await (
      await _kycBeacon.connect(_user).submitSupportingDocs(supportingDocs, 3)
    ).wait();
  }

  async function passCertification(
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

    const docs = await _kycBeacon.connect(_user).viewUser(_user.address);

    expect(docs[0][0][1]).to.equal(1n); // 1n => Status.PENDING

    await (
      await _kycBeacon
        .connect(_kycServiceProvider)
        .pass(_user.address, _certType, (await time.latest()) + 365 * 24 * 3600)
    ).wait();
  }

  async function failCertification(
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

    const docs = await _kycBeacon.connect(_user).viewUser(_user.address);

    expect(docs[0][0][1]).to.equal(1n); // 1n => Status.PENDING

    await (
      await _kycBeacon
        .connect(_kycServiceProvider)
        .fail(_user.address, _certType)
    ).wait();
  }

  async function registerDapp(_kycAdmin, _kycBeacon, _dappAddress) {
    const visibility = [0, 1, 2]; // certifications, name, email
    const options = { value: BigInt(6 * 10 ** 19).toString() };

    await (
      await _kycBeacon
        .connect(_kycAdmin)
        .registerDapp(6, _dappAddress, visibility, true, options)
    ).wait();
  }

  describe("Successful path", function () {
    it("will accept user supporting docs", async function () {
      const { user, kycBeacon } = await loadFixture(deployFixture);
      await uploadDocs(user, kycBeacon);

      const docs = await kycBeacon.connect(user).viewUser(user.address);

      expect(docs[1][0]).to.equal("Lil Jon");
      expect(docs[1][1]).to.equal("get_low2002@hotmail.com");
      expect(docs[1][2]).to.equal("123-456-7890");
    });

    it("creates passing certification", async function () {
      const { user, kycServiceProvider, kycBeacon } = await loadFixture(
        deployFixture
      );

      await uploadDocs(user, kycBeacon);
      await passCertification(3, user, kycBeacon, kycServiceProvider);

      const docs = await kycBeacon.connect(user).viewUser(user.address);

      expect(docs[0][0][0]).to.equal(3n); // 3n => CertType.ALL
      expect(docs[0][0][1]).to.equal(2n); // 1n => Status.PASS
    });

    it("will auto whitelist user", async function () {
      const {
        owner,
        kycAdmin,
        user,
        kycServiceProvider,
        kycBeacon,
        asset,
        permissionedVault,
      } = await loadFixture(deployFixture);

      await uploadDocs(user, kycBeacon);
      await passCertification(3, user, kycBeacon, kycServiceProvider);
      await registerDapp(kycAdmin, kycBeacon, permissionedVault.target);

      // Approve vault to spend token
      await (
        await asset
          .connect(user)
          .approve(permissionedVault.target, BigInt(10 ** 20).toString())
      ).wait();

      // Try deposit without whitelisting
      await expect(
        permissionedVault.connect(user).deposit(BigInt(10 ** 18).toString())
      ).to.be.revertedWith("user is not whitelisted");

      // Approve and auto whitelist
      await (
        await kycBeacon.connect(user).approveDapp(permissionedVault.target)
      ).wait();

      await (
        await permissionedVault
          .connect(user)
          .deposit(BigInt(10 ** 18).toString())
      ).wait();

      const bal = await permissionedVault.balanceOf(user.address);

      expect(bal).to.equal(BigInt(10 ** 18));
    });
  });

  describe("Certifier and Dapp functions", function () {
    it("fail user credential", async function () {
      const { user, kycServiceProvider, kycBeacon } = await loadFixture(
        deployFixture
      );

      await uploadDocs(user, kycBeacon);
      await failCertification(3, user, kycBeacon, kycServiceProvider);

      const userData = await kycBeacon.connect(user).viewUser(user.address);
      expect(userData[0].length).to.equal(0); // Cert marked failed and deleted
    });

    it("renews subscription before expired", async function () {
      const { kycAdmin, kycBeacon, permissionedVault } = await loadFixture(
        deployFixture
      );

      await registerDapp(kycAdmin, kycBeacon, permissionedVault.target);

      const expiration = (
        await kycBeacon.connect(kycAdmin).viewDapp(permissionedVault.target)
      )[1];

      const options = { value: BigInt(5 * 10 ** 19).toString() };
      await kycBeacon
        .connect(kycAdmin)
        .renewSubscription(5, permissionedVault.target, options);

      const newExpiration = (
        await kycBeacon.connect(kycAdmin).viewDapp(permissionedVault.target)
      )[1];

      expect(newExpiration).to.equal(
        expiration + BigInt(5 * 4 * 7 * 24 * 60 * 60)
      );
    });

    it("will return user data via manual review", async function () {
      const {
        owner,
        kycAdmin,
        user,
        kycServiceProvider,
        kycBeacon,
        asset,
        permissionedVault,
      } = await loadFixture(deployFixture);

      await uploadDocs(user, kycBeacon);
      await passCertification(3, user, kycBeacon, kycServiceProvider);
      await registerDapp(kycAdmin, kycBeacon, permissionedVault.target);

      // Approve vault to spend token
      await (
        await asset
          .connect(user)
          .approve(permissionedVault.target, BigInt(10 ** 20).toString())
      ).wait();

      // Try deposit without whitelisting
      await expect(
        permissionedVault.connect(user).deposit(BigInt(10 ** 18).toString())
      ).to.be.revertedWith("user is not whitelisted");

      // Approve and auto whitelist
      await (
        await kycBeacon.connect(user).approveDapp(permissionedVault.target)
      ).wait();

      const docs = await kycBeacon
        .connect(kycAdmin)
        .manualReview(user.address, permissionedVault.target);

      expect(docs[1][0]).to.equal("Lil Jon");
      expect(docs[1][1]).to.equal("get_low2002@hotmail.com");
      expect(docs[1][2]).to.equal(""); // Dapp does not have access to phone number based on scope
    });
  });
});
