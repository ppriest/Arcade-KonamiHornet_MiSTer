# Shared simulation models

`sdram_chip_model_wide.sv` (unmodified) and `sdram_chip_model_128.sv` (one change, below): copied from
`Arcade-KonamiGX_MiSTer/sim/common/` (commit 61f4e11). They decode real SDRAM commands and model
CAS latency and bursts; `_128` is the 128 MB module (two 64 MB chips selected by `SDRAM_nCS`). The
chain before KonamiGX (Seta, Fuuki, Psikyo) is in that repository's `sim/common/PROVENANCE.md`.

`[Hornet]` in `sdram_chip_model_128.sv`: a READ's burst starts CAS latency - 1 edges after its
command and a burst in progress runs until then, as the standard has read-to-read truncation; the
copied model started the new burst at once, which matched the controller's double read only at
CL2 (this core runs CL3).
