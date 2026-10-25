package xiangshan.backend.fu

import chisel3._
import chisel3.util.Cat
import chisel3.stage.ChiselGeneratorAnnotation
import circt.stage.ChiselStage
import org.chipsalliance.cde.config.Parameters
import top.DefaultConfig
import utility.{LogUtilsOptions, LogUtilsOptionsKey, PerfCounterOptions, PerfCounterOptionsKey, XSPerfLevel}
import xiangshan.{DebugOptionsKey, XSCoreParamsKey, XSModule, XSTileKey}
import xiangshan.backend.fu.FuConfig.{VialuCfg, VipuCfg}
import xiangshan.backend.fu.vector.Bundles.VConfig
import xiangshan.backend.fu.vector.VecPipedFuncUnit
import xiangshan.backend.fu.wrapper.{VIAluFix, VIPU}

/** VecFuLatHarness —— 把任意一个 `VecPipedFuncUnit` 收窄成与 `VIMacUHarness` 完全
  * 相同的窄 IO，供 `tests/unit/vecfu_latency_tb.cpp` 直接驱动该功能单元（P7 / 赛题 3.3）。
  *
  *  背景：RVV 1.0 基线序列由 `vmv.s.x` / `vwmul.vv` / `vwredsum.vs` 三类指令组成，
  *  分别落在三个不同的功能单元上：
  *      vmv.s.x / vwadd.wv  -> FuType.vialuF -> VIAluFix  (VialuCfg, FuConfig.scala:533-551)
  *      vwmul.vv / vdot 系列 -> FuType.vimac  -> VIMacU    (VimacCfg, FuConfig.scala:552-570)
  *      vwredsum.vs         -> FuType.vipu   -> VIPU      (VipuCfg,  FuConfig.scala:605-621)
  *  YunSuan 的 L1 仿真平台（`VectorSimTop`）只例化了 YunSuan 自己的
  *  `VIAluFWrapper` / `VPermTop` 等模块，既没有 `VIMacU` 也没有 `VIPU`，
  *  而且它的 `io.out.valid` 是平台计数器按常量产生的，不能单独证明 DUT 的流水深度。
  *  本 harness 与 `VIMacUHarness` 一样照搬 `ExeUnit.scala:228-241` 的 pipelineReg 链，
  *  链长取自 `cfg.latency`（下方 `nLat`）。`io.outValid` 虽然直接接功能单元的
  *  `io.out.valid`，但后者由 `validPipe(nLat) && validVecThisFu(nLat)` 得到
  *  （FuncUnit.scala:213-238），而 validPipe 正是本 harness 按 nLat 搭的寄存器链——
  *  所以 in.fire -> out.valid 的拍数按构造等于声明值，只是**平台构造值**，
  *  不是独立证据。数据通路深度要看 tb 里独立观测的「数据成形拍」（io_vd 第一次
  *  等于最终结果的拍数，属下界型证据），判读口径见 vecfu_latency_tb.cpp 文件头。
  *
  *  本文件只做连线，不含任何算术逻辑，也不修改任何 RTL。
  */
abstract class VecFuLatHarness(cfg: FuConfig)(implicit p: Parameters) extends XSModule {
  val io = IO(new Bundle {
    val valid    = Input(Bool())
    val fuOpType = Input(UInt(xiangshan.FuOpTypeWidth.W))
    val vsew     = Input(UInt(2.W))
    val vlmul    = Input(UInt(3.W))
    val vstart   = Input(UInt(8.W))
    val vl       = Input(UInt(8.W))
    val vuopIdx  = Input(UInt(6.W))
    val lastUop  = Input(Bool())
    val vm       = Input(Bool())
    val vta      = Input(Bool())
    val vma      = Input(Bool())
    val vs2Lo    = Input(UInt(64.W))
    val vs2Hi    = Input(UInt(64.W))
    val vs1Lo    = Input(UInt(64.W))
    val vs1Hi    = Input(UInt(64.W))
    val oldVdLo  = Input(UInt(64.W))
    val oldVdHi  = Input(UInt(64.W))
    val maskLo   = Input(UInt(64.W))
    val maskHi   = Input(UInt(64.W))

    val inReady  = Output(Bool())
    val outValid = Output(Bool())
    val vdLo     = Output(UInt(64.W))
    val vdHi     = Output(UInt(64.W))
  })

  protected def mkFu(): VecPipedFuncUnit

  private val u = mkFu()

  u.io.flush.valid := false.B
  u.io.flush.bits  := 0.U.asTypeOf(u.io.flush.bits)
  u.io.vxrm.foreach(_ := 0.U)
  u.io.frm.foreach(_ := 0.U)
  u.io.out.ready   := true.B
  u.io.in.valid    := io.valid

  private val in = WireInit(0.U.asTypeOf(u.io.in.bits))
  in.ctrl.fuOpType := io.fuOpType

  private val vpu = WireInit(0.U.asTypeOf(in.ctrl.vpu.get))
  vpu.vill    := false.B
  vpu.vma     := io.vma
  vpu.vta     := io.vta
  vpu.vsew    := io.vsew
  vpu.vlmul   := io.vlmul
  vpu.vm      := io.vm
  vpu.vstart  := io.vstart
  vpu.vuopIdx := io.vuopIdx
  vpu.lastUop := io.lastUop
  in.ctrl.vpu.get := vpu

  private val vcfg = WireInit(0.U.asTypeOf(new VConfig))
  vcfg.vtype.illegal := false.B
  vcfg.vtype.vma     := io.vma
  vcfg.vtype.vta     := io.vta
  vcfg.vtype.vsew    := io.vsew
  vcfg.vtype.vlmul   := io.vlmul
  vcfg.vl            := io.vl

  in.data.src(0) := Cat(io.vs1Hi,   io.vs1Lo)
  in.data.src(1) := Cat(io.vs2Hi,   io.vs2Lo)
  in.data.src(2) := Cat(io.oldVdHi, io.oldVdLo)
  in.data.src(3) := Cat(io.maskHi,  io.maskLo)
  in.data.src(4) := vcfg.asUInt

  // 与 ExeUnit.scala:228-241 完全一致的无条件打拍链，链长 = cfg.latency + 1
  private val nLat   = cfg.latency.latencyVal.get
  private val vPipe  = Wire(Vec(nLat + 1, Bool()))
  private val cPipe  = Wire(Vec(nLat + 1, chiselTypeOf(in.ctrl)))
  private val dPipe  = Wire(Vec(nLat + 1, chiselTypeOf(in.data)))
  vPipe(0) := io.valid
  cPipe(0) := in.ctrl
  dPipe(0) := in.data
  for (i <- 1 to nLat) {
    vPipe(i) := RegNext(vPipe(i - 1), false.B)
    cPipe(i) := RegNext(cPipe(i - 1))
    dPipe(i) := RegNext(dPipe(i - 1))
  }
  in.validPipe.get := vPipe
  in.ctrlPipe.get  := cPipe
  in.dataPipe.get  := dPipe

  u.io.in.bits := in

  io.inReady  := u.io.in.ready
  io.outValid := u.io.out.valid
  io.vdLo     := u.io.out.bits.res.data(63, 0)
  io.vdHi     := u.io.out.bits.res.data(127, 64)
}

class VIAluFixHarness(implicit p: Parameters) extends VecFuLatHarness(VialuCfg) {
  override protected def mkFu(): VecPipedFuncUnit = Module(new VIAluFix(VialuCfg))
  override def desiredName: String = "VIAluFixHarness"
}

class VIPUHarness(implicit p: Parameters) extends VecFuLatHarness(VipuCfg) {
  override protected def mkFu(): VecPipedFuncUnit = Module(new VIPU(VipuCfg))
  override def desiredName: String = "VIPUHarness"
}

private object VecFuLatCfg {
  def apply(): Parameters = {
    val defaultConfig = new DefaultConfig
    defaultConfig.alterPartial({
      case XSCoreParamsKey => defaultConfig(XSTileKey).head
      case LogUtilsOptionsKey => LogUtilsOptions(
        enableDebug  = defaultConfig(DebugOptionsKey).EnableDebug,
        enablePerf   = defaultConfig(DebugOptionsKey).EnablePerfDebug,
        fpgaPlatform = defaultConfig(DebugOptionsKey).FPGAPlatform,
        enableXMR    = defaultConfig(DebugOptionsKey).EnableXMR
      )
      case PerfCounterOptionsKey => PerfCounterOptions(
        enablePerfPrint = false,
        enablePerfDB    = false,
        perfLevel       = XSPerfLevel.withName(defaultConfig(DebugOptionsKey).PerfLevel),
        perfDBHartID    = 0
      )
    })
  }
}

object VIAluFixHarnessMain extends App {
  implicit val config: Parameters = VecFuLatCfg()
  (new ChiselStage).execute(
    if (args.isEmpty) Array("--target-dir", "build/vdot", "--target", "verilog") else args,
    Seq(ChiselGeneratorAnnotation(() => new VIAluFixHarness()(config)))
  )
}

object VIPUHarnessMain extends App {
  implicit val config: Parameters = VecFuLatCfg()
  (new ChiselStage).execute(
    if (args.isEmpty) Array("--target-dir", "build/vdot", "--target", "verilog") else args,
    Seq(ChiselGeneratorAnnotation(() => new VIPUHarness()(config)))
  )
}
