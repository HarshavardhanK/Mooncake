#!/usr/bin/env bash
# Thin wrapper around m15_render_template so it's invocable from RUNBOOK.md.
# Computes a sensible LOCAL_HOSTNAME based on PRFAAS_ROLE if not already set.
#
# Usage:
#   bash render_config.sh --template <path> --out <path>

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

TEMPLATE=""
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --template) TEMPLATE="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    *) m15_die "unknown arg: $1" ;;
  esac
done
[[ -n "${TEMPLATE}" && -n "${OUT}" ]] || \
  m15_die "usage: $0 --template <path> --out <path>"

# If template path is relative, resolve against the configs dir.
if [[ ! -f "${TEMPLATE}" && -f "${M15_DIR}/${TEMPLATE}" ]]; then
  TEMPLATE="${M15_DIR}/${TEMPLATE}"
fi
[[ -f "${TEMPLATE}" ]] || m15_die "template not found: ${TEMPLATE}"

# Set LOCAL_HOSTNAME based on role if the template needs it (x_internal one does).
if [[ -z "${LOCAL_HOSTNAME:-}" ]]; then
  case "${PRFAAS_ROLE:-}" in
    x_gateway)   export LOCAL_HOSTNAME="${X_GATEWAY_INTERNAL_IP:-${X_GATEWAY_PUBLIC_IP}}" ;;
    x_internal)  export LOCAL_HOSTNAME="${X_INTERNAL_INTERNAL_IP}" ;;
    y)           export LOCAL_HOSTNAME="${Y_PUBLIC_IP}" ;;
    *)           export LOCAL_HOSTNAME="127.0.0.1" ;;
  esac
fi
m15_log "LOCAL_HOSTNAME=${LOCAL_HOSTNAME} (role=${PRFAAS_ROLE:-unset})"

m15_render_template "${TEMPLATE}" "${OUT}"
cat "${OUT}"
