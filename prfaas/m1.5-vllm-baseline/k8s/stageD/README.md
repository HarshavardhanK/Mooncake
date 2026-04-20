# Stage D — operator runbook (Kubernetes path)

**Read `STAGE_D_PLAN.md` first** for the design rationale. This file is the
copy-pasteable operator playbook.

**Pre-conditions (cross-checked before any apply):**
- Stage A is green on Y (smoke job 200, KV transfer logged).
- Stage B has run `01-model-staging-job-g304.yaml` at least once on the X
  cluster, populating `/scratch/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2`
  on g304. (If Stage B isn't done yet, Stage D is blocked.)
- Operator has approved the firewall extension on g304
  (`firewall/g304-stageD-iptables.sh`).

---

## 0. Kubeconfig and context shortcuts

```bash
export X_KC=/Users/hkalalbandi/Desktop/Code/VP/kubeconfigs/vpcloud-slurm-v2-admin.kubeconfig.yaml
export Y_KC=/Users/hkalalbandi/Desktop/Code/VP/kubeconfigs/aln1-beta-harsha-g126-beta.kubeconfig.yaml
cd /Users/hkalalbandi/Desktop/Code/General/Mooncake/prfaas/m1.5-vllm-baseline/k8s/stageD
```

Sanity:

```bash
KUBECONFIG=$X_KC kubectl get nodes -o wide   # expect g304 Ready, 8 GPUs
KUBECONFIG=$Y_KC kubectl get nodes -o wide   # expect g126 Ready, 8 GPUs
```

---

## 1. Pre-flight (do these BEFORE applying anything)

### 1.1 Firewall extension on g304 (operator action, manual)

```bash
# from the laptop
scp firewall/g304-stageD-iptables.sh vpsupport@159.26.81.50:/tmp/
sshv vpsupport@159.26.81.50
sudo bash /tmp/g304-stageD-iptables.sh
```

Expected output:
```
[firewall] inserting rule: allow TCP 8998 from 147.185.40.126
[firewall] inserted.
[firewall] current rules touching :8998 or 13000-17000 ::
-A INPUT -s 147.185.40.126/32 -p tcp -m tcp --dport 8998 -j ACCEPT -m comment ...
-A INPUT -s 147.185.40.126/32 -p tcp -m tcp --dport 13000:17000 -j ACCEPT
```

If Stage 0a's 13000-17000 rule is missing for some reason, re-run Stage 0a's
`firewall_setup.sh stageD` first (NOT in scope for this Stage D agent).

### 1.2 Confirm port availability on g304

```bash
sshv vpsupport@159.26.81.50 'sudo ss -tlnp | grep -E ":8998|:1[3-7][0-9]{3}"'
# Expect: empty (no listeners). If something else holds 8998, the prefiller
# pod will CrashLoopBackOff with EADDRINUSE — change VLLM_MOONCAKE_BOOTSTRAP_PORT
# to e.g. 18998 in x/00-namespace.yaml AND y/00-configmap.yaml AND the firewall
# script, and re-apply both ConfigMaps + the firewall.
```

### 1.3 Confirm model is staged on g304

```bash
sshv vpsupport@159.26.81.50 'ls -lh /scratch/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2/ | head -20'
# Expect: config.json + several .safetensors files, ~18 GB total.
```

### 1.4 Sanity-check Stage 0a numbers still hold (5-min check)

```bash
# from g126 to g304, single iperf3:
sshv vpsupport@159.26.81.50 'iperf3 -s -p 13001 -1 &'
ssh ubuntu@147.185.40.126 'iperf3 -c 159.26.81.50 -p 13001 -t 10 -P 4'
# Expect: ~10-15 Gbps. If <2 Gbps, the wire is having a bad day; either
# wait for a different TOD window or document the degraded baseline before
# proceeding.
```

### 1.5 Confirm Stage A is up and Config H proxy is reachable on Y

```bash
KUBECONFIG=$Y_KC kubectl -n default get deploy,svc -l prfaas.experiment/stage=A
KUBECONFIG=$Y_KC kubectl -n default get svc proxy   # Stage A proxy on :8000
```

---

## 2. Bring-up sequence (X first, then Y)

### 2.1 X cluster — namespace + prefiller

```bash
KUBECONFIG=$X_KC kubectl apply -f x/00-namespace.yaml
KUBECONFIG=$X_KC kubectl apply -f x/10-prefiller.yaml

# Wait for the prefiller to come Ready (initContainer ~30s, vLLM weight load
# ~2 min, torch.compile JIT 3-5 min the first time).
KUBECONFIG=$X_KC kubectl -n prfaas-staged rollout status deploy/prefiller-staged --timeout=15m
```

Sanity from inside the X cluster:

```bash
KUBECONFIG=$X_KC kubectl -n prfaas-staged logs deploy/prefiller-staged -c vllm --tail=200 \
  | grep -Ei 'host IP|bootstrap port|Mooncake|kv_producer|listening|ready'

# expect to see:
#   [prefiller-staged] host IP: 159.26.81.50
#   [prefiller-staged] bootstrap port: 8998
#   ...vllm starts...
#   ...MooncakeConnector imports...
```

Sanity from outside (operator's laptop):

```bash
# bootstrap query — should return JSON with engine_id keys
curl -sS --max-time 10 http://159.26.81.50:8998/query | jq .

# OpenAI HTTP (proves vLLM is up; intentionally NOT publicly opened, so
# you'll need to test from g126 instead)
ssh ubuntu@147.185.40.126 'curl -sS http://159.26.81.50:8010/v1/models'
```

### 2.2 Y cluster — ConfigMap + decoder + proxy

```bash
KUBECONFIG=$Y_KC kubectl apply -f y/00-configmap.yaml
KUBECONFIG=$Y_KC kubectl apply -f y/20-decoder.yaml
KUBECONFIG=$Y_KC kubectl -n default rollout status deploy/decoder-staged --timeout=15m

KUBECONFIG=$Y_KC kubectl apply -f y/30-proxy.yaml
KUBECONFIG=$Y_KC kubectl -n default rollout status deploy/proxy-staged --timeout=2m
```

Confirm proxy resolved the cross-DC endpoint:

```bash
KUBECONFIG=$Y_KC kubectl -n default logs deploy/proxy-staged --tail=50 \
  | grep -E 'prefiller-host|cross-DC|engine_id'
# expect:
#   prefiller-host=159.26.81.50
#   prefiller-port=8010
#   prefiller-bootstrap-port=8998
```

### 2.3 Smoke (the gate before any benchmark)

```bash
KUBECONFIG=$Y_KC kubectl apply -f y/90-smoke-job.yaml
KUBECONFIG=$Y_KC kubectl -n default wait --for=condition=complete job/smoke-staged --timeout=3m
KUBECONFIG=$Y_KC kubectl -n default logs job/smoke-staged
# expect: http=200, body contains 'content', "[smoke-staged] OK"
```

If the smoke fails with connect-refused on 8998, the firewall step (1.1) is
the most likely culprit. If it fails on the Mooncake transport, suspect
13000-17000 on either side.

### 2.4 Confirm cross-DC KV transfer actually fired (the critical check)

```bash
# X-side prefiller log:
KUBECONFIG=$X_KC kubectl -n prfaas-staged logs deploy/prefiller-staged -c vllm --tail=500 \
  | grep -E 'transfer_id|do_remote_decode|kv_producer'

# Y-side decoder log:
KUBECONFIG=$Y_KC kubectl -n default logs deploy/decoder-staged -c vllm --tail=500 \
  | grep -E 'transfer_id|do_remote_prefill|kv_consumer|remote_bootstrap_addr'

# CRITICAL: same transfer_id should appear in BOTH logs. If the IDs match
# the cross-DC KV path actually fired. If only the Y log has them, the
# decoder fell back to local prefill (something is wrong with the proxy's
# kv_transfer_params plumbing).
```

---

## 3. Run the benchmark (Config P)

```bash
# Single TOD window. Override TIME_TAG and WORKLOADS as needed.
KUBECONFIG=$Y_KC kubectl apply -f y/40-bench-job.yaml

# Optional: override env per run (do this BEFORE apply, by editing the YAML,
# OR use `kubectl set env` AFTER apply but BEFORE the pod has started).
# Example: only run long_context for the first window
#   kubectl -n default set env job/bench-staged WORKLOADS="long_context" TIME_TAG="window1_off_peak"

KUBECONFIG=$Y_KC kubectl -n default wait --for=condition=complete job/bench-staged --timeout=4h
KUBECONFIG=$Y_KC kubectl -n default logs job/bench-staged --tail=200
```

Pull the results back:

```bash
# Either via SSH directly to g126:
rsync -avz ubuntu@147.185.40.126:/scratch/prfaas/results/stageD/ \
  ./prfaas/m1.5-vllm-baseline/results/stageD/

# or kubectl cp from the (still-existing) bench pod:
POD=$(KUBECONFIG=$Y_KC kubectl -n default get pod -l job-name=bench-staged -o name)
KUBECONFIG=$Y_KC kubectl -n default cp "${POD#pod/}":/results/stageD ./results-tmp/
```

Repeat 3 times across the day for `TIME_TAG=peak_us`, `eu_business`,
`off_peak`. Delete the Job between runs:

```bash
KUBECONFIG=$Y_KC kubectl -n default delete job bench-staged
```

---

## 4. Comparison protocol — Config P vs Config H

The headline number is `Λ_max(P) / Λ_max(H)` per workload per TOD window.

```bash
# 4.1 Config P (cross-DC) — Stage D stack against proxy-staged:8001
#     Done above (section 3).

# 4.2 Tear down Stage D X-side prefiller (release the wire / GPUs)
KUBECONFIG=$X_KC kubectl -n prfaas-staged delete deploy prefiller-staged

# 4.3 Run Config H bench against Stage A's proxy (single-cluster on Y)
#     This re-uses Stage A's already-running 1P+1D+proxy on g126.
#     Bench Job is the same shape — point it at Stage A's proxy:8000 instead
#     of Stage D's proxy-staged:8001. (Out-of-scope manifest; copy
#     y/40-bench-job.yaml, change `PROXY_URL` and `name: bench-staged-h`.)

# 4.4 Reduce Lambda_max per cell:
python3 ../../scripts/extract_lambda_max.py \
    --stage stageD \
    --results-dir ../../results/stageD/nemotron-nano-9b-v2 \
    --out ../../results/stageD/nemotron-nano-9b-v2/SUMMARY.md
```

---

## 5. Tear-down

### 5.1 Stage D Y-side

```bash
KUBECONFIG=$Y_KC kubectl -n default delete deploy,svc,job,cm \
  -l prfaas.experiment/stage=D
# Stage A objects (label stage=A) are NOT touched.
```

### 5.2 Stage D X-side (full nuke; namespace removal frees model PVC reference)

```bash
KUBECONFIG=$X_KC kubectl delete ns prfaas-staged
# Note: this does NOT delete /scratch/models on g304 (that's a hostPath
# owned by Stage B's staging Job — leave it for the next Stage D run).
```

### 5.3 Firewall rollback (only if explicitly desired by operator)

```bash
sshv vpsupport@159.26.81.50
sudo iptables -D INPUT -p tcp -s 147.185.40.126/32 --dport 8998 -j ACCEPT \
     -m comment --comment "prfaas stageD: Mooncake bootstrap from g126"
# Persist if needed (matches Stage 0a pattern).
```

---

## 6. What to look for in pod logs to confirm cross-DC KV transfer

| Where | Pattern (case-insensitive) | What it means |
|---|---|---|
| Prefiller log | `MooncakeConnector` import successful | connector loaded |
| Prefiller log | `kv_producer` | role correctly set |
| Prefiller log | `bootstrap.*8998.*listen` (or similar) | bootstrap server up |
| Prefiller log | `transfer_id=<hex>` | a request arrived for cross-DC pickup |
| Decoder log | `MooncakeConnector` import successful | connector loaded |
| Decoder log | `kv_consumer` | role correctly set |
| Decoder log | `remote_bootstrap_addr=159.26.81.50:8998` | proxy plumbed the right endpoint |
| Decoder log | `transfer_id=<hex>` (matching prefiller!) | KV pull from g304 actually happened |
| Proxy log | `prefiller-host=159.26.81.50` | env wired correctly |
| Proxy log | `engine_id` per dp_rank from `/query` | bootstrap discovery worked |

**Red flags:**
- Decoder log shows `do_remote_prefill=False` for every request → the proxy
  never instructed remote prefill (probably a proxy config issue or a
  prefiller warmup failure).
- Prefiller log has no `transfer_id` for any request the smoke fired →
  cross-DC connection is broken; check firewall first, then iptables on
  both sides for the 13000-17000 range.
- Decoder reports `connection refused 159.26.81.50:8998` → firewall step
  1.1 wasn't applied or the rule isn't in INPUT before a DROP.
- Goodput ~3.5 Gbps in benchmark cells → `MC_TCP_ENABLE_CONNECTION_POOL`
  isn't being honored by the connector; this is the headline open risk.
  Re-check `kubectl exec deploy/prefiller-staged -- env | grep MC_`.

---

## 7. Things this runbook intentionally does NOT do

- It does NOT bake or push container images.
- It does NOT modify Stage A manifests.
- It does NOT change anything on the X cluster outside the
  `prfaas-staged` namespace (and the operator-run firewall rule).
- It does NOT enable WireGuard.
- It does NOT add Mooncake master / etcd (we're on the v1 master-less
  connector, see decision #9 in `scripts/managed-services/inference/AGENTS.md`).
- It does NOT make any decision about persistence of the new iptables
  rule across reboots — the operator owns that policy.
