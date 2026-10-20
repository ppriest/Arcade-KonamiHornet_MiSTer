-- SPDX-License-Identifier: GPL-3.0-or-later
-- Which quarters of the K037122 SRAM (the PPC's 0x74020000-0x7403FFFF, 8K words each) the game
-- reads and writes over a long run, and the values of the K037122 control register 0x34 (its bit
-- 2 places the tilemap and palette): to size the core's SRAM. Driven by
-- scripts/mame_k037122_census.py through run.lua.
--
-- kscensus.txt at CORE_TO (and every 1000 frames):
--   quarter <first byte address> <reads> <writes> <nonzero writes>
--   ctl2 <value> <writes>

local out    = os.getenv("CORE_OUT")
local to     = tonumber(os.getenv("CORE_TO") or "30000")
local events = os.getenv("CORE_EVENTS") or ""

local m  = manager.machine
local ps = m.devices[":maincpu"].spaces["program"]

kscensus_subs = {}

local pressed, held = {}, {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end

local rd, wr, wnz, ctl = {}, {}, {}, {}
local function inc(t, k) t[k] = (t[k] or 0) + 1 end

local function dump()
    local f = io.open(out .. "/kscensus.txt", "w")
    local ks, seen = {}, {}
    for _, t in ipairs({ rd, wr }) do
        for k in pairs(t) do if not seen[k] then seen[k] = true; ks[#ks + 1] = k end end
    end
    table.sort(ks)
    for _, k in ipairs(ks) do
        f:write(string.format("quarter %08X %d %d %d\n", 0x74020000 + k * 0x8000, rd[k] or 0, wr[k] or 0, wnz[k] or 0))
    end
    for v, n in pairs(ctl) do f:write(string.format("ctl2 %08X %d\n", v, n)) end
    f:close()
end

kscensus_subs[#kscensus_subs + 1] = ps:install_write_tap(0x74020000, 0x7403ffff, "kscensus_w",
    function(offset, data, mask)
        local p = (offset - 0x74020000) // 0x8000
        inc(wr, p)
        if data & mask ~= 0 then inc(wnz, p) end
    end)
kscensus_subs[#kscensus_subs + 1] = ps:install_read_tap(0x74020000, 0x7403ffff, "kscensus_r",
    function(offset, data, mask) inc(rd, (offset - 0x74020000) // 0x8000) end)
kscensus_subs[#kscensus_subs + 1] = ps:install_write_tap(0x74000034, 0x74000037, "kscensus_c",
    function(offset, data, mask) inc(ctl, data & mask) end)

kscensus_subs[#kscensus_subs + 1] = emu.add_machine_frame_notifier(function()
    local f = m.screens[":screen"]:frame_number()
    for _, p in ipairs(pressed) do
        if f == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = f + p.len end
        if held[p] and f >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    if f % 1000 == 0 then dump() end
    if f >= to then
        dump()
        print("KSCENSUS_DONE")
        m:exit()
    end
end)
