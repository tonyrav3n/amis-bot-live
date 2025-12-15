// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

contract AmisEscrowManagerUSDC is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;

    uint256 public constant FEE_BPS = 250;
    uint256 public constant TOTAL_FEE_BPS = 500;
    uint256 public constant BOT_SHARE_BPS = 100;

    address public bot;
    address public feeReceiver;
    uint256 public tradeCount;

    uint256 public immutable releaseTimeout = 1 days;

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
        uint256 pendingBotFee;
        uint256 pendingfeeReceiverFee;
    }

    mapping(uint256 => Trade) public trades;

    // ✅ NEW: Mapping to prevent duplicate funding per Discord trade
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
    event BuyerFeeSplit(
        uint256 indexed tradeId,
        uint256 buyerFee,
        uint256 botFee,
        uint256 feeReceiverFee
    );
    event SellerFeeSplit(
        uint256 indexed tradeId,
        uint256 sellerFee,
        uint256 botFee,
        uint256 feeReceiverFee
    );
    event TradeLinkedToDiscord(
        bytes32 indexed discordTradeId,
        uint256 indexed onChainTradeId
    );

    modifier onlyBot() {
        require(msg.sender == bot, 'only bot can call this');
        _;
    }

    /**
     * @param _bot The address of the bot.
     * @param _feeReceiver The address collecting fees.
     * @param _usdc The address of the USDC contract on Base.
     * Note: Base USDC Address is usually 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
     */
    constructor(address _bot, address _feeReceiver, address _usdc) {
        require(_bot != address(0) && _feeReceiver != address(0) && _usdc != address(0), 'invalid addr');
        bot = _bot;
        feeReceiver = _feeReceiver;
        usdc = IERC20(_usdc);
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

        // ✅ NEW: Check if Discord trade already funded (prevents double-spend)
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

        // ✅ NEW: Store Discord trade ID mapping
        discordTradeIdToOnChainId[_discordTradeId] = id;

        // Calculate fee splits
        uint256 botFee = (buyerFee * BOT_SHARE_BPS) / TOTAL_FEE_BPS;
        uint256 feeReceiverFee = buyerFee - botFee;

        trades[id] = Trade({
            tradeId: id,
            buyer: msg.sender,
            seller: _seller,
            amount: _tradeAmount,
            status: TradeStatus.Funded,
            deliveryTimestamp: 0,
            pendingBotFee: botFee,
            pendingfeeReceiverFee: feeReceiverFee
        });

        emit Created(id, msg.sender, _seller, _tradeAmount);
        emit BuyerFeeSplit(id, buyerFee, botFee, feeReceiverFee);
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

        uint256 botFee = (sellerFee * BOT_SHARE_BPS) / TOTAL_FEE_BPS;
        uint256 feeReceiverFee = sellerFee - botFee;

        emit SellerFeeSplit(tradeId, sellerFee, botFee, feeReceiverFee);

        t.pendingBotFee += botFee;
        t.pendingfeeReceiverFee += feeReceiverFee;

        uint256 botAmount = t.pendingBotFee;
        uint256 receiverAmount = t.pendingfeeReceiverFee;

        t.pendingBotFee = 0;
        t.pendingfeeReceiverFee = 0;

        // Transfers using SafeERC20
        usdc.safeTransfer(t.seller, payout);
        usdc.safeTransfer(bot, botAmount);
        usdc.safeTransfer(feeReceiver, receiverAmount);

        emit Released(tradeId, t.seller, payout);
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

        uint256 totalFee = (t.amount * FEE_BPS) / 10000;
        uint256 distributable = t.amount - totalFee;

        uint256 buyerPayout = (distributable * buyerShareBps) / 10000;
        uint256 sellerPayout = (distributable * sellerShareBps) / 10000;

        uint256 botFee = (totalFee * BOT_SHARE_BPS) / TOTAL_FEE_BPS;
        uint256 feeReceiverFee = totalFee - botFee;

        t.pendingBotFee += botFee;
        t.pendingfeeReceiverFee += feeReceiverFee;

        uint256 botAmount = t.pendingBotFee;
        uint256 receiverAmount = t.pendingfeeReceiverFee;

        t.pendingBotFee = 0;
        t.pendingfeeReceiverFee = 0;

        // Payouts
        if (buyerPayout > 0) {
            usdc.safeTransfer(t.buyer, buyerPayout);
        }

        if (sellerPayout > 0) {
            usdc.safeTransfer(t.seller, sellerPayout);
        }

        usdc.safeTransfer(bot, botAmount);
        usdc.safeTransfer(feeReceiver, receiverAmount);

        emit Refunded(tradeId, t.buyer, buyerPayout);
        emit Released(tradeId, t.seller, sellerPayout);
    }
}
