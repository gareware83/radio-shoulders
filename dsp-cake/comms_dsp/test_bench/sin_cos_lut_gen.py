import argparse

import numpy as np
from waveform_generator import RRCWaveformGenerator

wfg = RRCWaveformGenerator()

# Parameters
ADDR_BITS = 8             # quarter-wave table: 2^8 = 256 entries, 8-bit addra
AMP_BITS  = 16            # output width
AMP_MAX   = 2**(AMP_BITS-1) - 1


# .coe for the blk_mem_gen IP wizard. Radix is declared in the header, so
# decimal values are fine here.
def write_coe(filename, data):
    with open(filename, "w") as f:
        f.write("memory_initialization_radix=10;\n")
        f.write("memory_initialization_vector=\n")
        for i, val in enumerate(data):
            sep = ',' if i < len(data)-1 else ';'
            f.write(f"{val}{sep}\n")

# .mem for XPM (xpm_memory_sprom MEMORY_INIT_FILE), which is read $readmemh
# style - values MUST be hex with no prefix, one per line, zero padded to the
# memory width. Writing decimal here silently misparses (32767 -> 0x32767,
# overflowing 16 bits), which is what the previous np.savetxt("%d") did.
def write_mem(filename, data, width_bits):
    mask   = (1 << width_bits) - 1
    digits = (width_bits + 3) // 4
    with open(filename, "w") as f:
        for val in data:
            f.write(f"{int(val) & mask:0{digits}X}\n")

def check(name, data, expected):
    if len(data) != expected:
        raise SystemExit(f"[!] {name}: {len(data)} entries, expected {expected}")
    print(f"[*] {name}: {len(data)} entries, "
          f"range {int(min(data))}..{int(max(data))}")


def gen_lut(plot=False):
    """Original behaviour: the quarter-wave sin/cos LUT the NCO's ROMs are
    initialized from (sine.mem/cos.mem, plus .coe for the IP wizard), and a
    fixed 10-cycle reference tone (pure_sine.dat/pure_cos.dat) at exactly
    fs/ADDR_BITS - not a stimulus generator, just a sanity-check waveform at
    the LUT's own native resolution."""
    N = 2**ADDR_BITS
    phases = np.arange(N) * np.pi / (2 * N)
    phases_tone = np.arange(N * 10) * 2 * np.pi / N

    sine = np.round(AMP_MAX * np.sin(phases)).astype(np.int16)
    cos  = np.round(AMP_MAX * np.cos(phases)).astype(np.int16)

    sine_tone = np.round(AMP_MAX * np.sin(phases_tone)).astype(np.int16)
    cos_tone  = np.round(AMP_MAX * np.cos(phases_tone)).astype(np.int16)

    # Catch a short/truncated table at generation time rather than as a
    # constant phase offset in hardware.
    check("sine", sine, N)
    check("cos",  cos,  N)

    write_coe("sine.coe", sine)
    write_coe("cos.coe", cos)

    write_mem("sine.mem", sine, AMP_BITS)
    write_mem("cos.mem",  cos,  AMP_BITS)

    wfg.save_to_file(samples=sine_tone, filename="pure_sine.dat")
    wfg.save_to_file(samples=cos_tone, filename="pure_cos.dat")

    if plot:
        import matplotlib.pyplot as plt
        plt.figure(figsize=(10, 4))
        plt.plot(sine, label="Quarter period sine")
        plt.plot(cos_tone, label="Quarter period cos")
        plt.title("Time Domain View of DDS Samples")
        plt.xlabel("Sample Index")
        plt.ylabel("Amplitude")
        plt.grid(True)
        plt.legend()
        plt.tight_layout()
        plt.show()


def gen_stimulus(freq_hz, fs, n_samples, phase_deg=0.0, amplitude=1.0,
                  cos_path="cos.dat", sin_path="sin.dat", plot=False):
    """Writes a stationary complex tone - I(n)=A*cos(wn+phi0),
    Q(n)=A*sin(wn+phi0) - as two decimal-per-line files (test_pll_top.vhd's
    format, via RRCWaveformGenerator.save_to_file - same convention every
    other stimulus file in this project uses).

    This is deliberately the same test methodology test_bench/loop_model.py's
    run_pll_pure_tone() already validated at the Python-model level: a single
    unmodulated tone with a residual frequency/phase offset isolates the
    PLL's own acquisition behavior from data-dependent effects entirely - no
    symbols, no framing, just "does the loop null out a known, deliberately
    non-zero residual." freq_hz=0 would hand the PLL an already-locked input
    and prove nothing; a real test needs freq_hz far enough from 0 that a
    genuinely broken loop (e.g. this file's own documented sign-error
    history) visibly fails to converge, not close enough to pass by luck.

    Amplitude is normalized to AMP_MAX (matches the ADC/DDC full-scale
    convention every other stimulus file in this project already uses, not
    an arbitrary unit) - pass 1.0 for full scale.
    """
    n = np.arange(n_samples)
    phase0 = np.deg2rad(phase_deg)
    w = 2 * np.pi * freq_hz / fs
    peak = amplitude * AMP_MAX

    cos_samples = np.round(peak * np.cos(w * n + phase0)).astype(np.int16)
    sin_samples = np.round(peak * np.sin(w * n + phase0)).astype(np.int16)

    wfg.save_to_file(samples=cos_samples, filename=cos_path)
    wfg.save_to_file(samples=sin_samples, filename=sin_path)
    print(f"[*] wrote {n_samples} samples to {cos_path}, {sin_path} "
          f"(freq={freq_hz} Hz, fs={fs} Hz, phase0={phase_deg} deg, "
          f"amplitude={amplitude})")

    if plot:
        import matplotlib.pyplot as plt
        plt.figure(figsize=(10, 4))
        plt.plot(cos_samples, label="I (cos)")
        plt.plot(sin_samples, label="Q (sin)")
        plt.title(f"Complex tone stimulus: {freq_hz} Hz @ fs={fs} Hz")
        plt.xlabel("Sample Index")
        plt.ylabel("Amplitude")
        plt.grid(True)
        plt.legend()
        plt.tight_layout()
        plt.show()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Generates the NCO's sin/cos LUT contents (default), "
                     "or a complex-tone stimulus file pair for driving "
                     "pll_2nd_order.vhd directly (--stimulus).")
    parser.add_argument("--stimulus", action="store_true",
                        help="generate a complex tone stimulus (cos.dat/"
                             "sin.dat) instead of the LUT files")
    parser.add_argument("--freq-hz", type=float, default=5000.0,
                        help="tone frequency, i.e. the residual the PLL "
                             "must correct (default 5000 Hz)")
    parser.add_argument("--fs", type=float, default=1_000_000.0,
                        help="sample rate (default 1 MHz, matching every "
                             "other stimulus file in this project)")
    parser.add_argument("--n-samples", type=int, default=4000,
                        help="stimulus length (default 4000)")
    parser.add_argument("--phase-deg", type=float, default=45.0,
                        help="initial phase offset in degrees (default 45)")
    parser.add_argument("--amplitude", type=float, default=0.5,
                        help="fraction of full scale, 0..1 (default 0.5)")
    parser.add_argument("--out-cos", default="cos.dat")
    parser.add_argument("--out-sin", default="sin.dat")
    parser.add_argument("--plot", action="store_true",
                        help="show a matplotlib window (default: write "
                             "files only, no GUI)")
    args = parser.parse_args()

    if args.stimulus:
        gen_stimulus(args.freq_hz, args.fs, args.n_samples, args.phase_deg,
                     args.amplitude, args.out_cos, args.out_sin, args.plot)
    else:
        gen_lut(args.plot)
