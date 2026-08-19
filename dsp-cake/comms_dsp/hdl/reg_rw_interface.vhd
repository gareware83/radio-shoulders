library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.all;
use work.pkg.all;

------------------------------------------------------------------------------
-- AXI4-Lite register file for the radio control/status space.
--
-- Flop-based rather than BRAM-backed: single-cycle reads keep the AXI
-- handshake simple, every register is directly visible to PL logic through
-- fpga_reg, and PL-driven read-only registers (status, counters) come back in
-- through status_reg without fighting the PS over a single BRAM port.
--
-- Writes to read-only offsets are accepted and discarded (OKAY response)
-- rather than erroring, which keeps naive userspace pokes from hanging.
--
-- tx_start / clr_stats / capture_arm are write-one pulses: they assert for
-- exactly one clock so PL logic can edge-trigger off them instead of
-- re-triggering every cycle a level-held bit stays set.
--
-- ADDRESS SPACE HAS TWO REGIONS, at different read latencies. Below word
-- offset C_CAPTURE_BASE_WORD (pkg.vhd) is this module's own flop file, one
-- cycle of AXI latency, unchanged from before. At or above it is
-- sample_sniffer's BRAM-backed capture buffer, reached through
-- capture_rd_addr/capture_rd_en/capture_rd_data - one EXTRA cycle of latency
-- for the BRAM's own registered read, which the read FSM below accounts for
-- explicitly (RD_CAP_WAIT) rather than assuming every address answers in the
-- same cycle it did before this region existed.
------------------------------------------------------------------------------
entity reg_rw_interface is
    Generic (
        G_SIMULATE : boolean := false
    );
    Port (
        clk     : in  std_logic;
        aresetn : in  std_logic;

        -- AXI4-Lite slave
        s_axi_user_regs_awaddr  : in  std_logic_vector(31 downto 0);
        s_axi_user_regs_awprot  : in  std_logic_vector(2 downto 0);
        s_axi_user_regs_awvalid : in  std_logic;
        s_axi_user_regs_awready : out std_logic;
        s_axi_user_regs_wdata   : in  std_logic_vector(31 downto 0);
        s_axi_user_regs_wstrb   : in  std_logic_vector(3 downto 0);
        s_axi_user_regs_wvalid  : in  std_logic;
        s_axi_user_regs_wready  : out std_logic;
        s_axi_user_regs_bresp   : out std_logic_vector(1 downto 0);
        s_axi_user_regs_bvalid  : out std_logic;
        s_axi_user_regs_bready  : in  std_logic;
        s_axi_user_regs_araddr  : in  std_logic_vector(31 downto 0);
        s_axi_user_regs_arprot  : in  std_logic_vector(2 downto 0);
        s_axi_user_regs_arvalid : in  std_logic;
        s_axi_user_regs_arready : out std_logic;
        s_axi_user_regs_rdata   : out std_logic_vector(31 downto 0);
        s_axi_user_regs_rresp   : out std_logic_vector(1 downto 0);
        s_axi_user_regs_rvalid  : out std_logic;
        s_axi_user_regs_rready  : in  std_logic;

        -- PS -> PL: writable register contents
        fpga_reg   : out fpgaReg32;
        -- PL -> PS: values returned for read-only offsets in the control
        -- region (word offsets below C_CAPTURE_BASE_WORD)
        status_reg : in  fpgaStatus32;

        -- One-clock pulses decoded from CONTROL writes
        tx_start     : out std_logic;
        clr_stats    : out std_logic;
        capture_arm  : out std_logic;

        -- Capture-region read passthrough to sample_sniffer. addr/en are
        -- driven together for exactly one cycle; capture_rd_data is sampled
        -- one cycle later, matching sample_sniffer's own READ_LATENCY_B => 1
        -- contract.
        capture_rd_addr : out natural range 0 to C_CAPTURE_DEPTH - 1;
        capture_rd_en   : out std_logic;
        capture_rd_data : in  std_logic_vector(31 downto 0)
    );
end reg_rw_interface;

architecture rtl of reg_rw_interface is

    signal reg_file  : fpgaReg32 := (others => (others => '0'));

    signal awready_i : std_logic;
    signal wready_i  : std_logic;
    signal bvalid_i  : std_logic;
    signal arready_i : std_logic;
    signal rvalid_i  : std_logic;
    signal rdata_i   : std_logic_vector(31 downto 0);

    signal tx_start_i     : std_logic;
    signal clr_stats_i    : std_logic;
    signal capture_arm_i  : std_logic;

    signal capture_rd_addr_i : natural range 0 to C_CAPTURE_DEPTH - 1;
    signal capture_rd_en_i   : std_logic;

    -- Read FSM: IDLE handles both regions' request phase; RD_CAP_WAIT is the
    -- one extra cycle the capture region's BRAM read needs before its data is
    -- valid. The control region never enters RD_CAP_WAIT - its response is
    -- still exactly as fast as before this region existed.
    type rd_state_t is (RD_IDLE, RD_CAP_WAIT, RD_CAP_WAIT1);
    signal rd_state : rd_state_t := RD_IDLE;

    -- Word index from a byte address, over the FULL address space (both
    -- regions) - deliberately NOT clamped here any more. Clamping now
    -- happens per-region in read_proc, since the two regions clamp to
    -- different bounds (C_REG_COUNT-1 vs C_CAPTURE_DEPTH-1). write_proc does
    -- not need clamping at all: its case statement already falls through to
    -- "accept and discard" for any idx that is not CONTROL/MODE/TX_LEN,
    -- clamped or not, so a write anywhere in the capture region lands there
    -- automatically with no special-casing - the capture RAM is read-only
    -- from the PS by construction, not because writes are blocked to it
    -- explicitly.
    --
    -- addr(12 downto 2) is 11 bits (0..2047), enough to reach
    -- C_CAPTURE_BASE_WORD + C_CAPTURE_DEPTH - 1 (256 + 1024 - 1 = 1279) with
    -- headroom, while still aliasing within the 64K AXI4-Lite window exactly
    -- as the narrower decode used to (harmless, same as before).
    function word_index (addr : std_logic_vector(31 downto 0)) return natural is
    begin
        return to_integer(unsigned(addr(12 downto 2)));
    end function;

    -- Apply AXI byte strobes to a register update.
    function apply_strb (old_val : std_logic_vector(31 downto 0);
                         new_val : std_logic_vector(31 downto 0);
                         strb    : std_logic_vector(3 downto 0))
        return std_logic_vector is
        variable res : std_logic_vector(31 downto 0);
    begin
        res := old_val;
        for b in 0 to 3 loop
            if strb(b) = '1' then
                res(b*8+7 downto b*8) := new_val(b*8+7 downto b*8);
            end if;
        end loop;
        return res;
    end function;

begin

    s_axi_user_regs_awready <= awready_i;
    s_axi_user_regs_wready  <= wready_i;
    s_axi_user_regs_bvalid  <= bvalid_i;
    s_axi_user_regs_bresp   <= "00";            -- always OKAY
    s_axi_user_regs_arready <= arready_i;
    s_axi_user_regs_rvalid  <= rvalid_i;
    s_axi_user_regs_rdata   <= rdata_i;
    s_axi_user_regs_rresp   <= "00";            -- always OKAY

    fpga_reg    <= reg_file;
    tx_start    <= tx_start_i;
    clr_stats   <= clr_stats_i;
    capture_arm <= capture_arm_i;

    capture_rd_addr <= capture_rd_addr_i;
    capture_rd_en   <= capture_rd_en_i;

    ---------------------------------------------------------------------------
    -- Write channel. Address and data are consumed together, so AW and W may
    -- arrive in either order - the transaction starts once both are valid.
    --
    -- Unchanged in shape from before this region existed: idx is no longer
    -- clamped by word_index, but the case statement below only ever matches
    -- CONTROL/MODE/TX_LEN explicitly and falls through to "accept, discard"
    -- for everything else - which is exactly correct for the capture region
    -- too, with no region-aware logic needed here at all.
    ---------------------------------------------------------------------------
    write_proc : process (clk)
        variable idx    : natural;
        variable ctrl_v : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            if aresetn = '0' then
                reg_file      <= (others => (others => '0'));
                awready_i     <= '0';
                wready_i      <= '0';
                bvalid_i      <= '0';
                tx_start_i    <= '0';
                clr_stats_i   <= '0';
                capture_arm_i <= '0';
            else
                -- single-cycle strobes by default
                awready_i     <= '0';
                wready_i      <= '0';
                tx_start_i    <= '0';
                clr_stats_i   <= '0';
                capture_arm_i <= '0';

                if s_axi_user_regs_awvalid = '1' and s_axi_user_regs_wvalid = '1'
                   and awready_i = '0' and wready_i = '0' and bvalid_i = '0' then

                    awready_i <= '1';
                    wready_i  <= '1';
                    bvalid_i  <= '1';

                    idx := word_index(s_axi_user_regs_awaddr);

                    case idx is
                        when C_REG_CONTROL =>
                            ctrl_v := apply_strb(reg_file(C_REG_CONTROL),
                                                 s_axi_user_regs_wdata,
                                                 s_axi_user_regs_wstrb);
                            -- pulse bits are emitted as one-clock strobes and
                            -- deliberately not retained, so a read-back never
                            -- suggests a transfer is permanently starting.
                            ctrl_v(C_CTRL_TX_START)    := '0';
                            ctrl_v(C_CTRL_CLR_STATS)   := '0';
                            ctrl_v(C_CTRL_CAPTURE_ARM) := '0';
                            reg_file(C_REG_CONTROL) <= ctrl_v;

                            if s_axi_user_regs_wstrb(0) = '1' then
                                tx_start_i    <= s_axi_user_regs_wdata(C_CTRL_TX_START);
                                clr_stats_i   <= s_axi_user_regs_wdata(C_CTRL_CLR_STATS);
                                capture_arm_i <= s_axi_user_regs_wdata(C_CTRL_CAPTURE_ARM);
                            end if;

                        when C_REG_MODE =>
                            reg_file(C_REG_MODE) <=
                                apply_strb(reg_file(C_REG_MODE),
                                           s_axi_user_regs_wdata,
                                           s_axi_user_regs_wstrb);

                        when C_REG_TX_LEN =>
                            reg_file(C_REG_TX_LEN) <=
                                apply_strb(reg_file(C_REG_TX_LEN),
                                           s_axi_user_regs_wdata,
                                           s_axi_user_regs_wstrb);

                        when others =>
                            null;   -- read-only, unmapped, or capture region:
                                    -- accept, discard
                    end case;

                elsif bvalid_i = '1' and s_axi_user_regs_bready = '1' then
                    bvalid_i <= '0';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Read channel.
    --
    -- Control region: single-cycle, exactly as before - decode and rdata_i
    -- both happen in the same transition that accepts the address, so
    -- rvalid_i can be asserted immediately.
    --
    -- Capture region: cannot be single-cycle, because sample_sniffer's BRAM
    -- registers its read output. The address and a one-cycle read pulse are
    -- issued while still accepting the AXI address (arready_i asserted, same
    -- as the control-region path), but rvalid_i is deliberately NOT asserted
    -- yet - RD_CAP_WAIT holds for exactly one more cycle, by which point
    -- capture_rd_data reflects the address just issued, and only THEN is
    -- rdata_i latched and rvalid_i raised. A real capture-region read is
    -- therefore two cycles from ARVALID to RVALID where a control-region read
    -- is one - a real difference the PS-side code does not need to know
    -- about, since it is ordinary AXI wait states, not a different protocol.
    ---------------------------------------------------------------------------
    read_proc : process (clk)
        variable idx      : natural;
        variable ctrl_idx : natural;
        variable cap_idx  : natural;
    begin
        if rising_edge(clk) then
            if aresetn = '0' then
                arready_i         <= '0';
                rvalid_i          <= '0';
                rdata_i           <= (others => '0');
                rd_state          <= RD_IDLE;
                capture_rd_en_i   <= '0';
                capture_rd_addr_i <= 0;
            else
                arready_i       <= '0';
                capture_rd_en_i <= '0';

                case rd_state is
                    when RD_IDLE =>
                        if s_axi_user_regs_arvalid = '1' and arready_i = '0'
                           and rvalid_i = '0' then

                            arready_i <= '1';
                            idx := word_index(s_axi_user_regs_araddr);

                            if idx < C_CAPTURE_BASE_WORD then
                                -- Control region: same clamp-to-last-register
                                -- behaviour as before this region existed -
                                -- see the word_index gotcha note in pkg.vhd's
                                -- register map comment.
                                if idx > C_REG_COUNT - 1 then
                                    ctrl_idx := C_REG_COUNT - 1;
                                else
                                    ctrl_idx := idx;
                                end if;

                                rvalid_i <= '1';

                                case ctrl_idx is
                                    when C_REG_ID =>
                                        rdata_i <= C_ID_MAGIC;

                                    -- writable registers read back what the
                                    -- PS wrote
                                    when C_REG_CONTROL | C_REG_MODE | C_REG_TX_LEN =>
                                        rdata_i <= reg_file(ctrl_idx);

                                    -- read-only registers come from PL
                                    when C_REG_STATUS | C_REG_RX_LEN
                                       | C_REG_FRAME_COUNT | C_REG_ERR_COUNT
                                       | C_REG_SYNC_COUNT  | C_REG_QUAL_MIN
                                       | C_REG_QUAL_MAX    | C_REG_QUAL_SYMS
                                       | C_REG_BUILD_ID =>
                                        rdata_i <= status_reg(ctrl_idx);

                                    when others =>
                                        rdata_i <= (others => '0');
                                end case;
                            else
                                -- Capture region: clamp into the buffer the
                                -- same way, then issue the BRAM read and wait
                                -- one more cycle for it - rvalid_i stays low
                                -- this cycle.
                                if idx - C_CAPTURE_BASE_WORD > C_CAPTURE_DEPTH - 1 then
                                    cap_idx := C_CAPTURE_DEPTH - 1;
                                else
                                    cap_idx := idx - C_CAPTURE_BASE_WORD;
                                end if;

                                capture_rd_addr_i <= cap_idx;
                                capture_rd_en_i   <= '1';
                                rd_state          <= RD_CAP_WAIT;
                            end if;
                        end if;
                    when RD_CAP_WAIT => 
                        -- The BRAM captures capture_rd_addr_i/capture_rd_en_i (stable since
                        -- last cycle) AT this edge; its registered output isn't valid until
                        -- the FOLLOWING edge (READ_LATENCY_B => 1). Nothing to do but wait
                        -- one more cycle for it.
                    
                        rd_state <= RD_CAP_WAIT1;

                    when RD_CAP_WAIT1 =>
                        rdata_i  <= capture_rd_data;
                        rvalid_i <= '1';
                        rd_state <= RD_IDLE;
                end case;

                -- Cannot race the two rvalid_i <= '1' assignments above: both
                -- of those only ever fire in a cycle where rvalid_i's value
                -- FROM BEFORE this edge was '0' (the RD_IDLE accept-path
                -- requires it explicitly; RD_CAP_WAIT is only reached one
                -- cycle after RD_IDLE issued a capture read, during which
                -- rvalid_i was never set). This check reads that same
                -- pre-edge value, so it and they can never both want to
                -- drive rvalid_i in the same cycle - one clears a completed
                -- transfer, the other starts a new one, never both at once.
                if rvalid_i = '1' and s_axi_user_regs_rready = '1' then
                    rvalid_i <= '0';
                end if;
            end if;
        end if;
    end process;

end rtl;
