// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {externalEuint128} from "@fhevm/solidity/lib/FHE.sol";
import {FHEBlackjackGateway} from "../FHEBlackjackGateway.sol";

/**
 * @dev Harness contract for unit testing. It replaces the on-chain gateway
 *      interactions with deterministic card draws and mocked reveal payloads.
 *      DO NOT deploy this contract in production environments.
 */
contract FHEBlackjackGatewayHarness is FHEBlackjackGateway {
    uint8[] private deck;
    uint256 private deckIndex;
    uint256 private requestCounter;

    mapping(uint256 => bytes) public mockCleartexts;
    mapping(address => uint8[10]) private stagedPlayerValues;
    mapping(address => uint8[10]) private stagedDealerValues;

    function setDeck(uint8[] memory cards) external {
        delete deck;
        for (uint256 i = 0; i < cards.length; i++) {
            uint8 value = cards[i];
            require(value >= 1 && value <= 52, "Card out of range");
            deck.push(value);
        }
        deckIndex = 0;
    }

    function remainingCards() external view returns (uint256) {
        return deck.length - deckIndex;
    }

    function performMockReveal(uint256 requestId) external {
        bytes memory payload = mockCleartexts[requestId];
        require(payload.length != 0, "No pending payload");
        delete mockCleartexts[requestId];
        onReveal(requestId, payload, "");
    }

    function startGame(
        uint256 betAmountWei,
        externalEuint128 /*encryptedBetAmount*/,
        bytes calldata /*inputProof*/
    ) public override {
        Game storage game = games[msg.sender];
        require(!game.isActive, "Game already in progress");
        require(game.pendingRequestId == 0, "Reveal pending");
        require(betAmountWei > 0, "Bet must be > 0");
        require(balances[msg.sender] >= betAmountWei, "Insufficient balance");

        balances[msg.sender] -= betAmountWei;
        _resetGame(game);

        game.betAmount = betAmountWei;
        game.betCiphertext = bytes32(uint256(betAmountWei));
        game.betVerified = false;
        game.gameState = 1;
        game.isActive = true;
        game.playerCardCount = 0;
        game.dealerCardCount = 0;
        game.playerScore = 0;
        game.dealerScore = 0;

        uint8[4] memory values;
        bytes32[4] memory handles;
        (values[0], handles[0]) = _pullCard();
        (values[1], handles[1]) = _pullCard();
        (values[2], handles[2]) = _pullCard();
        (values[3], handles[3]) = _pullCard();

        stagedPlayerValues[msg.sender][0] = values[0];
        stagedPlayerValues[msg.sender][1] = values[1];
        stagedDealerValues[msg.sender][0] = values[2];
        stagedDealerValues[msg.sender][1] = values[3];

        game.playerCardHandles[0] = handles[0];
        game.playerCardHandles[1] = handles[1];
        game.dealerCardHandles[0] = handles[2];
        game.dealerCardHandles[1] = handles[3];
        game.playerCardCount = 2;
        game.dealerCardCount = 2;

        uint256 requestId = _nextRequestId();
        game.pendingRequestId = requestId;
        game.pendingAction = PendingAction.InitialDeal;
        pendingRequests[requestId] = PendingRequest({
            player: msg.sender,
            action: PendingAction.InitialDeal,
            cardIndex: 0,
            extra: 0
        });
        uint128 wager = uint128(betAmountWei);
        mockCleartexts[requestId] = abi.encode(values[0], values[1], values[2], wager);

        emit GameStarted(msg.sender, betAmountWei, requestId);
    }

    function hit() public override {
        Game storage game = games[msg.sender];
        require(game.isActive, "No active game");
        require(game.pendingRequestId == 0, "Reveal pending");

        uint8 nextIndex = game.playerCardCount;
        require(nextIndex < 10, "Hand full");

        (uint8 value, bytes32 handle) = _pullCard();
        stagedPlayerValues[msg.sender][nextIndex] = value;
        game.playerCardHandles[nextIndex] = handle;
        game.playerCardCount = nextIndex + 1;

        uint256 requestId = _nextRequestId();
        game.pendingRequestId = requestId;
        game.pendingAction = PendingAction.PlayerHit;
        pendingRequests[requestId] = PendingRequest({
            player: msg.sender,
            action: PendingAction.PlayerHit,
            cardIndex: nextIndex,
            extra: 0
        });
        mockCleartexts[requestId] = abi.encode(value);
    }

    function stand() public override {
        Game storage game = games[msg.sender];
        require(game.isActive, "No active game");
        require(game.pendingRequestId == 0, "Reveal pending");

        uint256 requestId = _nextRequestId();
        game.pendingRequestId = requestId;
        game.pendingAction = PendingAction.DealerReveal;
        pendingRequests[requestId] = PendingRequest({
            player: msg.sender,
            action: PendingAction.DealerReveal,
            cardIndex: 1,
            extra: 0
        });
        mockCleartexts[requestId] = abi.encode(stagedDealerValues[msg.sender][1]);
    }

    function onReveal(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory /*decryptionProof*/
    ) public override returns (bool) {
        PendingRequest memory pending = pendingRequests[requestId];
        if (pending.player == address(0)) {
            revert InvalidReveal(requestId);
        }

        Game storage game = games[pending.player];
        if (game.pendingRequestId != requestId) {
            revert InvalidReveal(requestId);
        }

        delete pendingRequests[requestId];
        delete mockCleartexts[requestId];
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

    function _scheduleCardReplacement(
        Game storage game,
        address player,
        bool isPlayerHand,
        uint8 cardIndex
    ) internal override {
        (uint8 value, bytes32 handle) = _pullCard();

        if (isPlayerHand) {
            stagedPlayerValues[player][cardIndex] = value;
            game.playerCardHandles[cardIndex] = handle;
            game.playerCards[cardIndex] = 0;
        } else {
            stagedDealerValues[player][cardIndex] = value;
            game.dealerCardHandles[cardIndex] = handle;
            game.dealerCards[cardIndex] = 0;
        }

        uint256 requestId = _nextRequestId();
        game.pendingRequestId = requestId;
        game.pendingAction = PendingAction.CardReplacement;

        pendingRequests[requestId] = PendingRequest({
            player: player,
            action: PendingAction.CardReplacement,
            cardIndex: cardIndex,
            extra: isPlayerHand ? 1 : 2
        });

        mockCleartexts[requestId] = abi.encode(value);
        emit DuplicateCardResampled(player, isPlayerHand, cardIndex, requestId);
    }

    function _handleDealerReveal(
        Game storage game,
        PendingRequest memory pending,
        uint8 cardValue,
        uint256 requestId
    ) internal override {
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
            (uint8 value, bytes32 handle) = _pullCard();
            stagedDealerValues[pending.player][nextIndex] = value;
            game.dealerCardHandles[nextIndex] = handle;
            game.dealerCardCount = nextIndex + 1;

            uint256 newRequestId = _nextRequestId();
            game.pendingRequestId = newRequestId;
            game.pendingAction = PendingAction.DealerReveal;

            pendingRequests[newRequestId] = PendingRequest({
                player: pending.player,
                action: PendingAction.DealerReveal,
                cardIndex: nextIndex,
                extra: 0
            });
            mockCleartexts[newRequestId] = abi.encode(value);
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

    function _pullCard() internal returns (uint8 value, bytes32 handle) {
        require(deckIndex < deck.length, "Deck exhausted");
        value = deck[deckIndex];
        deckIndex += 1;
        handle = bytes32(uint256(value));
    }

    function _nextRequestId() internal returns (uint256) {
        requestCounter += 1;
        return requestCounter;
    }

    function _drawCard() internal pure override returns (bytes32) {
        revert("Harness overrides draw path");
    }
}
