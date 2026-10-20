// SPDX-License-Identifier: GPL-3.0-or-later
// sharc2_core alone; main.cpp (sim/sharc_tb's, for v2) is the external bus, the state loader and
// the trace writer.
module tb_sharc2 #(parameter int DMW = 32768) (
    input  logic        clk, reset, ce, serial,
    output logic        ext_req, ext_we,
    output logic [31:0] ext_addr, ext_wdata,
    input  logic        ext_ack,
    input  logic [31:0] ext_rdata,
    input  logic        irq_check_en,
    input  logic [31:0] dbg_irq_set,
    input  logic        dbg_iop_ovr,
    input  logic [31:0] dbg_iop_val,
    output logic        dbg_exec, dbg_idle,
    output logic [23:0] dbg_pc,
    output logic [47:0] dbg_op,
    input  logic [5:0]  dbg_sel,
    output logic [31:0] dbg_val,
    input  logic        dbg_pm_we,
    input  logic [14:0] dbg_pm_addr,
    input  logic [47:0] dbg_pm_wdata,
    input  logic        dbg_dm_we,
    input  logic [14:0] dbg_dm_addr,
    input  logic [31:0] dbg_dm_wdata,
    input  logic        dbg_we,
    input  logic [7:0]  dbg_wsel,
    input  logic [5:0]  dbg_widx,
    input  logic [63:0] dbg_wdata
);
    sharc2_core #(.BENCH(1), .DM_WORDS(DMW)) dsp (
        .clk, .reset, .ce, .boot(1'b0), .serial, .ext_req, .ext_we, .ext_addr, .ext_wdata, .ext_ack, .ext_rdata,
        .irq_in(3'b000), .irq_assert(3'b000), .irq_check_en, .dbg_irq_set, .dbg_iop_ovr, .dbg_iop_val,
        .dbg_exec, .dbg_pc, .dbg_op, .dbg_sel, .dbg_val, .dbg_idle,
        .dbg_pm_we, .dbg_pm_addr, .dbg_pm_wdata, .dbg_dm_we, .dbg_dm_addr, .dbg_dm_wdata,
        .dbg_we, .dbg_wsel, .dbg_widx, .dbg_wdata
    );
endmodule
