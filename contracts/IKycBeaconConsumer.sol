// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IKycBeaconConsumer {
  function kycAdmin() external view returns (address);
  function autoWhitelist(address, bool[] memory) external;
}
