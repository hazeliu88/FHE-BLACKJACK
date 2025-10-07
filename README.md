# 🃏 FHE Blackjack

一个基于Zama FHE（完全同态加密）技术的隐私21点游戏。所有手牌都在链上加密，实现真正的隐私游戏体验。

## ✨ 特色功能

- 🔐 **隐藏手牌**: 玩家和庄家手牌完全加密
- 🎯 **防作弊**: 服务器无法透视玩家牌面
- ⚡ **实时游戏**: 链上实时决策和结算
- 💰 **公平奖励**: 21点1.5倍，普通胜利2倍

## 🚀 快速开始

### 1. 安装依赖
```bash
npm run setup
```

### 2. 配置环境变量
编辑 `.env` 文件：
```bash
# Sepolia 测试网私钥 (包含 0x 前缀)
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Sepolia RPC，默认使用公共节点，可替换为 Infura/Alchemy 等服务
SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
```

### 3. 编译合约
```bash
npm run compile
```

### 4. 本地测试（无FHE）
```bash
# 启动本地节点（新终端）
npm run node

# 测试合约部署和基础功能（另一个终端）
npm run test-local
```

### 5. 部署到 Sepolia (Zama FHE) 测试网
```bash
npm run deploy-sepolia
```

### 6. 启动前端
```bash
npm run dev
```

## 🔧 项目结构

```
fhe-blackjack/
├── contracts/
│   └── FHEBlackjack.sol      # 主合约
├── scripts/
│   ├── deploy.js             # 部署脚本
│   └── test-local.js         # 本地测试
├── index.html                # 前端界面
├── package.json
└── hardhat.config.js
```

## 🌐 网络配置

- **本地网络**: `npm run deploy` (localhost:8545)
- **Sepolia (Zama FHE)**: `npm run deploy-sepolia` (默认 `https://ethereum-sepolia-rpc.publicnode.com`)

## 💡 重要说明

1. **本地测试限制**: FHE 功能依赖 Zama 在 Sepolia 部署的协处理器，本地 Hardhat 网络无法执行真正的同态运算
2. **私钥安全**: 永远不要提交包含真实私钥的 `.env` 文件，示例私钥仅供本地测试使用
3. **测试 ETH**: 需要为钱包准备 Sepolia ETH，可使用 [Alchemy Faucet](https://www.alchemy.com/faucets/ethereum-sepolia) 或其他公开水龙头

## 🃏 游戏规则

### 基础规则
- 目标：手牌总和尽可能接近21点，但不超过
- A可算作1或11，J/Q/K算作10
- 庄家16及以下必须要牌，17及以上必须停牌

### 奖励机制
- 🎯 **Blackjack** (2张牌21点): 1.5倍投注
- 🏆 **普通胜利**: 2倍投注
- 🤝 **平局 (Push)**: 退还投注
- 😔 **失败**: 失去投注

### 游戏流程
1. 下注并开始游戏
2. 获得2张初始手牌
3. 选择要牌(Hit)或停牌(Stand)
4. 庄家自动按规则行动
5. 比较结果并结算

## 🔗 有用链接

- [Zama官网](https://zama.ai)
- [FHEVM文档](https://docs.zama.ai/fhevm)
- [Zama Discord](https://discord.gg/zama) (获取测试ETH)