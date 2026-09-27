-- SPDX-License-Identifier: GPL-3.0-or-later
-- A window of the PPC403's execution, for sim/ppc_tb to start from and diff against.
-- Driven by scripts/mame_ppc_window.py, through run.lua.
--
-- At the end of frame CORE_FRAME:
--   state.txt   CPU registers MAME exposes (NAME=HEX)
--   workram.bin the 4 MB work RAM, big-endian
--   then arms the debugger trace (R0..R31 CR LR CTR XER MSR, then PC) to trace.tr and a
--   device-access log io.txt: every PPC access outside RAM and ROM, in bus order,
--   "R|W addr mask data".
-- Work RAM is DRC fastram (hornet.cpp:1326), invisible to taps: it comes from the dump.
--
--   CORE_OUT     output directory
--   CORE_FRAME   frame to start the window at
--   CORE_EVENTS  "frame:port:mask:len,..." inputs to press before it (e.g. 4400:IN2:80:5)

local out    = os.getenv("CORE_OUT")
local frame  = tonumber(os.getenv("CORE_FRAME") or "600")
local events = os.getenv("CORE_EVENTS") or ""

local m   = manager.machine
local cpu = m.devices[":maincpu"]
local sp  = cpu.spaces["program"]

-- globals: dropped subscriptions stop firing (LESSONS_LEARNED, Lua section)
ppcwin_subs = {}
ppcwin_hits = 0
ppcwin_err = nil

local held = {}
local pressed = {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16),
                              len = tonumber(len) }
end

local iof
local function log_access(rw, offset, data, mask)
    ppcwin_hits = ppcwin_hits + 1
    local ok, e = pcall(function()
        iof:write(string.format("%s %08X %08X %08X\n", rw, offset, mask, data))
    end)
    if not ok and not ppcwin_err then ppcwin_err = tostring(e) end
end

local RANGES = {
    { 0x40000000, 0x4000000f },   -- 4xx serial port (internal map)
    { 0x74000000, 0x7407ffff },   -- K037122
    { 0x78000000, 0x780c0003 },   -- DSP shared RAM and comm
    { 0x7d000000, 0x7d03ffff },   -- sysreg, M48T58, K056800
}

local function arm()
    local st = io.open(out .. "/state.txt", "w")
    local names = { "PC", "MSR", "CR", "LR", "CTR", "XER", "SRR0", "SRR1", "SPRG0", "SPRG1",
                    "SPRG2", "SPRG3", "EXIER", "EXISR", "EVPR", "TBH", "TBL" }
    for i = 0, 31 do names[#names + 1] = "R" .. i end
    for _, n in ipairs(names) do
        local e = cpu.state[n]
        if e then st:write(string.format("%s=%08X\n", n, e.value)) end
    end
    st:write(string.format("FRAME=%d\n", frame))
    st:close()

    local ram = io.open(out .. "/workram.bin", "wb")
    local chunk = {}
    for a = 0, 0x3ffffc, 4 do
        chunk[#chunk + 1] = string.pack(">I4", sp:read_u32(a))
        if #chunk == 4096 then ram:write(table.concat(chunk)); chunk = {} end
    end
    ram:write(table.concat(chunk))
    ram:close()

    iof = assert(io.open(out .. "/io.txt", "w"))
    iof:setvbuf("line")     -- the run is killed, not ended: keep every access
    for _, r in ipairs(RANGES) do
        ppcwin_subs[#ppcwin_subs + 1] = sp:install_read_tap(r[1], r[2], "ppcwin_r" .. r[1],
            function(offset, data, mask) log_access("R", offset, data, mask) end)
        ppcwin_subs[#ppcwin_subs + 1] = sp:install_write_tap(r[1], r[2], "ppcwin_w" .. r[1],
            function(offset, data, mask) log_access("W", offset, data, mask) end)
    end

    local dbg = m.debugger
    dbg.visible_cpu = cpu
    local fmt = {}
    for _ = 1, 37 do fmt[#fmt + 1] = "%08X" end
    local regs = {}
    for i = 0, 31 do regs[#regs + 1] = "R" .. i end
    for _, n in ipairs({ "CR", "LR", "CTR", "XER", "MSR" }) do regs[#regs + 1] = n end
    dbg:command('trace ' .. out .. '/trace.tr,maincpu,noloop,{tracelog "' .. table.concat(fmt, " ") ..
                ' ",' .. table.concat(regs, ",") .. '}')
    dbg:command('go')
    print("PPCWIN_ARMED frame " .. frame)
end

local armed = false
ppcwin_subs[#ppcwin_subs + 1] = emu.add_machine_frame_notifier(function()
    local f = m.screens[":screen"]:frame_number()
    for _, p in ipairs(pressed) do
        if f == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = f + p.len end
        if held[p] and f >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    if not armed and f >= frame then
        armed = true
        arm()
    end
    if armed and iof then
        iof:flush()
        if ppcwin_err then print("PPCWIN_TAP_ERROR " .. ppcwin_err) end
    end
end)
