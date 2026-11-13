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

/// @dev The three real DEX profiles, as `(swap fee for LP, swap fee for protocol)` in 1e18 units. The pair
///      and the router are configured from the same numbers, so the Hub's configured fee and the pool's
///      actual behaviour can never drift apart by accident — only deliberately, in the tests that check
///      what happens when a deployment is configured wrong.
library DexProfile {
    /// @dev The local `dex` repository: 0.30% swap fee, protocol fee permanently off.
    function localDex() internal pure returns (uint256 lp, uint256 protocol) {
        return (3_000_000_000_000_000, 0);
    }

    /// @dev Uniswap V2: 0.30% swap fee, 1/6 of sqrt(k) growth to the protocol (0.05% of 0.30%).
    function uniswapV2() internal pure returns (uint256 lp, uint256 protocol) {
        return (2_500_000_000_000_000, 500_000_000_000_000);
    }

    /// @dev PancakeSwap V2 mainnet: 0.25% total, 0.17% to LPs and 0.08% to the protocol.
    function pancakeMainnet() internal pure returns (uint256 lp, uint256 protocol) {
        return (1_700_000_000_000_000, 800_000_000_000_000);
    }

    /// @dev PancakeSwap V2 testnet: 0.20% total, 0.15% to LPs and 0.05% to the protocol.
    function pancakeTestnet() internal pure returns (uint256 lp, uint256 protocol) {
        return (1_500_000_000_000_000, 500_000_000_000_000);
    }
}

/// @dev Shared fixture. The factory / pair / router triad uses the real constant-product math so the
///      Hub's swap, conversion and refund paths are exercised against the same arithmetic a deployed
///      Uniswap V2 compatible DEX applies. `setDexProfile` reconfigures all three at once.
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

        (uint256 lpRatio, uint256 protocolRatio) = DexProfile.localDex();
        stake = new MockStake(
            address(memberNFT),
            address(launch),
            address(router),
            address(factory),
            PHASES_MIN,
            PHASES_MAX,
            lpRatio,
            protocolRatio
        );

        // The Hub reads the profile from Stake, so it is no longer a constructor input.
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

    /// @dev Points the Hub, the router and the pair at one DEX profile. The Hub's ratios are `immutable`,
    ///      so this redeploys the Hub: a fixture that kept the old instance would be testing a deployment
    ///      whose configuration disagrees with the pool it trades against.
    function _setDexProfile(uint256 lpRatio, uint256 protocolRatio) internal {
        (uint256 feeNumerator, uint256 feeDenominator) = _reduced(1e18 - lpRatio - protocolRatio, 1e18);
        (uint256 protocolNumerator, uint256 protocolDenominator) = protocolRatio == 0
            ? (uint256(0), uint256(1))
            : _reduced(protocolRatio, lpRatio);

        router.setFee(feeNumerator, feeDenominator);
        factory.setProtocolFee(protocolNumerator, protocolDenominator);
        factory.setFeeTo(protocolRatio == 0 ? address(0) : address(0xFEE));
        factory.configurePair(address(pair));

        // `_setDexProfile` re-points the DEX; the Hub copies the profile from Stake at construction,
        // so Stake has to carry it. The mock's ratios are immutable, hence a fresh Stake.
        _setStakeProfile(lpRatio, protocolRatio);
        hub = new LOVE20Hub(address(stake));
    }

    /// @dev Builds a Hub against a Stake carrying an arbitrary fee profile, so the constructor's
    ///      validation can be exercised now that the profile is no longer a Hub input. The Stake is
    ///      created first and the expectation armed immediately before the Hub, because `expectRevert`
    ///      only covers the next call.
    function _expectHubRejectsProfile(uint256 lpRatio, uint256 protocolRatio, bytes memory expectedError)
        internal
    {
        MockStake bad = new MockStake(
            address(memberNFT),
            address(launch),
            address(router),
            address(factory),
            PHASES_MIN,
            PHASES_MAX,
            lpRatio,
            protocolRatio
        );
        vm.expectRevert(expectedError);
        new LOVE20Hub(address(bad));
    }

    function _hubAgainstProfile(uint256 lpRatio, uint256 protocolRatio) internal returns (LOVE20Hub) {
        MockStake bad = new MockStake(
            address(memberNFT),
            address(launch),
            address(router),
            address(factory),
            PHASES_MIN,
            PHASES_MAX,
            lpRatio,
            protocolRatio
        );
        return new LOVE20Hub(address(bad));
    }

    function _setStakeProfile(uint256 lpRatio, uint256 protocolRatio) internal {
        stake = new MockStake(
            address(memberNFT),
            address(launch),
            address(router),
            address(factory),
            PHASES_MIN,
            PHASES_MAX,
            lpRatio,
            protocolRatio
        );
        stake.setPair(address(token), address(pair));
        stake.setParentToken(address(token), address(wbnb));
    }

    function _reduced(uint256 numerator, uint256 denominator) internal pure returns (uint256, uint256) {
        uint256 a = numerator;
        uint256 b = denominator;
        while (b != 0) {
            (a, b) = (b, a % b);
        }
        return (numerator / a, denominator / a);
    }

    /// @dev Adds liquidity to the community pair. Called more than once by the tests that need a skewed
    ///      pool, so the approvals are unlimited rather than sized to the first seed.
    function _seed(uint256 tokenSeed, uint256 parentSeed) internal {
        token.mint(address(this), tokenSeed);
        wbnb.mint(address(this), parentSeed);
        token.approve(address(pair), type(uint256).max);
        wbnb.approve(address(pair), type(uint256).max);

        (address token0,) = (pair.token0(), pair.token1());
        if (address(token) == token0) {
            pair.addLiquidity(tokenSeed, parentSeed);
        } else {
            pair.addLiquidity(parentSeed, tokenSeed);
        }
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

    /// @dev The pair's reserves ordered as `(community token, parent)`, which is how the Hub reads them.
    function _reserves() internal view returns (uint256 reserveToken, uint256 reserveParent) {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        return address(token) == pair.token0()
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
    }
}
