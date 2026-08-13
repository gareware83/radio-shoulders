import numpy as np
import matplotlib.pyplot as plt 
from waveform_generator import RRCWaveformGenerator

wfg = RRCWaveformGenerator()
# Parameters
ADDR_BITS = 8             # quarter-wave table: 2^8 = 256 entries, 8-bit addra
AMP_BITS  = 16            # output width
AMP_MAX   = 2**(AMP_BITS-1) - 1

# Generate phase values
N = 2**ADDR_BITS
phases = np.arange(N) * np.pi /(2* N)
phases_tone = np.arange(N*10) * 2 * np.pi/(N)
# Generate sine and cosine for bram as nco source
sine = np.round(AMP_MAX * np.sin(phases)).astype(np.int16)
cos  = np.round(AMP_MAX * np.cos(phases)).astype(np.int16)

#generate a full test set of pure tones to exercies the phase correction
sine_tone = np.round(AMP_MAX * np.sin(phases_tone)).astype(np.int16)
cos_tone  = np.round(AMP_MAX * np.cos(phases_tone)).astype(np.int16)

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

# Catch a short/truncated table at generation time rather than as a constant
# phase offset in hardware.
check("sine", sine, N)
check("cos",  cos,  N)

write_coe("sine.coe", sine)
write_coe("cos.coe", cos)

write_mem("sine.mem", sine, AMP_BITS)
write_mem("cos.mem",  cos,  AMP_BITS)

wfg.save_to_file(samples=sine_tone, filename="pure_sine.dat")
wfg.save_to_file(samples=cos_tone, filename="pure_cos.dat")

print("[*] Plotting example waveform...")
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








































