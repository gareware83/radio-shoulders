/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * The PL register map, as seen from userspace.
 *
 * hdl/pkg.vhd is authoritative. This header and the table in radioctl.c are
 * both mirrors of it and are kept in sync by hand - extending the map means
 * editing pkg.vhd, reg_rw_interface.vhd, radioctl.c AND this file, and
 * bumping the low half of C_ID_MAGIC so an old bitstream paired with new
 * tools is caught by the id check instead of returning plausible nonsense.
 */
#ifndef RADIO_REGS_H
#define RADIO_REGS_H

#define REGS_PHYS    0x43c00000UL
#define DMA_PHYS     0x80400000UL
#define REG_MAP_SIZE 0x10000UL

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
};

#define CTRL_ENABLE      (1u << 0)
#define CTRL_TX_START    (1u << 1)
#define CTRL_RX_ENABLE   (1u << 2)
#define CTRL_CLR_STATS   (1u << 3)
#define CTRL_CAPTURE_ARM (1u << 4)   /* write-one pulse, self-clearing */

#define MODE_ROLE              (1u << 0)
#define MODE_CAPTURE_TAP_SHIFT 8
#define MODE_CAPTURE_TAP_MASK  (0x3u << MODE_CAPTURE_TAP_SHIFT)

/* C_TAP_* in hdl/pkg.vhd - which RX chain stage the sniffer captures from */
enum {
	TAP_DDC      = 0,   /* post-DDC, pre-PLL */
	TAP_PLL      = 1,   /* post-PLL, matched filter's input */
	TAP_FILTERED = 2,   /* post matched filter */
	TAP_SYM      = 3,   /* post-Gardner, slicer's input */
};

#define STAT_TX_BUSY      (1u << 0)
#define STAT_PLL_LOCKED   (1u << 1)
#define STAT_FRAME_VALID  (1u << 2)
#define STAT_OVERFLOW     (1u << 3)
#define STAT_BUILD_DIRTY  (1u << 4)
#define STAT_CAPTURE_DONE (1u << 5)

/* Bumped 0x0001 -> 0x0002 for the sample-capture register/address-map
 * additions - see the comment on C_ID_MAGIC in hdl/pkg.vhd. */
#define ID_MAGIC 0x5A790002u

/* Diagnostic sample capture region: a second, much larger address range in
 * the same 64K AXI4-Lite window, backed by sample_sniffer's BRAM rather than
 * the control/status flop file - see pkg.vhd's "Diagnostic sample capture"
 * section for the full picture. One 32-bit word per I/Q pair, I in the low
 * half, Q in the high half (matches the DMA payload convention).
 */
#define CAPTURE_BASE_WORD 256
#define CAPTURE_DEPTH     1024

static inline int16_t capture_word_i(uint32_t w) { return (int16_t)(w & 0xffffu); }
static inline int16_t capture_word_q(uint32_t w) { return (int16_t)(w >> 16); }

#endif /* RADIO_REGS_H */
