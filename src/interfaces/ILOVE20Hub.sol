// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IUniswapV2Router02} from "./IUniswapV2Router02.sol";

struct StakeLiquidityWithTokenParams {
    address tokenAddress;
    uint256 tokenAmountDesired;
    uint256 parentTokenAmountDesired;
    uint256 minLiquidityShares;
    uint256 promisedWaitingPhases;
    uint256 memberId;
    uint256 deadline;
}

struct StakeLiquidityWithNativeParams {
    address tokenAddress;
    uint256 tokenAmountDesired;
    uint256 minLiquidityShares;
    uint256 promisedWaitingPhases;
    uint256 memberId;
    uint256 deadline;
}

struct AddLiquidityWithTokenParams {
    address tokenA;
    address tokenB;
    uint256 amountADesired;
    uint256 amountBDesired;
    uint256 minLiquidity;
    address to;
    uint256 deadline;
}

struct AddLiquidityWithNativeParams {
    address tokenAddress;
    uint256 amountTokenDesired;
    uint256 minLiquidity;
    address to;
    uint256 deadline;
}

struct LpQuote {
    bool hasLiquidity;
    bool willSwap;
    address swapTokenIn;
    address swapTokenOut;
    uint256 amountToSwap;
    uint256 amountOutFromSwap;
    uint256 preparedAmountA;
    uint256 preparedAmountB;
    uint256 usableAmountA;
    uint256 usableAmountB;
    uint256 expectedLiquidity;
}

struct StakeLiquidityQuote {
    bool hasLiquidity;
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
    uint256 liquiditySharesAdded;
    uint256 liquidityShares;
    uint256 govVotesAdded;
}

interface ILOVE20HubErrors {
    error ZeroTokenAddress();
    error ZeroTokenAAddress();
    error ZeroTokenBAddress();
    error ZeroNativeTokenAmount();
    error ZeroDesiredAmounts();
    error ZeroRecipientAddress();
    error IdenticalTokens(address tokenAddress);
    error WrappedNativeAsToken(address tokenAddress);
    error NativeInputUnsupported(address parentTokenAddress);
    error TokenNotRegistered(address tokenAddress);
    error PairMissing(address tokenAddress);
    error PairWithoutLiquidity(
        address tokenA,
        address tokenB
    );
    error DeadlineExpired(
        uint256 blockTimestamp,
        uint256 deadline
    );
    error AmountExceeded(
        uint256 amount,
        uint256 maxAmount
    );
    error ZeroSwapOutput();
    error InexactTokenTransfer(address tokenAddress, uint256 expected, uint256 received);
    error InsufficientLiquidity(uint256 liquidity, uint256 minLiquidity);
    error InsufficientLiquidityShares(uint256 shares, uint256 minShares);
    error PromisedWaitingPhasesMismatch(uint256 requested, uint256 current);
    error InvalidPromisedWaitingPhases(
        uint256 value,
        uint256 minPhases,
        uint256 maxPhases
    );
    error ZeroLpFeeRatio();
    error ProtocolFeeRatioNotBelowLpRatio(
        uint256 swapFeeForLpRatio,
        uint256 swapFeeForProtocolRatio
    );
    error SwapFeeRatiosConsumeTheWholeAmount(
        uint256 swapFeeForLpRatio,
        uint256 swapFeeForProtocolRatio
    );
    error SwapFeeSumBreaksTheClosedForm(
        uint256 swapFeeForLpRatio,
        uint256 swapFeeForProtocolRatio
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
        address indexed pairAddress,
        address indexed to,
        address indexed caller,
        uint256 preparedAmountA,
        uint256 preparedAmountB,
        uint256 remainingAmountA,
        uint256 remainingAmountB,
        uint256 liquidity
    );
    event HubLiquidityAddedWithNative(
        address indexed pairAddress,
        address indexed to,
        address indexed caller,
        uint256 preparedAmountA,
        uint256 preparedAmountB,
        uint256 remainingAmountA,
        uint256 remainingAmountB,
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

    function SWAP_FEE_FOR_LP_RATIO() external view returns (uint256);
    function SWAP_FEE_FOR_PROTOCOL_RATIO() external view returns (uint256);

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

    function quoteLp(address tokenA, address tokenB, uint256 amountADesired, uint256 amountBDesired)
        external
        view
        returns (LpQuote memory quote);

    function quoteLpWithNative(address tokenAddress, uint256 amountTokenDesired, uint256 amountNativeDesired)
        external
        view
        returns (LpQuote memory quote);

    function quoteStakeLiquidity(
        address tokenAddress,
        uint256 tokenAmountDesired,
        uint256 parentTokenAmountDesired,
        uint256 memberId,
        uint256 promisedWaitingPhases
    ) external view returns (StakeLiquidityQuote memory quote);

    function quoteStakeLiquidityWithNative(
        address tokenAddress,
        uint256 tokenAmountDesired,
        uint256 parentTokenAmountDesired,
        uint256 memberId,
        uint256 promisedWaitingPhases
    ) external view returns (StakeLiquidityQuote memory quote);
}
