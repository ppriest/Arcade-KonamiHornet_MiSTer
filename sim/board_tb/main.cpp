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
    struct Burst { uint32_t addr; int left; uint64_t ready; };
    std::deque<Burst> rq;
    uint64_t now = 0;
    uint32_t base = 0;                             // added to the address (port S: offsets)
    uint64_t bad = 0, nrd = 0, nwr = 0, nrq = 0;   // read beats, write beats, read bursts

    void drive() {
        *waitRequestn = (int)rq.size() < g_memq && wstall == 0;
        *readDataValid = 0;
        if (!rq.empty() && rq.front().ready <= now) {
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
        if (!rq.empty() && rq.front().ready <= now) {
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
    vp[0].wide = true; vp[0].writeDataHi = &t->v_fbw_wdata_hi; vp[0].byteEnableHi = &t->v_fbw_be_hi;
    vp[6].wide = true; vp[6].writeDataHi = &t->v_mf_wdata_hi; vp[6].byteEnableHi = &t->v_mf_be_hi; vp[6].readDataHi = &t->v_mf_rdata_hi;
    vp[1].wide = true; vp[1].writeDataHi = &t->v_fbcw_wdata_hi; vp[1].byteEnableHi = &t->v_fbcw_be_hi;
    vp[2].wide = true; vp[2].writeDataHi = &t->v_fbaw_wdata_hi; vp[2].byteEnableHi = &t->v_fbaw_be_hi;
    vp[3].wide = true; vp[3].readDataHi = &t->v_fbcr_rdata_hi;
    vp[4].wide = true; vp[4].readDataHi = &t->v_fbar_rdata_hi;
    // port S, the picture's frame-buffer reads: the same model, its addresses frame-buffer offsets
    CData s_nowr = 0, s_be = 0xF; IData s_wd = 0;
    AvPort sp{&t->s_read, &s_nowr, &t->s_waitn, &t->s_rvalid, &t->s_addr, &s_wd, &t->s_rdata, &t->s_burst, &s_be};
    sp.wide = true; sp.readDataHi = &t->s_rdata_hi;
    sp.base = FB_BASE;
    uint64_t cyc = 0;
    uint64_t a_bad = 0, b_bad = 0;
    // +bstat: port B accesses a frame by region (RAM 0x500000, RAM 0x1400000, CG ROM), sequential, 16-word blocks
    uint64_t bst[3][2] = {}, bseq = 0; uint32_t bprev = 0; std::set<uint32_t> bblk;
    std::vector<uint8_t> screen(512 * 384 * 3, 0);

    t->in0 = ports[":IN0"]; t->in1 = ports[":IN1"]; t->in2 = ports[":IN2"]; t->in3 = 0xF0;      // MAME reads 0xF0: JVS sense high (no JVS device), EEPDO 0
    t->dsw = ports[":DSW"];
    t->line_clocks = LINE_CLOCKS;
    t->run = 0; t->ld_we = 0; t->ld_v_we = 0;
    t->v_ring_off = ringoff;
    t->ddr3_en = ddr3;
    t->ppc_dbg_we = 0; t->dsp_dbg_we = 0; t->dsp_dbg_pm_we = 0; t->dsp_dbg_dm_we = 0;

    // the SHARC's clock: with clk until dsp_dual (the state load), then +dspmhz=N MHz against clk's
    // LINE_CLOCKS * 25 kHz, its edges placed in time between clk's
    double dsp_mhz = (s = Verilated::commandArgsPlusMatch("dspmhz=")) && *s ? atof(s + 8) : 0.0;
    bool dsp_dual = false;
    const double clk_ps = 1e12 / (LINE_CLOCKS * 25000.0);
    double t_ps = 0.0, dsp_next = 0.0;
    int dsp_lvl = 0;
    uint64_t dsp_x = 0;                 // with dsp_dual: the SHARC's instructions
    auto clock = [&]() {
        t->clk = 0;
        if (!dsp_dual) t->clk_dsp = 0;
        // port A
        t->a_ack = 0;
        if (due(0, t->a_req)) {
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
                if (!dsp_lvl && t->dsp_dbg_exec) dsp_x++;
                dsp_lvl ^= 1; t->clk_dsp = dsp_lvl; t->eval(); dsp_next += half;
            }
            if (dsp_next < t_ps + clk_ps + 1.0) {
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

    // ---------------------------------------------------------------- run
    t->run = 1;
    uint64_t run0 = cyc, ppc_insns = 0, dsp_insns = 0, overruns = 0, v_wait = 0, v_writes = 0, d_idle = 0;
    int frame = 0, prev_vpos = FRAME_LINE;
    // +pause=F,N: the pause input from frame F for N frames
    int pause_f = 1 << 30, pause_n = 0;
    if ((s = Verilated::commandArgsPlusMatch("pause=")) && *s) sscanf(s + 7, "%d,%d", &pause_f, &pause_n);
    bool fail = false;
    uint64_t limit = (uint64_t)(frames + 1) * 428 * LINE_CLOCKS;
    if (dsp_mhz > 0) { dsp_dual = true; dsp_next = t_ps + 1e6 / dsp_mhz / 2.0; dsp_lvl = 1; }
    while (frame < frames && cyc - run0 < limit && !Verilated::gotFinish()) {
        clock();
        if (t->ppc_dbg_exec) ppc_insns++;
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
        if (t->ev_v_write) v_writes++;
        if (t->v_ring_bad) ring_bad++;
        if (ddr3) {
            // probe D's counts (hornet_ddr3's dbg)
            uint32_t g = t->ddr_dbg;
            unsigned as = g & 3;
            if (g & 4) dd[0]++;                                // BUSY
            if (as == 0 && !(g & 0x400)) dd[1]++;             // idle
            if (g & 8) dd[2]++;                                // waiting for return-FIFO room
            if (as == 2 && (g & 4)) dd[3]++;                   // a read waiting on BUSY
            if (as == 3) dd[4]++;                              // writing
            if (as == 1) dd[5]++;                              // A_CMD
            if (g & 0x10) dd[6]++;                             // reads accepted
            if (g & 0x20) dd[7]++;                             // write beats
            if (g & 0x40) dd[8]++;                             // beats in
            if (g & (1u << 23)) { dd[9] += (g >> 11) & 0xFFF; dd[10]++; }
            // vraster: clocks a texture fill holds the pipeline, fills, clocks drawing triangles
            if (t->v_dbg & 0x20) { dd[11]++; if (!tf_q) dd[12]++; }
            tf_q = t->v_dbg & 0x20;
            if (((t->v_dbg >> 10) & 15) == 8) dd[13]++;
            if (g & 0x400) dc[(g >> 7) & 7]++;
        }
        if (t->vid_overrun) {
            overruns++;
            if (overruns <= 8) fprintf(stderr, "frame %d: line %d not built when shown\n", frame + 1, (int)t->vpos);
        }
        if (t->vpos == FRAME_LINE && prev_vpos != FRAME_LINE) {
            frame++;
            t->pause = frame >= pause_f && frame < pause_f + pause_n;
            std::string fd = snap + "/f" + std::to_string(frame) + "/";
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
                memset(dd, 0, sizeof dd); memset(dc, 0, sizeof dc);
            }
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
