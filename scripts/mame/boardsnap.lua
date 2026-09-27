-- SPDX-License-Identifier: GPL-3.0-or-later
-- The whole board at the end of one frame, for sim/board_tb to start from, then MAME's output
-- over the frames after it to compare with. Driven by scripts/mame_board_snapshot.py through
-- run.lua; MAME runs -nodrc (the benches' reference state is the interpreters').
--
-- At the end of frame CORE_FRAME, in CORE_OUT/start/:
--   <dev>.txt        every save item of <dev> up to 256 bytes: "name count size v0 v1 ..." (hex)
--   <dev>_state.txt  every debugger state entry of a CPU, "name value" (hex)
--   <dev>/<item>.bin every larger item, raw as MAME stores it (host order, little-endian)
--   workram.bin      the PPC's 4 MB work RAM, big-endian (DRC fastram: not a save item)
--   ports.txt        every input port's value, "tag value"
--   screen.txt       the screen's geometry, refresh rate and beam line
-- Then at the end of each of the CORE_FRAMES frames after it, in CORE_OUT/f<n>/:
--   voodoo0.txt      the Voodoo's small save items (front buffer, rgboffs, swap state)
--   fb.bin           the Voodoo's 2 MB frame buffer
--   screen.bin       MAME's composed screen, 32-bit ARGB, visible_width x visible_height
--
--   CORE_OUT, CORE_FRAME, CORE_FRAMES, CORE_EVENTS ("frame:port:mask:len,...")

local out    = os.getenv("CORE_OUT")
local frame  = tonumber(os.getenv("CORE_FRAME") or "7500")
local frames = tonumber(os.getenv("CORE_FRAMES") or "4")
local events = os.getenv("CORE_EVENTS") or ""

local m      = manager.machine
local screen = m.screens[":screen"]
local DEVICES = { ":", ":maincpu", ":dsp1", ":voodoo0", ":k033906_1", ":k037122_0", ":konppc",
                  ":m48t58", ":k056800", ":security_eeprom", ":watchdog" }

boardsnap_subs = {}

local pressed, held = {}, {}
for f, port, mask, len in events:gmatch("(%d+):(%w+):(%x+):(%d+)") do
    pressed[#pressed + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end

local function mkdir(d)
    os.execute('mkdir "' .. d:gsub("/", "\\") .. '" 2>nul')
end

local function fname(tag)
    local s = tag:gsub("^:", ""):gsub("[:/]", "_")
    return s == "" and "driver" or s
end

-- all bytes of an item, through read_block (offsets and counts in bytes)
local function item_bytes(it)
    local n = it.count * it.size
    local parts = {}
    for base = 0, n - 1, 0x100000 do
        parts[#parts + 1] = it:read_block(base, math.min(0x100000, n - base))
    end
    return table.concat(parts)
end

local function dump_device(dir, tag, small_only)
    local dev = m.devices[tag]
    if not dev then return end
    local base = dir .. "/" .. fname(tag)
    local st = io.open(base .. ".txt", "w")
    local made = false
    for name, idx in pairs(dev.items) do
        local it = emu.item(idx)
        local bytes = it.count * it.size
        if bytes <= 256 then
            local b = item_bytes(it)
            local v = {}
            for i = 0, it.count - 1 do
                if it.size == 8 then
                    local lo, hi = string.unpack("<I4I4", b, i * 8 + 1)
                    v[#v + 1] = string.format("%X%08X", hi, lo)
                else
                    v[#v + 1] = string.format("%X", (string.unpack("<I" .. it.size, b, i * it.size + 1)))
                end
            end
            st:write(string.format("%s %d %d %s\n", name, it.count, it.size, table.concat(v, " ")))
        elseif not small_only then
            if not made then mkdir(base); made = true end
            local f = io.open(base .. "/" .. name:gsub("[^%w_.]", "_") .. ".bin", "wb")
            f:write(item_bytes(it))
            f:close()
        end
    end
    st:close()
    -- the debugger's view: registers MAME does not save (SHARC PCSTK, CURLCNTR)
    if not small_only and dev.state then
        local sf = io.open(base .. "_state.txt", "w")
        for name, e in pairs(dev.state) do sf:write(string.format("%s %X\n", name, e.value)) end
        sf:close()
    end
end

local function dump_start()
    local dir = out .. "/start"
    mkdir(dir)
    for _, tag in ipairs(DEVICES) do dump_device(dir, tag, false) end

    local sp = m.devices[":maincpu"].spaces["program"]
    local ram = io.open(dir .. "/workram.bin", "wb")
    local chunk = {}
    for a = 0, 0x3ffffc, 4 do
        chunk[#chunk + 1] = string.pack(">I4", sp:read_u32(a))
        if #chunk == 4096 then ram:write(table.concat(chunk)); chunk = {} end
    end
    ram:write(table.concat(chunk))
    ram:close()

    local pf = io.open(dir .. "/ports.txt", "w")
    for tag, port in pairs(m.ioport.ports) do pf:write(string.format("%s %X\n", tag, port:read())) end
    pf:close()

    local sf = io.open(dir .. "/screen.txt", "w")
    local _, w, h = screen:pixels()
    sf:write(string.format("width %d\nheight %d\nvisible_width %d\nvisible_height %d\nrefresh_hz %.6f\nframe %d\n",
        screen.width, screen.height, w, h, screen.refresh, screen:frame_number()))
    sf:close()
end

local function dump_frame(n)
    local dir = out .. "/f" .. n
    mkdir(dir)
    dump_device(dir, ":voodoo0", true)
    for name, idx in pairs(m.devices[":voodoo0"].items) do
        if name:find("m_fbram") then
            local it = emu.item(idx)
            local f = io.open(dir .. "/fb.bin", "wb")
            f:write(it:read_block(0, 0x200000))
            f:close()
        end
    end
    local f = io.open(dir .. "/screen.bin", "wb")
    local px = screen:pixels()     -- also returns width and height, which are not written
    f:write(px)
    f:close()
end

local state, first = 0, 0
boardsnap_subs[#boardsnap_subs + 1] = emu.add_machine_frame_notifier(function()
    local f = screen:frame_number()
    for _, p in ipairs(pressed) do
        if f == p.f then m.ioport.ports[p.port]:field(p.mask):set_value(1); held[p] = f + p.len end
        if held[p] and f >= held[p] then m.ioport.ports[p.port]:field(p.mask):set_value(0); held[p] = nil end
    end
    if state == 0 and f >= frame then
        state = 1                   -- before the dump: an error must not repeat it every frame
        first = f
        dump_start()
        print("BOARDSNAP_START " .. f)
    elseif state == 1 then
        dump_frame(f - first)
        if f - first >= frames then
            print("BOARDSNAP_DONE")
            m:exit()
        end
    end
end)
