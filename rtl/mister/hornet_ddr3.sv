// SPDX-License-Identifier: GPL-3.0-or-later
//
// DDR3 for the Voodoo: N 32-bit Avalon-MM masters (vraster's six, the picture's frame-buffer
// reads) onto the 64-bit DDRAM port, all on clk. Two 32-bit beats share a 64-bit one, so the
// Voodoo's 568k beats a frame take about a third of the clocks (ROADMAP, Phase 2 throughput).
//
// Masters as vraster's (sim/board_tb's model): a read is one command with a burst count, its data
// later at one word a clock (rvalid); a write is a burst, the count with the first beat, each beat
// taken when waitn is high. Byte addresses, 32-bit aligned, absolute in the DDR3 space (vraster's
// FB_BASE, TEX_BASE): DDRAM_ADDR is the address's bits 31:3, which reach the core's window at
// 0x30000000 as they are. A burst is at most 509 words (255 beats).
//
//   reads   one 64-bit burst covering the words, its tag (master, first half, word count) queued;
//           the data comes back in order into a FIFO, from which the words go to their masters a
//           clock each. A read is issued only when the FIFO has room for all of it (credits).
//   writes  the granted master keeps the port for its burst; its words are packed in pairs, an odd
//           first or last word with the other half's byte enables off.
//   order   master N-1 (the picture) first, then the others in turn, a command or a write burst at
//           a time; the choice is registered (A_IDLE) a clock before the command goes (A_CMD).

module hornet_ddr3 #(
    parameter int N    = 7,
    parameter int RAW  = 8,             // the return FIFO holds 2^RAW beats
    // wide masters move a whole 64-bit beat a handshake: their bursts start on an 8-byte boundary
    // and count an even number of words (padding words with byte enables off); a write takes
    // m_wdata/m_be (low word) and m_wdata_hi/m_be_hi together, a read returns m_rdata and m_rdata_hi
    parameter logic [N-1:0] WIDE = '0
) (
    input  logic                 clk,
    input  logic                 reset,         // power-up only: a transaction cut short hangs the port
    // the masters' reset: no command starts, a write burst whose master stops is finished with
    // byte enables off, read data still due is taken and dropped; idle when nothing is outstanding
    input  logic                 drain,
    output logic                 idle,

    input  logic [N-1:0]         m_read,
    input  logic [N-1:0]         m_write,
    input  logic [N-1:0][31:0]   m_addr,
    input  logic [N-1:0][10:0]   m_burst,
    input  logic [N-1:0][3:0]    m_be,
    input  logic [N-1:0][31:0]   m_wdata,
    input  logic [N-1:0][3:0]    m_be_hi,
    input  logic [N-1:0][31:0]   m_wdata_hi,
    output logic [N-1:0]         m_waitn,
    output logic [N-1:0]         m_rvalid,
    output logic [31:0]          m_rdata,
    output logic [31:0]          m_rdata_hi,

    input  logic                 DDRAM_BUSY,
    output logic [7:0]           DDRAM_BURSTCNT,
    output logic [28:0]          DDRAM_ADDR,
    input  logic [63:0]          DDRAM_DOUT,
    input  logic                 DDRAM_DOUT_READY,
    output logic                 DDRAM_RD,
    output logic [63:0]          DDRAM_DIN,
    output logic [7:0]           DDRAM_BE,
    output logic                 DDRAM_WE,

    output logic [23:0]          dbg,
    output logic [77:0]          dbg_cmd       // the stp revision's probe K: the command on the port
);

localparam int MW = $clog2(N);

// ------------------------------------------------------------------------------------------
// return path: beats in, words out to their masters
// ------------------------------------------------------------------------------------------

logic [63:0]    rf [1 << RAW];
logic [RAW:0]   rf_wp, rf_rp;
logic [63:0]    rf_q;
logic           rf_qv;                  // rf_q holds the beat at rf_rp
logic [RAW+1:0] r_out;                  // beats issued and not yet taken from the FIFO

typedef struct packed { logic [MW-1:0] m; logic hi; logic [10:0] n; } tag_t;
tag_t           tq [16];
logic [4:0]     tq_wp, tq_rp;
tag_t           t_cur;
logic           t_hi;                   // the half next out
logic [10:0]    t_left;                 // words left in the head tag
logic           t_on;                   // a tag is being returned

wire            rf_empty = rf_wp == rf_rp;

// the words out: a narrow master's one a clock, a wide master's two (the whole beat); the beat
// leaves with its high half, the tag's last word, or at once for a wide master. rf_q is the RAM's
// registered output; it reads ahead to the next beat when one leaves, so beats go out back to back
wire out_now  = t_on && rf_qv;
wire t_wide   = WIDE[t_cur.m];
wire pop_beat = out_now && (t_wide || t_hi || t_left == 11'd1);
wire [RAW:0] rf_nx = pop_beat ? rf_rp + 1'd1 : rf_rp;
always_ff @(posedge clk) begin
    if (DDRAM_DOUT_READY) begin rf[rf_wp[RAW-1:0]] <= DDRAM_DOUT; rf_wp <= rf_wp + 1'd1; end
    rf_q <= rf[rf_nx[RAW-1:0]];
    // the beat read is there (a beat written this clock is not readable yet)
    rf_qv <= rf_nx != rf_wp;
    if (reset) begin rf_wp <= '0; rf_qv <= 1'b0; end
end

wire t_last = t_wide ? t_left <= 11'd2 : t_left == 11'd1;
wire tq_any = tq_wp != tq_rp;
always_ff @(posedge clk) begin
    m_rvalid <= '0;
    // the next tag is taken when none is on or the last word of this one goes
    if (tq_any && (!t_on || (out_now && t_last))) begin
        t_cur <= tq[tq_rp[3:0]]; t_hi <= tq[tq_rp[3:0]].hi; t_left <= tq[tq_rp[3:0]].n;
        tq_rp <= tq_rp + 1'd1;
        t_on <= 1'b1;
    end else if (out_now && t_last) t_on <= 1'b0;
    if (out_now) begin
        m_rvalid[t_cur.m] <= !drain;
        m_rdata <= (t_hi && !t_wide) ? rf_q[63:32] : rf_q[31:0];
        m_rdata_hi <= rf_q[63:32];
        if (!(tq_any && t_last)) begin
            t_hi <= !t_hi;
            t_left <= t_left - (t_wide ? 11'd2 : 11'd1);
        end
    end
    if (pop_beat) rf_rp <= rf_rp + 1'd1;
    if (reset) begin rf_rp <= '0; t_on <= 1'b0; tq_rp <= '0; m_rvalid <= '0; end
end

// ------------------------------------------------------------------------------------------
// commands
// ------------------------------------------------------------------------------------------

typedef enum logic [1:0] { A_IDLE, A_CMD, A_RD, A_WR } a_t;
a_t             as;
logic [MW-1:0]  g;                      // the granted master
logic           c_rd;                   // its command, registered in A_IDLE, issued from A_CMD
logic [31:0]    c_addr;
logic [10:0]    c_burst;
logic [MW-1:0]  rr;                     // the next in turn among 0..N-2
logic [10:0]    w_left;                 // write words still to take
logic           w_hold;                 // the low half of a pair is in w_lo
logic [31:0]    w_lo;
logic [3:0]     w_lobe;
logic           w_out;                  // a beat is on DDRAM_DIN waiting for !DDRAM_BUSY
logic [7:0]     b_left;                 // the burst's beats not yet taken by the port

function automatic logic [7:0] beats(input logic [31:0] a, input logic [10:0] n);
    return 8'((11'(a[2]) + n + 11'd1) >> 1);
endfunction

// the next master: N-1 first, then from rr round
logic          pick_v;
logic [MW-1:0] pick;
always_comb begin
    logic found;
    logic [MW-1:0] k;
    found = 1'b0; k = '0;
    if (m_read[N-1] || m_write[N-1]) begin found = 1'b1; k = MW'(N - 1); end
    for (int j = 0; j < N - 1; j++) begin
        logic [MW:0] i;
        i = (MW+1)'(rr) + (MW+1)'(j);
        if (i >= (MW+1)'(N - 1)) i = i - (MW+1)'(N - 1);
        if (!found && (m_read[MW'(i)] || m_write[MW'(i)])) begin found = 1'b1; k = MW'(i); end
    end
    pick_v = found; pick = k;
end

wire  rd_room = int'(r_out) + int'(beats(c_addr, c_burst)) <= (1 << RAW) && tq_wp - tq_rp < 5'd15;
wire  rd_go = as == A_CMD && !drain && c_rd && rd_room;     // a read issued: its tag, its credits

// write beats the master offers and the packer takes this clock
logic w_take;
always_comb begin
    m_waitn = '0;
    w_take = 1'b0;
    if (as == A_RD && !DDRAM_BUSY) m_waitn[g] = 1'b1;
    if (as == A_WR && m_write[g] && w_left != 0 && (!w_out || !DDRAM_BUSY)) begin m_waitn[g] = 1'b1; w_take = 1'b1; end
end

always_ff @(posedge clk) begin
    if (as == A_RD && !DDRAM_BUSY) DDRAM_RD <= 1'b0;
    if (w_out && !DDRAM_BUSY) begin DDRAM_WE <= 1'b0; w_out <= 1'b0; b_left <= b_left - 8'd1; end
    case (as)
    A_IDLE: if (pick_v && !drain) begin
        g <= pick;
        if (pick != MW'(N - 1)) rr <= (pick == MW'(N - 2)) ? '0 : pick + 1'd1;
        c_rd <= m_read[pick]; c_addr <= m_addr[pick]; c_burst <= m_burst[pick];
        as <= A_CMD;
    end
    A_CMD:
        if (drain) as <= A_IDLE;                    // not on the port yet
        else if (c_rd) begin
            if (rd_go) begin
                DDRAM_RD <= 1'b1; DDRAM_ADDR <= c_addr[31:3];
                DDRAM_BURSTCNT <= beats(c_addr, c_burst);
                tq[tq_wp[3:0]] <= '{m: g, hi: c_addr[2], n: c_burst};
                tq_wp <= tq_wp + 1'd1;
                as <= A_RD;
            end
        end else begin
            w_left <= c_burst;
            b_left <= beats(c_addr, c_burst);
            DDRAM_ADDR <= c_addr[31:3];
            DDRAM_BURSTCNT <= beats(c_addr, c_burst);
            // an odd first word goes alone, in the high half
            w_hold <= c_addr[2];
            w_lo <= 32'h0; w_lobe <= 4'h0;
            as <= A_WR;
        end
    A_RD: if (!DDRAM_BUSY) as <= A_IDLE;
    A_WR: begin
        if (w_take && WIDE[g]) begin
            w_left <= w_left - 11'd2;
            DDRAM_WE <= 1'b1; w_out <= 1'b1;
            DDRAM_DIN <= {m_wdata_hi[g], m_wdata[g]}; DDRAM_BE <= {m_be_hi[g], m_be[g]};
        end else if (w_take) begin
            w_left <= w_left - 1'd1;
            if (!w_hold && w_left != 11'd1) begin
                w_lo <= m_wdata[g]; w_lobe <= m_be[g]; w_hold <= 1'b1;
            end else begin
                DDRAM_WE <= 1'b1; w_out <= 1'b1;
                if (w_hold) begin DDRAM_DIN <= {m_wdata[g], w_lo}; DDRAM_BE <= {m_be[g], w_lobe}; end
                else begin DDRAM_DIN <= {32'h0, m_wdata[g]}; DDRAM_BE <= {4'h0, m_be[g]}; end
                w_hold <= 1'b0;
            end
        end
        // draining with the master stopped: the burst's other beats, writing nothing
        if (drain && !w_take && b_left != 0 && (!w_out || !DDRAM_BUSY) && !(w_out && b_left == 8'd1)) begin
            DDRAM_WE <= 1'b1; w_out <= 1'b1; DDRAM_DIN <= 64'h0; DDRAM_BE <= 8'h0;
        end
        if (b_left == 0 && !w_out) as <= A_IDLE;
    end
    default: as <= A_IDLE;
    endcase
    if (reset) begin as <= A_IDLE; DDRAM_RD <= 1'b0; DDRAM_WE <= 1'b0; w_out <= 1'b0; tq_wp <= '0; rr <= '0; end
end

// synthesis translate_off
always_ff @(posedge clk)
    if (as == A_IDLE && pick_v && (m_read[pick] || m_write[pick]) && m_burst[pick] > 11'd509)
        $error("hornet_ddr3: master %0d burst of %0d words", pick, m_burst[pick]);
always_ff @(posedge clk) begin
    if (as == A_IDLE && pick_v && !drain && WIDE[pick] && (m_addr[pick][2] || m_burst[pick][0] || m_burst[pick] == 0))
        $error("hornet_ddr3: wide master %0d %s at %08X of %0d words", pick, m_read[pick] ? "read" : "write",
               m_addr[pick], m_burst[pick]);
    if (as == A_IDLE && pick_v && !drain && m_burst[pick] == 0)
        $error("hornet_ddr3: master %0d burst of 0 words", pick);
    if (DDRAM_WE && !DDRAM_BUSY && (as != A_WR || b_left == 0))
        $error("hornet_ddr3: a write beat beyond the burst (master %0d)", g);
    if (DDRAM_WE && DDRAM_RD) $error("hornet_ddr3: read and write together");
end
// synthesis translate_on

assign idle = as == A_IDLE && r_out == '0 && !t_on && !tq_any;
assign dbg_cmd = {DDRAM_BUSY, DDRAM_RD, DDRAM_WE, w_out, b_left, w_left, DDRAM_BURSTCNT, c_addr[31:3],
                  c_rd, 3'(g), 2'(as), tq_any, t_on, 10'(r_out)};

// debug (the stp revision's probe D): {a read's latency valid, its latency (accepted to first beat,
// saturating), a command chosen, its master, a beat in, a write beat out, a read accepted, a read
// waiting for FIFO room, DDRAM_BUSY, the arbiter state}
logic [15:0] d_now;
logic [15:0] d_ts [16];
logic [7:0]  d_bt [16];
logic [3:0]  d_wp, d_rp;
logic [7:0]  d_left;
logic        d_lv;
logic [11:0] d_lat;
always_ff @(posedge clk) begin
    d_now <= d_now + 1'd1;
    d_lv <= 1'b0;
    if (as == A_RD && !DDRAM_BUSY) begin d_ts[d_wp] <= d_now; d_bt[d_wp] <= DDRAM_BURSTCNT; d_wp <= d_wp + 1'd1; end
    if (DDRAM_DOUT_READY) begin
        if (d_left == 8'd0) begin
            logic [15:0] l;
            l = d_now - d_ts[d_rp];
            d_lv <= 1'b1; d_lat <= (l > 16'd4095) ? 12'hFFF : l[11:0];
            d_left <= d_bt[d_rp] - 8'd1; d_rp <= d_rp + 1'd1;
        end else d_left <= d_left - 8'd1;
    end
    if (reset) begin d_wp <= '0; d_rp <= '0; d_left <= '0; end
end
assign dbg = {d_lv, d_lat, as == A_IDLE && pick_v, 3'(pick), DDRAM_DOUT_READY, DDRAM_WE && !DDRAM_BUSY,
              as == A_RD && !DDRAM_BUSY, as == A_CMD && c_rd && !rd_room, DDRAM_BUSY, as};

// read beats outstanding: issued, less those taken from the FIFO
always_ff @(posedge clk) begin
    logic [RAW+1:0] o;
    o = r_out;
    if (rd_go) o = o + (RAW+2)'(beats(c_addr, c_burst));
    if (pop_beat) o = o - 1'd1;
    r_out <= o;
    if (reset) r_out <= '0;
end

endmodule
