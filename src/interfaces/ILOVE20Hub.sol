// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IUniswapV2Router02} from "./IUniswapV2Router02.sol";

struct StakeLiquidityWithTokenParams {
    address tokenAddress;
    address inputTokenAddress;
    uint256 inputTokenAmount;
    uint256 tokenAmountMin;
    uint256 parentTokenAmountMin;
    uint256 promisedWaitingPhases;
    uint256 memberId;
    uint256 deadline;
}

struct StakeLiquidityWithNativeParams {
    address tokenAddress;
    uint256 tokenAmountMin;
    uint256 parentTokenAmountMin;
    uint256 promisedWaitingPhases;
    uint256 memberId;
    uint256 deadline;
}

struct AddLiquidityWithTokenParams {
    address tokenAddress;
    address inputTokenAddress;
    uint256 inputTokenAmount;
    uint256 tokenAmountMin;
    uint256 parentTokenAmountMin;
    address to;
    uint256 deadline;
}

struct AddLiquidityWithNativeParams {
    address tokenAddress;
    uint256 tokenAmountMin;
    uint256 parentTokenAmountMin;
    address to;
    uint256 deadline;
}

struct SingleTokenLpQuote {
    bool willSwap;
    address swapTokenIn;
    address swapTokenOut;
    uint256 amountToSwap;
    uint256 amountOutFromSwap;
    uint256 preparedTokenAmount;
    uint256 preparedParentTokenAmount;
    uint256 usableTokenAmount;
    uint256 usableParentTokenAmount;
    uint256 expectedLiquidity;
}

struct SingleTokenStakeLiquidityQuote {
    bool willSwap;
    address swapTokenIn;
    address swapTokenOut;
    uint256 amountToSwap;
    uint256 amountOutFromSwap;
    uint256 preparedTokenAmount;
    uint256 preparedParentTokenAmount;
    uint256 usableTokenAmount;
    uint256 usableParentTokenAmount;
    uint256 liquiditySharesAdded;
    uint256 liquidityShares;
    uint256 govVotesAdded;
    uint256 suggestedTokenAmountMin;
    uint256 suggestedParentTokenAmountMin;
}

interface ILOVE20HubErrors {
    error ZeroTokenAddress();
    error ZeroInputTokenAddress();
    error ZeroInputTokenAmount();
    error ZeroNativeTokenAmount();
    error ZeroRecipientAddress();
    error InvalidInputTokenAddress(address inputTokenAddress);
    error NativeInputUnsupported(address parentTokenAddress);
    error TokenNotRegistered(address tokenAddress);
    error PairMissing(address tokenAddress);
    error PairEmpty(address tokenAddress);
    error DeadlineExpired(
        uint256 blockTimestamp,
        uint256 deadline
    );
    error AmountExceeded(
        uint256 amount,
        uint256 maxAmount
    );
    error ZeroSwapOutput();
    error InsufficientTokenAmount(
        uint256 amount,
        uint256 minAmount
    );
    error InsufficientParentTokenAmount(
        uint256 amount,
        uint256 minAmount
    );
    error InvalidPromisedWaitingPhases(
        uint256 value,
        uint256 minPhases,
        uint256 maxPhases
    );
    error NativeTokenSenderRejected(address sender);
    error NativeRefundFailed();
}

interface ILOVE20HubEvents {
    event HubLiquidityStakedWithToken(
        address indexed tokenAddress,
        uint256 indexed memberId,
        address indexed caller,
        uint256 preparedTokenAmount,
        uint256 preparedParentTokenAmount,
        uint256 remainingTokenAmount,
        uint256 remainingParentTokenAmount
    );
    event HubLiquidityStakedWithNative(
        address indexed tokenAddress,
        uint256 indexed memberId,
        address indexed caller,
        uint256 preparedTokenAmount,
        uint256 preparedParentTokenAmount,
        uint256 remainingTokenAmount,
        uint256 remainingParentTokenAmount
    );
    event HubLiquidityAddedWithToken(
        address indexed tokenAddress,
        address indexed to,
        address indexed caller,
        uint256 preparedTokenAmount,
        uint256 preparedParentTokenAmount,
        uint256 remainingTokenAmount,
        uint256 remainingParentTokenAmount,
        uint256 liquidity
    );
    event HubLiquidityAddedWithNative(
        address indexed tokenAddress,
        address indexed to,
        address indexed caller,
        uint256 preparedTokenAmount,
        uint256 preparedParentTokenAmount,
        uint256 remainingTokenAmount,
        uint256 remainingParentTokenAmount,
        uint256 liquidity
    );
}

interface ILOVE20Hub is ILOVE20HubErrors, ILOVE20HubEvents {
    receive() external payable;

    function STAKE_ADDRESS() external view returns (address);

    function ROUTER_ADDRESS() external view returns (IUniswapV2Router02);

    function PAIR_FACTORY_ADDRESS() external view returns (address);

    function LAUNCH_ADDRESS() external view returns (address);

    function MEMBER_NFT_ADDRESS() external view returns (address);

    function WRAPPED_NATIVE_ADDRESS() external view returns (address);

    function stakeLiquidityWithToken(StakeLiquidityWithTokenParams calldata params)
        external
        returns (uint256 govVotesAdded, uint256 liquiditySharesAdded);

    function stakeLiquidityWithNative(StakeLiquidityWithNativeParams calldata params)
        external
        payable
        returns (uint256 govVotesAdded, uint256 liquiditySharesAdded);

    function addLiquidityWithToken(AddLiquidityWithTokenParams calldata params)
        external
        returns (uint256 liquidity);

    function addLiquidityWithNative(AddLiquidityWithNativeParams calldata params)
        external
        payable
        returns (uint256 liquidity);

    function quoteSingleTokenLp(address tokenAddress, address inputTokenAddress, uint256 inputTokenAmount)
        external
        view
        returns (SingleTokenLpQuote memory quote);

    function quoteSingleTokenLpWithNative(address tokenAddress, uint256 inputNativeTokenAmount)
        external
        view
        returns (SingleTokenLpQuote memory quote);

    function quoteSingleTokenStakeLiquidity(
        address tokenAddress,
        address inputTokenAddress,
        uint256 inputTokenAmount,
        uint256 memberId,
        uint256 promisedWaitingPhases
    ) external view returns (SingleTokenStakeLiquidityQuote memory quote);

    function quoteSingleTokenStakeLiquidityWithNative(
        address tokenAddress,
        uint256 inputNativeTokenAmount,
        uint256 memberId,
        uint256 promisedWaitingPhases
    ) external view returns (SingleTokenStakeLiquidityQuote memory quote);
}
