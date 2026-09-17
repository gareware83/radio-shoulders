library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
library work;
use work.vhdl_practice_pkg.all;

--This module is a linear frequency modulation (LFM) correlator. It takes in a stream of ADC samples
--and performs a correlation with a reference LFM signal. The output is a stream of correlation values. 
entity lfm is
    Generic (
        G_MSB : integer := 7;
        G_LEN : integer := 2**(G_MSB+1)
    );
    Port (
        clk        : in std_logic;
        arst       : in std_logic;
        data_valid : in std_logic;
        taps_valid : in std_logic;
        taps       : in std_logic_vector(G_MSB downto 0);
        bit_in     : in std_logic;
        pulse_out  : out std_logic_vector(G_MSB downto 0);
        corr_valid : out std_logic
        );
end lfm;

architecture Behavioral of lfm is

    -- Internal signals
    signal data_i          : std_logic;
    signal corr_accum      : signed(G_LEN - 1 downto 0) := (others => '0');

begin

corr_proc : process(clk, arst)
    variable mult : signed(4 downto 0);
begin
    if arst = '1' then
        corr_accum     <= (others => '0');
        data_i       <= '0';
    elsif rising_edge(clk) and data_valid = '1' and taps_valid = '1' then
        -- register lfsr output to account for 1 cycle delay
        data_i <= bit_in;
        --immediately update new value to match 8:1 despreading clock ratio
        mult := to_bipolar(taps(G_MSB)) * to_bipolar(data_i);
        --Bit expand for addition (+ is a good test to make sure you have all your signals typed correctly)
        corr_accum <= corr_accum + resize(mult, 5);    
        if corr_accum > to_signed(2**(G_MSB), 5) then
            pulse_out <= pulse_out;
            corr_valid <= '1';
        else
            pulse_out <= data_i & pulse_out(G_MSB downto 1);
            corr_valid <= '0';
        end if;
    end if;
end process corr_proc;

end Behavioral;
