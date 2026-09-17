library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

package vhdl_practice_pkg is

    -- Function to convert std_logic to signed (bipolar representation)
    function to_bipolar(b: std_logic) return signed;

end package vhdl_practice_pkg;

package body vhdl_practice_pkg is
    --function to map to -1,1 encoding
    function to_bipolar(b : std_logic) return signed is
    begin
        if b = '0' then
            return to_signed(-1,2);
        else
            return to_signed(1,2);
        end if;
    end function;
end package body vhdl_practice_pkg;