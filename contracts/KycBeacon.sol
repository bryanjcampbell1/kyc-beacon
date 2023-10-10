// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IKycBeacon.sol";
import "./IKycBeaconConsumer.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title KycBeacon
/// @author strangequark.eth
/// @notice Provides users a way to privately register their kyc/aml and accredited investor status
/// @dev 3rd party contracts using this register for whitelisting should inherit from IKycBeaconConsumer
contract KycBeacon is IKycBeacon, Ownable {

  uint256 certifierFee;
  uint256 dappSubscriptionFee;

  mapping(address => User) users;
  mapping(address => string) encryptionKeys;
  mapping(address => bool) certifierWhitelist;
  mapping(address => Certifier) certifiers;
  mapping(address => Dapp) dapps;

  constructor(uint256 _certifierFee, uint256 _dappSubscriptionFee) Ownable(msg.sender){
    certifierFee = _certifierFee;
    dappSubscriptionFee = _dappSubscriptionFee;
  }

  /// @notice Check that auth message signer is either msg.sender or a whitelisted certifier
  /// @dev msg.sender can be spoofed for view functions so this acts as our auth check
  modifier onlyPermitted(address _userAddress, bytes32 _messageHash, bytes calldata _signature) {
    address signer = ECDSA.recover(_messageHash, _signature);
    if ((signer != msg.sender) || (signer != _userAddress && !certifierWhitelist[signer]) )revert Unauthorized(msg.sender);
    _;
  }

  /// @notice Checks that the auth message signer matches the msg.sender
  /// @dev msg.sender can be spoofed for view functions so this acts as our auth check
  modifier onlyDapp(address _dappAddress, bytes32 _messageHash, bytes calldata _signature) {
    address signer = ECDSA.recover(_messageHash, _signature);
    require(signer == IKycBeaconConsumer(_dappAddress).kycAdmin(), "Only kycAdmin can view");
    if (signer != msg.sender) revert Unauthorized(msg.sender);
    _;
  }

  /// @notice User submits thier docs so they can be verified by certifiers
  /// @dev Supporiting docs uploaded to IPFS are encrypted with a key stored privately in User
  /// @param _data Private user data being uploaded for review
  /// @param _certType Type of certification user is requesting
  function submitSupportingDocs(bytes calldata _data, CertType _certType) public {

    ( string memory name, 
      string memory email, 
      string memory phone,
      string memory passportHash,
      string memory driversLicenseHash, 
      string memory taxReturnHash,
      string memory encryptionKey ) = abi.decode(_data, (string,string,string,string,string,string,string));

    User storage user = users[msg.sender];
    user.name = name;
    user.email = email;
    user.phone = phone;
    user.passportHash = passportHash;
    user.driversLicenseHash = driversLicenseHash;
    user.taxReturnHash = taxReturnHash;
    user.encryptionKey = encryptionKey;

    emit CertificationRequest(msg.sender, _certType);
  }

  /// @notice Getter function for private user data. Accessable to certifiers and the users themselves.
  /// @dev Supporiting docs uploaded to IPFS are encrypted with a key stored privately in User
  /// @param _userAddress Address of user who's data we are getting
  /// @param _messageHash Hash of the auth message 
  /// @param _signature Signature of the hashed message
  /// @return the Private user data
  function viewUser(address _userAddress, bytes32 _messageHash, bytes calldata _signature) public view onlyPermitted(_userAddress, _messageHash, _signature) returns(Cert[] memory, string[] memory){

    User storage user = users[_userAddress];

    string[] memory userInfo = new string[](7);
    userInfo[0] = user.name;
    userInfo[1] = user.email;
    userInfo[2] = user.phone;
    userInfo[3] = user.passportHash;
    userInfo[4] = user.driversLicenseHash;
    userInfo[5] = user.taxReturnHash;
    userInfo[6] = user.encryptionKey;

    return(user.certs, userInfo);
  }

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
  /// @param _dappAddress Address of the Dapp being approved by the user
  function approveDapp(address _dappAddress) public {
    User storage user = users[msg.sender];
    Dapp storage dapp = dapps[_dappAddress];

    user.approvedDapps[_dappAddress] = true;

    if(dapp.autoWhitelist){
      bool[] memory certs = new bool[](4);
      certs[0] = _isValidCert(CertType.KYC, user.certs);
      certs[1] = _isValidCert(CertType.AML, user.certs);
      certs[2] = _isValidCert(CertType.REG_D, user.certs);
      certs[3] = _isValidCert(CertType.ALL, user.certs);

      IKycBeaconConsumer(_dappAddress).autoWhitelist(msg.sender, certs);
    }
  }

  /// @notice Changes the users approval status of a Dapp
  /// @param _dappAddress Address of the Dapp
  /// @param _isApproved Boolean where if true Dapp is approved
  function editApprovedDapp(address _dappAddress, bool _isApproved) public {
    User storage user = users[msg.sender];
    user.approvedDapps[_dappAddress] = _isApproved;
  }

  /// @notice Certifier submits private data for review by the KycBeacon team
  /// @param _certifierAddress Address of the certifier
  /// @param _website String of the certifier's website 
  /// @param _taxId String of the certifier's tax id 
  function registerCertifier(address _certifierAddress, string memory _website, string memory _taxId) public {
    Certifier storage certifier = certifiers[_certifierAddress];
    certifier.website = _website;
    certifier.taxId = _taxId;

    emit RegisterCertifier(msg.sender, _website);
  }

  /// @notice Certifier calls in order to claim a new user cert request
  /// @param _userAddress Address of user requesting cert
  /// @param _certType Type of certification user is requesting
  function initiate(address _userAddress, CertType _certType) public {
    require(certifierWhitelist[msg.sender], "Not whitelisted");

    // Certifiers have one week to complete certification or it is claimable by another provider
    Cert memory cert = Cert(_certType, Status.PENDING, msg.sender, block.timestamp + 1 weeks);
    User storage user = users[_userAddress];
    Cert[] storage certs = user.certs;

    // check for old cert of the same certType
    // 3 possibilities
    // i) cert exists but is expired --> overwrite it
    // ii) cert does not exist --> push it
    // iii) valid cert exists --> do nothing
    uint foundAt = _findCertType(certs, _certType);
    if(foundAt != type(uint256).max && certs[foundAt].expiration < block.timestamp){
      certs[foundAt] = cert;
    } else if (foundAt == type(uint256).max) {
      certs.push(cert);
    } else{
      revert ValidCertExists(_userAddress, certs[foundAt].certifiedBy, _certType);
    }
    
  }

  /// @notice Certifier creates a passing cert for user
  /// @param _userAddress Address of user requesting cert
  /// @param _certType Type of certification user is requesting
  /// @param _expiresOn Date that new cert expires
  function pass(address _userAddress, CertType _certType, uint _expiresOn) public {
    require(certifierWhitelist[msg.sender], "Not whitelisted");

    Cert memory cert = Cert(_certType, Status.PASS, msg.sender, _expiresOn);
    User storage user = users[_userAddress];
    Cert[] storage certs = user.certs;

    uint foundAt = _findCertType(certs, _certType);
    if(foundAt != type(uint256).max && 
      certs[foundAt].certifiedBy == msg.sender && 
      certs[foundAt].status == Status.PENDING 
    ){
      certs[foundAt] = cert;
      emit CertificationPassed(_userAddress, msg.sender, _certType);
    } else{
      revert PendingCertMissing(_userAddress, msg.sender, _certType);
    }
  }

  /// @notice Certifier rejects the user's request for a new cert
  /// @param _userAddress Address of user requesting cert
  /// @param _certType Type of certification user is requesting
  function fail(address _userAddress, CertType _certType) public {
    require(certifierWhitelist[msg.sender], "Not whitelisted");

    User storage user = users[_userAddress];
    Cert[] storage certs = user.certs;

    uint foundAt = _findCertType(certs, _certType);

    // delete failed pending Cert
    if(foundAt != type(uint256).max && 
      certs[foundAt].certifiedBy == msg.sender && 
      certs[foundAt].status == Status.PENDING 
    ){
      for(uint i = foundAt; i < certs.length - 1; i++){
        certs[i] = certs[i+1];
      }
      certs.pop();
      emit CertificationFailed(_userAddress, msg.sender, _certType);

    } else{
      revert PendingCertMissing(_userAddress, msg.sender, _certType);
    }
  }

  /// @notice Handles the registration of and initial subscription for a 3rd party Dapp 
  /// @dev Dapp must inherit from IKycBeaconConsumer
  /// @param _numberOfMonths Initial subscription period
  /// @param _dappAddress Address of dapp 
  /// @param _visibilitySettings User fields that dapp requests access to 
  /// @param _isAutoWhitelist Determines if user can be whitelisted without manual review
  function registerDapp(uint8 _numberOfMonths, address _dappAddress, Visibility[] calldata _visibilitySettings, bool _isAutoWhitelist) public payable {
    require(msg.value == uint256(_numberOfMonths) * dappSubscriptionFee, "Subscription unpaid");
    require(msg.sender == IKycBeaconConsumer(_dappAddress).kycAdmin(), "Only kycAdmin can register");

    Dapp storage dapp = dapps[_dappAddress];
    dapp.subscriptionExpiration = block.timestamp + uint256(_numberOfMonths) * 4 weeks;
    dapp.visibilityRequests = _visibilitySettings;
    dapp.autoWhitelist = _isAutoWhitelist;

    emit RegisterDapp(_dappAddress, msg.sender); 
  }

  /// @notice Getter for Dapp private data. Useful for admin of 3rd party Dapps.
  /// @param _dappAddress Address of Dapp
  /// @param _messageHash Hash of the auth message 
  /// @param _signature Signature of the hashed message
  /// @return Private Dapp data includeing subscription info
  function viewDapp(address _dappAddress, bytes32 _messageHash, bytes calldata _signature) public onlyDapp(_dappAddress, _messageHash, _signature) view returns(Dapp memory){
    return dapps[_dappAddress];
  }

  /// @notice Renews subscription for 3rd party Dapp
  /// @param _numberOfMonths Subscription period
  /// @param _dappAddress Address of Dapp
  function renewSubscription(uint8 _numberOfMonths, address _dappAddress) public payable {
    require(msg.value == uint256(_numberOfMonths) * dappSubscriptionFee, "Subscription unpaid");
    Dapp storage dapp = dapps[_dappAddress];

    uint256 starts = (block.timestamp > dapp.subscriptionExpiration)? block.timestamp : dapp.subscriptionExpiration;
    uint256 expires = starts + uint256(_numberOfMonths) * 4 weeks;
    dapp.subscriptionExpiration = expires;

    emit RenewSubscription(_dappAddress, expires);
  }

  /// @notice Getter for private user data matching the Dapp visibility settings
  /// @param _userAddress Address of user
  /// @param _dappAddress Address of Dapp
  /// @param _messageHash Hash of the auth message 
  /// @param _signature Signature of the hashed message
  /// @return Private user data
  function manualReview(address _userAddress, address _dappAddress, bytes32 _messageHash, bytes calldata _signature) public view onlyDapp(_dappAddress, _messageHash, _signature) returns(Cert[] memory, string[] memory){
    User storage user = users[_userAddress];
    Dapp memory dapp = dapps[_dappAddress];

    require(user.approvedDapps[_dappAddress], "Dapp not permitted");
    require(msg.sender == IKycBeaconConsumer(_dappAddress).kycAdmin(), "Sender not permitted");

    Cert[] storage certs = user.certs;
    string[] memory userInfo = new string[](6);

    userInfo[0] = _isVisible(Visibility.NAME, dapp.visibilityRequests)? user.name : "";
    userInfo[1] = _isVisible(Visibility.EMAIL, dapp.visibilityRequests)? user.email : "";
    userInfo[2] = _isVisible(Visibility.PHONE, dapp.visibilityRequests)? user.phone : "";
    userInfo[3] = _isVisible(Visibility.PASSPORT, dapp.visibilityRequests)? user.passportHash : "";
    userInfo[4] = _isVisible(Visibility.LICENSE, dapp.visibilityRequests)? user.driversLicenseHash : "";
    userInfo[5] = _isVisible(Visibility.TAXES, dapp.visibilityRequests)? user.taxReturnHash : "";

    return(certs, userInfo);
  }

  /// @notice Internal function for finding the index of a cert of a specific type
  /// @param _certs Array of user's Certs
  /// @param _certType Type of cert we are looking for
  /// @return The index of the cert. If no cert is found we return the max uint.
  function _findCertType(Cert[] memory _certs, CertType _certType ) internal pure returns(uint){
    uint foundAt = type(uint256).max;
    for(uint i; i< _certs.length; i++ ){
      if(_certs[i].certType == _certType){
        foundAt = i;
        break;
      }
    }
    return foundAt;
  }

  /// @notice Internal function used to check if a user field is visible to a Dapp based on its visibilityRequests 
  /// @param _value User value 
  /// @param _visibilityRequests Array specified by Dapp that determines what user data it can see
  /// @return A boolean value representing whether that user field is visible to Dapp
  function _isVisible(Visibility _value, Visibility[] memory _visibilityRequests) internal pure returns (bool) {
    for (uint i = 0; i < _visibilityRequests.length; i++) {
        if (_visibilityRequests[i] == _value) {
            return true;
        }
    }

    return false;
  }

  /// @notice Internal function 
  /// @param _value a parameter just like in doxygen (must be followed by parameter name)
  /// @param _certs a parameter just like in doxygen (must be followed by parameter nam
  /// @return sdfasfasfars 
  function _isValidCert(CertType _value, Cert[] memory _certs) internal view returns (bool) {
    for (uint i = 0; i < _certs.length; i++) {
        if (_certs[i].certType == _value && _certs[i].status == Status.PASS && block.timestamp < _certs[i].expiration) {
            return true;
        }
    }

    return false;
  }

  /// @notice Admin function to (dis)approve certifier to grant user certs 
  /// @param _certifierAddress Address of certifier
  /// @param _isApproved A boolean that, if true, grants certifier the ability to create certs
  function editCertifierWhitelist(address _certifierAddress, bool _isApproved) public onlyOwner{
    certifierWhitelist[_certifierAddress] = _isApproved;
  }

  /// @notice Admin function used to change the certifier fee
  /// @param _fee New fee 
  function editCertifierFee(uint256 _fee) public onlyOwner{
    certifierFee = _fee;
  }

  /// @notice Admin function used to change the Dapp subscription fee
  /// @param _fee New fee
  function editDappSubscriptionFee(uint256 _fee) public onlyOwner{
    dappSubscriptionFee = _fee;
  }

}