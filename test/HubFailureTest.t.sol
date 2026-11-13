// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ILOVE20HubErrors} from "../src/interfaces/ILOVE20Hub.sol";
import {MockERC20, MockWrappedNative, MockUniswapV2Pair} from "./mocks/HubMocks.sol";
import {HubTestBase} from "./HubTestBase.sol";

/// @dev Selector coverage for the failure paths that need a hand-built pool state. Every reachable error
///      gets its selector and payload asserted exactly once somewhere in the suite.
contract HubFailureTest is HubTestBase {
    function testRejectsEmptyPair() public {
        (MockERC20 emptyToken,) = _newUnseededToken();
        vm.expectRevert(abi.encodeWithSelector(ILOVE20HubErrors.PairEmpty.selector, address(emptyToken)));
        hub.quoteSingleTokenLp(address(emptyToken), address(emptyToken), 1e18);
    }

    function testRejectsInputAboveTheReserveWidth() public {
        // One wei above the `uint112` reserve width, which is what a Uniswap V2 pair can represent.
        vm.expectRevert(
            abi.encodeWithSelector(
                ILOVE20HubErrors.AmountExceeded.selector, uint256(type(uint112).max) + 1, uint256(type(uint112).max)
            )
        );
        hub.quoteSingleTokenLp(address(token), address(token), uint256(type(uint112).max) + 1);
    }

    /// @dev A dust input against a deep pool rounds the swap output to zero; the Hub refuses rather than
    ///      staging a swap that would burn gas and return nothing.
    function testRejectsSwapOutputThatRoundsToZero() public {
        // A pool whose parent side is dust relative to the community side: the swap consumes the whole
        // input for an output that floors to zero. The Hub refuses rather than staging a swap that returns
        // nothing.
        // Leave the parent side at 1e3 wei against a 1e24 community side: any community-token input is
        // swapped for an output that floors to zero.
        uint256 parentReserve = wbnb.balanceOf(address(pair));
        pair.removeFromReserve(address(wbnb), parentReserve - 1_000);
        wbnb.burn(address(pair), parentReserve - 1_000);

        vm.expectRevert(ILOVE20HubErrors.ZeroSwapOutput.selector);
        hub.quoteSingleTokenLp(address(token), address(token), 1e18);
    }

    /// @dev After the swap the pool is balanced, so the conversion uses both sides; an input so small that
    ///      it cannot even fund one wei on each side is rejected instead of silently depositing nothing.

    function testRejectsNativeRefundThatTheCallerRefuses() public {
        // A contract caller with no `receive` cannot take the native refund back, which must surface as the
        // Hub's own error rather than a raw transfer failure.
        NativeRefusingCaller caller = new NativeRefusingCaller(LOVE20HubLike(address(hub)));
        vm.deal(address(caller), 1e18);

        vm.expectRevert(ILOVE20HubErrors.NativeRefundFailed.selector);
        caller.stake{value: 1e18}(address(token), MEMBER_ID);
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
    uint256 tokenAmountMin;
    uint256 parentTokenAmountMin;
    uint256 promisedWaitingPhases;
    uint256 memberId;
    uint256 deadline;
}
