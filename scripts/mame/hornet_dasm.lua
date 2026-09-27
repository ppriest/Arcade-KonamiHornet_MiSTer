-- Disassemble the hot loops found by hornet_load.lua's PC histograms.
-- Needs -debug -debugger none. CORE_DASM = "frame;cmd;cmd;..." debugger
-- commands run at that frame (e.g. "dasm file,addr,len,:dsp1").
local m = manager.machine
local spec = os.getenv("CORE_DASM") or ""
local parts = {}
for p in string.gmatch(spec, "([^;]+)") do parts[#parts + 1] = p end
local at = tonumber(table.remove(parts, 1))
local n = 0
m.debugger.execution_state = "run"
core_dasm_sub = emu.add_machine_frame_notifier(function()
    n = n + 1
    if n == at then
        for _, c in ipairs(parts) do m.debugger:command(c) end
    end
    if n == at + 2 then
        local f = io.open((os.getenv("CORE_OUT") or ".") .. "/console.txt", "w")
        for _, l in ipairs(m.debugger.consolelog) do f:write(l, string.char(10)) end
        f:close()
        m:exit()
    end
end)
