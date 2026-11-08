# 交接文档：后续工作规划（面向 x86_64 Linux / ≥64GB 内存机器）

本文件面向接手本项目的下一台机器。请先读 `docs/_plan/MASTER_PLAN.md`（唯一事实来源），再读本文件。

---

## 一、当前状态速览

### 赛题要求完成情况

| 赛题条目 | 状态 | 主要产物 |
|---|---|---|
| 1.1 环境部署验证 | ✅ | `logs/stage1/p1_hello_xiangshan.log`，裸机 RV64 程序经 UARTLITE 实输出，HIT GOOD TRAP 收尾 |
| 1.2 操作日志 | ✅ | `logs/stage1/*.log`（含 4 次真实失败与修复） |
| 1.3 向量加法执行过程文档 | ✅ | `docs/stage1/02_*.md` + 7 张图（6 张 FU 级波形图 + 图 7 全核流水图）+ `logs/stage1/waveform/` |
| 2.1 vdot.vv 设计文档 | ✅ | `docs/stage2/10_*.md`（1562 行；§1 开头为赛题官方语义与逐行对照，见下方「语义修订 S-3'」） |
| 2.2 vdot.vv RTL 实现 | ✅ | `rtl/patch/*.patch`、`rtl/chisel/`、`rtl/verilog/` |
| 2.3.1/2.3.2/2.3.3 三项功能测试 | ✅ | `docs/stage2/12_*.md`，29 万+ 条执行 0 失败 |
| 3.1.1 NEMU 指令扩展 | ✅ | `nemu/patch/0001-*.patch`、`docs/stage3/20_*.md` |
| 3.1.2 协同仿真验证 | ✅ Level 1（FU+译码级）+ Level 2（MinimalConfig 全核 difftest） | `docs/stage3/21_*.md`；全核 difftest 已完成（T1），见 `docs/stage3/23_全核difftest验证报告.md`、`logs/stage3/fullcore/` |
| 3.2 基线功能实现 | ✅ | `bench/baseline/`，NEMU 实测三方比对 0 失配 |
| 3.3 延迟加速分析 | ✅ 建模 + MinimalConfig 全核实测 | `docs/stage3/22_*.md` §5.5 + 图 9；全核实测主结论：单次点积 1.70×（函数整体）、长向量稳态 1.81× / 2.25×（建模 1.50× / 3.00×）；5.17× / 2.81× 为口径敏感的参考值；只对 MinimalConfig 成立；真实 LLM kernel 见 T3 |
| 提交要求：三段录屏 | ✅ 已生成（未上传） | 三段演示视频 `demo/video/*.mp4` + `.srt`，由脚本生成（`demo/video/storyboard.md`），视频三因体积不入库；见 T6 |
| 提交要求：PPT | ✅ 已生成（未上传） | `docs/submission/SNL-XiangShan-vdot-slides.pptx`（PDF 版随上传包提供），由脚本从 `docs/ppt/讲解大纲.md` 生成（`submission/upload/README.md`）；提交流程核对见 `docs/ppt/提交清单.md`；见 T6 |

### 独立验收预测分数（评分表满分 100）

| 一级指标 | 二级指标 | 满分 | 预测 | 依据 |
|---|---|---:|---:|---|
| 完整性 | 阶段一 | 15 | 13–14 | `ACCEPTANCE_P1.md`（整改后） |
| 完整性 | 阶段二 | 20 | 17–19 | `ACCEPTANCE_P2.md`（整改后） |
| 完整性 | 阶段三 | 25 | 20–22 | `ACCEPTANCE_P3.md` 预测 20；I-1~I-4、M-1~M-9 已全部整改（整改记录见该文件 §8）。审计时的主要扣分点是全核缺位与吞吐只有建模值；全核缺位已由 T1 补上（`23`，只跑了 MinimalConfig），分数是否回收未经复审，吞吐仍为建模值 |
| 可行性 | 技术路径合理性 | 10 | 9 | 复用极强；扣分因 latency=2 仅静态估算 → **T2 可补到 10** |
| 可行性 | 功能验证有效性 | 10 | 9 | 审计扣分因异常语义仅到译码级；T1 已在全核上验证异常经 ROB 投递、`mcause=2`（`23` §5.3），分数未经复审 |
| 探索性 | 微架构优化分析 | 5 | 4（自评） | 三份审计均未单独评分；T1 已完成（全核波形给出一条依赖链的发射间隔观测，`23` §7.2），**T3 可显著提升** |
| 探索性 | 软硬件协同理解 | 5 | 4–5（自评） | 三份审计均未单独评分；Level 1 协同 + 机制剖析 + Level 2 全核 difftest（`23`） |
| 创新性 | 设计优化独特性 | 5 | — | XOR 蝶形折叠树、三指令共享阵列 |
| 创新性 | 扩展应用潜力 | 5 | — | 现固定 LMUL=1 → **T4 可提升** |

> **结论（更新）**：原先投入产出比最高的 T1（全核 difftest）已完成（`docs/stage3/23_全核difftest验证报告.md`，提交 `4674e08`）。
> 全核 emu 现已能在本机构建，T3 的微基准周期（单次点积、依赖链、长向量循环）已在 MinimalConfig 全核上实测（`docs/stage3/22_*.md` §5.5），真实 LLM 内核仍未做；其余各项按第三节顺序。
> 2026-10-26 取得赛题官方语义后完成语义修订 S-3' 并全链重跑，见下方。

### 语义修订 S-3'【已完成，2026-10-26】

* **起因**：P2–P7 期间一直没有取到赛题页的语义图。2026-10-26 经赛题页数据接口取得官方语义图（8 行 `vdot_vv` Python 伪代码，原样存档于
  `docs/_recon/figures/vdot_official_semantics.jpg`，来源与 sha256 见 `docs/_recon/vdot-semantics-research.md` §14）。逐行对照后主体一致，
  唯一差异是目的寄存器其余位：伪代码 `vd[1..VLEN-1] = 0`，原裁定 S-3 按 `vta` 处理元素 1..3。
* **裁定**（`MASTER_PLAN.md` D2.4）：`vdot.vv` / `vdotacc.vv` 在 `vstart < vl` 时 `vd[31:0]` 写结果、`vd[VLEN-1:32]` 恒为 0，与 `vta` / `vma` 无关；
  `vl = 0` 时不写；`vdot4a.vv` 不变；保留 `vl` 机制，`vl = 8` 时与官方伪代码逐位等价，`vl = 16` 为满寄存器版本。论证见 `docs/stage2/10_vdot指令设计文档.md` §1 开头与 §9 R-18。
* **提交**：`364b141`（参考模型、语料、RTL、NEMU、基线与 FU 级/NEMU/协同仿真/基线重跑）、`61eb937`（全核重建与全核 difftest、波形、hello、周期实测重跑）、
  `0f62281`（阶段二、三文档）、`cfcd658`（三项基础测试 `vl=8` 主演示用例的 DUT 实测逐条存档）。
* **重跑结果**：官方伪代码字面实现 vs 参考模型 20570 条 0 失配（`logs/stage2/p3_official_pseudocode_equiv.log:40`；阴性对照 532 条全部失配，`:62`）；
  FU 级 290175 条 0 失败（`logs/stage2/p5_summary.log:43`），故障注入 6/6（`p5_fault_injection.log:273-274`）；NEMU 30794 条 0 失配（`logs/stage3/p5_vdot_tests.log:90`），
  故障注入 6/6（`logs/stage3/p5_fault_injection.log:192`）；协同仿真 72794 条、值比对 55960/55960、分歧 0（`logs/stage3/cosim/p6_cosim_run.log:45-52`），故障注入 7/7（`p6_fault_injection.log:358`）；
  基线等价 25960 条 0 失配（`logs/stage3/p7_baseline_equiv.log:114`）；全核语料 30794/30794、24,524,262 条提交 0 失配（`logs/stage3/fullcore/summary.log:8`、`23` §5.4），
  故障注入 bit0 3/3、`s3old` 3/3（`fault_summary.log:5`、`fault_summary_s3old.log:5`）；全核周期实测各点逐拍不变，主结论 1.70× / 1.81× / 2.25× 不变（`22` §5.5.2）。
* **已删除的旧日志**：`logs/stage3/cosim/p6_fault_injection_v2.log`、`logs/stage3/p7_baseline_gcc15_supplement.log`（删除于 `0f62281`）；
  全核首次构建的 `build_time_breakdown.log`、`build_emu_2/3.log`、`build_scripted_driver.log`、`build_emu_scripted.log` 等（加入于 `4674e08`，删除于 `61eb937`）。需要时用 `git show <提交>^:<路径>` 查看。

---

## 二、环境重建（第一步，约 1–2 小时）

### 版本锁定（务必一致，否则补丁不适用）

| 仓库 | 分支/commit |
|---|---|
| XiangShan | `kunminghu-v2` @ `a4eeaab` |
| └ yunsuan | `9559211` |
| NEMU | `9090839` |
| 其余子模块 | 以 kunminghu-v2 的 pin 为准（11 个） |

### 工具链

JDK **17**（JDK 21/25 会失败）、mill **0.12.3**（XiangShan）与 **0.11.1**（yunsuan，两个版本并存且不可混用）、Scala 2.13.15、Chisel 6.7.0、firtool 1.62.1（mill 自动下载）、Verilator、RISC-V 交叉工具链（需支持 `-march=rv64gcv_zve64x`，gcc ≥13）。

**全核 difftest（T1，`scripts/50_run_fullcore_difftest.sh`）额外需要**：**clang++**（difftest 子模块 `difftest/verilator.mk:76` 把 clang 专有选项 `-fno-slp-vectorize` 写死在 `OPT_FAST` 里，g++ 直接报错；改用 GCC 等价选项后 g++ 11.4 编译 Verilator 生成的超大函数 85 分钟仍未结束，见 `23` §3.3），以及 **≥64 GB 内存**（S-3' 后重建的 `make emu` 峰值 RSS 56445000 KiB（约 53.8 GiB），墙钟 24:31.63，`logs/stage3/fullcore/build_emu.log:2429,2434,2448`；首次构建分段测得 Verilator 前端峰值 56.4 GiB、mill 精化 JVM 峰值 19.5 GiB，原日志 `build_time_breakdown.log:13,39` 已删除，见 git 历史（提交 4674e08））。

### 已有脚本与其适用性

实测环境：Ubuntu 22.04.5 x86_64（128 核）、GCC 11.4（宿主）、`/opt/riscv` 下的 riscv64-unknown-elf GCC 15.2（交叉）、Verilator 5.024、OpenJDK 17.0.20；无 Docker；无 `libreadline-dev` / `libsdl2-dev`（由 `LOCAL_SYSROOT=1` 解包到 `${WORK_DIR}/sysroot`，未用 sudo）。
在**全新目录**（交付仓库重新 `git clone` + 独立 `WORK_DIR`，日志写到 `LOG_ROOT=/tmp/...`）按 00→40 顺序一键跑通，耗时为该次实测（mill / coursier / firtool 下载缓存沿用本机 `~/.cache`，干净机器首次会多出下载时间）。
下表是**语义修订 S-3' 之前**的复现记录，「关键结果」中的数字是当时的存档值；S-3' 之后 `20`/`21`/`30`/`40`/`50` 已在同一台机器上按新语义重跑并更新存档（新数字见上方「语义修订 S-3'」），没有再从全新目录复测。

| 脚本 | Linux x86_64 实测 | 关键结果 |
|---|---|---|
| `scripts/00_setup_env_host.sh` | ✅ 226 s（含按 pin 克隆 XiangShan 全部子模块与 NEMU） | 依赖缺失时列出 apt 命令后退出；`LOCAL_SYSROOT=1` 免 sudo 解包 readline/SDL2；自动探测 JDK 17 与支持 `rv64gcv_zve64x` 的交叉编译器；最后调用 `04` 生成两棵补丁工作树。重复执行全部「跳过」 |
| `scripts/01_setup_env_docker.sh` + `scripts/docker/Dockerfile.xsdev` | ⚠️ 未实测（本机无 Docker） | 镜像与平台按宿主架构自动选择（amd64/arm64），不再写死 arm64 与 `/work`。Linux 上不需要它 |
| `scripts/02_build_nemu.sh` | ✅ 29 s | 两种形态构建成功，`git status --short` 为空（零 patch） |
| `scripts/03_run_hello.sh` | ✅ 2 s | `hello xiangshan, I am cie2026-vdot, IP address <本机IP>`，HIT GOOD TRAP |
| `scripts/04_make_vdot_trees.sh`（新增） | ✅（由 00 调用） | 生成 `XiangShan-vdot` / `XiangShan-cosim` = kmhv2 + `rtl/patch/0001` + `0002` + `tests/unit/yunsuan_vdot_testbench.patch` |
| `scripts/10_build_yunsuan_sim.sh` | ✅ 105 s | 3 段均 `EMU EXCEEDED LIMIT` |
| `scripts/11_build_vdot_sim.sh` | ✅ 105 s | 8 段均 `EMU EXCEEDED LIMIT` |
| `scripts/20_run_func_tests.sh` | ✅ 317 s | 合计 290103 / 290103 通过，失败 suite 0，与存档 `p5_summary.log` 数字相同 |
| `scripts/21_build_nemu_vdot.sh`（含 `verify-patch`、`fault`） | ✅ 21 s / 10 s / 21 s | 30758 / 0，must-trap 4834/4834，`.so` HIT GOOD TRAP；故障注入 5/5（21103 / 12079 / 10173 / 3202 / 1584，与存档相同） |
| `scripts/30_run_cosim.sh`（含 `fault`） | ✅ 251 s / 96 s | 72758 条，值比对 0 失配、判定分歧 0；分 suite 汇总与存档 `p6_cosim_run.log:22-52` 逐行相同。故障注入 6/6：5116 / **6378（新增 T3-RTL-1b）** / 586 / 4944 / 分歧 162 / 分歧 74 |
| `scripts/40_run_bench.sh` | ✅ 126 s | [A] 25924/0、[B] 24 个长度 0 失配；9 个 CSV 中 6 个与仓库逐字节相同，`instr_count_loop` / `instr_count_single` / `speedup` 因 GCC 15 的 `minstret` 绝对值 +2 而不同（斜率不变；原补充日志 `p7_baseline_gcc15_supplement.log` 已删除，见 git 历史，现存档本身即 GCC 15.2 的运行，见 `docs/stage3/22_基线实现与延迟加速分析.md:643-650`）。绘图需 matplotlib + CJK 字体，缺失时跳过并告警 |
| `scripts/50_run_fullcore_difftest.sh`（T1 新增，`build`/`run`/`wave`/`fault`） | ✅ `build` 从零 23:31（独立 `WORK_DIR`；该日志 `build_scripted_driver.log` 已删除，见 git 历史（提交 4674e08））；`run` 约 45 分钟。S-3' 后重建：`make emu` 24:31.63（`logs/stage3/fullcore/build_emu.log:2429`），`run` 60m33s（`run_driver.log:76`，与其他任务并行） | MinimalConfig 全核 emu + NEMU 私有副本 `.so`；当时语料 30758/30758、24,517,314 条提交 0 失配；S-3' 后为 30794/30794、24,524,262 条提交 0 失配，故障注入 bit0 3/3、`s3old` 3/3（`logs/stage3/fullcore/summary.log`、`fault_summary.log`、`fault_summary_s3old.log`）。默认用 clang++，缺失时退回 g++ 并告警 |
| `scripts/tools/*` | ✅（随 20 / 30 / 40 间接实测） | `run_vimacu_tb` / `run_decode_tb` / `verify_patches` / `capture_vdot_waves` / `sync_rtl_sources` 已改为支持 `WORK_DIR`、GNU `mktemp`、`md5sum`。`fault_inject_vdot.sh`（改为 `md5sum`/`md5` 自动选择、支持 `WORK_DIR`/`YS_DIR`）与 `run_vecfu_latency.sh`（支持 `WORK_DIR`/`XS_DIR`）也已改完，`40` 不再要求 `WORK_DIR` 等于 `<仓库根>/work`；在独立 `WORK_DIR` 上复测：`40` 通过，`WITH_FAULT=1 bash scripts/20_run_func_tests.sh` 357 s，故障注入 5/5，各故障检出项数 10/9/5/9/5（/13）与存档 `p5_fault_injection.log` 相同 |

公共约定见 `scripts/lib/common.sh` 文件头：`WORK_DIR`、`LOG_ROOT`、`RESULTS_DIR`、`FIG_DIR`、`BUILD_ROOT`、`XS_RUNNER`（`auto`：Linux 在宿主机执行，macOS 进容器）、`CROSS`、`JOBS`、`PYTHON`。
已知限制：上游 yunsuan `emu.cpp` 用 `getcwd(cwd, 64)` 拼 VCD 路径，yunsuan 目录超过 63 字节时波形会静默丢失。40 已改为在短路径临时目录里运行 emu；`10`/`11` 的 `WAVE=1` 与 `20` 的 `WITH_WAVE=1` 遇到长路径时直接报错，提示改用较短的 `WORK_DIR`。

### 平台差异的处理现状（已固化进脚本）

1. `yunsuan/src/main/resources/espresso` 是上游自带的 **Linux x86-64 ELF**。`00_setup_env_host.sh` 第 4 步在 x86_64 上直接复制这份上游二进制到 `${WORK_DIR}/tools/bin/`（`00_setup_env_host.sh:262-269`），只有在它跑不起来时（如 arm64）才从源码自建；`10`/`11` 的 `forkEnv.json` 校验在两种平台上都无害，保留即可。
2. Linux 上 `XS_RUNNER=auto` 直接在宿主机执行 NEMU / 交叉编译 / cosim，**不需要 Docker**。官方镜像 `ghcr.io/openxiangshan/xs-env` 只有 amd64，未与本仓库脚本联调，非必要不用。

---

## 三、TODO（按投入产出比排序）

### T1 — 全核 difftest 【已完成】

> **状态：已完成**（提交 `4674e08`），报告 `docs/stage3/23_全核difftest验证报告.md`，日志 `logs/stage3/fullcore/`，一键脚本 `scripts/50_run_fullcore_difftest.sh`。
> 下面的验收标准逐条对应：
> * 全部语料 0 mismatch：MinimalConfig 全核上 30794/30794（S-3' 后重跑），4834 条必须 trap 的用例全部 `mcause=2`，6/6 批 HIT GOOD TRAP（`summary.log:1-9`）；另加 10 个背靠背依赖内核 × 4 个种子 0 失败（`summary.log:10-37`）；合计 24,524,262 条提交 0 失配（`23` §5.4）。
> * 故障注入：`VIMacU` 中 vdot 结果 bit0 翻转，3/3 个程序被 difftest 中止（`fault_summary.log:1-5`）；S-3' 后新增「写回尾部退回旧 S-3 的全 1」，同样 3/3（`fault_summary_s3old.log:1-5`）。
> * 全核波形：vdot 译码 1485 → 入 ROB 1488 → 发射 1494 → 进 VIMacU 1497 → 写回 1499 → 提交 1501，VIMacU 2 拍在真实流水线中确认（`wave_trace.txt:159-185`，`wave_fullcore_vdot.png`）；已据此更新 `docs/stage1/02_*.md`（§8.4.1、§10）与 `docs/stage3/21_*.md`（§0、§10.3、§11.2、§11.3、§12）。
> * Level 1 等价性论证：成立，G1–G4 在全核上闭合（`23` §8）。
> * 实际开销：构建约 23 分钟（不是预估的 1–3 小时；S-3' 后重建 `make emu` 24:31.63），运行约 45 分钟（S-3' 后与其他任务并行为 60m33s）；需要 clang++ 与 ≥64 GB 内存（见第二节工具链）。
> * **仍未覆盖**：只构建了 MinimalConfig（默认配置、`KunminghuV2Config` 未运行，`23` §3.1 论证功能结论可推广，但周期数只对 MinimalConfig 有效）；LMUL≠1 未在全核复测；依赖测试为 10 个固定模板，不是随机指令流（`23` §9）。
> 以下为立项时的原文，保留作记录。


**为什么**：当前唯一的得分天花板。现有协同仿真是 Level 1——把全核 difftest 的 **REF 侧原样搬了过来**（`dlopen` 真实 `riscv64-nemu-interpreter-so`，走 difftest 原生 C API），只把 DUT 从整个乱序核换成「vdot 功能单元 + 译码单元」。因此它能证明「一条 vdot 该算出什么、该不该报非法」，**不能**证明「它在乱序流水线里被正确发射、旁路、提交，异常被正确投递」。直接影响：3.1.2、功能验证有效性、微架构优化分析。

**前置**：T0 环境重建。注意 `work/XiangShan-kmhv2/Makefile:81` 的 `JVM_XMX ?= 40G`。

**步骤**
1. 纯净基线上应用 `rtl/patch/0001-xiangshan-vdot.patch` 与 `0002-yunsuan-vdot.patch`（`scripts/tools/verify_patches.sh` 可验证可应用性）。
2. NEMU 应用 `nemu/patch/0001-add-vdot-instruction-family.patch`，按 `riscv64-xs-kmhv2-ref_defconfig` 构建 `-so`。
3. 构建全核 emu（Verilator，带 difftest）。
4. 写带 vdot 的 RISC-V 测试程序（可直接复用 `tests/riscv/vdot/` 的语料打包方式与 `tests/vectors/` 语料），在全核上跑 difftest。
5. 抓 vdot 在真实流水线中的波形。

**验收标准**
- 全核 difftest 跑通，全部语料 0 mismatch；日志存档
- **故障注入**：改坏 RTL 一位，全核 difftest 必须报错（证明比对有效）
- 抓到 vdot 从译码到 ROB 提交的全核波形，并据此更新 `docs/stage1/02_*.md` 与 `docs/stage3/21_*.md` 的局限性章节
- 验证本项目 Level 1 协同仿真的等价性论证是否成立，如实记录

**预估**：构建 1–3 小时（含首次 Verilator 编译），调试 0.5–1 天。

---

### T2 — 综合，拿到真实面积与时序

**为什么**：`latency=2` 目前**只有静态逻辑级估算**支撑（设计文档已明确标注为估算而非综合结果），审计为此扣了 1 分；`13.7% 新增逻辑`也只是全加器等价结构计数的上界。一次综合可把两者从估算变成实测，直接提升「技术路径合理性」。

**步骤**：用 `rtl/verilog/vdot/VIMacU.v` 与基线 `rtl/verilog/baseline/VIMac.sv` 对照综合（yosys + Nangate45/Sky130 开源 PDK 即可，不必商业工具）。报告 vdot 路径的关键路径延迟、与 SEW=64 既有最长路径的对比、以及面积增量。

**验收标准**：给出综合脚本、真实报告、面积与 Fmax 对比表；回答「latency=2 是否真的收敛」；更新设计文档 §3 与 §8，把估算值旁边补上实测值。

---

### T3 — 真实 LLM 负载端到端评测

**为什么**：赛题动机是**边缘 LLM 推理**，当前只有微基准。一个 int8 GEMM 或 attention kernel 的端到端数据，是「探索性」和「创新性」最有说服力的材料，也能回答 T3 遗留的最大威胁。

**遗留威胁（必须解决）**：`vdotacc` 的循环携带依赖是 **2 拍**，比基线 `vwadd.wv` 的 1 拍更长。若循环是延迟受限且软件不做多累加器展开，长向量吞吐**可能不升反降**。现有 1.50× 吞吐是建模值，依赖「基线端口下界 3 拍压过其依赖下界」这一假设，FU 级平台无法验证。

**进展（微基准部分已完成，2026-10-25）**：在 MinimalConfig 全核 emu 上带 difftest 实测了单次点积、依赖链与长向量循环的周期数
（`bash scripts/50_run_fullcore_difftest.sh perf`；程序 `tests/riscv/fullcore/perf_cycles.c` + `perf_kernels.S` + `bench/baseline/baseline_rvv.S`；
日志 `logs/stage3/fullcore/perf_cycles.log`；CSV `bench/results/cycles_fullcore.csv`；分析 `docs/stage3/22_*.md` §5.5）。结论：
每跳向量依赖 = FU 延迟 + 5 拍（`vdotacc` 7、`vwadd.wv` 6）；`vdotacc` 单累加器循环 7.00 拍/迭代（被携带依赖卡住），基线 D 12.64 拍/迭代，
**威胁不成立（没有不升反降），加速比 1.81×**；2 累加器 5.63 拍/迭代（2.25×，贴近骨架循环 5.50 拍）。
**仍未做**：真实 LLM kernel（int8 GEMM / attention）、4 路累加器展开、默认配置上的周期、基线 D 12.64 拍瓶颈的定位（波形或 emu 性能计数器）。

**全核观测（T1 附带，不是吞吐测量；已被上面的实测取代）**：全核 MinimalConfig 波形中，两条相互依赖的 VIMacU 指令发射间隔 **7 拍**（1494→1501→1508：发射→进 FU 3 拍 + FU 2 拍 + 写回→依赖者发射 2 拍），同一波形里 VIAluFix 上的 `vadd.vv` 从发射到依赖者发射 **6 拍**（1488→1494）（`docs/stage3/23_全核difftest验证报告.md` §7.2 第 4 条、§9 第 3 条；`logs/stage3/fullcore/wave_trace.txt:173-188`）。据此「2 拍 vs 1 拍」在全核中更接近「7 拍 vs 6 拍」，劣势会被稀释；但这只是一条依赖链、一次执行的观测，6 拍取自 `vadd`（单 uop）而非 `vwadd.wv`（LMUL=2 下 4 uop）的循环，循环级周期数已由上面的实测补齐。全核 emu 与一键脚本现已具备（`scripts/50_run_fullcore_difftest.sh`），可直接在其上跑 kernel。

**步骤**：在全核上跑 int8 矩阵乘 / 注意力打分 kernel，vdot 版 vs 基线版，测真实周期数；做 2/4 路累加器展开的对比；给出随 N 变化的曲线。

**验收标准**：真实周期数（非指令数）对比；明确回答上述威胁成立与否；更新 `docs/stage3/22_*.md`，把建模值替换为实测值或保留并标注差异。

---

### T4 — 支持 LMUL > 1

**为什么**：当前按裁定 S-6 固定 LMUL=1（SEW=8/VLEN=128 场景恰为单 uop），LMUL≠1 由 `dotEmulIllegal` 守卫拦截。放开它直接提升「扩展应用潜力」。

**已有基础**：设计文档 §8.3 已论证可行性并给出**源码证据**——Rename 支持 bundle 内旁路（`Rename.scala:546-583`）、现成先例 `VEC_SLIDEUP` 在一条指令内对同一寄存器多次读写（`DecodeUnitComp.scala:1412-1426`）、空闲 `UopSplitType` 实测 19 个（推荐 `101011`）。方案：uop0 = `vdot`，uop1..n-1 = `vdotacc` 累加进同一 `vd`。

**注意**：现有 `VEC_VWW` 不可复用——其末 uop 会把 `lsrc(0)` 覆写成 `vs1`（`DecodeUnitComp.scala:1520`），对 `vwredsum` 是标量种子，对 `vdot` 是真正的第二向量源。

**验收标准**：参考模型、语料、NEMU、RTL 四方同步放开；全核 difftest 覆盖 LMUL=2/4/8；性能数据补充。

---

### T5 — 修复 chiseltest，跑通上游单元测试

**为什么**：`make test` 的 11 个用例全挂，根因是 chiseltest 6.0.0 生成的 harness 使用裸类型 `WData`，而 Verilator 5.052 已删除它（**版本不兼容，非本项目引入**）。Linux 上装 Verilator 4.x 或升级 chiseltest 即可绕开。价值中等——本项目已用 L1 差分测试替代，但跑通上游测试能增强「未破坏既有功能」的说服力。

---

### T6 — 提交物（视频、PPT、三册 PDF 已生成；Release、上传与加密提交待做）

**三段录屏**（赛题明文要求）：已由 `demo/video/` 的脚本生成三段演示视频（mp4 + `.srt`，分镜与数据来源见 `demo/video/storyboard.md`；视频三因体积不入库，随上传包提供）。下表为当初规划的素材：

| 录屏 | 内容 | 可依赖的现有产物 |
|---|---|---|
| ① 阶段一操作过程 | 环境部署、构建、hello 验证 | `scripts/00~03`、`logs/stage1/*.log` |
| ② 阶段二解题思路讲解 | vdot 语义（**先讲赛题官方伪代码与本项目的逐行对照、S-3'、`vl=8` 逐位等价**）、微架构、数据通路、RTL、三项测试 | `docs/stage2/10~13`（对照表在 `10` §1 开头）、`docs/_recon/figures/vdot_official_semantics.jpg`（官方语义图）、`logs/stage2/p3_official_pseudocode_equiv.log:40`（PASS 行）、`docs/stage1/figures/` |
| ③ 阶段三波形仿真与性能分析 | 协同仿真机制（Level 1 + 全核 difftest）、波形、加速比 | `docs/stage3/20~23`、`docs/stage3/figures/`、`logs/stage3/fullcore/`（`summary.log`、`fault_summary.log`、`fault_summary_s3old.log`、`wave_fullcore_vdot.png`；全核运行耗时长，录屏用预先跑好的日志） |

**PPT**：需覆盖三阶段解题思路、赛题官方语义与本项目的对照（`docs/ppt/讲解大纲.md` P5A）、微架构亮点（XOR 蝶形折叠树、三指令共享 16 路乘法阵列、零回退证据）、数据结论。分镜与逐页大纲已按 S-3' 更新（`docs/ppt/录屏脚本.md`、`docs/ppt/讲解大纲.md`），讲解 PPT 已由 `docs/submission/build/build_deck.py` 从大纲生成（`docs/submission/SNL-XiangShan-vdot-slides.pptx`，PDF 版随上传包提供），三册技术文档 PDF 由 `submission/upload/build-pdf.sh` 生成，生成命令见 `submission/upload/README.md`；四个上传包由 `submission/upload/build-bundles.sh` 生成。GitHub Release、大赛系统上传与下面的加密提交流程**尚未完成**。

**加密提交流程**（见大赛提交指南（上游 `OpenXiangShan/XiangShanLab` 仓库 `2026-CIE-RISC-V-Contest-Application-Track/SUBMISSION_GUIDE.md`，及大赛官网 https://rv.cie.org.cn））：
1. 本作品仓库转为 **public**（大赛硬性要求）
2. Fork `OpenXiangShan/XiangShanLab`
3. 在 `2026-CIE-RISC-V-Contest-Application-Track/` 下写 `my_submission.txt`（团队名、repo-url、GitHub 用户名、邮箱、项目描述 ≤100 字）
4. `source ./submit.sh my_submission.txt` 生成 `submission.asc`
5. 提 PR，标题格式 `[2026CIE大赛] 团队名称 - 项目名称`

---

## 四、必读陷阱清单（都是本项目踩过的真坑）

1. **分支**：赛题要的是 `kunminghu-v2`。`master` 是 KunminghuV3，向量单元被**完全重写**（新增 `backend/vector/` 区域），两者集成路径毫无共同之处。
2. **死代码**：`src/main/scala/xiangshan/backend/fu/vector/{VIPU,VIMacU,VIAluFix,...}.scala` 六个文件**整文件被注释**，改动必须落在 `backend/fu/wrapper/`。
3. **NEMU `.config` 是全局可变状态**：构建 `-ref` 会关掉所有串口，跑程序前必须 `make riscv64-xs-kmhv2_defconfig` 恢复。
4. **NEMU 按 PC 缓存译码**（`cpu-exec.c:784-793`），同一 PC 反复改写指令会复用首条译码结果。协同仿真中每条激励前需执行一条真 `fence.i` 刷 TCACHE。
5. **firtool 死代码消除**：昆明湖V2 的 FU 不自存流水副本，靠外部 `ctrlPipe/dataPipe/validPipe`。未驱动时整条 vdot 通路会被当死逻辑删掉（生成的 Verilog 里连 `VDotTree` 都没有）。
6. **L1 平台的 `io_out_valid` 由平台常量计数器产生**，不能用它"证实"DUT 延迟（循环论证）。须观测 DUT 内部寄存器与数据真正成形的拍。
7. **寄存器组对齐会掩盖缺陷**：用 `v1/v2/v3` 测 LMUL 守卫看似一致，实为对齐检查的副作用；必须用对齐的 `v8/v16/v24`。
8. **`gen_random_sew()`**：上游默认取不到 e8，不改就永远测不到 `vdot.vv`。
9. **裸机镜像需 `-no-pie`**：Ubuntu gcc 默认 `-pie`，`switch` 指针表靠动态重定位，objcopy 扁平镜像不会重定位。
10. **复位后 `mstatus.FS/VS=Off`**（`init.c:72-73`），不置位则 `vsetvli` 触发非法指令。
11. **全核 emu 必须用 clang++ 构建**：difftest 子模块 `OPT_FAST` 写死 clang 专有的 `-fno-slp-vectorize`（`difftest/verilator.mk:76`），g++ 直接报错；换 GCC 等价选项后 g++ 编译 Verilator 生成的超大单函数极慢（`docs/stage3/23_全核difftest验证报告.md` §3.3）。
12. **emu 的结果行在 stdout、`[PERF ]` 计数器在 stderr**：`2>&1 | grep` 合并过滤时两路交错可能吞掉 `HIT GOOD TRAP` 行，需分开收集（`23` §9 第 7 条）。

---

## 五、交接时的仓库约定

- `work/` 被 `.gitignore` 排除，**不入库**。上游仓库由 `scripts/00_setup_env_host.sh` 按 pin 克隆（Linux x86_64 与 macOS arm64 均可，见第二节「已有脚本与其适用性」）。
- 所有对上游的改动以 **patch 形式**沉淀在 `rtl/patch/`、`nemu/patch/`、`tests/unit/`，严禁直接提交上游工作树。
- `scripts/tools/sync_rtl_sources.sh --check` 校验 `rtl/chisel/` 与补丁是否漂移，**请纳入提交前检查**。
- 执行纪律（`MASTER_PLAN.md` 第 2 节）对接手方同样有效：**禁止伪造日志与数据，无法执行的必须标注「未执行」及原因**。本项目全部产物均满足该标准，请勿破坏。

---

## 六、遗留小项（交付整合时发现，未处理）

| 项 | 说明 | 建议 |
|---|---|---|
| ~~审计 I-3（阶段二部分）~~ **已处理** | 阶段二 3 张（`docs/stage2/figures/`，嵌入 `12` §10.2–10.4）、阶段三 3 张（`docs/stage3/figures/fig5–7`，嵌入 `22` §4.2）已由 `scripts/tools/make_stage23_figures.sh` 从入库 VCD 生成 | — |
| ~~`bench/results/latency_fu.csv` 措辞~~ **已处理** | 提交 `4d48f24` 已改生成脚本：`vwredsum`/`vredsum` 行为「数值未建模（未做数值比对）」，`vmul`/`vmacc` 行在 `VIMacU` 直驱补了数值比对后为「数值比对 64 笔一致」（`bench/results/latency_fu.csv:7,8,10,11`） | — |
| 指令计数口径 | 设计文档按 6→1（不含 vsetvli），P7 按 6→2（含 vsetvli），已在设计文档加注 | PPT 与录屏统一使用 6→2（3.00×，实测口径） |
| 守卫命名 | 方案文档称 `dotLmulIllegal`，代码为 `dotEmulIllegal`，已加注 | 无需改代码 |
| ~~阶段三独立审计~~ **已处理** | 已完成独立验收审计（`docs/_plan/ACCEPTANCE_P3.md`，预测 20/25，阻塞 0、重要 4、次要 9），全部问题已整改（提交 `98e4713`、`4d48f24`、`c913681`、`0cb8465`；逐条位置见该文件 §8「整改记录」） | 如需确认整改效果，可另行安排复审 |
