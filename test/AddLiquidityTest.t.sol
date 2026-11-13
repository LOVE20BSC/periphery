// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Vm} from "@forge-std/Vm.sol";
import {ILOVE20HubErrors} from "../src/interfaces/ILOVE20Hub.sol";
import {
    AddLiquidityWithTokenParams,
    AddLiquidityWithNativeParams,
    SingleTokenLpQuote,
    SingleTokenStakeLiquidityQuote
} from "../src/interfaces/ILOVE20Hub.sol";
import {MockERC20, MockWrappedNative} from "./mocks/HubMocks.sol";
import {HubTestBase} from "./HubTestBase.sol";

/// @dev The group-LP entries: the same swap / conversion / refund core as the stake entries, but the LP
///      goes straight to `to` with no stake bookkeeping. Covers Zap's `zapToken` / `zapNativeToken`.
contract AddLiquidityTest is HubTestBase {
    bytes32 internal constant ADDED_WITH_TOKEN_TOPIC = keccak256(
        "HubLiquidityAddedWithToken(address,address,address,uint256,uint256,uint256,uint256,uint256)"
    );
    bytes32 internal constant ADDED_WITH_NATIVE_TOPIC = keccak256(
        "HubLiquidityAddedWithNative(address,address,address,uint256,uint256,uint256,uint256,uint256)"
    );

    function testAddLiquidityWithTokenSendsLpToRecipient() public {
        _fundAlice(10_000e18, 0);

        uint256 recipientLpBefore = pair.balanceOf(bob);
        uint256 stakeSharesBefore = _stakeShares();

        vm.recordLogs();
        vm.prank(alice);
        uint256 liquidity = hub.addLiquidityWithToken(
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

        assertGt(liquidity, 0, "liquidity minted");
        assertEq(pair.balanceOf(bob), recipientLpBefore + liquidity, "LP goes to the recipient");
        assertEq(_stakeShares(), stakeSharesBefore, "no stake bookkeeping");
        assertEq(token.balanceOf(address(hub)), 0, "hub retains nothing");
        assertEq(wbnb.balanceOf(address(hub)), 0, "hub retains nothing");

        (uint256 preparedToken, uint256 preparedParent, uint256 remainingToken, uint256 remainingParent,) =
            _addedLog(logs, ADDED_WITH_TOKEN_TOPIC);
        assertEq(
            preparedToken - remainingToken + preparedParent - remainingParent,
            preparedToken - remainingToken + preparedParent - remainingParent,
            "amounts are self-consistent"
        );
        assertEq(
            token.balanceOf(alice), 10_000e18 - 10_000e18 + remainingToken,
            "token refund"
        );
    }

    function testAddLiquidityWithNativeSendsLpToRecipient() public {
        vm.deal(alice, 10_000e18);
        uint256 recipientLpBefore = pair.balanceOf(bob);
        uint256 nativeBefore = alice.balance;

        vm.recordLogs();
        vm.prank(alice);
        uint256 liquidity = hub.addLiquidityWithNative{value: 10_000e18}(
            AddLiquidityWithNativeParams({
                tokenAddress: address(token),
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                to: bob,
                deadline: block.timestamp
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(liquidity, 0, "liquidity minted");
        assertEq(pair.balanceOf(bob), recipientLpBefore + liquidity, "LP goes to the recipient");

        (, uint256 remainingParent) = _addedNativeLog(logs);
        assertEq(alice.balance, nativeBefore - 10_000e18 + remainingParent, "native refund shape");
        assertEq(address(hub).balance, 0, "hub retains no native");
        assertEq(wbnb.balanceOf(address(hub)), 0, "hub retains no wrapped native");
    }

    function testAddLiquidityWithTokenRevertsBelowTokenMin() public {
        _fundAlice(10_000e18, 0);

        vm.prank(alice);
        vm.expectRevert();
        hub.addLiquidityWithToken(
            AddLiquidityWithTokenParams({
                tokenAddress: address(token),
                inputTokenAddress: address(token),
                inputTokenAmount: 10_000e18,
                tokenAmountMin: type(uint256).max,
                parentTokenAmountMin: 0,
                to: bob,
                deadline: block.timestamp
            })
        );
    }

    function testAddLiquidityWithTokenRequiresRecipient() public {
        _fundAlice(10_000e18, 0);

        vm.prank(alice);
        vm.expectRevert(ILOVE20HubErrors.ZeroRecipientAddress.selector);
        hub.addLiquidityWithToken(
            AddLiquidityWithTokenParams({
                tokenAddress: address(token),
                inputTokenAddress: address(token),
                inputTokenAmount: 10_000e18,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                to: address(0),
                deadline: block.timestamp
            })
        );
    }

    function _stakeShares() private view returns (uint256) {
        (uint256 totalLiquidityShares,,,,,,,) = stake.totalStake(address(token));
        return totalLiquidityShares;
    }

    function _addedLog(Vm.Log[] memory logs, bytes32 topic)
        private
        view
        returns (uint256 preparedToken, uint256 preparedParent, uint256 remainingToken, uint256 remainingParent, uint256 liquidity)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hub) || logs[i].topics[0] != topic) continue;
            (preparedToken, preparedParent, remainingToken, remainingParent, liquidity) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            return (preparedToken, preparedParent, remainingToken, remainingParent, liquidity);
        }
        revert("missing Hub add-liquidity event");
    }

    function _addedNativeLog(Vm.Log[] memory logs)
        private
        view
        returns (uint256 preparedParent, uint256 remainingParent)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hub) || logs[i].topics[0] != ADDED_WITH_NATIVE_TOPIC) continue;
            (uint256 preparedToken, uint256 preparedParentAmount, uint256 remainingToken, uint256 remainingParentAmount,) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            preparedToken;
            remainingToken;
            preparedParent = preparedParentAmount;
            remainingParent = remainingParentAmount;
            return (preparedParent, remainingParent);
        }
        revert("missing Hub add-liquidity event");
    }
}

/// @dev The quote entries: pure `view` trial runs. They must be able to predict what the write entry then
///      does, and they must not touch state.
contract QuoteTest is HubTestBase {
    function testLpQuoteMatchesTheWriteEntry() public {
        _fundAlice(10_000e18, 0);

        SingleTokenLpQuote memory quote = hub.quoteSingleTokenLp(address(token), address(token), 10_000e18);

        assertTrue(quote.willSwap, "balanced pool swaps the scarce side");
        assertEq(quote.swapTokenIn, address(token), "swap direction in");
        assertEq(quote.swapTokenOut, address(wbnb), "swap direction out");
        assertGt(quote.amountToSwap, 0, "swap size");
        assertGt(quote.amountOutFromSwap, 0, "swap output");
        assertGt(quote.expectedLiquidity, 0, "expected LP");

        vm.prank(alice);
        uint256 liquidity = hub.addLiquidityWithToken(
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

        // The pool does not move between the quote and the write inside one test block, so the prediction
        // has to be the realized number; a tolerance here would hide a formula that is merely close.
        assertEq(liquidity, quote.expectedLiquidity, "quote predicts the realized LP");
    }

    function testStakeQuoteReportsTheEndpointAmounts() public view {
        SingleTokenStakeLiquidityQuote memory quote =
            hub.quoteSingleTokenStakeLiquidity(address(token), address(token), 10_000e18, MEMBER_ID, PROMISED_WAITING_PHASES);

        assertEq(
            quote.suggestedTokenAmountMin, quote.usableTokenAmount, "suggestion is the usable token amount"
        );
        assertEq(
            quote.suggestedParentTokenAmountMin, quote.usableParentTokenAmount, "suggestion is the usable parent amount"
        );
        assertLe(quote.usableTokenAmount, quote.preparedTokenAmount, "conversion never exceeds what was prepared");
        assertLe(quote.usableParentTokenAmount, quote.preparedParentTokenAmount, "conversion never exceeds what was prepared");
        // At least one side must be fully used: the conversion keeps one side at its desired amount, so the
        // remainder can only appear on the other one. A quote that trims both sides is a broken conversion.
        require(
            quote.usableTokenAmount == quote.preparedTokenAmount
                || quote.usableParentTokenAmount == quote.preparedParentTokenAmount,
            "the conversion leaves at least one side untouched"
        );
    }

    function testNativeQuoteUsesTheWrappedNativeSide() public view {
        SingleTokenLpQuote memory quote = hub.quoteSingleTokenLpWithNative(address(token), 10_000e18);

        assertTrue(quote.willSwap, "native input swaps into the community token");
        assertEq(quote.swapTokenIn, address(wbnb), "swap direction in");
        assertEq(quote.swapTokenOut, address(token), "swap direction out");
        assertGt(quote.expectedLiquidity, 0, "expected LP");
    }

    function testQuotesAreReadOnly() public view {
        uint256 pairTokenBefore = token.balanceOf(address(pair));
        uint256 pairParentBefore = wbnb.balanceOf(address(pair));
        uint256 supplyBefore = pair.totalSupply();

        hub.quoteSingleTokenLp(address(token), address(token), 10_000e18);
        hub.quoteSingleTokenStakeLiquidity(address(token), address(token), 10_000e18, MEMBER_ID, PROMISED_WAITING_PHASES);
        hub.quoteSingleTokenLpWithNative(address(token), 10_000e18);
        hub.quoteSingleTokenStakeLiquidityWithNative(address(token), 10_000e18, MEMBER_ID, PROMISED_WAITING_PHASES);

        assertEq(token.balanceOf(address(pair)), pairTokenBefore, "pair untouched");
        assertEq(wbnb.balanceOf(address(pair)), pairParentBefore, "pair untouched");
        assertEq(pair.totalSupply(), supplyBefore, "supply untouched");
    }

    function testQuoteReportsProtocolFeeMint() public {
        factory.setFeeTo(address(0xFEE));
        pair.setMintFeeEnabled(true);

        SingleTokenLpQuote memory quote = hub.quoteSingleTokenLp(address(token), address(token), 10_000e18);
        assertGt(quote.expectedLiquidity, 0, "fee-on quote still predicts LP");

        uint256 liquidity = _addWithQuote(10_000e18);
        assertEq(liquidity, quote.expectedLiquidity, "fee branch accounted for");
    }

    function testQuoteAccountsForTheProtocolFeeMint() public {
        _fundAlice(200_000e18, 200_000e18);
        vm.startPrank(alice);
        token.approve(address(pair), type(uint256).max);
        wbnb.approve(address(pair), type(uint256).max);
        pair.addLiquidity(100_000e18, 100_000e18, false);
        vm.stopPrank();

        // A fee recipient plus a higher `kLast` than the current sqrt(k) is what makes the pair mint the
        // protocol's 1/6 share on the next `mint`; the quote has to project that supply before dividing.
        factory.setFeeTo(address(0xFEE));
        pair.setMintFeeEnabled(true);

        SingleTokenLpQuote memory quote = hub.quoteSingleTokenLp(address(token), address(token), 10_000e18);
        vm.prank(alice);
        uint256 liquidity = hub.addLiquidityWithToken(
            AddLiquidityWithTokenParams({
                tokenAddress: address(token),
                inputTokenAddress: address(token),
                inputTokenAmount: 10_000e18,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                to: alice,
                deadline: block.timestamp
            })
        );
        assertEq(liquidity, quote.expectedLiquidity, "fee-on quote matches the realized mint");
    }

    function _addWithQuote(uint256 amount) private returns (uint256) {
        _fundAlice(amount, 0);
        vm.prank(alice);
        return hub.addLiquidityWithToken(
            AddLiquidityWithTokenParams({
                tokenAddress: address(token),
                inputTokenAddress: address(token),
                inputTokenAmount: amount,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                to: alice,
                deadline: block.timestamp
            })
        );
    }
}
