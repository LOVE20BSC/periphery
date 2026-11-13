// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IStake} from "@core/interfaces/IStake.sol";
import {IUniswapV2Pair} from "../../src/interfaces/IUniswapV2Pair.sol";
import {MockERC20} from "./HubMocks.sol";

/// @dev `Stake` stand-in for the Hub's integration tests. Only the two halves the Hub touches are
///      modelled, but both are modelled faithfully:
///
///      1. **Conversion** — `_optimalAmounts` is copied verbatim from `core/src/Stake.sol`, including the
///         "one side full, the other side scaled" shape and the truncating division.
///      2. **Funding** — `_pull` takes exactly the converted amounts from `msg.sender` and pushes them
///         into the pair, so the amounts that never get pulled stay with the caller. That is what the
///         Hub's `prepared − remaining` check has to observe.
///
///      Everything else (`sharesMinted`, `_mintFee` interaction, fee reclassification) is deliberately
///      absent: those are core's own correctness surface, covered by core's suite, and reproducing them
///      here would only create a second copy that can drift.
/// @dev Staging struct for the `LiquidityStaked` payload. The event carries fifteen fields, so the values
///      are collected in memory first and the emit only touches this one pointer — the same shape
///      core's `Stake` uses to stay inside the stack limit.
struct LiquidityStakedPayload {
    address tokenAddress;
    uint256 memberId;
    address caller;
    address memberOwner;
    uint256 tokenAmount;
    uint256 parentTokenAmount;
    uint256 promisedWaitingPhases;
    uint256 prevPromisedWaitingPhases;
    uint256 govVotesAdded;
    uint256 liquiditySharesAdded;
    uint256 liquidityShares;
    uint256 totalLiquidityShares;
    uint256 totalValidGovVotes;
    uint256 totalWithdrawableLp;
}

contract MockStake is IStake {
    address public immutable override PHASE_ADDRESS;
    address public immutable override MEMBER_NFT_ADDRESS;
    address public immutable override VOTE_ADDRESS;
    address public immutable override LAUNCH_ADDRESS;
    address public immutable override ROUTER_ADDRESS;
    address public immutable override PAIR_FACTORY_ADDRESS;

    uint256 public immutable override PROMISED_WAITING_PHASES_MIN;
    uint256 public immutable override PROMISED_WAITING_PHASES_MAX;
    uint256 public immutable override FEE_SETTLEMENT_RATIO;
    uint256 public immutable override BOOST_STAKE_SUPPLY_FACTOR;
    uint256 public immutable override BOOST_STAKE_MULTIPLIER;
    uint256 public constant override LIQUIDITY_TOKEN_EQUIVALENCE_FACTOR = 2;

    address public pairFactory;
    bool public feeSettlementEnabled;

    mapping(address => uint256) private _pairByToken;
    mapping(address => uint256) private _totalLiquidityShares;
    mapping(address => mapping(uint256 => uint256)) private _liquiditySharesByMemberId;
    mapping(address => mapping(uint256 => uint256)) private _promisedWaitingPhasesByMemberId;

    constructor(
        address memberNFTAddress,
        address launchAddress,
        address routerAddress,
        address pairFactoryAddress,
        uint256 promisedWaitingPhasesMin,
        uint256 promisedWaitingPhasesMax
    ) {
        MEMBER_NFT_ADDRESS = memberNFTAddress;
        LAUNCH_ADDRESS = launchAddress;
        ROUTER_ADDRESS = routerAddress;
        PAIR_FACTORY_ADDRESS = pairFactoryAddress;
        PHASE_ADDRESS = address(0);
        VOTE_ADDRESS = address(0);
        PROMISED_WAITING_PHASES_MIN = promisedWaitingPhasesMin;
        PROMISED_WAITING_PHASES_MAX = promisedWaitingPhasesMax;
        FEE_SETTLEMENT_RATIO = 0;
        BOOST_STAKE_SUPPLY_FACTOR = 1;
        BOOST_STAKE_MULTIPLIER = 1;
    }

    function stakeLiquidity(
        address tokenAddress,
        uint256 tokenAmount,
        uint256 parentTokenAmount,
        uint256 promisedWaitingPhases,
        uint256 memberId
    ) external override returns (uint256 govVotesAdded, uint256 liquiditySharesAdded) {
        if (tokenAmount == 0) revert ZeroTokenAmount();
        if (parentTokenAmount == 0) revert ZeroParentTokenAmount();
        if (
            promisedWaitingPhases < PROMISED_WAITING_PHASES_MIN
                || promisedWaitingPhases > PROMISED_WAITING_PHASES_MAX
        ) {
            revert InvalidPromisedWaitingPhases(
                promisedWaitingPhases, PROMISED_WAITING_PHASES_MIN, PROMISED_WAITING_PHASES_MAX
            );
        }

        uint256 previousShares = _liquiditySharesByMemberId[tokenAddress][memberId];
        uint256 previousPhases = _promisedWaitingPhasesByMemberId[tokenAddress][memberId];
        if (previousPhases != 0 && promisedWaitingPhases < previousPhases) {
            revert PromisedWaitingPhasesDecreased(promisedWaitingPhases, previousPhases);
        }

        uint256 tokenAmountIn;
        uint256 parentTokenAmountIn;
        (tokenAmountIn, parentTokenAmountIn, liquiditySharesAdded) =
            _pullAndMint(tokenAddress, tokenAmount, parentTokenAmount);

        _liquiditySharesByMemberId[tokenAddress][memberId] = previousShares + liquiditySharesAdded;
        _promisedWaitingPhasesByMemberId[tokenAddress][memberId] = promisedWaitingPhases;
        _totalLiquidityShares[tokenAddress] += liquiditySharesAdded;
        govVotesAdded = (previousShares + liquiditySharesAdded) * promisedWaitingPhases - previousShares * previousPhases;

        LiquidityStakedPayload memory payload;
        payload.tokenAddress = tokenAddress;
        payload.memberId = memberId;
        payload.caller = msg.sender;
        payload.memberOwner = _ownerOf(memberId);
        payload.tokenAmount = tokenAmountIn;
        payload.parentTokenAmount = parentTokenAmountIn;
        payload.promisedWaitingPhases = promisedWaitingPhases;
        payload.prevPromisedWaitingPhases = previousPhases;
        payload.govVotesAdded = govVotesAdded;
        payload.liquiditySharesAdded = liquiditySharesAdded;
        payload.liquidityShares = previousShares + liquiditySharesAdded;
        payload.totalLiquidityShares = _totalLiquidityShares[tokenAddress];
        payload.totalValidGovVotes = _totalLiquidityShares[tokenAddress] * promisedWaitingPhases;
        payload.totalWithdrawableLp = 0;
        _emitLiquidityStaked(payload);
    }

    /// @dev The pull-and-mint half of core's `_addLiquidity`: convert against the live reserves, take
    ///      exactly the converted amounts from `msg.sender`, then let the pair mint. Anything the
    ///      conversion did not ask for is simply never transferred.
    function _pullAndMint(address tokenAddress, uint256 tokenAmount, uint256 parentTokenAmount)
        private
        returns (uint256 tokenAmountIn, uint256 parentTokenAmountIn, uint256 liquiditySharesAdded)
    {
        address pair = pairAddress(tokenAddress);
        if (pair == address(0)) revert PairMissing(tokenAddress);

        (tokenAmountIn, parentTokenAmountIn) = _optimalAmountsFor(tokenAddress, pair, tokenAmount, parentTokenAmount);
        address parentTokenAddress = _parentTokenOf(tokenAddress);

        MockERC20(tokenAddress).transferFrom(msg.sender, address(this), tokenAmountIn);
        MockERC20(parentTokenAddress).transferFrom(msg.sender, address(this), parentTokenAmountIn);
        MockERC20(tokenAddress).transfer(pair, tokenAmountIn);
        MockERC20(parentTokenAddress).transfer(pair, parentTokenAmountIn);

        liquiditySharesAdded = IUniswapV2Pair(pair).mint(address(this));
        if (liquiditySharesAdded == 0) revert ZeroLiquidityMinted();
    }

    function _optimalAmountsFor(address tokenAddress, address pair, uint256 tokenAmount, uint256 parentTokenAmount)
        private
        view
        returns (uint256, uint256)
    {
        IUniswapV2Pair pairContract = IUniswapV2Pair(pair);
        (uint112 reserve0, uint112 reserve1,) = pairContract.getReserves();
        (uint256 reserveToken, uint256 reserveParent) = tokenAddress == pairContract.token0()
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
        return _optimalAmounts(tokenAmount, parentTokenAmount, reserveToken, reserveParent);
    }

    function _emitLiquidityStaked(LiquidityStakedPayload memory payload) private {
        emit LiquidityStaked({
            tokenAddress: payload.tokenAddress,
            round: 1,
            memberId: payload.memberId,
            caller: payload.caller,
            memberOwner: payload.memberOwner,
            tokenAmount: payload.tokenAmount,
            parentTokenAmount: payload.parentTokenAmount,
            promisedWaitingPhases: payload.promisedWaitingPhases,
            prevPromisedWaitingPhases: payload.prevPromisedWaitingPhases,
            govVotesAdded: payload.govVotesAdded,
            liquiditySharesAdded: payload.liquiditySharesAdded,
            liquidityShares: payload.liquidityShares,
            totalLiquidityShares: payload.totalLiquidityShares,
            totalValidGovVotes: payload.totalValidGovVotes,
            totalWithdrawableLp: payload.totalWithdrawableLp
        });
    }

    function setPair(address tokenAddress, address pairAddress_) external {
        _pairByToken[tokenAddress] = uint256(uint160(pairAddress_));
    }

    function setParentToken(address tokenAddress, address parentTokenAddress) external {
        _parentTokenByTokenAddress[tokenAddress] = parentTokenAddress;
    }

    mapping(address => address) private _parentTokenByTokenAddress;

    function _parentTokenOf(address tokenAddress) private view returns (address) {
        return _parentTokenByTokenAddress[tokenAddress];
    }

    function _ownerOf(uint256 memberId) private view returns (address owner) {
        (bool success, bytes memory data) =
            MEMBER_NFT_ADDRESS.staticcall(abi.encodeWithSignature("ownerOf(uint256)", memberId));
        owner = success && data.length == 32 ? abi.decode(data, (address)) : address(0);
    }

    /// @dev Copied verbatim from `core/src/Stake.sol` so the Hub's `prepared − remaining` check is
    ///      exercised against the real conversion, not an approximation of it.
    function _optimalAmounts(
        uint256 tokenAmount,
        uint256 parentTokenAmount,
        uint256 reserveToken,
        uint256 reserveParent
    ) private pure returns (uint256 optimalTokenAmount, uint256 optimalParentTokenAmount) {
        if (reserveToken == 0 || reserveParent == 0) {
            return (tokenAmount, parentTokenAmount);
        }

        optimalParentTokenAmount = (tokenAmount * reserveParent) / reserveToken;
        if (optimalParentTokenAmount <= parentTokenAmount) {
            return (tokenAmount, optimalParentTokenAmount);
        }

        optimalTokenAmount = (parentTokenAmount * reserveToken) / reserveParent;
        return (optimalTokenAmount, parentTokenAmount);
    }

    function pairAddress(address tokenAddress) public view override returns (address) {
        return address(uint160(_pairByToken[tokenAddress]));
    }

    function liquidityTokenAmount(address) external pure override returns (uint256) {
        return 0;
    }

    function totalStake(address)
        external
        pure
        override
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return (0, 0, 0, 0, 0, 0, 0, 0);
    }

    function memberStake(address, uint256)
        external
        pure
        override
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return (0, 0, 0, 0, 0, 0, 0);
    }

    function boostStakeCap(address, uint256) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function totalBurnedToken(address) external pure override returns (uint256) {
        return 0;
    }

    function totalParentTokenBurned(address) external pure override returns (uint256) {
        return 0;
    }

    function totalValidGovVotes(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function totalValidGovVotesAdded(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function totalValidGovVotesRemoved(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function validGovVotes(address, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function totalValidBoostShares(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function totalValidBoostSharesAdded(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function totalValidBoostSharesRemoved(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function validBoostShares(address, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function canWithdraw(address, uint256) external pure override returns (bool) {
        return false;
    }

    function settleFees(address) external override {}

    function stakeBoost(address, uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function unstake(address, uint256) external pure override {}

    function withdraw(address, uint256) external pure override {}

    function mergeStake(address, uint256, uint256) external pure override {}
}
