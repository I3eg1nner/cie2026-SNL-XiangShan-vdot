# 阶段三（赛题 3.1.1 / 3.1.2 / 3.2 / 3.3）独立验收审计报告

| 项 | 值 |
|---|---|
| 审计对象 | P5 NEMU 指令扩展、P6 NEMU↔RTL 协同仿真、P7 基线实现与加速比分析 |
| 审计依据 | `docs/_plan/MASTER_PLAN.md` P5（5 条）/ P6（5 条）/ P7（6 条）验收标准、D2 / D2.1 / D2.3（S-7'）、执行纪律第 2 节 |
| 被审版本 | 交付仓库 `b5a07b6`（审计开始时为 `f52b072`；审计期间他方提交了 `b5a07b6`，只新增波形 PNG、`make_stage23_figures.sh` 并改了几处文档。本报告按 `b5a07b6` 判定） |
| 审计环境 | x86_64 Linux（128 核），与建设环境（macOS/arm64 + arm64 Docker）**不同**；本机没有 docker 和 firtool |
| 审计方式 | 在本机按 pin **从零重建** `work/`，**不经交付脚本**逐步手工复现 P5/P6/P7 的全部实测项（脚本依赖 arm64 Docker，本机无法直接运行，见 I-4）；未采信任何文档自述数字 |
| 审计时间 | 2026-10-24 16:50 – 17:3x UTC |
| 审计者立场 | 独立验收，未参与任何建设工作；目标是**证伪**而非确认 |
| 对工作树的影响 | 交付仓库内**没有任何已跟踪文件被修改**（`git status --short` 为空）；`logs/`、`bench/results/` 未被覆盖（所有重跑产物写在 `/tmp/audit3/`）；唯一新增文件为本报告。`work/` 是审计者在本机新建的（此前不存在），其中的临时故障注入已按 `cmp` 逐字节还原 |

> **排除项（按任务约定不作为新发现）**：阶段二/三波形缺 PNG（审计期间已由 `b5a07b6` 补上）；`latency_fu.csv` 里「数值比对 0 笔一致」的措辞；
> 6→1 与 6→2 的指令计数口径；`dotLmulIllegal` 与 `dotEmulIllegal` 的命名。下文只在发现**新的方面**时提及。

---

## 0. 总评

阶段三的**实测数据本身经得起证伪**。我在一台与建设环境完全不同的机器（x86_64 Linux、GCC 15 交叉编译器、Verilator 5.024）上从零重建 NEMU 与 XiangShan，
把 P5 的 30758 条语料、P6 的 72758 条协同激励、P7 的 25924 条等价性用例和 FU 延迟实测全部重跑一遍：
**所有汇总数字与存档日志完全一致**（P6 分 suite 汇总表 `diff` 为空；`bench/results/*.csv` 由 `collect_results.py` 从日志重新生成，9 个文件逐字节相同）。
另外我自己写了一份独立的 Python 语义模型（按 D2 / D2.1 / S-7' 逐条实现），用它核对全部语料：**30650 条 0 失配**。
故障注入我复现了团队的 6 + 5 项，又自己补了 6 项，全部被检出。

问题集中在**证据的表述**上，没有发现伪造数据，也没有发现语义错误：
- 协同仿真报告引用的 `p6_build.log` 行号在**任何一版**日志里都不存在（I-1，与阶段一、阶段二 I-1 同类）；
- HANDOFF_TODO 陷阱 #6 在 **`VIMacU` 直驱**上又出现了一次：「546 笔全部 2 拍」中的 `out.valid` 由 harness 按 `VimacCfg.latency` 搭的寄存器链产生，按构造恒为 2 拍（I-2）；
- 故障注入 T3-RTL-1 被描述成「bit0 翻转」，实际因 Verilog 运算符优先级变成了输出选择反相（I-3）；
- 三个一键脚本 Linux 上跑不起来，`work/XiangShan-cosim` 也没有任何脚本负责创建（I-4）。

| 维度 | 判定 |
|---|---|
| 真实性（日志/波形/数据是否来自真实执行） | **通过**。全部核心数字在异构平台上独立复现；1 处「引用的日志行不存在」（I-1） |
| 可复现性 | **结论可复现，脚本不可复现**。手工步骤在 Linux 全部跑通；交付脚本绑定 arm64 Docker 与 macOS 路径（I-4） |
| 证据完备性 | **部分通过**（I-1；`VIMacU` 缺数据成形拍证据，I-2） |
| 交付物自洽性 | **基本通过**（几处陈旧数字与行号，M-2 / M-5 / M-6） |
| 诚实性（估算 vs 实测、局限性披露） | **基本通过**。建模值在 README / 文档 / CSV 三处都标得很清楚；例外是 I-2 的循环论证被写成「实测」，以及「2.00× 是下界」「只有协同仿真能发现」两处表述过强（M-3 / M-4） |
| S-7' 全链一致性 | **通过**。参考模型 → 语料 → NEMU → RTL 守卫 → 文档全部一致，由独立模型与 cosim 双向核实 |

---

## 1. P5 验收标准（NEMU 指令扩展，5 条）

| # | 验收标准 | 判定 | 审计者亲自取得的证据 |
|---|---|---|---|
| 1 | NEMU 在本机实际编译成功（riscv64-xs-kmhv2），日志存档 | **PASS** | 存档 `p5_nemu_build.log` 像真实终端输出（`:31`/`:45` 两种形态的 `CONFIG_CUSTOM_XVDOT`、`:38`/`:145` 两份 `vdot.o`、`:143` aarch64 `.so`）。我在 x86_64 上从 `9090839` 重新构建出独立解释器和 `-so` 两种形态，`autoconf.h:113` / `:103` 都有 `CONFIG_CUSTOM_XVDOT 1`。本机缺 `readline` / `SDL2` 开发包，我用 `apt-get download` 解到 `/tmp` 后通过 `CFLAGS`/`LDFLAGS` 传入，**没有改 NEMU 源码**（见 §6 R2） |
| 2 | patch 可干净应用到 NEMU master，验收方实测 | **PASS** | 在**全新 clone** 的 NEMU `9090839`（`git status` 为空）上执行 `git apply --check --verbose`，8 个文件全部通过；`--numstat` 合计 +278/−1，与文档一致；sha256 `fb003c54…` 与 `p5_nemu_build.log:7` 一致 |
| 3 | 三条指令的 NEMU 执行结果与独立 C 参考模型一致（≥10000 随机 + 全部定向） | **PASS（强于团队自测）** | ① 本机重跑：独立解释器 `TOTAL cases=30758 pass=30758 fail=0`，4834 条必须 trap 的全部 `mcause=2`，分 suite 表与 `p5_vdot_tests.log:70-90` 逐行相同；`-so` 经上游 `tools/ref-so-runner` 运行 `HIT GOOD TRAP / trap code:0`、`vst count = 30758`。② 用 `gen_vectors.py` + `vdot_cli` 重新生成 13 个语料文件，与仓库**逐字节相同**。③ **审计者自写的独立语义模型**（`/tmp/audit3/py/indep_model.py`，不引用 `vdot_ref.c`）核对全部语料 30650 条（`vstart_relaxed` 中 108 条 SKIP 策略行除外）：**0 失配**，S-7' 下 vdot4a 的 `vstart≠0` 全部判 `ILLEGAL_VSTART` |
| 4 | 正确处理 vl / vstart / vm / vta | **PASS** | 逐行读 `vdot.c`（221 行），结构与 `reduction_instr()` / `arithmetic_instr()` 一致。重跑 `fault_inject.sh`，6 项结果与 `p5_fault_injection.log` **数字完全相同**（21103 / 12079 / 10173 / 3202 / 等价变异体 / 1584）。我另外补了 4 项注入，**全部检出**：vdot4a 子字节索引 `4i+j→i+4j`（6161 条失败）、归约不写 tail（8202）、vdotacc 不读旧 vd（8066）、vdot4a 的 vma=1 不置全 1（1334） |
| 5 | 文档说明 NEMU 译码机制并与改动对应，标注 `文件:行号` | **PASS** | §1 的 `def_INSTR_TAB` / `INSTR_LIST` / 四级译码链讲得准确。抽查 46 处引用：37 处命中，8 处差 1–2 行，1 处指错（M-6），**没有一处指向不存在的代码** |

**P5 小结：5/5 PASS。**

---

## 2. P6 验收标准（NEMU↔RTL 协同仿真，5 条）

| # | 验收标准 | 判定 | 审计者亲自取得的证据 |
|---|---|---|---|
| 1 | 实际运行，REF 确为 NEMU 真实实现（非重写），文档给出代码引用证据 | **PASS**（存在证据引用问题 I-1） | `tests/cosim/` 三个源文件里**没有任何点积语义**：`cosim_main.cpp` / `ref_nemu.h` 不 include `vdot_ref`，只用 `dlopen` 加载 `difftest_init/regcpy/memcpy/exec`。本机运行时 `DIFFTEST_REG_SIZE = 1400 B` 校验通过，自检 `0x5d8` 通过。**决定性证据**：只改 NEMU 的 `vdot.c`（T3-NEMU-1，乘积异或 1）并重建 `.so`，值比对立刻出现 4944 条 FAIL，说明参考值确实来自 NEMU 本体。NEMU 侧引用（`ref.c:444/110/143/205/28`、`isa difftest ref.c:251/255-256/141/170/174-175`、`cpu-exec.c:784-793/884`、`fence.h:22`）全部命中 |
| 2 | ≥10000 随机 + 全部定向用例，0 失配；日志存档 | **PASS** | **本机完整复现**：真实 `.so` 加 Verilated `VDotTop` / `VdotDecodeProbe`（在本机由 mill 从 `XiangShan-cosim` 精化得到），72758 条激励，值比对 55924/55924，判定分歧 0。分 suite 汇总与 `p6_cosim_run.log:22-52` 做 `diff`，**完全相同**。另核：`55924 + 16834 = 72758`，非法一致的 16834 条全部是 REF 抛异常、RTL 也判非法 |
| 3 | difftest 机制讲清楚（标注 `文件:行号`）以及与全核的异同 | **PASS** | §9 的引用在 difftest `3729300` 上**全部命中**：`Rob.scala:1543`、`DataPath.scala:329`、`RenameTable.scala:312`、`NewCSR.scala:1624`、`Bundles.scala:66`、`Preprocess.scala:35`、`Difftest.scala:344-345/392`、`DPIC.scala:130/554-556`、`difftest.cpp:567/588/597/334/685/695/157`、`refproxy.cpp:185-213/193/196/232/143`、`refproxy.h:252-254/369/108-119/274-278`。§10/§11 的异同与缺口（G1–G4）写得诚实；§10.3 有两处陈旧内容（M-2） |
| 4 | 故障注入：改坏 RTL 一位，协同仿真必须报错；日志存档 | **PASS**（存在 I-3） | 本机复现全部 5 项，数字与 `p6_fault_injection.log` **完全一致**（5116 / 586 / 4944 / 分歧 162 / 分歧 74），恢复后复测通过。T3-RTL-2（`32'hFFFFFFFF→FFFFFFFE`）确实只改了一位，被检出 586 条，满足本条。但 T3-RTL-1 **并不是**文档所说的「bit0 翻转」（I-3）。我另补 2 项：真正给 `io_vd` 整体异或 bit0（加括号）→ 6378/6378 FAIL；去掉 NEMU vdot4a 的 vma 处理 → 313 FAIL |
| 5 | 全核 difftest 未运行时，写明原因与等价性论证 | **PASS** | §11.3 写明未执行及原因（16 GB 机器）；§11.1 给出 5 点论证，§11.2 列出缺口，其中 G1（`VIMacU` 的掩码/尾部成形逻辑没进协同仿真）为最大缺口，并已主动披露 |

**P6 小结：5/5 PASS，但带两个重要问题（I-1、I-3）。**

---

## 3. P7 验收标准（基线实现与加速比分析，6 条）

| # | 验收标准 | 判定 | 审计者亲自取得的证据 |
|---|---|---|---|
| 1 | 基线用 RVV 1.0 指令实现相同功能，在 NEMU 上与 vdot 逐位一致 | **PASS** | 本机用 GCC 15 重新编译 `tests/riscv/baseline` 并在本机 NEMU 上运行：`[A] TOTAL cases=30758 run=25924 pass=25924 fail=0`，三方失配全为 0；`[B]` 24 个长度 0 失配；`[A0]` 对照表与存档逐行相同 |
| 2 | 给出基线指令序列、条数、各指令延迟来源（`FuConfig` 等 `文件:行号`） | **PASS** | 在 pristine 树核对：`FuConfig.scala:563/544/615/415/402/66`、`Parameters.scala:409/449/450/453`、`UopInfoGen.scala:199/200/201/214/215/224/229`、`ExeUnit.scala:228-241`、`FuncUnit.scala:214-216`、`RiscvInst.scala:93` 全部命中。`VecDecoder.scala:466/430/436/244/419` 只在**实现树**上命中（pristine 是 457/421/427/243/410），文档没有声明行号基准（M-5） |
| 3 | vdot 延迟来自**实测 RTL 周期数**，估算部分明确标注 | **部分通过** | **L1 `VDotTop` 部分成立，而且不是循环论证**：我用自己写的 VCD 解析器（不用团队的 `vcd_extract.py`）读三份存档 VCD，又在本机重建 trace 版 emu 重新抓波形，12×3 笔事务中 `io_vd` 都在 `fire` 后的**第 2 个**上升沿才变化（第 1 拍仍是旧值），数值与我的独立模型一致。**`VIMacU` 直驱部分是循环论证**（I-2）：`io_outValid = vPipe_2_REG & validVecThisFu_2`（本机生成的 `VIMacUHarness.v:4181,4252-4253,4349`），而 harness 的寄存器链长度取自 `VimacCfg.latency`，所以「2 拍 × 546」按构造必然成立。该 harness 也没有测数据成形拍。我补测了一次：第 1 拍 `io_vd` 尚未等于终值的有 545/642 笔，其余 97 笔第 1 拍输出恰好已等于终值（未逐笔归因）。也就是说结论「=2」大体成立，但交付物里的证据不足以支撑 |
| 4 | 单次延迟、长向量吞吐、指令条数、关键路径/面积代价讨论 | **PASS** | §5.1–§5.4、§6、§7 齐全。核算：2575/2061 = 1.249、655/525 = 1.248、斜率 10/11/10/8/9 由 CSV 复算成立。§5.4 主动写出了「`vdotacc` 携带依赖 2 拍，长于基线的 1 拍」这一不利发现 |
| 5 | 至少一张图表，CSV 与绘图脚本一并提交 | **PASS** | `collect_results.py` 从两份存档日志重新生成 9 个 CSV，与 `bench/results/` **逐字节相同**。图 2 的 12 个标注值与 CSV 逐一复算一致。`plot_results.py` 未能在本机重新渲染（缺 matplotlib，未安装）。图 5 的 S2 寄存器值与 VCD 一致 |
| 6 | 结论诚实，不夸大，列出全部假设与误差来源 | **部分通过** | README / 文档 / CSV 三处对「实测 / 声明值 / 源码推导 / 建模」的标注**一致且清楚**，1.50× 与 2.00× 始终标为建模，局限性章节充分。扣分点：I-2 的循环论证被写成「实测」（包括「既有 vmul/vwmul/vmacc 一拍没慢（实测）」）；「2.00× 是对基线友好的下界」与自己的敏感性表矛盾（M-4） |

**P7 小结：4 PASS / 2 部分通过。**

---

## 4. 对头条声称的证伪尝试

| 头条声称 | 我的复现方法 | 结果 |
|---|---|---|
| P5「30758 条 0 失配，4834 条全 trap」 | 异构平台重建 + 重跑；独立模型核语料；重新生成语料 | **成立** |
| P5「故障注入 5/5」 | 重跑 6 项，另补 4 项 | **成立**（10/10 检出 + 1 个等价变异体，经实测确认） |
| P6「REF 为 NEMU 真实实现」 | 只改 NEMU `vdot.c`，看 cosim 的反应 | **成立**（4944 FAIL / 分歧 162 / 分歧 74） |
| P6「72758 条，值 0 失配，分歧 0」 | 本机从精化开始全链路重跑 | **成立**（汇总 `diff` 为空） |
| P6「T3-RTL-1：写回 bit0 翻转」 | 对比真正的 bit0 翻转 | **不成立**（I-3） |
| P6「S-7' 收敛被 T3-NEMU-3 守住」 | 重跑 | **成立**（分歧 0→74） |
| P7「vdot FU 延迟实测 2 拍」 | 自写 VCD 解析 + 重新抓波形 + 补测 VIMacU 数据成形拍 | **VDotTop 成立；VIMacU 的 546 笔是循环论证**（I-2） |
| P7「基线 25924 条逐位相同」 | GCC 15 重编 + 重跑 | **成立** |
| P7「CSV 均来自日志」 | 用 `collect_results.py` 从日志重新生成 | **成立**（9/9 逐字节相同） |
| P7「动态指令数 2575 / 2061」 | 重跑 | 绝对值依赖编译器：GCC 15 下每个点都 **+2**（2577 / 2063）；**斜率不变**（M-8） |
| 「G5b 只有协同仿真能发现」 | 查 P6 之前的设计文档历史 | **过强**（M-3） |

### 4.1 `文件:行号` 引用抽样（共 112 处）

| 范围 | 抽样数 | 命中 | 差 1–2 行 | 指错 | 指向不存在的代码 / 日志行 |
|---|---:|---:|---:|---:|---:|
| `20` → NEMU 源码 | 46 | 37 | 8（`decode.c:128→129`、`vcommon.c:95→96`、`vcompute_impl.c:1571→1572`、`:1007-1008→1009-1010`、`rvv/decode.h:41→39`、`ref_defconfig:190→191`（patch 后）、`vdot.c:204`（应为 192/200）、`isa-def.h:92→96`） | 1（`20:497` `refproxy.h:313-317`，应为 274-278） | 0 |
| `20` → P5 日志 | 10 | 10 | 0 | 0 | 0 |
| `21` → difftest / XiangShan / NEMU | 32 | 30 | 1（`DecodeUnitComp.scala:199→198`） | 1（`21:713` `vdot.c:102/125/130/148/187` 为 S-7' 之前的行号） | 0 |
| `21` → `p6_build.log` | 6 | 0 | 0 | 0 | **6**（I-1） |
| `22` + README → 源码 / 日志 | 18 | 13 | 0 | 5（VecDecoder 实现树基准，M-5） | 0 |

---

## 5. 问题清单

### 阻塞（0 项）

没有发现伪造数据、不可复现的结论或语义错误。

### 重要（4 项）

**I-1　协同仿真报告引用的 `p6_build.log` 行号在任何一版日志里都不存在**
- 位置：`docs/stage3/21_协同仿真验证报告.md:93`（「`p6_build.log:15` `ELF 64-bit LSB shared object, ARM aarch64`」）、`:99`（「`p6_build.log:64`」）、`:247-255`（§3.4 列出 `:6` patch 已应用、`:8` `103:#define CONFIG_CUSTOM_XVDOT 1`、`:15` aarch64 `.so`、`:16` `vdot.o`、`:17-21` `nm -D` 导出符号）。
- 事实：`logs/stage3/cosim/p6_build.log` 只有 50 行，`[1]` 段在 `:4` 写着「已存在且比 vdot.c 新，跳过重建」，**没有** patch 状态、autoconf、`file`、`nm` 这几类输出，`grep 'shared object\|nm -D\|CONFIG_CUSTOM_XVDOT'` 零命中。我又用 `git show fe0e6cf:logs/stage3/cosim/p6_build.log` 查了首次提交的版本：47 行，同样是跳过重建。**这些行从未存在过。**
- 结论本身属实：我在本机构建的 `-so` 有 `CONFIG_CUSTOM_XVDOT`（`autoconf.h:103`），T3-NEMU-1 也证明 `.so` 跑的是 `vdot.c`；`p5_nemu_build.log:45,143,145` 里有对应的真实输出。因此定级为「证据引用错误」，不是「伪造」。这与阶段一、阶段二 I-1 属同一类缺陷。
- 修复：把 §2.1 / §3.4 改为引用 `logs/stage3/p5_nemu_build.log:45,143,145`；或用 `FORCE_NEMU=1` 重跑 `30_run_cosim.sh`，让 `p6_build.log` 真正包含这些行后再引用。

**I-2　陷阱 #6 在 `VIMacU` 直驱上再次出现：「546 笔全部 2 拍」中的 `out.valid` 由 harness 按 `VimacCfg.latency` 产生**
- 位置：`tests/unit/vimacu_latency_tb.cpp:11-14`（「所以这里测到的就是这条功能单元在昆明湖 V2 流水线里的真实延迟」）；`docs/stage3/22_基线实现与延迟加速分析.md` §4.3（`:359`「`io.outValid` 直接来自 `VIMacU` 自己的 `io.out.valid`」）、§7.2 表（「既有指令…一拍没慢（实测）」）、§9.1 第 3 行（用 546 笔回应「统计量小」）、§12 第 2 条；`README.md:45`；`bench/results/latency_fu.csv` 的 vdot / vmul / vwmul / vmacc 行。
- 事实：`VIMacUHarness.scala:116` `nLat = VimacCfg.latency.latencyVal.get`，`:123-125` 用 `RegNext` 搭出 `vPipe`；`FuncUnit` 的 `out.valid = validPipe(nLat) & validVecThisFu(nLat)`。我在本机生成的网表里看到 `VIMacUHarness.v:4181` `assign io_out_valid = io_in_bits_validPipe_2 & validVecThisFu_2`，`:4252-4253` `vPipe_1_REG <= io_valid; vPipe_2_REG <= vPipe_1_REG`。也就是说 `out.valid` 是 `io_valid` 经过两级 harness 寄存器的结果，与 DUT 数据通路无关，**按构造恒为 2 拍**。上游 `vmul` / `vwmul` / `vmacc` 的「实测 2 拍」同理，只是重复了声明值。`VecFuLatHarness` 为此另加了「数据成形拍」一列，`VIMacU` 却没有加。
- 真正成立的部分：①数据在第 2 拍被采样时逐位正确（≤2）；②L1 `VDotTop` 的 VCD 内部信号显示第 1 拍尚未成形（这部分**不是**循环论证，我独立核实过）。我对 `VIMacU` 补测了数据成形拍（给 tb 加了第 1 拍采样，`/tmp/audit3/vimacu/aud_tb.cpp`）：**545/642 笔第 1 拍尚未成形**，97 笔第 1 拍输出恰好已等于终值（未逐笔归因，推测是 `vl=0`、全掩码等直通情形）。结论「=2」大体成立，但交付物没有提供这一证据。
- 修复：给 `vimacu_latency_tb.cpp` 加数据成形拍统计（只统计终值不等于 `oldVd` 的事务），并把注释和文档 §4.3 / §7.2 / §9.1 / §12 改为「`out.valid` 由 harness 按 `VimacCfg.latency` 产生；实测的是第 2 拍数据正确、第 1 拍数据未成形」。`vmul` / `vmacc` 也应加数值或成形校验，否则不应标「实测」。

**I-3　故障注入 T3-RTL-1 被误描述为「写回结果 bit0 翻转」**
- 位置：`docs/stage3/21_协同仿真验证报告.md:565`（表格「写回结果 **bit0 翻转**」）、`:577`（「能检出 RTL 侧与 NEMU 侧的一位错误」）、`scripts/30_run_cosim.sh:248-249`。
- 事实：注入是把 `assign io_vd =` 替换成 `assign io_vd = 128'h1 ^`，而生成的 `VDotTop.sv:1409-1410` 是 `assign io_vd = isDot4aS2 ? {...} : ...`。Verilog 中 `^` 的优先级高于 `?:`，所以实际变成 `(128'h1 ^ isDot4aS2) ? … : …`：**选择信号取反，vdot4a 与归约两种输出格式互换**，并不是结果的 bit0 翻转。日志本身就留着证据：`p6_fault_injection.log:17-28` 的 Verilator `WIDTHEXPAND`（XOR 右侧只有 1 位）和 `WIDTHTRUNC`（条件表达式是 128 位）警告。我本机对照：团队的注入 → 5116/6378 FAIL（与存档相同）；加括号做真正的 bit0 翻转 → **6378/6378** FAIL。
- 影响：P6-4 仍由 T3-RTL-2（真正的一位改动，586 条被检出）满足，检出结论不变；但表格对注入内容的描述是错的。
- 修复：把注入改为 `assign io_vd = 128'h1 ^ (` … `);`，或把文档描述改为「输出格式选择取反」，然后重跑并更新日志。

**I-4　P5/P6/P7 一键脚本在 Linux 上无法运行，`work/XiangShan-cosim` 也没有任何脚本负责创建**
- 位置：`scripts/21_build_nemu_vdot.sh:233-238`、`scripts/30_run_cosim.sh:35,58-63`、`scripts/40_run_bench.sh:41,77,83` 硬编码 `docker run --platform linux/arm64` 和镜像 `xsdev:ubuntu24.04-arm64`，容器内路径写死 `/work`；`30`/`40` 和 `run_vimacu_latency.sh`、`run_vecfu_latency.sh` 都 `source scripts/env_host.sh`，而这个**已提交**的文件写的是 `/opt/homebrew/opt/openjdk@17` 和 `/Users/i3eg1nner/...`；`30` / `40` 依赖的 `work/XiangShan-cosim`（kmhv2 + `rtl/patch/0001` + `0002` + `tests/unit/yunsuan_vdot_testbench.patch`）在全仓库**没有任何脚本创建**，`00_setup_env_host.sh` 只克隆 `XiangShan-kmhv2` 和 `NEMU`。
- 与交接文档矛盾：`docs/_plan/HANDOFF_TODO.md` 第二节把 `21/30/40` 标为「✅ Linux 可用」。实际上即使装了 Docker，arm64 镜像在 x86_64 上也只能走 QEMU 模拟。
- 其它 Linux 依赖没有写进文档：NEMU 需要 `libreadline-dev`、`libsdl2-dev`；Ubuntu 22.04 自带的 `riscv64-linux-gnu-gcc` 11.4 不认 `-march=rv64gcv_zve64x`，需要 GCC ≥ 12（我用的是 `/opt/riscv` 下的 GCC 15.2）；`corpus.S:12` 写死 `build/corpus.bin`，所以 `BUILD=` 变量无效。
- 正面结论：我按脚本内的命令手工执行，**每一步都在 Linux 上跑通了**（§6），数据完全可复现。问题出在包装层，而这正是评委第一眼会碰到的。
- 修复：脚本增加「`docker` 不可用或非 arm64 时直接在宿主机执行」分支，镜像和平台可配置；`env_host.sh` 不要入库，或改成按平台生成；新增 `scripts/tools/make_cosim_tree.sh`（复制 kmhv2 并按顺序打三份补丁），由 `30`/`40` 在树不存在时调用；在 README 写明 Linux 依赖。

### 次要（9 项）

**M-1　「未改动的 DecodeUnit / VecExceptionGen」措辞错误**
`21:106`（§2.2「内部串接**未改动的** `DecodeUnit` 与 `VecExceptionGen`」）和 `docs/00_项目总览.md:78`（「含**上游未改动的** `VecExceptionGen`」）不对：`rtl/patch/0001-xiangshan-vdot.patch` 同时修改了 `DecodeUnit.scala` 和 `VecExceptionGen.scala`（新增 `dotEewIllegal`、`dotEmulIllegal`）。准确说法是「其中 `vstartIllegal` 这一判据是上游原有、未改动的」。

**M-2　协同仿真报告 §10.3 有两处陈旧内容**
`21:714` 写「香山译码侧目前对 LMUL≠1 不报非法，这是一个**已定位的缺口**」，与同文 §7.4（已收敛，6000/6000 一致）矛盾；`21:713` 的 `vdot.c:102/125/130/148/187` 是 S-7' 之前的行号，当前应为 `108/136/168/207`。

**M-3　「只有 NEMU↔RTL 协同仿真能发现 G5b」表述过强**
`21` §7.5 标题、`:542`（「我们在写裁定时没有纳入考虑的**平台事实**」）、§0（「这类冲突，自写黄金模型永远发现不了」）。但在 P6 之前的版本（`git show fe0e6cf~1:docs/stage2/10_vdot指令设计文档.md` 的 `:246` 与 `:1390` 裁定 R-06）里，设计文档已经**明确识别**出 `vstartIllegal` 会挡掉 vdot4a 的 `vstart≠0`，当时把它登记为「全核不可达」。`docs/00_项目总览.md:74` 也如实承认了这一点。协同仿真真正贡献的是：证明这一已知偏差在全核 difftest 上会**确定性地报 mismatch**（即 R-06 的「不可达」判断是错的），并给出定量结果。建议据此改写表述。

**M-4　「2.00× 是对基线友好的下界」与自己的敏感性表矛盾**
`22:496` 和 `22:689` 称 2.00× 是下界；同文 §6 和 `sensitivity.csv` 里有三种情形低于 2.00×（vsetvli 花 1 拍 1.67×、vdot 退化为 3 拍 1.33×、退化为 4 拍 1.00×）。2.00× 只在假设④（多 uop 并行）这一维上是下界。README `:55` 的「敏感性区间 1.00×–5.00×」表述正确，22 应与之一致。

**M-5　`22` 的 `VecDecoder.scala` 行号用的是实现树基准，但没有声明**
`22:386-390` 的 `:466/:430/:436/:244/:419` 只在实现树上命中（pristine 是 `457/421/427/243/410`），而同表的 `FuConfig` / `UopInfoGen` 行号两棵树相同。这与阶段二 M-1 同类，建议在文首声明行号基准。

**M-6　`20` 中的陈旧数字**
`20:242` 写 blob 2 702 952 字节、`:251` 写镜像 2 709 128 字节，日志里是 2 707 176（`p5_vdot_tests.log:28`）和 2 713 352（`:33`）；`20:237-247` 的行数表中 `pack_corpus.py` 167→171、`gen_extra_vectors.py` 125→139、`fault_inject.sh` 173→202；`20:497` 的 `refproxy.h:313-317` 应为 `274-278`（`21:669` 写对了）；另有 8 处 NEMU 行号差 1–2 行（见 §4.1）。

**M-7　延迟日志打印的「声明值来源」实为标量乘法器的配置**
`p7_latency_measure.log:203-204` 在「声明值来源 : FuConfig.scala:563」下面打印的是 `FuConfig.scala:334`，而第 334 行属于 `MulCfg`（标量整数乘法器），不是 `VimacCfg`。原因是 `run_vimacu_latency.sh` 用 `grep … | sed -n '2p'` 取第 2 个匹配。数值碰巧同为 2，但打印出来的证据行是错的。

**M-8　测量程序输出中写死了常量；动态指令数的绝对值依赖编译器**
`tests/riscv/baseline/baseline_test.c:648,651` 把 `static_instr` 列直接写成字符串常量 `",12"` 和 `",7"` 输出到 CSVROW，看起来像测量结果（日志 `:59-60` 由 awk 真实计算出的 12 / 7 与之一致）。此外，`minstret` 差值包含调用点开销：我用 GCC 15 重编后，**每个点都 +2**（例如 2577 / 2063），N=64 的加速比由 1.222× 变为 1.213×。斜率 10/11/10/8/9 不变。文档应注明绝对值依赖工具链，结论以斜率为准。

**M-9　3.00×（2 路累加器）对应的代码并未交付**
`22:551`、`:794` 和 README `:53` 中「2 路累加器轮转时 3.00×」所描述的代码不存在：交付的 `bench/baseline/baseline_rvv.S` 里 `vdot_dot_i8` 只用单累加器 `v8`，2 路展开的版本既没有实现也没有做等价性验证。该数字已标为建模，但应说明「尚无对应实现」。

### 提示（不计入问题）
- 图 2(a) 中 N=4096 的标注「1.110」与「1.0 = 没有加速」文字重叠（`fig2_speedup.png` 右下角），属排版问题；数值本身正确。
- L1 平台上 `vdot.io_fire` 在每笔事务中保持高电平约 3 拍（VCD `#21–#27`），不是单拍脉冲。这不影响「第 1 拍未成形、第 2 拍成形」的判读，但说明 L1 没有覆盖单拍 `fire` 的使用方式（`21` G2「背靠背」缺口的另一面）。
- 审计期间他方提交了 `b5a07b6`（补齐波形 PNG），本报告已按该版本判定。

---

## 6. 复现记录（实际执行的命令与结果）

```
R0  work/ 不存在 → 新建
    git clone NEMU (master) && checkout 9090839
    git clone XiangShan (kunminghu-v2) && checkout a4eeaab && submodule update --init --recursive
      子模块 pin：difftest 3729300、yunsuan 9559211、utility 2f0743f、fudian e1bd469 … 与文档一致
R1  NEMU：git apply --check --verbose 0001-add-vdot-instruction-family.patch → 8/8 OK；numstat +278/-1
R2  NEMU 构建（x86_64，GCC 11.4 宿主）：缺 readline/SDL2 头文件
    → apt-get download libreadline-dev libncurses-dev libsdl2-dev libsdl2-2.0-0 libpulse0 libdecor-0-0
      libsndfile1 libasyncns0 libflac8 libogg0 libvorbis0a libvorbisenc2 libopus0，dpkg -x 到 /tmp/audit3/sysroot
    → CFLAGS=-I… LDFLAGS=-L… make riscv64-xs-kmhv2_defconfig && make -j64     → riscv64-nemu-interpreter
    → make riscv64-xs-kmhv2-ref_defconfig && make -j64                         → riscv64-nemu-interpreter-so
    → make -C tools/ref-so-runner                                              → runner
R3  P5 语料：复制 tests/riscv/vdot 到 /tmp（corpus.S 写死 build/），CROSS=/opt/riscv/bin/riscv64-unknown-elf-（GCC 15.2）
    interpreter：TOTAL 30758 pass 30758 fail 0；must-trap 4834/4834；HIT GOOD TRAP；vst count 30758
    ref-so-runner：HIT GOOD TRAP / trap code:0；vst count 30758
R4  P5 故障注入：bash fault_inject.sh → 21103/12079/10173/3202/等价/1584，5/5 + 还原 PASS（与存档逐数相同）
    审计者补 4 项（4i+j→i+4j / 去 tail / vdotacc 不读 vd / 去 vma）→ 6161/8202/8066/1334 FAIL；vdot.c md5 还原
R5  语料：cc vdot_cli + gen_vectors.py --outdir /tmp → 13/13 与 tests/vectors 逐字节相同
    独立模型 indep_model.py：checked 30650 mismatch 0
R6  XiangShan-cosim = cp -a kmhv2 + git apply rtl/patch/0001（XS）、0002 + tests/unit/yunsuan_vdot_testbench.patch（yunsuan）→ 全部干净应用
    mill -i YunSuan.runMain …VerilogVDotTop                       → VDotTop.sv（69 s，首次含下载 mill 0.11.1）
    mill -i xiangshan.test.runMain …VdotDecodeProbeMain             → VdotDecodeProbe.v（171 s，860 target 冷编译）
    verilator 5.024 --cc ×2；g++ 编译 tests/cosim 副本（/tmp/audit3/cosim）
R7  P6 全量：./cosim --so … 全部定向 + --random 10000 --illegal 3000 --seed 20260324
    → 72758 / 值 55924 PASS 0 FAIL / 分歧 0；分 suite 汇总与 p6_cosim_run.log diff 为空（2.3 s）
R8  P6 故障注入（/tmp/audit3/p6_fault.sh）：BASE 6378/0；T3-RTL-1 5116；真正 bit0 翻转 6378；T3-RTL-2 586；
    T3-NEMU-1 4944；T3-NEMU-2 分歧 162；T3-NEMU-3 分歧 74；去 vdot4a vma 313；还原后 cmp 一致且复测 PASS
R9  P7 [1]：tests/riscv/baseline（GCC 15）在本机 NEMU 上运行 → [A] 25924/0，[B] 24/0，[A0] 与存档相同；
    [C] 绝对值各 +2，斜率不变；静态 12/7（awk 计数）
R10 P7 [2]：make -C yunsuan emu EMU_TRACE=1（48 s）→ 抓 3 份 VCD；自写 vcdcheck.py：12×3 笔都在第 2 个上升沿成形，
    值与独立模型一致；存档 VCD 用同一方法核对，结果相同
R11 P7 [3]：精化 VIMacUHarness（22 s）、verilate、运行 → 178/178/190 与 64×3，与 p7_latency_measure.log:221-229 相同
    网表核查：VIMacUHarness.v:4181/4252-4253/4349（out.valid 来自 harness 寄存器链）
    补测数据成形拍（aud_tb.cpp）：第 1 拍未成形 545/642，已等于终值 97/642
R12 P7 [4]：精化 VIAluFixHarness / VIPUHarness、verilate、运行 → 1/1/1 与 2/2 拍，数据成形同拍，与存档相同
R13 python3 bench/collect_results.py --equiv-log … --latency-log … --out /tmp → 9/9 CSV 逐字节相同
    plot_results.py：本机无 matplotlib，未重新渲染；图 2 数值人工复算一致
R14 终态：交付仓库 git status --short 为空；未写 logs/、bench/results/；work/ 内注入均已 cmp 还原
```

---

## 7. 赛题条款完备性

| 赛题条款 | 交付物 | 完备性判断 |
|---|---|---|
| 3.1.1 NEMU 指令扩展 | `nemu/patch/`、`docs/stage3/20`、`scripts/21` | **完备**。补丁干净；语义与独立模型逐条一致；故障注入有效；异构平台可复现 |
| 3.1.2 协同仿真验证 | `tests/cosim/`、`docs/stage3/21`、`scripts/30` | **完备（Level 1）**。REF 为真实 NEMU `.so`，已实证；全链路异构平台复现；全核 difftest 未做，已披露（I-1、I-3 需整改） |
| 3.2 基线功能实现 | `bench/baseline/`、`tests/riscv/baseline/` | **完备** |
| 3.3 延迟加速分析 | `docs/stage3/22`、`bench/results/`、`docs/stage3/figures/` | **基本完备**。口径区分清楚；`VIMacU` 延迟证据存在循环论证（I-2）；吞吐只有建模值，已披露 |

**阶段三交付物完成度（25 分）预测：20 / 25**（优秀区间下部）。扣分主要来自：全核 difftest 缺位、吞吐只有建模值（−3）；I-1 至 I-4（−2）。
I-1 至 I-3 合计约 1 小时即可整改；I-4 需要半天，但它直接决定评委能否一键复现，建议优先处理。

---

## 8. 整改记录（审计后追加，以上正文未改动）

| 项 | 值 |
|---|---|
| 整改依据 | 本报告 §5（阻塞 0、重要 4、次要 9）与 §5「提示」 |
| 整改提交 | `8b28fcb`（I-1/I-3/M-1/M-2/M-3/M-6）、`87de89b`（I-2/M-4/M-5/M-7/M-8/M-9 与 `latency_fu.csv` 措辞）、`73722be`（I-4）、`b7a5e81`（I-4 收尾与 I-2 同类表述的清理）；之后的文档同步见本节末「后续跟进」 |
| 核验原则 | 下表「现位置」一列逐条在当前工作树中打开核对过；行号以追加本节时的文件为准，之后的修订可能使其偏移 |
| 未改动 | 本报告 §0–§7 正文（审计记录）；所有存档日志只追加或按段替换并注明原因，未删改既有段落之外的内容 |

### 8.1 重要级（4 项）

| # | 整改提交 | 做了什么 | 现位置（核验点） |
|---|---|---|---|
| **I-1** | `8b28fcb` | 删去 `p6_build.log` 中不存在的行号引用，`.so` 构建证据改引真实存在的 `p5_nemu_build.log`；`p6_build.log` 只引其真实内容（`:4-6` 跳过重建、`:45-50` 编译） | `docs/stage3/21_协同仿真验证报告.md:106-107`（§2.1）、`:268-269`（§3.4 证据块：`p5_nemu_build.log:45` `CONFIG_CUSTOM_XVDOT`、`:143` aarch64 `.so`） |
| **I-2** | `87de89b`、`b7a5e81` | `vimacu_latency_tb.cpp` 新增不读 `out.valid` 的数据成形拍测量（下界型，扰动前驱排除残留值），`out.valid` 明确标为平台构造值；`p7_latency_measure.log` [3] 段按新 tb 重跑替换并注明原因；`22` §4.3 / §7.2 / §9.1 / §12、README 改为「第 1 拍未成形、第 2 拍逐位正确」口径；`b7a5e81` 把 `VecFuLatHarness.scala`、`docs/stage2/10`、`12` 中同类表述一并改正 | `tests/unit/vimacu_latency_tb.cpp:7-25`；`logs/stage3/p7_latency_measure.log:190-197`（[3] 段替换说明）；`docs/stage3/22_基线实现与延迟加速分析.md:401`、`:724`、`:771`；`README.md:45` |
| **I-3** | `8b28fcb`、`73722be` | 文档把 T3-RTL-1 更正为「输出格式选择取反」；新增私有副本补充重跑（`scripts/tools/cosim_fault_rtl1_rerun.sh`），真正的 bit0 翻转 6378/6378 被检出；`73722be` 把加括号的 bit0 翻转作为 T3-RTL-1b 并入 `30_run_cosim.sh fault`（6 项） | `docs/stage3/21_协同仿真验证报告.md:587-648`（§8）；`scripts/30_run_cosim.sh:251-256`（T3-RTL-1 更名与说明）、`:270-292`（T3-RTL-1b）；`logs/stage3/cosim/p6_fault_rtl1_rerun.log:41-58` |
| **I-4** | `73722be`、`b7a5e81` | 新增 `scripts/lib/common.sh`（路径、平台判别、`XS_RUNNER=auto`：Linux 宿主机直接执行，macOS 进容器）与 `scripts/04_make_vdot_trees.sh`（按补丁生成 `XiangShan-vdot` / `XiangShan-cosim`）；00–40 号脚本与 `env_host.sh` 去掉写死的 arm64 镜像、`/work` 与 macOS 绝对路径；`corpus.S` 改为 `.incbin CORPUS_BIN`；README 写明 Linux 依赖；在全新目录按 00→40 实测通过 | `scripts/lib/common.sh:68-72`；`scripts/04_make_vdot_trees.sh:1-3`；`docs/_plan/HANDOFF_TODO.md:59-77`（脚本适用性表，按 Linux x86_64 实测重写）；`README.md:119-123`（Linux 依赖） |

### 8.2 次要级（9 项）

| # | 整改提交 | 做了什么 | 现位置（核验点） |
|---|---|---|---|
| M-1 | `8b28fcb` | 改为「两个文件都带本项目补丁，其中 `vstartIllegal` 判据是上游原有、未改动的」 | `docs/stage3/21_协同仿真验证报告.md:121`；`docs/00_项目总览.md:79` |
| M-2 | `8b28fcb` | 删去「已定位的缺口」这一陈旧结论；`vdot.c` 行号更新为 S-7' 之后的 `108/136/168/207` | `docs/stage3/21_协同仿真验证报告.md:780` |
| M-3 | `8b28fcb` | 改述为「设计阶段 R-06 已识别，协同仿真首次量化为 1946 条确定性分歧并迫使裁定修订」 | `docs/stage3/21_协同仿真验证报告.md:33`（§0 说明）、`:548`（§7.5 标题）、`:572` |
| M-4 | `87de89b` | 改为「2.00× 只在假设④这一维上是下界」，并列出低于 2.00× 的三种情形与 1.00×–5.00× 区间 | `docs/stage3/22_基线实现与延迟加速分析.md:564-566` |
| M-5 | `87de89b` | 文首声明源码行号基准；`VecDecoder.scala` 行号同时给出 pristine 与实现树 | `docs/stage3/22_基线实现与延迟加速分析.md:7-11` |
| M-6 | `8b28fcb` | blob / 镜像大小改为日志值 2 707 176 / 2 713 352；行数表更新（`pack_corpus.py` 171、`gen_extra_vectors.py` 139、`fault_inject.sh` 202）；`refproxy.h` 引用改为 `274-278` | `docs/stage3/20_NEMU指令扩展说明.md:239-251`、`:497` |
| M-7 | `87de89b` | `run_vimacu_latency.sh` 改为在 `val VimacCfg` 定义块内定位 latency 行，不再取第 2 个 grep 匹配 | `scripts/tools/run_vimacu_latency.sh:56-61` |
| M-8 | `87de89b`、`73722be` | `baseline_test.c` 的 `static_instr` 改为运行时从函数入口逐条解码到 `ret` 计数；`22` 注明 `minstret` 绝对值依赖编译器（GCC 15 每点 +2，斜率不变），补充日志 `p7_baseline_gcc15_supplement.log` | `tests/riscv/baseline/baseline_test.c:683`；`docs/stage3/22_基线实现与延迟加速分析.md:576-581` |
| M-9 | `87de89b` | 交付 2 路累加器内核 `vdot_dot_i8_acc2` 并在 NEMU 上实测等价性（24 个长度 0 失配）与指令数（斜率 8.00）；周期数仍标为建模 | `bench/baseline/baseline_rvv.S:212`；`docs/stage3/22_基线实现与延迟加速分析.md:637-642`；`logs/stage3/p7_baseline_gcc15_supplement.log:118-142,170-173` |

### 8.3 提示项与排除项

| 事项 | 处理 |
|---|---|
| `latency_fu.csv`「数值比对 0 笔一致」措辞（排除项） | `87de89b`：未做数值比对的行改为「数值未建模（未做数值比对）」（`bench/results/latency_fu.csv:6-7`） |
| 图 2(a) N=4096 标注与「1.0 = 没有加速」文字重叠 | `87de89b` 重绘图 1–4 时一并调整（`bench/plot_results.py` 中该文字已移到左侧） |
| L1 平台 `io_fire` 持续约 3 拍 | 属平台特性说明，未改动 |

### 8.4 后续跟进（整改提交之后发现的跨文档不一致）

- 协同仿真故障注入的现行口径统一为 **6/6**（RTL 侧 3、NEMU 侧 3，T3-RTL-1b 为补充项）：按现行脚本在独立工作目录重跑 `30_run_cosim.sh fault`，日志存为 `logs/stage3/cosim/p6_fault_injection_v2.log`（`:350` 为 `FAULT-INJECTION: 6/6 被检出`），存档的 `p6_fault_injection.log`（5/5）保留未覆盖；`21` §8、README、`docs/00` 已同步。
- `tests/unit/vecfu_latency_tb.cpp` 的打印文案把 `out.valid` 标为 harness 构造值（与 I-2 同类），`p7_latency_measure.log` [4] 段按新 tb 重跑替换并注明原因（`:293-300`），CSV 重新生成后 9 个文件逐字节不变。
- 审计 §7 列为扣分点的「全核 difftest 缺位」：之后已补做 MinimalConfig 全核 difftest（提交 `057ef76`，`docs/stage3/23_全核difftest验证报告.md`，日志 `logs/stage3/fullcore/`）；`21`、`22`、`02`、README、`docs/00`、`HANDOFF_TODO.md` 与 `docs/ppt/` 已同步口径。是否据此回收分数未经复审；默认配置未运行、吞吐仍为建模值。
