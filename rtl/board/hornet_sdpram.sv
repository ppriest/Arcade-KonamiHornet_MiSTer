// SPDX-License-Identifier: GPL-3.0-or-later
//
// A block RAM written on port A (byte enables) and read on port B, the data the clock after the
// address; one clock. Simple dual port, so an M10K is 40 bits wide (true dual port: 20): a 64-bit
// RAM of up to 256 words takes two.

module hornet_sdpram #(
    parameter int AW = 7,
    parameter int DW = 64               // a multiple of 8
) (
    input  logic            clk,
    input  logic [AW-1:0]   a_addr,
    input  logic [DW/8-1:0] a_be,
    input  logic [DW-1:0]   a_wdata,
    input  logic [AW-1:0]   b_addr,
    output logic [DW-1:0]   b_rdata
);

`ifndef ALTERA_RESERVED_QIS
    logic [DW-1:0] mem [1 << AW];
    always_ff @(posedge clk) begin
        for (int k = 0; k < DW / 8; k++)
            if (a_be[k]) mem[a_addr][8*k +: 8] <= a_wdata[8*k +: 8];
        b_rdata <= mem[b_addr];
    end
`else
    altsyncram #(
        .operation_mode("DUAL_PORT"),
        .ram_block_type("M10K"),
        .intended_device_family("Cyclone V"),
        .lpm_type("altsyncram"),
        .numwords_a(1 << AW), .widthad_a(AW), .width_a(DW),
        .numwords_b(1 << AW), .widthad_b(AW), .width_b(DW),
        .width_byteena_a(DW / 8), .byte_size(8),
        .outdata_reg_b("UNREGISTERED"), .address_reg_b("CLOCK0"),
        .clock_enable_input_a("BYPASS"), .clock_enable_input_b("BYPASS"),
        .clock_enable_output_b("BYPASS"), .outdata_aclr_b("NONE"),
        .read_during_write_mode_mixed_ports("DONT_CARE"),
        .power_up_uninitialized("FALSE")
    ) u_ram (
        .clock0(clk),
        .address_a(a_addr), .data_a(a_wdata), .wren_a(|a_be), .byteena_a(a_be),
        .address_b(b_addr), .q_b(b_rdata),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
        .rden_a(1'b1), .rden_b(1'b1), .eccstatus(), .q_a(), .data_b('1), .wren_b(1'b0),
        .byteena_b(1'b1), .clock1(1'b1)
    );
`endif

endmodule
