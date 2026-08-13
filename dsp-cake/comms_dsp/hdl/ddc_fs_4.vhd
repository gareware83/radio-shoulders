library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VComponents.all;
library work;
use work.all;

entity ddc_fs_4 is
    Port (
        clk      : in  std_logic;
        rst      : in  std_logic;
        x_in     : in  signed(15 downto 0);  -- 16-bit real input
        valid_in : in  std_logic;
        i_out    : out signed(15 downto 0);  -- 16-bit I output
        q_out    : out signed(15 downto 0);  -- 16-bit Q output
        valid_out: out std_logic             -- Output valid pulse every 4 input samples
    );
end ddc_fs_4;

architecture Behavioral of ddc_fs_4 is

-- fs/4 quadrature mixing needs no multipliers: cos(pi*n/2) and sin(pi*n/2)
-- are just {1,0,-1,0} and {0,1,0,-1}, so mixing is a sign flip and the
-- zero-valued taps are skipped entirely.
--
--   n:      0     1     2     3     4     5   ...
--   I:    +x[0]   -   -x[2]   -   +x[4]  ...
--   Q:      -   -x[1]   -   +x[3]   -    ...
--
-- I lands on even samples, Q on odd, so one complete pair falls out every
-- two input samples - decimate by 2, keeping 2 samples/symbol downstream
-- from a 4 sps input.
--
-- NOTE THE MINUS SIGN ON THE Q BRANCH. Downconversion multiplies by
-- exp(-j*w*n) = cos - j*sin, so the sin term is SUBTRACTED. An earlier version
-- used +sin, i.e. exp(+j*w*n), which is an upconversion and yields the
-- CONJUGATE baseband.
--
-- That is not a cosmetic sign error, and it is worth understanding why it was
-- invisible for so long. A conjugated QPSK signal is still a perfectly valid
-- QPSK signal: the constellation looks clean, the matched filter behaves, and
-- the carrier loop still locks. Everything upstream of the slicer appears fine.
--
-- It breaks at frame_sync. Conjugation maps (I,Q) -> (I,-Q), a REFLECTION of
-- the constellation. frame_sync resolves carrier phase ambiguity by testing the
-- four 90-degree ROTATIONS of the sync word, and a reflection is not one of
-- them - so sync would never fire, for any rotation, at any SNR, no matter how
-- well both loops converged. The symptom is "the DSP all looks right but no
-- frames ever arrive".
--
-- Derivation, for x[n] = A*cos(2*pi*n/4 + phi), wanting baseband A*exp(j*phi):
--   x[0] = A*cos(phi)              -> I = +x[0]
--   x[1] = A*cos(pi/2 + phi)       = -A*sin(phi)  -> Q = -x[1]
--
-- Flipping this sign also flips the apparent sign of any residual frequency
-- offset, so pll_2nd_order's loop polarity must be re-confirmed against it.
signal phase_cnt : unsigned(1 downto 0) := "00";
signal i_hold    : signed(15 downto 0) := (others => '0');

begin
    -- i_hold is written on an even phase and read on the NEXT (odd) phase,
    -- a full edge later, so the read sees the settled value. The previous
    -- version read i_temp in the same phase it was being written, which is
    -- the pre-edge value - that made i_out permanently zero, since phase 3
    -- always wrote 0 to the I path.
    process(clk, rst)
    begin
        if rst = '1' then
            phase_cnt <= "00";
            i_hold    <= (others => '0');
            i_out     <= (others => '0');
            q_out     <= (others => '0');
            valid_out <= '0';
        elsif (rising_edge(clk)) then
            valid_out <= '0';
            if (valid_in = '1' ) then
                case phase_cnt is
                    when "00" =>                    -- cos = +1
                        i_hold <= x_in;
                    when "01" =>                    -- -sin = -1, pair complete
                        i_out     <= i_hold;
                        q_out     <= -x_in;
                        valid_out <= '1';
                    when "10" =>                    -- cos = -1
                        i_hold <= -x_in;
                    when "11" =>                    -- -sin = +1, pair complete
                        i_out     <= i_hold;
                        q_out     <= x_in;
                        valid_out <= '1';
                    when others =>
                        null;
                end case;
                phase_cnt <= phase_cnt + 1;
            end if;
        end if;
    end process;
end Behavioral;