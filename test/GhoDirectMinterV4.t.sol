// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {GovernanceV3Ethereum} from "aave-address-book/GovernanceV3Ethereum.sol";
import {GhoEthereum} from "aave-address-book/GhoEthereum.sol";
import {AaveV4Ethereum, AaveV4EthereumHubs} from "aave-address-book/AaveV4Ethereum.sol";
import {IWithGuardian} from "solidity-utils/contracts/access-control/UpgradeableOwnableWithGuardian.sol";
import {IHub} from "aave-v4/hub/interfaces/IHub.sol";
import {IGhoDirectMinterV4} from "../src/interfaces/IGhoDirectMinterV4.sol";
import {IGhoToken} from "../src/interfaces/IGhoToken.sol";
import {DeploymentLibrary} from "../script/Deploy.s.sol";

contract GHODirectMinterV4_Test is Test {
  IHub internal hub = AaveV4EthereumHubs.CORE_HUB;

  uint256 internal ghoAssetId;
  address internal feeReceiver;

  address internal council = GhoEthereum.RISK_COUNCIL;
  address internal owner = GovernanceV3Ethereum.EXECUTOR_LVL_1;

  IGhoDirectMinterV4 internal minter;
  IGhoToken internal gho = IGhoToken(GhoEthereum.GHO_TOKEN);
  uint128 internal constant MINT_AMOUNT = 200_000 ether;

  function setUp() external {
    vm.createSelectFork(vm.rpcUrl("mainnet"), 26155052);

    minter = IGhoDirectMinterV4(DeploymentLibrary._deployV4Core());
    ghoAssetId = hub.getAssetId(address(gho));
    feeReceiver = hub.getAssetConfig(ghoAssetId).feeReceiver;

    // register minter as spoke on Hub with infinite addCap
    vm.startPrank(owner);
    AaveV4Ethereum.HUB_CONFIGURATOR
      .addSpoke(
        address(hub),
        address(minter),
        ghoAssetId,
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

  function test_withdrawAndBurn_revertsWith_InvalidCaller() external {
    vm.expectRevert(abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, address(this)));
    minter.withdrawAndBurn(100);
  }

  function test_transferExcessToTreasury(uint256 supplyAmount, uint256 drawAmount, uint256 elapsed) external {
    uint256 amount = _mintAndSupply(bound(supplyAmount, 1 ether, MINT_AMOUNT), owner);
    drawAmount = bound(drawAmount, 1, amount);
    elapsed = bound(elapsed, 1 days, 5 * 365 days);

    // set up a borrower spoke that can draw GHO
    address borrower = makeAddr("borrower");
    vm.prank(owner);
    AaveV4Ethereum.HUB_CONFIGURATOR
      .addSpoke(
        address(hub),
        borrower,
        ghoAssetId,
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
    hub.draw(ghoAssetId, drawAmount, makeAddr("borrowerRecipient"));
    skip(elapsed);

    uint256 feeReceiverSharesBefore = hub.getSpokeAddedShares(ghoAssetId, feeReceiver);
    uint256 feeReceiverBalanceBefore = hub.getSpokeAddedAssets(ghoAssetId, feeReceiver);
    (, uint256 level) = gho.getFacilitatorBucket(address(minter));
    uint256 spokeAddedAssets = hub.getSpokeAddedAssets(ghoAssetId, address(minter));
    assertGe(spokeAddedAssets, level);

    uint256 excess = spokeAddedAssets - level;
    uint256 expectedShares = hub.previewAddByAssets(ghoAssetId, excess);

    minter.transferExcessToTreasury();

    assertApproxEqAbs(hub.getSpokeAddedAssets(ghoAssetId, address(minter)), level, 2);
    uint256 feeReceiverSharesAfter = hub.getSpokeAddedShares(ghoAssetId, feeReceiver);
    assertApproxEqAbs(feeReceiverSharesAfter - feeReceiverSharesBefore, expectedShares, 1);
    uint256 feeReceiverBalanceAfter = hub.getSpokeAddedAssets(ghoAssetId, feeReceiver);
    assertApproxEqAbs(feeReceiverBalanceAfter - feeReceiverBalanceBefore, excess, 2);
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
    assertApproxEqAbs(hub.getSpokeAddedAssets(ghoAssetId, address(minter)), minterAddedAssetsBefore + amount, 2);
    assertApproxEqAbs(hub.getAddedAssets(ghoAssetId), totalAddedAssetsBefore + amount, 2);
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
    assertApproxEqAbs(hub.getAddedAssets(ghoAssetId), totalAddedAssetsBefore - withdrawAmount, 3);
    assertApproxEqAbs(hub.getSpokeAddedAssets(ghoAssetId, address(minter)), amount - withdrawAmount, 3);
    assertEq(levelAfter, levelBefore - withdrawAmount);
  }
}
