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
    type t_mult_array is array(0 to N_TAPS ) of signed(c_mult_width - 1 downto 0);
    
    signal sample_reg  : t_sample_array := (others => (others => '0'));
    signal mult_reg    : t_mult_array   := (others => (others => '0'));
    signal accumulator : signed(c_accum_width - 1 downto 0) := (others => '0');
    signal valid_pipe  : std_logic_vector(2 downto 0) := (others => '0'); --as many stages as needed for the filter pipe
    signal round       : signed(c_accum_width - 1 downto 0) := (others => '0');
begin
   
    mf_proc : process(clk, rst, enable)
        -- coeffs and samples are signed Q1.15, so fixed point multply bit expansion is
        -- is Q2.30, accumulate is then Q3.30, with summed bit expansion 
        variable accum  : signed (c_accum_width - 1 downto 0);
        --variable acc   : signed (c_accum_width - 1  downto 0);--MSB expansion for sum of acc and mult
        --variable round : signed (c_accum_width - 1 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
               sample_reg  <= (others => (others => '0'));
               mult_reg    <= (others => (others => '0'));
               accumulator <= (others => '0');
               valid_pipe  <= (others => '0');
               round       <= (others => '0');
               valid       <= '0';
               out_data    <= (others => '0');
            else
                --Stage 0 : march contole valid along side data it describes
                valid_pipe <= valid_pipe(1 downto 0) & enable;
                --stage 1 shift reg for delay line z^-1
                --array concat idiom
                --if enable = '1' then
                --    sample_reg <= in_data & sample_reg(0 to N_TAPS - 1);
                --end if;
                --my preferred way
                if enable = '1' then
                    for i in N_TAPS downto 1 loop
                       sample_reg(i) <= sample_reg(i - 1);
                    end loop;
                    sample_reg(0) <= in_data;
                end if;
                -- Stage 2 : multiply taps with time reveresed filter coeffs (are mine time reversed?)
                for i in 0 to N_TAPS - 1loop
                    mult_reg(i) <= sample_reg(i) * c_rrc_coeffs(i);
                end loop;

                -- Stage 3 : accumulate the products
                accum := (others => '0');
                for i in 0 to N_TAPS loop
                    accum := accum + resize(mult_reg(i), accum'length);
                end loop;
                accumulator <= accum;
                round <= accumulator + to_signed(2**14, c_accum_width);
                out_data <= round(30 downto 15);--truncate 
                valid    <= valid_pipe(3);

            end if;
        end if;
    end process mf_proc;
    
   
end Behavioral;