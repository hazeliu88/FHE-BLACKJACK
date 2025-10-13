const { ethers } = require("hardhat");
const assert = require("node:assert/strict");

const { parseEther, formatEther } = ethers;

async function getPendingRequestId(contract) {
  const state = await contract.getGameState();
  return BigInt(state[6]);
}

describe("FHEBlackjackGatewayHarness", function () {
  async function deployHarness() {
    const [player] = await ethers.getSigners();
    const Harness = await ethers.getContractFactory("FHEBlackjackGatewayHarness");
    const harness = await Harness.deploy();
    await harness.waitForDeployment();
    return { harness, player };
  }

  it("simulates initial deal via mocked gateway reveal", async function () {
    const { harness, player } = await deployHarness();

    await harness.connect(player).deposit({ value: parseEther("1") });
    await harness.setDeck([10, 8, 9, 7, 5, 4]);

    const bet = parseEther("0.1");
    const tx = await harness.connect(player).startGame(bet, ethers.ZeroHash, '0x');
    const receipt = await tx.wait();
    const started = receipt.logs.find((log) => log.fragment?.name === "GameStarted");
    assert(started, "GameStarted event not emitted");
    const requestId = started.args.requestId;

    await harness.performMockReveal(requestId);

    const playerCards = await harness.connect(player).getPlayerCards();
    assert.deepStrictEqual(playerCards.map((c) => Number(c)), [10, 8]);

    const state = await harness.getGameState();
    assert.strictEqual(state[0], true);
    assert.strictEqual(Number(state[2]), 18);
    assert.strictEqual(Number(state[4]), 2);
  });

  it("resamples duplicate cards during the opening deal", async function () {
    const { harness, player } = await deployHarness();

    await harness.connect(player).deposit({ value: parseEther("1") });
    await harness.setDeck([5, 5, 9, 12, 8]);

    await harness.startGame(parseEther("0.05"), ethers.ZeroHash, '0x');
    let requestId = await getPendingRequestId(harness);

    const firstReceipt = await (await harness.performMockReveal(requestId)).wait();
    const resampleLog = firstReceipt.logs.find((log) => log.fragment?.name === "DuplicateCardResampled");
    assert(resampleLog, "DuplicateCardResampled event not emitted");
    assert.strictEqual(resampleLog.args.isPlayerHand, true);
    assert.strictEqual(Number(resampleLog.args.cardIndex), 1);

    requestId = resampleLog.args.requestId;
    await harness.performMockReveal(requestId);

    const cards = await harness.getPlayerCards();
    assert.deepStrictEqual(cards.map((c) => Number(c)), [5, 8]);
  });

  it("handles hit bust via mocked reveal", async function () {
    const { harness, player } = await deployHarness();
    await harness.connect(player).deposit({ value: parseEther("1") });
    await harness.setDeck([10, 9, 5, 4, 8]);

    await harness.startGame(parseEther("0.05"), ethers.ZeroHash, '0x');
    let requestId = await getPendingRequestId(harness);
    await harness.performMockReveal(requestId);

    await harness.hit();
    requestId = await getPendingRequestId(harness);
    await harness.performMockReveal(requestId);

    const state = await harness.getGameState();
    assert.strictEqual(state[0], false);
    assert.strictEqual(Number(state[1]), 3);
  });

  it("plays dealer flow on stand with multiple reveals", async function () {
    const { harness, player } = await deployHarness();
    await harness.connect(player).deposit({ value: parseEther("2") });
    await harness.setDeck([9, 7, 6, 5, 20]);

    await harness.startGame(parseEther("0.2"), ethers.ZeroHash, '0x');
    let requestId = await getPendingRequestId(harness);
    await harness.performMockReveal(requestId);

    await harness.stand();
    while (true) {
      requestId = await getPendingRequestId(harness);
      if (requestId === 0n) break;
      await harness.performMockReveal(requestId);
    }

    const state = await harness.getGameState();
    assert.strictEqual(state[0], false);
    assert.strictEqual(Number(state[1]), 3);
    assert.strictEqual(Number(state[5]), 3);
  });

  it("returns wager on force reset", async function () {
    const { harness, player } = await deployHarness();
    await harness.connect(player).deposit({ value: parseEther("0.5") });
    await harness.setDeck([10, 23, 36, 49]);

    const bet = parseEther("0.2");
    await harness.startGame(bet, ethers.ZeroHash, '0x');
    let requestId = await getPendingRequestId(harness);
    await harness.performMockReveal(requestId);

    const receipt = await (await harness.forceReset()).wait();
    const resetEvent = receipt.logs.find((log) => log.fragment?.name === "ForceReset");
    assert(resetEvent, "ForceReset event not emitted");

    const balance = await harness.getBalance();
    assert.strictEqual(formatEther(balance), "0.5");
  });
});
