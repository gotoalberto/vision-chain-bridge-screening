// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

// Libraries
import { BridgeHookHashing } from "src/libraries/BridgeHookHashing.sol";
import { BridgeHookTypes } from "src/libraries/BridgeHookTypes.sol";

// Interfaces
import { IComplianceModule } from "interfaces/compliance/IComplianceModule.sol";
import { IPolicy } from "interfaces/compliance/IPolicy.sol";

/// @title BoundedHoldPolicy
/// @notice Prototype of an alternative Vision policy for the same ComplianceModule. It screens
///         like VisionPolicyV1 (deny list first, allowlisted senders pass, everyone else waits
///         for the screener), with one difference: a hold that nobody has escalated expires.
///         After maxReview anyone can release it on its original terms. Only two things stop
///         that clock: a party on the deny list (official sanctions lists) and an explicit
///         escalation, which Compliance must own. An outage of the screener therefore delays
///         deposits by at most maxReview instead of indefinitely, and every indefinite freeze is
///         a recorded human decision.
/// @dev    Not audited. Built for this prototype only. Withdrawal handling is simplified.
contract BoundedHoldPolicy is IPolicy {
    IComplianceModule public immutable module;
    address public compliance;
    address public screener;
    uint64 public maxReview;

    mapping(address => bool) public allowlisted;
    mapping(address => bool) public denylisted;
    /// @notice Held items that a person must decide on. They never expire.
    mapping(bytes32 => bool) public escalated;

    event Escalated(bytes32 indexed id, bytes32 caseRef);
    event EscalationClosed(bytes32 indexed id);
    event ReleasedAfterTimeout(bytes32 indexed id);

    error Unauthorized();
    error StillUnderReview(uint256 releasableAt);
    error BlockedByDecision();

    constructor(IComplianceModule _module, address _compliance, address _screener, uint64 _maxReview) {
        module = _module;
        compliance = _compliance;
        screener = _screener;
        maxReview = _maxReview;
    }

    // ----- IPolicy ------------------------------------------------------------------------

    function screenDeposit(BridgeHookTypes.Item calldata, Parties calldata _parties) external view returns (bool) {
        _onlyModule();
        if (_denied(_parties)) return false;
        return allowlisted[_parties.sender];
    }

    function screenWithdrawal(
        BridgeHookTypes.Item calldata,
        Parties calldata _parties,
        uint64 _expiresAt,
        uint256
    )
        external
        view
        returns (bool)
    {
        _onlyModule();
        if (_denied(_parties)) return false;
        return allowlisted[_parties.sender] || _expiresAt > block.timestamp;
    }

    function screenRelease(
        BridgeHookTypes.Item calldata _item,
        Parties calldata _parties,
        uint64 _expiresAt
    )
        external
        view
        returns (bool)
    {
        _onlyModule();
        if (_denied(_parties) || escalated[BridgeHookHashing.hashItem(_item)]) return false;
        return _expiresAt > block.timestamp;
    }

    // ----- Screener ------------------------------------------------------------------------

    /// @notice The screener clears a held item and completes it.
    function clearAndComplete(BridgeHookTypes.Item calldata _item) external {
        if (msg.sender != screener) revert Unauthorized();
        module.recordVerdict(BridgeHookHashing.hashItem(_item), uint64(block.timestamp + 1 days));
        module.completeDeposit(_item);
    }

    /// @notice The screener, or Compliance, stops the clock on a held item. From here only
    ///         Compliance can release it.
    function escalate(bytes32 _id, bytes32 _caseRef) external {
        if (msg.sender != screener && msg.sender != compliance) revert Unauthorized();
        escalated[_id] = true;
        emit Escalated(_id, _caseRef);
    }

    // ----- Compliance ----------------------------------------------------------------------

    /// @notice Compliance closes a case as a false positive: the escalation is lifted and the
    ///         item cleared. Completion is then permissionless.
    function closeAsFalsePositive(bytes32 _id) external {
        if (msg.sender != compliance) revert Unauthorized();
        escalated[_id] = false;
        emit EscalationClosed(_id);
        module.recordVerdict(_id, uint64(block.timestamp + 1 days));
    }

    function setDenylisted(address _account, bool _isDenied) external {
        if (msg.sender != compliance) revert Unauthorized();
        denylisted[_account] = _isDenied;
    }

    function setAllowlisted(address _account, bool _allowed) external {
        if (msg.sender != compliance) revert Unauthorized();
        allowlisted[_account] = _allowed;
    }

    // ----- Anyone --------------------------------------------------------------------------

    /// @notice Releases a held deposit nobody has escalated once maxReview has passed.
    function releaseAfterTimeout(BridgeHookTypes.Item calldata _item) external {
        bytes32 id = BridgeHookHashing.hashItem(_item);
        if (escalated[id]) revert BlockedByDecision();
        uint256 releasableAt = uint256(module.items(id).heldAt) + maxReview;
        if (block.timestamp < releasableAt) revert StillUnderReview(releasableAt);
        // screenRelease still applies the deny list when the module completes the item.
        module.recordVerdict(id, uint64(block.timestamp + 1 hours));
        emit ReleasedAfterTimeout(id);
        module.completeDeposit(_item);
    }

    // ----- Internal ------------------------------------------------------------------------

    function _onlyModule() internal view {
        if (msg.sender != address(module)) revert Unauthorized();
    }

    function _denied(Parties calldata _parties) internal view returns (bool) {
        return denylisted[_parties.sender] || denylisted[_parties.recipient];
    }
}
