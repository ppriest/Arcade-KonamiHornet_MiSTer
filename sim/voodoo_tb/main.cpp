// SPDX-License-Identifier: GPL-3.0-or-later
//
// SpinalVoodoo (rtl/voodoo/spinalvoodoo, CoreDe10) against MAME's Voodoo over captured frames.
//
//     scripts/run_verilator.sh voodoo_tb +win=debug/gradius4-voodoo3000
//
// From scripts/mame_voodoo_window.py: memory is preloaded from start/fbram.bin (2 MB frame
// buffer, then 4 MB of TMU memory, placed at SpinalVoodoo's frame-buffer and texture bases),
// MAME's FBI and TMU registers are written through the register port, then every SHARC write
// of the window is replayed in order through the same port. At each frame marker the bench
// waits for the core to go idle. The frame buffer is then compared with end/fbram.bin, pixel by
// pixel, per 512x384 buffer, and a PPM of each buffer is written for both.

// The top model is Vtb_voodoo unless a variant bench includes this file with VTOP set
#ifndef VTOP
#define VTOP Vtb_voodoo
#include "Vtb_voodoo.h"
#include "Vtb_voodoo___024root.h"
#define TEXCHECK            // texture-path texel check (sim/voodoo_tb/texpath.vlt)
#endif
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <sstream>
#include <string>
#include <deque>
#include <vector>

double sc_time_stamp() { return 0; }

// De10AddressMap.scala: the carve-out at the top of 1 GB
static const uint32_t FB_BASE = 0x40000000u - 12u * 1024 * 1024;
static const uint32_t TEX_BASE = FB_BASE + 4u * 1024 * 1024;
static std::vector<uint8_t> fbmem(4u << 20), texmem(8u << 20);
static int g_memlat = 2;                  // clocks from a read burst accepted to its first word (+memlat=)
static int g_memq = 1;                    // read bursts a port may have outstanding (+memq=)
static std::vector<uint16_t> fbwrites(2u << 20);    // writes per frame-buffer byte

static uint8_t *mem_at(uint32_t a) {
    if (a >= FB_BASE && a < FB_BASE + fbmem.size()) return &fbmem[a - FB_BASE];
    if (a >= TEX_BASE && a < TEX_BASE + texmem.size()) return &texmem[a - TEX_BASE];
    return nullptr;
}

// One Avalon-MM slave per master port: a burst is accepted with its first beat; read data
// follows at one word per clock, each burst no sooner than `lat` clocks after it was accepted.
// Up to g_memq read bursts may be outstanding.
struct AvPort {
    CData *read, *write, *waitRequestn, *readDataValid;
    IData *address, *writeData, *readData;
    SData *burstCount;
    CData *byteEnable;
    int wr_left = 0; uint32_t wr_addr = 0;
    // a wide master (hornet_ddr3 WIDE): two words a handshake, the odd one in *_hi
    bool wide = false;
    IData *writeDataHi = nullptr, *readDataHi = nullptr;
    CData *byteEnableHi = nullptr;
    // a master's readReady (vraster's frame-buffer reads): read data comes only the clock after it was high
    CData *readReady = nullptr;
    bool rdy_q = true;
    struct Burst { uint32_t addr; int left; uint64_t ready; };
    std::deque<Burst> rq;
    uint64_t now = 0;
    uint64_t reads = 0, writes = 0, bad = 0, above2m = 0;
    bool due() const { return !rq.empty() && rq.front().ready <= now && (!readReady || rdy_q); }

    void drive() {                         // before the rising edge
        *waitRequestn = (int)rq.size() < g_memq;     // writes never stall otherwise
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
    void edge() {                          // what the rising edge takes
        if (due()) {
            rq.front().addr += wide ? 8 : 4;
            rq.front().left -= wide ? 2 : 1;
            if (rq.front().left <= 0) rq.pop_front();
        }
        if (*waitRequestn && *write) {
            uint32_t a0 = wr_left ? wr_addr : *address;
            if (!wr_left) wr_left = *burstCount;
            for (int h = 0; h < (wide ? 2 : 1); h++) {
                uint32_t a = a0 + 4 * h;
                uint32_t d = h ? *writeDataHi : *writeData;
                uint8_t be = h ? *byteEnableHi : *byteEnable;
                uint8_t *p = mem_at(a);
                if (p) {
                    for (int i = 0; i < 4; i++)
                        if (be & (1 << i)) p[i] = (uint8_t)(d >> (8 * i));
                } else {
                    if (bad < 8) fprintf(stderr, "out-of-range write %08X\n", a);
                    bad++;
                }
                // the 2 MB MAME has: count writes; above it, report the first few
                if (a >= FB_BASE && a < FB_BASE + (2u << 20)) {
                    for (int i = 0; i < 4; i++)
                        if ((be & (1 << i)) && fbwrites[a - FB_BASE + i] < 65535) fbwrites[a - FB_BASE + i]++;
                } else if (a >= FB_BASE + (2u << 20) && a < FB_BASE + (4u << 20)) {
                    if (above2m++ < 8) fprintf(stderr, "frame-buffer write above 2 MB: %08X\n", a - FB_BASE);
                }
                writes++;
            }
            wr_addr = a0 + (wide ? 8 : 4);
            wr_left -= wide ? 2 : 1;
        } else if (*waitRequestn && *read) {
            rq.push_back({*address, (int)*burstCount, now + 1 + g_memlat});
            reads += *burstCount;
        }
        if (readReady) rdy_q = *readReady;
        now++;
    }
};

#define PORT(t, name) AvPort{&t->io_##name##_read, &t->io_##name##_write, &t->io_##name##_waitRequestn, \
    &t->io_##name##_readDataValid, &t->io_##name##_address, &t->io_##name##_writeData, &t->io_##name##_readData, \
    &t->io_##name##_burstCount, &t->io_##name##_byteEnable}

static std::map<std::string, std::vector<uint64_t>> load_items(const std::string &path) {
    std::map<std::string, std::vector<uint64_t>> items;
    FILE *f = fopen(path.c_str(), "r");
    if (!f) { fprintf(stderr, "no %s\n", path.c_str()); exit(1); }
    static char line[65536];
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
    return items;
}

static std::vector<uint8_t> load_bin(const std::string &p) {
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(1); }
    std::vector<uint8_t> v(6u << 20);
    size_t n = fread(v.data(), 1, v.size(), f);
    fclose(f);
    if (n != v.size()) fprintf(stderr, "%s: %zu bytes\n", p.c_str(), n);
    return v;
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

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *s;
    std::string win = (s = Verilated::commandArgsPlusMatch("win=")) && *s ? std::string(s + 5) : "";
    long maxcyc = (s = Verilated::commandArgsPlusMatch("cycles=")) && *s ? atol(s + 8) : 400000000;
    int drain_polls = (s = Verilated::commandArgsPlusMatch("drain=")) && *s ? atoi(s + 7) : 20000;
    if ((s = Verilated::commandArgsPlusMatch("memlat=")) && *s) g_memlat = atoi(s + 8);
    if ((s = Verilated::commandArgsPlusMatch("memq=")) && *s) g_memq = atoi(s + 6);
    if (win.empty()) { fprintf(stderr, "+win=<dir> required\n"); return 1; }
    std::string dir = win + "/";

    auto start = load_bin(dir + "start/fbram.bin");
    auto endm = load_bin(dir + "end/fbram.bin");
    memcpy(fbmem.data(), start.data(), 2u << 20);
    memcpy(texmem.data(), start.data() + (2u << 20), 4u << 20);
    auto items = load_items(dir + "start/vitems.txt");
    auto &fbi = items["m_reg/m_regs"];
    auto &tmu0 = items["m_tmu[0]/m_reg/m_regs"];

    VTOP *t = new VTOP;
#ifdef MEMFIFO                         // vraster: its memory FIFO's ring, a seventh master
    AvPort ports[7] = {PORT(t, memFbWrite), PORT(t, memFbColorWrite), PORT(t, memFbAuxWrite),
                       PORT(t, memFbColorRead), PORT(t, memFbAuxRead), PORT(t, memTex), PORT(t, memFifo)};
    ports[0].wide = true; ports[0].writeDataHi = &t->io_memFbWrite_writeDataHi; ports[0].byteEnableHi = &t->io_memFbWrite_byteEnableHi;
    ports[6].wide = true; ports[6].writeDataHi = &t->io_memFifo_writeDataHi; ports[6].byteEnableHi = &t->io_memFifo_byteEnableHi; ports[6].readDataHi = &t->io_memFifo_readDataHi;
    ports[1].wide = true; ports[1].writeDataHi = &t->io_memFbColorWrite_writeDataHi; ports[1].byteEnableHi = &t->io_memFbColorWrite_byteEnableHi;
    ports[2].wide = true; ports[2].writeDataHi = &t->io_memFbAuxWrite_writeDataHi; ports[2].byteEnableHi = &t->io_memFbAuxWrite_byteEnableHi;
    ports[3].wide = true; ports[3].readDataHi = &t->io_memFbColorRead_readDataHi; ports[3].readReady = &t->io_memFbColorRead_readReady;
    ports[4].wide = true; ports[4].readDataHi = &t->io_memFbAuxRead_readDataHi; ports[4].readReady = &t->io_memFbAuxRead_readReady;
    ports[5].wide = true; ports[5].readDataHi = &t->io_memTex_readDataHi; ports[5].readReady = &t->io_memTex_readReady;
    ports[5].writeDataHi = &t->io_memTex_writeDataHi; ports[5].byteEnableHi = &t->io_memTex_byteEnableHi;
#else
    AvPort ports[6] = {PORT(t, memFbWrite), PORT(t, memFbColorWrite), PORT(t, memFbAuxWrite),
                       PORT(t, memFbColorRead), PORT(t, memFbAuxRead), PORT(t, memTex)};
#endif
    uint64_t cyc = 0;
#ifdef TEXCHECK
    // Texel check: every texture-path request's taps, queued; every returned fetch compared
    // with texture memory at those taps. Needs sim/voodoo_tb/texpath.vlt.
    struct TexReq { uint32_t tap[4]; bool is16, bilinear; uint32_t bank[4], pair[4], lodBase, lodShift; };
    std::deque<TexReq> texq;
    uint64_t tex_fetches = 0, tex_bad = 0;
    auto *R = t->rootp;
#ifndef TBNAME
#define TBNAME tb_voodoo
#endif
#define TP_CAT2(a, b) a##b
#define TP_CAT(a, b) TP_CAT2(a, b)
#define TP(x) R->TP_CAT(TBNAME, TP_CAT(__DOT__dut__DOT__core_1__DOT__pixelPipeline_1__DOT__tmu_1__DOT__texturePath__DOT__, x))
    auto texel_at = [&](uint32_t a, bool is16) -> uint16_t {
        if (a + 2 > texmem.size()) return 0xdead;
        if (is16) return texmem[a & ~1u] | texmem[(a & ~1u) + 1] << 8;
        return texmem[a] | texmem[a] << 8;
    };
    uint64_t fill_words = 0, fill_bad = 0;
    // Recent fills: line, set, way, banks written, fetch count when it started.
    struct FillRec { uint32_t line, set, way, banks; uint64_t at; };
    std::deque<FillRec> fills;
    auto texcheck = [&]() {
        if (TP(fillRsp_fire)) {
            // Every fill word against texture memory at its address.
            uint32_t a = TP(wordAddr), d = TP(fillRsp_payload_fragment_data);
            uint32_t m = a + 4 <= texmem.size() ? texmem[a] | texmem[a + 1] << 8 | texmem[a + 2] << 16 | (uint32_t)texmem[a + 3] << 24 : 0xdeadbeef;
            fill_words++;
            uint32_t line = TP(fill_req_lineBase);
            if (fills.empty() || fills.back().line != line || (a - line) / 4 == 0) {
                if ((a - line) / 4 == 0) fills.push_back({line, (uint32_t)TP(fill_set), (uint32_t)TP(fill_way), 0, tex_fetches});
                if (fills.size() > 8) fills.pop_front();
            }
            if (!fills.empty()) fills.back().banks |= TP(mask);
            if (d != m && fill_bad++ < 12)
                fprintf(stderr, "fill word #%llu: line %06X addr %06X mem %08X got %08X set %u way %u mask %X\n",
                        (unsigned long long)fill_words, (unsigned)TP(fill_req_lineBase), a, m, d,
                        (unsigned)TP(fill_set), (unsigned)TP(fill_way), (unsigned)TP(mask));
        }
        if (TP(io_sampleRequest_valid) && TP(io_sampleRequest_ready)) {
            TexReq q;
            q.bilinear = TP(io_sampleRequest_payload_bilinear);
            q.is16 = TP(io_sampleRequest_payload_is16Bit);
            q.tap[0] = q.bilinear ? TP(io_sampleRequest_payload_biAddr0) : TP(io_sampleRequest_payload_pointAddr);
            q.tap[1] = TP(io_sampleRequest_payload_biAddr1);
            q.tap[2] = TP(io_sampleRequest_payload_biAddr2);
            q.tap[3] = TP(io_sampleRequest_payload_biAddr3);
            q.bank[0] = TP(io_sampleRequest_payload_tapPackedBank_0); q.bank[1] = TP(io_sampleRequest_payload_tapPackedBank_1);
            q.bank[2] = TP(io_sampleRequest_payload_tapPackedBank_2); q.bank[3] = TP(io_sampleRequest_payload_tapPackedBank_3);
            q.pair[0] = TP(io_sampleRequest_payload_tapPackedPair_0); q.pair[1] = TP(io_sampleRequest_payload_tapPackedPair_1);
            q.pair[2] = TP(io_sampleRequest_payload_tapPackedPair_2); q.pair[3] = TP(io_sampleRequest_payload_tapPackedPair_3);
            q.lodBase = TP(io_sampleRequest_payload_lodBase); q.lodShift = TP(io_sampleRequest_payload_lodShift);
            texq.push_back(q);
        }
        if (TP(dbgDataValid) && TP(io_sampleFetch_ready) && !texq.empty()) {
            TexReq q = texq.front(); texq.pop_front();
            uint16_t got[4] = {TP(io_sampleFetch_payload_texels_0), TP(io_sampleFetch_payload_texels_1),
                               TP(io_sampleFetch_payload_texels_2), TP(io_sampleFetch_payload_texels_3)};
            int n = q.bilinear ? 4 : 1;
            bool bad = false;
            for (int i = 0; i < n; i++) bad |= got[i] != texel_at(q.tap[i], q.is16);
            tex_fetches++;
            if (bad && tex_bad++ < 12) {
                fprintf(stderr, "texel mismatch #%llu (%s, %s):", (unsigned long long)tex_fetches,
                        q.bilinear ? "bilinear" : "point", q.is16 ? "16-bit" : "8-bit");
                fprintf(stderr, " lodBase %06X shift %u", q.lodBase, q.lodShift);
                for (int i = 0; i < n; i++) fprintf(stderr, " [%06X b%u p%u mem %04X got %04X]", q.tap[i], q.bank[i], q.pair[i], texel_at(q.tap[i], q.is16), got[i]);
                fprintf(stderr, "\n");
                for (auto &f : fills)
                    fprintf(stderr, "    fill line %06X set %u way %u banks %X (at fetch %llu)\n", f.line, f.set, f.way, f.banks, (unsigned long long)f.at);
            }
        }
    };
#endif
    auto clock = [&]() {
        t->clk = 0; t->io_hdmi_clock = 0;
        for (auto &p : ports) p.drive();
        t->eval();
#ifdef TEXCHECK
        texcheck();
#endif
        for (auto &p : ports) p.edge();
        t->clk = 1; t->io_hdmi_clock = 1;
        t->eval();
        cyc++;
    };
    t->reset = 1; t->io_hdmi_reset = 1;
    t->io_h2fLw_read = 0; t->io_h2fLw_write = 0;
    for (int i = 0; i < 8; i++) clock();
    t->reset = 0; t->io_hdmi_reset = 0;
    for (int i = 0; i < 8; i++) clock();

    // one register-port write, held until the port takes it
    auto wr = [&](uint32_t woff, uint32_t data) {
        t->io_h2fLw_address = woff; t->io_h2fLw_writedata = data; t->io_h2fLw_byteenable = 0xf;
        t->io_h2fLw_write = 1;
        do { t->clk = 0; t->eval(); bool taken = !t->io_h2fLw_waitrequest; clock(); if (taken) break; } while (cyc < (uint64_t)maxcyc);
        t->io_h2fLw_write = 0;
    };
    auto rd = [&](uint32_t woff) -> uint32_t {
        t->io_h2fLw_address = woff; t->io_h2fLw_read = 1;
        do { t->clk = 0; t->eval(); bool taken = !t->io_h2fLw_waitrequest; clock(); if (taken) break; } while (cyc < (uint64_t)maxcyc);
        t->io_h2fLw_read = 0;
        for (int i = 0; i < 1000; i++) { t->clk = 0; t->eval(); if (t->io_h2fLw_readdatavalid) { uint32_t d = t->io_h2fLw_readdata; clock(); return d; } clock(); }
        return 0xdeadbeef;
    };

    // MAME's registers: the video and init registers first, then the rest; commands skipped
    // (regs 0x20 triangleCMD, 0x40 ftriangleCMD, 0x48-0x4a nop/fastfill/swapbuffer, 0x4b userIntr,
    // 0 status); TMU 0's through chip mask 2
    const int order[] = {0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8c};
    for (int r : order) wr(r, (uint32_t)fbi[r]);
    for (int r = 1; r < 0x80; r++) {
        if (r == 0x20 || r == 0x40 || (r >= 0x48 && r <= 0x4b)) continue;
        wr(r, (uint32_t)fbi[r]);
    }
    for (int r = 0xc0; r < 0xc8; r++) wr(0x200 | r, (uint32_t)tmu0[r]);
    fprintf(stderr, "registers loaded at %llu clocks\n", (unsigned long long)cyc);

    FILE *wf = fopen((dir + "writes.txt").c_str(), "r");
    char kind; uint32_t off, data;
    long nwr = 0, nfr = 0;
    char line[128];
    while (fgets(line, sizeof line, wf) && cyc < (uint64_t)maxcyc) {
        if (line[0] == 'W' && sscanf(line, "%c %x %x", &kind, &off, &data) == 3) { wr(off, data); nwr++; }
        else if (line[0] == 'F') {
            // let the pipeline drain: wait for status busy (bit 7) to clear, at most +drain= polls
            for (int i = 0; i < drain_polls; i++) { uint32_t st = rd(0); if (!(st & 0x80)) break; for (int k = 0; k < 64; k++) clock(); }
            nfr++;
            fprintf(stderr, "frame %ld: %ld writes, %llu clocks\n", nfr, nwr, (unsigned long long)cyc);
            // the Voodoo's statistics (fbiPixelsIn, fbiChromaFail, fbiZfuncFail, fbiAfuncFail, fbiPixelsOut)
            fprintf(stderr, "  pixels in %u, chroma fail %u, depth fail %u, alpha fail %u, pixels out %u\n",
                    rd(0x53) & 0xffffff, rd(0x54) & 0xffffff, rd(0x55) & 0xffffff, rd(0x56) & 0xffffff, rd(0x57) & 0xffffff);
        }
    }
    fclose(wf);

    // compare the frame buffer, per buffer: MAME's rgboffs[0..2] and auxoffs
    {
        FILE *f = fopen((dir + "rtl_fbram.bin").c_str(), "wb");
        fwrite(fbmem.data(), 1, 2u << 20, f);
        fclose(f);
        f = fopen((dir + "rtl_fbwrites.bin").c_str(), "wb");
        fwrite(fbwrites.data(), 2, fbwrites.size(), f);
        fclose(f);
    }
    auto eitems = load_items(dir + "end/vitems.txt");
    auto &rgb = eitems["m_rgboffs"];
    uint32_t aux = (uint32_t)eitems["m_auxoffs"][0];
    int rowpix = (int)eitems["*m_renderer.get()/m_rowpixels"][0];
    int front = (int)eitems["m_frontbuf"][0], back = (int)eitems["m_backbuf"][0];
    fprintf(stderr, "MAME: rgboffs %llX %llX %llX auxoffs %X rowpixels %d front %d back %d\n",
            (unsigned long long)rgb[0], (unsigned long long)rgb[1], (unsigned long long)rgb[2], aux, rowpix, front, back);
    long total_bad = 0;
    for (int b = 0; b < 3; b++) {
        uint32_t o = (uint32_t)rgb[b];
        if (o >= (2u << 20) || o == 0xffffffffu) continue;
        long bad = 0;
        for (int y = 0; y < 384; y++)
            for (int x = 0; x < 512; x++) {
                uint32_t a = o + 2 * (y * rowpix + x);
                if (a + 1 >= (2u << 20)) continue;
                if (fbmem[a] != endm[a] || fbmem[a + 1] != endm[a + 1]) bad++;
            }
        fprintf(stderr, "buffer %d%s: %ld of %d pixels differ\n", b, b == front ? " (front)" : b == back ? " (back)" : "",
                bad, 512 * 384);
        ppm(dir + "rtl_buf" + std::to_string(b) + ".ppm", fbmem.data(), o, 512, 384, rowpix);
        ppm(dir + "mame_buf" + std::to_string(b) + ".ppm", endm.data(), o, 512, 384, rowpix);
        total_bad += bad;
    }
    {
        // where the core's writes landed: changed bytes per 64 KB of frame-buffer memory
        std::string h;
        for (uint32_t blk = 0; blk < (2u << 20); blk += 0x10000) {
            long c = 0;
            for (uint32_t a = blk; a < blk + 0x10000; a++) c += fbmem[a] != start[a];
            char b[32]; snprintf(b, sizeof b, "%X:%ld ", blk >> 16, c); if (c) h += b;
        }
        fprintf(stderr, "core changed bytes per 64K block: %s\n", h.c_str());
    }
    for (int i = 0; i < (int)(sizeof ports / sizeof ports[0]); i++)
        fprintf(stderr, "port %d: %llu words read, %llu written, %llu out of range\n", i,
                (unsigned long long)ports[i].reads, (unsigned long long)ports[i].writes, (unsigned long long)ports[i].bad);
#ifdef TEXCHECK
    fprintf(stderr, "texel check: %llu fetches, %llu with a texel not in memory\n",
            (unsigned long long)tex_fetches, (unsigned long long)tex_bad);
    fprintf(stderr, "fill check: %llu words, %llu not as in memory\n",
            (unsigned long long)fill_words, (unsigned long long)fill_bad);
#endif
    fprintf(stderr, "%ld writes, %llu clocks\n", nwr, (unsigned long long)cyc);
    t->final();
    delete t;
    return total_bad ? 1 : 0;
}
