// SPDX-License-Identifier: GPL-2.0-or-later
//
// radioctl - drive the comms DSP PL from userspace.
//
// Two jobs: poke the control/status register window, and run the RX datapath
// (arm the DMA, wait for a frame, print it).
//
// Everything is reached through UIO rather than /dev/mem, so it works without
// CONFIG_STRICT_DEVMEM caveats and stays tied to devicetree nodes. UIO also
// maps with pgprot_noncached, which matters for the DMA buffer: the Zynq HP
// ports are not cache-coherent with the CPU, so a cached mapping would serve
// stale lines for data the PL had just written.
//
// The register map lives in the PL; see hdl/pkg.vhd for the authoritative
// definitions. Keep the tables below in sync with it.

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define REG_MAP_SIZE 0x10000UL
#define DMA_MAP_SIZE 0x10000UL

/*
 * Physical addresses from the block design's Address Editor. These are fixed
 * by the PL, not by the board, so matching on them is stable. The DMA buffer
 * has no fixed address - it is whatever the devicetree reserved - so it is
 * found as the UIO device that is neither of these.
 */
#define REGS_PHYS 0x43c00000UL
#define DMA_PHYS  0x80400000UL

/* Word offsets, matching C_REG_* in hdl/pkg.vhd */
enum {
	REG_ID          = 0,
	REG_CONTROL     = 1,
	REG_MODE        = 2,
	REG_STATUS      = 3,
	REG_TX_LEN      = 4,
	REG_RX_LEN      = 5,
	REG_FRAME_COUNT = 6,
	REG_ERR_COUNT   = 7,
	REG_SYNC_COUNT  = 8,
	REG_QUAL_MIN    = 9,
	REG_QUAL_MAX    = 10,
	REG_QUAL_SYMS   = 11,
	REG_BUILD_ID    = 12,
	REG_COUNT
};

/* CONTROL bits */
#define CTRL_ENABLE     (1u << 0)
#define CTRL_TX_START   (1u << 1)   /* write-one pulse, self-clearing in PL */
#define CTRL_RX_ENABLE  (1u << 2)
#define CTRL_CLR_STATS  (1u << 3)

/* MODE bits */
#define MODE_ROLE       (1u << 0)   /* 0 = RX, 1 = TX */

/* STATUS bits */
#define STAT_TX_BUSY     (1u << 0)
#define STAT_PLL_LOCKED  (1u << 1)
#define STAT_FRAME_VALID (1u << 2)
#define STAT_OVERFLOW    (1u << 3)
#define STAT_BUILD_DIRTY (1u << 4)

#define ID_MAGIC 0x5A790001u

/*
 * AXI DMA register offsets, Simple mode (SG is disabled in the IP - see the
 * note in vivado/create_project.tcl). Byte offsets from the DMA base.
 */
#define S2MM_DMACR   0x30
#define S2MM_DMASR   0x34
#define S2MM_DA      0x48
#define S2MM_LENGTH  0x58

#define DMACR_RS        (1u << 0)
#define DMACR_RESET     (1u << 2)
#define DMACR_IOC_IRQEN (1u << 12)
#define DMACR_ERR_IRQEN (1u << 14)

#define DMASR_HALTED   (1u << 0)
#define DMASR_IDLE     (1u << 1)
#define DMASR_DMAINTERR (1u << 4)
#define DMASR_DMASLVERR (1u << 5)
#define DMASR_DMADECERR (1u << 6)
#define DMASR_IOC_IRQ  (1u << 12)
#define DMASR_ERR_IRQ  (1u << 14)

#define DMASR_ERRORS (DMASR_DMAINTERR | DMASR_DMASLVERR | DMASR_DMADECERR)

/* Frame metadata word prepended by rx_frame_buffer.vhd */
#define META_LEN(m)   ((m) & 0xffu)
#define META_TYPE(m)  (((m) >> 8) & 0xfu)
#define META_SEQ(m)   (((m) >> 12) & 0xfu)
#define META_COUNT(m) (((m) >> 16) & 0xffffu)

static const struct {
	const char *name;
	int         idx;
	int         writable;
} regs[] = {
	{ "id",      REG_ID,          0 },
	{ "control", REG_CONTROL,     1 },
	{ "mode",    REG_MODE,        1 },
	{ "status",  REG_STATUS,      0 },
	{ "tx_len",  REG_TX_LEN,      1 },
	{ "rx_len",  REG_RX_LEN,      0 },
	{ "frames",  REG_FRAME_COUNT, 0 },
	{ "errors",  REG_ERR_COUNT,   0 },
	{ "syncs",   REG_SYNC_COUNT,  0 },
	{ "qmin",    REG_QUAL_MIN,    0 },
	{ "qmax",    REG_QUAL_MAX,    0 },
	{ "qsyms",   REG_QUAL_SYMS,   0 },
	{ "build",   REG_BUILD_ID,    0 },
};

static volatile uint32_t *base;      /* register window */
static volatile uint32_t *dma;       /* DMA control window */
static volatile uint8_t  *buf;       /* reserved DDR, uncached */
static unsigned long      buf_phys;
static unsigned long      buf_size;

static uint32_t rd(int idx)             { return base[idx]; }
static void     wr(int idx, uint32_t v) { base[idx] = v; }

static uint32_t dma_rd(unsigned off)             { return dma[off / 4]; }
static void     dma_wr(unsigned off, uint32_t v) { dma[off / 4] = v; }

static int lookup(const char *name)
{
	for (size_t i = 0; i < sizeof(regs) / sizeof(regs[0]); i++)
		if (!strcmp(regs[i].name, name))
			return (int)i;
	return -1;
}

/* ------------------------------------------------------------------ */
/* UIO discovery                                                       */
/*                                                                     */
/* There are three UIO devices now (registers, DMA, buffer) and their   */
/* numbering depends on probe order, which is not guaranteed. Hardcoding*/
/* /dev/uio0 worked when there was only one; it would silently point at */
/* the wrong device now. Match on the physical address in sysfs instead.*/
/* ------------------------------------------------------------------ */

static int sysfs_hex(const char *path, unsigned long *out)
{
	FILE *f = fopen(path, "r");
	if (!f)
		return -1;
	int n = fscanf(f, "%lx", out);
	fclose(f);
	return n == 1 ? 0 : -1;
}

/*
 * Finds the UIO device whose map0 physical address is `want`. If want == 0,
 * finds the first device that is NOT one of the known PL register windows -
 * that is the DMA buffer, whose address is assigned by the devicetree and so
 * differs per board.
 */
static int uio_find(unsigned long want, unsigned long *addr, unsigned long *size)
{
	char path[128];

	for (int i = 0; i < 32; i++) {
		unsigned long a, s;

		snprintf(path, sizeof(path),
			 "/sys/class/uio/uio%d/maps/map0/addr", i);
		if (sysfs_hex(path, &a) < 0)
			continue;

		snprintf(path, sizeof(path),
			 "/sys/class/uio/uio%d/maps/map0/size", i);
		if (sysfs_hex(path, &s) < 0)
			continue;

		if (want ? (a == want) : (a != REGS_PHYS && a != DMA_PHYS)) {
			if (addr) *addr = a;
			if (size) *size = s;
			return i;
		}
	}
	return -1;
}

static void *uio_map(int uio_idx, size_t len, int *fd_out)
{
	char dev[32];
	snprintf(dev, sizeof(dev), "/dev/uio%d", uio_idx);

	int fd = open(dev, O_RDWR | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", dev, strerror(errno));
		return MAP_FAILED;
	}

	void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		fprintf(stderr, "mmap %s: %s\n", dev, strerror(errno));
		close(fd);
		return MAP_FAILED;
	}

	if (fd_out)
		*fd_out = fd;
	else
		close(fd);   /* the mapping survives the descriptor */
	return p;
}

/* ------------------------------------------------------------------ */
/* RX datapath                                                         */
/* ------------------------------------------------------------------ */

static int dma_reset(void)
{
	dma_wr(S2MM_DMACR, DMACR_RESET);

	/* Reset self-clears. Bounded rather than a bare spin so a wedged or
	 * unclocked DMA reports instead of hanging - an unclocked PL is a
	 * common enough failure that it deserves a message. */
	for (int i = 0; i < 100000; i++)
		if (!(dma_rd(S2MM_DMACR) & DMACR_RESET))
			return 0;

	fprintf(stderr, "DMA reset did not complete - is the PL clocked and "
			"the bitstream loaded?\n");
	return -1;
}

static long now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

/*
 * Arms one S2MM transfer and waits for it. Returns bytes received, or -1.
 *
 * Simple mode: destination address, then length, and writing the length is
 * what starts the transfer. The PL terminates it early with TLAST at the end
 * of a frame, and S2MM_LENGTH then reads back the actual byte count.
 */
static long rx_one(int timeout_ms)
{
	if (dma_reset() < 0)
		return -1;

	dma_wr(S2MM_DA, (uint32_t)buf_phys);
	dma_wr(S2MM_DMACR, DMACR_RS);

	/* Cap at the buffer size; a frame is far smaller and TLAST ends it. */
	uint32_t want = buf_size > 0x400000 ? 0x400000 : (uint32_t)buf_size;
	dma_wr(S2MM_LENGTH, want);

	long deadline = now_ms() + timeout_ms;
	for (;;) {
		uint32_t sr = dma_rd(S2MM_DMASR);

		if (sr & DMASR_ERRORS) {
			fprintf(stderr, "DMA error, DMASR=0x%08x%s%s%s\n", sr,
				(sr & DMASR_DMAINTERR) ? " int-err" : "",
				(sr & DMASR_DMASLVERR) ? " slave-err" : "",
				(sr & DMASR_DMADECERR) ? " decode-err" : "");
			return -1;
		}

		if (sr & DMASR_IOC_IRQ) {
			dma_wr(S2MM_DMASR, DMASR_IOC_IRQ);  /* w1c */
			return (long)dma_rd(S2MM_LENGTH);
		}

		if (now_ms() > deadline)
			return -2;   /* timeout, not an error */

		usleep(1000);
	}
}

static void hexdump(const volatile uint8_t *p, unsigned len)
{
	for (unsigned i = 0; i < len; i += 16) {
		printf("  %04x  ", i);
		for (unsigned j = 0; j < 16; j++) {
			if (i + j < len)
				printf("%02x ", p[i + j]);
			else
				printf("   ");
		}
		printf(" |");
		for (unsigned j = 0; j < 16 && i + j < len; j++) {
			uint8_t c = p[i + j];
			putchar((c >= 32 && c < 127) ? c : '.');
		}
		printf("|\n");
	}
}

static int show_frame(long got)
{
	if (got < 4) {
		fprintf(stderr, "short transfer: %ld bytes (expected at least the "
				"4-byte metadata word)\n", got);
		return 1;
	}

	uint32_t meta = *(volatile uint32_t *)buf;
	unsigned len  = META_LEN(meta);

	printf("frame #%u  type=0x%x seq=%u  payload=%u bytes\n",
	       META_COUNT(meta), META_TYPE(meta), META_SEQ(meta), len);

	/* The DMA stops on TLAST, so the byte count is the metadata word plus
	 * the payload rounded up to a whole word. A mismatch means the PL and
	 * this program disagree about the format. */
	unsigned expect = 4 + ((len + 3) & ~3u);
	if ((unsigned)got != expect)
		fprintf(stderr, "  warning: got %ld bytes, metadata implies %u\n",
			got, expect);

	if (len)
		hexdump(buf + 4, len);
	return 0;
}

static void dump(void)
{
	uint32_t id = rd(REG_ID), st = rd(REG_STATUS), md = rd(REG_MODE);

	printf("id          0x%08x %s\n", id,
	       id == ID_MAGIC ? "(ok)" : "(UNEXPECTED - wrong bitstream?)");
	/* Printed right after the ID because it qualifies every line below it:
	 * a dirty build means these registers may not be the ones in this
	 * source tree. */
	uint32_t bid = rd(REG_BUILD_ID);
	printf("build       %08x %s\n", bid,
	       (st & STAT_BUILD_DIRTY) ? "(DIRTY - built with uncommitted changes)"
	                               : "(clean)");
	printf("control     0x%08x\n", rd(REG_CONTROL));
	printf("mode        0x%08x  role=%s\n", md, (md & MODE_ROLE) ? "TX" : "RX");
	printf("status      0x%08x  tx_busy=%d pll_locked=%d in_frame=%d overflow=%d\n",
	       st, !!(st & STAT_TX_BUSY), !!(st & STAT_PLL_LOCKED),
	       !!(st & STAT_FRAME_VALID), !!(st & STAT_OVERFLOW));
	printf("tx_len      %u\n",   rd(REG_TX_LEN));
	printf("rx_len      %u\n",   rd(REG_RX_LEN));
	printf("frames      %u\n",   rd(REG_FRAME_COUNT));
	printf("errors      %u\n",   rd(REG_ERR_COUNT));

	/* Lock quality. syncs is the graded step between "nothing works" and "a
	 * frame arrived" - each sync means 16 consecutive symbols were right.
	 * The ratio approaches 1.0 for a clean QPSK constellation; it is
	 * scale-free, so it tracks lock quality rather than signal level. */
	uint32_t qmin = rd(REG_QUAL_MIN), qmax = rd(REG_QUAL_MAX);
	printf("syncs       %u\n",   rd(REG_SYNC_COUNT));
	printf("quality     ");
	if (qmax)
		printf("%.3f over %u symbols%s\n",
		       (double)qmin / (double)qmax, rd(REG_QUAL_SYMS),
		       ((double)qmin / (double)qmax) < 0.70 ? "  (POOR LOCK)" : "");
	else
		printf("no symbols measured\n");
}

static void usage(const char *p)
{
	fprintf(stderr,
		"usage: %s <command>\n"
		"\n"
		"  dump                  show every register, decoded\n"
		"  read  <reg>           read one register\n"
		"  write <reg> <value>   write one register (hex or decimal)\n"
		"\n"
		"  role  tx|rx           select transmit or receive\n"
		"  enable | disable      set/clear CONTROL.enable\n"
		"  listen                enable receive path\n"
		"  transmit [len]        pulse tx_start, optionally setting tx_len first\n"
		"  clrstats              pulse clr_stats\n"
		"\n"
		"  rx [timeout_ms]       arm the DMA, wait for one frame, print it\n"
		"                        (default timeout 5000 ms)\n"
		"  rxloop [timeout_ms]   same, repeating until interrupted\n"
		"\n"
		"registers: ", p);
	for (size_t i = 0; i < sizeof(regs) / sizeof(regs[0]); i++)
		fprintf(stderr, "%s%s", i ? ", " : "", regs[i].name);
	fprintf(stderr, "\n");
}

/* Maps the DMA control window and the reserved buffer. Only the rx commands
 * need these, so failure is not fatal to the register commands. */
static int map_datapath(void)
{
	int idx = uio_find(DMA_PHYS, NULL, NULL);
	if (idx < 0) {
		fprintf(stderr, "no UIO device at 0x%08lx (the AXI DMA)\n", DMA_PHYS);
		return -1;
	}
	dma = uio_map(idx, DMA_MAP_SIZE, NULL);
	if (dma == MAP_FAILED)
		return -1;

	idx = uio_find(0, &buf_phys, &buf_size);
	if (idx < 0) {
		fprintf(stderr, "no reserved DMA buffer found in /sys/class/uio\n");
		return -1;
	}
	buf = uio_map(idx, buf_size, NULL);
	if (buf == MAP_FAILED)
		return -1;

	return 0;
}

int main(int argc, char **argv)
{
	int argi = 1;

	if (argi >= argc) {
		usage(argv[0]);
		return 1;
	}

	int idx = uio_find(REGS_PHYS, NULL, NULL);
	if (idx < 0) {
		fprintf(stderr, "no UIO device at 0x%08lx (the PL register block)\n",
			REGS_PHYS);
		fprintf(stderr,
			"hint: no /dev/uio* usually means the kernel wasn't told which\n"
			"      compatible to bind - check for uio_pdrv_genirq.of_id=generic-uio\n"
			"      in /proc/cmdline\n");
		return 1;
	}

	base = uio_map(idx, REG_MAP_SIZE, NULL);
	if (base == MAP_FAILED)
		return 1;

	const char *cmd = argv[argi];
	int rc = 0;

	if (!strcmp(cmd, "dump")) {
		/*
		 * Registers only. dump() used to call map_datapath() as well,
		 * purely to print the DMA buffer address - but that mapped the
		 * DMA control window and a 16 MB region for no other reason,
		 * which turned the one command you reach for when something is
		 * already wrong into the one most likely to make it worse.
		 *
		 * Anything that maps the datapath can hang the CPU outright if
		 * the PL is unprogrammed or unclocked: a Zynq-7000 AXI master
		 * has no transaction timeout, so a read that is never answered
		 * locks the core with no oops and no console. Diagnostics must
		 * touch the least hardware possible. Use "dmainfo" for the
		 * buffer details.
		 */
		dump();

	} else if (!strcmp(cmd, "read") && argi + 1 < argc) {
		int i = lookup(argv[argi + 1]);
		if (i < 0) {
			fprintf(stderr, "unknown register: %s\n", argv[argi + 1]);
			rc = 1;
		} else {
			printf("0x%08x\n", rd(regs[i].idx));
		}

	} else if (!strcmp(cmd, "write") && argi + 2 < argc) {
		int i = lookup(argv[argi + 1]);
		if (i < 0) {
			fprintf(stderr, "unknown register: %s\n", argv[argi + 1]);
			rc = 1;
		} else if (!regs[i].writable) {
			fprintf(stderr, "%s is read-only\n", regs[i].name);
			rc = 1;
		} else {
			wr(regs[i].idx, (uint32_t)strtoul(argv[argi + 2], NULL, 0));
		}

	} else if (!strcmp(cmd, "role") && argi + 1 < argc) {
		uint32_t m = rd(REG_MODE);
		if (!strcmp(argv[argi + 1], "tx"))
			m |= MODE_ROLE;
		else if (!strcmp(argv[argi + 1], "rx"))
			m &= ~MODE_ROLE;
		else {
			fprintf(stderr, "role must be tx or rx\n");
			rc = 1;
		}
		if (!rc)
			wr(REG_MODE, m);

	} else if (!strcmp(cmd, "enable")) {
		wr(REG_CONTROL, rd(REG_CONTROL) | CTRL_ENABLE);

	} else if (!strcmp(cmd, "disable")) {
		wr(REG_CONTROL, rd(REG_CONTROL) & ~CTRL_ENABLE);

	} else if (!strcmp(cmd, "listen")) {
		wr(REG_CONTROL, rd(REG_CONTROL) | CTRL_ENABLE | CTRL_RX_ENABLE);

	} else if (!strcmp(cmd, "transmit")) {
		if (argi + 1 < argc)
			wr(REG_TX_LEN, (uint32_t)strtoul(argv[argi + 1], NULL, 0));
		/* tx_start self-clears in PL, so this is a pulse not a latch */
		wr(REG_CONTROL, rd(REG_CONTROL) | CTRL_ENABLE | CTRL_TX_START);

	} else if (!strcmp(cmd, "clrstats")) {
		wr(REG_CONTROL, rd(REG_CONTROL) | CTRL_CLR_STATS);

	} else if (!strcmp(cmd, "dmainfo")) {
		/* Explicitly opt in to touching the datapath. */
		if (map_datapath() < 0) {
			rc = 1;
		} else {
			printf("dma regs    0x%08lx\n", DMA_PHYS);
			printf("dma buffer  0x%08lx (%lu KiB)\n",
			       buf_phys, buf_size / 1024);
			printf("S2MM_DMASR  0x%08x\n", dma_rd(S2MM_DMASR));
		}

	} else if (!strcmp(cmd, "rx") || !strcmp(cmd, "rxloop")) {
		int loop = !strcmp(cmd, "rxloop");
		int timeout = (argi + 1 < argc)
			      ? atoi(argv[argi + 1]) : 5000;

		if (map_datapath() < 0) {
			rc = 1;
		} else {
			/* Arm the receive path before the DMA, or a frame that
			 * lands between the two is dropped and flagged as an
			 * overflow rather than captured. */
			wr(REG_CONTROL, rd(REG_CONTROL) | CTRL_ENABLE | CTRL_RX_ENABLE);

			do {
				long got = rx_one(timeout);
				if (got == -2) {
					fprintf(stderr, "timeout after %d ms, no frame\n",
						timeout);
					if (!loop) { rc = 1; break; }
				} else if (got < 0) {
					rc = 1;
					break;
				} else {
					rc = show_frame(got);
				}
			} while (loop);
		}

	} else {
		usage(argv[0]);
		rc = 1;
	}

	return rc;
}
