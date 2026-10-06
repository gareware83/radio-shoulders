library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity systolic_transposed_mf is
    Generic (
        SAMP_WIDTH : integer := 16;
        N_TAPS     : integer := 9
    );
    Port (
        clk      : in  STD_LOGIC;
        rst      : in  STD_LOGIC;
        enable   : in  STD_LOGIC;
        valid    : out STD_LOGIC;
        in_data  : in  SIGNED(SAMP_WIDTH - 1 downto 0);
        out_data : out SIGNED(SAMP_WIDTH - 1 downto 0)
    );
end systolic_transposed_mf;

architecture Behavioral of systolic_transposed_mf is

    type coeff_array_t is array(0 to N_TAPS - 1) of signed(SAMP_WIDTH - 1 downto 0);

    -- Root Raised Cosine (RRC) Matched Filter Coefficients (Q1.15 Format)
    constant c_rrc_coeffs : coeff_array_t := (
        to_signed(   854, 16),
        to_signed( -2021, 16),
        to_signed( -1266, 16),
        to_signed(  9089, 16),
        to_signed( 16384, 16),   -- Center tap (16384 / 32768 = 0.5)
        to_signed(  9089, 16),
        to_signed( -1266, 16),
        to_signed( -2021, 16),
        to_signed(   854, 16)
    );

    constant c_mult_width  : integer := 2 * SAMP_WIDTH;
    constant c_accum_width : integer := c_mult_width + 4;

    -- Pure nearest-neighbor tapped delay line (no broadcast). PE i's multiplier
    -- reads tap (2*i - 1): the sum chain advances the represented output time by
    -- 1 register/stage, but each successive tap needs a sample 2 samples older
    -- than the previous one, so the data delay line must run at 2 registers/hop,
    -- not 1 -- a single-rate shift chain (1 reg/hop for both data and sum) can
    -- never keep the two in sync past the second tap.
    constant c_delay_len : integer := 2 * (N_TAPS - 1);
    type t_delay_line is array(0 to c_delay_len - 1) of signed(SAMP_WIDTH - 1 downto 0);
    type t_sum_array   is array(0 to N_TAPS - 1) of signed(c_accum_width - 1 downto 0);

    signal delay_line     : t_delay_line := (others => (others => '0'));
    signal sum_pipeline   : t_sum_array  := (others => (others => '0'));
    signal valid_pipeline : std_logic_vector(0 to N_TAPS - 1) := (others => '0');
    signal final_rounded  : signed(c_accum_width - 1 downto 0) := (others => '0');

begin

    -- Tapped delay line: plain shift register, depth 2*(N_TAPS-1).
    delay_proc : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                delay_line <= (others => (others => '0'));
            elsif enable = '1' then
                delay_line(0) <= in_data;
                for k in 1 to c_delay_len - 1 loop
                    delay_line(k) <= delay_line(k - 1);
                end loop;
            end if;
        end if;
    end process delay_proc;

    -- PE 0: uses in_data directly -- the sum register itself supplies tap 0's
    -- one cycle of latency, so no separate delay-line entry is needed for it.
    pe0_proc : process(clk)
        variable v_mult : signed(c_mult_width - 1 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                sum_pipeline(0)   <= (others => '0');
                valid_pipeline(0) <= '0';
            elsif enable = '1' then
                valid_pipeline(0) <= '1';
                v_mult := in_data * c_rrc_coeffs(0);
                sum_pipeline(0)   <= resize(v_mult, c_accum_width);
            end if;
        end if;
    end process pe0_proc;

    -- Systolic Processing Elements 1 to N_TAPS-1: each reads a single fixed
    -- tap off the shared delay line and accumulates into its own sum register.
    mf_gen: for i in 1 to N_TAPS - 1 generate
        pe_proc : process(clk)
            variable v_mult : signed(c_mult_width - 1 downto 0);
        begin
            if rising_edge(clk) then
                if rst = '1' then
                    sum_pipeline(i)   <= (others => '0');
                    valid_pipeline(i) <= '0';
                elsif enable = '1' then
                    valid_pipeline(i) <= valid_pipeline(i-1);

                    v_mult := delay_line(2 * i - 1) * c_rrc_coeffs(i);

                    sum_pipeline(i)   <= sum_pipeline(i-1) + resize(v_mult, c_accum_width);
                end if;
            end if;
        end process pe_proc;
    end generate;

    -- Converge logic: single rounding addition at the final output boundary
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                final_rounded <= (others => '0');
                valid         <= '0';
            elsif enable = '1' then
                final_rounded <= sum_pipeline(N_TAPS - 1) + to_signed(2**14, c_accum_width);
                valid         <= valid_pipeline(N_TAPS - 1);
            else 
                valid <= '0';
            end if;
        end if;
    end process;

    -- Format and truncate back to standard Q1.15 output matching input width
    out_data <= final_rounded(30 downto 15);

end Behavioral;
