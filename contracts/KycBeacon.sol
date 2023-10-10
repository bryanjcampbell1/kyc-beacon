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

  /// @notice Checks that the auth message signer matches the msg.sender
  /// @dev msg.sender can be spoofed for view functions so this acts as our auth check
  modifier onlyPermitted(address _userAddress, bytes32 signedMessageHash, bytes calldata signature) {
    address signer = ECDSA.recover(signedMessageHash, signature);
    if ((signer != msg.sender) || (signer != _userAddress && !certifierWhitelist[signer]) )revert Unauthorized(msg.sender);
    _;
  }

  /// @notice User submits thier docs so they can be verified by certifiers
  /// @dev Supporiting docs uploaded to IPFS are encrypted with a key stored privately in User
  /// @param _data a parameter just like in doxygen (must be followed by parameter name)
  /// @param _certType a parameter just like in doxygen (must be followed by parameter name)
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
  /// @param _userAddress a parameter just like in doxygen (must be followed by parameter name)
  /// @param _signedMessageHash a parameter just like in doxygen (must be followed by parameter name)
  /// @param _signature a parameter just like in doxygen (must be followed by parameter name)
  /// @return Documents the return variables of a contract’s function state variable
  function viewUser(address _userAddress, bytes32 _signedMessageHash, bytes calldata _signature) public view onlyPermitted(_userAddress, _signedMessageHash, _signature) returns(Cert[] memory, string[] memory){

    //dont destructure
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
  /// @param _dappAddress a parameter just like in doxygen (must be followed by parameter name)
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

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
  /// @param _dappAddress a parameter just like in doxygen (must be followed by parameter name)
  /// @param _isApproved a parameter just like in doxygen (must be followed by parameter name)
  function editApprovedDapp(address _dappAddress, bool _isApproved) public {
    User storage user = users[msg.sender];
    user.approvedDapps[_dappAddress] = _isApproved;
  }

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
  /// @param _certifierAddress a parameter just like in doxygen (must be followed by parameter name)
  /// @param _website a parameter just like in doxygen (must be followed by parameter name)
  /// @param _taxId a parameter just like in doxygen (must be followed by parameter name)
  function registerCertifier(address _certifierAddress, string memory _website, string memory _taxId) public {
    Certifier storage certifier = certifiers[_certifierAddress];
    certifier.website = _website;
    certifier.taxId = _taxId;

    emit RegisterCertifier(msg.sender, _website);
  }

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
  /// @param _userAddress a parameter just like in doxygen (must be followed by parameter name)
  /// @param _certType a parameter just like in doxygen (must be followed by parameter name)
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

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
  /// @param _userAddress a parameter just like in doxygen (must be followed by parameter name)
  /// @param _certType a parameter just like in doxygen (must be followed by parameter name)
  /// @param _expiresOn a parameter just like in doxygen (must be followed by parameter name)
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

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
  /// @param _userAddress a parameter just like in doxygen (must be followed by parameter name)
  /// @param _certType a parameter just like in doxygen (must be followed by parameter name)
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

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
  /// @param _numberOfMonths a parameter just like in doxygen (must be followed by parameter name)
  /// @param _dappAddress a parameter just like in doxygen (must be followed by parameter name)
  /// @param _visibilitySettings a parameter just like in doxygen (must be followed by parameter name)
  /// @param _isAutoWhitelist a parameter just like in doxygen (must be followed by parameter name)
  function registerDapp(uint8 _numberOfMonths, address _dappAddress, Visibility[] calldata _visibilitySettings, bool _isAutoWhitelist) public payable {
    require(msg.value == uint256(_numberOfMonths) * dappSubscriptionFee, "Subscription unpaid");
    require(msg.sender == IKycBeaconConsumer(_dappAddress).kycAdmin(), "Only kycAdmin can register");

    Dapp storage dapp = dapps[_dappAddress];
    dapp.subscriptionExpiration = block.timestamp + uint256(_numberOfMonths) * 4 weeks;
    dapp.visibilityRequests = _visibilitySettings;
    dapp.autoWhitelist = _isAutoWhitelist;

    emit RegisterDapp(_dappAddress, msg.sender); 
  }

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
  /// @param _dappAddress a parameter just like in doxygen (must be followed by parameter name)
  /// @return Documents the return variables of a contract’s function state variable
  function viewDapp(address _dappAddress) public view returns(Dapp memory){
    require(msg.sender == IKycBeaconConsumer(_dappAddress).kycAdmin(), "Only kycAdmin can view");
    return dapps[_dappAddress];
  }

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
  /// @param _numberOfMonths a parameter just like in doxygen (must be followed by parameter name)
  /// @param _dappAddress a parameter just like in doxygen (must be followed by parameter name)
  function renewSubscription(uint8 _numberOfMonths, address _dappAddress) public payable {
    require(msg.value == uint256(_numberOfMonths) * dappSubscriptionFee, "Subscription unpaid");
    Dapp storage dapp = dapps[_dappAddress];

    uint256 starts = (block.timestamp > dapp.subscriptionExpiration)? block.timestamp : dapp.subscriptionExpiration;
    uint256 expires = starts + uint256(_numberOfMonths) * 4 weeks;
    dapp.subscriptionExpiration = expires;

    emit RenewSubscription(_dappAddress, expires);
  }

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
  /// @param _userAddress a parameter just like in doxygen (must be followed by parameter name)
  /// @param _dappAddress a parameter just like in doxygen (must be followed by parameter nam
  /// @return sdfasfasfars 
  function manualReview(address _userAddress, address _dappAddress) public view returns(Cert[] memory, string[] memory){
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

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
  /// @param _certs a parameter just like in doxygen (must be followed by parameter name)
  /// @param _certType a parameter just like in doxygen (must be followed by parameter nam
  /// @return sdfasfasfars 
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

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
  /// @param _value a parameter just like in doxygen (must be followed by parameter name)
  /// @param _visibilityRequests a parameter just like in doxygen (must be followed by parameter nam
  /// @return sdfasfasfars 
  function _isVisible(Visibility _value, Visibility[] memory _visibilityRequests) internal pure returns (bool) {
    for (uint i = 0; i < _visibilityRequests.length; i++) {
        if (_visibilityRequests[i] == _value) {
            return true;
        }
    }

    return false;
  }

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
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

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
  /// @param _certifierAddress a parameter just like in doxygen (must be followed by parameter name)
  /// @param _isApproved a parameter just like in doxygen (must be followed by parameter nam
  function editCertifierWhitelist(address _certifierAddress, bool _isApproved) public onlyOwner{
    certifierWhitelist[_certifierAddress] = _isApproved;
  }

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
  /// @param _fee a parameter just like in doxygen (must be followed by parameter name)
  function editCertifierFee(uint256 _fee) public onlyOwner{
    certifierFee = _fee;
  }

  /// @notice Approves a Dapp to view private user fields. If possible Dapp auto-whitelists user.
  /// @param _fee a parameter just like in doxygen (must be followed by parameter name)
  function editDappSubscriptionFee(uint256 _fee) public onlyOwner{
    dappSubscriptionFee = _fee;
  }

}