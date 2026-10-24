# 20 NEMU 指令扩展说明（vdot 指令族）

> 对应赛题条款：**阶段三 3.1.1 NEMU 指令扩展**
> 对应总体方案：`docs/_plan/MASTER_PLAN.md` 决策 **D2 / D2.1（S-1…S-9）**、分层验证 **L2**、阶段 **P5**
> 语义唯一事实来源：`tests/golden/vdot_ref.c`（说明见 `docs/stage2/13_参考模型与测试向量说明.md`）
> 交付物：`nemu/patch/0001-add-vdot-instruction-family.patch`、`nemu/README.md`、`tests/riscv/vdot/`、`scripts/21_build_nemu_vdot.sh`
> 真实运行日志：`logs/stage3/p5_nemu_build.log`、`p5_vdot_tests.log`、`p5_fault_injection.log`、`p5_patch_verify.log`

本文中所有 `文件:行号`：

* **上游未改动的文件**（`include/cpu/*.h`、`src/cpu/*`、`src/isa/riscv64/instr/decode.c`、
  `src/isa/riscv64/instr/rvv/vcompute_impl.c` / `vcommon.c` / `vreg_impl.c` / `vreg.h`）
  的行号在 NEMU commit `9090839` 原始状态与打完 patch 后**完全一致**；
* **被本 patch 改动的文件**（`Kconfig`、`isa-all-instr.h`、`rvv/decode.h`、`vcompute.h`、
  `vcompute_impl.h`）给出的是**打完 patch 之后**的行号，正文中会显式标注「(patch 后)」。

---

## 0. 一句话总结

在 NEMU（香山官方 difftest 参考模型，commit `9090839`）里新增一个
`CONFIG_CUSTOM_XVDOT` 配置项与 8 个文件、+258/-1 行的改动，实现
`vdot.vv` / `vdotacc.vv` / `vdot4a.vv` 三条自定义 OPIVV 指令；
用 30710 条语料（30663 条共享语料 + 47 条补充定向语料，期望值全部由
`tests/golden/vdot_ref.c` 生成）在 **独立解释器**与 **difftest 参考共享库**上
各跑一遍，**0 失配**；再用 5 次故障注入证明该测试确实能检出错误。

---

## 1. NEMU 的译码机制

### 1.1 整体流水：取指 → 译码 → 执行

```
cpu_exec()                       src/cpu/cpu-exec.c
   └─ fetch_decode()/execute()
        ├─ isa_fetch_decode(s)   src/isa/riscv64/instr/decode.c:128
        │     └─ table_main(s)   src/isa/riscv64/instr/decode.c:165
        │           └─ 一层层 def_INSTR_TAB 模式匹配，最终返回一个 EXEC_ID_xxx
        └─ g_exec_table[EXEC_ID_xxx](s)   src/cpu/cpu-exec.c:595
              └─ exec_xxx(s)     由 def_EHelper(xxx) 生成
```

NEMU **没有**用 ysyx 教学版的 `INSTPAT` 宏；香山版用的是
`def_INSTR_TAB` / `def_INSTR_IDTAB` 这一套模式匹配 DSL。

### 1.2 `def_INSTR_TAB`：编译期把模式串变成一次比较

`include/cpu/decode.h:192-203`：

```c
#define def_INSTR_raw(pattern, body) do { \
  uint64_t key, mask, shift; \
  pattern_decode(pattern, STRLEN(pattern), &key, &mask, &shift); \
  if ((((uint64_t)get_instr(s) >> shift) & mask) == key) { body; } \
} while (0)

#define def_INSTR_IDTABW(pattern, id, tab, width) \
  def_INSTR_raw(pattern, { concat(decode_, id)(s, width); return concat(table_, tab)(s); })
#define def_INSTR_IDTAB(pattern, id, tab)   def_INSTR_IDTABW(pattern, id, tab, 0)
#define def_INSTR_TAB(pattern, tab)         def_INSTR_IDTABW(pattern, empty, tab, 0)
```

`pattern_decode()`（`include/cpu/decode.h:162`）是 `always_inline` 的 `constexpr`
风格函数，把 `"111001 ? ????? ????? ??? ????? ????? ??"` 这种字符串在**编译期**
折算成 `(key, mask, shift)` 三元组，运行期只剩一次
`((instr >> shift) & mask) == key`。模式串规则：

* `0` / `1` = 必须匹配位，`?` = don't care，空格忽略；
* **从高位往低位写**，长度不必是 32，尾部连续的 `?` 会被折算进 `shift`。

`def_INSTR_IDTAB` 比 `def_INSTR_TAB` 多做一步：先调 `decode_<id>()`（DHelper，
负责解析操作数），再跳进下一级 `table_<tab>()`。

### 1.3 指令表的三段式自动生成

| 生成物 | 宏 | 位置 | 作用 |
|---|---|---|---|
| `EXEC_ID_<name>` 枚举 | `def_EXEC_ID` / `def_all_EXEC_ID()` | `include/cpu/decode.h:109-111`，实例化于 `src/isa/riscv64/include/isa-all-instr.h:507`(patch 后) | 用 `__COUNTER__` 给每条指令自动编号 |
| `table_<name>()` 叶子函数 | `def_THelper_ternary` / `def_all_THelper()` | `include/cpu/decode.h:117-141`，实例化于 `src/isa/riscv64/instr/decode.c:26` | 打印反汇编模板并 `return EXEC_ID_<name>` |
| `exec_<name>()` 执行体 | `def_EHelper(name)` | `include/cpu/exec.h:22-30` | 解释器真正干活的函数 |
| 跳转表 `g_exec_table[]` | `FILL_EXEC_TABLE` + `MAP(INSTR_LIST, …)` | `src/cpu/cpu-exec.c:262/434-436`（PERF_OPT 计算 goto 版）、`:588/595`（函数指针版） | `EXEC_ID` → `exec_<name>` |

三者都由同一份名单 `INSTR_LIST(f)` 驱动（`include/cpu/decode.h:104`，
展开为 `INSTR_NULLARY/UNARY/BINARY/TERNARY/TERNARY_CSR`）。
**因此：任何新指令必须先在 `src/isa/riscv64/include/isa-all-instr.h` 的名单里注册，
否则 `EXEC_ID_xxx` / `table_xxx` 都不存在，编译直接报错。** 这就是本次改动 ②。

### 1.4 RVV 的四级译码链

| 级 | 位置 | 判据 |
|---|---|---|
| ① 顶层 opcode | `src/isa/riscv64/instr/decode.c:100`<br>`def_INSTR_IDTAB("??????? ????? ????? ??? ????? 10101 ??", OP_V, OP_V)` | `opcode[6:2] = 10101` → OP-V (0x57) |
| ② DHelper 解操作数 | `src/isa/riscv64/instr/rvv/decode.h:25` `def_DHelper(OP_V)` | 解出 `vs1/vs2/vd`，按 funct3 设 `s->src_vmode`，设 `s->v_width`、`s->vm = instr.v_opv.v_vm` |
| ③ 按 funct3 分发 | `src/isa/riscv64/instr/rvv/decode.h:541` `def_THelper(OP_V)` | `000→vopivv  001→vopfvv  010→vopmvv  011→vopivi  100→vopivx  101→vopfvf  110→vopmvx  111→vsetvl_dispatch` |
| ④ 按 funct6 查表 | `src/isa/riscv64/instr/rvv/decode.h:163` `def_THelper(vopivv)` | 本次新增的三条就挂在这里（patch 后 `:214-220`） |

模式串在 OPIVV 一级的分段含义：

```
"111001 ? ????? ????? ??? ????? ????? ??"
 ├─6位─┘ │ └5位┘ └5位┘ └3位┘ └5位┘ └5位┘ └2位
 funct6  vm   vs2    vs1  funct3  vd  opcode[6:2] opcode[1:0]
```

注意 ③ 已经用 funct3 把 OPIVV 筛出来了，所以 ④ 的模式串里 funct3 位可以写 `???`
（与上游 `vadd`/`vwredsum` 等写法完全一致）。

---

## 2. 本次改动逐项对照表

补丁：`nemu/patch/0001-add-vdot-instruction-family.patch`
（sha256 `68410b8a59fd2246e2636876ec8c4c88a1ff01a1ec1f738b7dc1406b19e2b284`，
8 个文件 **+258 / -1** 行）。

| # | 文件（patch 后行号） | 行数 | 改动内容 | 为什么需要 | 模板来源 |
|---|---|---:|---|---|---|
| ① | `src/isa/riscv64/Kconfig:147-156` | +11 | 新增 `config CUSTOM_XVDOT`，`depends on RVV`，`default n` | 非标准指令必须可开关，默认关闭不影响上游其他配置 | `CUSTOM_XVEXP2`（`Kconfig:133-138`） |
| ② | `src/isa/riscv64/include/isa-all-instr.h:155-159` 与 `:502` | +8/-1 | `#define XVDOT_INSTR_TERNARY(f) f(vdot_vv) f(vdotacc_vv) f(vdot4a_vv)`，并在 `INSTR_TERNARY(f)` 列表末尾追加 `XVDOT_INSTR_TERNARY(f)` | 注册进 `INSTR_LIST`，才会生成 `EXEC_ID_*` / `table_*` / 跳转表项（见 §1.3） | `XVEXP2_INSTR_TERNARY`（`:143-147`） |
| ③ | `src/isa/riscv64/instr/rvv/decode.h:214-220` | +8 | 在 `vopivv` 表里加三条 `def_INSTR_TAB`（funct6 = `111001`/`111010`/`111011`），用 `#ifdef CONFIG_CUSTOM_XVDOT` 包住 | 让 funct6 匹配到对应的 `table_vdot_*` | 同表的 `vwredsum`（`:208`）等 |
| ④ | `src/isa/riscv64/instr/rvv/vcompute.h:1355-1370` | +17 | 三个 `def_EHelper(vdot_vv/vdotacc_vv/vdot4a_vv)`，各自展开成 `VDOT_ARITH(VDOT/VDOTACC/VDOT4A)` | 提供解释器真正调用的 `exec_*` 函数 | `def_EHelper(vredsum){REDUCTION(...)}`（`vcompute.h:260`）、`def_EHelper(vmacc){ARITH(...)}`（`:868`） |
| ⑤ | `src/isa/riscv64/instr/rvv/vcompute_impl.h:69-71 / :90-92 / :120-122` | +11 | `enum op_t` 末尾追加 `VDOT, VDOTACC, VDOT4A`；声明 `void vdot_instr(int, Decode*)`；新增宏 `VDOT_ARITH(opcode)` | 与 `ARITH()/REDUCTION()` 同构的微操作码 + 派发宏 | `#define REDUCTION(...)`（同文件 `:118`） |
| ⑥ | `src/isa/riscv64/instr/rvv/vdot.c`（**新增**） | +201 | 执行引擎：`vdot_check()` / `vdot_get_i8()` / `vdot_reduce()` / `vdot4a_exec()` / `vdot_instr()` | 三条指令的目的 EEW（32）与源 EEW（8）不同，通用的 `arithmetic_instr()` 统一 EEW 模型表达不了，必须单写 | 结构逐段对照 `reduction_instr()`（`vcompute_impl.c:1529`）与 `arithmetic_instr()`（`:488`） |
| ⑦ | `configs/riscv64-xs-kmhv2_defconfig:36` | +1 | `CONFIG_CUSTOM_XVDOT=y` | 独立解释器形态（L2 跑测试程序） | — |
| ⑧ | `configs/riscv64-xs-kmhv2-ref_defconfig:34` | +1 | `CONFIG_CUSTOM_XVDOT=y` | **difftest 参考库形态**；若 ref 不实现 vdot，P6 协同仿真毫无意义 | — |

**无需改动的地方**（已逐一核实）：

* `Makefile` —— `SRCS-y += $(shell find $(DIRS-y) -name "*.c")`（`Makefile:76`）自动发现 `vdot.c`；
* `src/isa/riscv64/instr/decode.c` —— OP-V 顶层入口 `:100` 已存在；
* `src/isa/riscv64/instr/rvv/vreg.h:24` —— `#define VLEN 128` 恰为赛题要求，无需改；
* `src/isa/riscv64/instr/rvv/exec.h` —— 已 `#include "vcompute.h"`，新 EHelper 自动进入编译；
* difftest 导出侧 —— `vr[32]` 在 `CONFIG_RVV` 下本就落在 `DIFFTEST_REG_SIZE` 区间内
  （`src/isa/riscv64/include/isa-def.h` 的 `vr[32]` 与 `difftest_state_end`），
  vdot 写进 `vd` 的结果天然会被 difftest 比对，无需任何额外导出代码。

### 2.1 编码占用核实

MASTER_PLAN D2.2 要求「实现前必须用脚本证明 funct6 未被 RVV 1.0 占用」。
除 `docs/stage2/10_vdot指令设计文档.md` 的论证外，这里再给一条**针对 NEMU 自身
译码表**的机器核对：解析 `vopivv` 表里的全部 `def_INSTR_TAB` 模式串，
打 patch 前 OPIVV 空间 64 个 funct6 中已占用 42 个，`111001/111010/111011`
均为空位（整个 `111xxx` 行在 OPIVV 全空）；打 patch 后占用 45 个。
复现命令见 `scripts/21_build_nemu_vdot.sh` 的说明与下式：

```bash
python3 - <<'EOF'
import re
src = open('work/NEMU/src/isa/riscv64/instr/rvv/decode.h').read()
body = re.search(r'def_THelper\(vopivv\)\s*\{(.*?)\n\}', src, re.S).group(1)
used = {m.group(1): m.group(2) for m in
        re.finditer(r'def_INSTR_TAB\("(\d{6}) [01?] [^"]*", (\w+)\)', body)}
for f in ('111001', '111010', '111011'):
    print(f, '->', used.get(f, '(空位)'))
EOF
```

---

## 3. vl / vstart / vm / vta / vma 如何从既有框架继承

本次实现的一条硬性原则：**凡是 NEMU 已经有的东西一律复用，不自己重写一遍**。
下表逐项说明每种架构行为落在哪个既有函数上。

| 行为 | 复用的框架设施（上游，未改动） | 在 `vdot.c` 中的位置 | 对应裁定 |
|---|---|---|---|
| 向量单元是否使能 / `vtype.vill` | `require_vector(true)`（`vcompute_impl.c:358`，内部 `require_vector_vs()` 查 `mstatus.vs`，`:266`） | 经 `vector_reduction_check()` / `vector_vvv_check()` 间接调用（`vdot.c:53-70`） | — |
| 掩码寄存器与 `vd` 冲突检查 | `require_vm(s)`（`vcompute_impl.c:332`：`vm==0 && vd==v0` → `EX_II`） | 仅 `vdot4a` 走（经 `vector_vvv_check()`）。归约形态**刻意不查** —— RVV 1.0 §5.3 允许归约的标量结果写 v0，上游 `vredsum` 用的 `vector_reduction_check()`（`:464`）同样不查 | — |
| 寄存器组对齐 | `require_aligned()`（`vcompute_impl.c:342`） | 由 `vector_reduction_check()` / `vector_vvv_check()` 代办 | — |
| **`vstart != 0` → Illegal Instruction** | `check_vstart_exception(s)`（`vcommon.c:20-24`，直接 `longjmp_exception(EX_II)`） | `vdot.c:93`（仅归约形态）；`vdot4a` **不调用** | **S-1 / S-7** |
| **`vstart >= vl`（含 `vl == 0`）→ 连 tail 都不写** | `check_vstart_ignore(s)`（`vcommon.c:8-18`，顺便把 `vstart` 清 0 并置脏） | `vdot.c:94` 与 `:140` | **S-5** |
| `vl` 主循环范围 | 与上游完全一致的 `for (idx = vstart->val; idx < vl->val; idx++)` | `vdot.c:107`、`:145` | — |
| prestart（`i < vstart` 保持不变） | 由主循环起点自然实现（上游同款写法） | `vdot.c:145` | **S-7**（Q3） |
| `vm` / `v0` 掩码取位 | `get_mask(0, idx)`（`vreg_impl.c:63`，按 RVV §4.5 取 v0 的第 idx 比特） | `vdot.c:108`、`:146` | — |
| 归约：inactive **源**元素排除出求和 | 与 `reduction_instr()`（`vcompute_impl.c:1540-1543`）逐字相同的 `continue` | `vdot.c:108-111` | R4 |
| 归约忽略 `vma` | 代码里根本不读 `vtype->vma`（归约没有 inactive 的**目的**元素） | `vdot.c:107-112` | **S-2** |
| 逐元素：inactive 目的元素按 `vma` | 与 `arithmetic_instr()`（`vcompute_impl.c:560-575`）同构：`vma=1` 写全 1，`vma=0` 保持 | `vdot.c:146-152` | Q5 |
| 归约 tail（`vta=1`） | `set_vreg_tail(vd)`（`vreg_impl.c:286`，把整个寄存器置全 1）再写元素 0 —— 与 `reduction_instr()` `:1563-1569` 完全一致 | `vdot.c:117-122` | **S-3**、R6 |
| 逐元素 tail（`vta=1`） | `get_vlen_max(vsew, vlmul, 0)`（`vreg_impl.c:106`）求 VLMAX，再逐元素写全 1 —— 与 `arithmetic_instr()` `:992-1000` 一致 | `vdot.c:168-176` | Q6 |
| 元素读写与 EEW 换算 | `get_vreg()` / `set_vreg()`（`vreg_impl.c:135` / `:178`）。源用 `vsew=0`（EEW=8，`SIGNED` 已按 `(int64_t)(int8_t)` 扩展），目的用 `vsew=2`（EEW=32，写回时自动截断 → 2^32 模回绕） | `vdot.c:73-77`、`:121`、`:177` | 溢出回绕 |
| 结束时 `vstart = 0` | 归约形态 `vstart->val = 0`（同 `reduction_instr():1571`）；逐元素形态 `rtl_li + vcsr_write(IDXVSTART, 0)`（同 `arithmetic_instr():1007-1008`） | `vdot.c:124`、`:178-179` | R9 |
| `mstatus.VS` 置脏 | `vp_set_dirty()` | `vdot.c:95/118/123/141/180` | difftest CSR 比对必需 |
| `vxsat` / `vcsr` | **不调用** `update_vcsr()` —— 本指令族不饱和（溢出证明见 D2），不应改 `vxsat` | — | 溢出分析 |

### 3.1 实现骨架（`vdot.c`）

```
vdot_instr(opcode, s)                     vdot.c:183
  ├─ vdot_check(s, opcode)                vdot.c:53
  │    ├─ 归约形态 : vector_reduction_check(s, 0)   ← vcompute_impl.c:464
  │    │             + vtype.vsew != 0  -> EX_II    （R1：要求 SEW=8）
  │    ├─ 逐元素形态: vector_vvv_check(s, true)     ← vcompute_impl.c:407
  │    │             + vtype.vsew != 2  -> EX_II    （Q1：要求 SEW=32）
  │    └─ vtype.vlmul != 0 -> EX_II                 （S-6：本版本固定 LMUL=1）
  ├─ VDOT / VDOTACC -> vdot_reduce(s, accumulate)   vdot.c:92
  └─ VDOT4A         -> vdot4a_exec(s)               vdot.c:139
```

`vdot_reduce()` 与上游 `reduction_instr()` 的**唯一结构性差异**是：上游用
`vs1[0]`（EEW = vsew+wide）作为归约初值，而 `vdot` 的初值恒为 0、`vdotacc` 的初值
取自 `vd.u32[0]`；源元素固定按 EEW=8 读、目的固定按 EEW=32 写。其余（检查顺序、
掩码处理、tail 处理、收尾）逐行同构。

---

## 4. 验证方法论

### 4.1 为什么不是「把参考模型抄进 NEMU」

`docs/stage2/13` §9 曾建议 NEMU 直接 `#include` 参考模型的核心函数。
本阶段**没有**这么做，理由有二：

1. 参考模型 `vdot_ref.c` 自带一整套 vl/vstart/vta/vma 逻辑，直接内联会绕开 NEMU
   的 `check_vstart_*` / `get_mask` / `set_vreg_tail` 框架，等于在 NEMU 里再造一遍轮子，
   与「复用既有框架」的要求冲突，也会掩盖 NEMU 框架本身的行为差异；
2. 更重要的是，**等价性应当被证明而不是被假设**。本阶段按 NEMU 自身惯用法独立实现，
   再用参考模型生成的 30710 条语料做逐位差分，这比「同一份代码自己跟自己比」
   提供的信息量高得多。

这一取舍是一处与 `docs/stage2/13` §9 第 4 条建议的**有意偏离**，在此显式记录。
对 P6 的影响见 §7。

### 4.2 测试程序结构（`tests/riscv/vdot/`）

| 文件 | 行数 | 作用 |
|---|---:|---|
| `pack_corpus.py` | 167 | 把文本 suite 打包成二进制 blob（**只做格式转换，不计算任何期望值**） |
| `gen_extra_vectors.py` | 125 | 生成补充定向语料（覆盖裁定 S-9）；期望值由 `tests/golden/vdot_cli` 现算 |
| `extra_vectors/vstart_range.txt` | 47 条 | 上一行的产物，随仓库提交 |
| `corpus.S` | 15 | 用 `.incbin` 把 2 702 952 字节的 blob 嵌进镜像的 `.rodata` |
| `start.S` | 90 | 裸机启动 + **M 态 trap handler**（记录 `mcause`/`mepc`，`mepc += 4` 后 `mret`） |
| `vdot_test.c` | 353 | 逐条执行 + 比对 + 分 suite 统计 + UART 输出 |
| `vdot.ld.in` | 49 | 链接脚本模板，`@MBASE@` 由 Makefile 从 NEMU 实际配置替换 |
| `Makefile` | 139 | 构建 + `check-config` 守卫 + `run` / `run-ref` / `extra-vectors` |
| `fault_inject.sh` | 173 | 故障注入自测（§5） |

**为什么把 30710 条用例嵌进镜像**：NEMU 上跑的是裸机程序，没有文件系统也没有 libc。
若以 C 数组形式嵌入，编译器要处理约 270 万个初始化项，编译极慢；打成二进制再
`.incbin`，汇编器一次 `read` 即可，编译时间可忽略，镜像 2 709 128 字节。

**单条用例的执行序列**（`vdot_test.c:run_case()`）：

1. `vsetivli x0,16,e8,m1,ta,ma` + 4 条 `vle8.v` —— 把 `v0`(掩码)/`v1`(vs1)/`v2`(vs2)/`v3`(vd_in) 整体灌进去；
2. `vsetvl x0, a4, a5` —— `a4 = vl`，`a5 = (vma<<7)|(vta<<6)|(vsew<<3)|0`。用寄存器形式而不是
   16 份立即数变体，`rd=x0 && rs1!=x0` 对应 NEMU `get_mode()`（`vcommon.c:95`）的 mode 0；
   随后 `csrr vl` 回读并与语料比对（统计项 `vl-readback-mismatch`，实测 0）；
3. `csrw vstart, a6` —— 必须在 `vsetvl` **之后**，因为 `set_vtype_vl()` 末尾会把 `vstart` 清零；
4. 发射被测指令（6 条静态编码之一，`.4byte`）；
5. `csrw vstart, zero` + `vsetivli` + `vse8.v v3` —— 回读 vd。先清 `vstart` 是因为
   指令若因 `vstart!=0` 抛异常，按 §3.7 `vstart` 不被修改，不清会让 `vse8.v` 从元素 `vstart` 开始存；
6. 判定：
   * 语料 `status == OK` → **不得** trap，且 `vd` 必须逐字节等于 `vd_expected`；
   * 语料 `status != OK` → **必须** trap、`mcause` 必须为 2（Illegal Instruction）、
     且 `vd` 必须保持不变（语料保证此时 `vd_expected == vd_in`）。

被测指令的机器码由位域宏 `VENC(funct6, vm)` 现场拼出，并用 `_Static_assert` 锚定到
6 个具体值，程序启动时也会把它们打印出来（日志 `p5_vdot_tests.log:62-65`），
镜像反汇编里能逐条找到（`p5_vdot_tests.log:71-76`）。

**一个真实踩的坑：裸机镜像必须 `-no-pie`。** Ubuntu 的 gcc 默认 `-pie`，
`-fno-pic` 只影响代码生成、不影响链接，产出的 ELF 仍带 `.rela.dyn` 动态重定位。
纯 PC 相对的代码不受影响，但编译器为 `switch` 生成的指针表（`CSWTCH.*`）里存的是
**绝对地址**，要靠装载器施加 `R_RISCV_RELATIVE` 才正确；NEMU 把 `objcopy -O binary`
出来的扁平镜像原样读进 pmem，不做任何重定位，于是那张表全是垃圾 ——
现象是失败用例打印 `status=` 之后 `put_str()` 拿到野指针、无限输出同一个字符。
**这个 bug 是故障注入（§5 的 inject #1）逼出来的**：干净实现下 30710 条全 PASS，
失败打印路径根本不会被执行，这条死路可以一直藏着。修复是给 `LDFLAGS` 加 `-no-pie`
（`tests/riscv/vdot/Makefile`），链接后 `readelf -d` 显示 "There is no dynamic
section in this file"。这正是"不能失败的测试毫无价值"的一个具体例证。

### 4.3 语料范围、`vstart_relaxed` 与补充定向语料

| suite | 条数 | 其中「必须 trap」 |
|---|---:|---:|
| positive / negative / boundary（vdot） | 40 / 44 / 103 | 0 / 0 / 9 |
| vdotacc_positive / _negative / _boundary | 40 / 44 / 103 | 0 / 0 / 9 |
| vdot4a_positive / _negative / _boundary | 40 / 44 / 115 | 0 / 0 / 3 |
| vstart_relaxed(strict) | 90 | 77 |
| random / vdotacc_random / vdot4a_random | 10000 / 10000 / 10000 | 1541 / 1572 / 0 |
| 小计（`tests/vectors/` 共享语料，13 个 suite） | 30663 | 3211 |
| vstart_range(extra)（P5 补充，`tests/riscv/vdot/extra_vectors/`） | 47 | 39 |
| **合计** | **30710** | **3250** |

`tests/vectors/vstart_relaxed.txt` 是裁定 S-1 的**备用策略**语料，文件头写着
`# policy: skip`，按非规范的 `VDOT_VSTART_SKIP` 策略生成。本项目绑定的是 STRICT 策略，
因此 `pack_corpus.py` 对其中 `vstart != 0` 的 77 条按 STRICT 重标注为
`ILLEGAL_VSTART` 且 `vd_expected = vd_in`（这正是参考模型 STRICT 分支的行为，
`vdot_ref.c` 的「规则 2」），suite 名加后缀 `(strict)` 以示区分；
`vstart == 0` 的 13 条两种策略结果相同，原样保留。这是打包脚本中**唯一**一处改写语料的地方，
其余 30620 条的 `vd_expected` / `status` 全部原样来自文本语料。

**补充定向语料 `extra_vectors/vstart_range.txt`（47 条）**：共享语料里只出现
`OK` / `ILLEGAL_VSTART` / `ERR_SEW` 三种状态，**没有任何 `ERR_VSTART_RANGE` 用例**，
也就是裁定 S-9 在共享语料中完全未覆盖。对 `vdot` / `vdotacc` 这不要紧（S-1 已把任何
`vstart != 0` 判为非法），但 `vdot4a` 的 VLMAX = 4、`vstart` 正常生效，
`vstart ∈ [4,15]` 是一组架构上可达、规范上 reserved、且"什么都不做"与"抛非法指令"
可区分的配置。本阶段因此用 `gen_extra_vectors.py` 补了一个定向 suite：
脚本只构造输入，再把整批请求通过管道交给 `tests/golden/vdot_cli`（即参考模型本体）
算出 `vd_expected` 与 `status`，做法与 `tests/vectors/gen_vectors.py` 完全一致，
**不引入第二份语义实现**。47 条中 39 条期望 `ERR_VSTART_RANGE`，
8 条是紧邻的合法边界（`vstart = 3`），用于确认没有把合法配置误判为非法。
重新生成：`make -C tests/riscv/vdot extra-vectors`。

### 4.4 实测结果（真实日志）

**独立解释器** `build/riscv64-nemu-interpreter`（`logs/stage3/p5_vdot_tests.log:78-93`）：

```
suite                      cases    pass    fail   must-trap
---------------------------------------------------------------------
positive                       40      40       0           0
negative                       44      44       0           0
boundary                      103     103       0           9
vdotacc_positive               40      40       0           0
vdotacc_negative               44      44       0           0
vdotacc_boundary              103     103       0           9
vdot4a_positive                40      40       0           0
vdot4a_negative                44      44       0           0
vdot4a_boundary               115     115       0           3
vstart_relaxed(strict)         90      90       0          77
random                      10000   10000       0        1541
vdotacc_random              10000   10000       0        1572
vdot4a_random               10000   10000       0           0
---------------------------------------------------------------------
TOTAL cases=30663 pass=30663 fail=0
  must-trap cases (status != OK) = 3211 , trapped with mcause=2 = 3211
  missing-trap=0  unexpected-trap=0  wrong-mcause=0  value-mismatch=0  vl-readback-mismatch=0
RESULT: PASS
```

NEMU 侧佐证（`p5_vdot_tests.log:97-101`）：
`HIT GOOD TRAP at pc = 0x0000000080000042`、
`total guest instructions = 5495017`、`vst count = 30663`
（30663 次向量 store = 逐条回读了 30663 次 `vd`，不存在"循环没跑"的可能）。

**difftest 参考共享库** `build/riscv64-nemu-interpreter-so`
（`p5_vdot_tests.log:110-124`）：ref 配置关掉了全部串口设备
（`configs/riscv64-xs-kmhv2-ref_defconfig:190` `# CONFIG_HAS_UARTLITE is not set`），
因此改用静默变体 `vdot_test_quiet.bin`（计算与比对逻辑完全相同，只是不输出，
结果以 `main` 的返回值 = 失败条数经 `nemu_trap` 作为 `halt_ret` 报告），
用 NEMU 自带的 `tools/ref-so-runner`（`dlopen` + `difftest_memcpy` + `difftest_exec`）驱动：

```
nemu: HIT GOOD TRAP at pc = 0x0000000080000042
trap code:0
total guest instructions = 5494795
vst count = 30663, vst unit count = 30663, vst unit optimized count = 0
runner 退出码 = 0
```

`trap code:0` ⇔ `main` 返回 0 ⇔ 30663 条用例 0 失配。**这是 `.so` 侧也正确实现了
vdot 的功能性证据**，不是「符号存在」之类的间接推断。

**覆盖情况对照赛题 2.3.x / P5 验收标准 3**：全部定向 suite（正数 120 / 负数 132 /
边界 321 条）+ 30000 条随机（远超「≥10000 随机」要求），0 失配。

### 4.5 patch 在干净副本上的验证

`./scripts/21_build_nemu_vdot.sh verify-patch`（日志 `logs/stage3/p5_patch_verify.log`）：
`git clone --shared --no-checkout` 出一份全新副本 → `git checkout 9090839`
（`git status --short` 为空）→ `git apply --check --verbose` 全部 8 个文件通过 →
`git apply` → 重新 `make riscv64-xs-kmhv2_defconfig && make -j` → 用这份干净副本编出的
解释器重跑全部语料：

```
TOTAL cases=30663 pass=30663 fail=0
RESULT: PASS
PATCH-VERIFY: OK
```

---

## 5. 故障注入证据

「30663 条全 PASS」本身不能证明测试有效 —— 也可能是比对逻辑形同虚设。
`tests/riscv/vdot/fault_inject.sh` 把 `work/NEMU/src/isa/riscv64/instr/rvv/vdot.c`
人为改坏 4 次，每次重新编译 NEMU 并重跑完整语料，要求**每次都必须 FAIL**。
完整日志：`logs/stage3/p5_fault_injection.log`。

| # | 注入内容 | 实测结果 | 日志行 |
|---|---|---|---|
| 1 | 丢掉源操作数的符号扩展（`SIGNED` → `UNSIGNED`，并删掉 `rtl_sext`） | `pass=9070 fail=21593`，`value-mismatch=21593` → **被检出** | `:10-30` |
| 2 | 归约主循环 `vl` 差一（`idx < vl` → `idx + 1 < vl`） | `pass=18584 fail=12079` → **被检出** | `:33-52` |
| 3 | 忽略掩码（`vm=0` 时不再排除 inactive 元素，`vdot4a` 也不再做 `vma` 处理） | `pass=20310 fail=10353` → **被检出** | `:55-86` |
| 4 | **破坏裁定 S-1**：删掉归约形态的 `check_vstart_exception(s)` | `pass=27461 fail=3202`，其中 `missing-trap=3202`、`must-trap 3211 条只 trap 了 9 条`（剩下 9 条是 `ERR_SEW` 类，与 vstart 无关） → **被检出** | `:89-108` |
| — | 还原源码并重新编译后复测 | `TOTAL pass=30663 fail=0  RESULT: PASS` | `:114-117` |

```
FAULT-INJECTION: 4/4 被检出
还原后复测: PASS
FAULT-INJECTION: PASS
```

注入 #4 专门针对 S-1，是 P5/赛题 2.3.3「`vstart≠0` 触发非法指令」这一项的直接证据：
若 NEMU 静默计算而不抛异常，测试立刻报出 3202 条 `missing-trap`。

脚本的注入方式是 Python 精确字符串替换并 `assert` 命中次数为 1，
源码一旦变动、注入点失配，脚本会报「注入失败」并整体 FAIL，**不允许"假装注入成功"**。

---

## 6. 复现命令

```bash
# 前置：xsdev 容器镜像已构建，work/NEMU 处于 commit 9090839
./scripts/21_build_nemu_vdot.sh                 # 打 patch + 构建两形态 + 跑两轮语料
./scripts/21_build_nemu_vdot.sh fault           # 故障注入自测
./scripts/21_build_nemu_vdot.sh verify-patch    # 干净副本上验证 patch
```

脚本 `set -euo pipefail` 且幂等：patch 已应用时用 `git apply --check --reverse`
判定并跳过。日志用 `tee` 落到 `logs/stage3/`：
`p5_nemu_build.log`(359 行) / `p5_vdot_tests.log`(128 行) /
`p5_fault_injection.log`(123 行) / `p5_patch_verify.log`(51 行)。

> 注：归档的 `p5_nemu_build.log:8` 显示「patch 已处于已应用状态…跳过」，
> 这是因为归档那次运行时工作区已经打过 patch（脚本幂等性生效）。
> 从零开始的首次运行会显示「patch 应用成功」；
> 从干净副本应用 patch 的完整过程另见 `p5_patch_verify.log:1-30`。

---

## 7. 给 P6（NEMU↔RTL 协同仿真）的交接要点

1. **ref 库已带 vdot**：`riscv64-xs-kmhv2-ref_defconfig:34` 已置 `CONFIG_CUSTOM_XVDOT=y`，
   `build/obj-riscv64-nemu-interpreter-so/src/isa/riscv64/instr/rvv/vdot.o` 确实被编译并链接
   （`p5_nemu_build.log:142,242`），且已用 `tools/ref-so-runner` 功能性验证过
   （`p5_vdot_tests.log:110-124`）。协同仿真直接 `--diff .../riscv64-nemu-interpreter-so` 即可。
2. **向量寄存器自动参与比对**：`vr[32]` 落在 `DIFFTEST_REG_SIZE` 区间内，
   `CONFIG_DIFFTEST_CHECK_VCSR=y`（ref defconfig）使 `vstart/vl/vtype/vxsat/...` 也参与比对。
   本实现每条路径都调了 `vp_set_dirty()`，并在结束时把 `vstart` 清零，
   不会在 CSR 比对上制造假失配。
3. **REF 侧「非重写」的证据链**：本实现与 `tests/golden/vdot_ref.c` 是两份独立代码，
   已在 30663 条语料上逐位一致（§4.4）。因此 RTL 测试平台继续使用 `vdot_ref.c` 作为
   C++ golden model 是成立的 —— 它与 NEMU 实际执行的语义等价，且等价性有实测支撑。
   若 P6 的验收口径要求「REF 侧字面上就是 NEMU 的代码」，最直接的做法是走
   **真 difftest 通路**（`.so` + `--diff`），那样 REF 侧就是 NEMU 本体，无需任何转述。
4. **RTL 必须与之对齐的两条额外约束**（语料未覆盖，属本实现的显式选择）：
   * `vtype.vlmul != 0`（LMUL ≠ 1）→ Illegal Instruction；
   * `vtype.vsew` 不匹配（vdot/vdotacc 要求 8，vdot4a 要求 32）→ Illegal Instruction。
     若 RTL 对这两种情况的处理不同，difftest 会在这两类激励上报失配。
5. **不要给 vdot 打 difftest skip**：`work/difftest/src/test/csrc/difftest/refproxy.h:313-317`
   有 `if (vecwen) assert(0)`，向量指令本就不支持 skip。vdot 不访存，无需 skip。

---

## 8. 局限性（如实标注）

1. **LMUL 只支持 1**。裁定 S-6 固定 `LMUL = 1`（VLEN=128、SEW=8 时恰为单 uop，
   正是赛题场景）。本实现把 `vlmul != 0` 直接判为 Illegal Instruction，而不是
   "尽力而为地算个结果"——这样任何越界使用都会立刻暴露，不会静默产生错误数据。
   LMUL>1 对 `vdot4a` 是平凡的逐元素扩展，对 `vdot/vdotacc` 是跨寄存器组归约，
   均属自然扩展点，但**本版本未实现、未测试**。
2. **语料未覆盖 `ERR_VL` 与 `ERR_VSTART_RANGE`**。`tests/vectors/` 里只出现
   `OK` / `ILLEGAL_VSTART` / `ERR_SEW` 三种状态（实测统计）。
   * `ERR_VL`（`vl > VLMAX`）架构上不可达 —— `vsetvl` 会把 `vl` 钳到 VLMAX（`vreg_impl.c:34-61`）；
   * `ERR_VSTART_RANGE`（裁定 S-9，`vstart > VLMAX-1`）对 `vdot/vdotacc` 被 S-1 完全覆盖
     （任何 `vstart != 0` 都已经非法）；对 `vdot4a`（VLMAX=4，`vstart ∈ {4..15}`）
     参考模型会返回 `ERR_VSTART_RANGE`，而**本 NEMU 实现不抛异常，而是走
     `check_vstart_ignore()` 的"`vstart >= vl` 则不写回"路径**。
     由于语料里没有这类用例，这处差异**未被测试覆盖**，在此显式记录：
     这是一个与参考模型的已知行为差异，影响范围是 `vdot4a` 且 `vstart ∈ [4,15]`
     这一组架构上「reserved」的配置。如需对齐，应在 `vdot_check()` 里补一条
     `vstart > VLMAX-1 → EX_II`，并请参考模型侧生成对应语料后重测。
3. **本层只验证指令语义，不验证微架构**。NEMU 不建模流水线、发射队列与 cache 时序，
   L2 层能回答"算得对不对"，回答不了"几个周期、怎么拆 uop" —— 后者由 L1（YunSuan FU
   Verilator 仿真）与 P7 负责。
4. **汇编器不认识这三条助记符**。测试程序用 `.word` 发射（编码由位域宏现场拼出 +
   `_Static_assert` 锚定）。为 binutils 增加助记符不在本阶段范围内。
5. **未做 difftest 全核协同仿真**。本文只证明 `.so` 本身能正确执行 vdot；
   DUT↔REF 的逐周期比对属 P6，全核香山 Verilator 仿真在本机不可行的论证见
   `docs/stage1/01_环境部署报告.md` §6.2。
6. **`vdot_test.c` 里有一处对 NEMU 行为的隐式依赖**：trap handler 固定 `mepc += 4`。
   这对本测试成立（被测指令都是 4 字节 `.word`），但不是通用的异常处理实现。
7. **宿主平台单一**：全部实测均在 macOS 15.5 / Apple Silicon 上的
   `linux/arm64` Docker 容器（Ubuntu 24.04 + GCC 13.3）内完成，**未在 x86_64 Linux 上验证**。
   NEMU 本身无架构相关代码路径（见 `docs/stage1/01_环境部署报告.md` §2.2 与
   `docs/_recon/nemu-difftest-env.md` §A.8），但这是推断而非实测。
