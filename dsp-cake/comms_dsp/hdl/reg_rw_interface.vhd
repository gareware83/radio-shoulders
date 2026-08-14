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
-- tx_start / clr_stats are write-one pulses: they assert for exactly one
-- clock so PL logic can edge-trigger off them instead of re-triggering every
-- cycle a level-held bit stays set.
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
        -- PL -> PS: values returned for read-only offsets
        status_reg : in  fpgaStatus32;

        -- One-clock pulses decoded from CONTROL writes
        tx_start   : out std_logic;
        clr_stats  : out std_logic
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

    signal tx_start_i  : std_logic;
    signal clr_stats_i : std_logic;

    -- Word index from a byte address. Only the low bits are decoded, so the
    -- map aliases across the 64K window - harmless, and keeps the decode small.
    function word_index (addr : std_logic_vector(31 downto 0)) return natural is
        variable idx : natural;
    begin
        idx := to_integer(unsigned(addr(6 downto 2)));
        if idx > C_REG_COUNT-1 then
            return C_REG_COUNT-1;
        else
            return idx;
        end if;
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

    fpga_reg  <= reg_file;
    tx_start  <= tx_start_i;
    clr_stats <= clr_stats_i;

    ---------------------------------------------------------------------------
    -- Write channel. Address and data are consumed together, so AW and W may
    -- arrive in either order - the transaction starts once both are valid.
    ---------------------------------------------------------------------------
    write_proc : process (clk)
        variable idx    : natural;
        variable ctrl_v : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            if aresetn = '0' then
                reg_file    <= (others => (others => '0'));
                awready_i   <= '0';
                wready_i    <= '0';
                bvalid_i    <= '0';
                tx_start_i  <= '0';
                clr_stats_i <= '0';
            else
                -- single-cycle strobes by default
                awready_i   <= '0';
                wready_i    <= '0';
                tx_start_i  <= '0';
                clr_stats_i <= '0';

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
                            ctrl_v(C_CTRL_TX_START)  := '0';
                            ctrl_v(C_CTRL_CLR_STATS) := '0';
                            reg_file(C_REG_CONTROL) <= ctrl_v;

                            if s_axi_user_regs_wstrb(0) = '1' then
                                tx_start_i  <= s_axi_user_regs_wdata(C_CTRL_TX_START);
                                clr_stats_i <= s_axi_user_regs_wdata(C_CTRL_CLR_STATS);
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
                            null;   -- read-only or unmapped: accept, discard
                    end case;

                elsif bvalid_i = '1' and s_axi_user_regs_bready = '1' then
                    bvalid_i <= '0';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Read channel. Single-cycle: the mux is combinational off the latched
    -- index, so no wait states are needed.
    ---------------------------------------------------------------------------
    read_proc : process (clk)
        variable idx : natural;
    begin
        if rising_edge(clk) then
            if aresetn = '0' then
                arready_i <= '0';
                rvalid_i  <= '0';
                rdata_i   <= (others => '0');
            else
                arready_i <= '0';

                if s_axi_user_regs_arvalid = '1' and arready_i = '0' and rvalid_i = '0' then
                    arready_i <= '1';
                    rvalid_i  <= '1';

                    idx := word_index(s_axi_user_regs_araddr);

                    case idx is
                        when C_REG_ID =>
                            rdata_i <= C_ID_MAGIC;

                        -- writable registers read back what the PS wrote
                        when C_REG_CONTROL | C_REG_MODE | C_REG_TX_LEN =>
                            rdata_i <= reg_file(idx);

                        -- read-only registers come from PL
                        when C_REG_STATUS | C_REG_RX_LEN
                           | C_REG_FRAME_COUNT | C_REG_ERR_COUNT
                           | C_REG_SYNC_COUNT | C_REG_QUAL_MIN
                           | C_REG_QUAL_MAX   | C_REG_QUAL_SYMS
                           | C_REG_BUILD_ID =>
                            rdata_i <= status_reg(idx);

                        when others =>
                            rdata_i <= (others => '0');
                    end case;

                elsif rvalid_i = '1' and s_axi_user_regs_rready = '1' then
                    rvalid_i <= '0';
                end if;
            end if;
        end if;
    end process;

end rtl;
