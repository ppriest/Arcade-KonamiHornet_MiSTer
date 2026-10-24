// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Hornet board (rtl/board/hornet_board.sv) started from a MAME snapshot and run freely for
// a few frames; at each frame its picture and its Voodoo front buffer are compared with MAME's.
//
//     python scripts/mame_board_snapshot.py gradius4 --frame 7500 --frames 4
//     scripts/run_verilator.sh board_tb +snap=debug/gradius4-board7500 [+frames=4]
//
// The snapshot (scripts/mame/boardsnap.lua) is taken at MAME's frame end, which the screen
// reaches at the line after its visible area (hornet.cpp:1432: visible lines 27-410). The board
// starts at that line; at each later arrival there:
//   picture   the board's video output over the frame against MAME's f<n+1>/screen.bin, which
//             holds the picture MAME showed during frame n (rtl_screen_f<n>.ppm,
//             mame_screen_f<n>.ppm)
//   Voodoo    the displayed buffer against MAME's f<n>/fb.bin at m_frontbuf's offset
//             (rtl_f<n>.ppm, mame_f<n>.ppm)
//
// Memories: ports A (PPC), B (SHARC), C and S (video) are answered in the clock they are seen; the
// Voodoo's Avalon ports as in sim/voodoo_tb (bursts, reads after a latency).

#include "Vtb_board.h"
#include "Vtb_board___024root.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <sstream>
#include <set>
#include <string>
#include <deque>
#include <vector>

double sc_time_stamp() { return 0; }

static const int FRAME_LINE = 411;        // MAME's frame end: the line after the visible area
// 64 MHz / 25 kHz: the Voodoo's medium-resolution line rate MAME picks (58.41 Hz at 428 lines).
// +line=N models another clk_sys at that line rate (1920: 48 MHz); the PPC timebase stays clk/2.
static int LINE_CLOCKS = 2560;

// ------------------------------------------------------------------------------------------
// files
// ------------------------------------------------------------------------------------------

static std::vector<uint8_t> load_bytes(const std::string &p, size_t size) {
    std::vector<uint8_t> v(size, 0);
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(1); }
    size_t n = fread(v.data(), 1, size, f);
    fclose(f);
    if (n != size) fprintf(stderr, "%s: %zu of %zu bytes\n", p.c_str(), n, size);
    return v;
}
// 32-bit words stored big-endian (ROM images, the PPC's work RAM dump)
static std::vector<uint32_t> load_be32(const std::string &p, size_t words) {
    auto b = load_bytes(p, words * 4);
    std::vector<uint32_t> w(words);
    for (size_t i = 0; i < words; i++)
        w[i] = (uint32_t)b[4 * i] << 24 | (uint32_t)b[4 * i + 1] << 16 | (uint32_t)b[4 * i + 2] << 8 | b[4 * i + 3];
    return w;
}
// MAME's save items, host order
static std::vector<uint32_t> load_le32(const std::string &p, size_t words) {
    auto b = load_bytes(p, words * 4);
    std::vector<uint32_t> w(words);
    memcpy(w.data(), b.data(), words * 4);
    return w;
}

// "<n>/name count size v0 v1 ..." -> name: values
static std::map<std::string, std::vector<uint64_t>> load_items(const std::string &path) {
    std::map<std::string, std::vector<uint64_t>> items;
    FILE *f = fopen(path.c_str(), "r");
    if (!f) { fprintf(stderr, "no %s\n", path.c_str()); exit(1); }
    static char line[65536];
    while (fgets(line, sizeof line, f)) {
        std::istringstream is(line);
        std::string name; int cnt, size;
        is >> name >> cnt >> size;
        auto sl = name.find('/');
        if (sl != std::string::npos) name = name.substr(sl + 1);
        std::vector<uint64_t> v;
        std::string h;
        while (is >> h) v.push_back(strtoull(h.c_str(), nullptr, 16));
        items[name] = v;
    }
    fclose(f);
    return items;
}
// "name value" (the debugger's registers)
static std::map<std::string, uint64_t> load_state(const std::string &path) {
    std::map<std::string, uint64_t> st;
    FILE *f = fopen(path.c_str(), "r");
    if (!f) { fprintf(stderr, "no %s\n", path.c_str()); exit(1); }
    char k[64]; char v[64];
    while (fscanf(f, "%63s %63s", k, v) == 2) st[k] = strtoull(v, nullptr, 16);
    fclose(f);
    return st;
}
static uint64_t need(const std::map<std::string, std::vector<uint64_t>> &m, const char *name, size_t i = 0) {
    auto it = m.find(name);
    if (it == m.end() || it->second.size() <= i) { fprintf(stderr, "item %s missing\n", name); exit(1); }
    return it->second[i];
}

static void ppm(const std::string &path, const uint8_t *fb, uint32_t offs, int w, int h, int stride) {
    FILE *f = fopen(path.c_str(), "wb");
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            uint16_t p = fb[offs + 2 * (y * stride + x)] | fb[offs + 2 * (y * stride + x) + 1] << 8;
            uint8_t rgb[3] = {uint8_t((p >> 11) << 3), uint8_t(((p >> 5) & 63) << 2), uint8_t((p & 31) << 3)};
            fwrite(rgb, 1, 3, f);
        }
    fclose(f);
}

// ------------------------------------------------------------------------------------------
// Voodoo memory (sim/voodoo_tb's model)
// ------------------------------------------------------------------------------------------

static const uint32_t FB_BASE = 0x40000000u - 12u * 1024 * 1024;   // De10AddressMap.scala
static const uint32_t TEX_BASE = FB_BASE + 4u * 1024 * 1024;
static std::vector<uint8_t> fbmem(4u << 20), texmem(8u << 20);
static int g_memlat = 2, g_memq = 1;
// +wwait=N: after each texture write the texture port holds waitRequestn low N clocks (DDR3's
// write cost under load, which fills vraster's FIFO and puts its ring to use as on the board)
static int g_wwait = 0;

static uint8_t *mem_at(uint32_t a) {
    if (a >= FB_BASE && a < FB_BASE + fbmem.size()) return &fbmem[a - FB_BASE];
    if (a >= TEX_BASE && a < TEX_BASE + texmem.size()) return &texmem[a - TEX_BASE];
    return nullptr;
}

// One Avalon-MM slave per master port: a burst is accepted with its first beat; read data follows
// at one word a clock, each burst no sooner than g_memlat clocks after it was accepted. Up to
// g_memq read bursts may be outstanding (+memlat=, +memq=).
struct AvPort {
    CData *read, *write, *waitRequestn, *readDataValid;
    IData *address, *writeData, *readData;
    SData *burstCount;
    CData *byteEnable;
    int wr_left = 0; uint32_t wr_addr = 0;
    int wstall = 0, wcost = 0;
    // a wide master (hornet_ddr3 WIDE): two words a handshake, the odd one in *_hi
    bool wide = false;
    IData *writeDataHi = nullptr, *readDataHi = nullptr;
    CData *byteEnableHi = nullptr;
    // a master's readReady: read data comes only the clock after it was high
    CData *readReady = nullptr;
    bool rdy_q = true;
    bool due() const { return !rq.empty() && rq.front().ready <= now && (!readReady || rdy_q); }
    struct Burst { uint32_t addr; int left; uint64_t ready; };
    std::deque<Burst> rq;
    uint64_t now = 0;
    uint32_t base = 0;                             // added to the address (port S: offsets)
    uint32_t wlo = 0, whi = ~0u;                   // where this port's writes belong
    const char *name = "";
    uint64_t bad = 0, nrd = 0, nwr = 0, nrq = 0;   // read beats, write beats, read bursts

    void drive() {
        *waitRequestn = (int)rq.size() < g_memq && wstall == 0;
        *readDataValid = 0;
        if (due()) {
            uint8_t *p = mem_at(rq.front().addr);
            uint32_t d = 0;
            if (p) memcpy(&d, p, 4); else bad++;
            *readDataValid = 1; *readData = d;
            if (wide) {
                uint8_t *q = mem_at(rq.front().addr + 4);
                uint32_t e = 0;
                if (q) memcpy(&e, q, 4);
                *readDataHi = e;
            }
        }
    }
    void edge() {
        if (due()) {
            rq.front().addr += wide ? 8 : 4;
            rq.front().left -= wide ? 2 : 1;
            if (rq.front().left <= 0) rq.pop_front();
        }
        if (wstall > 0) wstall--;
        if (*waitRequestn && *write) {
            wstall = wcost;
            uint32_t a = wr_left ? wr_addr : *address;
            if (!wr_left) wr_left = *burstCount;
            for (int h = 0; h < (wide ? 2 : 1); h++) {
                uint8_t *p = mem_at(a + 4 * h);
                if ((a + 4 * h < wlo || a + 4 * h >= whi) && bad++ < 8)
                    fprintf(stderr, "Voodoo %s write outside its region: %08X\n", name, a + 4 * h);
                uint32_t d = h ? *writeDataHi : *writeData;
                uint8_t be = h ? *byteEnableHi : *byteEnable;
                if (p) {
                    for (int i = 0; i < 4; i++)
                        if (be & (1 << i)) p[i] = (uint8_t)(d >> (8 * i));
                } else if (bad++ < 8) fprintf(stderr, "Voodoo write out of range %08X\n", a + 4 * h);
            }
            wr_addr = a + (wide ? 8 : 4);
            wr_left -= wide ? 2 : 1;
            nwr += wide ? 2 : 1;
        } else if (*waitRequestn && *read) {
            rq.push_back({*address + base, (int)*burstCount, now + 1 + g_memlat});
            nrd += *burstCount; nrq++;
        }
        if (readReady) rdy_q = *readReady;
        now++;
    }
};
#define PORT(t, n) AvPort{&t->v_##n##_read, &t->v_##n##_write, &t->v_##n##_waitn, &t->v_##n##_rvalid, \
    &t->v_##n##_addr, &t->v_##n##_wdata, &t->v_##n##_rdata, &t->v_##n##_burst, &t->v_##n##_be}


// +ddr3: the board's masters through hornet_ddr3 (as KonamiHornet.sv) to this model of the DDRAM
// port: a command or a write beat taken when !BUSY; read data in order, a 64-bit beat a clock, the
// first +ddrlat clocks after the command (data as at the command); BUSY at random, +ddrbusy percent
struct Ddr {
    Vtb_board *t;
    int lat = 30, busy_pct = 10;
    uint64_t now = 0;
    struct R { std::vector<uint64_t> d; size_t k; uint64_t ready; };
    std::deque<R> rq;
    int w_left = 0; uint32_t w_a = 0;
    bool busy = false, dv = false; uint64_t dout = 0;
    uint64_t rd_cmds = 0, wr_beats = 0, busy_clk = 0;
    static uint64_t rd64(uint32_t a) {
        uint64_t v = 0;
        for (int k = 0; k < 8; k++) { uint8_t *p = mem_at(a * 8 + k); if (p) v |= (uint64_t)*p << (8 * k); }
        return v;
    }
    void drive() { t->DDRAM_BUSY = busy; t->DDRAM_DOUT_READY = dv; t->DDRAM_DOUT = dout; }
    // the Avalon burst rules a real port hangs on: a count of 1-128 beats, address and count held
    // through a write burst, no read inside one, RD and WE not together
    uint64_t proto_bad = 0;
    uint32_t w_addr0 = 0, w_cnt0 = 0;
    void bad(const char *what) {
        if (proto_bad++ < 8) fprintf(stderr, "DDRAM protocol: %s at clock %llu (addr %07X count %u)\n", what,
                                     (unsigned long long)now, (unsigned)t->DDRAM_ADDR, (unsigned)t->DDRAM_BURSTCNT);
    }
    void edge() {
        if (t->DDRAM_RD && t->DDRAM_WE) bad("RD and WE together");
        if ((t->DDRAM_RD || (t->DDRAM_WE && !w_left)) && (t->DDRAM_BURSTCNT == 0 || t->DDRAM_BURSTCNT > 128))
            bad("burst count out of range");
        if (w_left && t->DDRAM_RD) bad("read inside a write burst");
        if (w_left && t->DDRAM_WE && (t->DDRAM_ADDR != w_addr0 || t->DDRAM_BURSTCNT != w_cnt0))
            bad("address or count changed inside a write burst");
        if (!busy && t->DDRAM_WE) {
            uint32_t a = w_left ? w_a : t->DDRAM_ADDR;
            if (!w_left) { w_left = t->DDRAM_BURSTCNT; w_addr0 = t->DDRAM_ADDR; w_cnt0 = t->DDRAM_BURSTCNT; }
            for (int k = 0; k < 8; k++)
                if (t->DDRAM_BE & (1 << k)) { uint8_t *p = mem_at(a * 8 + k); if (p) *p = (uint8_t)(t->DDRAM_DIN >> (8 * k)); }
            w_a = a + 1; w_left--; wr_beats++;
        } else if (!busy && t->DDRAM_RD) {
            R r; r.k = 0; r.ready = now + lat;
            for (uint32_t k = 0; k < t->DDRAM_BURSTCNT; k++) r.d.push_back(rd64(t->DDRAM_ADDR + k));
            rq.push_back(std::move(r)); rd_cmds++;
        }
        dv = false;
        if (!rq.empty() && rq.front().ready <= now) {
            dv = true; dout = rq.front().d[rq.front().k++];
            if (rq.front().k == rq.front().d.size()) rq.pop_front();
        }
        if (busy) busy_clk++;
        busy = (int)(rand() % 100) < busy_pct;
        now++;
    }
};

// ------------------------------------------------------------------------------------------

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *s;
    std::string snap = (s = Verilated::commandArgsPlusMatch("snap=")) && *s ? std::string(s + 6) : "";
    int frames = (s = Verilated::commandArgsPlusMatch("frames=")) && *s ? atoi(s + 8) : 4;
    if ((s = Verilated::commandArgsPlusMatch("line=")) && *s) LINE_CLOCKS = atoi(s + 6);
    if ((s = Verilated::commandArgsPlusMatch("memlat=")) && *s) g_memlat = atoi(s + 8);
    if ((s = Verilated::commandArgsPlusMatch("memq=")) && *s) g_memq = atoi(s + 6);
    if ((s = Verilated::commandArgsPlusMatch("wwait=")) && *s) g_wwait = atoi(s + 7);
    // +alat=N, +blat=N, +clat=N: ports A, B, C acknowledge N clocks after the request (port S is
    // an Avalon master like the Voodoo's: +memlat, +memq)
    int lat[4] = {0, 0, 0, 0}, wait[4] = {0, 0, 0, 0};
    { const char *nm[3] = {"alat=", "blat=", "clat="};
      for (int k = 0; k < 3; k++) if ((s = Verilated::commandArgsPlusMatch(nm[k])) && *s) lat[k] = atoi(s + 6); }
    auto due = [&](int k, bool req) { if (!req) { wait[k] = 0; return false; }
                                      if (wait[k] < lat[k]) { wait[k]++; return false; } wait[k] = 0; return true; };
    // +bcache: port B behind a two-line read-ahead buffer of 8-word lines, as an SDRAM front end
    // would be: a miss fills its line from the half holding the word, a word every pb_wpc clocks
    // (+bwpc=, default 2: two row-open double reads of Sorgelig's controller at 2x clk_sys) after
    // blat; an access to a line starts the next line's fill; writes are posted (two words of time)
    bool bcache = Verilated::commandArgsPlusMatch("bcache")[0];
    bool ccache = Verilated::commandArgsPlusMatch("ccache")[0];
    bool ddr3 = Verilated::commandArgsPlusMatch("ddr3")[0];
    Ddr ddr;
    unsigned long long dd[14] = {0}, dc[8] = {0};
    bool tf_q = false;
    uint64_t tx_fmt[16] = {}, tx_hold[2] = {}, vp_cs[16] = {}, vp_ts[16] = {}, vp_tris = 0, vp_mode[32] = {}, vp_st[8] = {}, vp_px[4] = {}, vp_hs[4] = {};
    if ((s = Verilated::commandArgsPlusMatch("ddrlat=")) && *s) ddr.lat = atoi(s + 8);
    if ((s = Verilated::commandArgsPlusMatch("ddrbusy=")) && *s) ddr.busy_pct = atoi(s + 9);
    // +ringoff: vraster's memory FIFO without its DDR3 ring (the stp revision's debug switch)
    bool ringoff = Verilated::commandArgsPlusMatch("ringoff")[0];
    uint64_t ring_bad = 0;
    std::vector<int> cc_tag(128, -1);
    int cc_wait = 0;
    int pb_wpc = (s = Verilated::commandArgsPlusMatch("bwpc=")) && *s ? atoi(s + 6) : 2;
    uint64_t pb_now = 0, pb_busy = 0, pb_ready = 0; bool pb_pend = false;
    uint32_t pb_tag[2] = {~0u, ~0u}; uint64_t pb_rdy[2][8] = {}; int pb_lru = 0;
    auto pb_fill = [&](int sl, uint32_t line, int first) {
        uint64_t st = std::max(pb_now, pb_busy);
        pb_tag[sl] = line;
        for (int k = 0; k < 8; k++) pb_rdy[sl][k] = st + lat[1] + pb_wpc * ((k - (first & 4)) & 7);
        pb_busy = st + 8 * pb_wpc;
    };
    auto pb_access = [&](uint32_t a, bool we) -> uint64_t {
        if (we) { pb_busy = std::max(pb_now, pb_busy) + 2 * pb_wpc; return pb_now; }
        uint32_t line = a >> 3; int sl = pb_tag[0] == line ? 0 : pb_tag[1] == line ? 1 : -1;
        if (sl < 0) { sl = pb_lru; pb_fill(sl, line, a & 7); }
        pb_lru = 1 - sl;
        uint64_t r = pb_rdy[sl][a & 7];
        if (pb_tag[1 - sl] != line + 1) pb_fill(1 - sl, line + 1, 0);
        return r;
    };
    // +acache: port A behind a line cache of 8-word lines (+alines=, default 128; +aways=, default
    // 1), as an SDRAM front end would be: a hit answers in +ahit clocks (default 2), a miss after
    // +amiss (default 20: one double read), once the posted writes before it have drained. Writes
    // are posted into a queue of +awq (default 4) and drain one every +awcost clocks (default 24:
    // two controller writes); a hit's line is updated, a miss is not allocated.
    bool acache = Verilated::commandArgsPlusMatch("acache")[0];
    // +atrace=<file>: port A's first +atracen= accesses (default 100000) for sim/sdram_tb's replay,
    // a line each: clocks from the last acknowledge to the request, write, address, byte enables,
    // write data, read data
    FILE *atrace = nullptr;
    long atrace_n = 0;
    { const char *v = Verilated::commandArgsPlusMatch("atrace=");
      if (v && *v) atrace = fopen(v + 8, "w"); }
    { const char *v = Verilated::commandArgsPlusMatch("atracen=");
      atrace_n = v && *v ? atol(v + 9) : 100000; }
    uint64_t at_clk = 0, at_req = 0, at_ack = 0; bool at_in = false;
    auto iarg = [&](const char *nm, int dflt) { const char *v = Verilated::commandArgsPlusMatch(nm);
                                                return v && *v ? atoi(v + strlen(nm) + 1) : dflt; };
    const int a_lines = iarg("alines=", 128), a_ways = iarg("aways=", 1), a_hit = iarg("ahit=", 2),
              a_miss = iarg("amiss=", 20), a_wq = iarg("awq=", 4), a_wcost = iarg("awcost=", 24);
    std::vector<uint32_t> pa_tag(a_lines * a_ways, ~0u);
    std::vector<uint64_t> pa_use(a_lines * a_ways, 0);
    std::deque<uint64_t> pa_wq;                            // the queued writes' drain ends
    uint64_t pa_now = 0, pa_ready = 0, pa_hits = 0, pa_misses = 0, pa_wfull = 0; bool pa_pend = false;
    auto pa_access = [&](uint32_t a, bool we) -> uint64_t {
        while (!pa_wq.empty() && pa_wq.front() <= pa_now) pa_wq.pop_front();
        uint32_t line = a >> 3, set = line % a_lines;
        int way = -1;
        for (int k = 0; k < a_ways; k++) if (pa_tag[set * a_ways + k] == line) way = k;
        if (we) {
            uint64_t at = pa_now + 1;
            if ((int)pa_wq.size() >= a_wq) { at = pa_wq[pa_wq.size() - a_wq]; pa_wfull++; }
            pa_wq.push_back(std::max(at, pa_wq.empty() ? 0 : pa_wq.back()) + a_wcost);
            if (way >= 0) pa_use[set * a_ways + way] = pa_now;
            return at;
        }
        if (way >= 0) { pa_hits++; pa_use[set * a_ways + way] = pa_now; return pa_now + a_hit; }
        pa_misses++;
        int v = 0;
        for (int k = 1; k < a_ways; k++) if (pa_use[set * a_ways + k] < pa_use[set * a_ways + v]) v = k;
        pa_tag[set * a_ways + v] = line; pa_use[set * a_ways + v] = pa_now;
        return std::max(pa_now, pa_wq.empty() ? 0 : pa_wq.back()) + a_miss;
    };
    if (snap.empty()) { fprintf(stderr, "+snap=<dir> required\n"); return 1; }
    std::string st = snap + "/start/";
    const std::string roms = "debug/gradius4-roms/";

    // port A: work RAM, program ROM, data ROM, character RAM
    auto work = load_be32(st + "workram.bin", 1u << 20);
    auto prg  = load_be32(roms + "prgrom.bin", 1u << 20);
    auto data = load_be32(roms + "datarom.bin", 2u << 20);
    auto chr  = load_le32(st + "k037122_0/0_m_char_ram.bin", 1u << 19);
    // port B: RAM 0x500000, RAM 0x1400000, CG ROM
    auto r500 = load_le32(st + "dsp1/0__sharc0_dataram.bin", 1u << 20);
    auto r14  = load_le32(st + "dsp1/1_1400000_14fffff.bin", 1u << 20);
    auto cg   = load_be32(roms + "cgrom.bin", 1u << 22);

    auto vfb = load_bytes(st + "voodoo0/0_m_fbram.bin", 6u << 20);
    memcpy(fbmem.data(), vfb.data(), 2u << 20);
    memcpy(texmem.data(), vfb.data() + (2u << 20), 4u << 20);

    auto ppc_items = load_items(st + "maincpu.txt");
    auto ppc_st    = load_state(st + "maincpu_state.txt");
    auto spr       = load_le32(st + "maincpu/0_m_core__spr.bin", 1024);
    auto dsp_items = load_items(st + "dsp1.txt");
    auto dsp_st    = load_state(st + "dsp1_state.txt");
    auto kpc       = load_items(st + "konppc.txt");
    auto k33       = load_items(st + "k033906_1.txt");
    auto k56       = load_items(st + "k056800.txt");
    auto vitems    = load_items(st + "voodoo0.txt");
    auto fbi       = load_le32(st + "voodoo0/0_m_reg_m_regs.bin", 256);
    auto tmu0      = load_le32(st + "voodoo0/0_m_tmu_0__m_reg_m_regs.bin", 256);
    std::map<std::string, uint32_t> ports;
    {
        FILE *f = fopen((st + "ports.txt").c_str(), "r");
        char k[64]; unsigned v;
        while (f && fscanf(f, "%63s %x", k, &v) == 2) ports[k] = v;
        if (f) fclose(f);
    }

    Vtb_board *t = new Vtb_board;
    ddr.t = t;
    AvPort vp[7] = {PORT(t, fbw), PORT(t, fbcw), PORT(t, fbaw), PORT(t, fbcr), PORT(t, fbar), PORT(t, tex), PORT(t, mf)};
    vp[5].wcost = g_wwait;
    {   // the frame buffer (MAME's 2 MB), the ring at FB_BASE + 3 MB, the texture memory
        const char *nm[7] = {"fbw", "fbcw", "fbaw", "fbcr", "fbar", "tex", "mf"};
        for (int k = 0; k < 7; k++) { vp[k].name = nm[k]; vp[k].wlo = FB_BASE; vp[k].whi = FB_BASE + (2u << 20); }
        vp[5].wlo = TEX_BASE; vp[5].whi = TEX_BASE + (4u << 20);
        vp[6].wlo = FB_BASE + (3u << 20); vp[6].whi = FB_BASE + (3u << 20) + (512u << 10);
    }
    vp[0].wide = true; vp[0].writeDataHi = &t->v_fbw_wdata_hi; vp[0].byteEnableHi = &t->v_fbw_be_hi;
    vp[6].wide = true; vp[6].writeDataHi = &t->v_mf_wdata_hi; vp[6].byteEnableHi = &t->v_mf_be_hi; vp[6].readDataHi = &t->v_mf_rdata_hi;
    vp[1].wide = true; vp[1].writeDataHi = &t->v_fbcw_wdata_hi; vp[1].byteEnableHi = &t->v_fbcw_be_hi;
    vp[2].wide = true; vp[2].writeDataHi = &t->v_fbaw_wdata_hi; vp[2].byteEnableHi = &t->v_fbaw_be_hi;
    vp[3].wide = true; vp[3].readDataHi = &t->v_fbcr_rdata_hi; vp[3].readReady = &t->v_fbcr_rready;
    vp[4].wide = true; vp[4].readDataHi = &t->v_fbar_rdata_hi; vp[4].readReady = &t->v_fbar_rready;
    vp[5].wide = true; vp[5].readDataHi = &t->v_tex_rdata_hi; vp[5].readReady = &t->v_tex_rready;
    vp[5].writeDataHi = &t->v_tex_wdata_hi; vp[5].byteEnableHi = &t->v_tex_be_hi;
    // port S, the picture's frame-buffer reads: the same model, its addresses frame-buffer offsets
    CData s_nowr = 0, s_be = 0xF; IData s_wd = 0;
    AvPort sp{&t->s_read, &s_nowr, &t->s_waitn, &t->s_rvalid, &t->s_addr, &s_wd, &t->s_rdata, &t->s_burst, &s_be};
    sp.wide = true; sp.readDataHi = &t->s_rdata_hi;
    sp.base = FB_BASE;
    uint64_t cyc = 0;
    uint64_t a_bad = 0, b_bad = 0;
    // port A accesses a frame: reads by region (work RAM, ROM, character RAM), writes; and reads
    // that follow the previous read's word (the icache's fills)
    uint64_t ast[3] = {}, a_wr = 0, a_seq = 0; uint32_t a_prev = ~0u;
    // +bstat: port B accesses a frame by region (RAM 0x500000, RAM 0x1400000, CG ROM), sequential, 16-word blocks
    uint64_t bst[3][2] = {}, bseq = 0; uint32_t bprev = 0; std::set<uint32_t> bblk;
    std::vector<uint8_t> screen(512 * 384 * 3, 0);

    t->in0 = ports[":IN0"]; t->in1 = ports[":IN1"]; t->in2 = ports[":IN2"]; t->in3 = 0xF0;      // MAME reads 0xF0: JVS sense high (no JVS device), EEPDO 0
    t->dsw = ports[":DSW"];
    t->line_clocks = LINE_CLOCKS;
    t->run = 0; t->ld_we = 0; t->ld_v_we = 0;
    t->v_ring_off = ringoff;
    t->ddr3_en = ddr3;
    // +sdram: ports A, B and C through hornet_sdram onto the chip model, preloaded with their memories.
    // A port A word w is halfwords 2w (bits 31:16) and 2w + 1; a halfword address is {chip, a25,
    // bank, row[12:0], column[8:0]} with a25 the column's top bit (rtl/mister/sdram/sdram.sv).
    bool sdram = Verilated::commandArgsPlusMatch("sdram")[0];
    t->sdram_en = sdram;
    if (sdram) {
        auto put = [&](uint32_t w, uint32_t v) {
            for (int h = 0; h < 2; h++) {
                uint32_t H = 2 * w + h;
                uint32_t idx = ((H >> 22) & 3) << 23 | ((H >> 9) & 0x1FFF) << 10 | ((H >> 24) & 1) << 9 | (H & 0x1FF);
                auto &m = (H >> 25) ? t->rootp->tb_board__DOT__chip__DOT__u_c1__DOT__mem
                                    : t->rootp->tb_board__DOT__chip__DOT__u_c0__DOT__mem;
                m[idx] = h ? (v & 0xFFFF) : (v >> 16);
            }
        };
        for (uint32_t i = 0; i < work.size(); i++) put(i, work[i]);
        for (uint32_t i = 0; i < prg.size(); i++) put(0x100000 + i, prg[i]);
        for (uint32_t i = 0; i < data.size(); i++) put(0x200000 + i, data[i]);
        for (uint32_t i = 0; i < chr.size(); i++) put(0x400000 + i, chr[i]);
        for (uint32_t i = 0; i < r500.size(); i++) put(0x800000 + i, r500[i]);
        for (uint32_t i = 0; i < r14.size(); i++) put(0x900000 + i, r14[i]);
        for (uint32_t i = 0; i < cg.size(); i++) put(0xA00000 + i, cg[i]);
    }
    t->ppc_dbg_we = 0; t->dsp_dbg_we = 0; t->dsp_dbg_pm_we = 0; t->dsp_dbg_dm_we = 0;

    // the SHARC's clock: with clk until dsp_dual (the state load), then +dspmhz=N MHz against clk's
    // LINE_CLOCKS * 25 kHz, its edges placed in time between clk's
    double dsp_mhz = (s = Verilated::commandArgsPlusMatch("dspmhz=")) && *s ? atof(s + 8) : 0.0;
    bool dsp_dual = false;
    const double clk_ps = 1e12 / (LINE_CLOCKS * 25000.0);
    double t_ps = 0.0, dsp_next = 0.0;
    int dsp_lvl = 0;
    uint64_t dsp_x = 0;                 // with dsp_dual: the SHARC's instructions
    // +dspprof: the SHARC's clocks by pipeline state (sim/sharc2_tb's classes), and its slow clocks
    // by X's PC into <snap>/board_slow_pcs.txt
    bool dsp_prof_on = Verilated::commandArgsPlusMatch("dspprof")[0];
    uint64_t dprof[9] = {}, e_clk = 0, e_quanta = 0;   // ... and the DMA engine's busy clocks and quanta
    std::map<uint32_t, uint64_t> dslow, dempty, dldhz;
    uint64_t dhz[5] = {}, ddma[7] = {}, dlb[5] = {};
    auto dsp_prof = [&]() {
        if (!dsp_prof_on) return;
        uint32_t s = t->rootp->tb_board__DOT__dut__DOT__dsp__DOT__dbg_prof;
        bool hz = s & 1, dv = s & 2, eb = s & 4, xb = s & 8, xs = s & 16, xv = s & 32, sq = s & 64, ex = s & 128;
        unsigned ph = s >> 8;
        int k;
        if (ex) k = 0;
        else if (sq) k = 5;
        else if (xv && ph) { k = 1; dslow[t->rootp->tb_board__DOT__dut__DOT__dsp__DOT__dbg_xpc]++; }
        else if (xv && xs) k = xb ? 3 : eb ? 2 : 4;
        else if (xv) k = 4;
        else if (dv && hz) k = 6;
        else if (!dv) k = 7;
        else k = 8;
        dprof[k]++;
        // D's hazard clocks by cause (dbg_hz bits 0-4: X's late result, a multi-cycle wait, the slow unit busy,
        // X's DAG write, a load's late result), and the bubbles (empty) by D's PC
        if (dv && hz) {
            unsigned h = t->rootp->tb_board__DOT__dut__DOT__dsp__DOT__dbg_hz;
            if (h & 1) dhz[0]++; if (h & 2) dhz[1]++; if (h & 4) dhz[2]++; if (h & 8) dhz[3]++; if (h & 16) dhz[4]++;
            if (h & 16) dldhz[t->rootp->tb_board__DOT__dut__DOT__dsp__DOT__dbg_xpc]++;   // the load in X
        }
        if (k == 8) dempty[t->rootp->tb_board__DOT__dut__DOT__dsp__DOT__d_pc]++;
        // the SHARC's line buffer (port B reads): line fills (misses, prefetches), clocks a fill is
        // under way, line-read requests waiting
        {
            auto *r = t->rootp;
            if (r->tb_board__DOT__dut__DOT__miss_go) dlb[0]++;
            if (r->tb_board__DOT__dut__DOT__pf_go) dlb[1]++;
            if (r->tb_board__DOT__dut__DOT__f_any) dlb[2]++;
            if (r->tb_board__DOT__dut__DOT__d_brd && !r->tb_board__DOT__dut__DOT__l_ack) dlb[3]++;
            if (r->tb_board__DOT__dut__DOT__d_brd && !r->tb_board__DOT__dut__DOT__lhit) dlb[4]++;
        }
        // the DMA engine's busy clocks: external read or write waits (by region: the Voodoo, else),
        // TCB loads, the rest; and its external accesses
        if (eb) {
            auto *r = t->rootp;
            unsigned st = r->tb_board__DOT__dut__DOT__dsp__DOT__e_step;
            bool w = r->tb_board__DOT__dut__DOT__dsp__DOT__e_wait, rq = r->tb_board__DOT__dut__DOT__dsp__DOT__eb_req;
            uint32_t a = r->tb_board__DOT__dut__DOT__dsp__DOT__eb_addr;
            static bool rq_q = false;
            if (rq && !rq_q) ddma[(a >> 20) == 0x24 ? 4 : r->tb_board__DOT__dut__DOT__dsp__DOT__eb_we ? 5 : 6]++;
            rq_q = rq;
            if (w && rq) ddma[(a >> 20) == 0x24 ? 0 : 1]++;
            else if (st >= 2) ddma[2]++;
            else ddma[3]++;
        }
        static bool eb_q = false;
        if (eb) { e_clk++; if (!eb_q) e_quanta++; }
        eb_q = eb;
    };
    int frame = 0, prev_vpos = FRAME_LINE;
    uint64_t sd_bad = 0;
    uint64_t dx_wait = 0, dx_rwait = 0;
    auto clock = [&]() {
        t->clk = 0;
        if (!dsp_dual) t->clk_dsp = 0;
        // port A
        t->a_ack = 0;
        at_clk++;
        if (t->a_req && !at_in) { at_in = true; at_req = at_clk; }
        bool a_due;
        if (sdram) {
            // hornet_sdram answers; the C++ memories follow its acknowledged writes and check its reads
            a_due = false;
            if (t->a_req && t->rootp->tb_board__DOT__sd_a_ack) {
                uint32_t a = t->a_addr, r = a >> 20;
                uint32_t *w = r == 0 ? &work[a & 0xFFFFF] : r == 1 ? &prg[a & 0xFFFFF] :
                              (r == 2 || r == 3) ? &data[a & 0x1FFFFF] : r == 4 ? &chr[a & 0x7FFFF] : nullptr;
                if (w && t->a_we) {
                    uint32_t m = 0;
                    for (int i = 0; i < 4; i++) if (t->a_be & (1 << i)) m |= 0xFFu << (8 * i);
                    *w = (*w & ~m) | (t->a_wdata & m);
                } else if (w && *w != t->rootp->tb_board__DOT__sd_a_rdata && sd_bad++ < 20)
                    fprintf(stderr, "frame %d line %d: port A read %06X: %08X from hornet_sdram, %08X written\n",
                            frame + 1, (int)t->vpos, a, t->rootp->tb_board__DOT__sd_a_rdata, *w);
            }
        } else if (!acache) a_due = due(0, t->a_req);
        else {
            if (t->a_req && !pa_pend) { pa_pend = true; pa_ready = pa_access(t->a_addr, t->a_we); }
            a_due = t->a_req && pa_now >= pa_ready;
            if (a_due) pa_pend = false;
        }
        pa_now++;
        if (a_due) {
            uint32_t a = t->a_addr, r = a >> 20, d = 0;
            uint32_t *w = nullptr;
            if (r == 0) w = &work[a & 0xFFFFF];
            else if (r == 1) w = &prg[a & 0xFFFFF];
            else if (r == 2 || r == 3) w = &data[a & 0x1FFFFF];
            else if (r == 4) w = &chr[a & 0x7FFFF];
            if (!w) { if (a_bad++ < 8) fprintf(stderr, "port A out of range %06X\n", a); }
            else if (t->a_we && (r == 0 || r == 4)) {
                uint32_t m = 0;
                for (int i = 0; i < 4; i++) if (t->a_be & (1 << i)) m |= 0xFFu << (8 * i);
                *w = (*w & ~m) | (t->a_wdata & m);
            } else d = *w;
            t->a_ack = 1; t->a_rdata = d;
            if (t->a_we) a_wr++;
            else { ast[r == 0 ? 0 : r == 4 ? 2 : 1]++; if (a == a_prev + 1) a_seq++; a_prev = a; }
            if (atrace && atrace_n > 0) {
                fprintf(atrace, "%llu %d %06X %X %08X %08X\n", (unsigned long long)(at_req - at_ack), t->a_we ? 1 : 0, a,
                        (unsigned)t->a_be, (unsigned)t->a_wdata, d);
                if (--atrace_n == 0) { fclose(atrace); atrace = nullptr; }
            }
            at_in = false; at_ack = at_clk;
        }
        // port B
        t->b_ack = 0;
        bool b_due;
        if (!bcache) b_due = due(1, t->b_req);
        else {
            if (t->b_req && !pb_pend) { pb_pend = true; pb_ready = pb_access(t->b_addr, t->b_we); }
            b_due = t->b_req && pb_now >= pb_ready;
            if (b_due || !t->b_req) pb_pend = false;
        }
        pb_now++;
        if (b_due) {
            uint32_t a = t->b_addr, r = a >> 20, d = 0;
            uint32_t *w = r == 0 ? &r500[a & 0xFFFFF] : r == 1 ? &r14[a & 0xFFFFF] : &cg[(a - 0x200000) & 0x3FFFFF];
            if (t->b_we && r < 2) *w = t->b_wdata;
            else if (t->b_we) { if (b_bad++ < 8) fprintf(stderr, "port B write to CG ROM %06X\n", a); }
            else d = *w;
            t->b_ack = 1; t->b_rdata = d;
            bst[r == 0 ? 0 : r == 1 ? 1 : 2][t->b_we ? 1 : 0]++;
            if (a == bprev + 1) bseq++;
            bprev = a; bblk.insert(a >> 4);
        }
        // port C: character RAM. +ccache: hornet_sdram's cache (128 direct-mapped lines of two
        // rows): a hit answers in 3 clocks, a miss after +clat; PPC writes drop their line
        t->c_ack = 0;
        if (ccache) {
            if (t->a_req && t->a_ack && t->a_we && (t->a_addr >> 20) == 4)
                cc_tag[(t->a_addr >> 3) & 127] = -1;
            if (!t->c_req) cc_wait = 0;
            else {
                uint32_t line = (t->c_addr >> 3) & 0xFFFF;
                int need = cc_tag[line & 127] == (int)line ? 3 : lat[2];
                if (++cc_wait >= need) {
                    cc_wait = 0; cc_tag[line & 127] = line; t->c_ack = 1;
                    for (int k = 0; k < 4; k++) t->c_rdata[k] = chr[((t->c_addr & 0x7FFFC) + k) & 0x7FFFF];
                }
            }
        } else if (due(2, t->c_req)) {
            t->c_ack = 1;
            for (int k = 0; k < 4; k++) t->c_rdata[k] = chr[((t->c_addr & 0x7FFFC) + k) & 0x7FFFF];
        }
        if (ddr3) ddr.drive();
        else { for (auto &p : vp) p.drive(); sp.drive(); }
        t->eval();
        if (dsp_dual) {
            const double half = 1e6 / dsp_mhz / 2.0;
            // the SHARC's executed instructions counted at its own rising edges
            while (dsp_next < t_ps + clk_ps - 1.0) {
                if (!dsp_lvl) dsp_prof();
                if (!dsp_lvl && t->dsp_dbg_exec) dsp_x++;
                dsp_lvl ^= 1; t->clk_dsp = dsp_lvl; t->eval(); dsp_next += half;
            }
            if (dsp_next < t_ps + clk_ps + 1.0) {
                if (!dsp_lvl) dsp_prof();
                if (!dsp_lvl && t->dsp_dbg_exec) dsp_x++;
                dsp_lvl ^= 1; t->clk_dsp = dsp_lvl; dsp_next += half;
            }
        }
        if (t->vid_ce && t->vid_de && t->vid_x < 512 && t->vid_y < 384) {
            uint8_t *q = &screen[3 * (t->vid_y * 512 + t->vid_x)];
            q[0] = t->vid_r; q[1] = t->vid_g; q[2] = t->vid_b;
        }
        if (ddr3) ddr.edge();
        else { for (auto &p : vp) p.edge(); sp.edge(); }
        t->clk = 1;
        if (!dsp_dual) t->clk_dsp = 1;
        t->eval();
        cyc++;
        t_ps += clk_ps;
    };

    t->reset = 1;
    for (int i = 0; i < 8; i++) clock();
    t->reset = 0;
    for (int i = 0; i < 8; i++) clock();

    // ---------------------------------------------------------------- board state
    auto ld = [&](int sel, uint32_t addr, uint32_t v) {
        t->ld_we = 1; t->ld_sel = sel; t->ld_addr = addr; t->ld_data = v; clock(); t->ld_we = 0;
    };
    {
        auto sh = load_le32(st + "konppc/0_m_dsp_shared_ram_i_.bin", 32768);
        for (uint32_t i = 0; i < 32768; i++) ld(0, i, sh[i]);
        auto ks = load_le32(st + "k037122_0/0_m_tile_ram.bin", 32768);
        for (uint32_t i = 0; i < 32768; i++) ld(1, i, ks[i]);
        auto nv = load_bytes(st + "m48t58/0_m_data.bin", 8192);
        for (uint32_t i = 0; i < 8192; i++) ld(2, i, nv[i]);
        // the .nvm save's port reads back what was loaded (byte i the clock after its address)
        {
            int bad = 0;
            for (uint32_t i = 0; i < 8192; i++) {
                t->nvu_addr = i; clock();
                if (t->nvu_q != nv[i] && bad++ < 4) fprintf(stderr, "NVRAM read-back %04X: %02X, want %02X\n", i, t->nvu_q, nv[i]);
            }
            fprintf(stderr, "NVRAM read-back: %d of 8192 bytes differ\n", bad);
        }
        auto kr = load_le32(st + "k033906_1/0_m_ram.bin", 256);
        for (uint32_t i = 0; i < 256; i++) ld(3, i, kr[i]);
        auto kreg = load_le32(st + "k037122_0/0_m_reg.bin", 64);
        for (uint32_t i = 0; i < 64; i++) ld(4, i, kreg[i]);
        auto k33reg = load_le32(st + "k033906_1/0_m_reg.bin", 256);
        ld(6, 0, k33reg[0x04]); ld(6, 1, k33reg[0x0f]); ld(6, 2, k33reg[0x14]);
        ld(5, 0, need(kpc, "m_dsp_comm_ppc[i]", 0)); ld(5, 1, need(kpc, "m_dsp_comm_ppc[i]", 1));
        ld(5, 2, need(kpc, "m_dsp_comm_sharc[i]", 0)); ld(5, 3, need(kpc, "m_dsp_comm_sharc[i]", 1));
        uint32_t bank = need(kpc, "m_dsp_shared_ram_bank[i]"), regs = need(k33, "m_reg_set");
        uint32_t cgb = (need(kpc, "m_dsp_comm_sharc[i]", 1) >> 3) & 1;
        // {bank, dsp_run, k033906_regs, cg_bank, enable_3d}: the SHARC runs unless MAME holds it
        // in reset (SUSPEND_REASON_RESET); enable_3d is not saved by MAME and not used here
        uint32_t dsp_run = (need(dsp_items, "m_suspend") & 2) ? 0 : 1;
        ld(5, 4, bank << 4 | dsp_run << 3 | regs << 2 | cgb << 1 | 1);
        ld(5, 5, need(kpc, "m_dsp_state[i]"));
        ld(5, 6, need(kpc, "m_cgboard_id"));
        ld(5, 7, need(ppc_items, "m_irqstate") & 1);
        ld(7, 0, need(k56, "m_snd_to_host_regs", 0)); ld(7, 1, need(k56, "m_snd_to_host_regs", 1));
        for (int i = 0; i < 4; i++) ld(7, 2 + i, need(k56, "m_host_to_snd_regs", i));
        {
            // the 68000 stand-in: running once hornet's SNDRES is set; a command pending if the
            // sound interrupt is (the tick phase is not saved: HACKS.md)
            auto drv = load_items(st + "driver.txt");
            ld(7, 6, (need(drv, "m_sndres") & 1) | ((need(k56, "m_int_pending") & 1) << 1));
        }
        ld(8, 0, FRAME_LINE | (need(vitems, "m_vblank") ? 1u << 16 : 0));
        for (int i = 0; i < 33; i++) ld(9, i, need(vitems, "m_clut", i) & 0xFFFFFF);
    }

    // Voodoo registers through the SHARC's path, as sim/voodoo_tb loads them: video and init
    // first, then the rest without the commands; TMU 0's through chip mask 2
    auto vwr = [&](uint32_t woff, uint32_t d) {
        t->ld_v_we = 1; t->ld_v_addr = woff; t->ld_v_data = d;
        for (int i = 0; i < 100000; i++) { t->clk = 0; t->eval(); bool taken = !t->ld_v_busy; clock(); if (taken) break; }
        t->ld_v_we = 0;
    };
    {
        const int order[] = {0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8c};
        for (int r : order) vwr(r, fbi[r]);
        for (int r = 1; r < 0x80; r++) {
            if (r == 0x20 || r == 0x40 || (r >= 0x48 && r <= 0x4b)) continue;
            vwr(r, fbi[r]);
        }
        for (int r = 0xc0; r < 0xc8; r++) vwr(0x200 | r, tmu0[r]);
    }

    // PPC (sim/ppc_tb numbering)
    auto ppoke = [&](int sel, uint32_t v) {
        t->ppc_dbg_we = 1; t->ppc_dbg_wsel = sel; t->ppc_dbg_wdata = v; clock(); t->ppc_dbg_we = 0;
    };
    {
        for (int i = 0; i < 32; i++) ppoke(i, ppc_st["R" + std::to_string(i)]);
        const char *names[] = {"CR", "LR", "CTR", "XER", "MSR", "PC", "SRR0", "SRR1",
                               "SPRG0", "SPRG1", "SPRG2", "SPRG3", "EXIER", "EVPR", "TBL", "TBH"};
        for (int i = 0; i < 16; i++) ppoke(32 + i, ppc_st[names[i]]);
        uint32_t tcr = spr[0x3da], tsr = spr[0x3d8], pit = spr[0x3db];
        ppoke(48, tcr);
        ppoke(49, tsr);
        ppoke(50, ppc_st["EXISR"]);
        ppoke(51, ppc_st["IOCR"]);
        ppoke(52, pit);
        // the PIT's phase is MAME's scheduler's, not saved: a full period from here (HACKS.md)
        ppoke(53, (tcr & 0x04000000) ? pit : 0);
        ppoke(54, need(ppc_items, "m_irqstate") & 0x1f);
    }

    // SHARC (sim/sharc_tb's loader)
    {
        auto block0 = load_le32(st + "dsp1/0__dsp1_block0.bin", 32768);
        auto block1 = load_le32(st + "dsp1/0__dsp1_block1.bin", 32768);
        for (uint32_t off = 0; off < 0x5000; off++) {
            uint32_t slot = off >> 12, base = (off & 0xfff) + (slot >> 1) * (3 << 12);
            uint64_t w = (slot & 1) ? ((uint64_t)block0[base + 0x2000] << 16) | (block0[base + 0x1000] & 0xffff)
                                    : ((uint64_t)block0[base] << 16) | (block0[base + 0x1000] >> 16);
            t->dsp_dbg_pm_we = 1; t->dsp_dbg_pm_addr = off; t->dsp_dbg_pm_wdata = w; clock();
        }
        t->dsp_dbg_pm_we = 0;
        for (uint32_t a = 0; a < 32768; a++) { t->dsp_dbg_dm_we = 1; t->dsp_dbg_dm_addr = a; t->dsp_dbg_dm_wdata = block1[a]; clock(); }
        t->dsp_dbg_dm_we = 0;
        auto put = [&](int sel, int idx, uint64_t v) {
            t->dsp_dbg_we = 1; t->dsp_dbg_wsel = sel; t->dsp_dbg_widx = idx; t->dsp_dbg_wdata = v; clock(); t->dsp_dbg_we = 0;
        };
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
        for (auto &a : arr)
            for (int k = 0; k < a.count; k++) put(a.sel, k, need(dsp_items, a.name, a.first + k));
        put(27, 0, dsp_st["PCSTK"]);           // not saved items: the debugger's values
        put(32, 0, dsp_st["CURLCNTR"]);
        if (need(dsp_items, "m_core->lstkp") != 0)
            fprintf(stderr, "warning: SHARC LSTKP %llu at the snapshot; LADDR and LCNTR are not saved by MAME\n",
                    (unsigned long long)need(dsp_items, "m_core->lstkp"));
        put(35, 0, 0xffffffff);
        put(255, 0, 0);                        // start
    }
    fprintf(stderr, "snapshot loaded at %llu clocks; PPC at %08X, SHARC at %05X\n", (unsigned long long)cyc,
            (unsigned)ppc_st["PC"], (unsigned)dsp_st["PC"]);

    // +cheat=ADDR:VAL[:or],...: cheat codes into the board's store (KonamiHornet.sv's index-255 layout:
    // flags, PPC address, compare, value), and the bytes they target printed each frame
    std::vector<std::pair<uint32_t, uint32_t>> cheats;
    if ((s = Verilated::commandArgsPlusMatch("cheat=")) && *s) {
        std::string spec = s + 7;
        size_t pos = 0;
        while (pos < spec.size()) {
            size_t e = spec.find(',', pos);
            std::string c = spec.substr(pos, e == std::string::npos ? std::string::npos : e - pos);
            uint32_t a = 0, v = 0; char m[8] = "";
            sscanf(c.c_str(), "%x:%x:%7s", &a, &v, m);
            uint32_t w[4] = {strcmp(m, "or") ? 0u : 1u, a, 0u, v};
            int k = (int)cheats.size();
            for (int i = 0; i < 4; i++) {
                t->cht_we = 1; t->cht_wa = 4 * k + i; t->cht_wd = w[i];
                clock();
            }
            t->cht_we = 0;
            cheats.push_back({a, v});
            if (e == std::string::npos) break;
            pos = e + 1;
        }
        t->cht_n = cheats.size();
    }

    // ---------------------------------------------------------------- run
    t->run = 1;
    uint64_t pbl[4] = {};
    uint64_t run0 = cyc, ppc_insns = 0, dsp_insns = 0, overruns = 0, v_wait = 0, v_writes = 0, d_idle = 0;
    // +pause=F,N: the pause input from frame F for N frames
    int pause_f = 1 << 30, pause_n = 0;
    if ((s = Verilated::commandArgsPlusMatch("pause=")) && *s) sscanf(s + 7, "%d,%d", &pause_f, &pause_n);
    bool fail = false;
    uint32_t ppc_pc_now = 0;
    uint64_t limit = (uint64_t)(frames + 1) * 428 * LINE_CLOCKS;
    if (dsp_mhz > 0) { dsp_dual = true; dsp_next = t_ps + 1e6 / dsp_mhz / 2.0; dsp_lvl = 1; }
    while (frame < frames && cyc - run0 < limit && !Verilated::gotFinish()) {
        clock();
        if (t->ppc_dbg_exec) { ppc_insns++; ppc_pc_now = t->ppc_dbg_pc; }
        // a port A, B or C request unanswered for 100k clocks, reported once a port
        {
            static uint64_t wt[3] = {0, 0, 0}; static bool told[3] = {false, false, false};
            bool rq[3] = {(bool)t->a_req, (bool)t->b_req, (bool)t->c_req};
            uint32_t ad[3] = {t->a_addr, t->b_addr, t->c_addr};
            for (int k = 0; k < 3; k++) {
                wt[k] = rq[k] ? wt[k] + 1 : 0;
                if (wt[k] == 100000 && !told[k]) {
                    told[k] = true;
                    fprintf(stderr, "frame %d line %d: port %c request at %06X unanswered for 100k clocks (we %d)\n",
                            frame + 1, (int)t->vpos, "ABC"[k], ad[k], k == 0 ? t->a_we : k == 1 ? t->b_we : 0);
                }
            }
        }
        // +trapat=<hex>: the PPC's last 64 PCs when it first executes there
        {
            static const char *ta = Verilated::commandArgsPlusMatch("trapat=");
            static uint32_t trap = ta && *ta ? (uint32_t)strtoul(ta + 8, nullptr, 16) : 0;
            static uint32_t ring[64]; static unsigned rn = 0; static bool done = false;
            if (trap && t->ppc_dbg_exec && !done) {
                ring[rn++ & 63] = t->ppc_dbg_pc;
                if (t->ppc_dbg_pc == trap) {
                    done = true;
                    fprintf(stderr, "frame %d line %d: PPC at %08X after", frame + 1, (int)t->vpos, trap);
                    for (unsigned i = rn - 64; i != rn; i++) fprintf(stderr, " %08X", ring[i & 63]);
                    fprintf(stderr, "\n");
                }
            }
        }
        // +ppcpcs: the PPC's executed PCs, one a line (hex), into <snap>/rtl_ppc_pcs.txt
        {
            static FILE *ppcs = Verilated::commandArgsPlusMatch("ppcpcs")[0]
                                ? fopen((snap + "/rtl_ppc_pcs.txt").c_str(), "w") : nullptr;
            if (ppcs && t->ppc_dbg_exec) fprintf(ppcs, "%08X\n", t->ppc_dbg_pc);
        }
        // +dspio: the SHARC's accesses outside its RAMs, as MAME's io.txt ("R|W addr data")
        {
            static FILE *dio = Verilated::commandArgsPlusMatch("dspio")[0]
                                   ? fopen((snap + "/rtl_dsp_io.txt").c_str(), "w") : nullptr;
            if (dio && t->ev_dsp_acc)
                fprintf(dio, "%c %08X %08X\n", t->ev_dsp_acc_we ? 'W' : 'R', t->ev_dsp_acc_addr, t->ev_dsp_acc_data);
        }
        if (dsp_dual) dsp_insns = dsp_x;
        else if (t->dsp_dbg_exec) {         // (+dsptrace, +dspops: same clock only)
            dsp_insns++;
            // +dsptrace: the SHARC's PCs, one a line, into <snap>/rtl_dsp_pcs.txt
            static FILE *dtr = Verilated::commandArgsPlusMatch("dsptrace")[0]
                                   ? fopen((snap + "/rtl_dsp_pcs.txt").c_str(), "w") : nullptr;
            if (dtr) fprintf(dtr, "%05X\n", (unsigned)t->dsp_dbg_pc);
            // +dspops: the opcode and PX (sel 20 is not readable; log the op) at chosen PCs
            if (Verilated::commandArgsPlusMatch("dspops")[0]) {
                unsigned pc = t->dsp_dbg_pc;
                if ((pc >= 0x2008C && pc <= 0x20091) || pc == 0x20016 || pc == 0x20017)
                    fprintf(stderr, "SHARC insn %llu at %05X: %012llX\n", (unsigned long long)dsp_insns, pc,
                            (unsigned long long)t->dsp_dbg_op);
            }
        }
        if (t->ev_dsp_reset) fprintf(stderr, "frame %d line %d: the SHARC boots\n", frame + 1, (int)t->vpos);
        if (Verilated::commandArgsPlusMatch("swaplog")[0]) {
            static int prev_disp = -1, prev_idle = -1;
            if (t->ev_swapcmd) fprintf(stderr, "frame %d line %d: swapbufferCMD\n", frame + 1, (int)t->vpos);
            static uint32_t last_pc = 0;
            if (t->ppc_dbg_exec && (t->ppc_dbg_pc & 0xFFFF) == 0x0500)
                fprintf(stderr, "frame %d line %d: PPC external interrupt after %08X (%llu instructions)\n", frame + 1,
                        (int)t->vpos, last_pc, (unsigned long long)ppc_insns);
            if (t->ppc_dbg_exec) last_pc = t->ppc_dbg_pc;
            // +ppcpath: the PPC's PCs from frame 3 line 21 to line 22, into <snap>/rtl_ppc_path.txt
            static FILE *pp = Verilated::commandArgsPlusMatch("ppcpath")[0]
                                  ? fopen((snap + "/rtl_ppc_path.txt").c_str(), "w") : nullptr;
            if (pp && t->ppc_dbg_exec && frame == 2 && t->vpos >= 21 && t->vpos <= 22)
                fprintf(pp, "%08X\n", t->ppc_dbg_pc);
            if (Verilated::commandArgsPlusMatch("delayprobe")[0] && t->ppc_dbg_exec && t->ppc_dbg_pc == 0x8020964C) {
                int s0 = t->ppc_dbg_sel;
                t->ppc_dbg_sel = 3; t->eval(); uint32_t r3 = t->ppc_dbg_val;
                t->ppc_dbg_sel = 33; t->eval(); uint32_t lr = t->ppc_dbg_val;
                t->ppc_dbg_sel = s0; t->eval();
                static uint32_t last_lr = 0, last_r3 = 0; static int reps = 0;
                if (lr != last_lr || r3 != last_r3 || reps < 2)
                    fprintf(stderr, "frame %d line %d: delay(%u) from %08X\n", frame + 1, (int)t->vpos, r3, lr);
                reps = (lr == last_lr && r3 == last_r3) ? reps + 1 : 0;
                last_lr = lr; last_r3 = r3;
            }
            if (Verilated::commandArgsPlusMatch("tbprobe")[0] && t->ppc_dbg_exec && t->ppc_dbg_pc == 0x80204EB4) {
                static int n = 0;
                if (n++ % 20000 == 0) {
                    int s0 = t->ppc_dbg_sel;
                    t->ppc_dbg_sel = 3; t->eval(); uint32_t r3 = t->ppc_dbg_val;
                    t->ppc_dbg_sel = 30; t->eval(); uint32_t r30 = t->ppc_dbg_val;
                    t->ppc_dbg_sel = 31; t->eval(); uint32_t r31 = t->ppc_dbg_val;
                    t->ppc_dbg_sel = s0; t->eval();
                    fprintf(stderr, "frame %d line %d: tblo %08X r30 %08X r31 %08X\n", frame + 1, (int)t->vpos, r3, r30, r31);
                }
            }
            static int sample_line = -1;
            if (Verilated::commandArgsPlusMatch("samplef=")[0] && frame == atoi(Verilated::commandArgsPlusMatch("samplef=") + 9) && t->vpos % 20 == 0 && t->vpos != sample_line) {
                sample_line = t->vpos;
                fprintf(stderr, "frame %d line %d: PPC at %08X\n", frame + 1, (int)t->vpos, last_pc);
            }
            if (t->ev_dsp_comm)
                fprintf(stderr, "frame %d line %d: SHARC W comm %08X %08X (pc %05X)\n", frame + 1, (int)t->vpos,
                        t->ev_dsp_comm_addr, t->ev_dsp_comm_data, (unsigned)t->dsp_dbg_pc);
            // the PPC's comm and sysreg traffic: writes, and reads when their value changes
            static std::map<uint32_t, uint32_t> last_rd;
            static int nall = 0;
            if (Verilated::commandArgsPlusMatch("devall")[0] && t->ev_dev && frame == 2 && t->vpos < 120 && nall < 300) {
                nall++;
                fprintf(stderr, "frame %d line %d: PPC* %c %08X %08X (pc %08X)\n", frame + 1, (int)t->vpos,
                        t->ev_dev_we ? 'W' : 'R', t->ev_dev_addr, t->ev_dev_data, last_pc);
            }
            if (t->ev_dev && (t->ev_dev_addr >> 16) != 0x7800 && (t->ev_dev_addr >> 16) != 0x7402) {
                bool show = t->ev_dev_we;
                if (!t->ev_dev_we) {
                    auto it = last_rd.find(t->ev_dev_addr);
                    show = it == last_rd.end() || it->second != t->ev_dev_data;
                    last_rd[t->ev_dev_addr] = t->ev_dev_data;
                }
                if (show)
                    fprintf(stderr, "frame %d line %d: PPC %c %08X %08X (pc %08X)\n", frame + 1, (int)t->vpos,
                            t->ev_dev_we ? 'W' : 'R', t->ev_dev_addr, t->ev_dev_data, last_pc);
            }
            if ((int)(t->v_displayed & 1) != prev_disp) {
                if (prev_disp >= 0) fprintf(stderr, "frame %d line %d: displayed buffer %d\n", frame + 1, (int)t->vpos, t->v_displayed & 1);
                prev_disp = t->v_displayed & 1;
            }
            if ((int)t->ev_dsp_idle != prev_idle) {
                fprintf(stderr, "frame %d line %d: SHARC %s\n", frame + 1, (int)t->vpos, t->ev_dsp_idle ? "idle" : "running");
                prev_idle = t->ev_dsp_idle;
            }
        }
        if (t->ev_v_wait) v_wait++;
        if (t->ev_dsp_idle) d_idle++;
        // port B's line reads for the SHARC (clk_sys): clocks a line's request waits, words taken,
        // lines, clocks a SHARC request waits in the crossing queue
        {
            auto *r = t->rootp;
            bool cl = r->tb_board__DOT__dut__DOT__c_line, xr = r->tb_board__DOT__dut__DOT__x_req;
            bool ack = sdram ? r->tb_board__DOT__sd_b_ack : t->b_ack;
            if (xr && cl && t->b_req) { if (ack) { pbl[1]++; if (r->tb_board__DOT__dut__DOT__lk == 7) pbl[2]++; } else pbl[0]++; }
            if (!r->tb_board__DOT__dut__DOT__cq_empty) pbl[3]++;
        }
        // the SHARC waiting on its external bus (clk clocks), and how many of them on reads
        if (t->rootp->tb_board__DOT__dut__DOT__dx_req && !t->rootp->tb_board__DOT__dut__DOT__dx_ack) {
            dx_wait++;
            if (!t->rootp->tb_board__DOT__dut__DOT__dx_we) dx_rwait++;
        }
        if (t->ev_v_write) v_writes++;
        if (t->v_ring_bad) ring_bad++;
        if (ddr3) {
            // probe D's counts (hornet_ddr3's dbg)
            uint32_t g = t->ddr_dbg;
            unsigned as = g & 3;
            if (g & 4) dd[0]++;                                // BUSY
            if (as == 0 && !(g & 0x800)) dd[1]++;             // idle
            if (g & 8) dd[2]++;                                // waiting for return-FIFO room
            if (as == 2 && (g & 4)) dd[3]++;                   // a read waiting on BUSY
            if (as == 3) dd[4]++;                              // writing
            if (as == 1) dd[5]++;                              // A_CMD
            if (g & 0x10) dd[6]++;                             // reads accepted
            if (g & 0x20) dd[7]++;                             // write beats
            if (g & 0x40) dd[8]++;                             // beats in
            if (g & (1u << 23)) { dd[9] += (g >> 12) & 0x7FF; dd[10]++; }
            // vraster: clocks a texture fill holds the pipeline, fills, clocks drawing triangles
            if (t->v_dbg & 0x20) {
                dd[11]++;
                if (!tf_q) {
                    dd[12]++;
                    // +texstat: fills by texture format, and by 16-bit or 8-bit texels the clocks they hold
                    tx_fmt[(t->rootp->tb_board__DOT__dut__DOT__voodoo__DOT__textureMode >> 8) & 15]++;
                }
                tx_hold[(t->rootp->tb_board__DOT__dut__DOT__voodoo__DOT__textureMode >> 11) & 1]++;
            }
            tf_q = t->v_dbg & 0x20;
            if (((t->v_dbg >> 10) & 15) == 8) dd[13]++;
            // +vprof: clocks by command state, by triangle state while drawing, and triangles
            vp_cs[(t->v_dbg >> 10) & 15]++;
            if (((t->v_dbg >> 10) & 15) == 8) vp_ts[t->rootp->tb_board__DOT__dut__DOT__voodoo__DOT__ts & 15]++;
            if (t->v_dbg & 0x8000) vp_tris++;
            // ... the pipeline's clocks while drawing: issuing a pixel, held by a fill, its next set not
            // ready, ready but its sibling's RAM busy
            if (((t->v_dbg >> 10) & 15) == 8) {
                auto *r = t->rootp;
                unsigned ps = r->tb_board__DOT__dut__DOT__voodoo__DOT__px_set & 7;
                if (r->tb_board__DOT__dut__DOT__voodoo__DOT__stall) vp_px[1]++;
                else if (r->tb_board__DOT__dut__DOT__voodoo__DOT__px_run) vp_px[0]++;
                else if ((r->tb_board__DOT__dut__DOT__voodoo__DOT__st[ps] & 7) != 2) vp_px[2]++;
                else if (!r->tb_board__DOT__dut__DOT__voodoo__DOT__px_start) vp_px[3]++;
            }
            {   // ... and the frame-buffer read masters' handshakes and beats at hornet_ddr3
                unsigned rd = t->rootp->tb_board__DOT__dm_read, wn = t->rootp->tb_board__DOT__dm_waitn;
                unsigned rv = t->rootp->tb_board__DOT__dm_rvalid;
                if (rd & wn & 8) vp_hs[0]++;
                if (rd & wn & 16) vp_hs[1]++;
                if (rv & 8) vp_hs[2]++;
                if (rv & 16) vp_hs[3]++;
            }
            // ... line-buffer set-clocks by state (free, read, ready, proc, done, write)
            for (int k = 0; k < 8; k++) vp_st[t->rootp->tb_board__DOT__dut__DOT__voodoo__DOT__st[k] & 7]++;
            // ... and drawing clocks by {chroma key, depth test, aux write, alpha test, blend}
            if (((t->v_dbg >> 10) & 15) == 8) {
                uint32_t fz = t->rootp->tb_board__DOT__dut__DOT__voodoo__DOT__fbzMode;
                uint32_t am = t->rootp->tb_board__DOT__dut__DOT__voodoo__DOT__alphaMode;
                vp_mode[((fz >> 1) & 1) << 4 | ((fz >> 4) & 1) << 3 | ((fz >> 10) & 1) << 2 | (am & 1) << 1 | ((am >> 4) & 1)]++;
            }
            if (g & 0x800) dc[(g >> 7) & 7]++;
        }
        if (t->vid_overrun) {
            overruns++;
            if (overruns <= 8) fprintf(stderr, "frame %d: line %d not built when shown\n", frame + 1, (int)t->vpos);
        }
        if (t->vpos == FRAME_LINE && prev_vpos != FRAME_LINE) {
            frame++;
            t->pause = frame >= pause_f && frame < pause_f + pause_n;
            std::string fd = snap + "/f" + std::to_string(frame) + "/";
            if (FILE *fx = fopen((fd + "voodoo0.txt").c_str(), "r")) fclose(fx);
            else {
                // past MAME's frames (+frames= beyond the snapshot's): the board runs on, its
                // picture written every 20 frames
                if (frame % (Verilated::commandArgsPlusMatch("everyshot")[0] ? 1 : 20) == 0) {
                    FILE *fr = fopen((snap + "/rtl_screen_f" + std::to_string(frame) + ".ppm").c_str(), "wb");
                    fprintf(fr, "P6\n512 384\n255\n");
                    fwrite(screen.data(), 1, screen.size(), fr);
                    fclose(fr);
                }
                fprintf(stderr, "frame %d at %llu clocks: PPC %llu, SHARC %llu instructions, PPC at %08X (past MAME's frames)\n",
                        frame, (unsigned long long)(cyc - run0), (unsigned long long)ppc_insns,
                        (unsigned long long)dsp_insns, ppc_pc_now);
                prev_vpos = t->vpos;
                continue;
            }
            auto mfi = load_items(fd + "voodoo0.txt");
            auto mfb = load_bytes(fd + "fb.bin", 2u << 20);
            uint32_t mfront = need(mfi, "m_frontbuf"), moffs = need(mfi, "m_rgboffs", mfront);
            // CoreHornet's buffer0Base is the displayed buffer's offset (swaps already applied)
            uint32_t roffs = t->v_base0;
            long diff = 0;
            for (int y = 0; y < 384; y++)
                for (int x = 0; x < 512; x++) {
                    uint32_t o = 2 * (y * 512 + x);
                    if (roffs + o + 1 >= fbmem.size()) { diff++; continue; }
                    if (fbmem[roffs + o] != mfb[moffs + o] || fbmem[roffs + o + 1] != mfb[moffs + o + 1]) diff++;
                }
            ppm(snap + "/rtl_f" + std::to_string(frame) + ".ppm", fbmem.data(), roffs, 512, 384, 512);
            ppm(snap + "/mame_f" + std::to_string(frame) + ".ppm", mfb.data(), moffs, 512, 384, 512);
            // MAME's f<n>/screen.bin is the picture shown during frame n - 1
            std::string fs = snap + "/f" + std::to_string(frame + 1) + "/screen.bin";
            if (FILE *fe = fopen(fs.c_str(), "rb")) {
                fclose(fe);
                auto ms = load_bytes(fs, 512 * 384 * 4);   // ARGB32, little-endian
                long sd = 0;
                FILE *fr = fopen((snap + "/rtl_screen_f" + std::to_string(frame) + ".ppm").c_str(), "wb");
                FILE *fm = fopen((snap + "/mame_screen_f" + std::to_string(frame) + ".ppm").c_str(), "wb");
                fprintf(fr, "P6\n512 384\n255\n"); fprintf(fm, "P6\n512 384\n255\n");
                for (int i = 0; i < 512 * 384; i++) {
                    uint8_t m3[3] = {ms[4 * i + 2], ms[4 * i + 1], ms[4 * i]};
                    if (memcmp(m3, &screen[3 * i], 3)) sd++;
                    fwrite(&screen[3 * i], 1, 3, fr); fwrite(m3, 1, 3, fm);
                }
                fclose(fr); fclose(fm);
                fprintf(stderr, "frame %d picture: %ld of 196608 pixels differ\n", frame, sd);
            }
            if (Verilated::commandArgsPlusMatch("dspdump=")[0] && frame == atoi(Verilated::commandArgsPlusMatch("dspdump=") + 9)) {
                // the SHARC's registers (sim/sharc_tb numbering): R0-15 I0-15 M0-15 ASTAT MODE1
                // IRPTL IMASK PCSTKP LSTKP CURLCNTR PCSTK
                static const char *nm[] = {"ASTAT", "MODE1", "IRPTL", "IMASK", "PCSTKP", "LSTKP", "CURLCNTR", "PCSTK"};
                int s0 = t->dsp_dbg_sel;
                fprintf(stderr, "frame %d SHARC at %05X:", frame, (unsigned)t->dsp_dbg_pc);
                for (int i = 0; i < 56; i++) {
                    t->dsp_dbg_sel = i; t->eval();
                    if (i < 48) fprintf(stderr, " %c%d=%X", "RIM"[i / 16], i % 16, t->dsp_dbg_val);
                    else fprintf(stderr, " %s=%X", nm[i - 48], t->dsp_dbg_val);
                }
                fprintf(stderr, "\n");
                t->dsp_dbg_sel = s0; t->eval();
            }
            if (Verilated::commandArgsPlusMatch("bstat")[0]) {
                fprintf(stderr, "frame %d port B: r500 %llu/%llu, r14 %llu/%llu, cg %llu/%llu (reads/writes); sequential %llu; 16-word blocks %zu\n",
                        frame, (unsigned long long)bst[0][0], (unsigned long long)bst[0][1], (unsigned long long)bst[1][0],
                        (unsigned long long)bst[1][1], (unsigned long long)bst[2][0], (unsigned long long)bst[2][1],
                        (unsigned long long)bseq, bblk.size());
                memset(bst, 0, sizeof bst); bseq = 0; bblk.clear();
            }
            if (Verilated::commandArgsPlusMatch("vstat")[0]) {
                const char *nm[7] = {"fbw", "fbcw", "fbaw", "fbcr", "fbar", "tex", "mf"};
                for (int k = 0; k < 7; k++) {
                    fprintf(stderr, "frame %d Voodoo %s: %llu read beats in %llu bursts, %llu write beats\n", frame, nm[k],
                            (unsigned long long)vp[k].nrd, (unsigned long long)vp[k].nrq, (unsigned long long)vp[k].nwr);
                    vp[k].nrd = vp[k].nrq = vp[k].nwr = 0;
                }
            }
            if (ddr3) {
                fprintf(stderr, "frame %d DDR3: busy %llu, idle %llu, room-wait %llu, read-busy %llu, writing %llu, cmd %llu; "
                        "reads %llu (latency %.1f), write beats %llu, beats in %llu; commands fbw %llu fbcw %llu fbaw %llu "
                        "fbcr %llu fbar %llu tex %llu ring %llu S %llu\n", frame,
                        dd[0], dd[1], dd[2], dd[3], dd[4], dd[5], dd[6], dd[10] ? (double)dd[9] / dd[10] : 0.0, dd[7], dd[8],
                        dc[0], dc[1], dc[2], dc[3], dc[4], dc[5], dc[6], dc[7]);
                fprintf(stderr, "frame %d Voodoo: drawing %llu clocks, texture fills %llu holding the pipeline %llu clocks\n",
                        frame, dd[13], dd[12], dd[11]);
                if (Verilated::commandArgsPlusMatch("texstat")[0]) {
                    fprintf(stderr, "frame %d texture fills by format:", frame);
                    for (int k = 0; k < 16; k++) if (tx_fmt[k]) fprintf(stderr, " %d:%llu", k, (unsigned long long)tx_fmt[k]);
                    fprintf(stderr, "; holding 8-bit %llu, 16-bit %llu clocks\n", (unsigned long long)tx_hold[0],
                            (unsigned long long)tx_hold[1]);
                }
                if (Verilated::commandArgsPlusMatch("vprof")[0]) {
                    static const char *cn[10] = {"idle", "load", "conv", "exec", "adj", "adj2", "fill", "swap", "tri", "texw"};
                    static const char *tn[10] = {"idle", "sort", "div", "row0", "line", "clip", "span", "emit", "next", "drain"};
                    fprintf(stderr, "frame %d Voodoo commands:", frame);
                    for (int k = 0; k < 10; k++) fprintf(stderr, " %s %llu", cn[k], (unsigned long long)vp_cs[k]);
                    fprintf(stderr, "; %llu triangles:", (unsigned long long)vp_tris);
                    for (int k = 0; k < 10; k++) fprintf(stderr, " %s %llu", tn[k], (unsigned long long)vp_ts[k]);
                    fprintf(stderr, "\nframe %d Voodoo drawing by mode (chroma, depth test, aux write, alpha test, blend):", frame);
                    for (int k = 0; k < 32; k++)
                        if (vp_mode[k]) fprintf(stderr, " %d%d%d%d%d:%llu", k >> 4 & 1, k >> 3 & 1, k >> 2 & 1, k >> 1 & 1, k & 1,
                                                (unsigned long long)vp_mode[k]);
                    fprintf(stderr, "\n");
                }
                if (Verilated::commandArgsPlusMatch("vprof")[0])
                    fprintf(stderr, "frame %d line-buffer set-clocks: free %llu read %llu ready %llu proc %llu done %llu write %llu\n",
                            frame, (unsigned long long)vp_st[0], (unsigned long long)vp_st[1], (unsigned long long)vp_st[2],
                            (unsigned long long)vp_st[3], (unsigned long long)vp_st[4], (unsigned long long)vp_st[5]);
                if (Verilated::commandArgsPlusMatch("vprof")[0])
                    fprintf(stderr, "frame %d pixel pipeline: issuing %llu, fill %llu, no set %llu, sibling %llu\n", frame,
                            (unsigned long long)vp_px[0], (unsigned long long)vp_px[1], (unsigned long long)vp_px[2],
                            (unsigned long long)vp_px[3]);
                if (Verilated::commandArgsPlusMatch("vprof")[0])
                    fprintf(stderr, "frame %d frame-buffer reads: colour %llu (%llu beats), depth %llu (%llu beats)\n", frame,
                            (unsigned long long)vp_hs[0], (unsigned long long)vp_hs[2], (unsigned long long)vp_hs[1],
                            (unsigned long long)vp_hs[3]);
                memset(vp_hs, 0, sizeof vp_hs);
                memset(vp_px, 0, sizeof vp_px);
                memset(vp_st, 0, sizeof vp_st);
                memset(vp_mode, 0, sizeof vp_mode);
                memset(vp_cs, 0, sizeof vp_cs); memset(vp_ts, 0, sizeof vp_ts); vp_tris = 0;
                memset(tx_fmt, 0, sizeof tx_fmt); memset(tx_hold, 0, sizeof tx_hold);
                memset(dd, 0, sizeof dd); memset(dc, 0, sizeof dc);
            }
            fprintf(stderr, "frame %d port A: reads work %llu, ROM %llu, char %llu (sequential %llu); writes %llu\n", frame,
                    (unsigned long long)ast[0], (unsigned long long)ast[1], (unsigned long long)ast[2],
                    (unsigned long long)a_seq, (unsigned long long)a_wr);
            for (auto &ch : cheats) {
                uint32_t a = ch.first & 0x3FFFFF;
                fprintf(stderr, "frame %d cheat %08X: %02X (wants %02X)\n", frame, ch.first,
                        (work[a >> 2] >> (8 * (3 - (a & 3)))) & 0xFF, ch.second);
            }
            if (acache) fprintf(stderr, "frame %d port A cache: %llu hits, %llu misses, %llu writes waited for the queue\n",
                                frame, (unsigned long long)pa_hits, (unsigned long long)pa_misses, (unsigned long long)pa_wfull);
            memset(ast, 0, sizeof ast); a_wr = 0; a_seq = 0; pa_hits = pa_misses = pa_wfull = 0;
            fprintf(stderr, "frame %d: SHARC waited %llu clocks on its bus (%llu on reads)\n", frame, (unsigned long long)dx_wait, (unsigned long long)dx_rwait);
            if (dsp_prof_on) {
                static const char *pn[9] = {"exec", "slow", "dma", "busy", "stall", "squash", "hazard", "refill", "empty"};
                fprintf(stderr, "frame %d SHARC clocks:", frame);
                for (int k = 0; k < 9; k++) fprintf(stderr, " %s %llu", pn[k], (unsigned long long)dprof[k]);
                fprintf(stderr, "; DMA engine busy %llu clocks, %llu quanta", (unsigned long long)e_clk, (unsigned long long)e_quanta);
                e_clk = e_quanta = 0;
                fprintf(stderr, "\n");
                memset(dprof, 0, sizeof dprof);
                std::vector<std::pair<uint64_t, uint32_t>> v;
                for (auto &e : dslow) v.push_back({e.second, e.first});
                std::sort(v.rbegin(), v.rend());
                FILE *sp = fopen((snap + "/board_slow_pcs_f" + std::to_string(frame) + ".txt").c_str(), "w");
                for (auto &e : v) fprintf(sp, "%05X %llu\n", e.second, (unsigned long long)e.first);
                fclose(sp);
                dslow.clear();
                fprintf(stderr, "frame %d SHARC hazards: late %llu, multi-cycle %llu, slow unit %llu, DAG %llu, a load's late %llu\n",
                        frame, (unsigned long long)dhz[0], (unsigned long long)dhz[1], (unsigned long long)dhz[2],
                        (unsigned long long)dhz[3], (unsigned long long)dhz[4]);
                memset(dhz, 0, sizeof dhz);
                fprintf(stderr, "frame %d SHARC DMA: waiting on the Voodoo %llu, on other external %llu, TCB %llu, other %llu clocks; "
                        "%llu Voodoo accesses, %llu other external writes, %llu reads\n", frame,
                        (unsigned long long)ddma[0], (unsigned long long)ddma[1], (unsigned long long)ddma[2],
                        (unsigned long long)ddma[3], (unsigned long long)ddma[4], (unsigned long long)ddma[5],
                        (unsigned long long)ddma[6]);
                memset(ddma, 0, sizeof ddma);
                fprintf(stderr, "frame %d SHARC line buffer: %llu misses, %llu prefetches, fills under way %llu clocks; "
                        "reads waiting %llu clocks (%llu on a line not there)\n", frame, (unsigned long long)dlb[0],
                        (unsigned long long)dlb[1], (unsigned long long)dlb[2], (unsigned long long)dlb[3],
                        (unsigned long long)dlb[4]);
                memset(dlb, 0, sizeof dlb);
                v.clear();
                for (auto &e : dempty) v.push_back({e.second, e.first});
                std::sort(v.rbegin(), v.rend());
                sp = fopen((snap + "/board_empty_pcs_f" + std::to_string(frame) + ".txt").c_str(), "w");
                for (auto &e : v) fprintf(sp, "%05X %llu\n", e.second, (unsigned long long)e.first);
                fclose(sp);
                dempty.clear();
                v.clear();
                for (auto &e : dldhz) v.push_back({e.second, e.first});
                std::sort(v.rbegin(), v.rend());
                sp = fopen((snap + "/board_ldhz_pcs_f" + std::to_string(frame) + ".txt").c_str(), "w");
                for (auto &e : v) fprintf(sp, "%05X %llu\n", e.second, (unsigned long long)e.first);
                fclose(sp);
                dldhz.clear();
            }
            dx_wait = dx_rwait = 0;
            fprintf(stderr, "frame %d port B line reads: %llu lines, %llu words, waiting %llu clocks; crossing queue busy %llu clocks\n",
                    frame, (unsigned long long)pbl[2], (unsigned long long)pbl[1], (unsigned long long)pbl[0],
                    (unsigned long long)pbl[3]);
            memset(pbl, 0, sizeof pbl);
            fprintf(stderr, "frame %d: SHARC waited %llu clocks on %llu Voodoo writes, idle %llu clocks\n", frame,
                    (unsigned long long)v_wait, (unsigned long long)v_writes, (unsigned long long)d_idle);
            fprintf(stderr, "frame %d at %llu clocks: PPC %llu, SHARC %llu instructions; front buffer RTL %u at %06X, "
                    "MAME %u at %06X: %ld of 196608 pixels differ\n", frame, (unsigned long long)(cyc - run0),
                    (unsigned long long)ppc_insns, (unsigned long long)dsp_insns, t->v_displayed & 1, roffs,
                    mfront, moffs, diff);
        }
        prev_vpos = t->vpos;
    }
    if (frame < frames) { fprintf(stderr, "stopped after %d frame(s)\n", frame); fail = true; }
    if (overruns) fprintf(stderr, "%llu line(s) not built in time\n", (unsigned long long)overruns);
    if (ring_bad) { fprintf(stderr, "%llu memory-FIFO ring entries read back wrong\n", (unsigned long long)ring_bad); fail = true; }
    if (ddr.proto_bad) { fprintf(stderr, "%llu DDRAM protocol violations\n", (unsigned long long)ddr.proto_bad); fail = true; }
    for (auto &p : vp) if (p.bad) fprintf(stderr, "Voodoo port: %llu out-of-range accesses\n", (unsigned long long)p.bad);
    // +chr=<snapshot dir>: the character RAM at the end against MAME's at that snapshot (the per-frame
    // dumps have none); a run from frame n for k frames ends at frame n + k
    if ((s = Verilated::commandArgsPlusMatch("chr=")) && *s) {
        auto want = load_le32(std::string(s + 5) + "/start/k037122_0/0_m_char_ram.bin", 1u << 19);
        size_t bad = 0, first = 0;
        for (size_t i = 0; i < want.size(); i++) if (chr[i] != want[i] && !bad++) first = i;
        fprintf(stderr, "character RAM: %zu of %zu words differ", bad, want.size());
        if (bad) fprintf(stderr, ", first at %05zX: RTL %08X, MAME %08X", first, chr[first], want[first]);
        fprintf(stderr, "\n");
        if (bad) fail = true;
    }
    // +tex=<snapshot dir>: the Voodoo's texture memory at the end against MAME's at that snapshot
    if ((s = Verilated::commandArgsPlusMatch("tex=")) && *s) {
        auto want = load_bytes(std::string(s + 5) + "/start/voodoo0/0_m_fbram.bin", 6u << 20);
        size_t bad = 0, first = 0;
        for (size_t i = 0; i < (4u << 20); i++)
            if (texmem[i] != want[(2u << 20) + i] && !bad++) first = i;
        { FILE *o = fopen((snap + "/rtl_tex.bin").c_str(), "wb"); fwrite(texmem.data(), 1, 4u << 20, o); fclose(o); }
        fprintf(stderr, "texture memory: %zu of %u bytes differ", bad, 4u << 20);
        if (bad) fprintf(stderr, ", first at %06zX: RTL %02X, MAME %02X", first, texmem[first], want[(2u << 20) + first]);
        fprintf(stderr, "\n");
        if (bad) fail = true;
    }
    delete t;
    return fail ? 2 : 0;
}
