# Phase 2 — analytical Λ_max model (paper Eq 3-8 regen)

This document is the human-readable spec for the Python in
`prfaas/m1.5-vllm-baseline/scripts/phase2/lambda_max_model.py`. It maps
each equation to the variables we measured in Phase 1, every assumption
we made, and the failure modes we expect to see if Phase 3's empirical
run disagrees.

Reference: §3 of *Prefill-as-a-Service: KVCache of Next-Generation
Models Could Go Cross-Datacenter* (Qin et al., arXiv:2604.15039, 2026).

> **TL;DR.** On our measured 14.7 Gbps inter-DC wire and 30 ms RTT, with
> the Phase 1 Φkv numbers plugged into the paper's bandwidth-feasibility
> + throughput-at-SLO model, **Kimi-Linear-48B-A3B-Instruct** is the
> Phase-3 pick: predicted `Λ_max(P)/Λ_max(H) = 7.94×` at the paper's
> `long_context` (`l = 16 K`), peaking at **16×** at `l = 8 K`. Qwen2.5-72B
> dense is **wire-infeasible** at every measured cell — exactly as the
> paper says for dense controls.

---

## 1. Inputs

### 1.1 Per-(model, l) inputs from Phase 1

For each `(model, input_len = l)` cell we have a JSONL row produced by
`phi_kv_probe.py` with these fields:

| field | symbol | units | source |
|---|---|---|---|
| `skv_bytes_total` | `S_kv(l)` | bytes | computed analytically from `config.json` (KDA layers ⇒ 0 bytes/token, MLA layers ⇒ `(kv_lora_rank + qk_rope_head_dim) × bpe`, etc.) |
| `tprefill_ms.p50` | `T_prefill(l)` | seconds (after /1e3) | measured: 20 timed requests, single-replica, `--max-running-requests 1`, `--disable-radix-cache` |
| `phi_kv_gbps` | `Φkv(l)` | Gbps | `S_kv(l) × 8 / T_prefill(l) / 1e9` |

Cells with `error` or `skipped` are dropped (e.g. Nemotron at `l = 131 K`,
Qwen2.5-72B above `max_position_embeddings`).

### 1.2 Per-system inputs

| symbol | units | meaning | default | source |
|---|---|---|---|---|
| `B_w` | Gbps | single-direction wire goodput | sweep `{1, 2, 5, 10, 14.7, 25, 40, 100}` plus measured 14.7 | Stage 0a operating point |
| `RTT` | seconds | link round-trip time | 0.02975 | Stage 0a `ping` (29.75 ms ± 0.06) |
| `SLO_TTFT` | seconds | TTFT P95 budget | 2.0 | paper §3, `long_context` workload |
| `o` | tokens | output length | 256 | paper-aligned `long_context` |
| `N_p` | replicas | prefill replicas in Config P | 1 | g304 alone, TP=8 |
| `N_d` | replicas | decode replicas in Config P | 1 | g126 alone, TP=8 |
| `N_y` | replicas | collocated replicas in Config H | 1 | g126 alone, TP=8 |
| `decode_batch_p` | requests | concurrent decode batch in P | 32 | SGLang continuous-batch typical for decode-only on H100 TP=8 |
| `decode_batch_h` | requests | concurrent decode batch in H | 4 | pessimistic — collocated prefill bursts block decode-batch progress |
| `TPOT` per model | s/token | per-token decode latency at batch=1 | see §4 | public H100 benchmarks |

All defaults are CLI flags so the same code regenerates the table for
any operating point in seconds.

---

## 2. Equations

Let `s = 1 / Λ_capacity` be the service time of the bottleneck server,
`λ` the offered request rate, `ρ = λ / Λ_capacity` the utilization.

### Eq 1 — per-request wire transit

```
T_wire(l) = (S_kv(l) × 8) / (B_w × 1e9)         [seconds]
```

Bytes shipped across the inter-DC link, divided by Gbps wire.

### Eq 2 — per-request floor TTFT (zero queueing)

```
TTFT_floor_H(l) = T_prefill(l)                                    [Config H]
TTFT_floor_P(l) = T_prefill(l) + T_wire(l) + RTT                  [Config P]
```

We charge `T_wire` *and* a full `RTT` to Config P. The full RTT covers
the prefiller→proxy bootstrap handshake plus the first KV block ack. It
is conservative — Mooncake's PD-disagg pipelines `T_wire` against the
prefill tail so the empirical floor will likely be lower. We deliberately
leave that tightening to Phase 3's measurements.

### Eq 3 — Config P capacity (PrfaaS)

```
λ_compute_p = N_p / T_prefill(l)                  [prefill GPU bound, X side]
λ_wire      = (B_w × 1e9) / (S_kv(l) × 8)         [wire bound, shared link]
λ_decode_p  = (N_d × decode_batch_p) / (o × TPOT) [decode GPU bound, Y side]
Λ_P_capacity = min(λ_compute_p, λ_wire, λ_decode_p)
```

The `bottleneck (P)` column in the CSV is whichever of the three is
binding.

### Eq 4 — Config H capacity (collocated decode-only on Y)

```
Λ_H_capacity = (N_y × decode_batch_h) / (T_prefill(l) + o × TPOT)
```

A collocated TP=8 replica must do prefill *and* decode on the same set
of GPUs. We assume per-request wall-clock = `T_prefill + T_decode` and
multiply by `decode_batch_h` (the achievable collocated batch — small
because prefill bursts block decode-batch progress on a shared replica).
This is the paper's "decode DC alone" baseline.

### Eq 5 — M/M/1 P95 wait approximation

```
W_p95(λ)        = ln(20) × s × ρ / (1 - ρ)        [ρ < 1; ∞ otherwise]
TTFT_p95(λ)     = TTFT_floor + W_p95(λ)
```

`ln(20) ≈ 2.996` is the 95th-percentile quantile of an exponential
distribution. M/M/1 is conservative — the paper's M/D/1 model gives
roughly half the wait, but real prefill latency is not perfectly
deterministic (SGLang scheduler jitter, MoE expert routing variance) so
the M/M/1 tail is the safer call. Phase 3 will measure the real tail
shape; if it is closer to M/D/1 we'll bias the predictions in the same
direction for both Configs.

### Eq 6 — Λ_max under SLO

```
Λ_max = max λ ∈ [0, Λ_capacity)  s.t.  TTFT_p95(λ) ≤ SLO_TTFT
```

Solved by 100-iteration bisection. Returns `0` if even `T_floor > SLO`.

### Eq 7 — paper headline (PrfaaS speedup)

```
speedup(model, l, B_w, ...) = Λ_max(P) / Λ_max(H)
```

This is the figure-of-merit the paper reports as Figure 8.

### Eq 8 — bandwidth-feasibility predicate (paper §5.1)

```
feasible(model, l, B_w) ≡ Φkv(l) ≤ B_w
                       ⇔ λ_wire / λ_compute_p ≥ 1
```

When this fails, the wire is the bottleneck and PrfaaS cannot beat the
homogeneous baseline regardless of how fast prefill is on the X side.
This is the dense-vs-hybrid divider.

---

## 3. Worked example: Kimi-Linear-48B at the operating point

`l = 16,384`, `o = 256`, `B_w = 14.7` Gbps, `RTT = 30 ms`, `SLO = 2 s`,
`N_p = N_d = N_y = 1`, `decode_batch_p = 32`, `decode_batch_h = 4`,
`TPOT = 12 ms/tok` (Phase 1: `S_kv = 132,120,576 B`,
`T_prefill = 0.182 s`).

```
T_wire        = 132 e6 × 8 / (14.7 e9)                       = 0.072 s
TTFT_floor_H  = 0.182 s
TTFT_floor_P  = 0.182 + 0.072 + 0.030                        = 0.284 s

λ_compute_p   = 1 / 0.182                                    =  5.50 req/s
λ_wire        = 14.7 e9 / (132 e6 × 8)                       = 13.91 req/s
λ_decode_p    = 1 × 32 / (256 × 0.012)                       = 10.42 req/s
Λ_P_capacity  = min(5.50, 13.91, 10.42)                      =  5.50 req/s   ← compute_p

Λ_H_capacity  = 1 × 4 / (0.182 + 256 × 0.012)                =  1.21 req/s

Λ_max(P) at SLO = 2 s, TTFT_floor=0.284 ⇒ ~4.17 req/s
Λ_max(H) at SLO = 2 s, TTFT_floor=0.182 ⇒ ~0.53 req/s

speedup       = 4.17 / 0.53                                  ≈ 7.9×
```

Matches `PHASE2_PICK.md` to two decimal places.

---

## 4. TPOT defaults and where they come from

These are the most leverage-heavy assumption in the model — moving TPOT
shifts Λ_max(H) and Λ_max(P) almost linearly. Defaults:

| model | active params | TPOT (s/tok) | source |
|---|---:|---:|---|
| `kimi-linear-48b` | 3 B (MoE 256 experts) | 0.012 | SGLang public benches at TP=8 batch=1 (~80–90 tok/s/req) |
| `nemotron-nano-9b-v2` | 9 B (Mamba2 majority) | 0.008 | NVIDIA blog + SGLang benches (~125 tok/s/req) |
| `qwen2.5-72b-instruct` | 72 B (dense) | 0.035 | SGLang TP=8 H100 (~28 tok/s/req at batch=1) |

These are operator-supplied; they should be replaced with measured
Phase 3 numbers as soon as a real concurrency sweep produces them.
Override per-cell with `--tpot kimi-linear-48b=0.014` etc.

The model is **not** sensitive to `TPOT` in the regime where `compute_p`
binds (long contexts, heavy prefill) — those rows are dominated by
`T_prefill / N_p`, not decode. It's only at short contexts (`l ≤ 4 K`)
that `decode_p` becomes the binding bottleneck and TPOT matters.

---

## 5. What the model says, qualitatively

Re-reading the CSV at the operating point:

1. **`kimi-linear-48b` is the unambiguous Phase-3 target.** Wire-feasible
   at every paper-relevant `l ∈ [1 K, 131 K]`, with predicted speedup
   ranging from 16× (`l ≤ 8 K`, decode-bound) through 8× (`l = 16 K`,
   compute-bound) down to 1.2× (`l = 64 K`, prefill saturates).
2. **`qwen2.5-72b-instruct` is wire-infeasible at every l ≥ 4 K.** Φkv at
   16 K is 53.8 Gbps, our wire is 14.7 — the wire alone is 3.6× too slow
   to keep up with prefill. Λ_max(P) collapses to zero. This is exactly
   the paper's argument for ruling dense models out at our bandwidth class.
3. **`nemotron-nano-9b-v2` is the backup pick.** Smaller model ⇒ smaller
   prefill latency ⇒ X-side compute_p is the bottleneck earlier (around
   `l = 4 K`); peak speedup ≈ 13× at short contexts, drops to 2× at 16 K
   then below 1 by 32 K.
4. **The Φkv-vs-Bw safety margin (paper §5.1)** holds for both hybrids
   and fails for the dense control across the entire paper-relevant
   context band. Our measurement agrees with the paper's qualitative
   claim despite using a 7× narrower wire (paper assumes 100 Gbps VPC,
   we have 14.7 Gbps public Internet).

---

## 6. Failure modes — what to look for in Phase 3

If Phase 3's measured Λ_max(P)/Λ_max(H) on Kimi-Linear-48B at `l = 16 K`
falls outside `7.94× ± 25%`, the most likely causes (in order of
likelihood):

1. **Decode batch wasn't 32.** The H100 KV-cache memory budget caps the
   concurrent decode batch SGLang can hold for Kimi at `l = 16 K`; if
   it's actually 8 instead of 32, predicted Λ_max(P) drops to ~1.05 req/s
   (decode_p binds before compute_p). Easy diagnosis: check SGLang's
   `--max-running-requests` and the `running_req` metric during the run.
2. **Mooncake adds non-trivial wire overhead.** `λ_wire` here uses raw
   Stage 0a goodput (14.7 Gbps). Mooncake's metadata, bootstrap, and
   block-id ack traffic will burn some headroom. If the connector ships
   at, say, 10 Gbps effective for KV blocks, λ_wire drops to 9.5 req/s
   — still above compute_p so it doesn't change the pick, but the wire
   could become binding at smaller hybrids (re-check Nemotron).
3. **Cross-replica scheduling overhead.** The paper's model assumes
   prefill and decode pipelines are tight. SGLang's PD-disagg shipping
   in v0.5.9 does pipeline KV transfer with prefill, but the proxy adds
   another network hop. If end-to-end TTFT_floor_P is closer to
   `T_prefill + T_wire + 2 × RTT`, predicted Λ_max(P) at SLO drops by
   ~10%.
4. **`T_prefill` regresses under load.** Phase 1 measured `T_prefill` at
   single concurrency. If SGLang's batched prefill at concurrency-N
   inflates per-request `T_prefill` (which it shouldn't — prefill is
   per-request — but might if there's contention on the KDA recurrent
   state), the compute_p bottleneck moves down by that factor.
5. **Public-internet bandwidth dipped at the run window.** Stage 0a's
   14.7 Gbps was a Sunday-night sample. Stage 0a-bis is meant to add two
   more time-of-day windows; if one of those is materially lower we'll
   re-run Phase 2 with the actual operating-point bandwidth and update
   the pick.

We deliberately do *not* claim the analytical model is right to better
than ±25%. The paper's own validation (Table 3 in the appendix) shows
~15-20% deviation between their analytical Λ_max and their measured
Λ_max, and they have private 100 Gbps fiber. Our wire is messier.

---

## 7. Reproduction

```bash
# Default operating point (matches PHASE2_PICK.md)
python prfaas/m1.5-vllm-baseline/scripts/phase2/run_phase2.py

# Narrower wire (Stage 0b WireGuard ablation, hypothetical 8 Gbps)
python prfaas/m1.5-vllm-baseline/scripts/phase2/run_phase2.py \
    --measured-bw 8.0 --bw-grid 1,2,4,8,16

# Tighter SLO (1 s, paper's 'chat_balanced' SLO)
python prfaas/m1.5-vllm-baseline/scripts/phase2/run_phase2.py \
    --slo-s 1.0 --input-len 4096

# Two prefillers on X (g304 + g307 as a single MoE shard)
python prfaas/m1.5-vllm-baseline/scripts/phase2/run_phase2.py --n-p 2

# Override Kimi TPOT to the measured Phase 3 number once we have it
python prfaas/m1.5-vllm-baseline/scripts/phase2/run_phase2.py \
    --tpot kimi-linear-48b=0.014
```

All outputs land under
`prfaas/results/m1.5-vllm-baseline/phase2_analytical/`. Re-running is
idempotent; it overwrites `lambda_max_predictions.csv`,
`PAPER_FIG8_REGEN.png`, and `PHASE2_PICK.md`.
