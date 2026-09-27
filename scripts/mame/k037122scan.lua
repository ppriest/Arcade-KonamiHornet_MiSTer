-- SPDX-License-Identifier: GPL-3.0-or-later
-- The K037122's scroll and increment registers (0x20, 0x24, 0x28) and control (0x30, 0x34) at the
-- end of each frame, for finding frames that rotate or zoom its tilemap. Driven by
-- scripts/mame_k037122_scan.py through run.lua.
--   CORE_OUT/k037122.txt: "frame r20 r24 r28 r30 r34" (hex), one line per frame that changes them
--   CORE_OUT, CORE_FRAMES (last frame), CORE_EVENTS

local out    = os.getenv("CORE_OUT")
local last   = tonumber(os.getenv("CORE_FRAMES") or "4400")
local events = os.getenv("CORE_EVENTS") or ""
local m      = manager.machine
local screen = m.screens[":screen"]

k037122scan_subs = {}

local pressed, held = {}, {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end

local reg
for name, idx in pairs(m.devices[":k037122_0"].items) do
    if name:find("m_reg") then reg = emu.item(idx) end
end
local f = assert(io.open(out .. "/k037122.txt", "w"))
local prev = ""
k037122scan_subs[#k037122scan_subs + 1] = emu.add_machine_frame_notifier(function()
    local fr = screen:frame_number()
    for _, p in ipairs(pressed) do
        if fr == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = fr + p.len end
        if held[p] and fr >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    local b = reg:read_block(0x20, 0x18)                -- registers 0x20-0x34, bytes
    local r20, r24, r28, _, r30, r34 = string.unpack("<I4I4I4I4I4I4", b)
    local s = string.format("%08X %08X %08X %08X %08X", r20, r24, r28, r30, r34)
    if s ~= prev then f:write(fr .. " " .. s .. "\n"); f:flush(); prev = s end
    if fr >= last then print("K037122SCAN_DONE"); m:exit() end
end)
