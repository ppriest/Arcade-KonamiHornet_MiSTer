// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/mister/hornet_sndbridge.sv through hornet_ddr3 (one wide master) to a DDR3 model with a
// read latency and a random BUSY. PPC writes go in as bursts of five (a command); the ring must
// hold each, in order, with its register, data and a rising microsecond stamp, the count and the
// state word must follow, and the magic and beat words must appear. A model server writes its
// word with a moving heartbeat, then stops: live must rise with the reply and fall again.
//
//     scripts/run_verilator.sh sndbridge_tb [+seed=N] [+busy=P]

`timescale 1ns/1ps

module tb_sndbridge;

logic clk = 0, reset = 1;
always #7.8125 clk = !clk;

localparam logic [31:0] SHM = 32'h3F20_0000;
logic        wr = 0;
logic [3:0]  wreg = 0;
logic [7:0]  wdata = 0;
logic [15:0] reply;
logic        live;

logic        b_read, b_write, b_waitn, b_rvalid;
logic [31:0] b_addr;
logic [10:0] b_burst;
logic [63:0] b_wdata, b_rdata;

hornet_sndbridge #(.SHM(SHM), .BEAT(20000), .POLL(256), .LIVE(40)) dut (
    .clk, .reset, .wr, .wreg, .wdata, .reply, .live,
    .m_read(b_read), .m_write(b_write), .m_addr(b_addr), .m_burst(b_burst), .m_wdata(b_wdata),
    .m_waitn(b_waitn), .m_rvalid(b_rvalid), .m_rdata(b_rdata)
);

logic        DDRAM_BUSY = 0, DDRAM_DOUT_READY = 0, DDRAM_RD, DDRAM_WE;
logic [7:0]  DDRAM_BURSTCNT, DDRAM_BE;
logic [28:0] DDRAM_ADDR;
logic [63:0] DDRAM_DOUT = 0, DDRAM_DIN;
logic [31:0] m_rdata, m_rdata_hi;
logic [1:0]  m_waitn, m_rvalid;
// two masters (the arbiter's selects need one bit): 0 idle, the bridge as 1
hornet_ddr3 #(.N(2), .WIDE(2'b10)) ddr3 (
    .clk, .reset, .drain(1'b0), .idle(),
    .m_read({b_read, 1'b0}), .m_write({b_write, 1'b0}), .m_addr({b_addr, 32'h0}), .m_burst({b_burst, 11'd0}),
    .m_be({4'hF, 4'h0}), .m_wdata({b_wdata[31:0], 32'h0}), .m_be_hi({4'hF, 4'h0}), .m_wdata_hi({b_wdata[63:32], 32'h0}),
    .m_waitn, .m_rvalid, .m_rready(2'b11), .m_rdata, .m_rdata_hi,
    .DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT, .DDRAM_DOUT_READY, .DDRAM_RD,
    .DDRAM_DIN, .DDRAM_BE, .DDRAM_WE, .dbg(), .dbg_cmd()
);
assign b_waitn = m_waitn[1];
assign b_rvalid = m_rvalid[1];
assign b_rdata = {m_rdata_hi, m_rdata};

int busy_pct = 20, seed = 1, errors = 0;
logic [63:0] mem [int];
int rq_n = 0; logic [28:0] rq_a; int rq_t = -1;
always @(posedge clk) begin
    DDRAM_DOUT_READY <= 0;
    if (rq_t == 0) begin DDRAM_DOUT <= mem.exists(rq_a) ? mem[rq_a] : 64'h0; DDRAM_DOUT_READY <= 1; end
    if (rq_t >= 0) rq_t--;
    if (!DDRAM_BUSY && DDRAM_WE) begin
        logic [63:0] v;
        v = mem.exists(DDRAM_ADDR) ? mem[DDRAM_ADDR] : 64'h0;
        for (int k = 0; k < 8; k++) if (DDRAM_BE[k]) v[8*k +: 8] = DDRAM_DIN[8*k +: 8];
        mem[DDRAM_ADDR] = v;
        if (DDRAM_BURSTCNT != 1) begin errors++; $display("write burst %0d", DDRAM_BURSTCNT); end
    end else if (!DDRAM_BUSY && DDRAM_RD) begin
        rq_a <= DDRAM_ADDR; rq_t <= 12;
    end
    DDRAM_BUSY <= $urandom_range(0, 99) < busy_pct;
end

function automatic logic [63:0] word(input logic [31:0] byteaddr);
    return mem.exists(byteaddr[31:3]) ? mem[byteaddr[31:3]] : 64'h0;
endfunction

// the expected entries
logic [3:0] e_reg [$];
logic [7:0] e_dat [$];

task automatic ppc(input logic [3:0] r, input logic [7:0] d);
    @(posedge clk); wr <= 1; wreg <= r; wdata <= d;
    @(posedge clk); wr <= 0;
    e_reg.push_back(r); e_dat.push_back(d);
endtask

initial begin
    int r, n;
    logic [31:0] last_us;
    if ($value$plusargs("seed=%d", seed)) ;
    if ($value$plusargs("busy=%d", busy_pct)) ;
    r = $urandom(seed);
    repeat (5) @(posedge clk);
    reset = 0;
    ppc(4'd8, 8'h80);
    for (int c = 0; c < 40; c++) begin
        // a command: registers 0-3, then the interrupt
        for (int k = 0; k < 4; k++) ppc(4'(k), 8'($urandom));
        ppc(4'd7, 8'h10);
        repeat ($urandom_range(0, 3) == 0 ? 0 : $urandom_range(10, 3000)) @(posedge clk);
    end
    repeat (3000) @(posedge clk);
    // the ring
    n = int'(word(SHM + 32'h10)[31:0]);
    if (n != e_reg.size()) begin errors++; $display("count %0d, expected %0d", n, e_reg.size()); end
    last_us = 0;
    for (int i = 0; i < e_reg.size(); i++) begin
        logic [63:0] w;
        w = word(SHM + 32'h1000 + 32'(i % 512) * 8);
        if (w[35:32] != e_reg[i] || w[47:40] != e_dat[i] || w[31:0] < last_us) begin
            errors++;
            if (errors < 10) $display("entry %0d: %016X, expected register %0d data %02X", i, w, e_reg[i], e_dat[i]);
        end
        last_us = w[31:0];
    end
    begin
        logic [63:0] s;
        logic [31:0] h;
        s = word(SHM + 32'h20);
        for (int k = 0; k < 4; k++)
            for (int i = e_reg.size() - 1; i >= 0; i--) if (e_reg[i] == 4'(k)) begin h[8*k +: 8] = e_dat[i]; break; end
        if (s[31:0] != h || !s[32]) begin errors++; $display("state %016X, expected %08X with SNDRES", s, h); end
    end
    if (word(SHM)[31:0] != 32'h534E_5248) begin errors++; $display("no magic"); end
    if (word(SHM + 32'h18)[31:0] == 0) begin errors++; $display("no beat"); end
    // a server: heartbeat moving, flags, reply 0x8D/0x12
    if (live) begin errors++; $display("live before any server"); end
    for (int i = 1; i < 30; i++) begin
        mem[(SHM + 32'h40) >> 3] = {16'(i), 8'hA5, 8'h01, 16'h0, 8'h12, 8'h8D};
        repeat (400) @(posedge clk);
    end
    if (!live || reply != 16'h128D) begin errors++; $display("live %0d reply %04X with a server", live, reply); end
    repeat (300 * 50) @(posedge clk);
    if (live) begin errors++; $display("still live after the heartbeat stopped"); end
    $display("%0d entries; %0d errors", e_reg.size(), errors);
    if (errors == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

endmodule
