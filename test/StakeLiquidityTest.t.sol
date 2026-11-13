// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Vm} from "@forge-std/Vm.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {LOVE20Hub} from "../src/LOVE20Hub.sol";
import {ILOVE20HubErrors} from "../src/interfaces/ILOVE20Hub.sol";
import {StakeLiquidityWithTokenParams, StakeLiquidityWithNativeParams} from "../src/interfaces/ILOVE20Hub.sol";
import {MockERC20, MockWrappedNative} from "./mocks/HubMocks.sol";
import {HubTestBase} from "./HubTestBase.sol";

/// @dev Both stake entry points: a success case each, the endpoint minimum check on the whole chain, and
///      the cross-layer assertion that `prepared − remaining` is exactly the amount core recorded as
///      entering the position.
contract StakeLiquidityTest is HubTestBase {
    bytes32 internal constant STAKED_WITH_TOKEN_TOPIC =
        keccak256("HubLiquidityStakedWithToken(address,uint256,address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant STAKED_WITH_NATIVE_TOPIC =
        keccak256("HubLiquidityStakedWithNative(address,uint256,address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant LIQUIDITY_STAKED_TOPIC = keccak256(
        "LiquidityStaked(address,uint256,uint256,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
    );

    function testStakeWithTokenSuccess() public {
        _fundAlice(10_000e18, 0);
        uint256 tokenBalanceBefore = token.balanceOf(alice);

        vm.recordLogs();
        vm.prank(alice);
        (uint256 govVotesAdded, uint256 liquiditySharesAdded) = hub.stakeLiquidityWithToken(
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

        assertGt(liquiditySharesAdded, 0, "liquidity shares minted");
        assertGt(govVotesAdded, 0, "gov votes added");

        HubAmounts memory hubAmounts = _hubAmounts(logs, STAKED_WITH_TOKEN_TOPIC);
        StakeAmounts memory coreAmounts = _stakeAmounts(logs);

        // The cross-layer identity: what the Hub says entered is exactly what core recorded.
        assertEq(
            hubAmounts.preparedTokenAmount - hubAmounts.remainingTokenAmount, coreAmounts.tokenAmount, "token entered"
        );
        assertEq(
            hubAmounts.preparedParentTokenAmount - hubAmounts.remainingParentTokenAmount,
            coreAmounts.parentTokenAmount,
            "parent entered"
        );

        // Refund shape: the caller pays the whole input up front, the swap consumes one part and the
        // conversion the other, so the only thing that comes back is the unconsumed remainder.
        assertEq(
            token.balanceOf(alice),
            tokenBalanceBefore - 10_000e18 + hubAmounts.remainingTokenAmount,
            "token net spend"
        );
        assertEq(token.balanceOf(address(hub)), 0, "hub retains no community token");
        assertEq(wbnb.balanceOf(address(hub)), 0, "hub retains no parent token");
    }

    function testStakeWithNativeSuccess() public {
        vm.deal(alice, 10_000e18);
        uint256 nativeBalanceBefore = alice.balance;

        vm.recordLogs();
        vm.prank(alice);
        (uint256 govVotesAdded, uint256 liquiditySharesAdded) = hub.stakeLiquidityWithNative{value: 10_000e18}(
            StakeLiquidityWithNativeParams({
                tokenAddress: address(token),
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(liquiditySharesAdded, 0, "liquidity shares minted");
        assertGt(govVotesAdded, 0, "gov votes added");

        HubAmounts memory hubAmounts = _hubAmounts(logs, STAKED_WITH_NATIVE_TOPIC);
        StakeAmounts memory coreAmounts = _stakeAmounts(logs);

        assertEq(
            hubAmounts.preparedParentTokenAmount - hubAmounts.remainingParentTokenAmount,
            coreAmounts.parentTokenAmount,
            "parent entered"
        );
        assertEq(
            hubAmounts.preparedTokenAmount - hubAmounts.remainingTokenAmount, coreAmounts.tokenAmount, "token entered"
        );

        // The refund comes back as native currency, so the exit balance is the entry balance minus
        // `msg.value` plus whatever the conversion and the stake did not consume.
        assertEq(
            alice.balance,
            nativeBalanceBefore - 10_000e18 + hubAmounts.remainingParentTokenAmount,
            "native refund shape"
        );
        assertEq(address(hub).balance, 0, "hub retains no native");
        assertEq(wbnb.balanceOf(address(hub)), 0, "hub retains no wrapped native");
        assertEq(token.balanceOf(address(hub)), 0, "hub retains no community token");
    }

    function testStakeWithTokenRevertsWhenEnteredBelowTokenMin() public {
        _fundAlice(10_000e18, 0);
        uint256 enteredToken = hub.quoteSingleTokenStake(address(token), address(token), 10_000e18).usableTokenAmount;

        // One wei above what the whole chain actually deposits: the endpoint check has to see it.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ILOVE20HubErrors.InsufficientTokenAmount.selector, enteredToken, enteredToken + 1)
        );
        hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                inputTokenAddress: address(token),
                inputTokenAmount: 10_000e18,
                tokenAmountMin: enteredToken + 1,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp
            })
        );
    }

    function testStakeWithTokenRevertsWhenEnteredBelowParentMin() public {
        _fundAlice(10_000e18, 0);
        uint256 enteredParent = hub.quoteSingleTokenStake(address(token), address(token), 10_000e18).usableParentTokenAmount;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILOVE20HubErrors.InsufficientParentTokenAmount.selector, enteredParent, enteredParent + 1
            )
        );
        hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                inputTokenAddress: address(token),
                inputTokenAmount: 10_000e18,
                tokenAmountMin: 0,
                parentTokenAmountMin: enteredParent + 1,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp
            })
        );
    }

    function testStakeWithNativeRevertsWhenEnteredBelowParentMin() public {
        vm.deal(alice, 10_000e18);

        vm.prank(alice);
        vm.expectRevert();
        hub.stakeLiquidityWithNative{value: 10_000e18}(
            StakeLiquidityWithNativeParams({
                tokenAddress: address(token),
                tokenAmountMin: 0,
                parentTokenAmountMin: type(uint256).max,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp
            })
        );
    }

    struct HubAmounts {
        uint256 preparedTokenAmount;
        uint256 preparedParentTokenAmount;
        uint256 remainingTokenAmount;
        uint256 remainingParentTokenAmount;
    }

    struct StakeAmounts {
        uint256 tokenAmount;
        uint256 parentTokenAmount;
    }

    function _hubAmounts(Vm.Log[] memory logs, bytes32 topic) private view returns (HubAmounts memory amounts) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hub) || logs[i].topics[0] != topic) continue;
            (amounts.preparedTokenAmount, amounts.preparedParentTokenAmount, amounts.remainingTokenAmount, amounts.remainingParentTokenAmount)
            = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            return amounts;
        }
        revert("missing Hub stake event");
    }

    /// @dev `LiquidityStaked` indexes `tokenAddress` / `round` / `memberId`, so the data section starts at
    ///      `caller` and the two entered amounts are the third and fourth non-indexed fields.
    function _stakeAmounts(Vm.Log[] memory logs) private view returns (StakeAmounts memory amounts) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(stake) || logs[i].topics[0] != LIQUIDITY_STAKED_TOPIC) continue;
            (,, amounts.tokenAmount, amounts.parentTokenAmount,,,,,,,,) = abi.decode(
                logs[i].data,
                (address, address, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
            );
            return amounts;
        }
        revert("missing core LiquidityStaked event");
    }
}
