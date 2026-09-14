# Neon Mech Legion — Smart Contracts

On-chain mech collection and merge-synthesis game, deployed on **Robinhood Chain**
(an Arbitrum Orbit L2, chain ID `4663`).

| | |
|---|---|
| **Live game** | https://neonmechlegion.xyz |
| **Collection** | https://opensea.io/collection/neonmechlegion |
| **Contract** | [`0xD9Ce80724456751d755a6B890714E3a2f2c002C5`](https://robinhoodchain.blockscout.com/address/0xD9Ce80724456751d755a6B890714E3a2f2c002C5) |
| **Explorer** | https://robinhoodchain.blockscout.com |

---

## Deployment

| | |
|---|---|
| Network | Robinhood Chain (Arbitrum Orbit L2) |
| Chain ID | `4663` |
| Contract address | `0xD9Ce80724456751d755a6B890714E3a2f2c002C5` |
| Deployment transaction | [`0x0e90800b2d828ffa7f7d3c958d5117a3cd134b4a4feba6ab9ed005866416feea`](https://robinhoodchain.blockscout.com/tx/0x0e90800b2d828ffa7f7d3c958d5117a3cd134b4a4feba6ab9ed005866416feea) |
| Compiler | solc `0.8.17` |
| Optimizer | enabled, `runs = 200`, `via_ir = false` |
| Runtime bytecode | 21,126 bytes |
| Embedded source hash | [`QmPZQj1dtud6yHfsNCLPtutjp4UEDJJYifM6cpSRDHL77h`](https://ipfs.io/ipfs/QmPZQj1dtud6yHfsNCLPtutjp4UEDJJYifM6cpSRDHL77h) — solc CBOR metadata block, starting at byte 21073 of the runtime |

Constructor arguments as deployed:

| # | Parameter | Value |
|---|---|---|
| 1 | `_baseURI` | `https://neonmechlegion.xyz/meta` |
| 2 | `_pointsPrice` | `800000000000000` |
| 3 | `_signer` | `0xdF8Ff96A9264308805e4f89c21f505Ec7Eb1F1A2` |
| 4 | `allowedSeaDrop` | `[0x00005EA00Ac477B1030CE78506496e8C2dE24bf5]` |

These are the values passed at construction time. One of them has since been
changed on-chain by the owner — see
[Known legacy](#known-legacy-the-disabled-buypoints-entry-point).

The ABI-encoded constructor arguments are in
[`script/constructor-args.txt`](script/constructor-args.txt), ready to paste into a
block explorer verification form.

> **Source/deployment parity.** The source in `src/` is compiled with the settings
> above and its runtime bytecode matches the contract deployed at the address
> above **byte for byte** (21,126 bytes, including the trailing solc metadata
> block). Because Solidity embeds a hash of the sources into that metadata,
> the source is intentionally left untouched — editing even a comment would
> change the metadata and break verification.

---

## Overview

Neon Mech Legion is a collection of 10,000 genesis mech units. Owners can merge
mechs to synthesize higher-tier units, and the resulting units are strictly
scarce: synthesis burns three units to create one.

Gameplay (tower runs, daily check-in, synthesis, events) awards an **off-chain
in-game score** that is used for matchmaking and seasonal leaderboards. The
score is not a token, is not transferable, and is not sold — see
[Known legacy](#known-legacy-the-disabled-buypoints-entry-point).

---

## Contract architecture

`NeonMechLegionV3` inherits from ProjectOpenSea's `ERC721SeaDrop`:

```
NeonMechLegionV3
└── ERC721SeaDrop                    (lib/seadrop/src/ERC721SeaDrop.sol)
    ├── ERC721ContractMetadata       (supply cap, base URI, contract metadata URI)
    ├── ERC721AConduitPreapproved    (OpenSea conduit pre-approval)
    └── ERC721A                      (gas-efficient batch minting, sequential IDs)
```

Design consequences:

- **SeaDrop-compatible.** Native OpenSea minting works through the canonical
  SeaDrop contract (`0x00005EA0...bf5`) via `mintSeaDrop`, with no custom
  marketplace integration.
- **Single ID sequence.** Game-side minting and SeaDrop minting share one
  ERC721A counter. The previous iteration maintained two independent counters,
  which could diverge; that class of bug is structurally removed here.
- **Synthesis is tracked by state, not by ID range.** A synthesized unit is
  flagged in `synthTier[id]`. Genesis units are not — their tier is derived
  deterministically from the token ID. Synthesis can therefore happen at any
  time rather than only after the genesis supply is exhausted.
- **No proxy, no upgradeability, no delegate calls.** The contract is immutable.
  Administrative actions are limited to explicit `onlyOwner` setters.

### Files

| Path | Purpose |
|---|---|
| `src/NeonMechLegionV3.sol` | The entire contract (237 lines) |
| `script/DeployV3.s.sol` | Foundry deployment script |
| `script/constructor-args.txt` | ABI-encoded constructor arguments |
| `broadcast/` | Recorded deployment transactions (no private keys) |
| `lib/seadrop` | Pinned SeaDrop dependency (git submodule) |

---

## Game flows

### 1. Coupon-gated minting

Minting is gated by an EIP-191 signature issued by the project's backend signer.
The user submits the signed coupon and **pays only gas** — no ETH is collected by
the contract for minting.

```solidity
mintWithCoupon(uint8 action, uint256 param, uint256 cost,
               uint256 nonce, uint256 expire, bytes sig)
```

The signed digest is:

```
keccak256(abi.encodePacked(owner, action, param, cost, nonce, expire, chainId))
```

hashed again with `ECDSA.toEthSignedMessageHash`, then recovered and compared
against `signer`. Constraints:

- `action` must equal `0` (`mint`) for this entry point;
- `block.timestamp <= expire`;
- `nonce` is single-use (`usedNonce[nonce]`), preventing replay;
- `chainId` is bound into the digest, so a coupon signed for one chain cannot
  be replayed on another;
- `_totalMinted() + param <= _maxSupply`.

### 2. Synthesis (merge)

```solidity
synthesizeWithCoupon(uint256[3] burnIds, uint8 targetTier, uint8 action,
                     uint256 cost, uint256 nonce, uint256 expire, bytes sig)
```

Three units of tier `N` are burned to mint one unit of tier `N + 1`. Note that
the signed `param` field carries **`targetTier`** for this entry point (a
deliberate quirk preserved for backend compatibility). Constraints:

- `action` must equal `1` (`synth`);
- `synthActive` must be `true`;
- `targetTier ∈ [2, 5]`, and all three burned units must be owned by the caller
  and be exactly tier `targetTier - 1`;
- the fresh unit's tier is written to `synthTier[newId]`.

Net supply never increases: `totalBurned` increases by 3 while one unit is
minted, so the 10,000 cap holds.

### 3. Rarity model

Genesis rarity is derived deterministically — **zero storage, no randomness
oracle, and verifiable by anyone**:

```solidity
h = uint256(keccak256(abi.encodePacked(id, TIER_SEED)));   // TIER_SEED = 0x4e6d6c2024
r = uint8(h % 100);
```

| `r` | Tier | Name | Share |
|---|---|---|---|
| `0 – 54` | 1 | Common | 55% |
| `55 – 79` | 2 | Uncommon | 25% |
| `80 – 92` | 3 | Rare | 13% |
| `93 – 98` | 4 | Epic | 6% |
| `99` | 5 | Legendary | 1% |

`tierOf(id)` returns the stored tier for synthesized units and the derived tier
for genesis units.

### 4. Metadata

```
genesis:  {baseURI}/metadata/{id}.json
synth:    {baseURI}/synth/{id}
```

`tokenURI` reverts with `URIQueryForNonexistentToken` for unminted IDs.

---

## Public interface

| Function | Access | Notes |
|---|---|---|
| `mintWithCoupon` | anyone with a valid coupon | user pays gas only |
| `synthesizeWithCoupon` | anyone with a valid coupon | requires `synthActive` |
| `tierOf` / `isGenesis` / `nextGenesisId` / `nextSynthId` | view | game-frontend helpers |
| `MAX_GENESIS` / `totalBurned` / `totalSupply` | view | supply accounting |
| `mintBatch` | `onlyOwner` | migration / airdrop helper |
| `setMintActive` / `setSynthActive` | `onlyOwner` | pause switches |
| `setSigner` | `onlyOwner` | rotate the coupon signer |
| `setMintPrice` / `setPointsPrice` | `onlyOwner` | legacy compatibility setter, see below |
| `withdraw` | `onlyOwner` | sweeps any residual balance |

---

## Build

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).
The SeaDrop dependency is a git submodule, so clone recursively:

```bash
git clone --recursive https://github.com/evemiranda861-png/neon-mech-legion.git
cd <your-repo>

forge build
```

To reproduce the deployed artifact exactly:

```bash
forge build --force
# out/NeonMechLegionV3.sol/NeonMechLegionV3.json
```

Dry-run the deployment script against Robinhood Chain (no transaction sent):

```bash
forge script script/DeployV3.s.sol:DeployV3 --rpc-url https://rpc.mainnet.chain.robinhood.com
```

> **Note on tests.** This repository contains the contract source and the
> deployment script. It does not yet ship a Foundry test suite for the
> coupon and synthesis paths; those are covered by on-chain integration testing
> against the live deployment. A test suite is on the roadmap.

---

## Verification status

| Service | Result |
|---|---|
| [Sourcify](https://sourcify.dev/#/lookup/0xD9Ce80724456751d755a6B890714E3a2f2c002C5) | **`match`** — recompiled runtime bytecode is byte-identical to the deployed runtime (verified 2026-09-14, match ID `50845493`) |
| Blockscout (Robinhood Chain) | Pending. The explorer's verifier API sits behind a bot challenge, so it cannot be driven from CI. The source in this repository is ready to paste into the explorer's verification form using `script/constructor-args.txt`. |

Sourcify performs an independent recompilation and compares the output to the
on-chain bytecode, so the `match` above is third-party confirmation that this
source is what is running at the deployed address.

### Reproducing verification locally

```bash
forge build --force

forge verify-contract \
  --chain 4663 \
  --verifier sourcify \
  --constructor-args script/constructor-args.txt \
  0xD9Ce80724456751d755a6B890714E3a2f2c002C5 \
  src/NeonMechLegionV3.sol:NeonMechLegionV3
```

To verify on Blockscout instead, use the explorer's web form with:

| Field | Value |
|---|---|
| Compiler | `v0.8.17+commit.8df45f5f` |
| Optimization | `Yes`, runs `200` |
| EVM version | `london` (Foundry default for solc 0.8.17) |
| Constructor arguments | contents of `script/constructor-args.txt` |

---

## Security notes

- **Coupon signer.** `signer` is the backend key that authorizes every mint and
  synthesis. Whoever holds it controls issuance. It is rotatable by the owner
  via `setSigner`, and it is not the owner key.
- **Replay protection.** Nonces are single-use and scoped per address, and the
  chain ID is part of the signed digest.
- **Owner powers are bounded and enumerable.** `mintBatch` (capped by
  `_maxSupply`), the `set*` switches, and `withdraw` are the complete list. There
  is no mint-to-self bypass, no hidden fee, and no path for the owner to move
  user tokens.
- **No external calls** other than ERC721A transfers, so there is no reentrancy
  surface introduced by this contract.
- **Frozen supply cap.** `_maxSupply` is set to `MAX_GENESIS` (10,000) in the
  constructor and is not adjustable by any setter.

---

## Known legacy: the disabled `buyPoints` entry point

This contract is immutable and was deployed from an early iteration of the
design. That iteration included a **paid entry point for in-game score**, and
the code for it is still present in the deployed bytecode:

- `buyPoints()` — payable function
- `pointsPrice` / `POINTS_PER_BUY` — price parameters
- `PointsPurchased` — event
- `setPointsPrice()` — owner setter

**Current state — how it was handled:**

1. The purchase path was **removed from the application layer** (the game
   frontend no longer exposes it, and the backend rejects requests for it).
2. It was then **permanently disabled on-chain** by the owner calling
   `setPointsPrice(type(uint256).max)`:

   | | |
   |---|---|
   | Transaction | [`0x4f50732c0ffc810728129e0b1bc9e5f9b05f0ebee87915798fea49daf70d401d`](https://robinhoodchain.blockscout.com/tx/0x4f50732c0ffc810728129e0b1bc9e5f9b05f0ebee87915798fea49daf70d401d) |
   | Effect | `pointsPrice()` returns `2^256 - 1` |

   The guard `require(msg.value >= pointsPrice)` can therefore never be
   satisfied, so any call to `buyPoints()` reverts. Holding `2^256 - 1` wei of
   ETH is impossible, which makes the function **dead code in practice**.

3. The in-game score is now **earned only** — through tower runs, daily
   check-in, synthesis activity, and events. It cannot be bought.

The functions remain in the bytecode because the contract cannot be modified
after deployment. They are inert, and a future version of the contract will omit
them entirely rather than carry a permanently disabled entry point.

---

## Repository layout

```
.
├── src/
│   └── NeonMechLegionV3.sol      # the contract
├── script/
│   ├── DeployV3.s.sol            # deployment script
│   └── constructor-args.txt      # ABI-encoded constructor arguments
├── broadcast/
│   └── DeployV3.s.sol/4663/      # recorded deployment transactions
├── lib/
│   └── seadrop/                  # git submodule (ProjectOpenSea/seadrop)
├── foundry.toml
├── foundry.lock
├── .gitattributes                # forces LF: solc hashes sources into the metadata
├── .gitignore
├── README.md
└── LICENSE
```

---

## License

MIT — see [LICENSE](LICENSE).
