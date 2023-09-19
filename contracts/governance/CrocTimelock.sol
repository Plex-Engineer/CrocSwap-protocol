// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "../interfaces/IProposalStore.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/** @title CrocTimelock
 *  @notice This contract is the timelock authority for the CrocPolicy contract.
 *  It is responsible for executing proposals from the ProposalStore (GoveShuttle) contract.
 */

contract CrocTimelock {
    address public immutable proposalStore;
    mapping(uint => bool) public executed;

    constructor(address _proposalStore) {
        proposalStore = _proposalStore;
    }

    function acceptAdmin() public pure returns (bool) {
        return true;
    }

    /**
     * @notice  Executes a queued proposal in the ProposalStore if not already executed
     * @param   _proposalId  The id of the proposal to execute
     */
    function execute(uint _proposalId) public payable {
        // check that the proposal has not been executed already
        require(
            !executed[_proposalId],
            "CrocTimelock::execute: proposal already executed"
        );
        executed[_proposalId] = true;

        // get the proposal from the ProposalStore
        IProposalStore.Proposal memory proposal = IProposalStore(proposalStore)
            .QueryProp(_proposalId);

        // check that this proposal exists
        require(proposal.id != 0, "CrocTimelock::execute: invalid proposal id");
        // check that the proposal is formatted corectly
        require(
            proposal.targets.length == proposal.values.length &&
                proposal.targets.length == proposal.signatures.length &&
                proposal.targets.length == proposal.calldatas.length,
            "CrocTimelock::execute: proposal not formatted correctly"
        );
        // execute the transactions
        for (uint i = 0; i < proposal.targets.length; i++) {
            (bool success, bytes memory returndata) = payable(
                proposal.targets[i]
            ).call{value: proposal.values[i]}(
                abi.encodePacked(
                    bytes4(keccak256(bytes(proposal.signatures[i]))),
                    proposal.calldatas[i]
                )
            );
            require(
                success,
                string(
                    abi.encodePacked(
                        "CrocTimelock::execute: Transaction execution reverted: ",
                        "Transaction: ",
                        Strings.toString(i),
                        " Reason: ",
                        string(returndata)
                    )
                )
            );
        }
    }
}
