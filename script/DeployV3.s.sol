// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Script.sol";
import { NeonMechLegionV3 } from "../src/NeonMechLegionV3.sol";

/// @notice 部署 NeonMechLegionV3 到 RH Chain。
/// 用法:
///   export OWNER_PRIVATE_KEY=0x...      # 合约 owner (项目钱包, 需有 RH Chain gas 代币)
///   export COUPON_SIGNER=0x...          # 后端 coupon 签名公钥
///   export BASE_URI="https://neonmechlegion.xyz/assets/metadata"
///   export POINTS_PRICE=800000000000000 # 0.0008 ETH (wei) = 1000 分
///
/// 1) 先 dry-run 演练 (不花钱):
///   forge script script/DeployV3.s.sol:DeployV3 --rpc-url robinhood
/// 2) 确认无误后广播 (RH Chain 走 EIP-1559, 不用 --legacy):
///   forge script script/DeployV3.s.sol:DeployV3 \
///     --rpc-url robinhood --broadcast --slow --verify \
///     --etherscan-api-key "" --verifier blockscout \
///     --verifier-url "https://api.routescan.io/v2/network/mainnet/evm/4663/etherscan"
///   (验证器可选; RH Chain 区块浏览器 = robinhoodchain.blockscout.com)
/// 3) 部署后: 用 mintBatch 把 32 个 V2 老持有者迁移到 V3 同地址; 再在 OpenSea 新建 drop 指向新合约。
contract DeployV3 is Script {
    // RH Chain 上已部署的 OpenSea SeaDrop 标准地址 (链无关)
    address constant SEADROP = 0x00005EA00Ac477B1030CE78506496e8C2dE24bf5;

    function run() external {
        uint256 pk = vm.envUint("OWNER_PRIVATE_KEY");
        address signer = vm.envAddress("COUPON_SIGNER");
        string memory baseURI = vm.envString("BASE_URI");
        uint256 pointsPrice = vm.envUint("POINTS_PRICE");

        address[] memory allowed = new address[](1);
        allowed[0] = SEADROP;

        vm.startBroadcast(pk);
        NeonMechLegionV3 v3 = new NeonMechLegionV3(baseURI, pointsPrice, signer, allowed);
        vm.stopBroadcast();

        console.log("NeonMechLegionV3 deployed at:", address(v3));
        console.log("  allowedSeaDrop:", SEADROP);
        console.log("  maxSupply (genesis cap):", v3.MAX_GENESIS());
    }
}
