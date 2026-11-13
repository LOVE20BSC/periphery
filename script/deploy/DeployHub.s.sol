// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {ILaunch} from "@core/interfaces/ILaunch.sol";
import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";
import {IUniswapV2Factory} from "../../src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "../../src/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IUniswapV2Router02.sol";
import {LOVE20Hub} from "../../src/LOVE20Hub.sol";

/// @dev Deployment gate for `LOVE20Hub`.
///
///      The Hub takes one injected dependency (`Stake`) and derives the rest, so a wrong `Stake` is the
///      only way to deploy a wrong Hub — that is what the address-book cross-check rules out.
///
///      The DEX fee profile is not a Hub input: Stake stores it and the Hub copies it, so the Hub cannot
///      disagree with the staking maths. What can still go wrong is Stake itself carrying the wrong
///      profile for the DEX it points at, and that is silent: the Hub would still work, but its swap
///      sizing and its LP projection would be off. So before broadcasting, this script (a) asserts that
///      Stake reports the profile the operator expected, and (b) re-derives the swap fee from the DEX
///      itself by asking the router for a real quote and inverting `getAmountOut`:
///
///        y = x*F*rOut / (rIn*D + x*F)   =>   F/D = y*rIn / (x*(rOut - y))
///
///      A mismatch aborts the run and prints both values. The ratios themselves come from `hub.params`
///      (auditable, reproducible, independent of whether the chain has a funded pool at deploy time); the
///      probe only cross-checks them.
contract DeployHub is Script {
    struct HubConfig {
        uint256 chainId;
        address stake;
        // The fee profile is not configured here: Stake stores it and the Hub copies it. These are the
        // values Stake is expected to report, kept only so the deployment can assert it read what the
        // operator intended.
        uint256 expectedSwapFeeForLpRatio;
        uint256 expectedSwapFeeForProtocolRatio;
        address expectedRouter;
        address expectedPairFactory;
        address expectedLaunch;
        address expectedMemberNFT;
        address expectedWrappedNative;
        /// @dev A pair with non-zero reserves used to cross-check the configured swap fee. Optional: when
        ///      zero the probe is skipped (a fresh chain has no funded pool to ask).
        address probeToken;
    }

    function run() external returns (address hubAddress) {
        HubConfig memory config = _loadConfig();
        _validateConfig(config);
        _validateFeeRatiosAgainstTheDex(config);

        vm.startBroadcast();
        LOVE20Hub hub = new LOVE20Hub(config.stake);
        vm.stopBroadcast();

        _validateDeployment(config, hub);
        hubAddress = address(hub);
        _logDeploymentSummary(hubAddress);
    }

    function _loadConfig() internal view returns (HubConfig memory config) {
        config.chainId = vm.envUint("CHAIN_ID");
        config.stake = vm.envAddress("STAKE_ADDRESS");
        config.expectedSwapFeeForLpRatio = vm.envUint("SWAP_FEE_FOR_LP_RATIO");
        config.expectedSwapFeeForProtocolRatio = vm.envUint("SWAP_FEE_FOR_PROTOCOL_RATIO");
        config.expectedRouter = vm.envAddress("ROUTER_ADDRESS");
        config.expectedPairFactory = vm.envAddress("PAIR_FACTORY_ADDRESS");
        config.expectedLaunch = vm.envAddress("LAUNCH_ADDRESS");
        config.expectedMemberNFT = vm.envAddress("MEMBER_NFT_ADDRESS");
        config.expectedWrappedNative = vm.envAddress("WRAPPED_NATIVE_ADDRESS");
        // `hub.params` always defines the key, so an unused probe arrives as an empty string rather than
        // as an unset variable. Both shapes mean "skip the cross-check".
        string memory probeTokenValue = vm.envString("SWAP_FEE_PROBE_TOKEN");
        config.probeToken = bytes(probeTokenValue).length == 0 ? address(0) : vm.envAddress("SWAP_FEE_PROBE_TOKEN");
    }

    /// @dev Runs entirely before `startBroadcast()`. Every derived value is re-read from `Stake` and from
    ///      the router, code-checked, and compared against the address book core wrote before this run.
    function _validateConfig(HubConfig memory config) internal view {
        require(block.chainid == config.chainId, "Chain ID mismatch");
        require(config.stake.code.length != 0, "Stake must be a deployed contract");

        IStake stake = IStake(config.stake);

        // The profile lives in Stake now, so this compares what Stake reports against what the operator
        // expected rather than validating a local copy. A mismatch means Stake was deployed with a
        // different DEX profile, which would make every Hub quote wrong in a way that is hard to see.
        require(
            stake.SWAP_FEE_FOR_LP_RATIO() == config.expectedSwapFeeForLpRatio,
            "Stake SWAP_FEE_FOR_LP_RATIO differs from the expected profile"
        );
        require(
            stake.SWAP_FEE_FOR_PROTOCOL_RATIO() == config.expectedSwapFeeForProtocolRatio,
            "Stake SWAP_FEE_FOR_PROTOCOL_RATIO differs from the expected profile"
        );
        require(config.expectedSwapFeeForLpRatio > 0, "SWAP_FEE_FOR_LP_RATIO must be non-zero");
        require(
            config.expectedSwapFeeForLpRatio + config.expectedSwapFeeForProtocolRatio < 1e18,
            "swap fee ratios must sum to less than 1e18"
        );

        address routerAddress = stake.ROUTER_ADDRESS();
        address pairFactoryAddress = stake.PAIR_FACTORY_ADDRESS();
        address launchAddress = stake.LAUNCH_ADDRESS();
        address memberNFTAddress = stake.MEMBER_NFT_ADDRESS();

        require(routerAddress.code.length != 0, "Stake routerAddress must be a deployed contract");
        require(pairFactoryAddress.code.length != 0, "Stake pairFactoryAddress must be a deployed contract");
        require(launchAddress.code.length != 0, "Stake launchAddress must be a deployed contract");
        require(memberNFTAddress.code.length != 0, "Stake memberNFTAddress must be a deployed contract");

        address wrappedNativeAddress = IUniswapV2Router02(routerAddress).WETH();
        require(wrappedNativeAddress.code.length != 0, "Router WETH must be a deployed contract");

        require(routerAddress == config.expectedRouter, "Stake routerAddress mismatch with core params");
        require(
            pairFactoryAddress == config.expectedPairFactory,
            "Stake pairFactoryAddress mismatch with core params"
        );
        require(launchAddress == config.expectedLaunch, "Stake launchAddress mismatch with core params");
        require(
            memberNFTAddress == config.expectedMemberNFT, "Stake memberNFTAddress mismatch with core params"
        );
        require(
            wrappedNativeAddress == config.expectedWrappedNative,
            "Router WETH mismatch with the dependency address file"
        );

        // The Hub trusts these getters at run time, so the graph has to be self-consistent before it is
        // written to the chain: Launch must agree with Stake about the factory, and MemberNFT must agree
        // about the root parent token.
        require(
            ILaunch(launchAddress).PAIR_FACTORY_ADDRESS() == pairFactoryAddress,
            "Launch pairFactoryAddress mismatch"
        );
        require(
            IMemberNFT(memberNFTAddress).LOVE20_TOKEN_ADDRESS() != address(0),
            "MemberNFT root token must be configured"
        );
    }

    /// @dev Cross-checks the configured swap fee against what the DEX actually charges, by inverting one
    ///      real `getAmountsOut` quote. Skipped when no probe token is configured.
    function _validateFeeRatiosAgainstTheDex(HubConfig memory config) internal view {
        address probeToken = config.probeToken;
        if (probeToken == address(0)) {
            console2.log("SWAP_FEE_PROBE_TOKEN unset; skipping the on-chain fee cross-check");
            return;
        }

        IUniswapV2Router02 router = IUniswapV2Router02(config.expectedRouter);
        address[] memory path = new address[](2);
        path[0] = probeToken;
        path[1] = config.expectedWrappedNative;

        address pairAddress = IUniswapV2Factory(config.expectedPairFactory).getPair(
            probeToken, config.expectedWrappedNative
        );
        require(pairAddress != address(0), "Probe pair missing; cannot cross-check the swap fee");

        (uint256 reserveIn, uint256 reserveOut) = _reservesOf(pairAddress, probeToken);
        require(reserveIn > 0 && reserveOut > 0, "Probe pair has no reserves; cannot cross-check the swap fee");

        // A quote at 1/1000 of the reserve keeps the output large enough that the inversion is exact.
        uint256 probeIn = reserveIn / 1000;
        require(probeIn > 0, "Probe pair too shallow to cross-check the swap fee");

        uint256 probeOut = router.getAmountsOut(probeIn, path)[1];
        require(probeOut > 0 && probeOut < reserveOut, "Probe quote unusable");

        // F/D = y*rIn / (x*(rOut - y)); compare the configured ratio against it after cross-multiplying so
        // the comparison stays integral.
        uint256 configuredFee = 1e18 - config.expectedSwapFeeForLpRatio - config.expectedSwapFeeForProtocolRatio;
        // The probe size is deliberately a fraction of the reserve so the quote stays large; the ratio is
        // then compared by cross-multiplication, which keeps the comparison integral. `probeIn` is a
        // division result, so both sides are scaled the same way — the scaling cancels in the comparison
        // and no precision is lost.
        uint256 quotedNumerator = probeOut * reserveIn * 1e18;
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 quotedDenominator = probeIn * (reserveOut - probeOut);

        // One part in a thousand of tolerance covers the pair's own floor division, which biases the
        // recovered ratio by roughly 1/output.
        uint256 configuredScaled = configuredFee * quotedDenominator;
        uint256 quotedScaled = quotedNumerator;
        uint256 difference =
            configuredScaled > quotedScaled ? configuredScaled - quotedScaled : quotedScaled - configuredScaled;

        require(
            difference * 1000 <= quotedScaled,
            string.concat(
                "Configured swap fee does not match the DEX: configured=",
                vm.toString(configuredFee),
                " quoted=",
                vm.toString((quotedNumerator * 1e18) / quotedDenominator)
            )
        );
    }

    function _reservesOf(address pairAddress, address tokenAddress)
        internal
        view
        returns (uint256 reserveIn, uint256 reserveOut)
    {
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        return tokenAddress == pair.token0()
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
    }

    function _validateDeployment(HubConfig memory config, LOVE20Hub hub) internal view {
        require(address(hub).code.length != 0, "Hub deployment failed");
        require(hub.STAKE_ADDRESS() == config.stake, "Stake mismatch");
        require(address(hub.ROUTER_ADDRESS()) == config.expectedRouter, "Router mismatch");
        require(hub.PAIR_FACTORY_ADDRESS() == config.expectedPairFactory, "Pair factory mismatch");
        require(hub.LAUNCH_ADDRESS() == config.expectedLaunch, "Launch mismatch");
        require(hub.MEMBER_NFT_ADDRESS() == config.expectedMemberNFT, "Member NFT mismatch");
        require(hub.WRAPPED_NATIVE_ADDRESS() == config.expectedWrappedNative, "Wrapped native mismatch");
        // The Hub copies the profile from Stake, so these assertions catch a Stake that was deployed
        // with a different profile than the operator expected.
        require(
            hub.SWAP_FEE_FOR_LP_RATIO() == config.expectedSwapFeeForLpRatio,
            "Hub LP fee ratio differs from the expected profile"
        );
        require(
            hub.SWAP_FEE_FOR_PROTOCOL_RATIO() == config.expectedSwapFeeForProtocolRatio,
            "Hub protocol fee ratio differs from the expected profile"
        );
    }

    function _logDeploymentSummary(address hubAddress) internal pure {
        console2.log("HUB_ADDRESS=", hubAddress);
    }
}
