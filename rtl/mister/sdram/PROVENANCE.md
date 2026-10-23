# `sdram.sv` — provenance

Copied unmodified from `Arcade-KonamiGX_MiSTer/rtl/memory/sdram/sdram.sv` (commit 61f4e11), with
`sdram_upstream_reference.sv` beside it for diffing. That file's own `PROVENANCE.md` has the chain:
Sorgelig's `sdram.v` (GPL-3.0-or-later, from `MiSTer-devel/Arcade-Jackal_MiSTer`), extended in
Psikyo to burst-4 reads, widened in Fuuki to 26-bit addresses, and in KonamiGX given the 128 MB
module's second chip (byte address bit 26 on `SDRAM_nCS`) and port 0's double read (`dbl0`: two
granules, 8 words of 16 bits, from one row activation).

Use here (`rtl/mister/hornet_sdram.sv`): three fixed-priority ports, 0 over 1 over 2. Port 0 takes
the line fills (the character cache and port B's read-ahead) with the double read; port 1 the PPC
and port B's writes; port 2 the download.

Edits here are marked `[Hornet]`: the state register and its constants widened to 5 bits, so that
CAS latency 3 and tRCD 3 (the double read's last state is then 16) can be set. Port 1's two-halfword
write (`w2_1`, `din1b`, `wrl1b`, `wrh1b`): the first WRITE leaves the row open, the second, a clock
later at the next column, precharges; a 32-bit write is one row activation, not two. The core runs the
controller at clk_sys, 64 MHz, with 2 and 2, as KonamiGX did at 96 MHz.
