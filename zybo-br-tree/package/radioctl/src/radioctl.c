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
 *
 * MM2S is DDR -> PL, the stimulus playback direction used by "loopback".
 * Note the soft reset in either DMACR resets the WHOLE engine, both channels,
 * so it can only be used between passes and never to re-arm one direction
 * while the other is mid-transfer.
 */
#define MM2S_DMACR   0x00
#define MM2S_DMASR   0x04
#define MM2S_SA      0x18
#define MM2S_LENGTH  0x28

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
 * Arms an S2MM transfer. Simple mode: destination address, then length, and
 * writing the length is what starts it. The PL terminates the transfer early
 * with TLAST at the end of a frame, and S2MM_LENGTH then reads back the
 * actual byte count.
 */
static void s2mm_arm(unsigned long dst_phys, uint32_t capacity)
{
	dma_wr(S2MM_DA, (uint32_t)dst_phys);
	dma_wr(S2MM_DMACR, DMACR_RS);
	dma_wr(S2MM_LENGTH, capacity);
}

/* Waits for the armed S2MM transfer. Bytes received, -1 error, -2 timeout. */
static long s2mm_wait(int timeout_ms)
{
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

static long rx_one(int timeout_ms)
{
	if (dma_reset() < 0)
		return -1;

	/* Cap at the buffer size; a frame is far smaller and TLAST ends it. */
	uint32_t want = buf_size > 0x400000 ? 0x400000 : (uint32_t)buf_size;
	s2mm_arm(buf_phys, want);

	return s2mm_wait(timeout_ms);
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

/* ------------------------------------------------------------------ */
/* Loopback: play a stimulus file into the RX chain and check what      */
/* comes back                                                           */
/*                                                                      */
/* The reserved buffer is split in half: the low half holds the sample   */
/* stream MM2S plays out, the high half receives the frames S2MM writes  */
/* back. One region would work only until a capture overran into the     */
/* samples still being played.                                           */
/* ------------------------------------------------------------------ */

#define TX_REGION_OFF 0UL
#define RX_REGION_OFF (buf_size / 2)

static int map_datapath(void);

struct chunk {
	unsigned long first;   /* first sample index */
	unsigned long count;   /* samples */
};

struct beat {
	uint32_t data;
	unsigned keep;
	int      last;
};

/*
 * Loads a ddc_input.dat-style file - one decimal sample per line - into the
 * playback half of the buffer, one 32-bit word per sample.
 *
 * The PL takes mm2s_tdata(15 downto 0) as a signed sample and ignores the
 * upper half (system_top.vhd), so only the low 16 bits carry meaning; the
 * value is written sign-extended purely so a hexdump of the buffer reads the
 * way the file does. Anything outside int16 is a generator bug that would
 * otherwise truncate silently, so it is reported rather than masked.
 */
static long load_stimulus(const char *path)
{
	FILE *f = fopen(path, "r");
	if (!f) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return -1;
	}

	volatile uint32_t *w = (volatile uint32_t *)(buf + TX_REGION_OFF);
	unsigned long cap = (buf_size / 2) / 4;
	unsigned long n = 0;
	int clipped = 0;
	char line[64];

	while (fgets(line, sizeof(line), f)) {
		char *end;
		long v = strtol(line, &end, 10);

		if (end == line)
			continue;   /* blank line or comment */

		if (n >= cap) {
			fprintf(stderr, "%s: more than %lu samples, does not fit "
					"the playback region\n", path, cap);
			fclose(f);
			return -1;
		}
		if (v > 32767 || v < -32768)
			clipped++;

		w[n++] = (uint32_t)(int32_t)v;
	}
	fclose(f);

	if (clipped)
		fprintf(stderr, "warning: %d sample(s) outside 16-bit range - the PL "
				"sees only bits 15:0\n", clipped);
	if (!n) {
		fprintf(stderr, "%s: no samples read\n", path);
		return -1;
	}
	return (long)n;
}

/*
 * Loads the playback chunk list written by waveform_generator.py's
 * save_chunks(): "<first sample> <count>", one line per frame.
 *
 * Without it the whole stimulus goes out as one transfer, which captures the
 * first frame and drops the rest - rx_frame_buffer holds a single frame and
 * backpressures, and userspace cannot re-arm S2MM inside a 3 us inter-frame
 * gap. One transfer per frame makes that structurally impossible instead of
 * relying on timing.
 */
static int load_chunks(const char *path, struct chunk **out, unsigned long n_samples)
{
	FILE *f = fopen(path, "r");
	if (!f) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return -1;
	}

	int cap = 16, n = 0;
	struct chunk *c = malloc(cap * sizeof(*c));
	char line[128];

	while (c && fgets(line, sizeof(line), f)) {
		unsigned long first, count;

		if (line[0] == '#')
			continue;
		if (sscanf(line, "%lu %lu", &first, &count) != 2)
			continue;

		if (first + count > n_samples) {
			fprintf(stderr, "chunk %d (%lu+%lu) runs past the %lu samples "
					"loaded - stimulus and chunk file disagree\n",
				n + 1, first, count, n_samples);
			free(c);
			fclose(f);
			return -1;
		}
		if (n == cap) {
			cap *= 2;
			struct chunk *bigger = realloc(c, cap * sizeof(*c));
			if (!bigger) { free(c); c = NULL; break; }
			c = bigger;
		}
		c[n].first = first;
		c[n].count = count;
		n++;
	}
	fclose(f);

	if (!c) {
		fprintf(stderr, "out of memory reading %s\n", path);
		return -1;
	}
	if (!n) {
		fprintf(stderr, "%s: no chunks found\n", path);
		free(c);
		return -1;
	}
	*out = c;
	return n;
}

/*
 * Loads rx_expected_stream.dat: the exact AXI-Stream beats rx_frame_buffer
 * should emit, "<data hex8> <keep hex1> <last 0|1>" per line. Frames are
 * delimited by last=1.
 *
 * This is the check that means anything. Frame count plus CRC only proves the
 * receiver decoded something self-consistent - a frame carrying the wrong
 * bytes passes CRC every time.
 */
static int load_expected(const char *path, struct beat **out)
{
	FILE *f = fopen(path, "r");
	if (!f) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return -1;
	}

	int cap = 64, n = 0;
	struct beat *b = malloc(cap * sizeof(*b));
	char line[128];

	while (b && fgets(line, sizeof(line), f)) {
		unsigned data, keep, last;

		if (line[0] == '#')
			continue;
		if (sscanf(line, "%x %x %u", &data, &keep, &last) != 3)
			continue;

		if (n == cap) {
			cap *= 2;
			struct beat *bigger = realloc(b, cap * sizeof(*b));
			if (!bigger) { free(b); b = NULL; break; }
			b = bigger;
		}
		b[n].data = data;
		b[n].keep = keep;
		b[n].last = last != 0;
		n++;
	}
	fclose(f);

	if (!b) {
		fprintf(stderr, "out of memory reading %s\n", path);
		return -1;
	}
	*out = b;
	return n;
}

static unsigned keep_bytes(unsigned keep)
{
	unsigned n = 0;
	for (unsigned i = 0; i < 4; i++)
		if (keep & (1u << i))
			n++;
	return n;
}

/*
 * Compares one captured frame against its expected beats. Returns 0 on a
 * match.
 *
 * The metadata word is compared on its low 16 bits only - length, type and
 * sequence. Bits 31:16 are the PL's running frame counter, which tracks
 * frames that PASSED CRC; one earlier frame failing shifts it for every frame
 * after, turning one fault into a cascade of misleading failures. It is
 * reported instead.
 */
static int check_frame(const volatile uint8_t *p, long got,
		       const struct beat *b, int nb, int frame_no)
{
	unsigned exact = 4 * (nb - 1) + keep_bytes(b[nb - 1].keep);
	unsigned padded = 4 * nb;
	int bad = 0;

	/* Whether the DMA writes a partial final beat as its kept bytes or pads
	 * to a whole word is a property of the IP rather than of this design, so
	 * both are accepted. They are identical whenever the payload is a
	 * multiple of 4 bytes, which is the case for every frame the generator
	 * currently emits. */
	if ((unsigned)got != exact && (unsigned)got != padded) {
		printf("    byte count %ld, expected %u\n", got, exact);
		bad++;
	}

	for (int i = 0; i < nb; i++) {
		if ((long)(4 * i + 4) > got) {
			printf("    beat %d missing (transfer ended early)\n", i);
			bad++;
			break;
		}

		uint32_t v = *(volatile uint32_t *)(p + 4 * i);
		uint32_t want = b[i].data;
		uint32_t mask = 0;

		for (unsigned k = 0; k < 4; k++)
			if (b[i].keep & (1u << k))
				mask |= 0xffu << (8 * k);

		if (i == 0) {
			if ((v & 0xffffu) != (want & 0xffffu)) {
				printf("    meta: len/type/seq 0x%04x, expected 0x%04x\n",
				       v & 0xffffu, want & 0xffffu);
				bad++;
			}
			if ((v >> 16) != (want >> 16))
				printf("    note: PL frame counter %u, expected %u "
				       "(an earlier frame failed CRC)\n",
				       v >> 16, want >> 16);
			continue;
		}

		if ((v & mask) != (want & mask)) {
			printf("    beat %d: 0x%08x, expected 0x%08x\n", i, v, want);
			bad++;
		}
	}

	if (!bad)
		printf("    frame %d OK\n", frame_no);
	return bad;
}

static void mm2s_play(unsigned long src_phys, uint32_t bytes)
{
	dma_wr(MM2S_SA, (uint32_t)src_phys);
	dma_wr(MM2S_DMACR, DMACR_RS);
	dma_wr(MM2S_LENGTH, bytes);   /* writing the length starts it */
}

static int cmd_loopback(const char *stim, const char *chunkf, const char *expectf,
			const char *outf, int timeout_ms)
{
	struct chunk *chunks = NULL, one;
	struct beat *beats = NULL;
	int n_chunks, n_beats = 0;
	FILE *out = NULL;
	int rc = 0;

	if (map_datapath() < 0)
		return 1;

	long n_samples = load_stimulus(stim);
	if (n_samples < 0)
		return 1;
	printf("stimulus    %ld samples from %s\n", n_samples, stim);

	if (chunkf) {
		n_chunks = load_chunks(chunkf, &chunks, (unsigned long)n_samples);
		if (n_chunks < 0)
			return 1;
		printf("chunks      %d, from %s\n", n_chunks, chunkf);
	} else {
		/* Everything in one transfer. Legitimate for a single-frame
		 * stimulus and useless for a multi-frame one, so say so. */
		one.first = 0;
		one.count = (unsigned long)n_samples;
		chunks = &one;
		n_chunks = 1;
		printf("chunks      none given - playing the whole file as one "
		       "transfer\n            (only the first frame can be "
		       "captured; see --chunks)\n");
	}

	if (expectf) {
		n_beats = load_expected(expectf, &beats);
		if (n_beats < 0) {
			rc = 1;
			goto done;
		}
		printf("expected    %d stream beats from %s\n", n_beats, expectf);
	}

	if (outf) {
		out = fopen(outf, "wb");
		if (!out) {
			fprintf(stderr, "open %s: %s\n", outf, strerror(errno));
			rc = 1;
			goto done;
		}
	}

	unsigned long tx_phys = buf_phys + TX_REGION_OFF;
	unsigned long rx_phys = buf_phys + RX_REGION_OFF;
	uint32_t rx_cap = (buf_size / 2) > 0x100000 ? 0x100000
						    : (uint32_t)(buf_size / 2);

	printf("buffer      play 0x%08lx, capture 0x%08lx\n", tx_phys, rx_phys);

	/* Counters describe this run only. */
	wr(REG_CONTROL, rd(REG_CONTROL) | CTRL_CLR_STATS);

	/* Arm the receiver before any DMA: a frame landing between the two is
	 * dropped and flagged as an overflow rather than captured. */
	wr(REG_CONTROL, rd(REG_CONTROL) | CTRL_ENABLE | CTRL_RX_ENABLE);

	if (dma_reset() < 0) {
		rc = 1;
		goto done;
	}

	int beat_i = 0, captured = 0, failed = 0, missed = 0;

	for (int c = 0; c < n_chunks; c++) {
		printf("\nchunk %d: samples %lu..%lu\n", c + 1, chunks[c].first,
		       chunks[c].first + chunks[c].count - 1);

		/* Capture first, then play - the other order races the frame. */
		s2mm_arm(rx_phys, rx_cap);
		mm2s_play(tx_phys + chunks[c].first * 4,
			  (uint32_t)(chunks[c].count * 4));

		long got = s2mm_wait(timeout_ms);

		if (got == -2) {
			printf("    no frame within %d ms\n", timeout_ms);
			missed++;
			/* The transfer is still outstanding; it has to be
			 * cleared before the next chunk can arm one. Reset is
			 * global, so the idle MM2S goes with it - harmless
			 * here, since its transfer has already drained. */
			if (dma_reset() < 0) {
				rc = 1;
				break;
			}
		} else if (got < 0) {
			rc = 1;
			break;
		} else {
			captured++;

			uint32_t mm_sr = dma_rd(MM2S_DMASR);
			if (mm_sr & DMASR_ERRORS)
				printf("    warning: MM2S_DMASR=0x%08x (playback "
				       "error)\n", mm_sr);

			const volatile uint8_t *p = buf + RX_REGION_OFF;
			uint32_t meta = *(volatile uint32_t *)p;

			printf("    got %ld bytes: len=%u type=0x%x seq=%u "
			       "(PL frame %u)\n", got, META_LEN(meta),
			       META_TYPE(meta), META_SEQ(meta), META_COUNT(meta));

			if (out && fwrite((const void *)p, 1, (size_t)got, out) != (size_t)got) {
				fprintf(stderr, "write %s: %s\n", outf, strerror(errno));
				rc = 1;
				break;
			}

			if (beats) {
				/* Walk to the end of this frame's beats. */
				int start = beat_i;
				while (beat_i < n_beats && !beats[beat_i].last)
					beat_i++;
				if (beat_i < n_beats)
					beat_i++;   /* include the last beat */

				int nb = beat_i - start;
				if (nb <= 0)
					printf("    no expected frame left to "
					       "compare against\n");
				else if (check_frame(p, got, &beats[start], nb, c + 1))
					failed++;
			}
		}
	}

	uint32_t qmin = rd(REG_QUAL_MIN), qmax = rd(REG_QUAL_MAX);
	uint32_t st = rd(REG_STATUS);

	printf("\n--- result ---\n");
	printf("captured    %d of %d chunks", captured, n_chunks);
	if (missed)
		printf(", %d timed out", missed);
	printf("\n");
	if (beats)
		printf("bit-truth   %d frame(s) mismatched\n", failed);
	printf("frames      %u passed CRC\n", rd(REG_FRAME_COUNT));
	printf("errors      %u failed CRC\n", rd(REG_ERR_COUNT));
	printf("syncs       %u sync-word detections\n", rd(REG_SYNC_COUNT));
	if (qmax)
		printf("quality     %.3f over %u symbols%s\n",
		       (double)qmin / (double)qmax, rd(REG_QUAL_SYMS),
		       ((double)qmin / (double)qmax) < 0.70 ? "  (POOR LOCK)" : "");
	if (st & STAT_OVERFLOW)
		printf("overflow    set - a frame was dropped while the buffer "
		       "was draining\n");

	/* A run that captured everything but was never bit-checked has not
	 * proved anything about content, so it is not called a pass. */
	if (rc == 0 && (missed || failed || captured != n_chunks))
		rc = 1;

done:
	if (out)
		fclose(out);
	if (chunks != &one)
		free(chunks);
	free(beats);
	return rc;
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
		"  loopback <samples.dat> [options]\n"
		"                        play a sample file through the RX chain and\n"
		"                        check the frames that come back\n"
		"    --chunks <file>     one playback transfer per frame\n"
		"                        (rx_chunks.txt; without it only the first\n"
		"                         frame of a multi-frame file is captured)\n"
		"    --expect <file>     rx_expected_stream.dat, for the bit-truth check\n"
		"    --out <file>        write captured frames here, metadata included\n"
		"    --timeout <ms>      per-frame capture timeout (default 2000)\n"
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

	} else if (!strcmp(cmd, "loopback") && argi + 1 < argc) {
		const char *stim = argv[argi + 1];
		const char *chunkf = NULL, *expectf = NULL, *outf = NULL;
		int timeout = 2000;

		for (int a = argi + 2; a < argc; a++) {
			int has_val = a + 1 < argc;

			if (!strcmp(argv[a], "--chunks") && has_val)
				chunkf = argv[++a];
			else if (!strcmp(argv[a], "--expect") && has_val)
				expectf = argv[++a];
			else if (!strcmp(argv[a], "--out") && has_val)
				outf = argv[++a];
			else if (!strcmp(argv[a], "--timeout") && has_val)
				timeout = atoi(argv[++a]);
			else {
				fprintf(stderr, "unknown or incomplete option: %s\n",
					argv[a]);
				usage(argv[0]);
				return 1;
			}
		}

		rc = cmd_loopback(stim, chunkf, expectf, outf, timeout);

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
