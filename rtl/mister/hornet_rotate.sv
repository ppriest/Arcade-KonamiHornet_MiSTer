// SPDX-License-Identifier: GPL-3.0-or-later
//
// HDMI rotation: the picture rotated 90 degrees into a DDR3 frame buffer that the framework's
// scaler shows (MISTER_FB). The buffer handling (three buffers, FB_VBL/FB_LL) and the addressing
// follow Sorgelig's screen_rotate_two.sv (GPL-2.0-or-later); the write path is this core's:
// RGB565, and four source lines go out as one 64-bit beat (four neighbouring pixels of the
// rotated row), so that the Voodoo's DDR3 port carries a command per four pixels, spread over the
// next four lines' time. A group still going out when the next completes is cut short and counted
// (`dropped`). The source height must be a multiple of 4 (Hornet: 384). No multiplies: row
// addresses are accumulated.

module hornet_rotate #(
    parameter logic [31:0] MEM_BASE = 32'h2400_0000        // three buffers, 1 MB apart
) (
    input  logic        clk,
    input  logic        ce,                                 // the pixel clock enable
    input  logic [7:0]  r, g, b,
    input  logic        vs, de,
    input  logic        enable,
    input  logic        ccw,

    output logic        FB_EN,
    output logic [4:0]  FB_FORMAT,
    output logic [11:0] FB_WIDTH, FB_HEIGHT,
    output logic [31:0] FB_BASE,
    output logic [13:0] FB_STRIDE,
    input  logic        FB_VBL, FB_LL,

    // a wide hornet_ddr3 write master: one beat a command
    output logic        m_write,
    output logic [31:0] m_addr,
    output logic [63:0] m_wdata,
    input  logic        m_waitn,
    output logic [15:0] dropped                            // groups cut short
);

// ------------------------------------------------------------------ frame geometry, buffers
logic [11:0] hsz = 12'd512, vsz = 12'd384;                  // the source's last frame
logic [11:0] hcnt, vcnt;
logic        vs_q, de_q;
logic [2:0]  en_q;
logic [22:0] bufsize;                                       // hsz * stride, accumulated
logic [22:0] acc;
wire  [13:0] stride = {1'b0, vsz, 1'b0};                    // bytes a rotated row (16 bpp)

always_ff @(posedge clk) if (ce) begin
    vs_q <= vs; de_q <= de;
    if (de) begin hcnt <= hcnt + 1'd1; acc <= acc + 23'(stride); end
    if (!de_q && de) begin hcnt <= 12'd1; acc <= 23'(stride); vcnt <= vcnt + 1'd1; end
    if (de_q && !de) begin hsz <= hcnt; bufsize <= acc; end
    if (!vs_q && vs) begin vsz <= vcnt; vcnt <= 12'd0; en_q <= {en_q[1:0], enable}; end
end

assign FB_EN     = en_q[2];
assign FB_FORMAT = 5'b00100;                                // 16 bpp, RGB565
assign FB_WIDTH  = vsz;
assign FB_HEIGHT = hsz;
assign FB_STRIDE = stride;

function automatic logic [1:0] buf_next(input logic [1:0] a, input logic [1:0] o);
    buf_next = 2'd1;
    if ((a == 2'd0 && o == 2'd1) || (a == 2'd1 && o == 2'd0)) buf_next = 2'd2;
    if ((a == 2'd1 && o == 2'd2) || (a == 2'd2 && o == 2'd1)) buf_next = 2'd0;
endfunction

logic [1:0] i_fb, o_fb;
logic       vbl_q, vsb_q;
always_ff @(posedge clk) begin
    vbl_q <= FB_VBL; vsb_q <= vs;
    if (FB_LL) begin
        if (!vbl_q && FB_VBL) o_fb <= {1'b0, ~i_fb[0]};
        if (!vsb_q && vs) i_fb <= {1'b0, ~i_fb[0]};
    end else begin
        if (!vbl_q && FB_VBL) o_fb <= buf_next(o_fb, i_fb);
        if (!vsb_q && vs) i_fb <= buf_next(i_fb, o_fb);
    end
end
assign FB_BASE = MEM_BASE + {10'h0, o_fb, 20'h0};

// ------------------------------------------------------------------ lines into groups of four
// CW:  source (x, y) -> rotated row x, column vsz-1-y; a group's beat at x * stride + (vsz-4-y0) * 2
// CCW: source (x, y) -> rotated row hsz-1-x, column y; its beat at (hsz-1-x) * stride + y0 * 2
// A group's four lines go into one bank of four line buffers while the other bank's group goes
// out (a beat per x, in the four lines' time). The scaler's 565 halfword has red in bits 4:0
// (sys/ascal.vhd shift_opix).
wire [15:0] pix = {b[7:3], g[7:2], r[7:3]};
logic [15:0] lb0 [1024], lb1 [1024], lb2 [1024], lb3 [1024];   // {bank, x}
logic [8:0]  x;
logic [1:0]  ly;                                            // the line within its group
logic        wb;                                            // the bank being written
logic [22:0] col;                                           // the group's first column (bytes)
logic        grp;                                           // a group is complete: send it

always_ff @(posedge clk) begin
    grp <= 1'b0;
    if (ce) begin
        if (de) begin
            case (ly)
            2'd0: lb0[{wb, x}] <= pix;
            2'd1: lb1[{wb, x}] <= pix;
            2'd2: lb2[{wb, x}] <= pix;
            2'd3: lb3[{wb, x}] <= pix;
            endcase
            x <= x + 1'd1;
        end
        if (de_q && !de) begin                              // a line's end
            x <= 9'd0;
            ly <= ly + 1'd1;
            if (ly == 2'd3) grp <= 1'b1;
        end
        if (!vs_q && vs) begin x <= 9'd0; ly <= 2'd0; wb <= 1'b0; end
    end
    if (grp) begin
        wb <= !wb;
        col <= ccw ? col + 23'd8 : col - 23'd8;
    end
    if (ce && !vs_q && vs) col <= ccw ? 23'd0 : 23'({vsz, 1'b0}) - 23'd8;
end

// ------------------------------------------------------------------ a group out, a beat per x
typedef enum logic [1:0] { D_IDLE, D_RD, D_DATA, D_OUT } dst_t;
dst_t        ds;
logic        db;                                            // the bank going out
logic [1:0]  dfb;                                           // ... into this buffer
logic [8:0]  dx;
logic [22:0] drow, dcol;
logic [15:0] q0, q1, q2, q3;
logic [63:0] beat;

always_ff @(posedge clk) begin
    q0 <= lb0[{db, dx}]; q1 <= lb1[{db, dx}]; q2 <= lb2[{db, dx}]; q3 <= lb3[{db, dx}];
    case (ds)
    D_RD:   ds <= D_DATA;                                   // the RAMs' address registered
    D_DATA: begin beat <= ccw ? {q3, q2, q1, q0} : {q0, q1, q2, q3}; ds <= D_OUT; end
    D_OUT:  if (m_waitn) begin
        dx <= dx + 1'd1;
        drow <= ccw ? drow - 23'(stride) : drow + 23'(stride);
        ds <= (dx == 9'(hsz - 1'd1)) ? D_IDLE : D_RD;
    end
    default: ;
    endcase
    // the next group is complete: start it (one still going out is cut short and counted)
    if (grp && FB_EN) begin
        if (ds != D_IDLE && dropped != 16'hFFFF) dropped <= dropped + 1'd1;
        db <= wb; dfb <= i_fb; dx <= 9'd0; dcol <= col;
        drow <= ccw ? bufsize - 23'(stride) : 23'd0;
        ds <= D_RD;
    end
end

assign m_write = ds == D_OUT;
assign m_addr  = MEM_BASE + {10'h0, dfb, drow[19:0] + dcol[19:0]};
assign m_wdata = beat;

endmodule
