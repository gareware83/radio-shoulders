library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.pkg.all;

------------------------------------------------------------------------------
-- Receiver lock-quality metric.
--
-- Accumulates, over recovered symbols:
--     sum_min = SUM min(|I|,|Q|)
--     sum_max = SUM max(|I|,|Q|)
--
-- The PS forms the ratio sum_min/sum_max. For QPSK sitting cleanly on the
-- diagonal, |I| = |Q| on every symbol, so the ratio approaches 1. Anything that
-- degrades the constellation pulls it down:
--
--   carrier phase error -> points rotate off the diagonal, |I| and |Q| diverge
--   timing error / ISI  -> symbol magnitudes vary, and the axes vary unequally
--   noise               -> both, incoherently
--
-- WHY A RATIO, AND WHY THESE TWO TERMS. There is no AGC in the chain, so signal
-- level is not controlled. Any absolute error measure (EVM against a fixed
-- reference magnitude, mean squared error, distance from a nominal point) moves
-- with input amplitude, and an automatic tuner optimising it would chase gain
-- rather than lock quality. min/max is scale-free by construction: multiply I
-- and Q by any positive constant and the ratio is unchanged.
--
-- It also needs no reference symbols, so it works on live traffic, not just on
-- a known test sequence - which is what makes it usable as a runtime lock
-- indicator as well as a tuning objective.
--
-- No divider here on purpose. Two accumulators and a symbol count go to the
-- register file; the PS does the division, where it costs nothing.
--
-- INTENDED USE AS A TUNING OBJECTIVE: frame count is a cliff - a search sees
-- 0,0,0,0,4 and has no gradient to follow. This ratio degrades smoothly, so a
-- coefficient search can hill-climb it. Pair it with frame_sync's sync counter
-- for partial credit ("symbols are right, frame body is not") before any frame
-- passes CRC at all.
--
-- Not simulated.
------------------------------------------------------------------------------
entity rx_quality is
    generic (
        -- Accumulators are frozen rather than wrapped when full, so a long
        -- capture degrades to "stopped measuring" instead of silently folding
        -- back through zero and reporting a good ratio from bad data.
        G_ACC_W : natural := 32
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        clr       : in  std_logic;                    -- CONTROL.CLR_STATS

        valid_in  : in  std_logic;
        i_in      : in  signed(15 downto 0);
        q_in      : in  signed(15 downto 0);

        sum_min   : out unsigned(G_ACC_W-1 downto 0);
        sum_max   : out unsigned(G_ACC_W-1 downto 0);
        sym_count : out unsigned(31 downto 0)
    );
end rx_quality;

architecture rtl of rx_quality is

    -- abs() of the most negative 16-bit value overflows back to itself, so
    -- widen before negating rather than after.
    function abs17 (v : signed(15 downto 0)) return unsigned is
        variable w : signed(16 downto 0);
    begin
        w := resize(v, 17);
        if w < 0 then
            w := -w;
        end if;
        return unsigned(w);
    end function;

    signal acc_min : unsigned(G_ACC_W-1 downto 0) := (others => '0');
    signal acc_max : unsigned(G_ACC_W-1 downto 0) := (others => '0');
    signal cnt     : unsigned(31 downto 0)        := (others => '0');
    signal frozen  : std_logic := '0';

begin

    sum_min   <= acc_min;
    sum_max   <= acc_max;
    sym_count <= cnt;

    process (clk)
        variable ai, aq : unsigned(16 downto 0);
        variable lo, hi : unsigned(16 downto 0);
        variable nmin   : unsigned(G_ACC_W downto 0);
        variable nmax   : unsigned(G_ACC_W downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' or clr = '1' then
                acc_min <= (others => '0');
                acc_max <= (others => '0');
                cnt     <= (others => '0');
                frozen  <= '0';

            elsif valid_in = '1' and frozen = '0' then
                ai := abs17(i_in);
                aq := abs17(q_in);

                if ai < aq then
                    lo := ai; hi := aq;
                else
                    lo := aq; hi := ai;
                end if;

                -- One extra bit of width so the carry out is visible; both
                -- accumulators freeze together, otherwise the ratio would be
                -- taken across two different capture lengths.
                nmin := ('0' & acc_min) + resize(lo, G_ACC_W + 1);
                nmax := ('0' & acc_max) + resize(hi, G_ACC_W + 1);

                if nmax(G_ACC_W) = '1' or nmin(G_ACC_W) = '1' then
                    frozen <= '1';
                else
                    acc_min <= nmin(G_ACC_W-1 downto 0);
                    acc_max <= nmax(G_ACC_W-1 downto 0);
                    cnt     <= cnt + 1;
                end if;
            end if;
        end if;
    end process;

end rtl;
