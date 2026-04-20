# Stage A — single-cluster 1P1D smoke on Y (g126), Kubernetes path

**Replaces** `prfaas/m1.5-vllm-baseline/STAGE_A_PLAN.md` (host-install
version). The host plan is kept for archive only — DO NOT use it.

**Purpose:** prove the Mooncake-vLLM v1 disaggregated stack works
end-to-end on Y, deployed via `kubectl apply`, no `pip install` on the
host. If green, the same image + manifest pattern lifts to Stage D
(cross-DC) with only network-path changes.

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
| `00-namespace.yaml` | `prfaas-stagea-env` ConfigMap in `default` (shared env vars). No new ns is created. |
| `01-model-pvc.yaml` | `model-weights` PVC, 80 Gi, local-path SC, RWO |
| `02-model-staging-job.yaml` | one-shot `Job` that downloads `nvidia/NVIDIA-Nemotron-Nano-9B-v2` into the PVC. Uses `huggingface/transformers-pytorch-cpu` to keep the image small; we only need `huggingface_hub`. |
| `10-prefiller.yaml` | Pod (or Deployment, replicas=1) for the prefiller. `vllm/vllm-openai:v0.19.1` + initContainer that `pip install --target=/opt/mc mooncake-transfer-engine`, then sets `PYTHONPATH`. Requests `nvidia.com/gpu: 4`. |
| `11-prefiller-bootstrap-svc.yaml` | Headless ClusterIP exposing port 8998 (Mooncake P2P bootstrap). Decoder resolves `prefiller-bootstrap.prfaas-stagea.svc:8998`. |
| `12-prefiller-api-svc.yaml` | ClusterIP exposing the OpenAI HTTP port 8010 (so the proxy can reach it). |
| `20-decoder.yaml` | Same image/init pattern. `nvidia.com/gpu: 4`. Sets the connector to `kv_consumer` with the prefiller's bootstrap Service as remote. |
| `21-decoder-api-svc.yaml` | ClusterIP exposing 8020. |
| `30-proxy.yaml` | Tiny Deployment running `prfaas/m1.5-vllm-baseline/scripts/...` proxy script (or `benchmarks/disaggregated_prefill/disagg_proxy_demo.py` from upstream Mooncake). Image: `python:3.11-slim` + `pip install fastapi uvicorn httpx` via initContainer. |
| `31-proxy-svc.yaml` | ClusterIP (8000) for in-cluster smoke; optional NodePort for quick `curl` from the operator's laptop via `kubectl port-forward`. |
| `90-smoke-job.yaml` | A `Job` that runs a single chat completion `curl` against the proxy and asserts a 200 + non-empty response. Used as the gate before bench. |

## Bring-up sequence (operator-driven)

```bash
# 0. point at Y cluster
export KUBECONFIG=~/Code/VP/kubeconfigs/aln1-beta-harsha-g126-beta.kubeconfig.yaml

# 1. config map
kubectl apply -f 00-namespace.yaml

# 2. provision the PVC and download the model (~18 GB, ~15-30 min)
kubectl apply -f 01-model-pvc.yaml -f 02-model-staging-job.yaml
kubectl -n default wait --for=condition=complete job/model-staging --timeout=45m
kubectl -n default logs job/model-staging --tail=20

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

# 6. one-shot smoke
kubectl apply -f 90-smoke-job.yaml
kubectl -n default wait --for=condition=complete job/smoke --timeout=2m
kubectl -n default logs job/smoke

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

3. **HuggingFace gating.** Nemotron-Nano-9B-v2 is publicly readable
   (verified `HEAD https://huggingface.co/api/models/...` → 200). No
   `HF_TOKEN` Secret needed. If we later switch to a gated model, the
   staging Job needs a `Secret` with the token mounted as
   `HUGGING_FACE_HUB_TOKEN`.
