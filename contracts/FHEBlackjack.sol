// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint8, euint32, externalEuint32} from '@fhevm/solidity/lib/FHE.sol';
import {SepoliaConfig} from '@fhevm/solidity/config/ZamaConfig.sol';

contract FHEBlackjack is SepoliaConfig {
    address public owner;

    struct Game {
        euint8[10] playerCards;
        euint8[10] dealerCards;
        uint8 playerCardCount;
        uint8 dealerCardCount;
        euint32 betAmount;
        uint8 gameState; // 0: not started, 1: in progress, 2: player won, 3: dealer won, 4: push
        bool isActive;
    }

    mapping(address => Game) public games;
    mapping(address => euint32) private playerBalances;

    event GameStarted(address indexed player, uint256 betAmount);
    event GameEnded(address indexed player, uint8 result); // 2: win, 3: lose, 4: push
    event Deposit(address indexed player, uint256 amount);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, 'Not owner');
        _;
    }

    function deposit() external payable {
        require(msg.value > 0, 'Must deposit something');

        euint32 currentBalance = playerBalances[msg.sender];
        euint32 depositAmount = FHE.asEuint32(uint32(msg.value));
        playerBalances[msg.sender] = FHE.add(currentBalance, depositAmount);
        FHE.allowThis(playerBalances[msg.sender]);
        FHE.allow(playerBalances[msg.sender], msg.sender);

        emit Deposit(msg.sender, msg.value);
    }

    function startGame(externalEuint32 encryptedBetAmount, bytes calldata inputProof) external {
        require(!games[msg.sender].isActive, 'Game already in progress');

        euint32 betAmount = FHE.fromExternal(encryptedBetAmount, inputProof);

        Game storage game = games[msg.sender];
        game.betAmount = betAmount;
        game.playerCardCount = 0;
        game.dealerCardCount = 0;
        game.gameState = 1;
        game.isActive = true;

        // Deal initial cards
        dealCard(msg.sender, true);
        dealCard(msg.sender, false);
        dealCard(msg.sender, true);

        emit GameStarted(msg.sender, 0);
    }

    function hit() external {
        require(games[msg.sender].isActive, 'No active game');
        require(games[msg.sender].gameState == 1, 'Game not in progress');

        dealCard(msg.sender, true);
    }

    function stand() external {
        require(games[msg.sender].isActive, 'No active game');
        require(games[msg.sender].gameState == 1, 'Game not in progress');

        uint8 result = uint8(uint256(keccak256(abi.encodePacked(block.prevrandao, block.timestamp, msg.sender))) % 3) + 2;
        endGame(msg.sender, result);
    }

    function dealCard(address player, bool toPlayer) private {
        Game storage game = games[player];
        uint8 index = toPlayer ? game.playerCardCount : game.dealerCardCount;
        require(index < 10, 'Hand is full');

        uint8 cardPlain = uint8((uint256(keccak256(abi.encodePacked(block.number, block.timestamp, player, toPlayer, index))) % 13) + 1);
        euint8 cardValue = FHE.asEuint8(cardPlain);

        if (toPlayer) {
            game.playerCards[index] = cardValue;
            game.playerCardCount = index + 1;
        } else {
            game.dealerCards[index] = cardValue;
            game.dealerCardCount = index + 1;
        }
    }

    function endGame(address player, uint8 result) private {
        Game storage game = games[player];
        game.gameState = result;
        game.isActive = false;

        if (result == 2) {
            euint32 payout = FHE.mul(game.betAmount, FHE.asEuint32(2));
            playerBalances[player] = FHE.add(playerBalances[player], payout);
        } else if (result == 4) {
            playerBalances[player] = FHE.add(playerBalances[player], game.betAmount);
        }

        FHE.allowThis(playerBalances[player]);
        FHE.allow(playerBalances[player], player);

        emit GameEnded(player, result);
    }

    function getBalance() external view returns (euint32) {
        return playerBalances[msg.sender];
    }

    function getGameState() external view returns (bool isActive, uint8 state) {
        Game storage game = games[msg.sender];
        return (game.isActive, game.gameState);
    }

    function withdrawOwner() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    function getContractBalance() external view onlyOwner returns (uint256) {
        return address(this).balance;
    }
}
