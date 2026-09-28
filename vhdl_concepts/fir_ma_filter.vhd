library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- FIR/moving average filter with divide for moving average
-- Implements a finite impulse response (FIR) filter with a moving average component, dropping the oldest sample from the sum
-- y[n] =  (y[n-1] - shift_reg(0) + new_sample); (generally, y[n] = y[n-1] + x[n] - x[n-N])
-- ma = (1/N) * y[n]
-- dividing by N for moving average where each sample contributes equally to the average (unlike the matched filter where each sampe 
-- is weighted by filter coefficients)
-- Assuming N is power of two TODO: snap any selected N to nearest power of two


entity fir_ma_filter is
    Generic (
        SAMP_WIDTH : integer := 8;
        N_TAPS     : integer := 8
    );
    Port ( clk      : in STD_LOGIC;
           rst      : in STD_LOGIC;
           enable   : in STD_LOGIC;
           valid    : out STD_LOGIC;
           in_data  : in SIGNED(SAMP_WIDTH - 1 downto 0);
           out_data : out SIGNED(SAMP_WIDTH - 1 downto 0)
    );
end fir_ma_filter;

architecture Behavioral of fir_ma_filter is
    type t_byte_array is array (0 to N_TAPS - 1) of signed(SAMP_WIDTH - 1 downto 0);
    signal sum          : signed (SAMP_WIDTH downto 0);--extra bit for bit expansion of a sum (can at most double the data width max value)
    signal shift_reg    : t_byte_array;
begin
    -- Using synchronous reset here, TODO: top level handling of an async reset for a system tied to a PLL and that can handle power on resets, but only has a top level async reste/ sycn deassert for the rest  
    -- Handle first sample load to shift register
    tap0_proc : process(clk,rst,enable)
    begin
        if rising_edge(clk) then
           if rst = '1' then
               shift_reg(0) <= (others => '0');
               
           elsif enable = '1' then
               shift_reg(0) <= in_data;
           end if;
        end if;
    end process;
       
       
    --generate shift reg array to average N_TAPS samples over
    shift_reg_gen : for i in 1 to N_TAPS - 1 generate
        tap_proc : process(clk,rst)
        begin
            if rising_edge(clk) then
                if rst = '1' then
                    shift_reg(i) <= (others => '0');
                elsif enable = '1' then
                    shift_reg(i) <= shift_reg(i - 1);
                end if;
            end if;
        end process;
    end generate;
               
    
    fir_proc : process(clk, rst, enable)
        variable moving_avg : signed (SAMP_WIDTH - 1 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                valid      <= '0';
                sum        <= (others => '0');
                --shift_reg  <= (others => (others => '0'));-- the initialization of an 'array of' that I ALWAYS FORGET!
                out_data   <= (others => '0');
             
            elsif enable = '1' then
                valid <= '1';
                sum   <= resize(sum, sum'length) - resize(signed(shift_reg(N_TAPS - 1)), sum'length) + resize(signed(in_data), sum'length);
                --Sum including bit expanded value and resize post divide, allow tool inference of round to zer, shift right and sign extend
                moving_avg := resize(sum/ (N_TAPS),SAMP_WIDTH);
                out_data <= moving_avg;
            else 
                valid <= '0';-- only assert data valid after moving average computation cycle
            end if;           
        end if;
        
    end process fir_proc;
        
end Behavioral;