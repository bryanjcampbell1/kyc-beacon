// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IKycBeaconConsumer } from "./KycBeacon.sol";
import "hardhat/console.sol";

// This vault is classified as a security. Only Reg D accredited investors can participate.
contract PermissionedVault is Ownable, IKycBeaconConsumer, ERC4626 {

  address public kycAdmin;
  address public kycBeacon;

  mapping(address => bool) public whitelist;

  constructor(
    address _assetAddress,
    address _kycAdmin,
    address _kycBeacon
  ) ERC20("Pemissioned Vault", "PVT") ERC4626(IERC20(_assetAddress)){
    kycAdmin = _kycAdmin;
    kycBeacon = _kycBeacon;
  }

  function autoWhitelist(address _user, bool[] memory _credentails) public {
    require(msg.sender == kycBeacon, "only beacon can auto-whitelist user");
    if(_credentails[2] || _credentails[3]){
      whitelist[_user] = true;
    }
  }

  function manualWhitelist(address _user, bool _status) public {
    require(msg.sender == kycAdmin, "not approved to whitelist users");
    whitelist[_user] = _status;
  }

  function deposit(uint _amount) public {
    require(whitelist[msg.sender], "user is not whitelisted");
    super.deposit(_amount, msg.sender);
  }

}