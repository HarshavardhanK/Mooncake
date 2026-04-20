# M1.5 results — schema and conventions

All runs land here. `*.csv`, `*.json`, `*.log`, `*.png`, `*.md` are
gitignored (see `.gitignore`); only this README and the gitignore are
committed. Each stage gets its own directory; each stage produces a
`SUMMARY.md` with the headline numbers when complete.

## Layout

```
results/
├── stage0/
│   ├── MODEL_DECISION.md           # output of extract_lambda_max.py --decide-model
│   └── SUMMARY.md                  # per-time-of-day goodput / RTT summary
├── stageA/
│   └── <model_tag>/
│       └── <workload>/
│           ├── sweep.csv
│           ├── in-XXXXX_out-YYYY_c-ZZZ.json
│           └── in-XXXXX_out-YYYY_c-ZZZ.log
├── stageB/
│   └── <model_tag>/
│       ├── configH/<workload>/sweep.csv      # Config H baseline
│       ├── configN/<workload>/sweep.csv      # Config N (same-machine disagg)
│       ├── configP/<workload>/sweep.csv      # Config P (X1↔X2 over IB)
│       └── SUMMARY.md
├── stageC/
│   └── <model_tag>/
│       ├── lan/<workload>/sweep.csv          # tc netem profiles
│       ├── metro/<workload>/sweep.csv
│       ├── regional/<workload>/sweep.csv
│       ├── continental/<workload>/sweep.csv
│       └── SUMMARY.md
└── stageD/
    └── <model_tag>/
        ├── 0900/<workload>/sweep.csv         # time-of-day repeats
        ├── 1500/<workload>/sweep.csv
        ├── 2300/<workload>/sweep.csv
        ├── configH/<workload>/sweep.csv      # Y-only baseline
        └── SUMMARY.md                        # contains the headline ratio
```

## sweep.csv schema

Produced by `scripts/run_concurrency_sweep.sh`, one row per
`(workload, concurrency)` cell:

| column | unit | source |
|---|---|---|
| `workload`               | str   | run_concurrency_sweep.sh argument |
| `model`                  | str   | HF id |
| `input_len`              | int   | tokens |
| `output_len`             | int   | tokens |
| `concurrency`            | int   | `--max-concurrency` |
| `num_prompts`            | int   | `concurrency × NUM_FOLDS` |
| `wall_clock_iso`         | str   | UTC ISO-8601 |
| `ttft_p50_ms`            | float | benchmark_serving.py |
| `ttft_p95_ms`            | float | benchmark_serving.py |
| `ttft_p99_ms`            | float | benchmark_serving.py |
| `tpot_p50_ms`            | float | benchmark_serving.py |
| `e2el_p50_ms`            | float | benchmark_serving.py |
| `output_throughput_tok_s`| float | benchmark_serving.py |
| `slo_ms`                 | int   | TTFT P95 SLO from env |
| `slo_met`                | 0/1   | computed |

## Λ_max derivation

For each `(config, workload)`:

1. Filter rows where `slo_met == 1`.
2. Pick the row with the highest `concurrency`.
3. `Λ_max(QPS) ≈ concurrency / (e2el_p50_ms / 1000)`.
4. Headline ratio per workload is `Λ_max(configP) / Λ_max(configH)`.

`scripts/extract_lambda_max.py` does this and writes the per-stage
SUMMARY.md.

## Repro

Each `<tag>.json` next to a `<tag>.log` is the full vLLM
benchmark_serving.py invocation's structured output. To re-run a single
cell, look at the corresponding `.log`'s first line for the exact command,
or wrap it with `WORKLOAD=... CONCURRENCIES=<single conc>
run_concurrency_sweep.sh`.
