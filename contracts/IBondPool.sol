// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.4.22 <0.9.0;
import "./IPancakePairLike.sol";

interface IBondPool {
  struct Pair {
    address[] path;
    string name;
    IPancakePairLike pancakePair;
    uint256 maxStake;
    uint256 minBond;
    uint256 entryFee; // Percentage value: upto 4 decimal places, x10000. For example: 25000 means 2.5%
    uint256 exitFee; // Percentage value: upto 4 decimal places, x10000. For example: 25000 means 2.5%
    uint256 lockingPeriod;
    uint256 totalLocked;
    uint256 totalNepPaired;
    uint256 totalLiquidity;
  }

  struct Bond {
    uint256 releaseDate;
    uint256 exitFee; // Percentage value: upto 4 decimal places, x10000. For example: 25000 means 2.5%
    uint256 nepAmount;
    uint256 bondTokenAmount;
    uint256 liquidity;
  }

  event PairUpdated(address indexed token, string name, uint256 maxStake, uint256 minBond, uint256 entryFee, uint256 exitFee, uint256 lockingPeriod, uint256 amount);
  event BondCreated(address indexed bondToken, uint256 nepStaked, uint256 bondTokenStaked, uint256 liquidity);
  event BondReleased(address indexed bondToken, uint256 nepReleased, uint256 bondTokenReleased, uint256 liquidity);

  /**
   * @dev Gets the bond market information information
   * @param token The token address to get the information
   * @param account Enter your account address to get the information
   * @param poolTotalNepPaired Returns the total amount of NEP paired with the given token
   * @param totalLocked Returns the total amount of the token locked/staked in this pool
   * @param totalLiquidity Returns the sum of liquidity (PancakeSwap LP token) locked in this pool
   * @param releaseDate Returns the release date of the sender (if any bond)
   * @param nepAmount Returns the sender's amount of NEP reward that was bonded with the suppplied token
   * @param bondTokenAmount Returns the sender's token amount that was bonded with NEP
   * @param liquidity Returns the sender's liquidity that was created and locked in the PancakeSwap exchange
   */
  function getInfo(address token, address account)
    external
    view
    returns (
      uint256 poolTotalNepPaired,
      uint256 totalLocked,
      uint256 totalLiquidity,
      uint256 releaseDate,
      uint256 nepAmount,
      uint256 bondTokenAmount,
      uint256 liquidity
    );

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
  ) external view returns (uint256 lockingPeriod, uint256 entryFee);

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
  ) external;

  /**
   * @dev Gets the amount of NEP required to create a bond with the supplied token and amount
   * @param tokenAddress The token to create bond with
   * @param amountIn The amount of token to supply
   */
  function getNepRequired(address tokenAddress, uint256 amountIn) external view returns (uint256[] memory);

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
  ) external;

  /**
   * @dev Entrypoint to release the bond held by the sender.
   * @param bondToken Enter the bond liquidity token address.
   */
  function releaseBond(address bondToken) external;
}
