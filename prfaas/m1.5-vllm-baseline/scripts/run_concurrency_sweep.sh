#!/usr/bin/env bash
# Run vLLM's benchmark_serving.py over a concurrency sweep for ONE workload,
# against an already-running proxy/vLLM endpoint. Stops once TTFT P95 has
# crossed the workload's SLO (so we don't burn time at obviously-saturated
# concurrencies).
#
# Required env:
#   WORKLOAD       chat_balanced | long_context | rag_summary | code_complete
#   RESULTS_DIR    where to put per-cell JSONs and the rolled-up CSV
# Optional:
#   PROXY_HOST     default 127.0.0.1
#   PROXY_PORT     default 8000
#   MODEL          default $PRIMARY_MODEL
#   CONCURRENCIES  space-separated list, default "1 4 16 32 64 128 192"
#   NUM_FOLDS      requests = concurrency × NUM_FOLDS, default 20
#   STOP_ON_SLO_BREACH  default 1 (set 0 to always run the full sweep)

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

m15_require_env WORKLOAD RESULTS_DIR
: "${PROXY_HOST:=127.0.0.1}"
: "${PROXY_PORT:=8000}"
: "${MODEL:=${PRIMARY_MODEL}}"
: "${CONCURRENCIES:=1 4 16 32 64 128 192}"
: "${NUM_FOLDS:=20}"
: "${STOP_ON_SLO_BREACH:=1}"

case "${WORKLOAD}" in
  chat_balanced)  INPUT_LEN=1024;  OUTPUT_LEN=256; SLO_MS="${TTFT_SLO_CHAT_BALANCED_MS}" ;;
  long_context)   INPUT_LEN=16384; OUTPUT_LEN=256; SLO_MS="${TTFT_SLO_LONG_CONTEXT_MS}" ;;
  rag_summary)    INPUT_LEN=8192;  OUTPUT_LEN=512; SLO_MS="${TTFT_SLO_RAG_SUMMARY_MS}" ;;
  code_complete)  INPUT_LEN=4096;  OUTPUT_LEN=32;  SLO_MS="${TTFT_SLO_CODE_COMPLETE_MS}" ;;
  *) m15_die "unknown WORKLOAD=${WORKLOAD}" ;;
esac

mkdir -p "${RESULTS_DIR}/${WORKLOAD}"
CSV="${RESULTS_DIR}/${WORKLOAD}/sweep.csv"
if [[ ! -f "${CSV}" ]]; then
  echo "workload,model,input_len,output_len,concurrency,num_prompts,wall_clock_iso,ttft_p50_ms,ttft_p95_ms,ttft_p99_ms,tpot_p50_ms,e2el_p50_ms,output_throughput_tok_s,slo_ms,slo_met" > "${CSV}"
fi

# vLLM's benchmark_serving.py lives in the vllm pip install. Locate it.
VLLM_PKG_DIR="$("${PRFAAS_VENV}/bin/python" -c 'import vllm, os; print(os.path.dirname(vllm.__file__))')"
BENCH="${VLLM_PKG_DIR}/../benchmarks/benchmark_serving.py"
if [[ ! -f "${BENCH}" ]]; then
  # Modern vLLM ships it inside the package as `vllm.benchmarks.serve`.
  BENCH=""
fi

run_one_cell() {
  local conc="$1"
  local num_prompts=$(( conc * NUM_FOLDS ))
  local tag
  tag="$(printf 'in-%05d_out-%04d_c-%03d' "${INPUT_LEN}" "${OUTPUT_LEN}" "${conc}")"
  local out_json="${RESULTS_DIR}/${WORKLOAD}/${tag}.json"
  local out_log="${RESULTS_DIR}/${WORKLOAD}/${tag}.log"
  local now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  m15_log "cell: ${WORKLOAD} concurrency=${conc} num_prompts=${num_prompts}"
  if [[ -n "${BENCH}" ]]; then
    "${PRFAAS_VENV}/bin/python" "${BENCH}" \
      --backend vllm \
      --model "${MODEL}" \
      --dataset-name random \
      --random-input-len "${INPUT_LEN}" \
      --random-output-len "${OUTPUT_LEN}" \
      --random-prefix-len 50 \
      --num-prompts "${num_prompts}" \
      --max-concurrency "${conc}" \
      --trust-remote-code \
      --ignore-eos \
      --host "${PROXY_HOST}" \
      --port "${PROXY_PORT}" \
      --save-result \
      --percentile-metrics 'ttft,tpot,itl,e2el' \
      --metric-percentiles '50,95,99' \
      --result-dir "${RESULTS_DIR}/${WORKLOAD}/" \
      --result-filename "${tag}.json" \
      >"${out_log}" 2>&1
  else
    "${PRFAAS_VENV}/bin/python" -m vllm.benchmarks.serve \
      --backend vllm \
      --model "${MODEL}" \
      --dataset-name random \
      --random-input-len "${INPUT_LEN}" \
      --random-output-len "${OUTPUT_LEN}" \
      --random-prefix-len 50 \
      --num-prompts "${num_prompts}" \
      --max-concurrency "${conc}" \
      --trust-remote-code \
      --ignore-eos \
      --host "${PROXY_HOST}" \
      --port "${PROXY_PORT}" \
      --save-result \
      --percentile-metrics 'ttft,tpot,itl,e2el' \
      --metric-percentiles '50,95,99' \
      --result-dir "${RESULTS_DIR}/${WORKLOAD}/" \
      --result-filename "${tag}.json" \
      >"${out_log}" 2>&1
  fi

  # Pluck percentiles out of the JSON the benchmark writes.
  "${PRFAAS_VENV}/bin/python" - "${out_json}" "${WORKLOAD}" "${MODEL}" "${INPUT_LEN}" "${OUTPUT_LEN}" "${conc}" "${num_prompts}" "${now_iso}" "${SLO_MS}" "${CSV}" <<'PY'
import json, sys, csv
js, workload, model, in_len, out_len, conc, n, ts, slo_ms, csv_path = sys.argv[1:]
d = json.load(open(js))
def g(k, default=""):
    return d.get(k, default)
ttft_p50 = g("median_ttft_ms")
ttft_p95 = g("p95_ttft_ms") or g("ttft_p95_ms")
ttft_p99 = g("p99_ttft_ms") or g("ttft_p99_ms")
tpot_p50 = g("median_tpot_ms")
e2el_p50 = g("median_e2el_ms")
out_tput = g("output_throughput")
slo_met  = 1 if (ttft_p95 != "" and float(ttft_p95) <= float(slo_ms)) else 0
with open(csv_path, "a", newline="") as f:
    csv.writer(f).writerow([workload, model, in_len, out_len, conc, n, ts,
                             ttft_p50, ttft_p95, ttft_p99, tpot_p50, e2el_p50,
                             out_tput, slo_ms, slo_met])
print(f"  TTFT_P95={ttft_p95} ms (SLO={slo_ms} ms) slo_met={slo_met}")
PY
}

slo_breached=0
for conc in ${CONCURRENCIES}; do
  run_one_cell "${conc}"
  # Check the last row: did P95 breach SLO?
  last_slo_met="$(tail -1 "${CSV}" | awk -F',' '{print $NF}')"
  if [[ "${last_slo_met}" == "0" ]]; then
    slo_breached=$(( slo_breached + 1 ))
    if [[ "${STOP_ON_SLO_BREACH}" -eq 1 && "${slo_breached}" -ge 2 ]]; then
      m15_log "SLO breached at concurrency=${conc} (and once before); stopping sweep"
      break
    fi
  fi
done

m15_log "sweep done — see ${CSV}"
