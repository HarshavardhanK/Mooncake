# K8s discovery — both clusters

**Date:** 2026-04-20T05:05 UTC
**Pivot trigger:** operator directive *"Are we installing things in the
kubernetes way or directly on the host? I don't want anything directly on
the host. Follow the k8s path."* — recorded as the constraint that drives
everything below.

We have two `kubectl` contexts (kubeconfigs handed off by the operator):

| Cluster | Kubeconfig (local) | API server | Where |
|---|---|---|---|
| **X** (g304, g307) | `~/Code/VP/kubeconfigs/vpcloud-slurm-v2-admin.kubeconfig.yaml` | `api.f7cafae9-….hosted-control-plane.k8s.iad1.voltagepark.net:6443` | iad1 |
| **Y** (g126) | `~/Code/VP/kubeconfigs/aln1-beta-harsha-g126-beta.kubeconfig.yaml` | `api.9698abbb-….hosted-control-plane.k8s.beta.dfw1.voltagepark.net:6443` | dfw1-beta |

Both run k8s **v1.35.0**, containerd **2.2.1**, Cilium CNI.

## X cluster (`vpcloud-slurm-v2-admin`, iad1)

| | |
|---|---|
| **My identity** | `admin` / `system:masters` → **cluster-admin** |
| **Nodes** | `g304` (10.10.34.2), `g307` (10.10.34.5), `slurmdev01` (10.14.91.6, no GPU) |
| **GPUs/node** | 8× NVIDIA-H100-80GB-HBM3, allocatable as `nvidia.com/gpu: 8` |
| **CPU/RAM/disk** per GPU node | 104 cores, 1056 GB RAM, 459 GB ephemeral storage |
| **RDMA** | `rdma/hca_shared_devices_a` capacity exposed (RDMA shared-device plugin running) — IB available to pods! |
| **GPU operator** | full stack (driver-daemonset, device-plugin, dcgm, gfd, container-toolkit) |
| **CNI / extras** | Cilium + Cilium-Envoy, csi-nfs-node DS, kruise-system, mpi-operator, monitoring |
| **StorageClasses** | **NONE.** Means: no dynamic PVCs. Use `hostPath` (admin), local NFS via csi-nfs, or pre-pull weights. |
| **LB controller** | none (no MetalLB / kube-vip). Means: NodePort or hostNetwork for cross-cluster traffic. |
| **slurmdev01** | a Slurm controller, 16 cores / 65 GB / no GPU. Not relevant for our pods. |

Notable: the existing `slurm-v2-test` ns + `mpi-operator` + `kruise-system`
suggest this cluster doubles as a Slurm-on-K8s testbed. We avoid those
namespaces and create our own.

## Y cluster (`aln1-beta-harsha-g126-beta`, dfw1-beta)

| | |
|---|---|
| **My identity** | `user` / group `mks:customer` → **namespaced** (no cluster-admin) but I have full CRUD on Pods/Deployments/Services/PVCs/ConfigMaps/Secrets/Jobs/StatefulSets/Namespaces in `default` and any new ns I create. |
| **Nodes** | `g126` only, 10.15.18.105 internal |
| **GPUs/node** | 8× H100-80GB, `nvidia.com/gpu: 8` allocatable |
| **CPU/RAM/disk** | (similar to X — full H100 box) |
| **GPU operator** | yes; `nvidia-device-plugin-daemonset`, `gpu-feature-discovery`, `nvidia-dcgm`, etc. |
| **StorageClasses** | `local-path` (default, `WaitForFirstConsumer`, `ReadWriteOnce`) via Rancher local-path-provisioner. **VAST CSI** present (vast-csi ns) but no SC exposed yet. |
| **CSIs** | local-path, csi-nfs, csi-vast |
| **LB controller** | none |
| **Other ns** | `nvsentinel` (NVIDIA fault detection — Mongo-backed, 3 PVCs of 8 GB each on local-path) |
| **PSP / PSA** | no PSP API; default ns has no Pod-Security label → likely permissive (we'll find out at first apply) |

So Y has a working dynamic SC for model weights (RWO is fine since both
pods land on the same node), and we have full app-layer permissions.

## Implications for Mooncake / vLLM deployment

1. **Image pulls** — both clusters reach Docker Hub OK (default), so
   `vllm/vllm-openai:v0.19.1` (latest stable, 10 GB) and PyPI
   `mooncake-transfer-engine==0.3.10.post1` are accessible. We layer the
   pip wheel via an `initContainer` (writes to a shared `emptyDir` on
   `/opt/mooncake-pip` then prepends it to PYTHONPATH). Avoids building
   and pushing a custom image for now.

2. **Model staging.**
   - Y: `PersistentVolumeClaim` on `local-path` SC, RWO,
     ReadWriteOnce. Both pods land on g126 (only one node), so single PV
     mounted via `subPath` in two pods is acceptable. Or two PVCs,
     download twice (slow but cleaner). We'll start with a single PVC
     mounted RWO and pin both pods to g126 with a node selector.
   - X: no SC, so we can't dynamically provision. Two options:
     a. **`hostPath` + a one-shot `Job` per node** that pre-downloads
        weights to `/srv/models/<model>` on each node. Simple, fast on
        re-runs.
     b. **PV from `csi-nfs` to a shared NFS export.** Cleaner across
        nodes but needs an NFS server we control.
     For Stage B (X internal): hostPath. For Stage D: same hostPath on
     g304, separate PVC (or hostPath) on g126.

3. **Cross-cluster KV transfer (Stage D)** — pods on g304 must reach
   pods on g126 over the **public Internet** (29.75 ms RTT, 14.7 Gbps
   ceiling per Stage 0a). Three options, in increasing isolation:
   - `hostNetwork: true` on the Mooncake-relevant pods. They bind to the
     node's public IP directly. Simplest, lowest overhead, but pods see
     the host's full network namespace (any port conflict is real). We
     already have firewall rules for ports 13000–17000 on the hosts.
   - **NodePort** services that expose pod ports on every node. Less
     leaky than hostNetwork, but adds a kube-proxy hop on the
     receive side and we'd need to overlap NodePort range (default
     30000–32767) with whatever Mooncake uses.
   - Cilium BGP / external IP. Not configured.
   **Decision (Stage D):** start with `hostNetwork: true` for the
   Mooncake-carrying pod (decoder on g126, prefiller on g304); leave the
   front-door HTTP server on a regular Service. Fall back to NodePort if
   port conflicts surface.

4. **Bootstrap port** — vLLM v1 MooncakeConnector uses
   `VLLM_MOONCAKE_BOOTSTRAP_PORT` (default 8998) on the prefiller. With
   `hostNetwork: true`, the decoder reaches it via the prefiller's host
   IP. With ClusterIP services in single-cluster Stage A, the
   prefiller's headless Service exposes 8998 cluster-internally.

5. **Service mesh / TLS** — none. We rely on the host firewall (port
   13000–17000 already opened in Stage 0a) and on the public Internet
   path being commercial-grade. Stage 0b (WireGuard ablation) is still
   on the menu if jitter or auth concerns surface.

## Cleanup of host-side artifacts

The Stage 0a host installs (apt packages, Mooncake C++ libs in
`~/prfaas/Mooncake`, host TCP sysctls, iptables rules) **stay**. They were
necessary to characterize the wire and don't conflict with the K8s path.
The TCP sysctls + iptables rules will be reused by `hostNetwork: true`
pods in Stage D.

The aborted Stage A host install on g126 has been cleaned up:
`~/.prfaas/venv` removed (was ~11 GB partial). The apt packages
`python3.10-venv` and `python3-pip` remain since they're system-level
Ubuntu packages with no negative impact.

No further changes to host filesystems or services from this point on.
Everything new goes through `kubectl apply`.
