// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/mister/hornet_ddr3.sv: seven 32-bit masters with random read and write bursts (odd and even
// starts and lengths, byte enables, reads outstanding while their words wait), each in its own
// region, against a 64-bit DDR3 model with a read latency and a random BUSY. Every word read is
// checked against what the master wrote.
//
//     scripts/run_verilator.sh ddr3_tb [+seed=N] [+ops=N] [+lat=N] [+busy=P] [+mask=M] [+wpct=P] [+dbg]
//
// Masters 1, 3 and 5 are wide (hornet_ddr3 WIDE): aligned even bursts, two words a handshake.
//
// +mask: the masters that run (bit i, master i); +wpct: the share of bursts that are writes;
// +dbg: every DDR3 command and master word.

`timescale 1ns/1ps

module tb_ddr3;

localparam int N = 7;
logic clk = 0, reset = 1;
always #7.8125 clk = !clk;

logic [N-1:0]       m_read = '0, m_write = '0, m_waitn, m_rvalid;
logic [N-1:0][31:0] m_addr = '0, m_wdata = '0;
logic [N-1:0][10:0] m_burst = '0;
logic [N-1:0][3:0]  m_be = '0, m_be_hi = '0;
logic [N-1:0][31:0] m_wdata_hi = '0;
logic [31:0]        m_rdata_hi;
localparam logic [N-1:0] WIDE = 7'b0101010;
logic [31:0]        m_rdata;

logic        DDRAM_BUSY = 0, DDRAM_DOUT_READY = 0, DDRAM_RD, DDRAM_WE;
logic [7:0]  DDRAM_BURSTCNT, DDRAM_BE;
logic [28:0] DDRAM_ADDR;
logic [63:0] DDRAM_DOUT = 0, DDRAM_DIN;
logic [23:0] dbg;
logic        drain = 0, idle;
logic [77:0] dbg_cmd;
logic [42:0] dbg_ret;

// +rdy=P: each master ready for its read data P percent of the clocks (m_rready)
logic [N-1:0]       m_rready = '1;
int rdy_pct = 100;
always @(posedge clk) for (int k = 0; k < N; k++) m_rready[k] <= ($urandom % 100) < rdy_pct;

hornet_ddr3 #(.N(N), .WIDE(WIDE)) dut (.*);

int lat = 20, busy_pct = 20, nops = 300, seed = 1, errors = 0, mask = 127, wpct = 33;
longint words_rd = 0, words_wr = 0;

// ---------------------------------------------------------------- the DDR3 model
logic [63:0] mem [int];
int          w_left = 0;
logic [28:0] w_a;
typedef struct { logic [63:0] d [$]; longint t; } rd_t;   // data as at the command
rd_t         rq [$];
longint      now = 0;

always @(posedge clk) begin
    now++;
    DDRAM_DOUT_READY <= 0;
    // read data: in order, a beat a clock, the first after lat
    if (rq.size() != 0 && rq[0].t <= now) begin
        DDRAM_DOUT_READY <= 1;
        DDRAM_DOUT <= rq[0].d.pop_front();
        if (rq[0].d.size() == 0) void'(rq.pop_front());
    end
    if (!DDRAM_BUSY && DDRAM_WE) begin
        logic [28:0] a;
        logic [63:0] v;
        if (w_left == 0) begin a = DDRAM_ADDR; w_left = DDRAM_BURSTCNT; end else a = w_a;
        v = mem.exists(a) ? mem[a] : 64'h0;
        for (int k = 0; k < 8; k++) if (DDRAM_BE[k]) v[8*k +: 8] = DDRAM_DIN[8*k +: 8];
        mem[a] = v;
        if ($test$plusargs("dbg")) $display("%t DDR write %07X be %02X %016X", $time, a, DDRAM_BE, DDRAM_DIN);
        w_a = a + 1; w_left--;
    end else if (!DDRAM_BUSY && DDRAM_RD) begin
        rd_t r;
        if (w_left != 0) begin errors++; $display("read inside a write burst at %t", $time); end
        r.d.delete();                   // r is static: clear what the last read left
        for (int k = 0; k < int'(DDRAM_BURSTCNT); k++)
            r.d.push_back(mem.exists(DDRAM_ADDR + 29'(k)) ? mem[DDRAM_ADDR + 29'(k)] : 64'h0);
        r.t = now + lat;
        if ($test$plusargs("dbg")) $display("%t DDR read %07X x%0d", $time, DDRAM_ADDR, DDRAM_BURSTCNT);
        rq.push_back(r);
    end
    DDRAM_BUSY <= $urandom_range(0, 99) < busy_pct;
end

// ---------------------------------------------------------------- the masters
logic [31:0] ref_m [N][int];            // per master: byte address -> word
logic [31:0] exp_q [N][$];              // words each master expects, in order
logic [31:0] exp_a [N][$];              // ... and their addresses

for (genvar gi = 0; gi < N; gi++) begin : g_chk
    always @(posedge clk) if (m_rvalid[gi]) begin
        for (int h = 0; h < (WIDE[gi] ? 2 : 1); h++) begin
            logic [31:0] d;
            d = h ? m_rdata_hi : m_rdata;
            if (exp_q[gi].size() == 0) begin errors++; $display("master %0d: unexpected word", gi); end
            else begin
                logic [31:0] e, ea;
                e = exp_q[gi].pop_front();
                ea = exp_a[gi].pop_front();
                if (d !== e) begin
                    errors++;
                    if (errors < 20) $display("master %0d: read %08X at %08X, expected %08X at %t", gi, d, ea, e, $time);
                end
                words_rd++;
                if ($test$plusargs("dbg")) $display("%t master %0d got %08X for %08X", $time, gi, d, ea);
            end
        end
    end
end

task automatic master(input int i);
    // its region: 1 MB at 0x38000000 + i MB, 32-bit words
    for (int op = 0; op < (mask[i] ? nops : 0); op++) begin
        int n, w0;
        logic [31:0] a;
        n = $urandom_range(0, 3) == 0 ? $urandom_range(1, 3) : $urandom_range(1, 300);
        w0 = $urandom_range(0, 4000);
        if (WIDE[i]) begin n = (n + 1) & ~1; w0 = w0 & ~1; end
        a = 32'h3800_0000 + i * 32'h10_0000 + w0 * 4;
        if ($urandom_range(0, 99) < wpct) begin
            // a write burst
            @(posedge clk);
            m_write[i] <= 1; m_addr[i] <= a; m_burst[i] <= 11'(n);
            for (int k = 0; k < n; k += (WIDE[i] ? 2 : 1)) begin
                logic [31:0] d [2], o;
                logic [3:0] be [2];
                for (int h = 0; h < 2; h++) begin
                    d[h] = $urandom; be[h] = $urandom_range(0, 7) == 0 ? 4'($urandom_range(0, 15)) : 4'hF;
                end
                m_wdata[i] <= d[0]; m_be[i] <= be[0]; m_wdata_hi[i] <= d[1]; m_be_hi[i] <= be[1]; m_write[i] <= 1;
                @(posedge clk);
                while (!m_waitn[i]) @(posedge clk);
                for (int h = 0; h < (WIDE[i] ? 2 : 1); h++) begin
                    o = ref_m[i].exists(a + 4 * (k + h)) ? ref_m[i][a + 4 * (k + h)] : 32'h0;
                    for (int b = 0; b < 4; b++) if (be[h][b]) o[8*b +: 8] = d[h][8*b +: 8];
                    ref_m[i][a + 4 * (k + h)] = o;
                    if ($test$plusargs("dbg")) $display("%t master %0d word %08X = %08X be %X", $time, i, a + 4 * (k + h), d[h], be[h]);
                    words_wr++;
                end
                if ($urandom_range(0, 9) == 0 && k + (WIDE[i] ? 2 : 1) < n) begin m_write[i] <= 0; @(posedge clk); end
            end
            m_write[i] <= 0;
        end else begin
            // a read, while fewer than about four bursts of words are outstanding
            while (exp_q[i].size() > 1000) @(posedge clk);
            @(posedge clk);
            m_read[i] <= 1; m_addr[i] <= a; m_burst[i] <= 11'(n);
            @(posedge clk);
            while (!m_waitn[i]) @(posedge clk);
            m_read[i] <= 0;
            if ($test$plusargs("dbg")) $display("%t master %0d read %08X x%0d", $time, i, a, n);
            for (int k = 0; k < n; k++) exp_a[i].push_back(a + 4 * k);
            for (int k = 0; k < n; k++) exp_q[i].push_back(ref_m[i].exists(a + 4 * k) ? ref_m[i][a + 4 * k] : 32'h0);
        end
    end
    while (exp_q[i].size() != 0) @(posedge clk);
endtask

initial begin
    int r;
    if ($value$plusargs("seed=%d", seed)) ;
    if ($value$plusargs("ops=%d", nops)) ;
    if ($value$plusargs("lat=%d", lat)) ;
    if ($value$plusargs("busy=%d", busy_pct)) ;
    if ($value$plusargs("mask=%d", mask)) ;
    if ($value$plusargs("rdy=%d", rdy_pct)) ;
    if ($value$plusargs("wpct=%d", wpct)) ;
    r = $urandom(seed);
    repeat (5) @(posedge clk);
    reset = 0;
    if ($test$plusargs("draintest")) begin
        // a master stops halfway through a write burst and the port drains: the burst must reach
        // its count on the DDRAM side, no master sees data, and idle rises; then a read drained
        int got = 0;
        @(posedge clk);
        m_write[0] <= 1; m_addr[0] <= 32'h3800_0000; m_burst[0] <= 11'd100; m_be[0] <= 4'hF; m_wdata[0] <= 32'h1234;
        for (int k = 0; k < 10; k++) begin @(posedge clk); while (!m_waitn[0]) @(posedge clk); end
        m_write[0] <= 0; drain <= 1;
        repeat (400) @(posedge clk);
        if (w_left != 0) begin errors++; $display("drain: write burst left %0d beats short", w_left); end
        if (!idle) begin errors++; $display("drain: not idle after a write burst"); end
        drain <= 0;
        @(posedge clk);
        m_read[1] <= 1; m_addr[1] <= 32'h3810_0000; m_burst[1] <= 11'd200;
        @(posedge clk); while (!m_waitn[1]) @(posedge clk);
        m_read[1] <= 0; drain <= 1;
        repeat (400) begin @(posedge clk); if (m_rvalid != '0) got++; end
        if (got != 0) begin errors++; $display("drain: %0d words reached a master", got); end
        if (!idle) begin errors++; $display("drain: not idle after a read"); end
        // drain 0-4 clocks after a read is offered: once it is chosen and before it reaches the
        // port (A_CMD), it must take no credits
        for (int d = 0; d < 5; d++) begin
            drain <= 0;
            @(posedge clk);
            m_read[1] <= 1; m_addr[1] <= 32'h3810_0000; m_burst[1] <= 11'd256;
            repeat (d) @(posedge clk);
            drain <= 1;
            @(posedge clk);
            m_read[1] <= 0;
            repeat (400) @(posedge clk);
            if (!idle) begin errors++; $display("drain: not idle, drain %0d clocks after a read: as %0d r_out %0d t_on %0d tq %0d %0d rf %0d %0d", d, dut.as, dut.r_out, dut.t_on, dut.tq_wp, dut.tq_rp, dut.rf_wp, dut.rf_rp); end
        end
        $display("drain test: %0d errors", errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
    fork
        master(0); master(1); master(2); master(3); master(4); master(5); master(6);
    join
    repeat (50) @(posedge clk);
    $display("words written %0d, read %0d; %0d errors; %0d clocks", words_wr, words_rd, errors, now);
    if (errors == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

endmodule
