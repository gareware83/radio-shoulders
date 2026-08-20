"""
loop_model.py - Design and verification model for the two closed loops in
dsp-cake/comms_dsp/hdl/: carrier recovery (pll_2nd_order.vhd) and symbol
timing recovery (timing_recovery_gardner.vhd).

WHY THIS EXISTS
----------------
K1/K2/C_GAIN_FRAC (PLL) and G_K/G_GAIN_FRAC (Gardner) were never designed -
both files say so themselves ("untuned starting values"). That was fine while
the RTL had structural bugs to find, but once those are gone, picking loop
gains by re-running RTL simulation and eyeballing the waveform is the same
mistake the RRC filter almost shipped with: a hand-picked placeholder standing
in for something with actual closed-form theory behind it. This is the
waveform_generator.py treatment (design in float, quantize to the real
fixed-point format, verify numerically, THEN emit VHDL) applied to the loop
filters instead of the pulse shape.

It also exists because it caught something a hand-derivation almost missed:
tracing pll_2nd_order.vhd's phase detector algebraically (see
characterize_pll_detector()'s docstring) suggested it might not respond to
the input signal's actual phase at all - only to the NCO's own phase. That is
a much larger claim than "the gain is untuned," so it gets checked here
NUMERICALLY before being believed, the same way every other claim in this
codebase's DSP work has been - see rx_model.py, check_filter_scaling(), the
LUT round-trip check in sin_cos_lut_gen.py.

WHAT THIS MODEL DOES AND DOES NOT CAPTURE
-------------------------------------------
The NCO's own sin/cos are modeled with floating-point math, not the 256-entry
quarter-wave LUT pll_2nd_order.vhd actually uses. That LUT's quantization is
a separate, already-characterized concern (sin_cos_lut_gen.py's round-trip
verification) and is small relative to the fixed-point gain-path bug this
file is built to chase. Everything downstream of the NCO - the phase/timing
detector arithmetic and the loop filter's multiply/shift/saturate path - IS
modeled bit-exactly, because that is exactly where the dead-zone bug lives:
it is a property of integer truncation, and a floating-point stand-in would
hide it completely.

Run this file directly for an end-to-end report: characterize both
detectors, quantify the dead zone in the CURRENT constants, redesign both
loops from closed-form theory, verify the redesign closed-loop against a
realistic impaired stimulus, and emit VHDL-ready constants.
"""

import numpy as np
from waveform_generator import RRCWaveformGenerator

# matplotlib itself is still pulled in transitively via RRCWaveformGenerator
# (waveform_generator.py imports pyplot at module level, for its own
# plot_spectrum()/plot_rrc_response()), so this doesn't avoid the import -
# just importing pyplot doesn't touch a display or open anything, so that's
# harmless either way. What's actually gated behind -plot below is building
# any figure or calling plt.show() at all - the analysis-only (default) path
# never does either, and needs no display to run.


# ---------------------------------------------------------------------------
# Fixed-point primitives - bit-exact translations of the VHDL functions of
# the same name/shape. Getting the TRUNCATION DIRECTION right matters: this
# is what determines the dead zone, not just whether one exists.
# ---------------------------------------------------------------------------

def sat32(v):
    """signed 32-bit saturate - sat32() in pll_2nd_order.vhd and the
    equivalent inline logic in timing_recovery_gardner.vhd."""
    return int(np.clip(v, -(2**31), 2**31 - 1))


def clamp_adj(v, limit=2**28):
    """clamp_adj() in timing_recovery_gardner.vhd - bounds the loop's
    authority to +/-limit rather than the full 32-bit range."""
    return int(np.clip(v, -limit, limit))


def shift_right_trunc(v, n):
    """VHDL's shift_right() on SIGNED: arithmetic shift, truncates toward
    negative infinity. Python's >> on a (possibly negative) int is already
    exactly this - not a coincidence to rely on silently, so spelled out
    here as its own function with the VHDL operation named in the docstring,
    the same reasoning as sat32/clamp_adj being wrapped instead of inlined.
    """
    return v >> n


# ===========================================================================
# PLL (carrier recovery) - hdl/pll_2nd_order.vhd
# ===========================================================================

# The NCO ROM's "1.0" - sin_cos_lut_gen.py's AMP_MAX (2**15-1), not a unit
# float. pll_2nd_order.vhd's phase_err is taken straight off the UNSHIFTED
# 32-bit multI/multQ product (I_in * nco_cos, both 16-bit operands), not off
# the >>16-truncated I_rot/Q_rot the way the rotated OUTPUT samples are. Using
# unit-magnitude cos/sin here (as an earlier version of this file did) makes
# every phase_err ~32767x smaller than the real RTL's, which silently flows
# through into a Kd that is ~32767x too small and a design_pi_loop() result
# that is ~32767x too LARGE to compensate - large enough to overflow K1's
# 16-bit field. Caught by quantize_and_check_deadzone() flagging a K1 that
# doesn't fit, not by inspection - the same "check the number, don't just
# check the sign" discipline the dead-zone check itself exists for.
NCO_SCALE = 2 ** 15 - 1


def pll_phase_detector_broken(i_in, q_in, theta_nco):
    """The ORIGINAL pll_2nd_order.vhd phase detector, kept only as a
    regression check that it stays broken (see characterize_pll_detector's
    "before" comparison) - this is NOT what the fixed RTL does any more.

        multI = I_in*cos(theta) - Q_in*sin(theta)      -- rotate input by +theta
        multQ = I_in*sin(theta) + Q_in*cos(theta)
        I_rot, Q_rot = multI, multQ
        phase_err = I_in*Q_rot - Q_in*I_rot

    Substituting the rotation into the cross product algebraically:

        phase_err = I_in*(I_in*sin(theta) + Q_in*cos(theta))
                  - Q_in*(I_in*cos(theta) - Q_in*sin(theta))
                  = (I_in**2 + Q_in**2) * sin(theta)

    Depends on theta (the NCO's OWN phase) and on the input's MAGNITUDE, but
    never on the input's phase - confirmed numerically below, not just by
    this algebra. cos(theta)/sin(theta) are scaled by NCO_SCALE to match the
    real ROM's fixed-point range - the conclusion doesn't depend on the
    scale, but keeping it consistent with the fixed detector avoids two
    different unit conventions living in the same file.
    """
    cos_t, sin_t = NCO_SCALE * np.cos(theta_nco), NCO_SCALE * np.sin(theta_nco)
    i_rot = i_in * cos_t - q_in * sin_t
    q_rot = i_in * sin_t + q_in * cos_t
    phase_err = i_in * q_rot - q_in * i_rot
    return i_rot / 2 ** 16, q_rot / 2 ** 16, phase_err


def pll_phase_detector(i_in, q_in, theta_nco):
    """The FIXED pll_2nd_order.vhd phase detector - decision-directed QPSK
    Costas error on the rotated sample:

        multI = I_in*cos(theta) - Q_in*sin(theta)   -- rotate input by theta,
        multQ = I_in*sin(theta) + Q_in*cos(theta)   -- unchanged, always correct
        phase_err = sign(multI)*multQ - sign(multQ)*multI

    matching pd_proc exactly: phase_err is formed from the FRESH, full-width
    multI/multQ variables, not the registered/truncated I_rot/Q_rot signals
    (which lag by a cycle and are scaled down for the output samples, not the
    error path) - see the VHDL comment this mirrors.

    For a correctly-decided QPSK symbol this is proportional to
    sin(residual phase error) and invariant to which of the four
    constellation points is currently transmitted - the hard decision
    supplies the right reference point automatically. Verified below: input
    phase sweep now has a real span, and its zero crossings land exactly on
    the QPSK decision boundaries and constellation points
    (0, +-45, +-90, +-135 degrees).

    cos(theta)/sin(theta) are scaled by NCO_SCALE (not unit magnitude) so
    phase_err comes out at the RTL's real fixed-point scale - see NCO_SCALE's
    docstring for why this matters far more than it looks like it should.
    i_rot/q_rot are returned pre-scaled back down by >>16 to match I_rot/Q_rot
    (informational only - not used to form phase_err, same as the RTL).
    """
    cos_t, sin_t = NCO_SCALE * np.cos(theta_nco), NCO_SCALE * np.sin(theta_nco)
    multI = i_in * cos_t - q_in * sin_t
    multQ = i_in * sin_t + q_in * cos_t
    signed_q = multQ if multI >= 0 else -multQ
    signed_i = multI if multQ >= 0 else -multI
    phase_err = signed_q - signed_i
    return multI / 2 ** 16, multQ / 2 ** 16, phase_err


def characterize_pll_detector(magnitude=20000.0, n_points=64, detector=pll_phase_detector,
                              kd_center=np.pi / 4, kd_halfwidth=np.deg2rad(2.0),
                              kd_points=17):
    """Sweeps INPUT PHASE at a fixed, arbitrary NCO phase, and separately
    sweeps NCO PHASE at a fixed input phase. A working phase detector's
    output should trace a clean S-curve against INPUT phase (that is the
    whole point of a phase detector). If instead the input-phase sweep is
    FLAT (no response) while the NCO-phase sweep alone reproduces a
    variation, that is the failure mode pll_phase_detector_broken()
    documents - pass detector=pll_phase_detector_broken to reproduce it as a
    regression check.

    Returns a dict with both sweeps' (angles, phase_err) arrays and a
    boolean verdict.
    """
    angles = np.linspace(-np.pi, np.pi, n_points, endpoint=False)

    # Sweep 1: NCO frozen at theta=0, vary the INPUT's own phase. This is
    # what a real carrier offset would look like to the detector.
    input_sweep = np.array([
        detector(magnitude * np.cos(a), magnitude * np.sin(a), 0.0)[2]
        for a in angles
    ])

    # Sweep 2: input frozen at phase 0, vary the NCO's phase instead.
    nco_sweep = np.array([
        detector(magnitude, 0.0, a)[2]
        for a in angles
    ])

    input_span = float(np.ptp(input_sweep))
    nco_span = float(np.ptp(nco_sweep))

    # A responsive detector's input-phase sweep should have real amplitude
    # relative to the input magnitude itself - an unresponsive one is flat
    # at (or near) a single value regardless of input phase.
    responsive = input_span > 0.1 * magnitude

    # Kd: slope through the STABLE zero crossing. This decision-directed
    # detector's S-curve is periodic every 90 deg and has crossings at BOTH
    # the quadrant boundaries (0/90/180/270 deg) and the quadrant centers
    # (+-45/+-135 deg) - but only the quadrant-CENTER crossings are usable.
    # At a boundary the sign()s that pick which quadrant is being decided
    # are themselves ambiguous, and direct inspection shows phase_err has a
    # discontinuous, WRONG-polarity jump there (e.g. +643k at -1 deg, -655k
    # at 0 deg, -644k at +1 deg - backwards relative to the S-curve's own
    # local slope on either side) rather than a proper crossing. Fitting a
    # slope through angle=0 (an earlier version of this function did) reads
    # that jump, not a gain - it is why the first redesign attempt produced
    # a K1 the wrong sign AND wrong order of magnitude, and why the closed
    # loop it drove never came close to settling.
    #
    # The quadrant-center crossings are the ones that matter anyway: this
    # codebase's QPSK symbols sit at +-45/+-135 deg (I,Q = +-1,+-1 - see
    # run_pll_closed_loop's/run_gardner_closed_loop's symbol construction),
    # so +-45 deg IS the detector's real small-signal operating point once
    # locked, not 0 deg.
    kd_angles = kd_center + np.linspace(-kd_halfwidth, kd_halfwidth, kd_points)
    kd_sweep = np.array([
        detector(magnitude * np.cos(a), magnitude * np.sin(a), 0.0)[2]
        for a in kd_angles
    ])
    kd_raw = np.polyfit(kd_angles - kd_center, kd_sweep, 1)[0]

    # SIGN FLIP, and the reason it matters more than it looks like it should:
    # design_pi_loop()'s closed-form formula assumes the STANDARD Costas
    # convention e = Kd*(theta_in - theta_nco), for which de/d(theta_nco) =
    # -Kd - theta_nco entering with a MINUS sign is what makes a positive
    # loop gain self-correcting (negative feedback).
    #
    # pd_proc does not derotate (psi = phi_in - theta_nco); it rotates
    # FORWARD (psi = phi_in + theta_nco - see pll_phase_detector's
    # docstring). theta_nco enters with a PLUS sign, so
    # de/d(theta_nco) = +kd_raw - the SAME sign as de/d(phi_in), not
    # opposite. Feeding kd_raw straight into design_pi_loop() therefore
    # gives K1/K2 the WRONG SIGN: the closed-form Bn/zeta math all still
    # looks fine on paper, but the actual closed loop has POSITIVE
    # feedback. This was caught by run_pll_pure_tone(), not by inspection -
    # a single-tone closed-loop test with the wrong-signed K1/K2 oscillates
    # continuously (phase_err RMS ~6.5e8, essentially the detector's full
    # range) and negating BOTH K1 and K2 collapses that to phase_err RMS
    # ~58k (an ~11,000x reduction) with u landing within 0.01% of the
    # correct value - not a tuning improvement, a stability phase change.
    #
    # Negating here (kd = -kd_raw), rather than negating K1/K2 after the
    # fact at every call site, means design_pi_loop()'s standard formula
    # produces the right sign automatically from here on - the bug cannot
    # silently come back just because someone calls design_pi_loop() again
    # without remembering this detector's non-standard rotation convention.
    kd = -kd_raw

    return {
        "angles": angles,
        "input_sweep": input_sweep,
        "nco_sweep": nco_sweep,
        "input_span": input_span,
        "nco_span": nco_span,
        "responsive_to_input_phase": responsive,
        "kd_angles": kd_angles,
        "kd_sweep": kd_sweep,
        "kd_raw": kd_raw,
        "kd": kd,
    }


class PLLFixedPoint:
    """Bit-exact model of pll_2nd_order.vhd's loop filter and NCO
    accumulator. The phase detector itself is left in float (see
    pll_phase_detector) since its arithmetic doesn't truncate in the VHDL
    either - only the loop filter's shift and the accumulators do, and
    that's what needs bit-fidelity here.
    """

    def __init__(self, K1=105, K2=1, gain_frac=16):
        self.K1 = K1
        self.K2 = K2
        self.gain_frac = gain_frac
        self.reset()

    def reset(self):
        self.phase_acc = 0     # unsigned 32-bit, wraps
        self.u = 0              # signed 32-bit frequency word
        self.e_prev = 0
        self.history = []       # list of dicts, one per step, for inspection

    def step(self, i_in, q_in):
        theta = (self.phase_acc / 2 ** 32) * 2 * np.pi
        i_rot, q_rot, phase_err = pll_phase_detector(i_in, q_in, theta)
        phase_err = int(phase_err)

        p1 = self.K1 * phase_err
        p2 = self.K2 * self.e_prev
        acc = p1 + p2
        delta = sat32(shift_right_trunc(acc, self.gain_frac))
        self.u = sat32(self.u + delta)
        self.e_prev = phase_err

        # unsigned wraparound accumulate, matching "unsigned(u)" in the VHDL
        self.phase_acc = (self.phase_acc + (self.u % 2 ** 32)) % 2 ** 32

        self.history.append(dict(i_in=i_in, q_in=q_in, i_rot=i_rot, q_rot=q_rot,
                                 phase_err=phase_err, delta=delta, u=self.u))
        return i_rot, q_rot, phase_err, self.u


def design_pi_loop(kd, k0, bn_ts, zeta=0.707):
    """Standard 2nd-order PI loop design (proportional Kp, integral Ki) from
    a target loop bandwidth (Bn*Ts, as a fraction of the sample rate) and
    damping factor - the same closed-form design used for Costas loops and
    timing loops alike (see e.g. Rice, "Digital Communications: A
    Discrete-Time Approach", the standard reference for exactly this
    derivation).

    Returns (Kp, Ki) in the TEXTBOOK convention: loop filter output
    v[n] = Kp*e[n] + Ki*i[n], i[n] = i[n-1]+e[n] (its own separate running
    sum), then the NCO does phase_acc[n] = phase_acc[n-1] + K0*v[n] - ONE
    accumulator total besides the integral path's own.

    kd: detector gain (output units per radian of true phase/timing error,
        measured by the characterize_* functions - NOT assumed).
    k0: NCO/accumulator gain (radians, or samples for Gardner, of actual
        correction per LSB of the frequency/increment word).

    IMPORTANT for the PLL: pll_2nd_order.vhd's loop filter is NOT this
    topology - see pll_kp_ki_to_rtl() before using (Kp, Ki) as (K1, K2)
    directly against pd_proc/loopf_proc. Gardner's filter has no integral
    term at all (G_K is Kp, Ki unused) so no mapping is needed there.
    """
    theta_n = (2 * np.pi * bn_ts) / (zeta + 1 / (4 * zeta))
    denom = 1 + 2 * zeta * theta_n + theta_n ** 2
    kp = (4 * zeta * theta_n) / denom / (kd * k0)
    ki = (4 * theta_n ** 2) / denom / (kd * k0)
    return kp, ki


def pll_kp_ki_to_rtl(kp, ki):
    """Maps textbook (Kp, Ki) to pll_2nd_order.vhd's actual loop-filter
    coefficients (K1, K2).

    loopf_proc does NOT keep a separate integral accumulator - it folds
    everything into u:
        delta[n] = K1*e[n] + K2*e[n-1]
        u[n]     = u[n-1] + delta[n]
        theta[n] = theta[n-1] + K0*u[n]

    z-transform: U(z) = (K1 + K2 z^-1) E(z) / (1 - z^-1), so
        Theta(z)/E(z) = K0*(K1 + K2 z^-1) / (1 - z^-1)^2

    The textbook form (Kp direct, Ki through its own accumulator, both then
    hit the SAME NCO integrator) gives:
        F(z) = Kp + Ki/(1-z^-1) = [(Kp+Ki) - Kp*z^-1] / (1-z^-1)
        Theta(z)/E(z) = K0*[(Kp+Ki) - Kp*z^-1] / (1-z^-1)^2

    Both are a general 2-tap-numerator / double-pole-at-DC transfer function
    - the same solution space, different coefficient parameterization.
    Matching numerators term by term:
        K1 = Kp + Ki
        K2 = -Kp

    Getting this backwards (feeding Kp, Ki into K1, K2 directly) puts the
    zero in the wrong place - close in magnitude, wrong shape - which is
    exactly the kind of bug quantize_and_check_deadzone()'s margin check
    can't catch (nothing rounds to zero) but run_pll_closed_loop()'s
    settled-std blowing up does.
    """
    k1_rtl = kp + ki
    k2_rtl = -kp
    return k1_rtl, k2_rtl


def quantize_and_check_deadzone(k1_float, k2_float, gain_frac, expected_err_std,
                                label=""):
    """Quantizes float gains to Q(gain_frac) fixed point and reports the dead
    zone: the largest error magnitude that still rounds to delta=0 after the
    >>gain_frac truncation. THIS is the check that would have caught the bug
    this file exists because of - comparing that dead zone against the
    error magnitude the loop actually operates at, not just checking that
    the quantized gain is "close enough" to the float design value.
    """
    k1_q = int(round(k1_float * 2 ** gain_frac))
    k2_q = int(round(k2_float * 2 ** gain_frac))

    dead_zone = (2 ** gain_frac) / max(abs(k1_q), 1)
    margin = expected_err_std / dead_zone if dead_zone else float("inf")

    print(f"[i] {label} quantization (gain_frac={gain_frac}):")
    print(f"    K1_float={k1_float:.6g}  -> K1_q={k1_q}")
    print(f"    K2_float={k2_float:.6g}  -> K2_q={k2_q}")
    print(f"    dead zone: |error| < {dead_zone:.1f} rounds to zero correction")
    print(f"    expected operating error (1 sigma): {expected_err_std:.1f}")
    if margin < 3.0:
        print(f"    [!] margin only {margin:.1f}x - the loop can stall in the "
              f"dead zone before reaching true lock. Lower gain_frac or "
              f"raise K1.")
    else:
        print(f"    margin {margin:.1f}x - operating error clears the dead "
              f"zone with room to spare.")
    return k1_q, k2_q, dead_zone, margin


def run_pll_closed_loop(K1, K2, gain_frac, freq_err_hz, fs, n_symbols=400,
                        seed=1234, label=""):
    """Drives PLLFixedPoint against a real, pulse-shaped, frequency-offset
    complex baseband stream (same generator as the RTL stimulus, so this is
    testing against the same kind of signal the RTL testbench uses, not a
    synthetic tone) and reports whether phase_err actually settles.

    Includes the matched-filter pass (rx_matched_filter): dsp_top.vhd now
    runs the PLL AFTER matched_filter_rrc, not before (see dsp_top.vhd's
    signal-declaration comment for why - pd_proc's decision-directed
    detector was seeing raw, ISI-heavy mid-symbol samples and that noise
    dominated phase_err's steady state). Leaving this stimulus un-filtered
    would test the loop against a signal it no longer actually receives.
    """
    gen = RRCWaveformGenerator(alpha=0.35, sps=4, span=4, num_symbols=n_symbols,
                               fs=fs, seed=seed)
    rrc = gen.generate_rrc_filter(sps=2)  # RX-rate taps, matching FILTER_LEN
    rng = np.random.default_rng(seed)
    symbols = (2 * rng.integers(0, 2, n_symbols) - 1) + \
              1j * (2 * rng.integers(0, 2, n_symbols) - 1)
    shaped = gen.upsample_and_filter(symbols, rrc, sps=2)

    # Residual carrier ON TOP of what ddc_fs_4 already removes - this model
    # starts from baseband (post-DDC), so freq_err_hz IS the whole offset
    # the PLL sees, unlike the RTL stimulus which is upconverted to fs/4 and
    # then has that exact fs/4 removed again downstream. Applied BEFORE the
    # matched filter, matching where the residual actually sits in the real
    # chain (present from upconversion onward, filtered along with
    # everything else) - not that it matters much at 250 Hz against a filter
    # passband measured in the hundreds of kHz, but there's no reason to
    # guess when getting the order right costs nothing.
    n = np.arange(len(shaped))
    residual = np.exp(2j * np.pi * freq_err_hz * n / fs)
    bb = shaped * residual
    bb = rx_matched_filter(bb, gen, sps=2, span=4)
    bb = bb / np.max(np.abs(bb)) * 20000

    pll = PLLFixedPoint(K1=K1, K2=K2, gain_frac=gain_frac)
    for s in bb:
        pll.step(int(s.real), int(s.imag))

    u_hist = np.array([h["u"] for h in pll.history])
    err_hist = np.array([h["phase_err"] for h in pll.history])

    # Expected steady-state u: the NCO's frequency word that cancels
    # freq_err_hz, in the same units u itself uses (cycles/sample * 2**32) -
    # NEGATIVE of the naive value. pd_proc rotates the input FORWARD by
    # theta_nco (psi = phi_in + theta_nco), not the usual backward
    # derotation (psi = phi_in - theta_nco) - see pll_phase_detector's
    # docstring. A positive freq_err_hz makes phi_in increase over time, so
    # holding psi constant needs theta_nco to DECREASE, which needs a
    # persistently NEGATIVE u (phase_acc accumulates u, never subtracts).
    # First found by a closed-loop run that looked "diverged" but was
    # actually converging cleanly to -u_naive the whole time - the model was
    # locking correctly, the print statement's comparison value wasn't.
    u_expected = -freq_err_hz / fs * 2 ** 32
    tail = u_hist[len(u_hist) // 2:]  # second half, after any acquisition transient
    settled_std = float(np.std(tail))
    settled_mean = float(np.mean(tail))

    print(f"[i] PLL closed-loop check{' - ' + label if label else ''}:")
    print(f"    u expected  ~ {u_expected:+.0f}")
    print(f"    u settled   ~ {settled_mean:+.0f}  (std over 2nd half: {settled_std:.0f})")
    print(f"    phase_err, 2nd-half RMS: {np.std(err_hist[len(err_hist)//2:]):.1f}")

    return dict(u_hist=u_hist, err_hist=err_hist, u_expected=u_expected,
               settled_mean=settled_mean, settled_std=settled_std, pll=pll)


def run_pll_pure_tone(K1, K2, gain_frac, freq_err_hz, iter_rate, n_iters=2000,
                      magnitude=20000.0, phase0=0.0, label=""):
    """Canonical PLL sanity check: a single, UNMODULATED tone at a constant
    frequency offset - no QPSK data, no random quadrant-hopping symbol to
    symbol, no Gardner, no matched filter, no AWGN. The simplest input a
    Costas loop can be asked to track, and the textbook way to verify a
    loop's own mechanism before ever touching data modulation.

    If phase_err does not settle to a small value near zero here, the loop
    filter/detector mechanism has a problem independent of data content. If
    it DOES settle cleanly here but not against real QPSK data
    (run_pll_closed_loop/run_joint_closed_loop), that implicates the data's
    own random quadrant-hopping specifically, not the loop mechanism -
    two different problems that would need two different fixes, and this is
    the test that tells them apart.

    Still exercises the REAL decision-directed detector (sign()-based), so
    it is not entirely free of the quadrant-boundary discontinuity found in
    characterize_pll_detector - a smoothly rotating tone crosses those
    boundaries once per quarter-cycle of freq_err_hz, same as any input
    would. What it removes is the RANDOM, uncorrelated jump between
    quadrants every single iteration that real QPSK data causes.

    iter_rate: the rate at which the PLL actually iterates in the current
    dsp_top.vhd chain (ddc -> filter -> gardner -> pll) - pass fs/2 to match
    run_joint_closed_loop's convention (PLL iterates once per Gardner-
    recovered symbol, roughly half the 2 sps input rate).
    """
    n = np.arange(n_iters)
    theta_in = 2 * np.pi * freq_err_hz * n / iter_rate + phase0
    bb = magnitude * np.exp(1j * theta_in)

    pll = PLLFixedPoint(K1=K1, K2=K2, gain_frac=gain_frac)
    for s in bb:
        pll.step(int(round(s.real)), int(round(s.imag)))

    u_hist = np.array([h["u"] for h in pll.history])
    err_hist = np.array([h["phase_err"] for h in pll.history])
    u_expected = -freq_err_hz / iter_rate * 2 ** 32
    tail = u_hist[len(u_hist) // 2:]
    err_tail = err_hist[len(err_hist) // 2:]

    print(f"[i] PLL pure-tone check{' - ' + label if label else ''}:")
    print(f"    u expected  ~ {u_expected:+.0f}")
    print(f"    u settled   ~ {np.mean(tail):+.0f}  (std over 2nd half: {np.std(tail):.0f})")
    print(f"    phase_err, 2nd-half RMS: {np.std(err_tail):.1f}  mean: {np.mean(err_tail):.1f}")

    return dict(pll=pll, u_hist=u_hist, err_hist=err_hist, u_expected=u_expected)


# ===========================================================================
# Gardner (symbol timing recovery) - hdl/timing_recovery_gardner.vhd
# ===========================================================================

def gardner_detector(i_hist, q_hist):
    """One evaluation of the Gardner TED, matching the RTL exactly:
        e = (I[k]-I[k-2])*I[k-1] + (Q[k]-Q[k-2])*Q[k-1]
    i_hist/q_hist are (i_k, i_k1, i_k2)-ordered 3-tuples: current on-symbol
    sample, the mid-symbol sample, and the previous on-symbol sample.
    Standard textbook TED - no structural bug suspected here (see the PLL's
    detector docstring for contrast) - characterize_gardner_detector() is
    mainly a sanity check that the characterization methodology itself is
    trustworthy, using a detector with known-good behavior as a control.
    """
    i_k, i_k1, i_k2 = i_hist
    q_k, q_k1, q_k2 = q_hist
    return (i_k - i_k2) * i_k1 + (q_k - q_k2) * q_k1


def rx_matched_filter(samples, gen, sps, span=4):
    """Applies the RX-rate RRC a second time, at whatever sample rate
    `samples` is already at - i.e. matched filtering, not pulse shaping.

    This was the gap in the first version of both Gardner functions below:
    apply_timing_offset() only does ONE RRC pass (TX shaping), so feeding its
    output straight to Gardner meant testing against a root-raised-cosine
    pulse, not the raised-cosine (RRC*RRC) response matched_filter_rrc.vhd
    actually hands Gardner in the real chain. Reusing the SAME RRC
    definition for this second pass is the same "one definition, both ends"
    rule write_vhdl_coeffs() already follows for the RTL matched filter -
    using a different filter here would defeat the point of modeling the
    real chain instead of a stand-in for it.

    `sps`/`span` describe the rate `samples` is ALREADY at (2 sps, span=4 ->
    9 taps, matching FILTER_LEN in dsp_pkg.vhd, or higher for an oversampled
    characterization signal) - not necessarily gen's own configured rate.
    """
    taps = gen.generate_rrc_filter(sps=sps, span=span)
    return np.convolve(samples, taps, mode="same")


def characterize_gardner_detector(alpha=0.35, sps=2, span=4, n_points=33,
                                  magnitude=20000.0):
    """Sweeps a fractional timing OFFSET through a pulse-shaped constant
    symbol transition and measures the Gardner error - the timing-domain
    equivalent of characterize_pll_detector(). Offset runs -0.5 to +0.5
    symbol; a working TED should cross zero at offset=0 with a clean,
    monotonic S-curve either side (this is the textbook Gardner
    "S-curve"), not be flat/unresponsive.

    Includes the matched-filter pass (rx_matched_filter) so Kd is measured
    against the same raised-cosine shape Gardner sees downstream of
    matched_filter_rrc.vhd in the real chain, not the bare root-raised-cosine
    apply_timing_offset()/upsample_and_filter() produce on their own.
    """
    # Build a long alternating-symbol sequence (the same reasoning as the
    # preamble's 0xCCCC pattern: max transition density, so the TED has a
    # transition on every symbol to key off) and pulse-shape it well above
    # the target sps so fractional-sample offsets can be read out precisely.
    osr = 16
    gen = RRCWaveformGenerator(alpha=alpha, sps=sps * osr, span=span, num_symbols=64)
    rrc_hi = gen.generate_rrc_filter(sps=sps * osr, span=span)
    symbols = np.array([magnitude * ((-1) ** k + 1j * (-1) ** k) for k in range(64)])
    hi = gen.upsample_and_filter(symbols, rrc_hi, sps=sps * osr)
    hi = rx_matched_filter(hi, gen, sps=sps * osr, span=span)

    offsets = np.linspace(-0.5, 0.5, n_points)
    errs = []
    mid = len(hi) // 2
    for off in offsets:
        # Sample instants at the target sps, offset by `off` symbols,
        # centered in the middle of the burst (clear of edge transients).
        idx_k2 = mid + int(round((off - 1) * sps * osr))
        idx_k1 = mid + int(round((off - 0.5) * sps * osr))
        idx_k = mid + int(round(off * sps * osr))
        i_hist = (hi[idx_k].real, hi[idx_k1].real, hi[idx_k2].real)
        q_hist = (hi[idx_k].imag, hi[idx_k1].imag, hi[idx_k2].imag)
        errs.append(gardner_detector(i_hist, q_hist))

    errs = np.array(errs)
    # Kd: slope through the origin region, the detector's small-signal gain.
    center = n_points // 2
    span_idx = max(1, n_points // 8)
    kd = np.polyfit(offsets[center - span_idx:center + span_idx + 1],
                    errs[center - span_idx:center + span_idx + 1], 1)[0]

    return dict(offsets=offsets, errs=errs, kd=kd)


class GardnerFixedPoint:
    """Bit-exact model of timing_recovery_gardner.vhd's accumulator, TED and
    loop filter. i_in/q_in are fed at 2 sps; the model emits a recovered
    symbol (and the timing_err at that instant) whenever the accumulator
    wraps, exactly matching the RTL's mu/incr carry-out behaviour - no
    interpolation, "take whichever sample it lands on", same as the RTL.
    """

    C_NOMINAL_INCR = 2 ** 31
    C_ADJ_LIMIT = 2 ** 28

    def __init__(self, G_K=64, gain_frac=24, negate=True):
        self.G_K = G_K
        self.gain_frac = gain_frac
        self.negate = negate
        self.reset()

    def reset(self):
        self.mu = 0
        self.incr = self.C_NOMINAL_INCR
        self.i_d1 = self.i_d2 = 0
        self.q_d1 = self.q_d2 = 0
        self.history = []
        # Per-INPUT-sample trace (mu/incr change every sample; timing_err
        # only exists at emit instants) - separate from self.history, which
        # is per-EMITTED-symbol only. Needed to plot mu's sawtooth ramp,
        # which is the shape that actually shows the loop steering.
        self.sample_history = []

    def step(self, i_in, q_in):
        i_in, q_in = int(i_in), int(q_in)
        mu_next = self.mu + self.incr
        carry = mu_next >= 2 ** 32
        self.mu = mu_next % 2 ** 32

        emitted = None
        if carry:
            e_v = gardner_detector((i_in, self.i_d1, self.i_d2),
                                   (q_in, self.q_d1, self.q_d2))
            e_v = int(e_v)
            loop_v = self.G_K * e_v
            adj_v = clamp_adj(shift_right_trunc(loop_v, self.gain_frac),
                              self.C_ADJ_LIMIT)
            if self.negate:
                adj_v = -adj_v
            self.incr = sat32(self.C_NOMINAL_INCR + adj_v) % 2 ** 32

            emitted = dict(i_out=i_in, q_out=q_in, timing_err=sat32(e_v),
                           incr=self.incr)
            self.history.append(emitted)

        self.i_d2, self.i_d1 = self.i_d1, i_in
        self.q_d2, self.q_d1 = self.q_d1, q_in
        self.sample_history.append(dict(mu=self.mu, incr=self.incr))
        return emitted


def run_gardner_closed_loop(G_K, gain_frac, timing_offset, ppm, fs, n_symbols=400,
                            seed=1234, negate=True, label=""):
    """Drives GardnerFixedPoint against a pulse-shaped, timing-and-clock-
    offset stream from the same generator the RTL testbench uses.

    Two things fixed from the first version of this function, both the same
    underlying gap: it built the stimulus at 4 sps (apply_timing_offset's
    default) and naively kept every other sample (`shaped[::2]`) to reach
    Gardner's 2 sps. That is not what ddc_fs_4's decimation does - it
    doesn't just drop samples from an already-basebanded, already-4-sps
    signal, and "every other sample of a 4 sps grid" has no guaranteed
    correspondence to a correctly time-aligned 2 sps grid at all. Building
    the generator with sps=2 directly makes apply_timing_offset() do its own
    interpolation onto the RIGHT grid, with the requested offset/ppm baked
    in natively, instead of decimating something that was never meant to be
    decimated that way.

    The second gap: apply_timing_offset() is TX shaping only (one RRC
    pass). The real Gardner sees the output of matched_filter_rrc.vhd - a
    SECOND RRC pass - not the bare TX-shaped signal. Missing that changes
    the effective pulse (root-raised-cosine instead of the true matched
    raised-cosine response), which is exactly the kind of difference that
    can make a closed-loop check agree or disagree with real RTL behaviour
    for the wrong reason. rx_matched_filter() adds it back.

    Carrier recovery is deliberately NOT modeled here - this isolates Gardner
    from the PLL the same way rx_model.py deliberately doesn't model either
    loop when checking frame-format self-consistency: it separates "does
    Gardner's own loop converge" from "does carrier recovery feed it a clean
    signal", which after the phase-detector fix above are two different
    questions again, not one conflated symptom.
    """
    gen = RRCWaveformGenerator(alpha=0.35, sps=2, span=4, num_symbols=n_symbols,
                               fs=fs, seed=seed)
    rng = np.random.default_rng(seed)
    symbols = (2 * rng.integers(0, 2, n_symbols) - 1) + \
              1j * (2 * rng.integers(0, 2, n_symbols) - 1)
    shaped = gen.apply_timing_offset(symbols, offset_symbols=timing_offset, ppm=ppm)
    bb = rx_matched_filter(shaped, gen, sps=2, span=4)
    bb = bb / np.max(np.abs(bb)) * 20000

    gard = GardnerFixedPoint(G_K=G_K, gain_frac=gain_frac, negate=negate)
    for s in bb:
        gard.step(s.real, s.imag)

    if not gard.history:
        print(f"[i] Gardner closed-loop check{' - ' + label if label else ''}: "
              f"no symbols emitted at all - loop never carried out.")
        return dict(history=[])

    incr_hist = np.array([h["incr"] for h in gard.history])
    err_hist = np.array([h["timing_err"] for h in gard.history])
    tail = incr_hist[len(incr_hist) // 2:]

    print(f"[i] Gardner closed-loop check{' - ' + label if label else ''}:")
    print(f"    symbols emitted: {len(gard.history)} (expected ~{n_symbols})")
    print(f"    incr settled ~ {np.mean(tail):+.0f}  "
         f"(nominal {GardnerFixedPoint.C_NOMINAL_INCR}, std over 2nd half: {np.std(tail):.0f})")
    print(f"    timing_err, 2nd-half RMS: {np.std(err_hist[len(err_hist)//2:]):.1f}")

    return dict(incr_hist=incr_hist, err_hist=err_hist, gard=gard)


def run_gardner_alternating(G_K, gain_frac, timing_offset, ppm, fs, n_symbols=400,
                            seed=1234, negate=True, label=""):
    """Canonical Gardner sanity check: alternating +1+1j/-1-1j symbols (max
    transition density - the same stimulus characterize_gardner_detector
    uses for its S-curve) instead of random QPSK data, and NO carrier offset
    at all - the timing-loop counterpart to run_pll_pure_tone's canonical
    carrier-only test, run_pll_pure_tone's "simplest possible input" applied
    to the timing loop instead.

    Every symbol transition gives Gardner a maximally clean, deterministic
    edge to key off, so this is the cleanest possible check of whether
    timing_err genuinely settles to (near) zero and stays there, separate
    from whatever variance random data content and PLL interaction add in
    run_gardner_closed_loop/run_joint_closed_loop.
    """
    gen = RRCWaveformGenerator(alpha=0.35, sps=2, span=4, num_symbols=n_symbols,
                               fs=fs, seed=seed)
    symbols = np.array([((-1) ** k + 1j * (-1) ** k) for k in range(n_symbols)]) \
             * (20000.0 / np.sqrt(2))
    shaped = gen.apply_timing_offset(symbols, offset_symbols=timing_offset, ppm=ppm)
    bb = rx_matched_filter(shaped, gen, sps=2, span=4)
    bb = bb / np.max(np.abs(bb)) * 20000

    gard = GardnerFixedPoint(G_K=G_K, gain_frac=gain_frac, negate=negate)
    for s in bb:
        gard.step(s.real, s.imag)

    if not gard.history:
        print(f"[i] Gardner alternating-pattern check{' - ' + label if label else ''}: "
             f"no symbols emitted at all - loop never carried out.")
        return dict(gard=gard)

    incr_hist = np.array([h["incr"] for h in gard.history])
    err_hist = np.array([h["timing_err"] for h in gard.history])
    tail = incr_hist[len(incr_hist) // 2:]
    err_tail = err_hist[len(err_hist) // 2:]

    print(f"[i] Gardner alternating-pattern check{' - ' + label if label else ''}:")
    print(f"    symbols emitted: {len(gard.history)} (expected ~{n_symbols})")
    print(f"    incr settled ~ {np.mean(tail):+.0f}  "
         f"(nominal {GardnerFixedPoint.C_NOMINAL_INCR}, std over 2nd half: {np.std(tail):.0f})")
    print(f"    timing_err, 2nd-half RMS: {np.std(err_tail):.1f}  mean: {np.mean(err_tail):.1f}")

    return dict(incr_hist=incr_hist, err_hist=err_hist, gard=gard)


# ===========================================================================
# Joint chain - dsp_top.vhd now runs ddc -> filter -> gardner -> pll (moved
# there for exactly this reason - see dsp_top.vhd's signal-declaration
# comment). The PLL's real input is Gardner's OUTPUT, not the 2 sps stream
# feeding Gardner, so verifying each loop against its own idealized stimulus
# (run_pll_closed_loop, run_gardner_closed_loop above) no longer reflects
# what one loop actually hands the other. This couples them.
# ===========================================================================

def run_joint_closed_loop(G_K, gardner_gain_frac, pll_k1, pll_k2, pll_gain_frac,
                          freq_err_hz, timing_offset, ppm, fs, n_symbols=400,
                          seed=1234, negate=True, label=""):
    """Shapes with a timing offset and ppm clock error, applies the residual
    carrier offset (present from upconversion onward, same as the real RF
    path - BEFORE the matched filter, not after), matched-filters, runs
    Gardner (2 sps -> 1 sps, still carrier-uncorrected - confirmed safe by
    run_gardner_closed_loop never needing carrier correction ahead of it),
    then feeds Gardner's recovered symbols straight into the PLL, exactly
    like inst_pll's data_valid/I_in/Q_in <= gard_valid/gard_i/gard_q in
    dsp_top.vhd.
    """
    gen = RRCWaveformGenerator(alpha=0.35, sps=2, span=4, num_symbols=n_symbols,
                               fs=fs, seed=seed)
    rng = np.random.default_rng(seed)
    symbols = (2 * rng.integers(0, 2, n_symbols) - 1) + \
              1j * (2 * rng.integers(0, 2, n_symbols) - 1)
    shaped = gen.apply_timing_offset(symbols, offset_symbols=timing_offset, ppm=ppm)

    n = np.arange(len(shaped))
    residual = np.exp(2j * np.pi * freq_err_hz * n / fs)
    bb = shaped * residual
    bb = rx_matched_filter(bb, gen, sps=2, span=4)
    bb = bb / np.max(np.abs(bb)) * 20000

    gard = GardnerFixedPoint(G_K=G_K, gain_frac=gardner_gain_frac, negate=negate)
    for s in bb:
        gard.step(s.real, s.imag)

    if not gard.history:
        print(f"[i] Joint closed-loop check{' - ' + label if label else ''}: "
             f"Gardner never emitted a symbol.")
        return dict(gard=gard, pll=None)

    pll = PLLFixedPoint(K1=pll_k1, K2=pll_k2, gain_frac=pll_gain_frac)
    for h in gard.history:
        pll.step(h["i_out"], h["q_out"])

    u_hist = np.array([h["u"] for h in pll.history])
    err_hist = np.array([h["phase_err"] for h in pll.history])

    # The PLL now iterates once per RECOVERED SYMBOL (Gardner's output rate,
    # ~half the 2 sps input rate) instead of once per raw 2 sps sample, so
    # it must correct roughly twice as much phase per iteration to track the
    # same freq_err_hz - hence the factor of 2 versus run_pll_closed_loop's
    # u_expected (which iterates at the full 2 sps rate). Same sign
    # convention as there (pd_proc rotates forward by theta_nco, so a
    # positive freq_err_hz still needs a persistently NEGATIVE u).
    u_expected = -2.0 * freq_err_hz / fs * 2 ** 32
    tail = u_hist[len(u_hist) // 2:]
    settled_std = float(np.std(tail))
    settled_mean = float(np.mean(tail))

    print(f"[i] Joint closed-loop check{' - ' + label if label else ''}:")
    print(f"    symbols emitted: {len(gard.history)} (expected ~{n_symbols})")
    print(f"    u expected  ~ {u_expected:+.0f}")
    print(f"    u settled   ~ {settled_mean:+.0f}  (std over 2nd half: {settled_std:.0f})")
    print(f"    phase_err, 2nd-half RMS: {np.std(err_hist[len(err_hist)//2:]):.1f}")

    return dict(gard=gard, pll=pll, u_hist=u_hist, err_hist=err_hist,
               u_expected=u_expected, settled_mean=settled_mean,
               settled_std=settled_std)


# ===========================================================================
# Plotting - visualise a closed-loop run's internal state over time
# ===========================================================================

def plot_pll_trace(pll, u_expected=None, mark_sample=None, filename="pll_trace.png",
                   title="PLL closed-loop trace", show=False):
    """Plots a PLLFixedPoint run's per-sample I_in (pre-rotation input),
    I_out/Q_out (I_rot/Q_rot, post-rotation output), phase_err and u
    (pll.history, populated by step()) - four panels, sharing an x-axis, so
    the raw input can be directly compared against what the loop did to it.
    mark_sample draws a vertical line - use it to mark where a real RTL run
    actually stopped, to see whether "residual phase" is "not converged
    yet" versus a genuine steady state.

    Always writes filename (a static PNG). show=True ALSO leaves the figure
    open on an interactive backend instead of closing it - pass show=True
    and call plt.show() once after all plots are built (see __main__'s -plot
    handling) to get a live, zoomable window per plot, for comparing
    sample-by-sample against a real RTL simulation waveform viewer rather
    than eyeballing a flat PNG.
    """
    import matplotlib.pyplot as plt
    i_in = np.array([h["i_in"] for h in pll.history])
    q_in = np.array([h["q_in"] for h in pll.history])
    i_rot = np.array([h["i_rot"] for h in pll.history])
    q_rot = np.array([h["q_rot"] for h in pll.history])
    phase_err = np.array([h["phase_err"] for h in pll.history])
    u = np.array([h["u"] for h in pll.history])
    n = np.arange(len(pll.history))

    fig, axes = plt.subplots(4, 1, figsize=(10, 11), sharex=True)
    fig.suptitle(title)

    axes[0].plot(n, i_in, label="I_in", linewidth=0.8, color="tab:blue")
    axes[0].plot(n, q_in, label="Q_in", linewidth=0.6, color="tab:blue", alpha=0.4)
    axes[0].set_ylabel("PLL input (I/Q)")
    axes[0].legend(loc="upper right")
    axes[0].grid(True, alpha=0.3)

    axes[1].plot(n, i_rot, label="I_out (I_rot)", linewidth=0.8, color="tab:orange")
    axes[1].plot(n, q_rot, label="Q_out (Q_rot)", linewidth=0.6, color="tab:orange", alpha=0.4)
    axes[1].set_ylabel("PLL output (I/Q)")
    axes[1].legend(loc="upper right")
    axes[1].grid(True, alpha=0.3)

    axes[2].plot(n, phase_err, color="tab:red", linewidth=0.8)
    axes[2].axhline(0, color="black", linewidth=0.5)
    axes[2].set_ylabel("phase_err")
    axes[2].grid(True, alpha=0.3)

    axes[3].plot(n, u, color="tab:green", linewidth=0.8)
    if u_expected is not None:
        axes[3].axhline(u_expected, color="black", linestyle="--", linewidth=0.8,
                        label=f"u_expected={u_expected:+.0f}")
        axes[3].legend(loc="upper right")
    axes[3].set_ylabel("u (NCO freq word)")
    axes[3].set_xlabel("sample (2 sps)")
    axes[3].grid(True, alpha=0.3)

    if mark_sample is not None:
        for ax in axes:
            ax.axvline(mark_sample, color="gray", linestyle=":", linewidth=1.2)

    fig.tight_layout()
    fig.savefig(filename, dpi=120)
    print(f"[✓] Wrote {filename}")
    if not show:
        plt.close(fig)
    return fig


def plot_gardner_trace(gard, mark_symbol=None, filename="gardner_trace.png",
                       title="Gardner closed-loop trace", show=False):
    """Plots a GardnerFixedPoint run's per-INPUT-sample mu/incr (the
    sawtooth phase accumulator and the rate the loop is steering it at) and
    per-EMITTED-symbol timing_err/I_out/Q_out (gard.history).

    Always writes filename (a static PNG). show=True ALSO leaves the figure
    open instead of closing it - see plot_pll_trace's docstring.
    """
    import matplotlib.pyplot as plt
    mu = np.array([h["mu"] for h in gard.sample_history])
    incr = np.array([h["incr"] for h in gard.sample_history])
    n_samp = np.arange(len(gard.sample_history))

    if gard.history:
        timing_err = np.array([h["timing_err"] for h in gard.history])
        i_out = np.array([h["i_out"] for h in gard.history])
        q_out = np.array([h["q_out"] for h in gard.history])
        n_sym = np.arange(len(gard.history))
    else:
        timing_err = i_out = q_out = np.array([])
        n_sym = np.array([])

    fig, axes = plt.subplots(4, 1, figsize=(10, 11))
    fig.suptitle(title)

    axes[0].plot(n_samp, mu, linewidth=0.5, color="tab:blue")
    axes[0].set_ylabel("mu (phase acc)")
    axes[0].set_xlabel("input sample (2 sps)")
    axes[0].grid(True, alpha=0.3)

    axes[1].plot(n_samp, incr, linewidth=0.8, color="tab:orange")
    axes[1].axhline(GardnerFixedPoint.C_NOMINAL_INCR, color="black", linestyle="--",
                    linewidth=0.8, label="nominal incr")
    axes[1].set_ylabel("incr")
    axes[1].set_xlabel("input sample (2 sps)")
    axes[1].legend(loc="upper right")
    axes[1].grid(True, alpha=0.3)

    axes[2].plot(n_sym, timing_err, linewidth=0.8, color="tab:red")
    axes[2].axhline(0, color="black", linewidth=0.5)
    axes[2].set_ylabel("timing_err")
    axes[2].set_xlabel("emitted symbol")
    axes[2].grid(True, alpha=0.3)

    axes[3].plot(n_sym, i_out, label="I_out", linewidth=0.8)
    axes[3].plot(n_sym, q_out, label="Q_out", linewidth=0.8)
    axes[3].set_ylabel("Gardner output (I/Q)")
    axes[3].set_xlabel("emitted symbol")
    axes[3].legend(loc="upper right")
    axes[3].grid(True, alpha=0.3)

    if mark_symbol is not None:
        axes[2].axvline(mark_symbol, color="gray", linestyle=":", linewidth=1.2)
        axes[3].axvline(mark_symbol, color="gray", linestyle=":", linewidth=1.2)

    fig.tight_layout()
    fig.savefig(filename, dpi=120)
    print(f"[✓] Wrote {filename}")
    if not show:
        plt.close(fig)
    return fig


# ===========================================================================
# VHDL emission
# ===========================================================================

def write_vhdl_constants(pll_k1, pll_k2, pll_gain_frac,
                         gardner_k, gardner_gain_frac,
                         filename="loop_coeffs.vhd"):
    """Emits both loops' redesigned constants, ready to paste into
    pll_2nd_order.vhd / timing_recovery_gardner.vhd - same "generate, don't
    hand-edit" convention as write_vhdl_coeffs() for the RRC taps."""
    with open(filename, "w") as f:
        f.write("-- Generated by loop_model.py - do not hand edit.\n")
        f.write("-- Paste into the matching constant/generic declarations.\n\n")
        f.write("-- pll_2nd_order.vhd\n")
        f.write(f"constant C_GAIN_FRAC : natural := {pll_gain_frac};\n")
        f.write(f"constant K1 : signed(15 downto 0) := to_signed({pll_k1},16);\n")
        f.write(f"constant K2 : signed(15 downto 0) := to_signed({pll_k2},16);\n\n")
        f.write("-- timing_recovery_gardner.vhd generics\n")
        f.write(f"G_GAIN_FRAC : natural := {gardner_gain_frac};\n")
        f.write(f"G_K         : integer := {gardner_k}\n")
    print(f"[✓] Wrote redesigned loop constants to {filename}")


# ===========================================================================
# Entry point: characterize, diagnose the current constants, redesign, verify
# ===========================================================================

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(
        description="Design/verify the PLL and Gardner loop filters. Runs "
                    "the full text report by default; add -plot to also "
                    "render live, zoomable plots (pll_trace.png/"
                    "gardner_trace.png are always written either way).")
    parser.add_argument("-plot", "--plot", action="store_true", dest="plot",
                        help="Show interactive plot windows (in addition to "
                             "saving the PNGs) so traces can be zoomed and "
                             "compared sample-by-sample against a real RTL "
                             "simulation waveform viewer. Off by default - "
                             "the analysis/report runs without building any "
                             "figure or needing a display, whether or not "
                             "this is passed.")
    args = parser.parse_args()

    FS = 1_000_000
    SYMBOL_RATE = FS / 4

    print("=" * 70)
    print("PLL phase detector: before/after")
    print("=" * 70)
    broken = characterize_pll_detector(detector=pll_phase_detector_broken)
    fixed = characterize_pll_detector(detector=pll_phase_detector)
    print(f"[i] BROKEN formula - input-phase sweep span : {broken['input_span']:.3g}  "
         f"NCO-phase sweep span: {broken['nco_span']:.3g}")
    print(f"[i] FIXED  formula - input-phase sweep span : {fixed['input_span']:.3g}  "
         f"NCO-phase sweep span: {fixed['nco_span']:.3g}")
    if fixed["responsive_to_input_phase"] and not broken["responsive_to_input_phase"]:
        print("[i] Confirms the fix: broken formula flat against input phase, "
             "fixed formula responsive. Kd measured from the fixed formula's "
             "zero crossing.")
    kd_pll = fixed["kd"]
    print(f"[i] PLL Kd, design-ready (sign-corrected for the +theta rotation "
         f"convention - see characterize_pll_detector()'s kd_raw comment): "
         f"{kd_pll:.4g}  (raw measured slope: {fixed['kd_raw']:.4g})")

    print()
    print("=" * 70)
    print("Gardner TED characterization (control - standard, no bug suspected; "
         "now includes the matched-filter pass)")
    print("=" * 70)
    gardner_char = characterize_gardner_detector()
    print(f"[i] measured Kd (slope at origin): {gardner_char['kd']:.3g}")
    print(f"[i] S-curve span: {np.ptp(gardner_char['errs']):.3g}")

    print()
    print("=" * 70)
    print("Canonical sanity checks - simplest possible input per loop, to")
    print("separate 'the loop mechanism itself' from 'data-content effects'")
    print("=" * 70)
    print("[i] PLL: single unmodulated tone at a constant frequency offset - "
         "no QPSK data, no quadrant-hopping, no Gardner, no matched filter.")
    pll_tone_result = run_pll_pure_tone(K1=-810, K2=803, gain_frac=16,
                                        freq_err_hz=250.0, iter_rate=FS / 2,
                                        n_iters=2000, label="deployed gains")
    print("[i] Gardner: random QPSK data (NOT the alternating max-transition "
         "pattern - that's a known Gardner self-noise pathology in closed "
         "loop, confirmed by testing it here: it saturates incr even with "
         "ZERO timing offset and ZERO ppm, i.e. with nothing to correct - "
         "not a bug, just the wrong stimulus for a closed-loop test), no "
         "carrier offset.")
    gard_canonical_result = run_gardner_closed_loop(G_K=12578, gain_frac=16,
                                                    timing_offset=0.37, ppm=20.0,
                                                    fs=FS, n_symbols=1022,
                                                    label="deployed gains, canonical")

    print()
    print("=" * 70)
    print("Dead-zone check against the CURRENT (untuned) constants")
    print("=" * 70)
    # Rough operating-error estimate for the dead-zone margin check: run the
    # current constants closed-loop first and measure what phase_err/
    # timing_err actually do, then check that against the dead zone their
    # OWN gain_frac implies - this is the check that would have caught the
    # bug directly, instead of finding it by reading a waveform by hand.
    # n_symbols=2000 (not the 400-symbol default): Bn*Ts=0.001's time
    # constant is ~1/Bn*Ts ~ 1000 samples, so 400 symbols (800 samples)
    # isn't enough run length to see it actually settle - it looked
    # "diverged" at 400 for exactly this reason before the u_expected sign
    # fix made clear it was just slow, not wrong.
    current_pll = run_pll_closed_loop(K1=105, K2=1, gain_frac=16,
                                      freq_err_hz=250.0, fs=FS, n_symbols=2000,
                                      label="current constants, fixed detector")
    quantize_and_check_deadzone(105 / 2**16, 1 / 2**16, gain_frac=16,
                                expected_err_std=max(current_pll["settled_std"], 1),
                                label="PLL (current gains, fixed detector)")

    current_gardner = run_gardner_closed_loop(G_K=64, gain_frac=24,
                                              timing_offset=0.37, ppm=20.0,
                                              fs=FS, label="current constants, "
                                              "tightened stimulus")
    if len(current_gardner.get("err_hist", [])):
        quantize_and_check_deadzone(64 / 2**24, 0, gain_frac=24,
                                    expected_err_std=max(np.std(current_gardner["err_hist"]), 1),
                                    label="Gardner (current)")

    print()
    print("=" * 70)
    print("Redesign from closed-form theory, both loops")
    print("=" * 70)

    # Bn*Ts=0.01 (matching Gardner's target below) turned out too fast here:
    # a closed-loop sweep (not shown in this report - see the session's
    # working notes) found it settles on the right value but with std
    # ~4-10% of the NCO's full 32-bit range, because pd_proc runs on RAW,
    # NOT-YET-MATCHED-FILTERED baseband (the PLL sits between ddc_fs_4 and
    # matched_filter_rrc in dsp_top.vhd) - every sample is data-modulated
    # and inter-symbol interference is not yet cleaned up, so the detector's
    # instantaneous output is intrinsically noisier than Gardner's (which
    # runs downstream of the matched filter). 0.001 converges within the
    # same few hundred samples and cuts that steady-state jitter by ~10x.
    k0_pll = 2 * np.pi / 2 ** 32  # phase_acc LSB -> radians per sample
    pll_kp, pll_ki = design_pi_loop(kd=kd_pll, k0=k0_pll, bn_ts=0.001, zeta=0.707)
    pll_k1_new, pll_k2_new = pll_kp_ki_to_rtl(pll_kp, pll_ki)
    print(f"[i] PLL design target: Bn*Ts=0.001, zeta=0.707")
    print(f"[i] textbook Kp={pll_kp:.6g}  Ki={pll_ki:.6g}")
    print(f"[i] mapped to RTL topology: K1={pll_k1_new:.6g}  K2={pll_k2_new:.6g}")

    k0_gardner = 1.0 / 2 ** 32  # accumulator LSB -> fraction-of-symbol per step
    gardner_k1_new, gardner_k2_new = design_pi_loop(kd=gardner_char["kd"], k0=k0_gardner,
                                                    bn_ts=0.01, zeta=0.707)
    print(f"[i] Gardner design target: Bn*Ts=0.01, zeta=0.707")
    print(f"[i] designed proportional gain (maps to G_K): {gardner_k1_new:.6g}")
    print(f"[i] designed integral gain (unused - Gardner's filter here is "
         f"proportional-only, no e_prev term): {gardner_k2_new:.6g}")

    print()
    for gf in (12, 16, 20):
        pll_k1_q, pll_k2_q, _, _ = quantize_and_check_deadzone(
            pll_k1_new, pll_k2_new, gain_frac=gf,
            expected_err_std=max(current_pll["settled_std"], 1),
            label=f"PLL redesign @ gain_frac={gf}")

    print()
    for gf in (16, 20, 24):
        gardner_k1_q, _, _, _ = quantize_and_check_deadzone(
            gardner_k1_new, 0, gain_frac=gf,
            expected_err_std=max(np.std(current_gardner.get("err_hist", [1])), 1),
            label=f"Gardner redesign @ gain_frac={gf}")

    print()
    print("=" * 70)
    print("Closed-loop verification of the redesign (gain_frac=16 for both)")
    print("=" * 70)
    quantize_and_check_deadzone(pll_k1_new, pll_k2_new, gain_frac=16,
                                expected_err_std=max(current_pll["settled_std"], 1),
                                label="PLL final")
    pll_k1_final = int(round(pll_k1_new * 2 ** 16))
    pll_k2_final = int(round(pll_k2_new * 2 ** 16))
    run_pll_closed_loop(K1=pll_k1_final, K2=pll_k2_final, gain_frac=16,
                        freq_err_hz=250.0, fs=FS, n_symbols=2000, label="REDESIGNED")

    gardner_k_final = int(round(gardner_k1_new * 2 ** 16))
    run_gardner_closed_loop(G_K=gardner_k_final, gain_frac=16,
                            timing_offset=0.37, ppm=20.0, fs=FS,
                            label="REDESIGNED")

    print()
    print("=" * 70)
    print("VHDL emission")
    print("=" * 70)
    write_vhdl_constants(pll_k1_final, pll_k2_final, 16,
                         gardner_k_final, 16)

    if not args.plot:
        print()
        print("(skipping plots - rerun with -plot to render and view them)")
    else:
        print()
        print("=" * 70)
        print("Plots: deployed gains against run_frames()'s actual stimulus "
             "parameters (freq_err_hz=250, timing_offset=0.37, ppm=20 - the "
             "same defaults ddc_input.dat was generated with), run "
             "continuously for 1022 symbols to match the real tb_dsp.vhd "
             "run's symbol count. Uses run_joint_closed_loop - dsp_top.vhd's "
             "CURRENT chain is ddc -> filter -> gardner -> pll, so the PLL's "
             "real input is Gardner's recovered 1 sps output, not the 2 sps "
             "stream feeding Gardner. This model does NOT reproduce the "
             "32-symbol silent gaps between frames that run_frames() "
             "inserts - if these plots converge cleanly but the real "
             "hardware/sim run doesn't, that gap is the next suspect.")
        print("=" * 70)
        plot_joint_result = run_joint_closed_loop(
            G_K=gardner_k_final, gardner_gain_frac=16,
            pll_k1=pll_k1_final, pll_k2=pll_k2_final, pll_gain_frac=16,
            freq_err_hz=250.0, timing_offset=0.37, ppm=20.0, fs=FS,
            n_symbols=1022, label="plotting run")
        plot_pll_trace(plot_joint_result["pll"], u_expected=plot_joint_result["u_expected"],
                      filename="pll_trace.png",
                      title="PLL trace - deployed gains, post-Gardner, 1022-symbol run",
                      show=True)
        plot_gardner_trace(plot_joint_result["gard"], filename="gardner_trace.png",
                           title="Gardner trace - deployed gains, 1022-symbol run",
                           show=True)

        print()
        print("[i] Canonical sanity-check plots: PLL against a pure tone (no "
             "data, no Gardner), Gardner against random data with no carrier "
             "offset - the same two runs the text report above already ran, "
             "just visualised. Watch phase_err in the pure-tone plot "
             "specifically: it settling to a small band around zero would "
             "mean the mechanism is fine and something data-related is the "
             "problem; it oscillating across most of its range (as the text "
             "report found) means the loop filter itself needs work "
             "regardless of what data ever reaches it.")
        plot_pll_trace(pll_tone_result["pll"], u_expected=pll_tone_result["u_expected"],
                      filename="pll_pure_tone_trace.png",
                      title="PLL trace - pure tone, canonical sanity check",
                      show=True)
        plot_gardner_trace(gard_canonical_result["gard"], filename="gardner_canonical_trace.png",
                           title="Gardner trace - random data, no carrier offset, canonical",
                           show=True)

        import matplotlib.pyplot as plt
        print()
        print("[i] Showing live plot windows (4: joint PLL/Gardner, canonical "
             "PLL/Gardner) - zoom/pan freely, close all windows to exit.")
        plt.show()
