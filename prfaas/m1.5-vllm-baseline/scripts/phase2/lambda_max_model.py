#!/usr/bin/env python3
"""Analytical Λ_max model for PrfaaS Phase 2.

Pure functions, no I/O. Implements the paper's bandwidth-feasibility +
throughput-at-SLO model from §3 of *Prefill-as-a-Service: KVCache of
Next-Generation Models Could Go Cross-Datacenter* (Qin et al., 2026),
adapted to the variables we can plug in directly from our Phase 1
measurements (`Φkv(l)`, `T_prefill(l)`, `S_kv(l)`).

The full derivation, every assumption, and the sensitivity analysis live
in
``prfaas/results/m1.5-vllm-baseline/phase2_analytical/MODEL_AND_EQUATIONS.md``.
This module is the executable form of those equations.

# Quick reference (Eq numbering matches MODEL_AND_EQUATIONS.md)

Inputs per (model, workload):
    l, o, S_kv(l) [bytes], T_prefill(l) [s], TPOT [s/tok]

Inputs per system:
    B_w [Gbps], RTT [s], N_p [prefill replicas], N_d [decode replicas],
    N_y [collocated replicas in Config H], decode_batch_p, decode_batch_h,
    SLO_TTFT [s]

Eq 1 (per-request wire transit, Config P):
    T_wire(l) = (S_kv(l) * 8) / (B_w * 1e9)         # bytes → bits / bps

Eq 2 (per-request floor TTFT):
    TTFT_floor_H(l) = T_prefill(l)
    TTFT_floor_P(l) = T_prefill(l) + T_wire(l) + RTT

Eq 3 (capacity bottlenecks, Config P):
    λ_compute_p = N_p / T_prefill(l)
    λ_wire      = (B_w * 1e9) / (S_kv(l) * 8)        # Gbps → req/s
    λ_decode_p  = (N_d * decode_batch_p) / (o * TPOT)
    Λ_P_capacity = min(λ_compute_p, λ_wire, λ_decode_p)

Eq 4 (capacity, Config H — collocated prefill+decode on Y):
    Λ_H_capacity = (N_y * decode_batch_h) / (T_prefill(l) + o * TPOT)

Eq 5 (M/M/1 P95 wait-time approximation at the bottleneck server):
    s_service = 1 / Λ_capacity
    ρ = λ_offered / Λ_capacity
    W_p95(λ_offered) = ln(20) * s_service * ρ / (1 - ρ)        # ρ < 1
    TTFT_p95(λ_offered) = TTFT_floor + W_p95(λ_offered)

Eq 6 (Λ_max under SLO): the largest λ_offered ∈ [0, Λ_capacity) with
    TTFT_p95(λ_offered) ≤ SLO_TTFT, found by bisection.

Eq 7 (paper headline, "PrfaaS speedup"):
    speedup(model, l, B_w, …) = Λ_max_P / Λ_max_H

Eq 8 (bandwidth-feasibility predicate, paper §5.1):
    feasible(model, l, B_w) ≡ Φkv(l) ≤ B_w
    → Λ_wire / λ_compute_p ≥ 1
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Literal


# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Workload:
    """Per-request workload parameters at one operating point."""

    input_len: int
    output_len: int
    skv_bytes: int          # KV bytes per request from Phase 1
    t_prefill_s: float      # measured Phase 1 p50 prefill latency (seconds)
    tpot_s: float           # per-token decode latency at batch=1 (seconds)


@dataclass(frozen=True)
class System:
    """Per-experiment system parameters."""

    b_w_gbps: float         # single-direction wire goodput
    rtt_s: float            # round-trip time on the wire
    slo_ttft_s: float       # TTFT P95 SLO
    n_p_replicas: int       # prefill replicas in Config P (each TP=8)
    n_d_replicas: int       # decode replicas in Config P (each TP=8)
    n_y_replicas: int       # collocated replicas in Config H
    decode_batch_p: int     # achievable concurrent decode batch in P
    decode_batch_h: int     # achievable concurrent decode batch in H


# ---------------------------------------------------------------------------
# Per-request floors
# ---------------------------------------------------------------------------


def t_wire_s(skv_bytes: int, b_w_gbps: float) -> float:
    """Eq 1: per-request KV wire transit time."""
    if b_w_gbps <= 0:
        return float("inf")
    return (skv_bytes * 8) / (b_w_gbps * 1e9)


def ttft_floor_h_s(w: Workload) -> float:
    """Eq 2 (H branch)."""
    return w.t_prefill_s


def ttft_floor_p_s(w: Workload, s: System) -> float:
    """Eq 2 (P branch)."""
    return w.t_prefill_s + t_wire_s(w.skv_bytes, s.b_w_gbps) + s.rtt_s


# ---------------------------------------------------------------------------
# Capacity bottlenecks
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class CapacityBreakdown:
    capacity_req_s: float
    bottleneck: Literal["compute_p", "wire", "decode_p", "collocated"]
    lambda_compute_p_req_s: float
    lambda_wire_req_s: float
    lambda_decode_p_req_s: float


def lambda_capacity_p(w: Workload, s: System) -> CapacityBreakdown:
    """Eq 3: Config P capacity = min(prefill, wire, decode)."""
    lam_compute = s.n_p_replicas / w.t_prefill_s if w.t_prefill_s > 0 else float("inf")
    lam_wire = (s.b_w_gbps * 1e9) / (w.skv_bytes * 8) if w.skv_bytes > 0 else float("inf")
    t_decode = w.output_len * w.tpot_s
    lam_decode = (s.n_d_replicas * s.decode_batch_p) / t_decode if t_decode > 0 else float("inf")
    parts = [
        ("compute_p", lam_compute),
        ("wire", lam_wire),
        ("decode_p", lam_decode),
    ]
    name, cap = min(parts, key=lambda kv: kv[1])
    return CapacityBreakdown(
        capacity_req_s=cap,
        bottleneck=name,
        lambda_compute_p_req_s=lam_compute,
        lambda_wire_req_s=lam_wire,
        lambda_decode_p_req_s=lam_decode,
    )


def lambda_capacity_h(w: Workload, s: System) -> float:
    """Eq 4: Config H collocated capacity.

    The collocated replica must do both prefill and decode on the same TP
    set. We pessimistically assume per-request wall-clock = T_prefill + T_decode
    (a single replica can't run prefill on req-A and decode on req-B in
    parallel because they share the KV cache). We then multiply by the
    achievable collocated batch (decode_batch_h). decode_batch_h is small
    relative to decode_batch_p because prefill bursts block decode-batch
    progress.
    """
    t_decode = w.output_len * w.tpot_s
    return (s.n_y_replicas * s.decode_batch_h) / (w.t_prefill_s + t_decode)


# ---------------------------------------------------------------------------
# SLO constraint: M/M/1 P95 wait approximation
# ---------------------------------------------------------------------------


_LN20 = math.log(20.0)  # ln(1/0.05) ≈ 2.996


def w_p95_s(lambda_offered: float, lambda_capacity: float) -> float:
    """Eq 5 (W_p95 only).

    Closed-form for an M/M/1 queue's P95 waiting time under load `λ` with
    service rate `μ = λ_capacity`. The factor ln(20) is the 95th-percentile
    quantile of an exponential distribution. We use M/M/1 (not M/D/1)
    because (a) prefill latency at fixed l is not perfectly deterministic —
    SGLang's batch scheduling adds jitter — and (b) M/M/1 is the
    conservative tail.
    """
    if lambda_capacity <= 0:
        return float("inf")
    if lambda_offered >= lambda_capacity:
        return float("inf")
    rho = lambda_offered / lambda_capacity
    s_service = 1.0 / lambda_capacity
    return _LN20 * s_service * rho / (1.0 - rho)


def ttft_p95_s(
    lambda_offered: float,
    lambda_capacity: float,
    ttft_floor: float,
) -> float:
    """Eq 5 (TTFT_p95)."""
    return ttft_floor + w_p95_s(lambda_offered, lambda_capacity)


def lambda_at_slo(
    lambda_capacity: float,
    ttft_floor: float,
    slo_s: float,
    *,
    n_iter: int = 100,
) -> float:
    """Eq 6: bisect to find the largest offered rate with TTFT_p95 ≤ SLO."""
    if lambda_capacity <= 0:
        return 0.0
    if ttft_floor > slo_s:
        return 0.0
    # If even the at-capacity (zero queueing) floor satisfies SLO, capacity is the answer.
    if ttft_p95_s(lambda_capacity * 0.999, lambda_capacity, ttft_floor) <= slo_s:
        return lambda_capacity * 0.999
    lo = 0.0
    hi = lambda_capacity * 0.999
    for _ in range(n_iter):
        mid = 0.5 * (lo + hi)
        if ttft_p95_s(mid, lambda_capacity, ttft_floor) <= slo_s:
            lo = mid
        else:
            hi = mid
    return lo


# ---------------------------------------------------------------------------
# Headline numbers
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class CellResult:
    # Inputs (echoed for CSV writers)
    model_short: str
    input_len: int
    output_len: int
    skv_bytes: int
    t_prefill_s: float
    tpot_s: float
    b_w_gbps: float
    rtt_s: float
    slo_ttft_s: float
    n_p_replicas: int
    n_d_replicas: int
    n_y_replicas: int
    decode_batch_p: int
    decode_batch_h: int

    # Derived per-request floors
    t_wire_s: float
    ttft_floor_h_s: float
    ttft_floor_p_s: float

    # Capacities
    lambda_compute_p_req_s: float
    lambda_wire_req_s: float
    lambda_decode_p_req_s: float
    lambda_capacity_p_req_s: float
    lambda_capacity_p_bottleneck: str
    lambda_capacity_h_req_s: float

    # SLO-constrained Λ_max
    lambda_max_p_req_s: float
    lambda_max_h_req_s: float
    speedup_p_over_h: float

    # Feasibility predicate
    phi_kv_gbps: float
    wire_feasible: bool


def evaluate(w: Workload, s: System, model_short: str) -> CellResult:
    """Run every equation for one (workload, system) cell."""
    cap_p = lambda_capacity_p(w, s)
    cap_h = lambda_capacity_h(w, s)

    floor_h = ttft_floor_h_s(w)
    floor_p = ttft_floor_p_s(w, s)

    lam_p = lambda_at_slo(cap_p.capacity_req_s, floor_p, s.slo_ttft_s)
    lam_h = lambda_at_slo(cap_h, floor_h, s.slo_ttft_s)

    speedup = (lam_p / lam_h) if lam_h > 0 else float("inf")

    phi_kv_bps = w.skv_bytes / w.t_prefill_s if w.t_prefill_s > 0 else float("inf")
    phi_kv_gbps = phi_kv_bps * 8 / 1e9

    return CellResult(
        model_short=model_short,
        input_len=w.input_len,
        output_len=w.output_len,
        skv_bytes=w.skv_bytes,
        t_prefill_s=w.t_prefill_s,
        tpot_s=w.tpot_s,
        b_w_gbps=s.b_w_gbps,
        rtt_s=s.rtt_s,
        slo_ttft_s=s.slo_ttft_s,
        n_p_replicas=s.n_p_replicas,
        n_d_replicas=s.n_d_replicas,
        n_y_replicas=s.n_y_replicas,
        decode_batch_p=s.decode_batch_p,
        decode_batch_h=s.decode_batch_h,
        t_wire_s=t_wire_s(w.skv_bytes, s.b_w_gbps),
        ttft_floor_h_s=floor_h,
        ttft_floor_p_s=floor_p,
        lambda_compute_p_req_s=cap_p.lambda_compute_p_req_s,
        lambda_wire_req_s=cap_p.lambda_wire_req_s,
        lambda_decode_p_req_s=cap_p.lambda_decode_p_req_s,
        lambda_capacity_p_req_s=cap_p.capacity_req_s,
        lambda_capacity_p_bottleneck=cap_p.bottleneck,
        lambda_capacity_h_req_s=cap_h,
        lambda_max_p_req_s=lam_p,
        lambda_max_h_req_s=lam_h,
        speedup_p_over_h=speedup,
        phi_kv_gbps=phi_kv_gbps,
        wire_feasible=phi_kv_gbps <= s.b_w_gbps,
    )
