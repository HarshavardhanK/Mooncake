# Phase 1 — Φkv measurements

**What this is:** the raw Φkv table that feeds the Phase 2 analytical model
(paper Eq 3-8). One row per (model, input_len) cell, measured on g126 with
SGLang v0.5.9-cu129-amd64 in single-replica, single-concurrency mode with
`--disable-radix-cache --max-running-requests 1` (paper-faithful, see
[`PHASE1_PHIKV_PLAN.md`](../../../docs/10-paper/PHASE1_PHIKV_PLAN.md) §4).

**Hardware:** 8× NVIDIA H100 80 GB SXM5 on `g126`.
**Engine:** SGLang `v0.5.9-cu129-amd64`.
**Time window:** 2026-04-20 21:53 → 22:32 UTC.

Per-model raw JSONL is in this directory:
- [`kimi-linear-48b.jsonl`](kimi-linear-48b.jsonl) — H1
- [`nemotron-nano-9b-v2.jsonl`](nemotron-nano-9b-v2.jsonl) — H2
- [`qwen2.5-72b-instruct.jsonl`](qwen2.5-72b-instruct.jsonl) — D1

Sibling `*.sglang.log` files are the unmodified server logs from each run.

---

## H1 — `moonshotai/Kimi-Linear-48B-A3B-Instruct` (TP=8)

48 B total params (~3 B active, MoE 256-experts), 27 hidden layers in a
21-KDA + 7-MLA hybrid layout (`linear_attn_config.full_attn_layers =
[4,8,12,16,20,24,27]` 1-indexed). MLA per-layer KV bytes = `(kv_lora_rank +
qk_rope_head_dim) × bpe = (512 + 64) × 2 = 1152`. Total `kv_per_token_bytes
= 7 × 1152 = 8064`.

| input_len | Skv (bytes) | Tprefill p25 (ms) | p50 | p75 | Φkv (Gbps) |
|---:|---:|---:|---:|---:|---:|
| 1,024   | 8,257,536    | 64.0  | 64.0  | 64.0  | 1.03 |
| 2,048   | 16,515,072   | 69.4  | 69.5  | 69.5  | 1.90 |
| 4,096   | 33,030,144   | 73.3  | 73.6  | 73.7  | 3.59 |
| 8,192   | 66,060,288   | 91.6  | 94.0  | 94.7  | 5.62 |
| 16,384  | 132,120,576  | 181.2 | 182.0 | 182.6 | 5.81 |
| 32,768  | 264,241,152  | 363.0 | 363.4 | 364.5 | 5.82 |
| 65,536  | 528,482,304  | 745.8 | 748.1 | 752.8 | 5.65 |
| 131,072 | 1,056,964,608| 1601.4| 1610.3| 1623.5| 5.25 |

**Shape:** Φkv ramps quickly through small `l` because Tprefill is dominated
by per-request fixed overhead, then plateaus around **5.7–5.8 Gbps for `l ∈
[16 K, 65 K]`**, slipping to 5.25 Gbps at 131 K as MLA's `O(l²)` attention
on the 7 full-attention layers starts to bite. KV size is tiny: even at
131 K it's only **1.06 GB total** (single replica).

## H2 — `nvidia/NVIDIA-Nemotron-Nano-9B-v2` (TP=4)

9 B params, 56 layers in a `hybrid_override_pattern`-defined layout: 4
attention layers + 52 Mamba2 layers (8 KV heads, 128 head_dim → 4 × 2 × 8 ×
128 × 2 = 16,384 bytes/token total). `max_position_embeddings = 131,072`.

| input_len | Skv (bytes) | Tprefill p25 (ms) | p50 | p75 | Φkv (Gbps) |
|---:|---:|---:|---:|---:|---:|
| 1,024   | 16,777,216    | 43.6  | 43.6  | 43.7  | 3.08 |
| 2,048   | 33,554,432    | 45.4  | 45.7  | 46.0  | 5.87 |
| 4,096   | 67,108,864    | 76.4  | 76.5  | 76.7  | 7.02 |
| 8,192   | 134,217,728   | 181.2 | 181.7 | 182.5 | 5.91 |
| 16,384  | 268,435,456   | 336.4 | 336.6 | 337.2 | 6.38 |
| 32,768  | 536,870,912   | 652.6 | 653.4 | 654.7 | 6.57 |
| 65,536  | 1,073,741,824 | 1308.3| 1309.1| 1310.5| 6.56 |
| 131,072 | 2,147,483,648 | —     | —     | —     | err (HTTP 400 from SGLang at exact `max_position_embeddings`; later runs skip via `safe_max = declared_max - output_len - 128`). |

**Shape:** plateau ≈ **6.5 Gbps for `l ≥ 16 K`**. Slightly higher Φkv than
Kimi because each attention layer carries 2× the bytes/token Kimi does
(16 KB vs 8 KB), so the wider per-token KV is shipped against a comparable
attention-budget Tprefill. The 131 K cell is a probe-script issue that's
been fixed in `phi_kv_probe.py` (`safe_max` skip), not a model issue;
re-running would yield ~6.4 Gbps based on the trend.

## D1 — `Qwen/Qwen2.5-72B-Instruct` (TP=8)

72 B dense, GQA-8, `head_dim=128`, 80 attention layers ⇒
`kv_per_token_bytes = 80 × 2 × 8 × 128 × 2 = 327,680`
(about **40× per-token** what Kimi-Linear costs). `max_position_embeddings
= 32,768`; longer contexts require YaRN extension, which we deliberately
do not enable so the published number remains directly comparable to
the paper's "stock dense" measurements.

| input_len | Skv (bytes) | Tprefill p25 (ms) | p50 | p75 | Φkv (Gbps) |
|---:|---:|---:|---:|---:|---:|
| 1,024   | 335,544,320    | 64.7  | 64.7  | 64.7  | 41.49 |
| 2,048   | 671,088,640    | 107.4 | 107.5 | 107.5 | 49.96 |
| 4,096   | 1,342,177,280  | 190.9 | 190.9 | 190.9 | 56.25 |
| 8,192   | 2,684,354,560  | 380.5 | 380.6 | 380.7 | 56.42 |
| 16,384  | 5,368,709,120  | 798.1 | 798.3 | 798.5 | 53.80 |
| 32,768  | 10,737,418,240 | —     | —     | —     | (skipped: > `safe_max=32639`) |
| 65,536  | 21,474,836,480 | —     | —     | —     | (skipped) |
| 131,072 | 42,949,672,560 | —     | —     | —     | (skipped) |

**Shape:** Φkv **plateau ≈ 54–56 Gbps** for `l ∈ [4 K, 16 K]`, ~10× higher
than the hybrids. KV size at 16 K is already **5 GB per request**. To
extend the dense control to 32 K+ we'd need YaRN; that's queued as a
follow-up but the paper's headline conclusion only needs the
hybrid-vs-dense ratio in the [4 K, 16 K] band.

---

## Hybrid vs dense — the headline ratio

This is the qualitative claim the PrfaaS paper's bandwidth-feasibility
argument depends on, replicated on our hardware.

| input_len | Φkv Kimi (Gbps) | Φkv Nemotron (Gbps) | Φkv Qwen2.5-72B (Gbps) | dense / Kimi | dense / Nemotron |
|---:|---:|---:|---:|---:|---:|
|  4,096 |  3.59 |  7.02 | 56.25 | **15.7×** | 8.0× |
|  8,192 |  5.62 |  5.91 | 56.42 | **10.0×** | 9.5× |
| 16,384 |  5.81 |  6.38 | 53.80 |  **9.3×** | 8.4× |

The dense control produces KV bytes between **9× and 16× faster** than the
hybrids in the band where all three coexist. PrfaaS's central claim is
that this is the asymmetry that makes hybrids feasible to disaggregate
across a commodity datacenter wire (~10–25 Gbps) and dense models not.

## Wire-feasibility cross-check (preview of Phase 2)

Using our Stage 0 / `m1.0-network-baseline` measured WAN of **14.7 Gbps**
between cluster X and cluster Y, here's whether each (model, l) is even
*allowed* on the wire under the paper's bandwidth-feasibility predicate
`Φkv(l) ≤ B_w` per replica (paper Eq 6 reduced):

| input_len | Kimi-Linear-48B | Nemotron-Nano-9B-v2 | Qwen2.5-72B |
|---:|:---:|:---:|:---:|
|  4,096 | feasible (3.59 ≪ 14.7) | feasible (7.02 < 14.7) | **infeasible** (56.25 ≫ 14.7) |
|  8,192 | feasible (5.62 < 14.7) | feasible (5.91 < 14.7) | **infeasible** (56.42 ≫ 14.7) |
| 16,384 | feasible (5.81 < 14.7) | feasible (6.38 < 14.7) | **infeasible** (53.80 ≫ 14.7) |
| 32,768 | feasible (5.82 < 14.7) | feasible (6.57 < 14.7) | n/a (model max) |
| 65,536 | feasible (5.65 < 14.7) | feasible (6.56 < 14.7) | n/a |
|131,072 | feasible (5.25 < 14.7) | n/a (probe limit) | n/a |

Both hybrids stay **2.2–4× under** our wire across the entire paper-relevant
context range; the dense control is **4× over** the wire even at its
shortest cell. This is exactly the gap the paper says PD-disaggregation
exploits, and it's why Phase 3 will run the empirical Mooncake disagg path
on Kimi-Linear-48B specifically — it's the model with the most paper-
proximate architecture (3:1 hybrid) and the largest wire-headroom (≥ 2.5×)
in the band where the paper does its case study.

## Caveats and follow-ups

1. **Qwen2.5-72B above 32 K** needs YaRN to extend `max_position_embeddings`.
   Phase 1 deliberately did not enable it because the paper's dense
   numbers are also stock; we'd need to be careful that a YaRN'd dense
   has the same Φkv shape (Tprefill grows quadratically with context, KV
   bytes linearly, so Φkv should *rise* — that's a Phase 2.5 cell).
2. **Nemotron at 131 K** errored because the request length equalled
   `max_position_embeddings` exactly; the SGLang server replied 400 before
   the warmup count completed. The probe now skips any `l > declared_max
   - output_len - 128`. A re-run with `l = 130 K` will close that cell.
3. **MoE warmup variance.** Kimi-Linear's MoE layers route 8 experts/token;
   the first 5 warmup requests appear to be enough to stabilise the
   per-l Tprefill (P75 / P25 ratio < 1.02 for `l ≥ 8 K`), but this is
   worth validating with a 50-warmup run if Phase 2 finds the analytical
   model is sensitive.
4. **Engine version.** Paper used SGLang's HEAD at submission time; we
   pinned `v0.5.9-cu129-amd64`. The CHANGELOG between submission tag and
   v0.5.9 is mostly perf and bug-fix work, so we expect this to bias Φkv
   slightly upward versus the paper (better attention kernels), not
   downward.

These do not change the qualitative result — both hybrids fit the wire
at every measured `l`, the dense doesn't fit at any.
