echo Booting persistent ext4 root (PYNQ-Z1)...
setenv ethaddr 02:00:00:00:00:02
setenv bootargs 'root=/dev/mmcblk0p2 rw rootwait'
load mmc 0 ${load_addr} ${fit_image}
bootm ${load_addr}#conf-pynq-z1-rootfs
