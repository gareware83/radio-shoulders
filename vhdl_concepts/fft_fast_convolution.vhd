library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;

-- Integration point for a vendor FFT IP (e.g. Xilinx xfft) implementing
-- overlap-save fast convolution. Not implemented here -- see fpga_prep.md
-- Section 8: block-buffer input, forward FFT, complex multiply against a
-- precomputed kernel spectrum, inverse FFT, discard the first G_LEN-1
-- (circular-wraparound) samples of each output block.
entity fft_fast_convolution is
    generic (
        G_LEN : integer := 256
    );
    port (
        clk        : in  std_logic;
        arst       : in  std_logic;
        data_valid : in  std_logic;
        taps_valid : in  std_logic;
        taps       : in  std_logic_vector(G_LEN - 1 downto 0);
        bit_in     : in  std_logic;
        corr_out   : out signed(G_LEN downto 0);
        corr_valid : out std_logic
    );
end fft_fast_convolution;

architecture Stub of fft_fast_convolution is
begin
    corr_out   <= (others => '0');
    corr_valid <= '0';
end Stub;
