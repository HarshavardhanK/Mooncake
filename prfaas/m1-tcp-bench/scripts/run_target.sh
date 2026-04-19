#!/usr/bin/env bash
# Run a Transfer Engine bench in target mode. Stays up until killed.
# Logs the RPC port the initiator must use as `--segment_id=<host>:<port>`.
#
# Env:
#   BENCH_BIN         lat|upstream    (default: lat — uses our latency-aware
#                                      bench. Both target binaries are
#                                      interchangeable on the wire because
#                                      they use the same TCP transport.)
#   PROTOCOL          tcp|rdma        (default: tcp; ignored when BENCH_BIN=lat)
#   BUFFER_SIZE_MB    target buffer per NUMA node (default: 4096 MiB)
#   EXTRA_ARGS        passthrough to bench
#   MC_*              standard Mooncake env vars
#
# Port discovery (P2P handshake mode only):
#   The Transfer Engine ignores the port in `local_server_name` and randomly
#   picks one from `MC_MIN_PRC_PORT`..`MC_MAX_PRC_PORT` (default 15000-17000)
#   for both the RPC handshake and the TCP data plane. We can't pin both to a
#   single port (they need separate ports) so the actual RPC port is announced
#   on stdout via:
#       Transfer Engine RPC using P2P handshake, listening on <host>:<port>
#   The harness (smoke_test.sh / run_matrix.sh / your wrapper) must scrape
#   this line and pass it to the initiator as `--segment-id <host>:<port>`.

set -euo pipefail

bench_bin="${BENCH_BIN:-lat}"
protocol="${PROTOCOL:-tcp}"
buffer_size_mb="${BUFFER_SIZE_MB:-4096}"
buffer_size=$(( buffer_size_mb * 1024 * 1024 ))

case "$bench_bin" in
  lat)
    exec transfer_engine_lat_bench \
      --mode=target \
      --metadata_server=P2PHANDSHAKE \
      --buffer_size="${buffer_size}" \
      ${EXTRA_ARGS:-}
    ;;
  upstream)
    exec transfer_engine_bench \
      --mode=target \
      --protocol="${protocol}" \
      --metadata_server=P2PHANDSHAKE \
      --buffer_size="${buffer_size}" \
      ${EXTRA_ARGS:-}
    ;;
  *)
    echo "unknown BENCH_BIN=${bench_bin} (lat|upstream)" >&2
    exit 2
    ;;
esac
