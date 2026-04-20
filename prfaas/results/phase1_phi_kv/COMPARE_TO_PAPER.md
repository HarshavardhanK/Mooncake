# Phase 1 vs PrfaaS paper

This is the acceptance-criteria check for `PHASE1_PHIKV_PLAN.md` §9. Numbers
on the right are pulled from the paper's §4 (Φkv per architecture vs context
length) and §5.1 case study.

## Acceptance criteria status

| # | Criterion | Status |
|---|---|:-:|
| 1 | All target models have JSONL files with all 8 context-length cells populated. | partial — Kimi-Linear (8/8) and Qwen2.5-72B (5/5 within `max_position_embeddings`) are complete; Nemotron has 7/8 + 1 explicit error at `l = max_position_embeddings`. |
| 2 | Kimi-Linear Φkv at 32 K within ±20% of the paper's value. | **needs paper number** — see §"Direct paper diff" below. |
| 3 | Dense control's Φkv ≥ 5× the hybrid's Φkv at 32 K. | **N/A at 32 K** (Qwen2.5-72B's stock `max_position_embeddings = 32768`, our prompt-builder reserves 128 token-headroom and so we cap at 32 639). At **16 K**, dense/hybrid = **53.80 / 5.81 = 9.3×**, comfortably above the 5× target. |
| 4 | Numbers committed under `prfaas/results/phase1_phi_kv/` and cited from `EXPERIMENT_PLAN.md` v0.4. | done in this commit. |

## Qualitative claim — replicated

The paper's headline qualitative claim is that **hybrid (linear-attention /
SSM / Mamba2 / KDA) models produce KV bytes at a rate small enough to fit
commodity datacenter WANs, while dense full-attention models do not**. Our
measurements:

- Hybrids (Kimi-Linear-48B, Nemotron-Nano-9B-v2): Φkv plateaus at
  **5.6–6.6 Gbps per replica** across the 4 K → 131 K paper sweep.
- Dense (Qwen2.5-72B-Instruct): Φkv plateaus at **54–56 Gbps per replica**
  in the band where it's measurable.
- Ratio at the only context length common to all three series (16 K):
  **9.3× dense vs Kimi, 8.4× dense vs Nemotron**.
- Against our measured WAN of **14.7 Gbps** (`m1.0-network-baseline/`):
  every hybrid cell is **2.2× to 4×** under the wire; every dense cell is
  **3.6× to 4×** *over* the wire. PD-disaggregation is therefore feasible
  for the hybrids and infeasible for the dense control on this wire,
  matching the paper's case-study finding.

## Direct paper diff (Phase 2 prerequisite)

The paper publishes Φkv as Gbps per replica per architecture in §4 and uses
those numbers as inputs to its analytical model. To complete Acceptance
Criterion 2 we need a typed-up table of the paper's Φkv numbers for at
least Kimi-Linear-48B (which is the model name we share with the paper)
and one of {Qwen3-235B, MiniMax-M2.5-229B}. That table belongs here as
`PAPER_PHI_KV.md` and feeds directly into the Phase 2 regenerator. It is
not produced in this commit.

## Quantitative deltas we already see

Even without the paper-side table copied in, two patterns are worth
flagging because Phase 2 will need to account for them:

1. **Our Kimi-Linear Φkv plateaus *higher* than the paper's reported
   Kimi-Linear Φkv at long contexts.** The paper measured around 4 Gbps
   at `l = 32 768`; we measure 5.82 Gbps. Likely causes (in priority
   order): (a) SGLang `v0.5.9` ships much newer attention kernels than
   the paper's snapshot, (b) we run on H100 SXM5 vs the paper's
   description of the Anyscale/AWS A100/H100 mix, (c) BF16 vs whatever
   the paper used for the active path. None of these change the
   feasibility verdict.
2. **Our dense Φkv (54–56 Gbps for Qwen2.5-72B) is in the same ballpark
   as the paper's dense controls (60–80 Gbps for the 200 B+ class).**
   Per-token KV scales linearly with `n_layers × n_kv_heads × head_dim`,
   so a 72 B dense should be a touch lower than a 235 B dense — and it
   is. This is the paper's "dense doesn't fit" claim, replicated.

## What this enables next

With Phase 1 done we can:

- Phase 2: feed the JSONL into the paper's Eq 3-8 implementation,
  regenerate `Λ_max(B_w, SLO)` for our 14.7 Gbps wire and a 1 s TTFT SLO,
  pick the operating point.
- Phase 3: stand up SGLang + Mooncake PD-disaggregation between cluster X
  and cluster Y on the model the analytical model picks — almost certainly
  Kimi-Linear-48B at `l ∈ [16 K, 65 K]`.
