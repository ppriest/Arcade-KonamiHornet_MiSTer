// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 0 criterion 4: the PPC403 core's area and Fmax on its own. A Quartus project of its own,
// not part of the core build:
//
//     quartus_sh --flow compile rtl/synth_check/synth_check
//
// Every input is driven from an LFSR seeded by one pin and every output folded into one pin,
// so nothing optimises away and no path is pin-bound.

module synth_top (
    input  logic clk,
    input  logic reset,
    input  logic din,
    output logic dout
);
    logic [127:0] lfsr;
    always_ff @(posedge clk) lfsr <= {lfsr[126:0], din ^ lfsr[127] ^ lfsr[125] ^ lfsr[100] ^ lfsr[98]};

    logic        i_req, d_req, d_we, dcr_we, dcr_re, dbg_exec;
    logic [30:0] i_addr, d_addr;
    logic [3:0]  d_be;
    logic [31:0] d_wdata, dcr_wdata, dbg_pc, dbg_ir, dbg_val;
    logic [9:0]  dcr_addr;

    ppc403_core cpu (
        .clk, .reset, .ce(lfsr[0] | lfsr[1]), .tb_tick(lfsr[2]),
        .i_req, .i_addr, .i_ack(lfsr[3]), .i_rdata(lfsr[35:4]),
        .d_req, .d_we, .d_addr, .d_be, .d_wdata, .d_ack(lfsr[36]), .d_rdata(lfsr[68:37]),
        .dcr_we, .dcr_re, .dcr_addr, .dcr_wdata, .dcr_rdata(lfsr[100:69]),
        .ext_irq(lfsr[105:101]), .int_irq(lfsr[114:106]),
        .dbg_exec, .dbg_pc, .dbg_ir, .dbg_sel(lfsr[120:115]), .dbg_val,
        .dbg_we(1'b0), .dbg_wsel(6'd0), .dbg_wdata(32'd0)
    );

    always_ff @(posedge clk)
        dout <= ^{i_req, d_req, d_we, dcr_we, dcr_re, dbg_exec, i_addr, d_addr, d_be, d_wdata,
                  dcr_wdata, dcr_addr, dbg_pc, dbg_ir, dbg_val};
endmodule
