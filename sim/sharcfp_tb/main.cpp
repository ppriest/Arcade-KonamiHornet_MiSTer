// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/cpu/sharc/sharc_fp_pkg.sv against MAME's own arithmetic. The reference functions below
// are the bodies of src/devices/cpu/sharc/compute.hxx (MAME 0.289, BSD-3-Clause, Ville Linde),
// reduced to (result, ASTAT bits set, STKY bits set) and evaluated with the host's floats, as
// MAME does. Build with SSE float semantics, no -ffast-math.
//
//     scripts/run_verilator.sh sharcfp_tb [+n=2000000] [+seed=1]

#include "Vtb_sharcfp.h"
#include "verilated.h"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <random>

double sc_time_stamp() { return 0; }

enum : uint32_t { AZ = 1, AV = 2, AN = 4, AC = 8, AS = 0x10, AI = 0x20, MN = 0x40, MV = 0x80,
                  MU = 0x100, MI = 0x200, AF = 0x400 };
enum : uint32_t { AUS = 1, AVS = 2, AIS = 0x20, MVS = 0x80, MUS = 0x100, MIS = 0x200 };
static const uint32_t NAN_ = 0xffffffff, INF = 0x7f800000, SIGN = 0x80000000;

static float F(uint32_t r) { float f; memcpy(&f, &r, 4); return f; }
static uint32_t R(float f) { uint32_t r; memcpy(&r, &f, 4); return r; }
static bool is_zero(uint32_t r) { return (r & 0x7fffffff) == 0; }
static bool is_den(uint32_t r) { return (r & INF) == 0 && (r & 0x7fffff); }
static bool is_dz(uint32_t r) { return (r & INF) == 0; }
static bool is_nan(uint32_t r) { return (r & INF) == INF && (r & 0x7fffff); }
static bool is_inf(uint32_t r) { return (r & 0x7fffffff) == INF; }
static uint32_t flush(uint32_t r) { return is_dz(r) ? (r & SIGN) : r; }
static bool nan_add(uint32_t a, uint32_t b) {
    bool ae = (a & INF) == INF, be = (b & INF) == INF;
    return (ae && (a & 0x7fffff)) || (be && (b & 0x7fffff)) || (ae && be && ((a ^ b) & SIGN));
}
static bool nan_sub(uint32_t a, uint32_t b) {
    bool ae = (a & INF) == INF, be = (b & INF) == INF;
    return (ae && (a & 0x7fffff)) || (be && (b & 0x7fffff)) || (ae && be && !((a ^ b) & SIGN));
}
static bool nan_mul(uint32_t a, uint32_t b) {
    bool ae = (a & INF) == INF, be = (b & INF) == INF;
    return (ae && ((a & 0x7fffff) || is_zero(b))) || (be && ((b & 0x7fffff) || is_zero(a)));
}

struct Res { uint32_t r = 0, r2 = 0, astat = 0, stky = 0; };

static Res fin(float f, bool trunc) {
    Res o; o.r = R(f);
    if (is_inf(o.r)) { o.astat |= AV; o.stky |= AVS; if (trunc) o.r = (o.r & SIGN) | 0x7f7fffff; }
    else if (is_dz(o.r)) { o.astat |= AZ; o.stky |= (o.r & 0x7fffff) ? AUS : 0; o.r &= SIGN; }
    o.astat |= (o.r & SIGN) ? AN : 0;
    o.astat |= AF;
    return o;
}
static Res invalid(uint32_t a = AI, uint32_t s = AIS) { Res o; o.r = NAN_; o.astat = a; o.stky = s; return o; }

static uint32_t scalb(uint32_t fx, uint32_t ry, uint32_t &astat) {
    uint32_t m = fx & 0x7fffff, s = fx & SIGN;
    int e = int((fx >> 23) & 0xff) - 127;
    e += int32_t(ry);
    if (e > 127) { astat |= AV; return s | INF; }
    if (e < -126) { astat |= AZ; return s; }
    return s | (uint32_t((e + 127) & 0xff) << 23) | m;
}

extern const uint32_t recips_lut[128], rsqrts_lut[128];

static Res ref(int op, uint32_t x, uint32_t y, bool trunc, uint32_t astat_in) {
    Res o;
    switch (op) {
    case 0: if (nan_add(x, y)) { o = invalid(); o.astat |= AF; return o; } return fin(F(flush(x)) + F(flush(y)), trunc);
    case 1: if (nan_sub(x, y)) { o = invalid(); o.astat |= AF; return o; } return fin(F(flush(x)) - F(flush(y)), trunc);
    case 2: if (nan_add(x, y)) { o = invalid(); o.astat |= AF; return o; } return fin((F(flush(x)) + F(flush(y))) * 0.5f, trunc);
    case 3: {
        bool xe = (x & INF) == INF, ye = (y & INF) == INF;
        if ((xe && (x & 0x7fffff)) || (ye && (y & 0x7fffff))) { o.r = o.r2 = NAN_; o.astat = AI; o.stky = AIS; }
        else if (!xe || !ye) {
            Res a = fin(F(flush(x)) + F(flush(y)), trunc), s = fin(F(flush(x)) - F(flush(y)), trunc);
            o.r = a.r; o.r2 = s.r;
            o.astat = (a.astat | s.astat) & ~AN; o.stky = a.stky | s.stky;
            if ((a.r | s.r) & SIGN) o.astat |= AN;
        } else {
            uint32_t pat = (x & SIGN) | (trunc ? 0x7f7fffff : INF);
            // compute.hxx assigns this integer to the float member (an int -> float conversion)
            if ((x ^ y) & SIGN) { o.r = NAN_; o.r2 = R(float(pat)); }
            else { o.r = R(float(pat)); o.r2 = NAN_; }
            o.astat = ((x & SIGN) ? AN : 0) | AV | AI; o.stky = AVS | AIS;
        }
        o.astat |= AF;
        return o;
    }
    case 4:
        if (is_nan(x)) o = invalid();
        else { if (is_dz(x)) { o.r = 0; o.astat = AZ; } else o.r = x & ~SIGN; o.astat |= (x & SIGN) ? AS : 0; }
        o.astat |= AF; return o;
    case 5: case 6:
        if (is_nan(x) || is_nan(y)) o = invalid();
        else {
            o.r = R(op == 5 ? std::min(F(x), F(y)) : std::max(F(x), F(y)));
            o.astat |= (F(o.r) < 0.0f) ? AN : 0; o.astat |= is_zero(o.r) ? AZ : 0;
        }
        o.astat |= AF; return o;
    case 7:
        if (is_nan(x)) o = invalid();
        else { if (is_dz(x)) { o.r = ~x & SIGN; o.astat = AZ; } else o.r = x ^ SIGN; o.astat |= (o.r & SIGN) ? AN : 0; }
        o.astat |= AF; return o;
    case 8:
        if (is_nan(x)) o = invalid();
        else { if (is_dz(x)) { o.r = x & SIGN; o.astat = AZ; } else o.r = x; o.astat |= (o.r & SIGN) ? AN : 0; }
        o.astat |= AF; return o;
    case 9: {
        uint32_t a = astat_in & ~(AZ | AN | AV | AC | AS | AI);
        uint32_t add = 0;
        if (is_nan(x) || is_nan(y)) { add = AI; o.stky = AIS; }
        else if (F(x) == F(y)) add = AZ;
        else if (F(x) < F(y)) add = AN;
        a |= add;
        uint32_t acc = (a >> 1) & 0x7f000000;
        if ((a & (AZ | AN)) == 0) acc |= 0x80000000;
        o.r = acc; o.astat = add | AF;
        return o;
    }
    case 10:
        if (is_nan(x)) o = invalid();
        else {
            uint32_t a = 0; o.r = scalb(x, y, a);
            o.astat |= (o.r & SIGN) ? AN : 0; o.astat |= is_zero(o.r) ? AZ : 0; o.stky |= is_den(o.r) ? AUS : 0;
        }
        o.astat |= AF; return o;
    case 11:
        if (is_inf(x)) { o.r = INF; o.astat = AV; }
        else if (is_zero(x)) { o.r = SIGN | INF; o.astat = AV; }
        else if (is_nan(x)) o = invalid();
        else { int e = int((x >> 23) & 0xff) - 127; o.r = e; o.astat |= (o.r & SIGN) ? AN : 0; o.astat |= e == 0 ? AZ : 0; }
        o.astat |= AF; return o;
    case 12: case 13: case 14: {
        uint32_t a = 0, v = op == 12 ? x : scalb(x, y, a);
        int32_t i;
        if (trunc) i = (op == 14) ? int32_t(F(v)) : int32_t(floorf(F(v)));
        else i = int32_t(nearbyintf(F(v)));
        o.r = i; o.astat |= (o.r & SIGN) ? AN : 0; o.astat |= i == 0 ? AZ : 0;
        o.stky |= is_den(v) ? AUS : 0; o.astat |= is_nan(x) ? AI : 0; o.astat |= AF;
        return o;
    }
    case 15: case 16: case 17: {
        uint32_t a = 0; o.r = R(float(int32_t(x)));
        if (op != 15) o.r = scalb(o.r, y, a);
        if (op == 17) o.astat |= (F(o.r) < 0.0f) ? AN : 0; else o.astat |= (o.r & SIGN) ? AN : 0;
        o.astat |= is_dz(o.r) ? AZ : 0; o.stky |= is_den(o.r) ? AUS : 0; o.astat |= AF;
        return o;
    }
    case 18:
        if (is_nan(x)) o = invalid();
        else if (is_zero(x)) { o.r = (x & SIGN) | INF; o.astat = AV; }
        else {
            uint32_t m = x & 0x7fffff, s = x & SIGN;
            int e = -(int((x >> 23) & 0xff) - 127) - 1;
            uint32_t rm = recips_lut[m >> 16];
            if (e > 125 || e < -126) { e = 0; rm = 0; } else e = (e + 127) & 0xff;
            o.r = s | (uint32_t(e) << 23) | rm;
            o.astat |= (x & SIGN) ? AN : 0; o.astat |= is_zero(o.r) ? AZ : 0;
        }
        o.astat |= AF; return o;
    case 19: {
        if (x > 0x80000000) o.r = NAN_;
        else if (is_nan(x)) o.r = NAN_;
        else {
            uint32_t m = x & 0xffffff, s = x & SIGN;
            int e = -((int((x >> 23) & 0xff) - 127) >> 1) - 1;
            o.r = s | (uint32_t((e + 127) & 0xff) << 23) | rsqrts_lut[m >> 17];
        }
        o.astat |= (x == 0x80000000) ? AN : 0; o.astat |= is_zero(o.r) ? AZ : 0; o.astat |= is_zero(x) ? AV : 0;
        o.astat |= (is_nan(x) || (x & SIGN)) ? AI : 0; if (o.astat & AI) o.stky |= AIS;
        o.astat |= AF; return o;
    }
    case 20:
        if (is_nan(x) || is_nan(y)) o = invalid();
        else { o.r = y & SIGN; o.astat |= o.r ? AN : 0; if (is_dz(x)) o.astat |= AZ; else o.r |= x & ~SIGN; }
        o.astat |= AF; return o;
    case 21:
        if (is_nan(x) || is_nan(y)) o = invalid();
        else {
            if (is_dz(x) || is_dz(y)) { o.r = x & SIGN; o.astat |= AZ; }
            else { o.r = R(std::clamp(F(x), F(y | SIGN), F(y & ~SIGN))); o.astat |= is_zero(o.r) ? AZ : 0; }
            o.astat |= (o.r & SIGN) ? AN : 0;
        }
        o.astat |= AF; return o;
    case 22:
        if (nan_mul(x, y)) return invalid(MI, MIS);
        o.r = R(F(x) * F(y));
        o.astat |= (o.r & SIGN) ? MN : 0; o.astat |= is_inf(o.r) ? MV : 0; o.astat |= is_den(o.r) ? MU : 0;
        o.stky |= is_inf(o.r) ? MVS : 0; o.stky |= is_den(o.r) ? MUS : 0;
        return o;
    }
    return o;
}

const uint32_t recips_lut[128] = {
    0x007f8000, 0x007e0000, 0x007c0000, 0x007a0000, 0x00780000, 0x00760000, 0x00740000, 0x00720000,
    0x00700000, 0x006f0000, 0x006d0000, 0x006b0000, 0x006a0000, 0x00680000, 0x00660000, 0x00650000,
    0x00630000, 0x00610000, 0x00600000, 0x005e0000, 0x005d0000, 0x005b0000, 0x005a0000, 0x00590000,
    0x00570000, 0x00560000, 0x00540000, 0x00530000, 0x00520000, 0x00500000, 0x004f0000, 0x004e0000,
    0x004c0000, 0x004b0000, 0x004a0000, 0x00490000, 0x00470000, 0x00460000, 0x00450000, 0x00440000,
    0x00430000, 0x00410000, 0x00400000, 0x003f0000, 0x003e0000, 0x003d0000, 0x003c0000, 0x003b0000,
    0x003a0000, 0x00390000, 0x00380000, 0x00370000, 0x00360000, 0x00350000, 0x00340000, 0x00330000,
    0x00320000, 0x00310000, 0x00300000, 0x002f0000, 0x002e0000, 0x002d0000, 0x002c0000, 0x002b0000,
    0x002a0000, 0x00290000, 0x00280000, 0x00280000, 0x00270000, 0x00260000, 0x00250000, 0x00240000,
    0x00230000, 0x00230000, 0x00220000, 0x00210000, 0x00200000, 0x001f0000, 0x001f0000, 0x001e0000,
    0x001d0000, 0x001c0000, 0x001c0000, 0x001b0000, 0x001a0000, 0x00190000, 0x00190000, 0x00180000,
    0x00170000, 0x00170000, 0x00160000, 0x00150000, 0x00140000, 0x00140000, 0x00130000, 0x00120000,
    0x00120000, 0x00110000, 0x00100000, 0x00100000, 0x000f0000, 0x000f0000, 0x000e0000, 0x000d0000,
    0x000d0000, 0x000c0000, 0x000c0000, 0x000b0000, 0x000a0000, 0x000a0000, 0x00090000, 0x00090000,
    0x00080000, 0x00070000, 0x00070000, 0x00060000, 0x00060000, 0x00050000, 0x00050000, 0x00040000,
    0x00040000, 0x00030000, 0x00030000, 0x00020000, 0x00020000, 0x00010000, 0x00010000, 0x00000000,
};
const uint32_t rsqrts_lut[128] = {
    0x00350000, 0x00330000, 0x00320000, 0x00300000, 0x002f0000, 0x002e0000, 0x002d0000, 0x002b0000,
    0x002a0000, 0x00290000, 0x00280000, 0x00270000, 0x00260000, 0x00250000, 0x00230000, 0x00220000,
    0x00210000, 0x00200000, 0x001f0000, 0x001e0000, 0x001e0000, 0x001d0000, 0x001c0000, 0x001b0000,
    0x001a0000, 0x00190000, 0x00180000, 0x00170000, 0x00160000, 0x00160000, 0x00150000, 0x00140000,
    0x00130000, 0x00130000, 0x00120000, 0x00110000, 0x00100000, 0x00100000, 0x000f0000, 0x000e0000,
    0x000e0000, 0x000d0000, 0x000c0000, 0x000b0000, 0x000b0000, 0x000a0000, 0x000a0000, 0x00090000,
    0x00080000, 0x00080000, 0x00070000, 0x00070000, 0x00060000, 0x00050000, 0x00050000, 0x00040000,
    0x00040000, 0x00030000, 0x00030000, 0x00020000, 0x00020000, 0x00010000, 0x00010000, 0x00000000,
    0x007f8000, 0x007e0000, 0x007c0000, 0x007a0000, 0x00780000, 0x00760000, 0x00740000, 0x00730000,
    0x00710000, 0x006f0000, 0x006e0000, 0x006c0000, 0x006a0000, 0x00690000, 0x00670000, 0x00660000,
    0x00640000, 0x00630000, 0x00620000, 0x00600000, 0x005f0000, 0x005e0000, 0x005c0000, 0x005b0000,
    0x005a0000, 0x00590000, 0x00570000, 0x00560000, 0x00550000, 0x00540000, 0x00530000, 0x00520000,
    0x00510000, 0x004f0000, 0x004e0000, 0x004d0000, 0x004c0000, 0x004b0000, 0x004a0000, 0x00490000,
    0x00480000, 0x00470000, 0x00460000, 0x00450000, 0x00450000, 0x00440000, 0x00430000, 0x00420000,
    0x00410000, 0x00400000, 0x003f0000, 0x003e0000, 0x003e0000, 0x003d0000, 0x003c0000, 0x003b0000,
    0x003a0000, 0x003a0000, 0x00390000, 0x00380000, 0x00370000, 0x00370000, 0x00360000, 0x00350000,
};

static const char *NAMES[] = {"FADD", "FSUB", "FAVG", "FADD/FSUB", "FABS", "FMIN", "FMAX", "FNEG",
    "FPASS", "FCOMP", "SCALB", "LOGB", "FIX", "FIX BY", "FIX BY (multi)", "FLOAT", "FLOAT BY",
    "FLOAT BY (multi)", "RECIPS", "RSQRTS", "COPYSIGN", "FCLIP", "FMUL"};
static const int NOPS = 23;

// operands biased toward the edges: zeros, denormals, infinities, NaNs, near-equal pairs
static uint32_t pick(std::mt19937 &g, uint32_t other) {
    uint32_t r = g();
    switch (g() % 16) {
    case 0: return r & SIGN;                                    // +-0
    case 1: return (r & SIGN) | (r & 0x7fffff);                 // denormal
    case 2: return (r & SIGN) | INF;                            // +-inf
    case 3: return (r & SIGN) | INF | ((r >> 1) & 0x7fffff) | 1;// NaN
    case 4: return other ^ (r & 0xf) ^ (r & SIGN);              // cancellation
    case 5: return (r & 0x807fffff) | (((127 + int(r % 60) - 30) & 0xff) << 23);
    case 6: return (r & 0x807fffff) | 0x00800000;               // smallest exponent
    case 7: return (r & 0x807fffff) | 0x7f000000;               // largest exponent
    case 8: return int32_t(r) >> (r & 31);                      // integers for FLOAT
    case 9: return uint32_t(int32_t(r % 64) - 32);              // small scales
    default: return r;
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *s;
    long n = (s = Verilated::commandArgsPlusMatch("n=")) && *s ? atol(s + 3) : 2000000;
    unsigned seed = (s = Verilated::commandArgsPlusMatch("seed=")) && *s ? atoi(s + 6) : 1;
    std::mt19937 g(seed);
    Vtb_sharcfp *t = new Vtb_sharcfp;
    long fails[NOPS] = {0}, runs[NOPS] = {0};
    for (long i = 0; i < n; i++) {
        int op = i % NOPS;
        uint32_t x = pick(g, 0), y = pick(g, x), a = g();
        bool trunc = (g() & 7) == 0;
        t->op = op; t->x = x; t->y = y; t->trunc = trunc; t->astat_in = a;
        t->eval();
        Res e = ref(op, x, y, trunc, a);
        bool two = op == 3;
        bool bad = t->r != e.r || t->astat != e.astat || t->stky != e.stky || (two && t->r2 != e.r2);
        runs[op]++;
        if (bad && fails[op]++ < 5)
            printf("%-16s x=%08X y=%08X trunc=%d: RTL r=%08X r2=%08X astat=%08X stky=%08X, "
                   "MAME r=%08X r2=%08X astat=%08X stky=%08X\n", NAMES[op], x, y, trunc,
                   t->r, t->r2, t->astat, t->stky, e.r, e.r2, e.astat, e.stky);
    }
    long total = 0;
    for (int op = 0; op < NOPS; op++) {
        printf("%-16s %9ld vectors, %ld mismatches\n", NAMES[op], runs[op], fails[op]);
        total += fails[op];
    }
    printf(total ? "FAIL: %ld mismatches\n" : "PASS\n", total);
    delete t;
    return total ? 1 : 0;
}
