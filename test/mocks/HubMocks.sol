// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IStake} from "@core/interfaces/IStake.sol";
import {IUniswapV2Pair} from "../../src/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "../../src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IUniswapV2Router02.sol";
import {IWrappedNative} from "../../src/interfaces/IWrappedNative.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public MAX_SUPPLY = type(uint256).max;

    /// @dev The Hub reads the community token's parent through `ILOVE20Token.PARENT_TOKEN_ADDRESS()`, so
    ///      the mock exposes the same getter the real `LOVE20Token` does. It is settable because the
    ///      fixture deploys the token before its parent is wired up.
    address internal _parentTokenAddress;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function PARENT_TOKEN_ADDRESS() external view returns (address) {
        return _parentTokenAddress;
    }

    function setParentTokenAddress(address parentTokenAddress_) external {
        _parentTokenAddress = parentTokenAddress_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "MOCK_ALLOWANCE");
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "MOCK_BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract MockWrappedNative is MockERC20, IWrappedNative {
    constructor() MockERC20("Wrapped BNB", "WBNB") {}

    function deposit() external payable override {
        totalSupply += msg.value;
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external override {
        require(balanceOf[msg.sender] >= amount, "MOCK_BALANCE");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "MOCK_NATIVE_SEND");
    }

    receive() external payable {}
}

/// @dev Pair mock with the real Uniswap V2 liquidity accounting: `mint` locks `MINIMUM_LIQUIDITY` on the
///      first mint, later mints are proportional to the smaller side, and `_mintFee` mints the protocol's
///      share of the growth in sqrt(k) to `feeTo`. Both the fee and the protocol's cut are configurable so
///      the Hub's projections can be checked against every real DEX profile:
///
///        Uniswap V2      swap 997/1000,  protocol k/a = 1/5   (1/6 of sqrt(k) growth)
///        Pancake mainnet swap 9975/10000, protocol k/a = 8/17 (32% of growth)
///        Pancake testnet swap 9980/10000, protocol k/a = 1/3  (25% of growth)
///
///      `_mintFee` runs *before* the proportional share is computed, exactly like the real pair, so a
///      projection that forgets it will disagree with the LP actually minted.
contract MockUniswapV2Pair is IUniswapV2Pair {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    address public immutable override token0;
    address public immutable override token1;

    uint256 public override totalSupply;
    uint256 public override kLast;

    /// @dev The protocol's cut of sqrt(k) growth, as `numerator / denominator`. Zero numerator means the
    ///      DEX takes nothing (the local `dex` profile).
    uint256 public protocolFeeNumerator;
    uint256 public protocolFeeDenominator;

    address public feeTo;

    mapping(address => uint256) public balanceOf;

    uint112 private _reserve0;
    uint112 private _reserve1;
    uint32 private _blockTimestampLast;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() external view override returns (uint112, uint112, uint32) {
        return (_reserve0, _reserve1, _blockTimestampLast);
    }

    function reserve0() external view returns (uint112) {
        return _reserve0;
    }

    function reserve1() external view returns (uint112) {
        return _reserve1;
    }

    function setProtocolFee(uint256 numerator, uint256 denominator) external {
        protocolFeeNumerator = numerator;
        protocolFeeDenominator = denominator;
    }

    function setFeeTo(address feeTo_) external {
        feeTo = feeTo_;
    }

    function addLiquidity(uint256 amount0, uint256 amount1) external returns (uint256 liquidity) {
        MockERC20(token0).transferFrom(msg.sender, address(this), amount0);
        MockERC20(token1).transferFrom(msg.sender, address(this), amount1);
        return _mint(msg.sender, amount0, amount1);
    }

    /// @dev `UniswapV2Pair.mint`, minus the token transfers the router has already done.
    function mintTo(address to, uint256 amount0, uint256 amount1) external returns (uint256 liquidity) {
        return _mint(to, amount0, amount1);
    }

    /// @dev `UniswapV2Pair.mint(address)`: the credited amounts are the balance deltas the caller already
    ///      transferred in, so this pairs with a plain `transfer` exactly like the real pair.
    function mint(address to) external override returns (uint256 liquidity) {
        uint256 amount0 = MockERC20(token0).balanceOf(address(this)) - uint256(_reserve0);
        uint256 amount1 = MockERC20(token1).balanceOf(address(this)) - uint256(_reserve1);
        return _mint(to, amount0, amount1);
    }

    /// @dev `UniswapV2Pair.burn(address)`: pays out the caller's proportional share of both reserves.
    function burn(address to) external override returns (uint256 amount0, uint256 amount1) {
        uint256 liquidity = balanceOf[msg.sender];
        uint256 supply = totalSupply;
        amount0 = (liquidity * uint256(_reserve0)) / supply;
        amount1 = (liquidity * uint256(_reserve1)) / supply;
        require(amount0 > 0 && amount1 > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED");

        MockERC20(token0).transfer(to, amount0);
        MockERC20(token1).transfer(to, amount1);
        balanceOf[msg.sender] -= liquidity;
        totalSupply = supply - liquidity;
        removeFromReserve(token0, amount0);
        removeFromReserve(token1, amount1);
    }

    /// @dev `UniswapV2Pair.mint` liquidity accounting: `_mintFee` first (it changes `totalSupply`), then the
    ///      first mint locks `MINIMUM_LIQUIDITY` or a later mint takes the smaller proportional side.
    function _mint(address to, uint256 amount0, uint256 amount1) private returns (uint256 liquidity) {
        bool feeOn = _mintFee();

        uint256 supply = totalSupply;
        if (supply == 0) {
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
            balanceOf[address(this)] = MINIMUM_LIQUIDITY;
            supply = MINIMUM_LIQUIDITY;
        } else {
            liquidity = _min((amount0 * supply) / _reserve0, (amount1 * supply) / _reserve1);
            require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
        }

        addToReserve(token0, amount0);
        addToReserve(token1, amount1);
        totalSupply = supply + liquidity;
        balanceOf[to] += liquidity;
        if (feeOn) kLast = uint256(_reserve0) * uint256(_reserve1);
    }

    /// @dev `UniswapV2Pair._mintFee`, generalised to `numerator / denominator`:
    ///
    ///        feeLp = supply * (rootK - rootKLast) * k / (a * rootK + k * rootKLast)
    ///
    ///      With `k/a = 1/5` this is Uniswap V2's `1/(5r+rLast)`; with `8/17` it is Pancake mainnet's
    ///      `8/(17r+8rLast)`. Returns whether the fee is on, which is what decides `kLast` upkeep.
    function _mintFee() private returns (bool feeOn) {
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast;
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = _sqrt(uint256(_reserve0) * uint256(_reserve1));
                uint256 rootKLast = _sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply * (rootK - rootKLast) * protocolFeeNumerator;
                    uint256 denominator =
                        protocolFeeDenominator * rootK + protocolFeeNumerator * rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mintTokens(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    function _mintTokens(address to, uint256 amount) private {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    /// @dev The protocol fee `_mintFee` would mint right now, for tests that assert the projection.
    function pendingFeeLiquidity() public view returns (uint256 feeLiquidity) {
        if (feeTo == address(0) || kLast == 0 || protocolFeeNumerator == 0) return 0;
        uint256 rootK = _sqrt(uint256(_reserve0) * uint256(_reserve1));
        uint256 rootKLast = _sqrt(kLast);
        if (rootK <= rootKLast) return 0;
        feeLiquidity = (totalSupply * (rootK - rootKLast) * protocolFeeNumerator)
            / (protocolFeeDenominator * rootK + protocolFeeNumerator * rootKLast);
    }

    function addToReserve(address tokenAddress, uint256 amount) public {
        if (tokenAddress == token0) {
            _reserve0 = uint112(uint256(_reserve0) + amount);
        } else {
            require(tokenAddress == token1, "MOCK_UNKNOWN_TOKEN");
            _reserve1 = uint112(uint256(_reserve1) + amount);
        }
        _blockTimestampLast = uint32(block.timestamp);
    }

    function removeFromReserve(address tokenAddress, uint256 amount) public {
        if (tokenAddress == token0) {
            require(uint256(_reserve0) >= amount, "MOCK_RESERVE");
            _reserve0 = uint112(uint256(_reserve0) - amount);
        } else {
            require(tokenAddress == token1, "MOCK_UNKNOWN_TOKEN");
            require(uint256(_reserve1) >= amount, "MOCK_RESERVE");
            _reserve1 = uint112(uint256(_reserve1) - amount);
        }
    }

    /// @dev A swap as the pair sees it: move the output out, then fold both legs into the reserves.
    function swapNow(address tokenIn, address tokenOut, address to, uint256 amountIn, uint256 amountOut) external {
        MockERC20(tokenOut).transfer(to, amountOut);
        addToReserve(tokenIn, amountIn);
        removeFromReserve(tokenOut, amountOut);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _sqrt(uint256 value) private pure returns (uint256 result) {
        if (value == 0) return 0;
        result = value;
        uint256 x = (value + 1) / 2;
        while (x < result) {
            result = x;
            x = (value / x + x) / 2;
        }
    }
}

contract MockUniswapV2Factory is IUniswapV2Factory {
    address public override feeTo;

    /// @dev Copied into every pair this factory creates, so a fixture configures the DEX profile once.
    uint256 public protocolFeeNumerator;
    uint256 public protocolFeeDenominator = 1;

    mapping(address => mapping(address => address)) private _pairByTokenByToken;

    function setPair(address tokenA, address tokenB, address pairAddress) external {
        _pairByTokenByToken[tokenA][tokenB] = pairAddress;
        _pairByTokenByToken[tokenB][tokenA] = pairAddress;
        MockUniswapV2Pair(pairAddress).setProtocolFee(protocolFeeNumerator, protocolFeeDenominator);
        MockUniswapV2Pair(pairAddress).setFeeTo(feeTo);
    }

    function setFeeTo(address feeTo_) external {
        feeTo = feeTo_;
    }

    /// @dev Configures the protocol's cut and pushes it to the already-registered pairs, so a test can set
    ///      the DEX profile after the fixture has built the pair.
    function setProtocolFee(uint256 numerator, uint256 denominator) external {
        protocolFeeNumerator = numerator;
        protocolFeeDenominator = denominator;
    }

    function configurePair(address pairAddress) external {
        MockUniswapV2Pair(pairAddress).setProtocolFee(protocolFeeNumerator, protocolFeeDenominator);
        MockUniswapV2Pair(pairAddress).setFeeTo(feeTo);
    }

    /// @dev Mirrors `UniswapV2Factory.createPair`: sorted tokens, registered under both orders.
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = address(new MockUniswapV2Pair(token0, token1));
        MockUniswapV2Pair(pair).setProtocolFee(protocolFeeNumerator, protocolFeeDenominator);
        MockUniswapV2Pair(pair).setFeeTo(feeTo);
        _pairByTokenByToken[tokenA][tokenB] = pair;
        _pairByTokenByToken[tokenB][tokenA] = pair;
    }

    function getPair(address tokenA, address tokenB) external view override returns (address) {
        return _pairByTokenByToken[tokenA][tokenB];
    }
}

/// @dev Router mock with the real constant-product math: `getAmountOut` verbatim from
///      `UniswapV2Library` but with a configurable fee, proportional mint with the locked
///      `MINIMUM_LIQUIDITY`, and `_mintFee` applied before the proportional share. Pairs always come from
///      the factory, so the Hub and the router can never disagree about which pair they are talking to.
contract MockUniswapV2Router02 is IUniswapV2Router02 {
    uint256 public feeNumerator = 997;
    uint256 public feeDenominator = 1000;
    uint256 private constant MINIMUM_LIQUIDITY = 1000;

    address public immutable override factory;
    address public immutable override WETH;

    constructor(address factory_, address weth_) {
        factory = factory_;
        WETH = weth_;
    }

    function setFee(uint256 numerator, uint256 denominator) external {
        feeNumerator = numerator;
        feeDenominator = denominator;
    }

    function setPair(address tokenA, address tokenB, address pairAddress) external {
        MockUniswapV2Factory(factory).setPair(tokenA, tokenB, pairAddress);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external override returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        require(to != address(0), "MOCK_ZERO_TO");

        MockUniswapV2Pair pair = MockUniswapV2Pair(_pairOrCreate(tokenA, tokenB));

        {
            (uint256 reserveA, uint256 reserveB) = _reservesOf(pair, tokenA, tokenB);
            (amountA, amountB) = _addLiquidityAmounts(
                reserveA, reserveB, amountADesired, amountBDesired, amountAMin, amountBMin
            );
        }

        liquidity = _pullAndMint(pair, tokenA, tokenB, amountA, amountB, to);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        require(path.length == 2, "MOCK_PATH");

        MockUniswapV2Pair pair = MockUniswapV2Pair(_pairOf(path[0], path[1]));
        (uint256 reserveIn, uint256 reserveOut) = _reservesOf(pair, path[0], path[1]);
        uint256 amountOut = _getAmountOut(amountIn, reserveIn, reserveOut);
        require(amountOut >= amountOutMin, "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");

        require(MockERC20(path[0]).transferFrom(msg.sender, address(pair), amountIn), "MOCK_PULL_IN");
        pair.swapNow(path[0], path[1], to, amountIn, amountOut);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        override
        returns (uint256[] memory amounts)
    {
        require(path.length == 2, "MOCK_PATH");
        MockUniswapV2Pair pair = MockUniswapV2Pair(_pairOf(path[0], path[1]));
        (uint256 reserveIn, uint256 reserveOut) = _reservesOf(pair, path[0], path[1]);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = _getAmountOut(amountIn, reserveIn, reserveOut);
    }

    /// @dev Pull both legs in and mint. Split out of `addLiquidity` to stay inside the stack limit, and
    ///      ordered by the pair's own `token0`/`token1`, which is what `pair.mint` expects.
    function _pullAndMint(
        MockUniswapV2Pair pair,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        address to
    ) private returns (uint256 liquidity) {
        require(MockERC20(tokenA).transferFrom(msg.sender, address(pair), amountA), "MOCK_PULL_A");
        require(MockERC20(tokenB).transferFrom(msg.sender, address(pair), amountB), "MOCK_PULL_B");

        (uint256 amount0, uint256 amount1) = tokenA == pair.token0() ? (amountA, amountB) : (amountB, amountA);
        liquidity = pair.mintTo(to, amount0, amount1);
    }

    /// @dev `UniswapV2Router02._addLiquidity` amount optimisation, verbatim.
    function _addLiquidityAmounts(
        uint256 reserveA,
        uint256 reserveB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) private pure returns (uint256 amountA, uint256 amountB) {
        if (reserveA == 0 && reserveB == 0) return (amountADesired, amountBDesired);

        uint256 amountBOptimal = (amountADesired * reserveB) / reserveA;
        if (amountBOptimal <= amountBDesired) {
            require(amountBOptimal >= amountBMin, "UniswapV2Router: INSUFFICIENT_B_AMOUNT");
            return (amountADesired, amountBOptimal);
        }
        uint256 amountAOptimal = (amountBDesired * reserveA) / reserveB;
        require(amountAOptimal >= amountAMin, "UniswapV2Router: INSUFFICIENT_A_AMOUNT");
        return (amountAOptimal, amountBDesired);
    }

    /// @dev `UniswapV2Library.getAmountOut`, with the configured fee instead of the hard-coded 997/1000.
    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        private
        view
        returns (uint256)
    {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * feeNumerator;
        return (amountInWithFee * reserveOut) / (reserveIn * feeDenominator + amountInWithFee);
    }

    /// @dev The real router creates the pair when it is missing; the Hub relies on that for cold starts.
    function _pairOrCreate(address tokenA, address tokenB) private returns (address pair) {
        pair = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) {
            pair = IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
    }

    function _pairOf(address tokenA, address tokenB) private view returns (address pair) {
        pair = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
        require(pair != address(0), "MOCK_PAIR_MISSING");
    }

    /// @dev Reserves ordered to match `(tokenA, tokenB)`, which is how `UniswapV2Library.pairReserves`
    ///      behaves: the caller's argument order decides, not the pair's token0 ordering.
    function _reservesOf(MockUniswapV2Pair pair, address tokenA, address tokenB)
        private
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (uint112 reserve0, uint112 reserve1) = (pair.reserve0(), pair.reserve1());
        if (tokenA == pair.token0()) {
            require(tokenB == pair.token1(), "MOCK_TOKEN_PAIR");
            return (uint256(reserve0), uint256(reserve1));
        }
        require(tokenA == pair.token1() && tokenB == pair.token0(), "MOCK_TOKEN_PAIR");
        return (uint256(reserve1), uint256(reserve0));
    }
}

/// @dev Minimal `MemberNFT` stand-in: the Hub only calls `ownerOf` to prove the `memberId` exists.
contract MockMemberNFT {
    mapping(uint256 => address) private _ownerByMemberId;

    function mint(uint256 memberId, address owner) external {
        _ownerByMemberId[memberId] = owner;
    }

    function ownerOf(uint256 memberId) external view returns (address owner) {
        owner = _ownerByMemberId[memberId];
        require(owner != address(0), "ERC721NonexistentToken");
    }
}

/// @dev Minimal `Launch` stand-in: the Hub only asks whether a token is a registered LOVE20 token, and
///      `PairMissing` coverage needs a way to deregister one again.
contract MockLaunch {
    mapping(address => address) private _parentTokenByTokenAddress;

    function register(address tokenAddress, address parentTokenAddress) external {
        _parentTokenByTokenAddress[tokenAddress] = parentTokenAddress;
    }

    function unregister(address tokenAddress) external {
        delete _parentTokenByTokenAddress[tokenAddress];
    }

    function isLOVE20Token(address tokenAddress) public view returns (bool) {
        return _parentTokenByTokenAddress[tokenAddress] != address(0);
    }
}
