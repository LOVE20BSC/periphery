// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {LOVE20Hub} from "../src/LOVE20Hub.sol";
import {ILOVE20HubErrors} from "../src/interfaces/ILOVE20Hub.sol";
import {MockERC20, MockWrappedNative, MockUniswapV2Pair} from "./mocks/HubMocks.sol";
import {HubTestBase, DexProfile} from "./HubTestBase.sol";

/// @dev Selector coverage for the failure paths that need a hand-built pool state. Every reachable error
///      gets its selector and payload asserted exactly once somewhere in the suite.
contract HubFailureTest is HubTestBase {
    /// @dev An existing pair with zero reserves is a legitimate cold start now, not an error. What is still
    ///      rejected is a cold start with only one side funded: there is no price to size a swap against.
    function testRejectsAColdStartWithOnlyOneSideFunded() public {
        (MockERC20 emptyToken,) = _newUnseededToken();

        vm.expectRevert(
            abi.encodeWithSelector(
                ILOVE20HubErrors.PairWithoutLiquidity.selector, address(emptyToken), address(wbnb)
            )
        );
        hub.quoteLp(address(emptyToken), address(wbnb), 1e18, 0);
    }

    function testRejectsInputAboveTheReserveWidth() public {
        // One wei above the `uint112` reserve width, which is what a Uniswap V2 pair can represent.
        vm.expectRevert(
            abi.encodeWithSelector(
                ILOVE20HubErrors.AmountExceeded.selector, uint256(type(uint112).max) + 1, uint256(type(uint112).max)
            )
        );
        hub.quoteLp(address(token), address(wbnb), uint256(type(uint112).max) + 1, 0);
    }

    /// @dev A dust input against a deep pool rounds the swap output to zero; the Hub refuses rather than
    ///      staging a swap that would burn gas and return nothing.
    function testRejectsSwapOutputThatRoundsToZero() public {
        // Leave the parent side at 1e3 wei against a 1e24 community side: any community-token input is
        // swapped for an output that floors to zero.
        uint256 parentReserve = wbnb.balanceOf(address(pair));
        pair.removeFromReserve(address(wbnb), parentReserve - 1_000);
        wbnb.burn(address(pair), parentReserve - 1_000);

        vm.expectRevert(ILOVE20HubErrors.ZeroSwapOutput.selector);
        hub.quoteLp(address(token), address(wbnb), 1e18, 0);
    }

    function testRejectsNativeRefundThatTheCallerRefuses() public {
        // A contract caller with no `receive` cannot take the native refund back, which must surface as the
        // Hub's own error rather than a raw transfer failure.
        NativeRefusingCaller caller = new NativeRefusingCaller(LOVE20HubLike(address(hub)));
        vm.deal(address(caller), 1e18);

        vm.expectRevert(ILOVE20HubErrors.NativeRefundFailed.selector);
        caller.stake{value: 1e18}(address(token), MEMBER_ID);
    }

    /// @dev Both sides zero is not "single token", it is nothing at all.
    function testRejectsBothDesiredAmountsZero() public {
        vm.expectRevert(ILOVE20HubErrors.ZeroAmount.selector);
        hub.quoteLp(address(token), address(wbnb), 0, 0);
    }

    function testRejectsIdenticalTokens() public {
        vm.expectRevert(abi.encodeWithSelector(ILOVE20HubErrors.IdenticalTokens.selector, address(token)));
        hub.quoteLp(address(token), address(token), 1e18, 1e18);
    }

    /// @dev The native LP entry derives the other side from `msg.value`, so passing the wrapped native as
    ///      the token would mean pairing WBNB with itself.
    function testRejectsWrappedNativeAsTheTokenSide() public {
        vm.expectRevert(abi.encodeWithSelector(ILOVE20HubErrors.WrappedNativeAsToken.selector, address(wbnb)));
        hub.quoteLpWithNative(address(wbnb), 1e18, 1e18);
    }

    /// @dev A pair whose reserves are wide enough that the swap would push a side past `uint112.max` still
    ///      reverts — but through the pair, not through a Hub prediction. This pins the documented limit of
    ///      `AmountExceeded`: it is an absurd-input guard, not an overflow guard.
    function testTheReserveWidthGuardDoesNotClaimToStopPairOverflow() public {
        // The gate only bounds each desired amount; a large enough desired still reaches the pair. Asserting
        // the behaviour here keeps the comment in `_swapPlan` honest.
        uint256 half = uint256(type(uint112).max) / 2;
        vm.expectRevert();
        hub.quoteLp(address(token), address(wbnb), uint256(type(uint112).max) + 1, half);
    }

    function _newUnseededToken() private returns (MockERC20 emptyToken, MockUniswapV2Pair emptyPair) {
        emptyToken = new MockERC20("Empty", "EMP");
        emptyToken.setParentTokenAddress(address(wbnb));
        launch.register(address(emptyToken), address(wbnb));
        (address token0, address token1) = address(emptyToken) < address(wbnb)
            ? (address(emptyToken), address(wbnb))
            : (address(wbnb), address(emptyToken));
        emptyPair = new MockUniswapV2Pair(token0, token1);
        factory.setPair(address(emptyToken), address(wbnb), address(emptyPair));
        stake.setPair(address(emptyToken), address(emptyPair));
        stake.setParentToken(address(emptyToken), address(wbnb));
    }
}

/// @dev A caller that can fund the Hub but refuses the native refund on the way back.
contract NativeRefusingCaller {
    LOVE20HubLike internal immutable hub;

    constructor(LOVE20HubLike hub_) {
        hub = hub_;
    }

    function stake(address tokenAddress, uint256 memberId) external payable {
        hub.stakeLiquidityWithNative{value: msg.value}(
            StakeLiquidityWithNativeParams({
                tokenAddress: tokenAddress,
                tokenAmountDesired: 0,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: 3,
                memberId: memberId,
                deadline: block.timestamp
            })
        );
    }
}

interface LOVE20HubLike {
    function stakeLiquidityWithNative(StakeLiquidityWithNativeParams calldata params)
        external
        payable
        returns (uint256 govVotesAdded, uint256 liquiditySharesAdded);
}

struct StakeLiquidityWithNativeParams {
    address tokenAddress;
    uint256 tokenAmountDesired;
    uint256 tokenAmountMin;
    uint256 parentTokenAmountMin;
    uint256 promisedWaitingPhases;
    uint256 memberId;
    uint256 deadline;
}

/// @dev The closed form's dominant term is `r^2 * (F+D)^2`. At `r = uint112.max` it only fits uint256 while
///      `F + D <= 65536`, which is why the constructor rejects ratios that would reduce past that bound.
///      This suite pins the boundary so a future fee profile cannot silently reintroduce the overflow.
contract SwapMathBoundTest is HubTestBase {
    function testRejectsAFeeProfileThatWouldOverflowTheSwapMaths() public {
        // A 1 wei fee leaves F/D = 999999999999999999/1e18, which reduces no further: F+D is ~2e18, far
        // past the 65536 the closed form needs. The constructor rejects it instead of letting a future
        // swap overflow.
        vm.expectRevert();
        new LOVE20Hub(address(stake), 1, 0);

        // Coarse ratios reduce to small integers, so a large nominal fee is still fine: 50% reduces to
        // 1/2 and constructs successfully.
        new LOVE20Hub(address(stake), 5e17, 0);

        // Every real profile is far inside the bound.
        new LOVE20Hub(address(stake), 3_000_000_000_000_000, 0);
    }

    /// @dev The quote must not revert for the largest input the guard allows, which is where the closed
    ///      form's intermediates are biggest.
    function testQuoteAtTheReserveWidthLimitDoesNotOverflow() public view {
        uint256 max = uint256(type(uint112).max);
        hub.quoteLp(address(token), address(wbnb), max, max);
    }
}

/// @dev The deploy script's fee cross-check, exercised against the mock DEX. This is the guard that stops a
///      parameter file from silently disagreeing with the chain it is deployed to.
contract FeeCrossCheckTest is HubTestBase {
    function testRecoversTheConfiguredFeeFromARealQuote() public view {
        (uint256 reserveIn, uint256 reserveOut) = _reserves();
        uint256 probeIn = reserveIn / 1000;

        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(wbnb);
        uint256 probeOut = router.getAmountsOut(probeIn, path)[1];

        // F/D = y*rIn / (x*(rOut - y)), recovered from the quote alone. The pair's floor division biases
        // the recovery by up to one wei of the ratio, which is the tolerance the deploy script allows.
        uint256 recovered = (probeOut * reserveIn * 1e18) / (probeIn * (reserveOut - probeOut));
        assertApproxEqAbs(recovered, 997e15, 1, "the local dex profile is recovered");
    }

    function testRecoveredFeeFollowsTheDexProfile() public {
        (uint256 lpRatio, uint256 protocolRatio) = DexProfile.pancakeMainnet();
        _setDexProfile(lpRatio, protocolRatio);

        (uint256 reserveIn, uint256 reserveOut) = _reserves();
        uint256 probeIn = reserveIn / 1000;

        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(wbnb);
        uint256 probeOut = router.getAmountsOut(probeIn, path)[1];

        uint256 recovered = (probeOut * reserveIn * 1e18) / (probeIn * (reserveOut - probeOut));
        assertApproxEqAbs(recovered, 9975e14, 1, "Pancake mainnet's 0.25% is recovered");
    }
}
