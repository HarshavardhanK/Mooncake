# Stage A — Mooncake-on-vLLM 1P1D bring-up — STATUS: BLOCKED on upstream

## Outcome (one-liner)

The SupportsHMA in-place patch on `MooncakeConnector` works as intended and
clears the original startup `ValueError`. Stage A is then blocked by a
**different**, deeper upstream limitation in `MooncakeConnectorWorker` that
explicitly does not support multi-backend (FA + Mamba2) hybrid models. No
workaround is in scope for this agent. Smoke job NOT executed. See
`MC_PATCH_NOTE.md`.

## Run metadata

| | |
|---|---|
| Timestamp (UTC) | 2026-04-20T07:35Z |
| Cluster | Y / `harsha-g126-beta` (single-node beta MKSv2) |
| Node | `g126` (4× H100 80GB HBM3) |
| Namespace | `default` |
| Model | `nvidia/NVIDIA-Nemotron-Nano-9B-v2` (FA + Mamba2 hybrid) |
| Model PVC | `model-weights` (Bound, 80Gi, `local-path` SC) |
| ConfigMap | `prfaas-stagea-env` (intact, 10 keys) |
| vLLM image | `vllm/vllm-openai:v0.19.1` (cp312) |
| initContainer image | `python:3.12-slim` (matches main container's cp312 to provide ABI-compatible mooncake wheel) |
| Mooncake transfer engine | `mooncake-transfer-engine==0.3.10.post1` (pip-installed to `/opt/mc`, mounted readonly) |
| TP per side | 4 |
| Ports | prefiller API 8010, prefiller bootstrap 8998, decoder API 8020 |
| MooncakeConnector patch | in-place via main container startup script — adds `SupportsHMA` base + flat `request_finished_all_groups` shim + `--no-disable-hybrid-kv-cache-manager` CLI flag |

## Phase outcomes

| Phase | Outcome |
|---|---|
| 1. Research patch | OK — `SupportsHMA` confirmed present in v0.19.1 `base.py`; NixlConnector pattern in `vllm/distributed/kv_transfer/kv_connector/v1/nixl/connector.py` mirrored |
| 2. Write patcher | OK — text-based, idempotent, AST-validated against the actual v0.19.1 source on host before deploy |
| 3. Apply manifests | OK — `kubectl apply` + `kubectl patch …replicas:1` (no `kubectl scale` due to RBAC) |
| 4. Wait for rollout | FAIL — both pods CrashLoopBackOff. Root cause is **not** the patch (the patch's sanity check passes every restart). Root cause is `MooncakeConnectorWorker.__init__` calling `attn_backend.get_kv_cache_shape(...)` on the Mamba2 backend, which raises `NotImplementedError`. See `worker_init_blocker.log`. |
| 5. Smoke test | NOT RUN — no usable engine to point the proxy at |
| 6. Capture evidence | OK (this directory) |
| 7. Commits | OK (see commit B) |

## Restart history at the time of stop

```
prefiller-547d8c869b-5dp7v   0/1   CrashLoopBackOff   5  ~10m
decoder-5fd59678c7-h4pvn     0/1   CrashLoopBackOff   5  ~10m
```

After capturing evidence, both deployments were patched back to
`replicas: 0` to release GPU resources.

## Smoke job HTTP code + body excerpt

`N/A` — engine never reaches the `/v1/models` readiness check; proxy not
applied.

## What the patch did prove

- The `[mc-patch]` script applies the SupportsHMA base + `request_finished_all_groups`
  shim cleanly on every pod start.
- The sanity check passes:
  `[mc-patch] sanity OK: MooncakeConnector is subclass of SupportsHMA`.
- The original Stage A blocker
  `ValueError: Hybrid KV cache manager is disabled but failed to convert the KV
  cache specs to one unified type` is **gone**.
- See `patch_confirmation.log`.

## What is now blocking Stage A

`MooncakeConnectorWorker.__init__` in v0.19.1 (and in upstream `main` as of
2026-04-19) explicitly comments at line 748:

```python
# NOTE (NickLucche) models with multiple backends are not supported yet
backend = get_current_attn_backend(vllm_config)
```

…and constructs a single `TpKVTopology` with that one backend. For a hybrid
FA + Mamba2 model, the first-layer backend's `get_kv_cache_shape` raises
`NotImplementedError`, which kills the worker:

```
File ".../mooncake_connector.py", line 773, in __init__
    self.kv_topo = TpKVTopology(...)
File ".../kv_transfer/kv_connector/utils.py", line 345, in __post_init__
    kv_cache_shape: tuple[int, ...] = attn_backend.get_kv_cache_shape(...)
File ".../vllm/v1/attention/backend.py", line 91, in get_kv_cache_shape
    raise NotImplementedError
```

This is the Mooncake-side analog of upstream NIXL's still-unmerged FA+Mamba2
work (RFC #36780 / PR #36687). See `MC_PATCH_NOTE.md` for the full options
analysis and the reasoning for stopping per the unblock-agent contract.

## Files in this directory

- `SUMMARY.md` (this file)
- `MC_PATCH_NOTE.md` — full patch rationale, what worked, what didn't, options
- `patch_confirmation.log` — proves the patch applied and the sanity assertion passed
- `worker_init_blocker.log` — proves the new blocker is in
  `MooncakeConnectorWorker.__init__` → `TpKVTopology` → `get_kv_cache_shape`
- `prefiller_full.log`, `decoder_full.log` — full vllm-container logs from the
  CrashLoopBackOff pods (last 3000 lines)
- `install_mooncake_init.log` — proves cp312 wheel for `mooncake-transfer-engine==0.3.10.post1` installed into `/opt/mc`
