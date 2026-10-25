# vdot 自定义向量点积指令族 —— 指令规范与微架构设计

| 项 | 值 |
|---|---|
| 对应赛题 | 阶段二 2.1「vdot 指令设计」 |
| 目标处理器 | XiangShan 昆明湖 V2（`kunminghu-v2`，HEAD `a4eeaab`） |
| 目标子模块 | `yunsuan` @ `9559211` |
| 代码树根（下文简称 `$XS`） | `<仓库根>/work/XiangShan-kmhv2`（由 `scripts/00_setup_env_host.sh` 按 pin 克隆） |
| 架构参数 | VLEN = 128，ELEN = 64，XLEN = 64 |
| 语义唯一事实来源 | `tests/golden/vdot_ref.c` + `vdot_ref.h` |
| 规范约束 | `docs/_plan/MASTER_PLAN.md` 决策 **D2** 与 **D2.1 语义裁定 S-1…S-9** |

## 0. 阅读约定

1. **证据标注**：每条关于现有代码的技术结论都给出 `文件:行号`。所有行号均由本文作者在上述 commit 上逐条打开文件核对，未从二手材料转抄。
2. **估算与实测的区分**：本文出现的所有逻辑级数、门数、面积、功耗均为**基于 Chisel 源码的静态结构计数或人工估算，不是综合/布局布线结果**。凡需要真实数值之处原先留有「待 P7 实测回填」的占位；P7 完成后，已实测的项回填为实测值并注明出处（`docs/stage3/22_基线实现与延迟加速分析.md`），仍无法实测的项改写为「未实测」并说明原因。文中出现「约」「量级」「估算」字样处，读者应理解为未经 EDA 工具验证的工程判断。
3. **UNVERIFIED**：无法在本代码树内核实的结论显式标注。
4. 标识符、信号名、文件名一律用英文原名，不作翻译。

---

## 1. 指令规范

### 1.0 指令族总览

| 指令 | funct6 | funct3 | opcode | 生效 SEW | 形态 | 目的 EEW | 累加 |
|---|---|---|---|---|---|---|---|
| `vdot.vv` | `111001` | `000` (OPIVV) | `1010111` | 8 | 全向量归约 | 32 | 否 |
| `vdotacc.vv` | `111010` | `000` (OPIVV) | `1010111` | 8 | 全向量归约 | 32 | 是（`vd[0]`） |
| `vdot4a.vv` | `111011` | `000` (OPIVV) | `1010111` | 32 | 逐元素分组点积 | 32 | 是（`vd[i]`） |

三条指令共享同一套 16 路 8×8 有符号乘法阵列与同一棵**可重构折叠加法树**（§4.4）。选择 OPIVV（`funct3=000`）而非 OPMVV 的理由见 §9 裁定 R-02。

### 1.1 编码位域图

三条指令共用 RVV 的 `.vv` 位域布局（`$XS/src/main/scala/xiangshan/backend/decode/isa/bitfield/RiscvInst.scala` 中 `isOPIVV` / `OPCODE7Bit.VECTOR_ARITH` 定义的格式）：

```
 31       26  25   24      20  19      15  14    12  11     7  6            0
┌────────────┬────┬──────────┬──────────┬─────────┬─────────┬──────────────┐
│   funct6   │ vm │   vs2    │   vs1    │ funct3  │   vd    │    opcode    │
│   [6]      │[1] │   [5]    │   [5]    │  [3]    │  [5]    │     [7]      │
└────────────┴────┴──────────┴──────────┴─────────┴─────────┴──────────────┘

vdot.vv     vd, vs2, vs1, vm
┌────────────┬────┬──────────┬──────────┬─────────┬─────────┬──────────────┐
│   111001   │ vm │   vs2    │   vs1    │   000   │   vd    │   1010111    │
└────────────┴────┴──────────┴──────────┴─────────┴─────────┴──────────────┘

vdotacc.vv  vd, vs2, vs1, vm
┌────────────┬────┬──────────┬──────────┬─────────┬─────────┬──────────────┐
│   111010   │ vm │   vs2    │   vs1    │   000   │   vd    │   1010111    │
└────────────┴────┴──────────┴──────────┴─────────┴─────────┴──────────────┘

vdot4a.vv   vd, vs2, vs1, vm
┌────────────┬────┬──────────┬──────────┬─────────┬─────────┬──────────────┐
│   111011   │ vm │   vs2    │   vs1    │   000   │   vd    │   1010111    │
└────────────┴────┴──────────┴──────────┴─────────┴─────────┴──────────────┘
```

`vm = 1` 表示无掩码；`vm = 0` 表示用 `v0` 作掩码源（与全部 RVV 向量算术指令一致）。

### 1.2 汇编语法与机器码

当前 GNU as 不认识这三条指令，必须用 `.insn` 或 `.word` 发射。

```gas
# ---- 形式一：.word（最稳妥，推荐用于测试程序） ----
# vdot.vv    v3, v1, v2        (vd=v3, vs2=v1, vs1=v2, vm=1)
.word 0xE61101D7
# vdotacc.vv v3, v1, v2
.word 0xEA1101D7
# vdot4a.vv  v3, v1, v2
.word 0xEE1101D7

# ---- 形式二：.insn r（参数化宏） ----
#  .insn r opcode, funct3, funct7, rd, rs1, rs2
#  其中 funct7 = (funct6 << 1) | vm
#  注意：指令字的 rs1 字段 = vs1，rs2 字段 = vs2，与汇编书写顺序 "vd, vs2, vs1" 相反
.macro VDOT_VV    vd, vs2, vs1, vm=1
  .insn r 0x57, 0x0, (0b111001 << 1) | \vm, \vd, \vs1, \vs2
.endm
.macro VDOTACC_VV vd, vs2, vs1, vm=1
  .insn r 0x57, 0x0, (0b111010 << 1) | \vm, \vd, \vs1, \vs2
.endm
.macro VDOT4A_VV  vd, vs2, vs1, vm=1
  .insn r 0x57, 0x0, (0b111011 << 1) | \vm, \vd, \vs1, \vs2
.endm
```

`funct7` 取值速查（`funct7 = funct6<<1 | vm`）：

| 指令 | vm=1 | vm=0 | 示例机器码（vd=v3, vs2=v1, vs1=v2, vm=1） |
|---|---|---|---|
| `vdot.vv` | `0x73` | `0x72` | `0xE61101D7` |
| `vdotacc.vv` | `0x75` | `0x74` | `0xEA1101D7` |
| `vdot4a.vv` | `0x77` | `0x76` | `0xEE1101D7` |

> 上表机器码由位域拼接算得（`funct6<<26 | vm<<25 | vs2<<20 | vs1<<15 | funct3<<12 | vd<<7 | opcode`），已用脚本复核。
> **UNVERIFIED**：本机未安装 RISC-V 工具链，`.insn r` 宏是否被 GNU as 接受（尤其 `v3` 这类向量寄存器名在 `.insn` 中的可用性）未实测。测试程序优先使用 `.word`，并在 P4 阶段用 `objdump -d` 回读校验。

### 1.3 操作数与 EEW 表

| 指令 | 操作数 | 角色 | EEW | EMUL | 元素数（VLEN=128, LMUL=1） | 符号性 |
|---|---|---|---|---|---|---|
| `vdot.vv` | `vs2` | 源 A | 8 | LMUL | 16 | signed |
| | `vs1` | 源 B | 8 | LMUL | 16 | signed |
| | `vd` | 目的 | 32 | 1（单寄存器） | 4（只写元素 0，其余为 tail） | — |
| | `v0` | 掩码 | 1 bit/源元素 | — | 16 bit | — |
| `vdotacc.vv` | `vs2` / `vs1` | 源 A / B | 8 | LMUL | 16 | signed |
| | `vd` | **第三源 + 目的** | 32 | 1 | 元素 0 读—改—写 | 累加器按无符号 32 位回绕 |
| | `v0` | 掩码 | 1 bit/源元素 | — | 16 bit | — |
| `vdot4a.vv` | `vs2` / `vs1` | 源 A / B（每 32 位元素含 4 个 int8 子元素） | 32 | LMUL | 4 | 子元素 signed |
| | `vd` | **第三源 + 目的** | 32 | LMUL | 4 | 累加器按无符号 32 位回绕 |
| | `v0` | 掩码 | **1 bit/32 位目的元素** | — | 4 bit | — |

**关键差异**：`vdot.vv` / `vdotacc.vv` 的掩码粒度是**源元素（8 位）**，`vdot4a.vv` 的掩码粒度是**目的元素（32 位）**。前者沿用 RVV 归约指令惯例（掩码筛选参与归约的源元素），后者沿用 Zvdot4a8i / ARM SDOT 惯例（掩码筛选目的元素）。该区别在 RTL 中由 `Mgu` 的 `info.eew` 自动处理（`$XS/src/main/scala/xiangshan/backend/fu/vector/Mgu.scala:59-61`：`maskDataVec = VecDataToMaskDataVec(in.mask, realEw)`）。

`vd` 的 EMUL 为 1（归约类）这一点必须在 `VecExceptionGen` 中显式声明，否则寄存器对齐/重叠检查会按 LMUL 判定（见 §6 集成项 C4）。

### 1.4 精确伪代码

以下伪代码与参考模型 `tests/golden/vdot_ref.c` **逐行对应**，括号内给出参考模型行号。RTL 与 NEMU 实现若与本节有出入，一律以参考模型为准。

#### 1.4.1 `vdot.vv` / `vdotacc.vv`（归约形态，SEW=8）

```c
/* vdot.vv    vd, vs2, vs1, vm    —— accumulate = 0
 * vdotacc.vv vd, vs2, vs1, vm    —— accumulate = 1
 * 对应 vdot_ref.c:69-126 vdot_reduce_common()
 */
VLMAX = VLEN / 8;                                    /* = 16   (vdot_ref.c:76) */

/* --- 译码/执行前的非法性检查 --- */
if (vtype.vill)            raise ILLEGAL_INSTRUCTION;
if (mstatus.VS == Off)     raise ILLEGAL_INSTRUCTION;
if (vtype.vsew != 0b000)   raise ILLEGAL_INSTRUCTION;   /* 必须 SEW=8   (vdot_ref.c:232/236) */
if (vstart != 0)           raise ILLEGAL_INSTRUCTION;   /* 裁定 S-1     (vdot_ref.c:90-91) */
require_aligned(vs1, LMUL); require_aligned(vs2, LMUL);  /* vd 为单寄存器，EMUL=1，无对齐要求 */

/* --- vstart >= vl（含 vl == 0）：整条指令不写回任何元素，连 tail 都不写 --- */
if (vstart >= vl) { vstart = 0; mstatus.VS = Dirty; return; }   /* 裁定 S-5 (vdot_ref.c:94) */

/* --- 归约主体：在 uint32 上累加，自然 2^32 回绕，无 UB --- */
uint32_t sum = accumulate ? vd.u32[0] : 0u;             /* (vdot_ref.c:97) */
for (i = vstart /* ==0 */; i < vl; i++) {
    if (vm == 0 && v0.mask[i] == 0) continue;           /* 裁定：inactive 源元素排除出归约 */
    sum += (uint32_t)( sext32(vs2.i8[i]) * sext32(vs1.i8[i]) );   /* (vdot_ref.c:100) */
}

/* --- 写回：先铺 tail（元素 1..3，EEW=32），再写元素 0；两者不相交 --- */
if (vtype.vta)                                          /* 裁定 S-3 (vdot_ref.c:104-106) */
    for (j = 1; j < VLEN/32; j++) vd.u32[j] = 0xFFFFFFFF;
vd.u32[0] = sum;                                        /* 裁定 S-4 (vdot_ref.c:108) */
/* vtype.vma 对归约无意义，忽略（裁定 S-2, vdot_ref.c:80） */

vstart = 0;  mstatus.VS = Dirty;
```

#### 1.4.2 `vdot4a.vv`（逐元素分组点积累加，SEW=32）

```c
/* vdot4a.vv vd, vs2, vs1, vm
 * 对应 vdot_ref.c:153-195 vdot4a_vv_ex()
 */
VLMAX = VLEN / 32;                                   /* = 4    (vdot_ref.c:157) */

if (vtype.vill)            raise ILLEGAL_INSTRUCTION;
if (vtype.vsew != 0b010)   raise ILLEGAL_INSTRUCTION;   /* 必须 SEW=32  (vdot_ref.c:240) */
require_aligned(vd, LMUL); require_aligned(vs1, LMUL); require_aligned(vs2, LMUL);

if (vstart != 0)           raise ILLEGAL_INSTRUCTION;   /* 裁定 S-7'  (vdot_ref.c:170-171) */

if (vstart >= vl) { vstart = 0; mstatus.VS = Dirty; return; }   /* 裁定 S-5 (vdot_ref.c:174) */

for (i = vstart /* ==0 */; i < vl; i++) {            /* prestart 仅在放宽实现上可达，见 S-7' */
    if (vm == 0 && v0.mask[i] == 0) {                /* inactive */
        if (vtype.vma) vd.u32[i] = 0xFFFFFFFF;       /* (vdot_ref.c:177-179) */
        continue;                                    /* vma==0：保持不变 */
    }
    uint32_t acc = vd.u32[i];
    for (j = 0; j < 4; j++)                          /* 裁定 S-7：子字节索引取 4i+j（S-7' 未修订此条） */
        acc += (uint32_t)( sext32(vs2.i8[4*i+j]) * sext32(vs1.i8[4*i+j]) );
    vd.u32[i] = acc;                                 /* (vdot_ref.c:181-187) */
}
if (vtype.vta)                                       /* tail: i >= vl */
    for (i = vl; i < VLMAX; i++) vd.u32[i] = 0xFFFFFFFF;    /* (vdot_ref.c:191-193) */

vstart = 0;  mstatus.VS = Dirty;
```

> **字节序说明**（`vdot_ref.h:40-56`）：向量寄存器内部按小端组织，`element i (EEW=8) == v[i]`，`element i (EEW=32) == v[4i] | v[4i+1]<<8 | v[4i+2]<<16 | v[4i+3]<<24`。因此 `vdot4a` 的第 `i` 个 32 位元素的 4 个 int8 子元素恰好是字节 `4i..4i+3`，与 RTL 中 `UIntSplit(vs2, 8)` 的下标完全一致，无需任何重排（§4.2）。
> 四个乘积相加，子元素顺序不影响结果，故本实现与 Zvdot4a8i spec 的 Sail `{a0@a1@a2@a3}` MSB-first 写法在结果上等价。

### 1.5 行为表

下表把 `vstart` / `vl` / `vm` / `vta` / `vma` / LMUL / 非法情形逐项固化，**依据列给出 D2.1 裁定编号与 RVV 1.0 条款**。

#### 1.5.1 `vdot.vv` / `vdotacc.vv`（归约）

| 情形 | 行为 | 依据 | 参考模型 |
|---|---|---|---|
| `vtype.vill = 1` | Illegal Instruction | RVV §3.4.1 | — |
| `vtype.vsew != 8` | Illegal Instruction | D2；本指令仅定义于 SEW=8 | `vdot_ref.c:232,236` |
| **`vstart != 0`** | **Illegal Instruction** | **S-1**；RVV §14「Vector reduction operations raise an illegal instruction exception if vstart is non-zero」 | `vdot_ref.c:90-91` |
| `vstart >= vl`（含 `vl = 0`） | 不写回任何元素，**连 tail 都不写**，`vd` 完全保持 | **S-5**；RVV §5.4 | `vdot_ref.c:94` |
| `vl = 0`（且 vstart=0） | 同上：`vd` 完全保持 | S-5 | `vdot_ref.c:94` |
| `vm = 1` | 全部 `i < vl` 的源元素参与归约 | RVV §5.3 | `vdot_ref.c:38` |
| `vm = 0`，`v0.mask[i] = 0` | 第 `i` 对源元素**排除出归约**（等价于贡献 0） | RVV §14「Inactive elements … are excluded from the reduction」 | `vdot_ref.c:99` |
| `vm = 0` 且 `v0` 全 0（所有源被掩掉） | 仍写 `vd.u32[0]`：`vdot` 写 0，`vdotacc` 写原值 | **S-4**；归约单位元为 0 | `vdot_ref.c:97-108` |
| `vta = 1` | 目的元素 1..3（EEW=32）写全 1 | **S-3**；RVV §3.4.3 | `vdot_ref.c:104-106` |
| `vta = 0` | 目的元素 1..3 保持 `vd` 原值 | S-3；RVV §3.4.3 | 同上（不进分支） |
| `vma` | **忽略**（归约无 body-inactive 目的元素） | **S-2** | `vdot_ref.c:80` |
| `vd` 与 `vs1`/`vs2` 寄存器重叠 | **允许**（`vd` 为单元素目的，RVV §5.2 允许） | RVV §5.2；`VecExceptionGen.scala:282,289` 的 `vdIsSingleElem` 分支 | — |
| `vd = v0` 且 `vm = 0` | **允许**（单元素目的例外，`VecExceptionGen.scala:260` `v0AllowOverlap`） | RVV §5.3 | — |
| `LMUL` | **本版本固定 LMUL = 1**（S-6）。`vlmul != 0` 的行为见 §8.3 扩展性论证，本版本不交付 | **S-6** | — |
| 执行结束 | `vstart = 0`，`mstatus.VS = Dirty` | RVV §3.7 | `vdot_ref.c:67` 注 |
| `vxsat` | **恒不置位**（无饱和，见 §1.6 溢出证明） | D2 | — |

#### 1.5.2 `vdot4a.vv`（逐元素）

| 情形 | 行为 | 依据 | 参考模型 |
|---|---|---|---|
| `vtype.vill = 1` | Illegal Instruction | RVV §3.4.1 | — |
| `vtype.vsew != 32` | Illegal Instruction | D2 / Zvdot4a8i draft v0.1 同样要求 SEW=32 | `vdot_ref.c:240` |
| **`vstart != 0`** | **Illegal Instruction** | **S-7'**（取代原 S-7 的 vstart 部分）；**平台约束优先原则**，非 RVV 对逐元素指令的一般规定 —— 见下文 §1.5.4 与 §9 裁定 R-17 | `vdot_ref.c:170-171` |
| `vstart >= vl`（含 `vl = 0`） | 不写回任何元素，连 tail 都不写 | **S-5**；RVV §5.4 | `vdot_ref.c:174` |
| `i < vstart`（prestart） | 目的元素保持不变。S-7' 之后该情形在本平台**架构上不可达**，仅在放宽 `vstart` 的实现上有意义；数据通路仍正确实现（非规范语料 `vstart_relaxed.txt` 的 40 条 vdot4a 用例在 L1 实测通过） | S-7' 的放宽分支；RVV §3.7 / §5.4 | `vdot_ref.c:176` |
| `vm = 1` | `vstart <= i < vl` 全部为 active | RVV §5.3 | — |
| `vm = 0`，`v0.mask[i] = 0`，`vma = 0` | 目的元素 `i` 保持原值（undisturbed） | RVV §3.4.3 | `vdot_ref.c:177-179` |
| `vm = 0`，`v0.mask[i] = 0`，`vma = 1` | 目的元素 `i` 写全 1（agnostic） | RVV §3.4.3 | `vdot_ref.c:178` |
| `i >= vl`（tail），`vta = 1` | 写全 1 | RVV §3.4.3 | `vdot_ref.c:191-193` |
| `i >= vl`（tail），`vta = 0` | 保持原值 | RVV §3.4.3 | 同上 |
| 掩码粒度 | **32 位目的元素**（每个结果 1 bit），与 Zvdot4a8i 一致 | `vdot_ref.c:150` | — |
| `vd` 与 `vs1`/`vs2` 重叠 | 允许（EEW/EMUL 完全相同，RVV §5.2 的「相同 EEW 可完全重叠」） | `VecExceptionGen.scala:286`（`vs2Constraint1`） | — |
| `LMUL` | 本版本固定 LMUL = 1（S-6）。LMUL>1 结构上直接复用 `UopSplitType.VEC_VVV`，见 §8.3 | S-6 | — |
| 累加溢出 | 按 2^32 模回绕，**不饱和**，不置 `vxsat` | RVV §11「overflows wrap around」 | `vdot_ref.c:16-18` |

#### 1.5.3 非法指令汇总（RTL 判定点）

| 条件 | 判定位置 | 说明 |
|---|---|---|
| `vstart != 0 && isVArith` | `$XS/src/main/scala/xiangshan/backend/decode/VecExceptionGen.scala:275`（pristine）/ `:305`（实现树）`vstartIllegal`，汇入 `io.illegalInst` | **现有逻辑天然满足 S-1 与 S-7'**，`FuType.vimac ∈ vecArith`，无需任何新增代码即可对**三条**指令在 `vstart != 0` 时报非法。详见 §9 裁定 R-05 / R-17。译码级定向用例 `tests/unit/vecexcgen_tb.cpp` 的 `[H]` `[I]` 两组（7 条）实测验证 |
| `vdot` 族且 `vtype.vlmul != 0`（LMUL != 1） | `VecExceptionGen.scala:217`（实现树）`dotEmulIllegal`，汇入 `:240` `emulIllegal` | 新增（裁定 S-6）。由 P6 协同仿真发现缺失，见 `docs/stage3/21` §7.2 |
| `vdot`/`vdotacc` 且 `SEW != 8`；`vdot4a` 且 `SEW != 32` | 需在 `VecExceptionGen.scala:195` 的 `eewIllegal` 中新增分支（集成项 C4） | 新增 |
| `vill` | `VecExceptionGen.scala:178` `villIllegal` | 现有 |
| 寄存器对齐 / 重叠 | `VecExceptionGen.scala:257,292` | 需把三条指令登记进 `vdIsSingleElem`（仅归约两条）等列表，见集成项 C4 |

#### 1.5.4 裁定 S-7'：`vdot4a` 的 `vstart` 为什么也判非法（平台约束优先原则）

**本小节记录一次语义修订，修订的触发者是 NEMU ↔ RTL 协同仿真。**

| | 原裁定 S-7（P3 阶段） | 修订后 S-7'（P6 阶段） |
|---|---|---|
| `vdot4a.vv` 且 `vstart != 0` | 正常生效，`i < vstart` 为 prestart | **Illegal Instruction** |
| 依据 | RVV §5.4 对逐元素指令的一般规定 | **平台约束优先原则**（见下） |
| `4i+j` 子字节索引 | S-7 的这一部分**未被修订**，仍然有效 | 同左 |

**修订经过**：本文档原先（见上一版 §1.5.3 的 ⚠️ 注与 §9 裁定 R-06）已经识别出「S-7 要求 `vstart`
正常生效，而 `vstartIllegal` 会在译码阶段挡掉它」这一冲突，但当时的处理是**把它登记为一处
可接受的不可达性**，ISA 定义照旧。P6 的 Level-1 协同仿真（真 NEMU `.so` ↔ Verilated 译码单元）
把这件事的真实代价量化了出来：在 `vdot4a` + `vstart ∈ {1,2,3}` 的 **1946 条**激励上，
NEMU 按 S-7 正常执行、香山判非法 —— 这是一类**确定性的全核 difftest mismatch**，
不是「不可达」，而是「两侧对同一条指令给出了不同的架构可见行为」。

**裁定（平台约束优先原则）**：自定义指令的 ISA 语义**不应宽于宿主微架构的实际能力**。
昆明湖 V2 的向量算术通路不支持从非零 `vstart` 恢复执行任何向量算术指令，这是既有架构事实，
不是本项目引入的缺陷。两条收敛路径中：

* **让 ISA 向微架构收敛**（采纳）：在参考模型与 NEMU 里补 `vstart != 0 -> Illegal Instruction`，
  改动面局限在本指令族内部，三条 vdot 指令的 `vstart` 行为从此完全一致，且与同平台上
  `vadd.vv` / `vmacc.vv` / `vwmul.vv` 等**所有**标准向量算术指令的行为一致
  （实测对照表见 `bench/results/vstart_control.csv`：8 条指令在 `vstart=1` 时全部 `TRAP mcause=2`）。
* **让微架构向 ISA 收敛**（否决）：为 `vdot4a` 在 `vstartIllegal` 上开一个例外，并让 `VIMacU`
  的 `Mgu` 正确处理 prestart。代价是改动一条影响**全部**向量算术指令的公共判据，
  回归面覆盖整个向量后端，风险与收益不成比例（这正是 §9 裁定 R-06 已经论证过的）。

**可放宽性（重要）**：S-7' 是**平台约束驱动的设计决策，不是指令语义的内在限制**。
在支持 `vstart` 重启的实现上，本条完全可以放宽回原 S-7 的 prestart 语义：
① 参考模型保留了 `VDOT_VSTART_SKIP` 策略，一行参数即可切换；
② 数据通路本身**已经正确实现**了 prestart（`Mgu` 的 `info.vstart` 接的就是
   `outVecCtrl.vstart`，`VIMacU.scala:140`），无需任何 RTL 改动；
③ 非规范语料 `tests/vectors/vstart_relaxed.txt` 里有 40 条 `vdot4a` 的 prestart 用例，
   在 L1 平台上实测全部通过 —— 也就是说「放宽之后应当是什么行为」是有可执行定义的。

**RTL 侧需要做什么：什么都不需要做。** `vdot4a` 走 `FuType.vimac`，`FuType.isVArith` 为真，
上游既有的 `vstartIllegal` 已经把它拦下。该结论不是推导出来的，是在译码级直驱平台上测出来的：
`tests/unit/vecexcgen_tb.cpp` 的 `[I]` 组 4 条用例（`vstart = 1/2/3` 期望非法、`vstart = 0` 期望合法）
全部 PASS，日志 `logs/stage2/p5_decode_illegal.log`。


### 1.6 溢出证明

**命题**：`vdot.vv` 在 VLEN=128 / SEW=8 / LMUL=1 下结果恒落在 int32 范围内，不可能溢出，因此不需要任何饱和逻辑，也永不置位 `vxsat`。

**证明**：

设 `a, b ∈ [-128, +127]`（int8 全域），乘积 `p = a·b`。

- 上界：`p` 取最大值当且仅当两数同号且绝对值最大。`(-128)·(-128) = +16384`；`127·127 = 16129`。故 `max p = 16384 = 2^14`。
- 下界：`p` 取最小值当且仅当两数异号且绝对值最大。`(-128)·(+127) = -16256`。故 `min p = -16256 > -2^14`。

因此 `|p| <= 16384 = 2^14`，单个乘积恰好可用 16 位二补码表示（`[-32768, 32767] ⊇ [-16256, 16384]`），这正是硬件上 8×8 乘法器输出 16 位的依据。

有效元素数 `n = vl <= VLMAX = VLEN/SEW = 128/8 = 16`。故

```
| Σ_{i=0}^{n-1} p_i |  <=  n · max|p_i|  <=  16 × 16384  =  262144  =  2^18  <  2^31 - 1
```

结果区间为 `[-16 × 16256, 16 × 16384] = [-260096, +262144]`，完整落在 int32 内，**且只用到 20 位二补码**（`[-524288, +524287]`）。∎

**推论与工程含义**：

1. `vdot.vv` 无需饱和/溢出标志逻辑，`io.out.bits.res.vxsat` 对本指令恒为 0。
2. 内部加法树的**最小**宽度为 20 位。本设计取 32 位（§4.3），一方面与目的 EEW 对齐省掉一次扩展，另一方面为 `vdotacc` / `vdot4a` 的 32 位累加器让路。
3. `vdotacc.vv` / `vdot4a.vv` 把外部累加值并入后可能超过 int32，按 RVV §11「overflows wrap around」做 2^32 模回绕，不饱和（`vdot_ref.c:16-18`）。硬件上这是「天然行为」：32 位加法器丢弃进位即是模 2^32。
4. `vdot4a.vv` 的单组上界更松：`|Σ_{j<4} p_j| <= 4 × 16384 = 65536 = 2^16`，加上 32 位累加器后同样按模 2^32 回绕。

---

## 2. 编码空间占用证明

### 2.1 方法

编写脚本 `scripts/tools/check_funct6.py`，在目标代码树中扫描全部 `.scala` 文件内形如

```scala
def <NAME> = BitPat("b<32 位 0/1/? 串>")
```

的指令位模式声明，按 RVV 的 OP-V 位域（`[31:26] funct6 / [25] vm / [24:20] vs2 / [19:15] vs1 / [14:12] funct3 / [11:7] vd / [6:0] opcode`）切分，筛出 `opcode == 1010111` 的全部条目，按 `funct3` 分组列出已占用的 `funct6`。含通配位 `?` 的 funct6 被**保守地展开为全部具体取值**并计入占用，确保不漏判冲突。

扫描覆盖三个来源（见脚本 `SCAN_FILES` / `SCAN_TREE_DIRS`）：

| 来源 | 文件 | 内容 |
|---|---|---|
| rocket-chip 自动生成 | `$XS/rocket-chip/src/main/scala/rocket/Instructions.scala` | RVV 1.0 全量 BitPat |
| XiangShan 自定义 | `$XS/src/main/scala/xiangshan/backend/decode/Instructions.scala` | `object Zvbb`（16 条）、`object Zimop` |
| 全树兜底 | `src/main/scala`、`rocket-chip/src/main/scala`、`yunsuan/src/main/scala` | 防止遗漏其它位置新增的自定义位模式 |

### 2.2 脚本

脚本完整内容见 `scripts/tools/check_funct6.py`（已提交，可执行）。核心逻辑摘录：

```python
PAT = re.compile(r'def\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*BitPat\(\s*"b([01?]{32})"\s*\)')
...
for name, bits in PAT.findall(text):
    opcode = bits[25:32]
    if opcode != "1010111":      # 只看 OP-V
        continue
    funct6 = bits[0:6]
    funct3 = bits[17:20]
    # funct6 含 '?' 时展开为全部具体取值，保守计为已占用
```

### 2.3 真实运行输出

命令与输出（完整日志存档于 `logs/stage2/check_funct6.log`）。下面是当年在 macOS 建设环境上的原样输出，其中的绝对路径是当时的仓库根；
复现时在仓库根执行 `python3 scripts/tools/check_funct6.py` 即可（需先由 `scripts/00_setup_env_host.sh` 生成 `work/XiangShan-kmhv2`）：

```
$ cd /Users/i3eg1nner/code/cie && python3 scripts/tools/check_funct6.py
========================================================================
OPIVV funct6 编码空间占用检查
========================================================================
代码树根目录 : /Users/i3eg1nner/code/cie/work/XiangShan-kmhv2
扫描 .scala  : 777 个文件，928 条 BitPat 指令位模式

-- funct3=000 (OPIVV)  已占用 funct6 共 42 个 --
   000000  VADD_VV
   000001  VANDN_VV
   000010  VSUB_VV
   000100  VMINU_VV
   000101  VMIN_VV
   000110  VMAXU_VV
   000111  VMAX_VV
   001001  VAND_VV
   001010  VOR_VV
   001011  VXOR_VV
   001100  VRGATHER_VV
   001110  VRGATHEREI16_VV
   010000  VADC_VVM
   010001  VMADC_VV, VMADC_VVM
   010010  VSBC_VVM
   010011  VMSBC_VV, VMSBC_VVM
   010100  VROR_VV
   010101  VROL_VV
   010111  VMERGE_VVM, VMV_V_V
   011000  VMSEQ_VV
   011001  VMSNE_VV
   011010  VMSLTU_VV
   011011  VMSLT_VV
   011100  VMSLEU_VV
   011101  VMSLE_VV
   100000  VSADDU_VV
   100001  VSADD_VV
   100010  VSSUBU_VV
   100011  VSSUB_VV
   100101  VSLL_VV
   100111  VSMUL_VV
   101000  VSRL_VV
   101001  VSRA_VV
   101010  VSSRL_VV
   101011  VSSRA_VV
   101100  VNSRL_WV
   101101  VNSRA_WV
   101110  VNCLIPU_WV
   101111  VNCLIP_WV
   110000  VWREDSUMU_VS
   110001  VWREDSUM_VS
   110101  VWSLL_VV

-- OPIVV 空闲 funct6 共 22 个 --
   000011 001000 001101 001111 010110 011110 011111 100100 100110
   110010 110011 110100 110110 110111 111000 111001 111010 111011
   111100 111101 111110 111111

-- 目标编码判定 --
   funct6=111001  vdot.vv       FREE
   funct6=111010  vdotacc.vv    FREE
   funct6=111011  vdot4a.vv     FREE

结论：三条 vdot 指令的 funct6 在本代码树 OPIVV 空间内全部空闲。
```

（脚本同时打印了 OPFVV/OPMVV/OPIVI/OPIVX/OPFVF/OPMVX/OPCFG 七个子空间的占用表，此处略，见日志文件。）

### 2.4 判定与边界

| funct6 | 指令 | 判定 |
|---|---|---|
| `111001` | `vdot.vv` | ✅ FREE |
| `111010` | `vdotacc.vv` | ✅ FREE |
| `111011` | `vdot4a.vv` | ✅ FREE |

OPIVV 的整个 `1110xx` 与 `1111xx` 共 8 个编码全部空闲，`111000` / `111100`–`111111` 可作备选。

**本证明的边界（必须随交付物一并声明）**：

1. 本证明的覆盖范围是**本代码树已实现的指令集合**（RVV 1.0 + XiangShan 的 Zvbb/Zimop 扩展）。RVV 1.0 规范把 OPIVV 的 `1110xx` 行整体留白（reserved），本设计占用的是 reserved 空间，属于**非标准自定义扩展**，不保证与未来标准指令兼容。
2. **外部扩展冲突（UNVERIFIED）**：RISC-V `Zvdot4a8i`（原 `Zvqdotq`，draft v0.1，未批准）把点积指令放在 **OPMVV**（`funct3=010`）的 `101100/101000/101010/101110`，与本设计的 OPIVV `1110xx` **不冲突**。本代码树未实现 `Zvdot4a8i`，故无法在树内核实这一点，结论来自外部规范文本（见 `docs/_recon/vdot-semantics-research.md` §3.2）。
3. `funct3=000` 且 `vm` 固定为 0 的「`*_VVM` 变体」（如 `VADC_VVM`）与非掩码变体共享 funct6，脚本已把它们合并计数（输出中 `010001 VMADC_VV, VMADC_VVM` 即为一例）。
4. 若将来需要让路给标准扩展，三条指令整体平移到 `111100`–`111110` 只需改 `Instructions.scala` 中的三行 BitPat 与汇编宏。

---

## 3. 微架构设计

### 3.1 插入点选择

**决策：在 `FuType.vimac` / `VIMacU` 内扩展，不新增 FuType，不改 `FuConfig` 的任何字段。**

| 理由 | 证据 |
|---|---|
| 最昂贵的硬件已经在那里：VLEN=128/SEW=8 时的 **16 路有符号 8×8 乘法阵列**，在 v2 上唯一的实现就是 `VIMacU` 内的 2 个 `VIMac64b`（Booth radix-4 + Wallace 树） | `$XS/src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala:64` `Seq.fill(numVecModule)(Module(new VIMac64b))`，`numVecModule = 128/64 = 2`（`:49-51`）；单片在 `sew=8` 时并行做 8 组 8×8（`yunsuan/.../VIMac64b.scala:86-88`） |
| `VIPU` / `VIAlu` 内**没有任何乘法器**，放那里必须另造一套阵列 | `yunsuan/src/main/scala/yunsuan/vector/VectorALU/VIAlu.scala:35,38` 只例化 `Reduction` 与 `VMask` |
| `VimacCfg` 已经提供 3 个向量源 + V0 + Vl、128 位目的、`piped=true`，**无需任何字段改动** | `$XS/src/main/scala/xiangshan/backend/fu/FuConfig.scala:551-568`，特别是 `:555-557` 的 `Seq(VecData(), VecData(), VecData(), V0Data(), VlData())` |
| OPIVV 格式**天然把 `vd` 作为第三源读入**，`vdotacc` / `vdot4a` 的累加通路零成本 | `$XS/src/main/scala/xiangshan/backend/decode/VecDecoder.scala:28-38`，`case class OPIVV` 的 `src3: BitPat = SrcType.vp` 为默认值；`DecodeUnit.scala:861` `lsrc(2) := Mux(isFMA, inst.FS3, inst.VD)` |
| 新增 `FuType` 的代价巨大：`FuType` 是 one-hot 枚举，`FuType.num` +1 会使 `fuType` 字段整体加宽，波及 `DecodedInst` / IQ entry / ROB entry / 旁路网络 | `$XS/src/main/scala/xiangshan/backend/fu/FuType.scala`（`OHEnumeration`，`def num = this.values.size`） |
| `vimac` 在 VFEX0 独占一个发射端口，`FuConfig`/`Parameters` 完全不动 | `$XS/src/main/scala/xiangshan/Parameters.scala:449` `ExeUnitParams("VFEX0", Seq(VfmaCfg, VialuCfg, VimacCfg, VppuCfg), ...)` |

**fuOpType 编码空间**：`VimacOpcode` 宽 3 位，已用 `000`–`110`，**仅 `b111` 空闲**（`yunsuan/src/main/scala/yunsuan/encoding/Opcode/VimacOpcode.scala:6-13`）。`VimacType` 总宽 9 位（`yunsuan/src/main/scala/yunsuan/package.scala:8` `OpTypeWidth = 9`），布局 `[8:7] pad / [6] vs2Sign / [5] vs1Sign / [4] vdSign / [3] format / [2:0] VimacOpcode`（`package.scala:381-406`）。现有全部取值的 `pad == 00`，故 `[8:7] ∈ {01,10,11}` 的高半空间完全空闲，正好用于区分三条 vdot 指令。注意 `VIMacU` 消费的 `fuOpType` 来自 `FuncUnit` 的 9 位端口（`$XS/src/main/scala/xiangshan/package.scala:68` `FuOpTypeWidth = 9`），**不存在 `VIPU` 路线上 `VIAluDecoder` 把 `fuOpType` 声明成 8 位的截断隐患**。

### 3.2 模块层次图

```
                       XiangShan backend
┌──────────────────────────────────────────────────────────────────────────┐
│ VFEX0  (Parameters.scala:449)                                            │
│   └── VIMacU(VimacCfg) extends VecPipedFuncUnit   wrapper/VIMacU.scala:45│
│         latency = cfg.latency = 2   (FuConfig.scala:563)                 │
│                                                                           │
│   ┌── VIMacSrcTypeModule            VIMacU.scala:18-43     [改]           │
│   │     fuOpType + vsew  ->  vs2Type / vs1Type / vdType                  │
│   │     vdot 三条：vs2Type=vs1Type=s8，vdType=u32                        │
│   │                                                                       │
│   ├── VecDataSplitModule × 3        VIMacU.scala:61-63     [复用，不改]   │
│   │     vs2 / vs1 / oldVd  ->  Vec(2, UInt(64.W)) 等                     │
│   │                                                                       │
│   ├── VIMac64b × 2                  VIMacU.scala:64        [仅加输出端口] │
│   │     ├─ S0: Booth radix-4 (×32组) + partProd Vec(34)(128b)            │
│   │     │       + Wallace 3->2 前 5 级 (34→23→16→11→8→6)                 │
│   │     │       ── RegEnable(fire) ── wallaceOut_mid_reg Seq(6)(128b)    │
│   │     ├─ S1: Wallace 后 3 级 (6→4→3→2) -> wallaceOutReg Seq(2)(128b)   │
│   │     │       8 × Adder_16b（sew=8 时互不串进位）-> sum_wo Vec(8)(16b) │
│   │     │       ★ 新增输出 io.prod16 := sum_wo                           │
│   │     │       ── RegEnable(fireS1) ── walOut(128b)                     │
│   │     └─ S2: vdS2 截取 / vsmul 舍入饱和 -> io.vd(64b)                  │
│   │                                                                       │
│   ├── VDotTree                      新建（yunsuan.vector.mac） [新]       │
│   │     ├─ S1: 掩码门控 + 16b->32b 符号扩展                              │
│   │     │       Fold L0 : 4 × CSA4to2(32)   组内 4 路 (p4g..p4g+3)       │
│   │     │       Fold L1 : 4 × CSA4to2(32)   蝶形折叠 Δ=1                 │
│   │     │       ── RegEnable(fireS1) ── (S1_g, C1_g) 8 × 32b             │
│   │     └─ S2: Fold L2 : 4 × CSA4to2(32)   蝶形折叠 Δ=2                  │
│   │             Acc    : 4 × CSA3to2(32)   注入 oldVd                    │
│   │             CPA    : 4 × Adder32                                     │
│   │             -> dotVd(128b)  = {R3, R2, R1, R0}                       │
│   │     复用件：CSA4to2 / CSA3to2                                        │
│   │             (yunsuan/.../VectorFloatFMA.scala:1596 / :1581)          │
│   │                                                                       │
│   ├── ByteMaskTailGen(128)          新例化一份（S0 侧）     [复用]        │
│   │     -> activeEn[15:0]（SEW=8 时逐元素）-> 寄存到 S1 做乘积门控       │
│   │                                                                       │
│   ├── RedTailGen                    新建，3 行逻辑           [新]         │
│   │     照抄 Reduction.scala:644-647，vd_vsew_bits 固定 32               │
│   │                                                                       │
│   └── Mgu(128)                      VIMacU.scala:65        [复用，不改]   │
│         vdot4a / 全部原有指令走这里；vdot / vdotacc 走 RedTailGen        │
│                                                                           │
│   io.out.bits.res.data := Mux(outIsDotRed, redVd, mgu.io.out.vd)   [改]  │
└──────────────────────────────────────────────────────────────────────────┘
```

### 3.3 流水级划分

`VIMacU` 继承 `VecPipedFuncUnit`（`$XS/src/main/scala/xiangshan/backend/fu/vector/VecPipedFuncUnit.scala:58-94`），流水寄存器由 `HasPipelineReg` 按 `latency = cfg.latency.latencyVal.get`（`:93`）自动生成：`validVec` / `ctrlVec` / `dataVec` 各有 `latency + 1` 个表项（`$XS/src/main/scala/xiangshan/backend/fu/FuncUnit.scala:175-177`）。`latency = 2` 意味着**两级流水寄存器、三段组合逻辑**，与 `VIMac64b` 内部的 S0/S1/S2 三段完全对齐（`VIMac64b.scala:168` 的 `wallaceOut_mid_reg`、`:208` 的 `walOut` 就是那两级寄存器）。

| 流水段 | 时钟沿 | 原有逻辑（`vmul`/`vmacc`/`vsmul`） | vdot 新增逻辑 |
|---|---|---|---|
| **S0** | `fire = io.in.valid` 当拍 | Booth radix-4 重编码（`VIMac64b.scala:48-67`）；34 个部分积生成（`:69-113`）；`partProd(33)` 注入 `oldVd`（`:117`，vdot 恒为 0）；Wallace 前 5 级 3→2（`:158-165`，34→23→16→11→8→6） | `ByteMaskTailGen` 产生 `activeEn[15:0]`（纯组合，与乘法阵列并行，不在关键路径上） |
| **寄存器 1** | — | `wallaceOut_mid_reg` = 6×128b ×2 片（`:168`） | `activeEnS1` = 16b；控制位 `isDotS1` / `foldS1` / `accS1` |
| **S1** | — | Wallace 后 3 级（`:178`，6→4→3→2）；8 × `Adder_16b`，`sew=8` 时 8 段完全独立（`:185-201`）→ `sum_wo` Vec(8)(16b) | 从 `sum_wo` 抽头 16 个 16 位乘积；按 `activeEn` 门控并符号扩展到 32 位；Fold L0（4×CSA4to2(32)）+ Fold L1（4×CSA4to2(32)） |
| **寄存器 2** | — | `walOut` = 128b ×2 片（`:208`）；`sewS2`/`highHalfS2`/… | `(S1_g, C1_g)` = 8×32b = 256b |
| **S2** | 输出拍 | `vdS2` 按 SEW 截取（`:216-222`）；`vsmul` 舍入 + 8 段链式 `Adder_8b_rnd`（`:253-281`）；饱和（`:283-292`）；`io.vd`（`:294`） | Fold L2（4×CSA4to2(32)）；Acc（4×CSA3to2(32)）注入 `oldVd`；4 × 32 位 CPA；`RedTailGen` 元素 0 定位 + tail；输出三选一 |
| **输出** | `io.out.valid` | `io.out.bits.res.data := mgu.io.out.vd`（`VIMacU.scala:148`） | `:= Mux(outIsDotRed, redVd, mgu.io.out.vd)` |

> **为什么 `Mgu` 不在关键路径上额外增加风险**：`vdot4a` 走的就是现有 `vmacc` 的那条 `Mgu` 路径（`VIMacU.scala:132-148`），只是 `vd` 来源换成 `dotVd`，`eew` 由 `outEew`（`:131`）给出的 e32。`vdot`/`vdotacc` 则完全绕过 `Mgu`，走更短的 `RedTailGen`（3 个掩码 AND/OR + 2 个 mux）。

### 3.4 单条 `vdot.vv` 的逐周期时序

设指令在周期 `T0` 被 VFEX0 发射（`io.in.valid = 1` 且 `io.in.ready = 1`）。

```
周期         T-1          T0             T1             T2            T3
          ┌──────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────┐
IQ 发射   │ issue│──>│          │   │          │   │          │   │      │
读 VRF    │      │   │ vs1/vs2/ │   │          │   │          │   │      │
          │      │   │ oldVd/v0 │   │          │   │          │   │      │
          └──────┘   └──────────┘   └──────────┘   └──────────┘   └──────┘

io.in.valid        ────┐
                    T0 └───────────────────────────────────────────

VIMac64b 内部
  fire             ────┐
                    T0 └───
  S0 组合            [Booth 32组][partProd×34][Wallace L1..L5 → 6 addends]
  ─ reg1 ─                      ↑ 上升沿 T0→T1 锁存 wallaceOut_mid_reg
  S1 组合                        [Wallace L6..L8 → 2 addends][8×Adder_16b]
                                 └─> sum_wo = p0..p7 (本片)    ★抽头点
  ─ reg2 ─                                     ↑ T1→T2 锁存 walOut
  S2 组合                                       [vdS2 截取 / vsmul]（vdot 不用）

VDotTree
  S1 组合                        [active 门控][sext16→32]
                                 [Fold L0 ×4][Fold L1 ×4]
  ─ reg ─                                     ↑ T1→T2 锁存 (S1_g, C1_g)
  S2 组合                                      [Fold L2 ×4][Acc ×4][CPA32 ×4]
                                               [RedTailGen 元素0 + tail]
                                               [输出 mux]

io.out.valid       ──────────────────────────────┐
                                               T2 └──────
写回 VfWB(0,0)                                   [T2 末沿 → 物理向量寄存器堆]
唤醒相关指令        （CertainLatency(2)：IQ 在 T0 即可投机唤醒 T2 发射的相关指令）
```

**结论**：`vdot.vv` 的 FU 延迟 = **2 个周期**，与 `vmul.vv`/`vmacc.vv` 完全相同，不改变 `VimacCfg.latency`（`FuConfig.scala:563`），因此调度器、唤醒网络、写回仲裁一律不动。
实测周期数：**2 周期**（P7 实测，FU 级，按数据成形拍判定：直驱 `VIMacU` 时 vdot 178 笔全部「第 1 拍未成形、第 2 拍与参考模型逐位一致」，`logs/stage3/p7_latency_measure.log:238-242`；vdotacc / vdot4a 见 `:243-252`；另有 L1 波形 12×3 笔，DUT 内部 S2 寄存器与 `io_vd` 均在第 2 拍成形。两个平台的 `out.valid` 都由测试平台按声明延迟构造，不作证据；详见 `docs/stage3/22_基线实现与延迟加速分析.md` §4.2/§4.3）。

### 3.5 背靠背发射行为

| 场景 | 行为 | 依据 |
|---|---|---|
| 连续无关的 `vdot.vv` | **吞吐 1 条/周期**。`VimacCfg.piped = true`（`FuConfig.scala:558`），`HasPipelineReg` 生成的是真流水，各级独立 | `FuncUnit.scala:175-193` |
| `vdot.vv` 与 `vmul.vv` / `vmacc.vv` 交错 | 同样 1 条/周期。两者共用 S0/S1 的乘法阵列，输出在 S2 由 `outIsDotRed` 选择，**无结构冲突** | §3.3 |
| `vdotacc.vv` 累加链（同一 `vd` 连续累加） | 存在 RAW 真相关，间隔 = FU 延迟 + 旁路 = **预期 2 周期/条**。`CertainLatency(2)` 允许 IQ 做投机唤醒，相关指令可在前一条进入 S2 的同一拍发射 | `FuConfig.scala:563`；`FuConfig.scala:564-565` 的 `vconfigWakeUp`/`maskWakeUp` |
| `vdot4a.vv` 累加链（LLM 内循环典型形态） | 同上，2 周期/条。**软件应使用 ≥2 个累加器轮转**（`vdot4a v8,…` / `vdot4a v9,…` 交替），即可把吞吐拉满到 1 条/周期 | 同上 |
| 同一周期两条 `vimac` | **不可能**。`vimac` 只绑定在 VFEX0 一个执行端口上 | `Parameters.scala:449-457`：`VimacCfg` 只出现在 VFEX0 |

> 以上「2 周期」是由 `CertainLatency(2)` 与流水结构推导的**解析值**，不是实测。真实的背靠背间隔（受唤醒时序、旁路网络、IQ 选择逻辑影响）**未实测**：FU 级平台一次只喂一条指令，观测不到发射与唤醒，需全核仿真（`docs/stage3/22` §4.1、§10；后续计划 `docs/_plan/HANDOFF_TODO.md` T1）。

### 3.6 关键路径讨论（设计问题 2）

#### 3.6.1 现有路径的静态逻辑级数（估算，非综合结果）

> **声明**：下表的「级数」是从 Chisel 源码数出来的**结构层级**，按「1 个 3:2 CSA ≈ 1 个全加器 ≈ 2 个逻辑级」「1 个 4:2 CSA ≈ 2 个全加器 ≈ 2–3 个逻辑级」「1 个 n 位 CPA 在综合后约 `log2(n)·2` 个逻辑级（进位树）」的粗粒度模型折算。**这不是时序报告，不能用来断言是否收敛。** 真实数据由 P7 综合/静态时序分析给出。

| 段 | 最坏工况 | 结构内容 | 折算逻辑级（估算） |
|---|---|---|---|
| **S0** | 任意 SEW | Booth 重编码（`VIMac64b.scala:48-67`，~2 级）+ `calcPartProd` 的 `Mux1H(sew.oneHot, 4 项)`（`:86-88`，~3 级）+ Wallace 5 级 3:2（`:158-165`，每级含一个进位掩码 AND，~3 级/级） | ≈ 2 + 3 + 5×3 = **20** |
| **S1** | **SEW=64** | Wallace 3 级 3:2（`:178`，~9）+ 8 个 `Adder_16b` **链式串进位**（`:185-201`，`sew=64` 时 `cin_wo(i) = cout_wo(i-1)` 全链导通 = 一个 128 位 CPA，~14–20） | ≈ **23–29** |
| **S1** | **SEW=8** | Wallace 3 级 3:2（~9）+ 8 个 **互不相连** 的 16 位加法器（`:198` `cin_wo(i) := Mux(sewS1.is8, false.B, …)`，~8） | ≈ **17** |
| **S2** | **SEW=64 + vsmul** | `walOutRnd` 选择（`:231-235`，~2）+ `rndIncGen` Mux1H（`:237-252`，~3）+ 8 个 `Adder_8b_rnd` **链式串进位**（`:258-277`，`sew=64` 时全链导通 = 一个 64 位 CPA，~10–14）+ 饱和 mux（`:283-292`，~2）+ `io.vd` 三选一（`:294`，~2） | ≈ **19–23** |
| **S2** | SEW=8 非 vsmul | `vdS2` 的 `PriorityMux`（`:216-222`，~3）+ 输出 mux（~2） | ≈ **5** |

**关键观察**：整个 `vimac` FU 的时钟周期由 **SEW=64 工况**决定（S1 ≈ 23–29 级、S2 ≈ 19–23 级）。而 **vdot 三条指令只在 SEW=8（源元素 8 位）下运行**，在同样的 S1/S2 里天然有大量裕量：SEW=8 时 S1 只有 ≈17 级、S2 只有 ≈5 级。**这块裕量就是把 vdot 加法树塞进 latency=2 的资源来源**，也是本设计能不改 `FuConfig` 的根本原因。

#### 3.6.2 方案 A：抽头 `wallaceOutReg`（carry-save）—— 经分析**不可行**，予以否决

赛前侦察建议的「从 `VIMac64b.scala:178` 的 `wallaceOutReg` 取 carry-save 输出，跳过 `Adder_16b` 链，省掉一级 CPA」在数学上**不成立**，理由如下。

在 `sew=8` 下，Wallace 的进位掩码 `"h7fff7fff…7fff"`（`VIMac64b.scala:138`）把每个 16 位 lane 的进位截断，使各 lane 完全独立。于是 `wallaceOutReg(0)` / `wallaceOutReg(1)` 的 lane `i` 给出一对 16 位数 `(s_i, c_i)`，满足

```
s_i + c_i ≡ p_i   (mod 2^16)        其中 p_i 是第 i 对元素的真实 16 位二补码乘积
```

注意这是**同余**而非相等：真实加法 `s_i + c_i` 的第 17 位进位 `k_i ∈ {0,1}` 被丢弃了。我们需要的是 `Σ_i sext32(p_i)`。把 `s_i, c_i` 当作 16 位**无符号**数求全精度和，得

```
Σ_i (s_i + c_i)  =  Σ_i p_i^{unsigned}  +  2^16 · Σ_i k_i
Σ_i sext32(p_i)  =  Σ_i p_i^{unsigned}  −  2^16 · Σ_i p_i[15]
⟹ Σ_i sext32(p_i) = Σ_i (s_i + c_i) − 2^16 · Σ_i ( k_i + p_i[15] )
```

修正项需要 `k_i`（lane 加法的进位输出）与 `p_i[15]`（乘积的符号位），**二者都只有在做完那次 16 位 lane 加法之后才知道**。而那次加法正是 `Adder_16b`（`:188-201`，`sew=8` 时 `cout_wo(i)` 与 `sum_wo(i)(15)` 恰好就是 `k_i` 和 `p_i[15]`）。也就是说，抽 carry-save **省不掉** lane 级 CPA，反而要额外加一个 5 位 popcount + 一次移位减法。

> 对「符号扩展不能跨过 carry-save 边界」这一点的直观解释：carry-save 表示只在模 `2^lane_width` 意义下有效，而符号扩展是一个需要知道精确数值的非模运算。

**真正能把加法推进 Wallace 树的做法**是在 `calcPartProd`（`:70-85`）里为 dot 模式把每个 8×8 部分积**符号扩展后放进 32 位 lane**、同时把 Wallace 进位掩码从 `7fff7fff…` 换成 `7fffffff…`。这样 Wallace 树本身就完成了「每 2 个乘积合并成 1 个 32 位 lane 和」的第一层归约。代价是：
- 必须修改 `calcPartProd` 这段**所有 SEW 共用**的核心逻辑（要把 blockIdx 为奇数的部分积整体右移 16 位并做符号填充），在 S0 关键路径上插入 128 位宽 × 34 份的 mux；
- S0 已经是 ≈20 级的长段，增量风险直接作用在**所有** `vimac` 指令上；
- diff 面积大、回归风险高。

**裁定**：否决。理由见 §9 裁定 R-08。作为 P7 之后若时序有富余的优化方向保留在 §8.4。

#### 3.6.3 方案 B（推荐）：抽头 `sum_wo`，加法树跨 S1/S2 切分，latency 保持 2

```
S1（接在 sum_wo 之后，SEW=8 工况下本段仅 ≈17 级，裕量 ≥6 级）
   16 × [active 门控 AND]            ≈ 1 级
   16 × [16b → 32b 符号扩展]          0 级（纯连线）
   Fold L0 : 4 × CSA4to2(32)          ≈ 3 级
   Fold L1 : 4 × CSA4to2(32)          ≈ 3 级
   ────────────────────────────────  S1 增量 ≈ 7 级
   S1 总计（vdot 工况）≈ 17 + 7 = 24 级   vs  S1 最坏工况（SEW=64 vmul）≈ 23–29 级

S2（SEW=8 非 vsmul 工况下本段仅 ≈5 级）
   Fold L2 : 4 × CSA4to2(32)          ≈ 3 级
   Acc     : 4 × CSA3to2(32)          ≈ 2 级
   CPA     : 4 × 32 位加法器           ≈ 10 级
   RedTailGen（2 AND + 1 OR + 2 mux） ≈ 4 级
   输出 mux                            ≈ 2 级
   ────────────────────────────────  S2 增量 ≈ 21 级
   S2 总计（vdot 工况）≈ 21 级            vs  S2 最坏工况（SEW=64 vsmul）≈ 19–23 级
```

**结论（估算，非实测）**：两段的 vdot 路径都落在现有最坏工况的同一量级内，**有望在不改 `latency = 2` 的前提下收敛**。S2 是两段中更紧的一侧（≈21 vs ≈19–23），因为那里有唯一的一次 32 位 CPA。

**代价**：
- 新增 S1→S2 流水寄存器 8 × 32 = **256 bit**（相比 2 片 `VIMac64b` 现有的 ≈1840 bit 触发器增加约 14%，相比整个 `vimac` FU 的流水寄存器占比更低）。
- `sum_wo` 的扇出增加（原来只驱动 `walOut`，现在多驱动 16 个 32 位门控 AND）。属于可被综合器缓冲解决的局部问题。
- **对 `vmul`/`vmacc`/`vsmul` 的既有时序零影响**：`VIMac64b` 内部逻辑一行不改，只新增一个输出端口 `io.prod16 := sum_wo`（纯读取）。这是本方案相对方案 A 和 D 的决定性优势——任何既有指令的时序回退都不会由本次改动引入。

**变体 B′（零新增寄存器）**：把整棵树（Fold L0/L1/L2 + Acc + CPA）全放进 S2，直接复用现有的 `walOut` 寄存器（`VIMac64b.scala:208`，它在 `sew=8` 时装的就是 16 个 16 位乘积）。这样**不增加任何触发器**，但 S2 增量变成 ≈ 1 + 3 + 3 + 3 + 2 + 10 + 4 + 2 ≈ 28 级，明显超过现有 S2 最坏工况（≈19–23 级），**大概率成为新的全芯片关键路径**。仅在 P7 综合显示 S2 有大量裕量时才考虑切换。

**不能直接整体复用 `CSA_Nto2With3to2MainPipeline` 的原因**（必须让 RTL 工程师知道）：该模块（`yunsuan/src/main/scala/yunsuan/vector/VectorFloatFMA.scala:1881-1942`）的 `pipeLevel` 语义是「从第 `pipeLevel` 层**起，之后每一层都插寄存器**」——`:1899-1903` 的 `is_piped` 一旦置真就不再复位。因此 `n=16, width=32` 时压缩层数 `ceng = 4`（16→11→8→4→2），只有 `pipeLevel = 4`（寄存器落在最后一层输入）或 `pipeLevel > 4`（寄存器落在输出）这两种取值会产生**恰好一级**流水；`pipeLevel <= 3` 会产生多级流水，把 FU 延迟顶到 3 以上。
且该模块固定按 `n→11→8→4→2` 压缩，**无法表达「4 组独立 4 路」这一可重构需求**。故本设计直接例化其底层原语 `CSA4to2(32)` / `CSA3to2(32)`（`VectorFloatFMA.scala:1596` / `:1581`）自行搭树——这与 `Reduction.scala` 的做法完全一致（`Reduction.scala:472,482,491,499` 等处正是手工例化 `CSA4to2`/`CSA3to2` 搭 sew=8 的归约树）。两个原语都是 `private[vector]`，对 `yunsuan.vector.mac` 包可见。

> 原语的模 `2^width` 正确性已核对：`CSA3to2` 的 `out_car = Cat(maj(width-2,0), 0.U)`（`:1591`）丢弃最高位进位；`CSA4to2` 的 `out_sum`/`out_car` 经 `:1622-1639` 的奇偶重排后满足 `out_sum + out_car ≡ a+b+c+d (mod 2^width)`。故 32 位宽、输入已符号扩展时，二补码求和完全正确（结果只用 20 位，远未触及模边界）。

#### 3.6.4 方案 C：把 `VimacCfg.latency` 提到 3

**做法**：`$XS/src/main/scala/xiangshan/backend/fu/FuConfig.scala:563` 改一行 `CertainLatency(2)` → `CertainLatency(3)`，`VIMac64b` 内部再加一级寄存器，vdot 树从容分布在 3 段里。

**代价（这是必须说清楚的）**：`VimacCfg` 是**所有** `vimac` 指令共用的配置。改成 3 之后：

| 受影响指令 | 影响 |
|---|---|
| `vmul.vv/vx`、`vmulh*`、`vwmul*` | 延迟 2 → 3，+50% |
| `vmacc/vnmsac/vmadd/vnmsub`、`vwmacc*` | 延迟 2 → 3；且这类指令常构成 `vd` 累加链，**相关链吞吐从 1/2 周期掉到 1/3 周期，损失 33%** |
| `vsmul.vv/vx` | 延迟 2 → 3 |
| 唤醒网络 | `CertainLatency(3)` 会改变 IQ 的投机唤醒时序，`Parameters.scala` 虽不用改，但整个 VFEX0 的唤醒延迟矩阵改变 |

换言之，为了一条新指令让**十几条既有 RVV 指令集体慢一拍**，在「以极小面积/性能开销换取点积吞吐」的赛题语境下是明显的减分项。

**裁定**：作为**保底方案**保留。触发条件写死为「P7 综合报告显示方案 B 的 S2 路径为全芯片关键路径且无法通过局部优化（CPA 结构替换、Fold L2 前移、寄存器重定时）解决」。切换成本为 1 行 `FuConfig` + 1 级寄存器，可在 P7 当天完成。

#### 3.6.5 推荐与风险登记

| 方案 | latency | 新增触发器 | 对既有指令时序的影响 | 推荐度 |
|---|---|---|---|---|
| **B（推荐）**：抽头 `sum_wo`，树跨 S1/S2 | 2 | +256 bit | **零**（`VIMac64b` 逻辑不改） | ★★★★★ |
| B′：抽头 `walOut`，树全在 S2 | 2 | 0 | 零，但 S2 很可能成为新关键路径 | ★★☆☆☆ |
| A：抽头 `wallaceOutReg` carry-save | 2 | 少 | — | **否决（数学上不成立，§3.6.2）** |
| D：改 `calcPartProd` 让 Wallace 树直接做 32 位 lane 归约 | 2 | 最少 | S0 增 mux，影响所有 `vimac` 指令 | ★☆☆☆☆（P7 后的优化方向） |
| **C（保底）**：`latency = 3` | 3 | 中 | **拖慢全部 `vimac` 指令 50%**；累加链吞吐 −33% | ★★☆☆☆（仅当 B 不收敛） |

**风险登记 R-TIMING**：方案 B 的 S2 逻辑级估算（≈21）与现有最坏工况（≈19–23）处于同一量级、无明显裕量。该结论是**静态估算**，必须在 P3 完成后用 `mill` 精化 + P7 的综合/STA 实测验证。若超标，按优先级依次尝试：(1) 把 `RedTailGen` 与输出 mux 合并以省 2 级；(2) 把 Fold L2 提前到 S1（S1 增 3 级、S2 减 3 级）；(3) 切换方案 C。

---

## 4. 数据通路

### 4.1 总览

```
     vs1 (128b)                         vs2 (128b)                 v0(mask) vl vstart vta vma
        │                                   │                          │     │   │    │   │
  VecDataSplitModule                  VecDataSplitModule               └──┬──┴───┴────┴───┘
  (VIMacU.scala:62)                   (VIMacU.scala:61)                   │
        │ outVec64b                         │ outVec64b             ByteMaskTailGen(128)
   ┌────┴────┐                         ┌────┴────┐                  (eew=e8 时逐元素)
   │ [63:0]  │ [127:64]                │ [63:0]  │ [127:64]               │ activeEn[15:0]
   ▼         ▼                         ▼         ▼                        │
┌──────────────┐                    ┌──────────────┐                      │
│  VIMac64b #0 │                    │  VIMac64b #1 │                      │
│  elem 0..7   │                    │  elem 8..15  │                      │
│  srcType = s8│                    │  srcType = s8│                      │
└──────┬───────┘                    └──────┬───────┘                      │
       │ ★ io.prod16 = sum_wo              │ ★ io.prod16                  │
       │   Vec(8, 16b) = p0..p7            │   Vec(8,16b) = p8..p15       │
       └───────────────┬───────────────────┘                              │
                       ▼                                                  ▼
              ┌───────────────────────────────────────────────────────────────┐
              │                        VDotTree                                │
              │  ① 门控 + 符号扩展   E[i] = Fill(32, act[i]) & SignExt(p[i],32)│
              │  ② 可重构蝶形折叠加法树（见 §4.4）                             │
              │  ③ 累加注入 oldVd                                              │
              │  ④ 4 × 32 位 CPA  →  R0 R1 R2 R3                              │
              └──────────────────────┬────────────────────────────────────────┘
                                     │ dotVd = Cat(R3,R2,R1,R0)  (128b)
         ┌───────────────────────────┴──────────────────────────┐
         │ isDotRed (vdot/vdotacc)              isDot4a         │
         ▼                                                      ▼
   ┌────────────────┐                                  ┌──────────────────┐
   │  RedTailGen    │  照抄 Reduction.scala:644-647    │   Mgu(128)        │
   │  只保留 R0 作   │  vd_vsew_bits 固定 = 32          │   eew = e32       │
   │  元素 0，       │                                  │   activeEn/       │
   │  元素1..3 按vta │                                  │   agnosticEn      │
   └───────┬────────┘                                  └─────────┬────────┘
           │                                                     │
           └──────────────────── Mux(outIsDotRed) ───────────────┘
                                        │
                              io.out.bits.res.data (128b)
```

### 4.2 16×(8×8) 乘法阵列的复用与抽头点正确性证明

**阵列规模**：`VIMacU` 例化 2 片 `VIMac64b`（`VIMacU.scala:64`，`numVecModule = destDataBits/64 = 2`）。单片在 `sew=8` 时把 64 位源切成 8 个 8 位元素，并行做 8 组有符号 8×8 乘法（`VIMac64b.scala:70-88` 的 `calcPartProd(i, 8)`，`blockIdx = (2i)/8`，即每 4 个 Booth 组对应一个 8 位元素）。**两片合计 16 组，恰好等于 VLEN=128 / SEW=8 的元素数。**

**元素到硬件的映射**（这是 RTL 工程师最容易接错的地方）：

| 层级 | 映射 | 证据 |
|---|---|---|
| `VecDataSplitModule` | `outVec64b(0) = inVecData[63:0]`，`outVec64b(1) = inVecData[127:64]` | `$XS/src/main/scala/xiangshan/backend/fu/vector/utils/VecDataSplitModule.scala:20,25,27`（`asTypeOf(Vec)` 按小端切分） |
| `vimacs(m)` | 片 `m` 处理元素 `8m .. 8m+7` | `VIMacU.scala:95-96,113-114`：`widen=false` 时直接用 `outVec64b(i)` |
| 片内 lane | `sum_wo(b)` 对应该片的第 `b` 个 8 位元素，`b = 0..7` | `calcPartProd` 的 `shifted` 被放在 `partProd` 的 `[16b+15 : 16b]`（`VIMac64b.scala:82-84`）；`sum_wo(i)` 取 `wallaceOutReg(*)[16i+15 : 16i]`（`:189`） |
| 全局 | `p[8m + b] = sum_wo_of_module_m(b) = vs2.i8[8m+b] × vs1.i8[8m+b]` | 组合上述三条 |

**抽头点正确性**：在 `sew=8`、`widen=0`、`isMacc=0`、`isSub=0`、`isFixP=0` 条件下，`sum_wo : Vec(8, UInt(16.W))`（`VIMac64b.scala:187`）就是 **8 个完整的 16 位二补码有符号乘积，未经任何截断**。证据链：

1. `partProd(33) = Mux(io.isMacc, …, 0.U)`（`:117`）：`isMacc=0` 时不注入 `oldVd`。新 opcode `b111` 不在 `VimacOpcode.isMacc` 的列表里（`VimacOpcode.scala:17`），故 `isMacc` 自动为 0。同理 `highHalf`（`:15`）、`isSub`（`:19`）、`isFixP`（`:21`）、`overWriteMultiplicand`（`:23`）对 `b111` 全部返回 false，**无需改动这五个判定函数**。
2. `partProd(32)`（`:113`）在 `sew=8` 时取 `plus1sew8`，处理「全部负 Booth 项 +1」。两源均为 signed（`srcType = s8`）时 `!vs1_is_signed = false`，无符号修正项为 0。
3. `sew=8` 时 Wallace 进位掩码 `7fff7fff…`（`:138`）与 `Adder_16b` 的 `cin_wo(i) := Mux(sewS1.is8, false.B, …)`（`:198`）共同保证 8 个 16 位 lane 完全独立。
4. **反向验证**：现有 `vmulh.vv` 在 `sew=8` 时取 `walOut` 每 16 位 lane 的 `[15:8]`（`:221` `Mux(highHalfS2, x(15,8), x(7,0))`），而 `vmulh` 的定义是「有符号乘积的高半部分」。该行为只有在 `sum_wo(i)` 是**完整的 16 位有符号乘积**时才正确。这是对抽头点语义最强的既有证据。

因此 vdot 的改动归结为：给 `VIMac64b` 加一个纯读出端口

```scala
val prod16 = Output(Vec(8, UInt(16.W)))   // 新增
...
io.prod16 := sum_wo                        // 新增，不改任何既有逻辑
```

**为什么不能复用 `widen` 标志**：`VIMac.scala:27` 的 `widen = srcTypeVs1(1,0) =/= vdType(1,0)` 只支持 **2 倍**扩宽，且 `VIMacU.scala:92-96` 会把输入重排成 `Cat(vs_32b(i+2), vs_32b(i))`，`VIMac64b.scala:216-218` 的 `vdS2` 还会按 `uopIdxS2(0)` 选半边。vdot 需要的是 **4 倍**（8b→32b）且不重排，故三条 vdot 指令的 `VimacType` 一律取 `FMT.VVV`（`widen = false`），绕开整条 widen 通路，只走新增的 `prod16` 抽头。

### 4.3 符号扩展策略与逐级位宽推导

**符号性来源**：`VIMac64b` 的 `vs2_is_signed = io.srcType(0)(2)`、`vs1_is_signed = io.srcType(1)(2)`（`VIMac64b.scala:37-38`）；元素宽度 `eewVs2 = SewOH(io.srcType(0)(1,0))`（`:39`）。`VIMacSrcTypeModule` 为 vdot 三条指令固定产生 `vs2Type = vs1Type = Cat(0.U(1.W), 1.U(1.W), VSew.e8) = "b0100"`（= `s8`），**乘法器本体一行不改即可做有符号 8×8**。

**逐级位宽表**：

| 级 | 信号 | 位宽 | 个数 | 数值范围 | 说明 |
|---|---|---|---|---|---|
| 输入 | `vs2.i8[i]`, `vs1.i8[i]` | 8 (signed) | 16 + 16 | `[-128, +127]` | 由 `VecDataSplitModule` + `VIMac64b` 内部 `UIntSplit(vs2, 8)` 切出 |
| S1 抽头 | `p[i] = sum_wo` | 16 (signed) | 16 | `[-16256, +16384]` | 完整二补码乘积，§4.2 已证 |
| S1 门控 | `act[i]` | 1 | 16 | — | `ByteMaskTailGen` 的 `activeEn(i)`（SEW=8 时字节 = 元素） |
| S1 扩展 | `E[i] = Fill(32, act[i]) & SignExt(p[i], 32)` | **32** (signed) | 16 | `{0} ∪ [-16256, +16384]` | **符号扩展是纯连线**（复制 `p[i][15]` 16 次），门控是 1 级 AND |
| S1 Fold L0 | `(S0_g, C0_g)`，`g = 0..3` | 32 × 2 | 4 组 | `S0_g + C0_g ≡ Σ_{j<4} E[4g+j] (mod 2^32)` | 4 × `CSA4to2(32)`，组内 4 路，`|Σ| <= 4×16384 = 2^16` |
| S1 Fold L1 | `(S1_g, C1_g)` | 32 × 2 | 4 组 | 全折叠模式：`≡ Σ_{j<8} (g 所在 8 元素组)` | 4 × `CSA4to2(32)`，蝶形 Δ=1 |
| **流水寄存器** | `(S1_g, C1_g)` | **8 × 32 = 256 bit** | — | — | S1→S2 |
| S2 Fold L2 | `(S2_g, C2_g)` | 32 × 2 | 4 组 | 全折叠模式：`≡ Σ_{i<16} E[i]`，`\|Σ\| <= 2^18` | 4 × `CSA4to2(32)`，蝶形 Δ=2 |
| S2 Acc | `(S3_g, C3_g)` | 32 × 2 | 4 组 | `≡ S2_g + C2_g + accOperand_g (mod 2^32)` | 4 × `CSA3to2(32)` |
| S2 CPA | `R_g = S3_g + C3_g` | **32** | 4 | 模 `2^32` 回绕 | 4 个 32 位加法器，**各自独立，不串进位** |
| 输出 | `dotVd = Cat(R3,R2,R1,R0)` | 128 | 1 | — | `vdot/vdotacc` 只用 `R0`；`vdot4a` 用全部 4 个 |

**为什么内部取 32 位而不是最小的 20 位**：
1. `vdotacc` / `vdot4a` 要把 32 位累加器注入同一棵树，取 32 位可以让累加器**直接作为一个加数**进入 CSA，不需要任何对齐/扩展逻辑；
2. 目的 EEW 是 32，取 32 位省掉输出侧的扩展；
3. 4 × 32 = 128 恰好等于 `destDataBits`，使 `vdot4a` 的 4 个结果天然对齐到 `vd` 的 4 个 32 位元素，`Mgu` 可以不加任何重排直接使用；
4. 按 §1.6 的证明，`vdot.vv` 的真实结果只占 20 位，32 位宽的 CSA/CPA 高 12 位恒为符号位的复制 —— 这部分在综合时会被常量传播大量化简，**实际面积代价远小于 32/20 的比值**（估算，非实测）。

### 4.4 ⭐ 可重构蝶形折叠加法树（核心创新点）

#### 4.4.1 设计目标

同一棵物理加法树必须同时服务两种完全不同的归约形态：

| 形态 | 指令 | 需求 |
|---|---|---|
| **全 16 路归约** | `vdot.vv`, `vdotacc.vv` | 16 个乘积 → **1** 个 32 位结果，落在 `vd` 元素 0 |
| **4 组 × 4 路** | `vdot4a.vv` | 16 个乘积 → **4** 个独立的 32 位结果，分别落在 `vd` 元素 0..3 |

朴素做法是造两棵树再用 mux 选，面积翻倍。本设计用一个 **2 bit 的 `foldLevels` 控制信号 + 蝶形（butterfly）互连**，让同一组 12 个 `CSA4to2(32)` 同时覆盖两种形态，**结果路径上不需要任何选择器**。

#### 4.4.2 结构

```
                       16 个 32 位符号扩展乘积 E[0..15]
                                    │
  ┌─────────────────────────────────┴──────────────────────────────────┐
  │ Fold L0（恒定执行）：组内 4 路，lane 之间物理隔离                   │
  │                                                                     │
  │   lane0           lane1           lane2           lane3             │
  │  E0 E1 E2 E3     E4 E5 E6 E7    E8 E9 E10 E11  E12 E13 E14 E15     │
  │  └─CSA4to2─┘     └─CSA4to2─┘    └─CSA4to2──┘   └──CSA4to2───┘      │
  │   (S0_0,C0_0)     (S0_1,C0_1)    (S0_2,C0_2)    (S0_3,C0_3)        │
  └─────────────────────────────────┬──────────────────────────────────┘
                                    │
  ┌─────────────────────────────────┴──────────────────────────────────┐
  │ Fold L1：蝶形距离 Δ=1，伙伴 lane 索引 = g XOR 1                     │
  │   输入 = { S0_g, C0_g, fold1 ? S0_{g^1} : 0, fold1 ? C0_{g^1} : 0 } │
  │                                                                     │
  │      lane0 ←──╳──→ lane1        lane2 ←──╳──→ lane3                │
  │      └─CSA4to2─┘   └─CSA4to2─┘  └─CSA4to2─┘   └─CSA4to2─┘          │
  │   (S1_0,C1_0)   (S1_1,C1_1)   (S1_2,C1_2)   (S1_3,C1_3)            │
  └─────────────────────────────────┬──────────────────────────────────┘
                     ══════ 流水寄存器 (S1 → S2) 8 × 32b ══════
  ┌─────────────────────────────────┴──────────────────────────────────┐
  │ Fold L2：蝶形距离 Δ=2，伙伴 lane 索引 = g XOR 2                     │
  │   输入 = { S1_g, C1_g, fold2 ? S1_{g^2} : 0, fold2 ? C1_{g^2} : 0 } │
  │                                                                     │
  │      lane0 ←────────╳────────→ lane2                               │
  │      lane1 ←────────╳────────→ lane3                               │
  │      └─CSA4to2─┘ ×4                                                 │
  │   (S2_0,C2_0) (S2_1,C2_1) (S2_2,C2_2) (S2_3,C2_3)                  │
  └─────────────────────────────────┬──────────────────────────────────┘
                                    │
  ┌─────────────────────────────────┴──────────────────────────────────┐
  │ Acc：4 × CSA3to2(32)，注入累加操作数                                │
  │   accOperand_g = isDot4a            ? oldVd.u32[g]                  │
  │                : (g==0 && accLane0) ? oldVd.u32[0]                  │
  │                :                      0                             │
  │   accLane0 = isDotAcc                                               │
  └─────────────────────────────────┬──────────────────────────────────┘
                                    │
  ┌─────────────────────────────────┴──────────────────────────────────┐
  │ CPA：4 × 32 位加法器，lane 之间 **不串进位**                        │
  │   R_g = S3_g + C3_g    →  dotVd = Cat(R3, R2, R1, R0)              │
  └─────────────────────────────────────────────────────────────────────┘
```

#### 4.4.3 模式控制

```scala
// VDotTree 的唯一模式输入
val foldLevels = Input(UInt(2.W))     // 0 = 4 组 4 路；2 = 全 16 路归约
val fold1 = foldLevels >= 1.U
val fold2 = foldLevels >= 2.U
```

| 指令 | `foldLevels` | `fold1` | `fold2` | 结果 |
|---|---|---|---|---|
| `vdot4a.vv` | `0` | 0 | 0 | `R_g = Σ_{j<4} E[4g+j] + oldVd.u32[g]`，4 个独立结果 |
| `vdot.vv` / `vdotacc.vv` | `2` | 1 | 1 | `R_0 = Σ_{i<16} E[i] (+ oldVd.u32[0])`，取 `R_0` |
| （预留）8 路分组 | `1` | 1 | 0 | `R_0 = Σ_{i<8} E[i]`，`R_2 = Σ_{8<=i<16} E[i]` |

**折叠关闭时 CSA4to2 为什么是正确的直通**：`CSA4to2(a, b, 0, 0)` 输出满足 `out_sum + out_car ≡ a + b + 0 + 0 (mod 2^32)`，即仍然是 `(a,b)` 这对 carry-save 数的一个合法再表示。因此 `fold = 0` 时该级不改变数值，**不需要绕过（bypass）mux**，模式切换只作用在加数输入端的 16 个 32 位 AND 门上。这是本结构相对「两棵树 + 输出 mux」的关键优势：
- 结果路径上零 mux → 不增加关键路径；
- 面积只多出 2 级 × 4 lane × 2 字 × 32 bit = **512 个 2 输入 AND 门**；
- 功能验证只需覆盖 `foldLevels ∈ {0, 2}` 两个点。

**为什么用 XOR 蝶形而不是单向归并**：取伙伴为 `g XOR Δ` 使得**每个 lane 都执行完全相同的运算**，于是：
1. 全折叠模式下 4 个 lane 最终都持有相同的 16 路总和，`vdot` 直接取 `lane0` 即可，**元素 0 的定位不需要任何额外选择逻辑**；
2. RTL 是完全规整的 `for (g <- 0 until 4)` 生成，没有特例分支，易写易查；
3. 向更大 VLEN 扩展时只需增加折叠级数（§8.2），结构不变。

代价是全折叠模式下 lane1..3 计算了 3 份冗余结果。功耗优化手段：在 `foldLevels === 2.U` 时把 lane1..3 的 Fold L2 输入与 Acc/CPA 输入做操作数门控（置 0），可省下约 3/4 的 L2+Acc+CPA 翻转功耗。该优化**建议在 P3 实现**，代价是 3 组 32 位 AND（估算，非实测）。

#### 4.4.4 与「进位门控」式可重构的关系

本结构中「组与组之间不串进位」这一点由两处共同保证，二者都直接沿用 `VIMac64b` 已有的成熟写法：

1. **压缩阶段**：每个 lane 例化**独立的** `CSA4to2(32)` 实例，模块边界天然隔离进位（`CSA4to2` 的内部 `cout_vec(i-1)` 链不跨实例，`VectorFloatFMA.scala:1610-1619`）。这等价于 `VIMac64b.scala:137-141` 用 `Mux1H(sew.oneHot, …)` 掩码切断 Wallace 跨段进位的效果，但用结构隔离替代掩码，更易验证。
2. **CPA 阶段**：4 个 32 位加法器各自 `cin = 0`，不链接。这与 `VIMac64b.scala:188-201` 的 `Adder_16b` 链在 `sew=8` 时 `cin_wo(i) := Mux(sewS1.is8, false.B, cout_wo(i-1))` 是同一个惯用法——只不过 vdot 把 lane 宽度从 16 位换成 32 位，且 lane 边界恒定不变。

若将来需要支持「可变 lane 宽度」（例如同一硬件同时支持 int8 和 int4 子元素），只需把 CPA 的 `cin` 改成 `Mux(laneMode, cout(i-1), false.B)`，即可**原样复刻** `Adder_16b` 链的做法。这是本结构可扩展性的直接体现（§8.2）。

### 4.5 掩码 / vl 的实现

归约形态下，掩码与 `vl` 被统一折叠成「对被排除的源元素注入加法单位元 0」，这与 `Reduction.scala:186-191` 的做法同构（那里是把被掩掉的源元素替换成运算的单位元 `ele8`）。本设计把注入点从**源元素**移到**乘积**，更省逻辑：

```scala
// VIMacU 内，S0 阶段计算（与乘法阵列并行，不在关键路径上）
private val dotMaskGen = Module(new ByteMaskTailGen(VLEN))
dotMaskGen.io.in.begin    := vstart            // vdot/vdotacc 恒为 0（S-1 保证）
dotMaskGen.io.in.end      := srcVConfig.vl
dotMaskGen.io.in.vma      := vma
dotMaskGen.io.in.vta      := vta
dotMaskGen.io.in.vsew     := VSew.e8           // 源元素宽度，恒为 e8
dotMaskGen.io.in.maskUsed := srcMask(15, 0)    // SEW=8 时 16 bit 恰好对应 16 元素
dotMaskGen.io.in.vdIdx    := 0.U               // LMUL=1，单 uop
private val dotActiveEn   = dotMaskGen.io.out.activeEn   // 16 bit

// S1 阶段门控（1 级 AND）
E(i) := Fill(32, dotActiveEnS1(i)) & SignExt(prod16Cat(i), 32)
```

正确性要点（逐条对应 §1.5.1）：

| 语义 | 由谁保证 | 证据 |
|---|---|---|
| `i >= vl` 的元素不参与 | `ByteMaskTailGen` 的 `bodyEn = … & UIntToContLow1s(vlBytes, …)` | `ByteMaskTailGen.scala:66` |
| `v0.mask[i] = 0` 的元素不参与 | `activeEn = bodyEnInVd & maskEn` | `ByteMaskTailGen.scala:72,78` |
| `vm = 1` 时全部 active | `VecPipedFuncUnit` 的 `srcMask` 在 `vm=1` 时取 `allMaskTrue` | `VecPipedFuncUnit.scala:48-53` |
| **`vstart >= vl` 时连 tail 都不写（S-5）** | `activeEn` 与 `agnosticEn` 同时被 `Mux(begin >= end, 0.U, …)` 清零 | `ByteMaskTailGen.scala:78-79` |
| 全部源被掩掉仍写 `vd[0]`（S-4） | `activeEn` 全 0 ⟹ 所有 `E[i] = 0` ⟹ 树输出 0；元素 0 的写入由 `RedTailGen` 无条件执行（只要 `vl != 0`） | §4.6 |
| `vma` 被忽略（S-2） | `RedTailGen` 不读 `agnosticEn`，只读 `vta` | §4.6 |

`vdot4a.vv` 的掩码走**现有 `Mgu`**，`info.eew = outEew = e32`（`VIMacU.scala:131`，`widen=false` 且 `vsew=e32`），`Mgu` 内部 `VecDataToMaskDataVec(in.mask, e32)`（`Mgu.scala:60`）自动把 `v0` 按 32 位元素粒度展开 —— 这正是 S-7 要求的掩码粒度，**零额外代码**。

### 4.6 元素 0 定位与 tail 处理（`RedTailGen`）

归约类不走 `Mgu`（原因与 `VIPU` 相同：`Mgu` 的逐字节 active/tail 模型表达不了「只写元素 0」）。直接照抄 `Reduction.scala:644-647` 的三行，把 `vd_vsew_bits_reg` 固定成 32：

```scala
// RedTailGen：vdot / vdotacc 的写回成形
private val vdMask   = ~0.U(VLEN.W)                        // Reduction.scala:53
private val bits32   = 32.U                                // 目的 EEW 固定 32 (S-3)
private val redVdOne = (vdMask << bits32) | (dotVd & (vdMask >> (VLEN.U - bits32)))
private val redVdOld = (outOldVd & (vdMask << bits32)) | (dotVd & (vdMask >> (VLEN.U - bits32)))
private val redVd    = Mux(outVl === 0.U, outOldVd,
                       Mux(outVecCtrl.vta, redVdOne, redVdOld))
```

语义对照（与 `vdot_ref.c:94,104-108` 逐条一致）：

| 条件 | `redVd` | 裁定 |
|---|---|---|
| `vl == 0`（`vstart` 恒为 0，S-1 保证 `vstart >= vl` ⟺ `vl == 0`） | `outOldVd`，整条指令不写任何位 | S-5 |
| `vta = 1` | `[31:0] = dotVd[31:0]`，`[127:32]` 全 1 | S-3 |
| `vta = 0` | `[31:0] = dotVd[31:0]`，`[127:32] = outOldVd[127:32]` | S-3 |

> **S-5 在归约形态下的化简**：由于 S-1 强制 `vstart == 0`，「`vstart >= vl`」退化为「`vl == 0`」。这使得 `RedTailGen` 只需一个 `vl === 0` 比较，无需任何 `vstart` 比较逻辑——**S-1 直接简化了硬件**，这是裁定 S-1 的额外收益。

最终输出选择：

```scala
private val outIsDot    = VimacType.isVdot(outCtrl.fuOpType)
private val outIsDotRed = outIsDot && !VimacType.isDot4a(outCtrl.fuOpType)

mgu.io.in.vd := Mux(outIsDot, dotVd, outVd)      // vdot4a 把 dotVd 喂给 Mgu
io.out.bits.res.data      := Mux(outIsDotRed, redVd, mgu.io.out.vd)
io.out.bits.res.vxsat.get := Mux(outIsDot, false.B, (outVxsat & mgu.io.out.active).orR)
```

（`mgu.io.out.illegal` 在当前实现中恒为 `false.B`，`Mgu.scala:131`，故 `io.out.bits.ctrl.exceptionVec` 那一行无需改动。）

---

## 5. 复用说明

### 5.1 复用模块清单

| # | 模块 / 结构 | 位置 | 复用方式 | 改动量 |
|---|---|---|---|---|
| 1 | **Booth radix-4 + Wallace 乘法阵列**（2 × `VIMac64b`，16 组 8×8） | `$XS/yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/VIMac64b.scala:12-208` | **100% 原样复用**，只加一个输出端口 `io.prod16 := sum_wo` | +7 行（`rtl/patch/0002-yunsuan-vdot.patch` 实计；其中有效代码 2 行：端口声明 `val prod16 = Output(...)` 与赋值 `io.prod16 := sum_wo`，其余 5 行为空行与注释） |
| 2 | `CSA4to2(width)` 压缩原语 | `$XS/yunsuan/src/main/scala/yunsuan/vector/VectorFloatFMA.scala:1596-1643` | 直接例化 12 个 `CSA4to2(32)` | 0 行（`private[vector]` 对 `yunsuan.vector.mac` 可见） |
| 3 | `CSA3to2(width)` 压缩原语 | `$XS/yunsuan/.../VectorFloatFMA.scala:1581-1595` | 直接例化 4 个 `CSA3to2(32)` | 0 行 |
| 4 | `Mgu(vlen)` 尾部/掩码成形 | `$XS/src/main/scala/xiangshan/backend/fu/vector/Mgu.scala:34-131` | `vdot4a` 完整复用（`eew=e32` 自动给出 32 位掩码粒度） | 0 行 |
| 5 | `ByteMaskTailGen(vlen)` | `$XS/src/main/scala/xiangshan/backend/fu/vector/ByteMaskTailGen.scala:46-79` | `vdot4a` 经 `Mgu` 间接复用；`vdot/vdotacc` 新例化一份做乘积门控 | 0 行（新增一次例化） |
| 6 | 归约 tail 成形惯用法 `red_vd_tail` | `$XS/yunsuan/.../VectorALU/Reduction.scala:644-647` | 照抄 3 行，`vd_vsew_bits` 固定 32 | 照抄 3 行 |
| 7 | `VecPipedFuncUnit` 流水骨架 | `$XS/src/main/scala/xiangshan/backend/fu/vector/VecPipedFuncUnit.scala:13-94` | 100% 复用：`vs1/vs2/oldVd/vm/vma/vta/vsew/vlmul/vstart/vuopIdx/srcMask/vl` 全部现成 | 0 行 |
| 8 | `HasPipelineReg` 流水寄存器生成 | `$XS/src/main/scala/xiangshan/backend/fu/FuncUnit.scala:175-211` | 100% 复用，`latency=2` 不变 | 0 行 |
| 9 | `VecDataSplitModule` 源数据切分 | `$XS/src/main/scala/xiangshan/backend/fu/vector/utils/VecDataSplitModule.scala:13-31` | 100% 复用 | 0 行 |
| 10 | `VIMacSrcTypeModule` 类型生成框架 | `$XS/src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala:18-43` | 复用框架，新增 vdot 分支 | +6 行 |
| 11 | `VimacType` / `VimacOpcode` 编码框架 | `$XS/yunsuan/.../package.scala:364-406`、`encoding/Opcode/VimacOpcode.scala:5-24` | 复用 `LiteralCat` 布局与 5 个 `isXxx` 判定（对 `b111` 天然返回 false） | +4 行 / +3 行 |
| 12 | OPIVV 译码框架（`case class OPIVV`） | `$XS/src/main/scala/xiangshan/backend/decode/VecDecoder.scala:28-43` | 100% 复用，`src3 = SrcType.vp` 默认值直接给出三源 | +3 行表项 |
| 13 | 复杂指令 uop 拆分框架 | `$XS/src/main/scala/xiangshan/backend/decode/DecodeUnitComp.scala:194-212` | LMUL=1 时 `csBundle(0)` 保持原指令默认值，**三条指令均为单 uop，无需任何新增拆分分支** | 0 行 |
| 14 | `VecExceptionGen` 非法检查框架 | `$XS/src/main/scala/xiangshan/backend/decode/VecExceptionGen.scala:140-294` | 复用 `vstartIllegal`（S-1 天然满足）、对齐/重叠检查；新增 SEW 判定与 `vdIsSingleElem` 登记 | +8 行 |
| 15 | `FuConfig` / `FuType` / `Parameters` / Dispatch / IQ / WbArbiter | `FuConfig.scala:551-568`、`Parameters.scala:449` | **完全不动** | 0 行 |

### 5.2 新增逻辑

| 新增件 | 内容 | 规模 |
|---|---|---|
| `VDotTree`（新建，`yunsuan.vector.mac`） | 门控 + 符号扩展 + 3 级蝶形折叠（12 × `CSA4to2(32)`）+ 4 × `CSA3to2(32)` + 4 × 32 位 CPA | 约 120 行 Chisel |
| `RedTailGen`（并入 `VIMacU`） | 3 行组合逻辑 | 3 行 |
| 译码/编码/异常登记 | 见 §6 集成点清单 | 约 30 行 |

### 5.3 复用比例估算（结构计数，非综合结果）

> **方法声明**：下表以「全加器等价（FAE）」为单位，直接**从 Chisel 生成器结构中数出实例个数**，不考虑综合器的常量传播与冗余消除。因此它是一个**上界偏保守、方向正确**的量级比较，**不是面积报告**。真实面积**未实测**：本项目未做综合（`docs/stage3/22` §7.1、§10 第 1 条；后续计划 `HANDOFF_TODO.md` T2）。

**既有（被复用的）组合逻辑**——2 片 `VIMac64b` 的 Wallace 树部分：

`nAddendsSeqGen(34)` 展开为 `[34, 23, 16, 11, 8, 6, 4, 3]`（`VIMac64b.scala:149-155`，由 `n => (n/3)*2 + n%3` 逐级递推），共 8 级 `reduce3to2`，每级的 3 元组个数 `floor(n/3)` 依次为 `11, 7, 5, 3, 2, 2, 1, 1`，合计 **32 个 3:2 组**，每组宽 128 位：

```
单片 Wallace FA 数 ≈ 32 × 128 = 4096 FAE
2 片              ≈ 8192 FAE
另加 8 × Adder_16b × 2 片 ≈ 256 FAE
（Booth 编码器、34 组部分积 Mux1H、S2 的 vsmul 舍入/饱和链未计入，故分母被低估）
```

**新增组合逻辑**——`VDotTree`：

| 件 | 数量 | 单件 FAE | 小计 |
|---|---|---|---|
| `CSA4to2(32)`（Fold L0/L1/L2） | 12 | 64 | 768 |
| `CSA3to2(32)`（Acc） | 4 | 32 | 128 |
| 32 位 CPA | 4 | ≈48 | 192 |
| 折叠门控 AND（2 级 × 4 lane × 2 字 × 32 bit） | 512 门 | — | ≈100 |
| 乘积门控 AND（16 × 32 bit） | 512 门 | — | ≈100 |
| `RedTailGen` + 输出 mux | — | — | ≈50 |
| **合计** | | | **≈1338 FAE** |

```
新增 / (新增 + 复用)  ≈  1338 / (1338 + 8192 + 256)  ≈  13.7%
```

**触发器**：新增 S1→S2 的 `(S1_g, C1_g)` 共 256 bit，另加约 8 bit 控制位。2 片 `VIMac64b` 现有触发器约 `2 × (6×128 + 128 + 零散) ≈ 1840 bit`。增量 ≈ **14%**（仅相对 MAC 数据通路；相对整个 `vimac` FU（含 `ctrlVec`/`dataVec` 两级流水寄存器）占比更低）。

**结论（保守表述）**：**本设计约 85% 以上的算术逻辑来自对香山/YunSuan 现有模块的直接复用，新增逻辑不足 15%，且新增部分的压缩器单元本身（`CSA4to2`/`CSA3to2`）也是 YunSuan 现成原语，真正从零编写的只有「符号扩展 + 蝶形互连 + 模式控制 + 元素 0 成形」这些连线级逻辑。** 乘法器——这个点积单元里最贵的部件——**一个新的都没有造**。

---

## 6. 集成点清单

按**实施顺序**编号。每项给出「改什么」「照抄谁」。RTL 工程师可直接按此表逐条施工。

### 阶段 A：YunSuan 数据通路（可独立精化、独立出 Verilog、独立跑 chiseltest）

**A1** — `$XS/yunsuan/src/main/scala/yunsuan/encoding/Opcode/VimacOpcode.scala`
- 在 `:13` 的 `def vsmul = "b110".U(width.W)` 之后新增：`def vdot = "b111".U(width.W)`（3 位空间**唯一**剩余值）。
- 新增 `def isVdot(opcode: UInt) = opcode === vdot`。
- **不要**修改 `highHalf`/`isMacc`/`isSub`/`isFixP`/`overWriteMultiplicand`（`:15-23`）：它们都是对具体值的 `Seq(...).map(_ === opcode)` 判定，对 `b111` 自动返回 false，正是我们要的。
- 照抄对象：`def vsmul = "b110".U(width.W)`（`:13`）。

**A2** — `$XS/yunsuan/src/main/scala/yunsuan/package.scala`（`object VimacType`，`:364-406`）
- 在 `:399` 的 `def vsmul` 之后新增三条，用 `[8:7]` pad 位区分：
  ```scala
  //                        pad       vs2    vs1    vd_old  format   opcode
  def vdot    = LiteralCat(1.U(2.W), INT.S, INT.S, INT.X, FMT.VVV, VimacOpcode.vdot)
  def vdotacc = LiteralCat(2.U(2.W), INT.S, INT.S, INT.S, FMT.VVV, VimacOpcode.vdot)
  def vdot4a  = LiteralCat(3.U(2.W), INT.S, INT.S, INT.S, FMT.VVV, VimacOpcode.vdot)
  ```
- 新增访问器：
  ```scala
  def isVdot(t: UInt)   = t(2, 0) === VimacOpcode.vdot
  def dotVariant(t: UInt) = t(8, 7)      // 1=vdot, 2=vdotacc, 3=vdot4a
  def isDotRed(t: UInt) = isVdot(t) && t(8, 7) =/= 3.U
  def isDot4a(t: UInt)  = isVdot(t) && t(8, 7) === 3.U
  ```
- 理由：现有全部 `VimacType` 取值的 `pad == 00`（`:384-399` 逐条可见），高半空间完全空闲；`FMT.VVV` 确保 `widen = false`，绕开 2 倍扩宽通路（§4.2）。
- 照抄对象：`def vmacc = LiteralCat(0.U(2.W), INT.S, INT.S, INT.S, FMT.VVV, VimacOpcode.vmacc)`（`:391`）。

**A3** — `$XS/yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/VIMac64b.scala`
- 在 IO Bundle（`:13-30`）中新增：`val prod16 = Output(Vec(8, UInt(16.W)))`。
- 在 `:201` 的 `for` 循环之后新增一行：`io.prod16 := sum_wo`。
- **严禁修改任何既有逻辑**。这是保证 `vmul`/`vmacc`/`vsmul` 时序与功能零回退的前提（§3.6.5）。
- 照抄对象：无（纯新增端口）。

**A4** — 新建 `$XS/yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/VDotTree.scala`
- `package yunsuan.vector.mac`，`import yunsuan.vector._`（`CSA4to2`/`CSA3to2` 为 `private[vector]`，本包可见）。
- IO：
  ```scala
  val fire       = Input(Bool())          // 接 VIMacU 的 fireS1
  val prod       = Input(Vec(16, UInt(16.W)))
  val activeEn   = Input(UInt(16.W))
  val foldLevels = Input(UInt(2.W))       // 0 = 4 组 4 路，2 = 全 16 路
  val accOperand = Input(Vec(4, UInt(32.W)))   // 已在外部按模式选好
  val dotVd      = Output(UInt(128.W))
  ```
- 内部结构严格按 §4.4.2：门控 + 符号扩展 → Fold L0（4×`CSA4to2(32)`）→ Fold L1（4×`CSA4to2(32)`）→ `RegEnable(fire)` → Fold L2（4×`CSA4to2(32)`）→ Acc（4×`CSA3to2(32)`）→ 4×32 位 CPA → `Cat(R3,R2,R1,R0)`。
- **注意**：`accOperand` 必须在 S1 阶段随 `(S1_g, C1_g)` 一起寄存到 S2（它来自 `oldVd`，在 S0 就可得），或者直接用 `VecPipedFuncUnit` 的 `outOldVd`（已是 S2 级信号）——推荐后者，省 128 bit 寄存器。
- 照抄对象：`Reduction.scala:456-505`（`sew=8` 归约树手工例化 `CSA4to2`/`CSA3to2` 的写法）。**不要**用 `CSA_Nto2With3to2MainPipeline`，原因见 §3.6.3。

**A5** — 在 `VDotTree.scala` 末尾新增 Verilog 出口（满足 MASTER_PLAN L0）
```scala
object VerilogVDotTree extends App {
  println("Generating the VDotTree hardware")
  emitVerilog(new VDotTree(), Array("--target-dir=build/vdot"))
}
```
- 照抄对象：`$XS/yunsuan/.../vectorIMAC/VIMac.scala:95-98` 的 `object VerilogVIMac`。

**A6（可选）** — `$XS/yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/VIMac.scala`
- 若希望 YunSuan 独立测试平台也能测顶层，在 `:29-47` 的 `vIMac64bs` 循环之后例化 `VDotTree` 并接 `prod16`。
- 对 XiangShan 侧无影响（`VIMac` 顶层不被 XiangShan 例化）。

### 阶段 B：XiangShan FU 包装

**B1** — `$XS/src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala`，`VIMacSrcTypeModule`（`:18-43`）
- 在 `:33-35` 的三个 `val` 上套一层 vdot 覆写：
  ```scala
  private val isDot = VimacType.isVdot(fuOpType)
  private val vs2Type = Mux(isDot, Cat(vs2IntType, VSew.e8), Cat(vs2IntType, vsew))
  private val vs1Type = Mux(isDot, Cat(vs1IntType, VSew.e8), Cat(vs1IntType, vsew))
  private val vdType  = Mux(isDot, Cat(vdIntType,  VSew.e32),
                                   Cat(vdIntType, Mux(widen, vsewX2, vsew)))
  ```
- 理由：`vdot4a` 的 `vtype.vsew = e32`，但乘法阵列必须按 **e8** 切分元素；`vdot/vdotacc` 的 `vsew` 本就是 e8，覆写后不变（幂等）。
- `:37` 的 `widenIllegal = widen && vsewX2 === VSew.e8` 对 vdot 无影响（`widen` 恒 false）。
- 照抄对象：`:35` 的 `Mux(widen, vsewX2, vsew)` 写法。

**B2** — `$XS/src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala`，主体（`:45-151`）
1. 新增别名：
   ```scala
   private val isDot    = VimacType.isVdot(fuOpType)
   private val fireS1   = GatedValidRegNext(io.in.valid)   // 与 VIMac64b.scala:33 一致
   private val outIsDot    = VimacType.isVdot(outCtrl.fuOpType)
   private val outIsDotRed = VimacType.isDotRed(outCtrl.fuOpType)
   private val outIsDot4a  = VimacType.isDot4a(outCtrl.fuOpType)
   ```
2. 新例化 `ByteMaskTailGen(VLEN)` 产生 `dotActiveEn[15:0]`（输入见 §4.5），并 `RegEnable(dotActiveEn, io.in.valid)` 寄存到 S1。
3. 新例化 `VDotTree`，输入接 `Cat(vimacs(1).io.prod16, vimacs(0).io.prod16)` 展平成 `Vec(16, UInt(16.W))`（**注意片 0 对应元素 0..7**，§4.2），`fire := fireS1`，`foldLevels := Mux(outIsDot4a_s1, 0.U, 2.U)`（需把该控制位寄存到 S1）。
4. `accOperand`：
   ```scala
   for (g <- 0 until 4)
     vdotTree.io.accOperand(g) := Mux(outIsDot4a, outOldVd(32*g+31, 32*g),
                                  Mux(outIsDotAcc && g.U === 0.U, outOldVd(31, 0), 0.U))
   ```
   （`g != 0` 且非 `vdot4a` 时为 0。）
5. **`isMacc` 必须保持 0**：`mod.io.isMacc := VimacOpcode.isMacc(opcode)`（`:117`）对 `b111` 自动为 false，**不要**为了累加去打开它——`sew=8` 时 Wallace 进位掩码（`VIMac64b.scala:138`）把每 lane 锁死在 16 位，`oldVd` 进 Wallace 树会被按 8 位元素逐个加，语义完全错误。
6. 输出改造（§4.6）：
   ```scala
   mgu.io.in.vd         := Mux(outIsDot, vdotTree.io.dotVd, outVd)
   io.out.bits.res.data := Mux(outIsDotRed, redVd, mgu.io.out.vd)
   io.out.bits.res.vxsat.get := Mux(outIsDot, false.B, (outVxsat & mgu.io.out.active).orR)
   ```
7. `RedTailGen` 三行（§4.6）。
- 照抄对象：`:99-121` 的 `vimacs` 驱动循环、`:132-146` 的 `mgu` 驱动、`Reduction.scala:644-647`。

### 阶段 C：译码链路

**C1** — `$XS/src/main/scala/xiangshan/backend/decode/Instructions.scala`
- 在 `object Zimop`（`:24`）之后新增：
  ```scala
  object Xsvdot {
    def VDOT_VV    = BitPat("b111001???????????000?????1010111")
    def VDOTACC_VV = BitPat("b111010???????????000?????1010111")
    def VDOT4A_VV  = BitPat("b111011???????????000?????1010111")
  }
  ```
- 照抄对象：`object Zvbb`（`:5-22`）。

**C2** — `$XS/src/main/scala/xiangshan/backend/decode/VecDecoder.scala`
- `import` 区（`:14` 的 `import xiangshan.backend.decode.Zvbb._` 旁）加 `import xiangshan.backend.decode.Xsvdot._`。
- `opivv` 数组（`:188` 起）末尾加三行：
  ```scala
  VDOT_VV    -> OPIVV(FuType.vimac, VimacType.vdot,    T, F, F),
  VDOTACC_VV -> OPIVV(FuType.vimac, VimacType.vdotacc, T, F, F),
  VDOT4A_VV  -> OPIVV(FuType.vimac, VimacType.vdot4a,  T, F, F),
  ```
  `uopSplitType` 用默认值 `UopSplitType.VEC_VVV`：LMUL=1 时 `numOfUop = lmul = 1`（`UopInfoGen.scala:201`），`DecodeUnitComp.scala:359-365` 的循环对 `i=0` 产生 `lsrc(0)=vs1, lsrc(1)=vs2, lsrc(2)=vd, ldest=vd, uopIdx=0`，**正是三条指令需要的单 uop 形态**。
- 照抄对象：`:234` `VSMUL_VV -> OPIVV(FuType.vimac, VimacType.vsmul, T, F, T)`。

**C3** — `$XS/src/main/scala/xiangshan/backend/decode/DecodeUnit.scala:976-979`
- 把 `VDOTACC_VV` 与 `VDOT4A_VV` 加入 `vmaInsts` 列表。
- 理由：`:1069` `decodedInst.vpu.isDependOldVd := … || isVma || …`。若该位为 0，`NewDispatch.scala` 会在 `vlIsVlmax && (vm||vma) && !isWritePartVd` 时**丢弃对旧 `vd` 的依赖**，使累加读到的 `oldVd` 不可信。
- `VDOT_VV` 是否也要加：`vdot.vv` 在 `vta=0` 时需要 `oldVd` 的 `[127:32]` 做 tail-undisturbed，**也必须加**。更稳妥的等价做法是把三条指令统一登记。
- 照抄对象：列表中已有的 `VMACC_VV`。

**C4** — `$XS/src/main/scala/xiangshan/backend/decode/VecExceptionGen.scala`
1. 在 `:143` 的 `redWideningInst` 之后新增：
   ```scala
   private val dotRedInst = Seq(VDOT_VV, VDOTACC_VV).map(_ === inst.ALL).reduce(_ || _)
   private val dot4aInst  = Seq(VDOT4A_VV).map(_ === inst.ALL).reduce(_ || _)
   ```
2. `:195` 的 `eewIllegal` 增加两项：
   ```scala
   private val dotEewIllegal = dotRedInst && (SEW =/= 0.U) || dot4aInst && (SEW =/= 2.U)
   private val eewIllegal = fpEewIllegal || intExtEewIllegal || wnEewIllegal || dotEewIllegal
   ```
3. `:245` 的 `vdIsSingleElem` 加 `|| dotRedInst`（`vdot4a` **不**加，它的 `vd` 是正常的 LMUL 向量）。
   效果：`vdEmul = "b100"`（单寄存器，`:248-254`），且 `vs1AllowOverlap`/`vs2AllowOverlap`/`v0AllowOverlap` 自动放行 `vd` 与源重叠（`:260,282,289`）。
4. `:246` 的 `vdEew` 加分支：`Mux(dotRedInst || dot4aInst, 2.U /* e32 */, …)`。
5. `:220` 的 `vs1IsSingleElem` **不要**加 vdot —— `vdot.vv` 的 `vs1` 是完整的 LMUL 向量操作数，不是 `vwredsum.vs` 那种标量种子。加了会把 `vs1Emul` 错判为 `"b100"`，导致 LMUL>1 时的对齐检查失效。
6. `:275` 的 `vstartIllegal` **保持不动** —— 现有逻辑恰好实现裁定 S-1（§9 裁定 R-05）。
- 照抄对象：`redWideningInst`（`:140-143`）及其在 `:193/:220/:245/:246` 的全部用法。

**C5** — 验证 uop 拆分无需改动
- 三条指令在 LMUL=1 下均为单 uop：`UopInfoGen.scala:248` `isComplex := isVecArith || …` 使所有 `opcode=1010111` 的指令走复杂译码通路，但 `UopInfoGen.scala:201` `VEC_VVV -> lmul`，`vlmul=000` 时 `lmul=1` ⟹ `numOfUop = 1`，`DecodeUnitComp.scala:194-205` 的默认初始化即为原指令语义。
- **本版本不新增 `UopSplitType`**（裁定 S-6）。LMUL>1 的方案见 §8.3。

### 阶段 D：测试

**D1** — 新建 `$XS/yunsuan/src/test/scala/vector/VectorALU/VDotSpec.scala`
- `trait VDotBehavior` + `class VDotSpec`，用 `SrcBundle`/`CtrlBundle`（`VAluTestUtils.scala:13-31`）硬编码十六进制用例。
- 照抄对象：`VIntFixpAluSpec.scala` 的 `vMaskTest()` 与 `class VAluSpec`。
- **注意**：`SrcBundle` 的位置参数顺序是 `(vs2, vs1, old_vd, mask)`；十六进制串在该框架里是「把寄存器当 128 位大整数」的写法，与参考模型 `vdot_ref.h:49-56` 的「`v[0]` 在最左」**顺序相反**，转换时务必用脚本而非手工。

**D2** — 用例覆盖矩阵（对应 P4 验收标准）
- 正数 ≥20、负数 ≥20（含全负 / 正负混合）；
- 边界：`+127/-128/0`、全 0、全 `-128`、`vl = 0/1/15/16`、`vm` 掩码（全 0 / 全 1 / 交错）、`vta` 两种取值；
- `vstart != 0`：按修订后的 P4 标准，**三条指令的期望结果都是 Illegal Instruction**（`vdot`/`vdotacc` 依 S-1，`vdot4a` 依 S-7'，§1.5.4）。FU 级平台不建模异常，这些用例应**跳过并在报告中记录跳过条数与原因**（§1.5.3）；`vdot4a` 的 prestart 数据通路改由非规范语料 `vstart_relaxed.txt` 覆盖。

**D3** — `$XS/src/test/scala/xiangshan/DecodeTest.scala`
- 新增译码级断言：三条指令的 `fuType == FuType.vimac`、`fuOpType == VimacType.vdot/vdotacc/vdot4a`、`uopSplitType == VEC_VVV`、`numOfUop == 1`、`srcType(2) == SrcType.vp`。
- 照抄对象：`class DecodeUnitTest extends XSTester`。

**D4** — 差分测试接入
- 按 MASTER_PLAN P4 验收标准第 4 条，≥10000 组随机差分必须直接复用 `tests/golden/vdot_ref.c`，**禁止重写 golden model**。
- 注意字节序转换（见 D1 备注）。

### 阶段 E：交付

**E1** — `git diff` 生成 `rtl/patch/xiangshan-vdot.patch` 与 `rtl/patch/yunsuan-vdot.patch`（两个仓库分开），不修改 `work/` 下的 git 历史。
**E2** — `mill` 精化 + `VerilogVDotTree` 产出 `rtl/verilog/`。
**E3** — 本文档 + `scripts/tools/check_funct6.py` + `logs/stage2/check_funct6.log` 入库。

---

## 7. 对比分析

### 7.1 横向对比表

| 维度 | 本设计 `vdot.vv` | 本设计 `vdotacc.vv` | 本设计 `vdot4a.vv` | RISC-V `Zvdot4a8i` `vdot4a.vv`（draft v0.1，未批准） | ARM `SDOT Vd.4S,Vn.16B,Vm.16B` | x86 `VPDPBUSD` | Nanhu-vdot 论文 `VDOTU`（arXiv:2409.00661） |
|---|---|---|---|---|---|---|---|
| 指令格式 | OPIVV，`funct6=111001` | OPIVV，`111010` | OPIVV，`111011` | **OPMVV**，`funct6=101100` | AdvSIMD 三操作数 | VEX/EVEX | **R-type，custom-0 (`opcode=0001011`)** |
| 操作数 | 2 向量 | 2 向量 + `vd` | 2 向量 + `vd` | 2 向量 + `vd` | 2 向量 + `Vd` | 2 向量 + `dest` | **2 个通用寄存器 (GPR)** |
| 要求的 SEW | 8 | 8 | 32 | 32（其它 SEW reserved） | 固定 | 固定 | n/a |
| 每条指令的 MAC 数 | **16** | **16** | **16** | 16（VLEN=128） | 16 | 16（VL=128） | **8** |
| 每条指令的结果数 | **1（标量，落 `vd[0]`）** | **1** | 4 | 4 | 4 | 4 | **1（标量，落 GPR）** |
| 跨 lane 归约 | **全部 16 路** | 全部 16 路 | 组内 4 路 | 组内 4 路 | 组内 4 路 | 组内 4 路 | 全部 8 路 |
| 累加进目的 | **否** | **是** | 是 | 是 | 是 | 是 | **否** |
| 符号组合 | s × s | s × s | s × s | s×s / u×u / s×u / u×s 四种 | s×s（`UDOT` u×u，`USDOT` u×s） | **仅 u×s** | s × s |
| 累加宽度 | 32（内部 20 位足够） | 32 | 32 | 32 | 32 | 32 | 64 |
| 溢出 | **不可能**（§1.6 已证） | 2^32 回绕 | 2^32 回绕 | 2^32 回绕 | 2^32 回绕 | 2^32 回绕（`VPDPBUSDS` 饱和） | — |
| 掩码粒度 | 源元素（8 位） | 源元素（8 位） | 目的元素（32 位） | 目的元素（32 位） | 无掩码 | EVEX：32 位元素 | 无 |
| `vstart != 0` | **Illegal**（S-1） | **Illegal**（S-1） | **Illegal**（S-7'，平台约束；§1.5.4） | 正常生效 | n/a | n/a | n/a |
| FU 延迟 | 2 周期（P7 FU 级实测，`docs/stage3/22` §4.3） | 2 周期 | 2 周期 | 实现相关 | 实现相关 | 典型 ~5 周期（Intel 公开文档） | 论文未给 |

### 7.2 设计选择差异的理由

**(1) 为什么 `vdot.vv` 做「全向量归约 + 不累加」，而工业界的 6 个先例清一色是「4 路分组 + 累加」？**

因为赛题的学术源头是 arXiv:2409.00661（Nanhu-vdot），其 `VDOTU` 正是「8 路 int8 乘法 + 7 个加法器 → 单标量，累加由软件做」。赛题把它从 custom-0 的 R-type 改写成 RVV 的 `.vv` 形式，但归约形态与「不累加」这两个特征保留了下来。D2 据此把 `vdot.vv` 定义为**由 `vl` 决定路数的全向量归约**（`vl=8` 时与论文完全一致，`vl=16` 是 VLEN=128 的满幅形态），**是论文语义的超集**。

**(2) 既然归约形态在长向量循环里不如分组累加，为什么还要做？**

因为这正是我们同时提供 `vdotacc.vv` 与 `vdot4a.vv` 的原因：

| 场景 | 推荐指令 | 理由 |
|---|---|---|
| 单次短向量点积（≤16 个 int8） | `vdot.vv` | 一条指令出结果，直接 `vmv.x.s` 取走 |
| 长向量内积，但需要标量结果 | `vdotacc.vv` 循环 | 循环体内**没有任何归约指令**，累加直接在 FU 内完成；相比基线省掉每次迭代的 `vwredsum.vs` |
| GEMM / 矩阵乘内核 | `vdot4a.vv` 循环 | 4 路并行累加器，循环内零归约，循环外一次 `vredsum.vs` 收尾；与 ARM SDOT / x86 VPDPBUSD 的软件范式完全一致，现有量化 GEMM 内核可直接移植 |

**(3) 为什么选 OPIVV（`funct3=000`）而不是标准 `Zvdot4a8i` 用的 OPMVV（`funct3=010`）？**

- OPIVV 的 `case class` 默认 `src3 = SrcType.vp`（`VecDecoder.scala:37`），**三源读取零成本**；OPMVV 必须显式传 `vdRen = T`。
- 赛题文本写的是 `vdot.vv`，而「整数向量—向量」在直觉上对应 `funct3=000`；已公开的三个参赛队仓库中有两个读成 `000`（见 `docs/_recon/vdot-semantics-research.md` §4）。
- 本设计是**非标准自定义扩展**，不以二进制兼容 `Zvdot4a8i` 为目标；若将来需要兼容，`vdot4a.vv` 平移到 OPMVV `101100` 只需改一行 BitPat。

**(4) 为什么不做无符号/混合符号变体（`vdot4au` / `vdot4asu`）？**

硬件上几乎免费：`VIMac64b` 的符号性完全由 `srcType(0)(2)` / `srcType(1)(2)` 控制（`VIMac64b.scala:37-38`），`VimacType` 的 `INT.S/INT.U` 位已经预留。不做的唯一原因是**编码预算与验证预算**：每个变体要占一个 funct6（OPIVV 还剩 19 个，不紧张）并翻倍测试向量。列为 §8.5 的扩展方向。
需要指出：LLM int8 量化推理中 x86 选择 `u8 × s8`（激活无符号、权重有符号）是有道理的，若将来面向特定量化方案，`vdot4asu` 的优先级高于 `vdot4au`。

**(5) 与基线（D2.2 候选 D）的对比**

基线用 6 条现有 RVV 指令实现同一功能：`vsetvli e32` → `vmv.s.x` → `vsetvli e8` → `vwmul.vv` → `vsetvli e16` → `vwredsum.vs`，关键路径 3 级。

| 维度 | 基线（6 条） | `vdot.vv`（1 条） | 说明 |
|---|---|---|---|
| 指令条数 | 6 | **1** | 静态计数，确定 |
| `vsetvli` 次数 | 3 | 0（调用方已在 e8 状态） | vtype 切换在香山上可能触发流水阻塞 |
| 中间寄存器压力 | `vwmul` 产生 EMUL=2 的寄存器对 | 无 | — |
| 串行归约 | 1 次 `vwredsum.vs` | 0（在 FU 内一次完成） | 主要收益来源 |
| 端到端延迟 | 未实测 | 未实测 | 全核仿真本机不可行；**不得以估算冒充实测**。FU 级实测与依赖链模型见 `docs/stage3/22` §4–§5 |
| 加速比 | — | 见 `docs/stage3/22` §5 | 指令条数 6→2 为 3.00×（实测，计入 vdot 侧的 `vsetvli`）；FU 延迟关键路径 4→2 拍为 2.00×（**建模**） |

> 本节为 P2 阶段的定性对比，不给出延迟/加速比数字。P7 的实测值与建模值（逐项标注）见 `docs/stage3/22_基线实现与延迟加速分析.md` §5；
> 注意上表「`vdot.vv` 1 条」假设调用方已处于 e8 状态，P7 的实测口径把 vdot 侧必需的 1 条 `vsetvli` 也计入，为 6 条 vs 2 条。

---

## 8. 面积 / 功耗定性评估与扩展性论证

> **本节全部为定性分析**。任何量化表述都标注为结构计数估算，不是综合结果。真实面积/功耗/频率**未实测**（未做综合，见 `docs/stage3/22` §7、§10；后续计划 `HANDOFF_TODO.md` T2）。

### 8.1 面积与功耗定性评估

**面积**

| 项 | 定性判断 | 依据 |
|---|---|---|
| 乘法器 | **零增量**。16 路 8×8 阵列 100% 复用，不新增任何乘法器 | §4.2、§5.1 第 1 项 |
| 组合逻辑 | 新增约 1.3k FAE，相对被复用的 Wallace 树（约 8.2k FAE）增量 ≈ 14%（结构计数上界，综合后应更低：32 位 CSA 的高 12 位在 `vdot` 模式下恒为符号位复制，可被常量传播大量化简） | §5.3 |
| 触发器 | 新增 256 bit，相对 2 片 `VIMac64b` 现有约 1840 bit 增量 ≈ 14% | §5.3 |
| 关键路径 | 不增加流水级，`latency` 保持 2 | §3.6.3 |
| 对比参照 | 论文 Nanhu-vdot 在南湖上实测 LUT +2.8%、FF +0.9%、功耗 +0.47%，而它是**从零造 8 路乘法器**；本设计不造乘法器，**核级占比应显著低于该数字**（推断，非实测） | arXiv:2409.00661 实测数据 |

**功耗**

| 项 | 定性判断 |
|---|---|
| 静态 | 与面积同阶，增量很小 |
| 动态（vdot 执行时） | 新增树的翻转 + 乘法阵列本来就要翻转。相对基线的 6 条指令（6 次取指/译码/发射/写回 + 2 次 128 位中间结果写回向量寄存器堆），**单次点积的总能耗应显著下降**——减少的寄存器堆读写与流水线控制开销通常大于新增组合逻辑的翻转开销 |
| 动态（非 vdot 执行时） | `VDotTree` 的输入来自 `sum_wo`，在执行 `vmul`/`vmacc` 时会被无谓翻转。**建议在 P3 实现操作数门控**：`prod` 输入端加 `Fill(16, isDotS1)` AND，可把非 vdot 指令引起的 `VDotTree` 翻转降到接近零。代价是 256 个 AND 门（估算） |
| 冗余 lane | 全折叠模式下 lane1..3 计算冗余结果。按 §4.4.3 的建议做模式门控可省约 3/4 的 L2+Acc+CPA 翻转 |

### 8.2 扩展到更高 SEW / 更大 VLEN

**(a) SEW=16 源元素（int16 × int16 → int32/int64 点积）**

`VIMac64b` 在 `sew=16` 时单片做 4 组 16×16，两片共 **8 组**，`sum_wo` 的 lane 宽度变成 32 位（`Adder_16b` 链在 `sew=16` 时 `cin_wo(i) := Mux(sewS1.is8, false.B, cout_wo(i-1))` 对奇数 `i` 导通，`VIMac64b.scala:198`，两两合并成 32 位 lane）。
本设计的适配：
- 乘积宽度 16 → 32，符号扩展目标宽度 32 → 64；
- 折叠级数 `log2(8/组大小)`：全 8 路归约需 3 级（8→4→2→1 组），分 2 组需 2 级；
- CSA 宽度 32 → 64，CPA 32 → 64 位。
**结构完全不变，只是参数化宽度与级数。** `VDotTree` 应从一开始就写成 `class VDotTree(numProd: Int, prodWidth: Int, accWidth: Int, numLane: Int)`。

**(b) VLEN=256 / 512**

`VIMacU` 的 `numVecModule = dataWidth / 64`（`VIMacU.scala:51`）本就参数化，VLEN=256 时自动变成 4 片 `VIMac64b` = 32 路 8×8。
本设计的适配：
- 乘积数 16 → 32 → 64；
- lane 数（`vdot4a` 的结果数）4 → 8 → 16；
- 蝶形折叠级数 2 → 3 → 4（全归约需要 `log2(numProd/4)` 级）；
- **流水切点自然随之调整**：VLEN=512 时折叠级数达 4，可把前 2 级放 S1、后 2 级放 S2，仍保持 `latency = 2`；若不够，蝶形结构允许在任意级之间插寄存器而不改变功能。
- 寄存器增量随 VLEN 线性增长（`numLane × 2 × accWidth`）。

**(c) 为什么蝶形结构天然可扩展**

全归约的折叠级数是 `ceil(log2(numLane))`，每级结构完全相同（`CSA4to2(accWidth)` × `numLane`，伙伴索引 `g XOR 2^k`）。`foldLevels` 从 2 bit 扩成 `log2(log2(numLane))+1` bit 即可表达「2 路/4 路/8 路/…/全路」任意分组粒度。这使同一套 RTL 能同时覆盖：
- `vdot4a`（4 路分组，Zvdot4a8i 兼容）
- 未来的 `vdot8a`（8 路分组，对标 ARM `SMMLA` 的每结果 8 路 MAC）
- `vdot`（全路归约）

### 8.3 扩展到 LMUL > 1（本版本不交付，裁定 S-6）

本版本固定 LMUL=1。以下是 LMUL>1 的完整方案分析，供后续版本参考。

#### 8.3.1 为什么不能直接复用 `UopSplitType.VEC_VWW`

`VEC_VWW` 是 `vwredsum.vs` 用的拆分（`DecodeUnitComp.scala:1502-1523`，`numOfUop = 2 × lmul`，`UopInfoGen.scala:229`）。其末 uop 的处理是：

```scala
csBundle(numOfUop-1.U).srcType(2) := SrcType.vp    // DecodeUnitComp.scala:1519
csBundle(numOfUop-1.U).lsrc(0)    := src1          // :1520  ← 致命
csBundle(numOfUop-1.U).lsrc(2)    := dest          // :1521
csBundle(numOfUop-1.U).ldest      := dest          // :1522
```

`:1520` 把末 uop 的 `lsrc(0)` **覆写成 `vs1`**。对 `vwredsum.vs` 这是对的——`vs1[0]` 是标量种子，只在最后一步并入。但对 `vdot.vv`，`vs1` 是**真正的第二个向量操作数**，每个 uop 都要用它对应的那一段。直接复用会产生错误的 uop 图。

**结论：`VEC_VWW` 不可复用。** 这一点在 LMUL=1 下无影响（`numOfUop = 2`，但我们用的是 `VEC_VVV` 的单 uop），故本版本不受影响。

#### 8.3.2 方案一：新增 `UopSplitType.VEC_VDOT`，累加链形态（推荐）

```
uop 0        : lsrc(0)=vs1+0, lsrc(1)=vs2+0, lsrc(2)=vd, ldest=vd, uopIdx=0  → vdot   模式
uop 1..lmul-1: lsrc(0)=vs1+i, lsrc(1)=vs2+i, lsrc(2)=vd, ldest=vd, uopIdx=i  → vdotacc模式
numOfUop = lmul
```

FU 侧零改动：`VIMacU` 根据 `vuopIdx === 0.U` 决定 `accLane0`（`vdot` 的 uop0 不累加，之后累加；`vdotacc` 全程累加）。`vlRemain = vl - uopIdx*16` 的计算照抄 `Reduction.scala:87-89` 的 `shift`/`vlRemain` 写法；`vta` 的 tail 由每个 uop 原样传递（uop0 从架构 `oldVd` 取 tail，之后各 uop 从上一 uop 的结果取，链式保持）。

**关键问题：XiangShan 的 uop 框架允许同一条指令的多个 uop 写同一个架构寄存器吗？**

**答：允许，有明确的源码证据与现成先例。**

1. **Rename 支持 bundle 内旁路**：`$XS/src/main/scala/xiangshan/backend/rename/Rename.scala:546-583`。对 bundle 内第 `i` 条指令的每个源，`bypassCond(j)(i-1)` 逐一比较前面每条指令的 `ldest`（`:561` `indexMatch = in.bits.ldest === t`，`:562` `writeMatch` 按 int/fp/vec 分类），然后 `:572-583` 用 `foldLeft(... Mux(next._2, next._1, z))` 把 `psrc` 替换成**最后一个匹配者**的 `pdest`。顺序正确（后写者胜）。跨 bundle 的情形由 RAT 正常处理。
2. **现成先例**：`UopSplitType.VEC_SLIDEUP`（`DecodeUnitComp.scala:1401-1427`）。其双重循环 `for (i <- 0 until MAX_VLMUL) for (j <- 0 to i)` 中，`j==0` 的 uop 恒写 `VECTOR_TMP_REG_LMUL + 1`（`:1417-1419`），而 `i` 取 1..7 都会产生一个 `j==0` 的 uop ⟹ **同一架构寄存器 `v33` 在一条指令内被写 7 次，期间还被其它 uop 读取**。该指令在昆明湖 V2 上是正常工作的功能，证明 rename/ROB/busy-table 完全支持这种模式。
3. **ROB / 提交**：每个 uop 持有自己的 `pdest` 与旧映射，按序提交并释放，与多 uop 写不同寄存器的情形没有区别。`csBundle(0).firstUop` / `csBundle(numOfUop-1).lastUop`（`DecodeUnitComp.scala:204-205`）标记保持不变。

**精确异常的意外收益**：若在 uop `k` 之后、uop `k+1` 之前发生中断，架构 `vd[0]` 中正好是前 `k` 段的部分和，而 `vstart` 应当恢复为 `k·16`。「`uopIdx == 0` 时覆写、否则累加」的硬件语义，**恰好就是从 `vstart = k·16` 恢复执行所需的语义**。也就是说累加链形态天生具备可重启性。
（在本处理器上这一点是理论性的：`VecExceptionGen.scala:275` 对 `vstart != 0` 的向量算术指令一律报非法。）

**代价**：uop 之间是真相关链，LMUL=8 时 8 个 uop 串行，延迟 ≈ `8 × 2 = 16` 周期（解析值）。

**需要改的文件（5 个）**：
1. `$XS/src/main/scala/xiangshan/package.scala:768-816` —— 新增 `def VEC_VDOT = "b101011".U`。
   （空闲编码核实：6 位空间 64 个值中已用 45 个，空闲 19 个；其中满足 `needSplit`（`:820`，`bit4 || bit5`）的只有 `010000 / 100110 / 101000 / 101011 / 111110` 五个。选 `101011` 因为它紧邻 `VEC_VWW = 101100`，语义聚类最佳。
   **补充核实**：`needSplit` 在全树只有定义处一处出现（`grep -rn "needSplit" src/ --include="*.scala"` 仅命中 `package.scala:820`），实际并未被任何模块消费 —— 真正的复杂指令判定是 `UopInfoGen.scala:248` 的 `isComplex := isVecArith || …`。故 bit4/bit5 的约束实际上不存在，但仍建议遵守以保持一致性。）
2. `UopInfoGen.scala:198-242` —— 加 `UopSplitType.VEC_VDOT -> lmul`。
3. `DecodeUnitComp.scala` —— 加一个 `is(UopSplitType.VEC_VDOT) { for (i <- 0 until MAX_VLMUL) { …4 行赋值… } }` 分支，照抄 `VEC_VVV`（`:359-367`）但把 `lsrc(2)` / `ldest` 固定为 `dest`（不加 `i`）。
4. `DecodeUnit.scala:1062` —— 把 `VEC_VDOT` 加入 `isWritePartVd` 列表（归约类只写部分 `vd`，Dispatch 的 `ignoreTail` 优化必须对它关闭）。
5. `VecDecoder.scala` —— 三行表项的 `uopSplitType` 从默认 `VEC_VVV` 改为 `VEC_VDOT`（仅归约两条；`vdot4a` 继续用 `VEC_VVV`，它本来就是标准的逐元素指令，`lsrc/ldest` 都要 `+i`）。

#### 8.3.3 方案二：二叉树形态（照搬 `VEC_VWW` 但修正 `lsrc(0)`）

```
uop 0..lmul-1      : lsrc(0)=vs1+i, lsrc(1)=vs2+i, ldest=TMP+i   （段内点积，写 32 位部分和）
uop lmul..2lmul-2  : 把 TMP 两两相加                              （需要一个新的「加元素0」模式）
末 uop             : lsrc(2)=vd, ldest=vd
```

- 优点：前 `lmul` 个 uop 彼此独立，可流水；总延迟 ≈ `lmul + 2·log2(lmul)` 周期，LMUL=8 时约 14 周期，略优于方案一的 16。
- 缺点：uop 数 `2·lmul - 1`（LMUL=8 时 15 个，vs 方案一的 8 个），译码拆分逻辑复杂得多，且 FU 必须新增一个「把两个源的元素 0 相加」的模式（`Reduction.scala` 用 `alu_uop` 处理这件事，`:683`）。
- **裁定：不推荐**。uop 数接近翻倍，译码逻辑复杂度与验证成本的上升远超 2 个周期的收益。

#### 8.3.4 `vdot4a.vv` 的 LMUL>1

无需任何新增拆分类型：`vdot4a` 是标准的三源逐元素指令，`UopSplitType.VEC_VVV`（`DecodeUnitComp.scala:359-367`）直接给出 `lsrc(0)=vs1+i, lsrc(1)=vs2+i, lsrc(2)=vd+i, ldest=vd+i`，与 `vmacc.vv` 完全同构。**LMUL>1 对 `vdot4a` 是开箱即用的**，只要把 `VecExceptionGen` 的对齐检查配好。

### 8.4 扩展到其它归约类指令

本设计的 `VDotTree` 剥掉乘法器之后就是一棵**可重构分组归约树**。只要把输入从「乘积」换成「源元素」，同一结构可直接服务：

| 潜在指令 | 复用方式 |
|---|---|
| `vredsum.vs` 的加速版 | 输入换成符号/零扩展后的源元素，`foldLevels = max`；但香山已有 `Reduction`，收益有限 |
| 分组求和 `vsegredsum`（RVV 1.1 讨论中的段内归约） | `foldLevels` 直接表达段大小 |
| int4 子元素点积（`vdot8a`，每 32 位元素 8 个 int4） | 乘法阵列需支持 4×4；加法树只需把 `numProd` 翻倍、折叠级数 +1 |
| 绝对差之和 `SAD`（视频编码常用） | 把 `CSA4to2` 前面的乘法器换成减法+绝对值，树完全不变 |

### 8.5 其它扩展方向（优先级排序）

1. **`vdot4asu.vv`（u8 激活 × s8 权重）**：对标 x86 `VPDPBUSD`，LLM int8 量化推理的主流布局。硬件成本仅为 `VimacType` 的 `INT.U/INT.S` 位取值不同（`VIMac64b` 的符号性完全由 `srcType` 控制），**几乎零面积增量**，占 1 个 funct6。
2. **`.vx` 变体**：`vdot4a.vx` 用 `rs1` 广播一组 4 字节权重，对 GEMM 很有用。需要 `i2v` 前置 uop（照抄 `VEC_VXV`）。
3. **操作数门控与冗余 lane 门控**（§8.1）：纯功耗优化，无功能风险。
4. **方案 D（Wallace 树内 32 位 lane 归约）**：若 P7 综合显示 S1/S2 都有大量裕量，可进一步省掉 Fold L0 一级，代价是改动 `calcPartProd`（§3.6.2）。

---

## 9. 设计裁定记录

本节记录设计过程中遇到的每一处歧义、候选方案与最终裁定。

| 编号 | 歧义 / 问题 | 候选方案 | 裁定与理由 |
|---|---|---|---|
| **R-01** | vdot 应插在哪个 FU？ | (a) `FuType.vimac` / `VIMacU`；(b) `FuType.vipu` / `VIPU`；(c) 新增 `FuType.vdot`；(d) 归约放 `VIPU`、`vdot4a` 放 `VIMacU` | **(a)**。16 路 8×8 乘法阵列在 v2 上**只存在于** `VIMacU`（`VIMacU.scala:64`）；`VIAlu` 内部没有任何乘法器（`VIAlu.scala:35,38`）。(c) 会使 one-hot `FuType.num` +1，波及 `DecodedInst`/IQ/ROB/旁路网络。(d) 会导致乘法阵列翻倍，直接违背「复用」评分项。 |
| **R-02** | `funct3` 取 `000`(OPIVV) 还是 `010`(OPMVV)？ | (a) OPIVV；(b) OPMVV（与 `Zvdot4a8i` 一致）；(c) 两个都译码 | **(a) OPIVV**。理由：① `case class OPIVV` 的 `src3` 默认就是 `SrcType.vp`（`VecDecoder.scala:37`），三源读取零成本；② 赛题写 `vdot.vv`，已公开的参赛队仓库多数读成 `000`；③ 本设计不以二进制兼容未批准的草案为目标。否决 (c)：同一语义占两套编码会使译码表、NEMU、测试向量全部翻倍，收益只是规避一个本不存在的风险。 |
| **R-03** | `VimacOpcode` 只剩 `b111` 一个值，三条指令怎么放？ | (a) 三条共用 `b111`，靠 `VimacType[8:7]` pad 位区分；(b) 把 `VimacOpcode.width` 从 3 扩到 4 | **(a)**。`VimacType` 是 9 位（`yunsuan/package.scala:8`），现有全部取值的 `[8:7] == 00`（`:384-399` 逐条可见），高半空间 384 个值全空。(b) 要改 `VimacOpcode.width` 和所有 `getOpcode` 切片，diff 大且无必要。 |
| **R-04** | `vdotacc` / `vdot4a` 的累加走 `isMacc`（进 Wallace 树）还是走新加法树？ | (a) 走 `isMacc`；(b) 在 `VDotTree` 末级注入 | **(b)**。`sew=8` 时 Wallace 进位掩码 `"h7fff7fff…"`（`VIMac64b.scala:138`）把每 lane 锁死在 16 位，且 `partProd(33)` 的 `oldVdReorg`（`:115-117`）是按 SEW 分段扩展的 —— `oldVd` 进 Wallace 树会被当成 16 个 8 位元素逐个加，语义完全错误，**且 32 位累加器根本放不进 16 位 lane**。 |
| **R-05** | 设计问题 3：`VecExceptionGen.scala:275` 对 `vstart != 0` 的向量算术指令一律报非法，而 `Reduction.scala` 全文 0 次出现 `vstart` —— 这是冲突还是契合？ | (a) 视为缺陷，为 vdot 放宽 `vstartIllegal`；(b) 视为与 S-1 契合，直接复用 | **(b)**。D2.1 裁定 **S-1** 明确规定 `vdot.vv`/`vdotacc.vv` 在 `vstart != 0` 时抛 Illegal Instruction，依据 RVV 1.0 §14「Vector reduction operations raise an illegal instruction exception if vstart is non-zero」。`VecExceptionGen.scala:275` 的 `vstartIllegal = isVArith && (io.vstart =/= 0.U)` **恰好就是这个语义**，`FuType.vimac ∈ vecArith`，故 **S-1 不需要任何新增代码即自动成立**。这同时解释了为什么 `Reduction.scala` 可以完全不实现 prestart —— 那是自洽的设计取舍，不是缺陷。本设计因此也获得两点简化：① `RedTailGen` 只需 `vl === 0` 一个比较（§4.6）；② §4.5 的 `ByteMaskTailGen.io.in.begin` 恒为 0。 |
| **R-06** ⚠️**已被 R-17 修订** | `vdot4a.vv` 按 S-7 要求 `vstart` 正常生效，但 `vstartIllegal` 会在译码阶段挡掉它 | (a) 为 `vdot4a` 放宽 `vstartIllegal`；(b) 数据通路照 S-7 实现，但接受全核层面不可达，在文档中写明 | **原裁定 (b)**。`vstartIllegal` 是一条影响**全部**向量算术指令的公共判据，为一条新指令开特例会扩大回归面。数据通路侧 `Mgu` 的 `info.vstart` 本来就接着 `outVecCtrl.vstart`（`VIMacU.scala:140`），prestart 天然正确，只是全核上到不了。<br>**R-06 的「不改 RTL」结论至今成立且已被实测确认**，但它当时**低估了后果**：把两侧行为不一致当成「一处不可达」记录下来，而没有同时修订 ISA 定义。P6 协同仿真证明那其实是 1946 条确定性的全核 difftest mismatch。修订见 **R-17 / 裁定 S-7'**（§1.5.4）。 |
| **R-07** | 设计问题 1：LMUL>1 的 uop 拆分 | (a) 复用 `VEC_VWW`；(b) 新增 `VEC_VDOT` 累加链；(c) 新增 `VEC_VDOT` 二叉树；(d) 本版本固定 LMUL=1 | **(d) 本版本固定 LMUL=1（D2.1 裁定 S-6）**，`uopSplitType` 用默认的 `VEC_VVV`，`numOfUop = 1`。(a) 已核实不可行：`DecodeUnitComp.scala:1520` 把末 uop 的 `lsrc(0)` 覆写成 `vs1`，对 `vwredsum.vs` 的标量种子是对的，对 `vdot.vv` 的向量操作数是错的。(b) 已核实**框架允许**（Rename 的 bundle 内旁路 `Rename.scala:546-583`；现成先例 `VEC_SLIDEUP` 在一条指令内把 `VECTOR_TMP_REG_LMUL+1` 写 7 次，`DecodeUnitComp.scala:1412-1426`），且具备天然的可重启语义，列为后续版本首选（§8.3.2）。(c) 不推荐：uop 数接近翻倍。 |
| **R-08** | 设计问题 2：加法树抽头点 | (a) `wallaceOutReg` carry-save；(b) `sum_wo`；(c) `walOut`；(d) 改 `calcPartProd` 做 32 位 lane | **(b)**，树跨 S1/S2 切分，`latency` 保持 2。(a) **数学上不成立**：carry-save 的 lane 表示只在模 2^16 下有效，符号扩展需要精确数值；修正项 `Σ(k_i + p_i[15])` 又依赖 lane 级 CPA 的输出，省不掉（§3.6.2 给出完整推导）。(c) 零新增寄存器但 S2 增量 ≈28 级，大概率成为新关键路径。(d) 要动 `calcPartProd` 这段所有 SEW 共用的 S0 核心逻辑，风险作用在全部 `vimac` 指令上。 |
| **R-09** | 能否直接用 `CSA_Nto2With3to2MainPipeline` 搭树？ | (a) 用；(b) 手工例化 `CSA4to2`/`CSA3to2` | **(b)**。该模块的 `pipeLevel` 语义是「从第 `pipeLevel` 层**起每层都插寄存器**」（`VectorFloatFMA.scala:1899-1903` 的 `is_piped` 一旦置真不复位），`n=16` 时只有 `pipeLevel = 4` 或 `> 4` 才产生恰好一级流水；更关键的是它固定按 `16→11→8→4→2` 压缩，**无法表达「4 组独立 4 路」的可重构需求**。手工例化其底层原语与 `Reduction.scala:472-505` 的做法完全一致，仍然是复用。 |
| **R-10** | `latency` 保持 2 还是提到 3？ | (a) 保持 2；(b) 提到 3 | **(a)，(b) 作保底**。(b) 只需改 `FuConfig.scala:563` 一行，但会让 `vmul`/`vmulh`/`vwmul*`/`vmacc`/`vnmsac`/`vmadd`/`vnmsub`/`vwmacc*`/`vsmul` 等十余条既有指令**集体慢 50%**，且 `vmacc` 类累加链吞吐损失 33%。切换触发条件写死为「P7 综合显示方案 B 的 S2 为全芯片关键路径且局部优化无效」。 |
| **R-11** | 可重构树用「两棵树 + 输出 mux」还是「蝶形折叠 + 输入门控」？ | (a) 两棵树；(b) 单向归并 + bypass mux；(c) XOR 蝶形 + 输入门控 | **(c)**。(a) 面积近乎翻倍。(b) 结果路径上有 mux，增加关键路径。(c) 利用 `CSA4to2(a,b,0,0)` 是合法直通这一性质，模式切换只作用在**加数输入端的 AND 门**上，结果路径零 mux；XOR 蝶形还使每个 lane 运算完全相同，`vdot` 直接取 lane0，省掉元素 0 的选择逻辑（§4.4.3）。 |
| **R-12** | 归约形态的掩码在哪里注入单位元？ | (a) 源元素（照抄 `Reduction.scala:186-191`）；(b) 乘积 | **(b)**。乘积门控只需 16 个 32 位 AND（在 S1，该段有裕量），而源元素门控要在 S0 的乘法阵列入口动手，会挤占 S0（≈20 级，最长的一段）。加法的单位元是 0，两种注入点数学等价。 |
| **R-13** | 归约形态走 `Mgu` 还是自建 tail 逻辑？ | (a) `Mgu`；(b) 照抄 `Reduction.scala:644-647` | **(b)**。`Mgu` 的逐字节 active/tail 模型表达不了「只写元素 0，其余按 `vta`」。`VIPU` 面对同样的问题也是绕过 `Mgu`（`wrapper/VIPU.scala:149` 直接 `io.out.bits.res.data := vialu.io.out.bits.vd`；该文件虽在 `:31` import 了 `Mgu`，但全文没有 `Module(new Mgu)`）。`vdot4a` 是正常的逐元素指令，继续走 `Mgu`。 |
| **R-14** | `vdot.vv` 是否需要饱和逻辑 / `vxsat`？ | (a) 需要；(b) 不需要 | **(b)**。§1.6 给出严格证明：`|Σ p_i| <= 16 × 16384 = 2^18 < 2^31`，不可能溢出。`io.out.bits.res.vxsat` 对 vdot 三条指令恒为 0。`vdotacc`/`vdot4a` 的累加按 RVV §11 回绕，同样不置 `vxsat`。 |
| **R-15** | `vdot.vv` 的 `vs1` 要不要登记进 `VecExceptionGen` 的 `vs1IsSingleElem`？ | (a) 要（照抄 `redWideningInst`）；(b) 不要 | **(b)**。`vs1IsSingleElem`（`VecExceptionGen.scala:220`）会把 `vs1Emul` 设成 `"b100"`（单寄存器，`:222`）。这对 `vwredsum.vs` 是对的（`vs1[0]` 是标量种子），对 `vdot.vv` 是错的（`vs1` 是完整的 LMUL 向量）。只有 `vdIsSingleElem`（`:245`）要加，因为 `vd` 确实只占一个寄存器。 |
| **R-17** | 协同仿真发现：`vdot4a` + `vstart != 0` 在 NEMU 上正常执行、在香山上判非法（1946 条确定性分歧）。改哪一侧？ | (a) 改香山向 NEMU 靠：为 `vdot4a` 在 `vstartIllegal` 上开例外，并让 `Mgu` 处理 prestart；(b) 改 NEMU/ISA 向香山靠：把 `vdot4a` 的 `vstart != 0` 也裁定为非法（**裁定 S-7'**） | **(b)，依据「平台约束优先原则」**：自定义指令的 ISA 语义不应宽于宿主微架构的实际能力。昆明湖 V2 的向量算术通路不支持非零 `vstart` 重启，这是既有架构事实；让 ISA 向微架构收敛，改动面只在本指令族内，且使三条 vdot 指令与同平台所有标准向量算术指令的 `vstart` 行为完全一致（实测对照 `bench/results/vstart_control.csv`，8 条指令在 `vstart=1` 时一律 `TRAP mcause=2`）。否决 (a) 的理由同 R-06：改公共判据的回归面是整个向量后端。**本裁定是平台约束驱动的，不是语义内在限制** —— 支持 `vstart` 重启的实现可以放宽（参考模型的 `VDOT_VSTART_SKIP` 策略 + 非规范语料 `vstart_relaxed.txt` 的 40 条 vdot4a 用例已给出可执行定义）。完整论证见 §1.5.4，发现过程见 `docs/stage3/21` §7.3。**RTL 侧零改动**，由 `tests/unit/vecexcgen_tb.cpp` 的 `[I]` 组实测确认。 |
| **R-16** | 机器码示例要不要用汇编器实际验证？ | — | 本机无 RISC-V 工具链，`.insn r` 宏的可接受性标注为 **UNVERIFIED**；`.word` 形式的机器码由位域拼接算得并用脚本复核，P4 阶段须用 `objdump -d` 回读确认。 |

---

## 10. 遗留事项与下游依赖

| # | 事项 | 承接阶段 |
|---|---|---|
| 1 | `VDotTree` 与 `VIMacU` 的 Chisel 实现，按 §6 集成点清单逐条施工 | P3 |
| 2 | `mill` 精化通过 + `VerilogVDotTree` 产出 Verilog | P3 |
| 3 | §3.6 全部逻辑级数估算的综合/STA 实测验证；若 S2 超标按 R-TIMING 的优先级处理 | P7 |
| 4 | 面积 / 功耗 / 频率实测数值回填（原文中「待 P7 实测回填」的占位）—— **P7 未能完成**：未做综合，相关位置已改写为「未实测」并给出原因 | P7 → 后续（`HANDOFF_TODO.md` T2） |
| 5 | `.insn r` 宏的汇编器可接受性验证（`objdump -d` 回读） | P4 |
| 6 | 单条 `vdot.vv` 的 RTL 实测周期数、背靠背间隔、与基线候选 D 的加速比 —— **P7 已完成**：FU 级实测 2 周期、加速比见 `docs/stage3/22` §5；背靠背间隔未实测（需全核） | P7 |
| 7 | LMUL>1（`UopSplitType.VEC_VDOT`）、`.vx` 变体、混合符号变体 | 后续版本 |
