// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fast ROM loading: the .mra's index-0 image with address="0x30000000" is written into DDR3 by the
// HPS (no ioctl_wr pulses), and this replays it, a byte at a time paced by the download path's
// wait, into the same logic the ioctl bytes feed (MS32's scheme: the two paths cannot diverge).
// The next beat is read while the current one goes out. DDRAM_* are the loader's only while
// `active`; the top hands them over with the board in reset and hornet_ddr3 idle.

module hornet_rom_loader (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,          // a pulse
    input  logic [26:0] length,         // image bytes
    output logic        active,

    output logic        wr,             // ioctl_wr / ioctl_addr / ioctl_dout as hps_io's
    output logic [26:0] addr,
    output logic [7:0]  dout,
    input  logic        wait_,          // the download path's ioctl_wait

    input  logic        DDRAM_BUSY,
    output logic [7:0]  DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    input  logic [63:0] DDRAM_DOUT,
    input  logic        DDRAM_DOUT_READY,
    output logic        DDRAM_RD
);

assign DDRAM_BURSTCNT = 8'd1;

logic [23:0] ra;                        // the next beat to read
logic        r_out;                     // a read is outstanding
logic [63:0] nb, cb;                    // the next beat, the one going out
logic        nb_v, cb_v;
logic [2:0]  k;                         // the byte of cb going out
logic [23:0] rq_a, nb_a, cb_a;          // the beats of the read, nb and cb

wire [23:0] beats = length[26:3] + (length[2:0] != 0);

always_ff @(posedge clk) begin
    wr <= 1'b0;
    if (DDRAM_RD && !DDRAM_BUSY) DDRAM_RD <= 1'b0;
    if (start) begin
        active <= 1'b1; ra <= '0; r_out <= 1'b0; nb_v <= 1'b0; cb_v <= 1'b0; k <= 3'd0;
    end else if (active) begin
        if (!r_out && !nb_v && ra != beats) begin
            DDRAM_RD <= 1'b1; DDRAM_ADDR <= 29'h0600_0000 + {5'h0, ra};
            r_out <= 1'b1; rq_a <= ra; ra <= ra + 1'd1;
        end
        if (DDRAM_DOUT_READY) begin nb <= DDRAM_DOUT; nb_a <= rq_a; nb_v <= 1'b1; r_out <= 1'b0; end
        if (!cb_v && nb_v && !DDRAM_DOUT_READY) begin
            cb <= nb; cb_v <= 1'b1; cb_a <= nb_a; nb_v <= 1'b0; k <= 3'd0;
        end
        // a byte every other clock at most: the path raises its wait the clock after wr
        if (cb_v && !wait_ && !wr) begin
            if ({cb_a, k} < length) begin
                wr <= 1'b1; addr <= {cb_a, k}; dout <= cb[8*k +: 8];
            end
            k <= k + 1'd1;
            if (k == 3'd7) cb_v <= 1'b0;
        end
        if (!cb_v && !nb_v && !r_out && ra == beats && !wr && !wait_) active <= 1'b0;
    end
    if (reset) begin active <= 1'b0; DDRAM_RD <= 1'b0; wr <= 1'b0; end
end

endmodule
