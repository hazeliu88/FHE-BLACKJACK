import { ethers } from 'ethers';
import fs from 'fs';
import path from 'path';
import dotenv from 'dotenv';

dotenv.config();

const normalizePrivateKey = (key) => {
  if (!key) return undefined;
  return key.startsWith('0x') ? key : `0x${key}`;
};

async function main() {
  console.log('🃏 Deploying FHE Blackjack Contract...\n');

  const privateKey = normalizePrivateKey(process.env.PRIVATE_KEY);
  if (!privateKey) {
    throw new Error('PRIVATE_KEY not found in .env file');
  }

  const rpcUrl = process.env.SEPOLIA_RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com';
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const deployer = new ethers.Wallet(privateKey, provider);

  console.log('Deployer:', deployer.address);
  console.log('Network: Sepolia (Zama FHE)');

  try {
    const balance = await provider.getBalance(deployer.address);
    console.log('Deployer balance:', ethers.formatEther(balance), 'ETH\n');

    if (balance === 0n) {
      console.log('⚠️  Warning: Deployer has 0 ETH balance');
      console.log('💡 Get Sepolia test ETH from a faucet, e.g. https://www.alchemy.com/faucets/ethereum-sepolia');
      return;
    }

    const contractPath = path.join(
      process.cwd(),
      'artifacts/contracts/FHEBlackjackGateway.sol/FHEBlackjackGateway.json'
    );
    if (!fs.existsSync(contractPath)) {
      throw new Error("Contract not compiled. Run 'npm run compile' first.");
    }

    const contractJson = JSON.parse(fs.readFileSync(contractPath, 'utf8'));
    const contractFactory = new ethers.ContractFactory(
      contractJson.abi,
      contractJson.bytecode,
      deployer
    );

    console.log('🚀 Deploying contract...');
    const blackjack = await contractFactory.deploy();
    await blackjack.waitForDeployment();
    const address = await blackjack.getAddress();

    console.log('🎉 FHEBlackjackGateway deployed to:', address);

    const indexPath = path.join(process.cwd(), 'index.html');
    if (fs.existsSync(indexPath)) {
      let content = fs.readFileSync(indexPath, 'utf8');
      content = content.replace(
        /const contractAddress = "[^"]*"/,
        `const contractAddress = "${address}"`
      );
      fs.writeFileSync(indexPath, content);
      console.log('✅ Frontend updated with contract address!');
    }

    console.log('\n🚀 Ready to play!');
    console.log("Run 'npm run dev' to start the development server");
  } catch (error) {
    console.error('❌ Deployment failed:', error.message);
    if (error.message.includes('insufficient funds')) {
      console.log('💡 Get Sepolia test ETH from a faucet, e.g. https://www.alchemy.com/faucets/ethereum-sepolia');
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
