-- Print address spaces and state register names of the Hornet CPUs, and take
-- a snapshot every CORE_SNAP_EVERY frames until CORE_END. Used to find where
-- gradius4 reaches attract before running hornet_load.lua.
local OUT   = os.getenv("CORE_OUT") or "."
local EVERY = tonumber(os.getenv("CORE_SNAP_EVERY") or "300")
local ENDF  = tonumber(os.getenv("CORE_END") or "3000")
local m = manager.machine

local f = io.open(OUT .. "/probe.txt", "w")
for _, tag in ipairs({ ":maincpu", ":audiocpu", ":dsp1", ":voodoo0" }) do
    local d = m.devices[tag]
    if d then
        f:write(tag, "\n")
        for name, sp in pairs(d.spaces) do
            f:write(string.format("  space %s width=%d shift=%d endian=%s\n",
                name, sp.data_width, sp.shift, tostring(sp.endianness)))
        end
        if d.state then
            local names = {}
            for n, _ in pairs(d.state) do names[#names + 1] = n end
            table.sort(names)
            f:write("  state: ", table.concat(names, " "), "\n")
        end
    else
        f:write(tag, " missing\n")
    end
end
f:close()

local n = 0
core_probe_sub = emu.add_machine_frame_notifier(function()
    n = n + 1
    if n % EVERY == 0 then m.video:snapshot() end
    if n >= ENDF then m:exit() end
end)
