-- SPDX-License-Identifier: GPL-3.0-or-later
-- Which of the SHARC's internal data memory (block 1, 0x28000-0x3FFFF in its data space) the
-- game touches over a long run: to size the core's DM. Driven by scripts/mame_sharc_dm_census.py
-- through run.lua; MAME runs -nodrc so the taps see the SHARC's accesses (instructions and DMA).
--
-- dmcensus.txt at CORE_TO (and every 1000 frames):
--   page <first word address> <reads> <writes> <nonzero writes>    per 1K words, touched pages only

local out    = os.getenv("CORE_OUT")
local to     = tonumber(os.getenv("CORE_TO") or "30000")
local events = os.getenv("CORE_EVENTS") or ""

local m  = manager.machine
local ds = m.devices[":dsp1"].spaces["data"]

dmcensus_subs = {}

local pressed, held = {}, {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end

local rd, wr, wnz = {}, {}, {}
local function inc(t, k) t[k] = (t[k] or 0) + 1 end

local function dump()
    local f = io.open(out .. "/dmcensus.txt", "w")
    local ks, seen = {}, {}
    for _, t in ipairs({ rd, wr }) do
        for k in pairs(t) do if not seen[k] then seen[k] = true; ks[#ks + 1] = k end end
    end
    table.sort(ks)
    for _, k in ipairs(ks) do
        f:write(string.format("page %05X %d %d %d\n", 0x28000 + k * 1024, rd[k] or 0, wr[k] or 0, wnz[k] or 0))
    end
    f:close()
end

dmcensus_subs[#dmcensus_subs + 1] = ds:install_write_tap(0x28000, 0x3ffff, "dmcensus_w",
    function(offset, data, mask)
        local p = (offset - 0x28000) // 1024
        inc(wr, p)
        if data ~= 0 then inc(wnz, p) end
    end)
dmcensus_subs[#dmcensus_subs + 1] = ds:install_read_tap(0x28000, 0x3ffff, "dmcensus_r",
    function(offset, data, mask) inc(rd, (offset - 0x28000) // 1024) end)

dmcensus_subs[#dmcensus_subs + 1] = emu.add_machine_frame_notifier(function()
    local f = m.screens[":screen"]:frame_number()
    for _, p in ipairs(pressed) do
        if f == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = f + p.len end
        if held[p] and f >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    if f % 1000 == 0 then dump() end
    if f >= to then
        dump()
        print("DMCENSUS_DONE")
        m:exit()
    end
end)
