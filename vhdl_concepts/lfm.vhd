library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
library work;
use work.vhdl_practice_pkg.all;

-- LFM correlator: correlates an incoming bit stream against a matched-filter
-- reference (taps). G_IMPL selects the implementation, defaulting off G_LEN:
--   IMPL_LOOP     - N < 16:        recompute the full dot product combinationally every cycle
--   IMPL_PIPELINE - 16 <= N <= 256: one MAC per stage, systolic, constant depth per stage
--   IMPL_FFT      - N > 256:       fast convolution (vendor FFT IP integration point)
entity lfm is
    generic (
        G_MSB  : integer     := 7;
        G_LEN  : integer     := 2**(G_MSB + 1);
        G_IMPL : t_corr_impl := f_default_corr_impl(G_LEN)
    );
    port (
        clk        : in  std_logic;
        arst       : in  std_logic;
        data_valid : in  std_logic;
        taps_valid : in  std_logic;
        taps       : in  std_logic_vector(G_LEN - 1 downto 0);
        bit_in     : in  std_logic;
        corr_out   : out signed(G_LEN  downto 0);  -- oversized but safe: G_LEN+1 bits comfortably covers +/-G_LEN
        corr_valid : out std_logic;
        debug_out  : out std_logic_vector(G_LEN - 1 downto 0)
    );
end lfm;

architecture Behavioral of lfm is
begin

    gen_corr : if G_IMPL = IMPL_LOOP generate
        -- last G_LEN received samples, aligned against taps by construction
        signal rx_shift_reg : std_logic_vector(G_LEN - 1 downto 0) := (others => '0');
    begin
        loop_proc : process(clk, arst)
            variable v_sum : signed(G_LEN downto 0);
        begin
            if arst = '1' then
                rx_shift_reg <= (others => '0');
                corr_out     <= (others => '0');
                corr_valid   <= '0';
                debug_out    <= (others => '0'); 
            elsif rising_edge(clk) and data_valid = '1' and taps_valid = '1' then
                rx_shift_reg <= bit_in & rx_shift_reg(G_LEN - 1 downto 1);
                v_sum := (others => '0');
                for i in 0 to G_LEN - 1 loop
                    v_sum := v_sum + resize(to_bipolar(rx_shift_reg(i)) * to_bipolar(taps(i)), v_sum'length);
                end loop;
                corr_out   <= v_sum;
                corr_valid <= '1';
                debug_out <= rx_shift_reg;
            end if;
           
        end process loop_proc;

    elsif G_IMPL = IMPL_PIPELINE generate
        -- transposed-form systolic MAC chain: sample and partial sum both
        -- flow stage-to-stage; each stage is exactly one MAC regardless of G_LEN
        type sample_pipe_t is array (0 to G_LEN) of std_logic;
        type sum_pipe_t    is array (0 to G_LEN) of signed(G_LEN downto 0);
        signal sample_pipe : sample_pipe_t;
        signal sum_pipe    : sum_pipe_t;
        signal valid_pipe  : std_logic_vector(0 to G_LEN);
    begin
        sample_pipe(0) <= bit_in;
        sum_pipe(0)    <= (others => '0');
        valid_pipe(0)  <= data_valid and taps_valid;

        stage_gen : for i in 0 to G_LEN - 1 generate
            stage_proc : process(clk, arst)
            begin
                if arst = '1' then
                    sample_pipe(i + 1) <= '0';
                    sum_pipe(i + 1)    <= (others => '0');
                    valid_pipe(i + 1)  <= '0';
                   
                elsif rising_edge(clk) then
                    sample_pipe(i + 1) <= sample_pipe(i);
                    sum_pipe(i + 1)    <= sum_pipe(i) +
                        resize(to_bipolar(sample_pipe(i)) * to_bipolar(taps(i)), sum_pipe(i)'length);
                    valid_pipe(i + 1)  <= valid_pipe(i);
                end if;
            end process stage_proc;
        end generate stage_gen;
        
        corr_out   <= sum_pipe(G_LEN);
        corr_valid <= valid_pipe(G_LEN);
        
        debug_gen : for i in 0 to G_LEN - 1 generate 
            debug_out(i) <= sample_pipe(i);
        end generate debug_gen;

    else generate
        -- fast convolution: integration point for a vendor FFT IP, see
        -- fft_fast_convolution.vhd
        fft_conv_inst : entity work.fft_fast_convolution
            generic map (
                G_LEN => G_LEN
            )
            port map (
                clk        => clk,
                arst       => arst,
                data_valid => data_valid,
                taps_valid => taps_valid,
                taps       => taps,
                bit_in     => bit_in,
                corr_out   => corr_out,
                corr_valid => corr_valid
            );
    end generate gen_corr;

end Behavioral;
