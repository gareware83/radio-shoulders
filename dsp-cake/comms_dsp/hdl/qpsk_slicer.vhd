library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.pkg.all;

------------------------------------------------------------------------------
-- QPSK hard-decision slicer. One symbol in, two bits out.
--
-- The decision itself is trivial: for Gray-mapped QPSK the nearest
-- constellation point is decided entirely by which quadrant the sample is in,
-- so the hard decision IS the two sign bits. No comparators, no thresholds -
-- b1 = i_in(15), b0 = q_in(15). Anything more elaborate here would be a
-- soft-decision output, which only pays off with an FEC decoder to consume it
-- (see below).
--
-- No derotation happens here. The carrier loop locks to an arbitrary multiple
-- of 90 degrees and nothing in a single symbol can resolve that - it takes the
-- sync word, so all the rotation logic lives in frame_sync where the sync word
-- is. See the ambiguity note in pkg.vhd.
--
-- mag_out is |I| + |Q|, a cheap approximation to symbol magnitude. It is not
-- used for the decision - it is there for a lock/quality indicator and for
-- setting an AGC later. At a clean lock it settles near constant; while the
-- carrier loop is still spinning it swings widely, which makes it a usable
-- (if crude) proxy for "is the receiver working".
--
-- FUTURE: for soft-decision FEC, i_in and q_in are already the log-likelihood
-- ratios up to a scale factor - pass them through instead of slicing, and let
-- the decoder do the deciding. Slicing here throws that information away, which
-- costs about 2 dB. Fine for now: there is no FEC yet.
------------------------------------------------------------------------------
entity qpsk_slicer is
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;

        valid_in  : in  std_logic;
        i_in      : in  signed(15 downto 0);
        q_in      : in  signed(15 downto 0);

        valid_out : out std_logic;
        bits_out  : out std_logic_vector(1 downto 0);   -- (b1, b0)
        mag_out   : out unsigned(16 downto 0)
    );
end qpsk_slicer;

architecture rtl of qpsk_slicer is

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

begin

    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                valid_out <= '0';
                bits_out  <= (others => '0');
                mag_out   <= (others => '0');
            else
                valid_out <= valid_in;

                if valid_in = '1' then
                    bits_out(1) <= i_in(15);
                    bits_out(0) <= q_in(15);
                    -- both terms are already 17-bit; max sum is 2*2**15,
                    -- which still fits
                    mag_out     <= abs17(i_in) + abs17(q_in);
                end if;
            end if;
        end if;
    end process;

end rtl;
