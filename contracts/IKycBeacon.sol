// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IKycBeacon
/// @author strangequark.eth
/// @notice Interface for KycBeacon used for definition of structs, enums, events, errors
interface IKycBeacon {

  enum CertType{ KYC, AML, REG_D, ALL }
  enum Status{ UNINITIATED, PENDING, PASS }
  enum Visibility{ CERTS, NAME, EMAIL, PHONE, PASSPORT, LICENSE, TAXES}

  struct Cert{
    CertType certType;
    Status status;
    address certifiedBy;
    uint expiration;
  }
  
  struct User{
    Cert[] certs;
    string name;
    string email;
    string phone;
    string passportHash;
    string driversLicenseHash;
    string taxReturnHash;
    string encryptionKey;
    mapping(address => bool) approvedDapps;
  }

  struct Certifier{
    string website;
    string taxId;
  }

  struct Dapp {
    bool autoWhitelist; 
    uint256 subscriptionExpiration;
    Visibility[] visibilityRequests;
  }

  struct PrivateDataRequestMessage {
    address requester;
    uint256 expiry;
  }

  error Unauthorized(address user);
  error ValidCertExists(address user, address certifier, CertType certType);
  error PendingCertMissing(address user, address certifier, CertType certType);
  
  event RegisterCertifier(address indexed certifier, string website);
  event RegisterDapp(address indexed dappAddress, address dappAdmin); 
  event RenewSubscription(address indexed dappAddress, uint256 expires); 
  event CertificationRequest(address indexed user, CertType indexed certType);
  event CertificationInitiated(address indexed user, address indexed certifier, CertType indexed certType);
  event CertificationPassed(address indexed user, address indexed certifier, CertType indexed certType);
  event CertificationFailed(address indexed user, address indexed certifier, CertType indexed certType);

  function submitSupportingDocs(bytes calldata data, CertType certType) external;
  function viewUser(address _userAddress, bytes32 _signedMessageHash, bytes calldata _signature) external view returns (Cert[] memory, string[] memory);
  function approveDapp(address dappAddress) external;
  function editApprovedDapp(address dappAddress, bool isApproved) external;
  function registerCertifier(address certifierAddress, string memory website, string memory taxId) external;
  function initiate(address userAddress, CertType certType) external;
  function pass(address userAddress, CertType certType, uint expiresOn) external;
  function fail(address userAddress, CertType certType) external;
  function registerDapp(uint8 numberOfMonths, address dappAddress, Visibility[] calldata visibilitySettings, bool isAutoWhitelist) external payable;
  function renewSubscription(uint8 numberOfMonths, address dappAddress) external payable;
  function viewDapp(address dappAddress, bytes32 _messageHash, bytes calldata _signature) external view returns (Dapp memory);
  function manualReview(address userAddress, address dappAddress, bytes32 _messageHash, bytes calldata _signature) external view returns(Cert[] memory, string[] memory);
  function editCertifierWhitelist(address certifierAddress, bool isApproved) external;
  function editCertifierFee(uint256 _fee) external;
  function editDappSubscriptionFee(uint256 _fee) external;

}