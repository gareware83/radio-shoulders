import numpy as np
from scipy.signal import lfilter
import matplotlib.pyplot as plt

# ---------------------------------------------------------------------------
# Frame format constants. These MUST match hdl/pkg.vhd - the receiver and this
# generator are two halves of one definition, and a mismatch shows up as
# "sync never fires" with no other clue.
# ---------------------------------------------------------------------------
SYNC_WORD = 0x1ACFFC1D          # CCSDS ASM
PREAMBLE_WORD = 0xCCCCCCCC      # see the long note in pkg.vhd - NOT 0xAAAA...
CRC_POLY = 0x1021               # CRC-16-CCITT
CRC_INIT = 0xFFFF

FRAME_TYPE_CMD, FRAME_TYPE_DATA, FRAME_TYPE_ACK = 0x0, 0x1, 0x2


def word_to_bits(value, nbits):
    """MSB-first bit list. Everything on the wire is MSB-first."""
    return [(value >> (nbits - 1 - i)) & 1 for i in range(nbits)]


def bytes_to_bits(data):
    bits = []
    for b in data:
        bits.extend(word_to_bits(b, 8))
    return bits


def crc16_ccitt(bits):
    """Bit-at-a-time CRC-16-CCITT, matching crc16_step() in pkg.vhd exactly.

    Init 0xFFFF, no final xor. Fed the header and payload bits in wire order.
    """
    crc = CRC_INIT
    for b in bits:
        fb = ((crc >> 15) & 1) ^ (b & 1)
        crc = (crc << 1) & 0xFFFF
        if fb:
            crc ^= CRC_POLY
    return crc


class RRCWaveformGenerator:
    def __init__(self, alpha=0.35, sps=4, span=4, num_symbols=100, freq_offset_hz=1e3,
                 fs=1e6, seed=1234):
        self.seed = seed
        self.alpha = alpha
        self.sps = sps              # Samples per symbol (ADC is 4× symbol rate)
        self.span = span            # Filter span in symbols
        self.num_symbols = num_symbols
        self.freq_offset = freq_offset_hz
        self.fs = fs                # Sample rate in Hz

        self.symbol_rate = fs / sps
        self.t = np.arange(self.num_symbols * self.sps) / fs

    # -----------------------------------------------------------------
    # Pulse shaping
    # -----------------------------------------------------------------
    def generate_rrc_filter(self, sps=None, span=None):
        sps = self.sps if sps is None else sps
        span = self.span if span is None else span

        N = span * sps
        t = np.arange(-N // 2, N // 2 + 1) / sps
        rrc = np.zeros_like(t)

        for i in range(len(t)):
            if t[i] == 0.0:
                rrc[i] = 1.0 - self.alpha + (4 * self.alpha / np.pi)
            elif abs(t[i]) == 1 / (4 * self.alpha):
                rrc[i] = (self.alpha / np.sqrt(2)) * (
                    (1 + 2 / np.pi) * np.sin(np.pi / (4 * self.alpha)) +
                    (1 - 2 / np.pi) * np.cos(np.pi / (4 * self.alpha))
                )
            else:
                num = np.sin(np.pi * t[i] * (1 - self.alpha)) + \
                      4 * self.alpha * t[i] * np.cos(np.pi * t[i] * (1 + self.alpha))
                denom = np.pi * t[i] * (1 - (4 * self.alpha * t[i])**2)
                rrc[i] = num / denom
        return rrc / np.sqrt(np.sum(rrc**2))  # Normalize energy

    def generate_symbols(self):
        # QPSK random symbols. Seeded so regenerating gives the same stimulus -
        # otherwise every run shifts the peak level, which makes the filter
        # output scaling (C_OUT_LSB) unrepeatable and sim results
        # incomparable between runs.
        rng = np.random.default_rng(self.seed)
        symbols = (2 * rng.integers(0, 2, self.num_symbols) - 1) + \
                  1j * (2 * rng.integers(0, 2, self.num_symbols) - 1)
        return symbols

    def upsample_and_filter(self, symbols, rrc, sps=None):
        sps = self.sps if sps is None else sps
        upsampled = np.zeros(len(symbols) * sps, dtype=complex)
        upsampled[::sps] = symbols
        return lfilter(rrc, 1.0, upsampled)

    def apply_frequency_offset(self, samples, freq=None):
        freq = self.freq_offset if freq is None else freq
        t = np.arange(len(samples)) / self.fs
        return np.real(samples * np.exp(2j * np.pi * freq * t))

    def quantize(self, samples, bitwidth=16, headroom=1.0):
        maxval = 2**(bitwidth - 1) - 1
        minval = -2**(bitwidth - 1)
        clipped = np.clip(samples * maxval * headroom, minval, maxval)
        return clipped.astype(np.int16)

    # -----------------------------------------------------------------
    # File output
    # -----------------------------------------------------------------
    def save_to_file(self, samples, filename="ddc_input.dat"):
        # Real-valued sample streams only. Complex data silently loses its
        # imaginary part through int(), so use save_symbols_to_file for
        # symbols - that bug meant qpsk_symbols.dat held I only.
        if np.iscomplexobj(samples):
            raise TypeError(f"{filename}: complex data would lose Q; "
                            f"use save_symbols_to_file()")
        with open(filename, "w") as f:
            for sample in samples:
                f.write(f"{int(sample)}\n")
        print(f"[✓] Saved {len(samples)} samples to {filename}")

    def save_symbols_to_file(self, symbols, filename="qpsk_symbols.dat"):
        """Reference symbols for self-checking, one 'I Q' pair per line.

        These are the pre-modulation truth: the demodulator output should
        match this sequence once carrier recovery and timing are working.
        """
        with open(filename, "w") as f:
            for s in symbols:
                f.write(f"{int(np.real(s))} {int(np.imag(s))}\n")
        print(f"[✓] Saved {len(symbols)} I/Q symbol pairs to {filename}")

    # -----------------------------------------------------------------
    # Matched filter taps for the VHDL receiver
    # -----------------------------------------------------------------
    def rrc_taps_quantized(self, bitwidth=16, peak_bits=14, sps=None):
        """Quantize the RRC to integers for the VHDL matched filter.

        A matched filter is only 'matched' if these taps ARE the pulse shape
        used for TX shaping - so both come from generate_rrc_filter().

        peak_bits sets the largest tap to 2**peak_bits, leaving headroom in
        the filter accumulator.
        """
        rrc = self.generate_rrc_filter(sps=sps)
        scale = (2 ** peak_bits) / np.max(np.abs(rrc))
        taps = np.round(rrc * scale).astype(np.int64)

        lim = 2 ** (bitwidth - 1) - 1
        if np.max(np.abs(taps)) > lim:
            raise SystemExit(f"[!] taps exceed {bitwidth}-bit range; lower peak_bits")
        return taps.astype(np.int32)

    def write_vhdl_coeffs(self, filename="rrc_coeffs.vhd", bitwidth=16, peak_bits=14,
                          rx_sps=None):
        """Emit the rrc_coeffs constant to paste into dsp_pkg.vhd.

        rx_sps is the samples-per-symbol the RX filter actually runs at, which
        is NOT necessarily the TX shaping rate: ddc_fs_4 decimates by 2, so a
        4 sps transmit stream reaches the matched filter at 2 sps. An RRC is
        defined in samples per symbol, so taps generated at the TX rate would
        stretch the pulse by the decimation factor and stop being matched.

        Span is held in SYMBOLS, so the filter covers the same stretch of the
        transmit pulse either way - only the sampling of it changes.
        FILTER_LEN in dsp_pkg.vhd must equal span*rx_sps + 1.
        """
        rx_sps = self.sps if rx_sps is None else rx_sps
        taps = self.rrc_taps_quantized(bitwidth, peak_bits, sps=rx_sps)
        n = len(taps)

        with open(filename, "w") as f:
            f.write("-- Generated by waveform_generator.py - do not hand edit.\n")
            f.write(f"-- alpha={self.alpha}, span={self.span} symbols, "
                    f"peak tap = 2**{peak_bits}\n")
            f.write(f"-- TX shaping runs at {self.sps} sps; these taps are for the RX\n")
            f.write(f"-- filter at {rx_sps} sps (ddc_fs_4 decimates by "
                    f"{self.sps // rx_sps}).\n")
            f.write("-- Regenerate alongside the stimulus - they are only matched\n")
            f.write("-- if they come from the same RRC definition.\n")
            f.write(f"constant FILTER_LEN : integer := {n};\n")
            f.write("constant rrc_coeffs : coeff_array_t := (\n")
            for i, v in enumerate(taps):
                sep = ',' if i < n - 1 else ''
                f.write(f"    to_signed({int(v):6d}, {bitwidth}){sep}\n")
            f.write(");\n")

        print(f"[✓] Wrote {n} taps to {filename} for RX at {rx_sps} sps "
              f"(peak {int(np.max(np.abs(taps)))}, sum {int(np.sum(taps))})")
        print(f"    -> set FILTER_LEN = {n} in dsp_pkg.vhd")
        return taps

    # =================================================================
    # Framed-burst generation
    # =================================================================

    def build_frame(self, payload, ftype=FRAME_TYPE_DATA, seq=0, preamble_bits=64):
        """One complete frame as an MSB-first bit list.

            | PREAMBLE | SYNC 32 | HEADER 16 | PAYLOAD | CRC16 |

        preamble_bits is configurable and defaults to twice the 32 bits the
        format nominally specifies. The receiver never searches for the
        preamble - frame_sync hunts the sync word - so its length is purely a
        transmit-side choice about how much runway the acquisition loops get.
        32 bits is only 16 symbols, which is not obviously enough for two
        feedback loops to settle; see the lead-in discussion in run_frames().
        """
        if len(payload) > 255:
            raise ValueError(f"payload {len(payload)} B exceeds the 255 B format limit")

        bits = []

        # Preamble: repeat the 32-bit pattern, truncated to preamble_bits
        pre = word_to_bits(PREAMBLE_WORD, 32)
        bits.extend((pre * ((preamble_bits + 31) // 32))[:preamble_bits])

        bits.extend(word_to_bits(SYNC_WORD, 32))

        # HEADER: | TYPE 4 | LEN 8 | SEQ 4 |
        header = ((ftype & 0xF) << 12) | ((len(payload) & 0xFF) << 4) | (seq & 0xF)
        hdr_bits = word_to_bits(header, 16)
        pay_bits = bytes_to_bits(payload)

        # CRC covers HEADER + PAYLOAD, not the preamble or sync word, and
        # obviously not itself.
        crc = crc16_ccitt(hdr_bits + pay_bits)

        bits.extend(hdr_bits)
        bits.extend(pay_bits)
        bits.extend(word_to_bits(crc, 16))

        return bits, crc

    @staticmethod
    def qpsk_map(bits):
        """Bits -> QPSK symbols, the exact inverse of qpsk_slicer.vhd.

        The slicer decides b1 = i_in(15) and b0 = q_in(15) - the SIGN BITS. So
        a set bit means a NEGATIVE component:

            b1 = 0 -> I = +1      b1 = 1 -> I = -1
            b0 = 0 -> Q = +1      b0 = 1 -> Q = -1

        Bits are consumed MSB-first in pairs, b1 then b0, matching the way
        frame_sync shifts each symbol into the low bits of its registers.

        Getting this inverse wrong is invisible until the very end of the
        chain: every loop still locks, the constellation still looks clean, and
        only the CRC fails.
        """
        if len(bits) % 2:
            raise ValueError("bit count must be even - 2 bits per QPSK symbol")
        b = np.array(bits, dtype=int).reshape(-1, 2)
        i = np.where(b[:, 0] == 0, 1.0, -1.0)
        q = np.where(b[:, 1] == 0, 1.0, -1.0)
        return i + 1j * q

    def build_burst(self, frames, gap_symbols=32, preamble_bits=64):
        """Concatenate several frames into one symbol stream, with idle gaps.

        Gaps matter: they force frame_sync back into its hunt state between
        frames, so the test exercises re-acquisition rather than one lucky
        lock that then coasts. Gap symbols are zero, i.e. no signal.

        Returns (symbols, manifest) where manifest describes what the receiver
        should produce, in order.
        """
        syms = []
        manifest = []

        for spec in frames:
            bits, crc = self.build_frame(spec["payload"],
                                         ftype=spec.get("type", FRAME_TYPE_DATA),
                                         seq=spec.get("seq", 0),
                                         preamble_bits=preamble_bits)
            frame_syms = self.qpsk_map(bits)

            manifest.append({
                "type": spec.get("type", FRAME_TYPE_DATA),
                "seq": spec.get("seq", 0),
                "len": len(spec["payload"]),
                "payload": bytes(spec["payload"]),
                "crc": crc,
                "start_symbol": len(syms),
                "n_symbols": len(frame_syms),
            })

            syms.extend(frame_syms)
            syms.extend([0j] * gap_symbols)

        return np.array(syms), manifest

    def apply_timing_offset(self, symbols, offset_symbols=0.0, ppm=0.0, osr=16):
        """Pulse-shape with a fractional timing offset and optional clock error.

        Shapes at sps*osr, then resamples down to sps starting at a fractional
        phase. Without this the symbol instants land exactly on sample
        boundaries and the timing loop has nothing to correct - which would
        make a passing simulation prove almost nothing about Gardner.

        ppm adds a sampling-clock frequency error between transmitter and
        receiver, so the loop has to keep TRACKING rather than just acquire
        once. Real links always have this.
        """
        hi_sps = self.sps * osr
        rrc_hi = self.generate_rrc_filter(sps=hi_sps)
        hi = self.upsample_and_filter(symbols, rrc_hi, sps=hi_sps)

        # Sample instants in high-rate index space
        n_out = int((len(hi) - hi_sps) / osr)
        idx = offset_symbols * hi_sps + np.arange(n_out) * osr * (1.0 + ppm * 1e-6)
        idx = idx[idx < len(hi) - 1]

        src = np.arange(len(hi))
        return np.interp(idx, src, hi.real) + 1j * np.interp(idx, src, hi.imag)

    def add_awgn(self, samples, snr_db):
        """Real-valued AWGN at a given SNR, measured on the signal actually sent."""
        if snr_db is None:
            return samples
        rng = np.random.default_rng(self.seed + 977)
        sig_pow = np.mean(samples.astype(float) ** 2)
        noise_pow = sig_pow / (10 ** (snr_db / 10.0))
        return samples + rng.normal(0.0, np.sqrt(noise_pow), len(samples))

    # -----------------------------------------------------------------
    # Verification helpers
    # -----------------------------------------------------------------
    def check_filter_scaling(self, quantized, taps):
        """Model ddc_fs_4 + matched_filter_rrc numerically and report the peak.

        C_OUT_LSB in matched_filter_rrc.vhd is a hand-picked output window, and
        it is only correct for a particular input amplitude. Changing the
        stimulus moves it. This reports what the accumulator actually reaches so
        the constant can be confirmed rather than assumed - an earlier estimate
        of 14 clipped 34 of 200 samples.

        ddc_fs_4 model: fs/4 mixing holds I on even phases and emits the pair on
        odd phases, so the 2 sps output is
            I = [x0, -x2, x4, -x6, ...]   Q = [x1, -x3, x5, -x7, ...]
        """
        x = quantized.astype(np.int64)
        n = (len(x) // 4) * 4
        x = x[:n]

        # even-indexed samples with alternating sign -> I, odd -> Q
        ev, od = x[0::2], x[1::2]
        i_ds = ev * np.resize([1, -1], len(ev))
        q_ds = od * np.resize([1, -1], len(od))

        i_acc = np.convolve(i_ds, taps.astype(np.int64))
        q_acc = np.convolve(q_ds, taps.astype(np.int64))
        peak = max(np.max(np.abs(i_acc)), np.max(np.abs(q_acc)))

        bits = int(np.ceil(np.log2(peak))) if peak > 0 else 0
        print(f"[i] matched-filter accumulator peak {peak} ({bits} bits)")
        for lsb in range(bits - 17, bits):
            if lsb < 0:
                continue
            out_peak = peak >> lsb
            clipped = np.sum(np.abs(i_acc) >> lsb > 32767) + \
                      np.sum(np.abs(q_acc) >> lsb > 32767)
            flag = "CLIPS" if clipped else f"{100 * out_peak / 32768:.0f}% full scale"
            print(f"      C_OUT_LSB = {lsb:2d} -> peak {out_peak:6d}  {flag}")

    def save_manifest(self, manifest, filename="rx_expected.txt"):
        """What the receiver should produce, for self-checking.

        Also emits the metadata word rx_frame_buffer.vhd prepends to each DMA
        packet, so the PS-side result can be compared without re-deriving it.
        """
        with open(filename, "w") as f:
            f.write("# Expected receiver output, in order.\n")
            f.write("# meta = the 32-bit word rx_frame_buffer prepends to each frame:\n")
            f.write("#   [31:16] frame count  [15:12] seq  [11:8] type  [7:0] len\n")
            for n, m in enumerate(manifest, start=1):
                meta = (n << 16) | ((m["seq"] & 0xF) << 12) | \
                       ((m["type"] & 0xF) << 8) | (m["len"] & 0xFF)
                f.write(f"\nframe {n}\n")
                f.write(f"  type    0x{m['type']:x}\n")
                f.write(f"  seq     {m['seq']}\n")
                f.write(f"  len     {m['len']}\n")
                f.write(f"  crc     0x{m['crc']:04X}\n")
                f.write(f"  meta    0x{meta:08X}\n")
                f.write(f"  payload {m['payload'].hex()}\n")
        print(f"[✓] Wrote expected results for {len(manifest)} frames to {filename}")

    def save_expected_stream(self, manifest, filename="rx_expected_stream.dat"):
        """The exact AXI-Stream beats rx_frame_buffer should emit, for the RTL
        testbench to compare against beat by beat.

        This is the ground-truth check. Frame count plus CRC only proves the
        receiver decoded something SELF-CONSISTENT - a generator bug that
        produced a valid frame with the wrong contents would pass both. Only
        comparing against the transmitted payload proves bit truth.

        One line per beat:  <data hex8> <tkeep hex1> <tlast 0|1>

        Packing must match rx_frame_buffer.vhd exactly: a metadata word first,
        then payload little-endian within each word, tkeep marking valid bytes
        of a partial final word.
        """
        lines = []
        for n, m in enumerate(manifest, start=1):
            meta = (n << 16) | ((m["seq"] & 0xF) << 12) | \
                   ((m["type"] & 0xF) << 8) | (m["len"] & 0xFF)

            pay = m["payload"]
            nwords = (len(pay) + 3) // 4
            last_is_meta = nwords == 0
            lines.append(f"{meta:08X} F {1 if last_is_meta else 0}")

            for w in range(nwords):
                chunk = pay[w * 4:w * 4 + 4]
                # little-endian: byte 0 in bits 7:0
                val = int.from_bytes(chunk.ljust(4, b"\x00"), "little")
                keep = (1 << len(chunk)) - 1
                last = 1 if w == nwords - 1 else 0
                lines.append(f"{val:08X} {keep:X} {last}")

        with open(filename, "w") as f:
            f.write("\n".join(lines) + "\n")
        print(f"[✓] Wrote {len(lines)} expected stream beats to {filename}")
        return lines

    def symbol_to_sample(self, k, timing_offset=0.0, ppm=0.0):
        """Output-sample index at which symbol k lands in ddc_input.dat.

        Two things move a symbol away from the naive k*sps:

          - lfilter() in upsample_and_filter() is causal, so pulse shaping
            delays everything by half the filter, span/2 symbols.
          - apply_timing_offset() resamples starting at a fractional phase and
            at a slightly wrong rate, so the mapping is offset AND scaled.

        From apply_timing_offset(), output sample n reads high-rate index
        offset*hi_sps + n*osr*(1+ppm*1e-6), and symbol k peaks at high-rate
        index k*hi_sps + span*hi_sps/2. Equating the two and cancelling osr:

            n = (k + span/2 - offset) * sps / (1 + ppm*1e-6)
        """
        return (k + self.span / 2.0 - timing_offset) * self.sps / (1.0 + ppm * 1e-6)

    def save_chunks(self, manifest, n_samples, gap_symbols=32, timing_offset=0.0,
                    ppm=0.0, filename="rx_chunks.txt"):
        """Sample ranges holding exactly one frame each, for PS-side playback.

        The hardware reason this file exists: rx_frame_buffer is a SINGLE
        store-and-forward buffer, and it backpressures rather than streaming -
        a frame arriving while the previous one is still draining is dropped
        and flagged in STATUS.OVERFLOW. MM2S plays at one sample per fabric
        clock (25 ns), so the 32-symbol inter-frame gap is about 3 us, and
        userspace cannot re-arm an S2MM transfer inside that. Pushing the
        whole file as one transfer therefore captures frame 1 and silently
        drops the rest.

        Splitting playback into one transfer per frame makes overflow
        impossible by construction rather than by timing luck, and gives the
        truth check the same granularity as rx_expected.txt.

        Boundaries are the MIDPOINTS of the idle gaps: each chunk carries its
        frame plus half a gap of lead-in (so the loops see silence before the
        preamble, as they would on a real re-acquisition) and half a gap of
        run-out (so the last symbols flush through the filter and framer
        before the transfer ends).

        One line per frame: <first sample> <count>
        """
        half_gap = gap_symbols / 2.0
        rows = []

        for i, m in enumerate(manifest):
            first_sym = m["start_symbol"] - (half_gap if i else self.span)
            last_sym = m["start_symbol"] + m["n_symbols"] + half_gap

            start = int(np.floor(self.symbol_to_sample(first_sym, timing_offset, ppm)))
            end = int(np.ceil(self.symbol_to_sample(last_sym, timing_offset, ppm)))

            start = max(0, start)
            end = min(n_samples, end)
            if end <= start:
                raise SystemExit(f"[!] frame {i + 1} maps to an empty sample range "
                                 f"({start}..{end}) - check sps/span/ppm")
            rows.append((start, end - start))

        with open(filename, "w") as f:
            f.write("# One playback chunk per frame: <first sample> <count>\n")
            f.write("# Indices into ddc_input.dat. Boundaries sit mid-gap so each\n")
            f.write("# chunk holds exactly one frame - see save_chunks() for why.\n")
            for start, count in rows:
                f.write(f"{start} {count}\n")
        print(f"[✓] Wrote {len(rows)} playback chunks to {filename}")
        return rows

    # =================================================================
    # Entry points
    # =================================================================

    def run_frames(self, n_frames=4, payload_len=16, gap_symbols=32,
                   preamble_bits=256, timing_offset=0.37, ppm=20.0,
                   freq_err_hz=None, snr_db=25.0, plot=True):
        """Generate a burst of real framed data through the whole TX model.

        Impairments are deliberate and each targets one recovery loop:

          freq_err_hz    residual carrier offset ON TOP of fs/4. ddc_fs_4
                         removes exactly fs/4, so without this the PLL sees a
                         perfectly centred signal and does nothing - the test
                         would pass without proving carrier recovery works.
          timing_offset  fractional symbol phase, so symbol instants do not
                         land on sample boundaries.
          ppm            sampling clock error, so the timing loop must keep
                         tracking rather than acquire once.
          snr_db         noise, so the CRC is actually doing a job.

        preamble_bits defaults to 256 (128 symbols), not the 32 the format
        nominally specifies. 32 bits is 16 symbols, and expecting a carrier
        loop AND a timing loop to both settle inside 16 symbols is optimistic -
        if acquisition proves reliable at a shorter lead-in, shorten it; if
        frames are missed, this is the first knob to turn.
        """
        rng = np.random.default_rng(self.seed)

        if freq_err_hz is None:
            # 0.1% of the symbol rate - small enough for a 2nd-order loop to
            # pull in, large enough that a broken loop shows up.
            freq_err_hz = 0.001 * self.symbol_rate

        print(f"[*] Building {n_frames} frames of {payload_len} B ...")
        frames = []
        for k in range(n_frames):
            frames.append({
                "payload": list(rng.integers(0, 256, payload_len).astype(int)),
                "type": FRAME_TYPE_DATA,
                "seq": k & 0xF,
            })

        symbols, manifest = self.build_burst(frames, gap_symbols=gap_symbols,
                                             preamble_bits=preamble_bits)
        print(f"    {len(symbols)} symbols total "
              f"({gap_symbols}-symbol gaps force re-acquisition between frames)")

        print(f"[*] Pulse shaping with {timing_offset:.2f}-symbol timing offset, "
              f"{ppm:.0f} ppm clock error ...")
        shaped = self.apply_timing_offset(symbols, offset_symbols=timing_offset,
                                          ppm=ppm)

        carrier = self.fs / 4 + freq_err_hz
        print(f"[*] Upconverting to {carrier / 1e3:.3f} kHz "
              f"(fs/4 + {freq_err_hz:.1f} Hz residual for the PLL to track) ...")
        rf = self.apply_frequency_offset(shaped, freq=carrier)

        # Headroom: RRC overshoot pushes the shaped envelope above the symbol
        # magnitude, and noise adds on top. Scaling to 0.5 of full scale keeps
        # the peaks off the rails - clipping would be indistinguishable from a
        # DSP bug in the waveform viewer.
        rf = rf / np.max(np.abs(rf))
        quantized = self.quantize(rf, headroom=0.5)
        quantized = self.add_awgn(quantized, snr_db).astype(np.int16)
        print(f"[*] Quantized with AWGN at {snr_db} dB SNR")

        self.save_to_file(quantized, "ddc_input.dat")
        self.save_symbols_to_file(symbols, "qpsk_symbols.dat")
        self.save_manifest(manifest, "rx_expected.txt")
        self.save_expected_stream(manifest, "rx_expected_stream.dat")
        self.save_chunks(manifest, len(quantized), gap_symbols=gap_symbols,
                         timing_offset=timing_offset, ppm=ppm)

        taps = self.rrc_taps_quantized(sps=self.sps // 2)
        self.check_filter_scaling(quantized, taps)

        if plot:
            self._plot_burst(quantized, symbols, manifest)

        return quantized, manifest

    def _plot_burst(self, quantized, symbols, manifest):
        fig, ax = plt.subplots(2, 1, figsize=(12, 6))

        ax[0].plot(quantized, linewidth=0.6)
        ax[0].set_title("Transmitted burst (quantized ADC input)")
        ax[0].set_xlabel("Sample index")
        ax[0].set_ylabel("Amplitude")
        for m in manifest:
            ax[0].axvspan(m["start_symbol"] * self.sps,
                          (m["start_symbol"] + m["n_symbols"]) * self.sps,
                          alpha=0.12, color="tab:green")
        ax[0].grid(True)

        n = min(400, len(quantized))
        ax[1].plot(quantized[:n], linewidth=0.8)
        ax[1].set_title(f"First {n} samples (preamble - constant-envelope "
                        f"alternating symbols)")
        ax[1].set_xlabel("Sample index")
        ax[1].grid(True)

        plt.tight_layout()
        plt.show()

    def run(self):
        """Original single-burst random-symbol stimulus, no framing.

        Kept for isolating the front end: it exercises the DDC, PLL and matched
        filter without needing sync, CRC or timing to work.
        """
        print("[*] Generating RRC filter...")
        rrc = self.generate_rrc_filter()

        print("[*] Generating QPSK symbols...")
        symbols = self.generate_symbols()
        self.save_symbols_to_file(symbols, filename="qpsk_symbols.dat")

        print("[*] Applying pulse shaping...")
        shaped = self.upsample_and_filter(symbols, rrc)

        print("[*] Applying frequency offset...")
        adc_input = self.apply_frequency_offset(shaped)

        print("[*] Quantizing to 16-bit signed integers...")
        quantized = self.quantize(adc_input)

        print("[*] Saving to file for VHDL testbench...")
        self.save_to_file(quantized, "ddc_input.dat")

        print("[*] Emitting matching RRC taps for the VHDL matched filter...")
        self.write_vhdl_coeffs("rrc_coeffs.vhd", rx_sps=self.sps // 2)

        print("[*] Plotting example waveform...")
        plt.figure(figsize=(10, 4))
        plt.plot(quantized[:300], label="Quantized ADC input")
        plt.title("Time Domain View of Input Samples")
        plt.xlabel("Sample Index")
        plt.ylabel("Amplitude")
        plt.grid(True)
        plt.legend()
        plt.tight_layout()
        plt.show()


if __name__ == "__main__":
    # span*sps + 1 must equal FILTER_LEN in dsp_pkg.vhd, so the RX filter is
    # genuinely matched to the TX pulse shape. span=17 gave 69 taps against a
    # 17-tap filter, which is why nothing matched.
    #
    # Only the RATIO carrier/fs matters to the hardware - the .dat file has no
    # time base, the DSP just consumes one sample per data_valid. So these are
    # really "0.25 cycles per sample" and "4 samples per symbol".
    #
    # Carrier near fs/4 rather than a small offset: with sps=4 the RRC occupies
    # (1/4)*(1+0.35) = 0.34 cycles/sample of bandwidth, so a near-DC carrier
    # puts half the signal below zero frequency and np.real() folds the image
    # straight back onto it. fs/4 centres it clear of both DC and Nyquist - and
    # matches what ddc_fs_4 expects.
    FS = 1_000_000
    gen = RRCWaveformGenerator(alpha=0.35, sps=4, span=4, num_symbols=100,
                               fs=FS, seed=1234)

    # Framed burst: 4 frames of real user data through the full receiver.
    gen.run_frames(n_frames=4, payload_len=16)

    # Front-end-only stimulus (no framing) is still available:
    #   gen.run()
