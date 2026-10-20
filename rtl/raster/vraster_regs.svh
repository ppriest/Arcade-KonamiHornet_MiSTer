// SPDX-License-Identifier: GPL-3.0-or-later
//
// vraster's registers: only those docs/RASTER.md lists as used, each stored once. Float
// registers are converted as MAME does (voodoo.cpp float_to_int32 / float_to_int64): vertices to
// x.4, the FBI's A to x.12, S/T/W to 32.32 (64 bits).

// MAME's alias map (voodoo.cpp:229): the remapped order puts each parameter's start, dX, dY together
function automatic logic [7:0] alias_reg(input logic [7:0] r);
    logic [4:0] i;
    logic [7:0] b;
    i = r[4:0];
    case (i)
    5'd0, 5'd1, 5'd2, 5'd3, 5'd4, 5'd5, 5'd6, 5'd7: b = {3'b0, i};
    default: begin
        logic [4:0] k, p;
        logic [1:0] w;
        k = i - 5'd8;                        // 0..23: parameter k/3, which of start/dX/dY k%3
        p = (k >= 5'd21) ? 5'd7 : (k >= 5'd18) ? 5'd6 : (k >= 5'd15) ? 5'd5 : (k >= 5'd12) ? 5'd4 :
            (k >= 5'd9) ? 5'd3 : (k >= 5'd6) ? 5'd2 : (k >= 5'd3) ? 5'd1 : 5'd0;
        w = 2'(k - (p << 1) - p);
        b = 8'h08 + {3'b0, p} + (w == 2'd1 ? 8'h08 : w == 2'd2 ? 8'h10 : 8'h00);
    end
    endcase
    return r[5] ? b + 8'h20 : b;
endfunction

// IEEE single to fixed point with `fb` fraction bits (MAME float_to_int64, float_to_int32), in two
// clocks: the magnitude (fmag64, fmag32: shifted, saturated), then the sign (fsgn)
function automatic logic [63:0] fmag64(input logic [31:0] d, input int fb);
    logic signed [12:0] e;
    logic [63:0] m;
    e = $signed({5'b0, d[30:23]}) - 13'sd150 + 13'(fb);
    m = {40'h0, 1'b1, d[22:0]};
    if (e < 0) m = (e > -13'sd64) ? m >> (-e) : 64'h0;
    else       m = (e < 13'sd64) ? m << e : 64'h7FFF_FFFF_FFFF_FFFF;
    return m;
endfunction
function automatic logic [31:0] fmag32(input logic [31:0] d, input int fb);
    logic signed [12:0] e;
    logic [31:0] m;
    e = $signed({5'b0, d[30:23]}) - 13'sd150 + 13'(fb);
    m = {8'h0, 1'b1, d[22:0]};
    if (e < 0) m = (e > -13'sd32) ? m >> (-e) : 32'h0;
    else       m = (e < 13'sd32) ? m << e : 32'h7FFF_FFFF;
    return m;
endfunction
function automatic logic signed [63:0] fsgn(input logic [31:0] d, input logic [63:0] m);
    return d[31] ? -$signed(m) : $signed(m);
endfunction

logic [31:0] fbiInit0, fbiInit1, fbiInit2, fbiInit3, fbiInit4;
logic [31:0] fbzColorPath, fogMode, alphaMode, fbzMode, clipLR, clipTB;
logic [31:0] color0, color1, zaColor, chromaKey;
logic [31:0] textureMode, tLOD, texBaseAddr;
logic signed [15:0] vAx, vAy, vBx, vBy, vCx, vCy;            // 12.4
logic signed [31:0] startA, dAdX, dAdY;                       // 12.12
logic signed [63:0] startS, dSdX, dSdY, startT, dTdX, dTdY;   // 32.32 (TMU)
logic signed [63:0] startW, dWdX, dWdY;                       // 32.32 (FBI and TMU alike here)
logic [31:0] tri_sign;                                       // the triangle command's data

// one register write; chip mask c (MAME chipmask_from_offset: 0 means all); the float data's
// magnitudes as x.4, x.12 and 32.32
task automatic reg_write(input logic [7:0] r, input logic [3:0] c, input logic [31:0] d,
                         input logic [31:0] m4, input logic [31:0] m12, input logic [63:0] m32);
    case (r)
    // fixed-point triangle registers (unused by the game, kept for the vertices)
    8'h02: vAx <= d[15:0];
    8'h03: vAy <= d[15:0];
    8'h04: vBx <= d[15:0];
    8'h05: vBy <= d[15:0];
    8'h06: vCx <= d[15:0];
    8'h07: vCy <= d[15:0];
    // float triangle registers
    8'h22: vAx <= 16'(fsgn(d, 64'(m4)));
    8'h23: vAy <= 16'(fsgn(d, 64'(m4)));
    8'h24: vBx <= 16'(fsgn(d, 64'(m4)));
    8'h25: vBy <= 16'(fsgn(d, 64'(m4)));
    8'h26: vCx <= 16'(fsgn(d, 64'(m4)));
    8'h27: vCy <= 16'(fsgn(d, 64'(m4)));
    8'h2c: startA <= 32'(fsgn(d, 64'(m12)));
    8'h34: dAdX <= 32'(fsgn(d, 64'(m12)));
    8'h3c: dAdY <= 32'(fsgn(d, 64'(m12)));
    8'h2d: startS <= fsgn(d, m32);
    8'h35: dSdX <= fsgn(d, m32);
    8'h3d: dSdY <= fsgn(d, m32);
    8'h2e: startT <= fsgn(d, m32);
    8'h36: dTdX <= fsgn(d, m32);
    8'h3e: dTdY <= fsgn(d, m32);
    8'h2f: startW <= fsgn(d, m32);
    8'h37: dWdX <= fsgn(d, m32);
    8'h3f: dWdY <= fsgn(d, m32);
    8'h20, 8'h40: tri_sign <= d;
    8'h41: fbzColorPath <= d;
    8'h42: fogMode <= d;
    8'h43: alphaMode <= d;
    8'h44: fbzMode <= d;
    8'h46: clipLR <= d;
    8'h47: clipTB <= d;
    8'h4c: zaColor <= d;
    8'h4d: chromaKey <= d;
    8'h51: color0 <= d;
    8'h52: color1 <= d;
    8'h80: fbiInit4 <= d;
    8'h84: fbiInit0 <= d;
    8'h85: fbiInit1 <= d;
    8'h86: fbiInit2 <= d;
    8'h87: fbiInit3 <= d;
    // TMU 0 (chip mask bit 1, or all)
    8'hc0: if (c == 4'h0 || c[1]) textureMode <= d;
    8'hc1: if (c == 4'h0 || c[1]) tLOD <= d;
    8'hc3: if (c == 4'h0 || c[1]) texBaseAddr <= d;
    default: ;
    endcase
endtask
