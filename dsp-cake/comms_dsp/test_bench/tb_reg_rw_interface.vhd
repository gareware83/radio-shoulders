-- tb_reg_rw_interface.vhd
-- Self-checking AXI4-Lite testbench for work.reg_rw_interface, together with
-- work.sample_sniffer - wired exactly as system_top.vhd wires them, not
-- tested in isolation, because the thing most worth verifying here is the
-- read-LATENCY contract between the two: reg_rw_interface's capture-region
-- read state (RD_CAP_WAIT) exists specifically to match sample_sniffer's
-- registered BRAM output, and that contract is only real if both sides of it
-- are actually exercised together.
--
-- Rewritten from an earlier version whose own top comment called it
-- "chat gpt generated nonsense" - accurately: its first test wrote
-- DEADBEEF to word 0 (ID_VERSION) and asserted the readback matched, which
-- cannot pass against the real module - ID_VERSION is read-only and always
-- answers C_ID_MAGIC, independent of anything ever written there.
--
-- VHDL-2008
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.all;
use work.pkg.all;

entity tb_reg_rw_interface is
end entity;

architecture sim of tb_reg_rw_interface is

  constant C_CLK_PERIOD  : time    := 10 ns;   -- 100 MHz
  constant C_TIMEOUT_CYC : natural := 2000;

  -- sample_sniffer is instantiated below at its DEFAULT generics (the real
  -- C_CAPTURE_DEPTH/C_CAPTURE_ADDR_W from pkg.vhd), deliberately not a
  -- smaller override for faster simulation. reg_rw_interface's
  -- capture-region clamp is hardcoded to the PACKAGE constant
  -- C_CAPTURE_DEPTH, not to whatever depth the instantiated sniffer actually
  -- has - true by construction here since both come from the same constant,
  -- but a smaller sniffer generic would silently break that coupling and
  -- drive an out-of-range value into rd_addr's "natural range 0 to
  -- G_DEPTH-1" port. Exactly matching production sidesteps the mismatch
  -- rather than working around it, and 1024 cycles costs nothing in
  -- simulated or wall-clock time anyway.

  signal clk     : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal rst     : std_logic;   -- active-high, for sample_sniffer

  signal AWADDR  : std_logic_vector(31 downto 0) := (others => '0');
  signal AWPROT  : std_logic_vector(2 downto 0)  := (others => '0');
  signal AWVALID : std_logic := '0';
  signal AWREADY : std_logic;
  signal WDATA   : std_logic_vector(31 downto 0) := (others => '0');
  signal WSTRB   : std_logic_vector(3 downto 0)  := (others => '0');
  signal WVALID  : std_logic := '0';
  signal WREADY  : std_logic;
  signal BRESP   : std_logic_vector(1 downto 0);
  signal BVALID  : std_logic;
  signal BREADY  : std_logic := '0';

  signal ARADDR  : std_logic_vector(31 downto 0) := (others => '0');
  signal ARPROT  : std_logic_vector(2 downto 0)  := (others => '0');
  signal ARVALID : std_logic := '0';
  signal ARREADY : std_logic;
  signal RDATA   : std_logic_vector(31 downto 0);
  signal RRESP   : std_logic_vector(1 downto 0);
  signal RVALID  : std_logic;
  signal RREADY  : std_logic := '0';

  signal fpga_reg   : fpgaReg32;
  signal status_reg : fpgaStatus32 := (others => (others => '0'));
  signal tx_start, clr_stats, capture_arm : std_logic;

  signal capture_rd_addr : natural range 0 to C_CAPTURE_DEPTH - 1;
  signal capture_rd_en   : std_logic;
  signal capture_rd_data : std_logic_vector(31 downto 0);

  -- sample_sniffer tap inputs - only the "sym" tap is exercised (tap_sel =
  -- C_TAP_SYM); the other three just need a defined, unused value.
  signal ddc_i, ddc_q, pll_i, pll_q, filt_i, filt_q, sym_i, sym_q
    : signed(15 downto 0) := (others => '0');
  signal ddc_valid, pll_valid, filt_valid, sym_valid : std_logic := '0';
  signal capture_done : std_logic;

  ------------------------------------------------------------------------
  -- AXI4-Lite master procedures
  ------------------------------------------------------------------------
  procedure axi_write(addr : in std_logic_vector(31 downto 0);
                      data : in std_logic_vector(31 downto 0);
                      strb : in std_logic_vector(3 downto 0)) is
    variable aw_done, w_done : boolean := false;
    variable timeout         : natural := 0;
  begin
    AWADDR <= addr; 
    AWPROT <= (others => '0');
    WDATA  <= data; 
    WSTRB  <= strb;
    AWVALID <= '1';
     WVALID <= '1';

    while not (aw_done and w_done) loop
      wait until rising_edge(clk);
      if AWVALID = '1' and AWREADY = '1' then
        AWVALID <= '0'; 
        aw_done := true;
      end if;
      if WVALID = '1' and WREADY = '1' then
        WVALID <= '0'; 
        w_done := true;
      end if;
      timeout := timeout + 1;
      assert timeout < C_TIMEOUT_CYC
        report "AXI write address/data handshake timeout" severity failure;
    end loop;

    BREADY <= '1';
    timeout := 0;
    loop
      wait until rising_edge(clk);
      exit when BVALID = '1';
      timeout := timeout + 1;
      assert timeout < C_TIMEOUT_CYC
        report "AXI write response timeout" severity failure;
    end loop;
    assert BRESP = "00" report "Write BRESP not OKAY" severity error;
    BREADY <= '0';
  end procedure;

  procedure axi_read(addr : in  std_logic_vector(31 downto 0);
                     data : out std_logic_vector(31 downto 0)) is
    variable timeout : natural := 0;
  begin
    ARADDR <= addr; ARPROT <= (others => '0');
    ARVALID <= '1';
    loop
      wait until rising_edge(clk);
      exit when ARVALID = '1' and ARREADY = '1';
      timeout := timeout + 1;
      assert timeout < C_TIMEOUT_CYC
        report "AXI read address handshake timeout" severity failure;
    end loop;
    ARVALID <= '0';

    RREADY <= '1';
    timeout := 0;
    loop
      wait until rising_edge(clk);
      exit when RVALID = '1';
      timeout := timeout + 1;
      assert timeout < C_TIMEOUT_CYC
        report "AXI read data timeout" severity failure;
    end loop;
    data := RDATA;
    assert RRESP = "00" report "Read RRESP not OKAY" severity error;
    RREADY <= '0';
  end procedure;

  -- One clock of a tap sample with valid asserted - models what a real DSP
  -- stage would do, one sample per pulse.
  procedure feed_sym(i, q : in integer) is
  begin
    sym_i <= to_signed(i, 16);
    sym_q <= to_signed(q, 16);
    sym_valid <= '1';
    wait until rising_edge(clk);
    sym_valid <= '0';
  end procedure;

begin

  rst <= not aresetn;

  reg_inst : entity work.reg_rw_interface
    port map (
      clk                      => clk,
      aresetn                  => aresetn,
      s_axi_user_regs_awaddr   => AWADDR,
      s_axi_user_regs_awprot   => AWPROT,
      s_axi_user_regs_awvalid  => AWVALID,
      s_axi_user_regs_awready  => AWREADY,
      s_axi_user_regs_wdata    => WDATA,
      s_axi_user_regs_wstrb    => WSTRB,
      s_axi_user_regs_wvalid   => WVALID,
      s_axi_user_regs_wready   => WREADY,
      s_axi_user_regs_bresp    => BRESP,
      s_axi_user_regs_bvalid   => BVALID,
      s_axi_user_regs_bready   => BREADY,
      s_axi_user_regs_araddr   => ARADDR,
      s_axi_user_regs_arprot   => ARPROT,
      s_axi_user_regs_arvalid  => ARVALID,
      s_axi_user_regs_arready  => ARREADY,
      s_axi_user_regs_rdata    => RDATA,
      s_axi_user_regs_rresp    => RRESP,
      s_axi_user_regs_rvalid   => RVALID,
      s_axi_user_regs_rready   => RREADY,
      fpga_reg                 => fpga_reg,
      status_reg                => status_reg,
      tx_start                 => tx_start,
      clr_stats                => clr_stats,
      capture_arm               => capture_arm,
      capture_rd_addr           => capture_rd_addr,
      capture_rd_en             => capture_rd_en,
      capture_rd_data           => capture_rd_data
    );

  -- Wired exactly as system_top.vhd wires it: default generics (the real
  -- production capture depth - see the note above), tap_sel straight off
  -- fpga_reg's MODE field rather than a testbench-only shortcut.
  sniffer_inst : entity work.sample_sniffer
    port map (
      clk => clk,
      rst => rst,

      ddc_i => ddc_i, ddc_q => ddc_q, ddc_valid => ddc_valid,
      pll_i => pll_i, pll_q => pll_q, pll_valid => pll_valid,
      filtered_i => filt_i, filtered_q => filt_q, filtered_valid => filt_valid,
      sym_i => sym_i, sym_q => sym_q, sym_valid => sym_valid,

      tap_sel => fpga_reg(C_REG_MODE)(C_MODE_CAPTURE_TAP_RANGE),

      arm  => capture_arm,
      done => capture_done,

      rd_addr => capture_rd_addr,
      rd_en   => capture_rd_en,
      rd_data => capture_rd_data
    );

  clk <= not clk after C_CLK_PERIOD / 2;

  process
  begin
    aresetn <= '0';
    wait for 10 * C_CLK_PERIOD;
    aresetn <= '1';
    wait;
  end process;

  ------------------------------------------------------------------------
  -- Test sequence
  ------------------------------------------------------------------------
  stim : process
    variable rd  : std_logic_vector(31 downto 0);
    variable exp : std_logic_vector(31 downto 0);
    variable timeout : natural;
  begin
    wait until aresetn = '1';
    wait until rising_edge(clk);
    report "Starting AXI4-Lite register tests..." severity note;

    -----------------------------------------------------------------
    -- 1) ID_VERSION is read-only: a write is discarded, the read always
    --    answers C_ID_MAGIC regardless.
    -----------------------------------------------------------------
    axi_write(x"00000000", x"DEADBEEF", "1111");
    axi_read (x"00000000", rd);
    assert rd = C_ID_MAGIC
      report "ID_VERSION did not read back C_ID_MAGIC" severity failure;

    -----------------------------------------------------------------
    -- 2) CONTROL/MODE/TX_LEN are genuinely read/write, and round-trip.
    -----------------------------------------------------------------
    axi_write(x"00000008", x"00000001", "1111");   -- MODE, word 2
    axi_read (x"00000008", rd);
    assert rd = x"00000001" report "MODE readback mismatch" severity failure;

    axi_write(x"00000010", x"000000AA", "1111");   -- TX_LEN, word 4
    axi_read (x"00000010", rd);
    assert rd = x"000000AA" report "TX_LEN readback mismatch" severity failure;

    -- WSTRB: strobe "0001" touches only byte 0. Previous value was
    -- 0x000000AA; writing 0xFFFFFF55 with byte 0 alone selected should leave
    -- bytes 1-3 at their old value (all zero) and replace only byte 0 (0x55).
    axi_write(x"00000010", x"FFFFFF55", "0001");
    axi_read (x"00000010", rd);
    assert rd = x"00000055"
      report "WSTRB byte-0-only write touched bytes it should not have"
      severity failure;

    -----------------------------------------------------------------
    -- 3) CONTROL pulse bits (TX_START/CLR_STATS/CAPTURE_ARM) self-clear:
    --    the write takes effect (tx_start/clr_stats/capture_arm pulse for
    --    one cycle - not observed directly here, since that would need a
    --    same-cycle wait; self-clearing is confirmed via the readback
    --    below), but the stored bit reads back 0, not 1.
    -----------------------------------------------------------------
    -- ENABLE(0) | TX_START(1) | CLR_STATS(3) | CAPTURE_ARM(4) = 0b11011
    axi_write(x"00000004", x"0000001B", "1111");
    axi_read (x"00000004", rd);
    assert rd(C_CTRL_TX_START) = '0'
      report "TX_START did not self-clear" severity failure;
    assert rd(C_CTRL_CLR_STATS) = '0'
      report "CLR_STATS did not self-clear" severity failure;
    assert rd(C_CTRL_CAPTURE_ARM) = '0'
      report "CAPTURE_ARM did not self-clear" severity failure;
    assert rd(C_CTRL_ENABLE) = '1'
      report "ENABLE (a non-pulse bit) was not retained" severity failure;

    -----------------------------------------------------------------
    -- 4) Control-region gap clamps to the last implemented register
    --    (C_REG_COUNT-1 = word 12 = BUILD_ID here), rather than reading
    --    zero or garbage - the documented gotcha in pkg.vhd's register map
    --    comment, still true after widening the decode for the capture
    --    region. Word 40 is comfortably inside the gap (13 <= 40 < 256).
    -----------------------------------------------------------------
    axi_read (std_logic_vector(to_unsigned(C_REG_BUILD_ID * 4, 32)), exp);
    axi_read (std_logic_vector(to_unsigned(40 * 4, 32)), rd);
    assert rd = exp
      report "control-region gap did not clamp to the last register"
      severity failure;

    -----------------------------------------------------------------
    -- 5) Capture region: select the SYM tap, arm, feed C_CAPTURE_DEPTH known
    --    samples, wait for CAPTURE_DONE, then read every word back through
    --    the AXI4-Lite window and check it round-tripped exactly - this is
    --    the read-latency path (RD_CAP_WAIT) actually being exercised
    --    end-to-end, not just reasoned about.
    -----------------------------------------------------------------
    axi_write(x"00000008", x"00000300", "1111");  -- MODE.CAPTURE_TAP = "11" (SYM)
    axi_write(x"00000004", x"00000011", "1111");  -- ENABLE | CAPTURE_ARM

    -- CAPTURE_ARM took effect on the write above; sample_sniffer is now
    -- "filling". Feed exactly C_CAPTURE_DEPTH samples, each i=n, q=-n so I and
    -- Q are distinguishable in the readback.
    for n in 0 to C_CAPTURE_DEPTH - 1 loop
      feed_sym(n, -n);
    end loop;

    timeout := 0;
    while capture_done /= '1' loop
      wait until rising_edge(clk);
      timeout := timeout + 1;
      assert timeout < C_TIMEOUT_CYC
        report "CAPTURE_DONE never asserted after a full fill" severity failure;
    end loop;

    for n in 0 to C_CAPTURE_DEPTH - 1 loop
      axi_read(std_logic_vector(to_unsigned((256 + n) * 4, 32)), rd);
      exp := std_logic_vector(to_signed(-n, 16)) & std_logic_vector(to_signed(n, 16));
      assert rd = exp
        report "capture word " & integer'image(n) & " mismatch: got " &
               to_hstring(rd) & " expected " & to_hstring(exp)
        severity failure;
    end loop;

    -----------------------------------------------------------------
    -- 6) Reading past the capture depth clamps to the last word, same
    --    "defined behaviour instead of a gap" rule as the control region.
    -----------------------------------------------------------------
    axi_read(std_logic_vector(to_unsigned((256 + C_CAPTURE_DEPTH - 1) * 4, 32)), exp);
    axi_read(std_logic_vector(to_unsigned((256 + C_CAPTURE_DEPTH + 5) * 4, 32)), rd);
    assert rd = exp
      report "capture-region overrun did not clamp to the last word"
      severity failure;

    report "All reg_rw_interface + sample_sniffer tests PASSED." severity note;
    wait for 20 * C_CLK_PERIOD;
    std.env.stop;
    wait;
  end process;

end architecture;
