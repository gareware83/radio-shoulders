# Clock-domain-crossing constraint for dsp_top's dedicated sample clock.
#
# The first hand-authored constraint this project has needed: until dsp_clk
# (FCLK1, 1 MHz) existed, everything ran off FCLK0 and Vivado's automatic
# clock derivation from the PS7 BD cell was sufficient - no XDC file was
# ever required. Two genuinely independent, asynchronous clocks changes
# that: without this, Vivado's static timing analyzer applies a normal
# synchronous setup/hold check across a boundary that by design has no
# fixed phase relationship, and reports it failing - not a real violation,
# a missing constraint.
#
# xpm_fifo_async (dsp-cake/comms_dsp/hdl/axis_cdc_fifo.vhd) handles the
# FUNCTIONAL metastability correctly on its own via CDC_SYNC_STAGES, but
# per Xilinx's own guidance that does not exempt the design from also
# declaring the two clocks as an asynchronous group here - the same applies
# to system_top.vhd's hand-written tap_sync_proc synchronizer (the
# diagnostic sample-sniffer tap crossing), which has no XPM macro to do it
# automatically. This one constraint covers both: everything downstream of
# clk vs. everything downstream of dsp_clk is now exempted from inter-clock
# timing analysis, project-wide.
#
# get_clocks -of_objects [get_nets ...] rather than a specific clock name
# (e.g. clk_fpga_0) deliberately - it resolves whatever clock object Vivado
# actually created for the named net, so this does not depend on guessing
# the PS7 BD's auto-generated clock naming convention, which can vary
# between Vivado versions/project regenerations.
#
# clk = FCLK0 (via system_top.vhd's ps_i port map, ,fclk => clk)
# dsp_clk = FCLK1, dsp_top's own sample clock (,fclk1 => dsp_clk)
#
# Add to the project: Vivado GUI "Add Sources" -> Add or Create Constraints,
# or from the Tcl console:
#   add_files -fileset constrs_1 -norecurse vivado/constraints/system_top_cdc.xdc
set_clock_groups -asynchronous -group [get_clocks -of_objects [get_nets clk]] -group [get_clocks -of_objects [get_nets dsp_clk]]

set_property MARK_DEBUG true [get_nets dsp_clk]

create_debug_core u_ila_0 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_0]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_0]
set_property C_DATA_DEPTH 8192 [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 2 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property port_width 1 [get_debug_ports u_ila_0/clk]
connect_debug_port u_ila_0/clk [get_nets [list ps_i/system_i/processing_system7_0/inst/FCLK_CLK1]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe0]
set_property port_width 16 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 [get_nets [list {uut/pll_gen.inst_pll/nco_sin[0]} {uut/pll_gen.inst_pll/nco_sin[1]} {uut/pll_gen.inst_pll/nco_sin[2]} {uut/pll_gen.inst_pll/nco_sin[3]} {uut/pll_gen.inst_pll/nco_sin[4]} {uut/pll_gen.inst_pll/nco_sin[5]} {uut/pll_gen.inst_pll/nco_sin[6]} {uut/pll_gen.inst_pll/nco_sin[7]} {uut/pll_gen.inst_pll/nco_sin[8]} {uut/pll_gen.inst_pll/nco_sin[9]} {uut/pll_gen.inst_pll/nco_sin[10]} {uut/pll_gen.inst_pll/nco_sin[11]} {uut/pll_gen.inst_pll/nco_sin[12]} {uut/pll_gen.inst_pll/nco_sin[13]} {uut/pll_gen.inst_pll/nco_sin[14]} {uut/pll_gen.inst_pll/nco_sin[15]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe1]
set_property port_width 32 [get_debug_ports u_ila_0/probe1]
connect_debug_port u_ila_0/probe1 [get_nets [list {uut/timing_gen.inst_timing/mu[0]} {uut/timing_gen.inst_timing/mu[1]} {uut/timing_gen.inst_timing/mu[2]} {uut/timing_gen.inst_timing/mu[3]} {uut/timing_gen.inst_timing/mu[4]} {uut/timing_gen.inst_timing/mu[5]} {uut/timing_gen.inst_timing/mu[6]} {uut/timing_gen.inst_timing/mu[7]} {uut/timing_gen.inst_timing/mu[8]} {uut/timing_gen.inst_timing/mu[9]} {uut/timing_gen.inst_timing/mu[10]} {uut/timing_gen.inst_timing/mu[11]} {uut/timing_gen.inst_timing/mu[12]} {uut/timing_gen.inst_timing/mu[13]} {uut/timing_gen.inst_timing/mu[14]} {uut/timing_gen.inst_timing/mu[15]} {uut/timing_gen.inst_timing/mu[16]} {uut/timing_gen.inst_timing/mu[17]} {uut/timing_gen.inst_timing/mu[18]} {uut/timing_gen.inst_timing/mu[19]} {uut/timing_gen.inst_timing/mu[20]} {uut/timing_gen.inst_timing/mu[21]} {uut/timing_gen.inst_timing/mu[22]} {uut/timing_gen.inst_timing/mu[23]} {uut/timing_gen.inst_timing/mu[24]} {uut/timing_gen.inst_timing/mu[25]} {uut/timing_gen.inst_timing/mu[26]} {uut/timing_gen.inst_timing/mu[27]} {uut/timing_gen.inst_timing/mu[28]} {uut/timing_gen.inst_timing/mu[29]} {uut/timing_gen.inst_timing/mu[30]} {uut/timing_gen.inst_timing/mu[31]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe2]
set_property port_width 32 [get_debug_ports u_ila_0/probe2]
connect_debug_port u_ila_0/probe2 [get_nets [list {uut/timing_gen.inst_timing/incr[0]} {uut/timing_gen.inst_timing/incr[1]} {uut/timing_gen.inst_timing/incr[2]} {uut/timing_gen.inst_timing/incr[3]} {uut/timing_gen.inst_timing/incr[4]} {uut/timing_gen.inst_timing/incr[5]} {uut/timing_gen.inst_timing/incr[6]} {uut/timing_gen.inst_timing/incr[7]} {uut/timing_gen.inst_timing/incr[8]} {uut/timing_gen.inst_timing/incr[9]} {uut/timing_gen.inst_timing/incr[10]} {uut/timing_gen.inst_timing/incr[11]} {uut/timing_gen.inst_timing/incr[12]} {uut/timing_gen.inst_timing/incr[13]} {uut/timing_gen.inst_timing/incr[14]} {uut/timing_gen.inst_timing/incr[15]} {uut/timing_gen.inst_timing/incr[16]} {uut/timing_gen.inst_timing/incr[17]} {uut/timing_gen.inst_timing/incr[18]} {uut/timing_gen.inst_timing/incr[19]} {uut/timing_gen.inst_timing/incr[20]} {uut/timing_gen.inst_timing/incr[21]} {uut/timing_gen.inst_timing/incr[22]} {uut/timing_gen.inst_timing/incr[23]} {uut/timing_gen.inst_timing/incr[24]} {uut/timing_gen.inst_timing/incr[25]} {uut/timing_gen.inst_timing/incr[26]} {uut/timing_gen.inst_timing/incr[27]} {uut/timing_gen.inst_timing/incr[28]} {uut/timing_gen.inst_timing/incr[29]} {uut/timing_gen.inst_timing/incr[30]} {uut/timing_gen.inst_timing/incr[31]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe3]
set_property port_width 32 [get_debug_ports u_ila_0/probe3]
connect_debug_port u_ila_0/probe3 [get_nets [list {uut/timing_err[0]} {uut/timing_err[1]} {uut/timing_err[2]} {uut/timing_err[3]} {uut/timing_err[4]} {uut/timing_err[5]} {uut/timing_err[6]} {uut/timing_err[7]} {uut/timing_err[8]} {uut/timing_err[9]} {uut/timing_err[10]} {uut/timing_err[11]} {uut/timing_err[12]} {uut/timing_err[13]} {uut/timing_err[14]} {uut/timing_err[15]} {uut/timing_err[16]} {uut/timing_err[17]} {uut/timing_err[18]} {uut/timing_err[19]} {uut/timing_err[20]} {uut/timing_err[21]} {uut/timing_err[22]} {uut/timing_err[23]} {uut/timing_err[24]} {uut/timing_err[25]} {uut/timing_err[26]} {uut/timing_err[27]} {uut/timing_err[28]} {uut/timing_err[29]} {uut/timing_err[30]} {uut/timing_err[31]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe4]
set_property port_width 2 [get_debug_ports u_ila_0/probe4]
connect_debug_port u_ila_0/probe4 [get_nets [list {uut/sliced_bits[0]} {uut/sliced_bits[1]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe5]
set_property port_width 8 [get_debug_ports u_ila_0/probe5]
connect_debug_port u_ila_0/probe5 [get_nets [list {uut/fb_len[0]} {uut/fb_len[1]} {uut/fb_len[2]} {uut/fb_len[3]} {uut/fb_len[4]} {uut/fb_len[5]} {uut/fb_len[6]} {uut/fb_len[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe6]
set_property port_width 32 [get_debug_ports u_ila_0/probe6]
connect_debug_port u_ila_0/probe6 [get_nets [list {uut/pll_gen.inst_pll/u[0]} {uut/pll_gen.inst_pll/u[1]} {uut/pll_gen.inst_pll/u[2]} {uut/pll_gen.inst_pll/u[3]} {uut/pll_gen.inst_pll/u[4]} {uut/pll_gen.inst_pll/u[5]} {uut/pll_gen.inst_pll/u[6]} {uut/pll_gen.inst_pll/u[7]} {uut/pll_gen.inst_pll/u[8]} {uut/pll_gen.inst_pll/u[9]} {uut/pll_gen.inst_pll/u[10]} {uut/pll_gen.inst_pll/u[11]} {uut/pll_gen.inst_pll/u[12]} {uut/pll_gen.inst_pll/u[13]} {uut/pll_gen.inst_pll/u[14]} {uut/pll_gen.inst_pll/u[15]} {uut/pll_gen.inst_pll/u[16]} {uut/pll_gen.inst_pll/u[17]} {uut/pll_gen.inst_pll/u[18]} {uut/pll_gen.inst_pll/u[19]} {uut/pll_gen.inst_pll/u[20]} {uut/pll_gen.inst_pll/u[21]} {uut/pll_gen.inst_pll/u[22]} {uut/pll_gen.inst_pll/u[23]} {uut/pll_gen.inst_pll/u[24]} {uut/pll_gen.inst_pll/u[25]} {uut/pll_gen.inst_pll/u[26]} {uut/pll_gen.inst_pll/u[27]} {uut/pll_gen.inst_pll/u[28]} {uut/pll_gen.inst_pll/u[29]} {uut/pll_gen.inst_pll/u[30]} {uut/pll_gen.inst_pll/u[31]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe7]
set_property port_width 32 [get_debug_ports u_ila_0/probe7]
connect_debug_port u_ila_0/probe7 [get_nets [list {uut/pll_gen.inst_pll/phase_err[0]} {uut/pll_gen.inst_pll/phase_err[1]} {uut/pll_gen.inst_pll/phase_err[2]} {uut/pll_gen.inst_pll/phase_err[3]} {uut/pll_gen.inst_pll/phase_err[4]} {uut/pll_gen.inst_pll/phase_err[5]} {uut/pll_gen.inst_pll/phase_err[6]} {uut/pll_gen.inst_pll/phase_err[7]} {uut/pll_gen.inst_pll/phase_err[8]} {uut/pll_gen.inst_pll/phase_err[9]} {uut/pll_gen.inst_pll/phase_err[10]} {uut/pll_gen.inst_pll/phase_err[11]} {uut/pll_gen.inst_pll/phase_err[12]} {uut/pll_gen.inst_pll/phase_err[13]} {uut/pll_gen.inst_pll/phase_err[14]} {uut/pll_gen.inst_pll/phase_err[15]} {uut/pll_gen.inst_pll/phase_err[16]} {uut/pll_gen.inst_pll/phase_err[17]} {uut/pll_gen.inst_pll/phase_err[18]} {uut/pll_gen.inst_pll/phase_err[19]} {uut/pll_gen.inst_pll/phase_err[20]} {uut/pll_gen.inst_pll/phase_err[21]} {uut/pll_gen.inst_pll/phase_err[22]} {uut/pll_gen.inst_pll/phase_err[23]} {uut/pll_gen.inst_pll/phase_err[24]} {uut/pll_gen.inst_pll/phase_err[25]} {uut/pll_gen.inst_pll/phase_err[26]} {uut/pll_gen.inst_pll/phase_err[27]} {uut/pll_gen.inst_pll/phase_err[28]} {uut/pll_gen.inst_pll/phase_err[29]} {uut/pll_gen.inst_pll/phase_err[30]} {uut/pll_gen.inst_pll/phase_err[31]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe8]
set_property port_width 16 [get_debug_ports u_ila_0/probe8]
connect_debug_port u_ila_0/probe8 [get_nets [list {uut/pll_gen.inst_pll/nco_cos[0]} {uut/pll_gen.inst_pll/nco_cos[1]} {uut/pll_gen.inst_pll/nco_cos[2]} {uut/pll_gen.inst_pll/nco_cos[3]} {uut/pll_gen.inst_pll/nco_cos[4]} {uut/pll_gen.inst_pll/nco_cos[5]} {uut/pll_gen.inst_pll/nco_cos[6]} {uut/pll_gen.inst_pll/nco_cos[7]} {uut/pll_gen.inst_pll/nco_cos[8]} {uut/pll_gen.inst_pll/nco_cos[9]} {uut/pll_gen.inst_pll/nco_cos[10]} {uut/pll_gen.inst_pll/nco_cos[11]} {uut/pll_gen.inst_pll/nco_cos[12]} {uut/pll_gen.inst_pll/nco_cos[13]} {uut/pll_gen.inst_pll/nco_cos[14]} {uut/pll_gen.inst_pll/nco_cos[15]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe9]
set_property port_width 1 [get_debug_ports u_ila_0/probe9]
connect_debug_port u_ila_0/probe9 [get_nets [list uut/bits_valid]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe10]
set_property port_width 1 [get_debug_ports u_ila_0/probe10]
connect_debug_port u_ila_0/probe10 [get_nets [list uut/ddc_valid]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe11]
set_property port_width 1 [get_debug_ports u_ila_0/probe11]
connect_debug_port u_ila_0/probe11 [get_nets [list dsp_rst]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe12]
set_property port_width 1 [get_debug_ports u_ila_0/probe12]
connect_debug_port u_ila_0/probe12 [get_nets [list dsp_rx_tlast]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe13]
set_property port_width 1 [get_debug_ports u_ila_0/probe13]
connect_debug_port u_ila_0/probe13 [get_nets [list dsp_rx_tready]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe14]
set_property port_width 1 [get_debug_ports u_ila_0/probe14]
connect_debug_port u_ila_0/probe14 [get_nets [list dsp_rx_tvalid]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe15]
set_property port_width 1 [get_debug_ports u_ila_0/probe15]
connect_debug_port u_ila_0/probe15 [get_nets [list dsp_valid]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe16]
set_property port_width 1 [get_debug_ports u_ila_0/probe16]
connect_debug_port u_ila_0/probe16 [get_nets [list uut/fb_done]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe17]
set_property port_width 1 [get_debug_ports u_ila_0/probe17]
connect_debug_port u_ila_0/probe17 [get_nets [list uut/fb_ok]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe18]
set_property port_width 1 [get_debug_ports u_ila_0/probe18]
connect_debug_port u_ila_0/probe18 [get_nets [list uut/fb_start]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe19]
set_property port_width 1 [get_debug_ports u_ila_0/probe19]
connect_debug_port u_ila_0/probe19 [get_nets [list fclk1_resetn]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe20]
set_property port_width 1 [get_debug_ports u_ila_0/probe20]
connect_debug_port u_ila_0/probe20 [get_nets [list uut/filtered_valid]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe21]
set_property port_width 1 [get_debug_ports u_ila_0/probe21]
connect_debug_port u_ila_0/probe21 [get_nets [list uut/gard_valid]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe22]
set_property port_width 1 [get_debug_ports u_ila_0/probe22]
connect_debug_port u_ila_0/probe22 [get_nets [list uut/pll_valid]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe23]
set_property port_width 1 [get_debug_ports u_ila_0/probe23]
connect_debug_port u_ila_0/probe23 [get_nets [list uut/sym_valid]]
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets dsp_clk]
