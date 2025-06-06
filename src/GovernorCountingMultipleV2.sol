// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { IGovernor, Governor } from "./Governor.sol";

/**
 * @dev Extension of {Governor} for advanced voting configurations including multiple-choice voting,
 * approval voting and weighted approval voting.
 *
 * The difference between this and GovernorCountingMultipleV1 is that this version places no restriction
 * on the number of options or winners. This is achieved by:
 * 1. Specifying the proposal information (number of options and number of winners) in the first bytes value of the
 *    `calldatas` input to `propose`, `queue` and `execute`.
 * 2. The number of options and number of winners can be extracted from this, as well as the indices of the option data.
 * 3. When voting, `castVoteWithParams` must be used (for multiple-choice voting). This `params` field contains a
 *    non-zero value for options that the voter wishes to vote for, along with potential weighting coefficients.
 * 4. If the `params` field is empty (or `castVote` is used), the vote will be assumed to be Bravo.
 *
 * @custom:security-considerations
 * 1. Weight Precision: When using weighted voting, there is inherent precision loss due to integer division.
 *    Users should use larger coefficients while maintaining proportions to minimize this effect.
 * 2. Front-Running: In scenarios with high-value proposals, voters might observe others' votes and
 *    adjust their voting strategy accordingly, as votes are visible on-chain.
 * 3. Memory Usage: The contract assumes reasonable bounds for nOptions and nWinners to prevent
 *    excessive memory allocation. The upper bounds are not enforced in _validateVoteOptions.
 * TODO: Cross-check with GovernorCountingSimple to ensure interface compatibility and function exposure.
 */
abstract contract GovernorCountingMultipleV2 is Governor {
    enum VoteTypeSimple {
        Against,
        For,
        Abstain
    }

    error GovernorInvalidMultipleChoiceProposal(uint256 nOptions, uint256 nWinners, bytes metadata);
    error GovernorNonIncrementingOptionIndices(uint256 nOptions, bytes metadata);

    struct ProposalVote {
        uint256 nOptions;
        uint256 nWinners;
        mapping(uint256 option => uint256) votes;
        mapping(address voter => bool) hasVoted;
    }

    // Proposal ID => Proposal Votes
    mapping(uint256 => ProposalVote) private _proposalVotes;

    constructor(string memory name_) Governor(name_) { }

    /// @inheritdoc IGovernor
    function COUNTING_MODE() public pure virtual override returns (string memory) {
        return "support=bravo,multiple&quorum=for,abstain";
    }

    /**
     * @dev Accessor to the internal vote counts.
     */
    function proposalVotes(uint256 proposalId)
        public
        view
        virtual
        returns (uint256 nOptions, uint256 nWinners, uint256[] memory votes)
    {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        nOptions = proposalVote.nOptions;
        nWinners = proposalVote.nWinners;
        votes = new uint256[](nOptions);
        for (uint256 i = 0; i < nOptions; i++) {
            votes[i] = proposalVote.votes[i];
        }
    }

    /// @inheritdoc IGovernor
    function hasVoted(uint256 proposalId, address account) public view virtual returns (bool) {
        return _proposalVotes[proposalId].hasVoted[account];
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

        // check proposal threshold
        uint256 votesThreshold = proposalThreshold();
        if (votesThreshold > 0) {
            uint256 proposerVotes = getVotes(proposer, clock() - 1);
            if (proposerVotes < votesThreshold) {
                revert GovernorInsufficientProposerVotes(proposer, proposerVotes, votesThreshold);
            }
        }

        uint256 proposalId = _propose(targets, values, calldatas, description, proposer);

        uint256 nOptions = 0;
        uint256 nWinners = 0;

        if (targets[0] == address(0) && calldatas.length != 0) {
            // CASE: MULTIPLE-CHOICE VOTING
            // Multiple-choice voting information (options, winners, indices) is stored in the first bytes index of the
            // `calldatas` input.
            (nOptions, nWinners) = _extractProposalSize(calldatas[0]);
        }

        // This function:
        // 1. Ensures each option's targets/values/calldatas are equisized
        // 2. Ensures the proposal configuration is valid
        _validateVoteOptions(targets, values, calldatas, nOptions, nWinners);

        // store proposal vote configuration
        _proposalVotes[proposalId].nOptions = nOptions;

        return proposalId;
    }

    /**
     * @dev Override of the {Governor-_countVote} function to handle advanced voting types.
     * @dev support is redundant here, as it is already encoded in the params field
     * @dev When using weighted voting, there may be precision loss due to integer division in the weight calculation
     * (totalWeight * weights[i] / weightDenominator). To mitigate this, users can increase their weight coefficients
     * while maintaining the same proportions.
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

        uint256 nOptions = proposalVote.nOptions;

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
            uint256 weightDenominator = 0;
            uint256[] memory weights = new uint256[](nOptions);

            // Case where weighting coefficients are provided (weighted choice)
            for (uint256 i = 0; i < nOptions; i++) {
                uint256 weight;
                assembly {
                    // load weight data - add 0x20 to skip length prefix of bytes array
                    let pos := add(add(params, 0x20), mul(i, 0x20)) // offset by full 32-byte slots
                    weight := mload(pos)
                }
                weightDenominator += weight;
                weights[i] = weight;
            }

            // Ensure at least one non-zero weight was provided
            if (weightDenominator == 0) {
                revert GovernorInvalidVoteParams();
            }

            uint256 totalAppliedWeight = 0;

            // Iterate through each supported option and apply the specified weight to totalWeight
            for (uint256 i = 0; i < nOptions; i++) {
                if (weights[i] != 0) {
                    // Applied weight = vote power * weight_i / sum(weight_i)
                    uint256 appliedWeight = totalWeight * weights[i] / weightDenominator;
                    proposalVote.votes[i] += appliedWeight;
                    totalAppliedWeight += appliedWeight;
                }
            }

            // ensure the total vote weights applied are not greater than the voter's total weight
            assert(totalAppliedWeight <= totalWeight);
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
        uint256 nOptions = proposalVote.nOptions;

        // Bravo proposal
        if (nOptions == 0) {
            return super.execute(targets, values, calldatas, descriptionHash);
        }

        uint256 nWinners = proposalVote.nWinners;

        _validateStateBitmap(
            proposalId, _encodeStateBitmap(ProposalState.Succeeded) | _encodeStateBitmap(ProposalState.Queued)
        );

        // mark as executed before calls to avoid reentrancy
        // this function does the following: _proposals[proposalId].executed = true;
        _setProposalExecuted(proposalId);

        // Create array to store vote amounts for each option
        uint256[] memory votes = new uint256[](nOptions);

        for (uint256 i = 0; i < nOptions; i++) {
            votes[i] = proposalVote.votes[i];
        }

        (address[] memory successfulTargets, uint256[] memory successfulValues, bytes[] memory successfulCalldatas) =
            _getSuccessfulOperations(nOptions, nWinners, targets, values, calldatas, votes);

        // before execute: register governance call in queue.
        if (_executor() != address(this)) {
            for (uint256 i = 0; i < targets.length; ++i) {
                if (targets[i] == address(this)) {
                    // this function does the following: _governanceCall.pushBack(keccak256(calldatas[i]));
                    _governanceCallPushBack(keccak256(calldatas[i]));
                }
            }
        }

        _executeOperations(proposalId, successfulTargets, successfulValues, successfulCalldatas, descriptionHash);

        // after execute: cleanup governance call queue.
        if (_executor() != address(this) && !_governanceCallEmpty()) {
            // this function does the following: _governanceCall.clear();
            _governanceCallClear();
        }

        emit ProposalExecuted(proposalId);

        return proposalId;
    }

    function queue(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
        public
        virtual
        override
        returns (uint256)
    {
        uint256 proposalId = getProposalId(targets, values, calldatas, descriptionHash);

        ProposalVote storage proposalVote = _proposalVotes[proposalId];

        uint256 nOptions = proposalVote.nOptions;

        // Bravo proposal
        if (nOptions == 0) {
            return super.queue(targets, values, calldatas, descriptionHash);
        }

        // ensure proposal has succeeded
        _validateStateBitmap(proposalId, _encodeStateBitmap(ProposalState.Succeeded));

        uint256 nWinners = proposalVote.nWinners;

        uint256[] memory votes = new uint256[](nOptions);

        // only want to queue the successful operations
        (address[] memory successfulTargets, uint256[] memory successfulValues, bytes[] memory successfulCalldatas) =
            _getSuccessfulOperations(nOptions, nWinners, targets, values, calldatas, votes);

        uint48 etaSeconds =
            _queueOperations(proposalId, successfulTargets, successfulValues, successfulCalldatas, descriptionHash);

        if (etaSeconds != 0) {
            // this function does the following: _proposals[proposalId].etaSeconds = etaSeconds;
            _setProposalEtaSeconds(proposalId, etaSeconds);
            emit ProposalQueued(proposalId, etaSeconds);
        } else {
            revert GovernorQueueNotImplemented();
        }

        return proposalId;
    }

    /**
     * @dev Extracts the proposal size from the proposal metadata bytes.
     * @param metadata The bytes containing the proposal number of options, number of winners and option indices
     * @return nOptions The number of options in the proposal
     * @return nWinners The number of winners to be selected
     */
    function _extractProposalSize(bytes memory metadata) internal pure returns (uint256 nOptions, uint256 nWinners) {
        if (metadata.length < 64) {
            revert GovernorInvalidMultipleChoiceProposal(0, 0, metadata);
        }

        // Extract first 32 bytes for nOptions and next 32 bytes for nWinners
        bytes32 nOptionsBytes;
        bytes32 nWinnersBytes;

        // Copy the data to avoid modifying the original bytes
        assembly {
            nOptionsBytes := mload(add(metadata, 32)) // skip length prefix
            nWinnersBytes := mload(add(metadata, 64))
        }

        // Convert to uint256 safely
        nOptions = uint256(nOptionsBytes);
        nWinners = uint256(nWinnersBytes);
    }

    /**
     * @dev Extracts the option data indices from the proposal info bytes.
     * @param nOptions The number of options in the proposal
     * @param metadata The bytes containing the proposal option indices
     * @return optionDataIndices Array of indices where each option's data starts
     */
    function _extractOptionIndices(uint256 nOptions, bytes memory metadata)
        internal
        pure
        returns (uint256[] memory optionDataIndices)
    {
        // Validate input length (32 bytes for nOptions + 32 bytes for nWinners + 32 bytes per index)
        if (metadata.length < (64 + (nOptions * 32))) {
            revert GovernorInvalidMultipleChoiceProposal(nOptions, 0, metadata);
        }

        // Initialize array for option indices
        optionDataIndices = new uint256[](nOptions);

        // Read indices from remaining 32-byte chunks
        bytes32 indexBytes;
        for (uint256 i = 0; i < nOptions; i++) {
            // Calculate offset: 64 (nOptions + nWinners) + i * 32
            uint256 offset = 64 + (i * 32);

            // Safely copy the bytes
            assembly {
                indexBytes := mload(add(metadata, add(32, offset))) // add 32 for length prefix
            }

            optionDataIndices[i] = uint256(indexBytes);

            // Validate that indices are monotonically increasing
            if (i > 0) {
                if (optionDataIndices[i] <= optionDataIndices[i - 1]) {
                    revert GovernorNonIncrementingOptionIndices(nOptions, metadata);
                }
            }
        }
    }

    /**
     * @dev Validates the proposal configuration including number of options and winners.
     * @notice This function ensures that:
     * 1. For Bravo proposals: nOptions == 0
     * 2. For multiple-choice proposals: nOptions > 1 && 0 < nWinners < nOptions
     */
    function _validateVoteOptions(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        uint256 nOptions,
        uint256 nWinners
    ) internal pure {
        for (uint256 i = 0; i < nOptions; i++) {
            if (targets.length != values.length || values.length != calldatas.length) {
                revert GovernorInvalidProposalLength(targets.length, calldatas.length, values.length);
            }
        }

        // Validate the proposal configuration
        // No upper limit is imposed on the number of options or winners.
        if (nOptions == 0) {
            // Case bravo: nOptions == 0
            return;
        } else if (nOptions > 1 && nWinners > 0 && nWinners < nOptions) {
            // Case multiple-choice: nOptions > 1, 0 < nWinners < nOptions
            return;
        } else {
            revert GovernorInvalidMultipleChoiceProposal(nOptions, nWinners, calldatas[0]);
        }
    }

    /**
     * @dev Returns the arrays of successful operations based on vote counts.
     * @notice The implementation uses a selection sort approach with O(n*k) complexity,
     * where n is the number of options and k is the number of winners.
     * This is optimal for the typical use case of 4-12 options per proposal.
     * While O(n*k) would be suboptimal for large n (100+ options), such cases
     * are not expected in practice, and the current implementation prioritizes
     * gas efficiency through minimal storage operations and simple comparisons.
     * @dev This function assumes that the proposal dimensions (nOptions and nWinners) are reasonably sized.
     * If this is not the case, the operation will run out of gas.
     */
    function _getSuccessfulOperations(
        uint256 nOptions,
        uint256 nWinners,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        uint256[] memory votes
    ) internal pure returns (address[] memory, uint256[] memory, bytes[] memory) {
        address[] memory successfulTargets = new address[](nWinners);
        uint256[] memory successfulValues = new uint256[](nWinners);
        bytes[] memory successfulCalldatas = new bytes[](nWinners);

        uint256[] memory optionDataIndices = _extractOptionIndices(nOptions, calldatas[0]);

        // Create array to store indices of top nWinners options by vote count
        uint256[] memory winningIndices = new uint256[](nWinners);

        for (uint256 i = 0; i < nWinners; i++) {
            uint256 maxVotes = 0;
            uint256 maxIndex = 0;
            for (uint256 j = 0; j < nOptions; j++) {
                if (votes[j] > maxVotes) {
                    maxVotes = votes[j];
                    maxIndex = j;
                }
            }
            winningIndices[i] = optionDataIndices[maxIndex];
            votes[maxIndex] = 0;
        }

        uint256 currentExecIndex = 0;
        uint256 winnerIndex = 0;
        for (uint256 i = 0; i < optionDataIndices.length - 1; i++) {
            uint256 lower = optionDataIndices[i];
            if (winningIndices[winnerIndex] == lower) {
                // safe access because i + 1 < optionDataIndices.length
                uint256 upper = optionDataIndices[i + 1];
                for (uint256 j = lower; j < upper; j++) {
                    successfulTargets[currentExecIndex] = targets[j];
                    successfulValues[currentExecIndex] = values[j];
                    successfulCalldatas[currentExecIndex] = calldatas[j];
                    currentExecIndex++;
                }
                winnerIndex++;
            }
        }

        return (successfulTargets, successfulValues, successfulCalldatas);
    }
}
