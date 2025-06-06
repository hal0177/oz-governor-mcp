// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { Governor } from "./Governor.sol";

// oz errors
/// error GovernorInvalidProposalLength(uint256 targets, uint256 calldatas, uint256 values);
/// error GovernorAlreadyCastVote(address voter);
/// error GovernorDisabledDeposit();
/// error GovernorOnlyExecutor(address account);
/// error GovernorNonexistentProposal(uint256 proposalId);
/// error GovernorUnexpectedProposalState(uint256 proposalId, ProposalState current, bytes32 expectedStates);
/// error GovernorInvalidVotingPeriod(uint256 votingPeriod);
/// error GovernorInsufficientProposerVotes(address proposer, uint256 votes, uint256 threshold);
/// error GovernorRestrictedProposer(address proposer);
error GovernorInvalidVoteType();
/// error GovernorInvalidVoteParams();
/// error GovernorQueueNotImplemented();
/// error GovernorNotQueuedProposal(uint256 proposalId);
/// error GovernorAlreadyQueuedProposal(uint256 proposalId);
/// error GovernorInvalidSignature(address voter);
/// error GovernorUnableToCancel(uint256 proposalId, address account);

// custom errors
error InvalidChoiceCount(uint256 nOptions);
error InvalidSupportValue(uint8 support);
error InvalidWeightCount(uint256 expectedCount, uint256 actualCount);
error InvalidProposalType(uint8 nOptions, uint8 nWinners);

/**
 * @dev Extension of {Governor} for advanced voting configurations including multiple-choice voting,
 * approval voting and weighted approval voting.
 *
 * The support parameter in voting functions is interpreted as a bitmap where each
 * bit represents a choice (up to 8 options):
 * - For Bravo voting, the support is simply the vote type (0 = Against, 1 = For, 2 = Abstain)
 * - For multiple-choice voting, the support is a bitmap where each bit represents a choice
 * - For weighted-choice voting, a number is attributed to each choice (in the `params` field)
 */
abstract contract GovernorCountingMultipleV1 is Governor {
    enum VoteTypeSimple {
        Against, // 0
        For, // 1
        Abstain // 2

    }

    struct VoteOption {
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
    }

    struct ProposalVote {
        uint8 nOptions;
        mapping(uint8 option => uint256) votes;
        mapping(address voter => bool) hasVoted;
    }

    // Proposal ID => Proposal Votes
    mapping(uint256 => ProposalVote) private _proposalVotes;

    // Single-choice `_castVote` options in an 8-option proposal
    // 00000000 -> 0 in decimal
    // 00000001 -> 1 in decimal
    // 00000010 -> 2 in decimal
    // 00000100 -> 4 in decimal
    // 00001000 -> 8 in decimal
    // 00010000 -> 16 in decimal
    // 00100000 -> 32 in decimal
    // 01000000 -> 64 in decimal
    // 10000000 -> 128 in decimal

    // Multiple-choice `_castVote` options in an 8-option proposal
    // 00100010 -> 34 in decimal (option 1 and 5)
    // 10001011 -> 139 in decimal (option 0, 1, 3, 7)
    // 10101010 -> 170 in decimal (option 1, 3, 5, 7)
    // 11001100 -> 204 in decimal (option 2, 3, 6, 7)
    // 11101110 -> 238 in decimal (option 1, 2, 3, 5, 6, 7)
    // 11111111 -> 255 in decimal (all options selected)

    constructor(string memory name_) Governor(name_) { }

    /**
     * @dev See {IGovernor-COUNTING_MODE}.
     */
    function COUNTING_MODE() public pure virtual override returns (string memory) {
        return "support=bravo,advanced&quorum=for,abstain";
    }

    /**
     * @dev Override of the {Governor-propose} function to incorporate multiple-choice proposals.
     * In multiple-choice voting, each option has its own set of on-chain outcome arrays (target/value/calldata).
     * No more than 8 options are allowed.
     *
     * The `calldatas` first 32 bytes are used to store the number of options and number of winners (execute x of n).
     * The subsequent bytes contain the indices of the option data in the `targets`, `values` and `calldatas` arrays.
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public virtual override returns (uint256) {
        address proposer = _msgSender();

        // check description restriction
        if (!_isValidDescriptionForProposer(proposer, description)) {
            revert GovernorRestrictedProposer(proposer);
        }

        uint8 nOptions;
        uint8 nWinners;
        uint8[] memory optionDataIndex = new uint8[](8);
        if (targets[0] == address(0) && calldatas.length != 0) {
            // CASE: MULTIPLE-CHOICE VOTING
            (nOptions, nWinners, optionDataIndex) = _parseMultipleChoice(calldatas[0]);
        } else {
            // CASE: STANDARD BRAVO VOTING
            nOptions = 0; // 0 means Bravo voting
            nWinners = 0; // 0 means Bravo voting
        }

        // TODO: ensure each option's targets/values/calldatas are equisized
        _validateVoteOptions(targets, values, calldatas, nOptions);

        // check proposal threshold
        uint256 votesThreshold = proposalThreshold();
        if (votesThreshold > 0) {
            uint256 proposerVotes = getVotes(proposer, clock() - 1);
            if (proposerVotes < votesThreshold) {
                revert GovernorInsufficientProposerVotes(proposer, proposerVotes, votesThreshold);
            }
        }

        uint256 proposalId = _propose(targets, values, calldatas, description, proposer);

        // store proposal vote configuration
        _proposalVotes[proposalId].nOptions = nOptions;

        return proposalId;
    }

    /**
     * @dev Override of the {Governor-_countVote} function to handle advanced voting types.
     */
    function _countVote(uint256 proposalId, address account, uint8 support, uint256 totalWeight, bytes memory params)
        internal
        virtual
        override
        returns (uint256)
    {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];

        if (proposalVote.hasVoted[account]) {
            revert GovernorAlreadyCastVote(account);
        }
        proposalVote.hasVoted[account] = true;

        uint8 nOptions = proposalVote.nOptions;

        if (nOptions == 0) {
            // Bravo voting
            if (support == uint8(VoteTypeSimple.Against)) {
                proposalVote.votes[uint8(VoteTypeSimple.Against)] += totalWeight;
            } else if (support == uint8(VoteTypeSimple.For)) {
                proposalVote.votes[uint8(VoteTypeSimple.For)] += totalWeight;
            } else if (support == uint8(VoteTypeSimple.Abstain)) {
                proposalVote.votes[uint8(VoteTypeSimple.Abstain)] += totalWeight;
            } else {
                revert GovernorInvalidVoteType();
            }
        } else {
            // Ensure support bitmap doesn't exceed available number of options
            // e.g. for a 3-option proposal, the support bitmap should be less than 8 (1000 in binary)
            // that way they can vote for any combination of the three options:
            // 000 -> vote for none of the three options
            // 001 -> vote for option A
            // 010 -> vote for option B
            // 101 -> vote for options A and C
            // 111 -> vote for all three options
            if (support > ((1 << nOptions) - 1)) {
                revert GovernorInvalidVoteType();
            }

            if (params.length == 0) {
                // Case where no weighting coefficients are provided (approval/single choice)
                // Iterate through each bit in the support bitmap
                // TODO: handle equal weight for each option
                for (uint8 i = 0; i < nOptions; i++) {
                    // Check if this option was selected (bit is 1)
                    if (support & (1 << i) != 0) {
                        proposalVote.votes[i] += totalWeight;
                    }
                }
            } else if (params.length == 0x20) {
                uint256 weightDenominator = 0;
                uint256[] memory weights = new uint256[](nOptions);

                // BUG: does the input params always have 32 bytes? can it work with fewer?

                // Case where weighting coefficients are provided (weighted choice)
                // The coefficients are packed into a 32-byte array (eight uint32 values).
                // Each 8-byte chunk in the packed bytes array represents vote weight applied to its corresponding
                // support bit.
                // Iterate through each bit in the support bitmap
                for (uint8 i = 0; i < nOptions; i++) {
                    // Check if this option was selected (bit is 1)
                    if (support & (1 << i) != 0) {
                        uint32 weight;
                        assembly {
                            // load weight data
                            let data := mload(add(params, 0x20))
                            // shift amount is 32 * position of option
                            let shift_qt := mul(i, 0x20)
                            let shiftedr := shr(shift_qt, data)
                            // mask out everything except the last 32 bits
                            let cast_u32 := and(shiftedr, 0xffffffff)
                            weight := cast_u32
                        }
                        weightDenominator += weight;
                        weights[i] = weight;
                    }
                }

                uint256 totalAppliedWeight = 0;

                // Iterate through each supported option and apply the specified weight to totalWeight
                for (uint8 i = 0; i < nOptions; i++) {
                    // TODO: check which conditional is cheaper - or any at all
                    // if (support & (1 << i) != 0) {
                    if (weights[i] != 0) {
                        uint256 appliedWeight = totalWeight * weights[i] / weightDenominator;
                        proposalVote.votes[i] += appliedWeight;
                        totalAppliedWeight += appliedWeight;
                    }
                }

                // ensure the total vote weights applied are not greater than the voter's total weight
                assert(totalAppliedWeight <= totalWeight);
            } else {
                // Case where either no coefficients were provided (approval/single choice) or 32 bytes of coefficients
                // were provided (vote weights applied to each option)
                revert InvalidWeightCount(0x20, params.length);
            }
        }

        return totalWeight;
    }

    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable virtual override returns (uint256) {
        uint256 proposalId = hashProposal(targets, values, calldatas, descriptionHash);

        ProposalVote storage proposalVote = _proposalVotes[proposalId];

        _validateStateBitmap(
            proposalId, _encodeStateBitmap(ProposalState.Succeeded) | _encodeStateBitmap(ProposalState.Queued)
        );

        // mark as executed before calls to avoid reentrancy
        // _proposals[proposalId].executed = true;
        _setProposalExecuted(proposalId);

        // TODO: isolate executable data to successful options only

        // before execute: register governance call in queue.
        if (_executor() != address(this)) {
            for (uint256 i = 0; i < targets.length; ++i) {
                if (targets[i] == address(this)) {
                    // _governanceCall.pushBack(keccak256(calldatas[i]));
                    _governanceCallPushBack(keccak256(calldatas[i]));
                }
            }
        }

        _executeOperations(proposalId, targets, values, calldatas, descriptionHash);

        // after execute: cleanup governance call queue.
        if (_executor() != address(this) && !_governanceCallEmpty()) {
            // _governanceCall.clear();
            _governanceCallClear();
        }

        emit ProposalExecuted(proposalId);

        // If no config exists, treat as standard Bravo proposal
        if (proposalVote.nOptions == 0) {
            return super.execute(targets, values, calldatas, descriptionHash);
        }

        return proposalId;
    }

    // function queue(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32
    // descriptionHash)
    //     public
    //     virtual
    //     override
    //     returns (uint256)
    // {
    //     // TODO: implement queueing for multiple-choice proposals and override the standard queue function
    //     // This is to work with private variables in the Governor contract
    //     // also to ensure only the successful option(s) are queued
    //     return 0;
    //     _setProposalEtaSeconds(proposalId, 0);
    // }

    // /**
    //  * @dev Internal function to determine the winning choice for a proposal.
    //  */
    // function _getWinningChoice(uint256 proposalId) internal view returns (uint8) {
    //     ProposalVoteConfiguration storage config = _proposalConfigs[proposalId];
    //     uint256 highestVotes = 0;
    //     uint8 winningChoice = 0;

    //     for (uint8 i = 0; i < config.nOptions; i++) {
    //         uint256 votes = _proposalVotes[proposalId][i];
    //         if (votes > highestVotes) {
    //             highestVotes = votes;
    //             winningChoice = i;
    //         }
    //     }

    //     return winningChoice;
    // }

    function _validateVoteOptions(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        uint256 nOptions
    ) internal pure returns (uint8) {
        // ensure nOptions is: 0 (Bravo voting) or 2-8 (multiple-choice voting)
        if (nOptions > 8) {
            revert InvalidChoiceCount(nOptions);
        }

        for (uint8 i = 0; i < nOptions; i++) {
            if (targets.length != values.length || values.length != calldatas.length) {
                revert GovernorInvalidProposalLength(targets.length, calldatas.length, values.length);
            }
        }

        return uint8(nOptions); // safe as nOptions is always less than 8
    }

    /**
     * @dev Squash the vote options into a single array of targets, values and calldatas.
     */
    function _squashVoteOptions(VoteOption[] memory voteOptions)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        uint256 squashedLength = 0;
        for (uint8 i = 0; i < voteOptions.length; i++) {
            squashedLength += voteOptions[i].targets.length;
        }

        targets = new address[](squashedLength);
        values = new uint256[](squashedLength);
        calldatas = new bytes[](squashedLength);

        uint256 squashedIndex = 0;
        for (uint8 i = 0; i < voteOptions.length; i++) {
            uint256 optionLength = voteOptions[i].targets.length;
            for (uint256 j = 0; j < optionLength; j++) {
                targets[squashedIndex] = voteOptions[i].targets[j];
                values[squashedIndex] = voteOptions[i].values[j];
                calldatas[squashedIndex] = voteOptions[i].calldatas[j];
                squashedIndex++;
            }
        }
        assert(squashedIndex == squashedLength);
    }

    function _parseMultipleChoice(bytes memory proposalData)
        internal
        pure
        returns (uint8 nOptions, uint8 nWinners, uint8[] memory optionDataIndex)
    {
        // calldatas[0][2-9] -> indices of the option data in the `targets`, `values` and `calldatas` arrays
        // abi.encode(bytes32(abi.encodePacked(uint8(8), uint8(i), uint8(j), uint8(k), uint8(l), uint8(m), uint8(n),
        // uint8(o), uint8(p), uint8(q))));

        nOptions = uint8(proposalData[0]); // first byte contains number of options (2-8)
        nWinners = uint8(proposalData[1]); // second byte contains number of winners (1-7)
        bool validNOptions = nOptions > 1 && nOptions <= 8;
        bool validNWinners = nWinners > 0 && nWinners < nOptions;
        optionDataIndex = new uint8[](nOptions);
        if (validNOptions && validNWinners) {
            // valid multiple-choice voting
            for (uint8 i = 0; i < nOptions; i++) {
                optionDataIndex[i] = uint8(proposalData[2 + i]); // subsequent bytes contain indices
            }
        } else {
            revert InvalidProposalType(nOptions, nWinners);
        }
    }
}
