// SPDX-License-Identifier: GPL-3.0-or-later
//
// vraster's fast fill (MAME rasterizer_fastfill, enqueue_fastfill): every row of the clip
// rectangle, the colour buffer from color1 through the dither the fbzMode names (indexed by the
// unflipped y, as MAME's), then the aux buffer from zaColor. A row is one burst on memFbWrite, a
// wide master's: two words (four pixels) a handshake from an even word, pixels outside the clip
// with their byte enables off.

// MAME dither_helper: matrices and the hardware equations (voodoo_render.h dither_rb, dither_g)
function automatic logic [3:0] dmat(input logic two, input logic [1:0] y, input logic [1:0] x);
    logic [3:0] m4 [16], m2 [16];
    m4 = '{4'd0, 4'd8, 4'd2, 4'd10, 4'd12, 4'd4, 4'd14, 4'd6, 4'd3, 4'd11, 4'd1, 4'd9, 4'd15, 4'd7, 4'd13, 4'd5};
    m2 = '{4'd8, 4'd10, 4'd8, 4'd10, 4'd11, 4'd9, 4'd11, 4'd9, 4'd8, 4'd10, 4'd8, 4'd10, 4'd11, 4'd9, 4'd11, 4'd9};
    return two ? m2[{y, x}] : m4[{y, x}];
endfunction
function automatic logic [15:0] dither565(input logic [31:0] fbz, input logic [1:0] y, input logic [1:0] x,
                                          input logic [7:0] r, input logic [7:0] g, input logic [7:0] b);
    logic [3:0]  d;
    logic [10:0] tr, tg, tb;
    if (!fbz[8]) return {r[7:3], g[7:2], b[7:3]};
    d = dmat(fbz[11], y, x);
    tr = ({3'b0, r} << 1) - {7'b0, r[7:4]} + {10'b0, r[7]} + {7'b0, d};
    tb = ({3'b0, b} << 1) - {7'b0, b[7:4]} + {10'b0, b[7]} + {7'b0, d};
    tg = ({3'b0, g} << 2) - {7'b0, g[7:4]} + {9'b0, g[7:6]} + {7'b0, d};
    return {tr[8:4], tg[9:4], tb[8:4]};
endfunction

typedef enum logic [2:0] { F_IDLE, F_ROW, F_BURST, F_NEXT } fstate_t;
fstate_t fs;
logic [9:0]  fl_y, fl_x, fl_x0, fl_x1, fl_y1;      // current row, word cursor, span, last row
logic        fl_aux;                                // this burst is the aux buffer's
logic [20:0] fl_row;                                // byte offset of the row (colour buffer)
logic [20:0] fl_auxrow;
logic [8:0]  fl_w0, fl_w1, fl_w;                    // first, last, current word of the burst
logic        fl_first;

wire [9:0] clip_l = clipLR[25:16], clip_r = clipLR[9:0], clip_t = clipTB[25:16], clip_b = clipTB[9:0];
wire       yflip = fbzMode[17];
wire [9:0] yorg = fbiInit3[31:22];

// colour of pixel x in row y (unflipped y for the dither, as MAME)
function automatic logic [15:0] fill_pix(input logic [9:0] y, input logic [9:0] x);
    return dither565(fbzMode, y[1:0], x[1:0], color1[23:16], color1[15:8], color1[7:0]);
endfunction

always_ff @(posedge clk) begin
    fill_done <= 1'b0;
    if (reset) fs <= F_IDLE;
    else case (fs)
    F_IDLE: if (fill_go) begin
        if (clip_t >= clip_b || clip_l >= clip_r) begin fill_done <= 1'b1; end
        else begin
            fl_y <= clip_t; fl_y1 <= clip_b - 10'd1;
            fl_w0 <= {clip_l[9:2], 1'b0}; fl_w1 <= {9'((clip_r - 10'd1) >> 1)} | 9'd1;
            fl_x0 <= clip_l; fl_x1 <= clip_r;
            fs <= F_ROW;
        end
    end
    F_ROW: begin
        // the row's byte offsets in the draw buffer and the aux buffer (y flipped for memory)
        logic [9:0]  sy;
        logic [20:0] rb;
        sy = yflip ? yorg - fl_y : fl_y;
        rb = 21'(sy * rowpix) << 1;
        fl_row <= rgboffs[fbzMode[15:14] == 2'd0 ? frontbuf : backbuf] + rb;
        fl_auxrow <= auxoffs + rb;
        fl_aux <= !fbzMode[9];                          // no colour pass: aux only
        fl_w <= fl_w0;
        fl_first <= 1'b1;
        fs <= F_BURST;
    end
    F_BURST: if (io_memFbWrite_waitRequestn) begin
        fl_first <= 1'b0;
        if (fl_w + 9'd1 == fl_w1) begin
            if (!fl_aux && fbzMode[10] && aux_ok) begin fl_aux <= 1'b1; fl_w <= fl_w0; fl_first <= 1'b1; end
            else fs <= F_NEXT;
        end else fl_w <= fl_w + 9'd2;
    end
    F_NEXT: if (fl_y == fl_y1) begin fill_done <= 1'b1; fs <= F_IDLE; end
            else begin fl_y <= fl_y + 10'd1; fs <= F_ROW; end
    default: fs <= F_IDLE;
    endcase
end

always_comb begin
    logic [9:0] xa, xb, xc, xd;
    xa = {fl_w, 1'b0}; xb = {fl_w, 1'b1}; xc = {fl_w + 9'd1, 1'b0}; xd = {fl_w + 9'd1, 1'b1};
    io_memFbWrite_read = 1'b0;
    io_memFbWrite_write = fs == F_BURST;
    io_memFbWrite_address = FB_BASE + {11'h0, (fl_aux ? fl_auxrow : fl_row)} + {21'h0, fl_w0, 2'b00};
    io_memFbWrite_burstCount = {2'b0, fl_w1 - fl_w0 + 9'd1};
    io_memFbWrite_byteEnable = {{2{xb >= fl_x0 && xb < fl_x1}}, {2{xa >= fl_x0 && xa < fl_x1}}};
    io_memFbWrite_writeData = fl_aux ? {zaColor[15:0], zaColor[15:0]} : {fill_pix(fl_y, xb), fill_pix(fl_y, xa)};
    io_memFbWrite_byteEnableHi = {{2{xd >= fl_x0 && xd < fl_x1}}, {2{xc >= fl_x0 && xc < fl_x1}}};
    io_memFbWrite_writeDataHi = fl_aux ? {zaColor[15:0], zaColor[15:0]} : {fill_pix(fl_y, xd), fill_pix(fl_y, xc)};
end
