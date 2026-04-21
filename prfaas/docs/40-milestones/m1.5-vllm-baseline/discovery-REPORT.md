# Phase 0 + 1 — Discovery report

Three parallel SSH-only discovery agents (g304, g307, g126) plus a follow-up
bootnet probe between g304↔g307. All read-only; nothing was installed or
modified on the nodes.

## TL;DR

- **Hardware is great**: 24× H100s as advertised, 1 TB RAM/node,
  100 Gbps bootnet between X-nodes, 29.7 ms ± 0.09 cross-DC RTT to Y.
- **Three real blockers** before Stage B/D can run:
  1. **GPUs on g304/g307 are owned by NVIDIA GPU Operator inside K8s** —
     `nvidia-smi` does not work from the host shell. Both X-nodes are
     Voltage Park managed-K8s workers (Cilium CNI, kubelet on :10250, NVIDIA
     driver container). g304 also has a `voltagepark.io/cni-pending=
     true:NoSchedule` taint and `gpu-validated=false`.
  2. **g307 has no NOPASSWD sudo** (g304 and g126 do). g307 cannot install
     anything as root from the SSH session as `vpsupport`.
  3. **CUDA toolkit is missing on all three nodes** (drivers loaded; no
     nvcc, no `/usr/local/cuda*`).
- **Cross-DC connectivity is excellent**: 29.7 ms RTT, 0% loss, sub-0.1 ms
  jitter. SSH and arbitrary high TCP ports appear reachable from g126 → both
  X public IPs (only port 13000 was tested as "no listener", which is a Y/X
  app-side absence, not a firewall block).
- **Inter-X connectivity over bootnet works**: 100 Gbps bonded LACP, MTU
  9000, 0.084 ms RTT between 10.10.34.2 (g304) ↔ 10.10.34.5 (g307). IB
  ports are UP but **have no IPv4** (IPoIB not configured). For Mooncake's
  RDMA verbs transport, the IB HCAs (`mlx5_0/3/4/5/6/9/10/11`) are usable
  by name; for TCP transport, bootnet is the path.

## What we can do without VP-support intervention

| Stage | Feasible? | Why |
|---|---|---|
| **0a** Transport bench, g304 ↔ g126 over public internet | YES | Both have sudo. Bench is CPU + TCP only; no GPU needed. Need to install Mooncake bench + open firewall (sudo iptables on each side, scoped to the peer IP). |
| **A**  Smoke 1P1D on g126 | YES | g126 has 8× H100 visible from host shell, sudo, 388 GB free, fresh node. Install vLLM + Mooncake + smoke model (Nemotron-Nano-9B-v2). |

## What needs VP-support intervention

| Stage | Blocked on |
|---|---|
| **B**  X1↔X2 disagg sweep on cluster X | (a) GPUs accessible on g304 AND g307 from the host shell (untaint g304, gpu-validate both) **or** kubectl access to schedule GPU pods; **and** (b) NOPASSWD sudo on g307 (or a way to install CUDA toolkit there). |
| **C**  Stage B + tc netem WAN profiles | Same as Stage B, plus sudo for `tc qdisc` (already covered by B unblocking). |
| **D**  Real cross-DC g304 ↔ g126 | Same as B (we need GPUs on g304 from host shell). Likely no extra firewall work — high TCP ports are already reachable from g126 → 159.26.81.50. |

## Detailed inventory

### g304 (x_gateway)

- **OS:** Ubuntu 24.04.4, kernel 6.8.0-100, FQDN `g304.iad1.voltagepark.net`
  (IAD = Ashburn, VA).
- **CPU/RAM:** 2× Xeon Platinum 8470 (104 logical cores), 1007 GB RAM, 8
  NUMA nodes.
- **GPUs:** 8× H100 inferred from IB topology (8 active 400 Gbps CX-7
  ports). NVIDIA driver 580.126.20 loaded but `nvidia-smi` cannot
  communicate from host shell.
- **IB:** 8 active ConnectX-7 NDR ports (400 Gbps), iface names
  `ibp{26,60,77,94,156,188,204,220}s0`. **No IPv4** on any IB port
  (IPoIB not configured).
- **Ethernet:** `bootnet` (bond, 100 Gbps LACP) at 10.10.34.2/24, MTU 9000.
  Public IP 159.26.81.50 is via NAT through 10.10.34.254, not bound on any
  local iface.
- **Storage:** `/scratch` 14 TB RAID0 (empty), `/data` 513 GB NFS @
  10.10.69.1 (98% full — unusable), root FS 387 GB free.
- **Software:** Python 3.12.3, gcc/g++ 13.3.0. No cmake, etcd, docker,
  vllm, jemalloc, mooncake libs, CUDA toolkit. RDMA userspace tooling
  present (perftest, ucx, rdma-core).
- **Sudo:** NOPASSWD ALL ✓
- **K8s:** worker node, Cilium CNI, taints `cni-pending=true:NoSchedule`,
  `gpu-validated=false`.

### g307 (x_internal)

- Same hardware class as g304 (Xeon 8470, 1 TB RAM, same 8× CX-7 IB
  topology, 14 TB /scratch).
- **GPUs:** Same K8s-owned situation. 8× H100 inferred from IB topology.
- **Ethernet:** `bootnet` at 10.10.34.5/24 (same /24 as g304). 100 Gbps
  bonded LACP, MTU 9000.
- **Sudo:** **NOT NOPASSWD** ✗ — this is the real install-time blocker
  for g307.
- **NFS `/data` is 98% full** (same share as g304).

### g126 (y)

- **OS:** Ubuntu 22.04.5, kernel 5.15.0-176.
- **CPU/RAM:** 2× Xeon Platinum 8470 (208 logical cores!), 1007 GB RAM,
  8 NUMA nodes.
- **GPUs:** **8× H100 80GB HBM3 visible from host shell**, NVLink NV18
  full mesh, driver 570.211.01.
- **NIC:** Only `mlx5_1` is up (= `enp27s0f0np0` at 10.15.18.105/29). The
  other 11 mlx5 ports are DOWN. **Single uplink for everything including
  cross-DC to X.**
- **Storage:** Root FS 388 GB free (good for Nemotron-Nano-9B-v2 ≈ 18 GB
  and Qwen3-Next-80B-A3B ≈ 160 GB if pruned). Six 2.9 TB NVMes are raw,
  unmounted (17.4 TB total available with sudo + format).
- **Software:** Python 3.10.12, gcc 11.4.0. No cmake, etcd, docker, vllm,
  CUDA toolkit. **No `infiniband-diags`** (minor; rdma-cli works).
- **Sudo:** NOPASSWD ✓
- **Outbound to X:** ping 30 ms ± 0.09 to both X public IPs, `nc :22`
  works, port 13000 reachable at L3 (just no listener yet).
- **K8s:** also a worker node (cilium, kubelet, nvidia-device-plugin
  pods running) — but unlike X, GPUs are visible to the host shell.

## Decisions that follow from the discovery

1. **Stage A and Stage 0a can start now.** I can drive them without any
   VP-support involvement. Stage 0a will give us the actual public-internet
   goodput between g304 and g126 — which directly drives the model
   decision and validates whether the paper's case study is even
   feasible on this link.
2. **The model decision shifts.** With 29.7 ms RTT and (presumably) a
   reasonable internet link from a Voltage Park IAD POP, **Qwen3-Next-80B-
   A3B-Instruct is plausibly in scope** if Stage 0a shows ≥ 25 Gbps
   sustained goodput. Nemotron-Nano-9B-v2 stays as the smoke model.
3. **Stage B's data path between g304↔g307 is bootnet (100 Gbps Ethernet),
   not IB-as-TCP.** Mooncake supports TCP transport directly; IPoIB is not
   required, IB-RDMA-by-HCA-name would need extra config we don't need
   for the disagg-pattern proof. We can revisit RDMA later.
4. **We need VP support for Stage B/D.** Specifically:
   - Untaint g304 (`kubectl taint nodes g304 voltagepark.io/cni-pending-`)
     and validate GPUs on both g304 and g307 so `nvidia-smi` works from
     host shell.
   - **OR** give us kubectl access scoped to a namespace where we can
     schedule GPU pods on g304 and g307.
   - Grant NOPASSWD sudo to `vpsupport` on g307 (or pre-install: cmake,
     CUDA toolkit, etcd, jemalloc, docker).

## Recommended next moves

**Immediately (no operator action needed):**
1. Install + build Mooncake + `transfer_engine_lat_bench` on g304 and
   g126 (`node_setup.sh` + the local-only build steps).
2. Open the firewall between g304 and g126 for the Mooncake port range.
3. Run **Stage 0a** end-to-end. Get the headline goodput number for the
   cross-DC link, decide the primary model, write
   `results/stage0/MODEL_DECISION.md`.
4. Install vLLM + Nemotron-Nano-9B-v2 on g126; run **Stage A**. Validates
   the entire vLLM + Mooncake + proxy stack on real GPUs end-to-end.

**In parallel, escalate to VP support:**
- "We need g304 and g307 un-tainted and gpu-validated so the host
  `nvidia-smi` works (currently blocked behind the GPU operator). And we
  need NOPASSWD sudo on g307."
- Alternatively: "Give us a namespace + kubectl context so we can schedule
  GPU pods on these nodes, and we'll containerize the workloads."

Once VP support comes back, **Stages B / C / D** unlock.
