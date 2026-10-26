// SHARC v2 alone, as the board instantiates it (DMA_LOCK 0, DMA_PACK 0, 16K data words, debug ports
// tied off):
// inputs from an LFSR, outputs folded to one pin, for area and Fmax
module synth_top (input logic clk, input logic din, output logic dout);
    logic [255:0] l;
    always_ff @(posedge clk) l <= {l[254:0], din ^ l[255] ^ l[253] ^ l[250] ^ l[245]};
    logic        ext_req, ext_we, dbg_exec, dbg_idle;
    logic [31:0] ext_addr, ext_wdata;
    logic [23:0] dbg_pc;
    sharc2_core #(.DM_WORDS(16384), .DMA_LOCK(0), .DMA_PACK(0), .SUBSET(1), .ONE_FADD(1)) dsp (
        .clk, .reset(l[0] & l[1] & l[2]), .ce(1'b1), .boot(l[3] & l[4] & l[5] & l[6]), .serial(1'b0),
        .ext_req, .ext_we, .ext_addr, .ext_wdata, .ext_ack(l[7]), .ext_rdata(l[39:8]), .ext_post(l[40]),
        .irq_in(l[42:40]), .irq_assert(l[45:43]), .irq_check_en(1'b1), .dbg_irq_set(32'h0),
        .dbg_iop_ovr(1'b0), .dbg_iop_val(32'h0),
        .dbg_exec, .dbg_pc, .dbg_op(), .dbg_sel(6'd0), .dbg_val(), .dbg_idle, .unsup(),
        .dbg_pm_we(1'b0), .dbg_pm_addr(15'h0), .dbg_pm_wdata(48'h0),
        .dbg_dm_we(1'b0), .dbg_dm_addr(15'h0), .dbg_dm_wdata(32'h0),
        .dbg_we(1'b0), .dbg_wsel(8'h0), .dbg_widx(6'h0), .dbg_wdata(64'h0)
    );
    always_ff @(posedge clk) dout <= ^{ext_req, ext_we, ext_addr, ext_wdata, dbg_exec, dbg_idle, dbg_pc};
endmodule
