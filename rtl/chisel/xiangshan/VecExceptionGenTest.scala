package xiangshan.backend.decode

import chisel3._
import chisel3.stage.ChiselGeneratorAnnotation
import circt.stage.ChiselStage
import org.chipsalliance.cde.config.Parameters
import top.DefaultConfig
import utility.{LogUtilsOptions, LogUtilsOptionsKey, PerfCounterOptions, PerfCounterOptionsKey, XSPerfLevel}
import xiangshan.{DebugOptionsKey, SrcType, XSCoreParamsKey, XSModule, XSTileKey}
import xiangshan.backend.Bundles.DecodedInst
import xiangshan.backend.fu.FuType
import xiangshan.backend.fu.vector.Bundles.VType

/** VecExceptionGenHarness —— 把 [[VecExceptionGen]] 收窄成一个可以直接用 Verilator 驱动的小模块。
  *
  *  [[VecExceptionGen]] 的输入里有一个很宽的 `DecodedInst`，但它实际只读其中 4 个字段
  *  （`fuType` / `srcType(0)` / `srcType(1)` / `vecWen`，见 VecExceptionGen.scala:53-55、:280-287）。
  *  本 harness 把这 4 个字段按「向量整数乘累加类指令」的取值写死，只把真正要遍历的
  *  4 个量（指令字、vtype.vsew、vtype.vlmul、vstart）引出成端口，于是 C++ 测试平台
  *  只需要驱动 4 个输入、读 1 个输出。
  *
  *  用途：验证 vdot 指令族在**译码阶段**的合法性判定，特别是
  *    - `dotEewIllegal`：vdot/vdotacc 只许 SEW=8，vdot4a 只许 SEW=32；
  *    - `dotEmulIllegal`：三条指令只许 LMUL=1（vlmul 编码 0），其余取值报非法（裁定 S-6）。
  *  并同时回归「既有向量指令的判定没有被改坏」。
  *
  *  用法：
  *    mill -i -D jvm-xmx=8G xiangshan.test.runMain \
  *         xiangshan.backend.decode.VecExceptionGenMain --target-dir build/vdot --target verilog
  */
class VecExceptionGenHarness(implicit p: Parameters) extends XSModule {
  val io = IO(new Bundle {
    val inst    = Input(UInt(32.W))
    val vsew    = Input(UInt(2.W))
    val vlmul   = Input(UInt(3.W))
    val vill    = Input(Bool())
    val vstart  = Input(UInt(8.W))
    val illegal = Output(Bool())
  })

  private val gen = Module(new VecExceptionGen)

  gen.io.inst := io.inst

  // DecodedInst 里 VecExceptionGen 真正用到的 4 个字段，其余保持 0。
  private val di = WireInit(0.U.asTypeOf(new DecodedInst))
  di.fuType     := FuType.vimac.U       // 向量整数乘累加 —— isVArith / isVArithMem 均为真
  di.srcType(0) := SrcType.vp           // vs1 是向量操作数
  di.srcType(1) := SrcType.vp           // vs2 是向量操作数
  di.vecWen     := true.B               // 写向量目的寄存器
  gen.io.decodedInst := di

  private val vt = Wire(new VType)
  vt.illegal := io.vill
  vt.vma     := false.B
  vt.vta     := true.B
  vt.vsew    := io.vsew
  vt.vlmul   := io.vlmul
  gen.io.vtype := vt

  gen.io.vstart := io.vstart

  io.illegal := gen.io.illegalInst
}

object VecExceptionGenMain extends App {
  private val defaultConfig = new DefaultConfig
  // 与 xiangshan.backend.fu.VIMacUMain 相同的 Key 补齐（不走 top.ArgParser 时必须手动注入）
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
    Seq(ChiselGeneratorAnnotation(() => new VecExceptionGenHarness()(config)))
  )
}
