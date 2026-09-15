# Neon Mech Legion — one-pager

**A free, fully playable on-chain mech game on Robinhood Chain (4663).**
Mint a mech, deploy it in a tower run, fuse three into one of the next tier.
No token, no presale, no paid entry point.

*Arbitrum Open House — Singapore Online Buildathon · Sep 14 → Oct 4, 2026 · Robinhood Chain track*

---

## The problem it solves

Robinhood Chain today is a strong trading and RWA environment. It has almost no
**consumer surface** — nothing a new wallet can *do* after it closes a position.
A free game is not competing with launch volume; it is what keeps a wallet
connected for another ten minutes and gives the chain a "you can build anything
here" story that is easy to demonstrate.

## What actually exists today

Not a mockup, not a three-week MVP.

| | |
|---|---|
| Live game | https://neonmechlegion.xyz |
| Collection | https://opensea.io/collection/neonmechlegion |
| Contract | [`0xD9Ce80724456751d755a6B890714E3a2f2c002C5`](https://robinhoodchain.blockscout.com/address/0xD9Ce80724456751d755a6B890714E3a2f2c002C5) |
| Source verified | Sourcify `match` — recompiled runtime is byte-identical to the deployed runtime (21,126 bytes), match ID `50845493` |
| Test suite | `forge test` — 43 tests, 43 passing, 0 failing |
| Source / deployment parity | byte-for-byte; see the repo README |

### Live on-chain state, 2026-09-14

Every figure below is readable by anyone with `cast` or a browser tab. Nothing
here is a projection.

| Metric | Value | How to check |
|---|---|---|
| Units minted (`_totalMinted()`) | **5,659** | `nextGenesisId() - 1`, or count mint logs |
| Units alive (`totalSupply()`) | **5,447** | `totalSupply()` |
| Units destroyed | **212** | count `Transfer(→ 0x0)` logs |
| — of which fusions | 171 (57 fusions × 3) | `totalBurned()` |
| — of which self-burns | 41 | derived; `totalBurned` does **not** count these |
| Supply cap | 10,000 | `MAX_GENESIS()` |
| Paid entry point | **disabled on-chain** | `pointsPrice()` returns `2^256 - 1` |

> The 41 self-burns are real user behaviour: holders chose to destroy their own
> unit via the inherited `burn(uint256)`. We report it because it is in the data,
> not because it flatters us.

## What is on-chain, and what is not

We would rather a judge know this from us than find it.

| On-chain | Off-chain |
|---|---|
| Ownership, transfers, royalties (ERC-721 via SeaDrop) | The game client (tower runs, battle animation) |
| Deterministic rarity derivation (zero storage, no oracle) | The **score / reward ledger** — a database number |
| Coupon-gated mint and 3→1 fusion | Coupon signing service (EIP-191) |
| Supply accounting, burns | Seasonal leaderboards |

The reward is an **in-game score**. It is not a token, not transferable, not
sold, and carries no redemption or investment right. In the UI it is labelled
"Season NML Rewards" — "NML" there is a product name and the collection's
ERC-721 symbol, not a ticker, because there is no token.

## Honest note on a legacy entry point

The contract is immutable and was deployed from an early iteration that included
a **paid entry point for score** (`buyPoints()`). We did not leave that as a
footnote:

1. the purchase path was removed from the application layer;
2. the owner then **permanently disabled it on-chain** —
   `setPointsPrice(type(uint256).max)`
   ([tx](https://robinhoodchain.blockscout.com/tx/0x4f50732c0ffc810728129e0b1bc9e5f9b05f0ebee87915798fea49daf70d401d)),
   so `require(msg.value >= pointsPrice)` can never be satisfied;
3. the test suite pins that disabled state, so it cannot silently regress.

The score is now **earned only** — tower runs, daily check-in, fusion, events.
A future deployment will omit the function entirely rather than carry dead code.

## Already shipped with this submission

**A 78-second demo video, served from the project's own domain — no third-party host:**
<https://www.neonmechlegion.xyz/media/nml-demo.mp4>

It walks the real flows on the deployed game — mint, 3-into-1 fusion, tower run,
score duel, scrapyard — and ends on the on-chain verification card: contract
address, chain ID, Sourcify `match`, and the `forge test` result.

**Index latency, measured on the production server:**

| | Before | Now |
|---|---|---|
| Cold card read | ~30 s | **under 0.2 s** |
| Worst-case path | 18.02 s | 0.99 s |
| Full index rebuild | 71.5 s | 14.9 s |

Robinhood Chain produces a block every 100 ms. That breaks conventional event-log
indexing — 30 days is 25.5 million blocks — and we found the public RPC returning
silently empty `eth_getLogs` results under load, which can wipe an index without
raising an error. The live index is therefore built on batched `eth_call` probes,
which either return a real owner or revert, so they cannot fail silently. The
verification step writes the observed owner back into the index, so a transfer is
picked up by the next reader instead of triggering a full rescan.

## What we will build during the buildathon

In priority order, and we will report progress either way:

1. **A social surface the project currently lacks.** There is no community
   channel today. Stand up Telegram/Discord, link it site-wide, and fill the
   collection's `discord_url` / `telegram_url` fields on OpenSea.
2. **Convert holders into players.** Thousands of wallets hold a mech; a small
   fraction have played. The remaining supply is the only real ammunition we
   have, and it goes to people who actually play — not to another free giveaway.

## Why this fits Robinhood Chain

Built on 4663 from the first commit — this is not a port made to qualify. Free
to mint, gas-only, no paid entry, no token: the funding model is a grant and
ecosystem support, not a sale.

## Links

- Live game — https://neonmechlegion.xyz
- X — https://x.com/NeonMechLegion
- Collection — https://opensea.io/collection/neonmechlegion
- Contracts — this repository
