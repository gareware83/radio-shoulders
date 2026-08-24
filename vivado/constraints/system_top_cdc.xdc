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
set_clock_groups -asynchronous \
    -group [get_clocks -of_objects [get_nets clk]] \
    -group [get_clocks -of_objects [get_nets dsp_clk]]
