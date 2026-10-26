// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hornet rasteriser: the Voodoo 1 subset Gradius IV uses (docs/RASTER.md), written from MAME's
// model (src/devices/video/voodoo.cpp, voodoo_render.cpp, voodoo_regs.h). Ports as SpinalVoodoo's
// CoreHornet, so that hornet_board does not change; the frame buffer and texture memory are laid
// out as MAME's (2 MB frame buffer at FB_BASE, TMU memory at TEX_BASE).
//
//   register port -> FIFO -> command processor: register writes (MAME's alias map, the float
//   registers converted to fixed point), and the commands in order: fast fill, swap buffer,
//   triangle; status and register reads answered at once. The FIFO is a staging FIFO, a ring of
//   MRING entries in DDR3 (the Voodoo's memory FIFO; io_memFifo) and the on-chip FIFO: while the
//   ring is empty, entries go from staging to the on-chip FIFO directly.

module vraster #(
    parameter logic [31:0] FB_BASE  = 32'h3F40_0000,    // De10AddressMap: 12 MB below 1 GB
    parameter logic [31:0] TEX_BASE = 32'h3F80_0000,    // FB_BASE + 4 MB
    parameter int          FIFO_AW  = 9,
    parameter logic [31:0] RING_BASE = 32'h3F70_0000,  // FB_BASE + 3 MB: above MAME's 2 MB frame buffer
    parameter int          MRING_AW = 16,              // 64K entries, 8 bytes each
    parameter              RECIP_HEX = "rtl/raster/vraster_recip.hex"   // reciprocal seed ROM
) (
    input  logic        clk,
    input  logic        reset,

    input  logic [21:0] io_h2fLw_address,               // 32-bit word offset into the 16 MB space
    input  logic        io_h2fLw_read,
    input  logic        io_h2fLw_write,
    input  logic [3:0]  io_h2fLw_byteenable,
    input  logic [31:0] io_h2fLw_writedata,
    output logic        io_h2fLw_waitrequest,
    output logic [31:0] io_h2fLw_readdata,
    output logic        io_h2fLw_readdatavalid,

    output logic        io_memFbWrite_read, io_memFbWrite_write,
    input  logic        io_memFbWrite_waitRequestn,
    output logic [31:0] io_memFbWrite_address,
    output logic [10:0] io_memFbWrite_burstCount,
    output logic [3:0]  io_memFbWrite_byteEnable,
    output logic [31:0] io_memFbWrite_writeData,
    output logic [31:0] io_memFbWrite_writeDataHi,  // wide: the burst's odd words, beside the even
    output logic [3:0]  io_memFbWrite_byteEnableHi,
    input  logic        io_memFbWrite_readDataValid,
    input  logic [31:0] io_memFbWrite_readData,

    output logic        io_memFbColorWrite_read, io_memFbColorWrite_write,
    input  logic        io_memFbColorWrite_waitRequestn,
    output logic [31:0] io_memFbColorWrite_address,
    output logic [10:0] io_memFbColorWrite_burstCount,
    output logic [3:0]  io_memFbColorWrite_byteEnable,
    output logic [31:0] io_memFbColorWrite_writeData,
    output logic [31:0] io_memFbColorWrite_writeDataHi,      // wide (hornet_ddr3 WIDE)
    output logic [3:0]  io_memFbColorWrite_byteEnableHi,
    input  logic        io_memFbColorWrite_readDataValid,
    input  logic [31:0] io_memFbColorWrite_readData,

    output logic        io_memFbAuxWrite_read, io_memFbAuxWrite_write,
    input  logic        io_memFbAuxWrite_waitRequestn,
    output logic [31:0] io_memFbAuxWrite_address,
    output logic [10:0] io_memFbAuxWrite_burstCount,
    output logic [3:0]  io_memFbAuxWrite_byteEnable,
    output logic [31:0] io_memFbAuxWrite_writeData,
    output logic [31:0] io_memFbAuxWrite_writeDataHi,      // wide (hornet_ddr3 WIDE)
    output logic [3:0]  io_memFbAuxWrite_byteEnableHi,
    input  logic        io_memFbAuxWrite_readDataValid,
    input  logic [31:0] io_memFbAuxWrite_readData,

    output logic        io_memFbColorRead_read, io_memFbColorRead_write,
    input  logic        io_memFbColorRead_waitRequestn,
    output logic [31:0] io_memFbColorRead_address,
    output logic [10:0] io_memFbColorRead_burstCount,
    output logic [3:0]  io_memFbColorRead_byteEnable,
    output logic [31:0] io_memFbColorRead_writeData,
    input  logic        io_memFbColorRead_readDataValid,
    input  logic [31:0] io_memFbColorRead_readData,
    input  logic [31:0] io_memFbColorRead_readDataHi,
    output logic        io_memFbColorRead_readReady,    // read data may come the next clock

    output logic        io_memFbAuxRead_read, io_memFbAuxRead_write,
    input  logic        io_memFbAuxRead_waitRequestn,
    output logic [31:0] io_memFbAuxRead_address,
    output logic [10:0] io_memFbAuxRead_burstCount,
    output logic [3:0]  io_memFbAuxRead_byteEnable,
    output logic [31:0] io_memFbAuxRead_writeData,
    input  logic        io_memFbAuxRead_readDataValid,
    input  logic [31:0] io_memFbAuxRead_readData,
    output logic        io_memFbAuxRead_readReady,
    input  logic [31:0] io_memFbAuxRead_readDataHi,

    output logic        io_memTex_read, io_memTex_write,
    input  logic        io_memTex_waitRequestn,
    output logic [31:0] io_memTex_address,
    output logic [10:0] io_memTex_burstCount,
    output logic [3:0]  io_memTex_byteEnable,
    output logic [31:0] io_memTex_writeData,
    input  logic        io_memTex_readDataValid,
    input  logic [31:0] io_memTex_readData,
    // wide (hornet_ddr3 WIDE): a beat a handshake; readReady as the frame-buffer reads'
    input  logic [31:0] io_memTex_readDataHi,
    output logic [31:0] io_memTex_writeDataHi,
    output logic [3:0]  io_memTex_byteEnableHi,
    output logic        io_memTex_readReady,
    output logic        io_memFifo_read, io_memFifo_write,
    input  logic        io_memFifo_waitRequestn,
    output logic [31:0] io_memFifo_address,
    output logic [10:0] io_memFifo_burstCount,
    output logic [3:0]  io_memFifo_byteEnable,
    output logic [31:0] io_memFifo_writeData,
    output logic [31:0] io_memFifo_writeDataHi,     // wide (hornet_ddr3 WIDE)
    output logic [3:0]  io_memFifo_byteEnableHi,
    input  logic        io_memFifo_readDataValid,
    input  logic [31:0] io_memFifo_readData,
    input  logic [31:0] io_memFifo_readDataHi,

    input  logic        io_vRetrace,
    output logic [1:0]  io_displayedBuffer,
    output logic [25:0] io_buffer0Base,                 // displayed buffer, bytes into the frame buffer
    output logic [25:0] io_buffer1Base,                 // draw (back) buffer
    output logic [15:0] io_pixelStride,
    // status for the debug probes: {triangle started, fill started, command state, FIFO empty,
    // FIFO full, ring in use, staging empty, swaps pending, front buffer}
    output logic [15:0] io_dbg,
    output logic [31:0] io_status,      // the status register's value now (hornet_board answers the SHARC's reads of it)
    input  logic        io_ring_off,    // debug: never use the memory FIFO's ring
    output logic        io_ring_bad     // debug: a ring entry read back was not the one written
);

`include "vraster_regs.svh"
`include "vraster_tex.svh"

// ------------------------------------------------------------------------------------------
// Register port and FIFO
// ------------------------------------------------------------------------------------------

logic [53:0] fifo [1 << FIFO_AW];
logic [FIFO_AW:0] f_wp, f_rp;
logic [53:0] f_q;
logic        f_full, f_empty, f_pop, f_qv;
logic        f_room;                    // 16 free: a ring read burst fits
logic        o_push;
logic [53:0] o_data;
assign f_empty = f_wp == f_rp;

// reads answered the clock after; status needs no FIFO
logic        rd_pend;
logic [31:0] rd_data;

// staging: the register port's writes, 16 entries (an MLAB)
logic [4:0]  s_wp, s_rp;
logic [53:0] s_q;
wire         s_full = (s_wp - s_rp) == 5'd16;
wire         s_empty = s_wp == s_rp;
wire  [4:0]  s_n = s_wp - s_rp;
wire         s_push = io_h2fLw_write && !s_full;
logic        s_pop;
assign io_h2fLw_waitrequest = io_h2fLw_write && s_full;
sharc2_lutram #(.AW(4), .DW(54)) u_stage (.clk, .we(s_push), .wa(s_wp[3:0]),
    .wd({io_h2fLw_address, io_h2fLw_writedata}), .ra(s_rp[3:0]), .rd(s_q));

// the ring: an entry a 64-bit beat (data in the low word, the address in the high; a wide master),
// written and read in bursts of 8 entries
typedef enum logic [1:0] { M_IDLE, M_WR, M_RD } m_t;
m_t          ms;
logic [MRING_AW:0] r_wp, r_rp;
logic [3:0]  m_k;                       // entries of the burst: done (write), left (read)
wire         r_empty = r_wp == r_rp;
wire         r_full = (r_wp - r_rp) > (MRING_AW + 1)'((1 << MRING_AW) - 8);
wire         ring_used = !r_empty || ms != M_IDLE;
// staging goes on chip while the ring is idle and empty, else to the ring 8 at a time
wire         direct = !ring_used && !s_empty && !f_full;
assign io_memFifo_write   = ms == M_WR;
assign io_memFifo_read    = ms == M_RD && m_k == 4'd0;
assign io_memFifo_address = RING_BASE + {(32 - MRING_AW - 3)'(0), (ms == M_WR ? r_wp[MRING_AW-1:0] : r_rp[MRING_AW-1:0]), 3'b000};
assign io_memFifo_burstCount = 11'd16;
assign io_memFifo_byteEnable = 4'hF;
assign io_memFifo_byteEnableHi = 4'hF;
// an entry's address word carries its ring index's low 10 bits above the address, checked when it
// is read back (io_ring_bad: an entry came back that is not the one written there last)
wire  [9:0]  w_tag = 10'(r_wp + (MRING_AW + 1)'(m_k));
wire  [9:0]  r_tag = 10'(r_rp + (MRING_AW + 1)'(4'd8 - m_k));
assign io_memFifo_writeData   = s_q[31:0];
assign io_memFifo_writeDataHi = {w_tag, s_q[53:32]};
wire   m_rv = ms == M_RD && m_k != 4'd0 && io_memFifo_readDataValid;
always_comb begin
    s_pop = direct || (ms == M_WR && io_memFifo_waitRequestn);
    o_push = direct || m_rv;
    o_data = direct ? s_q : {io_memFifo_readDataHi[21:0], io_memFifo_readData};
end
always_ff @(posedge clk)
    io_ring_bad <= m_rv && io_memFifo_readDataHi[31:22] != r_tag;
always_ff @(posedge clk) begin
    if (s_push) s_wp <= s_wp + 5'd1;
    if (s_pop) s_rp <= s_rp + 5'd1;
    case (ms)
    M_IDLE:
        if (s_n >= 5'd8 && (ring_used || f_full) && !r_full && !io_ring_off) begin ms <= M_WR; m_k <= 4'd0; end
        else if (!r_empty && f_room) begin ms <= M_RD; m_k <= 4'd0; end
    M_WR: if (io_memFifo_waitRequestn) begin
        m_k <= m_k + 4'd1;
        if (m_k == 4'd7) begin r_wp <= r_wp + (MRING_AW + 1)'(8); ms <= M_IDLE; end
    end
    M_RD:
        if (m_k == 4'd0 && io_memFifo_waitRequestn) m_k <= 4'd8;       // the command taken
        else if (m_rv) begin
            m_k <= m_k - 4'd1;
            if (m_k == 4'd1) begin r_rp <= r_rp + (MRING_AW + 1)'(8); ms <= M_IDLE; end
        end
    default: ms <= M_IDLE;
    endcase
    if (reset) begin s_wp <= '0; s_rp <= '0; r_wp <= '0; r_rp <= '0; ms <= M_IDLE; m_k <= '0; end
end

// the on-chip FIFO; full and room registered from the pointers' next values
always_ff @(posedge clk) begin
    logic [FIFO_AW:0] wp, rp;
    wp = f_wp; rp = f_rp;
    if (o_push) begin
        fifo[f_wp[FIFO_AW-1:0]] <= o_data;
        wp = f_wp + 1'd1;
    end
    f_q <= fifo[f_rp[FIFO_AW-1:0]];
    if (f_pop) rp = f_rp + 1'd1;
    if (reset) begin wp = '0; rp = '0; end
    f_wp <= wp; f_rp <= rp;
    f_full <= (wp - rp) == (FIFO_AW + 1)'(1 << FIFO_AW);
    f_room <= (wp - rp) <= (FIFO_AW + 1)'((1 << FIFO_AW) - 16);
    io_h2fLw_readdatavalid <= io_h2fLw_read;
    io_h2fLw_readdata <= rd_data;
end

// ------------------------------------------------------------------------------------------
// Buffers and swap
// ------------------------------------------------------------------------------------------

logic [1:0]  frontbuf, backbuf;
logic [7:0]  vbl_count;                // MAME m_vblank_count, saturating at 250
logic        swap_wait;                // a vsync swap is waiting for its vblank
logic [7:0]  swap_interval;
logic [2:0]  swaps_pending;
logic        vbl_q;

logic [20:0] rgboffs [3];
logic [20:0] auxoffs;
logic        aux_ok, rgb2_ok;
logic [9:0]  rowpix;
always_comb begin
    logic [20:0] pages;
    pages = {fbiInit2[19:11], 12'h0};
    rowpix = {fbiInit1[7:4], 6'h0};
    rgboffs[0] = 21'h0;
    rgboffs[1] = pages;
    rgb2_ok = fbiInit2[4];                         // triple buffering: no aux buffer
    rgboffs[2] = {pages[19:0], 1'b0};
    aux_ok = !fbiInit2[4];
    auxoffs = {pages[19:0], 1'b0};
end

assign io_displayedBuffer = frontbuf;
assign io_buffer0Base = {5'h0, rgboffs[frontbuf]};
assign io_buffer1Base = {5'h0, rgboffs[backbuf]};
assign io_pixelStride = {6'h0, rowpix};

// ------------------------------------------------------------------------------------------
// Command processor
// ------------------------------------------------------------------------------------------

typedef enum logic [3:0] { C_IDLE, C_LOAD, C_CONV, C_EXEC, C_ADJ, C_ADJ2, C_FILL, C_SWAP, C_TRI, C_TEXW } cstate_t;
cstate_t cs;

logic [21:0] c_addr;
logic [31:0] c_data;
logic        fill_done, tri_done;
logic        drain_pend;              // the last triangle's spans are still in the pipeline (vraster_tri)
logic        fill_go, tri_go;
logic [21:0] texw_a;                    // a texture write's byte address
logic [31:0] c_m4, c_m12;               // c_data's float magnitude as x.4, x.12, 32.32
logic [63:0] c_m32;
logic signed [4:0] sub_dx, sub_dy;      // the sub-pixel adjustment: 8 - vertex A's fraction
logic signed [31:0] adj_ay, adj_ax, adj_a;   // its products (y, x) and their sums
logic signed [63:0] adj_wy, adj_wx, adj_sy, adj_sx, adj_ty, adj_tx, adj_w, adj_s, adj_t;

// the registers the next triangle may write while the last one's spans drain: vertices, starts,
// gradients and triangleCMD (integer and float forms); the pipeline keeps its own x-gradients
function automatic logic tri_reg(input logic [7:0] r);
    return (r >= 8'h02 && r <= 8'h20) || (r >= 8'h22 && r <= 8'h40);
endfunction

// the register a FIFO entry names, after MAME's alias map (voodoo.cpp:229) when remapped
function automatic logic [7:0] reg_of(input logic [21:0] a);
    logic [7:0] r;
    r = a[7:0];
    if (a[19] && fbiInit3[0] && r < 8'h40) r = alias_reg(r);
    return r;
endfunction

always_ff @(posedge clk) begin
    logic swap_now, swap_in;
    swap_now = 1'b0;
    fill_go <= 1'b0;
    tri_go <= 1'b0;
    if (reset) begin
        cs <= C_IDLE;
        frontbuf <= 2'd0; backbuf <= 2'd1;
        vbl_count <= 8'd0; swap_wait <= 1'b0; swaps_pending <= 3'd0;
    end else begin
        case (cs)
        C_IDLE: if (!f_empty && !lod_busy) cs <= C_LOAD;    // f_q is valid the clock after
        C_LOAD: begin
            c_addr <= f_q[53:32]; c_data <= f_q[31:0];
            cs <= C_CONV;
        end
        C_CONV: begin
            c_m4 <= fmag32(c_data, 4); c_m12 <= fmag32(c_data, 12); c_m32 <= fmag64(c_data, 32);
            cs <= C_EXEC;
        end
        C_EXEC: if (!drain_pend || (c_addr < 22'h100000 && tri_reg(reg_of(c_addr)))) begin
            logic [7:0] r;
            r = reg_of(c_addr);
            cs <= C_IDLE;
            if (c_addr >= 22'h200000) begin
                // texture memory (internal_texture_w): TMU 0 only
                if ((c_addr - 22'h200000) < 22'h80000) cs <= C_TEXW;
                texw_a <= texwr_addr(c_addr - 22'h200000);
            end else if (c_addr >= 22'h100000) ;             // LFB writes: unused
            else begin
                reg_write(r, c_addr[11:8], c_data, c_m4, c_m12, c_m32);
                case (r)
                8'h49: if (fbzMode[9] || (fbzMode[10] && aux_ok)) begin fill_go <= 1'b1; cs <= C_FILL; end
                8'h4a: begin
                    swap_interval <= c_data[8:1];
                    if (!c_data[0]) begin
                        frontbuf <= next_buf(frontbuf);
                        backbuf <= next_buf(next_buf(frontbuf));
                        vbl_count <= 8'd0;
                        swap_now = 1'b1;
                    end else begin
                        swap_wait <= 1'b1;
                        cs <= C_SWAP;
                    end
                end
                8'h20, 8'h40: begin
                    // MAME triangle(): the sub-pixel adjustment, written back to the registers
                    // (products here, sums in C_ADJ, added in C_ADJ2)
                    adj_ay <= sub_dy * dAdY;          adj_ax <= sub_dx * dAdX;
                    adj_wy <= 64'(sub_dy) * dWdY;     adj_wx <= 64'(sub_dx) * dWdX;
                    adj_sy <= 64'(sub_dy) * dSdY;     adj_sx <= 64'(sub_dx) * dSdX;
                    adj_ty <= 64'(sub_dy) * dTdY;     adj_tx <= 64'(sub_dx) * dTdX;
                    cs <= C_ADJ;
                end
                default: ;
                endcase
            end
        end
        C_ADJ: begin
            adj_a <= (adj_ay + adj_ax) >>> 4; adj_w <= (adj_wy + adj_wx) >>> 4;
            adj_s <= (adj_sy + adj_sx) >>> 4; adj_t <= (adj_ty + adj_tx) >>> 4;
            if (!tag_clr) cs <= C_ADJ2;                 // the texture cache's tags are clear
        end
        C_ADJ2: begin
            if (fbzColorPath[26]) begin
                startA <= startA + adj_a; startW <= startW + adj_w;
                startS <= startS + adj_s; startT <= startT + adj_t;
            end
            tri_go <= 1'b1; cs <= C_TRI;
        end
        C_FILL: if (fill_done) cs <= C_IDLE;
        C_TRI:  if (tri_done) cs <= C_IDLE;
        C_SWAP: if (!swap_wait) cs <= C_IDLE;
        C_TEXW: if (io_memTex_waitRequestn) cs <= C_IDLE;
        default: cs <= C_IDLE;
        endcase

        sub_dx <= 5'sd8 - $signed({1'b0, vAx[3:0]});
        sub_dy <= 5'sd8 - $signed({1'b0, vAy[3:0]});

        // vblank start (MAME vblank_start): count, then swap if one is due
        vbl_q <= io_vRetrace;
        if (io_vRetrace && !vbl_q) begin
            vbl_count <= (vbl_count == 8'd250) ? 8'd250 : vbl_count + 8'd1;
            if (swap_wait && vbl_count + 8'd1 >= swap_interval) begin
                frontbuf <= next_buf(frontbuf);
                backbuf <= next_buf(next_buf(frontbuf));
                vbl_count <= 8'd0;
                swap_wait <= 1'b0;
                swap_now = 1'b1;
            end
        end
        // MAME counts swap commands as they enter the FIFO (map_register_w) and as they are done
        swap_in = s_push && io_h2fLw_address < 22'h100000 && io_h2fLw_address[7:0] == 8'h4a;
        if (swap_in && !(swap_now && swaps_pending != 0)) swaps_pending <= swaps_pending + 3'd1;
        else if (!swap_in && swap_now && swaps_pending != 0) swaps_pending <= swaps_pending - 3'd1;
    end
end
assign f_pop = cs == C_LOAD;

function automatic logic [1:0] next_buf(input logic [1:0] b);
    next_buf = (b == (rgb2_ok ? 2'd2 : 2'd1)) ? 2'd0 : b + 2'd1;
endfunction

// status (MAME reg_status_r) and the readable registers
always_comb begin
    logic busy;
    busy = !f_empty || cs != C_IDLE || !s_empty || ring_used || drain_pend;
    io_status = {1'b0, swaps_pending, 16'hFFFF, frontbuf, {3{busy}}, io_vRetrace, s_full ? 6'h00 : 6'h3F};
    rd_data = 32'h0;
    case (io_h2fLw_address[7:0])
    8'h00: rd_data = io_status;
    8'h84: rd_data = fbiInit0;
    8'h85: rd_data = fbiInit1;
    8'h86: rd_data = fbiInit2;
    8'h87: rd_data = fbiInit3;
    default: rd_data = 32'h0;
    endcase
end

// ------------------------------------------------------------------------------------------
// Fast fill (MAME rasterizer_fastfill): the clip rectangle, colour from color1 dithered, depth
// from zaColor, a burst a row
// ------------------------------------------------------------------------------------------

`include "vraster_fill.svh"

// ------------------------------------------------------------------------------------------
// Triangles (docs/RASTER.md)
// ------------------------------------------------------------------------------------------

`include "vraster_tri.svh"

// memTex: the texture cache's fills, or the command processor's texture writes (a beat, the word's
// half enabled). A fill's row is whole beats: an 8-bit row at an odd word starts a word early
wire [21:0] tf_a = texel_addr(rq_s, rq_t + {6'h0, rq_r});
assign tex_clear = cs == C_TEXW && io_memTex_waitRequestn;
assign io_memTex_read = fls == F2_REQ || rq_n;
assign io_memTex_write = cs == C_TEXW;
assign io_memTex_address = TEX_BASE + {10'h0, (cs == C_TEXW) ? texw_a[21:3] : tf_a[21:3], 3'b000};
assign io_memTex_burstCount = (cs == C_TEXW) ? 11'd2 : t16 ? {6'h0, rq_kn, 1'b0}
                                                         : {6'h0, (5'(tf_a[2]) + 5'(rq_kn) + 5'd1) & 5'h1E};
assign io_memTex_byteEnable = (cs == C_TEXW && texw_a[2]) ? 4'h0 : 4'hF;
assign io_memTex_byteEnableHi = (cs == C_TEXW && !texw_a[2]) ? 4'h0 : 4'hF;
assign io_memTex_writeData = c_data;
assign io_memTex_writeDataHi = c_data;


// status for the debug probes (bit 5: a texture-cache fill holds the pixel pipeline)
assign io_dbg = {tri_go, fill_go, cs, f_empty, f_full, ring_used, s_empty, fls != F2_IDLE, swaps_pending, frontbuf};

endmodule
