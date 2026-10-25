# vdot 指令族 RTL 实现说明

| 项 | 值 |
|---|---|
| 对应赛题 | 阶段二 2.2「RTL 实现」 |
| 对应计划 | `docs/_plan/MASTER_PLAN.md` 阶段 **P3** |
| 设计依据 | `docs/stage2/10_vdot指令设计文档.md`（§6 集成点清单 A1–A6 / B1–B2 / C1–C5 / D1–D4 / E1–E3） |
| 语义唯一事实来源 | `tests/golden/vdot_ref.c` + `vdot_ref.h`（裁定 S-1…S-9） |
| 基线 | XiangShan `kunminghu-v2` @ `a4eeaab`，`yunsuan` @ `9559211` |
| 实现工作树 | `work/XiangShan-vdot`（与 pristine 基线 `work/XiangShan-kmhv2` 隔离） |
| **行号基准（全文唯一）** | 本文出现的**每一处** `文件:行号`，行号都以**实现工作树**为准，即「pristine 基线 + §3 列出的三份补丁」之后的文件状态。全文不使用第二套基准；凡在上游文件中引用的行号，均已按补丁的行偏移换算到该基准 |
| 行号的离线核对方式 | 三份补丁涉及的全部 Chisel 源码已逐字节复制到 `rtl/chisel/`（清单与每个文件的行数见 `rtl/chisel/MANIFEST.md`），因此**不需要 `work/` 也能按行号核对**；副本由 `scripts/tools/sync_rtl_sources.sh` 从「基线 + 补丁」重建，`--check` 模式可验证副本未漂移。C++ 侧（`test_driver.cpp`、`vpu_constant.h` 等）不在该目录，按 `tests/unit/yunsuan_vdot_testbench.patch` 核对 |
| 架构参数 | VLEN = 128，ELEN = 64，XLEN = 64，LMUL = 1 |

---

## 0. 结论速览

| 项 | 结果 | 证据 |
|---|---|---|
| `mill -i YunSuan.compile`（mill 0.11.1） | **通过**，82 个 Scala 源文件 | `logs/stage2/p4_rtl_build.log` |
| `mill -i xiangshan.compile`（mill 0.12.3） | **通过**，382 个 Scala 源文件，77 s | `logs/stage2/p4_rtl_build.log` |
| `VDotTree` / `VDotTop` / `VIMac` Verilog 生成 | **通过** | `logs/stage2/p4_verilog_emit.log`、`rtl/verilog/vdot/` |
| `VIMacU`（含 vdot）单 FU 精化出 Verilog | **通过**，4876 行 | `rtl/verilog/vdot/VIMacU.v` |
| `DecodeUnit`（含三条新指令）精化出 Verilog | **通过** | `rtl/verilog/vdot/DecodeUnit.v` |
| 对既有 `vmul`/`vmacc`/`vsmul` 的影响 | **生成的 Verilog 逐字节相同**（去掉源码行号注释后 diff 为 0 行） | §7.1 |
| L1 冒烟测试（三条指令各 20000 随机 + 混合 20000 + 定向语料 178 条，合计 80178 条） | **全部 PASS，0 失配** | `logs/stage2/p4_smoke_test.log` |
| 故障注入自测（人为改坏一位） | **按预期 BADTRAP** | `logs/stage2/p4_fault_inject.log` |
| P4 完整功能测试（含 `VIMacU` 直驱 26024 条、随机 235348 条、5 个故障注入；裁定 S-7' 传播后重跑的数字，修订前为 27529 / 236887） | **全部 PASS** | `docs/stage2/12_基础功能测试报告.md`、`logs/stage2/p5_*.log` |
| `FuConfig` / `FuType` / `Parameters` / Dispatch / IQ / WbArbiter | **一行未改**（与设计文档 §5.1 第 15 项一致） | §6 文件清单 |

---

## 1. 模块层次与改动总览

```
XiangShan backend（mill 工程 xiangshan，mill 0.12.3）
└── VFEX0 / VIMacU(VimacCfg)             src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala   [改 +84/-9]
      ├── VIMacSrcTypeModule                   [改] vdot 三条指令强制 src=s8 / vd=e32
      ├── VecDataSplitModule × 3               [复用，未改]
      ├── VIMac64b × 2            yunsuan      [仅加只读输出端口 prod16]
      ├── ByteMaskTailGen(128)                 [复用，新例化一份做乘积门控]
      ├── VDotTree                yunsuan      [新建，161 行]
      ├── RedTailGen（3 行组合逻辑，内联在 VIMacU）[新]
      └── Mgu(128)                             [复用，未改；vdot4a 走这条路]

YunSuan（mill 工程 YunSuan，mill 0.11.1）
├── VimacOpcode.scala                     [改 +4]   新增 opcode b111 与 isVdot
├── package.scala / object VimacType      [改 +17]  新增 vdot/vdotacc/vdot4a 及 5 个判定
├── vectorIMAC/VIMac64b.scala             [改 +7]   新增 prod16 输出端口（纯读出）
├── vectorIMAC/VDotTree.scala             [新 161]  可重构蝶形折叠加法树 + Verilog 出口
└── vectorIMAC/VDotTop.scala              [新 150]  L1 平台用的 YunSuan 侧 FU 顶层 + Verilog 出口

译码链路（全部在 xiangshan 工程）
├── decode/Instructions.scala             [改 +11]  object Xsvdot 的三条 BitPat
├── decode/VecDecoder.scala               [改 +9]   opivv 表三行
├── decode/DecodeUnit.scala               [改 +5]   vmaInsts 登记三条
└── decode/VecExceptionGen.scala          [改 +34/-4]  dotRedInst/dot4aInst、SEW/LMUL 判定、vdIsSingleElem、vdEew
```

---

## 2. 逐模块走读

### 2.1 `VimacOpcode`（A1）

`VimacOpcode.width = 3`，原有 `b000`–`b110` 七个取值已占满，**只剩 `b111`**。三条 vdot 指令共用这一个 opcode，具体是哪一条由 `VimacType` 的 pad 位区分（裁定 R-03）。

```scala
def vdot    = "b111".U(width.W)
def isVdot(opcode: UInt) = opcode === vdot
```

关键点：**`highHalf` / `isMacc` / `isSub` / `isFixP` / `overWriteMultiplicand` 这五个判定一行都没改**。
它们都是 `Seq(具体值).map(_ === opcode).reduce(_||_)` 的形式，对 `b111` 自动返回 `false` —— 这正是我们要的（vdot 不取高半、不走 Wallace 树累加、不减、不饱和、不交换被乘数）。

### 2.2 `VimacType`（A2）

`VimacType` 总宽 9 位（`yunsuan/package.scala:8` `OpTypeWidth = 9`），布局：

```
[8:7] pad   [6] vs2Sign   [5] vs1Sign   [4] vdSign   [3] format   [2:0] VimacOpcode
```

现有全部取值的 `pad == 00`（逐条可验），高半空间完全空闲。新增：

| 指令 | pad | vs2 | vs1 | vd_old | format | opcode | 9 位值 |
|---|---|---|---|---|---|---|---|
| `vdot`    | `01` | S | S | X | VVV | `111` | `0_1110_0111` = 0x0E7 |
| `vdotacc` | `10` | S | S | S | VVV | `111` | `1_0111_0111` = 0x177 |
| `vdot4a`  | `11` | S | S | S | VVV | `111` | `1_1111_0111` = 0x1F7 |

`format` 一律取 `FMT.VVV`，于是 `VIMacU` 推导出的 `widen` 恒为 `false`，绕开只支持 2 倍扩宽的 widen 通路（vdot 需要的是 4 倍 8→32），只走新增的 `prod16` 抽头。

访问器（供 XiangShan 侧与 YunSuan 侧共用）：

```scala
def dotVariant(t) = t(8, 7)                      // 1=vdot 2=vdotacc 3=vdot4a
def isVdot(t)     = VimacOpcode.isVdot(t(2,0))
def isDot4a(t)    = isVdot(t) && dotVariant(t) === 3.U
def isDotRed(t)   = isVdot(t) && dotVariant(t) =/= 3.U
def isDotAcc(t)   = isVdot(t) && dotVariant(t) === 2.U
```

`FuOpTypeWidth = 9`（`xiangshan/package.scala:68`），`fuOpType` 端口能完整带上 pad 位，不存在截断。

### 2.3 `VIMac64b.prod16` 抽头（A3）

唯一的改动是**新增一个只读输出端口**：

```scala
val prod16 = Output(Vec(8, UInt(16.W)))   // IO Bundle 新增
...
io.prod16 := sum_wo                        // for 循环之后新增一行
```

`sum_wo`（`VIMac64b.scala:192`）是第二级流水（S1）末尾 8 个 `Adder_16b` 的输出。在
`sew=8 / widen=0 / isMacc=0 / isSub=0 / isFixP=0` 条件下它就是 8 个**完整的 16 位二补码有符号乘积**：

1. `partProd(33)`（oldVd 注入）在 `isMacc=0` 时为 0；
2. `sew=8` 时 Wallace 的进位掩码 `h7fff7fff…`（`:143`）与 `cin_wo(i) := Mux(sewS1.is8, false.B, …)`（`:203`）共同保证 8 个 16 位 lane 完全独立；
3. 反向验证：既有 `vmulh.vv` 在 `sew=8` 时直接取 `walOut` 每 16 位 lane 的 `[15:8]`（`:228`），而 `vmulh` 的定义就是「有符号乘积的高半」—— 这只有在 lane 内是完整 16 位有符号乘积时才成立。

**对既有指令零影响的硬证据**：见 §7.1，重新生成的 `VIMac.sv` 与阶段一存档的基线 `rtl/verilog/baseline/VIMac.sv` 在去掉源码行号注释后**逐字节相同**。

### 2.4 `VDotTree`（A4/A5，新建 161 行）

文件：`yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/VDotTree.scala`

```scala
class VDotTree(numProd: Int = 16, prodWidth: Int = 16, accWidth: Int = 32) extends Module
```

派生常量（为 §8 的扩展性预留，默认配置下取值见括号）：

| 名称 | 定义 | VLEN=128 取值 | 含义 |
|---|---|---|---|
| `numLane` | `numProd / 4` | 4 | lane 数 = 结果数 = `VLEN/32` |
| `numFold` | `log2Up(numLane)` | 2 | 全折叠所需的蝶形级数 |
| `numFoldS1` | `numFold / 2` | 1 | 放在 S1 的折叠级数（Fold L1） |
| `foldSelWidth` | `log2Up(numFold + 1)` | 2 | `foldLevels` 端口位宽 |

IO 的时序约定（这是接线时最容易错的地方，已写进源码注释）：

| 端口 | 时序 | 说明 |
|---|---|---|
| `fire` | — | S1→S2 流水寄存器使能，接 `fireS1` |
| `prod(16)` | **S1** | 来自 `VIMac64b.prod16`，本身就是 S1 组合输出 |
| `activeEn(16)` | **S1** | 在 S0 算好，用 `RegEnable(_, io.in.valid)` 打一拍送入 |
| `foldLevels(2)` | **S1** | 同上 |
| `accOperand(4×32)` | **S2** | 直接接 `outOldVd`（已是 S2 级信号），省掉 128 bit 寄存器 |
| `dotVd(128)` | **S2** | `Cat(R3,R2,R1,R0)` |

#### 结构与各级位宽推导

```
          prod(i) : 16 位二补码乘积，范围 [-16256, +16384]        × 16
             │
  ① 门控+符号扩展   E(i) = Fill(32, act(i)) & Cat(Fill(16, prod(i)(15)), prod(i))
             │      32 位（符号扩展是纯连线，门控是 1 级 AND）     × 16
             ▼
  ② Fold L0（恒执行）4 × CSA4to2(32)，lane g 吃 E[4g..4g+3]
             │      (S0_g, C0_g)，S0_g + C0_g ≡ Σ_{j<4} E[4g+j] (mod 2^32)，|Σ| ≤ 2^16
             ▼
  ③ Fold L1（Δ=1） 4 × CSA4to2(32)，伙伴 lane = g XOR 1
             │      输入 {S0_g, C0_g, fold1 & S0_{g^1}, fold1 & C0_{g^1}}
             ▼
  ══════ RegEnable(fire)：numLane × 2 × 32 = 256 bit ══════  （S1 → S2）
             ▼
  ④ Fold L2（Δ=2） 4 × CSA4to2(32)，伙伴 lane = g XOR 2
             │      全折叠时 |Σ| ≤ 16 × 2^14 = 2^18，只占 20 位，32 位远未溢出
             ▼
  ⑤ Acc          4 × CSA3to2(32)，第三输入 accOperand(g)
             ▼
  ⑥ CPA          4 × 32 位加法器，lane 之间 **不串进位**
                 R_g = (S3_g + C3_g)[31:0]  → 丢弃最高位进位 = 模 2^32 回绕
             ▼
          dotVd = Cat(R3, R2, R1, R0)   128 位
```

**为什么内部取 32 位而不是最小的 20 位**：① 32 位累加器可以不做任何对齐就作为一个加数进 CSA；② 目的 EEW 就是 32，省掉输出侧扩展；③ `4 × 32 = 128` 恰好等于 `destDataBits`，`vdot4a` 的 4 个结果天然对齐到 `vd` 的 4 个 32 位元素，`Mgu` 零重排。

#### 树如何为三条指令重构

控制面只有一个 2 位的 `foldLevels`，第 `k` 级折叠的使能是 `foldLevels > k.U`：

| 指令 | `foldLevels` | fold1 | fold2 | 每个 lane 的结果 | 取用 |
|---|---|---|---|---|---|
| `vdot4a.vv` | `0` | 0 | 0 | `R_g = Σ_{j<4} E[4g+j] + oldVd.u32[g]` | 4 个全用 |
| `vdot.vv` | `2` | 1 | 1 | `R_g = Σ_{i<16} E[i]`（4 个 lane 值相同） | 取 lane0 |
| `vdotacc.vv` | `2` | 1 | 1 | `R_0 = Σ_{i<16} E[i] + oldVd.u32[0]` | 取 lane0 |
| （预留）8 路分组 | `1` | 1 | 0 | `R_0 = Σ_{i<8}`，`R_2 = Σ_{8≤i<16}` | — |

两条关键性质：

1. **关闭折叠时不需要 bypass mux**。`CSA4to2(a, b, 0, 0)` 的输出满足 `out_sum + out_car ≡ a + b (mod 2^32)`，即该级仍是 `(a,b)` 这对 carry-save 数的一个合法再表示。所以模式切换只作用在**加数输入端的 16 个 32 位 AND 门**上，**结果路径上零选择器**，不增加关键路径。
2. **XOR 蝶形让每个 lane 做完全相同的事**。全折叠模式下 4 个 lane 最终都持有同一个 16 路总和，`vdot` 直接取 `lane0`，**元素 0 的定位不需要任何额外选择逻辑**；RTL 也因此是完全规整的 `Seq.tabulate(numLane)` 生成，没有特例分支。

代价是全折叠模式下 lane1..3 算了 3 份冗余结果（功耗，不是面积）。设计文档 §4.4.3 建议的冗余 lane 操作数门控**本版本未实现**，见 §9 设计偏离记录第 4 条。

#### 复用的压缩原语

`CSA4to2(32)` × 12 与 `CSA3to2(32)` × 4 全部直接例化 YunSuan 现成原语
（`yunsuan/src/main/scala/yunsuan/vector/VectorFloatFMA.scala:1596` / `:1581`），一行没改。
二者是 `private[vector]`，而 `VDotTree` 在 `yunsuan.vector.mac` 包（`yunsuan.vector` 的子包）内，可见性天然满足。
这与 `Reduction.scala:456-505` 手工例化这两个原语搭 `sew=8` 归约树的做法完全一致。

**没有**整体使用 `CSA_Nto2With3to2MainPipeline`：它的 `pipeLevel` 语义是「从第 `pipeLevel` 层起**每层都插寄存器**」（`VectorFloatFMA.scala:1899-1903` 的 `is_piped` 一旦置真不复位），且压缩拓扑固定为 `n→11→8→4→2`，**无法表达「4 组独立 4 路」的可重构需求**（裁定 R-09）。

### 2.5 `VIMacU`（B1/B2，改 +84/−9）

#### (a) `VIMacSrcTypeModule`

```scala
private val isDot = VimacType.isVdot(fuOpType)
private val vs2Type = Cat(vs2IntType, Mux(isDot, VSew.e8,  vsew))
private val vs1Type = Cat(vs1IntType, Mux(isDot, VSew.e8,  vsew))
private val vdType  = Cat( vdIntType, Mux(isDot, VSew.e32, Mux(widen, vsewX2, vsew)))
```

`vdot`/`vdotacc` 的 `vtype.vsew` 本就是 e8（覆写幂等）；`vdot4a` 的 `vtype.vsew` 是 e32，但乘法阵列必须按 e8 切分 4 个 int8 子元素 —— 这正是覆写的意义。符号性来自 `VimacType` 的 `vs2Sign/vs1Sign`，三条指令都是 `INT.S`，于是 `srcType = "b0100" = s8`，**乘法器本体一行不改即做有符号 8×8**。

#### (b) 乘积门控使能

```scala
dotMaskGen.io.in.begin    := vstart         // 归约类架构上恒为 0（S-1）
dotMaskGen.io.in.end      := srcVConfig.vl
dotMaskGen.io.in.vsew     := VSew.e8        // 源元素宽度，三条指令恒为 e8
dotMaskGen.io.in.maskUsed := srcMask(15, 0)
dotMaskGen.io.in.vdIdx    := 0.U            // LMUL=1，单 uop（S-6）
private val dotActiveEn = Mux(isDot4a, ~0.U(16.W), dotMaskGen.io.out.activeEn)
```

把「`vl` 截断 + `v0` 掩码」统一折叠成「对被排除的源元素注入加法单位元 0」，与
`Reduction.scala:186-191` 把被掩掉的源元素替换成运算单位元同构，只是注入点从源元素移到了乘积
（裁定 R-12：乘积门控只需 16 个 32 位 AND，且落在有裕量的 S1；源元素门控要挤 S0 这段最长的组合逻辑）。
`vdot4a` 的掩码粒度是 32 位目的元素，由 `Mgu` 按 `outEew = e32` 处理，乘积一律参与运算，故 active 全 1。

#### (c) 树的接线与流水对齐

```scala
private val fireS1 = GatedValidRegNext(io.in.valid)      // 与 VIMac64b.scala:38 完全同拍
vdotTree.io.fire       := fireS1
vdotTree.io.prod       := VecInit(vimacs.flatMap(m => (0 until 8).map(b => m.io.prod16(b))))
vdotTree.io.activeEn   := RegEnable(dotActiveEn, io.in.valid)
vdotTree.io.foldLevels := RegEnable(Mux(isDot4a, 0.U(2.W), 2.U(2.W)), io.in.valid)
```

元素到硬件的映射：`vimacs(0).prod16(b)` = 元素 `b`，`vimacs(1).prod16(b)` = 元素 `8+b`
（`VecDataSplitModule` 小端切分 → 片 m 处理元素 `8m..8m+7` → 片内 `sum_wo(b)` 对应第 b 个 8 位元素）。

`accOperand` 直接接 S2 级的 `outOldVd`：

```scala
for (g <- 0 until 4) {
  val redAcc = if (g == 0) Mux(outIsDotAcc, outOldVd(31, 0), 0.U(32.W)) else 0.U(32.W)
  vdotTree.io.accOperand(g) := Mux(outIsDot4a, outOldVd(32*g+31, 32*g), redAcc)
}
```

**特别注意**：`mod.io.isMacc := VimacOpcode.isMacc(opcode)` 对 `b111` 自动为 false，**绝不能**为了累加去打开它 —— `sew=8` 时 Wallace 进位掩码把每 lane 锁死在 16 位，32 位累加器根本放不进去，且 `oldVd` 会被当成 16 个 8 位元素逐个加（裁定 R-04）。

#### (d) `RedTailGen` 与输出复用

```scala
private val redVdTailOne = Cat(~0.U(96.W),            dotVd(31, 0))
private val redVdTailOld = Cat(outOldVd(127, 32),     dotVd(31, 0))
private val redVd = Mux(outVstart >= outVl, outOldVd,                 // S-5
                    Mux(outVecCtrl.vta, redVdTailOne, redVdTailOld))  // S-3

mgu.io.in.vd              := Mux(outIsDot, dotVd, outVd)
io.out.bits.res.data      := Mux(outIsDotRed, redVd, mgu.io.out.vd)
io.out.bits.res.vxsat.get := Mux(outIsDot, false.B, (outVxsat & mgu.io.out.active).orR)
```

- 归约类**绕过 `Mgu`**：`Mgu` 的逐字节 active/tail 模型表达不了「只写元素 0，其余按 `vta`」（裁定 R-13，`VIPU` 面对同样的问题也是绕过 `Mgu`）。上面三行是 `Reduction.scala:644-647` 的 `red_vd_tail` 惯用法在「目的 EEW 固定 32」下的特化（用 `Cat` 代替移位，综合结果等价且更直白）。
- `vdot4a` 是标准的逐元素三源指令，**继续走 `Mgu`**，只是 `vd` 来源换成 `dotVd`，`eew` 由 `outEew` 给出 e32，`Mgu` 内部 `VecDataToMaskDataVec(mask, e32)` 自动给出 32 位掩码粒度 —— 正是 S-7 要的，零额外代码。
- `vxsat` 对三条 vdot 指令恒 0（设计文档 §1.6 的溢出证明：`|Σ p_i| ≤ 16 × 2^14 = 2^18 < 2^31`）。

#### (e) 流水与延迟

`VIMacU` 继承 `VecPipedFuncUnit`，流水寄存器由 `HasPipelineReg` 按 `latency = VimacCfg.latency = 2` 自动生成，`FuConfig.scala` **一行未改**。VDotTree 的 S1/S2 切分与 `VIMac64b` 的 `wallaceOut_mid_reg`(S0→S1) / `walOut`(S1→S2) 两级寄存器严格对齐：

```
T0 (fire)      : Booth + partProd + Wallace 前 5 级        | ByteMaskTailGen（并行）
   --reg1-->     wallaceOut_mid_reg                        | activeEnS1 / foldLevelsS1
T1 (fireS1)    : Wallace 后 3 级 + 8×Adder_16b -> sum_wo   | 门控+符号扩展 + Fold L0 + Fold L1
   --reg2-->     walOut                                    | (S1_g, C1_g) 8×32b = 256 bit
T2             : vdS2 / vsmul（vdot 不用）                 | Fold L2 + Acc + CPA + RedTailGen + 输出 mux
```

**FU 延迟 = 2 周期，与 `vmul.vv`/`vmacc.vv` 完全相同。**

### 2.6 `VDotTop`（YunSuan 侧 L1 顶层，新建 150 行）

`VIMacU` 依赖 `xiangshan.backend.fu.vector` 包的 `ByteMaskTailGen` / `Mgu`，YunSuan 独立测试平台看不见它们。
因此为 L1 验证新建了 `VDotTop`：**算术通路与 `VIMacU` 完全相同**（同样的 2 片 `VIMac64b` + `prod16` 抽头 + 同一个 `VDotTree` + 同样的 `accOperand` 选择 + 同样的 latency=2），**只有掩码/尾部成形**改为按 `vdot_ref.c` 的行为表直接实现：

```scala
// 归约：active(i) = (vstart <= i < vl) && (vm || v0.mask[i])
// 写回：vstart>=vl -> oldVd；否则 [31:0]=dotVd[31:0]，[127:32] 按 vta 取全 1 / oldVd
// vdot4a：逐 32 位元素的 prestart / tail / inactive / active 四分支
```

这一处双实现是本次交付的已知局限，详见 §10 第 1 条。

### 2.7 译码链路（C1–C5）

| 项 | 文件 | 内容 |
|---|---|---|
| C1 | `decode/Instructions.scala` | 新增 `object Xsvdot`，三条 `BitPat("b1110xx???????????000?????1010111")` |
| C2 | `decode/VecDecoder.scala` | `opivv` 表三行 `-> OPIVV(FuType.vimac, VimacType.vdotXxx, T, F, F)`；`uopSplitType` 用默认 `VEC_VVV`（LMUL=1 ⇒ `numOfUop = 1`，`csBundle(0)` 给出 `lsrc(0)=vs1 / lsrc(1)=vs2 / lsrc(2)=vd / ldest=vd`）；OPIVV 的 `src3` 默认就是 `SrcType.vp`，三源读取零成本 |
| C3 | `decode/DecodeUnit.scala` | 三条指令登记进 `vmaInsts`，使 `vpu.isDependOldVd = 1`。不登记的话 `NewDispatch` 会在 `vlIsVlmax && (vm\|\|vma) && !isWritePartVd` 时丢弃对旧 `vd` 的依赖，`vdotacc`/`vdot4a` 的累加器与 `vdot` 的 tail-undisturbed 都会读到不可信值 |
| C4 | `decode/VecExceptionGen.scala` | ① 新增 `dotRedInst`/`dot4aInst`；② `eewIllegal` 增加 `dotEewIllegal = dotRedInst && SEW=/=0 \|\| dot4aInst && SEW=/=2`；③ `vdIsSingleElem` 加 `dotRedInst`（`vdot4a` **不加**）；④ `vdEew` 对三条指令取 `2.U`(e32)。`vs1IsSingleElem` **刻意不加**（裁定 R-15：`vdot` 的 `vs1` 是完整向量操作数，不是标量种子）。`vstartIllegal` **保持不动** —— 现有 `isVArith && vstart =/= 0` 恰好实现裁定 S-1（R-05） |
| C5 | — | 确认三条指令在 LMUL=1 下均为单 uop，`UopSplitType`/`UopInfoGen`/`DecodeUnitComp` **零改动** |

### 2.8 Verilog 出口（A5 + 新增）

| 入口 | 位置 | 产物 |
|---|---|---|
| `yunsuan.vector.mac.VerilogVDotTree` | `VDotTree.scala` 末尾（照抄 `VerilogVIMac`） | `VDotTree.sv` |
| `yunsuan.vector.mac.VerilogVDotTop` | `VDotTop.scala` 末尾 | `VDotTop.sv` |
| `xiangshan.backend.fu.VIMacUMain` | `src/test/scala/xiangshan/backend/fu/VIMacUTest.scala`（照抄既有 `xiangshan.DecodeMain`） | `VIMacU.v` |

`VIMacUMain` 不走 `top.ArgParser`，所以要自己补 `LogUtilsOptionsKey` / `PerfCounterOptionsKey`
（平时由 `ArgParser.scala:271-284` 的 `.alter` 注入），否则精化报 `Key LogUtilsOptionsKey is not defined`。

---

## 3. 改动文件清单（行数）

> **本节三张表的每一个数字都由 `git apply --numstat <补丁>` 实测得到**，不是人工统计。
> 复算方法（在仓库根目录执行，不写入任何工作树）：
>
> ```bash
> git apply --numstat rtl/patch/0002-yunsuan-vdot.patch        # 表 3.1
> git apply --numstat rtl/patch/0001-xiangshan-vdot.patch      # 表 3.2
> git apply --numstat tests/unit/yunsuan_vdot_testbench.patch  # 表 3.3
> ```
>
> 输出的三列依次是「新增行数 / 删除行数 / 文件路径」。表中「改动」列写成 `+增 / −删`；
> 新建文件只有新增行，其行数即该文件的总行数（与 `rtl/chisel/MANIFEST.md` 的行数列一致）。

### 3.1 `rtl/patch/0002-yunsuan-vdot.patch`（YunSuan RTL）

| 文件 | 改动 | 说明 |
|---|---|---|
| `src/main/scala/yunsuan/encoding/Opcode/VimacOpcode.scala` | +4 / −0 | `vdot` opcode + `isVdot` |
| `src/main/scala/yunsuan/package.scala` | +17 / −0 | `VimacType.vdot/vdotacc/vdot4a` + 5 个判定 |
| `src/main/scala/yunsuan/vector/vectorIMAC/VIMac64b.scala` | +7 / −0 | `prod16` 只读抽头 |
| `src/main/scala/yunsuan/vector/vectorIMAC/VDotTree.scala` | **新建 161 行** | 可重构蝶形折叠加法树 + Verilog 出口 |
| `src/main/scala/yunsuan/vector/vectorIMAC/VDotTop.scala` | **新建 150 行** | L1 平台用的 FU 顶层 + Verilog 出口 |
| **小计** | 3 文件改动 **+28 / −0**，2 文件新建 **311 行** —— 全补丁合计 **339 插入 / 0 删除** | |

### 3.2 `rtl/patch/0001-xiangshan-vdot.patch`（XiangShan）

| 文件 | 改动 | 说明 |
|---|---|---|
| `src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala` | +84 / −9 | 类型生成、掩码生成、树例化、累加选择、RedTailGen、输出复用 |
| `src/main/scala/xiangshan/backend/decode/VecExceptionGen.scala` | +34 / −4 | SEW 判定、**LMUL 判定（P4 阶段补）**、`vdIsSingleElem`、`vdEew` |
| `src/main/scala/xiangshan/backend/decode/Instructions.scala` | +11 / −0 | `object Xsvdot` |
| `src/main/scala/xiangshan/backend/decode/VecDecoder.scala` | +9 / −0 | `opivv` 三行 |
| `src/main/scala/xiangshan/backend/decode/DecodeUnit.scala` | +5 / −0 | `vmaInsts` |
| `src/test/scala/xiangshan/backend/fu/VIMacUTest.scala` | **新建 49 行** | `VIMacUMain` 精化/Verilog 出口 |
| `src/test/scala/xiangshan/backend/fu/VIMacUHarness.scala` | **新建 164 行**（P4 阶段补） | `VIMacU` 直驱验证用的窄 IO 包装 + Verilog 出口 |
| `src/test/scala/xiangshan/backend/decode/VecExceptionGenTest.scala` | **新建 89 行**（P4 阶段补） | `VecExceptionGen` 定向测试用的窄 IO 包装 + Verilog 出口 |
| **小计** | 5 文件改动 **+143 / −13**（5+11+9+34+84 = 143，0+0+0+4+9 = 13），3 文件新建 **302 行**（49+164+89）—— 全补丁合计 **445 插入 / 13 删除** | |

> **P4 阶段的后续改动**：`VecExceptionGen.scala` 增加了 `dotEmulIllegal`（拦截 `vlmul != 0`，
> 见下方 §10 第 8 条的更新），并新增两个测试入口。`rtl/patch/0001-xiangshan-vdot.patch`
> 已随之重新生成并实测可干净应用（`scripts/tools/verify_patches.sh`）。

**未改动**（与设计文档 §5.1 第 15 项一致）：`FuConfig.scala`、`FuType.scala`、`Parameters.scala`、Dispatch、IssueQueue、WbArbiter、`UopInfoGen.scala`、`DecodeUnitComp.scala`、`xiangshan/package.scala`、`Mgu.scala`、`ByteMaskTailGen.scala`、`VecDataSplitModule.scala`、`VecPipedFuncUnit.scala`、`FuncUnit.scala`。

### 3.3 `tests/unit/yunsuan_vdot_testbench.patch`（L1 测试平台）

| 文件 | 改动 | 说明 |
|---|---|---|
| `src/test/scala/top/VectorSimTop.scala` | +41 / −3 | `VDOT_latency`、`VPUTestFuType.vdot`、`unknown()` 阈值、延迟表、`VDotTop` 例化与连线、结果仲裁表 |
| `src/test/csrc/include/vpu_constant.h` | +13 / −2 | `VDot (10)`、`ALL_FUTYPES`、`VDOT_*_OPTYPES` |
| `src/test/csrc/include/gm_common.h` | +10 / −0 | `class VGMDot` |
| `src/test/csrc/include/test_driver.h` | +14 / −0 | `VGMDot vdot;` + 定向语料回放成员 |
| `src/test/csrc/test_driver.cpp` | +127 / −2 | `gen_random_optype` / **`gen_random_sew`** / `gen_random_vecinfo` / `get_expected_output` / `YS_VDOT_VECTORS` 语料回放；**另含 `YS_FUTYPE`/`YS_FUOPTYPE` 环境变量选择（原 `yunsuan_testdriver_env_select.patch` 的内容）** |
| `src/test/csrc/golden_model/vector_dot.cpp` | **新建 102 行** | 薄壳参考模型，`#include "vdot_ref.c"` |
| **小计** | 5 文件改动 **+205 / −7**（41+13+10+14+127 = 205，3+2+0+0+2 = 7），1 文件新建 **102 行** —— 全补丁合计 **307 插入 / 7 删除** | |

> **两个补丁不要重复应用**：`yunsuan_vdot_testbench.patch` 是对 pristine `yunsuan@9559211` 的完整 diff，
> 已经包含 `yunsuan_testdriver_env_select.patch` 的全部内容。

---

## 4. L1 测试平台接入（§9 的 6 处改动）

按 `docs/stage1/03_仿真平台搭建报告.md` §9 的清单逐条落实：

| # | 要求 | 落实 |
|---|---|---|
| 1 | 实现 FU 本体 | `VDotTop`（复用 `VIMac64b` 乘法阵列 + 新建 `VDotTree`） |
| 2 | 登记 fuType + 放宽 `unknown()` | `VPUTestFuType.vdot = "b0000_1010"`；`unknown(typ) = typ > 10.U` |
| 3 | 接进 SimTop | `VSPParameter.VDOT_latency = 2`；延迟查找表加 `vdot -> VDOT_latency.U`；例化 `VDotTop` 并连线；结果仲裁表加 `vdot -> vdot_result` |
| 4 | 登记 C 常量 | `#define VDot (10)`；加进 `ALL_FUTYPES`（`FU_NUM` 8→9）；`VDOT_NUM / VDOT_VV / VDOTACC_VV / VDOT4A_VV / VDOT_ALL_OPTYPES` |
| 5 | 写 golden model | `golden_model/vector_dot.cpp` + `gm_common.h` 的 `class VGMDot`。**直接 `#include "vdot_ref.c"`，没有重写任何语义** |
| 6 | 接进 TestDriver | `test_driver.h` 加 `VGMDot vdot;`；`get_expected_output()` 加 `case VDot`；`gen_random_optype()` 加 `case VDot`；**`gen_random_sew()` 加 `case VDot`**；`gen_random_vecinfo()` 固定 `vlmul=0` 并把 `vl` 的随机范围放宽到 `[0, vlmax]` |

### 4.1 `gen_random_sew()` —— 已实测确认的坑

上游 `gen_random_sew()` 的 `default` 分支是 `return (rand()%3)+1`，**取值范围 1..3，永远取不到 0（e8）**。
不加 `case VDot` 的话 `vdot.vv`（要求 SEW=8）一条都不会被生成。本实现：

```cpp
case VDot: return (input.fuOpType == VDOT4A_VV) ? 2 : 0; break;
```

可行性依据：`get_random_input()` 的非 cvt 分支里 `gen_random_optype()` 在 `gen_random_sew()` **之前**调用
（`test_driver.cpp:513-515`），所以 `gen_random_sew` 可以安全地依赖 `input.fuOpType`。

### 4.2 参考模型如何保证「不重写语义」

`scripts/11_build_vdot_sim.sh` 在构建前把 `tests/golden/vdot_ref.{c,h}` 复制进
`yunsuan/src/test/csrc/golden_model/`，`vector_dot.cpp` 用
```cpp
#include "vdot_ref.c"        /* 语义唯一事实来源，严禁在此重写 */
```
把它整体编译进同一个翻译单元。`vector_dot.cpp` 里只剩三件事：
① `VecInput.srcN[2]` ↔ `vreg128_t.v[16]` 的逐字节搬运（不依赖宿主字节序）；
② 平台紧凑 fuOpType（0/1/2）→ `enum vdot_op`；
③ 调 `vdot_exec(...)` 并把 `vd` 搬回 `VecOutput.result`。

`vdot_ref.c`/`.h` 被构建脚本同步、不进补丁，避免同一份代码在仓库里出现两份可能走样的拷贝。

### 4.3 fuOpType 位宽的权宜

仿真顶层 `VSTInputIO.fuOpType` 只有 **8 位**，装不下 9 位的 `VimacType` 编码（`vdot` = 0x0E7 还能装，`vdotacc` = 0x177 / `vdot4a` = 0x1F7 装不下）。
因此 C++ 侧用紧凑编号 0/1/2 选择指令，由 `VectorSimTop.scala` 翻译成真正的 `VimacType` 常量：

```scala
vdot.io.fuOpType := LookupTreeDefault(opcode, VimacType.vdot, List(
  0.U -> VimacType.vdot, 1.U -> VimacType.vdotacc, 2.U -> VimacType.vdot4a))
```

这只影响测试平台，不影响 XiangShan 侧（那里 `FuOpTypeWidth = 9`，完整携带 pad 位）。
编号顺序与 `enum vdot_op` 一致，便于语料文件与平台互通。

### 4.4 新增能力：定向语料回放

为了让 P4 的完整语料能直接跑在 L1 平台上，`TestDriver` 新增环境变量 `YS_VDOT_VECTORS`：

```bash
YS_VDOT_VECTORS=tests/vectors/positive.txt ./build/emu -O 40
```

它按 `docs/stage2/13` §3.1 的字段格式逐行解析，**只取输入字段**（`op vsew vstart vl vm vta vma vs1 vs2 vd_in … v0`），
期望值仍由 golden model 现场计算 —— 这样 RTL 与语料文件互为交叉校验。
`status != OK` 的用例（归约类 `vstart!=0` 的 `ILLEGAL_VSTART`）在 FU 级平台无法建模异常，加载时跳过并打印条数。
启动时会打印 `run with -O <N>`，照这个 N 跑即可让每条用例恰好执行一次。

---

## 5. 如何重建与复跑

```bash
cd <仓库根>
source scripts/env_host.sh                       # 必须：pin openjdk@17（JDK 25 不行）

# ---- L0：两个 mill 工程编译 + Verilog 生成 ----
cd work/XiangShan-vdot/yunsuan && mill -i YunSuan.compile                 # mill 0.11.1
cd <仓库根>/work/XiangShan-vdot && mill -i xiangshan.compile   # mill 0.12.3

cd work/XiangShan-vdot/yunsuan
mill -i YunSuan.runMain yunsuan.vector.mac.VerilogVDotTree     # -> build/vdot/VDotTree.sv
mill -i YunSuan.runMain yunsuan.vector.mac.VerilogVDotTop      # -> build/vdot/VDotTop.sv
mill -i YunSuan.runMain yunsuan.vector.mac.VerilogVIMac        # -> build/vimac/VIMac.sv

cd <仓库根>/work/XiangShan-vdot
mill -i -D jvm-xmx=8G xiangshan.test.runMain xiangshan.backend.fu.VIMacUMain \
     --target-dir build/vdot --target verilog                  # -> build/vdot/VIMacU.v
mill -i -D jvm-xmx=8G xiangshan.test.runMain xiangshan.DecodeMain \
     --target-dir build/vdot --target verilog                  # -> build/vdot/DecodeUnit.v

# ---- L1：构建仿真器并跑冒烟测试 ----
cd <仓库根>
bash scripts/11_build_vdot_sim.sh                 # 构建 + 冒烟（日志 logs/stage2/p4_smoke_test.log）
OPS=20000 bash scripts/11_build_vdot_sim.sh       # 加大随机条数
WAVE=1 bash scripts/11_build_vdot_sim.sh          # 带波形重建并抓一段 vdot.vv

# ---- 手工定向驱动 ----
cd work/XiangShan-vdot/yunsuan
YS_FUTYPE=10 YS_FUOPTYPE=0 ./build/emu -O 10000           # 只跑 vdot.vv
YS_FUTYPE=10 YS_FUOPTYPE=1 ./build/emu -O 10000           # 只跑 vdotacc.vv
YS_FUTYPE=10 YS_FUOPTYPE=2 ./build/emu -O 10000           # 只跑 vdot4a.vv
YS_FUTYPE=10                ./build/emu -O 30000          # 三条混合
YS_VDOT_VECTORS=../../../tests/vectors/random.txt ./build/emu -O 10000    # 回放随机语料
YS_FUTYPE=10 ./build/emu --dump-wave -b 0 -e 200 -O 6 -s 1                # 抓波形（需 EMU_TRACE=1 构建）
```

### 应用补丁到干净的上游

```bash
git clone -b kunminghu-v2 <XiangShan>  && cd XiangShan && git checkout a4eeaab
git submodule update --init --recursive
git apply /path/to/rtl/patch/0001-xiangshan-vdot.patch
cd yunsuan && git checkout 9559211
git apply /path/to/rtl/patch/0002-yunsuan-vdot.patch
git apply /path/to/tests/unit/yunsuan_vdot_testbench.patch   # 需要 L1 测试平台时才打
cp /path/to/tests/golden/vdot_ref.{c,h} src/test/csrc/golden_model/
```

---

## 6. 验证证据

| 层级 | 内容 | 结果 | 日志 |
|---|---|---|---|
| L0 | `mill -i YunSuan.compile`（clean 后完整编译 82 源文件） | exit=0 | `logs/stage2/p4_rtl_build.log` |
| L0 | `mill -i xiangshan.compile`（clean 后完整编译 382 源文件，77 s） | exit=0 | 同上 |
| L0 | `mill -i xiangshan.test.compile`（21 源文件，含 `VIMacUMain`） | exit=0 | 同上 |
| L0 | `VDotTree.sv` / `VDotTop.sv` / `VIMac.sv` / `VIMacU.v` / `DecodeUnit.v` 生成 | 全部 exit=0 | `logs/stage2/p4_verilog_emit.log` |
| L1 | `vdot.vv` 20000 条随机（SEW=8） | `EMU EXCEEDED LIMIT`，Operations:20000 | `logs/stage2/p4_smoke_test.log` |
| L1 | `vdotacc.vv` 20000 条随机（SEW=8） | `EMU EXCEEDED LIMIT`，Operations:20000 | 同上 |
| L1 | `vdot4a.vv` 20000 条随机（SEW=32） | `EMU EXCEEDED LIMIT`，Operations:20000 | 同上 |
| L1 | 三条指令混合 20000 条随机 | `EMU EXCEEDED LIMIT`，Operations:20000 | 同上 |
| L1 | 定向语料 `positive.txt` 40 条 / `negative.txt` 44 条 / `boundary.txt` 94 条（跳过 9 条 `ILLEGAL_VSTART`） | 全部 `EMU EXCEEDED LIMIT` | 同上 |
| L1 | 既有 FU 回归 `VIAluFWrapper` 2000 条 | `EMU EXCEEDED LIMIT` | 同上 |
| L1 | 波形（`vdot.vv`，含 `vdotTree` 层次） | 1.2 MB VCD，37161 行 | `logs/stage2/waveform/vdotvv_vdottop_fuType10_seed1.vcd` |
| 自测 | 故障注入（`io.dotVd ^ 1`） | `EMU BADTRAP`，还原后恢复 PASS | `logs/stage2/p4_fault_inject.log` |

> `EMU EXCEEDED LIMIT` 的含义是「跑满指定条数且每一条都与 golden model 逐位一致」；
> 出现失配会打印 `EMU BADTRAP` 并 dump REF/DUT 数值。判读依据见 `emu.cpp:208-210`。

---

## 7. 对既有逻辑的影响评估

### 7.1 生成 Verilog 的逐位比对（`vmul` / `vmacc` / `vsmul` 零回退的硬证据）

`prod16` 是纯新增的只读端口，`VIMac64b` 内部逻辑一行未改。把重新生成的 `VIMac.sv` 与阶段一存档的基线对比：

```
$ diff <(sed -E 's@//.*@@; s/[[:space:]]+$//' rtl/verilog/baseline/VIMac.sv) \
       <(sed -E 's@//.*@@; s/[[:space:]]+$//' rtl/verilog/vdot/VIMac.sv) | wc -l
0
```

**去掉源码行号注释后差异为 0 行**（唯一的差异就是注释里的行号，因为 `VIMac64b.scala` 插入了 7 行）。
`VIMac` 顶层没有例化 `VDotTree`，悬空的 `prod16` 被 firtool 常量传播消除，输出网表与基线完全一致。

### 7.2 L1 回归

`VIAluFWrapper`（fuType=5）2000 条随机测试在改动后仍然 PASS（`p4_smoke_test.log` 的 (f) 段），
`ALL_FUTYPES` 混合随机通道也把 `VDot` 纳入后整体通过。

### 7.3 没有碰的公共判据

- `VecExceptionGen.scala:305` 的 `vstartIllegal = isVArith && (vstart =/= 0)` **未改动**（裁定 R-05/R-06）。
- `VimacOpcode` 的 5 个 `isXxx` 判定 **未改动**。
- `FuConfig.VimacCfg.latency = CertainLatency(2)` **未改动**，唤醒/写回时序不变。

---

## 8. 扩展性

`VDotTree` 已按 `class VDotTree(numProd, prodWidth, accWidth)` 参数化，派生出 `numLane / numFold / numFoldS1 / foldSelWidth`：

| 场景 | 改动 | 结构变化 |
|---|---|---|
| VLEN=256 | `numProd = 32` | `numLane=8`，`numFold=3`（S1 放 1 级、S2 放 2 级），寄存器 8×2×32 = 512 bit |
| VLEN=512 | `numProd = 64` | `numLane=16`，`numFold=4`（S1/S2 各 2 级） |
| SEW=16 源元素 | `prodWidth = 32, accWidth = 64` | 位宽参数化即可，折叠结构不变 |
| 8 路分组 `vdot8a` | 复用现有硬件 | `foldLevels = 1` 这个取值已经可用（§2.4 的表） |

`numFoldS1 = numFold / 2` 的切分规则使 S1/S2 的折叠级数自动均衡，流水切点随 VLEN 自适应。
LMUL>1 的方案（新增 `UopSplitType.VEC_VDOT`）见设计文档 §8.3，**本版本不交付**（裁定 S-6）。

---

## 9. 设计偏离记录

严格按设计文档 §6 集成点清单施工。以下是与文档**不完全一致**的地方，逐条说明理由。
除第 1 条外，其余均为「更保守/更完整」方向的偏离，没有削弱任何语义。

| # | 集成项 | 设计文档写法 | 实际实现 | 理由 |
|---|---|---|---|---|
| 1 | A6（可选） | 「若希望 YunSuan 独立测试平台也能测顶层，在 `VIMac.scala` 的 `vIMac64bs` 循环之后例化 `VDotTree`」 | **没有改 `VIMac.scala`**，而是**新建了独立的 `VDotTop.scala`**（150 行） | ① 改 `VIMac` 会改变既有顶层的网表，§7.1 的「生成 Verilog 逐位相同」这条零回退证据就没了；② `VIMac` 的 tail/mask 逻辑（`TailGen`/`MaskReorg`，`VIMac.scala:58-87`）是按 `eewVd` 逐元素的模型，表达不了归约类「只写元素 0」，硬塞进去要改既有逻辑；③ 独立模块让 L1 的 DUT 边界与 `VIMacU` 的算术通路一一对应，更容易比对。**代价见 §10 第 1 条** |
| 2 | §4.6 `RedTailGen` | 「`Mux(outVl === 0.U, outOldVd, …)`，S-1 保证 `vstart>=vl` 退化为 `vl==0`」 | 实现为 `Mux(outVstart >= outVl, outOldVd, …)` | 与参考模型 `vdot_ref.c:94` 的 `if (vstart >= vl) return;` 逐字对应。在 XiangShan 上 `vstart` 架构上恒为 0，两者等价；在 L1 平台 `vstart` 是可自由驱动的输入端口，用完整判据才能与参考模型对齐。代价是一个 8 位比较器 |
| 3 | §4.5 掩码 | 只描述了归约形态的 `ByteMaskTailGen` 接线 | 额外加了 `dotActiveEn = Mux(isDot4a, ~0.U(16.W), …)` | 文档没写 `vdot4a` 的 activeEn 取值。`vdot4a` 的掩码粒度是 32 位目的元素、由 `Mgu` 处理，若复用 SEW=8 的 activeEn 会把乘积错误地按源元素掩掉。全 1 是唯一正确取值 |
| 4 | §4.4.3 / §8.1 | 「建议在 P3 实现冗余 lane 门控与 `prod` 输入端操作数门控」 | **未实现** | 纯功耗优化，不影响功能，且会给 S1 增加 1 级 AND。本机没有功耗分析工具（D3 分层验证），做了也无法量化收益。留给 P7 综合后按实测决定，已登记在 §10 |
| 5 | §6 D1/D3 | 「新建 `VDotSpec.scala` chiseltest 用例」「`DecodeTest.scala` 新增译码断言」 | **未实现**（改为 L1 Verilator 差分 + 语料回放） | 上游 chiseltest 6.0.0 在本机不可用：它生成的 C++ 用 `WData`，而 Verilator 5.052 已移除该类型（`docs/stage1/03_仿真平台搭建报告.md` §8.1 已记录，`make test` 本就不通过）。L1 平台（Verilator + C++ golden model）覆盖面更广（已跑 80000 随机 + 178 定向），是等价且更强的替代 |
| 6 | §6 A5 | 只要求 `VerilogVDotTree` | 额外加了 `VerilogVDotTop` 与 `xiangshan.backend.fu.VIMacUMain` | 前者是 L1 DUT 的顶层，后者让 XiangShan 侧的 vdot 改动能真正**精化**（而不只是通过 Scala 类型检查）并产出可读 Verilog，直接支撑 P3 验收标准第 1、2 条 |
| 7 | §9 测试平台 | 只要求随机激励 | 额外实现了 `YS_VDOT_VECTORS` 定向语料回放 | P4 的共享语料（当时 30663 条，S-7' 后 30703 条）需要能直接喂给 RTL；没有这个通道，定向用例只能手写 hex，既易错又无法与 `tests/vectors/` 对齐 |
| 8 | §6 C2 | `uopSplitType` 用默认 `VEC_VVV` | 一致，但**`vl` 随机范围在 L1 驱动里放宽到 `[0, vlmax]`** | 上游 `gen_random_vecinfo` 用 `rand()%vlmax + 1`，永远取不到 `vl=0`。裁定 S-5 对 `vl=0` 有明确规定（连 tail 都不写），参考模型和 RTL 都实现了，应该测到 |

**没有发现设计文档的错误。** §6 的集成点清单可以逐条施工，§4.2 的抽头点正确性证明、§4.4 的蝶形折叠正确性、§3.6.3 的流水切分方案 B 在实现中全部成立，一次通过（首次 L1 随机测试即 PASS，无需调试数据通路）。

---

## 10. 局限性

1. ~~**掩码/尾部成形在两处分别实现**~~ —— **已在 P4 阶段关闭**。
   原问题：`VIMacU`（XiangShan 侧）用 `ByteMaskTailGen` + `Mgu` + `RedTailGen`；`VDotTop`（YunSuan 侧，L1 用）用手写的等价逻辑，L1 验证的只是 `VDotTop` 这一侧，「被验证的东西不等于被集成的东西」。
   P4 的做法：新增 `VIMacUHarness`（只做连线的窄 IO 包装，`VIMacU.scala` 一行未改）+ `tests/unit/vimacu_tb.cpp`，把同一批共享语料**直接灌进 `VIMacU` 本体**，实测 **26024 条执行、0 失配**（裁定 S-7' 传播后重跑；修订前为 27529 条：1545 条 `vdot4a` + `vstart != 0` 用例转为非法、不再投放，另有 `vstart_relaxed.txt` 补入的 40 条 vdot4a 用例，27529 − 1545 + 40 = 26024，见第 3 条）；并核对两条路径共享的 `VDotTree` / `CSA4to2` / `CSA3to2` / `ByteMaskTailGen` 网表**逐字节相同**。详见 `docs/stage2/12_基础功能测试报告.md` §8 与 `logs/stage2/p5_vimacu_equiv.log`。
   **剩余**：全核 difftest 仍未执行（见第 2 条）。**后续更新**：阶段三已补做（`docs/stage3/23_全核difftest验证报告.md`）。

2. **全核层面未验证**。`mill xiangshan.runMain top.TopMain`（全 SoC 精化）与 `make emu`（全核 Verilator）在本机 16 GB 内存下不可行（官方要求 `-Xmx40G`，见 `docs/stage1/03_仿真平台搭建报告.md` §7.1、`MASTER_PLAN.md` D3）。因此：
   - 译码 → uop 拆分 → 发射 → `VIMacU` → 写回的**全链路未在真实流水线上跑过**；
   - 已验证到的最强层级是：`DecodeUnit` 与 `VIMacU` 各自**单独精化成 Verilog 成功**（证明译码表无冲突、FU 可综合），加上 L1 对算术通路的逐位差分。
   - 全链路验证留给 P6（NEMU↔RTL 协同仿真）与可能的全核 difftest。
   - **后续更新**：全核 difftest 已在阶段三补做（`docs/stage3/23_全核difftest验证报告.md`，MinimalConfig）：本补丁下的全核 emu 构建成功，译码 → 发射 → `VIMacU` → 写回 → 提交的全链路在真实流水线上跑通，24,517,314 条提交与 NEMU 0 失配；`rtl/patch/` 未因此改动。默认配置未运行，LMUL≠1 未在全核复测。

3. ~~**`vdot4a.vv` 的 `vstart != 0` 在全核上不可达**~~ —— **已由裁定 S-7' 消解，现为规范行为**（`MASTER_PLAN.md` D2.3）。
   原文：「`VecExceptionGen.scala:305` 的 `vstartIllegal` 对所有 `isVArith` 指令在 `vstart!=0` 时报非法，而裁定 S-7 要求 `vdot4a` 的 `vstart` 正常生效 …… 该路径只能在 L1 验证」。
   P6 协同仿真证明这不是一处无害的「不可达」，而是 NEMU（按 S-7 正常执行）与香山（判非法）之间 1946 条确定性的判定分歧（`docs/stage3/21_协同仿真验证报告.md` §7.3）。按**平台约束优先原则**修订为 **S-7'**：`vdot4a.vv` 在 `vstart != 0` 时**同样抛出 Illegal Instruction**，与 `vdot.vv` / `vdotacc.vv`（S-1）一致。
   **RTL 一行未改**：上游原有的 `VecExceptionGen.scala:305` `vstartIllegal = isVArith && (io.vstart =/= 0.U)` 本就覆盖 `vdot4a`（`FuType.vimac` 属于 `isVArith`），S-7' 只需要参考模型、语料与 NEMU 向它收敛。译码级定向测试 `tests/unit/vecexcgen_tb.cpp` 的 `[I]` 组实测确认：`vdot4a` 在 `vstart = 1/2/3` 时判非法、`vstart = 0` 时判合法（`logs/stage2/p5_decode_illegal.log:87-94`）。
   随之变化的测试口径：规范语料里原有的 1545 条 `vdot4a` + `vstart != 0` 用例（`vdot4a_boundary.txt` 6 条 + `vdot4a_random.txt` 1539 条）改标为 `ILLEGAL_VSTART`，在 FU 级平台上按「架构非法」跳过；数据通路本身的 prestart 门控（`VDotTop` 的 prestart 分支、`VIMacU` 经 `Mgu.info.vstart`）仍然正确实现，由非规范语料 `vstart_relaxed.txt`（130 条，其中 S-7' 时补入 40 条 vdot4a）继续在 L1 激励，以备在支持 `vstart` 重启的实现上放宽回 S-7。详见 12 号报告 §5.3 与 §12 第 3 条。

4. **归约类 `vstart != 0` 在 L1 走的是 SKIP 策略**。FU 级平台不建模异常，RTL 的归约数据通路（`activeEn` 的 `begin = vstart`）天然实现 §5.4 的 prestart 跳过。架构层的 STRICT 行为（S-1：抛 Illegal Instruction）由 `VecExceptionGen` 在译码阶段实现，不在 L1 验证。`vector_dot.cpp` 因此用 `VDOT_VSTART_SKIP` 调参考模型；语料文件里 `status != OK` 的用例被自动跳过（`boundary.txt` 跳过 9 条）。

5. **时序是估算，不是综合结果**。设计文档 §3.6 的逻辑级数估算（S1 ≈ 24 级、S2 ≈ 21 级）**本阶段没有也无法验证**——本机没有综合工具与工艺库。`latency = 2` 的可行性目前只有「结构上与 SEW=64 工况同量级」这一静态论证支撑。风险登记 R-TIMING 仍然有效，保底方案 C（`latency = 3`）的切换成本是 1 行 `FuConfig` + 1 级寄存器。P7 必须回填真实数据。

6. **面积/功耗未量化**。设计文档（`10_vdot指令设计文档.md`）§5.3 的 13.7% 新增逻辑占比是「全加器等价」结构计数，不是面积报告。`VDotTree.sv` 有 419 行 Verilog、`VDotTop.sv` 1444 行、`VIMacU.v` 4876 行，可作为规模的粗略参照，但不能当面积结论。

7. **未实现的优化**：冗余 lane 操作数门控、非 vdot 指令执行时对 `VDotTree.prod` 输入端的门控（设计文档 §8.1）。两者都是纯功耗项。

8. **LMUL > 1 不支持**（裁定 S-6）—— **拦截缺口已在 P4 阶段修复**。
   本版本 `uopSplitType` 用 `VEC_VVV`，LMUL>1 时 `numOfUop = lmul`，但 `vdot`/`vdotacc` 的多 uop 累加链语义没有实现，结果会是错的。原实现里 `VecExceptionGen` **不会**拦截 `vlmul != 0` 的 vdot 指令，会静默算错。
   P4 修复：`VecExceptionGen.scala:217` 新增
   `private val dotEmulIllegal = (dotRedInst || dot4aInst) && (io.vtype.vlmul =/= 0.U)`，并并入 `emulIllegal`（`:240`）。三条指令统一拦截，与 NEMU 侧 `vdot_check()` 的 `if (vtype->vlmul != 0) longjmp_exception(EX_II)` 保持一致。
   验证：新增 `VecExceptionGenHarness` + `tests/unit/vecexcgen_tb.cpp`，51 条定向用例全 PASS（日志 `logs/stage2/p5_decode_illegal.log`）；撤掉该守卫后 13 条立即变红（`PROVE_FAIL=1 bash scripts/tools/run_decode_tb.sh`，由 `scripts/20_run_func_tests.sh` 5.6 步自动执行，日志 `logs/stage2/p5_decode_prove_fail.log`）。
   **仍然不支持 LMUL>1 的正确执行**，只是从「静默算错」变成「明确报非法」。

9. **`.insn` 汇编宏未验证**。本机无 RISC-V 工具链，三条指令的机器码只由位域拼接算得（设计文档 §1.2 已标注 UNVERIFIED），P4/P5 需用 `objdump -d` 回读确认。

---

## 11. 波形证据的交付范围（`.gitignore` 决策）

`.gitignore` 第 8–10 行把 `*.vcd` / `*.fst` / `*.fsdb` **默认全部排除**（否则 `work/` 与
`**/build/` 下每次仿真产生的临时波形都会污染仓库）。此前只给 `logs/stage1/waveform/*.vcd`
开了例外，于是阶段二、阶段三的波形虽然被报告逐个数值引用，却进不了交付仓库
——评委拿到的仓库里没有这些文件，只能选择相信报告。本节记录对此作出的决策与理由。

### 11.1 决策

波形证据按三层交付，**三层都入库**：

| 层 | 内容 | 是否入库 | 作用 |
|---|---|---|---|
| ① 文本轨迹 | `logs/*/waveform/*_signal_trace.txt` | **是**（始终） | 可 `grep` / `diff` / 脚本比对的机读证据；报告里「某信号第 N 拍等于 X」靠它核对，不用开波形查看器 |
| ② 波形图 | `docs/stage1/figures/*.png`、`docs/stage3/figures/*.png` | **是**（始终） | 评委与答辩直接看的可视证据 |
| ③ 原始 VCD | `logs/stage1,2,3/waveform/*.vcd` | **是**（逐目录开例外） | ①② 的源头。有它，任何人都能用 GTKWave 或 `scripts/tools/vcd_extract.py` 自行复核 ①② 的每一个取值，而**不需要重建仿真器** |

入库的 VCD 共 **8 份、10.5 MB**（单份最大 1.85 MB）：

| 目录 | 份数 | 体积 | 被谁逐值引用 | 重新生成命令 |
|---|---:|---:|---|---|
| `logs/stage1/waveform/` | 2 | 2.7 MB | `docs/stage1/02_向量加法指令执行过程分析.md` §5/§6/§11.2（21 条波形证据 + 6 张图） | `WAVE=1 bash scripts/10_build_yunsuan_sim.sh` |
| `logs/stage2/waveform/` | 3 | 2.4 MB | `docs/stage2/12_基础功能测试报告.md` §10（12 个数值） | `bash scripts/tools/capture_vdot_waves.sh` |
| `logs/stage3/waveform/` | 3 | 5.4 MB | `docs/stage3/22_基线实现与延迟加速分析.md` §4.2（3×12 笔事务的延迟） | `bash scripts/40_run_bench.sh` |

判据只有两条，缺一不可：**(a) 有文档逐个数值引用它**；**(b) 单份 ≤ 2 MB**。
两条都满足才开例外，所以 `.gitignore` 里写的是**逐目录白名单**而不是放宽 `*.vcd` 本身
——构建树里的临时波形（`work/*/build/*.vcd`，每跑一次就多一份）仍然一律排除。

### 11.2 为什么不是「只留文本轨迹」

文本轨迹的可核对性其实强于截图（它是逐时刻的数值表），但它是**抽取结果**：
抽哪些信号、按什么时刻约定采样，都由 `vcd_extract.py` 的参数决定。
只交付抽取结果，等于要求评委相信抽取过程本身。把 10.5 MB 的源头一并交付，
证据链才从「报告 → 轨迹 → VCD」完整闭合，代价可以忽略。

### 11.3 为什么不是「全都不留，让评委自己跑」

三份波形的重新生成都要先重建带 `--trace` 的 Verilator 仿真器（`EMU_TRACE=1`），
在本机是分钟级、且依赖完整工具链。作为**证据**它必须随仓库走；
作为**可复现性**它仍然可重建 —— 上表第 5 列给出了每一份的原样重建命令，两者不矛盾。

### 11.4 仓库体积

交付仓库（不含 `.gitignore` 排除的 `work/` 与 `.git/`）实测 **62.6 MB**，其中波形相关
（8 份 VCD + 4 份文本轨迹 + 全部 PNG 图）合计 **12.4 MB**，远低于「几百 MB」的上限。
`*.fst` / `*.fsdb` 的例外是预留的（当前一份都没有）：若将来改用 FST 压缩格式，
同一套判据与目录白名单继续适用。

---

## 12. 给下一位同学（P4 测试工程师）

1. **一条命令起步**：`bash scripts/11_build_vdot_sim.sh`。它会同步参考模型、构建 emu、跑冒烟测试。`BUILD_ONLY=1` 只构建。
2. **跑完整语料**：
   ```bash
   cd work/XiangShan-vdot/yunsuan
   for f in positive negative boundary random vdotacc_* vdot4a_*; do
     VF=../../../tests/vectors/$f.txt
     N=$(awk '!/^#/ && NF>0 && $NF=="OK"' $VF | wc -l)
     YS_VDOT_VECTORS=$VF ./build/emu -O $N
   done
   ```
   每个文件启动时会打印 `run with -O <N>`，按它取 `-O` 才能保证每条用例恰好跑一次（否则会绕回重复执行）。
3. **`status != OK` 的用例会被跳过**并打印条数 —— 这些就是 P4 验收标准里「跳过项须说明原因与条数」要写的数字。目前只有 `boundary.txt` 有 9 条（归约类 `vstart!=0` → `ILLEGAL_VSTART`）。
4. **随机差分**：`YS_FUTYPE=10 ./build/emu -O 30000 -s <seed>` 即 30000 条三指令混合随机，期望值来自 `vdot_ref.c`。改 `-s` 换种子。
5. **故障注入**：`/tmp/faultinj.sh` 的做法已存档在 `logs/stage2/p4_fault_inject.log`，可照搬（改 `VDotTree.scala` 最后一行 → `make emu` → 跑 → 还原）。
6. **波形**：`WAVE=1 bash scripts/11_build_vdot_sim.sh`。注意切换 `WAVE` 必须重跑 verilator（脚本已自动 `rm -rf build/emu-compile`），且 trace 版 emu 必须带 `--dump-wave` 运行否则空指针崩溃。
7. **尚未覆盖、需要补的点**：`vdot4a.vv` 的 `vstart != 0`（prestart）路径（见 §10 第 3 条）；`vl = 0` 虽已纳入随机范围但定向用例更可靠；`vm=0` 且 `v0` 全 0 的 S-4 场景建议单独定向。
8. **不要**同时应用 `tests/unit/yunsuan_testdriver_env_select.patch` 和 `tests/unit/yunsuan_vdot_testbench.patch`，后者已包含前者。

> **P4 已完成情况**：上面第 7 条列出的三个待补点（`vdot4a` 的 `vstart != 0`、`vl = 0` 的定向用例、
> `vm=0` 且 `v0` 全 0 的 S-4 场景）均已覆盖并通过；另外关闭了 §10 第 1 条（VIMacU 直驱）与
> 第 8 条（LMUL 拦截）两个缺口。完整结果见 `docs/stage2/12_基础功能测试报告.md`，
> 一键复跑 `bash scripts/20_run_func_tests.sh`。
> 其后的裁定 S-7'（`MASTER_PLAN.md` D2.3）把 `vdot4a` 的 `vstart != 0` 改为非法，
> 上面第 3、7 条关于「`vdot4a` prestart 路径」的说法已按 §10 第 3 条更新：该路径现由非规范语料
> `vstart_relaxed.txt` 覆盖，规范语料中的对应用例改为 `ILLEGAL_VSTART`。
