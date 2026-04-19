# PrfaaS M1 — minimal image with Mooncake's transfer_engine_bench + tc netem.
# Built from the repo root so the local source tree is the build context.
#
#   docker build -f prfaas/m1-tcp-bench/docker/Dockerfile -t prfaas/m1-bench .
#
# We deliberately build only the Transfer Engine + bench binary (no CUDA, no
# Mooncake Store). M1 is a transport-layer experiment.

ARG UBUNTU_VERSION=22.04
FROM ubuntu:${UBUNTU_VERSION} AS build

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates pkg-config \
        libgoogle-glog-dev libgflags-dev libnuma-dev \
        libssl-dev libcurl4-openssl-dev \
        python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . /src

# Build only what we need for M1: Transfer Engine + the bench binary.
# - USE_CUDA=OFF: no GPU in the bench container
# - WITH_STORE=OFF: M1 is transport-only
# - USE_ETCD=OFF: bench supports P2PHANDSHAKE, no metadata service required
RUN mkdir -p build && cd build && \
    cmake .. \
        -DUSE_CUDA=OFF \
        -DUSE_ETCD=OFF \
        -DWITH_STORE=OFF \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo && \
    cmake --build . -j"$(nproc)" --target transfer_engine_bench

FROM ubuntu:${UBUNTU_VERSION} AS runtime
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgoogle-glog0v5 libgflags2.2 libnuma1 libssl3 libcurl4 \
        iproute2 iputils-ping net-tools sysstat ethtool \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# Copy bench + its shared libs.
COPY --from=build /src/build/mooncake-transfer-engine/example/transfer_engine_bench \
                  /usr/local/bin/transfer_engine_bench
COPY --from=build /src/build/mooncake-transfer-engine/src/libtransfer_engine.so \
                  /usr/local/lib/
RUN ldconfig

WORKDIR /work
COPY prfaas/m1-tcp-bench/scripts /work/scripts
RUN chmod +x /work/scripts/*.sh

ENTRYPOINT ["/bin/bash"]
