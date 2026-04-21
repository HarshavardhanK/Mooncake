# Phase 3 cross-DC runbook (XDC_RUNBOOK)

**Goal:** end-to-end run of `prfaas/m1.5-vllm-baseline/k8s/phase3-xdc/`
from cold start to Λ_max sweep, with explicit go/no-go gates at every
step. Time budget: ~90 minutes wall-clock if everything works first try
(model staging on X dominates), or ~3 hours including the Λ_max sweep.

> Engine and model rationale:
> [`ENGINE_DECISION.md`](../40-milestones/m1.5-vllm-baseline/ENGINE_DECISION.md),
> [`PHASE2_PICK.md`](../../results/m1.5-vllm-baseline/phase2_analytical/PHASE2_PICK.md).

## Pre-flight (must be green before §1)

* X-side full pre-flight:
  [`X_CLUSTER_PREFLIGHT.md`](X_CLUSTER_PREFLIGHT.md). All 9 steps must
  pass, including running the firewall script on g304 once.
* Y-side smoke run (single-host PD on g126):
  [`prfaas/m1.5-vllm-baseline/k8s/phase3-smoke/README.md`](../../m1.5-vllm-baseline/k8s/phase3-smoke/README.md).
  The smoke probe Job must exit `PASS`. If it does not, **stop** — the
  cross-DC variant cannot work if the local PD path doesn't.
* Y-side Phase 1 model PVC (`model-weights-phase1`) must exist on g126
  with Kimi-Linear staged. Confirmed during the smoke run above.

Set the contexts you'll use throughout this runbook:

```bash
export KCTX_X="<your-X-context>"      # cluster X (g304)
export KCTX_Y="aln1-beta-harsha-g126-beta"  # cluster Y (g126)
export NS_X="prfaas-staged"
export NS_Y="default"
```

## §1 — Stage the model on X (~30 min, 49 GiB download)

```bash
kubectl --context "${KCTX_X}" -n "${NS_X}" \
  apply -f prfaas/m1.5-vllm-baseline/k8s/phase3-xdc/x/00-configmap.yaml
kubectl --context "${KCTX_X}" -n "${NS_X}" \
  apply -f prfaas/m1.5-vllm-baseline/k8s/phase3-xdc/x/01-model-staging-job-g304.yaml

kubectl --context "${KCTX_X}" -n "${NS_X}" \
  wait --for=condition=complete --timeout=45m \
    job/model-staging-kimi-linear-48b-x
```

**Go/no-go:** Job condition `Complete=True`. If `Failed=True`, inspect:

```bash
kubectl --context "${KCTX_X}" -n "${NS_X}" \
  logs job/model-staging-kimi-linear-48b-x
ssh vpsupport@159.26.81.50 'ls -lh /scratch/models/moonshotai_Kimi-Linear-48B-A3B-Instruct'
```

Common failure modes:

| Symptom | Fix |
|---|---|
| `Disk full` | `df -h /scratch` on g304; free old models, re-apply |
| HF rate-limit / 5xx | Re-apply Job (idempotent on success-skip); check `huggingface_hub` for known outages |
| Pod stuck `ContainerCreating` | `kubectl describe pod`; usually image pull on `python:3.12-slim` — wait or pre-pull |

## §2 — Apply the X-side prefiller (~10-15 min to Ready)

```bash
kubectl --context "${KCTX_X}" -n "${NS_X}" \
  apply -f prfaas/m1.5-vllm-baseline/k8s/phase3-xdc/x/10-prefiller.yaml

kubectl --context "${KCTX_X}" -n "${NS_X}" \
  rollout status deploy/prefiller-phase3-xdc --timeout=20m
```

**Go/no-go:** Deployment Available. From your workstation, confirm the
prefiller's API and bootstrap port are reachable from the public Internet
**and** specifically from g126's egress IP (147.185.40.126):

```bash
# Workstation reach (general Internet — should be filtered by firewall):
nc -zv 159.26.81.50 30001 || echo "expected: filtered (firewall scopes to g126 only)"

# From inside Y, the only place that should reach:
kubectl --context "${KCTX_Y}" -n "${NS_Y}" run xdc-reach-check \
  --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  sh -c 'nc -zv 159.26.81.50 30001 && nc -zv 159.26.81.50 8998 && curl -fsS http://159.26.81.50:30001/health'
```

The reach-check pod must print **both** ports `succeeded` and `/health`
returning a 200. If 8998 succeeds but 30001 doesn't, re-run
`firewall/g304-phase3-iptables.sh` (it adds 30001).

## §3 — Apply the Y-side decoder + router (~10-15 min to Ready)

```bash
kubectl --context "${KCTX_Y}" -n "${NS_Y}" \
  apply -f prfaas/m1.5-vllm-baseline/k8s/phase3-xdc/y/00-configmap.yaml
kubectl --context "${KCTX_Y}" -n "${NS_Y}" \
  apply -f prfaas/m1.5-vllm-baseline/k8s/phase3-xdc/y/20-decoder.yaml
kubectl --context "${KCTX_Y}" -n "${NS_Y}" \
  apply -f prfaas/m1.5-vllm-baseline/k8s/phase3-xdc/y/30-router.yaml

kubectl --context "${KCTX_Y}" -n "${NS_Y}" \
  rollout status deploy/decoder-phase3-xdc --timeout=20m
kubectl --context "${KCTX_Y}" -n "${NS_Y}" \
  rollout status deploy/router-phase3-xdc --timeout=10m
```

**Go/no-go:** both Deployments Available. The decoder pod's startup
script does a TCP probe to `159.26.81.50:8998` first; if that probe
fails 60×5s, the pod exits with code 12 — that is a firewall problem,
not a SGLang problem. Re-check §2.

## §4 — Cross-DC smoke probe (~30s once everything's up)

```bash
kubectl --context "${KCTX_Y}" -n "${NS_Y}" \
  apply -f prfaas/m1.5-vllm-baseline/k8s/phase3-xdc/y/90-smoke-job.yaml
kubectl --context "${KCTX_Y}" -n "${NS_Y}" \
  wait --for=condition=complete --timeout=10m job/phase3-xdc-smoke-probe
kubectl --context "${KCTX_Y}" -n "${NS_Y}" \
  logs job/phase3-xdc-smoke-probe
```

**Go/no-go:** the probe logs end with `[probe-xdc] PASS` and an elapsed
time. The first request includes warm-up (CUDA graph capture on Y, KV
transfer setup over WAN); typical first-request elapsed is 3-15 seconds.
Steady-state TTFT (the Phase 2 prediction) is sub-second.

If the probe fails:

| Symptom | Where to look |
|---|---|
| `router /health` never up | `kubectl logs -l app=router-phase3-xdc` — usually waiting for prefill or decode `/health` |
| Probe HTTP 502/503 | `kubectl logs -l app=router-phase3-xdc` for the upstream that errored |
| Probe HTTP 200 but empty content | `kubectl logs -l app=decoder-phase3-xdc` for KV transfer errors |
| Probe times out | `tcpdump` on g304 for traffic from 147.185.40.126; if absent, firewall/route problem |

## §5 — Λ_max concurrency sweep

After the smoke passes, run the bench script. (See
`prfaas/m1.5-vllm-baseline/scripts/run_concurrency_sweep.sh` — adapt to
target the Phase 3 router endpoint via port-forward or in-cluster.)

```bash
# Port-forward the router locally:
kubectl --context "${KCTX_Y}" -n "${NS_Y}" \
  port-forward svc/router-xdc 8000:8000 &

# Sweep concurrency at the Phase 2 operating point (l = 8K, peak speedup):
PRFAAS_ROUTER_URL=http://localhost:8000 \
PRFAAS_INPUT_LEN=8192 \
PRFAAS_OUTPUT_LEN=64 \
PRFAAS_CONCURRENCY="1,2,4,8,16,32,64" \
PRFAAS_NUM_REQUESTS=200 \
PRFAAS_RESULT_DIR=prfaas/results/m1.5-vllm-baseline/phase3_xdc/l8k \
bash prfaas/m1.5-vllm-baseline/scripts/run_concurrency_sweep.sh
```

Repeat at `l = 16384` (paper-aligned long_context) into
`prfaas/results/m1.5-vllm-baseline/phase3_xdc/l16k`.

**Go/no-go for Λ_max:** Phase 2 predicted **16.00× speedup at `l = 8K`**
and **7.94× at `l = 16K`**. Empirical Λ_max(P)/Λ_max(H) within ±50% of
those is a strong replication; >2× off in either direction is a
methodology problem (re-check `--mem-fraction-static`, decoder batch
size, RTT, bandwidth at the time of the run).

The Λ_max(H) baseline runs against the smoke topology
(`phase3-smoke/`) on g126 alone — apply it after tearing down the
cross-DC stack to free the GPUs.

## §6 — Cleanup

```bash
# Y first (frees GPUs and stops dialing g304):
kubectl --context "${KCTX_Y}" -n "${NS_Y}" delete deploy,svc,job,cm \
  -l prfaas.experiment/phase=3-xdc
# X second:
kubectl --context "${KCTX_X}" -n "${NS_X}" delete deploy,job,cm \
  -l prfaas.experiment/phase=3-xdc
```

The Phase 1 PVC on Y and the staged model on g304's /scratch are
intentionally not touched. Re-runs reuse them.

## Failure mode → action (cross-DC specific)

See [`prfaas-smoke README §Failure mode`](../../m1.5-vllm-baseline/k8s/phase3-smoke/README.md#failure-mode--action)
for engine-level issues that aren't cross-DC-specific.

| Symptom | Likely cause | Fix |
|---|---|---|
| Decoder pod exits with code 12 | Firewall on g304 not open for 8998 from 147.185.40.126 | Re-run `firewall/g304-phase3-iptables.sh` on g304 |
| Decoder pod exits with code 12 but firewall is open | Y's egress IP changed (rare) | `curl ifconfig.me` from a Y pod; update PEER_IP in firewall script |
| Mooncake transport hangs after bootstrap | TCP 13000-17000 blocked | Stage 0a's rule may have been wiped; re-apply Stage 0a iptables script |
| WAN throughput ≪ Stage 0a baseline | `MC_TCP_ENABLE_CONNECTION_POOL=0` somewhere | Confirm env on both pods (`kubectl exec ... env \| grep MC_`) |
| Mooncake picks RDMA instead of TCP | `MOONCAKE_PROTOCOL=tcp` not honored | Set the explicit `--disaggregation-transfer-backend mooncake` flag (already in our manifests); also `kubectl exec ... env \| grep MOONCAKE_PROTOCOL` |
| TTFT 5-10× the Phase 2 prediction | RTT spike on the wire | `ping -c 50 159.26.81.50` from Y; if RTT > 50 ms, retry later |
