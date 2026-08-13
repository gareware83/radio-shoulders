library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.dsp_pkg.all;

entity matched_filter_rrc is
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        valid_in   : in  std_logic;
        i_in       : in  signed(15 downto 0);
        q_in       : in  signed(15 downto 0);
        valid_out  : out std_logic;
        i_out      : out signed(15 downto 0);  -- Output with extra bits for accumulated precision
        q_out      : out signed(15 downto 0)
    );
end matched_filter_rrc;

architecture rtl of matched_filter_rrc is
    -- Shift registers for I and Q input samples
type sample_array_t is array(0 to FILTER_LEN - 1) of signed(15 downto 0);
signal i_shift_reg : sample_array_t := (others => (others => '0'));
signal q_shift_reg : sample_array_t := (others => (others => '0'));

-- Accumulator width: 16-bit sample * 16-bit tap = 32-bit product, summing
-- FILTER_LEN of them needs ceil(log2(FILTER_LEN)) more bits. 40 covers 17
-- taps with margin.
constant C_ACC_W : natural := 40;

-- Output window, verified numerically through the full DDC -> filter chain
-- (ddc_input.dat, fs/4 mixed and decimated by 2, then the 9 taps below):
-- accumulator peaks at ~8.2e8 (30 bits), so shifting down by 15 gives a peak
-- near 25.1k - about 76% of full scale with no clipping. 14 clips 34 of 200
-- samples; 16 is safe but throws away a bit of resolution.
--
-- Margin is tighter than it looks: it assumes the stimulus amplitude and tap
-- scaling below. Re-check by convolving ddc_input.dat through the mixer and
-- these taps if peak_bits, the carrier, the decimation, or the input level
-- changes - all four move this.
constant C_OUT_LSB : natural := 15;
begin

-- The previous version accumulated into a SIGNAL inside the tap loop, so all
-- iterations read the same pre-update value and only the last assignment
-- survived - one tap, not a convolution - and nothing ever cleared it between
-- samples, so it drifted into saturation. Accumulation has to use a variable,
-- zeroed per sample.
process(clk, rst)
    variable i_acc_v : signed(C_ACC_W-1 downto 0);
    variable q_acc_v : signed(C_ACC_W-1 downto 0);
begin
    if rst = '1' then
        i_shift_reg <= (others => (others => '0'));
        q_shift_reg <= (others => (others => '0'));
        i_out       <= (others => '0');
        q_out       <= (others => '0');
        valid_out   <= '0';
    elsif (rising_edge(clk) ) then
        if (valid_in = '1') then
            -- Shift samples in. Input goes straight into tap 0 - the extra
            -- input register the old version had just delayed the whole
            -- response by one sample.
            i_shift_reg(0) <= i_in;
            q_shift_reg(0) <= q_in;
            for i in FILTER_LEN - 1 downto 1 loop
                i_shift_reg(i) <= i_shift_reg(i - 1);
                q_shift_reg(i) <= q_shift_reg(i - 1);
            end loop;

            i_acc_v := (others => '0');
            q_acc_v := (others => '0');
            for k in 0 to FILTER_LEN - 1 loop
                i_acc_v := i_acc_v + resize(i_shift_reg(k) * rrc_coeffs(k), C_ACC_W);
                q_acc_v := q_acc_v + resize(q_shift_reg(k) * rrc_coeffs(k), C_ACC_W);
            end loop;

            i_out <= i_acc_v(C_OUT_LSB + 15 downto C_OUT_LSB);
            q_out <= q_acc_v(C_OUT_LSB + 15 downto C_OUT_LSB);
            valid_out <= '1';

        else
            valid_out <= '0';
        end if;
   end if;
end process;

end rtl;
