# NEMU / Difftest / 环境部署 侦察报告（Part A–D）

> 侦察日期：2026-10-24。本文所有结论均基于本地 clone 的源码逐文件核对，给出 `路径:行号`。
> 无法从本地源码证实的内容一律标注 **UNVERIFIED**。
>
> 本地仓库版本（`git log -1`）：
>
> | 仓库 | 分支 | HEAD |
> |---|---|---|
> | `work/NEMU` | `master` | `9090839` feat(difftest): support fast shared reference execution (#1247) |
> | `work/difftest` | `master` | `8e9c8d7` feat(difftest): support fast-ref and fork checking (#980) |
> | `work/xs-env` | `master` | `81346b8` |
> | `work/XiangShan` | **`kunminghu-v3`** | `f85a1f7` |
> | `work/XiangShanLab` | `master` | `7f0eebf`（侦察过程中该目录被删除/重新克隆中） |
>
> ⚠️ **第一个重大发现**：本地 `work/XiangShan` 检出的是 **`kunminghu-v3`** 分支，而赛题要求的是 **昆明湖 V2**。
> `work/XiangShan/README.md:67-70` 明确列出 `kunminghu-v2` / `kunminghu-v3` 两个分支，并建议
> "If you plan to use XiangShan for research, verification, or downstream applications, we recommend prioritizing `kunminghu-v2`"。
> 两个分支的向量后端差异极大（见 §D.6），**必须先切到 `kunminghu-v2`**。

---

## Part A. NEMU 侦察

### A.1 RVV 实现的目录布局

RVV 全部实现在 `work/NEMU/src/isa/riscv64/instr/rvv/`：

| 文件 | 行数 | 作用 |
|---|---|---|
| `decode.h` | 545 | **译码表**：`OP_V` 的 DHelper + 各 funct3 子表（`vopivv`/`vopivx`/`vopivi`/`vopmvv`/`vopmvx`/`vopfvv`/`vopfvf`）+ 各 unary dispatch 子表 |
| `exec.h` | 18 | 只做三个 include：`vcfg.h` / `vcompute.h` / `vldst.h` |
| `vcfg.h` | 58 | `vsetvl` / `vsetvli` / `vsetivli` 的 EHelper |
| `vcompute.h` | 1355 | **每条算术指令一个 `def_EHelper`**，内部调用 `ARITH(...)` / `REDUCTION(...)` 等宏 |
| `vcompute_impl.h` | 135 | `enum op_t`（内部微操作码）、`ARITH*`/`REDUCTION`/`FLOAT_ARITH` 宏、各种 `vector_*_check()` 声明 |
| `vcompute_impl.c` | 1857 | **真正的执行引擎**：`arithmetic_instr` / `reduction_instr` / `permutaion_instr` / `mask_instr` / `floating_arithmetic_instr` |
| `vldst.h` / `vldst_impl.h` / `vldst_impl.c` | 170/53/1185 | 向量访存（vle/vse/vlse/vlxe/vlr/…）。**vdot 不涉及** |
| `vreg.h` / `vreg_impl.c` | 118/291 | 向量寄存器文件访问：`get_vreg` / `set_vreg` / `get_mask` / `set_mask` / `get_vlmax` |
| `vcommon.h` / `vcommon.c` | 23/148 | `check_vstart_ignore` / `check_vstart_exception` / `set_vtype_vl` 等 |
| `vfexp2.h` / `vfexp2.c` | 17/651 | **自定义非标准指令 `vfexp2.v` 的实现（最佳模板，见 §A.4）** |

关键常量：**`VLEN` 在 `work/NEMU/src/isa/riscv64/instr/rvv/vreg.h:23` 硬编码为 `128`**，与赛题 VLEN=128 一致，无需改动。

```c
// work/NEMU/src/isa/riscv64/instr/rvv/vreg.h:23-30
#define VLEN 128
#define VLENLG 8
#define MAXELEN 64
#define VENUM64 (VLEN/64)
...
#define VENUM8  (VLEN/8)
```

### A.2 译码机制：`def_INSTR_TAB` 模式匹配 DSL

NEMU 没有用 `INSTPAT`（那是 ysyx PA 版 NEMU 的宏）；XiangShan 版 NEMU 用的是 **`def_INSTR_TAB` / `def_INSTR_IDTAB`**，定义在 `work/NEMU/include/cpu/decode.h:192-203`：

```c
// work/NEMU/include/cpu/decode.h:192-203
#define def_INSTR_raw(pattern, body) do { \
  uint64_t key, mask, shift; \
  pattern_decode(pattern, STRLEN(pattern), &key, &mask, &shift); \
  if ((((uint64_t)get_instr(s) >> shift) & mask) == key) { body; } \
} while (0)

#define def_INSTR_IDTABW(pattern, id, tab, width) \
  def_INSTR_raw(pattern, { concat(decode_, id)(s, width); return concat(table_, tab)(s); })

#define def_INSTR_IDTAB(pattern, id, tab)   def_INSTR_IDTABW(pattern, id, tab, 0)
#define def_INSTR_TABW(pattern, tab, width) def_INSTR_IDTABW(pattern, empty, tab, width)
#define def_INSTR_TAB(pattern, tab)         def_INSTR_IDTABW(pattern, empty, tab, 0)
```

`pattern_decode()`（`include/cpu/decode.h:161-189`）在编译期（`always_inline` + `__COUNTER__` 展开）把 `"101101 ? ????? ????? ??? ????? ????? ??"` 这种字符串变成 `(key, mask, shift)` 三元组，运行时只是一次 `((instr >> shift) & mask) == key` 比较。模式串里：`0`/`1` 是必须匹配位，`?` 是 don't care，空格忽略。**模式串是从高位到低位写的，长度不必是 32**（尾部的 `?` 会被折算成 `shift`）。

译码链路（自顶向下）：

1. `work/NEMU/src/isa/riscv64/instr/decode.c:100`
   ```c
   def_INSTR_IDTAB("??????? ????? ????? ??? ????? 10101 ??", OP_V  , OP_V);
   ```
   即 opcode = `1010111` (OP-V, 0x57) → 调 `decode_OP_V()` 再进 `table_OP_V()`。

2. `work/NEMU/src/isa/riscv64/instr/rvv/decode.h:24-46` `def_DHelper(OP_V)`：解出 `vs1/vs2/vd`，按 funct3 设置 `s->src_vmode`（`SRC_VV=0`/`SRC_VI`/`SRC_VX`/`SRC_VF`），并设 `s->v_width = 1 << vtype->vsew`、`s->vm = instr.v_opv.v_vm`。

3. `work/NEMU/src/isa/riscv64/instr/rvv/decode.h:533-545` `def_THelper(OP_V)` 按 funct3 分发到 `vopivv` / `vopfvv` / `vopmvv` / `vopivi` / `vopivx` / `vopfvf` / `vopmvx` / `vsetvl_dispatch`。

4. 各子表按 **funct6**（instr[31:26]）做 `def_INSTR_TAB`。

   - **OPIVV 表**：`decode.h:163-215`（funct3=0b000）
   - **OPMVV 表**：`decode.h:314-373`（funct3=0b010）
   - **OPMVX 表**：`decode.h:375-418`（funct3=0b110）

   例：
   ```c
   // decode.h:318  OPMVV
   def_INSTR_TAB("000000 ? ????? ????? ??? ????? ????? ??", vredsum);
   // decode.h:354
   def_INSTR_TAB("101101 ? ????? ????? ??? ????? ????? ??", vmacc);
   // decode.h:369
   def_INSTR_TAB("111101 ? ????? ????? ??? ????? ????? ??", vwmacc);
   ```
   第 1 段 6 位 = funct6，第 2 段 1 位 = vm，然后 vs2/vs1/funct3/vd/opcode[6:2]/opcode[1:0]。

5. `table_<name>(s)` 由 `def_all_THelper()` 自动生成（`include/cpu/decode.h:118-141`），它打印反汇编并返回 `EXEC_ID_<name>`；`EXEC_ID_<name>` 由 `def_all_EXEC_ID()` 从 `INSTR_LIST` 宏自动编号（`include/cpu/decode.h:108-112`）。所以**任何新指令必须先在 `isa-all-instr.h` 的指令名单里注册**，否则 `table_xxx` / `EXEC_ID_xxx` 都不存在，编译报错。

### A.3 `vmacc` / `vwmacc` / `vredsum` 怎么实现的

**EHelper 层**（`vcompute.h`）只是把"微操作码 + 符号性 + widening"交给通用引擎：

```c
// work/NEMU/src/isa/riscv64/instr/rvv/vcompute.h:260
def_EHelper(vredsum)  { REDUCTION(REDSUM, SIGNED) }
// vcompute.h:868
def_EHelper(vmacc)    { ARITH(MACC, SIGNED) }
// vcompute.h:924
def_EHelper(vwmacc)   { ARITH_WIDE(MACC, SIGNED) }
// vcompute.h:928
def_EHelper(vwmaccsu) { ARITH_WIDE(MACCSU, UNSIGNED) }
```

宏展开（`vcompute_impl.h:93-97`）：

```c
#define ARITH(opcode, is_signed)       arithmetic_instr(opcode, is_signed, 0, 0, 0, s);
#define ARITH_WIDE(opcode, is_signed)  arithmetic_instr(opcode, is_signed, 1, 0, 0, s);
#define REDUCTION(opcode, is_signed)   reduction_instr(opcode, is_signed, 0, s);
#define WREDUCTION(opcode, is_signed)  reduction_instr(opcode, is_signed, 1, s);
```

`op_t` 枚举在 `vcompute_impl.h:38-70`。**注意：里面已经有 `DOTU, DOT` 两个遗留枚举值（`vcompute_impl.h:45`），是 RVV 0.7.1/0.8 时代 `vdot` 指令的残留，目前无任何 case 使用它们** —— 这意味着加 vdot 时可以直接复用 `DOT`/`DOTU` 这两个名字，但要自己补 `case`。

**执行引擎层**（`vcompute_impl.c`）：

`arithmetic_instr(opcode, is_signed, widening, narrow, dest_mask, s)` — `work/NEMU/src/isa/riscv64/instr/rvv/vcompute_impl.c:488`

流程：

1. `require_vector(true)`（`:489`）
2. 按 widening/narrow/dest_mask 选择合法性检查：`vector_vvv_check` / `vector_wvv_check` / `vector_wwv_check` / `vector_vwv_check` / `vector_mvv_check`（`:516-543`）
3. `check_vstart_exception(s)`；`check_vstart_ignore(s)` 为真则直接 `vp_set_dirty(); return;`（`:544-548`）
4. **主循环 `for (idx = vstart->val; idx < vl->val; idx++)`**（`:549`）—— 这就是 vl/vstart 语义的实现点
5. **掩码**（`:550-591`）：
   ```c
   rtlreg_t mask = get_mask(0, idx);     // v0 的第 idx bit
   if (s->vm == 0) {
     carry = mask;
     if (opcode != MERGE && ... && mask == 0) {
       if (RVV_AGNOSTIC) {
         if (vtype->vma) {                     // mask-agnostic：写全 1
           *s1 = (uint64_t)-1;
           set_vreg(id_dest->reg, idx, *s1, vtype->vsew+widening, vtype->vlmul, 1);
         }
       }
       continue;                                // mask-undisturbed：跳过不写
     }
   }
   ```
6. **EEW/EMUL 计算**（`:592-602`）：`eew = vtype->vsew + narrow; emul = vtype->vlmul;`（`VEXT` 特例 `emul = vtype->vlmul + narrow`）
7. **取 vs2**（`:604-605`）：`get_vreg(id_src2->reg, idx, s0, eew, emul, is_signed, 1)` + 可选 `rtl_sext`
8. **取 vs1 / rs1 / imm**（`:607-669`）：`switch (s->src_vmode)`，`SRC_VV` 分支用 `eew = vtype->vsew; emul = vtype->vlmul;` 再 `get_vreg(id_src->reg, idx, s1, ...)`
9. **大 `switch (opcode)` 计算**（`:~690-981`），其中：
   ```c
   // vcompute_impl.c:762-766   MACC（vmacc / vwmacc 共用）
   case MACC :
     rtl_mulu_lo(s, s1, s0, s1);
     get_vreg(id_dest->reg, idx, s0, vtype->vsew+widening, vtype->vlmul, is_signed, 1);
     rtl_add(s, s1, s1, s0);
     break;
   // vcompute_impl.c:767-772   MACCSU
   case MACCSU :
     rtl_sext(s, s1, s1, 1 << vtype->vsew);
     rtl_mulu_lo(s, s1, s0, s1);
     get_vreg(id_dest->reg, idx, s0, vtype->vsew+widening, vtype->vlmul, is_signed, 1);
     rtl_add(s, s1, s1, s0);
     break;
   ```
   注意 `vwmacc` 的"加宽"完全靠 `get_vreg/set_vreg` 的 `vsew+widening` 参数实现，乘法本身仍是 64 位 `rtl_mulu_lo`。
10. **写回**（`:984-988`）：
    ```c
    update_vcsr();
    if (dest_mask == 1) set_mask(id_dest->reg, idx, *s1, vtype->vsew, vtype->vlmul);
    else                set_vreg(id_dest->reg, idx, *s1, vtype->vsew+widening, vtype->vlmul, 1);
    ```
11. **tail-agnostic 处理**（`:990-1005`）：`if (RVV_AGNOSTIC && vtype->vta) { for (idx = vl; idx < vlmax; idx++) set_vreg(..., -1, ...); }`
12. **收尾**（`:1007-1009`）：`vstart = 0; vp_set_dirty();`

`reduction_instr(opcode, is_signed, wide, s)` — `vcompute_impl.c:1529`

```c
vector_reduction_check(s, wide);
get_vreg(id_src->reg, 0, s1, vtype->vsew+wide, vtype->vlmul, is_signed, 0);  // vs1[0] 作为累加初值
for (idx = vstart; idx < vl; idx++) {
  if (s->vm == 0 && get_mask(0, idx) == 0) continue;     // 归约：mask off 直接跳过
  get_vreg(id_src2->reg, idx, s0, vtype->vsew, vtype->vlmul, is_signed, 0);
  switch (opcode) { case REDSUM : rtl_add(s, s1, s0, s1); break; ... }
}
if (RVV_AGNOSTIC && vtype->vta && vl != 0) set_vreg_tail(id_dest->reg);
if (vl != 0) set_vreg(id_dest->reg, 0, *s1, vtype->vsew+wide, vtype->vlmul, 0);   // 只写 vd[0]
vp_set_dirty(); vstart->val = 0;
```

### A.4 自定义指令的现成模板：`CONFIG_CUSTOM_XVEXP2` / `vfexp2.v`

NEMU 里**已经有一条非标准自定义向量指令** `vfexp2.v`，加 vdot 完全可以照抄它的 5 处改动：

| # | 文件:行 | 改动 |
|---|---|---|
| 1 | `src/isa/riscv64/Kconfig:133-139` | 新增 `config CUSTOM_XVEXP2` / `depends on RVV` / `default n` |
| 2 | `src/isa/riscv64/include/isa-all-instr.h:140-144` | `#ifdef CONFIG_CUSTOM_XVEXP2` → `#define XVEXP2_INSTR_TERNARY(f) f(vfexp2_v)`；并在 `INSTR_TERNARY(f)` 列表末尾追加 `XVEXP2_INSTR_TERNARY(f)` |
| 3 | `src/isa/riscv64/instr/rvv/decode.h:147-156` | 在 `vfunary1_dispatch` 表里 `#ifdef CONFIG_CUSTOM_XVEXP2` 包住 `def_INSTR_TAB(..., vfexp2_v)` |
| 4 | `src/isa/riscv64/instr/rvv/vcompute.h:1156-1160` | `#ifdef CONFIG_CUSTOM_XVEXP2 def_EHelper(vfexp2_v) { FLOAT_ARITH(FEXP2, UNSIGNED) } #endif` |
| 5 | `src/isa/riscv64/instr/rvv/vcompute_impl.h` + `vfexp2.c/.h` | 新增 `FEXP2` 枚举值 + `case FEXP2:` + 独立算法文件 |
| 6 | `configs/riscv64-xs-ref_defconfig:33-34` | `CONFIG_CUSTOM_XVEXP2=y` |

`configs/riscv64-xs-kmhv2-ref_defconfig:33` 当前是 `# CONFIG_CUSTOM_XVEXP2 is not set`。

### A.5 增加一条 OPIVV/OPMVV 指令的**精确改动清单**

（以 `vdot.vv` 为例；文件路径相对 `work/NEMU/`）

| 步骤 | 文件 | 位置 | 内容 |
|---|---|---|---|
| **A5-1 Kconfig** | `src/isa/riscv64/Kconfig` | 在 `:139` 之后插入 | 新增 `config CUSTOM_XVDOT` / `bool "RISC-V custom vdot"` / `depends on RVV` / `default n` |
| **A5-2 指令注册** | `src/isa/riscv64/include/isa-all-instr.h` | `:140` 附近新增块；`:~436` 的 `#define INSTR_TERNARY(f)` 列表末尾追加 | `#ifdef CONFIG_CUSTOM_XVDOT` <br>`#define XVDOT_INSTR_TERNARY(f) f(vdot_vv)` <br>`#else`…`#endif`；并在 `INSTR_TERNARY(f)` 里加 `XVDOT_INSTR_TERNARY(f)` |
| **A5-3 译码模式** | `src/isa/riscv64/instr/rvv/decode.h` | OPIVV 表 `:163-215` **或** OPMVV 表 `:314-373` 内 | `def_INSTR_TAB("<funct6> ? ????? ????? ??? ????? ????? ??", vdot_vv);`（必须用 `#ifdef CONFIG_CUSTOM_XVDOT` 包住） |
| **A5-4 EHelper** | `src/isa/riscv64/instr/rvv/vcompute.h` | 放在 `vmacc`（`:868`）/`vwmacc`（`:924`）附近 | `def_EHelper(vdot_vv) { ARITH(DOT, SIGNED) }` 或自写 `vdot_instr(s)` |
| **A5-5 微操作码** | `src/isa/riscv64/instr/rvv/vcompute_impl.h` | `enum op_t` `:45` 已有 `DOTU, DOT`，可直接复用；若要新语义加 `VDOT` | — |
| **A5-6 执行逻辑** | `src/isa/riscv64/instr/rvv/vcompute_impl.c` | `arithmetic_instr` 的大 `switch` 内，`case MACC:`（`:762`）旁 | 新增 `case DOT:`；**注意：如果 vdot 的 EEW(vd) ≠ EEW(vs1/vs2)（例如 SEW=8 源、32 位目的），`arithmetic_instr` 的统一 EEW 模型无法直接表达，建议另写独立函数 `void vdot_instr(int is_signed, Decode *s)`，放在 `vcompute_impl.c` 末尾，并在 `vcompute_impl.h` 声明** |
| **A5-7 defconfig** | `configs/riscv64-xs-kmhv2-ref_defconfig` | `:33` 附近 | `CONFIG_CUSTOM_XVDOT=y` |
| **A5-8（可选）独立算法文件** | `src/isa/riscv64/instr/rvv/vdot.c` + `vdot.h` | 新建 | Makefile 会自动 `find $(DIRS-y) -name "*.c"`（`Makefile:75`），**无需改 Makefile** |

**不需要改的地方**：
- `vldst.h` / `vldst_impl.c`：vdot 不是访存指令。
- `src/isa/riscv64/instr/decode.c`：OP-V 的顶层入口 `:100` 已存在。
- `src/isa/riscv64/instr/rvv/vreg.h`：`VLEN=128` 已满足。
- `Makefile`：源文件自动发现。

**vl / vstart / vm 的处理必须由新写的执行函数自己负责**（参考 `arithmetic_instr:544-591` 和 `reduction_instr:1532-1545`）：
1. `require_vector(true)` + `vector_vvv_check(s, true)`；
2. `check_vstart_exception(s)` + `check_vstart_ignore(s)`；
3. 主循环 `for (idx = vstart->val; idx < vl->val; idx++)`；
4. `rtlreg_t mask = get_mask(0, idx); if (s->vm == 0 && mask == 0) { if (RVV_AGNOSTIC && vtype->vma) 写全1; continue; }`；
5. tail：`if (RVV_AGNOSTIC && vtype->vta) 把 [vl, vlmax) 写全 1`；
6. 结尾 `vstart->val = 0; vp_set_dirty();`。

> `vp_set_dirty()` 必须调用，否则 `mstatus.VS` 不会置脏，difftest 会在 CSR 比较上报错。

### A.6 可用的 funct6 编码空位（本地表逐行核对得出）

**OPIVV (funct3=0b000)，`decode.h:167-212` 已占用之外的空位**：
`000011, 001000, 001101, 001111, 010110, 011110, 011111, 100100, 100110, 110010, 110011, 110100, 110110, 110111, 111000, 111001, 111010, 111011, 111100, 111101, 111110, 111111`
（整个 `111xxx` 行在 OPIVV 全空。）

**OPMVV (funct3=0b010)，`decode.h:318-370` 已占用之外的空位**：
`001100, 001101, 001110, 001111, 010001, 010011, 010101, 010110, 101000, 101010, 101100, 101110, 111001, 111110`

> 注意 **`101000 / 101010 / 101100 / 101110` 这 4 个 OPMVV 空位正好是 `vmadd(101001)/vnmsub(101011)/vmacc(101101)/vnmsac(101111)` 的"偶数邻居"**，是业界给 int8 点积类指令预留的典型位置。具体采用哪个编码见 `vdot-semantics-research.md`。

### A.7 NEMU 构建方式

**官方流程**（`work/NEMU/README.md:147-160`）：

```bash
export NEMU_HOME=$(pwd)
make menuconfig            # 只在第一次需要（生成 include/config/）
make riscv64-xs-kmhv2-ref_defconfig
make -j
# 产物：./build/riscv64-nemu-interpreter-so
```

> ⚠️ **没有 `make ARCH=riscv64-xs-ref` 这个目标**。`ARCH=` 是 nexus-am（AM）的用法。NEMU 用的是 `<name>_defconfig` + `make`。
> 可用的昆明湖 V2 配置（`work/NEMU/configs/`）：
> - `riscv64-xs-kmhv2-ref_defconfig` ← **本赛题应该用这个**
> - `riscv64-xs-kmhv2-ref-debug_defconfig`（带 debug log）
> - `riscv64-xs-kmhv2-dual-ref_defconfig`（双核 difftest）
> - `riscv64-xs-kmhv2-fastref_defconfig`
> - `riscv64-xs-kmhv2_defconfig`（standalone 模式，不是 ref）

`riscv64-xs-kmhv2-ref_defconfig` 的关键项：

```
CONFIG_RVV=y                      # :32
# CONFIG_CUSTOM_XVEXP2 is not set # :33   ← 我们要在这里加 CONFIG_CUSTOM_XVDOT=y
CONFIG_RV_ZVFH_MIN=y / CONFIG_RV_ZVFH=y
CONFIG_RVV_AGNOSTIC=y             # :106  ← 开启 vta/vma agnostic 行为
CONFIG_ENGINE_INTERPRETER=y       # :116
CONFIG_MODE_SYSTEM=y              # :122
CONFIG_CC="gcc" / CONFIG_CC_O3=y / CONFIG_CC_LTO=y / CONFIG_CC_AGGRESSIVE_INLINE=y   # :128-141
# CONFIG_CC_NATIVE_ARCH is not set  # :139  ← 不会加 -march=native，跨架构友好
CONFIG_MSIZE=0x7ff80000000        # :171
CONFIG_DIFFTEST_CHECK_VCSR=y      # :217  ← 向量 CSR 参与比对
CONFIG_DIFFTEST_CHECK_FCSR=y      # :218
CONFIG_DIFFTEST_CHECK_SDTRIG=y    # :219
CONFIG_SHARE=y                    # :220  ← 编成 .so
CONFIG_SHARE_REF=y                # :221
```

`CONFIG_SHARE=y` 使 `work/NEMU/scripts/build.mk:3-9` 生效：
```make
SO = -so
CFLAGS  += -fPIC -D_SHARE=1
LDFLAGS += -rdynamic -shared -fPIC -Wl,--no-undefined -lz
LDFLAGS += -static-libstdc++ -Wl,--gc-sections -Wl,--exclude-libs,ALL
```
产物名 `$(BUILD_DIR)/$(NAME)$(SO)`，`NAME = nemu-$(ENGINE)`（`Makefile:109`），ISA 前缀由 `scripts/isa.mk` 加上 → **`build/riscv64-nemu-interpreter-so`**。

**宿主依赖**（`README.md:143-146`）：
```bash
apt install build-essential man gcc gdb git libreadline-dev libsdl2-dev zstd libzstd-dev
```
（`CONFIG_SHARE=y` 时不链接 `-lreadline` / `-lSDL2`，见 `Makefile:120-128`，所以 ref 模式对这两个的依赖其实可省。）
**不需要 RISC-V 交叉编译器**来构建 NEMU 本身 —— NEMU 是宿主侧 C 程序。交叉编译器只用于编译被测 workload。

### A.8 linux/aarch64 可移植性评估 ✅

逐项核查（`grep -rn -- "-m32|__x86_64__|immintrin|x86intrin|-msse|-mavx" src/ include/ Makefile scripts/`）：

| 风险点 | 结论 |
|---|---|
| `-m32` | **无任何出现** ✅ |
| `-march=native` | 仅在 `Makefile:112-116`，且**被 `ifndef CONFIG_SHARE` 包住**，ref（.so）模式不生效；而且 kmhv2-ref defconfig 里 `CONFIG_CC_NATIVE_ARCH` 未设 ✅ |
| `immintrin.h` | 3 处，全部在 **AME（矩阵扩展）**：`src/isa/riscv64/instr/ame/mldst_transpose_fast.c:29,33`、`src/cpu/difftest/ame/amuhash_x86.c:22,26`，且都被 `#if defined(__x86_64__)` 守卫（`amuhash.h:9`、`mldst_transpose_fast.h:25`）。存在 `amuhash_portable.c` 作为非 x86 回退 ✅。kmhv2-ref defconfig 里 `# CONFIG_RV_AME is not set`，这些文件根本不编译 ✅ |
| `__x86_64__` 条件 | `src/isa/riscv64/difftest/ref.c:263-268`：x86_64+GCC 用 `memmove`，其它用 `memcpy`，已有 aarch64 路径 ✅ |
| `__int128` / `uint128_t` | 大量使用（如 `vcompute_impl.c:742,754,760` 的 `__uint128_t`）。**aarch64 GCC/Clang 原生支持 `__int128`** ✅ |
| 链接选项 | `-Wl,--no-undefined` / `-Wl,--gc-sections` / `-static-libstdc++` 都是 GNU ld / lld 选项，Linux-aarch64 正常 ✅ |

**结论：NEMU 在 linux/aarch64 上构建 `riscv64-nemu-interpreter-so` 没有架构级障碍。** 这是整条链路中最容易拿下的一环，应优先完成。
（**UNVERIFIED**：未实际执行构建，`-Werror`（`scripts/build.mk:41`）在 GCC 13/14 下可能因新 warning 报错，需实跑验证。）

### A.9 NEMU difftest API 表面

**公共入口**在 `work/NEMU/src/cpu/difftest/ref.c`（所有符号都从 .so 导出，被 difftest 侧 `dlsym` 取出）：

| 符号 | 行号 | 签名 / 说明 |
|---|---|---|
| `difftest_init` | `:444` | `void difftest_init()` |
| `difftest_init_v2` | `:466` | `void difftest_init_v2(unsigned state_size)` |
| `difftest_regcpy` | `:143`（`:135` 为 LIGHTQS 版） | `void difftest_regcpy(void *dut, bool direction)` → 转 `isa_difftest_regcpy` |
| `difftest_csrcpy` | `:149` | `void difftest_csrcpy(void *dut, bool direction)` |
| `difftest_memcpy` | `:110` | `void difftest_memcpy(paddr_t nemu_addr, void *dut_buf, size_t n, bool direction)` |
| `difftest_memcpy_init` | `:102` | 带 `CONFIG_LARGE_COPY` 优化的初始化版 |
| `difftest_exec` | `:205` | `void difftest_exec(uint64_t n)` |
| `difftest_guided_exec` | `:230/:241` | `void difftest_guided_exec(void *guide)` |
| `difftest_raise_intr` | `:263/:270` | `void difftest_raise_intr(word_t NO)` |
| `difftest_status` | `:217` | `int difftest_status()` |
| `difftest_display` | `:475` | `void difftest_display()` |
| `difftest_skip_one` | `:527` | `void difftest_skip_one(bool isRVC, bool wen, uint32_t wdest, uint64_t wdata)` |
| `difftest_store_commit` | `:173` | store 比对 |
| `difftest_uarchstatus_sync` / `_cpy` | `:153/:164/:168` | LR/SC 状态同步 |
| `difftest_set_ramsize` / `difftest_set_mhartid` / `difftest_put_gmaddr` | `:122/:482/:487` | 初始化参数 |
| `difftest_get_vec_load_vdNum` | `:388` | **向量 load 相关** |
| `difftest_update_vec_load_pmem` | `:400` | **向量 load 相关** |
| `difftest_state_hash` / `difftest_flush_state` / `difftest_set_exec_mode` | `:551/:538/:45` | fast-ref / fork-ref |

> 注意：`difftest_step` **不在 NEMU 侧**。NEMU 提供的是 `difftest_exec(n)`；"step 一拍并比对"的逻辑在 difftest 框架（DUT 侧）的 `Difftest::step()`（`work/difftest/src/test/csrc/difftest/difftest.cpp:603`）。

**向量寄存器在 REF 寄存器结构体中的位置** —— `work/NEMU/src/isa/riscv64/include/isa-def.h`：

```c
typedef struct {
  /*** Below will be synced by regcpy when run difftest, DO NOT TOUCH ***/
  union { uint64_t _64; } gpr[32];              // 偏移 0
#ifndef CONFIG_FPU_NONE
  union { uint64_t _64; } fpr[32];
#endif
  // shadow CSRs: mode, mstatus, sstatus, mepc, sepc, mtval, stval, mtvec, stvec,
  //              mcause, scause, satp, mip, mie, mscratch, sscratch, mideleg, medeleg, pc
#ifdef CONFIG_RVH
  uint64_t v; mtval2; mtinst; hstatus; hideleg; hedeleg; hcounteren; htval; htinst; hgatp;
  vsstatus; vstvec; vsepc; vscause; vstval; vsatp; vsscratch;
#endif
#ifdef CONFIG_RVV
  union {                                        // isa-def.h:129-135
    uint64_t _64[VENUM64];   // VENUM64 = 128/64 = 2
    uint32_t _32[VENUM32];
    uint16_t _16[VENUM16];
    uint8_t  _8[VENUM8];
  } vr[32];                                      // ← 32 个 128-bit 向量寄存器
#endif
#ifdef CONFIG_DIFFTEST_CHECK_VCSR
  uint64_t vstart, vxsat, vxrm, vcsr, vl, vtype, vlenb;
#endif
  ...
  uint64_t difftest_state_end;                   // isa-def.h:160
} riscv64_CPU_state;
```

同步范围由 `work/NEMU/src/isa/riscv64/difftest/ref.c:28-29` 决定：

```c
const unsigned DIFFTEST_REG_SIZE =
  offsetof(riscv64_CPU_state, difftest_state_end) - offsetof(riscv64_CPU_state, gpr);
```

`isa_difftest_regcpy`（`src/isa/riscv64/difftest/ref.c:251-283`）就是对这段区间做 `memcpy`/`memmove`，所以 **`vr[32]` 天然在同步和比对范围内**，`vdot` 写进 `vd` 的结果一定会被 difftest 看到 —— 前提是 DUT 侧也上报了向量寄存器（见 Part B）。

> **布局一致性陷阱**：`vr[32]` 占 32×16B = 512B，但 difftest 侧 `DifftestArchVecRegState` 是 **`Vec(64, UInt(64.W))`**（`work/difftest/src/main/scala/Bundles.scala:216` → `ArchRegState(64)`），即 64 个 uint64 = 512B。两边字节数一致，`memcmp` 按 512 字节线性比。因此只要 DUT 端按 `vr[i]._64[0], vr[i]._64[1]` 的顺序排列即可，**NEMU 端不需要为 vdot 做任何额外导出**。

---

## Part B. difftest 协同仿真框架

### B.1 端到端机制

```
   [DUT: Verilated XiangShan SimTop]                [REF: riscv64-nemu-interpreter-so]
            |                                                     ^
    Chisel DifftestModule 探针                                    | dlsym()
    (DiffInstrCommit / DiffArchEvent /                            |
     DiffTrapEvent / DiffCSRState /                     RefProxy / NemuProxy
     DiffPhyIntRegState / DiffPhyVecRegState / ...)    (refproxy.cpp/.h)
            |  DPI-C（或 Batch/Squash 压缩通道）                   |
            v                                                     |
    diffstate_buffer  --->  Difftest::step()  --->  checkers  ----+
                                 |
                          proxy->compare(dut)  → 0/1
                                 |
                          proxy->display(dut)  → REPORT_DIFFERENCE
```

**1）DUT 提交指令。** XiangShan 在 ROB 提交点例化 Chisel 探针 `DifftestModule(new DiffInstrCommit, delay=N)`。
`work/difftest/src/main/scala/Bundles.scala:68-94` 定义了 `InstrCommit`：
```scala
class InstrCommit(val numPhyRegs: Int = 32) extends DifftestBaseBundle with HasValid {
  val skip, isRVC, rfwen, fpwen, vecwen, v0wen = Bool()   // :69-74
  val wpdest = UInt(log2Ceil(numPhyRegs).W)
  val wdest  = UInt(8.W)
  val otherwpdest = Vec(16, UInt(log2Ceil(numPhyRegs).W))
  val pc, instr, robIdx, lqIdx, sqIdx = ...
  val isLoad, isStore = Bool()
  val nFused, special = UInt(8.W)
}
```
注意 **`vecwen`（向量写使能）和 `v0wen`** 是专门为向量指令准备的；`otherwpdest` 用来报告一条向量指令拆成多个 uop 时写的多个物理寄存器。

**2）架构状态探针。** 昆明湖上报的是**物理寄存器堆 + 重命名表**，而不是架构寄存器：
- `DiffPhyVecRegState(numPhyRegs)` —— `work/difftest/src/main/scala/Difftest.scala:395-399`
- `DiffArchVecRenameTable(numPhyRegs)` —— `Difftest.scala:369-371`
- difftest 的 C++ 侧再用 RAT 把物理寄存器折算成 `DiffArchVecRegState`（`desiredCppName = "vrf"`，`Difftest.scala:347-352`）。

XiangShan 侧的例化点（kunminghu-v3，**v2 需另行确认 UNVERIFIED**）：
```
work/XiangShan/src/main/scala/xiangshan/backend/datapath/DataPath.scala:502
  val difftest = DifftestModule(new DiffPhyVecRegState(vecDiffNumPregs), delay = 2)
work/XiangShan/src/main/scala/xiangshan/backend/vector/VecRegionModule.scala:426
  val difftest = DifftestModule(new DiffPhyVecRegState(vecDiffNumPregs), delay = 2)
work/XiangShan/src/main/scala/xiangshan/backend/fu/NewCSR/NewCSR.scala:1750
  val diffVecCSRState = DifftestModule(new DiffVecCSRState)
```

**3）REF .so 的加载。** `work/difftest/Makefile:218-230`：
```make
REF ?= Nemu
ifneq ($(wildcard $(REF)),)      # REF 是一个文件路径 → 静态链接
  SIM_CXXFLAGS += -DREF_PROXY=LinkedProxy -DLINKED_REFPROXY_LIB=\"$(REF)\"
  SIM_LDFLAGS  += $(REF)
else                              # REF 是名字（Nemu/Spike）→ 运行时 dlopen
  SIM_CXXFLAGS += -DREF_PROXY=$(REF)Proxy
  SIM_CXXFLAGS += -DREF_HOME=\"$(NEMU_HOME)\"
endif
```
运行期 `./build/emu --diff /path/to/riscv64-nemu-interpreter-so` 指定 .so，`AbstractRefProxy::load_function<T>()` 用 `dlsym` 把上面 A.9 列的所有 `difftest_*` 符号取出来。

**4）比对与报错。**
- `Difftest::step()` —— `work/difftest/src/test/csrc/difftest/difftest.cpp:603`
- → `Difftest::check_all()` —— `difftest.cpp:676`，依次跑所有 `checkers`（InstrCommitChecker / ArchEventChecker / StoreChecker / LoadChecker …）
- → 每提交一条指令，REF 侧 `difftest_exec(1)`，然后 `proxy->sync()`（`refproxy.h:282-284`，内部 `ref_regcpy(&state.xrf, REF_TO_DUT, false)`）
- → `RefProxy::compare(dut)` —— `work/difftest/src/test/csrc/difftest/refproxy.cpp:184-230`：
  ```c
  #define PROXY_COMPARE(field) memcmp(&(dut->regs.field), &(state.field), sizeof(state.field))
  const int results[] = { PROXY_COMPARE(xrf),
  #ifdef CONFIG_DIFFTEST_ARCHFPREGSTATE
                          PROXY_COMPARE(frf),
  #endif
  #ifdef CONFIG_DIFFTEST_ARCHVECREGSTATE
                          PROXY_COMPARE(vrf),          // ← 向量寄存器比对
  #endif
  #ifdef CONFIG_DIFFTEST_VECCSRSTATE
                          PROXY_COMPARE(vcsr),         // ← 向量 CSR 比对
  #endif
                          ... PROXY_COMPARE(csr) };
  ```
- 不一致 → `difftest.cpp:753-760` 打印 `Mismatch detected ...`，`RefProxy::display(dut)`（`refproxy.cpp:232-270`）用 `PROXY_COMPARE_AND_DISPLAY(vrf, regs_name_vec)` 逐 64-bit lane 打印 REF/DUT 值，然后 `STATE_BADTRAP` 终止仿真。

> **三句话版**：XiangShan 在 ROB 提交点通过 Chisel 的 `DifftestModule` 探针（`DiffInstrCommit` + `DiffPhyVecRegState` + `DiffCSRState` + …）把每周期的提交信息和全部架构状态经 DPI-C 送进 C++ 侧的 `diffstate_buffer`；`Difftest::step()` 每看到一条提交就让通过 `dlopen` 加载的 NEMU `.so` 执行 `difftest_exec(1)`，再 `ref_regcpy` 把 REF 的整块寄存器状态拷回来。`RefProxy::compare()` 对 `xrf/frf/vrf/csr/vcsr/...` 逐块 `memcmp`，一旦不等就立刻 `display()` 打印出不一致的寄存器名和 REF/DUT 两个值并终止仿真，从而把 bug 钉死在出错的那一条指令上。

### B.2 向量架构寄存器默认是否参与比对？怎么打开？

**默认参与，但有条件。** 机制是：

1. **Chisel 侧**：只要设计里例化了 `DiffPhyVecRegState` / `DiffArchVecRegState`，`DifftestModule.finish()` 就会生成对应的 C++ 头和 `#define CONFIG_DIFFTEST_ARCHVECREGSTATE` 宏（生成在 `$(BUILD_DIR)/generated-src/diffstate.h`）。
   README 的 API 表（`work/difftest/README.md:148`）把 `DiffPhyVecRegState` 标为 **"Mandatory = No"**，即可选探针。
2. **C++ 侧**：所有向量比对代码都包在 `#ifdef CONFIG_DIFFTEST_ARCHVECREGSTATE` 里 —— `refproxy.h:238-240`、`refproxy.cpp:164-166,192-194,255-257`、`difftest.h:134-138`、`checkers.h:478-481,499-502`。
3. **NEMU 侧**：`vr[32]` 在 `CONFIG_RVV` 下无条件进入 `DIFFTEST_REG_SIZE` 区间（`isa-def.h:128-136`）。向量 CSR 额外受 `CONFIG_DIFFTEST_CHECK_VCSR` 控制（`isa-def.h:138-141`、`ref.c:77-85,166-174`），**kmhv2-ref defconfig 已经 `=y`**（`configs/riscv64-xs-kmhv2-ref_defconfig:217`）。

**所以对本赛题来说：XiangShan 默认配置 + `riscv64-xs-kmhv2-ref_defconfig` 已经开启了向量寄存器比对，vdot 的结果会被自动校验，无需额外开关。** 要确认的只有一点：构建 emu 时 `--enable-difftest` 要在（`work/XiangShan/Makefile:264` 的 `DEBUG_ARGS` 默认带，只要不设 `RELEASE=1`/`FPGA=1`）。

> **已知限制**：`refproxy.h:274-278`
> ```c
> #ifdef CONFIG_DIFFTEST_ARCHVECREGSTATE
>   // TODO: vec skip is not supported at this time.
>   if (vecwen) assert(0);
> #endif
> ```
> 即**向量指令不支持 `skip`**（MMIO 跳过机制）。vdot 不涉及访存，无影响。

### B.3 构建仿真：`make emu` 全链路

**XiangShan 侧**（`work/XiangShan/Makefile:398-406`）：
```make
emu-mk: sim-verilog
	$(MAKE) -C ./difftest emu-mk NUM_CORES=$(NUM_CORES) RTL_SUFFIX=$(RTL_SUFFIX) RTL_INCLUDE="$(RTL_INCLUDE)"
emu: $(call docker-deps,emu-mk)
	$(MAKE) -C ./difftest emu NUM_CORES=$(NUM_CORES) RTL_SUFFIX=$(RTL_SUFFIX) OBJCACHE=$(OBJCACHE)
```
`sim-verilog` → mill 跑 Chisel 生成 `build/rtl/SimTop.sv`（`CHISEL_TARGET=systemverilog`，`MFC_ARGS` 含 `--split-verilog --dump-fir`，`Makefile:217-220`）。

README 给的示例（`work/XiangShan/README.md:132-136`）：
```bash
make emu CONFIG=MinimalConfig EMU_THREADS=2 -j10
./build/emu -b 0 -e 0 -i ./ready-to-run/coremark-2-iteration.bin \
            --diff ./ready-to-run/riscv64-nemu-interpreter-so
```

**关键 make 变量**：

| 变量 | 定义处 | 作用 |
|---|---|---|
| `CONFIG` | `XiangShan/Makefile:52` | Chisel Config 名。`DefaultConfig`（全尺寸）/ `MinimalConfig`（`top/Configs.scala:93`，小 cache、小 BPU，**编译快得多**） |
| `EMU_THREADS` | `difftest/emu.mk:44-46`, `verilator.mk:63-65` | → `--threads N --threads-dpi all` 传给 verilator，并 `-DEMU_THREAD=N`。`0` = 单线程。CI 用 8（verilator ≥5.050）或 16（更老版本），见 `XiangShan/.github/workflows/emu.yml:206-215` |
| `EMU_TRACE` | `emu.mk:38`, `verilator.mk:50-56` | `1`/`vcd`/`VCD` → `--trace`（VCD）；`fst`/`FST` → `--trace-fst` + `-DENABLE_FST`。**必须在编译期设置** |
| `EMU_TRACE_ALL` | `verilator.mk:59-61` | `--trace-underscore`，连内部下划线信号一起 dump |
| `EMU_SNAPSHOT` | `verilator.mk:67-69` | `--savable` |
| `EMU_COVERAGE` | `verilator.mk:71-73` | `--coverage-line --coverage-toggle` |
| `WITH_DRAMSIM3` | `difftest/Makefile:235-241` | 把 DRAMsim3 作为内存时序模型接入（`-DWITH_DRAMSIM3`，链接 `-ldramsim3`，读 `$DRAMSIM3_HOME/configs/XiangShan.ini`）。**只影响性能数字的真实性，不影响功能正确性**；要求先编好 DRAMsim3。对 vdot 功能验证可以 `WITH_DRAMSIM3=0`（默认关） |
| `WITH_CHISELDB` / `WITH_CONSTANTIN` | `difftest/Makefile:189-206` | 默认 `=1`，需要 `libsqlite3-dev`。**为省事可 `WITH_CHISELDB=0 WITH_CONSTANTIN=0`** |
| `REF` | `difftest/Makefile:218` | 默认 `Nemu`，运行时 `dlopen` |
| `NO_DIFF` | `difftest/Makefile:103-106` | `=1` 完全去掉 difftest C++ 代码 |
| `OPT_FAST` | `verilator.mk:76` | 默认 `-O3 -fno-slp-vectorize`（C++ 编译优化） |
| `JVM_XMX` | `XiangShan/Makefile:99` | **默认 `40G`** —— mill/Chisel 精化的 JVM 最大堆 |

**生成波形**：

```bash
# 1) 编译期打开 trace（二选一）
make emu CONFIG=MinimalConfig EMU_TRACE=fst EMU_THREADS=1 -j8     # FST（体积小，推荐）
make emu CONFIG=MinimalConfig EMU_TRACE=1   EMU_THREADS=1 -j8     # VCD

# 2) 运行期指定 dump 窗口（-b 起始周期，-e 结束周期，0 = 不限）
./build/emu -i workload.bin --diff $NEMU_HOME/build/riscv64-nemu-interpreter-so \
            -b 0 -e 0 --dump-wave --wave-path ./wave.fst
```
运行期参数（`work/difftest/src/test/csrc/common/args.cpp`）：
- `--dump-wave`（`:128,183`）/ `--dump-wave-full`（`:129,203`）
- `--wave-path=FILE`（`:139,190`）
- `--dump-ref-trace`（`:130,196`）—— dump NEMU 侧 trace
- `-C/--max-cycles=NUM`（`:105,230`）
- `--enable-fork`（`:142,188`）—— LightSSS 快照，出错后自动回放并打开波形；**不要和 `-b/-e/--dump-wave` 同时用**（`difftest/README.md:228-230`）
- `--no-diff` —— 关闭比对

---

## Part C. 环境部署流程（竞赛阶段一）

### C.1 `xs-env` 的权威部署流程

`work/xs-env/README.md:8-21` 给出的 TLDR：

```sh
git clone https://github.com/OpenXiangShan/xs-env
cd xs-env
sudo -s ./setup-tools.sh    # 用 apt 装依赖（只跑一次）
source setup.sh             # 拉子模块 + 用小项目验证环境（只跑一次）
```
之后**每次**使用开发环境：
```sh
cd xs-env && source ./env.sh
```

### C.2 每一步做了什么

**`setup-tools.sh`**（`work/xs-env/setup-tools.sh`）—— 支持 `--target {all,base,optional,llvm,jdk,mill,verilator,gsim}`；`default` = `base + llvm + jdk + mill + verilator + gsim`（`:60-70`）。

| target | 脚本 | 内容 |
|---|---|---|
| `base` | `install-scripts/base.sh` | `apt install sudo vim git make g++ time curl ca-certificates libreadline6-dev libsdl2-dev **g++-riscv64-linux-gnu** zlib1g-dev device-tree-compiler flex autoconf bison sqlite3 libsqlite3-dev zstd libzstd-dev python3 python3-pip python-is-python3 python3-protobuf python3-grpc-tools python3-psutil python3-yaml numactl` |
| `llvm` | `install-scripts/llvm.sh` | 从 **apt.llvm.org** 装 clang/bolt/llvm/libclang-rt（Ubuntu ≥26.04 用 LLVM 21，否则 **LLVM 19**），软链 `/usr/local/llvm`。原因：gsim 要 clang 19+，verilator 5.050+ 要 clang 18+，而 Ubuntu 20/22 仓库的 clang 太旧 |
| `jdk` | `install-scripts/jdk.sh` | 下载 **GraalVM JDK 21** 到 `/opt/graalvm-jdk-21`。注释写明：**"do not change this unless tested, XiangShan does not compile with JDK 25 yet"** ← 直接回答了宿主 JDK 25 的问题。支持 `linux-x64` 和 **`linux-aarch64`** ✅ |
| `mill` | `install-scripts/mill.sh` | `curl` 下载 **mill-dist 1.0.4** 到 `/usr/local/bin/mill`（纯 shell 脚本，架构无关）。注意 `work/XiangShan/.mill-version` = **`0.12.17`**，bootstrap 脚本会按该文件再下载对应版本 |
| `verilator` | `install-scripts/verilator.sh` | apt 装构建依赖（`help2man perl python3 make autoconf g++ flex bison libgoogle-perftools-dev libjemalloc-dev numactl perl-doc zlib1g-dev liblz4-dev libfl2 libfl-dev`），然后 **`git clone verilator && git checkout v5.052 && ./configure CC=clang CXX=clang++ && make -j$(nproc) && make install`**（从源码编译，约 10–30 分钟） |
| `gsim` | `install-scripts/gsim.sh` | 从 GitHub Release 下载 OpenXiangShan **gsim** 预编译二进制。**显式支持 `aarch64` → `GSIM_ARCH=ARM64`** ✅（`gsim.sh:20-24`）。gsim 是香山自研的快速 RTL 模拟器，直接吃 CHIRRTL，**不需要 verilator** |
| `optional` | `install-scripts/optional.sh` | `proxychains4 htop zsh tmux rsync wget` |

**`setup.sh`**（`work/xs-env/setup.sh`）：
```sh
git submodule update --init --recursive DRAMsim3 NEMU NutShell nexus-am
git submodule update --init XiangShan && make -C XiangShan init
source ./env.sh
```
子模块（`work/xs-env/.gitmodules`）：
- `XiangShan` → github.com/OpenXiangShan/XiangShan
- `NEMU` → github.com/OpenXiangShan/NEMU，**branch = `xs`**
- `nexus-am` → OpenXiangShan/nexus-am（AM baremetal 库，用来编 workload）
- `NutShell` → OSCPU/NutShell，**branch = `difftest`**（只用于环境自检）
- `DRAMsim3` → OpenXiangShan/DRAMsim3

`make -C XiangShan init`（`work/XiangShan/Makefile:366-369`）：
```make
init:
	git submodule update --init
	cd rocket-chip && git submodule update --init cde hardfloat
	cd XSCache  && git submodule update --init OpenNCB ZhuJiang
```

**`env.sh`**（`work/xs-env/env.sh`）只设 5 个变量：
```sh
export XS_PROJECT_ROOT=<xs-env 绝对路径>
export NEMU_HOME=$XS_PROJECT_ROOT/NEMU
export AM_HOME=$XS_PROJECT_ROOT/nexus-am
export NOOP_HOME=$XS_PROJECT_ROOT/XiangShan
export DRAMSIM3_HOME=$XS_PROJECT_ROOT/DRAMsim3
```

### C.3 官方 "hello world" / 冒烟测试流程

`work/xs-env/env-test.sh` 就是官方自检脚本（CI 的 `setup-develop-env` job 直接 `source ./env-test.sh`，见 `.github/workflows/main.yml:49-52`）：

```sh
source ./env.sh
export NOOP_HOME=$(pwd)/NutShell        # ← 用更小的 NutShell 代替 XiangShan 做自检

# 打印版本
gcc --version; clang --version; java --version; verilator --version; gsim --version

# 1) 测 NEMU 能否编译
cd ${NEMU_HOME}
make riscv64-nutshell-ref_defconfig
make

# 2) 测 mill & Chisel
cd ${NOOP_HOME}            # NutShell
make init
make clean
make verilog

# 3) 测 verilator
make emu

# 4) 真正跑一次仿真
./build/emu -b 0 -e 0 -i ./ready-to-run/microbench.bin
```

**这就是竞赛"阶段一：环境部署与验证"最该照搬的流程。** 注意它刻意用 **NutShell**（一个几千行的小核）而不是 XiangShan 来验证环境，因为 XiangShan 本身编译代价极大 —— 这个设计对我们的资源受限场景是个重要启示（见 Part D 的回退策略）。

XiangShan 自己的 hello world（`work/XiangShan/README.md:132-136`）：
```bash
make emu CONFIG=MinimalConfig EMU_THREADS=2 -j10
./build/emu -b 0 -e 0 -i ./ready-to-run/coremark-2-iteration.bin \
            --diff ./ready-to-run/riscv64-nemu-interpreter-so
```
> ⚠️ 本地 `work/XiangShan/ready-to-run/` **是空目录**（它是独立 submodule，`.gitmodules` → github.com/OpenXiangShan/ready-to-run，未初始化）。执行 `git submodule update --init ready-to-run` 后才会有 `coremark-2-iteration.bin` / `microbench.bin` / 预编译的 `riscv64-nemu-interpreter-so`。其余子模块（difftest / yunsuan / rocket-chip / XSCache / utility / ChiselAIA / ChiselIOPMP / OpenIOMMU）本地**均已填充**。

### C.4 `xs-env` 的容器化路径

`work/xs-env/Dockerfile`：`FROM ubuntu:24.04`（`ARG BASE_IMAGE`），分层执行 `setup-tools.sh --target base/llvm/jdk/mill/verilator/gsim/optional`，最后 `ENV PATH="/usr/local/llvm/bin:/opt/graalvm-jdk-21/bin:$PATH"`、`JAVA_HOME=/opt/graalvm-jdk-21`。
`work/XiangShan/Dockerfile`：`FROM ghcr.io/openxiangshan/xs-env:stable` + mill 预热 + `make deps`。

**镜像 tag**（`work/xs-env/.github/workflows/docker.yml:52-75`）：
`ghcr.io/openxiangshan/xs-env:{latest,stable,ubuntu-20.04-slim,ubuntu-22.04-slim,ubuntu-24.04,ubuntu-24.04-slim,ubuntu-26.04,ubuntu-26.04-slim}`
- `stable` = ubuntu 24.04
- `latest` = ubuntu 26.04

🔴 **但 `platforms: linux/amd64`（`docker.yml:89,146`）—— 只构建 amd64，没有 arm64。** 实测确认：
```
$ docker manifest inspect ghcr.io/openxiangshan/xs-env:ubuntu-24.04
  manifests: [ { platform: { architecture: "amd64", os: "linux" } },
               { platform: { architecture: "unknown", os: "unknown" } } ]   # attestation
```
**官方镜像在 Apple Silicon 上只能通过 QEMU 用户态模拟运行（极慢，约 5–20×），或者自己用 `xs-env/Dockerfile` 在 arm64 上重新 build。**

`work/XiangShan/scripts/Makefile.docker` 提供 `make image` / `make <target> IN_XSDEV_DOCKER=...`，把 mill 跑在 `ghcr.io/openxiangshan/xsdev:<branch>` 容器里，源码只读挂载、`out/` 和 `build/` 可写挂载。

### C.5 XiangShanLab 教学材料

> ⚠️ 侦察后期 `work/XiangShanLab/` 被删除（疑似重新克隆中）。以下为被删除前抓取到的内容。

**顶层目录树**：
```
XiangShanLab/
├── 2026-CIE-RISC-V-Contest-Application-Track/    ← 本赛题
│   ├── README.md                 赛题说明
│   ├── SUBMISSION_GUIDE.md       提交流程
│   ├── submit.sh                 GPG 加密提交脚本
│   ├── contest/public-key.asc    评审公钥
│   ├── admin/decrypt_summary.sh
│   ├── 00_大赛总览与指南/
│   └── 01_参赛选手提交区/{Test_Team,零一}/submission.asc
├── xiangshan-course/             ← 14 章中文课程 + 8 章英文
├── xiangshan-programming-practice/  ChiselIOPMP / IopmpSystem / TwoToOneXbarSystem /
│                                    NonBlockingCache / mmu-smmpt / miniXiangShan
├── xiangshan-question-bank/      题库（含 "Hello XiangShan"）
├── xiangshan-bugs-library/       昆明湖 bug 案例库
├── tools/                        xiangshan-code-analyzer / analyze-xiangshan-wavekit /
│                                 xiangshan-wave-analysis / scenarios-extractor /
│                                 verification-driver / xiangshan-debug /
│                                 xiangshan-bugs-analyzer / riscv-skill-pack /
│                                 specification-analyzer / wavekit-xslab(submodule)
├── XiangShanLab-user-guide/      学习路径指引
├── xiangshan-research/ xiangshan-collaborators/ weekly-status/
├── external-contribution-project/
└── RISC-V-International-Participation-Guide/
```

**赛题原文**（`2026-CIE-RISC-V-Contest-Application-Track/README.md`）：
- 赛题名称：**面向边缘AI大语言模型推理的RISC-V自定义vdot指令设计-基于"香山"昆明湖V2处理器架构**
- **官方赛题页面：https://rv.cie.org.cn/direction?id=8** ← 语义定义图应在此页
- 背景：点积占 LLM/推荐系统 60–80% 计算量，GPT-2 中占 70%+
- 开发平台：`https://github.com/OpenXiangShan/xs-env.git` + `https://github.com/OpenXiangShan/XiangShanLab.git`

**提交要求**（`SUBMISSION_GUIDE.md`）：
1. Fork `OpenXiangShan/XiangShanLab`
2. 另建一个**公有**仓库 `cie2026-团队名称-作品名` 放作品
3. 在 `2026-CIE-RISC-V-Contest-Application-Track/` 下写 `my_submission.txt`（team-name / repo-url / github-username / contact-email / project-description / team-members / university / advisor / phone / notes），UTF-8
4. `source ./submit.sh my_submission.txt` → GPG 加密成 `01_参赛选手提交区/<团队名>/submission.asc`
5. push 到自己的 fork，再向 `OpenXiangShan/XiangShanLab:main` 发 PR
6. PR 标题格式：`[2026CIE大赛] 团队名称 - 项目名称`
7. **PR 描述里有三个阶段 checkbox**：
   - [ ] 阶段一：**环境部署与验证**
   - [ ] 阶段二：**vdot设计与实现**
   - [ ] 阶段三：**协同仿真与评估**

**第 1 章"香山开发环境"目录**（`xiangshan-course/docs/1-xiangshan-development-environment/`）：

| 文件 | 行数 | 主题 |
|---|---|---|
| `Introduction_Preface.md` | 46 | 前言 |
| `Chapter_1_Overview_of_the_Xiangshan_Development_Environment.md` | 409 | 开发环境总览 |
| `Chapter_1.5_Setting_up_Metals_in_VS_Code.md` | 70 | VS Code + Metals（Scala LSP） |
| `Chapter_2_Preparing_and_Understanding_the_Tools.md` | 977 | 工具链准备（mill/Chisel/verilator/…） |
| `Chapter_3_Applications.md` | 737 | 应用/workload |
| `Chapter_4_Instruction_Emulator__CPU_Simulation_and_Reference_Models_NEMU_Spike.md` | 750 | **NEMU / Spike 参考模型** |
| `Chapter_5_DRAMsim3_Memory_Simulation.md` | 339 | DRAMsim3 |
| `Chapter_6_The_Xiang_Shan_Simulation_Process.md` | 541 | **香山仿真流程** |
| `Chapter_7_The_GEM5_emulator.md` | 388 | GEM5 |
| `Chapter_8_The_Difftest_Co_Simulation_Framework.md` | 451 | **Difftest 协同仿真框架** |
| `attachments/`, `img/`, `FAQ/` | — | 附件与 FAQ |

**第 8 章 Difftest 要点**（与我们在 Part B 的源码核对一致）：
- 原理：DUT（香山） vs REF（NEMU/Spike），同规范两实现在相同输入下行为应一致
- 流程：执行指令 → 状态提取 → REF 同步执行 → 状态对比 → 结果处理
- 覆盖 "32 种状态检查"（寄存器 / 内存 / 异常 / 缓存一致性 / **向量化检查** / TLB …）
- 运行参数：`-i/--image`、`--diff <nemu .so>`、`--no-diff`
- 调错三部曲：**查 PC（在 `build/*.txt` 反汇编里搜地址）→ 看波形 → 改 Chisel**
- 成功标志：`HIT GOOD TRAP`

**其它与本赛题相关的课程材料**（grep 命中）：
- `xiangshan-course/docs/3-riscv-specification/unprivileged-spec/9-vector-operation/1-rvv.md` ← RVV 规范
- `xiangshan-course/docs/5-xiangshan-scenarios-analysis/instructions-lifecycle/vector-float-add/simple-execution-process-of-a-vfadd-instruction.md` ← **一条向量指令在香山里的完整生命周期，是实现 vdot RTL 时最该读的一篇**
- `xiangshan-course/docs/4-xiangshan-microarchitecture-analysis/2-xiangshan-design-document/9_Execute_Unit.md` ← 执行单元设计文档
- `xiangshan-course/docs/4-.../3-xiangshan-source-code-analysis/backend/Decode.md`、`Rename.md`
- 波形分析：`docs/5-.../branch-predictors/BPU-waveform-scenario-analysis.md`、`docs/5-.../cbo-inval/WAVEFORM_ANALYSIS.md`、`tools/analyze-xiangshan-wavekit/`、`tools/xiangshan-wave-analysis/`
- `xiangshan-course/docs/8-xiangshan-AI/basic-algorithm/24.parallel-strategies/parallel_strategies.md` ← 全仓唯一一处命中 "vdot" 字样的非赛题文档（并行策略，**不是指令定义**）

> **结论：XiangShanLab 中没有任何 vdot 指令语义的定义文档。** 语义只存在于官方赛题页 https://rv.cie.org.cn/direction?id=8 的那张图里。

---

## Part D. 可行性与资源评估（诚实版）

### D.1 一句话结论

> **在 Docker linux/aarch64 + 8 GB RAM + 10 核上，完整跑通"Verilated 全尺寸昆明湖 V2 + difftest"几乎不可行；`MinimalConfig` 也高度存疑。但 NEMU 侧和功能单元级验证完全可行。建议采用"NEMU 完整实现 + 独立功能单元级 Chisel/Verilator 协同仿真"为主线，把全核 difftest 作为"有条件则补做"的加分项。**

### D.2 证据：构建资源需求

| 证据 | 位置 | 含义 |
|---|---|---|
| `JVM_XMX ?= 40G` | `work/XiangShan/Makefile:99` | Chisel 精化（`make verilog`/`sim-verilog`）的 JVM 最大堆默认 **40 GB**。`-Xmx` 是上限不是预留，但官方把默认设成 40G 说明实际峰值远超 8 GB。**8 GB 容器（JVM 可用约 6–7 GB）极可能 OOM** |
| `JVM_XSS ?= 256m` | `Makefile:100` | Chisel 精化递归很深，需要 256 MB 栈 |
| CI 全部跑在 `runs-on: builder` / `perf` / `eda` 自建机 | `.github/workflows/emu.yml:98,188,253,310,375`；`emu-basics.yml:36`；`emu-performance.yml:46` | **没有任何一个真正编译 XiangShan 的 job 跑在 GitHub 托管的 `ubuntu-latest`（2-core/7 GB）上。** 只有 changes-detection、lint、`make test-jar` 这类轻量 job 用 `ubuntu-latest` |
| `timeout-minutes: 900`（MC EMU）/ `180`（basics build） | `emu.yml:189`；`emu-basics.yml:40` | 官方给单次构建留 3–15 小时 |
| `EMU_THREADS=8`（verilator ≥5.050）/ `16` | `emu.yml:206-215` | 官方仿真用 8–16 线程 |
| `--numa` | `emu.yml:235,242` | CI 机器是 NUMA 多路服务器 |
| 推荐 XSPdb 预编译二进制而不是本地构建 | `XiangShan/README.md:139-145` | 官方自己说："It is lightweight and requires no compilation. A standard Python environment is enough to run the full XiangShan experience with **low memory usage**." ← **官方承认本地构建内存开销大** |
| `env-test.sh` 用 NutShell 而非 XiangShan 自检 | `xs-env/env-test.sh:11` | 官方环境自检刻意避开 XiangShan 的构建代价 |

**经验数字（UNVERIFIED，来自社区常识，非本地源码可证）**：
- `make verilog` (DefaultConfig)：峰值 JVM 堆 ~16–32 GB，30–90 分钟
- `make verilog` (MinimalConfig)：峰值 JVM 堆 ~8–16 GB，10–30 分钟
- Verilator 对 ~2M 行 SystemVerilog 做 `--threads 8`：峰值 RSS 20–60 GB，1–6 小时
- `./build/emu` 运行时 RSS：DefaultConfig ~4–8 GB（含 DifftestMem）

### D.3 verilator 在 arm64 apt 上的可用性（实测）

| 发行版 (arm64) | `verilator` candidate | 结论 |
|---|---|---|
| ubuntu:22.04 (jammy/universe) | **4.038-1** | ❌ 太旧。`difftest/verilator.mk:38-43` 会走 `VERILATOR_LEGACY` 分支；XiangShan 的 Chisel 7 / firtool 输出的 SV 几乎肯定不被 4.038 接受 |
| ubuntu:24.04 (noble/universe) | **5.020-1** | ⚠️ 勉强。`VERILATOR_5_000=1` → `--no-timing +define+VERILATOR_5`；`VERILATOR_5_024=0` → 无 `--quiet-stats`。是否能编译昆明湖 RTL **UNVERIFIED** |
| 官方要求 | **v5.052 源码编译** | `xs-env/install-scripts/verilator.sh:28` `git checkout v5.052`，用 clang 编译。CI 注释提到 "verilator 5.050+ has refactored multi-threading"（`emu.yml:206-207`） |

`difftest/verilator.mk:32-47` 的版本门槛是软门槛（只影响 flags），**没有硬性下限检查**。但实践上 XiangShan 主线只在 5.05x 上回归测试。

**verilator 本身在 arm64 上从源码编译是没问题的**（纯 C++ + autoconf），`install-scripts/verilator.sh` 没有任何架构判断。编译 verilator 本身约需 10–30 分钟 / 2–4 GB。

### D.4 RISC-V 交叉编译器在 linux/arm64 上的可用性（实测）

| 包 | ubuntu:22.04 arm64 | ubuntu:24.04 arm64 |
|---|---|---|
| `gcc-riscv64-unknown-elf` | 10.2.0-0ubuntu1 | **13.2.0-11ubuntu1+12** |
| `picolibc-riscv64-unknown-elf` | — | 1.8.6-2 |
| `gcc-riscv64-linux-gnu` | 4:11.2.0--1ubuntu1 | **4:13.2.0-7ubuntu1** |
| `g++-riscv64-linux-gnu` | 4:11.2.0--1ubuntu1 | **4:13.2.0-7ubuntu1** |
| `gcc` (host) | 11.2.0 | 13.2.0 |
| `clang` | — | 1:18.0-59~exp2 |

**RVV 支持所需的 GCC 版本**：
- GCC ≤ 11：**无** V 扩展支持
- GCC 12：实验性 RVV 0.11/1.0 草案，`-march=rv64gcv` 可能被接受但 intrinsics 不全
- **GCC 13：首个支持批准版 RVV 1.0 的正式版本**，`-march=rv64gcv_zvl128b` 可用，`riscv_vector.h` intrinsics 基本完整
- GCC 14：RVV intrinsics v1.0 完整 + 自动向量化显著改善

> ✅ **Ubuntu 24.04 arm64 的 `gcc-riscv64-unknown-elf 13.2.0` 和 `gcc-riscv64-linux-gnu 13.2.0` 都足以编译 `-march=rv64gcv` 的 RVV baseline 代码。**
> ⚠️ Ubuntu 22.04 的 GCC 10/11 **不行**，必须用 24.04 或自己装 toolchain。
> ⚠️ 自定义指令 `vdot.vv` 汇编器不认识，必须用 `.insn` 伪指令或 `.word` 手工编码（这跟 toolchain 版本无关）。
> ⚠️ `xs-env/install-scripts/base.sh` 只装 `g++-riscv64-linux-gnu`（Linux ABI），没装 `gcc-riscv64-unknown-elf`（baremetal）。nexus-am 的 baremetal workload 通常也能用 `riscv64-linux-gnu-gcc -nostdlib` 编，**UNVERIFIED**。

### D.5 官方 Docker 镜像与多架构

| 镜像 | 来源 | 架构 |
|---|---|---|
| `ghcr.io/openxiangshan/xs-env:{latest,stable,ubuntu-XX.YY[-slim]}` | `xs-env/.github/workflows/docker.yml` | **仅 linux/amd64**（`platforms: linux/amd64`，`:89,:146`）。实测 `docker manifest inspect ghcr.io/openxiangshan/xs-env:ubuntu-24.04` 只有 `amd64` + attestation，**无 arm64** ❌ |
| `ghcr.io/openxiangshan/xsdev:<branch>` | `XiangShan/Dockerfile` + `scripts/Makefile.docker:21` | 基于上面那个，同样只有 amd64 ❌ |
| 自建 | `docker build --platform linux/arm64 -f xs-env/Dockerfile xs-env/` | ✅ 可行：`jdk.sh` 和 `gsim.sh` 都显式支持 `aarch64`，`verilator.sh` 从源码编译，`mill.sh` 架构无关。预计构建耗时 40–90 分钟 |

### D.6 kunminghu-v2 vs v3 的额外风险

本地 clone 是 **v3**。v3 的向量后端被完全重写：
- `work/XiangShan/src/main/scala/xiangshan/backend/vector/Decoder/`（`DecodePatterns.scala`、`InstPattern/VecArithInstPattern.scala`、`Split/SplitTable.scala`、`Uop/`、`DecodeFields/` …）—— 一套全新的、基于 trait mixin 的 RVV 译码/拆分框架
- `work/XiangShan/src/main/scala/xiangshan/backend/vector/VecRegionModule.scala`（新的向量寄存器分区）
- `work/XiangShan/CONTRIBUTING.zh-cn.md:42` 明确警告："**`kunminghu-v3` 的向量单元经历了完整重构，当前以提升性能为主要目标，在部分边界情况下可能仍存在功能问题**"

**昆明湖 V2 的向量执行单元在 `yunsuan` 子模块里**（本地 `work/XiangShan/yunsuan/` **已 init，有内容**），加 vdot 需要同时改 XiangShan 的 `DecodeUnit.scala` + yunsuan 的 `vector/vectorIMAC/VIMac*.scala`。
佐证：`work/XiangShan/yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/VIMac.scala` 在当前（v3）分支上 99 行里有 90 行是注释 —— 整个模块被注释掉了，说明 v3 已把向量 MAC 从 yunsuan 迁到 `xiangshan/backend/vector/` 下的新框架；而 `VIMac64b.scala`(135 行) / `VIMac64bStage1~3.scala`(510/193/320 行) 仍是活代码。
**UNVERIFIED**：V2 上的确切改动点需 checkout `kunminghu-v2` 后重新侦察。

**本地子模块实际状态**（`work/XiangShan/`，看起来 `make init` 已经跑过）：
`difftest`(21 项，HEAD=`99f77ff` #979，比 `work/difftest` 的 `8e9c8d7` #980 落后 1 个 commit)、`yunsuan`(9)、`rocket-chip`(24)、`XSCache`(12)、`ChiselAIA`(12)、`ChiselIOPMP`(7)、`OpenIOMMU`(10)、`utility`(4) **均已填充**；
**只有 `ready-to-run`(0 项) 是空的** —— 它也是个 submodule（`.gitmodules` → github.com/OpenXiangShan/ready-to-run），里面是 `coremark-2-iteration.bin` / `microbench.bin` / 预编译的 `riscv64-nemu-interpreter-so`，**必须 `git submodule update --init ready-to-run` 才能跑 README 的 hello world**。

**建议：立刻 `git clone -b kunminghu-v2 https://github.com/OpenXiangShan/XiangShan` 另起一份，并对 v2 做一次专门的向量后端侦察。**

### D.7 回退验证策略排名（强 → 弱）

---

#### 🥇 策略 1：全尺寸昆明湖 V2 + Verilator + NEMU difftest（理想）

- **做法**：`make emu CONFIG=DefaultConfig` + `./build/emu --diff riscv64-nemu-interpreter-so`
- **满足的赛题要求**：阶段一 ✅、阶段二 ✅、阶段三 ✅（真实 IPC / 周期数加速比、真实波形、真实 difftest）
- **不满足**：无
- **在本机可行性**：❌ **几乎不可行**。40G JVM 堆 + Verilator 对全尺寸核的峰值 RSS 远超 8 GB。
- **变通**：
  - 把 Docker Desktop 的 VM 内存从 8 GB 调到 **12–14 GB**（16 GB 物理机的上限），并开 **大 swap**（macOS 的 Docker VM 支持 swap，但会极慢）
  - 租一台云服务器（阿里云/腾讯云 32–64 GB 内存实例，按量付费几十元/天）—— **这是最务实的"保全胜"方案**

#### 🥈 策略 2：`MinimalConfig` 昆明湖 V2 + Verilator + NEMU difftest

- **做法**：`make emu CONFIG=MinimalConfig EMU_THREADS=2 WITH_CHISELDB=0 WITH_CONSTANTIN=0 -j6`
- **依据**：`work/XiangShan/README.md:133` 的官方示例就是这个；`XiangShan/.github/workflows/emu.yml:428-432` 有专门的 "Build MinimalConfig Release EMU" job
- **MinimalConfig 做了什么**（`work/XiangShan/src/main/scala/top/Configs.scala:93-...`）：缩小 L1/L2 cache（如 `:173` ICache 16KB/64set）、缩小 BPU、缩小各种队列。**核心的乱序后端和向量单元仍是完整的** ✅
- **满足**：阶段一 ✅、阶段二 ✅、阶段三 ⚠️（difftest 正确性验证完全有效；**IPC/周期数因 cache 缩小而失真**，但"vdot 版 vs RVV baseline 版"的相对加速比仍有参考价值，只要两次测量用同一 config）
- **不满足**：绝对性能数字不可用于"真实昆明湖 V2 性能"的论断
- **在本机可行性**：⚠️ **边缘可行，需实测**。瓶颈仍在 `make verilog` 的 JVM 堆。
- **必做的降配**：
  ```bash
  make sim-verilog CONFIG=MinimalConfig JVM_XMX=6G JVM_XSS=256m
  make emu CONFIG=MinimalConfig EMU_THREADS=2 WITH_CHISELDB=0 WITH_CONSTANTIN=0 \
           WITH_DRAMSIM3=0 OPT_FAST="-O1" -j4
  ```
  （`OPT_FAST=-O1` 大幅降低 g++ 编译 Verilated C++ 的内存与时间；`-j4` 而非 `-j10` 避免并行编译撑爆内存）
- **➡️ 这是推荐的"首要尝试目标"。**
- **⭐ 权威佐证**：赛题的学术源头论文 arXiv:2409.00661《基于开源矩阵指令集扩展（矢量点积）的高性能 RISC-V 处理器"香山"（南湖版本）大模型加速研究》第 5 节原文写道：
  > 「考虑到降低 FPGA 资源占用和仿真工程运行耗时，本文选用高性能处理器"香山"(nanhu 版本)的**最小配置**进行仿真，最小配置相比标准配置**减少了译码单元数量、后端执行单元数量、去除了 L2 缓存**。」

  **连拥有 S2C Prodigy S7-19PS / Xilinx VU19P FPGA 原型平台的原论文团队都选择了最小配置。** 我们用 `MinimalConfig` 完全站得住脚，评审不会扣分。详见 `vdot-semantics-research.md` §2。

#### 🥉 策略 3：gsim 代替 Verilator（本机最有希望跑通全核的路线）

- **做法**：`make gsim CONFIG=MinimalConfig`（`work/XiangShan/Makefile:404-405`）→ `make -C difftest emu GSIM=1 ...`
- **为什么值得优先试**：
  1. gsim **直接吃 CHIRRTL**（`CHISEL_TARGET=chirrtl`，`Makefile:88-90`），**跳过 firtool → SystemVerilog → Verilator 这两个最耗内存的环节**
  2. `xs-env/install-scripts/gsim.sh:20-24` **显式提供 aarch64/ARM64 预编译二进制** ✅
  3. difftest 有完整的 `gsim.mk` 支持
  4. CI 注释 `emu-basics.yml:53` 写着 "TODO: Use verilator for wave dump, switch to GSIM when ready" —— 官方正在往 gsim 迁移
- **满足**：阶段一 ✅、阶段二 ✅、阶段三 ⚠️（difftest ✅；**波形支持 UNVERIFIED**，gsim 的波形能力弱于 verilator）
- **不满足**：波形分析可能要退回 verilator 跑一小段
- **在本机可行性**：🟡 **最有希望**，但 `make sim-chirrtl` 仍要跑 mill/Chisel 精化（JVM 堆仍是瓶颈，只是省掉了 firtool 和 Verilator）
- **风险**：gsim 成熟度低于 verilator；昆明湖 V2 分支上 gsim 是否可用 **UNVERIFIED**

#### 4️⃣ 策略 4：XSPdb 预编译二进制（只能验证 baseline，不能验证我们的改动）

- `work/XiangShan/README.md:139-143`：从 GitHub Actions 的 `release.yml` artifact 下载预编译 XSPdb Python 包
- **致命缺陷**：是**预编译的官方 RTL**，不包含我们加的 vdot
- **唯一用途**：阶段一环境验证 / 熟悉香山行为 / 做 baseline 性能对照（也不准，因为版本不同）
- **架构**：release artifact 几乎肯定只有 x86_64（**UNVERIFIED**）

#### 5️⃣ 策略 5：独立功能单元级 Verilator 协同仿真（⭐ 本机最稳、性价比最高）

- **做法**：
  1. 用 Chisel 单独写 `VDotUnit`（输入 vs1/vs2/vd/vl/vm/vtype，输出 vd'），**不集成进完整核**
  2. `mill` 只精化这一个模块 → 几百行 SV（JVM 堆需求 < 2 GB）
  3. Verilator 编译这一个模块 + 一个 C++ testbench（几秒钟，内存 < 1 GB）
  4. C++ testbench 里直接 `dlopen` 我们改过的 `riscv64-nemu-interpreter-so`，或更简单地**直接链接一份从 NEMU 抽出来的 C 参考实现**
  5. 跑数百万条随机 + 定向激励（随机 vl / vstart / vm / vta / vma / 符号边界 / 溢出），逐 lane 比对
- **满足的赛题要求**：
  - 阶段一 ✅（NEMU 构建 + NutShell 冒烟测试，完整做）
  - 阶段二 ✅（RTL 设计 + NEMU 参考模型，都真实实现了）
  - 阶段三 ⚠️ **部分**：
    - "协同仿真" ✅ —— 确实是 RTL ↔ C 参考模型的差分协同仿真，机制与 difftest 同构，可以画出同样的框图
    - "评估" ⚠️ —— 可以给出 **vdot 单元的面积/时序估计**（yosys + 开源 PDK 或仅 LUT 数）、**指令数减少倍数**（静态统计：一次 vdot 替代 N 条 RVV 指令）、**理论吞吐加速比**；但**拿不到真实 IPC**
- **不满足**：没有在真实昆明湖流水线里跑过，无法证明"集成进昆明湖 V2 后不破坏正确性"，也无法给出端到端 IPC
- **在本机可行性**：✅ **完全可行**，内存需求 < 4 GB，单次迭代几分钟
- **加分补救**：即使不能跑全核仿真，**仍然要把 vdot 完整集成进 XiangShan 的 Chisel 代码并至少跑通 `make sim-verilog`（或 `sim-chirrtl`）**，证明"能精化通过"，并把 diff 作为提交物

> ### ⭐ 重要发现：YunSuan 自带的"独立功能单元 + C++ 黄金模型"验证框架
>
> 策略 5 不需要我们自己从零发明 —— **香山官方的功能单元仓库 `yunsuan`（`work/XiangShan/yunsuan/`，github.com/OpenXiangShan/YunSuan）已经内置了一套完全同构的单元级协同仿真框架**：
>
> ```
> yunsuan/
> ├── Makefile                                  # make emu [EMU_TRACE=1] → Verilator 只编译 FU，不编译整核
> ├── src/test/scala/top/VectorSimTop.scala     # 只例化若干 FU 的 SimTop
> │     trait VSPParameter { val VLEN = 128; val XLEN = 64; ... }    # ← VLEN=128，与赛题一致
> │     class VecInfoBundle { vstart(7.W), vl(8.W), vlmul(3.W), vm, ta, ma }  # ← 完整 RVV 语义接口
> │     :159-169  val vfa/vfd/via/imul/fcmp/falu/fmul/fma = Module(new ...)
> ├── src/test/csrc/golden_model/               # C++ 黄金模型（逐元素参考实现）
> │     ├── vector_integer_mac.cpp              # class VGMIntegerMAC —— VMUL/VWMUL/VMACC/VWMACC/VWMACCSU/...
> │     ├── vector_integer_alu.cpp  vector_permutation.cpp  vector_float_*.cpp
> │     └── gm_common.cpp
> ├── src/main/scala/yunsuan/vector/vectorIMAC/ # 向量整数乘加数据通路（vdot 最自然的落点）
> │     ├── VIMac.scala            99 行，**在 kunminghu-v3 分支已被整体注释掉**（v3 向量单元重构）
> │     └── VIMac64b.scala(135) / VIMac64bStage1.scala(510) / Stage2(193) / Stage3(320)  ← 仍然是活代码
> └── scripts/emu_parallel.py + log_analyse.py  # 并行跑 N 个 emu、汇总错误日志
> ```
>
> `yunsuan/README.md:4-23` 的官方用法：
> ```bash
> make emu [EMU_TRACE=1]
> ./build/emu [-C MAX_CYCLES] [-O MAX_OPERATIONS] [--dump-wave] [-b begin] [-e end]
> cd scripts && python3 emu_parallel.py 10 100 && python3 log_analyse.py
> ```
>
> **为什么这对我们极其有利**：
> 1. Verilator 只编译一个 FU（几百~几千行 SV），**内存 < 1 GB，构建 < 1 分钟**，8 GB 容器绰绰有余
> 2. `VecInfoBundle` 已经把 `vstart/vl/vlmul/vm/ta/ma` 全部建模，**RVV 的 vl/mask/tail 语义可以完整验证**
> 3. C++ golden model 的写法和 NEMU 的 `arithmetic_instr` 是同一套逻辑，**可以让 NEMU 和 golden model 共用同一份 vdot 参考实现代码**，三方（NEMU / golden model / RTL）一致
> 4. 这是**香山官方基础设施**，在答辩/评审时比自己搭的 testbench 有说服力得多
> 5. `VectorSimTop` 目前没有例化向量整数 MAC（`:159-169` 只有 vfa/vfd/via/imul/fcmp/falu/fmul/fma，`:320` 有 vperm），**我们可以按同样 pattern 新增 `VDot` 模块 + `VGMVDot` golden model**
>
> ⚠️ **UNVERIFIED**：`VIMac.scala` 在 v3 被注释掉说明 v3 的向量 MAC 已迁出 yunsuan；在 `kunminghu-v2` 分支上 `VIMac.scala` 应该是活的，需 checkout v2 后确认。

#### 6️⃣ 策略 6：纯 Chisel 单元测试（chiseltest / svsim）

- `make -C XiangShan test` / `Makefile.test`；或 difftest 自带的测试
- **满足**：阶段二部分 ✅
- **不满足**：没有"协同仿真"，没有 NEMU 参与，阶段三基本空白
- **可行性**：✅ 必然可行，但说服力最弱
- **定位**：作为策略 5 的补充（覆盖率 / 边界条件），不能单独作为交付

#### 7️⃣ 策略 7：只做 NEMU（最低保底）

- 改好 NEMU，写一个 RVV baseline 程序和一个 vdot 程序，在 **standalone NEMU**（`riscv64-xs-kmhv2_defconfig`，非 ref）里跑，比较**动态指令数**
- **满足**：阶段二的"参考模型"部分 ✅
- **不满足**：没有 RTL，没有协同仿真，**不满足赛题"硬件集成"的核心要求**
- **定位**：**必须做，但绝不能只做这个**

---

### D.8 推荐执行路线

```
第 0 步（今天）：
  ├─ git clone -b kunminghu-v2 XiangShan  → 对 V2 向量后端做专项侦察
  ├─ docker build --platform linux/arm64 -f xs-env/Dockerfile  → 自建 arm64 镜像（后台跑）
  └─ 在 arm64 容器里构建 NEMU（riscv64-xs-kmhv2-ref_defconfig）→ 验证 A.8 的可移植性结论

第 1 步（阶段一交付）：
  ├─ 容器内 source env-test.sh 流程：NEMU 构建 ✅ + NutShell make verilog/emu ✅ + microbench ✅
  └─ 截图 + 文档 → 阶段一 checkbox 打勾

第 2 步（阶段二）：
  ├─ NEMU 加 vdot.vv（按 A.5 清单，7 处改动）+ 自测
  └─ XiangShan V2 加 vdot.vv RTL（decode + 向量执行单元）
     └─ 至少跑通 make sim-verilog CONFIG=MinimalConfig JVM_XMX=6G

第 3 步（阶段三，按优先级尝试，能跑到哪算哪）：
  ├─ 先试 gsim（策略 3）：make gsim CONFIG=MinimalConfig
  ├─ 再试 MinimalConfig + verilator（策略 2），OPT_FAST=-O1 -j4
  ├─ 两者都 OOM → 落到策略 5（独立 VDotUnit + C 参考模型协同仿真），这是保底交付
  └─ 同时申请/租一台 ≥32 GB 内存的云主机，把策略 1/2 作为最终冲刺
```

**最诚实的建议：现在就去准备一台 ≥32 GB 内存的 Linux x86_64 机器（云主机按量付费即可）。** 本机 16 GB / Docker 8 GB 的配置，在 XiangShan 全核仿真面前差了一个数量级，靠优化参数填不平这个坑；而 NEMU 侧和功能单元级验证本机完全够用，应该在本机全速推进，不要浪费时间在全核构建的反复 OOM 上。
