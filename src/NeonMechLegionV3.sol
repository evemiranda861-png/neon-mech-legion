// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { ERC721SeaDrop } from "seadrop/src/ERC721SeaDrop.sol";

import { Strings } from "openzeppelin-contracts/utils/Strings.sol";
import { ECDSA } from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";

/**
 * @title  Neon Mech Legion V3 (SeaDrop-compatible)
 * @notice 在 OpenSea SeaDrop 合约 (0x00005EA0...bf5) 上做铸造 + 保留 V2 全部游戏逻辑。
 *
 * 设计要点:
 *  - 继承 ProjectOpenSea 的 ERC721SeaDrop, 自动获得 SeaDrop 全部接口
 *    (mintSeaDrop / getMintStats / update* / supportsInterface 等)。
 *  - OpenSea Drop 的铸造走 mintSeaDrop(minter, qty) -> 内部 _safeMint,
 *    使用 ERC721A 自增 ID (从 1 起, 与 V2 一致)。
 *  - 游戏侧 coupon mint / 合成同样走 ERC721A 自增 ID, 与 SeaDrop mint 共用同一 ID 序列,
 *    不会出现 V2 那种独立计数器与 SeaDrop 计数器分叉的问题。
 *  - 合成卡不再靠 ID 区间 (>MAX_GENESIS) 区分, 而是用 synthTier[id]!=0 标记。
 *    tierOf: synthTier[id]!=0 -> 返回存储等级; 否则 _deriveTier(id) 确定性推导。
 *    这样合成可发生在任意时刻 (不要求先铸满 10000), 且 ID 唯一无冲突。
 *  - MAX_GENESIS=10000 同时作为总铸造上限 (_maxSupply): 原生卡上限 10000,
 *    合成净减供应, 不会超过 10000。
 *
 * 稀有度等级 (uint8): 1=Common, 2=Uncommon, 3=Rare, 4=Epic, 5=Legendary
 *
 * Coupon 哈希 (后端与合约必须一致):
 *   keccak256(abi.encodePacked(owner, action, param, cost, nonce, expire, chainId))
 *   action: 0 = mint, 1 = synth
 */
contract NeonMechLegionV3 is ERC721SeaDrop {
    using Strings for uint256;
    using ECDSA for bytes32;

    // ============ 常量 ============
    uint256 public constant MAX_GENESIS = 10000; // 原生卡上限 = 总铸造上限
    uint256 public totalBurned;                  // 累计销毁数
    uint256 public constant TIER_SEED = 0x4e6d6c2024; // 与 metadata 脚本共用

    // ============ 状态 ============
    bool public mintActive = true;   // 预留开关 (coupon 仍是唯一铸币路径)
    bool public synthActive;
    uint256 public mintPrice;        // 兼容字段 (当前 mint 走 coupon, 不收 ETH)
    uint256 public pointsPrice;      // 买 1000 分所需 ETH (0.0008 ETH)
    uint256 public constant POINTS_PER_BUY = 1000;

    address public signer;           // 后端 coupon 签名公钥

    mapping(uint256 => uint8) public synthTier;
    mapping(uint256 => bool) public usedNonce;

    // ============ 事件 ============
    event Synthesized(address indexed owner, uint256[3] burnedIds, uint256 newId, uint8 newTier);
    event GenesisMinted(address indexed to, uint256 tokenId, uint8 tier);
    event PointsPurchased(address indexed buyer, uint256 amount);
    event CouponUsed(address indexed owner, uint256 indexed nonce, uint8 action);

    /**
     * @param _baseURI     metadata 基础 URL
     * @param _pointsPrice 买 1000 分所需 ETH (wei)
     * @param _signer      后端 coupon 签名公钥
     * @param allowedSeaDrop 允许的 SeaDrop 地址数组 (RH Chain: 0x00005EA0...bf5)
     */
    constructor(
        string memory _baseURI,
        uint256 _pointsPrice,
        address _signer,
        address[] memory allowedSeaDrop
    ) ERC721SeaDrop("Neon Mech Legion", "NML", allowedSeaDrop) {
        // ERC721ContractMetadata 内部存储, 直接赋值 (构造函数中 msg.sender 即 owner)
        _tokenBaseURI = _baseURI;
        _maxSupply = MAX_GENESIS;
        pointsPrice = _pointsPrice;
        signer = _signer;
    }

    // ============ 稀有度推导 (原生卡, 确定性、零存储) ============
    function _deriveTier(uint256 id) internal pure returns (uint8) {
        uint256 h = uint256(keccak256(abi.encodePacked(id, TIER_SEED)));
        uint8 r = uint8(h % 100);
        if (r < 55) return 1;       // Common 55%
        else if (r < 80) return 2; // Uncommon 25%
        else if (r < 93) return 3; // Rare 13%
        else if (r < 99) return 4; // Epic 6%
        return 5;                  // Legendary 1%
    }

    /// 任意 token 的等级: 合成卡读链上存储, 原生卡确定性推导
    function tierOf(uint256 id) public view returns (uint8) {
        if (synthTier[id] != 0) return synthTier[id];
        return _deriveTier(id);
    }

    // ============ Coupon 验签 ============
    function _hashCoupon(
        address owner,
        uint8 action,
        uint256 param,
        uint256 cost,
        uint256 nonce,
        uint256 expire,
        uint256 chainId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, action, param, cost, nonce, expire, chainId));
    }

    function _verifyCoupon(
        address owner,
        uint8 action,
        uint256 param,
        uint256 cost,
        uint256 nonce,
        uint256 expire,
        uint256 chainId,
        bytes memory sig
    ) internal view returns (bool) {
        bytes32 digest = ECDSA.toEthSignedMessageHash(
            _hashCoupon(owner, action, param, cost, nonce, expire, chainId)
        );
        return digest.recover(sig) == signer;
    }

    // ============ Mint (凭 coupon, 用户自付 gas) ============
    function mintWithCoupon(
        uint8 action,
        uint256 param,
        uint256 cost,
        uint256 nonce,
        uint256 expire,
        bytes calldata sig
    ) external {
        require(action == 0, "bad action");
        require(block.timestamp <= expire, "expired");
        require(!usedNonce[nonce], "nonce used");
        require(
            _verifyCoupon(msg.sender, action, param, cost, nonce, expire, block.chainid, sig),
            "bad sig"
        );
        require(_totalMinted() + param <= _maxSupply, "sold out");
        usedNonce[nonce] = true;
        uint256 startId = _nextTokenId();
        _safeMint(msg.sender, param);
        for (uint256 i = 0; i < param; i++) {
            emit GenesisMinted(msg.sender, startId + i, _deriveTier(startId + i));
        }
        emit CouponUsed(msg.sender, nonce, action);
    }

    // ============ 合成 (凭 coupon, 用户自付 gas) ============
    function synthesizeWithCoupon(
        uint256[3] calldata burnIds,
        uint8 targetTier,
        uint8 action,
        uint256 cost,
        uint256 nonce,
        uint256 expire,
        bytes calldata sig
    ) external {
        require(action == 1, "bad action");
        require(block.timestamp <= expire, "expired");
        require(!usedNonce[nonce], "nonce used");
        require(
            _verifyCoupon(msg.sender, action, targetTier, cost, nonce, expire, block.chainid, sig),
            "bad sig"
        );
        require(synthActive, "synth not active");
        require(targetTier >= 2 && targetTier <= 5, "bad target tier");
        uint8 sourceTier = targetTier - 1;
        for (uint256 i = 0; i < 3; i++) {
            uint256 id = burnIds[i];
            require(ownerOf(id) == msg.sender, "not owner");
            require(tierOf(id) == sourceTier, "tier mismatch");
        }
        for (uint256 i = 0; i < 3; i++) _burn(burnIds[i]);
        totalBurned += 3;
        uint256 newId = _nextTokenId();
        _safeMint(msg.sender, 1);
        synthTier[newId] = targetTier;
        usedNonce[nonce] = true;
        emit Synthesized(msg.sender, burnIds, newId, targetTier);
        emit CouponUsed(msg.sender, nonce, action);
    }

    // ============ 买分 (用户付 ETH, 后端核验后入账) ============
    function buyPoints() external payable {
        require(msg.value >= pointsPrice, "insufficient");
        emit PointsPurchased(msg.sender, POINTS_PER_BUY);
    }

    // ============ Owner 预留批量 mint ============
    function mintBatch(address to, uint256 amount) external onlyOwner {
        require(_totalMinted() + amount <= _maxSupply, "exceeds supply");
        uint256 startId = _nextTokenId();
        _safeMint(to, amount);
        for (uint256 i = 0; i < amount; i++) {
            emit GenesisMinted(to, startId + i, _deriveTier(startId + i));
        }
    }

    // ============ tokenURI ============
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_exists(tokenId)) revert URIQueryForNonexistentToken();
        string memory baseURI = _baseURI();
        if (bytes(baseURI).length == 0) return "";
        if (synthTier[tokenId] != 0) {
            return string(abi.encodePacked(baseURI, "/synth/", tokenId.toString()));
        }
        return string(abi.encodePacked(baseURI, "/metadata/", tokenId.toString(), ".json"));
    }

    // ============ 查询 (兼容游戏前端) ============
    function nextGenesisId() public view returns (uint256) {
        return _nextTokenId();
    }

    function nextSynthId() public view returns (uint256) {
        return _nextTokenId();
    }

    function isGenesis(uint256 tokenId) public view returns (bool) {
        return synthTier[tokenId] == 0;
    }

    // ============ Owner 管理 ============
    function setMintActive(bool v) external onlyOwner { mintActive = v; }
    function setSynthActive(bool v) external onlyOwner { synthActive = v; }
    function setMintPrice(uint256 p) external onlyOwner { mintPrice = p; }
    function setPointsPrice(uint256 p) external onlyOwner { pointsPrice = p; }
    function setSigner(address s) external onlyOwner { signer = s; }

    function withdraw() external onlyOwner {
        (bool ok, ) = msg.sender.call{value: address(this).balance}("");
        require(ok, "withdraw failed");
    }
}
