pragma solidity 0.8.6;

contract TownCrier {
    struct Request { // the data structure for each request
        address requester; // the address of the requester
        uint fee; // the amount of wei the requester pays for the request
        address callbackAddr; // the address of the contract to call for delivering response
        bytes4 callbackFID; // the specification of the callback function
        bytes32 paramsHash; // the hash of the request parameters
    }

    event Upgrade(address newAddr);
    event Reset(uint gas_price, uint min_fee, uint cancellation_fee);
    event RequestInfo(uint64 id, uint8 requestType, address requester, uint fee, address callbackAddr, bytes32 paramsHash, uint timestamp, bytes32[] requestData); // log of requests, the Town Crier server watches this event and processes requests
    event DeliverInfo(uint64 requestId, uint fee, uint gasPrice, uint gasLeft, uint callbackGas, bytes32 paramsHash, uint64 error, bytes32 respData); // log of responses
    event Cancel(uint64 requestId, address canceller, address requester, uint fee, int flag); // log of cancellations

    // address of the SGX account (mainnet)
    /* address public constant SGX_ADDRESS = 0x18513702cCd928F2A3eb63d900aDf03c9cc81593; */
    // FUZZ: we use a fuzzer-controlled SGX_ADDR
    address public constant SGX_ADDRESS = address(0x00c04689c0c5d48cec7275152b3026b53f6f78d03d);
    // FUZZ: fees are sent to a non-fuzzer controlled address
    address payable constant SGX_FEE_ADDR = payable(0xcf7C6611373327E75f8eF1bEEF8227AfB89816Dd);

    uint public GAS_PRICE = 5 * 10**10;
    uint public MIN_FEE = 30000 * GAS_PRICE; // minimum fee required for the requester to pay such that SGX could call deliver() to send a response
    uint public CANCELLATION_FEE = 25000 * GAS_PRICE; // charged when the requester cancels a request that is not responded

    uint public constant CANCELLED_FEE_FLAG = 1;
    uint public constant DELIVERED_FEE_FLAG = 0;
    int public constant FAIL_FLAG = -2 ** 250;
    int public constant SUCCESS_FLAG = 1;

    bool public killswitch;

    bool public externalCallFlag;

    uint64 public requestCnt;
    uint64 public unrespondedCnt;
    mapping(uint => Request) public requests;

    int public newVersion = 0;

    event AssertionFailed();

    receive() external payable {}

    constructor() {
        // Start request IDs at 1 for two reasons:
        //   1. We can use 0 to denote an invalid request (ids are unsigned)
        //   2. Storage is more expensive when changing something from zero to non-zero,
        //      so this means the first request isn't randomly more expensive.
        requestCnt = 1;
        requests[0].requester = msg.sender;
        killswitch = false;
        unrespondedCnt = 0;
        externalCallFlag = false;
    }

    function upgrade(address newAddr) public {
        if (msg.sender == requests[0].requester && unrespondedCnt == 0) {
            newVersion = -int(uint(uint160(newAddr)));
            killswitch = true;
            emit Upgrade(newAddr);
        }
    }

    function reset(uint price, uint minGas, uint cancellationGas) public {
        if (msg.sender == requests[0].requester && unrespondedCnt == 0) {
            GAS_PRICE = price;
            MIN_FEE = price * minGas;
            CANCELLATION_FEE = price * cancellationGas;
            emit Reset(GAS_PRICE, MIN_FEE, CANCELLATION_FEE);
        }
    }

    function suspend() public {
        if (msg.sender == requests[0].requester) {
            killswitch = true;
        }
    }

    function restart() public {
        if (msg.sender == requests[0].requester && newVersion == 0) {
            killswitch = false;
        }
    }

    function withdraw() public {
        if (msg.sender == requests[0].requester && unrespondedCnt == 0) {
            payable(requests[0].requester).transfer(address(this).balance);
        }
    }

    function request(uint8 requestType, address callbackAddr, bytes4
                     callbackFID, uint timestamp, bytes32[] memory requestData) public payable returns (int) {
        /* if (externalCallFlag) { */
        /*     revert(); */
        /* } */

        if (killswitch) {
            payable(msg.sender).transfer(msg.value);
            return newVersion;
        }

        if (msg.value < MIN_FEE) {
            // If the amount of ether sent by the requester is too little or
            // too much, refund the requester and discard the request.
            payable(msg.sender).transfer(msg.value);
            return FAIL_FLAG;
        } else {
            // Record the request.
            uint64 requestId = requestCnt;
            requestCnt++;
            unrespondedCnt++;

            bytes32 paramsHash = keccak256(abi.encodePacked(requestType, requestData));
            requests[requestId].requester = msg.sender;
            requests[requestId].fee = msg.value;
            requests[requestId].callbackAddr = callbackAddr;
            requests[requestId].callbackFID = callbackFID;
            requests[requestId].paramsHash = paramsHash;

            // Log the request for the Town Crier server to process.
            emit RequestInfo(requestId, requestType, msg.sender, msg.value, callbackAddr, paramsHash, timestamp, requestData);
            return int(uint(requestId));
        }
    }

    function deliver(uint64 requestId, bytes32 paramsHash, uint64 error, bytes32 respData) public {
        if (msg.sender != SGX_ADDRESS ||
                requestId <= 0 ||
                requests[requestId].requester == address(0) ||
                requests[requestId].fee == DELIVERED_FEE_FLAG) {
            // If the response is not delivered by the SGX account or the
            // request has already been responded to, discard the response.
            return;
        }

        uint fee = requests[requestId].fee;
        if (requests[requestId].paramsHash != paramsHash) {
            // If the hash of request parameters in the response is not
            // correct, discard the response for security concern.
            return;
        } else if (fee == CANCELLED_FEE_FLAG) {
            // If the request is cancelled by the requester, cancellation
            // fee goes to the SGX account and set the request as having
            // been responded to.
            SGX_FEE_ADDR.transfer(CANCELLATION_FEE);
            requests[requestId].fee = DELIVERED_FEE_FLAG;
            unrespondedCnt--;
            return;
        }

        // FUZZ: move this to the top
        uint callbackGas = (fee - MIN_FEE) / tx.gasprice; // gas left for the callback function
        emit DeliverInfo(requestId, fee, tx.gasprice, gasleft(), callbackGas, paramsHash, error, respData); // log the response information
        if (callbackGas > gasleft() - 5000) {
            callbackGas = gasleft() - 5000;
        }
        /* externalCallFlag = true; */
        requests[requestId].callbackAddr.call{gas:
            callbackGas}(abi.encodePacked(requests[requestId].callbackFID,
                                          requestId, error, respData)); 
                                          // call the callback function in the application contract
        /* externalCallFlag = false; */

        requests[requestId].fee = DELIVERED_FEE_FLAG;
        unrespondedCnt--;

        if (address(this).balance < fee) {
            emit AssertionFailed();
        }

        if (error < 2) {
            // Either no error occurs, or the requester sent an invalid query.
            // Send the fee to the SGX account for its delivering.
            SGX_FEE_ADDR.transfer(fee);
        } else {
            // Error in TC, refund the requester.
            /* externalCallFlag = true; */
            /* requests[requestId].requester.call.gas(2300).value(fee)(); */
            /* externalCallFlag = false; */
            payable(requests[requestId].requester).transfer(fee);
        }
    }

    function cancel(uint64 requestId) public returns (int) {
        /* if (externalCallFlag) { */
        /*     revert(); */
        /* } */

        if (killswitch) {
            return 0;
        }

        uint fee = requests[requestId].fee;
        if (requests[requestId].requester == msg.sender && fee >= CANCELLATION_FEE) {
            // If the request was sent by this user and has money left on it,
            // then cancel it.
            requests[requestId].fee = CANCELLED_FEE_FLAG;
            /* externalCallFlag = true; */
            payable(msg.sender).transfer(fee - CANCELLATION_FEE);
            /* externalCallFlag = false; */
            emit Cancel(requestId, msg.sender, requests[requestId].requester, requests[requestId].fee, 1);
            return SUCCESS_FLAG;
        } else {
            emit Cancel(requestId, msg.sender, requests[requestId].requester, fee, -1);
            return FAIL_FLAG;
        }
    }
}
