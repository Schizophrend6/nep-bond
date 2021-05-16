// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.4.22 <0.9.0;
import "openzeppelin-solidity/contracts/utils/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/security/Pausable.sol";
import "openzeppelin-solidity/contracts/security/ReentrancyGuard.sol";
import "./Recoverable.sol";
import "./IPancakeRouterLike.sol";
import "./IBondPool.sol";

contract BondPool is IBondPool, ReentrancyGuard, Recoverable, Pausable {
  using SafeMath for uint256;
  using SafeMath for int256;

  mapping(address => mapping(address => Bond)) public _bonds; // account -> bond token --> liquidity
  mapping(address => Pair) public _pool;
  uint256 public _totalNepPaired;
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
   * @dev Gets the bond market information information
   * @param token The token address to get the information
   * @param account Enter your account address to get the information
   * @param poolTotalNepPaired Returns the total amount of NEP paired with the given token
   * @param totalNepPaired Returns the total amount of NEP pair in all pools
   * @param totalLocked Returns the total amount of the token locked/staked in this pool
   * @param maxStake Returns the maximum amount of tokens that can be locked in this pool
   * @param totalLiquidity Returns the sum of liquidity (PancakeSwap LP token) locked in this pool
   * @param releaseDate Returns the release date of the sender (if any bond)
   * @param nepAmount Returns the sender's amount of NEP reward that was bonded with the suppplied token
   * @param bondTokenAmount Returns the sender's token amount that was bonded with NEP
   * @param liquidity Returns the sender's liquidity that was created and locked in the PancakeSwap exchange
   */
  function getInfo(address token, address account)
    external
    view
    override
    returns (
      uint256 poolTotalNepPaired,
      uint256 totalNepPaired,
      uint256 totalLocked,
      uint256 maxStake,
      uint256 totalLiquidity,
      uint256 releaseDate,
      uint256 nepAmount,
      uint256 bondTokenAmount,
      uint256 liquidity
    )
  {
    totalNepPaired = _totalNepPaired;
    poolTotalNepPaired = _pool[token].totalNepPaired;
    totalLocked = _pool[token].totalLocked;
    maxStake = _pool[token].maxStake;
    totalLiquidity = _pool[token].totalLiquidity;

    releaseDate = _bonds[account][token].releaseDate;
    nepAmount = _bonds[account][token].nepAmount;
    bondTokenAmount = _bonds[account][token].bondTokenAmount;
    liquidity = _bonds[account][token].liquidity;
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
   * @dev Adds or updates bond pairs for this pool
   *
   * @param token Provide the liquidity token address to bond with NEP
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
    string memory name,
    uint256 maxStake,
    uint256 minBond,
    uint256 entryFee,
    uint256 exitFee,
    uint256 lockingPeriod,
    uint256 amount
  ) public override onlyOwner {
    require(token != address(0), "Invalid token");
    require(maxStake > 0, "Invalid maximum stake amount");

    if (amount > 0) {
      _nepToken.transferFrom(super._msgSender(), address(this), amount);
    }

    address[] memory path = new address[](2);
    path[0] = address(_nepToken);
    path[1] = token;

    Pair memory pair;

    pair.name = name;
    pair.maxStake = maxStake;
    pair.minBond = minBond;
    pair.entryFee = entryFee;
    pair.exitFee = exitFee;
    pair.lockingPeriod = lockingPeriod;
    pair.path = path;

    _pool[token] = pair;

    emit PairUpdated(token, name, maxStake, minBond, entryFee, exitFee, lockingPeriod, amount);
  }

  /**
   * @dev Gets the amount of NEP required to create a bond with the supplied token and amount
   * @param tokenAddress The token to create bond with
   * @param amountIn The amount of token to supply
   */
  function getNepRequired(address tokenAddress, uint256 amountIn) external view override returns (uint256[] memory) {
    Pair memory pair = _pool[tokenAddress];
    return _pancakeRouter.getAmountsOut(amountIn, pair.path);
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
  ) public view override returns (uint256 lockingPeriod, uint256 entryFee) {
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
   * @param nepAmount The estimated amount of NEP to lock along with the liquidity token
   * @param minNep The minimum amount of NEP that should be added to the liquidity pool
   * @param lockingPeriod The locking period after which the bond can be released to the sender
   * @param txDeadline If the transaction is not finalized within this deadline, it will be cancelled.
   */
  function _addLiquidity(
    address bondToken,
    uint256 finalAmount,
    uint256 nepAmount,
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
    (uint256 nepStaked, uint256 tokenStaked, uint256 liquidity) = _pancakeRouter.addLiquidity(address(_nepToken), bondToken, nepAmount, finalAmount, minNep, finalAmount, address(this), txDeadline);

    _bonds[super._msgSender()][bondToken].exitFee = _pool[bondToken].exitFee;
    _bonds[super._msgSender()][bondToken].releaseDate = block.timestamp.add(lockingPeriod); // solhint-disable-line
    _bonds[super._msgSender()][bondToken].nepAmount = _bonds[super._msgSender()][bondToken].nepAmount.add(nepStaked);
    _bonds[super._msgSender()][bondToken].bondTokenAmount = _bonds[super._msgSender()][bondToken].bondTokenAmount.add(tokenStaked);
    _bonds[super._msgSender()][bondToken].liquidity = _bonds[super._msgSender()][bondToken].liquidity.add(liquidity);

    _totalNepPaired = _totalNepPaired.add(nepAmount);

    _pool[bondToken].totalLocked = _pool[bondToken].totalLocked.add(finalAmount);
    _pool[bondToken].totalNepPaired = _pool[bondToken].totalNepPaired.add(_totalNepPaired);
    _pool[bondToken].totalLiquidity = _pool[bondToken].totalLiquidity.add(liquidity);

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
    IERC20(bondToken).transferFrom(super._msgSender(), address(this), bondTokenAmount);

    _nepToken.approve(address(_pancakeRouter), nepAmount);
    IERC20(bondToken).approve(address(_pancakeRouter), bondTokenAmount.sub(entryFee));
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
  ) external override nonReentrant {
    (uint256 lockingPeriod, uint256 entryFee) = this.getCreateBondInfo(super._msgSender(), bondToken, bondTokenAmount, nepAmount);

    _approveAndTransfer(bondToken, bondTokenAmount, nepAmount, entryFee);
    _addLiquidity(bondToken, bondTokenAmount.sub(entryFee), nepAmount, minNep, lockingPeriod, txDeadline);
    IERC20(bondToken).transfer(_treasury, entryFee);
  }

  /**
   * @dev Removes and transfers all bond liquidity of the sender.
   * Liquidity means the original bond token amount, minus fees, plus NEP token rewards, plus PancakeSwap LP fees.
   *
   * @param bondToken Provide the address of the bond token to release to the sender.
   * @param nepTokenAmount The NEP token amount to release.
   * @param bondTokenAmount The bond token amount to release.
   */
  function _releaseBondToSender(address bondToken) private returns (uint256 nepTokenAmount, uint256 bondTokenAmount) {
    (nepTokenAmount, bondTokenAmount) = _pancakeRouter.removeLiquidity(
      address(_nepToken),
      bondToken,
      _bonds[super._msgSender()][bondToken].liquidity,
      _bonds[super._msgSender()][bondToken].nepAmount,
      _bonds[super._msgSender()][bondToken].bondTokenAmount,
      address(this),
      block.timestamp.add(1 hours) // solhint-disable-line
    );
  }

  /**
   * @dev Finalizes and resets the bond release of the sender.
   * @param bondToken Enter the bond liquidity token address.
   */
  function _finalize(address bondToken) private {
    _pool[bondToken].totalLiquidity = _pool[bondToken].totalLiquidity.sub(_bonds[super._msgSender()][bondToken].liquidity);

    _bonds[super._msgSender()][bondToken].releaseDate = 0;
    _bonds[super._msgSender()][bondToken].nepAmount = 0;
    _bonds[super._msgSender()][bondToken].bondTokenAmount = 0;
    _bonds[super._msgSender()][bondToken].liquidity = 0;
  }

  /**
   * @dev Entrypoint to release the bond held by the sender.
   * @param bondToken Enter the bond liquidity token address.
   */
  function releaseBond(address bondToken) external override whenNotPaused nonReentrant {
    require(block.timestamp >= _bonds[super._msgSender()][bondToken].releaseDate, "You're early."); // solhint-disable-line
    require(_bonds[super._msgSender()][bondToken].liquidity > 0, "Nothing to withdraw");

    uint256 exitFee = _bonds[super._msgSender()][bondToken].exitFee;
    uint256 nepTokenAmount;
    uint256 bondTokenAmount;

    if (exitFee == 0) {
      _releaseBondToSender(bondToken);

      emit BondReleased(
        bondToken,
        _bonds[super._msgSender()][bondToken].nepAmount,
        _bonds[super._msgSender()][bondToken].bondTokenAmount,
        nepTokenAmount,
        bondTokenAmount,
        _bonds[super._msgSender()][bondToken].liquidity
      );

      _finalize(bondToken);
      return;
    }

    (nepTokenAmount, bondTokenAmount) = _pancakeRouter.removeLiquidity(
      address(_nepToken),
      bondToken,
      _bonds[super._msgSender()][bondToken].liquidity,
      _bonds[super._msgSender()][bondToken].nepAmount,
      _bonds[super._msgSender()][bondToken].bondTokenAmount,
      address(this),
      block.timestamp.add(1 hours) // solhint-disable-line
    );

    uint256 bondTokenTransferAmount = bondTokenAmount.mul(1000000 - exitFee).div(1000000);
    uint256 nepTokenTransferAmount = nepTokenAmount.mul(1000000 - exitFee).div(1000000);

    /**
     * Transfer both tokens (minus exit fee) to the sender.
     */
    IERC20(bondToken).transfer(super._msgSender(), bondTokenTransferAmount);
    _nepToken.transfer(super._msgSender(), nepTokenTransferAmount);

    /**
     * Transfer the exit fee to the treasury.
     */
    IERC20(bondToken).transfer(_treasury, bondTokenAmount.sub(bondTokenTransferAmount));
    _nepToken.transfer(_treasury, nepTokenAmount.sub(nepTokenTransferAmount));

    _finalize(bondToken);

    emit BondReleased(
      bondToken,
      _bonds[super._msgSender()][bondToken].nepAmount,
      _bonds[super._msgSender()][bondToken].bondTokenAmount,
      nepTokenAmount,
      bondTokenAmount,
      _bonds[super._msgSender()][bondToken].liquidity
    );
  }
}
