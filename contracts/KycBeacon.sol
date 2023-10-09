// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";

interface IKycBeaconConsumer {
  function kycAdmin() external view returns (address);
  function autoWhitelist(address, bool[] memory) external;
}

contract KycBeacon is Ownable {

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

  mapping(address => User) users;
  mapping(address => bool) certifierWhitelist;
  mapping(address => Certifier) certifiers;
  mapping(address => Dapp) dapps;

  // Fee paid to the certifiers for eveluating users 
  uint256 certifierFee;

  // Fee paid to the contract by the dapps
  // Will be adjusted regularly based on number of participating dapps and user demand
  uint256 dappSubscriptionFee;

  // Ultimately the fee paid to kycBeacon has to be just slightly more than 
  // (number of users requesting certification) x certifierFee

  // only works if 
  // dappSubscriptionFee = (number of users requesting certification) x certifierFee / (number of dapps paying subscription)

  error ValidCertExists(address user, address certifier, CertType certType);
  error PendingCertMissing(address user, address certifier, CertType certType);

  event RegisterCertifier(address indexed certifier, string website);
  event RegisterDapp(address indexed dappAddress, address dappAdmin); 
  event RenewSubscription(address indexed dappAddress, uint256 expires); 
  event CertificationRequest(address indexed user, CertType indexed certType);
  event CertificationInitiated(address indexed user, address indexed certifier, CertType indexed certType);
  event CertificationPassed(address indexed user, address indexed certifier, CertType indexed certType);
  event CertificationFailed(address indexed user, address indexed certifier, CertType indexed certType);

  constructor(uint256 _certifierFee, uint256 _dappSubscriptionFee) {
    certifierFee = _certifierFee;
    dappSubscriptionFee = _dappSubscriptionFee;
  }

  // USER FUNCTIONS
  function submitSupportingDocs(bytes calldata data, CertType certType) public {

    ( string memory name, 
      string memory email, 
      string memory phone,
      string memory passportHash,
      string memory driversLicenseHash, 
      string memory taxReturnHash ) = abi.decode(data, (string,string,string,string,string,string));

    User storage user = users[msg.sender];
    user.name = name;
    user.email = email;
    user.phone = phone;
    user.passportHash = passportHash;
    user.driversLicenseHash = driversLicenseHash;
    user.taxReturnHash = taxReturnHash;

    // Cert memory cert = Cert(certType, Status.REQUESTED, msg.sender, block.timestamp);
    // User storage user = users[userAddress];
    // Cert[] storage certs = user.certs;

    emit CertificationRequest(msg.sender, certType);
  }

  function viewUser(address _userAddress) public view returns(Cert[] memory, string[] memory){
    require(msg.sender == _userAddress, "not authorized to view user data");

    User storage user = users[_userAddress];

    string[] memory userInfo = new string[](6);
    userInfo[0] = user.name;
    userInfo[1] = user.email;
    userInfo[2] = user.phone;
    userInfo[3] = user.passportHash;
    userInfo[4] = user.driversLicenseHash;
    userInfo[5] = user.taxReturnHash;

    // can I just return the user struct instead of destructureing it here?
    return(user.certs, userInfo);
  }


  function approveDapp(address dappAddress) public {
    User storage user = users[msg.sender];
    Dapp storage dapp = dapps[dappAddress];

    user.approvedDapps[dappAddress] = true;

    if(dapp.autoWhitelist){
      bool[] memory _certs = new bool[](4);
      _certs[0] = _isValidCert(CertType.KYC, user.certs);
      _certs[1] = _isValidCert(CertType.AML, user.certs);
      _certs[2] = _isValidCert(CertType.REG_D, user.certs);
      _certs[3] = _isValidCert(CertType.ALL, user.certs);

      IKycBeaconConsumer(dappAddress).autoWhitelist(msg.sender, _certs);
    }
  }

  function editApprovedDapp(address dappAddress, bool isApproved) public {
    User storage user = users[msg.sender];
    user.approvedDapps[dappAddress] = isApproved;
  }

  // CERTIFIER FUNCTIONS
  function registerCertifier(address certifierAddress, string memory website, string memory taxId) public {
    Certifier storage certifier = certifiers[certifierAddress];
    certifier.website = website;
    certifier.taxId = taxId;

    emit RegisterCertifier(msg.sender, website);
  }

  function initiate(address userAddress, CertType certType) public {
    require(certifierWhitelist[msg.sender], "Not whitelisted");

    // Certifiers have one week to complete certification or it is claimable by another provider
    Cert memory cert = Cert(certType, Status.PENDING, msg.sender, block.timestamp + 1 weeks);
    User storage user = users[userAddress];
    Cert[] storage certs = user.certs;

    // check for old cert of the same certType
    // 3 possibilities
    // i) cert exists but is expired --> overwrite it
    // ii) cert does not exist --> push it
    // iii) valid cert exists --> do nothing
    uint foundAt = _findCertType(certs, certType);
    if(foundAt != type(uint256).max && certs[foundAt].expiration < block.timestamp){
      certs[foundAt] = cert;
    } else if (foundAt == type(uint256).max) {
      certs.push(cert);
    } else{
      revert ValidCertExists(userAddress, certs[foundAt].certifiedBy, certType);
    }
    
  }

  function pass(address userAddress, CertType certType, uint expiresOn) public {
    require(certifierWhitelist[msg.sender], "Not whitelisted");

    Cert memory cert = Cert(certType, Status.PASS, msg.sender, expiresOn);
    User storage user = users[userAddress];
    Cert[] storage certs = user.certs;

    uint foundAt = _findCertType(certs, certType);
    if(foundAt != type(uint256).max && 
      certs[foundAt].certifiedBy == msg.sender && 
      certs[foundAt].status == Status.PENDING 
    ){
      certs[foundAt] = cert;
      emit CertificationPassed(userAddress, msg.sender, certType);
    } else{
      revert PendingCertMissing(userAddress, msg.sender, certType);
    }
  }

  function fail(address userAddress, CertType certType) public {
    require(certifierWhitelist[msg.sender], "Not whitelisted");

    User storage user = users[userAddress];
    Cert[] storage certs = user.certs;

    uint foundAt = _findCertType(certs, certType);

    // delete failed pending Cert
    if(foundAt != type(uint256).max && 
      certs[foundAt].certifiedBy == msg.sender && 
      certs[foundAt].status == Status.PENDING 
    ){
      for(uint i = foundAt; i < certs.length - 1; i++){
        certs[i] = certs[i+1];
      }
      certs.pop();
      emit CertificationFailed(userAddress, msg.sender, certType);

    } else{
      revert PendingCertMissing(userAddress, msg.sender, certType);
    }
  }

  function _findCertType(Cert[] memory certs, CertType certType ) internal pure returns(uint){
    uint foundAt = type(uint256).max;
    for(uint i; i< certs.length; i++ ){
      if(certs[i].certType == certType){
        foundAt = i;
        break;
      }
    }
    return foundAt;
  }

  // DAPP FUNCTIONS
  function registerDapp(uint8 numberOfMonths, address dappAddress, Visibility[] calldata visibilitySettings, bool isAutoWhitelist) public payable {
    require(msg.value == uint256(numberOfMonths) * dappSubscriptionFee, "Subscription unpaid");
    require(msg.sender == IKycBeaconConsumer(dappAddress).kycAdmin(), "Only kycAdmin can register");

    Dapp storage dapp = dapps[dappAddress];
    dapp.subscriptionExpiration = block.timestamp + uint256(numberOfMonths) * 4 weeks;
    dapp.visibilityRequests = visibilitySettings;
    dapp.autoWhitelist = isAutoWhitelist;

    emit RegisterDapp(dappAddress, msg.sender); 
  }

  function viewDapp(address dappAddress) public view returns(Dapp memory){
    require(msg.sender == IKycBeaconConsumer(dappAddress).kycAdmin(), "Only kycAdmin can view");
    return dapps[dappAddress];
  }

  function renewSubscription(uint8 numberOfMonths, address dappAddress) public payable {
    require(msg.value == uint256(numberOfMonths) * dappSubscriptionFee, "Subscription unpaid");
    Dapp storage dapp = dapps[dappAddress];

    uint256 starts = (block.timestamp > dapp.subscriptionExpiration)? block.timestamp : dapp.subscriptionExpiration;
    uint256 expires = starts + uint256(numberOfMonths) * 4 weeks;
    dapp.subscriptionExpiration = expires;

    emit RenewSubscription(dappAddress, expires);
  }

  function manualReview(address userAddress, address dappAddress) public view returns(Cert[] memory, string[] memory){
    User storage user = users[userAddress];
    Dapp memory dapp = dapps[dappAddress];

    require(user.approvedDapps[dappAddress], "Dapp not permitted");
    require(msg.sender == IKycBeaconConsumer(dappAddress).kycAdmin(), "Sender not permitted");

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

  function _isVisible(Visibility _value, Visibility[] memory _visibilityRequests) internal pure returns (bool) {
    for (uint i = 0; i < _visibilityRequests.length; i++) {
        if (_visibilityRequests[i] == _value) {
            return true;
        }
    }

    return false;
  }

  function _isValidCert(CertType _value, Cert[] memory _certs) internal view returns (bool) {
    for (uint i = 0; i < _certs.length; i++) {
        if (_certs[i].certType == _value && _certs[i].status == Status.PASS && block.timestamp < _certs[i].expiration) {
            return true;
        }
    }

    return false;
  }

  // ADMIN FUNCTIONS
  function editCertifierWhitelist(address certifierAddress, bool isApproved) public onlyOwner{
    certifierWhitelist[certifierAddress] = isApproved;
  }

  function editCertifierFee(uint256 _fee) public onlyOwner{
    certifierFee = _fee;
  }

  function editDappSubscriptionFee(uint256 _fee) public onlyOwner{
    dappSubscriptionFee = _fee;
  }

}