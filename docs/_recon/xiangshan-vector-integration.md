# XiangShan 昆明湖 V2 向量单元 —— `vdot.vv` 集成侦察报告

- 侦察对象：`/Users/i3eg1nner/code/cie/work/XiangShan`，HEAD = `f85a1f7`（master）
- yunsuan 子模块固定在 `267ff736e7acd8e0fe8d13710581e4902a8a8a6c`（分支 `kunminghu-v3`，见 `git submodule status`）。
  侦察期间仓库内 `yunsuan/` 尚未 checkout 完成，本报告中所有 `yunsuan/...` 的行号引用来自同一 commit
  的独立只读克隆（`/tmp/yunsuan_recon`），路径与子模块落地后的
  `/Users/i3eg1nner/code/cie/work/XiangShan/yunsuan/...` 完全一致。
- 目标指令：`vdot.vv`，8-bit 整数点积，SEW=8 源 / 32-bit 目的元素，读 vs1、vs2、vd（第三源，累加），写 vd，VLEN=128。

> 术语约定：本文把 XiangShan 新向量区域（`backend/vector/`，内部类名 `Func` / `Exu` / `VecRegionModule`）
> 称为 **V2 区域**；把 `backend/fu/wrapper/` + `backend/fu/vector/Mgu.scala` 这一套老接口称为 **V1 区域**。
> 两套并存，且 **FU 基类不同**，这是本次集成最容易踩坑的地方。

---

## 0. 流水线全景（decode → writeback）

```
                       ┌──────────────────────── Decode 区 (纯组合 DecodeTable) ──────────────────────┐
 inst[31:0]            │                                                                              │
     │                 │  Instructions.scala  ──(Scala 反射)──►  InstPattern.all                       │
     │                 │        (BitPat)                              │                               │
     │                 │                                              ▼                               │
     └────────────────►│  VecArithInstPattern.apply()  ──► VecIntVVVVPattern with V2_* / V1_* /        │
                       │   (func6 / func3 / vm / vs1 分派)        V3_*_SrcDest / SL_*  (traits)        │
                       │                                              │                               │
                       │   SplitTable.table(instBP)(sew##lmul) ──► Seq[Opcode]  (每个 uop 一个 Opcode) │
                       │                                              │                               │
                       │   ┌──────────────┬──────────────┬────────────┴──────┬──────────────────┐     │
                       │   ▼              ▼              ▼                   ▼                  ▼     │
                       │ FuTypeField  OpcodeField   UopInfoField        NumUop/NumWb      Src1/Src2/   │
                       │ (→FuType)    (→funcOp)     (→rename info)       Illegal           DestSelect  │
                       │                                                                    │         │
                       │                                                 SrcSelectModule ◄──┘         │
                       │                                                 (lreg: rs1/rs2/rd + uopIdx)  │
                       └──────────────────────────────────┬───────────────────────────────────────────┘
                                                          │  LatDecoder(fuType, opcode) → latency
                                                          ▼
                                       Rename / Dispatch / ROB  (标量后端, 未改)
                                                          │
                       ┌──────────────────────────────────▼───────────────────────────────────────────┐
                       │                      VecRegionModule (backend/vector/)                        │
                       │                                                                              │
                       │  VecIssueQueue ──is0──► IssuePipe ──is1(读 vpRF/vlRF)──► is2 ──► ex0Next      │
                       │        │                   │                                     │           │
                       │        │ (写回槽位预约)    │  WbFuBusyTable (按 latency 预约)     │           │
                       │        └───────────────────┴─────────────────────────────────────┘           │
                       │                                                                              │
                       │                        ┌──────────── Exu (每个 ExuParam 一个) ───────────┐   │
                       │                        │  BypassNetwork → ex(0..latencyMax) 流水寄存器   │   │
                       │                        │        │                                        │   │
                       │                        │        ├─► Func #0  (VIAluWrapper)              │   │
                       │                        │        ├─► Func #1  (VIMacU)      ◄── vdot 插入 │   │
                       │                        │        ├─► Func #2  (VMove / VCVT / VFMac ...)  │   │
                       │                        │        │      每个 Func 输出 out.ex(i).data.vec │   │
                       │                        │        │        .normal / .narrow / .maskE*     │   │
                       │                        │        ▼                                        │   │
                       │                        │  MergeUnit[i]  (yunsuan.vector.v2.MergeUnit)    │   │
                       │                        │   vm/vma/vta/vl + oldVd → 字节级 active/agnostic│   │
                       │                        └──────────────────────┬─────────────────────────┘   │
                       │                                               ▼                              │
                       │                                  Exu.ToRf  (wen/pdest/data)                  │
                       │                                               │                              │
                       │                        WbDataPath(vp/v0/vl) ──┴──► wb0/wb1/wb2 → Regfile      │
                       └──────────────────────────────────────────────────────────────────────────────┘
```

---

## 1. 指令译码（Instruction decode）

### 1.1 比特模式的唯一真源

向量指令的 32 位 `BitPat` 全部声明在
`/Users/i3eg1nner/code/cie/work/XiangShan/src/main/scala/xiangshan/backend/decode/isa/Instructions.scala`：

- `:474` `def VADD_VV :BitPat = BitPat("b000000???????????000?????1010111")`
- `:648` `def VMACC_VV :BitPat = BitPat("b101101???????????010?????1010111")`
- `:854` `def VWMACC_VV :BitPat = BitPat("b111101???????????010?????1010111")`
- `:796` `def VSHA2CH_VV :BitPat = BitPat("b1011101??????????010?????1110111")`

这些 `def` 还必须被挂进一个 `InstType` 对象并进入 `allWithNames` 列表：

- `:1809 / :1955 / :2147 / :2186 / :2332 / :2524` —— `object VType extends InstType` 中的转发 `def` 与 `allWithNames`。
- `:3132-3142` —— `object ZVKNHAType extends InstType`，仅 3 条 `VSHA2{CH,CL,MS}_VV`。

> **关键机制（务必理解）**：`InstPattern.all`
> （`src/main/scala/xiangshan/backend/vector/Decoder/InstPattern/InstPattern.scala:490-510`）
> 通过 **Scala 反射** 扫描 `Instructions` 对象里所有 `def ...: BitPat`，再逐个喂给 `InstPattern(bitpat)`。
> 也就是说：**在 `Instructions.scala` 里加一个 `def` 就自动进入候选集**，不需要额外注册表；
> 但要真正被译码，还必须 (a) 属于某个 `InstType`，(b) 该 `InstType` 所属扩展在
> `Extensions.scala:162 def extensions` 列表里，(c) 该扩展在
> `DecodeChannels.scala:59 val vectorExts = extensions.intersect(Seq(V, Zvbb, Zvknha, Zacas, ZacasZabha))` 里。

扩展定义：`src/main/scala/xiangshan/backend/decode/isa/Extensions.scala`
- `:39 case object V extends UnprivExt(Seq(VType))`
- `:43 case object Zvknha extends UnprivExt(Seq(ZVKNHAType))`
- `:162-176 def extensions(implicit p: Parameters): Seq[ExtBase] = Seq(I, M, A, F, D, ... V, H, Zvknha, Zvbb, ...)`

### 1.2 bit pattern → 指令“形状” trait

`src/main/scala/xiangshan/backend/vector/Decoder/InstPattern/VecArithInstPattern.scala`
按 `opcode(6,0) → func3(14,12) → func6(31,26)` 三级 `match` 分派（`:9-12, :125, :270, :459, :554, :671, :762, :843-845`）。

`vmacc.vv` / `vmadd.vv` 在 **OPMVV**（不是 OPIVV）：

```
:421  case s"101001" => new VecIntVVVVPattern() with V2_VecNormal with V1_VecNormal with V3_VecNormal_SrcDest with SL_All // VMADD.VV
:425  case s"101101" => new VecIntVVVVPattern() with V2_VecNormal with V1_VecNormal with V3_VecNormal_SrcDest with SL_All // VMACC.VV
:453  case s"111101" => new VecIntVVWWPattern() with V2_VecNormal with V1_VecNormal with V3_VecWiden_SrcDest with SL_Widen // VWMACC.VV
```

对比 OPIVV 的普通三操作数（`:13-14`）：
```
:13   case s"000000" => new VecIntVVVPattern() with V2_VecNormal with V1_VecNormal with V3_VecNormal_DestOnly with SL_All // VADD.VV
```

- `VecIntVVVVPattern` = “读 vs1 / vs2 / vd，写 vd，宽度不变” —— **与 vdot 最接近的形状**（`:929`）。
- `VecIntVVWWPattern` = “读 vs1 / vs2 / vd(宽)，写 vd(宽)”，vwmacc 用（`:934`）。
- `V3_*_SrcDest` 这一族 trait 表示 vd 同时是源（`:1037-1044`）。
- `SL_All` / `SL_Widen` 控制合法的 (SEW, LMUL) 组合，实现在
  `DecodeFields/VecDecodeChannel/SewLmulRangeField.scala:22-37`：
  - `SL_All` → 全部 (sew, lmul)
  - `SL_Widen` → `sew <= 32 && lmul <= 4`
  - `SL_CryptBoth` → `sew == 32 && lmul >= 1 || sew == 64 && lmul >= 2`（Zvknh 用）

Crypto 指令走 opcode `1110111`（OP_VE）分支（`:843-895`），统一用 `VecCryptoVVVVPattern`，
顶层入口在 `InstPattern.scala:480 case OP_VE => VecCryptoVVVVPattern()`。

### 1.3 trait → 译码字段 → uop

译码表在 `Decoder/DecodeChannel/VectorDecodeChannel.scala`：
- `:108-126` `instDecodeFields`（只用指令位）
- `:129-133` `instSewDecodeFields` = `Src1SelectField, Src2SelectField, DestSelectField`
- `:135-152` `instSewLmulNfDecodeFields` = `UopInfoField×8, OpcodeField×8, FuTypeField×8, NumWbField, NumUopField, IllegalField, NumUopOhField, WritePartVdField, IsSegmentField, VRegTypesField`
- `:155-162` 三张 `DecodeTable` 以 `rawInst` / `rawInst##sew` / `rawInst##sew##lmul##nf` 为 key

所有 uop 相关字段的共同入口是
`DecodeFields/VecDecodeChannel/UopInfoField.scala:88-96`：
```scala
instP match {
  case _: VecArithInstPattern =>
    val instBP = instP.rawInst
    SplitTable.table(instBP)(sewP ## lmulP)   // ← 唯一的算术 uop 拆分真源
```
`FuTypeField`（`FuTypeField.scala:22-50`）、`OpcodeField`（`OpcodeField.scala:18-25`）、
`NumUopField`（`NumUopField.scala:20-24`）全部复用 `UopInfoFieldVec.genUopSeq(op)` 的返回长度/元素。

`FuTypeField.genFuType`（`FuTypeField.scala:54-91`）是 **Opcode 家族 → FuType 的唯一映射表**：
```scala
case _: Opcode.VIAluOpcodes.type   => FuType.vialu
case _: Opcode.VIMacOpcodes.type   => FuType.vimac
case _: Opcode.VSha256msOpcodes.type => FuType.vsha256ms
case _: Opcode.VSha256cOpcodes.type  => FuType.vsha256c
```
**这是个 exhaustive match，新增 Opcode 家族不在这里加 case 会在 elaborate 时抛 `MatchError`。**

### 1.4 全仓提到 `vmacc` / `vwmacc` 的文件清单（排除 vendored 的 `ChiselAIA/`）

| 文件 | 行 | 作用 |
|---|---|---|
| `src/main/scala/xiangshan/backend/decode/isa/Instructions.scala` | 648, 854, 1955, 2147, 2332, 2524 | BitPat 声明 + `VType` 注册 |
| `src/main/scala/xiangshan/backend/vector/Decoder/InstPattern/VecArithInstPattern.scala` | 425-428, 451-456, 806-808, 832-838 | func6 → Pattern + trait |
| `src/main/scala/xiangshan/backend/vector/Decoder/Split/SplitTable.scala` | 918-919, 947-953 | uop 拆分表 |
| `src/main/scala/xiangshan/backend/vector/Decoder/DecodeFields/DecodeFields.scala` | （含 `vmacc` 字串） | 旧版/辅助字段表 |
| `yunsuan/src/main/scala/yunsuan/encoding/Opcode/Opcodes.scala` | 1768-1783（`vmacc_e*`）, 1794-1806（`vwmacc*`） | **功能码定义（真源）** |
| `yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/VIMac64b.scala` + `VIMac64b_noBooth.scala` | — | 使用 `VIMacOpcode` 解码位 |
| `src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala` | 13-41 | FU 包装，解码 `VIMacOpcodes.*` |
| `ChiselAIA/rocket-chip/.../rocket/Instructions.scala` | — | rocket-chip 自动生成表，**XiangShan 向量译码不使用**（仅标量/vendored） |

### 1.5 可用编码空间（已实测）

从 `VecArithInstPattern.scala` 直接统计：

- **OPIVV（`func3=000`，opcode=`1010111`）空闲 func6 共 22 个**：
  `000011 001000 001101 001111 010110 011110 011111 100100 100110 110010 110011 110100 110110 110111 111000 111001 111010 111011 111100 111101 111110 111111`
- **OPMVV（`func3=010`）空闲 func6 共 12 个**：
  `001110 001111 010001 010011 010101 010110 101000 101010 101100 101110 111001 111110`
  —— 注意 `101000 / 101010 / 101100 / 101110` 恰好是 MADD/NMSUB/MACC/NMSAC 四元组的偶数槽，
  这正是 RISC-V `Zvqdotq` 草案放 `vqdot*` 的位置（**UNVERIFIED：仓库内没有 Zvqdotq 规范，未核对官方编码**）。

---

## 2. uop 拆分 / vl / LMUL 处理

### 2.1 真正生效的拆分机制

**`Decoder/UopSplitType.scala` 与 `Decoder/UopNumModule.scala` 都不是算术指令的拆分主路径**：
- `UopSplitType.scala` 共 509 行，其中 459 行是注释（`grep -c '^ *//'` = 459），
  `UopSplitBase` / `splitUops` 的具体子类基本被注掉，是遗留/未来设计。
- `UopNumModule.scala` 的 `UopNumSegDecoder`（`:33-80`）只处理 **访存段数 `nf`** 与 `numUopOH` 相乘，
  与算术指令无关。
- `xiangshan/package.scala:637 object UopSplitType` 是 V1 旧后端的 split 枚举。

**算术指令的 uop 数与内容 100% 由
`src/main/scala/xiangshan/backend/vector/Decoder/Split/SplitTable.scala` 的
`SeqMap[BitPat, SeqMap[SewLmulPattern, Seq[Opcode]]]` 决定。**
`maxSplitUopNum = 8`（`src/main/scala/xiangshan/backend/vector/package.scala:30`）。

### 2.2 拆分助手函数一览（`SplitTable.scala`）

| 助手 | 行 | 语义 | LMUL=1/2/4/8 的 uop 数 |
|---|---|---|---|
| `dup` | 89-134 | 等宽，1 uop/寄存器 | 1 / 2 / 4 / 8 |
| `dupM` | 136-181 | 写 mask 寄存器，首 uop 分配 vd、其余 `+ NoDestAlloc` | 1 / 2 / 4 / 8 |
| `dupF2W` | 183-224 | **2 倍加宽**（vwadd/vwmacc），uop 数翻倍，LMUL=8 非法（`Seq()`） | 2 / 4 / 8 / — |
| `dupF2N` | 228-253 | 2 倍变窄（vnsrl/vnclip），偶数 uop `+ NoDestAlloc` | 2 / 4 / 8 / — |
| `dupF2Ncvt` | 256-284 | 变窄 cvt，`+ Src1Vp` | 1 / 2 / 4 / — |
| `redu` | 359-396 | 归约：前 N-1 个普通 uop + 最后一个 reduce uop | 1 / 2 / 4 / 8 |
| `wredu` | 428-470 | **加宽归约**（vwredsum）：`vwadd4uop` 树 + `adduop` + 最后 `reduop` | 1 / 2 / 4 / 8 |
| `same` / `sewSame` | 324-357 | 固定序列 | — |

典型行：
```
:918  VMACC_VV    -> dup(vmacc_e8, vmacc_e16, vmacc_e32, vmacc_e64)(_.S1v),
:949  VWMACC_VV   -> dupF2W(vwmacc_e8, vwmacc_e16, vwmacc_e32)(_.S1v),
:1123 VSHA2MS_VV  -> dup(null, null, vsha256ms, null)(_.S1v),
:1124 VSHA2CL_VV  -> dup(null, null, vsha256cl, null)(_.S1v),
:1125 VSHA2CH_VV  -> dup(null, null, vsha256ch, null)(_.S1v),
```
注意 Zvknh 的写法：`dup(null, null, <uop>, null)` —— 只有 e32 有效，其余 SEW 填 `null`，
配合 `SL_CryptBoth` 过滤掉非法 (sew,lmul)。**这正是“限定某个 SEW 的新指令”的标准写法。**

### 2.3 寄存器号推进方式（`Src1/Src2/DestSelect`）

枚举定义：
- `DecodeFields/VecDecodeChannel/Src2Select.scala:30-38`
- `DecodeFields/VecDecodeChannel/Src1Select.scala:30-39`
- `DecodeFields/VecDecodeChannel/DestSelect.scala:29-35`

硬件实现：`Decoder/DecodeChannel/SrcSelectModule.scala:44-130`
```
INC1  -> (r + i)        // 每个 uop 推进 1
INCF2 -> (r + i/2)      // 每 2 个 uop 推进 1
INCF4 -> (r + i/4)      // 每 4 个 uop 推进 1   ← 4:1 映射已存在
CONST -> r
```
并且 **`out.src(i).dest` 同时就是第三源 vs3 的寄存器号**（`SrcSelectModule.scala:113-131`）——
V3_*_SrcDest 类指令不需要额外的 src3 选择逻辑。

`VWMACC_VV` 的组合（`Src2Select.scala:65` / `Src1Select.scala:86` / `DestSelect.scala:62`）：
```
src1 = INCF2, src2 = INCF2, dest = INC1     // 2 个 dest 寄存器 ← 1 个 src 寄存器
```

### 2.4 本框架是否支持 4:1 元素数缩减？

**部分支持，分两种语义讨论：**

**语义 A（推荐）—— Zvqdotq 风格：`vtype.SEW = 32`，源寄存器里每个 32-bit 元素含 4×int8。**
- EEW(vs1) = EEW(vs2) = EEW(vd) = 32，EMUL 全相等 ⇒ 寄存器映射 **1:1**。
- 直接复用 `VecIntVVVVPattern + V2_VecNormal + V1_VecNormal + V3_VecNormal_SrcDest`，
  `SL_*` 限定 `sew == 32`（可仿照 `SL_CryptW128E32`，`SewLmulRangeField.scala:33`），
  拆分表用 `dup(null, null, vdot_e32, null)(_.S1v)`。
- `Src1/Src2/DestSelect` 全部 `INC1`，不需要任何新枚举值。
- `VRegTypesField`（见 §2.5）自动推导，无需改。
- **结论：解码侧零新增枚举，只需加表项。**

**语义 B —— “四倍加宽”：`vtype.SEW = 8`，vl 以 8-bit 元素计，vd 的 EEW=32、EMUL = LMUL/4。**
- 需要 `dest = INCF4`、`src = INC1`，其中 `DestSelectEnum.INCF4`（`DestSelect.scala:33`）
  与 `SrcSelectModule.scala:120` 的硬件 **已经存在**（目前被 `vzext.vf4` 这类反向用例使用，
  见 `Src2Select.scala:93 case VecIntS2DVExtF4Pattern() => INCF4`）。
- 但 **缺一个 `dupF4N` 拆分助手**（现有只有 `dupF2N`，`SplitTable.scala:228`），
  需要构造 “3 个 `+ NoDestAlloc` + 1 个分配 vd” 的四元组。
- 更严重的是 **写回数据通路不支持 1/4 宽结果**：
  `Func.VecSpecialData`（`backend/vector/fu/Func.scala:150-167`）只有
  `normal = UInt(vlen.W)` 和 `narrow = UInt((vlen/2).W)` 两档，**没有 `vlen/4`**。
  `Exu` 里 `isNarrow` 也只区分 2 倍变窄（`VecFuConfig.scala:197-201 needNarrowOut`）。
- 另外 `SL_Widen` 的约束是 `lmul <= 4`，四倍变窄需要新的 `SL_Narrow4`（已声明于
  `VecArithInstPattern.scala:1063 sealed trait SL_Narrow4`，`SewLmulRangeField.scala:29` 已有
  `case _: SL_Narrow4 => sew >= 32`，但没有算术指令在用）。
- **结论：语义 B 可做但代价显著高于语义 A。**

### 2.5 最接近的现有先例

| 先例 | 比例 | 文件:行 |
|---|---|---|
| `vwmacc.vv` | 1 src reg → 2 dst reg（2:1 加宽），读 vd 作第三源 | `SplitTable.scala:949` + `VecArithInstPattern.scala:453` |
| `vzext.vf4` / `vsext.vf4` | 1 src reg → 4 dst reg（4:1 加宽） | `Src2Select.scala:93`、`Src1Select.scala` 同族、`SrcSelectModule.scala:80` |
| `vnclip.wv` | 2 src reg → 1 dst reg（2:1 变窄，偶数 uop 不分配 vd） | `SplitTable.scala:665-670` + `dupF2N` |
| `vredsum.vs` | 向量 → 标量归约，`redu`，dest=`CONST`，src2=`INC1x7_S1` | `SplitTable.scala:690-693`, `Src2Select.scala:102`, `DestSelect.scala:99` |
| `vwredsum.vs` | **4 路加宽归约树**，用到 `vwadd4u_e*` 这一“一条 uop 做 4 输入加法”的 opcode | `SplitTable.scala:676-687` + `wredu`（`:428`）+ `yunsuan/.../Opcodes.scala:1414-1417` |

**`vwadd4u_e8`（`yunsuan/src/main/scala/yunsuan/encoding/Opcode/Opcodes.scala:1414`，属于 `VIAluOpcode`）
是仓库里唯一已有的“4 输入加法”原语**，是 vdot 累加树最直接的硬件先例。

### 2.6 vl / vstart 的处理位置

- `vl` 由 `IssuePipe.scala:203 is2Next.bits.data.vl.foreach(_ := in.is2VlRdDataNext.head.data)` 从 vl 物理寄存器读入。
- **tail 的切分在 `Exu.scala:143-163`**，不在 FU 内：
  ```
  :147  val vlMapVdIdx = elemIdxMapVdIdx(vl, eewOHEx(i))(3, 0)
  :148  val end        = elemIdxMapElemE8Idx(vl, eewOHEx(i))
  :156-163  mgu.in.data.end := Mux(isWholeVMove, vlenb.U, Mux1H(...vdIdx 与 vlMapVdIdx 比较...))
  ```
  `eewOHEx(i)`（`:114-122`）会在 `isWiden` 时把 EEW 左移一档 —— **只支持 2 倍加宽，不支持 4 倍。**
- `vstart` 在 V2 算术路径被硬编码为 0：
  - `backend/vector/fu/VecFunc.scala:35 protected def vstart = 0.U`
  - `Exu.scala:154-155 // since vstart is always 0 for vector arith instruction, begin is always 0` / `mgu.in.data.begin := 0.U`
  - 对应的译码字段是 `IsVstartForceZeroField.scala`。

---

## 3. FU 配置与发射（FU configuration & issue）

### 3.1 注册一个新 FU 需要动的 5 张表（按依赖顺序）

1. **`yunsuan/src/main/scala/yunsuan/encoding/Opcode/Opcodes.scala`** —— 新增 `trait XxxOpcode extends Opcodes` +
   `object XxxOpcode extends XxxOpcode`，并把它加进 `:376-395 private[encoding] lazy val opcodeObjects: Seq[Opcodes]`。
   必须 `override def getLat(opcode: Opcode): Int`（基类 `:176-179` 只会打印 warning 并返回 0）。
   注意 `Opcodes.updateWidth`（`:194-196`）是 **全局最大值**：新家族的编码位宽若超过现有最大值，
   `Opcode()` 的位宽会整体变宽；`Latency()` 位宽同理由 `getMaxFixLat` 决定（`:133-143`）。
2. **`src/main/scala/xiangshan/backend/decode/opcode/Opcode.scala`** —— `:61-78` 加一行别名
   `val XxxOpcodes = Opcodes.XxxOpcode`（纯转发层，向量 opcode 本体不在 XiangShan 仓库里）。
3. **`src/main/scala/xiangshan/backend/fu/FuType.scala`** —— `:40-56` 的 `addType(name = "...")`。
   `FuType` 是 one-hot 枚举（`object FuType extends ChiselOHEnum`，`:11`），
   **新增一项会让 `FuType()` 整体宽一位**，进而影响所有带 fuType 的 bundle。
   还需视情况加进 `:111 val vecOPI = Seq(vialu, vimac, vidiv)` 之类的分组，以及 `:197-201` 的名字映射表。
4. **`src/main/scala/xiangshan/backend/fu/FuConfig.scala`** —— 仿 `:592-614 val VimacCfg`，
   并加进 `:844-852 def allConfigs`。关键字段：
   ```scala
   srcData = Seq(Seq(VecData(), VecData(), VecData())),  // vs1, vs2, vd_old
   piped = true, writeVecRf = true, writeV0Rf = true,
   latency = CertainLatency(2), destDataBits = 128,
   vlWakeUp = true, maskWakeUp = true, readV0 = true, readVl = true, readVType = true,
   ```
5. **`src/main/scala/xiangshan/backend/vector/fu/VecFuConfig.scala`** —— `:270-289` 加
   `val XxxCfg = VecFuConfig.fromFuConfig(FuConfig.XxxCfg, (p, cfg) => Module(new XxxWrapper(cfg)(p).suggestName("Xxx")))`，
   并加进 `:291-330 def allConfigs`。
   **`fuGen2` 不给就会在 elaborate 时抛 `NotImplementedError`**（`VecFuConfig.scala:52`）。
   如果该 FU 要写 vd 的加宽/变窄结果，还要动 `:195-205 needWidenOut / needNarrowOut`，
   以及 `:181-193 isVecArith`（决定 `fflags` 是否单独走线等）。

### 3.2 挂到执行单元 & 发射队列

**V2 向量区域的执行单元列表在**
`src/main/scala/xiangshan/Parameters.scala:483-535 val vecSchdParams`：
```
:487-497  ExeUnitParams("VFEX0", Seq(VialuCfg, VimacCfg, VmoveCfg, VfcvtCfg, VfmacCfg),
                        Seq(VfWB(port=3,0), IntWB(port=4,1), FpWB(port=6,0)),
                        Seq(Seq(VfRD(0,0), FpRD(12,1)), Seq(VfRD(1,0)), Seq(VfRD(2,0))),
                        vlRD = VlRD(0,0), v0WB = V0WB(0,0), v0RD = V0RD(0,0))
:499-509  ExeUnitParams("VFEX1", Seq(VialuCfg, VidivCfg, VfmacCfg, VfdivCfg), ...)
:511-520  ExeUnitParams("VFEX2", Seq(VialuCfg), ...)
:522-531  ExeUnitParams("VFEX3", Seq(VialuCfg), ...)
:533-541  ExeUnitParams("VSTD0", Seq(VStdCfg), ...)
```
另有一份 **老的（V1）** 列表在 `src/main/scala/xiangshan/backend/BackendParams.scala:770-797`
（只有 VFEX0 / VFEX1，且 `VFEX0 = Seq(VialuCfg, VimacCfg, VfcvtCfg, VSetRvfWvfCfg, VmoveCfg)`）。

`ExuParam`（`backend/vector/ExuParam.scala`）是从 `ExeUnitParams` 机械转换来的（`:302-320 object ExuParam.apply`），
所有 `numSrc / readV0 / writeVecRf / needVxsatWen ...` 都是对 `fuConfigs` 做 `max` / `exists` 归约（`:45-85`），
**所以把新 cfg 塞进某个 `ExeUnitParams` 的 `fuConfigs` 列表里，发射/读写端口会自动扩容**，
前提是该 exu 的 `readPortCfgs` 已经有 3 个向量源端口（VFEX0..VFEX3 都有）。

`IssueParam`（`backend/vector/IssueParam.scala:89-91`）：
```scala
def getFuCfgs: Seq[VecFuConfig] = exuParams.flatMap(_.fuConfigs).distinct
def deqFuCfgs: Seq[Seq[VecFuConfig]] = exuParams.map(_.fuConfigs)
```
—— 发射队列按 `fuType` one-hot 与 `fuSel2`（`VecFuConfig.scala:112-114`）做选择，无需额外注册。

### 3.3 延迟（latency）的声明链

延迟在 **三处**必须一致：

1. **真源**：`yunsuan/.../Opcodes.scala` 里各家族的 `override def getLat`。
   `VIMacOpcode` 是 `:1838 override def getLat(opcode: Opcode): Int = 2`（整族固定 2）；
   `VIAluOpcode` 则按 opcode 位逐条算（`:1640-1649`）。
2. **硬件译码器**：`src/main/scala/xiangshan/backend/vector/LatDecoder.scala:34-45`
   ```scala
   // One group per opcode space; keep in sync with the vector exe units in `vecSchdParams`.
   val opcodes = Seq(FAluOpcodes, FMiscOpcodes, FCvtOpcodes, FMacOpcodes,
                     VIAluOpcodes, VIMacOpcodes, VMoveOpcodes, VFCvtOpcodes, VFMacOpcodes, StuOpcodes)
   ```
   **新家族不加进这个 `Seq`，`LatDecoder` 的 `Mux1H` 就取不到它的 latency。**
   调用点：`Decoder/DecodeStage.scala:191 bits.latency := LatDecoder(bits.fuType, bits.fuOpType)`。
   注意 `LatDecoder` 用 `FuTypeField.genFuType(opcodes)` 做 Mux1H 选择键（`:28-30`），
   所以 **同一个 FuType 下不能有两个 opcode 家族**（注释 `:35-36` 明说会被 OR 在一起）。
3. **FuConfig**：`FuConfig.latency = CertainLatency(n)` → `VecFuConfig.latency` →
   `Exu.latencyMax = param.fuConfigs.map(_.latency).max`（`Exu.scala:30`），决定 ex 流水级数
   `numOfEx = latencyMax + 1`（`:35`）与 MergeUnit 个数 `numOfMgu`（`:34`）。
   `Func` 基类据此生成 `in.ex = Vec(cfg.latency + 1, ValidIO(new InUop))`（`Func.scala:71`），
   并在 `Func.scala:36-38` 用 `outStage.valid := inStage.valid && inStage.bits.ctrl.latency === i.U` 做自动对齐。

### 3.4 写回端口与 busy table

- 写回端口由 `ExeUnitParams(..., wbPortConfigs)` 指定（`Parameters.scala:490` 里的 `VfWB(port=3,0)`）。
  同一个 exu 内多个 FU **共享**写回端口，由 `WbDataPath.scala:25-31` 的 `Mux1H` 按 `wen` 选择。
  因此 **把 vdot 挂进 VFEX0 不会新增写回端口**。
- `Exu.scala:55-62` 的断言：`PopCount(out.ex.map(_.valid)) <= 1.U`（`Func.scala:56-60`）——
  “Mixed-latency uops must therefore be scheduled so this Func never has more than one output stage valid”。
  即 **同一个 Func 在同一周期只能有一个输出级有效**。
- `WbFuBusyTable`（`backend/vector/WbFuBusyTable.scala`）：
  - `:102 DefaultExLatency = 4`，`:103 NonFixedLatencyWidth = 5`
  - `:137-141 fixedLatBusyTableEntries = (1 << Latency().getWidth) + 4`
  - `:150-156 writebackSlot(latency, latencyOffset)` 把 latency 编码成预约槽位
  - 发射队列在 is0 阶段就预约，表每周期右移一位（`:28-37`）
  - **只要 latency 是 `CertainLatency`，加入新 FU 对 busy table 是零改动**；
    非固定延迟 FU 才需要进 `ExuParam.nonFixedLatFuConfigs`（`ExuParam.scala:330`，
    目前硬编码为 `Seq(FuType.vidiv, FuType.vfdiv, FuType.fDivSqrt)`）。

### 3.5 “新 FU” vs “现有 FU 内的新功能”

- **新功能（推荐）**：在 `VIMacOpcode` 里加一个 opcode 值 → 复用 `FuType.vimac` / `VimacCfg` /
  `VIMacU`。**第 3.1 节的 5 张表只需动第 1 张**，LatDecoder、FuType 宽度、FuConfig、
  ExeUnitParams、busy table 全部零改动。
  `VIMacOpcode` 的字段布局（`Opcodes.scala:1817-1823`）：
  `[8]=vs2Sign [7]=vs1Sign [6:4]=op [3]=opMode(OP2/OP3) [2]=destMode(DV/DW) [1:0]=sew`。
  已用的 `op` 值只有 `000/001/010/011`，**`100/101/110/111` 全空**，加 `DOT = bb"100"` 不会改变 9 bit 宽度。
  代价：`getLat` 目前是整族常量 2（`:1838`），若 vdot 需要 3 拍，必须改成按位判断
  （会同时影响 vmacc 的 LatDecoder 表，但值不变所以安全）。
- **新 FU**：第 3.1 节 5 张表全动 + `LatDecoder.opcodes` + `Parameters.scala vecSchdParams` +
  `FuTypeField.genFuType` 的 match。`FuType` 宽度 +1 会波及全后端的 bundle 宽度（可编译通过，但 diff 面大）。

---

## 4. 数据通路（Datapath，yunsuan）

### 4.1 模块层次（实测名称）

```
xiangshan.backend.vector.Exu                       (backend/vector/Exu.scala:27)
 └─ fus: Seq[Func]                                 (Exu.scala:41, 由 VecFuConfig.fuGen2 构造)
     ├─ VIAluWrapper   (backend/fu/wrapper/VIAluWrapper.scala)   extends VecFixLatFunc
     ├─ VIMacU         (backend/fu/wrapper/VIMacU.scala:12)      extends VecFixLatFunc
     │    └─ vimacs: Seq.fill(VLEN/64 = 2)(Module(new VIMac64b))     (VIMacU.scala:42)
     │         └─ yunsuan.vector.mac.VIMac64b   ← 源文件路径 yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/VIMac64b.scala
     │              ├─ VIMac64bStage1  (Booth 编码 + 部分积 + Wallace 树)  510 行
     │              ├─ VIMac64bStage2  (3:2 压缩 + 2×152-bit 全加器)      193 行
     │              └─ VIMac64bStage3  (分段取位 + 饱和 + 舍入)            320 行
     ├─ VIDiv / VMove / VCVTWrapper / VFMacWrapper / VFDivWrapper / VStdWrapper
     └─ (V1 遗留) VSha256cWrapper / VSha256msWrapper  extends VecPipedFuncUnit  ← 不同基类！
 └─ mgus: Seq.fill(latencyMax+1)(Module(new yunsuan.vector.v2.MergeUnit))  (Exu.scala:43)
```

> **注意命名陷阱**：Scala 包名是 `yunsuan.vector.mac`，但目录名是 `vectorIMAC/`。
> `grep -r "VectorIntAdder\|VectorIntMultiplier"` 在本 commit 下 **没有匹配**；
> 真实名字是 `VIMac64b`（乘加）、`VIntAdder64b`（`yunsuan/src/main/scala/yunsuan/vector/v2/VectorInt/VIntAdder64b.scala`）、
> `VectorIntBitOp64b`、`VectorIntShift64b`、`VFixPoint64b`。

### 4.2 新功能单元必须实现的 Chisel 接口

**V2 区域的 FU 基类是 `xiangshan.backend.vector.fu.Func`**
（`src/main/scala/xiangshan/backend/vector/fu/Func.scala:19-64`）：

```scala
class Func(val cfg: VecFuConfig)(implicit p: Parameters) extends XSModule {
  val in  = IO(Input (new Func.In))      // Func.scala:22
  val out = IO(Output(new Func.Out))     // Func.scala:23
}

class In  { // Func.scala:67-75
  val flush   = Flipped(ValidIO(new Redirect))
  val ex0Next = ValidIO(new InUop)                 // 组合级（寄存器之前），用于生成译码信号
  val ex      = Vec(cfg.latency + 1, ValidIO(new InUop))   // 各级流水寄存器
  val frm     = Option.when(cfg.needSrcFrm)(Frm())
  val vxrm    = Option.when(cfg.needSrcVxrm)(Vxrm())
}
class Out { // Func.scala:77-80
  val ex = Vec(cfg.latency + 1, ValidIO(new OutUop))
}
class InData  { // Func.scala:116-122
  val src = MixedVec(cfg.genSrcDataVec)   // src(0)=vs1, src(1)=vs2, src(2)=vd_old
  val v0  = Option.when(cfg.readV0)(V0())    // VLEN 位
  val vl  = Option.when(cfg.readVl)(Vl())
  val imm = UInt(cfg.destDataBits.W)
}
class VecSpecialData(cfg, vlen) { // Func.scala:150-167  ← FU 的输出数据契约
  val normal   = UInt(vlen.W)            // 等宽结果（vdot 用这个）
  val narrow   = UInt((vlen/2).W)        // 2 倍变窄结果
  val maskE8/E16/E32/E64                 // mask 类结果
  val isWiden  : Option[Bool]            // cfg.needWidenOut 时存在
  val isNarrow : Option[Bool]
  val vxsatE8 / narrowVxsatE8 / fflagsE8 / narrowFflagsE8
}
```

实际要继承的是 `VecFixLatFunc`（固定延迟）或 `VecNonFixedLatFunc`（可变延迟），
两者都在 `src/main/scala/xiangshan/backend/vector/fu/VecFunc.scala:48-55 / 58-139`，
并通过 `trait VecFuncAlias`（`VecFunc.scala:14-46`）提供别名：
```scala
ex0vs1 = ex0data.src(0);  ex0vs2 = ex0data.src(1);  ex0oldVd = ex0data.src(2)
ex0vma / ex0vta / ex0vm / ex0uopIdx / vstart(=0) / vxrm / frm
vs1Ex / vs2Ex / vs3Ex / oldVdEx : Seq[UInt]   // 逐级
```

**yunsuan 侧 64-bit lane 的 IO 契约**（`yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/VIMac64b.scala:84-125`）：
```scala
class In {
  val info     = new Info           // uopIdx: UInt(6.W), vxrm: Vxrm()
  val ex0      = ValidIO(new InEx0) // ctrl: VIMac64bStage1.InCtrl, data: {vs2, vs1, oldVd : UInt(64.W)}
  val ex1Valid = Bool()
}
class Out { val ex0, ex1, ex2 = new OutData }
class OutData {
  val vd          = UInt(64.W)
  val narrowVd    = UInt(32.W)
  val mask        = new MaskGroup
  val vxsat       = UInt(8.W)
  val narrowVxsat = UInt(4.W)
}
// ctrl 字段（VIMac64bStage1.InCtrl）：
//   sewIs8 / sewIs16 / sewIs32 / sewIs64, vs1Sign, vs2Sign, vdSign,
//   isSub, highHalf, isMacc, widen, isFixP
```

`VIMacU.scala:62-83` 展示了 128→2×64 的拆分、widen 时的交错重组（`vs2GroupedVec`，`:57-60`）、
以及 `overWriteMultiplicand`（vmadd/vnmsub 把 vs2 与 oldVd 互换，`:23` + `:81-82`）。

### 4.3 可复用于 8-bit 乘累加的既有结构

**首选：`VIMac64bStage1` 的 Booth/Wallace 部分积阵列。**
在 `sewIs8` 下，一个 64-bit lane 并行算 8 个 8×8 乘法；
`VIMac64bStage1.scala:36-115` 可见：
- `vs1Booth`：32 组 Booth 编码（`:40-49`）
- `partProdGenerator`：`Vec(32, UInt(68.W))` 部分积（`:84-93`）
- `wallaceTreeGenerator`：`Vec(33, UInt(152.W))`，**`oldVd` 直接作为一行压进 Wallace 树**（`:107`），
  即 “乘累加” 是零额外延迟的（`isMacc` 信号，`:111`）

**元素分段靠“位距”而非独立加法器**：
`VIMac64bStage2.scala:52-63` 用两个 **152-bit 全加器**（`fullAdder152b`）一次算完整条 lane；
`VIMac64bStage3.scala:158-163` 再按 SEW 取位：
```
sewIs8  -> Cat(UIntSplit(sumFinalNonFixP, 19).reverse.map(x => Mux(highHalf, x(15,8), x(7,0))))
sewIs16 -> ... UIntSplit(..., 38) ... x(31,16) / x(15,0)
sewIs32 -> ... UIntSplit(..., 76) ... x(63,32) / x(31,0)
```
即 SEW=8 时 152 位被切成 **8 段 ×19 位**，每段放一个 16 位乘积 + 3 位余量。

**对 vdot 的直接含义**：四个相邻的 19-bit 段里已经各自躺着一个 8×8 乘积。
要得到 32-bit 点积，只需在 Stage3（或 `VIMacU` 内另起一路）把
`UIntSplit(sumFinalNonFixP, 19)` 的每 4 段取 `x(15,0)` 做符号扩展后相加，再加 `oldVd` 的 32-bit 元素。
这是一棵 4 输入、16→32 位的小加法树，**不触碰 Booth 编码、部分积、Wallace 树和 152-bit 全加器**。

**次选：`vwadd4u/vwadd4` 原语**（`yunsuan/.../Opcodes.scala:1414-1417`，属于 `VIAluOpcode`，
由 `SplitTable.scala:676-687` 的 `wredu` 使用）—— 仓库里已有的“四输入加宽加法”实现，
可作为累加树的参考实现；具体硬件在 `yunsuan/src/main/scala/yunsuan/vector/v2/VectorInt/VIntAdder64b.scala`
（**UNVERIFIED：未逐行核对 VIntAdder64b 是否真实实现了 WADD4U 路径**）。

---

## 5. Mask / tail / vstart 处理

### 5.1 V2 区域（Exu + yunsuan MergeUnit）—— vdot 实际会走的路径

FU **不做任何 mask/tail 处理**，只吐裸结果。合并由 `Exu` 外挂的 `MergeUnit` 完成：

`src/main/scala/xiangshan/backend/vector/Exu.scala:131-166`
```scala
mgu.in.valid       := ex(i).valid
mgu.in.ctrl.vma    := context.ctrl.vtype.get.vma
mgu.in.ctrl.vta    := context.ctrl.vtype.get.vta
mgu.in.data.mask   := Fill(vlenb, context.ctrl.vm.get) | context.data.v0.get  // :153  ← 见风险
mgu.in.data.begin  := 0.U                                                      // :155
mgu.in.data.end    := Mux(isWholeVMove, vlenb.U, Mux1H(Seq(
                        (vdIdx >  vlMapVdIdx) -> 0.U,
                        (vdIdx === vlMapVdIdx) -> end,
                        (vdIdx <  vlMapVdIdx) -> vlenb.U)))                    // :156-163
mgu.in.data.oldVd  := context.data.src(2).toByteVec                            // :165
mgu.in.data.vd     := vd.toByteVec                                             // :166
```

`yunsuan/src/main/scala/yunsuan/vector/v2/MergeUnit.scala:36-82`：
```scala
beginMask  = (Fill(vlenb,1) << begin)(2*vlenb-1, vlenb)
endMask    = (Fill(vlenb,1) << end  )(2*vlenb-1, vlenb)
tailMask   = ~endMask
bodyMask   = ~beginMask & endMask
activeMask   = bodyMask & maskEn
agnosticMask = Fill(vlenb,vma) & bodyMask & ~maskEn  |  Fill(vlenb,vta) & tailMask
res(i) = Mux(activeMask(i), vd(i), Mux(agnosticMask(i), 0xFF, oldVd(i)))
```
—— **全部按字节（vlenb=16）粒度工作**。

**因此一个新 FU 只需要提供**：
1. `out.ex(latency).bits.data.vec.get.normal` = 128 位裸结果；
2. 其余 `narrow / maskE8..E64 / vxsatE8 / narrowVxsatE8` 赋 0（见 `VIMacU.scala:86-121` 的样板）；
3. 若 `cfg.needWidenOut`，还要给 `isWiden`（`Exu.scala:108-113` 用它左移 EEW）。

### 5.2 V1 区域（`Mgu.scala` / `NewMgu.scala` / `ByteMaskTailGen.scala` / `Mgtu.scala`）

- `backend/fu/vector/ByteMaskTailGen.scala:45-99` 是真正的 **按 EEW 展开 mask 到字节** 的实现：
  ```
  :60-61  startBytes/vlBytes = Mux1H(eewOH, Seq.tabulate(4)(x => in.begin/end << x))   // 元素索引 → 字节索引
  :72     maskEn = MaskExtractor(vlen)(io.in.maskUsed, io.in.vsew)                      // 元素 mask → 字节 mask
  :67-69  prestartEnInVd/bodyEnInVd/tailEnInVd = LookupTree(vdIdx, ...)                 // 按 uopIdx 取本寄存器那一段
  :77-78  activeEn / agnosticEn
  ```
- `backend/fu/vector/NewMgu.scala:11-42` = `VecDataToMaskDataVec(mask, eew)` + `ByteMaskTailGen`，
  只输出 `activeEn / agnosticEn`（`:38-40`），由调用方自己做字节选择
  （见 `VSha256cWrapper.scala:44-65`）。
- `backend/fu/vector/Mgu.scala`（246 行）是功能更全的老版本（含 narrow / mask-dest / 写回合成）。
- `backend/fu/vector/Mgtu.scala`（55 行）处理 **mask 目的寄存器的 tail**（`vmseq` 之类，
  tail 位必须写 1），与 vdot 无关。

**V2 的 `MergeUnit` 相对 `ByteMaskTailGen` 少了两件事：
(a) mask 从元素粒度展开到字节粒度；(b) `begin`(vstart) 支持。**
参见 §9 风险。

---

## 6. 先例研究：`VSha256cWrapper` / `VSha256msWrapper`

（本节结论与并行侦察结果合并，见下文"6.4 完整改动清单"。）

### 6.1 它是**新 FuType**，不是现有 FU 的新功能

证据链：
- `src/main/scala/xiangshan/backend/fu/FuType.scala:55-56`
  ```scala
  val vsha256ms = addType(name = "vsha256ms")
  val vsha256c  = addType(name = "vsha256c")
  ```
- `src/main/scala/xiangshan/backend/fu/FuConfig.scala:724-743 val VSha256msCfg` / `:745-764 val VSha256cCfg`
  —— 注意这两个 cfg **有 `fuGen`**（V1 路径）：
  ```scala
  fuGen = (p, cfg) => Module(new VSha256cWrapper(cfg)(p).suggestName("VSha256c"))
  ```
- `src/main/scala/xiangshan/backend/vector/fu/VecFuConfig.scala:287-288`
  ```scala
  val VSha256msCfg = VecFuConfig.fromFuConfig(FuConfig.VSha256msCfg)   // ← 没有 fuGen2！
  val VSha256cCfg  = VecFuConfig.fromFuConfig(FuConfig.VSha256cCfg)
  ```
- `yunsuan/src/main/scala/yunsuan/encoding/Opcode/Opcodes.scala:2085-2107`
  ```scala
  trait VSha256msOpcode extends Opcodes { val vsha256ms = DvSvlS2vS1S3v(bb"1") ... }
  trait VSha256cOpcode  extends Opcodes { val vsha256cl = DvSvlS2vS1S3v(bb"10"); val vsha256ch = DvSvlS2vS1S3v(bb"11") ... }
  ```
- `src/main/scala/xiangshan/backend/vector/Decoder/DecodeFields/VecDecodeChannel/FuTypeField.scala:88-89`
  ```scala
  case _: Opcode.VSha256msOpcodes.type => FuType.vsha256ms
  case _: Opcode.VSha256cOpcodes.type  => FuType.vsha256c
  ```

### 6.2 uop 数与延迟

- **uop 数**：`SplitTable.scala:1123-1125`，`dup(null, null, vsha256*, null)(_.S1v)`
  —— 仅 e32 有效；`dup` 的 LMUL 映射给出 LMUL=1→1 uop、2→2、4→4、8→8（`SplitTable.scala:103-108`）。
  配合 `SL_CryptBoth`（`VecArithInstPattern.scala:889-894` 的 trait + `SewLmulRangeField.scala:34`）
  过滤出 `sew==32 && lmul>=1`。
- **延迟**：`FuConfig.scala:735 VSha256msCfg.latency = CertainLatency(4)`、
  `:757 VSha256cCfg.latency = CertainLatency(2)`；
  `Opcodes.scala:2080 override def getLat(opcode) = 0`（**这是 `VMoveOpcode` 的，VSha256*Opcode
  没有 override `getLat`，会走基类 `:176-179` 的 warning 路径返回 0 —— 与 FuConfig 的 2/4 不一致**，
  这正说明它们没走 V2 的 `LatDecoder`）。

### 6.3 重要警告：Zvknh **没有被挂进 V2 的执行单元**

`grep -rn "VSha256cCfg\|VSha256msCfg" src/main/scala/`（排除 FuConfig.scala / VecFuConfig.scala）
**零匹配** —— 它们既不在 `Parameters.scala:483 vecSchdParams`，也不在
`BackendParams.scala:770 vecSchdParams`，也不在 `VecFuConfig.allConfigs`
（`VecFuConfig.scala:291-330` 的列表里有 `VSha256msCfg, VSha256cCfg`，但没有任何 `ExeUnitParams` 引用它们），
也不在 `LatDecoder.opcodes`（`LatDecoder.scala:36-46`）。

**结论：Zvknh 是一个"译码侧完整、执行侧未接线"的半成品先例。**
它的价值在于 §1/§2（译码、拆分、opcode 家族注册）是完整可抄的；
但 §3.2（挂 exu）、§3.3（LatDecoder）、§4（V2 Func 基类）这三块必须改抄 **`VIMacU` / `VimacCfg`**。
`VSha256cWrapper extends VecPipedFuncUnit(cfg: FuConfig)`（`VSha256cWrapper.scala:12`），
而 V2 需要的是 `extends VecFixLatFunc(cfg: VecFuConfig)`（如 `VIMacU.scala:12`）——
**两者 IO 完全不同，不能直接套用。**


### 6.4 `vsha2*` 完整改动文件清单（编号 checklist）

下表是 “加一条非基础向量指令” 实际触及的全部文件，**按依赖顺序**排列。
最右列标注本次 `vdot.vv` 是否需要（假设采用 §10 推荐的“VIMac 内新功能”方案）。

| # | 文件 | 行 | 改动类型 | vdot 是否需要 |
|---|---|---|---|---|
| 1 | `yunsuan/src/main/scala/yunsuan/encoding/Opcode/Opcodes.scala` | 2085-2093（ms）, 2095-2107（c）, 394-395（注册进 `opcodeObjects`） | 新 opcode 家族 trait+object，声明 `isLegal/isCL/isCH` 谓词，用 `DvSvlS2vS1S3v` 标记读 vs3 | **需要**（但只加 opcode 值，不新建家族） |
| 2 | `yunsuan/src/main/scala/yunsuan/vector/v2/Crypto/VSha256ms.scala` | 整文件（新） | yunsuan 算术模块：`In{valid,vs1,vs2,vs3:UInt(128.W)}` / `Out{valid,vd:UInt(128.W)}` | **需要**（改为在 `vectorIMAC/` 下扩展） |
| 3 | `yunsuan/.../v2/Crypto/VSha256c.scala`、`CryptoIteration.scala`、`CryptoIterationCtrl.scala`、`Utils.scala` | 整文件（新） | 多算法共享迭代器 + 控制 FSM + 数学函数库 | 不需要（vdot 单算法） |
| 4 | `src/main/scala/xiangshan/backend/decode/isa/Instructions.scala` | 796-798（BitPat）, 3132-3142（`ZVKNHAType`） | 比特模式声明 + `InstType` 分组 | **需要** |
| 5 | `src/main/scala/xiangshan/backend/decode/isa/Extensions.scala` | 43（`case object Zvknha`）, 168（进 `def extensions`） | 扩展声明 + 启用 | 若复用 `V` 则不需要；若自建扩展则需要 |
| 6 | `src/main/scala/xiangshan/backend/fu/FuType.scala` | 55-56 | `addType(name=...)`，FuType 位宽 +1 | 不需要（复用 `FuType.vimac`） |
| 7 | `src/main/scala/xiangshan/backend/fu/FuConfig.scala` | 724-742 / 745-763（cfg 本体）, 165-177（`needVecCtrl`）, 201-212（`isVecArith`） | `FuConfig` 对象 + 两个分类列表 | 不需要 |
| 8 | `src/main/scala/xiangshan/backend/fu/wrapper/VSha256cWrapper.scala` / `VSha256msWrapper.scala` | 整文件（新） | FU 包装类，**但基类是 V1 的 `VecPipedFuncUnit`** | 不需要新建；改 `VIMacU.scala` |
| 9 | `src/main/scala/xiangshan/backend/decode/opcode/Opcode.scala` | 68-69 | 把 yunsuan 的 opcode 家族 re-export 进 XiangShan 命名空间 | 不需要（`VIMacOpcodes` 已存在） |
| 10 | `src/main/scala/xiangshan/backend/vector/fu/VecFuConfig.scala` | 196-197（`isVecArith` 的 FuType 列表）, 304-305（`fromFuConfig`）, 345-346（`allConfigs`） | 包装成 `VecFuConfig` 并注册 | 不需要 |
| 11 | `src/main/scala/xiangshan/backend/vector/Decoder/DecodeFields/VecDecodeChannel/FuTypeField.scala` | 88-89 | Opcode 家族 → FuType 的 exhaustive match | 不需要 |
| 12 | `src/main/scala/xiangshan/backend/vector/Decoder/Split/SplitTable.scala` | 17-18（import）, 1120-1125（`cryptoTable`） | uop 拆分表项 | **需要** |
| 13 | `src/main/scala/xiangshan/backend/vector/Decoder/InstPattern/VecArithInstPattern.scala` | 889/891/893（case 子句）, 924（`VecCryptoInstPattern`）, 1001-1070（Crypt* traits） | func6 → Pattern + 操作数/重叠/SEW-LMUL trait | **需要**（只加 case 子句，复用现成 trait） |
| 14 | `src/main/scala/xiangshan/backend/vector/Decoder/DecodeChannels.scala` | 54（`simpleExts`）, 58（`vectorExts`） | 把新扩展路由到向量译码通道 | 若复用 `V` 则不需要 |
| 15 | `src/main/scala/xiangshan/Parameters.scala`（`vecSchdParams`） / `src/main/scala/xiangshan/backend/BackendParams.scala`（`BackendV2SchdParams.vecSchdParams`） | 483-545 / 770-800 | **把 cfg 加进某个 `ExeUnitParams` 的 `fuConfigs`** —— **Zvknh 先例恰恰漏了这一步** | 不需要（vimac 已在 VFEX0） |
| 16 | `src/main/scala/xiangshan/backend/vector/LatDecoder.scala` | 36-46 | 把 opcode 家族加进 `LatDecoder.opcodes` —— **Zvknh 先例也漏了这一步** | 不需要（`VIMacOpcodes` 已在列） |
| 17 | 测试 | — | **全仓零测试文件提到 `vsha2`/`zvknh`** | 需要自建（见 §7.5） |

**先例的两个缺口（#15、#16）必须在 vdot 上补齐，哪怕先例里找不到“做对了”的样板。**

---

## 7. 构建与测试基础设施

### 7.1 JDK

仓库内 **没有任何 JDK 版本 pin**：
- `.github/workflows/*.yml` 中无 `setup-java` / `java-version`
- `Dockerfile:16 FROM ghcr.io/openxiangshan/xs-env:stable` —— JDK 来自上游镜像，本仓库不可见（**UNVERIFIED**）
- `.github/workflows/release.yml:148 container: image: ghcr.io/openxiangshan/xs-env:ubuntu-24.04`

本机实测：`java -version` → `openjdk 25.0.2 (Homebrew)`，`which java` → `/usr/bin/java`（macOS shim）。
**JDK 25 + Mill 0.12.17 + Scala 2.13.17 + Chisel 7.13.0 的兼容性未验证**，建议第一步就跑
`mill -i xiangshan.compile` 验证；若失败优先尝试 JDK 17 或 21。

### 7.2 Mill

- `.mill-version` 内容 = `0.12.17`（整个仓库唯一的 mill 版本 pin）
- **没有 `./mill` wrapper 脚本**（仓库根 `ls -la` 只有 `.mill-version` 与 `build.mill`，无 `mill`/`millw`）
- `README.md:121` 明确要求自行安装 mill（brew / coursier / 官方 bootstrap script）
- 本机实测 `which mill` → **未安装**，`which verilator` / `which firtool` / `which cs` → 均未安装
- 所有 Makefile 调用一律带 `-i`（no-server 模式），例如 `Makefile:318 mill -i xiangshan.compile`
- `Dockerfile:25-26` 的官方自举检查：`COPY .mill-version /tmp` + `RUN cd /tmp && mill -i --version`
- `yunsuan/` 是 **独立的 Mill 工程**（`yunsuan/build.sc`，模块对象名 `YunSuan`，自带 `.mill-version`），
  **没有**被父仓库的 `build.mill:91-93 object yunsuan extends ChiselModule` 声明 test 子模块。

### 7.3 Scala / Chisel / firtool

| 项 | 值 | 证据 |
|---|---|---|
| Scala | `2.13.17` | `build.mill:32 val defaultScalaVersion = "2.13.17"` |
| Chisel | `7.13.0` | `build.mill:19`（`import $ivy`）+ `build.mill:42`（`mvn"org.chipsalliance::chisel:7.13.0"`） |
| chisel-plugin | `7.13.0` | `build.mill:46` |
| firtool-resolver | `2.1.1` | `build.mill:20` |
| firtool / CIRCT 本体 | **未字面 pin** | `build.mill:48-53 resolveFirtoolDeps` 调用 `firtoolresolver.Resolve(chisel3.BuildInfo.firtoolVersion.get, true)`，即由 chisel 7.13.0 jar 内嵌的 `BuildInfo` 决定（**UNVERIFIED：静态检查无法得出具体版本号**） |
| yunsuan 独立工程 | 同样 Scala 2.13.17 / Chisel 7.13.0，但额外用 `chiseltest:6.0.0` + `scalatest:3.2.20` | `yunsuan/build.sc:13-16` |

注意主仓库 `src/test/scala` 用的是 **Chisel 7 自带的 `chisel3.simulator.scalatest.ChiselSim`**，
而 yunsuan 用的是 **老的外部 `chiseltest` 库**，两套测试 API 不同。

### 7.4 只编译 Scala（最快语法检查）

`build.mill:148 object xiangshan extends ChiselModule`（**小写 `xiangshan`**）。
`Makefile:317-319`：
```
comp:
	mill -i xiangshan.compile
	mill -i xiangshan.test.compile
```
**推荐命令**：
```bash
cd /Users/i3eg1nner/code/cie/work/XiangShan
mill -i xiangshan.compile          # 只编译 src/main/scala，不做 elaborate，最快
mill -i xiangshan.test.compile     # 顺带检查 src/test/scala
```

### 7.5 跑单个 Chisel 单元测试

**`Makefile.test` 已过期、不可直接用**（整文件 12 行，实测内容）：
```
Makefile.test:3   mill -i XiangShan.test.runMain xiangshan.DecodeMain -td build --output-file DecodeUnit.v
Makefile.test:8   mill -i XiangShan.test.test
Makefile.test:12  mill -i XiangShan.test.testOnly xiangshan.DecodeUnitTest
```
两个问题：(a) 模块名写成大写 `XiangShan`，而 `build.mill:148` 是小写 `xiangshan`（Makefile 其他地方
`:318/:319/:323` 都用小写）；(b) `xiangshan.DecodeMain` / `xiangshan.DecodeUnitTest`
在当前源码树中 **不存在**（`grep -rln "object DecodeMain\|class DecodeUnitTest" src/` 零匹配）。

**正确命令**（`build.mill:242 object test extends SbtTests with TestModule.ScalaTest`）：
```bash
mill -i xiangshan.test.testOnly xiangshan.backend.fu.vector.ByteMaskTailGenTest
mill -i xiangshan.test.test                 # 全部测试
```

**现有向量相关测试（绝对路径）**：
- `/Users/i3eg1nner/code/cie/work/XiangShan/src/test/scala/xiangshan/backend/fu/vector/ByteMaskTailGenTest.scala`
  —— `class ByteMaskTailGenTest extends AnyFlatSpec with Matchers with ChiselSim`（`:11`），
  `:25 import chisel3.simulator.HasSimulator.simulators.verilator` → **需要本机有 verilator**
- `/Users/i3eg1nner/code/cie/work/XiangShan/src/main/scala/xiangshan/backend/fu/vector/Mgu.scala:213`
  —— `class MguTest`（测试类写在 main 源码里）
- `/Users/i3eg1nner/code/cie/work/XiangShan/src/test/scala/xiangshan/backend/fu/VsetModuleMain.scala:12`
- yunsuan 独立工程：`yunsuan/src/test/scala/vector/VectorALU/VPermSpec.scala`（`class VPermSpec extends AnyFlatSpec with ChiselScalatestTester`），
  跑法要先 `cd yunsuan` 再 `mill -i YunSuan.test.testOnly yunsuan.vectortest.perm.VPermSpec`（独立 build root）

整个 `src/test/` 只有 **17 个 `.scala` 文件**，其中 `*Test.scala`/`*Spec.scala` 仅 4 个。

### 7.6 只生成单个模块的 Verilog（不建整个 SoC）

整 SoC 的入口是 `Makefile:39 FPGATOP = top.TopMain` / `:40 SIMTOP = top.XiangShanSim`，**不要用**。

仓库里有大量 **standalone `extends App` 生成器**，向量区域尤其多（实测存在）：

| 对象 | 文件:行 | 命令 |
|---|---|---|
| `VerilogMgu` | `src/main/scala/xiangshan/backend/fu/vector/Mgu.scala:205` | `mill -i xiangshan.runMain xiangshan.backend.fu.vector.VerilogMgu` |
| `VerilogMaskExtrator` | `src/main/scala/xiangshan/backend/fu/vector/utils/MaskExtrator.scala:47` | `mill -i xiangshan.runMain xiangshan.backend.fu.vector.utils.VerilogMaskExtrator` |
| `UopNumDecoderMain` | `src/main/scala/xiangshan/backend/vector/Decoder/UopNumModule.scala:310` | `mill -i xiangshan.runMain xiangshan.backend.vector.Decoder.UopNumDecoderMain` |
| `DecodeChannelsMain` | `src/main/scala/xiangshan/backend/vector/Decoder/DecodeChannels.scala:696` | `mill -i xiangshan.runMain xiangshan.backend.vector.Decoder.DecodeChannelsMain` |
| `UopSplitModuleMain` | `src/main/scala/xiangshan/backend/vector/Decoder/DecodeChannels.scala:737` | 同上 |
| `LatDecoder.main` | `src/main/scala/xiangshan/backend/vector/LatDecoder.scala:56-80` | `mill -i xiangshan.runMain xiangshan.backend.vector.LatDecoder` —— **还会 dump 所有 opcode 的 latency 表，调试神器** |
| `SplitTable.main` | `src/main/scala/xiangshan/backend/vector/Decoder/Split/SplitTable.scala:33-66` | `mill -i xiangshan.runMain xiangshan.backend.vector.Decoder.Split.SplitTable` —— **打印每条指令的 uop 拆分结果，验证新表项的首选手段** |
| `SrcSelectModule.main` | `src/main/scala/xiangshan/backend/vector/Decoder/DecodeChannel/SrcSelectModule.scala:134` | 生成 src/dest 选择器 Verilog |
| `Opcodes.main`（yunsuan） | `yunsuan/src/main/scala/yunsuan/encoding/Opcode/Opcodes.scala:366-372` | 打印所有 opcode 编码 |

统一的 emit 辅助：`src/main/scala/xiangshan/backend/vector/util/Verilog.scala`（`circt.stage.ChiselStage` 薄封装）。

yunsuan 也有自己的 standalone 入口：`yunsuan/src/test/scala/vector/VectorTest.scala:12-18 object GenTest extends App`
（`mill -i YunSuan.test.runMain yunsuan.vector.GenTest`，需在 `yunsuan/` 目录下）。

### 7.7 macOS / aarch64 注意事项

1. **CI 完全没有 macOS 覆盖**：所有 `runs-on:` 都是 `ubuntu-latest` 或自托管 Linux label。
2. **本机缺 mill / verilator / firtool / coursier**，全部需要先装；mill 没有 vendored wrapper。
3. `ready-to-run` 子模块（`build.mill:230 val ready_to_run = Seq("riscv64-nemu-interpreter-dual-so", "riscv64-nemu-interpreter-so", "riscv64-spike-so")`）
   提供 difftest 参考模型的 **预编译 `.so`**，极可能是 x86_64 Linux ELF，**在 macOS/aarch64 上无法加载**
   （该子模块当前未初始化，**UNVERIFIED**）。→ **结论：difftest 全系统仿真在本机不可行，只能做模块级仿真。**
4. `difftest/libso.mk:35` 用 GNU 风格 `-shared -m64`（macOS 应为 `-dynamiclib`）。
5. `scripts/Makefile.pdb:47-48` 用 GNU findutils 专有的 `find -printf` 和 ELF 专有的 `-Wl,-rpath='$ORIGIN...'`
   （macOS 应为 `@loader_path`）—— `make pdb` 在原生 macOS shell 上会失败。
6. **ChiselSim 测试内部驱动 Verilator**，所以“单元测试”也需要 `brew install verilator`；
   仓库未 pin verilator 版本（`difftest/verilator.mk:30,33-46` 只有 ≥4.210 / ≥5.000 / ≥5.024 的特性探测）。
7. `scalastyle-config.xml` / `project/build.properties(sbt.version=1.2.6)` 是 sbt 时代遗留，当前 Mill 构建不使用。

### 7.8 推荐的本机工作流（按风险从低到高）

```bash
cd /Users/i3eg1nner/code/cie/work/XiangShan

# 0) 一次性：安装依赖
brew install mill verilator          # mill 会自动读取 .mill-version=0.12.17

# 1) 纯语法/类型检查（最快，不 elaborate，不需要 verilator）
mill -i xiangshan.compile

# 2) 验证新 uop 拆分表（纯 Scala main，打印拆分结果，不生成硬件）
mill -i xiangshan.runMain xiangshan.backend.vector.Decoder.Split.SplitTable

# 3) 验证 latency 表
mill -i xiangshan.runMain xiangshan.backend.vector.LatDecoder

# 4) 单模块 Verilog（验证 elaborate 能过）
mill -i xiangshan.runMain xiangshan.backend.vector.Decoder.DecodeChannelsMain

# 5) 单个单元测试（需要 verilator）
mill -i xiangshan.test.testOnly xiangshan.backend.fu.vector.ByteMaskTailGenTest

# 6) yunsuan 侧（独立 build root）
cd yunsuan && mill -i YunSuan.test.runMain yunsuan.vector.GenTest
```

---

## 8. 配置变体（Config variants）

### 8.1 可用的顶层 Config

全部定义在 `src/main/scala/top/Configs.scala`（package `top`）：

| 类 | 行 | 备注 |
|---|---|---|
| `BaseConfig(n: Int)` | 70 | 基类 |
| `MinimalConfig(n: Int = 1)` | 93 | **最小**，见 §8.2 |
| `MediumConfig(n: Int = 1)` | 576 | deprecated，等同 DefaultConfig |
| `DefaultConfig(n: Int = 1)` | 583 | **默认**（`Makefile:50 CONFIG ?= DefaultConfig`） |
| `XSNoCTopConfig(n: Int = 1)` | 607 | NoC 顶层 |
| `XSNoCTopMinimalConfig(n: Int = 1)` | 613 | |
| `FpgaDefaultConfig(n: Int = 1)` | 631 | deprecated |
| 其余 | 441, 445, 467, 498, 569, 578, 591, 597, 602, 619, 625, 643, 658 | `MinimalL3DebugConfig` / `DefaultL3DebugConfig` / `FrontendDebugConfig` / `BackendV2Config` / `MinimalAliasDebugConfig` / `FuzzConfig` / `NoRobCompressionConfig` / `CVMConfig` / `CVMTestConfig` / `XSNoCDiffTopConfig` / `XSNoCDiffTopMinimalConfig` / `FpgaDiffDefaultConfig` / `FpgaDiffMinimalConfig` |

**仓库里没有名字叫 “Kunminghu” 的 Config 类**；“Kunminghu/KunminghuV3” 只作为
发布版本串出现在 `build.mill:189-192`。昆明湖 V2/V3 是 **分支与子模块 tag 的概念，不是 `--config` 选项**。

### 8.2 `--config` 的解析方式与精确取值

`src/main/scala/top/ArgParser.scala:61-68`：
```scala
def getConfigByName(confString: String): Parameters = {
  var prefix = "top." // default package is 'top'
  if (confString.contains('.')) { prefix = "" }
  val c = Class.forName(prefix + confString).getConstructor(Integer.TYPE)
  c.newInstance(1.asInstanceOf[Object]).asInstanceOf[Parameters]
}
```
—— **纯 Java 反射，没有白名单 `match`**。任何 `top` 包下、带单个 `Int` 构造参数的类都可直接用：
```
--config MinimalConfig
--config DefaultConfig
--config XSNoCTopConfig
--config XSNoCTopMinimalConfig
--config <完整包名.类名>     # 含 '.' 时不加 top. 前缀
```
不传 `--config` 时默认 `new DefaultConfig(1)`（`ArgParser.scala:69-70`）。
Makefile 侧：`make verilog CONFIG=MinimalConfig`（`Makefile:50`）。

### 8.3 哪个最小

**`MinimalConfig`**（`Configs.scala:93-296`）：`RobSize=48`、`RabSize=96`、
L2 `128KB`、LLC `4MB/8way`、L1D `32KB/4way`、更小的 BPU 表、更小的 ICache（`nSets=64`）、
更小的 LSQ / store-buffer / 发射队列 / 物理寄存器堆。
README 推荐的快速路径就是 `make emu CONFIG=MinimalConfig EMU_THREADS=2 -j10`（`README.md:134`）。

### 8.4 V 扩展是否可配

**所有 config 都强制开启 V，且无开关。**
`src/main/scala/xiangshan/Parameters.scala:305-308`：
```scala
def ISABase = "rv64i"
def ISAExtensions = Seq(
  "i", "m", "a", "f", "d", "c", "b", "v", "h",
  ...
```
`XSCoreParameters` 里 **没有 `HasVector` / `hasVector` 字段**，`top/Configs.scala` 里
**没有任何 `ISAExtensions` 的 override**。向量单元是流水线的固定组成部分，不是可选项。

### 8.5 VLEN / ELEN / XLEN

`src/main/scala/xiangshan/Parameters.scala:52-54`（`case class XSCoreParameters`）：
```scala
XLEN: Int = 64,
VLEN: Int = 128,
ELEN: Int = 64,
```
经 `HasXSParameter`（`Parameters.scala:657 def VLEN = coreParams.VLEN`）暴露给全后端。

**VLEN=128 就是默认值，且是唯一安全值。** 原因：

1. 没有任何 Config / YAML / CLI 能改它
   （`grep -n "VLEN" src/main/scala/top/*.scala` 零匹配；`ArgParser` / `YamlParser` 无 `--vlen`）。
2. **至少两处把 128 硬编码死，且不读 `coreParams.VLEN`**：
   - `src/main/scala/xiangshan/backend/fu/NewCSR/NewCSR.scala:46 final val VLEN = 128`
     （注释 `:48-50` 说明是 “macro 需要编译期字面量” 的妥协）
   - `src/main/scala/xiangshan/backend/vector/package.scala:23-24`
     ```scala
     trait HasVectorSettings { def VLEN = 128; def VLENB: Int = VLEN / 8; ... }
     ```
     被 14+ 个向量译码文件 mixin。
3. 多处直接传字面量 `128`：`Mgu.scala:210/226`、`MaskExtrator.scala:49`、`ByteMaskTailGenTest.scala:19/26`。
4. 仓库里 **没有任何 `require/assert` 检查 `VLEN == 128`**（我搜过 `VLEN == 128` / `VLEN != 128`；
   唯一与 VLEN 相关的 require 是 `backend/vector/Exu.scala:224` 和 `backend/float/FltExu.scala:205`
   的 `require(elemIdx.getWidth >= log2Up(VLEN))`，是消费端的位宽检查，不是取值约束）。

**结论：VLEN=128 是本项目的默认值且被硬编码加固；改成别的值不会 elaborate 失败，但会静默产生不一致的设计。
对本次比赛而言，VLEN=128 完全满足需求，不需要任何改动。**

---

## 9. 推荐方案与落地顺序

### 9.1 两条路线对比

| | **路线 A：VIMac 内新功能（推荐）** | 路线 B：全新 FuType `vdot` |
|---|---|---|
| opcode | `VIMacOpcode` 里加 `DOT = bb"100"`（op 字段 100~111 全空，不改 9 bit 宽度） | 新 `VDotOpcode` 家族 |
| FuType | 复用 `FuType.vimac`，**位宽不变** | `addType` → FuType 位宽 +1，波及全后端 bundle |
| FuConfig / VecFuConfig | 零改动（`VimacCfg` 已是 3 源 128 bit、`readV0/readVl/readVType`、`CertainLatency(2)`） | 全套新建 + `allConfigs` 注册 |
| ExeUnitParams | 零改动（`VimacCfg` 已在 `Parameters.scala:490 VFEX0`） | 必须改 `Parameters.scala` + `BackendParams.scala` |
| LatDecoder | 零改动（`VIMacOpcodes` 已在 `LatDecoder.scala:41`） | 必须加进 `LatDecoder.opcodes` |
| FuTypeField | 零改动 | 必须加 `case _: Opcode.VDotOpcodes.type => FuType.vdot` |
| WbFuBusyTable / 写回端口 | 零改动（共享 VFEX0 的 `VfWB(port=3,0)`） | 零改动（只要挂进已有 exu） |
| 风险 | `VIMacOpcode.getLat` 当前是整族常量 2（`Opcodes.scala:1838`），vdot 若需 3 拍要改成按位判断 | FuType 位宽变化、两处 `vecSchdParams` 必须同步、`Opcodes.updateWidth` 全局副作用 |

**强烈推荐路线 A。**

### 9.2 vdot 功能单元的推荐插入点

**硬件插入点（三选一，按侵入性从小到大）：**

1. **最推荐 —— `VIMac64bStage3` 里新增一条取位/归约路径**
   （`yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/VIMac64bStage3.scala:150-163`）。
   SEW=8 时 `sumFinalNonFixP` 已经是 8 段 ×19 bit，每段含一个 8×8 乘积；
   加一个 `isDot` 控制位，把每 4 段的 `x(15,0)` 符号扩展后相加（4 输入 16→32 bit 小加法树），
   再加上 `oldVd` 对应的 32 bit 元素。
   - 不碰 Booth 编码（`Stage1:40-49`）、部分积（`:84-93`）、Wallace 树（`:96-115`）、152-bit 全加器（`Stage2:52-63`）
   - 延迟仍是 2（与 `VIMacOpcode.getLat = 2` 一致，无需改 LatDecoder）
   - 需要把 `isDot` 从 `VIMac64bStage1.InCtrl` 一路透传到 Stage3（Stage1/2/3 的 `InCtrl`/`Out` bundle 各加一位）
   - 注意 `oldVd` 目前是作为 Wallace 树的一行压进去的（`Stage1:107 wallaceTreeGen.io.oldVd`），
     vdot 模式下要么关掉它改在 Stage3 末尾加，要么确保 oldVd 的 32-bit 对齐正确 —— **这是最需要仔细设计的一点**
2. **次推荐 —— `VIMacU.scala` 里并联一个 `VDot64b`**
   （`src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala:42 vimacs = Seq.fill(2)(Module(new VIMac64b))` 旁边）。
   完全独立的 8×8 乘法阵列 + 4 输入加法树，面积翻倍但零风险、零回归。
   出口在 `VIMacU.scala:111-121` 的 `out.ex(2).bits.data.vec` 处做 Mux。
3. 新建 `VDotWrapper extends VecFixLatFunc` —— 需要走路线 B，不推荐。

**软件（Chisel 配置）插入点清单**（路线 A + Zvqdotq 风格 SEW=32 语义）：

1. `yunsuan/.../encoding/Opcode/Opcodes.scala` `trait VIMacOpcode`（`:1725-1840`）
   - 加 `private val DOT = bb"100"`
   - 加 `val vdot_e32 = DvSvlS2vS1S3v(S2S, S1S, DOT, OP3, DV, E32)`（签名与 `vmacc_e32` 一致，`Opcodes.scala:1774`；`vmacc_e8` 在 `:1772`）
   - 加谓词 `def isVdot(implicit op: UInt): Bool = getOp === DOT && getOpMode === OP3`
   - **注意**：`isVmaccType`（`:1829`）等谓词不会误匹配 DOT，但 `VIMacU.scala:34 isMacc` 的语义要确认
2. `yunsuan/.../vectorIMAC/VIMac64bStage{1,2,3}.scala` —— 透传 `isDot` + 新增归约路径
3. `src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala` —— 新增 `isDot` 解码并连到 `mod.in.ex0.bits.ctrl`
4. `src/main/scala/xiangshan/backend/decode/isa/Instructions.scala`
   - 加 `def VDOT_VV :BitPat = BitPat("b<func6>???????????000?????1010111")`（OPIVV）
   - 加进 `object VType` 的转发 def 与 `allWithNames`（`:1809` 附近 + `:2186` 附近）
   - func6 从 §1.5 的 22 个空闲 OPIVV 槽里选，建议 `111000`（RVV 保留区的低位，冲突概率最小）
5. `src/main/scala/xiangshan/backend/vector/Decoder/InstPattern/VecArithInstPattern.scala`
   在 OPIVV 分支（`:12-123`）插入：
   ```scala
   case s"111000" => new VecIntVVVVPattern()
     with V2_VecNormal with V1_VecNormal with V3_VecNormal_SrcDest with SL_Dot // VDOT.VV
   ```
   并新增 `sealed trait SL_Dot extends SewLmulType`（`:1053` 附近）
6. `src/main/scala/xiangshan/backend/vector/Decoder/DecodeFields/VecDecodeChannel/SewLmulRangeField.scala:22-37`
   加 `case _: SL_Dot => { case (sew, _) => sew == 32 }`
7. `src/main/scala/xiangshan/backend/vector/Decoder/Split/SplitTable.scala`
   在 `opi11Table` 或新建 `opiDotTable` 里加 `VDOT_VV -> dup(null, null, vdot_e32, null)(_.S1v)`，
   并确保该表被合进 `table`（`:33-66 main` 可打印验证）

以上 7 步 **不需要碰**：`FuType.scala`、`FuConfig.scala`、`VecFuConfig.scala`、
`Parameters.scala`、`BackendParams.scala`、`LatDecoder.scala`、`FuTypeField.scala`、
`WbFuBusyTable.scala`、`Exu.scala`、`WbDataPath.scala`、`Src1/Src2/DestSelect.scala`、`VRegTypesField.scala`。

---

## 10. 风险与未知

### R1 —— 【高】V2 向量区域的 mask（v0）通路尚未接线
`src/main/scala/xiangshan/backend/vector/IssuePipe.scala:199-202`：
```scala
  //to do

  is2Next.bits.data.v0.foreach(_ := 0.U)
```
v0 被 **硬写 0**。再看 `Exu.scala:153`：
```scala
mgu.in.data.mask := Fill(vlenb, context.ctrl.vm.get) | context.data.v0.get // Todo: use vlenb v0
```
`V0()` 是 VLEN=128 位（`backend/fu/vector/Bundles.scala:199-202`），而 `mask` 只有 `vlenb=16` 位，
Chisel 会静默截断；且 **缺少按 EEW 从元素 mask 展开到字节 mask 的那一步**（V1 的
`ByteMaskTailGen.scala:72 MaskExtractor(vlen)(maskUsed, vsew)` 做的事）。
**影响**：当前 V2 区域里 `vm=0`（带 mask）的向量算术指令结果是错的；vdot 继承这个缺陷。
**行动**：比赛若只测 `vm=1`（无 mask）可暂时回避；否则需要自行补齐
（参考 `NewMgu.scala:11-42` 把 `VecDataToMaskDataVec` + `ByteMaskTailGen` 接进 `Exu`）。
**UNVERIFIED**：没有确认这是否是 master 上的已知临时状态还是另有补丁路径。

### R2 —— 【高】vdot 的语义尚未在队内定稿，两种选择代价差一个数量级
- **语义 A（Zvqdotq 风格，SEW=32，源 32-bit 元素内含 4×int8）**：寄存器 1:1，解码侧几乎零新增（§9.2）。
- **语义 B（SEW=8，vl 以字节计，vd EEW=32，4:1 元素缩减）**：需要新建 `dupF4N` 拆分助手，
  且 **`Func.VecSpecialData` 只有 `normal`(VLEN) 和 `narrow`(VLEN/2) 两档，没有 VLEN/4**
  （`backend/vector/fu/Func.scala:150-167`），`Exu.scala:114-122 eewOHEx` 也只支持 2 倍加宽。
  需要改 `Func` 的输出 bundle + `Exu` 的 EEW 推导 + `needNarrowOut` 分类，diff 面显著扩大。
**行动**：**尽早与评委/规范对齐，强烈建议走语义 A。**

### R3 —— 【中】本机 macOS/aarch64 无法做全系统验证
- `ready-to-run` 子模块的 NEMU/Spike `.so` 极可能是 x86_64 Linux ELF（**UNVERIFIED**，该子模块未初始化）
- `difftest/libso.mk:35` 用 GNU `-shared`，`scripts/Makefile.pdb:47-48` 用 GNU `find -printf` 与 ELF `$ORIGIN`
- CI 无任何 macOS runner
**行动**：本机只做 `mill -i xiangshan.compile` + 单模块 elaborate + ChiselSim 单测；
全系统 difftest 必须在 Linux x86_64（容器或远端机）上跑。

### R4 —— 【中】JDK 25 与工具链兼容性未验证
仓库没有 pin JDK；本机是 Homebrew OpenJDK **25.0.2**，而 Mill 0.12.17 / Scala 2.13.17 /
Chisel 7.13.0 的官方测试矩阵通常止于 JDK 21。**行动**：第一步就跑 `mill -i xiangshan.compile`；
失败则切 JDK 17/21（`brew install openjdk@21` + `JAVA_HOME`）。

### R5 —— 【中】Zvknh 先例是“半成品”，不能整套照抄
`VSha256cCfg` / `VSha256msCfg` **没有出现在任何 `ExeUnitParams` 的 `fuConfigs` 里**
（`Parameters.scala:483-545` 与 `BackendParams.scala:770-800` 是仅有的两处，均无），
也 **不在 `LatDecoder.opcodes`**（`LatDecoder.scala:36-46`），
且 `VSha256cWrapper extends VecPipedFuncUnit`（V1 基类）而非 `VecFixLatFunc`（V2 基类）。
**行动**：译码侧（Instructions / Extensions / InstPattern / SplitTable / Opcodes）照抄 Zvknh；
执行侧（Func 基类 / exu 挂载 / LatDecoder）**必须照抄 `VIMacU` + `VimacCfg`**。

### R6 —— 【中】`VIMacOpcode.getLat` 是整族常量
`yunsuan/.../Opcodes.scala:1838 override def getLat(opcode: Opcode): Int = 2`。
若 vdot 的累加树放不进 2 拍，必须把它改成按 opcode 位判断的形式（参考 `VIAluOpcode`，`:1640-1649`），
这会同时重算 vmacc/vmul 的表项（值不变所以安全），但要重新跑
`mill -i xiangshan.runMain xiangshan.backend.vector.LatDecoder` 核对。
另外 `Func.scala:56-60` 有硬断言：同一个 `Func` 一周期只能有一个输出级有效。

### R7 —— 【低】`Latency()` / `Opcode()` 的位宽是全局最大值
`yunsuan/.../Opcodes.scala:133-143 object Latency` 与 `:194-196 Opcodes.updateWidth`。
新增编码位宽超过现有最大值会让 `Opcode()` 整体变宽，影响所有带 `fuOpType` 的 bundle。
路线 A（在 VIMacOpcode 的空闲 op 值里加）**不触发**这个问题（9 bit 不变）。

### R8 —— 【低】`vstart != 0` 在 V2 算术路径不支持
`backend/vector/fu/VecFunc.scala:35 protected def vstart = 0.U`，
`Exu.scala:154-155` 注释明确 “vstart is always 0 for vector arith instruction”，`mgu.in.data.begin := 0.U`。
对应译码字段 `IsVstartForceZeroField.scala`。vdot 继承此限制（通常可接受）。

### R9 —— 【低】VLEN 的双真源
`xiangshan/Parameters.scala:53 VLEN: Int = 128` 与
`backend/vector/package.scala:23 def VLEN = 128`（`HasVectorSettings`）
以及 `backend/fu/NewCSR/NewCSR.scala:46 final val VLEN = 128` 三处各自独立，
**没有任何 assert 把它们绑在一起**。VLEN=128 时无影响；本次比赛不改 VLEN 即可。

### R10 —— 开放问题（需要外部确认）
1. `vdot.vv` 的官方/比赛规定编码到底是什么？是否就是 RISC-V `Zvqdotq` 的 `vqdot.vv`？
   （仓库内无规范文件，**UNVERIFIED**；若是 Zvqdotq，编码应在 **OPMVV** 的
   `101000/101010/101100/101110` 四个空槽里，而非题面所说的 OPIVV。）
2. 累加源 vd 的溢出语义：32-bit 回绕 还是 饱和？影响是否需要 `VxsatWen`。
3. 符号性：`vdot`（有符号）/`vdotu`（无符号）/`vdotsu`（混合）是否都要做？
   `VIMacOpcode` 的 `[8]=vs2Sign [7]=vs1Sign` 两位已经预留好，三个变体可共用一个 `DOT` op 值。
4. yunsuan 的 `VIntAdder64b.scala` 是否真的实现了 `WADD4U`（4 输入加宽加法）硬件？
   **UNVERIFIED**，未逐行核对，但 `vwadd4u_e8` opcode 确实存在（`Opcodes.scala:1414`）且被
   `SplitTable.scala:676-687 wredu` 使用 —— 值得先读这个模块，可能可直接复用做累加树。
5. 比赛的验证流程是什么？本仓库 **零测试覆盖 vsha2/zvknh**，向量指令的功能验证全部在仓库外
   （NEMU/Spike difftest），本机 macOS 跑不了（R3）。
