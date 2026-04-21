# Stage B is DEPRECATED for the paper-replication critical path

As of 2026-04-20, Stage B (vLLM-based ConfigH/N/P scaffolds for
single-cluster experiments on Y) is **deprecated**. It was authored
before we pivoted to SGLang for the paper-replication arm.

The replacement — for **single-host PD validation** on g126 — is:

[`prfaas/m1.5-vllm-baseline/k8s/phase3-smoke/`](../phase3-smoke/)

That stack uses SGLang v0.5.9 with native Mooncake PD-disaggregation,
which (a) supports the hybrid models Phase 2 selected (Kimi-Linear-48B)
and (b) actually drives the full PD protocol (the bundled
`mooncake.vllm_v1_proxy_server` could not — see
[`prfaas/results/m1.5-vllm-baseline/stageA/SUMMARY.md`](../../../results/m1.5-vllm-baseline/stageA/SUMMARY.md)).

The reasoning is documented in detail in
[`prfaas/docs/40-milestones/m1.5-vllm-baseline/ENGINE_DECISION.md`](../../../docs/40-milestones/m1.5-vllm-baseline/ENGINE_DECISION.md).

## What's preserved

The files in this directory (`stageB/`) are kept verbatim for the
historical record:

- They document the model-staging conventions on g304/g307 that Phase 3
  cross-DC reuses (its own staging Job at
  `phase3-xdc/x/01-model-staging-job-g304.yaml` follows the same pattern,
  but writes a different model and path).
- They show the vLLM `--kv-transfer-config` JSON shape we proved working
  in Stage A on dense Qwen2.5-7B; useful if anyone revisits a vLLM
  hybrid path after `SupportsHMA` lands and the deeper Mamba2 KV-shape
  dispatch is fixed upstream.

## Do not apply these manifests

If you `kubectl apply -f stageB/` you'll get a working vLLM stack on
dense models only, which is **not** what the paper experiment measures.
Use `phase3-smoke/` instead.
