-- SPDX-License-Identifier: GPL-3.0-or-later
-- The PPC's device accesses from power-on, by frame, for planning and checking a boot from reset
-- on the board. Driven by scripts/mame_bootlog.py through run.lua.
--   CORE_OUT/bootlog.txt: "frame R|W addr mask data" for every PPC access to the K037122 registers,
--   comm, sysreg, M48T58 and K056800, the 4xx serial port; per frame, "S frame n" the number of
--   shared-RAM accesses and "C frame n" the number of K037122 SRAM/character accesses.
--   CORE_OUT, CORE_FRAMES (last frame)

local out    = os.getenv("CORE_OUT")
local last   = tonumber(os.getenv("CORE_FRAMES") or "800")
local m      = manager.machine
local screen = m.screens[":screen"]
local sp     = m.devices[":maincpu"].spaces["program"]

bootlog_subs = {}
bootlog_err = nil

local f = assert(io.open(out .. "/bootlog.txt", "w"))
f:setvbuf("line")
local fr = 0
local nsh, nk = 0, 0
local function log(rw, o, d, mk)
    local ok, e = pcall(function() f:write(string.format("%d %s %08X %08X %08X\n", fr, rw, o, mk, d)) end)
    if not ok and not bootlog_err then bootlog_err = tostring(e) end
end
local RANGES = {
    { 0x40000000, 0x4000000f },   -- 4xx serial port
    { 0x74000000, 0x740000ff },   -- K037122 registers
    { 0x780c0000, 0x780c0003 },   -- comm
    { 0x7d000000, 0x7d03ffff },   -- sysreg, M48T58, K056800
}
for i, r in ipairs(RANGES) do
    bootlog_subs[#bootlog_subs + 1] = sp:install_read_tap(r[1], r[2], "bl_r" .. i, function(o, d, mk) log("R", o, d, mk) end)
    bootlog_subs[#bootlog_subs + 1] = sp:install_write_tap(r[1], r[2], "bl_w" .. i, function(o, d, mk) log("W", o, d, mk) end)
end
bootlog_subs[#bootlog_subs + 1] = sp:install_read_tap(0x78000000, 0x7800ffff, "bl_sr", function(o, d, mk) nsh = nsh + 1 end)
bootlog_subs[#bootlog_subs + 1] = sp:install_write_tap(0x78000000, 0x7800ffff, "bl_sw", function(o, d, mk) nsh = nsh + 1 end)
bootlog_subs[#bootlog_subs + 1] = sp:install_write_tap(0x74020000, 0x7407ffff, "bl_kw", function(o, d, mk) nk = nk + 1 end)

bootlog_subs[#bootlog_subs + 1] = emu.add_machine_frame_notifier(function()
    if nsh > 0 then f:write(string.format("S %d %d\n", fr, nsh)) end
    if nk > 0 then f:write(string.format("C %d %d\n", fr, nk)) end
    nsh, nk = 0, 0
    fr = screen:frame_number()
    if bootlog_err then print("BOOTLOG_TAP_ERROR " .. bootlog_err) end
    if fr >= last then print("BOOTLOG_DONE"); m:exit() end
end)
