# 23 全核 difftest 验证报告（HANDOFF T1）

| 项 | 值 |
|---|---|
| 对应赛题 | **阶段三 3.1.2 NEMU 与 RTL 协同仿真**（全核层级，Level 2） |
| 对应计划 | `docs/_plan/HANDOFF_TODO.md` T1 |
| DUT | 香山昆明湖V2 全核 `MinimalConfig`，Verilator emu（带 difftest）。工作树 `work/XiangShan-fullcore` = `work/XiangShan-kmhv2`（`a4eeaab`）副本 + `rtl/patch/0001-xiangshan-vdot.patch` + `rtl/patch/0002-yunsuan-vdot.patch` |
| REF | `work/NEMU-fullcore`（`work/NEMU` 的私有副本，`9090839` + `nemu/patch/0001-add-vdot-instruction-family.patch`），`riscv64-xs-kmhv2-ref_defconfig` 构建的 `riscv64-nemu-interpreter-so` |
| 一键复现 | `scripts/50_run_fullcore_difftest.sh`（`build` / `run` / `wave` / `fault`） |
| 测试程序 | `tests/riscv/fullcore/` |
| 日志 | `logs/stage3/fullcore/` |
| 执行环境 | Ubuntu 22.04 x86_64，128 核，约 1 TB 内存；Verilator 5.024；OpenJDK 17.0.20；clang++ 14；交叉 GCC 15.2（`/opt/riscv`） |

---

## 0. 结论速览

| 验收项（HANDOFF T1） | 结果 | 证据 |
|---|---|---|
| 全核 emu 构建（带 difftest） | **完成**。MinimalConfig，有效耗时约 23 分钟（精化 8:29 + verilate 12:57 + C++ 1:42），峰值内存 56.4 GiB（约 60.6 GB，Verilator 前端） | `build_time_breakdown.log:8,13,34,39,90`；`build_emu_3.log:38,57` |
| 全部语料 0 mismatch | **完成**。30758 条（全部定向 + 3×10000 随机 + 55 条补充定向），其中 4834 条应 trap，6 批全部 HIT GOOD TRAP，difftest 失配 0 | `summary.log:1-9` |
| 背靠背依赖（Level 1 证明不了的部分） | **完成**。10 个依赖内核 × 4 个随机种子 × 200 次迭代 × (背靠背 + fence 隔离) = 16000 次内核调用，自洽比较 0 失败，difftest 失配 0，4 次均 HIT GOOD TRAP | `summary.log:10-37`；`dep0.log:9-22` |
| 异常投递与 mcause | **完成**。4834 条非法用例在全核上全部 trap 且 mcause=2；流水线中（前后有依赖指令）插入的非法 vdot/vdot4a/vstart≠0 每次恰好 trap 3 次（K8，`k8-trap-count-bad=0`）；REF 侧独立执行判定，CSR 每条提交比对 | `summary.log:8,12`；§2.2 |
| 故障注入 | **完成**。VIMacU 的 vdot 结果 bit0 翻转后，3 个程序在**第一条** vdot 提交处被 difftest 中止（`v3_low` right/wrong 只差 bit0）；源码还原后与全核树逐字节一致 | `fault_summary.log:1-5` |
| 全核波形（译码 → ROB 提交） | **完成**。文本轨迹 + 时序图；VCD 382 MB 不入库 | `wave_trace.txt:155-192`；`wave_fullcore_vdot.png`（嵌入 §7 图 8） |
| Level 1 等价性论证是否成立 | **成立，且其 4 个缺口中的 G1–G4 已在全核上实测闭合**（§8） | §8 |
| 发现 RTL / NEMU 补丁缺陷 | **未发现**。`rtl/patch/`、`nemu/patch/` 均未改动 | — |

一句话：**打了 vdot 补丁的昆明湖V2 全核与打了 vdot 补丁的 NEMU 在 24,517,314 条逐条提交比对（27,090,115 个周期）上 0 失配；vdot 指令族在乱序流水线中的发射、物理寄存器旁路、提交与异常投递均与 NEMU 一致。**

---

## 1. 为什么要做，以及与 Level 1 的关系

`docs/stage3/21_协同仿真验证报告.md` 的 Level 1 方案把全核 difftest 的 REF 侧（真实 NEMU `.so`）原样搬过来，DUT 换成「vdot 功能单元 `VDotTop` + 香山译码单元」。它能回答「一条 vdot 应该算出什么、该不该报非法」，但它自己在 §10.3、§11.2 中承认回答不了：

* **G1** 写回成形逻辑在 `VIMacU`（全核里真正挂进流水线的 FU）和 `VDotTop`（Level 1 的 DUT）里是两份代码，Level 1 只验了后者；
* **G2** 没有背靠背流量；
* **G3** `vcsr` / `mstatus.VS` 不比对；
* **G4** 异常只验到译码打标，没有经过 ROB 投递。

本报告用真正的全核 difftest（Level 2）逐条回答这四个问题，结论见 §8。

---

## 2. 方法

### 2.1 链路

```
tests/riscv/fullcore/*.bin ──┬──> XiangShan-fullcore/build/emu（DUT：全核 RTL，Verilator 16 线程）
                             │        每拍把提交信息、架构寄存器、CSR、访存事件经 DPI 交给 difftest
                             └──> NEMU-fullcore/ref/riscv64-nemu-interpreter-so（REF，dlopen）
                                      DUT 每提交一条，REF 执行一条，随后整体比对
```

命令行：`emu -i <镜像> --diff <ref .so>`（`scripts/50_run_fullcore_difftest.sh` 中 `run_emu()`）。

### 2.2 difftest 比了什么（源码依据）

| 比对项 | 依据 |
|---|---|
| 整数 / 浮点 / **向量**架构寄存器堆、**向量 CSR**（`vstart vxsat vxrm vcsr vl vtype vlenb`）、H 扩展 CSR、普通 CSR（含 `mstatus mcause mepc mtval`） | `work/XiangShan-fullcore/difftest/src/test/csrc/difftest/refproxy.cpp:185-230`（`RefProxy::compare`，逐块 `memcmp`）；本次构建生成的 `build/generated-src/difftest-state.h:181-189`（`DifftestVecCSRState`）、`:249-252`（`DifftestArchVecRegState`，64×u64 = 32 个 128 位寄存器） |
| CSR 失配的豁免规则 | `refproxy.cpp:320-337`：只在 `CPU_ROCKET_CHIP` 下对 `mtval/stval/mtvec/stvec` 豁免，香山不适用 |
| **异常**：DUT 报出非法指令异常时，REF 不是被强制陷入，而是 `ref_exec(1)` **自己执行**那条指令 | `difftest/src/test/csrc/difftest/checkers/traps.cpp:81-106`：只有页错误 / 硬件错误类（`EX_IPF…EX_HWE`）走 `force_raise_exception`，其余（含 cause=2）走 `proxy->ref_exec(1)` |

第三行是异常比对有效的关键：若 RTL 判非法而 NEMU 判合法（或反之），两边的 `pc` / `mcause` / `mepc` / `vd` 会立即分叉并被 `compare` 捕获。

### 2.3 工作树与 NEMU

* 全核树 `work/XiangShan-fullcore` 由 kmhv2 基线 `rsync`（排除 `out/ build/`）后 `git checkout -- .`，再 `git apply` 两份补丁（`scripts/50_run_fullcore_difftest.sh` 的 `make_tree()`）。没有应用 `tests/unit/yunsuan_vdot_testbench.patch`（只影响 yunsuan 的 L1 测试平台，与全核无关）。收尾时核对：`git apply --check --reverse` 两份补丁均通过，kmhv2 基线 `git status` 为空。
* NEMU 用私有副本 `work/NEMU-fullcore`（`rsync` 自 `work/NEMU`），避免改动共享 `.config`（陷阱清单第 3 条）。`.so` 拷到 `work/NEMU-fullcore/ref/`，与同一副本里后续构建的解释器形态互不覆盖。补丁状态由 `git apply --check --reverse nemu/patch/0001-*.patch` 确认（`run_driver.log` 中「vdot 补丁已处于已应用状态」）。

---

## 3. 配置选择与构建

### 3.1 为什么选 `MinimalConfig`，它对结论有什么影响

kunminghu-v2 提供 `MinimalConfig`（`work/XiangShan-fullcore/src/main/scala/top/Configs.scala:68`）。它也是上游 CI 构建 emu 的配置（`.github/workflows/emu.yml:89-92`）。与默认配置的差别：

| 项 | MinimalConfig | 默认（`Parameters.scala`） | 对 vdot 结论的影响 |
|---|---|---|---|
| 译码 / 重命名宽度 | 6 / 6（`Configs.scala:72-73`） | 6 / 6（`Parameters.scala:149-150`） | 无 |
| ROB | 48（`Configs.scala:91`） | 160（`Parameters.scala:178`） | 只影响在飞指令数上限 |
| 整数侧发射队列 | 10（`Configs.scala:98`） | 24（`Parameters.scala:181`） | 无（vdot 走向量发射队列） |
| **向量调度器** | `vfSchdParams` 写死 `numEntries = 16/16/10`，**不随 `IssueQueueSize` 变化**（`Parameters.scala:445-466`） | 同左 | **无：两种配置的向量发射队列、FU 分组完全相同** |
| 向量物理寄存器 | 160（`Configs.scala:106`） | 128（`Parameters.scala:194`） | 只影响重命名压力 |
| `VIMacU` 所在执行单元 | `VFEX0 = {Vfma, Vialu, Vimac, Vppu}`（`Parameters.scala:449`），全核唯一一个 Vimac | 同左 | 无 |
| VLEN | 128（`Parameters.scala:60`，MinimalConfig 不改） | 128 | 无 |
| Cache / TLB / L2 / L3 | 缩小 | — | vdot 不访存；依赖测试 K6 的访存路径只是尺寸不同 |

因此：**功能结论（0 失配、异常投递、旁路正确）对默认配置同样成立的理由是：vdot 经过的译码、向量调度、VIMacU、写回、ROB 提交逻辑在两种配置下是同一份参数化 RTL，参数也相同**；ROB / 物理寄存器数目不同只改变压力而不改变数据通路。默认配置与 `KunminghuV2Config`（CHI 总线）**未实际构建运行**，§6 的周期数只对 MinimalConfig 实测有效。

### 3.2 构建命令与资源

```bash
cd work/XiangShan-fullcore
make emu CONFIG=MinimalConfig EMU_THREADS=16 EMU_TRACE=1 JVM_XMX=200G \
         WITH_CHISELDB=0 WITH_CONSTANTIN=0 CXX=clang++ LINK=clang++ -j128
```

| 阶段 | 墙钟 | 峰值 RSS | 证据 |
|---|---:|---:|---|
| mill 精化 + firtool（含首次 Scala 编译） | 8:29 | 19.5 GiB（JVM） | `build_time_breakdown.log:8,13` |
| Verilator 生成 C++（单线程前端） | 12:57 | **56.4 GiB** | `build_time_breakdown.log:34,39` |
| C++ 编译 + 链接（clang++ 14，`-j128`） | 1:40 | 4.3 GiB（单进程） | `build_time_breakdown.log:90,95`；`build_emu_3.log:38,43,57` |
| **合计（有效）** | **约 23 分钟** | 56.4 GiB | — |

说明：上表那次构建的 mill 精化与 Verilator 阶段运行期间，故障注入树（§6）的同一构建以 `nice -n 19` 并行进行，耗时偏保守。 单位说明：峰值 RSS 取自 GNU time 的 `Maximum resident set size (kbytes)`，该字段单位为 KiB（1024 字节）。例如 Verilator 前端 `59157676 kbytes`（`build_time_breakdown.log:39`）= 56.4 GiB = 约 60.6 GB（10^9 字节）；本仓库早期写作「59.2 GB」，是把该字段的 KiB 误当作 10^3 字节换算所得，已统一改为 GiB。

**脚本从零复测**：之后在独立 `WORK_DIR`（只含指向 `XiangShan-kmhv2`、`NEMU` 的符号链接）里执行 `bash scripts/50_run_fullcore_difftest.sh build`，从生成全核树、复制并构建私有 NEMU `.so` 到 emu 链接一次通过：`make emu` 墙钟 23:15、峰值 RSS 56.4 GiB（`build_emu_scripted.log:19,2429,2434,2448`），脚本总耗时 23:31（`build_scripted_driver.log` 末尾）；分阶段为精化 8:44 / verilate 12:47 / C++ 1:39。该 emu 跑 `vdot_wave.bin` 同样 HIT GOOD TRAP（`instrCnt = 35, cycleCnt = 1588`，与存档 emu 相同）。

原机器 16 GB 内存做不了的根本原因由此量化：Verilator 前端峰值 56.4 GiB（约 60.6 GB），远超 16 GB。

### 3.3 构建中真实遇到的两次失败（如实记录）

1. **g++ 不认识 clang 专有选项**。difftest 子模块（`3729300`）把 `OPT_FAST ?= -O3 -fno-slp-vectorize` 写死（`work/XiangShan-fullcore/difftest/verilator.mk:76`），该选项只有 clang 认识；Verilator 默认用 g++，于是 C++ 阶段立即失败：`build_emu.log:2421-2423`（`g++: error: unrecognized command-line option '-fno-slp-vectorize'`），`build_emu.log:2484` `exit=2`。
2. **g++ 编译超大单函数极慢**。改用 GCC 等价选项 `-fno-tree-slp-vectorize` 重编（`build_emu_2.log:3`）后，Verilator 生成的 `VSimTop___024root__DepSet_hd5918264__2.cpp`（15.9 MB，几乎全是一个函数 `nba_sequent__TOP__22`）在 g++ 11.4 `-O3` 下编译 85 分钟仍未结束。同一文件用 `clang++ -O3 -fno-slp-vectorize` 单独编译只需 1 分 48 秒，于是人工终止（`build_emu_2.log:38-61`），改用 clang++ 重编全部目标文件，1 分 42 秒完成（`build_emu_3.log`）。

两者都是环境问题（编译器选择），与 vdot 无关。一键脚本已固化为默认使用 clang++，缺少 clang++ 时退回 g++ 并告警（`scripts/50_run_fullcore_difftest.sh` 的 `build_emu_in()`）。

---

## 4. 测试程序

全部在 `tests/riscv/fullcore/`，用交叉 GCC 15.2 编译，链接地址 `0x80000000`，串口用香山 SoC 的 UARTLite `0x40600000`（`work/XiangShan-fullcore/src/main/scala/system/SoC.scala:163`），以 `nemu_trap`（`0x0000006b`，`a0` = 失败条数）结束。

### 4.1 语料批次（复用 P5 一致性测试程序，不做修改）

* 程序：`tests/riscv/vdot/start.S`、`vdot_test.c`、`corpus.S` **原样复用**，只是 `nemu_config.h` 改由 `tests/riscv/fullcore/Makefile` 按香山 SoC 地址生成。程序自带 M 态 trap handler，对每条用例检查「该 trap 的是否 trap、mcause 是否为 2、vd 是否不变」（`tests/riscv/vdot/vdot_test.c:272-284`），并逐字节比对 vd 与语料期望值。
* 语料：`tests/vectors/*.txt`（13 个 suite）+ `tests/riscv/vdot/extra_vectors/vstart_range.txt`，由 `pack_corpus.py` 打包成 30758 条，`slice_corpus.py` 切成 6 批（每批 5127 条，末批 5123 条）在 6 个 emu 进程上并行运行。
* 规模：全部定向用例（正数 / 负数 / 边界 × 3 条指令、`vstart_relaxed` 130 条按 STRICT 语义重标为必须 trap、补充定向 55 条）+ 每条指令 10000 条随机，共 30758 条；其中 4834 条必须 trap（SEW 不符、`vstart≠0`）。
* 这是**双重判定**：程序自身对照参考模型期望值；difftest 同时把每条提交与 NEMU 比对。

### 4.2 背靠背依赖测试（Level 1 证明不了的部分）

`vdot_dep.c` + `vdot_dep_kernels.S`。每个内核以宏写一次，实例化成两个函数：

* `kN_fast`：指令背靠背，依赖全部落在乱序流水线内部；
* `kN_slow`：同一序列，相邻指令间插 `fence`（`vdot_dep_kernels.S:38-42`）。昆明湖V2 的 `FENCE` 译码为 `noSpec + blockBack + flushPipe`（`work/XiangShan-fullcore/src/main/scala/xiangshan/backend/decode/DecodeUnit.scala:231`）：等所有更老指令提交后才执行、并冲刷流水线，使每条消费者只能读到已提交的架构状态。

驱动对同一份随机输入（32 个向量寄存器 + 64 B 访存缓冲；随机 AVL，SEW=8 取 0..17、SEW=32 取 0..5，四分之一迭代非满 vl；随机 vta/vma；偶尔放入全 0x80 / 全 0x7f 寄存器）各跑一次，逐字节比较 32 个向量寄存器与 4 个标量结果（`vdot_dep.c:119-125`）。fast/slow 不一致即流水线内的旁路、唤醒或重命名有错，与 NEMU 无关；两者一致但与 NEMU 不同则 difftest 当场中止。

| 内核 | 覆盖的依赖 | 源码 |
|---|---|---|
| K1 | `vadd`/`vsub` → vdot 的 vs1、vs2（RAW），vdot → `vmv.x.s` → 整数 `add`（跨域） | `vdot_dep_kernels.S:96` |
| K2 | vdot → vdotacc ×3 对同一 vd（v3）累加；之后 `VDOTACC 4,3,3`（vs2=vs1=上一条结果 v3，vd=v4）与 `VDOTACC 4,4,3`（vd=vs2=v4，vs1=v3） | `:112`（末两条见 `:122,124`） |
| K3 | vdot（e8）→ `vsetvl` → e32 的 `vadd` / vdot4a（vs2、vd 都是前序结果）/ `vredsum`（vs1 种子） | `:129` |
| K4 | `vmul` → vdot4a 累加 → vdot4a（vs1=vd）→ `vmslt` 生成 v0 → 带掩码 vdot4a → `vadd` | `:145` |
| K5 | `vmslt` → 带掩码 vdot（v0 RAW）→ 用 vdot 结果 `vmsne` 生成掩码 → 带掩码 vdotacc | `:162` |
| K6 | `vle8` → vdot → `vse32` → `vle32` → vdotacc（经访存的依赖），再 `ld` 回读 | `:176` |
| K7 | WAR / WAW：vdot 后立即覆写其源寄存器，结果寄存器被连续写 | `:197` |
| K8 | 流水线中的异常投递：合法 vdot 之后紧跟 SEW=32 的 vdot、SEW=8 的 vdot4a、`vstart=1` 的 vdotacc（各一次非法），trap 返回后继续消费前序结果；要求每次恰好 trap 3 次、mcause 之和 = 6（`vdot_dep.c:121-125`） | `:216` |
| K9 | 8 条互相独立的 vdot 同时在发射队列中，再收拢为两条 vdotacc 链，SEW=32 下 vdot4a 读归约结果 | `:244` |
| K10 | 16 次迭代的 vdotacc 累加循环；循环出口分支预测失败冲刷投机发射的 vdotacc | `:273` |

每个种子 10 内核 × 200 迭代 × 2 版本 = 4000 次内核调用；按内核源码静态计数，每次迭代（fast+slow）执行 152 条 vdot 族指令（其中 6 条为必须 trap 的非法指令），4 个种子合计约 12.2 万条 vdot 族动态指令。

### 4.3 波形程序

`vdot_wave.S`：`vadd.vv v1` → `vdot.vv v3, v10, v1` → `vdotacc.vv v3, v11, v8` → `vsetivli e32` → `vdot4a.vv v4, v3, v9`，一条 RAW 链，期望值写在文件头注释里（`vdot_wave.S:10-13`）。

---

## 5. 结果

### 5.1 语料（`logs/stage3/fullcore/summary.log:1-9`）

```
batch     cases     pass   fail  must-trap   trapped-ok  emu
b00        5127     5127      0        811          811  HIT_GOOD_TRAP
...
b05        5123     5123      0        839          839  HIT_GOOD_TRAP
CORPUS TOTAL cases=30758 pass=30758 fail=0 must-trap=4834 trapped-mcause2=4834 batches=6 hit-good-trap=6/6
difftest 失配报告行数（'different at' / 'ABORT'）：0
```

单批明细见 `corpus_b00.log:19-41`（分 suite 表，与 P5 在 NEMU 上的结果口径相同），`corpus_b00.log:50-51` 为 `HIT GOOD TRAP` 与 `instrCnt = 1032599, cycleCnt = 1490596`。每批约 103 万条提交、149 万周期，emu 墙钟约 570 s（约 2.6 k 周期/秒）。

### 5.2 依赖测试（`summary.log:10-37`）

4 个种子全部 `DEP TOTAL runs=2000x2 fail=0 k8-trap-count-bad=0`、`RESULT: PASS`、`HIT GOOD TRAP`；每次约 458 万条提交、452 万周期（IPC≈1.01）。分内核明细见 `dep0.log:9-22`。

### 5.3 异常投递与 mcause

* 语料中 4834 条必须 trap 的用例在全核上**全部 trap 且 mcause=2**，vd 保持不变（`summary.log:8`；单批 `corpus_b00.log:38-39`）。由于 REF 侧对非法指令是独立执行判定（§2.2，`traps.cpp:81-106`），且 `mcause/mepc/mtval/mstatus` 每条提交都比对，这同时证明 RTL 与 NEMU 对每一条非法用例的判定、`mepc`、`mtval` 一致——否则 difftest 会在该条中止。
* K8 在流水线中前后都有依赖指令的情况下注入 3 种非法 vdot 族指令，16000 次内核调用中每次恰好 trap 3 次（`k8-trap-count-bad=0`）。
* `vstart` 归零、`vl/vtype` 与 `mstatus.VS` 置脏：`vcsr` 与 `mstatus` 每条提交比对（§2.2），全程无失配。

### 5.4 汇总

| 项 | 数值 |
|---|---|
| 逐条比对的提交指令 | 24,517,314（6 批语料 + 4 个依赖种子的 `instrCnt` 之和） |
| 仿真周期 | 27,090,115 |
| difftest 失配 | 0 |
| HIT GOOD TRAP | 10 / 10 次运行 |

---

## 6. 故障注入（`logs/stage3/fullcore/fault_*`）

在独立副本 `work/XiangShan-fullcore-fault` 中修改 `src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala:181`（`fault_diff.txt`）：

```scala
-  private val dotVd = vdotTree.io.dotVd
+  private val dotVd = vdotTree.io.dotVd ^ 1.U  // FAULT-INJECTION T1-F1: flip bit0 of the vdot result
```

这是三条 vdot 指令共用的结果总线（归约写回 `redVd` 与 vdot4a 走 `Mgu` 的两条路径都取自它），即「改坏数据通路一位」。重新精化后生成的 `VIMacU.sv` 中可见 `{_vdotTree_io_dotVd[127:1], ~(_vdotTree_io_dotVd[0])}`，注入改动也被构建流程记录在 `build_emu_fault_3.log:265`。

| 程序 | 结果 | 首个失配 | 被中止的提交 |
|---|---|---|---|
| `vdot_wave.bin` | **检出** | `v3_low right = 0xffffffffffffff58, wrong = 0xffffffffffffff59`（`fault_wave.log:178-179`） | 第一条 vdot `e6a081d7` @ `0x80000042`（`fault_wave.log:54`） |
| `dep0/vdot_dep.bin` | **检出** | `right = 0xb85a792d00000468, wrong = …469`（`fault_summary.log:2`） | K1 的 vdot `e62081d7`（`fault_dep.log:67`） |
| `b00/vdot_test.bin` | **检出** | `right = 0xffffffff000005d8, wrong = …5d9`（`fault_summary.log:3`） | 语料第一条 vdot `e62081d7` @ `0x8000092a` 所在提交组（`fault_corpus_b00.log:76-77`） |

`FAULT-INJECTION: 3 / 3 个程序检出`；随后源码改回，`cmp` 确认与全核树逐字节一致（`fault_summary.log:4-5`）。三处失配的 right/wrong 都**只差 bit0**，说明 difftest 比的确实是 VIMacU 写回的 vd，且粒度到位。

注：difftest 报告里 `different at pc = …` 打印的 pc 不是出错 vdot 的地址，出错提交要看提交轨迹。轨迹中的 `<--` 标在出错**提交组**的最后一条指令上，而不一定是 vdot 本身：`vdot_wave.bin` 与 `dep0` 的出错提交组只有 1 条（`cmtcnt 1`，`fault_wave.log:29`、`fault_dep.log:33`），`<--` 正好落在 vdot 上（`fault_wave.log:54`、`fault_dep.log:67`）；`b00` 的出错提交组有 2 条（`fault_corpus_b00.log:43` 的 `cmtcnt 2`），`<--` 落在同组第二条 `j` 指令上（`:77`），vdot `e62081d7` 是同组第一条（`:76`）。上表最后一列按此判读。注入版 emu 留在 `work/XiangShan-fullcore-fault/build/`（源码已还原，二进制保留以便复查）。

---

## 7. 全核波形：vdot 从译码到 ROB 提交

### 7.1 抓取方式

```
emu -i vdot_wave.bin --diff <ref .so> --dump-wave -b 0 -e 2000 --wave-path work/build/fullcore/wave/vdot_wave.vcd
```

emu 在 `--dump-wave`（不加 `--dump-wave-full`）下每个周期只写一个时间点，VCD 时刻即周期号。整核 1594 个周期的 VCD 为 382 MB（`wave_dump.log:19`），**不入库**；入库的是：

* `logs/stage3/fullcore/wave_trace.txt`：`tests/riscv/fullcore/wave_trace.py` 从 VCD 抽取 162 个信号（译码、重命名、ROB 入队、向量发射队列入/出、VialuFix 与 Vimac 的输入输出、ROB 提交）后得到的事件轨迹；
* `logs/stage3/fullcore/wave_fullcore_vdot.png`：用 `scripts/tools/vcd_plot.py` 从同一 VCD 渲染的 13 路信号时序图（周期 1483–1516），文档内嵌的图 8 是它的逐字节副本 `docs/stage3/figures/fig8_fullcore_vdot_wave.png`； ![图 8　全核 MinimalConfig 中 vadd → vdot → vdotacc → vdot4a 背靠背的时序图](figures/fig8_fullcore_vdot_wave.png) 图 8　全核时序图（周期 1483–1516）。四条竖线标出 vdot（robIdx=22）的发射 1494、进 VIMacU 1497、写回 1499、提交 1501；`Vimac.in.valid` → `Vimac.out.valid` 三次都是 2 拍。图由 `scripts/50_run_fullcore_difftest.sh` 的 `run_wave()` 函数在抓完 VCD 后渲染；VCD 不入库，但只要 `work/build/fullcore/wave/vdot_wave.vcd` 还在，就可以只重画图、不重跑仿真：在 `PYTHON` 带 matplotlib 的环境中执行 `run_wave()` 里那条 `vcd_plot.py` 命令（`--vcd` 指向上述 VCD，`--from 1483 --to 1516`，13 个 `--signal` 原样照抄）。2026-10-25 按此重画到 `/tmp` 下核对过，信号与数值和存档图一致，只有字体渲染略有差别。
* `logs/stage3/fullcore/wave_run.log`：同一程序带 `--dump-commit-trace` 的逐条提交记录，`wave_run.log:34,35,37` 是三条 vdot 族指令的提交，`:46` 为 `HIT GOOD TRAP`。

### 7.2 关键信号与时刻（`wave_trace.txt:155-192`）

层次前缀 `TOP.SimTop.cpu.l_soc.core_with_l2.core.backend.` 省略。表中时刻取自第二次译码。轨迹里 vadd、vdot 在 1424、1459 已经各有一次译码输出（`wave_trace.txt:15,127`），但都停在重命名输入（`:19-148`），从未入 ROB（轨迹中第一条 `ROB-ENQ` 在 1487，`:168`）；1470–1482 没有事件，1483 起整组重新进入译码（`:150-153`）。这与紧挨在 vadd 之前的 `fence`（提交记录 `wave_run.log:32`）的语义一致：昆明湖V2 把 `FENCE` 译码为 `noSpec + blockBack + flushPipe`（`DecodeUnit.scala:231`，见 §4.2），更年轻的指令要等它提交，提交后流水线被冲刷、从下一条重新取指。轨迹没有抽取冲刷信号本身，所以「被 fence 冲刷」是由上述现象和源码语义推断的。`IQ0` = `inner_vfScheduler.IssueQueueVfmaVialuFixVimacVppuVfaluVfcvtVipuVsetrvfwvf`（含 Vimac 的那个向量发射队列）。

| 周期 | 阶段（信号） | vadd.vv v1 | vdot.vv v3,v10,v1 | vdotacc.vv v3,v11,v8 | vdot4a.vv v4,v3,v9 |
|---:|---|---|---|---|---|
| 1484–1488 | 译码输出 `inner_ctrlBlock.decode.io_out_0_*` | 1484 | 1485，`fuType=0x200000 fuOpType=0xe7 illegalInstr=0` | 1486，`fuOpType=0x177` | 1488，`fuOpType=0x1f7` |
| | 重命名输入 `inner_ctrlBlock.rename.io_in_0_*` | 1485 | 1486 | 1487 | 1489 |
| | 进发射队列 `IQ*.io_enq_0_*` | 1486（IQ1） | 1487（IQ0） | 1488（IQ0） | 1490（IQ0） |
| | 入 ROB `inner_ctrlBlock.rob.io_enq_req_0_*` | 1487 | 1488 | 1489 | 1491 |
| | 出发射队列 `IQ*.io_deqDelay_0_*`（物理源 rf0/rf1/rf2） | 1488，pdest=59 | **1494**，robIdx=22，pdest=60，psrc=(**59**,52,56) | **1501**，robIdx=23，pdest=61，psrc=(48,54,**60**) | **1508**，robIdx=25，pdest=62，psrc=(50,**61**,58) |
| | FU 输入 `exus_2.VialuFix.io_in_*` / `exus.Vimac.io_in_*` | 1491 | **1497**，vsew=0，`src0(vs1)=1211…0403`（= vadd 结果） | **1504**，`src2(oldVd)=…ffffff58`（= vdot 结果） | **1511**，vsew=2，`src1(vs2)=…00000310`（= vdotacc 结果） |
| | FU 输出 `…io_out_*`（`res_data`） | 1492，`1211100f…0403` | **1499**，`…ffffff58` | **1506**，`…00000310` | **1513**，`fffffff8 fffffff8 fffffff8 00000026` |
| | ROB 提交 `inner_ctrlBlock.rob.io_commits_*` | 1494 | **1501** | **1508** | **1515** |

读法：

1. **RAW 旁路走的是物理寄存器号**：vadd 的 `pdest=59` 出现在 vdot 的 `psrc rf0`（vs1），vdot 的 `pdest=60` 出现在 vdotacc 的 `rf2`（旧 vd / 累加源），vdotacc 的 `pdest=61` 出现在 vdot4a 的 `rf1`（vs2）。三条消费者进入 VIMacU 时读到的源值正是生产者在 FU 输出端产生的值（`wave_trace.txt:179→182`，`183→186`，`187→190`）。
2. **结果值与手算一致**：vdot = −(3+…+18) = −168 = `0xffffff58`；vdotacc 加上 −128×64 + 127×72 = 952 得 `0x310`；vdot4a 第 0 lane (0x10+0x03)×2 = 38 = `0x26`，其余 lane 4×(−1×2) = −8；tail 全 1（vta=1）。
3. **VIMacU 的 latency=2 在全核中得到确认**：Vimac `io_in_valid` 到 `io_out_valid` 恰为 2 拍（1497→1499、1504→1506、1511→1513），这是在真实流水线中、由 `VIMacU` 内部 `ctrlPipe/dataPipe` 驱动的结果，不再是 L1 平台的常量计数器（陷阱第 6 条）。
4. **发射 → FU 输入固定 3 拍**（1494→1497 等，对应读物理寄存器堆的 OG0/OG1 两级）；**FU 输出 → 依赖者发射 2 拍**（1499→1501）。因此在 MinimalConfig 下，**相互依赖的两条 vdot 族指令的发射间隔是 7 拍**（1494→1501→1508）。这是本波形的实测，样本为一条依赖链，见 §9 第 3 条的讨论。

---

## 8. Level 1 等价性论证是否成立

`21` §11.1 的论证有五步：REF 相同、比对对象就是 `vd`、算术通路同一份 RTL、译码判定同一份 RTL、比对链路有效。全核 difftest 的结果对它的检验如下：

| Level 1 的论断 / 缺口 | 全核实测 | 结论 |
|---|---|---|
| 「一条 vdot 应该算出什么」两层结论一致 | 同一份 30758 条语料，Level 1（`VDotTop`）与全核（`VIMacU`）都是 0 失配 | **成立** |
| **G1** 写回成形在 `VIMacU` 与 `VDotTop` 是两份代码，Level 1 只验了后者 | 全核里挂进流水线的是 `VIMacU`（波形 `exus.Vimac.*`）；全部 vl / vm / vta / vma 组合（含 vl=0、AVL>VLMAX）0 失配；故障注入证明比对确实落在 `VIMacU` 的输出上 | **闭合** |
| **G2** 没有背靠背流量 | K1–K10：RAW（经物理寄存器、经访存、跨整数域）、WAR/WAW、掩码依赖、8 条 vdot 同时在队列、分支冲刷；fast/slow 自洽 + difftest 双重 0 失配 | **闭合** |
| **G3** `vcsr` / `mstatus.VS` 不比对 | difftest 每条提交比对 `vstart vl vtype vcsr…` 与 `mstatus`（`refproxy.cpp:185-230`） | **闭合** |
| **G4** 异常只到译码打标 | 4834 条非法用例 + K8 流水线中注入的非法指令，均经 ROB 投递、`mcause=2`、`mepc` 正确，且 REF 独立判定（`traps.cpp:81-106`） | **闭合** |
| 「凡是一条 vdot 应算出什么、应不应该报非法，Level 1 结论与全核等价」（`21` §10.4） | 实测一致 | **成立** |

需要补充的两点：

* Level 1 的等价性只覆盖 LMUL=1（裁定 S-6），全核同样只测了 LMUL=1：语料格式没有 LMUL 字段，`vdot_test.c` 的 `vsetvl` 恒取 `vlmul=0`。Level 1 中 LMUL≠1 的非法判定（`dotEmulIllegal`，`21` §7.4 复跑 6000/6000 一致）**未在全核上复测**。
* Level 1 在 `21` §10.3 中把「流水线冒险」风险评为「中，理论上背靠背安全但未实测」——现在**已实测**，未发现问题。

---

## 9. 发现与局限

1. **未发现 RTL 或 NEMU 补丁缺陷**。`rtl/patch/`、`nemu/patch/` 未改动。
2. **环境问题两处**（§3.3）：上游 difftest 的 `OPT_FAST` 写死 clang 专有选项；g++ 11.4 编译 Verilator 生成的超大函数不可接受地慢。已在脚本中固化为 clang++。
3. **对 `docs/stage3/22` 遗留威胁的一条实测证据**：`22` 中 vdotacc 循环携带依赖按 FU 延迟记为 2 拍。全核波形显示，在 MinimalConfig 下相互依赖的 VIMacU 指令发射间隔是 **7 拍**（FU 2 拍 + 读寄存器堆 3 拍 + 写回唤醒到发射 2 拍，§7.2 第 4 条）。同样的唤醒 / 读寄存器开销也作用于基线里依赖 VIAluFix 的 `vwadd.wv` 链（本波形中 vadd 从发射到结果为 1488→1492，再到消费者发射 1494，共 6 拍）。所以「2 拍 vs 1 拍」在全核中会被稀释成约「7 拍 vs 6 拍」。这只是一条依赖链上的观测，**不是吞吐测量**；T3 要的循环级周期数仍需在全核上跑 kernel 实测。
4. **配置**：只构建了 MinimalConfig（理由与影响见 §3.1）。默认配置、`KunminghuV2Config` 未运行。
5. **随机性**：依赖测试的随机性在数据、vl、vta/vma 上；指令序列是 10 个固定模板，不是随机指令流生成器。乱序调度的交错由真实流水线自然产生，但没有刻意制造发射队列满、ROB 满等压力场景（K9 的 8 条独立 vdot 只部分覆盖）。
6. **语料程序的标题**：复用的 `vdot_test.c` 打印「NEMU vdot instruction-family conformance test」，在全核上运行时这行标题字面不准确；`nemu_config.h` 的 `NEMU_DEFCONFIG` 字段已改写为「XiangShan MinimalConfig emu (DUT) / riscv64-xs-kmhv2-ref_defconfig (REF)」以免误读（`corpus_b00.log:7`）。
7. **emu 输出**：emu 把 `HIT GOOD TRAP` 等写到 stdout、把数万行 `[PERF ]` 性能计数器写到 stderr；若用 `2>&1 | grep` 合并过滤，两路交错可能把结果行吞掉。脚本改为 stdout/stderr 分开收集，只过滤 stderr 中的 `[PERF ]` 行。
8. **NEMU 构建依赖**：本机无 `libreadline-dev`/`libsdl2-dev`，复用了 `/tmp/audit3/sysroot` 的解包（`NEMU_SYSROOT=/tmp/audit3/sysroot`）；`.so` 已存在时脚本不会重建。

---

## 10. 复现

```bash
# 依赖：scripts/00_setup_env_host.sh 已生成 work/XiangShan-kmhv2 与 work/NEMU；clang++；≥64 GB 内存
bash scripts/50_run_fullcore_difftest.sh build   # 全核树 + NEMU 私有副本 .so + emu（实测 23:31）
bash scripts/50_run_fullcore_difftest.sh run     # 6 批语料 + 依赖测试 4 个种子（本机约 45 分钟）
PLOT_PYTHON=/path/to/python-with-matplotlib \
bash scripts/50_run_fullcore_difftest.sh wave    # 波形 + 文本轨迹 + 时序图（约 1 分钟，VCD 382 MB）
bash scripts/50_run_fullcore_difftest.sh fault   # 故障注入（首次需额外构建一次 emu）
```

可调参数见脚本文件头（`FC_CONFIG`、`EMU_THREADS`、`JVM_XMX`、`BATCHES`、`DEP_ITERS`、`DEP_SEEDS`、`WAVE_BEGIN/END`）。日志写到 `${LOG_ROOT}/stage3/fullcore/`，已有同名日志时改写到 `rerun_<时间戳>/` 子目录，不覆盖存档。

本报告的存档由以下命令产生：`build` 阶段为三次手工 `make emu`（`build_emu.log` / `build_emu_2.log` / `build_emu_3.log`，过程见 §3.3），脚本固化最终做法后又在独立 `WORK_DIR` 中从零复测一次（`build_emu_scripted.log`、`build_scripted_driver.log`）；`run` / `wave` / `fault` 为上述脚本原样运行（`run_driver.log`、`wave_driver.log`、`fault_driver.log`）。

---

## 11. 文件清单

| 文件 | 内容 |
|---|---|
| `scripts/50_run_fullcore_difftest.sh` | 一键复现 |
| `tests/riscv/fullcore/Makefile` | 语料批次 / 依赖测试 / 波形程序的构建 |
| `tests/riscv/fullcore/slice_corpus.py` | 语料 blob 按区间切批 |
| `tests/riscv/fullcore/vdot_dep.c`、`vdot_dep_kernels.S` | 背靠背依赖测试 |
| `tests/riscv/fullcore/vdot_wave.S` | 波形抓取用最小程序 |
| `tests/riscv/fullcore/wave_trace.py` | 从全核 VCD 抽取 vdot 事件轨迹 |
| `logs/stage3/fullcore/build_emu*.log`、`build_time_breakdown.log` | 构建日志（含两次失败）与分阶段耗时；`build_emu_scripted.log`、`build_scripted_driver.log` 为脚本从零复测 |
| `logs/stage3/fullcore/build_emu_fault_*.log` | 故障注入版 emu 的构建日志（同样经历 g++ → clang++） |
| `logs/stage3/fullcore/corpus_b0[0-5].log`、`dep[0-3].log`、`summary.log`、`run_driver.log` | difftest 运行日志与汇总 |
| `logs/stage3/fullcore/fault_*.log`、`fault_diff.txt`、`fault_summary.log`、`fault_driver.log` | 故障注入 |
| `logs/stage3/fullcore/wave_run.log`、`wave_dump.log`、`wave_trace.txt`、`wave_fullcore_vdot.png`、`wave_driver.log` | 波形（时序图副本：`docs/stage3/figures/fig8_fullcore_vdot_wave.png`） |
