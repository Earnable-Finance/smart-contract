// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import './interfaces/IUniswapRouter02.sol';
import './interfaces/IUniswapV2Factory.sol';

contract PassiveIncomeStaking is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct CoinTypeInfo {
        address coinAddress;
        address[] routerPath;
    }

    address public efiAddress;
    address uniswapPair;
    IUniswapV2Router02 uniswapRouter;

    mapping(address => uint256) public claimed;
    CoinTypeInfo[] public coins;

    constructor(address _efiAddress) {
        efiAddress = _efiAddress;

        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(
            0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
        );
        // Create a uniswap pair for this new token
        uniswapPair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), _uniswapV2Router.WETH());

        // set the rest of the contract variables
        uniswapRouter = _uniswapV2Router;
    }

    function withdrawDividends(uint16 _cId) external {
        uint256 holdingAmount = IERC20(efiAddress).balanceOf(msg.sender);
        uint256 totalSupply = IERC20(efiAddress).totalSupply();
        uint256 brut = IERC20(efiAddress).balanceOf(address(this)).mul(holdingAmount).div(totalSupply);

        require(brut > claimed[msg.sender], 'not enough to claim');

        uint256 withdrawable = brut.sub(claimed[msg.sender]);
        
        CoinTypeInfo storage coin = coins[_cId];
        if (_cId == 0) { // if withdrawing token
            IERC20(efiAddress).safeTransfer(msg.sender, withdrawable);
        } else if (_cId == 1) { // if withdrawing ETH
            swapETH(withdrawable, coin.routerPath, payable(msg.sender));
        } else { // if withdrawing other coins
            swapCoin(withdrawable, coin.routerPath, msg.sender);
        }
        claimed[msg.sender] = claimed[msg.sender].add(withdrawable);
    }

    function withdrawableDividends() external view returns (uint256) {
        uint256 holdingAmount = IERC20(efiAddress).balanceOf(msg.sender);
        uint256 totalSupply = IERC20(efiAddress).totalSupply();
        uint256 brut = IERC20(efiAddress).balanceOf(address(this)).mul(holdingAmount).div(totalSupply);

        if (brut > claimed[msg.sender]) {
            return brut.sub(claimed[msg.sender]);
        }
        return 0;
    }

    function swapETH(uint256 _amount, address[] memory _path, address payable _to) private {
        uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(_amount, 0, _path, _to, block.timestamp.add(300));
    }

    function swapCoin(uint256 _amount, address[] memory _path, address _to) private {
        uniswapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(_amount, 0, _path, _to, block.timestamp.add(300));
    }

    function addCoinInfo(address[] memory _path, address _coinAddr) external onlyOwner {
        coins.push(CoinTypeInfo({
            coinAddress: _coinAddr,
            routerPath: _path
        }));
    }

    function updateCoinInfo(uint8 _cId, address[] memory _path, address _coinAddr) external onlyOwner {
        CoinTypeInfo storage coin = coins[_cId];
        coin.routerPath = _path;
        coin.coinAddress = _coinAddr;
    }
}

contract EarnableFi is ERC20('EarnableFi', 'EFI'), Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 constant public MAX_SUPPLY = 30000000000 * 1e18;  // 30B max supply

    uint16 private MAX_BP_RATE = 10000;
    uint16 private devTaxRate = 300;
    uint16 private marketingTaxRate = 500;
    uint16 private burnTaxRate = 400;
    uint16 private passiveIncomeRewardTaxRate = 700;
    uint16 private maxTransferAmountRate = 1000;

    uint256 public minAmountToSwap = 1000000000 * 1e18;    // 10% of total supply

    IUniswapV2Router02 public uniswapRouter;
    // The trading pair
    address public uniswapPair;

    address public feeRecipient = 0xf9054E835566250EB85BBB5A241d071035D34Cf5;
    address public passiveIncomeStakingAddress;

    // In swap and withdraw
    bool private _inSwapAndWithdraw;
    // The operator can only update the transfer tax rate
    address private _operator;
    // Automatic swap and liquify enabled
    bool public swapAndWithdrawEnabled = false;

    mapping(address => bool) private _isExcludedFromFee;
    mapping(address => bool) private _isExcludedFromMaxTx;

    bool private _tradingOpen = false;

    struct CoinTypeInfo {
        address coinAddress;
        address[] routerPath;
    }

    mapping(address => uint256) public claimed;
    CoinTypeInfo[] public coins;

    modifier onlyOperator() {
        require(_operator == msg.sender, "!operator");
        _;
    }

    modifier lockTheSwap {
        _inSwapAndWithdraw = true;
        _;
        _inSwapAndWithdraw = false;
    }

    modifier transferTaxFree {
        uint16 _devTaxRate = devTaxRate;
        uint16 _marketingTaxRate = marketingTaxRate;
        uint16 _burnTaxRate = burnTaxRate;
        devTaxRate = 0;
        marketingTaxRate = 0;
        burnTaxRate = 0;
        _;
        devTaxRate = _devTaxRate;
        marketingTaxRate = _marketingTaxRate;
        burnTaxRate = _burnTaxRate;
    }

    constructor() public {
        _operator = msg.sender;
        _mint(msg.sender, MAX_SUPPLY);

        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(
            0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
        );
        // Create a uniswap pair for this new token
        uniswapPair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), _uniswapV2Router.WETH());

        // set the rest of the contract variables
        uniswapRouter = _uniswapV2Router;

        _isExcludedFromFee[address(this)] = true;
        _isExcludedFromFee[msg.sender] = true;
        _isExcludedFromMaxTx[address(this)] = true;
        _isExcludedFromMaxTx[msg.sender] = true;
    }

    /**
     * @dev Returns the address of the current operator.
     */
    function operator() public view returns (address) {
        return _operator;
    }

    /// @notice Burns `_amount` token fromo `_from`. Must only be called by the owner.
    function burn(address _from, uint256 _amount) public onlyOwner {
        _burn(_from, _amount);
    }

    function _transfer(address _sender, address _recepient, uint256 _amount) internal override {
        require(_tradingOpen || _sender == owner() || _recepient == owner() || _sender == address(uniswapRouter), "!tradable");

        // swap and withdraw
        if (
            swapAndWithdrawEnabled == true
            && _inSwapAndWithdraw == false
            && address(uniswapRouter) != address(0)
            && uniswapPair != address(0)
            && _sender != uniswapPair
            && _sender != address(uniswapRouter)
            && _sender != owner()
        ) {
            swapAndWithdraw();
        }

        if (!_isExcludedFromMaxTx[_sender]) {
            require(_amount <= maxTransferAmount(), 'exceed max tx amount');
        }

        if (_isExcludedFromFee[_sender]) {
            super._transfer(_sender, _recepient, _amount);
        } else {
            uint256 devFee = _amount.mul(devTaxRate).div(MAX_BP_RATE);
            uint256 marketingFee = _amount.mul(marketingTaxRate).div(MAX_BP_RATE);
            uint256 passiveIncomeRewardFee = _amount.mul(passiveIncomeRewardTaxRate).div(MAX_BP_RATE);
            _amount = _amount.sub(devFee).sub(marketingFee).sub(passiveIncomeRewardFee);

            super._transfer(_sender, _recepient, _amount);
            super._transfer(_sender, address(this), devFee);
            super._transfer(_sender, address(this), marketingFee);
            super._transfer(_sender, passiveIncomeStakingAddress, marketingFee);
        }
    }

    /**
     * @dev Transfers operator of the contract to a new account (`newOperator`).
     * Can only be called by the current operator.
     */
    function transferOperator(address newOperator) public onlyOperator {
        require(newOperator != address(0));
        _operator = newOperator;
    }

    /**
     * @dev Update the swap router.
     * Can only be called by the current operator.
     */
    function updatePancakeRouter(address _router) public onlyOperator {
        uniswapRouter = IUniswapV2Router02(_router);
        uniswapPair = IUniswapV2Factory(uniswapRouter.factory()).getPair(address(this), uniswapRouter.WETH());
        require(uniswapPair != address(0));
    }

    /**
     * @dev Update the swapAndWithdrawEnabled.
     * Can only be called by the current operator.
     */
    function updateSwapAndLiquifyEnabled(bool _enabled) public onlyOperator {
        swapAndWithdrawEnabled = _enabled;
    }

    function manualSwap() external onlyOperator {
        swapAndWithdraw();
    }

    function manualWithdraw() external onlyOperator {
        uint256 bal = address(this).balance;
        payable(feeRecipient).transfer(bal);
    }

    function setPassiveIncomeStakingAddress(address _stakingAddress) external onlyOperator {
        passiveIncomeStakingAddress = _stakingAddress;
    }

    /// @dev Swap and liquify
    function swapAndWithdraw() private lockTheSwap transferTaxFree {
        uint256 contractTokenBalance = balanceOf(address(this));
        // swap tokens for ETH
        swapTokensForEth(contractTokenBalance);

        uint256 bal = address(this).balance;
        payable(feeRecipient).transfer(bal);
    }

    /// @dev Swap tokens for eth
    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the pantherSwap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapRouter.WETH();

        _approve(address(this), address(uniswapRouter), tokenAmount);

        // make the swap
        uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp + 1 days
        );
    }

    /**
     * @dev Returns the max transfer amount.
     */
    function maxTransferAmount() public view returns (uint256) {
        return totalSupply().mul(maxTransferAmountRate).div(MAX_BP_RATE);
    }

    function updateFees(uint16 _burnTaxRate, uint16 _devTaxRate, uint16 _marketingTaxRate) external onlyOwner {
        require(_burnTaxRate + _devTaxRate + _marketingTaxRate <= MAX_BP_RATE, '!values');
        burnTaxRate = _burnTaxRate;
        devTaxRate = _devTaxRate;
        marketingTaxRate = _marketingTaxRate;
    }

    function setMaxTransferAmountRate(uint16 _maxTransferAmountRate) external onlyOwner {
        require(_maxTransferAmountRate <= MAX_BP_RATE);
        maxTransferAmountRate = _maxTransferAmountRate;
    }

    function openTrading() external onlyOwner {
        _tradingOpen = true;
        maxTransferAmountRate = MAX_BP_RATE;
    }

    function isExcludedFromFee(address _addr) external view returns (bool) {
        return _isExcludedFromFee[_addr];
    }

    function excludeFromFee(address _addr, bool _is) external onlyOperator {
        _isExcludedFromFee[_addr] = _is;
    }

    function isExcludedFromMaxTx(address _addr) external view returns (bool) {
        return _isExcludedFromMaxTx[_addr];
    }

    function excludeFromMaxTx(address _addr, bool _is) external onlyOperator {
        _isExcludedFromMaxTx[_addr] = _is;
    }

    function withdrawDividends(uint16 _cId) external {
        uint256 holdingAmount = balanceOf(msg.sender);
        uint256 totalSupply = totalSupply();
        uint256 brut = balanceOf(address(this)).mul(holdingAmount).div(totalSupply);

        require(brut > claimed[msg.sender], 'not enough to claim');

        uint256 withdrawable = brut.sub(claimed[msg.sender]);
        
        CoinTypeInfo storage coin = coins[_cId];
        if (_cId == 0) { // if withdrawing token
            transfer(msg.sender, withdrawable);
        } else if (_cId == 1) { // if withdrawing ETH
            uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(withdrawable, 0, coin.routerPath, msg.sender, block.timestamp.add(300));
        } else { // if withdrawing other coins
            uniswapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(withdrawable, 0, coin.routerPath, msg.sender, block.timestamp.add(300));
        }
        claimed[msg.sender] = claimed[msg.sender].add(withdrawable);
    }

    function withdrawableDividends() external view returns (uint256) {
        uint256 holdingAmount = balanceOf(msg.sender);
        uint256 totalSupply = totalSupply();
        uint256 brut = balanceOf(address(this)).mul(holdingAmount).div(totalSupply);

        if (brut > claimed[msg.sender]) {
            return brut.sub(claimed[msg.sender]);
        }
        return 0;
    }

    function addCoinInfo(address[] memory _path, address _coinAddr) external onlyOwner {
        coins.push(CoinTypeInfo({
            coinAddress: _coinAddr,
            routerPath: _path
        }));
    }

    function updateCoinInfo(uint8 _cId, address[] memory _path, address _coinAddr) external onlyOwner {
        CoinTypeInfo storage coin = coins[_cId];
        coin.routerPath = _path;
        coin.coinAddress = _coinAddr;
    }

    mapping (address => address) internal _delegates;

    /// @notice A checkpoint for marking number of votes from a given block
    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    /// @notice A record of votes checkpoints for each account, by index
    mapping (address => mapping (uint32 => Checkpoint)) public checkpoints;

    /// @notice The number of checkpoints for each account
    mapping (address => uint32) public numCheckpoints;

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @notice The EIP-712 typehash for the delegation struct used by the contract
    bytes32 public constant DELEGATION_TYPEHASH = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    /// @notice A record of states for signing / validating signatures
    mapping (address => uint) public nonces;

      /// @notice An event thats emitted when an account changes its delegate
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    /// @notice An event thats emitted when a delegate account's vote balance changes
    event DelegateVotesChanged(address indexed delegate, uint previousBalance, uint newBalance);

    /**
     * @notice Delegate votes from `msg.sender` to `delegatee`
     * @param delegator The address to get delegatee for
     */
    function delegates(address delegator)
        external
        view
        returns (address)
    {
        return _delegates[delegator];
    }

   /**
    * @notice Delegate votes from `msg.sender` to `delegatee`
    * @param delegatee The address to delegate votes to
    */
    function delegate(address delegatee) external {
        return _delegate(msg.sender, delegatee);
    }

    /**
     * @notice Delegates votes from signatory to `delegatee`
     * @param delegatee The address to delegate votes to
     * @param nonce The contract state required to match the signature
     * @param expiry The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function delegateBySig(
        address delegatee,
        uint nonce,
        uint expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name())),
                getChainId(),
                address(this)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                DELEGATION_TYPEHASH,
                delegatee,
                nonce,
                expiry
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                structHash
            )
        );

        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "MARS::delegateBySig: invalid signature");
        require(nonce == nonces[signatory]++, "MARS::delegateBySig: invalid nonce");
        require(block.timestamp <= expiry, "MARS::delegateBySig: signature expired");
        return _delegate(signatory, delegatee);
    }

    /**
     * @notice Gets the current votes balance for `account`
     * @param account The address to get votes balance
     * @return The number of current votes for `account`
     */
    function getCurrentVotes(address account)
        external
        view
        returns (uint256)
    {
        uint32 nCheckpoints = numCheckpoints[account];
        return nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    /**
     * @notice Determine the prior number of votes for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param account The address of the account to check
     * @param blockNumber The block number to get the vote balance at
     * @return The number of votes the account had as of the given block
     */
    function getPriorVotes(address account, uint blockNumber)
        external
        view
        returns (uint256)
    {
        require(blockNumber < block.number, "MARS::getPriorVotes: not yet determined");

        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }

        // Next check implicit zero balance
        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }

    function _delegate(address delegator, address delegatee)
        internal
    {
        address currentDelegate = _delegates[delegator];
        uint256 delegatorBalance = balanceOf(delegator); // balance of underlying MARSs (not scaled);
        _delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);

        _moveDelegates(currentDelegate, delegatee, delegatorBalance);
    }

    function _moveDelegates(address srcRep, address dstRep, uint256 amount) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                // decrease old representative
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint256 srcRepOld = srcRepNum > 0 ? checkpoints[srcRep][srcRepNum - 1].votes : 0;
                uint256 srcRepNew = srcRepOld.sub(amount);
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                // increase new representative
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint256 dstRepOld = dstRepNum > 0 ? checkpoints[dstRep][dstRepNum - 1].votes : 0;
                uint256 dstRepNew = dstRepOld.add(amount);
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(
        address delegatee,
        uint32 nCheckpoints,
        uint256 oldVotes,
        uint256 newVotes
    )
        internal
    {
        uint32 blockNumber = safe32(block.number, "MARS::_writeCheckpoint: block number exceeds 32 bits");

        if (nCheckpoints > 0 && checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber) {
            checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            checkpoints[delegatee][nCheckpoints] = Checkpoint(blockNumber, newVotes);
            numCheckpoints[delegatee] = nCheckpoints + 1;
        }

        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    function safe32(uint n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    function getChainId() internal view returns (uint) {
        uint256 chainId;
        assembly { chainId := chainid() }
        return chainId;
    }
}