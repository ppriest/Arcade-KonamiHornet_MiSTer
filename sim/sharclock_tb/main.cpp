// SPDX-License-Identifier: GPL-3.0-or-later
//
// v1 against v2 on generated programs (tb_sharclock.sv): the same program and starting state in
// sharc_core, sharc2_core serial and sharc2_core pipelined. v1 and v2 serial are compared at every
// retired instruction (PC and the 56 registers of the window benches' trace); the pipelined core
// at the end, when all three sit in the program's last word (a jump to itself). No window capture
// is needed, so the float paths can be driven where the game does not go: MODE1 TRUNC, RND32 and
// ALUSAT toggled, denormal, tiny and huge operands, FIX / FLOAT with scales to the exponent's
// ends, STKY read into R registers. Every form used is in v2 with SUBSET 0. Internal memory only,
// no interrupts or DMA.
//
//     scripts/run_verilator.sh sharclock_tb [-GMAME_RND=1] [-GONE_FADD=0] [+seeds=200] [+seed0=1]
//                                           [+words=3000] [+hash]
//
// +hash prints, per program, a hash of every retire record of the three cores (clock, PC, the
// 56 registers): the same build at another commit must print the same hashes when nothing it
// models has changed, timing included.

#include "Vtb_sharclock.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <map>
#include <random>
#include <vector>

double sc_time_stamp() { return 0; }

typedef uint64_t u64;

static const u64 BASE = 0x20080;                      // the program; 0x20000-0x2007F stays empty

struct Gen {
    std::mt19937_64 g;
    std::vector<u64> prog;
    explicit Gen(u64 seed) : g(seed) {}
    u64 rnd(u64 n) { return g() % n; }
    double fr() { return (g() >> 11) * (1.0 / 9007199254740992.0); }
    int rreg() { return int(rnd(16)); }
    void emit(u64 w) { prog.push_back(w & 0xffffffffffffull); }

    u64 cond() {
        static const int astat_c[] = {0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0d,
                                      0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x1d};
        double r = fr();
        if (r < 0.7) return 0x1f;
        return astat_c[rnd(20)];
    }
    // compute fields: fixed ALU, float ALU, FMUL, shifter, multifunction
    u64 comp(bool allow_none = true) {
        static const int fixed[] = {0x01, 0x05, 0x25, 0x29, 0x02, 0x06, 0x26, 0x2a, 0x0a, 0x21, 0x22,
                                    0x30, 0x40, 0x41, 0x42, 0x43, 0x61, 0x62, 0x63};
        static const int flt[] = {0x81, 0x82, 0x91, 0x92, 0x89, 0x8a, 0xa1, 0xa2, 0xb0, 0xbd, 0xc1,
                                  0xc4, 0xc5, 0xc9, 0xca, 0xd9, 0xda, 0xe0, 0xe1, 0xe2, 0xe3,
                                  0x81, 0x82, 0x89, 0xc9, 0xca, 0xd9, 0xda, 0xf0};   // rounding ops twice
        static const int shift[] = {0x00, 0x08, 0x01, 0x02, 0x10, 0x11, 0x12, 0x13, 0x19, 0x30, 0x31,
                                    0x32, 0x33};
        double r = fr();
        if (allow_none && r < 0.10) return 0;
        if (r < 0.20) return (u64(fixed[rnd(19)]) << 12) | (rreg() << 8) | (rreg() << 4) | rreg();
        if (r < 0.50) {
            u64 op = flt[rnd(29)];
            if (op == 0xf0) return (u64(0xf0 | rreg()) << 12) | (rreg() << 8) | (rreg() << 4) | rreg();   // Ra = Rx + Ry, Rs = Rx - Ry
            return (op << 12) | (rreg() << 8) | (rreg() << 4) | rreg();
        }
        if (r < 0.65) return (1ull << 20) | (0x30ull << 12) | (rreg() << 8) | (rreg() << 4) | rreg();   // FMUL
        if (r < 0.72) return (2ull << 20) | (u64(shift[rnd(13)] << 2) << 12) | (rreg() << 8) | (rreg() << 4) | rreg();
        u64 mop = fr() < 0.6 ? 0x18 + rnd(8) : 0x30 + rnd(16);                       // FMUL || ALU
        return (1ull << 22) | (mop << 16) | (u64(rreg()) << 12) | (u64(rreg()) << 8) | rnd(256);
    }
    uint32_t fval() {
        double r = fr();
        uint32_t s = uint32_t(g() & 1) << 31, m = uint32_t(g()) & 0x7fffff;
        if (r < 0.30) { if (fr() < 0.3) m &= ~0xfffu; return s | (uint32_t(100 + rnd(60)) << 23) | m; }
        if (r < 0.40) return s | (uint32_t(1 + rnd(4)) << 23) | m;                    // near 2^-126
        if (r < 0.48) return s | (uint32_t(63 + rnd(4)) << 23) | m;                   // squares near 2^-126
        if (r < 0.54) return s | (uint32_t(190 + rnd(4)) << 23) | m;                  // squares near 2^128
        if (r < 0.60) return s | (uint32_t(250 + rnd(5)) << 23) | m;
        if (r < 0.66) return s | m;                                                   // denormal
        if (r < 0.72) {
            static const uint32_t sp[] = {0, 0x80000000, 0x7f800000, 0x00400000, 0x00800000,
                                          0x7f7fffff, 0x3f800000, 0x3f000000, 0xbfc00000};
            return sp[rnd(9)];
        }
        if (r < 0.86) return uint32_t(int32_t(rnd(129)) - 64);                        // integers, scales
        return uint32_t(g());
    }

    void build(int nwords) {
        // MODE1: TRUNC (0x8000), RND32 (0x10000) and ALUSAT (0x2000) in every combination
        static const uint32_t mode1v[] = {0x0, 0x8000, 0x10000, 0x18000, 0x2000, 0xa000, 0x12000, 0x1a000};
        emit((0x0full << 40) | (0x7bull << 32) | mode1v[rnd(8)]);
        for (int k = 0; k < 8; k++) {
            emit((0x0full << 40) | (u64(0x10 + k) << 32) | (0x28100 + 0x100 * k));      // I0-7 into block 1
            emit((0x0full << 40) | (u64(0x20 + k) << 32) | (uint32_t(int32_t(rnd(5)) - 2)));
        }
        for (int k = 0; k < 16; k++) emit((0x0full << 40) | (u64(k) << 32) | fval());
        while ((int)prog.size() < nwords) {
            double r = fr();
            if (r < 0.36) emit((0x02ull << 39) | (cond() << 33) | comp(false));       // compute
            else if (r < 0.44) {                                                       // compute, dreg <-> DM
                u64 i = rnd(8), d = g() & 1, u = g() & 1, mv = u64(int(rnd(7)) - 3) & 0x3f, dr = rreg();
                emit((0b0110ull << 44) | (i << 41) | (d << 39) | (u << 38) | (cond() << 33) |
                     (mv << 27) | (dr << 23) | comp());
            } else if (r < 0.50) {                                                     // compute, R <-> DM, I/M
                u64 post = g() & 1, i = rnd(8), m = rnd(8), d = g() & 1, u = rreg();
                emit((0b010ull << 45) | (post << 44) | (i << 41) | (m << 38) | (cond() << 33) |
                     (d << 31) | (u << 23) | comp());
            } else if (r < 0.62) {                                                     // compute, ureg = ureg
                static const int src[] = {0x7e, 0x7e, 0x7e, 0x7c, 0x7b};              // STKY, ASTAT, MODE1
                u64 s = fr() < 0.7 ? src[rnd(5)] : u64(rreg()), dst = rreg();
                emit((0b0111ull << 44) | (s << 36) | (cond() << 31) | (dst << 23) | comp());
            } else if (r < 0.74) {                                                     // immediate -> ureg
                double q = fr();
                if (q < 0.70) emit((0x0full << 40) | (u64(rreg()) << 32) | fval());
                else if (q < 0.85) emit((0x0full << 40) | (0x7bull << 32) | mode1v[rnd(8)]);
                else if (q < 0.95) emit((0x0full << 40) | (0x7eull << 32) | 0x05400000);   // STKY: only the empty stacks
                else emit((0x0full << 40) | (u64(0x20 + rnd(8)) << 32) | (uint32_t(int32_t(rnd(5)) - 2)));
            } else if (r < 0.78) {                                                     // immediate shift
                static const int sop[] = {0x00, 0x08, 0x01, 0x02, 0x10, 0x11, 0x12, 0x13, 0x19};
                u64 op = sop[rnd(9)], data = op < 0x10 ? (u64(int(rnd(80)) - 40) & 0xfff) : (g() & 0xfff);
                emit((0b000000100ull << 39) | (cond() << 33) | (((data >> 8) & 15) << 27) | (op << 16) |
                     ((data & 0xff) << 8) | (rreg() << 4) | rreg());
            } else if (r < 0.84) {                                                     // a counted loop
                u64 n = 1 + rnd(4), L = 1 + rnd(5);
                emit((0x0cull << 40) | (n << 24) | L);
                for (u64 k = 0; k < L; k++) emit((0x02ull << 39) | (0x1full << 33) | comp(false));
            } else if (r < 0.88) {                                                     // a forward jump, delayed or not
                u64 k = 3 + rnd(4), j = g() & 1;
                emit((0x07ull << 40) | (cond() << 33) | (j << 26) | k);
                for (u64 q = 0; q + 1 < k; q++) emit((0x02ull << 39) | (0x1full << 33) | comp(false));
            } else if (r < 0.90) emit(0);                                              // NOP
            else {                                                                     // I back into block 1
                u64 k = rnd(8);
                emit((0x0full << 40) | (u64(0x10 + k) << 32) | (0x28100 + 0x100 * k + rnd(64)));
            }
        }
        u64 end = BASE + prog.size();
        emit((0x06ull << 40) | (0x1full << 33) | end);                                // JUMP to itself
    }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *s;
    long seeds = (s = Verilated::commandArgsPlusMatch("seeds=")) && *s ? atol(s + 7) : 200;
    long seed0 = (s = Verilated::commandArgsPlusMatch("seed0=")) && *s ? atol(s + 7) : 1;
    int words = (s = Verilated::commandArgsPlusMatch("words=")) && *s ? atoi(s + 7) : 3000;
    bool hash = Verilated::commandArgsPlusMatch("hash")[0];
    long fails = 0, insns = 0, trunc_insns = 0, rnd32_insns = 0, stky_reads = 0;
    for (long sd = seed0; sd < seed0 + seeds; sd++) {
        Gen gen(sd);
        gen.build(words);
        const u64 endpc = BASE + gen.prog.size() - 1;
        Vtb_sharclock *t = new Vtb_sharclock;
        t->clk = 0; t->reset = 1; t->ce = 0;
        t->dbg_we = 0; t->dbg_pm_we = 0; t->dbg_dm_we = 0;
        auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
        for (int i = 0; i < 4; i++) tick();
        t->reset = 0;
        for (size_t k = 0; k < gen.prog.size(); k++) {
            t->dbg_pm_we = 1; t->dbg_pm_addr = BASE - 0x20000 + k; t->dbg_pm_wdata = gen.prog[k]; tick();
        }
        t->dbg_pm_we = 0;
        for (uint32_t a = 0; a < 0x1000; a++) { t->dbg_dm_we = 1; t->dbg_dm_addr = a; t->dbg_dm_wdata = gen.fval(); tick(); }
        t->dbg_dm_we = 0;
        auto put = [&](int sel, int idx, u64 v) {
            t->dbg_we = 1; t->dbg_wsel = sel; t->dbg_widx = idx; t->dbg_wdata = v; tick(); t->dbg_we = 0;
        };
        for (int k = 0; k < 16; k++) { put(0, k, gen.fval()); put(1, k, 0); }
        for (int sel = 2; sel <= 17; sel++) for (int k = 0; k < 8; k++) put(sel, k, 0);
        put(18, 0, gen.g()); put(19, 0, gen.g());
        // MAME's pipeline registers: the first word executed is daddr (sharc.cpp execute_run)
        put(21, 0, BASE - 1); put(22, 0, BASE); put(23, 0, BASE + 1); put(24, 0, BASE + 2);
        put(27, 0, 0x00ffffff); put(32, 0, 0xffffffff); put(35, 0, 0xffffffff);
        put(45, 0, 0x05400000);                       // STKY: the stacks empty (boot_state)
        put(52, 0, 0x10);
        put(255, 0, 0);
        t->ce = 1;

        struct Ret { uint32_t pc; u64 op; uint32_t v[56]; };
        std::deque<Ret> q1, q2;
        long n1 = 0, n2 = 0, at_end1 = 0, at_end2 = 0, at_end3 = 0, cyc = 0;
        bool bad = false;
        u64 h = 1469598103934665603ull;
        auto mix = [&](u64 v) { for (int b = 0; b < 8; b++) { h ^= (v >> (8 * b)) & 0xff; h *= 1099511628211ull; } };
        while (!bad && cyc < 400L * words + 100000) {
            t->clk = 0; t->eval();
            if (t->exec1 && at_end1 < 4) {
                Ret r; r.pc = t->pc1; r.op = t->op1;
                for (int k = 0; k < 56; k++) { t->sel1 = k; t->eval(); r.v[k] = t->val1; }
                mix(1); mix(cyc); mix(r.pc); for (int k = 0; k < 56; k++) mix(r.v[k]);
                if (r.pc != endpc) {
                    q1.push_back(r); n1++;
                    if (r.v[49] & 0x8000) trunc_insns++;
                    if (r.v[49] & 0x10000) rnd32_insns++;
                    if (((r.op >> 44) & 0xf) == 0b0111 && ((r.op >> 36) & 0xff) == 0x7e) stky_reads++;
                } else at_end1++;
            }
            if (t->exec2 && at_end2 < 4) {
                Ret r; r.pc = t->pc2; r.op = 0;
                for (int k = 0; k < 56; k++) { t->sel2 = k; t->eval(); r.v[k] = t->val2; }
                mix(2); mix(cyc); mix(r.pc); for (int k = 0; k < 56; k++) mix(r.v[k]);
                if (r.pc != endpc) { q2.push_back(r); n2++; } else at_end2++;
            }
            if (t->exec3) {
                mix(3); mix(cyc); mix(t->pc3);
                if (t->pc3 == endpc) at_end3++;
            }
            while (!q1.empty() && !q2.empty()) {
                Ret &a = q1.front(), &b = q2.front();
                bool diff = a.pc != b.pc;
                for (int k = 0; k < 56; k++) diff |= a.v[k] != b.v[k];
                if (diff) {
                    printf("seed %ld: v1 and v2 serial differ after instruction %ld, PC %05X (v2 %05X) %012llX:", sd,
                           n1 - long(q1.size()), a.pc, b.pc, (unsigned long long)a.op);
                    for (int k = 0; k < 56; k++) if (a.v[k] != b.v[k]) printf(" [%d] %08X/%08X", k, a.v[k], b.v[k]);
                    printf("\n");
                    bad = true;
                    break;
                }
                q1.pop_front(); q2.pop_front();
            }
            if (t->ext1 || t->ext2 || t->ext3) { printf("seed %ld: an external access\n", sd); bad = true; }
            if (t->unsup2 || t->unsup3) { printf("seed %ld: v2 flags an unsupported instruction\n", sd); bad = true; }
            t->clk = 1; t->eval();
            cyc++;
            if (at_end1 >= 4 && at_end2 >= 4 && at_end3 >= 8) break;
        }
        if (!bad && !(at_end1 >= 4 && at_end2 >= 4 && at_end3 >= 8)) {
            printf("seed %ld: no end after %ld clocks (v1 %ld, v2 serial %ld instructions)\n", sd, cyc, n1, n2);
            bad = true;
        }
        if (!bad && n1 != n2) { printf("seed %ld: v1 %ld instructions, v2 serial %ld\n", sd, n1, n2); bad = true; }
        if (!bad) {
            t->clk = 0; t->eval();
            for (int k = 0; k < 56; k++) {
                t->sel1 = k; t->sel3 = k; t->eval();
                mix(t->val3);
                if (k != 50 && t->val1 != t->val3) {   // IRPTL: no interrupts here, but not compared
                    printf("seed %ld: v2 pipelined ends with register [%d] %08X, v1 %08X\n", sd, k, t->val3, t->val1);
                    bad = true;
                }
            }
        }
        if (hash) printf("seed %ld hash %016llx clocks %ld\n", sd, (unsigned long long)h, cyc);
        insns += n1;
        fails += bad;
        delete t;
    }
    printf("%ld programs, %ld instructions compared (%ld under TRUNC, %ld under RND32, %ld STKY reads), %ld failed\n",
           seeds, insns, trunc_insns, rnd32_insns, stky_reads, fails);
    printf(fails ? "FAIL\n" : "PASS\n");
    return fails ? 1 : 0;
}
