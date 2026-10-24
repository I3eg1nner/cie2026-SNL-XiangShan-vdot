package xiangshan.backend.fu

import chisel3.stage.ChiselGeneratorAnnotation
import circt.stage.ChiselStage
import org.chipsalliance.cde.config.Parameters
import top.DefaultConfig
import utility.{LogUtilsOptions, LogUtilsOptionsKey, PerfCounterOptions, PerfCounterOptionsKey, XSPerfLevel}
import xiangshan.{DebugOptionsKey, XSCoreParamsKey, XSTileKey}
import xiangshan.backend.fu.FuConfig.VimacCfg
import xiangshan.backend.fu.wrapper.VIMacU

/** 单独精化 VIMacU（含 vdot 指令族的 VDotTree / ByteMaskTailGen / RedTailGen）并生成 Verilog。
  *
  *  全核精化（`top.TopMain`）在本机 16 GB 内存下不可行（官方要求 -Xmx40G，见
  *  docs/stage1/03_仿真平台搭建报告.md §7.1），因此按功能单元粒度精化，
  *  用来证明 vdot 改动在 XiangShan 侧真的能 elaborate，而不只是通过 Scala 类型检查。
  *
  *  写法照抄同目录下既有的 `xiangshan.DecodeMain`（src/test/scala/xiangshan/DecodeTest.scala:15-35）。
  *
  *  用法：
  *    mill -i -D jvm-xmx=8G xiangshan.test.runMain xiangshan.backend.fu.VIMacUMain \
  *         --target-dir build/vdot --target verilog
  */
object VIMacUMain extends App {
  private val defaultConfig = new DefaultConfig
  // 除了把 XSCoreParams 透传给"小模块"之外，还要补上 XSError/XSLog 需要的两个
  // 日志选项 Key —— 它们平时由 top.ArgParser.parse() 的 .alter 注入（ArgParser.scala:271-284），
  // 这里不走 ArgParser，必须自己补，否则精化会报 "Key LogUtilsOptionsKey is not defined"。
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
    Seq(ChiselGeneratorAnnotation(() => new VIMacU(VimacCfg)(config)))
  )
}
