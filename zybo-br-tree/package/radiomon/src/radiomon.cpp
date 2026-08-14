// SPDX-License-Identifier: GPL-2.0-or-later
//
// radiomon - watch the comms DSP receiver's registers live, in the terminal.
//
// The lock-quality metric (qmin/qmax) exists because frame count is a cliff,
// not a gradient: a search - or a person turning a knob - optimising "did a
// frame arrive" sees 0,0,0,0,4 and has no slope to follow. The ratio degrades
// smoothly with phase error, ISI and noise, and it is scale-free, so it tracks
// lock quality rather than signal level with no AGC in the chain. Watching it
// move while something is adjusted is the point of this program; a number
// printed once a second is much harder to read that way than a trace.
//
// SAFE TO LEAVE RUNNING. This maps the register window only, never the DMA
// control window or the sample buffer. Anything that touches the datapath can
// hard-lock the CPU if the PL is unprogrammed or unclocked - a Zynq-7000 AXI
// master has no transaction timeout, so a read that is never answered locks
// the core with no oops and no console. radioctl's dmainfo/rx/loopback are the
// commands that accept that risk; this one does not.

#include "plot_lib.hpp"

extern "C" {
#include "radio_regs.h"
}

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <deque>
#include <iostream>
#include <string>
#include <thread>

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

using namespace plot;

namespace {

volatile std::sig_atomic_t running = 1;

volatile uint32_t *regs = nullptr;

uint32_t rd(int idx) { return regs[idx]; }

// UIO discovery, matching radioctl: the /dev/uioN index depends on probe order
// with three UIO devices present, so the physical address in sysfs is what
// identifies the register window.
int uio_find(unsigned long want)
{
    for (int i = 0; i < 32; i++) {
        char path[128];
        std::snprintf(path, sizeof(path),
                      "/sys/class/uio/uio%d/maps/map0/addr", i);

        FILE *f = std::fopen(path, "r");
        if (!f)
            continue;

        unsigned long a = 0;
        int n = std::fscanf(f, "%lx", &a);
        std::fclose(f);

        if (n == 1 && a == want)
            return i;
    }
    return -1;
}

volatile uint32_t *map_regs()
{
    int idx = uio_find(REGS_PHYS);
    if (idx < 0) {
        std::fprintf(stderr,
                     "no UIO device at 0x%08lx (the PL register block)\n"
                     "hint: no /dev/uio* usually means the kernel wasn't told which\n"
                     "      compatible to bind - check for uio_pdrv_genirq.of_id=generic-uio\n"
                     "      in /proc/cmdline\n",
                     REGS_PHYS);
        return nullptr;
    }

    char dev[32];
    std::snprintf(dev, sizeof(dev), "/dev/uio%d", idx);

    int fd = ::open(dev, O_RDWR | O_SYNC);
    if (fd < 0) {
        std::fprintf(stderr, "open %s: %s\n", dev, std::strerror(errno));
        return nullptr;
    }

    void *p = ::mmap(nullptr, REG_MAP_SIZE, PROT_READ | PROT_WRITE,
                     MAP_SHARED, fd, 0);
    ::close(fd);   // the mapping survives the descriptor

    if (p == MAP_FAILED) {
        std::fprintf(stderr, "mmap %s: %s\n", dev, std::strerror(errno));
        return nullptr;
    }
    return static_cast<volatile uint32_t *>(p);
}

// One sample of everything that moves.
struct Sample {
    uint32_t status, frames, errors, syncs, rx_len;
    uint32_t qmin, qmax, qsyms;
};

Sample read_all()
{
    Sample s;
    s.status = rd(REG_STATUS);
    s.frames = rd(REG_FRAME_COUNT);
    s.errors = rd(REG_ERR_COUNT);
    s.syncs  = rd(REG_SYNC_COUNT);
    s.rx_len = rd(REG_RX_LEN);
    s.qmin   = rd(REG_QUAL_MIN);
    s.qmax   = rd(REG_QUAL_MAX);
    s.qsyms  = rd(REG_QUAL_SYMS);
    return s;
}

// The quality registers are free-running accumulators since the last
// clrstats, so qmin/qmax straight off the hardware is a CUMULATIVE average -
// it converges and then barely moves, which is exactly wrong for watching the
// effect of a change. The interval ratio is what responds: the difference in
// both accumulators since the previous poll.
//
// Returns -1 when the interval carried no symbols (nothing received) and falls
// back to the cumulative value when the counters have just been cleared.
float interval_quality(const Sample &now, const Sample &prev)
{
    if (now.qsyms < prev.qsyms || now.qmax < prev.qmax) {
        // Counters went backwards: clrstats, or the PL was reset under us.
        return now.qmax ? float(now.qmin) / float(now.qmax) : -1.0f;
    }

    uint32_t dmax = now.qmax - prev.qmax;
    uint32_t dmin = now.qmin - prev.qmin;

    if (dmax == 0)
        return -1.0f;

    return float(dmin) / float(dmax);
}

void usage(const char *p)
{
    std::fprintf(stderr,
                 "usage: %s [options]\n"
                 "\n"
                 "  --interval <ms>   poll period (default 250)\n"
                 "  --width <cols>    plot width in characters (default 60)\n"
                 "  --height <rows>   plot height in rows (default 10)\n"
                 "  --window <n>      samples held in the trace (default 200)\n"
                 "\n"
                 "Reads the register window only; never touches the DMA.\n",
                 p);
}

} // namespace

int main(int argc, char **argv)
{
    int interval_ms = 250, width = 60, height = 10, window = 200;

    for (int i = 1; i < argc; i++) {
        bool has_val = i + 1 < argc;

        if (!std::strcmp(argv[i], "--interval") && has_val)
            interval_ms = std::atoi(argv[++i]);
        else if (!std::strcmp(argv[i], "--width") && has_val)
            width = std::atoi(argv[++i]);
        else if (!std::strcmp(argv[i], "--height") && has_val)
            height = std::atoi(argv[++i]);
        else if (!std::strcmp(argv[i], "--window") && has_val)
            window = std::atoi(argv[++i]);
        else {
            usage(argv[0]);
            return 1;
        }
    }

    if (interval_ms < 10 || width < 10 || height < 2 || window < 2) {
        std::fprintf(stderr, "implausible option value\n");
        return 1;
    }

    std::signal(SIGINT, [](int) { running = 0; });

    regs = map_regs();
    if (!regs)
        return 1;

    uint32_t id = rd(REG_ID);
    if (id != ID_MAGIC) {
        // Not fatal - a wrong id still reads, and seeing what it is beats
        // being told nothing. But nothing below it can be trusted.
        std::fprintf(stderr, "warning: id reads 0x%08x, expected 0x%08x - "
                             "wrong or unloaded bitstream?\n", id, ID_MAGIC);
    }

    TerminalInfo term;
    term.detect();

    // y runs 0..1: the ratio is bounded, and a fixed scale means the trace
    // means the same thing from one run to the next. An autoscaled axis would
    // make a flat bad lock look identical to a flat good one.
    RealCanvas<BrailleCanvas> canvas({{0.0f, 1.0f}, {1.0f, 0.0f}},
                                     Size(width, height), term);
    auto layout = margin(frame("lock quality  min/max, 0..1", &canvas, term));

    std::deque<float> trace;
    Sample prev = read_all();
    bool first = true;

    while (running) {
        std::this_thread::sleep_for(std::chrono::milliseconds(interval_ms));
        if (!running)
            break;

        Sample now = read_all();
        float q = interval_quality(now, prev);
        prev = now;

        // A gap in reception is real information, so it is held at the last
        // value rather than drawn as zero - zero would read as "locked badly"
        // when the truth is "nothing arrived".
        trace.push_back(q >= 0.0f ? q : (trace.empty() ? 0.0f : trace.back()));
        while (int(trace.size()) > window)
            trace.pop_front();

        canvas.clear();

        // Reference lines: 1.0 is a clean constellation on the diagonal, 0.7
        // is the threshold radioctl already calls a poor lock.
        canvas.line(term.foreground_color, {0.0f, 0.70f}, {1.0f, 0.70f},
                    TerminalOp::ClipSrc);

        if (trace.size() > 1) {
            float dx = 1.0f / float(trace.size() - 1);
            for (std::size_t i = 1; i < trace.size(); i++) {
                canvas.line(palette::royalblue,
                            {float(i - 1) * dx, trace[i - 1]},
                            {float(i) * dx, trace[i]});
            }
        }

        if (!first)
            std::cout << term.move_up(layout.size().y + 4) << std::flush;
        first = false;

        for (auto const &line : layout)
            std::cout << term.clear_line() << line << '\n';

        char qtxt[32];
        if (q >= 0.0f)
            std::snprintf(qtxt, sizeof(qtxt), "%.3f%s", q,
                          q < 0.70f ? " POOR" : "");
        else
            std::snprintf(qtxt, sizeof(qtxt), "  -  ");

        std::cout << term.clear_line()
                  << "  quality " << qtxt
                  << "   symbols " << now.qsyms << '\n'
                  << term.clear_line()
                  << "  frames  " << now.frames
                  << "   errors " << now.errors
                  << "   syncs " << now.syncs
                  << "   rx_len " << now.rx_len << '\n'
                  << term.clear_line()
                  << "  status  0x" << std::hex << now.status << std::dec
                  << (now.status & STAT_FRAME_VALID ? "  in-frame" : "")
                  << (now.status & STAT_OVERFLOW    ? "  OVERFLOW" : "")
                  << (now.status & STAT_PLL_LOCKED  ? "  pll-locked" : "")
                  << '\n'
                  << term.clear_line()
                  << "  ctrl-C to stop\n"
                  << std::flush;
    }

    std::cout << std::endl;
    return 0;
}
