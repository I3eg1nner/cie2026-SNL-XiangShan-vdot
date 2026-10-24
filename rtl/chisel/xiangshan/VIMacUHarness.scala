package xiangshan.backend.fu

import chisel3._
import chisel3.util.{Cat, RegEnable}
import chisel3.stage.ChiselGeneratorAnnotation
import circt.stage.ChiselStage
import org.chipsalliance.cde.config.Parameters
import top.DefaultConfig
import utility.{LogUtilsOptions, LogUtilsOptionsKey, PerfCounterOptions, PerfCounterOptionsKey, XSPerfLevel}
import xiangshan.{DebugOptionsKey, XSCoreParamsKey, XSModule, XSTileKey}
import xiangshan.backend.fu.FuConfig.VimacCfg
import xiangshan.backend.fu.vector.Bundles.VConfig
import xiangshan.backend.fu.wrapper.VIMacU

/** VIMacUHarness —— 把**真正被集成进香山的** [[VIMacU]] 收窄成与 `VDotTop` 完全相同的
  * 窄 IO，使同一份定向语料可以直接灌进 `VIMacU` 本体。
  *
  *  背景（`docs/stage2/11_RTL实现说明.md` §10 第 1 条）：
  *  L1 的 YunSuan 测试平台测的是 `VDotTop`（算术通路与 `VIMacU` 相同，但掩码/尾部成形
  *  是另一份手写实现）。「被验证的东西不等于被集成的东西」是本项目最大的验证缺口。
  *  本 harness 的目的就是把这个缺口补上：它不改 `VIMacU` 一行，只是把
  *  `FuncUnitInput`（含 5 个源、VPUCtrlSignals、flush 等上百个字段）里 vdot 真正用到的
  *  那一小撮接出来，其余全部置 0。
  *
  *  端口语义与 `VDotTop` 一一对应：
  *    valid/fuOpType/vsew/vstart/vl/vm/vta/vma/vs2/vs1/oldVd/mask -> outValid/vd/vxsat
  *
  *  源下标约定（`VecPipedFuncUnit.scala:62-66`、`FuConfig.scala:555-557`）：
  *    src(0)=vs1  src(1)=vs2  src(2)=old_vd  src(3)=v0 掩码  src(4)=VConfig{vtype, vl}
  *
  *  用法：
  *    mill -i -D jvm-xmx=8G xiangshan.test.runMain \
  *         xiangshan.backend.fu.VIMacUHarnessMain --target-dir build/vdot --target verilog
  */
class VIMacUHarness(implicit p: Parameters) extends XSModule {
  val io = IO(new Bundle {
    val valid    = Input(Bool())
    val fuOpType = Input(UInt(xiangshan.FuOpTypeWidth.W))  // 完整 9 位 VimacType 编码
    val vsew     = Input(UInt(2.W))
    val vstart   = Input(UInt(8.W))
    val vl       = Input(UInt(8.W))
    val vm       = Input(Bool())
    val vta      = Input(Bool())
    val vma      = Input(Bool())
    // 128 位操作数一律拆成高/低两个 64 位端口，与 YunSuan 仿真顶层 VSTInputIO 的
    // src_N_0 / src_N_1 约定一致（docs/stage1/03_仿真平台搭建报告.md §4.3），
    // 这样 Verilator 侧全是 uint64_t，不出现 VlWide。
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
    val vxsat    = Output(Bool())
    val illegal  = Output(Bool())
  })

  private val u = Module(new VIMacU(VimacCfg))

  // flush 恒不触发（本 harness 不测流水线冲刷）
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
  vpu.vlmul   := 0.U            // LMUL = 1（裁定 S-6）
  vpu.vm      := io.vm
  vpu.vstart  := io.vstart
  vpu.vuopIdx := 0.U            // 单 uop
  vpu.lastUop := true.B
  in.ctrl.vpu.get := vpu

  // VimacCfg 的 vconfigWakeUp / maskWakeUp 都是 true（FuConfig.scala:564-565），
  // 所以 vl 与 v0 掩码走数据端口 src(4) / src(3)，而不是 ctrl.vpu 里的影子字段。
  private val vcfg = WireInit(0.U.asTypeOf(new VConfig))
  vcfg.vtype.illegal := false.B
  vcfg.vtype.vma     := io.vma
  vcfg.vtype.vta     := io.vta
  vcfg.vtype.vsew    := io.vsew
  vcfg.vtype.vlmul   := 0.U
  vcfg.vl            := io.vl

  in.data.src(0) := Cat(io.vs1Hi,   io.vs1Lo)
  in.data.src(1) := Cat(io.vs2Hi,   io.vs2Lo)
  in.data.src(2) := Cat(io.oldVdHi, io.oldVdLo)
  in.data.src(3) := Cat(io.maskHi,  io.maskLo)
  in.data.src(4) := vcfg.asUInt

  // -------------------------------------------------------------------------
  // ctrlPipe / dataPipe / validPipe —— 昆明湖 V2 的时序优化：功能单元**自己不保存**
  // 控制/数据的流水副本，而是由 ExeUnit 在外面打好拍后从端口送进来
  //   FuncUnit.scala:214-216  val validVec = io.in.bits.validPipe.get.zip(validVecThisFu)...
  //                           val ctrlVec  = io.in.bits.ctrlPipe.get
  //                           val dataVec  = io.in.bits.dataPipe.get
  // 因此 harness 必须照 ExeUnit.scala:228-241 的 pipelineReg 复制这条无条件寄存器链，
  // 否则 outCtrl/outData 恒为 0、io.out.valid 恒为 0，整条 vdot 通路会被当成死逻辑优化掉。
  // 这里 latency = VimacCfg.latency = 2，故链长 3（下标 0..2）。
  // -------------------------------------------------------------------------
  private val nLat   = VimacCfg.latency.latencyVal.get
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
  io.vxsat    := u.io.out.bits.res.vxsat.getOrElse(false.B)
  io.illegal  := u.io.out.bits.ctrl.exceptionVec.map(_(xiangshan.ExceptionNO.illegalInstr)).getOrElse(false.B)
}

object VIMacUHarnessMain extends App {
  private val defaultConfig = new DefaultConfig
  implicit val config: Parameters = defaultConfig.alterPartial({
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

  (new ChiselStage).execute(
    if (args.isEmpty) Array("--target-dir", "build/vdot", "--target", "verilog") else args,
    Seq(ChiselGeneratorAnnotation(() => new VIMacUHarness()(config)))
  )
}
