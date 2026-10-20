// SPDX-License-Identifier: GPL-3.0-or-later
//
// hornet_rtc against MAME's timekeeper rules (timekpr.cpp), with a 4-clock second:
// the host time, a year-end rollover, February in a leap year, the read bit freezing the bytes,
// the write bit stopping the count and loading the counters from the bytes when cleared.
//
//     scripts/run_verilator.sh rtc_tb

`timescale 1ns/1ps
module tb_rtc;
    logic clk = 0;
    always #5 clk = !clk;

    logic        set = 0, tick_en = 0, ld = 0, wa = 0, ra = 0;
    logic [55:0] host;
    logic [3:0]  we = 0;
    logic [31:0] wdata = 0, rdata;
    int          fails = 0;

    hornet_rtc #(.CLK_HZ(4)) dut (.clk, .set, .host_time(host), .tick_en, .ld, .wa, .we, .wdata,
                                  .ra, .rdata);

    task automatic clocks(int n); repeat (n) @(posedge clk); #1; endtask
    // {control, seconds, minutes, hours} and {day, date, month, year}
    task automatic expect_words(logic [31:0] w0, logic [31:0] w1, string what);
        logic [31:0] g0, g1;
        ra = 0; #1 g0 = rdata; ra = 1; #1 g1 = rdata;
        if (g0 !== w0 || g1 !== w1) begin
            $display("FAIL %s: %08x %08x, want %08x %08x", what, g0, g1, w0, w1); fails++;
        end else $display("ok   %s: %08x %08x", what, g0, g1);
    endtask
    task automatic wr(logic a, logic [3:0] b, logic [31:0] d);
        wa = a; we = b; wdata = d; clocks(1); we = 0;
    endtask

    initial begin
        // Thursday (4) 2026-12-31 23:59:58
        host = {8'h04, 8'h26, 8'h12, 8'h31, 8'h23, 8'h59, 8'h58};
        set = 1; clocks(1); set = 0;
        expect_words(32'h00_58_59_23, 32'h05_31_12_26, "host time");
        tick_en = 1;
        clocks(4); expect_words(32'h00_59_59_23, 32'h05_31_12_26, "one second");
        clocks(4); expect_words(32'h00_00_00_00, 32'h06_01_01_27, "year end");

        // 2028-02-28 23:59:59 through a write-bit load: write the bytes, clear W
        wr(0, 4'b1000, 32'h80_00_00_00);                       // W
        wr(0, 4'b0111, 32'h00_59_59_23);
        wr(1, 4'b1111, 32'h02_28_02_28);
        clocks(8);
        expect_words(32'h80_59_59_23, 32'h02_28_02_28, "stopped while W");
        wr(0, 4'b1000, 32'h00_00_00_00);                       // clear W: counters from the bytes
        clocks(4); expect_words(32'h00_00_00_00, 32'h03_29_02_28, "leap day");

        // R freezes the bytes; the counters run on, and clearing R copies them back
        wr(0, 4'b1000, 32'h40_00_00_00);
        clocks(8); expect_words(32'h40_00_00_00, 32'h03_29_02_28, "frozen by R");
        wr(0, 4'b1000, 32'h00_00_00_00);
        expect_words(32'h00_02_00_00, 32'h03_29_02_28, "R cleared");

        // the date's BL bit reads 0
        wr(1, 4'b0100, 32'h00_69_00_00);
        expect_words(32'h00_02_00_00, 32'h03_29_02_28, "BL masked");

        // a state load sets bytes and counters
        tick_en = 0; ld = 1;
        wr(0, 4'b1111, 32'h00_10_20_08); wr(1, 4'b1111, 32'h01_15_06_99);
        ld = 0; tick_en = 1; clocks(4);
        expect_words(32'h00_11_20_08, 32'h01_15_06_99, "state load");

        if (fails) $display("rtc_tb: %0d FAILED", fails); else $display("rtc_tb: all passed");
        $finish;
    end
endmodule
