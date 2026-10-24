# 昆明湖 V2（`kunminghu-v2`）向量单元集成侦察报告 — vdot 指令族

| 项 | 值 |
|---|---|
| 目标仓库 | `/Users/i3eg1nner/code/cie/work/XiangShan-kmhv2` |
| 分支 / HEAD | `kunminghu-v2` / `a4eeaab` |
| yunsuan 子模块 HEAD | `9559211 build: bump chisel 6.7.0` |
| 侦察方式 | 只读（`ls` / `grep` / `sed -n` / `cat`），**未执行任何 mill / sbt / make / verilator**；未修改 `work/` 下任何文件 |
| 结论可信度 | 每条结论均附 `绝对路径:行号`；无法核实者显式标注 **UNVERIFIED** |

> **工作树状态提示**：侦察期间 `yunsuan/src/test/csrc/test_driver.cpp` 存在一处未提交改动（新增 `YS_FUTYPE` / `YS_FUOPTYPE` 环境变量以锁定被测 FU，便于定向测试），系并行作业的同事所为，非本次侦察产生。本报告中引用的该文件行号以**上游版本**为准，实际行号可能因此偏移约 16 行。

> **与旧报告的关系**：`docs/_recon/xiangshan-vector-integration.md` 针对的是 `master`（KunminghuV3），其核心假设（`src/main/scala/xiangshan/backend/vector/` 重写向量单元）在 v2 上**不成立**——该目录在本树中不存在（已核实：`ls src/main/scala/xiangshan/backend/vector` 返回 `No such file or directory`）。本文档全部结论均在 v2 上重新核实，未从旧报告拷贝任何断言。

---

## 0. v2 向量单元总体布局（核实结果）

```
src/main/scala/xiangshan/backend/
├── decode/
│   ├── VecDecoder.scala          # 向量指令译码表（OPIVV/OPIVX/OPIVI/OPMVV/.../VLD/VST）
│   ├── Instructions.scala        # XiangShan 自定义 BitPat（Zvbb / Zimop）
│   ├── DecodeUnit.scala          # 简单指令译码 + vpu 控制位生成 + decode_table 汇总
│   ├── DecodeUnitComp.scala      # 复杂指令 uop 拆分（2082 行，switch(typeOfSplit)）
│   ├── UopInfoGen.scala          # numOfUop / numOfWB / lmul 计算
│   ├── VecExceptionGen.scala     # 向量非法指令检查
│   └── isa/bitfield/RiscvInst.scala  # 指令位域（isOPIVV / isVecArith / ...）
├── fu/
│   ├── FuConfig.scala            # FuConfig 定义（VialuCfg / VimacCfg / VppuCfg / VipuCfg ...）
│   ├── FuType.scala              # one-hot FuType 枚举
│   ├── vector/                   # 通用向量基础设施（**活**）
│   │   ├── VecPipedFuncUnit.scala  Mgu.scala  Mgtu.scala  ByteMaskTailGen.scala
│   │   ├── Bundles.scala  Utils.scala  VecSrcTypeModule.scala  VecNonPipedFuncUnit.scala
│   │   └── VIPU.scala / VIMacU.scala / VIAluFix.scala / VFPU.scala / VPerm.scala / VPUSubModule.scala  ← **全部被注释掉的死代码**
│   └── wrapper/                  # 真正例化的 FU 包装器（**活**）
│       ├── VIAluFix.scala  VIMacU.scala  VIPU.scala  VPPU.scala  VIDiv.scala
│       └── VFALU.scala  VFMA.scala  VCVT.scala  VFDivSqrt.scala  VSet.scala ...
└── Parameters.scala（在 src/main/scala/xiangshan/）  # ExeUnitParams: VFEX0..VFEX4
```

**关键核实**：`src/main/scala/xiangshan/backend/fu/vector/{VIPU,VIMacU,VIAluFix,VFPU,VPerm,VPUSubModule}.scala` 六个文件的**非注释非空行数均为 0**，即整文件被注释。`FuConfig.scala` 通过 `import xiangshan.backend.fu.wrapper._`（`src/main/scala/xiangshan/backend/fu/FuConfig.scala:10`）引用的是 `wrapper/` 下的实现。**所有修改必须落在 `wrapper/`，不要改 `vector/` 下的同名死文件。**

YunSuan 子模块布局：

```
yunsuan/src/main/scala/yunsuan/
├── package.scala                 # OpTypeWidth=9；VipuType / VimacType / VialuFixType / Vfxxx 等 fuOpType 编码
├── encoding/
│   ├── VecInt.scala  VecFp.scala  VecDstType.scala  package.scala
│   └── Opcode/{VimacOpcode,VialuOpcode,VipuOpcode,VfCvtOpcode}.scala
├── vector/
│   ├── VectorALU/                # VIAlu.scala / Reduction.scala / VMask.scala / VIntFixpAlu.scala
│   │                             # VAluDecode.scala（VAluOpcode）/ VAluBundles.scala（VIFuInput/Output）
│   │                             # VIntAdder64b.scala / VIntMisc64b.scala / VFixPoint64b.scala / VIAluFWrapper.scala
│   ├── vectorIMAC/               # VIMac.scala / VIMac64b.scala / VIMac64b_noBooth.scala
│   ├── VectorPerm/ VectorConvert/ VectorIdiv/ VPERM/ vfsqrt/
│   └── VectorFloatFMA.scala      # 内含 private[vector] CSA3to2 / CSA4to2
└── util/{LookupTree,LiteralCat,ParallelMux,BitUtils,ClockGatedReg}.scala
```

---

## 1. 译码（Decode）

### 1.1 位模式声明的三个来源

| 来源 | 文件 | 说明 |
|---|---|---|
| rocket-chip 自动生成 | `/Users/i3eg1nner/code/cie/work/XiangShan-kmhv2/rocket-chip/src/main/scala/rocket/Instructions.scala` | RVV 1.0 全量 `BitPat`，如 `:830 VWREDSUM_VS`、`:831 VWREDSUMU_VS`、`:609 VMACC_VV`、`:717 VREDSUM_VS` |
| XiangShan 自定义 | `/Users/i3eg1nner/code/cie/work/XiangShan-kmhv2/src/main/scala/xiangshan/backend/decode/Instructions.scala` | `object Zvbb`（16 条）与 `object Zimop`。**这是新增自定义指令 BitPat 的正确落点** |
| 预译码 | `/Users/i3eg1nner/code/cie/work/XiangShan-kmhv2/src/main/scala/xiangshan/backend/decode/isa/bitfield/RiscvInst.scala` | `isVecArith`（`:93`）、`isOPIVV`（`:97`）、`OPCODE7Bit.VECTOR_ARITH = "b1010111".U`（`:196`） |

译码表汇总在 `/Users/i3eg1nner/code/cie/work/XiangShan-kmhv2/src/main/scala/xiangshan/backend/decode/DecodeUnit.scala:806-819`：

```scala
val decode_table: Array[(BitPat, List[BitPat])] = XDecode.table ++ FpDecode.table ++
  BitmanipDecode.table ++ ScalarCryptoDecode.table ++ XSDebugDecode.table ++ CBODecode.table ++
  SvinvalDecode.table ++ HypervisorDecode.table ++ VecDecoder.table ++ ZicondDecode.table ++
  ZimopDecode.table ++ ZfaDecode.table
require(decode_table.map(_._2.length == 15).reduce(_ && _), "Decode tables have different column size")
```

`VecDecoder.decodeArray` 在 `VecDecoder.scala:822-823` 由 `vset ++ opivv ++ opivx ++ opivi ++ opmvv ++ opmvx ++ opfvv ++ opfvf ++ opfff ++ vls` 拼成。

### 1.2 15 列译码输出的含义

`XSDecode.generate()`（`DecodeUnit.scala:94-111`）：

```scala
List(src1, src2, src3, BitPat(fu.U(FuType.num.W)), fuOp, xWen.B, fWen.B, (vWen || mWen).B,
     xsTrap.B, noSpec.B, blockBack.B, flushPipe.B, canRobCompress.B, uopSplitType, selImm)
```

寄存器号来自 `DecodeUnit.scala:858-866`：

```scala
decodedInst.lsrc(0) := inst.RS1          // = vs1
decodedInst.lsrc(1) := inst.RS2          // = vs2
decodedInst.lsrc(2) := Mux(isFMA, inst.FS3, inst.VD)   // = vd（旧值）
decodedInst.ldest   := inst.RD           // = vd
```

> **关键**：`case class OPIVV`（`VecDecoder.scala:28-45`）的 `src3` 默认值就是 `SrcType.vp`：
> ```scala
> case class OPIVV(fu: FuType.OHType, fuOp: BitPat, vWen: Boolean, mWen: Boolean, vxsatWen: Boolean,
>                  uopSplitType: BitPat = UopSplitType.VEC_VVV,
>                  src1: BitPat = SrcType.vp, src2: BitPat = SrcType.vp, src3: BitPat = SrcType.vp)
> ```
> 因此**所有 OPIVV 指令天然把 `vd` 作为第三源读入**。`vdotacc.vv` 需要的「vd 作第三源」在 OPIVV 格式下无需任何额外工作。相比之下 `OPMVV`（`VecDecoder.scala:78-91`）需要显式传 `vdRen = T` 才会把 `src3` 设为 `SrcType.vp`。

### 1.3 `vmacc.vv` 全链路（三源 OPMVV）

| 阶段 | 位置 | 内容 |
|---|---|---|
| BitPat | `rocket-chip/src/main/scala/rocket/Instructions.scala:609` | `VMACC_VV = BitPat("b101101???????????010?????1010111")`（funct6=`101101`, funct3=`010` OPMVV） |
| 译码表 | `src/main/scala/xiangshan/backend/decode/VecDecoder.scala:383` | `VMACC_VV -> OPMVV(T, FuType.vimac, VimacType.vmacc, F, T, F, UopSplitType.VEC_VVV)`（首参 `vdRen=T` → `src3=SrcType.vp`） |
| fuOpType | `yunsuan/src/main/scala/yunsuan/package.scala:386` | `def vmacc = LiteralCat(0.U(2.W), INT.S, INT.S, INT.S, FMT.VVV, VimacOpcode.vmacc)` |
| vpu 控制位 | `src/main/scala/xiangshan/backend/decode/DecodeUnit.scala:977-980` | `vmaInsts` 列表含 `VMACC_VV`，参与 `:1069` `decodedInst.vpu.isDependOldVd := ... \|\| isVma \|\| ...` |
| uop 拆分 | `src/main/scala/xiangshan/backend/decode/DecodeUnitComp.scala:359-367` | `VEC_VVV`：`lsrc(0)=vs1+i, lsrc(1)=vs2+i, lsrc(2)=vd+i, ldest=vd+i, uopIdx=i` |
| uop 数 | `src/main/scala/xiangshan/backend/decode/UopInfoGen.scala:201` | `UopSplitType.VEC_VVV -> lmul` |
| FU | `src/main/scala/xiangshan/backend/fu/FuConfig.scala:551-570` | `VimacCfg`（`FuType.vimac`，`new VIMacU(cfg)`） |
| FU 内部 | `src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala:99-121` | `mod.io.oldVd := ...`，`mod.io.isMacc := VimacOpcode.isMacc(opcode)` |

### 1.4 `vredsum.vs` 全链路（非扩宽归约）

| 阶段 | 位置 | 内容 |
|---|---|---|
| BitPat | `rocket-chip/.../Instructions.scala:717` | `VREDSUM_VS = BitPat("b000000???????????010?????1010111")` |
| 译码表 | `VecDecoder.scala:410` | `VREDSUM_VS -> OPMVV(T, FuType.vipu, VipuType.vredsum_vs, F, T, F, UopSplitType.VEC_VRED)` |
| fuOpType | `yunsuan/.../package.scala:259` | `def vredsum_vs = "b00111001".U(OpTypeWidth.W)`（= 57） |
| uop 数 | `UopInfoGen.scala:224` | `UopSplitType.VEC_VRED -> lmul` → **LMUL=1 时 1 个 uop** |
| uop 拆分 | `DecodeUnitComp.scala:871-926` | 仅在 `vlmulReg ∈ {001,010,011}` 时改写；LMUL=1（`vlmul=000`）**落到默认分支** |
| FU | `FuConfig.scala:604-619` | `VipuCfg`（`FuType.vipu`，`new VIPU(cfg)`，latency = `CertainLatency(2)`） |
| FU 译码 | `src/main/scala/xiangshan/backend/fu/wrapper/VIPU.scala:61` | `BitPat(VipuType.vredsum_vs) -> List(BitPat(VAluOpcode.vredsum), uSew, uSew, uSew)` |
| 数据通路 | `yunsuan/.../VectorALU/VIAlu.scala:35` + `Reduction.scala` | `val vReduAlu = Module(new Reduction)` |

### 1.5 `vwredsum.vs` 全链路（**2× 扩宽归约，我们最接近的先例**）

| 阶段 | 位置 | 内容 |
|---|---|---|
| BitPat | `rocket-chip/.../Instructions.scala:830-831` | `VWREDSUM_VS = BitPat("b110001???????????000?????1010111")`（**OPIVV**, funct6=`110001`）；`VWREDSUMU_VS = ...110000...` |
| 译码表 | `VecDecoder.scala:242-243` | `VWREDSUM_VS -> OPIVV(FuType.vipu, VipuType.vwredsum_vs, T, F, F, UopSplitType.VEC_VWW)` |
| fuOpType | `yunsuan/.../package.scala:268-269` | `vwredsumu_vs = "b01000001"`（65）、`vwredsum_vs = "b01000010"`（66） |
| uop 数 | `UopInfoGen.scala:229` | `UopSplitType.VEC_VWW -> Cat(lmul, 0.U(1.W))` = `2 × lmul` → **LMUL=1 时 2 个 uop** |
| uop 拆分 | `DecodeUnitComp.scala:1502-1523` | 见 §2.3 |
| 非法检查 | `VecExceptionGen.scala:140-143, 193, 224, 232, 245` | `redWideningInst` 列表；`wnEewIllegal`（SEW=64 非法）、`vs2Eew = SEW+1`、`vdEew = SEW+1`、`vdIsSingleElem` |
| FU 译码 | `wrapper/VIPU.scala:70-71` | `BitPat(VipuType.vwredsum_vs) -> List(BitPat(VAluOpcode.vredsum), sSew, sSew, sSew2)`（`sSew2` = 有符号、SEW+1） |
| FU 特判 | `wrapper/VIPU.scala:103, 141-143` | `needShiftVs1` + `Mux1H(... needShiftVs1 -> ZeroExt(vs1(127,64), 128) ...)` |
| 数据通路 | `yunsuan/.../VectorALU/Reduction.scala:63-64` | `val vwredsum_vs = opcode.isVredsum && srcTypeVs2(2).asBool && (vdType(1,0) === (srcTypeVs2(1,0) + 1.U))` |
| 测试 | `yunsuan/src/test/scala/vector/VectorALU/VIntFixpAluSpec.scala:904-913, 959-968` | 4 个 uop 的 LMUL=2/vl=32 用例 |

### 1.6 提及 `vwredsum` 的**全部**文件与角色

```
rocket-chip/src/main/scala/rocket/Instructions.scala:830-831        指令位模式（BitPat）
src/main/scala/xiangshan/backend/decode/VecDecoder.scala:242-243    OPIVV 译码表项 → FuType.vipu / VipuType / UopSplitType.VEC_VWW
src/main/scala/xiangshan/backend/decode/VecExceptionGen.scala:141   redWideningInst 列表 → EEW/EMUL/寄存器对齐/重叠合法性检查
src/main/scala/xiangshan/backend/fu/wrapper/VIPU.scala:70-71        VIAluDecoder 表：VipuType → (VAluOpcode, srcType2, srcType1, vdType)
src/main/scala/xiangshan/backend/fu/wrapper/VIPU.scala:103          needShiftVs1 —— 中间 uop 把 vs1 高 64 位搬到低位
src/main/scala/xiangshan/backend/fu/vector/VIPU.scala:72-73,122     **已整体注释的死代码副本**，不要修改
yunsuan/src/main/scala/yunsuan/package.scala:268-269                VipuType fuOpType 数值编码
yunsuan/src/main/scala/yunsuan/vector/VectorALU/Reduction.scala:63-64  RTL 内部识别 widening 归约
yunsuan/src/test/scala/vector/VectorALU/VIntFixpAluSpec.scala:904,909,959,964  chiseltest 用例（含注释行）
```

间接但同样关键（以 `VEC_VWW` 之名出现）：

```
src/main/scala/xiangshan/package.scala:794                UopSplitType.VEC_VWW = "b101100".U
src/main/scala/xiangshan/backend/decode/UopInfoGen.scala:229   numOfUop = 2 × lmul
src/main/scala/xiangshan/backend/decode/DecodeUnitComp.scala:1502-1523  uop 拆分逻辑
src/main/scala/xiangshan/backend/decode/DecodeUnit.scala:1063  isWritePartVd 判定含 VEC_VWW
```

---

## 2. Uop 拆分与 vl/LMUL

### 2.1 机制总览

- `UopSplitType`：6 位常量，定义在 `/Users/i3eg1nner/code/cie/work/XiangShan-kmhv2/src/main/scala/xiangshan/package.scala:767-816`（注意：**不在** `backend/decode/` 下）。
- 复杂指令判定：`UopInfoGen.scala:248` `isComplex := isVecArith || isVecMem || isAmoCAS`；`DecodeUnit.scala:1085` `uopInfoGen.io.in.preInfo.isVecArith := inst.isVecArith`，而 `isVecArith` 仅看 opcode 是否为 `OP_V`（`isa/bitfield/RiscvInst.scala:93-95`）。**所有 `opcode=1010111` 的指令都会走复杂译码通路**，新指令无需额外登记。
- uop 个数：`UopInfoGen.scala:198-243` 的 `MuxLookup(typeOfSplit, 1.U)`。
- 实际拆分：`DecodeUnitComp.scala:194-205` 先把 `csBundle(i)` 全部初始化为原始指令 `latchedInst`，再在 `switch(typeOfSplit)` 中按需改写。**未被改写的字段保持原指令语义**。
- `csBundle(0).firstUop := true.B`、`csBundle(numOfUop-1).lastUop := true.B`（`DecodeUnitComp.scala:207-208`）。
- `VECTOR_TMP_REG_LMUL`：临时物理向量寄存器基址，归约树的中间结果都写在这里。

### 2.2 元素级 vs 归约级的本质差别

| | 元素级（`VEC_VVV`，如 `vmacc.vv`） | 归约（`VEC_VRED` / `VEC_VWW`） |
|---|---|---|
| uop 数 | `lmul` | `lmul`（VRED）/ `2×lmul`（VWW） |
| 每个 uop 的源 | `vs1+i, vs2+i, vd+i` | 成对的 `vs2+2i` / `vs2+2i+1`，或上一级的临时寄存器 |
| 目的 | `vd+i`（逐段写） | 中间 uop 写 `VECTOR_TMP_REG_LMUL+i`，**只有最后一个 uop 写真正的 `vd`** |
| `srcType(2)` | `vp`（读旧 vd） | 中间 uop 置 `SrcType.DC`，最后一个 uop 置 `vp` |
| `vs1`（标量种子）参与时机 | 每个 uop | **只在最后一个 uop**：`csBundle(numOfUop-1).lsrc(0) := src1` |
| 结构 | 线性 | **跨 uop 的二叉归约树** |

### 2.3 `VEC_VWW` 拆分源码（`DecodeUnitComp.scala:1502-1523`）

```scala
is(UopSplitType.VEC_VWW) {
  for (i <- 0 until MAX_VLMUL*2) {
    when(i.U < lmul){                                   // 前 lmul 个 uop：直接吃 vs2 的各段
      csBundle(i).srcType(2) := SrcType.DC
      csBundle(i).lsrc(0) := src2 + i.U
      csBundle(i).lsrc(1) := src2 + i.U
      csBundle(i).ldest   := (VECTOR_TMP_REG_LMUL + i).U
      csBundle(i).uopIdx  := i.U
    } otherwise {                                       // 后 lmul 个 uop：两两合并临时结果
      csBundle(i).srcType(2) := SrcType.DC
      csBundle(i).lsrc(0) := VECTOR_TMP_REG_LMUL.U + Cat((i.U-lmul),0.U(1.W)) + 1.U
      csBundle(i).lsrc(1) := VECTOR_TMP_REG_LMUL.U + Cat((i.U-lmul),0.U(1.W))
      csBundle(i).ldest   := (VECTOR_TMP_REG_LMUL + i).U
      csBundle(i).uopIdx  := i.U
    }
    csBundle(numOfUop-1.U).srcType(2) := SrcType.vp      // 最后一个 uop：引入 vs1[0] 并写回真 vd
    csBundle(numOfUop-1.U).lsrc(0) := src1
    csBundle(numOfUop-1.U).lsrc(2) := dest
    csBundle(numOfUop-1.U).ldest   := dest
  }
}
```

**LMUL=1（`vlmul=000`，`lmul=1`）时 `numOfUop = 2×1 = 2`**：

- uop0：`lsrc(0)=vs2, lsrc(1)=vs2, srcType(2)=DC, ldest=tmp0, uopIdx=0` —— 对单个 vs2 寄存器做段内扩宽归约，结果以**部分和向量**形式留在 `tmp0`。
- uop1：`lsrc(0)=vs1（被 numOfUop-1 覆盖）, lsrc(1)=tmp0, lsrc(2)=vd, ldest=vd, uopIdx=1` —— 合并 `vs1[0]` 标量种子，产生最终结果写入 `vd[0]`。

### 2.4 `VEC_VRED` 拆分（`DecodeUnitComp.scala:871-926`）

- `vlmul=000`（LMUL=1）：**不进入任何 `when` 分支**，`csBundle(0)` 保持默认 = 原指令（`lsrc(0)=vs1, lsrc(1)=vs2, lsrc(2)=vd, ldest=vd, uopIdx=0`）。`numOfUop = lmul = 1`。
  → **`vredsum.vs` 在 LMUL=1 时就是 1 个 uop，一次 FU 通过完成全部跨 lane 归约**；YunSuan `Reduction` 内部用 CSA 树在 2 个周期内把 16 个 8 位元素压成 1 个。
- `vlmul=001`（LMUL=2）：`numOfUop=2`。uop0 把 `vs2+1` 与 `vs2` 成对归约到 `tmp0`；uop1 为默认分支 + `:882-887`（`vlmul(2)===0 && vlmul(1,0).orR`）覆写为 `lsrc(0)=vs1, lsrc(1)=tmp0, lsrc(2)=vd, ldest=vd`。
- `vlmul=010/011`：先两两配对，再级联成树（`:878-896`），最后一个 uop 同样引入 `vs1`。

> **跨 lane 归约由谁完成？** 树的「跨 uop」部分在译码阶段静态展开；「段内（128 位内部 16 个元素）」部分由 YunSuan `Reduction` 的 CSA 加法树在**单次 FU 通过**内完成（见 §5）。

### 2.5 `vd` 作为源的处理（`vmacc` 情形）

三处配合：

1. **译码**：`OPMVV(vdRen = T, ...)` → `src3 = SrcType.vp`（`VecDecoder.scala:78-91`）；OPIVV 默认即为 `vp`。
2. **寄存器号**：`DecodeUnit.scala:861` `lsrc(2) := Mux(isFMA, inst.FS3, inst.VD)`。
3. **优化开关**：`DecodeUnit.scala:977-980` 的 `vmaInsts` 列表 + `:1069`
   ```scala
   decodedInst.vpu.isDependOldVd := isVppu || isVecOPF || isVStore || (isDstMask && !isOpMask) ||
                                    isNarrow || isVlx || isVma || isFof || vstartIsNotZero
   ```
   该位在 `src/main/scala/xiangshan/backend/dispatch/NewDispatch.scala:319-328` 被消费：
   ```scala
   val isDependOldVd = fromRename(i).bits.vpu.isDependOldVd
   val isWritePartVd = fromRename(i).bits.vpu.isWritePartVd
   val ignoreTail  = vlIsVlmax && (vm =/= 0.U || vma) && !isWritePartVd
   val ignoreOldVd = vlBusyTable.io.read(i).resp && vlIsNonZero && !isDependOldVd && (ignoreTail || ignoreWhole)
   ```
   即：若 `isDependOldVd=0` 且尾部可忽略，Dispatch 会**丢弃对旧 vd 的依赖**以缩短关键路径。
   → **`vdotacc.vv` 必须加入 `vmaInsts`（或等价列表）**，否则旧 vd 可能不被读入。
4. **归约类**：`DecodeUnit.scala:1063` `isWritePartVd := uopSplitType ∈ {VEC_VRED, VEC_0XV, VEC_VWW}`，复用 `VEC_VWW` 即自动获得。

---

## 3. FU 注册

### 3.1 现状

`FuType`（`src/main/scala/xiangshan/backend/fu/FuType.scala`）是 **one-hot 枚举**（`OHEnumeration`，`:11`），`def num = this.values.size`（`:140`）。向量整数相关：

```scala
val vipu   = addType(name = "vipu")     // :54
val vialuF = addType(name = "vialuF")   // :55
val vppu   = addType(name = "vppu")     // :56
val vimac  = addType(name = "vimac")    // :57
val vidiv  = addType(name = "vidiv")    // :58
val vecOPI = Seq(vipu, vialuF, vppu, vimac, vidiv)   // :127
```

`FuConfig`（`src/main/scala/xiangshan/backend/fu/FuConfig.scala`）：

| Cfg | 行 | fuType | srcData | latency | destDataBits | 其它 |
|---|---|---|---|---|---|---|
| `VialuCfg` | `:532-549` | `vialuF` | `Vec,Vec,Vec,V0,Vl` | `CertainLatency(1)` | 128 | `writeVxsat`, `needSrcVxrm` |
| `VimacCfg` | `:551-570` | `vimac` | `Vec,Vec,Vec,V0,Vl` | `CertainLatency(2)` | 128 | `writeVxsat`, `needSrcVxrm` |
| `VppuCfg` | `:587-602` | `vppu` | `Vec,Vec,Vec,V0,Vl` | `CertainLatency(2)` | 128 | |
| `VipuCfg` | `:604-619` | `vipu` | `Vec,Vec,Vec,V0,Vl` | `CertainLatency(2)` | 128 | `writeIntRf = true`（为 `vmv.x.s`） |
| `VidivCfg` | `:572-585` | `vidiv` | 同上 | `UncertainLatency()` | 128 | `piped = false` |

分组：`FuConfig.scala:843-852`
```scala
def allConfigs = Seq(..., VialuCfg, VipuCfg, ...)                       // 注意：VimacCfg / VppuCfg 不在 allConfigs
def VecArithFuConfigs = Seq(VialuCfg, VimacCfg, VppuCfg, VipuCfg, VfaluCfg, VfmaCfg, VfcvtCfg)
```

执行单元绑定（`src/main/scala/xiangshan/Parameters.scala:446-458`）：

```scala
ExeUnitParams("VFEX0", Seq(VfmaCfg, VialuCfg, VimacCfg, VppuCfg), Seq(VfWB(0,0), V0WB(0,0)), ...)
ExeUnitParams("VFEX1", Seq(VfaluCfg, VfcvtCfg, VipuCfg, VSetRvfWvfCfg), Seq(VfWB(0,1), V0WB(0,1), VlWB(...), IntWB(1,1), FpWB(0,1)), ...)
ExeUnitParams("VFEX2", Seq(VfmaCfg, VialuCfg), ...)
ExeUnitParams("VFEX3", Seq(VfaluCfg), ...)
ExeUnitParams("VFEX4", Seq(VfdivCfg, VidivCfg), ...)
```

→ **`vimac` 只有 VFEX0 一个端口，`vipu` 只有 VFEX1 一个端口**；两者各自单发射。

### 3.2 方案 (a)：在现有 FU 内加一条「功能」

以 `vimac` 为例，需要改动的**完整**清单：

| # | 文件 | 改动 |
|---|---|---|
| 1 | `src/main/scala/xiangshan/backend/decode/Instructions.scala` | 新增 `object` 或在现有 object 内加 `def VDOT_VV = BitPat("b111001???????????000?????1010111")` 等 3 条 |
| 2 | `src/main/scala/xiangshan/backend/decode/VecDecoder.scala` | 在 `opivv` 数组加 3 行 `VDOT_VV -> OPIVV(FuType.vimac, VimacType.vdot, T, F, F, UopSplitType.VEC_VWW)` |
| 3 | `yunsuan/src/main/scala/yunsuan/package.scala`（`object VimacType`） | 新增 3 个 `fuOpType` 常量 |
| 4 | `yunsuan/src/main/scala/yunsuan/encoding/Opcode/VimacOpcode.scala` | 新增 opcode 值 + `isVdot(...)` 判定 |
| 5 | `src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala` | `VIMacSrcTypeModule` 增加 vdot 的 `vs2Type/vs1Type/vdType`；主体增加点积加法树与输出复用 |
| 6 | `yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/VIMac64b.scala` | 增加 16/8 路乘积输出端口（见 §4.4） |
| 7 | `src/main/scala/xiangshan/backend/decode/DecodeUnit.scala` | `vmaInsts` 加 `VDOTACC_VV`（使 `isDependOldVd` 为真） |
| 8 | `src/main/scala/xiangshan/backend/decode/VecExceptionGen.scala` | 加入 `redWideningInst` 类似列表，使 EEW/EMUL/重叠检查正确 |

**`FuConfig.scala` / `FuType.scala` / `Parameters.scala` / `NewDispatch.scala` / `IssueQueue` / `WbArbiter` 一律不动**（除非需要改 latency）。

### 3.3 方案 (b)：新增一个 `FuType`

额外必须改：

| 文件 | 改动 | 连带影响 |
|---|---|---|
| `fu/FuType.scala:54-58` | `val vdot = addType("vdot")` | **`FuType.num` +1 → `fuType` one-hot 字段整体加宽**，波及 `DecodedInst`、IQ entry、ROB entry、Bypass 网络、`FuTypeOrR` 所有用例 |
| `fu/FuType.scala:127` | `vecOPI` 加 `vdot` | 影响 `isVArith` / `isVArithMem` / `isVecOPI` |
| `fu/FuType.scala:232-263` | `functionNameMap` 加项 | 性能计数器命名 |
| `fu/FuConfig.scala` | 新增 `VdotCfg` + 加入 `VecArithFuConfigs`（`:850-852`） | |
| `Parameters.scala:446-458` | 把 `VdotCfg` 塞进某个 `ExeUnitParams`，或新开 VFEX5 | 新开端口 → 新的 `VfWB` 写回端口号、新的 `VfRD` 读端口号、IQ 条目数、唤醒网络全部要重排 |

### 3.4 建议：**方案 (a)，落在 `VIMacU` / `FuType.vimac`**

理由（按重要性排序）：

1. **最昂贵的硬件已经在那里**。16 路 8×8 有符号乘法阵列在 v2 上的唯一实现就是 `VIMacU` 里的 2× `VIMac64b`（Booth radix-4 + Wallace 树，`sew=8` 时每片 8 组 8×8，两片共 16 组）。若把 vdot 放到 `VIPU`，`VIPU`/`VIAlu` 内部**没有任何乘法器**（`VIAlu.scala:35-39` 只例化 `Reduction` 和 `VMask`），必须再造一套阵列 —— 既浪费面积，也直接违背「复用」评分项。
2. **`vdot4a.vv` 天然是 `VIMacU` 形状**：按元素、三源（vd 累加）、`VEC_VVV` 拆分、走 `Mgu` 做 tail/mask —— 与 `vmacc.vv` 完全同构。
3. **`VimacCfg` 无需任何字段改动**：已有 3 个向量源 + V0 + Vl、`destDataBits=128`、`writeVecRf/writeV0Rf`、`vconfigWakeUp/maskWakeUp`、`piped=true`。
4. **归约专属的部分是「可搬运的小块」**：`UopSplitType.VEC_VWW` 与 FU 无关（它只改 `lsrc/ldest/uopIdx`）；元素 0 定位逻辑只有 `Reduction.scala:644-647` 三行，照抄即可。
5. **编码空间够用**：`VimacType` 是 9 位（`yunsuan/package.scala:8 OpTypeWidth = 9`），字段划分为 `[8:7] pad / [6] vs2Sign / [5] vs1Sign / [4] vdSign / [3] format / [2:0] opcode`。`VimacOpcode` 3 位只用了 0..6，**`b111` 空闲**；再配合 2 个 pad 位可区分 3 条 vdot 指令。

**代价与缓解**：`VimacCfg.latency = CertainLatency(2)`（`FuConfig.scala:565`）。16 个 16 位乘积求和到 32 位需要额外的 CSA 树 + CPA，可能装不进现有 2 级。两条路：
- (i) 把加法树接在 `VIMac64b` 的 **carry-save 中间节点** `wallaceOutReg`（`VIMac64b.scala:178`，`Seq(2)(UInt(128.W))`）上，省掉现有的 8× `Adder_16b` 链（`:181-201`），在同一 stage 内完成 16→2 压缩 + 一次 32 位 CPA → 保持 latency=2。
- (ii) 改 `FuConfig.scala:565` 为 `CertainLatency(3)` —— 一行改动，但**会同时拉长 `vmul`/`vmacc`/`vsmul` 等所有 vimac 指令**。时序富余不足时的保底方案。

> 若评审更看重「归约语义归位」，备选是把 `vdot.vv`/`vdotacc.vv` 放 `VIPU`、`vdot4a.vv` 放 `VIMacU`。**不推荐**：三条指令本应共享同一套乘法阵列（MASTER_PLAN D2 明确要求），拆到两个 FU 会导致阵列翻倍。

---

## 4. YunSuan 数据通路

### 4.1 整数向量 MAC 模块层次

```
XiangShan  VIMacU (wrapper/VIMacU.scala:45)        ← 活
   ├── VIMacSrcTypeModule        (:18-43)          srcType/vdType 生成
   ├── VecDataSplitModule × 3    (:61-63)          vs2 / vs1 / oldVd 切成 64b/32b/16b/8b
   ├── VIMac64b × 2              (:64)             numVecModule = 128/64 = 2
   └── Mgu(128)                  (:65)             tail / mask / agnostic

YunSuan 独立顶层 VIMac (vectorIMAC/VIMac.scala:7)  ← 只给 YunSuan 自测用，XiangShan 不例化
   └── VIMac64b × 2              (:29)
       + 自带 TailGen/PrestartGen/MaskReorg (:60-90)

VIMac64b (vectorIMAC/VIMac64b.scala:12)
   Stage 0:  Booth radix-4 重编码 (:46-67) → partProd Vec(34)(128b) (:69-117)
             Wallace 3→2 树，除最后 3 级 (:120-167)
             ── RegEnable ── wallaceOut_mid_reg  (:168)  Seq(6)(128b)
   Stage 1:  Wallace 最后 3 级 (:178) → wallaceOutReg Seq(2)(128b)
             8 × Adder_16b 链，按 SEW 串/断进位 (:181-201) → sum_wo Vec(8)(16b)
             ── RegEnable ── walOut (:208)
   Stage 2:  按 SEW 截取 / highHalf (:216-222)、vsmul 饱和舍入 (:224-292)
             io.vd (:294)

VIMac64b_noBooth (vectorIMAC/VIMac64b_noBooth.scala:11)  ← **全树无人例化，死代码/备选实现**
```

`VIMac` 顶层注释 `// Latency of MAC is 2 cycles`（`VIMac.scala:13`），`io.out.valid := RegNext(RegNext(io.in.valid))`（`:14`）。与 `VimacCfg.latency = CertainLatency(2)` 一致。

### 4.2 整数向量 ALU / 归约模块层次

```
XiangShan  VIAluFix (wrapper/VIAluFix.scala:133)   ← 元素级整数/定点，不含归约
   ├── VIAluSrcTypeModule
   ├── VecDataSplitModule × 3
   ├── VIntFixpAlu64b × 2       (:144)
   ├── Mgu(128)                 (:148)
   └── Mgtu(128)                (:149)

XiangShan  VIPU (wrapper/VIPU.scala:88)            ← 归约 + mask 类
   ├── VIAluDecoder             (:106)   VipuType → (VAluOpcode, srcType2, srcType1, vdType)
   └── VIAlu                    (:107)   yunsuan.vector.alu.VIAlu
   （**没有 Mgu / Mgtu**：io.out.bits.res.data := vialu.io.out.bits.vd，:149）

YunSuan VIAlu (VectorALU/VIAlu.scala:11)
   ├── Reduction  (:35)
   ├── VMask      (:38)
   └── vs2Ext 路径（vmv.x.s）(:41-46)
   输出：vdFinal = Mux(isVmvxs, vs2ExtS2, Mux(isReduction, vReduAlu.vd, vMaskAlu.vd))  (:56-57)
   latency：in.valid → validS1(RegNext) → out.valid(GatedValidRegNext) = **2 cycles**  (:52-60)
```

`VectorALU/` 目录全量：`Reduction.scala`(765)、`VAluBundles.scala`(117)、`VAluDecode.scala`(113)、`VAluUtils.scala`(111)、`VFixPoint64b.scala`(271)、`VIAlu.scala`(66)、`VIAluFWrapper.scala`(86)、`VIFuParameters.scala`(10)、`VIntAdder64b.scala`(162)、`VIntFixpAlu.scala`(326)、`VIntMisc64b.scala`(589)、`VMask.scala`(374)、`VMaskSlice.scala`(43)。

### 4.3 opcode 编码与空闲值

#### `VAluOpcode`（`yunsuan/src/main/scala/yunsuan/vector/VectorALU/VAluDecode.scala:8-66`），宽度 **6 位**

已用 **0..55** 连续：`vadd=0 … vssra=32, vredsum=33, vredmax=34, vredmin=35, vredand=36, vredor=37, vredxor=38, vcpop=39, vfirst=40, vmsbf=41, vmsif=42, vmsof=43, viota=44, vid=45, vmvsx=46, vmvxs=47`，Zvbb `vbrev=48 … vwsll=55`。

> **空闲：56, 57, 58, 59, 60, 61, 62, 63（共 8 个）。**

注意 `VAluBundles.scala:38` `def isReduction = (op >= vredsum) && (op <= vredxor)`（即 33..38）。新 opcode ≥ 56 不会被识别为归约，**必须显式新增 `def isVdot` 并扩展 `VIAlu.scala:56-57` 的输出 Mux**（若走 VIPU 路线）。

#### `VimacOpcode`（`yunsuan/src/main/scala/yunsuan/encoding/Opcode/VimacOpcode.scala`），宽度 **3 位**

`vmul=000, vmulh=001, vmacc=010, vnmsac=011, vmadd=100, vnmsub=101, vsmul=110`。
> **空闲：仅 `b111`（1 个）。**

`VimacType`（`yunsuan/package.scala:364-412`）总宽 9 位，布局 `[8:7] pad = 0 / [6] vs2Sign / [5] vs1Sign / [4] vdSign / [3] format(VVV=0,VVW=1) / [2:0] VimacOpcode`。
已用值均满足 `pad == 00`，因此 **`[8:7] ∈ {01,10,11}` 的整个高半空间（384 个值）全空**，足以安置 3 条 vdot。

#### `VipuType`（`yunsuan/src/main/scala/yunsuan/package.scala:256-282`），字面量 8 位（字段 9 位）

已用（十进制）：57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 75, 76, 77, 78, 79, 80, 81, 83, 255(`dummy`)。
> **空闲区间：0–56、67–74、82、84–254（9 位字段理论上还有 256–510，但见下方约束）。** 推荐紧随 `vwredsum_vs(66)` 之后取 **67/68/69（`b01000011/b01000100/b01000101`）**，语义聚类最佳。
>
> ⚠️ **硬约束**：消费者 `VIAluDecoder` 把 `fuOpType` 声明成 **8 位**（`src/main/scala/xiangshan/backend/fu/wrapper/VIPU.scala:46` `val fuOpType = UInt(8.W)`），而 XiangShan 的 `FuOpType()` 是 9 位（`src/main/scala/xiangshan/package.scala:68 def FuOpTypeWidth = 9`）。**新 `VipuType` 值必须 ≤ 255**，否则要同时加宽 `VIPU.scala:46`。67–74 满足该约束。

#### `VipuOpcode`（`encoding/Opcode/VipuOpcode.scala`），6 位

`vredsum=33 … vid=45`。该 `class`（非 `object`）在主代码中无人使用 —— `wrapper/VIPU.scala:33` 导入的是 `yunsuan.vector.alu.VAluOpcode`。属于遗留定义。**UNVERIFIED：是否有其它消费者**（全树 grep 仅见定义处）。

#### `VialuOpcode.scala` / `VecInt.scala` / `VecDstType.scala`
与 `VIAluFix` 路径相关；若按建议走 `vimac` 路线，不需要改动。**本次未逐值枚举（UNVERIFIED）**。

### 4.4 可复用的 8×8 乘法结构（**本项目最关键的复用点**）

`VIMac64b` 在 `sew=8` 时，单片即做 **8 组并行有符号 8×8**；`VIMacU` 例化 2 片 → **16 组**，正好等于 VLEN=128 / SEW=8 的元素数。

**(1) Booth radix-4 重编码**（`VIMac64b.scala:46-67`）——按 SEW 分段，`sew=8` 时在每 4 个 booth 组（= 8 bit）边界强制断开：

```scala
class boothRecode(d: UInt) {
  val positive = !d(2) && d(1,0) =/= 0.U
  val negative =  d(2) && d(1,0) =/= 3.U
  val one      = d(1) =/= d(0)
  val double   = d(2) =/= d(1) && d(1) === d(0)
}
val vs1Booth3b = Wire(Vec(32, UInt(3.W)))
vs1Booth3b(0) := Cat(vs1(1, 0), false.B)
for (i <- 1 until 32) {
  if (i % 4 != 0)      { vs1Booth3b(i) := vs1(2*i+1, 2*i-1) }
  else if (i == 16)    { vs1Booth3b(i) := Mux(sew.is64, vs1(2*i+1, 2*i-1), Cat(vs1(2*i+1, 2*i), false.B)) }
  else if (i % 8 == 0) { vs1Booth3b(i) := Mux(sew.is64 || sew.is32, vs1(2*i+1, 2*i-1), Cat(vs1(2*i+1, 2*i), false.B)) }
  else                 { vs1Booth3b(i) := Mux(!sew.is8, vs1(2*i+1, 2*i-1), Cat(vs1(2*i+1, 2*i), false.B)) }
}
```

**(2) 分段部分积**（`:69-88`）——`calcPartProd(i, sew)` 用 `blockIdx = (2*i)/sew` 把第 `i` 个 booth 组定位到第 `blockIdx` 个 SEW 段，`BitsExtend(elementVs2, 2*sew, vs2_is_signed)` 完成符号扩展，移位结果 `(boothResult << shiftBits)(2*sew-1, 0)` **被截断在段内**，段外补零：

```scala
for (i <- 0 until 32) {
  partProd(i) := Mux1H(sew.oneHot, Seq(8,16,32,64).map(sew => calcPartProd(i, sew)))
}
```

**(3) 符号/补偿加数**（`:90-116`）——`partProd(32)` 处理所有负 booth 的 +1、无符号 vs1 的高位修正、`isSub` 的 +1；`partProd(33)` 在 `isMacc` 时注入 `oldVd`。

**(4) Wallace 树**（`:118-178`）——纯组合的 3→2 规约，关键在于**按 SEW 掩蔽进位，防止跨段串扰**：

```scala
cout(i) := add3_UInt(data(3*i), data(3*i+1), data(3*i+2))._1 &
           Mux1H(Seq(sew.is8  -> "h7fff7fff7fff7fff7fff7fff7fff7fff".U(128.W),
                     sew.is16 -> "h7fffffff7fffffff7fffffff7fffffff".U(128.W),
                     sew.is32 -> "h7fffffffffffffff7fffffffffffffff".U(128.W),
                     sew.is64 -> ~0.U(128.W) ))
```
`nAddendsSeq = nAddendsSeqGen(34)`（`:155`）→ 34 → 22 → 15 → 10 → 7 → 5 → 4 → 3（共 7 级）。前 4 级在 stage 0，后 3 级移到 stage 1 以缓解时序（`:166-178`）。

**(5) 最终 128+128 加法**（`:180-201`）——8 个 `Adder_16b` 按 SEW 串/断进位：

```scala
class Adder_16b(in1: UInt, in2: UInt, cin: UInt) {
  private val bits = Cat(0.U(1.W), in1, cin) + Cat(0.U(1.W), in2, cin)
  val (cout, out) = (bits(17), bits(16, 1))
}
...
} else { cin_wo(i) := Mux(sewS1.is8, false.B, cout_wo(i-1)) }   // sew=8 时 8 段完全独立
sum_wo(i) := adder_16b.out
```

> **结论：在 `sew=8` 且 `widen=0` 时，`sum_wo : Vec(8, UInt(16.W))`（`VIMac64b.scala:187`）正是 8 个完整的 16 位有符号乘积**（未截断）。现有代码在 stage 2 的 `vdS2`（`:216-222`）把它截成低 8 位实现 `vmul.vv`；**vdot 只需在截断之前把它引出来**。
>
> 两个可行抽头：
> - **抽头 A（低风险）**：新增 `val prod16 = Output(Vec(8, UInt(16.W)))`，直接驱动 `sum_wo`。两片 `VIMac64b` 共 16 个 16 位乘积 → 新建 CSA 树求和。代价：多一级加法。
> - **抽头 B（省一级）**：新增 `val prodCS = Output(Vec(2, UInt(128.W)))` 驱动 `wallaceOutReg`（`:178`，carry-save 形式，sew=8 时为 8 组 16 位 sum/carry）。vdot 路径跳过 `Adder_16b` 链，直接把 32 个 16 位 CS 项送入自建 CSA 树，只在最后做一次 32 位 CPA。
>
> 符号性由 `srcType(0)(2) / srcType(1)(2)` 控制（`VIMac64b.scala:36-37`），置 `s8` 即为有符号 8 位，**无需改动乘法器**。

**(6) 可直接复用的 CSA 原语**（`yunsuan/src/main/scala/yunsuan/vector/VectorFloatFMA.scala:1581` / `:1596`）：

```scala
private[vector] class CSA3to2(width :Int) extends Module{
  val io = IO(new Bundle() { val in_a, in_b, in_c = Input(UInt(width.W)); val out_sum, out_car = Output(UInt(width.W)) })
  io.out_sum := io.in_a ^ io.in_b ^ io.in_c
  io.out_car := Cat(((io.in_a & io.in_b) | (io.in_a & io.in_c) | (io.in_b & io.in_c))(width-2,0), 0.U)
}
private[vector] class CSA4to2(width :Int) extends Module{ ... }
```
`private[vector]` 的可见范围是 `yunsuan.vector` 及其子包，`yunsuan.vector.alu`（`Reduction.scala`）与 `yunsuan.vector.mac`（`VIMac64b.scala`）**都在范围内**，可直接 `Module(new CSA4to2(width = 32))`。`Reduction.scala` 的加法树正是用它们搭的（`:382, 397, 405, 428, 437, 445, 472, 482, 491, 499`）。

**(7) ⭐ 现成的通用 N:2 压缩器 —— vdot 加法树的最佳复用目标**
`/Users/i3eg1nner/code/cie/work/XiangShan-kmhv2/yunsuan/src/main/scala/yunsuan/vector/VectorFloatFMA.scala:1881-1942`：

```scala
private[vector] class CSA_Nto2With3to2MainPipeline(n :Int, width :Int, pipeLevel :Int) extends Module{
  val io = IO(new Bundle() {
    val fire    = Input(Bool())
    val in      = Input(Vec(n, UInt(width.W)))
    val out_sum = Output(UInt(width.W))
    val out_car = Output(UInt(width.W))
  })
  ...
  var CSA4to2Num = if(n_next==8 || n_next==4) n_next/4 else 0
  var CSA3to2Num = if(n_next==8 || n_next==4) 0 else n_next/3
  ...
  while (CSA4to2Num!=0 || CSA3to2Num!=0){
    ceng = ceng + 1
    if (ceng == pipeLevel) is_piped = true          // ← 流水切点可参数化
    ...
  }
  io.out_sum := (if (pipeLevel>ceng) RegEnable(in_next(0), fire) else in_next(0))
  io.out_car := (if (pipeLevel>ceng) RegEnable(in_next(1), fire) else in_next(1))
}
```

参数化的任意 N→2 Wallace 压缩器，**且支持在任意层插入流水寄存器**。`n=16` 时压缩路径为 16→11→8→4→2，共 **4 层**。
→ **`Module(new CSA_Nto2With3to2MainPipeline(n = 16, width = 32, pipeLevel = k))` 即为 vdot 所需的「16 个 32 位符号扩展乘积 → 1 对 (sum, carry)」压缩器**，`pipeLevel` 可用来精确调节关键路径以保住 `latency = 2`。现有唯一使用者是 `VectorFloatFMA.scala:452-454`。`private[vector]` 对 `yunsuan.vector.mac` / `yunsuan.vector.alu` 均可见。

**(8) `BoothEncoderF64F32F16`**（`VectorFloatFMA.scala:1645`，使用处 `:446-450`）—— 分 SEW 打包的 Booth 编码器，直接输出 `io.out_pp : Vec(n, UInt(w.W))` 喂给上面的 N:2 压缩器。这正是「分段乘法器 → 通用加法树」的成熟范式，是 vdot 数据通路的结构模板。

### 4.5 YunSuan 向量 FU 必须实现的 IO 契约

两种形态：

**(A) `ValidIO` 风格（`VIAlu` / `VIMac` / `Reduction` 顶层）**，定义在 `yunsuan/src/main/scala/yunsuan/vector/VectorALU/VAluBundles.scala:77-102`：

```scala
class VIFuInfo extends Bundle {
  val vm     = Bool()
  val ma     = Bool()
  val ta     = Bool()
  val vlmul  = UInt(3.W)
  val vl     = UInt(8.W)
  val vstart = UInt(7.W)
  val uopIdx = UInt(6.W)
  val vxrm   = UInt(2.W)
}
class VIFuInput extends Bundle {
  val opcode  = new VAluOpcode          // 6 位 op + 大量 isXxx 判定方法
  val info    = new VIFuInfo
  val srcType = Vec(2, UInt(4.W))       // 0: vs2   1: vs1；[3:2]=符号/浮点/mask 类别，[1:0]=EEW
  val vdType  = UInt(4.W)
  val vs1     = UInt(128.W)
  val vs2     = UInt(128.W)
  val old_vd  = UInt(128.W)
  val mask    = UInt(128.W)
}
class VIFuOutput extends Bundle { val vd = UInt(128.W); val vxsat = Bool() }
// 顶层 io：val in = Flipped(ValidIO(new VIFuInput)); val out = ValidIO(new VIFuOutput)
```

`srcType`/`vdType` 的 4 位编码由 `wrapper/VIPU.scala:120-122` 组装：
```scala
val srcTypeVs2 = Cat(0.U | typeop2(2), typeop2(1) | typeop2(2), Fill(2,typeop2(2)) | (sew + typeop2(0)))
```
其中 `uSew="b000"`（无符号、SEW）、`uSew2="b001"`（无符号、SEW+1）、`sSew="b010"`（有符号、SEW）、`sSew2="b011"`（有符号、SEW+1）、`mask="b100"`（`wrapper/VIPU.scala:54-58`）。

**(B) 扁平 64 位片风格（`VIMac64b`，XiangShan 直接例化的那种）**，`yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/VIMac64b.scala:12-30`：

```scala
val io = IO(new Bundle {
  val fire     = Input(Bool())
  val info     = Input(new VIFuInfo)
  val srcType  = Input(Vec(2, UInt(4.W)))
  val vdType   = Input(UInt(4.W))
  val vs1      = Input(UInt(64.W))
  val vs2      = Input(UInt(64.W))
  val oldVd    = Input(UInt(64.W))
  val highHalf = Input(Bool())
  val isMacc   = Input(Bool())
  val isSub    = Input(Bool())
  val widen    = Input(Bool())
  val isFixP   = Input(Bool())
  val vd       = Output(UInt(64.W))
  val vxsat    = Output(UInt(8.W))
})
```
XiangShan 侧的驱动代码在 `wrapper/VIMacU.scala:99-121`。**新 vdot 模块若要被 `VIMacU` 例化，建议采用形态 (B)（无 `ValidIO`，用 `fire` + 固定流水级）**，与现有风格一致。

### 4.6 已有的「乘加后归约」结构先例

| 结构 | 位置 | 评价 |
|---|---|---|
| `CSA_Nto2With3to2MainPipeline(n, width, pipeLevel)` | `yunsuan/.../vector/VectorFloatFMA.scala:1881-1942` | ⭐ **最佳复用目标**：参数化 N→2 压缩器 + 可参数化流水切点。`n=16, width=32` 直接可用 |
| `BoothEncoderF64F32F16(width, is_addend_expand_1bit)` | `yunsuan/.../vector/VectorFloatFMA.scala:1645`（用于 `:446-450`） | 分 SEW 打包 Booth 编码器 → `Vec(n, UInt(w.W))` 部分积，与上者组成完整乘加阵列 |
| `VIMac64b` 自身 | `yunsuan/.../vectorIMAC/VIMac64b.scala:12`，尤其 `:117` `partProd(33)` | 已经是「乘法 + Wallace 内融合累加」（`vmacc`）。但在 `sew=8` 时 Wallace 进位掩码（`:138`）把每 lane 限死在 16 位，**不能**直接用它做 32 位累加 |
| `FloatAdderReductionF32WidenF16` | `yunsuan/.../vector/FloatAdderReductionF32WidenF16.scala:6`（`StageN` 在 `:202`） | 浮点扩宽归约，但是**逐元素逐拍迭代**（`:28` `RegNext(U_Stage_N.io.stageN_out)`）而非树形；**全树无人例化（死代码）**。仅作为「带 is_init 握手的扩宽归约 FU」API 先例 |

**整数侧没有任何现成的 dot-product 模块。** 全树 `grep -rni "dotprod|dot_prod|\bvdot\b"` 零命中 —— opcode 层面完全从零开始。但加法树本体可以 100% 由 `CSA_Nto2With3to2MainPipeline` / `CSA3to2` / `CSA4to2` 搭成，无需自研压缩器。

---

## 5. 归约先例（`vredsum` / `vwredsum` 在 v2 上的真实实现）

### 5.1 模块与路径

```
译码：VecDecoder.scala:242-243 / :404-411  →  FuType.vipu + VipuType.vwredsum_vs + UopSplitType.VEC_VWW/VEC_VRED
拆分：DecodeUnitComp.scala:871-926 (VRED) / :1502-1523 (VWW)   ← 跨 uop 二叉树
发射：VFEX1（Parameters.scala:450）
FU ：wrapper/VIPU.scala:88  →  VIAluDecoder(:43) + VIAlu(:107)
RTL：yunsuan/.../VectorALU/VIAlu.scala:35  →  Module(new Reduction)
```

### 5.2 `Reduction` 的加法树结构（`yunsuan/src/main/scala/yunsuan/vector/VectorALU/Reduction.scala`）

- 输入 `vs12 = Cat(vs1, vs2)`（`:84`），共 256 位 = 32 字节；按 SEW 切成 `vs12m_bytes_sewN : Vec(2*vlenb=32, UInt(8.W))`（`:167-170`），并用 `vmask_bits = vmask >> shift`（`:86`）和 `vlRemain`（`:87`）把越界/被屏蔽的元素置为该运算的单位元（`zero/umax/smax/smin`，`:106-112`）。
- **加法（vredsum/vwredsum）**：纯 CSA（Wallace）树，按 SEW 分别实例化：
  - `sew=64`：1 个 `CSA3to2(64)`（`:382`）
  - `sew=32`：2 个 `CSA3to2(32)`（`:397, :405`）
  - `sew=16`：3 个 `CSA3to2(16)` + 1 个 `CSA4to2(16)`（`:428, :437, :445`）
  - `sew=8` ：4 个 `CSA4to2(8)` + 3 个 `CSA3to2(8)` + 1 个 `CSA4to2(8)`（`:472, :482, :491, :499`）→ 最终 `sum3_sew8 / carry3_sew8`（`:504-505`）
  即把 32 个 8 位数压到 1 对 (sum, carry)，**sum/carry 对跨流水级寄存**（`:671` `vd_reg := Cat(sum3_sew8, carry3_sew8)`），下一级再做 CPA。
- **比较（vredmax/vredmin）**：`compare_3to1` / `compare_2to1` 树（`:512-610`），底层用 `Adder_xb`（`:686-695`）。
- **逻辑（vredand/or/xor）**：`vd_logical : Vec(4, UInt(64.W))` 折半归约（`:264`）。

### 5.3 延迟

`Reduction` 内部 1 级寄存器（`:67 fire_reg_s1 = RegNext(fire)` 及一系列 `RegEnable(..., fire)`），`vd_reg` 是第 2 级。`VIAlu` 外层再做 `opcodeS1/validS1/opcodeS2`（`VIAlu.scala:52-60`），`io.out.valid := GatedValidRegNext(validS1)`。

> **归约路径总延迟 = 2 个周期**，与 `VipuCfg.latency = CertainLatency(2)`（`FuConfig.scala:614`）一致。

### 5.4 跨 uop 累加（LMUL>1）

`Reduction.scala:88-104` 用 `uopIdx` + `vlmul` 区分两类 uop：

```scala
val reduction_uop       = !widen && ((uopIdx === 0.U) || ((vlmul === 2.U) && (uopIdx < 2.U)) || ((vlmul === 3.U) && (uopIdx < 4.U)))
val widen_reduction_uop =  widen && ((uopIdx === 0.U) || ((vlmul === 1.U) && (uopIdx < 2.U)) ||
                                     ((vlmul === 2.U) && (uopIdx < 4.U)) || ((vlmul === 3.U) && (uopIdx < 8.U)))
val alu_uop             = !widen && (((vlmul === 1.U) && (uopIdx < 1.U)) || ((vlmul === 2.U) && (uopIdx < 3.U)) || ((vlmul === 3.U) && (uopIdx < 7.U)))
val widen_alu_uop       =  widen && ((uopIdx === 0.U) || ((vlmul === 1.U) && (uopIdx < 3.U)) ||
                                     ((vlmul === 2.U) && (uopIdx < 7.U)) || ((vlmul === 3.U) && (uopIdx < 15.U)))
```

- `*_reduction_uop`：做真正的树压缩，输出一个「部分和向量」。
- `*_alu_uop`：只做逐元素加（把两个临时向量按元素相加），输出 `alu_vd`。
- 最终输出二选一（`:683`）：
  ```scala
  io.out.vd := Mux(alu_uop_reg || widen_alu_uop_reg, alu_vd, red_vd_tail)
  ```

配合 `wrapper/VIPU.scala:103, 141-143`：对 `vwredsum*` 且 `vuopIdx < lmul` 的中间 uop，把 `vs1` 替换为 `ZeroExt(vs1(127,64), 128)`，即把 `Cat(vs1, vs2)` 的上半搬到参与归约的位置。

### 5.5 **结果如何落到 vd 的元素 0**（vdot 必须照抄的三行）

`Reduction.scala:644-647`：

```scala
val red_vd_tail_one = (vd_mask << vd_vsew_bits_reg) | (red_vd & (vd_mask >> (VLEN.U - vd_vsew_bits_reg)))
val red_vd_tail_vd  = (old_vd_reg & (vd_mask << vd_vsew_bits_reg)) | (red_vd & (vd_mask >> (VLEN.U - vd_vsew_bits_reg)))

val red_vd_tail = Mux(vl_reg === 0.U, old_vd_reg, Mux(ta_reg, red_vd_tail_one, red_vd_tail_vd))
```

其中 `vd_mask = ~0.U(VLEN.W)`（`:51`），`vd_vsew_bits = 8.U << vd_vsew`（`:46`）。语义：

| 条件 | vd 结果 |
|---|---|
| `vl == 0` | 整个 `old_vd` 保持不变（归约指令在 vl=0 时不写 vd） |
| `vta = 1` | 低 `SEW_vd` 位 = 归约结果，**其余位全 1** |
| `vta = 0` | 低 `SEW_vd` 位 = 归约结果，其余位 = `old_vd` |

> 这正是 `vdot.vv`（`vd.u32[0] = Σ…`，其余按 vta 处理）需要的全部尾部语义。把 `vd_vsew_bits_reg` 固定为 32、`red_vd` 换成点积结果即可。

### 5.6 掩码 / vl / vstart 在 `Reduction` 内部的处理

**掩码与 vl 被折叠成一次「单位元填充」**（`Reduction.scala:186-218`），以 sew=8 为例（`:186-191`）：

```scala
for (i <- 0 until 2*vlenb) {
  vs12m_bytes_sew8(i) := vs12_bytes(i)
  when(((!vm && !vmask_bits(i)) || (i.U >= vlRemainBytes)) && (reduction_uop || widen_reduction_uop)) {
    vs12m_bytes_sew8(i) := ele8
  }
}
```

`ele8/16/32/64`（`:113-164`）取该运算的单位元：加法/或/异或 → `zero`，`vredmax` → `smin`，`vredmin` → `smax`，`vredminu`/`vredand` → `umax`。
掩码源是原始 128 位 `io.in.bits.mask` 经 `vmask_bits = vmask >> shift`（`:86`）移位，**不走 `MaskExtract`**；`vlRemain = Mux(vl >= shift, vl - shift, 0.U)`（`:87`），`shift = Mux(widen, uopIdx << vsew_plus1, uopIdx << (vsew_plus1 + 1.U))`（`:85`）。

> ⚠️ **`Reduction.scala` 全文 0 次出现 `vstart`**（`grep -c vstart Reduction.scala` → `0`）。`ma` 虽在 `:29` 绑定但从未使用。**即：昆明湖 V2 的整数归约 RTL 根本不实现 `vstart != 0` 的 prestart 语义**，这与 §6.4 中「译码阶段对 `vstart != 0` 的向量算术指令直接报非法」是自洽的设计取舍。vdot 若沿用该结构，也将不支持 `vstart != 0`，必须在设计文档中显式声明。

---

## 6. Mask / tail / vstart

### 6.1 三个模块的分工

| 模块 | 文件 | 职责 |
|---|---|---|
| `ByteMaskTailGen(vlen)` | `src/main/scala/xiangshan/backend/fu/vector/ByteMaskTailGen.scala:46` | 由 `begin(vstart) / end(vl) / vma / vta / vsew / maskUsed / vdIdx` 生成 **字节粒度**的 `activeEn` 与 `agnosticEn` |
| `Mgu(vlen)` | `.../Mgu.scala:33` | 用 `activeEn/agnosticEn` 在 `vd / oldVd / 全 1` 三者间逐字节选择；另含 mask-destination（逐位）路径 |
| `Mgtu(vlen)` | `.../Mgtu.scala:29` | mask 目的指令专用：`idx >= vl` 的位**无条件置 1**（mask 目的尾部恒为 agnostic） |

`ByteMaskTailGen` 核心（`:63-78`）：
```scala
private val prestartEn = UIntToContLow1s(startBytes, maxVLMAX)
private val bodyEn     = UIntToContLow0s(startBytes, maxVLMAX) & UIntToContLow1s(vlBytes, maxVLMAX)
private val tailEn     = UIntToContLow0s(vlBytes, maxVLMAX)
...
private val activeEn   = Mux(io.in.begin >= io.in.end, 0.U(numBytes.W), bodyEnInVd & maskEn)
private val agnosticEn = Mux(io.in.begin >= io.in.end, 0.U(numBytes.W), maskAgnosticEn | tailAgnosticEn)
```

`Mgu` 的三路选择（`Mgu.scala:84-89`）：
```scala
for (i <- 0 until numBytes) {
  resVecByte(i) := MuxCase(oldVdVecByte(i), Seq(
    activeEn(i)   -> vdVecByte(i),
    agnosticEn(i) -> byte1s,
  ))
}
```

`MguIO`（`Mgu.scala:167-188`）+ `VecInfo`（`:190-200`）：
```scala
class VecInfo extends Bundle {
  val ta = Bool(); val ma = Bool(); val vl = Vl(); val vstart = Vl()
  val eew = VSew(); val vsew = VSew(); val vdIdx = UInt(3.W); val vlmul = UInt(3.W)
  val valid = Bool(); val narrow = Bool(); val dstMask = Bool()   // 后两项见 Mgu 使用处
}
```

### 6.2 新 FU 要做的事（以 `VIMacU` 为模板，`wrapper/VIMacU.scala:123-150`）

```scala
private val outEew = Mux(outWiden, outVecCtrl.vsew + 1.U, outVecCtrl.vsew)
mgu.io.in.vd            := outVd            // FU 的原始结果（未加尾部处理）
mgu.io.in.oldVd         := outOldVd         // 来自 VecPipedFuncUnit 的 outData.src(2)
mgu.io.in.mask          := outSrcMask       // 来自 VecPipedFuncUnit 的 outSrcMask
mgu.io.in.info.ta       := outVecCtrl.vta
mgu.io.in.info.ma       := outVecCtrl.vma
mgu.io.in.info.vl       := outVl
mgu.io.in.info.vlmul    := outVecCtrl.vlmul
mgu.io.in.info.valid    := io.out.valid
mgu.io.in.info.vstart   := outVecCtrl.vstart
mgu.io.in.info.eew      := outEew           // ★ 目的元素宽度（vdot4a 固定 e32）
mgu.io.in.info.vsew     := outVecCtrl.vsew
mgu.io.in.info.vdIdx    := outVecCtrl.vuopIdx
mgu.io.in.info.narrow   := 0.B
mgu.io.in.info.dstMask  := 0.B
mgu.io.in.isIndexedVls  := false.B

io.out.bits.res.data := mgu.io.out.vd
io.out.bits.res.vxsat.get := (outVxsat & mgu.io.out.active).orR
io.out.bits.ctrl.exceptionVec.get(ExceptionNO.illegalInstr) := mgu.io.out.illegal
```

**新 FU 只需要**：
1. 继承 `VecPipedFuncUnit(cfg)`（`src/main/scala/xiangshan/backend/fu/vector/VecPipedFuncUnit.scala:58`）—— 它已经把 `vs1/vs2/oldVd/vm/vma/vta/vsew/vlmul/vstart/vuopIdx/vxrm/srcMask/srcVConfig.vl` 全部准备好（`:13-56`），输出侧还有 `outCtrl/outData/outVecCtrl/outVl/outOldVd/outSrcMask/outLastUop`（`:68-91`），流水级数由 `override def latency = cfg.latency.latencyVal.get`（`:93`）自动生成。
2. 正确给出 `outEew`（目的 EEW）与 `vdIdx`，其余交给 `Mgu`。
3. mask 目的指令才需要 `Mgtu`（vdot 不需要）。

### 6.3 vdot 的特殊性：归约不走 `Mgu`

`VIPU`（`wrapper/VIPU.scala:149`）直接 `io.out.bits.res.data := vialu.io.out.bits.vd`，**完全不用 `Mgu`**。原因是归约的尾部语义是「只写元素 0，其余按 vta」，与 `Mgu` 的逐元素 active/tail 模型不同。

因此：
- **`vdot4a.vv`（按元素）→ 用 `Mgu`**，`eew = e32`，与 `vmacc` 完全同构。
- **`vdot.vv` / `vdotacc.vv`（归约）→ 不用 `Mgu`**，照抄 `Reduction.scala:644-647` 的 `red_vd_tail`。掩码通过「把被屏蔽的元素乘积置 0」实现（加法的单位元是 0，与 `Reduction.scala:106` 的 `zero(w)` 同理）。

### 6.4 ⚠️ vstart 的硬性限制

`src/main/scala/xiangshan/backend/decode/VecExceptionGen.scala:275`：

```scala
private val vstartIllegal = isVArith && (io.vstart =/= 0.U)
```
`:288` `io.illegalInst := instIllegal || villIllegal || eewIllegal || emulIllegal || regNumIllegal || regOverlapIllegal || vstartIllegal`

`isVArith = FuType.isVArith(fuType)`（`:54`）= `FuTypeOrR(fuType, vecArith)`（`FuType.scala:180`），`vecArith = vecOPI ++ vecOPF` 包含 `vipu` 与 `vimac`。

> **昆明湖 V2 对所有向量算术指令，只要 `vstart != 0` 就直接报 illegal instruction。** 这意味着 MASTER_PLAN P4 验收标准第 3 条中的「vstart≠0」用例**无法在全核 RTL 上以正常执行的方式验证**。
>
> 更进一步：`Reduction.scala` **全文根本没有读取 `vstart`**（见 §5.6），即归约数据通路本身也不实现 prestart 语义。`VIMac64b` 一侧则通过 `VIMac.scala:63 PrestartGen(io.in.bits.info.vstart, uopIdx, eewVd)`（YunSuan 独立顶层）或 XiangShan 的 `Mgu → ByteMaskTailGen.io.in.begin := info.vstart`（`Mgu.scala:62`）支持 prestart。
>
> **结论**：`vdot4a.vv`（走 `Mgu`）可以正确处理 `vstart`；`vdot.vv`/`vdotacc.vv`（归约）若照抄 `Reduction` 则不支持。无论哪条路，全核层面都被译码器挡住。该限制必须在交付文档中如实写明，并说明「vstart≠0」用例只在 L1（YunSuan FU 级，`vstart` 是 `VIFuInfo` 的普通输入端口 `VAluBundles.scala:83`，可自由驱动）覆盖。

---

## 7. 编码空间证明（OPIVV, funct3=000, opcode=1010111）

### 7.1 枚举命令

```bash
cd /Users/i3eg1nner/code/cie/work/XiangShan-kmhv2

# (1) rocket-chip 中全部 OPIVV 位模式（17 个任意位 + funct3=000 + 5 位 vd + 1010111）
grep -oE 'def [A-Z0-9_]+ *= *BitPat\("b[01?]{17}000[01?]{5}1010111"\)' \
     rocket-chip/src/main/scala/rocket/Instructions.scala \
  | sed -E 's/def ([A-Z0-9_]+) *= *BitPat\("b([01?]{6})(.*)/\2 \1/' | sort | uniq

# (2) XiangShan 自定义（Zvbb）中的 OPIVV
grep -oE 'def [A-Z0-9_]+ *= *BitPat\("b[01?]{17}000[01?]{5}1010111"\)' \
     src/main/scala/xiangshan/backend/decode/Instructions.scala

# (3) 全树是否有 funct6=1110xx 的 OPIVV
grep -rnE 'BitPat\("b1110[01?]{2}[01?]{11}000[01?]{5}1010111"\)' --include="*.scala" .
```

### 7.2 输出（已实际执行）

**(1)+(2) 合并后的 42 个已占用 funct6**：

```
000000 VADD_VV        000001 VANDN_VV(Zvbb)  000010 VSUB_VV        000100 VMINU_VV
000101 VMIN_VV        000110 VMAXU_VV        000111 VMAX_VV        001001 VAND_VV
001010 VOR_VV         001011 VXOR_VV         001100 VRGATHER_VV    001110 VRGATHEREI16_VV
010000 VADC_VVM       010001 VMADC_VV/VVM    010010 VSBC_VVM       010011 VMSBC_VV/VVM
010100 VROR_VV(Zvbb)  010101 VROL_VV(Zvbb)   010111 VMERGE_VVM/VMV_V_V
011000 VMSEQ_VV       011001 VMSNE_VV        011010 VMSLTU_VV      011011 VMSLT_VV
011100 VMSLEU_VV      011101 VMSLE_VV        100000 VSADDU_VV      100001 VSADD_VV
100010 VSSUBU_VV      100011 VSSUB_VV        100101 VSLL_VV        100111 VSMUL_VV
101000 VSRL_VV        101001 VSRA_VV         101010 VSSRL_VV       101011 VSSRA_VV
101100 VNSRL_WV       101101 VNSRA_WV        101110 VNCLIPU_WV     101111 VNCLIP_WV
110000 VWREDSUMU_VS   110001 VWREDSUM_VS     110101 VWSLL_VV(Zvbb)
```

**空闲 funct6（22 个）**：
```
000011 001000 001101 001111 010110 011110 011111 100100 100110
110010 110011 110100 110110 110111
111000 111001 111010 111011 111100 111101 111110 111111
```

**(3) 输出为空** —— 全树没有任何 `funct6=1110xx` 的 OPIVV 位模式。
（`grep -rnE 'BitPat\("b1110'` 命中的全部是别的编码空间：`AMOMAXU_*`（opcode=0101111）、`FCLASS_*`/`FMV_X_*`（opcode=1010011）、`VAMOMAXU*`（0101111）、`VL8RE*_V`（0000111）、`VS8R_V`（0100111）、以及 `VFWMUL_VV = "b111000???????????001?????1010111"` / `VFWMUL_VF = "...101..."` —— 后两者 funct6=`111000` 但 **funct3 = 001/101（OPFVV/OPFVF）**，与 OPIVV 的 funct3=000 不冲突。）

### 7.3 判定

| funct6 | 指令 | 判定 |
|---|---|---|
| `111001` | `vdot.vv` | ✅ **FREE** |
| `111010` | `vdotacc.vv` | ✅ **FREE** |
| `111011` | `vdot4a.vv` | ✅ **FREE** |

整个 `1110xx`（`111000`–`111011`）与 `1111xx` 在 OPIVV 空间内全部空闲，`111100` 起还有 4 个备用位置。**无需备选方案。**

### 7.4 本证明的边界（必须在交付文档中声明）

1. 本证明仅覆盖**本仓库所实现的** RVV 1.0 子集。RVV 1.0 规范把 OPIVV 的部分 funct6 标为 reserved 而非 assigned；`1110xx` 在规范的 OPIVV 表中确为空白行。
2. **外部扩展冲突风险（UNVERIFIED）**：RISC-V 的 `Zvqdotq` 草案（`vqdot.vv` 等 int8 点积）也在争夺整数点积的编码空间。本仓库未实现 `Zvqdotq`，无法在树内核实其 funct6 分配。设计文档应声明 vdot 为**非标准自定义扩展**，并说明若将来与 `Zvqdotq` 冲突可平移到 `111100`–`111111`。
3. `funct3=000` 且 `vm` 位固定为 0 的「`*_VVM` 变体」（如 `VADC_VVM`）与非掩码变体共享 funct6，本枚举已把它们合并计数。

---

## 8. 构建 / 测试入口（v2）

> 以下全部为**读文件所得**，本次侦察未执行任何构建命令。

### 8.1 版本矩阵

| 项 | XiangShan 顶层 | YunSuan 子模块 |
|---|---|---|
| mill | **0.12.3**（`.mill-version`；CI `.github/workflows/emu.yml:508-511` 用 `jodersky/setup-mill@v0.3.0`） | **0.11.1**（`yunsuan/.mill-version`；CI `yunsuan/.github/workflows/main.yml:29-32`） |
| build.sc API | mill-0.12（`Task.Input`、`SbtTests`，`build.sc:132,299,316`） | mill-0.11（`import mill.modules.Util`，`yunsuan/build.sc:4`；`SbtModuleTests`，`:61`） |
| Scala | `2.13.15`（`build.sc:37`） | `2.13.15`（`yunsuan/build.sc:12`） |
| Chisel | `org.chipsalliance::chisel:6.7.0`（`build.sc:40`） | 同上（`yunsuan/build.sc:13`） |
| chiseltest | `edu.berkeley.cs::chiseltest:6.0.0`（`build.sc:42`，加到 `xiangshan` 于 `:319`） | 同上，且是 **main** 依赖（`yunsuan/build.sc:15,56`） |
| scalatest | 仅 `utility.test` 显式钉死 `3.2.7`（`build.sc:130`）；`xiangshan.test` 由 chiseltest 传递引入（**UNVERIFIED**） | `3.2.19`（`yunsuan/build.sc:16,67-69`） |
| firtool/CIRCT | 无版本钉死；`build.sc:68-73` 的 `resolveFirtoolDeps` 经 `firtool-resolver:1.3.0` 动态解析 chisel 6.7.0 自带版本；可用 `FIRTOOL` 环境变量覆盖（`Makefile:95-97`）（**具体版本号 UNVERIFIED**） | 同上 |
| JDK | 无 `java -version` 检查。CI 的 scalafmt job 用 temurin **11**（`emu.yml:630-633`） | CI 用 `olafurpg/setup-scala@v10`，未指定版本（**UNVERIFIED**） |
| JVM 堆 | `JVM_XMX ?= 40G`、`JVM_XSS ?= 256m`（`Makefile:81-82`）→ `-Djvm-xmx/-Djvm-xss`（`:85`）→ `build.sc:298-303` `forkArgs = Seq("-Xmx40G","-Xss256m")`；CI 覆盖为 `JVM_XMX=16g`（`emu.yml:532,550,568`） | **硬编码** `override def forkArgs = Seq("-Xmx128G", "-Xss256m")`（`yunsuan/build.sc:50`，`test` 继承于 `:63`） |

> **两个 `build.sbt` 均为失效遗留物**：顶层 `build.sbt:1-2`（chisel 3.4.3 / scala 2.12.10）引用了本检出中不存在的目录；`yunsuan/build.sbt:3,7,14`（scala 2.12.13 / chisel 3.5.1 / chiseltest 0.5.1）与 `build.sc` 完全矛盾。**一律用 mill。**
>
> **两个 build.sc 的 mill API 互不兼容**：不能用 0.12 构建 yunsuan 独立工程，也不能用 0.11 构建 XiangShan。

### 8.2 命令速查（**文件中的字面写法**）

```bash
# ── XiangShan（仓库根，mill 0.12.3）──────────────────────────
mill -i yunsuan.compile                       # 只编 yunsuan 源码（build.sc:140-144 定义 object yunsuan）
mill -i xiangshan.compile                     # Makefile:271-273 的 `make comp`
mill -i xiangshan.test.compile
make sim-verilog                              # Makefile:292-297 → top.XiangShanSim --target-dir build/rtl
mill -i xiangshan.test.runMain xiangshan.DecodeMain -td build --output-file DecodeUnit.v   # Makefile.test:3

# ── YunSuan 独立（cwd 必须是 yunsuan/，mill 0.11.1）──────────
mill YunSuan.compile                          # 模块名见 yunsuan/build.sc:73
mill YunSuan.test.test                        # == make test（yunsuan/Makefile:80-81）
mill YunSuan.test.runMain yunsuan.top.SimTop -td ./build --full-stacktrace --target verilog  # yunsuan/Makefile:10-12
make emu                                      # yunsuan/Makefile:69 → softfloat + verilator
./build/emu -O 10000                          # CI 用法（yunsuan/.github/workflows/main.yml:38-42）
```

**⚠️ `Makefile.test` 很可能是坏的**：它把模块写作 `XiangShan`（大写 X，`Makefile.test:3,8,12`），而 `build.sc:286` 声明的是 `object xiangshan`（小写）。mill 的模块解析区分大小写。正确形式应为 `mill -i xiangshan.test.test` / `mill -i xiangshan.test.testOnly xiangshan.DecodeUnitTest`。（未实际执行验证，但名称不匹配是确凿的。）

**⚠️ `yunsuan` 在 XiangShan 构建中没有 test 子模块**（`build.sc:140-144` 只有 `object yunsuan extends HasChisel`，无 `test`、无 chiseltest 依赖）。`mill -i yunsuan.test.test` **不会解析成功**。YunSuan 的 scalatest 只能在 `yunsuan/` 目录下用 mill 0.11.1 跑。

### 8.3 单模块出 Verilog 的现成入口

| 入口 | 位置 | 产物 |
|---|---|---|
| `object VerilogAlu` | `yunsuan/.../VectorALU/VIAlu.scala:63-66` | `emitVerilog(new VIAlu(), Array("--target-dir", "build/vifu"))` |
| `object VerilogRed` | `yunsuan/.../VectorALU/Reduction.scala:758-761` | `emitVerilog(new Reduction(), Array("--target-dir", "build/vifu"))` |
| `object VerilogVIMac` | `yunsuan/.../vectorIMAC/VIMac.scala:95-98` | `emitVerilog(new VIMac(), Array("--target-dir=build/vimac"))` |
| `object SimTop` | `yunsuan/src/test/scala/top/VectorSimTop.scala:400-404` | `ChiselStage.execute` + `FirtoolOption("--lowering-options=explicitBitcast")` |
| `object DecodeMain` | `src/test/scala/xiangshan/DecodeTest.scala:15-35` | XiangShan 的 `ArgParser.parse` + `ChiselStage.execute` |
| 内联 | `src/test/scala/xiangshan/backend/fu/vector/ByteMaskTailGenTest.scala:19` | `emitVerilog(new ByteMaskTailGen(128)(defaultConfig), Array("--target-dir","build/ByteMaskTailGen"))` |

> **MASTER_PLAN L0（mill 精化 + 出 Verilog）的最低成本路径**：在 YunSuan 里给新模块加一个 `object VerilogVDot extends App { emitVerilog(new VDot(), Array("--target-dir", "build/vdot")) }`，然后 `cd yunsuan && mill YunSuan.runMain yunsuan.vector.<pkg>.VerilogVDot`（注意 `VerilogAlu`/`VerilogRed`/`VerilogVIMac` 都在 **main** 源码树里，所以用 `YunSuan.runMain` 而非 `YunSuan.test.runMain`）。

### 8.4 YunSuan 的 verilator `make emu` 平台（**存在，已核实**）

`yunsuan/Makefile`：

| 目标 | 行 | 作用 |
|---|---|---|
| `$(TOP_V)` = `./build/SimTop.v` | `:10-12` | mill 精化 `yunsuan.top.SimTop` |
| `$(EMU_MK)` | `:55,58-61` | `verilator --cc --exe $(VERILATOR_FLAGS) -o ./build/emu -Mdir ./build/emu-compile <SimTop.v> <所有 cpp>` |
| `$(EMU)` = `./build/emu` | `:56,63-64` | `make -C build/emu-compile -j33 -f VSimTop.mk` |
| `emu` | `:69` | `emu: $(SOFTFLOAT) $(EMU)` |

Verilator 选项 `:47-52`：`--top-module $(TOP) --assert --output-split 500 --output-split-cfuncs 500`；波形 `EMU_TRACE=1|vcd|VCD` → `--trace`（`:27-30`）；多线程 `EMU_THREADS`（`:33-37`）。

> **⚠️ macOS 阻塞点**：`yunsuan/Makefile.softfloat:1-14` 在 Makefile 解析期 git-clone `berkeley-softfloat-3`，并把产物路径**硬编码**为 `build/Linux-x86_64-GCC/softfloat.a`（`SPECIALIZE_TYPE=RISCV`）。在 darwin/arm64 上 `make emu` 不能直接工作，需要改 `Makefile.softfloat` 的平台目录或在 Linux 容器内跑。这直接影响 MASTER_PLAN 的 L1/L3 层。

运行语法（`yunsuan/README.md:9`，解析在 `yunsuan/src/test/csrc/emu.cpp:22-44`）：
```
./build/emu [-C MAX_CYCLES] [-O MAX_OPERATIONS] [-s SEED] [--dump-wave] [-b begin_dump] [-e end_dump]
```
辅助脚本：`yunsuan/scripts/emu_parallel.py`（并行跑 N 个 emu，日志到 `./log`）、`yunsuan/scripts/log_analyse.py`。

### 8.5 其它环境旋钮

- XiangShan：`CONFIG ?= DefaultConfig`（`Makefile:60`）、`NUM_CORES ?= 1`（`:61`）、`ISSUE ?= E.b`（`:62`，校验于 `:64-67`）、`CHISEL_TARGET ?= systemverilog`（`:63`）、`JVM_XMX/JVM_XSS`（`:81-82`）、`FIRTOOL`（`:95-97`）、`BUILD_DIR = ./build`、`RTL_DIR = ./build/rtl`（`:19-20`）。
- **没有 `MILL_ARGS` 变量**；mill 侧变量名是 `MILL_BUILD_ARGS`（`Makefile:85`）。`build.sc:38` 要求环境变量 `MILL_WORKSPACE_ROOT`（mill 0.12 自动设置）。
- YunSuan：`TOP ?= SimTop`（`:3`）、`BUILD_DIR = ./build`（`:4`）、`EMU_TRACE`、`EMU_THREADS ?= 0`。

---

## 9. 现有向量单元测试

### 9.1 XiangShan `src/test/`（共 19 个文件，向量相关极少）

| 文件 | 类型 | 说明 |
|---|---|---|
| `src/test/scala/xiangshan/backend/fu/vector/ByteMaskTailGenTest.scala` | chiseltest + `emitVerilog` | **XiangShan 侧唯一的向量 FU 测试**。`:27-41` 只有 `poke`/`peek`+`println`，**没有 `expect`**，即只打印不断言 |
| `src/test/scala/xiangshan/backend/fu/VsetModuleMain.scala` | chiseltest，输入全组合遍历 | `:42-54` 生成笛卡尔积，`:63-70` 调 Scala 参考模型 `VsetRef.test(...)`，`:95-100` `expect(..., message)`。**XiangShan 侧「Scala golden model + expect」的最佳范本** |
| `src/test/scala/xiangshan/backend/fu/VsetRef.scala` | Scala 参考模型 | |
| `src/test/scala/xiangshan/backend/fu/VsetTop.scala` | DUT 包装 | |
| `src/test/scala/xiangshan/XSTester.scala` | 基类 | `class XSTester`（`:13-27`）、`HasTestAnnos`/`DumpVCD`/`UseVerilatorBackend`（`:29-39`） |
| `src/test/scala/xiangshan/DecodeTest.scala` | `object DecodeMain`（`:15`）+ `class DecodeUnitTest extends XSTester`（`:38`） | **vdot 的译码级测试应加在这里** |

其余为非向量基础设施：`cache/WpuTest.scala`、`top/{SimMMIO,SimTop}.scala`、`backend/{BackendMain,DataPathMain,SchedulerMain}.scala`、`backend/issue/{IssueQueueMain,DataArrayMain,MultiWakeupQueueMain}.scala`、`backend/fu/NewCSR/McorepwrCommitStuckCheckTest.scala`、`backend/rob/CommitStuckCounterTest.scala`、`frontend/FrontTrigger.scala`、`utils/GenPipeWithFlush.scala`、`fu/IntDiv.scala`。

### 9.2 YunSuan `yunsuan/src/test/scala/`

| 文件 | 行数 | 内容 |
|---|---|---|
| `vector/VectorALU/VAluTestUtils.scala` | 171 | `SrcBundle`、`CtrlBundle`、`IMac64bCtrlBundle`、`trait BundleGenHelper`、`object dataType`、`TestHarnessAlu/IMac/Perm` |
| `vector/VectorALU/VIAluWrapper.scala` | 22 | 包住 `yunsuan.vector.alu.VIAlu` 的 `Decoupled` 壳 |
| `vector/VectorALU/VIntFixpAluSpec.scala` | 1037 | `trait VAluBehavior` + `class VAluSpec` —— **含全部归约用例** |
| `vector/VectorALU/VIMacSpec.scala` | 251 | `class VIMacWrapper`（`:14-26`）+ `trait VIMacBehavior` + `class VIMacSpec`（`:247`） |
| `vector/VectorALU/VIMac64bSpec.scala` | 331 | `VIMac64bInput/Output` 束（`:13-28`）、`VIMac64bWrapper`（`:31-55`）、`class VIMac64bSpec`（`:326`） |
| `vector/VectorALU/VPermSpec.scala` / `VPermWrapper.scala` | 156 / 24 | 置换单元 |
| `vector/VectorTest.scala` | 196 | `object GenTest`、`class YunSuanTester`、11 个**纯精化冒烟测试**（只 `dut.clock.step(10)`，无激励无检查） |
| `vector/VFCvtWapper.scala` | 36 | 只有 `VFCVTTop` + 发射器，无用例 |
| `top/VectorSimTop.scala` | 404 | verilator emu 的 DUT 顶层 |

包名：`package yunsuan.vectortest.alu`（`VIntFixpAluSpec.scala:2`）。

### 9.3 YunSuan C++ golden model（`yunsuan/src/test/csrc/`，19 个文件）

```
main.cpp(34)  emu.cpp(255)  test_driver.cpp(564)
include/{emu.h(58), test_driver.h(92), gm_common.h(153), iotype.h(175), vpu_constant.h(379), vfpu_functions.h(604)}
golden_model/{gm_common.cpp(435), vector_integer_alu.cpp(328), vector_integer_aluF.cpp(164),
              vector_integer_divider.cpp(166), vector_permutation.cpp(1706), vector_float_base.cpp(52),
              vector_float_adder.cpp(167), vector_float_fma.cpp(125), vector_float_divider.cpp(75),
              vector_float_convert.cpp(214), scalar_float_convert.cpp(166)}
```

- **无 DPI-C**。C++ 通过 verilator 生成的 `VSimTop*` 对象**直接读写成员**（`test_driver.cpp:489-512`，如 `dut_ptr->io_in_bits_src_0_0`、`io_in_bits_fuOpType`、`io_in_bits_vinfo_vl`），信号名必须与 `yunsuan/src/test/scala/top/VectorSimTop.scala:46-78` 的 `VSTInputIO`/`VecInfoBundle` 严格对应。
- 用例结构体 `struct VecInput`（`include/iotype.h:13-29`）：4 个 128 位源（`uint64_t srcN[2]`）+ `fuType/fuOpType/uop_idx/sew/src_widen/widen/is_frs1/is_frs2/rm/rm_s` + 嵌套 `VecInfo{vstart,vl,vlmul,vm,ta,ma}`（`:4-11`）；输出 `struct VecOutput{uint64_t result[2]; uint32_t fflags[2]; uint64_t vxsat;}`（`:31-35`）。
- 激励**全随机**：`TestDriver::get_random_input()`（`test_driver.cpp:363-433`），`-s SEED` 控制（`emu.cpp:57-61`）。
- 比对：整结构体 `memcmp`（`test_driver.cpp:515-542`），失配 → `display()` 打印 REF/DUT → `EMU BADTRAP` → 重放同一用例并转波形。
- 模型基类 `VPUGoldenModel`（`include/gm_common.h:11-28`）：`get_expected_output(VecInput)` + `select_element(VecInput, idx)` + 四个纯虚 `calculation_e8/e16/e32/e64(ElementInput)`。整数 ALU 实现在 `golden_model/vector_integer_alu.cpp:12/91/171/251`（按 `fuOpType` 的 switch）。
- opcode 常量用 `binstoi("<8 位二进制串>")` 手工镜像在 `include/vpu_constant.h`（`:11-12` 注释明说 *"should keep same with chisel"*），并有 `*_ALL_OPTYPES` 列表供随机器取样。

> **⚠️ 对 vdot 的关键缺口**：emu 随机平台**目前根本不覆盖 `VIAlu`/归约通路**。
> - `SimTop` 例化的是 `VectorIntAdder`（`VectorSimTop.scala:158`）与 `VIAluFWrapper`（`:332`），**没有 `VIAlu`**。
> - `ALL_FUTYPES`（`vpu_constant.h:31`）不含 `VIntegerALUV2`，完整列表在 `:27` 被注释掉。
> - `VGMIntegerALUF::vialuF_calculation_vvv` 只实现了 `VADD_VV`/`VSUB_VV`，其余 `exit(1)`（`vector_integer_aluF.cpp:~85-88`）。
>
> **结论**：MASTER_PLAN 的 L1/L3 若要走 C++ golden model 差分路线，需要新增 SimTop DUT 实例 + 新 fuType + 新 GM 类，工作量不小；而 **chiseltest 硬编码向量路线（§9.4）是低摩擦路径**，且 `VAluSpec` 的归约块就是现成模板。

### 9.4 chiseltest 用例格式（vdot 照此写）

两个 case class（`yunsuan/src/test/scala/vector/VectorALU/VAluTestUtils.scala:13-31`）：

```scala
case class SrcBundle(vs2: String = "h0",
                     vs1: String = "h0",
                     old_vd: String = "h0",
                     mask: String = "hffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff")

case class CtrlBundle(vdType: Int = 0, srcTypeVs2: Int = 0, srcTypeVs1: Int = 0,
                      opcode: Int = 0, vm: Boolean = true, ma: Boolean = false, ta: Boolean = true,
                      vlmul: Int = 0, vl: Int = 16, vstart: Int = 0, uopIdx: Int = 0, vxrm: Int = 0)
```

要点：

1. 输入是 **128 位十六进制字符串**（允许下划线），在 `genVAluInput`（`:60-71`）里转 `.U(128.W)`。`SrcBundle` 位置参数顺序是 **(vs2, vs1, old_vd, mask)**。
2. **没有独立的 `vsew` 字段**。元素宽度与符号性由 `vdType / srcTypeVs2 / srcTypeVs1` 三个类型字段表达，编码见 `object dataType`（`:126-139`）：`u8=0, u16=1, u32=2, u64=3, s8=4, s16=5, s32=6, s64=7, f16=9, f32=10, f64=11, mask=15`。它们是 `CtrlBundle` 的前三个位置参数，故惯用写法 `vredsum.copy(s16, s8, s8, ...)` = (vdType, srcTypeVs2, srcTypeVs1)。
   → **`vdot.vv`（int8 → int32）应写作 `vdot.copy(u32, s8, s8, ...)`**，与 `vwredsum` 的 `(s16, s8, s8)` 同构。
3. opcode 以具名 `val` 注册在 `trait VAluBehavior` 顶部，如 `VIntFixpAluSpec.scala:56` `val vredsum = CtrlBundle(opcode = 33)`，数值必须与 `VAluOpcode`（`VAluDecode.scala:8-66`）一致。
4. 期望值由 `genVAluOutput(vd: String, vxsat: Boolean = false)`（`VAluTestUtils.scala:86-91`）**硬编码十六进制**，无 golden model、无随机。
5. 判定（`VIntFixpAluSpec.scala:127-134`）：
   ```scala
   fork { dut.io.in.enqueueSeq(inputSeq) }
   .fork { dut.io.out.expectDequeueSeq(outputSeq) }.join()
   dut.clock.step(1)
   ```
   `vMaskTest` 在 dequeue 前插 2 拍（`:1001-1006`）。初始化走 `TestHarnessAlu.test_init(dut)`（`VAluTestUtils.scala:141-148`，`setTimeout(2000)` + `initSource/initSink`）。
6. 注册：`class VAluSpec`（`:1026-1036`）里 `it should behave like vMaskTest()`。**目前只有 `vMaskTest()` 是启用的**，`vIntTest0..6` 全被注释掉。

**归约用例原文（我们最接近的先例）** —— `VIntFixpAluSpec.scala:904-908`（LMUL=2, vl=32 的 4 个 uop）：

```scala
// vwredsum lmul=2 vl=32
genVAluInput(SrcBundle("ha61d8bb6a61d8a7893e9353e93e93400", "ha61d8bb6a61d8a78", "h0", "ha740d125a740cfe8950c7aad950c7970"), vredsum.copy(s16, s8, s8, vm = false, ta = false, ma = false, vlmul = 1, vl=32)),
genVAluInput(SrcBundle("hca8638a6ca863768b851e22eb851e0f0", "hca8638a6ca863768", "h0", "ha740d125a740cfe8950c7aad950c7970"), vredsum.copy(s16, s8, s8, vm = false, ta = false, ma = false, vlmul = 1, vl=32, uopIdx = 1)),
genVAluInput(SrcBundle("h6ffc0fff4ffa6000000000078", "hffca00000000ffa6ffb8ffd700000068", "h0", "ha740d125a740cfe8950c7aad950c7970"), vredsum.copy(s16, s8, s8, vm = false, ta = false, ma = false, vlmul = 1, vl=32, uopIdx = 2)),
genVAluInput(SrcBundle("hffca0006ffc0ff9aff5effd7000000e0", "h5d4c31d65d4c30984b17db5e4b17da20", "hcba97e15cba97cd8b975279db9752660", "ha740d125a740cfe8950c7aad950c7970"), vredsum.copy(s16, s8, s8, vm = false, ta = false, ma = false, vlmul = 1, vl=32, uopIdx = 3)),
```

对应期望（`:959-963`）：

```scala
// vwredsum lmul=2 vl=32
genVAluOutput("h6ffc0fff4ffa6000000000078"),
genVAluOutput("hffca00000000ffa6ffb8ffd700000068"),
genVAluOutput("hffca0006ffc0ff9aff5effd7000000e0"),
genVAluOutput("hcba97e15cba97cd8b975279db975d95f"),
```

**要复刻的关键模式**：归约是多 uop 的；第 k 个 uop 的期望输出被原样作为第 k+1 个 uop 的 `vs2`（对比 `:959` 的输出 `h6ffc0fff4ffa6000000000078` 与 `:907` 的 `vs2`）；最终标量落在最后一个 uop 的 `vd` 低位；`old_vd` 携带标量种子；`ta=false, ma=false` 时期望值必须原样携带 `old_vd` 的高位。

此外，`VIntFixpAluSpec.scala:901-903 / :956-958` 还有 8 位 `vredsum`（LMUL=2, vl=32，2 个 uop）的用例；`:915-934` 覆盖 `vredand/or/xor/maxu/minu/max/min`。

---

## 10. v2 向量流水线（译码 → 重命名 → 分发 → 发射 → VIMacU/VIPU → Mgu → 写回）

```
                        指令 (32b)  opcode=1010111
                              │
            ┌─────────────────▼──────────────────────────────────────────────┐
            │ DecodeStage / DecodeUnit.scala                                 │
            │  decode_table = XDecode ++ ... ++ VecDecoder.table ++ ...      │  :806-819
            │   → fuType, fuOpType, srcType[0..2], uopSplitType, vWen        │
            │  lsrc(0)=RS1(vs1) lsrc(1)=RS2(vs2) lsrc(2)=VD ldest=RD         │  :858-866
            │  vpu.{vsew,vlmul,vta,vma,vm,vstart,isNarrow,isDstMask,...}     │  :1043-1077
            │  vpu.isDependOldVd  ← vmaInsts 等                              │  :1069
            │  vpu.isWritePartVd  ← VEC_VRED / VEC_0XV / VEC_VWW             │  :1063
            │                                                                 │
            │ UopInfoGen.scala  numOfUop = f(uopSplitType, lmul, vsew, nf)   │  :198-243
            │ VecExceptionGen.scala  illegalInst（EEW/EMUL/对齐/重叠/vstart） │  :288
            └─────────────────┬──────────────────────────────────────────────┘
                              │ isComplex
            ┌─────────────────▼──────────────────────────────────────────────┐
            │ DecodeUnitComp.scala   switch(typeOfSplit)                     │
            │   csBundle(i) := latchedInst（默认继承）                        │  :194-205
            │   VEC_VVV  : lsrc=vs1+i,vs2+i,vd+i ; ldest=vd+i                │  :359-367
            │   VEC_VRED : 成对归约 → VECTOR_TMP_REG_LMUL ; 末 uop 引入 vs1   │  :871-926
            │   VEC_VWW  : 2×lmul 个 uop，二叉树 ; 末 uop lsrc(2)=vd,ldest=vd │  :1502-1523
            │   firstUop / lastUop / uopIdx                                   │  :207-208
            └─────────────────┬──────────────────────────────────────────────┘
                              ▼
                     Rename (rename/Rename.scala) ──→ ROB
                              ▼
            ┌──────────────────────────────────────────────────────────────┐
            │ NewDispatch.scala                                             │
            │   ignoreTail  = vlIsVlmax && (vm||vma) && !isWritePartVd      │  :326
            │   ignoreOldVd = vlReady && vl!=0 && !isDependOldVd && ...     │  :328
            └─────────────────┬────────────────────────────────────────────┘
                              ▼
            ┌──────────────────────────────────────────────────────────────┐
            │ vfSchdParams (Parameters.scala:445-465)                      │
            │  IQ0 ─┬─ VFEX0  [VfmaCfg, VialuCfg, VimacCfg, VppuCfg]       │  :449
            │       └─ VFEX1  [VfaluCfg, VfcvtCfg, VipuCfg, VSetRvfWvfCfg] │  :450
            │  IQ1 ─┬─ VFEX2  [VfmaCfg, VialuCfg]                          │  :453
            │       └─ VFEX3  [VfaluCfg]                                   │  :454
            │  IQ2 ─── VFEX4  [VfdivCfg, VidivCfg]                         │  :457
            │  读端口 VfRD×3 + V0RD + VlRD（即 vs1/vs2/vd_old/v0/vtype&vl） │
            └───────┬──────────────────────────────┬───────────────────────┘
                    │ FuType.vimac                 │ FuType.vipu
                    ▼                              ▼
  ┌─────────────────────────────────┐  ┌──────────────────────────────────────┐
  │ wrapper/VIMacU.scala:45         │  │ wrapper/VIPU.scala:88                │
  │  extends VecPipedFuncUnit       │  │  extends VecPipedFuncUnit            │
  │  latency = 2 (FuConfig:565)     │  │  latency = 2 (FuConfig:614)          │
  │                                 │  │                                      │
  │  VIMacSrcTypeModule   :60       │  │  VIAluDecoder          :106          │
  │  VecDataSplitModule×3 :61-63    │  │   VipuType → (VAluOpcode,            │
  │  ┌───────────────────────────┐  │  │              srcType2/1, vdType)     │
  │  │ VIMac64b × 2        :64   │  │  │  ┌────────────────────────────────┐  │
  │  │  S0 Booth(32组)+Wallace   │  │  │  │ VIAlu              :107        │  │
  │  │     partProd Vec(34)×128b │  │  │  │  ├─ Reduction  (VIAlu.scala:35)│  │
  │  │  ── Reg ──                │  │  │  │  │   CSA3to2/CSA4to2 树        │  │
  │  │  S1 Wallace末3级 →        │  │  │  │  │   red_vd_tail (Red:644-647) │  │
  │  │     wallaceOutReg(2×128b) │  │  │  │  ├─ VMask       (VIAlu.scala:38)│ │
  │  │     8×Adder_16b →         │  │  │  │  └─ vs2Ext（vmv.x.s）          │  │
  │  │     sum_wo Vec(8)×16b ★   │  │  │  └────────────────────────────────┘  │
  │  │  ── Reg ──                │  │  │   （无 Mgu —— 尾部在 Reduction 内）  │
  │  │  S2 截取/饱和/舍入 → vd   │  │  │                                      │
  │  └───────────────────────────┘  │  │  io.out.res.data := vialu.out.vd :149│
  │  ┌───────────────────────────┐  │  └──────────────────────────────────────┘
  │  │ Mgu(128)            :65   │  │
  │  │  ByteMaskTailGen          │  │   ★ = vdot 抽头点（16 个 16 位有符号乘积）
  │  │   activeEn / agnosticEn   │  │
  │  │  逐字节 vd/oldVd/全1 三选 │  │
  │  └───────────────────────────┘  │
  │  io.out.res.data := mgu.vd :148 │
  └─────────────────┬───────────────┘
                    ▼
         WbArbiter / 写回 VfWB(port, 0|1) + V0WB  →  向量物理寄存器堆
                    ▼
                   ROB 提交
```

---

## 11. vdot 集成清单

按**实施顺序**编号。推荐插入点：`FuType.vimac` / `VIMacU`（理由见 §3.4）。
每项给出「改什么」与「照抄哪条现有指令」。

### 阶段 A — YunSuan 数据通路（先做，可独立出 Verilog 与跑 chiseltest）

| # | 文件 | 改动 | 照抄对象 |
|---|---|---|---|
| **A1** | `yunsuan/src/main/scala/yunsuan/encoding/Opcode/VimacOpcode.scala` | 新增 `def vdot = "b111".U(width.W)`（**3 位空间唯一空闲值**）；新增 `def isVdot(opcode: UInt) = opcode === vdot`；确认 `highHalf/isMacc/isSub/isFixP/overWriteMultiplicand` 对 `b111` 均返回 false（现有实现天然满足） | `vsmul = "b110"`（`:13`） |
| **A2** | `yunsuan/src/main/scala/yunsuan/package.scala`（`object VimacType`，`:364`） | 用 `[8:7]` pad 位区分三条指令：<br>`def vdot    = LiteralCat(1.U(2.W), INT.S, INT.S, INT.X, FMT.VVV, VimacOpcode.vdot)`<br>`def vdotacc = LiteralCat(2.U(2.W), INT.S, INT.S, INT.S, FMT.VVV, VimacOpcode.vdot)`<br>`def vdot4a  = LiteralCat(3.U(2.W), INT.S, INT.S, INT.S, FMT.VVV, VimacOpcode.vdot)`<br>新增 `def isVdot(t: UInt) = t(2,0) === VimacOpcode.vdot`、`def vdotVariant(t: UInt) = t(8,7)` | `def vmacc = LiteralCat(0.U(2.W), INT.S, INT.S, INT.S, FMT.VVV, VimacOpcode.vmacc)`（`:386`） |
| **A3** | `yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/VIMac64b.scala` | 新增输出端口暴露未截断乘积：<br>`val prod16  = Output(Vec(8, UInt(16.W)))` ← 驱动 `sum_wo`（`:187`，抽头 A）<br>或 `val prodCS = Output(Vec(2, UInt(128.W)))` ← 驱动 `wallaceOutReg`（`:178`，抽头 B，省一级加法）<br>**不改任何既有逻辑**，纯新增端口 | — |
| **A4** | 新建 `yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/VDotTree.scala` | 16×16b（或 32 个 CS 项）→ 32b 的可重构加法树：<br>- `vdot/vdotacc`：全 16 路求和 → 1 个 32 位标量<br>- `vdot4a`：4 组各 4 路求和 → 4 个 32 位结果<br>**首选直接例化 `Module(new CSA_Nto2With3to2MainPipeline(n = 16, width = 32, pipeLevel = k))`**（`VectorFloatFMA.scala:1881`，`private[vector]` 对 `yunsuan.vector.mac` 可见，`pipeLevel` 用于调节关键路径）；`vdot4a` 则用 4 个 `n = 4, width = 32` 的实例。符号扩展 16b→32b 后压缩，最后一次 32 位 CPA | ⭐ `CSA_Nto2With3to2MainPipeline`（`VectorFloatFMA.scala:1881-1942`，现有使用者 `:452-454`）；次选手工搭 `Reduction.scala:456-505`（sew=8 的 4×CSA4to2 + 3×CSA3to2 + 1×CSA4to2）；CSA 原语 `VectorFloatFMA.scala:1581/1596` |
| **A5** | `yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/VIMac.scala`（可选） | 若希望 YunSuan 独立平台也能测顶层，在 `VIMac` 里例化 `VDotTree` 并接到 `prod16` | `VIMac.scala:29-47` |
| **A6** | 新增 `object VerilogVDot extends App { emitVerilog(new VDotTree(), Array("--target-dir", "build/vdot")) }` | 满足 MASTER_PLAN L0「生成 vdot 功能单元 Verilog」 | `Reduction.scala:758-761` 的 `object VerilogRed` |

### 阶段 B — XiangShan FU 包装

| # | 文件 | 改动 | 照抄对象 |
|---|---|---|---|
| **B1** | `src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala`（`VIMacSrcTypeModule`，`:18-43`） | 为 vdot 覆写类型：`vs2Type = Cat(0.U, 1.U, VSew.e8)`、`vs1Type` 同、`vdType = Cat(0.U, 0.U, VSew.e32)`（vdot/vdotacc）；vdot4a 的 vs2/vs1 为 e8、vd 为 e32。注意现有 `widenIllegal` 判定（`:37`）不要误伤 | `private val vdType = Cat(vdIntType, Mux(widen, vsewX2, vsew))`（`:35`） |
| **B2** | `src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala`（主体，`:45-151`） | ① 例化 `VDotTree`，输入接 `vimacs(0/1).io.prod16`；<br>② `vdotacc` 把 `oldVd(31,0)` 作为加法树的额外加数（**不要**走 `isMacc`，否则 oldVd 会进 Wallace 树被逐元素加）；<br>③ 输出复用：`vdot/vdotacc` 走 `red_vd_tail` 式元素 0 定位（照抄 `Reduction.scala:644-647`，把 `vd_vsew_bits` 固定为 32）；`vdot4a` 走现有 `Mgu`，`outEew := VSew.e32`；<br>④ 掩码：`vdot/vdotacc` 用 `outSrcMask` 把被屏蔽 lane 的 16 位乘积清零后再入树 | `VIPU.scala:95-103`（needClearVs1/needShiftVs1 的特判风格）；`VIMacU.scala:123-150`（Mgu 接线） |
| **B3** | `src/main/scala/xiangshan/backend/fu/FuConfig.scala:565` | **仅当时序不满足时**把 `VimacCfg.latency` 从 `CertainLatency(2)` 改为 `CertainLatency(3)`。优先尝试抽头 B 保持 2 | `VipuCfg.latency = CertainLatency(2)`（`:614`） |

### 阶段 C — XiangShan 译码与拆分

| # | 文件 | 改动 | 照抄对象 |
|---|---|---|---|
| **C1** | `src/main/scala/xiangshan/backend/decode/Instructions.scala` | 新增 `object Vdot { def VDOT_VV = BitPat("b111001???????????000?????1010111"); def VDOTACC_VV = BitPat("b111010..."); def VDOT4A_VV = BitPat("b111011...") }` | `object Zvbb`（整个文件） |
| **C2** | `src/main/scala/xiangshan/backend/decode/VecDecoder.scala`（`import` 区 `:14` + `opivv` 数组 `:188-250`） | `import xiangshan.backend.decode.Vdot._`；新增三行：<br>`VDOT_VV    -> OPIVV(FuType.vimac, VimacType.vdot,    T, F, F, UopSplitType.VEC_VWW)`<br>`VDOTACC_VV -> OPIVV(FuType.vimac, VimacType.vdotacc, T, F, F, UopSplitType.VEC_VWW)`<br>`VDOT4A_VV  -> OPIVV(FuType.vimac, VimacType.vdot4a,  T, F, F, UopSplitType.VEC_VVV)` | `VWREDSUM_VS -> OPIVV(FuType.vipu, VipuType.vwredsum_vs, T, F, F, UopSplitType.VEC_VWW)`（`:243`）；`VSMUL_VV -> OPIVV(FuType.vimac, VimacType.vsmul, T, F, T)`（`:234`） |
| **C3** | `src/main/scala/xiangshan/backend/decode/DecodeUnit.scala:977-980` | 把 `VDOTACC_VV`（和 `VDOT4A_VV`）加入 `vmaInsts`，确保 `isDependOldVd = 1`（`:1069`） | `vmaInsts` 现含 `VMACC_VV` 等 |
| **C4** | `src/main/scala/xiangshan/backend/decode/VecExceptionGen.scala` | ① 新建 `dotInst = Seq(VDOT_VV, VDOTACC_VV)`，并入 `vdIsSingleElem`（`:245`）与 `vs1IsSingleElem`（`:233`，vdot 的 vs1 不是标量，需单独斟酌）；<br>② `vdEew` 对 vdot 应为 `e32`（`:246` 的 `vdEew` 逻辑需加分支）；<br>③ `vs2Eew`/`vs2Emul` 保持 SEW/LMUL；<br>④ 若要求 `vsew=8`（vdot/vdotacc）/ `vsew=32`（vdot4a），在 `eewIllegal`（`:195`）加判定 | `redWideningInst`（`:140-143`）及其在 `:193/:224/:232/:245` 的全部用法 |
| **C5** | 验证 uop 拆分无需改动 | `UopSplitType.VEC_VWW` 的 `numOfUop = 2×lmul`（`UopInfoGen.scala:229`）与拆分逻辑（`DecodeUnitComp.scala:1502-1523`）对 vdot 完全适用：中间 uop 做段内点积部分和，末 uop 合并并写 `vd`。**注意**：`VEC_VWW` 末 uop 会把 `lsrc(0)` 设为 `src1`（即 vs1）——对 vwredsum 这是标量种子，对 vdot 这是第二个向量操作数。**必须核实末 uop 的 vs1 来源是否被破坏，可能需要新增 `UopSplitType.VEC_VDOT`** | — |

### 阶段 D — 测试

| # | 文件 | 改动 | 照抄对象 |
|---|---|---|---|
| **D1** | `yunsuan/src/test/scala/vector/VectorALU/VIMacSpec.scala` 或新建 `VDotSpec.scala` | 新增 `trait VDotBehavior` + `def vDotTest()`；用 `SrcBundle`/`CtrlBundle` 硬编码十六进制用例；`class VDotSpec extends AnyFlatSpec with ChiselScalatestTester with BundleGenHelper with VDotBehavior` | `VIntFixpAluSpec.scala:878-1036` 的 `vMaskTest()` 与 `class VAluSpec` |
| **D2** | 同上 | 用例覆盖：正数 ≥20、负数 ≥20（含全负/混合）、边界（+127/-128/0、全 0、全 ±128、vl=0/1/15/16、vstart≠0、vm 掩码、vta 两种取值） | `VIntFixpAluSpec.scala:901-934` |
| **D3** | `src/test/scala/xiangshan/DecodeTest.scala` | 新增 vdot 的译码级断言（检查 fuType/fuOpType/uopSplitType/numOfUop） | `class DecodeUnitTest extends XSTester`（`:38`） |
| **D4** | （可选，高成本）`yunsuan/src/test/csrc/` + `VectorSimTop.scala` | 若要做 ≥10000 组随机差分：需在 `SimTop` 增加 vdot DUT 实例、在 `vpu_constant.h` 增 fuType/optype、新增 GM 类 | `golden_model/vector_integer_alu.cpp` + `include/gm_common.h:79-84` |

### 阶段 E — 交付

| # | 内容 |
|---|---|
| **E1** | `git diff` 生成 `rtl/patch/*.patch`（分别针对 XiangShan 与 yunsuan 两个仓库，**不修改 `work/` 的 git 历史**） |
| **E2** | `mill YunSuan.runMain ...VerilogVDot` 产出 `rtl/verilog/` |
| **E3** | 编码空间证明脚本 + 输出存入 `docs/stage2/` |

---

## 12. 风险与未知

### 12.1 高风险

| # | 风险 | 证据 | 缓解 |
|---|---|---|---|
| **R1** | **`VEC_VWW` 末 uop 会把 `lsrc(0)` 覆写为 `src1`（vs1）**。对 `vwredsum` 这是「标量种子寄存器」，对 `vdot.vv` 则 `vs1` 是真正的第二个向量操作数——末 uop 需要的是 `tmp` 与 `vs1` 的**原始段**，语义不同。直接复用 `VEC_VWW` 很可能产生错误的 uop 图 | `DecodeUnitComp.scala:1519-1522` | 大概率需要在 `src/main/scala/xiangshan/package.scala:767-816` 新增 `UopSplitType.VEC_VDOT`（空闲编码：`000001/000010/000011/000101/...`，需逐一核对），在 `UopInfoGen.scala` 加 `numOfUop` 项，在 `DecodeUnitComp.scala` 加 `is(...)` 分支。**这会把改动面从 3 个文件扩到 5 个** |
| **R2** | **`vstart != 0` 在全核 RTL 上必然触发非法指令异常**，`isVArith && vstart =/= 0` 无条件判非法 | `VecExceptionGen.scala:275` | MASTER_PLAN P4 的 `vstart≠0` 用例只能在 L1（YunSuan FU 级）完成；交付文档必须如实写明层级局限 |
| **R3** | **`VimacCfg.latency = CertainLatency(2)`**。16 个 16 位乘积 → 32 位需要额外 CSA 树 + CPA，可能放不进现有 2 级。改成 3 会拖慢所有 vimac 指令 | `FuConfig.scala:565`；`VIMac64b.scala:166-208` 的两级切分 | 优先走抽头 B（从 `wallaceOutReg` 取 carry-save，省掉 `Adder_16b` 链）。若仍不够，改 latency=3 并在报告中量化对 `vmul/vmacc` 的影响 |

### 12.2 中风险

| # | 风险 | 证据 | 缓解 |
|---|---|---|---|
| **R4** | **macOS/arm64 跑不了 YunSuan `make emu`**：softfloat 产物路径硬编码 `build/Linux-x86_64-GCC/softfloat.a` | `yunsuan/Makefile.softfloat:1-14` | 改 `Makefile.softfloat` 的平台目录，或在 Linux 容器内执行 L1/L3 |
| **R5** | **C++ golden model 差分路线成本远高于预期**：`SimTop` 根本没有 `VIAlu`/归约 DUT；`ALL_FUTYPES` 不含 `VIntegerALUV2`；`VGMIntegerALUF` 只实现了 `VADD_VV/VSUB_VV` | `VectorSimTop.scala:155-161, 309, 332, 354`；`vpu_constant.h:27,31`；`vector_integer_aluF.cpp` | MASTER_PLAN P4「≥10000 组随机差分」应改走 chiseltest + Scala 参考模型（如 `VsetModuleMain.scala` + `VsetRef.scala` 的范式），或在 emu 平台新增完整 DUT+GM（工作量大，需单列任务） |
| **R6** | `Makefile.test` 的模块名大小写错误（`XiangShan` vs `build.sc:286` 的 `xiangshan`），`make test` 很可能直接失败 | `Makefile.test:3,8,12` vs `build.sc:286` | 用 `mill -i xiangshan.test.test` 直接调用；交付脚本不要依赖 `Makefile.test` |
| **R7** | `yunsuan` 在 XiangShan 构建中**没有 test 子模块**，两个 build.sc 的 mill API（0.11 vs 0.12）不兼容 | `build.sc:140-144`；`yunsuan/build.sc:4,61` | YunSuan 单元测试必须在 `yunsuan/` 目录下用 mill 0.11.1 跑；需要本机同时具备两个 mill 版本（`.mill-version` 文件会自动选择） |
| **R8** | `yunsuan/build.sc:50` 硬编码 `-Xmx128G`。16GB 内存的本机可能直接 OOM 或被 JVM 拒绝 | `yunsuan/build.sc:50` | 本机验证前需确认 JVM 对超配 `-Xmx` 的行为；必要时在交付 patch 中调低（但这会改动 upstream 构建文件，需在文档中说明） |
| **R9** | **`vdot4a.vv` 的 vd 累加路径**：若复用 `isMacc` 让 `oldVd` 进入 Wallace 树（`VIMac64b.scala:116` `partProd(33)`），`oldVdReorg` 是按 SEW 分段扩展的；且 `sew=8` 时 Wallace 进位掩码（`:138` `"h7fff7fff..."`）把每 lane 限死在 16 位，无法承载 32 位累加 | `VIMac64b.scala:113-117, 136-143` | `vdot4a` 必须保持 `isMacc=0`，在 `VDotTree` 末级把 `oldVd` 的 4 个 32 位元素作为额外加数。（改 Wallace 掩码为 32 位 lane 的方案时序是否可行 —— UNVERIFIED） |
| **R10** | **`widen` 标志只支持 2× 扩宽**：`VIMac.scala:27` `widen = srcTypeVs1(1,0) =/= vdType(1,0)`，且 `:40-46` 会把输入重排成 `Cat(vs1_32b(i+2), vs1_32b(i))`。vdot 需要 **4×** 扩宽（8b→32b），**不能**复用 `widen` | `VIMac.scala:27, 40-46`；`VIMac64b.scala:216-222` 的 `vdS2` 选择 | 新增一个独立控制位（如 `isDot`），绕开 `widen` 的输入重排与 `vdS2` 选择，直接走新增的 `prod16`/`prodCS` 抽头 |
| **R11** | **`VIAluDecoder.io.in.fuOpType` 只有 8 位**（`wrapper/VIPU.scala:46`），而 `FuOpTypeWidth = 9`（`src/main/scala/xiangshan/package.scala:68`）。若走 VIPU 路线且选用 >255 的 `VipuType` 值会被静默截断 | `wrapper/VIPU.scala:46` | 走 vimac 路线则无关；走 vipu 路线时 `VipuType` 值取 67–74（≤255） |

### 12.3 未核实（UNVERIFIED）

| 项 | 说明 |
|---|---|
| U1 | **`Zvqdotq` 草案是否占用 OPIVV `1110xx`**。本仓库未实现 `Zvqdotq`，无法在树内核实。设计文档应声明 vdot 为非标准自定义扩展 |
| U2 | **`UopSplitType` 的空闲编码**。`src/main/scala/xiangshan/package.scala:767-816` 中 6 位空间已用约 45 个值，本次未逐值枚举空闲集 |
| U3 | **`VialuOpcode.scala` / `encoding/VecInt.scala` / `VecDstType.scala` 的逐值枚举**。本次未展开（走 vimac 路线则无需改动） |
| U4 | **`VipuOpcode` 类的消费者**。全树 grep 仅见其定义处（`encoding/Opcode/VipuOpcode.scala`），`wrapper/VIPU.scala:33` 导入的是 `yunsuan.vector.alu.VAluOpcode`。疑似遗留定义 |
| U5 | **`FloatAdderReductionF32WidenF16.scala`、`VIMac64b_noBooth.scala`、`VectorALU/VMaskSlice.scala` 全树无人例化**，用途不明（疑似历史/备选实现） |
| U5b | **`VIAlu.scala:83` 的 `DecodeLogic` 是否容忍 9 位 `BitPat(VipuType.*)` 字面量对 8 位 `io.in.fuOpType`**（未精化，无法确认是编译报错还是静默截断） |
| U5c | **把 `VIMac64b` 的 Wallace 进位掩码在 `sew=8` 时改成 32 位 lane（`"h7fffffff..."`）是否时序可行**，这将允许 `vdot4a` 在原树内完成累加 |
| U6 | **firtool/CIRCT 的确切版本号**（由 `firtool-resolver:1.3.0` 在解析期从 chisel 6.7.0 产物动态确定） |
| U7 | **`xiangshan.test` 实际使用的 scalatest 版本**（由 chiseltest 6.0.0 传递引入，未钉死） |
| U8 | **YunSuan CI 的 JDK 版本**（`olafurpg/setup-scala@v10` 默认值） |
| U9 | **`Reduction.scala` 中段 `:120-620` 的逐行语义**（`alu_vd`、`vd_logical`、`vs12m_bytes_sewN` 的精确构造）。本次只核实了加法树骨架、延迟与输出定位；若要完全复刻其掩码/vl 处理，需逐行通读 |
| U10 | **`Makefile.test` / `make test` 是否真的失败**（名称不匹配是确凿的，但未实际执行） |
| U10b | **`yunsuan/src/test/csrc/test_driver.cpp` 的未提交改动**由并行作业引入（`YS_FUTYPE`/`YS_FUOPTYPE` 环境变量），本报告引用该文件的行号基于上游版本，可能偏移 |
| U11 | **VIMac64b `sum_wo` 在 `widen=1` 时的语义**。本次只核实了 `widen=0, sew=8` 的路径；widen 路径（`VIMac.scala:40-44` 的 32 位交错重组）未展开 |

