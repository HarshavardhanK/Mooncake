#!/usr/bin/env bash
# Run transfer_engine_bench in target mode. Stays up until killed.
# Logs the RPC port the initiator must use as `--segment_id=<host>:<port>`.
#
# Env:
#   PROTOCOL          tcp|rdma   (default: tcp)
#   BUFFER_SIZE_MB    target buffer (default: 4096 MiB)
#   EXTRA_ARGS        passthrough to bench
#   MC_*              standard Mooncake env vars

set -euo pipefail

protocol="${PROTOCOL:-tcp}"
buffer_size_mb="${BUFFER_SIZE_MB:-4096}"
buffer_size=$(( buffer_size_mb * 1024 * 1024 ))

exec transfer_engine_bench \
  --mode=target \
  --protocol="${protocol}" \
  --metadata_server=P2PHANDSHAKE \
  --buffer_size="${buffer_size}" \
  ${EXTRA_ARGS:-}
