--RF → ADC → DDC → Matched Filter → Timing → Slice → Frame → DDR
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.pkg.all;

entity dsp_top is
    Generic (
        G_SIM    : boolean := FALSE;
        G_PLL    : boolean := True;
        G_TIMING : boolean := True     -- bypass Gardner (see note below)
    );
    Port (
        SYS_CLK    : in  std_logic;
        ARST       : in  std_logic;
        ADC_IN     : in  signed(15 downto 0);
        data_valid : in  std_logic;

        -- control, from the register block
        rx_enable  : in  std_logic;
        clr_stats  : in  std_logic;

        -- recovered frames -> AXI DMA S2MM -> DDR
        rx_tdata   : out std_logic_vector(31 downto 0);
        rx_tkeep   : out std_logic_vector(3 downto 0);
        rx_tlast   : out std_logic;
        rx_tvalid  : out std_logic;
        rx_tready  : in  std_logic;

        -- status, back to the register block
        frame_count : out unsigned(15 downto 0);
        err_count   : out unsigned(15 downto 0);
        rx_len      : out unsigned(7 downto 0);
        overflow    : out std_logic;
        in_frame    : out std_logic;

        -- lock quality, for diagnostics and as a tuning objective
        sync_count  : out unsigned(15 downto 0);
        qual_min    : out unsigned(31 downto 0);
        qual_max    : out unsigned(31 downto 0);
        qual_syms   : out unsigned(31 downto 0);

        -- Tap points for the diagnostic sample sniffer (sample_sniffer.vhd,
        -- instantiated in system_top). Named tap_* rather than reusing the
        -- internal signal names below, since a port and an architecture
        -- signal cannot share a name - these are plain concurrent copies of
        -- ddc_i/q, filtered_i/q, gard_i/q and sym_i/q, added for visibility
        -- only and driving nothing else in this entity.
        tap_ddc_i        : out signed(15 downto 0);
        tap_ddc_q        : out signed(15 downto 0);
        tap_ddc_valid    : out std_logic;

        tap_pll_i        : out signed(15 downto 0);   -- post-PLL (= sym_i/q,
        tap_pll_q        : out signed(15 downto 0);   -- the slicer's input
        tap_pll_valid    : out std_logic;              -- either way G_PLL
                                                        -- is set)

        tap_filtered_i     : out signed(15 downto 0);  -- post matched filter,
        tap_filtered_q     : out signed(15 downto 0);  -- BEFORE Gardner/PLL
        tap_filtered_valid : out std_logic;

        tap_sym_i        : out signed(15 downto 0);    -- post timing recovery
        tap_sym_q        : out signed(15 downto 0);    -- (= gard_i/q), BEFORE
        tap_sym_valid    : out std_logic;              -- the PLL now

        -- Hardware/sim debug trace only (docs/zybo_work.md's hardware-debug
        -- section) - same signals the hardware ILA capture already taps via
        -- mark_debug, exposed here as real ports so test_dsp_top.vhd's
        -- trace dump can reach them without a VHDL-2008 external name
        -- (xsim 2022.2 crashes on those reaching into an if-generate region).
        dbg_mu           : out unsigned(31 downto 0);
        dbg_incr         : out unsigned(31 downto 0);
        dbg_timing_err   : out signed(31 downto 0);
        dbg_u            : out signed(31 downto 0);
        dbg_phase_err    : out signed(31 downto 0);
        dbg_nco_sin      : out signed(15 downto 0);
        dbg_nco_cos      : out signed(15 downto 0);
        dbg_bits_valid   : out std_logic;
        dbg_sliced_bits  : out std_logic_vector(1 downto 0);
        dbg_fb_start     : out std_logic;
        dbg_fb_done      : out std_logic;
        dbg_fb_ok        : out std_logic;
        dbg_fb_len       : out unsigned(7 downto 0)
    );
end dsp_top;

architecture Behavioral of dsp_top is

-- Chain, in series:
--
--   ADC_IN (real, carrier at fs/4)
--     -> ddc_fs_4        coarse downconversion, decimate by 2 (4 sps -> 2 sps)
--     -> matched_filter  now genuinely at baseband, still 2 sps
--     -> gardner         symbol timing recovery, 2 sps -> 1 sps
--     -> pll_2nd_order   residual frequency/phase, fine carrier recovery
--     -> qpsk_slicer     hard decision, 1 symbol -> 2 bits
--     -> frame_sync      sync word, phase ambiguity, header, payload, CRC
--     -> rx_frame_buffer store-and-forward, 32-bit stream to the DMA
--
-- The two recovery loops are independent and both are required. The carrier
-- loop fixes WHAT the samples are; the timing loop fixes WHEN they are taken.
-- A perfect carrier lock sampled at the wrong instant still yields no bits.
--
-- The DDC/PLL stages used to be alternative branches selected by G_PLL, so the
-- PLL path had no downconversion at all - the matched filter was fed a signal
-- still at the fs/4 carrier, well above the RRC's cutoff, and could only
-- attenuate it rather than produce symbols.
--
-- The split of labour matters: the DDC removes the bulk carrier with nothing
-- but sign flips, leaving the PLL to track a small residual offset, which is
-- what a 2nd-order loop is good at. Asking it to acquire from DC all the way
-- to fs/4 is the fragile case.
--
-- PLL moved TWICE now. First DDC -> PLL -> filter -> gardner (original),
-- then DDC -> filter -> PLL -> gardner (matched filter ahead of the PLL, to
-- remove ISI). That second move only bought a ~13% reduction in the PLL's
-- steady-state jitter (test_bench/loop_model.py, run_pll_closed_loop) and
-- real hardware/sim lock quality didn't move outside noise (98 -> 104 /1000).
-- The actual cause wasn't ISI: pd_proc's decision-directed detector runs on
-- EVERY 2 sps sample, and even a perfectly ISI-free raised-cosine pulse is
-- near a NULL at the sample exactly between two symbol peaks - that's a
-- SAMPLING-INSTANT problem, which matched filtering cannot fix no matter
-- where it sits in the chain. Only timing recovery knows which instant is
-- which, so the PLL now runs on Gardner's OUTPUT (gard_i/q, 1 sps,
-- always on-peak) instead of the 2 sps stream feeding Gardner.
--
-- This is safe to reorder because Gardner's TED is close to carrier-phase
-- independent by design - it's the reason the docs already give for using
-- Gardner over a data-aided TED ("works before anything is demodulated, so
-- it can bootstrap") - confirmed in this codebase's own closed-loop model,
-- which never applied carrier correction ahead of Gardner in any of its
-- passing runs. The PLL now gets exactly the clean, ISI-free, on-peak
-- samples it always needed, at the cost of one extra pipeline stage of
-- carrier-tracking latency (Gardner's own acquisition transient) before
-- carrier lock can begin.
signal ddc_i, ddc_q   : signed(15 downto 0);
signal ddc_valid      : std_logic;

signal filtered_i     : signed(15 downto 0);
signal filtered_q     : signed(15 downto 0);
signal filtered_valid : std_logic;

-- Symbol-timed (1 sps) samples, still carrier-uncorrected: Gardner's output
-- if G_TIMING, otherwise the matched filter's output passed straight through
-- (see timing_gen's bypass note - only valid for a testbench already at 1
-- sps).
signal gard_i, gard_q : signed(15 downto 0);
signal gard_valid     : std_logic;
signal timing_err     : signed(31 downto 0);

signal pll_i, pll_q   : signed(15 downto 0);
signal pll_valid      : std_logic;

-- Final, carrier-corrected symbol stream feeding the slicer: the PLL's
-- output if G_PLL, otherwise gard_i/q passed straight through.
signal sym_i, sym_q   : signed(15 downto 0);
signal sym_valid      : std_logic;

signal bits_valid     : std_logic;
signal sliced_bits    : std_logic_vector(1 downto 0);
signal sym_mag        : unsigned(16 downto 0);

signal fb_byte_valid  : std_logic;
signal fb_byte_data   : std_logic_vector(7 downto 0);
signal fb_start       : std_logic;
signal fb_done        : std_logic;
signal fb_ok          : std_logic;
signal fb_len         : unsigned(7 downto 0);
signal fb_type        : std_logic_vector(3 downto 0);
signal fb_seq         : std_logic_vector(3 downto 0);

-- Hardware debug (ILA) round 1 - see system_top.vhd's own mark_debug block
-- for the CDC/reset half of this; these are the chain-internal signals that
-- answer "is the loop actually converging on real hardware, and does a
-- frame ever internally complete" - fb_ok/fb_done bracket each attempted
-- frame, timing_err/gard_valid and pll_valid bracket the two recovery loops.
attribute mark_debug : string;
attribute mark_debug of ddc_valid      : signal is "true";
attribute mark_debug of filtered_valid : signal is "true";
attribute mark_debug of gard_valid     : signal is "true";
attribute mark_debug of timing_err     : signal is "true";
attribute mark_debug of pll_valid      : signal is "true";
attribute mark_debug of sym_valid      : signal is "true";
attribute mark_debug of bits_valid     : signal is "true";
attribute mark_debug of sliced_bits    : signal is "true";
attribute mark_debug of fb_start       : signal is "true";
attribute mark_debug of fb_done        : signal is "true";
attribute mark_debug of fb_ok          : signal is "true";
attribute mark_debug of fb_len         : signal is "true";

begin

------------------------------------------------------------------
-- Coarse downconversion: fs/4 quadrature mixing, decimate by 2
------------------------------------------------------------------
inst_ddc: entity work.ddc_fs_4
    port map (
         clk      => SYS_CLK
        ,rst      => ARST
        ,x_in     => ADC_IN
        ,valid_in => data_valid
        ,i_out    => ddc_i
        ,q_out    => ddc_q
        ,valid_out=> ddc_valid
    );

------------------------------------------------------------------
-- Matched filter, now at 2 samples/symbol. Runs on the DDC's raw output -
-- BEFORE carrier recovery, not after (see the signal-declaration comment
-- above for why).
------------------------------------------------------------------
inst_filter : entity work.matched_filter_rrc
    port map (
        clk        => SYS_CLK,
        rst        => ARST,
        i_in       => ddc_i,
        q_in       => ddc_q,
        valid_in   => ddc_valid,
        i_out      => filtered_i,
        q_out      => filtered_q,
        valid_out  => filtered_valid
    );

------------------------------------------------------------------
-- Symbol timing recovery: 2 sps -> 1 sps at the recovered instant. Runs on
-- the matched filter's output DIRECTLY, still carrier-uncorrected - see the
-- signal-declaration comment above for why that's safe.
--
-- G_TIMING = FALSE is NOT a "no timing offset" mode - it assumes the stream is
-- already at one sample per symbol AND correctly aligned, which is only true
-- for a synthetic testbench feeding symbols directly. On anything from the
-- matched filter it halves the symbol rate and samples arbitrarily. Use it to
-- isolate the slicer and framer from loop behaviour, nothing else.
------------------------------------------------------------------
timing_gen: if G_TIMING = True generate

    inst_timing : entity work.timing_recovery_gardner
        port map (
             clk        => SYS_CLK
            ,rst        => ARST
            ,valid_in   => filtered_valid
            ,i_in       => filtered_i
            ,q_in       => filtered_q
            ,valid_out  => gard_valid
            ,i_out      => gard_i
            ,q_out      => gard_q
            ,timing_err => timing_err
            ,dbg_mu     => dbg_mu
            ,dbg_incr   => dbg_incr
        );

else generate

    gard_i      <= filtered_i;
    gard_q      <= filtered_q;
    gard_valid  <= filtered_valid;
    timing_err  <= (others => '0');
    dbg_mu      <= (others => '0');
    dbg_incr    <= (others => '0');

end generate;

------------------------------------------------------------------
-- Fine carrier recovery. Runs on Gardner's OUTPUT now (1 sps, always
-- on-peak) rather than the 2 sps stream feeding it - see the
-- signal-declaration comment above for why. G_PLL bypasses this stage -
-- useful for isolating timing recovery from carrier-loop behaviour while
-- debugging.
------------------------------------------------------------------
pll_gen: if G_PLL = True generate

    inst_pll: entity work.pll_2nd_order
        port map (
             clk           => SYS_CLK
            ,rst           => ARST
            ,data_valid    => gard_valid
            ,I_in          => gard_i
            ,Q_in          => gard_q
            ,I_out         => pll_i
            ,Q_out         => pll_q
            ,dbg_u         => dbg_u
            ,dbg_phase_err => dbg_phase_err
            ,dbg_nco_sin   => dbg_nco_sin
            ,dbg_nco_cos   => dbg_nco_cos
        );

    -- pll_2nd_order has no valid output: its phase detector registers
    -- I_rot/Q_rot, so the data is one clock behind its input. Delay the
    -- strobe to match rather than reusing gard_valid directly.
    pll_valid_proc : process (SYS_CLK)
    begin
        if rising_edge(SYS_CLK) then
            if ARST = '1' then
                pll_valid <= '0';
            else
                pll_valid <= gard_valid;
            end if;
        end if;
    end process;

    sym_i     <= pll_i;
    sym_q     <= pll_q;
    sym_valid <= pll_valid;

else generate  -- PLL bypassed: straight from Gardner

    sym_i     <= gard_i;
    sym_q     <= gard_q;
    sym_valid <= gard_valid;
    dbg_u         <= (others => '0');
    dbg_phase_err <= (others => '0');
    dbg_nco_sin   <= (others => '0');
    dbg_nco_cos   <= (others => '0');

end generate;

------------------------------------------------------------------
-- Hard decision: 1 symbol -> 2 bits
------------------------------------------------------------------
inst_slicer : entity work.qpsk_slicer
    port map (
         clk       => SYS_CLK
        ,rst       => ARST
        ,valid_in  => sym_valid
        ,i_in      => sym_i
        ,q_in      => sym_q
        ,valid_out => bits_valid
        ,bits_out  => sliced_bits
        ,mag_out   => sym_mag
    );

------------------------------------------------------------------
-- Frame recovery: sync word (and with it the carrier phase
-- ambiguity), header, payload, CRC
------------------------------------------------------------------
inst_frame : entity work.frame_sync
    port map (
         clk         => SYS_CLK
        ,rst         => ARST
        ,enable      => rx_enable
        ,valid_in    => bits_valid
        ,bits_in     => sliced_bits
        ,byte_valid  => fb_byte_valid
        ,byte_data   => fb_byte_data
        ,frame_start => fb_start
        ,frame_done  => fb_done
        ,frame_ok    => fb_ok
        ,frame_len   => fb_len
        ,frame_type  => fb_type
        ,frame_seq   => fb_seq
        ,in_frame    => in_frame
        ,sync_count  => sync_count
    );

------------------------------------------------------------------
-- Lock quality, measured on the recovered symbols. Taps the slicer
-- input, not its output - the decision throws away exactly the
-- information this needs.
------------------------------------------------------------------
inst_qual : entity work.rx_quality
    port map (
         clk       => SYS_CLK
        ,rst       => ARST
        ,clr       => clr_stats
        ,valid_in  => sym_valid
        ,i_in      => sym_i
        ,q_in      => sym_q
        ,sum_min   => qual_min
        ,sum_max   => qual_max
        ,sym_count => qual_syms
    );

------------------------------------------------------------------
-- Store-and-forward buffer -> DMA S2MM -> DDR
------------------------------------------------------------------
inst_rxbuf : entity work.rx_frame_buffer
    port map (
         clk         => SYS_CLK
        ,rst         => ARST
        ,clr_stats   => clr_stats
        ,byte_valid  => fb_byte_valid
        ,byte_data   => fb_byte_data
        ,frame_start => fb_start
        ,frame_done  => fb_done
        ,frame_ok    => fb_ok
        ,frame_len   => fb_len
        ,frame_type  => fb_type
        ,frame_seq   => fb_seq
        ,m_tdata     => rx_tdata
        ,m_tkeep     => rx_tkeep
        ,m_tlast     => rx_tlast
        ,m_tvalid    => rx_tvalid
        ,m_tready    => rx_tready
        ,frame_count => frame_count
        ,err_count   => err_count
        ,overflow    => overflow
        ,rx_len      => rx_len
    );

------------------------------------------------------------------
-- Sniffer tap points - plain copies, drive nothing else in this entity.
-- tap_pll_i/q come from sym_i/q rather than pll_i/q: sym_i/q is the
-- slicer's actual input either way the G_PLL generate resolves, where
-- pll_i/q is only driven inside the G_PLL=true branch and would read 'U' in
-- simulation with the PLL bypassed.
--
-- Pipeline order is now ddc -> filtered -> gard -> pll (PLL moved AFTER
-- Gardner, its second move - see the signal-declaration comment above), so
-- tap_sym (Gardner's own 1 sps output, gard_i/q) now sits BEFORE tap_pll
-- (the final, carrier-corrected sym_i/q) in the chain - the reverse of the
-- original ddc -> pll -> filtered -> sym order. The tap names still mean
-- what they say (post-matched-filter, post-PLL, post-timing-recovery) -
-- only their relative position and underlying signal moved.
------------------------------------------------------------------
tap_ddc_i     <= ddc_i;
tap_ddc_q     <= ddc_q;
tap_ddc_valid <= ddc_valid;

tap_filtered_i     <= filtered_i;
tap_filtered_q     <= filtered_q;
tap_filtered_valid <= filtered_valid;

tap_sym_i     <= gard_i;
tap_sym_q     <= gard_q;
tap_sym_valid <= gard_valid;

tap_pll_i     <= sym_i;
tap_pll_q     <= sym_q;
tap_pll_valid <= sym_valid;

-- debug trace passthrough, see the port declarations' comment. mu/incr and
-- u/phase_err/nco_sin/nco_cos are wired directly in the timing_gen/pll_gen
-- generate blocks above (both branches, including bypass) since they come
-- from inside those conditional regions.
dbg_timing_err  <= timing_err;
dbg_bits_valid  <= bits_valid;
dbg_sliced_bits <= sliced_bits;
dbg_fb_start    <= fb_start;
dbg_fb_done     <= fb_done;
dbg_fb_ok       <= fb_ok;
dbg_fb_len      <= fb_len;

end Behavioral;
