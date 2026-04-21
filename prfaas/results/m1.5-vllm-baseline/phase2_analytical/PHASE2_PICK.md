# Phase 2 pick — which hybrid for the cross-DC empirical run?

Operating point: `B_w = 14.70` Gbps (Stage 0a single-flow median), `RTT = 30` ms, `l = 16384` tokens, `o` per `--output-len`, `SLO_TTFT = 2.0` s.

## Ranking (highest predicted speedup first)

| rank | model | Λ_max(H) [req/s] | Λ_max(P) [req/s] | speedup | wire feasible | bottleneck (P) |
|---:|---|---:|---:|---:|:---:|---|
| 1 | `kimi-linear-48b` | 0.525 | 4.171 | 7.94× | ✓ | `compute_p` |
| 2 | `nemotron-nano-9b-v2` | 0.809 | 1.771 | 2.19× | ✓ | `compute_p` |
| 3 | `qwen2.5-72b-instruct` | 0.058 | 0.000 | 0.00× | ✗ | `wire` |

## Pick for Phase 3

**`kimi-linear-48b`** at `l = 16384`. Predicted `Λ_max(P) / Λ_max(H) = 7.94×` on our 14.70 Gbps wire with `SLO_TTFT = 2.0 s`.

Bottleneck of the predicted Λ_max(P) is `compute_p` (`λ_compute_p = 5.50`, `λ_wire = 13.91`, `λ_decode_p = 10.42` req/s). If Phase 3's measured Λ_max comes within ±25% of this number, the analytical model is validated for our hardware; if it's off by more, read MODEL_AND_EQUATIONS.md §6 for the failure modes we expected.


## Context-length sweep at the operating point (model = `kimi-linear-48b`)

| input_len | Λ_max(H) | Λ_max(P) | speedup | bottleneck (P) | TTFT_floor_P [s] |
|---:|---:|---:|---:|---|---:|
| 1,024 | 0.576 | 9.048 | 15.70× | `decode_p` | 0.098 |
| 2,048 | 0.574 | 9.042 | 15.76× | `decode_p` | 0.108 |
| 4,096 | 0.572 | 9.034 | 15.79× | `decode_p` | 0.121 |
| 8,192 | 0.563 | 9.009 | 16.00× | `decode_p` | 0.160 |
| 16,384 | 0.525 | 4.171 | 7.94× | `compute_p` | 0.284 |
| 32,768 | 0.453 | 1.578 | 3.49× | `compute_p` | 0.537 |
| 65,536 | 0.319 | 0.393 | 1.23× | `compute_p` | 1.065 |
| 131,072 | 0.085 | 0.000 | 0.00× | `compute_p` | 2.215 |

Peak predicted speedup for `kimi-linear-48b`: **16.00× at l = 8,192**. Phase 3's concurrency sweep should include this cell so the headline number is captured at its strongest point — not only at the paper-aligned `l = 16384` ``long_context``.

## Reproduction

```
python -m phase2.run_phase2 \
    --phi-kv-dir prfaas/results/m1.5-vllm-baseline/phase1_phi_kv \
    --out-dir   prfaas/results/m1.5-vllm-baseline/phase2_analytical \
    --measured-bw 14.70 \
    --rtt-s 0.02975 \
    --slo-s 2.0 \
    --input-len 16384
```
