# PLL Demo — A Discrete-Time, Complex-Valued Carrier-Recovery Loop
## Results

[tb pll sim](./pll_demo_sim.png)

## Intro
A small, self-contained 2nd-order carrier-recovery PLL example pulled from a larger practice (for fun) software-defined-radio
project, written in synthesizable VHDL,
verified against a simple sine-wave stimulus with a self-checking testbench.

This file explains what the design is and how the test proves it works. It's
written to stand on its own without conext from the rest of the parent
project.

The parent project is on the following branch for anyone intersted in reviewing the state of the larger design. 
[Radio-shoulders](https://github.com/gareware83/radio-shoulders)

The development is accelerated using Claude AI code, steered by my professional experience in FPGA, DSP and SDR design. 

Algorithm reference: Digital Communications: A discrete Time Approach, Michael Rice

## What this is

`pll_2nd_order.vhd` is a carrier-recovery loop: given a complex baseband
signal (`I`, `Q`) whose phase is rotating at some unknown, roughly-constant
rate (a frequency offset between a transmitter and receiver's local
oscillators, in a real radio), it estimates that rotation and cancels it
out. This is a standard building block in almost every digital receiver, 
without it, a QPSK constellation just spins in a circle instead of sitting
still at four fixed symbol points.

The loop has three pieces, all in one clocked VHDL process group:

1. **Rotator**: multiplies the incoming complex sample by the current
   estimate of the carrier's phase (`cos`/`sin` from a numerically
   controlled oscillator, i.e. an NCO/DDS), producing a "derotated" complex
   output.
2. **Phase detector**: looks at the derotated output and produces a
   number representing how far off the current phase estimate still is.
3. **Loop filter + NCO**: a 2nd-order proportional-integral filter
   accumulates the phase detector's output into a frequency word, which
   drives the NCO's own phase accumulator. This is the feedback that makes
   it a *loop*: get the phase estimate wrong, and the next cycle's
   detector output nudges it back.

## Sine Wave as Stimulus

Using a sine wave as the stimulus instead of a QPSK data carrying signal works 
to isolate loop dynamics and observe phase error, loop filter output, 
and nco waveform converging on values that cancel residual phase and stabalize
the PLL output to the rest of the DSP receiver. 


## The test setup

- **Stimulus**: `test_bench/sin_cos_lut_gen.py --stimulus` generates
  `cos.dat`/`sin.dat` which is the complex tone `A·e^{j(2π·f·n/fs + φ₀)}`, written as
  plain decimal text, one sample per line (the same format every stimulus
  file in the parent project uses). Default test point: 5000 Hz at a 1 MHz
  sample rate, 45° initial phase, 8000 samples, half full-scale amplitude.
- **Testbench**: `test_bench/test_pll_top.vhd` (entity `test_pll_top`)
  feeds `cos.dat`/`sin.dat` into `pll_2nd_order.vhd` one sample per clock,
  and `test_bench/tb_pll.vhd` is the thin top-level wrapper that reports
  pass/fail results.
- **Run it**: standard Vivado behavioral simulation, `tb_pll` as the
  simulation top. `cos.dat`/`sin.dat` need to be physically present in
  wherever the simulator's working directory 

## How correctness is checked

Two independent, self-checking criteria, both evaluated over the last 200
samples of the run:

1. **Did the NCO find the right frequency?** For a tone at a known
   frequency `f` against sample rate `fs`, the exact phase increment per
   sample needed to cancel it is `2^32 × f/fs` (the NCO's phase accumulator
   is 32 bits, spanning one full circle). The loop filter's output (`u`,
   the "frequency word") is checked against that computed value directly,
   within 5% as quantitative proof of convergence

2. **Did the derotated signal land on a stable point?** `min(|I|,|Q|) /
   max(|I|,|Q|)` of the derotated output, summed over the window — the
   same scale-invariant lock-quality ratio the parent project's receiver
   uses everywhere else (`rx_quality.vhd`). A ratio near 1.0 means the
   output settled near a diagonal (`I≈Q` in magnitude); a ratio near 0
   would mean it collapsed onto one axis instead, locking onto the wrong, unstable equilibrium. The parent project runs the full RX chain on a
   Zybo Z7-20 (xc7z020clg400-1) dev board

Both have to pass for the testbench to report `PASS`.

A full per-sample trace (`pll_trace.csv`) is also written for every run —
every sample's input, output, phase error, and loop-filter state — so a
claimed pass/fail can always be checked against the actual time-domain
behavior, not just trusted from a summary number.

## Files

| File | Role |
|---|---|
| `hdl/pll_2nd_order.vhd` | The DUT — synthesizable, no simulation-only constructs except the `dbg_*` debug ports |
| `test_bench/test_pll_top.vhd` | Stimulus, DUT instantiation, self-check, trace dump |
| `test_bench/tb_pll.vhd` | Top-level testbench wrapper (reports PASS/FAIL) |
| `test_bench/sin_cos_lut_gen.py` | Generates both the DUT's NCO lookup tables and the test stimulus (`--stimulus`) |
| `test_bench/loop_model.py` | Python-level loop model used to derive/validate the loop filter gains and characterize the phase detector before committing anything to RTL |
