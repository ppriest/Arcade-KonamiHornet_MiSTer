// SPDX-License-Identifier: GPL-3.0-or-later
// sharc2_pkg::shifter against shifter_ref (MAME's forms) on random operands, the shift values
// weighted to the edges.
//     scripts/run_verilator.sh shifter_tb
module tb_shifter;
import sharc2_pkg::*;
initial begin
    static logic [5:0] ops [14] = '{6'h00, 6'h08, 6'h01, 6'h02, 6'h10, 6'h11, 6'h12, 6'h13, 6'h19,
                                    6'h30, 6'h31, 6'h32, 6'h33, 6'h3f};
    longint bad = 0;
    for (int i = 0; i < 4000000; i++) begin
        logic [5:0]  sop;
        logic [31:0] sv, x, rnv;
        logic        imm;
        xres_t a, b;
        sop = ops[$urandom % 14];
        x = $urandom; rnv = $urandom; imm = $urandom % 2;
        case ($urandom % 4)
        0: sv = $urandom;
        1: sv = 32'($signed($urandom % 80) - 40);
        2: sv = {20'h0, 6'($urandom % 40), 6'($urandom % 40)};
        default: sv = {$urandom % 2 ? 24'hFFFFFF : 24'h0, 8'($urandom)};
        endcase
        if ($urandom % 8 == 0) x = 32'h8000_0000 >> ($urandom % 32);
        a = shifter(sop, sv, imm, 4'd3, x, rnv, 1'b0);
        b = shifter_ref(sop, sv, imm, 4'd3, x, rnv);
        if (a != b) begin
            if (bad < 10) $display("op %02X sval %08X imm %0d x %08X rn %08X: %08X %08X / ref %08X %08X",
                                   sop, sv, imm, x, rnv, a.d0, a.aset, b.d0, b.aset);
            bad++;
        end
    end
    $display("4000000 vectors, %0d differ", bad);
    $finish;
end
endmodule
