// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// Testing
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";
import { CommonTest } from "test/setup/CommonTest.sol";
import { BoundedHoldPolicy } from "test/vision/BoundedHoldPolicy.sol";

// Scripts
import { DeployUtils } from "scripts/libraries/DeployUtils.sol";
import { ForgeArtifacts } from "scripts/libraries/ForgeArtifacts.sol";

// Libraries
import { BridgeHookHashing } from "src/libraries/BridgeHookHashing.sol";
import { BridgeHookTypes } from "src/libraries/BridgeHookTypes.sol";
import { DevFeatures } from "src/libraries/DevFeatures.sol";

// Interfaces
import { IComplianceModule } from "interfaces/compliance/IComplianceModule.sol";
import { IPolicy } from "interfaces/compliance/IPolicy.sol";
import { IProxy } from "interfaces/universal/IProxy.sol";
import { IProxyAdmin } from "interfaces/universal/IProxyAdmin.sol";

/// @title BoundedHoldScenarios
/// @notice The alternative policy (option B in the write-up) on the same ComplianceModule and
///         the same unmodified Portal: holds expire unless a person escalates them.
contract BoundedHoldScenarios is CommonTest {
    address internal custodian = makeAddr("custodyMultisig");
    address internal compliance = makeAddr("complianceMultisig");
    address internal screener = makeAddr("screenerService");
    address internal retail = makeAddr("retailUser");
    address internal sanctioned = makeAddr("sanctionedAddress");
    address internal anyone = makeAddr("anyone");

    IComplianceModule internal module;
    BoundedHoldPolicy internal policy;

    bytes32 internal constant TRANSACTION_DEPOSITED = keccak256("TransactionDeposited(address,address,uint256,bytes)");

    function setUp() public override {
        super.setUp();
        skipIfDevFeatureDisabled(DevFeatures.BRIDGE_HOOK);

        IProxyAdmin moduleProxyAdmin = IProxyAdmin(
            DeployUtils.create1({
                _name: "ProxyAdmin",
                _args: DeployUtils.encodeConstructor(abi.encodeCall(IProxyAdmin.__constructor__, (custodian)))
            })
        );
        address impl = DeployUtils.create1({
            _name: "ComplianceModule",
            _args: DeployUtils.encodeConstructor(abi.encodeCall(IComplianceModule.__constructor__, ()))
        });
        module = IComplianceModule(
            DeployUtils.create1({
                _name: "Proxy",
                _args: DeployUtils.encodeConstructor(abi.encodeCall(IProxy.__constructor__, (address(moduleProxyAdmin))))
            })
        );
        vm.prank(custodian);
        moduleProxyAdmin.upgrade(payable(address(module)), impl);

        policy = new BoundedHoldPolicy(module, compliance, screener, 24 hours);
        vm.prank(compliance);
        policy.setDenylisted(sanctioned, true);

        vm.prank(address(moduleProxyAdmin));
        module.initialize(compliance, IPolicy(address(policy)), optimismPortal2, l1CrossDomainMessenger, l1StandardBridge);
        vm.store(
            address(optimismPortal2),
            bytes32(ForgeArtifacts.getSlot("OptimismPortal2", "bridgeHook").slot),
            bytes32(uint256(uint160(address(module))))
        );

        vm.deal(retail, 10 ether);
        vm.deal(sanctioned, 10 ether);
    }

    function test_optionB1_screenerDown_holdExpires_anyoneReleases() external {
        console.log("");
        console.log("B1. Screener down: an unreviewed hold expires after 24 hours");
        BridgeHookTypes.Item memory item = _deposit(retail, 1 ether);
        console.log("  [Retail sees] Deposit received on Ethereum. Checking it, at most 24 hours.");

        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(BoundedHoldPolicy.StillUnderReview.selector, block.timestamp + 24 hours));
        policy.releaseAfterTimeout(item);

        vm.warp(block.timestamp + 24 hours);
        vm.recordLogs();
        vm.prank(anyone);
        policy.releaseAfterTimeout(item);
        assertTrue(_emitted(TRANSACTION_DEPOSITED), "released on the original terms");
        console.log("  [Retail sees] No objection within 24 hours. Deposit sent to Vision Chain.");
    }

    function test_optionB2_sanctionedNeverExpires() external {
        console.log("");
        console.log("B2. Official list hit: the clock never runs out");
        BridgeHookTypes.Item memory item = _deposit(sanctioned, 5 ether);
        vm.warp(block.timestamp + 365 days);
        vm.prank(anyone);
        vm.expectRevert(IComplianceModule.ComplianceModule_PolicyRefused.selector);
        policy.releaseAfterTimeout(item);
        assertEq(address(module).balance, 5 ether);
        console.log("  [check] a deny list party stays frozen after a year");
    }

    function test_optionB3_escalatedCase_needsCompliance() external {
        console.log("");
        console.log("B3. KYT alert: the screener escalates, Compliance decides");
        BridgeHookTypes.Item memory item = _deposit(retail, 2 ether);
        bytes32 id = BridgeHookHashing.hashItem(item);

        vm.prank(screener);
        policy.escalate(id, keccak256("CASE-2026-0042"));
        console.log("  [Retail sees] Deposit under review by our team.");

        vm.warp(block.timestamp + 30 days);
        vm.prank(anyone);
        vm.expectRevert(BoundedHoldPolicy.BlockedByDecision.selector);
        policy.releaseAfterTimeout(item);

        vm.prank(compliance);
        policy.closeAsFalsePositive(id);
        vm.recordLogs();
        vm.prank(anyone);
        module.completeDeposit(item);
        assertTrue(_emitted(TRANSACTION_DEPOSITED));
        console.log("  [Retail sees] Review finished. Deposit sent to Vision Chain.");
    }

    function _deposit(address _from, uint256 _amount) internal returns (BridgeHookTypes.Item memory item_) {
        item_ = BridgeHookTypes.Item({
            direction: BridgeHookTypes.Direction.Deposit,
            asset: BridgeHookTypes.Asset.ETH,
            from: _from,
            aliased: false,
            to: _from,
            ethAmount: _amount,
            l2Value: _amount,
            gasLimit: 100_000,
            isCreation: false,
            data: hex"",
            nonce: uint256(
                vm.load(address(optimismPortal2), bytes32(ForgeArtifacts.getSlot("OptimismPortal2", "depositNonce").slot))
            )
        });
        vm.prank(_from, _from);
        optimismPortal2.depositTransaction{ value: _amount }(_from, _amount, 100_000, false, hex"");
    }

    function _emitted(bytes32 _topic) internal view returns (bool found_) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == _topic) found_ = true;
        }
    }
}
