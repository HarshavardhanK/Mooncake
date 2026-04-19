#!/usr/bin/env bash
# Build transfer_engine_bench natively (no Docker), for use on real cluster
# nodes. Mirrors the cmake flags in docker/Dockerfile so the binary behaves
# identically in both paths.
#
# Run from the repo root:
#   sudo ./dependencies.sh -y    # one-time, installs system pkgs + submodules + yalantinglibs
#   ./prfaas/m1-tcp-bench/scripts/native_build.sh
#
# Outputs:
#   build/mooncake-transfer-engine/example/transfer_engine_bench
#
# Env:
#   BUILD_DIR     defaults to ./build
#   JOBS          defaults to nproc

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${repo_root}"

build_dir="${BUILD_DIR:-${repo_root}/build}"
jobs="${JOBS:-$(nproc)}"

if [[ ! -f "${repo_root}/extern/yalantinglibs/CMakeLists.txt" ]]; then
  echo "ERROR: extern/yalantinglibs missing." >&2
  echo "Run: git submodule update --init --recursive" >&2
  echo "Or:  sudo ./dependencies.sh -y    (does submodules + yalantinglibs install)" >&2
  exit 1
fi

mkdir -p "${build_dir}"
cd "${build_dir}"

# Detect ninja; fall back to make.
generator="Unix Makefiles"
if command -v ninja >/dev/null 2>&1; then
  generator="Ninja"
fi

cmake "${repo_root}" -G "${generator}" \
  -DUSE_CUDA=OFF \
  -DUSE_ETCD=OFF \
  -DWITH_STORE=OFF \
  -DWITH_STORE_RUST=OFF \
  -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo

cmake --build . --target transfer_engine_bench -j"${jobs}"

bench="${build_dir}/mooncake-transfer-engine/example/transfer_engine_bench"
if [[ ! -x "${bench}" ]]; then
  echo "ERROR: build did not produce ${bench}" >&2
  exit 1
fi

echo
echo "[native_build] OK -> ${bench}"
echo "[native_build] add to PATH or alias as needed:"
echo "    export PATH=\"${build_dir}/mooncake-transfer-engine/example:\$PATH\""
echo "    export LD_LIBRARY_PATH=\"${build_dir}/mooncake-transfer-engine/src:${build_dir}/mooncake-asio:\${LD_LIBRARY_PATH:-}\""
