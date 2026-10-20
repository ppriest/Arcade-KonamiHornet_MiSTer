-- SPDX-License-Identifier: GPL-3.0-or-later
-- What the game asks of the Voodoo over a long run (docs/RASTER.md, "What the game uses").
-- Driven by scripts/mame_voodoo_census.py through run.lua; MAME runs -nodrc so the taps on the
-- SHARC's data space see its Voodoo accesses.
--
-- census.txt at CORE_TO:
--   reg <name> <count>                every register written (MAME's alias map applied)
--   val <name> <hex> <count>          every distinct value of the mode registers
--   tri <param mask> <count>          the parameters written between triangle commands
--   space <name> <count>              texture memory and LFB writes, reads

local out    = os.getenv("CORE_OUT")
local to     = tonumber(os.getenv("CORE_TO") or "30000")
local events = os.getenv("CORE_EVENTS") or ""

local m  = manager.machine
local ds = m.devices[":dsp1"].spaces["data"]

voodoocensus_subs = {}
voodoocensus_err  = nil

local pressed, held = {}, {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end

-- MAME's register names (voodoo_regs.h) for the first 0x100, and its alias map (voodoo.cpp:229)
local base = { [0]="status", "intrCtrl", "vertexAx", "vertexAy", "vertexBx", "vertexBy", "vertexCx", "vertexCy",
  "startR", "startG", "startB", "startZ", "startA", "startS", "startT", "startW",
  "dRdX", "dGdX", "dBdX", "dZdX", "dAdX", "dSdX", "dTdX", "dWdX",
  "dRdY", "dGdY", "dBdY", "dZdY", "dAdY", "dSdY", "dTdY", "dWdY", "triangleCMD", "r21" }
local names = {}
for i = 0, 0x21 do names[i] = base[i] end
for i = 2, 0x1f do names[0x20 + i] = "f" .. base[i] end
names[0x40] = "ftriangleCMD"
local more = { [0x41]="fbzColorPath", [0x42]="fogMode", [0x43]="alphaMode", [0x44]="fbzMode", [0x45]="lfbMode",
  [0x46]="clipLeftRight", [0x47]="clipLowYHighY", [0x48]="nopCMD", [0x49]="fastfillCMD", [0x4a]="swapbufferCMD",
  [0x4b]="fogColor", [0x4c]="zaColor", [0x4d]="chromaKey", [0x50]="stipple", [0x51]="color0", [0x52]="color1",
  [0x80]="fbiInit4", [0x81]="vRetrace", [0x82]="backPorch", [0x83]="videoDimensions", [0x84]="fbiInit0",
  [0x85]="fbiInit1", [0x86]="fbiInit2", [0x87]="fbiInit3", [0x88]="hSync", [0x89]="vSync", [0x8a]="clutData",
  [0x8b]="dacData", [0xc0]="textureMode", [0xc1]="tLOD", [0xc2]="tDetail", [0xc3]="texBaseAddr",
  [0xc4]="texBaseAddr_1", [0xc5]="texBaseAddr_2", [0xc6]="texBaseAddr_3_8", [0xc7]="trexInit0", [0xc8]="trexInit1" }
for k, v in pairs(more) do names[k] = v end
for i = 0x58, 0x77 do names[i] = "fogTable" end
for i = 0xc9, 0xe0 do names[i] = "nccTable" end
local alias = { [0]=0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
  0x08, 0x10, 0x18, 0x09, 0x11, 0x19, 0x0a, 0x12, 0x1a, 0x0b, 0x13, 0x1b, 0x0c, 0x14, 0x1c,
  0x0d, 0x15, 0x1d, 0x0e, 0x16, 0x1e, 0x0f, 0x17, 0x1f }
for i = 0, 0x1f do alias[0x20 + i] = alias[i] + 0x20 end
alias[0x20] = 0x20; alias[0x21] = 0x21

local modes = { fbzColorPath=1, fogMode=1, alphaMode=1, fbzMode=1, lfbMode=1, textureMode=1, tLOD=1,
  tDetail=1, chromaKey=1, clipLeftRight=1, clipLowYHighY=1, fbiInit0=1, fbiInit1=1, fbiInit2=1, fbiInit3=1,
  stipple=1, zaColor=1, videoDimensions=1 }
-- parameter bits for the per-triangle set: R G B Z A S T W, by base register 0x08-0x0f and their d/dX d/dY
local pbit = {}
for i = 0, 7 do pbit[0x08 + i] = i; pbit[0x10 + i] = i; pbit[0x18 + i] = i end

local regs, vals, tris, space = {}, {}, {}, {}
local pmask, chips = 0, 0
local function inc(t, k) t[k] = (t[k] or 0) + 1 end

local function onw(offset, data)
    local w = (offset - 0x2400000)
    if w >= 0x200000 then inc(space, "texture") return end
    if w >= 0x100000 then inc(space, "lfb") return end
    local reg = w & 0xff
    if (w >> 19) & 1 == 1 and reg < 0x40 then reg = alias[reg] end
    local chip = (w >> 8) & 0xf
    local n = names[reg] or string.format("r%02x", reg)
    if chip ~= 0 then n = n .. "@" .. chip end
    inc(regs, n)
    local bn = names[reg]
    if bn and modes[bn] then inc(vals, n .. " " .. string.format("%08X", data)) end
    local b = reg >= 0x20 and reg < 0x40 and reg - 0x20 or reg
    if pbit[b] then pmask = pmask | (1 << pbit[b]) end
    if reg == 0x20 or reg == 0x40 then
        inc(tris, string.format("%02X", pmask)); pmask = 0
    end
end

local function dump()
    local f = io.open(out .. "/census.txt", "w")
    local function sorted(t, fmt)
        local ks = {}
        for k in pairs(t) do ks[#ks + 1] = k end
        table.sort(ks)
        for _, k in ipairs(ks) do f:write(string.format(fmt, k, t[k])) end
    end
    sorted(regs, "reg %s %d\n")
    sorted(vals, "val %s %d\n")
    sorted(tris, "tri %s %d\n")
    sorted(space, "space %s %d\n")
    f:close()
end

voodoocensus_subs[#voodoocensus_subs + 1] = ds:install_write_tap(0x2400000, 0x27fffff, "voodoocensus_w",
    function(offset, data, mask)
        local ok, e = pcall(onw, offset, data)
        if not ok and not voodoocensus_err then voodoocensus_err = tostring(e) end
    end)
voodoocensus_subs[#voodoocensus_subs + 1] = ds:install_read_tap(0x2400000, 0x27fffff, "voodoocensus_r",
    function(offset, data, mask) inc(space, "read") end)

voodoocensus_subs[#voodoocensus_subs + 1] = emu.add_machine_frame_notifier(function()
    local f = m.screens[":screen"]:frame_number()
    for _, p in ipairs(pressed) do
        if f == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = f + p.len end
        if held[p] and f >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    if f % 1000 == 0 then dump() end
    if voodoocensus_err then print("VOODOOCENSUS_TAP_ERROR " .. voodoocensus_err) end
    if f >= to then
        dump()
        print("VOODOOCENSUS_DONE")
        m:exit()
    end
end)
