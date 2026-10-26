# `vdot.vv` 指令语义调研报告（Part E）

> 侦察日期：2026-10-24
> 目标：在**没有拿到官方赛题语义定义图**的情况下，确定一个有权威依据、可辩护的 `vdot.vv` 规范定义。（**2026-10-26 补记**：官方语义图已经数据接口取得，复核结论见文末 §14。下文为当时的调研原文，保留不改。）
>
> 标记约定：**CONFIRMED** = 已取得一手来源并直接核对；**UNVERIFIED** = 未能直接核实；**INFERRED** = 由证据推断。

---

## 0. 执行摘要

| 问题 | 答案 |
|---|---|
| 官方语义图能找到吗？ | ❌ **不能。** `rv.cie.org.cn/direction?id=8` 是纯 JS SPA，页面正文和 `<img>` 全部由 JS 渲染，普通 HTTP 抓取只拿到 `<title>`；`/api/direction/8`、`/prod-api/direction/8` 返回同一个空壳。XiangShanLab 的 `00_大赛总览与指南/` 目录里**只有一个 `.gitkeep`**。需要真实浏览器（headless Chrome）才能取 |（**2026-10-26 更新**：已取得，是一段 8 行 Python 伪代码，见 §14）
| 赛题的**学术源头**找到了吗？ | ✅ **找到了，而且拿到了全文和编码图。** arXiv:2409.00661《基于开源矩阵指令集扩展（矢量点积）的高性能 RISC-V 处理器"香山"（南湖版本）大模型加速研究》。赛题标题几乎是这篇论文标题的昆明湖 V2 版改写 |
| RISC-V 官方标准怎么定义？ | ✅ **`Zvdot4a8i`**（原名 `Zvqdotq`），未批准（draft v0.1），已取得 spec 原文伪代码 |
| 其它参赛队怎么做的？ | 5 个公开仓库，**分裂成两派**，但都用 `funct6 = 111001` |
| 我们该实现什么？ | **可配置双模 vdot 单元**：默认走"赛题派"语义（SEW=8 全向量归约），同时提供 Zvdot4a8i 标准模式。见 §7 |

---

## 1. 官方赛题语义：找不到（明确结论）

### 1.1 已确认的赛题信息（CONFIRMED）

来源：`work/XiangShanLab/2026-CIE-RISC-V-Contest-Application-Track/README.md` 与 `SUBMISSION_GUIDE.md`（本地克隆，内容已抓取；该目录侦察后期被删除/重新克隆）

| 项目 | 内容 |
|---|---|
| 赛事 | 第二届 CIE 全国 RISC-V 高水平创新及应用大赛 |
| 赛道 | 应用方向 → **CIE-香山社区 RISC-V 应用创新赛道** |
| 赛题全称 | **面向边缘AI大语言模型推理的RISC-V自定义vdot指令设计 — 基于"香山"昆明湖V2处理器架构** |
| **官方赛题页** | **https://rv.cie.org.cn/direction?id=8** ← 语义图在这里 |
| 承办 | 中电新一代（北京）信息技术研究院有限公司 |
| 赛程 | 报名 2026-06-30→11-08；格式审查/预赛 11-09→11-27；选拔赛 11-30→12-18；总决赛 2027 年 1 月中旬（线下） |
| 开发平台 | `github.com/OpenXiangShan/xs-env`、`github.com/OpenXiangShan/XiangShanLab` |
| 三阶段 | 阶段一 环境部署与验证 / 阶段二 vdot设计与实现 / 阶段三 协同仿真与评估 |
| 提交方式 | 公开仓库 `cie2026-团队名-作品名` + GPG 加密的 `submission.asc` + 向 XiangShanLab 发 PR |

赛事主页：https://www.cie.org.cn/list_43/16315.html

### 1.2 检索到的赛题正文片段（CONFIRMED，来自中文搜索快照）

> 「复用香山现有向量实现，新增一条自定义向量点积指令 **vdot.vv（SEW=8, VLEN=128）**，在处理器流水线中集成专用硬件加速单元，以极小面积开销换取数倍点积吞吐提升」

**这段话里没有逐元素公式。** 公式只在那张图里。

### 1.3 XiangShanLab 全库检索（CONFIRMED）

`grep -ril "vdot"` 的全部命中：赛题 README、SUBMISSION_GUIDE、PR 模板、`xiangshan-course/docs/8-xiangshan-AI/.../parallel_strategies.md`（AI 并行策略，非指令定义）、两份题库。
> ✅ **XiangShanLab 中不存在任何 vdot 指令的语义定义文档。**

### 1.4 取图的下一步（必须做）

- 用 headless Chrome / Playwright 渲染 `https://rv.cie.org.cn/direction?id=8`，抓 DOM 里的 `<img src>`
- 或者在普通浏览器里打开该页，F12 → Network → 过滤 `Img`，复制图片 URL
- 或者直接问主办方/在 XiangShanLab 提 issue

---

## 2. ⭐ 赛题的学术源头：Nanhu-vdot 论文（CONFIRMED，已取得全文 + 编码图）

### 2.1 文献信息

- **标题**：《基于开源矩阵指令集扩展（矢量点积）的高性能 RISC-V 处理器"香山"（南湖版本）大模型加速研究》
  （英文：*Research on LLM Acceleration Using the High-Performance RISC-V Processor "Xiangshan" (Nanhu Version) Based on the Open-Source Matrix Instruction Set Extension (Vector Dot Product)*）
- **作者**：Xu-Hao Chen, Si-Peng Hu, Hong-Chao Liu, Bo-Ran Liu, Dan Tang, Di Zhao
- **arXiv**：**2409.00661**（2024-09），10 页，中文
  - 摘要页 https://arxiv.org/abs/2409.00661
  - PDF **https://arxiv.org/pdf/2409.00661** ← 已下载并用 `pdftotext` / `pdfimages` 完整提取
- **赛题与论文的关系**：赛题标题 = 论文标题把"南湖"换成"昆明湖V2"、把"矩阵指令集扩展（矢量点积）"换成"自定义vdot指令"。**几乎可以断定赛题就是这篇论文的续作命题。**

### 2.2 论文中 VDOTU 指令的编码（CONFIRMED —— 直接读取论文图 4 的位图）

从 PDF 第 5 页抽出图 4「矢量点积计算指令编码格式」，内容为：

```
 31          25 24     20 19     15 14   12 11    7 6         0
+--------------+---------+---------+-------+-------+-----------+
|   0000000    |   rs2   |   rs1   |  000  |  rd   |  0001011  |
+--------------+---------+---------+-------+-------+-----------+
     funct7                          funct3           opcode
                                                    (custom-0)
```

论文正文（§4.2）原话：
> 「矢量点积操作采用 RISC-V 指令的 **R-type** 译码模式，Inst[11:7] 表示……目的寄存器号，Inst[19:15] 和 Inst[24:20] 表示源操作数寄存器号……**0001011** 的后缀在 RISC-V 中通常用于自定义指令（**custom-0** 指令）。」

> 🔴 **关键：论文的 VDOTU 用的是通用寄存器（GPR）+ custom-0 opcode，不是向量寄存器。** 赛题把它改成了 `vdot.vv`（OP-V 的 `.vv` 形式），这是赛题相对论文的**主要演进点**。

### 2.3 论文中 VDOTU 的数据通路（CONFIRMED —— 读取论文图 3 位图 + 正文）

论文 §3.2 原话：
> 「VDOTU 是扩展指令的核心执行单元，采用 **SIMD 向量化**的执行方式。VDOTU 默认配置为 **8bit 的整形计算**，VDOTU 包含**八路 8-bit 乘法器和七个加法器**。输出采用 **64-bit**，与处理器的通用寄存器大小一致。」

图 3「VDOTU 执行模块结构」画的是：
```
Source Register1 ─┐
                  ├─→ Source Data ─→ ┌──────── Integer Multiplier ────────┐
Source Register2 ─┘                  │ [×][×][×][×][×][×][×][×]  (8 路)   │
                                     │   \ /    \ /    \ /    \ /         │
                                     │   (+)    (+)    (+)    (+)   4 个   │
                                     │     \    /        \    /           │
                                     │      (+)           (+)       2 个   │
                                     │         \         /                │
                                     │            (+)               1 个   │
                                     └─────────────┬──────────────────────┘
                                                   ↓
                                                Result            （共 7 个加法器）
```

**语义（INFERRED，由图 3 + 图 4 + 算法 1 三者一致推出）**：
```c
// vdotu rd, rs1, rs2      (R-type, funct7=0000000, funct3=000, opcode=0001011)
int64_t sum = 0;
for (int i = 0; i < 8; i++)
    sum += (int32_t)(int8_t)(rs1 >> (8*i)) * (int32_t)(int8_t)(rs2 >> (8*i));
rd = sum;        // 非累加：直接覆盖 rd
```
→ **8 路 int8 乘法 → 加法树 → 单个标量结果，不累加。**

### 2.4 论文的软件用法（CONFIRMED，§4.3 算法 1 原文）

> 输入：两个包含 **32 个 int8** 元素的数据块 X 和 Y
> 步骤 1：把 X 每 32 个数存入 **4 个通用寄存器** xi，每个寄存器存 **8 个 int8**
> 步骤 2：把 Y 同样存入 4 个寄存器 yi
> 步骤 3：xi 与 yi 作为源寄存器，通过混合汇编调用自定义指令，**由扩展加速单元计算完成 4 个点积结果**
> 步骤 4：**由软件执行 4 个点积结果累加**，并转换数据类型

→ 证实：**一条指令 = 8 对 int8 的点积 = 1 个标量；累加由软件做。**

### 2.5 论文的实测结果（CONFIRMED，可作为我们报告的对标数据）

| 指标 | 香山 nanhu | nanhu-vdot | 变化 |
|---|---|---|---|
| LUT | 564211 | 579888 | **+15677 (+2.8%)** |
| Flip-Flop | 278746 | 281232 | **+2486** |
| 功耗 | 8.454 W | 8.494 W | **+0.04 W (+0.47%)** |
| 50000 次矢量点积耗时 | 99.96 (单位见原文) | — | **矢量点积提速 >4×** |
| GPT-2 推理 | — | — | **约快 30%** |

论文还说明：「考虑到降低 FPGA 资源占用和仿真工程运行耗时，本文选用高性能处理器"香山"(nanhu 版本)的**最小配置**进行仿真，最小配置相比标准配置**减少了译码单元数量、后端执行单元数量、去除了 L2 缓存**。」
> 📌 **这正是 `MinimalConfig`。连原论文作者（有 S2C VU19P FPGA 原型机！）都选择最小配置。这是我们在 `nemu-difftest-env.md` Part D 推荐 `MinimalConfig` 的有力佐证，评审一定能接受。**

实验平台：上海思尔芯 (S2C) Prodigy™ S7-19PS Logic System（Xilinx VU19P），Vivado 2020.2。

---

## 3. RISC-V `Zvdot4a8i`（原 `Zvqdotq`）标准草案（CONFIRMED，取得 spec 原文）

### 3.1 状态与出处

- **改名**：`Zvqdotq` → **`Zvdot4a8i`**（Vector 4-element Dot Product accumulate of packed 8-bit Integers）；指令 `vqdot*` → **`vdot4a*`**
- **未批准（UNRATIFIED）**，draft **v0.1**，JIRA 跟踪 ticket **RVS-1971**（https://jira.riscv.org）
- 当前 spec 归宿：**riscv-isa-manual PR #2576**（open，未合入；Andrew Waterman 已 review "looks good"），新增 `src/unpriv/vector-dot.adoc`
  - PR：https://github.com/riscv/riscv-isa-manual/pull/2576
  - **spec 原文（本报告伪代码的来源）**：https://raw.githubusercontent.com/nibrunieAtSi5/riscv-isa-manual/zvdot/src/unpriv/vector-dot.adoc （fork `nibrunieAtSi5/riscv-isa-manual`，branch `zvdot`，sha `3d50c477bbe862b7ab9666772cd69a3a2d53d622`）
- 旧的独立仓库（`Zvqdotq` 命名，v0.0.2）：https://github.com/riscv/riscv-dot-product
  - https://raw.githubusercontent.com/riscv/riscv-dot-product/main/vector-dot-product-zvqdotq.adoc
  - https://raw.githubusercontent.com/riscv/riscv-dot-product/main/vector-dot-product-inst-table.adoc
- 前身提案：SiFive Dot-Product Extension v0.0.1 (2023-09-20)，https://lists.riscv.org/g/sig-vector/attachment/116/0/sifive-vector-dot-product.pdf （HTTP 402，未取到）
- 科普综述：https://fprox.substack.com/p/risc-v-vector-is-expanding
- ⚠️ `github.com/riscv/riscv-zvqdotq` **不存在**（404）

### 3.2 编码（CONFIRMED —— spec 与 QEMU 解码表交叉验证）

opcode = `1010111` (0x57, OP-V)。funct3：`.vv` = `010`(OPMVV)，`.vx` = `110`(OPMVX)。

| 新名 | 旧名 | funct6 | `.vv` funct3 | `.vx` funct3 |
|---|---|---|---|---|
| `vdot4a.vv/.vx`（s×s） | `vqdot` | **`101100`** | `010` | `110` |
| `vdot4au.vv/.vx`（u×u） | `vqdotu` | **`101000`** | `010` | `110` |
| `vdot4asu.vv/.vx`（vs2 有符号 × vs1/rs1 无符号） | `vqdotsu` | **`101010`** | `010` | `110` |
| `vdot4aus.vx`（**仅 .vx**，vs2 无符号 × rs1 有符号） | `vqdotus` | **`101110`** | — | `110` |

QEMU `target/riscv/insn32.decode` 原文：
```
vqdot_vv    101100 . ..... ..... 010 ..... 1010111 @r_vm
vqdot_vx    101100 . ..... ..... 110 ..... 1010111 @r_vm
vqdotu_vv   101000 . ..... ..... 010 ..... 1010111 @r_vm
vqdotu_vx   101000 . ..... ..... 110 ..... 1010111 @r_vm
vqdotsu_vv  101010 . ..... ..... 010 ..... 1010111 @r_vm
vqdotsu_vx  101010 . ..... ..... 110 ..... 1010111 @r_vm
vqdotus_vx  101110 . ..... ..... 110 ..... 1010111 @r_vm
```
来源：https://www.mail-archive.com/qemu-devel/msg1136908.html (RFC v4)、http://www.mail-archive.com/qemu-devel@nongnu.org/msg1160694.html (v5, 2026-01)、series index https://ratatoskr.run/qemu-devel/2026/01/14417608/t

> 💡 **这 4 个 funct6（`101000/101010/101100/101110`）正好是 OPMVV 里 `vmadd(101001)/vnmsub(101011)/vmacc(101101)/vnmsac(101111)` 的偶数邻居** —— 和我们在 `nemu-difftest-env.md` §4.2 从 NEMU 译码表独立算出的 OPMVV 空位完全吻合（CONFIRMED，本地核对 `work/NEMU/src/isa/riscv64/instr/rvv/decode.h:318-370`）。

> ⚠️ **不要用的旧编码**：LLVM 早期实验性 commit `1ac489c8e38e`（PR #137039, 2025）里 `VQDOTU_VX = 0b101001`，与现行 spec 和 QEMU **不一致，已过时**。

### 3.3 规则（CONFIRMED）

- 要求 **`SEW == 32`**，其它 SEW 值 **reserved** → 非法指令
- 依赖 **`Zve32x`**
- `vs2`/`vs1` 的每个 32-bit 元素是 **4 个 8-bit 子元素**的打包；`vd` 的同下标 32-bit 元素是**累加器（读—改—写）**
- **累加进 `vd`**，`vd` 既是源又是目的
- 掩码粒度是 **32-bit 元素**（每个 32-bit 结果一个 mask bit，不是每字节一个）
- 溢出**回绕**，不饱和。8-bit 输入 → 32-bit 累加器（"quad-widening"）

### 3.4 ⭐ VERBATIM 伪代码（逐字引自 `src/unpriv/vector-dot.adoc`，branch `zvdot`，CC-BY-4.0）

```
// vdot4a.vv  (signed x signed, vector-vector)
foreach (i from vstart to vl-1) {
  let {a0 @ a1 @ a2 @ a3} : bits (4*(SEW/4)) = get_velem(vs2, i)
  let {b0 @ b1 @ b2 @ b3} : bits (4*(SEW/4)) = get_velem(vs1, i)
  let acc : bits (SEW) = get_velem(vd, i);
  let res : bits (SEW) = sign_extend(a0) * sign_extend(b0)
                       + sign_extend(a1) * sign_extend(b1)
                       + sign_extend(a2) * sign_extend(b2)
                       + sign_extend(a3) * sign_extend(b3)
                       + acc;
  set_velem(vd, i, res);
}

// vdot4a.vx  (signed x signed, vector-scalar)
foreach (i from vstart to vl-1) {
  let {a0 @ a1 @ a2 @ a3} : bits (4*(SEW/4)) = get_velem(vs2, i)
  let {b0 @ b1 @ b2 @ b3} : bits (4*(SEW/4)) = zext_or_truncate_to_sew(X(rs1));
  let acc : bits (SEW) = get_velem(vd, i);
  let res : bits (SEW) = sign_extend(a0) * sign_extend(b0)
                       + sign_extend(a1) * sign_extend(b1)
                       + sign_extend(a2) * sign_extend(b2)
                       + sign_extend(a3) * sign_extend(b3)
                       + acc;
  set_velem(vd, i, res);
}

// vdot4au.vv  (unsigned x unsigned)
foreach (i from vstart to vl-1) {
  let {a0 @ a1 @ a2 @ a3} : bits (4*(SEW/4)) = get_velem(vs2, i)
  let {b0 @ b1 @ b2 @ b3} : bits (4*(SEW/4)) = get_velem(vs1, i)
  let acc : bits (SEW) = get_velem(vd, i);
  let res : bits (SEW) = zero_extend(a0) * zero_extend(b0)
                       + zero_extend(a1) * zero_extend(b1)
                       + zero_extend(a2) * zero_extend(b2)
                       + zero_extend(a3) * zero_extend(b3)
                       + acc;
  set_velem(vd, i, res);
}

// vdot4asu.vv  (vs2 signed x vs1 unsigned)
foreach (i from vstart to vl-1) {
  let {a0 @ a1 @ a2 @ a3} : bits (4*(SEW/4)) = get_velem(vs2, i)
  let {b0 @ b1 @ b2 @ b3} : bits (4*(SEW/4)) = get_velem(vs1, i)
  let acc : bits (SEW) = get_velem(vd, i);
  let res : bits (SEW) = sign_extend(a0) * zero_extend(b0)
                       + sign_extend(a1) * zero_extend(b1)
                       + sign_extend(a2) * zero_extend(b2)
                       + sign_extend(a3) * zero_extend(b3)
                       + acc;
  set_velem(vd, i, res);
}

// vdot4aus.vx  (vs2 unsigned x rs1 signed, scalar only)
foreach (i from vstart to vl-1) {
  let {a0 @ a1 @ a2 @ a3} : bits (4*(SEW/4)) = get_velem(vs2, i)
  let {b0 @ b1 @ b2 @ b3} : bits (4*(SEW/4)) = zext_or_truncate_to_sew(X(rs1));
  let acc : bits (SEW) = get_velem(vd, i);
  let res : bits (SEW) = zero_extend(a0) * sign_extend(b0)
                       + zero_extend(a1) * sign_extend(b1)
                       + zero_extend(a2) * sign_extend(b2)
                       + zero_extend(a3) * sign_extend(b3)
                       + acc;
  set_velem(vd, i, res);
}
```

> 注：spec 写成通用的 `SEW/4` 位子元素，是为了将来复用到 16-bit（SEW=64）和 4-bit 变体；**对 `Zvdot4a8i` 而言 SEW 固定为 32，子元素就是 8 位**。
> `{a0 @ a1 @ a2 @ a3}` 是 Sail 的 MSB-first 位拼接，即 `a3` 是最低字节、`a0` 是最高字节 —— 但因为 4 个乘积要相加，**字节顺序对结果无影响**。
> 没有 `vdot4aus.vv`：把 `vdot4asu.vv` 的 `vs2`/`vs1` 对调即可，不值得占一个编码。

QEMU `vector_helper.c` 的参考实现（证实"累加"）：
```c
for (idx = 0; idx < 4; ++idx) {
    T1 r1 = ((T1 *)r1_buf)[HS1(idx)];
    T2 r2 = ((T2 *)r2_buf)[HS2(idx)];
    acc += (TD)r1 * (TD)r2;
}
((TD *)vd)[HD(i)] = acc;
```

### 3.5 容易混淆的同族提案（不要搞错）

- `rv_zvqwbdota8i`（未批准，riscv-opcodes）：`vqwbdotau.vv` funct6 `0x2e`、`vqwbdotas.vv` funct6 `0x2f`，funct3=0，**opcode `0x77`**，用 `vs2x8` 寄存器组的**块点积**。https://github.com/riscv/riscv-opcodes/pull/437
- `rv_zvfbdota32f` / `rv_zvfwbdota16bf` / `rv_zvfqwbdota8f`：同族的浮点版本
- VMXDOTP（MX / microscaling 格式）：学术提案 https://arxiv.org/pdf/2603.04979

---

## 4. 其它参赛队的公开仓库（5 个，分裂成两派）

所有这些都是**各队自己的重构，不是官方语义**（UNVERIFIED）。

### 派别 A —— 对齐 RISC-V 标准（SEW=32，4×4 lane，累加）

| 仓库 | 要点 |
|---|---|
| **https://github.com/redoop/xiangshan-vdot** | 扩展名 `Xkhmvdot`。**`funct6=111001`，`funct3=010`(OPMVV)，`opcode=1010111`**。SEW 必须 e32，否则非法指令。`vd[j] += Σ_{i=0..3} sext8(vs1[j][i]) × sext8(vs2[j][i])` mod 2³²，继承 RVV 的 mask/tail/vstart/异常语义。**自述"semantically aligned with official RISC-V Zvdot4a8i"**。目前最完整的一份：NEMU/Spike/RTL **三方 difftest 280/280**，63 项 riscv-tests，VFEX0 里 2 周期流水的 64-bit 点积核，宣称**指令数降 12.7×、GEMM 周期加速 ~8.2×、核面积 +0.014%** |

### 派别 B —— 贴近赛题字面（SEW=8，8 lane，不累加，结果塞进 vd[31:0]）

| 仓库 | 要点 |
|---|---|
| **https://github.com/Jade0x13157A6/cie2026-xiangshan-vdot** | `vd[31:0] = Σ_{i=0..7} vs2[i]×vs1[i]; vd[127:32] = 0`。SEW=8，LMUL=1，signed int8 → signed int32，**无掩码支持**。给出示例编码 `.word 0xe61101d7` 对应 `vdot.vv v3, v1, v2`。宣称相对标量 C 快 3.03×，76/76 测试通过 |
| **https://github.com/vienna-0FFH/cie2026-shishui-vdot** | 同样 8 lane 归约到 `vd[31:0]`、`vd[127:32]=0`，要求 `vm=1` 且 `vstart=0`。4 周期弹性流水，8 个有符号乘法器 + 加法树。文档在 `vdot/README.md`、`vdot/docs/design.md`、`vdot/integration/README.md`。注明最大幅值 8×128×128 = 131072 可放进 32 位 |

### 仅阶段一 / 无语义

- https://github.com/juese12/cie2026-skito-SKIProject
- https://github.com/mmm-arch/cie2026-01-xiangshan-vdot
- https://github.com/wsyZZ182/cie2026-Z-riscv-xs
- https://github.com/OpenXiangShan/XiangShanLab/pull/113 （零一队，阶段一波形提交，无 vdot 语义）

### ⭐ 4.1 我独立复核了派别 B 的示例编码（CONFIRMED）

对 `0xe61101d7` 做位域拆解：

```
word          = 0xe61101d7
opcode[6:0]   = 0b1010111   (0x57 = OP-V)        ✅ 向量指令，不是论文的 custom-0
vd    [11:7]  = v3
funct3[14:12] = 0b000       (OPIVV)              ← 派别 B 选 OPIVV
vs1   [19:15] = v2
vs2   [24:20] = v1
vm    [25]    = 1
funct6[31:26] = 0b111001                         ← 关键
```

并且核对本地 NEMU 译码表：`grep '"111001' work/NEMU/src/isa/riscv64/instr/rvv/decode.h` **无任何命中** —— `funct6 = 111001` 在 OPIVV / OPMVV / OPIVX / OPMVX **全部表里都是空位**（RVV 1.0 里 OPMVV 的 `111000=vwmulu`、`111010=vwmulsu`、`111011=vwmul`，`111001` 确实未分配）。

### 4.2 从分歧中能推出什么（INFERRED）

| 观察 | 推论 |
|---|---|
| **三个队（两派）都独立选了 `funct6 = 111001`** | 这个值**极可能直接印在官方语义图上**。纯巧合的概率很低 —— 空位有十几个，大家都挑同一个很反常。**强烈建议我们也用 `111001`** |（**2026-10-26 更正**：该推断不成立。官方语义图只是一段 Python 伪代码，**图上没有任何编码信息**，funct6 / funct3 / opcode 都没有，见 §14。三队收敛到 `111001` 的原因无法从官方材料得到解释，本项目选它的依据只剩 OPIVV 空闲性证明。）
| 派别 B 的 **8 lane** 之前"无法解释" | **现在解释清楚了**：论文 §3.2 的 VDOTU 就是**八路 8-bit 乘法器 + 七个加法器**（§2.3 的图 3）。官方语义图**很可能直接复用了论文的图 3**，所以是 8 路 |（**2026-10-26 补记**：官方图确为 8 路——伪代码 `for i in range(8)`，但形式是伪代码而非论文的结构图，见 §14。）
| 派别 B **不累加**、结果是**单个标量** | 同样来自论文：论文的 VDOTU 输出 64-bit 单结果，**累加由软件做**（§2.4 算法 1 步骤 4） |
| 派别 B 选 `funct3 = 000` (OPIVV) | 一个不熟 RVV 内部约定的人画编码图时，"整数向量-向量"最直觉的 funct3 就是 `000`。两队都读成 `000`，也支持"图上写的就是 000" |（**2026-10-26 更正**：官方图上没有 funct3，见 §14。）
| 派别 A（redoop）自述是"对齐标准"而非"对齐赛题" | redoop **主动偏离了赛题字面**去追标准。这说明 redoop 看到的官方语义**也不是** Zvdot4a8i，否则不需要特意声明"aligned with" |

> 🔑 **综合结论（INFERRED，置信度中高）**：官方语义图大概率是**论文 Nanhu-vdot 的 VDOTU（8 路 int8 乘法 → 加法树 → 单标量，不累加）改画成 RVV `.vv` 编码**，`funct6 = 111001`，`funct3` 很可能是 `000`。（**2026-10-26 复核**：语义部分（8 路 int8 有符号乘积 → 单标量、不累加）得到证实，且官方要求 `vd` 其余位清零；编码部分（funct6 / funct3）不成立，官方图上没有编码信息。见 §14。）

---

## 5. 横向对照：ARM / x86 / 其它 RISC-V 厂商

### 5.1 ARM SDOT / UDOT（AArch64 NEON）— CONFIRMED

- Armv8.2-A 可选（FEAT_DotProd），**Armv8.4-A 起强制**
- `SDOT Vd.4S, Vn.16B, Vm.16B`：4 个 int32 lane，每个 lane 做 **4 路 int8 点积**并**累加进 `Vd` 原值**。另有 `Vd.2S, Vn.8B, Vm.8B`（Q=0）
- 带索引形式 `SDOT Vd.4S, Vn.16B, Vm.4B[index]` 广播一组 4 字节
- `UDOT` = 无符号×无符号；`USDOT`（无符号×有符号，FEAT_I8MM）
- **ARM ARM 伪代码原文**：
```
AArch64_CheckFPAdvSIMDEnabled();
operand1 = V(n);
operand2 = V(m);
result   = V(d);

for e = 0 to elements-1 do
  res = 0;
  for i = 0 to 3 do
    element1 = SInt(operand1[(4*e + i)*:(esize DIV 4)]);
    element2 = SInt(operand2[(4*e + i)*:(esize DIV 4)]);
    res = res + element1 * element2;
  end;
  result[e*:esize] = result[e*:esize] + res;
end;

V(d) = result;
```
（`result` 初值取自 `V(d)` ⇒ **累加**，结构与 Zvdot4a8i 完全同构）
- 编码：bit31=0, bit30=Q, 29-28=`00`, 27-25=`111`, bit24=0, 23-22=size, bit21=0, 20-16=Rm, 15-14=`10`, 13-11=`010`, 10-5=Rn, 4-0=Rd
- URL：https://www.scs.stanford.edu/~zyedidia/arm64/sdot_advsimd_vec.html ・ https://support.arm.com/documentation/ddi0602/latest/SIMD-FP-Instructions/SDOT--vector---Dot-product-signed-arithmetic--vector-- ・ intrinsics `vdotq_s32`/`vdotq_u32` https://arm-software.github.io/acle/neon_intrinsics/advsimd.html ・ 科普 https://developer.arm.com/community/arm-community-blogs/b/tools-software-ides-blog/posts/exploring-the-arm-dot-product-instructions

### 5.2 ARM SVE/SVE2 SDOT/UDOT

语义相同、向量可伸缩：`SDOT Zda.S, Zn.B, Zm.B`（4 路 int8→int32 累加进 `Zda`）、`SDOT Zda.D, Zn.H, Zm.H`（4 路 int16→int64）。目的寄存器 `Zda` 是破坏性/累加的。

### 5.3 ARM SMMLA / UMMLA / USMMLA（FEAT_I8MM）— 简述

`SMMLA Vd.4S, Vn.16B, Vm.16B`：**2×8 int8 矩阵 × 8×2 int8 矩阵**，2×2 的 int32 乘积**破坏性累加**进 `Vd`。等价于**每个目的元素 8 路点积** —— 32 MAC/指令，**SDOT 的 2 倍**。Armv8.2→8.5 可选，**Armv8.6-A 起强制**，`ID_AA64ISAR1_EL1.I8MM` 探测。
URL：https://www.scs.stanford.edu/~zyedidia/arm64/smmla_advsimd_vec.html ・ https://support.arm.com/documentation/109697/2026_09/Feature-descriptions/ ・ LLVM https://reviews.llvm.org/D77871

### 5.4 x86 VPDPBUSD（AVX512-VNNI / AVX-VNNI）— CONFIRMED，Intel SDM 伪代码原文

**无符号 × 有符号**（SRC1 字节无符号，SRC2 字节有符号）—— 正好匹配量化神经网络的布局（u8 激活 × s8 权重）。每个 dword lane 4 个字节，乘积为 16 位中间值，求和后**累加进目的 dword**。

```
VPDPBUSD (VEX encoded)
VL=(128, 256)
KL=VL/32
ORIGDEST := DEST
FOR i := 0 TO KL-1:
    p1word := ZERO_EXTEND(SRC1.byte[4*i+0]) * SIGN_EXTEND(SRC2.byte[4*i+0])
    p2word := ZERO_EXTEND(SRC1.byte[4*i+1]) * SIGN_EXTEND(SRC2.byte[4*i+1])
    p3word := ZERO_EXTEND(SRC1.byte[4*i+2]) * SIGN_EXTEND(SRC2.byte[4*i+2])
    p4word := ZERO_EXTEND(SRC1.byte[4*i+3]) * SIGN_EXTEND(SRC2.byte[4*i+3])
    DEST.dword[i] := ORIGDEST.dword[i] + p1word + p2word + p3word + p4word
DEST[MAX_VL-1:VL] := 0
```
```
VPDPBUSD (EVEX encoded)
(KL,VL)=(4,128), (8,256), (16,512)
ORIGDEST := DEST
FOR i := 0 TO KL-1:
    IF k1[i] or *no writemask*:
        IF SRC2 is memory and EVEX.b == 1:  t := SRC2.dword[0]
        ELSE:                                t := SRC2.dword[i]
        p1word := ZERO_EXTEND(SRC1.byte[4*i])   * SIGN_EXTEND(t.byte[0])
        p2word := ZERO_EXTEND(SRC1.byte[4*i+1]) * SIGN_EXTEND(t.byte[1])
        p3word := ZERO_EXTEND(SRC1.byte[4*i+2]) * SIGN_EXTEND(t.byte[2])
        p4word := ZERO_EXTEND(SRC1.byte[4*i+3]) * SIGN_EXTEND(t.byte[3])
        DEST.dword[i] := ORIGDEST.dword[i] + p1word + p2word + p3word + p4word
    ELSE IF *zeroing*:  DEST.dword[i] := 0
    ELSE:               DEST.dword[i] := ORIGDEST.dword[i]
DEST[MAX_VL-1:VL] := 0
```
兄弟指令：`VPDPBUSDS`（饱和）、`VPDPWSSD`/`VPDPWSSDS`（int16 对）。intrinsic `_mm512_dpbusd_epi32`。典型 ~5 周期延迟、亚周期吞吐。
URL：https://www.felixcloutier.com/x86/vpdpbusd ・ https://en.wikichip.org/wiki/x86/avx512_vnni ・ https://www.intel.com/content/www/us/en/developer/articles/guide/deep-learning-with-avx512-and-dl-boost.html

### 5.5 T-Head XTheadVdot（玄铁）— CONFIRMED

仓库 https://github.com/XUANTIE-RV/thead-extension-spec（旧 URL `T-head-Semi/thead-extension-spec` 会跳转），目录 `xtheadvdot/`，文件 `vmaqa_vv.adoc` / `vmaqa_vx.adoc` / `vmaqau_*.adoc` / `vmaqasu_*.adoc` / `vmaqaus_vx.adoc`。
raw：`https://raw.githubusercontent.com/XUANTIE-RV/thead-extension-spec/master/xtheadvdot/vmaqa_vv.adoc`
已在 C906/C908/C910/C920 实现；LLVM 扩展名 `XTHeadVdot` v1.0.0，助记符前缀 `th.`。

**`th.vmaqa.vv vd, vs1, vs2`** —— "Four signed 8-bit multiply with 32-bit add"：
```
vd[i] = vd[i] + vs1[i][7:0]   * vs2[i][7:0]
              + vs1[i][15:8]  * vs2[i][15:8]
              + vs1[i][23:16] * vs2[i][23:16]
              + vs1[i][31:24] * vs2[i][31:24]
```
编码：`opcode[6:0]=0x0b`（**custom-0**，不是 OP-V）、`vd[11:7]`、`funct3[14:12]=0x6`、`vs1[19:15]`、`vs2[24:20]`、`vm[25]`、`funct6[31:26]=0x20`。

**`th.vmaqasu.vx vd, rs1, vs2`** —— "Four signed-unsigned 8-bit multiply with 32-bit add"：
```
vd[i] = vd[i] + rs1[7:0]   * vs2[i][7:0]
              + rs1[15:8]  * vs2[i][15:8]
              + rs1[23:16] * vs2[i][23:16]
              + rs1[31:24] * vs2[i][31:24]
```
编码：`opcode=0x0b`、`funct3=0x6`、`rs1[19:15]`、`vs2[24:20]`、`vm[25]`、`funct6[31:26]=0x25`。

**UNVERIFIED**：`vmaqau.*` / `vmaqaus.vx` / `vmaqa.vx` / `vmaqasu.vv` 的确切 funct6 未逐一取证（只直接确认了 `0x20` 和 `0x25`，其余应在 `0x20..0x25` 邻近）。
**特别注意**：XTheadVdot 的**掩码是 8 位粒度**，而 `vl` 数的是 32-bit 目的元素 —— 与 Zvdot4a8i（32-bit 元素粒度掩码）**不同**。

### 5.6 其它 RISC-V 厂商（来自 https://llvm.org/docs/RISCVUsage.html）

| 扩展 | 厂商 | 版本 | 前缀 |
|---|---|---|---|
| `XAndesVDot` | Andes | 5.0.0 | `nds.` |
| `XSfvqmaccdod` / `XSfvqmaccqoq`（int8 矩阵乘） | SiFive | 1.1.0 | `sf.` |
| `XTHeadVdot` | T-Head / 阿里 | 1.0.0 | `th.` |
| `XSmtVdotII`（IME 子集，X60 / A100） | SpacemiT 进迭时空 | 1.0.0 | `smt.` |
| `Zvdot4a8i` | RISC-V International | 0.1 draft | —（LLVM experimental） |

### 5.7 一张表看完所有先例

| | 每个结果的 lane 数 | 输入类型 | 累加进目的？ | 累加宽度 | 结果形态 |
|---|---|---|---|---|---|
| RISC-V `vdot4a.vv` | 4 × int8 | s×s, u×u, s×u, u×s | **是**（`vd`） | 32-bit | 向量（每 32-bit 元素一个） |
| ARM `SDOT`/`UDOT` | 4 × int8 | s×s, u×u（+`USDOT` u×s） | **是**（`Vd`） | 32-bit | 向量 |
| ARM `SMMLA` | 8 × int8（2×8·8×2 矩阵） | s×s | **是**（破坏性） | 32-bit | 向量 |
| x86 `VPDPBUSD` | 4 × int8 | **仅 u×s** | **是** | 32-bit | 向量 |
| T-Head `th.vmaqa.vv` | 4 × int8 | s×s, u×u, s×u, u×s | **是**（`vd`） | 32-bit | 向量 |
| **论文 Nanhu-vdot `vdotu`** | **8 × int8** | s×s | **否** | 64-bit | **单标量（GPR）** |
| 赛题派别 B 重构 | 8 × int8 | s×s | 否 | 32-bit | 单标量（`vd[31:0]`） |

> **工业界的 6 个先例无一例外都是"4 路 × 向量化 × 累加"。论文（也就是赛题的源头）是"8 路 × 单标量 × 不累加"，是个异类。** 这个矛盾正是我们设计决策的核心。

---

## 6. 本地 NEMU 编码空间核对（CONFIRMED）

逐行核对 `work/NEMU/src/isa/riscv64/instr/rvv/decode.h`。

**OPIVV（funct3=`000`，`decode.h:167-212`）空闲 funct6**：
`000011, 001000, 001101, 001111, 010110, 011110, 011111, 100100, 100110, 110010, 110011, 110100, 110110, 110111`，以及**整行 `111000`–`111111`**。
→ ✅ **`111001` 空闲**

**OPMVV（funct3=`010`，`decode.h:318-370`）空闲 funct6**：
`001100, 001101, 001110, 001111, 010001, 010011, 010101, 010110,` **`101000, 101010, 101100, 101110`**（= Zvdot4a8i 的 4 个编码，全部空闲 ✅）`, 111001, 111110`
→ ✅ **`111001` 空闲**

**历史遗留线索**：`work/NEMU/src/isa/riscv64/instr/rvv/vcompute_impl.h:45` 的 `enum op_t` 里有两个从未被任何 `case` 使用的枚举值：
```c
  NCLIPU, NCLIP, WREDSUMU, WREDSUM, DOTU, DOT, WSMACCU, WSMACC,
```
`DOTU` / `DOT` 是 **RVV 0.7.1/0.8 草案时代 `vdotu.vv` / `vdot.vv` 的残留**，RVV 1.0 批准时被删除但 NEMU 保留了名字。
→ 我们可以**直接复用 `DOT` 枚举名**，减少 diff；也说明 "vdot" 这个名字在 RISC-V 历史上确实指过点积指令。

---

## 7. ⭐ 推荐方案：可配置双模 `vdot.vv`

### 7.1 为什么不能二选一

| 方案 | 风险 |
|---|---|
| 只做 Zvdot4a8i（SEW=32，4 路，累加） | 若官方图是 8/16 路标量归约 → **不符合赛题**，分数大幅受损 |
| 只做 8 路标量归约 | 若官方图其实是标准对齐 → 同样不符合；而且语义"反 RVV 惯例"，被评审质疑设计水平 |

**两种语义共用同一个 16 路 int8 乘法器阵列，只是加法树的抽头和写回方式不同。** 增量成本极小（NEMU 多一个 `case`，RTL 多一组 mux），收益是**彻底消除语义不确定性风险**，同时成为报告里的一个设计亮点。

### 7.2 硬件结构（一套乘法器，两种归约）

```
vs1 (128b) ──┐
             ├──→ 16 × int8×int8 乘法器 ──→ 16 个 int16 乘积 p0..p15
vs2 (128b) ──┘                                      │
                                    ┌───────────────┴───────────────┐
                                    ↓                               ↓
                          ┌─ 模式 DOT4（标准对齐）─┐     ┌─ 模式 DOTR（赛题派）──┐
                          │ 4 棵独立 3 加法器树    │     │ 1 棵 15 加法器全树      │
                          │ s0=p0..3  s1=p4..7     │     │ S = Σ p0..p15           │
                          │ s2=p8..11 s3=p12..15   │     │ （按 vl 掩掉多余 lane） │
                          │ vd.u32[j] += sj        │     │ vd.u32[0] = S           │
                          │ （4 个 int32 累加器）   │     │ vd[127:32] = 0          │
                          └────────────────────────┘     └─────────────────────────┘
```
> 模式 DOTR 下取 `vl=8` 即可**精确复现论文 Nanhu-vdot 的 8 路行为**；取 `vl=16` 是 VLEN=128 的自然满幅形态。

### 7.3 编码（统一）

```
 31    26  25  24    20 19    15 14  12 11   7 6      0
+--------+----+--------+--------+------+------+--------+
| funct6 | vm |   vs2  |   vs1  |funct3|  vd  | opcode |
+--------+----+--------+--------+------+------+--------+
  111001    ?   vs2[4:0] vs1[4:0]  ???   vd[4:0] 1010111
```

| 字段 | 取值 | 理由 |
|---|---|---|
| `opcode[6:0]` | `1010111` (0x57, OP-V) | 赛题写 `vdot.vv` = RVV 的 `.vv` 形式 |
| **`funct6[31:26]`** | **`111001`** | **三个参赛队独立收敛到同一个值，极可能来自官方图**；本地核对在 NEMU 所有 vop 表里都空闲（CONFIRMED） |（2026-10-26 更正：官方图上没有编码信息，见 §14）
| `funct3[14:12]` | **主用 `000` (OPIVV)**，同时译码 `010` (OPMVV) 作为备选 | 派别 B（2 队）读成 `000`，派别 A（1 队）读成 `010`。**两个都译码，零成本消除分歧** |
| `vm[25]` | `0`/`1` | `1`=无掩码；`0`=用 v0 掩码 |

**GNU as 写法（不认识这条指令，必须 `.insn`）**：
```gas
# vdot.vv vd, vs2, vs1, vm     （OPIVV 形式，funct3=0）
.macro vdot_vv vd, vs2, vs1, vm=1
  .insn r 0x57, 0x0, (0b111001 << 1) | \vm, \vd, \vs1, \vs2
.endm

# 校验：vdot.vv v3, v1, v2, vm=1  应该等于 0xe61101d7
```
> ⚠️ `.insn r` 的 `rs1`/`rs2` 对应指令的 `[19:15]`/`[24:20]`，即 **`rs1`←vs1、`rs2`←vs2**，与汇编书写顺序 `vd, vs2, vs1` 相反，极易写反。写完务必 `objdump -d` 核对机器码。

### 7.4 规范定义 —— 模式 DOTR（**默认**，赛题派 / 论文派）

```c
/* ============================================================
 * vdot.vv  vd, vs2, vs1, vm        ——  模式 DOTR（默认）
 *   vtype.vsew == 0 (SEW=8)，VLEN=128，EMUL(vs1)=EMUL(vs2)=LMUL
 *   语义：对 vs1/vs2 的前 vl 个 int8 元素做点积，结果写入 vd 的第 0 个 32-bit 元素
 * ============================================================ */

/* 前置检查 */
require(vtype.vill == 0);
require(mstatus.VS != Off);
require(vtype.vsew == 0b000);              // 必须 SEW=8，否则 Illegal Instruction
require_aligned(vd, LMUL); require_aligned(vs1, LMUL); require_aligned(vs2, LMUL);

int64_t sum = 0;                            // 不累加：以 0 为初值
for (i = vstart; i < vl; i++) {
    if (vm == 0 && v0.mask[i] == 0) continue;          // 掩码：8-bit 元素粒度，masked-off 跳过
    int32_t a = (int8_t)vs1.u8[i];                     // 有符号 int8
    int32_t b = (int8_t)vs2.u8[i];                     // 有符号 int8
    sum += a * b;                                      // 在 int32 下累加（最坏 16×128×128 = 262144，远未溢出）
}

if (vl != 0) {
    vd.u32[0] = (uint32_t)(int32_t)sum;                // 结果写第 0 个 32-bit 元素
    if (vtype.vta) {                                   // tail-agnostic：其余写全 1
        for (j = 1; j < VLEN/32; j++) vd.u32[j] = ~0u;
    }
    /* vtype.vta == 0（tail-undisturbed）：vd[VLEN-1:32] 保持原值 */
}
/* vl == 0：vd 完全不写（与 vredsum 一致） */

vstart = 0;
mstatus.VS = Dirty;
```

**与派别 B 的差异及理由**：
| 项 | 派别 B（2 队） | 我们 | 理由 |
|---|---|---|---|
| lane 数 | 硬编码 8 | **由 `vl` 决定（≤16）** | `vl=8` 时与派别 B / 论文完全一致；RVV 语义要求 `vl` 可变。**我们的是超集** |
| 掩码 | 不支持 | **支持** | RVV 规范要求；difftest 会测 |
| `vd[127:32]` | 恒置 0 | **按 `vta` 策略**（`vta=1`→全 1，`vta=0`→不变） | 与 `vredsum` 一致。若官方确为"置 0"，改 1 行 |（**2026-10-26**：官方确为清零，已按此修订为裁定 S-3'，见 §14）
| `vstart` | 必须为 0 | **支持任意 vstart** | RVV 规范要求；允许被中断后恢复 |

> 📌 为什么选"归约（reduction）"而不是"逐元素"：`vl`/`vta` 的行为完全照抄 RVV 的 `vredsum.vs`，在 NEMU 里可以直接套用 `reduction_instr` 的框架（`work/NEMU/src/isa/riscv64/instr/rvv/vcompute_impl.c:1529`），工作量最小且语义最不容易出错。

### 7.5 规范定义 —— 模式 DOT4（标准对齐，`Zvdot4a8i` 语义）

```c
/* ============================================================
 * vdot.vv  vd, vs2, vs1, vm        ——  模式 DOT4（可选，标准对齐）
 *   vtype.vsew == 2 (SEW=32)，每个 32-bit 元素含 4 个 int8
 *   语义 == RISC-V Zvdot4a8i 的 vdot4a.vv（见 §3.4）
 * ============================================================ */
require(vtype.vsew == 0b010);               // 必须 SEW=32

for (i = vstart; i < vl; i++) {
    if (vm == 0 && v0.mask[i] == 0) {       // 掩码：32-bit 元素粒度
        if (vtype.vma) vd.u32[i] = ~0u;
        continue;
    }
    uint32_t a = vs1.u32[i], b = vs2.u32[i];
    int32_t acc = (int32_t)vd.u32[i];       // ★ 累加：以 vd 原值为初值
    for (k = 0; k < 4; k++)
        acc += (int32_t)(int8_t)((a >> (8*k)) & 0xFF)
             * (int32_t)(int8_t)((b >> (8*k)) & 0xFF);
    vd.u32[i] = (uint32_t)acc;              // 32 位回绕，不饱和，不置 vxsat
}
if (vtype.vta) for (i = max(vl,vstart); i < VLMAX; i++) vd.u32[i] = ~0u;
vstart = 0;
mstatus.VS = Dirty;
```

### 7.6 两种模式如何共存

**最优雅的方案：用 `vtype.vsew` 本身区分模式**，不需要额外的 CSR 或编码位：

| `vtype.vsew` | 模式 | 语义 |
|---|---|---|
| `0b000` (SEW=8) | **DOTR** | 全向量归约 → `vd.u32[0]`，不累加（赛题派 / 论文派） |
| `0b010` (SEW=32) | **DOT4** | 4 组 4 路 → `vd.u32[i] +=`（Zvdot4a8i 标准） |
| `0b001` / `0b011` | — | Illegal Instruction |

这样：
- 赛题要求的 `vdot.vv (SEW=8, VLEN=128)` → 自动走 DOTR ✅
- 跑标准 Zvdot4a8i 测试向量时 `vsetvli e32` → 自动走 DOT4 ✅
- **编码完全统一，不占额外 funct6** ✅
- 在报告里是一个很漂亮的设计点："同一条指令按 `vtype.vsew` 自适应两种点积形态，既满足赛题又对齐 RISC-V 标准草案"

### 7.7 共享参考实现（三方一致的关键）

把参考语义写成**一个独立的 C 文件**，同时被 NEMU、yunsuan C++ 黄金模型、以及测试程序引用：

```c
/* work/NEMU/src/isa/riscv64/instr/rvv/vdot.h  （也软链给 yunsuan golden model 用） */
#include <stdint.h>

/* 模式 DOTR：n 个 int8 对的点积（n = 有效 lane 数，调用方按 vl + mask 筛好） */
static inline int32_t vdot_reduce_s8(const int8_t *a, const int8_t *b, int n) {
    int32_t s = 0;
    for (int i = 0; i < n; i++) s += (int32_t)a[i] * (int32_t)b[i];
    return s;
}

/* 模式 DOT4：单个 32-bit 元素的 4 路点积 + 累加 */
static inline uint32_t vdot4a_elem_s8(uint32_t a, uint32_t b, uint32_t acc) {
    int32_t r = (int32_t)acc;
    for (int k = 0; k < 4; k++)
        r += (int32_t)(int8_t)((a >> (8*k)) & 0xFF)
           * (int32_t)(int8_t)((b >> (8*k)) & 0xFF);
    return (uint32_t)r;
}
```
语义一旦调整只改这一处，NEMU / 黄金模型 / 测试自动保持一致。

---

## 8. 基线（baseline）：用现有 RVV 指令实现同一功能

**NEMU 已实现以下全部指令**（逐行核对 `decode.h`）：

| 指令 | funct3 / funct6 | decode.h 行号 |
|---|---|---|
| `vwmul.vv` | OPMVV `111011` | `:367` |
| `vwmulu.vv` | OPMVV `111000` | `:365` |
| `vwmacc.vv` | OPMVV `111101` | `:369` |
| `vmacc.vv` | OPMVV `101101` | `:354` |
| `vwredsum.vs` | OPIVV `110001` | `:207` |
| `vwredsumu.vs` | OPIVV `110000` | `:206` |
| `vredsum.vs` | OPMVV `000000` | `:318` |
| `vsext.vf4` | OPMVV `010010`+vs1=`00101` | `:79` |
| `vzext.vf4` | OPMVV `010010`+vs1=`00100` | `:78` |

### 8.1 Baseline —— int8 向量点积（与模式 DOTR 等价）

```gas
# sum = Σ a[i]*b[i]，a/b 为 int8 数组，长度 n。a0=n, a1=&a, a2=&b
    vsetvli     t0, x0, e32, m1, ta, ma
    vmv.v.i     v8, 0                   # int32 累加器
loop:
    vsetvli     t0, a0, e8, m1, ta, ma  # t0 ≤ 16
    vle8.v      v1, (a1)
    vle8.v      v2, (a2)
    vwmul.vv    v4, v1, v2              # 16×int16 乘积（EMUL=2）
    vsetvli     x0, x0, e16, m2, ta, ma
    vwredsum.vs v8, v4, v8              # int16→int32 串行归约，累加进 v8[0]
    add         a1, a1, t0
    add         a2, a2, t0
    sub         a0, a0, t0
    bnez        a0, loop
    vsetvli     x0, x0, e32, m1, ta, ma
    vmv.x.s     a0, v8
```
**内循环：6 条向量指令 + 4 条标量指令。** 瓶颈是 `vwredsum.vs` —— RVV 的归约是**串行**的，在香山上是多拍非流水操作。

### 8.2 vdot 版本（模式 DOTR）

```gas
    li          t1, 0
loop:
    vsetvli     t0, a0, e8, m1, ta, ma
    vle8.v      v1, (a1)
    vle8.v      v2, (a2)
    vdot.vv     v8, v2, v1              # ← 一条指令：16 路 int8 点积 → v8[0]
    vsetvli     x0, x0, e32, m1, ta, ma
    vmv.x.s     t2, v8
    add         t1, t1, t2              # 标量累加（与论文算法 1 步骤 4 一致）
    add         a1, a1, t0
    add         a2, a2, t0
    sub         a0, a0, t0
    bnez        a0, loop
    mv          a0, t1
```
**内循环：4 条向量 + 6 条标量**（多了 `vmv.x.s` 和标量加）。

### 8.3 vdot 版本（模式 DOT4，性能最优 —— 推荐用这个做加速比）

```gas
    vsetvli     x0, x0, e32, m1, ta, ma
    vmv.v.i     v8, 0                   # 4 个 int32 累加器
loop:
    vsetvli     t0, a0, e32, m1, ta, ma # t0 = 32-bit 元素数（每个含 4 个 int8）
    vle32.v     v1, (a1)
    vle32.v     v2, (a2)
    vdot.vv     v8, v2, v1              # ← 16 次 int8 MAC，直接累加进 v8，循环内无归约
    sh2add      a1, t0, a1
    sh2add      a2, t0, a2
    sub         a0, a0, t0
    bnez        a0, loop
    vredsum.vs  v16, v8, v16            # ★ 归约只在循环外做一次
    vmv.x.s     a0, v16
```
**内循环：3 条向量 + 4 条标量，且循环内彻底消除了串行归约。**

### 8.4 加速比论证要点

| 对比维度 | Baseline (§8.1) | vdot DOT4 (§8.3) | 收益 |
|---|---|---|---|
| 内循环向量指令数 | 6 | **3** | **2×** |
| 内循环 `vsetvli` 次数 | 2（e8↔e16 切换） | **1** | 消除 vtype 切换开销（香山上 vsetvli 可能触发流水线阻塞） |
| 内循环串行归约 | 每次迭代 1 次 `vwredsum.vs` | **0**（移到循环外） | **主要收益来源** |
| 寄存器压力 | `vwmul` 产生 EMUL=2 的 `v4:v5` | 无中间加宽结果 | 更少寄存器 |
| 每条向量指令的 int8 MAC 数 | `vwmul` 16 次乘（但还要归约） | **16 次 MAC 一次完成** | — |

> 📌 **把"消除内循环串行归约"作为报告里性能论证的核心论点**，而不是单纯数指令条数 —— 这才是真正的微架构洞见，评审会认。
> 📌 对照数据：论文 Nanhu-vdot 实测矢量点积 **>4×**、GPT-2 推理 **~30%**；redoop 队宣称指令数 **12.7×**、GEMM 周期 **~8.2×**。我们的数字落在这个区间内才可信。

---

## 9. 映射到 NEMU 的实现

### 9.1 模式 DOTR —— 套 `reduction_instr` 的框架

`work/NEMU/src/isa/riscv64/instr/rvv/vcompute_impl.c:1529` 的 `reduction_instr` 结构（vs1[0] 作初值、逐元素掩码、只写 vd[0]、`vta` 处理、`vstart=0`）与模式 DOTR 几乎完全一致。建议**复制一份改成 `vdot_reduce_instr()`**：

```c
/* work/NEMU/src/isa/riscv64/instr/rvv/vcompute_impl.c 末尾新增 */
void vdot_reduce_instr(Decode *s) {
  require_vector(true);
  if (vtype->vsew != 0) longjmp_exception(EX_II);     // 必须 SEW=8
  double vflmul = compute_vflmul();
  if (vflmul > 1) {
    require_aligned(id_dest->reg, vflmul);
    require_aligned(id_src ->reg, vflmul);
    require_aligned(id_src2->reg, vflmul);
  }
  check_vstart_exception(s);
  if (check_vstart_ignore(s)) { vp_set_dirty(); return; }

  int64_t sum = 0;
  for (word_t idx = vstart->val; idx < vl->val; idx++) {
    if (s->vm == 0 && get_mask(0, idx) == 0) continue;
    get_vreg(id_src ->reg, idx, s1, 0 /*EEW=8*/, vtype->vlmul, 1 /*signed*/, 1);
    get_vreg(id_src2->reg, idx, s0, 0 /*EEW=8*/, vtype->vlmul, 1 /*signed*/, 1);
    sum += (int64_t)(int8_t)(uint8_t)*s1 * (int64_t)(int8_t)(uint8_t)*s0;
  }

  if (vl->val != 0) {
    *s1 = (uint64_t)(uint32_t)(int32_t)sum;
    set_vreg(id_dest->reg, 0, *s1, 2 /*EEW=32*/, vtype->vlmul, 0);
    if (RVV_AGNOSTIC && vtype->vta) {
      for (int j = 1; j < VLEN/32; j++) {
        *s1 = (uint64_t)-1;
        set_vreg(id_dest->reg, j, *s1, 2, vtype->vlmul, 0);
      }
    }
  }
  vstart->val = 0;
  vp_set_dirty();
}
```
> `get_vreg(reg, idx, dst, vsew=0, ...)` 会自动按 8-bit 元素跨寄存器组寻址（`vreg_impl.c:113-124` 的 `get_reg`/`get_idx`），`set_vreg(..., vsew=2, ...)` 自动按 32-bit 元素写 —— **EEW 不一致完全不是问题**。

### 9.2 模式 DOT4 —— 直接套 `arithmetic_instr`

因为 EEW(vd)=EEW(vs1)=EEW(vs2)=32，可以只在 `arithmetic_instr` 的大 `switch` 里加一个 `case`（`case MACC:` 在 `vcompute_impl.c:762`）：
```c
      case DOT : {                                     /* 复用 enum op_t 里遗留的 DOT */
        uint32_t a = (uint32_t)*s1, b = (uint32_t)*s0;
        get_vreg(id_dest->reg, idx, s2, vtype->vsew, vtype->vlmul, 0, 1);
        int32_t acc = (int32_t)(uint32_t)*s2;
        for (int k = 0; k < 4; k++)
          acc += (int32_t)(int8_t)((a >> (8*k)) & 0xFF)
               * (int32_t)(int8_t)((b >> (8*k)) & 0xFF);
        *s1 = (uint64_t)(uint32_t)acc;
        break;
      }
```
`vl`/`vstart`/`vm`/`vta`/`vma` 全部由框架自动处理（见 `nemu-difftest-env.md` §A.3）。

### 9.3 EHelper 与译码

```c
/* vcompute.h，放在 vmacc (:868) 附近 */
#ifdef CONFIG_CUSTOM_XVDOT
def_EHelper(vdot_vv) {
  require_vector(true);
  switch (vtype->vsew) {
    case 0: vdot_reduce_instr(s);  break;    /* SEW=8  → 模式 DOTR（赛题默认） */
    case 2: ARITH(DOT, UNSIGNED)   break;    /* SEW=32 → 模式 DOT4（Zvdot4a8i） */
    default: longjmp_exception(EX_II);
  }
}
#endif
```
```c
/* decode.h：两个 funct3 都挂上，消除派别分歧 */
/* vopivv 表（decode.h:163-215），放在 vwredsum (:207) 之后 */
#ifdef CONFIG_CUSTOM_XVDOT
  def_INSTR_TAB("111001 ? ????? ????? ??? ????? ????? ??", vdot_vv);
#endif
/* vopmvv 表（decode.h:314-373），放在 vwmulu (:365) 之前 */
#ifdef CONFIG_CUSTOM_XVDOT
  def_INSTR_TAB("111001 ? ????? ????? ??? ????? ????? ??", vdot_vv);
#endif
```

完整的 7 处改动清单见 `nemu-difftest-env.md` §A.5（Kconfig / isa-all-instr.h / decode.h / vcompute.h / vcompute_impl.h / vcompute_impl.c / defconfig）。

---

## 10. 若拿到官方图后发现不一致，怎么快速改

| 官方实际语义 | 我们要改的地方 | 工作量 |
|---|---|---|
| lane 数固定 8（而非由 `vl` 决定） | 在 `vdot_reduce_instr` 里把循环上界改成 `min(vl, 8)` | **1 行** |
| `vd[127:32]` 必须置 0（而非 `vta` 策略） | 把 tail 循环的 `-1` 改成 `0`，并去掉 `vta` 判断 | **2 行** |
| 结果是 64-bit 写 `vd[63:0]` | `set_vreg(..., EEW=3, ...)` | **1 行** |
| **累加**（`vd[0] += Σ`） | 把 `int64_t sum = 0;` 改成先 `get_vreg(vd, 0, …)` | **2 行** |
| funct3 只认 `010`（或只认 `000`） | 删掉 `decode.h` 里另一张表的那行 | **1 行** |
| funct6 不是 `111001` | 改 `decode.h` 的模式串 + 汇编 `.macro` | **2 行** |
| 无符号 / 混合符号变体 | 各占一个 funct6 空位（OPMVV 的 `101000/101010/101110`） | 中等 |
| 饱和（置 `vxsat`） | `case` 里加饱和判断；注意 `CONFIG_DIFFTEST_CHECK_VCSR=y` 会让 difftest 比对 `vxsat` | 中等 |
| 完全是 GPR + custom-0（论文原样） | 换一条 R-type 指令路径，不走 RVV 框架 | **大**（但赛题明写 `.vv`，概率很低） |

**所有"小改"都集中在 §7.7 的共享参考实现 + 2 个 NEMU 函数里**，这正是推荐把语义抽成独立 C 函数的原因。

---

## 11. CONFIRMED / UNVERIFIED 总表

### CONFIRMED（已取得一手来源并直接核对）
- ✅ `Zvdot4a8i` 全部 5 条指令的 spec 伪代码原文（来自 PR #2576 分支的 `.adoc`）
- ✅ `Zvdot4a8i` funct6（`101100`/`101000`/`101010`/`101110`）、funct3（`010` OPMVV / `110` OPMVX）、opcode `1010111` —— spec 与 QEMU `insn32.decode` 交叉验证
- ✅ `Zvdot4a8i` 要求 SEW=32、依赖 Zve32x、**累加进 `vd`**、32-bit 元素粒度掩码
- ✅ `Zvdot4a8i` 状态：**UNRATIFIED**，draft v0.1，PR #2576 open，JIRA RVS-1971
- ✅ **arXiv:2409.00661 Nanhu-vdot 论文全文**，含图 3（8 乘法器 + 7 加法器结构）和图 4（R-type / funct7=0000000 / funct3=000 / opcode=0001011 custom-0）的位图内容，以及算法 1 和 FPGA 实测数据
- ✅ ARM SDOT 的 ARM-ARM 伪代码与编码
- ✅ x86 VPDPBUSD 的 Intel SDM 伪代码（VEX + EVEX 两版）
- ✅ T-Head `th.vmaqa.vv`（funct6 `0x20`）、`th.vmaqasu.vx`（funct6 `0x25`），opcode `0x0b`
- ✅ 5 个参赛队公开仓库的存在与内容
- ✅ `0xe61101d7` 的位域拆解（funct6=`111001`, funct3=`000`, vm=1, vs2=v1, vs1=v2, vd=v3, opcode=0x57）—— 本报告独立复核
- ✅ `funct6 = 111001` 在 NEMU 所有 vop 译码表里均未使用（`grep '"111001' decode.h` 无命中）
- ✅ NEMU OPIVV / OPMVV 的完整空闲 funct6 列表
- ✅ 赛事日程、赛道、提交机制、开发平台 URL

### UNVERIFIED / 未找到
- ❌ **官方 vdot.vv 语义图** —— `rv.cie.org.cn` 是 JS SPA，XiangShanLab 的 `00_大赛总览与指南/` 只有 `.gitkeep`。**必须用真实浏览器取**（**2026-10-26 已取得**，经数据接口而非浏览器，见 §14）
- ❌ T-Head `vmaqau.*` / `vmaqaus.vx` / `vmaqa.vx` / `vmaqasu.vv` 的确切 funct6（只直接确认了 `0x20` 和 `0x25`）
- ❌ SiFive 原始 dot-product 提案 PDF（lists.riscv.org 返回 HTTP 402）
- ❌ 任何 2024/2025 届 CIE 大赛获奖作品的技术报告（首届公告 https://www.cie.org.cn/list_43/15303.html ，但没有公开的获奖技术文档）
- ⚠️ `funct6 = 111001` 是否真的来自官方图 —— 只能说三队独立收敛，**强烈暗示但未证实**
- ⚠️ 官方 funct3 是 `000` 还是 `010` —— 两派分歧。**我们的方案两个都译码，规避风险**
- ⚠️ LLVM commit `1ac489c8e38e` 的 funct6 值**已过时**，不要用

---

## 12. 参考资料索引

**官方赛事**
- 赛事主页 https://www.cie.org.cn/list_43/16315.html
- **赛题页（含语义图）https://rv.cie.org.cn/direction?id=8**
- 首届赛事公告 https://www.cie.org.cn/list_43/15303.html
- XiangShanLab 赛题 README https://raw.githubusercontent.com/OpenXiangShan/XiangShanLab/master/2026-CIE-RISC-V-Contest-Application-Track/README.md
- 提交指南 https://raw.githubusercontent.com/OpenXiangShan/XiangShanLab/master/2026-CIE-RISC-V-Contest-Application-Track/SUBMISSION_GUIDE.md
- ⚠️ XiangShanLab 默认分支是 **`master`**，`main` 的 URL 会 404

**赛题源头论文**
- **arXiv:2409.00661** https://arxiv.org/abs/2409.00661 ・ PDF https://arxiv.org/pdf/2409.00661 ・ ADS https://ui.adsabs.harvard.edu/abs/2024arXiv240900661C/abstract

**RISC-V Zvdot4a8i**
- riscv-isa-manual PR #2576 https://github.com/riscv/riscv-isa-manual/pull/2576
- spec 原文 https://raw.githubusercontent.com/nibrunieAtSi5/riscv-isa-manual/zvdot/src/unpriv/vector-dot.adoc
- 旧仓库 https://github.com/riscv/riscv-dot-product
- QEMU 实现 https://www.mail-archive.com/qemu-devel/msg1136908.html ・ http://www.mail-archive.com/qemu-devel@nongnu.org/msg1160694.html
- 综述 https://fprox.substack.com/p/risc-v-vector-is-expanding
- 同族块点积提案 https://github.com/riscv/riscv-opcodes/pull/437

**其它 ISA**
- ARM SDOT https://www.scs.stanford.edu/~zyedidia/arm64/sdot_advsimd_vec.html
- ARM SMMLA https://www.scs.stanford.edu/~zyedidia/arm64/smmla_advsimd_vec.html
- ARM ACE/ACLE intrinsics https://arm-software.github.io/acle/neon_intrinsics/advsimd.html
- x86 VPDPBUSD https://www.felixcloutier.com/x86/vpdpbusd ・ https://en.wikichip.org/wiki/x86/avx512_vnni
- T-Head XTheadVdot https://github.com/XUANTIE-RV/thead-extension-spec
- LLVM RISC-V 厂商扩展一览 https://llvm.org/docs/RISCVUsage.html

**参赛队公开仓库**
- https://github.com/redoop/xiangshan-vdot （最完整，派别 A）
- https://github.com/Jade0x13157A6/cie2026-xiangshan-vdot （派别 B）
- https://github.com/vienna-0FFH/cie2026-shishui-vdot （派别 B）
- https://github.com/juese12/cie2026-skito-SKIProject ・ https://github.com/mmm-arch/cie2026-01-xiangshan-vdot ・ https://github.com/wsyZZ182/cie2026-Z-riscv-xs
- https://github.com/OpenXiangShan/XiangShanLab/pull/113

**香山 / NEMU / difftest 工具链**
- DiffTest 官方文档 https://docs.xiangshan.cc/zh-cn/latest/tools/difftest/
- NEMU 官方文档 https://docs.xiangshan.cc/zh-cn/latest/tools/nemu/
- 新 NEMU 临时使用指南 https://github.com/OpenXiangShan/NEMU/wiki/%E6%96%B0NEMU%E4%B8%B4%E6%97%B6%E4%BD%BF%E7%94%A8%E6%8C%87%E5%8D%97
- 香山工具详解：difftest 应用及配合波形检验 https://blog.csdn.net/weixin_41953023/article/details/136500965
- NEMU DiffTest 基本原理 https://blog.csdn.net/zyhse/article/details/140371014
- Difftest 踩坑笔记(一) https://icfgblog.com/index.php/software/340.html
- XiangShan Design Doc https://github.com/OpenXiangShan/XiangShan-Design-Doc
- HPCA'25 香山 tutorial https://tutorial.xiangshan.cc/hpca25/slides/20250302-HPCA25-1-Introduction-XiangShan.pdf

**相关学术工作（自定义 RVV 指令 + 微架构集成方法论）**
- IndexMAC（结构化稀疏矩阵乘的自定义 RVV 指令）https://arxiv.org/pdf/2311.07241
- Saturn Vector Unit 指令调度 https://arxiv.org/pdf/2412.00997
- 为可重构 SIMD 扩展 RISC-V ISA https://arxiv.org/pdf/2106.07456

---

## 13. 待办

- [ ] **用 headless Chrome 取 https://rv.cie.org.cn/direction?id=8 的语义图**（最高优先级）（**2026-10-26 已完成**：改用数据接口取得，见 §14）
- [ ] 读完 arXiv:2409.00661 的参考文献，看有无后续的昆明湖版论文
- [ ] 逐一拉取 `thead-extension-spec/xtheadvdot/*.adoc` 补全 T-Head funct6 表
- [ ] 把 §7.7 的共享参考实现落到 `work/NEMU/src/isa/riscv64/instr/rvv/vdot.h`
- [ ] checkout `kunminghu-v2` 确认 RTL 落点（`yunsuan/src/main/scala/yunsuan/vector/vectorIMAC/`）
- [ ] 联系主办方 / 在 XiangShanLab 开 issue 索取语义的文字版

---

## 14. 赛题页面复核（2026-10-26）

### 14.1 取图路径

* 赛题页 https://rv.cie.org.cn/direction?id=8 是 Vue 单页应用，正文与图片都由前端脚本渲染，直接抓 HTML 只能拿到空壳（与 §1 的记录一致）。
* 前端渲染所用的数据来自接口 `https://api.rv.cie.org.cn/api/subject/index?race_id=8`，其返回的赛题正文中引用了语义图：
  `https://api.rv.cie.org.cn/storage/ueditor/20260615/bc72c5ea-d0b4-4f962e3cdd5feb916af2db486c8ec14c4353eb302.png`
  （路径中的 `20260615` 是上传目录名）。
* 访问日期：2026-10-26。
* 存档：取回的图片原样（未作任何修改）保存为 `docs/_recon/figures/vdot_official_semantics.jpg`，
  sha256 `4d255095d1e327010354c3cb50afd2f283f07f14784d9734f249c344cf3b1a6c`（66723 字节，691×268 JPEG；服务器上的文件名后缀为 `.png`，实际内容是 JPEG）。
  `target.md:19` 的 `bc72c5ea-d0b4-45aa-961f-9c11eb1caeda.png` 即同一张图在赛题正文中的文件名。

### 14.2 语义图转录（逐字，行号为图上行号）

```python
1  def vdot_vv(vs1, vs2, sew=8):
2      # 根据SEW设定，从两个源向量寄存器中各取8个int8数据
3      result = 0
4      for i in range(8):
5          result += sign_extend(vs1[i]) * sign_extend(vs2[i])
6      # 结果写入目标向量寄存器vd的第一个元素
7      vd[0] = result
8      vd[1..VLEN-1] = 0  # 其他通道清零
```

图上**只有**这段伪代码：没有编码位域图，没有 funct6 / funct3 / opcode，也没有 vl、vm、vstart、vta/vma、LMUL 的规定。

### 14.3 与本报告推断的对照

| 本报告的推断 | 位置 | 复核结论 |
|---|---|---|
| 官方语义是「8 路 int8 乘法 → 单标量，不累加」，源自论文 VDOTU | §4.2、§4 综合结论 | **证实**：伪代码 `for i in range(8)`、`result` 为单值、不读 `vd` |
| 结果写 `vd[31:0]`（派别 B 的读法） | §4 派别 B | **证实**：`vd[0] = result` |
| `vd[127:32]` 置 0（派别 B）还是按 `vta`（§7.4 我们的选择） | §7.4 表、§10 | **官方为清零**：`vd[1..VLEN-1] = 0`。本项目据此把原裁定 S-3（按 `vta`）修订为 S-3'（恒清零，与 `vta`/`vma` 无关），见 `docs/_plan/MASTER_PLAN.md` D2.4 |
| `funct6 = 111001`「极可能印在官方语义图上」 | §4.2 表第 1 行（`:337`） | **不成立**：图上没有任何编码信息。三个参赛队收敛到 `111001` 的原因无法从官方材料得到解释；本项目沿用 `111001` 的依据是 OPIVV 空闲性证明（`docs/stage2/10_vdot指令设计文档.md` §2） |
| `funct3 = 000`「图上写的就是 000」 | §4.2 表第 4 行（`:340`） | **不成立**：图上没有 funct3。本项目选 OPIVV 的理由见设计文档 §9 R-02 |
| 官方图「很可能直接复用论文图 3」 | §4.2 表第 2 行（`:338`） | **部分成立**：路数（8）一致，但官方给的是伪代码而不是结构图 |

### 14.4 对本项目语义的影响

* 主体语义不变：8 个 int8 有符号乘积求和、结果写目的寄存器元素 0（按 32 位计）、不累加。本项目的 `vdot.vv` 在 `vl=8`、`vm=1`、`vstart=0` 时与伪代码逐位等价（`tests/golden/check_official_pseudocode.py`，20570 条 0 失配，`logs/stage2/p3_official_pseudocode_equiv.log:40`）。
* 唯一修订：目的寄存器其余位由「按 `vta` 作 tail」改为「恒清零」（裁定 S-3'）。理由与先例见 `docs/stage2/10_vdot指令设计文档.md` §1 开头「赛题官方语义与逐行对照」。
* 伪代码没有规定的 vl / vm / vstart / LMUL 仍按本项目的工程化裁定（S-1、S-2、S-4、S-5、S-6、S-7'）处理；`vdotacc.vv`、`vdot4a.vv` 是本项目的扩展指令，不在官方伪代码范围内。
