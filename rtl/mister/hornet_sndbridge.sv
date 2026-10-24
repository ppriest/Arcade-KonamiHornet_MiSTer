// SPDX-License-Identifier: GPL-3.0-or-later
//
// The sound board on the HPS (MiSTer_ArcadeSoundServer, src/hornet): a block of DDR3 shared with the server, written
// and read through a wide hornet_ddr3 master. Little-endian 64-bit words, byte offsets from SHM:
//
//   +0x00  "HRNS", version 1                                          the FPGA, every BEAT
//   +0x08  the 68000 program's and the samples' DDR3 byte addresses  the FPGA, every BEAT
//   +0x10  {count of ring entries written, 32}                       the FPGA, after each entry
//   +0x18  {beat count (+1 every BEAT), 32}                          the FPGA, every BEAT
//   +0x20  {SNDRES in bit 32, host registers 3-0 in bits 31-0}       the FPGA, after each entry
//   +0x40  {heartbeat 16, 0xA5 8, running 8 (bit 0); 0 16, reply 1 8, reply 0 8}    the server
//   +0x1000 ring of RING entries {0, data 8, register 8 (0-7, 8 SNDRES), microseconds 32}
//
// Each PPC write to a K056800 host register or to SNDRES becomes an entry stamped with a
// microsecond count, so the server can replay them at their spacing; a write follows its entry
// through the same master, so the count never runs ahead of the ring. The server's word is read
// every POLL clocks; `live` while its heartbeat moved within LIVE polls and its flags say it runs.

module hornet_sndbridge #(
    parameter logic [31:0] SHM      = 32'h3F20_0000,
    parameter logic [31:0] PROG     = 32'h31C0_2000,    // the image's 68000 program, in DDR3
    parameter logic [31:0] SAMPLES  = 32'h31C8_2000,    // ... and its samples
    parameter int          RING     = 512,
    parameter int          BEAT     = 640_000,          // 10 ms at 64 MHz
    parameter int          POLL     = 4096,             // 64 us
    parameter int          LIVE     = 1600              // 0.1 s of polls
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        wr,                 // hornet_board's snd_*
    input  logic [3:0]  wreg,
    input  logic [7:0]  wdata,
    output logic [15:0] reply,
    output logic        live,

    output logic        m_read,
    output logic        m_write,
    output logic [31:0] m_addr,
    output logic [10:0] m_burst,
    output logic [63:0] m_wdata,
    input  logic        m_waitn,
    input  logic        m_rvalid,
    input  logic [63:0] m_rdata
);

localparam int RW = $clog2(RING);

// microseconds: clk / 64
logic [37:0] clocks;
always_ff @(posedge clk) clocks <= clocks + 1'd1;
wire  [31:0] us = clocks[37:6];

// the PPC's writes, queued: a command is five writes in a quarter of a microsecond
logic [43:0] q [16];                        // {us, register, data}
logic [3:0]  q_wp, q_rp;
wire         q_empty = q_wp == q_rp;
always_ff @(posedge clk) begin
    if (wr && q_wp + 4'd1 != q_rp) begin q[q_wp] <= {us, wreg, wdata}; q_wp <= q_wp + 1'd1; end
    if (reset) q_wp <= '0;
end

logic [31:0] host;                          // the current host registers 3-0
logic        sndres;
logic [31:0] count;
logic [31:0] beats;
logic [19:0] beat_t;
logic        beat_due;
logic [12:0] poll_t;
logic        poll_due;

typedef enum logic [3:0] { S_IDLE, S_ENTRY, S_COUNT, S_STATE, S_MAGIC, S_ADDRS, S_BEAT, S_POLL, S_RDATA } st_t;
st_t         st;
logic [43:0] e;

always_ff @(posedge clk) begin
    if (beat_t == 20'(BEAT - 1)) begin beat_t <= '0; beat_due <= 1'b1; end
    else beat_t <= beat_t + 1'd1;
    if (poll_t == 13'(POLL - 1)) begin poll_t <= '0; poll_due <= 1'b1; end
    else poll_t <= poll_t + 1'd1;

    case (st)
    S_IDLE:
        if (!q_empty) begin
            e = q[q_rp];
            q_rp <= q_rp + 1'd1;
            if (e[11:8] == 4'd8) sndres <= e[7];
            else if (e[11:8] < 4'd4) host[8*e[9:8] +: 8] <= e[7:0];
            m_addr <= SHM + 32'h1000 + {count[RW-1:0], 3'b000};
            m_wdata <= {16'h0, e[7:0], 4'h0, e[11:8], e[43:12]};
            m_write <= 1'b1; st <= S_ENTRY;
        end else if (beat_due) begin
            beat_due <= 1'b0;
            m_addr <= SHM; m_wdata <= {32'd1, 32'h534E_5248};      // "HRNS"
            m_write <= 1'b1; st <= S_MAGIC;
        end else if (poll_due) begin
            poll_due <= 1'b0;
            m_addr <= SHM + 32'h40; m_read <= 1'b1; st <= S_POLL;
        end
    S_ENTRY: if (m_waitn) begin
        m_write <= 1'b0;
        count <= count + 1'd1;
        st <= S_COUNT;
    end
    S_COUNT: begin
        m_addr <= SHM + 32'h10; m_wdata <= {32'h0, count}; m_write <= 1'b1;
        if (m_write && m_waitn) begin m_write <= 1'b0; st <= S_STATE; end
    end
    S_STATE: begin
        m_addr <= SHM + 32'h20; m_wdata <= {31'h0, sndres, host}; m_write <= 1'b1;
        if (m_write && m_waitn) begin m_write <= 1'b0; st <= S_IDLE; end
    end
    S_MAGIC: if (m_waitn) begin
        m_addr <= SHM + 32'h08; m_wdata <= {SAMPLES, PROG}; st <= S_ADDRS;
    end
    S_ADDRS: if (m_waitn) begin
        beats <= beats + 1'd1;
        m_addr <= SHM + 32'h18; m_wdata <= {32'h0, beats + 32'd1}; st <= S_BEAT;
    end
    S_BEAT: if (m_waitn) begin m_write <= 1'b0; st <= S_IDLE; end
    S_POLL: if (m_waitn) begin m_read <= 1'b0; st <= S_RDATA; end
    S_RDATA: if (m_rvalid) st <= S_IDLE;
    default: st <= S_IDLE;
    endcase

    if (reset) begin
        st <= S_IDLE; m_read <= 1'b0; m_write <= 1'b0; q_rp <= '0;
        count <= '0; beats <= '0; host <= '0; sndres <= 1'b0;
        beat_t <= '0; beat_due <= 1'b1; poll_t <= '0; poll_due <= 1'b0;
    end
end

assign m_burst = 11'd2;                     // one beat

// the server's word: its reply, and whether its heartbeat moves
logic [15:0] hb;
logic [10:0] stale;
always_ff @(posedge clk) begin
    if (st == S_RDATA && m_rvalid) begin
        if (m_rdata[63:48] != hb) stale <= '0;
        else if (stale != 11'(LIVE)) stale <= stale + 1'd1;
        hb <= m_rdata[63:48];
        live <= m_rdata[47:40] == 8'hA5 && m_rdata[32] && stale != 11'(LIVE);
        reply <= m_rdata[15:0];
    end
    if (reset) begin live <= 1'b0; stale <= 11'(LIVE); hb <= '0; reply <= '0; end
end

endmodule
