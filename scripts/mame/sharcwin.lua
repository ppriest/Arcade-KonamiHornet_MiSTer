-- SPDX-License-Identifier: GPL-3.0-or-later
-- A window of the SHARC's (:dsp1) execution, for sim/sharc_tb to start from and diff against.
-- Driven by scripts/mame_sharc_window.py, through run.lua; MAME runs -nodrc (the recompiler
-- bypasses the data-space taps) with -debug -debugger none (the trace).
--
-- At the end of frame CORE_FRAME:
--   items.txt     every save-state item of :dsp1 of up to 64 elements, "name count v0 v1 ..."
--                 (hex); the whole core state, alternate registers and stacks included
--   block0.bin, block1.bin      the two internal RAM blocks as MAME stores them, 32-bit LE
--   ram500.bin, ram1400.bin     the external RAMs at 0x500000 and 0x1400000, 32-bit LE
--   then arms the debugger trace (TRACE_REGS below, then PC) to trace.tr and a log of the
--   accesses the SHARC makes outside its own RAMs and ROM, io.txt: "R|W addr data".
--
--   CORE_OUT     output directory
--   CORE_FRAME   frame to start the window at
--   CORE_EVENTS  "frame:port:mask:len,..." inputs to press before it

local out    = os.getenv("CORE_OUT")
local frame  = tonumber(os.getenv("CORE_FRAME") or "600")
local events = os.getenv("CORE_EVENTS") or ""

local m   = manager.machine
local dsp = m.devices[":dsp1"]
local ds  = dsp.spaces["data"]

sharcwin_subs = {}
sharcwin_hits = 0
sharcwin_err  = nil

local TRACE_REGS = {}
for i = 0, 15 do TRACE_REGS[#TRACE_REGS + 1] = "R" .. i end
for i = 0, 15 do TRACE_REGS[#TRACE_REGS + 1] = "I" .. i end
for i = 0, 15 do TRACE_REGS[#TRACE_REGS + 1] = "M" .. i end
for _, n in ipairs({ "ASTAT", "MODE1", "IRPTL", "IMASK", "PCSTKP", "LSTKP", "CURLCNTR", "PCSTK" }) do
    TRACE_REGS[#TRACE_REGS + 1] = n
end

local pressed, held = {}, {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end

local iof
local function log_access(rw, offset, data)
    sharcwin_hits = sharcwin_hits + 1
    local ok, e = pcall(function() iof:write(string.format("%s %08X %08X\n", rw, offset, data)) end)
    if not ok and not sharcwin_err then sharcwin_err = tostring(e) end
end

-- the SHARC's view outside its own RAMs and the CG ROM (hornet.cpp:1057-1066)
local RANGES = {
    { 0x0400000, 0x041ffff },   -- shared RAM
    { 0x2400000, 0x27fffff },   -- Voodoo
    { 0x3400000, 0x34000ff },   -- comm
    { 0x3500000, 0x35000ff },   -- K033906
    { 0x3600000, 0x37fffff },   -- CG ROM window (its bank is konppc state)
}

local function dump_words(path, it)
    local f = io.open(path, "wb")
    local chunk = {}
    for i = 0, it.count - 1 do
        chunk[#chunk + 1] = string.pack("<I4", it:read(i))
        if #chunk == 4096 then f:write(table.concat(chunk)); chunk = {} end
    end
    f:write(table.concat(chunk))
    f:close()
end

local function arm()
    local st = io.open(out .. "/items.txt", "w")
    for name, idx in pairs(dsp.items) do
        local it = emu.item(idx)
        if name:find("block0") then dump_words(out .. "/block0.bin", it)
        elseif name:find("block1") then dump_words(out .. "/block1.bin", it)
        elseif name:find("dataram") then dump_words(out .. "/ram500.bin", it)
        elseif name:find("1400000") then dump_words(out .. "/ram1400.bin", it)
        elseif it.count <= 64 then
            local v = {}
            for i = 0, it.count - 1 do v[#v + 1] = string.format("%X", it:read(i)) end
            st:write(string.format("%s %d %s\n", name, it.count, table.concat(v, " ")))
        end
    end
    st:write(string.format("FRAME 1 %X\n", frame))
    st:close()

    iof = assert(io.open(out .. "/io.txt", "w"))
    iof:setvbuf("line")
    for _, r in ipairs(RANGES) do
        sharcwin_subs[#sharcwin_subs + 1] = ds:install_read_tap(r[1], r[2], "sharcwin_r" .. r[1],
            function(offset, data, mask) log_access("R", offset, data) end)
        sharcwin_subs[#sharcwin_subs + 1] = ds:install_write_tap(r[1], r[2], "sharcwin_w" .. r[1],
            function(offset, data, mask) log_access("W", offset, data) end)
    end

    local dbg = m.debugger
    dbg.visible_cpu = dsp
    local fmt = {}
    for _ = 1, #TRACE_REGS do fmt[#fmt + 1] = "%08X" end
    dbg:command('trace ' .. out .. '/trace.tr,dsp1,noloop,{tracelog "' .. table.concat(fmt, " ") ..
                ' ",' .. table.concat(TRACE_REGS, ",") .. '}')
    dbg:command('go')
    print("SHARCWIN_ARMED frame " .. frame)
end

local armed = false
sharcwin_subs[#sharcwin_subs + 1] = emu.add_machine_frame_notifier(function()
    local f = m.screens[":screen"]:frame_number()
    for _, p in ipairs(pressed) do
        if f == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = f + p.len end
        if held[p] and f >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    if not armed and f >= frame then
        armed = true
        arm()
    end
    if sharcwin_err then print("SHARCWIN_TAP_ERROR " .. sharcwin_err) end
end)
