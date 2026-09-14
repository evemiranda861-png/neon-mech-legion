// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { NeonMechLegionV3 } from "../src/NeonMechLegionV3.sol";

/**
 * @title  NeonMechLegionV3 测试套件
 * @notice 覆盖 src/NeonMechLegionV3.sol 的全部外部行为。
 *
 * 重要约束：本文件是**纯新增**，未修改 src/ 下任何一行合约源码。
 *         已部署合约的源码字节码必须与链上保持一致（Sourcify 已验证），
 *         因此测试只能在外围新增，不能改动合约本体。
 *
 * 覆盖范围：
 *   A 初始化与 SeaDrop 兼容层
 *   B 稀有度确定性推导
 *   C coupon 铸造（成功路径 + 8 条失败路径，含签名不可盗用）
 *   D owner 批量铸造与权限
 *   E 3 合 1 熔炼（含连续熔炼链条与净减供应）
 *   F buyPoints（含链上已停用状态的回归验证）
 *   G tokenURI
 *   H owner 管理函数与提现
 *   I 前端兼容视图
 */
contract NeonMechLegionV3Test is Test {
    // ============ 常量 ============
    uint256 internal constant MAX_SUPPLY = 10000;
    uint256 internal constant SIGNER_PK = 0xA11CE;
    uint256 internal constant POINTS_PRICE = 0.0008 ether;
    uint8 internal constant ACTION_MINT = 0;
    uint8 internal constant ACTION_SYNTH = 1;

    NeonMechLegionV3 internal nml;
    address internal signer;
    address internal alice = address(0xBEEF);
    address internal bob = address(0xCAFE);

    string internal constant BASE = "https://neonmechlegion.xyz/api/token";

    // ============ 事件（与合约定义一致，用于 expectEmit） ============
    event GenesisMinted(address indexed to, uint256 tokenId, uint8 tier);
    event Synthesized(address indexed owner, uint256[3] burnedIds, uint256 newId, uint8 newTier);
    event PointsPurchased(address indexed buyer, uint256 amount);
    event CouponUsed(address indexed owner, uint256 indexed nonce, uint8 action);

    function setUp() public {
        signer = vm.addr(SIGNER_PK);
        address[] memory allowed = new address[](1);
        allowed[0] = address(0x00005EA00Ac477B1030CE78506496e8C2dE24bf5); // SeaDrop (uint->address, 不做 checksum 校验)
        nml = new NeonMechLegionV3(BASE, POINTS_PRICE, signer, allowed);
        // 让测试合约自己有余额，便于 with pay 类测试
        vm.deal(address(this), 100 ether);
    }

    /// @dev 测试合约同时扮演 owner 与持有者，需要能接收 NFT 与 ETH
    ///      （ERC721A._safeMint 对合约地址会调用 onERC721Received；withdraw 会转 ETH 回来）
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02; // IERC721Receiver.onERC721Received.selector
    }

    receive() external payable {}

    // ================================================================
    // helpers
    // ================================================================

    /// @dev 复刻合约内 _hashCoupon + ECDSA.toEthSignedMessageHash
    function _digest(
        address owner_,
        uint8 action,
        uint256 param,
        uint256 cost,
        uint256 nonce,
        uint256 expire,
        uint256 chainId
    ) internal pure returns (bytes32) {
        bytes32 h = keccak256(abi.encodePacked(owner_, action, param, cost, nonce, expire, chainId));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h));
    }

    function _signWith(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev 用正确的 signer 私钥签，绑定当前 chainId
    function _sign(
        address owner_,
        uint8 action,
        uint256 param,
        uint256 cost,
        uint256 nonce,
        uint256 expire
    ) internal view returns (bytes memory) {
        return _signWith(SIGNER_PK, _digest(owner_, action, param, cost, nonce, expire, block.chainid));
    }

    /// @dev 铸造一个 mint coupon
    function _mintCoupon(address owner_, uint256 qty, uint256 nonce)
        internal
        view
        returns (uint256 expire, bytes memory sig)
    {
        expire = block.timestamp + 1 hours;
        sig = _sign(owner_, ACTION_MINT, qty, 0, nonce, expire);
    }

    /// @dev 在已存在的 token 中找出 count 个指定等级的 id
    function _findIdsOfTier(uint8 tier, uint256 count) internal view returns (uint256[] memory out) {
        out = new uint256[](count);
        uint256 found;
        uint256 total = nml.totalSupply();
        for (uint256 id = 1; id <= total && found < count; id++) {
            if (nml.tierOf(id) == tier) {
                out[found] = id;
                found++;
            }
        }
        require(found == count, "fixture: not enough tokens of that tier");
    }

    // ================================================================
    // A. 初始化
    // ================================================================

    function test_A1_InitialState() public view {
        assertEq(nml.name(), "Neon Mech Legion");
        assertEq(nml.symbol(), "NML");
        assertEq(nml.nextGenesisId(), 1, "ERC721A id must start at 1");
        assertEq(nml.nextSynthId(), 1, "genesis/synth share one id sequence");
        assertEq(nml.totalBurned(), 0);
        assertEq(nml.signer(), signer);
        assertEq(nml.pointsPrice(), POINTS_PRICE);
        assertEq(nml.totalSupply(), 0);
        // 构造函数未开启 synth
        assertFalse(nml.synthActive(), "synth must start disabled");
        assertTrue(nml.mintActive());
    }

    function test_A2_SeaDropCompat() public view {
        assertEq(nml.maxSupply(), MAX_SUPPLY, "maxSupply must be MAX_GENESIS");
        // ERC2981 / ERC721 / ERC165 接口应可用
        assertTrue(nml.supportsInterface(0x80ac58cd), "ERC721");
        assertTrue(nml.supportsInterface(0x01ffc9a7), "ERC165");
    }

    // ================================================================
    // B. 稀有度推导
    // ================================================================

    function test_B1_DeriveTierDeterministic() public view {
        assertEq(nml.tierOf(1), nml.tierOf(1));
        assertEq(nml.tierOf(9999), nml.tierOf(9999));
    }

    function test_B2_IsGenesisDefaultsTrue() public view {
        // 未铸造的 id，synthTier==0 → isGenesis 为 true
        assertTrue(nml.isGenesis(1));
        assertTrue(nml.isGenesis(9999));
    }

    function testFuzz_B3_TierAlwaysInRange(uint256 id) public view {
        uint8 t = nml.tierOf(id);
        assertGe(t, 1);
        assertLe(t, 5);
    }

    function test_B4_TierDistributionMatchesSpec() public view {
        // 规格: Common55 / Uncommon25 / Rare13 / Epic6 / Legendary1
        uint256[6] memory bins; // index 1..5
        uint256 sample = 3000;
        for (uint256 id = 1; id <= sample; id++) {
            bins[nml.tierOf(id)]++;
        }
        // 宽松容差 ±25% —— 只证明分布没跑偏，不做精确统计断言
        assertGt(bins[1], (sample * 55) / 100 * 75 / 100, "Common too rare");
        assertLt(bins[1], (sample * 55) / 100 * 125 / 100, "Common too common");
        assertGt(bins[2], (sample * 10) / 100, "Uncommon far off");
        assertGt(bins[5], 0, "Legendary must exist in 3000 samples");
        assertLt(bins[5], (sample * 5) / 100, "Legendary too common");
    }

    // ================================================================
    // C. coupon 铸造
    // ================================================================

    function test_C1_MintWithCoupon_Success() public {
        uint256 qty = 3;
        (uint256 expire, bytes memory sig) = _mintCoupon(alice, qty, 1);

        vm.prank(alice);
        nml.mintWithCoupon(ACTION_MINT, qty, 0, 1, expire, sig);

        assertEq(nml.balanceOf(alice), qty);
        assertEq(nml.totalSupply(), qty);
        assertEq(nml.ownerOf(1), alice);
        assertEq(nml.ownerOf(3), alice);
        assertTrue(nml.usedNonce(1));
    }

    function test_C2_MintWithCoupon_EmitsEvents() public {
        uint256 qty = 1;
        (uint256 expire, bytes memory sig) = _mintCoupon(alice, qty, 42);

        vm.expectEmit(true, false, false, true);
        emit GenesisMinted(alice, 1, nml.tierOf(1));
        vm.expectEmit(true, true, false, true);
        emit CouponUsed(alice, 42, ACTION_MINT);

        vm.prank(alice);
        nml.mintWithCoupon(ACTION_MINT, qty, 0, 42, expire, sig);
    }

    function test_C3_RevertBadAction() public {
        uint256 expire = block.timestamp + 1 hours;
        bytes memory sig = _sign(alice, ACTION_SYNTH, 1, 0, 1, expire);
        vm.prank(alice);
        vm.expectRevert(bytes("bad action"));
        nml.mintWithCoupon(ACTION_SYNTH, 1, 0, 1, expire, sig);
    }

    function test_C4_RevertExpired() public {
        uint256 expire = block.timestamp - 1;
        bytes memory sig = _sign(alice, ACTION_MINT, 1, 0, 1, expire);
        vm.prank(alice);
        vm.expectRevert(bytes("expired"));
        nml.mintWithCoupon(ACTION_MINT, 1, 0, 1, expire, sig);
    }

    function test_C5_RevertNonceReuse() public {
        uint256 qty = 1;
        (uint256 expire, bytes memory sig) = _mintCoupon(alice, qty, 7);

        vm.prank(alice);
        nml.mintWithCoupon(ACTION_MINT, qty, 0, 7, expire, sig);

        // 同一个 nonce 再来一次 —— 必须被挡下（防重放）
        vm.prank(alice);
        vm.expectRevert(bytes("nonce used"));
        nml.mintWithCoupon(ACTION_MINT, qty, 0, 7, expire, sig);
    }

    function test_C6_RevertBadSig_WrongKey() public {
        uint256 expire = block.timestamp + 1 hours;
        bytes32 digest = _digest(alice, ACTION_MINT, 1, 0, 1, expire, block.chainid);
        bytes memory sig = _signWith(0xBADBAD, digest); // 非 signer 私钥
        vm.prank(alice);
        vm.expectRevert(bytes("bad sig"));
        nml.mintWithCoupon(ACTION_MINT, 1, 0, 1, expire, sig);
    }

    function test_C7_RevertSigBoundToCaller() public {
        // alice 的 coupon 被 bob 拿去用 —— 必须失败（签名绑定 msg.sender）
        uint256 expire = block.timestamp + 1 hours;
        bytes memory sig = _sign(alice, ACTION_MINT, 1, 0, 5, expire);
        vm.prank(bob);
        vm.expectRevert(bytes("bad sig"));
        nml.mintWithCoupon(ACTION_MINT, 1, 0, 5, expire, sig);
    }

    function test_C8_RevertWrongChainId() public {
        uint256 expire = block.timestamp + 1 hours;
        bytes32 digest = _digest(alice, ACTION_MINT, 1, 0, 1, expire, block.chainid + 1);
        bytes memory sig = _signWith(SIGNER_PK, digest);
        vm.prank(alice);
        vm.expectRevert(bytes("bad sig"));
        nml.mintWithCoupon(ACTION_MINT, 1, 0, 1, expire, sig);
    }

    function test_C9_RevertSoldOut() public {
        uint256 qty = MAX_SUPPLY + 1;
        (uint256 expire, bytes memory sig) = _mintCoupon(alice, qty, 1);
        vm.prank(alice);
        vm.expectRevert(bytes("sold out"));
        nml.mintWithCoupon(ACTION_MINT, qty, 0, 1, expire, sig);
    }

    function test_C10_RevertParamTampered() public {
        // 后端签的是 1 个，前端想改成 5 个 —— 参数被改则签名失效
        uint256 expire = block.timestamp + 1 hours;
        bytes memory sig = _sign(alice, ACTION_MINT, 1, 0, 1, expire);
        vm.prank(alice);
        vm.expectRevert(bytes("bad sig"));
        nml.mintWithCoupon(ACTION_MINT, 5, 0, 1, expire, sig);
    }

    function testFuzz_C11_MintQuantity(uint256 qty) public {
        qty = (qty % 500) + 1; // 1..500
        (uint256 expire, bytes memory sig) = _mintCoupon(alice, qty, 1);
        vm.prank(alice);
        nml.mintWithCoupon(ACTION_MINT, qty, 0, 1, expire, sig);
        assertEq(nml.totalSupply(), qty);
        assertEq(nml.balanceOf(alice), qty);
    }

    // ================================================================
    // D. owner 批量铸造 / 权限
    // ================================================================

    function test_D1_MintBatch_Success() public {
        nml.mintBatch(bob, 10);
        assertEq(nml.balanceOf(bob), 10);
        assertEq(nml.totalSupply(), 10);
        assertEq(nml.nextGenesisId(), 11);
    }

    function test_D2_MintBatch_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        nml.mintBatch(alice, 1);
    }

    function test_D3_MintBatch_RevertExceedsSupply() public {
        vm.expectRevert(bytes("exceeds supply"));
        nml.mintBatch(bob, MAX_SUPPLY + 1);
    }

    function test_D4_GenesisAndSynthShareIdSequence() public {
        nml.mintBatch(bob, 2); // ids 1,2
        assertEq(nml.nextGenesisId(), 3);
        assertEq(nml.nextSynthId(), 3);
    }

    // ================================================================
    // E. 合成 (3 -> 1)
    // ================================================================

    function _activateSynth() internal {
        nml.setSynthActive(true);
        assertTrue(nml.synthActive());
    }

    function test_E1_RevertWhenSynthInactive() public {
        nml.mintBatch(address(this), 100);
        uint256[] memory ids = _findIdsOfTier(1, 3);
        uint256 expire = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(this), ACTION_SYNTH, 2, 0, 1, expire);
        vm.expectRevert(bytes("synth not active"));
        nml.synthesizeWithCoupon([ids[0], ids[1], ids[2]], 2, ACTION_SYNTH, 0, 1, expire, sig);
    }

    function test_E2_Synthesize_Success() public {
        nml.mintBatch(address(this), 300);
        _activateSynth();

        uint256[] memory ids = _findIdsOfTier(1, 3);
        uint256 supplyBefore = nml.totalSupply();
        uint256 burnedBefore = nml.totalBurned();
        uint256 nextId = nml.nextGenesisId();

        uint256 expire = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(this), ACTION_SYNTH, 2, 0, 1, expire);
        nml.synthesizeWithCoupon([ids[0], ids[1], ids[2]], 2, ACTION_SYNTH, 0, 1, expire, sig);

        // 三张源卡被销毁
        assertEq(nml.totalBurned(), burnedBefore + 3);
        // 净供应 -2（烧 3 出 1）
        assertEq(nml.totalSupply(), supplyBefore - 3 + 1);
        // 新卡记录在存储里，等级为 2
        assertEq(nml.tierOf(nextId), 2);
        assertFalse(nml.isGenesis(nextId));
        assertEq(nml.ownerOf(nextId), address(this));
        assertTrue(nml.usedNonce(1));

        // 源卡已不存在
        vm.expectRevert();
        nml.ownerOf(ids[0]);
    }

    function test_E3_RevertTierMismatch() public {
        nml.mintBatch(address(this), 300);
        _activateSynth();

        uint256[] memory c = _findIdsOfTier(1, 2);
        uint256[] memory u = _findIdsOfTier(2, 1); // 混入一张不同等级
        uint256 expire = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(this), ACTION_SYNTH, 2, 0, 1, expire);
        vm.expectRevert(bytes("tier mismatch"));
        nml.synthesizeWithCoupon([c[0], c[1], u[0]], 2, ACTION_SYNTH, 0, 1, expire, sig);
    }

    function test_E4_RevertNotOwner() public {
        nml.mintBatch(alice, 300);
        nml.mintBatch(bob, 300);
        _activateSynth();

        // bob 想烧 alice 的卡
        uint256[] memory ids = new uint256[](3);
        uint256 found;
        for (uint256 id = 1; id <= nml.totalSupply() && found < 3; id++) {
            if (nml.tierOf(id) == 1 && nml.ownerOf(id) == alice) {
                ids[found] = id;
                found++;
            }
        }
        require(found == 3, "fixture");

        uint256 expire = block.timestamp + 1 hours;
        bytes memory sig = _sign(bob, ACTION_SYNTH, 2, 0, 1, expire);
        vm.prank(bob);
        vm.expectRevert(bytes("not owner"));
        nml.synthesizeWithCoupon([ids[0], ids[1], ids[2]], 2, ACTION_SYNTH, 0, 1, expire, sig);
    }

    function test_E5_RevertBadTargetTier() public {
        nml.mintBatch(address(this), 300);
        _activateSynth();
        uint256[] memory ids = _findIdsOfTier(1, 3);
        uint256 expire = block.timestamp + 1 hours;

        // 1) 低于下限
        bytes memory sig1 = _sign(address(this), ACTION_SYNTH, 1, 0, 1, expire);
        vm.expectRevert(bytes("bad target tier"));
        nml.synthesizeWithCoupon([ids[0], ids[1], ids[2]], 1, ACTION_SYNTH, 0, 1, expire, sig1);

        // 2) 高于上限
        bytes memory sig6 = _sign(address(this), ACTION_SYNTH, 6, 0, 2, expire);
        vm.expectRevert(bytes("bad target tier"));
        nml.synthesizeWithCoupon([ids[0], ids[1], ids[2]], 6, ACTION_SYNTH, 0, 2, expire, sig6);
    }

    function test_E6_RevertBadAction() public {
        nml.mintBatch(address(this), 300);
        _activateSynth();
        uint256[] memory ids = _findIdsOfTier(1, 3);
        uint256 expire = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(this), ACTION_MINT, 2, 0, 1, expire);
        vm.expectRevert(bytes("bad action"));
        nml.synthesizeWithCoupon([ids[0], ids[1], ids[2]], 2, ACTION_MINT, 0, 1, expire, sig);
    }

    function test_E7_RevertNonceReuse() public {
        nml.mintBatch(address(this), 300);
        _activateSynth();
        uint256[] memory ids = _findIdsOfTier(1, 6);
        uint256 expire = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(this), ACTION_SYNTH, 2, 0, 1, expire);

        nml.synthesizeWithCoupon([ids[0], ids[1], ids[2]], 2, ACTION_SYNTH, 0, 1, expire, sig);

        vm.expectRevert(bytes("nonce used"));
        nml.synthesizeWithCoupon([ids[3], ids[4], ids[5]], 2, ACTION_SYNTH, 0, 1, expire, sig);
    }

    function test_E8_ChainThreeIntoOne() public {
        // 完整链条: 9 x tier1 -> 3 x tier2 -> 1 x tier3，验证每级净减供应
        nml.mintBatch(address(this), 600);
        _activateSynth();
        uint256 supply0 = nml.totalSupply();

        uint256[] memory t1 = _findIdsOfTier(1, 9);
        uint256 expire = block.timestamp + 1 hours;

        // 3 次 tier1 -> tier2
        for (uint256 k = 0; k < 3; k++) {
            uint256 nonce = 100 + k;
            bytes memory sig = _sign(address(this), ACTION_SYNTH, 2, 0, nonce, expire);
            nml.synthesizeWithCoupon([t1[k * 3], t1[k * 3 + 1], t1[k * 3 + 2]], 2, ACTION_SYNTH, 0, nonce, expire, sig);
        }
        assertEq(nml.totalSupply(), supply0 - 9 + 3, "after 3x fuse");

        uint256[] memory t2 = _findIdsOfTier(2, 3);
        bytes memory sig2 = _sign(address(this), ACTION_SYNTH, 3, 0, 200, expire);
        nml.synthesizeWithCoupon([t2[0], t2[1], t2[2]], 3, ACTION_SYNTH, 0, 200, expire, sig2);

        assertEq(nml.totalSupply(), supply0 - 9 + 3 - 3 + 1, "after final fuse");
        assertEq(nml.totalBurned(), 12);
        assertEq(nml.tierOf(nml.nextGenesisId() - 1), 3);
    }

    // ================================================================
    // F. buyPoints —— 含线上停用状态的回归
    // ================================================================

    function test_F1_BuyPoints_Success() public {
        vm.deal(alice, 1 ether);
        vm.expectEmit(true, false, false, true);
        emit PointsPurchased(alice, 1000);
        vm.prank(alice);
        nml.buyPoints{ value: POINTS_PRICE }();
        assertEq(address(nml).balance, POINTS_PRICE);
    }

    function test_F2_BuyPoints_RevertInsufficient() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("insufficient"));
        nml.buyPoints{ value: POINTS_PRICE - 1 }();
    }

    /// @notice 链上已通过 setPointsPrice(type(uint256).max) 永久停用买分入口。
    ///         本测试锁定该状态：任何金额都必须失败。
    function test_F3_BuyPoints_DisabledByMaxPrice() public {
        nml.setPointsPrice(type(uint256).max);

        vm.deal(alice, 10_000 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("insufficient"));
        nml.buyPoints{ value: 1 ether }();

        // 即使把全世界的钱都打进去也不可能满足 msg.value >= uint256.max
        vm.prank(alice);
        vm.expectRevert(bytes("insufficient"));
        nml.buyPoints{ value: 10_000 ether }();

        assertEq(address(nml).balance, 0);
    }

    function test_F4_BuyPoints_OnlyOwnerCanChangePrice() public {
        vm.prank(alice);
        vm.expectRevert();
        nml.setPointsPrice(1);
    }

    // ================================================================
    // G. tokenURI
    // ================================================================

    function test_G1_TokenURI_Genesis() public {
        nml.mintBatch(alice, 1);
        assertEq(nml.tokenURI(1), string(abi.encodePacked(BASE, "/metadata/1.json")));
    }

    function test_G2_TokenURI_Synth() public {
        nml.mintBatch(address(this), 300);
        _activateSynth();
        uint256[] memory ids = _findIdsOfTier(1, 3);
        uint256 newId = nml.nextGenesisId();
        uint256 expire = block.timestamp + 1 hours;
        bytes memory sig = _sign(address(this), ACTION_SYNTH, 2, 0, 1, expire);
        nml.synthesizeWithCoupon([ids[0], ids[1], ids[2]], 2, ACTION_SYNTH, 0, 1, expire, sig);

        assertEq(nml.tokenURI(newId), string(abi.encodePacked(BASE, "/synth/", _u(newId))));
    }

    function test_G3_TokenURI_RevertNonexistent() public {
        vm.expectRevert();
        nml.tokenURI(999);
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 t = v;
        uint256 d;
        while (t != 0) {
            d++;
            t /= 10;
        }
        bytes memory b = new bytes(d);
        while (v != 0) {
            d--;
            b[d] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return string(b);
    }

    // ================================================================
    // H. owner 管理 / 提现
    // ================================================================

    function test_H1_SetSynthActive_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        nml.setSynthActive(true);
        assertFalse(nml.synthActive());
    }

    function test_H2_SetSigner_TakesEffect() public {
        uint256 newPk = 0xB0B;
        address newSigner = vm.addr(newPk);
        nml.setSigner(newSigner);
        assertEq(nml.signer(), newSigner);

        uint256 expire = block.timestamp + 1 hours;
        // 旧 signer 的签名失效
        bytes memory oldSig = _sign(alice, ACTION_MINT, 1, 0, 1, expire);
        vm.prank(alice);
        vm.expectRevert(bytes("bad sig"));
        nml.mintWithCoupon(ACTION_MINT, 1, 0, 1, expire, oldSig);

        // 新 signer 生效
        bytes memory newSig = _signWith(newPk, _digest(alice, ACTION_MINT, 1, 0, 2, expire, block.chainid));
        vm.prank(alice);
        nml.mintWithCoupon(ACTION_MINT, 1, 0, 2, expire, newSig);
        assertEq(nml.balanceOf(alice), 1);
    }

    function test_H3_SetSigner_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        nml.setSigner(alice);
    }

    function test_H4_SetMintActiveAndPrice_OnlyOwner() public {
        nml.setMintActive(false);
        assertFalse(nml.mintActive());
        nml.setMintPrice(1 ether);
        assertEq(nml.mintPrice(), 1 ether);

        vm.startPrank(alice);
        vm.expectRevert();
        nml.setMintActive(true);
        vm.expectRevert();
        nml.setMintPrice(0);
        vm.stopPrank();
    }

    function test_H5_Withdraw_OnlyOwner() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        nml.buyPoints{ value: POINTS_PRICE }();

        vm.prank(bob);
        vm.expectRevert();
        nml.withdraw();
    }

    function test_H6_Withdraw_Success() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        nml.buyPoints{ value: POINTS_PRICE }();

        uint256 expected = address(nml).balance;
        assertGt(expected, 0);

        nml.withdraw(); // 测试合约即 owner
        assertEq(address(nml).balance, 0);
        assertEq(address(this).balance, 100 ether + expected);
    }

    // ================================================================
    // I. 前端兼容视图
    // ================================================================

    function test_I1_IdsAndGenesisFlags() public {
        nml.mintBatch(alice, 5);
        assertEq(nml.nextGenesisId(), 6);
        assertEq(nml.nextSynthId(), 6);
        for (uint256 id = 1; id <= 5; id++) {
            assertTrue(nml.isGenesis(id));
        }
    }
}
