// SPDX-License-Identifier: GPL-3.0-or-later
//
// The PPC's instruction fetches through a 1 KB two-way cache of 8-word lines, on port A (the
// PPC403GA has a 2 KB instruction cache; MAME does not model it, so neither its size nor its
// timing is the chip's). In game the PPC falls a frame behind at port A latency 10 without it
// (sim/board_tb +alat); on frame 7500's fetches this geometry misses 0.21% of instructions.
//
// The PPC has one fetch out at a time. A hit answers the clock after the request; a miss fills the
// line a word at a time through port A (the word, from the line's start, then the rest), then
// answers. The game runs from work RAM: a PPC store into a cached line drops the line, and a fill
// under way of that line is not kept. A request that arrives during pause waits in r_*.

module hornet_icache (
    input  logic        clk,
    input  logic        reset,
    input  logic        run,            // the PPC's clock enable: a request counts only then
    input  logic        pause,          // no lookup or fill starts

    // the PPC: port A word address (hornet_board ppc_port_a)
    input  logic        req,
    input  logic [22:0] addr,
    output logic        ack,
    output logic [31:0] rdata,

    // port A: a word request a pulse, answered by m_ack with m_rdata
    output logic        m_req,
    output logic [22:0] m_addr,
    input  logic        m_ack,
    input  logic [31:0] m_rdata,

    // PPC stores on port A, to drop the lines they fall in
    input  logic        st,
    input  logic [22:0] st_addr
);

// address: tag [22:7], set [6:3], word [2:0]
logic [15:0] tg0 [16], tg1 [16];
logic [15:0] v0, v1;
logic [15:0] lru;                       // the way to fill next in each set
logic [31:0] q0, q1;

// a request: from the PPC this clock, or held from a pause
logic        r_v;
logic [22:0] r_a;
wire         in_v = r_v || (req && run);
wire  [22:0] in_a = r_v ? r_a : addr;

typedef enum logic [1:0] { C_IDLE, C_LOOK, C_FILL, C_DONE } c_t;
c_t          cs;
logic [22:0] l_a;                       // the request being answered
logic        l_h0, l_h1;
logic [2:0]  f_k;                       // the fill's next word, from the line's start
logic        f_way, f_stale, f_wait;
logic [31:0] f_word;                    // the requested word, as it arrives

wire  [3:0]  in_set = in_a[6:3];
assign ack = (cs == C_LOOK && (l_h0 || l_h1)) || cs == C_DONE;
// the PPC's next request comes in the clock of the last one's answer, so it is taken then too
wire         take = in_v && !pause && (cs == C_IDLE || ack);
wire  [6:0]  rd_a = {in_set, in_a[2:0]};
wire  [3:0]  l_set = l_a[6:3];
// stores, registered (the store's address decode is long): a fetch from the line in the store's
// clock or the next may still hit the old words (HACKS.md)
logic        stq;
logic [22:0] stq_a;
always_ff @(posedge clk) begin stq <= st && !reset; stq_a <= st_addr; end
wire         st_hit0 = stq && v0[stq_a[6:3]] && tg0[stq_a[6:3]] == stq_a[22:7];
wire         st_hit1 = stq && v1[stq_a[6:3]] && tg1[stq_a[6:3]] == stq_a[22:7];

// the ways' words in block RAM: port A the fill's writes, port B the lookups
logic        f_we;
logic [6:0]  f_wa;
always_comb begin
    f_we = cs == C_FILL && m_ack;
    f_wa = {l_set, f_k};
end
hornet_dpram #(.AW(7), .DW(32), .WORD(1)) u_w0 (.clk,
    .a_addr(f_wa), .a_be({4{f_we && !f_way}}), .a_wdata(m_rdata), .a_rdata(),
    .b_addr(rd_a), .b_be(4'h0), .b_wdata(32'h0), .b_rdata(q0));
hornet_dpram #(.AW(7), .DW(32), .WORD(1)) u_w1 (.clk,
    .a_addr(f_wa), .a_be({4{f_we && f_way}}), .a_wdata(m_rdata), .a_rdata(),
    .b_addr(rd_a), .b_be(4'h0), .b_wdata(32'h0), .b_rdata(q1));

assign rdata = cs == C_DONE ? f_word : l_h1 ? q1 : q0;
assign m_addr = {l_a[22:3], f_k};

always_ff @(posedge clk) begin
    m_req <= 1'b0;
    if (req && run && !r_v && !take) begin r_v <= 1'b1; r_a <= addr; end
    if (take) begin
        r_v <= 1'b0;
        l_a <= in_a;
        l_h0 <= v0[in_set] && tg0[in_set] == in_a[22:7] && !(st_hit0 && stq_a[6:3] == in_set);
        l_h1 <= v1[in_set] && tg1[in_set] == in_a[22:7] && !(st_hit1 && stq_a[6:3] == in_set);
        cs <= C_LOOK;
    end else case (cs)
    C_LOOK:
        if (l_h0 || l_h1) begin
            lru[l_set] <= !l_h1;
            cs <= C_IDLE;
        end else if (!pause) begin
            f_way <= lru[l_set]; f_k <= 3'd0; f_stale <= 1'b0; f_wait <= 1'b1;
            m_req <= 1'b1;
            if (lru[l_set]) v1[l_set] <= 1'b0; else v0[l_set] <= 1'b0;
            cs <= C_FILL;
        end
    C_FILL: if (m_ack) begin
        if (f_k == l_a[2:0]) f_word <= m_rdata;
        f_k <= f_k + 3'd1;
        if (f_k == 3'd7) begin
            if (f_way) begin tg1[l_set] <= l_a[22:7]; v1[l_set] <= !f_stale; end
            else begin tg0[l_set] <= l_a[22:7]; v0[l_set] <= !f_stale; end
            lru[l_set] <= !f_way;
            cs <= C_DONE;
        end else m_req <= 1'b1;
    end
    C_DONE: cs <= C_IDLE;
    default: cs <= C_IDLE;
    endcase
    // stores: drop the lines; a fill of the line is not kept
    if (st_hit0) v0[stq_a[6:3]] <= 1'b0;
    if (st_hit1) v1[stq_a[6:3]] <= 1'b0;
    if (stq && (cs == C_FILL || cs == C_LOOK) && stq_a[22:3] == l_a[22:3]) f_stale <= 1'b1;
    if (reset) begin cs <= C_IDLE; v0 <= '0; v1 <= '0; lru <= '0; r_v <= 1'b0; m_req <= 1'b0; end
end

endmodule
