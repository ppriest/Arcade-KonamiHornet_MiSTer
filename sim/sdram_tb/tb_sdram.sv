// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/mister/hornet_sdram.sv against a reference memory, on the 128 MB chip model
// (sim/common/sdram_chip_model_128.sv): a download of three windows (work RAM, character RAM,
// the SHARC's RAM at 0x1400000), then ports A, B and C at once with random traffic of the board's
// kinds: port A reads, byte-enabled writes and fetch runs over work RAM and character RAM; port B
// read streams and writes; port C tile-row reads (four words) of character RAM. Every read is checked; a port
// C read may return the value from before or after a port A write that overlaps it.
//
//     scripts/run_verilator.sh sdram_tb [+seed=N] [+ops=N]
//     scripts/run_verilator.sh sdram_tb +atrace=debug/atrace8460.txt [+only=a]
//
// +atrace: port A replays sim/board_tb's +atrace record instead of random traffic, each request the
// recorded number of clocks after the last acknowledge; the words it reads before writing are
// downloaded first with the values the board read. Reports the replay's clocks.

`timescale 1ns/1ps

module tb_sdram;

logic clk_mem = 0;
wire  clk;
always #7.8125 clk_mem = !clk_mem;                      // 64 MHz: the core runs the controller at clk
assign clk = clk_mem;

logic        init = 1, reset = 1, flush = 0;
logic [1:0]  a_dbg = 2'b00;
logic [2:0]  b_left = 3'd0;
wire  [15:0] SDRAM_DQ;
logic [12:0] SDRAM_A;
logic [1:0]  SDRAM_BA;
logic        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;

logic        a_req = 0, a_we = 0, a_ack;
logic [22:0] a_addr = 0;
logic [3:0]  a_be = 0;
logic [31:0] a_wdata = 0, a_rdata;
logic        b_req = 0, b_we = 0, b_ack;
logic [22:0] b_addr = 0;
logic [31:0] b_wdata = 0, b_rdata;
logic        c_req = 0, c_ack;
logic [18:0] c_addr = 0;
logic [127:0] c_rdata;
logic        d_we = 0, d_ready;
logic [25:0] d_addr = 0;
logic [15:0] d_din = 0;

hornet_sdram dut (.*);
sdram_chip_model_128 chip (.clk(SDRAM_CLK), .SDRAM_DQ, .SDRAM_A, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE,
                           .SDRAM_nRAS, .SDRAM_nCAS);

// the windows, in SDRAM word addresses (byte >> 2)
localparam int WORK0 = 0,          WORK_N = 4096;       // port A region 0
localparam int CHR0  = 32'h040_0000, CHR_N = 8192;      // port A region 4 = 0x1000000 >> 2
localparam int BR0   = 32'h090_0000, BR_N  = 8192;      // port B region 1 = (0x2000000 >> 2) + 1M words

logic [31:0] ref_m [int];
int errors = 0, nops = 3000, seed = 1;
string only = "abc";                                   // +only=: the ports that run
string atrace = "";
longint replay_t0 = 0, replay_clk = 0;
always @(posedge clk) replay_clk++;
longint n_a = 0, n_b = 0, n_c = 0, t_a = 0, t_b = 0, t_c = 0;   // accesses, clocks waiting

function automatic bit has(input string s, input string c);
    for (int i = 0; i < s.len(); i++) if (s.substr(i, i) == c) return 1;
    return 0;
endfunction

function automatic logic [31:0] merge(input logic [31:0] o, input logic [31:0] n, input logic [3:0] be);
    for (int k = 0; k < 4; k++) if (be[k]) o[8*k +: 8] = n[8*k +: 8];
    return o;
endfunction

task automatic dl_word(input int w, input logic [31:0] v);
    for (int h = 0; h < 2; h++) begin
        @(negedge clk);
        while (!d_ready) @(negedge clk);
        d_we = 1; d_addr = 26'(2 * w + h); d_din = h ? v[15:0] : v[31:16];
        @(negedge clk);
        d_we = 0;
    end
endtask

task automatic a_op(input logic we, input logic [22:0] ad, input logic [3:0] be, input logic [31:0] wd);
    int w;
    logic [31:0] exp;
    w = int'(ad);                       // port A: SDRAM word = a_addr
    @(negedge clk);
    a_req = 1; a_we = we; a_addr = ad; a_be = be; a_wdata = wd;
    @(negedge clk);
    while (!a_ack) begin @(negedge clk); t_a++; end
    a_req = 0;
    if (we) ref_m[w] = merge(ref_m.exists(w) ? ref_m[w] : 0, wd, be);
    else begin
        exp = ref_m.exists(w) ? ref_m[w] : 32'h0;
        if (a_rdata !== exp) begin
            errors++;
            if (errors < 20) $display("A read %06X: %08X, expected %08X at %t", ad, a_rdata, exp, $time);
        end
    end
    n_a++;
endtask

task automatic b_op(input logic we, input logic [22:0] ad, input logic [31:0] wd);
    int w;
    logic [31:0] exp;
    w = 32'h080_0000 + int'(ad);
    @(negedge clk);
    b_req = 1; b_we = we; b_addr = ad; b_wdata = wd;
    @(negedge clk);
    while (!b_ack) begin @(negedge clk); t_b++; end
    b_req = 0;
    if (we) ref_m[w] = wd;
    else begin
        exp = ref_m.exists(w) ? ref_m[w] : 32'h0;
        if (b_rdata !== exp) begin
            errors++;
            if (errors < 20) $display("B read %06X: %08X, expected %08X at %t", ad, b_rdata, exp, $time);
        end
    end
    n_b++;
endtask

task automatic c_op(input logic [18:0] ad);
    // a row of four words; each may be from before or after a port A write that overlaps it
    int w;
    logic [31:0] prev [4];
    w = CHR0 + int'({ad[18:2], 2'b00});
    @(negedge clk);
    for (int k = 0; k < 4; k++) prev[k] = ref_m.exists(w + k) ? ref_m[w + k] : 32'h0;
    c_req = 1; c_addr = ad;
    @(negedge clk);
    while (!c_ack) begin @(negedge clk); t_c++; end
    c_req = 0;
    for (int k = 0; k < 4; k++)
        if (c_rdata[32*k +: 32] !== prev[k] && c_rdata[32*k +: 32] !== (ref_m.exists(w + k) ? ref_m[w + k] : 32'h0)) begin
            errors++;
            if (errors < 20) $display("C read %05X word %0d: %08X, expected %08X at %t", ad, k, c_rdata[32*k +: 32], prev[k], $time);
        end
    n_c++;
endtask

initial begin
    int r;
    if ($value$plusargs("seed=%d", seed)) ;
    if ($value$plusargs("ops=%d", nops)) ;
    if ($value$plusargs("only=%s", only)) ;
    if ($value$plusargs("atrace=%s", atrace)) ;
    begin int d; if ($value$plusargs("adbg=%d", d)) a_dbg = 2'(d); end
    r = $urandom(seed);
    repeat (20) @(posedge clk);
    init = 0;
    repeat (600) @(posedge clk);
    reset = 0;
    repeat (4) @(posedge clk);

    // download
    for (int i = 0; i < WORK_N; i++) begin ref_m[WORK0 + i] = $urandom; dl_word(WORK0 + i, ref_m[WORK0 + i]); end
    for (int i = 0; i < CHR_N; i++)  begin ref_m[CHR0 + i]  = $urandom; dl_word(CHR0 + i, ref_m[CHR0 + i]); end
    for (int i = 0; i < BR_N; i++)   begin ref_m[BR0 + i]   = $urandom; dl_word(BR0 + i, ref_m[BR0 + i]); end
    if (atrace != "") begin
        int fd, gap, we, ad, be, wd, rd;
        bit seen [int];
        fd = $fopen(atrace, "r");
        if (fd == 0) begin $display("cannot open %s", atrace); $finish; end
        while ($fscanf(fd, "%d %d %h %h %h %h", gap, we, ad, be, wd, rd) == 6) begin
            if (!we && !seen.exists(ad)) begin ref_m[ad] = rd; dl_word(ad, rd); end
            seen[ad] = 1;
        end
        $fclose(fd);
    end
    $display("download done at %t", $time);

    fork
        // port A: a recorded stream
        if (atrace != "") begin
            int fd, gap, we, ad, be, wd, rd, n;
            fd = $fopen(atrace, "r");
            n = 0;
            replay_t0 = replay_clk;
            while ($fscanf(fd, "%d %d %h %h %h %h", gap, we, ad, be, wd, rd) == 6) begin
                if (n++ > 0) repeat (gap > 2 ? gap - 2 : 0) @(negedge clk);
                a_op(we[0], 23'(ad), 4'(be), wd);
            end
            $fclose(fd);
            $display("replay: %0d accesses in %0d clocks", n, replay_clk - replay_t0);
        end
        // port A
        for (int i = 0; i < (has(only, "a") && atrace == "" ? nops : 0); i++) begin
            int k;
            k = $urandom_range(0, 9);
            if (k < 3) begin                                // a fetch run
                int s, n;
                s = $urandom_range(0, WORK_N - 16); n = $urandom_range(2, 12);
                for (int j = 0; j < n; j++) a_op(0, 23'(WORK0 + s + j), 4'h0, 0);
            end else if (k < 5) a_op(0, 23'(WORK0 + $urandom_range(0, WORK_N - 1)), 4'h0, 0);
            else if (k < 7) a_op(1, 23'(WORK0 + $urandom_range(0, WORK_N - 1)), 4'($urandom_range(1, 15)), $urandom);
            else if (k < 8) a_op(0, 23'(CHR0 + $urandom_range(0, CHR_N - 1)), 4'h0, 0);
            else a_op(1, 23'(CHR0 + $urandom_range(0, CHR_N - 1)), 4'($urandom_range(1, 15)), $urandom);
        end
        // port B
        for (int i = 0; i < (has(only, "b") ? nops : 0); i++) begin
            int k;
            k = $urandom_range(0, 9);
            if (k < 6) begin                                // a stream
                int s, n;
                s = $urandom_range(0, BR_N - 80); n = $urandom_range(8, 64);
                for (int j = 0; j < n; j++) b_op(0, 23'(32'h10_0000 + s + j), 0);
            end else if (k < 8) b_op(0, 23'(32'h10_0000 + $urandom_range(0, BR_N - 1)), 0);
            else b_op(1, 23'(32'h10_0000 + $urandom_range(0, BR_N - 1)), $urandom);
        end
        // port C: tile rows, 16 words a tile, two words a row, rows of a few tiles repeated
        for (int i = 0; i < (has(only, "c") ? nops : 0); i++) begin
            int t0, row;
            t0 = $urandom_range(0, CHR_N / 16 - 8); row = $urandom_range(0, 7);
            for (int rr = row; rr < row + 3 && rr < 8; rr++)
                for (int t = t0; t < t0 + 6; t++)
                    c_op(19'(16 * t + 4 * (rr % 4)));
        end
    join

    $display("ops: A %0d, B %0d, C %0d; %0d errors", n_a, n_b, n_c, errors);
    $display("clocks an access after the first: A %0.2f, B %0.2f, C %0.2f",
             real'(t_a) / n_a, real'(t_b) / n_b, real'(t_c) / n_c);
    if (errors == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

endmodule
