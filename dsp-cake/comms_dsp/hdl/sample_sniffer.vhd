library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

Library xpm;
use xpm.vcomponents.all;

library work;
use work.pkg.all;

-- Diagnostic capture buffer: freezes G_DEPTH consecutive I/Q pairs from one
-- selected stage of the RX chain into BRAM, readable one word at a time
-- through the capture region of the same AXI4-Lite window CONTROL/STATUS/etc
-- live in (see C_CAPTURE_BASE_WORD in pkg.vhd and reg_rw_interface's
-- capture-region read handling).
--
-- Single-shot, not circular. CONTROL.CAPTURE_ARM resets the write pointer and
-- starts a fresh fill; once G_DEPTH samples have been written the buffer
-- freezes (STATUS.CAPTURE_DONE) and holds until the next arm. This is the
-- same shape rx_frame_buffer already uses for the same reason: a fixed
-- snapshot that the PS reads out at its own pace has no producer/consumer
-- race to get wrong, where a free-running circular buffer would.
--
-- Four tap points, matching the RX chain diagram's stages exactly - see
-- C_TAP_* in pkg.vhd for the encoding:
--   DDC        post-DDC, pre-PLL        - is the carrier being removed at all?
--   PLL        post-PLL                 - matched filter's input
--   FILTERED   post matched filter      - pulse-shaped baseband
--   SYM        post-Gardner             - slicer's input, same point rx_quality taps
--
-- The four stages run at different, individually gapped rates (decimation at
-- the DDC, again at Gardner, plus whatever gaps VALID_DMA itself has), so
-- there is no single shared valid strobe to gate capture on - only the
-- selected tap's own valid ever advances the write pointer.
entity sample_sniffer is
    Generic (
        -- Depth and address width are both given explicitly, rather than one
        -- derived from the other, so a mismatch between them is an
        -- elaboration-time assertion failure instead of a silently wrapped
        -- write pointer (2**G_ADDR_W must equal G_DEPTH - checked below).
        G_DEPTH  : natural := C_CAPTURE_DEPTH;
        G_ADDR_W : natural := C_CAPTURE_ADDR_W
    );
    Port (
        clk : in std_logic;
        rst : in std_logic;

        -- Tap inputs - exactly one is selected by tap_sel.
        ddc_i      : in signed(15 downto 0);
        ddc_q      : in signed(15 downto 0);
        ddc_valid  : in std_logic;

        pll_i      : in signed(15 downto 0);   -- post-PLL (dsp_top's mf_i/q)
        pll_q      : in signed(15 downto 0);
        pll_valid  : in std_logic;

        filtered_i     : in signed(15 downto 0);
        filtered_q     : in signed(15 downto 0);
        filtered_valid : in std_logic;

        sym_i      : in signed(15 downto 0);
        sym_q      : in signed(15 downto 0);
        sym_valid  : in std_logic;

        tap_sel : in std_logic_vector(1 downto 0);   -- C_TAP_* in pkg.vhd

        -- Control: write-one pulse (self-clearing upstream in
        -- reg_rw_interface, same as tx_start/clr_stats) resets the write
        -- pointer and starts a new fill. Re-arming mid-fill restarts from
        -- empty rather than queuing or being refused - a fresh command wins,
        -- the same rule rx_frame_buffer follows.
        arm  : in  std_logic;
        done : out std_logic;

        -- Read port into the capture RAM, driven by reg_rw_interface's AXI
        -- read FSM. One cycle of latency: rd_data reflects the address
        -- presented WITH rd_en on the previous clock edge - standard
        -- synchronous BRAM behaviour, the same READ_LATENCY_A => 1 contract
        -- pll_2nd_order's LUT ROMs already use. reg_rw_interface's
        -- capture-region read state accounts for exactly this latency.
        rd_addr : in  natural range 0 to G_DEPTH - 1;
        rd_en   : in  std_logic;
        rd_data : out std_logic_vector(31 downto 0)
    );
end sample_sniffer;

architecture rtl of sample_sniffer is

    signal wr_ptr   : unsigned(G_ADDR_W - 1 downto 0) := (others => '0');
    signal filling  : std_logic := '0';
    signal done_i   : std_logic := '0';

    signal tap_i_sel     : signed(15 downto 0);
    signal tap_q_sel     : signed(15 downto 0);
    signal tap_valid_sel : std_logic;

    signal wr_en   : std_logic;
    signal wr_data : std_logic_vector(31 downto 0);
    signal rd_data_i : std_logic_vector(31 downto 0);

begin

    assert (2 ** G_ADDR_W = G_DEPTH)
        report "sample_sniffer: G_ADDR_W does not match G_DEPTH - " &
               "2**G_ADDR_W must equal G_DEPTH exactly"
        severity failure;

    ---------------------------------------------------------------------
    -- Tap mux. Every stage runs on the same clk, gated only by its own
    -- valid strobe - a plain combinational select, no clock-domain
    -- crossing anywhere in this design.
    ---------------------------------------------------------------------
    tap_mux : process (all)
    begin
        case tap_sel is
            when C_TAP_DDC =>
                tap_i_sel <= ddc_i; tap_q_sel <= ddc_q; tap_valid_sel <= ddc_valid;
            when C_TAP_PLL =>
                tap_i_sel <= pll_i; tap_q_sel <= pll_q; tap_valid_sel <= pll_valid;
            when C_TAP_FILTERED =>
                tap_i_sel <= filtered_i; tap_q_sel <= filtered_q; tap_valid_sel <= filtered_valid;
            when others =>   -- C_TAP_SYM
                tap_i_sel <= sym_i; tap_q_sel <= sym_q; tap_valid_sel <= sym_valid;
        end case;
    end process;

    -- I in the low half, Q in the high half - see C_CAPTURE_I_RANGE /
    -- C_CAPTURE_Q_RANGE in pkg.vhd.
    wr_data <= std_logic_vector(tap_q_sel) & std_logic_vector(tap_i_sel);
    wr_en   <= filling and tap_valid_sel;

    fill_proc : process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                wr_ptr  <= (others => '0');
                filling <= '0';
                done_i  <= '0';
            else
                if arm = '1' then
                    wr_ptr  <= (others => '0');
                    filling <= '1';
                    done_i  <= '0';
                elsif wr_en = '1' then
                    if wr_ptr = to_unsigned(G_DEPTH - 1, G_ADDR_W) then
                        filling <= '0';
                        done_i  <= '1';
                    else
                        wr_ptr <= wr_ptr + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    done    <= done_i;
    rd_data <= rd_data_i;

    ---------------------------------------------------------------------
    -- Capture RAM: simple dual-port, one write port (the fill FSM above),
    -- one registered read port (the AXI side, one cycle of latency). A
    -- genuine dual-port primitive rather than sharing a single port between
    -- write and read sidesteps any arbitration between the two entirely -
    -- there is nothing to get wrong there because there is nothing to
    -- arbitrate.
    ---------------------------------------------------------------------
    capture_ram : xpm_memory_sdpram
    generic map (
        ADDR_WIDTH_A            => G_ADDR_W,
        ADDR_WIDTH_B            => G_ADDR_W,
        AUTO_SLEEP_TIME         => 0,
        BYTE_WRITE_WIDTH_A      => 32,
        CASCADE_HEIGHT          => 0,
        CLOCKING_MODE           => "common_clock",
        ECC_MODE                => "no_ecc",
        MEMORY_INIT_PARAM       => "0",
        MEMORY_OPTIMIZATION     => "true",
        MEMORY_PRIMITIVE        => "block",
        MEMORY_SIZE             => G_DEPTH * 32,   -- BITS, not words - the
                                                    -- same trip-up the LUT
                                                    -- ROMs' MEMORY_SIZE note
                                                    -- in pll_2nd_order.vhd
                                                    -- already warns about
        MESSAGE_CONTROL         => 0,
        READ_DATA_WIDTH_B       => 32,
        READ_LATENCY_B          => 1,
        READ_RESET_VALUE_B      => "0",
        RST_MODE_A              => "SYNC",
        RST_MODE_B              => "SYNC",
        SIM_ASSERT_CHK          => 0,
        USE_EMBEDDED_CONSTRAINT => 0,
        USE_MEM_INIT            => 0,
        WAKEUP_TIME             => "disable_sleep",
        WRITE_DATA_WIDTH_A      => 32,
        WRITE_MODE_B            => "no_change"
    )
    port map (
        clka           => clk,
        ena            => '1',
        wea            => (0 => wr_en),
        addra          => std_logic_vector(wr_ptr),
        dina           => wr_data,
        injectsbiterra => '0',
        injectdbiterra => '0',

        clkb           => clk,
        rstb           => rst,
        enb            => rd_en,
        regceb         => '1',
        addrb          => std_logic_vector(to_unsigned(rd_addr, G_ADDR_W)),
        doutb          => rd_data_i,
        sleep          => '0',
        sbiterrb       => open,
        dbiterrb       => open
    );

end rtl;
