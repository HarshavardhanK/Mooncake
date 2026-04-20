# Stage B — design doc

Companion to [README.md](./README.md). README is the operator runbook;
this doc is the *why*.

---

## 1. What Stage B proves

Stage B is a **clean-wire upper bound** for the PrfaaS-style cross-DC
disaggregation pattern. It tests the layer-cake decomposition:

```
  total cost of cross-DC PD = (vLLM disagg overhead)        ← Stage B
                              + (cross-host KV transport)   ← Stage B (Config P only)
                              + (RTT inflation)             ← Stage C
                              + (public-internet noise)     ← Stage D
```

Stage B isolates the *first two* layers on a wire that's effectively
free (bootnet at 100 Gbps LACP, ~0.084 ms RTT). If we can't make the
PrfaaS pattern competitive *here*, we have no business expecting it to
work over the WAN.

The three configurations are designed so that pairwise differences map
to specific causes:

| Comparison         | What the gap measures                                    |
|--------------------|----------------------------------------------------------|
| H ↔ N              | Per-node hardware variance (g304 vs g307); should be ≈0  |
| H ↔ P (same node ↔ cross node) | KV transport across Cilium pod overlay on bootnet  |
| N ↔ P              | Cross-node disagg vs single-node disagg w/ same TP shape |

Stage B's headline numbers feed into Stages C and D as the *control* —
Stage C adds `tc netem` profiles to the bootnet path and re-runs Config
P; Stage D replaces the bootnet hop with the real public internet path
to Y.

---

## 2. Why Configs H, N, and P (and not the original H/N/P from EXPERIMENT_PLAN.md)

EXPERIMENT_PLAN.md §5 originally defined Config N as "Y splits its 8
GPUs into 2P+6D, still on Y", i.e. asymmetric prefill/decode. That
makes sense **on Y** (one node, the only way to get any disagg signal
is to split GPUs unevenly).

On X we have two identical 8-GPU nodes. The question we want to answer
is *"does putting prefill on a different node hurt or help?"* — for
which the right control is the **same TP=4+TP=4 split, played on one
node**, not a 2P+6D oddity. So Stage B redefines the configs as:

- **H (homogeneous decode-only)** — TP=4 prefiller + TP=4 decoder on
  g304. All KV traffic is loopback through the kernel via Cilium pod
  overlay. This is "Y alone with no help" played on g304.
- **N (sanity baseline / naive het)** — same shape, on g307. Confirms
  we're not measuring a per-node anomaly.
- **P (PrfaaS-style)** — TP=4 prefiller on g304, TP=4 decoder on g307.
  KV crosses bootnet via Cilium-routed ClusterIP. This is the PrfaaS
  pattern played locally, with the network behaving as well as it ever
  will.

This deliberately deviates from the EXPERIMENT_PLAN.md §5 N. The
deviation is recorded here so the eventual SUMMARY.md can call it out
when it compares Stage B to Stage D's Y-side baseline.

---

## 3. How Λ_max(SLO) is computed from the bench CSV

The bench Job writes one CSV per config per workload at:

```
/scratch/prfaas-results/stageB/config{H|N|P}/<workload>/sweep.csv
```

Schema (one row per concurrency cell):

```
workload,model,input_len,output_len,concurrency,num_prompts,wall_clock_iso,
ttft_p50_ms,ttft_p95_ms,ttft_p99_ms,tpot_p50_ms,e2el_p50_ms,
output_throughput_tok_s,n_ok,n_err,wall_s,slo_ms,slo_met
```

`slo_met = 1` iff `ttft_p95_ms ≤ slo_ms` for that cell, where `slo_ms`
comes from the per-workload constants in `00-namespace.yaml`'s
ConfigMap (1000 / 2000 / 1500 / 1500 ms for chat / long_context /
rag_summary / code_complete).

`extract_lambda_max.py` (host-side, unchanged from the script we
already have) walks the CSVs and computes:

```
Λ_max(config, workload) := highest concurrency c
                          such that slo_met(c) == 1,
                          converted to QPS via c / E2EL_P50.
```

The "/ E2EL_P50" conversion approximates `concurrency /
mean_request_latency`. It's not exactly QPS-from-Poisson-arrival, but
it's the same conversion used in the host-script Stage B and in the M1
results, so cross-stage comparisons stay apples-to-apples.

The headline ratios reported in `SUMMARY.md`:

```
Λ_max(P) / Λ_max(H)   per workload
Λ_max(N) / Λ_max(H)   per workload   (sanity check, should be ≈1.0)
```

Stage B is **green** when, on `long_context`:
- `Λ_max(P) / Λ_max(H) ≥ 0.90`
- `Λ_max(P) / Λ_max(N) > 1.00`
- `|Λ_max(N) / Λ_max(H) − 1.0| ≤ 0.05`

---

## 4. What we expect on bootnet

From Stage 0a (host-side cross-DC bench, captured in
`prfaas/m1.5-vllm-baseline/results/stage0a/SUMMARY.md`):

- **Bootnet RTT (g304 ↔ g307):** 0.084 ms (sub-millisecond LAN).
- **Bootnet underlay capacity:** 100 Gbps LACP (2× 50 Gbps bonded).
- **Cilium pod overlay efficiency on this hardware:** unmeasured, but
  with VXLAN encap and no NIC offload assumptions we conservatively
  expect 30–60 Gbps single-flow goodput (not the 100 Gbps line rate).
  Multi-flow with `MC_TCP_ENABLE_CONNECTION_POOL=1` should saturate
  closer to 80 Gbps.

For Nemotron-Nano-9B-v2 on `long_context` (16k input, 256 output) at
TP=4 per replica, KV cache per request is ~0.5–1 GB (hybrid attention
keeps this small). At target Λ_max around 30–60 QPS per replica, KV
traffic peaks around 5–15 Gbps per direction — comfortably inside what
Cilium-on-bootnet can do. So **bootnet is not the bottleneck for Stage
B**, and we expect Λ_max(P) ≈ Λ_max(H) within a few percent.

If we measure Λ_max(P) / Λ_max(H) < 0.85 on `long_context`, the gap is
not the wire — it's something inside Mooncake or Cilium that we need to
chase before Stage C/D.

---

## 5. Risk register

| #   | Risk                                                                 | Probability | Impact | Mitigation |
|-----|----------------------------------------------------------------------|-------------|--------|------------|
| R1  | hostPath race during model staging (two pods read while download is mid-write) | Low (Jobs gate via `wait --for=condition=complete`) | High (truncated weights → vLLM init crash) | README §"What to do if..." |
| R2  | `type: Directory` hostPath fails-fast if staging Job hasn't run on that node | High (intentional) | Low (clear error message in events) | This is *desired* behavior — better than silent empty-dir mount |
| R3  | Cilium pod overlay caps bootnet throughput well below underlay      | Medium       | Medium  | We measured raw bootnet at 100 Gbps; if Stage B Λ_max(P) is suspiciously low, run an in-cluster `iperf3` Job between two pods on g304/g307 to baseline the overlay |
| R4  | GPU device-plugin assigns *contiguous* GPUs (e.g. both pods on g304 get GPUs 0–3 each) and the second pod fails to schedule | Low (device-plugin tracks per-device allocation) | High (deployment stuck Pending) | If observed, set explicit `CUDA_VISIBLE_DEVICES` via env override + a separate ResourceClaim — but this is a known-working pattern from Stage A |
| R5  | Cilium NetworkPolicy default-deny in `kube-system` blocks cross-pod traffic | Low (DISCOVERY.md shows no CNPs)  | High (everything hangs) | README §NOTES has the allow-list CNP ready to apply if needed |
| R6  | vLLM v1 MooncakeConnector defaults to a transport other than TCP    | Low (Stage A shows TCP works without explicit config) | Medium  | We set `MC_TRANSPORT_PROTOCOL=tcp` in the ConfigMap. If the connector ignores it, vLLM logs at `VLLM_LOGGING_LEVEL=INFO` will name the transport on init |
| R7  | Bench Job exhausts the proxy's HTTPx connection pool at high concurrency | Medium       | Low (manifests as inflated TTFT, not crash) | Bench Python uses one `AsyncClient` with default pool; if concurrency 192 saturates pool, raise `--limits` in `httpx.AsyncClient(limits=...)` and re-run |
| R8  | Mooncake bootstrap (8998) port collision when running multiple configs simultaneously | Low (we run sequentially per README) | Low (containerPort is namespaced per pod) | N/A — different pods, different IPs |
| R9  | Image pull (`vllm/vllm-openai:v0.19.1`, ~10 GB) re-runs on each fresh pod, slowing iteration | Medium       | Low (just slow, not broken) | First pull caches on the node; subsequent pulls are instant. We set `imagePullPolicy: IfNotPresent` |
| R10 | hostPath results dir on g304 fills up across configs (~few GB per config of JSONs) | Low (DISCOVERY.md: 14 TB free on /scratch) | Low | Operator can `rm -rf /scratch/prfaas-results/stageB` between runs if reproducing |
| R11 | The bench's `make_random_prompt` hits a degenerate token distribution (e.g. lots of repetition) and the model's prefill cache short-circuits → Λ_max looks artificially high | Low | Medium | Random word-level gibberish should not hit prefix-cache hits. Sanity check via `output_throughput_tok_s` consistency across cells |
| R12 | g304 or g307 GPU is in use by another workload (Slurm-on-K8s testbed per DISCOVERY.md) | Medium       | High (pod stuck Pending on `nvidia.com/gpu`) | Pre-flight: `kubectl describe node g304 g307 \| grep -A2 "Allocated resources"` before bring-up |

---

## 6. Open questions for the operator (before bring-up)

1. **Bench output PVC vs hostPath.** Default chosen here is hostPath at
   `/scratch/prfaas-results/stageB`. Pros: zero infrastructure, survives
   Job deletion, `scp`-able. Cons: tied to a single node (g304 by
   default). Alternative: stand up a `csi-nfs` PVC if there's a NFS
   server on the X-side network. **Operator: confirm hostPath is
   acceptable, or point at a writable NFS export.**

2. **Single bench node for Λ_max(P).** The bench Job is pinned to g304
   so its results land predictably. For Config P, the bench client lives
   on the same node as the prefiller (and proxy lives on g307 with the
   decoder). The bench → proxy hop crosses bootnet. This adds one
   network hop to TTFT. Acceptable for our SLOs but worth flagging —
   alternative is to pin bench to g307 to put bench → proxy on
   loopback. **Operator: pick g304 (current) or g307 (lower TTFT noise
   for Config P at the cost of mixing bench output into the decoder
   node's `/scratch`).**

3. **Concurrency grid.** Default `1 4 16 32 64 128 192` matches
   EXPERIMENT_PLAN.md §6.1. For Nemotron-Nano-9B-v2 we may saturate well
   below 192 — operator can shrink the grid via the `BENCH_CONCURRENCIES`
   ConfigMap key to save bench time.

4. **Workload subset.** Default runs all four (chat / long_context /
   rag_summary / code_complete). The Stage B success criteria only
   reference `long_context`. Operator can drop the other three via
   `BENCH_WORKLOADS` to cut bench time ~4×.

5. **Cilium NetworkPolicy posture.** We assume default-allow.
   `kubectl get cnp -A` to verify, and apply the README §NOTES CNP only
   if a default-deny exists.

---

## 7. What's next after Stage B

- **Stage B+ (deferred):** flip Mooncake to RDMA over the IB fabric.
  Same configs, same model, just `MC_TRANSPORT_PROTOCOL=rdma` plus
  device exposure (`rdma/hca_shared_devices_a` resource claim, already
  available per DISCOVERY.md). Tells us how much Stage B cost us by
  *not* using RDMA.
- **Stage C:** Config P only, with `tc netem` profiles on the bootnet
  interface. Isolates pure RTT effect.
- **Stage D:** Config P with prefiller on g304 (X cluster, iad1) and
  decoder on g126 (Y cluster, dfw1-beta). Real public internet between
  them. The headline number for the paper.
