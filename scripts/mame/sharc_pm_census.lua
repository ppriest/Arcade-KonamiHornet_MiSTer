-- SPDX-License-Identifier: GPL-3.0-or-later
-- Which of the SHARC's program memory (block 0 as 48-bit words, 0x20000-0x24FFF) the game uses
-- over a long run: to size the core's PM. Driven by scripts/mame_sharc_pm_census.py through
-- run.lua (MAME -nodrc). Fetches do not pass the address-space taps (and a 64-bit tap's mask does
-- not fit a Lua integer), so the census is the PM's contents: non-zero words per 1K-word page,
-- sampled every 1000 frames, the maximum kept.
--
-- pmcensus.txt at CORE_TO (and every 1000 frames):
--   page <first word address> <most non-zero words seen>    non-zero pages only

local out    = os.getenv("CORE_OUT")
local to     = tonumber(os.getenv("CORE_TO") or "30000")
local events = os.getenv("CORE_EVENTS") or ""

local m  = manager.machine
local ps = m.devices[":dsp1"].spaces["program"]

pmcensus_subs = {}

local pressed, held = {}, {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end

local nz = {}

local function sample()
    for pg = 0, 19 do
        local n = 0
        for w = 0, 1023 do
            local a = 0x20000 + pg * 1024 + w
            if ps:read_u64(a) ~= 0 then n = n + 1 end
        end
        if n > (nz[pg] or 0) then nz[pg] = n end
    end
end

local function dump()
    local f = io.open(out .. "/pmcensus.txt", "w")
    for pg = 0, 19 do
        if (nz[pg] or 0) > 0 then
            f:write(string.format("page %05X %d\n", 0x20000 + pg * 1024, nz[pg]))
        end
    end
    f:close()
end

pmcensus_subs[#pmcensus_subs + 1] = emu.add_machine_frame_notifier(function()
    local f = m.screens[":screen"]:frame_number()
    for _, p in ipairs(pressed) do
        if f == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = f + p.len end
        if held[p] and f >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    if f % 1000 == 0 then sample(); dump() end
    if f >= to then
        sample(); dump()
        print("PMCENSUS_DONE")
        m:exit()
    end
end)
