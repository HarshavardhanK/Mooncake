# Phase 1 — run-by-run notes

This is the operator's logbook for the Phase 1 Φkv replication runs on
g126. It complements [`PHI_KV_TABLE.md`](./PHI_KV_TABLE.md) (the
headline data), [`COMPARE_TO_PAPER.md`](./COMPARE_TO_PAPER.md)
(acceptance-criteria status), and the per-model JSONL files in this
directory. If you want the *what we measured*, read `PHI_KV_TABLE.md`.
If you want *what actually happened in the room*, read this.

Companion docs:
- [`../../PROJECT_LOG.md`](../../../docs/00-overview/PROJECT_LOG.md) §6 — same data,
  positioned in the larger project narrative.
- [`../../INFRA_LOG.md`](../../../docs/30-operations/INFRA_LOG.md) — every infra event
  (disk pressure, port collisions, RBAC) referenced below.
- [`../../DECISIONS.md`](../../../docs/20-decisions/DECISIONS.md) — ADRs for every
  decision below (mid-run parser fix, env-var rename, Qwen weight
  eviction, etc.).

---

## Timeline (UTC, 2026-04-20)

| Time | Event |
|---|---|
| 21:30 | Final Phase 1 ConfigMap + 400 GiB PVC applied. Disk on g126 was at ~70% used. |
| 21:32 | Stage Kimi-Linear-48B (`02-model-staging-job-kimi.yaml`). Job completes ~21:37 (~5 min, hf_transfer enabled). |
| 21:38 | Stage Qwen2.5-72B (`03-model-staging-job-qwen72b.yaml`). Disk crosses ~80% during shard download. |
| 21:48 | Qwen2.5-72B staging completes. Disk at ~85%. Briefly tripped `disk-pressure:NoSchedule` taint; cluster auto-cleared after a wave of cert-manager evictions (we don't have RBAC to clean those). Decided to profile dense first, then evict its weights, before staging Nemotron — see ADR-014. |
| 21:51 | Profiler Job for **Nemotron** (TP=4) actually went first because its weights were already on the PVC from Stage A and we wanted to validate the SGLang+probe pipeline on the smallest model. **First success: 7 cells (1K → 65K) good, 1 cell (131K) errored** — request length equalled `max_position_embeddings` and SGLang returned 400. |
| 21:55 | Patched `phi_kv_probe.py` to add `_model_max_len()` + `safe_max` skip semantics (ADR-010). Pushed the new ConfigMap; new behaviour is a `"skipped": true` JSON record per oversize cell rather than a Job-level fail. |
| 21:58 | Profiler Job for **Qwen2.5-72B** (TP=8). Hit the SGLang port-binding issue (uvicorn `[Errno 98] address already in use`). Iterated three times across ports 30000 → 40000 → 8001 before realising the env-var name itself was the bug (ADR-008). Renamed `SGLANG_PORT` → `PRFAAS_SGLANG_API_PORT`; added `TORCHINDUCTOR_COMPILE_THREADS=1`. |
| 22:24 | Qwen2.5-72B run completes. **5 cells (1K → 16K) good, 3 cells (32K → 131K) skipped** because `safe_max=32639` (= `max_position_embeddings - output_len - 128 = 32768 - 1 - 128`). Documented in ADR-011. |
| 22:25 | One-shot `weights-cleanup-qwen72b` Job removes 135.4 GB. Disk drops to ~60%. `disk-pressure` clears. |
| 22:25 | Profiler Job for **Kimi-Linear-48B** (TP=8). First completion at ~22:48. |
| 22:50 | Sanity-check Kimi numbers vs. paper's Table 6 → ours plateau ≈ 4.5–4.9 Gbps; paper says ~5.5–6 Gbps. Ratio is suspiciously close to 6/7. Investigated `phi_kv_probe.py::_parse_kimi_linear`. Found the parser was reading `cfg.get("layer_types")` and `cfg.get("full_attn_layer_idx")` at the top level of `config.json`, neither of which exist on the released Kimi-Linear-48B. The fallback was `(n+3)//4 = 6` attention layers — but the actual config nests this at `linear_attn_config.full_attn_layers = [4,8,12,16,20,24,27]` (7 layers, 1-indexed). |
| 22:55 | Patched `_parse_kimi_linear` to read `linear_attn_config.full_attn_layers` and to normalize 1-indexed → 0-indexed when `max(idx) == n_layers`. ADR-007. Pushed the new ConfigMap. |
| 23:00 | Re-ran the Kimi profiler. Completes ~23:30. Plateau now ~5.7–5.8 Gbps for `l ∈ [16K, 65K]` — exactly what the per-token-KV math predicts (`7 × 1152 = 8064 bytes/token`, vs. the bugged `6 × 1152 = 6912 bytes/token`). Headline numbers in `PHI_KV_TABLE.md` are post-fix. |
| 23:35 | All three JSONL files copied locally via the results-reader sidecar. SGLang server logs (sibling `*.sglang.log` files) gitignored due to size but staged for diagnosis. |
| 23:50 | Composed `PHI_KV_TABLE.md`, `COMPARE_TO_PAPER.md`, updated `PHASE1_PHIKV_PLAN.md` and `EXPERIMENT_PLAN.md`. Committed as `d475071`. |

Wall-clock summary: **Phase 1 ran in ~2.5 hours** including two
mid-flight bug fixes and one full Qwen-eviction cycle. The "clean"
re-run (everything pinned, every patch already in place) would take
~75 minutes including weight staging.

---

## Per-model run notes

### H1 — Kimi-Linear-48B-A3B-Instruct (TP=8)

**Job:** `phi-kv-profiler-kimi-linear-48b-vj5nh`
**Engine flags:** `--disable-radix-cache --max-running-requests 1
--mem-fraction-static 0.85`
**Sampling:** 5 warmup, 20 timed per cell.
**KV pre-flight (post-fix):** 7 attention layers (MLA),
`kv_per_token_bytes = 7 × 1152 = 8064`, 27 hidden layers total.

What worked:

- Server warmup took ~8 minutes (model load + CUDA-graph capture +
  inductor compile-single-threaded). Subsequent cells reuse the
  compiled graphs.
- Tprefill noise across the 20 timed samples is exemplary: P75 / P25
  ratio is < 1.02 for every cell at `l ≥ 8 K`. Below that the cell-to-
  cell ratio is dominated by per-request overhead rather than prefill
  work, but the *per-cell* noise is still tight.
- MoE warmup variance worry was unfounded: the first 5 warmup
  iterations appear sufficient to load and route through every active
  expert at least once.

What broke and how it was fixed:

- **Parser bug, first run.** First completion came in with Φkv
  plateauing at ~4.5–4.9 Gbps, which is exactly 6/7 of what the
  per-token-KV math predicts when you correctly count Kimi's 7 MLA
  attention layers. Postmortem in §"Postmortem 1" below.
- **`fla-core` install at startup.** Kimi's KDA layers depend on
  `fla-core` kernels, which the SGLang image doesn't ship. The
  profiler Job's container `command:` does
  `pip install --no-cache-dir 'fla-core>=0.4.0'` before launching
  SGLang; adds ~30 s to startup.

### H2 — NVIDIA-Nemotron-Nano-9B-v2 (TP=4)

**Job:** `phi-kv-profiler-nemotron-nano-9b-v2-q2chn`
**Engine flags:** same as Kimi.
**KV pre-flight:** 4 attention layers (GQA-8, head_dim=128) + 52
Mamba2 layers, `kv_per_token_bytes = 4 × 4096 = 16,384` (Mamba2 layers
contribute 0 because the SSM state is fixed-size).

What worked:

- TP=4 fits comfortably on 4× H100 with KV cache cap unhit even at
  `l = 65,536`.
- Smallest model in the set; was the sandbox for validating the
  end-to-end probe pipeline before we touched Kimi or Qwen.

What broke:

- **`l = 131,072` cell errored.** SGLang returned `HTTP 400 Bad
  Request` because the request prompt was *exactly*
  `max_position_embeddings = 131,072` tokens long, with `output_len=1`
  needing one more position than the embedding table provides. This
  surfaced an ergonomic bug in the probe: pre-fix it treated 400 as
  fatal. Postmortem in §"Postmortem 2" below.
- The `l = 131,072` cell shows up in the JSONL as an `"error"` record
  rather than a `"skipped": true` record because that run predates the
  `safe_max` semantics. Re-running this cell at `l = 130,944`
  (= 131072 − 128) would close it.

### D1 — Qwen2.5-72B-Instruct (TP=8)

**Job:** `phi-kv-profiler-qwen2-5-72b-mvjsf`
**Engine flags:** same as Kimi.
**KV pre-flight:** 80 attention layers (GQA-8, head_dim=128),
`kv_per_token_bytes = 80 × 2 × 8 × 128 × 2 = 327,680` (BF16, K + V).

What worked:

- The dense baseline against which the hybrid feasibility ratio is
  computed.
- Plateau is sharp: 56.25 / 56.42 / 53.80 Gbps for `l ∈ {4K, 8K, 16K}`.
  The slight dip at 16 K is real (GQA's `O(l²)` attention starting to
  bite Tprefill more than KV bytes grow per token).

What broke:

- **SGLang port-binding loop.** Three consecutive failed startup
  attempts on ports 30000, 40000, 8001 before we figured out the env-
  var name itself was the bug (`SGLANG_PORT` is reserved by SGLang's
  internal scheduler). Full postmortem in §"Postmortem 3" below.
- **PyTorch inductor compile workers** were also competing for the
  port. Mitigated by setting `TORCHINDUCTOR_COMPILE_THREADS=1`.
- **Cells `l ∈ {32K, 65K, 131K}` skipped** by `safe_max = 32639`
  because `max_position_embeddings = 32,768` and we deliberately do not
  enable YaRN extension (ADR-011). These show up in the JSONL as
  `"skipped": true` records.

After the run, weights were evicted from the PVC by the cleanup Job
(ADR-014); the staging would be rerun if we ever revisit the dense
control.

---

## Postmortems

### Postmortem 1 — Kimi-Linear-48B parser bug

**Symptom.** First Kimi run completed cleanly across all 8 cells but
Φkv plateau came in at ~4.5–4.9 Gbps for `l ∈ [16 K, 65 K]`, materially
below the ~5.5–6 Gbps the paper publishes for the same model on
similar hardware.

**Hypothesis 1 (rejected).** Engine version drift — maybe SGLang
v0.5.9 has a kernel regression vs. paper's snapshot. Inspected the
SGLang CHANGELOG between paper-likely-snapshot and v0.5.9; almost all
diffs are perf-positive or bug-fixes. Engine drift would more likely
push Φkv *up*, not down. Rejected.

**Hypothesis 2 (rejected).** Tprefill clock skew or warmup
contamination. Re-checked the JSONL: P75/P25 < 1.02 across all cells,
five warmup samples discarded, single-stream. Measurement is clean.
Rejected.

**Hypothesis 3 (correct).** `Skv` was wrong. The probe computes Skv
analytically from `config.json`. Dumping
`prfaas/m1.5-vllm-baseline/scripts/phi_kv_probe.py::_parse_kimi_linear`
output for the actual Kimi config showed `n_attn_layers=6,
n_linear_layers=21`. The released Kimi-Linear-48B config has
`linear_attn_config.full_attn_layers = [4,8,12,16,20,24,27]` —
*seven* MLA layers, 1-indexed. The bug was that `_parse_kimi_linear`
was reading `cfg.get("layer_types")` and `cfg.get("full_attn_layer_idx")`
at the top level (neither exists in the released config), then falling
through to a `(n + 3) // 4` heuristic which on `n=27` returns 6.

**Numerical impact.**

| Cell | Buggy Skv | Correct Skv | Buggy Φkv | Correct Φkv |
|---:|---:|---:|---:|---:|
| 1024 | 7,077,888 | 8,257,536 | 0.88 Gbps | 1.03 Gbps |
| 16384 | 113,246,208 | 132,120,576 | 4.98 Gbps | 5.81 Gbps |
| 65536 | 452,984,832 | 528,482,304 | 4.84 Gbps | 5.65 Gbps |
| 131072 | 905,969,664 | 1,056,964,608 | 4.50 Gbps | 5.25 Gbps |

Ratio is uniformly 7/6 = 1.167×. Math checks out.

**Fix.** Read `linear_attn_config.full_attn_layers` (and the also-valid
`cfg.get("full_attn_layer_idx")` and `cfg.get("global_attention_layers")`
for forward-compatibility). Normalize to 0-indexed when
`max(idx) == n_layers`. Build the per-layer attention mask explicitly.

**Decision.** Re-ran the entire Kimi sweep on the patched parser
(ADR-007). The post-fix numbers are the headline; the buggy numbers do
not appear in any committed file (apart from this postmortem).

**Lesson.** The probe should validate the parsed `n_attn_layers`
against an authoritative source on first run. Adding a startup-time
sanity-check that prints `n_attn_layers / n_linear_layers / kv_per_token_bytes`
and bails if any of them is implausible (e.g. `n_attn_layers == 0` for
a model with `attn_implementation != "linear"`) is a follow-up.

### Postmortem 2 — Nemotron `l = 131,072` HTTP 400

**Symptom.** Probe sent a 131,072-token prompt with `output_len=1` to
SGLang. SGLang replied with `HTTP 400 Bad Request`. Pre-fix, the probe
treated 400 as a fatal warmup failure and exited the cell with an
error JSON record (it did not exit the Job — the loop continued — but
it mucked up the headline table generation script which expected
either a successful row or a skip row).

**Diagnosis.** Nemotron-Nano-9B-v2's `max_position_embeddings = 131,072`.
A request of length L tokens with `output_len=K` needs the model to
have positions [0, L+K). When `L = 131072` and `K = 1`, that's positions
[0, 131073) which is exactly one past `max_position_embeddings`. SGLang
detects this at request-validation time and returns 400.

**Fix.** Probe now reads `max_position_embeddings` from the model's
`config.json` (with fallback keys) and computes
`safe_max = declared_max - output_len - 128`. Cells with `l > safe_max`
emit a `"skipped": true` JSON record and do not even contact the
server. Same code path will help any future hybrid we profile.

**Decision.** Skip semantics over fail semantics (ADR-010). Could have
re-attempted at `l = 131,071` instead, but every other cell uses powers
of 2 — keeping the report clean is worth more than recovering one cell.

### Postmortem 3 — SGLang port-binding race

**Symptom.** SGLang server pod log:

```
INFO:     Started parent process [1]
INFO:     Will watch for changes in these directories: ['/workspace']
ERROR:    [Errno 98] address already in use
INFO:     Application startup failed. Exiting.
```

Pod restarts in a loop. Tried port 30000, 40000, 8001 — same symptom.
Each rename of `SGLANG_PORT` to the new value did *not* fix it.

**Diagnosis.** `srt/utils/network.py::get_open_port()` reads
`os.getenv("SGLANG_PORT")` and uses that value for the SGLang
scheduler's *internal* IPC port allocation, which happens *before*
uvicorn binds the user-facing API port. So the scheduler grabs the
port we wanted for the API, and uvicorn loses the race.

`torch._inductor.compile_worker` worker processes inherit the same
env and were *also* trying to bind ports during CUDA-graph capture.

**Fix.** Two changes (ADR-008):

1. Rename our env var to `PRFAAS_SGLANG_API_PORT`. SGLang's
   `SGLANG_PORT` lookup now returns nothing; the scheduler picks an
   ephemeral port and the API port is uncontested. Pass the value to
   `--port` on the command line so SGLang knows where uvicorn should
   bind.
2. Set `TORCHINDUCTOR_COMPILE_THREADS=1` so inductor compiles in the
   parent process, not in subprocess workers. Costs ~5 seconds at
   warmup; cheap.

**Detection going forward.** A `ss -tlnp` in the SGLang container
during startup would show *what* is binding the port. Documented in
[`../../INFRA_LOG.md`](../../../docs/30-operations/INFRA_LOG.md) §2 detection paragraph.

---

## What's reliably reproducible from these results

- The full Phase 1 sweep, with `safe_max` skip semantics and the
  patched Kimi parser, on three models: ~75 minutes wall-clock on
  g126, including weight staging from Hugging Face.
- The headline ratio (dense / hybrid Φkv ≈ 9-16×) is stable: it's
  governed by per-token-KV byte counts, which come straight from
  `config.json`. As long as the parser is right, the ratio will land
  in the same band on any contemporary H100 8-GPU node.
- The wire-feasibility verdict (both hybrids fit, dense doesn't fit)
  is robust to ±20% Φkv variation — both hybrids are 2.2-4× under the
  wire, the dense is 4× over the wire.

## What's *not* yet reproducible from these results

- Phase 2's analytical Λ_max number — needs the regenerator code,
  not just the Φkv table.
- An empirical check that any of this matches a real PD-disagg run —
  Phase 3.
- A direct, paper Table-6-cell-by-cell quantitative diff — needs us
  to type up `PAPER_PHI_KV.md` from the PDF first.
