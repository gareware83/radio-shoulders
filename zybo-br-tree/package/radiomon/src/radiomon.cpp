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
//
// NO frame()/margin() ANYWHERE IN THIS FILE, ON PURPOSE. plot_lib.hpp's
// text-layout path calls into its own Unicode east-asian-width lookup
// (unicode_cp_in_tree, walking a self-referential static tree in
// unicode_data.hpp) for every character in a frame's title, including plain
// ASCII - there is no fast path that skips it. That tree segfaults on this
// build (g++ 11.4.0): confirmed against the pristine, un-repacked upstream
// source too, so it is not something introduced by packing this into a
// single header. Root cause not chased further - it is upstream's bug, not
// this file's - but every render path here works around it identically:
// print a plain std::cout header line, then stream the BrailleCanvas
// directly (it has its own operator<<, confirmed NOT to touch the
// frame/layout machinery at all). Same braille rendering, no border, no
// title-in-a-box - just no crash. Do not reintroduce frame()/margin() here
// without re-testing this exact crash first.

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
void     wr(int idx, uint32_t v) { regs[idx] = v; }

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

// -----------------------------------------------------------------------
// Diagnostic sample capture: one-shot, stage-selectable raw I/Q dump from
// the sniffer added in hdl/sample_sniffer.vhd. Read through the SAME
// register AXI4-Lite window read_all() already polls continuously above -
// the capture RAM is a second address region on that one bus (see
// C_CAPTURE_BASE_WORD in hdl/pkg.vhd), not the DMA. The "SAFE TO LEAVE
// RUNNING" claim at the top of this file still holds for --capture: it is
// the same bus, same risk profile, just a different offset and one extra
// AXI wait state.
// -----------------------------------------------------------------------

struct CapturePoint { int16_t i, q; };

int tap_from_name(const char *name)
{
    if (!std::strcmp(name, "ddc"))      return TAP_DDC;
    if (!std::strcmp(name, "pll"))      return TAP_PLL;
    if (!std::strcmp(name, "filtered")) return TAP_FILTERED;
    if (!std::strcmp(name, "sym"))      return TAP_SYM;
    return -1;
}

// Arms the sniffer, waits for STATUS.CAPTURE_DONE, and reads back every
// captured word. Returns an empty vector on timeout (reported to stderr,
// not fatal - the caller decides what an empty capture means).
//
// THE SNIFFER ONLY SEES SAMPLES WHILE SOMETHING ELSE IS DRIVING MM2S. This
// design has no free-running ADC - G_VALID_SRC = VALID_DMA means dsp_top
// only advances on an active DMA transfer's tvalid, so --capture has to run
// concurrently with a real source (radioctl loopback, or eventually live
// traffic), not on its own. A timeout with an otherwise-healthy board
// usually means exactly that: nothing was feeding MM2S when this ran.
std::vector<CapturePoint> run_capture(int tap, int timeout_ms)
{
    uint32_t mode = rd(REG_MODE);
    mode = (mode & ~MODE_CAPTURE_TAP_MASK) |
           ((uint32_t(tap) << MODE_CAPTURE_TAP_SHIFT) & MODE_CAPTURE_TAP_MASK);
    wr(REG_MODE, mode);

    // ENABLE alongside the arm pulse: harmless if already enabled, and
    // capturing on a receiver that was never enabled would be a confusing
    // way to get an empty result.
    wr(REG_CONTROL, rd(REG_CONTROL) | CTRL_ENABLE | CTRL_CAPTURE_ARM);

    auto deadline = std::chrono::steady_clock::now() +
                    std::chrono::milliseconds(timeout_ms);
    while (!(rd(REG_STATUS) & STAT_CAPTURE_DONE)) {
        if (std::chrono::steady_clock::now() > deadline) {
            std::fprintf(stderr,
                         "capture did not complete within %d ms.\n"
                         "Is something else actively driving MM2S right now "
                         "(radioctl loopback, a live receive)? The sniffer "
                         "only advances when real samples are flowing.\n",
                         timeout_ms);
            return {};
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    std::vector<CapturePoint> out;
    out.reserve(CAPTURE_DEPTH);
    for (int i = 0; i < CAPTURE_DEPTH; i++) {
        uint32_t w = rd(CAPTURE_BASE_WORD + i);
        out.push_back({capture_word_i(w), capture_word_q(w)});
    }
    return out;
}

// "<I> <Q>" per line, decimal - the same two-column convention
// waveform_generator.py's save_symbols_to_file() already uses, so a capture
// can be loaded straight into that Python tooling (as a complex array,
// I + 1j*Q) for spectral analysis of real hardware data, not just simulated
// stimulus. Unlike a stimulus .dat file this is post-DDC at every tap point
// (all four are downstream of ddc_fs_4), so downconvert_fs4=False is the
// right call there - the fs/4 removal already happened in hardware.
bool save_capture(const std::vector<CapturePoint> &pts, const char *path)
{
    FILE *f = std::fopen(path, "w");
    if (!f) {
        std::fprintf(stderr, "open %s: %s\n", path, std::strerror(errno));
        return false;
    }
    for (auto const &p : pts)
        std::fprintf(f, "%d %d\n", p.i, p.q);
    std::fclose(f);
    std::fprintf(stderr, "wrote %zu I/Q pairs to %s\n", pts.size(), path);
    return true;
}

// Constellation: I on x, Q on y, one dot per captured sample, no connecting
// lines - a locked QPSK signal should show four tight clusters near the
// corners; a spinning or noise-like carrier fills the whole disc instead
// (the same 0.41 min/max signature the quality ratio reports, seen directly
// rather than inferred from one number).
void plot_constellation(const std::vector<CapturePoint> &pts, int width, int height)
{
    TerminalInfo term;
    term.detect();

    RealCanvas<BrailleCanvas> canvas({{-1.0f, 1.0f}, {1.0f, -1.0f}},
                                     Size(width, height), term);

    canvas.line(term.foreground_color, {-1.0f, 0.0f}, {1.0f, 0.0f}, TerminalOp::ClipSrc);
    canvas.line(term.foreground_color, {0.0f, -1.0f}, {0.0f, 1.0f}, TerminalOp::ClipSrc);

    for (auto const &p : pts)
        canvas.dot(palette::royalblue, {float(p.i) / 32768.0f, float(p.q) / 32768.0f});

    std::cout << "constellation  I (x) / Q (y), normalized\n" << canvas << '\n';
}

// Time-domain: I and Q vs sample index, as two traces - shows transients,
// gaps and settling behaviour a single constellation snapshot cannot (e.g.
// the preamble-to-payload transition, or a loop still converging at the
// start of a capture).
void plot_waveform(const std::vector<CapturePoint> &pts, int width, int height)
{
    TerminalInfo term;
    term.detect();

    RealCanvas<BrailleCanvas> canvas({{0.0f, 1.0f}, {1.0f, -1.0f}},
                                     Size(width, height), term);

    canvas.line(term.foreground_color, {0.0f, 0.0f}, {1.0f, 0.0f}, TerminalOp::ClipSrc);

    if (pts.size() > 1) {
        float dx = 1.0f / float(pts.size() - 1);
        for (std::size_t k = 1; k < pts.size(); k++) {
            float x0 = float(k - 1) * dx, x1 = float(k) * dx;
            canvas.line(palette::royalblue,
                        {x0, float(pts[k - 1].i) / 32768.0f},
                        {x1, float(pts[k].i) / 32768.0f});
            canvas.line(palette::red,
                        {x0, float(pts[k - 1].q) / 32768.0f},
                        {x1, float(pts[k].q) / 32768.0f});
        }
    }

    std::cout << "I (blue) / Q (red) vs sample index, normalized\n" << canvas << '\n';
}

void usage(const char *p)
{
    std::fprintf(stderr,
                 "usage: %s [options]\n"
                 "       %s --capture <ddc|pll|filtered|sym> [options]\n"
                 "\n"
                 "live quality trend (default mode):\n"
                 "  --interval <ms>   poll period (default 250)\n"
                 "  --width <cols>    plot width in characters (default 60)\n"
                 "  --height <rows>   plot height in rows (default 10)\n"
                 "  --window <n>      samples held in the trace (default 200)\n"
                 "\n"
                 "one-shot raw sample capture:\n"
                 "  --capture <tap>   arm the sniffer at this RX chain stage,\n"
                 "                    wait for it to fill, then display it.\n"
                 "                    Needs something else actively driving\n"
                 "                    MM2S at the same time (radioctl loopback,\n"
                 "                    a live receive) - there is no free-running\n"
                 "                    ADC in this design.\n"
                 "  --view <constellation|waveform>   (default constellation)\n"
                 "  --out <file>      also write \"I Q\" per line to a file\n"
                 "  --capture-timeout <ms>   (default 5000)\n"
                 "\n"
                 "Reads the register window only; never touches the DMA control\n"
                 "window or the reserved sample buffer, in either mode.\n",
                 p, p);
}

} // namespace

int main(int argc, char **argv)
{
    int interval_ms = 250, width = 60, height = 10, window = 200;
    const char *capture_tap_name = nullptr;
    const char *capture_out = nullptr;
    const char *capture_view = "constellation";
    int capture_timeout_ms = 5000;

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
        else if (!std::strcmp(argv[i], "--capture") && has_val)
            capture_tap_name = argv[++i];
        else if (!std::strcmp(argv[i], "--view") && has_val)
            capture_view = argv[++i];
        else if (!std::strcmp(argv[i], "--out") && has_val)
            capture_out = argv[++i];
        else if (!std::strcmp(argv[i], "--capture-timeout") && has_val)
            capture_timeout_ms = std::atoi(argv[++i]);
        else {
            usage(argv[0]);
            return 1;
        }
    }

    if (interval_ms < 10 || width < 10 || height < 2 || window < 2 ||
        capture_timeout_ms < 10) {
        std::fprintf(stderr, "implausible option value\n");
        return 1;
    }

    int capture_tap = -1;
    if (capture_tap_name) {
        capture_tap = tap_from_name(capture_tap_name);
        if (capture_tap < 0) {
            std::fprintf(stderr, "unknown tap: %s (want ddc, pll, filtered, "
                                 "or sym)\n", capture_tap_name);
            return 1;
        }
        if (std::strcmp(capture_view, "constellation") &&
            std::strcmp(capture_view, "waveform")) {
            std::fprintf(stderr, "unknown --view: %s (want constellation or "
                                 "waveform)\n", capture_view);
            return 1;
        }
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

    if (capture_tap_name) {
        auto pts = run_capture(capture_tap, capture_timeout_ms);
        if (pts.empty())
            return 1;

        if (capture_out && !save_capture(pts, capture_out))
            return 1;

        if (!std::strcmp(capture_view, "waveform"))
            plot_waveform(pts, width, height);
        else
            plot_constellation(pts, width, height);

        return 0;
    }

    TerminalInfo term;
    term.detect();

    // y runs 0..1: the ratio is bounded, and a fixed scale means the trace
    // means the same thing from one run to the next. An autoscaled axis would
    // make a flat bad lock look identical to a flat good one.
    RealCanvas<BrailleCanvas> canvas({{0.0f, 1.0f}, {1.0f, 0.0f}},
                                     Size(width, height), term);

    // No frame()/margin() - see the note at the top of this file. Redraw
    // math below is done by hand instead of via layout.size().y: one header
    // line, `height` canvas lines, 4 status lines beneath.
    const int total_lines = height + 5;

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
            std::cout << term.move_up(total_lines) << std::flush;
        first = false;

        std::cout << term.clear_line() << "lock quality  min/max, 0..1\n"
                  << canvas << '\n';

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
