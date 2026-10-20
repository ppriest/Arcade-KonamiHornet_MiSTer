// SPDX-License-Identifier: GPL-3.0-or-later
// SpinalVoodoo's CoreDe10 for the Hornet board: vertical retrace comes from the board's video
// timing (hornet_board), not from SpinalVoodoo's own HDMI scanout, which is held in reset; the
// displayed buffer and the two colour-buffer bases go out to the board's scanout.
//   scala-cli run --server=false <clone>/project.scala <clone>/src rtl/voodoo/gen \
//     --main-class hornet.CoreHornetGen -- <outdir>
package hornet

import spinal.core._
import spinal.lib._
import spinal.lib.bus.amba3.apb._
import spinal.lib.bus.avalon._
import voodoo.{Config, Core, GenSupport}
import voodoo.de10.{De10MemBackend, H2fLwMmio, H2fLwToBmbBridge}

case class CoreHornet(c: Config) extends Component {
  private val cpuAddressWidth = Core.cpuBmbParams.access.addressWidth
  private def avalon = AvalonMM(De10MemBackend.avalonConfig(De10MemBackend.physicalAddressWidth))

  val io = new Bundle {
    val h2fLw = slave(H2fLwMmio(cpuAddressWidth - 2))
    val memFbWrite = master(avalon)
    val memFbColorWrite = master(avalon)
    val memFbAuxWrite = master(avalon)
    val memFbColorRead = master(avalon)
    val memFbAuxRead = master(avalon)
    val memTex = master(avalon)
    val vRetrace = in Bool ()
    val displayedBuffer = out UInt (2 bits)
    val buffer0Base = out UInt (c.addressWidth)
    val buffer1Base = out UInt (c.addressWidth)
    val pixelStride = out UInt (16 bits)
  }

  val core = Core(c)
  val memBackend = De10MemBackend(c)
  val h2fBridge = H2fLwToBmbBridge(cpuAddressWidth, Core.cpuBmbParams)

  io.h2fLw <> h2fBridge.io.h2fLw
  core.io.cpuBus <> h2fBridge.io.cpuBus

  Seq(
    core.io.fbMemWrite <> memBackend.io.fbMemWrite,
    core.io.fbColorWriteMem <> memBackend.io.fbColorWriteMem,
    core.io.fbAuxWriteMem <> memBackend.io.fbAuxWriteMem,
    core.io.fbColorReadMem <> memBackend.io.fbColorReadMem,
    core.io.fbAuxReadMem <> memBackend.io.fbAuxReadMem,
    core.io.texMem <> memBackend.io.texMem,
    io.memFbWrite <> memBackend.io.memFbWrite,
    io.memFbColorWrite <> memBackend.io.memFbColorWrite,
    io.memFbAuxWrite <> memBackend.io.memFbAuxWrite,
    io.memFbColorRead <> memBackend.io.memFbColorRead,
    io.memFbAuxRead <> memBackend.io.memFbAuxRead,
    io.memTex <> memBackend.io.memTex
  )

  core.io.statusInputs.vRetrace := io.vRetrace
  core.io.statusInputs.memFifoFree := 0xffff
  core.io.statusInputs.pciInterrupt := False
  core.io.hdmi.clock := ClockDomain.current.readClockWire
  core.io.hdmi.reset := True

  io.displayedBuffer := core.io.swapDisplayedBuffer
  io.buffer0Base := core.hdmiScanout.io.regs.frontBase.pull()
  io.buffer1Base := core.hdmiScanout.io.regs.backBase.pull()
  io.pixelStride := core.hdmiScanout.io.regs.pixelStride.pull().resized

  core.io.fbBaseAddr := 0
  core.io.flushFbCaches := False
}

object CoreHornetGen extends App {
  GenSupport.de10Verilog(args(0)).generate(CoreHornet(Config.voodoo1()))
}

// Gradius IV's subset (HARDWARE_NOTES, Voodoo usage): no fog; a 512x384 frame. Area experiments:
//   --tex-slots N   texture fill cache slots (default 16)
//   --no-fb-cache   no framebuffer read cache
//   --fixed-lod     LOD from tLOD's clamp only (lodmin = lodmax)
//   --formats a,b   texel formats decoded (Tmu.TextureFormat numbers)
object CoreHornetTrimGen extends App {
  def arg(name: String): Option[String] = args.indexOf(name) match {
    case -1 => None
    case i  => Some(args(i + 1))
  }
  val c = Config.voodoo1().copy(
    enableFog = false,
    maxFbDims = (512, 384),
    texFillCacheSlots = arg("--tex-slots").map(_.toInt).getOrElse(16),
    useFbReadCache = !args.contains("--no-fb-cache"),
    fixedLod = args.contains("--fixed-lod"),
    texFormats = arg("--formats").map(_.split(",").toSeq.map(_.toInt)).getOrElse(Nil))
  GenSupport.de10Verilog(args(0)).generate(CoreHornet(c))
}
