library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library work;
use work.all;

package vhdl_practice_pkg is
    constant C_TO_BIPOLAR : integer := 2;
    constant C_MULT_WIDTH : integer := 2*C_TO_BIPOLAR;
    -- Function to convert std_logic to signed (bipolar representation)
    function to_bipolar(b: std_logic) return signed;

    -- Correlator implementation strategies, selected by tap count
    type t_corr_impl is (IMPL_LOOP, IMPL_PIPELINE, IMPL_FFT);
    function f_default_corr_impl(len : integer) return t_corr_impl;
    
    -- LFSR polynomial and seed select based on 4, 8, 16 bit max length minimum tap lfsr for pn sequene and matched filter creation for pulse detection in linear freq mod test module
    -- No need for signed integer
    function lfsr_poly (width : positive) return std_logic_vector;
    function lfsr_seed (width : positive) return std_logic_vector;
    function lfsr_size(width : positive) return positive;

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

    -- small: direct combinational loop, mid: pipelined systolic MAC array,
    -- large: FFT-based fast convolution
    function f_default_corr_impl(len : integer) return t_corr_impl is
    begin
        if len <= 16 then
            return IMPL_LOOP;
        elsif len <= 256 then
            return IMPL_PIPELINE;
        else
            return IMPL_FFT;
        end if;
    end function;
    --Size the seed and poly to select predefined values for ranges
    function lfsr_size(width : positive) return positive is
    begin
        if width <= 4 then
            return 4;
        elsif width <= 8 then
            return 8;
        elsif width <= 16 then
            return 16;
        else
            assert false report "lfsr_size: unsupported width" severity failure;
            return 4;
        end if;
    end function;
            
    function lfsr_poly(width : positive) return std_logic_vector is
        variable v : std_logic_vector(width - 1 downto 0) := (others => '0');
    begin 
        case lfsr_size(width) is
        when 4       => return x"9";  --x^4 + x + 1
        when 8       => return x"8E"; --x^8 + x^4 + x^3 + x^2 + 1
        when 16      => return x"8016"; --x^16 + x^5 + x^3 + x^2 + 1
        when others  => 
          assert false report "lfsr_poly: unsupported width" severity failure;
          return v;
        end case;
    end function;
    
    function lfsr_seed(width : positive) return std_logic_vector is
        variable v : std_logic_vector(width - 1 downto 0) := (others => '0');
    begin 
        case width is
        when 4       => return x"3";  
        when 8       => return x"A5";
        when 16      => return x"ACE1"; 
        when others  => 
          assert false report "lfsr_seed: unsupported width" severity failure;
          return v;
        end case;
    end function;
end package body vhdl_practice_pkg;