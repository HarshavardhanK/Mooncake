# Principal Engineer Review — PrfaaS-on-Mooncake Replication (2026-04-20)

**Reviewer:** Principal Engineer (adversarial review)
**Commit under review:** `1485f74` on `feat/prfaas-m1.5-vllm-baseline`
**Paper:** Qin et al., *Prefill-as-a-Service: KVCache of Next-Generation Models Could Go Cross-Datacenter*, arXiv:2604.15039v1, Apr 2026.
**Team's stated goal:** Paper-faithful replication on heterogeneous Voltage Park GPU clusters.

---

## 1. Executive Verdict

**NOT APPROVED — REWORK REQUIRED** on two axes before Phase 3 manifests should be applied.

The team has done excellent infrastructure work (Stage 0a wire characterization, Phase 1 Φkv probe, operational documentation). However, the analytical model in Phase 2 contains **three compounding errors that inflate the predicted speedup from ~1.5× (paper's regime) to 8–16×**, and Phase 3 as designed **implements naive heterogeneous PD, not PrfaaS**. If applied as-is, the team will measure a number that cannot be compared to the paper's headline claim, defeating the stated purpose.

| Severity | Count | Summary |
|---|---:|---|
| **BLOCKER** | 3 | Config H baseline is a strawman (2× GPU asymmetry + 8× batch asymmetry); Phase 2 does not implement the paper's joint (t, Np/Nd) optimization; Phase 3 is naive-het-PD, not PrfaaS |
| **HIGH** | 5 | M/M/1 metric ≠ paper's metric; decode_batch_{p,h} assumption undefended; no workload distribution; TPOT defaults unjustified; `--disaggregation-transfer-backend mooncake` unverified |
| **MEDIUM** | 5 | No Config H baseline plan; fla-core runtime pip install; model substitution not honest; no bench script for SGLang; no layer-wise pipelining |
| **LOW** | 3 | Mooncake protocol assertion missing; port 30001 NodePort collision risk; no long-running stability test |
| **ACCEPTED** | 5 | Phase 1 Φkv methodology is sound; wire characterization thorough; SGLang engine choice well-reasoned; firewall approach adequate; deprecation of vLLM scaffolds honest |

**What MUST be fixed before applying Phase 3:** Fix the analytical model (BLOCKERs 1-2), add a local PD-P path to the Phase 3 topology or honestly relabel the experiment as "naive het PD" (BLOCKER 3).

**What MAY ship as-is:** Phase 1 data, Stage 0a data, the K8s plumbing (manifests are well-structured), the firewall scripts.

---

## 2. Findings

### BLOCKER-1: Config H Baseline Is a Strawman — Not the Paper's Homogeneous Baseline

**Severity:** BLOCKER
**Paper reference:** §4.1 Setup, Table 6 (Config comparison)
**Codebase reference:**

```45:51:prfaas/m1.5-vllm-baseline/scripts/phase2/run_phase2.py
    ap.add_argument("--n-p", type=int, default=1)
    ap.add_argument("--n-d", type=int, default=1)
    ap.add_argument("--n-y", type=int, default=1)
    ap.add_argument("--decode-batch-p", type=int, default=32)
    ap.add_argument("--decode-batch-h", type=int, default=4)
```

**What's wrong:**

The team's Config H uses `N_y=1` collocated replica (8 GPUs on g126) with `decode_batch_h=4`. Config P uses `N_p=1` (8 GPUs on g304) + `N_d=1` (8 GPUs on g126) with `decode_batch_p=32`. This means:

1. **Config P uses 2× the GPUs** (16 total) vs Config H (8 total). The paper's comparison holds total GPU count approximately constant: 32 H200 + 64 H20 = 96 GPUs for PrfaaS-PD vs 96 H20 for homogeneous PD.
2. **Config P gets 8× the decode batch capacity** (`decode_batch_p=32` vs `decode_batch_h=4`). This is the single largest lever in the model — it makes Λ_H_capacity = `1 × 4 / (0.182 + 256 × 0.012)` = 1.21 req/s while Λ_P_capacity = min(5.50, 13.91, 10.42) = 5.50 req/s.

The paper's homogeneous PD baseline (Table 6, column 3) is a properly disaggregated PD cluster with Np=9 prefill + Nd=3 decode instances, achieving Λmax = 2.11 req/s. The team's Config H is a single collocated server that must do both prefill and decode serially. These are fundamentally different systems.

**Why it matters:** The team's predicted 7.94× speedup is largely a measurement artifact of comparing 16 GPUs against 8 GPUs with an 8× decode batch penalty. Correcting for equal GPU budget and equal decode batch would collapse the predicted speedup dramatically — likely below 2×, in the range the paper actually claims.

**Concrete fix:**

- Config H must be a disaggregated PD setup on g126 alone (same as `phase3-smoke`: TP=4 prefiller + TP=4 decoder). `decode_batch_h` should equal `decode_batch_p` or at least be the measured value from the smoke.
- Alternatively, keep Config H as-is but rename it "Config C (collocated)" and add a proper Config H that disaggregates on Y alone — so the comparison chain is Collocated < Homo-PD < Het-PD (naive) < PrfaaS, which is the paper's full chain.
- The "PrfaaS speedup" headline number must compare equal-resource configurations, or explicitly state the GPU budget is different and discount accordingly.

---

### BLOCKER-2: Phase 2 Does Not Implement Paper's Joint (t, Np/Nd) Optimization

**Severity:** BLOCKER
**Paper reference:** §3.4.2 Throughput-Optimal Configuration, Eqs 7–8, Figure 5
**Codebase reference:**

```150:188:prfaas/m1.5-vllm-baseline/scripts/phase2/run_phase2.py
def sweep(
    phi_data: dict[str, list[dict]],
    *,
    bw_grid_gbps: list[float],
    # ...
) -> list[CellResult]:
    rows: list[CellResult] = []
    for short, phi_rows in phi_data.items():
        # ...
        workloads = build_workloads(phi_rows, output_len=output_len, tpot_s=tpot)
        for w in workloads:
            for bw in bw_grid_gbps:
                # ... evaluates each (model, l, bw) independently
```

**What's wrong:**

The paper's core optimization (§3.4.2) jointly searches two variables:
- **t** (routing threshold): determines p = P(L > t), llong = E[L|L>t], lshort = E[L|L≤t]
- **Np/Nd** (prefill-to-decode ratio within the PD cluster)

This requires a workload *distribution* (the paper uses truncated log-normal μ=9.90, σ=1.00), not isolated fixed-l evaluations. The team's code evaluates each Phase 1 `(model, l)` cell independently — it never:
1. Computes p, llong, lshort from a distribution + threshold t
2. Searches over t to balance Θ_prfaas/p = Θ_pd-p/(1-p) (Eq 7)
3. Searches Np/Nd to balance total prefill throughput against decode (Eq 8)
4. Accounts for the fact that PD-P handles (1-p) of requests locally

The paper's Figure 5 shows the 2D grid search explicitly: one axis for Np (fixing t at optimum), one for t (fixing Np=3, Nd=5). The team has no equivalent.

**Why it matters:** Without the joint search, the team's "operating point pick" is not the paper's optimal configuration — it's an arbitrary single-l evaluation. The paper's Λmax of 3.24 req/s emerges from the intersection of all three bottleneck curves across the *distribution*, not from any single l. The team cannot compare their single-l number to the paper's distribution-optimal number.

**Concrete fix:**

1. Implement the truncated log-normal distribution from §4.1: `L ~ TruncLogNormal(μ=9.90, σ=1.00, [128, 128K])`.
2. For each candidate threshold t, compute p = P(L > t), llong = E[L|L>t], lshort = E[L|L≤t].
3. Interpolate Φkv(llong) and Φkv(lshort) from Phase 1 data.
4. Compute Θ_prfaas, Θ_pd-p, Θ_pd-d per Eqs 3-5.
5. Grid-search (t, Np/Nd) to maximize Λmax per Eq 6.

---

### BLOCKER-3: Phase 3 Implements Naive Heterogeneous PD, Not PrfaaS

**Severity:** BLOCKER
**Paper reference:** §3.1 Overview, §3.2 Hybrid Prefix Cache Pool, §3.3 PrfaaS-PD Disaggregation, §3.4.3 Dual-Timescale Scheduling, §4.3.3 (naive het PD = only 1.16×)
**Codebase reference:**

```50:75:prfaas/m1.5-vllm-baseline/k8s/phase3-xdc/y/30-router.yaml
              exec python3 -m sglang_router.launch_router \
                --pd-disaggregation \
                --prefill "${PREFILL_URL}" \
                --decode "${DECODE_URL}" \
                --host 0.0.0.0 \
                --port "${ROUTER_PORT}"
```

**What's wrong:**

The paper defines PrfaaS as requiring five system mechanisms (§3.1–§3.4). The team's Phase 3 implements **zero** of them:

| Paper PrfaaS mechanism | Paper section | Team Phase 3 status |
|---|---|---|
| Length-threshold routing (only l > t goes cross-DC) | §3.3, §3.4.3 | **MISSING.** `sglang_router --pd-disaggregation` sends ALL requests to the cross-DC prefiller. No routing threshold t. |
| Local PD-P path (short requests stay on Y) | §3.3, Figure 3 | **MISSING.** No prefill node on Y. All prefill goes to X. |
| Bandwidth-aware scheduling | §3.4.3 short-term | **MISSING.** Router does not monitor egress utilization. |
| Global KVCache manager with prefix matching | §3.2, §3.4.3 | **MISSING.** No Mooncake KV Indexer deployed. No prefix-match routing. |
| Hybrid prefix cache pool | §3.2, Figure 4 | **MISSING.** SGLang v0.5.9 does not implement the paper's transfer-cache / prefix-cache block distinction. |

The paper explicitly compares PrfaaS against "naive heterogeneous PD" in §4.3.3 and shows it achieves only 1.16× (not 1.54×). The team's Phase 3 topology matches the naive configuration exactly: all prefill on remote, all decode on local, no scheduling. If the team applies these manifests and measures Λmax(P)/Λmax(H), they will get a number for *naive het PD*, not *PrfaaS*.

**Why it matters:** The team's stated goal is "paper-faithful replication." Running naive het PD and calling the result "PrfaaS" would be dishonest. The paper's 1.54× headline specifically attributes the 32% improvement over naive het PD (1.54×/1.16× = 33% delta) to the scheduling and cache mechanisms the team has not built.

**Concrete fix:**

Two honest options:
1. **Relabel:** Call Phase 3 what it is — "naive heterogeneous PD baseline." The paper validates this at 1.16× (Table 6, column 4). This is still valuable and publishable. Add Phase 4 as M2+M3+M4 from the team's roadmap (length-threshold router, hybrid prefix pool, bandwidth-aware controller) to replicate actual PrfaaS.
2. **Add a local PD-P path:** Deploy a second SGLang instance on g126 in prefill-only mode (TP=4), alongside the TP=4 decoder. Modify the router to implement length-threshold routing: l > t → g304, l ≤ t → local prefiller. This would be a minimal PrfaaS implementation.

---

### HIGH-1: M/M/1 P95 Wait Approximation Is a Silent Metric Substitution

**Severity:** HIGH
**Paper reference:** §3.4.1 Throughput Model, Eq 6
**Codebase reference:**

```173:201:prfaas/m1.5-vllm-baseline/scripts/phase2/lambda_max_model.py
_LN20 = math.log(20.0)  # ln(1/0.05) ≈ 2.996

def w_p95_s(lambda_offered: float, lambda_capacity: float) -> float:
    """Eq 5 (W_p95 only).
    Closed-form for an M/M/1 queue's P95 waiting time...
    """
    # ...
```

**What's wrong:**

The paper's Λmax (Eq 6) is the steady-state throughput ceiling: `Λmax = min(Θ_prfaas/p, Θ_pd-p/(1-p), Θ_pd-d)`. There is no queueing model in the paper's analytical framework. The team added an M/M/1 P95 wait-time approximation and uses `Λmax(SLO)` — the largest λ where M/M/1 P95 wait + floor ≤ SLO — which is a strictly lower (stricter) number than the paper's Λmax.

The team's `MODEL_AND_EQUATIONS.md` acknowledges this: "M/M/1 is conservative — the paper's M/D/1 model gives roughly half the wait." But the paper uses **neither** M/M/1 nor M/D/1. The paper's Λmax is pure capacity without queueing.

**Why it matters:** The M/M/1 constraint suppresses both Λmax(P) and Λmax(H), but it suppresses Λmax(H) *more* because Config H has lower raw capacity → higher utilization ρ → faster queue blowup. This asymmetric suppression inflates the speedup ratio beyond what the paper's metric would show. The team's numbers are not comparable to the paper's Table 6.

**Concrete fix:** Implement the paper's raw Eq 6 as the primary metric. Keep the M/M/1 Λmax(SLO) as a supplementary metric and report both, clearly labeled.

---

### HIGH-2: decode_batch_p=32 vs decode_batch_h=4 Is Undefended and Dominant

**Severity:** HIGH
**Paper reference:** §3.4.1 Eq 5 (Θ_pd-d)
**Codebase reference:**

```91:93:prfaas/m1.5-vllm-baseline/scripts/phase2/lambda_max_model.py
    decode_batch_p: int     # achievable concurrent decode batch in P
    decode_batch_h: int     # achievable concurrent decode batch in H
```

**What's wrong:**

The 8× ratio `decode_batch_p / decode_batch_h = 32 / 4` is the single largest lever in the predicted speedup. The rationale in `MODEL_AND_EQUATIONS.md` is "pessimistic — collocated prefill bursts block decode-batch progress." This is a qualitative argument, not a measurement.

For Kimi-Linear-48B at l=16K:
- `Λ_H = 1 × 4 / (0.182 + 3.072) = 1.23 req/s`
- If `decode_batch_h = 32`: `Λ_H = 1 × 32 / 3.254 = 9.83 req/s`

With `decode_batch_h = 32`, the speedup collapses from 7.94× to approximately 0.4× — Config P *loses* because the wire overhead doesn't buy enough to offset the decode batch penalty. The entire Phase 2 conclusion depends on this one unverified number.

**Why it matters:** If Phase 3 empirically shows Config H achieving decode batch sizes > 8, the entire analytical prediction is invalidated.

**Concrete fix:** Measure `decode_batch_h` during the `phase3-smoke` run by monitoring SGLang's `running_req` metric under load. Use the measured value in Phase 2.

---

### HIGH-3: No Workload Distribution — Phase 2 Evaluates Isolated Fixed-l Points

**Severity:** HIGH
**Paper reference:** §4.1 Setup — "truncated log-normal distribution (μ=9.90, σ=1.00, truncated to [128, 128K]) with mean ≈27K tokens, output_len=1024"
**Codebase reference:**

```128:148:prfaas/m1.5-vllm-baseline/scripts/phase2/run_phase2.py
def build_workloads(
    phi_rows: list[dict],
    *,
    output_len: int,
    tpot_s: float,
) -> list[Workload]:
    """One Workload per Phase 1 (model, l) row."""
    out: list[Workload] = []
    for r in phi_rows:
        out.append(Workload(
            input_len=r["input_len"],
            # ...
        ))
    return out
```

**What's wrong:**

Phase 2 evaluates each Phase 1 `(model, l)` cell as if ALL requests have that exact length. The paper's workload uses a *distribution* of lengths, with mean ~27K. The routing threshold t partitions this distribution into long (PrfaaS) and short (local PD) subsets. The team never computes this partition.

Additionally, the team uses `output_len=256` while the paper uses `output_len=1024`. This 4× difference in output length directly impacts decode throughput (Θ_pd-d) and therefore Λmax.

**Why it matters:** The per-fixed-l evaluation produces a speedup curve (the context-length sweep in PHASE2_PICK.md) that looks impressive at short l (16× at l=8K) but this is a regime the paper explicitly says is *below the routing threshold* — short requests stay local in PrfaaS. The team's "peak speedup at l=8K" is a number the paper says should never occur because those requests wouldn't be routed to PrfaaS.

**Concrete fix:**
1. Set `output_len=1024` to match the paper.
2. Implement the distribution-based evaluation as described in BLOCKER-2.

---

### HIGH-4: TPOT Defaults Are Guesswork from Uncited Sources

**Severity:** HIGH
**Paper reference:** §4.1 — "profiled separately for prefill and decode using in-house vLLM"
**Codebase reference:**

```73:84:prfaas/m1.5-vllm-baseline/scripts/phase2/run_phase2.py
TPOT_S_DEFAULT: dict[str, float] = {
    "kimi-linear-48b": 0.012,
    "nemotron-nano-9b-v2": 0.008,
    "qwen2.5-72b-instruct": 0.035,
}
```

**What's wrong:**

The paper profiles TPOT empirically per model (§4.1: "The model is deployed at 8 GPUs per instance and profiled separately for prefill and decode using in-house vLLM. Table 5 lists..."). The team uses TPOT defaults from "SGLang public benches" and "NVIDIA blog" — sources that are not cited with URLs or versions, making the numbers unreproducible.

For Kimi-Linear-48B specifically: TPOT = 0.012 s/tok = 83 tok/s at batch=1. But Kimi-Linear is MoE with 256 experts, 3B active — its decode should be extremely fast. If the actual TPOT is 0.006 (not unreasonable for 3B active params), `Λ_H` doubles and the speedup halves.

**Why it matters:** `MODEL_AND_EQUATIONS.md` §4 says "These are the most leverage-heavy assumption in the model — moving TPOT shifts Λ_max(H) and Λ_max(P) almost linearly." The team agrees this is critical but hasn't measured it.

**Concrete fix:** Measure TPOT during the `phase3-smoke` run with a decode-only benchmark at batch=1. Use `--max-running-requests 1 --input-len 1 --output-len 256` and measure per-token decode latency.

---

### HIGH-5: `--disaggregation-transfer-backend mooncake` Flag Not Pre-Verified

**Severity:** HIGH
**Paper reference:** N/A (implementation detail)
**Codebase reference:**

```124:129:prfaas/docs/40-milestones/m1.5-vllm-baseline/ENGINE_DECISION.md
- **Verify `--disaggregation-transfer-backend mooncake` is the exact flag
  name in `v0.5.9-cu129-amd64`.** The in-tree tests use it for the EPD
  case (`--encoder-transfer-backend mooncake`) but not explicitly for the
  PD-only test.
```

**What's wrong:**

The team has committed Phase 3 manifests that depend on `--disaggregation-transfer-backend mooncake` being a valid SGLang v0.5.9 flag, but the ENGINE_DECISION.md explicitly states this has NOT been verified. The in-tree tests use `--encoder-transfer-backend` (EPD, not PD). These are different code paths.

**Why it matters:** If the flag doesn't exist or has a different name, the pod will crash after 10+ minutes of image pull + model load + CUDA graph compile. Cost: 1-2 hours per failed attempt. This is a 30-second verification that was explicitly deferred.

**Concrete fix:**

```bash
docker run --rm lmsysorg/sglang:v0.5.9-cu129-amd64 \
  python3 -m sglang.launch_server --help 2>&1 | grep -i disagg
```

Run this once before committing manifests. If the flag differs, patch the manifests — it's a one-line change.

---

### MEDIUM-1: No Empirical Λmax(H) Baseline Plan — Smoke ≠ Baseline

**Severity:** MEDIUM
**Paper reference:** Table 6, all three columns
**Codebase reference:** `prfaas/m1.5-vllm-baseline/k8s/phase3-smoke/` and XDC_RUNBOOK.md §5

**What's wrong:**

The XDC_RUNBOOK.md says "The Λ_max(H) baseline runs against the smoke topology (phase3-smoke/) on g126 alone — apply it after tearing down the cross-DC stack to free the GPUs." But `phase3-smoke` is a prefiller (TP=4) + decoder (TP=4) + router on g126 — that's a disaggregated PD setup, not the paper's "homogeneous PD" (which has its own P/D ratio optimization). And it's certainly not a collocated server (Config H per the team's own definition).

The team needs to decide: is Config H "collocated" (single SGLang with no `--disaggregation-mode`) or "homo-PD" (disaggregated, same GPUs)? These give different Λmax values.

**Concrete fix:** Author a `phase3-homo/` manifest set: single SGLang instance, TP=8, no disaggregation mode, all 8 GPUs on g126. That's the true Config H. Keep smoke as "Config N (naive same-host disagg)" for comparison.

---

### MEDIUM-2: `fla-core` Runtime Pip Install — Fragile Dependency

**Severity:** MEDIUM
**Codebase reference:**

```122:123:prfaas/m1.5-vllm-baseline/k8s/phase3-xdc/x/10-prefiller.yaml
              echo "[prefiller-xdc] installing fla-core (Kimi-Linear KDA kernels)"
              pip install --no-cache-dir --quiet "fla-core>=${FLA_CORE_VERSION}"
```

**What's wrong:**

Every pod restart does `pip install fla-core>=0.4.0` from PyPI. If PyPI is unreachable from inside the cluster (network policy, DNS, egress filtering), the pod fails to start. The `--no-cache-dir` flag means it downloads every time, even if the wheel is in pip's cache. No fallback exists.

**Concrete fix:** Pre-bake `fla-core` into a custom SGLang image, or mount a pre-downloaded wheel via a hostPath volume.

---

### MEDIUM-3: Model Substitution Not Honestly Labeled

**Severity:** MEDIUM
**Paper reference:** Table 1, Table 3
**Codebase reference:** `prfaas/results/m1.5-vllm-baseline/phase1_phi_kv/COMPARE_TO_PAPER.md`

**What's wrong:**

The paper measures Φkv for six models (Table 1): Kimi-Linear, MiMo-V2-Flash, Qwen3.5-397B, Ring-2.5-1T (hybrids); MiniMax-M2.5, Qwen3-235B (dense). The team measured three: Kimi-Linear-48B (in paper), Nemotron-Nano-9B-v2 (**NOT in paper**), Qwen2.5-72B (**NOT in paper**).

COMPARE_TO_PAPER.md acknowledges this as "needs paper number" but doesn't call out that two of the three models are substitutions for models the paper doesn't test. Nemotron-Nano-9B-v2 is a Mamba2 hybrid — architecturally distinct from the paper's SWA/KDA/linear-attention hybrids. Qwen2.5-72B is a 72B dense model substituted for 229-235B dense models.

**Why it matters:** The team claims "replicates the paper's central qualitative claim" but only one of three models is actually in the paper. The qualitative claim holds (hybrid Φkv < dense Φkv), but calling it "paper-faithful replication" with 2/3 substitute models overstates what was achieved.

**Concrete fix:** Add a clear "Model Substitution Table" in COMPARE_TO_PAPER.md and README.md that maps each team model to the paper model it substitutes, with explicit notes on architectural differences.

---

### MEDIUM-4: No Bench Script Committed for SGLang Phase 3

**Severity:** MEDIUM
**Codebase reference:** XDC_RUNBOOK.md §5 references `run_concurrency_sweep.sh`

**What's wrong:**

XDC_RUNBOOK.md §5 says to use `prfaas/m1.5-vllm-baseline/scripts/run_concurrency_sweep.sh` but notes "adapt to target the Phase 3 router endpoint." This script was written for vLLM's `benchmark_serving.py` and may not work with SGLang's endpoint without modification. No adapted version is committed.

**Concrete fix:** Commit an SGLang-specific `run_phase3_sweep.sh` that targets the router endpoint and produces the same CSV schema as the Phase 2 predictions for direct comparison.

---

### MEDIUM-5: No Layer-Wise Prefill Pipelining — TTFT Will Be Worse Than Predicted

**Severity:** MEDIUM
**Paper reference:** §3.3 — "layer-wise prefill pipelining to overlap KVCache generation with transmission"

**What's wrong:**

The paper requires pipelining: KV blocks from early layers are transmitted while later layers are still prefilling. SGLang's Mooncake integration may or may not implement this. If it doesn't, the measured TTFT_floor_P will be T_prefill + T_wire (fully serial), not the overlapped value the paper assumes.

The team's analytical model already assumes serial (TTFT_floor_P = T_prefill + T_wire + RTT), which is the conservative case. But if the paper's analytical model assumes pipelining and the team's doesn't, the comparison is apples-to-oranges in the other direction.

**Concrete fix:** Document whether SGLang v0.5.9's Mooncake PD path does layer-wise pipelining. Carry as a known gap if it doesn't.

---

### LOW-1: No MOONCAKE_PROTOCOL=tcp Hard Assertion

**Severity:** LOW
**Codebase reference:** X-side ConfigMap sets `MOONCAKE_PROTOCOL: "tcp"` but no code verifies the engine honored it.

**What's wrong:**

If g304 has RDMA HCAs visible (it does — `rdma/hca_shared_devices_a` is exposed), Mooncake could silently select RDMA. The ConfigMap env var may not be read by SGLang's Mooncake adapter — it could be a Mooncake transfer engine env var only.

**Concrete fix:** Add a startup check in the pod script: `echo "$MOONCAKE_PROTOCOL" | grep -q tcp || { echo "FATAL: protocol not tcp"; exit 13; }` and verify in SGLang logs that TCP was selected.

---

### LOW-2: Port 30001 NodePort Collision Risk on X

**Severity:** LOW
**Codebase reference:**

```51:52:prfaas/m1.5-vllm-baseline/k8s/phase3-xdc/x/00-configmap.yaml
  PRFAAS_SGLANG_API_PORT: "30001"
```

**What's wrong:**

Port 30001 falls within Kubernetes' default NodePort range (30000-32767). With `hostNetwork: true`, the pod binds directly on g304's interface. If any NodePort Service in the X cluster allocates port 30001, there will be a bind conflict.

**Concrete fix:** Use a port outside the NodePort range (e.g., 28001) or verify no NodePort Service on X uses 30001: `kubectl --context <X> get svc -A -o json | jq '.items[].spec.ports[]?.nodePort' | grep 30001`.

---

### LOW-3: No Long-Running Stability Test for Wire

**Severity:** LOW
**Paper reference:** Implied by §3.4.3 bandwidth-aware scheduling (designed for fluctuating bandwidth)

**What's wrong:**

Stage 0a measured wire goodput at one time window. The ±15% diurnal variance is noted but no 24-hour stability run was performed. If wire bandwidth drops to 10 Gbps during a Phase 3 Λmax sweep, the results are contaminated.

**Concrete fix:** Run a background `iperf3` or Mooncake bench during the Phase 3 sweep to confirm the wire holds at ≥12 Gbps throughout.

---

### ACCEPTED — Phase 1 Φkv Methodology

The `phi_kv_probe.py` implementation is sound. Skv is computed analytically per layer type with correct handling of MLA (compressed K + RoPE shard), KDA (0 bytes/token), and GQA (standard 2×n_kv×head_dim×bpe). The Kimi-Linear config.json parser correctly identifies the 21 KDA + 7 MLA pattern from `linear_attn_config.full_attn_layers`. Probe methodology (5 warmup, 20 timed, single concurrency, --disable-radix-cache, output_len=1) matches the paper's profiling setup (§4.1).

**One caveat worth noting (A.1 from the checklist):** For Nemotron-Nano-9B-v2, the probe correctly assigns 0 bytes/token to Mamba2 layers — the Mamba2 recurrent state is fixed-size, not per-token. However, the Mamba2 state (~54 MB per request) must still be transferred cross-DC for decode. The probe ignores this, which means Φkv is slightly under-counted for Nemotron (by ~0.3 Gbps at l=32K). This doesn't change the feasibility verdict.

### ACCEPTED — Wire Characterization (Stage 0a)

14.7 Gbps median, 29.75 ms RTT, MC_TCP_ENABLE_CONNECTION_POOL mandatory — all well-documented and well-measured.

### ACCEPTED — SGLang Engine Choice

The ENGINE_DECISION.md is honest and well-reasoned. SGLang v0.5.9 is the paper's engine, serves hybrids natively, and ships Mooncake PD-disagg. The vLLM deprecation is justified by the structural hybrid-model failure.

### ACCEPTED — Firewall Approach

`g304-phase3-iptables.sh` is idempotent, scoped to source IP, well-commented. `iptables -I INPUT 1` inserts at the top of the chain, which is correct — it ensures the ACCEPT rule is evaluated before any later DROP.

### ACCEPTED — Deprecation of vLLM Scaffolds

Both `DEPRECATED.md` files are honest about what they are and what replaced them. The reasoning chain (vLLM hybrid failure → SGLang → deprecate vLLM scaffolds) is sound.

---

## 3. Paper Fidelity Matrix

| Paper claim / equation / setup | Section | Status | Notes |
|---|---|---|---|
| **Eq 1: Φkv = Skv/Tprefill** | §2.1 | ✅ Implemented | `phi_kv_probe.py` — correct per layer type |
| **Table 3: Φkv per model per l** | §2.1 | ⚠️ Partially implemented | Only 1 of 6 paper models (Kimi-Linear); 2 substitutes |
| **Eq 2: Bout ≈ (N/P)·Φkv(Lavg)** | §2.3 | ❌ Missing | Phase 2 doesn't compute Lavg from a distribution |
| **Eq 3: Θ_prfaas = min(compute, wire)** | §3.4.1 | ⚠️ Partially | Computed per fixed l, not per llong from distribution |
| **Eq 4: Θ_pd-p** | §3.4.1 | ❌ Missing | No PD-P path in Phase 3; no lshort computation |
| **Eq 5: Θ_pd-d** | §3.4.1 | ⚠️ Silently substituted | Team's `decode_batch_h=4` is not paper-justified |
| **Eq 6: Λmax = min(Θ_prfaas/p, Θ_pd-p/(1-p), Θ_pd-d)** | §3.4.1 | ❌ Silently substituted | Team uses M/M/1 P95 SLO constraint, not raw min |
| **Eq 7: balanced PrfaaS vs PD-P** | §3.4.2 | ❌ Missing | No joint t search |
| **Eq 8: balanced prefill vs decode** | §3.4.2 | ❌ Missing | No Np/Nd search |
| **Figure 5: 2D grid search** | §4.2 | ❌ Missing | Team does per-l sweep, not (t, Np/Nd) grid |
| **Table 6: three-config comparison** | §4.3 | ❌ Not yet run | Manifests authored but not applied |
| **Workload: truncated log-normal** | §4.1 | ❌ Missing | Fixed-l only; output_len=256 vs paper's 1024 |
| **Hardware: H200+H20 heterogeneous** | §4.1 | ⚠️ Substituted | H100+H100 homogeneous hardware; acknowledged |
| **Network: 100 Gbps VPC** | §4.1 | ⚠️ Substituted | 14.7 Gbps public Internet; acknowledged |
| **Length-threshold routing** | §3.3, §3.4.3 | ❌ Missing | sglang_router does round-robin, not threshold |
| **Bandwidth-aware scheduling** | §3.4.3 | ❌ Missing | No egress monitoring |
| **Hybrid prefix cache pool** | §3.2 | ❌ Missing | No transfer-cache / prefix-cache distinction |
| **Global KVCache manager** | §3.2 | ❌ Missing | No KV Indexer deployed |
| **Selective offloading** | §3.3 | ❌ Missing | ALL requests go cross-DC |
| **Layer-wise prefill pipelining** | §3.3 | ❓ Unknown | Not verified in SGLang v0.5.9 |
| **Naive het PD baseline** | §4.3.3 | ✅ Accidentally implemented | Phase 3 IS naive het PD (1.16× in paper) |
| **Homo PD baseline** | §4.3.2 | ❌ Missing | No proper homo-PD baseline authored |

---

## 4. Phase 3 Go/No-Go Decision

**Recommendation: FIX THEN APPLY — with scope correction.**

The K8s manifests are well-engineered infrastructure. The operational plumbing (firewall, model staging, cross-cluster ConfigMaps, decoder pre-flight TCP probe) is production-quality. What's wrong is the *experiment design*, not the *deployment engineering*.

**Apply Phase 3 cross-DC manifests IF:**
1. The team relabels the experiment as "naive heterogeneous PD baseline" — which is what it is, and which the paper validates at 1.16× (Table 6, column 4). This is still valuable data.
2. The team also deploys a proper Config H (collocated, non-disaggregated) on g126 and measures Λmax(H) with the same workload.
3. The team acknowledges that the Phase 2 predicted speedup (7.94×–16×) is not the number Phase 3 will produce, and that's expected.

**Do NOT apply if:**
1. The team intends to report the Phase 3 number as "PrfaaS speedup" comparable to the paper's 1.54×. That claim requires the scheduling and caching mechanisms the team has not built.

---

## 5. Suggested Workplan — Next 2-3 Commits

### Commit 1: "Fix Phase 2 analytical model — correct Config H, add paper's raw Λmax, document metric gap"

- Change `decode_batch_h` default to match `decode_batch_p` (or a measured value).
- Add a `--raw-lambda-max` mode that computes the paper's Eq 6 (no M/M/1) alongside the SLO-constrained metric.
- Add a "Methodology Gap" section to `MODEL_AND_EQUATIONS.md` that enumerates: (a) M/M/1 substitution, (b) no distribution/threshold search, (c) Config H GPU asymmetry.
- Re-run `run_phase2.py` and commit updated `PHASE2_PICK.md` and `lambda_max_predictions.csv`.

### Commit 2: "Relabel Phase 3 as naive-het-PD baseline; add collocated Config H manifest"

- Add `prfaas/m1.5-vllm-baseline/k8s/phase3-homo/` with a single SGLang TP=8 collocated server on g126.
- Update `XDC_RUNBOOK.md` to run both Phase 3 (naive het PD) and Phase 3-homo (collocated baseline) and compute the ratio.
- Add a "Paper Fidelity Statement" to `README.md` that says: "Phase 3 measures naive heterogeneous PD (paper §4.3.3, Table 6 column 4, predicted 1.16× in the paper's configuration). PrfaaS-specific mechanisms (length-threshold routing, bandwidth-aware scheduling, hybrid prefix cache) are deferred to M2/M3/M4."

### Commit 3: "Verify SGLang PD-disagg flags and pre-bake fla-core"

- Run the `docker run --rm ... --help | grep disagg` command and capture the output.
- If the flag exists: no manifest change needed.
- If not: patch the manifests with the correct flag.
- Bake `fla-core>=0.4.0` into a custom SGLang image or add a hostPath wheel cache.
- Add the MOONCAKE_PROTOCOL=tcp assertion to the pod startup script.

---

*Review conducted 2026-04-20. Reviewer holds the line: the team's infrastructure work is excellent, but the analytical model and experiment labeling must be corrected before the numbers are publishable. The single most important thing the team must address: **the Config H baseline must compare equal resources, not half the hardware with 8× decode batch penalty.***
