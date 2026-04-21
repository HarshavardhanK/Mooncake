# Phase 1 — Φkv replication on cluster Y (g126)

This directory contains the K8s manifests for the paper-faithful Phase 1
work described in `prfaas/docs/10-paper/PHASE1_PHIKV_PLAN.md`.

## Bring-up

All commands assume `KUBECONFIG=…/aln1-beta-harsha-g126-beta.kubeconfig.yaml`
and a working `kubectl`. The user's role on this cluster is `mks:customer`,
which only RoleBinds the `default` namespace — every object below lives
there.

```
KCFG=/Users/hkalalbandi/Desktop/Code/VP/kubeconfigs/aln1-beta-harsha-g126-beta.kubeconfig.yaml
K="kubectl --kubeconfig=$KCFG -n default"

# 0. Shared ConfigMap (model list + sweep config) and results PVC
$K apply -f 00-namespace.yaml
$K apply -f 01-model-pvc.yaml
$K apply -f 10-profiler-kimi.yaml   # creates results PVC + (placeholder) probe ConfigMap

# 1. Sync the real probe script into the placeholder ConfigMap.
#    Re-run this whenever phi_kv_probe.py changes.
$K create configmap prfaas-phase1-probe-script \
   --from-file=phi_kv_probe.py=../../scripts/phi_kv_probe.py \
   --dry-run=client -o yaml | $K apply -f -

# 2. Stage Kimi-Linear-48B (paper hybrid H1, ~49 GiB).
$K apply -f 02-model-staging-job-kimi.yaml
$K wait --for=condition=complete --timeout=45m job/model-staging-kimi-linear-48b

# 3. Profile H1.  Runs SGLang + sweep + JSONL → /results/kimi-linear-48b.jsonl.
$K apply -f 10-profiler-kimi.yaml
$K logs -f job/phi-kv-profiler-kimi-linear-48b
$K wait --for=condition=complete --timeout=60m job/phi-kv-profiler-kimi-linear-48b

# 4. Pull the result file out of the PVC for committing.
POD=$($K get pod -l job-name=phi-kv-profiler-kimi-linear-48b -o jsonpath='{.items[0].metadata.name}')
$K cp $POD:/results/kimi-linear-48b.jsonl ../../../results/m1.5-vllm-baseline/phase1_phi_kv/kimi-linear-48b.jsonl
$K cp $POD:/results/kimi-linear-48b.sglang.log ../../../results/m1.5-vllm-baseline/phase1_phi_kv/kimi-linear-48b.sglang.log

# 5. Repeat for D1 (Qwen2.5-72B-Instruct, paper-faithful dense control).
$K apply -f 03-model-staging-job-qwen72b.yaml
$K wait --for=condition=complete --timeout=120m job/model-staging-qwen2-5-72b

# Delete the Kimi profiler so the GPUs free up before applying the Qwen one
# (both want all 8 GPUs).
$K delete job phi-kv-profiler-kimi-linear-48b

$K apply -f 11-profiler-qwen72b.yaml
$K wait --for=condition=complete --timeout=120m job/phi-kv-profiler-qwen2-5-72b
$K cp <pod>:/results/qwen2.5-72b-instruct.jsonl ../../../results/m1.5-vllm-baseline/phase1_phi_kv/

# 6. Repeat for H2 (Nemotron-Nano-9B-v2, adjacent hybrid).
$K apply -f 12-profiler-nemotron.yaml
$K wait --for=condition=complete --timeout=60m job/phi-kv-profiler-nemotron-nano-9b-v2
$K cp <pod>:/results/nemotron-nano-9b-v2.jsonl ../../../results/m1.5-vllm-baseline/phase1_phi_kv/

# 7. Cleanup (frees PVCs, GPU pods).
$K delete -l prfaas.experiment/phase=1 deploy,svc,job,pvc,cm
```

## Why a placeholder ConfigMap?

Inlining a 400-line Python script in a YAML `data:` block is brittle (whitespace,
quoting, line-length). Instead, `10-profiler-kimi.yaml` declares the ConfigMap
with a single placeholder line that `raise SystemExit(...)` on import — so if
you forget to sync the real script, the probe Job fails immediately with a
clear error message. The intended workflow is:

```
$K create configmap prfaas-phase1-probe-script \
   --from-file=phi_kv_probe.py=../../scripts/phi_kv_probe.py \
   --dry-run=client -o yaml | $K apply -f -
```

This pattern keeps the source-of-truth in the repo (under `scripts/`) where
linting and version control work normally.

## Why one profiler Job per model (not one rotating)?

GPU memory accounting on a Kubernetes Job is per-Pod, and SGLang doesn't
support hot-swapping models without restarting the server. One Job per model
gives clean fault isolation and clean GPU release between runs.

## Concurrency on g126

g126 has 8× H100. The Kimi-Linear and Qwen2.5-72B Jobs each request all 8
GPUs (`nvidia.com/gpu: 8`), so they cannot run simultaneously. The Nemotron
Job requests 4 GPUs — in principle it could run alongside another TP=4 job,
but for clean numbers run it alone.

## Re-running just the sweep (weights already staged)

The probe Job is idempotent. To re-run with different settings (more timed
samples, narrower context range, etc.), edit `00-namespace.yaml`'s
ConfigMap and re-apply the profiler Job:

```
$K apply -f 00-namespace.yaml
$K delete job phi-kv-profiler-kimi-linear-48b --ignore-not-found
$K apply -f 10-profiler-kimi.yaml
```

The model PVC (`model-weights-phase1`) is preserved across deletes —
only the Jobs/Pods are recreated.
