-- SPDX-License-Identifier: GPL-3.0-or-later
-- The sound board's traffic in MAME, with machine time, from frame CORE_FRAME for CORE_FRAMES
-- frames: the PPC's K056800 host accesses (0x7D030000-F) and system-register writes (0x7D010000-F,
-- SNDRES is register 4 bit 7), and the 68000's K056800 sound-side accesses (0x300000-1F), timer
-- writes (0x500000, 0x600000) and RF5C400 writes (0x200000-FFF). Driven by scripts/mame_sndlog.py.
--   CORE_OUT/sndlog.txt: "F frame time_us" at each frame end, "<cpu> R|W addr data mask time_us"

local out    = os.getenv("CORE_OUT")
local first  = tonumber(os.getenv("CORE_FRAME") or "0")
local frames = tonumber(os.getenv("CORE_FRAMES") or "600")
local events = os.getenv("CORE_EVENTS") or ""
local m      = manager.machine
local screen = m.screens[":screen"]
local ppc    = m.devices[":maincpu"].spaces["program"]
local snd    = m.devices[":audiocpu"].spaces["program"]

sndlog_subs = {}
sndlog_err = nil

local pressed, held = {}, {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end

local f
local function us() return m.time:as_double() * 1e6 end
local function log(who, rw, a, d, mk)
    local ok, e = pcall(function()
        f:write(string.format("%s %s %08X %08X %08X %.3f\n", who, rw, a, d, mk or 0, us()))
    end)
    if not ok and not sndlog_err then sndlog_err = tostring(e) end
end

local function tap(space, lo, hi, who, name)
    sndlog_subs[#sndlog_subs + 1] = space:install_read_tap(lo, hi, name .. "r",
        function(o, d, mk) log(who, "R", o, d, mk) end)
    sndlog_subs[#sndlog_subs + 1] = space:install_write_tap(lo, hi, name .. "w",
        function(o, d, mk) log(who, "W", o, d, mk) end)
end

local state = 0
local function start()
    state = 1
    f = assert(io.open(out .. "/sndlog.txt", "w"))
    f:setvbuf("full", 1 << 20)
    tap(ppc, 0x7d030000, 0x7d03000f, "PPC", "sl_k")
    sndlog_subs[#sndlog_subs + 1] = ppc:install_write_tap(0x7d010000, 0x7d01000f, "sl_sysw",
        function(o, d, mk) log("PPC", "W", o, d, mk) end)
    tap(snd, 0x300000, 0x30001f, "SND", "sl_sk")
    sndlog_subs[#sndlog_subs + 1] = snd:install_write_tap(0x500000, 0x600001, "sl_tw",
        function(o, d, mk) log("SND", "W", o, d, mk) end)
    sndlog_subs[#sndlog_subs + 1] = snd:install_write_tap(0x200000, 0x200fff, "sl_rfw",
        function(o, d, mk) log("RF", "W", o, d, mk) end)
end

if first == 0 then start() end
sndlog_subs[#sndlog_subs + 1] = emu.add_machine_frame_notifier(function()
    local fr = screen:frame_number()
    for _, p in ipairs(pressed) do
        if fr == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = fr + p.len end
        if held[p] and fr >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    if state == 0 and fr >= first then start() end
    if state == 1 then
        f:write(string.format("F %d %.3f\n", fr, us()))
        if fr >= first + frames then f:close(); print("SNDLOG_DONE"); m:exit() end
    end
    if sndlog_err then print("SNDLOG_TAP_ERROR " .. sndlog_err) end
end)
