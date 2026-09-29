library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

--y[n] = sum(x[k]*h[k-1])
-- Matched filter implementation
entity matched_filter is
    Generic (
        SAMP_WIDTH : integer := 16;
        N_TAPS     : integer :=  9--matching N=9 for existing rrc_coeffs
    );
    Port ( 
           clk      : in STD_LOGIC;
           rst      : in STD_LOGIC;
           enable   : in STD_LOGIC;
           valid    : out STD_LOGIC;
           in_data  : in SIGNED(SAMP_WIDTH - 1 downto 0);
           out_data : out SIGNED(SAMP_WIDTH  - 1 downto 0)
    );
end matched_filter;

architecture Behavioral of matched_filter is
     type coeff_array_t is array(0 to N_TAPS - 1) of signed(SAMP_WIDTH - 1 downto 0); 
    --pull constants over from zybo_radio for a rrc matched filter, just because I already have them
     constant c_rrc_coeffs : coeff_array_t := (
        to_signed(   854, 16),
        to_signed( -2021, 16),
        to_signed( -1266, 16),
        to_signed(  9089, 16),
        to_signed( 16384, 16),   -- center tap, could implement a symmetic filter to reduce taps and 
        to_signed(  9089, 16),
        to_signed( -1266, 16),
        to_signed( -2021, 16),
        to_signed(   854, 16)
    );
    -- coeffs and samples are signed Q1.15, so fixed point multply bit expansion is
    -- is Q2.30, accumulate is then Q3.30, with summed bit expansion 
    constant c_mult_width  : integer :=  2 * SAMP_WIDTH;
    constant c_accum_width : integer := c_mult_width + 1;
    --buffer in N_TAPS samples for match filter multiply accumulate, sized N_TAPS + 1 to register the raw incoming sample
    type t_sample_array is array(0 to N_TAPS ) of signed(SAMP_WIDTH - 1 downto 0);
    type t_sum_array is array(0 to N_TAPS ) of signed(c_accum_width - 1 downto 0);
    
    signal sample_buffer  : t_sample_array := (others => (others => '0'));
    signal sum_buffer     : t_sum_array    := (others => (others => '0'));
    signal valid_buffer   : std_logic_vector(0 to N_TAPS);
    signal round          : t_sum_array  := (others => (others => '0'));
begin
    
    --initialize with 0th sample for sample array
   ind0_proc : process(clk, rst)
   begin
       if rising_edge(clk) then
           if rst = '1' then
               sample_buffer(0) <= (others => '0');
               sum_buffer(0)    <= (others => '0');
               valid_buffer(0)  <= '0';
               round (0)        <= (others => '0');
           else 
               sample_buffer(0) <= in_data;
               valid_buffer(0)  <= enable;
           end if;
       end if;
   end process ind0_proc;
   
    out_data <= round(N_TAPS )(30 downto 15);--truncate 
    valid    <= valid_buffer(N_TAPS) and enable;
    mf_gen: for i in 0 to N_TAPS - 1 generate
        mf_proc : process(clk, rst, enable)
            -- coeffs and samples are signed Q1.15, so fixed point multply bit expansion is
            -- is Q2.30, accumulate is then Q3.30, with summed bit expansion 
            variable mult  : signed (c_mult_width - 1 downto 0);
            --variable acc   : signed (c_accum_width - 1  downto 0);--MSB expansion for sum of acc and mult
            --variable round : signed (c_accum_width - 1 downto 0);
        begin
            if rising_edge(clk) then
                if rst = '1' then
                    sample_buffer(i + 1) <= (others => '0');--don't double drive index 0 after initializing with incoming sample
                    sum_buffer(i + 1)    <= (others => '0');
                    round (i + 1)        <= (others => '0');
                    valid_buffer(i + 1)  <= '0';
                elsif enable = '1' then
                    valid_buffer(i + 1) <= valid_buffer(i);
                    sample_buffer(i + 1) <= sample_buffer(i);
                    --mult_buffer(i + 1)   <= resize((sample_buffer(i) * c_rrc_coeffs(i)), c_mult_width);
                    --multiply in variable to ensure correct index is used in i + 1 sum
                    mult := resize((sample_buffer(i) * c_rrc_coeffs(i)), c_mult_width);
                    sum_buffer(i + 1)    <= sum_buffer(i) + resize(mult, c_accum_width);
                    --mult  := resize((sample_buffer(i) * c_rrc_coeffs(i)), c_mult_width);
                    --acc   := resize(acc, c_accum_width) + resize(mult, c_accum_width);
                    --round := resize(acc, c_accum_width) + to_signed(2**14, c_accum_width); -- rounding
                    round(i + 1) <= resize(sum_buffer(i + 1), c_accum_width) + to_signed(2**14, c_accum_width); -- rounding
                end if;
            end if;
        end process mf_proc;
    end generate;
   
end Behavioral;