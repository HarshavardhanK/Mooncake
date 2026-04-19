# PrfaaS M1 — minimal image with Mooncake's transfer_engine_bench.
# Built from the repo root so the local source tree is the build context.
#
#   docker build -f prfaas/m1-tcp-bench/docker/Dockerfile -t prfaas/m1-bench .
#
# We follow upstream's `dependencies.sh` exactly to avoid drifting from the
# canonical install (system pkgs + git submodules + yalantinglibs from source).
# The only knobs we override at cmake time are:
#   - WITH_STORE=OFF       (M1 is transport-only)
#   - WITH_STORE_RUST=OFF  (defaults ON, requires WITH_STORE)
#   - USE_CUDA=OFF         (M1 cross-DC hop is DRAM<->DRAM)
#   - USE_ETCD=OFF         (bench uses P2PHANDSHAKE; no metadata service)
#
# We build a single stage (no slim runtime) to keep the image easy to debug
# inside, and we build only the `transfer_engine_bench` target so cmake skips
# the python module + store extensions.

ARG UBUNTU_VERSION=22.04
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# --- system packages -------------------------------------------------------
# Mirrors dependencies.sh exactly so we stay aligned with upstream. We add
# iproute2/iputils-ping/sysstat on top for the WAN-emulation harness itself.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build git wget unzip ca-certificates \
        pkg-config patchelf \
        libibverbs-dev libgoogle-glog-dev libgtest-dev libjsoncpp-dev \
        libunwind-dev libnuma-dev libpython3-dev libboost-all-dev libssl-dev \
        libgrpc-dev libgrpc++-dev libprotobuf-dev libyaml-cpp-dev \
        protobuf-compiler-grpc libcurl4-openssl-dev libhiredis-dev \
        liburing-dev libjemalloc-dev libmsgpack-dev libzstd-dev \
        libasio-dev libxxhash-dev libc6-dev libc-bin python3 \
        iproute2 iputils-ping net-tools sysstat ethtool \
    && rm -rf /var/lib/apt/lists/*

# --- source ---------------------------------------------------------------
WORKDIR /src
COPY . /src

# Initialize submodules from the repo we just COPYed. We assume the host
# checkout has them already (init'd locally). If not, the user can run
# `git submodule update --init --recursive` on the host before `docker build`.
# Re-running here is a no-op when submodules are populated.
RUN if [ -f .gitmodules ] && [ ! -f extern/yalantinglibs/CMakeLists.txt ]; then \
        echo "ERROR: extern/yalantinglibs missing. Run 'git submodule update --init --recursive' on the host before building." >&2; \
        exit 1; \
    fi

# --- yalantinglibs (from submodule, matches dependencies.sh) --------------
RUN cd extern/yalantinglibs \
    && mkdir -p build && cd build \
    && cmake .. -DBUILD_EXAMPLES=OFF -DBUILD_BENCHMARK=OFF -DBUILD_UNIT_TESTS=OFF \
    && cmake --build . -j"$(nproc)" \
    && cmake --install . \
    && cd /src && rm -rf extern/yalantinglibs/build

# --- mooncake build (only the bench target) -------------------------------
RUN mkdir -p build && cd build \
    && cmake .. -G Ninja \
        -DUSE_CUDA=OFF \
        -DUSE_ETCD=OFF \
        -DWITH_STORE=OFF \
        -DWITH_STORE_RUST=OFF \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    && cmake --build . --target transfer_engine_bench -j"$(nproc)"

# Put the bench on PATH and make sure the runtime loader can find the .so's
# that were built alongside it (transfer_engine, asio_shared, etc.).
RUN ln -s /src/build/mooncake-transfer-engine/example/transfer_engine_bench \
          /usr/local/bin/transfer_engine_bench \
    && echo "/src/build/mooncake-transfer-engine/src" >> /etc/ld.so.conf.d/mooncake.conf \
    && echo "/src/build/mooncake-asio" >> /etc/ld.so.conf.d/mooncake.conf \
    && find /src/build -maxdepth 6 -name '*.so*' -printf '%h\n' | sort -u >> /etc/ld.so.conf.d/mooncake.conf \
    && ldconfig

WORKDIR /work
COPY prfaas/m1-tcp-bench/scripts /work/scripts
RUN chmod +x /work/scripts/*.sh

ENTRYPOINT ["/bin/bash"]
