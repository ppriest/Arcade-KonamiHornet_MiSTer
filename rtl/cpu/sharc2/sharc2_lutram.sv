// SPDX-License-Identifier: GPL-3.0-or-later
//
// A small register array in MLAB: one write port (written at the clock edge), one read port read
// combinationally (the data of the address this clock). Quartus 17 does not infer an MLAB from
// an asynchronous read ("uninferred due to asynchronous read logic") and builds registers; the
// altdpram below is the MLAB (altsyncram has no unregistered read address). Simulators run the model.

module sharc2_lutram #(
    parameter int AW = 5,
    parameter int DW = 32
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] wa,
    input  logic [DW-1:0] wd,
    input  logic [AW-1:0] ra,
    output logic [DW-1:0] rd
);

`ifndef ALTERA_RESERVED_QIS
    logic [DW-1:0] mem [1 << AW];
    always_ff @(posedge clk) if (we) mem[wa] <= wd;
    assign rd = mem[ra];
`else
    altdpram #(
        .intended_device_family("Cyclone V"),
        .ram_block_type("MLAB"),
        .lpm_type("altdpram"),
        .width(DW), .widthad(AW), .numwords(1 << AW),
        .indata_reg("INCLOCK"), .wraddress_reg("INCLOCK"), .wrcontrol_reg("INCLOCK"),
        .rdaddress_reg("UNREGISTERED"), .rdcontrol_reg("UNREGISTERED"), .outdata_reg("UNREGISTERED"),
        .read_during_write_mode_mixed_ports("CONSTRAINED_DONT_CARE")
    ) u_ram (
        .inclock(clk), .inclocken(1'b1), .outclock(1'b1), .outclocken(1'b1),
        .data(wd), .wraddress(wa), .wren(we), .rdaddress(ra), .rden(1'b1), .q(rd),
        .aclr(1'b0), .byteena(1'b1), .rdaddressstall(1'b0), .wraddressstall(1'b0)
    );
`endif

endmodule
