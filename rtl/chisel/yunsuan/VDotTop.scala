package yunsuan.vector.mac

import chisel3._
import chisel3.util._
import yunsuan.VimacType
import yunsuan.vector._
import yunsuan.util._

/** VDotTop —— vdot 指令族在 YunSuan 侧的独立功能单元顶层
  *
  *  用途：把「2 片 [[VIMac64b]] 的 16 路 8×8 乘法阵列 + [[VDotTree]] 可重构折叠加法树」
  *  封装成一个可以直接挂进 YunSuan 独立 FU 测试平台（`src/test/scala/top/VectorSimTop.scala`）
  *  的模块，从而让 vdot 三条指令能在 L1 层做逐周期差分验证。
  *
  *  与 XiangShan 侧 `VIMacU` 的关系：
  *    - **算术通路完全相同**：同样的 VIMac64b.prod16 抽头、同样的 VDotTree 例化、同样的
  *      accOperand 选择、同样的 latency = 2。
  *    - **掩码/尾部成形不同**：`VIMacU` 复用 XiangShan 的 `ByteMaskTailGen` + `Mgu`
  *      （它们是 `xiangshan.backend.fu.vector` 包的模块，YunSuan 不可见），本模块按
  *      `tests/golden/vdot_ref.c` 的行为表直接实现等价逻辑。两边语义一致，见
  *      `docs/stage2/11_RTL实现说明.md`「局限性」。
  *
  *  流水：latency = 2（与 VIMac64b 的 S0/S1/S2 三段组合逻辑对齐）
  *    fire  : 输入有效当拍，驱动 VIMac64b 的 S0->S1 寄存器
  *    fireS1: fire 的下一拍，驱动 VIMac64b 的 S1->S2 寄存器与 VDotTree 的 S1->S2 寄存器
  */
class VDotTop extends Module {
  val VLEN = 128

  val io = IO(new Bundle {
    val fire     = Input(Bool())
    /** VimacType 编码的 9 位 fuOpType，取值为 VimacType.vdot / vdotacc / vdot4a */
    val fuOpType = Input(UInt(9.W))
    val info     = Input(new VIFuInfo)
    val vs2      = Input(UInt(VLEN.W))
    val vs1      = Input(UInt(VLEN.W))
    val oldVd    = Input(UInt(VLEN.W))
    val mask     = Input(UInt(VLEN.W))

    val vd       = Output(UInt(VLEN.W))
  })

  private val fire   = io.fire
  private val fireS1 = GatedValidRegNext(fire)

  private val isDot4a  = VimacType.isDot4a(io.fuOpType)
  private val isDotAcc = VimacType.isDotAcc(io.fuOpType)

  // ---------------------------------------------------------------------------
  // 乘法阵列：2 片 VIMac64b，片 m 处理元素 8m..8m+7。
  // 三条 vdot 指令一律把源类型固定成 s8（有符号 8 位），与 vtype.vsew 无关：
  //   vdot/vdotacc 的 vtype.vsew 本就是 e8；
  //   vdot4a 的 vtype.vsew 是 e32，但乘法阵列必须按 e8 切分子元素。
  // srcType 编码为 Cat(0, sign, sew[1:0])，s8 = "b0100"，s32 = "b0110"。
  // ---------------------------------------------------------------------------
  private val srcTypeS8  = "b0100".U(4.W)
  private val vdTypeS32  = "b0110".U(4.W)
  private val vimacs = Seq.fill(2)(Module(new VIMac64b))
  vimacs.zipWithIndex.foreach { case (mod, i) =>
    mod.io.fire       := fire
    mod.io.info       := io.info
    mod.io.srcType(0) := srcTypeS8
    mod.io.srcType(1) := srcTypeS8
    mod.io.vdType     := vdTypeS32
    mod.io.vs2        := UIntSplit(io.vs2, 64)(i)
    mod.io.vs1        := UIntSplit(io.vs1, 64)(i)
    mod.io.oldVd      := UIntSplit(io.oldVd, 64)(i)
    // 五个判定对 VimacOpcode.vdot(b111) 天然全部返回 false，这里显式接 false 以示意图
    mod.io.highHalf   := false.B
    mod.io.isMacc     := false.B
    mod.io.isSub      := false.B
    mod.io.widen      := false.B
    mod.io.isFixP     := false.B
  }

  // ---------------------------------------------------------------------------
  // S0：active 使能生成（与乘法阵列并行，不在关键路径上）
  //   归约形态（vdot/vdotacc）：active(i) = (vstart <= i < vl) && (vm || v0.mask[i])
  //     其中 vstart >= vl 时整体清零（裁定 S-5）。
  //     注：架构上 S-1 保证归约类指令的 vstart 恒为 0（否则在译码阶段就报非法），
  //     这里仍按 prestart 规则实现，使 FU 级平台在放宽策略下也给出规范行为。
  //   逐元素形态（vdot4a）：掩码粒度是 32 位目的元素，由下面的输出成形逻辑处理，
  //     乘积一律参与运算，故 active 全 1。
  // ---------------------------------------------------------------------------
  private val vl     = io.info.vl
  private val vstart = io.info.vstart
  private val redActiveEn = VecInit(Seq.tabulate(16) { i =>
    (i.U >= vstart) && (i.U < vl) && (io.info.vm || io.mask(i))
  }).asUInt
  private val dotActiveEn = Mux(isDot4a, ~0.U(16.W), redActiveEn)

  // ---------------------------------------------------------------------------
  // S1：折叠加法树
  // ---------------------------------------------------------------------------
  private val vdotTree = Module(new VDotTree(numProd = 16, prodWidth = 16, accWidth = 32))
  vdotTree.io.fire     := fireS1
  // 片 0 的 prod16(b) 是元素 b，片 1 的 prod16(b) 是元素 8+b（见设计文档 §4.2 元素到硬件的映射表）
  vdotTree.io.prod     := VecInit(vimacs.flatMap(m => (0 until 8).map(b => m.io.prod16(b))))
  vdotTree.io.activeEn := RegEnable(dotActiveEn, fire)
  vdotTree.io.foldLevels := RegEnable(Mux(isDot4a, 0.U(2.W), 2.U(2.W)), fire)

  // S2 级信号
  private val isDot4aS2  = RegEnable(RegEnable(isDot4a,  fire), fireS1)
  private val isDotAccS2 = RegEnable(RegEnable(isDotAcc, fire), fireS1)
  private val oldVdS2    = RegEnable(RegEnable(io.oldVd, fire), fireS1)
  private val maskS2     = RegEnable(RegEnable(io.mask,  fire), fireS1)
  private val vlS2       = RegEnable(RegEnable(vl,       fire), fireS1)
  private val vstartS2   = RegEnable(RegEnable(vstart,   fire), fireS1)
  private val vmS2       = RegEnable(RegEnable(io.info.vm, fire), fireS1)
  private val vtaS2      = RegEnable(RegEnable(io.info.ta, fire), fireS1)
  private val vmaS2      = RegEnable(RegEnable(io.info.ma, fire), fireS1)

  // 累加操作数：vdot4a 逐 lane 注入 oldVd.u32[g]；vdotacc 只在 lane0 注入 oldVd.u32[0]；vdot 全 0
  for (g <- 0 until 4) {
    val redAcc = if (g == 0) Mux(isDotAccS2, oldVdS2(31, 0), 0.U(32.W)) else 0.U(32.W)
    vdotTree.io.accOperand(g) := Mux(isDot4aS2, oldVdS2(32 * g + 31, 32 * g), redAcc)
  }
  private val dotVd = vdotTree.io.dotVd

  // ---------------------------------------------------------------------------
  // S2：写回成形
  // ---------------------------------------------------------------------------
  private val vstartGeVlS2 = vstartS2 >= vlS2

  // (1) 归约形态：只写目的元素 0（EEW=32），元素 1..3 按 vta 处理；vma 被忽略（裁定 S-2）。
  //     照抄 Reduction.scala:644-647 的 red_vd_tail 惯用法，目的 EEW 固定为 32。
  private val redVdTailOne = Cat(~0.U((VLEN - 32).W), dotVd(31, 0))
  private val redVdTailOld = Cat(oldVdS2(VLEN - 1, 32), dotVd(31, 0))
  private val redVd = Mux(vstartGeVlS2, oldVdS2, Mux(vtaS2, redVdTailOne, redVdTailOld))

  // (2) 逐元素形态（vdot4a）：prestart / body-active / body-inactive / tail 四分支，
  //     掩码粒度为 32 位目的元素，逐条对应 vdot_ref.c:141-176。
  private val dot4aVd = Cat(Seq.tabulate(4) { i =>
    val oldElem   = oldVdS2(32 * i + 31, 32 * i)
    val prestart  = i.U < vstartS2
    val tail      = i.U >= vlS2
    val inactive  = !vmS2 && !maskS2(i)
    Mux(vstartGeVlS2 || prestart, oldElem,
    Mux(tail,     Mux(vtaS2, ~0.U(32.W), oldElem),
    Mux(inactive, Mux(vmaS2, ~0.U(32.W), oldElem),
                  dotVd(32 * i + 31, 32 * i))))
  }.reverse)

  io.vd := Mux(isDot4aS2, dot4aVd, redVd)
}

object VerilogVDotTop extends App {
  println("Generating the VDotTop hardware")
  emitVerilog(new VDotTop(), Array("--target-dir=build/vdot"))
}
