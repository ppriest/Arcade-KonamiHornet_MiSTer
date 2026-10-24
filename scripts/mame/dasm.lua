-- SPDX-License-Identifier: GPL-3.0-or-later
-- Disassemble address ranges of a CPU with MAME's debugger at the end of a frame (code the game
-- copies to RAM needs the frame after the copy). Driven by scripts/mame_dasm.py through run.lua.
--   CORE_OUT/dasm_<start>.txt per range; CORE_CPU (tag), CORE_FRAME, CORE_RANGES "start:len,..." (hex)

local out    = os.getenv("CORE_OUT")
local cpu    = os.getenv("CORE_CPU") or "maincpu"
local frame  = tonumber(os.getenv("CORE_FRAME") or "150")
local ranges = os.getenv("CORE_RANGES") or ""
local m      = manager.machine

dasm_subs = {}
dasm_subs[#dasm_subs + 1] = emu.add_machine_frame_notifier(function()
    if m.screens[":screen"]:frame_number() < frame then return end
    local dbg = m.debugger
    dbg.visible_cpu = m.devices[":" .. cpu]
    for s, l in ranges:gmatch("(%x+):(%x+)") do
        dbg:command(string.format("dasm %s/dasm_%s.txt,%s,%s,0,%s", out, s, s, l, cpu))
    end
    print("DASM_DONE")
    m:exit()
end)
