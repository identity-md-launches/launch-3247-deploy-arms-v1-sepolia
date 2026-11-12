// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title The burnable test token Arms is bonded and paid in on Sepolia
/// @notice The launch owner receives the fixed supply at construction and distributes it by transfer.
/// Holders may burn only their own tokens; no callable mint or burnFrom exists after construction.
contract MockToken is ERC20, Ownable {
    uint256 public constant INITIAL_SUPPLY = 1_000_000 ether;

    constructor(address owner_) ERC20("Arms Test Token", "ARMT") Ownable(owner_) {
        _mint(owner_, INITIAL_SUPPLY);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
