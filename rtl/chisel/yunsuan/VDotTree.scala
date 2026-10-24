package yunsuan.vector.mac

import chisel3._
import chisel3.util._
import yunsuan.vector._

/** VDotTree —— vdot 指令族的可重构蝶形折叠加法树
  *
  *  输入是 [[VIMac64b]] 在第二级流水（S1）抽出的 `prod16` —— 16 个完整的 16 位二补码乘积
  *  （证明见设计文档 §4.2）。本模块把它们按模式折叠成 4 个 32 位结果：
  *
  *    foldLevels = 0  ->  4 组各自 4 路：R_g = Σ_{j<4} E[4g+j] + acc_g      （vdot4a.vv）
  *    foldLevels = 2  ->  全 16 路归约： R_0 = Σ_{i<16} E[i]   + acc_0      （vdot.vv / vdotacc.vv）
  *
  *  结构（见设计文档 §4.4）：
  *
  *    S1：乘积门控 + 符号扩展 -> Fold L0（组内 4 路）-> Fold L1（蝶形 Δ=1）
  *        ===== RegEnable(fire) 一级流水寄存器：numLane × 2 × accWidth bit =====
  *    S2：Fold L2（蝶形 Δ=2）-> Acc（注入累加操作数）-> numLane 个独立 CPA
  *
  *  两个要点：
  *   1. 折叠控制只作用在「加数输入端的 AND 门」上，**结果路径上没有任何选择器**。
  *      依据：CSA4to2(a, b, 0, 0) 的输出满足 out_sum + out_car ≡ a + b (mod 2^width)，
  *      即关闭折叠时该级是一个合法的 carry-save 直通，不需要 bypass mux。
  *   2. 伙伴 lane 取 `g XOR Δ`（XOR 蝶形）而不是单向归并，使得每个 lane 执行完全相同的运算。
  *      于是全折叠模式下 4 个 lane 最终都持有同一个 16 路总和，`vdot` 直接取 lane0，
  *      元素 0 的定位不需要任何额外选择逻辑。
  *
  *  复用：压缩原语 [[CSA4to2]] / [[CSA3to2]] 直接取自 `yunsuan/vector/VectorFloatFMA.scala:1596/:1581`，
  *  与 `Reduction.scala:456-505` 手工搭 sew=8 归约树的做法完全一致。
  *  **不能**整体复用 `CSA_Nto2With3to2MainPipeline`：它的 `pipeLevel` 语义是「从第 pipeLevel 层起
  *  每层都插寄存器」，且压缩拓扑固定为 n→11→8→4→2，无法表达「4 组独立 4 路」这一可重构需求
  *  （见设计文档 §3.6.3 / 裁定 R-09）。
  *
  *  @param numProd   乘积个数（VLEN=128 / SEW=8 时为 16）
  *  @param prodWidth 单个乘积位宽（8×8 -> 16）
  *  @param accWidth  树内部与累加器位宽（取 32：既是目的 EEW，也让 32 位累加器零成本并入）
  */
class VDotTree(numProd: Int = 16, prodWidth: Int = 16, accWidth: Int = 32) extends Module {
  require(numProd % 4 == 0 && isPow2(numProd), "numProd 必须是 4 的倍数且为 2 的幂")
  require(accWidth > prodWidth, "accWidth 必须大于 prodWidth，否则符号扩展无意义")

  /** lane 数 = 结果数。VLEN=128 时为 4，恰好等于 vdot4a 的结果数，也等于 128/32 */
  val numLane: Int = numProd / 4
  /** 把 numLane 个 lane 完全折叠成 1 个所需的蝶形级数：log2(numLane)。numLane=4 时为 2 */
  val numFold: Int = log2Up(numLane)
  /** 流水切点：前 numFoldS1 级折叠放在 S1，其余放在 S2。
    * numFold=2 时 numFoldS1=1，即 Fold L1 在 S1、Fold L2 在 S2，与设计文档 §3.6.3 方案 B 一致 */
  val numFoldS1: Int = numFold / 2
  /** foldLevels 的位宽：要能表达 0..numFold */
  val foldSelWidth: Int = log2Up(numFold + 1)

  val io = IO(new Bundle {
    /** S1→S2 流水寄存器使能，接 VIMacU/VDotTop 的 fireS1（与 VIMac64b.scala:208 的 walOut 同拍） */
    val fire       = Input(Bool())
    /** 【S1 时序】16 个 16 位二补码乘积，低下标对应低元素号 */
    val prod       = Input(Vec(numProd, UInt(prodWidth.W)))
    /** 【S1 时序】逐乘积的 active 使能；0 表示该元素被 vl / 掩码排除出归约（注入加法单位元 0） */
    val activeEn   = Input(UInt(numProd.W))
    /** 【S1 时序】折叠级数：0 = 组内 4 路（vdot4a），numFold = 全路归约（vdot/vdotacc） */
    val foldLevels = Input(UInt(foldSelWidth.W))
    /** 【S2 时序】每个 lane 的累加操作数；不累加时外部送 0 */
    val accOperand = Input(Vec(numLane, UInt(accWidth.W)))
    /** 【S2 时序】Cat(R_{n-1}, ..., R_1, R_0)，宽度 numLane*accWidth = VLEN */
    val dotVd      = Output(UInt((numLane * accWidth).W))
  })

  // ---------------------------------------------------------------------------
  // S1 ①：乘积门控 + 符号扩展
  //   E(i) = act(i) ? sext_{accWidth}(prod(i)) : 0
  //   符号扩展是纯连线（复制 prod(i) 的最高位 accWidth-prodWidth 次），门控是 1 级 AND。
  //   把掩码/vl 折叠成「对被排除元素注入加法单位元 0」，与 Reduction.scala:186-191
  //   把被掩掉的源元素替换成运算单位元的做法同构，只是注入点从源元素移到了乘积（裁定 R-12）。
  // ---------------------------------------------------------------------------
  private val extProd = Wire(Vec(numProd, UInt(accWidth.W)))
  for (i <- 0 until numProd) {
    val signExtended = Cat(Fill(accWidth - prodWidth, io.prod(i)(prodWidth - 1)), io.prod(i))
    extProd(i) := Fill(accWidth, io.activeEn(i)) & signExtended
  }

  /** 例化一个 CSA4to2(accWidth)，返回 (sum, carry)，满足 sum + carry ≡ a+b+c+d (mod 2^accWidth) */
  private def csa4to2(a: UInt, b: UInt, c: UInt, d: UInt): (UInt, UInt) = {
    val m = Module(new CSA4to2(accWidth))
    m.io.in_a := a
    m.io.in_b := b
    m.io.in_c := c
    m.io.in_d := d
    (m.io.out_sum, m.io.out_car)
  }

  /** 例化一个 CSA3to2(accWidth)，返回 (sum, carry)，满足 sum + carry ≡ a+b+c (mod 2^accWidth) */
  private def csa3to2(a: UInt, b: UInt, c: UInt): (UInt, UInt) = {
    val m = Module(new CSA3to2(accWidth))
    m.io.in_a := a
    m.io.in_b := b
    m.io.in_c := c
    (m.io.out_sum, m.io.out_car)
  }

  /** 一级蝶形折叠：lane g 与 lane (g XOR delta) 合并。
    *  en = 0 时伙伴输入被 AND 成 0，CSA4to2(S, C, 0, 0) 是合法直通，该级不改变数值。 */
  private def foldStage(in: Seq[(UInt, UInt)], delta: Int, en: Bool): Seq[(UInt, UInt)] =
    Seq.tabulate(numLane) { g =>
      val partner = in(g ^ delta)
      csa4to2(in(g)._1, in(g)._2,
              Fill(accWidth, en) & partner._1,
              Fill(accWidth, en) & partner._2)
    }

  // ---------------------------------------------------------------------------
  // S1 ②：Fold L0（组内 4 路，lane 之间物理隔离）+ 前 numFoldS1 级蝶形折叠
  //   Fold L0 恒定执行：lane g 压缩 E[4g .. 4g+3]，|Σ| <= 4×2^14 = 2^16
  // ---------------------------------------------------------------------------
  private val foldL0: Seq[(UInt, UInt)] =
    Seq.tabulate(numLane)(g => csa4to2(extProd(4 * g), extProd(4 * g + 1),
                                       extProd(4 * g + 2), extProd(4 * g + 3)))

  private var csNodeS1: Seq[(UInt, UInt)] = foldL0
  for (k <- 0 until numFoldS1) {
    csNodeS1 = foldStage(csNodeS1, 1 << k, io.foldLevels > k.U)
  }

  // ---------------------------------------------------------------------------
  // S1 → S2 流水寄存器：numLane × 2 × accWidth bit（VLEN=128 时为 4×2×32 = 256 bit）
  //   折叠控制位同样打一拍，供 S2 的后续折叠级使用。
  // ---------------------------------------------------------------------------
  private val sumRegS2 = RegEnable(VecInit(csNodeS1.map(_._1)), io.fire)
  private val carRegS2 = RegEnable(VecInit(csNodeS1.map(_._2)), io.fire)
  private val foldLevelsS2 = RegEnable(io.foldLevels, io.fire)

  // ---------------------------------------------------------------------------
  // S2 ①：剩余的蝶形折叠级
  // ---------------------------------------------------------------------------
  private var csNodeS2: Seq[(UInt, UInt)] =
    Seq.tabulate(numLane)(g => (sumRegS2(g), carRegS2(g)))
  for (k <- numFoldS1 until numFold) {
    csNodeS2 = foldStage(csNodeS2, 1 << k, foldLevelsS2 > k.U)
  }

  // ---------------------------------------------------------------------------
  // S2 ②：Acc —— 用 CSA3to2 把累加操作数注入 carry-save 对
  //   不能走 VIMac64b 的 isMacc 通路：sew=8 时 Wallace 进位掩码把每 lane 锁死在 16 位，
  //   32 位累加器根本放不进去（设计文档裁定 R-04）。
  // ---------------------------------------------------------------------------
  private val accNode: Seq[(UInt, UInt)] =
    Seq.tabulate(numLane)(g => csa3to2(csNodeS2(g)._1, csNodeS2(g)._2, io.accOperand(g)))

  // ---------------------------------------------------------------------------
  // S2 ③：CPA —— numLane 个独立的 accWidth 位加法器，lane 之间不串进位。
  //   丢弃最高位进位即是模 2^32 回绕，正是 RVV §11「overflows wrap around」要求的行为。
  // ---------------------------------------------------------------------------
  private val laneRes: Seq[UInt] =
    Seq.tabulate(numLane)(g => (accNode(g)._1 + accNode(g)._2)(accWidth - 1, 0))

  io.dotVd := Cat(laneRes.reverse)
}

object VerilogVDotTree extends App {
  println("Generating the VDotTree hardware")
  emitVerilog(new VDotTree(), Array("--target-dir=build/vdot"))
}
