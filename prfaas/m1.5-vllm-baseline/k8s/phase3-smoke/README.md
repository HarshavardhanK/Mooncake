# Phase 3 — single-host PD-disaggregation smoke (g126 only)

This stack proves the SGLang + Mooncake-TCP PD-disaggregation path works
end-to-end **before** we spend any cross-DC time. Both the prefiller and
the decoder run on `g126`; Mooncake KV transfer rides the cluster pod
network over TCP. The router sits in front of both engines and orchestrates
the full PD protocol.

If this run cannot complete a single request through the router, the
cross-DC variant (`../phase3-xdc/`) will not work either. **Do not skip
this step.**

> Engine choice rationale: see
> [`prfaas/docs/40-milestones/m1.5-vllm-baseline/ENGINE_DECISION.md`](../../../docs/40-milestones/m1.5-vllm-baseline/ENGINE_DECISION.md).
> Phase 2 model pick (Kimi-Linear-48B-A3B-Instruct): see
> [`prfaas/results/m1.5-vllm-baseline/phase2_analytical/PHASE2_PICK.md`](../../../results/m1.5-vllm-baseline/phase2_analytical/PHASE2_PICK.md).

## Pre-flight

1. **Phase 1 PVC must exist with the model staged.** This stack mounts
   `model-weights-phase1` read-only and expects
   `/models/moonshotai_Kimi-Linear-48B-A3B-Instruct/config.json` to be
   present. Verify with:

   ```bash
   kubectl --context aln1-beta-harsha-g126-beta -n default \
     get pvc model-weights-phase1
   kubectl --context aln1-beta-harsha-g126-beta -n default \
     get jobs -l prfaas.experiment/phase=1
   ```

   If the model is not staged, apply Phase 1 first:

   ```bash
   kubectl --context aln1-beta-harsha-g126-beta -n default \
     apply -f ../phase1/01-model-pvc.yaml
   kubectl --context aln1-beta-harsha-g126-beta -n default \
     apply -f ../phase1/02-model-staging-job-kimi.yaml
   kubectl --context aln1-beta-harsha-g126-beta -n default \
     wait --for=condition=complete --timeout=30m \
       job/model-staging-kimi-linear-48b
   ```

2. **GPUs available.** The smoke needs `8 × H100 80GB SXM5` on `g126`
   (`4` for the prefiller pod, `4` for the decoder pod). Check
   `nvidia.com/gpu` allocatable:

   ```bash
   kubectl --context aln1-beta-harsha-g126-beta get node g126 \
     -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
   ```

   Phase 1 jobs hold GPUs while running — make sure no `phi-kv-profiler-*`
   Job is still active before applying.

3. **Image pull cache (optional).** The SGLang image is large
   (`lmsysorg/sglang:v0.5.9-cu129-amd64`, ~9 GiB). Phase 1 already pulled
   it on `g126`, so this should be a no-op. Confirm with:

   ```bash
   kubectl --context aln1-beta-harsha-g126-beta debug node/g126 \
     -it --image=alpine -- chroot /host crictl images | grep sglang
   ```

## Apply order

```bash
KCTX=aln1-beta-harsha-g126-beta
NS=default

kubectl --context "${KCTX}" -n "${NS}" apply -f 00-namespace.yaml
kubectl --context "${KCTX}" -n "${NS}" apply -f 10-prefiller.yaml
kubectl --context "${KCTX}" -n "${NS}" apply -f 11-decoder.yaml
kubectl --context "${KCTX}" -n "${NS}" apply -f 20-services.yaml
kubectl --context "${KCTX}" -n "${NS}" apply -f 12-router.yaml

kubectl --context "${KCTX}" -n "${NS}" rollout status \
  deploy/prefiller-phase3-smoke --timeout=15m
kubectl --context "${KCTX}" -n "${NS}" rollout status \
  deploy/decoder-phase3-smoke --timeout=15m
kubectl --context "${KCTX}" -n "${NS}" rollout status \
  deploy/router-phase3-smoke --timeout=5m

kubectl --context "${KCTX}" -n "${NS}" apply -f 90-smoke-job.yaml
kubectl --context "${KCTX}" -n "${NS}" wait --for=condition=complete \
  job/phase3-smoke-probe --timeout=10m
kubectl --context "${KCTX}" -n "${NS}" logs job/phase3-smoke-probe
```

The probe Job exits with `[probe] PASS` on success.

## Expected behaviour

| Pod | Time to ready | What to look for in logs |
|---|---|---|
| prefiller | 5-12 min (CUDA graph capture is slow on Kimi-Linear) | `Application startup complete`, then `disaggregation` mentions |
| decoder | 5-12 min | same as prefiller, plus a successful TCP probe to the prefiller bootstrap port |
| router | < 1 min after engines are healthy | `pd-disaggregation` mode active, both upstreams reachable |
| smoke-probe | < 30 s after router is ready | one POST to `/v1/chat/completions`, returns content |

A typical first-request latency is dominated by warm-up (CUDA graphs,
fla-core JIT). Steady-state TTFT for `l = 8K-16K` should land in the
sub-second range on a single H100 PD pair (Phase 2 prediction:
`TTFT_floor_P ≈ 0.16 s` at `l = 16K`, see
[`PHASE2_PICK.md`](../../../results/m1.5-vllm-baseline/phase2_analytical/PHASE2_PICK.md)).

## Cleanup

```bash
kubectl --context "${KCTX}" -n "${NS}" delete deploy,svc,job,cm \
  -l prfaas.experiment/phase=3-smoke
```

The Phase 1 PVC (`model-weights-phase1`) is intentionally not touched.

## Failure mode → action

| Symptom | Likely cause | Fix |
|---|---|---|
| Prefiller `Address already in use` on 30001 | `SGLANG_PORT` env leaked through | Confirm we use `PRFAAS_SGLANG_API_PORT`, never `SGLANG_PORT` |
| Decoder `connection refused` to bootstrap | Prefiller not ready yet | The decoder script polls 60×5s; if still failing, see decoder logs for the actual host:port it tried |
| Router `pd-disaggregation` flag unrecognized | SGLang v0.5.9 router CLI drift | `kubectl exec` into the router pod, run `python3 -m sglang_router.launch_router --help`, patch the flag |
| `--disaggregation-transfer-backend` rejected | SGLang flag name drift in v0.5.9 | Same procedure — `python3 -m sglang.launch_server --help \| grep -i disag` |
| `fla_core` import error in Kimi-Linear init | initContainer `pip install` failed | Check pod events, network egress; the `pip install` runs at container start, not init container, so look at the engine pod logs |
| Smoke probe 500 with `KV transfer timeout` | Mooncake transfer engine not reaching prefiller | `kubectl exec` into decoder pod, `getent hosts prefiller.default.svc` then `curl bootstrap`; check `MC_TCP_ENABLE_CONNECTION_POOL=1` is set on both sides |

For deeper debugging — including cross-DC-specific failure modes — see
the cross-DC runbook's "Failure mode → action" table:
[`prfaas/docs/30-operations/XDC_RUNBOOK.md`](../../../docs/30-operations/XDC_RUNBOOK.md#failure-mode--action-cross-dc-specific).
