library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
library work;
use work.vhdl_practice_pkg.all;

entity lfsr is 
    Generic (
    --default generics
        G_MSB  : integer := 7;
        G_SEED : std_logic_vector(G_MSB downto 0) := lfsr_seed(G_MSB + 1);
        G_POLY : std_logic_vector(G_MSB downto 0) := lfsr_poly(G_MSB + 1)-- polynomial bit i set, lfsr_reg(i) is a tap
        
    );
    Port (
        clk      : in std_logic;
        arst     : in std_logic;
        pn_out   : out std_logic;
        reload   : in std_logic;
        enable   : in std_logic
    );
end lfsr;

architecture Behavioral of lfsr is
   
    signal lfsr_reg : std_logic_vector(G_MSB downto 0) := G_SEED;
    signal taps     : std_logic_vector(G_MSB downto 0) := G_POLY;
    signal feedback : std_logic;

begin

    gen_taps : for i in 0 to G_MSB generate
        taps(i) <= lfsr_reg(i) and G_POLY(i);
    end generate gen_taps;
    -- VHDL 2008 unary reduction operator
    feedback <= xor taps;
    process(clk,arst) 
    begin
        if arst = '1' then
            lfsr_reg <= G_SEED;
        elsif rising_edge(clk) and enable = '1' then
            if reload = '1' then 
                lfsr_reg <= G_SEED;
            elsif enable = '1' then
                lfsr_reg <= feedback & lfsr_reg(G_MSB downto 1);
            end if;
        end if;
    end process;
    
    pn_out <= lfsr_reg(0);
    
end Behavioral;