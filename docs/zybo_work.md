# Zybo Z7 Bring-Up Notes

## Goal

DSP-hosted radio comm system exercise: implement a radio in DSP hosted on each board's FPGA fabric, with the two boards (Zybo Z7 + PYNQ-Z1) communicating over Ethernet. Everything below — Linux bring-up, persistent storage, SSH, static IPs — is groundwork for that.

> **Architecture and interfaces live in [system_design.md](system_design.md)** — RX chain block diagram, register map, DMA packet format, and the userspace API. This file is the build procedure, boot flow, and the running log of problems and fixes.

## Hardware

- **Board:** Digilent Zybo Z7-10 or Z7-20 (XC7Z010/020-CLG400)
- **Rack:** DeskPi RackMate T0 (10" 4U) alongside PYNQ-Z1 — see `zybo_pynq_rack_bom.xlsx`

---

## JTAG / XSCT Scan Chain

Running `targets` in XSCT shows four entries:

```
1  APU                   — parent container; use for system reset (rst -system)
   2  ARM Cortex-A9 #0  — load ELF files here (dow, con)
   3  ARM Cortex-A9 #1  — secondary core, leave halted
4  xc7z010/020          — JTAG TAP; FPGA bitstream only (fpga -f)
```

### Loading U-Boot via XSCT

`boot.bin` is a Xilinx composite image — not ELF, cannot use `dow` directly. Load components separately:

```tcl
connect
targets 2                  ;# ARM Cortex-A9 #0
rst -system
source ps7_init.tcl        ;# from Vivado exported HW — initializes DDR, clocks, MIO
ps7_init
ps7_post_config
dow fsbl.elf
con
after 5000                 ;# wait for FSBL to complete
stop
dow u-boot.elf
con
```

`ps7_init.tcl` must come from a Vivado project targeting the Zybo specifically — it is not portable across boards.

### U-Boot Console

U-Boot outputs to UART, not JTAG. Connect a serial terminal in parallel:

```bash
minicom -D /dev/ttyUSB0 -b 115200
# or
screen /dev/ttyUSB0 115200
```

Open the terminal **before** running `con` in XSCT to catch early boot output.

---

## ZedBoard Boot Artifacts — Not Compatible with Zybo

| Layer | ZedBoard | Zybo | Problem |
|-------|----------|------|---------|
| SoC package | CLG484 | CLG400 | Different pinout |
| DDR init (ps7_init) | Board-specific | Different DDR chip | DDR won't train; hangs at FSBL |
| DDR size | 512MB | 512MB (Z7-10) / 1GB (Z7-20) | Wrong memory map |
| UART MIO pins | MIO48/49 | MIO14/15 | No console output |
| Ethernet PHY | Marvell 88E1518 | Realtek RTL8211E | Wrong PHY driver |

ZedBoard `boot.bin` will hang or produce no output on Zybo.

---

## Software Sources

### U-Boot
- **Digilent fork (start here):** https://github.com/Digilent/u-boot-digilent
  - u-boot-xlnx base with Digilent board additions, correct MIO/DDR/PHY config for Zybo

### PetaLinux BSPs (full bootable image, quickest path)
- Z7-10: https://github.com/Digilent/Petalinux-Zybo-Z7-10
- Z7-20: https://github.com/Digilent/Petalinux-Zybo-Z7-20

### Buildroot
- **Starting point:** [jbootsma/zybo-br-tree](https://github.com/jbootsma/zybo-br-tree)
  - Buildroot external tree targeting Zybo Z7-20 specifically
- Mainline buildroot has `zynq_zybo_defconfig` but targets the original Zybo (not Z7); no `zynq_zybo_z7_defconfig` in mainline
- Community alternatives: [pacalet/sab4z](https://github.com/pacalet/sab4z) (BR2_EXTERNAL pattern, includes custom PL), [florolf/zynq-buildroot](https://github.com/florolf/zynq-buildroot) (older, 2016.02 era)

### Board Files
- https://github.com/Digilent/Zybo-Z7 — constraints, demos
- https://github.com/Digilent/Zybo-Z7-OS — OS-level demos

### Zybo Boot Work

make -C ../buildroot/ O=`pwd`/output BR2_EXTERNAL=`pwd` zybo_z720_defconfig
make -C ../buildroot/ O=`pwd`/output BR2_EXTERNAL=`pwd`

Successful build produces (`output/images/`):
- `boot.bin` — FSBL + SPL, first stage
- `u-boot.img` — second stage bootloader
- `fit.itb` — FIT image bundling `zImage` (load/entry `0x8000`), `rootfs.cpio.gz` ramdisk, and `zynq-zybo-z7.dtb`

### First Boot — SD Card

1. Format an SD card FAT32.
2. Copy the three build outputs to the SD card root:
   ```
   cp output/images/{boot.bin,u-boot.img,fit.itb} <sd-card-mount>/
   ```
3. Set the Zybo boot-mode jumper (**JP5** per general Zybo Z7 documentation — double-check against the board reference manual/silkscreen, not verified from anything in this repo) to **SD**, insert the card.
4. Open a UART console **before** powering on, so early boot output isn't missed:
   ```
   minicom -D /dev/ttyUSB0 -b 115200
   ```
5. Power on. `fit.itb` does auto-load, just via a longer path than the README implies — see **Boot Script (boot.scr)** below for why, and for an optional faster/more deterministic path.
6. Login: `root`, no password. Note the rootfs is a ramdisk — changes don't persist across reboots.

### Boot Script (boot.scr) — Speeds Up SD Autoboot (Not Required)

U-boot's actual default `bootcmd` is `run distro_bootcmd`, which walks `boot_targets` (`mmc0 qspi usb0 pxe dhcp xilinx`) looking for `boot.scr.uimg`/`boot.scr` or `extlinux/extlinux.conf` on each — it does **not** look for `fit.itb` by name, so it finds nothing on `mmc0`, `qspi`, or `usb0` and falls through. It does still get there, though: `xilinx` is an unconditional catch-all target appended to the end of the list, and its command is `run $modeboot`. `board.c` sets `modeboot=sdboot` when the board is strapped for SD boot, and `sdboot` (`load mmc 0 ${load_addr} ${fit_image} && bootm ${load_addr}`) is a real, working command — so `fit.itb` does end up loading and booting automatically. The catch is the `pxe`/`dhcp` targets in between have to time out first (no server needed, but still real wall-clock delay, especially with no Ethernet cable connected).

Adding a `boot.scr` short-circuits this: `mmc0` is scanned first and immediately finds/runs it, skipping `qspi`/`usb0`/`pxe`/`dhcp` entirely.

1. Write a plain-text u-boot script, `boot.cmd`:
   ```
   echo Copying FIT from SD to RAM...
   load mmc 0 ${load_addr} ${fit_image}
   bootm ${load_addr}
   ```
2. Compile it with `mkimage` (built by Buildroot as `host-uboot-tools`, at `output/host/bin/mkimage`):
   ```
   output/host/bin/mkimage -A arm -T script -C none -n "Zybo SD boot" -d boot.cmd boot.scr
   ```
3. Copy `boot.scr` to the SD card root alongside `boot.bin`/`u-boot.img`/`fit.itb`.
4. Power on — `distro_bootcmd` finds `boot.scr` on `mmc0` immediately (`boot_scripts="boot.scr.uimg boot.scr"`) and sources it, without waiting on the rest of the fallback chain.

Note this is genuinely different for **QSPI** boot mode (below): there, `modeboot=qspiboot`, but no `qspiboot` env command is defined anywhere in this u-boot tree — that fallback is broken, not just slow. A boot script at the reserved QSPI script offset is required there, not just an optimization.

### Boot Script — Auto-Boot to Persistent ext4 Root (both boards)

Same mechanism as above, but selecting the `-rootfs` FIT config instead of the default `-ramdisk` one, so the board comes up on `/dev/mmcblk0p2` automatically instead of the ramdisk — no more manual `bootm ...#conf-...-rootfs` at the prompt every boot, and changes made over SSH now survive a reboot.

`board/common/boot.cmd` (Zybo):
```
echo Booting persistent ext4 root (Zybo Z7)...
setenv ethaddr 02:00:00:00:00:01
setenv bootargs 'root=/dev/mmcblk0p2 rw rootwait'
load mmc 0 ${load_addr} ${fit_image}
bootm ${load_addr}#conf-zynq-zybo-z7-rootfs
```
`board/pynq-z1/boot.cmd` (PYNQ-Z1), same shape, different config name and MAC:
```
echo Booting persistent ext4 root (PYNQ-Z1)...
setenv ethaddr 02:00:00:00:00:02
setenv bootargs 'root=/dev/mmcblk0p2 rw rootwait'
load mmc 0 ${load_addr} ${fit_image}
bootm ${load_addr}#conf-pynq-z1-rootfs
```
No `saveenv` needed for either variable — the script sets both fresh every boot, so nothing needs to persist in the env sector.

**`ethaddr` line added later**, after tracking down a real intermittent-connectivity bug: both boards' U-Boot defconfigs have `CONFIG_NET_RANDOM_ETHADDR=y` with no fixed `local-mac-address` anywhere in either devicetree, so `eth0` gets a *brand-new random MAC every single boot*. Static IPs stayed the same across a reboot, but the MAC behind them didn't — so the host's ARP cache / switch's MAC table kept stale entries pointing at the old, no-longer-valid MAC until they aged out, producing exactly the "works, then `No route to host`, then works again" pattern that turned into a whole debugging detour (double-mount, PHY compatible-string, client isolation — all ruled out as red herrings before landing on this). A cable replug/power-cycle "fixing" it temporarily was actually consistent with this theory rather than contradicting it — link-up typically fires a gratuitous ARP, which forces an early cache refresh instead of waiting for the natural timeout.

Confirmed via `common/image-fdt.c:546` that `fdt_fixup_ethernet()` runs from the same `image_setup_libfdt()` call already verified for `bootargs`/`fdt_chosen()` — so `setenv ethaddr` right before `bootm` reliably lands in the devicetree's `local-mac-address` property Linux actually uses, regardless of whatever U-Boot's own NIC state did internally. Picked arbitrary locally-administered addresses (`02:...`, first octet `02` marks locally-administered/no vendor-registration needed), just needs to stay distinct between the two boards. Config names confirmed directly from each board's rebuilt `fit.its` (`conf-zynq-zybo-z7-ramdisk`/`-rootfs`, `conf-pynq-z1-ramdisk`/`-rootfs`) rather than assumed, since `mkfit.py`'s naming is derived from the dtb filename.

Considered but not pursued (yet): exposing U-Boot's env to Linux via `fw_setenv`/`fw_printenv` (`BR2_PACKAGE_UBOOT_TOOLS`, `FWPRINTENV` suboption, default `y`) to manage this over SSH without needing serial or a rebuild at all. Checked what that would actually require: `CONFIG_SPI_ZYNQ_QSPI` is **not set** in either kernel build, and neither board's dts enables/describes the `qspi` node's flash child with a proper `compatible`/partition layout — so the QSPI flash isn't exposed as a Linux MTD device at all right now. Real feature, but a kernel+devicetree project of its own, not a quick add.

Compiled with each board's own `mkimage` (they can differ between per-board Buildroot toolchains, so use the matching one) and dropped straight into `images/` next to `fit.itb`:
```
./output-zybo/host/bin/mkimage -A arm -T script -C none -n "Zybo persistent-root boot" -d board/common/boot.cmd output-zybo/images/boot.scr
./output-pynq/host/bin/mkimage -A arm -T script -C none -n "PYNQ-Z1 persistent-root boot" -d board/pynq-z1/boot.cmd output-pynq/images/boot.scr
```
Copy each `boot.scr` onto its board's SD card root alongside the existing `boot.bin`/`u-boot.img`/`fit.itb` to make it take effect. Not yet wired into `build_all.sh`/the Buildroot post-image step — currently a manual compile step after each build, since `boot.cmd` doesn't change often. Could be automated later if it becomes annoying.

### Switching to TFTP Network Boot

Useful once SD boot works, to skip re-flashing the card on every rebuild.

1. Set up a TFTP server on the dev machine with a static IP, serving `output/images/fit.itb`.
2. Remove/rename `fit.itb` from the SD card root so it stops auto-loading locally (forces fallback to the next `boot_targets` entry).
3. Connect the Zybo to the same LAN via Ethernet, boot it, and interrupt autoboot at the u-boot prompt.
4. Point u-boot at the TFTP server and set the board's own IP:
   ```
   editenv host_ip
   edit: <tftp server addr>
   editenv ipaddr
   edit: <zybo addr>
   ```
5. Define the tftp boot command (u-boot's default env already sets `load_addr=0x2000000` and `fit_image=fit.itb`, see below):
   ```
   editenv bootcmd_tftp
   edit: tftpboot $load_addr $host_ip:$fit_image && bootm $load_addr
   ```
6. Add `tftp` to the boot target search order:
   ```
   editenv boot_targets
   edit: tftp mmc0 usb0 pxe dhcp
   ```
7. Persist to flash and reset to test:
   ```
   saveenv
   reset
   ```
8. From then on, rebuild → board reset picks up the new `fit.itb` over the network, no SD card swap needed.

### QSPI Boot

QSPI flash on the Zybo Z7 is 16MB (`CONFIG_SYS_FLASH_SIZE` = `0x1000000`) — too small to hold the current `fit.itb` (~25MB: ~12MB kernel + ~13MB ramdisk + dtb). QSPI here is only practical as a **persistent bootloader stage** that chainloads the real FIT from SD or TFTP, not as storage for the full boot image. Flash layout, from `zynq_zybo_z7_defconfig`'s u-boot `.config` and `zynq-common.h`:

| Offset | Size | Contents |
|---|---|---|
| `0x000000` | ~75KB (actual built size; must stay under `0xE0000`) | `boot.bin` (FSBL + SPL) |
| `0xE0000` | `0x20000` (128KB) | u-boot's own saved environment (`CONFIG_ENV_OFFSET`/`_SIZE` — this is the hard boundary `boot.bin` must not cross, not a size reserved for it) |
| `0x100000` | ~560KB | `u-boot.img` (`CONFIG_SYS_SPI_U_BOOT_OFFS`) |
| `0x100000`–`0xFC0000` | ~14MB free | available for a boot script or a much smaller payload |
| `0xFC0000` | `0x40000` (256KB) | reserved boot-script region for the built-in `qspi` boot target (`script_offset_f`/`script_size_f`) |

Steps (boot the board once from SD/TFTP first, then run these at the `Zynq>` prompt to program the flash):

1. Write `boot.bin` and `u-boot.img` to their fixed offsets:
   ```
   sf probe 0 0 0
   load mmc 0 ${load_addr} boot.bin
   sf update ${load_addr} 0x0 ${filesize}
   load mmc 0 ${load_addr} u-boot.img
   sf update ${load_addr} 0x100000 ${filesize}
   ```
2. Build a `boot.scr` the same way as the SD version above, but chainloading the FIT from SD or network since it doesn't fit in QSPI itself:
   ```
   echo Booting from QSPI: chainloading FIT from SD...
   load mmc 0 ${load_addr} ${fit_image}
   bootm ${load_addr}
   ```
   (swap in the `tftpboot` version from the TFTP section above for a fully network-fed boot)
3. Flash it to the reserved script region:
   ```
   load mmc 0 ${load_addr} boot.scr
   sf update ${load_addr} 0xFC0000 ${filesize}
   ```
4. Set the Zybo boot-mode jumper (JP5) to **QSPI**, power on. `qspi` is already in the default `boot_targets` list (`bootcmd_qspi` runs `sf probe; sf read $scriptaddr $script_offset_f $script_size_f; source $scriptaddr`), so it's picked up automatically — no env changes needed.

Note: with the jumper on QSPI, an SD card is still needed for step 2's `load mmc` to reach the FIT at runtime — only `boot.bin`/`u-boot.img`/the boot script actually live in flash. Point the script at `tftpboot` instead for a fully cardless boot.

### uEnv.txt on QSPI

This u-boot's built-in `uEnv.txt` support (`loadbootenv`/`importbootenv`, `bootenv=uEnv.txt`) only knows about `mmc`/`usb` (`sd_loadbootenv`, `usb_loadbootenv`) — there's no ready-made `qspi_loadbootenv`. QSPI's real equivalent is u-boot's own environment: since `CONFIG_ENV_IS_IN_SPI_FLASH=y` is already set, anything you `setenv`+`saveenv` is written straight to the QSPI env sector (`0xE0000`, 128KB) — persisted the same way a `uEnv.txt` would be, no text file involved:
```
setenv uenvcmd 'run sdboot'
saveenv
```
This is the recommended path — it reuses the exact hook `preboot` already checks for (`if test -n $uenvcmd; then run uenvcmd; fi`).

If you specifically need a literal `uEnv.txt` file living in QSPI (e.g. to keep it human-editable the same way an SD-card one would be), there's no built-in loader for that on QSPI — you'd stage it via SD/TFTP into RAM first, then write it to a free flash offset yourself:
```
load mmc 0 ${loadbootenv_addr} uEnv.txt
sf probe 0 0 0
sf update ${loadbootenv_addr} <chosen offset> ${filesize}
```
...and add a matching `sf read` + `env import -t` step to whatever boot script loads it, since u-boot won't do that automatically for QSPI the way it does for `mmc`/`usb`. Given the native env-in-QSPI already covers the same use case, this manual route is only worth it if the plain-text file itself matters.

### Persistent Root Filesystem (ext4)

**Does the Zybo have eMMC or other persistent storage?** No — the Zybo Z7 (Z7-10 and Z7-20) has a microSD slot and the 16MB QSPI flash covered above, no onboard eMMC. QSPI is both too small and largely spoken for by the bootloader/env/script regions, so the microSD card is the only practical persistent storage for a real root filesystem.

Buildroot config to build an ext4 image instead of (or alongside) the ramdisk — add to `zybo_z720_defconfig`:
```
BR2_TARGET_ROOTFS_EXT2=y
BR2_TARGET_ROOTFS_EXT2_4=y
BR2_TARGET_ROOTFS_EXT2_SIZE="256M"
```
Produces `output/images/rootfs.ext4`.

To actually boot from it:
1. Partition the SD card with two partitions: a small FAT32 one (`boot.bin`/`u-boot.img`/`fit.itb`/`boot.scr`) and a second ext4 partition sized to fit `rootfs.ext4` (or larger — `resize2fs` can grow it to fill the partition on first boot).
2. Write the image to the second partition: `dd if=output/images/rootfs.ext4 of=/dev/sdX2 bs=1M`
3. **`mkfit.py` change, applied:** it used to bundle the ramdisk into `fit.itb` unconditionally (`Ramdisk()` was passed to every `Configuration`), which mattered because Buildroot's default init runs directly from an unpacked ramdisk as PID 1 without pivoting to `root=` — so `bootargs.root=` alone wouldn't have switched you onto the ext4 partition. Fixed: `make_img()` now emits **two** FIT configs per dtb — `conf-<board>-ramdisk` (unchanged behavior, stays the default so existing bare `bootm ${load_addr}` calls, e.g. `sdboot`, are unaffected) and `conf-<board>-rootfs` (no ramdisk image at all).
4. Select the persistent-root config explicitly and point bootargs at the real partition — this gets fixed up into the FIT's loaded device tree automatically at boot (the DTS `chosen/bootargs` is empty by default, so no DTS edit needed):
   ```
   setenv bootargs 'root=/dev/mmcblk0p2 rw rootwait'
   saveenv
   bootm ${load_addr}#conf-zynq-zybo-z7-rootfs
   ```
   (or bake that `bootm` line into a dedicated `boot.scr` if you want it to be the normal boot path rather than a manual one-off — see the Boot Script section above for how)

### Deriving Boot-Product Load Addresses from the Device Tree

The DRAM window available for staging/loading images comes from the `memory` node in the board DTS (`arch/arm/boot/dts/xilinx/zynq-zybo-z7.dts`):
```
memory@0 {
	device_type = "memory";
	reg = <0x0 0x40000000>;   // base 0x00000000, size 1GB (Z7-20)
};
```
No `reserved-memory`/`no-map` regions are declared in this DTS, so the full `0x00000000`–`0x3FFFFFFF` range is fair game — any load address just needs to (a) fall inside that window and (b) not collide with another image once everything is unpacked.

How each address in the boot chain is actually chosen:
- **Kernel** `load`/`entry` = `0x8000` — hardcoded in `zybo-br-tree/board/common/mkfit.py` (`Kernel.loadaddr`). This is the standard ARM Linux `TEXT_OFFSET` (32KB into RAM), leaving room below for the vector table/boot params.
- **Ramdisk** and **fdt** — left unset in `mkfit.py`/`fit.its`; u-boot's FIT loader (`bootm`) places them itself above the kernel at runtime, still safely inside the 1GB window.
- **TFTP/SD staging address** (`$load_addr`, where the whole `fit.itb` blob lands before `bootm` unpacks it) = `0x2000000` (32MB) — set in u-boot's default env (`include/configs/zynq-common.h`). It's chosen well above the kernel's own final `0x8000` load point so the full ~26MB `fit.itb` can be downloaded without the tail of the download overwriting anything `bootm` has already relocated, and comfortably below the 1GB ceiling.

To sanity-check on a different board/DDR size: re-grep the `memory@0` node for that board's `.dts`, confirm `reg`'s size covers `$load_addr` + `fit.itb`'s file size with headroom, and confirm no `reserved-memory` node overlaps `0x2000000`.

### SSH + Static IP (both boards)

Dropbear (`BR2_PACKAGE_DROPBEAR=y`) + a fixed root password (`BR2_TARGET_GENERIC_ROOT_PASSWD="root"`) get SSH working; without a fixed IP you still need serial to find whatever address DHCP handed out, defeating the point. Fixed via a rootfs overlay replacing `/etc/network/interfaces` outright — Zybo: `zybo-br-tree/board/common/overlay/etc/network/interfaces`, PYNQ-Z1: `zybo-br-tree/board/pynq-z1/overlay/etc/network/interfaces` (separate overlay dirs, since the two boards were never sharing one):
```
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
	address 10.0.0.200
	netmask 255.255.255.0
	gateway 10.0.0.1
```
(PYNQ-Z1's is identical except `10.0.0.201` — same `/24` as the host, distinct from Zybo's `.200` and each board's original DHCP lease.) Wired up per-board:
```
BR2_ROOTFS_OVERLAY="$(BR2_EXTERNAL_ZYBO_Z7_PATH)/board/common/overlay"        # zybo_z720_defconfig
BR2_ROOTFS_OVERLAY="$(BR2_EXTERNAL_ZYBO_Z7_PATH)/board/pynq-z1/overlay"       # pynq_z1_defconfig
```
This replaced `BR2_SYSTEM_DHCP="eth0"` on both defconfigs rather than coexisting with it — `BR2_SYSTEM_DHCP` only *appends* a dhcp stanza onto `/etc/network/interfaces` at build time, and the overlay copy (which happens later, at rootfs finalize) would just overwrite the whole file anyway, so there was no reason to keep both. Confirmed working on real hardware — both boards SSH-reachable and able to ping each other (after ruling out an AP/client-isolation red herring on the router).

### Auto-Mounting the SD Partitions

Manually `mount`-ing `/dev/mmcblk0p1`/`/dev/mmcblk0p2` after every ramdisk boot to push updated images over SSH got old fast. `/bin/mount -a` already runs automatically at boot (confirmed in `/etc/inittab`'s `sysinit` sequence, standard BusyBox-init behavior) — it just had nothing beyond the stock skeleton entries to act on. Added two lines to `/etc/fstab` via the same per-board overlays (full file needed, not just the diff — overlay copies replace the file wholesale, not merge it):
```
/dev/mmcblk0p1	/mnt/boot	vfat	defaults	0	0
/dev/mmcblk0p2	/mnt/data	ext4	defaults	0	0
```
Mount-point directories (`mnt/boot`, `mnt/data`) added to both overlays too — confirmed overlays are applied via `rsync -a` (`Makefile:816`), which preserves empty directories, so this works without needing a placeholder file. (Git itself still won't track those empty dirs if you `git add` this — filesystem-level thing, not a git thing — not a problem for the build either way, just don't expect `git status` to show them individually.)

**Update:** the `/dev/mmcblk0p2` double-mount described above (already root via `root=` in the persistent config, then mounted a second time at `/mnt/data` via fstab) was flagged during a PYNQ static-IP debugging session as a "just in case" cleanup, even though a Zybo control test confirmed it wasn't actually the cause there (Zybo has the identical fstab pattern and boots persistent-root fine) — ruling it out as *the* bug, but it was still worth tidying up rather than leaving an unnecessary double-mount in place. Replaced the static `/dev/mmcblk0p2` fstab line with a conditional init script, `etc/init.d/S41mountdata` (added to both overlays), that only mounts it at `/mnt/data` if it isn't already mounted somewhere (i.e. isn't already live root):
```sh
start() {
	if ! grep -q '^/dev/mmcblk0p2 ' /proc/mounts; then
		mount /dev/mmcblk0p2 /mnt/data
	fi
}
```
`/dev/mmcblk0p1` (FAT32 boot) stays as a plain static `fstab` entry — it's never the root device, so no double-mount is possible there. Confirmed `/etc/init.d/rcS` runs everything matching `/etc/init.d/S??*` in numeric order via `"$i" start"`, same mechanism as the existing `S40network`, so `S41mountdata` slots in right after it with no other wiring needed.

### Re-syncing the Persistent ext4 Partition After a Rebuild

Bites anyone running this setup: `rootfs.ext4` was `dd`'d onto `/dev/mmcblk0p2` as a one-time step. Rebuilding regenerates `output-<board>/images/rootfs.ext4` on disk, but nothing re-flashes it onto the card automatically — the partition stays frozen at whatever it was on the last `dd`, silently drifting out of sync with the overlay/config changes actually going into new builds (this is exactly what happened with the static-IP overlay — the ramdisk had it, the already-`dd`'d ext4 partition didn't).

Safe update procedure, since you can't `dd` a mounted-as-root partition out from under the running system:

1. Reboot into the **ramdisk** config (the default — plain `bootm ${load_addr}` at the `Zynq>` prompt, or just let autoboot run without a persistent-root `boot.scr` in place), so `/dev/mmcblk0p2` is unmounted rather than being live root.
2. Pull the SD card (or otherwise get host access to the raw device) and re-write it:
   ```
   dd if=output-zybo/images/rootfs.ext4 of=/dev/sdX2 bs=1M
   ```
   (`output-pynq/images/rootfs.ext4` for PYNQ-Z1.) This is a full overwrite — anything written directly to that partition since the last `dd` (outside of what's tracked in the Buildroot config/overlay) is lost.
3. Reinsert, boot back into the persistent-root config to confirm.

No automation for this yet — still a manual pull-the-card step after every rebuild that's meant to reach the persistent partition, unlike `fit.itb`/`boot.scr` which just need a file copy onto the still-writable-from-the-running-ramdisk FAT32 partition.

### Zybo troubleshooting notes

**"does not have an 'external.desc'"**
`BR2_EXTERNAL` was pointed at `zybo_NEW` itself instead of a real br2-external tree. Clone [jbootsma/zybo-br-tree](https://github.com/jbootsma/zybo-br-tree) alongside `buildroot/` and point `BR2_EXTERNAL` at that instead:
```
git clone https://github.com/jbootsma/zybo-br-tree.git
cd zybo-br-tree
make -C ../buildroot/ O=`pwd`/output BR2_EXTERNAL=`pwd` zybo_z720_defconfig
```

**"cc1: fatal error: ./arch/../configs/zynq_zybo_z7_defconfig: No such file or directory"**
`zybo_z720_defconfig` sets `BR2_TARGET_UBOOT_BOARD_DEFCONFIG="zynq_zybo_z7"` but never pins a U-Boot version, so it falls through to Buildroot's floating "latest" (2026.07 at time of writing). The `zybo-br-tree` repo hasn't been updated since 2019-10-19, back when mainline U-Boot still shipped `zynq_zybo_z7_defconfig`; upstream has since dropped board-specific Zynq-7000 defconfigs in favor of `xilinx_zynq_virt_defconfig` + device tree. Fix by pinning an older U-Boot version in `zybo-br-tree/configs/zybo_z720_defconfig`:
```
BR2_TARGET_UBOOT_CUSTOM_VERSION=y
BR2_TARGET_UBOOT_CUSTOM_VERSION_VALUE="2019.10"
```

**"No U-Boot board name set. Check your BR2_TARGET_UBOOT_BOARDNAME setting"**
Side effect of the fix above. Buildroot's U-Boot "Build system" choice only defaults to Kconfig-based (`BR2_TARGET_UBOOT_BUILD_SYSTEM_KCONFIG`) when `BR2_TARGET_UBOOT_LATEST_VERSION` is set — pinning a custom version drops it back to `BUILD_SYSTEM_LEGACY`, which expects `BOARDNAME` instead of `BOARD_DEFCONFIG`. Add explicitly alongside the version pin:
```
BR2_TARGET_UBOOT_BUILD_SYSTEM_KCONFIG=y
```
Full addition to `zybo_z720_defconfig`:
```
BR2_TARGET_UBOOT=y
BR2_TARGET_UBOOT_BUILD_SYSTEM_KCONFIG=y
BR2_TARGET_UBOOT_CUSTOM_VERSION=y
BR2_TARGET_UBOOT_CUSTOM_VERSION_VALUE="2019.10"
```
Re-run the `zybo_z720_defconfig` make step after editing before rebuilding.

**"No rule to make target 'arch/arm/boot/dts/zynq-zybo-z7.dtb'"**
Kernel pinned via "latest" resolved to 7.1.6; upstream has since moved ARM device trees into per-vendor subdirectories (`arch/arm/boot/dts/xilinx/...`) like arm64 already had. `BR2_LINUX_KERNEL_INTREE_DTS_NAME="zynq-zybo-z7"` needs the vendor prefix:
```
BR2_LINUX_KERNEL_INTREE_DTS_NAME="xilinx/zynq-zybo-z7"
```
`BR2_ROOTFS_POST_SCRIPT_ARGS` stays as the plain basename — Buildroot flattens the installed dtb regardless of source subdirectory.

---

## Multi-Board: Zybo Z7 + PYNQ-Z1 from One External Tree

Goal: `zybo-br-tree` produces working images for both boards. Originally tried as one shared `fit.itb` with two FIT configurations (see git history on this doc's local branch if curious) — abandoned that in favor of two independent defconfigs, each with its own `O=` build output, because:
- Buildroot doesn't support passing multiple defconfigs to one invocation anyway — `make <name>_defconfig` always produces exactly one `.config` → one `O=` output → one image. The standard Buildroot pattern for multi-board support from one external tree is two separate invocations with two separate `O=` dirs, same as how upstream Buildroot itself handles its hundreds of board defconfigs.
- It also sidesteps a real fragility the shared-FIT approach had: `u-boot.img` turned out unable to be shared between boards anyway (below), so there was no benefit left to forcing the kernel/dtb side to share a single image via `#conf-name` boot-time selection.

### What can and can't be shared across the two builds

Researched via web search since no maintained br2-external tree exists for PYNQ-Z1 the way `jbootsma/zybo-br-tree` does for Zybo Z7 (checked: [ikwzm/FPGA-SoC-U-Boot-PYNQ-Z1](https://github.com/ikwzm/FPGA-SoC-U-Boot-PYNQ-Z1), [jpeezzy/pynq-1](https://github.com/jpeezzy/pynq-1), [regymm/PYNQSDR](https://github.com/regymm/PYNQSDR), [astfyi/spearf1sh](https://github.com/astfyi/spearf1sh) — none is a drop-in equivalent).

- **`boot.bin` (FSBL+SPL) — can't share.** Needs its own PYNQ-Z1 Vivado project (DDR calibration, MIO pinmux), same as the existing "`ps7_init.tcl` isn't portable across boards" note above. Still an open prerequisite — building `pynq_z1_defconfig` end-to-end doesn't get you a working `boot.bin` yet.
- **`u-boot.img` — can't share either** (correcting an earlier guess in this doc's chat history that it "likely" could be). `pynq-z1.dts` uses `serial0 = &uart0`, but Zybo Z7's u-boot is built with `CONFIG_DEBUG_UART_BASE=0xe0001000` (UART**1**) — PYNQ-Z1 needs UART**0** (`0xe0000000`) instead, a compile-time constant. Solved without a whole second U-Boot board defconfig, though — see below.
- **Kernel `zImage`, ramdisk, rootfs config — shared** between the two defconfigs (same buildroot toolchain/rootfs/kernel settings, just duplicated across the two files since Buildroot defconfigs can't include one another).
- **Device tree — one file per board**, `pynq-z1.dts` sourced below.

### Sourcing `pynq-z1.dts`

Pulled from [jpeezzy/pynq-1](https://github.com/jpeezzy/pynq-1)'s `nix/pkgs/kernel/0001-ARM-dts-pynq-Add-Digilent-Zynq-PYNQ-Z1-Board.patch` (Florian Klink), landed at `zybo-br-tree/board/pynq-z1/pynq-z1.dts`. One adaptation from upstream: changed `#include "zynq-7000.dtsi"` to `#include "xilinx/zynq-7000.dtsi"` — this kernel's dts reorg moved it under `xilinx/`, and `BR2_LINUX_KERNEL_CUSTOM_DTS_PATH` copies the file into the flat `arch/arm/boot/dts/` root rather than into `xilinx/`, so the unqualified include wouldn't resolve (same class of issue as the Zybo `INTREE_DTS_NAME` vendor-prefix fix above).

Two hardware facts confirmed straight from this DTS, worth knowing:
- **DRAM is 512MB** (`memory@0 { reg = <0x0 0x20000000>; };`) — half the Zybo Z7-20's 1GB. Doesn't break anything in the "Deriving Load Addresses" section above (`$load_addr=0x2000000` is still well within range), but that section's DRAM table was written Zybo-specific and doesn't apply as-is to PYNQ-Z1.
- **Console is UART0**, not UART1 like Zybo Z7 — the fact that ruled out sharing `u-boot.img`.

### Changes made

**`zybo-br-tree/board/common/mkfit.py`** — `make_img()` used to hardcode exactly one `.dtb` (`sys.argv[2]`) into a single FIT config. Generalized to build one `Configuration` per `.dtb` passed on the command line (sorted out from an optional trailing `.bit` fpga arg by extension). With the two-defconfig split, each build only ever passes one dtb, so in practice this now just produces a single-config FIT named after that board's dtb (`conf-zynq-zybo-z7` or `conf-pynq-z1`) — but it's harmless/correct either way, so left as the general form rather than reverted, in case a genuine shared-FIT use case comes up later.

**`zybo-br-tree/board/pynq-z1/pynq-z1.dts`** (new) — see sourcing above.

**`zybo-br-tree/configs/pynq_z1_defconfig`** (new) — copy of `zybo_z720_defconfig`'s structure with: `BR2_TARGET_GENERIC_HOSTNAME="pynq-z1"`, `BR2_ROOTFS_POST_SCRIPT_ARGS="pynq-z1.dtb"`, `BR2_LINUX_KERNEL_CUSTOM_DTS_PATH` pointing at the new dts (no `INTREE_DTS_NAME`, since it's not in mainline). U-Boot side went through two attempts — see below, current state uses `BR2_TARGET_UBOOT_BOARD_DEFCONFIG="zynq_pynq_z1"` directly.

**`zybo-br-tree/configs/zybo_z720_defconfig`** — reverted the multi-dtb `BR2_ROOTFS_POST_SCRIPT_ARGS`/`BR2_LINUX_KERNEL_CUSTOM_DTS_PATH` additions from the abandoned shared-FIT attempt; otherwise unchanged from the earlier bugfixes below.

Also fixed three unrelated errors found in `zybo_z720_defconfig` while first touching it for this work (none were valid Buildroot options, so they were silently no-ops) — carried over as-is into `pynq_z1_defconfig` too since it was copied afterward:
- `BR2_SYSTEM_DHCP2="eth0"` → `BR2_SYSTEM_DHCP="eth0"` (real bug — DHCP auto-config on `eth0` was **not** actually active; `DHCP2` isn't a real option)
- Removed `BR2_PACKAGE_E2FSPROGS_MKE2FS=y` and `BR2_PACKAGE_E2FSPROGS_E2FSCK=y` — not real suboptions; `mke2fs`/`e2fsck` are unconditionally built by plain `BR2_PACKAGE_E2FSPROGS=y` per its own help text
- Removed `BR2_PACKAGE_E2FSPROGS_DOSFSCK=y` — not a real option; `dosfsck`/`fsck.fat` belongs to `dosfstools`, a different package entirely

### Building both

Two independent invocations, one per board, each with its own `O=` directory so they don't clobber each other:
```
make -C ../buildroot/ O=`pwd`/output-zybo BR2_EXTERNAL=`pwd` zybo_z720_defconfig
make -C ../buildroot/ O=`pwd`/output-zybo BR2_EXTERNAL=`pwd`

make -C ../buildroot/ O=`pwd`/output-pynq BR2_EXTERNAL=`pwd` pynq_z1_defconfig
make -C ../buildroot/ O=`pwd`/output-pynq BR2_EXTERNAL=`pwd`
```
Each produces its own `boot.bin`/`u-boot.img`/`fit.itb` under `output-<board>/images/`. Since each build's FIT only ever contains its own single dtb (per the `mkfit.py` note above), the earlier "boot.scr must select `#conf-name` explicitly" concern from the shared-FIT design doesn't apply here — plain `bootm ${load_addr}` (what `sdboot`/`modeboot` already do) is unambiguous again on both boards. (Each dtb now produces two configs — ramdisk and persistent-root, see the ext4 section above — but the ramdisk one still stays default/first, so this still holds for the normal boot path; `#conf-name` is only needed to explicitly opt into the persistent-root one.)

Both commands are also wrapped in `build_all.sh` (project root, alongside this file) — runs both builds back-to-back into `output-zybo/` and `output-pynq/`, `set -euo pipefail` so it stops on the first failure instead of building the second image on top of a broken first one.

### PYNQ-Z1 `boot.bin` — resolved, no Vivado project needed

Turns out neither board's `boot.bin` (FSBL+SPL) actually came from a Vivado project — checked, and mainline U-Boot itself already bundles `board/xilinx/zynq/zynq-zybo-z7/ps7_init_gpl.c` (the DDR/pinmux init data), which is why the Zybo build never needed one. PYNQ-Z1 has no equivalent bundled in mainline, but the same [jpeezzy/pynq-1](https://github.com/jpeezzy/pynq-1) repo that supplied the kernel dts also has it, packaged as a U-Boot patch — full repo now cloned to `/home/gareth/home_projects/zybo_NEW/pynq-1` (sibling of `buildroot/`/`zybo-br-tree/`, kept for reference/provenance).

How U-Boot picks which `ps7_init_gpl.c` to compile — checked `board/xilinx/zynq/Makefile`: it's keyed directly off `CONFIG_DEFAULT_DEVICE_TREE` (`board/xilinx/zynq/$(CONFIG_DEFAULT_DEVICE_TREE)/ps7_init_gpl.c`).

**First attempt (broke on the actual build) — kept here for the record, don't repeat it:** used `zynq_zybo_z7` as the base U-Boot defconfig plus a hand-rolled `uboot-fragment.config` (`BR2_TARGET_UBOOT_CONFIG_FRAGMENT_FILES`) overriding just `CONFIG_DEBUG_UART_BASE`/`CONFIG_DEFAULT_DEVICE_TREE`, and only applied the `ps7_init_gpl.c`-adding patch. This got the DDR init file in place, but `jpeezzy/pynq-1` actually splits PYNQ-Z1 U-Boot support across **two** patches — the second, `0001-ARM-zynq-add-Digilent-Zynq-PYNQ-Z1.patch`, is what creates `arch/arm/dts/zynq-pynq-z1.dts` (U-Boot's own devicetree copy, separate from the kernel's) and registers it in `arch/arm/dts/Makefile`. Without it, setting `CONFIG_DEFAULT_DEVICE_TREE="zynq-pynq-z1"` pointed U-Boot at a `.dts` that didn't exist, and the build failed on `arch/arm/dts/zynq-pynq-z1.dtb` with U-Boot's generic (and fairly unhelpful) `Device Tree Source is not correctly specified` error.

Also worth noting since it looked alarming in the build log: U-Boot's `dtb-$(CONFIG_ARCH_ZYNQ)` list compiles *every* Zynq board's `.dts` (zc702, zed, zybo, zturn, etc.) as part of `make dtbs`, regardless of which board defconfig is active — that's normal upstream behavior, not something specific to this setup, and the same thing happens (harmlessly) during the Zybo build too.

**Fix:** the second patch also happens to add a complete, real `configs/zynq_pynq_z1_defconfig` upstream — so instead of patching just the missing file and keeping the hand-rolled fragment, switched to using that defconfig directly (simpler than maintaining a duplicate of settings that already exist upstream). Deleted `uboot-fragment.config` (superseded). Current `pynq_z1_defconfig` U-Boot lines:
```
BR2_TARGET_UBOOT_BOARD_DEFCONFIG="zynq_pynq_z1"
BR2_TARGET_UBOOT_PATCH="$(BR2_EXTERNAL_ZYBO_Z7_PATH)/board/pynq-z1/uboot-patches/0001-ARM-zynq-add-Digilent-Zynq-PYNQ-Z1.patch $(BR2_EXTERNAL_ZYBO_Z7_PATH)/board/pynq-z1/uboot-patches/0001-pynq-add-ps7_init_gpl.c.patch"
```
Both patches now live in `zybo-br-tree/board/pynq-z1/uboot-patches/`. (Option name is `BR2_TARGET_UBOOT_PATCH`, not `BR2_TARGET_UBOOT_CUSTOM_PATCH_DIR` — the latter is a legacy alias that just sets `PATCH`'s default, per `boot/uboot/Config.in`.) Verified both apply cleanly against the pinned U-Boot 2019.10 source individually (`patch -p1 --dry-run`) — they touch disjoint files (dts/defconfig/Makefile vs. the board-specific ps7_init dir) so order between them doesn't matter.

### Commands

```bash
vivado -mode batch -source create_project.tcl -tclargs digilentinc.com:zybo-z7-20:part0:1.2 xc7z020clg400-1 zybo_radio ./zybo_radio
```

### Still open
- Re-running `build_all.sh` with this fix and confirming it actually builds — the previous attempt is what surfaced the missing-second-patch bug above.
- Confirming a real boot on PYNQ-Z1 hardware once the build succeeds.
- Both boards now have static IPs configured the same way (see "SSH + Static IP (Zybo)" above): Zybo `10.0.0.200`, PYNQ-Z1 `10.0.0.201`, via `board/pynq-z1/overlay/etc/network/interfaces` + `BR2_ROOTFS_OVERLAY` in `pynq_z1_defconfig`, same as Zybo's `BR2_SYSTEM_DHCP` → overlay swap. Not yet boot-tested on PYNQ-Z1 hardware.

---

## Vivado Project (PL side)

> **Current state: the Vivado project is the source of truth, not the script.**
> `vivado/create_project.tcl` was the bootstrap — it got the framework stood up and reached a first bitstream. Since then the design has moved on in the GUI (extra `blk_mem_gen` instances for the waveform tables, the `Data_SG` mapping fix, ongoing DSP work), and the script has *not* been kept in sync. Treat the sections below as a record of how the framework was built and why it's wired the way it is, not as the current build procedure.
>
> **Regenerate the script from the project rather than hand-maintaining it.** When the design settles, from the GUI's Tcl Console:
> ```tcl
> write_bd_tcl -force <path>/system_bd.tcl        # block design only
> write_project_tcl -force <path>/rebuild.tcl     # whole project incl. sources + IP
> ```
> That produces a regeneration script reflecting what's actually in the project, instead of best-guesses at Vivado automation behavior (which cost several debug cycles the first time around — see Gotchas).
>
> **`create_project.tcl` still carries `-force`**, so running it now would wipe the project and everything done in the GUI since. Remove the flag or the project path before it gets run by muscle memory.

Scripted project creation lives in `vivado/create_project.tcl`. It builds the block design, pulls in the `dsp-cake/comms_dsp` HDL, and sets `system_top` as the design top.

### Running it (bootstrap only — see note above)

**From a real terminal, not Vivado's GUI Tcl console.** `vivado -mode batch ...` is a shell command that launches a *separate* headless Vivado process; pasting it into an already-running GUI's console will at best error and at worst kill the session (the script's `exit 1` on bad args terminates the whole application when run inside the GUI's own interpreter — learned this the hard way).

```bash
cd /home/gareth/home_projects/zybo_NEW/vivado
vivado -mode batch -source create_project.tcl -tclargs digilentinc.com:zybo-z7-20:part0:1.2 xc7z020clg400-1 zybo_radio ./zybo_radio
```

Board identifiers:
- **Zybo Z7-20**: `board_part` = `digilentinc.com:zybo-z7-20:part0:1.2`, `part` = `xc7z020clg400-1` (verified against [Digilent/vivado-boards](https://github.com/Digilent/vivado-boards)'s `board.xml`).
- **PYNQ-Z1**: same `part` (same XC7Z020 chip), but its board files aren't in Digilent's repo — get the exact `board_part` from your local install with `get_board_parts -filter {NAME =~ *pynq*}` in the Tcl console.

Once it completes, open `<project_dir>/<project_name>.xpr` in the GUI to work interactively.

Note `create_project` currently carries `-force`, so **re-running wipes and regenerates the project directory**, including any manual GUI changes (added IP, hand-edited constraints). Fine while bootstrapping the framework; drop the flag once there's real work in the project you'd hate to lose.

### What the block design contains

```
PS DDR --(AXI DMA MM2S)--> PL dsp_top --(AXI DMA S2MM)--> PS DDR --> Linux --> Ethernet
PS GP0 --(AXI3->AXI4-Lite converter)--> PL reg_rw_interface   (user register space)
PS GP1 --> axi_dma_0 control/status
DMA mm2s/s2mm introut --> xlconcat --> PS IRQ_F2P             (for dma_proxy)
```

- **GEM is PS hard IP** — the PHY wires to PS MIO pins, so PL can't drive Ethernet directly. Data must transit DDR and go out via the normal Linux network stack; the AXI DMA and the GEM's own internal DMA are two separate engines chained through a DDR buffer.
- **HP0/HP1 split** — MM2S (+ the SG descriptor engine) on HP0, S2MM on HP1, so TX and RX don't contend for the same DDR path on a full-duplex radio.
- **GP0/GP1 split** — registers on GP0, DMA control on GP1, so they aren't sharing one master port through an interconnect.
- **Scatter-Gather enabled** on the DMA because `dma_proxy` expects it.
- An earlier draft used `axi_gpio` for the register space; dropped in favor of the existing `reg_rw_interface` HDL, which is BRAM-backed and already feeds `fpgaReg32` into the DSP chain.

### Ports the wrapper must expose

`system_top.vhd` instantiates `system_wrapper` and expects these external BD ports — if elaboration complains about port mismatches, this is the first place to look:

| Wrapper port | Purpose |
|---|---|
| `DDR_*`, `FIXED_IO_*` | PS7 dedicated pins, passed straight to top-level |
| `M_AXIS_MM2S_0_*` | DMA → PL sample stream (32-bit) |
| `S_AXIS_S2MM_0_*` | PL → DMA sample stream (32-bit) |
| `M_AXI_REGS_0_*` | AXI4-Lite → `reg_rw_interface` |
| `fclk`, `fclk_resetn` | PS `FCLK_CLK0` / `FCLK_RESET0_N`, renamed in the BD to match |

Making an interface external auto-names it `<interface>_0`, which is why the streams carry that suffix; the converter master and clock/reset are renamed explicitly in the script.

### Gotchas found while wiring this up

- **NCO ROM `.mem` files must be *design* sources, not just simulation sources.** `pll_2nd_order.vhd` instantiates two `xpm_memory_sprom` with `MEMORY_INIT_FILE => "cos.mem"` / `"sine.mem"`. Those are read by **synthesis**, which cannot see the `sim_1` fileset — adding them only there gives:

  ```
  [Synth 8-4445] could not open $readmem data file 'cos.mem';
  please make sure the file is added to project and has read permission, ignoring
  ```

  **Note "ignoring" — it is a warning, not an error.** Synthesis completes, the bitstream builds, and both ROMs come up filled with **zeros**, so the NCO emits nothing and carrier recovery silently does nothing. It only shows up as a dead receiver on hardware, and simulation passes throughout because the simulator *can* see `sim_1`. Treat this warning as fatal. Fixed in `create_project.tcl` with a second `add_files` (no `-fileset`) for `*.mem`; in the GUI it must go in **Design Sources**, not Simulation Sources.
- **`FIXED_IO` was missing from the old top level.** Only `DDR_*` was declared, so the wrapper's FIXED_IO would have dangled. Both are required on any PS7 design.
- **VHDL-2008 is mandatory.** `reg_rw_interface.vhd` and `pll_2nd_order.vhd` use `/* */` block comments, which don't exist in VHDL-93 — synthesis fails to parse them under Vivado's default. The script marks all VHDL as 2008.
- **`blk_mem_gen_2` isn't in the repo.** `reg_rw_interface` instantiates it but there's no `.xci`, so the script generates it (single-port, 32×2048, reset pin + `rsta_busy`) to match the component declaration. Worth checking against whatever was originally generated.
- **Reset polarity was conflicting.** `fclk_resetn` (active low) was being fed to both `dsp_top.ARST` (checked `= '1'`) and `reg_rw_interface.aresetn` (checked `= '0'`). Now `rst <= not fclk_resetn` and each gets the polarity it expects.
- **The datapath was crossed and partly floating.** `dsp_top`'s `ADC_IN` read a signal nothing drove, while the actual MM2S data went to a signal nothing consumed. Streams now follow the DMA's own channel naming (`mm2s_*` = into PL, `s2mm_*` = out of PL).
- **Hardcoded stimulus path in `test_dsp_top.vhd:33`** points at `/home/gareth/home_projects/comms_dsp/...`, which predates the move to `dsp-cake/comms_dsp/`. Simulation will fail on file-open until it's made relative or driven by a generic.
- **`.coe` init paths get baked into IP config.** The waveform `blk_mem_gen` instances initialize from `test_bench/cos.coe` / `sine.coe`; Vivado stores whatever path it was given in the `.xci`. If that's absolute, it breaks as soon as the repo moves — and `write_project_tcl` will capture the absolute form. Same failure mode as the stale testbench path above. Worth pointing them at repo-relative locations before exporting a regeneration script.
- **`Data_SG` left unmapped on the first bitstream** — see the address-map section below; the fix and its root cause are written up there.

### Getting the Bitstream into the Buildroot Image

There's already a working precedent for this in the tree: `configs/crc_example_defconfig` + `board/crc32/`, which loads a CRC32 HLS block's bitstream at boot. Same mechanism applies here.

**The XSA is not needed.** Xilinx's XSA → PetaLinux/Vitis flow exists to generate an FSBL and a devicetree. We use neither: boot is U-Boot SPL with mainline's bundled `ps7_init_gpl.c`, and the devicetree is mainline's. The only two things needed out of Vivado are the **`.bit` file** and the **PL address map** from the Address Editor.

**Nothing about the PS side changes.** GEM/Ethernet, SD, UART, USB are PS hard IP — a bitstream doesn't touch them, so Ethernet, static IPs, SSH, persistent root and the whole boot chain carry over untouched. That's the reason for the `#include` approach in the devicetree below rather than using a Vivado-generated dts.

**1. Bitstream into the FIT** — already supported, no new machinery. `mkfit.py` has always had an `Fpga` image class, and `post-image.sh` forwards its args, so it's just a second post-script arg:
```
BR2_ROOTFS_POST_SCRIPT_ARGS="zynq-zybo-z7-radio.dtb $(BR2_EXTERNAL_ZYBO_Z7_PATH)/board/radio/design_1.bit"
```
`mkfit.py` sorts args by `.dtb` extension, so the non-dtb one becomes the `fpga` image; U-Boot's `bootm` programs the PL before starting Linux. With the dual-config setup, the same bitstream is shared by both the `-ramdisk` and `-rootfs` configs.

**2. Custom devicetree that includes the board one.** This is what preserves the working peripheral set — the custom dts inherits everything from the stock board dts and only *adds* PL nodes. Template, adapted from `board/crc32/zynq-zybo-z7-crc.dts`:
```dts
/dts-v1/;
#include "xilinx/zynq-zybo-z7.dts"    // all PS peripherals inherited unchanged

&clkc {
	assigned-clocks = <&clkc 15>;
	assigned-clock-rates = <50000000>;  // FCLK0, drives the PL
};

&amba {
	// PL IP nodes go here - see below
};
```
Two adjustments vs. the crc example:
- **The include needs the `xilinx/` vendor prefix.** The crc example predates the kernel dts reorg and says `#include "zynq-zybo-z7.dts"`, which no longer resolves — same gotcha already hit with `pynq-z1.dts` (see Multi-Board section).
- Zybo needs switching from `BR2_LINUX_KERNEL_INTREE_DTS_NAME` to `BR2_LINUX_KERNEL_CUSTOM_DTS_PATH`. PYNQ-Z1 already uses `CUSTOM_DTS_PATH`, so it just needs its existing dts extended.

**3. PL IP nodes + kernel config.**

Address map, read off the Address Editor of the first build that reached bitstream (`dsp-cake/comms_dsp/test_bench/Table.xlsx`):

| Master | Slave | Base | Range |
|---|---|---|---|
| `axi_dma_0/Data_MM2S` | `S_AXI_HP0` (DDR) | `0x0000_0000` | 1G |
| `axi_dma_0/Data_S2MM` | `S_AXI_HP1` (DDR) | `0x0000_0000` | 1G |
| `M_AXI_REGS_0` → `reg_rw_interface` | — | `0x43C0_0000` | 64K |
| `axi_dma_0/S_AXI_LITE` | DMA control | `0x8040_0000` | 64K |

The GP0/GP1 split landed as intended — `0x43C0_0000` sits in GP0's window, `0x8040_0000` in GP1's.

Resulting `&amba` nodes:
```dts
&amba {
	axi_dma_0: dma@80400000 {
		compatible = "xlnx,axi-dma-1.00.a";
		reg = <0x80400000 0x10000>;
		clocks = <&clkc 15>;
		clock-names = "s_axi_lite_aclk";
		interrupt-parent = <&intc>;
		interrupts = <0 29 4>, <0 30 4>;
		#dma-cells = <1>;
		xlnx,include-sg;

		dma-channel@80400000 {
			compatible = "xlnx,axi-dma-mm2s-channel";
			interrupts = <0 29 4>;
			xlnx,datawidth = <0x20>;
		};

		dma-channel@80400030 {
			compatible = "xlnx,axi-dma-s2mm-channel";
			interrupts = <0 30 4>;
			xlnx,datawidth = <0x20>;
		};
	};

	user_regs: uio@43c00000 {
		compatible = "generic-uio";
		reg = <0x43c00000 0x10000>;
		clocks = <&clkc 15>;
	};
};
```

Interrupt numbering: `IRQ_F2P` starts at GIC SPI 61, which in devicetree is `<0 29 4>` (confirmed by the crc example using exactly that for its single F2P line). The two DMA lines through `xlconcat_0` are therefore `<0 29 4>` (mm2s, `In0`) and `<0 30 4>` (s2mm, `In1`).

Kernel options not currently in the Buildroot config, to be added via `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES`:
```
CONFIG_UIO=y
CONFIG_UIO_PDRV_GENIRQ=y
CONFIG_FPGA=y
CONFIG_FPGA_MGR_ZYNQ_FPGA=y
CONFIG_FPGA_REGION=y
CONFIG_OF_FPGA_REGION=y
```
Landed in `board/common/linux-radio.config`. Two things checking the kernel source saved:
- **`CONFIG_XILINX_DMA` is already `=y`** in the `multi_v7` defconfig — the AXI DMA driver needs nothing added.
- **FPGA manager needs no devicetree work.** Mainline `zynq-7000.dtsi` already declares both `devcfg@f8007000` (`xlnx,zynq-devcfg-1.0`) and an `fpga_full: fpga-region` referencing it, so enabling the Kconfig symbols is sufficient.

**Do you need FPGA manager?** Not for correctness — U-Boot programs the PL from the FIT before Linux starts. It's purely a development convenience: reload a bitstream over SSH instead of rebuilding the FIT, copying to SD and rebooting. Worth having for the same reason as the SSH/static-IP work. Format gotcha: the kernel's `zynq-fpga` manager wants a raw **`.bin`** (`write_bitstream -bin_file`, or bootgen), *not* the `.bit` with its header — U-Boot's `fpga loadb` is the one that takes `.bit` directly. Load with `echo design.bin > /sys/class/fpga_manager/fpga0/firmware` after dropping it in `/lib/firmware`.

**Gotcha: `compatible = "generic-uio"` binds to nothing on its own.** `uio_pdrv_genirq` ships with a deliberately *empty* OF match table, filled at runtime from a module parameter:
```c
static struct of_device_id uio_of_genirq_match[] = {
	{ /* This is filled with module_parm */ },
	{ /* Sentinel */ },
};
module_param_string(of_id, uio_of_genirq_match[0].compatible, 128, 0);
```
So the devicetree node is inert and no `/dev/uio*` appears until the kernel command line names the compatible string. Added to `board/common/boot.cmd`:
```
setenv bootargs 'root=/dev/mmcblk0p2 rw rootwait uio_pdrv_genirq.of_id=generic-uio'
```
This is a `boot.scr`-only change — recompile the script and copy it to the FAT partition, no Buildroot rebuild needed. Confirmed working: `/dev/uio0` appears, and `/sys/class/uio/uio0/maps/map0/addr` reads back `0x43c00000`.

Note the UIO node currently has no `interrupts` property, so `read()`-blocking on the fd for events isn't available — `mmap` register access works fine. If event support is wanted later, add `interrupts = <0 31 4>` and wire a third input into `xlconcat_0`.

**Known issue: `Data_SG` was left unmapped.** The same first build showed `/axi_dma_0/Data_SG` under "Incomplete Paths" pointing at `/axi_mem_intercon_2/M00_AXI` — the earlier `BD 41-2670` warning, unresolved. The design still built to bitstream (it's only a warning), but **SG-mode DMA can't fetch descriptors without it, so `dma_proxy` will fail at runtime.** Cause: the data-plane automation calls passed the *HP slave* pin as the object, and re-automating an already-automated HP0 made Vivado spin up a second interconnect whose master went nowhere. Fixed in `create_project.tcl` by targeting the *master* pin instead, plus an explicit fallback:
```tcl
assign_bd_address -target_address_space [get_bd_addr_spaces axi_dma_0/Data_SG] \
    [get_bd_addr_segs processing_system7_0/S_AXI_HP0/HP0_DDR_LOWOCM]
```
Verify `Data_SG` shows a real base/range in the Address Editor on the next regenerate before trusting the DMA.

### Still open (PL side)

- `dsp_top` has no output ports yet (`filtered_i`/`filtered_q` are internal), so the S2MM path is tied inactive in `system_top.vhd` with a TODO. Nothing reaches DDR until those are exposed and wired.
- `mm2s_tready` is tied high — `dsp_top` has no backpressure port, so the stream can't stall yet.
- I/Q packing on the 32-bit stream is undecided (interleaved samples vs I in low half / Q in high half); `system_top.vhd` currently slices the low 16 bits to match `dsp_top`'s `ADC_IN`.
- `dma_proxy` not set up yet — the AXI DMA driver probes (`xilinx-vdma 80400000.dma: Xilinx AXI DMA Engine Driver Probed!!`), but nothing drives it from userspace.
- `Data_SG` mapping fix applied in the GUI but **not yet re-synthesized** — the existing bitstream still has the dangling SG path, so SG-mode DMA won't fetch descriptors until synth+impl is re-run. This is the next thing likely to bite when `dma_proxy` goes in.
- `create_project.tcl` is out of sync with the project (waveform BRAMs, SG fix, DSP changes). Regenerate it with `write_project_tcl`/`write_bd_tcl` rather than editing it by hand.

---

## Radio Control Architecture

How the PS drives the PL radio, and how the two boards swap roles.

### Two paths to the PS — keep them separate

| Path | Carries | Why |
|---|---|---|
| **Register space (UIO, `0x43C0_0000`)** | Commands + status: start, role select, lengths, counters | Low latency, single-word, `mmap`-able. Poll or write from userspace with no driver. |
| **AXI DMA → DDR (`0x8040_0000` ctrl)** | Bulk data: demodulated payload, captured IQ, TX sample buffers | Full DDR bandwidth via HP ports. |

Bulk payload deliberately does *not* go through the register BRAM — that would cap throughput at PIO speed and waste the DMA path. Registers carry control words; streams go through DMA.

### Register map

Word offsets in the 64K AXI4-Lite window at `0x43C0_0000`:

| Offset | Name | Access | Contents |
|---|---|---|---|
| `0x00` | `ID_VERSION` | RO | Magic + version — confirms which bitstream is loaded |
| `0x04` | `CONTROL` | RW | `[0]` enable, `[1]` tx_start (pulse), `[2]` rx_enable, `[3]` clr_stats |
| `0x08` | `MODE` | RW | `[0]` role: 0=RX, 1=TX; `[3:1]` modulation; `[7:4]` spread factor |
| `0x0C` | `STATUS` | RO | `[0]` tx_busy, `[1]` pll_locked, `[2]` frame_valid, `[3]` overflow |
| `0x10` | `TX_LEN` | RW | Payload length, bytes |
| `0x14` | `RX_LEN` | RO | Last received payload length |
| `0x18` | `FRAME_COUNT` | RO | Frames decoded |
| `0x1C` | `ERR_COUNT` | RO | CRC failures |

`tx_start` is a **write-one pulse** — it self-clears after one cycle in PL. A level-held start bit would re-trigger every clock, so don't treat it as a latched enable.

### Symmetric TX/RX — one bitstream, role selected at runtime

Both boards get the **same** bitstream containing both TX and RX chains; `MODE[0]` picks which is active. Consequences:

- One bitstream to build and maintain, not two.
- Roles swap with a register write over SSH — no reflash, no reboot, no SD card. Consistent with the rest of this setup's bias toward removing reflash friction.
- Costs fabric (both chains resident), which is affordable on an XC7Z020 at these sample rates.

### Frame structure (v1)

Deliberately simple, chosen to be easy to parse in an FSM and easy to swap out later when experimenting with encoding schemes:

```
| PREAMBLE | SYNC WORD  | HEADER   | PAYLOAD    | CRC16 |
| 32 bits  | 32 bits    | 16 bits  | 0-255 B    | 16    |
  0xAAAAAAAA  0x1ACFFC1D   see below
```

- **Preamble** `0xAAAAAAAA` — alternating 1/0 for AGC settling and timing recovery.
- **Sync word** `0x1ACFFC1D` — the CCSDS attached sync marker. Standard, good autocorrelation, correlator-friendly.
- **Header** — `[15:12]` type (0=command, 1=data, 2=ack), `[11:4]` payload length in bytes, `[3:0]` reserved.
- **CRC-16-CCITT** (poly `0x1021`) over header+payload — cheap LFSR in PL.

Receive FSM after the despreader: `SEARCH` (correlate for sync) → `HEADER` → `PAYLOAD` → `CRC` → raise `frame_valid`, bump `FRAME_COUNT` or `ERR_COUNT`.

### `reg_rw_interface` rebuild

The original module could not round-trip a register write, for three separate reasons:

1. **No address decode** — `addra` was latched but unused; the write loop wrote `wdata` into *every* `fpga_reg(i)`, so all registers always held the same value.
2. **`wea` hardwired to `'0'`** in all three branches of `write_data_proc` — the BRAM write-enable never asserted.
3. **`dina` never driven** after reset — even had `wea` fired, it would have written zeros.

Reads returned `douta` (from the BRAM), which nothing ever wrote. The three TODOs left in the file line up with exactly this.

**The BRAM was dropped in the rebuild.** For a control/status register file it's the wrong primitive: read latency complicates the AXI handshake, PL logic can't see individual register bits without reading them back through the single port, and RO status registers driven *from* PL don't fit a port the PS also writes. A flop array is simpler, single-cycle, and exposes every register directly to PL logic — ~512 flops for 16 registers, trivial on a 7020. This also removes the `blk_mem_gen_2` dependency that was never checked into the repo. If a bulk staging buffer is wanted later it belongs in its own module, not in the control path.

### Driving the registers from the PS

`radioctl` (`package/radioctl/`, enabled via `BR2_PACKAGE_RADIOCTL=y` on both boards) ships in the rootfs at `/usr/bin/radioctl`. It `mmap`s the register window through `/dev/uio0` rather than `/dev/mem`, so it stays tied to the devicetree node instead of a hardcoded physical address, and isn't affected by `CONFIG_STRICT_DEVMEM`.

```sh
radioctl dump                 # every register, decoded
radioctl read status
radioctl write mode 0x1
radioctl role tx              # or: role rx
radioctl enable               # / disable
radioctl listen               # enable + rx_enable
radioctl transmit 64          # set tx_len=64, then pulse tx_start
radioctl clrstats
radioctl -d /dev/uio1 dump    # if the node enumerates elsewhere
```

**First thing to check after a new bitstream** — `radioctl dump` prints `id` with an `(ok)` / `(UNEXPECTED - wrong bitstream?)` marker against `0x5A790001`. If that magic doesn't read back, nothing else in the map is trustworthy: either the PL isn't configured, the UIO node is mapping the wrong window, or an older bitstream is loaded.

Writes to read-only offsets are rejected by the tool (and discarded harmlessly in PL, which returns OKAY rather than erroring — a stray poke can't hang the AXI bus).

`tx_start` and `clr_stats` are **write-one pulses**: `radioctl transmit` sets the bit, PL emits a one-clock strobe, and the stored bit reads back as 0. That's expected, not a failed write.

**Quick one-off pokes without the tool** — BusyBox has `devmem` (`CONFIG_DEVMEM=y`), which bypasses UIO and hits the physical address directly:
```sh
devmem 0x43c00000 32          # read ID_VERSION
devmem 0x43c00008 32 0x1      # MODE = TX
```
Useful for a fast sanity check, but `radioctl` is preferable for anything repeated — it decodes bit fields and won't silently read a stale/unmapped window.

**Bringing up a link across both boards** (once the TX/RX chains are driving the registers):
```sh
# on the receiver
radioctl role rx && radioctl listen

# on the transmitter
radioctl role tx && radioctl transmit 64

# back on the receiver
radioctl read frames          # should increment
radioctl read errors          # CRC failures
```

To extend the map: add the constant in `hdl/pkg.vhd`, the `case` arm in `reg_rw_interface.vhd`, the table entry in `package/radioctl/src/radioctl.c`, and the enum in `package/radiomon/src/radio_regs.h` — all three userspace copies are mirrors of the VHDL and are kept in sync by hand. Bump the low half of `C_ID_MAGIC` when the layout changes, so an old bitstream paired with a new `radioctl` is caught by the id check rather than producing confusing reads.

## DSP Chain (PLL, NCO, matched filter)

Working notes on `dsp-cake/comms_dsp/hdl`. Most of this was debugging existing WIP rather than new design.

### NCO / carrier recovery (`pll_2nd_order.vhd`)

Four separate faults, found while chasing a garbled output on a pure-sine stimulus:

1. **Both LUT ROMs were asleep.** `sleep => '1'` on the `xpm_memory_sprom` instances. `sleep` is dynamic power-down — asserted, the memory doesn't read and `douta` is invalid. Everything downstream was garbage regardless of the rest. Should be `'0'`.
2. **`0x"00"` isn't the literal it looks like.** VHDL-2008 parses `<length>x"..."`, so that's a *zero-length* bit string, not hex zero. Should be `x"00"`.
3. **Loop filter overflowed on essentially every sample.** It did `resize(resize(K1,32) * phase_err + resize(K2,32) * e_prev, 32)` — the products are 48-bit, and resizing to 32 drops the high bits. With `K1 = 105` against a 32-bit `phase_err`, the loop was being driven by wrapped garbage. Now: products carried at full width (`C_PROD_W = 48`, `C_SUM_W = 49`), scaled by an explicit `shift_right(acc, C_GAIN_FRAC)` — that shift *is* the fixed-point gain — then clamped through `sat32()`. Saturation matters specifically because `u` is the frequency word: a wrap would slam the NCO from maximum positive to maximum negative frequency and throw the loop entirely, rather than just pinning it.
4. **The NCO wasn't generating a sinusoid.** `increment_phase` was computed but never used, so `phase_map` advanced every valid clock instead of every 256th; the quadrant sign inversion the comments described was never implemented, so the output was the quarter-wave repeated four times.

**Why `phase_acc(7 downto 0) = x"00"` never fired**, which is what surfaced #4: the accumulator steps by `u`, not by 1, so it *jumps over* exact values. If `u = 1000`, the low byte advances by `1000 mod 256 = 232` per cycle and only returns to zero if that sequence happens to close on it — and `u` changes every cycle while the loop converges. **Equality-testing a stepped accumulator is unreliable by construction**; detect the carry (`phase_acc(8) xor phase_acc_prev(8)`) if you need the event at all.

**Restructured so the question doesn't arise.** The accumulator's upper bits *are* the phase index, so `increment_phase`/`phase_map` were deleted entirely:

```vhdl
quadrant <= phase_acc(31 downto 30);          -- [31:30] quadrant
raw_idx  <= phase_acc(29 downto 22);          -- [29:22] LUT index, [21:0] sub-phase
phase_lookup <= raw_idx when quadrant(0)='0' else not raw_idx;   -- quarter-wave fold
-- cos negative in Q1/Q2, sin negative in Q2/Q3, using quadrant_d
```

Only `phase_acc` is sequential now; everything downstream is a combinational slice. The structural point: a **separately-counted index has no enforced relationship to the accumulator** — any missed or spurious increment desynchronizes it permanently, with nothing to re-sync. Slicing makes them incapable of disagreeing. `quadrant_d` delays the quadrant one cycle to match `READ_LATENCY_A => 1`, so sign folding lands on the right sample; ROM `ena` is `data_valid` to match the accumulator's gating (tying it to `'1'` would let `cos_raw` update on cycles `quadrant_d` didn't).

Verified working on a pure-sine stimulus after these.

### LUT generation (`test_bench/sin_cos_lut_gen.py`)

- **`.mem` was written decimal but XPM reads it `$readmemh`-style.** `32767` would parse as `0x32767` and overflow 16 bits. Added `write_mem()` emitting zero-padded hex. The `.coe` path is fine with decimal because the radix is declared in the header.
- **`cos.coe` was missing its first entry** — 255 values starting at 32766, where `cos.mem` correctly had 256 starting at 32767. That's a one-index phase offset between sine and cosine, i.e. a constant rotation you'd chase in the PLL. The on-disk file was a stale artifact from an older version of the script (space-separated single line vs. the current comma-per-line), so regenerating fixed it.
- Added a `check()` guard aborting generation if a table isn't `2**ADDR_BITS` long, so truncation fails loudly instead of showing up as phase error in hardware.
- Round-trip verified: both `.mem` files parse back to the numpy reference exactly.

### `blk_mem_gen` vs XPM

Address width is **derived from depth** in the `blk_mem_gen` wizard — never set directly; `C_ADDRA_WIDTH` is a derived parameter, and the generated core has fixed port widths. The "4 or 32" options are the *data* width field. For a genuinely generic-parameterized ROM use `xpm_memory_sprom`, which takes `ADDR_WIDTH_A` etc. as real generics and needs no `.xci` in the repo. Two trip-ups: `MEMORY_SIZE` is in **bits** (256 entries × 16 = 4096), and `READ_LATENCY_A` puts a cycle inside the loop.

Vivado's Language Template for the VHDL variant documents defaults in *Verilog* notation (`1'b0`, `8'b0`), so anything lifted from those comments needs translating — `'0'`, `(others => '0')`.

### Matched filter (`matched_filter_rrc.vhd`, `dsp_pkg.vhd`)

**TX and RX weren't the same filter, so nothing could match.** `waveform_generator.py` shaped with `span=17, sps=4` → 69 taps, while `dsp_pkg.vhd` had `FILTER_LEN = 17` filled with a placeholder triangle explicitly commented *"Replace with actual scaled RRC coefficients"*. Fixed by generating both from one definition: `span=4, sps=4` gives exactly `span*sps+1 = 17` taps, matching `FILTER_LEN` with no VHDL structural change.

`waveform_generator.py` gained `rrc_taps_quantized()` and `write_vhdl_coeffs()`, which emit `rrc_coeffs.vhd` from the same RRC definition used for TX shaping. **Regenerate taps and stimulus together — they're only matched if they come from the same RRC.**

**Taps must be generated at the RX rate, not the TX rate.** An RRC is defined in *samples per symbol*, and `ddc_fs_4` decimates by 2, so the matched filter sees 2 sps from a 4 sps transmit stream. Taps generated at the TX rate would stretch the pulse by the decimation factor and stop being matched. `write_vhdl_coeffs(rx_sps=...)` re-derives the pulse at the RX rate while holding **span in symbols**, so the filter still covers the same stretch of the transmit pulse:

| | sps | span | taps |
|---|---|---|---|
| TX shaping (stimulus) | 4 | 4 symbols | 17 |
| RX matched filter | 2 | 4 symbols | **9** → `FILTER_LEN = 9` |

Sanity check that the derivation is right rather than merely plausible: the 9 taps come out as exactly the even-indexed subset of the 17-tap set, which is what sampling the same continuous pulse at half the rate must give.

Two further bugs in the filter itself:

1. **It wasn't computing a convolution.** The tap loop accumulated into a *signal* (`i_acc <= i_acc + ...`), so every iteration read the same pre-update value and only the last assignment survived — one tap, not a FIR — and nothing cleared it between samples, so it drifted into saturation. Accumulation must use a **variable**, zeroed per sample.
2. **The output slice discarded the result.** `i_out <= i_acc(63 downto 48)` took the top 16 bits of a 64-bit accumulator whose real content occupies ~30 bits — pure sign extension, so the output read as 0 or -1.

`C_OUT_LSB` is **verified numerically** rather than estimated, by simulating the full chain in numpy (mix at fs/4, decimate by 2, convolve with the current taps) against the actual `ddc_input.dat`. Current value **15**: accumulator peaks at ~8.2e8 (30 bits), giving an output peak near 25.1k — 76% of full scale, no clipping; `LSB=14` clips 34 of 200 samples. Four things invalidate this and all of them have moved at least once during bring-up: `peak_bits`, the carrier, the decimation factor, and the input level. Re-run the check rather than assuming.

### Downconversion, and the chain order (`ddc_fs_4.vhd`, `dsp_top.vhd`)

**The DDC and PLL were alternative branches, not stages.** `dsp_top` selected between them with `G_PLL`, so the PLL path had *no downconversion at all* — the matched filter was being fed a signal still sitting at the fs/4 carrier. Since the RRC cutoff is ~169 kHz and the carrier is at 250 kHz, the filter could only attenuate it (measured 0.72×), never demodulate. That's the "output looks like a reduced-amplitude copy of the input" symptom.

They're complementary stages and now run in series:

```
ADC_IN (real, carrier at fs/4)
  -> ddc_fs_4        coarse downconversion, decimate by 2 (4 sps -> 2 sps)
  -> pll_2nd_order   residual frequency/phase only
  -> matched_filter  genuinely at baseband, 2 sps
```

The division of labour matters: the DDC strips the bulk carrier using nothing but sign flips (no multipliers), leaving the PLL to track a small residual — what a 2nd-order loop is actually good at. Asking the PLL to acquire from DC all the way to fs/4 is the fragile case, especially with no centre-frequency term in the accumulator.

`G_PLL` was repurposed rather than removed: it now **bypasses** the PLL (DDC → filter directly), which is useful for isolating the filter from loop behaviour while tuning.

**`ddc_fs_4`'s mixing was correct; its output stage wasn't.** The `{+x, 0, -x, 0}` / `{0, +x, 0, -x}` sequence is proper fs/4 mixing — this is the sign alternation `dsp_top`'s old even/odd split was missing. But the output did `i_out <= i_temp` in the same phase `i_temp` was being written, and a signal read inside a clocked process sees the *pre-edge* value — which came from phase 3, where the I path is always zero. **`i_out` was permanently zero**, and `q_out` only ever carried one of the four mixer phases. Same class of bug as the matched filter accumulator.

Rewritten to capture I on even phases into `i_hold` and emit the complete pair on the following odd phase — a full edge later, so the read sees settled data. Verified against ideal fs/4 mixing in numpy: output pairs match exactly, decimating 2:1.

One inherent caveat worth knowing rather than discovering later: the fs/4 mixer takes I from sample *n* and Q from *n+1*, so the pair carries a **half-sample I/Q skew**. Standard fixes are a half-sample interpolator or accepting it at high sps.

Because the DDC now removes the bulk carrier, **`u` should settle near zero rather than the `0.25 × 2**32` figure below** — that value applies only when the PLL is fed the raw carrier. `u` running away to a large value points at the DDC not doing its job upstream.

### Sample rate, system clock, and `data_valid`

**The chain never needs a clock converter.** It runs on the 100 MHz `SYS_CLK` and advances exactly one sample per `data_valid` — `phase_acc`, the filter shift register and the accumulator are all gated on it. So the effective sample rate is set by *how often that strobe fires*, not by any clock. That's the standard pattern: fast fabric clock, valid strobe at the sample rate, no CDC or MMCM.

**Consequence for stimulus files: `.dat` has no time base.** It's a sequence of numbers with a certain number of *cycles per sample*; the hardware replays it at whatever rate `data_valid` fires. Only the dimensionless ratio carries over from Python:

```
carrier / fs = cycles per sample = u / 2**32
```

`test_dsp_top.vhd` holds `valid_in` high and feeds one sample per clock, so its effective rate is 100 MHz — the Python's nominal `fs = 1 MHz` is irrelevant to the hardware, only `carrier/fs` matters.

This gives a sharp lock check: **the NCO's `u` should converge to `cycles_per_sample × 2**32`.** For the current fs/4 stimulus that's `0.25 × 2**32 = 1,073,741,824`. Landing somewhere else means locking to an image, or not locking.

**`G_VALID_SRC` generic** on `system_top` selects the strobe source, so the same RTL covers sim and hardware:

| Value | Source | Use |
|---|---|---|
| `VALID_DMA` | `mm2s_tvalid` from the AXI-Stream | normal build (default) |
| `VALID_ALWAYS` | tied `'1'` | simulation; rate = system clock |
| `VALID_ADC` | external ADC strobe | not wired yet — add the port when the ADC path exists |

Declared as an enum (`valid_src_t` in `pkg.vhd`) rather than a string so a wrong value is an elaboration error instead of silently taking the fallback branch.

### Stimulus carrier — why it moved to fs/4

The original `freq_offset_hz = 5000` against `fs = 1 MHz`, `sps = 4` put a **0.005 cycles/sample** carrier under a signal occupying `(1/4)(1+0.35) = 0.34` cycles/sample of bandwidth. The signal therefore extended well below zero frequency, and `apply_frequency_offset()` takes `np.real()`, which folds the negative-frequency image directly back onto the signal — I and Q are unrecoverable in principle, not just in practice.

Now `freq_offset_hz = fs/4` (0.25 cycles/sample), which puts the signal at 81–419 kHz in nominal terms: clear of both DC and Nyquist, and matching what `ddc_fs_4` expects. Verified by FFT of the generated file.

Also **seeded the symbol generator** (`seed=1234`). It was using unseeded `np.random`, so every regeneration produced a different stimulus — which makes the filter output scaling unrepeatable and sim runs incomparable. Verified: repeat runs now produce an identical `ddc_input.dat`.

### Reference symbols for self-checking

`qpsk_symbols.dat` holds the pre-modulation truth the demodulator should eventually reproduce — the testbench's existing "need to add self checking" TODO.

It was **only storing the I component**: `save_to_file()` does `int(sample)` on complex data, which silently drops the imaginary part, so half of every QPSK symbol was lost. Now written by `save_symbols_to_file()` as `I Q` pairs, one per line, and `save_to_file()` raises on complex input so the failure can't recur silently.

### Symbol timing recovery (`timing_recovery_gardner.vhd`)

Carrier recovery alone doesn't give bit recovery. The PLL can lock phase perfectly and the matched filter still be sampled at the wrong instant — that's a second, independent loop, and without it there are no bits.

**Gardner** was chosen for the first cut:

- It is **decision-free** — the error needs no symbol decisions, so it can bootstrap before anything is demodulated. Decision-directed detectors (Mueller & Müller) need a working slicer, which is a chicken-and-egg problem during acquisition.
- It wants **exactly 2 samples/symbol**, which is already what `ddc_fs_4` produces. That's the reason the DDC decimates to 2 rather than 1.

```
e[k] = (I[k] - I[k-1])*I[k-1/2] + (Q[k] - Q[k-1])*Q[k-1/2]
```

`[k]`/`[k-1]` are consecutive on-symbol samples, `[k-1/2]` the mid-symbol sample between them. All three sit on the 2 sps grid, so forming the error needs **no interpolation**.

Structure mirrors the PLL: a phase accumulator (`mu`) spanning one symbol, nominal increment `2**31` so it wraps once per symbol at 2 sps, and a loop filter that perturbs the increment. The carry-out marks the sample chosen as the symbol instant. Output is 1 sample/symbol.

**Known limitation — timing is quantised to whole input samples.** The loop takes whichever sample the accumulator lands on, so the sampling instant moves in half-symbol steps and the residual error never drops below ±1/4 symbol. That needs no multipliers and is enough to close the loop for bring-up, but it is not a final answer.

**Upgrade path is additive.** `mu` is the fractional symbol phase — exactly what a Farrow interpolator consumes. Swapping "take the nearest sample" for "interpolate at `mu`" leaves the detector and loop filter untouched. Farrow + polyphase resampling deliberately deferred to a standalone project once the basic RX algorithms are in place.

Fixed-point follows the rules the PLL loop filter had to learn the hard way: full-width products (`C_PROD_W = 33`, `C_ERR_W = 34`, `C_LOOP_W = 50`), an explicit `shift_right(loop_v, G_GAIN_FRAC)` gain rather than an implicit truncation, and saturation instead of wrapping. `C_ADJ_LIMIT = 2**28` bounds the loop's authority to ±12.5% of nominal so it can't invert or stall the symbol rate.

Bugs caught on self-review before simulation, all worth knowing about because they generalise:

- **`C_NOMINAL_INCR` is `2**31`, which does not fit in a *positive* signed 32-bit value.** Casting `x"80000000"` straight to `signed` yields −2³¹, so the offset arithmetic was operating on a large negative number and saturating. Fixed by zero-extending (`signed('0' & C_NOMINAL_INCR)`) into 34-bit arithmetic. Same class of error as the earlier loop-filter truncation — the width was fine, the *interpretation* wasn't.
- **`timing_err` used `resize(err, 32)` on a 34-bit value**, silently dropping the top two bits so a large error could read back as a small one. Now saturates via `sat32()`.
- The `incr` update recomputed the clamped adjustment inline instead of reusing `adj` — redundant and a place for the two copies to drift apart. Now computed once into `adj_v`.

**Not yet simulated, and not yet wired into `dsp_top`** — the chain still ends at `matched_filter_rrc`. First thing to check in sim is **loop polarity**: the adjustment is added to the increment, and whether that pulls the sampling instant toward or away from correct depends on the sign convention. Backwards polarity turns a converging loop into a diverging one. If `timing_err` grows instead of settling toward zero, negate `adj_v`. `G_K = 64` / `G_GAIN_FRAC = 24` are untuned starting values in exactly the way `C_GAIN_FRAC` was for the PLL.

### Framed-burst stimulus and the floating-point reference receiver

With the full RX chain in place the old stimulus (random symbols, no framing) stopped being enough — it could not exercise sync, CRC, or re-acquisition. `waveform_generator.py` gained `run_frames()`, which builds a real transmit chain in Python: frame assembly → CRC → QPSK map → RRC shaping → fractional timing offset → upconversion → quantise → AWGN.

Default burst is **4 frames × 16 payload bytes**, seeded, with 32-symbol idle gaps between frames so `frame_sync` is forced back into its hunt state each time — a single lucky lock that then coasts would prove nothing about re-acquisition. Outputs are `ddc_input.dat`, `qpsk_symbols.dat`, and `rx_expected.txt` (per-frame type/seq/len/CRC/payload, plus the exact metadata word `rx_frame_buffer` should prepend).

Impairments are deliberate, one per loop:

| Knob | Default | Exercises |
|---|---|---|
| `freq_err_hz` | 0.1% of symbol rate | Carrier PLL — **on top of** fs/4, since `ddc_fs_4` removes exactly fs/4 and the PLL would otherwise have nothing to do |
| `timing_offset` | 0.37 symbol | Gardner acquisition |
| `ppm` | 20 | Gardner *tracking* — a clock error means the loop can't just acquire once |
| `snr_db` | 25 | Gives the CRC a job |

`check_filter_scaling()` now models the DDC + matched filter numerically and prints the accumulator peak against every candidate `C_OUT_LSB`. Re-verified after the amplitude change: **15 still correct** (49% full scale, no clipping; 14 reaches 98% and is too tight with noise).

**Bit-truth checking in the RTL testbench.** `run_frames()` also emits `rx_expected_stream.dat` — the exact AXI-Stream beats `rx_frame_buffer` should produce (`<data hex8> <tkeep hex1> <tlast 0|1>`, one line per beat, metadata word then little-endian payload words). `test_dsp_top.vhd` compares every accepted beat against it.

This exists because **frame count plus CRC is not a ground-truth check**. A frame passing CRC-16 proves it is internally self-consistent, not that it carries the bits that were transmitted — a generator bug producing a well-formed frame with the wrong contents passes CRC every time. The verdict now also requires `beat_errors = 0` and `exp_exhausted = '1'`; the latter catches frames that never arrived at all, since beats that don't arrive cannot mismatch.

**`rx_model.py` is a floating-point reference receiver** that decodes `ddc_input.dat` and checks it against `rx_expected.txt`. It deliberately does *not* model the PLL or Gardner loop — it uses the known offsets directly. That isolates "is the frame format self-consistent?" from "do the loops converge?", so a failure is attributable. It also sweeps all four carrier lock angles, because a clean run otherwise leaves the phase-ambiguity path completely untested.

Both questions it was built to answer came back *no*, which is the point:

**Bug 1 — `C_PREAMBLE = 0xAAAAAAAA` gives the timing loop no error signal.** Under this QPSK mapping `1010...` maps every symbol pair to `(b1,b0) = (1,0)` — the *same constellation point every time*. Gardner's error is `(I[k] - I[k-1]) * I[k-1/2]`; with no symbol transitions that difference is identically zero, so the timing loop cannot acquire during the preamble at all. Changed to **`0xCCCCCCCC`** (`1100...`), which alternates between two antipodal points, giving a transition every symbol and reducing to BPSK for the carrier loop. Alternating bits are the right instinct at the *bit* level; this constellation cares about the *symbol* level. Costs nothing in the receiver — `frame_sync` hunts the sync word, never the preamble.

**Bug 2 — `ddc_fs_4` produced the conjugate baseband.** The Q branch used `+sin`, making the mixer multiply by `cos + j·sin = exp(+jωn)` — an *up*conversion. Downconversion is `exp(-jωn) = cos - j·sin`, so the sin term must be negated:

```
x[0] = A·cos(φ)            -> I = +x[0]
x[1] = A·cos(π/2 + φ) = -A·sin(φ)  -> Q = -x[1]     (was +x[1])
```

This is the more interesting failure because of *how well it hides*. A conjugated QPSK signal is still a perfectly valid QPSK signal — clean constellation, matched filter fine, carrier loop still locks. Everything upstream of the slicer looks right, which is exactly why it survived earlier simulation. It breaks at `frame_sync`: conjugation is a **reflection** `(I,Q) → (I,-Q)`, and the four things `frame_sync` tests are **rotations**. A reflection is not among them, so sync would never fire — for any rotation, at any SNR, however well both loops converged. Symptom would have been "the DSP all looks correct but no frames ever arrive."

Fixed in `ddc_fs_4.vhd` and in `fs_by_4_mix()` in `dsp_pkg.vhd` (unused by the DDC, which has inline logic, but it would have reintroduced the same bug).

**Consequence to check:** flipping the Q sign also flips the apparent sign of any residual frequency offset, so `pll_2nd_order`'s loop polarity needs re-confirming against the corrected DDC — a loop that converged before may now diverge.

After both fixes the model recovers all 4 frames, CRC OK, at all four carrier lock angles.

### Bit-truth checking in the RTL testbench

`run_frames()` emits `rx_expected_stream.dat`: the exact AXI-Stream beats `rx_frame_buffer` should produce, as `<data hex8> <tkeep hex1> <tlast 0|1>`, one line per beat — metadata word then little-endian payload words. `test_dsp_top.vhd` compares every accepted beat against it.

This exists because **frame count plus CRC is not a ground-truth check**. Passing CRC-16 proves a frame is internally self-consistent, not that it carries the transmitted bits; a generator bug producing a well-formed frame with wrong contents passes every time. The verdict now also requires `beat_errors = 0` and `exp_exhausted = '1'`. The second matters more than it looks: beats that never arrive cannot mismatch, so `beat_errors` alone would report clean on a run that delivered 2 of 4 frames.

**`rx_expected_stream.dat` must be added to the `sim_1` fileset**, or the VHDL file open fails at elaboration.

### Lock-quality metric (`rx_quality.vhd`) and the auto-tuner design

Groundwork for an automatic loop tuner: run TX/RX over the channel, sweep loop coefficients, stop when the known sequence comes back.

**The design decision that makes or breaks it: frame count is a cliff, not a gradient.** A search optimising "did the frame arrive" sees `0,0,0,0,4` and has no slope to follow, degenerating into brute-force grid search over a 4-dimensional space. It needs a metric that degrades *smoothly*.

`rx_quality.vhd` accumulates, over recovered symbols:

```
sum_min = Σ min(|I|,|Q|)      sum_max = Σ max(|I|,|Q|)
```

The PS forms `sum_min/sum_max`. For QPSK sitting cleanly on the diagonal, `|I| = |Q|` and the ratio → 1. Carrier phase error rotates points off the diagonal; timing error and ISI make magnitudes vary; noise does both. All pull it down, continuously.

**Why a ratio specifically:** there is no AGC, so signal level is uncontrolled. Any absolute measure (EVM against a fixed reference, MSE, distance from a nominal point) moves with input amplitude, and a tuner optimising it would chase gain rather than lock quality. `min/max` is scale-free by construction. It also needs no reference symbols, so it works on live traffic — usable as a runtime lock indicator, not just a tuning objective. No divider in fabric; the PS does the division.

`frame_sync` also exports `sync_count` — every sync detection whether or not CRC later passes. That is the graded step between "nothing works" and "a frame arrived": a match means 16 consecutive symbols were correct, which is real progress while the frame body still fails.

Planned tuner, **not yet built**:

| Piece | Approach |
|---|---|
| Coefficients | `TIMING_CFG` (K, shift), `CARRIER_K` (K1, K2), `CARRIER_CFG` (shift) as RW registers |
| Objective | `qual_min/qual_max`, then `sync_count`, then `frame_count` — lexicographic, coarse to fine |
| Search | Coordinate descent; the metric is smooth enough to hill-climb |
| Loop | PS writes coefficients → replays fixed stimulus via MM2S → reads metric → steps |

Optimising frame count *directly* is the mistake — it is flat almost everywhere.

**Deliberately deferred: making the coefficients writable.** That means converting `timing_recovery_gardner` and `pll_2nd_order` from generics to ports — churn on two modules currently under suspicion — and more fundamentally a tuner can only fix what is tunable. Until the chain is known structurally correct, a search would grind indefinitely proving no coefficient helps.

### Open issues in the DSP chain

- **Phase detector reads previous-cycle values.** `I_rot`/`Q_rot` on the right-hand side of the cross product are clocked signals, so they're one cycle stale relative to `I_in`/`Q_in`, and the ROM adds another. Loop-dynamics tuning, not garbling.
- **`pll_2nd_order` has no valid output.** `dsp_top` compensates with a one-cycle delay on `ddc_valid`, which silently breaks if the PLL's internal pipelining changes. A real `valid_out` on the PLL would be more robust.
- **Half-sample I/Q skew** from the fs/4 mixer (I from sample *n*, Q from *n+1*) — inherent, not a bug, but it shows up as a fixed phase error if unaccounted for.
- **`dsp_top` has no output ports.** `filtered_i`/`filtered_q`/`filtered_valid` are internal, so nothing reaches `system_top` or the S2MM path. Needed before any demodulated data reaches DDR.
- **`C_GAIN_FRAC = 16` is a starting point, not a derived value.** Depends on phase-detector output scaling. Locks-but-crawls → lower it; oscillates → raise it.
- `status_reg` is still tied to zeros in `system_top.vhd`, so `frames`/`errors`/`pll_locked` read 0 regardless of what the chain does.
- `mm2s_tready` is still tied `'1'` — with `G_VALID_SRC = VALID_DMA` the chain can't backpressure the DMA, so a stall would drop samples silently.

## RX Loopback Demo — file → DDR → PL → DDR → file

Plays a recorded sample file into the RX chain over MM2S and checks the frames
that come back over S2MM against the transmitted payload. This is the first
thing that exercises the whole datapath on real hardware rather than in
simulation, and it needs no transmitter — the stimulus is the Python TX model's
output.

```
ddc_input.dat --> radioctl loopback --> DDR (play region) --> MM2S --> dsp_top
                                                                          |
   verdict <-- rx_expected_stream.dat <-- DDR (capture region) <-- S2MM <--+
```

### Why playback is split into one transfer per frame

The obvious implementation — push the whole file in one MM2S transfer —
captures frame 1 and silently drops the rest. Three facts combine:

- MM2S plays at **one sample per fabric clock** (25 ns at 40 MHz), because
  `mm2s_tready` is tied `'1'` and `dsp_valid` is `mm2s_tvalid`.
- `rx_frame_buffer` is a **single** store-and-forward buffer that backpressures.
  A frame arriving while the previous one is still draining is dropped and
  flagged in `STATUS.OVERFLOW`.
- The inter-frame gaps are 32 symbols, about **3 µs**. Userspace cannot re-arm
  an S2MM transfer inside that.

So `waveform_generator.py` now emits `rx_chunks.txt` — one `<first sample>
<count>` line per frame, with boundaries at the **midpoints of the idle gaps**,
so each chunk carries its frame plus half a gap of lead-in and half of run-out.
One frame per transfer makes overflow impossible by construction rather than by
timing luck, and gives the truth check the same granularity as
`rx_expected.txt`.

Mapping symbol index to sample index is not `k * sps`: `lfilter` in the pulse
shaper is causal (delays by `span/2` symbols) and `apply_timing_offset`
resamples at a fractional phase and a ppm-scaled rate. `symbol_to_sample()`
carries the derivation.

### Buffer layout

The 16 MB reserved region is split in half — low half plays, high half
captures. One region would work only until a capture overran the samples still
being played.

### Running it

**How to invoke it lives in [system_design.md §5.3](system_design.md)**, with
the other usage documentation — including which three files have to be copied to
the board and why they are not installed in the rootfs. Not duplicated here:
two copies of a command line is exactly the drift this project keeps paying for.

### What it reports, and one thing it deliberately does not fail on

Per chunk: bytes received, the decoded metadata word, and a beat-by-beat
comparison. Then the register counters for the run (`frames`, `errors`,
`syncs`, quality ratio, `OVERFLOW`).

The metadata word is compared on its **low 16 bits only** — length, type,
sequence. Bits 31:16 are the PL's running count of frames that *passed CRC*, so
one early failure shifts it for every frame after, turning a single fault into a
cascade of misleading failures. The drift is reported as a note instead.

A run that captured everything but was never bit-checked is not called a pass.

### `radiomon` — live register plotting

`package/radiomon/` (C++14, `BR2_PACKAGE_RADIOMON=y`) polls the register window
and plots the lock-quality ratio as a terminal trace, with the counters below
it.

It plots the **interval** ratio, not the raw registers. `qmin`/`qmax` are
free-running accumulators since the last `clrstats`, so the ratio straight off
the hardware is a cumulative average — it converges and then barely moves,
which is exactly wrong for watching the effect of a change. The difference in
both accumulators since the previous poll is what responds. A poll interval
carrying no symbols holds the last value rather than drawing zero: zero reads as
"locked badly" when the truth is "nothing arrived".

The y axis is pinned to 0..1 rather than autoscaled, so the trace means the same
thing between runs — an autoscaled axis makes a flat bad lock look identical to
a flat good one. The 0.70 line is drawn because that is the threshold
`radioctl` already calls a poor lock.

```sh
radiomon                       # 250 ms poll, 60x10 plot
radiomon --interval 100 --width 100 --height 16
```

**It maps the register window only, never the DMA**, so it is safe to leave
running while the PL's state is uncertain — same reasoning as `radioctl dump`
versus `dmainfo`. Run it in one SSH session while `radioctl loopback` runs in
another.

The plotting library is [fbbdev/plot](https://github.com/fbbdev/plot), MIT,
vendored as a single packed header. It needed one fix to cross-compile:
`utils::max(1l, ...)` at three sites, where `Coord` is `std::ptrdiff_t` — `long`
on a 64-bit host, `int` on 32-bit ARM — so template deduction fails only when
built for the board. The header's top comment records it; reapply it if the file
is ever re-packed.

## Boot script, rootfs updates, and build identification

### `boot.scr` is now generated by the build — and the drift it was hiding

`boot.scr` used to be built by hand with `mkimage`, and drifted out of sync with the FIT. `board/common/boot.cmd` asked for `conf-zynq-zybo-z7-rootfs`, but `mkfit.py` derives configuration names from the **DTB filename**:

```python
board = os.path.splitext(os.path.basename(dtb))[0]   # zynq-zybo-z7-radio
name  = 'conf-' + board + '-rootfs'                  # conf-zynq-zybo-z7-radio-rootfs
```

so the real name carried `-radio` and `boot.cmd` did not. The failure is nastier than a plain error: `bootm` fails on the missing configuration, U-Boot falls through to a bare `bootm`, and that takes the FIT's **`default`** — which is the *ramdisk* configuration. The board boots, looks completely healthy, and silently discards every change written to it, because root is a ramdisk rather than `mmcblk0p2`.

It presented as "`lsblk` shows no `/` mountpoint and `mmcblk0p2` is at `/mnt/data`". On a ramdisk root, edits made on the board vanish at reboot while rootfs changes from a rebuild *do* appear — which mimics a working persistent setup closely enough to fool you for a while.

`post-image.sh` now:

- builds `boot.scr` from each board's `boot.cmd`, located by finding the directory containing that board's `.dts` (so adding a board needs no edit here);
- **fails the build** if the configuration `boot.cmd` requests is absent from the generated `fit.its`, listing the available names.

`board/pynq-z1/boot.cmd` was already correct (`pynq-z1.dtb` → `conf-pynq-z1-rootfs`).

### `clk_ignore_unused` — without it the PL runs unclocked

**Symptom:** `fpga_manager` reports `operating`, the devicetree is correct, all three UIO devices probe at the right addresses, `dmesg` is clean — and *any* access to `0x43C0_0000` hard-locks the CPU. No oops, no console output, no return; only a power cycle recovers it.

**Cause:** FCLK0 clocks the entire PL. `ps7_init`/U-Boot enables it at boot, but no *Linux* driver claims it — `uio_pdrv_genirq` parses no `clocks` property and enables nothing. Moving `axi_dma_0` from `xlnx,axi-dma-1.00.a` to `generic-uio` removed the last driver that did (the Xilinx DMA driver calls `clk_prepare_enable()`). The common clock framework then runs `clk_disable_unused()` at late boot and gates it off.

The PL is left **configured but unclocked**. Its AXI slave physically cannot respond, and a Zynq-7000 AXI master has no transaction timeout, so the read never completes and the core locks. `fpga_manager` still reports `operating` because configuration and clocking are independent — which is precisely why that reading misleads here.

**Diagnosis** — safe, reads kernel state and never touches the bus:

```bash
mount -t debugfs none /sys/kernel/debug
grep -E "^ *fclk0 " /sys/kernel/debug/clk/clk_summary
```

```
fclk0    0    0    0    50000000   0   0   50000   N
         ^enable  ^prepare                         ^enabled
```

Enable count 0, prepare count 0, `N`. Rate correct at 50 MHz — `assigned-clock-rates` in the dts worked — but gated off.

**Fix:** `clk_ignore_unused` in bootargs, now in both `boot.cmd` files.

Two things worth remembering about it:

- It only prevents the kernel **disabling** a clock that is already on; it cannot enable one that never was. It works here only because `ps7_init` turns FCLK0 on before Linux starts.
- It is the **blunt** fix — it disables that safety net for every clock in the system. The precise fix is to give FCLK0 a consumer whose driver genuinely enables it.

**Useful corollary:** FCLK0 really is 50 MHz while the Vivado design appears constrained at 100 MHz, so the failing timing paths have roughly double the slack the report shows. The constraint should still be corrected so the report means something.

**Diagnostic ordering lesson.** Three theories were wrong before this one — a stale `.mem` fileset, an out-of-range register decode, and the address map. The address map *was* genuinely misconfigured (`assign_bd_address` had put the register block at `0x4000_0000`) and fixing it was necessary, but it was not what caused the hang. What finally isolated it was refusing to touch the bus at all: `clk_summary`, sysfs and `dmesg` answered the question with zero risk, where every `radioctl` attempt cost a power cycle and produced no information.

### Updating the persistent rootfs

`rootfs.ext4` cannot be written to `mmcblk0p2` while running from it. The two-configuration FIT makes the ramdisk config a deliberate escape hatch:

```bash
# on the board: move boot.scr aside so U-Boot falls through to the FIT default
mv /mnt/boot/boot.scr /mnt/boot/boot.scr.bak
reboot
# now on the ramdisk root, with p2 free:
dd if=/mnt/boot/rootfs.ext4 of=/dev/mmcblk0p2 bs=4M
resize2fs /dev/mmcblk0p2          # rootfs.ext4 is sized to its CONTENTS, not
                                  # the 16 GB partition - without this the
                                  # filesystem stays small regardless
mv /mnt/boot/boot.scr.bak /mnt/boot/boot.scr
reboot
```

Alternatively pull the card and write it from the host.

### `S41mountdata` mounted the root partition twice

The guard grepped `/proc/mounts` for `^/dev/mmcblk0p2 `, which **never matches when it is the root filesystem**: the kernel reports the device it was handed on the command line as `/dev/root`.

```
/dev/root / ext4 rw,relatime 0 0
```

So in the persistent-root configuration the partition was mounted at both `/` and `/mnt/data`. Linux permits one filesystem at two paths, but it is confusing and awkward to unmount or fsck cleanly. The script now checks both what the kernel was *asked* to use as root (`root=` in `/proc/cmdline`) and what is actually mounted at `/` under either name.

### Build identification: `BUILD_ID` + `STATUS.BUILD_DIRTY`

"Is the PL actually the design I think it is?" was the wrong assumption more than once — a rootfs rebuilt against a bitstream that was *not* rebuilt looks identical from userspace right up until something hangs.

`BUILD_ID` (`0x30`, RO) carries the first 32 bits of the git commit, generated at project-creation time into `hdl/build_id.vhd` and read back with `radioctl read build` or `radioctl dump`.

**The dirty flag is doing the real work.** During development the tree almost always has uncommitted changes, so the hash alone names a commit the bitstream does not correspond to. `STATUS.BUILD_DIRTY` (bit 4) means "lower bound, not an identification". Under CI — building from a clean checkout — `dirty = 0` and the hash becomes a genuine identification.

`build_id.vhd` is **generated and gitignored**: a tracked file rewritten on every build would keep the tree permanently dirty, defeating the flag it carries. Two generators exist — `create_project.tcl` (before `add_files`) and `dsp-cake/comms_dsp/gen_build_id.sh` (standalone, no Vivado, for command-line simulation, a fresh clone, or CI). Without one of them having run, `system_top.vhd` fails to elaborate on the missing package.

### Time sync

Neither board has a battery-backed RTC, so the clock starts at the epoch every boot and every log timestamp is meaningless until something sets it. Nothing was configured.

Enabled busybox's `ntpd` via `board/common/busybox-ntp.config` (no new package), with `S49ntp` in both overlays and the server in `/etc/default/ntp` so it can be changed on the board without a rebuild.

**`ntpd` is invoked twice, deliberately.** A normal NTP daemon *slews* — nudging a few ppm at a time so time never jumps backwards. Slewing a 50-year error would take effectively forever, so the first correction must be a **step** (`ntpd -q`), and only then does the daemon take over for drift. Skip the `-q` pass and the clock sits at 1970 looking like NTP is broken.

Points at the **dev host (`10.0.0.191`), not a public pool**: there is no `resolv.conf` in either overlay so hostnames will not resolve, and syncing both boards to one local server makes them agree with *each other* — which matters more than absolute accuracy once TX logs on one board are correlated against RX logs on the other. Note that address is a DHCP lease on the host's wifi; a static reservation would make it durable.

The host must *serve* NTP (`chrony` with `allow 10.0.0.0/24`); `systemd-timesyncd` is client-only. Check with `sudo chronyc clients` — without `sudo` it returns `501 Not authorised` whether or not anything has connected.

Changing the busybox config requires `make busybox-rebuild`, or the applet set is silently reused without `ntpd`.

## WHERE THINGS STAND — read this first

Live state at the end of the last working session. Nothing here is settled.

### 0. State of the board and tree right now

The Vivado project **has** been regenerated from `create_project.tcl` and rebuilt to a bitstream (`vivado.log`, `launch_runs` through `write_bitstream`, copied to the repo root and `board/common/zybo_radio.bit`), and `fit.itb` was rebuilt afterwards, so the FIT carries it. That was the previous "next action" and it is done at the build level. The pinned `0x43C0_0000`, the fatal address-map check, `latest_ipdef`, the manual interconnect wiring and `build_id.vhd` generation all survived a real run.

What is still out of step:

| Thing | State | Consequence |
|---|---|---|
| Everything above | Built, **never booted** | None of it is proven in hardware yet, only in the tool |
| FCLK0 | Changed 50 → 40 MHz in both the tcl and the dts | Needs a Vivado rebuild *and* a Buildroot rebuild; the two must land together |
| `BUILD_ID` in the built bitstream | `0x0e03d0a8`, which **is not a commit in this repo** | The workspace move rewrote history. `BUILD_DIRTY` is set so it was only ever a lower bound, but regenerate `build_id.vhd` before the next build or `radioctl read build` names a commit that does not exist |
| `radioctl` / `radiomon` on the board | Rebuilt into `output-zybo/target/`, not yet onto the card | Needs an image rebuild and the rootfs update dance below |
| `clk_ignore_unused` | In both `boot.cmd` files | Confirm the `boot.scr` on the FAT partition was regenerated; otherwise it only applies when typed by hand at the U-Boot prompt |

**Next action:** rebuild the bitstream at 40 MHz, confirm `WNS` is now positive, then rebuild the images and update the rootfs. After that the loopback demo is runnable end to end for the first time.

Avoid another hand edit to the BD: the script is the source of truth and has now proven it can rebuild the design.

### 1. `ddc_input.dat` is currently a ZERO-IMPAIRMENT bisect stimulus

**This is the single easiest thing to be confused by.** The file on disk right now has no timing offset, no clock error, no carrier residual and no noise — it is not the default `run_frames()` output. It was regenerated deliberately to split one question in two.

`rx_model.py` confirms it still decodes 4/4. `rx_expected_stream.dat` is **unchanged** by this (payloads come from the same seed), so nothing needs re-adding to the project.

| Result of running it | Meaning |
|---|---|
| Passes 4/4 | Framing, slicer, buffer, packing, DMA stream are structurally correct. Everything left is loop *performance* — add impairments back one at a time (`timing_offset` → `ppm` → `freq_err_hz` → `snr_db`) and whichever breaks it names the loop to tune. |
| Still fails | Structural bug in the RTL that the Python model does not share. The loops are a red herring. |

Restore the impaired stimulus with:

```bash
cd dsp-cake/comms_dsp/test_bench
python3 -c "from waveform_generator import RRCWaveformGenerator as G; \
  G(alpha=0.35,sps=4,span=4,num_symbols=100,fs=1_000_000,seed=1234).run_frames(n_frames=4,payload_len=16,plot=False)"
```

### 2. Last simulation result, and what it rules out

```
frames passing CRC : 0        frames failing CRC : 2
stream beats seen  : 0        expected frames    : 4
```

**`err_count = 2` means sync fired twice.** A sync match needs 16 consecutive correct symbols; false-sync probability is ~4 × 2⁻³² per position, so across ~2000 symbols those were real frames, correctly detected.

That **rules out a loop polarity inversion** — a diverging loop never produces 16 good symbols in a row. Do not spend time flipping `adj_v` before re-testing. The picture is: sync detection works, the frame *body* corrupts. Two frames synced and failed CRC; two never synced.

`rx_model.py` decodes the same stimulus 4/4. The model and the RTL differ in exactly one respect — the model uses ideal timing and ideal carrier derotation. That points at loop residual error, not correctness.

Unexplored theory worth testing: during the 32-symbol inter-frame gaps the signal is zero, so Gardner's error term (a *product* of samples) goes to zero and `incr` holds, but the phase accumulator free-runs and may land on the wrong half-symbol when the next preamble arrives. Capture `inst_timing/incr` across a gap — if it walks away from `0x80000000` while the input is silent, that is the mechanism, and it would explain "some frames acquire, some don't".

### 3. The Vivado script — resolved, including one bug that hard-locked the board

`create_project.tcl` was changed to disable Scatter-Gather, and took four attempts to build. Sequence, most recent last:

1. `[Ip 78-92] Failed to extract configurable options` / `No valid slave interface could be found to connect to M_AXI_MM2S`. Two hypotheses tried and **both wrong**: restoring `c_sg_include_stscntrl_strm {0}` did not help, and the IP config was demonstrably fine because the GP1 → `S_AXI_LITE` automation on the *preceding* line succeeded.
2. Replaced both data-plane `apply_bd_automation` calls with explicit manual wiring (1×1 `axi_interconnect` per HP port, clocks, resets, addresses). `safe_net` guards each connection, because the GP1 automation already drives some DMA pins and `connect_bd_net` errors on an already-driven pin.
3. `[BD 5-313] Found unsupported IP 'axi_interconnect:1.7'` — `get_ipdefs -all` returns every version and `[lindex ... 0]` picked the deprecated one. `latest_ipdef` now selects the highest version by dictionary sort.
4. **The register block landed at `0x4000_0000` instead of `0x43C0_0000`.** This is the important one.

**Why #4 matters far more than the others.** `assign_bd_address` does not preserve any particular offset — with no explicit base it drops each segment at the bottom of the master's window, and GP0's window starts at `0x4000_0000`. The old automation path happened to place the register block at `0x43C0_0000`; nothing was ever pinning it there.

Nothing warns about this. It builds clean and fails at runtime in the worst available way: the devicetree node (`uio@43c00000`), `C_AXI_BASE_ADDR` in `pkg.vhd` and `REGS_PHYS` in `radioctl` all still say `0x43C0_0000`, so every register access lands outside any mapped segment. **A Zynq-7000 AXI master has no transaction timeout**, so the read is never answered and the CPU locks solid — no oops, no console, no clue. The symptom was "`fpga_manager` reports `operating` and *any* `radioctl` command hangs the board".

Two guards added: the offset is now pinned explicitly with `set_property offset 0x43C00000`, and a check at the end of the script `exit 1`s if the segment is anywhere else. A fault that is invisible at build time and undebuggable at runtime has to fail the build.

Note the other four IP lookups still use `[lindex ... 0]`. They work because those IPs are single-version in this catalog, but the pattern is unsafe and worth cleaning up.

**Scatter-Gather is off on purpose** — see the long comment in `create_project.tcl`. With SG on, the Simple-mode registers (`S2MM_DA`/`S2MM_LENGTH`) do not exist at all and every transfer needs descriptor chains in memory. Reverting to SG=1 permanently means rewriting the userspace DMA path around descriptors.

### 4. Timing — the constraint was never wrong, and FCLK0 is now 40 MHz

`WNS = -1.017 ns`, `TNS = -87.5 ns`, **96 failing endpoints**, all on `clk_fpga_0` and all in `uut/inst_filter` — the matched filter's DSP48 cascade (`q_shift_reg_reg[8][15]` → `q_out0__5/PCIN[*]`). Nothing in the AXI path fails, which is why the register hang turned out to be the address map rather than timing.

**Correcting what this section used to say.** It claimed the design was constrained at 100 MHz while the devicetree ran FCLK0 at 50, and therefore had twice the slack the report showed. That was wrong, and it was wrong in the direction that invites ignoring a real violation. The Clock Summary in `system_top_timing_summary_routed.rpt` reads:

```
Clock       Waveform(ns)       Period(ns)      Frequency(MHz)
clk_fpga_0  {0.000 10.000}     20.000          50.000
```

20 ns — the constraint always matched the devicetree. There was nothing to reconcile, and `-1.017 ns` was a genuine failure at the clock the board actually ran. Check the number before theorising about it: `get_property PERIOD [get_clocks clk_fpga_0]` on the implemented design answers this in one line.

**Why place-and-route cannot fix it.** The failing path is 19.27 ns of which **16.4 ns (85%) is logic**, across 13 levels: seven chained DSP48E1s in a PCOUT→PCIN cascade plus a CARRY4 chain and a LUT2. Five of those cascade hops are 1.713 ns each and are fixed silicon. Implementation strategies and post-route `phys_opt` work on the 2.86 ns of routing, so the entire budget they can address is smaller than the miss. Retiming has only the one output register to move and cannot cover seven cascade stages. This is where a day disappears for no gain.

**Root cause, and the proper fix.** `matched_filter_rrc.vhd` computes nine multiplies and the whole adder tree between two flops, so none of the DSP48's internal A/M/P registers get used. The real fix is to register the products and split the adder tree — contained, but it changes chain latency, and `dsp_top` compensates for the PLL's missing `valid_out` with a hand-counted delay that has to move with it. That wants a simulation behind it, so it is a separate change.

**What was done instead: FCLK0 50 → 40 MHz.** 25 ns closes every failing endpoint with roughly 4 ns spare, with no RTL change and no latency shift. It costs nothing real — the DSP chain advances one sample per `data_valid`, so the fabric clock sets no sample rate, and nothing at these frame sizes needs the AXI bandwidth. Two places, and **they must agree**:

| Where | Setting | What it controls |
|---|---|---|
| `vivado/create_project.tcl` | `CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {40}` on the PS7 | The timing constraint, and nothing else |
| `board/common/zynq-zybo-z7-radio.dts` | `assigned-clock-rates = <40000000>` | The rate the hardware actually runs at |

They are independent because boot uses mainline U-Boot's bundled `ps7_init_gpl.c` rather than an FSBL generated from the Vivado project — nothing reconciles the two automatically. If they drift apart, the timing report stops describing the board, which is the situation this section previously mis-diagnosed.

Vivado emits a bitstream even when timing fails; it is only a critical warning. Confirm `WNS` is positive on the next rebuild rather than assuming the clock change took.

### 5. Repo split

Work is moving to `radio-shoulders` (flattened single repo; nested `dsp-cake` and `zybo-br-tree` `.git` dirs removed). `zybo_NEW` retains the originals including the `gareware83/dsp-cake` remote.

Buildroot is **not** committed — clone it to the repo root, since `build_all.sh` does `make -C ../buildroot/` relative to `zybo-br-tree`.

Watch the output trees: they are named `output/`, `output-zybo/` and `output-pynq/`, roughly 22 GB combined. A `--exclude='output-*'` pattern **silently misses the first one** — the hyphen matters. `.gitignore` uses `output*/`.

## Status

- [x] Clone jbootsma/zybo-br-tree and build initial Buildroot image
- [x] Confirm UART console on /dev/ttyUSB0 at 115200
- [x] ~~Verify ps7_init.tcl from Vivado Zybo board project~~ — turned out unnecessary; mainline U-Boot already bundles Zybo's `ps7_init_gpl.c`, no Vivado project needed (see Multi-Board section)
- [ ] Load U-Boot via XSCT using component method above — not needed for the SD/persistent-root path in use now, still untried
- [x] **Zybo Z7: fully functional persistent-fs boot** (ext4 root on `/dev/mmcblk0p2`, SSH, static IP `10.0.0.200`, auto-boot via `boot.scr`)
- [ ] PYNQ-Z1: same, on real hardware (config/build-level work done, not yet boot-tested)
- [~] PL/DSP radio implementation — Vivado project + PS/PL datapath block design built through to bitstream; `dsp-cake/comms_dsp` DSP modules WIP. S2MM return path not yet driven.
  - [x] NCO/carrier recovery working on a pure-sine stimulus (see DSP Chain section — ROM sleep, loop-filter overflow, NCO restructure)
  - [x] Real RRC taps generated at the RX rate (9 taps @ 2 sps) and matched to TX shaping; filter convolution + output scaling fixed
  - [x] Stimulus moved to an fs/4 carrier, seeded for reproducibility; reference symbols now carry both I and Q
  - [x] DDC output stage fixed (`i_out` was permanently zero) and put in series ahead of the PLL rather than branched against it
  - [x] Chain verified in simulation with the series DDC→PLL→filter order
  - [x] Full RX chain written and wired: Gardner timing recovery → QPSK slicer → frame sync → store-and-forward buffer → S2MM stream
  - [x] Two convention bugs found by the Python reference model before RTL sim: preamble mapping to a constant symbol, and `ddc_fs_4` producing conjugate baseband
  - [x] Bit-truth self-checking testbench (compares every S2MM beat against transmitted payload)
  - [x] Lock-quality metric (`rx_quality.vhd`) + `sync_count`, readable from the PS
  - [~] **RX chain does not yet recover frames in simulation** — sync fires, CRC fails. See "Where things stand".
  - [ ] Farrow interpolator / polyphase timing recovery — deferred to a standalone project
  - [ ] Automatic loop tuner — metric built, coefficient registers deliberately not yet added
- [x] **PL register window pinned to `0x43C0_0000`** with a build-time check — an unpinned `assign_bd_address` put it at `0x4000_0000` and hard-locked the CPU on every register access
- [x] `boot.scr` generated by `post-image.sh`, with a build-time check that the requested FIT configuration exists
- [x] Persistent-root boot confirmed on hardware (`mmcblk0p2` at `/`), double-mount of the root partition fixed
- [x] `BUILD_ID` + `STATUS.BUILD_DIRTY` so a running board reports which commit its bitstream came from
- [x] NTP (busybox `ntpd`) against the dev host on both boards — no RTC on either
- [x] **`clk_ignore_unused` in bootargs** — without it FCLK0 is gated off after boot, the PL runs unclocked, and any register access hard-locks the CPU
- [~] **Timing**: was WNS −1.017 ns on 96 endpoints in the matched filter's DSP cascade, at a constraint that turned out to be correct all along (50 MHz, matching the dts). FCLK0 dropped to 40 MHz in both the tcl and the dts; **rebuild and confirm WNS is positive**. Pipelining the filter MAC is the proper fix and is still open
- [x] **RX loopback demo**: `radioctl loopback` plays a sample file through DDR → MM2S → RX chain → S2MM → DDR and checks every beat against the transmitted payload. One transfer per frame, boundaries from `rx_chunks.txt`, because the single frame buffer backpressures and a 3 µs gap is not re-armable from userspace. Built and host-tested; **not yet run on hardware**
- [x] `radiomon` — live terminal plot of the lock-quality ratio + counters, register window only. Cross-compiles for the board (needed one 32-bit fix in the vendored plot library)
- [ ] CI joining the Vivado and Buildroot builds (bitstream → `board/common/` → FIT is currently a manual step)
- [x] **PL/PS plumbing live on hardware** — AXI DMA probes at `0x8040_0000`, `/dev/uio0` maps the register window at `0x43C0_0000`, FPGA manager present at `/sys/class/fpga_manager/fpga0`
- [x] Register control path end-to-end, **verified on hardware** — rebuilt `reg_rw_interface` (real address decode, RO/RW split, pulse bits) + `radioctl` in the rootfs. `id` reads `0x5A790001`, RW registers round-trip (`mode`, `tx_len`), `tx_start` self-clears after `transmit`.
- [ ] TX/RX chains driving the registers — `status_reg` is tied to zeros in `system_top.vhd` until they do
- [ ] PS-side software for the datapath — `dma_proxy` (or hand-rolled UIO DMA) not started
- [ ] Ethernet-based radio comms between the two boards — not started
