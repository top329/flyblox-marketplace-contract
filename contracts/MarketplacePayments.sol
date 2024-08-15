// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import "./IBEP20.sol";
import "./Ownable.sol";

contract MarketplacePayments is Ownable {
    enum State {
        Pending,
        Completed,
        Released,
        Reverted,
        Disputed,
        RefundAccepted,
        IncHoldingAccepted
    }

    struct Order {
        uint256 orderId;
        address buyer;
        address seller;
        uint256 deliverDate;
        uint256 holdingPeriod;
        address paymentToken;
        uint256 amount;
        uint256 fee;
        State state;
        uint256 createdAt;
        uint256 completedAt;
        uint256 releasedAt;
        uint256 revertedAt;
    }

    uint256 private totalOrders = 0;

    mapping(uint256 => Order) orders;
    mapping(address => bool) allowedTokens;

    uint256 fee = 20;

    modifier condition(bool _condition, string memory message) {
        require(_condition, message);
        _;
    }

    event OrderCreated(uint256 orderId);

    event OrderCompleted(uint256 orderId, address indexed caller);
    event OrderReverted(uint256 orderId, address indexed caller);
    event OrderCompletedAndReleased(uint256 orderId, address indexed caller);
    event OrderHoldingPeriodUpdated(uint256 orderId, address indexed caller);


    function isTokenAllowed(address _tokenAddress) public view returns (bool) {
        return allowedTokens[_tokenAddress];
    }

    function updateTokensList(
        address _tokenAddress,
        bool allowed
    ) public onlyOwner returns (bool) {
        allowedTokens[_tokenAddress] = allowed;
        return true;
    }

    function createAndDeposit(
        address sellerAddress,
        uint256 deliverDateTimestamp,
        uint256 holdingPeriod,
        address _paymentToken,
        uint256 _amount
    )
        public
        condition(
            sellerAddress != _msgSender(),
            "Error: Seller cannot be buyer"
        )
        condition(deliverDateTimestamp > block.timestamp, "Error: Invalid Due date")
        condition(allowedTokens[_paymentToken], "Error: Invalid payment token")
        condition(_amount > 0, "Error: Invalid amount")
        returns (bool)
    {
        totalOrders += 1;
        Order storage order = orders[totalOrders];
        order.orderId = totalOrders;
        order.seller = sellerAddress;
        order.buyer = _msgSender();
        order.deliverDate = deliverDateTimestamp;
        order.holdingPeriod = holdingPeriod;
        order.paymentToken = _paymentToken;
        order.state = State.Pending;
        order.amount = _amount;
        order.fee = fee;
        order.createdAt = block.timestamp;

        IBEP20(_paymentToken).transferFrom(
            _msgSender(),
            address(this),
            _amount
        );

        emit OrderCreated(totalOrders);
        return true;
    }

    function markComplete(uint256 orderId)
        public
        condition((orders[orderId].buyer==_msgSender()||_msgSender()== owner()), "Error: Caller not buyer/owner")   
        condition(orders[orderId].state==State.Pending, "Error: Invalid current state")   
        returns (bool)     
    {
        Order storage order = orders[orderId];    
        order.state = State.Completed;
        order.completedAt = block.timestamp;

        emit OrderCompleted(orderId,_msgSender());

        return true;
     }

    function markCompleteAndReleaseFundsToSeller(
        uint256 orderId
    )
        public
        condition(
            (orders[orderId].buyer == _msgSender() || _msgSender() == owner()),
            "Error: Caller not buyer/owner"
        )
        condition(
            (orders[orderId].state == State.Pending && orders[orderId].state != State.Disputed && orders[orderId].state != State.Completed),
            "Error: Invalid current state"
        )
    {
        Order storage order = orders[orderId];
        order.completedAt = block.timestamp;
        order.releasedAt = block.timestamp;
        order.state = State.Released;

        emit OrderCompletedAndReleased(orderId, _msgSender());
        uint256 feeValue = (order.amount * fee) / 10 ** 3;
        IBEP20(order.paymentToken).transfer(
            order.seller,
            order.amount - feeValue
        );
        IBEP20(order.paymentToken).transfer(owner(), feeValue);
    }

    function claimFundsFromContract(
        uint256 orderId
    )
        public
        condition(
            orders[orderId].state != State.Disputed,
            "Error: Order is disputed"
        )
        condition(
            (orders[orderId].seller == _msgSender() || _msgSender() == owner()),
            "Error: Caller not seller/owner"
        )
        condition(
            (orders[orderId].deliverDate + orders[orderId].holdingPeriod) < block.timestamp,
            "Error: Cannot claim funds during holding period"
        )
    {
        Order storage order = orders[orderId];
        order.completedAt = block.timestamp;
        order.state = State.Completed;

        emit OrderCompleted(orderId, _msgSender());
        uint256 feeValue = (order.amount * fee) / 10 ** 3;
        IBEP20(order.paymentToken).transfer(
            order.seller,
            order.amount - feeValue
        );
        IBEP20(order.paymentToken).transfer(owner(), feeValue);
    }

    function refund(
        uint256 orderId
    )
        public
        condition(
            orders[orderId].state != State.Disputed,
            "Error: Order is disputed"
        )
        condition(
            (orders[orderId].buyer == _msgSender() || _msgSender() == owner()),
            "Error: Caller not buyer/owner"
        )
        condition(
            (orders[orderId].deliverDate + orders[orderId].holdingPeriod) > block.timestamp,
            "Error: Holding Period is expired."
        )
        condition(
            (orders[orderId].state == State.RefundAccepted),
            "Error: Seller has not accepted refund"
        )
    {
        Order storage order = orders[orderId];
        order.state = State.Reverted;
        order.revertedAt = block.timestamp;
        emit OrderReverted(orderId, _msgSender());
        IBEP20(order.paymentToken).transfer(
            order.buyer,
            order.amount
        );
    }

    function acceptRefund(
        uint256 orderId
    )
        public
        condition(
            orders[orderId].state != State.Disputed,
            "Error: Order is disputed"
        )
        condition(
            (orders[orderId].seller == _msgSender() || _msgSender() == owner()),
            "Error: Caller not seller/owner"
        )
        condition(
            (orders[orderId].deliverDate + orders[orderId].holdingPeriod) > block.timestamp,
            "Error: Holding period is expired"
        )
    {
        Order storage order = orders[orderId];
        order.state = State.RefundAccepted;
    }

    function sellerIncHoldingTime(
        uint256 orderId,
        uint256 _newHoldingTime
    )
        public
        condition(
            orders[orderId].state != State.Disputed,
            "Error: Order is disputed"
        )
        condition(
            (orders[orderId].seller == _msgSender() || _msgSender() == owner()),
            "Error: Caller not seller/owner"
        )
        condition(
            (orders[orderId].deliverDate + orders[orderId].holdingPeriod) > block.timestamp,
            "Error: Holding period is expired"
        )
        condition(
            _newHoldingTime > orders[orderId].holdingPeriod,
            "Error: New holding time cannot be smaller than current holding time"
        )
        condition(
            (orders[orderId].state == State.Pending && orders[orderId].state == State.IncHoldingAccepted),
            "Error: Buyer has not accepted holding time increase"
        )
    {
        Order storage order = orders[orderId];
        order.holdingPeriod = _newHoldingTime;
        emit OrderHoldingPeriodUpdated(orderId, _msgSender());
    }

    function buyerIncHoldingTime(
        uint256 orderId,
        uint256 _newHoldingTime
    )
        public
        condition(
            orders[orderId].state != State.Disputed,
            "Error: Order is disputed"
        )
        condition(
            (orders[orderId].buyer == _msgSender() || _msgSender() == owner()),
            "Error: Seller not seller/owner"
        )
        condition(
            (orders[orderId].deliverDate + orders[orderId].holdingPeriod) > block.timestamp,
            "Error: Holding period is expired"
        )
        condition(
            _newHoldingTime > orders[orderId].holdingPeriod,
            "Error: New holding time cannot be smaller than current holding time"
        )
        condition(
            (orders[orderId].state == State.IncHoldingAccepted), 
            "Error: Seller has not accepted holding time increase"
        )
    {
        Order storage order = orders[orderId];
        order.holdingPeriod = _newHoldingTime;
        emit OrderHoldingPeriodUpdated(orderId, _msgSender());
    }

    function sellerAcceptIncHoldingTime(
        uint256 orderId
    )
        public
        condition(
            orders[orderId].state != State.Disputed,
            "Error: Order is disputed"
        )
        condition(
            (orders[orderId].seller == _msgSender() || _msgSender() == owner()),
            "Error: Caller not seller/owner"
        )
        condition(
            (orders[orderId].deliverDate + orders[orderId].holdingPeriod) > block.timestamp,
            "Error: Holding period is expired"
        )
        condition(
            orders[orderId].state == State.Pending,
            "Error: Order state is not pending"
        )
    {
        Order storage order = orders[orderId];
        order.state = State.IncHoldingAccepted;
    }

    function disputeOrder(uint256 orderId)
        public
        condition(
            (orders[orderId].deliverDate + orders[orderId].holdingPeriod) > block.timestamp,
            "Error: Holding period is expired"
        )
        condition(
            orders[orderId].state != State.Completed,
            "Error: Order is already completed"
        )
    {
        Order storage order = orders[orderId];
        order.state = State.Disputed;
    }

    function setTransactionFee(
        uint256 _newFee
    )
        public
        condition(owner() == _msgSender(), "Error: Caller not owner")
        returns (bool)
    {
        fee = _newFee;
        return true;
    }

    function orderDetails(
        uint256 orderId
    )
        public
        view
        condition(
            (orders[orderId].seller == _msgSender() ||
                _msgSender() == owner() ||
                orders[orderId].buyer == _msgSender()),
            "Error: Caller not seller/buyer/owner"
        )
        returns (
            address buyer,
            address seller,
            address paymentToken,
            State state,
            uint256 deliverDate,
            uint256 amount,
            uint256 fees,
            uint256 createdAt,
            uint256 releasedAt,
            uint256 completedAt
        )
    {
        Order memory order = orders[orderId];
        return (
            order.buyer,
            order.seller,
            order.paymentToken,
            order.state,
            order.deliverDate,
            order.amount,
            order.fee,
            order.createdAt,
            order.releasedAt,
            order.completedAt
        );
    }
}
