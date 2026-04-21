# Stage A — Single-host PD smoke on g126 (dfw1-beta)

**Date:** 2026-04-20  **Branch:** `feat/prfaas-m1.5-vllm-baseline`
**Cluster:** `aln1-beta-harsha-g126-beta` (1 node, 8× H100 80 GB)
**Image:** `vllm/vllm-openai:v0.19.1`
**Connector:** `MooncakeConnector` (vLLM v1) + in-place SupportsHMA patch
**Active model:** `Qwen/Qwen2.5-7B-Instruct` (dense, 7.6B params, FP16/BF16)
**Parked model:** `nvidia/NVIDIA-Nemotron-Nano-9B-v2` (hybrid Mamba2+attn, see MC_PATCH_NOTE.md)

---

## Result

| Probe | Outcome |
| --- | --- |
| Model staging (Qwen2.5-7B-Instruct → PVC) | **GREEN** — 15 GiB in 48 s via `huggingface-cli` + `hf-transfer` |
| Prefiller (TP=4, kv_producer) `Ready` | **GREEN** — `/v1/models` returns 200, weights loaded in 1.73 s, torch.compile cached, KV cache 59.04 GiB/rank |
| Decoder (TP=4, kv_consumer) `Ready` | **GREEN** — same as above, distinct `engine_id` |
| Mooncake Transfer Engine init on all 8 workers | **GREEN** — RPC P2P handshake listening on the prefiller (`172.28.0.100:1522[09…]`) and decoder (`172.28.0.227:150[68…]`); ports inside our firewall range |
| HCA topology discovery | **0 HCAs** — pod is on the cluster pod network, not host-network, so no RDMA NICs visible. Expected for Stage A (single-host smoke); **must be revisited for Stage D** (cross-DC) where we need either RDMA via SR-IOV/host-network or TCP fallback explicitly enabled |
| `MooncakeConnector` `SupportsHMA` shim applied | **GREEN** — `[mc-patch] sanity OK: MooncakeConnector is subclass of SupportsHMA` on both pods |
| Proxy (`mooncake.vllm_v1_proxy_server`) up | **GREEN** — uvicorn on `:8000`, both upstreams reachable through ClusterIP |
| Smoke (`POST /v1/chat/completions`, model=qwen2.5-7b-instruct) | **GREEN — HTTP 200, content `"OK"`, 35 prompt + 2 completion tokens** |
| Cross-pod KV actually transferred end-to-end | **PARTIAL — see "Caveat" below** |

```
[smoke] http=200
[smoke] body={"id":"chatcmpl-…","object":"chat.completion","created":1776672747,
              "model":"qwen2.5-7b-instruct",
              "choices":[{"index":0,
                          "message":{"role":"assistant","content":"OK", …},
                          "finish_reason":"stop", …}],
              "usage":{"prompt_tokens":35,"total_tokens":37,"completion_tokens":2,…},
              "kv_transfer_params":null}
```

## Caveat: bundled proxy doesn't drive the full PD protocol

When the smoke request hit the prefiller, the worker logged:

```
WARNING 04-20 08:12:27 [mooncake_connector.py:563]
   Missing transfer_id in kv_transfer_params from router!
```

The proxy shipped in `mooncake-transfer-engine==0.3.10.post1`
(`mooncake.vllm_v1_proxy_server`) is a thin round-robin that forwards
requests to prefiller and decoder without populating
`kv_transfer_params.transfer_id` / `do_remote_prefill` / `do_remote_decode`
/ `remote_engine_id` / `remote_block_ids` / `remote_host` / `remote_port`.

Net effect for Stage A: both halves are real vLLM engines with
`MooncakeConnector` initialized and Transfer Engines listening, but the
**KV blocks are not actually being pulled across pods** — the decoder is
re-prefilling the prompt locally to satisfy the request. So the smoke
proves:
- the patched HMA gate works,
- both engines coexist on one host,
- the connector path is wired all the way through,
- and a request can complete end-to-end through the proxy.

It does **not** yet prove that disaggregation produces a measurable
prefill/decode split. That requires a proxy that speaks the full v1 PD
protocol (constructs `transfer_id`, sets `do_remote_decode=true` on the
prefiller hop with `max_tokens=1`, then `do_remote_prefill=true` on the
decoder hop with the prefiller's returned block_ids/engine_id/host/port).
The reference implementation lives in
`vllm/examples/online_serving/disaggregated_serving/` and we will swap
it in for Stage B.

This is a P1 follow-up but **does not block Stage A**. Stage A's
exit criterion is "single-host PD plumbing is reproducible", and that
is satisfied.

## Files in this directory

| File | Bytes | What it contains |
| --- | --- | --- |
| `SUMMARY.md` | this file | the human-readable Stage A report |
| `MC_PATCH_NOTE.md` | — | full write-up of the SupportsHMA patch + Mamba2 NotImplementedError finding |
| `nemotron_failure_prefiller.log` | — | 546-line raw transcript of the failing Nemotron-Nano-9B-v2 prefiller pod |
| `smoke.log` | — | raw output of the `smoke` Job pod |
| `kv_transfer_evidence.log` | — | concatenated tails of proxy + prefiller (vllm) + decoder (vllm) logs around the smoke window |

## Key timings (on g126, BF16, TP=4)

| Phase | Duration | Source |
| --- | --- | --- |
| Pod schedule → init container start | <2 s | `kubectl describe pod` events |
| `pip install mooncake-transfer-engine==0.3.10.post1` (init container) | ~10 s | install-mooncake initContainer logs |
| `pip install` cold cache → wheel cached | n/a (wheel ships) | n/a |
| Weights load (Qwen2.5-7B-Instruct, 4 shards, local PVC) | 1.73 s | `Loading weights took 1.73 seconds` |
| torch.compile (two compile ranges) | 18.26 s | `torch.compile took 18.26 s in total` |
| CUDA graphs profile + capture | ~1.2 s | `Initial profiling/warmup run took 1.23 s` |
| KV cache allocation per rank | 59.04 GiB | `Available KV cache memory: 59.04 GiB` |
| First `/v1/models` 200 after pod start | ~3 m | readiness probe transition |
| Smoke request total wall time | <1 s | curl exit immediate after streaming |

## Reproduction

From `prfaas/m1.5-vllm-baseline/k8s/stageA/`:

```bash
export Y_KC=/path/to/aln1-beta-harsha-g126-beta.kubeconfig.yaml

# Apply (idempotent):
KUBECONFIG=$Y_KC kubectl apply -f 00-namespace.yaml \
                               -f 01-model-pvc.yaml \
                               -f 02b-model-staging-job-qwen.yaml

# Wait for the staging Job (≈1 min for Qwen2.5-7B):
KUBECONFIG=$Y_KC kubectl wait --for=condition=complete job/model-staging-qwen --timeout=10m

# Bring up serving + proxy:
KUBECONFIG=$Y_KC kubectl apply -f 10-prefiller.yaml \
                               -f 11-prefiller-bootstrap-svc.yaml \
                               -f 12-prefiller-api-svc.yaml \
                               -f 20-decoder.yaml \
                               -f 21-decoder-api-svc.yaml \
                               -f 30-proxy.yaml \
                               -f 31-proxy-svc.yaml

# Wait for both deployments:
KUBECONFIG=$Y_KC kubectl rollout status deploy/prefiller --timeout=10m
KUBECONFIG=$Y_KC kubectl rollout status deploy/decoder   --timeout=10m
KUBECONFIG=$Y_KC kubectl rollout status deploy/proxy     --timeout=2m

# Smoke:
KUBECONFIG=$Y_KC kubectl delete job/smoke --ignore-not-found
KUBECONFIG=$Y_KC kubectl apply -f 90-smoke-job.yaml
KUBECONFIG=$Y_KC kubectl wait --for=condition=complete job/smoke --timeout=2m
KUBECONFIG=$Y_KC kubectl logs -l job-name=smoke
```

Tear-down (Y cluster RBAC: `default` namespace only):

```bash
KUBECONFIG=$Y_KC kubectl -n default delete deploy,svc,job,pvc,cm \
   -l prfaas.experiment/stage=A
```
