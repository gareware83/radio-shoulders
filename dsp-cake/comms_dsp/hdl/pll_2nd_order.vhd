library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
Library xpm;
use xpm.vcomponents.all;
library work;
use work.all;

entity pll_2nd_order is
    port (
        clk     : in  std_logic;
        rst     : in  std_logic;
        
        data_valid : in std_logic;
        -- input complex samples
        I_in    : in  signed(15 downto 0);
        Q_in    : in  signed(15 downto 0);
        -- output corrected samples
        I_out   : out signed(15 downto 0);
        Q_out   : out signed(15 downto 0);

        -- Hardware/sim debug trace only (docs/zybo_work.md's hardware-debug
        -- section) - mirrors what the hardware ILA capture already taps via
        -- mark_debug, so test_dsp_top.vhd's trace dump can get the same
        -- signals through a real port instead of a VHDL-2008 external name
        -- (xsim 2022.2 crashes on those reaching into an if-generate region -
        -- see the testbench's own history for why this exists as a port
        -- rather than an external name).
        dbg_u         : out signed(31 downto 0);
        dbg_phase_err : out signed(31 downto 0);
        dbg_nco_sin   : out signed(15 downto 0);
        dbg_nco_cos   : out signed(15 downto 0)
    );
end entity;

architecture rtl of pll_2nd_order is
-- Loop gains, Q(C_GAIN_FRAC) fixed point: effective gain = K / 2**C_GAIN_FRAC.
-- Raising C_GAIN_FRAC slows the loop and increases headroom; lowering it
-- speeds acquisition and risks instability. Tune this rather than letting the
-- arithmetic overflow.
--
-- Designed by test_bench/loop_model.py (Bn*Ts=0.001, zeta=0.707) from the
-- FIXED detector's measured Kd - not the untuned placeholders these replace.
-- loopf_proc's structure (u accumulates K1*e[n]+K2*e[n-1] directly, no
-- separate integral accumulator) is NOT the textbook Kp/Ki topology; see
-- pll_kp_ki_to_rtl()'s docstring for the K1=Kp+Ki, K2=-Kp mapping used to
-- get here. Regenerate with loop_model.py rather than hand-tuning either
-- value on its own - they only make sense as this specific pair.
--
-- SIGN: this pd_proc rotates the input FORWARD by theta_nco
-- (psi = phi_in + theta_nco), not the standard DEROTATION
-- (psi = phi_in - theta_nco) closed-form PLL design formulas assume - see
-- pll_phase_detector()'s and characterize_pll_detector()'s docstrings in
-- loop_model.py. Missing that sign once already shipped a K1/K2 pair that
-- passed every dead-zone/margin check yet was pure POSITIVE feedback in the
-- real closed loop - confirmed by run_pll_pure_tone(), a single-tone
-- closed-loop test with no data modulation at all: phase_err oscillated
-- continuously across virtually the full detector range (RMS ~6.5e8)
-- regardless of loop bandwidth, damping factor, or step-size clamping,
-- because none of those fix a sign error. Negating BOTH K1 and K2 (this
-- pair) collapsed that to phase_err RMS ~58k - an ~11,000x reduction - with
-- u landing within 0.01% of the correct value. loop_model.py's
-- characterize_pll_detector() now negates its measured Kd before this
-- design is derived, so a straight regenerate keeps the right sign
-- automatically - this comment is here so it's obvious if it ever isn't.

constant C_GAIN_FRAC : natural := 16;
constant K1 : signed(15 downto 0) := to_signed(-810,16);
constant K2 : signed(15 downto 0) := to_signed(803,16);

-- Widths: K (16) * phase_err (32) = 48-bit product; summing two needs 49.
constant C_PROD_W : natural := K1'length + 32;   -- 48
constant C_SUM_W  : natural := C_PROD_W + 1;     -- 49

-- Clamp to signed 32-bit rather than wrapping. Wrapping the frequency word
-- would jump the NCO from max positive to max negative frequency, which
-- throws the loop rather than just saturating it.
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
------------------------------------------------------------------
-- NCO: phase accumulator
------------------------------------------------------------------
-- 32-bit accumulator spans one full circle. The upper bits ARE the phase
-- index - no counting or rollover detection needed:
--   [31:30] quadrant
--   [29:22] 8-bit index into the 256-entry quarter-wave LUT
--   [21:0]  sub-index phase, sets frequency resolution
signal phase_acc        : unsigned(31 downto 0)        := (others => '0');
signal quadrant         : unsigned(1 downto 0)         := (others => '0');
signal raw_idx          : unsigned(7 downto 0)         := (others => '0');
signal phase_lookup     : std_logic_vector(7 downto 0) := (others => '0');
signal nco_cos, nco_sin : signed(15 downto 0)          := (others => '0');
signal cos_raw, sin_raw : std_logic_vector(15 downto 0) := (others => '0');

-- quadrant delayed to match the ROMs' READ_LATENCY_A, so the sign folding is
-- applied to the sample it actually belongs to
signal quadrant_d       : unsigned(1 downto 0)         := (others => '0');
------------------------------------------------------------------
-- Phase detector
------------------------------------------------------------------
signal I_rot, Q_rot    : signed(15 downto 0) := (others => '0');
signal phase_err       : signed(31 downto 0) := (others => '0');
 
------------------------------------------------------------------
-- Loop filter (2nd order, PI)
------------------------------------------------------------------
signal e_prev         : signed(31 downto 0) := (others => '0');
signal u              : signed(31 downto 0) := (others => '0');

-- Hardware debug (ILA) round 1 - see system_top.vhd's mark_debug block.
-- phase_err/u are the convergence signals: phase_err should settle to a
-- small, roughly-constant residual once locked, not oscillate with large
-- swings or rail at extremes - u is the loop filter's running estimate,
-- should track and hold steady once phase_err has settled.
--
-- u also gets dont_touch, not just mark_debug: it's a 32-bit accumulator
-- that (per this file's own comments) rarely gets near its saturation
-- rails for real input - synthesis's static range analysis can legitimately
-- prove individual high-order bits never change for the reachable values it
-- sees and constant-propagate just those bits away, even though mark_debug
-- keeps the signal as a whole from being deleted. dont_touch blocks that
-- bit-level optimization too, which mark_debug alone does not.
attribute mark_debug : string;
attribute mark_debug of phase_err : signal is "true";
attribute mark_debug of u         : signal is "true";
attribute mark_debug of nco_cos   : signal is "true";
attribute mark_debug of nco_sin   : signal is "true";

attribute dont_touch : string;
attribute dont_touch of u : signal is "true";

begin

------------------------------------------------------------------
-- NCO phase accumulator update
------------------------------------------------------------------
-- Only the accumulator is sequential. Everything downstream is a
-- combinational slice of it, so the LUT index can't drift out of step with
-- the true phase - which a separately-counted index inevitably does, since
-- nothing ever re-syncs the two after a missed or spurious increment.
nco_proc: process(clk)
begin
    if rst = '1' then
        phase_acc  <= (others => '0');
        quadrant_d <= (others => '0');
    elsif rising_edge(clk) and data_valid = '1' then
        -- u is the frequency word; unsigned cast gives the two's-complement
        -- wraparound a phase accumulator wants
        phase_acc <= phase_acc + unsigned(u);
        -- align the quadrant with the ROM data it will sign-correct
        quadrant_d <= quadrant;
    end if;
end process;

quadrant <= phase_acc(31 downto 30);
raw_idx  <= phase_acc(29 downto 22);

-- Quarter-wave folding: odd quadrants traverse the table backwards.
phase_lookup <= std_logic_vector(raw_idx) when quadrant(0) = '0'
                else std_logic_vector(not raw_idx);

-- Sign folding: cos is negative in Q1/Q2, sin is negative in Q2/Q3.
-- Uses the delayed quadrant so the sign matches the sample coming out of the
-- ROM one cycle later.
nco_cos <= -signed(cos_raw) when (quadrant_d = "01" or quadrant_d = "10")
           else signed(cos_raw);

nco_sin <= -signed(sin_raw) when (quadrant_d = "10" or quadrant_d = "11")
           else signed(sin_raw);

-- need to be synchronous with pll to match phase core carrier recovery


 
cos_lut : xpm_memory_sprom
generic map (
    ADDR_WIDTH_A      => 8,
    MEMORY_SIZE       => 256*16,     -- BITS, not words - easy trip-up
    READ_DATA_WIDTH_A => 16,
    READ_LATENCY_A    => 1,
    MEMORY_INIT_FILE  => "cos.mem",
    MEMORY_PRIMITIVE  => "block"
)
port map (
    clka           => clk, 
    ena            => data_valid,
    addra          => phase_lookup, 
    douta          => cos_raw,
    rsta           => rst, 
    regcea         => '1', 
    injectsbiterra => '0', 
    injectdbiterra => '0',
    sleep          => '0',
    sbiterra       => open, 
    dbiterra       => open
);

sin_lut : xpm_memory_sprom
generic map (
    ADDR_WIDTH_A      => 8,
    MEMORY_SIZE       => 256*16,     -- BITS, not words - easy trip-up
    READ_DATA_WIDTH_A => 16,
    READ_LATENCY_A    => 1,
    MEMORY_INIT_FILE  => "sine.mem",
    MEMORY_PRIMITIVE  => "block"
)
port map (
    clka           => clk, 
    ena            => data_valid,
    addra          => phase_lookup, 
    douta          => sin_raw,
    rsta           => rst, 
    regcea         => '1', 
    injectsbiterra => '0', 
    injectdbiterra => '0',
    sleep          => '0',
    sbiterra       => open, 
    dbiterra       => open
);


/*sin_lut: blk_mem_gen_1
       port map (
             clka  => clk
            ,addra => phase_lookup
            ,douta => sin_raw
            ,ena   => increment_phase--data_valid
        );
*/
    ------------------------------------------------------------------
    -- Phase detector: rotate input by the NCO estimate, then a
    -- decision-directed cross product on the ROTATED sample.
    ------------------------------------------------------------------
-- The previous version crossed the RAW, un-rotated I_in/Q_in against the
-- rotated pair: phase_err <= I_in*Q_rot - Q_in*I_rot. Algebraically, with
-- I_rot/Q_rot themselves defined as I_in/Q_in rotated by theta (the NCO's
-- own phase), that cross product collapses to exactly
-- (I_in^2 + Q_in^2) * sin(theta) - a term that depends on the NCO's OWN
-- phase and the input's magnitude, but never on the input's actual phase.
-- It could not detect a phase error at all, confirmed numerically in
-- test_bench/loop_model.py (characterize_pll_detector(): sweeping the
-- input's phase at fixed NCO phase gave zero response; sweeping the NCO's
-- phase alone reproduced a full sin curve - the two sweeps should have
-- looked similar for a genuine phase detector, and instead only one of them
-- did anything).
--
-- Fixed to the decision-directed form the old code's own comment named but
-- didn't implement: e = sign(I_rot)*Q_rot - sign(Q_rot)*I_rot. For a
-- correctly-decided QPSK symbol this is proportional to sin(residual phase
-- error) and invariant to which of the four constellation points is
-- currently transmitted - the hard decision (which quadrant) supplies the
-- right reference point automatically, so the error reflects only how far
-- off that decided point the sample landed, not the data itself. No
-- multiplier needed for the "sign(...)" part - just a conditional negate on
-- the sign bit.
pd_proc: process(clk)
    variable multI, multQ       : signed(31 downto 0) := (others => '0');
    variable signed_I, signed_Q : signed(31 downto 0) := (others => '0');
begin
    if rst = '1' then
        I_rot     <= (others => '0');
        Q_rot     <= (others => '0');
        phase_err <= (others => '0');
    elsif rising_edge(clk) and data_valid = '1'  then
        -- rotate input by NCO - this part was always correct; only the
        -- error formula below it wasn't.
        multI := resize((resize(I_in,32) * resize(nco_cos,32) - resize(Q_in,32) * resize(nco_sin,32)),32);
        multQ := resize((resize(I_in,32) * resize(nco_sin,32) + resize(Q_in,32) * resize(nco_cos,32)),32);

        I_rot <= resize(multI(31 downto 16),16);
        Q_rot <= resize(multQ(31 downto 16),16);

        -- Uses multI/multQ (this cycle's fresh rotation) rather than the
        -- registered I_rot/Q_rot, which would read one cycle stale here -
        -- no reason to carry that staleness into a formula being fixed
        -- anyway.
        if multI(31) = '0' then
            signed_Q := resize(multQ, 32);
        else
            signed_Q := -resize(multQ, 32);
        end if;

        if multQ(31) = '0' then
            signed_I := resize(multI, 32);
        else
            signed_I := -resize(multI, 32);
        end if;

        phase_err <= signed_Q - signed_I;
    end if;
end process;

    ------------------------------------------------------------------
    -- Loop filter (PI)
    ------------------------------------------------------------------
-- The previous version did resize(K1*phase_err + K2*e_prev, 32) - the products
-- are 48 bits wide, so resizing to 32 dropped the high bits and wrapped on
-- almost any real error value. Now the multiply/sum are carried at full width,
-- scaled down by an explicit shift (the fixed-point gain), then saturated.
loopf_proc: process(clk)
    variable p1, p2 : signed(C_PROD_W-1 downto 0);
    variable acc    : signed(C_SUM_W-1 downto 0);
    variable delta  : signed(31 downto 0);
begin
    if rst = '1' then
        u      <= (others => '0');
        e_prev <= (others => '0');
    elsif rising_edge(clk) and data_valid = '1' then
        p1 := K1 * phase_err;
        p2 := K2 * e_prev;
        acc := resize(p1, C_SUM_W) + resize(p2, C_SUM_W);

        -- apply the fixed-point gain, then clamp before it reaches the
        -- 32-bit frequency word
        delta := sat32(shift_right(acc, C_GAIN_FRAC));

        -- saturating integrator
        u <= sat32(resize(u, 33) + resize(delta, 33));

        e_prev <= phase_err;
    end if;
end process;

    ------------------------------------------------------------------
    -- Output corrected samples (truncate back to 16 bits)
    ------------------------------------------------------------------
 I_out <= (I_rot);
 Q_out <= (Q_rot);

    -- debug trace passthrough, see the port declaration's comment
    dbg_u         <= u;
    dbg_phase_err <= phase_err;
    dbg_nco_sin   <= nco_sin;
    dbg_nco_cos   <= nco_cos;

end architecture;
--reminder for bit growth rules:
-- add with carry room
/*
signal a,b : signed(15 downto 0);
signal s   : signed(16 downto 0);  -- one extra bit
s <= resize(a, s'length) + resize(b, s'length);

-- 16×16 => 32-bit product
signal a,b : signed(15 downto 0);
signal p   : signed(31 downto 0);
p <= a * b;  -- no extra resize needed for width

*/