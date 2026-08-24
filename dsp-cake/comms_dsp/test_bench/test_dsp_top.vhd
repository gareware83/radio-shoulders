library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

library work;
use work.all;

------------------------------------------------------------------------------
-- Testbench for the full RX chain.
--
-- Feeds ddc_input.dat one sample per clock and watches frames come out of the
-- S2MM stream. Expected results are in rx_expected.txt, produced alongside the
-- stimulus by waveform_generator.py's run_frames().
--
-- The self-check is on FRAME COUNT and CRC, not on sample-level output. That is
-- deliberate: the recovery loops converge on their own schedule, so the exact
-- sample a frame lands on is not predictable and asserting on it would make the
-- test fragile for no benefit. "Four frames arrived and all four passed CRC" is
-- the property that actually matters, and it cannot pass by accident - the CRC
-- covers header and payload both.
------------------------------------------------------------------------------
entity test_dsp_top is
    Port (
        sim_done   : out std_logic;
        sim_passed : out std_logic
    );
end test_dsp_top;

architecture sim of test_dsp_top is

    -- Simulation-only clock, decoupled from the real design's clocking
    -- (dsp_top is fed directly here, bypassing system_top.vhd/dsp_clk/the
    -- CDC FIFOs entirely - see system_top.vhd's entity header comment).
    -- dsp_top's own loop filters are purely SAMPLE-driven, not real-time-
    -- driven - every process reacts only to data_valid pulses, with no
    -- notion of "seconds" anywhere in the RTL. The "fs = 1 MHz" the loop
    -- coefficients (test_bench/loop_model.py) are designed against is an
    -- assumption baked into ddc_input.dat's actual SAMPLE VALUES (carrier
    -- placement, freq_err_hz, ppm, all computed against FS = 1_000_000 in
    -- waveform_generator.py), not into this clock's period - feed the same
    -- samples one-per-data_valid-pulse and the loop dynamics under test are
    -- bit-for-bit identical regardless of clk_period. Set to 1 us here so
    -- the simulator's own reported Time: values read out AS real sample
    -- timing (useful for correlating against radiomon/hardware captures),
    -- not because a different value would test different behaviour.
    constant clk_period : time := 1 us;

    -- Sized in CYCLES (via clk_period), not a fixed absolute time - the
    -- previous version (100 us flat) silently assumed clk_period stayed
    -- near its old ~100 ns value forever, and broke (simulation never
    -- reaching sim_done) the moment it didn't. 7000 cycles covers the
    -- current stimulus (ddc_input.dat is 6140 samples - `wc -l
    -- ddc_input.dat` to recheck after regenerating it) plus margin for
    -- chain latency and the last frame draining through the buffer. Bump
    -- this if the stimulus grows past ~6500 samples.
    constant sim_time : time := 7000 * clk_period;

    constant EXPECTED_FRAMES : natural := 4;

    -- DUT signals
    signal clk        : std_logic := '0';
    signal rst        : std_logic := '1';
    signal x_in       : signed(15 downto 0) := (others => '0');
    signal valid_in   : std_logic := '0';

    signal rx_enable  : std_logic := '0';
    signal clr_stats  : std_logic := '0';

    signal rx_tdata   : std_logic_vector(31 downto 0);
    signal rx_tkeep   : std_logic_vector(3 downto 0);
    signal rx_tlast   : std_logic;
    signal rx_tvalid  : std_logic;
    signal rx_tready  : std_logic := '1';   -- testbench always accepts

    signal frame_count : unsigned(15 downto 0);
    signal err_count   : unsigned(15 downto 0);
    signal rx_len      : unsigned(7 downto 0);
    signal overflow    : std_logic;
    signal in_frame    : std_logic;

    signal sync_count  : unsigned(15 downto 0);
    signal qual_min    : unsigned(31 downto 0);
    signal qual_max    : unsigned(31 downto 0);
    signal qual_syms   : unsigned(31 downto 0);

    signal stim_done  : std_logic := '0';

    -- Ground-truth checking
    signal beats_seen      : natural := 0;
    signal beat_errors     : natural := 0;
    signal exp_exhausted   : std_logic := '0';

    -- Stimulus file I/O
    file stim_file : text open read_mode is "ddc_input.dat";

    -- Expected S2MM beats, emitted by waveform_generator.py alongside the
    -- stimulus: "<data hex8> <tkeep hex1> <tlast 0|1>", one line per beat.
    file exp_file  : text open read_mode is "rx_expected_stream.dat";

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
    -- Reset, then enable the receive path.
    --
    -- rx_enable gates frame_sync; with it low the framer is held in reset and
    -- no amount of correct DSP upstream produces a frame.
    --------------------------------------------------------------------------
    rst_process : process
    begin
        rst       <= '1';
        rx_enable <= '0';
        wait for 25 ns;
        rst       <= '0';
        wait for 25 ns;
        rx_enable <= '1';
        wait;
    end process;

    --------------------------------------------------------------------------
    -- Stimulus: one sample per clock
    --------------------------------------------------------------------------
    stim_process : process
        variable linebuf : line;
        variable int_val : integer := 0;
    begin
        x_in     <= (others => '0');
        valid_in <= '0';
        wait until rst = '0';
        wait until rising_edge(clk);

        while not endfile(stim_file) loop
            readline(stim_file, linebuf);
            read(linebuf, int_val);

            x_in     <= to_signed(int_val, 16);
            valid_in <= '1';
            wait until rising_edge(clk);
        end loop;

        valid_in  <= '0';
        x_in      <= (others => '0');
        stim_done <= '1';
        wait;
    end process;

    --------------------------------------------------------------------------
    -- Frame monitor and BIT-TRUTH check.
    --
    -- Every accepted S2MM beat is compared against rx_expected_stream.dat -
    -- data, tkeep and tlast. This is the check that actually proves the payload
    -- matches what was transmitted.
    --
    -- Frame count plus CRC is NOT sufficient on its own. The CRC proves the
    -- received frame is self-consistent, not that it carries the bits that were
    -- sent: a generator bug producing a well-formed frame with the wrong
    -- contents passes CRC every time. Comparing against the transmitted payload
    -- is the only thing that closes that gap.
    --
    -- First beat of every packet is the metadata word:
    --   [31:16] frame counter  [15:12] seq  [11:8] type  [7:0] length
    -- Everything after it, up to TLAST, is payload packed little-endian.
    --------------------------------------------------------------------------
    monitor_process : process(clk)
        variable first_beat : boolean := true;
        variable meta       : std_logic_vector(31 downto 0);
        variable l          : line;
        variable el         : line;
        variable exp_data   : std_logic_vector(31 downto 0);
        variable exp_keep   : std_logic_vector(3 downto 0);
        variable exp_last   : integer;
        variable bad        : boolean;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                first_beat := true;
            elsif rx_tvalid = '1' and rx_tready = '1' then

                if first_beat then
                    meta := rx_tdata;
                    write(l, string'("[TB] frame "));
                    write(l, to_integer(unsigned(meta(31 downto 16))));
                    write(l, string'("  type=0x"));
                    write(l, to_integer(unsigned(meta(11 downto 8))));
                    write(l, string'("  seq="));
                    write(l, to_integer(unsigned(meta(15 downto 12))));
                    write(l, string'("  len="));
                    write(l, to_integer(unsigned(meta(7 downto 0))));
                    write(l, string'("  at "));
                    write(l, now);
                    writeline(output, l);
                    first_beat := false;
                else
                    write(l, string'("[TB]   payload word 0x"));
                    hwrite(l, rx_tdata);
                    write(l, string'("  tkeep="));
                    write(l, to_integer(unsigned(rx_tkeep)));
                    writeline(output, l);
                end if;

                ------------------------------------------------------------
                -- compare this beat against the transmitted truth
                ------------------------------------------------------------
                beats_seen <= beats_seen + 1;

                if endfile(exp_file) then
                    -- more beats than were ever sent
                    beat_errors <= beat_errors + 1;
                    write(l, string'("[TB] ERROR: unexpected extra beat 0x"));
                    hwrite(l, rx_tdata);
                    writeline(output, l);
                else
                    readline(exp_file, el);
                    hread(el, exp_data);
                    hread(el, exp_keep);
                    read(el, exp_last);

                    bad := false;
                    if rx_tdata /= exp_data then bad := true; end if;
                    if rx_tkeep /= exp_keep then bad := true; end if;
                    if (rx_tlast = '1') /= (exp_last = 1) then bad := true; end if;

                    if bad then
                        beat_errors <= beat_errors + 1;
                        write(l, string'("[TB] MISMATCH beat "));
                        write(l, beats_seen);
                        write(l, string'(" got 0x"));
                        hwrite(l, rx_tdata);
                        write(l, string'("/k"));
                        hwrite(l, rx_tkeep);
                        write(l, string'("/l"));
                        write(l, std_logic'image(rx_tlast));
                        write(l, string'("  expected 0x"));
                        hwrite(l, exp_data);
                        write(l, string'("/k"));
                        hwrite(l, exp_keep);
                        write(l, string'("/l"));
                        write(l, exp_last);
                        writeline(output, l);
                    end if;

                    if endfile(exp_file) then
                        exp_exhausted <= '1';
                    end if;
                end if;

                -- TLAST closes the packet, so the next beat starts a new frame
                if rx_tlast = '1' then
                    first_beat := true;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Verdict
    --------------------------------------------------------------------------
    check_process : process
        variable l : line;
    begin
        sim_done   <= '0';
        sim_passed <= '0';

        wait until stim_done = '1';
        -- let the tail of the chain drain: filter, loops, and the frame buffer
        -- readout all sit behind the last input sample. 20 cycles (was a
        -- flat "2 us", which meant something different at every clk_period
        -- - see clk_period's own comment above for why that class of bug
        -- keeps recurring here).
        wait for 20 * clk_period;

        write(l, string'("[TB] ---- results ----"));                 writeline(output, l);
        write(l, string'("[TB] frames passing CRC : "));
        write(l, to_integer(frame_count));                           writeline(output, l);
        write(l, string'("[TB] frames failing CRC : "));
        write(l, to_integer(err_count));                             writeline(output, l);
        write(l, string'("[TB] overflow           : "));
        write(l, std_logic'image(overflow));                         writeline(output, l);
        write(l, string'("[TB] expected frames    : "));
        write(l, EXPECTED_FRAMES);                                   writeline(output, l);
        write(l, string'("[TB] stream beats seen  : "));
        write(l, beats_seen);                                        writeline(output, l);
        write(l, string'("[TB] beat mismatches    : "));
        write(l, beat_errors);                                       writeline(output, l);
        write(l, string'("[TB] all expected beats : "));
        write(l, std_logic'image(exp_exhausted));                    writeline(output, l);

        -- Lock quality. sync_count is the graded signal between "nothing
        -- works" and "a frame arrived": each sync means 16 consecutive symbols
        -- were correct. qual_min/qual_max approaches 1.0 for a clean QPSK
        -- constellation sitting on the diagonal.
        write(l, string'("[TB] sync detections    : "));
        write(l, to_integer(sync_count));                            writeline(output, l);
        write(l, string'("[TB] symbols measured   : "));
        write(l, to_integer(qual_syms));                             writeline(output, l);
        write(l, string'("[TB] quality sum_min    : "));
        write(l, to_integer(qual_min));                              writeline(output, l);
        write(l, string'("[TB] quality sum_max    : "));
        write(l, to_integer(qual_max));                              writeline(output, l);
        if qual_max /= 0 then
            -- qual_min can approach 2**31, so widen BEFORE scaling by 1000 -
            -- the product needs ~41 bits and would wrap in 32.
            write(l, string'("[TB] quality ratio x1000: "));
            write(l, to_integer((resize(qual_min, 48) * 1000)
                                / resize(qual_max, 48)));
            write(l, string'("   (1000 = ideal, <700 = poor lock)"));
            writeline(output, l);
        end if;

        -- Pass needs BOTH: the frame-level counters agree, and every stream
        -- beat matched the transmitted payload. exp_exhausted catches the case
        -- where fewer frames arrived than were sent - beat_errors alone would
        -- stay zero, because beats that never arrive cannot mismatch.
        if to_integer(frame_count) = EXPECTED_FRAMES
           and to_integer(err_count) = 0
           and overflow = '0'
           and beat_errors = 0
           and exp_exhausted = '1' then
            sim_passed <= '1';
            write(l, string'("[TB] PASS - payload matches transmitted data"));
        else
            sim_passed <= '0';
            write(l, string'("[TB] FAIL - see docs/system_design.md "));
            write(l, string'("for the loop-polarity checks to make first"));
        end if;
        writeline(output, l);

        sim_done <= '1';
        wait;
    end process;

    --------------------------------------------------------------------------
    -- DUT
    --------------------------------------------------------------------------
    uut: entity work.dsp_top
        port map (
             SYS_CLK     => clk
            ,ARST        => rst
            ,ADC_IN      => x_in
            ,data_valid  => valid_in

            ,rx_enable   => rx_enable
            ,clr_stats   => clr_stats

            ,rx_tdata    => rx_tdata
            ,rx_tkeep    => rx_tkeep
            ,rx_tlast    => rx_tlast
            ,rx_tvalid   => rx_tvalid
            ,rx_tready   => rx_tready

            ,frame_count => frame_count
            ,err_count   => err_count
            ,rx_len      => rx_len
            ,overflow    => overflow
            ,in_frame    => in_frame

            ,sync_count  => sync_count
            ,qual_min    => qual_min
            ,qual_max    => qual_max
            ,qual_syms   => qual_syms
        );

end sim;
