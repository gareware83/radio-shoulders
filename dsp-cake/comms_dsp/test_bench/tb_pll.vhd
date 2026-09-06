library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

library work;
use work.all;

------------------------------------------------------------------------------
-- Top-level wrapper: reports test_pll's pass/fail once it signals done. All
-- the actual stimulus/DUT/self-check logic lives in test_pll_top.vhd
-- (entity test_pll) - this file is deliberately thin, matching the
-- tb_dsp.vhd/test_dsp_top.vhd split the full-chain testbench already uses.
------------------------------------------------------------------------------
entity tb_pll is
end entity tb_pll;

architecture tb of tb_pll is

signal test_pass : std_logic;
signal test_done : std_logic;

begin

p_test_run : process
begin
    wait until test_done = '1';
    report "TEST DONE";

    if test_pass = '1' then
        report "ALL TESTS PASS";
    else
        report "At LEAST ONE TEST FAILED";
    end if;
end process;

tb_inst : entity work.test_pll_top
    port map (
         sim_passed => test_pass
        ,sim_done => test_done
    );
end tb;
