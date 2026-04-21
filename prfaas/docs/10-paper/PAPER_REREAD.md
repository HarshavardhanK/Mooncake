# Paper re-read: what does PrfaaS actually claim?

This document is the receipts behind the v0.3 reframing of
`EXPERIMENT_PLAN.md`. v0.1/v0.2 of the plan made two assumptions that turn
out to be wrong on close reading. Both are corrected in v0.3.

Reference: *Prefill-as-a-Service: KVCache of Next-Generation Models Could Go
Cross-Datacenter* (Qin et al., arXiv:2604.15039, 2026).

## The paper's actual three claims

In the paper's own words, the contributions are:

1. **A bandwidth-feasibility characterization** showing that hybrid-attention
   model architectures (Mamba2, gated DeltaNet, lightning attention, etc.)
   have low enough KV-stream rates to make cross-DC PD viable on commodity
   inter-DC links — and that *dense-attention* models do not.
2. **A throughput-at-SLO model** for cross-DC disaggregation, parameterized
   by per-replica prefill throughput, decoder steady-state load, link
   bandwidth, and link RTT.
3. **An analytical case study** plugging a 100 Gbps VPC peering measurement
   into that model for a representative hybrid model, showing that the
   decode DC sustains substantially higher Λ_max(SLO) when prefill is
   offloaded.

What the paper **does not** claim, and what we should not test:

- It does not claim a single request gets a faster TTFT. The headline is
  about how many *concurrent* requests the decode DC can handle at a fixed
  TTFT-P95 SLO.
- It does not claim the scheme works for dense-attention models. It
  explicitly excludes them.
- It does not present an end-to-end deployment measurement on the kind of
  budget-public-internet WAN we have. The case study uses 100 Gbps VPC
  peering and an analytical model.

## Implications for what we should measure

| Wrong v0.2 framing | What v0.3 does instead |
|---|---|
| Per-request TTFT/TPOT/ITL/E2EL as the headline metric | **Λ_max(SLO)** = max QPS at TTFT P95 ≤ SLO, with TTFT/TPOT/etc reported alongside |
| Llama-3.1-70B + Qwen3-8B as primary models | **Qwen3-Next-80B-A3B-Instruct** (primary, hybrid MoE) + **NVIDIA-Nemotron-Nano-9B-v2** (smoke / fallback, hybrid Mamba2) |
| Compare disagg-cross-DC vs. collocated-on-prefill-DC (not a meaningful baseline) | **Three configs** per stage: H = homogeneous decode-only on Y, N = naive het split on Y, P = PrfaaS-style with prefill on X. Headline = Λ_max(P) / Λ_max(H). |
| Stage D inflates TTFT by N ms vs Stage C → bad result | Stage D shows (or doesn't show) Λ_max(P) > Λ_max(H) → a result either way; the bandwidth threshold is the finding |

`SIZING.md` is the bandwidth-feasibility math from claim (1) plugged into
our hardware. It is the gate that decides whether Qwen3-Next is the right
primary or whether we drop to Nemotron-Nano after Stage 0 measures the wire.

## Why the prior framing was tempting (and wrong)

It's natural to treat "cross-DC PD" as "send one request through a slower
pipe and see what TTFT does" — that's how a request-flow person thinks. But
the paper's claim is system-level: when you free up the decode DC's prefill
GPUs, *the decoder serves more steady-state requests*, and you measure that
in QPS-at-SLO, not in any single request's TTFT.

Once you frame it that way:

- A bandwidth-starved link doesn't refute the claim — it just lowers the
  Λ_max(P) ceiling. As long as Λ_max(P) > Λ_max(H), the paper wins.
- Per-request TTFT going up by an RTT is not a problem; what matters is
  whether enough requests still meet the P95 budget.
- Dense models are out of scope because their KV stream is 10–20× larger,
  putting Λ_max(P) below Λ_max(H) at any plausible inter-DC bandwidth.
  This is hypothesis H6 in the v0.3 plan, supported analytically in
  SIZING.md §3, not run.

## What we lose by switching framings

The Stage A/B/C/D layout from v0.2 is mostly preserved — we just sweep
concurrency to find Λ_max instead of taking single-concurrency
measurements. The build-out cost is one Python script
(`extract_lambda_max.py`) and a "sweep until SLO breaches" loop in
`run_concurrency_sweep.sh`. Everything else (Mooncake config,
proxy_demo.py, vLLM connector, firewall whitelist) is the same.

The flip side: we can't directly compare our v0.3 numbers to anyone else's
TTFT report. But the paper itself doesn't publish a TTFT comparison either;
it publishes Λ_max ratios. So we're better aligned with the literature, not
worse.
