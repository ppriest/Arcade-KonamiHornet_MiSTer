#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write obj_verilator/tb_board.sv: hornet_board's own port list as module tb_board, for
scripts/run_verilator.sh (which builds tb_<bench>). Called by scripts/verilator_prep.sh.

Beside the board, hornet_ddr3 as KonamiHornet.sv wires it (the six Voodoo masters, the memory
FIFO's ring, port S at vraster's FB_BASE). With ddr3_en low the board's memory inputs are the
wrapper's (board_tb's per-port models); high, they come from hornet_ddr3, whose DDRAM port the
bench answers (board_tb +ddr3)."""
import re
from pathlib import Path

src = Path("rtl/board/hornet_board.sv").read_text()
m = re.search(r"module hornet_board (?:#\(.*?\n\) )?\((.*?)\n\);", src, re.S)
ports = m.group(1)

V = ["fbw", "fbcw", "fbaw", "fbcr", "fbar", "tex", "mf"]
lines = []
lines.append("    // hornet_ddr3 between the board's masters and the bench (+ddr3)")
lines.append("    wire [7:0]       dm_read, dm_write, dm_waitn, dm_rvalid;")
lines.append("    wire [7:0][31:0] dm_addr, dm_wdata;")
lines.append("    wire [7:0][10:0] dm_burst;")
lines.append("    wire [7:0][3:0]  dm_be;")
lines.append("    wire [31:0]      dm_rdata, dm_rdata_hi;")
lines.append("    wire [7:0][3:0]  dm_be_hi;")
lines.append("    wire [7:0][31:0] dm_wdata_hi;")
lines.append("    assign dm_be_hi[0] = v_fbw_be_hi; assign dm_wdata_hi[0] = v_fbw_wdata_hi;")
lines.append("    assign dm_be_hi[6] = v_mf_be_hi; assign dm_wdata_hi[6] = v_mf_wdata_hi;")
lines.append("    assign dm_be_hi[1] = v_fbcw_be_hi; assign dm_wdata_hi[1] = v_fbcw_wdata_hi;")
lines.append("    assign dm_be_hi[2] = v_fbaw_be_hi; assign dm_wdata_hi[2] = v_fbaw_wdata_hi;")
lines.append("    assign dm_be_hi[5] = v_tex_be_hi; assign dm_wdata_hi[5] = v_tex_wdata_hi;")
lines.append("    assign dm_be_hi[4:3] = '0; assign dm_wdata_hi[4:3] = '0; assign dm_be_hi[7] = '0; assign dm_wdata_hi[7] = '0;")
for i, n in enumerate(V):
    lines.append(f"    assign dm_read[{i}] = v_{n}_read; assign dm_write[{i}] = v_{n}_write; "
                 f"assign dm_addr[{i}] = v_{n}_addr; assign dm_burst[{i}] = v_{n}_burst; "
                 f"assign dm_be[{i}] = v_{n}_be; assign dm_wdata[{i}] = v_{n}_wdata;")
lines.append("    assign dm_read[7] = s_read; assign dm_write[7] = 1'b0; "
             "assign dm_addr[7] = 32'h3F40_0000 + {6'h0, s_addr}; assign dm_burst[7] = s_burst; "
             "assign dm_be[7] = 4'hF; assign dm_wdata[7] = 32'h0;")
lines.append("    hornet_ddr3 #(.N(8), .WIDE(8'b1111_1111), .PRI(5)) ddr3 (.clk, .reset, .drain(!run), .idle(),")
lines.append("        .m_read(dm_read), .m_write(dm_write), .m_addr(dm_addr), .m_burst(dm_burst), .m_be(dm_be),")
lines.append("        .m_wdata(dm_wdata), .m_waitn(dm_waitn), .m_rvalid(dm_rvalid), .m_rdata(dm_rdata),")
lines.append("        .m_rready({2'b11, v_tex_rready, v_fbar_rready, v_fbcr_rready, 3'b111}),")
lines.append("        .m_be_hi(dm_be_hi), .m_wdata_hi(dm_wdata_hi), .m_rdata_hi(dm_rdata_hi),")
lines.append("        .DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT, .DDRAM_DOUT_READY, .DDRAM_RD,")
lines.append("        .DDRAM_DIN, .DDRAM_BE, .DDRAM_WE, .dbg(ddr_dbg), .dbg_cmd());")
lines.append("    // +sdram: hornet_sdram and the 128 MB chip model answer ports A, B and C (the bench preloads")
lines.append("    // the chip)")
lines.append("    wire [15:0] SDRAM_DQ;")
lines.append("    wire [12:0] SDRAM_A;")
lines.append("    wire [1:0]  SDRAM_BA;")
lines.append("    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;")
lines.append("    wire        sd_a_ack;")
lines.append("    wire [31:0] sd_a_rdata, sd_b_rdata;")
lines.append("    wire        sd_b_ack, sd_c_ack;")
lines.append("    wire [127:0] sd_c_rdata;")
lines.append("    hornet_sdram sdram (.clk, .clk_mem(clk), .init(reset), .reset, .flush(!run), .a_dbg(2'b00),")
lines.append("        .SDRAM_A, .SDRAM_DQ, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS,")
lines.append("        .SDRAM_nCAS, .SDRAM_CLK, .SDRAM_CKE,")
lines.append("        .a_req(a_req && sdram_en), .a_we, .a_addr, .a_be, .a_wdata, .a_ack(sd_a_ack), .a_rdata(sd_a_rdata),")
lines.append("        .b_req(b_req && sdram_en), .b_we, .b_addr, .b_wdata, .b_left, .b_ack(sd_b_ack), .b_rdata(sd_b_rdata),")
lines.append("        .c_req(c_req && sdram_en), .c_addr, .c_ack(sd_c_ack), .c_rdata(sd_c_rdata),")
lines.append("        .d_we(1'b0), .d_addr(26'h0), .d_din(16'h0), .d_ready());")
lines.append("    sdram_chip_model_128 chip (.clk(SDRAM_CLK), .SDRAM_DQ, .SDRAM_A, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE,")
lines.append("        .SDRAM_nRAS, .SDRAM_nCAS);")
conn = [".a_ack(sdram_en ? sd_a_ack : a_ack), .a_rdata(sdram_en ? sd_a_rdata : a_rdata)",
        ".b_ack(sdram_en ? sd_b_ack : b_ack), .b_rdata(sdram_en ? sd_b_rdata : b_rdata)",
        ".c_ack(sdram_en ? sd_c_ack : c_ack), .c_rdata(sdram_en ? sd_c_rdata : c_rdata)"]
for i, n in enumerate(V):
    conn.append(f".v_{n}_waitn(ddr3_en ? dm_waitn[{i}] : v_{n}_waitn), "
                f".v_{n}_rvalid(ddr3_en ? dm_rvalid[{i}] : v_{n}_rvalid), "
                f".v_{n}_rdata(ddr3_en ? dm_rdata : v_{n}_rdata)")
conn.append(".v_mf_rdata_hi(ddr3_en ? dm_rdata_hi : v_mf_rdata_hi)")
conn.append(".v_fbcr_rdata_hi(ddr3_en ? dm_rdata_hi : v_fbcr_rdata_hi), .v_fbar_rdata_hi(ddr3_en ? dm_rdata_hi : v_fbar_rdata_hi)")
conn.append(".v_tex_rdata_hi(ddr3_en ? dm_rdata_hi : v_tex_rdata_hi)")
conn.append(".s_waitn(ddr3_en ? dm_waitn[7] : s_waitn), .s_rvalid(ddr3_en ? dm_rvalid[7] : s_rvalid), "
            ".s_rdata(ddr3_en ? dm_rdata : s_rdata), .s_rdata_hi(ddr3_en ? dm_rdata_hi : s_rdata_hi)")

extra = ("\n    input  logic        ddr3_en,\n    input  logic        sdram_en,\n"
         "    input  logic        DDRAM_BUSY,\n    output logic [7:0]  DDRAM_BURSTCNT,\n"
         "    output logic [28:0] DDRAM_ADDR,\n    input  logic [63:0] DDRAM_DOUT,\n"
         "    input  logic        DDRAM_DOUT_READY,\n    output logic        DDRAM_RD,\n"
         "    output logic [63:0] DDRAM_DIN,\n    output logic [7:0]  DDRAM_BE,\n"
         "    output logic        DDRAM_WE,\n    output logic [23:0] ddr_dbg")
out = Path("obj_verilator/tb_board.sv")
out.parent.mkdir(exist_ok=True)
text = ("// generated by scripts/board_wrapper.py from rtl/board/hornet_board.sv\n"
        "module tb_board (" + ports + "," + extra + "\n);\n" + "\n".join(lines) + "\n"
        "    hornet_board dut (.*,\n        " + ",\n        ".join(conn) + ");\nendmodule\n")
if not out.exists() or out.read_text() != text:
    out.write_text(text)
