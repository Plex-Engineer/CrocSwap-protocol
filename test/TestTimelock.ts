import chai from "chai";
import { expect } from "chai";
import { solidity } from "ethereum-waffle";
import {
  CrocPolicy,
  CrocSwapDex,
  CrocTimelock,
  MockProposalStore,
} from "../typechain";
import { ethers } from "hardhat";
import { BytesLike } from "ethers";
import { TestPool, makeTokenPool } from "./FacadePool";

chai.use(solidity);

async function addProposal(
  proposalStore: MockProposalStore,
  id: number,
  title: string,
  desc: string,
  targets: string[],
  values: number[],
  signatures: string[],
  calldatas: BytesLike[]
) {
  await (
    await proposalStore.AddProposal(
      id,
      title,
      desc,
      targets,
      values,
      signatures,
      calldatas
    )
  ).wait();
}
// commands
function transferCmd(auth: string): BytesLike {
  let abiCoder = new ethers.utils.AbiCoder();
  return abiCoder.encode(["uint8", "address"], [20, auth]);
}

function upgradeCmd(slot: number, address: string): BytesLike {
  let abiCoder = new ethers.utils.AbiCoder();
  //21 is upgrade code
  return abiCoder.encode(["uint8", "address", "uint16"], [21, address, slot]);
}

describe("Croc Timelock", () => {
  const randAddress = ethers.constants.AddressZero;
  let dex: CrocSwapDex;
  let proposalStore: MockProposalStore;
  let crocTimelock: CrocTimelock;
  let crocPolicy: CrocPolicy;
  let abiCoder = new ethers.utils.AbiCoder();
  beforeEach("deploy governance", async () => {
    // deploy proposal store
    const proposalStoreFactory = await ethers.getContractFactory(
      "MockProposalStore"
    );
    proposalStore = (await (
      await proposalStoreFactory.deploy()
    ).deployed()) as MockProposalStore;

    // deploy timelock
    const timelockFactory = await ethers.getContractFactory("CrocTimelock");
    crocTimelock = (await (
      await timelockFactory.deploy(proposalStore.address)
    ).deployed()) as CrocTimelock;

    // deploy dex
    const testPool = await makeTokenPool();
    dex = await testPool.dex;

    // deploy crocPolicy
    const crocPolicyFactory = await ethers.getContractFactory("CrocPolicy");
    crocPolicy = (await (
      await crocPolicyFactory.deploy(dex.address)
    ).deployed()) as CrocPolicy;

    // set authority on dex to crocPolicy
    dex
      .connect(await testPool.auth)
      .protocolCmd(testPool.COLD_PROXY, transferCmd(crocPolicy.address), true);

    // set authority on crocPolicy
    await crocPolicy.transferGovernance(
      crocTimelock.address,
      crocTimelock.address,
      crocTimelock.address
    );
  });

  it("deploy timelock correctly", async () => {
    expect((await crocTimelock.proposalStore()) == proposalStore.address);
  });

  it("sets all authority", async () => {
    expect(await crocPolicy.opsAuthority_()).to.equal(crocTimelock.address);
    expect(await crocPolicy.treasuryAuthority_()).to.equal(
      crocTimelock.address
    );
    expect(await crocPolicy.emergencyAuthority_()).to.equal(
      crocTimelock.address
    );

    // // slot 0 is the authority slot
    // expect(await (await testPool.dex).readSlot(ethers.utils.keccak256(
    //     (new ethers.utils.AbiCoder).encode(["uint"], [0])
    // ))).to.equal(crocPolicy.address);

    // only timelock should be able to transfer governance on crocPolicy now
    await expect(
      crocPolicy.transferGovernance(randAddress, randAddress, randAddress)
    ).to.be.revertedWith("Treasury Authority");
  });

  it("incorrect proposal id", async () => {
    await expect(crocTimelock.execute(1)).to.be.revertedWith(
      "CrocTimelock::execute: invalid proposal id"
    );
  });

  it("set new crocPolicy authority through proposal", async () => {
    // deploy new timelock
    const timelockFactory = await ethers.getContractFactory("CrocTimelock");
    const newCrocTimelock = (await (
      await timelockFactory.deploy(proposalStore.address)
    ).deployed()) as CrocTimelock;

    await addProposal(
      proposalStore,
      1,
      "new gov test",
      "new gov test",
      [crocPolicy.address],
      [0],
      ["transferGovernance(address,address,address)"],
      [
        abiCoder.encode(
          ["address", "address", "address"],
          [
            newCrocTimelock.address,
            newCrocTimelock.address,
            newCrocTimelock.address,
          ]
        ),
      ]
    );
    // execute proposal
    await (await crocTimelock.execute(1)).wait();
    // check auth
    expect(await crocPolicy.opsAuthority_()).to.equal(newCrocTimelock.address);
    expect(await crocPolicy.treasuryAuthority_()).to.equal(
      newCrocTimelock.address
    );
    expect(await crocPolicy.emergencyAuthority_()).to.equal(
      newCrocTimelock.address
    );
  });

  it("cannot execute same proposal twice", async () => {
    // deploy new timelock
    const timelockFactory = await ethers.getContractFactory("CrocTimelock");
    const newCrocTimelock = (await (
      await timelockFactory.deploy(proposalStore.address)
    ).deployed()) as CrocTimelock;

    await addProposal(
      proposalStore,
      1,
      "new gov test",
      "new gov test",
      [crocPolicy.address],
      [0],
      ["transferGovernance(address,address,address)"],
      [
        abiCoder.encode(
          ["address", "address", "address"],
          [
            newCrocTimelock.address,
            newCrocTimelock.address,
            newCrocTimelock.address,
          ]
        ),
      ]
    );
    // execute proposal
    await (await crocTimelock.execute(1)).wait();
    await expect(crocTimelock.execute(1)).to.be.revertedWith(
      "CrocTimelock::execute: proposal already executed"
    );
  });

  it("emergency halt through proposal", async () => {
    await addProposal(
      proposalStore,
      1,
      "emergency halt test",
      "emergency halt test",
      [crocPolicy.address],
      [0],
      ["emergencyHalt(address,string)"],
      [
        abiCoder.encode(
          ["address", "string"],
          [dex.address, "emergency halt test"]
        ),
      ]
    );
    expect((await (await crocTimelock.execute(1)).wait()).status).equal(1);
  });

  it("test upgrade sidecar", async () => {
    // upgrade cold path
    const coldPathFactory = await ethers.getContractFactory("ColdPath");
    const newColdPath = await (await coldPathFactory.deploy()).deployed();
    const bootPath = 0;
    const coldPathSlot = 3;
    await addProposal(
      proposalStore,
      1,
      "upgrade cold path",
      "upgrade cold path",
      [crocPolicy.address],
      [0],
      ["treasuryResolution(address,uint16,bytes,bool)"],
      [
        abiCoder.encode(
          ["address", "uint16", "bytes", "bool"],
          [
            dex.address,
            bootPath,
            upgradeCmd(coldPathSlot, newColdPath.address),
            true,
          ]
        ),
      ]
    );
    expect((await (await crocTimelock.execute(1)).wait()).status).equal(1);
  });
});
