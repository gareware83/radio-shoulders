#!/usr/bin/env python3
"""Plots test_pll_top.vhd's per-sample trace dump (pll_trace.csv) into one
clean, annotated figure - meant to sit next to a Vivado waveform-window
screenshot in PLL_DEMO.md, not replace it: this shows the same signals with
proper axis labels, a marked theoretical target, and a zoomed-in view of the
steady-state ripple that a raw waveform screenshot can't easily isolate.

Four panels:
  1. I_in/Q_in (rotating input) vs I_out/Q_out (derotated output), full run -
     the "spinning thing becomes still thing" plot.
  2. u (loop filter output / NCO frequency word), full run, with the
     theoretical target (2**32 * freq/fs, computed from the same
     --freq-hz/--fs given to sin_cos_lut_gen.py --stimulus) marked - the
     quantitative convergence proof.
  3. I_out/Q_out constellation, steady-state samples only - proves it
     settled near a diagonal, not a circle or the wrong axis.
  4. Zoomed phase_err over one short steady-state window - makes the
     decision-directed detector's 4x-carrier-frequency ripple (see
     PLL_DEMO.md) actually legible, which the full-run trace can't.

Usage:
    python3 sim_out_view.py pll_trace.csv
    python3 sim_out_view.py pll_trace.csv --freq-hz 5000 --fs 1000000 --steady-state-start 3000
    python3 sim_out_view.py pll_trace.csv --out pll_demo_sim_view.png --show
"""
import argparse
import csv

import numpy as np


def load_trace(path):
    with open(path) as f:
        r = csv.DictReader(f)
        rows = [{k: int(v) for k, v in row.items()} for row in r]
    return {k: np.array([row[k] for row in rows]) for k in rows[0]}


def find_ripple_period(trace, start, max_period=400, verify_len=10):
    """Smallest period p such that (I_out,Q_out,phase_err) at `start` is
    bit-for-bit identical to `start+p`, and stays identical for the next
    verify_len samples too (rules out a coincidental single-sample match).
    Exact-match, not autocorrelation: the steady-state ripple documented in
    PLL_DEMO.md is a true discrete limit cycle (values repeat exactly, not
    approximately), and there's a composite structure here - a fast
    sub-ripple nested inside the slower true period - that autocorrelation
    can lock onto instead of the fundamental, since it scores a nested
    harmonic as a strong "peak" too. Falls back to max_period if nothing
    matches within range, rather than raising - this is for picking a
    sensible zoom width, not a claim of exact periodicity."""
    i_out, q_out, pe = trace["I_out"], trace["Q_out"], trace["phase_err"]
    n = len(i_out)
    for p in range(2, max_period):
        if start + p + verify_len >= n:
            break
        if all(i_out[start + k] == i_out[start + p + k]
               and q_out[start + k] == q_out[start + p + k]
               and pe[start + k] == pe[start + p + k]
               for k in range(verify_len)):
            return p
    return max_period


def plot(trace, freq_hz, fs, steady_state_start, out_path, show, title):
    import matplotlib.pyplot as plt

    n = trace["sample"]
    u_expected = round((2**32) * freq_hz / fs)

    fig, axes = plt.subplots(2, 3, figsize=(18, 9))
    fig.suptitle(title)

    # 1. I/Q in vs out, full run
    ax = axes[0, 0]
    ax.plot(n, trace["I_in"], color="tab:blue", linewidth=0.6, alpha=0.5, label="I_in")
    ax.plot(n, trace["Q_in"], color="tab:blue", linewidth=0.6, alpha=0.25, label="Q_in")
    ax.plot(n, trace["I_out"], color="tab:orange", linewidth=1.0, label="I_out")
    ax.plot(n, trace["Q_out"], color="tab:red", linewidth=1.0, label="Q_out")
    ax.set_title("Rotating input -> derotated output")
    ax.set_xlabel("sample")
    ax.set_ylabel("amplitude")
    ax.legend(loc="upper right", fontsize=8)
    ax.grid(True, alpha=0.3)

    # 2. u vs theoretical target, full run
    ax = axes[0, 1]
    ax.plot(n, trace["u"], color="tab:green", linewidth=0.8, label="u (actual)")
    ax.axhline(-u_expected, color="black", linestyle="--", linewidth=1.0,
               label=f"-2^32*f/fs = {-u_expected:,}")
    ax.axhline(u_expected, color="gray", linestyle=":", linewidth=0.8,
               label=f"+2^32*f/fs = {u_expected:,}")
    ax.set_title("Loop filter output (NCO frequency word) vs. theoretical target")
    ax.set_xlabel("sample")
    ax.set_ylabel("u")
    ax.legend(loc="lower right", fontsize=8)
    ax.grid(True, alpha=0.3)

    axes[0, 2].axis("off")

    # 3. Constellation, steady-state only. Axes are scaled to the actual
    # cluster with a margin, NOT auto-scaled to include the origin - the
    # whole point is to show how tight the cluster is, which a view that
    # also has to fit (0,0) makes invisible when the loop is genuinely
    # locked (a small cluster far from the origin, at whatever the tone's
    # amplitude/phase happens to put it at).
    ax = axes[1, 0]
    mask = n >= steady_state_start
    i_ss, q_ss = trace["I_out"][mask], trace["Q_out"][mask]
    sc = ax.scatter(i_ss, q_ss, c=n[mask], cmap="viridis", s=8, alpha=0.7)
    span = max(i_ss.max() - i_ss.min(), q_ss.max() - q_ss.min(), 1)
    pad = span * 0.6 + 10
    cx, cy = (i_ss.max() + i_ss.min()) / 2, (q_ss.max() + q_ss.min()) / 2
    ax.set_xlim(cx - pad, cx + pad)
    ax.set_ylim(cy - pad, cy + pad)
    ax.set_aspect("equal", adjustable="box")

    # Mean settled point, called out explicitly as an ordered pair rather
    # than left implicit in the scatter - the ripple (see panel 4) means no
    # single sample is fully representative, but the mean over the window
    # is, and stating "(I, Q), quadrant X" directly is a more concrete claim
    # than a picture of a cluster on its own.
    mean_i, mean_q = float(i_ss.mean()), float(q_ss.mean())
    quadrant = ("++" if mean_i >= 0 and mean_q >= 0 else
                "+-" if mean_i >= 0 else
                "-+" if mean_q >= 0 else "--")
    ax.plot(mean_i, mean_q, marker="x", color="black", markersize=10, mew=2)
    ax.annotate(f"({mean_i:.0f}, {mean_q:.0f})\nquadrant {quadrant}",
                (mean_i, mean_q), textcoords="offset points", xytext=(12, 12),
                fontsize=9, fontweight="bold")

    ax.set_title(f"I_out/Q_out constellation (sample >= {steady_state_start})")
    ax.set_xlabel("I_out")
    ax.set_ylabel("Q_out")
    fig.colorbar(sc, ax=ax, label="sample index", fraction=0.046, pad=0.04)
    ax.grid(True, alpha=0.3)

    # 4. phase_err, FULL run, own panel - deliberately NOT sharing an axis
    # with the zoomed steady-state view (panel 5). phase_err genuinely
    # swings to +/- several hundred million during the initial acquisition
    # transient (samples 0-~2500) before settling to a steady-state ripple
    # roughly 100x smaller - a single shared y-axis would flatten that
    # smaller ripple down to what looks like a flat line at zero, which is
    # exactly the "no oscillation, just noise near zero" misreading this
    # panel exists to head off. Compare directly against panel 5 to see
    # both scales explicitly rather than inferring one from the other.
    ax = axes[1, 1]
    ax.plot(n, trace["phase_err"], color="tab:red", linewidth=0.6)
    ax.axhline(0, color="black", linewidth=0.5)
    ax.axvline(steady_state_start, color="gray", linestyle=":", linewidth=1.0)
    ax.set_title("phase_err, FULL run (note the scale vs. panel to the right)")
    ax.set_xlabel("sample")
    ax.set_ylabel("phase_err")
    ax.grid(True, alpha=0.3)

    # 5. Zoomed phase_err ripple, one short steady-state window - same
    # signal as panel 4, ~100x smaller y-axis range.
    ax = axes[1, 2]
    period = find_ripple_period(trace, steady_state_start)
    zoom_len = period * 4
    zoom_start = steady_state_start
    zoom_end = min(zoom_start + zoom_len, len(n))
    zn = n[zoom_start:zoom_end]
    ax.plot(zn, trace["phase_err"][zoom_start:zoom_end], color="tab:red",
            linewidth=1.2, marker=".", markersize=3)
    ax.axhline(0, color="black", linewidth=0.5)
    ax.set_title(f"phase_err, zoomed ({zoom_len} samples from {zoom_start}) - "
                 f"~{period}-sample ripple")
    ax.set_xlabel("sample")
    ax.set_ylabel("phase_err")
    ax.grid(True, alpha=0.3)

    fig.tight_layout()
    fig.savefig(out_path, dpi=130)
    print(f"[✓] Wrote {out_path}")
    if show:
        plt.show()
    else:
        plt.close(fig)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("trace_csv", nargs="?", default="pll_trace.csv",
                        help="test_pll_top.vhd's trace dump (default: pll_trace.csv)")
    parser.add_argument("--freq-hz", type=float, default=5000.0,
                        help="test tone frequency - must match what "
                             "sin_cos_lut_gen.py --stimulus was run with "
                             "(default 5000)")
    parser.add_argument("--fs", type=float, default=1_000_000.0,
                        help="sample rate (default 1e6)")
    parser.add_argument("--steady-state-start", type=int, default=3000,
                        help="first sample considered steady-state, for "
                             "the constellation/zoom panels (default 3000)")
    parser.add_argument("--out", default="pll_demo_sim_view.png")
    parser.add_argument("--show", action="store_true",
                        help="also open an interactive window")
    parser.add_argument("--title", default="pll_2nd_order.vhd - pure-tone convergence")
    args = parser.parse_args()

    trace = load_trace(args.trace_csv)
    plot(trace, args.freq_hz, args.fs, args.steady_state_start,
         args.out, args.show, args.title)
