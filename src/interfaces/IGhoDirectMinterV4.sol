// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title IGhoDirectMinterV4
/// @author Aave Labs
/// @notice Interface for the GhoDirectMinter, a GHO facilitator that injects (mints) and removes (burns) GHO from an Aave v4 Hub.
/// @dev The GhoDirectMinter is expected to be registered as a spoke on the Hub with infinite addCap.
interface IGhoDirectMinterV4 {
  /// @notice Initializes the contract.
  /// @param owner The address of the owner.
  /// @param council The address of the guardian council.
  function initialize(address owner, address council) external;

  /// @notice Mints GHO and adds it as liquidity to the Hub.
  /// @dev Only callable by the owner or guardian.
  /// @param amount The amount of GHO to mint and supply.
  function mintAndSupply(uint256 amount) external;

  /// @notice Removes GHO liquidity from the Hub and burns it.
  /// @dev Only callable by the owner or guardian.
  /// @param amount The amount of GHO to withdraw and burn.
  function withdrawAndBurn(uint256 amount) external;

  /// @notice Transfers excess GHO interest (added shares above facilitator bucket level) to the fee receiver.
  /// @dev Callable by anyone.
  /// @dev Due to rounding in the share conversion, the amount transferred may be slightly less than the true excess.
  /// This is neglectable and should not have any impact on the system.
  function transferExcessToTreasury() external;

  /// @notice Returns the address of the Aave v4 Hub.
  /// @return The Hub contract address.
  function hub() external view returns (address);

  /// @notice Returns the asset identifier for GHO in the Hub.
  /// @return The asset identifier.
  function assetId() external view returns (uint256);

  /// @notice Returns the address of the GHO token.
  /// @return The GHO token address.
  function gho() external view returns (address);
}
