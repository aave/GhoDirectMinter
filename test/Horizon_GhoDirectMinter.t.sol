// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {MiscEthereum} from "aave-address-book/MiscEthereum.sol";
import {AaveV3EthereumAssets} from "aave-address-book/AaveV3Ethereum.sol";
import {GovernanceV3Ethereum} from "aave-address-book/GovernanceV3Ethereum.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ITransparentProxyFactory} from "solidity-utils/contracts/transparent-proxy/interfaces/ITransparentProxyFactory.sol";
import {UpgradeableOwnableWithGuardian, IWithGuardian} from "solidity-utils/contracts/access-control/UpgradeableOwnableWithGuardian.sol";
import {GovV3Helpers} from "aave-helpers/src/GovV3Helpers.sol";
import {IPool, DataTypes} from "aave-v3-origin/contracts/interfaces/IPool.sol";
import {ReserveConfiguration} from "aave-v3-origin/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {GhoDirectMinter} from "../src/GhoDirectMinter.sol";
import {HorizonGHOListing} from "../src/proposals/HorizonGHOListing.sol";
import {IGhoToken} from "../src/interfaces/IGhoToken.sol";
import {DeploymentLibrary} from "../script/DeployHorizon.s.sol";

contract Horizon_GHODirectMinter_Test is Test {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    IPool constant POOL = IPool(0xAe05Cd22df81871bc7cC2a04BeCfb516bFe332C8); // horizon pool
    address public constant USTB_TOKEN =
        0x43415eB6ff9DB7E26A15b704e7A3eDCe97d31C4e;

    GhoDirectMinter internal minter;
    IERC20 internal ghoAToken;
    HorizonGHOListing internal proposal;

    function setUp() external {
        vm.createSelectFork(vm.rpcUrl("mainnet"));

        // execute pending gho listing payload
        GovV3Helpers.executePayload(vm, 218); // TODO: update

        // execute payload
        address facilitator = DeploymentLibrary._deployHorizon();
        proposal = new HorizonGHOListing();
        GovV3Helpers.executePayload(vm, address(proposal));

        address[] memory facilitators = IGhoToken(
            AaveV3EthereumAssets.GHO_UNDERLYING
        ).getFacilitatorsList();
        minter = GhoDirectMinter(facilitators[facilitators.length - 1]);
        assertEq(address(minter), facilitator);
        ghoAToken = IERC20(minter.GHO_A_TOKEN());
    }

    function test_mintAndSupply_owner(uint256 amount) public returns (uint256) {
        return
            _mintAndSupply(
                amount,
                DeploymentLibrary.HORIZON_OPERATIONAL_MULTISIG
            );
    }

    function test_mintAndSupply_council(
        uint256 amount
    ) external returns (uint256) {
        return _mintAndSupply(amount, DeploymentLibrary.COUNCIL);
    }

    function test_mintAndSupply_rando() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector,
                address(this)
            )
        );
        minter.mintAndSupply(vm.randomUint(1, 100e18));
    }

    function test_withdrawAndBurn_owner(
        uint256 supplyAmount,
        uint256 withdrawAmount
    ) external {
        _withdrawAndBurn(
            supplyAmount,
            withdrawAmount,
            DeploymentLibrary.HORIZON_OPERATIONAL_MULTISIG
        );
    }

    function test_withdrawAndBurn_council(
        uint256 supplyAmount,
        uint256 withdrawAmount
    ) external {
        _withdrawAndBurn(
            supplyAmount,
            withdrawAmount,
            DeploymentLibrary.COUNCIL
        );
    }

    function test_withdrawAndBurn_rando() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector,
                address(this)
            )
        );
        minter.withdrawAndBurn(vm.randomUint(1, 100e18));
    }

    function test_transferExcessToTreasury() external {
        uint256 amount = test_mintAndSupply_owner(1000 ether);
        // supply USTB and borrow gho
        deal(USTB_TOKEN, address(this), 10_000e6);
        IERC20(USTB_TOKEN).approve(address(POOL), 10_000e6);
        POOL.deposit(USTB_TOKEN, 10_000e6, address(this), 0);
        POOL.borrow(
            AaveV3EthereumAssets.GHO_UNDERLYING,
            amount,
            2,
            0,
            address(this)
        );

        // generate some yield
        vm.warp(block.timestamp + 1000);

        uint256 collectorBalanceBeforeTransfer = ghoAToken.balanceOf(
            address(minter.COLLECTOR())
        );
        uint256 balanceBeforeTransfer = ghoAToken.balanceOf(address(minter));
        assertGt(balanceBeforeTransfer, amount);
        minter.transferExcessToTreasury();
        assertApproxEqAbs(ghoAToken.balanceOf(address(minter)), amount, 1);
        assertApproxEqAbs(
            ghoAToken.balanceOf(address(minter.COLLECTOR())) -
                collectorBalanceBeforeTransfer,
            balanceBeforeTransfer - amount,
            1
        );
    }

    /// @dev supplies a bounded value of [amount, 1, type(uint256).max] to the pool
    function _mintAndSupply(
        uint256 amount,
        address caller
    ) internal returns (uint256) {
        // setup
        amount = bound(amount, 1, 100e18);
        DataTypes.ReserveConfigurationMap memory configurationBefore = POOL
            .getConfiguration(AaveV3EthereumAssets.GHO_UNDERLYING);
        uint256 totalATokenSupplyBefore = ghoAToken.totalSupply();
        uint256 minterATokenSupplyBefore = IERC20(ghoAToken).balanceOf(
            address(minter)
        );
        (, uint256 levelBefore) = IGhoToken(AaveV3EthereumAssets.GHO_UNDERLYING)
            .getFacilitatorBucket(proposal.GHO_DIRECT_MINTER());

        // mint
        vm.prank(caller);
        minter.mintAndSupply(amount);

        // check
        DataTypes.ReserveConfigurationMap memory configurationAfter = POOL
            .getConfiguration(AaveV3EthereumAssets.GHO_UNDERLYING);
        (, uint256 levelAfter) = IGhoToken(AaveV3EthereumAssets.GHO_UNDERLYING)
            .getFacilitatorBucket(proposal.GHO_DIRECT_MINTER());
        // after supplying the minters aToken balance should increase by the supplied amount
        assertEq(
            IERC20(ghoAToken).balanceOf(address(minter)),
            minterATokenSupplyBefore + amount
        );
        // the aToken total supply should be adjusted by the same amount
        assertEq(ghoAToken.totalSupply(), totalATokenSupplyBefore + amount);
        // the cap should not be touched
        assertEq(
            configurationBefore.getSupplyCap(),
            configurationAfter.getSupplyCap()
        );
        // level should be increased by the minted amount
        assertEq(levelAfter, levelBefore + amount);
        return amount;
    }

    // burns a bounded value of [withdrawAmount, 1, boundedSupplyAmount] from the pool
    function _withdrawAndBurn(
        uint256 supplyAmount,
        uint256 withdrawAmount,
        address caller
    ) internal {
        // setup
        uint256 amount = _mintAndSupply(
            supplyAmount,
            DeploymentLibrary.HORIZON_OPERATIONAL_MULTISIG
        );
        withdrawAmount = bound(withdrawAmount, 1, amount);
        uint256 totalATokenSupplyBefore = ghoAToken.totalSupply();
        (, uint256 levelBefore) = IGhoToken(AaveV3EthereumAssets.GHO_UNDERLYING)
            .getFacilitatorBucket(proposal.GHO_DIRECT_MINTER());

        // burn
        vm.prank(caller);
        minter.withdrawAndBurn(withdrawAmount);

        // check
        (, uint256 levelAfter) = IGhoToken(AaveV3EthereumAssets.GHO_UNDERLYING)
            .getFacilitatorBucket(proposal.GHO_DIRECT_MINTER());
        // aToken total supply should be decreased by the burned amount
        assertEq(
            ghoAToken.totalSupply(),
            totalATokenSupplyBefore - withdrawAmount
        );
        // the minter supply should shrink by the same amount
        assertEq(
            IERC20(ghoAToken).balanceOf(address(minter)),
            amount - withdrawAmount
        );
        // the minter level should shrink by the same amount
        assertEq(levelAfter, levelBefore - withdrawAmount);
    }
}
