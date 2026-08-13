
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VCOMPONENTS.ALL;

library work;
use work.all;
use work.dsp_pkg.all;
use work.pkg.all;

-- Top level for the comms DSP PL design.
--
-- Only the PS7's own dedicated pins (DDR + FIXED_IO) are top-level ports -
-- everything else (AXI-Lite register bus, AXI4-Stream to/from the DMA,
-- clock/reset) is internal between the block design wrapper and the PL
-- logic, so it lives as signals rather than ports.
--
-- Datapath:
--   PS DDR --(AXI DMA MM2S)--> mm2s_* --> dsp_top
--   dsp_top --> s2mm_* --(AXI DMA S2MM)--> PS DDR --> Linux --> Ethernet
entity system_top is
  generic (
    -- Where the DSP chain's sample strobe comes from. See valid_src_t in
    -- pkg.vhd. VALID_DMA for a real build; VALID_ALWAYS runs the chain at the
    -- full system clock, which is only meaningful in simulation.
    G_VALID_SRC : valid_src_t := VALID_DMA
  );
  port (
    DDR_0_addr        : inout STD_LOGIC_VECTOR ( 14 downto 0 );
    DDR_0_ba          : inout STD_LOGIC_VECTOR ( 2 downto 0 );
    DDR_0_cas_n       : inout STD_LOGIC;
    DDR_0_ck_n        : inout STD_LOGIC;
    DDR_0_ck_p        : inout STD_LOGIC;
    DDR_0_cke         : inout STD_LOGIC;
    DDR_0_cs_n        : inout STD_LOGIC;
    DDR_0_dm          : inout STD_LOGIC_VECTOR ( 3 downto 0 );
    DDR_0_dq          : inout STD_LOGIC_VECTOR ( 31 downto 0 );
    DDR_0_dqs_n       : inout STD_LOGIC_VECTOR ( 3 downto 0 );
    DDR_0_dqs_p       : inout STD_LOGIC_VECTOR ( 3 downto 0 );
    DDR_0_odt         : inout STD_LOGIC;
    DDR_0_ras_n       : inout STD_LOGIC;
    DDR_0_reset_n     : inout STD_LOGIC;
    DDR_0_we_n        : inout STD_LOGIC;
    FIXED_IO_0_ddr_vrn  : inout STD_LOGIC;
    FIXED_IO_0_ddr_vrp  : inout STD_LOGIC;
    FIXED_IO_0_mio      : inout STD_LOGIC_VECTOR ( 53 downto 0 );
    FIXED_IO_0_ps_clk   : inout STD_LOGIC;
    FIXED_IO_0_ps_porb  : inout STD_LOGIC;
    FIXED_IO_0_ps_srstb : inout STD_LOGIC
  );
end system_top;

architecture Behaviorial of system_top is

signal clk         : std_logic;
signal fclk_resetn : std_logic;                 -- active low, straight from PS7
signal rst         : std_logic;                 -- active high, derived below

-- AXI4-Lite: PS -> reg_rw_interface (user register space).
-- Trimmed to the Lite subset only - the full-AXI4 burst/ID/cache/QoS
-- signals the old version carried (ar/aw burst, cache, id, len, lock, qos,
-- region, size, bid, rid, rlast, wlast) were never used by reg_rw_interface
-- and are dropped. The BD-side master port must be AXI4-Lite to match.
signal s_axi_regs_awaddr  : std_logic_vector(31 downto 0);
signal s_axi_regs_awprot  : std_logic_vector(2 downto 0);
signal s_axi_regs_awvalid : std_logic;
signal s_axi_regs_awready : std_logic;
signal s_axi_regs_wdata   : std_logic_vector(31 downto 0);
signal s_axi_regs_wstrb   : std_logic_vector(3 downto 0);
signal s_axi_regs_wvalid  : std_logic;
signal s_axi_regs_wready  : std_logic;
signal s_axi_regs_bresp   : std_logic_vector(1 downto 0);
signal s_axi_regs_bvalid  : std_logic;
signal s_axi_regs_bready  : std_logic;
signal s_axi_regs_araddr  : std_logic_vector(31 downto 0);
signal s_axi_regs_arprot  : std_logic_vector(2 downto 0);
signal s_axi_regs_arvalid : std_logic;
signal s_axi_regs_arready : std_logic;
signal s_axi_regs_rdata   : std_logic_vector(31 downto 0);
signal s_axi_regs_rresp   : std_logic_vector(1 downto 0);
signal s_axi_regs_rvalid  : std_logic;
signal s_axi_regs_rready  : std_logic;

-- AXI4-Stream, DMA MM2S -> PL (samples out of DDR into the DSP chain).
-- PL is the sink here.
signal mm2s_tdata  : std_logic_vector(31 downto 0);
signal mm2s_tkeep  : std_logic_vector(3 downto 0);
signal mm2s_tlast  : std_logic;
signal mm2s_tvalid : std_logic;
signal mm2s_tready : std_logic;

-- AXI4-Stream, PL -> DMA S2MM (processed samples back into DDR for the PS
-- to pick up and send over Ethernet). PL is the source here.
signal s2mm_tdata  : std_logic_vector(31 downto 0);
signal s2mm_tkeep  : std_logic_vector(3 downto 0);
signal s2mm_tlast  : std_logic;
signal s2mm_tvalid : std_logic;
signal s2mm_tready : std_logic;

signal dsp_valid  : std_logic;    -- sample strobe selected by G_VALID_SRC
signal fpga_reg   : fpgaReg32;    -- PS -> PL, control words
signal status_reg : fpgaStatus32; -- PL -> PS, read-only status/counters
signal tx_start   : std_logic;    -- one-clock pulse from a CONTROL write
signal clr_stats  : std_logic;    -- one-clock pulse from a CONTROL write

-- RX chain status, driven by dsp_top
signal rx_frame_count : unsigned(15 downto 0);
signal rx_err_count   : unsigned(15 downto 0);
signal rx_frame_len   : unsigned(7 downto 0);
signal rx_overflow    : std_logic;
signal rx_in_frame    : std_logic;
signal rx_sync_count  : unsigned(15 downto 0);
signal rx_qual_min    : unsigned(31 downto 0);
signal rx_qual_max    : unsigned(31 downto 0);
signal rx_qual_syms   : unsigned(31 downto 0);

begin

-- status_reg is what the PS reads back at the RO offsets. Anything the PL
-- doesn't drive is held at zero so reads return something defined rather
-- than 'U'.
status_proc : process (all)
begin
    status_reg <= (others => (others => '0'));

    -- C_REG_ID is not driven here - reg_rw_interface answers that offset from
    -- C_ID_MAGIC directly, and two sources for one register invites drift.

    status_reg(C_REG_STATUS)(C_STAT_FRAME_VALID) <= rx_in_frame;
    status_reg(C_REG_STATUS)(C_STAT_OVERFLOW)    <= rx_overflow;
    -- TODO: TX_BUSY and PLL_LOCKED have no source yet. pll_2nd_order exports
    -- no lock indicator, and there is no TX chain at all.
    status_reg(C_REG_STATUS)(C_STAT_TX_BUSY)     <= '0';
    status_reg(C_REG_STATUS)(C_STAT_PLL_LOCKED)  <= '0';

    status_reg(C_REG_RX_LEN)(7 downto 0)       <= std_logic_vector(rx_frame_len);
    status_reg(C_REG_FRAME_COUNT)(15 downto 0) <= std_logic_vector(rx_frame_count);
    status_reg(C_REG_ERR_COUNT)(15 downto 0)   <= std_logic_vector(rx_err_count);

    status_reg(C_REG_SYNC_COUNT)(15 downto 0)  <= std_logic_vector(rx_sync_count);
    status_reg(C_REG_QUAL_MIN)                 <= std_logic_vector(rx_qual_min);
    status_reg(C_REG_QUAL_MAX)                 <= std_logic_vector(rx_qual_max);
    status_reg(C_REG_QUAL_SYMS)                <= std_logic_vector(rx_qual_syms);
end process;

-- PS7 hands out an active-low reset; dsp_top wants active high, the AXI
-- register block wants active low. Derive both rather than passing one
-- signal into ports of opposite polarity (which the old version did).
rst <= not fclk_resetn;

ps_i : entity work.system_wrapper
  port map (
     DDR_addr             => DDR_0_addr
    ,DDR_ba               => DDR_0_ba
    ,DDR_cas_n            => DDR_0_cas_n
    ,DDR_ck_n             => DDR_0_ck_n
    ,DDR_ck_p             => DDR_0_ck_p
    ,DDR_cke              => DDR_0_cke
    ,DDR_cs_n             => DDR_0_cs_n
    ,DDR_dm               => DDR_0_dm
    ,DDR_dq               => DDR_0_dq
    ,DDR_dqs_n            => DDR_0_dqs_n
    ,DDR_dqs_p            => DDR_0_dqs_p
    ,DDR_odt              => DDR_0_odt
    ,DDR_ras_n            => DDR_0_ras_n
    ,DDR_reset_n          => DDR_0_reset_n
    ,DDR_we_n             => DDR_0_we_n
    ,FIXED_IO_ddr_vrn     => FIXED_IO_0_ddr_vrn
    ,FIXED_IO_ddr_vrp     => FIXED_IO_0_ddr_vrp
    ,FIXED_IO_mio         => FIXED_IO_0_mio
    ,FIXED_IO_ps_clk      => FIXED_IO_0_ps_clk
    ,FIXED_IO_ps_porb     => FIXED_IO_0_ps_porb
    ,FIXED_IO_ps_srstb    => FIXED_IO_0_ps_srstb
    -- AXI4-Lite master out to the user register block
    ,M_AXI_REGS_0_awaddr  => s_axi_regs_awaddr
    ,M_AXI_REGS_0_awprot  => s_axi_regs_awprot
    ,M_AXI_REGS_0_awvalid => s_axi_regs_awvalid
    ,M_AXI_REGS_0_awready => s_axi_regs_awready
    ,M_AXI_REGS_0_wdata   => s_axi_regs_wdata
    ,M_AXI_REGS_0_wstrb   => s_axi_regs_wstrb
    ,M_AXI_REGS_0_wvalid  => s_axi_regs_wvalid
    ,M_AXI_REGS_0_wready  => s_axi_regs_wready
    ,M_AXI_REGS_0_bresp   => s_axi_regs_bresp
    ,M_AXI_REGS_0_bvalid  => s_axi_regs_bvalid
    ,M_AXI_REGS_0_bready  => s_axi_regs_bready
    ,M_AXI_REGS_0_araddr  => s_axi_regs_araddr
    ,M_AXI_REGS_0_arprot  => s_axi_regs_arprot
    ,M_AXI_REGS_0_arvalid => s_axi_regs_arvalid
    ,M_AXI_REGS_0_arready => s_axi_regs_arready
    ,M_AXI_REGS_0_rdata   => s_axi_regs_rdata
    ,M_AXI_REGS_0_rresp   => s_axi_regs_rresp
    ,M_AXI_REGS_0_rvalid  => s_axi_regs_rvalid
    ,M_AXI_REGS_0_rready  => s_axi_regs_rready
    -- DMA MM2S: DDR -> PL
    ,M_AXIS_MM2S_0_tdata  => mm2s_tdata
    ,M_AXIS_MM2S_0_tkeep  => mm2s_tkeep
    ,M_AXIS_MM2S_0_tlast  => mm2s_tlast
    ,M_AXIS_MM2S_0_tvalid => mm2s_tvalid
    ,M_AXIS_MM2S_0_tready => mm2s_tready
    -- DMA S2MM: PL -> DDR
    ,S_AXIS_S2MM_0_tdata  => s2mm_tdata
    ,S_AXIS_S2MM_0_tkeep  => s2mm_tkeep
    ,S_AXIS_S2MM_0_tlast  => s2mm_tlast
    ,S_AXIS_S2MM_0_tvalid => s2mm_tvalid
    ,S_AXIS_S2MM_0_tready => s2mm_tready
    ,fclk                 => clk
    ,fclk_resetn          => fclk_resetn
  );

-- TODO: the DSP chain has no backpressure path yet - it consumes one sample
-- per data_valid unconditionally - so the MM2S stream is always accepted.
-- Give dsp_top a tready once any stage can stall.
mm2s_tready <= '1';

-- TODO: 32-bit stream carrying 16-bit I/Q - taking the low half for now to
-- match dsp_top's 16-bit ADC_IN. Decide the packing (interleaved samples vs
-- I in low half / Q in high half) and slice accordingly.
-- Sample strobe selection. The DSP chain advances one sample per pulse, so
-- this sets the effective sample rate without any clock conversion.
-- VALID_ADC has no source yet - add the port when the ADC path exists.
dsp_valid <= mm2s_tvalid when G_VALID_SRC = VALID_DMA else
             '1'         when G_VALID_SRC = VALID_ALWAYS else
             '0';

uut : entity work.dsp_top
  port map (
     SYS_CLK     => clk
    ,ARST        => rst
    ,ADC_IN      => signed(mm2s_tdata(15 downto 0))
    ,data_valid  => dsp_valid

    ,rx_enable   => fpga_reg(C_REG_CONTROL)(C_CTRL_RX_ENABLE)
    ,clr_stats   => clr_stats

    -- recovered frames back to DDR
    ,rx_tdata    => s2mm_tdata
    ,rx_tkeep    => s2mm_tkeep
    ,rx_tlast    => s2mm_tlast
    ,rx_tvalid   => s2mm_tvalid
    ,rx_tready   => s2mm_tready

    ,frame_count => rx_frame_count
    ,err_count   => rx_err_count
    ,rx_len      => rx_frame_len
    ,overflow    => rx_overflow
    ,in_frame    => rx_in_frame

    ,sync_count  => rx_sync_count
    ,qual_min    => rx_qual_min
    ,qual_max    => rx_qual_max
    ,qual_syms   => rx_qual_syms
  );

reg_inst : entity work.reg_rw_interface
  port map (
     clk                     => clk
    ,aresetn                 => fclk_resetn
    ,s_axi_user_regs_awaddr  => s_axi_regs_awaddr
    ,s_axi_user_regs_awprot  => s_axi_regs_awprot
    ,s_axi_user_regs_awvalid => s_axi_regs_awvalid
    ,s_axi_user_regs_awready => s_axi_regs_awready
    ,s_axi_user_regs_wdata   => s_axi_regs_wdata
    ,s_axi_user_regs_wstrb   => s_axi_regs_wstrb
    ,s_axi_user_regs_wvalid  => s_axi_regs_wvalid
    ,s_axi_user_regs_wready  => s_axi_regs_wready
    ,s_axi_user_regs_bresp   => s_axi_regs_bresp
    ,s_axi_user_regs_bvalid  => s_axi_regs_bvalid
    ,s_axi_user_regs_bready  => s_axi_regs_bready
    ,s_axi_user_regs_araddr  => s_axi_regs_araddr
    ,s_axi_user_regs_arprot  => s_axi_regs_arprot
    ,s_axi_user_regs_arvalid => s_axi_regs_arvalid
    ,s_axi_user_regs_arready => s_axi_regs_arready
    ,s_axi_user_regs_rdata   => s_axi_regs_rdata
    ,s_axi_user_regs_rresp   => s_axi_regs_rresp
    ,s_axi_user_regs_rvalid  => s_axi_regs_rvalid
    ,s_axi_user_regs_rready  => s_axi_regs_rready
    ,fpga_reg                => fpga_reg
    ,status_reg              => status_reg
    ,tx_start                => tx_start
    ,clr_stats               => clr_stats
  );

end;
