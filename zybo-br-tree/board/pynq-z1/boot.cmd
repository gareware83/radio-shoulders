echo Booting persistent ext4 root (PYNQ-Z1)...
setenv ethaddr 02:00:00:00:00:02
#
# clk_ignore_unused is NOT optional on this design.
#
# FCLK0 clocks the whole PL. It is enabled by ps7_init/U-Boot at boot, but no
# Linux driver claims it: uio_pdrv_genirq parses no 'clocks' property and
# enables nothing, and moving axi_dma_0 from xlnx,axi-dma-1.00.a to generic-uio
# removed the last driver that did. The common clock framework then runs
# clk_disable_unused() at late boot and gates it off.
#
# The PL is left configured but unclocked, so its AXI slave can never respond.
# A Zynq-7000 AXI master has no transaction timeout, so the first register read
# hard-locks the CPU: no oops, no console, no clue. fpga_manager still reports
# "operating", because configuration and clocking are independent.
#
# Confirmed via /sys/kernel/debug/clk/clk_summary, where fclk0 showed
# enable_cnt 0, prepare_cnt 0 and 'N' in the enabled column, at the correct
# 50 MHz rate.
#
# This is the blunt fix - it disables the safety net for EVERY clock in the
# system. The precise fix is to give FCLK0 a consumer whose driver actually
# enables it.
setenv bootargs 'root=/dev/mmcblk0p2 rw rootwait uio_pdrv_genirq.of_id=generic-uio clk_ignore_unused'
load mmc 0 ${load_addr} ${fit_image}
bootm ${load_addr}#conf-pynq-z1-rootfs
