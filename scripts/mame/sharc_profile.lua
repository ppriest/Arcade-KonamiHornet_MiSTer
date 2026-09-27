-- SHARC (:dsp1) usage profile for gradius4. Driven by scripts/sharc_profile.py through run.lua.
-- Needs -nodrc (the recompiler bypasses the data-space taps) and -debug -debugger none (trace
-- and interrupt counters). Environment:
--
--   CORE_OUT      output directory
--   CORE_EVENTS   "frame:port:hexmask:len,..."   presses (e.g. 4400:IN2:80:5,4430:IN0:80:5)
--   CORE_WINDOWS  "name:from:to,..."             measurement windows (screen frame numbers)
--   CORE_PLAY     "from:to"                      frames in which the controls are driven
--   CORE_TRACES   "name:frame:nframes,..."       debugger trace of dsp1 for nframes from frame
--   CORE_END      frame to exit at
--   CORE_SR       state sample rate, Hz
--   CORE_SNAPS    "frame,frame,..."              snapshots
--
-- Per window <w>:
--   int_<w>.txt     internal RAM words touched: "blk word r w" (DM bus, incl. DMA)
--   ext_<w>.txt     distinct words touched in the 0x500000 and 0x1400000 RAMs
--   frames_<w>.csv  per-frame access counts by region
--   samp_<w>.txt    sampled state histograms (MODE1, MODE2, IMASK, LSTKP, L regs, PC)
-- iop.txt: every write to IOP registers 0x00-0xff ("frame addr data"), irq.txt: interrupt entries
-- per frame by vector (breakpoints on the vectors), trace_<name>.tr: trace with DAG2 registers,
-- pm_<name>.bin / pm_<name>_end.bin: program memory at trace start / stop.

local OUT   = os.getenv("CORE_OUT") or "."
local ENDF  = tonumber(os.getenv("CORE_END") or "7600")
local SR    = tonumber(os.getenv("CORE_SR") or "20000")
local m     = manager.machine
local dsp   = m.devices[":dsp1"]
local ds    = dsp.spaces["data"]
local scr   = m.screens[":screen"]
local dbg   = m.debugger

-- Globals on purpose: collected subscriptions stop firing (LESSONS_LEARNED, Lua section).
sp_subs, sp_wsubs = {}, {}
sp_hits, sp_err = 0, nil

local function guard(fn)
    return function(o, d, mk)
        sp_hits = sp_hits + 1
        local ok, e = pcall(fn, o, d, mk)
        if not ok and not sp_err then sp_err = tostring(e) end
    end
end

local windows = {}
for n, a, b in (os.getenv("CORE_WINDOWS") or ""):gmatch("(%w+):(%d+):(%d+)") do
    windows[#windows + 1] = { name = n, a = tonumber(a), b = tonumber(b) }
end
local traces = {}
for n, f, k in (os.getenv("CORE_TRACES") or ""):gmatch("(%w+):(%d+):(%d+)") do
    traces[#traces + 1] = { name = n, f = tonumber(f), k = tonumber(k) }
end
local PL_A, PL_B = (os.getenv("CORE_PLAY") or "-1:-2"):match("(%-?%d+):(%-?%d+)")
PL_A, PL_B = tonumber(PL_A), tonumber(PL_B)
local events = {}
for f, port, mask, len in (os.getenv("CORE_EVENTS") or ""):gmatch("(%d+):(%w+):(%x+):(%d+)") do
    events[#events + 1] = { f = tonumber(f), port = ":" .. port, mask = tonumber(mask, 16), len = tonumber(len) }
end

local snaps = {}
for f in (os.getenv("CORE_SNAPS") or ""):gmatch("(%d+)") do snaps[tonumber(f)] = true end

local function field(port, mask) return m.ioport.ports[port]:field(mask) end

-------------------------------------------------------------------------------
-- Window state
local win = nil          -- current window table
local frame = 0

local REG = {            -- external regions, word addresses
    { "shared", 0x0400000, 0x041ffff }, { "ram500", 0x0500000, 0x05fffff },
    { "ram1400", 0x1400000, 0x14fffff }, { "voodoo", 0x2400000, 0x27fffff },
    { "comm", 0x3400000, 0x34000ff }, { "k033906", 0x3500000, 0x35000ff },
    { "cgrom", 0x3600000, 0x37fffff },
}
local CNT = {}           -- per-frame counters
local CNAMES = { "int_r", "int_w", "int_short_r", "int_short_w", "int_mirror_r", "int_mirror_w",
    "iop_r", "iop_w", "other_r", "other_w" }
for _, r in ipairs(REG) do CNAMES[#CNAMES + 1] = r[1] .. "_r"; CNAMES[#CNAMES + 1] = r[1] .. "_w" end
local function clear() for _, n in ipairs(CNAMES) do CNT[n] = 0 end end
clear()

-- internal RAM word key: blk * 0x8000 + word
local IR, IW = {}, {}    -- key -> count
local ER, EW = {}, {}    -- external RAM address -> count

local function ikey(a)
    if a < 0x40000 then
        if a < 0x28000 then return a - 0x20000, 0 end
        return 0x8000 + (a & 0x7fff), (a >= 0x30000) and 1 or 0     -- 0x30000+ are mirrors
    end
    local s = a & 0xffff                                            -- short-word index
    if a < 0x50000 then return s >> 1, 2 end
    return 0x8000 + (s >> 1), 2
end

local function int_r(o)
    local k, kind = ikey(o)
    IR[k] = (IR[k] or 0) + 1
    if kind == 0 then CNT.int_r = CNT.int_r + 1 elseif kind == 1 then CNT.int_mirror_r = CNT.int_mirror_r + 1
    else CNT.int_short_r = CNT.int_short_r + 1 end
end
local function int_w(o)
    local k, kind = ikey(o)
    IW[k] = (IW[k] or 0) + 1
    if kind == 0 then CNT.int_w = CNT.int_w + 1 elseif kind == 1 then CNT.int_mirror_w = CNT.int_mirror_w + 1
    else CNT.int_short_w = CNT.int_short_w + 1 end
end

local function arm_window()
    local S = sp_wsubs
    S[#S + 1] = ds:install_read_tap(0x20000, 0x7ffff, "spir", guard(function(o) int_r(o) end))
    S[#S + 1] = ds:install_write_tap(0x20000, 0x7ffff, "spiw", guard(function(o) int_w(o) end))
    S[#S + 1] = ds:install_read_tap(0x0, 0xff, "spior", guard(function(o) CNT.iop_r = CNT.iop_r + 1 end))
    S[#S + 1] = ds:install_read_tap(0x80000, 0x3ffffff, "spoth_r", guard(function(o)
        for _, r in ipairs(REG) do
            if o >= r[2] and o <= r[3] then
                local n = r[1] .. "_r"; CNT[n] = CNT[n] + 1
                if n == "ram500_r" or n == "ram1400_r" then ER[o] = (ER[o] or 0) + 1 end
                return
            end
        end
        CNT.other_r = CNT.other_r + 1
    end))
    S[#S + 1] = ds:install_write_tap(0x80000, 0x3ffffff, "spoth_w", guard(function(o)
        for _, r in ipairs(REG) do
            if o >= r[2] and o <= r[3] then
                local n = r[1] .. "_w"; CNT[n] = CNT[n] + 1
                if n == "ram500_w" or n == "ram1400_w" then EW[o] = (EW[o] or 0) + 1 end
                return
            end
        end
        CNT.other_w = CNT.other_w + 1
    end))
    win.csv = assert(io.open(OUT .. "/frames_" .. win.name .. ".csv", "w"))
    win.csv:write("frame," .. table.concat(CNAMES, ",") .. "\n")
    IR, IW, ER, EW = {}, {}, {}, {}
    win.H = {}
    clear()
end

local function close_window()
    for _, s in ipairs(sp_wsubs) do s:remove() end
    sp_wsubs = {}
    win.csv:close()
    local f = assert(io.open(OUT .. "/int_" .. win.name .. ".txt", "w"))
    local keys = {}
    for k in pairs(IR) do keys[k] = true end
    for k in pairs(IW) do keys[k] = true end
    for k in pairs(keys) do
        f:write(string.format("%d %04x %d %d\n", k >> 15, k & 0x7fff, IR[k] or 0, IW[k] or 0))
    end
    f:close()
    f = assert(io.open(OUT .. "/ext_" .. win.name .. ".txt", "w"))
    keys = {}
    for k in pairs(ER) do keys[k] = true end
    for k in pairs(EW) do keys[k] = true end
    for k in pairs(keys) do f:write(string.format("%07x %d %d\n", k, ER[k] or 0, EW[k] or 0)) end
    f:close()
    f = assert(io.open(OUT .. "/samp_" .. win.name .. ".txt", "w"))
    for key, t in pairs(win.H) do
        for v, n in pairs(t) do f:write(key, " ", v, " ", n, "\n") end
    end
    f:close()
    win = nil
end

-------------------------------------------------------------------------------
-- IOP writes, whole run: "frame reg data pc". A chained DMA start (DMAC bits 0 and 1) also logs
-- the first TCB, read from the block share so the read does not reach the taps:
-- "frame T ch II IM C CP EI EM EC".
local iopf = assert(io.open(OUT .. "/iop.txt", "w"))
local blk = { m.memory.shares[":dsp1:block0"], m.memory.shares[":dsp1:block1"] }
local last_cp = {}
sp_subs[#sp_subs + 1] = ds:install_write_tap(0x0, 0xff, "spiow", guard(function(o, d)
    iopf:write(string.format("%d %02x %08x %06x\n", frame, o, d, dsp.state["PC"].value))
    if o == 0x43 or o == 0x4b then last_cp[o == 0x43 and 6 or 7] = d end
    if (o == 0x1c or o == 0x1d) and (d & 3) == 3 then
        local ch = (o == 0x1c) and 6 or 7
        local k = ikey(0x20000 + ((last_cp[ch] or 0) & 0x1ffff))
        local b, w = blk[(k >> 15) + 1], k & 0x7fff
        local t = {}
        for _, off in ipairs({ 0, 1, 2, 3, 5, 6, 7 }) do
            t[#t + 1] = string.format("%x", b:read_u32(((w - off) & 0x7fff) * 4))
        end
        iopf:write(string.format("%d T %d %s\n", frame, ch, table.concat(t, " ")))
    end
    if win then CNT.iop_w = CNT.iop_w + 1 end
end))

-------------------------------------------------------------------------------
-- Interrupt entries: one breakpoint per vector, counting into temp variables.
-- Vectors 0x20000 + 4*n; n -> temp slot.
local VEC = { [4] = 0, [6] = 1, [7] = 2, [8] = 3, [16] = 4, [17] = 5, [5] = 6, [20] = 7, [21] = 7, [3] = 8 }
local VNAME = { [0] = "TMZHI(4)", "IRQ2I(6)", "IRQ1I(7)", "IRQ0I(8)", "EP0I/DMA6(16)", "EP1I/DMA7(17)",
    "VIRPTI(5)", "CB7I/CB15I(20,21)", "SOVFI(3)", "other" }
dbg.visible_cpu = dsp
for n = 0, 31 do
    if n ~= 0 and n ~= 1 then
        local t = VEC[n] or 9
        -- IRPTL bit n is set on entry: ordinary code placed in an unused vector slot does not count
        dbg:command(string.format("bpset %x,(temp%d+=(irptl>>%d)&1)&0", 0x20000 + 4 * n, t, n))
    end
end
for t = 0, 9 do dbg:command(string.format("temp%d=0", t)) end
local irqf = assert(io.open(OUT .. "/irq.txt", "w"))
irqf:write("frame")
for t = 0, 9 do irqf:write(" " .. VNAME[t]) end
irqf:write("\n")
local function read_irq_counts()
    local before = #dbg.consolelog
    local fmt = {}
    for t = 0, 9 do fmt[#fmt + 1] = "%d" end
    local args = {}
    for t = 0, 9 do args[#args + 1] = "temp" .. t end
    dbg:command('printf "SPIRQ ' .. table.concat(fmt, " ") .. '",' .. table.concat(args, ","))
    local line = dbg.consolelog[#dbg.consolelog]
    for t = 0, 9 do dbg:command(string.format("temp%d=0", t)) end
    if #dbg.consolelog > before and line then return (line:gsub("^SPIRQ ", "")) end
    return "?"
end

-------------------------------------------------------------------------------
-- State sampler (inside windows)
local ST = {}
for _, n in ipairs({ "PC", "MODE1", "MODE2", "IMASK", "LSTKP", "PCSTKP", "STSTKP", "CURLCNTR" }) do
    ST[n] = dsp.state[n]
end
local LREG = {}
for i = 0, 15 do LREG[i] = dsp.state["L" .. i] end
local function hist(key, val)
    local t = win.H[key]
    if not t then t = {}; win.H[key] = t end
    t[val] = (t[val] or 0) + 1
end
local sampler = coroutine.wrap(function()
    while true do
        emu.wait(1 / SR)
        if win then
            hist("PC", string.format("%x", ST.PC.value))
            hist("MODE1", string.format("%08x", ST.MODE1.value))
            hist("MODE2", string.format("%08x", ST.MODE2.value))
            hist("IMASK", string.format("%08x", ST.IMASK.value))
            hist("LSTKP", string.format("%d", ST.LSTKP.value))
            hist("PCSTKP", string.format("%d", ST.PCSTKP.value))
            for i = 0, 15 do
                local v = LREG[i].value
                if v ~= 0 then hist("L" .. i, string.format("%x", v)) end
            end
        end
    end
end)

-------------------------------------------------------------------------------
-- Controls in the play range: fire buttons pulsed, direction held 20..80 frames.
local held = {}
local rng = 12345
local function rand(n) rng = (rng * 1103515245 + 12345) & 0x7fffffff; return rng % n end
local dir_until = -1
local function drive_play(f)
    local on = (f % 6) < 3
    for _, b in ipairs({ 0x01, 0x02, 0x04 }) do field(":IN0", b):set_value(on and 1 or 0) end
    if f >= dir_until then
        for _, b in ipairs({ 0x40, 0x20, 0x10, 0x08 }) do field(":IN0", b):set_value(0) end
        local dirs = { { 0x40 }, { 0x20 }, { 0x10 }, { 0x08 }, { 0x40, 0x08 }, { 0x20, 0x08 } }
        for _, b in ipairs(dirs[rand(6) + 1]) do field(":IN0", b):set_value(1) end
        dir_until = f + 20 + rand(60)
    end
end

-------------------------------------------------------------------------------
local TRFMT, TRREGS = {}, {}
for i = 8, 15 do TRREGS[#TRREGS + 1] = "i" .. i end
for i = 8, 15 do TRREGS[#TRREGS + 1] = "m" .. i end
for _, n in ipairs({ "mode1", "mode2", "imask", "lstkp", "pcstkp" }) do TRREGS[#TRREGS + 1] = n end
for _ = 1, #TRREGS do TRFMT[#TRFMT + 1] = "%X" end
local tracing = nil

-- Program memory 0x20000-0x24FFF as 6-byte little-endian words, for opcode classification.
local ps = dsp.spaces["program"]
local function dump_pm(path)
    local f = assert(io.open(path, "wb"))
    local chunk = {}
    for a = 0x20000, 0x24fff do
        local v = ps:read_u64(a)
        chunk[#chunk + 1] = string.pack("<I4I2", v & 0xffffffff, (v >> 32) & 0xffff)
    end
    f:write(table.concat(chunk))
    f:close()
end

local sealed = false
local hb = assert(io.open(OUT .. "/heartbeat.txt", "w"))
sp_subs[#sp_subs + 1] = emu.add_machine_frame_notifier(function()
    local ok, e = pcall(function()
        frame = scr:frame_number()
        -- close out frame
        if win then
            local row = { tostring(frame) }
            for _, n in ipairs(CNAMES) do row[#row + 1] = tostring(CNT[n]) end
            win.csv:write(table.concat(row, ","), "\n")
            clear()
            irqf:write(frame, " ", win.name, " ", read_irq_counts(), "\n")
            if frame >= win.b then close_window() end
        end
        if not win then
            for _, w in ipairs(windows) do
                if frame + 1 == w.a or (frame + 1 > w.a and frame < w.b and not w.done) then
                    w.done = true
                    win = w
                    read_irq_counts()               -- zero the counters
                    arm_window()
                    break
                end
            end
        end
        for f, rel in pairs(held) do
            if frame >= rel then f:set_value(0); held[f] = nil end
        end
        for _, ev in ipairs(events) do
            if ev.f == frame then local f = field(ev.port, ev.mask); f:set_value(1); held[f] = frame + ev.len end
        end
        if frame >= PL_A and frame <= PL_B then drive_play(frame) end
        if tracing and frame >= tracing.stop then
            dbg:command("trace off,dsp1")
            dump_pm(OUT .. "/pm_" .. tracing.name .. "_end.bin")
            tracing = nil
        end
        for _, t in ipairs(traces) do
            if frame == t.f and not t.done then
                t.done = true
                dump_pm(OUT .. "/pm_" .. t.name .. ".bin")
                dbg:command(string.format('trace %s/trace_%s.tr,dsp1,noloop,{tracelog "%s ",%s}',
                    OUT, t.name, table.concat(TRFMT, " "), table.concat(TRREGS, ",")))
                tracing = { stop = frame + t.k, name = t.name }
            end
        end
        if frame % 100 == 0 then
            hb:write(frame, " hits ", sp_hits, " err ", tostring(sp_err), "\n"); hb:flush()
        end
        if snaps[frame] then m.video:snapshot() end
        if frame >= ENDF and not sealed then
            sealed = true
            iopf:close(); irqf:close()
            hb:write("end ", frame, " hits ", sp_hits, " err ", tostring(sp_err), "\n"); hb:close()
            print("SHARC_PROFILE_OK")
            m:exit()
        end
    end)
    if not ok and not sp_err then sp_err = "frame: " .. tostring(e); print("SPERR " .. sp_err) end
end)

dbg.execution_state = "run"
sampler()
