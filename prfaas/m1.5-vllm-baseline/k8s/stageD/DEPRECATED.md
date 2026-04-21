# Stage D is DEPRECATED for the paper-replication critical path

As of 2026-04-20, Stage D (vLLM-based cross-DC scaffold spanning g304→g126)
is **deprecated**. It was the original vLLM cross-DC plan, predating
the pivot to SGLang for the paper-replication arm.

The replacement — for **cross-DC PD-disaggregation** between cluster X
(g304) and cluster Y (g126) — is:

[`prfaas/m1.5-vllm-baseline/k8s/phase3-xdc/`](../phase3-xdc/)

That stack uses SGLang v0.5.9 with native Mooncake PD-disaggregation,
the same engine Phase 1 used for Φkv profiling and Phase 2 used to pick
the model (Kimi-Linear-48B). Engine identity is preserved between the
analytical and empirical arms.

The reasoning is documented in detail in
[`prfaas/docs/40-milestones/m1.5-vllm-baseline/ENGINE_DECISION.md`](../../../docs/40-milestones/m1.5-vllm-baseline/ENGINE_DECISION.md).

## What's preserved

The files in this directory (`stageD/`) are kept verbatim for the
historical record:

- `stageD/x/10-prefiller.yaml` is the canonical reference for
  hostNetwork-on-X PD prefill on g304. The Phase 3 cross-DC prefiller
  (`phase3-xdc/x/10-prefiller.yaml`) inherits the same hostNetwork +
  toleration + tcp-only design; only the engine binary and flags differ.
- `stageD/firewall/g304-stageD-iptables.sh` is what originally opened
  TCP 8998 from `147.185.40.126/32`. Phase 3 reuses that rule and adds
  TCP 30001 on top, via
  `phase3-xdc/firewall/g304-phase3-iptables.sh` (idempotent — does not
  re-add 8998 if it's already present).
- `stageD/y/00-configmap.yaml` defines the `PREFILLER_HOST` /
  `PREFILLER_BOOTSTRAP_PORT` / `MC_TCP_ENABLE_CONNECTION_POOL` /
  `MC_LEGACY_RPC_PORT_BINDING` env-name vocabulary that Phase 3
  inherits.

## Do not apply these manifests

If you `kubectl apply -f stageD/x/` and `stageD/y/` you'll get a vLLM
cross-DC stack that cannot serve the hybrid models Phase 2 selected.
Use `phase3-xdc/` instead, after running the smoke
(`phase3-smoke/README.md`) and the X-cluster pre-flight
([`X_CLUSTER_PREFLIGHT.md`](../../../docs/30-operations/X_CLUSTER_PREFLIGHT.md)).
