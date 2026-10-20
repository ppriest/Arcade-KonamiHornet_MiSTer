// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami Hornet, one CG board (gradius4): PPC403GA, ADSP-21062 and Voodoo 1 with the glue
// between them, from MAME's hornet.cpp and konppc.cpp, and the picture (hornet_video.sv: the
// Voodoo's displayed buffer under the K037122 tilemap). No sound side (68000, K056800's sound
// half, RF5C400).
//
// Memories too large for block RAM are outside, on two request/acknowledge ports, 32-bit words:
//   port A (PPC):   work RAM, program ROM, data ROM, K037122 character RAM
//   port B (SHARC): RAM at 0x500000, RAM at 0x1400000, CG ROM
//   port C (video): K037122 character RAM, read only (the PPC writes it on port A)
//   port S (video): the Voodoo's frame buffer, read only, for the displayed picture
// a_req/b_req are held until a_ack/b_ack; data with the acknowledge. The Voodoo's six Avalon
// masters are passed through (v_*). Block RAM here: shared RAM (128 KB), K037122 SRAM (128 KB),
// M48T58 (8 KB), K033906 (1 KB).
//
// Clocks: clk is clk_sys; the PPC and Voodoo run every clock (the ratio to the real clocks is not
// modelled), the PPC timebase at clk/2. The SHARC runs on clk_dsp: its shared-RAM port is on that
// clock, and its other accesses cross to the board's decode here through a command FIFO (writes
// answered as they are queued, reads when the board has answered them).
//
// Video timing comes from the Voodoo's hSync/vSync/backPorch/videoDimensions registers, taken
// from the SHARC's writes to them, as MAME's recompute_video_timing does (voodoo.cpp:2746): a
// frame is vSync.off + vSync.on lines of line_clocks clocks; vertical blank runs from line
// vSync.off to line 0 (vblank_start/vblank_stop, voodoo.cpp:2545-2603). line_clocks is an
// input: MAME picks it from its own frame period (HACKS.md).

module hornet_board #(
    parameter RECIP_HEX = "rtl/raster/vraster_recip.hex"   // vraster's seed ROM, from the project
) (
    input  logic        clk,
    input  logic        clk_dsp,       // the SHARC's clock (asynchronous to clk; hornet_cdc)
    input  logic        reset,

    // port A: PPC memories (word address, region in the top bits: 0 work RAM, 1 program ROM,
    // 2-3 data ROM, 4 character RAM)
    output logic        a_req,
    output logic        a_we,
    output logic [22:0] a_addr,
    output logic [3:0]  a_be,          // a_be[3] = bits 31:24 (the PPC's byte 0)
    output logic [31:0] a_wdata,
    input  logic        a_ack,
    input  logic [31:0] a_rdata,

    // port B: SHARC memories (word address: 0 RAM 0x500000, 1 RAM 0x1400000, 2-5 CG ROM)
    output logic        b_req,
    output logic        b_we,
    output logic [22:0] b_addr,
    output logic [31:0] b_wdata,
    input  logic        b_ack,
    input  logic [31:0] b_rdata,

    // port C: K037122 character RAM reads, a tile row of four words (word address as port A
    // region 4, 4-aligned; word k of the row in c_rdata[32k+31:32k])
    output logic        c_req,
    output logic [18:0] c_addr,
    input  logic        c_ack,
    input  logic [127:0] c_rdata,

    // port S: Voodoo frame-buffer reads, an Avalon-MM read master (bursts; byte address of a
    // 32-bit word, relative to the frame buffer as the v_* ports' offsets)
    output logic        s_read,
    output logic [25:0] s_addr,
    output logic [10:0] s_burst,
    input  logic        s_waitn,
    input  logic        s_rvalid,
    input  logic [31:0] s_rdata,
    input  logic [31:0] s_rdata_hi,

    // picture: 512 x 384 of a 644 x vtotal raster, a pixel every 4 clocks
    output logic        vid_ce,
    output logic        vid_de,
    output logic [9:0]  vid_x, vid_y,
    output logic [7:0]  vid_r, vid_g, vid_b,
    output logic        vid_hb, vid_vb, vid_hs, vid_vs,
    output logic        vid_overrun,

    // Voodoo memory masters (vraster's Avalon ports)
    output logic        v_fbw_read, v_fbw_write, v_fbcw_read, v_fbcw_write, v_fbaw_read, v_fbaw_write,
    output logic        v_fbcr_read, v_fbcr_write, v_fbar_read, v_fbar_write, v_tex_read, v_tex_write,
    input  logic        v_fbw_waitn, v_fbcw_waitn, v_fbaw_waitn, v_fbcr_waitn, v_fbar_waitn, v_tex_waitn,
    output logic [31:0] v_fbw_addr, v_fbcw_addr, v_fbaw_addr, v_fbcr_addr, v_fbar_addr, v_tex_addr,
    output logic [10:0] v_fbw_burst, v_fbcw_burst, v_fbaw_burst, v_fbcr_burst, v_fbar_burst, v_tex_burst,
    output logic [3:0]  v_fbw_be, v_fbcw_be, v_fbaw_be, v_fbcr_be, v_fbar_be, v_tex_be,
    output logic [31:0] v_fbw_wdata, v_fbcw_wdata, v_fbaw_wdata, v_fbcr_wdata, v_fbar_wdata, v_tex_wdata,
    // wide masters (hornet_ddr3 WIDE): the beat's odd word beside wdata/be
    output logic [31:0] v_fbw_wdata_hi, v_fbcw_wdata_hi, v_fbaw_wdata_hi, v_mf_wdata_hi,
    output logic [3:0]  v_fbw_be_hi, v_fbcw_be_hi, v_fbaw_be_hi, v_mf_be_hi,
    input  logic [31:0] v_fbcr_rdata_hi, v_fbar_rdata_hi, v_mf_rdata_hi,
    input  logic        v_fbw_rvalid, v_fbcw_rvalid, v_fbaw_rvalid, v_fbcr_rvalid, v_fbar_rvalid, v_tex_rvalid,
    input  logic [31:0] v_fbw_rdata, v_fbcw_rdata, v_fbaw_rdata, v_fbcr_rdata, v_fbar_rdata, v_tex_rdata,
    // ... and its memory FIFO's ring (vraster io_memFifo)
    output logic        v_mf_read, v_mf_write,
    input  logic        v_mf_waitn,
    output logic [31:0] v_mf_addr,
    output logic [10:0] v_mf_burst,
    output logic [3:0]  v_mf_be,
    output logic [31:0] v_mf_wdata,
    input  logic        v_mf_rvalid,
    input  logic [31:0] v_mf_rdata,

    // inputs: sysreg ports 0-2, 3 (without its serial bits), 4 (DIP switches)
    input  logic [7:0]  in0, in1, in2, in3, dsw,
    // the M48T58's clock from the host's time (hornet_rtc), loaded on rtc_set
    input  logic        rtc_set,
    input  logic [55:0] rtc_time,
    // the M48T58 read for the .nvm save (a byte, the clock after its address); nv_wr: a PPC
    // write to it this clock
    input  logic [12:0] nvu_addr,
    output logic [7:0]  nvu_q,
    output logic        nv_wr,
    input  logic [15:0] line_clocks,
    // pause: no new PPC instruction fetch starts and its timebase stops; the PPC stalls when its
    // queue runs dry, its data accesses and the SHARC, Voodoo and picture running on
    input  logic        pause,

    // video state (the harness samples the front buffer at vblank)
    output logic        vblank,
    output logic [9:0]  vpos,
    output logic [1:0]  v_displayed,
    output logic [25:0] v_base0, v_base1,
    output logic [15:0] v_dbg,           // vraster's io_dbg
    input  logic        v_ring_off,      // debug: vraster's io_ring_off
    output logic        v_ring_bad,      // debug: vraster's io_ring_bad

    // state load (benches, savestates), written with the CPUs held (run low)
    input  logic        run,
    input  logic        ld_we,
    input  logic [3:0]  ld_sel,        // see the ld block
    input  logic [16:0] ld_addr,
    input  logic [31:0] ld_data,
    // Voodoo register writes while loading, through the SHARC's path (snooped like the SHARC's)
    input  logic        ld_v_we,
    input  logic [21:0] ld_v_addr,
    input  logic [31:0] ld_v_data,
    output logic        ld_v_busy,

    // CPU debug ports (sim/*_tb numbering)
    output logic        ppc_dbg_exec,
    output logic [31:0] ppc_dbg_pc,
    input  logic [5:0]  ppc_dbg_sel,
    output logic [31:0] ppc_dbg_val,
    input  logic        ppc_dbg_we,
    input  logic [5:0]  ppc_dbg_wsel,
    input  logic [31:0] ppc_dbg_wdata,
    output logic        dsp_dbg_exec,
    output logic [23:0] dsp_dbg_pc,
    output logic [47:0] dsp_dbg_op,
    input  logic [5:0]  dsp_dbg_sel,
    output logic [31:0] dsp_dbg_val,
    input  logic        dsp_dbg_pm_we,
    input  logic [14:0] dsp_dbg_pm_addr,
    input  logic [47:0] dsp_dbg_pm_wdata,
    input  logic        dsp_dbg_dm_we,
    input  logic [14:0] dsp_dbg_dm_addr,
    input  logic [31:0] dsp_dbg_dm_wdata,
    input  logic        dsp_dbg_we,
    input  logic [7:0]  dsp_dbg_wsel,
    input  logic [5:0]  dsp_dbg_widx,
    input  logic [63:0] dsp_dbg_wdata,

    // board events for the harness
    output logic        ev_dsp_reset,      // the PPC released the SHARC's RESET: it boots
    output logic        ev_swapcmd,        // swapbufferCMD written to the Voodoo
    output logic        ev_dsp_idle,       // the SHARC is idle
    output logic        ev_dev,            // a PPC device access answered this clock
    output logic [31:0] ev_dev_addr,
    output logic [31:0] ev_dev_data,
    output logic        ev_dev_we,
    output logic        ev_dsp_comm,       // the SHARC writes a comm register (ev_dev_* hold nothing)
    output logic [31:0] ev_dsp_comm_addr,
    output logic [31:0] ev_dsp_comm_data,
    output logic        ev_v_wait,         // the SHARC waits on the Voodoo's register port
    output logic        ev_v_write,        // a SHARC write to the Voodoo taken
    output logic        ev_dsp_acc,        // a SHARC access to a board device or port B ends this clock
    output logic        ev_dsp_acc_we,
    output logic [31:0] ev_dsp_acc_addr,
    output logic [31:0] ev_dsp_acc_data
);

// ------------------------------------------------------------------------------------------
// Board registers (konppc, hornet sysreg, K033906, K056800 host side)
// ------------------------------------------------------------------------------------------

logic        sh_bank;           // konppc m_dsp_shared_ram_bank: the PPC's bank; the SHARC's is ^1
logic [7:0]  dsp_state;         // konppc m_dsp_state (0x80, |= 0x10 by comm bit 31)
logic        enable_3d;
logic [31:0] comm_ppc [2];      // konppc m_dsp_comm_ppc: PPC to SHARC
logic [31:0] comm_sharc [2];    // m_dsp_comm_sharc: SHARC to PPC
logic        dsp_run;           // comm bit 28 (reset released)
logic        cg_bank;           // CG ROM bank, SHARC comm offset 1 bit 3
logic [1:0]  cg_id;             // sysreg 7 bits 5-4 (konppc set_cgboard_id)
logic        k033906_regs;      // m_reg_set: K033906 window shows its PCI registers
logic [31:0] k033906_membase, k033906_intline, k033906_r14;
logic        irq0;              // PPC IRQ0: Voodoo vblank, cleared by sysreg 7 bit 6
logic [7:0]  snd_to_host [2];   // K056800, written by the (absent) 68000
logic [7:0]  host_to_snd [4];
// Stand-in for the 68000's side of the K056800 (HACKS.md): once SNDRES (sysreg 4 bit 7) lets it
// run, its 344.5 Hz timer (hornet.cpp:1405) counts the low nibble of snd_to_host[0]; a sound
// interrupt (host register 7) is answered SND_ACK clocks later by counting once more and
// toggling bit 7. MAME's boot: 0x05..0x0C, command, 0x8D within 511 polls
// (debug/gradius4-bootlog); in play 0x85 (frame 7500).
localparam int SND_TICK = 185760;      // clk_sys (64 MHz) / (16.9344 MHz / 384 / 128)
localparam int SND_ACK  = 4096;        // the 68000's interrupt handler, well inside MAME's 511 polls
logic        snd_run, snd_pend;
logic [17:0] snd_tick;
logic [12:0] snd_ack;
logic [31:0] k037122_reg [64];

typedef enum logic [1:0] { XS_IDLE, XS_ONE, XS_VRD } xs_t;
xs_t         xs_state;          // SHARC access to a board device
logic [31:0] xs_rdata;
logic        vb_start, vb_stop;

// konppc drops CG-board accesses for board ids it does not have (konppc.cpp:131-150)
wire cg_ok = cg_id == 2'd0;

// ------------------------------------------------------------------------------------------
// Block RAMs
// ------------------------------------------------------------------------------------------

// shared RAM: 2 banks of 16K words; PPC port (32-bit, byte enables), SHARC port (16-bit halves)
logic [14:0] shp_addr, shs_addr;
logic [31:0] shp_q, shs_q, shp_wdata;
logic [3:0]  shp_we;
logic        shs_we, shs_hi;
logic [15:0] shs_wdata;
// a SHARC half is two byte lanes: 3-2 high, 1-0 low
hornet_dpram2 #(.AW(15), .DW(32)) u_shram (
    .clk_a(clk), .clk_b(clk_dsp),
    .a_addr(shp_addr), .a_be(shp_we), .a_wdata(shp_wdata), .a_rdata(shp_q),
    .b_addr(shs_addr), .b_be(shs_we ? (shs_hi ? 4'b1100 : 4'b0011) : 4'b0000),
    .b_wdata({shs_wdata, shs_wdata}), .b_rdata(shs_q)
);

// K037122 SRAM: tilemap and palette, 32K words; port B is the video's. Built as its first three
// quarters (8K words each): gradius4 keeps the palette at 0 and the tilemap at 0x2000-0x5FFF
// (control bit 2 clear) and writes only zeros to the fourth, which reads as 0 here (HACKS.md)
logic [14:0] ks_addr, kv_addr;
logic [31:0] ks_q, kv_q, ks_wdata;
logic [3:0]  ks_we;
logic [31:0] ks_qb [3], kv_qb [3];
logic [1:0]  ks_qs, kv_qs;         // the quarter each read is from
genvar gk;
generate for (gk = 0; gk < 3; gk++) begin : g_ksram
    hornet_dpram #(.AW(13), .DW(32)) u_ksram (
        .clk,
        .a_addr(ks_addr[12:0]), .a_be(ks_addr[14:13] == 2'(gk) ? ks_we : 4'b0), .a_wdata(ks_wdata), .a_rdata(ks_qb[gk]),
        .b_addr(kv_addr[12:0]), .b_be(4'b0), .b_wdata(32'h0), .b_rdata(kv_qb[gk])
    );
end endgenerate
always_ff @(posedge clk) begin ks_qs <= ks_addr[14:13]; kv_qs <= kv_addr[14:13]; end
assign ks_q = (ks_qs == 2'd3) ? 32'h0 : ks_qb[ks_qs];
assign kv_q = (kv_qs == 2'd3) ? 32'h0 : kv_qb[kv_qs];

// M48T58: 8 KB, 4 bytes a PPC word (MAME's 8-bit handlers on the 32-bit bus: a word access
// is 4 consecutive bytes, byte 0 in bits 31:24)
logic [10:0] nv_addr;
logic [31:0] nv_q, nv_wdata;
logic [3:0]  nv_we;
logic [31:0] nvu_w;
hornet_dpram #(.AW(11), .DW(32)) u_nvram (
    .clk,
    .a_addr(nv_addr), .a_be(nv_we), .a_wdata(nv_wdata), .a_rdata(nv_q),
    .b_addr(nvu_addr[12:2]), .b_be(4'b0), .b_wdata(32'h0), .b_rdata(nvu_w)
);
logic [1:0]  nvu_b;
always_ff @(posedge clk) nvu_b <= nvu_addr[1:0];
assign nvu_q = nvu_w[{~nvu_b, 3'b000} +: 8];                  // byte 0 in bits 31:24
// a write that changes what the .nvm keeps: not the clock bytes (reading the clock writes them)
assign nv_wr = nv_we != 4'b0 && run && nv_addr[10:1] != 10'h3FF;
// its clock bytes, 0x1FF8-0x1FFF (words 0x7FE, 0x7FF), are registers; the RAM's copy is not read
logic [31:0] rtc_q;
logic        dv_rtc, dv_rtc_wa;
hornet_rtc u_rtc (
    .clk, .set(rtc_set), .host_time(rtc_time), .tick_en(run), .ld(!run),
    .wa(nv_addr[0]), .we((nv_addr[10:1] == 10'h3FF) ? nv_we : 4'b0), .wdata(nv_wdata),
    .ra(dv_rtc_wa), .rdata(rtc_q)
);

// K033906 RAM: 256 words, the SHARC's; read the clock after its address (XS_ONE)
logic [31:0] kram [256];
logic [31:0] kram_q;
logic        kram_we;
logic [7:0]  kram_a;
logic [31:0] kram_wd;
always_ff @(posedge clk) begin
    if (kram_we) kram[kram_a] <= kram_wd;
    kram_q <= kram[kram_a];
end

// ------------------------------------------------------------------------------------------
// PPC403GA
// ------------------------------------------------------------------------------------------

logic        i_req, i_ack, d_req, d_we, d_ack;
logic [30:0] i_addr, d_addr;
logic [31:0] i_rdata, d_rdata, d_wdata;
logic [3:0]  d_be;
logic        p_req, p_we;
logic [30:0] p_addr;
logic [31:0] p_wdata;
logic [3:0]  p_be;
logic        dcr_we, dcr_re;
logic [9:0]  dcr_addr;
logic [31:0] dcr_wdata;
logic        tb_div;

ppc403_core ppc (
    .clk, .reset, .ce(run), .tb_tick(run && tb_div && !pause),
    .i_req, .i_addr, .i_ack, .i_rdata,
    .d_req(p_req), .d_we(p_we), .d_addr(p_addr), .d_be(p_be), .d_wdata(p_wdata), .d_ack, .d_rdata,
    .dcr_we, .dcr_re, .dcr_addr, .dcr_wdata, .dcr_rdata(32'h0),
    .ext_irq({4'b0, irq0}), .int_irq(9'h0),
    .dbg_exec(ppc_dbg_exec), .dbg_pc(ppc_dbg_pc), .dbg_ir(), .dbg_sel(ppc_dbg_sel),
    .dbg_val(ppc_dbg_val), .dbg_we(ppc_dbg_we), .dbg_wsel(ppc_dbg_wsel), .dbg_wdata(ppc_dbg_wdata)
);

always_ff @(posedge clk) if (reset) tb_div <= 1'b0; else if (run) tb_div <= !tb_div;

// The PPC's data request registered before the address decode: the effective-address add
// and the decode do not fit one clock. The PPC waits in X_MEM for d_ack, one clock longer.
always_ff @(posedge clk) begin
    d_req <= !reset && run && p_req;
    d_we <= p_we; d_addr <= p_addr; d_be <= p_be; d_wdata <= p_wdata;
end

// port A address of a PPC address, and whether it is on port A (hornet.cpp:947-963)
function automatic logic [23:0] ppc_port_a(input logic [30:0] a);   // {hit, word address}
    logic [31:0] ba;
    ba = {1'b0, a};
    if (ba < 32'h0040_0000)                               ppc_port_a = {1'b1, 3'd0, ba[21:2]};
    else if (ba >= 32'h7F00_0000 && ba < 32'h7F40_0000)   ppc_port_a = {1'b1, 3'd1, ba[21:2]};
    else if (ba >= 32'h7FC0_0000)                         ppc_port_a = {1'b1, 3'd1, ba[21:2]};
    else if (ba >= 32'h7E00_0000 && ba < 32'h7E80_0000)   ppc_port_a = {1'b1, 2'd1, ba[22:2]};
    else if (ba >= 32'h7404_0000 && ba < 32'h7408_0000)   // char RAM window, bank from reg 0x30
        ppc_port_a = {1'b1, 3'd4, 1'b0, k037122_reg[12][2:0], ba[17:2]};
    else                                                  ppc_port_a = '0;
endfunction

// PPC data accesses to the board's own devices: one clock
wire [31:0] da = {1'b0, d_addr};
wire d_sh   = da >= 32'h7800_0000 && da < 32'h7801_0000;
wire d_comm = da >= 32'h780C_0000 && da < 32'h780C_0004;
wire d_kreg = da >= 32'h7400_0000 && da < 32'h7400_0100;
wire d_ksr  = da >= 32'h7402_0000 && da < 32'h7404_0000;
wire d_sysr = da >= 32'h7D00_0000 && da < 32'h7D01_0000;
wire d_sysw = da >= 32'h7D01_0000 && da < 32'h7D02_0000;
wire d_nv   = da >= 32'h7D02_0000 && da < 32'h7D02_2000;
wire d_snd  = da >= 32'h7D03_0000 && da < 32'h7D03_0010;
wire d_spu  = da >= 32'h4000_0000 && da < 32'h4000_0010;
wire [23:0] d_pa = ppc_port_a(d_addr);
wire [23:0] i_pa = ppc_port_a(i_addr);

// the PPC's fetches through its instruction cache (hornet_icache), whose fills go on port A
logic        ic_mreq, ic_mack;
logic [22:0] ic_maddr;
hornet_icache u_icache (
    .clk, .reset, .run, .pause,
    .req(i_req), .addr(i_pa[22:0]), .ack(i_ack), .rdata(i_rdata),
    .m_req(ic_mreq), .m_addr(ic_maddr), .m_ack(ic_mack), .m_rdata(a_rdata),
    .st(d_req && d_we && d_pa[23]), .st_addr(d_pa[22:0])
);

// the byte lane of a byte-wide device: d_be[3] is byte 0
function automatic logic [1:0] lane(input logic [3:0] be);
    lane = be[3] ? 2'd0 : be[2] ? 2'd1 : be[1] ? 2'd2 : 2'd3;
endfunction

// port A: one access at a time, data side first
logic        ai_pend, ad_pend, a_busy, a_own_d;
logic [22:0] ai_addr, ad_addr;
logic        ad_we;
logic [3:0]  ad_be;
logic [31:0] ad_wdata;

// device side of the data bus
logic        dv_pend;            // a device access answered next clock
logic [31:0] dv_rdata;
logic        dv_bram;            // ...with its data from a block RAM
logic [1:0]  dv_bram_sel;        // 0 shared, 1 K037122 SRAM, 2 M48T58
logic [1:0]  dv_lane;

always_comb begin
    shp_addr = {sh_bank, d_addr[15:2]};
    shp_wdata = d_wdata;
    shp_we = (run && d_req && d_we && d_sh && cg_ok) ? d_be : 4'b0;
    ks_addr = d_addr[16:2];
    ks_wdata = d_wdata;
    ks_we = (run && d_req && d_we && d_ksr) ? d_be : 4'b0;
    nv_addr = d_addr[12:2];
    nv_wdata = d_wdata;
    nv_we = (run && d_req && d_we && d_nv) ? d_be : 4'b0;
    // state load: the same ports, the CPUs held
    if (!run && ld_we) begin
        shp_addr = ld_addr[14:0]; shp_wdata = ld_data; shp_we = {4{ld_sel == 4'd0}};
        ks_addr  = ld_addr[14:0]; ks_wdata  = ld_data; ks_we  = {4{ld_sel == 4'd1}};
        // a byte: ld_addr[1:0] 0 is bits 31:24
        nv_addr  = ld_addr[12:2]; nv_wdata = {4{ld_data[7:0]}};
        nv_we = (ld_sel == 4'd2) ? 4'(4'b1000 >> ld_addr[1:0]) : 4'b0;
    end
end

logic [31:0] dv_addr, dv_wdata;
logic        dv_we;
assign ev_dev = dv_pend;
assign ev_dsp_comm = x_req && x_we && xs_comm && xs_state == XS_IDLE;
assign ev_dsp_comm_addr = x_addr;
assign ev_dsp_comm_data = x_wdata;
assign ev_v_wait  = run && x_req && xs_vd && !x_ack;
assign ev_v_write = run && x_req && xs_vd && x_we && x_ack;
assign ev_dsp_acc      = x_req && x_ack;
assign ev_dsp_acc_we   = x_we;
assign ev_dsp_acc_addr = x_addr;
assign ev_dsp_acc_data = x_we ? x_wdata : x_rdata;
assign ev_dev_addr = dv_addr;
assign ev_dev_data = dv_we ? dv_wdata : d_rdata;
assign ev_dev_we = dv_we;

assign ic_mack = a_ack && a_busy && !a_own_d;
always_comb begin
    d_ack = (a_ack && a_busy && a_own_d) || dv_pend;
    d_rdata = a_rdata;
    if (dv_pend) begin
        if (!dv_bram) d_rdata = dv_rdata;
        else case (dv_bram_sel)
            2'd0: d_rdata = shp_q;
            2'd1: d_rdata = ks_q;
            default: d_rdata = dv_rtc ? rtc_q : nv_q;
        endcase
    end
end

assign a_req = a_busy;

always_ff @(posedge clk) begin
    if (reset) begin
        ai_pend <= 1'b0; ad_pend <= 1'b0; a_busy <= 1'b0; dv_pend <= 1'b0;
    end else begin
        dv_pend <= 1'b0;
        if (d_req) begin
            if (d_pa[23]) ;                    // port A, below
            else begin
                // board devices (hornet.cpp:947-963, konppc.cpp:131-222)
                dv_pend <= 1'b1;
                dv_addr <= {1'b0, d_addr}; dv_wdata <= d_wdata; dv_we <= d_we;
                dv_bram <= 1'b0;
                dv_rdata <= 32'h0;
                dv_lane <= lane(d_be);
                if (d_sh) begin
                    dv_bram <= cg_ok; dv_bram_sel <= 2'd0;
                end else if (d_ksr) begin
                    dv_bram <= 1'b1; dv_bram_sel <= 2'd1;
                end else if (d_nv) begin
                    dv_bram <= 1'b1; dv_bram_sel <= 2'd2;
                    dv_rtc <= d_addr[12:3] == 10'h3FF; dv_rtc_wa <= d_addr[2];
                end else if (d_comm && cg_ok) begin
                    if (!d_we) dv_rdata <= comm_sharc[0] | {8'h0, dsp_state, 16'h0};
                end else if (d_kreg) begin
                    // reg 0x14 reads 0x3fa (k037122.cpp reg_r)
                    if (!d_we) dv_rdata <= (d_addr[7:2] == 6'h05) ? 32'h3FA : k037122_reg[d_addr[7:2]];
                end else if (d_sysr) begin
                    logic [7:0] r;
                    case ({d_addr[15:2], lane(d_be)} & 16'hFFFF)
                    16'd0: r = in0;
                    16'd1: r = in1;
                    16'd2: r = in2;
                    16'd3: r = in3;
                    16'd4: r = dsw;
                    default: r = 8'h0;
                    endcase
                    dv_rdata <= {4{r}};
                end else if (d_spu) begin
                    // SPLS reads 0x06 (transmit buffer and shift register empty) in MAME's boot;
                    // the serial port itself is not in the core (HACKS.md)
                    if (!d_we && d_addr[3:0] == 4'h0) dv_rdata <= 32'h0600_0000;
                end else if (d_snd) begin
                    logic [2:0] o;
                    o = {d_addr[2], lane(d_be)};
                    dv_rdata <= {4{(o < 3'd2) ? snd_to_host[o[0]] : 8'h0}};
                end
            end
        end

        // port A: the next access, the data side first, a request of this clock or a waiting one;
        // what does not go now waits in ad_* / ai_*
        begin
            logic dn, in_, free, go_d, go_i;
            dn  = d_req && d_pa[23];
            in_ = ic_mreq;
            free = !a_busy || a_ack;
            go_d = free && (ad_pend || dn);
            go_i = free && !go_d && (ai_pend || in_) && !pause;
            if (a_busy && a_ack) a_busy <= 1'b0;
            if (go_d) begin
                a_busy <= 1'b1; a_own_d <= 1'b1;
                if (ad_pend) begin
                    a_addr <= ad_addr; a_we <= ad_we; a_be <= ad_be; a_wdata <= ad_wdata;
                end else begin
                    a_addr <= d_pa[22:0]; a_we <= d_we; a_be <= d_be; a_wdata <= d_wdata;
                end
            end else if (go_i) begin
                a_busy <= 1'b1; a_own_d <= 1'b0;
                a_addr <= ai_pend ? ai_addr : ic_maddr; a_we <= 1'b0; a_be <= 4'hF;
            end
            // waiting requests: taken, or newly arrived and not taken
            if (go_d && ad_pend) ad_pend <= 1'b0;
            if (dn && !(go_d && !ad_pend)) begin
                ad_pend <= 1'b1; ad_addr <= d_pa[22:0];
                ad_we <= d_we; ad_be <= d_be; ad_wdata <= d_wdata;
            end
            if (go_i && ai_pend) ai_pend <= 1'b0;
            if (in_ && !(go_i && !ai_pend)) begin ai_pend <= 1'b1; ai_addr <= ic_maddr; end
        end
    end
end

// SHARC IRQ requests from the PPC (comm bits 25, 26): set the SHARC's pending bits
wire [2:0] dsp_irq_assert = (run && d_req && d_we && !d_pa[23] && d_comm && cg_ok && d_be[3]) ?
                            {1'b0, d_wdata[26], d_wdata[25]} : 3'b0;

// ------------------------------------------------------------------------------------------
// SHARC
// ------------------------------------------------------------------------------------------

logic        x_req, x_we, x_ack;
logic [31:0] x_addr, x_wdata, x_rdata;

// ---------------------------------------------------------------- the SHARC's clock domain
logic        dx_req, dx_we, dx_ack;
logic [31:0] dx_addr, dx_wdata, dx_rdata;
logic        dsp_reset, dsp_ce, dsp_ce1, dsp_boot, sh_bank_d;
logic [1:0]  dsp_irq;
// reset, run and the shared-RAM bank into clk_dsp; the enable a flop later, so that it rises with
// the boot pulse (three flops through hornet_pulse)
hornet_sync u_srst (.clk(clk_dsp), .d(reset), .q(dsp_reset));
hornet_sync u_sce  (.clk(clk_dsp), .d(run && dsp_run), .q(dsp_ce1));
hornet_sync u_sbk  (.clk(clk_dsp), .d(sh_bank), .q(sh_bank_d));
always_ff @(posedge clk_dsp) dsp_ce <= dsp_ce1;
hornet_pulse u_sboot (.clk_a(clk), .a(ev_dsp_reset), .clk_b(clk_dsp), .b(dsp_boot));
hornet_pulse u_sirq0 (.clk_a(clk), .a(dsp_irq_assert[0]), .clk_b(clk_dsp), .b(dsp_irq[0]));
hornet_pulse u_sirq1 (.clk_a(clk), .a(dsp_irq_assert[1]), .clk_b(clk_dsp), .b(dsp_irq[1]));

sharc2_core #(.DM_WORDS(16384)) dsp (     // gradius4 uses below 0x2A800 (docs/HACKS.md)
    .clk(clk_dsp), .reset(dsp_reset), .ce(dsp_ce), .boot(dsp_boot), .serial(1'b0),
    .ext_req(dx_req), .ext_we(dx_we), .ext_addr(dx_addr), .ext_wdata(dx_wdata),
    .ext_ack(dx_ack), .ext_rdata(dx_rdata),
    .irq_in(3'b0), .irq_assert({1'b0, dsp_irq}), .irq_check_en(1'b1), .dbg_irq_set(32'h0),
    .dbg_iop_ovr(1'b0), .dbg_iop_val(32'h0),
    .dbg_exec(dsp_dbg_exec), .dbg_pc(dsp_dbg_pc), .dbg_op(dsp_dbg_op), .dbg_sel(dsp_dbg_sel),
    .dbg_val(dsp_dbg_val), .dbg_idle(ev_dsp_idle),
    .dbg_pm_we(dsp_dbg_pm_we), .dbg_pm_addr(dsp_dbg_pm_addr), .dbg_pm_wdata(dsp_dbg_pm_wdata),
    .dbg_dm_we(dsp_dbg_dm_we), .dbg_dm_addr(dsp_dbg_dm_addr), .dbg_dm_wdata(dsp_dbg_dm_wdata),
    .dbg_we(dsp_dbg_we), .dbg_wsel(dsp_dbg_wsel), .dbg_widx(dsp_dbg_widx), .dbg_wdata(dsp_dbg_wdata)
);

// the shared RAM, the SHARC's half-words (konppc.cpp:291-313: odd offset low half, even high):
// the address the first clock (a write then), the answer the second
wire  dx_sh = dx_addr >= 32'h0040_0000 && dx_addr < 32'h0042_0000;
logic sh_ph;                            // the second clock of a shared-RAM access
assign shs_addr  = {!sh_bank_d, dx_addr[14:1]};
assign shs_hi    = !dx_addr[0];
assign shs_wdata = dx_wdata[15:0];
assign shs_we    = dsp_ce && dx_req && dx_we && dx_sh && !sh_ph;

// everything else: queued for the board ({we, word address, data}); a write is answered as it is
// queued, a single read when the board's answer has crossed back (cr_*). Port B's regions (the
// SHARC's DMA streams from RAM 0x1400000) are read through two lines of 8 words on this side: a
// miss queues a line read (data bit 0 set), whose words come back in order through rq_*, and the
// line after the one in use is fetched behind it. A write into a line drops it; a comm write
// (it may switch the CG ROM bank) drops both.
typedef enum logic [1:0] { DB_IDLE, DB_RD, DB_RDY } db_t;
db_t         dbs;
logic        cq_full, cq_empty, cq_pop, cq_push;
logic [58:0] cq_head, cq_in;
logic        cr_t, cr_new;
logic [31:0] cr_data, cr_dsp;
logic        rq_full, rq_empty, rq_pop, rq_push;
logic [31:0] rq_head;
hornet_afifo #(.AW(3), .DW(59)) u_cq (
    .clk_w(clk_dsp), .rst_w(dsp_reset), .w_push(cq_push), .w_data(cq_in), .w_full(cq_full),
    .clk_r(clk), .rst_r(reset), .r_pop(cq_pop), .r_data(cq_head), .r_empty(cq_empty));
hornet_afifo #(.AW(4), .DW(32)) u_rq (
    .clk_w(clk), .rst_w(reset), .w_push(rq_push), .w_data(x_rdata), .w_full(rq_full),
    .clk_r(clk_dsp), .rst_r(dsp_reset), .r_pop(rq_pop), .r_data(rq_head), .r_empty(rq_empty));
hornet_pulse u_cr (.clk_a(clk), .a(cr_t), .clk_b(clk_dsp), .b(cr_new));

// the lines: tag (word address bits 25:3), allocated, words in (in order), dropped while filling
wire         dx_b = (dx_addr >= 32'h0050_0000 && dx_addr < 32'h0060_0000) ||
                    (dx_addr >= 32'h0140_0000 && dx_addr < 32'h0150_0000) ||
                    (dx_addr >= 32'h0360_0000 && dx_addr < 32'h0380_0000);
wire         dx_cm = dx_addr >= 32'h0340_0000 && dx_addr < 32'h0340_0100;
logic [22:0] lt [2];
logic [1:0]  la, ls;                    // allocated, stale
logic [3:0]  lw [2];                    // words in
logic [1:0]  fq;                        // fills queued: fq[0] the one receiving
logic        fq_n;                      // ... and how many (0: none, else fq_n + 1)
logic        f_any;
logic        l_mru;
logic [31:0] lq;
wire  [22:0] dl = dx_addr[25:3];
wire         lh0 = la[0] && !ls[0] && lt[0] == dl, lh1 = la[1] && !ls[1] && lt[1] == dl;
wire         lhs = lh1;
wire         lhit = lh0 || lh1;
wire         lword = lw[lhs] > {1'b0, dx_addr[2:0]};
wire         lfill0 = f_any && fq[0] == 1'b0 || f_any && fq_n && fq[1] == 1'b0;
wire         lfill1 = f_any && fq[0] == 1'b1 || f_any && fq_n && fq[1] == 1'b1;
wire  [1:0]  lfilling = {lfill1, lfill0};
sharc2_lutram #(.AW(4), .DW(32)) u_lines (.clk(clk_dsp), .we(rq_pop), .wa({fq[0], lw[fq[0]][2:0]}),
    .wd(rq_head), .ra({lhs, dx_addr[2:0]}), .rd(lq));

wire         d_brd = dx_req && !dx_we && dx_b;
wire         l_ack = dsp_ce && d_brd && lhit && lword && dbs == DB_IDLE;
// a push this clock: the request itself (a write, or a single read), else a miss's line, else
// the line after the one in use
wire         dq_go = dsp_ce && dx_req && !dx_sh && !d_brd && dbs == DB_IDLE && !cq_full;
wire         lv    = !l_mru;            // a miss's slot: the one not used last
wire         miss_go = d_brd && !lhit && !lfilling[lv] && !(f_any && fq_n) && !cq_full && !dq_go;
wire  [22:0] nl = dl + 23'd1;
wire         nv = !lhs;
wire         pf_go = d_brd && lhit && !(la[nv] && lt[nv] == nl) && !lfilling[nv] && !(f_any && fq_n) &&
                     !cq_full && !dq_go && !miss_go;
assign cq_push = dq_go || miss_go || pf_go;
assign cq_in   = dq_go ? {dx_we, dx_addr[25:0], dx_wdata} :
                 {1'b0, (miss_go ? dl : nl), 3'b000, 32'h1};
assign rq_pop  = !rq_empty && f_any;

always_ff @(posedge clk_dsp) begin
    if (dsp_ce && dx_req && dx_sh && !sh_ph) sh_ph <= 1'b1;
    else if (dsp_ce && sh_ph) sh_ph <= 1'b0;
    case (dbs)
    DB_IDLE: if (dq_go && !dx_we) dbs <= DB_RD;
    DB_RD: if (cr_new) begin cr_dsp <= cr_data; dbs <= DB_RDY; end
    DB_RDY: if (dsp_ce) dbs <= DB_IDLE;
    default: dbs <= DB_IDLE;
    endcase
    if (l_ack) l_mru <= lhs;
    // a line's words as they come
    if (rq_pop) begin
        lw[fq[0]] <= lw[fq[0]] + 4'd1;
        if (lw[fq[0]] == 4'd7) begin
            if (ls[fq[0]]) la[fq[0]] <= 1'b0;
            if (fq_n) begin fq[0] <= fq[1]; fq_n <= 1'b0; end else f_any <= 1'b0;
        end
    end
    // a new fill
    if (miss_go || pf_go) begin
        logic sl;
        sl = miss_go ? lv : nv;
        lt[sl] <= miss_go ? dl : nl; la[sl] <= 1'b1; ls[sl] <= 1'b0; lw[sl] <= 4'd0;
        if (!f_any || (rq_pop && lw[fq[0]] == 4'd7 && !fq_n)) begin fq[0] <= sl; f_any <= 1'b1; end
        else begin fq[1] <= sl; fq_n <= 1'b1; end
    end
    // writes into a line drop it; a comm write drops both
    if (dq_go && dx_we && (dx_b || dx_cm))
        for (int k = 0; k < 2; k++)
            if (dx_cm || (la[k] && lt[k] == dl)) begin
                if (lfilling[k]) ls[k] <= 1'b1; else la[k] <= 1'b0;
            end
    if (dsp_reset) begin sh_ph <= 1'b0; dbs <= DB_IDLE; la <= 2'b00; f_any <= 1'b0; fq_n <= 1'b0; end
end
always_comb begin
    dx_ack = sh_ph || (dq_go && dx_we) || dbs == DB_RDY || l_ack;
    dx_rdata = sh_ph ? {16'h0, shs_hi ? shs_q[31:16] : shs_q[15:0]} : l_ack ? lq : cr_dsp;
end

// ---------------------------------------------------------------- the board's side
// the queue's head is the request the board's decode below answers (x_*): a single access, or a
// line's eight reads (lk), whose words go back through rq; a single read's answer through cr_data
logic [2:0]  lk;
wire         c_line = !cq_head[58] && cq_head[0];
assign x_req   = !cq_empty && !(c_line && rq_full);
assign x_we    = cq_head[58];
assign x_addr  = {6'h0, cq_head[57:35], c_line ? lk : cq_head[34:32]};
assign x_wdata = cq_head[31:0];
assign cq_pop  = x_req && x_ack && (!c_line || lk == 3'd7);
assign rq_push = x_req && x_ack && c_line;
always_ff @(posedge clk) begin
    cr_t <= 1'b0;
    if (x_req && x_ack && !x_we && !c_line) begin cr_data <= x_rdata; cr_t <= 1'b1; end
    if (x_req && x_ack && c_line) lk <= lk + 3'd1;
    if (reset) lk <= 3'd0;
end

// SHARC data map (hornet.cpp:1057-1066), word addresses
wire xs_r500 = x_addr >= 32'h0050_0000 && x_addr < 32'h0060_0000;
wire xs_r14  = x_addr >= 32'h0140_0000 && x_addr < 32'h0150_0000;
wire xs_vd   = x_addr >= 32'h0240_0000 && x_addr < 32'h0280_0000;
wire xs_comm = x_addr >= 32'h0340_0000 && x_addr < 32'h0340_0100;
wire xs_k33  = x_addr >= 32'h0350_0000 && x_addr < 32'h0350_0100;
wire xs_cg   = x_addr >= 32'h0360_0000 && x_addr < 32'h0380_0000;
wire xs_b    = xs_r500 || xs_r14 || xs_cg;

// port B
assign b_req   = x_req && xs_b;
assign b_we    = x_we;
assign b_wdata = x_wdata;
always_comb
    if (xs_r500)     b_addr = {3'd0, x_addr[19:0]};
    else if (xs_r14) b_addr = {3'd1, x_addr[19:0]};
    else             b_addr = 23'h20_0000 + {1'b0, cg_bank, x_addr[20:0]};  // from region 2, 2M words a bank

// shared RAM, the SHARC's half-words (konppc.cpp:291-313): odd offset low half, even high
always_comb begin
    kram_a = x_addr[7:0];
    kram_wd = x_wdata;
    kram_we = run && x_req && x_we && xs_k33 && !k033906_regs && xs_state == XS_IDLE;
    if (!run && ld_we && ld_sel == 4'd3) begin kram_a = ld_addr[7:0]; kram_wd = ld_data; kram_we = 1'b1; end
end


// Voodoo register port (vraster h2fLw)
logic        h_read, h_write, h_wait, h_rvalid;
logic [21:0] h_addr;
logic [31:0] h_wdata, h_rdata;

// the Voodoo port is the SHARC's, or the loader's while the CPUs are held
wire         vp_sharc = x_req && xs_vd && (xs_state == XS_IDLE);
assign h_read  = vp_sharc && !x_we;
assign h_write = (vp_sharc && x_we) || (!run && ld_v_we);
assign h_addr  = run ? x_addr[21:0] : ld_v_addr;
assign h_wdata = run ? x_wdata : ld_v_data;
assign ld_v_busy = h_wait;

always_comb begin
    x_ack = 1'b0;
    x_rdata = xs_rdata;
    if (xs_b) begin
        x_ack = b_ack;
        x_rdata = xs_r500 ? {16'h0, b_rdata[15:0]} : b_rdata;    // hornet.cpp:1060
    end else if (xs_vd) begin
        if (xs_state == XS_IDLE && x_we) x_ack = x_req && !h_wait;
        else if (xs_state == XS_VRD) begin x_ack = h_rvalid; x_rdata = h_rdata; end
    end else if (xs_state == XS_ONE) begin
        x_ack = 1'b1;
        x_rdata = (xs_k33 && !k033906_regs) ? kram_q : xs_rdata;
    end
end

// ------------------------------------------------------------------------------------------
// State load
// ------------------------------------------------------------------------------------------
//   0 shared RAM word (ld_addr[14:0])       1 K037122 SRAM word       2 M48T58 byte
//   3 K033906 RAM word (ld_addr[7:0])       4 K037122 register (ld_addr[5:0])
//   5 comm: addr 0/1 comm_ppc, 2/3 comm_sharc, 4 {bank, dsp_run, k033906_regs, cg_bank,
//     enable_3d} in bits 4..0, 5 dsp_state, 6 cg_id, 7 irq0
//   6 K033906 registers: addr 0 membase, 1 intline, 2 reg 0x14
//   7 K056800: addr 0-1 snd_to_host, 2-5 host_to_snd, 6 {pending, SNDRES} of the 68000 stand-in
//   8 video: vpos in bits 9:0, vblank in bit 16 (above)
//   9 Voodoo CLUT entry ld_addr[5:0] (0-32), 0x00RRGGBB (above)
task automatic ld_regs();
    case (ld_sel)
    4'd4: k037122_reg[ld_addr[5:0]] <= ld_data;
    4'd5: case (ld_addr[2:0])
        3'd0: comm_ppc[0] <= ld_data;
        3'd1: comm_ppc[1] <= ld_data;
        3'd2: comm_sharc[0] <= ld_data;
        3'd3: comm_sharc[1] <= ld_data;
        3'd4: {sh_bank, dsp_run, k033906_regs, cg_bank, enable_3d} <= ld_data[4:0];
        3'd5: dsp_state <= ld_data[7:0];
        3'd6: cg_id <= ld_data[1:0];
        default: irq0 <= ld_data[0];
        endcase
    4'd6: case (ld_addr[1:0])
        2'd0: k033906_membase <= ld_data;
        2'd1: k033906_intline <= ld_data;
        default: k033906_r14 <= ld_data;
        endcase
    4'd7: if (ld_addr[2:0] < 3'd2) snd_to_host[ld_addr[0]] <= ld_data[7:0];
          else if (ld_addr[2:0] < 3'd6) host_to_snd[2'(ld_addr[2:0] - 3'd2)] <= ld_data[7:0];
          else begin snd_run <= ld_data[0]; snd_pend <= ld_data[1]; end
    default: ;
    endcase
endtask

// Board registers: the PPC's writes, the SHARC's accesses to comm and K033906, state loads
always_ff @(posedge clk) begin
    if (reset) begin
        irq0 <= 1'b0;
        ev_dsp_reset <= 1'b0;
        xs_state <= XS_IDLE;
        // power-on: konppc's init (konppc.cpp:49-58), the SHARC held in reset (hornet.cpp:1352)
        sh_bank <= 1'b0; dsp_state <= 8'h80; enable_3d <= 1'b0; dsp_run <= 1'b0;
        comm_ppc[0] <= 32'h0; comm_ppc[1] <= 32'h0; comm_sharc[0] <= 32'h0; comm_sharc[1] <= 32'h0;
        cg_bank <= 1'b0; cg_id <= 2'd0; k033906_regs <= 1'b0;
        k033906_membase <= 32'h0; k033906_intline <= 32'h0; k033906_r14 <= 32'h0;
        for (int i = 0; i < 2; i++) snd_to_host[i] <= 8'h0;
        snd_run <= 1'b0; snd_pend <= 1'b0; snd_tick <= 18'd0; snd_ack <= 13'd0;
        for (int i = 0; i < 4; i++) host_to_snd[i] <= 8'h0;
        for (int i = 0; i < 64; i++) k037122_reg[i] <= 32'h0;
    end else begin
        ev_dsp_reset <= 1'b0;
        if (run && d_req && d_we && !d_pa[23]) begin
            if (d_comm && cg_ok) begin
                // konppc.cpp cgboard_dsp_comm_w_ppc
                if (d_be[3]) begin
                    sh_bank <= d_wdata[24];
                    if (d_wdata[31]) dsp_state <= dsp_state | 8'h10;
                    k033906_regs <= d_wdata[29];
                    dsp_run <= d_wdata[28];
                    // RESET released: MAME resets the SHARC then (diexec.cpp:717-729), with its
                    // EPROM boot from shared RAM
                    if (d_wdata[28] && !dsp_run) ev_dsp_reset <= 1'b1;
                end
                if (d_be[1] || d_be[2]) enable_3d <= d_wdata[22];
                if (d_be[0]) comm_ppc[0] <= {24'h0, d_wdata[7:0]};
            end
            if (d_kreg)
                for (int b = 0; b < 4; b++)
                    if (d_be[b]) k037122_reg[d_addr[7:2]][b*8 +: 8] <= d_wdata[b*8 +: 8];
            if (d_sysw) begin
                // sysreg 7 (hornet.cpp:798-819): bit 6 clears IRQ0, bits 5-4 the CG board id
                if ({d_addr[15:2], lane(d_be)} == 16'd7) begin
                    if (d_wdata[6]) irq0 <= 1'b0;
                    cg_id <= d_wdata[5:4];
                end
            end
            if (d_snd && {d_addr[2], lane(d_be)} < 3'd4)
                host_to_snd[{d_addr[2], lane(d_be)}] <= d_wdata[8*(3 - lane(d_be)) +: 8];
            if (d_snd && {d_addr[2], lane(d_be)} == 3'd7) begin                  // sound interrupt
                snd_pend <= 1'b1; snd_ack <= 13'd0;
            end
            if (d_sysw && {d_addr[15:2], lane(d_be)} == 16'd4)
                snd_run <= d_wdata[8*(3 - lane(d_be)) + 7];                   // SNDRES
        end
        // the stand-in's timer tick
        if (!snd_run) snd_tick <= 18'd0;
        else if (!run) ;
        else begin
            logic [3:0] c;
            c = snd_to_host[0][3:0];
            if (snd_tick == 18'(SND_TICK - 1)) begin snd_tick <= 18'd0; c = c + 4'd1; end
            else snd_tick <= snd_tick + 18'd1;
            if (snd_pend) begin
                if (snd_ack == 13'(SND_ACK - 1)) begin
                    c = c + 4'd1;
                    snd_to_host[0][7] <= !snd_to_host[0][7];
                    snd_pend <= 1'b0;
                end else snd_ack <= snd_ack + 13'd1;
            end
            snd_to_host[0][3:0] <= c;
        end
        if (vb_start) irq0 <= 1'b1;
        if (vb_stop)  irq0 <= 1'b0;

        case (xs_state)
        XS_IDLE: if (x_req && !xs_b) begin
            if (xs_vd) begin
                if (!x_we && !h_wait) xs_state <= XS_VRD;
            end else begin
                xs_state <= XS_ONE;
                xs_rdata <= 32'h0;
                if (xs_comm) begin
                    if (!x_we) xs_rdata <= comm_ppc[x_addr[0]];
                    else begin
                        // konppc.cpp dsp_comm_sharc_w, CGBOARD_TYPE_HORNET
                        comm_sharc[x_addr[0]] <= x_wdata;
                        if (x_addr[0]) cg_bank <= x_wdata[3];
                    end
                end else if (xs_k33) begin
                    // k033906.cpp: PCI registers or 256 words of RAM
                    if (!k033906_regs) ;        // kram_*, below
                    else if (!x_we) case (x_addr[7:0])
                        8'h00: xs_rdata <= 32'h0001_121A;
                        8'h02: xs_rdata <= 32'h0400_0000;
                        8'h04: xs_rdata <= k033906_membase;
                        8'h0F: xs_rdata <= k033906_intline;
                        8'h14: xs_rdata <= k033906_r14;
                        default: xs_rdata <= 32'h0;
                    endcase else case (x_addr[7:0])
                        8'h04: k033906_membase <= (x_wdata == 32'hFFFF_FFFF) ? 32'hFF00_0000 : {x_wdata[31:24], 24'h0};
                        8'h0F: k033906_intline <= x_wdata;
                        8'h14: k033906_r14 <= x_wdata;
                        default: ;      // 0x10 initEnable: vraster has no init-enable gate (HACKS.md)
                    endcase
                end
            end
        end
        XS_ONE: xs_state <= XS_IDLE;
        XS_VRD: if (h_rvalid) xs_state <= XS_IDLE;
        default: xs_state <= XS_IDLE;
        endcase

        if (ld_we) ld_regs();
    end
end

// ------------------------------------------------------------------------------------------
// Voodoo
// ------------------------------------------------------------------------------------------

vraster #(.RECIP_HEX(RECIP_HEX)) voodoo (
    .clk, .reset,
    .io_h2fLw_address(h_addr), .io_h2fLw_read(h_read), .io_h2fLw_write(h_write),
    .io_h2fLw_byteenable(4'hF), .io_h2fLw_writedata(h_wdata), .io_h2fLw_waitrequest(h_wait),
    .io_h2fLw_readdata(h_rdata), .io_h2fLw_readdatavalid(h_rvalid),
    .io_memFbWrite_read(v_fbw_read), .io_memFbWrite_write(v_fbw_write),
    .io_memFbWrite_waitRequestn(v_fbw_waitn), .io_memFbWrite_address(v_fbw_addr),
    .io_memFbWrite_burstCount(v_fbw_burst), .io_memFbWrite_byteEnable(v_fbw_be),
    .io_memFbWrite_writeData(v_fbw_wdata), .io_memFbWrite_readDataValid(v_fbw_rvalid),
    .io_memFbWrite_writeDataHi(v_fbw_wdata_hi), .io_memFbWrite_byteEnableHi(v_fbw_be_hi),
    .io_memFbColorWrite_writeDataHi(v_fbcw_wdata_hi), .io_memFbColorWrite_byteEnableHi(v_fbcw_be_hi),
    .io_memFbAuxWrite_writeDataHi(v_fbaw_wdata_hi), .io_memFbAuxWrite_byteEnableHi(v_fbaw_be_hi),
    .io_memFbColorRead_readDataHi(v_fbcr_rdata_hi), .io_memFbAuxRead_readDataHi(v_fbar_rdata_hi),
    .io_memFbWrite_readData(v_fbw_rdata),
    .io_memFbColorWrite_read(v_fbcw_read), .io_memFbColorWrite_write(v_fbcw_write),
    .io_memFbColorWrite_waitRequestn(v_fbcw_waitn), .io_memFbColorWrite_address(v_fbcw_addr),
    .io_memFbColorWrite_burstCount(v_fbcw_burst), .io_memFbColorWrite_byteEnable(v_fbcw_be),
    .io_memFbColorWrite_writeData(v_fbcw_wdata), .io_memFbColorWrite_readDataValid(v_fbcw_rvalid),
    .io_memFbColorWrite_readData(v_fbcw_rdata),
    .io_memFbAuxWrite_read(v_fbaw_read), .io_memFbAuxWrite_write(v_fbaw_write),
    .io_memFbAuxWrite_waitRequestn(v_fbaw_waitn), .io_memFbAuxWrite_address(v_fbaw_addr),
    .io_memFbAuxWrite_burstCount(v_fbaw_burst), .io_memFbAuxWrite_byteEnable(v_fbaw_be),
    .io_memFbAuxWrite_writeData(v_fbaw_wdata), .io_memFbAuxWrite_readDataValid(v_fbaw_rvalid),
    .io_memFbAuxWrite_readData(v_fbaw_rdata),
    .io_memFbColorRead_read(v_fbcr_read), .io_memFbColorRead_write(v_fbcr_write),
    .io_memFbColorRead_waitRequestn(v_fbcr_waitn), .io_memFbColorRead_address(v_fbcr_addr),
    .io_memFbColorRead_burstCount(v_fbcr_burst), .io_memFbColorRead_byteEnable(v_fbcr_be),
    .io_memFbColorRead_writeData(v_fbcr_wdata), .io_memFbColorRead_readDataValid(v_fbcr_rvalid),
    .io_memFbColorRead_readData(v_fbcr_rdata),
    .io_memFbAuxRead_read(v_fbar_read), .io_memFbAuxRead_write(v_fbar_write),
    .io_memFbAuxRead_waitRequestn(v_fbar_waitn), .io_memFbAuxRead_address(v_fbar_addr),
    .io_memFbAuxRead_burstCount(v_fbar_burst), .io_memFbAuxRead_byteEnable(v_fbar_be),
    .io_memFbAuxRead_writeData(v_fbar_wdata), .io_memFbAuxRead_readDataValid(v_fbar_rvalid),
    .io_memFbAuxRead_readData(v_fbar_rdata),
    .io_memTex_read(v_tex_read), .io_memTex_write(v_tex_write),
    .io_memTex_waitRequestn(v_tex_waitn), .io_memTex_address(v_tex_addr),
    .io_memTex_burstCount(v_tex_burst), .io_memTex_byteEnable(v_tex_be),
    .io_memTex_writeData(v_tex_wdata), .io_memTex_readDataValid(v_tex_rvalid),
    .io_memTex_readData(v_tex_rdata),
    .io_memFifo_read(v_mf_read), .io_memFifo_write(v_mf_write), .io_memFifo_waitRequestn(v_mf_waitn),
    .io_memFifo_address(v_mf_addr), .io_memFifo_burstCount(v_mf_burst), .io_memFifo_byteEnable(v_mf_be),
    .io_memFifo_writeData(v_mf_wdata), .io_memFifo_writeDataHi(v_mf_wdata_hi), .io_memFifo_byteEnableHi(v_mf_be_hi),
    .io_memFifo_readDataHi(v_mf_rdata_hi), .io_memFifo_readDataValid(v_mf_rvalid), .io_memFifo_readData(v_mf_rdata),
    .io_vRetrace(vblank),
    .io_displayedBuffer(v_displayed), .io_buffer0Base(v_base0), .io_buffer1Base(v_base1),
    .io_pixelStride(v_stride), .io_dbg(v_dbg), .io_ring_off(v_ring_off), .io_ring_bad(v_ring_bad)
);

hornet_video video (
    .clk, .reset,
    .run, .lclk, .vpos, .vtotal(vtotal),
    .k_scroll(k037122_reg[8]), .k_incy(k037122_reg[9]), .k_incx(k037122_reg[10]),
    .k_ctl(k037122_reg[12]), .k_ctl2(k037122_reg[13]),
    .k_raddr(kv_addr), .k_rdata(kv_q),
    .c_req, .c_addr, .c_ack, .c_rdata,
    .s_read, .s_addr, .s_burst, .s_waitn, .s_rvalid, .s_rdata, .s_rdata_hi,
    .v_base(v_base0), .v_stride, .v_xoffs, .v_yoffs,
    .clut_we, .clut_idx, .clut_data,
    .vid_ce, .vid_de, .vid_x, .vid_y, .vid_r, .vid_g, .vid_b, .vid_hb, .vid_vb, .vid_hs, .vid_vs,
    .overrun(vid_overrun)
);

// ------------------------------------------------------------------------------------------
// Video timing, from the Voodoo's timing registers
// ------------------------------------------------------------------------------------------

logic [11:0] vsync_on, vsync_off;      // vSync (0x224): on in bits 11:0, off in bits 27:16
logic [15:0] lclk;
logic        vb_restart;
// until the Voodoo's vSync is written, MAME's screen keeps hornet.cpp's 428 lines and the
// Voodoo's vblank starts and stops at line 0 (m_vsyncstart 0, voodoo.cpp:2527-2603)
wire  [11:0] vtotal = (vsync_on + vsync_off == 12'd0) ? 12'd428 : vsync_on + vsync_off;
logic [9:0]  v_xoffs, v_yoffs;         // backPorch (0x208): horizontal + 2, vertical
logic        clut_we;
logic [5:0]  clut_idx;
logic [23:0] clut_data;
logic [15:0] v_stride;

// the SHARC's (or loader's) writes to vSync, backPorch and clutData (voodoo.cpp:2403-2445);
// hSync and videoDimensions only set MAME's screen, which this board fixes at hornet.cpp's
wire v_fbi_wr = h_write && !h_wait && h_addr < 22'h10_0000 && (h_addr[11:8] == 4'd0 || h_addr[8]);
assign ev_swapcmd = v_fbi_wr && h_addr[7:0] == 8'h4A;

always_ff @(posedge clk) begin
    clut_we <= 1'b0;
    if (reset) begin
        // hornet.cpp's screen until the Voodoo's timing is written: visible from (41, 27)
        vsync_on <= 12'd0; vsync_off <= 12'd0; v_xoffs <= 10'd41; v_yoffs <= 10'd27;
    end else if (v_fbi_wr && h_addr[7:0] == 8'h89) begin
        vsync_on  <= h_wdata[11:0];
        vsync_off <= h_wdata[27:16];
    end
    if (v_fbi_wr && h_addr[7:0] == 8'h82) begin
        v_xoffs <= {2'b0, h_wdata[7:0]} + 10'd2;
        v_yoffs <= {2'b0, h_wdata[23:16]};
    end
    // clutData: index in bits 31:24; MAME ignores it while fbiInit1 holds video timing reset
    if (v_fbi_wr && h_addr[7:0] == 8'h8A) begin
        clut_we <= 1'b1; clut_idx <= h_wdata[29:24]; clut_data <= h_wdata[23:0];
    end
    if (ld_we && ld_sel == 4'd9) begin
        clut_we <= 1'b1; clut_idx <= ld_addr[5:0]; clut_data <= ld_data[23:0];
    end
end

always_ff @(posedge clk) begin
    vb_start <= 1'b0;
    vb_stop  <= 1'b0;
    if (reset) begin
        vpos <= 10'd0; vblank <= 1'b0; lclk <= 16'd0; vb_restart <= 1'b0;
    end else if (ld_we && ld_sel == 4'd8) begin
        vpos <= ld_data[9:0];
        vblank <= ld_data[16];
        lclk <= 16'd0;
    end else if (run) begin
        if (vb_restart) begin
            // vblank_stop then vblank_start at line 0 (vSync.off 0): the line falls and rises
            vblank <= 1'b1; vb_start <= 1'b1; vb_restart <= 1'b0;
        end
        if (lclk + 16'd1 >= line_clocks) begin
            lclk <= 16'd0;
            if ({2'b0, vpos} + 12'd1 >= vtotal) vpos <= 10'd0;
            else vpos <= vpos + 10'd1;
            // vblank_start at line vSync.off, vblank_stop at line 0
            if ({2'b0, vpos} + 12'd1 == vsync_off) begin vblank <= 1'b1; vb_start <= 1'b1; end
            if ({2'b0, vpos} + 12'd1 >= vtotal) begin
                vblank <= 1'b0; vb_stop <= 1'b1;
                if (vsync_off == 12'd0) vb_restart <= 1'b1;
            end
        end else
            lclk <= lclk + 16'd1;
    end
end

endmodule
