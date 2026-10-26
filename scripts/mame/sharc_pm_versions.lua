-- SPDX-License-Identifier: GPL-3.0-or-later
-- Every distinct program the SHARC holds over a long run (block 0 as 48-bit words,
-- 0x20000-0x24FFF), to check what the core's instruction subset assumes: that the program is fixed
-- after boot. Driven by scripts/mame_sharc_pm_versions.py through run.lua (MAME -nodrc).
--
-- CORE_CHEATS: "addr:value,..." bytes written in the PPC's space every frame from CORE_CHEAT_FROM
-- (MAME's Invincibility and Infinite Lives, so that a play run reaches the later stages).
--
-- Out, every CORE_EVERY frames: pm_<frame>.bin when the program differs from the last saved (six
-- bytes a word: low 32 bits, high 16, little-endian), versions.txt (frame, words changed);
-- snap_<frame>.png every 3000 frames.

local out    = os.getenv("CORE_OUT")
local to     = tonumber(os.getenv("CORE_TO") or "30000")
local every  = tonumber(os.getenv("CORE_EVERY") or "50")
local events = os.getenv("CORE_EVENTS") or ""
local cheats = os.getenv("CORE_CHEATS") or ""
local cfrom  = tonumber(os.getenv("CORE_CHEAT_FROM") or "0")

local m   = manager.machine
local ps  = m.devices[":dsp1"].spaces["program"]
local cpu = m.devices[":maincpu"].spaces["program"]

pmver_subs = {}

local pressed, held = {}, {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end
local pokes = {}
for a, v in cheats:gmatch("(%x+):(%x+)") do pokes[#pokes + 1] = { a = tonumber(a, 16), v = tonumber(v, 16) } end

local last = nil
local vf = io.open(out .. "/versions.txt", "w")

local function sample(f)
    local cur, parts, changed = {}, {}, 0
    for i = 0, 0x4FFF do
        local w = ps:read_u64(0x20000 + i)
        cur[i] = w
        if last == nil or last[i] ~= w then changed = changed + 1 end
    end
    if changed > 0 then
        for i = 0, 0x4FFF do
            local w = cur[i]
            parts[#parts + 1] = string.pack("<I4I2", w & 0xFFFFFFFF, (w >> 32) & 0xFFFF)
        end
        local b = io.open(string.format("%s/pm_%06d.bin", out, f), "wb")
        b:write(table.concat(parts))
        b:close()
        vf:write(string.format("%d %d\n", f, changed))
        vf:flush()
        last = cur
    end
end

pmver_subs[#pmver_subs + 1] = emu.add_machine_frame_notifier(function()
    local f = m.screens[":screen"]:frame_number()
    for _, p in ipairs(pressed) do
        if f == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = f + p.len end
        if held[p] and f >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    if f >= cfrom then for _, p in ipairs(pokes) do cpu:write_u8(p.a, p.v) end end
    if f % every == 0 then sample(f) end
    if f % 3000 == 0 and f > 0 then m.screens[":screen"]:snapshot(string.format("%s/snap_%06d.png", out, f)) end
    if f >= to then
        sample(f)
        vf:close()
        print("PMVERSIONS_DONE")
        m:exit()
    end
end)
