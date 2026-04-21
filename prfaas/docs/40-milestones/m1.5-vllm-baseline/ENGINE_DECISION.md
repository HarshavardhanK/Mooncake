# Engine decision for Phase 3 (cross-DC empirical arm)

**Decision (locked 2026-04-20):** the empirical PD-disaggregation arm
runs on **SGLang `v0.5.9-cu129-amd64`** with Mooncake transfer engine
`v0.3.9` (bundled). The vLLM Stage B/C/D scaffolds in
`prfaas/m1.5-vllm-baseline/k8s/{stageB,stageC,stageD}/` are **deprecated
in place** — kept for the historical record but not on the critical path
for the paper-replication run.

## Why SGLang, not vLLM

We started M1.5 on vLLM v0.19.1 because Mooncake's first-class connector
plugin (`MooncakeConnector` v1) targets vLLM. Stage A proved the
plumbing works end-to-end on dense Qwen2.5-7B (HTTP 200, content `OK`,
both engines coexist on one host with Mooncake transfer engines bound).

Three things made vLLM unworkable for the paper-replication arm:

1. **Hybrid models structurally fail on vLLM 0.19.1.** Nemotron-Nano-9B-v2
   is a hybrid Mamba2+attention model and crashes inside
   `TpKVTopology.__post_init__ → attn_backend.get_kv_cache_shape()` —
   the Mamba2 backend raises `NotImplementedError`. The `SupportsHMA`
   shim we shipped (and upstreamed as kvcache-ai/Mooncake#1931) gates
   the Hybrid KV cache manager but does not solve the deeper KV-shape
   dispatch. See `prfaas/results/m1.5-vllm-baseline/stageA/MC_PATCH_NOTE.md`
   for the full failure stack. **Kimi-Linear-48B (Phase 2's pick) hits
   the same class of failure** — KDA layers have a fixed-size recurrent
   state, not a per-token KV cube, so the connector needs a per-layer-type
   shape function.    That work is queued as Path C in
   [`PAPER_MODEL_PLAN.md`](../../10-paper/PAPER_MODEL_PLAN.md) but not on
   the critical path now.
2. **SGLang ships native PD-disaggregation with Mooncake in v0.5.9.**
   Confirmed by both the SGLang release notes and our own in-tree
   integration tests at `scripts/tone_tests/scripts/test_1p1d_erdma.sh`
   and `scripts/tone_tests/scripts/test_epd_sglang.sh`. The CLI is
   `--disaggregation-mode {prefill,decode}` plus
   `--disaggregation-transfer-backend mooncake`; the matching router is
   `python -m sglang_router.launch_router --pd-disaggregation
   --prefill <url> --decode <url>`. SGLang's attention dispatcher handles
   linear-attention (KDA), MLA, Mamba2, and SWA *natively*, so Kimi-Linear,
   Nemotron-Nano-9B, MiMo-V2-Flash all serve out of the box.
3. **The PrfaaS paper itself uses SGLang for Φkv profiling.** Phase 1
   already adopted SGLang for that reason, and the numbers we got
   ([`PHI_KV_TABLE.md`](../../../results/m1.5-vllm-baseline/phase1_phi_kv/PHI_KV_TABLE.md))
   agree qualitatively with the paper's published Table 6. Staying on
   SGLang for Phase 3 keeps engine identity between our analytical and
   empirical arms.

## What we lose by deprecating the vLLM scaffolds

- **Stage A's bundled `mooncake.vllm_v1_proxy_server` caveat is no longer
  relevant.** Stage A could not actually verify cross-pod KV transfer
  because the bundled proxy doesn't populate `transfer_id` /
  `do_remote_prefill` / `do_remote_decode`. SGLang's `sglang_router` with
  `--pd-disaggregation` does drive the full PD protocol — confirmed by
  the integration tests in this repo.
- **Stage B's `configH/configN/configP` per-config rolloutsneed re-authoring
  for SGLang.** Concretely: H = single SGLang server (no
  `--disaggregation-mode`); N = same-host PD split using `--base-gpu-id`;
  P = cross-host (or cross-cluster) PD split. This is straightforward —
  the SGLang flags map 1:1 onto vLLM's `--kv-transfer-config`
  `kv_role` enum. We do this work as part of Phase 3 manifest authoring
  (see `k8s/phase3-smoke/` and `k8s/phase3-xdc/`).
- **The `SupportsHMA` upstream PR (kvcache-ai/Mooncake#1931) becomes
  optional for our paper-replication critical path.** It's still useful
  for vLLM users who want hybrid support; we leave it open and review
  comments as a separate workstream.

## What's deprecated (concretely)

| Path | Status | Action |
|---|---|---|
| `prfaas/m1.5-vllm-baseline/k8s/stageA/` | retained — Stage A is the dense-engine wire-baseline result on Qwen2.5-7B | none |
| `prfaas/m1.5-vllm-baseline/k8s/stageB/` | DEPRECATED for paper-replication | leave files; add deprecation notice; supersede via `k8s/phase3-smoke/` (single-host PD) and `k8s/phase3-xdc/` (cross-DC) |
| `prfaas/m1.5-vllm-baseline/k8s/stageC/` (never authored) | not authored, no longer planned | n/a — RTT sweep moves to a SGLang `tc netem` scaffold under `k8s/phase3-rtt-sweep/` once Phase 3 cross-DC headline lands |
| `prfaas/m1.5-vllm-baseline/k8s/stageD/` | DEPRECATED | leave files; add deprecation notice; supersede via `k8s/phase3-xdc/` |
| `prfaas/m1.5-vllm-baseline/scripts/run_stage_b.sh` (if present) | DEPRECATED | rename to `*.deprecated.sh` |

## Cross-DC flag pattern (target spec)

Authoritative reference: `scripts/tone_tests/scripts/test_1p1d_erdma.sh`
+ `scripts/tone_tests/scripts/common.sh::launch_sglang_server`. We expect
this exact CLI shape in the SGLang `v0.5.9-cu129-amd64` image; verified
against the in-tree tests (which use the same image family).

```bash
# Prefiller (cluster X / g304):
python -m sglang.launch_server \
    --model-path /models/moonshotai_Kimi-Linear-48B-A3B-Instruct \
    --host 0.0.0.0 --port 30001 \
    --tp-size 8 \
    --disaggregation-mode prefill \
    --disaggregation-transfer-backend mooncake \
    --disaggregation-bootstrap-port 8998 \
    --trust-remote-code \
    --mem-fraction-static 0.85

# Decoder (cluster Y / g126):
python -m sglang.launch_server \
    --model-path /models/moonshotai_Kimi-Linear-48B-A3B-Instruct \
    --host 0.0.0.0 --port 30001 \
    --tp-size 8 \
    --disaggregation-mode decode \
    --disaggregation-transfer-backend mooncake \
    --trust-remote-code \
    --mem-fraction-static 0.85

# Router (cluster Y / g126, user-facing):
python -m sglang_router.launch_router \
    --pd-disaggregation \
    --prefill http://<g304-public-ip>:30001 \
    --decode  http://decoder.default.svc:30001 \
    --host 0.0.0.0 --port 8000
```

Mooncake itself is configured via `MOONCAKE_CONFIG_PATH=/etc/mooncake.json`
on each pod with `protocol=tcp`, `local_hostname=<pod_public_ip>`,
`MC_TCP_ENABLE_CONNECTION_POOL=1` (mandatory per Stage 0a, 4× collapse
otherwise), `MC_LEGACY_RPC_PORT_BINDING=1` (deterministic ports for the
firewall whitelist).

## Open items

- **Verify `--disaggregation-transfer-backend mooncake` is the exact flag
  name in `v0.5.9-cu129-amd64`.** The in-tree tests use it for the EPD
  case (`--encoder-transfer-backend mooncake`) but not explicitly for the
  PD-only test. First step on `phase3-smoke` apply: shell into the pulled
  image and `python -m sglang.launch_server --help | grep -i disag` to
  confirm. If the flag differs, the manifest is one-line patch.
- **Verify Mooncake bootstrap port discovery across clusters.** Stage A
  used port `8998` which worked on the pod network. For cross-DC, the
  prefiller's bootstrap port must be reachable from the decoder's public
  IP through the firewall whitelist (see `XDC_RUNBOOK.md` and
  `X_CLUSTER_PREFLIGHT.md`).

These are tracked in [`XDC_RUNBOOK.md`](../../30-operations/XDC_RUNBOOK.md) §pre-flight.
