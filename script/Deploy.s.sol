// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EthereumScript} from "solidity-utils/contracts/utils/ScriptUtils.sol";
import {IPoolAddressesProvider} from "aave-v3-origin/contracts/interfaces/IPoolAddressesProvider.sol";
import {ICollector} from "aave-v3-origin/contracts/treasury/ICollector.sol";
import {ITransparentProxyFactory} from "solidity-utils/contracts/transparent-proxy/interfaces/ITransparentProxyFactory.sol";
import {GhoDirectMinter} from "../src/GhoDirectMinter.sol";
import {GhoDirectMinterV4} from "../src/GhoDirectMinterV4.sol";
import {IGhoToken} from "../src/interfaces/IGhoToken.sol";

import {AaveV3Ethereum, AaveV3EthereumAssets} from "aave-address-book/AaveV3Ethereum.sol";
import {AaveV3EthereumLido} from "aave-address-book/AaveV3EthereumLido.sol";
import {GovernanceV3Ethereum} from "aave-address-book/GovernanceV3Ethereum.sol";
import {MiscEthereum} from "aave-address-book/MiscEthereum.sol";

library DeploymentLibrary {
  function _deployFacilitator(
    ITransparentProxyFactory proxyFactory,
    address upgradeAdmin,
    IPoolAddressesProvider poolAddressesProvider,
    address collector,
    IGhoToken gho,
    address council
  ) internal returns (address) {
    address vaultImpl = address(new GhoDirectMinter(poolAddressesProvider, address(collector), address(gho)));
    return
      proxyFactory.create(
        vaultImpl,
        upgradeAdmin,
        abi.encodeWithSelector(
          GhoDirectMinter.initialize.selector,
          address(GovernanceV3Ethereum.EXECUTOR_LVL_1),
          council
        )
      );
  }

  function _deployV4Facilitator(
    ITransparentProxyFactory proxyFactory,
    address upgradeAdmin,
    address hub,
    address gho,
    address council
  ) internal returns (address) {
    address impl = address(new GhoDirectMinterV4(hub, gho));
    return
      proxyFactory.create(
        impl,
        upgradeAdmin,
        abi.encodeCall(GhoDirectMinterV4.initialize, (address(GovernanceV3Ethereum.EXECUTOR_LVL_1), council))
      );
  }

  function _deployCore() internal returns (address) {
    address council = 0x8513e6F37dBc52De87b166980Fa3F50639694B60;

    return
      ITransparentProxyFactory(MiscEthereum.TRANSPARENT_PROXY_FACTORY).create(
        0xE4C958dE49303c9be571E00582CF9454586dE76F,
        GovernanceV3Ethereum.EXECUTOR_LVL_1,
        abi.encodeWithSelector(
          GhoDirectMinter.initialize.selector,
          address(GovernanceV3Ethereum.EXECUTOR_LVL_1),
          council
        )
      );
  }
}

contract DeployCore is EthereumScript {
  function run() external broadcast {
    DeploymentLibrary._deployCore();
  }
}
