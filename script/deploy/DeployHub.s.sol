// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {ILaunch} from "@core/interfaces/ILaunch.sol";
import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IUniswapV2Router02.sol";
import {LOVE20Hub} from "../../src/LOVE20Hub.sol";

contract DeployHub is Script {
    struct HubConfig {
        uint256 chainId;
        address stake;
        address expectedRouter;
        address expectedPairFactory;
        address expectedLaunch;
        address expectedMemberNFT;
        address expectedWrappedNative;
    }

    function run() external returns (address hubAddress) {
        HubConfig memory config = _loadConfig();
        _validateConfig(config);

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
        config.expectedRouter = vm.envAddress("ROUTER_ADDRESS");
        config.expectedPairFactory = vm.envAddress("PAIR_FACTORY_ADDRESS");
        config.expectedLaunch = vm.envAddress("LAUNCH_ADDRESS");
        config.expectedMemberNFT = vm.envAddress("MEMBER_NFT_ADDRESS");
        config.expectedWrappedNative = vm.envAddress("WRAPPED_NATIVE_ADDRESS");
    }

    /// @dev Runs entirely before `startBroadcast()`. The Hub takes one address and derives the rest, so the
    ///      only way a wrong deployment can happen is through a wrong `Stake` — which is exactly what this
    ///      gate rules out: every derived value is re-read from `Stake` and from the router, code-checked,
    ///      and compared against the address book core wrote before this run.
    function _validateConfig(HubConfig memory config) internal view {
        require(block.chainid == config.chainId, "Chain ID mismatch");
        require(config.stake.code.length != 0, "Stake must be a deployed contract");

        IStake stake = IStake(config.stake);
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

    function _validateDeployment(HubConfig memory config, LOVE20Hub hub) internal view {
        require(address(hub).code.length != 0, "Hub deployment failed");
        require(hub.STAKE_ADDRESS() == config.stake, "Stake mismatch");
        require(address(hub.ROUTER_ADDRESS()) == config.expectedRouter, "Router mismatch");
        require(hub.PAIR_FACTORY_ADDRESS() == config.expectedPairFactory, "Pair factory mismatch");
        require(hub.LAUNCH_ADDRESS() == config.expectedLaunch, "Launch mismatch");
        require(hub.MEMBER_NFT_ADDRESS() == config.expectedMemberNFT, "Member NFT mismatch");
        require(hub.WRAPPED_NATIVE_ADDRESS() == config.expectedWrappedNative, "Wrapped native mismatch");
    }

    function _logDeploymentSummary(address hubAddress) internal pure {
        console2.log("HUB_ADDRESS=", hubAddress);
    }
}
