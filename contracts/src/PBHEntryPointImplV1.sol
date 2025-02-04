// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IWorldIDGroups} from "@world-id-contracts/interfaces/IWorldIDGroups.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IPBHEntryPoint} from "./interfaces/IPBHEntryPoint.sol";
import {ByteHasher} from "./helpers/ByteHasher.sol";
import {PBHExternalNullifier} from "./helpers/PBHExternalNullifier.sol";
import {WorldIDImpl} from "@world-id-contracts/abstract/WorldIDImpl.sol";
import "@BokkyPooBahsDateTimeLibrary/BokkyPooBahsDateTimeLibrary.sol";

/// @title PBH Entry Point Implementation V1
/// @dev This contract is an implementation of the PBH Entry Point.
///      It is used to verify the signature of a Priority User Operation, and Relaying Priority Bundles to the EIP-4337 Entry Point.
/// @author Worldcoin
contract PBHEntryPointImplV1 is IPBHEntryPoint, WorldIDImpl {
    ///////////////////////////////////////////////////////////////////////////////
    ///                   A NOTE ON IMPLEMENTATION CONTRACTS                    ///
    ///////////////////////////////////////////////////////////////////////////////

    // This contract is designed explicitly to operate from behind a proxy contract. As a result,
    // there are a few important implementation considerations:
    //
    // - All updates made after deploying a given version of the implementation should inherit from
    //   the latest version of the implementation. This prevents storage clashes.
    // - All functions that are less access-restricted than `private` should be marked `virtual` in
    //   order to enable the fixing of bugs in the existing interface.
    // - Any function that reads from or modifies state (i.e. is not marked `pure`) must be
    //   annotated with the `onlyProxy` and `onlyInitialized` modifiers. This ensures that it can
    //   only be called when it has access to the data in the proxy, otherwise results are likely to
    //   be nonsensical.
    // - This contract deals with important data for the PBH system. Ensure that all newly-added
    //   functionality is carefully access controlled using `onlyOwner`, or a more granular access
    //   mechanism.
    // - Do not assign any contract-level variables at the definition site unless they are
    //   `constant`.
    //
    // Additionally, the following notes apply:
    //
    // - Initialisation and ownership management are not protected behind `onlyProxy` intentionally.
    //   This ensures that the contract can safely be disposed of after it is no longer used.
    // - Carefully consider what data recovery options are presented as new functionality is added.
    //   Care must be taken to ensure that a migration plan can exist for cases where upgrades
    //   cannot recover from an issue or vulnerability.

    ///////////////////////////////////////////////////////////////////////////////
    ///                    !!!!! DATA: DO NOT REORDER !!!!!                     ///
    ///////////////////////////////////////////////////////////////////////////////

    // To ensure compatibility between upgrades, it is exceedingly important that no reordering of
    // these variables takes place. If reordering happens, a storage clash will occur (effectively a
    // memory safety error).

    using ByteHasher for bytes;

    ///////////////////////////////////////////////////////////////////////////////
    ///                                  ERRORS                                ///
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Thrown when attempting to reuse a nullifier
    error InvalidNullifier();

    ///////////////////////////////////////////////////////////////////////////////
    ///                                  Events                                ///
    //////////////////////////////////////////////////////////////////////////////

    event PBHEntryPointImplInitialized(
        IWorldIDGroups indexed worldId, IEntryPoint indexed entryPoint, uint8 indexed numPbhPerMonth
    );

    /// @notice Emitted once for each successful PBH verification.
    ///
    /// @param sender The sender of this particular transaction or UserOp.
    /// @param nonce Transaction/UserOp nonce.
    /// @param payload The zero-knowledge proof that demonstrates the claimer is registered with World ID.
    event PBH(address indexed sender, uint256 indexed nonce, PBHPayload payload);

    /// @notice Emitted when the World ID address is set.
    ///
    /// @param worldId The World ID instance that will be used for verifying proofs.
    event WorldIdSet(address indexed worldId);

    /// @notice Emitted when the number of PBH transactions allowed per month is set.
    ///
    /// @param numPbhPerMonth The number of allowed PBH transactions per month.
    event NumPbhPerMonthSet(uint8 indexed numPbhPerMonth);

    ///////////////////////////////////////////////////////////////////////////////
    ///                                  Vars                                  ///
    //////////////////////////////////////////////////////////////////////////////

    /// @notice Transient Storage for the hashed operations.
    /// @dev The PBHSignatureAggregator will cross reference this slot to ensure
    ///     The PBHVerifier is always the proxy to the EntryPoint for PBH Bundles.
    bytes32 internal _hashedOps;

    /// @dev The World ID group ID (always 1)
    uint256 internal constant _GROUP_ID = 1;

    /// @dev The World ID instance that will be used for verifying proofs
    IWorldIDGroups public worldId;

    /// @dev The EntryPoint where Aggregated PBH Bundles will be proxied to.
    IEntryPoint public entryPoint;

    /// @notice The number of PBH transactions that may be used by a single
    ///         World ID in a given month.
    uint8 public numPbhPerMonth;

    /// @dev Whether a nullifier hash has been used already. Used to guarantee an action is only performed once by a single person
    mapping(uint256 => bool) public nullifierHashes;

    ///////////////////////////////////////////////////////////////////////////////
    ///                             INITIALIZATION                              ///
    ///////////////////////////////////////////////////////////////////////////////

    /// @notice Constructs the contract.
    constructor() {
        // When called in the constructor, this is called in the context of the implementation and
        // not the proxy. Calling this thereby ensures that the contract cannot be spuriously
        // initialized on its own.
        _disableInitializers();
    }

    /// @notice Initializes the contract.
    /// @dev Must be called exactly once.
    /// @dev This is marked `reinitializer()` to allow for updated initialisation steps when working
    ///      with upgrades based upon this contract. Be aware that there are only 256 (zero-indexed)
    ///      initialisations allowed, so decide carefully when to use them. Many cases can safely be
    ///      replaced by use of setters.
    /// @dev This function is explicitly not virtual as it does not make sense to override even when
    ///      upgrading. Create a separate initializer function instead.
    ///
    /// @param _worldId The World ID instance that will be used for verifying proofs. If set to the
    ///        0 addess, then it will be assumed that verification will take place off chain.
    /// @param _entryPoint The ERC-4337 Entry Point.
    /// @param _numPbhPerMonth The number of allowed PBH transactions per month.
    ///
    /// @custom:reverts string If called more than once at the same initialisation number.
    function initialize(IWorldIDGroups _worldId, IEntryPoint _entryPoint, uint8 _numPbhPerMonth)
        external
        reinitializer(1)
    {
        // First, ensure that all of the parent contracts are initialised.
        __delegateInit();

        worldId = _worldId;
        entryPoint = _entryPoint;
        numPbhPerMonth = _numPbhPerMonth;

        // Say that the contract is initialized.
        __setInitialized();
        emit PBHEntryPointImplInitialized(_worldId, _entryPoint, _numPbhPerMonth);
    }

    /// @notice Responsible for initialising all of the supertypes of this contract.
    /// @dev Must be called exactly once.
    /// @dev When adding new superclasses, ensure that any initialization that they need to perform
    ///      is accounted for here.
    ///
    /// @custom:reverts string If called more than once.
    function __delegateInit() internal virtual onlyInitializing {
        __WorldIDImpl_init();
    }

    ///////////////////////////////////////////////////////////////////////////////
    ///                                  Functions                             ///
    //////////////////////////////////////////////////////////////////////////////

    /// Execute a batch of PackedUserOperation with Aggregators
    /// @param opsPerAggregator - The operations to execute, grouped by aggregator (or address(0) for no-aggregator accounts).
    /// @param beneficiary      - The address to receive the fees.
    function handleAggregatedOps(
        IEntryPoint.UserOpsPerAggregator[] calldata opsPerAggregator,
        address payable beneficiary
    ) external virtual onlyProxy onlyInitialized {
        for (uint256 i = 0; i < opsPerAggregator.length; ++i) {
            bytes32 hashedOps = keccak256(abi.encode(opsPerAggregator[i].userOps));
            assembly ("memory-safe") {
                if gt(tload(hashedOps), 0) { revert(0, 0) }

                tstore(hashedOps, hashedOps)
            }

            PBHPayload[] memory pbhPayloads = abi.decode(opsPerAggregator[i].signature, (PBHPayload[]));
            for (uint256 j = 0; j < pbhPayloads.length; ++j) {
                verifyPbh(
                    opsPerAggregator[i].userOps[j].sender,
                    opsPerAggregator[i].userOps[j].nonce,
                    opsPerAggregator[i].userOps[j].callData,
                    pbhPayloads[j]
                );
            }
        }

        entryPoint.handleAggregatedOps(opsPerAggregator, beneficiary);
    }

    /// @notice Validates the hashed operations is the same as the hash transiently stored.
    /// @param hashedOps The hashed operations to validate.
    function validateSignaturesCallback(bytes32 hashedOps) external view virtual onlyProxy onlyInitialized {
        assembly ("memory-safe") {
            if iszero(eq(tload(hashedOps), hashedOps)) { revert(0, 0) }
        }
    }

    /// @param sender The sender of this particular transaction or UserOp.
    /// @param nonce Transaction/UserOp nonce.
    /// @param callData Transaction/UserOp call data.
    /// @param pbhPayload The PBH payload containing the proof data.
    function verifyPbh(address sender, uint256 nonce, bytes calldata callData, PBHPayload memory pbhPayload)
        public
        virtual
        onlyInitialized
        onlyProxy
    {
        // First, we make sure this nullifier has not been used before.
        if (nullifierHashes[pbhPayload.nullifierHash]) {
            revert InvalidNullifier();
        }

        // Verify the external nullifier
        PBHExternalNullifier.verify(pbhPayload.pbhExternalNullifier, numPbhPerMonth);

        // If worldId address is set, proceed with on chain verification,
        // otherwise assume verification has been done off chain by the builder.
        if (address(worldId) != address(0)) {
            // We now generate the signal hash from the sender, nonce, and calldata
            uint256 signalHash = abi.encodePacked(sender, nonce, callData).hashToField();

            // We now verify the provided proof is valid and the user is verified by World ID
            worldId.verifyProof(
                pbhPayload.root,
                _GROUP_ID,
                signalHash,
                pbhPayload.nullifierHash,
                pbhPayload.pbhExternalNullifier,
                pbhPayload.proof
            );
        }

        // We now record the user has done this, so they can't do it again (proof of uniqueness)
        nullifierHashes[pbhPayload.nullifierHash] = true;

        emit PBH(sender, nonce, pbhPayload);
    }

    /// @notice Sets the number of PBH transactions allowed per month.
    /// @param _numPbhPerMonth The number of allowed PBH transactions per month.
    function setNumPbhPerMonth(uint8 _numPbhPerMonth) external virtual onlyOwner onlyProxy onlyInitialized {
        numPbhPerMonth = _numPbhPerMonth;
        emit NumPbhPerMonthSet(_numPbhPerMonth);
    }

    /// @dev If the World ID address is set to 0, then it is assumed that verification will take place off chain.
    /// @notice Sets the World ID instance that will be used for verifying proofs.
    /// @param _worldId The World ID instance that will be used for verifying proofs.
    function setWorldId(address _worldId) external virtual onlyOwner onlyProxy onlyInitialized {
        worldId = IWorldIDGroups(_worldId);
        emit WorldIdSet(_worldId);
    }
}
