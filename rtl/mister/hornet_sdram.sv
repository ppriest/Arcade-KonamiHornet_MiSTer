// SPDX-License-Identifier: GPL-3.0-or-later
//
// The board's SDRAM ports (hornet_board ports A, B, C) and the ROM download on the 128 MB module,
// through Sorgelig's controller (rtl/mister/sdram, three fixed-priority ports) at clk_mem: clk, or
// 2x clk from the same PLL (the core runs it at clk).
//
//   controller port 0  line fills, 8 words as two double reads: port C's cache, port B's read-ahead
//   controller port 1  port A's reads and writes, port B's writes
//   controller port 2  the download (load time)
//
// Byte addresses (27 bits):
//   0x0000000-0x1FFFFFF  port A, a_addr * 4: work RAM, program ROM, data ROM, character RAM (region
//                        4, 0x1000000, which port C reads)
//   0x2000000-0x37FFFFF  port B, 0x2000000 + b_addr * 4: RAM 0x500000, RAM 0x1400000, CG ROM (at
//                        0x2800000, as KonamiHornet.sv's download puts it)
// A 32-bit word is two halfwords, the high half at the lower address (big-endian, as the PPC and
// the ROM images), each halfword's high byte on DQ[15:8]. The download writes halfwords so.
//
// Port C (the video's character RAM reads, a tile row of four words at a time) is a 128-line
// direct-mapped cache of 8-word lines, which hold two rows; port B (the SHARC's RAM at 0x1400000, read in streams by its DMA: board_tb
// +bstat) a two-line read-ahead buffer, where an access to a line starts the next line's fill.
// Port A keeps its last granule (two words) for sequential fetches. Writes reach the SDRAM before
// they are acknowledged; a write drops the cached line it falls in, a fill under way of that line
// is not kept, and no fill of a line starts while a write to it waits (the fills' port has
// priority over the writes').
//
// Clocks: clk_mem is clk or 2x clk from the same PLL. The controller's inputs are clk registers held from
// a request until its acknowledge; its acknowledges and data are taken into clk registers on the
// same edge (dout is written on clk_mem edges up to the acknowledge's and held for at least the
// controller's seven-cycle lead to its next read data, longer than one clk).

module hornet_sdram (
    input  logic        clk,
    input  logic        clk_mem,
    input  logic        init,           // ~pll_locked: the chip's initialisation
    input  logic        reset,

    output logic [12:0] SDRAM_A,
    inout  wire  [15:0] SDRAM_DQ,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic  [1:0] SDRAM_BA,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_CLK,
    output logic        SDRAM_CKE,

    // hornet_board's ports: requests held until acknowledged, data with the acknowledge
    input  logic        a_req,
    input  logic        a_we,
    input  logic [22:0] a_addr,
    input  logic [3:0]  a_be,           // a_be[3] = bits 31:24
    input  logic [31:0] a_wdata,
    output logic        a_ack,
    output logic [31:0] a_rdata,

    input  logic        b_req,
    input  logic        b_we,
    input  logic [22:0] b_addr,
    input  logic [31:0] b_wdata,
    output logic        b_ack,
    output logic [31:0] b_rdata,

    input  logic        c_req,
    input  logic [18:0] c_addr,         // a row of four words: c_addr[1:0] is not used
    output logic        c_ack,
    output logic [127:0] c_rdata,       // word k of the row in bits 32k+31:32k

    // download: a halfword at a time (byte address bits 26:1), taken when d_ready
    input  logic        d_we,
    input  logic [25:0] d_addr,
    input  logic [15:0] d_din,
    output logic        d_ready
);

localparam logic [21:0] B_LINE0 = 22'h10_0000;          // 0x2000000 >> 5
localparam logic [21:0] C_LINE0 = 22'h08_0000;          // 0x1000000 >> 5
localparam logic [24:0] B_WORD0 = 25'h80_0000;          // 0x2000000 >> 2

// port B's request registered (the SHARC's bus decode is long); the copy of the clock after an
// acknowledge is dropped, as the board lowers its request then
logic        br_req, br_we;
logic [22:0] br_addr;
logic [31:0] br_wdata;
always_ff @(posedge clk) begin
    br_req <= b_req && !b_ack && !reset;
    br_we <= b_we; br_addr <= b_addr; br_wdata <= b_wdata;
end

// ------------------------------------------------------------------------------------------
// the controller
// ------------------------------------------------------------------------------------------

logic [25:0] m_addr0, m_addr1, m_addr2;                 // byte address bits 26:1
logic        m_req0, m_req1, m_req2;
logic        m_ack0, m_ack1, m_ack2;
logic        m_wrl1, m_wrh1;
logic [15:0] m_din1, m_din2;
logic [63:0] m_dout, m_doutb;

sdram u_sdram (
    .SDRAM_DQ, .SDRAM_A, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE,
    .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CLK, .SDRAM_CKE,
    .init, .clk(clk_mem),
    .addr0(m_addr0), .wrl0(1'b0), .wrh0(1'b0), .din0(16'h0), .dout0(m_dout), .req0(m_req0),
    .ack0(m_ack0), .dbl0(1'b1), .dout0b(m_doutb),
    .addr1(m_addr1), .wrl1(m_wrl1), .wrh1(m_wrh1), .din1(m_din1), .dout1(), .req1(m_req1),
    .ack1(m_ack1),
    .addr2(m_addr2), .wrl2(1'b1), .wrh2(1'b1), .din2(m_din2), .dout2(), .req2(m_req2),
    .ack2(m_ack2)
);

// acknowledges and data into clk; a port is idle when its acknowledge has caught up
logic        k_ack0, k_ack1, k_ack2;
logic [63:0] k_dout, k_doutb;
always_ff @(posedge clk) begin
    k_ack0 <= m_ack0; k_ack1 <= m_ack1; k_ack2 <= m_ack2;
    k_dout <= m_dout; k_doutb <= m_doutb;
end
wire p0_idle = k_ack0 == m_req0;
wire p1_idle = k_ack1 == m_req1;
wire p2_idle = k_ack2 == m_req2;

// word k of a granule: the high half first
function automatic logic [31:0] gw(input logic [63:0] g, input logic k);
    return k ? {g[47:32], g[63:48]} : {g[15:0], g[31:16]};
endfunction

// ------------------------------------------------------------------------------------------
// port 2: download
// ------------------------------------------------------------------------------------------

assign d_ready = p2_idle;
always_ff @(posedge clk) begin
    if (d_we && p2_idle) begin m_addr2 <= d_addr; m_din2 <= d_din; m_req2 <= !m_req2; end
    if (reset) m_req2 <= k_ack2;
end

// ------------------------------------------------------------------------------------------
// port 1: port A, and port B's writes, an operation at a time
// ------------------------------------------------------------------------------------------

typedef enum logic [2:0] { W_IDLE, W_A_RD, W_HI, W_LO, W_END } w_t;
w_t          ws;
logic        w_b;                       // the operation is port B's
logic [25:0] w_hw;                      // the word's high halfword
logic [31:0] w_d;
logic [3:0]  w_be;
logic        b_wack;                    // port B's write is done

logic        ag_v;                      // port A's last granule
logic [21:0] ag_a;                      // a_addr[22:1]
logic [63:0] ag_d;

wire  a_new = a_req && !a_ack;
wire  b_wnew = br_req && br_we && !b_ack && !b_wack;
wire  a_take_wr = ws == W_IDLE && a_new && a_we;
wire  b_take_wr = ws == W_IDLE && !a_new && b_wnew;
wire  w_busy = ws == W_HI || ws == W_LO || ws == W_END;
wire  [21:0] w_line = w_hw[25:4];       // byte bits 26:5

always_ff @(posedge clk) begin
    a_ack <= 1'b0;
    b_wack <= 1'b0;
    case (ws)
    W_IDLE:
        if (a_new && !a_we && ag_v && ag_a == a_addr[22:1]) begin
            a_ack <= 1'b1; a_rdata <= gw(ag_d, a_addr[0]);
        end else if (a_new && !a_we) begin
            m_addr1 <= {2'b00, a_addr[22:1], 2'b00};
            m_wrl1 <= 1'b0; m_wrh1 <= 1'b0;
            m_req1 <= !m_req1;
            ws <= W_A_RD;
        end else if (a_take_wr) begin
            w_b <= 1'b0; w_hw <= {2'b00, a_addr, 1'b0}; w_d <= a_wdata; w_be <= a_be;
            if (ag_a == a_addr[22:1]) ag_v <= 1'b0;
            ws <= W_HI;
        end else if (b_take_wr) begin
            w_b <= 1'b1; w_hw <= {B_WORD0 + 25'(br_addr), 1'b0}; w_d <= br_wdata; w_be <= 4'hF;
            ws <= W_HI;
        end
    W_A_RD: if (p1_idle) begin
        ag_v <= 1'b1; ag_a <= a_addr[22:1]; ag_d <= k_dout;
        a_ack <= 1'b1; a_rdata <= gw(k_dout, a_addr[0]);
        ws <= W_IDLE;
    end
    W_HI: if (p1_idle) begin
        if (w_be[3:2] != 2'b00) begin
            m_addr1 <= w_hw; m_din1 <= w_d[31:16]; m_wrh1 <= w_be[3]; m_wrl1 <= w_be[2];
            m_req1 <= !m_req1;
        end
        ws <= W_LO;
    end
    W_LO: if (p1_idle) begin
        if (w_be[1:0] != 2'b00) begin
            m_addr1 <= w_hw + 26'd1; m_din1 <= w_d[15:0]; m_wrh1 <= w_be[1]; m_wrl1 <= w_be[0];
            m_req1 <= !m_req1;
        end
        ws <= W_END;
    end
    W_END: if (p1_idle) begin
        if (w_b) b_wack <= 1'b1; else a_ack <= 1'b1;
        ws <= W_IDLE;
    end
    default: ws <= W_IDLE;
    endcase
    if (reset) begin ws <= W_IDLE; m_req1 <= k_ack1; ag_v <= 1'b0; a_ack <= 1'b0; b_wack <= 1'b0; end
end

// the lines the writes taken this clock fall in (port A's matter for character RAM only)
wire [21:0] a_wline = {2'b00, a_addr[22:3]};
wire [21:0] b_wline = B_LINE0 + {2'b00, br_addr[22:3]};
wire        a_cwr = a_take_wr && a_addr[22:20] == 3'd4;

// ------------------------------------------------------------------------------------------
// fills (controller port 0): a line as two double reads, the half holding the wanted word first
// ------------------------------------------------------------------------------------------

typedef enum logic [1:0] { FL_IDLE, FL_H0, FL_H1 } fl_t;
fl_t          fl;
logic         fl_c;                     // for port C (else port B's slot fl_slot)
logic         fl_slot;
logic [21:0]  fl_line;                  // byte bits 26:5
logic         fl_half;                  // the half read first
logic         fl_stale;                 // a write fell in the line during the fill
logic         fl_dv;                    // a half's data this clock (fl_dh, fl_data)
logic         fl_dh;
logic         fl_end;                   // ... and it is the second
wire  [127:0] fl_data = {gw(k_doutb, 1), gw(k_doutb, 0), gw(k_dout, 1), gw(k_dout, 0)};
wire          a_cwr_line = a_cwr && a_wline == fl_line;  // a character-RAM write into the line filled

logic         go_c, go_b, go_slot, go_half;
logic [21:0]  go_line;

always_ff @(posedge clk) begin
    fl_dv <= 1'b0; fl_end <= 1'b0;
    case (fl)
    FL_IDLE: if (go_c || go_b) begin
        fl_c <= go_c; fl_slot <= go_slot; fl_line <= go_line; fl_half <= go_half;
        fl_stale <= 1'b0;
        m_addr0 <= {go_line, go_half, 3'b000};
        m_req0 <= !m_req0;
        fl <= FL_H0;
    end
    FL_H0: if (p0_idle) begin
        fl_dv <= 1'b1; fl_dh <= fl_half;
        m_addr0 <= {fl_line, !fl_half, 3'b000};
        m_req0 <= !m_req0;
        fl <= FL_H1;
    end
    FL_H1: if (p0_idle) begin
        fl_dv <= 1'b1; fl_dh <= !fl_half; fl_end <= 1'b1;
        fl <= FL_IDLE;
    end
    default: fl <= FL_IDLE;
    endcase
    if (fl != FL_IDLE && ((a_cwr && fl_c && a_wline == fl_line) || (b_take_wr && !fl_c && b_wline == fl_line)))
        fl_stale <= 1'b1;
    if (reset) begin fl <= FL_IDLE; m_req0 <= k_ack0; end
end
// a fill's last half is written the clock after FL_H1 leaves; the stale flag still holds then
wire fl_keep = !fl_stale;

// ------------------------------------------------------------------------------------------
// port C: the character cache
// ------------------------------------------------------------------------------------------

logic [127:0] cd [256];                 // {index, half}: four words
logic [8:0]   ct [128];                 // tags
logic [127:0] c_valid;
logic [127:0] cd_q;
logic [8:0]   ct_q;
logic         cv_q;
logic [18:0]  cq_a;                     // the address cd_q and ct_q are for
logic         cq_v;                     // ... read for a request, after the last fill write
wire  [6:0]   c_idx = c_addr[9:3];
wire  [21:0]  c_line = C_LINE0 + {6'h00, c_addr[18:3]};
wire          c_look = cq_v && c_req && !c_ack && cq_a == c_addr;
wire          c_hit = c_look && cv_q && ct_q == c_addr[18:10];

always_ff @(posedge clk) begin
    cd_q <= cd[{c_idx, c_addr[2]}];
    ct_q <= ct[c_idx];
    cv_q <= c_valid[c_idx];
    cq_a <= c_addr;
    cq_v <= c_req && !c_ack && !(fl_dv && fl_c) && !a_cwr;
    c_ack <= 1'b0;
    if (c_hit) begin
        c_ack <= 1'b1;
        c_rdata <= cd_q;
    end
    // a miss is answered from its fill's first half, which holds its row, unless a write fell in
    // the line; the second half and the tag follow
    if (c_req && !c_ack && fl_dv && fl_c && !fl_end && !fl_stale && !a_cwr_line &&
        fl_line == c_line && fl_dh == c_addr[2]) begin
        c_ack <= 1'b1;
        c_rdata <= fl_data;
    end
    if (fl_dv && fl_c) begin
        cd[{fl_line[6:0], fl_dh}] <= fl_data;
        // the slot's old line is gone with its first half (a request answered early may look it up
        // before the second half and the tag arrive)
        if (!fl_end) c_valid[fl_line[6:0]] <= 1'b0;
        if (fl_end) begin ct[fl_line[6:0]] <= fl_line[15:7]; c_valid[fl_line[6:0]] <= fl_keep; end
    end
    if (a_cwr) c_valid[a_addr[9:3]] <= 1'b0;
    if (reset) begin c_valid <= '0; c_ack <= 1'b0; end
end
wire c_miss = c_look && !(cv_q && ct_q == c_addr[18:10]) && !(w_busy && !w_b && w_line == c_line) &&
              !(a_cwr && a_wline == c_line);

// ------------------------------------------------------------------------------------------
// port B: two lines of read-ahead
// ------------------------------------------------------------------------------------------

logic [19:0]  bt [2];                   // br_addr[22:3]
logic [1:0]   bv [2];                   // halves present
logic [1:0]   bal;                      // slots allocated
logic         b_mru;
logic         b_rack;
wire  [19:0]  b_line = br_addr[22:3];
wire          b_h0 = bal[0] && bt[0] == b_line;
wire          b_h1 = bal[1] && bt[1] == b_line;
wire          b_hit = b_h0 || b_h1;
wire          b_hs = b_h1;              // the slot holding it
wire          b_rnew = br_req && !br_we && !b_ack;
wire  [19:0]  b_nl = b_line + 20'd1;

// the lines' words in four MLAB lanes (word k of a half in lane k), at {slot, half}: a fill's half
// written in one clock, a word read without a clock
logic [31:0]  bq [4];
wire  [1:0]   bw_a = {fl_slot, fl_dh};
genvar gk;
generate for (gk = 0; gk < 4; gk++) begin : g_bl
    sharc2_lutram #(.AW(2), .DW(32)) u_bl (.clk, .we(fl_dv && !fl_c), .wa(bw_a), .wd(fl_data[32*gk +: 32]),
        .ra({b_hs, br_addr[2]}), .rd(bq[gk]));
end endgenerate

assign b_ack = b_rack || b_wack;
always_ff @(posedge clk) begin
    b_rack <= 1'b0;
    if (b_rnew && !b_rack && b_hit && bv[b_hs][br_addr[2]]) begin
        b_rack <= 1'b1;
        b_rdata <= bq[br_addr[1:0]];
        b_mru <= b_hs;
    end
    if (fl_dv && !fl_c) begin
        if (fl_keep) bv[fl_slot][fl_dh] <= 1'b1;
    end
    if (fl == FL_IDLE && go_b && !go_c) begin
        bal[go_slot] <= 1'b1; bt[go_slot] <= 20'(go_line - B_LINE0); bv[go_slot] <= 2'b00;
    end
    if (b_take_wr) for (int s = 0; s < 2; s++) if (bt[s] == b_line) bal[s] <= 1'b0;
    if (reset) begin bal <= 2'b00; b_rack <= 1'b0; end
end

// ------------------------------------------------------------------------------------------
// the fill engine's next line: port C's miss, then port B's miss, then the line after port B's
// ------------------------------------------------------------------------------------------

always_comb begin
    logic b_miss, b_next;
    b_miss = b_rnew && !b_rack && !b_hit && !(w_busy && w_b) && !b_wnew;
    b_next = b_rnew && !b_rack && b_hit && !(bal[!b_hs] && bt[!b_hs] == b_nl) && !(w_busy && w_b);
    go_c = c_miss;
    go_b = b_miss || b_next;
    go_line = go_c ? c_line : B_LINE0 + {2'b00, b_miss ? b_line : b_nl};
    go_half = go_c ? c_addr[2] : b_miss ? br_addr[2] : 1'b0;
    go_slot = b_miss ? !b_mru : !b_hs;
end

endmodule
