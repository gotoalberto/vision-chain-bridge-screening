// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// Testing
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";
import { CommonTest } from "test/setup/CommonTest.sol";

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
import { IVisionPolicyV1 } from "interfaces/compliance/IVisionPolicyV1.sol";
import { IProxy } from "interfaces/universal/IProxy.sol";
import { IProxyAdmin } from "interfaces/universal/IProxyAdmin.sol";

/// @title VisionBridgeScenarios
/// @notice Walks through the bridge screening scenarios of the Vision Chain exercise on the real
///         OP Stack L1 contracts: OptimismPortal2 with its bridge hook, the L1StandardBridge, the
///         ComplianceModule and VisionPolicyV1. Every scenario logs what the user would see.
///         Run with: DEV_FEATURE__BRIDGE_HOOK=true forge test --match-path test/vision/* -vv
contract VisionBridgeScenarios is CommonTest {
    // Roles. Each one is a separate key so the separation of duties is visible in the test.
    address internal custodian = makeAddr("custodyMultisig"); // upgrades the module (holds custody)
    address internal compliance = makeAddr("complianceMultisig"); // owns the policy lists and the module
    address internal screener = makeAddr("screenerService"); // verdict writer, can only clear

    // Users.
    address internal bank = makeAddr("allowlistedBank");
    address internal retail = makeAddr("retailUser");
    address internal sanctioned = makeAddr("sanctionedAddress");
    address internal anyone = makeAddr("anyone");

    IComplianceModule internal module;
    IVisionPolicyV1 internal policy;

    bytes32 internal constant DEPOSIT_HELD = keccak256("DepositHeld(bytes32)");
    bytes32 internal constant TRANSACTION_DEPOSITED = keccak256("TransactionDeposited(address,address,uint256,bytes)");

    function setUp() public override {
        super.setUp();
        skipIfDevFeatureDisabled(DevFeatures.BRIDGE_HOOK);

        // 1. The module lives behind its own ProxyAdmin, owned by a custody multisig that is not
        //    the chain's ProxyAdmin owner.
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

        // 2. VisionPolicyV1: banks onboarded by Partnerships are allowlisted, the official lists
        //    feed the deny list, verdicts last at most 3 days, withdrawals wait 1 hour.
        address[] memory allowlist = new address[](1);
        allowlist[0] = bank;
        address[] memory denylist = new address[](1);
        denylist[0] = sanctioned;
        policy = IVisionPolicyV1(
            DeployUtils.create1({
                _name: "VisionPolicyV1",
                _args: DeployUtils.encodeConstructor(
                    abi.encodeCall(
                        IVisionPolicyV1.__constructor__,
                        (module, compliance, screener, 3 days, 1 hours, allowlist, denylist)
                    )
                )
            })
        );
        vm.prank(address(moduleProxyAdmin));
        module.initialize(compliance, IPolicy(address(policy)), optimismPortal2, l1CrossDomainMessenger, l1StandardBridge);

        // 3. Point the Portal at the module. On a live chain this is an OPCM upgrade with
        //    overrides.cfg.bridgeHook; the test writes the slot directly.
        vm.store(
            address(optimismPortal2),
            bytes32(ForgeArtifacts.getSlot("OptimismPortal2", "bridgeHook").slot),
            bytes32(uint256(uint160(address(module))))
        );

        vm.deal(bank, 100 ether);
        vm.deal(retail, 100 ether);
        vm.deal(sanctioned, 100 ether);
    }

    // ---------------------------------------------------------------------------------------
    // Scenario 1: an allowlisted bank deposits. Nothing changes compared with a standard chain.
    // ---------------------------------------------------------------------------------------
    function test_scenario1_allowlistedDeposit_proceeds() external {
        _title("1. Allowlisted bank deposits 10 ETH");
        uint256 lockboxBefore = address(ethLockbox).balance;

        vm.recordLogs();
        vm.prank(bank, bank);
        optimismPortal2.depositTransaction{ value: 10 ether }(bank, 10 ether, 100_000, false, hex"");

        assertTrue(_emitted(TRANSACTION_DEPOSITED), "deposit must reach L2");
        assertEq(address(ethLockbox).balance - lockboxBefore, 10 ether);
        _user("Bank", "Deposit sent. Arrives on Vision Chain in the next L2 blocks (about 1 to 3 minutes).");
    }

    // ---------------------------------------------------------------------------------------
    // Scenario 2: an unknown but clean user deposits. The deposit waits for the screener, which
    // clears and completes it on the original terms.
    // ---------------------------------------------------------------------------------------
    function test_scenario2_unknownCleanDeposit_heldThenCleared() external {
        _title("2. Unknown retail user deposits 1 ETH");

        BridgeHookTypes.Item memory item = _ethDeposit(retail, retail, 1 ether, hex"");
        vm.recordLogs();
        vm.prank(retail, retail);
        optimismPortal2.depositTransaction{ value: 1 ether }(retail, 1 ether, 100_000, false, hex"");

        assertTrue(_emitted(DEPOSIT_HELD), "unknown senders wait for screening");
        assertFalse(_emitted(TRANSACTION_DEPOSITED), "nothing reaches L2 yet");
        assertEq(address(module).balance, 1 ether, "the module holds the ETH");
        _user("Retail", "Deposit received on Ethereum. Checking it, this usually takes a few minutes.");

        // The screener checks both parties off chain (lists plus KYT) and finds nothing.
        vm.recordLogs();
        vm.prank(screener);
        policy.clearAndCompleteDeposit(item, uint64(block.timestamp + 1 days));

        assertTrue(_emitted(TRANSACTION_DEPOSITED), "deposit reaches L2 on its original terms");
        assertEq(address(module).balance, 0);
        _user("Retail", "Check passed. Deposit sent to Vision Chain.");
    }

    // ---------------------------------------------------------------------------------------
    // Scenario 3: a sanctioned address deposits. The deposit is held, the funds sit in the
    // module, and neither the screener nor anyone else can push it through or send it back.
    // ---------------------------------------------------------------------------------------
    function test_scenario3_sanctionedDeposit_frozen() external {
        _title("3. Sanctioned address deposits 5 ETH");
        uint256 lockboxBefore = address(ethLockbox).balance;

        BridgeHookTypes.Item memory item = _ethDeposit(sanctioned, sanctioned, 5 ether, hex"");
        vm.recordLogs();
        vm.prank(sanctioned, sanctioned);
        optimismPortal2.depositTransaction{ value: 5 ether }(sanctioned, 5 ether, 100_000, false, hex"");

        assertTrue(_emitted(DEPOSIT_HELD));
        assertFalse(_emitted(TRANSACTION_DEPOSITED), "nothing reaches L2");
        assertEq(address(module).balance, 5 ether, "frozen in the module");
        assertEq(address(ethLockbox).balance, lockboxBefore, "L2 supply backing unchanged");
        _user("Sanctioned", "Deposit received on Ethereum. It is under review.");

        // The screener cannot clear it while the address is on the deny list.
        vm.prank(screener);
        vm.expectRevert(IComplianceModule.ComplianceModule_PolicyRefused.selector);
        policy.clearAndCompleteDeposit(item, uint64(block.timestamp + 1 days));

        // Nobody can complete it without a verdict.
        vm.prank(anyone);
        vm.expectRevert(IComplianceModule.ComplianceModule_ItemNotCleared.selector);
        module.completeDeposit(item);

        // There is no refund path: the module has no function that pays the sender back.
        console.log("  [check] screener and third parties cannot release it; no refund function exists");
    }

    // ---------------------------------------------------------------------------------------
    // Scenario 3b: the sanctioned address tries a forced L2 transaction with no value, for
    // example to move funds it already has on L2. The transaction is held as well.
    // ---------------------------------------------------------------------------------------
    function test_scenario3b_sanctionedForcedTransaction_held() external {
        _title("3b. Sanctioned address forces an L2 call with no value");
        bytes memory transferOnL2 = abi.encodeWithSignature("transfer(address,uint256)", retail, 1e18);

        vm.recordLogs();
        vm.prank(sanctioned, sanctioned);
        optimismPortal2.depositTransaction(makeAddr("someL2Token"), 0, 100_000, false, transferOnL2);

        assertTrue(_emitted(DEPOSIT_HELD), "forced transactions are screened too");
        assertFalse(_emitted(TRANSACTION_DEPOSITED));
        _user("Sanctioned", "Transaction received on Ethereum. It is under review.");
    }

    // ---------------------------------------------------------------------------------------
    // Scenario 3c: a clean user sends funds to a sanctioned L2 address. The recipient is
    // screened, so the deposit is held.
    // ---------------------------------------------------------------------------------------
    function test_scenario3c_depositToSanctionedRecipient_held() external {
        _title("3c. Allowlisted bank deposits to a sanctioned L2 recipient");
        vm.recordLogs();
        vm.prank(bank, bank);
        optimismPortal2.depositTransaction{ value: 1 ether }(sanctioned, 1 ether, 100_000, false, hex"");

        assertTrue(_emitted(DEPOSIT_HELD), "the deny list beats the allowlist");
        assertFalse(_emitted(TRANSACTION_DEPOSITED));
        _user("Bank", "Deposit under review.");
    }

    // ---------------------------------------------------------------------------------------
    // Scenario 4: false positive. Compliance takes the address off the deny list (case closed),
    // then the screener clears the held item. It completes to the original recipient only.
    // ---------------------------------------------------------------------------------------
    function test_scenario4_falsePositive_released() external {
        _title("4. False positive: release after review");
        BridgeHookTypes.Item memory item = _ethDeposit(sanctioned, sanctioned, 5 ether, hex"");
        vm.prank(sanctioned, sanctioned);
        optimismPortal2.depositTransaction{ value: 5 ether }(sanctioned, 5 ether, 100_000, false, hex"");
        _user("User", "Deposit under review.");

        // Compliance, not the screener, removes the address from the deny list.
        address[] memory accounts = new address[](1);
        accounts[0] = sanctioned;
        vm.prank(compliance);
        policy.removeFromDenylist(accounts);

        // The screener records the clearance. Anyone can then complete, so the user never
        // depends on Bitpanda to send the final transaction.
        vm.prank(screener);
        policy.clear(BridgeHookHashing.hashItem(item), uint64(block.timestamp + 1 days));

        vm.recordLogs();
        vm.prank(anyone);
        module.completeDeposit(item);

        assertTrue(_emitted(TRANSACTION_DEPOSITED), "released on the original terms");
        assertEq(address(module).balance, 0);
        _user("User", "Review finished. Deposit sent to Vision Chain, to the address you chose.");

        // A tampered item (different recipient) does not match any commitment.
        BridgeHookTypes.Item memory redirected = item;
        redirected.to = anyone;
        vm.prank(screener);
        vm.expectRevert();
        policy.clearAndCompleteDeposit(redirected, uint64(block.timestamp + 1 days));
        console.log("  [check] the item cannot be redirected to another recipient");
    }

    // ---------------------------------------------------------------------------------------
    // Scenario 5: a sanctioned address bridges an ERC20 through the L1StandardBridge. The tokens
    // leave the bridge escrow and move to the module.
    // ---------------------------------------------------------------------------------------
    function test_scenario5_sanctionedErc20Deposit_tokensFrozen() external {
        _title("5. Sanctioned address bridges 100 tokens through the L1StandardBridge");
        deal(address(L1Token), sanctioned, 100 ether, true);
        vm.startPrank(sanctioned, sanctioned);
        L1Token.approve(address(l1StandardBridge), type(uint256).max);
        vm.recordLogs();
        l1StandardBridge.depositERC20(address(L1Token), address(L2Token), 100 ether, 200_000, hex"");
        vm.stopPrank();

        assertTrue(_emitted(DEPOSIT_HELD));
        assertFalse(_emitted(TRANSACTION_DEPOSITED));
        assertEq(L1Token.balanceOf(address(module)), 100 ether, "tokens frozen in the module");
        assertEq(l1StandardBridge.deposits(address(L1Token), address(L2Token)), 0, "bridge accounting debited");
        _user("Sanctioned", "Token deposit under review.");
    }

    // ---------------------------------------------------------------------------------------
    // Scenario 6: governance. The chain's ProxyAdmin owner skips the hook, so L2 upgrades never
    // wait for screening.
    // ---------------------------------------------------------------------------------------
    function test_scenario6_governanceBypass() external {
        _title("6. ProxyAdmin owner deposits an L2 upgrade");
        address pao = proxyAdmin.owner();
        vm.deal(pao, 1 ether);
        vm.recordLogs();
        vm.prank(pao, pao);
        optimismPortal2.depositTransaction(address(0x4200000000000000000000000000000000000018), 0, 200_000, false, hex"");
        assertTrue(_emitted(TRANSACTION_DEPOSITED));
        assertFalse(_emitted(DEPOSIT_HELD));
        console.log("  [check] governance deposits are not screened (documented exception)");
    }

    // ---------------------------------------------------------------------------------------
    // Scenario 7: the screener is down for hours. Compliance chooses to keep holding (fail
    // closed) or flips the disable switch (fail open). Items already held stay held.
    // ---------------------------------------------------------------------------------------
    function test_scenario7_screenerOutage_disableSwitch() external {
        _title("7. Screener outage and the disable switch");
        vm.prank(retail, retail);
        optimismPortal2.depositTransaction{ value: 1 ether }(retail, 1 ether, 100_000, false, hex"");
        _user("Retail", "Deposit received on Ethereum. Checking it (delayed).");

        vm.prank(compliance);
        module.disable(0);

        vm.recordLogs();
        vm.prank(retail, retail);
        optimismPortal2.depositTransaction{ value: 2 ether }(retail, 2 ether, 100_000, false, hex"");
        assertTrue(_emitted(TRANSACTION_DEPOSITED), "new deposits proceed unscreened while disabled");
        assertEq(address(module).balance, 1 ether, "the earlier deposit stays held");
        console.log("  [check] disable lets new items through and keeps held items held");
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    /// @notice Builds the item the Portal will build for a plain ETH deposit from an EOA. The
    ///         nonce is the Portal's deposit counter at the time of the call.
    function _ethDeposit(
        address _from,
        address _to,
        uint256 _amount,
        bytes memory _data
    )
        internal
        returns (BridgeHookTypes.Item memory)
    {
        return BridgeHookTypes.Item({
            direction: BridgeHookTypes.Direction.Deposit,
            asset: BridgeHookTypes.Asset.ETH,
            from: _from,
            aliased: false,
            to: _to,
            ethAmount: _amount,
            l2Value: _amount,
            gasLimit: 100_000,
            isCreation: false,
            data: _data,
            nonce: _depositNonce()
        });
    }

    /// @notice Reads the Portal's deposit counter from storage.
    function _depositNonce() internal returns (uint256) {
        return uint256(
            vm.load(address(optimismPortal2), bytes32(ForgeArtifacts.getSlot("OptimismPortal2", "depositNonce").slot))
        );
    }

    /// @notice Whether the recorded logs contain an event with this signature.
    function _emitted(bytes32 _topic) internal view returns (bool found_) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == _topic) found_ = true;
        }
    }

    function _title(string memory _text) internal pure {
        console.log("");
        console.log(_text);
    }

    function _user(string memory _who, string memory _text) internal pure {
        console.log(string.concat("  [", _who, " sees] ", _text));
    }
}
