// SPDX-License-Identifier: GPL-3.0-or-later
// PPC403 core alone; main.cpp is the memory system and the trace writer.
module tb_ppc (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,
    input  logic        tb_tick,
    output logic        i_req,
    output logic [30:0] i_addr,
    input  logic        i_ack,
    input  logic [31:0] i_rdata,
    output logic        d_req,
    output logic        d_we,
    output logic [30:0] d_addr,
    output logic [3:0]  d_be,
    output logic [31:0] d_wdata,
    input  logic        d_ack,
    input  logic [31:0] d_rdata,
    output logic        dcr_we,
    output logic [9:0]  dcr_addr,
    output logic [31:0] dcr_wdata,
    input  logic [4:0]  ext_irq,
    output logic        dbg_exec,
    output logic [31:0] dbg_pc,
    output logic [31:0] dbg_ir,
    input  logic [5:0]  dbg_sel,
    output logic [31:0] dbg_val,
    input  logic        dbg_we,
    input  logic [5:0]  dbg_wsel,
    input  logic [31:0] dbg_wdata
);
    logic dcr_re;
    ppc403_core cpu (
        .clk, .reset, .ce, .tb_tick,
        .i_req, .i_addr, .i_ack, .i_rdata,
        .d_req, .d_we, .d_addr, .d_be, .d_wdata, .d_ack, .d_rdata,
        .dcr_we, .dcr_re, .dcr_addr, .dcr_wdata, .dcr_rdata(32'h0),
        .ext_irq, .int_irq(9'h0),
        .dbg_exec, .dbg_pc, .dbg_ir, .dbg_sel, .dbg_val, .dbg_we, .dbg_wsel, .dbg_wdata
    );
endmodule
