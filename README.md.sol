// SPDX-License-Identifier: MIT
pragma solidity 0.5.12;

import {IERC20} from "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "@chainlink/contracts/src/v0.5/ChainlinkClient.sol";
import "./PoolManager.sol";
import "./ConditionalToken.sol";

contract Market is Ownable, ChainlinkClient {
    event Created(uint indexed marketID, uint _time);
    event Paused(uint indexed marketID, uint _time);
    event Resumed(uint indexed marketID, uint _time);
    event Closed(uint indexed marketID, uint _time);
    event Buy(uint indexed marketID, uint _time);
    event Redeem(uint indexed marketID, uint _time);
    event NewToken(address indexed contractAddress, uint _time);

    enum Status {Running, Pending, Paused, Closed}

    struct MarketStruct {
        bool exist;
        uint marketID;
        uint baseCurrencyID;
        uint initialPrice;
        uint finalPrice;
        uint created;
        uint duration;
        uint totalDeposit;
        uint totalRedemption;
        Status status;
        address collateralToken;
        address bearToken;
        address bullToken;
        address pool;
    }

    mapping(uint => MarketStruct) public markets;
    mapping(uint => string) public baseCurrencyList;
    mapping(address => bool) public collateralList;
    mapping(address => uint8) public collateralDecimalsList;
    mapping(bytes32 => uint) public requestToMarketID;

    PoolManager public poolManager;

    address private chainlinkOracle;
    bytes32 private chainlinkJobID;
    uint256 private chainlinkFee;

    uint public currentMarketID = 1;
    uint public CONDITIONAL_TOKEN_WEIGHT;
    uint public COLLATERAL_TOKEN_WEIGHT;

    constructor(address _poolManager) public {
        CONDITIONAL_TOKEN_WEIGHT = SafeMath.mul(10**18, uint(10));
        COLLATERAL_TOKEN_WEIGHT  = SafeMath.mul(CONDITIONAL_TOKEN_WEIGHT, uint(2));

        poolManager = PoolManager(_poolManager);
        
        chainlinkOracle = 0x72f3dFf4CD17816604dd2df6C2741e739484CA62; //https://market.link/nodes/0x72f3dFf4CD17816604dd2df6C2741e739484CA62/jobs?network=1
        chainlinkJobID = "5d1f6593e5c74d03ac9c24f4072745e0"; //https://market.link/jobs/fd1d35a3-5a30-49fb-95c9-81eb45d16238?network=1
        chainlinkFee = 0.1 * 10 ** 18; // 0.1 LINK

        baseCurrencyList[1] = "BTC";
    }

    function requestInitialPrice(string memory symbol) internal returns (bytes32 requestId) {
        Chainlink.Request memory request = buildChainlinkRequest(chainlinkJobID, address(this), this.fulfillInitialPrice.selector);
        
        request.add("get", string(abi.encodePacked("https://min-api.cryptocompare.com/data/price?fsym=", symbol, "&tsyms=USD")));
        request.add("path", "USD");
        
        return sendChainlinkRequestTo(chainlinkOracle, request, chainlinkFee);
    }
    
    function fulfillInitialPrice(bytes32 _requestId, uint _price) public recordChainlinkFulfillment(_requestId)
    {
        require(
            requestToMarketID[_requestId] > 0,
            "Invalid request"
        );
        
        markets[requestToMarketID[_requestId]].initialPrice = _price;
        markets[requestToMarketID[_requestId]].status = Status.Running;

        emit Created(currentMarketID, now);
    }

    function requestFinalPrice(string memory symbol) internal returns (bytes32 requestId) {
        Chainlink.Request memory request = buildChainlinkRequest(chainlinkJobID, address(this), this.fulfillFinalPrice.selector);
        
        request.add("get", string(abi.encodePacked("https://min-api.cryptocompare.com/data/price?fsym=", symbol, "&tsyms=USD")));
        request.add("path", "USD");
        
        return sendChainlinkRequestTo(chainlinkOracle, request, chainlinkFee);
    }
    
    function fulfillFinalPrice(bytes32 _requestId, uint _price) public recordChainlinkFulfillment(_requestId)
    {
        require(
            requestToMarketID[_requestId] > 0,
            "Invalid request"
        );
        
        markets[requestToMarketID[_requestId]].finalPrice = _price;
        markets[requestToMarketID[_requestId]].status = Status.Closed;

        emit Closed(markets[requestToMarketID[_requestId]].marketID, now);
    }

    function cloneToken(string memory _name, string memory _symbol, uint8 _decimals) internal onlyOwner returns (ConditionalToken) {
        ConditionalToken token = new ConditionalToken(_name, _symbol, _decimals);
        emit NewToken(address(token), now);
        return token;
    }

    function calcSwapFee(uint8 _decimals) public pure returns (uint) {
        return SafeMath.mul(uint(3), SafeMath.div((uint(10) ** uint(_decimals)), uint(1000))); // 0.3%
    }

    function create(uint _baseCurrencyID, uint _duration, address _collateralToken, uint _collateralAmount)
        public
    {
        require(
            bytes(baseCurrencyList[_baseCurrencyID]).length > 0,
            "Invalid base currency"
        );
        require(
            collateralList[_collateralToken] != false,
            "Invalid collateral"
        );
        require(
            _duration >= 600 seconds && _duration < 365 days,
            "Invalid duration"
        );

        uint8 _collateralDecimals = collateralDecimalsList[_collateralToken];

        //Create two ERC20 tokens
        ConditionalToken _bearToken = cloneToken("Bear", "Bear", _collateralDecimals);
        ConditionalToken _bullToken = cloneToken("Bull", "Bull", _collateralDecimals);

        //Calculate conditional tokens amount
        uint _conditionalAmount = SafeMath.div(_collateralAmount, uint(2));

        //Create balancer pool
        BPool _pool = poolManager.createPool();

        //Mint both tokens
        _bearToken.mint(address(this), _conditionalAmount);
        _bullToken.mint(address(this), _conditionalAmount);

        IERC20 collateral = IERC20(_collateralToken);

        //Deposit collateral token
        collateral.transferFrom(msg.sender, address(this), _collateralAmount);

        //Approve tokens for binding by a pool
        poolManager.approveToken(_collateralToken, address(_pool), _collateralAmount);
        poolManager.approveToken(address(_bearToken), address(_pool), _conditionalAmount);
        poolManager.approveToken(address(_bullToken), address(_pool), _conditionalAmount);

        //Bind tokens to the pool
        poolManager.bindToken(address(_pool), _collateralToken, _collateralAmount, COLLATERAL_TOKEN_WEIGHT);
        poolManager.bindToken(address(_pool), address(_bearToken), _conditionalAmount, CONDITIONAL_TOKEN_WEIGHT);
        poolManager.bindToken(address(_pool), address(_bullToken), _conditionalAmount, CONDITIONAL_TOKEN_WEIGHT);

        //Calculate swap fee
        uint _swapFee = calcSwapFee(_collateralDecimals);

        //Set swap fee
        poolManager.setFee(address(_pool), _swapFee);

        //Release the pool and allow public swaps
        poolManager.setPublic(address(_pool), true);

        MarketStruct memory marketStruct =
            MarketStruct({
                exist: true,
                status: Status.Pending,
                marketID: currentMarketID,
                baseCurrencyID: _baseCurrencyID,
                initialPrice: 0,
                finalPrice: 0,
                created: now,
                duration: _duration,
                totalDeposit: 0,
                totalRedemption: 0,
                collateralToken: _collateralToken,
                bearToken: address(_bearToken),
                bullToken: address(_bullToken),
                pool: address(_pool)
            });

        markets[currentMarketID] = marketStruct;

        // TODO:
        bytes32 requestID = requestInitialPrice(baseCurrencyList[_baseCurrencyID]);
        requestToMarketID[requestID] = currentMarketID;

        // markets[currentMarketID].initialPrice = 100;
        // markets[currentMarketID].status = Status.Running;

        //Increment current market ID
        currentMarketID++;
    }

    function pause(uint _marketID) public onlyOwner {
        require(markets[_marketID].exist, "Market doesn't exist");
        require(markets[_marketID].status == Status.Running, "Invalid status");

        markets[_marketID].status = Status.Paused;

        emit Paused(_marketID, now);
    }

    function resume(uint _marketID) public onlyOwner {
        require(markets[_marketID].exist, "Market doesn't exist");
        require(markets[_marketID].status == Status.Paused, "Invalid status");

        markets[_marketID].status = Status.Running;

        emit Resumed(_marketID, now);
    }

    function close(uint _marketID) public onlyOwner {
        require(markets[_marketID].exist, "Market doesn't exist");
        require(
            markets[_marketID].status == Status.Running ||
                markets[_marketID].status == Status.Paused,
            "Market has already been closed"
        );
        require(
            SafeMath.add(
                markets[_marketID].created,
                markets[_marketID].duration
            ) > now,
            "Market closing time hasn't yet arrived"
        );

        // TODO:
        bytes32 requestID = requestFinalPrice(baseCurrencyList[markets[_marketID].baseCurrencyID]);
        requestToMarketID[requestID] = _marketID;

        // markets[currentMarketID].initialPrice = 200;
        // markets[currentMarketID].status = Status.Closed;
    }

    //Buy new token pair for collateral token
    function buy(uint _marketID, uint _amount) external {
        require(markets[_marketID].exist, "Market doesn't exist");
        require(markets[_marketID].status == Status.Running, "Invalid status");
        require(_amount > 0, "Invalid amount");

        IERC20 collateral = IERC20(markets[_marketID].collateralToken);
        ConditionalToken bearToken = ConditionalToken(markets[_marketID].bearToken);
        ConditionalToken bullToken = ConditionalToken(markets[_marketID].bullToken);

        //Deposit collateral
        require(collateral.transferFrom(msg.sender, address(this), _amount));

        //Calculate conditional tokens amount
        uint _conditionalAmount = SafeMath.div(_amount, uint(2));

        //Mint both tokens for user
        bearToken.mint(msg.sender, _conditionalAmount);
        bullToken.mint(msg.sender, _conditionalAmount);

        //Increase total deposited collateral
        markets[_marketID].totalDeposit = SafeMath.add(
            markets[_marketID].totalDeposit,
            _amount
        );

        emit Buy(_marketID, now);
    }

    function redeem(uint _marketID, uint _amount) external {
        require(markets[_marketID].exist, "Market doesn't exist");
        require(markets[_marketID].status == Status.Closed, "Invalid status");
        require(_amount > 0, "Invalid amount");
        require(
            markets[_marketID].totalDeposit >=
                markets[_marketID].totalRedemption,
            "No collateral left"
        );

        //Determine winning token address
        address winningTokenAddress;

        if (markets[_marketID].finalPrice > markets[_marketID].initialPrice) {
            winningTokenAddress = markets[_marketID].bearToken;
        } else {
            winningTokenAddress = markets[_marketID].bullToken;
        }

        //TODO: Price didn't change

        //Deposit winningToken
        ConditionalToken winningToken = ConditionalToken(winningTokenAddress);

        require(winningToken.transferFrom(msg.sender, address(this), _amount));

        //Burn winningToken
        winningToken.burn(address(this), _amount);

        //Send collateral to user
        IERC20 collateral = IERC20(markets[_marketID].collateralToken);

        require(collateral.transferFrom(address(this), msg.sender, _amount));

        //Increase total redemed collateral
        markets[_marketID].totalRedemption = SafeMath.add(
            markets[_marketID].totalRedemption,
            _amount
        );

        emit Redeem(_marketID, now);
    }

    function setBaseCurrencyList(
        uint _baseCurrencyID,
        string memory _title
    ) public onlyOwner {
        baseCurrencyList[_baseCurrencyID] = _title;
    }

    function setCollateral(
        address _collateral,
        bool _value,
        uint8 _decimals
    ) public onlyOwner {
        collateralList[_collateral] = _value;
        collateralDecimalsList[_collateral] = _decimals;
    }

    function viewMarketExist(uint _marketID) public view returns (bool) {
        return markets[_marketID].exist;
    }

    function setChainlink(address _chainlinkOracle, bytes32 _chainlinkJobID, uint256 _chainlinkFee) public onlyOwner {
        chainlinkOracle = _chainlinkOracle;
        chainlinkJobID = _chainlinkJobID;
        chainlinkFee = _chainlinkFee;
    }

    function setLinkToken(address _link) public onlyOwner {
        // If the address passed in for _link is zero
        if(_link == address(0)) {
            // Detect what public network the contract is on
            setPublicChainlinkToken();
        } else {
            // Otherwise set the address to what was passed in
            setChainlinkToken(_link);
        }
    }
}
