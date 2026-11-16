// SPDX-License-Identifier: GPL-3.0-or-later
// v1 and v2 side by side on one program and one starting state: sharc_core (the golden model),
// sharc2_core serial (comparable at every retired instruction) and sharc2_core pipelined, as on
// the board (comparable at the end). BENCH 1 on both v2s for the I / M read port. main.cpp
// loads all three through the shared dbg ports. V2_RND other than MAME_RND shows that the bench
// sees the rounding.
module tb_sharclock #(parameter bit MAME_RND = 0, parameter bit SUBSET = 0, parameter bit ONE_FADD = 1,
                      parameter bit V2_RND = MAME_RND) (
    input  logic        clk, reset, ce,
    input  logic        dbg_pm_we,
    input  logic [14:0] dbg_pm_addr,
    input  logic [47:0] dbg_pm_wdata,
    input  logic        dbg_dm_we,
    input  logic [14:0] dbg_dm_addr,
    input  logic [31:0] dbg_dm_wdata,
    input  logic        dbg_we,
    input  logic [7:0]  dbg_wsel,
    input  logic [5:0]  dbg_widx,
    input  logic [63:0] dbg_wdata,
    input  logic [5:0]  sel1, sel2, sel3,
    output logic [31:0] val1, val2, val3,
    output logic        exec1, exec2, exec3,
    output logic [23:0] pc1, pc2, pc3,
    output logic [47:0] op1,
    output logic        ext1, ext2, ext3,
    output logic        unsup2, unsup3
);
    sharc_core #(.MAME_RND(MAME_RND)) v1 (
        .clk, .reset, .ce, .boot(1'b0), .ext_req(ext1), .ext_we(), .ext_addr(), .ext_wdata(),
        .ext_ack(1'b1), .ext_rdata(32'h0),
        .irq_in(3'b000), .irq_assert(3'b000), .irq_check_en(1'b0), .dbg_irq_set(32'h0),
        .dbg_exec(exec1), .dbg_pc(pc1), .dbg_op(op1), .dbg_sel(sel1), .dbg_val(val1), .dbg_idle(),
        .dbg_pm_we, .dbg_pm_addr, .dbg_pm_wdata, .dbg_dm_we, .dbg_dm_addr, .dbg_dm_wdata,
        .dbg_we, .dbg_wsel, .dbg_widx, .dbg_wdata
    );
    sharc2_core #(.BENCH(1), .SUBSET(SUBSET), .ONE_FADD(ONE_FADD), .MAME_RND(V2_RND)) v2s (
        .clk, .reset, .ce, .boot(1'b0), .serial(1'b1), .ext_req(ext2), .ext_we(), .ext_addr(), .ext_wdata(),
        .ext_ack(1'b1), .ext_rdata(32'h0), .ext_post(1'b0),
        .irq_in(3'b000), .irq_assert(3'b000), .irq_check_en(1'b0), .dbg_irq_set(32'h0),
        .dbg_iop_ovr(1'b0), .dbg_iop_val(32'h0),
        .dbg_exec(exec2), .dbg_pc(pc2), .dbg_op(), .dbg_sel(sel2), .dbg_val(val2), .dbg_idle(), .unsup(unsup2),
        .dbg_pm_we, .dbg_pm_addr, .dbg_pm_wdata, .dbg_dm_we, .dbg_dm_addr, .dbg_dm_wdata,
        .dbg_we, .dbg_wsel, .dbg_widx, .dbg_wdata
    );
    sharc2_core #(.BENCH(1), .SUBSET(SUBSET), .ONE_FADD(ONE_FADD), .MAME_RND(V2_RND)) v2p (
        .clk, .reset, .ce, .boot(1'b0), .serial(1'b0), .ext_req(ext3), .ext_we(), .ext_addr(), .ext_wdata(),
        .ext_ack(1'b1), .ext_rdata(32'h0), .ext_post(1'b0),
        .irq_in(3'b000), .irq_assert(3'b000), .irq_check_en(1'b0), .dbg_irq_set(32'h0),
        .dbg_iop_ovr(1'b0), .dbg_iop_val(32'h0),
        .dbg_exec(exec3), .dbg_pc(pc3), .dbg_op(), .dbg_sel(sel3), .dbg_val(val3), .dbg_idle(), .unsup(unsup3),
        .dbg_pm_we, .dbg_pm_addr, .dbg_pm_wdata, .dbg_dm_we, .dbg_dm_addr, .dbg_dm_wdata,
        .dbg_we, .dbg_wsel, .dbg_widx, .dbg_wdata
    );
endmodule
