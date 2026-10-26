// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami Hornet (Gradius IV) for MiSTer: rtl/board/hornet_board.sv on the DE10-nano.
//
// Clocks (rtl/pll): clk_sys 64 MHz (the board, the picture at clk_sys/4, SDRAM, DDR3); SDRAM_CLK
// 64 MHz at 180 degrees; clk_dsp 48 MHz, the SHARC's (asynchronous to clk_sys in the SDC; the
// board crosses it, hornet_cdc).
// Memory (docs/ROADMAP.md, Phase 2 memory plan): the board's ports A, B and C on SDRAM
// (rtl/mister/hornet_sdram.sv), the Voodoo's six masters and the picture's port S on DDR3
// (rtl/mister/hornet_ddr3.sv).
//
// Download (ioctl index 0, the .mra's ROM image), byte offsets of the image:
//   0x0000000  program ROM, 4 MB    -> SDRAM 0x0400000 (port A region 1)
//   0x0400000  data ROM, 8 MB       -> SDRAM 0x0800000 (port A regions 2-3)
//   0x0C00000  CG ROM, 16 MB        -> SDRAM 0x2800000 (port B regions 2-5)
//   0x1C00000  M48T58, 8 KB         -> the board's NVRAM (its state-load port)
// Images are big-endian (scripts/rom_images.py); SDRAM holds a halfword's even byte on DQ[15:8].
// The .nvm file (<nvram index="4" size="8192">): the M48T58, loaded after the image with the
// board in reset, saved a second after the PPC's last write to it.
// DIP switches: ioctl index 254.

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

// HDMI rotation (hornet_rotate): Auto is Off, gradius4 being horizontal; 3:4 when rotated
wire [1:0] rot_sel    = status[64:63];
`ifdef MISTER_FB
wire       rotate_en  = rot_sel[1];
`else
wire       rotate_en  = 1'b0;                  // hornet_rotate not built (MISTER_FB off)
`endif
wire       rotate_ccw = rot_sel == 2'd3;
assign VIDEO_ARX = (!ar) ? (rotate_en ? 12'd3 : 12'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (rotate_en ? 12'd4 : 12'd3) : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"KonamiHornet;;",
	"-;",
	"H5O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
`ifdef MISTER_FB
	"H5O[64:63],Orientation,Auto,Off,CW,CCW;",
`endif
	"-;",
	"DIP;",
	"C,Cheats;",
	"O[7],Cheats Enabled,Yes,No;",
	"O[8],Slowdown indicator,Off,On;",
	"-;",
	"R[0],Reset and close OSD;",
	"J1,Power Up,Shot,Missile,Start,Coin,Service,Test,Pause;",
	"jn,A,B,X,Start,Select,R,L,Y;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire direct_video;
wire   [1:0] buttons;
wire [127:0] status;
wire  [31:0] joy_pad_0, joy_pad_1;
wire  [10:0] ps2_key;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;
wire        ioctl_upload;
wire  [7:0] ioctl_din;
reg         nvram_save = 1'b0;
wire [64:0] rtc;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({10'd0, direct_video, 5'd0}),
	.direct_video(direct_video),

	.joystick_0(joy_pad_0),
	.joystick_1(joy_pad_1),
	.ps2_key(ps2_key),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nvram_save),
	.ioctl_upload_index(8'd4),
	.ioctl_din(ioctl_din),
	.ioctl_rd(),

	.RTC(rtc)
);

// MAME's default keys beside the pads (rtl/mame_keys.sv), in the J1 line's layout: F2 the test
// switch, 9/0 the service coins
wire [31:0] key_0, key_1;
wire  [1:0] svc_coin;
mame_keys #(.BUTTONS(3), .START(7), .COIN(8), .PAUSE(11), .SERVICE(10)) u_keys
	(.clk(clk_sys), .ps2_key, .key0(key_0), .key1(key_1), .svc_coin);
wire [31:0] joystick_0 = joy_pad_0 | key_0 | {22'd0, svc_coin[0], 9'd0};
wire [31:0] joystick_1 = joy_pad_1 | key_1 | {22'd0, svc_coin[1], 9'd0};

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys, clk_dsp, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(SDRAM_CLK),
	.outclk_2(clk_dsp),
	.locked(pll_locked)
);

// pll_locked and RESET are asynchronous to clk_sys. As a synchronous reset, an edge can reach one
// register's data and its enable on different clocks: probe K read hornet_ddr3 waiting on a read it never
// issued, the board held in reset for good, in some placements and not others. Both come through these:
// sys_reset set while the PLL is unlocked and released on a clk_sys edge, RESET two flops in
reg [2:0] lock_q = 3'b000;
always @(posedge clk_sys or negedge pll_locked)
	if (!pll_locked) lock_q <= 3'b000;
	else lock_q <= {lock_q[1:0], 1'b1};
wire sys_reset = !lock_q[2];
reg [1:0] hps_rst_q = 2'b11;
always @(posedge clk_sys) hps_rst_q <= {hps_rst_q[0], RESET};

wire reset = hps_rst_q[1] | status[0] | buttons[1];

///////////////////////   DOWNLOAD   /////////////////////////////

wire rom_dl = ioctl_download && ioctl_index == 16'd0;
wire nv_dl  = ioctl_download && ioctl_index == 16'd4;

// Fast loading: an index-0 download that delivers no bytes put the image in DDR3 at 0x30000000
// (the .mra's address=); when that download ends hornet_rom_loader replays it into the byte path
// below, once per download (or at the next reset release). A .nvm loaded since keeps the M48T58.
wire        ldr_active, ldr_wr;
wire        ddr_idle;
wire [26:0] ldr_addr;
wire  [7:0] ldr_dout;
wire        img_dl   = rom_dl || ldr_active;
wire        img_wr   = ldr_active ? ldr_wr : ioctl_wr;
wire [26:0] img_addr = ldr_active ? ldr_addr : ioctl_addr;
wire  [7:0] img_dout = ldr_active ? ldr_dout : ioctl_dout;
reg rom_dl_q, dl0_seen, dl_seen_wr, ldr_done, ldr_pending, ldr_start, nv_seen;
wire ldr_due = ldr_pending && dl0_seen && !dl_seen_wr && !ldr_done;
always @(posedge clk_sys) begin
	ldr_start <= 1'b0;
	rom_dl_q <= rom_dl;
	if (rom_dl && !rom_dl_q) begin dl0_seen <= 1'b1; dl_seen_wr <= 1'b0; ldr_done <= 1'b0; nv_seen <= 1'b0; end
	else if (rom_dl && ioctl_wr) dl_seen_wr <= 1'b1;
	if (nv_dl) nv_seen <= 1'b1;
	// armed by a reset or by the end of an index-0 download (the HPS need not reset the core after
	// putting the image in DDR3: without this the board ran on what the SDRAM held)
	if (reset || (rom_dl_q && !rom_dl)) ldr_pending <= 1'b1;
	else if (ldr_pending && !ioctl_download && !ldr_active && ddr_idle) begin
		ldr_pending <= 1'b0;
		if (ldr_due) begin ldr_start <= 1'b1; ldr_done <= 1'b1; end
	end
end

// DIP switches
reg [7:0] dsw = 8'h7A;                  // gradius4's defaults (hornet.cpp), Monitor Type 15KHz
always @(posedge clk_sys) if (ioctl_wr && ioctl_index == 16'd254 && ioctl_addr == 27'd0) dsw <= ioctl_dout;

// cheats (ioctl index 255): the active codes, 16 bytes each, little-endian words, into the board's
// store a word at a time (16 codes); their number when the download ends (Main_MiSTer sends 2 bytes
// when none is active)
wire        cht_dl = ioctl_download && ioctl_index == 16'd255;
reg  [31:0] cht_sh, cht_wd;
reg         cht_we, cht_dl_q;
reg   [5:0] cht_wa;
reg   [8:0] cht_top;
reg   [4:0] cht_n;
always @(posedge clk_sys) begin
	cht_we <= 1'b0;
	cht_dl_q <= cht_dl;
	if (cht_dl && !cht_dl_q) cht_top <= 9'd0;
	if (cht_dl && ioctl_wr && ioctl_addr[26:8] == 0) begin
		cht_sh <= {ioctl_dout, cht_sh[31:8]};
		if (ioctl_addr[1:0] == 2'd3) begin cht_we <= 1'b1; cht_wa <= ioctl_addr[7:2]; cht_wd <= {ioctl_dout, cht_sh[31:8]}; end
		cht_top <= ioctl_addr[8:0] + 9'd1;
	end
	if (!cht_dl && cht_dl_q) cht_n <= cht_top[8] ? 5'd16 : {1'b0, cht_top[7:4]};
	if (sys_reset) cht_n <= 5'd0;
end

// the image's bytes: ROM halfwords to the SDRAM, the M48T58 bytes to the board
reg  [7:0]  dl_hi;                      // the halfword's even byte
reg         d_we;
reg  [25:0] d_addr;
reg  [15:0] d_din;
wire        d_ready;
reg         ld_we;
reg  [16:0] ld_addr;
reg  [31:0] ld_data;

function automatic [26:0] dl_map(input [26:0] a);       // image offset -> SDRAM byte address
	if (a < 27'h0400000)      dl_map = 27'h0400000 + a;
	else if (a < 27'h0C00000) dl_map = 27'h0800000 + (a - 27'h0400000);
	else                      dl_map = 27'h2800000 + (a - 27'h0C00000);
endfunction

wire [26:0] dl_a = dl_map(img_addr);

always @(posedge clk_sys) begin
	ld_we <= 1'b0;
	if (d_we && d_ready) d_we <= 1'b0;
	if (nv_dl && ioctl_wr && !ioctl_addr[26:13]) begin
		ld_we <= 1'b1; ld_addr <= {4'h0, ioctl_addr[12:0]}; ld_data <= {24'h0, ioctl_dout};
	end
	if (img_dl && img_wr) begin
		if (img_addr >= 27'h1C00000 && img_addr < 27'h1C02000) begin
			if (!(ldr_active && nv_seen)) ld_we <= 1'b1;
			ld_addr <= {4'h0, img_addr[12:0]}; ld_data <= {24'h0, img_dout};
		end else if (img_addr >= 27'h1C00000) ;             // the sound board's ROMs: the HPS reads them
		else if (!img_addr[0]) dl_hi <= img_dout;
		else begin
			d_we <= 1'b1;
			d_addr <= dl_a[26:1];
			d_din <= {dl_hi, img_dout};
		end
	end
end
assign ioctl_wait = d_we;

// the board runs once the image is in
// ... and stays in reset until the DDR3 port has finished what the board started (a transaction
// cut short there hangs the HPS port: hornet_ddr3 drain)
reg board_reset = 1'b1;
always @(posedge clk_sys) board_reset <= reset || rom_dl || nv_dl || sys_reset || ldr_due || ldr_start || ldr_active
                                         || (board_reset && !ddr_idle);
// the M48T58's clock takes the host's time as the board leaves reset (MAME: once, at start)
reg board_reset_q = 1'b1;
always @(posedge clk_sys) board_reset_q <= board_reset;
wire rtc_set = board_reset_q && !board_reset;

// the .nvm save: requested once the PPC has not written the M48T58 for a second, so a burst of
// writes costs one SD-card write, or 10 s after the first unsaved write if the writes go on
wire        nv_wr;
reg         nv_dirty = 1'b0;
reg  [25:0] nv_quiet = 26'd0;
reg  [25:0] nv_sec = 26'd0;
reg  [3:0]  nv_age = 4'd0;              // whole seconds dirty
always @(posedge clk_sys) begin
	nvram_save <= 1'b0;
	if (nv_dirty) begin
		nv_sec <= (nv_sec == 26'd63_999_999) ? 26'd0 : nv_sec + 26'd1;
		if (nv_sec == 26'd63_999_999) nv_age <= nv_age + 4'd1;
	end
	if (nv_wr) begin
		if (!nv_dirty) begin nv_sec <= 26'd0; nv_age <= 4'd0; end
		nv_dirty <= 1'b1;
		nv_quiet <= 26'd0;
	end else if (nv_dirty) nv_quiet <= nv_quiet + 26'd1;
	if (nv_dirty && (nv_quiet == 26'd63_999_999 || nv_age == 4'd10)) begin
		nv_dirty   <= 1'b0;
		nvram_save <= 1'b1;
	end
	if (board_reset) nv_dirty <= 1'b0;
end

///////////////////////   BOARD   ////////////////////////////////

wire        a_req, a_we, a_ack;
wire [22:0] a_addr;
wire [3:0]  a_be;
wire [31:0] a_wdata, a_rdata;
wire        b_req, b_we, b_ack;
wire [22:0] b_addr;
wire [31:0] b_wdata, b_rdata;
wire  [2:0] b_left;
wire        c_req, c_ack;
wire [18:0] c_addr;
wire [127:0] c_rdata;
wire        s_read, s_waitn, s_rvalid;
wire [25:0] s_addr;
wire [10:0] s_burst;
wire [31:0] s_rdata, s_rdata_hi;

wire        vid_ce, vid_de, vid_hb, vid_vb, vid_hs, vid_vs;
wire        vblank, ppc_exec, dsp_exec, dsp_idle, dsp_unsup;
wire        vid_overrun, ev_swapcmd, ev_v_write, ev_v_wait;
wire [1:0]  v_displayed;
wire [25:0] v_base0;
wire [15:0] v_dbg;
wire        v_ring_off, v_ring_bad;
wire [1:0]  sd_dbg;                     // hornet_sdram's port A debug switches (probe F's source)
`ifndef DEBUG_ISSP
assign v_ring_off = 1'b0;
assign sd_dbg = 2'b00;
`endif
wire [31:0] ppc_pc;
wire [23:0] dsp_pc;
wire [7:0]  vid_r, vid_g, vid_b;
wire [9:0]  vid_x, vid_y;
wire        snd_wr, snd_live;
wire [3:0]  snd_wreg;
wire [7:0]  snd_wdata;
wire [15:0] snd_reply;

// hornet_ddr3's masters: the Voodoo's fbw, fbcw, fbaw, fbcr, fbar, tex and its memory FIFO's
// ring, the HDMI rotator, then port S (the last is served first)
wire [8:0]       m_read, m_write, m_waitn, m_rvalid, m_rready;
assign m_rready[2:0] = '1; assign m_rready[8:6] = '1;   // all but vraster's frame-buffer reads always take
wire [8:0][31:0] m_addr, m_wdata;
wire [8:0][10:0] m_burst;
wire [8:0][3:0]  m_be;
wire [31:0]      m_rdata;
// wide masters: the fast fill (0), the span writes (1, 2) and reads (3, 4), the memory FIFO's
// ring (6), the rotator (7), port S (8); the texture master (5) narrow
localparam logic [8:0] DDR_WIDE = 9'b1_1111_1111;
wire [8:0][3:0]  m_be_hi;
wire [8:0][31:0] m_wdata_hi;
assign m_be_hi[4:3] = '0; assign m_be_hi[8] = '0;
assign m_wdata_hi[4:3] = '0; assign m_wdata_hi[8] = '0;
wire [31:0]      m_rdata_hi;

// players 1 and 2: J1's bits 0-3 right, left, down, up; 4-6 Power Up, Shot, Missile (buttons 1-3); 7 Start,
// 8 Coin, 9 Service, 10 Test (hornet.cpp INPUT_PORTS hornet: active low); 11 Pause, a toggle
reg pause = 1'b0, pause_b = 1'b0;
always @(posedge clk_sys) begin
	pause_b <= joystick_0[11] | joystick_1[11];
	if ((joystick_0[11] | joystick_1[11]) && !pause_b) pause <= !pause;
	if (board_reset) pause <= 1'b0;
end
function automatic [7:0] player(input [31:0] j);
	player = ~{j[7], j[3], j[2], j[1], j[0], j[4], j[5], j[6]};
endfunction
wire [7:0] in0 = player(joystick_0);
wire [7:0] in1 = player(joystick_1);
// IN2: coin 1, coin 2, service 1, test, service 2
wire [7:0] in2 = ~{joystick_0[8], joystick_1[8], joystick_0[9], joystick_0[10] | joystick_1[10],
                   joystick_1[9], 3'b000};

hornet_board board (
	.clk(clk_sys), .clk_dsp, .reset(board_reset),
	.a_req, .a_we, .a_addr, .a_be, .a_wdata, .a_ack, .a_rdata,
	.b_req, .b_we, .b_addr, .b_wdata, .b_left, .b_ack, .b_rdata,
	.cht_we, .cht_wa, .cht_wd, .cht_n(status[7] ? 5'd0 : cht_n),
	.c_req, .c_addr, .c_ack, .c_rdata,
	.s_read, .s_addr, .s_burst, .s_waitn, .s_rvalid, .s_rdata, .s_rdata_hi,
	.vid_ce, .vid_de, .vid_x, .vid_y, .vid_r, .vid_g, .vid_b,
	.vid_hb, .vid_vb, .vid_hs, .vid_vs, .vid_overrun(vid_overrun),
	.v_fbw_read(m_read[0]),  .v_fbw_write(m_write[0]),  .v_fbw_waitn(m_waitn[0]),
	.v_fbcw_read(m_read[1]), .v_fbcw_write(m_write[1]), .v_fbcw_waitn(m_waitn[1]),
	.v_fbaw_read(m_read[2]), .v_fbaw_write(m_write[2]), .v_fbaw_waitn(m_waitn[2]),
	.v_fbcr_read(m_read[3]), .v_fbcr_write(m_write[3]), .v_fbcr_waitn(m_waitn[3]),
	.v_fbar_read(m_read[4]), .v_fbar_write(m_write[4]), .v_fbar_waitn(m_waitn[4]),
	.v_tex_read(m_read[5]),  .v_tex_write(m_write[5]),  .v_tex_waitn(m_waitn[5]),
	.v_fbw_addr(m_addr[0]), .v_fbcw_addr(m_addr[1]), .v_fbaw_addr(m_addr[2]),
	.v_fbcr_addr(m_addr[3]), .v_fbar_addr(m_addr[4]), .v_tex_addr(m_addr[5]),
	.v_fbw_burst(m_burst[0]), .v_fbcw_burst(m_burst[1]), .v_fbaw_burst(m_burst[2]),
	.v_fbcr_burst(m_burst[3]), .v_fbar_burst(m_burst[4]), .v_tex_burst(m_burst[5]),
	.v_fbw_be(m_be[0]), .v_fbcw_be(m_be[1]), .v_fbaw_be(m_be[2]),
	.v_fbcr_be(m_be[3]), .v_fbar_be(m_be[4]), .v_tex_be(m_be[5]),
	.v_fbw_wdata(m_wdata[0]), .v_fbcw_wdata(m_wdata[1]), .v_fbaw_wdata(m_wdata[2]),
	.v_fbw_wdata_hi(m_wdata_hi[0]), .v_fbw_be_hi(m_be_hi[0]),
	.v_fbcw_wdata_hi(m_wdata_hi[1]), .v_fbcw_be_hi(m_be_hi[1]), .v_fbaw_wdata_hi(m_wdata_hi[2]), .v_fbaw_be_hi(m_be_hi[2]),
	.v_fbcr_rdata_hi(m_rdata_hi), .v_fbar_rdata_hi(m_rdata_hi),
	.v_mf_wdata_hi(m_wdata_hi[6]), .v_mf_be_hi(m_be_hi[6]), .v_mf_rdata_hi(m_rdata_hi),
	.v_fbcr_wdata(m_wdata[3]), .v_fbar_wdata(m_wdata[4]), .v_tex_wdata(m_wdata[5]),
	.v_fbw_rvalid(m_rvalid[0]), .v_fbcw_rvalid(m_rvalid[1]), .v_fbaw_rvalid(m_rvalid[2]),
	.v_fbcr_rvalid(m_rvalid[3]), .v_fbar_rvalid(m_rvalid[4]), .v_tex_rvalid(m_rvalid[5]),
	.v_fbcr_rready(m_rready[3]), .v_fbar_rready(m_rready[4]), .v_tex_rready(m_rready[5]),
	.v_tex_rdata_hi(m_rdata_hi), .v_tex_wdata_hi(m_wdata_hi[5]), .v_tex_be_hi(m_be_hi[5]),
	.v_fbw_rdata(m_rdata), .v_fbcw_rdata(m_rdata), .v_fbaw_rdata(m_rdata),
	.v_fbcr_rdata(m_rdata), .v_fbar_rdata(m_rdata), .v_tex_rdata(m_rdata),
	.v_mf_read(m_read[6]), .v_mf_write(m_write[6]), .v_mf_waitn(m_waitn[6]), .v_mf_addr(m_addr[6]),
	.v_mf_burst(m_burst[6]), .v_mf_be(m_be[6]), .v_mf_wdata(m_wdata[6]), .v_mf_rvalid(m_rvalid[6]),
	.v_mf_rdata(m_rdata),
	.in0, .in1, .in2, .in3(8'hF0), .dsw,
	.rtc_set, .rtc_time(rtc[55:0]),
	.nvu_addr(ioctl_addr[12:0]), .nvu_q(ioctl_din), .nv_wr,
	.pause,
	.vblank(vblank), .vpos(), .v_displayed(v_displayed), .v_base0(v_base0), .v_base1(),
	.ev_swapcmd(ev_swapcmd), .ev_v_write(ev_v_write), .ev_v_wait(ev_v_wait), .v_dbg(v_dbg),
	.v_ring_off, .v_ring_bad,
	.run(!board_reset), .ld_we, .ld_sel(4'd2), .ld_addr, .ld_data,
	.ld_v_we(1'b0), .ld_v_addr(22'h0), .ld_v_data(32'h0), .ld_v_busy(),
	.ppc_dbg_exec(ppc_exec), .ppc_dbg_pc(ppc_pc), .ppc_dbg_sel(6'd0), .ppc_dbg_val(),
	.ppc_dbg_we(1'b0), .ppc_dbg_wsel(6'd0), .ppc_dbg_wdata(32'h0),
	.dsp_dbg_exec(dsp_exec), .dsp_dbg_pc(dsp_pc), .dsp_dbg_op(), .dsp_dbg_sel(6'd0), .dsp_dbg_val(),
	.ev_dsp_idle(dsp_idle),
	.ev_dsp_unsup(dsp_unsup),
	.snd_wr, .snd_wreg, .snd_wdata, .snd_reply, .snd_live,
	.dsp_dbg_pm_we(1'b0), .dsp_dbg_pm_addr(15'h0), .dsp_dbg_pm_wdata(48'h0),
	.dsp_dbg_dm_we(1'b0), .dsp_dbg_dm_addr(15'h0), .dsp_dbg_dm_wdata(32'h0),
	.dsp_dbg_we(1'b0), .dsp_dbg_wsel(8'd0), .dsp_dbg_widx(6'd0), .dsp_dbg_wdata(64'h0)
);

// port S as master 8: frame-buffer offsets onto vraster's FB_BASE
assign m_read[8]  = s_read;
assign m_write[8] = 1'b0;
assign m_addr[8]  = 32'h3F40_0000 + {6'h0, s_addr};
assign m_burst[8] = s_burst;
assign m_be[8]    = 4'hF;
assign m_wdata[8] = 32'h0;
assign s_waitn    = m_waitn[8];
assign s_rvalid   = m_rvalid[8];
assign s_rdata    = m_rdata;
assign s_rdata_hi = m_rdata_hi;

///////////////////////   MEMORY   ///////////////////////////////

hornet_sdram sdram (
	.clk(clk_sys), .clk_mem(clk_sys), .init(sys_reset), .reset(sys_reset), .flush(board_reset), .a_dbg(sd_dbg),
	.SDRAM_A, .SDRAM_DQ, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE,
	.SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CLK(), .SDRAM_CKE,
	.a_req(a_req && !board_reset), .a_we, .a_addr, .a_be, .a_wdata, .a_ack, .a_rdata,
	.b_req(b_req && !board_reset), .b_we, .b_addr, .b_wdata, .b_left, .b_ack, .b_rdata,
	.c_req(c_req && !board_reset), .c_addr, .c_ack, .c_rdata,
	.d_we, .d_addr, .d_din, .d_ready
);

assign DDRAM_CLK = clk_sys;
wire  [7:0] h_burstcnt, l_burstcnt;
wire [28:0] h_addr, l_addr;
wire        h_rd, h_we, l_rd;
wire [23:0] ddr_dbg;
wire [77:0] ddr_cmd;
wire [42:0] ddr_ret;
wire        k_rst;                   // probe K's source bit 0: hornet_ddr3's reset
hornet_ddr3 #(.N(9), .WIDE(DDR_WIDE), .PRI(5)) ddr3 (     // 5: vraster's texture fills
	.clk(clk_sys), .reset(sys_reset || k_rst), .drain(board_reset), .idle(ddr_idle),
	.m_read, .m_write, .m_addr, .m_burst, .m_be, .m_wdata, .m_waitn, .m_rvalid, .m_rready, .m_rdata,
	.m_be_hi(m_be_hi), .m_wdata_hi(m_wdata_hi), .m_rdata_hi(m_rdata_hi),
	.DDRAM_BUSY(DDRAM_BUSY || ldr_active), .DDRAM_BURSTCNT(h_burstcnt), .DDRAM_ADDR(h_addr), .DDRAM_DOUT,
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY && !ldr_active), .DDRAM_RD(h_rd),
	.DDRAM_DIN, .DDRAM_BE, .DDRAM_WE(h_we),
	.dbg(ddr_dbg), .dbg_cmd(ddr_cmd), .dbg_ret(ddr_ret)
);
// the loader has the port while the board is in reset and hornet_ddr3 idle (ldr_start waits for it)
assign DDRAM_BURSTCNT = ldr_active ? l_burstcnt : h_burstcnt;
assign DDRAM_ADDR     = ldr_active ? l_addr : h_addr;
assign DDRAM_RD       = ldr_active ? l_rd : h_rd;
assign DDRAM_WE       = !ldr_active && h_we;
hornet_rom_loader rom_loader (
	.clk(clk_sys), .reset(sys_reset), .start(ldr_start), .length(27'h1C02000), .active(ldr_active),
	.wr(ldr_wr), .addr(ldr_addr), .dout(ldr_dout), .wait_(ioctl_wait),
	.DDRAM_BUSY, .DDRAM_BURSTCNT(l_burstcnt), .DDRAM_ADDR(l_addr), .DDRAM_DOUT, .DDRAM_DOUT_READY,
	.DDRAM_RD(l_rd)
);

///////////////////////   VIDEO   ////////////////////////////////

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = vid_ce;
assign VGA_DE = !(vid_hb || vid_vb);
assign VGA_HS = vid_hs;
assign VGA_VS = vid_vs;
// Slowdown indicator (OSD): a yellow 8x8 square in the top-right corner for 30 frames after a buffer
// swap that came two to fifteen frames after the one before (the game below 60 frames a second; a
// screen held longer is not counted), or a tilemap line not built when shown
logic       vb_q;
logic [1:0] disp_q;
logic [3:0] f_since;                   // frames since the last swap, saturating
logic [4:0] ind_t;                     // frames the square stays
always_ff @(posedge clk_sys) begin
	vb_q <= vblank;
	disp_q <= v_displayed;
	if (vblank && !vb_q) begin
		if (f_since != 4'hF) f_since <= f_since + 1'd1;
		if (ind_t != 0) ind_t <= ind_t - 1'd1;
	end
	if (v_displayed != disp_q) begin
		f_since <= 4'd0;
		if (f_since >= 4'd2 && f_since != 4'hF) ind_t <= 5'd30;
	end
	if (vid_overrun) ind_t <= 5'd30;
end
wire ind_on = status[8] && ind_t != 0 && vid_x >= 10'd504 && vid_x < 10'd512 && vid_y < 10'd8;

assign VGA_R  = ind_on ? 8'hFF : vid_r;
assign VGA_G  = ind_on ? 8'hFF : vid_g;
assign VGA_B  = ind_on ? 8'h00 : vid_b;

// the sound board on the HPS (MiSTer_ArcadeSoundServer) as master 7: the PPC's K056800 and SNDRES writes out,
// the server's replies in (hornet_sndbridge has the shared block's layout)
assign m_burst[7] = 11'd2;
assign {m_be[7], m_be_hi[7]} = 8'hFF;
hornet_sndbridge sndbridge (
	.clk(clk_sys), .reset(sys_reset),
	.wr(snd_wr), .wreg(snd_wreg), .wdata(snd_wdata), .reply(snd_reply), .live(snd_live),
	.m_read(m_read[7]), .m_write(m_write[7]), .m_addr(m_addr[7]), .m_burst(),
	.m_wdata({m_wdata_hi[7], m_wdata[7]}), .m_waitn(m_waitn[7]), .m_rvalid(m_rvalid[7]),
	.m_rdata({m_rdata_hi, m_rdata})
);

assign LED_USER = ioctl_download;

`ifdef DEBUG_ISSP
// probe F (scripts/read_issp.tcl's fields_F): bring-up. Counters saturate; source bit 0 clears them.
wire [7:0] issp_src;
reg  [15:0] p_frames, p_dlkb, p_ppc, p_dsp;
reg  [9:0]  p_dlb;
reg  [7:0]  p_aack, p_back;
reg         p_vb;
wire        p_clr = issp_src[0];
always @(posedge clk_sys) begin
	p_vb <= vblank;
	if (vblank && !p_vb && p_frames != 16'hFFFF) p_frames <= p_frames + 1'd1;
	if (img_dl && img_wr) begin p_dlb <= p_dlb + 1'd1; if (p_dlb == 10'h3FF && p_dlkb != 16'hFFFF) p_dlkb <= p_dlkb + 1'd1; end
	if (ppc_exec && p_ppc != 16'hFFFF) p_ppc <= p_ppc + 1'd1;
	if (a_ack) p_aack <= p_aack + 1'd1;
	if (b_ack) p_back <= p_back + 1'd1;
	if (p_clr) begin p_frames <= 0; p_dlkb <= 0; p_dlb <= 0; p_ppc <= 0; p_aack <= 0; p_back <= 0; end
end
reg [1:0] p_clr_d;                      // into clk_dsp
always @(posedge clk_dsp) begin
	p_clr_d <= {p_clr_d[0], p_clr};
	if (dsp_exec && p_dsp != 16'hFFFF) p_dsp <= p_dsp + 1'd1;
	if (p_clr_d[1]) p_dsp <= 0;
end
`ifdef PROBE_F                          // probe F (bring-up) and K (the loader): when there is room
altsource_probe #(
	.sld_auto_instance_index("YES"), .instance_id("F"), .probe_width(144), .source_width(8),
	.source_initial_value("0"), .enable_metastability("NO"), .lpm_type("altsource_probe")
) u_issp (
	.probe({pll_locked, board_reset, rom_dl, d_ready, dsp_idle, a_req, b_req, s_read,
	        p_back, p_aack, dsp_pc, ppc_pc, p_dsp, p_ppc, p_dlkb, p_frames}),
	.source(issp_src), .source_clk(clk_sys), .source_ena(1'b1)
);
`else
assign issp_src = 8'h0;
`endif
assign sd_dbg = issp_src[2:1];
`ifndef PROBE_K                         // K takes H's room: with both, the stp fit needs 4211 of 4191 LABs
// probe H: one frame's traffic and timing, latched at each vblank (scripts/read_issp.tcl's
// fields_H): the K037122 line builder, ports A/B/C/S, the SHARC's Voodoo writes, DDR3 beats
reg  [7:0]  h_fr, h_swap;
reg  [11:0] r_ovr, h_ovr, r_cmax, h_cmax, r_sbur, h_sbur, r_smax, h_smax, c_run, s_run;
reg  [15:0] r_creq, h_creq, r_mf, h_mf;
reg  [19:0] r_vw, h_vw, r_ddrw, h_ddrw, r_ddrr, h_ddrr;
reg  [23:0] r_cbusy, h_cbusy, r_vwait, h_vwait, r_idle, h_idle, r_bbusy, h_bbusy, r_abusy, h_abusy;
reg         s_wait;
reg  [1:0]  idle_s;
always @(posedge clk_sys) begin
	idle_s <= {idle_s[0], dsp_idle};
	if (vblank && !p_vb) begin
		h_fr <= h_fr + 1'd1;
		h_ovr <= r_ovr; h_cmax <= r_cmax; h_sbur <= r_sbur; h_smax <= r_smax; h_creq <= r_creq;
		h_mf <= r_mf; h_vw <= r_vw; h_ddrw <= r_ddrw; h_ddrr <= r_ddrr; h_cbusy <= r_cbusy;
		h_vwait <= r_vwait; h_idle <= r_idle; h_bbusy <= r_bbusy; h_abusy <= r_abusy;
		r_ovr <= 0; r_cmax <= 0; r_sbur <= 0; r_smax <= 0; r_creq <= 0; r_mf <= 0; r_vw <= 0;
		r_ddrw <= 0; r_ddrr <= 0; r_cbusy <= 0; r_vwait <= 0; r_idle <= 0; r_bbusy <= 0; r_abusy <= 0;
	end else begin
		if (vid_overrun) r_ovr <= r_ovr + 1'd1;
		if (c_req) r_cbusy <= r_cbusy + 1'd1;
		if (c_req && c_ack) r_creq <= r_creq + 1'd1;
		if (c_req && c_run > r_cmax) r_cmax <= c_run;
		if (s_read && s_waitn) r_sbur <= r_sbur + 1'd1;
		if (s_wait && s_rvalid && s_run > r_smax) r_smax <= s_run;
		if (ev_v_write) r_vw <= r_vw + 1'd1;
		if (ev_v_wait) r_vwait <= r_vwait + 1'd1;
		r_ddrw <= r_ddrw + (m_write[0] & m_waitn[0]) + (m_write[1] & m_waitn[1]) + (m_write[2] & m_waitn[2]);
		r_ddrr <= r_ddrr + m_rvalid[3] + m_rvalid[4] + m_rvalid[5];
		if ((m_write[6] && m_waitn[6]) || m_rvalid[6]) r_mf <= r_mf + 1'd1;
		if (idle_s[1]) r_idle <= r_idle + 1'd1;
		if (b_req) r_bbusy <= r_bbusy + 1'd1;
		if (a_req) r_abusy <= r_abusy + 1'd1;
	end
	// a port C request's clocks so far; port S from the burst's acceptance to its first word
	c_run <= (c_req && !c_ack && c_run != 12'hFFF) ? c_run + 1'd1 : 12'd0;
	if (s_read && s_waitn) begin s_wait <= 1'b1; s_run <= 0; end
	else if (s_wait && s_rvalid) s_wait <= 1'b0;
	else if (s_wait && s_run != 12'hFFF) s_run <= s_run + 1'd1;
	if (ev_swapcmd) h_swap <= h_swap + 1'd1;
end
altsource_probe #(
	.sld_auto_instance_index("YES"), .instance_id("H"), .probe_width(305), .source_width(1),
	.source_initial_value("0"), .enable_metastability("NO"), .lpm_type("altsource_probe")
) u_issp_h (
	.probe({dsp_unsup, h_fr, v_base0, v_displayed, h_swap, h_abusy, h_bbusy, h_idle, h_mf, h_ddrr, h_ddrw,
	        h_vwait, h_vw, h_smax, h_sbur, h_cmax, h_cbusy, h_creq, h_ovr}),
	.source(), .source_clk(clk_sys), .source_ena(1'b1)
);
`endif
`ifdef PROBE_DV                         // probes V and D: define in the .qsf when there is room
// probe V: the Voodoo (vraster's io_dbg) a frame at a time, latched at each vblank: triangles,
// fills, clocks drawing / busy / FIFO full / ring in use, texture fills and the clocks they hold
// the pixel pipeline; the live status
wire       vd_tri = v_dbg[15], vd_fill = v_dbg[14];
wire [3:0] vd_cs = v_dbg[13:10];
reg  [15:0] r_tri, q_tri;
reg  [11:0] r_fill, q_fill;
reg  [23:0] r_tclk, q_tclk, r_bclk, q_bclk, r_fclk, q_fclk, r_rclk, q_rclk;
reg  [23:0] r_tfh, q_tfh;               // clocks a texture fill holds the pipeline
reg  [15:0] r_tfn, q_tfn;               // texture fills
reg         tf_q;
reg  [15:0] r_rbad, q_rbad;             // ring entries read back wrong
always @(posedge clk_sys) begin
	if (v_ring_bad && r_rbad != 16'hFFFF) r_rbad <= r_rbad + 1'd1;
	if (vblank && !p_vb) begin
		q_tri <= r_tri; q_fill <= r_fill; q_tclk <= r_tclk; q_bclk <= r_bclk; q_fclk <= r_fclk;
		q_rclk <= r_rclk; q_rbad <= r_rbad; q_tfh <= r_tfh; q_tfn <= r_tfn;
		r_tri <= 0; r_fill <= 0; r_tclk <= 0; r_bclk <= 0; r_fclk <= 0; r_rclk <= 0; r_rbad <= 0;
		r_tfh <= 0; r_tfn <= 0;
	end else begin
		if (vd_tri) r_tri <= r_tri + 1'd1;
		if (vd_fill) r_fill <= r_fill + 1'd1;
		if (vd_cs == 4'd8) r_tclk <= r_tclk + 1'd1;           // C_TRI
		if (vd_cs != 4'd0) r_bclk <= r_bclk + 1'd1;
		if (v_dbg[8]) r_fclk <= r_fclk + 1'd1;                // FIFO full
		if (v_dbg[7]) r_rclk <= r_rclk + 1'd1;                // ring in use
		if (v_dbg[5]) r_tfh <= r_tfh + 1'd1;                // a texture fill holds the pipeline
		if (v_dbg[5] && !tf_q) r_tfn <= r_tfn + 1'd1;
	end
	tf_q <= v_dbg[5];
end
altsource_probe #(
	.sld_auto_instance_index("YES"), .instance_id("V"), .probe_width(204), .source_width(1),
	.source_initial_value("0"), .enable_metastability("NO"), .lpm_type("altsource_probe")
) u_issp_v (
	.probe({q_rbad, h_fr, v_dbg, q_tfh, q_tfn, q_rclk, q_fclk, q_bclk, q_tclk, q_fill, q_tri}),
	// source bit 0: the Voodoo's memory FIFO without its DDR3 ring
	.source(v_ring_off), .source_clk(clk_sys), .source_ena(1'b1)
);
`endif
// probe K: the DDR3 port's command and return path, live (hornet_ddr3's dbg_cmd, dbg_ret), every term
// of board_reset; the return path's state when it first held a tag (t_on), in clocks since
// configuration; whether a command was ever taken; pll_locked's and RESET's rising edges
`ifdef PROBE_K
reg  [31:0] k_clk = 0, k_ton_clk = 0;
reg  [42:0] k_ton_ret = 0;
reg         k_ton_seen = 0, k_ton_br = 0, k_ton_rst = 0, k_take_seen = 0;
reg  [7:0]  k_lock_up = 0, k_reset_up = 0;
reg  [2:0]  k_lock_s = 0, k_reset_s = 0;
always @(posedge clk_sys) begin
	if (k_clk != 32'hFFFF_FFFF) k_clk <= k_clk + 1'd1;
	k_lock_s <= {k_lock_s[1:0], pll_locked};
	k_reset_s <= {k_reset_s[1:0], RESET};
	if (k_lock_s[1] && !k_lock_s[2] && k_lock_up != 8'hFF) k_lock_up <= k_lock_up + 1'd1;
	if (k_reset_s[1] && !k_reset_s[2] && k_reset_up != 8'hFF) k_reset_up <= k_reset_up + 1'd1;
	if (ddr_dbg[11]) k_take_seen <= 1'b1;
	if (ddr_cmd[10] && !k_ton_seen) begin
		k_ton_seen <= 1'b1; k_ton_clk <= k_clk; k_ton_ret <= ddr_ret; k_ton_br <= board_reset; k_ton_rst <= RESET;
	end
end
altsource_probe #(
	.sld_auto_instance_index("YES"), .instance_id("K"), .probe_width(272), .source_width(1),
	.source_initial_value("0"), .enable_metastability("NO"), .lpm_type("altsource_probe")
) u_issp_k (
	// rot_dropped on top: synthesis drops its constant bits from the probe's shift register, and the
	// read pads at the top, so a constant field below the top moves every field above it
	.probe({rot_dropped, k_ton_clk, k_ton_ret, k_ton_br, k_ton_rst, k_ton_seen, k_take_seen, k_lock_up, k_reset_up,
	        ddr_ret, ldr_addr[26:12], ldr_active, ldr_pending, ldr_due, ldr_done, dl0_seen, dl_seen_wr,
	        nv_seen, ldr_wr && ioctl_wait,
	        board_reset, pll_locked, ioctl_index[7:0], ioctl_download, nv_dl, rom_dl, buttons[1], status[0],
	        RESET, ddr_idle, ddr_cmd}), .source(k_rst), .source_clk(clk_sys), .source_ena(1'b1)
);
`else
assign k_rst = 1'b0;
`endif
`ifdef PROBE_DV
// probe D: the DDR3 port a frame at a time (hornet_ddr3's dbg), latched at each vblank: clocks
// DDRAM_BUSY, idle, waiting for return-FIFO room, waiting to issue a read, writing; read commands,
// write beats, beats in; read latency (accepted to first beat) sum and worst; commands by master
wire        dd_lv = ddr_dbg[23];
wire [11:0] dd_lat = {1'b0, ddr_dbg[22:12]};
wire        dd_go = ddr_dbg[11];
wire [2:0]  dd_m = (ddr_dbg[10:7] == 4'd8) ? 3'd7 : ddr_dbg[9:7];       // port S in slot 7, the rotator uncounted
wire        dd_in = ddr_dbg[6], dd_wb = ddr_dbg[5], dd_ra = ddr_dbg[4], dd_room = ddr_dbg[3], dd_busy = ddr_dbg[2];
wire [1:0]  dd_as = ddr_dbg[1:0];
reg  [23:0] r_dbusy, q_dbusy, r_didle, q_didle, r_droom, q_droom, r_drdw, q_drdw, r_dwr, q_dwr;
reg  [19:0] r_drc, q_drc, r_dwb, q_dwb, r_din, q_din;
reg  [27:0] r_dlat, q_dlat;
reg  [11:0] r_dlmax, q_dlmax;
reg  [15:0] r_dc [8], q_dc [8];
always @(posedge clk_sys) begin
	if (vblank && !p_vb) begin
		q_dbusy <= r_dbusy; q_didle <= r_didle; q_droom <= r_droom; q_drdw <= r_drdw; q_dwr <= r_dwr;
		q_drc <= r_drc; q_dwb <= r_dwb; q_din <= r_din; q_dlat <= r_dlat; q_dlmax <= r_dlmax;
		r_dbusy <= 0; r_didle <= 0; r_droom <= 0; r_drdw <= 0; r_dwr <= 0;
		r_drc <= 0; r_dwb <= 0; r_din <= 0; r_dlat <= 0; r_dlmax <= 0;
		for (int i = 0; i < 8; i++) begin q_dc[i] <= r_dc[i]; r_dc[i] <= 0; end
	end else begin
		if (dd_busy) r_dbusy <= r_dbusy + 1'd1;
		if (dd_as == 2'd0 && !dd_go) r_didle <= r_didle + 1'd1;
		if (dd_room) r_droom <= r_droom + 1'd1;
		if (dd_as == 2'd2 && dd_busy) r_drdw <= r_drdw + 1'd1;
		if (dd_as == 2'd3) r_dwr <= r_dwr + 1'd1;
		if (dd_ra) r_drc <= r_drc + 1'd1;
		if (dd_wb) r_dwb <= r_dwb + 1'd1;
		if (dd_in) r_din <= r_din + 1'd1;
		if (dd_lv) begin r_dlat <= r_dlat + dd_lat; if (dd_lat > r_dlmax) r_dlmax <= dd_lat; end
		if (dd_go && ddr_dbg[10:7] != 4'd7) r_dc[dd_m] <= r_dc[dd_m] + 1'd1;
	end
end
altsource_probe #(
	.sld_auto_instance_index("YES"), .instance_id("D"), .probe_width(348), .source_width(1),
	.source_initial_value("0"), .enable_metastability("NO"), .lpm_type("altsource_probe")
) u_issp_d (
	.probe({q_dc[7], q_dc[6], q_dc[5], q_dc[4], q_dc[3], q_dc[2], q_dc[1], q_dc[0],
	        q_dlmax, q_dlat, q_din, q_dwb, q_drc, q_dwr, q_drdw, q_droom, q_didle, q_dbusy}),
	.source(), .source_clk(clk_sys), .source_ena(1'b1)
);
`endif
`endif

endmodule
