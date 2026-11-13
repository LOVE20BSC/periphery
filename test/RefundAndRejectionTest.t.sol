// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ILOVE20HubErrors} from "../src/interfaces/ILOVE20Hub.sol";
import {
    StakeLiquidityWithTokenParams,
    StakeLiquidityWithNativeParams,
    AddLiquidityWithTokenParams,
    AddLiquidityWithNativeParams
} from "../src/interfaces/ILOVE20Hub.sol";
import {MockERC20, MockWrappedNative} from "./mocks/HubMocks.sol";
import {HubTestBase} from "./HubTestBase.sol";

/// @dev Refund shape and the failure contract. The refund form is decided by the entry point alone (ERC20
///      path returns ERC20, native path returns native), never by an argument, so these cases assert the
///      two branches separately and check that the Hub never keeps a balance.
contract RefundAndRejectionTest is HubTestBase {
    function testTokenRefundReturnsErc20WhenTheRatioIsOff() public {
        // Skew the pool so a single-sided input cannot be converted in full: the leftover must come back
        // as the same ERC20 the caller paid with.
        _seed(500_000e18, 500_000e18);
        _fundAlice(10_000e18, 0);
        uint256 before = token.balanceOf(alice);

        vm.prank(alice);
        hub.addLiquidityWithToken(
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

        assertLe(token.balanceOf(alice), before, "only the refund comes back");
        assertEq(token.balanceOf(address(hub)), 0, "hub retains no community token");
        assertEq(wbnb.balanceOf(address(hub)), 0, "hub retains no wrapped native");
    }

    function testNativeRefundReturnsNativeNeverWrapped() public {
        vm.deal(alice, 10_000e18);

        vm.prank(alice);
        hub.addLiquidityWithNative{value: 10_000e18}(
            AddLiquidityWithNativeParams({
                tokenAddress: address(token),
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                to: alice,
                deadline: block.timestamp
            })
        );

        // Nothing may be left in either form: the wrapped remainder is unwrapped and forwarded.
        assertEq(wbnb.balanceOf(alice), 0, "no wrapped native is returned");
        assertEq(wbnb.balanceOf(address(hub)), 0, "hub holds no wrapped native");
        assertEq(address(hub).balance, 0, "hub holds no native");
    }

    function testNativeRefundRejectsTheWrongSenderOnReceive() public {
        vm.deal(address(this), 1e18);
        vm.prank(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(ILOVE20HubErrors.NativeTokenSenderRejected.selector, address(0xDEAD))
        );
        (bool success,) = address(hub).call{value: 1}("");
        success;
    }

    function testRejectsZeroTokenAddress() public {
        vm.expectRevert(ILOVE20HubErrors.ZeroTokenAddress.selector);
        hub.quoteSingleTokenLp(address(0), address(token), 1e18);
    }

    function testRejectsZeroInputTokenAddress() public {
        vm.expectRevert(ILOVE20HubErrors.ZeroInputTokenAddress.selector);
        hub.quoteSingleTokenLp(address(token), address(0), 1e18);
    }

    function testRejectsZeroInputTokenAmount() public {
        vm.expectRevert(ILOVE20HubErrors.ZeroInputTokenAmount.selector);
        hub.quoteSingleTokenLp(address(token), address(token), 0);
    }

    function testRejectsZeroNativeAmount() public {
        vm.expectRevert(ILOVE20HubErrors.ZeroNativeTokenAmount.selector);
        hub.quoteSingleTokenLpWithNative(address(token), 0);
    }

    function testRejectsExpiredDeadline() public {
        vm.expectRevert(
            abi.encodeWithSelector(ILOVE20HubErrors.DeadlineExpired.selector, block.timestamp, block.timestamp - 1)
        );
        vm.prank(alice);
        hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                inputTokenAddress: address(token),
                inputTokenAmount: 1e18,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp - 1
            })
        );
    }

    function testRejectsUnregisteredToken() public {
        MockERC20 stranger = new MockERC20("Stranger", "STR");
        stranger.setParentTokenAddress(address(wbnb));
        vm.expectRevert(abi.encodeWithSelector(ILOVE20HubErrors.TokenNotRegistered.selector, address(stranger)));
        hub.quoteSingleTokenLp(address(stranger), address(stranger), 1e18);
    }

    function testRejectsMissingMemberId() public {
        _fundAlice(10_000e18, 0);
        vm.prank(alice);
        vm.expectRevert();
        hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                inputTokenAddress: address(token),
                inputTokenAmount: 10_000e18,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: 999,
                deadline: block.timestamp
            })
        );
    }

    function testRejectsInputTokenOutsideThePair() public {
        MockERC20 stranger = new MockERC20("Stranger", "STR");
        vm.expectRevert(
            abi.encodeWithSelector(ILOVE20HubErrors.InvalidInputTokenAddress.selector, address(stranger))
        );
        vm.prank(alice);
        hub.stakeLiquidityWithToken(
            StakeLiquidityWithTokenParams({
                tokenAddress: address(token),
                inputTokenAddress: address(stranger),
                inputTokenAmount: 1e18,
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp
            })
        );
    }

    function testNativeEntryRejectsATokenWhoseParentIsNotWrappedNative() public {
        MockERC20 otherParent = new MockERC20("Other Parent", "OTP");
        MockERC20 child = new MockERC20("Child", "CHD");
        child.setParentTokenAddress(address(otherParent));
        launch.register(address(child), address(otherParent));

        vm.deal(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ILOVE20HubErrors.NativeInputUnsupported.selector, address(otherParent))
        );
        hub.stakeLiquidityWithNative{value: 1e18}(
            StakeLiquidityWithNativeParams({
                tokenAddress: address(child),
                tokenAmountMin: 0,
                parentTokenAmountMin: 0,
                promisedWaitingPhases: PROMISED_WAITING_PHASES,
                memberId: MEMBER_ID,
                deadline: block.timestamp
            })
        );
    }

    function testRejectsMissingPair() public {
        MockERC20 lonely = new MockERC20("Lonely", "LON");
        lonely.setParentTokenAddress(address(wbnb));
        launch.register(address(lonely), address(wbnb));

        vm.expectRevert(abi.encodeWithSelector(ILOVE20HubErrors.PairMissing.selector, address(lonely)));
        hub.quoteSingleTokenLp(address(lonely), address(lonely), 1e18);
    }
}
