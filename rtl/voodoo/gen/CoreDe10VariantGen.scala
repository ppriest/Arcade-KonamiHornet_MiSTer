// SPDX-License-Identifier: GPL-3.0-or-later
// Generator variants of SpinalVoodoo's CoreDe10 for A/B experiments, compiled together with the
// SpinalVoodoo sources:
//   scala-cli run --server=false <clone>/project.scala <clone>/src rtl/voodoo/gen \
//     --main-class hornet.CoreDe10VariantGen -- <outdir> [--no-tex-fill-cache] [--no-fb-read-cache]
package hornet

import voodoo.{Config, GenSupport}
import voodoo.de10.CoreDe10

object CoreDe10VariantGen extends App {
  val out = args(0)
  val base = Config.voodoo1()
  val cfg = base.copy(
    useTexFillCache = if (args.contains("--no-tex-fill-cache")) false else base.useTexFillCache,
    useFbReadCache = if (args.contains("--no-fb-read-cache")) false else base.useFbReadCache
  )
  GenSupport.de10Verilog(out).generate(CoreDe10(cfg))
}
