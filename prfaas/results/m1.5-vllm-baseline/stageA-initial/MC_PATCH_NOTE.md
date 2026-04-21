# In-place patch of vLLM v0.19.1 MooncakeConnector — why and what we found

## Summary in one sentence

We patched `vllm.distributed.kv_transfer.kv_connector.v1.mooncake.mooncake_connector.MooncakeConnector`
in-place at pod startup to subclass `SupportsHMA` (and added
`--no-disable-hybrid-kv-cache-manager` to the `vllm serve` CLI). That successfully
unblocks the **scheduler-side** hybrid-allocator gate, but exposes a **deeper**
upstream limitation: the `MooncakeConnectorWorker` itself only supports a single
attention backend, so **FA + Mamba2 hybrids (Nemotron-Nano-9B-v2) still fail to
start** with `NotImplementedError` from `attn_backend.get_kv_cache_shape(...)`.

## Background — why we patched in the first place

vLLM v0.19.1 (the latest release as of 2026-04-19) introduced a hybrid memory
allocator (HMA) gate that auto-disables HMA whenever `--kv-transfer-config` is
set, **unless** the connector subclasses `SupportsHMA`. Refs:

- vllm-project/vllm PR #25712 — introduces `SupportsHMA` ABC in
  `vllm/distributed/kv_transfer/kv_connector/v1/base.py`. The single abstract
  method is `request_finished_all_groups(self, request, block_ids: tuple[list[int], ...])`.
- vllm-project/vllm PR #27592 — enforces the auto-disable when
  `--kv-transfer-config` is set and the user did not explicitly opt back in
  with `--no-disable-hybrid-kv-cache-manager`. Code:
  `vllm/config/vllm.py` lines ~1227-1244.
- vllm-project/vllm PR #35758 (merged 2026-03-06) — adds `SupportsHMA` to
  `NixlConnector` for **FA + SWA** hybrids (`request_finished_all_groups`
  delegates to the existing scheduler with the multi-group tuple).
- vllm-project/vllm PR #36687 (RFC-level, **not merged** as of 2026-04-19) —
  proposes FA + Mamba2 NIXL support. Tracked under RFC #36780.
- `MooncakeConnector` does **not** subclass `SupportsHMA` in any released
  vLLM version or in upstream `main` (verified 2026-04-19 against
  `https://raw.githubusercontent.com/vllm-project/vllm/main/vllm/distributed/kv_transfer/kv_connector/v1/mooncake/mooncake_connector.py`).

Without HMA the engine cannot accept the hybrid cache spec for FA+Mamba2 and
crashes during `unify_hybrid_kv_cache_specs(...)` with:

```
ValueError: Hybrid KV cache manager is disabled but failed to convert the
KV cache specs to one unified type.
```

This was the original Stage A blocker. Operator approved patching
MooncakeConnector ourselves to subclass `SupportsHMA`.

## What the patch does

The patch is applied **in-place** by the main vllm container's startup script
(see `prfaas/m1.5-vllm-baseline/k8s/stageA/10-prefiller.yaml` and `20-decoder.yaml`).
It runs **before** `exec vllm serve`. It is fully **idempotent** (skips edits if
`SupportsHMA` is already present in the source) and **reversible** (no image
rebuild — clean rollback is `kubectl apply` of the original manifests, restart
the pod, and the freshly-pulled image layer is back to upstream v0.19.1).

The patcher edits exactly one file:
`/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/mooncake/mooncake_connector.py`

Edits:

1. Add `SupportsHMA` to the import block from
   `vllm.distributed.kv_transfer.kv_connector.v1.base`.
2. Change `class MooncakeConnector(KVConnectorBase_V1):` to
   `class MooncakeConnector(KVConnectorBase_V1, SupportsHMA):`.
3. Insert a new `request_finished_all_groups(self, request, block_ids: tuple[list[int], ...])`
   method that flattens all KV-cache groups into one list and delegates to the
   existing single-group `request_finished`. This is a **minimum-viable shim**
   that unblocks the SupportsHMA gate. Cross-DC fidelity for FA+Mamba2 SSM
   state is **NOT** verified by this patch.

The patcher also runs a sanity check that imports the patched module and asserts
`issubclass(MooncakeConnector, SupportsHMA)` before the engine starts.

We additionally pass `--no-disable-hybrid-kv-cache-manager` to `vllm serve` so
the auto-disable in `vllm/config/vllm.py:1227-1244` does not fire even with
`--kv-transfer-config` set. (vLLM's own warning message recommends this flag
when a connector implements `SupportsHMA`.)

## Result of the patch

- The patch is applied successfully on every pod start. The sanity check passes:
  `[mc-patch] sanity OK: MooncakeConnector is subclass of SupportsHMA`.
- The original `ValueError` about "Hybrid KV cache manager is disabled" is
  **gone** from both prefiller and decoder pods.
- See `patch_confirmation.log` for the actual log lines.

## NEW blocker discovered after the patch (the one that stopped Stage A)

With HMA enabled, vLLM constructs a multi-group KV cache spec for
Nemotron-Nano-9B-v2 (FA layers + Mamba2 layers). The
`MooncakeConnectorWorker.__init__` then runs and crashes with:

```
File ".../mooncake_connector.py", line 773, in __init__
    self.kv_topo = TpKVTopology(...)
File ".../kv_transfer/kv_connector/utils.py", line 345, in __post_init__
    kv_cache_shape: tuple[int, ...] = attn_backend.get_kv_cache_shape(...)
File "/usr/local/lib/python3.12/dist-packages/vllm/v1/attention/backend.py", line 91, in get_kv_cache_shape
    raise NotImplementedError
NotImplementedError
```

Root cause is on **line 748** of `mooncake_connector.py` (v0.19.1):

```python
# Get the attention backend from the first layer
# NOTE (NickLucche) models with multiple backends are not supported yet
backend = get_current_attn_backend(vllm_config)
...
self.kv_topo = TpKVTopology(
    ...,
    attn_backends=[backend],   # single backend only
)
```

`get_current_attn_backend(vllm_config)` returns the backend of the **first**
layer. For Nemotron-Nano-9B-v2 (which has Mamba2 layers in early positions),
that backend's `get_kv_cache_shape` is the unimplemented base-class default and
raises `NotImplementedError`. Even if it returned the FA backend, the connector
would still mis-handle the Mamba2 group, because the worker is hard-coded to
treat all groups with the same backend.

This is **not** a bug in our SupportsHMA shim — `request_finished_all_groups`
is never reached. The blocker is in `MooncakeConnectorWorker.__init__`, in
upstream code we did not touch, and is a fundamental limitation that the
in-source comment explicitly acknowledges: "models with multiple backends are
not supported yet".

## Why we stopped here (per Stage A unblock-agent contract)

The unblock-agent prompt's hard constraint says:

> If the patch approach fails for a fundamental reason …, STOP and report —
> switching to a baked custom image of newer vLLM is a separate decision the
> operator must approve.

This is exactly that scenario, but in the opposite direction from the worry
the prompt anticipated: `SupportsHMA` **is** in v0.19.1's `base.py` and the
patch took cleanly; the blocker is on the worker side, in code that explicitly
does not support hybrid models.

We therefore did not run the smoke job (Phase 5) and did not produce
`smoke.log` / `kv_transfer_evidence.log`. The pods are scaled back to 0
to release GPU resources.

## Options for the operator

In rough order of effort:

1. **Try a non-hybrid model on the same setup.** Any pure-FA model
   (Llama-class, Qwen2.5-class) should now start with the patched
   MooncakeConnector and `--no-disable-hybrid-kv-cache-manager`. This validates
   the rest of the Mooncake KV-transfer pipeline end-to-end while we wait
   upstream.
2. **Wait for upstream FA+Mamba2 support.** RFC #36780 / PR #36687 in
   vllm-project/vllm covers FA+Mamba2 NIXL. Once that lands and a `MooncakeConnector`
   equivalent is written (or the same hybrid-aware `TpKVTopology` machinery is
   shared between Nixl and Mooncake), Stage A can re-target Nemotron without a
   custom image.
3. **Patch `MooncakeConnectorWorker` ourselves.** Concretely: build a list of
   per-group `TpKVTopology` instances (one per kv_cache_group) instead of one,
   and propagate group-aware indexing through `register_kv_caches`,
   `start_load_kv`, `wait_for_save`, and the bootstrap-server / sender / receiver
   code paths. This is a non-trivial refactor of ~500-700 LOC and overlaps
   with the upstream RFC; doing it in-tree is high-risk and likely to need
   re-doing once upstream lands. **Operator decision required.**
4. **Bake a custom vLLM image with the worker patch.** Same scope as (3) plus
   image-build / registry / supply-chain work. Explicitly out-of-scope per
   this agent's hard constraints; needs operator approval.

## Files of interest in this stage's results dir

- `MC_PATCH_NOTE.md` (this file)
- `SUMMARY.md` — top-level outcome
- `patch_confirmation.log` — the `[mc-patch]` lines proving the patch applied
  and the sanity check passed
- `worker_init_blocker.log` — grep'd error trace from both pods showing the
  new `NotImplementedError` blocker
- `prefiller_full.log`, `decoder_full.log` — full vllm-container logs (last
  3000 lines each) from the failed pods
- `install_mooncake_init.log` — initContainer log proving
  `mooncake-transfer-engine==0.3.10.post1` was installed cleanly into
  `/opt/mc` for cp312
