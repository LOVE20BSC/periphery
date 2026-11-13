// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "@forge-std/Test.sol";
import {LOVE20Hub} from "../src/LOVE20Hub.sol";
import {
    MockERC20,
    MockWrappedNative,
    MockUniswapV2Pair,
    MockUniswapV2Factory,
    MockUniswapV2Router02,
    MockMemberNFT,
    MockLaunch
} from "./mocks/HubMocks.sol";
import {MockStake} from "./mocks/MockStake.sol";

/// @dev Shared fixture. The factory / pair / router triad uses the real constant-product math so the
///      Hub's swap, conversion and refund paths are exercised against the same arithmetic a deployed
///      Uniswap V2 compatible DEX applies.
abstract contract HubTestBase is Test {
    uint256 internal constant MEMBER_ID = 1;
    uint256 internal constant OTHER_MEMBER_ID = 2;
    uint256 internal constant PROMISED_WAITING_PHASES = 3;
    uint256 internal constant PHASES_MIN = 1;
    uint256 internal constant PHASES_MAX = 100;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    MockWrappedNative internal wbnb;
    MockUniswapV2Factory internal factory;
    MockUniswapV2Router02 internal router;
    MockMemberNFT internal memberNFT;
    MockLaunch internal launch;
    MockStake internal stake;
    LOVE20Hub internal hub;

    MockERC20 internal token;
    MockUniswapV2Pair internal pair;

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        wbnb = new MockWrappedNative();
        factory = new MockUniswapV2Factory();
        router = new MockUniswapV2Router02(address(factory), address(wbnb));
        memberNFT = new MockMemberNFT();
        launch = new MockLaunch();

        stake = new MockStake(
            address(memberNFT),
            address(launch),
            address(router),
            address(factory),
            PHASES_MIN,
            PHASES_MAX
        );

        hub = new LOVE20Hub(address(stake));

        memberNFT.mint(MEMBER_ID, alice);
        memberNFT.mint(OTHER_MEMBER_ID, bob);

        token = new MockERC20("Community Token", "CMT");
        token.setParentTokenAddress(address(wbnb));
        launch.register(address(token), address(wbnb));
        (address token0, address token1) = address(token) < address(wbnb)
            ? (address(token), address(wbnb))
            : (address(wbnb), address(token));
        pair = new MockUniswapV2Pair(token0, token1);
        factory.setPair(address(token), address(wbnb), address(pair));
        stake.setPair(address(token), address(pair));
        stake.setParentToken(address(token), address(wbnb));

        _seed(1_000_000e18, 1_000_000e18);
    }

    /// @dev Adds liquidity to the community pair. Called more than once by the tests that need a skewed
    ///      pool, so the approvals are unlimited rather than sized to the first seed.
    function _seed(uint256 tokenSeed, uint256 parentSeed) internal {
        token.mint(address(this), tokenSeed);
        wbnb.mint(address(this), parentSeed);
        token.approve(address(pair), type(uint256).max);
        wbnb.approve(address(pair), type(uint256).max);
        pair.addLiquidity(tokenSeed, parentSeed, false);
    }

    function _fundAlice(uint256 tokenAmount, uint256 parentAmount) internal {
        if (tokenAmount > 0) {
            token.mint(alice, tokenAmount);
            vm.prank(alice);
            token.approve(address(hub), tokenAmount);
        }
        if (parentAmount > 0) {
            wbnb.mint(alice, parentAmount);
            vm.prank(alice);
            wbnb.approve(address(hub), parentAmount);
        }
    }

    function _parentOf(address) internal view returns (address) {
        return address(wbnb);
    }
}
