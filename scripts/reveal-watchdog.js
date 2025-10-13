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

const requireOption = (name) => {
  const value = options[name];
  if (!value) {
    console.error(`Missing required option --${name}=...`);
    process.exit(1);
  }
  return value;
};

const normalizeAddress = (input) => {
  try {
    return ethers.getAddress(input);
  } catch (error) {
    console.error(`Invalid address: ${input}`);
    process.exit(1);
  }
};

const rpcUrl = options.rpc || process.env.SEPOLIA_RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com';
const provider = new ethers.JsonRpcProvider(rpcUrl);

const artifactPath = options.artifact || path.join('artifacts', 'contracts', 'FHEBlackjackGateway.sol', 'FHEBlackjackGateway.json');
if (!fs.existsSync(artifactPath)) {
  console.error(`Artifact not found at ${artifactPath}`);
  process.exit(1);
}

const { abi } = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));

let contractAddress = options.contract;
if (!contractAddress && fs.existsSync('index.html')) {
  const match = fs
    .readFileSync('index.html', 'utf8')
    .match(/const contractAddress = "(0x[a-fA-F0-9]{40})"/);
  if (match) {
    contractAddress = match[1];
  }
}

if (!contractAddress) {
  console.error('Missing contract address. Provide --contract=0x..., set in index.html, or use --artifact with address.');
  process.exit(1);
}

const contract = new ethers.Contract(contractAddress, abi, provider);

const playerAddress = normalizeAddress(requireOption('player'));
const intervalMs = (() => {
  if (!options.interval) return 5000;
  const value = Number(options.interval);
  if (!Number.isFinite(value) || value <= 0) {
    console.error('interval must be a positive number (milliseconds).');
    process.exit(1);
  }
  return Math.floor(value);
})();

const thresholdMs = (() => {
  if (!options.threshold) return 45000;
  const value = Number(options.threshold) * 1000;
  if (!Number.isFinite(value) || value <= 0) {
    console.error('threshold must be a positive number (seconds).');
    process.exit(1);
  }
  return Math.floor(value);
})();

const warnEveryMs = (() => {
  if (!options.warnEvery) return thresholdMs;
  const value = Number(options.warnEvery) * 1000;
  if (!Number.isFinite(value) || value <= 0) {
    console.error('warnEvery must be a positive number (seconds).');
    process.exit(1);
  }
  return Math.floor(value);
})();

let lastPendingId = 0n;
let lastLoggedId = 0n;
let pendingSince = null;
let lastWarningTs = 0;

const formatTimestamp = () => new Date().toISOString();

const describeState = (state) => {
  const isActive = Boolean(state[0]);
  const gameState = Number(state[1]);
  const playerScore = Number(state[2]);
  const dealerUp = Number(state[3]);
  const playerCardCount = Number(state[4]);
  const dealerCardCount = Number(state[5]);
  const pendingId = BigInt(state[6]);
  return { isActive, gameState, playerScore, dealerUp, playerCardCount, dealerCardCount, pendingId };
};

const log = (message) => console.log(`[${formatTimestamp()}] ${message}`);

const poll = async () => {
  try {
    const state = await contract.getGameState({ from: playerAddress });
    const info = describeState(state);
    const { pendingId, isActive } = info;
    const now = Date.now();

    if (pendingId !== lastPendingId) {
      if (pendingId !== 0n) {
        pendingSince = now;
        lastWarningTs = 0;
        log(`Pending request detected: id=${pendingId.toString()} (game active=${isActive})`);
      } else if (lastPendingId !== 0n && pendingSince) {
        const duration = Math.floor((now - pendingSince) / 1000);
        log(`Pending request ${lastPendingId.toString()} resolved after ${duration}s.`);
        pendingSince = null;
        lastLoggedId = 0n;
      }
      lastPendingId = pendingId;
    }

    if (pendingId !== 0n) {
      if (!pendingSince) {
        pendingSince = now;
      }
      const elapsedMs = now - pendingSince;
      if (elapsedMs >= thresholdMs && (now - lastWarningTs >= warnEveryMs)) {
        const elapsedSec = Math.floor(elapsedMs / 1000);
        log(`⚠️  Reveal still pending (${elapsedSec}s). request=${pendingId.toString()} | player=${playerAddress}`);
        lastWarningTs = now;
      } else if (lastLoggedId !== pendingId) {
        const elapsedSec = Math.floor((now - pendingSince) / 1000);
        log(`⏳ Waiting on request ${pendingId.toString()} (${elapsedSec}s).`);
        lastLoggedId = pendingId;
      }
    }
  } catch (error) {
    log(`Error while polling: ${error?.reason || error?.message || error}`);
  }
};

log(`Watching pending reveals for ${playerAddress} on contract ${contractAddress} (interval=${intervalMs}ms, threshold=${Math.floor(thresholdMs / 1000)}s)`);

await poll();
const interval = setInterval(poll, intervalMs);

const shutdown = () => {
  clearInterval(interval);
  log('Watchdog stopped.');
  process.exit(0);
};

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
