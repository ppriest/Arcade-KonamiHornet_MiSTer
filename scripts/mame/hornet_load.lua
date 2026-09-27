-- Workload measurement for Konami Hornet (gradius4). Driven by
-- scripts/hornet_load.py through run.lua. Environment:
--
--   CORE_OUT       output directory
--   CORE_EVENTS    "frame:port:mask:len,..."  press a field for len frames
--                  (port without the leading colon, e.g. IN2)
--   CORE_SNAPS     "frame,frame,..."           snapshot frames
--   CORE_ATTRACT   "from:to"                   frames labelled attract
--   CORE_PLAY      "from:to"                   frames labelled play; the
--                                              script drives the controls
--   CORE_END       frame to exit at
--   CORE_SR        PC sample rate in Hz
--   CORE_STATS     1 to read the Voodoo pixel counters before each nopCMD
--                  that clears them (a CPU-style read: it flushes the FIFO)
--   CORE_DASM      "frame|cmd|cmd,frame|cmd..." debugger commands to run at
--                  a frame (needs -debug -debugger none; see hornet_load.py --dasm)
--
-- Outputs frames.csv (one row per frame), and per phase: pc_<cpu>_<phase>.txt
-- (PC histogram), modes_<phase>.txt (register value and triangle-state
-- histograms).

local OUT    = os.getenv("CORE_OUT") or "."
local ENDF   = tonumber(os.getenv("CORE_END") or "3000")
local SR     = tonumber(os.getenv("CORE_SR") or "20000")
local STATS  = os.getenv("CORE_STATS") == "1"
local m      = manager.machine

local function range(s)
    local a, b = (s or ""):match("^(%d+):(%d+)$")
    return tonumber(a or "-1"), tonumber(b or "-2")
end
local AT_A, AT_B = range(os.getenv("CORE_ATTRACT"))
local PL_A, PL_B = range(os.getenv("CORE_PLAY"))

local events = {}
for spec in string.gmatch(os.getenv("CORE_EVENTS") or "", "([^,]+)") do
    local fr, port, mask, len = spec:match("^(%d+):([^:]+):(%x+):(%d+)$")
    assert(fr, "bad event " .. spec)
    events[#events + 1] = { f = tonumber(fr), port = port, mask = tonumber(mask, 16), len = tonumber(len) }
end
local snaps = {}
for s in string.gmatch(os.getenv("CORE_SNAPS") or "", "(%d+)") do snaps[tonumber(s)] = true end

local function field(port, mask)
    if port:sub(1, 1) ~= ":" then port = ":" .. port end
    return m.ioport.ports[port]:field(mask)
end

-- Global on purpose: taps held only by a local stop firing when collected.
core_taps = {}

local dasm = {}
for spec in string.gmatch(os.getenv("CORE_DASM") or "", "([^,]+)") do
    local parts = {}
    for p in string.gmatch(spec, "([^|]+)") do parts[#parts + 1] = p end
    dasm[tonumber(table.remove(parts, 1))] = parts
end
if next(dasm) then m.debugger.execution_state = "run" end

local frame = 0
local phase = "boot"
local function phase_of(f)
    if f >= AT_A and f <= AT_B then return "attract" end
    if f >= PL_A and f <= PL_B then return "play" end
    return "boot"
end

-------------------------------------------------------------------------------
-- Per-frame counters
local C = {}
local CNAMES = { "tri", "ftri", "fastfill", "swap", "nop", "nopreset", "regw",
    "lfbw", "texw", "texsrc_r", "tri_area", "tri_area_tex", "tri_area_blend",
    "tri_area_bilin", "tri_area_z", "ppc_sh_w", "ppc_sh_r", "ppc_comm_w", "ppc_comm_r",
    "sh_sh_w", "sh_sh_r", "sh_comm_w", "sh_comm_r", "sh_reset",
    "remap", "swizzle", "ppc_idle", "ppc_work", "fastfill_px",
    "pin", "chroma", "zfail", "afail", "pout" }
local function clear() for _, n in ipairs(CNAMES) do C[n] = 0 end end
clear()

-- Histograms per phase: H[phase][key][value] = count
local H = { boot = {}, attract = {}, play = {} }
local function hist(key, val, n)
    local t = H[phase][key]
    if not t then t = {}; H[phase][key] = t end
    t[val] = (t[val] or 0) + (n or 1)
end

-------------------------------------------------------------------------------
-- Voodoo register writes (SHARC data space, word addressed)
local R = {}                                   -- last value per register index
local TRACK = { [0x41] = "fbzColorPath", [0x42] = "fogMode", [0x43] = "alphaMode",
    [0x44] = "fbzMode", [0x45] = "lfbMode", [0xc0] = "textureMode", [0xc1] = "tLOD",
    [0xc2] = "tDetail", [0x84] = "fbiInit0", [0x87] = "fbiInit3" }

local function s16(v) v = v & 0xffff; if v >= 0x8000 then v = v - 0x10000 end return v end
local function f32(v) return (string.unpack("<f", string.pack("<I4", v & 0xffffffff))) end

local function triangle(fl)
    local ax, ay, bx, by, cx, cy
    if fl then
        ax, ay = f32(R[0x22] or 0), f32(R[0x23] or 0)
        bx, by = f32(R[0x24] or 0), f32(R[0x25] or 0)
        cx, cy = f32(R[0x26] or 0), f32(R[0x27] or 0)
    else
        ax, ay = s16(R[0x02] or 0) / 16, s16(R[0x03] or 0) / 16
        bx, by = s16(R[0x04] or 0) / 16, s16(R[0x05] or 0) / 16
        cx, cy = s16(R[0x06] or 0) / 16, s16(R[0x07] or 0) / 16
    end
    local area = math.abs((bx - ax) * (cy - ay) - (cx - ax) * (by - ay)) * 0.5
    if area ~= area or area > 1e6 then area = 0 end          -- NaN / garbage
    local cp, fz, am, fm = R[0x41] or 0, R[0x44] or 0, R[0x43] or 0, R[0x42] or 0
    local tm, tl = R[0xc0] or 0, R[0xc1] or 0
    C.tri_area = C.tri_area + area
    local tex = (cp >> 27) & 1 == 1
    if tex then
        C.tri_area_tex = C.tri_area_tex + area
        if (tm >> 1) & 3 ~= 0 then C.tri_area_bilin = C.tri_area_bilin + area end
    end
    if (am >> 4) & 1 == 1 then C.tri_area_blend = C.tri_area_blend + area end
    if (fz >> 4) & 1 == 1 then C.tri_area_z = C.tri_area_z + area end
    local key = string.format("cp=%08x fz=%08x am=%08x fm=%08x tm=%08x tlod=%08x",
        cp, fz, am, fm, tex and tm or 0, tex and tl or 0)
    hist("tri_state", key, 1)
    hist("tri_state_area", key, math.floor(area + 0.5))
end

-- voodoo.cpp s_alias_map: the alternate layout of registers 0x00-0x3f,
-- selected by address bit 21 (word bit 19) when fbiInit3 bit 0 is set.
local ALIAS = { [0] = 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x10, 0x18, 0x09, 0x11, 0x19, 0x0a, 0x12, 0x1a, 0x0b, 0x13, 0x1b,
    0x0c, 0x14, 0x1c, 0x0d, 0x15, 0x1d, 0x0e, 0x16, 0x1e, 0x0f, 0x17, 0x1f,
    0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
    0x28, 0x30, 0x38, 0x29, 0x31, 0x39, 0x2a, 0x32, 0x3a, 0x2b, 0x33, 0x3b,
    0x2c, 0x34, 0x3c, 0x2d, 0x35, 0x3d, 0x2e, 0x36, 0x3e, 0x2f, 0x37, 0x3f }

-- Voodoo statistics registers (24-bit, cleared by nopCMD bit 0)
local SREG = { pin = 0x2400053, chroma = 0x2400054, zfail = 0x2400055, afail = 0x2400056, pout = 0x2400057 }
local stat_space = m.devices[":dsp1"].spaces["data"]
function stats_accumulate()
    for k, a in pairs(SREG) do C[k] = C[k] + (stat_space:read_u32(a) & 0xffffff) end
end

local function voodoo_reg_w(offset, data, mask)
    local w = offset - 0x2400000
    local reg = w & 0xff
    local chip = (w >> 8) & 0xf
    C.regw = C.regw + 1
    if (w >> 19) & 1 == 1 then
        C.remap = C.remap + 1
        if reg < 0x40 and ((R[0x87] or 0) & 1) == 1 then reg = ALIAS[reg] end
    end
    if (w >> 18) & 1 == 1 then C.swizzle = C.swizzle + 1 end
    R[reg] = data
    if reg == 0x20 then C.tri = C.tri + 1; triangle(false)
    elseif reg == 0x40 then C.ftri = C.ftri + 1; triangle(true)
    elseif reg == 0x49 then
        C.fastfill = C.fastfill + 1
        hist("fastfill_fbzMode", string.format("%08x", R[0x44] or 0))
        local lr, tb = R[0x46] or 0, R[0x47] or 0
        local wdt = (lr & 0x3ff) - ((lr >> 16) & 0x3ff)
        local hgt = (tb & 0x3ff) - ((tb >> 16) & 0x3ff)
        if wdt > 0 and hgt > 0 then C.fastfill_px = C.fastfill_px + wdt * hgt end
    elseif reg == 0x4a then C.swap = C.swap + 1; hist("swapbufferCMD", string.format("%08x", data))
    elseif reg == 0x48 then
        C.nop = C.nop + 1
        if data & 1 == 1 then
            C.nopreset = C.nopreset + 1
            -- gradius4 clears the counters with nopCMD bit 0 several times a
            -- frame; read them just before each clear. The tap runs before
            -- the write reaches the device.
            if STATS then stats_accumulate() end
        end
    end
    local name = TRACK[reg]
    if name then hist(name .. (reg >= 0xc0 and string.format("[chip%x]", chip) or ""), string.format("%08x", data)) end
    hist("regs_written", string.format("%02x", reg))
end

local dsp_data = m.devices[":dsp1"].spaces["data"]
local ppc      = m.devices[":maincpu"].spaces["program"]

core_taps[#core_taps + 1] = dsp_data:install_write_tap(0x2400000, 0x24fffff, "vreg", voodoo_reg_w)
core_taps[#core_taps + 1] = dsp_data:install_write_tap(0x2500000, 0x25fffff, "vlfb",
    function(o, d, mk) C.lfbw = C.lfbw + 1 end)
core_taps[#core_taps + 1] = dsp_data:install_write_tap(0x2600000, 0x27fffff, "vtex",
    function(o, d, mk) C.texw = C.texw + 1 end)
core_taps[#core_taps + 1] = dsp_data:install_read_tap(0x3600000, 0x37fffff, "texsrc",
    function(o, d, mk) C.texsrc_r = C.texsrc_r + 1 end)
core_taps[#core_taps + 1] = dsp_data:install_write_tap(0x0400000, 0x041ffff, "shw",
    function(o, d, mk) C.sh_sh_w = C.sh_sh_w + 1 end)
core_taps[#core_taps + 1] = dsp_data:install_read_tap(0x0400000, 0x041ffff, "shr",
    function(o, d, mk) C.sh_sh_r = C.sh_sh_r + 1 end)
core_taps[#core_taps + 1] = dsp_data:install_write_tap(0x3400000, 0x34000ff, "scw",
    function(o, d, mk) C.sh_comm_w = C.sh_comm_w + 1 end)
core_taps[#core_taps + 1] = dsp_data:install_read_tap(0x3400000, 0x34000ff, "scr",
    function(o, d, mk) C.sh_comm_r = C.sh_comm_r + 1 end)
-- No tap on the SHARC program space: it is 64 bits wide and a tap callback
-- there receives a mask above 2^63, which sol refuses ("integer value will be
-- misrepresented in lua"), killing MAME. Code uploads are seen as PPC writes
-- to the shared RAM plus a SHARC reset (sh_reset) instead.

local function popbytes(mk)
    local n = 0
    for b = 0, 3 do if (mk >> (b * 8)) & 0xff ~= 0 then n = n + 1 end end
    return n
end
local last_reset_bit = 0
core_taps[#core_taps + 1] = ppc:install_write_tap(0x78000000, 0x7800ffff, "ppcshw",
    function(o, d, mk) C.ppc_sh_w = C.ppc_sh_w + popbytes(mk) end)
core_taps[#core_taps + 1] = ppc:install_read_tap(0x78000000, 0x7800ffff, "ppcshr",
    function(o, d, mk) C.ppc_sh_r = C.ppc_sh_r + popbytes(mk) end)
core_taps[#core_taps + 1] = ppc:install_write_tap(0x780c0000, 0x780c0003, "ppccw",
    function(o, d, mk)
        C.ppc_comm_w = C.ppc_comm_w + 1
        if mk & 0xff000000 ~= 0 then
            local b = (d >> 28) & 1
            if b == 1 and last_reset_bit == 0 then C.sh_reset = C.sh_reset + 1 end
            last_reset_bit = b
            hist("ppc_comm_hi", string.format("%02x", (d >> 24) & 0xff))
        end
    end)
core_taps[#core_taps + 1] = ppc:install_read_tap(0x780c0000, 0x780c0003, "ppccr",
    function(o, d, mk) C.ppc_comm_r = C.ppc_comm_r + 1 end)

-------------------------------------------------------------------------------
-- PC sampling
local CPUS = { { tag = ":maincpu", name = "ppc" }, { tag = ":dsp1", name = "sharc" },
    { tag = ":audiocpu", name = "m68k" } }
local PCH = {}      -- PCH[phase][name][pc] = n
for _, p in ipairs({ "boot", "attract", "play" }) do
    PCH[p] = {}
    for _, c in ipairs(CPUS) do PCH[p][c.name] = {} end
end
local states = {}
for _, c in ipairs(CPUS) do states[c.name] = m.devices[c.tag].state["CURPC"] end
local samples = 0
local FS = {}       -- per-frame samples by cpu name: FS[name][pc] = n
for _, c in ipairs(CPUS) do FS[c.name] = {} end

-- PPC idle classification (gradius4 ver JAC). The main loop at
-- 0x802024D4-0x8020253F spins until the vblank counter at 0x40(r31) changes,
-- calling the helpers below on every pass (0x80205F74 polls the SHARC status
-- byte at 0x780C0003). A sample in the loop means idle; a sample in a helper
-- keeps the previous state, since the helpers are also called from frame work;
-- anything else is work. Found from hornet_dasm output, not general.
local PPC_LOOP = { 0x802024D4, 0x8020253F }
local PPC_HELPERS = { { 0x80205F74, 0x80205F97 }, { 0x80209414, 0x80209417 },
    { 0x80213340, 0x80213457 }, { 0x80213734, 0x802137DF }, { 0x802136BC, 0x802136FF },
    { 0x8021303C, 0x8021304F }, { 0x8020964C, 0x802096C7 } }
local ppc_state_idle = true
local function ppc_classify(pc)
    if pc >= PPC_LOOP[1] and pc <= PPC_LOOP[2] then ppc_state_idle = true; return end
    for _, r in ipairs(PPC_HELPERS) do
        if pc >= r[1] and pc <= r[2] then return end
    end
    ppc_state_idle = false
end

local sampler = coroutine.wrap(function()
    while true do
        emu.wait(1 / SR)
        samples = samples + 1
        ppc_classify(states.ppc.value)
        if ppc_state_idle then C.ppc_idle = C.ppc_idle + 1 else C.ppc_work = C.ppc_work + 1 end
        for _, c in ipairs(CPUS) do
            local pc = states[c.name].value
            local t = PCH[phase][c.name]
            t[pc] = (t[pc] or 0) + 1
            local ft = FS[c.name]
            ft[pc] = (ft[pc] or 0) + 1
        end
    end
end)

-- Per-frame PC histograms are written compactly so the idle loops can be
-- chosen after the run: pcs_<cpu>.txt gets "frame pc:n pc:n ..." lines.
local pcf = {}
for _, c in ipairs(CPUS) do pcf[c.name] = assert(io.open(OUT .. "/pcs_" .. c.name .. ".txt", "w")) end

-------------------------------------------------------------------------------

local csv = assert(io.open(OUT .. "/frames.csv", "w"))
local hdr = { "frame", "phase", "samples" }
for _, n in ipairs(CNAMES) do hdr[#hdr + 1] = n end
csv:write(table.concat(hdr, ","), "\n")

-------------------------------------------------------------------------------
-- Controls
local held = {}     -- field -> release frame
local function press(port, mask, len)
    local f = field(port, mask)
    f:set_value(1)
    held[f] = frame + len
end
local rng = 12345
local function rand(n) rng = (rng * 1103515245 + 12345) & 0x7fffffff; return rng % n end

local function drive_play(f)
    -- shot and missile: pulse 3 frames on / 3 off
    local on = (f % 6) < 3
    field(":IN0", 0x04):set_value(on and 1 or 0)
    field(":IN0", 0x02):set_value(on and 1 or 0)
    -- movement: hold a random direction for 20..80 frames
    if not core_dir_until or f >= core_dir_until then
        for _, b in ipairs({ 0x40, 0x20, 0x10, 0x08 }) do field(":IN0", b):set_value(0) end
        local d = rand(6)
        local dirs = { { 0x40 }, { 0x20 }, { 0x10 }, { 0x08 }, { 0x40, 0x08 }, { 0x20, 0x08 } }
        for _, b in ipairs(dirs[d + 1]) do field(":IN0", b):set_value(1) end
        core_dir_until = f + 20 + rand(60)
    end
    -- power-up button every 90 frames
    if f % 90 == 0 then press(":IN0", 0x01, 3) end
    -- keep continuing: coin + start every 600 frames
    if f % 600 == 300 then press(":IN2", 0x80, 4) end
    if f % 600 == 310 then press(":IN0", 0x80, 4) end
end

-------------------------------------------------------------------------------
core_frame_sub = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    -- close out the frame just finished
    local row = { tostring(frame), phase, tostring(samples) }
    for _, n in ipairs(CNAMES) do
        local v = C[n]
        row[#row + 1] = (math.type(v) == "float") and string.format("%.1f", v) or tostring(v)
    end
    csv:write(table.concat(row, ","), "\n")
    for name, t in pairs(FS) do
        local parts = { tostring(frame) }
        for pc, n in pairs(t) do parts[#parts + 1] = string.format("%x:%d", pc, n) end
        pcf[name]:write(table.concat(parts, " "), "\n")
        FS[name] = {}
    end
    clear()
    samples = 0

    -- next frame
    phase = phase_of(frame + 1)
    for f, rel in pairs(held) do
        if frame >= rel then f:set_value(0); held[f] = nil end
    end
    for _, e in ipairs(events) do
        if e.f == frame then press(e.port, e.mask, e.len) end
    end
    if phase == "play" then drive_play(frame) end
    if snaps[frame] then m.video:snapshot() end
    if dasm[frame] then
        for _, c in ipairs(dasm[frame]) do m.debugger:command((c:gsub(";", ","))) end
    end
    if frame >= ENDF then
        csv:close()
        for _, fh in pairs(pcf) do fh:close() end
        for p, cpus in pairs(PCH) do
            for name, t in pairs(cpus) do
                local fh = io.open(OUT .. "/pc_" .. name .. "_" .. p .. ".txt", "w")
                for pc, n in pairs(t) do fh:write(string.format("%x %d\n", pc, n)) end
                fh:close()
            end
        end
        for p, keys in pairs(H) do
            local fh = io.open(OUT .. "/modes_" .. p .. ".txt", "w")
            for key, t in pairs(keys) do
                for v, n in pairs(t) do fh:write(key, "\t", v, "\t", tostring(n), "\n") end
            end
            fh:close()
        end
        print("HORNET_LOAD_OK")
        m:exit()
    end
end)

sampler()
