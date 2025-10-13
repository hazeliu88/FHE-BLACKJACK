import fs from 'fs';
import path from 'path';
import hre from 'hardhat';

async function main() {
  console.log('🃏 Deploying FHEBlackjackBatch...\n');

  const [deployer] = await hre.ethers.getSigners();
  console.log('Deployer:', deployer.address);
  console.log('Network:', hre.network.name);

  const balance = await deployer.provider.getBalance(deployer.address);
  console.log('Deployer balance:', hre.ethers.formatEther(balance), 'ETH\n');
  if (balance === 0n) {
    console.log('⚠️  Deployer balance is zero. Please fund the account with Sepolia ETH before deploying.');
    return;
  }

  const Factory = await hre.ethers.getContractFactory('FHEBlackjackBatch');
  console.log('🚀 Deploying contract...');
  const contract = await Factory.deploy();
  await contract.waitForDeployment();

  const address = await contract.getAddress();
  console.log('\n🎉 FHEBlackjackBatch deployed to:', address);
  console.log('🔗 Explorer:', `https://sepolia.etherscan.io/address/${address}`);

  const indexPath = path.join(process.cwd(), 'index.html');
  if (fs.existsSync(indexPath)) {
    let content = fs.readFileSync(indexPath, 'utf8');
    content = content.replace(
      /const batchContractAddress = "[^"]*"/,
      `const batchContractAddress = "${address}"`
    );
    fs.writeFileSync(indexPath, content);
    console.log('✅ Frontend updated with batch contract address!');
  } else {
    console.log('⚠️  index.html not found. Update batchContractAddress manually.');
  }

  console.log('\nNext steps:');
  console.log(`1. Update batchContractAddress in index.html to ${address}`);
  console.log('2. npm run prepare-wasm');
  console.log('3. npm run dev');
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
