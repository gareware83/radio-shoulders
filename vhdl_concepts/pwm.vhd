library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library work;   
use work.all;

entity pwm is
    Generic (
        PWM_WIDTH : integer := 8 --2**N discrete values for duty cycle
    );
    Port (
        clk        : in std_logic;
        rst        : in std_logic;
        valid_in   : std_logic; --couple enable with duty cycle value input
        duty_cycle : unsigned(PWM_WIDTH - 1 downto 0);
        pwm_out    : out std_logic;
        valid_out  : out std_logic;
        counter    : in unsigned(PWM_WIDTH - 1 downto 0)
    );

end entity pwm;

--Some other thoughts on how to do this in comments
architecture Behavioral of pwm is
    --signal rotate : std_logic_vector(1 downto 0) := "10";
begin
    pwm_proc : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                --counter <= (others => '0');
                pwm_out <= '0';
                valid_out <= '0';
            elsif valid_in = '1' then
                --counter <= counter + 1;
                --pwm_out <= rotate(1);
                --gap_cnt <= gap_cnt + 1 when valid_in='0'; pwm_out <= std_logic(gap_cnt(0));
                valid_out <= '1'; 
            else
                --rotate <= rotate(0) & rotate(1);
                --rotate <= rotate(N-2 downto 0) & rotate(N-1)
                --pwm_out <= '1' when duty_counter < duty_cycle else '0';  -- level, not a toggle event for say 13/64 type of duty cycle
                pwm_out <= not pwm_out;
                valid_out <= '0';
            end if;
        end if;
    end process pwm_proc;
end Behavioral;