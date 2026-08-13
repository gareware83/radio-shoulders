library IEEE, STD;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VComponents.all;
library work;
use work.all;
use work.dsp_pkg.all;

entity tb_dsp is
end entity tb_dsp;

architecture tb of tb_dsp is

constant C_TEST_COUNT : natural := 1;
signal tests_pass : std_logic_vector(C_TEST_COUNT - 1 downto 0);
signal test_pass : std_logic;
signal test_done : std_logic;

begin

--test_pass <= or_reduct(tests_pass);

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

tb_inst : entity work.test_dsp_top
--    generic map (
--       G_TEST_COUNT =>  C_TEST_COUNT 
 --   )
    port map (
         sim_passed => test_pass
        ,sim_done => test_done
    );
end tb;