# M1.5 — Cross-DC vLLM serving baseline (Λ_max-at-SLO)

This is the milestone that **proves or refutes** the central PrfaaS claim on
real GPUs and real wire. It picks up where M1 (synthetic transport bench)
left off and stops short of M2 (smart router): we use the bundled vLLM v1
`MooncakeConnector` (with our in-place `SupportsHMA` patch), a round-robin
proxy from `mooncake-transfer-engine`, and pin everything else.

> **Read first:** [`prfaas/docs/00-overview/EXPERIMENT_PLAN.md`](../../00-overview/EXPERIMENT_PLAN.md). This
> README is the *operational* layer; the plan is the *why*.

> **Pivot to Kubernetes (2026-04-20):** the original RUNBOOK targeted
> direct host installs. After the user requested a K8s-only path, all
> Stage A/B/D execution moved into [`k8s/`](../../../m1.5-vllm-baseline/k8s/) with one subdirectory
> per stage. The host-script tree under `scripts/` is preserved for
> reference (e.g. `transfer_engine_bench` Stage 0a still drives the
> wire), but is no longer the active deployment surface for the vLLM
> serving stages.

> **Smoke-model pivot (2026-04-20):** Stage A intended to use
> Nemotron-Nano-9B-v2 (Mamba2+attn hybrid, the paper's claimed sweet
> spot). We empirically confirmed that vLLM v0.19.1's MooncakeConnector
> cannot serve hybrid models even with `SupportsHMA` patched —
> `TpKVTopology` calls `get_kv_cache_shape()` on every layer's attention
> backend and the Mamba2 backend raises `NotImplementedError`. Stage A
> now runs on **Qwen2.5-7B-Instruct** (dense, gateless, ~15 GiB, TP=4)
> for the wire baseline. Hybrid follow-up tracked in
> [`../PAPER_MODEL_PLAN.md`](../../10-paper/PAPER_MODEL_PLAN.md). Full evidence in
> [`../../../results/m1.5-vllm-baseline/stageA/`](../../../results/m1.5-vllm-baseline/stageA/).

## Reading order

1. **[`PREFLIGHT.md`](./PREFLIGHT.md)** — what the agent needs from you to
   start: SSH paths, public IPs, firewall control, model staging paths,
   GPU availability windows. **Fill this in first.** Stage 0 is blocked
   until it's done.
2. **[`SIZING.md`](./SIZING.md)** — back-of-envelope bandwidth math: which
   model fits at which measured WAN bandwidth. This is what tells us if
   Qwen3-Next-80B-A3B is the right primary, or if we need to drop to
   Nemotron-Nano-9B-v2 after Stage 0.
3. **[`RUNBOOK.md`](./RUNBOOK.md)** — exact step-by-step commands per stage.
   Stages 0 → A → B → C → D, with go/no-go checkpoints. Every command is
   copy-pasteable; every script is parameterized by env vars set in
   `scripts/lib/common.sh` (which sources from `~/.prfaas_env` if present).

## Layout

```
prfaas/m1.5-vllm-baseline/
├── README.md                  # this file
├── PREFLIGHT.md               # intake form
├── SIZING.md                  # bandwidth-feasibility math
├── RUNBOOK.md                 # per-stage commands
├── configs/
│   ├── mooncake.localhost.json.template   # Stage A (single-machine smoke)
│   ├── mooncake.x_internal.json.template  # Stage B/C (X1 ↔ X2 over IB)
│   ├── mooncake.x_gateway.json.template   # Stage D (X-gateway, public IP)
│   └── mooncake.y.json.template           # Stage D (Y, public IP)
├── scripts/
│   ├── lib/
│   │   └── common.sh              # shared env, role detection, helpers
│   ├── preflight_check.sh         # validate the topology before Stage 0
│   ├── node_setup.sh              # install vLLM + Mooncake + fetch weights
│   ├── firewall_setup.sh          # whitelist Mooncake ports per side
│   ├── wireguard_setup.sh         # OPTIONAL, only for Stage 0b ablation
│   ├── start_master.sh            # mooncake_master + etcd
│   ├── start_prefiller.sh         # vLLM kv_producer
│   ├── start_decoder.sh           # vLLM kv_consumer
│   ├── start_proxy.sh             # round-robin proxy
│   ├── stop_all.sh                # kill everything by port
│   ├── run_concurrency_sweep.sh   # one workload, sweep concurrency, find Λ_max
│   ├── run_stage_0.sh             # transport bench over real WAN
│   ├── run_stage_a.sh             # single-machine smoke
│   ├── run_stage_b.sh             # X1↔X2 over IB, three-config sweep
│   ├── run_stage_c.sh             # Stage B + tc netem profiles
│   ├── run_stage_d.sh             # real cross-DC, three time-of-day repeats
│   ├── run_mixed_trace.sh         # paper-style mixed-length workload
│   └── extract_lambda_max.py      # walk a results dir, output Λ_max table
└── results/
    ├── README.md                  # CSV schema + directory layout
    └── .gitignore                 # generated artifacts not committed
```

## Status

| Stage | Goal | Status |
|---|---|---|
| 0a   | Real WAN transport baseline (g126 ↔ g304, public Internet) | ✅ window 1 done — see [`results/stage0a/SUMMARY.md`](../../../results/m1.5-vllm-baseline/stage0a/SUMMARY.md). Median 14.7 Gbps / RTT 29.75 ms. Two more time-of-day windows still pending. |
| 0b   | WireGuard tunnel ablation (one-off cost number) | 📋 |
| A    | Single-machine 1P1D smoke on Y (g126), K8s | ✅ **GREEN on Qwen2.5-7B-Instruct** — patched MooncakeConnector + vllm-v1 + bundled proxy → HTTP 200 / content `OK`. Negative finding on Nemotron-Nano-9B-v2 (vLLM 0.19.1 MooncakeConnector cannot serve Mamba2+attn hybrids). Evidence: [`../../../results/m1.5-vllm-baseline/stageA/`](../../../results/m1.5-vllm-baseline/stageA/). Caveat: bundled proxy doesn't drive full PD protocol — see [`../../../results/m1.5-vllm-baseline/stageA/SUMMARY.md`](../../../results/m1.5-vllm-baseline/stageA/SUMMARY.md). |
| B    | g304 prefiller ↔ g307 decoder over X-cluster internal LACP, 3-config Λ_max sweep | 🔄 **manifests written** in [`k8s/stageB/`](../../../m1.5-vllm-baseline/k8s/stageB/), pending `kubectl apply` |
| C    | Stage B + `tc netem` continental profile | 📋 |
| D    | Real cross-DC over public internet (X-cluster prefiller ↔ g126 decoder), three time-of-day repeats | 🔄 **manifests written** in [`k8s/stageD/`](../../../m1.5-vllm-baseline/k8s/stageD/), pending firewall whitelist + `kubectl apply` |

When a stage is `🔄`, the working CSV is at
`results/<stage>/<model>/<config>/<workload>/lambda_max.csv`. When green,
`results/<stage>/SUMMARY.md` has the headline ratio and plots.

### Active deployment surface

```
prfaas/m1.5-vllm-baseline/k8s/
├── DISCOVERY.md       # K8s discovery on both clusters (RBAC, SC, GPU op, CNI, etc.)
├── stageA/            # single-host PD smoke on g126 (Y cluster)   ✅ green
├── stageB/            # internal-X PD-disagg sweep                   🔄 ready
└── stageD/            # cross-DC PD-disagg                           🔄 ready
```

Per-stage README in each directory is the operational entry point (kubeconfig
expectations, apply order, smoke command, tear-down).
