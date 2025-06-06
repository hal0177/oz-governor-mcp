# OpenZeppelin Governor: Multiple-Choice Extension

This repository contains the first version of an extension written for OpenZeppelin Governor.

Critically, the additions made in this extension do not alter the current Governor external interface.

This extension is a superset of `GovernorCountingSimple`, therefore the Bravo method of counting remains possible.

## Current State of OZ Governor

Currently, voting takes place for binary (Bravo) proposals.

This means the only options for a voter are For, Against, Abstain. This is implemented in `GovernorCountingSimple`.

If the For and Abstain votes reach a high enough threshold (the quorum) then the vote data can be executed on-chain.

## Additions with OZ Governor Counting Multiple

### Multiple-Choice Proposals

With this extension, the creation of proposals with multiple options is possible.

These proposals can have an arbitrary number of options, where each option contains on-chain data that can be executed after a successful voting round.

Included in the `targets`, `values` and `calldatas` parameters that are passed to the `propose` function, exists metadata describing number of options `nOptions`, number of winning options `nWinners` and indices of each option.

These indices specify the starting location of each option in the `targets`, `values` and `calldatas` arrays.

The first element `calldatas[0]` in the `calldatas` array is designated for this metadata to be specified.

### Voting on Multiple-Choice Proposals

Voters have number of possibilities when casting their voting power on a multiple-choice proposal:

1. Single-choice: Allocate all available voting power to a single option.
2. Approval: Distribute voting power evenly among all (or some) options (option weighting coefficients are equal).
3. Weighted: Specify weighting coefficients for all (or some) options. This coefficient reflects the proportion of their voting power to allocate to each option.

**NOTE**: If the vote type is Bravo, then voters have the same options as specified in `GovernorCountingSimple`.

***Please contact hal0177@proton.me for queries.***
