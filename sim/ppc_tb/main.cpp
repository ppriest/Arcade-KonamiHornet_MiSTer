// SPDX-License-Identifier: GPL-3.0-or-later
//
// PPC403 bench: the core against gradius4's ROMs, writing one line per instruction in the
// format of scripts/mame_insn_trace.py --regs all (R0..R31 CR LR CTR XER MSR, then "PC:"),
// for scripts/compare_insn_trace.py.
//
//   from reset:  scripts/run_verilator.sh ppc_tb +n=100000
//                -> debug/gradius4-insn/rtl.tr
//   a window:    scripts/run_verilator.sh ppc_tb +win=debug/gradius4-win3000 +n=300000
//                -> <win>/rtl.tr
//
// A window (scripts/mame_ppc_window.py) starts from MAME's registers and work RAM and
// replays every device access from MAME's io.txt in order: a read returns MAME's data, a
// write must match MAME's. The first mismatch stops the run. The vblank interrupt (IRQ0) is
// raised where MAME's trace enters the external-interrupt vector, and dropped on the
// sysreg 7 bit 6 write that clears it in MAME (hornet.cpp:813-814).
//
// Timing-dependent state comes from MAME too, since the core's timing is not MAME's: the
// timebase is stopped, each mfspr of TBLO/TBHI has its result replaced by MAME's, and the PIT
// interrupt is raised (TSR.PIS) where MAME's trace enters vector 0x1000. TCR starts at
// 0x04000000, the value the game writes (code at 0x80209590; MAME does not export TCR).
//
// From reset, devices not modelled read as 0 except the sysregs; every access is logged to
// debug/<set>-insn/rtl_io.log.

#include "Vtb_ppc.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <map>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static std::vector<uint8_t> load(const std::string &p, size_t size) {
    std::vector<uint8_t> v(size, 0);
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(1); }
    size_t n = fread(v.data(), 1, size, f);
    fclose(f);
    fprintf(stderr, "%s: %zu bytes\n", p.c_str(), n);
    return v;
}

static uint32_t be32(const std::vector<uint8_t> &m, uint32_t a) {
    return (uint32_t)m[a] << 24 | (uint32_t)m[a + 1] << 16 | (uint32_t)m[a + 2] << 8 | m[a + 3];
}

static void wr_be(std::vector<uint8_t> &m, uint32_t a, uint32_t v, unsigned be) {
    for (int i = 0; i < 4; i++)
        if (be & (8 >> i)) m[a + i] = (uint8_t)(v >> (24 - 8 * i));
}

static uint32_t be_mask(unsigned be) {
    uint32_t m = 0;
    for (int i = 0; i < 4; i++)
        if (be & (8 >> i)) m |= 0xffu << (24 - 8 * i);
    return m;
}

struct Access { char rw; uint32_t addr, mask, data; };

struct Board {
    std::vector<uint8_t> ram, prg, data;
    FILE *io = nullptr;
    bool replay = false;
    std::vector<Access> log;
    size_t next = 0;
    bool fail = false;
    bool irq0_ack = false;

    bool mem_rom(uint32_t a) const {
        return a < 0x400000 || (a >= 0x7e000000 && a < 0x7e800000) || a >= 0x7f000000;
    }

    uint32_t rom_read(uint32_t a) const {
        if (a < 0x400000) return be32(ram, a);
        if (a >= 0x7e000000 && a < 0x7e800000) return be32(data, a - 0x7e000000);
        if (a >= 0x7fc00000) return be32(prg, a - 0x7fc00000);
        if (a >= 0x7f000000 && a < 0x7f400000) return be32(prg, a - 0x7f000000);
        return 0;
    }

    // a device access, replayed or stubbed
    uint32_t device(char rw, uint32_t a, uint32_t v, unsigned be) {
        uint32_t mask = be_mask(be);
        if (rw == 'W' && a == 0x7d010004 && (be & 1) && (v & 0x40)) irq0_ack = true;
        if (replay) {
            if (next >= log.size()) {
                fprintf(stderr, "replay exhausted at %c %08X\n", rw, a);
                fail = true;
                return 0;
            }
            const Access &e = log[next];
            if (e.rw != rw || e.addr != a || e.mask != mask || (rw == 'W' && ((e.data ^ v) & mask))) {
                fprintf(stderr, "DEVICE DIVERGENCE at access %zu: MAME %c %08X mask %08X data %08X, "
                        "RTL %c %08X mask %08X data %08X\n", next + 1, e.rw, e.addr, e.mask, e.data,
                        rw, a, mask, v & mask);
                fail = true;
                return 0;
            }
            next++;
            return e.data;
        }
        uint32_t r = 0;
        if (rw == 'R' && a == 0x7d000000) r = 0xffffff70;   // IN0-2 idle, port 3 (hornet.cpp:654-670)
        if (rw == 'R' && a == 0x7d000004) r = 0xff000000;   // DSW
        if (io) fprintf(io, "%c %08X %08X %08X\n", rw, a, mask, rw == 'W' ? v & mask : r & mask);
        return r;
    }

    uint32_t read(uint32_t a) {
        a &= 0x7ffffffc;
        if (mem_rom(a)) return rom_read(a);
        return device('R', a, 0, 0xf);
    }

    uint32_t dread(uint32_t a, unsigned be) {
        a &= 0x7ffffffc;
        if (mem_rom(a)) return rom_read(a);
        return device('R', a, 0, be);
    }

    void write(uint32_t a, uint32_t v, unsigned be) {
        a &= 0x7ffffffc;
        if (a < 0x400000) { wr_be(ram, a, v, be); return; }
        if (mem_rom(a)) return;
        device('W', a, v, be);
    }
};

// MAME's trace: the PC of every line, and where each line starts for reading registers back
struct Trace {
    FILE *f = nullptr;
    std::vector<uint32_t> pcs;
    std::vector<long> offs;

    void open(const std::string &path, long n) {
        f = fopen(path.c_str(), "r");
        if (!f) return;
        static char line[1024];
        long off = ftell(f);
        while ((long)pcs.size() < n + 1 && fgets(line, sizeof line, f)) {
            char *c = strchr(line, ':');
            if (c && c - line >= 8) {
                pcs.push_back((uint32_t)strtoul(c - 8, nullptr, 16));
                offs.push_back(off);
            }
            off = ftell(f);
        }
    }

    uint32_t gpr(long i, int r) {
        static char line[1024];
        fseek(f, offs[i], SEEK_SET);
        if (!fgets(line, sizeof line, f)) return 0;
        return (uint32_t)strtoul(line + 9 * r, nullptr, 16);
    }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *s;
    std::string set = (s = Verilated::commandArgsPlusMatch("set=")) && *s ? std::string(s + 5) : "gradius4";
    long n = (s = Verilated::commandArgsPlusMatch("n=")) && *s ? atol(s + 3) : 100000;
    int lat = (s = Verilated::commandArgsPlusMatch("lat=")) && *s ? atoi(s + 5) : 1;
    std::string win = (s = Verilated::commandArgsPlusMatch("win=")) && *s ? std::string(s + 5) : "";

    std::string roms = "debug/" + set + "-roms/";
    std::string dir = win.empty() ? "debug/" + set + "-insn/" : win + "/";
    Board b;
    b.prg = load(roms + "prgrom.bin", 0x400000);
    b.data = load(roms + "datarom.bin", 0x800000);
    std::map<std::string, uint32_t> st;
    Trace mt;
    uint32_t evpr = 0;
    if (win.empty()) {
        b.ram.assign(0x400000, 0);
        b.io = fopen((dir + "rtl_io.log").c_str(), "w");
    } else {
        b.ram = load(dir + "workram.bin", 0x400000);
        FILE *f = fopen((dir + "state.txt").c_str(), "r");
        if (!f) { fprintf(stderr, "no %sstate.txt\n", dir.c_str()); return 1; }
        char k[32]; unsigned v;
        while (fscanf(f, "%31[^=]=%x\n", k, &v) == 2) st[k] = v;
        fclose(f);
        FILE *io = fopen((dir + "io.txt").c_str(), "r");
        Access e;
        while (io && fscanf(io, " %c %x %x %x", &e.rw, &e.addr, &e.mask, &e.data) == 4) b.log.push_back(e);
        if (io) fclose(io);
        b.replay = true;
        mt.open(dir + "trace.tr", n);
        evpr = st["EVPR"] & 0xffff0000;
        fprintf(stderr, "window: %zu device accesses, %zu trace PCs, start PC %08X\n",
                b.log.size(), mt.pcs.size(), st["PC"]);
    }
    FILE *tr = fopen((dir + "rtl.tr").c_str(), "w");
    if (!tr) { fprintf(stderr, "cannot write %srtl.tr\n", dir.c_str()); return 1; }

    Vtb_ppc *t = new Vtb_ppc;
    t->clk = 0; t->reset = 1; t->ce = 0; t->tb_tick = 0; t->ext_irq = 0;
    t->i_ack = 0; t->d_ack = 0; t->dbg_we = 0;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    for (int i = 0; i < 4; i++) tick();
    t->reset = 0;
    // a register write between cycles, the core held
    auto poke = [&](int sel, uint32_t v) {
        int ce = t->ce;
        t->ce = 0; t->dbg_we = 1; t->dbg_wsel = sel; t->dbg_wdata = v;
        t->clk = 0; t->eval(); t->clk = 1; t->eval();
        t->dbg_we = 0; t->ce = ce;
    };
    if (!win.empty()) {
        for (int i = 0; i < 32; i++) poke(i, st["R" + std::to_string(i)]);
        const char *names[] = {"CR", "LR", "CTR", "XER", "MSR", "PC", "SRR0", "SRR1",
                               "SPRG0", "SPRG1", "SPRG2", "SPRG3", "EXIER", "EVPR", "TBL", "TBH"};
        for (int i = 0; i < 16; i++) poke(32 + i, st[names[i]]);
        poke(48, 0x04000000);
    }
    t->ce = 1;

    // each port: one request outstanding, answered `lat` cycles after the request cycle
    struct Req { bool on = false; int wait = 0; uint32_t addr = 0, wdata = 0; unsigned be = 0; bool we = false; };
    Req ir, dr;
    int tb_fix = -1;                            // GPR to take from MAME before the next line
    bool pit_now = false;                       // raise TSR.PIS before the next cycle
    long insns = 0;
    uint64_t cyc = 0;
    while (insns < n && !Verilated::gotFinish() && !b.fail) {
        if (pit_now) { poke(49, 0x08000000); pit_now = false; }
        t->clk = 0;
        t->i_ack = 0; t->d_ack = 0;
        if (ir.on && ir.wait == 0) { t->i_ack = 1; t->i_rdata = b.read(ir.addr); ir.on = false; }
        if (dr.on && dr.wait == 0) {
            t->d_ack = 1;
            if (dr.we) { b.write(dr.addr, dr.wdata, dr.be); t->d_rdata = 0; }
            else t->d_rdata = b.dread(dr.addr, dr.be);
            dr.on = false;
        }
        if (b.irq0_ack) { t->ext_irq &= ~1; b.irq0_ack = false; }
        t->tb_tick = win.empty() && (cyc & 1);
        t->eval();

        if (t->dbg_exec) {
            if (tb_fix >= 0 && insns < (long)mt.pcs.size()) { poke(tb_fix, mt.gpr(insns, tb_fix)); t->eval(); }
            tb_fix = -1;
            for (int i = 0; i < 37; i++) {
                t->dbg_sel = i; t->eval();
                fprintf(tr, "%08X ", t->dbg_val);
            }
            fprintf(tr, "%08X: %08X\n", t->dbg_pc, t->dbg_ir);
            uint32_t op = t->dbg_ir;
            if (!win.empty() && (op >> 26) == 31 && ((op >> 1) & 0x3ff) == 339) {
                unsigned spr = ((op >> 11) & 0x1f) << 5 | ((op >> 16) & 0x1f);
                if (spr == 0x3dc || spr == 0x3dd || spr == 0x3cc || spr == 0x3cd) tb_fix = (op >> 21) & 31;
            }
            // MAME's next instruction is an interrupt vector not reached by falling through:
            // raise the source now, after this instruction has been decided
            if (insns + 1 < (long)mt.pcs.size() && mt.pcs[insns] + 4 != mt.pcs[insns + 1]) {
                if (mt.pcs[insns + 1] == (evpr | 0x500)) { t->ext_irq |= 1; t->eval(); }
                if (mt.pcs[insns + 1] == (evpr | 0x1000)) pit_now = true;
            }
            insns++;
        }
        if (t->i_req && !ir.on) { ir.on = true; ir.wait = lat - 1; ir.addr = (uint32_t)t->i_addr; }
        if (t->d_req && !dr.on) {
            dr.on = true; dr.wait = lat - 1; dr.addr = (uint32_t)t->d_addr;
            dr.we = t->d_we; dr.be = t->d_be; dr.wdata = t->d_wdata;
        }
        t->clk = 1; t->eval();
        if (ir.on && ir.wait > 0) ir.wait--;
        if (dr.on && dr.wait > 0) dr.wait--;
        cyc++;
    }
    fclose(tr);
    if (b.io) fclose(b.io);
    fprintf(stderr, "%ld instructions, %llu clocks (%.2f clocks/insn)", insns,
            (unsigned long long)cyc, insns ? (double)cyc / insns : 0.0);
    if (b.replay) fprintf(stderr, ", %zu of %zu device accesses replayed", b.next, b.log.size());
    fprintf(stderr, "\n");
    delete t;
    return b.fail ? 2 : 0;
}
