library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
library work;
use work.vhdl_practice_pkg.all;

entity lfm_signal_gen is
    generic (
         G_CHIRP_MSB : integer := 7;
        G_CHIRP_LEN  : integer := 2**lfsr_size(G_CHIRP_MSB+1) --2**N of the snapped LFSR width, 0..N-1 bit indicesB
    );
    port (
        clk              : in std_logic;
        arst             : in std_logic;
        lfm_sig_en       : in std_logic;
        mf_taps_valid    : out std_logic;
        mf_taps          : out std_logic_vector(G_CHIRP_LEN - 1 downto 0);
        lfm_signal_valid : out std_logic;
        lfm_signal_out   : out std_logic
    );
end lfm_signal_gen;

architecture Behavioral of lfm_signal_gen is
      --LFM chirp constants
    constant c_chirp_size  : positive := lfsr_size(G_CHIRP_MSB + 1);
    constant c_chirp_poly : std_logic_vector(c_chirp_size - 1 downto 0) := lfsr_poly(c_chirp_size);
    constant c_chirp_seed : std_logic_vector(c_chirp_size - 1 downto 0) := lfsr_seed(c_chirp_size);
    constant c_chirp_len  : integer range 0 to 2**(c_chirp_size) := G_CHIRP_LEN;
    constant c_rand_interval : integer range 0 to 10*G_CHIRP_LEN := 10*G_CHIRP_LEN;
    --rand cosntants
    constant c_lfsr_msb : integer := 7;
    constant c_seed     : std_logic_vector(c_lfsr_msb downto 0) := x"FF";
    constant c_poly     : std_logic_vector(c_lfsr_msb downto 0) := x"AA";
    
    --State machine as source select to create mathed filter bits, generate ranqdom bits, then splice is the chirp for detection
    type t_lfm_signal_state is (IDLE, MF_GEN, RAND_GEN, CHIRP_GEN);
    attribute enum_encoding : string;
    attribute enum_encoding of t_lfm_signal_state : type is "00 01 11 10";--Gray code
    signal signal_state : t_lfm_signal_state := IDLE;
    
    signal lfm_signal    : std_logic := '0';
    signal chirp_counter : integer range 0 to  c_chirp_len := 0; 
    signal chirp_pn      : std_logic := '0';
    signal chirp_en      : std_logic := '0';
    signal reload_lfsr   : std_logic := '0';
    signal rand_counter  : integer range 0 to c_rand_interval := 0;
    signal lfm_en        : std_logic := '0';

begin

--signal mux to splice in chirp for detection amongst the random bit sequence
lfm_signal_out <= chirp_pn when signal_state = CHIRP_GEN else lfm_signal;

chirp_seq : process (clk, arst, signal_state,lfm_sig_en)
begin

    if arst = '1' then
        mf_taps_valid    <= '0';
        mf_taps          <= (others => '0');
        lfm_signal_valid <= '0';
        -- (removed) 'lfm_signal <= '0';' used to be here, but lfm_signal is
        -- also structurally driven by lfm_lfsr's port map (pn_out => lfm_signal)
        -- below -- two simultaneous drivers on one resolved signal. That
        -- instance already resets itself correctly via its own arst port, so
        -- this process has no business driving lfm_signal at all. The
        -- conflict was intermittent (resolves to 'X' only when the two
        -- drivers disagree), which is why it showed as red glitches rather
        -- than a solid stuck value, and it propagated straight through
        -- lfm_bit_in -> bit_in -> data_i in vhdl_practice.vhd/lfm.vhd.
        mf_taps  <= (others => '0');
        chirp_en <= '0';
        chirp_counter <= 0;
        signal_state <= IDLE;
        reload_lfsr <= '0';
    elsif rising_edge(clk) then
 
        case(signal_state) is
            when IDLE =>
                reload_lfsr <= '0';
                chirp_en <= '0';
                if lfm_sig_en = '1' then
                    signal_state <= MF_GEN;
                    reload_lfsr       <= '1';
                end if;
            when MF_GEN =>
                reload_lfsr       <= '0';
                         
                if  chirp_counter >= c_chirp_len - 1 then
                    chirp_en          <= '0';
                    mf_taps_valid     <= '1';
                    signal_state <= RAND_GEN;
                    chirp_counter     <= 0;
                else
                    chirp_en <= '1';
                    mf_taps_valid <= '0';
                    chirp_counter <= chirp_counter + 1;    
                    mf_taps       <= chirp_pn & mf_taps(c_chirp_len - 1 downto 1);--shift in the first period of taps as the matched filter for chirp detection 
                end if;
               lfm_signal_valid <= '0';              
            when RAND_GEN =>
                chirp_en <= '0';
                lfm_signal_valid <= '1';
                if rand_counter >= c_rand_interval - 1 then
                    signal_state <= CHIRP_GEN;
                    reload_lfsr       <= '1';
                    rand_counter      <= 0;
                    lfm_en           <= '0';
                else
                    rand_counter <= rand_counter + 1;
                    chirp_counter <= 0;
                    lfm_en <= '1';
                    
                end if;
                -- (removed) an unconditional 'next_signal_state <= CHIRP_GEN;' used to sit
                -- here, outside the if/else above. Since it's the last assignment to
                -- next_signal_state on every pass through this branch, it overwrote both
                -- the if's CHIRP_GEN *and* the else's RAND_GEN decision every single cycle --
                -- forcing a 1-cycle-only dwell in RAND_GEN instead of the intended
                -- c_rand_interval-cycle noise window. The if/else above already assigns
                -- next_signal_state correctly on both paths; nothing else is needed here.
            when CHIRP_GEN =>
                lfm_signal_valid <= '1';
                reload_lfsr       <= '0';
                if chirp_counter >= c_chirp_len - 1 then
                    signal_state <= RAND_GEN;
                    chirp_en <= '0';
                    chirp_counter <= 0;
                else
                    chirp_counter <= chirp_counter + 1;
                    chirp_en <= '1';
                    lfm_en <= '0';
                end if;
            when others =>
                signal_state <= IDLE;
        end case;
    
    end if;
end process;

--Simple case for 'Pulse' generator for LFM, LFM will trigger a 'detection' on a single period sequence of the m-seq lfsr
chirp_lfsr : entity work.lfsr
    generic map(
         G_SEED => c_chirp_seed
        ,G_MSB  => c_chirp_size - 1 
        ,G_POLY => c_chirp_poly
    )
    port map(
         clk    => clk   
        ,arst   => arst
        ,pn_out => chirp_pn
        ,enable => chirp_en
        ,reload => reload_lfsr
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
        ,reload => '0'--never reload the signal pn sequence
    );
end Behavioral;