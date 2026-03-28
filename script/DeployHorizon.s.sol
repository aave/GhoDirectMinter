// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EthereumScript} from "solidity-utils/contracts/utils/ScriptUtils.sol";
import {IPoolAddressesProvider} from "aave-v3-origin/contracts/interfaces/IPoolAddressesProvider.sol";
import {ICollector} from "aave-v3-origin/contracts/treasury/ICollector.sol";
import {ITransparentProxyFactory} from "solidity-utils/contracts/transparent-proxy/interfaces/ITransparentProxyFactory.sol";
import {GhoDirectMinter} from "../src/GhoDirectMinter.sol";
import {IGhoToken} from "../src/interfaces/IGhoToken.sol";

import {AaveV3Ethereum} from "aave-address-book/AaveV3Ethereum.sol";
import {GovernanceV3Ethereum} from "aave-address-book/GovernanceV3Ethereum.sol";
import {MiscEthereum} from "aave-address-book/MiscEthereum.sol";
import {GhoEthereum} from "aave-address-book/GhoEthereum.sol";

library DeploymentLibrary {
    address public constant EXECUTOR_LVL_1 =
        GovernanceV3Ethereum.EXECUTOR_LVL_1;
    IPoolAddressesProvider public constant POOL_ADDRESSES_PROVIDER =
        IPoolAddressesProvider(0x5D39E06b825C1F2B80bf2756a73e28eFAA128ba0); // horizon pool addresses provider
    address public constant COLLECTOR = address(AaveV3Ethereum.COLLECTOR);
    address public constant COUNCIL =
        0x8513e6F37dBc52De87b166980Fa3F50639694B60; // council used on other GHO stewards

    function _deployHorizon() internal returns (address) {
        address impl = address(
            new GhoDirectMinter(
                POOL_ADDRESSES_PROVIDER,
                COLLECTOR,
                GhoEthereum.GHO_TOKEN
            )
        );
        address proxy = ITransparentProxyFactory(
            MiscEthereum.TRANSPARENT_PROXY_FACTORY
        ).create(
                impl,
                EXECUTOR_LVL_1,
                abi.encodeCall(
                    GhoDirectMinter.initialize,
                    (EXECUTOR_LVL_1, COUNCIL)
                )
            );
        return proxy;
    }
}

contract DeployHorizon is EthereumScript {
    function run() external broadcast {
        DeploymentLibrary._deployHorizon();
    }
}
