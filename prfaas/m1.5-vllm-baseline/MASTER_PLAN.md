# M1.5 master execution plan — real-cluster kickoff

**Branch:** `feat/prfaas-m1.5-vllm-baseline` (PR #4, draft)
**Owner:** agentic, driven from Cursor with Opus 4.7 as the parent.

This is the live operational plan. Every step has a verifier and a known
output artifact. No step proceeds until the previous step's verifier is
green.

## Cluster inventory (provided by operator)

| Role tag        | Hostname | Public IP        | SSH                          | Cluster | GPUs (declared) |
|-----------------|----------|------------------|------------------------------|---------|-----------------|
| `x_gateway`     | g304     | 159.26.81.50     | `sshv vpsupport@<ip>`        | X       | 8× H100         |
| `x_internal`    | g307     | 159.26.81.53     | `sshv vpsupport@<ip>`        | X       | 8× H100         |
| `y`             | g126     | 147.185.40.126   | `ssh ubuntu@<ip>`            | Y       | 8× H100         |

Both X-nodes have public IPs, so the role split is by convention (g304 will
host `mooncake_master` for cross-DC traffic; g307 sits on the IB side).

## Phases

### Phase 0 — Discovery (parallel, ~10 min, no writes to nodes)
Three subagents, one per node. Each captures:
- SSH reachability + sudo capability
- OS / kernel / CPU / memory
- GPU inventory (`nvidia-smi`, count, memory, driver, CUDA)
- IB topology (`ibstat`, `rdma link`, IB iface name and IP)
- Network: all IPs (`ip -br a`), public-route iface, listening ports on the
  Mooncake range
- Storage: candidate model dirs and free space (VAST mount on X, NVMe on Y)
- Software baseline: python3, pip, gcc, cmake, etcd, docker, existing vLLM,
  existing Mooncake build
- Outbound TCP reachability check to the other cluster's public IP on
  ports 80, 443, 13000 (one of these is enough to know the egress isn't
  totally locked down)
- Writes a JSON report to `discovery/<host>.json` and a free-form
  `discovery/<host>.log`

**Verifier:** all 3 reports exist and contain at least: `gpu_count >= 8`,
`ib_iface != null`, `outbound_tcp_to_peer == "ok"` for at least the
gateway↔Y direction.

### Phase 1 — Cross-DC connectivity baseline (sequential, ~5 min)
From Y, against g304 public IP:
- `ping -c 30` → median + jitter
- `iperf3 -t 30` (single + 4-stream) → goodput
- `traceroute -T -p 443` → path

Same from g304 against Y. Captures whether the path is actually open and
how fast it is, **before** we install anything.

**Verifier:** both directions show TCP reachability on at least one high
port. Median goodput ≥ 100 Mbps (anything less and we have a story to tell
about the link before going further).

If TCP on high ports is blocked end-to-end, we stop here and surface the
firewall question to the operator.

### Phase 2 — Provisioning (parallel per node, ~30–60 min)
- Generate `~/.prfaas_env` per node from the discovery report.
- Run `prfaas/m1.5-vllm-baseline/scripts/node_setup.sh` per node
  (build Mooncake + bench, create venv, install vLLM matching CUDA,
  apply host TCP tuning).
- Stage models:
  - Y: `nvidia/NVIDIA-Nemotron-Nano-9B-v2` to `$Y_MODEL_DIR` (~18 GB).
  - X (both nodes via VAST): defer until Stage 0a tells us the primary
    model. Pre-stage Nemotron on X too as fallback.
- Run `preflight_check.sh` per node.

**Verifier:** `preflight_check.sh` exits 0 on all three nodes.

### Phase 3 — Stage 0a: characterize the wire (~30 min × 3 time-of-day)
- Open firewall on X (ports 13000–17000) scoped to Y_PUBLIC_IP.
  Same on Y for X_GATEWAY_PUBLIC_IP. Idempotent via `firewall_setup.sh`.
- Run `transfer_engine_lat_bench` matrix between g304 (target) and g126
  (initiator). Drives `run_stage_0a.sh`.
- Run at three points spread across the day for time-of-day variance.

**Verifier:** `extract_lambda_max.py --decide-model` writes
`results/stage0/MODEL_DECISION.md`. Decision tree → primary model.

#### Phase 3 status — DONE for window 1 (2026-04-20T04:36 UTC)

- See `results/stage0a/SUMMARY.md` and `results/stage0a/MODEL_DECISION.md`.
- **Wire ceiling:** 14.7 Gbps median sustained (best 16.2 Gbps, worst-case
  no-pool 3.6 Gbps). RTT 29.75 ms. g126 (DFW) ↔ g304 (IAD), public Internet.
- **Primary model decided:** `nvidia/NVIDIA-Nemotron-Nano-9B-v2`,
  2 prefill replicas × TP=4. Fits the ≥10 Gbps branch of SIZING.md §4 with
  ~50% headroom per replica.
- **Mandatory transport knob:** `MC_TCP_ENABLE_CONNECTION_POOL=1`
  (turning it off collapses goodput 4×).
- **Still open:** two more time-of-day windows (peak-US, EU-business)
  before the 14.7 Gbps median is "the median" rather than "Sunday night".
  Tracked as Stage 0a-bis.

### Phase 4 — Stage A: localhost smoke on Y (~1–2 h)
Validates Mooncake master + vLLM kv-transfer + proxy on a single box,
1P1D over loopback, with the smoke model. No cross-DC traffic.

**Verifier:** smoke curl returns sensible chat output + bench cell completes
+ both vLLM logs show KV transfer events.

### Phase 5 — Stage B: IB-as-TCP three-config sweep (~6 h)
Three runs on cluster X (g304 + g307):
- `CONFIG=H` — TP=8 vLLM on g307 alone, no Mooncake (homogeneous baseline).
- `CONFIG=N` — 4P+4D on g307 alone, Mooncake over loopback (naive het).
- `CONFIG=P` — g307 prefill (TP=8), g304 decode (TP=8), Mooncake over IB.

**Verifier:** `results/stageB/<model>/SUMMARY.md` shows
`Λ_max(P)/Λ_max(H) ≥ 0.9` on `long_context` AND `Λ_max(P) > Λ_max(N)`.

### Phase 6 — Stage C: emulated WAN profiles on B's setup (~4 h)
`tc netem` on the IB-bonded ether iface, three profiles: metro / regional /
continental.

**Verifier:** `results/stageC/<model>/SUMMARY.md` shows the breakeven RTT.

### Phase 7 — Stage D: real cross-DC (~1.5 days, time-of-day repeats)
g304 = prefiller, g126 = decoder. Three runs spread across a day.
Plus a Config H run on g126 alone for the headline ratio.

**Verifier:** `results/stageD/<model>/SUMMARY.md` shows the
`Λ_max(P_realWAN) / Λ_max(H_onY)` ratio with median+min+max across the
three runs.

## Artifacts produced

```
prfaas/m1.5-vllm-baseline/
  discovery/                  # phase 0
    g304.json  g307.json  g126.json
    cross_dc_baseline.md     # phase 1
  PREFLIGHT_AUTOFILL.md       # values agent will write into ~/.prfaas_env
  results/
    stage0/MODEL_DECISION.md  # phase 3
    stageA/...                # phase 4
    stageB/.../SUMMARY.md     # phase 5  ← clean-network proof
    stageC/.../SUMMARY.md     # phase 6
    stageD/.../SUMMARY.md     # phase 7  ← headline number
```

## Halting conditions

The agent stops and surfaces a question to the operator if:
- Any node fails Phase 0 SSH or doesn't have ≥ 8 H100s as expected.
- Phase 1 cross-DC TCP is blocked on all high ports (firewall too tight).
- Phase 1 goodput is < 1 Gbps median (interesting story but warrants
  operator confirmation before burning a day on Stage 0a).
- `preflight_check.sh` fails on any node and the cause isn't trivially
  fixable (e.g., missing sudo).
- Any verifier doesn't go green within the time budget.
