"""Floating-point reference receiver for the framed burst stimulus.

Purpose: prove that ddc_input.dat is actually decodable, and that the frame
format, CRC, QPSK mapping and phase-ambiguity resolution in pkg.vhd /
frame_sync.vhd are all mutually consistent - BEFORE spending time in RTL
simulation. If this model cannot recover the frames, no amount of VHDL
debugging will help, because the stimulus or the format definition is wrong.

This is deliberately NOT a model of the hardware. It does not implement the
carrier PLL or the Gardner loop; it uses the known frequency and timing offsets
directly. That isolates the question it exists to answer - "is the framing
self-consistent?" - from the question the RTL simulation answers - "do the
loops converge?". Mixing the two makes a failure impossible to attribute.

Run after waveform_generator.py:
    python3 rx_model.py
"""

import numpy as np

from waveform_generator import (
    SYNC_WORD, crc16_ccitt, word_to_bits,
)

SPS_RX = 2          # after ddc_fs_4's decimate-by-2
FS = 1_000_000


def ddc_fs_4(x):
    """Model of ddc_fs_4.vhd: fs/4 quadrature mix, decimate by 2.

    The mixer holds I on even phases and emits the pair on odd phases:
        I = [x0, -x2, x4, -x6, ...]    Q = [-x1, x3, -x5, x7, ...]

    Note the negated Q. Downconversion multiplies by exp(-j*w*n) = cos - j*sin.
    Using +sin produces the CONJUGATE baseband, which is a reflected
    constellation - and a reflection is not one of the four rotations
    frame_sync searches, so sync can never fire. This model found that bug in
    the RTL; see the note in ddc_fs_4.vhd.
    """
    ev, od = x[0::2], x[1::2]
    n = min(len(ev), len(od))
    i = ev[:n] * np.resize([1, -1], n)
    q = od[:n] * np.resize([-1, 1], n)
    return i + 1j * q


def rrc(alpha, sps, span):
    N = span * sps
    t = np.arange(-N // 2, N // 2 + 1) / sps
    h = np.zeros_like(t)
    for k, tk in enumerate(t):
        if tk == 0.0:
            h[k] = 1.0 - alpha + 4 * alpha / np.pi
        elif abs(tk) == 1 / (4 * alpha):
            h[k] = (alpha / np.sqrt(2)) * (
                (1 + 2 / np.pi) * np.sin(np.pi / (4 * alpha)) +
                (1 - 2 / np.pi) * np.cos(np.pi / (4 * alpha)))
        else:
            num = np.sin(np.pi * tk * (1 - alpha)) + \
                4 * alpha * tk * np.cos(np.pi * tk * (1 + alpha))
            den = np.pi * tk * (1 - (4 * alpha * tk) ** 2)
            h[k] = num / den
    return h / np.sqrt(np.sum(h ** 2))


def rotate_qpsk(bits, k):
    """Same rotation table as rotate_qpsk() in pkg.vhd, on a bit list.

    Rotating (I,Q) by +90 gives (-Q, I), which in sign bits is:
        k=0 (b1,b0)   k=1 (~b0,b1)   k=2 (~b1,~b0)   k=3 (b0,~b1)
    """
    out = []
    for n in range(0, len(bits), 2):
        b1, b0 = bits[n], bits[n + 1]
        if k % 4 == 0:
            out += [b1, b0]
        elif k % 4 == 1:
            out += [1 - b0, b1]
        elif k % 4 == 2:
            out += [1 - b1, 1 - b0]
        else:
            out += [b0, 1 - b1]
    return out


def slice_qpsk(syms):
    """Hard decision, matching qpsk_slicer.vhd: the two sign bits."""
    bits = []
    for s in syms:
        bits.append(0 if s.real >= 0 else 1)
        bits.append(0 if s.imag >= 0 else 1)
    return bits


def find_frames(bits):
    """Model of frame_sync.vhd, including the four-rotation sync search."""
    sync_rot = [rotate_qpsk(word_to_bits(SYNC_WORD, 32), k) for k in range(4)]
    frames = []
    n = 0

    while n + 32 <= len(bits):
        window = bits[n:n + 32]
        match = next((k for k in range(4) if window == sync_rot[k]), None)

        if match is None:
            n += 2          # advance one SYMBOL, not one bit
            continue

        # Derotate everything after the sync word by the inverse rotation
        inv = (4 - match) % 4
        p = n + 32
        body = rotate_qpsk(bits[p:], inv)

        if len(body) < 16:
            break
        hdr_bits = body[:16]
        hdr = int("".join(map(str, hdr_bits)), 2)
        ftype, ln, seq = (hdr >> 12) & 0xF, (hdr >> 4) & 0xFF, hdr & 0xF

        need = 16 + ln * 8 + 16
        if len(body) < need:
            break

        pay_bits = body[16:16 + ln * 8]
        crc_bits = body[16 + ln * 8:need]
        crc_rx = int("".join(map(str, crc_bits)), 2)
        crc_calc = crc16_ccitt(hdr_bits + pay_bits)

        payload = bytes(int("".join(map(str, pay_bits[i:i + 8])), 2)
                        for i in range(0, len(pay_bits), 8))

        frames.append({
            "type": ftype, "seq": seq, "len": ln, "payload": payload,
            "crc_rx": crc_rx, "crc_calc": crc_calc, "ok": crc_rx == crc_calc,
            "rotation": match,
        })

        n = p + need
    return frames


def parse_expected(path="rx_expected.txt"):
    out, cur = [], None
    for line in open(path):
        line = line.strip()
        if line.startswith("frame "):
            cur = {}
            out.append(cur)
        elif cur is not None and line and not line.startswith("#"):
            key, _, val = line.partition(" ")
            cur[key] = val.strip()
    return out


def main(freq_err_hz=250.0, alpha=0.35, span=4):
    x = np.loadtxt("ddc_input.dat")
    print(f"[*] Read {len(x)} samples from ddc_input.dat")

    bb = ddc_fs_4(x)

    # Stand in for the carrier PLL using the known residual offset. The DDC
    # removes exactly fs/4; what is left is the deliberate error the RTL's PLL
    # has to track. Sample rate here is fs/2 after decimation.
    t = np.arange(len(bb)) / (FS / 2)
    bb = bb * np.exp(-2j * np.pi * freq_err_hz * t)

    h = rrc(alpha, SPS_RX, span)
    mf = np.convolve(bb, h)
    print(f"[*] Matched filtered: {len(mf)} samples at {SPS_RX} sps")

    # Stand in for the Gardner loop by trying both sample phases and keeping
    # whichever gives the tighter constellation. The RTL has to FIND this;
    # here it is only in the way.
    best, best_metric = None, -1
    for phase in range(SPS_RX):
        syms = mf[phase::SPS_RX]
        m = np.mean(np.abs(syms.real)) + np.mean(np.abs(syms.imag))
        if m > best_metric:
            best, best_metric = syms, m
    print(f"[*] Symbol decimation: {len(best)} symbols")

    frames = find_frames(slice_qpsk(best))
    expected = parse_expected()

    print(f"\n[*] Recovered {len(frames)} frames, expected {len(expected)}\n")

    ok = len(frames) == len(expected)
    for n, f in enumerate(frames):
        exp = expected[n] if n < len(expected) else {}
        pay_ok = f["payload"].hex() == exp.get("payload", "")
        good = f["ok"] and pay_ok
        ok &= good
        print(f"  frame {n + 1}: type=0x{f['type']:x} seq={f['seq']} "
              f"len={f['len']} rot={f['rotation']*90}deg "
              f"crc={'OK' if f['ok'] else 'FAIL'} "
              f"payload={'match' if pay_ok else 'MISMATCH'}")
        if not pay_ok:
            print(f"      got      {f['payload'].hex()}")
            print(f"      expected {exp.get('payload', '(none)')}")

    # The frames above all arrive at rotation 0, which leaves the entire
    # phase-ambiguity path untested - and that path is the one thing standing
    # between a locked carrier loop and readable bits. Force each rotation.
    print("\n[*] Phase-ambiguity sweep (a carrier loop may lock to any of these):")
    rot_ok = True
    for k in range(4):
        rotated = best * np.exp(1j * np.pi / 2 * k)
        f = find_frames(slice_qpsk(rotated))
        good = len(f) == len(expected) and all(x["ok"] for x in f)
        detected = sorted({x["rotation"] for x in f})
        rot_ok &= good
        print(f"      lock at {k * 90:3d}deg -> {len(f)} frames, "
              f"detected rot={detected}, crc {'all OK' if good else 'FAIL'}")
    ok &= rot_ok

    print("\n" + ("[PASS] stimulus and frame format are self-consistent"
                  if ok else "[FAIL] see mismatches above"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
