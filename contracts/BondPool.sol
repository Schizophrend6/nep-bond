// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.4.22 <0.9.0;
import "openzeppelin-solidity/contracts/utils/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/security/Pausable.sol";
import "openzeppelin-solidity/contracts/security/ReentrancyGuard.sol";
import "./Recoverable.sol";
import "./IPancakeRouterLike.sol";
import "./IBondPool.sol";
import "./Libraries/NTransferUtilV1.sol";

contract BondPool is IBondPool, ReentrancyGuard, Recoverable, Pausable {
  using SafeMath for uint256;
  using NTransferUtilV1 for IERC20;

  mapping(address => mapping(address => Bond)) public _bonds; // account -> bond token --> liquidity
  mapping(address => Pair) public _pool;

  bool public _migrationComplete = false;
  uint256 public override _totalRewardAllocation;
  mapping(address => uint256) public override _bondRewardAllocation;
  uint256 public _totalNepPaired;
  mapping(address => mapping(address => uint256)) public _myNepRewards; // account --> bond token --> reward total
  address public _treasury;

  event TreasuryUpdated(address indexed previous, address indexed current);

  IERC20 public _nepToken;
  IPancakeRouterLike public _pancakeRouter;

  constructor(
    address nepToken,
    address pancakeRouter,
    address treasury
  ) {
    _nepToken = IERC20(nepToken);
    _pancakeRouter = IPancakeRouterLike(pancakeRouter);
    _treasury = treasury;

    emit TreasuryUpdated(address(0), treasury);
  }

  /**
   * @dev Gets the summary of the Cake Farm
   * @param token The token address to get the information
   * @param account Account to obtain summary of
   * @param values[0] poolTotalNepPaired Returns the total amount of NEP paired with the given token
   * @param values[1] totalLocked Returns the total amount of the token locked/staked in this pool
   * @param values[2] releaseDate Returns the release date of the account (if any bond)
   * @param values[3] nepAmount Returns the account's active NEP reward that was bonded with the suppplied token
   * @param values[4] bondTokenAmount Returns the accounts's token amount that was bonded with NEP
   * @param values[5] liquidity Returns the account's liquidity that was created and locked in the PancakeSwap exchange
   * @param values[6] myNepRewards Returns the account's sum total NEP reward in this pool
   */
  function getInfo(address token, address account) external view override returns (uint256[] memory values) {
    values = new uint256[](7);

    values[0] = _pool[token].totalNepPaired;
    values[1] = _pool[token].totalLocked;

    values[2] = _bonds[account][token].releaseDate;
    values[3] = _bonds[account][token].nepAmount;
    values[4] = _bonds[account][token].bondTokenAmount;
    values[5] = _bonds[account][token].liquidity;
    values[6] = _myNepRewards[account][token]; // myNepRewards
  }

  /**
   * @dev Gets the amount of NEP required to create a bond with the supplied token and amount
   * @param tokenAddress The token to create bond with
   * @param amountIn The amount of token to supply
   */
  function getNepRequired(address tokenAddress, uint256 amountIn) external view override returns (uint256[] memory) {
    (uint112 reserve0, uint112 reserve1, ) = _pool[tokenAddress].pancakePair.getReserves();

    address token0 = _pool[tokenAddress].pancakePair.token0();
    uint256 tokenBalance = token0 == tokenAddress ? reserve0 : reserve1;
    uint256 nepBalance = token0 == tokenAddress ? reserve1 : reserve0;

    uint256 bondAmount = amountIn.mul(1000000 - _pool[tokenAddress].entryFee).div(1000000);

    // slither-disable-next-line divide-before-multiply
    uint256 nepRequired = bondAmount.mul(nepBalance).div(tokenBalance);

    uint256[] memory amounts = new uint256[](2);
    amounts[0] = nepRequired;
    amounts[1] = bondAmount;

    return amounts;
  }

  /**
   * @dev Gets the bond creation information
   * @param you Enter an address to get the creation information
   * @param bondToken Enter the liquidity token address to bond NEP with
   * @param bondTokenAmount Enter the amount of liquidity token to create a bond
   * @param nepAmount Enter the estimated amount of NEP which is bonded with the liquidity token
   */
  function getCreateBondInfo(
    address you,
    address bondToken,
    uint256 bondTokenAmount,
    uint256 nepAmount
  ) external view override returns (uint256 lockingPeriod, uint256 entryFee) {
    require(bondToken != address(0), "Invalid token");

    Pair memory pair = _pool[bondToken];

    require(pair.maxStake > 0, "Please try again later"); // Invalid token to pair
    require(pair.maxStake >= pair.totalLocked.add(bondTokenAmount), "Liquidity exceeds the cap. Reduce your bond amount"); // solhint-disable-line
    require(bondTokenAmount >= pair.minBond, "Insufficient liquidity");
    entryFee = bondTokenAmount.mul(pair.entryFee).div(1000000);

    uint256 approved = IERC20(bondToken).allowance(you, address(this));
    require(approved >= bondTokenAmount, "Approval not enough");

    require(nepAmount > 0, "Enter a valid amount");
    require(_nepToken.balanceOf(address(this)) >= nepAmount, "NEP balance insufficient. Reduce your bond amount"); // solhint-disable-line

    lockingPeriod = pair.lockingPeriod;
  }

  /**
   * @dev Adds liquidity to the bond pool
   * @param bondToken The liquidity token to create bond with
   * @param finalAmount The amount of liquidity token (minus fee) to lock
   * @param nepDesired The estimated amount of NEP to lock along with the liquidity token
   * @param minNep The minimum amount of NEP that should be added to the liquidity pool
   * @param lockingPeriod The locking period after which the bond can be released to the sender
   * @param txDeadline If the transaction is not finalized within this deadline, it will be cancelled.
   */
  function _addLiquidity(
    address bondToken,
    uint256 finalAmount,
    uint256 nepDesired,
    uint256 minNep,
    uint256 lockingPeriod,
    uint256 txDeadline
  ) private {
    /**
     * Sends the staked amount of bond token
     * and add equivalent amount of NEP (e) to the liquidity pool
     * to form a liquidity pair on PancakeSwap.
     *
     * The sender's liquidity (k) will be locked for next (n) number
     * of days. After the locking period, the sender will get
     * the original tokens back, minus fees (f), and NEP tokens
     * rewarded (e) in the liquidity pool.
     * Additionally, the sender will also receive
     * PancakeSwap liquidity provider fees and/or impermanent loss (i).
     *
     * Total Withdrawal amount (w) = k - f + r
     * Total Rewards (r) = e + i
     */
    (uint256 nepStaked, uint256 tokenStaked, uint256 liquidity) = _pancakeRouter.addLiquidity(address(_nepToken), bondToken, nepDesired, finalAmount, minNep, finalAmount, address(this), txDeadline);

    _bonds[super._msgSender()][bondToken].exitFee = _pool[bondToken].exitFee;
    _bonds[super._msgSender()][bondToken].releaseDate = block.timestamp.add(lockingPeriod); // solhint-disable-line
    _bonds[super._msgSender()][bondToken].nepAmount = _bonds[super._msgSender()][bondToken].nepAmount.add(nepStaked);
    _bonds[super._msgSender()][bondToken].bondTokenAmount = _bonds[super._msgSender()][bondToken].bondTokenAmount.add(tokenStaked);
    _bonds[super._msgSender()][bondToken].liquidity = _bonds[super._msgSender()][bondToken].liquidity.add(liquidity);

    _totalNepPaired = _totalNepPaired.add(nepStaked);
    _myNepRewards[super._msgSender()][bondToken] = _myNepRewards[super._msgSender()][bondToken].add(nepStaked);

    _pool[bondToken].totalLocked = _pool[bondToken].totalLocked.add(finalAmount);
    _pool[bondToken].totalNepPaired = _pool[bondToken].totalNepPaired.add(nepStaked);
    _pool[bondToken].totalLiquidity = _pool[bondToken].totalLiquidity.add(liquidity);

    emit BondCreated(bondToken, nepStaked, tokenStaked, liquidity);
  }

  function migrateLiquidity(
    address beneficiary,
    address bondToken,
    uint256 nepStaked,
    uint256 tokenStaked,
    uint256 liquidity,
    uint256 releaseDate,
    bool migrationComplete
  ) external onlyOwner {
    require(_migrationComplete == false, "Migration already completed");

    // First transfer the liquidity
    IPancakePairLike pair = _pool[bondToken].pancakePair;

    // slither-disable-next-line reentrancy-no-eth
    require(pair.transferFrom(msg.sender, address(this), liquidity), "Could not transfer liquidity");

    // Update the state
    _bonds[beneficiary][bondToken].exitFee = _pool[bondToken].exitFee;
    _bonds[beneficiary][bondToken].releaseDate = releaseDate;
    _bonds[beneficiary][bondToken].nepAmount = _bonds[beneficiary][bondToken].nepAmount.add(nepStaked);
    _bonds[beneficiary][bondToken].bondTokenAmount = _bonds[beneficiary][bondToken].bondTokenAmount.add(tokenStaked);
    _bonds[beneficiary][bondToken].liquidity = _bonds[beneficiary][bondToken].liquidity.add(liquidity);

    _totalNepPaired = _totalNepPaired.add(nepStaked);
    _myNepRewards[beneficiary][bondToken] = _myNepRewards[beneficiary][bondToken].add(nepStaked);

    _pool[bondToken].totalLocked = _pool[bondToken].totalLocked.add(tokenStaked);
    _pool[bondToken].totalNepPaired = _pool[bondToken].totalNepPaired.add(nepStaked);
    _pool[bondToken].totalLiquidity = _pool[bondToken].totalLiquidity.add(liquidity);

    _migrationComplete = migrationComplete;
    emit BondCreated(bondToken, nepStaked, tokenStaked, liquidity);
  }

  /**
   * @dev Approves the bond liquidity token and NEP
   * from this contract to be spent by Pancake Router
   *
   * @param bondToken The address of the liquidity token
   * @param bondTokenAmount The total amount of liquidity token to approve
   * @param nepAmount The total amount of NEP to approve
   * @param entryFee The entry fee amount in liquidity token value
   */
  function _approveAndTransfer(
    address bondToken,
    uint256 bondTokenAmount,
    uint256 nepAmount,
    uint256 entryFee
  ) private {
    IERC20(bondToken).safeTransferFrom(super._msgSender(), address(this), bondTokenAmount);

    require(_nepToken.approve(address(_pancakeRouter), nepAmount), "NEP approval failed");
    require(IERC20(bondToken).approve(address(_pancakeRouter), bondTokenAmount.sub(entryFee)), "Bond token approval failed");
  }

  /**
   * @dev Finalizes and resets the bond release of the sender.
   * @param bondToken Enter the bond liquidity token address.
   */
  function _finalize(address bondToken) private {
    uint256 holdersLiquidity = _bonds[super._msgSender()][bondToken].liquidity;
    uint256 totalLiquidity = _pool[bondToken].totalLiquidity;

    _pool[bondToken].totalLiquidity = totalLiquidity.sub(holdersLiquidity);
    _bonds[super._msgSender()][bondToken].releaseDate = 0;
    _bonds[super._msgSender()][bondToken].nepAmount = 0;
    _bonds[super._msgSender()][bondToken].bondTokenAmount = 0;
    _bonds[super._msgSender()][bondToken].liquidity = 0;
  }

  /**
   * @dev Removes and transfers all bond liquidity of the sender.
   * Liquidity means the original bond token amount, minus fees, plus NEP token rewards, plus PancakeSwap LP fees.
   *
   * @param bondToken Provide the address of the bond token to release to the sender.
   */
  function _releaseBondToSender(address bondToken) private {
    uint256 liquidity = _bonds[super._msgSender()][bondToken].liquidity;

    _finalize(bondToken);

    require(_pool[bondToken].pancakePair.transfer(super._msgSender(), liquidity), "Bond release failed");
    emit BondReleased(bondToken, liquidity);
  }

  /**
   * @dev Removes and transfers all bond liquidity of the sender, deducting fees.
   * Liquidity means the original bond token amount, minus fees, plus NEP token rewards, plus PancakeSwap LP fees.
   *
   * @param bondToken Provide the address of the bond token to release to the sender.
   */
  function _releaseBondToSenderDeductingFees(address bondToken, uint256 exitFee) private {
    uint256 liquidity = _bonds[super._msgSender()][bondToken].liquidity;
    uint256 fees = liquidity.mul(1000000 - exitFee).div(1000000);
    uint256 released = liquidity.sub(fees);

    _finalize(bondToken);

    if (released > 0) {
      require(_pool[bondToken].pancakePair.transfer(super._msgSender(), released), "Release bond failed");
    }

    // Transfer the exit fee to the treasury
    if (fees > 0) {
      require(_pool[bondToken].pancakePair.transfer(_treasury, fees), "Transfer to treasury failed");
    }

    emit BondReleased(bondToken, _bonds[super._msgSender()][bondToken].liquidity);
  }

  /**
   * @dev Entrypoint to release the bond held by the sender.
   * @param bondToken Enter the bond liquidity token address.
   */
  function releaseBond(address bondToken) external override whenNotPaused nonReentrant {
    require(block.timestamp >= _bonds[super._msgSender()][bondToken].releaseDate, "You're early."); // solhint-disable-line
    require(_bonds[super._msgSender()][bondToken].liquidity > 0, "Nothing to withdraw");

    uint256 exitFee = _bonds[super._msgSender()][bondToken].exitFee;

    exitFee == 0 ? _releaseBondToSender(bondToken) : _releaseBondToSenderDeductingFees(bondToken, exitFee);
  }

  /**
   * @dev Entrypoint to create bond which rewards equivalent of NEP tokens
   * to the sender after the locking period.
   *
   * @param bondToken The address of the liquidity token
   * @param bondTokenAmount The total amount of liquidity token to approve
   * @param nepAmount The total amount of NEP to approve
   * @param minNep Minimum amount of NEP that should be bonded along with the liquidity token. If your supplied value is too high, the transaction can fail.
   * @param txDeadline If the transaction is not finalized within this deadline, it will be cancelled.
   */
  function createBond(
    address bondToken,
    uint256 bondTokenAmount,
    uint256 nepAmount,
    uint256 minNep,
    uint256 txDeadline
  ) external override whenNotPaused nonReentrant {
    require(bondTokenAmount > 0, "Invalid bond amount");
    require(nepAmount > 0, "Invalid desired NEP amount");

    (uint256 lockingPeriod, uint256 entryFee) = this.getCreateBondInfo(super._msgSender(), bondToken, bondTokenAmount, nepAmount);

    _approveAndTransfer(bondToken, bondTokenAmount, nepAmount, entryFee);
    _addLiquidity(bondToken, bondTokenAmount.sub(entryFee), nepAmount, minNep, lockingPeriod, txDeadline);

    if (entryFee > 0) {
      IERC20(bondToken).safeTransfer(_treasury, entryFee);
    }
  }

  /**
   * @dev Changes the treasury address
   * @param treasury Provide new treasury address to change
   */
  function changeTreasury(address treasury) external onlyOwner {
    require(treasury != address(0), "Invalid address");
    require(treasury != _treasury, "Provide a new address");

    emit TreasuryUpdated(_treasury, treasury);
    _treasury = treasury;
  }

  /**
   * @dev Changes the NEP Token address
   * @param nepToken Provide new NEP token address to change
   */
  function changeNEPToken(address nepToken) external onlyOwner {
    _nepToken = IERC20(nepToken);
  }

  /**
   * @dev Changes the PancakeRouter address
   * @param pancakeRouter Provide new PancakeRouter address to change
   */
  function changePancakeRouter(address pancakeRouter) external onlyOwner {
    _pancakeRouter = IPancakeRouterLike(pancakeRouter);
  }

  /**
   * @dev Adds or updates bond pairs for this pool
   *
   * @param token Provide the liquidity token address to bond with NEP
   * @param pancakePair Provide the pair address of the liquidity token/NEP
   * @param name Provide a name of this bond
   * @param maxStake The maximum cap of total tokens that can be staked to create bond
   * @param minBond Minimum bond amount
   * @param entryFee Entry fee on one side-liquidity token
   * @param exitFee Exit fee on both sides
   * @param lockingPeriod The locking period for the liquidity token and reawds
   * @param amount The amount of NEP tokens to transfer
   *
   */
  function addOrUpdatePair(
    address token,
    IPancakePairLike pancakePair,
    string memory name,
    uint256 maxStake,
    uint256 minBond,
    uint256 entryFee,
    uint256 exitFee,
    uint256 lockingPeriod,
    uint256 amount
  ) external override onlyOwner {
    require(token != address(0), "Invalid token");
    require(maxStake > 0, "Invalid maximum stake amount");

    if (amount > 0) {
      _totalRewardAllocation = _totalRewardAllocation.add(amount);
      _bondRewardAllocation[token] = _bondRewardAllocation[token].add(amount);

      _nepToken.safeTransferFrom(super._msgSender(), address(this), amount);
    }

    _pool[token].name = name;

    if (address(pancakePair) != address(0)) {
      _pool[token].pancakePair = pancakePair;
    }

    _pool[token].maxStake = maxStake;
    _pool[token].minBond = minBond;
    _pool[token].entryFee = entryFee;
    _pool[token].exitFee = exitFee;
    _pool[token].lockingPeriod = lockingPeriod;

    emit PairUpdated(token, name, maxStake, minBond, entryFee, exitFee, lockingPeriod, amount);
  }

  function pause() external onlyOwner whenNotPaused {
    super._pause();
  }

  function unpause() external onlyOwner whenPaused {
    super._unpause();
  }
}
