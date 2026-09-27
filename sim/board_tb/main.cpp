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
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <sstream>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static const int FRAME_LINE = 411;        // MAME's frame end: the line after the visible area
static const int LINE_CLOCKS = 2560;      // 64 MHz / 25 kHz: the Voodoo's medium-resolution line rate MAME picks (58.41 Hz at 428 lines)

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
static int g_memlat = 2;

static uint8_t *mem_at(uint32_t a) {
    if (a >= FB_BASE && a < FB_BASE + fbmem.size()) return &fbmem[a - FB_BASE];
    if (a >= TEX_BASE && a < TEX_BASE + texmem.size()) return &texmem[a - TEX_BASE];
    return nullptr;
}

struct AvPort {
    CData *read, *write, *waitRequestn, *readDataValid;
    IData *address, *writeData, *readData;
    SData *burstCount;
    CData *byteEnable;
    int wr_left = 0; uint32_t wr_addr = 0;
    int rd_left = 0; uint32_t rd_addr = 0; int rd_wait = 0;
    uint64_t bad = 0;

    void drive() {
        *waitRequestn = rd_left == 0;
        *readDataValid = 0;
        if (rd_left && rd_wait == 0) {
            uint8_t *p = mem_at(rd_addr);
            uint32_t d = 0;
            if (p) memcpy(&d, p, 4); else bad++;
            *readDataValid = 1; *readData = d;
        }
    }
    void edge() {
        if (rd_left) {
            if (rd_wait) rd_wait--;
            else { rd_addr += 4; rd_left--; }
        }
        if (*waitRequestn && *write) {
            uint32_t a = wr_left ? wr_addr : *address;
            if (!wr_left) wr_left = *burstCount;
            uint8_t *p = mem_at(a);
            if (p) {
                for (int i = 0; i < 4; i++)
                    if (*byteEnable & (1 << i)) p[i] = (uint8_t)(*writeData >> (8 * i));
            } else if (bad++ < 8) fprintf(stderr, "Voodoo write out of range %08X\n", a);
            wr_addr = a + 4;
            wr_left--;
        } else if (*waitRequestn && *read && !rd_left) {
            rd_addr = *address; rd_left = *burstCount; rd_wait = g_memlat;
        }
    }
};
#define PORT(t, n) AvPort{&t->v_##n##_read, &t->v_##n##_write, &t->v_##n##_waitn, &t->v_##n##_rvalid, \
    &t->v_##n##_addr, &t->v_##n##_wdata, &t->v_##n##_rdata, &t->v_##n##_burst, &t->v_##n##_be}

// ------------------------------------------------------------------------------------------

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *s;
    std::string snap = (s = Verilated::commandArgsPlusMatch("snap=")) && *s ? std::string(s + 6) : "";
    int frames = (s = Verilated::commandArgsPlusMatch("frames=")) && *s ? atoi(s + 8) : 4;
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
    AvPort vp[6] = {PORT(t, fbw), PORT(t, fbcw), PORT(t, fbaw), PORT(t, fbcr), PORT(t, fbar), PORT(t, tex)};
    uint64_t cyc = 0;
    uint64_t a_bad = 0, b_bad = 0;
    std::vector<uint8_t> screen(512 * 384 * 3, 0);

    t->in0 = ports[":IN0"]; t->in1 = ports[":IN1"]; t->in2 = ports[":IN2"]; t->in3 = 0x70;
    t->dsw = ports[":DSW"];
    t->line_clocks = LINE_CLOCKS;
    t->run = 0; t->ld_we = 0; t->ld_v_we = 0;
    t->ppc_dbg_we = 0; t->dsp_dbg_we = 0; t->dsp_dbg_pm_we = 0; t->dsp_dbg_dm_we = 0;

    auto clock = [&]() {
        t->clk = 0;
        // port A
        t->a_ack = 0;
        if (t->a_req) {
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
        if (t->b_req) {
            uint32_t a = t->b_addr, r = a >> 20, d = 0;
            uint32_t *w = r == 0 ? &r500[a & 0xFFFFF] : r == 1 ? &r14[a & 0xFFFFF] : &cg[a & 0x3FFFFF];
            if (t->b_we && r < 2) *w = t->b_wdata;
            else if (t->b_we) { if (b_bad++ < 8) fprintf(stderr, "port B write to CG ROM %06X\n", a); }
            else d = *w;
            t->b_ack = 1; t->b_rdata = d;
        }
        // port C: character RAM; port S: the Voodoo's frame buffer
        t->c_ack = 0;
        if (t->c_req) { t->c_ack = 1; t->c_rdata = chr[t->c_addr & 0x7FFFF]; }
        t->s_ack = 0;
        if (t->s_req) {
            static int dbg_last_line = -1, dbg_n = 0;
            if (Verilated::commandArgsPlusMatch("sdebug")[0] && t->vpos != dbg_last_line && dbg_n < 12) {
                dbg_last_line = t->vpos; dbg_n++;
                fprintf(stderr, "line %d: first scanout read %06X\n", (int)t->vpos, (unsigned)t->s_addr);
            }
            uint32_t a = t->s_addr & 0x3FFFFC, d;
            memcpy(&d, &fbmem[a], 4);
            t->s_ack = 1; t->s_rdata = d;
        }
        for (auto &p : vp) p.drive();
        t->eval();
        if (t->vid_ce && t->vid_de && t->vid_x < 512 && t->vid_y < 384) {
            uint8_t *q = &screen[3 * (t->vid_y * 512 + t->vid_x)];
            q[0] = t->vid_r; q[1] = t->vid_g; q[2] = t->vid_b;
        }
        for (auto &p : vp) p.edge();
        t->clk = 1;
        t->eval();
        cyc++;
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
    uint64_t run0 = cyc, ppc_insns = 0, dsp_insns = 0, overruns = 0, v_wait = 0, v_writes = 0;
    int frame = 0, prev_vpos = FRAME_LINE;
    bool fail = false;
    uint64_t limit = (uint64_t)(frames + 1) * 428 * LINE_CLOCKS;
    while (frame < frames && cyc - run0 < limit && !Verilated::gotFinish()) {
        clock();
        if (t->ppc_dbg_exec) ppc_insns++;
        // +dspio: the SHARC's accesses outside its RAMs, as MAME's io.txt ("R|W addr data")
        {
            static FILE *dio = Verilated::commandArgsPlusMatch("dspio")[0]
                                   ? fopen((snap + "/rtl_dsp_io.txt").c_str(), "w") : nullptr;
            if (dio && t->ev_dsp_acc)
                fprintf(dio, "%c %08X %08X\n", t->ev_dsp_acc_we ? 'W' : 'R', t->ev_dsp_acc_addr, t->ev_dsp_acc_data);
        }
        if (t->dsp_dbg_exec) {
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
        if (t->ev_v_write) v_writes++;
        if (t->vid_overrun) {
            overruns++;
            if (overruns <= 8) fprintf(stderr, "frame %d: line %d not built when shown\n", frame + 1, (int)t->vpos);
        }
        if (t->vpos == FRAME_LINE && prev_vpos != FRAME_LINE) {
            frame++;
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
            fprintf(stderr, "frame %d: SHARC waited %llu clocks on %llu Voodoo writes\n", frame,
                    (unsigned long long)v_wait, (unsigned long long)v_writes);
            fprintf(stderr, "frame %d at %llu clocks: PPC %llu, SHARC %llu instructions; front buffer RTL %u at %06X, "
                    "MAME %u at %06X: %ld of 196608 pixels differ\n", frame, (unsigned long long)(cyc - run0),
                    (unsigned long long)ppc_insns, (unsigned long long)dsp_insns, t->v_displayed & 1, roffs,
                    mfront, moffs, diff);
        }
        prev_vpos = t->vpos;
    }
    if (frame < frames) { fprintf(stderr, "stopped after %d frame(s)\n", frame); fail = true; }
    if (overruns) fprintf(stderr, "%llu line(s) not built in time\n", (unsigned long long)overruns);
    for (auto &p : vp) if (p.bad) fprintf(stderr, "Voodoo port: %llu out-of-range accesses\n", (unsigned long long)p.bad);
    delete t;
    return fail ? 2 : 0;
}
