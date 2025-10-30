# 🃏 FHE Blackjack

A privacy-first blackjack game powered by Zama's fully homomorphic encryption (FHE). All cards remain encrypted on-chain, so neither the dealer nor anyone else can cheat.

**Live:** https://fhe-blackjack-test-2.vercel.app

## What's the idea?

Traditional online blackjack requires you to trust the server. With FHE, the game logic runs encrypted on the blockchain. Your cards stay hidden until it's time to reveal, and the math is done entirely with encrypted data. No central authority, no backdoors.

## Getting started

### Prerequisites
- Node.js 18+
- MetaMask or similar Web3 wallet
- Sepolia test ETH (grab some from a [faucet](https://www.alchemy.com/faucets/ethereum-sepolia))

### Local development

```bash
# Install dependencies
npm install --legacy-peer-deps

# Set up environment
cp .env.example .env
# Edit .env with your Sepolia private key

# Compile contracts
npm run compile

# Start the dev server
npm run dev
```

Then open http://localhost:3000 in your browser.

### Deploy to Sepolia

```bash
npm run deploy-sepolia
```

Update the contract address in `index.html` with the one from the deploy output.

## How it works

1. **Connect wallet** → MetaMask signs your transactions
2. **Deposit ETH** → Funds go into the smart contract
3. **Place bet** → Your bet amount is encrypted before sending to the contract
4. **Game logic** → Everything happens in encrypted form on-chain
5. **Settle** → Results are revealed and payout is calculated

The relayer SDK handles decryption on the frontend—your private keys never leave your browser.

## The stack

- **Smart Contracts:** Solidity with Zama's FHE library
- **Frontend:** Vanilla HTML/JS (no React, keep it simple)
- **FHE:** Zama's FHEVM running on Sepolia
- **Deployment:** Vercel for the frontend, smart contracts on Sepolia

## Game rules

- Get as close to 21 as possible without going over
- Aces count as 1 or 11, face cards are 10
- Dealer hits on 16 or below, stands on 17+
- Blackjack (21 with 2 cards) pays 3:2, regular win pays 2:1

## Verification & auditing

The in-page **Fairness Audit** panel lets you verify any game by address or transaction hash. You'll see the full timeline of events and card reveals.

For developers, there's also a CLI tool:

```bash
# Check a specific player's recent games
node scripts/verify-round.js --player=0xYourAddress --fromBlock=latest-2000

# Audit a transaction
node scripts/verify-round.js --tx=0xYourTxHash
```

## Project structure

```
├── contracts/
│   └── FHEBlackjackBatch.sol  # Main contract
├── scripts/
│   ├── deploy.js              # Deployment
│   ├── verify-round.js        # Game verification
│   └── reveal-watchdog.js     # Monitor pending reveals
├── index.html                 # Frontend
└── package.json
```

## Notes

- FHE operations have latency—game resolution isn't instant
- Gas costs are higher than traditional contracts (that's the price of privacy)
- Contract is deployed on Sepolia; testnet only for now
- Private key in `.env` is for deployment only and never sent to Vercel

## Links

- [Zama](https://zama.ai)
- [FHEVM docs](https://docs.zama.ai/fhevm)
- [Zama Discord](https://discord.gg/zama)

---

**中文文档:** See [README-CN.md](./README-CN.md)
