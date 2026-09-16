library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

library work;
use work.all;

--Practice fundamentals of VHDL in test bench

entity tb_vhdl_practice is
end tb_vhdl_practice;

architecture behavior of tb_vhdl_practice is

signal test_pass : std_logic;
signal test_done : std_logic;

begin

p_test_run : process
begin
    -- Initialize signals
    test_pass <= '0';
    test_done <= '0';

    -- Wait for 100 ns for global reset to finish
    wait for 100 ns;

    -- Add stimulus here
    test_pass <= '1';
    test_done <= '1';

    -- Wait for 100 ns to observe the results
    wait for 100 ns;

    -- End simulation
    wait;
end process p_test_run; 

tb_inst : entity work.vhdl_practice
    port map (
        sim_passed => test_pass,
        sim_done => test_done
    );

end behavior;