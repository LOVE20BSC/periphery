// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Vm} from "@forge-std/Vm.sol";
import {LOVE20Hub} from "../src/LOVE20Hub.sol";
import {ILOVE20Hub, ILOVE20HubEvents, ILOVE20HubErrors} from "../src/interfaces/ILOVE20Hub.sol";
import {
    StakeLiquidityWithTokenParams,
    AddLiquidityWithTokenParams,
    AddLiquidityWithNativeParams
} from "../src/interfaces/ILOVE20Hub.sol";
import {MockERC20} from "./mocks/HubMocks.sol";
import {HubTestBase} from "./HubTestBase.sol";

/// @dev Construction: exactly one injected dependency, everything else derived through it, all immutable
///      and all upper case, with no `init` and no `initialized` flag on the ABI.
contract ConstructionTest is HubTestBase {
    function testDerivesEveryDependencyFromTheStakeAddress() public view {
        assertEq(hub.STAKE_ADDRESS(), address(stake), "stake injected");
        assertEq(address(hub.ROUTER_ADDRESS()), address(router), "router derived from stake");
        assertEq(hub.PAIR_FACTORY_ADDRESS(), address(factory), "factory derived from stake");
        assertEq(hub.LAUNCH_ADDRESS(), address(launch), "launch derived from stake");
        assertEq(hub.MEMBER_NFT_ADDRESS(), address(memberNFT), "member NFT derived from stake");
        assertEq(hub.WRAPPED_NATIVE_ADDRESS(), address(wbnb), "wrapped native derived from the router");
    }

    function testExposesNoInitOrInitializedEntry() public view {
        // The absence is part of the contract: dependency injection means there is nothing left to
        // initialize, so neither selector may exist. Probing them is the only way to assert absence.
        (bool hasInit,) = address(hub).staticcall(abi.encodeWithSignature("init(address)"));
        (bool hasInitialized,) = address(hub).staticcall(abi.encodeWithSignature("initialized()"));
        assertFalse(hasInit, "no init");
        assertFalse(hasInitialized, "no initialized flag");
    }
}

/// @dev Event contract. `periphery.hub` carries only the orchestration facts of this layer; the amounts
///      that entered the position or the pool are recoverable as `prepared − remaining`, and both shapes
///      ("exactly enough, no remainder" and "ratio off, refund issued") need a fixture.
contract HubEventTest is HubTestBase {
    bytes32 internal constant STAKED_WITH_TOKEN_TOPIC =
        keccak256("HubLiquidityStakedWithToken(address,uint256,address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant ADDED_WITH_TOKEN_TOPIC = keccak256(
        "HubLiquidityAddedWithToken(address,address,address,uint256,uint256,uint256,uint256,uint256)"
    );
    bytes32 internal constant ADDED_WITH_NATIVE_TOPIC = keccak256(
        "HubLiquidityAddedWithNative(address,address,address,uint256,uint256,uint256,uint256,uint256)"
    );

    function testStakeEventCarriesTheThreeIndexedKeysAndTheFourAmounts() public {
        _fundAlice(10_000e18, 0);

        vm.recordLogs();
        vm.prank(alice);
        hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                inputTokenAddress: address(token),
                inputTokenAmount: 10_000e18,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hub) || logs[i].topics[0] != STAKED_WITH_TOKEN_TOPIC) continue;
            found = true;
            assertEq(logs[i].topics.length, 4, "three indexed keys");
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(token), "slot 1 is the root key");
            assertEq(uint256(logs[i].topics[2]), MEMBER_ID, "slot 2 is memberId");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), alice, "slot 3 is the caller");
            (uint256 preparedToken, uint256 preparedParent, uint256 remainingToken, uint256 remainingParent) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            assertGt(preparedToken, 0, "prepared token");
            assertGt(preparedParent, 0, "prepared parent");
            assertLe(remainingToken, preparedToken, "remainder bounded");
            assertLe(remainingParent, preparedParent, "remainder bounded");
        }
        assertTrue(found, "event emitted");
    }

    /// @dev Balanced pool and a single-sided input: the swap leaves exactly enough, so both remainders are
    ///      zero. The floor division in the swap sizing means one wei can survive on the parent side, so
    ///      the fixture asserts the shape (a zero remainder on at least the side the caller did not supply)
    ///      rather than a value that would break the moment rounding moves.
    function testStakeEventReportsZeroRemainderWhenTheRatioIsExact() public {
        _fundAlice(10_000e18, 0);

        vm.recordLogs();
        vm.prank(alice);
        hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                inputTokenAddress: address(token),
                inputTokenAmount: 10_000e18,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (, uint256 preparedParent, uint256 remainingToken, uint256 remainingParent) = _stakeAmounts(logs);
        assertEq(remainingToken, 0, "community side has no remainder");
        assertLe(remainingParent, 1, "parent side keeps at most the rounding wei of a balanced pool");
        assertGt(preparedParent, 0, "parent side was funded");
    }

    /// @dev Skewed pool: the conversion cannot use the whole input, so a remainder is refunded and shows up
    ///      in the event. This is the "比例失衡、有剩余" fixture the spec requires next to the zero case.
    function testStakeEventReportsRemainderWhenTheRatioIsOff() public {
        // Skew the pool by removing community token: the conversion then cannot use the whole input.
        pair.removeFromReserve(address(token), 800_000e18);
        token.burn(address(pair), 800_000e18);
        _fundAlice(10_000e18, 0);

        vm.recordLogs();
        vm.prank(alice);
        hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                inputTokenAddress: address(token),
                inputTokenAmount: 10_000e18,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 preparedToken,, uint256 remainingToken,) = _stakeAmounts(logs);
        assertGt(remainingToken, 0, "skewed pool leaves a remainder");
        assertLt(remainingToken, preparedToken, "the remainder is not the whole prepared amount");
        assertEq(token.balanceOf(address(hub)), 0, "the remainder was refunded, not kept");
    }

    function testAddLiquidityEventsUseTheRecipientAsTheObjectKey() public {
        _fundAlice(10_000e18, 0);

        vm.recordLogs();
        vm.prank(alice);
        hub.addLiquidityWithToken(
            AddLiquidityWithTokenParams({
                tokenAddress: address(token),
                inputTokenAddress: address(token),
                inputTokenAmount: 10_000e18,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                to: bob,
                deadline: block.timestamp
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hub) || logs[i].topics[0] != ADDED_WITH_TOKEN_TOPIC) continue;
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(token), "slot 1 is the root key");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), bob, "slot 2 is the recipient, not a member id");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), alice, "slot 3 is the caller");
        }
        assertTrue(found, "event emitted");
    }

    function testAddLiquidityWithNativeEventShape() public {
        vm.deal(alice, 10_000e18);

        vm.recordLogs();
        vm.prank(alice);
        hub.addLiquidityWithNative{value: 10_000e18}(
            AddLiquidityWithNativeParams({
                tokenAddress: address(token),
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                to: bob,
                deadline: block.timestamp
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hub) || logs[i].topics[0] != ADDED_WITH_NATIVE_TOPIC) continue;
            found = true;
            assertEq(logs[i].topics.length, 4, "three indexed keys");
            (uint256 preparedToken, uint256 preparedParent, uint256 remainingToken, uint256 remainingParent,) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            assertGt(preparedToken, 0, "prepared token");
            assertGt(preparedParent, 0, "prepared parent");
            assertLe(remainingToken, preparedToken, "remainder bounded");
            assertLe(remainingParent, preparedParent, "remainder bounded");
        }
        assertTrue(found, "event emitted");
    }

    function _stakeAmounts(Vm.Log[] memory logs)
        private
        view
        returns (uint256 preparedToken, uint256 preparedParent, uint256 remainingToken, uint256 remainingParent)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hub) || logs[i].topics[0] != STAKED_WITH_TOKEN_TOPIC) continue;
            return abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
        }
        revert("missing Hub stake event");
    }
}
