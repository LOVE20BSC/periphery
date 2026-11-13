// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IUniswapV2Router02} from "./IUniswapV2Router02.sol";

/// @dev Staking entry, ERC20 funding. Both desired amounts may be non-zero (dual sided) or only one of
///      them (the single-token case is `desired == 0` on the other side).
struct StakeLiquidityWithTokenParams {
    address tokenAddress;
    uint256 tokenAmountDesired;
    uint256 parentTokenAmountDesired;
    uint256 tokenAmountMin;
    uint256 parentTokenAmountMin;
    uint256 promisedWaitingPhases;
    uint256 memberId;
    uint256 deadline;
}

/// @dev Staking entry, native funding. The native amount is `msg.value`; `parentTokenAmountDesired` is
///      therefore not a parameter. The parent side must be the wrapped native token.
struct StakeLiquidityWithNativeParams {
    address tokenAddress;
    uint256 tokenAmountDesired;
    uint256 tokenAmountMin;
    uint256 parentTokenAmountMin;
    uint256 promisedWaitingPhases;
    uint256 memberId;
    uint256 deadline;
}

/// @dev LP entry, ERC20 funding, any token pair. `tokenA` / `tokenB` are the pair's two sides in the
///      caller's own order; the Hub derives the pair from the factory and never requires `tokenA < tokenB`.
struct AddLiquidityWithTokenParams {
    address tokenA;
    address tokenB;
    uint256 amountADesired;
    uint256 amountBDesired;
    uint256 amountAMin;
    uint256 amountBMin;
    address to;
    uint256 deadline;
}

/// @dev LP entry, native funding. The native side is `msg.value`, so it is not a parameter; the other side
///      is `tokenAddress` and the pair is `(tokenAddress, WRAPPED_NATIVE_ADDRESS)`.
struct AddLiquidityWithNativeParams {
    address tokenAddress;
    uint256 amountTokenDesired;
    uint256 amountTokenMin;
    uint256 amountNativeMin;
    address to;
    uint256 deadline;
}

/// @dev One call's quote. `hasLiquidity == false` means the pair is missing or its reserves are both zero,
///      in which case no swap happens and both desired amounts must be non-zero (first liquidity).
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
    uint256 suggestedAmountAMin;
    uint256 suggestedAmountBMin;
}

/// @dev Staking quote: the LP quote plus the share / vote outcome core will actually credit. `memberId` and
///      `promisedWaitingPhases` are required because both values depend on the member's existing position.
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
    uint256 suggestedTokenAmountMin;
    uint256 suggestedParentAmountMin;
}

interface ILOVE20HubErrors {
    error ZeroTokenAddress();
    error ZeroTokenAAddress();
    error ZeroTokenBAddress();
    error ZeroNativeTokenAmount();
    error ZeroAmount();
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
    error InsufficientTokenAmount(
        uint256 amount,
        uint256 minAmount
    );
    error InsufficientParentTokenAmount(
        uint256 amount,
        uint256 minAmount
    );
    error InsufficientAmountA(
        uint256 amount,
        uint256 minAmount
    );
    error InsufficientAmountB(
        uint256 amount,
        uint256 minAmount
    );
    error InvalidPromisedWaitingPhases(
        uint256 value,
        uint256 minPhases,
        uint256 maxPhases
    );
    error InvalidFeeRatios(
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

    /// @dev The fee the pair keeps for liquidity providers, in 1e18 units (0.25% = 2.5e15).
    function SWAP_FEE_FOR_LP_RATIO() external view returns (uint256);

    /// @dev The fee the protocol takes out of that, in 1e18 units (Pancake mainnet: 0.08% = 8e14).
    ///      Zero means the DEX has its protocol fee permanently off.
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

    /// @dev The native amount is a parameter here (unlike the write entry, where it is `msg.value`): a
    ///      `view` call has no `msg.value`, and the simulation needs both sides.
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
