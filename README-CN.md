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

## 🔍 公平性与排障工具

### 页面内审计面板
- 连接钱包后，页面底部的 **Fairness Audit** 面板可直接查询玩家地址或交易哈希。
- 面板会展示 `GameStarted → (Player/DealerCardRevealed) → RoundSettled` 的完整时间线，并在出现重复牌时标记 `DuplicateCardResampled`。
- 顶部的待处理揭牌计时条会在 15 秒/45 秒时高亮提醒，提示是否需要尝试 Force Reset。

### CLI 回合验证
```bash
# 拉取指定玩家近期的所有事件
node scripts/verify-round.js --player=0xYourAddress --fromBlock=latest-2000

# 审计指定交易
node scripts/verify-round.js --tx=0xYourTxHash
```
- 所有卡牌都会以真实点数+花色（例如 `Q♣️`）显示，方便核对每一步揭牌。

### 揭牌看门狗
```bash
# 默认 5 秒轮询，45 秒告警
npm run watch-pending -- --player=0xYourAddress

# 自定义阈值（30 秒告警，15 秒打印状态）
npm run watch-pending -- --player=0xYourAddress --threshold=30 --warnEvery=15
```
- 脚本会直接调用链上 `getGameState()`（通过 `--player` 填入的地址作为 `msg.sender`）并记录每个 `pendingRequestId` 的持续时间。
- 超过阈值会输出 `⚠️ Reveal still pending ...` 日志，可用于本地守护或 CI 监控。
- 浏览器端的 relayer SDK 会在加载 WASM 时校验 Gateway/KMS 签名；若需进一步调试，可在开发者工具中查看 `[relayer]` 日志或参考 Zama 官方文档获取详细的 attestation 步骤。

## 🔗 有用链接

- [Zama官网](https://zama.ai)
- [FHEVM文档](https://docs.zama.ai/fhevm)
- [Zama Discord](https://discord.gg/zama) (获取测试ETH)
