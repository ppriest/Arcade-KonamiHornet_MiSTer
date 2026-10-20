// SPDX-License-Identifier: GPL-3.0-or-later
// v2 float units against sharc_fp_pkg (tb_sharc2fp.sv). Operands: random bit patterns, and
// pairs with nearby exponents and shared high mantissa bits (cancellation), with zeros,
// infinities, NaNs and denormals mixed in.
//
//     scripts/run_verilator.sh sharc2fp_tb [+n=10000000] [+seed=1]
#include "Vtb_sharc2fp.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>

double sc_time_stamp() { return 0; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *s;
    long n = (s = Verilated::commandArgsPlusMatch("n=")) && *s ? atol(s + 3) : 10000000;
    unsigned seed = (s = Verilated::commandArgsPlusMatch("seed=")) && *s ? atoi(s + 6) : 1;
    std::mt19937 rng(seed);
    auto special = [&](uint32_t v) -> uint32_t {
        switch (rng() % 16) {
        case 0: return v & 0x80000000;                           // zero
        case 1: return (v & 0x80000000) | 0x7f800000;            // inf
        case 2: return (v & 0x807fffff) | 0x7f800000 | 1;        // NaN
        case 3: return v & 0x807fffff;                           // denormal
        case 4: return (v & 0x80000000) | 0x00800000 | (v & 0x7fffff);  // smallest exponent
        case 5: return (v & 0x80000000) | 0x7f000000 | (v & 0x7fffff);  // largest exponent
        default: return v;
        }
    };
    Vtb_sharc2fp *t = new Vtb_sharc2fp;
    long bad_add = 0, bad_mul = 0, checked = 0, stalls = 0;
    uint32_t hx[3] = {0}, hy[3] = {0};
    for (long i = 0; i < n + 1; i++) {
        uint32_t x = rng(), y;
        switch (rng() % 5) {
        case 0: y = rng(); break;
        case 1: y = (x & 0xffffff00) ^ (rng() & 0x800000ff); break;   // near cancellation
        case 2: y = x + (int32_t)((rng() % 0x1800000) - 0xC00000); break;  // exponent within 1
        case 3: y = (rng() & 0x807fffff) | ((254 - ((x >> 23) & 0xff) + rng() % 8 - 4) & 0xff) << 23;
                break;                                             // product near 1 / overflow
        default: y = (x ^ 0x80000000) + (rng() % 64) - 32; break;
        }
        if (rng() % 8 == 0) x = special(x);
        if (rng() % 8 == 0) y = special(y);
        if (rng() % 16 == 0) y = (rng() & 0x807fffff) | ((128 - ((x >> 23) & 0xff) + rng() % 6) & 0xff) << 23;
        t->x = x; t->y = y; t->sub = rng() & 1; t->trunc = (rng() % 4) == 0;
        for (;;) {
            t->clk = 0; t->eval();
            t->en = !t->busy;
            if (t->busy) stalls++;
            t->clk = 1; t->eval();
            if (t->en) break;
        }
        hx[2] = hx[1]; hx[1] = hx[0]; hx[0] = x; hy[2] = hy[1]; hy[1] = hy[0]; hy[0] = y;
        t->clk = 0; t->eval();
        if (i >= 1) {
            checked++;
            if (t->bad_add && bad_add++ < 10)
                printf("add mismatch %ld: %08x %08x got %08x want %08x\n", i, hx[0], hy[0], t->got, t->want);
            if (t->bad_mul && bad_mul++ < 10)
                printf("mul mismatch %ld: %08x %08x got %08x want %08x\n", i, hx[0], hy[0], t->got, t->want);
        }
    }
    printf("%ld checked, %ld slow-path clocks, add %ld bad, mul %ld bad\n", checked, stalls, bad_add, bad_mul);
    delete t;
    return bad_add + bad_mul != 0;
}
