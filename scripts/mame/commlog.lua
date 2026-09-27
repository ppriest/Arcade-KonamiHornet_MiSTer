-- SPDX-License-Identifier: GPL-3.0-or-later
-- The PPC/SHARC handshake in MAME: every PPC access to the comm register (0x780C0000) and every
-- SHARC access to its comm registers (0x3400000-1), with the machine time, from frame CORE_FRAME
-- for CORE_FRAMES frames. Driven by scripts/mame_commlog.py through run.lua (-nodrc, so the
-- SHARC's data-space taps fire).
--   CORE_OUT/commlog.txt: "F frame time_us" at each frame end, "<cpu> R|W addr data time_us"

local out    = os.getenv("CORE_OUT")
local first  = tonumber(os.getenv("CORE_FRAME") or "2150")
local frames = tonumber(os.getenv("CORE_FRAMES") or "4")
local events = os.getenv("CORE_EVENTS") or ""
local m      = manager.machine
local screen = m.screens[":screen"]
local ppc    = m.devices[":maincpu"].spaces["program"]
local dsp    = m.devices[":dsp1"].spaces["data"]

commlog_subs = {}
commlog_err = nil

local pressed, held = {}, {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end

local f
local function us() return m.time:as_double() * 1e6 end
local function log(who, rw, a, d)
    local ok, e = pcall(function() f:write(string.format("%s %s %08X %08X %.2f\n", who, rw, a, d, us())) end)
    if not ok and not commlog_err then commlog_err = tostring(e) end
end

local state = 0
commlog_subs[#commlog_subs + 1] = emu.add_machine_frame_notifier(function()
    local fr = screen:frame_number()
    for _, p in ipairs(pressed) do
        if fr == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = fr + p.len end
        if held[p] and fr >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    if state == 0 and fr >= first then
        state = 1
        f = assert(io.open(out .. "/commlog.txt", "w"))
        f:setvbuf("line")
        commlog_subs[#commlog_subs + 1] = ppc:install_read_tap(0x780c0000, 0x780c0003, "cl_pr",
            function(o, d, mk) log("PPC", "R", o, d) end)
        commlog_subs[#commlog_subs + 1] = ppc:install_write_tap(0x780c0000, 0x780c0003, "cl_pw",
            function(o, d, mk) log("PPC", "W", o, d) end)
        commlog_subs[#commlog_subs + 1] = dsp:install_read_tap(0x3400000, 0x3400001, "cl_sr",
            function(o, d, mk) log("DSP", "R", o, d) end)
        commlog_subs[#commlog_subs + 1] = dsp:install_write_tap(0x3400000, 0x3400001, "cl_sw",
            function(o, d, mk) log("DSP", "W", o, d) end)
    end
    if state == 1 then
        f:write(string.format("F %d %.2f\n", fr, us()))
        if fr >= first + frames then print("COMMLOG_DONE"); m:exit() end
    end
    if commlog_err then print("COMMLOG_TAP_ERROR " .. commlog_err) end
end)
