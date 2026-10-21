// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/mister/hornet_rotate.sv: a 512x384 picture (a pattern of x and y) through the video timing,
// the port taking beats at random; every beat written must hold, at each of its four pixels,
// the source pixel its address names, and each frame must write every beat of its buffer once.
//
//     scripts/run_verilator.sh rotate_tb [+ccw] [+wait=P] [+frames=N]

`timescale 1ns/1ps

module tb_rotate;

logic clk = 0;
always #7.8125 clk = !clk;

localparam int HS = 512, VS = 384, HT = 640, VT = 400;
logic        ce = 0, vs = 0, de = 0, enable = 1, ccw = 0, FB_VBL = 0, FB_LL = 0;
logic [7:0]  r, g, b;
logic        FB_EN;
logic [4:0]  FB_FORMAT;
logic [11:0] FB_WIDTH, FB_HEIGHT;
logic [31:0] FB_BASE;
logic [13:0] FB_STRIDE;
logic        m_write, m_waitn = 0;
logic [31:0] m_addr;
logic [63:0] m_wdata;
logic [15:0] dropped;

hornet_rotate dut (.*);

int wait_pct = 30, frames = 6, errors = 0, beats = 0, frame = 0;
function automatic logic [23:0] src(input int x, input int y);
    return {8'(x * 3 + y), 8'(y * 5 + (x >> 3)), 8'(x ^ y)};
endfunction
function automatic logic [15:0] p565(input logic [23:0] c);
    return {c[23:19], c[15:10], c[7:3]};                  // c is {b, g, r}
endfunction

// timing: a pixel every 4 clocks, HT x VT pixels a frame, vsync in the blank lines
int px = 0, py = 0, cc = 0;
always @(posedge clk) begin
    cc <= (cc + 1) % 4;
    ce <= cc == 3;
    if (cc == 3) begin
        px = px + 1;
        if (px == HT) begin px = 0; py = (py + 1) % VT; if (py == 0) frame++; end
        de <= px < HS && py < VS;
        vs <= py >= VS + 4 && py < VS + 8;
        {b, g, r} <= src(px, py);
    end
end

// the port; checks each beat against its address
always @(posedge clk) begin
    m_waitn <= $urandom_range(0, 99) >= wait_pct;
    if (m_write && m_waitn) begin
        int off, row, col, x, y;
        off = int'(m_addr - 32'h2400_0000) & 32'hF_FFFF;
        row = off / (VS * 2); col = (off % (VS * 2)) / 2;
        for (int k = 0; k < 4; k++) begin
            if (ccw) begin x = HS - 1 - row; y = col + k; end
            else begin x = row; y = VS - 1 - (col + k); end
            if (m_wdata[16*k +: 16] !== p565(src(x, y))) begin
                errors++;
                if (errors < 10) $display("beat at %08X pixel %0d: %04X, expected %04X (x %0d y %0d)",
                                          m_addr, k, m_wdata[16*k +: 16], p565(src(x, y)), x, y);
            end
        end
        beats++;
    end
end

initial begin
    int last;
    if ($test$plusargs("ccw")) ccw = 1;
    if ($value$plusargs("wait=%d", wait_pct)) ;
    if ($value$plusargs("frames=%d", frames)) ;
    // frames 0-3 settle the sizes and FB_EN; count beats over the rest
    while (frame < 4) @(posedge clk);
    last = beats;
    while (frame < frames) @(posedge clk);
    if (beats - last != (frames - 4) * HS * VS / 4) begin
        errors++; $display("%0d beats over %0d frames, expected %0d", beats - last, frames - 4, (frames - 4) * HS * VS / 4);
    end
    if (dropped != 0) begin errors++; $display("%0d beats dropped", dropped); end
    if (FB_WIDTH != VS || FB_HEIGHT != HS || FB_STRIDE != VS * 2) begin
        errors++; $display("FB %0dx%0d stride %0d", FB_WIDTH, FB_HEIGHT, FB_STRIDE);
    end
    $display("%s: %0d beats, %0d dropped, %0d errors", ccw ? "CCW" : "CW", beats, dropped, errors);
    if (errors == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

endmodule
