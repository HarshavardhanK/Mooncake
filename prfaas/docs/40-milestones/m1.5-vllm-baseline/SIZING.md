# M1.5 sizing — does this model fit our wire?

The PrfaaS paper's central feasibility constraint is:

> The cross-DC link's effective bandwidth (per prefiller) must exceed the
> rate at which the prefiller produces KV cache.

Below that threshold, the prefiller stalls waiting for the link to drain
and Λ_max(P) ≤ Λ_max(H). Above it, you get the paper's Λ_max gain.

This doc plugs *our* hardware and *our* candidate models into that formula
so we can decide, **before Stage A**, whether the primary model is feasible
or if we need to drop to the smoke-test model.

---

## 1. The formula

For a prefill replica running at sustained throughput `T_pref` (input
tokens per second), the KV cache it produces per second is:

```
KV_bytes_per_sec = T_pref × kv_per_token_bytes
```

`kv_per_token_bytes` is what the model architecture decides:

```
dense:  kv_per_token = 2 × n_kv_heads × head_dim × n_layers × bytes_per_elem
hybrid: kv_per_token = 2 × n_kv_heads × head_dim × n_attention_layers × bytes_per_elem
        (the Mamba/SSM/linear layers contribute 0 to the KV stream)
```

For BF16, `bytes_per_elem = 2`.

For the system to be bandwidth-feasible:

```
KV_bytes_per_sec ≤ wire_goodput_bytes_per_sec / num_prefill_replicas
```

And — important — `wire_goodput` here is what we measure in **Stage 0**,
not what's printed on the link's box. Public-internet 10 Gbps usually
delivers 4–8 Gbps of single-flow TCP goodput.

---

## 2. The numbers for our two models

### 2a. Qwen3-Next-80B-A3B-Instruct (primary)

Architecture (from the model card / config.json):
- Total params: 80 B (MoE; 3 B activated per token)
- Layers: 48
- Of which **standard attention layers**: 12 (every 4th layer, gated
  DeltaNet linear-attention on the rest)
- `n_kv_heads`: 2 (GQA group of 16)
- `head_dim`: 256
- `bytes_per_elem`: 2 (BF16)

```
kv_per_token = 2 × 2 × 256 × 12 × 2  =  24,576 bytes  ≈ 24 KB/token
```

For comparison, dense Llama-3.1-70B is `2 × 8 × 128 × 80 × 2 = 327,680 B
≈ 320 KB/token`. Qwen3-Next-80B-A3B is **~13× cheaper per token** thanks to
the hybrid architecture. This is what makes the paper's scheme viable.

#### Sustained prefill throughput on TP=8 H100

From published benchmarks for Qwen3-Next-class models on H100:
- Prefill throughput ≈ 100,000–250,000 input-tokens/sec at long context,
  TP=8, BF16, well-tuned vLLM.
- Use **150,000 input-tokens/sec** as a working estimate (will be replaced
  by Stage A measurement).

```
KV_bytes_per_sec  = 150,000 × 24,576  =  3.69 GB/s  =  29.5 Gbps per prefiller
```

**Bandwidth check (one prefiller):**

| Wire | Effective goodput | Feasible? |
|---|---|---|
| 100 Gbps VPC peering (paper's case) | ~80 Gbps | ✅ comfortable headroom |
| 40 Gbps cross-region private | ~30 Gbps | ✅ marginal — one prefiller saturates |
| 10 Gbps public internet, single flow | ~4–8 Gbps | ❌ infeasible at 100% prefill load |
| 10 Gbps public internet, **8 parallel flows** | ~8–9 Gbps | ❌ still short |
| 10 Gbps public internet at **partial prefill load** (50% utilization → 75K tok/s) | ~8 Gbps avail / 14.7 Gbps demand | ❌ infeasible |

**Conclusion for Qwen3-Next-80B-A3B on a 10 Gbps public-internet link:**
the model only fits if either (a) we run the prefiller at ≤ 25–30%
sustained utilization, or (b) the wire turns out to deliver 30+ Gbps with
parallel TCP. Both are possible but neither is a sure thing. **Stage 0a is
the gate.**

If Stage 0a says we have ≥ 25 Gbps multi-flow goodput, Qwen3-Next stays
primary. Otherwise we drop to Nemotron-Nano-9B-v2.

### 2b. NVIDIA-Nemotron-Nano-9B-v2 (smoke / fallback primary)

Architecture (from the model card / config.json):
- Total params: 9 B
- Total layers: 56 (52 Mamba2 + 4 attention; ratio is ~28:1 by weight class)
- Standard attention layers: **4**
- `n_kv_heads`: 8 (GQA)
- `head_dim`: 128
- `bytes_per_elem`: 2 (BF16)

```
kv_per_token = 2 × 8 × 128 × 4 × 2  =  16,384 bytes  ≈ 16 KB/token
```

#### Sustained prefill throughput on TP=4 H100

For a 9B hybrid on TP=4 H100 we can push roughly:
- 200,000–400,000 input-tokens/sec at long context.
- Use **300,000 tok/s** as a working estimate.

```
KV_bytes_per_sec  = 300,000 × 16,384  =  4.92 GB/s  =  39.3 Gbps per prefiller
```

Note that throughput-per-prefiller is *higher* in absolute Gbps for the
smaller model, because the smaller model prefills faster. But because
Nemotron-Nano is far cheaper to run, we typically **don't max out** a
single replica — we'd rather run 2–4 small replicas at lower per-replica
throughput. At 25% per-replica utilization (~75K tok/s), per-replica KV
demand drops to ~9.8 Gbps, which fits a 10 Gbps link with parallel TCP.

**Conclusion for Nemotron-Nano-9B-v2:** feasible on 10 Gbps public
internet **at moderate per-replica load**. Run with two prefiller replicas
and the round-robin proxy will balance them; per-replica demand stays under
the link goodput.

---

## 3. Dense models, for comparison (paper-aligned, NOT run)

We do not run dense models in M1.5; this section is the analytical backup
for hypothesis H6.

### Llama-3.1-70B (full attention, GQA n_kv_heads=8, head_dim=128, layers=80)

```
kv_per_token = 2 × 8 × 128 × 80 × 2 = 327,680 bytes ≈ 320 KB/token
```

At a TP=8 prefill throughput of 80,000 tok/s:

```
KV_bytes_per_sec  = 80,000 × 327,680  ≈  26.2 GB/s  =  210 Gbps per prefiller
```

This requires a **210 Gbps single-flow TCP** stream from prefiller to
decoder. Not achievable on commodity 10/40/100 Gbps WAN, even with parallel
TCP and tuned everything. **Confirmed infeasible**, in line with the paper.

### Qwen3-8B (full-attention dense, n_kv_heads=8, head_dim=128, layers=36)

```
kv_per_token = 2 × 8 × 128 × 36 × 2 = 147,456 bytes ≈ 144 KB/token
```

At TP=1 prefill throughput of 100,000 tok/s:

```
KV_bytes_per_sec ≈ 14.4 GB/s = 115 Gbps per prefiller
```

Also infeasible on public internet for sustained load. Marginally feasible
on 100 Gbps VPC peering with light load. Confirms why the paper restricts
its scope to hybrid models.

---

## 4. Decision tree (executed at end of Stage 0)

```
Stage 0a measures `wire_goodput_gbps` (median across time-of-day window).

if wire_goodput_gbps >= 25:
    primary = Qwen3-Next-80B-A3B-Instruct
    target_prefill_throughput = wire_goodput_gbps × 1e9 / 8 / 24576  # tok/s
    # If the prefiller can sustain that throughput, run at full load.
    # Otherwise, run at the prefiller's natural ceiling and the wire is
    # over-provisioned (best case for the paper's argument).
elif wire_goodput_gbps >= 10:
    primary = NVIDIA-Nemotron-Nano-9B-v2
    target_prefill_throughput_per_replica = wire_goodput_gbps × 1e9 / 8 / 16384 / 2
    # Two prefiller replicas, each at ~half wire capacity.
elif wire_goodput_gbps >= 5:
    primary = NVIDIA-Nemotron-Nano-9B-v2
    # Single prefiller, the experiment becomes a "low-bandwidth WAN" study.
    # Headline ratio likely small or negative; still publishable as a
    # breakeven measurement.
else:
    # < 5 Gbps. Cross-DC PD is not feasible on our wire for any current
    # open hybrid model. Reframe as "characterize the breakeven on a worse
    # wire than the paper assumed."
    primary = NVIDIA-Nemotron-Nano-9B-v2
    # Run it anyway; report the negative result honestly.
```

This decision is made automatically by `scripts/extract_lambda_max.py
--decide-model` after Stage 0a, which writes the result to
`results/stage0/MODEL_DECISION.md`.

---

## 5. Total bytes shipped over the matrix (for the bandwidth-budget question
in PREFLIGHT.md §7)

Per cell: `num_prompts × kv_per_token × input_len`. With NUM_FOLDS=20 and
the §6.1 grid (4 workloads × 7 concurrencies × 3 time-of-day repeats):

For Qwen3-Next:
- `long_context` (16384 input, conc=192, fold=20, kv=24KB): one cell ships
  `192 × 20 × 16384 × 24576 = ~1.5 GB`. Across all 4 workloads × 7
  concurrencies × 3 repeats ≈ **~250 GB per Stage D run**, dominated by
  long_context cells. Adding Stages B+C inflates this by 3–4× (more
  configs, more WAN profiles), so Stage B + C + D total is on the order of
  **~1 TB**, well under the "~10 TB" worst-case in PREFLIGHT.md.

For Nemotron-Nano (kv=16KB instead of 24KB) the totals scale by 2/3.

If the bandwidth budget in PREFLIGHT §7 comes back as constrained, we cut
NUM_FOLDS in half and drop the `code_complete` workload (it's the least
informative for the headline number).

---

## 6. What this doc commits us to

- Run Stage 0a first; **its output picks the model**, not vibes.
- Report Λ_max for whichever model the wire supports.
- Don't hand-wave the dense-model exclusion — § 3 is the receipts.

When the agent finishes Stage 0a, it writes `results/stage0/MODEL_DECISION.md`
with:

1. measured `wire_goodput_gbps` (median + min/max)
2. branch taken from the §4 decision tree
3. selected primary model + target prefill throughput
4. updated `~/.prfaas_env` with `PRIMARY_MODEL` set accordingly

Then RUNBOOK.md Stage A starts, using whatever the decision tree picked.
