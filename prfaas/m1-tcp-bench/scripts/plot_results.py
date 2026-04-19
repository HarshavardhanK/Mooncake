#!/usr/bin/env python3
"""Plot M1 results from one or more matrix CSVs.

Usage:
    plot_results.py results/regional.csv [results/metro.csv ...]

Produces, alongside each input CSV:
    <stem>.throughput_by_threads.png   goodput vs threads, faceted by block_size
    <stem>.connpool_effect.png         goodput delta from MC_TCP_ENABLE_CONNECTION_POOL
    <stem>.summary.md                  one-paragraph summary suitable for REPORT.md

Intentionally minimal: the goal is fast, deterministic outputs we can commit
alongside the CSVs to make regressions visible across Mooncake versions.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt


def load(csv_path: Path) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    for col in ("goodput_gbps", "block_size", "threads", "slice_size",
                "conn_pool", "roundrobin", "rtt_ms", "loss_pct", "bw_mbit",
                "p50_us", "p95_us", "p99_us"):
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")
    df = df[df["bench_exit_code"] == 0]
    return df


def plot_throughput_by_threads(df: pd.DataFrame, out: Path) -> None:
    block_sizes = sorted(df["block_size"].dropna().unique())
    fig, axes = plt.subplots(1, len(block_sizes), figsize=(5 * len(block_sizes), 4),
                             sharey=True, squeeze=False)
    for ax, bs in zip(axes[0], block_sizes):
        sub = df[df["block_size"] == bs]
        # For each (slice_size, conn_pool) configuration, plot mean over reps.
        for (ss, cp), grp in sub.groupby(["slice_size", "conn_pool"]):
            agg = grp.groupby("threads")["goodput_gbps"].mean().sort_index()
            label = f"slice={int(ss)} pool={int(cp)}"
            ax.plot(agg.index, agg.values, marker="o", label=label)
        ax.set_title(f"block_size = {int(bs)} B")
        ax.set_xlabel("threads")
        ax.set_xscale("log", base=2)
        ax.grid(True, alpha=0.3)
    axes[0][0].set_ylabel("goodput (Gbps)")
    axes[0][-1].legend(loc="best", fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


def plot_connpool_effect(df: pd.DataFrame, out: Path) -> None:
    # Pair (conn_pool=0, conn_pool=1) rows by everything else and show delta.
    keys = ["op", "block_size", "threads", "slice_size", "roundrobin"]
    pivot = df.pivot_table(index=keys, columns="conn_pool",
                           values="goodput_gbps", aggfunc="mean").dropna()
    if 0 not in pivot.columns or 1 not in pivot.columns:
        return
    delta = (pivot[1] - pivot[0]).rename("delta_gbps").reset_index()
    fig, ax = plt.subplots(figsize=(8, 4))
    ax.scatter(delta.index, delta["delta_gbps"], alpha=0.6)
    ax.axhline(0, color="k", lw=0.5)
    ax.set_xlabel("matrix cell index (each = unique op/bs/th/slice/rr)")
    ax.set_ylabel("Δ goodput (pool=1 − pool=0), Gbps")
    ax.set_title("Effect of MC_TCP_ENABLE_CONNECTION_POOL")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


def plot_latency_vs_throughput(df: pd.DataFrame, out: Path) -> None:
    if "p99_us" not in df.columns or df["p99_us"].dropna().empty:
        return
    fig, ax = plt.subplots(figsize=(7, 5))
    block_sizes = sorted(df["block_size"].dropna().unique())
    cmap = plt.cm.viridis
    for i, bs in enumerate(block_sizes):
        sub = df[df["block_size"] == bs]
        ax.scatter(sub["goodput_gbps"], sub["p99_us"],
                   color=cmap(i / max(1, len(block_sizes) - 1)),
                   label=f"bs={int(bs)}", alpha=0.6, s=30)
    ax.set_xlabel("goodput (Gbps)")
    ax.set_ylabel("P99 batch latency (µs)")
    ax.set_yscale("log")
    ax.set_title("Latency vs throughput across the matrix")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(loc="best", fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


def write_summary(df: pd.DataFrame, out: Path) -> None:
    if df.empty:
        out.write_text("No successful cells in this CSV.\n")
        return
    profile = df["profile"].iloc[0]
    rtt = df["rtt_ms"].iloc[0]
    loss = df["loss_pct"].iloc[0]
    bw = df["bw_mbit"].iloc[0]
    best = df.sort_values("goodput_gbps", ascending=False).iloc[0]
    avg = df["goodput_gbps"].mean()

    has_lat = "p99_us" in df.columns and df["p99_us"].dropna().any()
    lat_block = ""
    if has_lat:
        lat_at_best = ""
        for col in ("p50_us", "p95_us", "p99_us"):
            if col in best.index and pd.notna(best.get(col)):
                lat_at_best += f" {col}={best[col]:.0f}"
        median_p99 = df["p99_us"].median()
        lat_block = (
            f"- Median P99 across matrix: **{median_p99:.0f} µs**\n"
            f"- Latency at peak-goodput cell: {lat_at_best.strip()}\n"
        )

    text = f"""# {profile} — summary

- WAN: rtt={rtt} ms, loss={loss}%, bw_cap={bw} mbit
- Cells: {len(df)}
- Mean goodput across matrix: **{avg:.2f} Gbps**
- Peak goodput: **{best['goodput_gbps']:.2f} Gbps**
  - op={best['op']} block_size={int(best['block_size'])} threads={int(best['threads'])} \
slice_size={int(best['slice_size'])} conn_pool={int(best['conn_pool'])} roundrobin={int(best['roundrobin'])}
{lat_block}
See `{out.with_suffix('').name}.throughput_by_threads.png`, \
`{out.with_suffix('').name}.connpool_effect.png`, and \
`{out.with_suffix('').name}.latency_vs_throughput.png` for plots.
"""
    out.write_text(text)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    for raw in argv[1:]:
        csv_path = Path(raw)
        df = load(csv_path)
        stem = csv_path.with_suffix("")
        plot_throughput_by_threads(df, stem.with_suffix(".throughput_by_threads.png"))
        plot_connpool_effect(df, stem.with_suffix(".connpool_effect.png"))
        plot_latency_vs_throughput(df, stem.with_suffix(".latency_vs_throughput.png"))
        write_summary(df, stem.with_suffix(".summary.md"))
        print(f"[plot] wrote artifacts for {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
