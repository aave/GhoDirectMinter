// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {MiscEthereum} from "aave-address-book/MiscEthereum.sol";
import {AaveV3Ethereum, AaveV3EthereumAssets, IACLManager} from "aave-address-book/AaveV3Ethereum.sol";
import {AaveV3EthereumLido} from "aave-address-book/AaveV3EthereumLido.sol";
import {GovernanceV3Ethereum} from "aave-address-book/GovernanceV3Ethereum.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {
  ITransparentProxyFactory
} from "solidity-utils/contracts/transparent-proxy/interfaces/ITransparentProxyFactory.sol";
import {
  UpgradeableOwnableWithGuardian,
  IWithGuardian
} from "solidity-utils/contracts/access-control/UpgradeableOwnableWithGuardian.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {GovV3Helpers} from "aave-helpers/src/GovV3Helpers.sol";
import {IPool, DataTypes} from "aave-v3-origin/contracts/interfaces/IPool.sol";
import {ReserveConfiguration} from "aave-v3-origin/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {GhoDirectMinter} from "../src/GhoDirectMinter.sol";
import {IGhoToken} from "../src/interfaces/IGhoToken.sol";
import {DeploymentLibrary} from "../script/Deploy.s.sol";

contract GHODirectMinter_Test is Test {
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  // its the council used on other GHO stewards
  // might make sense to have on address book
  address council = 0x8513e6F37dBc52De87b166980Fa3F50639694B60;

  GhoDirectMinter internal minter;
  uint128 internal constant MINT_AMOUNT = 200_000 ether;
  IERC20 internal ghoAToken;

  address owner = GovernanceV3Ethereum.EXECUTOR_LVL_1;

  function setUp() external {
    vm.createSelectFork(vm.rpcUrl("mainnet"), 23189945);

    // list facilitator
    minter = GhoDirectMinter(DeploymentLibrary._deployCore());
    vm.startPrank(owner);
    IAccessControl(address(getACL())).grantRole(getACL().RISK_ADMIN_ROLE(), address(minter));
    IGhoToken(AaveV3EthereumAssets.GHO_UNDERLYING).addFacilitator(address(minter), "minter", MINT_AMOUNT);

    address[] memory facilitators = IGhoToken(AaveV3EthereumAssets.GHO_UNDERLYING).getFacilitatorsList();
    assertEq(facilitators[facilitators.length - 1], address(minter));
    ghoAToken = IERC20(minter.GHO_A_TOKEN());

    // burn all supply to start with a clean state on the tests
    assertEq(ghoAToken.balanceOf(address(minter)), 0);
    vm.stopPrank();
  }

  function getPool() internal pure returns (IPool) {
    return AaveV3Ethereum.POOL;
  }

  function getACL() internal pure returns (IACLManager) {
    return AaveV3Ethereum.ACL_MANAGER;
  }

  function test_mintAndSupply_owner(uint256 amount) public returns (uint256) {
    return _mintAndSupply(amount, owner);
  }

  function test_mintAndSupply_council(uint256 amount) external returns (uint256) {
    return _mintAndSupply(amount, council);
  }

  function test_mintAndSupply_rando() external {
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
    // supply sth and borrow gho
    deal(AaveV3EthereumAssets.wstETH_UNDERLYING, address(this), 1_000 ether);
    IERC20(AaveV3EthereumAssets.wstETH_UNDERLYING).approve(address(AaveV3EthereumLido.POOL), 1_000 ether);
    AaveV3EthereumLido.POOL.deposit(AaveV3EthereumAssets.wstETH_UNDERLYING, 1_000 ether, address(this), 0);
    vm.prank(owner);
    AaveV3EthereumLido.POOL_CONFIGURATOR.setBorrowCap(AaveV3EthereumAssets.GHO_UNDERLYING, 0);
    AaveV3EthereumLido.POOL.borrow(AaveV3EthereumAssets.GHO_UNDERLYING, amount, 2, 0, address(this));

    // generate some yield
    vm.warp(block.timestamp + 1000);

    uint256 collectorBalanceBeforeTransfer = ghoAToken.balanceOf(address(minter.COLLECTOR()));
    uint256 balanceBeforeTransfer = ghoAToken.balanceOf(address(minter));
    // is equal on core due to rf 100%
    // is gt on lido due to ef < 100%
    assertGe(balanceBeforeTransfer, amount);
    minter.transferExcessToTreasury();
    assertApproxEqAbs(ghoAToken.balanceOf(address(minter)), amount, 1);
    assertApproxEqAbs(
      ghoAToken.balanceOf(address(minter.COLLECTOR())) - collectorBalanceBeforeTransfer,
      balanceBeforeTransfer - amount,
      1
    );
  }

  /// @dev supplies a bounded value of [amount, 1, type(uint256).max] to the pool
  function _mintAndSupply(uint256 amount, address caller) internal returns (uint256) {
    // setup
    amount = bound(amount, 1, MINT_AMOUNT);
    DataTypes.ReserveConfigurationMap memory configurationBefore =
      getPool().getConfiguration(AaveV3EthereumAssets.GHO_UNDERLYING);
    uint256 totalATokenSupplyBefore = ghoAToken.totalSupply();
    uint256 minterATokenSupplyBefore = IERC20(ghoAToken).balanceOf(address(minter));
    (, uint256 levelBefore) = IGhoToken(AaveV3EthereumAssets.GHO_UNDERLYING).getFacilitatorBucket(address(minter));

    // mint
    vm.prank(caller);
    minter.mintAndSupply(amount);

    // check
    DataTypes.ReserveConfigurationMap memory configurationAfter =
      getPool().getConfiguration(AaveV3EthereumAssets.GHO_UNDERLYING);
    (, uint256 levelAfter) = IGhoToken(AaveV3EthereumAssets.GHO_UNDERLYING).getFacilitatorBucket(address(minter));
    // after supplying the minters aToken balance should increase by the supplied amount
    assertEq(IERC20(ghoAToken).balanceOf(address(minter)), minterATokenSupplyBefore + amount);
    // the aToken total supply should be adjusted by the same amount
    assertEq(ghoAToken.totalSupply(), totalATokenSupplyBefore + amount);
    // the cap should not be touched
    assertEq(configurationBefore.getSupplyCap(), configurationAfter.getSupplyCap());
    // level should be increased by the minted amount
    assertEq(levelAfter, levelBefore + amount);
    return amount;
  }

  // burns a bounded value of [withdrawAmount, 1, boundedSupplyAmount] from the pool
  function _withdrawAndBurn(uint256 supplyAmount, uint256 withdrawAmount, address caller) internal {
    // setup
    uint256 amount = _mintAndSupply(supplyAmount, owner);
    withdrawAmount = bound(withdrawAmount, 1, amount);
    uint256 totalATokenSupplyBefore = ghoAToken.totalSupply();
    (, uint256 levelBefore) = IGhoToken(AaveV3EthereumAssets.GHO_UNDERLYING).getFacilitatorBucket(address(minter));

    // burn
    vm.prank(caller);
    minter.withdrawAndBurn(withdrawAmount);

    // check
    (, uint256 levelAfter) = IGhoToken(AaveV3EthereumAssets.GHO_UNDERLYING).getFacilitatorBucket(address(minter));
    // aToken total supply should be decreased by the burned amount
    assertEq(ghoAToken.totalSupply(), totalATokenSupplyBefore - withdrawAmount);
    // the minter supply should shrink by the same amount
    assertEq(IERC20(ghoAToken).balanceOf(address(minter)), amount - withdrawAmount);
    // the minter level should shrink by the same amount
    assertEq(levelAfter, levelBefore - withdrawAmount);
  }
}
