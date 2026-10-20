// SPDX-License-Identifier: GPL-3.0-or-later
//
// A block RAM with two read/write ports, each with byte enables; read data the clock after the
// address. One clock.
//
// Synthesis instantiates a BIDIR_DUAL_PORT altsyncram: written behaviourally with byte enables,
// Quartus 17 refuses two writers ("multiple constant drivers") or builds the array from
// registers (the Hyper NeoGeo 64 core's hng64_bram, LESSONS_LEARNED). Simulators run the model.

module hornet_dpram #(
    parameter int AW = 15,
    parameter int DW = 32,              // a multiple of 8
    parameter bit WORD = 0,             // whole-word writes only (a_be/b_be all or none): no byte
                                        // enables, so that the x5 block widths are open to the fitter
    parameter int MAXD = 0              // the block depth to slice by (altsyncram maximum_depth), 0: any
) (
    input  logic            clk,
    input  logic [AW-1:0]   a_addr,
    input  logic [DW/8-1:0] a_be,       // bytes written this clock
    input  logic [DW-1:0]   a_wdata,
    output logic [DW-1:0]   a_rdata,
    input  logic [AW-1:0]   b_addr,
    input  logic [DW/8-1:0] b_be,
    input  logic [DW-1:0]   b_wdata,
    output logic [DW-1:0]   b_rdata
);

`ifndef ALTERA_RESERVED_QIS
    logic [DW-1:0] mem [1 << AW];

    always_ff @(posedge clk) begin
        for (int k = 0; k < DW / 8; k++)
            if (a_be[k]) mem[a_addr][8*k +: 8] <= a_wdata[8*k +: 8];
        a_rdata <= mem[a_addr];
    end
    always_ff @(posedge clk) begin
        for (int k = 0; k < DW / 8; k++)
            if (b_be[k]) mem[b_addr][8*k +: 8] <= b_wdata[8*k +: 8];
        b_rdata <= mem[b_addr];
    end
`else
    altsyncram #(
        .operation_mode("BIDIR_DUAL_PORT"),
        .ram_block_type("M10K"),
        .intended_device_family("Cyclone V"),
        .lpm_type("altsyncram"),
        .numwords_a(1 << AW), .widthad_a(AW), .width_a(DW),
        .numwords_b(1 << AW), .widthad_b(AW), .width_b(DW),
        .width_byteena_a(WORD ? 1 : DW / 8), .width_byteena_b(WORD ? 1 : DW / 8), .byte_size(8),
        .maximum_depth(MAXD),
        .outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
        .address_reg_b("CLOCK0"), .indata_reg_b("CLOCK0"), .wrcontrol_wraddress_reg_b("CLOCK0"),
        .byteena_reg_b("CLOCK0"),
        .clock_enable_input_a("BYPASS"), .clock_enable_output_a("BYPASS"),
        .clock_enable_input_b("BYPASS"), .clock_enable_output_b("BYPASS"),
        .outdata_aclr_a("NONE"), .outdata_aclr_b("NONE"),
        .read_during_write_mode_mixed_ports("DONT_CARE"),
        .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
        .power_up_uninitialized("FALSE")
    ) u_ram (
        .clock0(clk), .clock1(1'b1),
        .address_a(a_addr), .data_a(a_wdata), .wren_a(|a_be), .byteena_a(WORD ? {DW/8{1'b1}} : a_be), .q_a(a_rdata),
        .address_b(b_addr), .data_b(b_wdata), .wren_b(|b_be), .byteena_b(WORD ? {DW/8{1'b1}} : b_be), .q_b(b_rdata),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
        .rden_a(1'b1), .rden_b(1'b1), .eccstatus()
    );
`endif

endmodule
