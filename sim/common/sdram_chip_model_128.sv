// SPDX-License-Identifier: GPL-3.0-or-later
// The 128 MB SDRAM module: two 64 MB chips (13 row, 10 column, 4 bank bits)
// on one bus, SDRAM_nCS low selecting the first and high the second, as
// rtl/memory/sdram/sdram.sv drives it after Arcade-PsikyoSH2_MiSTer's sdram1.sv
// (the module's wiring itself is not checked here). Each chip is
// sdram_chip_model_wide.sv's command decoder with a 10-bit column and a select.
module sdram_chip_model_128 (
	input  logic         clk,
	inout  wire  [15:0] SDRAM_DQ,
	input  logic [12:0] SDRAM_A,
	input  logic  [1:0] SDRAM_BA,
	input  logic         SDRAM_nCS,
	input  logic         SDRAM_nWE,
	input  logic         SDRAM_nRAS,
	input  logic         SDRAM_nCAS
);
	sdram_chip_model_64 #(.SEL(1'b0)) u_c0 (.*);
	sdram_chip_model_64 #(.SEL(1'b1)) u_c1 (.*);
endmodule

module sdram_chip_model_64 #(
	parameter bit SEL = 1'b0     // the SDRAM_nCS level that selects this chip
) (
	input  logic         clk,

	inout  wire  [15:0] SDRAM_DQ,
	input  logic [12:0] SDRAM_A,
	input  logic  [1:0] SDRAM_BA,
	input  logic         SDRAM_nCS,
	input  logic         SDRAM_nWE,
	input  logic         SDRAM_nRAS,
	input  logic         SDRAM_nCAS
);

	localparam logic [2:0] CMD_NOP          = 3'b111;
	localparam logic [2:0] CMD_ACTIVE       = 3'b011;
	localparam logic [2:0] CMD_READ         = 3'b101;
	localparam logic [2:0] CMD_WRITE        = 3'b100;
	localparam logic [2:0] CMD_PRECHARGE    = 3'b010;
	localparam logic [2:0] CMD_AUTO_REFRESH = 3'b001;
	localparam logic [2:0] CMD_LOAD_MODE    = 3'b000;

	wire [2:0] cmd = SDRAM_nCS == SEL ? {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} : CMD_NOP;
	int writes = 0, refreshes = 0;   // for the bench: what reached this chip
	always @(posedge clk) begin
		if (cmd == CMD_WRITE) writes <= writes + 1;
		if (cmd == CMD_AUTO_REFRESH) refreshes <= refreshes + 1;
	end

	// {bank[1:0], row[12:0], col[9:0]}: 32M words, one 64 MB chip
	logic [15:0] mem [0:33554431];

	function automatic int unsigned addr_of(input logic [1:0] bank, input logic [12:0] row, input logic [9:0] col);
		addr_of = {bank, row, col};
	endfunction

	// [GX] four banks, as the chip has and as {bank, row, col} above says: with two,
	// an access above 16 MB (bank 2 or 3) indexed past the array -- ModelSim read
	// the open row as X, so the whole bank collapsed onto one row, while Verilator
	// wrapped the index and agreed with itself.
	logic [12:0] open_row [0:3];
	logic [12:0] mode_reg;
	wire  [2:0] cas_latency_field  = mode_reg[6:4];
	wire  [2:0] burst_length_field = mode_reg[2:0];
	wire  [4:0] burst_words        = 5'd1 << burst_length_field;   // 0=1,1=2,2=4,3=8

	// [Hornet] reads as the standard has them at any CAS latency: a READ's burst starts CL - 1 edges
	// after the command's edge (data on DQ for the controller's sample at CL), and a burst in
	// progress runs on until then (read-to-read truncation). The model this came from started the
	// new burst at once, which only matched the double read at CL2.
	typedef struct { longint start; logic [9:0] col; logic [1:0] bank; int len; } rd_t;
	rd_t     rq [$];
	longint  t = 0;
	logic [9:0] rcol;
	logic [1:0] rbank;
	int      rburst_left = 0;

	logic         driving;
	logic [15:0] drive_word;

	assign SDRAM_DQ = driving ? drive_word : 16'bz;

	always_ff @(posedge clk) begin
		int unsigned widx;

		driving <= 1'b0;
		if (rq.size() != 0 && rq[0].start <= t) begin
			rcol = rq[0].col; rbank = rq[0].bank; rburst_left = rq[0].len;
			void'(rq.pop_front());
		end
		if (rburst_left > 0) begin
			driving     <= 1'b1;
			widx        = addr_of(rbank, open_row[rbank], rcol);
			drive_word  <= mem[widx];
			rburst_left = rburst_left - 1;
			rcol        = rcol + 10'd1;
		end

		unique case (cmd)
			CMD_ACTIVE:    open_row[SDRAM_BA] <= SDRAM_A;
			CMD_LOAD_MODE: mode_reg <= SDRAM_A;
			CMD_WRITE: begin
				widx = addr_of(SDRAM_BA, open_row[SDRAM_BA], SDRAM_A[9:0]);
				if (!SDRAM_A[11]) mem[widx][7:0]  <= SDRAM_DQ[7:0];
				if (!SDRAM_A[12]) mem[widx][15:8] <= SDRAM_DQ[15:8];
			end
			CMD_READ: rq.push_back('{start: t + longint'(cas_latency_field) - 1, col: SDRAM_A[9:0],
			                         bank: SDRAM_BA, len: int'(burst_words)});
			default: ; // NOP / PRECHARGE / AUTO_REFRESH: nothing to model
		endcase
		t = t + 1;
	end

endmodule
