// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hornet's picture: the Voodoo's displayed buffer through its CLUT, with the K037122's
// rotate/zoom tilemap over it (hornet.cpp screen_update: voodoo update, then k037122 tile_draw).
//
// Screen: 644 pixels a line at clk/4; 512 x 384 visible from the Voodoo's back porch (xoffs,
// yoffs), as MAME's recompute_video_timing sets its screen (voodoo.cpp:2749-2750).
// Each visible line is built while the line before it is shown, into one of two line buffers:
//   Voodoo   the displayed buffer's row (line - yoffs). Read on port S, a word per two pixels.
//   K037122  per pixel, the tilemap position (cx, cy) = start + x * incx + y * incy in 16.16,
//            x and y the raster position (x from xoffs)
//            (k037122.cpp tile_draw, tilemap.cpp draw_roz_core without wraparound): outside the
//            map, or pen 0, is transparent. Tile words and the palette from the K037122 SRAM
//            (k_raddr/k_rdata, one clock), the character RAM on port C. The start of each line
//            and each pixel's position come from adders, not multiplies.
// The K037122 draws from the registers as they are when a line is built; MAME draws the whole
// frame with the registers at the end of it.
//
// Voodoo colours go through the CLUT as MAME's voodoo update builds its pens: per channel, the
// 33 CLUT entries interpolated at 1/8 steps (voodoo.cpp:858-889), rebuilt after a CLUT write.

module hornet_video (
    input  logic        clk,
    input  logic        reset,

    input  logic        run,            // the raster is running (lclk counts)
    input  logic [15:0] lclk,           // clock within the line (the board's line counter)
    input  logic [9:0]  vpos,
    input  logic [11:0] vtotal,

    // K037122 registers (k037122.cpp: 0x20 scroll, 0x24 incyx/incyy, 0x28 incxx/incxy,
    // 0x30 control, 0x34 origin and CLUT position)
    input  logic [31:0] k_scroll, k_incy, k_incx, k_ctl, k_ctl2,
    output logic [14:0] k_raddr,
    input  logic [31:0] k_rdata,

    // port C: K037122 character RAM, word address (512K words)
    output logic        c_req,
    output logic [18:0] c_addr,
    input  logic        c_ack,
    input  logic [31:0] c_rdata,

    // port S: the Voodoo's frame buffer, byte address of a 32-bit word
    output logic        s_req,
    output logic [25:0] s_addr,
    input  logic        s_ack,
    input  logic [31:0] s_rdata,

    input  logic [25:0] v_base,         // displayed buffer (CoreHornet buffer0Base)
    input  logic [15:0] v_stride,       // pixels per row
    input  logic [9:0]  v_xoffs,        // backPorch.horizontal + 2 (voodoo.cpp:2418)
    input  logic [9:0]  v_yoffs,        // backPorch.vertical

    // CLUT entry writes (clutData, or a state load): index 0-32, 0x00RRGGBB
    input  logic        clut_we,
    input  logic [5:0]  clut_idx,
    input  logic [23:0] clut_data,

    output logic        vid_ce,         // pixel clock enable (clk/4)
    output logic        vid_de,
    output logic [9:0]  vid_x,
    output logic [9:0]  vid_y,
    output logic [7:0]  vid_r, vid_g, vid_b,
    output logic        overrun         // pulse: the line being built was not finished in time
);

localparam int VIS_W = 512, VIS_H = 384;

// ------------------------------------------------------------------------------------------
// CLUT and its per-channel tables
// ------------------------------------------------------------------------------------------

logic [23:0] clut [33];
logic [7:0]  rtab [32], gtab [64], btab [32];
logic        tab_busy;
logic [6:0]  tab_i;                     // 0-31 red/blue, 32-95 green

// a * (8 - f) + b * f, >> 3, with a 3-bit f: 8a + (b - a) f from shifts
function automatic logic [7:0] lerp8(input logic [7:0] a, input logic [7:0] b, input logic [2:0] f);
    logic signed [12:0] d, s;
    d = $signed({5'b0, b}) - $signed({5'b0, a});
    s = $signed({2'b0, a, 3'b0});
    if (f[0]) s = s + d;
    if (f[1]) s = s + (d <<< 1);
    if (f[2]) s = s + (d <<< 2);
    lerp8 = s[10:3];
endfunction

// MAME's clut[32] kludge: 0 with clut[31] non-zero reads as white (voodoo.cpp:862-863)
function automatic logic [23:0] clut_at(input logic [5:0] i);
    if (i == 6'd32 && clut[32] == 24'h0 && clut[31] != 24'h0) clut_at = 24'hFFFFFF;
    else clut_at = clut[i];
endfunction

always_ff @(posedge clk) begin
    if (reset) begin
        tab_busy <= 1'b1; tab_i <= 7'd0;
    end else begin
        if (clut_we && clut_idx <= 6'd32) begin
            clut[clut_idx] <= clut_data;
            tab_busy <= 1'b1; tab_i <= 7'd0;
        end else if (tab_busy) begin
            if (tab_i < 7'd32) begin
                logic [7:0] c;
                c = {tab_i[4:0], tab_i[4:2]};                   // pal5bit
                rtab[tab_i[4:0]] <= lerp8(clut_at({1'b0, c[7:3]})[23:16], clut_at({1'b0, c[7:3]} + 6'd1)[23:16], c[2:0]);
                btab[tab_i[4:0]] <= lerp8(clut_at({1'b0, c[7:3]})[7:0],   clut_at({1'b0, c[7:3]} + 6'd1)[7:0],   c[2:0]);
            end else begin
                logic [5:0] g;
                logic [7:0] c;
                g = 6'(tab_i - 7'd32);
                c = {g, g[5:4]};                                 // pal6bit
                gtab[g] <= lerp8(clut_at({1'b0, c[7:3]})[15:8], clut_at({1'b0, c[7:3]} + 6'd1)[15:8], c[2:0]);
            end
            if (tab_i == 7'd95) tab_busy <= 1'b0;
            tab_i <= tab_i + 7'd1;
        end
    end
end

// ------------------------------------------------------------------------------------------
// Line buffers: [bank][x]
// ------------------------------------------------------------------------------------------

logic [15:0] vbuf [2][VIS_W];           // Voodoo pixel
logic [16:0] kbuf [2][VIS_W];           // {opaque, K037122 palette word low 16 bits}

// ------------------------------------------------------------------------------------------
// Line build, started at each line for the next one
// ------------------------------------------------------------------------------------------

wire        line_start = run && lclk == 16'd0;
wire [9:0]  next_line = ({2'b0, vpos} + 12'd1 >= vtotal) ? 10'd0 : vpos + 10'd1;
wire        next_vis = next_line >= v_yoffs && next_line < v_yoffs + 10'(VIS_H);
logic [9:0] b_line;                     // the line being built
logic       b_bank;

// K037122 frame parameters (k037122.cpp tile_draw)
wire        map128 = k_ctl[16];
wire signed [15:0] scrollx = k_scroll[31:16];
wire signed [15:0] scrolly_raw = k_scroll[15:0];
wire signed [15:0] scrolly = k_ctl2[16] ? scrolly_raw : scrolly_raw - (map128 ? 16'sh2000 : 16'sh1000);
wire [31:0] startx = {{4{scrollx[15]}}, scrollx, 12'h0};
wire [31:0] starty = {{4{scrolly[15]}}, scrolly, 12'h0};
wire [31:0] incxx = {{12{k_incx[31]}}, k_incx[31:16], 4'h0};
wire [31:0] incxy = {{12{k_incx[15]}}, k_incx[15:0], 4'h0};
// the 128x128 map takes incyx unshifted (k037122.cpp:170), MAME_KLUDGES.md
wire [31:0] incyx = map128 ? {{16{k_incy[31]}}, k_incy[31:16]} : {{12{k_incy[31]}}, k_incy[31:16], 4'h0};
wire [31:0] incyy = {{12{k_incy[15]}}, k_incy[15:0], 4'h0};
wire [14:0] tile_base = k_ctl2[2] ? 15'h0000 : 15'h2000;   // words
wire [14:0] pal_base  = k_ctl2[2] ? 15'h6000 : 15'h0000;

// position of raster pixel (xoffs, line): start + xoffs * inc(x) + line * inc(y). The x term
// is added xoffs times at line 0 (xi_n), the line term once a line.
logic [31:0] row_cx, row_cy;            // for b_line
logic [9:0]  xi_n;

// ---------------------------------------------------------------- Voodoo row
typedef enum logic [1:0] { VF_IDLE, VF_ADDR, VF_RUN, VF_WAIT } vf_t;
vf_t         vf;
logic [9:0]  vf_x;                      // next pixel of the line
logic [25:0] vf_a;                      // its byte address
logic [23:0] vf_wa;                     // word held in vf_w (address / 4)
logic [31:0] vf_w;
logic        vf_have, vf_row_ok;
logic [25:0] v_rowbase;                 // the displayed buffer's row for b_line

assign s_req  = vf == VF_WAIT;
assign s_addr = {vf_a[25:2], 2'b00};

// ---------------------------------------------------------------- K037122 row
typedef enum logic [2:0] { KF_IDLE, KF_START, KF_POS, KF_TILE, KF_CHAR, KF_PEN, KF_PAL } kf_t;
kf_t         kf;
logic [9:0]  kf_x;
logic [31:0] cx, cy;
logic [13:0] kf_tidx;                   // tile of kf_tile
logic        kf_thave;
logic [31:0] kf_tile;
logic [18:0] kf_cwa;                    // word held in kf_cw
logic        kf_chave;
logic [31:0] kf_cw;
logic [7:0]  kf_pen;

wire [10:0] px = cx[26:16];
wire [10:0] py = cy[26:16];
wire [13:0] ti = map128 ? {py[9:3], px[9:3]} : {py[8:3], px[10:3]};
wire        inmap = map128 ? (cx[31:26] == 6'd0 && cy[31:26] == 6'd0)       // 1024 x 1024
                           : (cx[31:27] == 5'd0 && cy[31:25] == 7'd0);      // 2048 x 512
// character byte: tile * 128 + row * 16 + {2,0,6,4,10,8,14,12}[column] after the flips, in
// MAME's host byte order (little-endian words; k037122.cpp gfx layout, MSB-first planes)
wire [2:0]  cxx = kf_tile[22] ? ~cx[18:16] : cx[18:16];
wire [2:0]  cyy = kf_tile[23] ? ~cy[18:16] : cy[18:16];
wire [18:0] cwa = {kf_tile[13:0], cyy, cxx[2:1]};
wire [7:0]  cpen = cxx[0] ? kf_cw[7:0] : kf_cw[23:16];
wire        chit = kf_chave && kf_cwa == cwa;

assign c_req  = kf == KF_CHAR && !chit;
assign c_addr = cwa;
always_comb
    if (kf == KF_PEN) k_raddr = pal_base + {2'b0, kf_tile[21:17], kf_pen};
    else              k_raddr = tile_base + {1'b0, ti};

always_ff @(posedge clk) begin
    if (reset) begin
        vf <= VF_IDLE; kf <= KF_IDLE; overrun <= 1'b0;
    end else begin
        overrun <= 1'b0;
        if (line_start) begin
            overrun <= vf != VF_IDLE || kf != KF_IDLE;
            b_line <= next_line;
            b_bank <= next_line[0];
            // line accumulators: line 0 from the start values, then + inc(y) a line
            if (next_line == 10'd0) begin
                row_cx <= startx;
                row_cy <= starty;
                xi_n <= v_xoffs;
            end else begin
                row_cx <= row_cx + incyx;
                row_cy <= row_cy + incyy;
            end
            // the Voodoo row: line - yoffs, a stride of bytes a line
            if (next_line == v_yoffs) v_rowbase <= v_base;
            else v_rowbase <= v_rowbase + {9'h0, v_stride, 1'b0};
            if (next_vis) begin
                vf <= VF_ADDR;
                vf_row_ok <= next_line >= v_yoffs;
                kf <= KF_START;
            end
        end else begin
            if (xi_n != 10'd0) begin
                row_cx <= row_cx + incxx;
                row_cy <= row_cy + incxy;
                xi_n <= xi_n - 10'd1;
            end
            // ------------------------------------------------ Voodoo row
            case (vf)
            VF_ADDR: begin
                vf_a <= v_rowbase;
                vf_x <= 10'd0; vf_have <= 1'b0;
                vf <= VF_RUN;
            end
            VF_RUN:
                if (vf_x == 10'(VIS_W)) vf <= VF_IDLE;
                else if (!vf_row_ok) begin
                    vbuf[b_bank][vf_x[8:0]] <= 16'h0;
                    vf_x <= vf_x + 10'd1;
                end else if (vf_have && vf_wa == vf_a[25:2]) begin
                    vbuf[b_bank][vf_x[8:0]] <= vf_a[1] ? vf_w[31:16] : vf_w[15:0];
                    vf_x <= vf_x + 10'd1;
                    vf_a <= vf_a + 26'd2;
                end else
                    vf <= VF_WAIT;
            VF_WAIT: if (s_ack) begin
                vf_w <= s_rdata; vf_wa <= vf_a[25:2]; vf_have <= 1'b1;
                vf <= VF_RUN;
            end
            default: ;
            endcase

            // ------------------------------------------------ K037122 row
            case (kf)
            KF_START: begin
                cx <= row_cx; cy <= row_cy;
                kf_x <= 10'd0; kf_thave <= 1'b0; kf_chave <= 1'b0;
                kf <= KF_POS;
            end
            KF_POS:
                if (kf_x == 10'(VIS_W)) kf <= KF_IDLE;
                else if (!inmap) begin
                    kbuf[b_bank][kf_x[8:0]] <= 17'h0;
                    kf_x <= kf_x + 10'd1;
                    cx <= cx + incxx; cy <= cy + incxy;
                end else if (kf_thave && kf_tidx == ti)
                    kf <= KF_CHAR;
                else begin
                    kf_tidx <= ti;              // tile word read this clock (k_raddr)
                    kf <= KF_TILE;
                end
            KF_TILE: begin
                kf_tile <= k_rdata; kf_thave <= 1'b1;
                kf <= KF_CHAR;
            end
            KF_CHAR:
                if (chit) begin
                    if (cpen == 8'h0) begin
                        kbuf[b_bank][kf_x[8:0]] <= 17'h0;
                        kf_x <= kf_x + 10'd1;
                        cx <= cx + incxx; cy <= cy + incxy;
                        kf <= KF_POS;
                    end else begin
                        kf_pen <= cpen;
                        kf <= KF_PEN;
                    end
                end else if (c_ack) begin
                    kf_cw <= c_rdata; kf_cwa <= cwa; kf_chave <= 1'b1;
                end
            KF_PEN: kf <= KF_PAL;               // palette read this clock (k_raddr)
            KF_PAL: begin
                kbuf[b_bank][kf_x[8:0]] <= {1'b1, k_rdata[15:0]};
                kf_x <= kf_x + 10'd1;
                cx <= cx + incxx; cy <= cy + incxy;
                kf <= KF_POS;
            end
            default: ;
            endcase
        end
    end
end

// ------------------------------------------------------------------------------------------
// Output
// ------------------------------------------------------------------------------------------

wire [9:0] hpos = lclk[11:2];
wire       vis  = hpos >= v_xoffs && hpos < v_xoffs + 10'(VIS_W) && vpos >= v_yoffs && vpos < v_yoffs + 10'(VIS_H);
wire [8:0] ox   = 9'(hpos - v_xoffs);

always_ff @(posedge clk) begin
    vid_ce <= lclk[1:0] == 2'd0;
    if (lclk[1:0] == 2'd0) begin
        logic [16:0] k;
        logic [15:0] v;
        k = kbuf[vpos[0]][ox];
        v = vbuf[vpos[0]][ox];
        vid_de <= vis;
        vid_x <= {1'b0, ox};
        vid_y <= vpos - v_yoffs;
        if (k[16]) begin
            // K037122 palette word: blue 15-11, red 10-6, green 5-0 (pal5bit / pal6bit)
            vid_r <= {k[10:6], k[10:8]};
            vid_g <= {k[5:0], k[5:4]};
            vid_b <= {k[15:11], k[15:13]};
        end else begin
            vid_r <= rtab[v[15:11]];
            vid_g <= gtab[v[10:5]];
            vid_b <= btab[v[4:0]];
        end
    end
end

endmodule
