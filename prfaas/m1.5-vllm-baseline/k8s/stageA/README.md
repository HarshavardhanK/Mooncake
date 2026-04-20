# Stage A — single-cluster 1P1D smoke on Y (g126), Kubernetes path

**Status (2026-04-20):** ✅ **GREEN on Qwen2.5-7B-Instruct (dense).**
Smoke job `90-smoke-job.yaml` returns `HTTP 200` with content `"OK"`.
First paper-relevant negative finding captured for hybrid Mamba2+attn
models — vLLM v0.19.1's `MooncakeConnector` cannot serve them even with
the `SupportsHMA` shim applied. Full evidence in
[`../../../results/stageA/`](../../../results/stageA/).

**Replaces** `prfaas/m1.5-vllm-baseline/STAGE_A_PLAN.md` (host-install
version). The host plan is kept for archive only — DO NOT use it.

**Purpose:** prove the Mooncake-vLLM v1 disaggregated stack works
end-to-end on Y, deployed via `kubectl apply`, no `pip install` on the
host. If green, the same image + manifest pattern lifts to Stage D
(cross-DC) with only network-path changes.

**Active smoke model:** `Qwen/Qwen2.5-7B-Instruct` (dense, ~15 GiB BF16,
TP=4 trivial fit). Originally targeted Nemotron-Nano-9B-v2 (Mamba2+attn
hybrid) but that model crashes in the connector at
`TpKVTopology.__post_init__ → attn_backend.get_kv_cache_shape()` →
`NotImplementedError`. We keep both staging jobs (`02-…` for Nemotron,
`02b-…` for Qwen) so both the green and the negative-finding paths can
be reproduced from a clean PVC. See `00-namespace.yaml` for the active
ConfigMap pointing at Qwen, and the `HYBRID_MODEL_*` keys for the
parked Nemotron paths.

**Honest caveat:** the bundled `mooncake.vllm_v1_proxy_server` is a
round-robin proxy that does not populate `transfer_id` /
`do_remote_prefill` / `do_remote_decode` / `remote_*` in
`kv_transfer_params`. Stage A proves both engines coexist, both
`MooncakeConnector` instances initialize, both Transfer Engines bind
their RPC ports, and a request completes end-to-end at the OpenAI
layer — but the decoder is most likely re-prefilling the prompt
locally rather than pulling KV from the prefiller. Stages B and D will
swap to the upstream `vllm/examples/online_serving/disaggregated_serving/`
reference proxy before drawing any throughput conclusion.

## Namespace decision

Y cluster's `mks:customer` group only has a `RoleBinding` in the
**`default`** namespace (`mks-customer-workloads-binding` →
`ClusterRole/mks-customer-workloads`). Creating a new namespace
succeeds, but does NOT auto-grant us workload CRUD inside it.

So **all Stage A objects live in `default`** and carry the label
`prfaas.experiment/stage=A` for grouped lifecycle:

```bash
kubectl -n default delete deploy,svc,job,pvc,cm \
  -l prfaas.experiment/stage=A
```

## Topology

Single node `g126`, Y cluster (`aln1-beta-harsha-g126-beta`),
ns `default`:

```
                                 ┌────────────────────────────┐
   client (curl/bench-job) ──── │  Service: proxy (8000)     │
                                 │  Pod: proxy (round-robin)  │
                                 └──┬───────────────────┬─────┘
                                    │                   │
                                    ▼                   ▼
                ┌──────────────────────┐   ┌──────────────────────┐
                │ Pod: prefiller       │   │ Pod: decoder         │
                │   vllm v1 + MC connr │◀─▶│   vllm v1 + MC connr │
                │   kv_role=producer   │KV │   kv_role=consumer   │
                │   GPUs 0-3 (TP=4)    │tx │   GPUs 4-7 (TP=4)    │
                │   :8010 (api)        │   │   :8020 (api)        │
                │   :8998 (bootstrap)  │   │                      │
                └──────────────────────┘   └──────────────────────┘
                          ▲                        ▲
                          │                        │
                          └─────── Service ────────┘
                            prefiller-bootstrap (headless, 8998 ClusterIP)
                            (decoder dials prefiller-bootstrap.<ns>.svc:8998)
                                    │
                                    ▼
                         PVC: model-weights (RWO, local-path)
                         backed by /opt/local-path-provisioner/...
                         on g126 — populated by an init Job once
```

Two pods, two TP-4 instances, **one shared model PVC** on the local-path
SC. Both pods are pinned to g126 with a `nodeSelector`, so RWO works
fine (single node anyway).

## Pieces

| File | Purpose |
|---|---|
| `00-namespace.yaml` | `prfaas-stagea-env` ConfigMap in `default` (shared env vars: `PRIMARY_MODEL`, `MODEL_LOCAL_DIR`, `PRIMARY_MODEL_SHORT`, ports, TP size). Active model points at Qwen2.5-7B-Instruct; `HYBRID_MODEL_*` keys preserve the parked Nemotron paths. |
| `01-model-pvc.yaml` | `model-weights` PVC, 80 Gi, local-path SC, RWO |
| `02-model-staging-job.yaml` | one-shot `Job` that downloads `nvidia/NVIDIA-Nemotron-Nano-9B-v2` into the PVC (parked — kept on disk to reproduce the negative finding from a clean PVC). |
| `02b-model-staging-job-qwen.yaml` | one-shot `Job` that downloads `Qwen/Qwen2.5-7B-Instruct` into the PVC (active smoke model). |
| `10-prefiller.yaml` | Deployment (replicas=1) for the prefiller. `vllm/vllm-openai:v0.19.1` + initContainer that `pip install --target=/opt/mc mooncake-transfer-engine==0.3.10.post1`. The main container then writes `/tmp/mc_patch.py`, runs it to subclass `SupportsHMA` onto the bundled `MooncakeConnector` in-place, and `exec vllm serve`. Requests `nvidia.com/gpu: 4`, TP=4, kv_role=kv_producer. |
| `11-prefiller-bootstrap-svc.yaml` | Headless ClusterIP exposing port 8998 (Mooncake P2P bootstrap). Decoder resolves `prefiller-bootstrap.default.svc:8998`. |
| `12-prefiller-api-svc.yaml` | ClusterIP exposing the OpenAI HTTP port 8010 (so the proxy can reach it). |
| `20-decoder.yaml` | Same image/init/patch pattern. `nvidia.com/gpu: 4`. kv_role=kv_consumer. |
| `21-decoder-api-svc.yaml` | ClusterIP exposing 8020. |
| `30-proxy.yaml` | Tiny Deployment running `python -m mooncake.vllm_v1_proxy_server` (round-robin, ships in `mooncake-transfer-engine==0.3.10.post1`). Image: `python:3.11-slim` + initContainer `pip install`. **Stages B/D will replace this with `vllm/examples/online_serving/disaggregated_serving/disagg_proxy_demo.py`**, which actually injects `transfer_id` / `do_remote_*` so the decoder pulls KV from the prefiller. |
| `31-proxy-svc.yaml` | ClusterIP (8000) for in-cluster smoke; optional NodePort for quick `curl` from the operator's laptop via `kubectl port-forward`. |
| `90-smoke-job.yaml` | A `Job` that runs a single chat completion `curl` against the proxy and asserts a 200 + non-empty response. Used as the gate before bench. Reads the model name from the `prfaas-stagea-env` ConfigMap so swapping models requires no edit here. |

## Bring-up sequence (operator-driven)

```bash
# 0. point at Y cluster
export KUBECONFIG=~/Code/VP/kubeconfigs/aln1-beta-harsha-g126-beta.kubeconfig.yaml

# 1. config map
kubectl apply -f 00-namespace.yaml

# 2. provision the PVC and download the active dense smoke model
#    (Qwen2.5-7B-Instruct, ~15 GiB, ~1 min on this rig with hf-transfer):
kubectl apply -f 01-model-pvc.yaml -f 02b-model-staging-job-qwen.yaml
kubectl -n default wait --for=condition=complete job/model-staging-qwen --timeout=15m
kubectl -n default logs job/model-staging-qwen --tail=20

# 2b. (optional) also stage Nemotron-Nano-9B-v2 to reproduce the
#     negative finding from a clean PVC (~17 GiB, similar timing):
# kubectl apply -f 02-model-staging-job.yaml
# kubectl -n default wait --for=condition=complete job/model-staging --timeout=45m

# 3. start prefiller and its services
kubectl apply -f 10-prefiller.yaml -f 11-prefiller-bootstrap-svc.yaml -f 12-prefiller-api-svc.yaml
kubectl -n default rollout status deploy/prefiller --timeout=10m
kubectl -n default logs deploy/prefiller --tail=200 | grep -Ei "Mooncake|MooncakeConnector|listening|ready"

# 4. start decoder
kubectl apply -f 20-decoder.yaml -f 21-decoder-api-svc.yaml
kubectl -n default rollout status deploy/decoder --timeout=10m
kubectl -n default logs deploy/decoder --tail=200 | grep -Ei "Mooncake|MooncakeConnector|consumer|ready"

# 5. start the proxy
kubectl apply -f 30-proxy.yaml -f 31-proxy-svc.yaml
kubectl -n default rollout status deploy/proxy --timeout=2m

# 6. one-shot smoke (model name is read from the ConfigMap)
kubectl delete job/smoke --ignore-not-found
kubectl apply -f 90-smoke-job.yaml
kubectl -n default wait --for=condition=complete job/smoke --timeout=2m
kubectl -n default logs -l job-name=smoke
# Expected: [smoke] http=200, [smoke] body=…"content":"OK"…, [smoke] OK

# 7. (manual) port-forward + concurrency cell from the laptop, OR
#    launch a k8s Job that runs scripts/run_concurrency_sweep.sh against
#    proxy.default.svc:8000. To be added once the smoke is green.
```

## Tear-down

```bash
kubectl -n default delete deploy,svc,job,pvc,cm \
  -l prfaas.experiment/stage=A
```

PVC is reclaim-policy=Delete by default for local-path, so the model
bytes are freed too. Background pod terminations finish in <30 s.

## Open questions (still on the operator)

1. **Custom image vs initContainer pip install.** The initContainer
   approach pulls `mooncake-transfer-engine` from PyPI on every pod
   start (~30 s). For Stage A this is fine. For Stage D we should bake
   a small image and push it to Docker Hub or to a registry both
   clusters can reach. **Default plan: build one after Stage A is
   green, push to Docker Hub under our account.**

2. **Pod-Security policy.** Y's `default` ns has no Pod-Security
   labels — we expect privileged/baseline behavior is fine. If the
   first pod apply rejects (initContainer running as root, mooncake
   binding low ports, etc.), we'll add `runAsUser: 0` /
   `securityContext.privileged: true` and re-test. Stage A doesn't
   need hostNetwork; that's only Stage D.

3. **HuggingFace gating.** Both currently staged models
   (Qwen2.5-7B-Instruct and Nemotron-Nano-9B-v2) are publicly readable.
   No `HF_TOKEN` Secret needed. If we later switch to a gated model
   (e.g. Llama-3.1-8B-Instruct), the staging Job needs a `Secret` with
   the token mounted as `HUGGING_FACE_HUB_TOKEN`.

4. **Hybrid-model swap-back.** When upstream lands a hybrid-aware
   connector (see `prfaas/PAPER_MODEL_PLAN.md`), reverting Stage A to
   Nemotron is a one-line ConfigMap edit:
   ```bash
   kubectl patch configmap prfaas-stagea-env --type=merge -p \
     '{"data":{"PRIMARY_MODEL":"nvidia/NVIDIA-Nemotron-Nano-9B-v2",
               "MODEL_LOCAL_DIR":"/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2",
               "PRIMARY_MODEL_SHORT":"nemotron-nano-9b-v2"}}'
   kubectl rollout restart deploy/prefiller deploy/decoder
   ```
   The SupportsHMA in-place patch in `10-prefiller.yaml` and
   `20-decoder.yaml` is idempotent and stays put — it's a no-op for
   dense models and a prerequisite for any future hybrid attempt.
