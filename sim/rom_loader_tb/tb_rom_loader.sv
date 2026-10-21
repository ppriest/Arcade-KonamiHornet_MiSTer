// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/mister/hornet_rom_loader.sv: an image of +len bytes in a DDR3 model (read latency, random
// BUSY) replayed into a model of the download path (an odd byte raises the wait for a random
// time, as KonamiHornet.sv's d_we does); every byte must arrive once, in order, at its address.
//
//     scripts/run_verilator.sh rom_loader_tb [+len=N] [+lat=N] [+busy=P] [+seed=N]

`timescale 1ns/1ps

module tb_rom_loader;

logic clk = 0, reset = 1, start = 0;
always #7.8125 clk = !clk;

logic        active, wr, wait_ = 0;
logic [26:0] addr, length;
logic [7:0]  dout;
logic        DDRAM_BUSY = 0, DDRAM_DOUT_READY = 0, DDRAM_RD;
logic [7:0]  DDRAM_BURSTCNT;
logic [28:0] DDRAM_ADDR;
logic [63:0] DDRAM_DOUT = 0;

hornet_rom_loader dut (.*);

int len = 100003, lat = 20, busy_pct = 20, seed = 1, errors = 0;
function automatic logic [7:0] img(input int a); return 8'(a * 7 + (a >> 8) * 13 + 5); endfunction

// DDR3: one outstanding beat, data lat clocks after the command is taken
int due = -1; logic [28:0] ra; longint now = 0;
always @(posedge clk) begin
    now++;
    DDRAM_DOUT_READY <= 0;
    if (due == 0) begin
        logic [63:0] d;
        for (int k = 0; k < 8; k++) d[8*k +: 8] = img((int'(ra) - 32'h0600_0000) * 8 + k);
        DDRAM_DOUT <= d; DDRAM_DOUT_READY <= 1;
    end
    if (due >= 0) due--;
    if (DDRAM_RD && !DDRAM_BUSY) begin
        if (due >= 0) begin errors++; $display("a second read outstanding"); end
        if (DDRAM_BURSTCNT != 1) begin errors++; $display("burst %0d", DDRAM_BURSTCNT); end
        ra <= DDRAM_ADDR; due = lat;
    end
    DDRAM_BUSY <= $urandom_range(0, 99) < busy_pct;
end

// the download path: bytes in order; an odd one holds the wait for 0-6 clocks
int next = 0, hold = 0;
always @(posedge clk) begin
    if (hold > 0) hold--;
    wait_ <= hold > 0;
    if (wr) begin
        if (wait_) begin errors++; $display("byte while waiting at %0d", addr); end
        if (addr != 27'(next) || dout != img(next)) begin
            errors++; if (errors < 10) $display("got %02X at %0d, expected %02X at %0d", dout, addr, img(next), next);
        end
        next++;
        if (addr[0]) begin hold = $urandom_range(1, 7); wait_ <= 1; end
    end
end

initial begin
    int r;
    if ($value$plusargs("len=%d", len)) ;
    if ($value$plusargs("lat=%d", lat)) ;
    if ($value$plusargs("busy=%d", busy_pct)) ;
    if ($value$plusargs("seed=%d", seed)) ;
    r = $urandom(seed);
    length = 27'(len);
    repeat (5) @(posedge clk);
    reset <= 0;
    @(posedge clk); start <= 1; @(posedge clk); start <= 0;
    @(posedge clk);
    while (active) @(posedge clk);
    repeat (20) @(posedge clk);
    if (next != len) begin errors++; $display("%0d of %0d bytes", next, len); end
    $display("%0d bytes in %0d clocks (%.2f a byte); %0d errors", next, now, real'(now) / len, errors);
    if (errors == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

endmodule
