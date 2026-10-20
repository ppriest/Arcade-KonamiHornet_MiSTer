// SPDX-License-Identifier: GPL-3.0-or-later
//
// The M48T58's clock (MAME timekpr.cpp, m48t58_device): bytes 0x1FF8-0x1FFF are registers here,
// the rest of the 8 KB is hornet_board's RAM. The counters tick once a second unless the
// oscillator is stopped (seconds bit 7) or the write bit is set, and are copied into the bytes
// unless the read bit is set; clearing the write bit loads the counters from the bytes. No
// calibration, no battery-low, no century (the M48T58 has none).
//
// set loads the counters from the host's time (hps_io's RTC, MSM6242B layout: BCD seconds,
// minutes, hours, date, month, year, then the day of the week 0-6) and copies them into the
// bytes, as MAME does once at start. A write with ld (the image download, a state load) sets the
// byte and its counter, without the control register's side effects.

module hornet_rtc #(
    parameter int CLK_HZ = 64_000_000
) (
    input  logic        clk,
    input  logic        set,
    input  logic [55:0] host_time,
    input  logic        tick_en,        // the board runs (the second counts only then)
    input  logic        ld,
    // the PPC's word at 0x1FF8 (wa 0) or 0x1FFC (wa 1); byte 0 in bits 31:24
    input  logic        wa,
    input  logic [3:0]  we,
    input  logic [31:0] wdata,
    input  logic        ra,             // the word read, as wa
    output logic [31:0] rdata           // combinational on ra
);

localparam logic [7:0] CTL_W = 8'h80, CTL_R = 8'h40, SEC_ST = 8'h80, DAY_CEB = 8'h20,
                       DAY_CB = 8'h10, DATE_BL = 8'h40;

// the bytes as read (0 control, 1 seconds, 2 minutes, 3 hours, 4 day, 5 date, 6 month, 7 year)
logic [7:0] b [8];
// the counters
logic [7:0] c_ctl, c_sec, c_min, c_hour, c_day, c_date, c_mon, c_year;

assign rdata = ra ?{b[4], b[5] & ~DATE_BL, b[6], b[7]} : {b[0], b[1], b[2], b[3]};

// BCD increment within [lo, hi] under a mask; carry when it wraps (time_helper::inc_bcd)
function automatic logic [8:0] inc_bcd(input logic [7:0] v, input logic [7:0] mask,
                                       input logic [7:0] lo, input logic [7:0] hi);
    logic [7:0] x, r;
    logic       cy;
    x = v & mask;
    cy = 1'b0;
    if (x >= hi) begin r = lo; cy = 1'b1; end
    else if (x[3:0] == 4'h9) r = {x[7:4] + 4'd1, 4'h0};
    else r = {x[7:4], x[3:0] + 4'd1};
    return {cy, (v & ~mask) | (r & mask)};
endfunction

// February: 29 when the year is a multiple of 4 (MAME: the binary year % 4). For BCD 10t + u,
// 10t mod 4 is 2t mod 4.
function automatic logic [7:0] days_in_feb(input logic [7:0] year);
    logic [1:0] m;
    m = {year[4], 1'b0} + year[1:0];
    return (m == 2'd0) ? 8'h29 : 8'h28;
endfunction

// one second of clk; a write in the second's last clock puts the tick off a clock
localparam int SEC_W = $clog2(CLK_HZ);
logic [SEC_W-1:0] sec_div;
wire              sec_end = sec_div == SEC_W'(CLK_HZ - 1);
wire              sec_tick = tick_en && sec_end && we == 4'b0;
always_ff @(posedge clk) begin
    if (!tick_en) sec_div <= '0;
    else if (sec_tick) sec_div <= '0;
    else if (!sec_end) sec_div <= sec_div + 1'd1;
end

always_ff @(posedge clk) begin
    if (set) begin
        c_ctl  <= 8'h00;
        c_sec  <= host_time[7:0];  c_min <= host_time[15:8]; c_hour <= host_time[23:16];
        c_date <= host_time[31:24]; c_mon <= host_time[39:32]; c_year <= host_time[47:40];
        c_day  <= {5'h00, host_time[50:48] + 3'd1};
        b[0] <= 8'h00;
        b[1] <= host_time[7:0];   b[2] <= host_time[15:8];  b[3] <= host_time[23:16];
        b[4] <= {5'h00, host_time[50:48] + 3'd1};
        b[5] <= host_time[31:24]; b[6] <= host_time[39:32]; b[7] <= host_time[47:40];
    end else if (ld) begin
        for (int i = 0; i < 4; i++)
            if (we[3 - i]) begin
                b[{wa, 2'(i)}] <= wdata[8 * (3 - i) +: 8];
                case ({wa, 2'(i)})
                3'd0: c_ctl  <= wdata[8 * (3 - i) +: 8];
                3'd1: c_sec  <= wdata[8 * (3 - i) +: 8];
                3'd2: c_min  <= wdata[8 * (3 - i) +: 8];
                3'd3: c_hour <= wdata[8 * (3 - i) +: 8];
                3'd4: c_day  <= wdata[8 * (3 - i) +: 8];
                3'd5: c_date <= wdata[8 * (3 - i) +: 8];
                3'd6: c_mon  <= wdata[8 * (3 - i) +: 8];
                default: c_year <= wdata[8 * (3 - i) +: 8];
                endcase
            end
    end else begin
        // the PPC's writes (timekeeper_device::write)
        if (!wa && we[3]) begin
            if ((c_ctl & CTL_W) != 0 && (wdata[31:24] & CTL_W) == 0) begin
                c_sec <= b[1]; c_min <= b[2]; c_hour <= b[3]; c_day <= b[4];
                c_date <= b[5]; c_mon <= b[6]; c_year <= b[7];
            end
            if ((c_ctl & CTL_R) != 0 && (wdata[31:24] & CTL_W) == 0) begin
                b[1] <= c_sec; b[2] <= c_min; b[3] <= c_hour; b[4] <= c_day;
                b[5] <= c_date; b[6] <= c_mon; b[7] <= c_year;
            end
            c_ctl <= wdata[31:24];
        end
        if (wa && we[3]) c_day <= (c_day & ~DAY_CEB) | (wdata[31:24] & DAY_CEB);
        for (int i = 0; i < 4; i++)
            if (we[3 - i]) b[{wa, 2'(i)}] <= wdata[8 * (3 - i) +: 8];

        // the second (timer_tick)
        if (sec_tick && (c_sec & SEC_ST) == 0 && (c_ctl & CTL_W) == 0) begin
            logic [8:0] s, m, h, d, dt, mo, y;
            logic [7:0] day;
            s = inc_bcd(c_sec, 8'h7F, 8'h00, 8'h59);
            m = s[8] ? inc_bcd(c_min, 8'h7F, 8'h00, 8'h59) : {1'b0, c_min};
            h = m[8] ? inc_bcd(c_hour, 8'h3F, 8'h00, 8'h23) : {1'b0, c_hour};
            d = h[8] ? inc_bcd(c_day, 8'h07, 8'h01, 8'h07) : {1'b0, c_day};
            dt = h[8] ? inc_bcd(c_date, 8'h3F, 8'h01, (c_mon == 8'h02) ? days_in_feb(c_year) :
                                (c_mon == 8'h04 || c_mon == 8'h06 || c_mon == 8'h09 ||
                                 c_mon == 8'h11) ? 8'h30 : 8'h31) : {1'b0, c_date};
            mo = dt[8] ? inc_bcd(c_mon, 8'h1F, 8'h01, 8'h12) : {1'b0, c_mon};
            y = mo[8] ? inc_bcd(c_year, 8'hFF, 8'h00, 8'h99) : {1'b0, c_year};
            day = d[7:0];
            if (y[8] && (day & DAY_CEB) != 0) day = day ^ DAY_CB;
            c_sec <= s[7:0]; c_min <= m[7:0]; c_hour <= h[7:0]; c_day <= day;
            c_date <= dt[7:0]; c_mon <= mo[7:0]; c_year <= y[7:0];
            if ((c_ctl & CTL_R) == 0) begin
                b[0] <= c_ctl; b[1] <= s[7:0]; b[2] <= m[7:0]; b[3] <= h[7:0]; b[4] <= day;
                b[5] <= dt[7:0]; b[6] <= mo[7:0]; b[7] <= y[7:0];
            end
        end
    end
end

endmodule
