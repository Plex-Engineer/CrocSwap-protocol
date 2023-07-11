import { solidity } from "ethereum-waffle";
import chai from "chai";
import { expect } from "chai";
import { ICSRTurnstile } from "../typechain/ICSRTurnstile";
import { ethers, network } from "hardhat";
import { CrocSwapDex } from "../typechain";
chai.use(solidity);

async function impersonate(address: string) {
  await network.provider.request({
    method: "hardhat_impersonateAccount",
    params: [address],
  });
  return await ethers.getSigner(address);
}

async function setBalance(address: string, balance: string) {
  await network.provider.request({
    method: "hardhat_setBalance",
    params: [address, balance],
  });
}

describe("CSR", () => {
  let turnstile: ICSRTurnstile;
  //random address
  const recipient = "0xbDA5747bFD65F08deb54cb465eB87D40e51B197E";

  beforeEach("attach contracts", async () => {
    turnstile = (await ethers.getContractAt(
      "ICSRTurnstile",
      "0xEcf044C5B4b867CFda001101c617eCd347095B44"
    )) as ICSRTurnstile;
  });
  it("deploy dex with csr", async () => {
    //get current nftId
    const currentNFTID = await turnstile.currentCounterId();

    // deploy new dex
    const dexFactory = await ethers.getContractFactory("CrocSwapDex");
    const dex = await dexFactory.deploy();
    await dex.deployed();

    // check if dex has CSR attached
    expect(await dex.csrID()).to.equal(currentNFTID);
    expect(await turnstile.getTokenId(dex.address)).to.equal(currentNFTID);
    expect(await turnstile.isRegistered(dex.address)).to.equal(true);
  });

  it("balance of csr nft and claim", async () => {
    // deploy new dex
    const dexFactory = await ethers.getContractFactory("CrocSwapDex");
    const dex = (await dexFactory.deploy()) as CrocSwapDex;
    await dex.deployed();

    const csrID = await dex.csrID();
    const csrOwner = await turnstile.ownerOf(csrID);

    // impersonate turnstile owner
    const turnstileSigner = await impersonate(await turnstile.owner());
    await setBalance(turnstileSigner.address, "0xffffffffffffffff");
    //distribute fees to nft
    await turnstile
      .connect(turnstileSigner)
      .distributeFees(csrID, { value: "1000000" });
    // check balance of nft
    expect(await turnstile.balances(csrID)).to.equal("1000000");

    // claim fees
    await setBalance(csrOwner, "0xffffffffffffffff");
    const balanceBefore = await ethers.provider.getBalance(recipient);
    await (
      await turnstile
        .connect(await impersonate(csrOwner))
        .withdraw(csrID, recipient, "1000000")
    ).wait();
    const balanceAfter = await ethers.provider.getBalance(recipient);
    expect(balanceAfter.sub(balanceBefore)).to.equal("1000000");
  });
});
