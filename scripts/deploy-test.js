import hre from 'hardhat';
import fs from 'fs';

async function main() {
  console.log("🚀 Deploying FHE Blackjack Test contract to Sepolia...\n");

  // Get the contract factory
  const FHEBlackjackTest = await hre.ethers.getContractFactory("FHEBlackjackTest");
  
  console.log("📋 Contract compilation successful");
  console.log("💰 Deploying with account:", (await hre.ethers.getSigners())[0].address);

  // Deploy the contract
  const blackjack = await FHEBlackjackTest.deploy();
  await blackjack.waitForDeployment();

  const address = await blackjack.getAddress();
  console.log("✅ FHEBlackjackTest deployed to:", address);

  // Update the contract address in index.html
  const indexPath = 'index.html';
  if (fs.existsSync(indexPath)) {
    let content = fs.readFileSync(indexPath, 'utf8');
    
    // Replace the contract address
    const oldAddressPattern = /const contractAddress = "[^"]+";/;
    const newAddressLine = `const contractAddress = "${address}";`;
    
    if (oldAddressPattern.test(content)) {
      content = content.replace(oldAddressPattern, newAddressLine);
      fs.writeFileSync(indexPath, content);
      console.log("📝 Updated contract address in index.html");
    }
  }

  console.log("\n🎉 Deployment completed!");
  console.log("📋 Contract address:", address);
  console.log("🔗 Etherscan:", `https://sepolia.etherscan.io/address/${address}`);
  console.log("\n💡 Next steps:");
  console.log("1. Run 'npm start' to test the game");
  console.log("2. Connect your wallet and deposit some ETH");
  console.log("3. Enjoy the improved blackjack with real rules!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });