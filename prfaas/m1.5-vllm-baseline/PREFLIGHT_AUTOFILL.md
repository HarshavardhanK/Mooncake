# PREFLIGHT autofill (post-discovery)

Filled from the Phase 0 discovery run. This is what the agent will write
into `~/.prfaas_env` on each node in Phase 2 (provisioning).

The `<TBD-stage0a>` values get filled after Stage 0a runs.

## g304 (x_gateway, cluster X) — `~/.prfaas_env`

```sh
# Identity
export PRFAAS_ROLE="x_gateway"
export PRFAAS_CLUSTER="X"
export PRFAAS_NODE_ID="g304"

# Network (this node)
export PRFAAS_PUBLIC_IP="159.26.81.50"
export PRFAAS_BOOTNET_IP="10.10.34.2"        # 100 Gbps LACP, MTU 9000, to g307
export PRFAAS_PRIMARY_IFACE="bootnet"

# Network (peers)
export PRFAAS_X_GATEWAY_PUBLIC_IP="159.26.81.50"
export PRFAAS_X_GATEWAY_INTERNAL_IP="10.10.34.2"
export PRFAAS_X_INTERNAL_PUBLIC_IP="159.26.81.53"     # not reachable from g304 public-IP, USE BOOTNET
export PRFAAS_X_INTERNAL_INTERNAL_IP="10.10.34.5"     # the one we actually use
export PRFAAS_Y_PUBLIC_IP="147.185.40.126"

# Mooncake ports (canonical for the project)
export PRFAAS_MOONCAKE_MASTER_PORT=10001
export PRFAAS_ETCD_CLIENT_PORT=2379
export PRFAAS_ETCD_PEER_PORT=2380
export PRFAAS_TE_PORT_RANGE_LO=13000
export PRFAAS_TE_PORT_RANGE_HI=13999

# Storage
export PRFAAS_WORK_DIR="/scratch/prfaas"           # 14 TB empty RAID
export PRFAAS_MODEL_DIR="/scratch/prfaas/models"
export PRFAAS_LOG_DIR="/scratch/prfaas/logs"
export PRFAAS_PID_DIR="/scratch/prfaas/run"
export PRFAAS_VENV_DIR="/scratch/prfaas/venv"

# Software paths to install / build
export PRFAAS_MOONCAKE_REPO="https://github.com/HarshavardhanK/Mooncake.git"
export PRFAAS_MOONCAKE_BRANCH="feat/prfaas-m1.5-vllm-baseline"
export PRFAAS_MOONCAKE_DIR="/scratch/prfaas/Mooncake"
export PRFAAS_MOONCAKE_BUILD_DIR="/scratch/prfaas/Mooncake/build"

# RDMA / IB (active devices, all 400 Gbps CX-7, no IPv4)
export PRFAAS_IB_DEVICES="mlx5_0,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_9,mlx5_10,mlx5_11"
export PRFAAS_IB_RATE_GBPS=400

# K8s reality (informational; agent will not poke kubectl from here)
export PRFAAS_IS_K8S_NODE=1
export PRFAAS_GPU_BLOCKER="taint=cni-pending,gpu-validated=false"

# Cross-DC characteristics (from discovery)
export PRFAAS_RTT_TO_Y_MS=29.74
export PRFAAS_RTT_TO_Y_LOSS_PCT=0
export PRFAAS_GOODPUT_TO_Y_MBPS="<TBD-stage0a>"
```

## g307 (x_internal, cluster X) — `~/.prfaas_env`

```sh
# Identity
export PRFAAS_ROLE="x_internal"
export PRFAAS_CLUSTER="X"
export PRFAAS_NODE_ID="g307"

# Network
export PRFAAS_PUBLIC_IP="159.26.81.53"
export PRFAAS_BOOTNET_IP="10.10.34.5"
export PRFAAS_PRIMARY_IFACE="bootnet"

export PRFAAS_X_GATEWAY_PUBLIC_IP="159.26.81.50"
export PRFAAS_X_GATEWAY_INTERNAL_IP="10.10.34.2"     # the path we actually use g307→g304
export PRFAAS_X_INTERNAL_PUBLIC_IP="159.26.81.53"
export PRFAAS_X_INTERNAL_INTERNAL_IP="10.10.34.5"
export PRFAAS_Y_PUBLIC_IP="147.185.40.126"

export PRFAAS_MOONCAKE_MASTER_PORT=10001
export PRFAAS_ETCD_CLIENT_PORT=2379
export PRFAAS_ETCD_PEER_PORT=2380
export PRFAAS_TE_PORT_RANGE_LO=13000
export PRFAAS_TE_PORT_RANGE_HI=13999

# Storage
export PRFAAS_WORK_DIR="/scratch/prfaas"
export PRFAAS_MODEL_DIR="/scratch/prfaas/models"
export PRFAAS_LOG_DIR="/scratch/prfaas/logs"
export PRFAAS_PID_DIR="/scratch/prfaas/run"
export PRFAAS_VENV_DIR="/scratch/prfaas/venv"

# Repo paths
export PRFAAS_MOONCAKE_REPO="https://github.com/HarshavardhanK/Mooncake.git"
export PRFAAS_MOONCAKE_BRANCH="feat/prfaas-m1.5-vllm-baseline"
export PRFAAS_MOONCAKE_DIR="/scratch/prfaas/Mooncake"
export PRFAAS_MOONCAKE_BUILD_DIR="/scratch/prfaas/Mooncake/build"

export PRFAAS_IB_DEVICES="mlx5_0,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_9,mlx5_10,mlx5_11"
export PRFAAS_IB_RATE_GBPS=400

# Sudo blocker
export PRFAAS_SUDO_NOPASSWD=0
export PRFAAS_GPU_BLOCKER="no_host_nvidia_smi+no_passwordless_sudo"
```

## g126 (y, cluster Y) — `~/.prfaas_env`

```sh
# Identity
export PRFAAS_ROLE="y"
export PRFAAS_CLUSTER="Y"
export PRFAAS_NODE_ID="g126"

# Network
export PRFAAS_PUBLIC_IP="147.185.40.126"
export PRFAAS_PRIMARY_IFACE="enp27s0f0np0"
export PRFAAS_PRIMARY_IPV4="10.15.18.105"

export PRFAAS_X_GATEWAY_PUBLIC_IP="159.26.81.50"
export PRFAAS_X_INTERNAL_PUBLIC_IP="159.26.81.53"
export PRFAAS_Y_PUBLIC_IP="147.185.40.126"

export PRFAAS_MOONCAKE_MASTER_PORT=10001
export PRFAAS_ETCD_CLIENT_PORT=2379
export PRFAAS_ETCD_PEER_PORT=2380
export PRFAAS_TE_PORT_RANGE_LO=13000
export PRFAAS_TE_PORT_RANGE_HI=13999

# Storage  (single mounted FS; NVMe array is raw and we won't format it for stage 0a/A)
export PRFAAS_WORK_DIR="/home/ubuntu/prfaas"
export PRFAAS_MODEL_DIR="/home/ubuntu/prfaas/models"
export PRFAAS_LOG_DIR="/home/ubuntu/prfaas/logs"
export PRFAAS_PID_DIR="/home/ubuntu/prfaas/run"
export PRFAAS_VENV_DIR="/home/ubuntu/prfaas/venv"

# Repo
export PRFAAS_MOONCAKE_REPO="https://github.com/HarshavardhanK/Mooncake.git"
export PRFAAS_MOONCAKE_BRANCH="feat/prfaas-m1.5-vllm-baseline"
export PRFAAS_MOONCAKE_DIR="/home/ubuntu/prfaas/Mooncake"
export PRFAAS_MOONCAKE_BUILD_DIR="/home/ubuntu/prfaas/Mooncake/build"

# Hardware
export PRFAAS_GPU_COUNT=8
export PRFAAS_GPU_MODEL="H100-80GB-HBM3"
export PRFAAS_DRIVER_VERSION="570.211.01"

# Cross-DC characteristics (this is the side that initiates against X)
export PRFAAS_RTT_TO_X_GW_MS=29.71
export PRFAAS_RTT_TO_X_GW_LOSS_PCT=0
export PRFAAS_RTT_TO_X_GW_JITTER_MS=0.09

# Sudo
export PRFAAS_SUDO_NOPASSWD=1
```

## Open holes the agent needs to fill before Stage B/D

1. **Stage 0a goodput** — fills `PRFAAS_GOODPUT_TO_Y_MBPS`.
2. **VP-support unblocks (B/D only)** — when GPUs are exposed on g304 and
   g307 from the host shell (and g307 has sudo), the env files above are
   ready to drive the existing stage scripts unchanged.
