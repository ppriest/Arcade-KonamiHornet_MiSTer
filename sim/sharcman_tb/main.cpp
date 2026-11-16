// SPDX-License-Identifier: GPL-3.0-or-later
//
// sharc_fp_pkg's man_* functions and the v2 units at MAME_RND 0 against the ADSP-2106x SHARC
// User's Manual (rev 2.1), the rules of each Appendix B entry as docs/MAME_KLUDGES.md "SHARC at
// MAME_RND 0" lists them, page by page. The reference works on values, not fields: the exact
// result in long double (a sum the format cannot hold is computed toward zero, with the inexact
// flag as the sticky bit), then rounded at 24 bits by its own code. Where the manual is silent
// the reference follows the choices that section lists.
//
//     scripts/run_verilator.sh sharcman_tb [+n=100000000] [+seed=1]

#include "Vtb_sharcman.h"
#include "verilated.h"
#include <algorithm>
#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>

#pragma STDC FENV_ACCESS ON

double sc_time_stamp() { return 0; }

typedef long double LD;

enum : uint32_t { AZ = 1, AV = 2, AN = 4, AC = 8, AS = 0x10, AI = 0x20, MN = 0x40, MV = 0x80,
                  MU = 0x100, MI = 0x200, AF = 0x400 };
enum : uint32_t { AUS = 1, AVS = 2, AIS = 0x20, MVS = 0x80, MUS = 0x100, MIS = 0x200 };
static const uint32_t NAN_ = 0xffffffff, INF = 0x7f800000, SIGN = 0x80000000, MAXF = 0x7f7fffff,
                      ALL1 = 0xffffffff;

static bool is_zero(uint32_t r) { return (r & 0x7fffffff) == 0; }
static bool is_dz(uint32_t r) { return (r & INF) == 0; }
static bool is_nan(uint32_t r) { return (r & INF) == INF && (r & 0x7fffff); }
static bool is_inf(uint32_t r) { return (r & 0x7fffffff) == INF; }
static uint32_t flush(uint32_t r) { return is_dz(r) ? (r & SIGN) : r; }       // p. 2-3

// the value of a finite float
static LD val(uint32_t r) {
    int e = (r >> 23) & 0xff;
    uint32_t m = r & 0x7fffff;
    LD v = e ? ldexpl((LD)(m | 0x800000), e - 150) : ldexpl((LD)m, -149);
    return (r & SIGN) ? -v : v;
}

// v (nonzero) at 24 bits. `inexact`: the true magnitude is a little more than |v|.
//   RND32 set: toward zero under TRUNC, else to nearest even (p. 2-7, 2-15); underflow and
//     overflow of the post-rounded result, exponent unbounded (p. 2-8, 2-16, 2-17).
//   RND32 clear: 40-bit results, not built: to nearest at 24 bits, underflow and overflow
//     decided on the exact value, a round-up to 2^128 giving NORM.MAX.
// An overflow gives +-infinity, or +-NORM.MAX under TRUNC (B-24); an underflow +-0.
struct Rnd { uint32_t r; bool ovf, tiny; };
static bool c_tie, c_tiny, c_ovf;                     // coverage of the vector just checked
static Rnd round24(LD v, bool inexact, bool trunc, bool rnd32) {
    Rnd o = {0, false, false};
    uint32_t sg = std::signbit(v) ? SIGN : 0;
    LD a = fabsl(v);
    int ex;
    frexpl(a, &ex);
    int E = ex - 1;                                   // 2^E <= a < 2^(E+1)
    LD q = ldexpl(a, 23 - E);
    LD fl = floorl(q), fr = q - fl;
    uint64_t mi = (uint64_t)fl;
    bool rz = trunc && rnd32;
    bool up = !rz && (fr > 0.5L || (fr == 0.5L && (inexact || (mi & 1))));
    if (fr == 0.5L && !inexact) c_tie = true;
    mi += up;
    int Er = E;
    if (mi == (1ull << 24)) { mi >>= 1; Er++; }
    bool tiny = rnd32 ? Er < -126 : E < -126;
    bool ovf = rnd32 ? Er > 127 : E > 127;
    if (ovf) { o.ovf = c_ovf = true; o.r = sg | (trunc ? MAXF : INF); return o; }
    if (tiny) { o.tiny = c_tiny = true; o.r = sg; return o; }
    if (Er > 127) { o.r = sg | MAXF; return o; }
    o.r = sg | (uint32_t(Er + 127) << 23) | uint32_t(mi & 0x7fffff);
    return o;
}

struct Res { uint32_t r = 0, r2 = 0, astat = 0, stky = 0; };

static bool nan_add(uint32_t a, uint32_t b, bool sub) {
    bool ae = (a & INF) == INF, be = (b & INF) == INF;
    bool opp = ((a ^ b) & SIGN) != 0;
    return (ae && (a & 0x7fffff)) || (be && (b & 0x7fffff)) || (ae && be && (sub ? !opp : opp));
}

// Fn = Fx + Fy, Fx - Fy (B-24, B-25), (Fx + Fy)/2 (B-28, rounded once)
static Res alu(uint32_t x, uint32_t y, bool trunc, bool rnd32, bool sub, bool avg) {
    Res o;
    if (nan_add(x, y, sub)) { o.r = NAN_; o.astat = AI | AF; o.stky = AIS; return o; }
    uint32_t xf = flush(x), yf = flush(y) ^ (sub ? SIGN : 0);
    if (is_inf(xf) || is_inf(yf)) {                   // the manual is silent: an infinity is kept,
        uint32_t s = (is_inf(xf) ? xf : yf) & SIGN;   // as MAME, NORM.MAX under TRUNC, with AV
        o.r = s | (trunc ? MAXF : INF); o.astat = AV; o.stky = AVS;
    } else {
        volatile LD a = val(xf), b = val(yf);
        fesetround(FE_TOWARDZERO);
        feclearexcept(FE_INEXACT);
        volatile LD s = a + b;
        bool inexact = fetestexcept(FE_INEXACT) != 0;
        fesetround(FE_TONEAREST);
        LD v = avg ? ldexpl(s, -1) : (LD)s;
        if (v == 0) { o.r = std::signbit(v) ? SIGN : 0; o.astat = AZ; }
        else {
            Rnd q = round24(v, inexact, trunc, rnd32);
            o.r = q.r;
            if (q.ovf) { o.astat |= AV; o.stky |= AVS; }
            if (q.tiny) { o.astat |= AZ; o.stky |= AUS; }
        }
    }
    if (o.r & SIGN) o.astat |= AN;
    o.astat |= AF;
    return o;
}

// Fn = Fx * Fy (B-53; p. 2-16, 2-17)
static Res mul(uint32_t x, uint32_t y, bool trunc, bool rnd32) {
    Res o;
    uint32_t xf = flush(x), yf = flush(y), sg = (xf ^ yf) & SIGN;
    bool xe = (xf & INF) == INF, ye = (yf & INF) == INF;
    if ((xe && ((xf & 0x7fffff) || is_zero(yf))) || (ye && ((yf & 0x7fffff) || is_zero(xf)))) {
        o.r = NAN_; o.astat = MI; o.stky = MIS; return o;
    }
    if (xe || ye) { o.r = sg | INF; o.astat = MV; o.stky = MVS; }      // silent: infinity, as MAME
    else if (is_zero(xf) || is_zero(yf)) o.r = sg;
    else {
        Rnd q = round24(val(xf) * val(yf), false, trunc, rnd32);   // 48 bits: exact
        o.r = q.r;
        if (q.ovf) { o.astat |= MV; o.stky |= MVS; }
        if (q.tiny) { o.astat |= MU; o.stky |= MUS; }
    }
    if (o.r & SIGN) o.astat |= MN;
    return o;
}

// Rn = FIX Fx [BY Ry] (B-37)
static Res fix(uint32_t x, bool by, uint32_t ry, bool trunc, bool alusat) {
    Res o;
    uint32_t xf = flush(x);
    int64_t E = int64_t((xf >> 23) & 0xff) - 127 + (by ? int64_t(int32_t(ry)) : 0);
    if (is_nan(xf)) { o.r = ALL1; o.astat = AI; o.stky = AIS; }
    else if (is_inf(xf) || (!is_zero(xf) && E >= 31)) {
        o.astat = AV; c_ovf = true;
        if (alusat) o.r = (xf & SIGN) ? 0x80000000 : 0x7fffffff;
        else { o.r = ALL1; o.astat |= AI; o.stky = AIS; }
    } else if (!is_zero(xf)) {
        bool neg = xf & SIGN;
        if (E < -126) o.stky = AUS;
        int64_t i;
        if (E < -64) i = (trunc && neg) ? -1 : 0;
        else {
            LD v = ldexpl(val(xf), by ? int(int32_t(ry)) : 0);
            i = int64_t(trunc ? floorl(v) : nearbyintl(v));
            if (v - floorl(v) == 0.5L) c_tie = true;
            if (v < 0 && v > -1) c_tiny = true;
        }
        o.r = uint32_t(int32_t(i));
    }
    if (o.r & SIGN) o.astat |= AN;
    if (o.r == 0) o.astat |= AZ;
    o.astat |= AF;
    return o;
}

// Fn = FLOAT Rx [BY Ry] (B-38)
static Res flt(uint32_t x, bool by, uint32_t ry, bool trunc, bool rnd32) {
    Res o;
    int32_t i = int32_t(x);
    if (i != 0) {
        LD a = fabsl((LD)i);
        uint32_t sg = i < 0 ? SIGN : 0;
        int ex;
        frexpl(a, &ex);
        int64_t E = int64_t(ex - 1) + (by ? int64_t(int32_t(ry)) : 0);
        if (E > 127) { o.r = sg | (trunc ? MAXF : INF); o.astat = AV; o.stky = AVS; c_ovf = true; }
        else if (E < -126) { o.r = sg; o.stky = AUS; c_tiny = true; }
        else {
            LD q = ldexpl(a, 23 - (ex - 1)), fl = floorl(q), fr = q - fl;
            uint64_t m = (uint64_t)fl;
            if (fr != 0) c_tie = true;                // bits below 24: the "halfway" column
            if (!rnd32 && (fr > 0.5L || (fr == 0.5L && (m & 1)))) m++;
            if (m == (1ull << 24)) { m >>= 1; E++; }
            if (E > 127) o.r = sg | MAXF;
            else o.r = sg | (uint32_t(E + 127) << 23) | uint32_t(m & 0x7fffff);
        }
    }
    if (o.r & SIGN) o.astat |= AN;
    if (is_zero(o.r)) o.astat |= AZ;
    o.astat |= AF;
    return o;
}

static int cmpv(uint32_t a, uint32_t b) {             // finite or infinite, flushed
    LD va = is_inf(a) ? ((a & SIGN) ? -INFINITY : INFINITY) : val(a);
    LD vb = is_inf(b) ? ((b & SIGN) ? -INFINITY : INFINITY) : val(b);
    return va < vb ? -1 : va > vb ? 1 : 0;
}

extern const uint32_t recips_lut[128], rsqrts_lut[128];

static Res ref(int op, uint32_t x, uint32_t y, bool trunc, bool rnd32, bool alusat, uint32_t astat_in) {
    Res o;
    uint32_t xf = flush(x), yf = flush(y);
    switch (op) {
    case 0: return alu(x, y, trunc, rnd32, false, false);
    case 1: return alu(x, y, trunc, rnd32, true, false);
    case 2: return alu(x, y, trunc, rnd32, false, true);
    case 3: {                                         // B-78
        if (is_nan(x) || is_nan(y)) { o.r = o.r2 = NAN_; o.astat = AI | AF; o.stky = AIS; return o; }
        Res a = alu(x, y, trunc, rnd32, false, false), s = alu(x, y, trunc, rnd32, true, false);
        o.r = a.r; o.r2 = s.r;
        o.astat = ((a.astat | s.astat) & ~AN) | AF;
        if ((!(a.astat & AI) && (a.r & SIGN)) || (!(s.astat & AI) && (s.r & SIGN))) o.astat |= AN;
        o.stky = a.stky | s.stky;
        return o;
    }
    case 4: return mul(x, y, trunc, rnd32);
    case 5: return fix(x, false, 0, trunc, alusat);
    case 6: return fix(x, true, y, trunc, alusat);
    case 7: return flt(x, false, 0, trunc, rnd32);
    case 8: return flt(x, true, y, trunc, rnd32);
    case 9: {                                         // COMP (B-29)
        uint32_t a = astat_in & ~(AZ | AN | AV | AC | AS | AI), add = 0;
        if (is_nan(xf) || is_nan(yf)) { add = AI; o.stky = AIS; }
        else if (cmpv(xf, yf) == 0) add = AZ;
        else if (cmpv(xf, yf) < 0) add = AN;
        a |= add;
        uint32_t acc = (a >> 1) & 0x7f000000;
        if ((a & (AZ | AN)) == 0) acc |= 0x80000000;
        o.r = acc; o.astat = add | AF;
        return o;
    }
    case 10: case 11:                                 // MIN, MAX (B-42, B-43)
        if (is_nan(xf) || is_nan(yf)) { o.r = NAN_; o.astat = AI | AF; o.stky = AIS; return o; }
        if (is_zero(xf) && is_zero(yf)) o.r = op == 10 ? ((xf | yf) & SIGN) : (xf & yf & SIGN);
        else o.r = (op == 10) == (cmpv(xf, yf) <= 0) ? xf : yf;
        if (is_zero(o.r)) o.astat |= AZ;
        break;
    case 12: {                                        // SCALB (B-34)
        if (is_nan(xf)) { o.r = NAN_; o.astat = AI | AF; o.stky = AIS; return o; }
        int64_t E = int64_t((xf >> 23) & 0xff) - 127 + int64_t(int32_t(y));
        if (is_zero(xf)) o.r = xf;                    // silent: +-0
        else if (is_inf(xf) || E > 127) { o.r = (xf & SIGN) | (trunc ? MAXF : INF); o.astat = AV; o.stky = AVS; }
        else if (E < -126) { o.r = xf & SIGN; o.stky = AUS; }
        else o.r = (xf & 0x807fffff) | (uint32_t(E + 127) << 23);
        if (is_zero(o.r)) o.astat |= AZ;
        break;
    }
    case 13:                                          // LOGB (B-36)
        if (is_nan(xf)) { o.r = ALL1; o.astat = AI; o.stky = AIS; }
        else if (is_inf(xf)) { o.r = alusat ? 0x7fffffff : INF; o.astat = AV; }
        else if (is_zero(xf)) { o.r = alusat ? 0x80000000 : (SIGN | INF); o.astat = AV; }
        else o.r = uint32_t(int32_t((xf >> 23) & 0xff) - 127);
        if (o.r == 0) o.astat |= AZ;
        break;
    case 14:                                          // RECIPS (B-39), MAME's seed
        if (is_nan(xf)) { o.r = NAN_; o.astat = AI | AF; o.stky = AIS; return o; }
        if (is_zero(xf)) { o.r = xf | INF; o.astat = AV; }
        else if (int((xf >> 23) & 0xff) - 127 > 125) { o.r = xf & SIGN; o.astat = AZ; }
        else o.r = (xf & SIGN) | (uint32_t(-(int((xf >> 23) & 0xff) - 127) - 1 + 127) << 23) | recips_lut[(xf >> 16) & 0x7f];
        o.astat |= (xf & SIGN) ? AN : 0; o.astat |= AF;
        return o;
    case 15:                                          // RSQRTS (B-40), MAME's seed
        if (is_nan(xf) || ((xf & SIGN) && !is_zero(xf))) { o.r = ALL1; o.astat = AI; o.stky = AIS; }
        else if (is_zero(xf)) { o.r = xf | INF; o.astat = AV; }
        else if (is_inf(xf)) { o.r = 0; o.astat = AZ; }
        else o.r = (uint32_t((-((int((xf >> 23) & 0xff) - 127) >> 1) - 1 + 127) & 0xff) << 23) | rsqrts_lut[(xf >> 17) & 0x7f];
        if (xf == SIGN) o.astat |= AN;
        o.astat |= AF;
        return o;
    case 16:                                          // ABS (B-31)
        if (is_nan(x)) { o.r = NAN_; o.astat = AI | AF; o.stky = AIS; return o; }
        o.r = xf & ~SIGN; if (is_zero(o.r)) o.astat = AZ; if (x & SIGN) o.astat |= AS;
        o.astat |= AF; return o;
    case 17:                                          // PASS (B-32)
        if (is_nan(x)) { o.r = NAN_; o.astat = AI | AF; o.stky = AIS; return o; }
        o.r = xf; if (is_zero(o.r)) o.astat |= AZ;
        break;
    case 18:                                          // -Fx (B-30)
        if (is_nan(x)) { o.r = NAN_; o.astat = AI | AF; o.stky = AIS; return o; }
        o.r = xf ^ SIGN; if (is_zero(o.r)) o.astat |= AZ;
        break;
    case 19:                                          // COPYSIGN (B-41)
        if (is_nan(x) || is_nan(y)) { o.r = NAN_; o.astat = AI | AF; o.stky = AIS; return o; }
        o.r = (y & SIGN) | (xf & ~SIGN); if (is_zero(o.r)) o.astat |= AZ;
        break;
    default: {                                        // CLIP (B-44)
        if (is_nan(x) || is_nan(y)) { o.r = NAN_; o.astat = AI | AF; o.stky = AIS; return o; }
        uint32_t ax = xf & ~SIGN, ay = yf & ~SIGN;
        o.r = cmpv(ax, ay) < 0 ? xf : ((xf & SIGN) | ay);
        if (is_zero(o.r)) o.astat |= AZ;
        break;
    }
    }
    if (o.r & SIGN) o.astat |= AN;
    o.astat |= AF;
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

static const char *NAMES[] = {"FADD", "FSUB", "FAVG", "FADD/FSUB", "FMUL", "FIX", "FIX BY",
    "FLOAT", "FLOAT BY", "COMP", "FMIN", "FMAX", "SCALB", "LOGB", "RECIPS", "RSQRTS", "FABS",
    "FPASS", "FNEG", "COPYSIGN", "FCLIP"};
static const int NOPS = 21;

static uint32_t fbits(uint32_t s, int e, uint32_t m) { return (s & SIGN) | (uint32_t(e & 0xff) << 23) | (m & 0x7fffff); }

// float operands: special values, the exponent ends, near cancellation, halfway sums and products
static void pick_f(std::mt19937 &g, int op, uint32_t &x, uint32_t &y) {
    uint32_t r = g(), s = g();
    x = g(); y = g();
    switch (g() % 18) {
    case 0: break;
    case 15: {                                                                 // both special: two infinities, NaNs, zeros, denormals
        static const uint32_t sp[] = {0x7f800000, 0xff800000, 0x7f800000, 0xff800000, 0, SIGN, 0x00000001, 0x80400000, 0x7fc00000};
        x = sp[g() % 9]; y = sp[g() % 9];
        break;
    }
    case 16: {                                                                 // product at 2^128 - a few ulps
        x = fbits(r, 128 + g() % 126, g());
        float f = float(val(MAXF) / val(x));
        uint32_t fy;
        memcpy(&fy, &f, 4);
        y = (fy + int32_t(g() % 7) - 3) ^ (s & SIGN);
        if (is_dz(y) || (y & INF) == INF) y = fbits(s, 1 + g() % 253, g());
        break;
    }
    case 17:                                                                   // sum at 2^128 - a few ulps
        x = fbits(r, 254, 0x7fffff - (g() & 3));
        y = fbits(r, 254 - 24 + int(g() % 3), g() & ((g() & 1) ? 0 : 0x7fffff));
        break;
    case 14: {                                                                 // product at 2^-126 +- a few ulps
        x = fbits(r, 1 + g() % 253, g());
        float f = float(ldexpl(1.0L, -126) / val(x));
        uint32_t fy;
        memcpy(&fy, &f, 4);
        y = (fy + int32_t(g() % 9) - 4) ^ (s & SIGN);
        if (is_dz(y) || (y & INF) == INF) y = fbits(s, 1 + g() % 253, g());
        break;
    }
    case 1: y = x ^ SIGN ^ (r & 0x3f); break;                                   // cancellation
    case 2: y = fbits(s, ((x >> 23) & 0xff) - 24 + int(r % 3) - 1, (r & 1) ? 0 : g()); break; // half an ulp
    case 3: x = fbits(r, 1 + r % 3, g()); y = fbits(s ^ (g() & 1 ? SIGN : 0), 1 + s % 3, g()); break; // near 2^-126
    case 4: x = fbits(r, 250 + r % 5, g()); y = fbits(r, 250 + s % 5, g()); break;    // near 2^128
    case 5: { int ex = 127 + g() % 128; x = fbits(r, ex, g()); y = fbits(s, std::min(254, 381 - ex + int(s % 9) - 4), g()); break; } // product near 2^128
    case 6: { int ex = 1 + g() % 127; x = fbits(r, ex, g()); y = fbits(s, std::max(1, 128 - ex + int(s % 7) - 3), g()); break; }   // product near 2^-126
    case 7: { int ex = 1 + g() % 127; x = fbits(r, ex, 0x7fffff - (g() & 0xff)); y = fbits(s, std::max(1, 127 - ex + int(s % 3)), g() & 0x3ff); break; } // product just under 2^-126
    case 8: y = fbits(s, (s >> 8) % 256, (g() % 8) << 20); break;              // a few-bit factor: product ties
    case 9: x = fbits(r, 1 + r % 4, g()); y = fbits(s, 125 + s % 4, (s & 1) ? 0x7fffff : g()); break; // product around 2^-126
    case 10: x &= 0x807fffff; break;                                           // denormal
    case 11: y &= 0x807fffff; break;
    case 12: x = (r & SIGN) | ((g() & 1) ? INF : 0) | ((g() & 1) ? (g() | 1) & 0x7fffff : 0); break;   // inf, zero, NaN
    default: y = (s & SIGN) | ((g() & 1) ? INF : 0) | ((g() % 4 == 0) ? (g() | 1) & 0x7fffff : 0); break;
    }
    (void)op;
}

// FIX operands: around integers and halves, near 2^31, small; FIX BY scales near the edges
static void pick_fix(std::mt19937 &g, uint32_t &x, uint32_t &y) {
    uint32_t r = g();
    switch (g() % 8) {
    case 0: x = g(); break;
    case 1: { float f = float(int32_t(g()) >> (g() % 31)) + ((g() & 1) ? 0.5f : -0.5f); memcpy(&x, &f, 4); break; }
    case 2: { float f = float(int32_t(g()) >> (g() % 31)); memcpy(&x, &f, 4); x += int32_t(g() % 5) - 2; break; }
    case 3: x = fbits(r, 157 + r % 3, g()); break;                              // near 2^31
    case 4: x = fbits(r, 100 + r % 30, g()); break;                             // under 1
    case 5: x = g() & 0x807fffff; break;                                        // denormal
    case 6: x = fbits(r, 120 + r % 40, (g() % 4) << 21); break;                 // exact halves and quarters
    default: x = (r & SIGN) | ((g() & 1) ? INF : 0) | ((g() & 1) ? 1 : 0); break;
    }
    switch (g() % 4) {
    case 0: y = g(); break;
    case 1: y = uint32_t(int32_t(g() % 64) - 32); break;
    case 2: y = uint32_t(127 + int32_t(g() % 9) - 4 - int32_t((x >> 23) & 0xff) + 127); break;  // to the overflow edge
    default: y = uint32_t(-126 + int32_t(g() % 9) - 4 - int32_t((x >> 23) & 0xff) + 127); break;
    }
}

// FLOAT operands: integers with bits below 24, powers of two and their neighbours, the ends
static void pick_float(std::mt19937 &g, uint32_t &x, uint32_t &y) {
    uint32_t r = g();
    switch (g() % 6) {
    case 0: x = g(); break;
    case 1: x = uint32_t(int32_t(g()) >> (g() % 32)); break;
    case 2: { uint32_t p = 1u << (g() % 31); x = p + int32_t(g() % 5) - 2; if (g() & 1) x = -x; break; }
    case 3: x = (g() & 1) ? 0x7fffffff - (g() % 4) : 0x80000000 + (g() % 4); break;
    case 4: x = 0; break;
    default: x = (r & 0xffffff00) | 0x80; break;                                // ties at 24 bits
    }
    int E = x ? 31 - __builtin_clz(int32_t(x) < 0 ? -x : x) : 0;
    switch (g() % 5) {
    case 0: y = g(); break;
    case 1: y = uint32_t(int32_t(g() % 64) - 32); break;
    case 2: y = uint32_t(127 - E + int32_t(g() % 5) - 2); break;                // to 2^128
    case 3: y = uint32_t(-126 - E + int32_t(g() % 5) - 2); break;               // to 2^-126
    default: y = 0x7ffffff0u + (g() % 32); break;                               // the C int's wrap
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *s;
    long n = (s = Verilated::commandArgsPlusMatch("n=")) && *s ? atol(s + 3) : 10000000;
    unsigned seed = (s = Verilated::commandArgsPlusMatch("seed=")) && *s ? atoi(s + 6) : 1;
    std::mt19937 g(seed);
    Vtb_sharcman *t = new Vtb_sharcman;
    long fails[NOPS] = {0}, runs[NOPS] = {0}, ufail[2] = {0}, uruns[2] = {0}, busy = 0;
    long tiny[NOPS] = {0}, ovf[NOPS] = {0}, tie[NOPS] = {0}, den[NOPS] = {0}, trn[NOPS] = {0}, r32[NOPS] = {0};
    t->clk = 0;
    for (long i = 0; i < n; i++) {
        int op = i % NOPS;
        uint32_t x, y, a = g();
        if (op == 5 || op == 6) pick_fix(g, x, y);
        else if (op == 7 || op == 8) pick_float(g, x, y);
        else if (op == 12) { uint32_t d; pick_f(g, op, x, d); pick_fix(g, d, y); }
        else pick_f(g, op, x, y);
        bool trunc = g() & 1, rnd32 = g() & 1, alusat = (g() & 3) == 0;
        t->op = op; t->x = x; t->y = y; t->trunc = trunc; t->rnd32 = rnd32; t->alusat = alusat; t->astat_in = a;
        t->clk = 0; t->eval();
        c_tie = c_tiny = c_ovf = false;
        Res e = ref(op, x, y, trunc, rnd32, alusat, a);
        tiny[op] += c_tiny; ovf[op] += c_ovf; tie[op] += c_tie; trn[op] += trunc; r32[op] += rnd32;
        den[op] += (op != 7 && op != 8 && ((is_dz(x) && !is_zero(x)) || (is_dz(y) && !is_zero(y))));
        bool bad = t->r != e.r || t->astat != e.astat || t->stky != e.stky || (op == 3 && t->r2 != e.r2);
        runs[op]++;
        if (bad && fails[op]++ < 5)
            printf("%-16s x=%08X y=%08X trunc=%d rnd32=%d alusat=%d: RTL r=%08X r2=%08X astat=%08X stky=%08X, "
                   "manual r=%08X r2=%08X astat=%08X stky=%08X\n", NAMES[op], x, y, trunc, rnd32, alusat,
                   t->r, t->r2, t->astat, t->stky, e.r, e.r2, e.astat, e.stky);
        t->clk = 1; t->eval();
        busy += t->busy;
        if (op <= 1 || op == 4) {
            int u = op == 4;
            uint32_t gr = u ? t->mr : t->ar, ga = u ? t->ma : t->aa, gs = u ? t->ms : t->as;
            uruns[u]++;
            if ((gr != e.r || ga != e.astat || gs != e.stky) && ufail[u]++ < 5)
                printf("%s %s x=%08X y=%08X trunc=%d rnd32=%d: unit r=%08X astat=%08X stky=%08X, manual r=%08X astat=%08X stky=%08X\n",
                       u ? "sharc_fmul" : "sharc_fadd", NAMES[op], x, y, trunc, rnd32, gr, ga, gs, e.r, e.astat, e.stky);
        }
    }
    long total = 0;
    for (int op = 0; op < NOPS; op++) {
        bool fx = op == 5 || op == 6, fl = op == 7 || op == 8;
        printf("%-16s %10ld vectors, %ld mismatches; TRUNC %ld, RND32 %ld, denormal operand %ld, %s %ld, "
               "%s %ld, %s %ld\n", NAMES[op], runs[op], fails[op], trn[op], r32[op], den[op],
               fl ? "truncated" : "halfway", tie[op], fx ? "in (-1, 0)" : "underflow", tiny[op],
               fx ? "out of range" : "overflow", ovf[op]);
        total += fails[op];
    }
    printf("sharc_fadd       %10ld vectors, %ld mismatches\n", uruns[0], ufail[0]);
    printf("sharc_fmul       %10ld vectors, %ld mismatches (busy %ld)\n", uruns[1], ufail[1], busy);
    total += ufail[0] + ufail[1] + (busy != 0);
    printf(total ? "FAIL: %ld mismatches\n" : "PASS\n", total);
    delete t;
    return total ? 1 : 0;
}
