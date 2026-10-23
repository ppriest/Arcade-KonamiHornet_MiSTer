// SPDX-License-Identifier: GPL-3.0-or-later
//
// SHARC v2 window bench (sim/sharc_tb's for rtl/cpu/sharc2): sharc2_core started from MAME's whole
// state at a frame
// (scripts/mame_sharc_window.py), writing one line per instruction in the trace's format
// (R0-15 I0-15 M0-15 ASTAT MODE1 IRPTL IMASK PCSTKP LSTKP CURLCNTR PCSTK, then "PC:") for
// scripts/compare_sharc_trace.py.
//
//     scripts/run_verilator.sh sharc2_tb +win=debug/gradius4-sharc3000 +n=300000 [+pipe]
//
// +pipe runs the pipeline as on the board (serial off): the trace is then not comparable, but
// the device accesses still are.
//
// External bus: the RAMs at 0x500000 and 0x1400000 are modelled from MAME's dumps, and the CG
// ROM from debug/<set>-roms/cgrom.bin with its bank from comm offset 1 bit 3 (konppc.cpp:268-276;
// MAME's taps do not see that bank). Every other access (shared RAM, Voodoo, comm, K033906) is
// replayed from io.txt in order:
// a read returns MAME's data, a write must match. PCSTK and CURLCNTR, which MAME does not
// save, come from the trace's first line. Interrupts are raised where MAME's trace
// enters a vector (0x20000 + 4n) other than by falling through. DMA timing is MAME's scheduler's,
// not the instruction stream's, so the value of a DMA-status read (IOP 0x37), IRPTL's DMA bits
// and ASTAT.BTF after a test of IRPTL are taken from MAME's trace; the core's DMA moves the data.

#include "Vtb_sharc2.h"
#include "Vtb_sharc2___024root.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <map>
#include <sstream>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static std::vector<uint32_t> load32(const std::string &p, size_t words) {
    std::vector<uint32_t> v(words, 0);
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(1); }
    size_t n = fread(v.data(), 4, words, f);
    fclose(f);
    fprintf(stderr, "%s: %zu words\n", p.c_str(), n);
    return v;
}

struct Access { char rw; uint32_t addr, data; };

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *s;
    long n = (s = Verilated::commandArgsPlusMatch("n=")) && *s ? atol(s + 3) : 100000;
    std::string win = (s = Verilated::commandArgsPlusMatch("win=")) && *s ? std::string(s + 5) : "";
    if (win.empty()) { fprintf(stderr, "+win=<dir> required\n"); return 1; }
    std::string dir = win + "/";

    // MAME's items: "name count v0 v1 ..."
    std::map<std::string, std::vector<uint64_t>> items;
    {
        FILE *f = fopen((dir + "items.txt").c_str(), "r");
        if (!f) { fprintf(stderr, "no %sitems.txt\n", dir.c_str()); return 1; }
        char line[8192];
        while (fgets(line, sizeof line, f)) {
            std::istringstream is(line);
            std::string name; int cnt;
            is >> name >> cnt;
            auto sl = name.find('/');
            if (sl != std::string::npos) name = name.substr(sl + 1);
            std::vector<uint64_t> v;
            std::string h;
            while (is >> h) v.push_back(strtoull(h.c_str(), nullptr, 16));
            items[name] = v;
        }
        fclose(f);
    }
    auto item = [&](const char *name) -> std::vector<uint64_t> & {
        auto it = items.find(name);
        if (it == items.end()) { fprintf(stderr, "item %s missing\n", name); exit(1); }
        return it->second;
    };

    auto block0 = load32(dir + "block0.bin", 32768);
    auto block1 = load32(dir + "block1.bin", 32768);
    auto ram500 = load32(dir + "ram500.bin", 1 << 20);
    auto ram1400 = load32(dir + "ram1400.bin", 1 << 20);
    std::vector<uint32_t> cgrom = load32("debug/gradius4-roms/cgrom.bin", 1 << 22);
    for (auto &w : cgrom) w = __builtin_bswap32(w);          // stored big-endian
    int cgbank = 0;

    std::vector<Access> log;
    {
        FILE *f = fopen((dir + "io.txt").c_str(), "r");
        Access e;
        while (f && fscanf(f, " %c %x %x", &e.rw, &e.addr, &e.data) == 3) log.push_back(e);
        if (f) fclose(f);
    }

    // MAME's trace: PCs, and the first line's PCSTK (not a saved item)
    std::vector<uint32_t> mpcs;
    std::vector<long> moffs;          // file offset of each trace line
    uint32_t pcstk0 = 0x00ffffff, curlcntr0 = 0xffffffff;
    {
        FILE *f = fopen((dir + "trace.tr").c_str(), "r");
        char line[2048];
        long off = 0;
        while (f && (long)mpcs.size() < n + 1 && (off = ftell(f), fgets(line, sizeof line, f))) {
            char *c = strchr(line, ':');
            if (!c || c - line < 6) continue;
            moffs.push_back(off);
            char *p = c;
            while (p > line && p[-1] != ' ') p--;
            if (mpcs.empty()) {
                // the 55th and 56th values are CURLCNTR and PCSTK
                char *q = line;
                for (int k = 0; k < 54; k++) { q = strchr(q, ' '); q++; }
                curlcntr0 = strtoul(q, &q, 16);
                pcstk0 = strtoul(q, nullptr, 16);
            }
            mpcs.push_back(strtoul(p, nullptr, 16));
        }
        if (f) fclose(f);
    }
    fprintf(stderr, "window: %zu device accesses, %zu trace PCs\n", log.size(), mpcs.size());

    FILE *mtr = fopen((dir + "trace.tr").c_str(), "r");
    auto mreg = [&](long i, int k) -> uint32_t {     // register k of MAME's line i
        static char line[2048];
        fseek(mtr, moffs[i], SEEK_SET);
        if (!fgets(line, sizeof line, mtr)) return 0;
        return strtoul(line + 9 * k, nullptr, 16);
    };

    Vtb_sharc2 *t = new Vtb_sharc2;
    t->clk = 0; t->reset = 1; t->ce = 0; t->serial = !Verilated::commandArgsPlusMatch("pipe")[0]; t->ext_ack = 0; t->irq_check_en = 0; t->dbg_irq_set = 0;
    t->dbg_we = 0; t->dbg_pm_we = 0; t->dbg_dm_we = 0; t->dbg_iop_ovr = 0;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    for (int i = 0; i < 4; i++) tick();
    t->reset = 0;
    auto put = [&](int sel, int idx, uint64_t v) {
        t->dbg_we = 1; t->dbg_wsel = sel; t->dbg_widx = idx; t->dbg_wdata = v; tick(); t->dbg_we = 0;
    };

    // program memory: MAME's packing of 48-bit words into block 0 (sharc.cpp:299-307)
    for (uint32_t off = 0; off < 0x5000; off++) {
        uint32_t slot = off >> 12, base = (off & 0xfff) + (slot >> 1) * (3 << 12);
        uint64_t w = (slot & 1) ? ((uint64_t)block0[base + 0x2000] << 16) | (block0[base + 0x1000] & 0xffff)
                                : ((uint64_t)block0[base] << 16) | (block0[base + 0x1000] >> 16);
        t->dbg_pm_we = 1; t->dbg_pm_addr = off; t->dbg_pm_wdata = w; tick();
    }
    t->dbg_pm_we = 0;
    for (uint32_t a = 0; a < 32768; a++) { t->dbg_dm_we = 1; t->dbg_dm_addr = a; t->dbg_dm_wdata = block1[a]; tick(); }
    t->dbg_dm_we = 0;

    struct { const char *name; int sel; int first, count; } arr[] = {
        {"&m_core->r[0].r", 0, 0, 16}, {"&m_core->reg_alt[0].r", 1, 0, 16},
        {"m_core->dag1.i", 2, 0, 8}, {"m_core->dag1.m", 3, 0, 8}, {"m_core->dag1.l", 4, 0, 8}, {"m_core->dag1.b", 5, 0, 8},
        {"m_core->dag2.i", 6, 0, 8}, {"m_core->dag2.m", 7, 0, 8}, {"m_core->dag2.l", 8, 0, 8}, {"m_core->dag2.b", 9, 0, 8},
        {"m_core->dag1_alt.i", 10, 0, 8}, {"m_core->dag1_alt.m", 11, 0, 8}, {"m_core->dag1_alt.l", 12, 0, 8}, {"m_core->dag1_alt.b", 13, 0, 8},
        {"m_core->dag2_alt.i", 14, 0, 8}, {"m_core->dag2_alt.m", 15, 0, 8}, {"m_core->dag2_alt.l", 16, 0, 8}, {"m_core->dag2_alt.b", 17, 0, 8},
        {"m_core->mrf", 18, 0, 1}, {"m_core->mrb", 19, 0, 1}, {"m_core->px", 20, 0, 1},
        {"m_core->pc", 21, 0, 1}, {"m_core->daddr", 22, 0, 1}, {"m_core->faddr", 23, 0, 1}, {"m_core->nfaddr", 24, 0, 1},
        {"m_core->delay_slot1", 25, 0, 1}, {"m_core->delay_slot2", 26, 0, 1},
        {"m_core->pcstkp", 28, 0, 1}, {"m_core->pcstack", 29, 0, 30},
        {"m_core->lcstack", 30, 0, 6}, {"m_core->lastack", 31, 0, 6},
        {"m_core->lstkp", 34, 0, 1},
        {"m_core->status_stack.mode1", 36, 0, 5}, {"m_core->status_stack.astat", 37, 0, 5}, {"m_core->status_stkp", 38, 0, 1},
        {"m_core->astat", 39, 0, 1}, {"m_core->astat_old", 40, 0, 1}, {"m_core->astat_old_old", 41, 0, 1},
        {"m_core->astat_old_old_old", 42, 0, 1}, {"m_core->mode1", 43, 0, 1}, {"m_core->mode2", 44, 0, 1},
        {"m_core->stky", 45, 0, 1}, {"m_core->irptl", 46, 0, 1}, {"m_core->imask", 47, 0, 1}, {"m_core->imaskp", 48, 0, 1},
        {"m_core->ustat1", 49, 0, 1}, {"m_core->ustat2", 50, 0, 1}, {"m_core->flag", 51, 0, 4},
        {"m_core->syscon", 52, 0, 1}, {"m_core->sysstat", 53, 0, 1}, {"m_core->idle", 54, 0, 1},
        {"m_core->irq_pending", 55, 0, 1}, {"m_core->active_irq_num", 56, 0, 1}, {"m_core->interrupt_active", 57, 0, 1},
        {"m_core->systemreg_latency_cycles", 58, 0, 1}, {"m_core->systemreg_latency_reg", 59, 0, 1},
        {"m_core->systemreg_latency_data", 60, 0, 1}, {"m_core->systemreg_previous_data", 61, 0, 1},
        {"m_core->dma.control", 62, 6, 2}, {"m_core->dma.int_index", 63, 6, 2}, {"m_core->dma.int_modifier", 64, 6, 2},
        {"m_core->dma.int_count", 65, 6, 2}, {"m_core->dma.chain_ptr", 66, 6, 2}, {"m_core->dma.gen_purpose", 67, 6, 2},
        {"m_core->dma.ext_index", 68, 6, 2}, {"m_core->dma.ext_modifier", 69, 6, 2}, {"m_core->dma.ext_count", 70, 6, 2},
        {"m_core->dma_op.active", 71, 6, 2}, {"m_core->dma_op.chained", 72, 6, 2},
        {"m_core->dma_op.src", 73, 6, 2}, {"m_core->dma_op.dst", 74, 6, 2},
        {"m_core->dma_op.src_modifier", 75, 6, 2}, {"m_core->dma_op.dst_modifier", 76, 6, 2},
        {"m_core->dma_op.src_count", 77, 6, 2}, {"m_core->dma_op.dst_count", 78, 6, 2},
        {"m_core->dma_op.pmode", 79, 6, 2}, {"m_core->dma_op.chain_ptr", 80, 6, 2},
        {"m_core->dma_op.chained_direction", 81, 6, 2}, {"m_core->dma_status", 82, 0, 1},
    };
    for (auto &a : arr) {
        auto &v = item(a.name);
        for (int k = 0; k < a.count; k++) put(a.sel, k, v[a.first + k]);
    }
    put(27, 0, pcstk0);                       // PCSTK and CURLCNTR are not saved items
    put(32, 0, curlcntr0);
    if (item("m_core->lstkp")[0] != 0) fprintf(stderr, "warning: LSTKP %llu at the window start; LADDR and LCNTR are not saved by MAME\n",
                                              (unsigned long long)item("m_core->lstkp")[0]);
    put(35, 0, 0xffffffff);                   // LADDR with the loop stack empty
    put(255, 0, 0);                            // start
    t->ce = 1;

    FILE *tr = fopen((dir + "rtl2.tr").c_str(), "w");
    size_t next = 0;
    bool fail = false;
    long insns = 0;
    uint64_t cyc = 0;
    bool irq_now = false;
    // clocks by what X does (sim/sharc2_tb/perf.vlt)
    enum { P_EXEC, P_SLOW, P_DMAWAIT, P_BUSY, P_OTHERSTALL, P_SQUASH, P_HAZARD, P_REFILL, P_EMPTY, P_N };
    static const char *pname[P_N] = {"exec", "slow-access", "dma-wait", "unit-busy", "flags/irq-wait",
                                     "squash", "D-hazard", "refill", "empty"};
    uint64_t perf[P_N] = {};
    uint64_t hz[5] = {};
    uint64_t xphc[8] = {};                   // slow clocks by X phase
    std::map<uint32_t, uint64_t> slow_pc;     // ... by the PC in X
    std::map<uint32_t, uint64_t> ld_pc;       // load hazard clocks by the load's PC (in X)                      // D hazard clocks: late R, multi-cycle wait, slow unit, DAG
    uint32_t irq_mask = 0;
    int fix_reg = -1;                   // R register loaded from the DMA status by the last insn
    bool fix_btf = false;               // the last insn tested IRPTL
    auto poke = [&](int sel, int idx, uint64_t v) {
        t->ce = 0; t->dbg_we = 1; t->dbg_wsel = sel; t->dbg_widx = idx; t->dbg_wdata = v;
        t->clk = 0; t->eval(); t->clk = 1; t->eval();
        t->dbg_we = 0; t->ce = 1; t->clk = 0; t->eval();
    };
    auto rtlreg = [&](int k) -> uint32_t { t->dbg_sel = k; t->eval(); return t->dbg_val; };
    // a window that opens idle starts at the vector MAME took
    if (!mpcs.empty() && mpcs[0] >= 0x20000 && mpcs[0] < 0x20080 && (mpcs[0] & 3) == 0 &&
        item("m_core->idle")[0]) {
        t->ce = 0; put(55, 0, 1u << ((mpcs[0] - 0x20000) / 4)); t->ce = 1;
        irq_now = true;
    }
    while (insns < n && !fail && !Verilated::gotFinish()) {
        t->clk = 0;
        t->ext_ack = 0;
        if (t->ext_req) {
            uint32_t a = t->ext_addr;
            uint32_t d = 0;
            if (a >= 0x500000 && a < 0x600000) {
                if (t->ext_we) ram500[a - 0x500000] = t->ext_wdata;
                d = ram500[a - 0x500000] & 0xffff;      // reads masked to 16 bits (hornet.cpp:1059)
            } else if (a >= 0x1400000 && a < 0x1500000) {
                if (t->ext_we) ram1400[a - 0x1400000] = t->ext_wdata;
                d = ram1400[a - 0x1400000];
            } else if (a >= 0x3600000 && a < 0x3800000) {
                d = cgrom[(cgbank << 21) + (a - 0x3600000)];
            } else {
                char rw = t->ext_we ? 'W' : 'R';
                if (rw == 'W' && a == 0x3400001) cgbank = (t->ext_wdata >> 3) & 1;
                if (next >= log.size()) { fprintf(stderr, "replay exhausted at %c %08X\n", rw, a); fail = true; }
                else {
                    const Access &e = log[next];
                    if (e.rw != rw || e.addr != a || (rw == 'W' && e.data != t->ext_wdata)) {
                        fprintf(stderr, "DEVICE DIVERGENCE at access %zu (insn %ld): MAME %c %08X %08X, RTL %c %08X %08X\n",
                                next + 1, insns, e.rw, e.addr, e.data, rw, a, t->ext_wdata);
                        fail = true;
                    }
                    d = e.data;
                    next++;
                }
            }
            t->ext_ack = 1; t->ext_rdata = d;
        }
        t->irq_check_en = irq_now;
        t->dbg_irq_set = irq_now ? irq_mask : 0;
        t->eval();
        if (t->dbg_exec) {
            irq_now = false;
            // DMA timing is MAME's scheduler's (the IOP write that starts a channel fires on a
            // timer): take DMA-status reads and IRPTL's DMA bits from MAME's trace
            if (insns < (long)mpcs.size()) {
                uint32_t mi = mreg(insns, 50), ri = rtlreg(50);
                if (mi != ri && ((mi ^ ri) & ~0x30000u) == 0) poke(46, 0, mi);
                uint32_t ma = mreg(insns, 48), ra = rtlreg(48);
                if (fix_btf && ma != ra && ((ma ^ ra) & ~0x40000u) == 0) poke(39, 0, ma);
            }
            fix_reg = -1; fix_btf = false;
            {
                uint64_t op = t->dbg_op;
                unsigned top = (op >> 40) & 0xff;
                // ureg = DM(0x37), direct (sharcop_dm_to_ureg_direct)
                // (v2: the IOP read itself returns MAME's value, which reaches a pipelined core)
                if (top == 0x10 && (uint32_t)op == 0x37 && ((op >> 36) & 0xf) == 0) fix_reg = (op >> 32) & 0xf;
                t->dbg_iop_ovr = fix_reg >= 0 && insns + 1 < (long)mpcs.size();
                if (t->dbg_iop_ovr) t->dbg_iop_val = mreg(insns + 1, fix_reg);
                // BIT TST/XOR IRPTL (sharcop_sysreg_bitop, sreg 9)
                if (top == 0x14 && ((op >> 32) & 0xf) == 9) fix_btf = true;
            }
            for (int i = 0; i < 56; i++) { t->dbg_sel = i; t->eval(); fprintf(tr, "%08X ", t->dbg_val); }
            fprintf(tr, "%06X: %012llX\n", t->dbg_pc, (unsigned long long)t->dbg_op);
            if (insns + 1 < (long)mpcs.size()) {
                uint32_t np = mpcs[insns + 1];
                if (np >= 0x20000 && np < 0x20080 && (np & 3) == 0 && np != mpcs[insns] + 1) {
                    // raise the interrupt MAME entered next
                    int which = (np - 0x20000) / 4;
                    irq_mask = 1u << which;
                    irq_now = true;
                }
            }
            insns++;
            // the interrupt inputs change after this edge: v2's fetch_step is in the executing
            // instruction's own clock (v1's bench changes them in this clock, for its next fetch)
        }
        {
            auto *R = t->rootp;
            int k;
            if (R->tb_sharc2__DOT__dsp__DOT__d_valid && R->tb_sharc2__DOT__dsp__DOT__d_hazard)
                for (int h = 0; h < 5; h++) if ((R->tb_sharc2__DOT__dsp__DOT__dbg_hz >> h) & 1) hz[h]++;
            if ((R->tb_sharc2__DOT__dsp__DOT__dbg_hz >> 4) & 1) ld_pc[R->tb_sharc2__DOT__dsp__DOT__x_pc]++;
            if (R->tb_sharc2__DOT__dsp__DOT__x_exec_now) k = P_EXEC;
            else if (R->tb_sharc2__DOT__dsp__DOT__x_squash) k = P_SQUASH;
            else if (R->tb_sharc2__DOT__dsp__DOT__x_valid && R->tb_sharc2__DOT__dsp__DOT__xph != 0) {
                k = P_SLOW;
                xphc[R->tb_sharc2__DOT__dsp__DOT__xph & 7]++;
                slow_pc[R->tb_sharc2__DOT__dsp__DOT__x_pc]++;
            }
            else if (R->tb_sharc2__DOT__dsp__DOT__x_valid && R->tb_sharc2__DOT__dsp__DOT__x_stall)
                k = R->tb_sharc2__DOT__dsp__DOT__x_busy ? P_BUSY : R->tb_sharc2__DOT__dsp__DOT__e_busy ? P_DMAWAIT : P_OTHERSTALL;
            else if (R->tb_sharc2__DOT__dsp__DOT__x_valid) k = P_OTHERSTALL;
            else if (R->tb_sharc2__DOT__dsp__DOT__d_valid && R->tb_sharc2__DOT__dsp__DOT__d_hazard) k = P_HAZARD;
            else if (!R->tb_sharc2__DOT__dsp__DOT__d_valid) k = P_REFILL;
            else k = P_EMPTY;
            perf[k]++;
        }
        t->clk = 1; t->eval();
        cyc++;
        if (cyc > (uint64_t)n * 400) {
            auto *R = t->rootp;
            fprintf(stderr, "no progress: X valid %d phase %d pc %06X todo %04X; D valid %d pc %06X hazard %d\n",
                    R->tb_sharc2__DOT__dsp__DOT__x_valid, R->tb_sharc2__DOT__dsp__DOT__xph,
                    R->tb_sharc2__DOT__dsp__DOT__x_pc, R->tb_sharc2__DOT__dsp__DOT__x_todo,
                    R->tb_sharc2__DOT__dsp__DOT__d_valid, R->tb_sharc2__DOT__dsp__DOT__d_pc,
                    R->tb_sharc2__DOT__dsp__DOT__d_hazard);
            break;
        }
    }
    fclose(tr);
    fprintf(stderr, "clocks:");
    for (int k = 0; k < P_N; k++) if (perf[k]) fprintf(stderr, " %s %llu", pname[k], (unsigned long long)perf[k]);
    fprintf(stderr, " | slow ACC %llu WAIT %llu POST %llu STEP %llu", (unsigned long long)xphc[1], (unsigned long long)xphc[2],
            (unsigned long long)xphc[3], (unsigned long long)xphc[4]);
    {
        std::vector<std::pair<uint64_t, uint32_t>> v;
        for (auto &e : slow_pc) v.push_back({e.second, e.first});
        std::sort(v.rbegin(), v.rend());
        {
            std::vector<std::pair<uint64_t, uint32_t>> u;
            for (auto &e : ld_pc) u.push_back({e.second, e.first});
            std::sort(u.rbegin(), u.rend());
            FILE *lp = fopen((win + "/ldhz_pcs.txt").c_str(), "w");
            for (auto &e : u) fprintf(lp, "%05X %llu\n", e.second, (unsigned long long)e.first);
            fclose(lp);
        }
        FILE *sp = fopen((win + "/slow_pcs.txt").c_str(), "w");
        for (auto &e : v) fprintf(sp, "%05X %llu\n", e.second, (unsigned long long)e.first);
        fclose(sp);
    }
    fprintf(stderr, " | hazard late-R %llu mc-wait %llu slow-unit %llu dag %llu (late R from loads %llu)", (unsigned long long)hz[0], (unsigned long long)hz[1], (unsigned long long)hz[2], (unsigned long long)hz[3], (unsigned long long)hz[4]);
    fprintf(stderr, "\n");
    fprintf(stderr, "%ld instructions, %llu clocks, %zu of %zu device accesses replayed\n", insns,
            (unsigned long long)cyc, next, log.size());
    delete t;
    return fail ? 2 : 0;
}
