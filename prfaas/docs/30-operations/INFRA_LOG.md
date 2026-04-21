# Infrastructure log — PrfaaS-on-Mooncake

This document records every infrastructure-level event we hit during the
work — the actual operator pain points, with diagnosis and resolution —
so the next operator doesn't pay the same costs we did. It is the
companion to [`PROJECT_LOG.md`](../00-overview/PROJECT_LOG.md) §research-and-data and
[`DECISIONS.md`](../20-decisions/DECISIONS.md) §design-choices.

Sections:

1. Disk pressure on g126
2. Port collisions inside SGLang
3. RBAC and permissions on cluster Y
4. Driver / CUDA / image compatibility
5. K8s scheduling and tolerations
6. Hugging Face downloads (`hf_transfer`, gated repos)
7. Cluster X — pending GPU exposure work
8. Operational checklist for re-running Phase 1

---

## 1. Disk pressure on g126

### Symptom

`kubectl get nodes -o wide` shows the `node.kubernetes.io/disk-pressure:NoSchedule`
taint on `g126`. New pods stay `Pending` forever. Existing pods get
evicted in waves; `kubectl get pods -A` lights up with `Evicted` rows
across cluster-system namespaces (cert-manager, monitoring), in addition
to our own.

### Root cause

g126 has a single ext4 filesystem at `/dev/nvme0n1p2` (438.5 GiB). The
kubelet's imagefs and the `local-path` provisioner share that
filesystem. There is no separate fast tier. We ran into it twice:

1. Trying to host **all three Phase 1 model weights** simultaneously
   (Kimi 95 GB + Qwen2.5-72B 135 GB + Nemotron 17 GB ≈ **245 GB**), on
   top of the cluster system images and `kube-system` pod data. With
   that much PVC content, the kubelet's free-disk threshold tripped.
2. After Stage A, an **80 GiB PVC** from the original Stage A run was
   still mounted (`stagea-models`). Combined with the Phase 1 PVC and
   Kimi+Qwen weights, disk briefly went red.

### Resolution

In order, what worked:

- **Delete the orphaned Stage A PVC.** `kubectl delete pvc stagea-models`
  and its `PersistentVolume`. Frees the 80 GiB Stage A footprint.
- **Bump the Phase 1 PVC from 80 GiB to 400 GiB.** Edited
  `prfaas/m1.5-vllm-baseline/k8s/phase1/01-model-pvc.yaml`. With the
  underlying disk at 438.5 GiB, this is essentially the entire physical
  capacity minus system files.
- **After Qwen2.5-72B's measurable cells (`l ≤ 16 K`) are collected,
  delete the Qwen weights** (135.4 GB) via a one-shot Job
  (`weights-cleanup-qwen72b`). The Job runs at
  `priorityClassName: system-cluster-critical` and tolerates
  `node.kubernetes.io/disk-pressure:NoSchedule` so it can run while
  the taint is still on. The full Job manifest is reproduced below for
  reference (it's not checked in because it's a one-shot, but
  re-pasting it is fine):

  ```yaml
  apiVersion: batch/v1
  kind: Job
  metadata:
    name: weights-cleanup-qwen72b
    labels:
      prfaas.experiment/phase: "1"
  spec:
    backoffLimit: 1
    template:
      metadata:
        labels:
          app: weights-cleanup-qwen72b
          prfaas.experiment/phase: "1"
      spec:
        restartPolicy: OnFailure
        priorityClassName: system-cluster-critical
        nodeSelector:
          kubernetes.io/hostname: g126
        tolerations:
          - key: node.kubernetes.io/disk-pressure
            operator: Exists
            effect: NoSchedule
        containers:
          - name: cleaner
            image: busybox:1.36
            imagePullPolicy: IfNotPresent
            command: ["sh", "-c"]
            args:
              - |
                set -ex
                echo "=== before ==="
                du -sh /models/* 2>/dev/null || true
                df -h /models
                if [ -d "/models/Qwen_Qwen2.5-72B-Instruct" ]; then
                  rm -rf /models/Qwen_Qwen2.5-72B-Instruct
                  echo "[clean] removed Qwen2.5-72B weights"
                fi
                echo "=== after ==="
                du -sh /models/* 2>/dev/null || true
                df -h /models
            volumeMounts:
              - name: model
                mountPath: /models
            resources:
              requests:
                cpu: "100m"
                memory: 64Mi
              limits:
                cpu: "1"
                memory: 256Mi
        volumes:
          - name: model
            persistentVolumeClaim:
              claimName: model-weights-phase1
  ```

- **Wait ~2 min after the cleanup Job completes** for the kubelet to
  re-evaluate disk usage and clear the taint.

### Steady-state

After Phase 1 completed and the Qwen2.5-72B weights were evicted:

- Kimi-Linear-48B: ~95 GB
- Nemotron-Nano-9B-v2: ~17 GB
- Cluster system + container images: ~85 GB
- Free: ~240 GB
- Disk usage: ~78%, `disk-pressure` taint clear.

### Pre-flight check before re-running Phase 1

```bash
KUBECONFIG=$Y_KCFG kubectl get node g126 -o jsonpath='{.spec.taints}{"\n"}'
KUBECONFIG=$Y_KCFG kubectl exec -n default \
  $(kubectl --kubeconfig=$Y_KCFG -n default get pod -l app=results-reader -o name | head -1) \
  -- df -h /results
```

If `disk-pressure` is set, run the cleanup Job before staging anything.
If `df -h /models` is > 85% used, evict Qwen2.5-72B (or whichever
weight set is biggest and not currently being measured) before
re-staging.

---

## 2. Port collisions inside SGLang (and PyTorch inductor)

### Symptom

SGLang server pod logs show:

```
[uvicorn.error] [Errno 98] address already in use
INFO:     Application startup failed. Exiting.
```

The pod restarts in a loop. The Kubernetes Service in front of the
deployment never reaches `Ready`.

### Root cause

Two collisions, both on the user-facing API port:

1. **SGLang's own scheduler IPC.** `srt/utils/network.py::get_open_port()`
   reads `os.getenv("SGLANG_PORT")`. If set, the scheduler grabs that
   port for its internal IPC during startup, *before* uvicorn binds the
   user-facing HTTP port. We set `SGLANG_PORT` because we wanted to
   force the API onto a known port; the scheduler swallowed it first
   and uvicorn lost the race.

2. **PyTorch inductor compile workers.** `torch._inductor.compile_worker`
   forks N subprocesses during CUDA-graph capture. They inherit env
   from the parent and were transiently binding ports themselves
   (we believe for inductor's internal IPC), occasionally racing with
   uvicorn even after fixing collision #1.

We hit collision #1 three times in a row on different port numbers
(30000 → 40000 → 8001) before realising the issue was the variable
name, not the value.

### Resolution

Two changes, both reflected in the Phase 1 manifests:

1. **Rename our env var to `PRFAAS_SGLANG_API_PORT`** in
   `00-namespace.yaml`. Pass its value to `--port` on the SGLang command
   line explicitly. SGLang's `SGLANG_PORT` env-var lookup now returns
   nothing, the scheduler picks a free ephemeral port, and the API port
   is uncontested. The ConfigMap entry has a long comment so a future
   operator doesn't innocently rename the var back:

   ```yaml
   # CRITICAL: do NOT name this `SGLANG_PORT`. SGLang's own
   # `srt/utils/network.py::get_open_port()` reads `os.getenv("SGLANG_PORT")`
   # and uses it to allocate the scheduler's internal IPC port BEFORE uvicorn
   # binds the user-facing HTTP port. The two collide and uvicorn dies with
   # "[Errno 98] address already in use". Use a project-namespaced var instead
   # and pass its value to `--port` explicitly.
   PRFAAS_SGLANG_API_PORT: "8001"
   ```

2. **Set `TORCHINDUCTOR_COMPILE_THREADS=1`** so PyTorch inductor compiles
   single-threaded and doesn't fork compile-worker subprocesses. Costs a
   few seconds at warmup; cheap. Set in every profiler manifest's
   `env:` block.

### Detection

If the symptom recurs, dump the listening sockets inside the SGLang
container before crash:

```bash
kubectl --kubeconfig=$Y_KCFG -n default exec -it $POD -- sh -c \
  'ss -tlnp || netstat -tlnp || true'
```

Anything else listening on the API port is the culprit. Check that no
manifest re-introduces `SGLANG_PORT` and that `TORCHINDUCTOR_COMPILE_THREADS=1`
is set.

---

## 3. RBAC and permissions on cluster Y

### Constraint

The `aln1-beta-harsha-g126-beta` kubeconfig authenticates as a member of
the `mks:customer` group. RBAC scopes:

- We can create / delete / list / watch the standard pod-shaped
  resources in the `default` namespace: `pods`, `deployments`,
  `statefulsets`, `jobs`, `services`, `configmaps`, `secrets`, `pvcs`.
- We **cannot** create or delete namespaces.
- We **cannot** mutate cluster-scoped resources: `nodes`, `priority
  classes`, `cluster role bindings`, `crds`.
- We **cannot** delete pods in foreign namespaces. In particular: the
  cert-manager pods that get evicted under disk-pressure stay as
  `Failed` rows forever — we don't have permission to clean them up.

### Practical implications

- Every Phase 1 resource lives in `default` namespace.
- We use **labels**, not namespaces, for isolation:
  `prfaas.experiment/stage: A`, `prfaas.experiment/phase: "1"`. Bulk
  cleanup is `kubectl delete deploy,svc,job,pvc,cm -l prfaas.experiment/phase=1`.
- The orphaned `Failed` cert-manager / monitoring pods after
  disk-pressure events are visual noise but are in a terminal state
  (consume no scheduler quota, no GPU quota). Ignore them; ask cluster
  ops to garbage-collect periodically.
- We can use `priorityClassName: system-cluster-critical` on Jobs we
  create — the *binding* exists at the cluster level, we just can't
  *create* new priority classes. This is what lets the disk-cleanup
  Job tolerate `disk-pressure:NoSchedule`.

### `priorityClassName` for emergency Jobs

The cleanup Job pattern in §1 above uses `system-cluster-critical`
because it's allowed to schedule on a tainted node. Don't use this for
research workloads — only for emergency reclamation.

---

## 4. Driver / CUDA / image compatibility

### Constraint

g126's NVIDIA driver is **`570.211.01`** (verify with
`nvidia-smi --query-gpu=driver_version --format=csv,noheader` from any
GPU pod, or via the GPU operator's pod logs). That driver supports up
to **CUDA 12.9**. CUDA 13.0 binaries (`cu130` builds) fail at container
start with a CUDA driver-symbol-mismatch error.

### Decision

All Phase 1 SGLang pods pin
**`lmsysorg/sglang:v0.5.9-cu129-amd64`**. SGLang's published image set
also has `v0.5.9-cu130-amd64` and `v0.5.9-cu125-amd64`; only `cu129` is
the right one for g126 right now. (`cu125` would also work but leaves
performance on the table.)

vLLM Stage A used `vllm/vllm-openai:v0.19.1`, which is built on CUDA
12.4 — comfortably below the driver's max.

### Pre-flight check before bumping the SGLang image

```bash
# Get the driver:
kubectl --kubeconfig=$Y_KCFG -n default exec $POD -- nvidia-smi \
  --query-gpu=driver_version --format=csv,noheader

# Get the CUDA-driver max:
#   570.x → 12.9 max
#   575.x → 13.0 max
#   580.x → 13.1 max
# (NVIDIA's compatibility table; double-check at release time.)
```

If the new SGLang image is `cu13x` and the driver doesn't support it,
*don't bump the image*. Ask cluster ops to bump the driver first.

---

## 5. K8s scheduling and tolerations

### NodeSelector

Every Phase 1 manifest pins `nodeSelector: kubernetes.io/hostname: g126`
because Y is a single-node cluster. Prevents accidental scheduling onto
something else if the cluster is ever extended.

### Tolerations

Production manifests (the profiler Jobs) deliberately do **not**
tolerate `disk-pressure:NoSchedule`. We want a profiler Job to fail-out
loudly if disk is full, rather than silently overwhelm the system.

Only the disk-cleanup Job (and any other emergency-reclamation Job)
tolerates `disk-pressure`. See §1.

### GPU resource requests

Each profiler Job requests `nvidia.com/gpu: <tp>` exactly:

- Kimi-Linear-48B at TP=8 → 8 GPUs
- Qwen2.5-72B at TP=8 → 8 GPUs
- Nemotron-Nano-9B-v2 at TP=4 → 4 GPUs

Phase 1 must be **sequential** because Kimi and Qwen each take all 8
GPUs. Nemotron at TP=4 *could* coexist with a TP=4 partner but in
practice we run it standalone too — the goal is exact-conditions Φkv,
not shared-tenancy benchmarking.

### Memory and CPU

Per pod: `cpu: "16"`, `memory: 200Gi`, `ephemeral-storage: 50Gi` for
Kimi/Qwen at TP=8. Tuned empirically; SGLang's tokenizer + scheduler
processes don't need much CPU/RAM, but the Hugging Face cache touches
ephemeral-storage briefly during model load.

---

## 6. Hugging Face downloads

### Tooling

We use `huggingface-cli download` with `HF_HUB_ENABLE_HF_TRANSFER=1`
inside a `python:3.12-slim` Job. `hf_transfer` parallel-downloads
shards faster than the default Python implementation; on g126 we see
~1 GB/s sustained.

### Gated repos

`moonshotai/Kimi-Linear-48B-A3B-Instruct` and Nemotron-Nano-9B-v2 are
gated. The staging Job references a `Secret` named `huggingface-token`
in the `default` namespace, mounted as `HF_TOKEN`. **Don't check the
secret in.** The current rig provisions it via:

```bash
kubectl --kubeconfig=$Y_KCFG -n default create secret generic huggingface-token \
  --from-literal=HF_TOKEN=$HF_TOKEN
```

If you don't have the token in your env, `op read op://Personal/huggingface/api-token`
or the equivalent.

### Sizes (rounded, observed)

| Model | Disk on PVC | Wall-clock to download (g126, hf_transfer) |
|---|---|---|
| `moonshotai/Kimi-Linear-48B-A3B-Instruct` | ~95 GB | ~5 min |
| `Qwen/Qwen2.5-72B-Instruct` | ~135 GB | ~10 min |
| `nvidia/NVIDIA-Nemotron-Nano-9B-v2` | ~17 GB | ~1 min |
| `Qwen/Qwen2.5-7B-Instruct` (Stage A) | ~15 GB | ~48 s |

### Lingering staging pods

Once `huggingface-cli download` returns, the bash wrapper exits and the
pod transitions `Running` → `Succeeded`. Sometimes Kubernetes takes
20–40 s to mark the pod completed (it's waiting for the container's
`stop` to flush). If you're watching, use
`kubectl wait --for=condition=complete job/<name> --timeout=2400s`
rather than polling `kubectl get pods` — the Job condition flips first.

---

## 7. Cluster X — pending GPU exposure work

### Symptom

The X-cluster (g304 + g307) is administratively reachable via the
admin kubeconfig, but applying a manifest with `nvidia.com/gpu: 8`
yields `Insufficient nvidia.com/gpu` regardless of how many GPUs are
physically present.

### Diagnosis (incomplete)

NVIDIA GPU Operator is either not installed or not advertising GPUs in
the `node.status.allocatable` map on g304/g307. From the cluster's
`device-plugin` logs we'd see whether the driver / DCGM / device plugin
is up. The investigation is queued as the `x_cluster_check` todo on
the active branch but blocked on cluster-operator action — we don't
have admin to debug from inside.

### Impact on the experiment

- Phase 1 had to land on g126 only — fine, single-node profiling
  doesn't need cluster X.
- Phase 3 cross-DC needs g304 (or g307) as the prefiller. **Blocking.**
- The 229 B / 309 B paper-class dense controls (MiniMax-M2.5,
  Qwen3-235B) need TP=16 across both X-cluster nodes. **Blocking** for
  the dense extension.

### Plan

When cluster X GPU exposure unblocks, two parallel checks:

1. `kubectl get node g304 -o json | jq .status.allocatable` shows
   `"nvidia.com/gpu": "8"`.
2. A 1-pod 1-GPU smoke `Job` finishes in seconds.

Then port the Phase 3 design draft over and unblock the cross-DC arm.

---

## 8. Operational checklist for re-running Phase 1

If you're re-running Phase 1 from scratch tomorrow, work through this
in order. Each row maps to a known-painful failure mode above.

| # | Step | Source of pain |
|---|---|---|
| 1 | Confirm g126 is not tainted: `kubectl get node g126 -o jsonpath='{.spec.taints}{"\n"}'` | §1 |
| 2 | Confirm driver and image compatibility (`nvidia-smi --query-gpu=driver_version` vs the SGLang image's CUDA tag) | §4 |
| 3 | Apply `00-namespace.yaml` (CMs and namespace label set) — verify `PRFAAS_SGLANG_API_PORT` is set, `SGLANG_PORT` is **not** set | §2 |
| 4 | Apply `01-model-pvc.yaml` (400 GiB PVC) | §1 |
| 5 | Sync probe script ConfigMap from `prfaas/m1.5-vllm-baseline/scripts/phi_kv_probe.py` | §6 |
| 6 | Stage models you need (Kimi / Nemotron / Qwen2.5-72B) — wait for each Job to `complete` | §6 |
| 7 | Apply profiler Jobs **sequentially**, one model at a time | §5 |
| 8 | After each profiler Job completes, copy the JSONL out via the results-reader sidecar pattern | §3 |
| 9 | If you no longer need Qwen2.5-72B weights, run the cleanup Job to free disk before the next staging | §1 |
| 10 | Bulk cleanup: `kubectl delete job,deploy,svc,cm -l prfaas.experiment/phase=1` (do **not** delete the PVC unless you also want to lose model weights) | §3 |
