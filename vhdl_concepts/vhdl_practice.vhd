library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
Library xpm;
use xpm.vcomponents.all;
library work;
use work.vhdl_practice_pkg.all;

entity vhdl_practice is

    Port(
        sim_passed : out std_logic;
        sim_done : out std_logic
    );
end vhdl_practice;

architecture Behavioral of vhdl_practice is
    constant clk_period : time := 1 us; --1 MHz clock
    constant sim_time   : time := 8000 * clk_period; -- 8ms simulation time
    constant c_lfsr_msb : integer := 7;
    constant c_seed     : std_logic_vector(c_lfsr_msb downto 0) := x"FF";
    constant c_poly     : std_logic_vector(c_lfsr_msb downto 0) := x"AA";
    constant c_chips_per_bit : integer := 8;
    constant c_chirp_msb : integer := 3;
    constant c_chirp_len : integer := 2**(c_chirp_msb + 1) - 1;
    
  
    
    signal clk  : std_logic := '0';
    signal rst  : std_logic := '1';
    signal arst : std_logic := '1';
    
    signal a, b       : signed(15 downto 0) := (others => '0'); --example a and b are both Q1.15
    signal sum        : signed(17 downto 0) := (others => '0'); --Q1 + 1 guard bit so 16 + 2 bits total to add two signed 16 bit numbers
    signal prod       : signed(31 downto 0) := (others => '0'); -- m1.n1 * Qm2.n2 -> Q(m1+m2).(n1+n2) q2.30 raw multiplied procuct
    signal prod_1     : signed(31 downto 0) := (others => '0'); --interim product for round up stage in round and truncate operation
    signal prod_q1_15 : signed( 15 downto 0):= (others => '0'); 
    signal pseudo_rand : std_logic;
    signal tx_data_symbol     : std_logic_vector(7 downto 0) := x"AA"; --simple counter as data source for data bit spreading (chipping) and recovery
    signal data_valid  : std_logic := '0';
    
    --spreader signals
    signal chip_count   : integer range 0 to c_chips_per_bit - 1 :=0;--8:1 chipping ratio
    --signal chipped_data : std_logic := '0';
    signal chipped_buffer : std_logic_vector(c_chips_per_bit -1 downto 0) := (others => '0');
    signal chipped_byte   : std_logic_vector(c_chips_per_bit -1 downto 0) := (others => '0');
    signal lfsr_en        : std_logic := '0';
    
    -- despreader signals
    signal rx_chip_count :  integer range 0 to c_chips_per_bit - 1 :=0;
    signal corr_accum    : signed(4 downto 0);
    signal rx_data_valid : std_logic;
    signal rx_data_bit   : std_logic;
    signal rx_data_symbol : std_logic_vector(7 downto 0) := (others => '0');
    signal prev_pn        : std_logic := '0';
    
    signal lfm_sig_en     : std_logic := '0'; 
    signal lfm_taps_valid : std_logic := '0';
    signal lfm_taps       : std_logic_vector(c_chirp_len - 1 downto 0); -- need to parameterize this to power of lfm chirp  2**(chirp_msb+1)
    signal lfm_data_valid : std_logic := '0';
    signal lfm_bit_in     : std_logic := '0' ;
    
    signal lfm_corr_out   : signed(c_chirp_len downto 0);  -- lfm's corr_out is signed(G_LEN downto 0), G_LEN=16 below
    signal corr_valid     : std_logic := '0';
    
    signal fir_valid : std_logic := '0';
    signal fir_ma_data : signed(7 downto 0):= (others => '0');
    
begin
    

clk_process : process
begin
    while now < sim_time loop
        clk <= '0';
        wait for clk_period/2;
        clk <= '1';
        wait for clk_period/2;
    end loop;
    wait;
end process;

rst_process : process
begin
   
    wait for 2 * clk_period;
    rst <= '1';
    wait for 2 * clk_period;
    rst <= '0';
    wait;
end process;

arst_process : process
begin
    wait for 4 * clk_period;
    arst <= '1';
    wait for 4 * clk_period;
    arst <= '0';
    wait;
end process;

--fixed point arithmetic with round and truncate
qn_process : process(clk, arst)
begin
    if arst = '1' then
        --pick some power of 2 values to more easily interpret the resulting integers
        -- 0x4000 as a q1.15 value is a positive decimal of .5, so prod should be .25, or 0x2000 in q1.15 integer representation
        a          <= signed'(x"4000");
        b          <= signed'(x"4000");
        sum        <= (others => '0');
        prod       <= (others => '0');
        prod_1     <= (others => '0');
        prod_q1_15 <= (others => '0');
        
     elsif rising_edge(clk) then
        
        sum <= resize(a, 18) + resize(b,18);
        prod <= a * b;
        prod_1 <= prod + signed'(x"0000_4000");
        prod_q1_15 <= prod_1(30 downto 15);
        
    end if;
    
end process;

spreading_process : process(clk, arst) 
    variable chipped_data : std_logic;
begin
    if arst = '1' then
        tx_data_symbol <= x"AA" ;--a shift from msb to lsb will toggle the lsb and show up as AA or 55, easy to check by eye
        chip_count <= 0;
        data_valid <= '0';
        lfsr_en <= '1';
        chipped_buffer <= (others => '0');
        chipped_byte   <= (others => '0');
    elsif rising_edge(clk) then 
       --fold in 8th bit immediately to handle next byte lag
        chipped_data := pseudo_rand xor tx_data_symbol(0);
        chipped_buffer <= chipped_data & chipped_buffer(c_lfsr_msb downto 1);
        if chip_count = C_CHIPS_PER_BIT - 1 then
            --reset chip count, incrementing over full chips per bit for one cycle pause for data valid
            chip_count <= 0;
            --data valid when 8 bit buffer contains whole chipped user data bit
            data_valid <= '1';
            --shift counter for next test user data bit (toggling the lsb of the counter as a test data stream)
            tx_data_symbol <= tx_data_symbol(0) & tx_data_symbol(c_lfsr_msb downto 1);
            --register the chipped byte buffer
            chipped_byte <= chipped_buffer;
        else 
           chip_count <= chip_count + 1;
           data_valid <= '0';
          
        end if;      
    end if;    
end process;

--assuming nice and phase locked despread on the same lfsr stage and clock just to show test data bit recovery
despreading_process : process(clk, arst)
    --2b x 2b signed mulipled to either -1 or 1 always
    variable mult  : signed(3 downto 0);
    --Wide enough for +/- 8 (5 bit twos-complement)
    variable accum : signed(4 downto 0);
begin
    if arst = '1' then
        rx_chip_count  <= 0;
        corr_accum     <= (others => '0');
        rx_data_valid  <= '0';
        rx_data_bit    <= '0';
        rx_data_symbol <= (others => '0');
        prev_pn        <= '0';
    elsif rising_edge(clk) then
        -- register lfsr output to account for 1 cycle delay
        prev_pn <= pseudo_rand;
        --immediately update new value to match 8:1 despreading clock ratio
        mult := to_bipolar(chipped_buffer(c_lfsr_msb)) * to_bipolar(prev_pn);
        --Bit expand for addition (+ is a good test to make sure you have all your signals typed correctly)
        accum := corr_accum + resize(mult, 5);
        if rx_chip_count = c_chips_per_bit -1 then
            rx_chip_count <= 0;           
            rx_data_valid <= '1';
            corr_accum <= (others => '0');
            --select the signed bit, whatever sign the accumulator is at the end of the symbol correlation is the user data bit in bipolar encoding
            rx_data_bit <= accum(accum'high);
            --Cheap repack of received symbols
            rx_data_symbol <= accum(accum'high) & rx_data_symbol(7 downto 1);
            
        else
           rx_chip_count  <= rx_chip_count + 1;
           rx_data_valid  <= '0';
           corr_accum     <= accum;
           rx_data_symbol <= rx_data_symbol;
        end if;
        
    end if;
    
end process;


spreading_lfsr : entity work.lfsr
    generic map(
        G_SEED => c_seed,
        G_MSB  => c_lfsr_msb,
        G_POLY => c_poly-- polynomial bit i set, lfsr_reg(i) is a tap
    )
    port map(
         clk      => clk   
        ,arst     => arst
        ,pn_out => pseudo_rand
        ,enable => lfsr_en
        ,reload => '0'
    );

lfm_start : process(clk, arst)
begin
    if arst = '1' then
        lfm_sig_en <= '0';
    elsif rising_edge(clk) then
        lfm_sig_en <= '1';
        --if sim_done <= '1' then
        --    lfm_sig_en  <= '0';
        --else 
        --    lfm_sig_en <= '1';
        --end if;
    end if;
end process;

lfm_inst : entity work.lfm
    generic map (
         G_MSB => c_chirp_msb
        ,G_LEN => c_chirp_len--paramaterize to 2**(chirp_msb+1)
    )
    port map (
    
         clk        => clk
        ,arst       => arst
        ,data_valid => lfm_data_valid
        ,taps_valid => lfm_taps_valid
        ,taps       => lfm_taps
        ,bit_in     => lfm_bit_in
        ,corr_out  => lfm_corr_out
        ,corr_valid => corr_valid
    );
    
lfm_sig_gen : entity work.lfm_signal_gen
    generic map (
          G_CHIRP_MSB => c_chirp_msb
         ,G_CHIRP_LEN => c_chirp_len
    )
    port map (
         clk              => clk
        ,arst             => arst
        ,lfm_sig_en       => lfm_sig_en 
        ,mf_taps_valid    => lfm_taps_valid
        ,mf_taps          => lfm_taps
        ,lfm_signal_valid => lfm_data_valid
        ,lfm_signal_out   => lfm_bit_in
    );
    
fir_ma_proc : entity work.fir_ma_filter
    generic map (
        SAMP_WIDTH => 8
    )
    port map (
         clk      => clk
        ,rst      => arst 
        ,enable   => data_valid--just key off an available enable for now
        ,valid    => fir_valid -- pinned to 1 for now, probably going to need a state machine or generate to handle the usm/avg stages correctly
        ,in_data  => signed(chipped_byte)
        ,out_data => fir_ma_data
    );
    
sim_t : process
begin
    wait for sim_time;
    sim_done <= '1';  
    wait;
end process;

end Behavioral;