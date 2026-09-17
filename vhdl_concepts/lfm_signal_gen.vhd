library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
library work;
use work.vhdl_practice_pkg.all;

entity lfm_signal_gen is
    generic (
        G_CHIRP_MSB : integer := 3
    );
    port (
        clk              : in std_logic;
        arst             : in std_logic;
        lfm_sig_en       : in std_logic;
        mf_taps_valid    : out std_logic;
        mf_taps          : out std_logic_vector(G_CHIRP_MSB downto 0);
        lfm_signal_valid : out std_logic;
        lfm_signal       : out std_logic
    );
end lfm_signal_gen;

architecture Behavioral of lfm_signal_gen is
      --LFM chirp constants
    constant c_chirp_poly : std_logic_vector(G_CHIRP_MSB downto 0) := "1100";
    constant c_chirp_seed : std_logic_vector(G_CHIRP_MSB downto 0) := "0001";
    constant c_chirp_len  : integer range 0 to 2**(G_CHIRP_MSB + 1) := 2**(G_CHIRP_MSB + 1);
    constant c_rand_interval : integer range 0 to 255 := 255;
    --rand cosntants
    constant c_lfsr_msb : integer := 7;
    constant c_seed     : std_logic_vector(c_lfsr_msb downto 0) := x"FF";
    constant c_poly     : std_logic_vector(c_lfsr_msb downto 0) := x"AA";
    
    --State machine as source select to create mathed filter bits, generate ranqdom bits, then splice is the chirp for detection
    type t_lfm_signal_state is (IDLE, MF_GEN, RAND_GEN, CHIRP_GEN);
    attribute enum_encoding : string;
    attribute enum_encoding of t_lfm_signal_state : type is "00 01 11 10";
    signal signal_state, next_signal_state : t_lfm_signal_state := IDLE;
    
    signal chirp_counter : integer range 0 to  c_chirp_len := 0; 
    signal chirp_pn      : std_logic;
    signal chirp_en      : std_logic;
    signal rand_counter  : integer range 0 to c_rand_interval := 0;
    signal lfm_en        : std_logic := '0';

begin


chirp_seq : process (clk, arst, signal_state,lfm_sig_en)
begin

    if arst = '1' then
        mf_taps_valid    <= '0';
        mf_taps          <= (others => '0');
        lfm_signal_valid <= '0';
        lfm_signal       <= '0';
        mf_taps  <= (others => '0');
        chirp_counter <= 0;
        next_signal_state <= IDLE;
    elsif rising_edge(clk) then
        next_signal_state <= signal_state;
        case(signal_state) is
            when IDLE =>
                if lfm_sig_en = '1' then
                    next_signal_state <= MF_GEN;
                end if;
            when MF_GEN =>
                mf_taps <= chirp_pn & mf_taps(c_chirp_len - 1 downto 1);--shift in the first period of taps as the matched filter for chirp detection 
                if  chirp_counter >= c_chirp_len then
                    chirp_en <= '0';
                    mf_taps_valid <= '1';
                    next_signal_state <= RAND_GEN;
                    chirp_counter <= 0;
                else
                    chirp_en <= '1';
                    mf_taps_valid <= '0';
                    chirp_counter <= chirp_counter + 1;                  
                end if;
               lfm_signal_valid <= '0';              
            when RAND_GEN =>
                lfm_signal_valid <= '1';
                if rand_counter >= c_rand_interval then
                    next_signal_state <= CHIRP_GEN;
                    rand_counter <= 0;
                    lfm_en <= '0';
                else
                    rand_counter <= rand_counter + 1;
                    lfm_en <= '1';
                end if;
                next_signal_state <= CHIRP_GEN;
            when CHIRP_GEN =>
                lfm_signal_valid <= '1';
                chirp_en <= '1';
                if chirp_counter >= c_chirp_len then
                    next_signal_state <= RAND_GEN;
                    chirp_en <= '0';
                end if;
            when others =>
                next_signal_state <= IDLE;
        end case;
    
    end if;
end process;

--Simple case for 'Pulse' generator for LFM, LFM will trigger a 'detection' on a single period sequence of the m-seq lfsr
chirp_lfsr : entity work.lfsr
    generic map(
         G_SEED => c_chirp_seed
        ,G_MSB  => G_CHIRP_MSB
        ,G_POLY => c_chirp_poly
    )
    port map(
         clk    => clk   
        ,arst   => arst
        ,pn_out => chirp_pn
        ,enable => chirp_en
    );
--run the lfsr 
lfm_lfsr : entity work.lfsr
    generic map(
         G_SEED => c_seed
        ,G_MSB  => c_lfsr_msb
        ,G_POLY => c_poly
    )
    port map(
         clk    => clk   
        ,arst   => arst
        ,pn_out => lfm_signal
        ,enable => lfm_en
    );
end Behavioral;