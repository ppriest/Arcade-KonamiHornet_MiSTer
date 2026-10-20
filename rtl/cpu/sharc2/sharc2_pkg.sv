// SPDX-License-Identifier: GPL-3.0-or-later
//
// SHARC v2: the compute field's decode and the one-clock units (fixed ALU, shifter) as pure
// functions. The arithmetic is v1's (rtl/cpu/sharc/sharc_core_ops.svh alu_fixed, shift_op,
// compute), which follows MAME's compute.hxx and sharcops.hxx; flags are returned as the bits
// to clear and the bits to set, applied in instruction order by the core.

package sharc2_pkg;

import sharc_fp_pkg::*;

localparam logic [31:0] SV = 32'h0000_0800, SZ = 32'h0000_1000, SS = 32'h0000_2000,
                        BTF = 32'h0004_0000;
localparam logic [31:0] AOS = 32'h0000_0004;
localparam logic [31:0] ALU_FLAGS = AZ | AN | AV | AC | AS | AI;
localparam logic [31:0] MUL_FLAGS = MN | MV | MU | MI;

// ------------------------------------------------------------------------------------------
// Compute field decode
// ------------------------------------------------------------------------------------------

// the slow unit's operations (sharc2_alu)
typedef enum logic [4:0] {
    MC_PASS, MC_NEG, MC_ABS, MC_SCALB, MC_LOGB, MC_RECIPS, MC_RSQRTS, MC_FIX, MC_FLOAT,
    MC_FIXBY, MC_FLOATBY, MC_COPYSIGN, MC_MIN, MC_MAX, MC_CLIP, MC_COMP, MC_FLOAT_MF, MC_FIX_MF
} mc_t;

typedef struct packed {
    logic        x;         // a result or flags in X (fixed ALU, shifter, MR moves, MR clear)
    logic        fadd;      // adder 0: FADD/FSUB and the add half of the dual forms
    logic        fsub1;     // adder 1: the subtract half of the dual forms
    logic        fmul;
    logic        imul;      // fixed multiply
    logic        mc;        // slow unit, two clocks
    mc_t         mc_op;
    logic        avg;       // FAVG, four clocks
    logic        dual;      // FADD_FSUB flag rules
    logic        absr;      // ABS(Fx +- Fy)
    logic        sub;       // adder 0 subtracts
    logic        needs_astat;   // reads ASTAT in X: carry-in, COMP history
    logic        w_flags;   // updates ASTAT/STKY in W
    logic [31:0] w_aclr;    // ASTAT bits the W part clears
    logic [3:0]  wm, wa, ws;    // W destinations: multiplier, adder/slow unit, adder 1
    logic        wm_en, wa_en, ws_en;
    logic [15:0] late;      // R written in W
    logic [15:0] rd;        // R read
} cinfo_t;

// operand slots: AX, AY (adder, ALU, shifter, slow unit), MX, MY (multipliers), E (Rn as a source)
function automatic logic [3:0] slot_ax(input logic [22:0] c);
    slot_ax = c[22] ? {2'b10, c[3:2]} : c[7:4];
endfunction
function automatic logic [3:0] slot_ay(input logic [22:0] c);
    slot_ay = c[22] ? {2'b11, c[1:0]} : c[3:0];
endfunction
function automatic logic [3:0] slot_mx(input logic [22:0] c);
    slot_mx = c[22] ? {2'b00, c[7:6]} : c[7:4];
endfunction
function automatic logic [3:0] slot_my(input logic [22:0] c);
    slot_my = c[22] ? {2'b01, c[5:4]} : c[3:0];
endfunction

function automatic logic [15:0] bit16(input logic [3:0] r);
    bit16 = 16'h1 << r;
endfunction

function automatic cinfo_t comp_info(input logic [22:0] c);
    cinfo_t o;
    logic [7:0] op;
    logic [1:0] cu;
    logic [3:0] rn, rx, ry;
    logic [5:0] mop;
    o = '0;
    o.mc_op = MC_PASS;
    op = c[19:12]; cu = c[21:20]; rn = c[11:8]; rx = c[7:4]; ry = c[3:0];
    mop = c[21:16];
    if (c == 0) return o;
    if (!c[22]) begin
        o.rd = bit16(rx) | bit16(ry);
        case (cu)
        2'd0:
            if (!op[7]) begin
                o.x = 1'b1;
                o.needs_astat = op == 8'h05 || op == 8'h25 || op == 8'h06 || op == 8'h26 || op == 8'h0a;
            end else begin
                o.w_flags = 1'b1;
                o.w_aclr = ALU_FLAGS;
                o.wa = rn; o.wa_en = 1'b1;
                if (op[7:4] == 4'hf) begin
                    o.fadd = 1'b1; o.fsub1 = 1'b1; o.dual = 1'b1;
                    o.ws = c[15:12]; o.ws_en = 1'b1;
                end else case (op)
                8'h81: o.fadd = 1'b1;
                8'h82: begin o.fadd = 1'b1; o.sub = 1'b1; end
                8'h89: o.avg = 1'b1;
                8'h8a: begin o.mc = 1'b1; o.mc_op = MC_COMP; o.wa_en = 1'b0; o.needs_astat = 1'b1;
                             o.w_aclr = ALU_FLAGS | 32'hFF00_0000; end
                8'h91: begin o.fadd = 1'b1; o.absr = 1'b1; end
                8'h92: begin o.fadd = 1'b1; o.sub = 1'b1; o.absr = 1'b1; end
                8'ha1: begin o.mc = 1'b1; o.mc_op = MC_PASS; end
                8'ha2: begin o.mc = 1'b1; o.mc_op = MC_NEG; end
                8'hb0: begin o.mc = 1'b1; o.mc_op = MC_ABS; end
                8'hbd: begin o.mc = 1'b1; o.mc_op = MC_SCALB; end
                8'hc1: begin o.mc = 1'b1; o.mc_op = MC_LOGB; end
                8'hc4: begin o.mc = 1'b1; o.mc_op = MC_RECIPS; end
                8'hc5: begin o.mc = 1'b1; o.mc_op = MC_RSQRTS; end
                8'hc9: begin o.mc = 1'b1; o.mc_op = MC_FIX; end
                8'hca: begin o.mc = 1'b1; o.mc_op = MC_FLOAT; end
                8'hd9: begin o.mc = 1'b1; o.mc_op = MC_FIXBY; end
                8'hda: begin o.mc = 1'b1; o.mc_op = MC_FLOATBY; end
                8'he0: begin o.mc = 1'b1; o.mc_op = MC_COPYSIGN; end
                8'he1: begin o.mc = 1'b1; o.mc_op = MC_MIN; end
                8'he2: begin o.mc = 1'b1; o.mc_op = MC_MAX; end
                8'he3: begin o.mc = 1'b1; o.mc_op = MC_CLIP; end
                default: o.wa_en = 1'b0;            // no result; the ALU flags are cleared
                endcase
            end
        2'd1:
            case (op)
            8'h14, 8'h16: o.x = 1'b1;
            8'h30: begin o.fmul = 1'b1; o.w_flags = 1'b1; o.w_aclr = MUL_FLAGS; o.wm = rn; o.wm_en = 1'b1; end
            8'h40, 8'h70, 8'hb0, 8'hb2: begin
                o.imul = 1'b1; o.w_flags = 1'b1; o.w_aclr = MUL_FLAGS; o.wm = rn; o.wm_en = 1'b1;
            end
            default: ;
            endcase
        2'd2: begin o.x = 1'b1; o.rd |= bit16(rn); end
        default: ;
        endcase
    end else begin
        case (mop)
        6'h00: begin o.x = 1'b1; o.rd = '0; end
        6'h01: begin o.x = 1'b1; o.rd = bit16(rn); end
        6'h04, 6'h05: begin
            o.x = 1'b1;                                 // Ra = Rxa +- Rya
            o.imul = 1'b1; o.wm = c[15:12]; o.wm_en = c[15:12] != c[11:8];  // Rm, unless Ra is the same
            o.w_flags = 1'b1; o.w_aclr = MUL_FLAGS;
            o.rd = bit16(slot_mx(c)) | bit16(slot_my(c)) | bit16(slot_ax(c)) | bit16(slot_ay(c));
            o.sub = mop == 6'h05;
        end
        default:
            if (mop[5:3] == 3'b011 || mop[5:4] == 2'b11) begin
                o.fmul = 1'b1; o.wm = c[15:12]; o.wm_en = 1'b1;
                o.wa = c[11:8]; o.wa_en = 1'b1;
                o.w_flags = 1'b1; o.w_aclr = MUL_FLAGS | ALU_FLAGS;
                o.rd = bit16(slot_mx(c)) | bit16(slot_my(c)) | bit16(slot_ax(c)) | bit16(slot_ay(c));
                if (mop[5:4] == 2'b11) begin
                    o.fadd = 1'b1; o.fsub1 = 1'b1; o.dual = 1'b1;
                    o.ws = c[19:16]; o.ws_en = 1'b1;
                end else case (mop[2:0])
                3'd0: o.fadd = 1'b1;
                3'd1: begin o.fadd = 1'b1; o.sub = 1'b1; end
                3'd2: begin o.mc = 1'b1; o.mc_op = MC_FLOAT_MF; end
                3'd3: begin o.mc = 1'b1; o.mc_op = MC_FIX_MF; end
                3'd4: o.avg = 1'b1;
                3'd5: begin o.mc = 1'b1; o.mc_op = MC_ABS; end
                3'd6: begin o.mc = 1'b1; o.mc_op = MC_MAX; end
                default: begin o.mc = 1'b1; o.mc_op = MC_MIN; end
                endcase
            end
        endcase
    end
    // the W results overwrite in the order the handler writes: Rm, Ra, Rs (compute.hxx)
    if (o.wm_en) o.late |= bit16(o.wm);
    if (o.wa_en) o.late |= bit16(o.wa);
    if (o.ws_en) o.late |= bit16(o.ws);
    return o;
endfunction

// ------------------------------------------------------------------------------------------
// Fixed-point ALU (v1 alu_fixed, the dual add/sub, and multifunction Ra = Rxa +- Rya)
// ------------------------------------------------------------------------------------------

typedef struct packed {
    logic        we0, we1;
    logic [3:0]  r0, r1;
    logic [31:0] d0, d1;
    logic [31:0] aclr, aset, sset;
} xres_t;

function automatic logic [31:0] saturate(input logic [31:0] r);
    saturate = {32{r[31]}} ^ 32'h8000_0000;
endfunction

function automatic xres_t alu_fixed(input logic [7:0] op, input logic [3:0] rn, input logic [31:0] x,
                                    input logic [31:0] y, input logic [31:0] astat, input logic sat);
    xres_t o;
    logic [31:0] r, c, a;
    logic set_r;
    o = '0;
    r = 32'h0;
    a = 32'h0;
    c = (astat & AC) ? 32'd1 : 32'd0;
    set_r = 1'b1;
    o.aclr = ALU_FLAGS | AF;
    case (op)
    // AC is the 33-bit sum's carry: MAME's r < x (add) and r <= x (subtract) with its two
    // exceptions (x + 0xFFFFFFFF + 1; x - 0xFFFFFFFF + 0 - 1) are exactly that
    8'h01, 8'h05, 8'h25, 8'h29: begin
        logic [31:0] yy;
        logic [32:0] s33;
        yy = (op == 8'h29) ? 32'd1 : (op == 8'h25) ? 32'd0 : y;
        s33 = {1'b0, x} + {1'b0, yy} + {32'h0, (op == 8'h05 || op == 8'h25) && c[0]};
        r = s33[31:0];
        if (~(x ^ yy) & (x ^ r) & 32'h8000_0000) begin a |= AV; o.sset |= AOS; end
        if (s33[32]) a |= AC;
        if (sat && (a & AV)) r = saturate(r);
    end
    8'h02, 8'h06, 8'h26, 8'h2a: begin
        logic [31:0] yy;
        logic [32:0] s33;
        yy = (op == 8'h2a) ? 32'd1 : (op == 8'h26) ? 32'd0 : y;
        s33 = {1'b0, x} + {1'b0, ~yy} + {32'h0, (op == 8'h06 || op == 8'h26) ? c[0] : 1'b1};
        r = s33[31:0];
        if ((x ^ yy) & (x ^ r) & 32'h8000_0000) begin a |= AV; o.sset |= AOS; end
        if (s33[32]) a |= AC;
        if (sat && (a & AV)) r = saturate(r);
    end
    8'h0a: begin                                         // COMP: AZ/AN and the history byte
        logic [31:0] acc;
        set_r = 1'b0;
        if (x == y) a |= AZ;
        else if ($signed(x) < $signed(y)) a |= AN;
        acc = (astat >> 1) & 32'h7F00_0000;
        if ((a & (AZ | AN)) == 0) acc |= 32'h8000_0000;
        o.aclr |= 32'hFF00_0000;
        a |= acc;
    end
    8'h21: r = x;
    8'h22: begin
        r = -x;
        if ((32'h0 ^ x) & (32'h0 ^ r) & 32'h8000_0000) begin a |= AV; o.sset |= AOS; end
        if (r <= 32'h0) a |= AC;
        if (sat && (a & AV)) r = saturate(r);
    end
    8'h30: begin
        r = x[31] ? -x : x;
        if (r[31]) begin a |= AV; o.sset |= AOS; if (sat) r = 32'h7FFF_FFFF; end
        if (x[31]) a |= AS;
    end
    8'h40: r = x & y;
    8'h41: r = x | y;
    8'h42: r = x ^ y;
    8'h43: r = ~x;
    8'h61: r = ($signed(x) < $signed(y)) ? x : y;
    8'h62: r = ($signed(x) < $signed(y)) ? y : x;
    8'h63: begin
        logic [31:0] ay;
        ay = y[31] ? -y : y;
        r = ($signed(x) < -$signed(ay)) ? -ay : ($signed(ay) < $signed(x)) ? ay : x;
    end
    default: set_r = 1'b0;
    endcase
    if (set_r) begin
        if (r[31]) a |= AN;
        if (r == 0) a |= AZ;
        o.we0 = 1'b1; o.r0 = rn; o.d0 = r;
    end
    o.aset = a;
    return o;
endfunction

// Rs = Rx - Ry, Ra = Rx + Ry (fixed, compute.hxx:1335-1368)
function automatic xres_t alu_dual(input logic [3:0] ra, input logic [3:0] rs, input logic [31:0] x,
                                   input logic [31:0] y, input logic sat);
    xres_t o;
    logic [31:0] ad, sb;
    logic avd, avs;
    logic [32:0] ad33, sb33;
    o = '0;
    ad33 = {1'b0, x} + {1'b0, y}; sb33 = {1'b0, x} + {1'b0, ~y} + 33'd1;   // carries: ad < x, sb <= x
    ad = ad33[31:0]; sb = sb33[31:0];
    avd = (~(x ^ y) & (x ^ ad) & 32'h8000_0000) != 0;
    avs = ((x ^ y) & (x ^ sb) & 32'h8000_0000) != 0;
    o.aclr = ALU_FLAGS | AF;
    if (avd || avs) begin o.aset |= AV; o.sset |= AOS; end
    if (ad33[32] || sb33[32]) o.aset |= AC;
    if (sat) begin
        if (avd) ad = saturate(ad);
        if (avs) sb = saturate(sb);
    end
    if (ad == 0 || sb == 0) o.aset |= AZ;
    if ((ad | sb) & 32'h8000_0000) o.aset |= AN;
    o.we0 = 1'b1; o.r0 = ra; o.d0 = ad;
    o.we1 = 1'b1; o.r1 = rs; o.d1 = sb;
    return o;
endfunction

// multifunction Ra = Rxa + Rya / Rxa - Rya, the ALU half of MRF-free SSFR (compute.hxx:1400-1430)
function automatic xres_t alu_mf(input logic [3:0] ra, input logic sub, input logic [31:0] x,
                                 input logic [31:0] y);
    xres_t o;
    logic [31:0] r;
    o = '0;
    r = sub ? x - y : x + y;
    o.aclr = ALU_FLAGS | AF;
    if (r[31]) o.aset |= AN;
    if (r == 0) o.aset |= AZ;
    if (!sub) begin
        if (~(x ^ y) & (x ^ r) & 32'h8000_0000) begin o.aset |= AV; o.sset |= AOS; end
        if (r < x) o.aset |= AC;
    end else begin
        if ((x ^ y) & (x ^ r) & 32'h8000_0000) begin o.aset |= AV; o.sset |= AOS; end
        if (r <= x) o.aset |= AC;
    end
    o.we0 = 1'b1; o.r0 = ra; o.d0 = r;
    return o;
endfunction

// ------------------------------------------------------------------------------------------
// Shifter (v1 shift_op: SHIFT_OPERATION_IMM and COMPUTE cu = 2)
// ------------------------------------------------------------------------------------------

// The shifter: every form as one left rotate (by k) of x, the bits kept (m), the bits filled with
// a sign bit (f, sg) and Rn ORed in; the masks and the sign bit are worked out beside the rotate.
// shifter_ref is MAME's form for form (compute.hxx), kept for sim/shifter_tb
function automatic xres_t shifter(input logic [5:0] sop, input logic [31:0] sval, input logic imm,
                                  input logic [3:0] rn, input logic [31:0] x, input logic [31:0] rnv);
    xres_t o;
    logic [31:0] r, a, rot, m, f, ones_r, mk, rs;
    logic signed [7:0] sh8;
    logic signed [31:0] sh, shx;
    logic [5:0]  bitn, len, l, n;
    logic [4:0]  k;
    logic        sg, wr, orn, zpre;
    o = '0;
    a = 32'h0;
    wr = 1'b1;
    sh8 = sval[7:0];
    sh = imm ? {{24{sh8[7]}}, sh8} : $signed(sval);
    bitn = sval[5:0]; len = sval[11:6];
    l = (len > 6'd32) ? 6'd32 : len;
    mk = (l >= 6'd32) ? 32'hFFFF_FFFF : ((32'h1 << l) - 32'h1);
    o.aclr = SZ | SV | SS;
    k = 5'd0; m = 32'h0; f = 32'h0; sg = 1'b0; orn = 1'b0; zpre = 1'b0;
    case (sop)
    6'h00, 6'h08: begin
        shx = (sop == 6'h08 && !imm) ? {{24{sh8[7]}}, sh8} : sh;
        k = shx[4:0];
        if (shx < 0) begin
            if (shx > -32) begin
                n = 6'(-shx);
                m = 32'hFFFF_FFFF >> n;
                if (sop == 6'h08 && !imm) begin f = ~m; sg = x[31]; end
            end
        end else begin
            if (shx < 32) m = 32'hFFFF_FFFF << shx[4:0];
            if (shx > 0) a |= SV;
        end
        orn = sop == 6'h08;
        zpre = sop == 6'h08 && imm;              // OR LSHIFT by an immediate: SZ before the OR
    end
    6'h01: begin
        if (sh < 0) begin
            n = (sh > -32) ? 6'(-sh) : 6'd31;
            k = 5'(6'd32 - n);
            m = 32'hFFFF_FFFF >> n; f = ~m; sg = x[31];
        end else begin
            k = sh[4:0];
            if (sh < 32) m = 32'hFFFF_FFFF << sh[4:0];
            if (sh > 0) a |= SV;
        end
    end
    6'h02: begin
        k = sh[4:0]; m = 32'hFFFF_FFFF;
        if (!imm && sh > 0) a |= SV;
    end
    6'h10, 6'h11, 6'h12, 6'h13, 6'h19: begin
        if (len != 0 && bitn < 32) begin
            ones_r = 32'hFFFF_FFFF >> bitn;
            case (sop)
            6'h10: begin k = 5'(6'd32 - bitn); m = mk & ones_r; f = mk & ~ones_r; sg = x[31]; end
            6'h12: begin
                k = 5'(6'd32 - bitn);
                if ({1'b0, bitn} + {1'b0, len} > 7'd32) m = ones_r;
                else begin
                    m = mk;
                    if (l < 6'd32) begin f = ~mk; sg = x[5'(bitn + l - 6'd1)]; end
                end
            end
            6'h13: begin
                k = bitn[4:0]; m = mk << bitn;
                if (l < 6'd32) begin f = ~mk << bitn; sg = x[5'(l - 6'd1)]; end
            end
            default: begin k = bitn[4:0]; m = mk << bitn; end      // 11, 19
            endcase
        end
        orn = sop == 6'h19;
        if ({1'b0, bitn} + {1'b0, len} > 7'd32) a |= SV;
    end
    default: ;
    endcase
    rot = (x << k) | (x >> (6'd32 - {1'b0, k}));
    rs = (rot & m) | (f & {32{sg}});
    r = orn ? rnv | rs : rs;
    case (sop)
    6'h00, 6'h08, 6'h01, 6'h02, 6'h10, 6'h11, 6'h12, 6'h13, 6'h19: if ((zpre ? rs : r) == 0) a |= SZ;
    6'h30, 6'h31, 6'h32: begin
        r = x;
        if (sval < 32) begin
            case (sop)
            6'h30: r = r | (32'h1 << sval[4:0]);
            6'h31: r = r & ~(32'h1 << sval[4:0]);
            default: r = r ^ (32'h1 << sval[4:0]);
            endcase
        end else a |= SV;
        if (r == 0) a |= SZ;
    end
    6'h33: begin
        wr = 1'b0;
        if (sval < 32) begin
            if ((x & (32'h1 << sval[4:0])) == 0) a |= SZ;
        end else a |= SZ | SV;
    end
    default: wr = 1'b0;
    endcase
    o.aset = a;
    o.we0 = wr; o.r0 = rn; o.d0 = r;
    return o;
endfunction

function automatic xres_t shifter_ref(input logic [5:0] sop, input logic [31:0] sval, input logic imm,
                                  input logic [3:0] rn, input logic [31:0] x, input logic [31:0] rnv);
    xres_t o;
    logic [31:0] r, a;
    logic signed [7:0] sh8;
    logic signed [31:0] sh;
    logic [5:0] bitn, len;
    logic wr;
    o = '0;
    a = 32'h0;
    r = 32'h0;
    wr = 1'b1;
    sh8 = sval[7:0];
    sh = imm ? {{24{sh8[7]}}, sh8} : $signed(sval);
    bitn = sval[5:0]; len = sval[11:6];
    o.aclr = SZ | SV | SS;
    case (sop)
    6'h00, 6'h08: begin
        logic signed [31:0] shx;
        shx = (sop == 6'h08 && !imm) ? {{24{sh8[7]}}, sh8} : sh;
        if (shx < 0) r = (shx > -32) ? ((sop == 6'h08 && !imm) ? 32'($signed(x) >>> (-shx)) : x >> (-shx)) : 32'h0;
        else begin
            r = (shx < 32) ? x << shx : 32'h0;
            if (shx > 0) a |= SV;
        end
        if (sop == 6'h08) begin
            if (imm) begin if (r == 0) a |= SZ; r = rnv | r; end
            else begin r = rnv | r; if (r == 0) a |= SZ; end
        end else if (r == 0) a |= SZ;
    end
    6'h01: begin
        if (sh < 0) r = 32'($signed(x) >>> ((sh > -32) ? -sh : 31));
        else begin
            r = (sh < 32) ? x << sh : 32'h0;
            if (sh > 0) a |= SV;
        end
        if (r == 0) a |= SZ;
    end
    6'h02: begin
        logic [4:0] n5;
        n5 = sh[4:0];
        r = (x << n5) | (x >> (6'd32 - {1'b0, n5}));
        if (n5 == 0) r = x;
        if (!imm && sh > 0) a |= SV;
        if (r == 0) a |= SZ;
    end
    6'h10, 6'h11, 6'h12, 6'h13, 6'h19: begin
        logic [31:0] mk;
        logic [5:0]  l;
        l = (len > 6'd32) ? 6'd32 : len;
        mk = (l >= 32) ? 32'hFFFF_FFFF : ((32'h1 << l) - 1);
        case (sop)
        6'h10: r = (len == 0 || bitn >= 32) ? 32'h0 : 32'($signed(x) >>> bitn) & mk;
        6'h11: r = (len == 0 || bitn >= 32) ? 32'h0 : (x & mk) << bitn;
        6'h12: begin
            if (len == 0 || bitn >= 32) r = 32'h0;
            else if (bitn + len > 32) r = x >> bitn;
            else begin
                logic [31:0] v;
                v = (x >> bitn) & mk;
                r = (l < 32 && v[l - 1]) ? (v | ~mk) : v;
            end
        end
        6'h13: begin
            logic [31:0] v;
            if (len == 0 || bitn >= 32) r = 32'h0;
            else begin
                v = x & mk;
                if (l < 32 && v[l - 1]) v = v | ~mk;
                r = v << bitn;
            end
        end
        default: r = rnv | ((len != 0 && bitn < 32) ? (x & mk) << bitn : 32'h0);
        endcase
        if (r == 0) a |= SZ;
        if ({1'b0, bitn} + {1'b0, len} > 7'd32) a |= SV;
    end
    6'h30, 6'h31, 6'h32: begin
        r = x;
        if (sval < 32) begin
            case (sop)
            6'h30: r = r | (32'h1 << sval[4:0]);
            6'h31: r = r & ~(32'h1 << sval[4:0]);
            default: r = r ^ (32'h1 << sval[4:0]);
            endcase
        end else a |= SV;
        if (r == 0) a |= SZ;
    end
    6'h33: begin
        wr = 1'b0;
        if (sval < 32) begin
            if ((x & (32'h1 << sval[4:0])) == 0) a |= SZ;
        end else a |= SZ | SV;
    end
    default: wr = 1'b0;
    endcase
    o.aset = a;
    o.we0 = wr; o.r0 = rn; o.d0 = r;
    return o;
endfunction

endpackage
