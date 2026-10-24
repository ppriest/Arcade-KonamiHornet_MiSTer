-- SPDX-License-Identifier: GPL-3.0-or-later
-- The Voodoo's work over a few frames, for sim/voodoo_tb to replay into SpinalVoodoo.
-- Driven by scripts/mame_voodoo_window.py through run.lua; MAME runs -nodrc so the taps on the
-- SHARC's data space see its Voodoo accesses.
--
-- At the end of frame CORE_FRAME:  start/ (vitems.txt, fbram.bin)
-- then every SHARC access to the Voodoo window, writes.txt: "F frame" markers at each frame end,
--   "W offset data" (offset = 32-bit word index into the 16 MB PCI space) and "R offset data"
-- At the end of frame CORE_FRAME + CORE_FRAMES: end/ (vitems.txt, fbram.bin)
--
-- vitems.txt: every :voodoo0 item of up to 256 elements, "name count v0 v1 ..." (hex).
-- fbram.bin: m_fbram, 2 MB frame buffer then 4 MB TMU 0 memory.

local out    = os.getenv("CORE_OUT")
local frame  = tonumber(os.getenv("CORE_FRAME") or "3000")
local frames = tonumber(os.getenv("CORE_FRAMES") or "1")
local events = os.getenv("CORE_EVENTS") or ""
local pokes  = os.getenv("CORE_POKES") or ""       -- "from:addr:value,...": as boardsnap.lua's

local m   = manager.machine
local vd  = m.devices[":voodoo0"]

-- CORE_DIPS "Field=Setting;...": DIP switches, set before the game first reads them
for spec in (os.getenv("CORE_DIPS") or ""):gmatch("[^;]+") do
    local name, want = spec:match("^(.-)=(.*)$")
    local done = false
    for _, port in pairs(m.ioport.ports) do
        local fld = port.fields[name]
        if fld then
            for raw, label in pairs(fld.settings) do
                if label == want then fld.user_value = raw; done = true end
            end
        end
    end
    if not done then error("no DIP setting " .. spec) end
end
local ds  = m.devices[":dsp1"].spaces["data"]

voodoowin_subs = {}
voodoowin_err  = nil

local poke = {}
for f, a, v in pokes:gmatch("(%d+):(%x+):(%x+)") do
    poke[#poke + 1] = { f = tonumber(f), a = tonumber(a, 16), v = tonumber(v, 16) }
end
local prog = m.devices[":maincpu"].spaces["program"]
local pressed, held = {}, {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end

local function dump(dir)
    os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
    local st = io.open(dir .. "/vitems.txt", "w")
    for name, idx in pairs(vd.items) do
        local it = emu.item(idx)
        if name:find("m_fbram") then
            -- read_block: element reads through Lua take over an hour for 6 MB
            local f = io.open(dir .. "/fbram.bin", "wb")
            for base = 0, it.count - 1, 0x100000 do
                f:write(it:read_block(base, math.min(0x100000, it.count - base)))
            end
            f:close()
        elseif it.count <= 256 then
            -- 8-byte items can exceed a Lua integer through read(); take their bytes instead
            local v = {}
            for i = 0, it.count - 1 do
                if it.size == 8 then
                    local lo, hi = string.unpack("<I4I4", it:read_block(i * 8, 8))    -- offsets in bytes
                    v[#v + 1] = string.format("%X%08X", hi, lo)
                else
                    v[#v + 1] = string.format("%X", it:read(i))
                end
            end
            st:write(string.format("%s %d %s\n", name, it.count, table.concat(v, " ")))
        end
    end
    st:close()
end

local wf
local function logw(rw, offset, data)
    local ok, e = pcall(function() wf:write(string.format("%s %06X %08X\n", rw, offset - 0x2400000, data)) end)
    if not ok and not voodoowin_err then voodoowin_err = tostring(e) end
end

local state = 0
voodoowin_subs[#voodoowin_subs + 1] = emu.add_machine_frame_notifier(function()
    local f = m.screens[":screen"]:frame_number()
    for _, p in ipairs(pressed) do
        if f == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = f + p.len end
        if held[p] and f >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    if state == 0 then
        for _, p in ipairs(poke) do
            if f >= p.f then prog:write_u8(p.a, p.v) end
        end
    end
    if state == 0 and f >= frame then
        dump(out .. "/start")
        wf = assert(io.open(out .. "/writes.txt", "w"))
        voodoowin_subs[#voodoowin_subs + 1] = ds:install_write_tap(0x2400000, 0x27fffff, "voodoowin_w",
            function(offset, data, mask) logw("W", offset, data) end)
        voodoowin_subs[#voodoowin_subs + 1] = ds:install_read_tap(0x2400000, 0x27fffff, "voodoowin_r",
            function(offset, data, mask) logw("R", offset, data) end)
        state = 1
    elseif state == 1 then
        wf:write(string.format("F %d\n", f))
        if f >= frame + frames then
            wf:close()
            dump(out .. "/end")
            state = 2
            print("VOODOOWIN_DONE")
            m:exit()
        end
    end
    if voodoowin_err then print("VOODOOWIN_TAP_ERROR " .. voodoowin_err) end
end)
