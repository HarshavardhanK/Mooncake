# M1.5 preflight intake

**Stage 0 is blocked until every item below is filled in.** Reply with the
answers (or commit them as the diff to this file under
`## Answers`) and the agent will proceed.

The principle: every operational fact we need lives in this file or in
`~/.prfaas_env` (a single file, sourced by every script under
`scripts/lib/common.sh`). No magic numbers in scripts.

---

## 1. SSH access

For the agent to drive the clusters end-to-end, it needs:

- **Cluster X gateway node** (the one with the public IP):
  - Hostname or IP: `___`
  - SSH user: `___`
  - SSH key path on the agent's machine: `___`
  - Jumphost? `___` (if yes, full ProxyJump string)
  - Sudo without password? `___` (yes/no — needed for sysctl + iptables)

- **Cluster X internal node** (the one without a public IP, only IB to
  the gateway):
  - Same fields as above. Reachable via `ssh -J <gateway>` once the agent
    is on the gateway, or directly?

- **Cluster Y** (the single-node decode cluster):
  - Same fields as above.

- **Optional jumphost / bastion** (if the agent connects through one):
  - Same fields.

If you'd rather drive the clusters yourself and I just write the scripts:
say so here, and I'll structure RUNBOOK.md as "commands to copy-paste"
instead of "commands the agent runs."

## 2. Network topology

- **Cluster X gateway public IPv4** (reachable from Y): `___`
- **Cluster Y public IPv4** (reachable from X-gateway): `___`
- **Cluster X internal IB-side IPv4** of the second X node, as seen from
  the gateway: `___`
- **Cluster Y SSH IP** if different from public IP: `___`
- **Approximate RTT** between X-gateway public IP and Y public IP, if known
  (from a `ping` you've already run): `___ ms`. If unknown, the agent will
  measure it during preflight and put it here.
- **Geographic distance class** (see EXPERIMENT_PLAN §10 Q6): same metro /
  same country / trans-continental / trans-oceanic: `___`

## 3. Firewall

- **Who controls the egress firewall on cluster X side** (you, an ops team,
  a cloud provider console)? `___`
- **Who controls the ingress firewall on cluster Y side**? `___`
- **Can a single TCP port (we'll use 10001 for `mooncake_master`, 2379 for
  `etcd`, and 13000–13999 for the Mooncake transport plane) be whitelisted
  in each direction with the source IP scoped to the other cluster's
  public IP?** `___` (yes / no / "needs ticket, ETA N days")
- If "no" or "ETA > 1 day": fall back to a relay VM in a third location.
  Confirm we have the budget to spin one up: `___`

## 4. Storage and model weights

- **Cluster X VAST mount path** where model weights live (or where we can
  stage them): `___` (e.g. `/mnt/vast/models/`)
- **Cluster Y NVMe path** where model weights live (or where we can stage
  them): `___` (e.g. `/scratch/models/`)
- **Free space on each path**: `___` (Qwen3-Next-80B-A3B-Instruct ≈ 160 GB
  in BF16; Nemotron-Nano-9B-v2 ≈ 18 GB).
- **Pre-staged?** `___` (yes / no — if yes, exact paths per model)
- **HuggingFace token** if needed for any gated model (Qwen3-Next is open;
  Nemotron-Nano-v2 is open under NVIDIA open license; should not be
  required, but in case): `___` (or "use my `HF_TOKEN` env var")

## 5. GPU availability windows

- **Cluster X**: can we hold both nodes (16× H100) for: `___`
  - Half day (Stage A smoke): `___`
  - 1 day (Stage B): `___`
  - ½ day (Stage C, depends on B): `___`
  - 1–2 days, intermittent across 24h (Stage D, time-of-day variance): `___`
- **Cluster Y**: same questions. Stage A uses 8/8 GPUs, B/C use Y as idle,
  D uses Y as decode-only. Note: Stage D Config H runs on Y too, so we need
  Y for the full Stage D window.

## 6. Software baseline

- **OS / kernel** on each cluster (`uname -a` output): `___`
- **CUDA driver version** on each cluster (`nvidia-smi`): `___`
- **Python**: are there existing virtualenvs we should use, or shall we
  create fresh ones under `~/.prfaas/venv/`? `___`
- **Existing vLLM install on any node**? `___` (if yes, version)

## 7. Bandwidth budget

- Is there an MB/GB or $/GB cap on cross-DC traffic for this experiment?
  `___`
- Stage D at full concurrency on `long_context` for Qwen3-Next-80B-A3B
  could ship roughly **5–15 TB** across the matrix (back-of-envelope; see
  SIZING.md). Confirm we won't blow through someone's quota: `___`

## 8. Reporting / IRC

- **Where should results land?** A shared drive, a Slack channel, just
  committed to this repo? `___`
- **Who's the owner / reviewer** for go/no-go decisions between stages?
  `___`

---

## How the agent uses this

When you fill this in, the agent generates `~/.prfaas_env` on each node,
runs `scripts/preflight_check.sh` to verify connectivity / firewall /
storage / GPU access, then proceeds straight to Stage 0a.

### `~/.prfaas_env` schema

```bash
# Per-node identity
export PRFAAS_ROLE=x_gateway          # x_gateway | x_internal | y
export PRFAAS_NODE_INDEX=0            # 0/1 within the cluster

# Cluster X
export X_GATEWAY_PUBLIC_IP=___
export X_GATEWAY_INTERNAL_IP=___      # IB-side IP, for X1↔X2 traffic
export X_INTERNAL_PUBLIC_IP=___       # may be empty if only IB
export X_INTERNAL_INTERNAL_IP=___     # IB-side IP

# Cluster Y
export Y_PUBLIC_IP=___

# Mooncake control plane
export MOONCAKE_MASTER_HOST=$X_GATEWAY_PUBLIC_IP
export MOONCAKE_MASTER_PORT=10001
export ETCD_HOST=$X_GATEWAY_PUBLIC_IP
export ETCD_PORT=2379
export MOONCAKE_TRANSPORT_PORT_RANGE=13000-13999

# Storage
export X_MODEL_DIR=/mnt/vast/models
export Y_MODEL_DIR=/scratch/models

# Models
export SMOKE_MODEL=nvidia/NVIDIA-Nemotron-Nano-9B-v2
export PRIMARY_MODEL=Qwen/Qwen3-Next-80B-A3B-Instruct

# Workload knobs
export TTFT_SLO_LONG_CONTEXT_MS=2000
export TTFT_SLO_CHAT_BALANCED_MS=1000
export TTFT_SLO_RAG_SUMMARY_MS=1500
export TTFT_SLO_CODE_COMPLETE_MS=1500
```

This file is **never** committed (it's in `.gitignore`); each node has its
own copy with the role set appropriately.

## Answers

> Fill in below. Anything missing will be flagged by `preflight_check.sh`
> and Stage 0 will refuse to start.
