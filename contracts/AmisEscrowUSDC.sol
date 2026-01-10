// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import '@openzeppelin/contracts/access/Ownable2Step.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

contract AmisEscrowManagerUSDC is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    ISwapRouter02 public immutable swapRouter;
    IWETH9 public immutable weth;

    uint256 public constant FEE_BPS = 250;

    address public bot;
    address public feeReceiver;
    uint256 public tradeCount;

    uint256 public immutable releaseTimeout = 1 days;

    // Uniswap Fee Tier (0.3% - standard for stable/eth pairs on L2s usually, or 0.05% for stable/stable)
    // USDC/WETH pool on Base Sepolia might vary. We'll use 3000 (0.3%) as default.
    uint24 public constant POOL_FEE = 3000; 

    enum TradeStatus {
        Created,
        Funded,
        Delivered,
        Completed,
        Cancelled,
        Disputed
    }

    struct Trade {
        uint256 tradeId;
        address buyer;
        address seller;
        uint256 amount;
        TradeStatus status;
        uint256 deliveryTimestamp;
        uint256 pendingFee;
    }

    mapping(uint256 => Trade) public trades;

    /// @notice Mapping to prevent duplicate funding per Discord trade
    mapping(bytes32 => uint256) public discordTradeIdToOnChainId;

    event Created(
        uint256 indexed tradeId,
        address indexed buyer,
        address indexed seller,
        uint256 amount
    );
    event Funded(uint256 indexed tradeId, address indexed buyer, uint256 amount);
    event Delivered(uint256 indexed tradeId, address indexed seller);
    event Approved(uint256 indexed tradeId, address indexed buyer);
    event Released(uint256 indexed tradeId, address indexed to, uint256 amount);
    event Disputed(uint256 indexed tradeId, address indexed raisedBy);
    event Refunded(
        uint256 indexed tradeId,
        address indexed buyer,
        uint256 amount
    );
    event BuyerFeeCollected(
        uint256 indexed tradeId,
        uint256 fee
    );
    event SellerFeeCollected(
        uint256 indexed tradeId,
        uint256 fee
    );
    event FeeConverted(uint256 usdcAmount, uint256 ethReceived);
    event FeeConversionFailed(uint256 usdcAmount, string reason);
    event TradeLinkedToDiscord(
        bytes32 indexed discordTradeId,
        uint256 indexed onChainTradeId
    );
    event BotUpdated(address indexed oldBot, address indexed newBot);
    event FeeReceiverUpdated(address indexed oldFeeReceiver, address indexed newFeeReceiver);
    event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed to);

    modifier onlyBot() {
        require(msg.sender == bot, 'only bot can call this');
        _;
    }

    modifier onlyBotOrOwner() {
        require(msg.sender == bot || msg.sender == owner(), 'only bot or owner can call this');
        _;
    }

    /**
     * @param _bot The address of the bot.
     * @param _feeReceiver The address collecting fees.
     * @param _usdc The address of the USDC contract on Base.
     * @param _swapRouter The address of the Uniswap V3 SwapRouter02.
     * @param _weth The address of WETH9.
     */
    constructor(
        address _bot, 
        address _feeReceiver, 
        address _usdc,
        address _swapRouter,
        address _weth
    ) {
        require(_bot != address(0) && _feeReceiver != address(0) && _usdc != address(0), 'invalid addr');
        require(_swapRouter != address(0) && _weth != address(0), 'invalid swap addr');
        
        bot = _bot;
        feeReceiver = _feeReceiver;
        usdc = IERC20(_usdc);
        swapRouter = ISwapRouter02(_swapRouter);
        weth = IWETH9(_weth);
    }

    // --- TRADE CREATION & FUNDING ---
    /**
     * @notice Called by Buyer via frontend with Discord trade ID for duplicate protection.
     * @dev IMPORTANT: Buyer must Approve the contract to spend USDC before calling this.
     * @param _seller The wallet address of the seller.
     * @param _tradeAmount The amount of USDC the trade is for (excluding fees).
     * @param _discordTradeId Unique Discord trade identifier (keccak256 hash of Discord trade ID string).
     */
    function createAndFundTrade(
        address _seller,
        uint256 _tradeAmount,
        bytes32 _discordTradeId
    ) external nonReentrant returns (uint256) {
        require(_seller != address(0), 'invalid address');
        require(msg.sender != _seller, 'buyer cannot be seller');
        require(_tradeAmount > 0, 'amount must be greater than 0');

        // Check if Discord trade already funded (prevents double-spend)
        require(
            discordTradeIdToOnChainId[_discordTradeId] == 0,
            'Discord trade already funded'
        );

        // Calculate required funding: Amount + 2.5%
        uint256 buyerFee = (_tradeAmount * FEE_BPS) / 10000;
        uint256 requiredTotal = _tradeAmount + buyerFee;

        // Transfer USDC from buyer to this contract
        // SafeERC20 handles the require(success) check automatically
        usdc.safeTransferFrom(msg.sender, address(this), requiredTotal);

        tradeCount++;
        uint256 id = tradeCount;

        // Store Discord trade ID mapping
        discordTradeIdToOnChainId[_discordTradeId] = id;

        trades[id] = Trade({
            tradeId: id,
            buyer: msg.sender,
            seller: _seller,
            amount: _tradeAmount,
            status: TradeStatus.Funded,
            deliveryTimestamp: 0,
            pendingFee: buyerFee
        });

        emit Created(id, msg.sender, _seller, _tradeAmount);
        emit BuyerFeeCollected(id, buyerFee);
        emit Funded(id, msg.sender, _tradeAmount);
        emit TradeLinkedToDiscord(_discordTradeId, id);

        return id;
    }

    /**
     * @notice Check if a Discord trade has already been funded.
     * @param _discordTradeId The keccak256 hash of the Discord trade ID.
     * @return True if the Discord trade has been funded, false otherwise.
     */
    function isDiscordTradeFunded(bytes32 _discordTradeId) external view returns (bool) {
        return discordTradeIdToOnChainId[_discordTradeId] != 0;
    }

    // --- DELIVERY (Triggered by Seller via Discord -> Bot) ---
    function markDelivered(uint256 tradeId) external onlyBot {
        require(tradeId > 0 && tradeId <= tradeCount, 'invalid trade id');

        Trade storage t = trades[tradeId];

        require(
            t.status == TradeStatus.Funded,
            "can only mark delivered at 'funded' state"
        );
        t.status = TradeStatus.Delivered;
        t.deliveryTimestamp = block.timestamp;
        emit Delivered(tradeId, t.seller);
    }

    // --- RELEASE (Triggered by Buyer via Discord -> Bot) ---
    function approveDelivery(uint256 tradeId) external onlyBot nonReentrant {
        require(tradeId > 0 && tradeId <= tradeCount, 'invalid trade id');

        Trade storage t = trades[tradeId];

        require(
            t.status == TradeStatus.Delivered,
            "can only approve delivery at 'delivered' state"
        );
        emit Approved(tradeId, t.buyer);
        _release(tradeId);
    }

    // --- AUTO RELEASE (Optional safety net) ---
    function releaseAfterTimeout(uint256 tradeId) external onlyBot nonReentrant {
        require(tradeId > 0 && tradeId <= tradeCount, 'invalid trade id');

        Trade storage t = trades[tradeId];

        require(
            t.status == TradeStatus.Delivered,
            "can only auto release at 'delivered' state"
        );
        require(
            block.timestamp >= t.deliveryTimestamp + releaseTimeout,
            'timeout not reached'
        );
        _release(tradeId);
    }

    // Internal release logic
    function _release(uint256 tradeId) internal {
        require(tradeId > 0 && tradeId <= tradeCount, 'invalid trade id');

        Trade storage t = trades[tradeId];

        require(t.status != TradeStatus.Completed, 'already completed');
        t.status = TradeStatus.Completed;

        uint256 sellerFee = (t.amount * FEE_BPS) / 10000;
        uint256 payout = t.amount - sellerFee;

        emit SellerFeeCollected(tradeId, sellerFee);

        // Accumulate seller fee with pending buyer fee
        uint256 totalFee = t.pendingFee + sellerFee;
        t.pendingFee = 0;

        // Transfer payout to seller
        usdc.safeTransfer(t.seller, payout);
        
        // Handle Fees: Swap to ETH or fallback to USDC transfer
        _swapFeesToETH(totalFee);

        emit Released(tradeId, t.seller, payout);
    }

    /**
     * @notice Swaps USDC fees to ETH and sends to feeReceiver.
     * @dev Falls back to sending USDC if swap fails.
     */
    function _swapFeesToETH(uint256 usdcAmount) internal {
        if (usdcAmount == 0) return;

        try this._performSwap(usdcAmount) returns (uint256 ethReceived) {
            emit FeeConverted(usdcAmount, ethReceived);
        } catch {
            // Fallback: Transfer USDC if swap fails
            usdc.safeTransfer(feeReceiver, usdcAmount);
            emit FeeConversionFailed(usdcAmount, "Swap reverted");
        }
    }

    /**
     * @notice External function to perform the swap (needed for try/catch)
     * @dev Only callable by this contract
     */
    function _performSwap(uint256 usdcAmount) external returns (uint256) {
        require(msg.sender == address(this), "internal use only");

        // Approve Router
        usdc.safeApprove(address(swapRouter), usdcAmount);

        // Swap USDC -> WETH
        ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02.ExactInputSingleParams({
            tokenIn: address(usdc),
            tokenOut: address(weth),
            fee: POOL_FEE,
            recipient: address(this), // Receive WETH here to unwrap
            amountIn: usdcAmount,
            amountOutMinimum: 0, // Accept market price for fees
            sqrtPriceLimitX96: 0
        });

        uint256 wethAmount = swapRouter.exactInputSingle(params);

        // Unwrap WETH -> ETH
        weth.withdraw(wethAmount);

        // Transfer ETH to feeReceiver
        (bool success, ) = feeReceiver.call{value: wethAmount}("");
        require(success, "ETH transfer failed");

        return wethAmount;
    }

    // --- DISPUTE ---
    function openDispute(uint256 tradeId, address raisedBy) external onlyBot {
        require(tradeId > 0 && tradeId <= tradeCount, 'invalid trade id');

        Trade storage t = trades[tradeId];

        require(
            t.status == TradeStatus.Delivered,
            'can dispute only after delivery'
        );
        require(
            raisedBy == t.buyer || raisedBy == t.seller,
            'invalid dispute raiser'
        );

        t.status = TradeStatus.Disputed;
        emit Disputed(tradeId, raisedBy);
    }

    function resolveDispute(
        uint256 tradeId,
        uint256 buyerShareBps,
        uint256 sellerShareBps
    ) external onlyBot nonReentrant {
        require(tradeId > 0 && tradeId <= tradeCount, 'invalid trade id');

        Trade storage t = trades[tradeId];

        require(t.status == TradeStatus.Disputed, 'not in dispute');
        require(buyerShareBps + sellerShareBps == 10000, 'invalid split');

        t.status = TradeStatus.Completed;

        // Only charge seller fee on dispute resolution (buyer fee already collected)
        uint256 sellerFee = (t.amount * FEE_BPS) / 10000;
        uint256 distributable = t.amount - sellerFee;

        uint256 buyerPayout = (distributable * buyerShareBps) / 10000;
        uint256 sellerPayout = (distributable * sellerShareBps) / 10000;

        emit SellerFeeCollected(tradeId, sellerFee);

        // Accumulate seller fee with pending buyer fee
        uint256 totalFee = t.pendingFee + sellerFee;
        t.pendingFee = 0;

        // Payouts
        if (buyerPayout > 0) {
            usdc.safeTransfer(t.buyer, buyerPayout);
        }

        if (sellerPayout > 0) {
            usdc.safeTransfer(t.seller, sellerPayout);
        }

        // Handle Fees: Swap to ETH or fallback to USDC transfer
        _swapFeesToETH(totalFee);

        emit Refunded(tradeId, t.buyer, buyerPayout);
        emit Released(tradeId, t.seller, sellerPayout);
    }

    // --- ADMIN FUNCTIONS ---

    /**
     * @notice Refunds the buyer for a trade that is stuck in Funded status.
     * @dev Can only be called by the bot or owner. Only works for Funded trades.
     * @param tradeId The on-chain trade ID to refund.
     */
    function refundBuyer(uint256 tradeId) external onlyBotOrOwner nonReentrant {
        require(tradeId > 0 && tradeId <= tradeCount, 'invalid trade id');

        Trade storage t = trades[tradeId];

        require(t.status == TradeStatus.Funded, "can only refund at 'funded' state");
        
        t.status = TradeStatus.Cancelled;

        // Refund only the trade amount (fees are forfeited)
        usdc.safeTransfer(t.buyer, t.amount);

        emit Refunded(tradeId, t.buyer, t.amount);
    }

    /**
     * @notice Emergency withdrawal of any ERC20 token from the contract.
     * @dev Only owner can call. Use with caution - for recovering stuck/mistaken tokens.
     * @param token The ERC20 token address to withdraw.
     * @param amount The amount to withdraw.
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        require(token != address(0), 'invalid token address');
        require(amount > 0, 'amount must be greater than 0');

        IERC20(token).safeTransfer(owner(), amount);
        emit EmergencyWithdrawal(token, amount, owner());
    }

    /**
     * @notice Updates the bot address for key rotation.
     * @dev Only owner can call.
     * @param newBot The new bot address.
     */
    function setBot(address newBot) external onlyOwner {
        require(newBot != address(0), 'invalid bot address');
        address oldBot = bot;
        bot = newBot;
        emit BotUpdated(oldBot, newBot);
    }

    /**
     * @notice Updates the fee receiver address.
     * @dev Only owner can call.
     * @param newFeeReceiver The new fee receiver address.
     */
    function setFeeReceiver(address newFeeReceiver) external onlyOwner {
        require(newFeeReceiver != address(0), 'invalid fee receiver address');
        address oldFeeReceiver = feeReceiver;
        feeReceiver = newFeeReceiver;
        emit FeeReceiverUpdated(oldFeeReceiver, newFeeReceiver);
    }

    // Allow contract to receive ETH from WETH.withdraw
    receive() external payable {}
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH9 {
    function withdraw(uint256 wad) external;
}
