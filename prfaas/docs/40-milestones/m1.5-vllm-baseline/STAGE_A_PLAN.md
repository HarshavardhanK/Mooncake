# Stage A — single-machine 1P1D smoke on g126

**Purpose:** validate the Mooncake-vLLM v1 disaggregated-serving stack
end-to-end on Y, with the model the SIZING decision picked
(`nvidia/NVIDIA-Nemotron-Nano-9B-v2`). This is **only a smoke**: no
cross-DC traffic, no Λ_max measurement that we'd report, just "does the
plumbing work, and what's the per-token latency overhead of going through
the connector versus a single vLLM serving the same model."

If Stage A is green, we have a known-good launch sequence we can lift
verbatim into Stage D (the real cross-DC run on g126 ↔ g304).

---

## Inventory of g126 (already verified, 2026-04-20T04:48 UTC)

### Available

| Component | Status |
|---|---|
| GPUs | 8× H100 80GB **directly accessible from host** (no GPU Operator in the way — this is the K8s worker, but driver is host-side) |
| NVIDIA driver / CUDA runtime | 570.211.01 / "CUDA 12.8" reported by nvidia-smi |
| Python | 3.10.12, system-installed |
| Disk free on `/` | 387 GB (plenty for weights + HF cache) |
| RAM | (not yet read; H100 box, expect ≥ 1 TB) |
| Mooncake C++ libs | `libtransfer_engine.so` built under `~/prfaas/Mooncake/build/...` (Stage 0a artifact) |
| Public network | `enp27s0f0np0`, default route, public IP `147.185.40.126` |
| Firewall to g304 | open on 13000–17000 (Stage 0a artifact) |
| TCP host tuning | applied (256 MB rmem/wmem, but `tcp_rmem`/`tcp_wmem` still kernel default; `ip_local_port_range` and `tcp_tw_reuse` not aggressive) |

### Missing (to install for Stage A)

| Component | Source | Approx size / time |
|---|---|---|
| Python venv at `~/.prfaas/venv` | `python3 -m venv` | trivial |
| `vllm` (Python) | `pip install vllm` (latest, v1 path) | ~5 GB on disk, ~3 min |
| `mooncake-transfer-engine` (Python wheel) | `pip install mooncake-transfer-engine` | ~30 MB, ~30 s. NB: bundles its own .so; if that conflicts with our locally-built lib we fall back to building from source. |
| `huggingface_hub[cli]`, `aiohttp`, `fastapi`, `uvicorn`, `requests`, `quart`, `httpx`, `pandas`, `datasets` | `pip install` | <1 min |
| Nemotron-Nano-9B-v2 weights | `hf-cli download` to `~/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2` | **~18 GB, ~15-30 min depending on HF bandwidth** |
| `~/.prfaas_env` (role=y) | hand-written | 2 min |
| `mooncake_master`, `etcd` | **NOT NEEDED for Stage A** — vLLM v1 `MooncakeConnector` is point-to-point with a bootstrap-port handshake, no master/etcd required |

---

## Architecture

Single box, 8 GPUs, two vLLM instances:

```
                         ┌──────────────────────────┐
   client (curl/bench) ──┤  proxy (port 8000)       │
                         │  benchmarks/xypd_benchmarks/proxy_demo.py
                         └──┬─────────────┬─────────┘
                            │              │
                            ▼              ▼
       ┌───────────────────────┐   ┌───────────────────────┐
       │ prefiller (port 8010) │   │ decoder (port 8020)   │
       │ MooncakeConnector     │◀─▶│ MooncakeConnector     │
       │ kv_role=kv_producer   │KV │ kv_role=kv_consumer   │
       │ TP=4, GPUs 0-3        │tx │ TP=4, GPUs 4-7        │
       │ bootstrap port 8998   │   │                       │
       └───────────────────────┘   └───────────────────────┘
                            │              │
                            └──────┬───────┘
                                   ▼
                         loopback (127.0.0.1)
```

Why TP=4 + TP=4 (and not TP=8 on each):
- The MODEL_DECISION says we run **2 prefill replicas × TP=4** in
  production (Stage D). Stage A should test *that* topology, not a
  topology we'll never run.
- Each H100 80GB has more than enough headroom for a 9 B model at TP=4
  (each rank holds ~5 GB of weights, ~50 GB free for KV).

Why MooncakeConnector (v1) and not MooncakeStoreConnector (v0):
- vLLM ≥ 0.16 has v1 by default; v1's MooncakeConnector is what's
  documented and supported going forward.
- v1 is **stateless wrt master/etcd** — the bootstrap is a port the
  prefiller listens on; the decoder's kv_consumer connects directly. This
  cuts two services out of the deployment for Stage A.
- v1 is the path that lets us run Stage D over public Internet without an
  etcd cluster spanning two DCs.

---

## Bring-up sequence

All on g126 as `ubuntu`. Each step has a verifier; halt if a verifier fails.

### 0. Write `~/.prfaas_env` (role=y)

```bash
cat > ~/.prfaas_env <<'EOF'
# Stage A on g126 — single-node smoke for the Nemotron-Nano-9B-v2 path.
export PRFAAS_ROLE="y"
export PRFAAS_NODE_INDEX=0

# Network — only Y_PUBLIC_IP matters for Stage A; the others are placeholders
# we'll fill in once we touch Stage D.
export Y_PUBLIC_IP="147.185.40.126"
export X_GATEWAY_PUBLIC_IP="159.26.81.50"
export X_GATEWAY_INTERNAL_IP=""
export X_INTERNAL_PUBLIC_IP="159.26.81.53"
export X_INTERNAL_INTERNAL_IP=""

# Mooncake — these get used in Stage D, not Stage A.
export MOONCAKE_TRANSPORT_PORT_RANGE="13000-13999"

# Models
export Y_MODEL_DIR="${HOME}/models"
export X_MODEL_DIR="/mnt/vast/models"
export SMOKE_MODEL="nvidia/NVIDIA-Nemotron-Nano-9B-v2"
export PRIMARY_MODEL="nvidia/NVIDIA-Nemotron-Nano-9B-v2"   # decided by Stage 0a

# vLLM
export VLLM_USE_V1=1
export VLLM_LOGGING_LEVEL=INFO

# SLOs (paper-aligned)
export TTFT_SLO_LONG_CONTEXT_MS=2000
export TTFT_SLO_CHAT_BALANCED_MS=1000
export TTFT_SLO_RAG_SUMMARY_MS=1500
export TTFT_SLO_CODE_COMPLETE_MS=1500
EOF
```

**Verifier:** `source ~/.prfaas_env && env | grep -E "^(PRFAAS|Y_|X_|MC_|MOONCAKE_|SMOKE_|PRIMARY_|TTFT_|VLLM_)"` shows all of the above.

### 1. Create venv and install Python deps

```bash
python3 -m venv ~/.prfaas/venv
source ~/.prfaas/venv/bin/activate
pip install --upgrade pip
pip install vllm                              # latest stable, v1 path
pip install mooncake-transfer-engine          # MooncakeConnector wheel
pip install "huggingface_hub[cli]" aiohttp fastapi uvicorn requests \
            quart httpx pandas datasets matplotlib
```

**Verifier (~3 min total):**

```bash
python -c "import vllm; print('vllm', vllm.__version__)"   # expect ≥ 0.16.0
python -c "from mooncake.engine import TransferEngine; print('mooncake OK')"
python -c "import torch; print('torch', torch.__version__, 'cuda?', torch.cuda.is_available(), 'devs', torch.cuda.device_count())"
# expect cuda? True, devs 8
```

### 2. Pre-flight GPU sanity

```bash
nvidia-smi --query-gpu=index,name,memory.free,memory.total --format=csv
```

**Verifier:** 8 H100s reported, ≥ 75 GB free per GPU.

### 3. Stage Nemotron-Nano-9B-v2 weights

```bash
mkdir -p ~/models
HF_HUB_DOWNLOAD_TIMEOUT=300 \
  huggingface-cli download nvidia/NVIDIA-Nemotron-Nano-9B-v2 \
    --local-dir ~/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2 \
    --max-workers 8
```

**Verifier (~15-30 min):**
- `ls ~/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2 | grep safetensors` returns ≥ 1 shard.
- `du -sh ~/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2` reports ~18 GB.
- `python -c "from transformers import AutoConfig; c = AutoConfig.from_pretrained('$HOME/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2', trust_remote_code=True); print(c.model_type, c.num_hidden_layers)"` succeeds.

### 4. Vanilla vLLM smoke (NO connector)

Confirm the model itself loads and serves before we add the connector.

```bash
CUDA_VISIBLE_DEVICES=0,1,2,3 \
~/.prfaas/venv/bin/vllm serve ~/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2 \
  --served-model-name nemotron-nano-9b-v2 \
  --port 8000 \
  --tensor-parallel-size 4 \
  --max-model-len 32768 \
  --gpu-memory-utilization 0.85 \
  --trust-remote-code \
  > ~/.prfaas/logs/vllm_smoke.log 2>&1 &

# wait for /v1/models, then:
curl -sf http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"nemotron-nano-9b-v2",
       "messages":[{"role":"user","content":"What is 2+2?"}],
       "max_tokens":16}'
```

**Verifier (~2-3 min model load):**
- HTTP 200 on `/v1/models`.
- chat completion returns a sensible token (`"4"` or close).
- `nvidia-smi` shows ~5 GB allocated per GPU 0-3.

If this fails, the issue is vLLM/Nemotron compatibility — fix that before
even thinking about the connector. Then kill this process.

### 5. 1P1D bring-up via the existing scripts

```bash
# ensure ~/.prfaas_env is sourced
source ~/.prfaas_env
cd ~/prfaas/Mooncake

# render the localhost mooncake config (no-op for v1 connector but the
# scripts expect the path to exist)
bash prfaas/m1.5-vllm-baseline/scripts/render_config.sh \
  --template prfaas/m1.5-vllm-baseline/configs/mooncake.localhost.json.template \
  --out /tmp/mooncake-stageA.json

# DO NOT call start_master.sh — v1 connector is master-less.

# Prefiller on GPUs 0-3, port 8010
MOONCAKE_CONFIG_PATH=/tmp/mooncake-stageA.json \
MODEL=$HOME/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2 \
TP=4 ROLE=kv_producer PORT=8010 GPU_IDS=0,1,2,3 \
VLLM_MOONCAKE_BOOTSTRAP_PORT=8998 \
  bash prfaas/m1.5-vllm-baseline/scripts/start_prefiller.sh

# Decoder on GPUs 4-7, port 8020
MOONCAKE_CONFIG_PATH=/tmp/mooncake-stageA.json \
MODEL=$HOME/models/nvidia_NVIDIA-Nemotron-Nano-9B-v2 \
TP=4 ROLE=kv_consumer PORT=8020 GPU_IDS=4,5,6,7 \
  bash prfaas/m1.5-vllm-baseline/scripts/start_decoder.sh

# Round-robin proxy on port 8000
MODEL=nemotron-nano-9b-v2 \
PREFILL=localhost:8010 DECODE=localhost:8020 PROXY_PORT=8000 \
  bash prfaas/m1.5-vllm-baseline/scripts/start_proxy.sh
```

**Verifier (~3-5 min):**
- All three pidfiles exist under `~/.prfaas/pids/`.
- `curl -sf http://localhost:8010/v1/models` and `:8020/v1/models` and
  `:8000/status` all return 200.
- `nvidia-smi` shows ~5 GB per GPU on all 8 GPUs.

### 6. End-to-end smoke through the proxy

```bash
curl -sf http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"nemotron-nano-9b-v2",
       "messages":[{"role":"user","content":"Tell me a 200-word story about an LLM serving over a WAN."}],
       "max_tokens":300,
       "temperature":0.0}' | jq .
```

**Verifier:**
- Returns a 200-word-ish completion.
- `~/.prfaas/logs/prefiller_8010.log` shows a Mooncake KV-transfer event
  (search for `MooncakeConnector` or `kv` in the log).
- `~/.prfaas/logs/decoder_8020.log` shows the decoder picked up the KV
  cache and continued generation (NOT a fresh prefill).

### 7. One concurrency cell (informational; not Λ_max yet)

```bash
WORKLOAD=chat_balanced \
CONCURRENCIES=16 \
NUM_FOLDS=10 \
PROXY_PORT=8000 \
MODEL=nemotron-nano-9b-v2 \
RESULTS_DIR=~/prfaas/results/stageA \
  bash prfaas/m1.5-vllm-baseline/scripts/run_concurrency_sweep.sh
```

**Verifier:** CSV row written under `results/stageA/`, p95 TTFT < 5 s, no
errors. We don't compute Λ_max here — that's Stage B+ on real H/N/P
configurations.

### 8. Tear down

```bash
bash prfaas/m1.5-vllm-baseline/scripts/stop_all.sh
```

**Verifier:** `nvidia-smi` shows 0 MB used per GPU within 30 seconds.

---

## What can go wrong (known risks)

1. **`mooncake-transfer-engine` wheel ABI mismatch with our libs.**
   The pip wheel ships its own `libtransfer_engine.so`. If `import` works,
   leave it alone. If it fails on `lib*.so` not found, fall back to the
   path documented in `vllm-integration-v1.0.md` §Installation note:
   `pip uninstall mooncake-transfer-engine` and rely on our locally-built
   `libtransfer_engine.so` via `LD_LIBRARY_PATH`. We have that lib (Stage 0a built it).

2. **Nemotron-Nano-9B-v2 needs a vLLM version with Mamba2 hybrid support.**
   vLLM ≥ 0.7 has it. Latest stable is well past that. If not, pin a known
   version. We confirm in step 4 (vanilla vLLM smoke) before going further.

3. **`start_proxy.sh` calls `proxy_demo.py` not the upstream toy_proxy.**
   `proxy_demo.py` exists in `benchmarks/xypd_benchmarks/` and is
   xPyD-aware (round-robin across multiple prefillers). For 1P1D it's fine.

4. **Prefiller bootstrap port collision.** `VLLM_MOONCAKE_BOOTSTRAP_PORT=8998`
   is set. If our existing firewall rules for 13000-17000 happen to NOT
   include 8998, the loopback path doesn't care (no firewall on lo).
   For Stage D we'd add it.

5. **Disk: 18 GB weights + ~10 GB pip wheels + ~5 GB CUDA libs.**
   Total ~35 GB. We have 387 GB free. Fine.

6. **`MOONCAKE_CONFIG_PATH` shape.** v1 connector may not even read it; the
   v0 path expects RDMA device, NIC priority matrix, etc. Render it
   anyway from the template (the scripts expect the file to exist) but if
   the connector ignores it, that's a benign no-op.

---

## What this gives us

| If Stage A is green | If Stage A fails |
|---|---|
| Known-good launch sequence we lift into Stage D unchanged. | We've found a stack issue early, on a single box, with full visibility into all logs. |
| One free TTFT/throughput data point at concurrency 16, 1P1D, loopback. | Likely a pip-version pin, a Mamba2 vLLM gap, or a connector wheel issue — all fixable in tens of minutes. |
| Confidence the connector codepath is exercised end-to-end. | We do NOT proceed to Stage D blind. |

---

## Time budget

| Step | Wall clock |
|---|---|
| 0. Write env | 1 min |
| 1. venv + pip | 5 min |
| 2. GPU pre-flight | 30 s |
| 3. Weight download | **15-30 min** (the long pole) |
| 4. Vanilla vLLM smoke | 5 min (load + curl + kill) |
| 5. 1P1D bring-up | 5-10 min (two model loads in sequence) |
| 6. E2E curl | 30 s |
| 7. One concurrency cell | 3-5 min |
| 8. Teardown | 30 s |
| **Total** | **35-60 min** |

Most of that is steps 3-5 (weight download + two model loads).
