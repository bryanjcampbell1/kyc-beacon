// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Asset is ERC20 {
  constructor() ERC20("AssetToken", "AST") {
    _mint(msg.sender, 100 ether);
  }

  function mint(uint _amount) public{
    _mint(msg.sender, _amount);
  }
}