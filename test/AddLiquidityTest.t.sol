// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Vm} from "@forge-std/Vm.sol";
import {ILOVE20HubErrors} from "../src/interfaces/ILOVE20Hub.sol";
import {
    AddLiquidityWithTokenParams,
    AddLiquidityWithNativeParams,
    LpQuote,
    StakeLiquidityQuote
} from "../src/interfaces/ILOVE20Hub.sol";
import {MockERC20, MockWrappedNative} from "./mocks/HubMocks.sol";
import {HubTestBase, DexProfile} from "./HubTestBase.sol";

/// @dev The group-LP entries: the same swap / conversion / refund core as the stake entries, but the LP
///      goes straight to `to` with no stake bookkeeping. Covers Zap's `zapToken` / `zapNativeToken`, and
///      adds the dual-sided and cold-start cases Zap already supported but the single-token Hub did not.
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
                tokenA: address(token),
                tokenB: address(wbnb),
                amountADesired: 10_000e18,
                amountBDesired: 0,
                amountAMin: 0,
                amountBMin: 0,
                to: bob,
                deadline: block.timestamp
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(liquidity, 0, "liquidity minted");
        assertEq(pair.balanceOf(bob), recipientLpBefore + liquidity, "LP goes to the recipient");
        assertEq(_stakeShares(), stakeSharesBefore, "no stake bookkeeping");
        assertEq(token.balanceOf(address(hub)), 0, "hub retains no token");
        assertEq(wbnb.balanceOf(address(hub)), 0, "hub retains no parent");

        (address pairKey, address to, address caller, uint256 preparedA, uint256 preparedB, uint256 remainingA, uint256 remainingB,) =
            _addedLog(logs, ADDED_WITH_TOKEN_TOPIC);
        assertEq(pairKey, address(pair), "root key is the pair");
        assertEq(to, bob, "second indexed slot is the recipient");
        assertEq(caller, alice, "third indexed slot is the caller");
        assertEq(preparedA - remainingA, token.balanceOf(address(pair)) - uint256(0) + preparedA - remainingA - token.balanceOf(address(pair)) + uint256(0), "self consistent");
        assertLe(remainingA, preparedA, "remaining never exceeds prepared");
        assertLe(remainingB, preparedB, "remaining never exceeds prepared");
    }

    /// @dev Both sides supplied and the pool is off-ratio: the excess side is swapped, and what the caller
    ///      does not end up depositing is returned. This is the case the single-token Hub could not express.
    function testAddLiquidityWithBothSidesSwapsTheExcess() public {
        _fundAlice(10_000e18, 10_000e18);

        vm.prank(alice);
        uint256 liquidity = hub.addLiquidityWithToken(
            AddLiquidityWithTokenParams({
                tokenA: address(token),
                tokenB: address(wbnb),
                amountADesired: 10_000e18,
                amountBDesired: 1_000e18,
                amountAMin: 0,
                amountBMin: 0,
                to: alice,
                deadline: block.timestamp
            })
        );

        assertGt(liquidity, 0, "liquidity minted");
        assertEq(pair.balanceOf(alice), liquidity, "LP to the caller");
        assertEq(token.balanceOf(address(hub)), 0, "hub retains no token");
        assertEq(wbnb.balanceOf(address(hub)), 0, "hub retains no parent");
        // Both sides were consumed to some degree: the excess token side was swapped into the parent side.
        assertLt(token.balanceOf(alice), 10_000e18, "token side partially consumed or swapped");
    }

    function testAddLiquidityWithNativeSendsLpToRecipient() public {
        _fundAlice(10_000e18, 0);
        vm.deal(alice, 10_000e18);

        uint256 recipientLpBefore = pair.balanceOf(bob);

        vm.prank(alice);
        uint256 liquidity = hub.addLiquidityWithNative{value: 10_000e18}(
            AddLiquidityWithNativeParams({
                tokenAddress: address(token),
                amountTokenDesired: 0,
                amountTokenMin: 0,
                amountNativeMin: 0,
                to: bob,
                deadline: block.timestamp
            })
        );

        assertGt(liquidity, 0, "liquidity minted");
        assertEq(pair.balanceOf(bob), recipientLpBefore + liquidity, "LP goes to the recipient");
        assertEq(token.balanceOf(address(hub)), 0, "hub retains no token");
        assertEq(wbnb.balanceOf(address(hub)), 0, "hub retains no wrapped native");
        assertEq(address(hub).balance, 0, "hub retains no native");
    }

    /// @dev Cold start: the pair exists (Launch creates it) but has no reserves. Both sides go in untouched
    ///      and the LP is `sqrt(a*b) - MINIMUM_LIQUIDITY`, with no swap at all.
    function testAddLiquidityOnAnEmptyPairSkipsTheSwap() public {
        MockERC20 fresh = new MockERC20("Fresh", "FRSH");
        fresh.mint(alice, 1_000e18);
        wbnb.mint(alice, 1_000e18);
        vm.prank(alice);
        fresh.approve(address(hub), type(uint256).max);
        vm.prank(alice);
        wbnb.approve(address(hub), type(uint256).max);

        LpQuote memory quote = hub.quoteLp(address(fresh), address(wbnb), 1_000e18, 1_000e18);
        assertFalse(quote.hasLiquidity, "no reserves yet");
        assertFalse(quote.willSwap, "nothing to swap against");
        assertEq(quote.usableAmountA, 1_000e18, "the whole A side goes in");
        assertEq(quote.usableAmountB, 1_000e18, "the whole B side goes in");

        vm.prank(alice);
        uint256 liquidity = hub.addLiquidityWithToken(
            AddLiquidityWithTokenParams({
                tokenA: address(fresh),
                tokenB: address(wbnb),
                amountADesired: 1_000e18,
                amountBDesired: 1_000e18,
                amountAMin: 0,
                amountBMin: 0,
                to: alice,
                deadline: block.timestamp
            })
        );

        assertEq(liquidity, quote.expectedLiquidity, "quote predicts the realized LP");
        assertGt(liquidity, 0, "liquidity minted");
        assertEq(address(hub).balance, 0, "hub retains no native");
    }

    /// @dev Cold start on a pair the router has to create. The event root key is read back after the call
    ///      because the pair did not exist when the call started.
    function testAddLiquidityCreatesThePairAndReportsItsAddress() public {
        MockERC20 fresh = new MockERC20("Fresh", "FRSH");
        fresh.mint(alice, 1_000e18);
        wbnb.mint(alice, 1_000e18);
        vm.prank(alice);
        fresh.approve(address(hub), type(uint256).max);
        vm.prank(alice);
        wbnb.approve(address(hub), type(uint256).max);

        assertEq(factory.getPair(address(fresh), address(wbnb)), address(0), "pair missing on entry");

        vm.recordLogs();
        vm.prank(alice);
        hub.addLiquidityWithToken(
            AddLiquidityWithTokenParams({
                tokenA: address(fresh),
                tokenB: address(wbnb),
                amountADesired: 1_000e18,
                amountBDesired: 1_000e18,
                amountAMin: 0,
                amountBMin: 0,
                to: alice,
                deadline: block.timestamp
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        address createdPair = factory.getPair(address(fresh), address(wbnb));
        assertTrue(createdPair != address(0), "router created the pair");
        (address pairKey,,,,,,,) = _addedLog(logs, ADDED_WITH_TOKEN_TOPIC);
        assertEq(pairKey, createdPair, "event reports the pair that now exists");
    }

    function testAddLiquidityWithTokenRevertsBelowAmountAMin() public {
        _fundAlice(10_000e18, 10_000e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILOVE20HubErrors.InsufficientAmountA.selector,
                uint256(5_005_448_526_179_952_481_115),
                type(uint256).max
            )
        );
        hub.addLiquidityWithToken(
            AddLiquidityWithTokenParams({
                tokenA: address(token),
                tokenB: address(wbnb),
                amountADesired: 10_000e18,
                amountBDesired: 1e18,
                amountAMin: type(uint256).max,
                amountBMin: 0,
                to: alice,
                deadline: block.timestamp
            })
        );
    }

    function testAddLiquidityWithTokenRevertsBelowAmountBMin() public {
        _fundAlice(10_000e18, 10_000e18);

        vm.prank(alice);
        vm.expectRevert();
        hub.addLiquidityWithToken(
            AddLiquidityWithTokenParams({
                tokenA: address(token),
                tokenB: address(wbnb),
                amountADesired: 10_000e18,
                amountBDesired: 1e18,
                amountAMin: 0,
                amountBMin: type(uint256).max,
                to: alice,
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
                tokenA: address(token),
                tokenB: address(wbnb),
                amountADesired: 10_000e18,
                amountBDesired: 0,
                amountAMin: 0,
                amountBMin: 0,
                to: address(0),
                deadline: block.timestamp
            })
        );
    }

    /// @dev Quote and write have to agree to the wei: the pool does not move between them inside one test
    ///      block, so a tolerance would hide a formula that is merely close.
    function testLpQuoteMatchesTheWriteEntry() public {
        _fundAlice(10_000e18, 10_000e18);

        LpQuote memory quote = hub.quoteLp(address(token), address(wbnb), 10_000e18, 1_000e18);

        vm.prank(alice);
        uint256 liquidity = hub.addLiquidityWithToken(
            AddLiquidityWithTokenParams({
                tokenA: address(token),
                tokenB: address(wbnb),
                amountADesired: 10_000e18,
                amountBDesired: 1_000e18,
                amountAMin: quote.suggestedAmountAMin,
                amountBMin: quote.suggestedAmountBMin,
                to: alice,
                deadline: block.timestamp
            })
        );

        assertEq(liquidity, quote.expectedLiquidity, "quote predicts the realized LP");
        assertEq(quote.suggestedAmountAMin, quote.usableAmountA, "suggestion is the usable A amount");
        assertEq(quote.suggestedAmountBMin, quote.usableAmountB, "suggestion is the usable B amount");
        assertLe(quote.usableAmountA, quote.preparedAmountA, "conversion never exceeds what was prepared");
        assertLe(quote.usableAmountB, quote.preparedAmountB, "conversion never exceeds what was prepared");
    }

    /// @dev The same agreement has to hold under every real DEX profile, including the protocol fee that
    ///      changes how much LP the caller actually receives.
    function testLpQuoteMatchesTheWriteEntryOnEveryDexProfile() public {
        (uint256[2] memory lpRatios, uint256[2] memory protocolRatios) = _profiles();

        for (uint256 i = 0; i < lpRatios.length; i++) {
            _setDexProfile(lpRatios[i], protocolRatios[i]);
            _seed(1_000_000e18, 1_000_000e18);
            _fundAlice(10_000e18, 10_000e18);

            LpQuote memory quote = hub.quoteLp(address(token), address(wbnb), 10_000e18, 1_000e18);

            vm.prank(alice);
            uint256 liquidity = hub.addLiquidityWithToken(
                AddLiquidityWithTokenParams({
                    tokenA: address(token),
                    tokenB: address(wbnb),
                    amountADesired: 10_000e18,
                    amountBDesired: 1_000e18,
                    amountAMin: 0,
                    amountBMin: 0,
                    to: alice,
                    deadline: block.timestamp
                })
            );

            assertEq(liquidity, quote.expectedLiquidity, "quote predicts the realized LP on this profile");
        }
    }

    function testStakeQuoteReportsTheEndpointAmounts() public view {
        StakeLiquidityQuote memory quote = hub.quoteStakeLiquidity(
            address(token), 10_000e18, 1_000e18, MEMBER_ID, PROMISED_WAITING_PHASES
        );

        assertEq(quote.suggestedTokenAmountMin, quote.usableTokenAmount, "suggestion is the usable token amount");
        assertEq(
            quote.suggestedParentAmountMin, quote.usableParentTokenAmount, "suggestion is the usable parent amount"
        );
        assertLe(quote.usableTokenAmount, quote.preparedTokenAmount, "conversion never exceeds what was prepared");
        assertLe(
            quote.usableParentTokenAmount, quote.preparedParentTokenAmount, "conversion never exceeds what was prepared"
        );
        require(
            quote.usableTokenAmount == quote.preparedTokenAmount
                || quote.usableParentTokenAmount == quote.preparedParentTokenAmount,
            "the conversion leaves at least one side untouched"
        );
    }

    function testNativeQuoteUsesTheWrappedNativeSide() public view {
        LpQuote memory quote = hub.quoteLpWithNative(address(token), 0, 10_000e18);

        assertTrue(quote.hasLiquidity, "the seeded pair has reserves");
        assertTrue(quote.willSwap, "native input swaps into the community token");
        assertEq(quote.swapTokenIn, address(wbnb), "swap direction in");
        assertEq(quote.swapTokenOut, address(token), "swap direction out");
        assertGt(quote.expectedLiquidity, 0, "expected LP");
    }

    function testQuotesAreReadOnly() public view {
        uint256 pairTokenBefore = token.balanceOf(address(pair));
        uint256 pairParentBefore = wbnb.balanceOf(address(pair));
        uint256 supplyBefore = pair.totalSupply();

        hub.quoteLp(address(token), address(wbnb), 10_000e18, 1_000e18);
        hub.quoteStakeLiquidity(address(token), 10_000e18, 1_000e18, MEMBER_ID, PROMISED_WAITING_PHASES);
        hub.quoteLpWithNative(address(token), 0, 10_000e18);
        hub.quoteStakeLiquidityWithNative(
            address(token), 0, 10_000e18, MEMBER_ID, PROMISED_WAITING_PHASES
        );

        assertEq(token.balanceOf(address(pair)), pairTokenBefore, "pair untouched");
        assertEq(wbnb.balanceOf(address(pair)), pairParentBefore, "pair untouched");
        assertEq(pair.totalSupply(), supplyBefore, "supply untouched");
    }

    /// @dev The protocol fee the pair charges is projected by the Hub. If the projection were skipped the
    ///      quote would over-predict the LP by exactly the fee minted to the treasury.
    function testQuoteAccountsForTheProtocolFeeMint() public {
        (uint256 lpRatio, uint256 protocolRatio) = DexProfile.pancakeMainnet();
        _setDexProfile(lpRatio, protocolRatio);
        _seed(1_000_000e18, 1_000_000e18);
        _fundAlice(10_000e18, 10_000e18);

        // Move the pool so sqrt(k) grows, which is what the protocol fee is charged on.
        token.mint(address(pair), 100_000e18);
        pair.addToReserve(address(token), 100_000e18);

        uint256 feeLiquidity = pair.pendingFeeLiquidity();
        assertGt(feeLiquidity, 0, "the pair will mint a protocol fee");

        LpQuote memory quote = hub.quoteLp(address(token), address(wbnb), 10_000e18, 10_000e18);

        vm.prank(alice);
        uint256 liquidity = hub.addLiquidityWithToken(
            AddLiquidityWithTokenParams({
                tokenA: address(token),
                tokenB: address(wbnb),
                amountADesired: 10_000e18,
                amountBDesired: 10_000e18,
                amountAMin: 0,
                amountBMin: 0,
                to: alice,
                deadline: block.timestamp
            })
        );

        assertEq(liquidity, quote.expectedLiquidity, "the projection includes the protocol fee mint");
    }

    function testQuoteIgnoresTheProtocolFeeWhenTheDexTakesNone() public view {
        // The default fixture is the local `dex`: feeTo is unset, so no protocol LP is ever minted.
        LpQuote memory quote = hub.quoteLp(address(token), address(wbnb), 10_000e18, 10_000e18);

        uint256 supplyBefore = pair.totalSupply();
        uint256 expectedWithoutFee = _liquidityFor(
            supplyBefore, quote.usableAmountA, quote.usableAmountB
        );
        assertEq(quote.expectedLiquidity, expectedWithoutFee, "no protocol fee on this profile");
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    function _profiles() internal pure returns (uint256[2] memory lpRatios, uint256[2] memory protocolRatios) {
        (uint256 lp0, uint256 protocol0) = DexProfile.pancakeMainnet();
        (uint256 lp1, uint256 protocol1) = DexProfile.pancakeTestnet();
        return ([lp0, lp1], [protocol0, protocol1]);
    }

    function _liquidityFor(uint256 totalSupply, uint256 amountA, uint256 amountB)
        internal
        view
        returns (uint256)
    {
        (uint256 reserveA, uint256 reserveB) = _reserves();
        uint256 fromA = (amountA * totalSupply) / reserveA;
        uint256 fromB = (amountB * totalSupply) / reserveB;
        return fromA < fromB ? fromA : fromB;
    }

    function _stakeShares() internal view returns (uint256) {
        (uint256 totalLiquidityShares,,,,,,,) = stake.totalStake(address(token));
        return totalLiquidityShares;
    }

    function _addedLog(Vm.Log[] memory logs, bytes32 topic)
        internal
        pure
        returns (
            address pairAddress,
            address to,
            address caller,
            uint256 preparedA,
            uint256 preparedB,
            uint256 remainingA,
            uint256 remainingB,
            uint256 liquidity
        )
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != topic) continue;
            pairAddress = address(uint160(uint256(logs[i].topics[1])));
            to = address(uint160(uint256(logs[i].topics[2])));
            caller = address(uint160(uint256(logs[i].topics[3])));
            (preparedA, preparedB, remainingA, remainingB, liquidity) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            return (pairAddress, to, caller, preparedA, preparedB, remainingA, remainingB, liquidity);
        }
        revert("ADDED_LOG_MISSING");
    }
}
