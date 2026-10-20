// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hornet's picture: the Voodoo's displayed buffer through its CLUT, with the K037122's
// rotate/zoom tilemap over it (hornet.cpp screen_update: voodoo update, then k037122 tile_draw).
//
// Screen: 644 pixels a line at clk/4; 512 x 384 visible from the Voodoo's back porch (xoffs,
// yoffs), as MAME's recompute_video_timing sets its screen (voodoo.cpp:2749-2750).
// Each visible line is built while the line before it is shown, into one of two line buffers:
//   Voodoo   the displayed buffer's row (line - yoffs): one 256-word burst on port S, a word
//            (two pixels) into the line buffer as each comes back.
//   K037122  per pixel, the tilemap position (cx, cy) = start + x * incx + y * incy in 16.16,
//            x and y the raster position (x from xoffs)
//            (k037122.cpp tile_draw, tilemap.cpp draw_roz_core without wraparound): outside the
//            map, or pen 0, is transparent. Tile words and the palette from the K037122 SRAM
//            (k_raddr/k_rdata, one clock), the character RAM on port C a tile row (four words,
//            eight pixels) at a time. A pixel a clock while its tile and row are in hand, the
//            palette read one clock and written the next. The start of each line and each pixel's
//            position come from adders, not multiplies.
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

    // port C: K037122 character RAM, a tile row of four words (word address, 4-aligned): word k
    // of the row in c_rdata[32k+31:32k]
    output logic        c_req,
    output logic [18:0] c_addr,
    input  logic        c_ack,
    input  logic [127:0] c_rdata,

    // port S: the Voodoo's frame buffer, an Avalon-MM read master (hornet_ddr3's kind): byte
    // address of a 32-bit word, a burst of s_burst words, data at s_rvalid
    output logic        s_read,
    output logic [25:0] s_addr,
    output logic [10:0] s_burst,
    input  logic        s_waitn,
    input  logic        s_rvalid,
    input  logic [31:0] s_rdata,
    input  logic [31:0] s_rdata_hi,     // wide (hornet_ddr3 WIDE): a beat, two words, a clock

    input  logic [25:0] v_base,         // displayed buffer (vraster buffer0Base)
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
    output logic        vid_hb, vid_vb, // blanking: outside the 512 x 384 window
    output logic        vid_hs, vid_vs, // sync: placed after the window (HACKS.md)
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

// the tables rebuilt after a CLUT write, an entry a clock in two steps: the two CLUT entries
// (p_*), then the interpolation and the table write
logic        p_v;
logic [6:0]  p_i;
logic [2:0]  p_f;
logic [23:0] p_e0, p_e1;
always_ff @(posedge clk) begin
    p_v <= 1'b0;
    if (reset) begin
        tab_busy <= 1'b1; tab_i <= 7'd0;
        // MAME's power-on CLUT (voodoo.cpp:994-996): a grey ramp of pal5bit(n), entry 32 white.
        // gradius4 runs with it: MAME snapshots at frames 140, 195, 625 and 2150 all hold it.
        for (int n = 0; n < 32; n++) clut[n] <= {3{5'(n), 3'(n >> 2)}};
        clut[32] <= 24'hFFFFFF;
    end else begin
        if (clut_we && clut_idx <= 6'd32) begin
            clut[clut_idx] <= clut_data;
            tab_busy <= 1'b1; tab_i <= 7'd0;
        end else if (tab_busy) begin
            logic [7:0] c;
            if (tab_i < 7'd32) c = {tab_i[4:0], tab_i[4:2]};                       // pal5bit
            else c = {6'(tab_i - 7'd32), 2'(6'(tab_i - 7'd32) >> 4)};             // pal6bit
            p_v <= 1'b1; p_i <= tab_i; p_f <= c[2:0];
            p_e0 <= clut_at({1'b0, c[7:3]}); p_e1 <= clut_at({1'b0, c[7:3]} + 6'd1);
            if (tab_i == 7'd95) tab_busy <= 1'b0;
            tab_i <= tab_i + 7'd1;
        end
    end
    if (p_v) begin
        if (p_i < 7'd32) begin
            rtab[p_i[4:0]] <= lerp8(p_e0[23:16], p_e1[23:16], p_f);
            btab[p_i[4:0]] <= lerp8(p_e0[7:0],   p_e1[7:0],   p_f);
        end else
            gtab[6'(p_i - 7'd32)] <= lerp8(p_e0[15:8], p_e1[15:8], p_f);
    end
end

// ------------------------------------------------------------------------------------------
// Line buffers: [bank][x]
// ------------------------------------------------------------------------------------------

// block RAMs, {bank, x}: written a clock after the builders ask, read by the output. Instanced:
// inferred, Quartus retimed vbuf's read register into the CLUT lookup and built it from registers
logic        vb_we, kb_we;
logic [7:0]  vb_wa;                     // {bank, beat}: four pixels a beat
logic [10:0] kb_wa;
logic [63:0] vb_wd;
logic [16:0] kb_wd;
logic [63:0] vb_q;
logic [16:0] kb_q;

// ------------------------------------------------------------------------------------------
// Line build: the Voodoo row during the line before; the K037122 row up to three lines ahead,
// into four banks, so a line of tile-row misses borrows time from the hits after it
// ------------------------------------------------------------------------------------------

wire        line_start = run && lclk == 16'd0;
wire [9:0]  next_line = ({2'b0, vpos} + 12'd1 >= vtotal) ? 10'd0 : vpos + 10'd1;
wire        next_vis = next_line >= v_yoffs && next_line < v_yoffs + 10'(VIS_H);
logic [9:0] b_line;                     // the K037122 line being built
logic [1:0] b_bank;
logic [9:0] bl;                         // the next K037122 line to take
// bl's distance after the line shown, modulo the frame: 1-3 it may be built, 0 or a line or more
// behind (an overrun) it is skipped
wire [11:0] bl_d = ({2'b0, bl} >= {2'b0, vpos}) ? {2'b0, bl} - {2'b0, vpos} : {2'b0, bl} + vtotal - {2'b0, vpos};
wire        bl_ahead = bl_d >= 12'd1 && bl_d <= 12'd3;
wire        bl_late = bl_d == 12'd0 || bl_d + 12'd16 > vtotal;
wire        bl_vis = bl >= v_yoffs && bl < v_yoffs + 10'(VIS_H);
wire        vpos_vis = vpos >= v_yoffs && vpos < v_yoffs + 10'(VIS_H);

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
logic [31:0] row_cx, row_cy;            // for bl
logic [9:0]  xi_n;

// ---------------------------------------------------------------- Voodoo row
typedef enum logic [1:0] { VF_IDLE, VF_ZERO, VF_REQ, VF_DATA } vf_t;
vf_t         vf;
logic [8:0]  vf_w;                      // next word of the line
logic        vf_bank;
logic [25:0] v_rowbase;                 // the displayed buffer's row for b_line (word aligned)

assign s_read  = vf == VF_REQ;
assign s_addr  = {v_rowbase[25:2], 2'b00};
assign s_burst = 11'(VIS_W / 2);

// ---------------------------------------------------------------- K037122 row
typedef enum logic [2:0] { KF_IDLE, KF_RUN, KF_TILE, KF_CHAR, KF_END } kf_t;
kf_t         kf;
logic [9:0]  kf_x;
logic [31:0] cx, cy;
logic [13:0] kf_tidx;                   // tile of kf_tile
logic        kf_thave;
logic [31:0] kf_tile;
logic [16:0] kf_rwa;                    // row held in kf_row (word address / 4)
logic        kf_rhave;
logic [127:0] kf_row;
logic        kp_we, kp_pal;             // the pixel written next clock: transparent, or the palette
logic [8:0]  kp_x;                      // word read this clock

wire [10:0] px = cx[26:16];
wire [10:0] py = cy[26:16];
wire [13:0] ti = map128 ? {py[9:3], px[9:3]} : {py[8:3], px[10:3]};
wire        inmap = map128 ? (cx[31:26] == 6'd0 && cy[31:26] == 6'd0)       // 1024 x 1024
                           : (cx[31:27] == 5'd0 && cy[31:25] == 7'd0);      // 2048 x 512
// character byte: tile * 128 + row * 16 + {2,0,6,4,10,8,14,12}[column] after the flips, in
// MAME's host byte order (little-endian words; k037122.cpp gfx layout, MSB-first planes)
wire [2:0]  cxx = kf_tile[22] ? ~cx[18:16] : cx[18:16];
wire [2:0]  cyy = kf_tile[23] ? ~cy[18:16] : cy[18:16];
wire [16:0] rwa = {kf_tile[13:0], cyy};
wire [31:0] rword = kf_row[32 * cxx[2:1] +: 32];
wire [7:0]  cpen = cxx[0] ? rword[7:0] : rword[23:16];
wire        k_thit = kf_thave && kf_tidx == ti;
wire        k_rhit = kf_rhave && kf_rwa == rwa;

assign c_req  = kf == KF_CHAR;
assign c_addr = {kf_rwa, 2'b00};
always_comb
    if (kf == KF_RUN && inmap && k_thit) k_raddr = pal_base + {2'b0, kf_tile[21:17], cpen};
    else                                 k_raddr = tile_base + {1'b0, ti};

always_ff @(posedge clk) begin
    if (reset) begin
        vf <= VF_IDLE; kf <= KF_IDLE; overrun <= 1'b0;
        // out of range: the first step wraps to line 0 and takes its start values then
        bl <= 10'h3FF; xi_n <= 10'd0;
    end else begin
        overrun <= 1'b0;
        vb_we <= 1'b0; kb_we <= 1'b0;
        if (line_start) begin
            // the line now shown, if visible, should be built: not still building, not skipped
            overrun <= vf != VF_IDLE ||
                       (vpos_vis && ((kf != KF_IDLE && b_line == vpos) || bl == vpos));
            // the Voodoo row: line - yoffs, a stride of bytes a line
            if (next_line == v_yoffs) v_rowbase <= v_base;
            else v_rowbase <= v_rowbase + {9'h0, v_stride, 1'b0};
            // a row still arriving from an overrun is let finish (its data is in flight)
            if (next_vis && vf == VF_IDLE) begin
                vf <= (next_line >= v_yoffs) ? VF_REQ : VF_ZERO;
                vf_w <= 9'd0; vf_bank <= next_line[0];
            end
        end else begin
            case (vf)
            VF_ZERO: begin
                vb_we <= 1'b1; vb_wa <= {vf_bank, vf_w[7:1]}; vb_wd <= 64'h0;
                vf_w <= vf_w + 9'd2;
                if (vf_w == 9'(VIS_W / 2 - 2)) vf <= VF_IDLE;
            end
            VF_REQ: if (s_waitn) vf <= VF_DATA;
            VF_DATA: if (s_rvalid) begin
                vb_we <= 1'b1; vb_wa <= {vf_bank, vf_w[7:1]}; vb_wd <= {s_rdata_hi, s_rdata};
                vf_w <= vf_w + 9'd2;
                if (vf_w == 9'(VIS_W / 2 - 2)) vf <= VF_IDLE;
            end
            default: ;
            endcase
        end

        // ------------------------------------------------ K037122 rows, ahead of the display
        // line 0's x term, xoffs * inc(x), added once a clock before the line is taken
        if (xi_n != 10'd0) begin
            row_cx <= row_cx + incxx;
            row_cy <= row_cy + incxy;
            xi_n <= xi_n - 10'd1;
        end
        if (kp_we) begin
            kb_we <= 1'b1; kb_wa <= {b_bank, kp_x}; kb_wd <= kp_pal ? {1'b1, k_rdata[15:0]} : 17'h0;
        end
        kp_we <= 1'b0;
        case (kf)
        KF_IDLE:
            // take line bl when it is 1-3 lines ahead of the one shown (its bank is free); a line
            // the display has reached or passed is skipped. Then step to the next line: line 0
            // from the start values, else + inc(y).
            if (run && xi_n == 10'd0 && (bl_ahead || bl_late)) begin
                if (bl_ahead && bl_vis) begin
                    b_line <= bl; b_bank <= bl[1:0];
                    cx <= row_cx; cy <= row_cy;
                    kf_x <= 10'd0; kf_thave <= 1'b0; kf_rhave <= 1'b0;
                    kf <= KF_RUN;
                end
                if ({2'b0, bl} + 12'd1 >= vtotal) begin
                    bl <= 10'd0; row_cx <= startx; row_cy <= starty; xi_n <= v_xoffs;
                end else begin
                    bl <= bl + 10'd1; row_cx <= row_cx + incyx; row_cy <= row_cy + incyy;
                end
            end
        KF_RUN:
            if (kf_x == 10'(VIS_W)) kf <= KF_END;
            else if (inmap && !k_thit) begin
                kf_tidx <= ti;                  // tile word read this clock (k_raddr)
                kf <= KF_TILE;
            end else if (inmap && !k_rhit) begin
                kf_rwa <= rwa;
                kf <= KF_CHAR;
            end else begin
                // a pixel: transparent outside the map or at pen 0, else its palette word,
                // read this clock (k_raddr) and written the next
                kp_we <= 1'b1; kp_x <= kf_x[8:0]; kp_pal <= inmap && cpen != 8'h0;
                kf_x <= kf_x + 10'd1;
                cx <= cx + incxx; cy <= cy + incxy;
            end
        KF_TILE: begin
            kf_tile <= k_rdata; kf_thave <= 1'b1;
            kf <= KF_RUN;
        end
        KF_CHAR: if (c_ack) begin
            kf_row <= c_rdata; kf_rhave <= 1'b1;
            kf <= KF_RUN;
        end
        KF_END: kf <= KF_IDLE;                  // the last pixel's write
        default: ;
        endcase
    end
end

// ------------------------------------------------------------------------------------------
// Output
// ------------------------------------------------------------------------------------------

wire [9:0] hpos = lclk[11:2];
wire       vis  = hpos >= v_xoffs && hpos < v_xoffs + 10'(VIS_W) && vpos >= v_yoffs && vpos < v_yoffs + 10'(VIS_H);
wire [8:0] ox   = 9'(hpos - v_xoffs);

logic [23:0] kb_q24;
hornet_sdpram #(.AW(8), .DW(64)) u_vbuf (.clk,
    .a_addr(vb_wa), .a_be({8{vb_we}}), .a_wdata(vb_wd),
    .b_addr({vpos[0], ox[8:2]}), .b_rdata(vb_q));
wire [31:0] vb_w  = ox[1] ? vb_q[63:32] : vb_q[31:0];
wire [15:0] vb_px = ox[0] ? vb_w[31:16] : vb_w[15:0];
hornet_dpram #(.AW(11), .DW(24)) u_kbuf (.clk,
    .a_addr(kb_wa), .a_be({3{kb_we}}), .a_wdata({7'h0, kb_wd}), .a_rdata(),
    .b_addr({vpos[1:0], ox}), .b_be(3'b000), .b_wdata(24'h0), .b_rdata(kb_q24));
assign kb_q = kb_q24[16:0];

always_ff @(posedge clk) begin
    vid_ce <= lclk[1:0] == 2'd1;
    if (lclk[1:0] == 2'd1) begin
        vid_de <= vis;
        vid_hb <= !(hpos >= v_xoffs && hpos < v_xoffs + 10'(VIS_W));
        vid_vb <= !(vpos >= v_yoffs && vpos < v_yoffs + 10'(VIS_H));
        vid_hs <= hpos >= v_xoffs + 10'(VIS_W + 16) && hpos < v_xoffs + 10'(VIS_W + 64);
        vid_vs <= vpos >= v_yoffs + 10'(VIS_H + 3) && vpos < v_yoffs + 10'(VIS_H + 6);
        vid_x <= {1'b0, ox};
        vid_y <= vpos - v_yoffs;
        if (kb_q[16]) begin
            // K037122 palette word: blue 15-11, red 10-6, green 5-0 (pal5bit / pal6bit)
            vid_r <= {kb_q[10:6], kb_q[10:8]};
            vid_g <= {kb_q[5:0], kb_q[5:4]};
            vid_b <= {kb_q[15:11], kb_q[15:13]};
        end else begin
            vid_r <= rtab[vb_px[15:11]];
            vid_g <= gtab[vb_px[10:5]];
            vid_b <= btab[vb_px[4:0]];
        end
    end
end

endmodule
