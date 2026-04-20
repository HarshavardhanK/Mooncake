# Stage A — MooncakeConnector + hybrid model finding

**Date:** 2026-04-20  **Cluster:** dfw1-beta / g126 (1× H100×8, kubeconfig
`vpcloud-slurm-v2-admin`)  **Image:** `vllm/vllm-openai:v0.19.1`  **Wheel:**
`mooncake-transfer-engine==0.3.10.post1`  **Connector:**
`vllm.distributed.kv_transfer.kv_connector.v1.mooncake.MooncakeConnector`

## TL;DR

vLLM v0.19.1's bundled `MooncakeConnector` **cannot serve hybrid
Mamba2+attention models**, even with the `SupportsHMA` shim applied. The
deeper blocker is in `TpKVTopology`: it iterates every layer's attention
backend and calls `get_kv_cache_shape(...)`, which the Mamba2 backend
explicitly raises `NotImplementedError` for. This is a structural gap, not
a flag flip.

For Stage A we therefore pivoted the smoke model to **Qwen2.5-7B-Instruct**
(dense, gateless, ~15 GiB, TP=4) and parked Nemotron-Nano-9B-v2 as the
**negative-finding artifact** (kept on the PVC, kept in the ConfigMap as
`HYBRID_MODEL_*`, evidence below).

This is the first PrfaaS-paper-relevant finding the rig has produced: the
paper claims hybrid-attention models are *the* class that justifies
cross-DC prefill offload, but the open-source connector path to actually
serve them is broken at the latest released vLLM version. Re-running
hybrid models is tracked in `prfaas/docs/10-paper/PAPER_MODEL_PLAN.md`.

## Layered failures we observed (in the order vLLM tripped over them)

1. **Stock connector, no patch** → engine fails at startup with
   ```
   ValueError: Hybrid KV cache manager is disabled but failed to
   convert the KV cache specs to one unified type.
   ```
   Cause: vLLM v0.19.1 disables the Hybrid Memory Allocator (HMA) the
   moment `--kv-transfer-config` is non-empty, *unless* the connector
   subclasses `vllm.distributed.kv_transfer.kv_connector.v1.base.SupportsHMA`.
   `MooncakeConnector` does not. Hybrid models like Nemotron-Nano-9B-v2
   *require* HMA because their KV cache specs are not uniform (4 attention
   layers + 52 Mamba-2 layers). Net: engine refuses to start. Gate
   reference: vllm-project/vllm PR #25712 (introduced `SupportsHMA`),
   PR #27592 (enforced the gate for connectors).

2. **With our in-place `SupportsHMA` patch** (10/20-prefiller/decoder
   `initContainer` writes `mc_patch.py` and runs it inside the vLLM
   container before `exec vllm serve`):
   - `mc-patch] applied SupportsHMA to MooncakeConnector at .../mooncake_connector.py`
   - `mc-patch] sanity OK: MooncakeConnector is subclass of SupportsHMA`
   - Model weights load (1.73 s, 4.17 GiB on each TP rank), torch.compile
     completes (18.26 s, two compile ranges cached), CUDA graphs profiled
     (0.71 GiB total), 59.04 GiB KV cache allocated per rank.
   - Then **all four workers crash simultaneously** with:
     ```
     File ".../v1/mooncake/mooncake_connector.py", line 773, in __init__
       self.kv_topo = TpKVTopology(
     File ".../kv_connector/utils.py", line 345, in __post_init__
       kv_cache_shape: tuple[int, ...] = attn_backend.get_kv_cache_shape(
     File ".../v1/attention/backend.py", line 91, in get_kv_cache_shape
       raise NotImplementedError
     NotImplementedError
     ```
   - The base-class default for `get_kv_cache_shape` is
     `raise NotImplementedError`. Mamba2's backend in vLLM v0.19.1 does not
     override it, because Mamba SSM state is not a (block, kv_heads,
     head_dim) cube. `TpKVTopology` was written assuming uniform attention
     layers, so it can't even enumerate the Mamba2 layer's layout, much
     less plan a cross-rank/cross-host transfer of that state.

   Full transcript: `nemotron_failure_prefiller.log` (this directory),
   546 lines, both stderr+stdout from a TP-4 prefiller pod on g126.

## Why we don't try to "fix it harder"

A working FA + Mamba2 KV connector requires three things vLLM 0.19.1 does
not have today:

- A Mamba2-aware `get_kv_cache_shape()` (or an explicit per-layer-type
  branch in `TpKVTopology`) that knows the (chunk, headdim, state_size)
  shape and contiguous slab layout used for Mamba SSM state.
- A connector path that registers a *separate* memory region for the SSM
  state and transfers it along with the KV blocks (it's not just bigger,
  it's structurally different: gating tensors, Δ, ssm_state).
- A producer/consumer protocol that knows how many SSM-state bytes belong
  to each request_id so the consumer can drop them into the correct rank's
  contiguous region.

Upstream:
- `MooncakeConnector` on `main` (as of 2026-04-20) still does not subclass
  `SupportsHMA` and still calls into `TpKVTopology` the same way.
- The closest in-flight design is the NIXL connector RFC (vllm-project/vllm
  PR #36687), which is RFC-only and not merged.
- No released vLLM connector supports Mamba2 PD-disaggregation.

So writing a deeper patch in this fork would mean re-implementing the
hybrid KV transfer protocol from scratch. That is a research project, not a
Stage A unblock. We log the finding and route around it.

## What the patch *does* fix (and why we keep it)

The `SupportsHMA` patch is correct and necessary for any future hybrid
attempt — without it, no engine starts at all. We keep it on every
prefiller/decoder pod even now (with the dense smoke model) for two
reasons:
1. **Idempotency:** for a dense model the patch is a no-op (the dense
   `get_kv_cache_shape` works, HMA is unnecessary, but having it enabled
   doesn't hurt).
2. **Drop-in hybrid swap:** the day a connector lands that handles
   Mamba2 layouts, we change `PRIMARY_MODEL` / `MODEL_LOCAL_DIR` in
   `00-namespace.yaml` and roll out — no other deltas.

The patch implementation lives in
`prfaas/m1.5-vllm-baseline/k8s/stageA/10-prefiller.yaml` and
`20-decoder.yaml` (search for `mc_patch.py`). It is intentionally a small
regex-driven edit of the installed wheel rather than a forked image —
keeps the smoke independent of any Mooncake fork build.

## Files in this directory

| File | What it is |
| --- | --- |
| `MC_PATCH_NOTE.md` | this document |
| `nemotron_failure_prefiller.log` | full prefiller-pod log from the failing run, including the worker traceback above |
| `SUMMARY.md` | high-level Stage A result (smoke green on dense, hybrid blocked on connector) |
| `smoke.log` | smoke-Job pod log (curl→proxy→prefiller→decoder, 200 + content) |
| `kv_transfer_evidence.log` | grep of prefiller+decoder logs around the smoke window showing MooncakeConnector init + transfer params |

## Reproduction (3 commands)

From `prfaas/m1.5-vllm-baseline/k8s/stageA/`:

```bash
# 1. Show the gate that originally tripped us (run with stock connector,
#    i.e. comment out the mc_patch.py block in 10-prefiller.yaml):
KUBECONFIG=$Y_KC kubectl logs -l app=prefiller -c vllm --tail=200

# 2. With patch applied, swap to the hybrid model in the ConfigMap:
KUBECONFIG=$Y_KC kubectl patch configmap prfaas-stagea-env --type=merge -p \
  '{"data":{"PRIMARY_MODEL":"nvidia/NVIDIA-Nemotron-Nano-9B-v2",
            "MODEL_LOCAL_DIR":"/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2",
            "PRIMARY_MODEL_SHORT":"nemotron-nano-9b-v2"}}'
KUBECONFIG=$Y_KC kubectl rollout restart deploy/prefiller deploy/decoder

# 3. Observe the deeper TpKVTopology / get_kv_cache_shape NotImplementedError
#    in worker logs, identical to nemotron_failure_prefiller.log.
```
