# Phase 3 cross-DC — PD-disaggregation across X (g304) and Y (g126)

The actual headline experiment for the paper-replication arm.

* **X (cluster `prfaas-staged` namespace, node `g304`, public IP
  `159.26.81.50`)** — runs the SGLang prefiller on 8 H100s with
  `--disaggregation-mode prefill`. Pod is on `hostNetwork=true` so its
  SGLang API (`30001`) and Mooncake bootstrap (`8998`) listen on g304's
  public interface.
* **Y (cluster `aln1-beta-harsha-g126-beta`, namespace `default`, node
  `g126`)** — runs the SGLang decoder on 8 H100s with
  `--disaggregation-mode decode` and the `sglang_router` with
  `--pd-disaggregation`. Decoder dials `g304:8998` over the WAN for
  Mooncake KV transfer; router dials `g304:30001` over the WAN for prefill.

Engine choice and rationale:
[`prfaas/docs/40-milestones/m1.5-vllm-baseline/ENGINE_DECISION.md`](../../../docs/40-milestones/m1.5-vllm-baseline/ENGINE_DECISION.md).
Model pick rationale (Kimi-Linear-48B, peak speedup at `l = 8K`):
[`PHASE2_PICK.md`](../../../results/m1.5-vllm-baseline/phase2_analytical/PHASE2_PICK.md).

Use the runbook to apply this stack:
[`prfaas/docs/30-operations/XDC_RUNBOOK.md`](../../../docs/30-operations/XDC_RUNBOOK.md).

## File map

```
phase3-xdc/
├── README.md                      ← you are here
├── firewall/
│   └── g304-phase3-iptables.sh    ← operator runs this on g304 once
├── x/                             ← apply on cluster X (kubectl --context <X>)
│   ├── 00-configmap.yaml
│   ├── 01-model-staging-job-g304.yaml
│   └── 10-prefiller.yaml
└── y/                             ← apply on cluster Y (--context aln1-beta-harsha-g126-beta)
    ├── 00-configmap.yaml
    ├── 20-decoder.yaml
    ├── 30-router.yaml
    └── 90-smoke-job.yaml
```

The two sides are intentionally separate kubectl contexts. Do not try
`kubectl apply -f phase3-xdc/` from a single context — it will fail
(different namespaces, different clusters).

## Pre-flight checklist (do these before applying)

See [`X_CLUSTER_PREFLIGHT.md`](../../../docs/30-operations/X_CLUSTER_PREFLIGHT.md)
for the full checklist. The short version:

1. Run the smoke first. [`../phase3-smoke/README.md`](../phase3-smoke/README.md).
   If single-host PD doesn't work, cross-DC won't either.
2. Confirm the X kubeconfig is in your `KUBECONFIG` and the context name
   is known. The `prfaas-staged` namespace already has the operator-owned
   RoleBindings from Stage D; we re-use them.
3. Confirm `g304` exposes `nvidia.com/gpu: 8` allocatable.
4. Confirm Stage 0a's iptables rules (TCP 13000-17000 from
   `147.185.40.126/32`) are still active on g304.
5. Ship `firewall/g304-phase3-iptables.sh` to g304 and run it as root
   (one-time; idempotent).
6. Confirm Phase 1's PVC `model-weights-phase1` on g126 has the Kimi
   model staged.

## Apply order — see XDC_RUNBOOK.md

The exact go/no-go sequence (apply X manifests → wait staging → apply
prefiller → apply Y manifests → cross-DC smoke → Λ_max sweep) lives in
[`prfaas/docs/30-operations/XDC_RUNBOOK.md`](../../../docs/30-operations/XDC_RUNBOOK.md).
