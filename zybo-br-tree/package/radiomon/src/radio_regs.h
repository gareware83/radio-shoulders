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

#define CTRL_ENABLE     (1u << 0)
#define CTRL_TX_START   (1u << 1)
#define CTRL_RX_ENABLE  (1u << 2)
#define CTRL_CLR_STATS  (1u << 3)

#define MODE_ROLE       (1u << 0)

#define STAT_TX_BUSY     (1u << 0)
#define STAT_PLL_LOCKED  (1u << 1)
#define STAT_FRAME_VALID (1u << 2)
#define STAT_OVERFLOW    (1u << 3)
#define STAT_BUILD_DIRTY (1u << 4)

#define ID_MAGIC 0x5A790001u

#endif /* RADIO_REGS_H */
