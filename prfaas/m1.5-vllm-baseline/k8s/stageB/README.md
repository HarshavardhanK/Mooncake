# Stage B — IB-as-TCP three-config Λ_max sweep on cluster X (Kubernetes)

**Purpose.** Establish the clean-wire upper bound for Λ_max(P) on the
PrfaaS pattern, on real GPUs, deployed entirely through `kubectl apply`
(no host installs — DISCOVERY.md §pivot-trigger).

Stage B sweeps **three configurations** on `nvidia/NVIDIA-Nemotron-Nano-9B-v2`
across cluster X (g304 + g307, 8× H100/node, bootnet 10.10.34.0/24 at
100 Gbps LACP, ~0.084 ms RTT). Mooncake transport is **TCP-via-IP** (the
"IB-as-TCP" path, Cilium pod overlay riding on bootnet); RDMA is
deferred to Stage B+.

The headline numbers we want:
- `Λ_max(P) ≥ 0.9 × Λ_max(H)` on `long_context` — disagg pays for itself
- `Λ_max(P) > Λ_max(N)`         — cross-node disagg beats single-node disagg
- `|Λ_max(H) − Λ_max(N)| ≲ 5%`  — g304 and g307 are interchangeable nodes

If any of these fail, see [STAGE_B_PLAN.md §Risk register](./STAGE_B_PLAN.md#risk-register).

---

## Topology

All three configs live in the `prfaas-stageb` namespace, with names
suffixed `-h | -n | -p` so they can coexist or be torn down individually
via the `prfaas.config` label.

### Config H — homogeneous, both pods on g304

```
                                    g304 (10.10.34.2)
                                    ┌──────────────────────────────────────────┐
   client ──── proxy-h:8000 ─────▶  │  proxy-h          (pod, no GPU)         │
   (bench Job)                      │   ├─▶ prefiller-h-api:8010 ─▶ prefiller │
                                    │   │                              GPU 0–3 │
                                    │   └─▶ decoder-h-api:8020 ─▶ decoder    │
                                    │                                GPU 4–7 │
                                    │  prefiller-h ◀──── KV via headless     │
                                    │             :8998   prefiller-h-bootstrap│
                                    │             (loopback within g304)     │
                                    └──────────────────────────────────────────┘
```

### Config N — homogeneous, both pods on g307 (sanity baseline for H)

```
                                    g307 (10.10.34.5)
                                    ┌──────────────────────────────────────────┐
   client ──── proxy-n:8000 ─────▶  │  proxy-n          (pod, no GPU)         │
                                    │   ├─▶ prefiller-n-api:8010 ─▶ prefiller │
                                    │   │                              GPU 0–3 │
                                    │   └─▶ decoder-n-api:8020 ─▶ decoder    │
                                    │                                GPU 4–7 │
                                    │  prefiller-n ◀──── KV via headless     │
                                    │             :8998   prefiller-n-bootstrap│
                                    │             (loopback within g307)     │
                                    └──────────────────────────────────────────┘
```

### Config P — PrfaaS pattern, prefiller on g304, decoder on g307

```
       g304 (10.10.34.2)                                  g307 (10.10.34.5)
       ┌─────────────────────────┐                        ┌─────────────────────────┐
       │ prefiller-p             │                        │ proxy-p (pod, no GPU)   │
       │   GPU 0–3, TP=4         │                        │  ├─▶ prefiller-p-api    │
       │   :8010 (api)           │ ◀── prefiller-p-api ───┤  │   8010 (cross-node)  │
       │   :8998 (bootstrap)     │                        │  │                      │
       │                         │ ◀── prefiller-p-       │  └─▶ decoder-p-api      │
       │                         │     bootstrap (8998,   │      :8020 (loopback)   │
       │                         │     headless ClusterIP)│                          │
       └─────────────────────────┘                        │ decoder-p              │
              ▲                                           │   GPU 0–3, TP=4         │
              │                                           │   :8020 (api)           │
              │       Cilium pod overlay (bootnet         │                          │
              └────── underlay, 100 Gbps LACP) ──────────▶└─────────────────────────┘
                       ── KV cache (TCP) flows ──▶
```

The KV cache crosses nodes via the regular Cilium-routed ClusterIP path.
No `hostNetwork`, no NodePort. Stage B+ will add RDMA; Stage D will add
`hostNetwork: true` for the public-internet hop.

---

## Files in this directory

| File                                    | Purpose |
|-----------------------------------------|---------|
| `00-namespace.yaml`                     | Namespace `prfaas-stageb` + ConfigMap `prfaas-stageb-env` (model, ports, SLOs, bench knobs) |
| `01-model-staging-job-g304.yaml`        | One-shot HF download to `/scratch/models/...` on g304 (hostPath) |
| `02-model-staging-job-g307.yaml`        | Same for g307 |
| `configH/10-prefiller.yaml`             | TP=4 prefiller pinned to g304 |
| `configH/11-prefiller-bootstrap-svc.yaml` | Headless ClusterIP, 8998, selects `app=prefiller-h` |
| `configH/12-prefiller-api-svc.yaml`     | ClusterIP, 8010, OpenAI front-door |
| `configH/20-decoder.yaml`               | TP=4 decoder pinned to g304 |
| `configH/21-decoder-api-svc.yaml`       | ClusterIP, 8020 |
| `configH/30-proxy.yaml`                 | `mooncake.vllm_v1_proxy_server` Deployment, pinned to g304 |
| `configH/31-proxy-svc.yaml`             | ClusterIP, 8000, bench target |
| `configH/90-smoke-job.yaml`             | One-shot `curl` against proxy-h, gates the bench |
| `configN/*`                             | Same as H, all pods pinned to g307 |
| `configP/*`                             | prefiller on g304, decoder + proxy on g307 |
| `bench/40-bench-job.yaml`               | Per-config concurrency-sweep Job + `bench-workload` ConfigMap (Python) |
| `STAGE_B_PLAN.md`                       | Detailed design + risk register + how Λ_max is computed |

---

## Bring-up

```bash
export KUBECONFIG=~/Code/VP/kubeconfigs/vpcloud-slurm-v2-admin.kubeconfig.yaml
kubectl config current-context  # sanity: vpcloud-slurm-v2-admin
cd prfaas/m1.5-vllm-baseline/k8s/stageB

# 1. namespace + shared env (~5 s)
kubectl apply -f 00-namespace.yaml

# 2. stage the model on BOTH nodes in parallel (~15-30 min, ~18 GB each)
kubectl apply -f 01-model-staging-job-g304.yaml -f 02-model-staging-job-g307.yaml
kubectl -n prfaas-stageb wait --for=condition=complete \
  job/model-stage-g304 job/model-stage-g307 --timeout=45m
kubectl -n prfaas-stageb logs job/model-stage-g304 --tail=10
kubectl -n prfaas-stageb logs job/model-stage-g307 --tail=10
# Sanity (operator):
#   ssh vpsupport@159.26.81.50 'ls /scratch/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2 | head'
#   ssh vpsupport@159.26.81.53 'ls /scratch/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2 | head'
```

Then for **each config** (H, then N, then P), one at a time:

```bash
export CONFIG=H && export CONFIG_LOWER=h   # repeat with N/n then P/p

# 3. prefiller + services
kubectl apply -f config${CONFIG_LOWER:-H}/10-prefiller.yaml \
              -f config${CONFIG_LOWER:-H}/11-prefiller-bootstrap-svc.yaml \
              -f config${CONFIG_LOWER:-H}/12-prefiller-api-svc.yaml
kubectl -n prfaas-stageb rollout status deploy/prefiller-${CONFIG_LOWER} --timeout=10m

# 4. decoder + service
kubectl apply -f config${CONFIG_LOWER:-H}/20-decoder.yaml \
              -f config${CONFIG_LOWER:-H}/21-decoder-api-svc.yaml
kubectl -n prfaas-stageb rollout status deploy/decoder-${CONFIG_LOWER} --timeout=10m

# 5. proxy + service
kubectl apply -f config${CONFIG_LOWER:-H}/30-proxy.yaml \
              -f config${CONFIG_LOWER:-H}/31-proxy-svc.yaml
kubectl -n prfaas-stageb rollout status deploy/proxy-${CONFIG_LOWER} --timeout=2m

# 6. smoke
kubectl apply -f config${CONFIG_LOWER:-H}/90-smoke-job.yaml
kubectl -n prfaas-stageb wait --for=condition=complete job/smoke-${CONFIG_LOWER} --timeout=3m
kubectl -n prfaas-stageb logs job/smoke-${CONFIG_LOWER}

# 7. bench (envsubst the per-config placeholders)
envsubst '${CONFIG} ${CONFIG_LOWER}' < bench/40-bench-job.yaml | kubectl apply -f -
kubectl -n prfaas-stageb wait --for=condition=complete job/bench-${CONFIG_LOWER} --timeout=4h
kubectl -n prfaas-stageb logs -f job/bench-${CONFIG_LOWER}

# 8. extract results
ssh vpsupport@159.26.81.50 \
  "tar czf - -C /scratch/prfaas-results/stageB config${CONFIG}" \
  > stageB_config${CONFIG}_results.tar.gz
```

After all three configs, run the host-side aggregator on the extracted CSVs:

```bash
mkdir -p prfaas/m1.5-vllm-baseline/results/stageB/nvidia_NVIDIA-Nemotron-Nano-9B-v2
tar xzf stageB_configH_results.tar.gz -C prfaas/m1.5-vllm-baseline/results/stageB/nvidia_NVIDIA-Nemotron-Nano-9B-v2/
tar xzf stageB_configN_results.tar.gz -C prfaas/m1.5-vllm-baseline/results/stageB/nvidia_NVIDIA-Nemotron-Nano-9B-v2/
tar xzf stageB_configP_results.tar.gz -C prfaas/m1.5-vllm-baseline/results/stageB/nvidia_NVIDIA-Nemotron-Nano-9B-v2/

python3 prfaas/m1.5-vllm-baseline/scripts/extract_lambda_max.py \
  --stage stageB \
  --results-dir prfaas/m1.5-vllm-baseline/results/stageB/nvidia_NVIDIA-Nemotron-Nano-9B-v2 \
  --out prfaas/m1.5-vllm-baseline/results/stageB/nvidia_NVIDIA-Nemotron-Nano-9B-v2/SUMMARY.md
```

---

## Tear-down

Per-config (keeps model staging artifacts on `/scratch`):
```bash
kubectl -n prfaas-stageb delete deploy,svc,job \
  -l prfaas.experiment/stage=B,prfaas.config=H
```

Whole stage (keeps model bytes on `/scratch`):
```bash
kubectl -n prfaas-stageb delete deploy,svc,job,cm \
  -l prfaas.experiment/stage=B
```

Nuke everything including ns:
```bash
kubectl delete ns prfaas-stageb
```

The `/scratch/models/...` weights stay on each node across `delete ns`
because `hostPath` volumes are not GC'd by Kubernetes. To free disk:
```bash
ssh vpsupport@159.26.81.50 'sudo rm -rf /scratch/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2'
ssh vpsupport@159.26.81.53 'sudo rm -rf /scratch/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2'
ssh vpsupport@159.26.81.50 'sudo rm -rf /scratch/prfaas-results/stageB'
```

---

## Expected timing

| Step                                  | Wall time |
|---------------------------------------|-----------|
| Model staging (parallel, both nodes)  | 15–30 min |
| Prefiller pod ready (per config)      | 3–6 min (image pull dominates the first time, then ~90 s for vLLM init) |
| Decoder pod ready                     | 3–6 min |
| Proxy pod ready                       | <1 min   |
| Smoke Job                             | <1 min   |
| Bench Job, full sweep, per config     | 60–120 min (depends on how early SLO breaches stop sweeps) |
| **Whole Stage B (3 configs, sequential)** | **~6 h end-to-end** including sanity gaps |

If you're running configs sequentially (recommended — Configs H and N
both consume all 8 GPUs of their pinned node, and Config P needs 4 GPUs
on each), the per-config bench is the long tail. Configs can be torn down
between runs; weights stay on `/scratch`.

---

## Success criteria

Stage B is **green** when, on the `long_context` workload (the paper's
main case for hybrid models):

1. **`Λ_max(P) ≥ 0.9 × Λ_max(H)`** — Config P's clean-wire Λ_max is
   within 10% of the homogeneous baseline. Anything less means our
   disaggregation overhead on a fast LAN is suspicious.
2. **`Λ_max(P) > Λ_max(N)`** — putting prefill on a different node beats
   doing the same split on one node. If false, either our split is wrong
   or Mooncake's loopback path is faster than the cross-node Cilium path
   (interesting either way).
3. **`|Λ_max(H) − Λ_max(N)| ≲ 5%`** — g304 and g307 give the same
   homogeneous baseline. Larger gaps suggest a per-node anomaly that we
   need to chase before trusting any P-vs-H comparison.

Recorded in `prfaas/m1.5-vllm-baseline/results/stageB/<model>/SUMMARY.md`
by `extract_lambda_max.py`.

---

## What to do if model staging gets out of sync between nodes

Symptoms:
- `model-stage-g304` finishes; `model-stage-g307` is still running 30+ min
  later, OR has been retried by `backoffLimit` after a transient HF error.
- `kubectl get job -n prfaas-stageb` shows different `COMPLETIONS`
  across the two staging Jobs.
- Operator deployed a config and the prefiller pod is `CrashLoopBackOff`
  with the vLLM logs complaining `Could not find config.json`.

Fix:
1. Check both Jobs:
   ```bash
   kubectl -n prfaas-stageb get job
   kubectl -n prfaas-stageb logs job/model-stage-g307 --tail=50
   ```
2. If g307 failed (e.g. HF rate limit), the Job is idempotent — just
   re-trigger it without touching g304:
   ```bash
   kubectl -n prfaas-stageb delete job model-stage-g307
   kubectl apply -f 02-model-staging-job-g307.yaml
   ```
   The `if [[ -f ${MODEL_LOCAL_DIR}/config.json ]] && ls *.safetensors`
   guard means the resumed Job skips already-downloaded files.
3. If hostPath dirs differ in *content* (e.g. one has fewer safetensors
   shards), wipe and re-stage:
   ```bash
   ssh vpsupport@159.26.81.53 'sudo rm -rf /scratch/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2'
   kubectl -n prfaas-stageb delete job model-stage-g307
   kubectl apply -f 02-model-staging-job-g307.yaml
   ```
4. As a sanity check before launching configs, verify checksums match:
   ```bash
   for h in 159.26.81.50 159.26.81.53; do
     ssh vpsupport@$h 'cd /scratch/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2 && \
       sha256sum *.safetensors | sort > /tmp/sums.txt && cat /tmp/sums.txt'
   done | tee /tmp/all-sums.txt
   ```
   The two `.safetensors` shard sums must match line-for-line. If they
   don't, the bench Λ_max for whichever node has the bad shard will be
   garbage and your H-vs-N comparison breaks.
5. Race condition (rare): both Jobs finish in K8s but one node's
   downloader process was killed mid-`safetensors_rust` write so a single
   shard is truncated. The vLLM init log will say `safetensors header out
   of bounds` or similar. Same fix as #3 — wipe and re-stage that one
   node.

---

## NOTES — Cilium NetworkPolicy

The X cluster runs Cilium as the CNI. By default, Cilium has **no
default-deny** policy in `prfaas-stageb` (we created the namespace fresh
with `cluster-admin`, no `CiliumNetworkPolicy` is auto-attached). All
the cross-pod traffic Stage B needs — namely:

| From                            | To                                         | Port  |
|---------------------------------|--------------------------------------------|-------|
| `proxy-h | -n | -p`             | `prefiller-{h,n,p}-api`                    | 8010  |
| `proxy-h | -n | -p`             | `decoder-{h,n,p}-api`                      | 8020  |
| `decoder-{h,n,p}`               | `prefiller-{h,n,p}-bootstrap`              | 8998  |
| `bench-{h,n,p}` (Job)           | `proxy-{h,n,p}`                            | 8000  |

— is allowed by Cilium's default-allow-all. **No `NetworkPolicy` resource
is required** for the bring-up to work.

If, however, the operator finds a default-deny `CiliumNetworkPolicy` in
`kube-system` or attached cluster-wide (`kubectl get cnp -A`), Stage B
will need an allow-list. The minimal one:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: stageb-allow-internal
  namespace: prfaas-stageb
spec:
  endpointSelector: {}
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: prfaas-stageb
      toPorts:
        - ports:
            - {port: "8000",  protocol: TCP}
            - {port: "8010",  protocol: TCP}
            - {port: "8020",  protocol: TCP}
            - {port: "8998",  protocol: TCP}
```

This lives in this README rather than as a manifest because we do NOT
want to apply it preemptively — adding any CNP to a namespace flips
Cilium from default-allow to default-deny for that namespace, breaking
anything we forgot to enumerate. Only apply if a default-deny is already
in force.

---

## Pointers

- Detailed design + Λ_max derivation + risk register: [STAGE_B_PLAN.md](./STAGE_B_PLAN.md)
- Stage A reference manifests (Y cluster, single-node): `../stageA/`
- Cluster discovery: `../DISCOVERY.md`
- Host-script equivalents (kept for archive): `../../scripts/run_stage_b.sh`,
  `../../scripts/run_concurrency_sweep.sh`,
  `../../scripts/extract_lambda_max.py`
