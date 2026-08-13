# RF/SDR Engineering Interview Prep Notes

This document covers the core topics typically asked in SDR, RF DSP, and communications systems interviews — with concise but deep explanations suitable for a senior embedded/RF DSP engineer.

---

# 1. FIR vs IIR Filters

## FIR (Finite Impulse Response)
**Characteristics**
- Impulse response length is finite.
- Always stable (no feedback loops).
- Can achieve *exact* linear phase.
- Implemented using feed-forward taps only.

**Advantages**
- Linear phase → predictable group delay (critical for QAM/OFDM).
- Unconditionally stable.
- Ideal for multirate DSP (decimators, channelizers).
- Robust in fixed-point implementations.

**Disadvantages**
- Many coefficients required for sharp transitions, but can utilize symmetry to reduce actual multiplies in MAC filter implementation
- Higher latency and computational cost.

---

## IIR (Infinite Impulse Response)
**Characteristics**
- Uses feedback paths → infinite impulse response.
- Can approximate analog filters with low order.
- Nonlinear phase.

**Advantages**
- Very computationally efficient.
- Small filter order achieves sharp cutoff.
- Good for audio, control loops, and narrowband filtering.

**Disadvantages**
- Can become unstable (pole locations matter).
- Nonlinear phase distorts modulated waveforms.
- Sensitive to coefficient quantization.

---

## Common Follow-Up Interview Questions
- Why is linear phase important in communication systems?
- Why are FIR filters preferred in channelizers and DDC chains?
- How do CIC filters differ from FIR filters?
- How do you maintain IIR stability in fixed-point hardware (FPGA/ASIC)?

---

# 2. SDR Processing Chain

## Typical SDR Receiver Chain
1. **RF Front End**
   - LNA, filters, attenuator/AGC.
   - Mixer & LO (unless direct-RF sampling).
   - Image rejection, anti-alias filtering.

2. **ADC (IF or Direct RF Sampling)**
   - Digitizes RF/IF.
   - Sampling clock phase noise important for high-frequency sampling.

3. **Digital Downconversion (DDC)**
   - Numerically-controlled oscillator (NCO).
   - Digital mixer → I/Q.
   - CIC decimator.
   - FIR / half-band decimators.

4. **Channel Filtering**
   - Matched filter
   - RRC (root raised cosine)
   - Pulse shaping to eliminate ISI.

5. **Timing Recovery**
   - Gardner or Mueller & Müller.
   - Farrow or polyphase interpolators.

6. **Carrier Recovery**
   - Costas loop or PLL.
   - CFO/phase offset estimation.

7. **Equalization**
   - LMS/MMSE/ZF equalizer.
   - DFE (decision feedback equalization).

8. **Demodulation & Decoding**
   - QAM/PSK demapper.
   - Deinterleaver.
   - LDPC / Turbo / Viterbi decoding.

---

## Follow-Up Interview Questions
- Walk through the DDC process in detail.
- Explain timing recovery algorithms.
- Explain symbol synchronization vs carrier synchronization.
- Why are CIC filters used before FIR filters in a multi-stage decimator?

---

# 3. RF Sampling Types

There are three core types of RF sampling used in digital radios:

## 1. Direct (Uniform) RF Sampling
- ADC directly samples the RF carrier.
- Aliasing handled digitally via DDC.
- Requires high-speed GSPS ADCs.
- Used in modern wideband SDRs.

## 2. Bandpass (Subsampling)
- Sample below Nyquist on purpose.
- High-frequency band folds into Zone 1.
- Requires clean anti-alias filtering.
- Useful for IF receivers and power-efficient SDRs.

## 3. Compressive / Non-Uniform Sampling
- Uses random or multi-coset sampling.
- Only works when the spectrum is sparse.
- Used in EW/ESM ultra-wideband sensing.

---

## Additional Techniques Often Asked
- **Time-interleaved ADCs** (architecture for high sample rates).
- **Digital LO + DDC** as replacement for analog mixers.
- **Aperture jitter and its impact on RF SNR**.

---

# 4. Compensating for ISI (Inter-Symbol Interference)

## Methods for ISI Mitigation
### 1. Nyquist Pulse Shaping
- Transmitter uses RRC filter.
- Receiver uses matched RRC filter.
- Produces zero-ISI at symbol boundaries.

### 2. Equalization
- **Linear equalizers:** ZF, MMSE.
- **Adaptive equalizers:** LMS, RLS, NLMS.
- **Decision Feedback Equalizer (DFE).**

### 3. Symbol Timing Recovery
- Gardner or Mueller & Müller algorithm.
- Fractional delay filters (Farrow).

### 4. OFDM Approaches
- Use pilots to estimate channel.
- Perform channel equalization per subcarrier.

---

## Follow-Up Questions Likely
- What is the purpose of the roll-off factor in RRC?
- Compare ZF vs MMSE equalizers.
- Why is DFE effective against post-cursor ISI?

---

# 5. Nyquist Zones & 3rd Nyquist Zone Formula

## Definition
A Nyquist zone is a half-sampling-rate interval:

\[
\text{Zone } n = \left[(n-1)\frac{f_s}{2},\; n\frac{f_s}{2}\right]
\]

## 3rd Nyquist Zone
\[
\text{Zone 3} = \left[f_s,\; \frac{3f_s}{2}\right]
\]

### Aliasing Rules Summary
- Even zones mirror (spectral inversion).
- Odd zones maintain orientation.
- All zones fold into Zone 1 after sampling.

---

# 6. Zero-Span Setting on a Spectrum Analyzer

## What Zero Span Does
Zero-span mode stops frequency sweeping and locks LO at one frequency.  
The display becomes **power vs time**, not frequency vs amplitude.

You are essentially using the spectrum analyzer like:
- A time-domain envelope detector.
- A power meter with time resolution.

## Common Uses
- View TDMA burst timing.
- Measure radar pulse width.
- Observe transmitter settling time.
- Validate hopping dwell time.
- Check AGC attack/decay behavior.
- Measure amplitude modulation envelopes.

## Follow-Up Questions
- How does RBW/VBW affect zero-span?
- Why is zero-span insufficient for very fast transient signals?

---

# 7. Shannon’s Theorem

## Shannon–Hartley Capacity Formula
\[
C = B \log_2\left(1 + \frac{S}{N}\right)
\]

Where:
- \( C \) = maximum data rate (bits/sec)
- \( B \) = channel bandwidth (Hz)
- \( S/N \) = linear signal-to-noise ratio

## Key Points
- Absolute theoretical limit — no modulation or code can exceed it.
- QAM, OFDM, DSSS all stay below the Shannon limit.
- LDPC and Turbo codes approach capacity within ~0.5–1 dB.

---
# SDR FPGA Pipeline – Interview Diagram (Markdown)

This file gives you **diagram-first** SDR pipelines you can drop straight into VS Code and talk through in an FPGA interview.

---

## 1. Top-Level SDR System (Rx + Tx Path)

```mermaid
flowchart LR
    subgraph RF_Frontend[RF Front-End]
        RFIN[RF In] --> LNA[LNA]
        LNA --> BPF[Bandpass Filter]
        BPF --> ATT[ATT / AGC]
    end

    RF_Frontend --> ADC[High-Speed ADC]

    subgraph FPGA_RX[FPGA – Rx DSP Chain]
        ADC -->|JESD/LVDS| DDC_IN[ADC IF Samples]
        DDC_IN --> RX_DSP[Rx DSP Pipeline]
    end

    FPGA_RX -->|AXI-Stream| CPU_RX[SoC CPU / Embedded SW]
    CPU_RX --> APP[Waveform / Networking / Control App]

    APP --> CPU_TX[Tx Baseband Processing]
    CPU_TX -->|AXI-Stream| FPGA_TX[FPGA – Tx DSP Chain]

    subgraph FPGA_TX[FPGA – Tx DSP Chain]
        TX_DSP[Tx DSP Pipeline] --> DAC_IN[DAC Baseband / IF]
    end

    DAC_IN --> DAC[High-Speed DAC]

    subgraph RF_OUT_FE[RF Out Front-End]
        DAC --> LPF_TX[Reconstruction / LPF]
        LPF_TX --> PA[PA]
        PA --> RFOUT[RF Out (Antenna)]
    end
```

flowchart LR
    ADC[ADC Samples (FS, real)] --> DC_CORR[DC Offset / IQ Cal / Dither]

    DC_CORR --> NCO_MIX[NCO + Complex Mixer<br/>(Digital Downconversion)]
    NCO_MIX --> CIC[CIC Decimator]
    CIC --> HB1[Halfband / FIR Decimator 1]
    HB1 --> HB2[Halfband / FIR Decimator 2]
    HB2 --> CH_FILT[Channel Filter / RRC Matched Filter]

    CH_FILT --> AGC[AGC (Digital)]
    AGC --> TIM_REC[Timing Recovery<br/>(Gardner / M&M + Interpolator)]
    TIM_REC --> EQ[Equalizer<br/>(ZF/MMSE/DFE/LMS)]

    EQ --> DEMOD[Symbol Demapper<br/>(QPSK/QAM/FSK)]
    DEMOD --> DEINT[Deinterleaver]
    DEINT --> FEC[Decoder<br/>(LDPC/Turbo/Viterbi)]
    FEC --> RX_FRAMER[Frame / Packet Deframer]

    RX_FRAMER -->|AXI-Stream / AXI-MM| CPU[Embedded CPU / PS]

flowchart LR
    CPU[Embedded CPU / PS] -->|AXI-Stream / AXI-MM| TX_FRAMER[TX Framer<br/>(Headers, Preamble, Pilot Insertion)]
    TX_FRAMER --> FEC_ENC[FEC Encoder<br/>(LDPC/Turbo/Conv.)]
    FEC_ENC --> INTL[Interleaver / Scrambler]
    INTL --> MOD[Symbol Mapper<br/>(QPSK/QAM/FSK/etc.)]

    MOD --> PULSE_SHAPE[Pulse Shaping Filter<br/>(RRC, Nyquist)]
    PULSE_SHAPE --> UP1[FIR / Halfband Interpolator 1]
    UP1 --> UP2[FIR / Halfband Interpolator 2]
    UP2 --> DUC[Digital Upconverter<br/>(NCO + Complex Mixer)]

    DUC --> SCALE[Digital Gain / Crest Factor Reduction (CFR)]
    SCALE --> DAC_IN[DAC Interface Samples]
    DAC_IN --> DAC[DAC]

flowchart TB
    subgraph PL[Programmable Logic (FPGA Fabric)]
        ADC_IF[ADC IF / JESD RX] --> DDC_blk[DDC + Decimators]
        DDC_blk --> RX_FILT[Channel Filter / RRC]
        RX_FILT --> RX_DSP[Timing / Equalization / Demod]

        RX_DSP --> AXIS2MM[AXI-Stream to AXI-MM<br/>(DMA / FIFO)]
        AXIS2MM --> HP_PORT[PS HP Port / DDR]

        PS_CFG[AXI-Lite Control Regs] --> DDC_blk
        PS_CFG --> RX_FILT
        PS_CFG --> RX_DSP
        PS_CFG --> DUC_blk
        PS_CFG --> TX_FILT
    end

    subgraph PS[Processing System (e.g., ARM A9/R5/A53)]
        HP_PORT --> DDR[Shared DDR Memory]
        DDR --> SW[Waveform SW / MAC / Control]
        SW --> PS_CFG
    end

# End of Document
