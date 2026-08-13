echo Booting persistent ext4 root (Zybo Z7)...
setenv ethaddr 02:00:00:00:00:01
setenv bootargs 'root=/dev/mmcblk0p2 rw rootwait uio_pdrv_genirq.of_id=generic-uio'
load mmc 0 ${load_addr} ${fit_image}
bootm ${load_addr}#conf-zynq-zybo-z7-rootfs
