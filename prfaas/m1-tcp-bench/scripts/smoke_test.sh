#!/usr/bin/env bash
# Smoke test: run target + initiator on the same host (loopback) for a small
# subset of the matrix. Validates the harness wiring before two-DC runs.
#
#   ./prfaas/m1-tcp-bench/scripts/smoke_test.sh [build_dir]
#
# Defaults:
#   build_dir = ./build (override or pass as $1)
#
# Writes:
#   prfaas/m1-tcp-bench/results/smoke.csv
#
# Cells run (3 total): single block_size + threads, sweep slice/conn-pool to
# prove env-var plumbing reaches the bench.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
m1_root="$(cd "${here}/.." && pwd)"
repo_root="$(cd "${m1_root}/../.." && pwd)"

build_dir="${1:-${BUILD_DIR:-${repo_root}/build}}"
bench="${build_dir}/mooncake-transfer-engine/example/transfer_engine_bench"
lat_bench="${build_dir}/prfaas/m1-tcp-bench/bench/transfer_engine_lat_bench"

for b in "${bench}" "${lat_bench}"; do
  if [[ ! -x "${b}" ]]; then
    echo "ERROR: ${b} not found. Run scripts/native_build.sh first." >&2
    exit 1
  fi
done

export PATH="${build_dir}/mooncake-transfer-engine/example:${build_dir}/prfaas/m1-tcp-bench/bench:${PATH}"
export LD_LIBRARY_PATH="${build_dir}/mooncake-transfer-engine/src:${build_dir}/mooncake-asio:${LD_LIBRARY_PATH:-}"

results_csv="${m1_root}/results/smoke.csv"
target_log="${m1_root}/results/smoke.target.log"
mkdir -p "${m1_root}/results"
: > "${target_log}"

echo "[smoke] starting target on loopback"
PROTOCOL=tcp BUFFER_SIZE_MB=1024 \
  "${here}/run_target.sh" >"${target_log}" 2>&1 &
target_pid=$!

cleanup() {
  echo "[smoke] tearing down (pid=${target_pid})"
  kill "${target_pid}" 2>/dev/null || true
  wait "${target_pid}" 2>/dev/null || true
  pkill -f 'transfer_engine_(lat_)?bench --mode=target' 2>/dev/null || true
}
trap cleanup EXIT

# Wait for "listening on host:port" line.
for _ in $(seq 1 30); do
  if grep -Eq 'listening on [^ ]+:[0-9]+' "${target_log}"; then
    break
  fi
  sleep 1
done

listen_line=$(grep -Eo 'listening on [^ ]+:[0-9]+' "${target_log}" | tail -1 || true)
if [[ -z "${listen_line}" ]]; then
  echo "ERROR: target failed to come up" >&2
  echo "--- target log ---" >&2
  tail -30 "${target_log}" >&2
  exit 1
fi
target_addr="${listen_line##* }"
echo "[smoke] target=${target_addr}"

# Use 127.0.0.1 explicitly for loopback (target may bind to hostname).
host_part="${target_addr%:*}"
port_part="${target_addr##*:}"
target_addr="127.0.0.1:${port_part}"

# Truncate CSV so the smoke test is reproducible.
: > "${results_csv}"

cells=(
  # block-size threads slice  pool rr
  "65536      4       65536  0    0"
  "65536      4       65536  1    0"
  "262144     4       262144 1    0"
)

for cell in "${cells[@]}"; do
  read -r bs th ss cp rr <<<"${cell}"
  "${here}/run_initiator.sh" \
    --segment-id "${target_addr}" \
    --csv "${results_csv}" \
    --profile "lan" \
    --op write \
    --block-size "${bs}" \
    --threads "${th}" \
    --slice-size "${ss}" \
    --conn-pool "${cp}" \
    --roundrobin "${rr}" \
    --duration 5 \
    --notes "smoke"
done

echo
echo "[smoke] OK -> ${results_csv}"
column -ts, "${results_csv}" || cat "${results_csv}"
