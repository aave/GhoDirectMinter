// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {MiscEthereum} from "aave-address-book/MiscEthereum.sol";
import {AaveV3EthereumAssets} from "aave-address-book/AaveV3Ethereum.sol";
import {GovernanceV3Ethereum} from "aave-address-book/GovernanceV3Ethereum.sol";
import {GhoEthereum} from "aave-address-book/GhoEthereum.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {
  ITransparentProxyFactory
} from "solidity-utils/contracts/transparent-proxy/interfaces/ITransparentProxyFactory.sol";
import {IWithGuardian} from "solidity-utils/contracts/access-control/UpgradeableOwnableWithGuardian.sol";
import {IHub} from "aave-v4/hub/interfaces/IHub.sol";
import {IHubBase} from "aave-v4/hub/interfaces/IHubBase.sol";
import {IAccessManager} from "aave-v4/dependencies/openzeppelin/IAccessManager.sol";
import {IGhoDirectMinterV4} from "../src/interfaces/IGhoDirectMinterV4.sol";
import {IGhoToken} from "../src/interfaces/IGhoToken.sol";
import {DeploymentLibrary} from "../script/Deploy.s.sol";

contract GHODirectMinterV4_Test is Test {
  // @dev deployments on mainnet fork
  IHub internal hub = IHub(0x3Ed2C9829FBCab6015E331a0352F8ae148217D70); // core hub

  uint256 internal ghoAssetId;
  address internal feeReceiver;

  address internal council = GhoEthereum.RISK_COUNCIL;
  address internal owner = GovernanceV3Ethereum.EXECUTOR_LVL_1;

  IGhoDirectMinterV4 internal minter;
  IGhoToken internal gho = IGhoToken(AaveV3EthereumAssets.GHO_UNDERLYING);
  uint128 internal constant MINT_AMOUNT = 200_000 ether;

  function setUp() external {
    vm.createSelectFork(vm.rpcUrl("devnet"), 25097390);

    minter = IGhoDirectMinterV4(
      DeploymentLibrary._deployV4Facilitator(
        ITransparentProxyFactory(MiscEthereum.TRANSPARENT_PROXY_FACTORY), owner, address(hub), address(gho), council
      )
    );
    ghoAssetId = hub.getAssetId(address(gho));
    feeReceiver = hub.getAssetConfig(ghoAssetId).feeReceiver;

    // register minter as spoke on Hub with infinite addCap
    vm.startPrank(owner);
    hub.addSpoke(
      ghoAssetId,
      address(minter),
      IHub.SpokeConfig({
        addCap: hub.MAX_ALLOWED_SPOKE_CAP(), drawCap: 0, riskPremiumThreshold: 0, active: true, halted: false
      })
    );

    // register minter as GHO facilitator
    gho.addFacilitator(address(minter), "GhoDirectMinterCoreHub", MINT_AMOUNT);
    vm.stopPrank();
  }

  function test_setup() public view {
    assertEq(minter.hub(), address(hub));
    assertEq(minter.gho(), address(gho));
    assertEq(minter.assetId(), ghoAssetId);
    assertEq(hub.getAsset(ghoAssetId).underlying, address(gho));
    address[] memory facilitators = gho.getFacilitatorsList();
    assertEq(facilitators[facilitators.length - 1], address(minter));
    assertEq(hub.getSpokeAddedAssets(ghoAssetId, address(minter)), 0);
  }

  function test_mintAndSupply_owner(uint256 amount) public returns (uint256) {
    return _mintAndSupply(amount, owner);
  }

  function test_mintAndSupply_council(uint256 amount) external returns (uint256) {
    return _mintAndSupply(amount, council);
  }

  function test_mintAndSupply_revertsWith_InvalidCaller() external {
    vm.expectRevert(abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, address(this)));
    minter.mintAndSupply(100);
  }

  function test_withdrawAndBurn_owner(uint256 supplyAmount, uint256 withdrawAmount) external {
    _withdrawAndBurn(supplyAmount, withdrawAmount, owner);
  }

  function test_withdrawAndBurn_council(uint256 supplyAmount, uint256 withdrawAmount) external {
    _withdrawAndBurn(supplyAmount, withdrawAmount, council);
  }

  function test_withdrawAndBurn_rando() external {
    vm.expectRevert(abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, address(this)));
    minter.withdrawAndBurn(100);
  }

  function test_transferExcessToTreasury() external {
    uint256 amount = test_mintAndSupply_owner(1000 ether);

    // set up a borrower spoke that can draw GHO
    address borrower = makeAddr("borrower");
    vm.prank(owner);
    hub.addSpoke(
      ghoAssetId,
      borrower,
      IHub.SpokeConfig({
        addCap: type(uint40).max,
        drawCap: type(uint40).max,
        riskPremiumThreshold: type(uint24).max,
        active: true,
        halted: false
      })
    );

    // generate some yield
    vm.prank(borrower);
    hub.draw(ghoAssetId, amount, makeAddr("borrowerRecipient"));
    skip(365 days);

    uint256 feeReceiverSharesBefore = hub.getSpokeAddedShares(ghoAssetId, feeReceiver);
    uint256 feeReceiverBalanceBefore = hub.getSpokeAddedAssets(ghoAssetId, feeReceiver);
    (, uint256 level) = gho.getFacilitatorBucket(address(minter));
    uint256 spokeAddedAssets = hub.getSpokeAddedAssets(ghoAssetId, address(minter));
    assertGe(spokeAddedAssets, level);

    uint256 excess = spokeAddedAssets - level;
    uint256 expectedShares = hub.previewAddByAssets(ghoAssetId, excess);

    minter.transferExcessToTreasury();

    assertApproxEqAbs(hub.getSpokeAddedAssets(ghoAssetId, address(minter)), level, 1);
    uint256 feeReceiverSharesAfter = hub.getSpokeAddedShares(ghoAssetId, feeReceiver);
    assertApproxEqAbs(feeReceiverSharesAfter - feeReceiverSharesBefore, expectedShares, 1);
    uint256 feeReceiverBalanceAfter = hub.getSpokeAddedAssets(ghoAssetId, feeReceiver);
    assertApproxEqAbs(feeReceiverBalanceAfter - feeReceiverBalanceBefore, excess, 1);
  }

  function test_mintAndSupply_exceedsBucketCapacity() external {
    // mint full bucket capacity
    vm.prank(owner);
    minter.mintAndSupply(MINT_AMOUNT);

    // minting 1 more should revert (GHO bucket capacity exceeded)
    vm.prank(owner);
    vm.expectRevert(bytes("FACILITATOR_BUCKET_CAPACITY_EXCEEDED"));
    minter.mintAndSupply(1);
  }

  function test_mintAndSupply_zeroAmount() external {
    vm.prank(owner);
    vm.expectRevert(bytes("INVALID_MINT_AMOUNT"));
    minter.mintAndSupply(0);
  }

  function test_withdrawAndBurn_exceedsSpokeBalance() external {
    vm.prank(owner);
    minter.mintAndSupply(1000 ether);

    uint256 spokeBalance = hub.getSpokeAddedAssets(ghoAssetId, address(minter));

    // withdrawing more than spoke balance underflows spoke.addedShares
    vm.prank(owner);
    vm.expectRevert(stdError.arithmeticError);
    minter.withdrawAndBurn(spokeBalance + 1);
  }

  function test_withdrawAndBurn_zeroBalance() external {
    // withdrawing when nothing was supplied underflows spoke.addedShares
    vm.prank(owner);
    vm.expectRevert(stdError.arithmeticError);
    minter.withdrawAndBurn(1);
  }

  function test_transferExcessToTreasury_noExcess(uint256 amount) external {
    amount = bound(amount, 2, MINT_AMOUNT);
    vm.prank(owner);
    minter.mintAndSupply(amount);

    (, uint256 level) = gho.getFacilitatorBucket(address(minter));
    uint256 balance = hub.getSpokeAddedAssets(ghoAssetId, address(minter));

    uint256 feeReceiverSharesBefore = hub.getSpokeAddedShares(ghoAssetId, feeReceiver);

    if (balance < level) {
      // balance < level due to share rounding → underflow revert
      vm.expectRevert(stdError.arithmeticError);
      minter.transferExcessToTreasury();
    } else {
      // balance == level → excess is 0, no-op
      minter.transferExcessToTreasury();
      uint256 feeReceiverSharesAfter = hub.getSpokeAddedShares(ghoAssetId, feeReceiver);
      assertEq(feeReceiverSharesAfter, feeReceiverSharesBefore);
    }
  }

  function _mintAndSupply(uint256 amount, address caller) internal returns (uint256) {
    amount = bound(amount, 2, MINT_AMOUNT);

    uint256 totalAddedAssetsBefore = hub.getAddedAssets(ghoAssetId);
    uint256 minterAddedAssetsBefore = hub.getSpokeAddedAssets(ghoAssetId, address(minter));
    (, uint256 levelBefore) = gho.getFacilitatorBucket(address(minter));

    vm.prank(caller);
    minter.mintAndSupply(amount);

    (, uint256 levelAfter) = gho.getFacilitatorBucket(address(minter));
    assertApproxEqAbs(hub.getSpokeAddedAssets(ghoAssetId, address(minter)), minterAddedAssetsBefore + amount, 1);
    assertApproxEqAbs(hub.getAddedAssets(ghoAssetId), totalAddedAssetsBefore + amount, 1);
    // bucket level is exact
    assertEq(levelAfter, levelBefore + amount);

    return amount;
  }

  function _withdrawAndBurn(uint256 supplyAmount, uint256 withdrawAmount, address caller) internal {
    uint256 amount = _mintAndSupply(supplyAmount, owner);
    withdrawAmount = bound(withdrawAmount, 1, amount - 1); // rounding

    uint256 totalAddedAssetsBefore = hub.getAddedAssets(ghoAssetId);
    (, uint256 levelBefore) = gho.getFacilitatorBucket(address(minter));

    vm.prank(caller);
    minter.withdrawAndBurn(withdrawAmount);

    (, uint256 levelAfter) = gho.getFacilitatorBucket(address(minter));
    assertApproxEqAbs(hub.getAddedAssets(ghoAssetId), totalAddedAssetsBefore - withdrawAmount, 2);
    assertApproxEqAbs(hub.getSpokeAddedAssets(ghoAssetId, address(minter)), amount - withdrawAmount, 2);
    assertEq(levelAfter, levelBefore - withdrawAmount);
  }
}
