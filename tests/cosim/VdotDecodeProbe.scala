/***************************************************************************************
 * VdotDecodeProbe —— 协同仿真用的「译码侧非法指令」探针（赛题阶段三 3.1.2 / P6）
 *
 * 目的：
 *   NEMU（REF）在遇到非法的 vdot 配置时会抛 Illegal Instruction；功能单元 VDotTop
 *   本身不建模异常，异常判定在香山里发生在**译码阶段**。本模块把真实流水线里的
 *   两级判定原样串起来，暴露成一个纯组合的 (instr, vtype, vstart) -> illegal 接口，
 *   以便 C++ 测试平台对 REF 的 trap 与 DUT 的 illegal 做逐条比对。
 *
 * 连接关系与真实流水线完全一致：
 *   DecodeStage.scala:104   decoderComp = Module(new DecodeUnitComp)
 *   DecodeStage.scala:152   complexInst <- decoders(i).io.deq.decodedInst   （简单译码结果）
 *   DecodeUnitComp.scala:168-173
 *       vecException.io.inst        := latchedInst.instr
 *       vecException.io.decodedInst := latchedInst
 *       vecException.io.vtype       := latchedInst.vpu.vtype
 *       vecException.io.vstart      := latchedInst.vpu.vstart
 *   DecodeUnitComp.scala:198
 *       dst.exceptionVec(EX_II) := latchedInst.exceptionVec(EX_II) || illegalInst
 *
 * 这里唯一省略的是 DecodeUnitComp 入口的那一级寄存器（latch），它只影响时序、
 * 不影响判定结果，因此探针是纯组合的。
 ***************************************************************************************/
package xiangshan.backend.decode

import org.chipsalliance.cde.config.Parameters
import chisel3._
import chisel3.util._
import xiangshan._
import xiangshan.ExceptionNO.illegalInstr
import xiangshan.backend.fu.FuType
import xiangshan.backend.fu.vector.Bundles.{VType, Vl}
import xiangshan.backend.regfile.IntPregParams
import top.ArgParser

class VdotDecodeProbe(implicit p: Parameters) extends XSModule {
  val io = IO(new Bundle {
    val instr  = Input(UInt(32.W))
    val vtype  = Input(new VType)
    val vstart = Input(Vl())

    /** 最终送进 ROB 的非法指令标志（简单译码 + 向量异常生成器） */
    val illegal        = Output(Bool())
    /** 仅简单译码器给出的 EX_II（未知编码等） */
    val illegalSimple  = Output(Bool())
    /** 仅 VecExceptionGen 给出的向量非法判定 */
    val illegalVec     = Output(Bool())
    /** 该指令是否走复杂译码通路（只有复杂通路才会经过 VecExceptionGen） */
    val isComplex      = Output(Bool())
    val fuType         = Output(UInt(FuType.num.W))
    val fuOpType       = Output(UInt(FuOpTypeWidth.W))
  })

  private val du = Module(new DecodeUnit)
  du.io.enq.ctrlFlow := 0.U.asTypeOf(du.io.enq.ctrlFlow)
  du.io.enq.ctrlFlow.instr := io.instr
  du.io.enq.vtype  := io.vtype
  du.io.enq.vstart := io.vstart
  du.io.csrCtrl    := 0.U.asTypeOf(du.io.csrCtrl)
  du.io.fromCSR    := 0.U.asTypeOf(du.io.fromCSR)

  private val simpleInst = du.io.deq.decodedInst

  private val vecException = Module(new VecExceptionGen)
  vecException.io.inst        := simpleInst.instr
  vecException.io.decodedInst := simpleInst
  vecException.io.vtype       := simpleInst.vpu.vtype
  vecException.io.vstart      := simpleInst.vpu.vstart

  io.illegalSimple := simpleInst.exceptionVec(illegalInstr)
  io.illegalVec    := vecException.io.illegalInst
  io.isComplex     := du.io.deq.isComplex
  io.illegal       := io.illegalSimple || (du.io.deq.isComplex && vecException.io.illegalInst)
  io.fuType        := simpleInst.fuType
  io.fuOpType      := simpleInst.fuOpType
}

object VdotDecodeProbeMain extends App {
  val (config, firrtlOpts, firtoolOpts) = ArgParser.parse(args)
  val defaultConfig = config.alterPartial({
    case XSCoreParamsKey => config(XSTileKey).head.copy(
      intPreg = IntPregParams(
        numEntries = 64,
        numRead = Some(14),
        numWrite = Some(8),
      ),
    )
  })
  (new _root_.circt.stage.ChiselStage).execute(args, Seq(
    chisel3.stage.ChiselGeneratorAnnotation(() => new VdotDecodeProbe()(defaultConfig))
  ))
}
