# 面向边缘 AI 大语言模型推理的 RISC-V 自定义 vdot 指令设计

**2026CIE 赛题**：「面向边缘AI大语言模型推理的RISC-V自定义vdot指令设计」（赛题原文 `target.md`，评分表 `score.md`）
**团队标识**：`cie2026-vdot`　｜　**目标平台**：香山昆明湖 V2（XiangShan `kunminghu-v2` @ `a4eeaab`，YunSuan @ `9559211`，NEMU @ `9090839`）

本项目在**最大限度复用昆明湖 V2 既有向量实现**的前提下，为其新增 int8 点积自定义指令族：赛题要求的
`vdot.vv`（SEW=8、VLEN=128，16 路 int8×int8 乘积归约到 32 位）以及两条共享同一数据通路的扩展指令
`vdotacc.vv`（累加变体）与 `vdot4a.vv`（SEW=32 下的 4 组×4 路分组点积累加）。交付物覆盖赛题三个阶段：
环境部署与 `vadd.vv` 波形分析 → 指令设计、Chisel RTL 与正数/负数/边界值测试 → NEMU 指令扩展、
NEMU↔RTL 协同仿真、RVV 1.0 基线实现与延迟加速比分析。所有日志、波形与数据均来自真实运行，
无法执行的部分一律标注「未执行」并说明原因。

> 逐条对照赛题要求、评分表自评与验证体系总览见 **[`docs/00_项目总览.md`](docs/00_项目总览.md)**。
> 项目唯一事实来源（决策 D1–D4、语义裁定、阶段验收标准）见 `docs/_plan/MASTER_PLAN.md`。

---

## 1. 成果摘要

「标注」一列说明数字的性质：**实测** = 真实工具跑出来、日志在库；**源码推导** = 从香山源码查找表算出；
**建模** = 用实测量按假设拼出的模型值，**不是**任何机器上测到的数。

### 1.1 功能与一致性

| 项目 | 结果 | 标注 | 证据 |
|---|---|---|---|
| 1.1 环境验证串 | `hello xiangshan, I am cie2026-vdot, IP address 192.168.30.213`，`HIT GOOD TRAP`，8115 条指令 | 实测（NEMU 上执行的裸机 RV64 程序） | `logs/stage1/p1_hello_xiangshan.log:97,115,118` |
| 2.3 功能测试总计 | **290103 条执行，0 失败**，9358 条按规范跳过（全部为架构非法用例，逐条有据） | 实测（FU 级 Verilator） | `logs/stage2/p5_summary.log:43,45` |
| 　其中 2.3.1 正数 / 2.3.2 负数 / 2.3.3 边界 | 120 / 132 / 424 条全 PASS（边界跳过 27 条） | 实测 | `docs/stage2/12_基础功能测试报告.md` §0 |
| 　其中随机差分（对 `tests/golden/vdot_ref.c`） | 235348 条，0 失配 | 实测 | `logs/stage2/p5_func_random.log` |
| 　其中直驱真正被集成的 `VIMacU` | 26024 条，0 失配 | 实测 | `logs/stage2/p5_summary.log`（VIMacU 等价行） |
| 译码级非法指令判定 | 51 条全 PASS；撤掉 LMUL 守卫后 13 条变红 | 实测 | `logs/stage2/p5_decode_illegal.log:120`、`p5_decode_prove_fail.log:134` |
| 既有指令零回归 | 9 个既有 FU 输出（含周期数）与 pristine 基线逐字相同；164 个共有 module 中 163 个去注释后逐字节相同（差异仅顶层 `SimTop`） | 实测 | `logs/stage2/p5_regression.log:31-39,52-54` |
| RTL 故障注入 | 5/5 被检出 | 实测 | `logs/stage2/p5_fault_injection.log:201-202` |
| 3.1.1 NEMU 指令扩展 | **30758 条语料 0 失配**；4834 条必须 trap 的用例全部以 `mcause=2` trap；difftest 参考共享库上同一语料 `trap code:0` | 实测 | `logs/stage3/p5_vdot_tests.log:87-90,116,126` |
| 　NEMU 补丁干净应用 / 故障注入 | 干净副本上重跑 30758/30758；故障注入 5/5 被检出（另 1 个经论证的等价变异体） | 实测 | `logs/stage3/p5_patch_verify.log:47,51`、`p5_fault_injection.log:165-169` |
| 3.1.2 协同仿真（**Level 1**：真实 NEMU `.so` ↔ Verilated 译码单元 + vdot 功能单元） | 72758 条激励；值比对 **55924/55924，0 失配**；非法判定 **分歧 0**（首轮 6415 条分歧经 G5a 补守卫 + 裁定 S-7' 后归零） | 实测 | `logs/stage3/cosim/p6_cosim_run.log:45-52`；首轮记录见 `docs/stage3/21_协同仿真验证报告.md` §7.4 |
| 　协同仿真故障注入 | 5/5 被检出（RTL 侧 2、NEMU 侧 3，其中一项专门守护 S-7'） | 实测 | `logs/stage3/cosim/p6_fault_injection.log:111` |
| 3.2 基线等价性 | RVV 1.0 基线序列与 vdot 指令族在 NEMU 上 **25924 条实跑用例逐位相同，0 失配**；长向量循环 24 个长度 0 失配 | 实测 | `logs/stage3/p7_baseline_equiv.log:112-114,144` |

### 1.2 延迟与加速比（赛题 3.3）

| 项目 | 基线 | vdot | 结果 | 标注 | 证据 |
|---|---:|---:|---:|---|---|
| vdot 三条指令的 FU 延迟 | — | 2 拍 | `VIMacU` 直驱 178/178/190 笔全部 2 拍且数据逐位正确；L1 波形 12×3 笔全部 2 拍 | 实测（FU 级） | `logs/stage3/p7_latency_measure.log:221-223`；`logs/stage3/waveform/p7_*.vcd` |
| 基线核心指令 FU 延迟 | `vmv.s.x` 1 拍、`vwmul.vv` 2 拍、`vwredsum.vs` 2 拍 | — | 与 `FuConfig` 声明值一致 | 实测（FU 级） | `bench/results/latency_fu.csv`；`p7_latency_measure.log:227,277,291` |
| `vsetvli` 延迟 | 0 拍 | 0 拍 | 未实测（落在整数侧 BJU2，不在向量 FU 平台内） | 声明值 | `docs/stage3/22_基线实现与延迟加速分析.md` §4.5 |
| 单次 16 元素点积：架构指令条数 | 6 | 2 | **3.00×** | 实测（反汇编） | `bench/results/speedup.csv` |
| 单次点积：向量算术指令条数 | 3 | 1 | **3.00×** | 实测 | 同上 |
| 单次点积：译码级 uop 条数 | 14 | 3 | **4.67×** | 源码推导 | 同上；`UopInfoGen.scala:197-235` |
| 单次点积：FU 延迟关键路径 | 4 拍 | 2 拍 | **2.00×** | **建模**（实测 FU 延迟按依赖链相加，假设完美前递、无端口冲突） | `bench/results/critical_path.csv`、`sensitivity.csv` |
| 长向量循环 N=4096：动态指令数 | 2575 | 2061 | **1.249×**（渐近 1.250×） | 实测（NEMU `minstret`，是指令数不是周期数） | `bench/results/instr_count_loop.csv`；`p7_baseline_equiv.log:160-167` |
| 长向量稳态吞吐 | 3 拍/迭代 | 2 拍/迭代 | **1.50×**（2 路累加器展开时 3.00×） | **建模**（FU 级平台测不到） | `docs/stage3/22_基线实现与延迟加速分析.md` §5.3 |

> 上表各行**量纲不同、不可互相替代**，不能挑最大的一个当作「加速比」。2.00× 的敏感性区间为
> 1.00×–5.00×（`bench/results/sensitivity.csv`）。`vdotacc` 的循环携带依赖为 2 拍，长于基线的 1 拍：
> 在延迟受限且软件不做累加器展开的场景下长向量吞吐**可能不升反降**，这是本加速比结论的最大威胁（`22` §5.4）。

---

## 2. 设计亮点

1. **最大限度复用香山既有实现**
   * 16 路 8×8 乘法阵列**零新增**：直接取自既有 2 片 `VIMac64b` 的部分积，仅新增一个只读输出端口 `prod16`（`VIMac64b.scala` +7 行）；
   * 加法树全部例化 YunSuan 既有原语 `CSA4to2` / `CSA3to2`（生成网表实测 12 + 4 个实例）；
   * `Mgu`、`ByteMaskTailGen`、`VecPipedFuncUnit`、`VecDataSplitModule` 零改动复用；
   * **`FuConfig` / `FuType` / `Parameters` / Dispatch / IQ / WbArbiter 一行未改**——vdot 挂在既有 `VimacCfg`（`latency = CertainLatency(2)` 不变）上，调度、唤醒与写回网络完全不受影响；
   * 零回归有三重证据：既有 FU 输出逐字相同、163/164 module 网表去注释后逐字节相同、`vmul`/`vwmul`/`vmacc` 实测延迟仍为 2 拍（`docs/stage2/11_RTL实现说明.md` §7、`docs/stage3/22` §7.2）。
   * 新增算术逻辑约 13.7%（全加器等价**结构计数上界**，非综合结果；`docs/stage2/10_vdot指令设计文档.md` §5.3）。
2. **XOR 蝶形折叠加法树**（`docs/stage2/10` §4.4）：同一组 12 个 `CSA4to2(32)` 由 2 bit `foldLevels` 控制，伙伴 lane 取 `g XOR Δ`，
   一棵树同时覆盖「16 路全归约」与「4 组×4 路」两种形态；结果路径上零选择器，模式切换只作用在加数输入端的 AND 门上，
   全折叠时每个 lane 都持有总和、元素 0 定位无需额外逻辑，向更大 VLEN 扩展只需增加折叠级数。
3. **三条指令共享一条数据通路**：`vdot.vv` / `vdotacc.vv` / `vdot4a.vv` 共用同一乘法阵列与同一棵可重构加法树，
   区别只在 `foldLevels` 与累加操作数注入；三者实测同为 2 拍。
4. **协同仿真抓到了自写黄金模型永远抓不到的冲突（裁定 S-7'）**：原裁定 S-7 允许 `vdot4a` 在 `vstart != 0` 时正常执行；
   参考模型、NEMU、RTL 数据通路都按 S-7 实现，彼此「一致地正确」。只有在 Level 1 协同仿真里，NEMU 被拿去和香山
   **上游未改动的**译码判据 `vstartIllegal = isVArith && vstart =/= 0` 比对时，才暴露出 1946 条确定性分歧——
   错的不是实现，而是 ISA 裁定比目标微架构更宽。按「平台约束优先原则」修订为 S-7'（`vdot4a` 在 `vstart != 0` 时同样非法），
   RTL 一行未改即收敛（`docs/stage3/21_协同仿真验证报告.md` §7.3–§7.5、`docs/_plan/MASTER_PLAN.md` D2.3）。

---

## 3. 仓库导航

| 目录 / 文件 | 内容 |
|---|---|
| `target.md`、`score.md`、根目录 PDF | 官方赛题、评分表与提交操作手册 |
| `docs/00_项目总览.md` | 赛题逐条对照表、评分表自评、语义裁定史、验证体系总览 |
| `docs/_plan/` | `MASTER_PLAN.md`（唯一事实来源）、`HANDOFF_TODO.md`（交接与后续工作）、阶段一/二独立验收审计与整改记录（`ACCEPTANCE_*.md` 为历史记录，不随后续修订改写） |
| `docs/_recon/` | 动手前的源码侦察笔记（昆明湖 V2 向量集成点、NEMU/difftest、vdot 语义调研） |
| `docs/stage1/` | 环境版本锁定、部署报告、`vadd.vv` 执行过程分析、仿真平台搭建报告；`figures/` 6 张波形图 |
| `docs/stage2/` | `10` 设计文档、`11` RTL 实现说明、`12` 基础功能测试报告、`13` 参考模型与测试向量说明；`figures/` 3 张 vdot 功能波形图 |
| `docs/stage3/` | `20` NEMU 指令扩展说明、`21` 协同仿真验证报告、`22` 基线实现与延迟加速分析；`figures/` 4 张数据图 + 3 张延迟实测波形图 |
| `docs/ppt/` | 答辩材料目录（**当前为空**，见局限性） |
| `rtl/patch/` | 对上游的正式交付：`0001-xiangshan-vdot.patch`、`0002-yunsuan-vdot.patch` |
| `rtl/chisel/` | 打完补丁后全部新增/修改 Chisel 源码的只读副本（`MANIFEST.md`），由 `scripts/tools/sync_rtl_sources.sh` 重建与校验 |
| `rtl/verilog/` | 生成的 Verilog：`vdot/`（`VDotTree.sv`、`VDotTop.sv`、`VIMacU.v`、`DecodeUnit.v` 等）与 `baseline/`（零回归对照） |
| `nemu/` | NEMU 扩展补丁 `patch/0001-add-vdot-instruction-family.patch` 与使用说明 |
| `tests/golden/` | C 参考模型 `vdot_ref.c`（语义唯一事实来源，各测试平台直接 `#include`，不重写） |
| `tests/vectors/` | 共享语料：13 个 suite、30703 条，由参考模型生成 |
| `tests/unit/` | FU 级测试平台：L1 测试平台补丁、`VIMacU`/`VecExceptionGen` 直驱、FU 延迟实测 harness |
| `tests/riscv/` | 裸机 RV64 程序：`hello/`（1.1）、`vdot/`（NEMU 一致性）、`baseline/`（基线等价性与指令计数） |
| `tests/cosim/` | NEMU↔RTL 协同仿真驱动与译码探针 |
| `bench/` | RVV 1.0 基线实现（`baseline/`）、结果数据（`results/*.csv`）、日志→CSV→图表脚本 |
| `scripts/` | 编号一键复现脚本；`tools/` 为辅助工具（波形抽取、补丁校验、故障注入等）；`docker/` 为容器镜像定义 |
| `logs/stage1,2,3/` | 真实终端日志；`waveform/` 下为被文档逐值引用的 8 份 VCD 与文本轨迹 |
| `work/` | 上游仓库工作区（`.gitignore` 排除，不入库），由 `scripts/00_setup_env_host.sh` 按锁定 commit 克隆 |

---

## 4. 复现快速上手

**本快照的验证平台**：macOS 15.5 / Darwin 24.5.0 arm64（Apple Silicon，16 GB）+ Docker 容器
`xsdev:ubuntu24.04-arm64`（NEMU 构建、RISC-V 交叉编译在容器内）；Verilator 5.052、OpenJDK 17、
mill 0.12.3（XiangShan）/ 0.11.1（YunSuan）。在 x86_64 Linux 上复现的改动点见
[`docs/_plan/HANDOFF_TODO.md`](docs/_plan/HANDOFF_TODO.md) 第二节（`00` 号脚本需改写，其余脚本可直接使用）。

```bash
bash scripts/00_setup_env_host.sh       # 宿主机工具链 + 按锁定 commit 克隆上游到 work/（macOS/brew 专用）
source scripts/env_host.sh               # 每个新 shell 先导入 PATH / JAVA_HOME
./scripts/01_setup_env_docker.sh build   # 构建 xsdev 容器镜像（NEMU 与交叉工具链）
./scripts/02_build_nemu.sh               # 容器内构建 NEMU 独立解释器与 difftest 参考共享库
./scripts/03_run_hello.sh                # 1.1：裸机程序在 NEMU 上打印 hello 串
bash scripts/10_build_yunsuan_sim.sh     # L1：YunSuan 官方 FU 仿真平台（WAVE=1 抓 vadd 波形，1.3）
bash scripts/11_build_vdot_sim.sh        # L0/L1：带 vdot 的 RTL 精化、构建与冒烟测试
bash scripts/20_run_func_tests.sh        # 2.3：正数/负数/边界/随机/回归/译码级/VIMacU 直驱全套功能测试
./scripts/21_build_nemu_vdot.sh          # 3.1.1：打 NEMU 补丁、构建两种形态、跑 30758 条语料
./scripts/30_run_cosim.sh                # 3.1.2：NEMU↔RTL Level 1 协同仿真（加参数 fault 跑故障注入）
bash scripts/40_run_bench.sh             # 3.2/3.3：基线等价性、FU 延迟实测、CSV 与图表
```

| 脚本 | 做什么 | 主要产物 | 本快照验证情况 |
|---|---|---|---|
| `00_setup_env_host.sh` | 安装 verilator / openjdk@17 / mill / 原生 espresso，按 pin 克隆 XiangShan（11 个子模块）与 NEMU | `work/` | macOS/arm64；Linux 需改写 |
| `01_setup_env_docker.sh` | 构建并进入 xsdev 容器 | `logs/stage1/p1_docker_build.log` | macOS + Docker（arm64 镜像） |
| `02_build_nemu.sh` / `03_run_hello.sh` | 构建 NEMU；运行 1.1 验证程序 | `logs/stage1/p1_nemu_build.log`、`p1_hello_xiangshan.log` | 同上 |
| `10_build_yunsuan_sim.sh` | YunSuan L1 平台 + `vadd.vv` 波形 | `logs/stage1/waveform/` | macOS/arm64 宿主机 |
| `11_build_vdot_sim.sh` | vdot RTL 精化、Verilog、L1 冒烟 | `logs/stage2/p4_*.log`、`rtl/verilog/vdot/` | macOS/arm64 宿主机 |
| `20_run_func_tests.sh` | 阶段二全部功能测试并生成汇总表 | `logs/stage2/p5_*.log` | macOS/arm64 宿主机 |
| `21_build_nemu_vdot.sh` | NEMU 扩展构建与一致性测试（`fault` / `verify-patch` 子命令） | `logs/stage3/p5_*.log` | 容器内 |
| `30_run_cosim.sh` | 协同仿真（宿主机 Verilator + 容器内链接 NEMU `.so`） | `logs/stage3/cosim/` | 宿主机 + 容器 |
| `40_run_bench.sh` | 基线等价性（容器内 NEMU）+ FU 延迟实测（宿主机）+ 绘图 | `logs/stage3/p7_*.log`、`bench/results/`、`docs/stage3/figures/` | 宿主机 + 容器 |

提交前自检：`bash scripts/tools/sync_rtl_sources.sh --check`（校验 `rtl/chisel/` 与补丁无漂移，只读）、
`bash scripts/tools/verify_patches.sh`（三份补丁可干净应用到 pristine 上游）。

---

## 5. 局限性（如实说明）

1. **协同仿真是 Level 1，不是全核 difftest。** REF 侧是真实的 NEMU difftest 共享库，但 DUT 是「vdot 功能单元 + 译码单元」
   而不是整个乱序核。它证明了「一条 vdot 该算出什么、该不该报非法」，**没有**证明它在流水线里被正确发射、旁路、提交、
   异常被正确投递。原因是内存：全核 Verilator 构建官方要求约 40 GB JVM 堆，本机 16 GB（`docs/stage1/03_仿真平台搭建报告.md` §7.1）。
   同理，阶段二的三项功能测试运行在 FU 级平台而非全核仿真上，阶段一的 hello 程序运行在 NEMU 上而非香山 RTL 上。
2. **`latency = 2` 由静态逻辑级估算 + FU 级实测支撑，没有综合。** FU 级实测证明 RTL 在第 2 拍给出正确结果；
   能否在目标频率下时序收敛未经综合与静态时序分析验证。面积 13.7% 是结构计数上界，功耗未量化。
3. **LMUL 固定为 1**（裁定 S-6）：`LMUL != 1` 的 vdot 一律判非法；多 uop 累加链方案已在设计文档 §8.3 论证但未实现。
4. **吞吐加速比是建模值。** 1.50× / 3.00× 来自端口与依赖下界模型；单次点积的 2.00× 也是把实测 FU 延迟按依赖链相加的模型值。
   实测的只有 FU 延迟、指令条数与功能等价性。`vsetvli` 延迟为声明值；uop 条数为源码推导。
5. **提交物未完成**：赛题要求的三段录屏、答辩 PPT（`docs/ppt/` 为空）与加密提交流程均**未做**。
6. 阶段二波形以 VCD + 文本轨迹交付，未另附截图；`tests/unit/VectorSimTop.scala` 等上游派生文件中保留了上游原有的
   `TODO`/`FIXME` 注释（本项目补丁未新增任何此类注释）。

后续工作（全核 difftest、综合、真实 LLM 负载、LMUL>1、提交物）按投入产出比排序见
[`docs/_plan/HANDOFF_TODO.md`](docs/_plan/HANDOFF_TODO.md)。
