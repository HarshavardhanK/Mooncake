# Stage D — Cross-DC PD-disagg, Kubernetes design

**Status:** design only. NOTHING in this directory has been applied to either
cluster. NO commits, NO image bakes. Operator owns all cluster mutations.

**Goal:** run vLLM v1 PD-disagg with the prefiller in cluster X (g304, iad1)
and the decoder in cluster Y (g126, dfw1-beta), with KV cache crossing the
public Internet on the Mooncake transport. Headline metric is
`Λ_max(P) / Λ_max(H)` per workload per time-of-day window (see
`prfaas/docs/00-overview/EXPERIMENT_PLAN.md` §5 Stage D).

**Inputs that drive every decision below:**
- Wire (Stage 0a): 14.7 Gbps median, 29.75 ms RTT, p50/p95/p99 batch latency
  285/379/781 ms. Mandatory: `MC_TCP_ENABLE_CONNECTION_POOL=1`,
  `MC_LEGACY_RPC_PORT_BINDING=1`. iptables 13000-17000 already open both
  ways.
- Model: `nvidia/NVIDIA-Nemotron-Nano-9B-v2`, 16 KB/token KV, TP=4 per
  replica, 2 prefill replicas planned by sizing math. Stage D starts with
  one prefiller replica on g304 (single-cluster proof first); a second
  replica on g307 is a follow-up if the first cell saturates the wire.
- K8s realities (`k8s/DISCOVERY.md`):
  - X: cluster-admin, NO StorageClasses, RDMA shared device exposed.
  - Y: namespaced (`default` only), local-path SC, single H100×8 node.
- Stage A K8s artifacts in `k8s/stageA/` are the Config H baseline; do not
  modify.

---

## Architecture

```
                                                                                  
  PUBLIC INTERNET (Stage 0a: ~14.7 Gbps median sustained, 29.75 ms RTT)             
  ============================================================================        
  - bootstrap   TCP 8998 (g304 inbound, sourced from 147.185.40.126/32)             
  - transport   TCP 13000-17000 (g304 inbound, already opened in Stage 0a)            
  - return path egress from g126 via Cilium SNAT to 147.185.40.126                   

X CLUSTER (vpcloud-slurm-v2-admin, iad1)        Y CLUSTER (aln1-beta-harsha-g126-beta, dfw1-beta)
context: vpcloud-slurm-v2-admin                  context: aln1-beta-harsha-g126-beta
ns: prfaas-staged                                ns: default

+--------------------------------------+        +-----------------------------------------------+
| Node g304 (public 159.26.81.50)      |        | Node g126 (public 147.185.40.126)             |
|                                      |        |                                               |
|  +-------------------------------+   |        |  +-------------+      +----------------------+ |
|  | Pod: prefiller-staged         |   |        |  | Pod: proxy- |      | Pod: decoder-staged  | |
|  |   hostNetwork: true           |<--+--KV----+--| staged      |      |   normal pod netns   | |
|  |   binds 0.0.0.0:8010 (api)    |   | xfer   |  |   :8001     |      |   :8021 (api)        | |
|  |   binds 0.0.0.0:8998 (boot)   |   | TCP    |  | --prefiller-|      |   TP=4 kv_consumer   | |
|  |   binds dyn 13000-17000 xport |   |        |  |  host=159.. |      |   PVC model-weights  | |
|  |   vLLM kv_producer TP=4       |   |        |  +------+------+      |   (Stage A's, RWO)   | |
|  |   /scratch/models (hostPath,  |   |        |         |             +----------------------+ |
|  |   pre-staged by Stage B)      |   |        |         | ClusterIP        ^                  |
|  +-------------------------------+   |        |         v                  |                  |
|  GPUs 4x H100 (nvidia.com/gpu: 4)    |        |  +--------------+   ClusterIP                  |
|                                      |        |  | Service:     |   decoder-staged-api :8021   |
+--------------------------------------+        |  | proxy-staged |                              |
                                                  |  | :8001        |                              |
                                                  |  +------+-------+                              |
                                                  |         ^                                       |
                                                  |  +------+--------+                              |
                                                  |  | Job: smoke    |                              |
                                                  |  | + Job: bench  |                              |
                                                  |  +---------------+                              |
                                                  +-----------------------------------------------+

  Comparison protocol:
   1) bring up Stage D X-side + Y-side, run Config-P bench against proxy-staged
   2) kubectl delete the X-side prefiller (release wire)
   3) bring up / re-use Stage A's prefiller+decoder+proxy on Y
      (`prfaas.experiment/stage=A` labels), run Config-H bench against Stage
      A's `proxy:8000`
   4) extract Lambda_max per workload, divide P/H per TOD window
```

---

## Problem 1 — Cross-cluster networking

Decoder on Y must reach prefiller on X over the public Internet on TCP 8998
(Mooncake bootstrap) AND TCP 13000-17000 (dynamic transport range).
ClusterIP DNS doesn't cross clusters.

| Option | Pros | Cons |
|---|---|---|
| (a) `hostNetwork: true` on the prefiller pod on X | Simple, deterministic, pod binds to host's public IP (159.26.81.50) directly. Minimal hops. The dynamic 13000-17000 range Just Works. | Pod sees host's whole netns; any port collision with a system service is real. Stage 0a's bench already proved 8998 / 13000-17000 are unused. |
| (b) NodePort Service on X | Keeps pod in normal netns. | Default NodePort range 30000-32767 cannot fit 13000-17000 without a `service-node-port-range` cluster-wide kube-apiserver flag (cluster-admin only, but operator-policy decision). Even with that, NodePort adds a kube-proxy hop on receive. |
| (c) WireGuard tunnel between Cilium overlays | Ephemeral, encrypted | 5-15% / 2-8 Gbps overhead per paper-cited refs. Adds latency variance. EXPERIMENT_PLAN explicitly drops this from the benchmark path (Stage 0b is a one-off measurement of the cost). |

**Recommendation: (a) hostNetwork=true on the prefiller pod on X.**

Rationale:
- Matches exactly what Stage 0a measured. `transfer_engine_lat_bench` ran
  on the host net of g304; `hostNetwork=true` puts the prefiller pod in
  the same netns. Wire numbers carry over without an interpretation gap.
- The decoder pod on Y stays in normal pod netns. It only initiates
  outbound; egress goes through Cilium's default SNAT to 147.185.40.126,
  which X has already whitelisted on 13000-17000 from Stage 0a.
- Bootstrap port (8998) is the *only* extra inbound rule X needs. The
  exact line is in `firewall/g304-stageD-iptables.sh`.
- We intentionally do not put the front-door HTTP (8010) behind a public
  Service. The proxy on Y reaches the prefiller via the Mooncake
  bootstrap port, not via OpenAI HTTP.

Open questions:
- Q1.1 — does any system service on g304 grab :8998 or any port in
  13000-17000 between reboots? Stage 0a empirically didn't see that, but a
  fresh reboot could shift the kernel's local ephemeral range. Pre-flight
  asks operator to `ss -tlnp | grep -E ':8998|:1[3-7][0-9]{3}'` before
  apply.
- Q1.2 — does the X cluster apply any NetworkPolicy by default that would
  block hostNetwork outbound? `kubectl get netpol -A` should be empty.

---

## Problem 2 — Model staging on X

X has no dynamic StorageClass.

| Option | Pros | Cons |
|---|---|---|
| (a) Pre-stage via a one-shot Job on g304 to `/scratch/models/...` (hostPath) | g304 has 14T on /scratch (empty). Idempotent. Same pattern as Stage A's `02-model-staging-job.yaml`. | Per-node only; if we ever add g307 we run a second Job. |
| (b) Bake the model into a custom image | One pull = ready-to-go. | Operator hasn't approved a custom image. Image would be ~30 GB. |
| (c) NFS / VAST CSI | Cleanest cross-node. | csi-vast is present on Y but not X. csi-nfs on X exists; would need an NFS export we control. Operator has not provisioned one. |

**Recommendation: (a). Reuse the Stage B `01-model-staging-job-g304.yaml`**
(owned by the Stage B agent; we depend on it but do not duplicate it here).
Stage D only needs g304 — the prefiller is single-replica for now.

Open questions:
- Q2.1 — has the Stage B agent committed a model-staging Job for g304? If
  not, Stage D is blocked on it. Stage D's prefiller pod will fail at
  startup with `MODEL_LOCAL_DIR not found` (the args block has an explicit
  pre-check that prints this).
- Q2.2 — is `/scratch/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2` the agreed
  on-disk path? Stage D's ConfigMap encodes that path; if Stage B picks a
  different path, Stage D's ConfigMap needs the same change.

---

## Problem 3 — Cross-cluster authentication / no shared service mesh

Each cluster has its own kubeconfig; no shared service discovery, no shared
mesh, no shared secrets. The proxy must know the prefiller's public
IP+ports to construct `kv_transfer_params`.

| Option | Pros | Cons |
|---|---|---|
| (a) Run the proxy on Y, hard-code prefiller's public IP via ConfigMap on Y | Single proxy, simplest. Same code path as Stage A. | Proxy is single-cluster aware; for multi-prefiller (g304+g307) we'd hard-code two IPs. Acceptable for Stage D-1 (single prefiller). |
| (b) Proxy per cluster, coordinate via etcd / Redis / external KV | Scales to N prefillers across N DCs. | Stateful external dependency we don't have. Defer to M3+. |

**Recommendation: (a). Y-side proxy with `--prefiller-host=159.26.81.50`.**

The proxy dials `http://159.26.81.50:8998/query` to discover engine_ids
exactly like Stage A — just with a public IP instead of a ClusterIP DNS
name. `30-proxy.yaml` plumbs the IP via `valueFrom: configMapKeyRef`
against `prfaas-staged-env` so a future change of public IP is a
ConfigMap edit + proxy rollout, not a YAML edit.

Open questions:
- Q3.1 — when we add a second prefiller (likely on g307), does the proxy
  binary support `--prefiller-host a,b` or does it want repeated flags?
  Need to read `mooncake-wheel/mooncake/vllm_v1_proxy_server.py` before
  Stage D-2. (Out of scope for THIS design; flagged for the followup.)

---

## Problem 4 — Decoder placement

Decoder on Y (g126), TP=4, kv_consumer. Same pattern as Stage A's decoder.

**Recommendation: parallel `decoder-staged` Deployment** (separate from
Stage A's `decoder`). Different env, different port (8021 vs 8020), so
both can coexist on g126 during the comparison protocol. Reuses Stage A's
`model-weights` PVC (RWO, multi-mount on same node).

---

## Problem 5 — Mandatory env / connector config

Stage A used the minimal `--kv-transfer-config` form because the path was
loopback. Stage D MUST set:

1. `MC_TCP_ENABLE_CONNECTION_POOL=1` — without it, Stage 0a measured a 4×
   collapse to ~3.6 Gbps. Set on both pods AND in the ConfigMap (belt and
   braces; envFrom can be silently overridden by env, so we set the env
   too).
2. `MC_LEGACY_RPC_PORT_BINDING=1` — keeps the Mooncake RPC port
   deterministic and inside the iptables-allowed 13000-17000 range. Same
   belt-and-braces treatment.
3. `--kv-transfer-config` includes `kv_connector_extra_config.mooncake_protocol: "tcp"`
   explicitly. The X cluster has `rdma/hca_shared_devices_a` exposed
   cluster-wide; if the connector auto-picks `rdma` because it sees an HCA,
   the path would silently differ from Stage 0a's TCP measurements (and
   wouldn't actually leave the cluster). Hard-coding `tcp` removes that
   ambiguity.
4. `VLLM_USE_V1=1`, `VLLM_MOONCAKE_BOOTSTRAP_PORT=8998`, and
   `VLLM_MOONCAKE_ABORT_REQUEST_TIMEOUT=480` carry forward from Stage A.

All four are encoded in `00-namespace.yaml` (X-side) and `00-configmap.yaml`
(Y-side). The Deployment env blocks restate the two MC_* knobs as a guard.

Open questions:
- Q5.1 — once we observe a real cross-DC `transfer_id`, do we see the
  expected ~7.35 Gbps per replica (sizing target) or much less? If much
  less, vLLM is probably collapsing to a single TCP stream regardless of
  `MC_TCP_ENABLE_CONNECTION_POOL`. Plan B: lift the connector knob into the
  `kv_connector_extra_config` block so the connector configures Mooncake
  directly.

---

## Problem 6 — Comparison run "Config H on Y"

Λ_max(P)/Λ_max(H) per workload per TOD window. Config H is "Y alone with no
help" — exactly what Stage A's deployment does (1P+1D collocated on g126).

**Recommendation: reuse Stage A unchanged.** Stage D's bring-up script does
NOT create Config H manifests. Bench loop:

1. Stage A is already deployed (or operator re-applies it with
   `kubectl apply -f k8s/stageA/`).
2. Operator runs the Config H bench against Stage A's `proxy:8000`
   (separate from Stage D's `proxy-staged:8001`).
3. Operator brings up Stage D X-side + Y-side, runs the Config P bench
   against `proxy-staged:8001`.
4. `extract_lambda_max.py` divides per workload per TOD window.

Both stacks coexist on g126 because Stage D uses distinct ports (8021,
8001) and a parallel Deployment / Service (`*-staged`).

Open questions:
- Q6.1 — Stage A's "Config H" is technically a 1P+1D split, not a single
  TP=8 collocated vLLM. The host-side `run_stage_d.sh` Config H starts a
  single TP=8. Is the user OK treating Stage A 1P1D as Config H, or do we
  need a third manifest set for "true Config H = TP=8 collocated"? Treating
  Stage A as Config H is what the prompt says to do. If user wants the
  TP=8 variant later, it is a separate manifest set (out of scope here).

---

## Problem 7 — Time-of-day windows

Stage 0a-bis (pending) will produce TOD-vs-goodput data for the wire. Stage
D should run the comparison at all 3 windows.

**Recommendation:** the bench Job (`y/40-bench-job.yaml`) takes `TIME_TAG`
as an env. Operator runs:
- `TIME_TAG=peak_us` (e.g. 18:00 UTC, US business hours)
- `TIME_TAG=eu_business` (e.g. 10:00 UTC)
- `TIME_TAG=off_peak` (e.g. 04:00 UTC, what Stage 0a window 1 measured)

Output paths under `/scratch/prfaas/results/stageD/<MODEL_TAG>/configP/<TIME_TAG>/`
on g126 separate the runs cleanly. Same per-Time-Of-Day for Config H
against Stage A's proxy.

Open questions:
- Q7.1 — operator scheduling: can we hold the X cluster's 4 GPUs for ~3h
  per TOD window across 24h? We need ~12h of g304 GPU time total for the
  3-window matrix.
- Q7.2 — should we also re-run Stage 0a in each window so we have a
  same-window goodput baseline to correlate Config P TTFT outliers
  against? That's the Stage 0a-bis question; flagged as a dependency.

---

## Problem 8 — Firewall

Both g304 and g126 already have iptables rules for TCP 13000-17000
(Mooncake transport range) sourced from each other's public IPs. Stage D
needs ALSO TCP 8998 (bootstrap) on g304, sourced from g126.

**Recommendation:** present the exact rule line in
`firewall/g304-stageD-iptables.sh`. Operator runs it manually on g304
(`sshv vpsupport@159.26.81.50`). The script:
- is idempotent (`iptables -C` check before `iptables -I`)
- scopes the rule to `147.185.40.126/32` (g126 public IP)
- adds a `-m comment --comment "prfaas stageD: ..."` so the rule is
  attributable in `iptables -S`
- prints what to do for persistence (the host's existing iptables-save
  pattern is unknown; we don't assume).

We do NOT open 8010 publicly — the OpenAI HTTP API on the prefiller is for
the proxy's warmup probe only, and the proxy reaches it via the *same*
public IP using the Mooncake bootstrap path. (If profiling reveals the
proxy needs direct OpenAI HTTP to the prefiller for warmup, we open 8010
in a follow-up.)

Open questions:
- Q8.1 — operator confirms the existing iptables rules on g304 use
  `iptables -I INPUT N -p tcp -s ...` (insert) vs `iptables -A INPUT ...`
  (append) and use the same persistence mechanism. The provided script
  inserts at position 1 (so it precedes any default DROP).
- Q8.2 — does g126 need any new outbound rule to reach g304:8998? Stage
  0a verified outbound 13000 was reachable; 8998 should be the same path
  but we have not directly tested it. If the test smoke fails with
  connect-refused on 8998, the operator may need to extend g126's egress
  iptables (probably not — most policies are stateful and allow RELATED).

---

## File index (Stage D deliverables)

| File | Cluster | Purpose |
|---|---|---|
| `STAGE_D_PLAN.md` | n/a | This design doc |
| `README.md` | n/a | Operator runbook |
| `x/00-namespace.yaml` | X | Namespace `prfaas-staged` + ConfigMap with model paths + cross-DC env |
| `x/10-prefiller.yaml` | X | hostNetwork prefiller on g304, kv_producer, TP=4, mooncake_protocol=tcp |
| `y/00-configmap.yaml` | Y | ConfigMap `prfaas-staged-env` in `default` with `PREFILLER_HOST=159.26.81.50` |
| `y/20-decoder.yaml` | Y | decoder-staged Deployment + ClusterIP, kv_consumer, TP=4, on g126 |
| `y/30-proxy.yaml` | Y | proxy-staged Deployment + ClusterIP, plumbs cross-DC prefiller via configMapKeyRef |
| `y/90-smoke-job.yaml` | Y | End-to-end smoke; success means cross-DC KV path works |
| `y/40-bench-job.yaml` | Y | concurrency × workload sweep, output to /scratch/prfaas/results on g126 |
| `firewall/g304-stageD-iptables.sh` | host | Operator-run iptables extension for g304 (TCP 8998 from g126) |
