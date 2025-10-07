import '@fhevm/hardhat-plugin';
import dotenv from 'dotenv';
dotenv.config();

const normalizePrivateKey = (key) => {
  if (!key) return undefined;
  return key.startsWith('0x') ? key : `0x${key}`;
};

const PRIVATE_KEY = normalizePrivateKey(process.env.PRIVATE_KEY);
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com';

/** @type import('hardhat/config').HardhatUserConfig */
export default {
  solidity: {
    version: '0.8.24',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    localhost: {
      url: 'http://127.0.0.1:8545',
    },
    sepolia: {
      url: SEPOLIA_RPC_URL,
      chainId: 11155111,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
  },
};
