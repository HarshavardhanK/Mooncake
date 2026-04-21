#!/usr/bin/env python3
"""Phase 2 driver: regenerate the paper's Λ_max(BW, SLO) table on our hardware.

Loads Phase 1 Φkv JSONLs as (model, l, S_kv, T_prefill) inputs, joins them
with per-experiment system parameters (wire bandwidth, RTT, TP layout,
SLO), runs the analytical model in
``prfaas/m1.5-vllm-baseline/scripts/phase2/lambda_max_model.py``, and dumps:

  * ``lambda_max_predictions.csv`` — one row per (model, l, B_w, RTT, SLO,
    decode_batch_*) cell.
  * ``PAPER_FIG8_REGEN.png`` — Λ_max(P)/Λ_max(H) vs B_w, one line per
    model, vertical line at our 14.7 Gbps measured wire. Generated only if
    matplotlib is importable.

Usage::

    python -m phase2.run_phase2 \\
        --phi-kv-dir prfaas/results/m1.5-vllm-baseline/phase1_phi_kv \\
        --out-dir   prfaas/results/m1.5-vllm-baseline/phase2_analytical

All defaults below match the paper-faithful PrfaaS arm:

  * ``B_w`` sweep: 1 → 100 Gbps log-spaced (paper Fig 8 range), plus our
    measured operating point (14.7 Gbps from Stage 0a).
  * ``RTT``: 0.030 s (Stage 0a measurement: 29.75 ms ± 0.06 between g126
    and g304 over the public Internet).
  * ``SLO``: 2.0 s TTFT P95 (paper-aligned for ``long_context``).
  * ``output_len``: 256 tokens (matches the paper's ``long_context``
    workload; Stage A/B/D will use the same).
  * ``N_p = N_d = N_y = 1``: minimum cross-DC topology — one prefiller on
    g304, one decoder on g126, one collocated baseline on g126.
  * ``decode_batch_p = 32`` and ``decode_batch_h = 4``: SGLang continuous-
    batch defaults (pessimistic for H because prefill bursts block
    decode-batch progress on a collocated replica).
  * ``TPOT`` per model from public H100 benchmarks; documented below and
    in MODEL_AND_EQUATIONS.md.

Every assumption is a CLI flag so you can rerun the entire table with a
different operating point in seconds.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import sys
from dataclasses import asdict
from pathlib import Path

# Allow running both as `python -m phase2.run_phase2` and as
# `python prfaas/m1.5-vllm-baseline/scripts/phase2/run_phase2.py`.
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from lambda_max_model import (  # noqa: E402
    CellResult,
    System,
    Workload,
    evaluate,
)


# ---------------------------------------------------------------------------
# TPOT defaults (operator-supplied estimates from public H100 benchmarks).
# These should be replaced with measured numbers once Stage B/C/D run a
# real concurrency sweep. Documented in MODEL_AND_EQUATIONS.md §4.
# ---------------------------------------------------------------------------

TPOT_S_DEFAULT: dict[str, float] = {
    # Kimi-Linear-48B-A3B-Instruct: MoE 48B total, ~3B active. KDA + MLA
    # decode is memory-bandwidth-bound; published SGLang numbers on H100
    # land around 80-90 tok/s/req at batch=1, ~12 ms/token.
    "kimi-linear-48b": 0.012,
    # Nemotron-Nano-9B-v2: 9B hybrid Mamba2+attention, very fast decode
    # (~125 tok/s/req at batch=1, ~8 ms/token).
    "nemotron-nano-9b-v2": 0.008,
    # Qwen2.5-72B-Instruct (dense): TP=8 at batch=1 ~28 tok/s/req on H100,
    # ~35 ms/token.
    "qwen2.5-72b-instruct": 0.035,
}


def _logspace(lo: float, hi: float, n: int) -> list[float]:
    if n < 2:
        return [lo]
    log_lo, log_hi = math.log(lo), math.log(hi)
    step = (log_hi - log_lo) / (n - 1)
    return [math.exp(log_lo + i * step) for i in range(n)]


# ---------------------------------------------------------------------------
# Phase 1 loader
# ---------------------------------------------------------------------------


def load_phi_kv(phi_kv_dir: Path) -> dict[str, list[dict]]:
    """Load every ``*.jsonl`` under ``phi_kv_dir`` as {model_short: [rows]}.

    Skips records that have an ``error`` or ``skipped`` flag — those are
    Phase 1 cells that didn't produce a valid Φkv (model max len, network
    error, etc.).
    """
    out: dict[str, list[dict]] = {}
    for p in sorted(phi_kv_dir.glob("*.jsonl")):
        rows: list[dict] = []
        for line in p.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            if rec.get("error") or rec.get("skipped"):
                continue
            rows.append(rec)
        if rows:
            short = rows[0]["model_short"]
            out[short] = rows
    return out


# ---------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------


def build_workloads(
    phi_rows: list[dict],
    *,
    output_len: int,
    tpot_s: float,
) -> list[Workload]:
    """One Workload per Phase 1 (model, l) row."""
    out: list[Workload] = []
    for r in phi_rows:
        out.append(
            Workload(
                input_len=r["input_len"],
                output_len=output_len,
                skv_bytes=r["skv_bytes_total"],
                t_prefill_s=r["tprefill_ms"]["p50"] / 1e3,
                tpot_s=tpot_s,
            )
        )
    return out


def sweep(
    phi_data: dict[str, list[dict]],
    *,
    bw_grid_gbps: list[float],
    rtt_s: float,
    slo_s: float,
    output_len: int,
    n_p: int,
    n_d: int,
    n_y: int,
    decode_batch_p: int,
    decode_batch_h: int,
    tpot_overrides: dict[str, float] | None = None,
) -> list[CellResult]:
    rows: list[CellResult] = []
    for short, phi_rows in phi_data.items():
        tpot = (tpot_overrides or {}).get(short) or TPOT_S_DEFAULT.get(short)
        if tpot is None:
            print(
                f"[phase2] WARNING: no TPOT default for {short}; "
                f"skipping. Add it to TPOT_S_DEFAULT or pass --tpot.",
                file=sys.stderr,
            )
            continue
        workloads = build_workloads(phi_rows, output_len=output_len, tpot_s=tpot)
        for w in workloads:
            for bw in bw_grid_gbps:
                s = System(
                    b_w_gbps=bw,
                    rtt_s=rtt_s,
                    slo_ttft_s=slo_s,
                    n_p_replicas=n_p,
                    n_d_replicas=n_d,
                    n_y_replicas=n_y,
                    decode_batch_p=decode_batch_p,
                    decode_batch_h=decode_batch_h,
                )
                rows.append(evaluate(w, s, model_short=short))
    return rows


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------


def write_csv(rows: list[CellResult], out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        out_path.write_text("")
        return
    fields = list(asdict(rows[0]).keys())
    with out_path.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        for r in rows:
            d = asdict(r)
            for k, v in list(d.items()):
                if isinstance(v, float):
                    d[k] = (
                        "inf"
                        if math.isinf(v)
                        else ("nan" if math.isnan(v) else round(v, 6))
                    )
            w.writerow(d)


def maybe_plot_fig8(
    rows: list[CellResult],
    out_path: Path,
    *,
    measured_bw_gbps: float,
    fixed_input_len: int,
    fixed_slo_s: float,
    fixed_rtt_s: float,
) -> str | None:
    """Generate the paper-style Fig 8 if matplotlib is available."""
    try:
        import matplotlib  # type: ignore

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt  # type: ignore
    except ImportError:
        return None
    out_path.parent.mkdir(parents=True, exist_ok=True)

    by_model: dict[str, list[tuple[float, float]]] = {}
    for r in rows:
        if (
            r.input_len != fixed_input_len
            or abs(r.slo_ttft_s - fixed_slo_s) > 1e-9
            or abs(r.rtt_s - fixed_rtt_s) > 1e-9
        ):
            continue
        speedup = r.speedup_p_over_h
        if math.isinf(speedup) or math.isnan(speedup):
            continue
        by_model.setdefault(r.model_short, []).append((r.b_w_gbps, speedup))

    if not by_model:
        return None

    fig, ax = plt.subplots(figsize=(7.0, 4.5), dpi=130)
    for short, pts in sorted(by_model.items()):
        pts.sort()
        xs = [x for x, _ in pts]
        ys = [y for _, y in pts]
        ax.plot(xs, ys, marker="o", linewidth=1.6, markersize=4, label=short)
    ax.axvline(
        measured_bw_gbps,
        color="black",
        linestyle="--",
        linewidth=1.0,
        label=f"measured wire = {measured_bw_gbps:.1f} Gbps",
    )
    ax.axhline(1.0, color="grey", linestyle=":", linewidth=0.8)
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("Inter-DC wire bandwidth B_w (Gbps)")
    ax.set_ylabel("Λ_max(P) / Λ_max(H)")
    ax.set_title(
        f"Predicted PrfaaS speedup vs wire bandwidth\n"
        f"(l = {fixed_input_len}, SLO = {fixed_slo_s:.1f} s, "
        f"RTT = {fixed_rtt_s * 1e3:.0f} ms; from Phase 1 Φkv on g126)"
    )
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(loc="best", fontsize=8)
    fig.tight_layout()
    fig.savefig(out_path)
    plt.close(fig)
    return str(out_path)


# ---------------------------------------------------------------------------
# Pick file: which model wins on our wire?
# ---------------------------------------------------------------------------


def write_pick(
    rows: list[CellResult],
    out_path: Path,
    *,
    measured_bw_gbps: float,
    fixed_input_len: int,
    fixed_slo_s: float,
    fixed_rtt_s: float,
) -> None:
    """Distill the row at the operating point into a 'which model for Phase 3?' note."""
    op_rows = [
        r
        for r in rows
        if r.input_len == fixed_input_len
        and abs(r.slo_ttft_s - fixed_slo_s) < 1e-9
        and abs(r.rtt_s - fixed_rtt_s) < 1e-9
        and abs(r.b_w_gbps - measured_bw_gbps) < 1e-3
    ]
    op_rows.sort(key=lambda r: r.speedup_p_over_h, reverse=True)

    lines: list[str] = []
    lines.append("# Phase 2 pick — which hybrid for the cross-DC empirical run?\n")
    lines.append(
        f"Operating point: `B_w = {measured_bw_gbps:.2f}` Gbps (Stage 0a "
        f"single-flow median), `RTT = {fixed_rtt_s * 1e3:.0f}` ms, "
        f"`l = {fixed_input_len}` tokens, `o` per `--output-len`, "
        f"`SLO_TTFT = {fixed_slo_s:.1f}` s.\n"
    )
    if not op_rows:
        lines.append(
            "_No rows matched the operating point — re-run Phase 2 with "
            "`--measured-bw 14.7` and the same `--input-len`._\n"
        )
        out_path.write_text("\n".join(lines))
        return

    lines.append("## Ranking (highest predicted speedup first)\n")
    lines.append(
        "| rank | model | Λ_max(H) [req/s] | Λ_max(P) [req/s] | speedup | "
        "wire feasible | bottleneck (P) |"
    )
    lines.append(
        "|---:|---|---:|---:|---:|:---:|---|"
    )
    for i, r in enumerate(op_rows, start=1):
        feasible = "✓" if r.wire_feasible else "✗"
        speedup = (
            f"{r.speedup_p_over_h:.2f}×"
            if not math.isinf(r.speedup_p_over_h)
            else "∞"
        )
        lines.append(
            f"| {i} | `{r.model_short}` | {r.lambda_max_h_req_s:.3f} | "
            f"{r.lambda_max_p_req_s:.3f} | {speedup} | {feasible} | "
            f"`{r.lambda_capacity_p_bottleneck}` |"
        )

    pick = op_rows[0]
    lines.append("\n## Pick for Phase 3\n")
    lines.append(
        f"**`{pick.model_short}`** at `l = {pick.input_len}`. Predicted "
        f"`Λ_max(P) / Λ_max(H) = {pick.speedup_p_over_h:.2f}×` on our "
        f"{measured_bw_gbps:.2f} Gbps wire with `SLO_TTFT = {pick.slo_ttft_s:.1f} s`.\n"
    )
    lines.append(
        f"Bottleneck of the predicted Λ_max(P) is "
        f"`{pick.lambda_capacity_p_bottleneck}` "
        f"(`λ_compute_p = {pick.lambda_compute_p_req_s:.2f}`, "
        f"`λ_wire = {pick.lambda_wire_req_s:.2f}`, "
        f"`λ_decode_p = {pick.lambda_decode_p_req_s:.2f}` req/s). "
        "If Phase 3's measured Λ_max comes within ±25% of this number, "
        "the analytical model is validated for our hardware; if it's off "
        "by more, read MODEL_AND_EQUATIONS.md §6 for the failure modes "
        "we expected.\n"
    )

    # Per-model context-length sweep at the operating B_w/RTT/SLO so the
    # operator can see where the speedup peaks (it isn't always at l=16K).
    pick_short = pick.model_short
    ctx_rows = [
        r
        for r in rows
        if r.model_short == pick_short
        and abs(r.b_w_gbps - measured_bw_gbps) < 1e-3
        and abs(r.slo_ttft_s - fixed_slo_s) < 1e-9
        and abs(r.rtt_s - fixed_rtt_s) < 1e-9
    ]
    ctx_rows.sort(key=lambda r: r.input_len)
    if ctx_rows:
        lines.append("\n## Context-length sweep at the operating point "
                     f"(model = `{pick_short}`)\n")
        lines.append(
            "| input_len | Λ_max(H) | Λ_max(P) | speedup | bottleneck (P) | "
            "TTFT_floor_P [s] |"
        )
        lines.append("|---:|---:|---:|---:|---|---:|")
        for r in ctx_rows:
            speedup = (
                f"{r.speedup_p_over_h:.2f}×"
                if not math.isinf(r.speedup_p_over_h)
                else "∞"
            )
            lines.append(
                f"| {r.input_len:,} | {r.lambda_max_h_req_s:.3f} | "
                f"{r.lambda_max_p_req_s:.3f} | {speedup} | "
                f"`{r.lambda_capacity_p_bottleneck}` | "
                f"{r.ttft_floor_p_s:.3f} |"
            )
        best = max(ctx_rows, key=lambda r: r.speedup_p_over_h)
        lines.append(
            f"\nPeak predicted speedup for `{pick_short}`: "
            f"**{best.speedup_p_over_h:.2f}× at l = {best.input_len:,}**. "
            "Phase 3's concurrency sweep should include this cell so the "
            "headline number is captured at its strongest point — not only "
            f"at the paper-aligned `l = {fixed_input_len}` ``long_context``.\n"
        )
    lines.append("## Reproduction\n")
    lines.append("```")
    lines.append("python -m phase2.run_phase2 \\")
    lines.append("    --phi-kv-dir prfaas/results/m1.5-vllm-baseline/phase1_phi_kv \\")
    lines.append("    --out-dir   prfaas/results/m1.5-vllm-baseline/phase2_analytical \\")
    lines.append(f"    --measured-bw {measured_bw_gbps:.2f} \\")
    lines.append(f"    --rtt-s {fixed_rtt_s} \\")
    lines.append(f"    --slo-s {fixed_slo_s} \\")
    lines.append(f"    --input-len {fixed_input_len}")
    lines.append("```")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument(
        "--phi-kv-dir",
        type=Path,
        default=Path("prfaas/results/m1.5-vllm-baseline/phase1_phi_kv"),
    )
    ap.add_argument(
        "--out-dir",
        type=Path,
        default=Path("prfaas/results/m1.5-vllm-baseline/phase2_analytical"),
    )
    ap.add_argument("--rtt-s", type=float, default=0.02975, help="link RTT in seconds")
    ap.add_argument("--slo-s", type=float, default=2.0, help="TTFT P95 SLO in seconds")
    ap.add_argument("--measured-bw", type=float, default=14.7, help="measured wire Gbps")
    ap.add_argument(
        "--bw-grid",
        default="1,2,5,10,14.7,25,40,100",
        help="comma-separated B_w sweep (Gbps); 14.7 is auto-included.",
    )
    ap.add_argument("--input-len", type=int, default=16384, help="for the headline plot/pick")
    ap.add_argument("--output-len", type=int, default=256)
    ap.add_argument("--n-p", type=int, default=1)
    ap.add_argument("--n-d", type=int, default=1)
    ap.add_argument("--n-y", type=int, default=1)
    ap.add_argument("--decode-batch-p", type=int, default=32)
    ap.add_argument("--decode-batch-h", type=int, default=4)
    ap.add_argument(
        "--tpot",
        action="append",
        default=[],
        help="per-model TPOT override; format MODEL_SHORT=SECONDS",
    )
    args = ap.parse_args(argv)

    bw_grid = sorted(
        {float(x) for x in args.bw_grid.split(",") if x.strip()} | {args.measured_bw}
    )

    tpot_over: dict[str, float] = {}
    for kv in args.tpot:
        if "=" not in kv:
            print(f"[phase2] ignoring malformed --tpot {kv!r}", file=sys.stderr)
            continue
        k, v = kv.split("=", 1)
        tpot_over[k.strip()] = float(v)

    phi_data = load_phi_kv(args.phi_kv_dir)
    if not phi_data:
        print(f"[phase2] no JSONLs found under {args.phi_kv_dir}", file=sys.stderr)
        return 2

    print(
        f"[phase2] loaded {sum(len(v) for v in phi_data.values())} Φkv rows "
        f"across {len(phi_data)} models from {args.phi_kv_dir}"
    )

    rows = sweep(
        phi_data,
        bw_grid_gbps=bw_grid,
        rtt_s=args.rtt_s,
        slo_s=args.slo_s,
        output_len=args.output_len,
        n_p=args.n_p,
        n_d=args.n_d,
        n_y=args.n_y,
        decode_batch_p=args.decode_batch_p,
        decode_batch_h=args.decode_batch_h,
        tpot_overrides=tpot_over,
    )

    csv_path = args.out_dir / "lambda_max_predictions.csv"
    write_csv(rows, csv_path)
    print(f"[phase2] wrote {len(rows)} rows → {csv_path}")

    fig_path = args.out_dir / "PAPER_FIG8_REGEN.png"
    rendered = maybe_plot_fig8(
        rows,
        fig_path,
        measured_bw_gbps=args.measured_bw,
        fixed_input_len=args.input_len,
        fixed_slo_s=args.slo_s,
        fixed_rtt_s=args.rtt_s,
    )
    if rendered:
        print(f"[phase2] wrote plot → {rendered}")
    else:
        print("[phase2] matplotlib unavailable; skipped plot")

    pick_path = args.out_dir / "PHASE2_PICK.md"
    write_pick(
        rows,
        pick_path,
        measured_bw_gbps=args.measured_bw,
        fixed_input_len=args.input_len,
        fixed_slo_s=args.slo_s,
        fixed_rtt_s=args.rtt_s,
    )
    print(f"[phase2] wrote pick → {pick_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
