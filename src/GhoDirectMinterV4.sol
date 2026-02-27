// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {
  UpgradeableOwnableWithGuardian
} from "solidity-utils/contracts/access-control/UpgradeableOwnableWithGuardian.sol";
import {IGhoToken} from "./interfaces/IGhoToken.sol";
import {IGhoDirectMinterV4} from "./interfaces/IGhoDirectMinterV4.sol";
import {IHub} from "aave-v4/hub/interfaces/IHub.sol";

/// @title GhoDirectMinterV4
/// @author Aave Labs
/// @notice A GHO facilitator that injects (mints) and removes (burns) GHO from an Aave v4 Hub.
/// @dev The GhoDirectMinterV4 is expected to be registered as a spoke on the Hub with infinite addCap.
contract GhoDirectMinterV4 is Initializable, UpgradeableOwnableWithGuardian, IGhoDirectMinterV4 {
  IGhoToken internal immutable GHO;
  IHub internal immutable HUB;
  uint256 internal immutable ASSET_ID;

  /// @dev Constructor.
  /// @param hub_ The address of the Aave v4 Hub.
  /// @param gho_ The address of the GHO token.
  constructor(address hub_, address gho_) {
    HUB = IHub(hub_);
    ASSET_ID = HUB.getAssetId(gho_); // reverts on invalid `underlying`
    GHO = IGhoToken(gho_);
    _disableInitializers();
  }

  /// @inheritdoc IGhoDirectMinterV4
  function initialize(address owner, address council) external virtual initializer {
    __Ownable_With_Guardian_init(owner, council);
  }

  /// @inheritdoc IGhoDirectMinterV4
  function mintAndSupply(uint256 amount) external onlyOwnerOrGuardian {
    GHO.mint(address(HUB), amount);
    HUB.add(ASSET_ID, amount); // this spoke is given infinite cap
  }

  /// @inheritdoc IGhoDirectMinterV4
  function withdrawAndBurn(uint256 amount) external onlyOwnerOrGuardian {
    HUB.remove(ASSET_ID, amount, address(this));
    GHO.burn(amount);
  }

  /// @inheritdoc IGhoDirectMinterV4
  function transferExcessToTreasury() external {
    (, uint256 level) = GHO.getFacilitatorBucket(address(this));
    uint256 balance = HUB.getSpokeAddedAssets(ASSET_ID, address(this));
    uint256 excess = balance - level;
    // underestimate excess shares to ensure the facilitator remains at or above bucket level
    uint256 excessShares = HUB.previewAddByAssets(ASSET_ID, excess);
    if (excessShares > 0) {
      HUB.payFeeShares(ASSET_ID, excessShares);
    }
  }

  /// @inheritdoc IGhoDirectMinterV4
  function hub() external view returns (address) {
    return address(HUB);
  }

  /// @inheritdoc IGhoDirectMinterV4
  function assetId() external view returns (uint256) {
    return ASSET_ID;
  }

  /// @inheritdoc IGhoDirectMinterV4
  function gho() external view returns (address) {
    return address(GHO);
  }
}
