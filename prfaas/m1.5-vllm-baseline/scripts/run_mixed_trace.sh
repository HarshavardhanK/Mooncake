#!/usr/bin/env bash
# Run the paper-style mixed-length trace against an already-running proxy.
#
# Three sub-traces are interleaved so the prefill load is heterogeneous:
#   60% chat_balanced  (in=1024,  out=256)
#   25% rag_summary    (in=8192,  out=512)
#   15% long_context   (in=16384, out=256)
#
# Total prompts = MIX_TOTAL_PROMPTS (default 1000), at concurrency MIX_CONC
# (default 64). Run AFTER you've found Λ_max per-workload — pick MIX_CONC ≈
# 0.7 × min(Λ_max(P)) so you're in a stable, near-saturation regime.
#
# Required env (sourced from ~/.prfaas_env):
#   PRIMARY_MODEL     PRIMARY_MODEL_TAG
#
# Optional:
#   PROXY_HOST        default 127.0.0.1
#   PROXY_PORT        default 8000
#   MIX_CONC          default 64
#   MIX_TOTAL_PROMPTS default 1000
#   STAGE_TAG         default "stageB" (controls results dir)
#
# Usage:
#   STAGE_TAG=stageD MIX_CONC=96 \
#     bash prfaas/m1.5-vllm-baseline/scripts/run_mixed_trace.sh

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

m15_require_env PRIMARY_MODEL PRIMARY_MODEL_TAG
: "${PROXY_HOST:=127.0.0.1}"
: "${PROXY_PORT:=8000}"
: "${MIX_CONC:=64}"
: "${MIX_TOTAL_PROMPTS:=1000}"
: "${STAGE_TAG:=stageB}"
: "${MODEL:=${PRIMARY_MODEL}}"

# 60 / 25 / 15 split, integer-rounded so the sum equals MIX_TOTAL_PROMPTS.
n_chat=$(( MIX_TOTAL_PROMPTS * 60 / 100 ))
n_rag=$(( MIX_TOTAL_PROMPTS * 25 / 100 ))
n_long=$(( MIX_TOTAL_PROMPTS - n_chat - n_rag ))

ts="$(date +%Y%m%d-%H%M%S)"
out_dir="${M15_RESULTS_DIR}/${STAGE_TAG}/${PRIMARY_MODEL_TAG}/mixed_trace/${ts}"
mkdir -p "${out_dir}"

VLLM_PKG_DIR="$("${PRFAAS_VENV}/bin/python" -c 'import vllm, os; print(os.path.dirname(vllm.__file__))')"
BENCH="${VLLM_PKG_DIR}/../benchmarks/benchmark_serving.py"
[[ -f "${BENCH}" ]] || BENCH=""

run_segment() {
  local label="$1" in_len="$2" out_len="$3" n="$4"
  local tag="${label}_in-${in_len}_out-${out_len}_c-${MIX_CONC}_n-${n}"
  m15_log "mixed: ${label} in=${in_len} out=${out_len} n=${n} (conc=${MIX_CONC})"
  local args=(
    --backend vllm --model "${MODEL}"
    --dataset-name random
    --random-input-len "${in_len}" --random-output-len "${out_len}"
    --random-prefix-len 50
    --num-prompts "${n}" --max-concurrency "${MIX_CONC}"
    --trust-remote-code --ignore-eos
    --host "${PROXY_HOST}" --port "${PROXY_PORT}"
    --save-result
    --percentile-metrics 'ttft,tpot,itl,e2el'
    --metric-percentiles '50,95,99'
    --result-dir "${out_dir}"
    --result-filename "${tag}.json"
  )
  if [[ -n "${BENCH}" ]]; then
    "${PRFAAS_VENV}/bin/python" "${BENCH}" "${args[@]}" \
      >"${out_dir}/${tag}.log" 2>&1 &
  else
    "${PRFAAS_VENV}/bin/python" -m vllm.benchmarks.serve "${args[@]}" \
      >"${out_dir}/${tag}.log" 2>&1 &
  fi
}

m15_log "starting three concurrent random-length submitters → ${PROXY_HOST}:${PROXY_PORT}"
m15_log "trace size: chat=${n_chat} rag=${n_rag} long=${n_long} total=${MIX_TOTAL_PROMPTS}"

run_segment chat 1024  256 "${n_chat}"
run_segment rag  8192  512 "${n_rag}"
run_segment long 16384 256 "${n_long}"
wait

m15_log "mixed trace done — JSONs under ${out_dir}"

# Roll up: report TTFT P95 per sub-trace and aggregate output throughput.
"${PRFAAS_VENV}/bin/python" - "${out_dir}" <<'PY'
import csv, glob, json, os, sys
out_dir = sys.argv[1]
rows = []
agg_tput = 0.0
for js in sorted(glob.glob(os.path.join(out_dir, "*.json"))):
    d = json.load(open(js))
    label = os.path.basename(js).split("_")[0]
    rows.append({
        "segment":  label,
        "n":        d.get("num_prompts") or d.get("completed", ""),
        "ttft_p50_ms": d.get("median_ttft_ms", ""),
        "ttft_p95_ms": d.get("p95_ttft_ms") or d.get("ttft_p95_ms", ""),
        "ttft_p99_ms": d.get("p99_ttft_ms") or d.get("ttft_p99_ms", ""),
        "tpot_p50_ms": d.get("median_tpot_ms", ""),
        "e2el_p50_ms": d.get("median_e2el_ms", ""),
        "output_tput_tok_s": d.get("output_throughput", ""),
    })
    try:
        agg_tput += float(d.get("output_throughput", 0))
    except (TypeError, ValueError):
        pass

with open(os.path.join(out_dir, "mixed_trace.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(rows)

with open(os.path.join(out_dir, "SUMMARY.md"), "w") as f:
    f.write("# Mixed trace summary\n\n")
    f.write("| Segment | N | TTFT P50 ms | TTFT P95 ms | TTFT P99 ms | TPOT P50 ms | E2EL P50 ms | Out tput tok/s |\n")
    f.write("|---|---|---|---|---|---|---|---|\n")
    for r in rows:
        f.write("| " + " | ".join(str(r[k]) for k in r) + " |\n")
    f.write(f"\nAggregate output throughput (sum over segments): **{agg_tput:.1f} tok/s**\n")
print("wrote", os.path.join(out_dir, "mixed_trace.csv"))
print("wrote", os.path.join(out_dir, "SUMMARY.md"))
PY

m15_log "see ${out_dir}/SUMMARY.md"
