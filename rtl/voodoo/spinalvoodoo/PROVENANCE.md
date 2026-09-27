# SpinalVoodoo, generated Verilog

- Source: https://github.com/fayalalebrun/SpinalVoodoo, commit
  28d143501c122429fe2d2367ec8fa942671c495a (clone at `E:/SpinalVoodoo`).
- Generated, not edited, from that commit with `rtl/voodoo/patches/*.patch` applied:
  `scala-cli run --server=false <clone>/project.scala <clone>/src rtl/voodoo/gen --main-class
  hornet.CoreDe10VariantGen -- <outdir>` (the upstream `voodoo.de10.CoreDe10Gen` configuration)
  with scala-cli 1.15.0 and Temurin JDK 21.0.12 (SpinalHDL 1.13.0 per `project.scala`).
  Output `CoreDe10.v` and its ROM sidecars (`*.bin`, read by `$readmemb`).
- Patches (texture fill cache; found by `sim/voodoop_tb`'s texel check against MAME captures):
  - `0001-texcache-bank-and-fill-response.patch`: the 16-bit bank select ORed a column bit into
    the row bit, so both rows of a bilinear footprint shared banks and one tap read another's
    data; and a fill emitted the registered texels, missing the tap resolved on the emitting
    word. Before: 44,425 of 79,903 fetches with a wrong texel (window 7500); after: 0 of 79,903
    and 0 of 221,502 (window 2150).
  - `0002-dither-2x2-mame.patch`: MAME's 2x2 dither matrix in place of 86Box's
    (`docs/MAME_KLUDGES.md`, Voodoo 1).
- `CoreHornet.v` (and its `CoreHornet.v_*.bin`): the same sources and patches, generated with
  `--main-class hornet.CoreHornetGen` from `rtl/voodoo/gen/CoreHornet.scala`: vertical retrace
  from the board, the displayed buffer's base out, SpinalVoodoo's HDMI scanout held in reset.
  `CoreDe10.v` stays for `sim/voodoo_tb`.
- **No licence.** The repository has no licence file (GitHub API `license: null`), so all rights
  are the author's. User decision (ROADMAP, Open items): used here in a private repository, and
  no binary is released while it stays unlicensed.
- To regenerate: in a fresh clone at that commit, `git apply` the patches, run the command
  above and copy the output here. Never edit
  these files; changes go through the Scala source or a wrapper.
