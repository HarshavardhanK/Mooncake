# PrfaaS-on-Mooncake: experiment plan

**Status:** draft v0.4 — paper-faithful re-alignment.

> **TL;DR for v0.4.** v0.3 had the right framing (Λ_max-at-SLO, hybrid focus,
> three-config head-to-head) but used model surrogates (Qwen3-Next-80B-A3B,
> Qwen2.5-7B) that aren't in the PrfaaS paper's evaluation set. v0.4 inserts a
> new **Phase 1 — Φkv replication** that profiles the paper's actual primary
> hybrid (`moonshotai/Kimi-Linear-48B-A3B-Instruct`) with the paper's actual
> serving stack (SGLang v0.5.9 + Mooncake transfer engine), reproducing the
> measurement that drives Table 6. Stages A–D from v0.3 still stand but become
> the *empirical* arm of the plan; Phase 1 is the *analytical* input the paper
> uses to forecast Λ_max(BW, SLO). See
> [`PHASE1_PHIKV_PLAN.md`](../10-paper/PHASE1_PHIKV_PLAN.md) for the full Phase 1 spec.

### v0.3 → v0.4 changelog

| What | v0.3 | v0.4 |
|---|---|---|
| Primary hybrid | Qwen3-Next-80B-A3B-Instruct (paper-adjacent) | **moonshotai/Kimi-Linear-48B-A3B-Instruct** (paper's actual) |
| Smoke / second hybrid | nvidia/Nemotron-Nano-9B-v2 (paper-adjacent Mamba2) | unchanged |
| Dense control | analytical only (Llama-70B, Qwen3-8B back-of-envelope) | **measured: Qwen2.5-72B-Instruct** on g126; defer Qwen3-235B (paper's actual) until X-cluster K8s GPU exposure unblocks |
| Engineering smoke for K8s plumbing | n/a | Stage A's Qwen2.5-7B run on vLLM (kept as proof the K8s+Mooncake plumbing is alive; not a paper data point) |
| Engine | vLLM 0.19.1 only | **SGLang v0.5.9** for Phase 1 (paper's exact tool, ships first-class Mooncake PD-disagg); vLLM kept for Stage A engineering smoke |
| Headline measurement | Stage D Λ_max(P)/Λ_max(H) ratio | unchanged for the empirical arm; **Phase 1's Φkv replication is the analytical headline** that Phase 2 plugs into the paper's Eq 3-8 to predict the same ratio |

### Earlier reframing (kept from v0.3)

v0.1/v0.2 framed the experiment around per-request TTFT on dense models
(Llama-70B, Qwen3-8B). After re-reading the paper end-to-end (see
`prfaas/docs/10-paper/PAPER_REREAD.md`), both choices were wrong:

1. **Wrong metric.** The paper's headline is *throughput-at-SLO* — "decode DC
   sustains N× more concurrent users at fixed P95 TTFT", not "any single
   request gets a faster TTFT". Per-request TTFT on a starved WAN looks bad;
   that's not a refutation of the paper.
2. **Wrong model class.** Cross-DC PD only closes the bandwidth budget for
   hybrid-attention models. Llama-70B's KV stream is ~30–70 Gbps per replica
   at load — physically impossible to push across commodity public internet.

v0.3 corrected both. v0.4 takes the next step: instead of using paper-adjacent
hybrid surrogates, run the paper's actual hybrid (Kimi-Linear-48B-A3B) with
the paper's actual engine (SGLang v0.5.9), so our Φkv numbers are directly
comparable to the paper's published Table 6 values.

Stages A–D are still structured around three head-to-head configurations
(collocated / naive het / PrfaaS-style) per stage, sweeping concurrency to
find Λ_max for each. Phase 1 sits *before* Stage B and feeds Phase 2's
analytical regenerator.

This doc is the end-to-end plan for **proving (or refuting) the central claim
of the PrfaaS paper** — that cross-datacenter Prefill-Decode disaggregation
on **hybrid-attention models** lets a decode DC sustain higher throughput at
the same SLO than it could alone. It sits one level above the per-milestone
READMEs in `prfaas/m*/`. The actionable runbook lives in
[`prfaas/docs/40-milestones/m1.5-vllm-baseline/RUNBOOK.md`](../40-milestones/m1.5-vllm-baseline/RUNBOOK.md).

If you only read one section, read [§5 Stages](#5-stages-and-go-no-go-criteria).

---

## 1. Goal

Show, on real GPUs and real wire, whether routing prefill of a
hybrid-attention LLM to a remote datacenter lets the decode DC sustain
**meaningfully more concurrent users** at a fixed TTFT SLO than it could on
its own hardware budget — the central claim of the PrfaaS paper.

The success metric for every comparison in this document is

> **Λ_max(SLO) = the maximum offered QPS at which the system still meets
> TTFT P95 ≤ SLO** (default SLO = 2 s, will be tuned per workload in §6).

This is what `benchmark_serving.py` lets us extract via concurrency sweeps.
Per-request TTFT, TPOT, ITL, E2EL are reported alongside but are not the
go/no-go signal.

Non-goals (for the first proof):

- The smart routing layer from PrfaaS §4 — that's M2/M3/M4. M1.5 uses
  round-robin between identical replicas.
- Cost modeling. We focus on *feasibility*; cost follows trivially if Λ_max
  improves.
- Multi-tenant fairness, failure recovery, autoscaling.
- Dense-attention models (Llama, full-attention Qwen). The paper rules these
  out at our bandwidth class; we do not re-litigate that here.

## 2. Hardware topology

Inventory:

| Cluster | Nodes | GPUs | Within-cluster interconnect | Shared FS |
|---|---|---|---|---|
| **X** | 2 | 16× H100 (8/node) | InfiniBand | VAST |
| **Y** | 1 | 8× H100 | n/a (single node) | local NVMe |

Network **between** X and Y: **public internet**, no dedicated inter-DC link,
no private peering. The paper's case study uses 100 Gbps VPC peering —
clearly not what we have. That's fine: a public-internet result that *still*
beats the homogeneous decode-only baseline is a stronger claim than the
paper makes. A public-internet result that *fails* tells us where the
breakeven actually is.

Logical role assignment for M1.5:

```
"Prefill DC" (X — bulk compute)             public internet              "Decode DC" (Y — user-facing)
──────────────────────────────              ───────────────              ─────────────────────────────
Cluster X: 2 nodes × 16 H100               firewall-allow on              Cluster Y: 1 node × 8 H100
- 1–2 prefiller vLLMs, TP=8 each           Mooncake TCP port              - 1 decoder vLLM, TP=8
- mooncake_master (+ etcd)              ════════════════════════>         - proxy server (round-robin)
- VAST: model weights cached once          measured RTT,                  - user-facing OpenAI endpoint
                                           measured bw,                   - local NVMe: model weights
                                           variable both                    independently staged
```

Roles are not load-bearing in code — `--kv-transfer-config` switches a vLLM
process between `kv_producer` and `kv_consumer`. We can flip the layout if Y
turns out to be the better prefill DC, but the natural fit is "cluster with
more GPUs runs prefill."

### 2.1 Operational concerns specific to public-internet WAN

These do not exist in a same-DC setup; flagging them up front so we plan for
them rather than discover them mid-experiment.

**Network exposure.** Mooncake's TCP transport has no built-in TLS or auth.
v0.2 of this doc proposed a WireGuard tunnel as the default. In v0.3 we drop
that for the *benchmark path*, because:

- WireGuard caps user-space throughput somewhere around 2–8 Gbps per tunnel
  (kernel WG is faster but still adds ~5–15% overhead and reduces effective
  MTU by 80 bytes). On a 10 Gbps link that's a real ceiling.
- The tunnel adds latency variance unrelated to what we're measuring.
- The paper's analytical model assumes raw TCP throughput.

The benchmark path uses **firewall whitelist + interface bind** instead:

- On X-gateway: `iptables -A INPUT -p tcp --dport <mooncake_port>
  -s <Y_public_ip>/32 -j ACCEPT; iptables -A INPUT -p tcp --dport
  <mooncake_port> -j DROP`. Same on Y for the reverse direction.
- `mooncake.json` `local_hostname` is set to the public IP of the local node
  so vLLM binds the listener to that interface, not `0.0.0.0`.
- We document, but do not implement, a WireGuard variant for production
  deployments where the security cost is acceptable. **A separate Stage 0b
  will measure the WireGuard delta** so we know the cost.

This is a deliberate trade-off: convenience and security in production vs
clean benchmark numbers in research. Both are defensible.

**NAT / public IPs.** At minimum, one node per side needs a public IP
reachable from the other side. If both clusters are behind NAT with no port
forwarding, we fall back to a relay node in a third location (cheap cloud
VM); document but do not pre-build.

**Bandwidth variability.** Public-internet paths fluctuate by time of day.
Each Stage D measurement is repeated at three wall-clock times across a
24-hour window; results report median plus min/max. M1's CSV schema already
has a `wall_clock_iso` column we can bucket on.

**Path MTU.** Default is 1500 on most public paths, sometimes lower. We
verify with `tracepath` after firewall is up. Mooncake doesn't do PMTU
discovery on its application sockets, so we set TCP MSS clamping in iptables
if the path MTU is < 1500.

**Egress cost.** Probably free (owned/leased nodes), but worth confirming
with whoever pays the bandwidth bill before shipping multi-TB benchmarks.
Stage D at full concurrency on Qwen3-Next-80B-A3B for `long_context` could
ship ~10 TB across the matrix.

### 2.2 Why we keep the IB link in the picture

The 2-node IB link inside cluster X is *not* what we're benchmarking — but
it's incredibly useful as a **clean baseline**. It lets us run a full
disaggregated pipeline (prefill on X1, decode on X2) with effectively zero
RTT and zero loss, so any Λ_max we see there is the upper bound. Stage B
uses this. Stage C adds emulated WAN profiles on top of the IB link to
isolate "what does pure RTT do to Λ_max, on a clean wire?" Stage D then
runs the same workloads on the real public-internet path between X and Y;
the gap between Stage C and Stage D tells us how much the public internet's
noise (jitter, loss, bandwidth dips) costs us beyond pure RTT.

## 3. Hypotheses

Numbered so result CSVs and plots can refer back to them. These are the
paper's actual claims, restated in our hardware terms.

| #  | Hypothesis | How we measure | Status |
|----|-----------|----------------|--------|
| H1 | The X↔Y TCP transport sustains enough goodput to ship a hybrid model's KV cache faster than the prefiller produces it (the paper's bandwidth-feasibility condition) | Stage 0: M1 transport bench in `MODE=native` over the real WAN | ⏳ |
| H2 | At a fixed TTFT-P95 SLO, **Λ_max(PrfaaS) > Λ_max(decode-only)** on Y, on hybrid-attention models, on prefill-heavy workloads | Stages B/C/D, three-config QPS sweep | ⏳ |
| H3 | Adding 10–80 ms RTT inflates *individual* TTFT by ≤1× RTT (one round trip), not by `prefill_time + RTT` | Stage C: TTFT vs RTT at fixed light load | ⏳ |
| H4 | The Λ_max gain shrinks but does not vanish when the WAN goes from clean (Stage C continental) to noisy (Stage D real public internet) | Stage D vs Stage C continental | ⏳ |
| H5 | The breakeven is governed by `effective_BW × hybrid_KV_ratio` vs `prefill_throughput`. Below breakeven, Λ_max(PrfaaS) ≤ Λ_max(decode-only). | Cross-stage analysis using Stage 0 numbers | ⏳ |
| H6 | None of this works for dense-attention models at our bandwidth class. We *don't* run a Llama-70B sweep, we just put the back-of-envelope number in the writeup. | `prfaas/docs/40-milestones/m1.5-vllm-baseline/SIZING.md` | ✅ (analytical only) |

H2 is the headline. H5 is what determines whether the headline is meaningful
or coincidental.

## 4. What Mooncake already gives us

We are *not* building from scratch. Concrete artifacts already in this repo:

- `MooncakeStoreConnector` (vLLM v0) and `MooncakeConnector` (vLLM v1) — both
  ship as `--kv-transfer-config` plugins. The v0 path supports an explicit
  `"protocol": "tcp"` knob in `mooncake.json`, which is what we want for
  cross-DC. (Final pin: see §10 Q3 — deferred until Stage A.)
- `mooncake_master` — daemon that tracks KV block locations.
- `benchmarks/xypd_benchmarks/proxy_demo.py` — round-robin P×D proxy.
- `benchmarks/xypd_benchmarks/vllm-benchmarks/benchmarks.sh` — the matrix
  driver. Wraps vLLM's own `benchmark_serving.py` with
  `--percentile-metrics="ttft,tpot,itl,e2el"` over an `(input_len, output_len,
  concurrency)` grid. **This is the workload generator.** We extend it with
  a QPS-sweep mode for Λ_max.
- `scripts/tone_tests/scripts/test_vllm_1p1d_erdma.sh` — a working 1P1D
  smoke-test pattern (REMOTE_IP for prefill, LOCAL_IP for decode, proxy in
  between, validating curl). Strip `erdma` and swap to TCP.
- `prfaas/m1-tcp-bench/scripts/apply_wan.sh` — `tc netem` profiles for
  emulating cross-DC RTT/loss/bandwidth on a NIC.
- `prfaas/m1-tcp-bench/scripts/native_build.sh` and `host_tune.sh` — built
  for M1, reused as-is for Stage 0.

What we still write (small, concrete, lives under
`prfaas/m1.5-vllm-baseline/`): glue scripts that wire these together for
our specific topology, plus a `mooncake.json` per role, plus a Λ_max
extractor on top of `benchmark_serving.py`'s output.

## 5. Stages and go/no-go criteria

Each stage is independently meaningful. We don't move on until the previous
stage's go/no-go is met.

```
Stage 0 ──> Stage A ──> Phase 1 ──> Phase 2 ──> Stage B ──> Stage C ──> Stage D
(wire)      (eng        (Φkv per    (analyt    (IB base)   (IB+netem)  (real WAN)
            smoke,      paper       regenerate
            Qwen2.5-7B  hybrid +    Λ_max from
            on vLLM)    dense       measured Φkv
                        on SGLang)  + Stage 0a
                                    wire)
                                        \           \           \
                                         \-- isolates Mooncake overhead
                                                     \-- isolates RTT effect
                                                                 \-- adds public-internet noise
```

**Phase 1 + Phase 2 = analytical / paper-replication arm.** They live on
g126 alone, no wire involved, and produce numbers directly comparable to the
paper's Table 6 / Figure 8.

**Stages B–D = empirical PD-disagg arm.** Validate that our actual measured
Λ_max on hybrid models matches the analytical prediction from Phase 2.

Every stage from B onward runs **three configurations** in head-to-head:

- **Config H (homogeneous decode-only):** all of Y's 8 GPUs run a single
  collocated vLLM. Baseline Λ_max for "Y alone with no help."
- **Config N (naive heterogeneous):** Y splits its 8 GPUs into a small
  prefill pod + decode pod (e.g. 2P+6D), still on Y. No remote prefill.
  Shows whether disagg-on-Y alone is even worth doing.
- **Config P (PrfaaS-style):** Y runs decode-only TP=8, prefill is X. This
  is the system claim.

The headline number is `Λ_max(P) / Λ_max(H)` per workload per stage. The
paper claims this is > 1 for hybrid models on prefill-heavy workloads.

### Stage 0 — Characterize the X↔Y link (½ day, before anything else)

**Goal:** know what the wire can do *before* we put an 80B model on it. This
is the M1 transport bench, re-run across the actual public-internet path
inside the firewall whitelist (no WireGuard, see §2.1).

Substages:

- **0a (raw):** firewall whitelist between X-gateway and Y, no tunnel.
  Run `prfaas/m1-tcp-bench/scripts/run_matrix.sh` in `MODE=native` against
  the public IPs. Sweep slice size, threads, conn-pool — same matrix M1
  already covers. Repeat at three wall-clock times.
- **0b (tunnel ablation):** stand up WireGuard, re-run *one* representative
  cell (slice=4MiB, threads=4, conn-pool=on). Compare goodput, latency, CPU
  to 0a. This is documented as a *cost* number, not a default.
- **Out-of-band sanity:** TCP RTT (`ping`), MTU (`tracepath`), single-flow
  `iperf3 -P 1` and multi-flow `iperf3 -P 16`.

**Done when:**
- We have a CSV under `prfaas/results/m1-tcp-bench/cross_dc_xy/` reporting
  goodput / P50 latency / retransmits per cell, plus time-of-day variance.
- We have a one-paragraph "what the wire can do" in
  `prfaas/results/m1.5-vllm-baseline/stage0a/SUMMARY.md`.
- We can answer: *"At measured median bandwidth B Gbps, what's the largest
  hybrid model that fits the bandwidth budget for `long_context` at our
  target QPS?"* — back-of-envelope math is in `SIZING.md`, plug Stage 0's B
  in.

If the answer is **Qwen3-Next-80B-A3B doesn't fit**, we drop to
`Nemotron-Nano-9B-v2` for Stage B onward (see SIZING.md for the threshold).

### Stage A — Single-machine 1P1D smoke (½ day, on cluster Y)  — **DONE (Qwen2.5-7B), hybrid blocked**

**Goal:** prove the Mooncake+vLLM integration end-to-end on one box. No
network, no WAN, no tunnel. Validates the wiring; does *not* attempt to
prove H2.

**Realised setup (K8s, not host-side):**

- 1 node (`g126`, H100×8) on cluster Y, all in the `default` namespace.
- 2 vLLM Deployments backed by `vllm/vllm-openai:v0.19.1`:
  - `prefiller` — `CUDA_VISIBLE_DEVICES=0,1,2,3`, TP=4, `kv_role=kv_producer`,
    OpenAI port 8010, Mooncake bootstrap port 8998.
  - `decoder`   — `CUDA_VISIBLE_DEVICES=4,5,6,7`, TP=4, `kv_role=kv_consumer`,
    OpenAI port 8020.
- `mooncake.json` with `"protocol": "tcp"`, `local_hostname=127.0.0.1` (RDMA
  not negotiated — `Found 0 HCAs` inside the container, see Stage B for the
  HCA fix).
- Proxy: bundled `mooncake.vllm_v1_proxy_server` (round-robin, **does not
  drive the full v1 PD protocol** — see caveats in
  `prfaas/docs/40-milestones/m1.5-vllm-baseline/MASTER_PLAN.md`).
- **Active smoke model: `Qwen/Qwen2.5-7B-Instruct`** (dense attention).
  Pivoted from Nemotron-Nano-9B-v2 after a layered failure (see below).
- A single `curl` to `proxy.default.svc:8000/v1/chat/completions` returns
  `OK` (HTTP 200, content `"OK"`). Evidence:
  `prfaas/results/m1.5-vllm-baseline/stageA/smoke.log` and `kv_transfer_evidence.log`.

**Negative finding — hybrid models on MooncakeConnector v0.19.1:**

Nemotron-Nano-9B-v2 is a **hybrid Mamba2 + attention** model and fails on
this stack in two stages:

1. *Without* a SupportsHMA shim → vLLM disables the Hybrid KV cache
   manager whenever `--kv-transfer-config` is set, then crashes with
   `ValueError: Hybrid KV cache manager is disabled but failed to convert
   the KV cache specs to one unified type`.
2. *With* an in-place `SupportsHMA` patch + `--no-disable-hybrid-kv-cache-manager`
   → it gets one layer further and dies inside `TpKVTopology.__post_init__`
   on `attn_backend.get_kv_cache_shape()`, which the Mamba2 backend
   raises `NotImplementedError` for. Evidence:
   `prfaas/results/m1.5-vllm-baseline/stageA/nemotron_failure_prefiller.log`,
   `prfaas/results/m1.5-vllm-baseline/stageA/MC_PATCH_NOTE.md`.

The SupportsHMA patch is preserved (idempotent, no-op for dense models)
in `10-prefiller.yaml` and `20-decoder.yaml` so swapping back to a
hybrid model is a one-line ConfigMap edit once upstream support lands.
The full hybrid-model unblock plan lives in
`prfaas/docs/10-paper/PAPER_MODEL_PLAN.md` (paths A/B/C: wait for upstream, SGLang
probe, custom connector).

**Done when (✅ all met for the dense path):**
- Smoke curl succeeds (`http=200`, content `"OK"`).
- Both vLLM processes log MooncakeConnector init, prefiller publishes
  bootstrap on 8998, decoder connects.
- Prefiller and decoder Deployments report `Available=True` and
  `1/1 Ready` for ≥ 5 min.
- Negative finding for the hybrid path (Nemotron) is captured with
  full stack traces and the proposed three-path unblock.

### Phase 1 — Φkv replication on the paper's actual hybrid (1 day, on g126)

**Goal:** reproduce the paper's Table 6 input — the per-model KV-throughput
rate `Φkv(l) = Skv(l) / Tprefill(l)` — using the paper's actual primary
hybrid (`moonshotai/Kimi-Linear-48B-A3B-Instruct`), the paper's actual
serving stack (SGLang v0.5.9), and the paper's context-length sweep
(1 K → 128 K). Full spec: [`PHASE1_PHIKV_PLAN.md`](../10-paper/PHASE1_PHIKV_PLAN.md).

**What changes vs Stage A:**

- **Engine.** SGLang v0.5.9 (paper's tool) instead of vLLM 0.19.1 (Stage A).
  SGLang's attention dispatcher handles linear-attention / MLA natively, so
  Kimi-Linear and Nemotron-Nano both serve out of the box — no `SupportsHMA`
  patch, no Mamba2 `NotImplementedError`. Bonus: SGLang's Mooncake PD-disagg
  path is what we'll need in Phase 3 too, so we standardise here.
- **Model.** Kimi-Linear-48B-A3B-Instruct (paper's primary hybrid that fits
  one 8-H100 box, 49 GiB BF16, MIT license, public on HF).
- **Workload.** Single-instance, concurrency=1, output_len=1, no radix-cache
  hits. The probe times request_submit → first_token, computes Skv(l) from
  config.json, dumps JSONL.

**Models in scope this week (g126 alone):**

| Role | Model | TP | Why |
|---|---|---|---|
| H1 (paper hybrid) | `moonshotai/Kimi-Linear-48B-A3B-Instruct` | 8 | Paper's primary hybrid; 3:1 KDA-to-MLA architecture |
| H2 (adjacent hybrid) | `nvidia/NVIDIA-Nemotron-Nano-9B-v2` | 4 | Already on Stage A's PVC; cheap second data point |
| D1 (dense control) | `Qwen/Qwen2.5-72B-Instruct` | 8 | Largest dense model that fits one box at BF16; paper-faithful "high-Φkv full-attention" control |

Deferred until X-cluster K8s GPU exposure unblocks: Qwen3-235B-A22B (paper's
actual dense control, FP8, TP=16), MiMo-V2-Flash 309B (paper's secondary
hybrid).

**Done when:**
- `prfaas/results/m1.5-vllm-baseline/phase1_phi_kv/{kimi-linear-48b,qwen2.5-72b-instruct,nemotron-nano-9b-v2}.jsonl`
  populated with all 8 context-length cells.
- `COMPARE_TO_PAPER.md` shows our Kimi-Linear Φkv at 32 K within ±20% of the
  paper's Table 6 value, or documents a specific reason for the gap.
- Hybrid Φkv at 32 K is at least 5× lower than dense Φkv at 32 K — the
  paper's qualitative headline, replicated on our own hardware.

**Status (as of 2026-04-20):** **DONE** for the qualitative paper claim;
quantitative diff vs paper Table 6 deferred to Phase 2 prerequisite.
- Kimi-Linear-48B (H1): 8/8 cells, Φkv plateau **5.6–5.8 Gbps** for `l ∈
  [16 K, 65 K]`, 5.25 Gbps at 131 K.
- Nemotron-Nano-9B-v2 (H2): 7/8 cells (probe now skips
  `l ≥ max_position_embeddings - safety`), Φkv plateau **6.5 Gbps** for
  `l ∈ [16 K, 65 K]`.
- Qwen2.5-72B-Instruct (D1): 5/5 cells within stock
  `max_position_embeddings = 32 768`, Φkv plateau **54–56 Gbps**.
- Headline ratio at the only `l` common to all three (16 K):
  **dense / Kimi = 9.3×**, **dense / Nemotron = 8.4×**, both above the
  5× target.
- Wire-feasibility cross-check vs measured 14.7 Gbps WAN: every hybrid
  cell ≤ wire (2.2× to 4× headroom); every dense cell ≫ wire
  (3.6× to 4× over). PD-disagg is feasible on hybrids, infeasible on the
  dense control — matches paper §5.1.
- Full table + per-model JSONL + SGLang server logs:
  [`results/phase1_phi_kv/`](../../results/m1.5-vllm-baseline/phase1_phi_kv/), entry-point
  [`PHI_KV_TABLE.md`](../../results/m1.5-vllm-baseline/phase1_phi_kv/PHI_KV_TABLE.md) and
  [`COMPARE_TO_PAPER.md`](../../results/m1.5-vllm-baseline/phase1_phi_kv/COMPARE_TO_PAPER.md).

### Phase 2 — Analytical Λ_max regenerator (½ day, no GPUs needed)

**Goal:** implement the paper's throughput-at-SLO model (Eq 3-8 in §3 of the
paper) as Python, feed it Phase 1's measured Φkv plus Stage 0a's measured
wire bandwidth (14.7 Gbps median single-flow goodput), regenerate the paper's
Figure 8 with our actual numbers.

Outputs:
- `prfaas/results/phase2_analytical/lambda_max_predictions.csv` — predicted
  Λ_max(BW, SLO) per (model, link bandwidth, RTT, target SLO) cell.
- `prfaas/results/phase2_analytical/PAPER_FIG8_REGEN.png` — paper-style plot.
- A "**which model is the sweet spot for Phase 3?**" pick: the hybrid where
  the analytical model says Λ_max(P) > Λ_max(H) at our measured wire.

This phase is pure code. No new GPUs, no new K8s. It feeds Phase 3.

### Phase 3 — Empirical SGLang+Mooncake PD-disagg (current focus, Apr 2026)

**Status:** manifests authored on `feat/prfaas-m1.5-vllm-baseline` 2026-04-20.
Engine locked on SGLang v0.5.9 (rationale + what's deprecated:
[`docs/40-milestones/m1.5-vllm-baseline/ENGINE_DECISION.md`](../40-milestones/m1.5-vllm-baseline/ENGINE_DECISION.md)).
Model and operating point picked by Phase 2:
[`results/m1.5-vllm-baseline/phase2_analytical/PHASE2_PICK.md`](../../results/m1.5-vllm-baseline/phase2_analytical/PHASE2_PICK.md).

**Two layers, applied in order:**

1. **Single-host PD smoke on g126** —
   [`m1.5-vllm-baseline/k8s/phase3-smoke/`](../../m1.5-vllm-baseline/k8s/phase3-smoke/).
   Prefiller (TP=4) + decoder (TP=4) + sglang_router on the same node,
   Mooncake-TCP over the cluster pod network. Validates the SGLang +
   Mooncake stack end-to-end before we spend cross-DC time. Go/no-go
   gate: smoke probe Job exits PASS.
2. **Cross-DC PD on g304→g126** —
   [`m1.5-vllm-baseline/k8s/phase3-xdc/`](../../m1.5-vllm-baseline/k8s/phase3-xdc/).
   X-side prefiller pinned to g304 with `hostNetwork=true` so the public
   IP `159.26.81.50` is what listens on 30001 (api) and 8998 (Mooncake
   bootstrap). Y-side decoder + router on g126 dial X over the WAN.
   Operator runbook: [`docs/30-operations/XDC_RUNBOOK.md`](../30-operations/XDC_RUNBOOK.md).
   X-cluster pre-flight: [`docs/30-operations/X_CLUSTER_PREFLIGHT.md`](../30-operations/X_CLUSTER_PREFLIGHT.md).

The original Stage B/C/D vLLM scaffolds are **deprecated** for the
paper-replication critical path; their directories now carry a
`DEPRECATED.md` pointing to the SGLang replacements.

The remaining Stage B/C/D goals (clean-wire upper bound, RTT sweep,
real-WAN sweep) move under Phase 3 as concurrency-sweep variants of the
same SGLang stack: smoke for H baseline, xdc for P over real WAN, and
an `xdc-netem` variant (TBD) for the RTT sweep.

### Stage B — All-on-X disagg over IB (DEPRECATED — kept for v0.3 historical context)

**Goal:** establish the **clean-wire upper bound** for `Λ_max(P)`. This is
the floor any cross-DC number is compared against. Run all three configs.

Configs:

- **Config H (baseline):** single vLLM on X1, TP=8, both roles, no
  Mooncake.
- **Config N:** two vLLMs on X1 (4P+4D split), Mooncake over loopback. Tests
  same-machine disagg overhead.
- **Config P:** prefill on X1 TP=8 (`kv_producer`), decode on X2 TP=8
  (`kv_consumer`), Mooncake over IB link as transport. **TCP, not RDMA** —
  we use TCP throughout because that's what we'll have cross-DC. IB-as-RDMA
  here would inflate the baseline unfairly.

Workload: paper-aligned mix from §6. Sweep concurrency `1, 4, 16, 32, 64,
128, 192` per workload. For each `(config, workload)` pair, find the highest
concurrency where TTFT P95 ≤ SLO; report that as Λ_max.

Primary model: **Qwen3-Next-80B-A3B-Instruct**. If Stage 0 says it doesn't
fit the bandwidth budget, fall back to Nemotron-Nano-9B-v2 (note in
SUMMARY.md).

**Done when:**
- Per workload: `Λ_max(P) ≥ 0.9 × Λ_max(H)` on `long_context`. (We're not
  beating H here yet — same hardware budget, plus disagg overhead — but we
  shouldn't be losing more than 10% on a clean wire.)
- KV transfer logged at the goodput floor measured in Stage 0a IB-internal.
- `Λ_max(P) > Λ_max(N)` — disagg on more hardware should beat disagg on
  less hardware. If not, our split is wrong.

### Stage C — All-on-X disagg over IB + emulated WAN (½ day, depends on B)

**Goal:** characterize Λ_max vs *pure* RTT on a clean wire. Isolates the
effect of latency from the noise of public internet.

- Same setup as Stage B (Config P only — H and N are already known from B).
- Apply `prfaas/m1-tcp-bench/scripts/apply_wan.sh` profiles to the IB-bonded
  Ethernet interface (or a veth pair) on both X1 and X2:
  - `lan` (0 ms, 0% loss, uncapped) — control = Stage B Config P.
  - `metro` (2 ms RTT, 100 Gbps cap)
  - `regional` (10 ms, 0.01% loss, 100 Gbps)
  - `continental` (40 ms, 0.05% loss, 40 Gbps)
- Re-run the matrix at each profile.

**Done when:**
- Λ_max(continental) ≥ 0.5 × Λ_max(lan) on `long_context` — i.e. the
  cross-continent case still gives meaningful throughput.
- TTFT(continental) − TTFT(lan) at *light load* (concurrency 4) ≤ 100 ms on
  `long_context` — this is **H3**, on a clean wire.
- The Λ_max-vs-RTT curve has the right shape: roughly flat at low RTT, then
  knees over once KV transfer starts queueing.

### Stage D — True cross-DC over public internet (1–2 days)

**Goal:** the actual paper claim, on the actual hardware. This is the
deliverable.

- Config P on real X↔Y: prefill on X-gateway (TP=8), optionally a second
  prefiller on the other X node sharing the gateway, decode on Y (TP=8).
- Firewall whitelist on Mooncake port; `local_hostname` bound to public IPs.
  No WireGuard (see §2.1).
- `mooncake.json` with `"protocol": "tcp"` and `local_hostname` = public IP
  per node.
- Proxy on Y, user-facing endpoint on Y.
- Run the `(workload × concurrency)` matrix; **repeat each cell at three
  different wall-clock times** (matching Stage 0's variance window).
- For each cell: log measured RTT (`ss -i`) and effective bandwidth (KV
  bytes shipped / KV transfer wall time) so we can correlate any TTFT
  outlier with a bandwidth dip.

We also re-run **Config H on Y** (same workload, same concurrency sweep) so
we have the head-to-head Λ_max(P) / Λ_max(H) ratio. Config N on Y is
optional in Stage D (collected if time permits).

**Done when:**
- We can write a one-paragraph conclusion of the form: *"On
  Qwen3-Next-80B-A3B over [N ms RTT, M Gbps] real public internet between
  cluster X (16 H100) and cluster Y (8 H100), routing prefill to X lets Y
  sustain X% more concurrent users at TTFT-P95-SLO 2 s on the
  `long_context` workload, vs Y alone. The gain is Y% on `chat_balanced`,
  −Z% on `code_complete` (output-bound)."*
- Median across the 3 time-of-day repeats is reported, with min/max as
  error bars.
- Stage D Λ_max(P) is within `Stage C(closest WAN profile) ± 25%`. If not,
  the gap is the "public-internet noise tax" and is reported as a
  conditional finding.

If Stage D shows Λ_max(P) < Λ_max(H) at our measured bandwidth, the paper's
claim is conditional — true only above some bandwidth threshold we didn't
hit. That's still a publishable finding (it pins down the breakeven).

## 6. Workloads

Two layers: a small fixed grid for cross-stage comparability, plus a
paper-aligned mixed trace for Stage D's headline number.

### 6.1 Fixed grid (used Stages B, C, D)

All driven by `vllm/benchmarks/benchmark_serving.py --dataset-name random`
via `benchmarks.sh`. Four points in the input/output space because they
expose different bottlenecks.

| Name | Input tok | Output tok | Exercises | TTFT SLO |
|---|---|---|---|---|
| `chat_balanced` | 1024 | 256 | balanced; sanity check | 1.0 s |
| `long_context` | 16384 | 256 | prefill-dominated, **paper's main case** | 2.0 s |
| `rag_summary` | 8192 | 512 | mixed | 1.5 s |
| `code_complete` | 4096 | 32 | output-light, prefill-heavy | 1.5 s |

Concurrency sweep per workload: `1, 4, 16, 32, 64, 128, 192`. Concurrency is
how we *find* Λ_max — for each config, we report the highest concurrency
where TTFT P95 ≤ SLO.

### 6.2 Mixed trace (Stage D headline)

The PrfaaS paper's Λ_max number comes from a real production trace
distribution. We don't have those traces, but we approximate with a mixed
workload that matches the paper's stated input-length distribution shape:
mean ~3K, P95 ~30K, long-tail to 100K, output mean ~200 tokens.

Implementation: run three `benchmark_serving.py` instances in parallel with
different `--random-input-len` settings, weighted ~70% / 25% / 5% by request
count to match the distribution percentiles. Concrete invocation in
`prfaas/m1.5-vllm-baseline/scripts/run_mixed_trace.sh`.

This is the *only* workload where we report the head-to-head Λ_max(P) /
Λ_max(H) ratio as a single number for the paper-style result.

### 6.3 Models

| Tier | Model | Why | TP |
|---|---|---|---|
| Smoke | `nvidia/Nemotron-Nano-9B-v2` | Hybrid Mamba2+attention, fits TP=1, fast iteration on Stage A | 1 or 4 |
| **Primary** | **`Qwen/Qwen3-Next-80B-A3B-Instruct`** | Hybrid (gated DeltaNet + standard attn), MoE 80B/3B, the canonical open hybrid model. Apache 2.0. | 8 |
| Stretch | TBD second hybrid (MiniMax-M2 or successor) | Cross-check H2 isn't a Qwen3-Next-specific artifact | 8 |

Dense-attention models are intentionally excluded; see H6 and `SIZING.md`
for the bandwidth-feasibility analysis that rules them out.

## 7. Metrics and storage layout

Every cell of the matrix produces:

- **Λ_max derivation table:** one row per `(config, workload, concurrency)`
  with TTFT P50/P95/P99, TPOT P50, E2EL P50, output throughput, KV transfer
  bytes/time/Gbps. From this we extract Λ_max per `(config, workload)`.
- Raw vLLM serving JSON, one per cell, under
  `prfaas/results/m1.5-vllm-baseline/<stage>/<model>/<config>/<workload>/concurrency=N/`.
- A consolidated CSV per stage with columns:
  `stage, config, model, workload, input_len, output_len, concurrency,
   wan_profile, wall_clock_iso, ttft_p50_ms, ttft_p95_ms, ttft_p99_ms,
   tpot_p50_ms, e2el_p50_ms, output_throughput_tok_s,
   kv_xfer_gbps, kv_xfer_time_ms_p50, slo_met`.
- A `summary.md` per stage with three plots:
  1. TTFT-P95 vs concurrency, three configs overlaid, per workload.
  2. Λ_max(config) bar chart, per workload.
  3. KV-transfer-Gbps vs concurrency (sanity check for bandwidth saturation).
- A `repro.sh` per cell that re-runs that exact configuration.

We reuse the M1 result schema where it overlaps (`p50_us`, `goodput_gbps`)
so M1 and M1.5 plots are directly comparable.

## 8. Baselines

The Λ_max table for every workload reports four numbers (chain decomposes
the cost):

1. **Config H, Stage B (collocated on X1):** ideal ceiling, biggest hardware
   pool.
2. **Config H, Stage D (collocated on Y):** the apples-to-apples decode-DC
   baseline that PrfaaS-on-our-hardware must beat.
3. **Config P, Stage B (disagg on X over IB-as-TCP):** clean-wire ceiling
   for the disaggregated system.
4. **Config P, Stage D (disagg over real public internet):** the headline
   number.

The headline ratio is **(4) / (2)** — "PrfaaS-on-our-hardware vs our
hardware alone." Anything > 1 confirms H2 at our bandwidth class.

The chain `(2 → 4)` decomposes attribution: any gap is "what the cross-DC
prefill bought us, net of the WAN cost."

## 9. Updated roadmap

This doc inserts a new **M1.5** between the existing M1 (transport-only
bench, done) and M2 (smart router, planned).

| Milestone | Goal | Branch | Status |
|---|---|---|---|
| **M1** | Cross-DC TCP transfer baseline (synthetic) | `feat/prfaas-m1-tcp-bench` | ✅ |
| **M1.5** | Cross-DC vLLM serving baseline on hybrid models. Three-config Λ_max comparison. Stages 0–D of this doc. | `feat/prfaas-m1.5-vllm-baseline` *(new)* | 📋 active |
| **M2** | Length-based router prototype, replacing round-robin proxy | `feat/prfaas-m2-router` | 📋 |
| **M3** | Hybrid prefix pool (cross-DC prefix cache) | `feat/prfaas-m3-hybrid-pool` | 📋 |
| **M4** | Bandwidth-aware controller (closed loop) | `feat/prfaas-m4-controller` | 📋 |

`prfaas/README.md` is updated alongside this revision to reflect the
locked-in scope.

## 10. Open questions

### Answered (locked in for M1.5)

- **Q1. ✅ Link between X and Y.** Different DCs, public internet, no
  dedicated inter-DC connection. Drives §2.1.
- **Q2. ✅ Shared storage.** Cluster X has VAST; cluster Y has local NVMe.
  Two independent download steps in `node_setup.sh`.
- **Q4. ✅ Model class.** Hybrid-attention only.
  Primary = Qwen3-Next-80B-A3B-Instruct; smoke =
  Nemotron-Nano-9B-v2. Dense models analytically ruled out in `SIZING.md`.
- **Q5. ✅ Primary metric.** Λ_max(SLO). Per-request TTFT/TPOT/ITL/E2EL
  reported but not gating.
- **Q11. ✅ WireGuard?** Not in the benchmark path. Firewall whitelist +
  interface bind instead. WireGuard delta measured in Stage 0b as a
  one-off cost number.

### Deferred (decide right before the relevant stage)

- **Q3. vLLM version pin.** Two candidates:
  - vLLM v0.x (≤0.15) + `MooncakeStoreConnector`: explicit `"protocol":
    "tcp"` knob, matches existing `benchmarks.sh`.
  - vLLM v1.x + `MooncakeConnector`: newer, but the TCP path is less
    documented.

  Decide right before Stage A by running both for the smoke curl. Whichever
  produces a clean KV-transfer log over TCP wins. If both work, prefer v1
  for forward-compatibility with M2's router.

### Open (need answer from you to start Stage 0)

- **Q6. Geographic distance / expected RTT between X and Y.** Same metro
  (~5 ms), same country (~30 ms), trans-continental (~80 ms),
  trans-oceanic (~150–200 ms)? Sets which `tc netem` profile in Stage C is
  the closest analog to Stage D, and feeds the SIZING.md breakeven check.
- **Q7. Public IP availability.** Does at least one node in each cluster
  have a public IPv4 (or IPv6) reachable from the other side? If not, we
  need a relay VM in a third location (cheap; document but not pre-built).
- **Q8. Firewall control.** Who controls the firewall on each side and can
  punch a single TCP port (Mooncake's `"port": <NNNNN>`) from the other
  cluster's source IP? This is the *only* network change needed for the
  benchmark path.
- **Q9. Bandwidth budget.** Is there an MB/GB cap on cross-DC traffic for
  this experiment? Stage D on Qwen3-Next at full concurrency on
  `long_context` could ship ~10 TB across the whole matrix.
- **Q10. GPU availability windows.** Can we hold all three nodes for a full
  day each for Stages B+C, plus 24 hours of intermittent use across a day
  for Stage D's time-of-day variance? Or do we need to checkpoint/resume
  between time-of-day cells?
- **Q12. SSH access.** What's the SSH path (jumphost? direct?) and the
  username/key the agent should use to drive each cluster? See
  `prfaas/docs/40-milestones/m1.5-vllm-baseline/PREFLIGHT.md` for the full intake form.

Once Q6–Q10 and Q12 are answered, the next concrete deliverable is running
`prfaas/m1.5-vllm-baseline/scripts/preflight_check.sh` against both
clusters; everything from there is scripted.
