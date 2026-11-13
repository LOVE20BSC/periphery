// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";
import {ILOVE20Token} from "@core/interfaces/ILOVE20Token.sol";
import {ILaunch} from "@core/interfaces/ILaunch.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {
    ILOVE20Hub,
    StakeLiquidityWithTokenParams,
    StakeLiquidityWithNativeParams,
    AddLiquidityWithTokenParams,
    AddLiquidityWithNativeParams,
    LpQuote,
    StakeLiquidityQuote
} from "./interfaces/ILOVE20Hub.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";
import {IWrappedNative} from "./interfaces/IWrappedNative.sol";

/// @dev One call's snapshot of the pair it trades against. `balanceABefore` / `balanceBBefore` are the Hub's
///      own balances at entry, so every prepared / remaining amount is a plain balance delta.
struct HubPair {
    address tokenA;
    address tokenB;
    address pairAddress;
    bool hasLiquidity;
    uint256 balanceABefore;
    uint256 balanceBBefore;
    uint256 reserveA;
    uint256 reserveB;
}

/// @dev The four amounts one call reports. Computed once per call and read by the minimum check, by the
///      refund and by the event, which keeps the entry points inside the stack limit under the standard
///      optimizer without a second copy of the arithmetic.
struct HubAmounts {
    uint256 preparedAmountA;
    uint256 preparedAmountB;
    uint256 remainingAmountA;
    uint256 remainingAmountB;
}

/// @dev Staking entry: a community token and its parent, both sides resolved from the registry.
struct StakeContext {
    address tokenAddress;
    address parentTokenAddress;
    address pairAddress;
    uint256 balanceTokenBefore;
    uint256 balanceParentBefore;
    uint256 reserveToken;
    uint256 reserveParent;
    bool hasLiquidity;
}

contract LOVE20Hub is ReentrancyGuard, ILOVE20Hub {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant UNISWAP_V2_MINIMUM_LIQUIDITY = 1000;
    uint256 private constant UNISWAP_V2_MAX_RESERVE = type(uint112).max;

    /// @dev Both fee ratios are 1e18 fixed point fractions of the swap amount, copied from `Stake` at
    ///      construction. They differ per deployment: the local `dex` charges 0.30% and takes no protocol
    ///      fee, Pancake mainnet charges 0.25% of which 0.08% goes to the protocol, Pancake testnet
    ///      0.20%/0.05%.
    ///
    ///      `SWAP_FEE_FOR_LP_RATIO` is the part the pair keeps; `SWAP_FEE_FOR_PROTOCOL_RATIO` is the part
    ///      the DEX takes out of it. The swap fee actually charged is their sum, and it is also exactly the
    ///      fee the constant-product swap maths uses.
    uint256 public immutable SWAP_FEE_FOR_LP_RATIO;
    uint256 public immutable SWAP_FEE_FOR_PROTOCOL_RATIO;

    address public immutable STAKE_ADDRESS;

    IUniswapV2Router02 public immutable ROUTER_ADDRESS;

    address public immutable PAIR_FACTORY_ADDRESS;

    address public immutable LAUNCH_ADDRESS;

    address public immutable MEMBER_NFT_ADDRESS;

    address public immutable WRAPPED_NATIVE_ADDRESS;

    /// @dev The DEX profile is not a constructor input: `Stake` already stores it, because it needs the
    ///      same two ratios to predict the pair's `_mintFee`. Reading them from there keeps one source of
    ///      truth, so the Hub cannot be deployed against a fee profile that disagrees with the one the
    ///      staking maths uses.
    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address stakeAddress) {
        uint256 swapFeeForLpRatio = IStake(stakeAddress).SWAP_FEE_FOR_LP_RATIO();
        uint256 swapFeeForProtocolRatio = IStake(stakeAddress).SWAP_FEE_FOR_PROTOCOL_RATIO();
        if (swapFeeForLpRatio == 0) revert InvalidFeeRatios(swapFeeForLpRatio, swapFeeForProtocolRatio);
        if (swapFeeForLpRatio + swapFeeForProtocolRatio >= PRECISION) {
            revert InvalidFeeRatios(swapFeeForLpRatio, swapFeeForProtocolRatio);
        }
        // The closed form's dominant term is `r^2 * (F+D)^2`; at `r = uint112.max` it only fits uint256
        // while `F+D <= 65536`. Checked here so an impossible deployment fails at construction instead of
        // overflowing on some future swap.
        uint256 swapFeeRatio = PRECISION - swapFeeForLpRatio - swapFeeForProtocolRatio;
        if (_swapFeeSumBound(swapFeeRatio) > 65536) {
            revert InvalidFeeRatios(swapFeeForLpRatio, swapFeeForProtocolRatio);
        }

        SWAP_FEE_FOR_LP_RATIO = swapFeeForLpRatio;
        SWAP_FEE_FOR_PROTOCOL_RATIO = swapFeeForProtocolRatio;

        STAKE_ADDRESS = stakeAddress;
        address routerAddress = IStake(stakeAddress).ROUTER_ADDRESS();
        PAIR_FACTORY_ADDRESS = IStake(stakeAddress).PAIR_FACTORY_ADDRESS();
        LAUNCH_ADDRESS = IStake(stakeAddress).LAUNCH_ADDRESS();
        MEMBER_NFT_ADDRESS = IStake(stakeAddress).MEMBER_NFT_ADDRESS();
        ROUTER_ADDRESS = IUniswapV2Router02(routerAddress);
        WRAPPED_NATIVE_ADDRESS = IUniswapV2Router02(routerAddress).WETH();
    }

    receive() external payable {
        if (msg.sender != WRAPPED_NATIVE_ADDRESS) revert NativeTokenSenderRejected(msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // staking: a community token and its parent, resolved from the registry
    // ---------------------------------------------------------------------------------------------

    function stakeLiquidityWithToken(StakeLiquidityWithTokenParams calldata params)
        external
        nonReentrant
        returns (uint256 govVotesAdded, uint256 liquiditySharesAdded)
    {
        _checkDeadline(params.deadline);
        if (params.tokenAddress == address(0)) revert ZeroTokenAddress();
        _checkDesiredAmounts(params.tokenAmountDesired, params.parentTokenAmountDesired);
        _checkMemberId(params.memberId);
        _checkPromisedWaitingPhases(params.promisedWaitingPhases);

        StakeContext memory context = _stakeContext(params.tokenAddress);
        IERC20(params.tokenAddress).safeTransferFrom(msg.sender, address(this), params.tokenAmountDesired);
        IERC20(context.parentTokenAddress).safeTransferFrom(
            msg.sender, address(this), params.parentTokenAmountDesired
        );

        HubAmounts memory amounts = _prepareStake(
            context, params.tokenAmountDesired, params.parentTokenAmountDesired, params.deadline
        );

        (govVotesAdded, liquiditySharesAdded) = _stake(
            context,
            amounts,
            params.promisedWaitingPhases,
            params.memberId,
            params.tokenAmountMin,
            params.parentTokenAmountMin
        );

        _refundTokens(context.tokenAddress, context.parentTokenAddress, amounts);

        emit HubLiquidityStakedWithToken({
            tokenAddress: context.tokenAddress,
            memberId: params.memberId,
            caller: msg.sender,
            preparedTokenAmount: amounts.preparedAmountA,
            preparedParentTokenAmount: amounts.preparedAmountB,
            remainingTokenAmount: amounts.remainingAmountA,
            remainingParentTokenAmount: amounts.remainingAmountB
        });
    }

    function stakeLiquidityWithNative(StakeLiquidityWithNativeParams calldata params)
        external
        payable
        nonReentrant
        returns (uint256 govVotesAdded, uint256 liquiditySharesAdded)
    {
        _checkDeadline(params.deadline);
        if (params.tokenAddress == address(0)) revert ZeroTokenAddress();
        if (msg.value == 0) revert ZeroNativeTokenAmount();
        _checkDesiredAmounts(params.tokenAmountDesired, msg.value);
        _checkMemberId(params.memberId);
        _checkPromisedWaitingPhases(params.promisedWaitingPhases);
        _checkRegisteredToken(params.tokenAddress);
        _checkNativeParent(params.tokenAddress);

        StakeContext memory context = _stakeContext(params.tokenAddress);
        IERC20(params.tokenAddress).safeTransferFrom(msg.sender, address(this), params.tokenAmountDesired);
        IWrappedNative(WRAPPED_NATIVE_ADDRESS).deposit{value: msg.value}();

        HubAmounts memory amounts =
            _prepareStake(context, params.tokenAmountDesired, msg.value, params.deadline);

        (govVotesAdded, liquiditySharesAdded) = _stake(
            context,
            amounts,
            params.promisedWaitingPhases,
            params.memberId,
            params.tokenAmountMin,
            params.parentTokenAmountMin
        );

        _refundNativeThenToken(context.tokenAddress, amounts);

        emit HubLiquidityStakedWithNative({
            tokenAddress: context.tokenAddress,
            memberId: params.memberId,
            caller: msg.sender,
            preparedTokenAmount: amounts.preparedAmountA,
            preparedParentTokenAmount: amounts.preparedAmountB,
            remainingTokenAmount: amounts.remainingAmountA,
            remainingParentTokenAmount: amounts.remainingAmountB
        });
    }

    // ---------------------------------------------------------------------------------------------
    // LP: any token pair, no registry lookup
    // ---------------------------------------------------------------------------------------------

    function addLiquidityWithToken(AddLiquidityWithTokenParams calldata params)
        external
        nonReentrant
        returns (uint256 liquidity)
    {
        _checkDeadline(params.deadline);
        _checkTokenPair(params.tokenA, params.tokenB);
        if (params.to == address(0)) revert ZeroRecipientAddress();
        _checkDesiredAmounts(params.amountADesired, params.amountBDesired);

        HubPair memory pool = _pairContext(params.tokenA, params.tokenB);
        IERC20(params.tokenA).safeTransferFrom(msg.sender, address(this), params.amountADesired);
        IERC20(params.tokenB).safeTransferFrom(msg.sender, address(this), params.amountBDesired);

        HubAmounts memory amounts =
            _prepare(pool, params.amountADesired, params.amountBDesired, params.deadline);

        liquidity = _addLiquidity(
            pool, amounts, params.to, params.deadline, params.amountAMin, params.amountBMin
        );

        _refundTokens(pool.tokenA, pool.tokenB, amounts);

        emit HubLiquidityAddedWithToken({
            pairAddress: _resolvedPairAddress(pool),
            to: params.to,
            caller: msg.sender,
            preparedAmountA: amounts.preparedAmountA,
            preparedAmountB: amounts.preparedAmountB,
            remainingAmountA: amounts.remainingAmountA,
            remainingAmountB: amounts.remainingAmountB,
            liquidity: liquidity
        });
    }

    function addLiquidityWithNative(AddLiquidityWithNativeParams calldata params)
        external
        payable
        nonReentrant
        returns (uint256 liquidity)
    {
        _checkDeadline(params.deadline);
        if (params.tokenAddress == address(0)) revert ZeroTokenAddress();
        if (params.tokenAddress == WRAPPED_NATIVE_ADDRESS) revert WrappedNativeAsToken(params.tokenAddress);
        if (msg.value == 0) revert ZeroNativeTokenAmount();
        if (params.to == address(0)) revert ZeroRecipientAddress();
        _checkDesiredAmounts(params.amountTokenDesired, msg.value);

        HubPair memory pool = _pairContext(params.tokenAddress, WRAPPED_NATIVE_ADDRESS);
        IERC20(params.tokenAddress).safeTransferFrom(msg.sender, address(this), params.amountTokenDesired);
        IWrappedNative(WRAPPED_NATIVE_ADDRESS).deposit{value: msg.value}();

        HubAmounts memory amounts =
            _prepare(pool, params.amountTokenDesired, msg.value, params.deadline);

        liquidity = _addLiquidity(
            pool, amounts, params.to, params.deadline, params.amountTokenMin, params.amountNativeMin
        );

        _refundNativeThenToken(pool.tokenA, amounts);

        emit HubLiquidityAddedWithNative({
            pairAddress: _resolvedPairAddress(pool),
            to: params.to,
            caller: msg.sender,
            preparedAmountA: amounts.preparedAmountA,
            preparedAmountB: amounts.preparedAmountB,
            remainingAmountA: amounts.remainingAmountA,
            remainingAmountB: amounts.remainingAmountB,
            liquidity: liquidity
        });
    }

    // ---------------------------------------------------------------------------------------------
    // quotes
    // ---------------------------------------------------------------------------------------------

    function quoteLp(address tokenA, address tokenB, uint256 amountADesired, uint256 amountBDesired)
        external
        view
        returns (LpQuote memory quote)
    {
        _checkTokenPair(tokenA, tokenB);
        _checkDesiredAmounts(amountADesired, amountBDesired);
        HubPair memory pool = _pairContext(tokenA, tokenB);
        return _quoteLp(pool, amountADesired, amountBDesired);
    }

    function quoteLpWithNative(address tokenAddress, uint256 amountTokenDesired, uint256 amountNativeDesired)
        external
        view
        returns (LpQuote memory quote)
    {
        if (tokenAddress == address(0)) revert ZeroTokenAddress();
        if (tokenAddress == WRAPPED_NATIVE_ADDRESS) revert WrappedNativeAsToken(tokenAddress);
        _checkDesiredAmounts(amountTokenDesired, amountNativeDesired);
        HubPair memory pool = _pairContext(tokenAddress, WRAPPED_NATIVE_ADDRESS);
        return _quoteLp(pool, amountTokenDesired, amountNativeDesired);
    }

    function quoteStakeLiquidity(
        address tokenAddress,
        uint256 tokenAmountDesired,
        uint256 parentTokenAmountDesired,
        uint256 memberId,
        uint256 promisedWaitingPhases
    ) external view returns (StakeLiquidityQuote memory quote) {
        if (tokenAddress == address(0)) revert ZeroTokenAddress();
        _checkDesiredAmounts(tokenAmountDesired, parentTokenAmountDesired);
        _checkMemberId(memberId);
        _checkPromisedWaitingPhases(promisedWaitingPhases);
        StakeContext memory context = _stakeContext(tokenAddress);
        return _stakeQuote(context, tokenAmountDesired, parentTokenAmountDesired, memberId, promisedWaitingPhases);
    }

    function quoteStakeLiquidityWithNative(
        address tokenAddress,
        uint256 tokenAmountDesired,
        uint256 parentTokenAmountDesired,
        uint256 memberId,
        uint256 promisedWaitingPhases
    ) external view returns (StakeLiquidityQuote memory quote) {
        if (tokenAddress == address(0)) revert ZeroTokenAddress();
        _checkDesiredAmounts(tokenAmountDesired, parentTokenAmountDesired);
        _checkMemberId(memberId);
        _checkPromisedWaitingPhases(promisedWaitingPhases);
        _checkRegisteredToken(tokenAddress);
        _checkNativeParent(tokenAddress);
        StakeContext memory context = _stakeContext(tokenAddress);
        return _stakeQuote(context, tokenAmountDesired, parentTokenAmountDesired, memberId, promisedWaitingPhases);
    }

    // ---------------------------------------------------------------------------------------------
    // validation
    // ---------------------------------------------------------------------------------------------

    function _checkDeadline(uint256 deadline) private view {
        // A deadline is the caller's own upper bound on when the swap and the deposit may land; shifting
        // it by a validator's timestamp window only re-times the caller's own transaction.
        // forge-lint: disable-next-item(block-timestamp)
        if (block.timestamp > deadline) revert DeadlineExpired(block.timestamp, deadline);
    }

    /// @dev At least one side has to carry value; which side is the caller's choice. The single-token case
    ///      is simply the other side being zero, so it needs no separate entry point.
    function _checkDesiredAmounts(uint256 amountA, uint256 amountB) private pure {
        if (amountA == 0 && amountB == 0) revert ZeroAmount();
    }

    function _checkTokenPair(address tokenA, address tokenB) private pure {
        if (tokenA == address(0)) revert ZeroTokenAAddress();
        if (tokenB == address(0)) revert ZeroTokenBAddress();
        if (tokenA == tokenB) revert IdenticalTokens(tokenA);
    }

    function _checkMemberId(uint256 memberId) private view {
        // Existence only: core lets anyone add to an existing position, so the Hub does not require the
        // caller to hold the NFT.
        // forge-lint: disable-next-item(unused-return)
        IMemberNFT(MEMBER_NFT_ADDRESS).ownerOf(memberId);
    }

    /// @dev BNB is the root parent token, not any LOVE20 token, so the native branch only applies to a
    ///      community token whose parent is the wrapped native token. Checked before the pair is looked up
    ///      and before `msg.value` is wrapped, so a mismatched token fails on its own terms.
    function _checkNativeParent(address tokenAddress) private view {
        address parentTokenAddress = ILOVE20Token(tokenAddress).PARENT_TOKEN_ADDRESS();
        if (parentTokenAddress != WRAPPED_NATIVE_ADDRESS) revert NativeInputUnsupported(parentTokenAddress);
    }

    function _checkPromisedWaitingPhases(uint256 promisedWaitingPhases) private view {
        uint256 minPhases = IStake(STAKE_ADDRESS).PROMISED_WAITING_PHASES_MIN();
        uint256 maxPhases = IStake(STAKE_ADDRESS).PROMISED_WAITING_PHASES_MAX();
        if (promisedWaitingPhases < minPhases || promisedWaitingPhases > maxPhases) {
            revert InvalidPromisedWaitingPhases(promisedWaitingPhases, minPhases, maxPhases);
        }
    }

    function _checkRegisteredToken(address tokenAddress) private view {
        if (!ILaunch(LAUNCH_ADDRESS).isLOVE20Token(tokenAddress)) revert TokenNotRegistered(tokenAddress);
    }

    // ---------------------------------------------------------------------------------------------
    // contexts
    // ---------------------------------------------------------------------------------------------

    /// @dev The staking path is scoped to one community: its pair is guaranteed by `Launch`, so a missing
    ///      pair is a misconfiguration, not a cold start. Zero reserves are allowed (first liquidity).
    function _stakeContext(address tokenAddress) private view returns (StakeContext memory context) {
        _checkRegisteredToken(tokenAddress);

        context.tokenAddress = tokenAddress;
        context.parentTokenAddress = ILOVE20Token(tokenAddress).PARENT_TOKEN_ADDRESS();
        context.balanceTokenBefore = IERC20(tokenAddress).balanceOf(address(this));
        context.balanceParentBefore = IERC20(context.parentTokenAddress).balanceOf(address(this));

        address pairAddress = IUniswapV2Factory(PAIR_FACTORY_ADDRESS).getPair(
            tokenAddress, context.parentTokenAddress
        );
        if (pairAddress == address(0)) revert PairMissing(tokenAddress);
        context.pairAddress = pairAddress;

        (uint256 reserveToken, uint256 reserveParent) = _reservesOf(pairAddress, tokenAddress);
        context.reserveToken = reserveToken;
        context.reserveParent = reserveParent;
        context.hasLiquidity = reserveToken != 0 || reserveParent != 0;
    }

    /// @dev The LP path is generic: a missing pair is a legitimate cold start (the router creates it), so
    ///      `hasLiquidity == false` covers both "no pair" and "pair with zero reserves".
    function _pairContext(address tokenA, address tokenB) private view returns (HubPair memory pool) {
        pool.tokenA = tokenA;
        pool.tokenB = tokenB;
        pool.balanceABefore = IERC20(tokenA).balanceOf(address(this));
        pool.balanceBBefore = IERC20(tokenB).balanceOf(address(this));

        address pairAddress = IUniswapV2Factory(PAIR_FACTORY_ADDRESS).getPair(tokenA, tokenB);
        pool.pairAddress = pairAddress;
        if (pairAddress == address(0)) return pool;

        (uint256 reserveA, uint256 reserveB) = _reservesOf(pairAddress, tokenA);
        pool.reserveA = reserveA;
        pool.reserveB = reserveB;
        pool.hasLiquidity = reserveA != 0 || reserveB != 0;
    }

    function _reservesOf(address pairAddress, address tokenA)
        private
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        if (tokenA == pair.token0()) {
            return (uint256(reserve0), uint256(reserve1));
        }
        return (uint256(reserve1), uint256(reserve0));
    }

    /// @dev The event root key for an LP fact. When the pair did not exist on entry the router created it
    ///      during this call, so it is read back once. Only the first ever LP for a pair pays for this.
    function _resolvedPairAddress(HubPair memory pool) private view returns (address pairAddress) {
        if (pool.pairAddress != address(0)) return pool.pairAddress;
        pairAddress = IUniswapV2Factory(PAIR_FACTORY_ADDRESS).getPair(pool.tokenA, pool.tokenB);
    }

    // ---------------------------------------------------------------------------------------------
    // preparation: swap the excess side so both sides match the pool ratio
    // ---------------------------------------------------------------------------------------------

    function _prepare(HubPair memory pool, uint256 amountADesired, uint256 amountBDesired, uint256 deadline)
        private
        returns (HubAmounts memory amounts)
    {
        _swapToBalance(pool, amountADesired, amountBDesired, deadline);
        return _readPrepared(pool);
    }

    function _prepareStake(
        StakeContext memory context,
        uint256 tokenAmountDesired,
        uint256 parentTokenAmountDesired,
        uint256 deadline
    ) private returns (HubAmounts memory amounts) {
        _swapToBalanceStake(context, tokenAmountDesired, parentTokenAmountDesired, deadline);
        return _readPreparedStake(context);
    }

    /// @dev `prepared` is a balance delta over the whole call: whatever core or the router does not pull
    ///      stays on the Hub and is exactly the remainder.
    function _readPrepared(HubPair memory pool) private view returns (HubAmounts memory amounts) {
        amounts.preparedAmountA = IERC20(pool.tokenA).balanceOf(address(this)) - pool.balanceABefore;
        amounts.preparedAmountB = IERC20(pool.tokenB).balanceOf(address(this)) - pool.balanceBBefore;
    }

    function _readPreparedStake(StakeContext memory context) private view returns (HubAmounts memory amounts) {
        amounts.preparedAmountA =
            IERC20(context.tokenAddress).balanceOf(address(this)) - context.balanceTokenBefore;
        amounts.preparedAmountB =
            IERC20(context.parentTokenAddress).balanceOf(address(this)) - context.balanceParentBefore;
    }

    function _readRemainder(HubPair memory pool, HubAmounts memory amounts) private view {
        amounts.remainingAmountA = IERC20(pool.tokenA).balanceOf(address(this)) - pool.balanceABefore;
        amounts.remainingAmountB = IERC20(pool.tokenB).balanceOf(address(this)) - pool.balanceBBefore;
    }

    function _readRemainderStake(StakeContext memory context, HubAmounts memory amounts) private view {
        amounts.remainingAmountA =
            IERC20(context.tokenAddress).balanceOf(address(this)) - context.balanceTokenBefore;
        amounts.remainingAmountB =
            IERC20(context.parentTokenAddress).balanceOf(address(this)) - context.balanceParentBefore;
    }

    function _swapToBalance(HubPair memory pool, uint256 amountADesired, uint256 amountBDesired, uint256 deadline)
        private
    {
        if (!pool.hasLiquidity) return;
        (bool swapAForB, uint256 amountToSwap) =
            _swapPlan(pool.reserveA, pool.reserveB, amountADesired, amountBDesired);
        _executeSwap(pool.tokenA, pool.tokenB, swapAForB, amountToSwap, deadline);
    }

    function _swapToBalanceStake(
        StakeContext memory context,
        uint256 tokenAmountDesired,
        uint256 parentTokenAmountDesired,
        uint256 deadline
    ) private {
        if (!context.hasLiquidity) return;
        (bool swapTokenForParent, uint256 amountToSwap) =
            _swapPlan(context.reserveToken, context.reserveParent, tokenAmountDesired, parentTokenAmountDesired);
        _executeSwap(
            context.tokenAddress, context.parentTokenAddress, swapTokenForParent, amountToSwap, deadline
        );
    }

    function _executeSwap(
        address tokenA,
        address tokenB,
        bool swapAForB,
        uint256 amountToSwap,
        uint256 deadline
    ) private {
        if (amountToSwap == 0) return;

        address tokenIn = swapAForB ? tokenA : tokenB;
        address tokenOut = swapAForB ? tokenB : tokenA;

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        _approveToken(tokenIn, address(ROUTER_ADDRESS), amountToSwap);
        // `amountOutMin = 1` only asserts a non-zero output. Price protection is the caller's endpoint
        // minimum (`tokenAmountMin` / `amountAMin`), checked after the deposit against what actually
        // entered; predicting the output here would duplicate the router's arithmetic and still not
        // stop a sandwich that already moved the pool before this call.
        ROUTER_ADDRESS.swapExactTokensForTokens(amountToSwap, 1, path, address(this), deadline);
        _approveToken(tokenIn, address(ROUTER_ADDRESS), 0);
    }

    /// @dev Decides which side is in excess and by how much has to be swapped so both sides end up in the
    ///      pool's ratio. A single-sided input is the special case where the other desired amount is zero.
    function _swapPlan(uint256 reserveA, uint256 reserveB, uint256 amountADesired, uint256 amountBDesired)
        private
        view
        returns (bool swapAForB, uint256 amountToSwap)
    {
        if (amountADesired > UNISWAP_V2_MAX_RESERVE || amountBDesired > UNISWAP_V2_MAX_RESERVE) {
            revert AmountExceeded(
                amountADesired > amountBDesired ? amountADesired : amountBDesired, UNISWAP_V2_MAX_RESERVE
            );
        }
        // A * reserveB >= reserveA * B means A is (weakly) the excess side.
        if (amountADesired * reserveB >= reserveA * amountBDesired) {
            swapAForB = true;
            amountToSwap = _amountToSwap(reserveA, reserveB, amountADesired, amountBDesired);
        } else {
            swapAForB = false;
            amountToSwap = _amountToSwap(reserveB, reserveA, amountBDesired, amountADesired);
        }
        if (amountToSwap != 0 && amountToSwap > (swapAForB ? amountADesired : amountBDesired)) {
            revert ZeroSwapOutput();
        }
    }

    /// @dev Closed form for "swap exactly enough to balance the pair afterwards", so a single input (or an
    ///      unbalanced double input) funds both sides. Solved from the constant-product invariant with the
    ///      fee `F/D`:
    ///
    ///        x = ( sqrt( r^2 * (F+D)^2 + 4*F*D*r*I/(rOut + b) ) - r*(F+D) ) / (2F)
    ///
    ///      where `I = a*rOut - r*b` and `b` is the other side's desired amount. With `b = 0` this reduces
    ///      to the single-token solution; with `F/D = 997/1000` it reduces to the classic Uniswap V2 form.
    ///
    ///      The fee is stored as two 1e18 ratios (LP part and protocol part) because that is how a
    ///      deployment is configured, but the arithmetic runs on the reduced integers: `F/D` is their
    ///      complement in lowest terms. Doing it this way is exact — routing the 1e18 factor through the
    ///      root would lose the low wei and can even underflow.
    ///
    ///      Overflow: `r^2*(F+D)^2` is the dominant term. At `r = uint112.max` it stays inside uint256 for
    ///      `F+D <= 65536`, which the constructor enforces. The real profiles are 799..1997.
    function _amountToSwap(uint256 reserveIn, uint256 reserveOut, uint256 amountIn, uint256 amountOutAlready)
        private
        view
        returns (uint256 amountToSwap)
    {
        if (reserveIn == 0 || reserveOut == 0) return 0;

        uint256 imbalance = amountIn * reserveOut - reserveIn * amountOutAlready;
        if (imbalance == 0) return 0;

        (uint256 feeNumerator, uint256 feeDenominator) = _swapFeeFraction();
        uint256 sum = feeNumerator + feeDenominator;

        uint256 inner = reserveIn * reserveIn * sum * sum
            + (4 * feeNumerator * feeDenominator * reserveIn * imbalance) / (reserveOut + amountOutAlready);

        return (Math.sqrt(inner) - reserveIn * sum) / (2 * feeNumerator);
    }

    /// @dev The swap fee `F/D` in lowest terms. The two configured ratios sum to the fee the pair charges;
    ///      `F = D - (lp + proto)` and `D = 1e18` reduce to small integers for every real profile
    ///      (`997/1000`, `399/400`, `499/500`), which is what keeps the closed form exact and bounded.
    function _swapFeeFraction() private view returns (uint256 feeNumerator, uint256 feeDenominator) {
        feeDenominator = PRECISION;
        feeNumerator = PRECISION - SWAP_FEE_FOR_LP_RATIO - SWAP_FEE_FOR_PROTOCOL_RATIO;
        uint256 divisor = _gcd(feeNumerator, feeDenominator);
        return (feeNumerator / divisor, feeDenominator / divisor);
    }

    /// @dev The protocol's cut of the growth in sqrt(k), as `k/a` in lowest terms. Zero when the DEX has its
    ///      protocol fee permanently off, which makes the whole `_mintFee` branch a no-op.
    function _protocolFeeFraction() private view returns (uint256 feeNumerator, uint256 feeDenominator) {
        uint256 protocolRatio = SWAP_FEE_FOR_PROTOCOL_RATIO;
        if (protocolRatio == 0) return (0, 1);
        uint256 divisor = _gcd(protocolRatio, SWAP_FEE_FOR_LP_RATIO);
        return (protocolRatio / divisor, SWAP_FEE_FOR_LP_RATIO / divisor);
    }

    function _gcd(uint256 a, uint256 b) private pure returns (uint256) {
        while (b != 0) {
            (a, b) = (b, a % b);
        }
        return a;
    }

    /// @dev `F + D` after reducing `F/D` to lowest terms, which is the bound the closed form needs.
    function _swapFeeSumBound(uint256 swapFeeRatio) private pure returns (uint256) {
        uint256 divisor = _gcd(swapFeeRatio, PRECISION);
        return swapFeeRatio / divisor + PRECISION / divisor;
    }

    function _optimalAmounts(
        uint256 reserveA,
        uint256 reserveB,
        uint256 amountADesired,
        uint256 amountBDesired
    ) private pure returns (uint256 amountA, uint256 amountB) {
        uint256 amountBOptimal = (amountADesired * reserveB) / reserveA;
        if (amountBOptimal <= amountBDesired) {
            return (amountADesired, amountBOptimal);
        }
        uint256 amountAOptimal = (amountBDesired * reserveA) / reserveB;
        return (amountAOptimal, amountBDesired);
    }

    function _liquidityMinted(
        uint256 reserveA,
        uint256 reserveB,
        uint256 totalSupply,
        uint256 amountA,
        uint256 amountB
    ) private pure returns (uint256 liquidity) {
        if (totalSupply == 0) {
            return Math.sqrt(amountA * amountB) - UNISWAP_V2_MINIMUM_LIQUIDITY;
        }
        liquidity =
            Math.min((amountA * totalSupply) / reserveA, (amountB * totalSupply) / reserveB);
    }

    /// @dev `totalSupply` after the pair's own `_mintFee`. The protocol takes a configured share of the
    ///      growth in sqrt(k) and mints it as LP, so the caller's proportional share is smaller than it
    ///      would otherwise be. Written with `k/a` in lowest terms:
    ///
    ///        feeLp = supply * (rootK - rootKLast) * k / (a * rootK + k * rootKLast)
    ///
    ///      which is exactly Uniswap V2's `supply*(rootK-rootKLast)/(5*rootK+rootKLast)` when `k/a = 1/5`,
    ///      and Pancake mainnet's `8/(17r+8rLast)` when `k/a = 8/17`. A zero `k` means the DEX takes no
    ///      protocol fee at all, and the branch returns `totalSupply` untouched.
    function _totalSupplyAfterFeeMint(HubPair memory pool, uint256 reserveA, uint256 reserveB)
        private
        view
        returns (uint256 totalSupply)
    {
        totalSupply = IUniswapV2Pair(pool.pairAddress).totalSupply();

        (uint256 feeNumerator, uint256 feeDenominator) = _protocolFeeFraction();
        if (feeNumerator == 0) return totalSupply;

        uint256 kLast = IUniswapV2Pair(pool.pairAddress).kLast();
        if (kLast == 0) return totalSupply;

        uint256 rootK = Math.sqrt(reserveA * reserveB);
        uint256 rootKLast = Math.sqrt(kLast);
        if (rootK <= rootKLast) return totalSupply;

        uint256 numerator = totalSupply * (rootK - rootKLast) * feeNumerator;
        uint256 denominator = feeDenominator * rootK + feeNumerator * rootKLast;
        return totalSupply + numerator / denominator;
    }

    // ---------------------------------------------------------------------------------------------
    // staking
    // ---------------------------------------------------------------------------------------------

    /// @dev Reads the remainder and applies the caller's minimums as an endpoint check: what actually
    ///      entered the stake or the pool is `prepared - remaining`, which is precisely the semantics of
    ///      `tokenAmountMin` / `parentTokenAmountMin`. Sharing one implementation across the staking and
    ///      the LP path is what keeps the rule from drifting between them.
    function _settle(
        HubAmounts memory amounts,
        uint256 amountAMin,
        uint256 amountBMin,
        bool staking
    ) private pure {
        uint256 enteredA = amounts.preparedAmountA - amounts.remainingAmountA;
        uint256 enteredB = amounts.preparedAmountB - amounts.remainingAmountB;
        if (enteredA < amountAMin) {
            if (staking) revert InsufficientTokenAmount(enteredA, amountAMin);
            revert InsufficientAmountA(enteredA, amountAMin);
        }
        if (enteredB < amountBMin) {
            if (staking) revert InsufficientParentTokenAmount(enteredB, amountBMin);
            revert InsufficientAmountB(enteredB, amountBMin);
        }
    }

    function _stake(
        StakeContext memory context,
        HubAmounts memory amounts,
        uint256 promisedWaitingPhases,
        uint256 memberId,
        uint256 tokenAmountMin,
        uint256 parentAmountMin
    ) private returns (uint256 govVotesAdded, uint256 liquiditySharesAdded) {
        address stakeAddress = STAKE_ADDRESS;
        _approveToken(context.tokenAddress, stakeAddress, amounts.preparedAmountA);
        _approveToken(context.parentTokenAddress, stakeAddress, amounts.preparedAmountB);

        (govVotesAdded, liquiditySharesAdded) = IStake(stakeAddress).stakeLiquidity(
            context.tokenAddress,
            amounts.preparedAmountA,
            amounts.preparedAmountB,
            promisedWaitingPhases,
            memberId
        );

        _approveToken(context.tokenAddress, stakeAddress, 0);
        _approveToken(context.parentTokenAddress, stakeAddress, 0);
        _readRemainderStake(context, amounts);
        _settle(amounts, tokenAmountMin, parentAmountMin, true);
    }

    function _addLiquidity(
        HubPair memory pool,
        HubAmounts memory amounts,
        address to,
        uint256 deadline,
        uint256 amountAMin,
        uint256 amountBMin
    ) private returns (uint256 liquidity) {
        address tokenA = pool.tokenA;
        address tokenB = pool.tokenB;
        address routerAddress = address(ROUTER_ADDRESS);

        _approveToken(tokenA, routerAddress, amounts.preparedAmountA);
        _approveToken(tokenB, routerAddress, amounts.preparedAmountB);

        // The pool-level minimums stay at zero. The caller's minimums are endpoint amounts for the whole
        // chain (`prepared - remaining`), and `_settle` is their single implementation for both paths;
        // passing them down as `amountAMin`/`amountBMin` would put the same rule in two places and surface
        // a router-specific revert instead of a Hub error.
        (,, liquidity) = ROUTER_ADDRESS.addLiquidity(
            tokenA, tokenB, amounts.preparedAmountA, amounts.preparedAmountB, 0, 0, to, deadline
        );

        _approveToken(tokenA, routerAddress, 0);
        _approveToken(tokenB, routerAddress, 0);
        _readRemainder(pool, amounts);
        _settle(amounts, amountAMin, amountBMin, false);
    }

    // ---------------------------------------------------------------------------------------------
    // quotes
    // ---------------------------------------------------------------------------------------------

    function _quoteLp(HubPair memory pool, uint256 amountADesired, uint256 amountBDesired)
        private
        view
        returns (LpQuote memory quote)
    {
        quote.hasLiquidity = pool.hasLiquidity;

        // No reserves: the whole deposit goes in untouched, so the quote is the input itself. The router
        // creates the pair when it is missing, so this is the cold-start branch of both "no pair" and
        // "pair with zero reserves".
        if (!pool.hasLiquidity) {
            if (amountADesired == 0 || amountBDesired == 0) {
                revert PairWithoutLiquidity(pool.tokenA, pool.tokenB);
            }
            quote.preparedAmountA = amountADesired;
            quote.preparedAmountB = amountBDesired;
            quote.usableAmountA = amountADesired;
            quote.usableAmountB = amountBDesired;
            quote.expectedLiquidity =
                Math.sqrt(amountADesired * amountBDesired) - UNISWAP_V2_MINIMUM_LIQUIDITY;
            quote.suggestedAmountAMin = amountADesired;
            quote.suggestedAmountBMin = amountBDesired;
            return quote;
        }

        (bool swapAForB, uint256 amountToSwap) =
            _swapPlan(pool.reserveA, pool.reserveB, amountADesired, amountBDesired);

        uint256 reserveAAfter = pool.reserveA;
        uint256 reserveBAfter = pool.reserveB;
        uint256 preparedA = amountADesired;
        uint256 preparedB = amountBDesired;

        if (amountToSwap > 0) {
            quote.willSwap = true;
            quote.amountToSwap = amountToSwap;
            quote.swapTokenIn = swapAForB ? pool.tokenA : pool.tokenB;
            quote.swapTokenOut = swapAForB ? pool.tokenB : pool.tokenA;

            // The router is the authority on the output: asking it keeps the quote and the write equal to
            // the wei even if the configured fee ratios are slightly off for this deployment.
            uint256 amountOut = _routerAmountOut(quote.swapTokenIn, quote.swapTokenOut, amountToSwap);
            if (amountOut == 0) revert ZeroSwapOutput();
            quote.amountOutFromSwap = amountOut;

            if (swapAForB) {
                preparedA = amountADesired - amountToSwap;
                preparedB = amountBDesired + amountOut;
                reserveAAfter = pool.reserveA + amountToSwap;
                reserveBAfter = pool.reserveB - amountOut;
            } else {
                preparedA = amountADesired + amountOut;
                preparedB = amountBDesired - amountToSwap;
                reserveAAfter = pool.reserveA - amountOut;
                reserveBAfter = pool.reserveB + amountToSwap;
            }
        }

        quote.preparedAmountA = preparedA;
        quote.preparedAmountB = preparedB;

        (uint256 usableA, uint256 usableB) =
            _optimalAmounts(reserveAAfter, reserveBAfter, preparedA, preparedB);
        quote.usableAmountA = usableA;
        quote.usableAmountB = usableB;
        quote.suggestedAmountAMin = usableA;
        quote.suggestedAmountBMin = usableB;

        uint256 totalSupplyAfterFeeMint = _totalSupplyAfterFeeMint(pool, reserveAAfter, reserveBAfter);
        quote.expectedLiquidity =
            _liquidityMinted(reserveAAfter, reserveBAfter, totalSupplyAfterFeeMint, usableA, usableB);
    }

    function _stakeQuote(
        StakeContext memory context,
        uint256 tokenAmountDesired,
        uint256 parentTokenAmountDesired,
        uint256 memberId,
        uint256 promisedWaitingPhases
    ) private view returns (StakeLiquidityQuote memory quote) {
        LpQuote memory lpQuote = _stakeLpQuote(context, tokenAmountDesired, parentTokenAmountDesired);

        quote.hasLiquidity = lpQuote.hasLiquidity;
        quote.willSwap = lpQuote.willSwap;
        quote.swapTokenIn = lpQuote.swapTokenIn;
        quote.swapTokenOut = lpQuote.swapTokenOut;
        quote.amountToSwap = lpQuote.amountToSwap;
        quote.amountOutFromSwap = lpQuote.amountOutFromSwap;
        quote.preparedTokenAmount = lpQuote.preparedAmountA;
        quote.preparedParentTokenAmount = lpQuote.preparedAmountB;
        quote.usableTokenAmount = lpQuote.usableAmountA;
        quote.usableParentTokenAmount = lpQuote.usableAmountB;
        quote.expectedLiquidity = lpQuote.expectedLiquidity;
        quote.suggestedTokenAmountMin = lpQuote.suggestedAmountAMin;
        quote.suggestedParentAmountMin = lpQuote.suggestedAmountBMin;

        (uint256 totalLiquidityShares, , uint256 withdrawableLp, , , , , ) =
            IStake(STAKE_ADDRESS).totalStake(context.tokenAddress);
        (uint256 memberLiquidityShares, , uint256 currentPromisedWaitingPhases, , , , ) =
            IStake(STAKE_ADDRESS).memberStake(context.tokenAddress, memberId);

        quote.liquiditySharesAdded = totalLiquidityShares == 0 || withdrawableLp == 0
            ? quote.expectedLiquidity
            : (totalLiquidityShares * quote.expectedLiquidity) / withdrawableLp;
        quote.liquidityShares = memberLiquidityShares + quote.liquiditySharesAdded;
        quote.govVotesAdded = quote.liquidityShares * promisedWaitingPhases
            - memberLiquidityShares * currentPromisedWaitingPhases;
    }

    /// @dev The staking side of `_quoteLp`: same maths, but the pair is the community's and the two sides
    ///      are named token / parent.
    function _stakeLpQuote(
        StakeContext memory context,
        uint256 tokenAmountDesired,
        uint256 parentTokenAmountDesired
    ) private view returns (LpQuote memory quote) {
        HubPair memory pool = HubPair({
            tokenA: context.tokenAddress,
            tokenB: context.parentTokenAddress,
            pairAddress: context.pairAddress,
            hasLiquidity: context.hasLiquidity,
            balanceABefore: 0,
            balanceBBefore: 0,
            reserveA: context.reserveToken,
            reserveB: context.reserveParent
        });
        // The staking path requires an existing pair, but zero reserves are legal: `_quoteLp` treats them
        // as the cold-start branch, which is exactly what `Stake.stakeLiquidity` does with its own
        // `_optimalAmounts` when both reserves are zero.
        if (!context.hasLiquidity) {
            if (tokenAmountDesired == 0 || parentTokenAmountDesired == 0) {
                revert PairWithoutLiquidity(context.tokenAddress, context.parentTokenAddress);
            }
            quote.preparedAmountA = tokenAmountDesired;
            quote.preparedAmountB = parentTokenAmountDesired;
            quote.usableAmountA = tokenAmountDesired;
            quote.usableAmountB = parentTokenAmountDesired;
            quote.expectedLiquidity =
                Math.sqrt(tokenAmountDesired * parentTokenAmountDesired) - UNISWAP_V2_MINIMUM_LIQUIDITY;
            quote.suggestedAmountAMin = tokenAmountDesired;
            quote.suggestedAmountBMin = parentTokenAmountDesired;
            return quote;
        }
        return _quoteLp(pool, tokenAmountDesired, parentTokenAmountDesired);
    }

    function _routerAmountOut(address tokenIn, address tokenOut, uint256 amountIn)
        private
        view
        returns (uint256 amountOut)
    {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        return ROUTER_ADDRESS.getAmountsOut(amountIn, path)[1];
    }

    function _approveToken(address tokenAddress, address spender, uint256 amount) private {
        IERC20(tokenAddress).forceApprove(spender, amount);
    }

    function _refundTokens(address tokenA, address tokenB, HubAmounts memory amounts) private {
        _refundToken(tokenA, amounts.remainingAmountA);
        _refundToken(tokenB, amounts.remainingAmountB);
    }

    /// @dev The native branch returns the wrapped-native remainder as native currency: the shape of the
    ///      refund is decided by the function the caller used, never by an argument.
    function _refundNativeThenToken(address tokenAddress, HubAmounts memory amounts) private {
        if (amounts.remainingAmountB > 0) {
            IWrappedNative(WRAPPED_NATIVE_ADDRESS).withdraw(amounts.remainingAmountB);
            // forge-lint: disable-next-line(arbitrary-send-eth)
            (bool success,) = msg.sender.call{value: amounts.remainingAmountB}("");
            if (!success) revert NativeRefundFailed();
        }
        _refundToken(tokenAddress, amounts.remainingAmountA);
    }

    function _refundToken(address tokenAddress, uint256 amount) private {
        if (amount == 0) return;
        IERC20(tokenAddress).safeTransfer(msg.sender, amount);
    }
}
