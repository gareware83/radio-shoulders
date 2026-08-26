library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

library xpm;
use xpm.vcomponents.all;
library work;
use work.pkg.all;

------------------------------------------------------------------------------
-- Generic async FIFO for crossing one data-plus-valid/ready stream between
-- two independent clock domains. Wraps xpm_fifo_async in first-word-fall-
-- through mode, so the consumer side sees the standard, simplest contract:
-- dout is valid whenever rd_empty = '0', no separate rd_en pulse needed to
-- see the first word.
--
-- Built for dsp_top's clock domain crossing (system_top.vhd): one instance
-- carries ADC_IN samples from the AXI/DMA clock into the DSP's own clock,
-- one carries recovered frame bytes back the other way. Same structure both
-- directions - only G_DATA_WIDTH/G_DEPTH and which side is "write" differ -
-- so this is one parameterized entity rather than two hand-written copies
-- that would otherwise be free to drift apart.
--
-- xpm_fifo_async takes a SINGLE rst input, synchronized internally to both
-- clock domains - not separate wr_rst/rd_rst ports. Driven here from
-- (wr_rst or rd_rst) so the FIFO is held in reset if EITHER side's domain
-- is still resetting. Per the XPM FIFO reset contract, wr_en/rd_en must not
-- be asserted while wr_rst_busy/rd_rst_busy are high - callers get those
-- flags out and are expected to gate on them the same way any other XPM
-- reset-busy signal in this codebase already is (see reg_rw_interface.vhd's
-- BRAM read-latency handling for the general pattern of respecting an XPM
-- primitive's own timing contract rather than assuming it is instant).
------------------------------------------------------------------------------
entity axis_cdc_fifo is
    generic (
        G_DATA_WIDTH : natural := 16;
        G_DEPTH      : natural := 1024
    );
    port (
        -- Write side
        wr_clk      : in  std_logic;
        wr_rst      : in  std_logic;   -- active high
        wr_en       : in  std_logic;
        wr_data     : in  std_logic_vector(G_DATA_WIDTH - 1 downto 0);
        wr_full     : out std_logic;   -- backpressure: hold wr_en/upstream tvalid off
        wr_rst_busy : out std_logic;

        -- Read side
        rd_clk      : in  std_logic;
        rd_rst      : in  std_logic;   -- active high
        rd_en       : in  std_logic;   -- pop; ignored when rd_empty = '1'
        rd_data     : out std_logic_vector(G_DATA_WIDTH - 1 downto 0);
        rd_empty    : out std_logic;   -- '0' means rd_data is valid NOW (fwft)
        rd_rst_busy : out std_logic
    );
end entity;

architecture rtl of axis_cdc_fifo is
    signal rst_either : std_logic;
begin

    rst_either <= wr_rst or rd_rst;

    fifo_i : xpm_fifo_async
    generic map (
        CDC_SYNC_STAGES     => 2,
        DOUT_RESET_VALUE     => "0",
        ECC_MODE              => "no_ecc",
        FIFO_MEMORY_TYPE      => "auto",
        FIFO_READ_LATENCY     => 0,          -- required by READ_MODE => fwft
        FIFO_WRITE_DEPTH      => G_DEPTH,
        FULL_RESET_VALUE      => 1,          -- read as full until reset clears -
                                              -- safer default than a spurious
                                              -- not-full glimpse during reset
        PROG_EMPTY_THRESH     => 10,
        PROG_FULL_THRESH      => 10,
        RD_DATA_COUNT_WIDTH   => 1,
        READ_DATA_WIDTH       => G_DATA_WIDTH,
        READ_MODE             => "fwft",
        RELATED_CLOCKS        => 0,          -- independent, unrelated clocks
        SIM_ASSERT_CHK        => 0,
        USE_ADV_FEATURES      => "0000",     -- only full/empty needed, not
                                              -- prog_full/prog_empty/counts
        WAKEUP_TIME            => 0,
        WRITE_DATA_WIDTH        => G_DATA_WIDTH,
        WR_DATA_COUNT_WIDTH      => 1
    )
    port map (
        rst            => rst_either,

        wr_clk         => wr_clk,
        wr_en          => wr_en,
        din            => wr_data,
        full           => wr_full,
        wr_rst_busy    => wr_rst_busy,
        overflow       => open,
        almost_full    => open,
        prog_full      => open,
        wr_data_count  => open,
        wr_ack         => open,

        rd_clk         => rd_clk,
        rd_en          => rd_en,
        dout           => rd_data,
        empty          => rd_empty,
        rd_rst_busy    => rd_rst_busy,
        underflow      => open,
        almost_empty   => open,
        prog_empty     => open,
        rd_data_count  => open,
        data_valid     => open,

        injectsbiterr  => '0',
        injectdbiterr  => '0',
        sbiterr        => open,
        dbiterr        => open,
        sleep          => '0'
    );

end architecture;
