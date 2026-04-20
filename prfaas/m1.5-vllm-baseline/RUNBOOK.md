# M1.5 RUNBOOK — exact commands per stage

Every command is parameterized by `~/.prfaas_env` (see PREFLIGHT.md). Source
it before running anything: `source ~/.prfaas_env`.

Convention: where you see `${X_GATEWAY_PUBLIC_IP}`, that's literal — the
script will resolve it from your env. Where you see `<...>` in angle
brackets, that's a value the agent fills in at runtime from a previous
step's output.

---

## Stage 0 — Characterize the X↔Y wire

### Stage 0a: raw TCP across the public-internet path

**Where:** X-gateway and Y, both as `root` (or sudo).

**Pre-req:** `node_setup.sh` has been run on both nodes (installs Mooncake
build prereqs, builds `transfer_engine_lat_bench`, raises host TCP buffers
via `host_tune.sh`).

**Commands** (the wrapper handles host_tune + firewall + run_target/run_matrix
based on `PRFAAS_ROLE`):

```bash
# On X-gateway (target side, leave running):
sudo bash prfaas/m1.5-vllm-baseline/scripts/run_stage_0a.sh
# It prints the RPC port chosen by run_target.sh — capture it.

# On Y (initiator), repeat at 09:00, 15:00, 23:00 local (≥3 cells for
# time-of-day variance):
TARGET_RPC_PORT=<from above> \
  bash prfaas/m1.5-vllm-baseline/scripts/run_stage_0a.sh
```

**Output:** three CSVs under
`prfaas/m1-tcp-bench/results/cross_dc_xy/<timestamp>/results.csv`. Each row
is one cell of the M1 matrix (slice × threads × conn-pool).

**Decide model:**

```bash
python3 prfaas/m1.5-vllm-baseline/scripts/extract_lambda_max.py \
  --decide-model \
  --stage0-results prfaas/m1-tcp-bench/results/cross_dc_xy/ \
  --out prfaas/m1.5-vllm-baseline/results/stage0/MODEL_DECISION.md
```

**Go/no-go:**
- ≥ 25 Gbps median multi-flow goodput → primary = Qwen3-Next-80B-A3B.
- 10–25 Gbps → primary = Nemotron-Nano-9B-v2 with 2 prefill replicas.
- < 10 Gbps → still proceed with Nemotron-Nano, document as
  low-bandwidth-WAN study.

### Stage 0b: WireGuard ablation (one-off, 30 min)

```bash
# Both sides — wrapper sets up WireGuard, then runs ONE matrix cell across
# the tunnel:
sudo bash prfaas/m1.5-vllm-baseline/scripts/run_stage_0b.sh   # x_gateway side: target

TARGET_RPC_PORT=<from above> \
  bash prfaas/m1.5-vllm-baseline/scripts/run_stage_0b.sh      # y side: initiator
```

Compare to the same cell from Stage 0a. The delta is the WireGuard tax. If
< 10%, we could move M1.5 onto WG; if ≥ 30%, the firewall-whitelist
benchmark path stays.

---

## Stage A — Single-machine 1P1D smoke (cluster Y only)

**Where:** Y, all 8 GPUs.

```bash
# Source env on Y:
source ~/.prfaas_env

# One-off setup:
bash prfaas/m1.5-vllm-baseline/scripts/node_setup.sh smoke
# This installs vLLM + downloads NVIDIA-Nemotron-Nano-9B-v2 to $Y_MODEL_DIR.

# Render mooncake.json for localhost:
bash prfaas/m1.5-vllm-baseline/scripts/render_config.sh \
  --template configs/mooncake.localhost.json.template \
  --out /tmp/mooncake.json

# Bring up master + etcd:
bash prfaas/m1.5-vllm-baseline/scripts/start_master.sh

# Bring up a 4-GPU prefiller (kv_producer, GPUs 0-3) and a 4-GPU decoder
# (kv_consumer, GPUs 4-7), both on localhost:
MOONCAKE_CONFIG_PATH=/tmp/mooncake.json \
MODEL=$SMOKE_MODEL TP=4 ROLE=kv_producer PORT=8100 GPU_IDS=0,1,2,3 \
  bash prfaas/m1.5-vllm-baseline/scripts/start_prefiller.sh

MOONCAKE_CONFIG_PATH=/tmp/mooncake.json \
MODEL=$SMOKE_MODEL TP=4 ROLE=kv_consumer PORT=8200 GPU_IDS=4,5,6,7 \
  bash prfaas/m1.5-vllm-baseline/scripts/start_decoder.sh

# Wait for both to be ready, then proxy:
PREFILL=localhost:8100 DECODE=localhost:8200 PROXY_PORT=8000 \
  bash prfaas/m1.5-vllm-baseline/scripts/start_proxy.sh

# Smoke curl:
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"'$SMOKE_MODEL'","messages":[{"role":"user","content":"What is 2+2?"}],"max_tokens":32}'
```

**Done when:** the curl returns sensible text and both vLLM logs show KV
transfer messages.

**Run one benchmark cell to validate the full path:**

```bash
WORKLOAD=chat_balanced CONCURRENCY=16 \
RESULTS_DIR=prfaas/m1.5-vllm-baseline/results/stageA \
  bash prfaas/m1.5-vllm-baseline/scripts/run_concurrency_sweep.sh \
    --proxy-port 8000 --model $SMOKE_MODEL
```

**Cleanup:**

```bash
bash prfaas/m1.5-vllm-baseline/scripts/stop_all.sh
```

---

## Stage B — Disagg over IB-as-TCP, three-config Λ_max sweep

**Where:** cluster X (X1 + X2). Roles: X1 = prefiller, X2 = decoder + proxy
+ master.

**Pre-req:** Stage A green; `node_setup.sh primary` ran on both X nodes;
the model chosen by Stage 0 is staged on `$X_MODEL_DIR`; passwordless ssh
from X2 → X1 works.

Run each config separately on X2 (the wrapper ssh's into X1 for the
prefiller / Config H decoder side):

```bash
source ~/.prfaas_env

CONFIG=H bash prfaas/m1.5-vllm-baseline/scripts/run_stage_b.sh
CONFIG=N bash prfaas/m1.5-vllm-baseline/scripts/run_stage_b.sh
CONFIG=P bash prfaas/m1.5-vllm-baseline/scripts/run_stage_b.sh
# Each writes to results/stageB/<MODEL_TAG>/config{H,N,P}/ and refreshes
# results/stageB/<MODEL_TAG>/SUMMARY.md.
```

**Done when** `Λ_max(P)/Λ_max(H) ≥ 0.9` on `long_context` AND `Λ_max(P) >
Λ_max(N)`.

---

## Stage C — Stage B + emulated WAN profiles

**Where:** same as Stage B. We layer `tc netem` on the IB-bonded Ethernet
interface (or a veth pair). Bring up Config P first (`CONFIG=P bash
run_stage_b.sh`), leave it running, then:

```bash
# Identify the iface Mooncake actually uses for X1↔X2 traffic.
# Usually whatever `mooncake.x_internal.json.template` resolves to.
ip -br a | grep ib   # or: bond0 / eth0 — whichever your IB-bonded ether is

IB_IFACE=bond0 \
  bash prfaas/m1.5-vllm-baseline/scripts/run_stage_c.sh
# Wrapper iterates WAN_PROFILES (default: metro regional continental),
# applies tc netem on both sides, re-runs the Config P sweep per profile,
# and clears netem on exit. SUMMARY.md is written under
# results/stageC/<MODEL_TAG>/.
```

---

## Stage D — Real cross-DC

**Where:** X-gateway (prefiller, master, etcd) + Y (decoder, proxy).

```bash
# X-gateway: stand up master + prefiller (leave running):
source ~/.prfaas_env
sudo bash prfaas/m1.5-vllm-baseline/scripts/run_stage_d.sh
# (defaults to CONFIG=P; idempotent — starts firewall + master + prefiller.)

# Y: stand up decoder + proxy and drive the bench. Repeat at 09:00, 15:00,
# 23:00 local for time-of-day variance. Each run lands under a $(date +%H00)
# subdirectory:
source ~/.prfaas_env
sudo bash prfaas/m1.5-vllm-baseline/scripts/run_stage_d.sh

# After all P runs, take down the cross-DC stack and run Config H on Y:
bash prfaas/m1.5-vllm-baseline/scripts/stop_all.sh
CONFIG=H bash prfaas/m1.5-vllm-baseline/scripts/run_stage_d.sh
# (Tear down x_gateway side too: bash stop_all.sh on x_gateway.)
```

The `y` side wrapper writes `results/stageD/<MODEL_TAG>/SUMMARY.md` after
each run with the headline ratio `Λ_max(P_realWAN) / Λ_max(H_onY)`.

**Done when** SUMMARY.md has the headline ratio `Λ_max(P_realWAN) /
Λ_max(H_onY)` per workload, with median across the three time-of-day
repeats and min/max as error bars.

---

## Quick reference: which script does what

| When you want to… | Run |
|---|---|
| Validate a new node before any stage | `scripts/preflight_check.sh` |
| Install vLLM + build Mooncake + stage a model | `scripts/node_setup.sh {smoke,primary}` |
| Open the firewall ports for a stage | `sudo scripts/firewall_setup.sh {stage0,stageD}` (idempotent) |
| Stand up the WireGuard tunnel (Stage 0b only) | `sudo scripts/wireguard_setup.sh` |
| Start mooncake_master + etcd | `scripts/start_master.sh` |
| Start a vLLM prefiller / decoder | `scripts/start_{prefiller,decoder}.sh` |
| Start the round-robin proxy | `scripts/start_proxy.sh` |
| Tear everything down | `scripts/stop_all.sh` |
| Run one workload, sweep concurrency to Λ_max | `scripts/run_concurrency_sweep.sh` |
| Walk a results dir and emit Λ_max table + plots | `scripts/extract_lambda_max.py` |
| Run the paper-style mixed-length workload | `scripts/run_mixed_trace.sh` |
| Stage 0a: characterize the X↔Y wire | `scripts/run_stage_0a.sh` (role-aware) |
| Stage 0b: WireGuard ablation | `scripts/run_stage_0b.sh` (role-aware) |
| Stage A: localhost 1P1D smoke | `scripts/run_stage_a.sh` |
| Stage B: IB-as-TCP three-config sweep | `CONFIG={H,N,P} scripts/run_stage_b.sh` |
| Stage C: Stage B + tc netem WAN profiles | `IB_IFACE=… scripts/run_stage_c.sh` |
| Stage D: real cross-DC | `scripts/run_stage_d.sh` (role-aware; CONFIG=H on Y for baseline) |
