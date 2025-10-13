#!/usr/bin/env node
import { ethers } from 'ethers';
import fs from 'fs';
import path from 'path';
import dotenv from 'dotenv';

dotenv.config();

const args = process.argv.slice(2);
const options = Object.fromEntries(
  args
    .filter((arg) => arg.includes('='))
    .map((arg) => {
      const [key, value] = arg.split('=');
      return [key.replace(/^--/, ''), value];
    })
);

if (!options.contract && fs.existsSync('index.html')) {
  const match = fs
    .readFileSync('index.html', 'utf8')
    .match(/const contractAddress = "(0x[a-fA-F0-9]{40})"/);
  if (match) {
    options.contract = match[1];
  }
}

const rpcUrl = process.env.SEPOLIA_RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com';
const provider = new ethers.JsonRpcProvider(rpcUrl);

const artifactPath = options.artifact || path.join('artifacts', 'contracts', 'FHEBlackjackGateway.sol', 'FHEBlackjackGateway.json');
if (!fs.existsSync(artifactPath)) {
  console.error(`Artifact not found at ${artifactPath}`);
  process.exit(1);
}

const { abi } = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));

if (!options.contract) {
  console.error('Missing contract address. Provide --contract=0x..., set FHE_BLACKJACK_ADDRESS, or ensure index.html contains the address.');
  process.exit(1);
}

const contract = new ethers.Contract(options.contract, abi, provider);

const normalizeBlock = (value) => {
  if (!value || value === 'latest') {
    return undefined;
  }
  const parsed = Number(value);
  if (Number.isNaN(parsed)) {
    throw new Error(`Invalid block number: ${value}`);
  }
  return parsed;
};

const formatBlockRange = (fromBlock, toBlock) => {
  const from = normalizeBlock(fromBlock);
  const to = normalizeBlock(toBlock);
  return { fromBlock: from, toBlock: to };
};

const formatWei = (wei) => {
  try {
    return `${ethers.formatEther(wei)} ETH`;
  } catch (_) {
    return wei.toString();
  }
};

const printTimeline = (entries) => {
  entries
    .sort((a, b) => Number(a.blockNumber) - Number(b.blockNumber))
    .forEach((entry) => {
      console.log(`\n#${entry.blockNumber} tx ${entry.transactionHash}`);
      console.log(`  ${entry.label}`);
      entry.notes.forEach((note) => console.log(`    - ${note}`));
    });
};

const decodeReceipt = async (txHash) => {
  const receipt = await provider.getTransactionReceipt(txHash);
  if (!receipt) {
    throw new Error(`Transaction ${txHash} not found`);
  }
  const iface = new ethers.Interface(abi);
  const entries = [];
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== options.contract.toLowerCase()) {
      continue;
    }
    try {
      const parsed = iface.parseLog(log);
      entries.push({
        blockNumber: log.blockNumber,
        transactionHash: log.transactionHash,
        label: parsed.name,
        notes: describeEvent(parsed)
      });
    } catch (_) {
      // ignore logs that do not decode
    }
  }
  if (!entries.length) {
    console.log('No FHEBlackjackGateway events emitted in this transaction.');
    return;
  }
  printTimeline(entries);
};

const describeEvent = (parsed) => {
  const name = parsed.name || parsed.event;
  const args = parsed.args;
  switch (name) {
    case 'GameStarted': {
      const { player, betAmount, requestId } = args;
      return [
        `player: ${player}`,
        `bet: ${formatWei(betAmount)}`,
        `requestId: ${requestId}`
      ];
    }
    case 'InitialHandRevealed': {
      const { player, playerCardOne, playerCardTwo, dealerUpCard, requestId } = args;
      return [
        `player: ${player}`,
        `initial cards: ${cardLabel(playerCardOne)}, ${cardLabel(playerCardTwo)}`,
        `dealer up card: ${cardLabel(dealerUpCard)}`,
        `requestId: ${requestId}`
      ];
    }
    case 'PlayerCardRevealed': {
      const { player, cardValue, cardIndex, newScore, requestId } = args;
      return [
        `player: ${player}`,
        `card index: ${cardIndex}`,
        `card: ${cardLabel(cardValue)}`,
        `new score: ${newScore}`,
        `requestId: ${requestId}`
      ];
    }
    case 'DealerCardRevealed': {
      const { player, cardValue, cardIndex, newScore, requestId } = args;
      return [
        `player: ${player}`,
        `dealer card index: ${cardIndex}`,
        `card: ${cardLabel(cardValue)}`,
        `dealer score: ${newScore}`,
        `requestId: ${requestId}`
      ];
    }
    case 'RoundSettled': {
      const { player, result, payout, playerScore, dealerScore } = args;
      return [
        `player: ${player}`,
        `result code: ${result}`,
        `payout: ${formatWei(payout)}`,
        `player score: ${playerScore}`,
        `dealer score: ${dealerScore}`
      ];
    }
    case 'InvalidBetReveal': {
      const { player, claimedAmount, revealedAmount } = args;
      return [
        `player: ${player}`,
        `claimed: ${formatWei(claimedAmount)}`,
        `revealed: ${formatWei(revealedAmount)}`
      ];
    }
    case 'DuplicateCardResampled': {
      const { player, isPlayerHand, cardIndex, requestId } = args;
      return [
        `player: ${player}`,
        `hand: ${isPlayerHand ? 'player' : 'dealer'}`,
        `card index: ${cardIndex}`,
        `requestId: ${requestId}`
      ];
    }
    case 'ForceReset': {
      const { player } = args;
      return [`player: ${player}`];
    }
    default:
      const fragment = parsed.eventFragment;
      if (fragment) {
        return fragment.inputs.map((input, idx) => `${input.name}: ${args[idx]}`);
      }
      return [];
  }
};

const cardLabel = (value) => {
  const val = Number(value);
  if (!Number.isFinite(val) || val <= 0) {
    return 'unknown';
  }
  const zeroBased = val - 1;
  const rank = (zeroBased % 13) + 1;
  const suitIndex = Math.floor(zeroBased / 13);
  const suits = ['♠️', '♥️', '♦️', '♣️'];
  const faces = {
    1: 'A',
    11: 'J',
    12: 'Q',
    13: 'K'
  };
  const rankLabel = faces[rank] || `${rank}`;
  const suit = suits[suitIndex] || '♠️';
  return `${rankLabel}${suit}`;
};

const queryByPlayer = async (player) => {
  const range = formatBlockRange(options.fromBlock, options.toBlock);
  if (range.toBlock === undefined || range.fromBlock === undefined) {
    const latest = await provider.getBlockNumber();
    if (range.toBlock === undefined) {
      range.toBlock = latest;
    }
    if (range.fromBlock === undefined) {
      const DEFAULT_LOOKBACK = 2_000;
      range.fromBlock = Math.max(0, range.toBlock - DEFAULT_LOOKBACK);
    }
  }
  const filters = [
    contract.filters.GameStarted(player),
    contract.filters.InitialHandRevealed(player),
    contract.filters.PlayerCardRevealed(player),
    contract.filters.DealerCardRevealed(player),
    contract.filters.RoundSettled(player),
    contract.filters.InvalidBetReveal(player),
    contract.filters.DuplicateCardResampled(player),
    contract.filters.ForceReset(player)
  ];

  const results = await Promise.allSettled(
    filters.map((filter) => contract.queryFilter(filter, range.fromBlock, range.toBlock))
  );

  const entries = results
    .flatMap((result) => (result.status === 'fulfilled' ? result.value : []))
    .map((event) => ({
      blockNumber: event.blockNumber,
      transactionHash: event.transactionHash,
      label: event.event,
      notes: describeEvent(event)
    }));

  const rejected = results.filter((result) => result.status === 'rejected');
  if (rejected.length) {
    console.warn('⚠️  Some queries failed. Try narrowing the block range with --fromBlock/--toBlock.');
  }

  if (!entries.length) {
    console.log('No events found for player in the specified range.');
    return;
  }
  printTimeline(entries);
};

const main = async () => {
  try {
    if (options.tx) {
      await decodeReceipt(options.tx);
      return;
    }
    if (options.player) {
      await queryByPlayer(options.player);
      return;
    }
    console.log('Usage: node scripts/verify-round.js --player=0x... [--fromBlock=] [--toBlock=]');
    console.log('   or: node scripts/verify-round.js --tx=0x...');
  } catch (error) {
    console.error(error.message || error);
    process.exit(1);
  }
};

await main();
