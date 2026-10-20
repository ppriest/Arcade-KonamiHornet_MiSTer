// SPDX-License-Identifier: GPL-3.0-or-later
//
// Clock-domain crossings between clk_sys and the SHARC's clock (hornet_board): a level through two
// flops, a pulse as a toggle, and a FIFO with Gray-coded pointers. The SDC makes the two clocks
// asynchronous; nothing else crosses.

// a level, two flops in the destination domain
module hornet_sync (
    input  logic clk,
    input  logic d,
    output logic q
);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) logic s1;
    always_ff @(posedge clk) begin s1 <= d; q <= s1; end
endmodule

// a one-clock pulse in the source domain to a one-clock pulse in the destination; pulses closer
// than three destination clocks merge
module hornet_pulse (
    input  logic clk_a,
    input  logic a,
    input  logic clk_b,
    output logic b
);
    logic t = 1'b0, s, s_q;
    always_ff @(posedge clk_a) if (a) t <= !t;
    hornet_sync u_s (.clk(clk_b), .d(t), .q(s));
    always_ff @(posedge clk_b) begin s_q <= s; b <= s != s_q; end
endmodule

// a FIFO of 2^AW words of DW bits: written on clk_w, read on clk_r (show-ahead: r_data is the
// head while !r_empty, r_pop takes it). Full and empty are each seen a few clocks late from the
// other side's pointer, which only costs room.
module hornet_afifo #(
    parameter int AW = 4,
    parameter int DW = 64
) (
    input  logic          clk_w,
    input  logic          rst_w,
    input  logic          w_push,
    input  logic [DW-1:0] w_data,
    output logic          w_full,
    input  logic          clk_r,
    input  logic          rst_r,
    input  logic          r_pop,
    output logic [DW-1:0] r_data,
    output logic          r_empty
);
    logic [AW:0] wb, wg, rb, rg;                // binary and Gray pointers
    logic [AW:0] rg_w, wg_r;                    // the other side's Gray pointer, synchronised

    function automatic logic [AW:0] g2b(input logic [AW:0] g);
        logic [AW:0] b;
        b[AW] = g[AW];
        for (int i = AW - 1; i >= 0; i--) b[i] = b[i + 1] ^ g[i];
        return b;
    endfunction

    // write side
    always_ff @(posedge clk_w) begin
        if (w_push && !w_full) begin
            wb <= wb + 1'd1;
            wg <= (wb + 1'd1) ^ ((wb + 1'd1) >> 1);
        end
        if (rst_w) begin wb <= '0; wg <= '0; end
    end
    // the Gray pointers through two flops each (one bit changes a step)
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) logic [AW:0] rg_s1;
    always_ff @(posedge clk_w) begin rg_s1 <= rg; rg_w <= rg_s1; end
    assign w_full = (wb - g2b(rg_w)) == (AW + 1)'(1 << AW);

    // read side
    always_ff @(posedge clk_r) begin
        if (r_pop && !r_empty) begin
            rb <= rb + 1'd1;
            rg <= (rb + 1'd1) ^ ((rb + 1'd1) >> 1);
        end
        if (rst_r) begin rb <= '0; rg <= '0; end
    end
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) logic [AW:0] wg_s1;
    always_ff @(posedge clk_r) begin wg_s1 <= wg; wg_r <= wg_s1; end
    assign r_empty = g2b(wg_r) == rb;
    // the words in an MLAB, written on clk_w, read without a clock: the read side reaches a slot only
    // after its write pointer has crossed, clocks after the write
    sharc2_lutram #(.AW(AW), .DW(DW)) u_mem (.clk(clk_w), .we(w_push && !w_full), .wa(wb[AW-1:0]),
        .wd(w_data), .ra(rb[AW-1:0]), .rd(r_data));
endmodule
