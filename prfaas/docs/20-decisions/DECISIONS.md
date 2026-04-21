# Architecture decision register — PrfaaS-on-Mooncake

This file is the canonical record of every meaningful decision made on
this work, in ADR (Architecture Decision Record) form. Each entry has a
**status**, **context**, the **decision**, the **consequences**, and the
**alternatives we considered and rejected** with the reason.

ADRs are append-only. If a decision is overturned, the old ADR stays and
a new one references it via "Supersedes ADR-XXX".

Index:

- [ADR-001](#adr-001-deploy-on-kubernetes-only-no-host-installs) — Deploy on Kubernetes only, no host installs
- [ADR-002](#adr-002-headline-metric-is-%CE%BB_maxslo-not-per-request-ttft) — Headline metric is Λ_max(SLO), not per-request TTFT
- [ADR-003](#adr-003-pivot-from-vllm-to-sglang-for-the-paper-replication-arm-path-b) — Pivot from vLLM to SGLang for the paper-replication arm (Path B)
- [ADR-004](#adr-004-primary-hybrid-is-kimi-linear-48b-a3b-instruct-paper-actual) — Primary hybrid is Kimi-Linear-48B-A3B-Instruct (paper-actual)
- [ADR-005](#adr-005-dense-control-is-qwen2572b-instruct-not-qwen3-235b) — Dense control is Qwen2.5-72B-Instruct, not Qwen3-235B
- [ADR-006](#adr-006-supportshma-shim-as-a-single-purpose-upstream-pr) — SupportsHMA shim as a single-purpose upstream PR
- [ADR-007](#adr-007-fix-the-kimi-linear-config-parser-and-re-run-not-extrapolate) — Fix the Kimi-Linear config parser and re-run, not extrapolate
- [ADR-008](#adr-008-rename-sglang_port-to-prfaas_sglang_api_port-to-avoid-internal-collision) — Rename `SGLANG_PORT` to `PRFAAS_SGLANG_API_PORT` to avoid internal collision
- [ADR-009](#adr-009-tprefill-protocol-1-warmup-set--20-timed-singlestream-output_len1) — Tprefill protocol: 5 warmup, 20 timed, single-stream, `output_len=1`
- [ADR-010](#adr-010-skip-cells-above-max_position_embeddings-instead-of-failing-the-job) — Skip cells above `max_position_embeddings` instead of failing the Job
- [ADR-011](#adr-011-do-not-yarn-extend-qwen2572b-for-the-headline-table) — Do not YaRN-extend Qwen2.5-72B for the headline table
- [ADR-012](#adr-012-disable-radix-cache-for-%CF%86kv-measurement) — Disable radix cache for Φkv measurement
- [ADR-013](#adr-013-firewall-whitelist-not-wireguard-for-the-benchmark-path) — Firewall whitelist, not WireGuard, for the benchmark path
- [ADR-014](#adr-014-evict-qwen2572b-weights-from-the-pvc-once-its-cells-are-collected) — Evict Qwen2.5-72B weights from the PVC once its cells are collected
- [ADR-015](#adr-015-sglang-image-is-v059-cu129-amd64-not-cu130-or-newer) — SGLang image is `v0.5.9-cu129-amd64`, not `cu130` or newer
- [ADR-016](#adr-016-stage-a-stays-in-the-tree-as-engineering-smoke-not-a-paper-data-point) — Stage A stays in the tree as engineering smoke, not a paper data point

---

## ADR-001 — Deploy on Kubernetes only, no host installs

**Status:** accepted, 2026-04-19.

**Context.** The original Stage A runbook installed vLLM, Mooncake, and
the proxy directly on the bare-metal hosts via `pip` and `systemd`-style
scripts. The user explicitly required: "Are we installing things in the
kubernetes way or directly on the host? I don't want anything directly
on the host. Follow the k8s path." Both clusters expose Kubernetes APIs;
the X cluster exposes admin-class kubeconfig, and the Y cluster exposes
a customer-class kubeconfig restricted to the `default` namespace.

**Decision.** All serving stages (A, B, C, D, Phase 1, Phase 3) run as
Kubernetes Deployments / Jobs against the user-supplied kubeconfigs,
with model weights staged on PVCs and the connector configured via
ConfigMaps. The host-script tree under `m1.5-vllm-baseline/scripts/`
stays as reference and as the substrate for the wire-bench Stage 0a
(which runs `transfer_engine_bench` directly on the host); it is not
the active deployment surface for any serving stage.

**Consequences.**

- Reproducibility is high: every cell is `kubectl apply -f`.
- Disk pressure on g126 is now a recurring failure mode because the
  `local-path` provisioner shares the kubelet imagefs (see
  [`INFRA_LOG.md`](../30-operations/INFRA_LOG.md) §1).
- `default`-namespace-only RBAC on Y constrains us — we can't taint
  nodes, can't use namespaces for isolation, can't mass-delete cluster
  pods. Manageable but documented.
- Init containers do the `pip install fla-core` for Kimi runs and the
  in-place `SupportsHMA` patch for vLLM Stage A — keeps base images
  upstream-clean.

**Alternatives rejected.**

- *Direct host install with systemd.* Faster bring-up, but explicitly
  ruled out by the user; less reproducible across rebuilds.
- *Container-on-host (Docker, no K8s).* Sacrifices PVC-managed weight
  staging and the K8s liveness/readiness machinery. Same reasons as
  above.

---

## ADR-002 — Headline metric is Λ_max(SLO), not per-request TTFT

**Status:** accepted, 2026-04-19. Supersedes the implicit v0.1/v0.2
framing.

**Context.** Plan v0.1/v0.2 framed the experiment around per-request
TTFT and TPOT on dense models. Re-reading the paper end-to-end made
clear that the paper's contribution is system-throughput at SLO, not
single-request latency. A bandwidth-starved cross-DC link will *always*
make a single request slower; that's not a refutation of the paper. The
paper's claim is that the *decode DC sustains more concurrent users* at
the same TTFT P95.

**Decision.** Λ_max(SLO) — the maximum offered QPS at which TTFT P95 ≤
SLO — is the headline metric for every comparison from Stage B onward.
TTFT, TPOT, ITL, E2EL are reported alongside but are not the go/no-go
signal. SLO is 2 s by default, tuned per workload. Phase 1's Φkv is the
analytical input that *predicts* Λ_max via the paper's Eq 3-8.

**Consequences.**

- `benchmark_serving.py` runs in concurrency-sweep mode; we extract
  Λ_max from the output via a small script.
- Three-config head-to-head (H = homogeneous decode-only, N = naive het,
  P = PrfaaS-style) is the comparison structure. Headline number is
  `Λ_max(P) / Λ_max(H)`.
- Direct comparability with the literature improves (the paper publishes
  Λ_max ratios, not TTFT comparisons).

**Alternatives rejected.**

- *TTFT P95 as the headline.* Would systematically penalize any cross-
  DC arrangement at the request level, which is not what the paper
  claims. Kept as a side metric.
- *Throughput in tokens/s as the headline.* Conflates prefill and
  decode work; doesn't isolate the SLO question.

---

## ADR-003 — Pivot from vLLM to SGLang for the paper-replication arm (Path B)

**Status:** accepted, 2026-04-19. Supersedes the v0.3 plan's "vLLM
everywhere".

**Context.** Stage A established that vLLM v0.19.1's MooncakeConnector
cannot serve any hybrid Mamba2+attn model on the released code path —
`TpKVTopology.get_kv_cache_shape` raises `NotImplementedError` on the
Mamba2 backend. Three theoretical paths exist to unblock hybrids
(captured in [`PAPER_MODEL_PLAN.md`](../10-paper/PAPER_MODEL_PLAN.md)):

- **Path A — wait for upstream vLLM.** Unbounded ETA; each minute we
  wait is a minute we're not generating data on the only model class
  the paper makes its claim on.
- **Path B — switch engines to SGLang.** SGLang `v0.5.9` ships
  first-class Mooncake PD-disagg binding (transfer engine 0.3.9, GPU
  staging buffer for heterogeneous TP, intra-node NVLink KV transfer);
  serves Kimi-Linear / Mamba2 / KDA / MLA out of the box. Crucially,
  the paper's authors used SGLang for their own profiling.
- **Path C — write a hybrid-aware MooncakeConnector ourselves.** 2–4
  weeks of focused engineering on `TpKVTopology` and the connector's
  registration logic. Highest paper fidelity for vLLM users; high
  fixed-cost; we'd carry it.

**Decision.** Path B. SGLang `v0.5.9-cu129-amd64` is the engine for
Phase 1 and Phase 3. The paper used SGLang, so adopting SGLang is a
paper-fidelity *gain*, not a workaround.

**Consequences.**

- vLLM Stage A stays in the tree as engineering smoke (proves the K8s
  + Mooncake plumbing) but is explicitly not a paper data point.
- The SupportsHMA upstream PR (#1931) is decoupled from the critical
  path of this work; it remains useful for vLLM users but is no longer
  blocking.
- Path C drops from "blocking" to "nice-to-have", conditional on Phase
  3's outcome.
- We need to learn SGLang's CLI, port format, and PD-disagg config —
  modest cost.

**Alternatives rejected.** Path A (unbounded ETA), Path C (high fixed
cost; only justifies after we know whether the empirical claim holds).

---

## ADR-004 — Primary hybrid is Kimi-Linear-48B-A3B-Instruct (paper-actual)

**Status:** accepted, 2026-04-19. Supersedes ADR-implicit-in-v0.3 ("use
Qwen3-Next-80B-A3B as primary").

**Context.** v0.3 used Qwen3-Next-80B-A3B-Instruct as the primary
hybrid. It's hybrid, MoE, and similarly sized — but it isn't in the
paper's evaluation set. The paper evaluates Kimi-Linear-48B as its
primary hybrid (MLA + KDA, 3:1 hybrid ratio, 48 B / 3 B active). With
Path B (SGLang) selected and Kimi-Linear shipping on SGLang since
v0.5.x, we can run the paper's actual primary hybrid directly.

**Decision.** Primary hybrid is **`moonshotai/Kimi-Linear-48B-A3B-Instruct`**.
Kept as secondary hybrid: `nvidia/NVIDIA-Nemotron-Nano-9B-v2`
(adjacent, much smaller, single-host; useful as a diversity check on
the per-token-KV math because Mamba2 has different layer-kind
allocation than Kimi's KDA + MLA).

**Consequences.**

- TP=8 on g126 (fits comfortably at BF16 — 48 B with 3 B active).
- Requires `fla-core` installed at container start (Kimi's KDA layer
  needs it; SGLang image doesn't bundle).
- Phase 1's Φkv numbers are directly comparable to paper Table 6 cells
  for Kimi-Linear-48B.
- Phase 3 will most likely target Kimi-Linear-48B at `l ∈ [16 K, 65 K]`
  given the wire headroom.

**Alternatives rejected.**

- *Qwen3-Next-80B-A3B-Instruct.* Paper-adjacent, not paper-actual. v0.4
  paper-fidelity goal supersedes.
- *MiMo-V2-Flash 309B.* Paper's "claimed sweet spot", but we can't
  serve it without X-cluster K8s GPU exposure, which is currently
  blocked. Tracked as a Phase-3-stretch.

---

## ADR-005 — Dense control is Qwen2.5-72B-Instruct, not Qwen3-235B

**Status:** accepted, 2026-04-19.

**Context.** The paper's dense controls are MiniMax-M2.5 (229 B, 10 B
active, dense-softmax MoE) and Qwen3-235B (235 B, 22 B active, dense-
softmax MoE). Neither fits on g126 (8× H100 80 GB) at BF16 without
quantization, and serving them at FP8 across g304+g307 is blocked on
X-cluster K8s GPU exposure.

**Decision.** Dense control is **`Qwen/Qwen2.5-72B-Instruct`** —
72 B dense, GQA-8, 80 layers, BF16, fits TP=8 on g126. Defer Qwen3-235B
or MiniMax-M2.5 until X-cluster GPU exposure unblocks.

**Consequences.**

- Per-token KV is 327,680 bytes (vs Kimi's 8,064 — 40×). Big enough to
  produce a clean dense-vs-hybrid ratio cell on the same hardware.
- `max_position_embeddings = 32,768` without YaRN; we can only profile
  up to `l = 16,384` cleanly. The dense Φkv plateau (54-56 Gbps) is
  obvious at that point.
- Direct quantitative comparison to paper Table 6's MiniMax-M2.5 cells
  is not apples-to-apples. We use the ratio (dense Φkv / hybrid Φkv)
  rather than the absolute as the comparable number.

**Alternatives rejected.**

- *Qwen3-235B at FP8 on g304+g307.* Blocked on X-cluster GPU exposure;
  also FP8 vs BF16 muddies the Φkv comparison.
- *MiniMax-M2.5.* Same blocker; also uses a different attention layout
  that complicates per-token-KV math.
- *Llama-3.1-70B as dense control.* Less paper-adjacent than Qwen2.5-72B
  (paper uses Qwen-family models in its hybrid set).

---

## ADR-006 — SupportsHMA shim as a single-purpose upstream PR

**Status:** accepted, 2026-04-19.

**Context.** vLLM v0.19.1's HMA path requires the connector class to
declare `SupportsHMA`. Mooncake's `MooncakeConnector` doesn't. The fix
is a one-line class annotation. The user explicitly asked: "I don't
want anything else but only this effort for that PR. Make sure that is
the case."

**Decision.** Carry the `SupportsHMA` annotation as a single, isolated
upstream PR on its own branch (`feat/supports-hma-shim`). Submit as
[Mooncake#1931](https://github.com/kvcache-ai/Mooncake/pull/1931). PR
contains nothing else — no research code, no proxy patches, no
manifests, no docs unrelated to the shim. The principal-engineer-style
review feedback was incorporated; the PR is currently open and awaiting
maintainer.

**Consequences.**

- Reviewable in minutes, not hours.
- Decoupled from the rest of this work — if we drop vLLM entirely
  (Path B), the PR still has independent value for vLLM users.
- Required us to maintain two active branches (this one for research,
  the shim branch for upstream).

**Alternatives rejected.**

- *Bundle SupportsHMA + the Mamba2 unblock in one PR.* The Mamba2
  unblock is structural vLLM work, not a shim; combining them would
  bloat the PR and stall the shim's review.
- *Don't submit upstream; carry as a local patch.* Loses the value of
  upstreaming for other vLLM-on-Mooncake users.

---

## ADR-007 — Fix the Kimi-Linear config parser and re-run, not extrapolate

**Status:** accepted, 2026-04-20.

**Context.** Mid-Phase-1 we noticed Kimi's measured Φkv (4.5–4.9 Gbps
plateau in the first run) was lower than the per-token-KV math
predicted. Investigation found that `phi_kv_probe.py`'s
`_parse_kimi_linear` was reading `cfg.get("layer_types")` and `cfg.get(
"full_attn_layer_idx")` at the top level of `config.json`, neither of
which exists in the released Kimi-Linear-48B config. The fallback was a
hard-coded 3:1 KDA:MLA ratio (`(n + 3) // 4` attention layers), which
on `n_layers=27` gives 6 attention layers — but the actual config sits
at `linear_attn_config.full_attn_layers = [4, 8, 12, 16, 20, 24, 27]`
(7 attention layers, 1-indexed).

So the script was undercounting attention layers by 1 and undercounting
per-token-KV by ~14% (6/7 of the right value). All Skv numbers were
14% low; all Φkv numbers were correspondingly 14% low.

**Decision.** Patch `_parse_kimi_linear` to read
`linear_attn_config.full_attn_layers` (with normalization for
1-indexed → 0-indexed when `max(idx) == n_layers`). Re-run the entire
Kimi sweep on the new parser, do not back-fill or extrapolate. Treat
the first run as a probe-script-bug postmortem.

**Consequences.**

- One re-run cost (~60 minutes wall time on g126 TP=8).
- The headline numbers in the table are the post-fix values.
- Writeup of the first-run anomaly is preserved in
  `prfaas/results/m1.5-vllm-baseline/phase1_phi_kv/RUN_NOTES.md` for transparency.

**Alternatives rejected.**

- *Multiply the first-run Φkv by 7/6 and ship it.* Mathematically
  defensible but weakens the "we ran the actual probe" guarantee.
- *Hardcode 7 attention layers for Kimi-Linear-48B specifically.* Would
  break for other Kimi sizes; reading the config is the right primitive.

---

## ADR-008 — Rename `SGLANG_PORT` to `PRFAAS_SGLANG_API_PORT` to avoid internal collision

**Status:** accepted, 2026-04-20.

**Context.** SGLang's `srt/utils/network.py::get_open_port()` reads
`os.getenv("SGLANG_PORT")` and uses it to allocate the scheduler's
internal IPC port *before* uvicorn binds the user-facing HTTP API port.
If both ports are the same, uvicorn dies with `[Errno 98] address
already in use`. We hit this three times (port 30000, then 40000, then
8001) before figuring it out — each time we changed the port we kept
calling the variable `SGLANG_PORT`, so the collision moved with us.

Additionally, `torch._inductor.compile_worker` subprocesses inherit
environment from the parent and were *also* binding to ports during
CUDA-graph capture, racing with uvicorn.

**Decision.** Rename the env var holding our intended user-facing API
port from `SGLANG_PORT` to **`PRFAAS_SGLANG_API_PORT`**. Set it to
`8001`. Pass its value to `--port` explicitly on the SGLang command
line. SGLang's internal `SGLANG_PORT` lookup now returns nothing, so
the scheduler picks a fresh ephemeral port and the API port is ours.

Additionally set `TORCHINDUCTOR_COMPILE_THREADS=1` so PyTorch inductor
runs single-threaded and doesn't fork compile-worker subprocesses that
race for ports.

**Consequences.**

- One-line env change in every Phase 1 manifest.
- Comment in `00-namespace.yaml` documents *why* the var is renamed, so
  future operators don't innocently rename it back.
- Inductor compile is single-threaded; warmup is a few seconds slower
  per run. Acceptable given how rarely we restart the server.

**Alternatives rejected.**

- *Pin a port that's known not to collide.* SGLang's open-port logic
  scans freely; any port we pick can be claimed by the scheduler if
  the env var is set. The fix is the variable name, not the port value.
- *Patch SGLang to not read `SGLANG_PORT`.* Out-of-tree patch; we don't
  control the engine.

---

## ADR-009 — Tprefill protocol: 5 warmup, 20 timed, single-stream, `output_len=1`

**Status:** accepted, 2026-04-19.

**Context.** Φkv = Skv / Tprefill. The paper's Tprefill is the
*per-request, isolated* prefill time — i.e. the time the engine spends
producing the first token, with no other requests in flight. Output
length is irrelevant to that quantity but the request has to produce
*at least one* token to record a Tprefill-equivalent (`first_token_time
- request_submit_time`).

**Decision.** Per `(model, l)` cell:

- 5 warmup requests, results discarded.
- 20 timed requests. Record P25, P50, P75 of Tprefill in milliseconds.
- `--max-running-requests 1` on the engine. `--disable-radix-cache`
  on the engine.
- `output_len = 1` per request. `temperature = 0`. Identical prompt
  per cell (synthesized to be exactly `l` tokens after tokenization).

**Consequences.**

- Tprefill noise (P75 / P25 ratio) is < 1.02 for `l ≥ 8 K` across all
  cells — adequate for the paper's analytical model.
- Each cell takes ~2× Tprefill(l) × 25 wall-clock seconds. The longest
  Kimi cell (`l=131,072`, Tprefill ≈ 1.6 s) takes ~80 s. The whole
  sweep finishes in ~1 hour per model on g126 TP=8.

**Alternatives rejected.**

- *Concurrency > 1.* Tprefill becomes queue-aware; not what Eq 3
  models. Dropped.
- *Output_len > 1.* Adds decode-step time to the measurement.
- *50 warmup, 50 timed.* Overkill given observed P75/P25 ratio.

---

## ADR-010 — Skip cells above `max_position_embeddings` instead of failing the Job

**Status:** accepted, 2026-04-20.

**Context.** Nemotron-Nano-9B-v2's `max_position_embeddings = 131,072`.
Sending exactly 131,072 input tokens with `output_len=1` blows past the
position embedding (the `+1` past `max_position_embeddings` for the
output token has no position to occupy), and SGLang returns an HTTP 400.
First Nemotron run failed-out at the last cell because the script
treated 400 as a fatal error.

**Decision.** `phi_kv_probe.py` reads the model's
`max_position_embeddings` (or fallback keys), computes
`safe_max = declared_max - args.output_len - 128`, and skips any cell
where `l > safe_max`. Skipped cells emit a JSONL record with
`"skipped": true` and `"error":"skipped_above_model_max: declared_max=…
safe_max=…"`. Only *non-skip* errors mark the Job as failed.

**Consequences.**

- Nemotron's 131 K cell becomes a clean skip (will be filled when a
  smaller `output_len` doesn't help — fundamentally a model-config
  ceiling).
- Qwen2.5-72B's 32 K, 65 K, 131 K cells are clean skips (model is
  capped at 32 K stock).
- Future runs on other models won't fail-out the entire sweep on the
  cap cell.

**Alternatives rejected.**

- *Cap the sweep per-model in the manifest.* More config drift; the
  probe should be self-aware.
- *Set `output_len=0`.* SGLang doesn't accept it; needs at least 1.

---

## ADR-011 — Do not YaRN-extend Qwen2.5-72B for the headline table

**Status:** accepted, 2026-04-20.

**Context.** Qwen2.5-72B-Instruct stops at `max_position_embeddings =
32,768` stock. The official YaRN extension lifts this to 131 K and is
trivially configurable in SGLang. But: enabling YaRN changes the RoPE
scaling, which affects per-layer attention math (the kernels are still
GQA, just with a longer position table). Including a YaRN cell in the
headline dense column would mix two engine paths (stock RoPE vs YaRN-
scaled RoPE) and weaken the dense plateau measurement.

**Decision.** Headline table reports Qwen2.5-72B at `l ∈ [1 K, 16 K]`
only (within stock `max_position_embeddings`). Cells at `l ∈ {32 K,
65 K, 131 K}` are explicit skips with `"skipped": true`. A *separate*
Phase 2.5 cell (optional) will extend the dense control with YaRN to
test whether dense Φkv keeps growing or plateaus past 16 K.

**Consequences.**

- Dense plateau is published over `l ∈ [4 K, 16 K]` only — narrower
  than the hybrids' published range.
- Headline ratio (dense / hybrid at 16 K = 9.3× for Kimi, 8.4× for
  Nemotron) is the conservative dense-vs-hybrid number we cite.
- Phase 2.5 stays optional and clearly out-of-band so we don't re-write
  the headline if we run it.

**Alternatives rejected.**

- *Enable YaRN and ship the long cells in the headline table.* Mixes
  two engine paths in one column.
- *Skip the long cells silently.* Loses the data trail of "we know
  why these cells are missing."

---

## ADR-012 — Disable radix cache for Φkv measurement

**Status:** accepted, 2026-04-19.

**Context.** SGLang's RadixAttention cache (`--disable-radix-cache` is
the off flag) opportunistically reuses prefix KV across requests. If
the warmup and timed requests share any prefix (and they will, because
the probe synthesizes a deterministic prompt), the cached prefix
shortens Tprefill on every request after the first, inflating Φkv into
non-physical territory.

**Decision.** `--disable-radix-cache` is mandatory for every Phase 1
SGLang invocation. Enforced by the manifest (every probe job sets it on
the launch command line) and double-checked by parsing the SGLang
startup log for "Disable radix cache".

**Consequences.**

- Tprefill measurements reflect cold prefill, matching paper Eq 3.
- Φkv is the bytes-per-second the GPU actually produces, not what an
  application would see end-to-end with cache hits.
- Radix cache **stays on** for any later workload-style measurements
  (Stage B/C/D Λ_max sweeps), where it's a fair part of the system.

**Alternatives rejected.**

- *Leave radix cache on; randomize prompts to avoid prefix sharing.*
  Adds entropy to the measurement and still leaks across the warmup
  → timed boundary.

---

## ADR-013 — Firewall whitelist, not WireGuard, for the benchmark path

**Status:** accepted, 2026-04-19.

**Context.** Mooncake's TCP transport has no built-in TLS or auth.
v0.2 of the plan defaulted to a WireGuard tunnel. WireGuard caps user-
space throughput around 2-8 Gbps per tunnel; on a 14.7 Gbps wire that
is the dominant bottleneck and would obscure the actual transport
ceiling.

**Decision.** The benchmark path uses **firewall whitelist + interface
bind**:

- iptables rule on the X-gateway: ACCEPT tcp from Y's public IP on the
  Mooncake port; DROP all others on that port.
- Same on Y for the reverse direction.
- `mooncake.json`'s `local_hostname` is set to the public IP of the
  local node so vLLM/SGLang binds the listener to that interface, not
  `0.0.0.0`.

WireGuard is a separately-tracked Stage 0b ablation so we know the
production cost — but it does not gate the benchmark.

**Consequences.**

- Stage 0a wire numbers are the raw TCP wire, no tunnel overhead.
- Stage D's Λ_max numbers are similarly tunnel-free.
- We document, but don't implement, the WireGuard path for production.

**Alternatives rejected.**

- *Default WireGuard.* Paper assumes raw TCP throughput in its model;
  a tunnel breaks that assumption.
- *TLS via stunnel.* Same throughput problem at this bandwidth.

---

## ADR-014 — Evict Qwen2.5-72B weights from the PVC once its cells are collected

**Status:** accepted, 2026-04-20. Reversed and re-applied once during
Phase 1 because of a re-run.

**Context.** g126's disk is shared between PVCs and the kubelet
imagefs. Hosting Kimi-Linear-48B (~95 GB) + Qwen2.5-72B (~135 GB) +
Nemotron-Nano-9B-v2 (~17 GB) + system + container images saturated
disk and triggered the kubelet's `DiskPressure` taint, evicting many
unrelated cluster pods.

**Decision.** As soon as Qwen2.5-72B's measurable cells (`l ≤ 16 K`)
are collected and their JSONL committed locally, delete the
`/models/Qwen_Qwen2.5-72B-Instruct` directory from the Phase 1 PVC via
a one-shot Job (`weights-cleanup-qwen72b`, runs as
`system-cluster-critical` priority class to bypass the
`DiskPressure:NoSchedule` taint).

**Consequences.**

- ~135 GB freed, disk usage drops from "kubelet-evicting" to ~78%
  used, taint clears within minutes.
- Re-running Qwen2.5-72B requires re-staging (~10 minutes from
  Hugging Face). Acceptable given how rarely we re-run.
- Nemotron and Kimi weights stay on the PVC for repeatability of the
  hybrid cells.

**Alternatives rejected.**

- *Bigger PVC.* PVC is already 400 GiB and nearly the full physical
  disk.
- *Push weights to S3 and re-stage on demand.* Adds external
  dependency; not cheaper at this scale.

---

## ADR-015 — SGLang image is `v0.5.9-cu129-amd64`, not `cu130` or newer

**Status:** accepted, 2026-04-19.

**Context.** g126's NVIDIA driver is `570.211.01`, which supports up
to CUDA 12.9. SGLang publishes both `cu129` and `cu130` builds for
v0.5.9. Loading the `cu130` image on a `cu129`-max driver fails on
container start with an obvious symbol mismatch.

**Decision.** Pin `lmsysorg/sglang:v0.5.9-cu129-amd64` for every
Phase 1 manifest. Document the driver-CUDA correspondence in
[`INFRA_LOG.md`](../30-operations/INFRA_LOG.md) §4 so future image bumps check the
driver first.

**Consequences.**

- Locked to `cu129` until the cluster operator bumps the driver.
- SGLang `v0.5.9` is the first version with stable Mooncake binding +
  Kimi-Linear support, so we're not leaving features on the table.

**Alternatives rejected.**

- *Bump the driver on g126 to support `cu130`.* Cluster-operator action;
  not blocking.

---

## ADR-016 — Stage A stays in the tree as engineering smoke, not a paper data point

**Status:** accepted, 2026-04-19.

**Context.** Stage A used Qwen2.5-7B-Instruct (dense, 7.6 B params) on
vLLM v0.19.1 + MooncakeConnector to prove the K8s + Mooncake plumbing
end-to-end. With ADR-003 (pivot to SGLang) and ADR-004 (paper-actual
Kimi-Linear), Stage A's model is no longer paper-relevant.

**Decision.** Stage A's manifests, results, and `MC_PATCH_NOTE.md` stay
in the tree. Documentation is updated to label Stage A as
"engineering-only proof of plumbing" — not cited from any paper-
replication plot or table. The negative finding on hybrid models
(Mamba2 `NotImplementedError`) is still cited as the trigger for ADR-003
and the SupportsHMA PR.

**Consequences.**

- Anyone bringing up the rig from scratch has a worked example of K8s
  + Mooncake + vLLM end-to-end.
- The negative finding on hybrid models is preserved (motivates the
  pivot) without confusing the reader about what's a paper data point
  and what isn't.
- Stage A doesn't get rolled into Phase 1's headline.

**Alternatives rejected.**

- *Delete Stage A.* Loses the negative finding's evidence trail.
- *Re-run Stage A on SGLang for "consistency".* Wastes time; Stage A's
  job is already done.
