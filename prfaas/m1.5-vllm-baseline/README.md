# M1.5 — Cross-DC vLLM serving baseline (hybrid models, Λ_max-at-SLO)

This is the milestone that **proves or refutes** the central PrfaaS claim on
real GPUs and real wire. It picks up where M1 (synthetic transport bench)
left off and stops short of M2 (smart router): we use a stock round-robin
proxy, the existing Mooncake `MooncakeStoreConnector` (or `MooncakeConnector`
on vLLM v1, decided in Stage A), and pin everything else.

> **Read first:** [`prfaas/EXPERIMENT_PLAN.md`](../EXPERIMENT_PLAN.md). This
> README is the *operational* layer; the plan is the *why*.

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
| 0a   | Real WAN transport baseline (g126 ↔ g304, public Internet) | ✅ window 1 done — see [`results/stage0a/SUMMARY.md`](./results/stage0a/SUMMARY.md). Median 14.7 Gbps / RTT 29.75 ms. → primary model decided in [`results/stage0a/MODEL_DECISION.md`](./results/stage0a/MODEL_DECISION.md): `nvidia/NVIDIA-Nemotron-Nano-9B-v2`, 2 prefill replicas. Two more time-of-day windows pending (Stage 0a-bis). |
| 0b   | WireGuard tunnel ablation (one-off cost number) | 📋 |
| A    | Single-machine 1P1D smoke on Y (Nemotron-Nano-9B-v2) | 📋 unblocked — bring up Mooncake master + vLLM 1P1D on g126 over loopback |
| B    | X1↔X2 over IB-as-TCP, 3-config Λ_max sweep | 📋 blocked on X-side GPU access (k8s GPU Operator owns devices today; see [`discovery/VP_SUPPORT_TICKET.md`](./discovery/VP_SUPPORT_TICKET.md)) |
| C    | Stage B + `tc netem` continental profile | 📋 |
| D    | Real cross-DC over public internet, three time-of-day repeats | 📋 |

When a stage is `🔄`, the working CSV is at
`results/<stage>/<model>/<config>/<workload>/lambda_max.csv`. When green,
`results/<stage>/SUMMARY.md` has the headline ratio and plots.
