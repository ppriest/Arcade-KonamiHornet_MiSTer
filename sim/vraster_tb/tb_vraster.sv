// SPDX-License-Identifier: GPL-3.0-or-later
// vraster under sim/voodoo_tb's harness (its main.cpp, VTOP Vtb_vraster).
module tb_vraster (
  input wire [21:0] io_h2fLw_address,
  input wire io_h2fLw_read,
  input wire io_h2fLw_write,
  input wire [3:0] io_h2fLw_byteenable,
  input wire [31:0] io_h2fLw_writedata,
  output wire io_h2fLw_waitrequest,
  output wire [31:0] io_h2fLw_readdata,
  output wire io_h2fLw_readdatavalid,
  output wire io_memFbWrite_read,
  output wire io_memFbWrite_write,
  input wire io_memFbWrite_waitRequestn,
  output wire [31:0] io_memFbWrite_address,
  output wire [10:0] io_memFbWrite_burstCount,
  output wire [3:0] io_memFbWrite_byteEnable,
  output wire [31:0] io_memFbWrite_writeData,
  output wire [31:0] io_memFbWrite_writeDataHi,
  output wire [3:0] io_memFbWrite_byteEnableHi,
  input wire io_memFbWrite_readDataValid,
  input wire [31:0] io_memFbWrite_readData,
  output wire io_memFbColorWrite_read,
  output wire io_memFbColorWrite_write,
  input wire io_memFbColorWrite_waitRequestn,
  output wire [31:0] io_memFbColorWrite_address,
  output wire [10:0] io_memFbColorWrite_burstCount,
  output wire [3:0] io_memFbColorWrite_byteEnable,
  output wire [31:0] io_memFbColorWrite_writeData,
  output wire [31:0] io_memFbColorWrite_writeDataHi,
  output wire [3:0] io_memFbColorWrite_byteEnableHi,
  input wire io_memFbColorWrite_readDataValid,
  input wire [31:0] io_memFbColorWrite_readData,
  output wire io_memFbAuxWrite_read,
  output wire io_memFbAuxWrite_write,
  input wire io_memFbAuxWrite_waitRequestn,
  output wire [31:0] io_memFbAuxWrite_address,
  output wire [10:0] io_memFbAuxWrite_burstCount,
  output wire [3:0] io_memFbAuxWrite_byteEnable,
  output wire [31:0] io_memFbAuxWrite_writeData,
  output wire [31:0] io_memFbAuxWrite_writeDataHi,
  output wire [3:0] io_memFbAuxWrite_byteEnableHi,
  input wire io_memFbAuxWrite_readDataValid,
  input wire [31:0] io_memFbAuxWrite_readData,
  output wire io_memFbColorRead_read,
  output wire io_memFbColorRead_write,
  input wire io_memFbColorRead_waitRequestn,
  output wire [31:0] io_memFbColorRead_address,
  output wire [10:0] io_memFbColorRead_burstCount,
  output wire [3:0] io_memFbColorRead_byteEnable,
  output wire [31:0] io_memFbColorRead_writeData,
  input wire io_memFbColorRead_readDataValid,
  input wire [31:0] io_memFbColorRead_readData,
  input wire [31:0] io_memFbColorRead_readDataHi,
  output wire io_memFbAuxRead_read,
  output wire io_memFbAuxRead_write,
  input wire io_memFbAuxRead_waitRequestn,
  output wire [31:0] io_memFbAuxRead_address,
  output wire [10:0] io_memFbAuxRead_burstCount,
  output wire [3:0] io_memFbAuxRead_byteEnable,
  output wire [31:0] io_memFbAuxRead_writeData,
  input wire io_memFbAuxRead_readDataValid,
  input wire [31:0] io_memFbAuxRead_readData,
  input wire [31:0] io_memFbAuxRead_readDataHi,
  output wire io_memFbColorRead_readReady,
  output wire io_memFbAuxRead_readReady,
  input wire [31:0] io_memTex_readDataHi,
  output wire [31:0] io_memTex_writeDataHi,
  output wire [3:0] io_memTex_byteEnableHi,
  output wire io_memTex_readReady,
  output wire io_memTex_read,
  output wire io_memTex_write,
  input wire io_memTex_waitRequestn,
  output wire [31:0] io_memTex_address,
  output wire [10:0] io_memTex_burstCount,
  output wire [3:0] io_memTex_byteEnable,
  output wire [31:0] io_memTex_writeData,
  input wire io_memTex_readDataValid,
  input wire [31:0] io_memTex_readData,
  output wire io_memFifo_read,
  output wire io_memFifo_write,
  input wire io_memFifo_waitRequestn,
  output wire [31:0] io_memFifo_address,
  output wire [10:0] io_memFifo_burstCount,
  output wire [3:0] io_memFifo_byteEnable,
  output wire [31:0] io_memFifo_writeData,
  output wire [31:0] io_memFifo_writeDataHi,
  output wire [3:0] io_memFifo_byteEnableHi,
  input wire [31:0] io_memFifo_readDataHi,
  input wire io_memFifo_readDataValid,
  input wire [31:0] io_memFifo_readData,
  input wire io_hdmi_clock,
  input wire io_hdmi_reset,
  output wire [7:0] io_hdmi_video_rgb_r,
  output wire [7:0] io_hdmi_video_rgb_g,
  output wire [7:0] io_hdmi_video_rgb_b,
  output wire io_hdmi_video_de,
  output wire io_hdmi_video_hSync,
  output wire io_hdmi_video_vSync,
  output wire [0:0] io_hdmi_status_displayedBuffer,
  output wire [25:0] io_hdmi_status_displayedBase,
  output wire io_hdmi_status_swapPending,
  output wire [1:0] io_hdmi_status_swapCount,
  output wire io_hdmi_status_newFrame,
  output wire io_hdmi_status_active,
  output wire [9:0] io_hdmi_status_x,
  output wire [9:0] io_hdmi_status_y,
  output wire io_hdmi_underflow,
  output wire [12:0] io_hdmi_fifoLevel,
  input wire clk,
  input wire reset
);
    // vblank for MAME's swap-on-retrace: a short pulse every VBL_PERIOD clocks
    localparam int VBL_PERIOD = 50000;
    logic [16:0] vcnt;
    always_ff @(posedge clk) vcnt <= (reset || vcnt == VBL_PERIOD - 1) ? 17'd0 : vcnt + 17'd1;
    wire vretrace = vcnt < 17'd1000;
    assign io_hdmi_video_rgb_r = 8'h0; assign io_hdmi_video_rgb_g = 8'h0; assign io_hdmi_video_rgb_b = 8'h0;
    assign io_hdmi_video_de = 1'b0; assign io_hdmi_video_hSync = 1'b0; assign io_hdmi_video_vSync = 1'b0;
    assign io_hdmi_status_displayedBase = 26'h0; assign io_hdmi_status_swapPending = 1'b0;
    assign io_hdmi_status_swapCount = 2'h0; assign io_hdmi_status_newFrame = 1'b0; assign io_hdmi_status_active = 1'b0;
    assign io_hdmi_status_x = 10'h0; assign io_hdmi_status_y = 10'h0; assign io_hdmi_underflow = 1'b0;
    assign io_hdmi_fifoLevel = 13'h0;
    logic [1:0] disp;
    assign io_hdmi_status_displayedBuffer = disp[0];
    vraster dut (
        .io_h2fLw_address(io_h2fLw_address),
        .io_h2fLw_read(io_h2fLw_read),
        .io_h2fLw_write(io_h2fLw_write),
        .io_h2fLw_byteenable(io_h2fLw_byteenable),
        .io_h2fLw_writedata(io_h2fLw_writedata),
        .io_h2fLw_waitrequest(io_h2fLw_waitrequest),
        .io_h2fLw_readdata(io_h2fLw_readdata),
        .io_h2fLw_readdatavalid(io_h2fLw_readdatavalid),
        .io_memFbWrite_read(io_memFbWrite_read),
        .io_memFbAuxRead_readDataHi(io_memFbAuxRead_readDataHi),
        .io_memFbColorRead_readReady(io_memFbColorRead_readReady), .io_memFbAuxRead_readReady(io_memFbAuxRead_readReady),
        .io_memTex_readDataHi(io_memTex_readDataHi), .io_memTex_writeDataHi(io_memTex_writeDataHi),
        .io_memTex_byteEnableHi(io_memTex_byteEnableHi), .io_memTex_readReady(io_memTex_readReady),
        .io_memFbColorRead_readDataHi(io_memFbColorRead_readDataHi),
        .io_memFbAuxWrite_writeDataHi(io_memFbAuxWrite_writeDataHi), .io_memFbAuxWrite_byteEnableHi(io_memFbAuxWrite_byteEnableHi),
        .io_memFbColorWrite_writeDataHi(io_memFbColorWrite_writeDataHi), .io_memFbColorWrite_byteEnableHi(io_memFbColorWrite_byteEnableHi),
        .io_memFbWrite_writeDataHi(io_memFbWrite_writeDataHi), .io_memFbWrite_byteEnableHi(io_memFbWrite_byteEnableHi),
        .io_memFbWrite_write(io_memFbWrite_write),
        .io_memFbWrite_waitRequestn(io_memFbWrite_waitRequestn),
        .io_memFbWrite_address(io_memFbWrite_address),
        .io_memFbWrite_burstCount(io_memFbWrite_burstCount),
        .io_memFbWrite_byteEnable(io_memFbWrite_byteEnable),
        .io_memFbWrite_writeData(io_memFbWrite_writeData),
        .io_memFbWrite_readDataValid(io_memFbWrite_readDataValid),
        .io_memFbWrite_readData(io_memFbWrite_readData),
        .io_memFbColorWrite_read(io_memFbColorWrite_read),
        .io_memFbColorWrite_write(io_memFbColorWrite_write),
        .io_memFbColorWrite_waitRequestn(io_memFbColorWrite_waitRequestn),
        .io_memFbColorWrite_address(io_memFbColorWrite_address),
        .io_memFbColorWrite_burstCount(io_memFbColorWrite_burstCount),
        .io_memFbColorWrite_byteEnable(io_memFbColorWrite_byteEnable),
        .io_memFbColorWrite_writeData(io_memFbColorWrite_writeData),
        .io_memFbColorWrite_readDataValid(io_memFbColorWrite_readDataValid),
        .io_memFbColorWrite_readData(io_memFbColorWrite_readData),
        .io_memFbAuxWrite_read(io_memFbAuxWrite_read),
        .io_memFbAuxWrite_write(io_memFbAuxWrite_write),
        .io_memFbAuxWrite_waitRequestn(io_memFbAuxWrite_waitRequestn),
        .io_memFbAuxWrite_address(io_memFbAuxWrite_address),
        .io_memFbAuxWrite_burstCount(io_memFbAuxWrite_burstCount),
        .io_memFbAuxWrite_byteEnable(io_memFbAuxWrite_byteEnable),
        .io_memFbAuxWrite_writeData(io_memFbAuxWrite_writeData),
        .io_memFbAuxWrite_readDataValid(io_memFbAuxWrite_readDataValid),
        .io_memFbAuxWrite_readData(io_memFbAuxWrite_readData),
        .io_memFbColorRead_read(io_memFbColorRead_read),
        .io_memFbColorRead_write(io_memFbColorRead_write),
        .io_memFbColorRead_waitRequestn(io_memFbColorRead_waitRequestn),
        .io_memFbColorRead_address(io_memFbColorRead_address),
        .io_memFbColorRead_burstCount(io_memFbColorRead_burstCount),
        .io_memFbColorRead_byteEnable(io_memFbColorRead_byteEnable),
        .io_memFbColorRead_writeData(io_memFbColorRead_writeData),
        .io_memFbColorRead_readDataValid(io_memFbColorRead_readDataValid),
        .io_memFbColorRead_readData(io_memFbColorRead_readData),
        .io_memFbAuxRead_read(io_memFbAuxRead_read),
        .io_memFbAuxRead_write(io_memFbAuxRead_write),
        .io_memFbAuxRead_waitRequestn(io_memFbAuxRead_waitRequestn),
        .io_memFbAuxRead_address(io_memFbAuxRead_address),
        .io_memFbAuxRead_burstCount(io_memFbAuxRead_burstCount),
        .io_memFbAuxRead_byteEnable(io_memFbAuxRead_byteEnable),
        .io_memFbAuxRead_writeData(io_memFbAuxRead_writeData),
        .io_memFbAuxRead_readDataValid(io_memFbAuxRead_readDataValid),
        .io_memFbAuxRead_readData(io_memFbAuxRead_readData),
        .io_memTex_read(io_memTex_read),
        .io_memTex_write(io_memTex_write),
        .io_memTex_waitRequestn(io_memTex_waitRequestn),
        .io_memTex_address(io_memTex_address),
        .io_memTex_burstCount(io_memTex_burstCount),
        .io_memTex_byteEnable(io_memTex_byteEnable),
        .io_memTex_writeData(io_memTex_writeData),
        .io_memTex_readDataValid(io_memTex_readDataValid),
        .io_memTex_readData(io_memTex_readData),
        .io_memFifo_read(io_memFifo_read), .io_memFifo_write(io_memFifo_write),
        .io_memFifo_writeDataHi(io_memFifo_writeDataHi), .io_memFifo_byteEnableHi(io_memFifo_byteEnableHi),
        .io_memFifo_readDataHi(io_memFifo_readDataHi),
        .io_memFifo_waitRequestn(io_memFifo_waitRequestn), .io_memFifo_address(io_memFifo_address),
        .io_memFifo_burstCount(io_memFifo_burstCount), .io_memFifo_byteEnable(io_memFifo_byteEnable),
        .io_memFifo_writeData(io_memFifo_writeData), .io_memFifo_readDataValid(io_memFifo_readDataValid),
        .io_memFifo_readData(io_memFifo_readData),
        .io_vRetrace(vretrace), .io_displayedBuffer(disp), .io_buffer0Base(), .io_buffer1Base(), .io_pixelStride(),
        .clk, .reset
    );

    // where the clocks go: printed at the end (main.cpp calls final)
    longint c_fill, c_all, c_ts [16], c_rs [4], c_ws [4], c_px, c_stall, c_sdwait, c_cs [16];
    always_ff @(posedge clk) if (!reset) begin
        c_all <= c_all + 1;
        c_ts[int'(dut.ts)] <= c_ts[int'(dut.ts)] + 1;
        c_rs[int'(dut.rs)] <= c_rs[int'(dut.rs)] + 1;
        c_ws[int'(dut.ws)] <= c_ws[int'(dut.ws)] + 1;
        c_cs[int'(dut.cs)] <= c_cs[int'(dut.cs)] + 1;
        if (dut.px_run) c_px <= c_px + 1;
        if (dut.stall) c_stall <= c_stall + 1;
        if (int'(dut.fls) == 0 && dut.miss != 0) c_fill <= c_fill + 1;
        if (dut.sd_v && !dut.sd_take) c_sdwait <= c_sdwait + 1;
    end
    initial begin
        c_all = 0; c_fill = 0; c_px = 0; c_stall = 0; c_sdwait = 0;
        for (int k = 0; k < 16; k++) begin c_ts[k] = 0; c_cs[k] = 0; end
        for (int k = 0; k < 4; k++) begin c_rs[k] = 0; c_ws[k] = 0; end
    end
    final begin
        $display("profile: %0d clocks; pixels issued %0d, stalled %0d; span waiting for the reader %0d; tile fills %0d", c_all, c_px, c_stall, c_sdwait, c_fill);
        $display("  cmd  IDLE %0d LOAD %0d CONV %0d EXEC %0d ADJ %0d ADJ2 %0d FILL %0d SWAP %0d TRI %0d TEXW %0d",
                 c_cs[0], c_cs[1], c_cs[2], c_cs[3], c_cs[4], c_cs[5], c_cs[6], c_cs[7], c_cs[8], c_cs[9]);
        $display("  tri  IDLE %0d SORT %0d DIV %0d ROW0 %0d LINE %0d CLIP %0d SPAN %0d EMIT %0d NEXT %0d DRAIN %0d",
                 c_ts[0], c_ts[1], c_ts[2], c_ts[3], c_ts[4], c_ts[5], c_ts[6], c_ts[7], c_ts[8], c_ts[9]);
        $display("  read IDLE %0d REQ %0d; write IDLE %0d RUN %0d", c_rs[0], c_rs[1], c_ws[0], c_ws[1]);
    end
endmodule
