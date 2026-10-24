// SPDX-License-Identifier: GPL-3.0-or-later
//
// vraster's triangles: MAME's poly.h render_triangle spans (vertices sorted by y, scanlines
// sampled at y + 0.5, ends rounded by round_coordinate) and voodoo_render.cpp's rasterizer per
// span.
//
// Approximations (docs/HACKS.md): slopes in fixed point (MAME uses float), iterated R/G/B taken
// as zero (the game never writes them; their registers stay 0), no Z iteration (W-buffer only).

// ---------------------------------------------------------------- per-pixel stages (MAME)

function automatic logic [7:0] pclamp8(input logic [11:0] v);    // clamped_argb's pseudo-clamp
    if (v == 12'hFFF) return 8'h00;
    if (v == 12'h100) return 8'hFF;
    return v[7:0];
endfunction

function automatic logic [7:0] sat8(input logic signed [17:0] v);
    return (v < 0) ? 8'h00 : (v > 18'sd255) ? 8'hFF : v[7:0];
endfunction

function automatic logic [23:0] rgb565_888(input logic [15:0] p);
    return {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};
endfunction

// a pixel's colour (MAME combine_color, chroma key, alpha test): the clamped iterated A and the
// texel (ARGB); whether the pixel survives, and its A R G B
typedef struct packed {
    logic        pass;
    logic [31:0] c;                // A R G B
} pc_t;
// in two clocks: pix_sel, the selects (blend colour, factor, add, chroma key); pix_comb, the
// scale, add, clamp and alpha test
typedef struct packed {
    logic        pass;                                 // the chroma key passes
    logic [3:0][9:0] bc;                               // blend colour (signed), A R G B
    logic [3:0][8:0] bfac;                             // blend factor
    logic [3:0][7:0] av;                               // the add
} ps_t;
function automatic ps_t pix_sel(input logic [7:0] ia, input logic [31:0] texel);
    ps_t o;
    logic [7:0]  oc [4], lc [4], tx [4], c1 [4], c0 [4], bf [4], av [4], it [4];
    logic signed [9:0] bc [4];
    logic [8:0]  bfac [4];
    o.pass = 1'b1;
    it = '{ia, 8'h00, 8'h00, 8'h00};                    // iterated RGB is 0 (header)
    tx = '{texel[31:24], texel[23:16], texel[15:8], texel[7:0]};
    c1 = '{color1[31:24], color1[23:16], color1[15:8], color1[7:0]};
    c0 = '{color0[31:24], color0[23:16], color0[15:8], color0[7:0]};
    // c_other (rgbselect, aselect); chroma key on its RGB
    for (int k = 1; k < 4; k++)
        case (fbzColorPath[1:0]) 2'd0: oc[k] = it[k]; 2'd1: oc[k] = tx[k]; 2'd2: oc[k] = c1[k]; default: oc[k] = 8'h0; endcase
    if (fbzMode[1] && {oc[1], oc[2], oc[3]} == chromaKey[23:0]) o.pass = 1'b0;
    case (fbzColorPath[3:2]) 2'd0: oc[0] = it[0]; 2'd1: oc[0] = tx[0]; 2'd2: oc[0] = c1[0]; default: oc[0] = 8'h0; endcase
    // c_local (localselect, its override, cca_localselect)
    for (int k = 1; k < 4; k++)
        lc[k] = (fbzColorPath[7] ? tx[0][7] : fbzColorPath[4]) ? c0[k] : it[k];
    case (fbzColorPath[6:5]) 2'd1: lc[0] = c0[0]; default: lc[0] = it[0]; endcase   // 2, 3: Z/W unused
    // blend colour: zero other, subtract local
    for (int k = 0; k < 4; k++) begin
        logic zo, sub;
        zo = (k == 0) ? fbzColorPath[17] : fbzColorPath[8];
        sub = (k == 0) ? fbzColorPath[18] : fbzColorPath[9];
        bc[k] = (zo ? 10'sd0 : $signed({2'b0, oc[k]})) - (sub ? $signed({2'b0, lc[k]}) : 10'sd0);
    end
    // blend factor (mselect), reversed unless the reverse bit
    for (int k = 1; k < 4; k++)
        case (fbzColorPath[12:10])
        3'd1: bf[k] = lc[k];
        3'd2: bf[k] = oc[0];
        3'd3: bf[k] = lc[0];
        3'd4: bf[k] = tx[0];
        default: bf[k] = 8'h0;
        endcase
    case (fbzColorPath[21:19])
    3'd1, 3'd3: bf[0] = lc[0];
    3'd2: bf[0] = oc[0];
    3'd4: bf[0] = tx[0];
    default: bf[0] = 8'h0;
    endcase
    for (int k = 0; k < 4; k++) begin
        logic rev;
        rev = (k == 0) ? fbzColorPath[22] : fbzColorPath[13];
        bfac[k] = {1'b0, rev ? bf[k] : ~bf[k]} + 9'd1;
    end
    // add c_local / a_local
    for (int k = 1; k < 4; k++)
        case (fbzColorPath[15:14]) 2'd1: av[k] = lc[k]; 2'd2: av[k] = lc[0]; default: av[k] = 8'h0; endcase
    av[0] = fbzColorPath[24:23] != 2'd0 ? lc[0] : 8'h0;
    for (int k = 0; k < 4; k++) begin o.bc[k] = bc[k]; o.bfac[k] = bfac[k]; o.av[k] = av[k]; end
    return o;
endfunction
function automatic pc_t pix_comb(input ps_t ps);
    pc_t o;
    logic [7:0]  fc [4];
    o.pass = ps.pass;
    // scale, add, clamp (rgbaint scale_add_and_clamp: (c * f >> 8) + a), invert
    for (int k = 0; k < 4; k++) begin
        logic signed [19:0] p;
        p = ($signed(ps.bc[k]) * $signed({1'b0, ps.bfac[k]})) >>> 8;
        fc[k] = sat8(18'(p) + $signed({10'b0, ps.av[k]}));
    end
    if (fbzColorPath[25]) fc[0] = ~fc[0];
    if (fbzColorPath[16]) for (int k = 1; k < 4; k++) fc[k] = ~fc[k];
    // alpha test
    if (alphaMode[0])
        case (alphaMode[3:1])
        3'd0: o.pass = 1'b0;
        3'd1: if (!(fc[0] < alphaMode[31:24])) o.pass = 1'b0;
        3'd2: if (!(fc[0] == alphaMode[31:24])) o.pass = 1'b0;
        3'd3: if (!(fc[0] <= alphaMode[31:24])) o.pass = 1'b0;
        3'd4: if (!(fc[0] > alphaMode[31:24])) o.pass = 1'b0;
        3'd5: if (!(fc[0] != alphaMode[31:24])) o.pass = 1'b0;
        3'd6: if (!(fc[0] >= alphaMode[31:24])) o.pass = 1'b0;
        default: ;
        endcase
    o.c = {fc[0], fc[1], fc[2], fc[3]};
    return o;
endfunction

typedef struct packed {
    logic        ok;                                   // the pixel is written
    logic [7:0]  r, g, b;
    logic [15:0] depth;
} pb_t;

// the pixel out before the dither (compute_depthval, depth_test, alpha_blend): the colour from
// pix_comb, wfloat, the destination colour and depth
function automatic pb_t pix_blend(input pc_t pc, input logic [15:0] wf, input logic [15:0] dpix,
                                  input logic [15:0] dz);
    pb_t o;
    logic signed [17:0] dv;
    logic [7:0] fc [4];
    o = '0;
    dv = {2'b0, wf};
    if (fbzMode[16]) begin
        dv = dv + 18'(signed'(zaColor[15:0]));
        dv = (dv < 0) ? 18'sd0 : (dv > 18'sd65535) ? 18'sd65535 : dv;
    end
    if (!pc.pass) return o;
    if (fbzMode[4]) begin
        logic [15:0] s;
        logic pass;
        s = fbzMode[20] ? zaColor[15:0] : dv[15:0];
        case (fbzMode[7:5])
        3'd0: pass = 1'b0;
        3'd1: pass = s < dz;
        3'd2: pass = s == dz;
        3'd3: pass = s <= dz;
        3'd4: pass = s > dz;
        3'd5: pass = s != dz;
        3'd6: pass = s >= dz;
        default: pass = 1'b1;
        endcase
        if (!pass) return o;
    end
    fc = '{pc.c[31:24], pc.c[23:16], pc.c[15:8], pc.c[7:0]};
    // alpha blend (alpha planes off: destination alpha 0xFF)
    if (alphaMode[4]) begin
        logic [23:0] d;
        logic [7:0]  dc [4];
        logic [8:0]  ss [4], ds [4];
        d = rgb565_888(dpix);
        dc = '{8'hFF, d[23:16], d[15:8], d[7:0]};
        for (int k = 1; k < 4; k++) begin
            case (alphaMode[11:8])
            4'd1: ss[k] = {1'b0, fc[0]} + 9'd1;
            4'd2: ss[k] = {1'b0, dc[k]} + 9'd1;
            4'd3: ss[k] = 9'd256;
            4'd4: ss[k] = 9'd256;
            4'd5: ss[k] = 9'd256 - {1'b0, fc[0]};
            4'd6: ss[k] = 9'd256 - {1'b0, dc[k]};
            4'd7: ss[k] = 9'd1;
            4'd15: ss[k] = (fc[0] == 8'd0) ? 9'd1 : 9'd2;     // min(sa, 0x100 - 0xFF) + 1
            default: ss[k] = 9'd0;
            endcase
            case (alphaMode[15:12])
            4'd1: ds[k] = {1'b0, fc[0]} + 9'd1;
            4'd2: ds[k] = {1'b0, fc[k]} + 9'd1;
            4'd3: ds[k] = 9'd256;
            4'd4: ds[k] = 9'd256;
            4'd5: ds[k] = 9'd256 - {1'b0, fc[0]};
            4'd6: ds[k] = 9'd256 - {1'b0, fc[k]};
            4'd7: ds[k] = 9'd1;
            4'd15: ds[k] = {1'b0, fc[k]} + 9'd1;
            default: ds[k] = 9'd0;
            endcase
            fc[k] = sat8(18'(({10'b0, fc[k]} * ss[k] + {10'b0, dc[k]} * ds[k]) >> 8));
        end
    end
    o.ok = 1'b1;
    o.r = fc[1]; o.g = fc[2]; o.b = fc[3];
    o.depth = dv[15:0];
    return o;
endfunction

// ---------------------------------------------------------------- triangle setup and span generation
//
// Spans flow through the line-buffer sets in turn: the reader fills a set with the span's colour
// and depth rows, the pixel pipeline runs the span through it, the writer writes the rows back
// whole (pixels that fail keep what was read). Within a triangle the stages overlap. A triangle
// ends for the command processor once its last span is handed to the reader (drain_pend while its
// spans finish): the next one's register writes and setup go on meanwhile, and its first span
// waits for the pipeline and the fill engine to be idle, so no two triangles' spans meet in it.

typedef enum logic [3:0] {
    T_IDLE, T_SORT, T_DIV, T_ROW0, T_LINE, T_CLIP, T_SPAN, T_NEXT, T_DRAIN
} tstate_t;
tstate_t ts;

logic signed [15:0] t1x, t1y, t2x, t2y, t3x, t3y;      // sorted vertices, 12.4
logic signed [11:0] y_cur, y_end;                     // scanline, last + 1
logic signed [39:0] slope13, slope12, slope23;        // pixels per pixel, 20 fraction bits
logic [5:0]  div_n;
logic [39:0] div_rem [3], div_q [3], div_d [3];
logic        div_neg [3], div_z [3];
logic [9:0]  sx0, sx1, s_scry;
logic signed [11:0] cx0, cx1;                          // the clipped ends before the empty test
logic        row_skip;

// parameters at x = vertex A's integer x on the current row (MAME: start + dy * dpdy), and the
// multiply that takes them to a span's start: one parameter a clock (A, W, S, T)
logic signed [31:0] r_a;
logic signed [63:0] r_w, r_s, r_t;
logic [1:0]  pk;
logic signed [31:0] sp_a;
logic signed [63:0] sp_w, sp_s, sp_t;

wire signed [11:0] axi = 12'(vAx >>> 4), ayi = 12'(vAy >>> 4);

// The edges' x at the scanline centre, 20 fraction bits (mod 2^32): (xa << 20 + dy16 s) >> 4 on
// the first row (dy16: y + 0.5 - ya in 12.4), then + s a row, which is exact; rounded by MAME's
// round_coordinate
// an edge's x rounded to a pixel and held to -2048..2047: an edge far off the screen stays off it
// (MAME's edges are floats; a wrapped one would span the screen)
function automatic logic signed [11:0] edge_round(input logic signed [43:0] x20);
    logic signed [24:0] v;
    v = 25'(x20 >>> 20) + ((x20[19:0] > 20'h80000) ? 25'sd1 : 25'sd0);
    return (v > 25'sd2047) ? 12'sd2047 : (v < -25'sd2048) ? -12'sd2048 : 12'(v);
endfunction
logic signed [56:0] ep [3];                            // the first row's dy16 s
logic signed [43:0] x13, x12, x23;                    // 12.20 with 12 bits to spare: no wrap
logic signed [11:0] ea, eb;                            // this row's ends, rounded
logic [9:0]  sy_l;

// the one multiplier of the row and span starts: (y - ay) or (x0 - ax) by the parameter pk's slope,
// its operands registered (m1), the product the clock after (mprod_q), added the clock after that
logic signed [11:0] mop_a, ma_q;
logic signed [63:0] mop_b, mb_q;
logic signed [63:0] mprod_q;
logic [2:0]  mk1, mk_q;                                // its {row, parameter}
logic        mv1, mv_q;
always_ff @(posedge clk) begin
    ma_q <= mop_a; mb_q <= mop_b;
    mk1 <= {ts == T_ROW0, pk};
    mv1 <= ts == T_ROW0 || (ts == T_SPAN && !span_hold);
    mprod_q <= 64'(ma_q * mb_q);
    mk_q <= mk1;
    mv_q <= mv1;
end
always_comb begin
    mop_a = (ts == T_ROW0) ? y_cur - ayi : $signed({2'b0, sx0}) - axi;
    case ({ts == T_ROW0, pk})
    3'b100: mop_b = 64'(dAdY);  3'b101: mop_b = dWdY;  3'b110: mop_b = dSdY;  3'b111: mop_b = dTdY;
    3'b000: mop_b = 64'(dAdX);  3'b001: mop_b = dWdX;  3'b010: mop_b = dSdX;  default: mop_b = dTdX;
    endcase
end

// span descriptor handed to the reader
logic        sd_v;
logic [9:0]  sd_x0, sd_x1;
logic [20:0] sd_crow, sd_zrow;
logic [9:0]  sd_scry;
logic signed [31:0] sd_a;
logic signed [63:0] sd_w, sd_s, sd_t;
logic        sd_take;                                  // the reader takes it this clock

// the span whose start parameters are being computed, emitted when its last product has landed
// while the row loop goes on to the next row (whose products wait for the emit: span_hold)
logic        e_v, e_last;                              // pending; the row's last part
logic [9:0]  e_x0, e_x1, e_sy;
wire         span_hold = ts == T_SPAN && pk == 2'd0 && e_v;
wire         emit_now = e_v && !mv1 && !mv_q && (!sd_v || sd_take) && !drain_pend;
// the pipeline's x-gradients, taken at each emit (the registers may hold the next triangle's)
logic signed [31:0] px_dadx;
logic signed [63:0] px_dwdx, px_dsdx, px_dtdx;

logic        spans_idle;                               // no set busy, pipeline empty
logic        fill_idle;                                // the texture fill engine idle

always_ff @(posedge clk) begin
    tri_done <= 1'b0;
    if (sd_take) sd_v <= 1'b0;
    if (mv_q)
        case (mk_q)
        3'b100: r_a <= startA + 32'(mprod_q);
        3'b101: r_w <= startW + mprod_q;
        3'b110: r_s <= startS + mprod_q;
        3'b111: r_t <= startT + mprod_q;
        3'b000: sp_a <= r_a + 32'(mprod_q);
        3'b001: sp_w <= r_w + mprod_q;
        3'b010: sp_s <= r_s + mprod_q;
        default: sp_t <= r_t + mprod_q;
        endcase
    if (drain_pend && spans_idle && fill_idle && !sd_v) drain_pend <= 1'b0;
    if (emit_now) begin
        logic [20:0] rb;
        rb = 21'(e_sy * rowpix) << 1;
        px_dadx <= dAdX; px_dwdx <= dWdX; px_dsdx <= dSdX; px_dtdx <= dTdX;
        sd_v <= 1'b1;
        sd_x0 <= e_x0; sd_x1 <= e_x1; sd_scry <= e_sy;
        sd_crow <= rgboffs[fbzMode[15:14] == 2'd0 ? frontbuf : backbuf] + rb;
        sd_zrow <= auxoffs + rb;
        sd_a <= sp_a <<< 8; sd_w <= sp_w; sd_s <= sp_s; sd_t <= sp_t;
        e_v <= 1'b0;
        // the row's parameters step once its last span has its products
        if (e_last) begin r_a <= r_a + dAdY; r_w <= r_w + dWdY; r_s <= r_s + dSdY; r_t <= r_t + dTdY; end
    end
    if (reset) begin ts <= T_IDLE; sd_v <= 1'b0; e_v <= 1'b0; drain_pend <= 1'b0; end
    else case (ts)
    T_IDLE: if (tri_go) begin
        logic signed [15:0] ax, ay, bx, by, cx, cy;
        ax = vAx; ay = vAy; bx = vBx; by = vBy; cx = vCx; cy = vCy;
        if (by < ay) begin {ax, bx} = {bx, ax}; {ay, by} = {by, ay}; end
        if (cy < by) begin
            {bx, cx} = {cx, bx}; {by, cy} = {cy, by};
            if (by < ay) begin {ax, bx} = {bx, ax}; {ay, by} = {by, ay}; end
        end
        t1x <= ax; t1y <= ay; t2x <= bx; t2y <= by; t3x <= cx; t3y <= cy;
        y_cur <= 12'(ay >>> 4) + ((ay[3:0] > 4'd8) ? 12'sd1 : 12'sd0);
        y_end <= 12'(cy >>> 4) + ((cy[3:0] > 4'd8) ? 12'sd1 : 12'sd0);
        ts <= T_SORT;
    end
    T_SORT: begin
        // the three edges' slopes, dx / dy, divided side by side (dy = 0: slope 0)
        logic signed [16:0] dx [3], dy [3];
        dx[0] = 17'(t3x) - 17'(t1x); dy[0] = 17'(t3y) - 17'(t1y);
        dx[1] = 17'(t2x) - 17'(t1x); dy[1] = 17'(t2y) - 17'(t1y);
        dx[2] = 17'(t3x) - 17'(t2x); dy[2] = 17'(t3y) - 17'(t2y);
        for (int k = 0; k < 3; k++) begin
            div_neg[k] <= dx[k][16];
            div_z[k] <= dy[k] == 0;
            div_q[k] <= {(dx[k][16] ? -dx[k] : dx[k]), 23'h0} >> 3;
            div_d[k] <= 40'(dy[k]);
            div_rem[k] <= 40'h0;
        end
        div_n <= 6'd40;
        ts <= T_DIV;
    end
    T_DIV: begin
        logic [40:0] r;
        logic signed [39:0] q [3];
        for (int k = 0; k < 3; k++) begin
            r = {div_rem[k][39:0], div_q[k][39]};
            div_q[k] <= {div_q[k][38:0], r >= {1'b0, div_d[k]}};
            div_rem[k] <= (r >= {1'b0, div_d[k]}) ? 40'(r - {1'b0, div_d[k]}) : r[39:0];
            q[k] = $signed({div_q[k][38:0], r >= {1'b0, div_d[k]}});
            q[k] = div_z[k] ? 40'sd0 : div_neg[k] ? -q[k] : q[k];
        end
        div_n <= div_n - 6'd1;
        if (div_n == 6'd1) begin
            slope13 <= q[0]; slope12 <= q[1]; slope23 <= q[2];
            pk <= 2'd0; ts <= T_ROW0;
        end
    end
    T_ROW0: begin
        // the first row's parameters: start + (y - ay) * dpdy (the shared multiplier, added above);
        // the edges' first x
        if (pk == 2'd0) begin
            // y - vertex y, both signed (a first row at 0 under a vertex just above the top)
            ep[0] <= (17'($signed({y_cur, 4'h8})) - 17'(t1y)) * slope13;
            ep[1] <= (17'($signed({y_cur, 4'h8})) - 17'(t1y)) * slope12;
            ep[2] <= (17'($signed({y_cur, 4'h8})) - 17'(t2y)) * slope23;
        end
        if (pk == 2'd1) begin
            x13 <= 44'(($signed({t1x, 20'h0}) + ep[0]) >>> 4);
            x12 <= 44'(($signed({t1x, 20'h0}) + ep[1]) >>> 4);
            x23 <= 44'(($signed({t2x, 20'h0}) + ep[2]) >>> 4);
        end
        pk <= pk + 2'd1;
        if (pk == 2'd3) ts <= T_LINE;
    end
    T_LINE: begin
        if (y_cur >= y_end) ts <= T_DRAIN;
        else begin
            ea <= edge_round(x13);
            // signed: a middle vertex above the top (t2y < 0) puts every visible row on the 2-3 edge
            eb <= edge_round(($signed({y_cur, 4'h8}) < t2y) ? x12 : x23);
            sy_l <= yflip ? 10'(yorg - 10'(y_cur)) : 10'(y_cur);
            ts <= T_CLIP;
        end
    end
    T_CLIP: begin
        logic signed [11:0] a, b;
        logic [9:0] sy;
        a = ea; b = eb;
        if (a > b) {a, b} = {b, a};
        sy = sy_l;
        if (fbzMode[0]) begin
            if (a < $signed({2'b0, clip_l})) a = $signed({2'b0, clip_l});
            if (b > $signed({2'b0, clip_r})) b = $signed({2'b0, clip_r});
        end
        if (a < 0) a = 0;
        if (b > 12'sd512) b = 12'sd512;
        // the empty test is T_SPAN's first clock
        cx0 <= a; cx1 <= b;
        row_skip <= (fbzMode[0] && (sy < clip_t || sy >= clip_b)) || y_cur < 0;
`ifndef SYNTHESIS
        if (!((fbzMode[0] && (sy < clip_t || sy >= clip_b)) || y_cur < 0) && sy >= 10'd384 && a < b)
            $display("vraster: span at row %0d (y %0d, yorg %0d, flip %0d, clip %0d %0d-%0d)", sy, y_cur, yorg, yflip,
                     fbzMode[0], clip_t, clip_b);
`endif
        sx0 <= 10'(a); sx1 <= 10'(b);
        s_scry <= sy;
        pk <= 2'd0;
        ts <= T_SPAN;
    end
    T_SPAN: if (!span_hold) begin
        // the span start's parameters: the row's + (x0 - ax) * dpdx; an empty row leaves its
        // first product unused. After the fourth the span is pending (e_*) and the loop goes on;
        // a set holds 64 beats, so a longer span goes as its first 64 and the rest from T_SPAN again
        pk <= pk + 2'd1;
        if (pk == 2'd0 && (cx0 >= cx1 || row_skip)) ts <= T_NEXT;
        else if (pk == 2'd3) begin
            logic [9:0] xb;
            xb = {sx0[9:2] + 8'd64, 2'b00};
            e_v <= 1'b1; e_x0 <= sx0; e_sy <= s_scry;
            if (sx1 > xb) begin
                e_x1 <= xb; e_last <= 1'b0;
                sx0 <= xb; cx0 <= $signed({2'b0, xb});
            end else begin
                e_x1 <= sx1; e_last <= 1'b1;
                ts <= T_NEXT;
            end
        end
    end
    T_NEXT: begin
        // an emitted row's parameters step at its emit; an empty row's here
        y_cur <= y_cur + 12'sd1;
        if (!e_v) begin r_a <= r_a + dAdY; r_w <= r_w + dWdY; r_s <= r_s + dSdY; r_t <= r_t + dTdY; end
        x13 <= x13 + 44'(slope13); x12 <= x12 + 44'(slope12); x23 <= x23 + 44'(slope23);
        ts <= T_LINE;
    end
    T_DRAIN: if (!sd_v && !e_v) begin tri_done <= 1'b1; drain_pend <= 1'b1; ts <= T_IDLE; end
    default: ts <= T_IDLE;
    endcase
end

// ---------------------------------------------------------------- line-buffer sets

// A set: a span's colour and depth rows, a beat (four pixels) an entry from the span's first beat.
// Eight sets share four RAM pairs, set k in pair k[1:0]'s half k[2] of 64 entries (T_SPAN splits a
// longer span), so that short spans have twice the sets in flight. The halves share the RAMs'
// ports, a clock at a time: on port A q18's pixel goes first and the reader's beat for that RAM
// waits in hornet_ddr3 (readReady); on port B q16's read goes first and the writer reads again.
typedef enum logic [2:0] { S_FREE, S_READ, S_READY, S_PROC, S_DONE, S_WRITE } sstate_t;
localparam int NSET = 8;
function automatic logic [1:0] lb_ram(input logic [2:0] k);
    return k[1:0];
endfunction
function automatic logic lb_half(input logic [2:0] k);
    return k[2];
endfunction
sstate_t     st [NSET];
logic [9:0]  s_x0 [NSET], s_x1 [NSET];
logic [2:0]  rd_set, px_set, wr_set;                   // next set for each stage, in turn

// RAM ports: A writes (reader beats, pipeline pixels), B reads (pipeline, writer); colour and
// depth addressed apart, so that their streams run side by side. An entry is a 64-bit beat, two
// words (four pixels): the masters are wide (hornet_ddr3 WIDE)
logic [6:0]  lac_addr [4], laz_addr [4], lbc_addr [4], lbz_addr [4];
logic [7:0]  lca_be [4], lza_be [4];
logic [63:0] lca_d [4], lza_d [4];
logic [63:0] lcb_q [4], lzb_q [4];
genvar gs;
generate for (gs = 0; gs < 4; gs++) begin : g_set
    hornet_sdpram #(.AW(7), .DW(64)) u_c (.clk,
        .a_addr(lac_addr[gs]), .a_be(lca_be[gs]), .a_wdata(lca_d[gs]),
        .b_addr(lbc_addr[gs]), .b_rdata(lcb_q[gs]));
    hornet_sdpram #(.AW(7), .DW(64)) u_z (.clk,
        .a_addr(laz_addr[gs]), .a_be(lza_be[gs]), .a_wdata(lza_d[gs]),
        .b_addr(lbz_addr[gs]), .b_rdata(lzb_q[gs]));
end endgenerate

// A set's span parameters in block RAM: {row, A, W, S, T} for the pipeline and the colour and depth
// row addresses for the writer, each read at the index its stage will have next clock (px_nx,
// wr_nx), so that the data is the current set's; the reader keeps its span's rows in registers
localparam int PW = 240;                               // 10 + 32 + 3 * 64, to whole bytes
logic [PW-1:0] par_q;
logic [47:0] wrow_q;
logic [2:0]  px_nx, wr_nx;
logic [20:0] rd_crw, rd_zrw;
hornet_sdpram #(.AW(3), .DW(PW)) u_par (.clk, .a_addr(rd_set), .a_be({(PW / 8){sd_take}}),
    .a_wdata(PW'({sd_scry, sd_a, sd_w, sd_s, sd_t})), .b_addr(px_nx), .b_rdata(par_q));
hornet_sdpram #(.AW(3), .DW(48)) u_wrow (.clk, .a_addr(rd_set), .a_be({6{sd_take}}),
    .a_wdata(48'({sd_crow, sd_zrow})), .b_addr(wr_nx), .b_rdata(wrow_q));
always_ff @(posedge clk) if (sd_take) begin rd_crw <= sd_crow; rd_zrw <= sd_zrow; end
wire [20:0] wr_crw = wrow_q[41:21], wr_zrw = wrow_q[20:0];

// ---------------------------------------------------------------- span reader
//
// A span's depth and colour rows are requested together, and the next span's as soon as a set is
// free: the data comes back in request order on each port, set after set, while later requests
// wait in the memory.

typedef enum logic [0:0] { R_IDLE, R_REQ } rstate_t;
rstate_t     rs;
logic        rz_iss, rc_iss;                           // this span's requests are accepted
logic [2:0]  zd_set, cd_set;                           // the set each port's data is for
logic [8:0]  zd_n, cd_n;                               // the next word, from the span's first
logic [NSET-1:0] zdn, cdn;                             // a set's depth, colour rows are in

// a set's first and last word (comb arrays: Quartus 17 fails on a function reading s_x0[k][9:1])
logic [8:0]  sw0 [NSET], sw1 [NSET];
logic [8:0]  rw0 [NSET], rw1 [NSET];                   // ... widened to whole beats
always_comb
    for (int k = 0; k < NSET; k++) begin
        sw0[k] = s_x0[k][9:1]; sw1[k] = 9'((s_x1[k] - 10'd1) >> 1);
        rw0[k] = {sw0[k][8:1], 1'b0}; rw1[k] = {sw1[k][8:1], 1'b1};
    end

wire zd_v = io_memFbAuxRead_readDataValid;
wire cd_v = io_memFbColorRead_readDataValid;
wire zacc = rs == R_REQ && !rz_iss && io_memFbAuxRead_waitRequestn;
wire cacc = rs == R_REQ && !rc_iss && io_memFbColorRead_waitRequestn;

assign sd_take = rs == R_IDLE && sd_v && st[rd_set] == S_FREE;

always_ff @(posedge clk) begin
    if (reset) begin
        rs <= R_IDLE; rd_set <= 3'd0; zd_set <= 3'd0; cd_set <= 3'd0; zd_n <= 9'd0; cd_n <= 9'd0;
        zdn <= '0; cdn <= '0;
        for (int k = 0; k < NSET; k++) st[k] <= S_FREE;
    end else begin
        case (rs)
        R_IDLE: if (sd_take) begin
            s_x0[rd_set] <= sd_x0; s_x1[rd_set] <= sd_x1;
            st[rd_set] <= S_READ;
            rz_iss <= 1'b0; rc_iss <= 1'b0;
            rs <= R_REQ;
        end
        R_REQ: begin
            if (zacc) rz_iss <= 1'b1;
            if (cacc) rc_iss <= 1'b1;
            if ((rz_iss || zacc) && (rc_iss || cacc)) begin rd_set <= rd_set + 3'd1; rs <= R_IDLE; end
        end
        default: rs <= R_IDLE;
        endcase
        // a beat (two words) a clock
        if (zd_v) begin
            if (rw0[zd_set] + zd_n + 9'd1 == rw1[zd_set]) begin zdn[zd_set] <= 1'b1; zd_set <= zd_set + 3'd1; zd_n <= 9'd0; end
            else zd_n <= zd_n + 9'd2;
        end
        if (cd_v) begin
            if (rw0[cd_set] + cd_n + 9'd1 == rw1[cd_set]) begin cdn[cd_set] <= 1'b1; cd_set <= cd_set + 3'd1; cd_n <= 9'd0; end
            else cd_n <= cd_n + 9'd2;
        end
        for (int k = 0; k < NSET; k++)
            if (st[k] == S_READ && zdn[k] && cdn[k]) begin st[k] <= S_READY; zdn[k] <= 1'b0; cdn[k] <= 1'b0; end
        // the pipeline and the writer move the other sets on
        if (px_start) st[px_set] <= S_PROC;
        if (px_finish) st[px_fin_set] <= S_DONE;
        if (wr_start) st[wr_set] <= S_WRITE;
        if (wr_finish) st[wr_set] <= S_FREE;
    end
end

assign io_memFbAuxRead_read = rs == R_REQ && !rz_iss;
assign io_memFbAuxRead_write = 1'b0;
assign io_memFbAuxRead_address = FB_BASE + {11'h0, rd_zrw} + {21'h0, rw0[rd_set], 2'b00};
assign io_memFbAuxRead_burstCount = {2'b0, rw1[rd_set] - rw0[rd_set] + 9'd1};
assign io_memFbAuxRead_byteEnable = 4'hF;
assign io_memFbAuxRead_writeData = 32'h0;
assign io_memFbColorRead_read = rs == R_REQ && !rc_iss;
assign io_memFbColorRead_write = 1'b0;
assign io_memFbColorRead_address = FB_BASE + {11'h0, rd_crw} + {21'h0, rw0[rd_set], 2'b00};
assign io_memFbColorRead_burstCount = {2'b0, rw1[rd_set] - rw0[rd_set] + 9'd1};
assign io_memFbColorRead_byteEnable = 4'hF;
assign io_memFbColorRead_writeData = 32'h0;

// ---------------------------------------------------------------- pixel pipeline
//
//   q1  the pixel from the iterators, A clamped        q2  |W|, |S|, |T|, signs; W << 16's leading zeros
//   q3  |W|'s leading zeros; wfloat                     q4  mantissa m; its seed from the ROM
//   q5  m * seed                                        q6  the Newton correction
//   q7  the reciprocal y (2^62 / m >> 7, 24 bits)       q8  |S| y, |T| y
//   q9  S, T (24.8)                                     q10 texel coordinates
//   q11 tile slots, tags, bank addresses; the tag check (a miss stalls q1-q11 while the tile fills)
//   q12 texels from the banks                           q13 decoded
//   q14 bilinear, horizontal                            q15 bilinear, vertical; texture combine
//   q16 colour combine's selects, chroma key            q17 scale, add, clamp; alpha test
//   q18 depth test, blend (destination read at q16)
//   then the dither, into the line buffer. q12 onwards always advance: a stall leaves a bubble.
//
// The reciprocal: |W| normalised to a 32-bit mantissa m (top bit set); m's 10 bits below the top
// address the seed ROM (2^62 / m to about 11 bits, vraster_recip.hex); one Newton step takes it to
// about 22 bits; s32(i * 256 / W) = (|i| >> 8) y >> (71 - lz) with the signs (MAME: doubles;
// docs/HACKS.md).

localparam int TCB = 5;                                // texture cache slot bits a coordinate
localparam int TSW = 2 * TCB;

logic        stall;                                    // a cache fill is under way
logic        px_run;                                   // the iterators are issuing a span
logic [2:0]  p0_set;
logic [9:0]  p0_x, p0_sy;
logic signed [31:0] p0_a;
logic signed [63:0] p0_w, p0_s, p0_t;
logic        px_start, px_finish;
logic [2:0]  px_fin_set;

typedef struct packed {
    logic        v, last;
    logic [2:0]  set;
    logic [5:0]  o;                                    // the line-buffer entry: beat from the set's first
    logic [9:0]  x, sy;
    logic [7:0]  ia;                                   // iterated A, clamped
    logic [15:0] wf;                                   // wfloat, from q3
} pm_t;
pm_t m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12, m13, m14, m15, m16, m17, m18;

assign px_start = !px_run && st[px_set] == S_READY && !stall;
assign px_nx = (!stall && px_run && p0_x + 10'd1 == s_x1[p0_set]) ? px_set + 3'd1 : px_set;

always_ff @(posedge clk) begin
    if (reset) begin px_run <= 1'b0; px_set <= 3'd0; end
    else if (!stall) begin
        if (px_start) begin
            px_run <= 1'b1; p0_set <= px_set;
            p0_x <= s_x0[px_set];
            {p0_sy, p0_a, p0_w, p0_s, p0_t} <= par_q[233:0];
        end else if (px_run) begin
            p0_x <= p0_x + 10'd1;
            p0_a <= p0_a + (px_dadx <<< 8); p0_w <= p0_w + px_dwdx; p0_s <= p0_s + px_dsdx; p0_t <= p0_t + px_dtdx;
            if (p0_x + 10'd1 == s_x1[p0_set]) begin px_run <= 1'b0; px_set <= px_set + 3'd1; end
        end
    end
end

function automatic logic [6:0] clz64(input logic [63:0] v);      // 64 for zero
    logic [6:0] n;
    n = 7'd64;
    for (int i = 0; i < 64; i++) if (v[i]) n = 7'(63 - i);
    return n;
endfunction

// compute_wfloat from iterw's leading zeros
function automatic logic [15:0] wfloat_lz(input logic [6:0] lz, input logic signed [63:0] iterw);
    logic signed [7:0] e;
    logic [63:0] sh;
    e = $signed({1'b0, lz}) - 8'sd16;
    if (e < 0) return 16'h0000;
    if (e >= 16) return 16'hFFFF;
    sh = iterw >>> (35 - e);
    return (({e[3:0], 12'h0}) | (sh[15:0] ^ 16'h1FFF)) + 16'd1;
endfunction

typedef struct packed {
    logic [55:0] as, at;                               // |S| >> 8, |T| >> 8
    logic        nw, zw, ns, nt;                       // W < 0, W == 0, S < 0, T < 0
    logic [6:0]  lz;                                   // |W|'s leading zeros, from q3
} ca_t;

// the seed ROM (generated by scripts/gen_recip_rom.py)
logic [13:0] seed_rom [1024];
initial $readmemh(RECIP_HEX, seed_rom);

logic signed [63:0] w1, s1, t1, w2;
logic [63:0] aw2, aw3;
logic [6:0]  lzw2;
ca_t         c2, c3, c4, c5, c6, c7, c8;
logic [31:0] mn3, mn4;                                 // the mantissa: from q3's registers, at q4
logic [13:0] seed4, seed5, seed6;
logic [45:0] my5;
logic signed [34:0] cp6;
logic [23:0] y7;
logic [79:0] ps8, pt8;
logic signed [31:0] fs8, ft8;                          // the non-perspective S, T
logic signed [31:0] sq9, tq9;
logic        nw9;
tc_t         tc10, tc11, tc12, tc13, tc14;
logic [TSW-1:0] slot11 [4];
logic [26:0] tag11 [4];
logic [TSW:0] ra11 [4];

assign mn3 = 32'((aw3 << c3.lz) >> 32);
always_ff @(posedge clk) if (!stall) seed4 <= seed_rom[mn3[30:21]];

always_ff @(posedge clk) if (!stall) begin
    logic [63:0] as, at;
    logic signed [47:0] e;
    logic signed [19:0] er;
    logic [31:0] yy, qs, qt;
    logic [TSW:0] ra [4];
    // q1
    m1.v <= px_run; m1.last <= px_run && p0_x + 10'd1 == s_x1[p0_set];
    m1.set <= p0_set; m1.x <= p0_x; m1.sy <= p0_sy;
    m1.o <= 6'(p0_x[9:2] - s_x0[p0_set][9:2]);
    m1.ia <= pclamp8(12'(p0_a >>> 20)); m1.wf <= 16'h0;
    w1 <= p0_w; s1 <= p0_s; t1 <= p0_t;
    // q2
    m2 <= m1; w2 <= w1;
    aw2 <= w1[63] ? 64'(-w1) : 64'(w1);
    as = s1[63] ? 64'(-s1) : 64'(s1);
    at = t1[63] ? 64'(-t1) : 64'(t1);
    c2.as <= as[63:8]; c2.at <= at[63:8];
    c2.nw <= w1[63]; c2.zw <= w1 == 0; c2.ns <= s1[63]; c2.nt <= t1[63]; c2.lz <= 7'd0;
    lzw2 <= clz64(64'(w1 <<< 16));
    // q3
    m3 <= m2; m3.wf <= wfloat_lz(lzw2, w2 <<< 16);
    aw3 <= aw2;
    c3 <= c2; c3.lz <= clz64(aw2);
    // q4 (the seed: above)
    m4 <= m3; c4 <= c3; mn4 <= mn3;
    // q5
    m5 <= m4; c5 <= c4;
    my5 <= 46'(mn4) * 46'(seed4);                      // m y0 = my << 17 (y0 = seed << 17)
    seed5 <= seed4;
    // q6: (2^62 - m y0) >> 17 kept to its top 20 bits (>> 32); y0 e >> 62 = seed er >> 13
    m6 <= m5; c6 <= c5;
    e = $signed(48'h1 << 45) - $signed({2'b0, my5});
    er = 20'(e >>> 15);
    cp6 <= ($signed({1'b0, seed5}) * er) >>> 13;
    seed6 <= seed5;
    // q7
    m7 <= m6; c7 <= c6;
    yy = {1'b0, seed6, 17'h0} + 32'(cp6);
    y7 <= yy[30:7];
    // q8
    m8 <= m7; c8 <= c7;
    ps8 <= 80'(c7.as) * 80'(y7);
    pt8 <= 80'(c7.at) * 80'(y7);
    fs8 <= c7.ns ? -$signed(32'(c7.as >> 16)) : $signed(32'(c7.as >> 16));    // s32(S / 2^24)
    ft8 <= c7.nt ? -$signed(32'(c7.at >> 16)) : $signed(32'(c7.at >> 16));
    // q9
    m9 <= m8; nw9 <= c8.nw;
    qs = 32'(ps8 >> (71 - c8.lz)); qt = 32'(pt8 >> (71 - c8.lz));
    if (!textureMode[0]) begin sq9 <= fs8; tq9 <= ft8; end
    else if (c8.zw) begin sq9 <= 32'sh8000_0000; tq9 <= 32'sh8000_0000; end
    else begin
        sq9 <= (c8.ns ^ c8.nw) ? -$signed(qs) : $signed(qs);
        tq9 <= (c8.nt ^ c8.nw) ? -$signed(qt) : $signed(qt);
    end
    // q10
    m10 <= m9;
    tc10 <= tex_map(sq9, tq9, nw9);
    // q11
    m11 <= m10; tc11 <= tc10;
    for (int b = 0; b < 4; b++) ra[b] = '0;
    for (int k = 0; k < 4; k++) begin
        logic [7:0] s, t;
        s = tap_s(tc10, k); t = tap_t(tc10, k);
        slot11[k] <= tile_slot(s, t);
        tag11[k] <= tile_tag(s, t);
        ra[{t[0], s[0]}] = {tile_slot(s, t), t[1]};
    end
    for (int b = 0; b < 4; b++) ra11[b] <= ra[b];
end

// ---------------------------------------------------------------- texture cache
//
// 4x4-texel tiles in 1 << TSW slots (slot: the tile's low TCB s and t bits, so that neighbouring
// tiles never share one); four banks by (s & 1, t & 1), so that a bilinear footprint is one read
// of each. A tag is the tile's first texel address with the texture's width and texel size, in
// block RAM: a copy a tap, read at q11 (the slots of the pixel entering q11, or of the one held
// there while it stalls). Texture memory writes clear it, a slot a clock (tag_clr), and triangles
// wait for that. Frame 2150's tile fills by size: 64 slots 20,040, 256 9,687, 1024 2,487; at
// memlat 20, 256 slots take 925k clocks for the frame, 1024 703k. At 256 the board bench (one burst a port at a time) falls a frame behind at 2150.

// a bank entry: a tile-row's two texels of the bank's column parity, {s & 2, !(s & 2)}
logic [31:0] tbank0 [2 << TSW], tbank1 [2 << TSW], tbank2 [2 << TSW], tbank3 [2 << TSW];
logic [3:0]  tb_we;
logic [TSW:0] tb_wa [4];
logic [31:0] tb_wd [4];
logic [27:0] tagm0 [1 << TSW], tagm1 [1 << TSW], tagm2 [1 << TSW], tagm3 [1 << TSW];  // valid, tag
logic [27:0] tq11 [4];                                 // q11's taps' entries
logic        tg_we;
logic [TSW-1:0] tg_wa;
logic [27:0] tg_wd;
logic        tag_clr;                                  // clearing the tags
logic [TSW-1:0] clr_i;
logic [31:0] tb_q [4];

function automatic logic [26:0] tile_tag(input logic [7:0] s, input logic [7:0] t);
    return {texel_addr({s[7:2], 2'b00}, {t[7:2], 2'b00}), t_twb, t16};
endfunction
function automatic logic [TSW-1:0] tile_slot(input logic [7:0] s, input logic [7:0] t);
    return {t[TCB+1:2], s[TCB+1:2]};
endfunction
// texel k of a footprint: 0 (s0,t0), 1 (s1,t0), 2 (s0,t1), 3 (s1,t1)
function automatic logic [7:0] tap_s(input tc_t c, input int k);
    return (k & 1) ? c.s1 : c.s0;
endfunction
function automatic logic [7:0] tap_t(input tc_t c, input int k);
    return (k & 2) ? c.t1 : c.t0;
endfunction

logic [3:0]  miss;
always_comb
    for (int k = 0; k < 4; k++)
        miss[k] = m11.v && fbzColorPath[27] && (k == 0 || tc11.bil) &&
                  !(tq11[k][27] && tq11[k][26:0] == tag11[k]);

// the tag reads: q10's taps' slots as they enter q11, q11's while it holds
logic [TSW-1:0] tg_ra [4];
always_comb
    for (int k = 0; k < 4; k++) tg_ra[k] = stall ? slot11[k] : tile_slot(tap_s(tc10, k), tap_t(tc10, k));
always_ff @(posedge clk) begin
    if (tg_we) begin tagm0[tg_wa] <= tg_wd; tagm1[tg_wa] <= tg_wd; tagm2[tg_wa] <= tg_wd; tagm3[tg_wa] <= tg_wd; end
    tq11[0] <= tagm0[tg_ra[0]];
    tq11[1] <= tagm1[tg_ra[1]];
    tq11[2] <= tagm2[tg_ra[2]];
    tq11[3] <= tagm3[tg_ra[3]];
end

// fill: the first missing tile and up to TRUN-1 after it along s, to the texture row's end (spans
// run along s, and a row of a run is one burst: a latency for TRUN tiles). Four row reads are
// issued back to back and their data written as it comes, row after row, tile after tile: a 16-bit
// tile-row is a beat, written in its clock; an 8-bit row's beat is two tile-rows, the low word
// written as it comes and the high the clock after, with readReady low between (an odd row start
// leaves a word to skip, an odd end one at the end). A tile's tag is written with its last row;
// F2_WAIT lets the last tag reach the tag read.
// Only a missing tile stalls the pipeline: pixels that hit go on while a fill runs. So that none
// reads a slot being rewritten, a fill first clears the tags of its run, a tile a clock, and takes
// no data (readReady) until it has. After a fill for a miss, while the triangle has spans to come,
// the same run one tile row on (dTdY's sign) is fetched ahead: spans walk t a row at a time.
localparam int TRUN = 8;
typedef enum logic [2:0] { F2_IDLE, F2_REQ, F2_DATA, F2_WAIT } fillst_t;
fillst_t     fls;
assign       fill_idle = fls == F2_IDLE;
logic [7:0]  cf_s, cf_t;                               // the run's first texel
logic [3:0]  cf_kn;                                    // tiles in the run
logic [1:0]  cf_rq;                                    // the next row to request
logic [1:0]  cf_r;                                     // the next data's row
logic [2:0]  cf_k;                                     // ... its tile in the run (16-bit)
logic [3:0]  cf_wi;                                    // ... its word in the row's burst (8-bit)
logic [3:0]  cf_pad;                                   // an 8-bit row's burst starts a word early
logic [3:0]  cf_iv;                                    // the run's tags cleared so far
logic        cf_pf;                                    // the fill is a prefetch
logic        pf_v;                                     // a prefetch waits: the run (cf_s, cf_kn) at row pf_t
logic [7:0]  pf_t;
logic        fb_on;                                    // a tile-row is written to the banks this clock
logic [2:0]  fb_k;                                     // ... its tile in the run
logic        h_v;                                      // an 8-bit beat's high word, written now
logic [31:0] h_d;
logic        tex_clear;                                // a texture memory write
wire         fill_dv = (fls == F2_REQ || fls == F2_DATA) && io_memTex_readDataValid;
wire         k_last = {1'b0, cf_k} == cf_kn - 4'd1;
// an 8-bit row's words: the pad, the run's tiles, and the burst's last to make it even
wire [3:0]   w_end = 4'((5'(cf_pad[cf_r]) + 5'(cf_kn) + 5'd1) & 5'h1E);
wire         w_last = cf_wi + 4'd2 == w_end;
wire         fill_last = t16 ? fill_dv && cf_r == 2'd3 && k_last : h_v && cf_r == 2'd3 && w_last;
wire         iv_done = cf_iv == cf_kn;
wire         iv_we = (fls == F2_REQ || fls == F2_DATA) && !iv_done && !tag_clr;
assign io_memTex_readReady = iv_done && !(fill_dv && !t16);
// tile k of the run's first texel
function automatic logic [7:0] run_s(input logic [7:0] s, input logic [2:0] k);
    return s + {3'b0, k, 2'b00};
endfunction

assign stall = miss != 4'h0;
// s along the pipeline at the miss: the next pixel's (q10) against the missing one's
wire [7:0]   s_step = tap_s(tc10, 0) - tap_s(tc11, 0);
wire         s_falls = (m10.v && s_step != 8'h00) ? s_step[7] : px_dsdx[63];

always_ff @(posedge clk) begin
    if (tag_clr) begin
        clr_i <= clr_i + 1'd1;
        if (&clr_i) tag_clr <= 1'b0;
    end
    if (reset || (tex_clear && !tag_clr)) begin tag_clr <= 1'b1; clr_i <= '0; end
    h_v <= fill_dv && !t16;
    if (fill_dv) h_d <= io_memTex_readDataHi;
    if (iv_we) cf_iv <= cf_iv + 4'd1;
    if (drain_pend || ts == T_DRAIN || ts == T_IDLE) pf_v <= 1'b0;
    if (fill_dv && t16) begin
        if (k_last) begin cf_k <= 3'd0; cf_r <= cf_r + 2'd1; end
        else cf_k <= cf_k + 3'd1;
    end
    if (h_v) begin
        if (w_last) begin cf_wi <= 4'd0; cf_r <= cf_r + 2'd1; end
        else cf_wi <= cf_wi + 4'd2;
    end
    if (reset) fls <= F2_IDLE;
    else case (fls)
    F2_IDLE: if (miss != 4'h0) begin
        int k;
        logic [7:0] ms, mt;
        k = miss[0] ? 0 : miss[1] ? 1 : miss[2] ? 2 : 3;
        ms = tap_s(tc11, k); mt = tap_t(tc11, k);
        cf_t <= {mt[7:2], 2'b00};
        // the run: a texture row of TRUN tiles or fewer whole (its width 1 << t_twb texels);
        // otherwise TRUN tiles from the missing one, or to the row's end, or where s falls (the next
        // pixel's s below the missing one's, or with no next pixel or the same s, dSdX < 0), TRUN
        // tiles ending at it, or from the row's start
        begin
            logic [8:0] left;
            left = (9'd1 << t_twb) - {1'b0, ms[7:2], 2'b00};
            if (t_twb <= 4'($clog2(TRUN) + 2)) begin
                cf_s <= 8'h00;
                cf_kn <= (t_twb < 4'd2) ? 4'd1 : 4'((9'd1 << t_twb) >> 2);
            end else if (s_falls) begin
                cf_s <= (ms[7:2] >= 6'(TRUN - 1)) ? {ms[7:2] - 6'(TRUN - 1), 2'b00} : 8'h00;
                cf_kn <= 4'(TRUN);
            end else begin
                cf_s <= {ms[7:2], 2'b00};
                cf_kn <= (left[8:2] >= 7'(TRUN)) ? 4'(TRUN) : left[5:2];
            end
        end
        cf_rq <= 2'd0; cf_r <= 2'd0; cf_k <= 3'd0; cf_wi <= 4'd0; cf_iv <= 4'd0;
        cf_pf <= 1'b0; pf_v <= 1'b0;
        fls <= F2_REQ;
    end else if (pf_v && !drain_pend && ts != T_DRAIN && ts != T_IDLE) begin
        cf_t <= pf_t;
        cf_rq <= 2'd0; cf_r <= 2'd0; cf_k <= 3'd0; cf_wi <= 4'd0; cf_iv <= 4'd0;
        cf_pf <= 1'b1; pf_v <= 1'b0;
        fls <= F2_REQ;
    end
    F2_REQ: if (io_memTex_waitRequestn) begin
        cf_pad[cf_rq] <= !t16 && tf_a[2];
        cf_rq <= cf_rq + 2'd1;
        if (cf_rq == 2'd3) fls <= F2_DATA;
    end
    F2_DATA: if (fill_last) begin
        fls <= F2_WAIT;
        if (!cf_pf && !drain_pend && ts != T_DRAIN && ts != T_IDLE) begin
            pf_v <= 1'b1;
            pf_t <= dTdY[63] ? cf_t - 8'd4 : cf_t + 8'd4;
        end
    end
    F2_WAIT: fls <= F2_IDLE;
    default: fls <= F2_IDLE;
    endcase
end
`ifndef SYNTHESIS
always_ff @(posedge clk)
    if (fls == F2_REQ && t16 && tf_a[2]) $error("vraster: a 16-bit texture row at an odd word (%06X)", tf_a);
`endif

// the tag writes: the clear's, a fill's clearing of its run, or a tile's with its last row (row 3)
always_comb begin
    tg_we = tag_clr || iv_we || (fb_on && cf_r == 2'd3);
    tg_wa = tag_clr ? clr_i : tile_slot(run_s(cf_s, iv_we ? cf_iv[2:0] : fb_k), cf_t);
    tg_wd = (tag_clr || iv_we) ? 28'h0 : {1'b1, tile_tag(run_s(cf_s, fb_k), cf_t)};
end

// the fill's bank writes into banks (row parity, column parity), an entry (two texels) a bank: a
// 16-bit beat's tile-row, or an 8-bit word's (the beat's low word as it comes, its high the clock
// after; a word outside the run's tiles is the burst's padding)
always_comb begin
    logic [31:0] w;
    logic [3:0]  wi;
    logic [2:0]  k;
    logic        on;
    tb_we = 4'h0;
    for (int b = 0; b < 4; b++) begin tb_wa[b] = '0; tb_wd[b] = 32'h0; end
    if (t16) begin
        on = fill_dv; k = cf_k;
        tb_wd[{cf_r[0], 1'b0}] = {io_memTex_readDataHi[15:0], io_memTex_readData[15:0]};
        tb_wd[{cf_r[0], 1'b1}] = {io_memTex_readDataHi[31:16], io_memTex_readData[31:16]};
    end else begin
        w = h_v ? h_d : io_memTex_readData;
        wi = h_v ? cf_wi + 4'd1 : cf_wi;
        k = 3'(wi - 4'(cf_pad[cf_r]));
        on = (fill_dv || h_v) && wi >= 4'(cf_pad[cf_r]) && wi - 4'(cf_pad[cf_r]) < cf_kn;
        tb_wd[{cf_r[0], 1'b0}] = {8'h00, w[23:16], 8'h00, w[7:0]};
        tb_wd[{cf_r[0], 1'b1}] = {8'h00, w[31:24], 8'h00, w[15:8]};
    end
    if (on)
        for (int c = 0; c < 2; c++) begin
            tb_we[{cf_r[0], 1'(c)}] = 1'b1;
            tb_wa[{cf_r[0], 1'(c)}] = {tile_slot(run_s(cf_s, k), cf_t), cf_r[1]};
        end
    fb_on = on; fb_k = k;
end

always_ff @(posedge clk) begin
    if (tb_we[0]) tbank0[tb_wa[0]] <= tb_wd[0];
    if (tb_we[1]) tbank1[tb_wa[1]] <= tb_wd[1];
    if (tb_we[2]) tbank2[tb_wa[2]] <= tb_wd[2];
    if (tb_we[3]) tbank3[tb_wa[3]] <= tb_wd[3];
    if (!stall) begin
        tb_q[0] <= tbank0[ra11[0]];
        tb_q[1] <= tbank1[ra11[1]];
        tb_q[2] <= tbank2[ra11[2]];
        tb_q[3] <= tbank3[ra11[3]];
    end
end

// ---------------------------------------------------------------- q12 onwards and the result

logic [31:0] tx13 [4];
logic [31:0] tx14;
logic [51:0] h0_14, h1_14;
logic [31:0] tex15;
ps_t         ps16;
pc_t         pc17;
pb_t         pb18;
logic [15:0] dpix17, dz17;

always_comb
    for (int k = 0; k < 4; k++) begin
        lbc_addr[k] = (ws == W_RUN && lb_ram(wr_set) == 2'(k) && !wr_steal) ? {lb_half(wr_set), 6'((wc_next - ww0) >> 1)}
                                                                            : {lb_half(m16.set), m16.o};
        lbz_addr[k] = (ws == W_RUN && lb_ram(wr_set) == 2'(k) && !wr_steal) ? {lb_half(wr_set), 6'((wz_next - ww0) >> 1)}
                                                                            : {lb_half(m16.set), m16.o};
    end

always_comb begin
    logic [31:0] dc, dz;
    dc = m17.x[1] ? lcb_q[lb_ram(m17.set)][63:32] : lcb_q[lb_ram(m17.set)][31:0];
    dz = m17.x[1] ? lzb_q[lb_ram(m17.set)][63:32] : lzb_q[lb_ram(m17.set)][31:0];
    dpix17 = m17.x[0] ? dc[31:16] : dc[15:0];
    dz17 = m17.x[0] ? dz[31:16] : dz[15:0];
end

always_ff @(posedge clk) begin
    // q12
    if (!stall) begin m12 <= m11; tc12 <= tc11; end
    else m12.v <= 1'b0;
    // q13
    m13 <= m12; tc13 <= tc12;
    for (int k = 0; k < 4; k++) begin
        logic [7:0] s, t;
        s = tap_s(tc12, k); t = tap_t(tc12, k);
        tx13[k] <= texel_argb(textureMode[11:8], s[1] ? tb_q[{t[0], s[0]}][31:16] : tb_q[{t[0], s[0]}][15:0]);
    end
    // q14
    m14 <= m13; tc14 <= tc13;
    tx14 <= tx13[0];
    h0_14 <= bil_h(tx13[0], tx13[1], tc13.sf);
    h1_14 <= bil_h(tx13[2], tx13[3], tc13.sf);
    // q15
    m15 <= m14;
    tex15 <= fbzColorPath[27] ? tex_combine(tc14.bil ? bil_v(h0_14, h1_14, tc14.tf) : tx14) : 32'h0;
    // q16
    m16 <= m15;
    ps16 <= pix_sel(m15.ia, tex15);
    // q17
    m17 <= m16;
    pc17 <= pix_comb(ps16);
    // q18
    m18 <= m17;
    pb18 <= pix_blend(pc17, m17.wf, dpix17, dz17);
end

// line-buffer port A: the reader's words, or q18's pixel, dithered
logic [15:0] px_color;
assign px_color = dither565(fbzMode, m18.sy[1:0], m18.x[1:0], pb18.r, pb18.g, pb18.b);
always_comb
    for (int k = 0; k < 4; k++) begin
        lac_addr[k] = 7'h0; laz_addr[k] = 7'h0;
        lca_be[k] = 8'h0; lza_be[k] = 8'h0; lca_d[k] = 64'h0; lza_d[k] = 64'h0;
        if (m18.v && lb_ram(m18.set) == 2'(k) && pb18.ok) begin
            lac_addr[k] = {lb_half(m18.set), m18.o}; laz_addr[k] = {lb_half(m18.set), m18.o};
            lca_d[k] = {4{px_color}}; lza_d[k] = {4{pb18.depth}};
            lca_be[k] = 8'b11 << {m18.x[1:0], 1'b0};
            lza_be[k] = 8'b11 << {m18.x[1:0], 1'b0};
        end
        if (zd_v && lb_ram(zd_set) == 2'(k)) begin
            laz_addr[k] = {lb_half(zd_set), 6'(zd_n >> 1)};
            lza_d[k] = {io_memFbAuxRead_readDataHi, io_memFbAuxRead_readData}; lza_be[k] = 8'hFF;
        end
        if (cd_v && lb_ram(cd_set) == 2'(k)) begin
            lac_addr[k] = {lb_half(cd_set), 6'(cd_n >> 1)};
            lca_d[k] = {io_memFbColorRead_readDataHi, io_memFbColorRead_readData}; lca_be[k] = 8'hFF;
        end
    end

// a beat may come next clock unless q17's pixel will be written (q18) to the RAM it may be for
assign io_memFbColorRead_readReady = !(m17.v && (lb_ram(m17.set) == lb_ram(cd_set) || lb_ram(m17.set) == lb_ram(cd_set + 3'd1)));
assign io_memFbAuxRead_readReady = !(m17.v && (lb_ram(m17.set) == lb_ram(zd_set) || lb_ram(m17.set) == lb_ram(zd_set + 3'd1)));

assign px_finish = m18.v && m18.last;
assign px_fin_set = m18.set;

// ---------------------------------------------------------------- span writer
//
// The set's colour and depth rows back to memory, side by side, a beat (two words) a clock each,
// from an even word to an odd one, the pixels outside the span with their byte enables off. A
// stream's next beat is read from the line buffer as its current one is taken.

typedef enum logic [0:0] { W_IDLE, W_RUN } wstate_t;
wstate_t     ws;
logic        wr_start, wr_finish;
logic [2:0]  wr_fin_set;
logic [8:0]  ww0, ww1;
logic [8:0]  wc_a, wz_a, wc_next, wz_next;             // the word each stream presents; read next
logic        wc_v, wz_v;                               // the line buffer's output holds it
logic        wc_on, wz_on;                             // the stream has words left
wire         wr_steal = m16.v && lb_ram(m16.set) == lb_ram(wr_set);   // q16 reads the writer's RAM
wire         wc_acc = ws == W_RUN && wc_on && wc_v && io_memFbColorWrite_waitRequestn;
wire         wz_acc = ws == W_RUN && wz_on && wz_v && io_memFbAuxWrite_waitRequestn;

assign wr_start = ws == W_IDLE && st[wr_set] == S_DONE;
assign wr_nx = (ws == W_IDLE ? wr_start && !fbzMode[9] && !(fbzMode[10] && aux_ok) : ws == W_RUN && wr_finish)
               ? wr_set + 3'd1 : wr_set;
assign wr_fin_set = wr_set;
assign wc_next = wc_acc ? wc_a + 9'd2 : wc_a;
assign wz_next = wz_acc ? wz_a + 9'd2 : wz_a;
assign wr_finish = (ws == W_RUN && !(wc_on && !(wc_acc && wc_a + 9'd1 == ww1)) && !(wz_on && !(wz_acc && wz_a + 9'd1 == ww1))) ||
                   (wr_start && !fbzMode[9] && !(fbzMode[10] && aux_ok));

always_ff @(posedge clk) begin
    if (reset) begin ws <= W_IDLE; wr_set <= 3'd0; end
    else case (ws)
    W_IDLE: if (wr_start) begin
        ww0 <= rw0[wr_set]; ww1 <= rw1[wr_set];
        wc_a <= rw0[wr_set]; wz_a <= rw0[wr_set];
        wc_v <= 1'b0; wz_v <= 1'b0;
        wc_on <= fbzMode[9]; wz_on <= fbzMode[10] && aux_ok;
        if (fbzMode[9] || (fbzMode[10] && aux_ok)) ws <= W_RUN;
        else wr_set <= wr_set + 3'd1;                   // nothing to write
    end
    W_RUN: begin
        wc_v <= !wr_steal; wz_v <= !wr_steal;           // q16 took the read: read it again
        wc_a <= wc_next; wz_a <= wz_next;
        if (wc_acc && wc_a + 9'd1 == ww1) wc_on <= 1'b0;
        if (wz_acc && wz_a + 9'd1 == ww1) wz_on <= 1'b0;
        if (wr_finish) begin ws <= W_IDLE; wr_set <= wr_set + 3'd1; end
    end
    default: ws <= W_IDLE;
    endcase
end

// a word's byte enables: its two pixels inside [x0, x1)
function automatic logic [3:0] pix_be(input logic [8:0] w, input logic [9:0] x0, input logic [9:0] x1);
    return {{2{{w, 1'b1} >= x0 && {w, 1'b1} < x1}}, {2{{w, 1'b0} >= x0 && {w, 1'b0} < x1}}};
endfunction

always_comb begin
    logic [9:0] x0, x1;
    x0 = s_x0[wr_set]; x1 = s_x1[wr_set];
    io_memFbColorWrite_read = 1'b0;
    io_memFbColorWrite_write = ws == W_RUN && wc_on && wc_v;
    io_memFbColorWrite_address = FB_BASE + {11'h0, wr_crw} + {21'h0, ww0, 2'b00};
    io_memFbColorWrite_burstCount = {2'b0, ww1 - ww0 + 9'd1};
    io_memFbColorWrite_byteEnable = pix_be(wc_a, x0, x1);
    io_memFbColorWrite_byteEnableHi = pix_be(wc_a + 9'd1, x0, x1);
    io_memFbColorWrite_writeData = lcb_q[lb_ram(wr_set)][31:0];
    io_memFbColorWrite_writeDataHi = lcb_q[lb_ram(wr_set)][63:32];
    io_memFbAuxWrite_read = 1'b0;
    io_memFbAuxWrite_write = ws == W_RUN && wz_on && wz_v;
    io_memFbAuxWrite_address = FB_BASE + {11'h0, wr_zrw} + {21'h0, ww0, 2'b00};
    io_memFbAuxWrite_burstCount = {2'b0, ww1 - ww0 + 9'd1};
    io_memFbAuxWrite_byteEnable = pix_be(wz_a, x0, x1);
    io_memFbAuxWrite_byteEnableHi = pix_be(wz_a + 9'd1, x0, x1);
    io_memFbAuxWrite_writeData = lzb_q[lb_ram(wr_set)][31:0];
    io_memFbAuxWrite_writeDataHi = lzb_q[lb_ram(wr_set)][63:32];
end

logic        sets_free;
always_comb begin
    sets_free = 1'b1;
    for (int k = 0; k < NSET; k++) if (st[k] != S_FREE) sets_free = 1'b0;
end
assign spans_idle = sets_free && rs == R_IDLE &&
                    !px_run &&
                    !m1.v && !m2.v && !m3.v && !m4.v && !m5.v && !m6.v && !m7.v && !m8.v && !m9.v &&
                    !m10.v && !m11.v && !m12.v && !m13.v && !m14.v && !m15.v && !m16.v && !m17.v && !m18.v;
