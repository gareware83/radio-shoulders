-- tb_reg_rw_interface.vhd
-- Self-checking AXI4-Lite testbench for work.reg_rw_interface
-- VHDL-2008
--And a good example of chat gpt generated nonsense!
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.all; 
use work.dsp_pkg.all;

entity tb_reg_rw_interface is
end entity;

architecture sim of tb_reg_rw_interface is


  -- ---------------------------------------------------------------------------
  -- Parameters
  -- ---------------------------------------------------------------------------
  constant C_CLK_PERIOD    : time := 10 ns;  -- 100 MHz
  constant C_TIMEOUT_CYC   : natural := 1000;

  -- ---------------------------------------------------------------------------
  -- DUT ports/signals (match your port map names/shapes)
  -- ---------------------------------------------------------------------------
  signal clk                      : std_logic := '0';
  signal aresetn                  : std_logic := '0';

  signal S01_AXI_0_AWADDR        : std_logic_vector(31 downto 0) := (others => '0');
  signal S01_AXI_0_AWPROT        : std_logic_vector(2 downto 0)  := (others => '0');
  signal S01_AXI_0_AWVALID       : std_logic_vector(0 downto 0)  := (others => '0');
  signal S01_AXI_0_WDATA         : std_logic_vector(31 downto 0) := (others => '0');
  signal S01_AXI_0_WSTRB         : std_logic_vector(3 downto 0)  := (others => '0');
  signal S01_AXI_0_WVALID        : std_logic_vector(0 downto 0)  := (others => '0');
  signal S01_AXI_0_AWREADY       : std_logic_vector(0 downto 0);
  signal S01_AXI_0_WREADY        : std_logic_vector(0 downto 0);
  signal S01_AXI_0_BRESP         : std_logic_vector(1 downto 0);
  signal S01_AXI_0_BVALID        : std_logic_vector(0 downto 0);
  signal S01_AXI_0_BREADY        : std_logic_vector(0 downto 0)  := (others => '0');

  signal S01_AXI_0_ARADDR        : std_logic_vector(31 downto 0) := (others => '0');
  signal S01_AXI_0_ARPROT        : std_logic_vector(2 downto 0)  := (others => '0');
  signal S01_AXI_0_ARVALID       : std_logic_vector(0 downto 0)  := (others => '0');
  signal S01_AXI_0_ARREADY       : std_logic_vector(0 downto 0);
  signal S01_AXI_0_RDATA         : std_logic_vector(31 downto 0);
  signal S01_AXI_0_RRESP         : std_logic_vector(1 downto 0);
  signal S01_AXI_0_RVALID        : std_logic_vector(0 downto 0);
  signal S01_AXI_0_RREADY        : std_logic_vector(0 downto 0)  := (others => '0');

  -- fpga_reg type: adjust to your actual type if different
  signal fpga_reg                : fpgaReg32;

  -- Helpers (scalar views of 1-bit vectors)
  alias AWVALID  : std_logic is S01_AXI_0_AWVALID(0);
  alias WVALID   : std_logic is S01_AXI_0_WVALID(0);
  alias AWREADY  : std_logic is S01_AXI_0_AWREADY(0);
  alias WREADY   : std_logic is S01_AXI_0_WREADY(0);
  alias BVALID   : std_logic is S01_AXI_0_BVALID(0);
  alias BREADY   : std_logic is S01_AXI_0_BREADY(0);
  alias ARVALID  : std_logic is S01_AXI_0_ARVALID(0);
  alias ARREADY  : std_logic is S01_AXI_0_ARREADY(0);
  alias RVALID   : std_logic is S01_AXI_0_RVALID(0);
  alias RREADY   : std_logic is S01_AXI_0_RREADY(0);
  
  ------------------------
--Procedures
-------------------------
procedure axi_write(signal addr : in std_logic_vector(31 downto 0);
                    signal data : in std_logic_vector(31 downto 0);
                    signal  strb : in std_logic_vector(3 downto 0) ) is--:= "1111"
    variable aw_done, w_done : boolean := false;
    variable timeout         : natural := 0;
  begin
    -- Drive address & data channels
    S01_AXI_0_AWADDR <= addr;
    S01_AXI_0_AWPROT <= (others => '0');
    S01_AXI_0_WDATA  <= data;
    S01_AXI_0_WSTRB  <= strb;

    AWVALID <= '1';
    WVALID  <= '1';

    -- Handshake either order (AXI allows it)
    while (not (aw_done and w_done)) loop
      wait until rising_edge(clk);
      if (AWVALID = '1' and AWREADY = '1') then
        AWVALID <= '0';
        aw_done := true;
      end if;
      if (WVALID = '1' and WREADY = '1') then
        WVALID <= '0';
        w_done := true;
      end if;
      timeout := timeout + 1;
      assert timeout < C_TIMEOUT_CYC report "AXI write address/data handshake timeout" severity failure;
    end loop;

    -- B channel
    BREADY <= '1';
    timeout := 0;
    loop
      wait until rising_edge(clk);
      exit when (BVALID = '1');
      timeout := timeout + 1;
      assert timeout < C_TIMEOUT_CYC report "AXI write response timeout" severity failure;
    end loop;
    -- Optionally check OKAY
    assert (S01_AXI_0_BRESP = "00") report "Write BRESP not OKAY" severity error;
    BREADY <= '0';
  end procedure;

  procedure axi_read(addr : in  std_logic_vector(31 downto 0);
                     data : out std_logic_vector(31 downto 0)) is
    variable timeout : natural := 0;
  begin
    -- AR channel
    S01_AXI_0_ARADDR <= addr;
    S01_AXI_0_ARPROT <= (others => '0');
    ARVALID <= '1';
    loop
      wait until rising_edge(clk);
      exit when (ARVALID = '1' and ARREADY = '1');
      timeout := timeout + 1;
      assert timeout < C_TIMEOUT_CYC report "AXI read address handshake timeout" severity failure;
    end loop;
    ARVALID <= '0';

    -- R channel
    RREADY <= '1';
    timeout := 0;
    loop
      wait until rising_edge(clk);
      exit when (RVALID = '1');
      timeout := timeout + 1;
      assert timeout < C_TIMEOUT_CYC report "AXI read data timeout" severity failure;
    end loop;
    data := S01_AXI_0_RDATA;
    -- Optionally check OKAY
    assert (S01_AXI_0_RRESP = "00") report "Read RRESP not OKAY" severity error;
    RREADY <= '0';
  end procedure;


begin
  -- ---------------------------------------------------------------------------
  -- DUT Instance
  -- ---------------------------------------------------------------------------
  reg_inst : entity work.reg_rw_interface
    port map (
      clk                      => clk,
      aresetn                  => aresetn,
      s_axi_user_regs_awaddr   => S01_AXI_0_AWADDR,
      s_axi_user_regs_awprot   => S01_AXI_0_AWPROT,
      s_axi_user_regs_awvalid  => S01_AXI_0_AWVALID(0),
      s_axi_user_regs_wdata    => S01_AXI_0_WDATA,
      s_axi_user_regs_wstrb    => S01_AXI_0_WSTRB,
      s_axi_user_regs_wvalid   => S01_AXI_0_WVALID(0),
      s_axi_user_regs_awready  => S01_AXI_0_AWREADY(0),
      s_axi_user_regs_wready   => S01_AXI_0_WREADY(0),
      s_axi_user_regs_bresp    => S01_AXI_0_BRESP,
      s_axi_user_regs_bvalid   => S01_AXI_0_BVALID(0),
      s_axi_user_regs_bready   => S01_AXI_0_BREADY(0),
      s_axi_user_regs_araddr   => S01_AXI_0_ARADDR,
      s_axi_user_regs_arprot   => S01_AXI_0_ARPROT,
      s_axi_user_regs_arvalid  => S01_AXI_0_ARVALID(0),
      s_axi_user_regs_arready  => S01_AXI_0_ARREADY(0),
      s_axi_user_regs_rdata    => S01_AXI_0_RDATA,
      s_axi_user_regs_rresp    => S01_AXI_0_RRESP,
      s_axi_user_regs_rvalid   => S01_AXI_0_RVALID(0),
      s_axi_user_regs_rready   => S01_AXI_0_RREADY(0),
      fpga_reg                 => fpga_reg
    );

  -- ---------------------------------------------------------------------------
  -- Clock / Reset
  -- ---------------------------------------------------------------------------
  clk <= not clk after C_CLK_PERIOD/2;

  process
  begin
    -- Active-low reset
    aresetn <= '0';
    wait for 10*C_CLK_PERIOD;
    aresetn <= '1';
    wait;
  end process;

  -- ---------------------------------------------------------------------------
  -- AXI4-Lite master helper procedures
  -- ---------------------------------------------------------------------------
  
 -- procedure <PROC_NAME> (<comma_separated_inputs> : in <type>;
 --                         <comma_separated_outputs> : out <type>) is
 --     -- subprogram_declarative_items (constant declarations, variable declarations, etc.)
 --  begin
 --     -- procedure body
 --  end <PROC_NAME>;
 
 
  -- ---------------------------------------------------------------------------
  -- Test sequence
  -- ---------------------------------------------------------------------------
  stim : process
    variable rd : std_logic_vector(31 downto 0);
    variable exp: std_logic_vector(31 downto 0);
  begin
    -- Wait for reset deassertion
    wait until aresetn = '1';
    wait until rising_edge(clk);
    report "Starting AXI4-Lite register tests..." severity note;

    -- 1) Write/Read @0x0000
    axi_write(x"00000000", x"DEADBEEF", "1111");
    axi_read (x"00000000", rd);
    assert rd = x"DEADBEEF" report "Mismatch @0x0" severity failure;

    -- 2) Write/Read @0x0004
    axi_write(x"00000004", x"12345678", "1111");
    axi_read (x"00000004", rd);
    assert rd = x"12345678" report "Mismatch @0x4" severity failure;

    -- 3) Partial write (WSTRB test) LSByte only at 0x0000
    axi_write(x"00000000", x"000000AA", "0001");
    axi_read (x"00000000", rd);
    exp := x"DEADBEEF";    -- previous value
    exp(7 downto 0) := x"AA";
    assert rd = exp report "WSTRB byte update failed @0x0" severity failure;

    -- Optional: observe fpga_reg (if DUT mirrors a status register)
    report "fpga_reg = " & to_hstring(fpga_reg) severity note;

    report "All AXI4-Lite register tests PASSED." severity note;
    wait for 20*C_CLK_PERIOD;
    std.env.stop;
    wait;
  end process;

end architecture;
