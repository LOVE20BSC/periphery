// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Vm} from "@forge-std/Vm.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {LOVE20Hub} from "../src/LOVE20Hub.sol";
import {ILOVE20HubErrors} from "../src/interfaces/ILOVE20Hub.sol";
import {
    StakeLiquidityWithTokenParams,
    StakeLiquidityWithNativeParams,
    StakeLiquidityQuote
} from "../src/interfaces/ILOVE20Hub.sol";
import {MockERC20, MockWrappedNative} from "./mocks/HubMocks.sol";
import {HubTestBase, DexProfile} from "./HubTestBase.sol";

/// @dev Both stake entry points: a success case each, the endpoint minimum check on the whole chain, and
///      the cross-layer assertion that `prepared − remaining` is exactly the amount core recorded as
///      entering the position. The dual-sided case is the one this revision adds: a caller may supply
///      both tokens, and the excess side is swapped before staking.
contract StakeLiquidityTest is HubTestBase {
    bytes32 internal constant STAKED_WITH_TOKEN_TOPIC =
        keccak256("HubLiquidityStakedWithToken(address,uint256,address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant STAKED_WITH_NATIVE_TOPIC =
        keccak256("HubLiquidityStakedWithNative(address,uint256,address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant LIQUIDITY_STAKED_TOPIC = keccak256(
        "LiquidityStaked(address,uint256,uint256,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
    );

    /// @dev The deadline is the first check on every write entry, so an expired one is rejected before
    ///      any funds move.
    function testStakeWithTokenRejectsAnExpiredDeadline() public {
        _fundAlice(10_000e18, 0);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILOVE20HubErrors.DeadlineExpired.selector, block.timestamp, block.timestamp - 1
            )
        );
        hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                tokenAmountDesired: 10_000e18,
                parentTokenAmountDesired: 0,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp - 1
            })
        );
    }

    function testStakeWithTokenSuccess() public {
        _fundAlice(10_000e18, 0);

        vm.recordLogs();
        vm.prank(alice);
        (uint256 govVotesAdded, uint256 liquiditySharesAdded) = hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                tokenAmountDesired: 10_000e18,
                parentTokenAmountDesired: 0,
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
        assertEq(token.balanceOf(address(hub)), 0, "hub retains no token");
        assertEq(wbnb.balanceOf(address(hub)), 0, "hub retains no parent");
    }

    /// @dev Both sides supplied, pool off-ratio: the excess side is swapped, then the balanced pair goes into
    ///      the stake. This is the dual-sided capability the single-token Hub lacked.
    function testStakeWithBothSidesSwapsTheExcess() public {
        _fundAlice(10_000e18, 10_000e18);

        vm.recordLogs();
        vm.prank(alice);
        (uint256 govVotesAdded, uint256 liquiditySharesAdded) = hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                tokenAmountDesired: 10_000e18,
                parentTokenAmountDesired: 1_000e18,
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
        assertEq(
            hubAmounts.preparedTokenAmount - hubAmounts.remainingTokenAmount, coreAmounts.tokenAmount, "token entered"
        );
        assertEq(
            hubAmounts.preparedParentTokenAmount - hubAmounts.remainingParentTokenAmount,
            coreAmounts.parentTokenAmount,
            "parent entered"
        );
        assertEq(token.balanceOf(address(hub)), 0, "hub retains no token");
        assertEq(wbnb.balanceOf(address(hub)), 0, "hub retains no parent");
    }

    function testStakeWithNativeSuccess() public {
        _fundAlice(10_000e18, 0);
        vm.deal(alice, 10_000e18);

        vm.recordLogs();
        vm.prank(alice);
        (uint256 govVotesAdded, uint256 liquiditySharesAdded) = hub.stakeLiquidityWithNative{value: 10_000e18}(
            StakeLiquidityWithNativeParams({
                tokenAddress: address(token),
                tokenAmountDesired: 0,
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
            hubAmounts.preparedTokenAmount - hubAmounts.remainingTokenAmount, coreAmounts.tokenAmount, "token entered"
        );
        assertEq(
            hubAmounts.preparedParentTokenAmount - hubAmounts.remainingParentTokenAmount,
            coreAmounts.parentTokenAmount,
            "parent entered"
        );
        assertEq(address(hub).balance, 0, "hub retains no native");
    }

    function testStakeQuotePredictsTheRealizedSharesAndVotes() public {
        _fundAlice(10_000e18, 10_000e18);

        StakeLiquidityQuote memory quote = hub.quoteStakeLiquidity(
            address(token), 10_000e18, 1_000e18, MEMBER_ID, PROMISED_WAITING_PHASES
        );

        assertGt(quote.liquiditySharesAdded, 0, "quote predicts a non-zero share increment");
        assertGt(quote.govVotesAdded, 0, "quote predicts a non-zero vote increment");

        vm.prank(alice);
        (uint256 govVotesAdded, uint256 liquiditySharesAdded) = hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                tokenAmountDesired: 10_000e18,
                parentTokenAmountDesired: 1_000e18,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp
            })
        );

        assertEq(quote.liquiditySharesAdded, liquiditySharesAdded, "predicted share increment");
        assertEq(quote.govVotesAdded, govVotesAdded, "predicted vote increment");
    }

    /// @dev The quote must read the member's existing position, otherwise `govVotesAdded` is computed
    ///      against the wrong baseline.
    function testStakeQuotePredictsOnTopOfAnExistingPosition() public {
        _fundAlice(20_000e18, 20_000e18);

        vm.startPrank(alice);
        hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                tokenAmountDesired: 5_000e18,
                parentTokenAmountDesired: 5_000e18,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp
            })
        );

        StakeLiquidityQuote memory quote = hub.quoteStakeLiquidity(
            address(token), 10_000e18, 1_000e18, MEMBER_ID, PROMISED_WAITING_PHASES
        );
        (uint256 govVotesAdded, uint256 liquiditySharesAdded) = hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                tokenAmountDesired: 10_000e18,
                parentTokenAmountDesired: 1_000e18,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        assertEq(quote.liquiditySharesAdded, liquiditySharesAdded, "predicted increment on a non-empty position");
        assertEq(quote.govVotesAdded, govVotesAdded, "predicted vote increment on a non-empty position");
    }

    /// @dev The same quote/write agreement under a DEX that charges a protocol fee, where the LP actually
    ///      minted is smaller than the naive projection.
    function testStakeQuoteMatchesTheWriteOnPancakeMainnet() public {
        (uint256 lpRatio, uint256 protocolRatio) = DexProfile.pancakeMainnet();
        _setDexProfile(lpRatio, protocolRatio);
        _seed(1_000_000e18, 1_000_000e18);
        _fundAlice(10_000e18, 10_000e18);

        StakeLiquidityQuote memory quote = hub.quoteStakeLiquidity(
            address(token), 10_000e18, 1_000e18, MEMBER_ID, PROMISED_WAITING_PHASES
        );

        vm.prank(alice);
        (uint256 govVotesAdded, uint256 liquiditySharesAdded) = hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                tokenAmountDesired: 10_000e18,
                parentTokenAmountDesired: 1_000e18,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp
            })
        );

        assertEq(quote.liquiditySharesAdded, liquiditySharesAdded, "predicted share increment");
        assertEq(quote.govVotesAdded, govVotesAdded, "predicted vote increment");
    }

    function testStakeWithTokenRevertsWhenEnteredBelowTokenMin() public {
        _fundAlice(10_000e18, 0);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILOVE20HubErrors.InsufficientTokenAmount.selector,
                uint256(5_004_945_277_897_729_495_366),
                type(uint256).max
            )
        );
        hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                tokenAmountDesired: 10_000e18,
                parentTokenAmountDesired: 0,
                tokenAmountMin: type(uint256).max,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp
            })
        );
    }

    function testStakeWithTokenRevertsWhenEnteredBelowParentMin() public {
        _fundAlice(10_000e18, 0);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILOVE20HubErrors.InsufficientParentTokenAmount.selector,
                uint256(4_955_391_364_255_177_718_184),
                type(uint256).max
            )
        );
        hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                tokenAmountDesired: 10_000e18,
                parentTokenAmountDesired: 0,
                tokenAmountMin: 0,
                parentTokenAmountMin: type(uint256).max,
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
                tokenAmountDesired: 0,
                tokenAmountMin: 0,
                parentTokenAmountMin: type(uint256).max,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp
            })
        );
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

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

    function _hubAmounts(Vm.Log[] memory logs, bytes32 topic) internal pure returns (HubAmounts memory amounts) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != topic) continue;
            (amounts.preparedTokenAmount, amounts.preparedParentTokenAmount, amounts.remainingTokenAmount, amounts.remainingParentTokenAmount) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            return amounts;
        }
        revert("HUB_LOG_MISSING");
    }

    /// @dev `LiquidityStaked` carries three indexed keys and twelve payload fields; `tokenAmount` and
    ///      `parentTokenAmount` are the third and fourth payload fields.
    function _decodeStakeAmounts(bytes memory data)
        internal
        pure
        returns (uint256 tokenAmount, uint256 parentTokenAmount)
    {
        (,, tokenAmount, parentTokenAmount,,,,,,,,) =
            abi.decode(data, (address, address, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256));
    }

    function _stakeAmounts(Vm.Log[] memory logs) internal pure returns (StakeAmounts memory amounts) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != LIQUIDITY_STAKED_TOPIC) continue;
            (uint256 tokenAmount, uint256 parentTokenAmount) = _decodeStakeAmounts(logs[i].data);
            amounts.tokenAmount = tokenAmount;
            amounts.parentTokenAmount = parentTokenAmount;
            return amounts;
        }
        revert("CORE_LOG_MISSING");
    }
}
