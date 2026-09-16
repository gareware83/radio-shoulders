library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;

Library UNISIM;
use UNISIM.vcomponents.all;

library work;
use work.all;

entity clk_gen is
    Port(
        clk_ref   : in  std_logic;
        clk_out_1 : out std_logic;
        clk_out_2 : out std_logic;
        locked    : out std_logic;
        rst       : in  std_logic
    );
end clk_gen;

architecture Behavioral of clk_gen is

    signal clk_in1_buf : std_logic;
    signal clk_fb      : std_logic;
    signal clk_out1_unbuf, clk_out2_unbuf : std_logic;
begin

    -- Input buffer for the reference clock
    ibuf_inst : IBUF
    port map (
            I => clk_ref, 
            O => clk_in1_buf
            );

    -- MMCM Primitive Instantiation
    mmcm_inst : MMCME2_BASE
    generic map (
        BANDWIDTH      => "OPTIMIZED",
        CLKIN1_PERIOD  => 10.0,      -- 10.0 ns = 100 MHz input
        CLKFBOUT_MULT_F=> 8.0,     -- VCO = 100MHz * 8 = 800 MHz
        DIVCLK_DIVIDE  => 1,         -- VCO divisor
        
        -- Configure Output 1 (80 MHz)
        CLKOUT1_DIVIDE => 10,         -- 800 MHz / 10 = 80 MHz
        
        -- Configure Output 2 (8 MHz)
        CLKOUT2_DIVIDE => 100         -- 800MHz / 100 = 8 MHz
    )
    port map (
        CLKIN1   => clk_in1_buf,
        RST      => rst,
        LOCKED   => locked,
        
        -- Feedback loop (required for phase alignment)
        CLKFBOUT => clk_fb,
        CLKFBIN  => clk_fb,
        
        -- Outputs
        CLKOUT1  => clk_out1_unbuf,
        CLKOUT2  => clk_out2_unbuf
    );

    -- Output buffers (required to put the derived clocks onto global routing networks)
    clkout1_buf : BUFG port map (I => clk_out1_unbuf, O => clk_out1);
    clkout2_buf : BUFG port map (I => clk_out2_unbuf, O => clk_out2);
end Behavioral;