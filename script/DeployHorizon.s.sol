// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EthereumScript} from "solidity-utils/contracts/utils/ScriptUtils.sol";
import {IPoolAddressesProvider} from "aave-v3-origin/contracts/interfaces/IPoolAddressesProvider.sol";
import {ICollector} from "aave-v3-origin/contracts/treasury/ICollector.sol";
import {ITransparentProxyFactory} from "solidity-utils/contracts/transparent-proxy/interfaces/ITransparentProxyFactory.sol";
import {GhoDirectMinter} from "../src/GhoDirectMinter.sol";
import {IGhoToken} from "../src/interfaces/IGhoToken.sol";

import {AaveV3EthereumAssets} from "aave-address-book/AaveV3Ethereum.sol";
import {AaveV3EthereumLido} from "aave-address-book/AaveV3EthereumLido.sol";
import {GovernanceV3Ethereum} from "aave-address-book/GovernanceV3Ethereum.sol";
import {MiscEthereum} from "aave-address-book/MiscEthereum.sol";

library DeploymentLibrary {
    address public constant HORIZON_OPERATIONAL_MULTISIG =
        0xE6ec1f0Ae6Cd023bd0a9B4d0253BDC755103253c; // horizon operational multisig
    address public constant POOL_ADDRESSES_PROVIDER =
        0x5D39E06b825C1F2B80bf2756a73e28eFAA128ba0; // horizon pool addresses provider
    address public constant COLLECTOR =
        0xE5E6091073a9EcaCD8611d0D4A843464ebf3D2F8; // horizon revenue splitter
    address public constant COUNCIL =
        0x8513e6F37dBc52De87b166980Fa3F50639694B60; // council used on other GHO stewards

    function _deployFacilitator(
        ITransparentProxyFactory proxyFactory,
        address proxyAdmin,
        IPoolAddressesProvider poolAddressesProvider,
        address collector,
        IGhoToken gho
    ) internal returns (address) {
        address vaultImpl = address(
            new GhoDirectMinter(
                poolAddressesProvider,
                address(collector),
                address(gho)
            )
        );
        return
            proxyFactory.create(
                vaultImpl,
                proxyAdmin,
                abi.encodeWithSelector(
                    GhoDirectMinter.initialize.selector,
                    address(GovernanceV3Ethereum.EXECUTOR_LVL_1),
                    COUNCIL
                )
            );
    }

    function _deployHorizon() internal returns (address) {
        return
            _deployFacilitator(
                // new version of transparent proxy factory
                ITransparentProxyFactory(
                    MiscEthereum.TRANSPARENT_PROXY_FACTORY
                ),
                MiscEthereum.PROXY_ADMIN,
                IPoolAddressesProvider(POOL_ADDRESSES_PROVIDER),
                address(COLLECTOR),
                IGhoToken(AaveV3EthereumAssets.GHO_UNDERLYING)
            );
    }
}
contract DeployHorizon is EthereumScript {
    function run() external broadcast {
        DeploymentLibrary._deployHorizon();
    }
}
