library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.all;

------------------------------------------------------------------------------
-- Gardner symbol timing recovery, 2 samples/symbol in, 1 sample/symbol out.
--
-- Carrier recovery alone isn't enough for bit recovery: the PLL can lock phase
-- perfectly and the matched filter still be sampled at the wrong instant. This
-- closes that second loop.
--
-- Gardner is used because it needs no symbol decisions - it works before
-- anything is demodulated, so it can bootstrap - and it wants exactly 2 sps,
-- which is why ddc_fs_4 decimates to 2 rather than 1.
--
--   e[k] = (I[k] - I[k-1])*I[k-1/2] + (Q[k] - Q[k-1])*Q[k-1/2]
--
-- where [k] and [k-1] are consecutive on-symbol samples and [k-1/2] is the
-- mid-symbol sample between them. All three are already on the 2 sps grid, so
-- no interpolation is needed to form the error.
--
-- TIMING ADJUSTMENT IS QUANTISED TO WHOLE INPUT SAMPLES. The loop steers a
-- phase accumulator and takes whichever sample it lands on, so the sampling
-- instant moves in half-symbol steps. That's coarse - the residual timing
-- error never goes below +/-1/4 symbol - but it needs no multipliers and is
-- enough to close the loop for bring-up.
--
-- Upgrade path: mu below is the fractional symbol phase, which is exactly the
-- input a Farrow interpolator consumes. Replacing "take the nearest sample"
-- with "interpolate at mu" is additive - the detector and loop filter don't
-- change. Left as a separate exercise along with polyphase resampling.
--
-- Not simulated - no VHDL toolchain available here. Fixed-point widths follow
-- the same rules the PLL loop filter needed: full-width products, an explicit
-- gain shift, and saturation rather than wrapping.
--
-- Loop polarity: the error is added to the phase increment with adj_v
-- negated (see loopf_proc below) - confirmed against loop_model.py's
-- bit-exact GardnerFixedPoint model (negate=True), which converges cleanly
-- to the nominal increment under a realistic timing-offset+ppm stimulus.
-- If timing_err ever grows instead of settling toward zero in sim, that
-- polarity is the first thing to re-check.
--
-- G_K/G_GAIN_FRAC designed by test_bench/loop_model.py (Bn*Ts=0.01,
-- zeta=0.707) from the TED's measured Kd against matched-filtered (not just
-- TX-shaped) stimulus - not the untuned placeholders these replace. This
-- filter has no integral term (G_K is the textbook Kp directly - see
-- design_pi_loop()'s docstring), so unlike the PLL's K1/K2 there's no
-- topology mapping needed here.
------------------------------------------------------------------------------
entity timing_recovery_gardner is
    generic (
        -- Loop gain is Q(G_GAIN_FRAC): effective gain = G_K / 2**G_GAIN_FRAC.
        -- Raise to slow the loop and add headroom, lower to speed acquisition.
        G_GAIN_FRAC : natural := 16;
        G_K         : integer := 12578
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;

        -- 2 samples/symbol from the matched filter
        valid_in   : in  std_logic;
        i_in       : in  signed(15 downto 0);
        q_in       : in  signed(15 downto 0);

        -- 1 sample/symbol, at the recovered symbol instant
        valid_out  : out std_logic;
        i_out      : out signed(15 downto 0);
        q_out      : out signed(15 downto 0);

        -- for STATUS / debug
        timing_err : out signed(31 downto 0)
    );
end timing_recovery_gardner;

architecture rtl of timing_recovery_gardner is

    -- Phase accumulator spans one symbol. At 2 sps each input sample advances
    -- half a symbol, so the nominal increment is 2**31 and the accumulator
    -- wraps once per symbol. The loop perturbs the increment to slide the
    -- sampling instant.
    constant C_NOMINAL_INCR : unsigned(31 downto 0) := x"80000000";

    -- Bound the loop's authority so it can't invert or stall the nominal rate.
    -- +/-2**28 is +/-12.5% of the nominal increment.
    constant C_ADJ_LIMIT : integer := 2**28;

    signal mu       : unsigned(31 downto 0) := (others => '0');
    signal incr     : unsigned(31 downto 0) := C_NOMINAL_INCR;
    signal adj      : signed(31 downto 0)   := (others => '0');

    -- sample history: i_in is s[n], i_d1 is s[n-1], i_d2 is s[n-2]
    signal i_d1, i_d2 : signed(15 downto 0) := (others => '0');
    signal q_d1, q_d2 : signed(15 downto 0) := (others => '0');

    signal err      : signed(33 downto 0) := (others => '0');

    -- widths: (17-bit difference) * (16-bit mid) = 33, summing two needs 34
    constant C_PROD_W : natural := 33;
    constant C_ERR_W  : natural := 34;
    -- G_K is 16-bit against a 34-bit error
    constant C_LOOP_W : natural := 16 + C_ERR_W;

    function sat32 (v : signed) return signed is
        constant MAXV : signed(31 downto 0) := ('0', others => '1');
        constant MINV : signed(31 downto 0) := ('1', others => '0');
    begin
        if v > resize(MAXV, v'length) then
            return MAXV;
        elsif v < resize(MINV, v'length) then
            return MINV;
        else
            return resize(v, 32);
        end if;
    end function;

    function clamp_adj (v : signed) return signed is
    begin
        if v > to_signed(C_ADJ_LIMIT, v'length) then
            return to_signed(C_ADJ_LIMIT, 32);
        elsif v < to_signed(-C_ADJ_LIMIT, v'length) then
            return to_signed(-C_ADJ_LIMIT, 32);
        else
            return resize(v, 32);
        end if;
    end function;

begin

    -- err is 34-bit; saturate rather than resize, which would silently drop the
    -- top two bits and make a large error read back as a small one.
    timing_err <= sat32(err);

    process (clk)
        variable mu_next  : unsigned(32 downto 0);
        variable di, dq   : signed(16 downto 0);
        variable pi_v     : signed(C_PROD_W-1 downto 0);
        variable pq_v     : signed(C_PROD_W-1 downto 0);
        variable e_v      : signed(C_ERR_W-1 downto 0);
        variable loop_v   : signed(C_LOOP_W-1 downto 0);
        variable adj_v    : signed(31 downto 0);
        variable incr_v   : signed(33 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                mu        <= (others => '0');
                incr      <= C_NOMINAL_INCR;
                adj       <= (others => '0');
                i_d1      <= (others => '0');
                i_d2      <= (others => '0');
                q_d1      <= (others => '0');
                q_d2      <= (others => '0');
                err       <= (others => '0');
                valid_out <= '0';
                i_out     <= (others => '0');
                q_out     <= (others => '0');
            else
                valid_out <= '0';

                if valid_in = '1' then
                    -- Advance symbol phase. The carry out marks the sample the
                    -- loop has chosen as the on-symbol instant.
                    mu_next := resize(mu, 33) + resize(incr, 33);
                    mu      <= mu_next(31 downto 0);

                    if mu_next(32) = '1' then
                        -- s[n] is on-symbol, s[n-1] mid-symbol, s[n-2] the
                        -- previous on-symbol. Reading the delay registers here
                        -- gives their pre-edge values, which is exactly the
                        -- history wanted - they update below for the next pass.
                        di := resize(i_in, 17) - resize(i_d2, 17);
                        dq := resize(q_in, 17) - resize(q_d2, 17);

                        pi_v := di * i_d1;
                        pq_v := dq * q_d1;
                        e_v  := resize(pi_v, C_ERR_W) + resize(pq_v, C_ERR_W);
                        err  <= e_v;

                        -- Loop filter: scale by the fixed-point gain, then clamp
                        -- the loop's authority over the increment.
                        loop_v := to_signed(G_K, 16) * e_v;
                        adj_v  := -clamp_adj(shift_right(loop_v, G_GAIN_FRAC));
                        adj    <= adj_v;

                        -- C_NOMINAL_INCR is 2**31, which does NOT fit in a
                        -- positive signed 32-bit value - casting it straight to
                        -- signed makes it -2**31. Zero-extend to 34 bits so the
                        -- offset arithmetic stays positive.
                        incr_v := resize(signed('0' & C_NOMINAL_INCR), 34)
                                  + resize(adj_v, 34);
                        incr   <= unsigned(incr_v(31 downto 0));

                        -- emit the symbol
                        i_out     <= i_in;
                        q_out     <= q_in;
                        valid_out <= '1';
                    end if;

                    -- shift history every input sample, on-symbol or not
                    i_d2 <= i_d1;
                    i_d1 <= i_in;
                    q_d2 <= q_d1;
                    q_d1 <= q_in;
                end if;
            end if;
        end if;
    end process;

end rtl;
