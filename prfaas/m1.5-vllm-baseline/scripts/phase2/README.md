# Phase 2 — analytical Λ_max regenerator

Pure Python; no GPUs, no clusters. Loads Phase 1 Φkv JSONLs from
`prfaas/results/m1.5-vllm-baseline/phase1_phi_kv/`, applies the paper's
Eq 3-8 (see
[`MODEL_AND_EQUATIONS.md`](../../../results/m1.5-vllm-baseline/phase2_analytical/MODEL_AND_EQUATIONS.md)),
and writes:

- `lambda_max_predictions.csv` — one row per (model, l, B_w, RTT, SLO,
  decode_batch_*) cell.
- `PAPER_FIG8_REGEN.png` — paper-style speedup-vs-bandwidth plot.
- `PHASE2_PICK.md` — narrative "which hybrid for Phase 3?" pick.

## Run

```bash
# default operating point: B_w=14.7 Gbps, RTT=29.75 ms, SLO=2 s, l=16384, o=256
python prfaas/m1.5-vllm-baseline/scripts/phase2/run_phase2.py
```

## Files

| file | purpose |
|---|---|
| `lambda_max_model.py` | Pure analytical functions (no I/O). Each function maps to a numbered equation in MODEL_AND_EQUATIONS.md. |
| `run_phase2.py` | CLI driver: load JSONLs → sweep grid → write outputs. |
| `__init__.py` | Package marker. |

## Sensitivity

Re-run with different operating points to explore sensitivity (see
MODEL_AND_EQUATIONS.md §7 for examples).

## Dependencies

- Python 3.10+ (stdlib only for the model)
- `matplotlib` (optional, for PAPER_FIG8_REGEN.png; the CSV + pick are
  generated regardless)

## What this is not

- Not a per-request simulator. The M/M/1 P95 approximation is intentional
  — the paper's headline number is closed-form, not Monte Carlo.
- Not a load tester. Phase 3 is the empirical run.
