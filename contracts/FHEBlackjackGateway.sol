// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint8, euint128, externalEuint128} from "@fhevm/solidity/lib/FHE.sol";
import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

/**
 * @title FHEBlackjackGateway
 * @notice Prototype blackjack contract that uses Zama's Gateway to provide
 *         verifiable card reveals. Gameplay is currently limited to the
 *         opening deal while we iterate on the full hit/stand flow.
 */
contract FHEBlackjackGateway is SepoliaConfig {
    enum PendingAction {
        None,
        InitialDeal,
        PlayerHit,
        DealerReveal,
        CardReplacement
    }

    struct PendingRequest {
        address player;
        PendingAction action;
        uint8 cardIndex;
        uint8 extra;
    }

    struct Game {
        uint256 betAmount;
        uint8 gameState; // 0: idle, 1: in progress, 2: player win, 3: dealer win, 4: push
        bytes32 betCiphertext;
        bool betVerified;
        bool isActive;
        uint8 playerCardCount;
        uint8 dealerCardCount;
        uint8 playerScore;
        uint8 dealerScore;
        bytes32[10] playerCardHandles;
        bytes32[10] dealerCardHandles;
        uint8[10] playerCards;
        uint8[10] dealerCards;
        uint256 pendingRequestId;
        PendingAction pendingAction;
        bool dealerHoleRevealed;
        bool playerBlackjack;
        bool initialRevealComplete;
        uint256 deckMask;
    }

    mapping(address => Game) internal games;
    mapping(address => uint256) internal balances;
    mapping(uint256 => PendingRequest) internal pendingRequests;

    event Deposit(address indexed player, uint256 amount);
    event Withdrawal(address indexed player, uint256 amount);
    event GameStarted(address indexed player, uint256 betAmount, uint256 requestId);
    event InitialHandRevealed(
        address indexed player,
        uint8 playerCardOne,
        uint8 playerCardTwo,
        uint8 dealerUpCard,
        uint256 requestId
    );
    event ForceReset(address indexed player);
    event PlayerCardRevealed(address indexed player, uint8 cardValue, uint8 cardIndex, uint8 newScore, uint256 requestId);
    event DealerCardRevealed(address indexed player, uint8 cardValue, uint8 cardIndex, uint8 newScore, uint256 requestId);
    event RoundSettled(address indexed player, uint8 result, uint256 payout, uint8 playerScore, uint8 dealerScore);
    event InvalidBetReveal(address indexed player, uint256 claimedAmount, uint256 revealedAmount);
    event DuplicateCardResampled(address indexed player, bool isPlayerHand, uint8 cardIndex, uint256 requestId);

    error GameInProgress(address player);
    error NoActiveGame(address player);
    error RevealPending(uint256 requestId);
    error InvalidReveal(uint256 requestId);
    error UnsupportedRevealAction(uint8 action);
    error CardOutOfRange(uint8 value);

    modifier noPendingReveal(Game storage game) {
        if (game.pendingRequestId != 0) {
            revert RevealPending(game.pendingRequestId);
        }
        _;
    }

    // ---------------------------------------------------------------------
    // Player funds
    // ---------------------------------------------------------------------

    function deposit() external payable {
        require(msg.value > 0, "Must deposit something");
        balances[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
        emit Withdrawal(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Gameplay (initial deal prototype)
    // ---------------------------------------------------------------------

    function startGame(
        uint256 betAmountWei,
        externalEuint128 encryptedBetAmount,
        bytes calldata inputProof
    ) external virtual {
        Game storage game = games[msg.sender];
        if (game.isActive) {
            revert GameInProgress(msg.sender);
        }
        if (game.pendingRequestId != 0) {
            revert RevealPending(game.pendingRequestId);
        }

        require(betAmountWei > 0, "Bet must be > 0");
        require(balances[msg.sender] >= betAmountWei, "Insufficient balance");

        balances[msg.sender] -= betAmountWei;

        _resetGame(game);

        game.betAmount = betAmountWei;
        game.betVerified = false;
        game.gameState = 1;
        game.isActive = true;
        game.playerCardCount = 0;
        game.dealerCardCount = 0;
        game.playerScore = 0;
        game.dealerScore = 0;

        euint128 betCipher = FHE.fromExternal(encryptedBetAmount, inputProof);
        game.betCiphertext = FHE.toBytes32(betCipher);

        // Draw four cards: player1, player2, dealerUp, dealerHole
        bytes32 playerCardOne = _drawCard();
        bytes32 playerCardTwo = _drawCard();
        bytes32 dealerUpCard = _drawCard();
        bytes32 dealerHoleCard = _drawCard();

        game.playerCardHandles[0] = playerCardOne;
        game.playerCardHandles[1] = playerCardTwo;
        game.dealerCardHandles[0] = dealerUpCard;
        game.dealerCardHandles[1] = dealerHoleCard;
        game.playerCardCount = 2;
        game.dealerCardCount = 2; // hole card kept encrypted for now

        bytes32[] memory cts = new bytes32[](4);
        cts[0] = playerCardOne;
        cts[1] = playerCardTwo;
        cts[2] = dealerUpCard;
        cts[3] = game.betCiphertext;

        uint256 requestId = FHE.requestDecryption(cts, this.onReveal.selector);
        game.pendingRequestId = requestId;
        game.pendingAction = PendingAction.InitialDeal;
        game.dealerHoleRevealed = false;
        pendingRequests[requestId] = PendingRequest({
            player: msg.sender,
            action: PendingAction.InitialDeal,
            cardIndex: 0,
            extra: 0
        });

        emit GameStarted(msg.sender, betAmountWei, requestId);
    }

    function hit() external virtual {
        Game storage game = games[msg.sender];
        if (!game.isActive) {
            revert NoActiveGame(msg.sender);
        }
        if (game.pendingRequestId != 0) {
            revert RevealPending(game.pendingRequestId);
        }

        uint8 nextIndex = game.playerCardCount;
        require(nextIndex < 10, "Hand full");

        bytes32 handle = _drawCard();
        game.playerCardHandles[nextIndex] = handle;
        game.playerCardCount = nextIndex + 1;

        bytes32[] memory cts = new bytes32[](1);
        cts[0] = handle;
        uint256 requestId = FHE.requestDecryption(cts, this.onReveal.selector);

        game.pendingRequestId = requestId;
        game.pendingAction = PendingAction.PlayerHit;

        pendingRequests[requestId] = PendingRequest({
            player: msg.sender,
            action: PendingAction.PlayerHit,
            cardIndex: nextIndex,
            extra: 0
        });
    }

    function stand() external virtual {
        Game storage game = games[msg.sender];
        if (!game.isActive) {
            revert NoActiveGame(msg.sender);
        }
        if (game.pendingRequestId != 0) {
            revert RevealPending(game.pendingRequestId);
        }

        bytes32[] memory cts = new bytes32[](1);
        cts[0] = game.dealerCardHandles[1];
        uint256 requestId = FHE.requestDecryption(cts, this.onReveal.selector);

        game.pendingRequestId = requestId;
        game.pendingAction = PendingAction.DealerReveal;

        pendingRequests[requestId] = PendingRequest({
            player: msg.sender,
            action: PendingAction.DealerReveal,
            cardIndex: 1,
            extra: 0
        });
    }

    function forceReset() external {
        Game storage game = games[msg.sender];
        if (!game.isActive) {
            revert NoActiveGame(msg.sender);
        }
        if (game.pendingRequestId != 0) {
            revert RevealPending(game.pendingRequestId);
        }

        uint256 wager = game.betAmount;
        balances[msg.sender] += wager;

        _resetGame(game);
        emit ForceReset(msg.sender);
    }

    // ---------------------------------------------------------------------
    // Gateway callback
    // ---------------------------------------------------------------------

    function onReveal(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory decryptionProof
    ) public virtual returns (bool) {
        PendingRequest memory pending = pendingRequests[requestId];
        if (pending.player == address(0)) {
            revert InvalidReveal(requestId);
        }

        FHE.checkSignatures(requestId, cleartexts, decryptionProof);

        Game storage game = games[pending.player];
        if (game.pendingRequestId != requestId) {
            revert InvalidReveal(requestId);
        }

        delete pendingRequests[requestId];
        game.pendingRequestId = 0;

        if (pending.action == PendingAction.InitialDeal) {
            (uint8 cardOne, uint8 cardTwo, uint8 dealerUp, uint128 revealedBet) = abi.decode(
                cleartexts,
                (uint8, uint8, uint8, uint128)
            );

            if (uint256(revealedBet) != game.betAmount) {
                emit InvalidBetReveal(pending.player, game.betAmount, revealedBet);
                balances[pending.player] += game.betAmount;
                _resetGame(game);
                return true;
            }

            game.betVerified = true;
            game.betCiphertext = bytes32(0);
            if (!_assignInitialCard(game, pending.player, cardOne, 0, true)) {
                return true;
            }
            if (!_assignInitialCard(game, pending.player, cardTwo, 1, true)) {
                return true;
            }
            if (!_assignInitialCard(game, pending.player, dealerUp, 0, false)) {
                return true;
            }

            _finalizeInitialHand(game, pending.player, requestId);
        } else if (pending.action == PendingAction.PlayerHit) {
            uint8 cardValue = abi.decode(cleartexts, (uint8));
            _handlePlayerHitReveal(game, pending, cardValue, requestId);
        } else if (pending.action == PendingAction.DealerReveal) {
            uint8 cardValue = abi.decode(cleartexts, (uint8));
            _handleDealerReveal(game, pending, cardValue, requestId);
        } else if (pending.action == PendingAction.CardReplacement) {
            uint8 cardValue = abi.decode(cleartexts, (uint8));
            _handleCardReplacement(game, pending, cardValue, requestId);
        } else {
            revert UnsupportedRevealAction(uint8(pending.action));
        }

        return true;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getBalance() external view returns (uint256) {
        return balances[msg.sender];
    }

    function getGameState()
        external
        view
        returns (
            bool isActive,
            uint8 state,
            uint8 playerScore,
            uint8 dealerUpCard,
            uint8 playerCardCount,
            uint8 dealerCardCount,
            uint256 pendingRequestId
        )
    {
        Game storage game = games[msg.sender];
        return (
            game.isActive,
            game.gameState,
            game.playerScore,
            game.dealerCards[0],
            game.playerCardCount,
            game.dealerCardCount,
            game.pendingRequestId
        );
    }

    function getPlayerCards() external view returns (uint8[] memory cards) {
        Game storage game = games[msg.sender];
        cards = new uint8[](game.playerCardCount);
        for (uint8 i = 0; i < game.playerCardCount; ++i) {
            cards[i] = game.playerCards[i];
        }
    }

    function getDealerVisibleCards() external view returns (uint8[] memory cards) {
        Game storage game = games[msg.sender];
        uint8 visibleCount = 0;
        if (game.dealerCardCount == 0) {
            return new uint8[](0);
        }

        if (game.dealerHoleRevealed) {
            visibleCount = game.dealerCardCount;
        } else {
            visibleCount = 1;
        }
        cards = new uint8[](visibleCount);
        for (uint8 i = 0; i < visibleCount; ++i) {
            cards[i] = game.dealerCards[i];
        }
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _drawCard() internal virtual returns (bytes32) {
        euint8 randomness = FHE.randEuint8();
        euint8 modded = FHE.rem(randomness, 52);
        euint8 card = FHE.add(modded, FHE.asEuint8(1));
        return FHE.toBytes32(card);
    }

    function _calculateHandValue(uint8[10] storage cards, uint8 count) internal view virtual returns (uint8) {
        uint16 total;
        uint8 aces;

        for (uint8 i = 0; i < count; ++i) {
            uint8 card = cards[i];
            if (card == 0) {
                continue;
            }

            uint8 rank = _cardRank(card);
            if (rank == 1) {
                aces++;
                total += 11;
            } else if (rank >= 10) {
                total += 10;
            } else {
                total += rank;
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

    function _resetGame(Game storage game) internal virtual {
        if (game.pendingRequestId != 0) {
            delete pendingRequests[game.pendingRequestId];
            game.pendingRequestId = 0;
        }

        for (uint8 i = 0; i < game.playerCardCount; ++i) {
            game.playerCards[i] = 0;
            game.playerCardHandles[i] = bytes32(0);
        }
        for (uint8 j = 0; j < game.dealerCardCount; ++j) {
            game.dealerCards[j] = 0;
            game.dealerCardHandles[j] = bytes32(0);
        }

        game.betAmount = 0;
        game.betCiphertext = bytes32(0);
        game.betVerified = false;
        game.gameState = 0;
        game.isActive = false;
        game.playerCardCount = 0;
        game.dealerCardCount = 0;
        game.playerScore = 0;
        game.dealerScore = 0;
        game.pendingAction = PendingAction.None;
        game.dealerHoleRevealed = false;
        game.playerBlackjack = false;
        game.initialRevealComplete = false;
        game.deckMask = 0;
    }

    function _cardRank(uint8 cardValue) internal pure returns (uint8) {
        if (cardValue == 0 || cardValue > 52) {
            revert CardOutOfRange(cardValue);
        }
        uint8 zeroBased = cardValue - 1;
        return (zeroBased % 13) + 1;
    }

    function _registerCard(Game storage game, uint8 cardValue) internal returns (bool) {
        if (cardValue == 0 || cardValue > 52) {
            revert CardOutOfRange(cardValue);
        }

        uint256 bit = uint256(1) << (cardValue - 1);
        if ((game.deckMask & bit) != 0) {
            return false;
        }

        game.deckMask |= bit;
        return true;
    }

    function _scheduleCardReplacement(
        Game storage game,
        address player,
        bool isPlayerHand,
        uint8 cardIndex
    ) internal virtual {
        bytes32 handle = _drawCard();
        if (isPlayerHand) {
            game.playerCardHandles[cardIndex] = handle;
            game.playerCards[cardIndex] = 0;
        } else {
            game.dealerCardHandles[cardIndex] = handle;
            game.dealerCards[cardIndex] = 0;
        }

        bytes32[] memory cts = new bytes32[](1);
        cts[0] = handle;
        uint256 requestId = FHE.requestDecryption(cts, this.onReveal.selector);

        game.pendingRequestId = requestId;
        game.pendingAction = PendingAction.CardReplacement;

        pendingRequests[requestId] = PendingRequest({
            player: player,
            action: PendingAction.CardReplacement,
            cardIndex: cardIndex,
            extra: isPlayerHand ? 1 : 2
        });

        emit DuplicateCardResampled(player, isPlayerHand, cardIndex, requestId);
    }

    function _assignInitialCard(
        Game storage game,
        address player,
        uint8 cardValue,
        uint8 cardIndex,
        bool isPlayerHand
    ) internal returns (bool) {
        if (!_registerCard(game, cardValue)) {
            _scheduleCardReplacement(game, player, isPlayerHand, cardIndex);
            return false;
        }

        if (isPlayerHand) {
            game.playerCards[cardIndex] = cardValue;
        } else {
            game.dealerCards[cardIndex] = cardValue;
        }

        return true;
    }

    function _finalizeInitialHand(Game storage game, address player, uint256 requestId) internal {
        if (game.initialRevealComplete) {
            return;
        }

        if (game.playerCards[0] == 0 || game.playerCards[1] == 0 || game.dealerCards[0] == 0) {
            return;
        }

        game.playerScore = _calculateHandValue(game.playerCards, game.playerCardCount);
        game.playerBlackjack = (game.playerScore == 21 && game.playerCardCount == 2);
        game.pendingAction = PendingAction.None;
        game.initialRevealComplete = true;

        emit InitialHandRevealed(player, game.playerCards[0], game.playerCards[1], game.dealerCards[0], requestId);
    }

    function _handlePlayerHitReveal(
        Game storage game,
        PendingRequest memory pending,
        uint8 cardValue,
        uint256 requestId
    ) internal virtual {
        game.pendingAction = PendingAction.None;

        if (!_registerCard(game, cardValue)) {
            _scheduleCardReplacement(game, pending.player, true, pending.cardIndex);
            return;
        }

        game.playerCards[pending.cardIndex] = cardValue;

        uint8 newScore = _calculateHandValue(game.playerCards, game.playerCardCount);
        game.playerScore = newScore;

        emit PlayerCardRevealed(pending.player, cardValue, pending.cardIndex, newScore, requestId);

        if (newScore > 21) {
            _finalizeRound(game, pending.player, 3);
        }
    }

    function _handleDealerReveal(
        Game storage game,
        PendingRequest memory pending,
        uint8 cardValue,
        uint256 requestId
    ) internal virtual {
        if (!_registerCard(game, cardValue)) {
            _scheduleCardReplacement(game, pending.player, false, pending.cardIndex);
            return;
        }

        game.dealerCards[pending.cardIndex] = cardValue;
        if (pending.cardIndex == 1) {
            game.dealerHoleRevealed = true;
        }

        uint8 newScore = _calculateHandValue(game.dealerCards, game.dealerCardCount);
        game.dealerScore = newScore;
        game.pendingAction = PendingAction.None;

        emit DealerCardRevealed(pending.player, cardValue, pending.cardIndex, newScore, requestId);

        if (newScore < 17 && game.dealerCardCount < 10) {
            uint8 nextIndex = game.dealerCardCount;
            bytes32 handle = _drawCard();
            game.dealerCardHandles[nextIndex] = handle;
            game.dealerCardCount = nextIndex + 1;

            bytes32[] memory cts = new bytes32[](1);
            cts[0] = handle;
            uint256 newRequestId = FHE.requestDecryption(cts, this.onReveal.selector);

            game.pendingRequestId = newRequestId;
            game.pendingAction = PendingAction.DealerReveal;

            pendingRequests[newRequestId] = PendingRequest({
                player: pending.player,
                action: PendingAction.DealerReveal,
                cardIndex: nextIndex,
                extra: 0
            });

            return;
        }

        uint8 result;
        if (newScore > 21) {
            result = 2;
        } else if (newScore == game.playerScore) {
            result = 4;
        } else if (newScore < game.playerScore) {
            result = 2;
        } else {
            result = 3;
        }

        _finalizeRound(game, pending.player, result);
    }

    function _handleCardReplacement(
        Game storage game,
        PendingRequest memory pending,
        uint8 cardValue,
        uint256 requestId
    ) internal virtual {
        bool isPlayerHand = (pending.extra == 1);

        if (!_registerCard(game, cardValue)) {
            _scheduleCardReplacement(game, pending.player, isPlayerHand, pending.cardIndex);
            return;
        }

        if (isPlayerHand) {
            game.playerCards[pending.cardIndex] = cardValue;
        } else {
            game.dealerCards[pending.cardIndex] = cardValue;
            if (pending.cardIndex == 1) {
                game.dealerHoleRevealed = true;
            }
        }

        game.pendingAction = PendingAction.None;

        if (!game.initialRevealComplete) {
            _finalizeInitialHand(game, pending.player, requestId);
            return;
        }

        if (isPlayerHand) {
            uint8 newScore = _calculateHandValue(game.playerCards, game.playerCardCount);
            game.playerScore = newScore;
            emit PlayerCardRevealed(pending.player, cardValue, pending.cardIndex, newScore, requestId);

            if (newScore > 21) {
                _finalizeRound(game, pending.player, 3);
            }

            return;
        }

        uint8 newDealerScore = _calculateHandValue(game.dealerCards, game.dealerCardCount);
        game.dealerScore = newDealerScore;
        emit DealerCardRevealed(pending.player, cardValue, pending.cardIndex, newDealerScore, requestId);

        if (newDealerScore < 17 && game.dealerCardCount < 10) {
            uint8 nextIndex = game.dealerCardCount;
            bytes32 handle = _drawCard();
            game.dealerCardHandles[nextIndex] = handle;
            game.dealerCardCount = nextIndex + 1;

            bytes32[] memory cts = new bytes32[](1);
            cts[0] = handle;
            uint256 newRequestId = FHE.requestDecryption(cts, this.onReveal.selector);

            game.pendingRequestId = newRequestId;
            game.pendingAction = PendingAction.DealerReveal;

            pendingRequests[newRequestId] = PendingRequest({
                player: pending.player,
                action: PendingAction.DealerReveal,
                cardIndex: nextIndex,
                extra: 0
            });

            return;
        }

        uint8 result;
        if (newDealerScore > 21) {
            result = 2;
        } else if (newDealerScore == game.playerScore) {
            result = 4;
        } else if (newDealerScore < game.playerScore) {
            result = 2;
        } else {
            result = 3;
        }

        _finalizeRound(game, pending.player, result);
    }

    function _finalizeRound(Game storage game, address player, uint8 result) internal virtual {
        if (!game.isActive) {
            return;
        }

        uint256 wager = game.betAmount;
        uint256 payout;

        if (result == 2) {
            payout = wager * 2;
            if (game.playerBlackjack) {
                payout += wager / 2;
            }
            balances[player] += payout;
        } else if (result == 4) {
            payout = wager;
            balances[player] += payout;
        }

        game.gameState = result;
        game.isActive = false;
        game.betAmount = 0;
        game.pendingAction = PendingAction.None;
        game.pendingRequestId = 0;

        emit RoundSettled(player, result, payout, game.playerScore, game.dealerScore);
    }
}
