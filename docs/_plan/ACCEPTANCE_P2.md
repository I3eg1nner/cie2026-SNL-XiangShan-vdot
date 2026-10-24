# 阶段二（赛题 2.1 / 2.2 / 2.3.1 / 2.3.2 / 2.3.3）独立验收审计报告

| 项 | 值 |
|---|---|
| 审计对象 | P2 设计文档、P3 RTL 实现、P4 三项基础功能测试 |
| 审计依据 | `docs/_plan/MASTER_PLAN.md` P2（8 条）/ P3（6 条）/ P4（6 条）验收标准、D2 / D2.1 / D2.3、执行纪律第 2 节 |
| 审计方式 | **全部结论由审计者本人在本机实际执行得到**；未采信任何文档自述数字 |
| 审计时间 | 2026-10-24 22:03 – 22:4x CST |
| 审计者立场 | 独立验收，未参与任何建设工作；目标是**证伪**而非确认 |
| 对工作树的影响 | `logs/stage2/` 在重跑后已逐字节还原；`work/XiangShan-vdot` 两次临时改源码后均已按 md5 校验还原并重建干净产物；`work/XiangShan-kmhv2`、`work/XiangShan-cosim`、`work/NEMU` 未写入 |

> **排除项（按任务约定不作为新发现）**：D2.3 裁定 S-7'（`vdot4a` 在 `vstart != 0` 时改判非法）尚未传播到
> 设计文档 §1.5.2/§1.5.3、测试报告 §5.3/§12 第 3 条与参考模型/语料。该不一致为已知待办，不计入本报告问题清单。

---

## 0. 总评

阶段二的交付质量**显著高于阶段一**。阶段一审计发现的两类典型缺陷——伪造的日志引用、与 VCD 矛盾的波形数字——
在本阶段**基本没有重现**：我逐条复核的 12 个波形数值全部能在 VCD 里原样取到；约 40 处 `文件:行号` 引用
全部命中（阶段一的错误率是 20%）。一键脚本真实幂等，汇总表与存档逐字节一致。

仍存在 4 个**重要**问题，其中一个属于阶段一同类（**声称有日志、实际日志里没有**），必须整改。

| 维度 | 判定 |
|---|---|
| 真实性（日志/波形/数据是否来自真实执行） | **通过**，1 处例外（§问题 I-1） |
| 可复现性 | **通过**，优于文档自述（见 §复现记录） |
| 证据完备性 | **部分通过**（缺波形截图、缺反向验证日志） |
| 交付物自洽性 | **部分通过**（`rtl/chisel/` 副本陈旧） |
| 诚实性（估算 vs 实测、局限性披露） | **基本通过**，1 处循环论证未披露（§问题 I-4） |

---

## 1. P2 验收标准（设计文档，8 条）

| # | 验收标准 | 判定 | 审计者亲自取得的证据 |
|---|---|---|---|
| 1 | 指令语义完整规范（编码位域图、伪代码、vstart/vl/vm/vta/vma 行为表、溢出分析） | **PASS** | `10_vdot指令设计文档.md` §1.0–1.6 齐全。我手工按位域复算三条机器码：`111001 1 00001 00010 000 00011 1010111` = `0xE61101D7` ✔、`0xEA1101D7` ✔、`0xEE1101D7` ✔；`funct7 = funct6<<1\|vm` 的 6 个取值 ✔。伪代码逐行标注 `vdot_ref.c` 行号，抽查 `vdot_ref.c:94`（`vstart>=vl` 返回）命中。溢出证明 `\|Σp\|≤16×2^14=2^18<2^31` 数学成立 |
| 2 | 编码空间占用证明（脚本 + 输出） | **PASS** | 我重跑 `python3 scripts/tools/check_funct6.py`，exit=0，输出与 `logs/stage2/check_funct6.log` **去时间戳后零差异**：OPIVV 已占 42 个 funct6、空闲 22 个，`111001/111010/111011` 全部 FREE。§2.4 明确声明「只覆盖本代码树已实现指令集」「占用的是 reserved 空间」「Zvdot4a8i 为 UNVERIFIED」——边界诚实 |
| 3 | 微架构（层次图、流水级、时序图、关键路径估算） | **PASS** | §3.2 层次图、§3.3 S0/S1/S2 三段表、§3.4 逐周期时序图、§3.6 关键路径。关键路径处三次显式声明「估算，非综合结果」，并给出折算模型；方案 A 的否决有完整数学推导 |
| 4 | 数据通路（16 路 8×8 阵列 + 可重构加法树结构、位宽推导、符号扩展） | **PASS** | §4.1–4.6。§4.2 给出 `sum_wo` 抽头点正确性的三条独立论证（含用既有 `vmulh` 反推）；§3.6.3 末尾核对了 `CSA3to2`/`CSA4to2` 的模 `2^width` 正确性 |
| 5 | **复用说明**（逐项 `文件:行号` + 自研占比） | **PASS** | 15 项复用清单，我抽查 12 处行号全部命中（见 §4 引用抽样表）。13.7% 可独立复算：生成的 `rtl/verilog/vdot/VDotTree.sv` 里**实测** `CSA4to2` 实例 12 个、`CSA3to2` 4 个、32 位加法 4 处，与 §5.3 的计数完全一致；分母 32×128×2+256=8448 与 `nAddendsSeqGen(34)` 递推一致（11+7+5+3+2+2+1+1=32 组）。方法声明「分母被低估、结果为上界」属保守表述 |
| 6 | 集成点清单（每个文件 + 内容 + 理由） | **PASS** | §6 A1–A6/B1–B2/C1–C5/D1–D4/E1–E3，按实施顺序编号；实现侧 §9「设计偏离记录」逐条回扣，偏离有理由 |
| 7 | 与 Zvqdotq / ARM SDOT / x86 VPDPBUSD 对比表 | **PASS** | §7.1 七列对比（含 Nanhu-vdot 论文），差异项有 §7.2 逐条理由 |
| 8 | 面积/功耗定性评估 + 扩展性论证 | **PASS** | §8.1–8.5；全部量化表述均标 `TBD(由P7实测填入)` 或「推断，非实测」 |

**P2 小结：8/8 PASS。** 这是三份验收标准里完成度最高的一组。

---

## 2. P3 验收标准（RTL 实现，6 条）

| # | 验收标准 | 判定 | 审计者亲自取得的证据 |
|---|---|---|---|
| 1 | `mill` 精化通过、无错误、日志存档 | **PASS** | `logs/stage2/p4_rtl_build.log` 为真实终端输出（含 `mill -i clean` 后的完整编译、exit=0）。我自己的重跑中 `xiangshan.test.runMain …VIMacUHarnessMain` / `…VecExceptionGenMain` 两次精化均成功（10s / 9s） |
| 2 | 成功生成 vdot 功能单元 Verilog，文件存在可读 | **PASS** | `rtl/verilog/vdot/`：`VDotTree.sv` 419 行、`VDotTop.sv` 1444 行、`VIMacU.v` 4876 行、`DecodeUnit.v`、`VIMac.sv` 均在且可读 |
| 3 | 补丁 `git apply` 可在干净 kunminghu-v2 上应用（验收方实测） | **PASS（强于团队自测）** | 我**不经**团队脚本独立验证：`git -C work/XiangShan-kmhv2 archive HEAD` 导出 pristine 全树到 `/tmp/audit/px`、yunsuan 到 `/tmp/audit/py`，三份补丁 `git apply --check` 与 `git apply` 全部成功。随后做**全目录**对比（团队脚本只比对补丁涉及的 19 个文件）：`diff -r -q /tmp/audit/px/src work/XiangShan-vdot/src` **零差异**；yunsuan 侧仅多出 `vdot_ref.c/.h`，二者与 `tests/golden/` 的 md5 完全相同（`c46e3479…` / `863c8d5a…`），系构建脚本按设计拷入。**补丁集完整覆盖了被测工作树，无"工作树里有、补丁里没有"的改动** |
| 4 | 代码风格与香山一致、关键逻辑有中文注释 | **PASS** | `VDotTree.scala`/`VDotTop.scala` 包名 `yunsuan.vector.mac`、Chisel 风格与 `Reduction.scala` 一致；中文注释密度高且包含推导依据 |
| 5 | 确实复用 YunSuan 现有乘法/加法结构 | **PASS（证据很强）** | 乘法器**零新增**：`VIMac64b` 仅加只读端口 `io.prod16 := sum_wo`（工作树 `VIMac64b.scala:208`），文件净增 7 行（295→302 行，与 §7.1 自述一致）；加法树全部例化 YunSuan 既有原语（生成网表里 12×`CSA4to2`、4×`CSA3to2`）；`Mgu`/`ByteMaskTailGen`/`VecPipedFuncUnit`/`FuncUnit`/`FuConfig` 零改动（`git status` 核实） |
| 6 | 三条指令均实现；译码、uop 拆分、FU 路由、写回全链路打通 | **部分通过** | 三条指令齐全：`Instructions.scala:30-32` 三条 BitPat、`VecDecoder.scala:256-258` 三行 opivv 表、`DecodeUnit.scala:983` `vmaInsts`、`VecExceptionGen` SEW/LMUL 守卫、`VIMacU` 输出三选一，均已核对。但「全链路打通」只到**分段验证**：`DecodeUnit` 与 `VIMacU` 各自单独精化成功 + 译码级 46 条 + FU 级 27529 条，**全核流水线上未跑过**（本机 16GB 不足，文档 §10 第 2 条已如实披露）。按字面标准记 部分通过 |

**P3 小结：5 PASS / 1 部分通过。** 第 3 条我用比团队更严格的方法复核，结论成立。

---

## 3. P4 验收标准（功能测试，6 条）

| # | 验收标准 | 判定 | 审计者亲自取得的证据 |
|---|---|---|---|
| 1 | 正数 ≥20 组全 PASS，日志为真实仿真输出 | **PASS** | 我的重跑：`positive/vdotacc_positive/vdot4a_positive` 各 40 条，合计 120，全 PASS；VIMacU 直驱通道再跑一遍同样 120 条。日志含 `EMU EXCEEDED LIMIT` + `Operations:40` 原始输出 |
| 2 | 负数 ≥20 组（含全负、正负混合）全 PASS | **PASS** | 132 条全 PASS。含 `0x80×0x80=+16384`、`0x80×0x7F=-16256`、`0xFF×0xFF=+1` 等符号扩展陷阱；我对 `0x80×0x7F` 用例做了故障注入反证（见 §5 复现记录 R5） |
| 3 | 边界覆盖 `±127/−128/0`、全 0、全 ±128、vl=0/1/15/16、`vstart≠0` 非法、vm、vta，全 PASS（跳过须说明） | **PASS** | 390 条全 PASS，跳过 21 条。我直接从语料统计复核：`boundary.txt` vl 取值 `0 1 2 3 4 8 15 16`、vstart `0 1 15`、vta/vma/vm 两值齐全、`vm=0` 24 条、全零 1 条、全 0x80 4 条；跳过 21 条的 status 只有 `ERR_SEW`(9) 与 `ILLEGAL_VSTART`(12)，无其它类别 |
| 4 | ≥10000 随机差分对比 `vdot_ref.c`，0 失配，**禁止重写 golden model** | **PASS** | 我的重跑：随机合计 236887 条、0 失配。禁止重写一条我做了实证：`vector_dot.cpp:17` 与 `vimacu_tb.cpp:31` 都是 `#include "vdot_ref.c"`，三处副本 md5 全等；`vector_dot.cpp` 的 85 行里只有字节搬运与 op 映射，语义全部来自 `vdot_exec()` |
| 5 | 报告含用例表（输入/期望/实际）、**波形截图**、复现命令 | **部分通过** | 用例表 ✔（§2 总表 + §3/4/5 worked example 含 REF/DUT 两行）、复现命令 ✔（§13 分项映射到日志）。**波形截图不存在**：`logs/stage2/waveform/` 只有 3 份 VCD + 3 份文本轨迹，全仓库 `*.png/jpg/svg` 只有 P7 的 4 张数据图 |
| 6 | 验收方独立重跑脚本，结果一致 | **PASS** | 我完整重跑 `bash scripts/20_run_func_tests.sh`（未降随机量，`RANDOM_OPS=20000`×3 种子全量）。`p5_summary.log` 与存档**去时间戳后零差异**：293107 attempted / 293107 passed / 0 failed / 6268 skipped，失败 suite 数 0。`p5_func_random.log`、`p5_regression.log` 同样零差异；其余日志差异仅为时间戳、`EMU has executed N ms` 与 mktemp 随机文件名 |

**P4 小结：5 PASS / 1 部分通过。**

### 3.1 跳过条目会计（逐条核算，结论：账对得上，无静默丢弃）

我不看报告，直接从 `tests/vectors/*.txt` 统计：

| 来源 | 总条数 | 可执行 | 跳过 | 跳过原因（实测 status） |
|---|---:|---:|---:|---|
| 10 个定向 suite | 663 | 642 | 21 | `ERR_SEW`×9、`ILLEGAL_VSTART`×12 |
| 3 个随机语料 | 30000 | 26887 | 3113 | `ILLEGAL_VSTART`×3113 |
| **语料合计** | **30663** | **27529** | **3134** | 无其它状态 |

汇总表的 6268 = 3134（A 通道 YunSuan L1）+ 3134（B 通道 VIMacU 直驱，回放同样 13 个文件）。
**算术成立，没有一条被静默丢弃**（`attempted + skipped` 恒等于文件总行数）。

「跳过的 FU 级异常用例由 46 条译码级用例覆盖」这一条**基本成立但有 2 处缺口**：译码级只有
`vdotacc SEW=32` 与 `vdotacc vstart=1`，而语料里被跳过的还有 `vdotacc SEW=16/64`、`vdotacc vstart=15`。
由于 `dotEewIllegal = dotRedInst && (SEW =/= 0)`、`vstartIllegal = isVArith && vstart =/= 0` 两个谓词对
vdot/vdotacc 共用，逻辑上等价覆盖，但报告「`[F]` 组含 vdotacc」「没有一条真正被放过」的措辞强于用例实际。

---

## 4. 对四个头条声称的证伪尝试（逐条）

| 头条声称 | 我的复现方法 | 结果 |
|---|---|---|
| **「新增逻辑仅约 13.7%」** | 重算分子分母；再到生成网表里数实例 | **站得住**。分子 768+128+192+100+100+50=1338、分母 1338+8192+256=9786 → 13.67%；`VDotTree.sv` 实测 12 个 `CSA4to2`、4 个 `CSA3to2`、4 处 32 位加法，与计数一致。方法在文中声明为「FAE 结构计数、分母低估、上界偏保守」，**不是面积报告**，表述与方法匹配 |
| **「latency 保持 2」** | 找测量点 | **部分站得住，且有一处循环论证未披露**。`VimacCfg.latency = CertainLatency(2)` 确实未改（`FuConfig.scala:563` 核对）；27529 条 VIMacU 直驱与 236887 条 L1 随机在"发射后第 2 拍采样"时数据逐位正确 → **RTL 周期数 ≤2 成立**。但 L1 波形里的 `io_out_valid` 是测试平台自己按常量 `VDOT_latency = 2` 的计数器产生的（`tests/unit/VectorSimTop.scala:26` `VDOT_latency: Int = 2`、`:108-120` 查表、`:127` `counter >= latency`、`:421` 驱动 `io.out.valid`），**与 DUT 流水深度无关**。报告把它写成波形证实的 2 周期（见问题 I-4）。时序收敛未验证，文档已如实披露 |
| **「生成的 VIMac.sv 与基线逐字节相同（零回退）」** | 自己跑 diff | **按文档给出的口径成立，但"逐字节"措辞不准**。`diff <(去注释) <(去注释)` = **0 行**（我用文档原命令复现）；但原始文件 `diff` 有 1922 行、md5 不同（`4cfdbd54…` vs `717faeed…`），差异全部是 firtool 写在注释里的源码行号。`11_RTL实现说明.md:529` 与 `:122` 都带了「去掉源码行号注释后」的限定，`12:61` 一处是无限定的「逐字节相同」 |
| **「9 个 fuType 输出含周期数逐字相同」/「163/164 module 网表逐字节不变」** | 两项都自己跑 | **全部成立**。逐 FU 对拍 9 行全 `YES`（含 `Cycles:10019/24138/4019/6019/23372/8019`）；我独立执行 `verilog_module_diff.py rtl/verilog/baseline/SimTop.v rtl/verilog/vdot/SimTop_with_vdot.v` → 164 共有 module、163 去注释后逐字节相同、1 处差异为 `SimTop` 顶层、5 个新增、0 个删除。注：被改过的 `VIMac64b` 归在"新增"里（阶段一基线 SimTop 本就没有例化它），该模块的零回退由 `VIMac.sv` 那条证据覆盖，证据链整体闭合 |
| **「直接驱动 VIMacU 本体 27529 条 0 失配」** | 读 harness 源码 + 跑一遍 | **成立**。`VIMacUHarness.scala:68` `private val u = Module(new VIMacU(VimacCfg))` 是真模块真配置；生成的 `VIMacUHarness.v` 里确有 `module VIMacU`/`VDotTree`/`Mgu`/`ByteMaskTailGen`。「`VIMacU.scala` 一行未改」在"P4 未再改动"的语境下成立（harness 是 `src/test/scala` 下的新文件）；但全项目 VIMacU.scala 实际 +84/−9，措辞可更精确。共享算术核 9 个 module 的 md5 我在自己的运行里逐个复现，与报告 §8.4 全等 |
| **「故障注入 5/5 被检出」** | **亲手重注一个故障** | **成立**。我把 `VDotTree.scala:77` 的符号扩展改成零扩展（`Cat(0.U((accWidth-prodWidth).W), io.prod(i))`），`make emu` 重建（63 s，md5 由 `1af7b331…` 类变为 `be924bf7…`），`negative.txt` 立即 `Error, compare failed`：REF `…fffc0800` vs DUT `…000c0800`；`YS_FUTYPE=10 YS_FUOPTYPE=0 -O 20000` 在第 1 条就 `EMU BADTRAP`。随后还原源码（md5 回到 `a6f5d3a5…`）并重建，`negative.txt` 恢复 `EMU EXCEEDED LIMIT / Operations:44` |
| **funct6 占用证明** | 重跑脚本 | **成立**（见 P2-2） |

### 4.1 `文件:行号` 引用抽样（抽 18 处，覆盖四份文档）

| # | 文档:行 | 引用 | 判定 |
|---|---|---|---|
| 1 | 10:428,533 | `FuConfig.scala:551-568` / `:563` `latency = CertainLatency(2)` | ✔ 命中 |
| 2 | 10:426 | `Parameters.scala:449` VFEX0 含 VimacCfg | ✔ |
| 3 | 10:415 | `DecodeUnit.scala:861` `lsrc(2) := Mux(isFMA,…)` | ✔ |
| 4 | 10:463 | `Reduction.scala:644-647` `red_vd_tail` | ✔ |
| 5 | 10:118 | `Mgu.scala:59-61` `VecDataToMaskDataVec` | ✔ |
| 6 | 10:873/874/876 | `ByteMaskTailGen.scala:66 / 72,78 / 78-79` | ✔ 三处全中 |
| 7 | 10:937/419 | `VimacOpcode.scala:5-24` / `package.scala:381-406` | ✔ |
| 8 | 10:241 | `VecExceptionGen.scala:275` `vstartIllegal`（pristine） | ✔ |
| 9 | 10:941 等 | `VecPipedFuncUnit.scala:48-53` / `FuncUnit.scala:175-211` / `VecDataSplitModule.scala:13-31` | ✔ |
| 10 | 10:1116/1298 | `UopInfoGen.scala:201 / :229`、`DecodeUnitComp.scala:359-365 / :1519` | ✔ |
| 11 | 10:202/1393 | `VectorFloatFMA.scala:1596`(CSA4to2) / `:1581`(CSA3to2) / `:1899-1903`(is_piped) | ✔ |
| 12 | 11:115 | `VIMac64b.scala:187` = `sum_wo` | ⚠ **仅在 pristine 成立**；实现工作树里是 192（见问题 I-5） |
| 13 | 11:240 | `VIMac64b.scala:33` = `fireS1` | ⚠ 同上（vdot 树第 33 行是注释） |
| 14 | 11:539 vs 11:594 | `VecExceptionGen.scala:275` vs `:305` 指同一行 | ⚠ **同一文档内两种基准**（问题 I-5） |
| 15 | 11:607 / 12:646 | `VecExceptionGen.scala:217` `dotEmulIllegal`、`:240` 并入 `emulIllegal`、`208-217` | ✔（实现工作树） |
| 16 | 12:68/475/529 | `emu.cpp:205-210`、`main.yml:42`、`vpu_constant.h:32` | ✔ |
| 17 | 12:571/573 | `FuncUnit.scala:214-216`、`ExeUnit.scala:228-241` `pipelineReg` | ✔ |
| 18 | 13:465/467/513/604 | NEMU `vcompute_impl.c:1531`、`vcommon.c:20-24`、`:8-18`、`vreg_impl.c:286` | ✔ 四处全中（只读查看，未写入 `work/NEMU`） |

**引用准确率：18 项中 15 项完全正确、3 项为"行号基准"问题（代码本身存在、只是指向另一棵树）、0 项指向不存在的代码。**
与阶段一 20% 的硬错误率相比，本阶段**没有重现**该缺陷。

---

## 5. 问题清单

### 阻塞（0 项）

无。没有发现伪造数据、不可复现结论或语义错误。

### 重要（4 项）

**I-1　声称有日志、日志里没有：译码级反向验证未存档**
- 位置：`docs/stage2/12_基础功能测试报告.md:26`（结论速览「撤掉守卫后 13 条立刻变红」，证据列写 `logs/stage2/p5_decode_illegal.log`）、`:682-702`（§9.3 贴出 `PASS 33，FAIL 13` / `VECEXC-TB: FAIL` 的终端输出块）、`docs/stage2/11_RTL实现说明.md:609`（同样指向该日志）。
- 事实：`logs/stage2/p5_decode_illegal.log` 只有 `(1) 精化` `(2) Verilator 构建` `(3) 运行定向用例` 三节（112 行），**没有任何 `(4) 反向验证` 段**；全仓库 `grep -rl "反向验证\|nofix"` 在 `logs/` 下**零命中**。`20_run_func_tests.sh:381` 调用 `run_decode_tb.sh` 时并未设 `PROVE_FAIL=1`，所以这段输出永远不会进入该日志。
- 严重性：违反执行纪律 1（证据必须来自真实执行并存档）与 3（证据优先）。这正是阶段一「伪造日志引用」的同类。
- **但结论本身属实**：我执行 `PROVE_FAIL=1 bash scripts/tools/run_decode_tb.sh`，实测 13 条 FAIL（vdot 7 + vdotacc 3 + vdot4a 3）、`共 46 条，PASS 33，FAIL 13`、`VECEXC-TB: FAIL`，与文档贴出的输出**逐字一致**；脚本自动还原源码（md5 `7fe8aea6…` 复原）。因此定级为「证据缺失」而非「伪造」。
- 修复：在 `scripts/20_run_func_tests.sh` 的 5.5 步增加一次 `PROVE_FAIL=1` 运行（或单独提供 `scripts/tools/run_decode_tb.sh` 的归档调用），输出落盘为 `logs/stage2/p5_decode_prove_fail.log`，并把上述三处引用改指该文件。

**I-2　交付的 Chisel 源码副本陈旧，不含本阶段头号修复**
- 位置：`rtl/chisel/xiangshan/VecExceptionGen.scala`（321 行）vs 工作树 `work/XiangShan-vdot/src/main/scala/xiangshan/backend/decode/VecExceptionGen.scala`（332 行）。
- 事实：`diff` 显示交付副本**缺失 P4 新增的 `dotEmulIllegal`**（第 208–218 行的注释块与守卫行）以及 `emulIllegal` 末尾的 `|| dotEmulIllegal`。即：`rtl/chisel/` 里陈列的，正是测试报告 §9 重点宣传的「LMUL>1 静默算错」缺陷**修复前**的代码。其余 10 个 `rtl/chisel/*.scala` 与工作树逐字节相同（我逐个 `cmp` 核对）。
- 附带：`rtl/chisel/xiangshan/` 缺 P4 新增的 `VIMacUHarness.scala`（164 行）与 `VecExceptionGenTest.scala`（89 行），而 `MASTER_PLAN` P3 交付物明确包含 `rtl/chisel/`（新增模块源码）。
- 影响：评委若按目录读源码，会看到与补丁、与被测 RTL 不一致的版本。（补丁本身是对的——我已全树证明。）
- 修复：`cp` 刷新 `rtl/chisel/xiangshan/VecExceptionGen.scala`，补入两个新增文件；并在 `scripts/` 里加一条「交付副本与工作树一致性」自检（`cmp` 循环），纳入 `20_run_func_tests.sh`。

**I-3　P4 验收标准第 5 条要求的「波形截图」完全缺失**
- 位置：`docs/stage2/12_基础功能测试报告.md` §10；`logs/stage2/waveform/`。
- 事实：目录下只有 3 份 `.vcd` 与 3 份 `_signal_trace.txt`，`find logs docs -name "*.png" -o -name "*.jpg" -o -name "*.svg"` 在阶段一/阶段二范围内**零命中**（仅 `docs/stage3/figures/` 有 P7 的 4 张数据图）。
- 说明：文本轨迹的可核对性其实**强于**截图（我就是靠它+VCD 复核的），但验收标准与赛题答辩都要图。
- 修复：用 GTKWave/Surfer 打开三份 VCD，各截一张含 `io_in_valid/io_out_valid/io_prod_*/io_dotVd/io_vd` 的图存入 `logs/stage2/waveform/*.png`，在 §10.2–10.4 每节嵌入，并保留文本轨迹作为可机读证据。

**I-4　`latency = 2` 的波形证据是循环论证，且未披露**
- 位置：`docs/stage2/12_基础功能测试报告.md:763`（「**in.fire@#21 → out.valid@#25 = 2 个时钟周期**，与 `latency=2` 一致」）、`:913`（§12 第 8 条「波形证实的只是『in.fire 到 out.valid 确实是 2 个时钟周期』这一行为」）。
- 事实：L1 平台的 `io.out.valid` 并非来自 DUT，而是测试平台按常量生成的——`tests/unit/VectorSimTop.scala:26` `val VDOT_latency: Int = 2`、`:108-120` 按 fuType 查表填 `latency`、`:127` `finish_fixLatency = busy && (counter >= latency)`、`:421` `io.out.valid := Mux(is_uncertain, finish_uncertain, finish_fixLatency)`。因此 `#21→#25` 测的是**测试平台自己的计数器**，对 DUT 流水深度零信息量。
- 真正成立的表述应是：①`VimacCfg.latency` 未改；②在「发射后第 2 拍」采样时，L1 236887 条 + VIMacU 直驱 27529 条数据**逐位正确**，故 RTL 周期数 ≤ 2；③时序收敛未验证（这一条已披露）。
- 修复：把 §10.2 该行改为「`out.valid` 由平台按 `VDOT_latency=2` 产生，本行证明的是**在第 2 拍采样时 DUT 数据已正确**」，§12 第 8 条同步改写，并指向 `VectorSimTop.scala:127,421`。

### 次要（9 项）

**M-1　`docs/stage2/11_RTL实现说明.md` 行号基准自相矛盾且未声明**
§2.3 的 `VIMac64b.scala:33/138/187/198/221`、§7.3 的 `VecExceptionGen.scala:275` 用的是 **pristine 基线**行号；
§10 第 3 条的 `:305`、第 8 条的 `:217/:240` 用的是**实现工作树**行号。文档表头只写了「实现工作树 `work/XiangShan-vdot`」。
按该表头读，§2.3 的 5 处全部落空（工作树里 `sum_wo` 在 192、`io.prod16` 在 208、`fireS1` 在 34 之后）。
修复：在文档开头加一行「未特别注明处，行号以 pristine 基线 `work/XiangShan-kmhv2` 为准；标 (vdot) 者以实现工作树为准」，并把 §7.3 的 `:275` 统一成与 §10 相同的基准。

**M-2　改动行数表与补丁实测不符（7 处）**
我用 `git apply --numstat` 在 pristine 导出副本上实测：

| 文档位置 | 文档写 | 实测 |
|---|---|---|
| 11:365 `VectorSimTop.scala` | +44 / −7 | **+41 / −3** |
| 11:366 `vpu_constant.h` | +15 / −3 | **+13 / −2** |
| 11:368 `test_driver.h` | +10 | **+14** |
| 11:369 `test_driver.cpp` | +118 / −4 | **+127 / −2** |
| 11:345 `VecExceptionGen.scala` | +35 / −3 | **+34 / −4** |
| 11:344 `VIMacU.scala` | +93 / −12 | **+84 / −9** |
| 11:352 小计 | +153 / −15 | **+143 / −13**（与同句自述的「445 插入 / 13 删除」自相矛盾：153+302=455≠445） |

`11:36` 又写 `VecExceptionGen [改 +25]`，与 §3.2 的 +35 和实测的 +34 三个数互不相同。
YunSuan 侧（+4/+17/+7/161/150）与三个新建文件（49/164/89）全部准确。
修复：用 `git apply --numstat` 的输出重新生成这两张表。

**M-3　`TBD` 形式不统一（审计期间已被 P7 并发消除，仍需制度化）**
审计开始时（22:0x）`docs/stage2/13` 有 **11 处** 非约定形式 `TBD(由P7填入实测值)`，而设计文档用的是约定形式
`TBD(由P7实测填入)`（10 处）——P8 若按约定形式检索占位符会全部漏掉。
审计结束前重查，这 11 处已被 P7 工程师在并发回填实测延迟时一并移除（当前 `docs/stage2/` 只剩 10 处约定形式）。
修复：把「唯一允许的占位符形式」写进 `MASTER_PLAN` 执行纪律，并让 P8 的检索脚本同时匹配 `TBD(` 前缀而非整串。

**M-4　把计划要求标成「赛题要求」，其中一个数字无出处**
`12:141`「赛题要求「≥20 组」」——`target.md` 2.3.1/2.3.2 没有任何条数要求，≥20 出自 `MASTER_PLAN` P4-1/2；
`12:309`「赛题要求「≥48 组」」——`target.md` 与 `MASTER_PLAN` **都没有**这个数字，我无法在仓库内找到出处（官方 PDF 为 CID 编码，**无法验证**是否另有来源）。
修复：改为「计划（MASTER_PLAN P4）要求 ≥20 组」；48 若无出处则删除或注明来源页码。

**M-5　译码级覆盖缺 3 条，报告措辞强于证据**
语料里被跳过的 `vdotacc SEW=16`、`vdotacc SEW=64`、`vdotacc vstart=15` 在 46 条译码用例里没有对应项
（`[F]` 只有 `vdotacc SEW=32`，`[H]` 只有 `vdotacc vstart=1`）。谓词共用故逻辑等价，但 `12:338`「全部在译码层得到验证，没有一条真正被放过」与 `12:333`「`[H]`/`[F]` 组含 vdotacc」措辞偏强。
修复：在 `tests/unit/vecexcgen_tb.cpp` 补 3 条用例（46→49），或把措辞改为「按判定谓词等价覆盖」。

**M-6　「pristine 基线」措辞不严谨**
`work/XiangShan-kmhv2/yunsuan` 的工作区带着 `tests/unit/yunsuan_testdriver_env_select.patch`（`test_driver.cpp` +16/−1，我用 `git -C … diff` 核实）。对拍用的基线 emu 即由此构建。该改动只动测试驱动、不影响被测 RTL，且 `docs/stage1/00_环境版本锁定.md:59-60` 已披露，但 `12:500-502` 直接称其为 pristine 基线而无脚注。
修复：在 §7.3 加一句「基线 emu = kmhv2 + `yunsuan_testdriver_env_select.patch`（仅测试驱动 16 行，用于 `YS_FUTYPE` 选择）」。

**M-7　跨文档引用指向不存在的小节**
`11:601` 写「§5.3 的 13.7% 新增逻辑占比」，但 `11_RTL实现说明.md` **没有 §5.3**（§5 是「如何重建与复跑」）；13.7% 在 `10_vdot指令设计文档.md` §5.3。
修复：改为「设计文档 §5.3」。

**M-8　`MASTER_PLAN` D2.3 的行号错误**
`docs/_plan/MASTER_PLAN.md:62` 写 `VecExceptionGen.scala:294` 的 `vstartIllegal = isVArith && vstart =/= 0`；
实际 pristine 第 294 行是 `io.illegalInst := …`，`vstartIllegal` 在 pristine 275 / 实现树 305。
修复：改为 `:275（pristine）/ :305（实现树）`。

**M-9　`tests/unit/VectorSimTop.scala` 残留 11 处 `TODO`/`FIXME`**
（`:18,19,20,179,189,196,219,223,235,267` 等）均为上游原文，但 P8 验收标准 4 要求「全仓库无占位符残留」。
修复：在 P8 的检索脚本里显式白名单该上游派生文件，并在 README 注明「上游原始注释，未改动」。

### 提示（不计入问题，但值得知道）
- `tests/unit/vimacu_latency_tb.cpp`、`tests/unit/vecfu_latency_tb.cpp`、`bench/`、`docs/stage3/22_*`、`logs/stage3/p7_*` 在审计期间处于未提交状态，是 P7 工程师**正在进行**的工作，不计入阶段二评价。有意思的是 `vimacu_latency_tb.cpp:8-14` 的注释独立得出了与本报告 I-4 完全相同的结论（L1 的 `io_out_valid` 来自平台常量），说明团队内部已知此事，只是没有回写阶段二文档。
- 报告 §13 称整套战役「默认约 4 分钟」，我的实测是 **47 秒**（22:03:35→22:04:22，含两次 mill 精化）。低估风险为零，仅提示可更新。

---

## 6. 赛题条款完备性与阶段二评分预测

| 赛题条款 | 交付物 | 完备性判断 | 理由 |
|---|---|---|---|
| **2.1 vdot.vv 设计文档** | `docs/stage2/10`（1414 行） | **完备，明显超出** | 指令语义/编码证明/微架构/数据通路/复用/集成清单/横向对比/面积扩展性八项齐全；估算与实测严格分离；三条指令（含两条扩展）而非一条 |
| **2.2 vdot.vv RTL 实现** | `rtl/chisel/`、`rtl/patch/`、`rtl/verilog/`、`docs/stage2/11` | **完备**（1 处交付物瑕疵 I-2） | 补丁可干净应用并与被测工作树**全目录逐字节一致**（我独立验证）；可精化、可出 Verilog；既有模块 163/164 网表零变化 |
| **2.3.1 正数测试** | 120 条 × 2 通道 | **完备** | 全 PASS，worked example 含手算与 REF/DUT 对照 |
| **2.3.2 负数测试** | 132 条 × 2 通道 | **完备** | 含符号扩展陷阱专项；故障注入 F1 证明该 suite 确实能红（我亲自复现） |
| **2.3.3 边界值测试** | 390 条 × 2 通道 + 46 条译码级 | **完备**（跳过项有据，措辞略强 M-5） | 覆盖 ±127/−128/0、全 0、全 ±128、vl=0/1/…/16、vstart、vm、vta、vma、32 位回绕 |

### 阶段二交付物完成度（20 分，优秀 16-20 / 良好 11-16 / 一般 6-11 / 较差 0-6）

**预测得分：17 / 20（优秀区间下半部）**

- 支撑「优秀」的硬事实：三项测试全部实测通过且可独立复现（我一次复跑即逐字节重合）；293107 条 0 失配；
  参考模型单一来源可证；补丁可干净应用且覆盖完整；对既有指令零回退有网表级证据；故障注入自证测试有效性；
  局限性章节主动登记了自己的最大验证缺口并在本阶段关闭了其中一个（VIMacU 直驱）。
- 扣分项（约 −3）：
  1. 赛题 2.3 字面要求「基于**香山仿真环境**」，实际最强层级是 FU 级（YunSuan L1 + VIMacU 直驱 + VecExceptionGen 直驱），
     **全核流水线未跑**。文档披露充分，但评委按字面打分时这是客观差距（−1.5）；
  2. 缺波形截图（I-3，−0.5）；
  3. 反向验证证据未存档（I-1，−0.5）；
  4. `rtl/chisel/` 副本陈旧 + 行数表错误 + 跨文档引用错误（I-2/M-1/M-2/M-7，−0.5）。
- 若 I-1 ~ I-4 全部整改，**可稳进 18–19 分**；全核 difftest 缺位是 18 分以上的天花板，只能靠 P6 协同仿真与等价性论证补偿。

### 可行性 · 技术路径合理性（10 分，优秀 9-10 / 良好 7-9 / 一般 4-7 / 较差 0-4）

**预测得分：9 / 10（优秀下限）**

「是否复用香山现有向量实现」这一条是本项目最强的地方，我的核对结论：
- **乘法器零新增**：16 路 8×8 全部来自既有 2 片 `VIMac64b`，改动仅 `+7 行`（一个只读输出端口），且用生成网表证明既有指令零回退；
- 加法树用的是 YunSuan 自家原语 `CSA4to2`/`CSA3to2`（生成网表实测 12+4 个实例），不是另造；
- `Mgu`/`ByteMaskTailGen`/`VecPipedFuncUnit`/`HasPipelineReg`/`VecDataSplitModule` 全部零改动复用；
- `FuConfig`/`FuType`/`Parameters`/Dispatch/IQ/WbArbiter **一行未改**（`git status` 可证），这意味着调度与写回网络完全不受影响；
- 落地性有补丁级证据：干净上游 + 三份补丁 = 被测工作树，字节级一致。

扣 1 分的理由：时序可行性（`latency=2`）目前**只有静态逻辑级估算**支撑（S1≈24 vs 最坏 23–29、S2≈21 vs 最坏 19–23，裕量很薄），
且报告把平台生成的 `out_valid` 当成了延迟证据（I-4）；R-TIMING 风险真实存在，保底方案 C 会让十余条既有指令集体慢 50%。

### 可行性 · 功能验证有效性（10 分，同档）

**预测得分：9 / 10（优秀下限）**

- 覆盖正数/负数/边界：**全部满足且大幅超量**（120 / 132 / 390 条定向 + 236887 条随机）；
- **两条互相独立的 DUT 通道**（`VDotTop` 与真正被集成的 `VIMacU`），共享同一份参考模型与同一批语料，互为等价性证明——这一点超出一般参赛水平；
- **测试有效性有自证**：5 个语义不同的故障注入 5/5 被检出（我亲手复现 1 个，确认 suite 真会红），译码级守卫有反向验证（我亲手复现，13 条变红）；
- 跳过项会计透明、可独立复算；对「没检出」的每一格都给出了物理解释（§11.2–11.3 是本报告作者认为全套文档里质量最高的一节）。

扣 1 分的理由：① 异常语义只在译码级验证，「译码报非法」与「流水线真的不写 `vd`」之间仍缺全核一环；
② 波形截图缺失、反向验证日志缺失，使部分证据链依赖「再跑一次」而非存档；③ 译码级对 vdotacc 的 SEW/vstart 覆盖有 3 条缺口（M-5）。
（协同仿真是否通过属阶段三 P6 范围，本次未审计，不计入该项打分。）

---

## 7. 复现记录（我实际执行的命令与真实结果）

```
R0  source scripts/env_host.sh
R1  cp -R logs/stage2 /tmp/audit/orig_logs_stage2          # 先备份交付日志
R2  bash scripts/20_run_func_tests.sh                      # 全量重跑，未降随机量
       22:03:35 开始 → 22:04:22 结束（47 s，含 2 次 mill 精化、2 次 verilator 构建）
       合计 293107 attempted / 293107 passed / 0 failed / 6268 skipped，失败 suite 数 0
       p5_summary.log、p5_func_random.log、p5_regression.log 与存档 **去时间戳后零差异**
       其余日志差异仅为时间戳、"EMU has executed N ms"、mktemp 文件名
R3  rm -rf logs/stage2 && cp -R /tmp/audit/orig_logs_stage2 logs/stage2
       git status 确认 logs/ 无任何改动（交付物原样还原）
R4  git -C work/XiangShan-kmhv2 archive HEAD | tar -x -C /tmp/audit/px      # 不触碰 pristine 工作树
    git -C work/XiangShan-kmhv2/yunsuan archive HEAD | tar -x -C /tmp/audit/py
    (cd /tmp/audit/px && git init -q . && git apply --check 0001 && git apply 0001)   -> OK
    (cd /tmp/audit/py && git init -q . && git apply --check 0002 && git apply 0002
                                       && git apply --check tb   && git apply tb)     -> OK
    diff -r -q /tmp/audit/px/src work/XiangShan-vdot/src                -> 零差异
    diff -r -q /tmp/audit/py/src work/XiangShan-vdot/yunsuan/src        -> 仅多 vdot_ref.c/.h
    md5 tests/golden/vdot_ref.c == 工作树副本 == build/vimacu-tb 副本   -> c46e34793a0b…
R5  故障注入复现（VDotTree.scala:77 符号扩展 -> 零扩展）
    make -C work/XiangShan-vdot/yunsuan emu                            -> 63 s，emu md5 变化
    YS_VDOT_VECTORS=tests/vectors/negative.txt ./build/emu -O 44 -s 7
        -> Error, compare failed：REF …fffc0800 / DUT …000c0800
    YS_FUTYPE=10 YS_FUOPTYPE=0 ./build/emu -O 20000 -s 11
        -> EMU BADTRAP，Operations:1
    还原源码（md5 回到 a6f5d3a584e718e579fdef4b91ef1ff7）+ 重建
        -> EMU EXCEEDED LIMIT / Operations:44
R6  PROVE_FAIL=1 bash scripts/tools/run_decode_tb.sh
        -> 13 条 FAIL（vdot 7 / vdotacc 3 / vdot4a 3）
           "共 46 条，PASS 33，FAIL 13" / "VECEXC-TB: FAIL"
           源码自动还原，md5 回到 7fe8aea6f6eb541f43d70aebe770055c
R7  python3 scripts/tools/check_funct6.py        -> 与 logs/stage2/check_funct6.log 零差异，exit=0
R8  diff <(sed -E 's@//.*@@;s/[[:space:]]+$//' rtl/verilog/baseline/VIMac.sv) \
         <(sed -E 's@//.*@@;s/[[:space:]]+$//' rtl/verilog/vdot/VIMac.sv) | wc -l   -> 0
    diff rtl/verilog/baseline/VIMac.sv rtl/verilog/vdot/VIMac.sv | wc -l            -> 1922（全为注释行号）
R9  python3 scripts/tools/verilog_module_diff.py rtl/verilog/baseline/SimTop.v \
                                                 rtl/verilog/vdot/SimTop_with_vdot.v
        -> 共有 164，逐字节相同 163，差异 1 ['SimTop']，新增 5，删除 0
R10 python3 scripts/tools/vcd_extract.py --vcd logs/stage2/waveform/*.vcd --transactions / --signals …
        -> vdot:    #21 fire / #25 out；sumRegS2_0=carRegS2_0=00010000；io_dotVd=00040000×4
           vdotacc: io_accOperand_0=000003e8、_1=0；io_dotVd=05d8 05d8 05d8 09c0；io_vd=…000009c0
           vdot4a:  sumRegS2_0/carRegS2_0=00000014/0000000a；_1=00000004/000000aa
                    io_dotVd=0000034e 000001be 000000ae 0000001e；foldLevels=0
        -> §10.2/§10.3/§10.4 共 12 个数值**全部与 VCD 一致，无一处对不上**
R11 语料会计：逐文件 awk 统计 -> 30663 / 27529 / 3134，status 仅 ERR_SEW 与 ILLEGAL_VSTART
R12 交付副本一致性：对 11 个 rtl/chisel/*.scala 逐个 cmp
        -> 10 个 IDENTICAL，VecExceptionGen.scala **DIFFERENT**（缺 dotEmulIllegal，321 vs 332 行）
R13 署名扫描：对 generated by / co-authored-by 等署名行做 grep -rniE（排除 work/ 与 .git/）
        -> 零命中
    占位符扫描：TODO/FIXME 仅 tests/unit/VectorSimTop.scala（上游原文 11 处）；
                TBD 两种写法 10 : 11（见 M-3）
R14 引用抽样 18 处（见 §4.1），逐条 sed -n 打开核对
R15 终态核查：work/XiangShan-vdot、work/XiangShan-vdot/yunsuan 的 git status 与审计开始时完全一致；
    work/XiangShan-kmhv2 未写入；work/XiangShan-cosim、work/NEMU 全程只读（仅 sed 查看 4 个文件）
```

---

## 8. 整改优先级建议

| 优先级 | 事项 | 预计工作量 |
|---|---|---|
| 1 | I-1 把 `PROVE_FAIL=1` 的输出真正落盘并改引用 | 10 分钟（脚本加 3 行） |
| 2 | I-2 刷新 `rtl/chisel/` 副本 + 加一致性自检 | 15 分钟 |
| 3 | I-4 改写 latency 的两处表述，披露 `out_valid` 来自平台常量 | 15 分钟 |
| 4 | I-3 补三张波形截图 | 30 分钟 |
| 5 | M-2 用 `git apply --numstat` 重算两张行数表 | 15 分钟 |
| 6 | M-1 / M-3 / M-4 / M-7 / M-8 文字订正 | 20 分钟 |
| 7 | M-5 补 3 条译码用例（46→49） | 20 分钟 |

全部整改合计约 2 小时，完成后阶段二可从 17 分提升到 18–19 分区间。
