//@ts-nocheck
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import {
  deployFixture,
  uploadDocs,
  passCertification,
  failCertification,
  registerDapp,
  signAuthMessage,
} from "./helpers";

describe("KycBeacon", function () {
  it("will accept user supporting docs", async function () {
    const { user, kycBeacon } = await loadFixture(deployFixture);
    await uploadDocs(user, kycBeacon);

    const { messageHash, signature } = await signAuthMessage(user);
    const docs = await kycBeacon
      .connect(user)
      .viewUser(user.address, messageHash, signature);

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

    const { messageHash, signature } = await signAuthMessage(user);
    const docs = await kycBeacon
      .connect(user)
      .viewUser(user.address, messageHash, signature);

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
    await(
      await asset
        .connect(user)
        .approve(permissionedVault.target, BigInt(10 ** 20).toString())
    ).wait();

    // Try deposit without whitelisting
    await expect(
      permissionedVault.connect(user).deposit(BigInt(10 ** 18).toString())
    ).to.be.revertedWith("user is not whitelisted");

    // Approve and auto whitelist
    await(
      await kycBeacon.connect(user).approveDapp(permissionedVault.target)
    ).wait();

    await(
      await permissionedVault.connect(user).deposit(BigInt(10 ** 18).toString())
    ).wait();

    const bal = await permissionedVault.balanceOf(user.address);

    expect(bal).to.equal(BigInt(10 ** 18));
  });

  it("fail user credential", async function () {
    const { user, kycServiceProvider, kycBeacon } = await loadFixture(
      deployFixture
    );

    await uploadDocs(user, kycBeacon);
    await failCertification(3, user, kycBeacon, kycServiceProvider);

    const { messageHash, signature } = await signAuthMessage(user);
    const docs = await kycBeacon
      .connect(user)
      .viewUser(user.address, messageHash, signature);

    expect(docs[0].length).to.equal(0); // Cert marked failed and deleted
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
    await(
      await asset
        .connect(user)
        .approve(permissionedVault.target, BigInt(10 ** 20).toString())
    ).wait();

    // Try deposit without whitelisting
    await expect(
      permissionedVault.connect(user).deposit(BigInt(10 ** 18).toString())
    ).to.be.revertedWith("user is not whitelisted");

    // Approve and auto whitelist
    await(
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

