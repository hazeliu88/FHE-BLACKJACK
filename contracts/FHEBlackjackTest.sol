// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract FHEBlackjackTest {
    struct Game {
        uint256 betAmount;
        uint8 playerCardCount;
        uint8 dealerCardCount; 
        uint8 gameState; // 0: not started, 1: in progress, 2: player won, 3: dealer won, 4: push
        bool isActive;
        uint8[10] playerCards;
        uint8[10] dealerCards;
        uint8 playerScore;
        uint8 dealerScore;
    }

    mapping(address => Game) public games;
    mapping(address => uint256) public balances;
    address public owner;
    uint256 private nonce;

    event GameStarted(address indexed player, uint256 betAmount);
    event GameEnded(address indexed player, uint8 result);
    event Deposit(address indexed player, uint256 amount);
    event CardDealt(address indexed player, bool isPlayer, uint8 card);
    event GameForceReset(address indexed player);

    constructor() {
        owner = msg.sender;
        nonce = block.timestamp; // Better initial nonce
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    function deposit() external payable {
        require(msg.value > 0, "Must deposit something");
        balances[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function startGameTest(uint256 betAmount) external {
        require(!games[msg.sender].isActive, "Game already in progress");
        require(balances[msg.sender] >= betAmount, "Insufficient balance");

        // Deduct bet from balance immediately
        balances[msg.sender] -= betAmount;

        Game storage game = games[msg.sender];
        game.betAmount = betAmount;
        game.playerCardCount = 0;
        game.dealerCardCount = 0;
        game.gameState = 1;
        game.isActive = true;
        game.playerScore = 0;
        game.dealerScore = 0;

        // Deal initial cards (2 to player, 2 to dealer)
        dealCard(msg.sender, true);  // Player card 1
        dealCard(msg.sender, false); // Dealer card 1 (hidden)
        dealCard(msg.sender, true);  // Player card 2
        dealCard(msg.sender, false); // Dealer card 2

        // Check for natural blackjack
        if (game.playerScore == 21) {
            if (game.dealerScore == 21) {
                endGame(msg.sender, 4); // Push
            } else {
                endGame(msg.sender, 2); // Player blackjack wins
            }
        }

        emit GameStarted(msg.sender, betAmount);
    }

    function dealCard(address player, bool isPlayer) private {
        Game storage game = games[player];
        
        // Better randomness using multiple sources
        uint256 randomSource = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            uint256(block.prevrandao),
            block.number,
            msg.sender,
            nonce,
            isPlayer ? game.playerCardCount : game.dealerCardCount
        )));
        nonce = uint256(keccak256(abi.encodePacked(randomSource, nonce, blockhash(block.number - 1))));
        
        // Generate card value (1-13, where 1=Ace, 11=Jack, 12=Queen, 13=King)
        uint8 cardValue = uint8((randomSource % 13) + 1);
        
        if (isPlayer) {
            require(game.playerCardCount < 10, "Hand is full");
            game.playerCards[game.playerCardCount] = cardValue;
            game.playerCardCount++;
            game.playerScore = calculateHandValue(game.playerCards, game.playerCardCount);
        } else {
            require(game.dealerCardCount < 10, "Hand is full");
            game.dealerCards[game.dealerCardCount] = cardValue;
            game.dealerCardCount++;
            game.dealerScore = calculateHandValue(game.dealerCards, game.dealerCardCount);
        }
        
        emit CardDealt(player, isPlayer, cardValue);
    }

    function calculateHandValue(uint8[10] memory cards, uint8 cardCount) private pure returns (uint8) {
        uint16 total = 0;
        uint8 aces = 0;

        for (uint8 i = 0; i < cardCount; i++) {
            uint8 card = cards[i];
            if (card == 1) {
                aces++;
                total += 11;
            } else if (card > 10) {
                total += 10;
            } else {
                total += card;
            }
        }

        while (total > 21 && aces > 0) {
            total -= 10;
            aces--;
        }

        if (total > 255) {
            total = 255;
        }

        return uint8(total);
    }

    function hit() external {
        require(games[msg.sender].isActive, "No active game");
        require(games[msg.sender].gameState == 1, "Game not in progress");

        dealCard(msg.sender, true);
        
        // Check for bust
        if (games[msg.sender].playerScore > 21) {
            endGame(msg.sender, 3); // Dealer wins (player bust)
        }
    }

    function stand() external {
        require(games[msg.sender].isActive, "No active game");
        require(games[msg.sender].gameState == 1, "Game not in progress");

        Game storage game = games[msg.sender];
        
        // Dealer plays: hits on 16 and below, stands on 17 and above
        while (game.dealerScore < 17) {
            dealCard(msg.sender, false);
        }
        
        // Determine winner
        uint8 result;
        if (game.dealerScore > 21) {
            result = 2; // Player wins (dealer bust)
            balances[msg.sender] += game.betAmount * 2; // Return bet + winnings
        } else if (game.playerScore > game.dealerScore) {
            result = 2; // Player wins
            balances[msg.sender] += game.betAmount * 2;
        } else if (game.playerScore < game.dealerScore) {
            result = 3; // Dealer wins
            // Bet already deducted, no return
        } else {
            result = 4; // Push
            balances[msg.sender] += game.betAmount; // Return bet only
        }

        endGame(msg.sender, result);
    }

    function endGame(address player, uint8 result) private {
        games[player].gameState = result;
        games[player].isActive = false;
        
        // Special handling for blackjack win
        if (result == 2 && games[player].playerScore == 21 && games[player].playerCardCount == 2) {
            balances[player] += games[player].betAmount * 3 / 2;
        }
        
        emit GameEnded(player, result);
    }

    function forceReset() external {
        Game storage game = games[msg.sender];
        require(game.isActive, "No active game");

        balances[msg.sender] += game.betAmount;
        delete games[msg.sender];

        emit GameForceReset(msg.sender);
    }


    function getBalance() external view returns (uint256) {
        return balances[msg.sender];
    }

    function getGameState() external view returns (bool isActive, uint8 state) {
        Game memory game = games[msg.sender];
        return (game.isActive, game.gameState);
    }

    function getPlayerCards() external view returns (uint8[] memory cards, uint8 count, uint8 score) {
        Game memory game = games[msg.sender];
        uint8[] memory playerCards = new uint8[](game.playerCardCount);
        for (uint8 i = 0; i < game.playerCardCount; i++) {
            playerCards[i] = game.playerCards[i];
        }
        return (playerCards, game.playerCardCount, game.playerScore);
    }

    function getDealerCards() external view returns (uint8[] memory cards, uint8 count, uint8 score) {
        Game memory game = games[msg.sender];
        uint8[] memory dealerCards = new uint8[](game.dealerCardCount);
        for (uint8 i = 0; i < game.dealerCardCount; i++) {
            dealerCards[i] = game.dealerCards[i];
        }
        return (dealerCards, game.dealerCardCount, game.dealerScore);
    }

    function getGameDetails() external view returns (
        bool isActive,
        uint8 state,
        uint8 playerScore,
        uint8 dealerScore,
        uint8 playerCardCount,
        uint8 dealerCardCount
    ) {
        Game memory game = games[msg.sender];
        return (
            game.isActive,
            game.gameState,
            game.playerScore,
            game.dealerScore,
            game.playerCardCount,
            game.dealerCardCount
        );
    }

    function withdrawOwner() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }
}