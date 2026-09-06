library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

library work;
use work.all;

------------------------------------------------------------------------------
-- Standalone testbench for pll_2nd_order.vhd alone - no Gardner, no matched
-- filter, no framing, just the carrier-recovery loop against a stationary
-- complex tone (cos.dat/sin.dat, test_bench/sin_cos_lut_gen.py --stimulus).
--
-- This is the same test methodology test_bench/loop_model.py's
-- run_pll_pure_tone() already validated at the Python-model level, and for
-- the same reason: a single unmodulated tone with a known, deliberately
-- non-zero residual isolates the loop's own acquisition behaviour from
-- everything data-dependent. It is also the exact test that caught this
-- project's real PLL sign-error bug (see pll_2nd_order.vhd's own header
-- comment) - a broken loop does not converge on a bare tone regardless of
-- bandwidth/damping tuning, so this is a meaningful correctness check, not
-- a toy demo.
--
-- Self-check has two independent parts, checked over the last
-- C_CHECK_WINDOW samples:
--
--   1. NCO FREQUENCY CONVERGENCE - the direct proof of "the NCO is
--      cancelling the input tone", not just a proxy for it: for a tone at
--      C_TEST_FREQ_HZ against sample rate C_TEST_FS_HZ, the phase increment
--      per sample that exactly cancels it is 2**32 * freq/fs (phase_acc is
--      32-bit spanning one full circle - see pll_2nd_order.vhd's own NCO
--      comment). dbg_u must land within C_U_TOLERANCE_PCT of that magnitude.
--      Checked on magnitude only, not sign - which sign a given rotation
--      direction/derotation convention needs is exactly the kind of detail
--      pll_2nd_order.vhd's own "SIGN:" header comment warns has bitten this
--      project before, so this check is deliberately agnostic to it and
--      only asks "did the loop find the right rate."
--   2. CONSTELLATION BALANCE - min(|I_out|,|Q_out|)/max(|I_out|,|Q_out|),
--      the SAME scale-invariant ratio rx_quality.vhd already uses
--      everywhere else in this project (radioctl/radiomon's "quality",
--      same <0.7-is-poor-lock convention), summed over the window exactly
--      like rx_quality's own sum_min/sum_max accumulators. Deliberately
--      NOT dbg_phase_err (still reported below, for reference only): that
--      detector's raw output scales with the full-precision product terms,
--      so a few LSBs of ordinary fixed-point dither around a genuinely
--      locked corner turns into a phase_err reading in the hundreds-of-
--      thousands purely from amplitude scaling - an artifact of the
--      detector's output units, not a measure of lock quality. I_out/Q_out
--      themselves are dimensionless-ratio-friendly and directly show
--      whether the loop settled near a stable corner (|I|~=|Q|) or an
--      unstable axis-aligned crossing (one near zero) - the same
--      distinction this project's real hardware testing already had to
--      make (see docs/zybo_work.md).
------------------------------------------------------------------------------
entity test_pll_top is
    Port (
        sim_done   : out std_logic;
        sim_passed : out std_logic
    );
end test_pll_top;

architecture sim of test_pll_top is

    -- See test_dsp_top.vhd's identical comment: real-time units don't
    -- matter to the DUT (every process here reacts to data_valid, not to
    -- "seconds"), 1 us just makes the simulator's own Time: readout land on
    -- convenient round numbers.
    constant clk_period : time := 1 us;

    -- Must match whatever cos.dat/sin.dat were actually generated with -
    -- regenerate BOTH together, not just the stimulus:
    --   python3 sin_cos_lut_gen.py --stimulus --freq-hz 5000 --phase-deg 45 --n-samples 8000
    -- 8000 samples (not the original 4000) because this loop's bandwidth is
    -- deliberately narrow (Bn*Ts=0.001, pll_2nd_order.vhd's own header) -
    -- the first 4000-sample attempt already showed u converging to within
    -- 0.23% of the theoretically exact value, just hadn't fully settled
    -- phase_err yet by sample 4000. This is a genuine settling-time need,
    -- not a bug - see the mismatch between a narrow loop bandwidth and a
    -- comparatively large single-step frequency offset.
    constant C_TEST_FREQ_HZ : real    := 5000.0;
    constant C_TEST_FS_HZ   : real    := 1_000_000.0;
    constant C_N_SAMPLES    : natural := 8000;
    constant sim_time       : time := (C_N_SAMPLES + 500) * clk_period;   -- stimulus length + drain margin

    -- round(2**32 * freq/fs) - see the header comment's part 1. natural(...)
    -- on a real expression rounds to nearest per the VHDL standard, so no
    -- separate round() (IEEE.MATH_REAL, not otherwise needed in this file)
    -- is required.
    constant C_U_EXPECTED_MAG : natural := natural(4294967296.0 * C_TEST_FREQ_HZ / C_TEST_FS_HZ);
    constant C_U_TOLERANCE_PCT : natural := 5;

    -- See the header comment's part 2 - same threshold convention
    -- rx_quality.vhd/radioctl/radiomon already use project-wide.
    constant C_QUALITY_MIN_X1000 : natural := 700;
    constant C_CHECK_WINDOW      : natural := 200;

    signal clk       : std_logic := '0';
    signal rst       : std_logic := '1';
    signal I_in      : signed(15 downto 0) := (others => '0');
    signal Q_in      : signed(15 downto 0) := (others => '0');
    signal I_out     : signed(15 downto 0);
    signal Q_out     : signed(15 downto 0);
    signal valid_in  : std_logic := '0';
    signal stim_done : std_logic := '0';

    signal dbg_u         : signed(31 downto 0);
    signal dbg_phase_err : signed(31 downto 0);
    signal dbg_nco_sin   : signed(15 downto 0);
    signal dbg_nco_cos   : signed(15 downto 0);

    -- Ring of the last C_CHECK_WINDOW (I_out,Q_out) pairs, updated on every
    -- data_valid cycle - same shape rx_quality.vhd's own sum_min/sum_max
    -- accumulate, just windowed here instead of running from reset.
    type iq_hist_t is array (0 to C_CHECK_WINDOW - 1) of signed(15 downto 0);
    signal i_hist     : iq_hist_t := (others => (others => '0'));
    signal q_hist     : iq_hist_t := (others => (others => '0'));
    signal hist_idx   : natural range 0 to C_CHECK_WINDOW - 1 := 0;
    signal hist_count : natural := 0;   -- caps at C_CHECK_WINDOW once full

    file stim_file_cos : text open read_mode is "cos.dat";
    file stim_file_sin : text open read_mode is "sin.dat";

    -- abs() of the most negative 16-bit value overflows back to itself, so
    -- widen before negating rather than after - same function, same reason,
    -- as rx_quality.vhd's own abs17.
    function abs17 (v : signed(15 downto 0)) return natural is
        variable w : signed(16 downto 0);
    begin
        w := resize(v, 17);
        if w < 0 then
            w := -w;
        end if;
        return to_integer(unsigned(w));
    end function;

begin

    --------------------------------------------------------------------------
    -- Clock
    --------------------------------------------------------------------------
    clk_process : process
    begin
        while now < sim_time loop
            clk <= '0';
            wait for clk_period / 2;
            clk <= '1';
            wait for clk_period / 2;
        end loop;
        wait;
    end process;

    --------------------------------------------------------------------------
    -- Reset
    --------------------------------------------------------------------------
    rst_process : process
    begin
        rst <= '1';
        wait for 25 ns;
        rst <= '0';
        wait;
    end process;

    --------------------------------------------------------------------------
    -- Stimulus: one (I,Q) = (cos[n], sin[n]) pair per clock, in lockstep -
    -- both files advance together since they're the real and imaginary
    -- halves of the SAME complex sample at each n, not two independent
    -- streams. Must match C_TEST_FREQ_HZ/C_TEST_FS_HZ/C_N_SAMPLES above -
    -- see that comment for the exact regenerate command.
    --------------------------------------------------------------------------
    stim_process : process
        variable line_cos, line_sin : line;
        variable val_cos, val_sin   : integer;
    begin
        I_in     <= (others => '0');
        Q_in     <= (others => '0');
        valid_in <= '0';
        wait until rst = '0';
        wait until rising_edge(clk);

        while not endfile(stim_file_cos) and not endfile(stim_file_sin) loop
            readline(stim_file_cos, line_cos);
            read(line_cos, val_cos);
            readline(stim_file_sin, line_sin);
            read(line_sin, val_sin);

            I_in     <= to_signed(val_cos, 16);
            Q_in     <= to_signed(val_sin, 16);
            valid_in <= '1';
            wait until rising_edge(clk);
        end loop;

        valid_in  <= '0';
        I_in      <= (others => '0');
        Q_in      <= (others => '0');
        stim_done <= '1';
        wait;
    end process;

    --------------------------------------------------------------------------
    -- Full per-sample trace dump - every sample, not just a window summary,
    -- so a claimed "converged" reading can be checked against the actual
    -- time-domain behaviour instead of trusted from a single end-of-run
    -- snapshot. Same shape test_dsp_top.vhd's own trace_dump_process uses.
    --------------------------------------------------------------------------
    trace_dump_process : process
        file trace_file : text open write_mode is "pll_trace.csv";
        variable l : line;
        variable sample_idx : natural := 0;
    begin
        write(l, string'("sample,I_in,Q_in,I_out,Q_out,phase_err,u,nco_sin,nco_cos"));
        writeline(trace_file, l);

        wait until rst = '0';
        while now < sim_time loop
            wait until rising_edge(clk);
            if valid_in = '1' then
                write(l, sample_idx);                     write(l, string'(","));
                write(l, to_integer(I_in));                write(l, string'(","));
                write(l, to_integer(Q_in));                write(l, string'(","));
                write(l, to_integer(I_out));               write(l, string'(","));
                write(l, to_integer(Q_out));               write(l, string'(","));
                write(l, to_integer(dbg_phase_err));       write(l, string'(","));
                write(l, to_integer(dbg_u));                write(l, string'(","));
                write(l, to_integer(dbg_nco_sin));         write(l, string'(","));
                write(l, to_integer(dbg_nco_cos));
                writeline(trace_file, l);
                sample_idx := sample_idx + 1;
            end if;
        end loop;
        wait;
    end process;

    --------------------------------------------------------------------------
    -- Sliding window of the last C_CHECK_WINDOW (I_out,Q_out) pairs
    --------------------------------------------------------------------------
    hist_process : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                hist_idx   <= 0;
                hist_count <= 0;
            elsif valid_in = '1' then
                i_hist(hist_idx) <= I_out;
                q_hist(hist_idx) <= Q_out;
                if hist_idx = C_CHECK_WINDOW - 1 then
                    hist_idx <= 0;
                else
                    hist_idx <= hist_idx + 1;
                end if;
                if hist_count < C_CHECK_WINDOW then
                    hist_count <= hist_count + 1;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Verdict: PASS needs the full window populated (i.e. the run was long
    -- enough to reach steady state at all) AND both checks from the header
    -- comment - NCO frequency convergence and constellation balance.
    --------------------------------------------------------------------------
    check_process : process
        variable l          : line;
        variable ai, aq     : natural;
        variable lo, hi     : natural;
        variable sum_min    : natural := 0;   -- max ~200 * 32767, fits comfortably in a 32-bit natural
        variable sum_max    : natural := 0;
        variable u_mag      : natural;
        variable u_diff_abs : natural;
        variable u_tol      : natural;
        variable quality_ok : boolean;
        variable freq_ok    : boolean;
        variable passed     : boolean;
    begin
        sim_done   <= '0';
        sim_passed <= '0';

        wait until stim_done = '1';
        wait for 20 * clk_period;   -- drain the loop's own pipeline latency

        sum_min := 0;
        sum_max := 0;
        for k in i_hist'range loop
            ai := abs17(i_hist(k));
            aq := abs17(q_hist(k));
            if ai < aq then
                lo := ai; hi := aq;
            else
                lo := aq; hi := ai;
            end if;
            sum_min := sum_min + lo;
            sum_max := sum_max + hi;
        end loop;

        u_mag      := natural(abs(to_integer(dbg_u)));
        u_diff_abs := abs(integer(u_mag) - integer(C_U_EXPECTED_MAG));
        u_tol      := (C_U_EXPECTED_MAG * C_U_TOLERANCE_PCT) / 100;

        -- Cross-multiplied rather than divided, same reason rx_quality.vhd
        -- leaves the division to the PS: no rounding/precision loss from an
        -- integer divide, and it stays exact.
        quality_ok := (hist_count >= C_CHECK_WINDOW) and (sum_max > 0)
                      and (sum_min * 1000 >= C_QUALITY_MIN_X1000 * sum_max);
        freq_ok    := u_diff_abs <= u_tol;
        passed     := quality_ok and freq_ok;

        write(l, string'("[TB] ---- results ----"));                    writeline(output, l);
        write(l, string'("[TB] check window samples : "));
        write(l, hist_count);                                           writeline(output, l);
        write(l, string'("[TB] quality ratio x1000  : "));
        if sum_max > 0 then
            write(l, (sum_min * 1000) / sum_max);
        else
            write(l, 0);
        end if;
        writeline(output, l);
        write(l, string'("[TB] locked threshold     : "));
        write(l, C_QUALITY_MIN_X1000);                                  writeline(output, l);
        write(l, string'("[TB] final u              : "));
        write(l, to_integer(dbg_u));                                    writeline(output, l);
        write(l, string'("[TB] |u| expected (+/-"));
        write(l, C_U_TOLERANCE_PCT);
        write(l, string'("%)   : "));
        write(l, C_U_EXPECTED_MAG);                                     writeline(output, l);
        write(l, string'("[TB] |u| actual - expected: "));
        write(l, u_diff_abs);
        write(l, string'(" (tolerance "));
        write(l, u_tol);
        write(l, string'(")"));                                         writeline(output, l);

        -- Where the loop actually settled: I_out/Q_out is the final
        -- derotated point. |I|~=|Q| means it's sitting near a stable
        -- QPSK corner (+/-45/135/225/315); one of them near zero instead
        -- means it locked onto an unstable axis-aligned crossing
        -- (0/90/180/270) - a real failure mode this project has hit
        -- before on hardware, distinct from "hasn't converged yet".
        write(l, string'("[TB] final I_out, Q_out   : "));
        write(l, to_integer(I_out));
        write(l, string'(", "));
        write(l, to_integer(Q_out));                                    writeline(output, l);
        write(l, string'("[TB] final phase_err (ref only, not checked - see header comment): "));
        write(l, to_integer(dbg_phase_err));                            writeline(output, l);

        if passed then
            sim_passed <= '1';
            write(l, string'("[TB] PASS - NCO converged onto the tone's "));
            write(l, string'("frequency and constellation balance settled"));
        else
            sim_passed <= '0';
            write(l, string'("[TB] FAIL - "));
            if not freq_ok then
                write(l, string'("NCO did not converge onto the tone's frequency"));
            end if;
            if not freq_ok and not quality_ok then
                write(l, string'("; "));
            end if;
            if not quality_ok then
                write(l, string'("constellation balance did not settle near a stable corner"));
            end if;
            write(l, string'(" - see pll_2nd_order.vhd's own header "));
            write(l, string'("comment for the loop-polarity checks to make first"));
        end if;
        writeline(output, l);

        sim_done <= '1';
        wait;
    end process;

    --------------------------------------------------------------------------
    -- DUT
    --------------------------------------------------------------------------
    uut: entity work.pll_2nd_order
        port map (
             clk           => clk
            ,rst           => rst
            ,data_valid    => valid_in
            ,I_in          => I_in
            ,Q_in          => Q_in
            ,I_out         => I_out
            ,Q_out         => Q_out
            ,dbg_u         => dbg_u
            ,dbg_phase_err => dbg_phase_err
            ,dbg_nco_sin   => dbg_nco_sin
            ,dbg_nco_cos   => dbg_nco_cos
        );

end sim;
