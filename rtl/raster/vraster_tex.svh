// SPDX-License-Identifier: GPL-3.0-or-later
//
// vraster's texture unit, TMU 0 only (MAME rasterizer_texture: recompute, fetch_texel,
// lookup_single_texel, combine_texture; voodoo.cpp internal_texture_w). One LOD level a texture
// (tLOD lodmin = lodmax in every value the game writes, docs/RASTER.md). Texels are read from
// texture memory over memTex a word at a time.

localparam logic [21:0] TEX_MASK = 22'h3FFFFF;          // 4 MB of TMU memory

// MAME palexpand
function automatic logic [7:0] pex(input int n, input logic [7:0] b);
    case (n)
    1: return b[0] ? 8'hFF : 8'h00;
    2: return {b[1:0], b[1:0], b[1:0], b[1:0]};
    3: return {b[2:0], b[2:0], b[2:1]};
    4: return {b[3:0], b[3:0]};
    5: return {b[4:0], b[4:2]};
    6: return {b[5:0], b[5:4]};
    default: return b;
    endcase
endfunction

// lookup_single_texel's decode: format, the texel's 16 bits (8-bit formats in the low byte); ARGB
function automatic logic [31:0] texel_argb(input logic [3:0] f, input logic [15:0] v);
    logic [7:0] lo;
    lo = v[7:0];
    case (f)
    4'd0:  return {8'hFF, pex(3, lo[7:5]), pex(3, lo[4:2]), pex(2, {6'h0, lo[1:0]})};
    4'd2:  return {lo, lo, lo, lo};
    4'd3:  return {8'hFF, lo, lo, lo};
    4'd4:  return {pex(4, {4'h0, lo[7:4]}), pex(4, {4'h0, lo[3:0]}), pex(4, {4'h0, lo[3:0]}), pex(4, {4'h0, lo[3:0]})};
    4'd8:  return {v[15:8], pex(3, lo[7:5]), pex(3, lo[4:2]), pex(2, {6'h0, lo[1:0]})};
    4'd10: return {8'hFF, pex(5, {3'h0, v[15:11]}), pex(6, {2'h0, v[10:5]}), pex(5, {3'h0, v[4:0]})};
    4'd11: return {pex(1, {7'h0, v[15]}), pex(5, {3'h0, v[14:10]}), pex(5, {3'h0, v[9:5]}), pex(5, {3'h0, v[4:0]})};
    4'd12: return {pex(4, {4'h0, v[15:12]}), pex(4, {4'h0, v[11:8]}), pex(4, {4'h0, v[7:4]}), pex(4, {4'h0, v[3:0]})};
    4'd13: return {v[15:8], lo, lo, lo};
    default: return 32'h0;                              // palette and NCC formats: unused
    endcase
endfunction

// the texture's shape (recompute): width and height masks at LOD 0
wire [7:0] tw_mask0 = tLOD[20] ? 8'hFF : 8'hFF >> tLOD[22:21];
wire [7:0] th_mask0 = tLOD[20] ? 8'hFF >> tLOD[22:21] : 8'hFF;
wire       t16 = textureMode[11];                       // format >= 8: two bytes a texel

function automatic logic [3:0] tw_bits(input logic [7:0] m);     // log2(m + 1)
    tw_bits = 4'd0;
    for (int i = 0; i < 8; i++) if (m[i]) tw_bits = 4'(i + 1);
endfunction

// The byte offset of each LOD (recompute: base << 3 plus the sizes of the LODs before it), one a
// clock after tLOD, texBaseAddr or the texel size change; the command processor waits for it
// (lod_busy). LODs past 8 share LOD 9's offset.
logic [21:0] lod_off [10];
logic [23:0] lod_key_q;
logic [3:0]  lod_i;
logic        lod_run, lod_busy;
logic [21:0] lod_acc;
wire  [23:0] lod_key = {texBaseAddr[19:0], tLOD[22:20], t16};
assign lod_busy = lod_key != lod_key_q || lod_run;

always_ff @(posedge clk) begin
    if (lod_key != lod_key_q) begin
        lod_key_q <= lod_key;
        lod_acc <= {texBaseAddr[18:0], 3'b000};
        lod_i <= 4'd0;
        lod_run <= 1'b1;
    end else if (lod_run) begin
        logic [16:0] sz;
        sz = 17'({1'b0, tw_mask0 >> lod_i} + 9'd1) * 17'({1'b0, th_mask0 >> lod_i} + 9'd1);
        if (lod_i >= 4'd3 && sz < 17'd4) sz = 17'd4;
        lod_off[lod_i] <= lod_acc & TEX_MASK;
        lod_acc <= lod_acc + (t16 ? 22'(sz) << 1 : 22'(sz));
        lod_i <= lod_i + 4'd1;
        if (lod_i == 4'd9) lod_run <= 1'b0;
    end
    if (reset) begin lod_key_q <= ~lod_key; lod_run <= 1'b0; end
end

function automatic logic [21:0] lod_at(input logic [3:0] l);
    return lod_off[(l > 4'd9) ? 4'd9 : l];
endfunction

// the texture's one level (lodmin = lodmax), registered
logic [3:0]  t_ilod, t_twb;                             // the level; log2 of its width
logic [7:0]  t_smax, t_tmax;
logic [21:0] t_base;
always_ff @(posedge clk) begin
    t_ilod <= tLOD[5:2];
    t_smax <= tw_mask0 >> tLOD[5:2];
    t_tmax <= th_mask0 >> tLOD[5:2];
    t_twb <= tw_bits(tw_mask0 >> tLOD[5:2]);
    t_base <= lod_at(tLOD[5:2]);
end

// a texel's byte address at (s, t) (lookup_single_texel)
function automatic logic [21:0] texel_addr(input logic [7:0] s, input logic [7:0] t);
    logic [15:0] idx;
    idx = ({8'h0, t} << t_twb) + {8'h0, s};
    return (t_base + (t16 ? {5'h0, idx, 1'b0} : {6'h0, idx})) & TEX_MASK;
endfunction

// texture write target (internal_texture_w, write_ptr)
function automatic logic [21:0] texwr_addr(input logic [21:0] off);
    logic [3:0] l;
    logic [7:0] tt, ts;
    logic [7:0] wm;
    logic [17:0] o;
    l = off[18:15];
    tt = off[14:7];
    ts = {off[6:0], 1'b0};
    wm = tw_mask0 >> l;
    o = ({10'h0, tt} << tw_bits(wm)) + {10'h0, ts};
    return (lod_at(l) + ((t16 ? {3'h0, o, 1'b0} : {4'h0, o}) & ~22'h3)) & TEX_MASK;
endfunction

// the four (or one) texel coordinates and the filter fractions
typedef struct packed {
    logic        bil;
    logic [7:0]  s0, s1, t0, t1;
    logic [3:0]  sf, tf;
} tc_t;

// S, T (24.8) to texel coordinates at the texture's one LOD (fetch_texel after the divide)
function automatic tc_t tex_map(input logic signed [31:0] s_in, input logic signed [31:0] t_in, input logic wneg);
    tc_t o;
    logic signed [31:0] s, t, s1, t1;
    s = s_in; t = t_in;
    if (textureMode[3] && wneg) begin s = 0; t = 0; end
    o = '0;
    o.bil = textureMode[2];                              // magnification filter: the LOD is lodmin
    if (!o.bil) begin
        s = s >>> (t_ilod + 8); t = t >>> (t_ilod + 8);
        if (textureMode[6]) s = (s < 0) ? 0 : (s > $signed({24'h0, t_smax})) ? $signed({24'h0, t_smax}) : s;
        if (textureMode[7]) t = (t < 0) ? 0 : (t > $signed({24'h0, t_tmax})) ? $signed({24'h0, t_tmax}) : t;
        o.s0 = s[7:0] & t_smax; o.t0 = t[7:0] & t_tmax;
        o.s1 = o.s0; o.t1 = o.t0;
    end else begin
        s = (s >>> t_ilod) - 32'sh80; t = (t >>> t_ilod) - 32'sh80;
        o.sf = s[7:4]; o.tf = t[7:4];                     // bilinear mask 0xF0 (Voodoo 1)
        s = s >>> 8; t = t >>> 8;
        s1 = s + 1; t1 = t + 1;
        if (textureMode[6]) begin
            if (s < 0) begin s = 0; s1 = 0; end
            else if (s >= $signed({24'h0, t_smax})) begin s = {24'h0, t_smax}; s1 = s; end
        end
        if (textureMode[7]) begin
            if (t < 0) begin t = 0; t1 = 0; end
            else if (t >= $signed({24'h0, t_tmax})) begin t = {24'h0, t_tmax}; t1 = t; end
        end
        o.s0 = s[7:0] & t_smax; o.s1 = s1[7:0] & t_smax;
        o.t0 = t[7:0] & t_tmax; o.t1 = t1[7:0] & t_tmax;
    end
    return o;
endfunction

// bilinear_filter_rgbaint (the generic form), in two pipeline steps. The Voodoo 1's fractions are
// 4 bits (mask 0xF0), so ((c00 (256-u) + c01 u)(256-v) + (c10 (256-u) + c11 u) v) >> 16 with
// u = 16 sf, v = 16 tf is exactly (h0 (16-tf) + h1 tf) >> 8 with h = c0 (16-sf) + c1 sf: 4-bit
// multiplies only. bil_h: one row's h, four 13-bit channels; bil_v: the result
function automatic logic [51:0] bil_h(input logic [31:0] c0, input logic [31:0] c1, input logic [3:0] sf);
    logic [51:0] h;
    logic [4:0] su;
    su = 5'd16 - {1'b0, sf};
    for (int k = 0; k < 4; k++)
        h[13*k +: 13] = 13'(c0[8*k +: 8]) * 13'(su) + 13'(c1[8*k +: 8]) * 13'(sf);
    return h;
endfunction
function automatic logic [31:0] bil_v(input logic [51:0] h0, input logic [51:0] h1, input logic [3:0] tf);
    logic [31:0] o;
    logic [4:0] tu;
    tu = 5'd16 - {1'b0, tf};
    for (int k = 0; k < 4; k++) begin
        logic [17:0] r;
        r = 18'(h0[13*k +: 13]) * 18'(tu) + 18'(h1[13*k +: 13]) * 18'(tf);
        o[8*k +: 8] = r[15:8];
    end
    return o;
endfunction

// combine_texture with one TMU: the other input is 0, so the result is the selected add
function automatic logic [31:0] tex_combine(input logic [31:0] tl);
    logic [7:0] a, rgb [3];
    for (int k = 0; k < 3; k++)
        case (textureMode[19:18])
        2'd1: rgb[k] = tl[8*k +: 8];
        2'd2: rgb[k] = tl[31:24];
        default: rgb[k] = 8'h00;
        endcase
    a = textureMode[28:27] != 2'd0 ? tl[31:24] : 8'h00;
    if (textureMode[20]) for (int k = 0; k < 3; k++) rgb[k] = ~rgb[k];
    if (textureMode[29]) a = ~a;
    return {a, rgb[2], rgb[1], rgb[0]};
endfunction
