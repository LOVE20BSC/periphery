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
    SingleTokenLpQuote,
    SingleTokenStakeLiquidityQuote
} from "./interfaces/ILOVE20Hub.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";
import {IWrappedNative} from "./interfaces/IWrappedNative.sol";

/// @dev One call's snapshot of the community pool. `balanceTokenBefore` / `balanceParentBefore` are the
///      Hub's own balances at entry, so every prepared / remaining amount is a plain balance delta and
///      core's conversion formula is never re-derived here.
struct HubPool {
    address tokenAddress;
    address parentTokenAddress;
    address pairAddress;
    uint256 balanceTokenBefore;
    uint256 balanceParentBefore;
    uint256 reserveToken;
    uint256 reserveParent;
}

/// @dev The four amounts one call reports. Computed once per call and read by the minimum check, by the
///      refund and by the event, which keeps the entry points inside the stack limit under the standard
///      optimizer without a second copy of the arithmetic.
struct HubAmounts {
    uint256 preparedTokenAmount;
    uint256 preparedParentTokenAmount;
    uint256 remainingTokenAmount;
    uint256 remainingParentTokenAmount;
}

contract LOVE20Hub is ReentrancyGuard, ILOVE20Hub {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant UNISWAP_V2_MINIMUM_LIQUIDITY = 1000;
    uint256 private constant UNISWAP_V2_MAX_RESERVE = type(uint112).max;

    /// @dev Bound on the swap leg only, as a 1e18 ratio (1%). The caller's minimums describe the endpoint
    ///      of the whole chain, so they cannot be passed down as `amountOutMin`: the pool cannot move
    ///      between reading the reserves and swapping inside one transaction, so `_amountOut` of the
    ///      pre-swap reserves is what the router should return, and this bound turns a sandwich on the
    ///      swap leg into a revert while leaving room for rounding.
    uint256 private constant SWAP_OUTPUT_TOLERANCE_RATIO = 1e16;

    address public immutable STAKE_ADDRESS;

    IUniswapV2Router02 public immutable ROUTER_ADDRESS;

    address public immutable PAIR_FACTORY_ADDRESS;

    address public immutable LAUNCH_ADDRESS;

    address public immutable MEMBER_NFT_ADDRESS;

    address public immutable WRAPPED_NATIVE_ADDRESS;

    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address stakeAddress) {
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

    function stakeLiquidityWithToken(StakeLiquidityWithTokenParams calldata params)
        external
        nonReentrant
        returns (uint256 govVotesAdded, uint256 liquiditySharesAdded)
    {
        _checkDeadline(params.deadline);
        _checkTokenInput(params.tokenAddress, params.inputTokenAddress, params.inputTokenAmount);
        _checkMemberId(params.memberId);

        HubPool memory pool = _hubPool(params.tokenAddress);
        _checkInputToken(pool, params.inputTokenAddress);
        IERC20(params.inputTokenAddress).safeTransferFrom(msg.sender, address(this), params.inputTokenAmount);
        HubAmounts memory amounts = _prepare(pool, params.inputTokenAddress, params.inputTokenAmount, params.deadline);

        (govVotesAdded, liquiditySharesAdded) = _stake(
            pool,
            amounts,
            params.promisedWaitingPhases,
            params.memberId,
            params.tokenAmountMin,
            params.parentTokenAmountMin
        );

        _refundTokens(pool, amounts);

        emit HubLiquidityStakedWithToken({
            tokenAddress: pool.tokenAddress,
            memberId: params.memberId,
            caller: msg.sender,
            preparedTokenAmount: amounts.preparedTokenAmount,
            preparedParentTokenAmount: amounts.preparedParentTokenAmount,
            remainingTokenAmount: amounts.remainingTokenAmount,
            remainingParentTokenAmount: amounts.remainingParentTokenAmount
        });
    }

    function stakeLiquidityWithNative(StakeLiquidityWithNativeParams calldata params)
        external
        payable
        nonReentrant
        returns (uint256 govVotesAdded, uint256 liquiditySharesAdded)
    {
        _checkDeadline(params.deadline);
        _checkNativeInput(params.tokenAddress, msg.value);
        _checkMemberId(params.memberId);
        _checkRegisteredToken(params.tokenAddress);
        _checkNativeParent(params.tokenAddress);

        HubPool memory pool = _hubPool(params.tokenAddress);
        HubAmounts memory amounts = _prepareNative(pool, params.deadline);

        (govVotesAdded, liquiditySharesAdded) = _stake(
            pool,
            amounts,
            params.promisedWaitingPhases,
            params.memberId,
            params.tokenAmountMin,
            params.parentTokenAmountMin
        );

        _refundNativeThenTokens(pool, amounts);

        emit HubLiquidityStakedWithNative({
            tokenAddress: pool.tokenAddress,
            memberId: params.memberId,
            caller: msg.sender,
            preparedTokenAmount: amounts.preparedTokenAmount,
            preparedParentTokenAmount: amounts.preparedParentTokenAmount,
            remainingTokenAmount: amounts.remainingTokenAmount,
            remainingParentTokenAmount: amounts.remainingParentTokenAmount
        });
    }

    function addLiquidityWithToken(AddLiquidityWithTokenParams calldata params)
        external
        nonReentrant
        returns (uint256 liquidity)
    {
        _checkDeadline(params.deadline);
        _checkTokenInput(params.tokenAddress, params.inputTokenAddress, params.inputTokenAmount);
        if (params.to == address(0)) revert ZeroRecipientAddress();

        HubPool memory pool = _hubPool(params.tokenAddress);
        _checkInputToken(pool, params.inputTokenAddress);
        IERC20(params.inputTokenAddress).safeTransferFrom(msg.sender, address(this), params.inputTokenAmount);
        HubAmounts memory amounts = _prepare(pool, params.inputTokenAddress, params.inputTokenAmount, params.deadline);

        liquidity = _addLiquidity(
            pool, amounts, params.to, params.deadline, params.tokenAmountMin, params.parentTokenAmountMin
        );

        _refundTokens(pool, amounts);

        emit HubLiquidityAddedWithToken({
            tokenAddress: pool.tokenAddress,
            to: params.to,
            caller: msg.sender,
            preparedTokenAmount: amounts.preparedTokenAmount,
            preparedParentTokenAmount: amounts.preparedParentTokenAmount,
            remainingTokenAmount: amounts.remainingTokenAmount,
            remainingParentTokenAmount: amounts.remainingParentTokenAmount,
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
        _checkNativeInput(params.tokenAddress, msg.value);
        if (params.to == address(0)) revert ZeroRecipientAddress();
        _checkRegisteredToken(params.tokenAddress);
        _checkNativeParent(params.tokenAddress);

        HubPool memory pool = _hubPool(params.tokenAddress);
        HubAmounts memory amounts = _prepareNative(pool, params.deadline);

        liquidity = _addLiquidity(
            pool, amounts, params.to, params.deadline, params.tokenAmountMin, params.parentTokenAmountMin
        );

        _refundNativeThenTokens(pool, amounts);

        emit HubLiquidityAddedWithNative({
            tokenAddress: pool.tokenAddress,
            to: params.to,
            caller: msg.sender,
            preparedTokenAmount: amounts.preparedTokenAmount,
            preparedParentTokenAmount: amounts.preparedParentTokenAmount,
            remainingTokenAmount: amounts.remainingTokenAmount,
            remainingParentTokenAmount: amounts.remainingParentTokenAmount,
            liquidity: liquidity
        });
    }

    function quoteSingleTokenLp(address tokenAddress, address inputTokenAddress, uint256 inputTokenAmount)
        external
        view
        returns (SingleTokenLpQuote memory quote)
    {
        _checkTokenInput(tokenAddress, inputTokenAddress, inputTokenAmount);
        HubPool memory pool = _hubPool(tokenAddress);
        return _quoteSingleToken(pool, inputTokenAddress, inputTokenAmount);
    }

    function quoteSingleTokenLpWithNative(address tokenAddress, uint256 inputNativeTokenAmount)
        external
        view
        returns (SingleTokenLpQuote memory quote)
    {
        _checkNativeInput(tokenAddress, inputNativeTokenAmount);
        _checkRegisteredToken(tokenAddress);
        _checkNativeParent(tokenAddress);
        HubPool memory pool = _hubPool(tokenAddress);
        return _quoteSingleToken(pool, WRAPPED_NATIVE_ADDRESS, inputNativeTokenAmount);
    }

    function quoteSingleTokenStakeLiquidity(
        address tokenAddress,
        address inputTokenAddress,
        uint256 inputTokenAmount,
        uint256 memberId,
        uint256 promisedWaitingPhases
    ) external view returns (SingleTokenStakeLiquidityQuote memory quote) {
        _checkTokenInput(tokenAddress, inputTokenAddress, inputTokenAmount);
        _checkMemberId(memberId);
        _checkPromisedWaitingPhases(promisedWaitingPhases);
        HubPool memory pool = _hubPool(tokenAddress);
        return _stakeQuote(
            _quoteSingleToken(pool, inputTokenAddress, inputTokenAmount),
            tokenAddress,
            memberId,
            promisedWaitingPhases
        );
    }

    function quoteSingleTokenStakeLiquidityWithNative(
        address tokenAddress,
        uint256 inputNativeTokenAmount,
        uint256 memberId,
        uint256 promisedWaitingPhases
    ) external view returns (SingleTokenStakeLiquidityQuote memory quote) {
        _checkNativeInput(tokenAddress, inputNativeTokenAmount);
        _checkRegisteredToken(tokenAddress);
        _checkNativeParent(tokenAddress);
        _checkMemberId(memberId);
        _checkPromisedWaitingPhases(promisedWaitingPhases);
        HubPool memory pool = _hubPool(tokenAddress);
        return _stakeQuote(
            _quoteSingleToken(pool, WRAPPED_NATIVE_ADDRESS, inputNativeTokenAmount),
            tokenAddress,
            memberId,
            promisedWaitingPhases
        );
    }

    function _checkDeadline(uint256 deadline) private view {
        // A deadline is the caller's own upper bound on when the swap and the deposit may land; shifting
        // it by a validator's timestamp window only re-times the caller's own transaction.
        // forge-lint: disable-next-item(block-timestamp)
        if (block.timestamp > deadline) revert DeadlineExpired(block.timestamp, deadline);
    }

    function _checkTokenInput(address tokenAddress, address inputTokenAddress, uint256 inputTokenAmount)
        private
        pure
    {
        if (tokenAddress == address(0)) revert ZeroTokenAddress();
        if (inputTokenAddress == address(0)) revert ZeroInputTokenAddress();
        if (inputTokenAmount == 0) revert ZeroInputTokenAmount();
    }

    function _checkNativeInput(address tokenAddress, uint256 nativeTokenAmount) private pure {
        if (tokenAddress == address(0)) revert ZeroTokenAddress();
        if (nativeTokenAmount == 0) revert ZeroNativeTokenAmount();
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

    function _checkInputToken(HubPool memory pool, address inputTokenAddress) private pure {
        if (inputTokenAddress != pool.tokenAddress && inputTokenAddress != pool.parentTokenAddress) {
            revert InvalidInputTokenAddress(inputTokenAddress);
        }
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

    function _hubPool(address tokenAddress) private view returns (HubPool memory pool) {
        _checkRegisteredToken(tokenAddress);

        pool.tokenAddress = tokenAddress;
        pool.parentTokenAddress = ILOVE20Token(tokenAddress).PARENT_TOKEN_ADDRESS();
        pool.balanceTokenBefore = IERC20(tokenAddress).balanceOf(address(this));
        pool.balanceParentBefore = IERC20(pool.parentTokenAddress).balanceOf(address(this));

        address pairAddress = IUniswapV2Factory(PAIR_FACTORY_ADDRESS).getPair(tokenAddress, pool.parentTokenAddress);
        if (pairAddress == address(0)) revert PairMissing(tokenAddress);
        pool.pairAddress = pairAddress;

        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        if (reserve0 == 0 && reserve1 == 0) revert PairEmpty(tokenAddress);

        if (tokenAddress == pair.token0()) {
            pool.reserveToken = uint256(reserve0);
            pool.reserveParent = uint256(reserve1);
        } else {
            pool.reserveToken = uint256(reserve1);
            pool.reserveParent = uint256(reserve0);
        }
    }

    function _prepare(HubPool memory pool, address inputTokenAddress, uint256 inputTokenAmount, uint256 deadline)
        private
        returns (HubAmounts memory amounts)
    {
        _checkInputToken(pool, inputTokenAddress);
        _swapToBalance(pool, inputTokenAddress == pool.tokenAddress, inputTokenAmount, deadline);
        return _readPrepared(pool);
    }

    function _prepareNative(HubPool memory pool, uint256 deadline) private returns (HubAmounts memory) {
        IWrappedNative(WRAPPED_NATIVE_ADDRESS).deposit{value: msg.value}();
        _swapToBalance(pool, false, msg.value, deadline);
        return _readPrepared(pool);
    }

    /// @dev `prepared` is a balance delta over the whole call: whatever core or the router does not pull
    ///      stays on the Hub and is exactly the remainder. No propagation of core's conversion formula.
    function _readPrepared(HubPool memory pool) private view returns (HubAmounts memory amounts) {
        amounts.preparedTokenAmount = IERC20(pool.tokenAddress).balanceOf(address(this)) - pool.balanceTokenBefore;
        amounts.preparedParentTokenAmount =
            IERC20(pool.parentTokenAddress).balanceOf(address(this)) - pool.balanceParentBefore;
    }

    /// @dev Reads the remainder and applies the caller's minimums as an endpoint check: what actually
    ///      entered the stake or the pool is `prepared - remaining`, which is precisely the semantics of
    ///      `tokenAmountMin` / `parentTokenAmountMin`. Sharing one implementation across all four entry
    ///      points is what keeps the rule from drifting between the stake and the LP path.
    function _settle(HubAmounts memory amounts, uint256 tokenAmountMin, uint256 parentAmountMin) private pure {
        if (amounts.preparedTokenAmount - amounts.remainingTokenAmount < tokenAmountMin) {
            revert InsufficientTokenAmount(
                amounts.preparedTokenAmount - amounts.remainingTokenAmount, tokenAmountMin
            );
        }
        if (amounts.preparedParentTokenAmount - amounts.remainingParentTokenAmount < parentAmountMin) {
            revert InsufficientParentTokenAmount(
                amounts.preparedParentTokenAmount - amounts.remainingParentTokenAmount, parentAmountMin
            );
        }
    }

    function _readRemainder(HubPool memory pool, HubAmounts memory amounts) private view {
        amounts.remainingTokenAmount = IERC20(pool.tokenAddress).balanceOf(address(this)) - pool.balanceTokenBefore;
        amounts.remainingParentTokenAmount =
            IERC20(pool.parentTokenAddress).balanceOf(address(this)) - pool.balanceParentBefore;
    }

    function _swapToBalance(HubPool memory pool, bool inputTokenIsToken, uint256 inputTokenAmount, uint256 deadline)
        private
    {
        (uint256 amountToSwap, uint256 amountOutFromSwap) =
            _swapPlan(pool.reserveToken, pool.reserveParent, inputTokenIsToken, inputTokenAmount);
        if (amountToSwap == 0) return;

        address tokenIn = inputTokenIsToken ? pool.tokenAddress : pool.parentTokenAddress;
        address tokenOut = inputTokenIsToken ? pool.parentTokenAddress : pool.tokenAddress;

        uint256 amountOutMin = (amountOutFromSwap * (PRECISION - SWAP_OUTPUT_TOLERANCE_RATIO)) / PRECISION;
        if (amountOutMin == 0) amountOutMin = 1;

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        _approveToken(tokenIn, address(ROUTER_ADDRESS), amountToSwap);
        ROUTER_ADDRESS.swapExactTokensForTokens(amountToSwap, amountOutMin, path, address(this), deadline);
        _approveToken(tokenIn, address(ROUTER_ADDRESS), 0);
    }

    function _swapPlan(uint256 reserveToken, uint256 reserveParent, bool inputTokenIsToken, uint256 inputTokenAmount)
        private
        pure
        returns (uint256 amountToSwap, uint256 amountOutFromSwap)
    {
        // A single input has to fit the pair's own reserve width: Uniswap V2 stores reserves in `uint112`,
        // so a larger input could not be converted against them at all.
        if (inputTokenAmount > UNISWAP_V2_MAX_RESERVE) {
            revert AmountExceeded(inputTokenAmount, UNISWAP_V2_MAX_RESERVE);
        }
        if (inputTokenIsToken) {
            amountToSwap = _amountToSwap(reserveToken, reserveParent, inputTokenAmount);
            amountOutFromSwap = _amountOut(amountToSwap, reserveToken, reserveParent);
        } else {
            amountToSwap = _amountToSwap(reserveParent, reserveToken, inputTokenAmount);
            amountOutFromSwap = _amountOut(amountToSwap, reserveParent, reserveToken);
        }
        if (amountToSwap > 0 && amountOutFromSwap == 0) revert ZeroSwapOutput();
    }

    /// @dev Closed form for "swap exactly enough to balance the pair afterwards", so a single input funds
    ///      both sides. Solved from the constant-product invariant with the 997/1000 fee: the swap size
    ///      that leaves the residual ratio equal to the pool ratio is the stable root below. Both
    ///      reserves are non-zero by the time this runs (`_hubPool` rejects an empty pair), and the
    ///      caller has already chosen the scarce side.
    function _amountToSwap(uint256 reserveIn, uint256 reserveOut, uint256 amountIn)
        private
        pure
        returns (uint256 amountToSwap)
    {
        uint256 imbalance = amountIn * reserveOut;
        return (
            Math.sqrt(reserveIn * reserveIn * 3_988_009 + Math.mulDiv(reserveIn * 3_988_000, imbalance, reserveOut))
                - reserveIn * 1_997
        ) / 1_994;
    }

    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        private
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) return 0;
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    function _optimalAmounts(
        uint256 reserveToken,
        uint256 reserveParent,
        uint256 tokenAmountDesired,
        uint256 parentTokenAmountDesired
    ) private pure returns (uint256 tokenAmount, uint256 parentTokenAmount) {
        uint256 parentTokenAmountOptimal = (tokenAmountDesired * reserveParent) / reserveToken;
        if (parentTokenAmountOptimal <= parentTokenAmountDesired) {
            return (tokenAmountDesired, parentTokenAmountOptimal);
        }
        uint256 tokenAmountOptimal = (parentTokenAmountDesired * reserveToken) / reserveParent;
        return (tokenAmountOptimal, parentTokenAmountDesired);
    }

    function _liquidityMinted(
        uint256 reserveToken,
        uint256 reserveParent,
        uint256 totalSupply,
        uint256 tokenAmount,
        uint256 parentTokenAmount
    ) private pure returns (uint256 liquidity) {
        if (totalSupply == 0) {
            return Math.sqrt(tokenAmount * parentTokenAmount) - UNISWAP_V2_MINIMUM_LIQUIDITY;
        }
        liquidity = Math.min(
            (tokenAmount * totalSupply) / reserveToken, (parentTokenAmount * totalSupply) / reserveParent
        );
    }

    function _totalSupplyAfterFeeMint(HubPool memory pool, uint256 reserveToken, uint256 reserveParent)
        private
        view
        returns (uint256 totalSupply)
    {
        totalSupply = IUniswapV2Pair(pool.pairAddress).totalSupply();

        if (IUniswapV2Factory(PAIR_FACTORY_ADDRESS).feeTo() == address(0)) return totalSupply;

        uint256 kLast = IUniswapV2Pair(pool.pairAddress).kLast();
        if (kLast == 0) return totalSupply;

        uint256 rootK = Math.sqrt(reserveToken * reserveParent);
        uint256 rootKLast = Math.sqrt(kLast);
        if (rootK <= rootKLast) return totalSupply;

        return totalSupply + (totalSupply * (rootK - rootKLast)) / (rootK * 5 + rootKLast);
    }

    function _stake(
        HubPool memory pool,
        HubAmounts memory amounts,
        uint256 promisedWaitingPhases,
        uint256 memberId,
        uint256 tokenAmountMin,
        uint256 parentAmountMin
    ) private returns (uint256 govVotesAdded, uint256 liquiditySharesAdded) {
        address stakeAddress = STAKE_ADDRESS;
        _approveToken(pool.tokenAddress, stakeAddress, amounts.preparedTokenAmount);
        _approveToken(pool.parentTokenAddress, stakeAddress, amounts.preparedParentTokenAmount);

        (govVotesAdded, liquiditySharesAdded) = IStake(stakeAddress).stakeLiquidity(
            pool.tokenAddress,
            amounts.preparedTokenAmount,
            amounts.preparedParentTokenAmount,
            promisedWaitingPhases,
            memberId
        );

        _approveToken(pool.tokenAddress, stakeAddress, 0);
        _approveToken(pool.parentTokenAddress, stakeAddress, 0);
        _readRemainder(pool, amounts);
        _settle(amounts, tokenAmountMin, parentAmountMin);
    }

    function _addLiquidity(
        HubPool memory pool,
        HubAmounts memory amounts,
        address to,
        uint256 deadline,
        uint256 tokenAmountMin,
        uint256 parentAmountMin
    ) private returns (uint256 liquidity) {
        address tokenAddress = pool.tokenAddress;
        address parentTokenAddress = pool.parentTokenAddress;
        address routerAddress = address(ROUTER_ADDRESS);

        _approveToken(tokenAddress, routerAddress, amounts.preparedTokenAmount);
        _approveToken(parentTokenAddress, routerAddress, amounts.preparedParentTokenAmount);

        // The pool-level minimums stay at zero. The caller's minimums are endpoint amounts for the whole
        // chain (`prepared - remaining`), and `_settle` is their single implementation for both the stake
        // and the LP path; passing them down as `amountAMin`/`amountBMin` would put the same rule in two
        // places and surface a router-specific revert instead of a Hub error.
        (,, liquidity) = ROUTER_ADDRESS.addLiquidity(
            tokenAddress,
            parentTokenAddress,
            amounts.preparedTokenAmount,
            amounts.preparedParentTokenAmount,
            0,
            0,
            to,
            deadline
        );

        _approveToken(tokenAddress, routerAddress, 0);
        _approveToken(parentTokenAddress, routerAddress, 0);
        _readRemainder(pool, amounts);
        _settle(amounts, tokenAmountMin, parentAmountMin);
    }

    function _quoteSingleToken(HubPool memory pool, address inputTokenAddress, uint256 inputTokenAmount)
        private
        view
        returns (SingleTokenLpQuote memory quote)
    {
        _checkInputToken(pool, inputTokenAddress);

        bool inputTokenIsToken = inputTokenAddress == pool.tokenAddress;
        (uint256 amountToSwap, uint256 amountOutFromSwap) =
            _swapPlan(pool.reserveToken, pool.reserveParent, inputTokenIsToken, inputTokenAmount);

        quote.amountToSwap = amountToSwap;
        quote.amountOutFromSwap = amountOutFromSwap;
        if (amountToSwap > 0) {
            quote.willSwap = true;
            quote.swapTokenIn = inputTokenIsToken ? pool.tokenAddress : pool.parentTokenAddress;
            quote.swapTokenOut = inputTokenIsToken ? pool.parentTokenAddress : pool.tokenAddress;
        }

        quote.preparedTokenAmount = inputTokenIsToken ? inputTokenAmount - amountToSwap : amountOutFromSwap;
        quote.preparedParentTokenAmount = inputTokenIsToken ? amountOutFromSwap : inputTokenAmount - amountToSwap;

        (uint256 reserveToken, uint256 reserveParent) = inputTokenIsToken
            ? (pool.reserveToken + amountToSwap, pool.reserveParent - amountOutFromSwap)
            : (pool.reserveToken - amountOutFromSwap, pool.reserveParent + amountToSwap);

        // Both prepared amounts are non-zero here: `_swapPlan` already rejected a zero swap output, and the
        // side the caller supplied keeps whatever the swap did not consume. So the conversion always has
        // two positive inputs to work with and its result is positive on both sides.
        (uint256 tokenAmountUsed, uint256 parentAmountUsed) = _optimalAmounts(
            reserveToken, reserveParent, quote.preparedTokenAmount, quote.preparedParentTokenAmount
        );

        quote.usableTokenAmount = tokenAmountUsed;
        quote.usableParentTokenAmount = parentAmountUsed;

        uint256 totalSupplyAfterFeeMint =
            _totalSupplyAfterFeeMint(pool, reserveToken, reserveParent);
        quote.expectedLiquidity =
            _liquidityMinted(reserveToken, reserveParent, totalSupplyAfterFeeMint, tokenAmountUsed, parentAmountUsed);
    }

    function _stakeQuote(
        SingleTokenLpQuote memory quote,
        address tokenAddress,
        uint256 memberId,
        uint256 promisedWaitingPhases
    ) private view returns (SingleTokenStakeLiquidityQuote memory stakeQuote) {
        stakeQuote.willSwap = quote.willSwap;
        stakeQuote.swapTokenIn = quote.swapTokenIn;
        stakeQuote.swapTokenOut = quote.swapTokenOut;
        stakeQuote.amountToSwap = quote.amountToSwap;
        stakeQuote.amountOutFromSwap = quote.amountOutFromSwap;
        stakeQuote.preparedTokenAmount = quote.preparedTokenAmount;
        stakeQuote.preparedParentTokenAmount = quote.preparedParentTokenAmount;
        stakeQuote.usableTokenAmount = quote.usableTokenAmount;
        stakeQuote.usableParentTokenAmount = quote.usableParentTokenAmount;
        stakeQuote.suggestedTokenAmountMin = quote.usableTokenAmount;
        stakeQuote.suggestedParentTokenAmountMin = quote.usableParentTokenAmount;

        (uint256 totalLiquidityShares, , uint256 withdrawableLp, , , , , ) = IStake(STAKE_ADDRESS).totalStake(tokenAddress);
        (uint256 memberLiquidityShares, , uint256 currentPromisedWaitingPhases, , , , ) =
            IStake(STAKE_ADDRESS).memberStake(tokenAddress, memberId);

        stakeQuote.liquiditySharesAdded = totalLiquidityShares == 0 || withdrawableLp == 0
            ? quote.expectedLiquidity
            : (totalLiquidityShares * quote.expectedLiquidity) / withdrawableLp;
        stakeQuote.liquidityShares = memberLiquidityShares + stakeQuote.liquiditySharesAdded;
        stakeQuote.govVotesAdded =
            stakeQuote.liquidityShares * promisedWaitingPhases - memberLiquidityShares * currentPromisedWaitingPhases;
    }

    function _approveToken(address tokenAddress, address spender, uint256 amount) private {
        IERC20(tokenAddress).forceApprove(spender, amount);
    }

    function _refundTokens(HubPool memory pool, HubAmounts memory amounts) private {
        _refundToken(pool.tokenAddress, amounts.remainingTokenAmount);
        _refundToken(pool.parentTokenAddress, amounts.remainingParentTokenAmount);
    }

    /// @dev The native branch returns the wrapped-native remainder as native currency: the shape of the
    ///      refund is decided by the function the caller used, never by an argument.
    function _refundNativeThenTokens(HubPool memory pool, HubAmounts memory amounts) private {
        if (amounts.remainingParentTokenAmount > 0) {
            IWrappedNative(WRAPPED_NATIVE_ADDRESS).withdraw(amounts.remainingParentTokenAmount);
            // forge-lint: disable-next-line(arbitrary-send-eth)
            (bool success,) = msg.sender.call{value: amounts.remainingParentTokenAmount}("");
            if (!success) revert NativeRefundFailed();
        }
        _refundToken(pool.tokenAddress, amounts.remainingTokenAmount);
    }

    function _refundToken(address tokenAddress, uint256 amount) private {
        if (amount == 0) return;
        IERC20(tokenAddress).safeTransfer(msg.sender, amount);
    }
}
