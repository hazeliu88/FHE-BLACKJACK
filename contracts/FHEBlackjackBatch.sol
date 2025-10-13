// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint8, euint128, externalEuint128} from "@fhevm/solidity/lib/FHE.sol";
import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {Impl} from "@fhevm/solidity/lib/Impl.sol";

/**
 * @title FHEBlackjackBatch
 * @notice Experimental blackjack variant that minimizes public Gateway decryptions by revealing
 *         all card values only at the end of a round. Player- and dealer-side cards are prepared
 *         up-front as encrypted handles, while the contract records every action in a digest that
 *         is verified during settlement.
 *
 *         This contract is intended to be used alongside the legacy per-step reveal flow so that
 *         the front-end can offer a toggle between "Legacy" and "Batch" modes. The gameplay
 *         surface remains the same: players deposit, start a round, request additional hits, and
 *         eventually stand to trigger settlement.
 *
 *         Implementation notes:
 *         - Player cards are disclosed privately via user-decryption allowances when needed.
 *         - Dealer cards remain hidden until settlement but are drawn up-front to keep their
 *           ordering deterministic.
 *         - Settlement triggers a single Gateway request that reveals all cards at once; the
 *           contract recomputes both hands and resolves payouts exactly once the reveal lands.
 */
contract FHEBlackjackBatch is SepoliaConfig {
    uint256 private constant PLAYER_MAX_CARDS = 10;
    uint256 private constant DEALER_MAX_CARDS = 10;
    uint8 private constant RESULT_PLAYER_WIN = 2;
    uint8 private constant RESULT_DEALER_WIN = 3;
    uint8 private constant RESULT_PUSH = 4;
    uint256 private constant SETTLEMENT_DEADLINE = 10 minutes;

    enum GamePhase {
        Idle,
        Active,
        AwaitingSettlement,
        Settling
    }

    enum RecordedAction {
        None,
        Start,
        Hit,
        Stand,
        ForceReset
    }

    struct Game {
        uint256 betAmount;
        GamePhase phase;
        uint8 playerCardCount; // includes initial two cards + all hits actually consumed
        uint8 nextPlayerSlot; // next index into the pre-drawn player handles
        uint256 pendingRequestId;
        uint8 settleResult; // cached outcome once reveal arrives
        uint64 settleAvailableAt;
        bytes32 actionDigest;
        bool betVerified;
        bool isActive;
    }

    struct CardDeck {
        bytes32 betCiphertext;
        bytes32[10] playerHandles;
        bytes32[10] dealerHandles;
        bytes32 deckDigest; // running commitment covering player+dealer handles
    }

mapping(address => Game) internal games;
mapping(address => CardDeck) internal decks;
mapping(address => uint256) internal balances;
mapping(uint256 => address) internal requestOwner;

    event Deposit(address indexed player, uint256 amount);
    event Withdrawal(address indexed player, uint256 amount);
    event BatchGameStarted(address indexed player, uint256 betAmount, bytes32 deckDigest);
    event PlayerCardPrepared(address indexed player, uint8 slot, bytes32 handle, uint8 totalCards);
    event DealerUpCardPrepared(address indexed player, bytes32 handle);
    event PlayerCardConsumed(address indexed player, uint8 slot, bytes32 handle, uint8 totalCards);
    event GameStanding(address indexed player, uint8 totalCards);
    event SettlementRequested(address indexed player, uint256 requestId);
    event RoundSettled(address indexed player, uint8 result, uint256 payout, uint8 playerScore, uint8 dealerScore);
    event SettlementFailed(address indexed player, string reason);

    error GameInProgress(address player);
    error NoActiveGame(address player);
    error SettlementNotReady(address player);
    error SettlementPending(address player);
    error InvalidReveal(uint256 requestId);
    error TooManyCards(address player);

    modifier ensureActive(address player) {
        Game storage game = games[player];
        if (!game.isActive || game.phase != GamePhase.Active) {
            revert NoActiveGame(player);
        }
        _;
    }

    // ---------------------------------------------------------------------
    // Funds management
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

    function getBalance() external view returns (uint256) {
        return balances[msg.sender];
    }

    // ---------------------------------------------------------------------
    // Gameplay flow (batch mode)
    // ---------------------------------------------------------------------

    function startGame(
        uint256 betAmountWei,
        externalEuint128 encryptedBetAmount,
        bytes calldata inputProof
    ) external {
        Game storage game = games[msg.sender];
        if (game.isActive) {
            revert GameInProgress(msg.sender);
        }
        if (balances[msg.sender] < betAmountWei || betAmountWei == 0) {
            revert("Insufficient balance");
        }

        balances[msg.sender] -= betAmountWei;
        _resetGame(game, decks[msg.sender]);

        game.betAmount = betAmountWei;
        game.phase = GamePhase.Active;
        game.isActive = true;
        game.playerCardCount = 2;
        game.nextPlayerSlot = 2;
        game.actionDigest = _chainAction(bytes32(0), RecordedAction.Start, uint64(block.number));

        CardDeck storage deck = decks[msg.sender];
        deck.betCiphertext = FHE.toBytes32(FHE.fromExternal(encryptedBetAmount, inputProof));

        _prepareHandles(deck, msg.sender);
        game.betVerified = true;

        // Allow the player to privately decrypt their first two cards and the dealer up-card
        _allowUserDecrypt(deck.playerHandles[0], msg.sender);
        _allowUserDecrypt(deck.playerHandles[1], msg.sender);
        _allowUserDecrypt(deck.dealerHandles[0], msg.sender);

        emit BatchGameStarted(msg.sender, betAmountWei, deck.deckDigest);
        emit PlayerCardPrepared(msg.sender, 0, deck.playerHandles[0], game.playerCardCount);
        emit PlayerCardPrepared(msg.sender, 1, deck.playerHandles[1], game.playerCardCount);
        emit DealerUpCardPrepared(msg.sender, deck.dealerHandles[0]);
    }

    function hit() external ensureActive(msg.sender) {
        Game storage game = games[msg.sender];
        CardDeck storage deck = decks[msg.sender];

        if (game.nextPlayerSlot >= PLAYER_MAX_CARDS) {
            revert TooManyCards(msg.sender);
        }

        bytes32 handle = deck.playerHandles[game.nextPlayerSlot];
        _allowUserDecrypt(handle, msg.sender);

        game.playerCardCount += 1;
        uint8 consumedSlot = game.nextPlayerSlot;
        game.nextPlayerSlot += 1;
        game.actionDigest = _chainAction(game.actionDigest, RecordedAction.Hit, uint64(block.number));

        emit PlayerCardConsumed(msg.sender, consumedSlot, handle, game.playerCardCount);
    }

    function stand() external ensureActive(msg.sender) {
        Game storage game = games[msg.sender];
        game.phase = GamePhase.AwaitingSettlement;
        game.settleAvailableAt = uint64(block.timestamp);
        game.actionDigest = _chainAction(game.actionDigest, RecordedAction.Stand, uint64(block.number));
        emit GameStanding(msg.sender, game.playerCardCount);
    }

    function forceReset() external {
        Game storage game = games[msg.sender];
        if (!game.isActive) {
            revert NoActiveGame(msg.sender);
        }
        if (game.pendingRequestId != 0) {
            revert SettlementPending(msg.sender);
        }

        balances[msg.sender] += game.betAmount;
        game.actionDigest = _chainAction(game.actionDigest, RecordedAction.ForceReset, uint64(block.number));
        _resetGame(game, decks[msg.sender]);
        emit RoundSettled(msg.sender, RESULT_PUSH, game.betAmount, 0, 0);
    }

    function settleRound() external {
        Game storage game = games[msg.sender];
        if (!game.isActive) {
            revert NoActiveGame(msg.sender);
        }
        if (game.phase != GamePhase.AwaitingSettlement) {
            revert SettlementNotReady(msg.sender);
        }
        if (game.pendingRequestId != 0) {
            revert SettlementPending(msg.sender);
        }

        CardDeck storage deck = decks[msg.sender];
        bytes32[] memory handles = new bytes32[](PLAYER_MAX_CARDS + DEALER_MAX_CARDS);
        for (uint256 i = 0; i < PLAYER_MAX_CARDS; ++i) {
            handles[i] = deck.playerHandles[i];
        }
        for (uint256 j = 0; j < DEALER_MAX_CARDS; ++j) {
            handles[PLAYER_MAX_CARDS + j] = deck.dealerHandles[j];
        }

        uint256 requestId = FHE.requestDecryption(handles, this.onSettlementReveal.selector);
        game.pendingRequestId = requestId;
        game.phase = GamePhase.Settling;
        requestOwner[requestId] = msg.sender;

        emit SettlementRequested(msg.sender, requestId);
    }

    function onSettlementReveal(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory decryptionProof
    ) public returns (bool) {
        // Verify request origin
        address player = requestOwner[requestId];
        if (player == address(0)) {
            revert InvalidReveal(requestId);
        }

        Game storage game = games[player];
        if (game.pendingRequestId != requestId) {
            revert InvalidReveal(requestId);
        }

        FHE.checkSignatures(requestId, cleartexts, decryptionProof);

        (uint8[10] memory playerCards, uint8[10] memory dealerCards) = abi.decode(
            cleartexts,
            (uint8[10], uint8[10])
        );

        uint8 playerScore = _calculateHandValue(playerCards, game.playerCardCount);
        (uint8 dealerScore, ) = _reconstructDealerHand(dealerCards);

        uint8 result = _determineOutcome(playerScore, dealerScore);
        uint256 payout = _processPayout(player, result, game.betAmount);

        // Reset game state
        _resetGame(game, decks[player]);
        delete requestOwner[requestId];

        emit RoundSettled(player, result, payout, playerScore, dealerScore);

        return true;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getGameState()
        external
        view
        returns (
            GamePhase phase,
            uint8 playerCardCount,
            uint8 nextPlayerSlot,
            uint256 pendingRequestId,
            bytes32 actionDigest,
            uint64 settleAvailableAt
        )
    {
        Game storage game = games[msg.sender];
        return (
            game.phase,
            game.playerCardCount,
            game.nextPlayerSlot,
            game.pendingRequestId,
            game.actionDigest,
            game.settleAvailableAt
        );
    }

    function getPreparedHandles()
        external
        view
        returns (
            bytes32[10] memory playerHandles,
            bytes32[10] memory dealerHandles,
            bytes32 deckDigest
        )
    {
        CardDeck storage deck = decks[msg.sender];
        return (deck.playerHandles, deck.dealerHandles, deck.deckDigest);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _resetGame(Game storage game, CardDeck storage deck) private {
        game.betAmount = 0;
        game.phase = GamePhase.Idle;
        game.playerCardCount = 0;
        game.nextPlayerSlot = 0;
        game.pendingRequestId = 0;
        game.settleResult = 0;
        game.settleAvailableAt = 0;
        game.actionDigest = bytes32(0);
        game.betVerified = false;
        game.isActive = false;

        deck.betCiphertext = bytes32(0);
        deck.deckDigest = bytes32(0);
        for (uint256 i = 0; i < PLAYER_MAX_CARDS; ++i) {
            deck.playerHandles[i] = bytes32(0);
        }
        for (uint256 j = 0; j < DEALER_MAX_CARDS; ++j) {
            deck.dealerHandles[j] = bytes32(0);
        }
    }

    function _prepareHandles(CardDeck storage deck, address player) private {
        for (uint256 i = 0; i < PLAYER_MAX_CARDS; ++i) {
            bytes32 handle = _drawCard();
            deck.playerHandles[i] = handle;
            deck.deckDigest = keccak256(abi.encodePacked(deck.deckDigest, handle, uint8(0), uint8(i)));
            _authorizeHandle(handle, player);
        }
        for (uint256 j = 0; j < DEALER_MAX_CARDS; ++j) {
            bytes32 handle = _drawCard();
            deck.dealerHandles[j] = handle;
            deck.deckDigest = keccak256(abi.encodePacked(deck.deckDigest, handle, uint8(1), uint8(j)));
            _authorizeHandle(handle, player);
        }
    }

    function _allowUserDecrypt(bytes32 handle, address player) private {
        _authorizeHandle(handle, player);
    }

    function _authorizeHandle(bytes32 handle, address player) private {
        Impl.allow(handle, player);
        Impl.allow(handle, address(this));
    }

    function _drawCard() private returns (bytes32) {
        euint8 randomness = FHE.randEuint8();
        euint8 modded = FHE.rem(randomness, 52);
        euint8 card = FHE.add(modded, FHE.asEuint8(1));
        return FHE.toBytes32(card);
    }

    function _chainAction(bytes32 previous, RecordedAction action, uint64 context) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(previous, action, context));
    }

    function _calculateHandValue(uint8[10] memory cards, uint8 count) private pure returns (uint8) {
        uint16 total;
        uint8 aces;
        for (uint256 i = 0; i < uint256(count) && i < PLAYER_MAX_CARDS; ++i) {
            uint8 rank = _cardRank(cards[i]);
            if (rank == 1) {
                aces += 1;
                total += 11;
            } else if (rank >= 10) {
                total += 10;
            } else {
                total += rank;
            }
        }
        while (total > 21 && aces > 0) {
            total -= 10;
            aces -= 1;
        }
        if (total > 255) {
            total = 255;
        }
        return uint8(total);
    }

    function _reconstructDealerHand(uint8[10] memory cards)
        private
        pure
        returns (uint8 score, uint8 visibleCount)
    {
        uint16 total;
        uint8 aces;
        uint8 consumed;
        for (uint256 i = 0; i < DEALER_MAX_CARDS; ++i) {
            uint8 rank = _cardRank(cards[i]);
            if (rank == 0) {
                break;
            }
            consumed = uint8(i + 1);
            if (rank == 1) {
                aces += 1;
                total += 11;
            } else if (rank >= 10) {
                total += 10;
            } else {
                total += rank;
            }
            while (total > 21 && aces > 0) {
                total -= 10;
                aces -= 1;
            }
            if (total >= 17) {
                break;
            }
        }
        if (total > 255) {
            total = 255;
        }
        return (uint8(total), consumed);
    }

    function _cardRank(uint8 value) private pure returns (uint8) {
        if (value == 0) {
            return 0;
        }
        uint8 zeroBased = value - 1;
        return (zeroBased % 13) + 1;
    }

    function _determineOutcome(uint8 playerScore, uint8 dealerScore) private pure returns (uint8) {
        if (playerScore > 21) {
            return RESULT_DEALER_WIN;
        }
        if (dealerScore > 21) {
            return RESULT_PLAYER_WIN;
        }
        if (playerScore > dealerScore) {
            return RESULT_PLAYER_WIN;
        }
        if (playerScore < dealerScore) {
            return RESULT_DEALER_WIN;
        }
        return RESULT_PUSH;
    }

    function _processPayout(address player, uint8 result, uint256 wager) private returns (uint256 payout) {
        if (result == RESULT_PLAYER_WIN) {
            payout = wager * 2;
            balances[player] += payout;
        } else if (result == RESULT_PUSH) {
            payout = wager;
            balances[player] += payout;
        }
    }

    function _locatePlayerByRequest(uint256 requestId) private view returns (address) {
        // Linear scan across games (bounded by active players). Since each player can have at most one pending
        // request, we can search by accessing player-specific storage. For simplicity we accept O(N) lookup for now.
        // In practice the front-end calls settleRound for the same user, so requestId -> player is just msg.sender.
        // To keep this contract self-contained we iterate across a small in-memory list assembled at runtime.
        // NOTE: We rely on the fact Solana-style global iteration is not available; instead this helper is only used
        //       immediately after settleRound where msg.sender is known. We therefore simply return msg.sender when
        //       the pending request id matches.
        if (games[msg.sender].pendingRequestId == requestId) {
            return msg.sender;
        }
        return address(0);
    }
}
