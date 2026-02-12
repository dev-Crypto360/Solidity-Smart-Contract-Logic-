// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  Epstein Files (EPSTEN)
  - Uniswap V2 (Ethereum mainnet)
  - Supply: 10,000,000,000 (10B)
  - SELL TAX ONLY: 1.5% (150 bps)
  - Fee tokens are swapped to ETH and forwarded to FUND_WALLET
  - No owner/admin functions, no blacklist, no trading gate

  Uniswap V2 Router02 (Ethereum):
  0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
*/

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

contract EpsteinFiles {
    // ===== ERC20 =====
    string public constant name = "Epstein Files";
    string public constant symbol = "EPSTEN";
    uint8  public constant decimals = 18;

    uint256 public constant TOTAL_SUPPLY = 10_000_000_000 * 1e18; // 10B
    uint256 public totalSupply = TOTAL_SUPPLY;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ===== Tax config =====
    uint256 public constant SELL_TAX_BPS = 150; // 1.5%
    uint256 public constant BPS_DENOM = 10_000;

    // ETH receiver
    address public constant FUND_WALLET = 0xeC130B456A3e7B488bF966Cbf3F8a3C1265063dd;

    // Uniswap V2 Router02 (Ethereum mainnet)
address public constant UNISWAP_V2_ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;

    // Pair (created in constructor)
    address public immutable uniswapV2Pair;

    // ===== Swap control =====
    bool private inSwap;

    // Swap fees only when at least this many fee-tokens have accumulated
    // (fixed constant, no admin setters)
    uint256 public constant SWAP_THRESHOLD = 5_000_000 * 1e18; // 5M tokens

    modifier swapping() {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor() {
        // Create Uniswap V2 pair with WETH
        IUniswapV2Router02 r = IUniswapV2Router02(UNISWAP_V2_ROUTER);
        uniswapV2Pair = IUniswapV2Factory(r.factory()).createPair(address(this), r.WETH());

        // Mint all supply to deployer
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    receive() external payable {} // receive ETH from swaps

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "ALLOWANCE");
        unchecked { allowance[from][msg.sender] = allowed - value; }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(from != address(0) && to != address(0), "ZERO_ADDR");

        uint256 bal = balanceOf[from];
        require(bal >= value, "BAL");

        // On sells, swap accumulated fee tokens to ETH first (if above threshold)
        if (!inSwap && to == uniswapV2Pair) {
            uint256 contractTokens = balanceOf[address(this)];
            if (contractTokens >= SWAP_THRESHOLD) {
                _swapFeesForETHAndSend(contractTokens);
            }
        }

        // SELL = transfer to pair -> take 1.5% fee in tokens to this contract
        if (to == uniswapV2Pair && !inSwap && value > 0) {
            uint256 fee = (value * SELL_TAX_BPS) / BPS_DENOM;
            uint256 net = value - fee;

            unchecked {
                balanceOf[from] = bal - value;
                balanceOf[address(this)] += fee;
                balanceOf[to] += net;
            }

            emit Transfer(from, address(this), fee);
            emit Transfer(from, to, net);
            return;
        }

        // No tax on buys or wallet transfers
        unchecked {
            balanceOf[from] = bal - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _swapFeesForETHAndSend(uint256 tokenAmount) internal swapping {
        // Approve router
        allowance[address(this)][UNISWAP_V2_ROUTER] = tokenAmount;
        emit Approval(address(this), UNISWAP_V2_ROUTER, tokenAmount);

        // ✅ Correctly declare path (this is what your Remix error was about)
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = IUniswapV2Router02(UNISWAP_V2_ROUTER).WETH();

        // Swap fee tokens -> ETH
        IUniswapV2Router02(UNISWAP_V2_ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );

        // Send ETH to fund wallet
        (bool ok, ) = FUND_WALLET.call{value: address(this).balance}("");
        require(ok, "ETH_SEND_FAIL");
    }
}