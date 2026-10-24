# 2026CIE「面向边缘AI大语言模型推理的RISC-V自定义vdot指令设计」总体方案与阶段验收标准

团队标识：**cie2026-vdot**

本文件是项目的唯一事实来源（Single Source of Truth）。所有阶段任务、交付物、验收标准以此为准。

---

## 0. 锁定的工程决策（D1–D4）

### D1 目标版本（已核实）
| 组件 | 选型 | 依据 |
|---|---|---|
| XiangShan | 分支 `kunminghu-v2` | README.zh-cn.md:65-68 明确「昆明湖-V2 → kunminghu-v2 分支」，且官方建议研究/验证优先选 V2（V3 向量单元重构中、功能不稳定）。`master` 分支是 KunminghuV3，**不是**赛题目标。 |
| NEMU | `master` + `riscv64-xs-kmhv2-ref_defconfig` | NEMU 官方提供 kmhv2 专用 difftest ref 配置。 |
| yunsuan / difftest / utility / rocket-chip | 由 `kunminghu-v2` 的 submodule pin 决定 | 保证与目标版本自洽。 |

> 所有仓库的精确 commit SHA 必须记录到 `docs/stage1/00_环境版本锁定.md`。

### D2 vdot 指令族语义（规范定义）

VLEN=128。基础指令 `vdot.vv` 对应赛题要求；另两条为本方案的扩展指令，三者**共享同一套 16 路 8×8 乘法阵列与可重构加法树**。

| 指令 | 编码 (funct6 / funct3 / opcode) | 生效条件 | 语义 |
|---|---|---|---|
| `vdot.vv vd, vs2, vs1` | `111001` / `000` (OPIVV) / `1010111` | `vtype.vsew = 8` | **四倍宽全向量归约**：`vd.u32[0] = Σ_{i=0}^{vl-1} sext32(vs2.i8[i]) × sext32(vs1.i8[i])`；`vd` 的其余元素按 `vta` 作为 tail 处理。对应赛题语义（vl=16 时为 16 路点积）。 |
| `vdotacc.vv vd, vs2, vs1` | `111010` / `000` (OPIVV) / `1010111` | `vtype.vsew = 8` | **累加变体**：`vd.u32[0] = vd.u32[0] + Σ ...`。`vd` 作为第三源读取（复用 `vmacc.vv` 已有的三源通路）。面向长向量 LLM 内积循环，消除循环内的独立累加指令。32 位回绕，不饱和。 |
| `vdot4a.vv vd, vs2, vs1` | `111011` / `000` (OPIVV) / `1010111` | `vtype.vsew = 32` | **分组点积累加**（Zvqdotq / ARM SDOT / x86 VPDPBUSD 风格）：`∀i<vl: vd.u32[i] += Σ_{j=0}^{3} sext(vs2.i8[4i+j]) × sext(vs1.i8[4i+j])`。VLEN=128 时产生 4 个结果。体现「向更高 SEW/VLEN 扩展」的能力。 |

**溢出分析**：int8×int8 ∈ [-16256, 16384]，16 项求和 |sum| ≤ 262144 < 2^31，`vdot.vv` 无溢出可能，无需饱和逻辑。`vdotacc`/`vdot4a` 的累加按 32 位模运算回绕。

**掩码/尾部**：遵循 RISC-V 归约指令惯例（参照 `vredsum.vs` / `vwredsum.vs`）。`vstart`、`vl`、`vm`、`vta` 行为在设计文档中逐项规定并实现。

#### D2.1 语义裁定（P3 参考模型阶段裁定，全项目强制遵守）
下列裁定已在 C 参考模型中实现并经 30663 条用例 + 故障注入验证，**RTL 与 NEMU 必须与之逐位一致**。完整论证见 `docs/stage2/13_参考模型与测试向量说明.md`「语义裁定记录」。

| 编号 | 裁定 | 依据 |
|---|---|---|
| S-1 | `vdot.vv` / `vdotacc.vv` 在 `vstart != 0` 时**抛出 Illegal Instruction** | RVV 1.0 §14：归约类指令 vstart 非零即非法。三点支撑：① NEMU `reduction_instr` 本就如此；② 基线用的 `vwredsum.vs` 同样禁止，否则基线与 vdot 不再功能等价，加速比失去意义；③ 归约无法中途重启。备用策略 `VDOT_VSTART_SKIP` 与非规范语料 `vstart_relaxed.txt` 已备好 |
| S-2 | 归约类（`vdot`/`vdotacc`）忽略 `vma` | 归约无 body-masked 目的元素 |
| S-3 | tail 按 **EEW=32** 处理，即元素 1..3 为 tail | 目的 EEW 为 32 |
| S-4 | 全部源元素被掩掉时，仍写 `vd[0] = 0`（`vdotacc` 为原值） | 归约单位元为 0 |
| S-5 | `vstart >= vl`（含 `vl = 0`）时**连 tail 都不写** | RVV 1.0 §5.4 |
| S-6 | 本版本固定 **LMUL = 1** | 赛题场景 SEW=8/VLEN=128 恰为单 uop；LMUL>1 作为扩展方向论述 |
| S-7 | `vdot4a.vv` 为逐元素指令，`vstart` 正常生效，子字节索引取 `4i+j` | 非归约 |
| S-9 | `vstart` 越界报错 | — |

> **对 P4 验收标准的修订**：原「`vstart≠0`」用例改为「`vstart≠0` 必须触发 Illegal Instruction」。FU 级平台若不建模异常，须跳过这些用例并在报告中写明跳过条数与原因。

#### D2.2 基线选型（P3 裁定）
单次点积基线选用**候选 D**（6 条指令）：`vsetvli e32` → `vmv.s.x` → `vsetvli e8` → `vwmul.vv` → `vsetvli e16` → `vwredsum.vs`，关键路径 3 级。长向量循环体基线刻意**不使用**会把归约放进循环的朴素候选 A，以免人为抬高加速比。详见 `bench/baseline/`。

**编码占用核实要求**：实现前必须用脚本证明 funct6=`111001/111010/111011` 在 OPIVV 空间内未被 RVV 1.0 占用，证据存入 `docs/stage2/`。

### D3 分层验证策略（L0–L4）
本机为 macOS/arm64、16GB 内存、Docker VM 8GB；XiangShan 全核 Verilator 构建官方要求 ~40GB JVM 堆且官方镜像仅 amd64。因此采用**分层验证**，并在文档中如实说明每层的覆盖范围与局限。

| 层级 | 内容 | 对应赛题要求 |
|---|---|---|
| **L0** | mill 精化（elaboration）+ 生成 Verilog | 2.2 RTL 实现可综合性 |
| **L1** | YunSuan 官方独立 FU 测试平台（`yunsuan/` 自带 `make emu`、VLEN=128、C++ golden model）+ Verilator | 2.3.1/2.3.2/2.3.3 正数/负数/边界功能测试 + 波形 |
| **L2** | NEMU 独立执行 vdot 程序 | 3.1.1 NEMU 指令扩展 |
| **L3** | NEMU ↔ RTL 协同仿真：将 NEMU 中**真实的 vdot C 实现**编译进 FU 测试平台作为参考模型，逐周期比对（非重写的近似模型）。延伸目标：全核 difftest | 3.1.2 协同仿真验证 |
| **L4** | 延迟/吞吐测量：RTL 周期数 + 流水线解析模型 + NEMU 指令计数；基线为现有 RVV 指令组合 | 3.2 基线实现 / 3.3 加速比分析 |

**诚实性要求**：任何未能实际运行的层级，必须在报告中明确标注「未执行」及原因，**严禁伪造日志或数据**。

### D4 交付仓库结构
```
docs/   stage1/ stage2/ stage3/ ppt/ _plan/ _recon/   设计与报告文档
rtl/    chisel/(源码与patch) verilog/(生成结果) patch/ RTL 交付
nemu/   patch/ 与说明                                  NEMU 扩展交付
tests/  unit/(FU级) riscv/(汇编/C 测试程序)            测试用例
bench/  基线实现与性能数据                              性能分析
scripts/ 一键复现脚本（环境、构建、测试、性能）          可复现性
logs/   stage1/ stage2/ stage3/ 真实运行日志与波形      证据
work/   上游仓库（.gitignore 排除）
```

---

## 1. 阶段任务分解、目标与验收标准

每个阶段由**执行方**完成，由**独立的验收方**按验收标准逐条核查；验收不通过则返工，直至通过。

### P1 环境部署与验证（赛题阶段一，15 分）
**目标**：在本机建立可复现的香山开发环境，产出环境验证信息、完整操作日志、向量加法指令执行过程分析。

**交付物**
- `scripts/00_setup_env_host.sh`：宿主机（macOS/arm64）一键环境搭建 —— 按锁定 commit 克隆 XiangShan `kunminghu-v2`（`a4eeaab`，含 11 个子模块 + rocket-chip `--recursive`）与 NEMU（`9090839`），并安装 verilator / openjdk@17 / mill / 原生 espresso
- `scripts/01_setup_env_docker.sh`：xsdev 容器镜像构建与进入（含 Docker 镜像定义 `scripts/docker/Dockerfile.xsdev`）
- `docs/stage1/00_环境版本锁定.md`：所有仓库 commit SHA、工具链版本
- `docs/stage1/01_环境部署报告.md`：部署全过程、遇到的问题与解决
- `logs/stage1/*.log`：真实终端日志
- 验证程序输出 `hello xiangshan, I am cie2026-vdot, IP address <本机IP>`
- `docs/stage1/02_向量加法指令执行过程分析.md`：基于**真实波形**分析 `vadd.vv` 在香山中的译码→拆分→发射→执行→写回全过程
- `logs/stage1/waveform/`：波形文件与截图

**验收标准（逐条 PASS/FAIL）**
1. 脚本可从零复现，验收方独立执行成功
2. 日志为真实终端输出（含时间戳、命令、真实报错与修复），非编造
3. hello 信息确由仿真器/模拟器实际执行 RISC-V 程序产生，附日志行号证据
4. 波形文件真实存在且可打开；分析文档中每个结论都能在波形上找到对应信号与时刻
5. 执行过程分析覆盖：指令编码 → 译码 → uop 拆分（LMUL/vl）→ 发射 → VIAlu 数据通路 → mask/tail 处理 → 写回，并标注香山源码 `文件:行号`
6. 文档中明确标注本层级的局限（若 hello 跑在 NEMU 而非全核 RTL，必须写明）

### P2 vdot.vv 设计文档（赛题阶段二 2.1，含在 20 分内）
**目标**：产出可直接指导 RTL 编码的完整设计文档。

**交付物**：`docs/stage2/10_vdot指令设计文档.md`

**验收标准**
1. 指令语义：D2 三条指令的完整规范（编码位域图、伪代码、vstart/vl/vm/vta/vma 行为表、溢出分析）
2. 编码空间占用证明（脚本 + 输出）
3. 微架构：模块层次图、流水级划分、时序图、关键路径估算
4. 数据通路：16 路 8×8 乘法阵列 + 可重构加法树的结构图、位宽推导、符号扩展策略
5. **复用说明**：逐项列出复用了香山/YunSuan 的哪些现有模块（`文件:行号`），自研部分占比
6. 集成点清单：每个需修改文件 + 修改内容 + 理由
7. 与 Zvqdotq / ARM SDOT / x86 VPDPBUSD 的对比表
8. 面积/功耗定性评估与扩展性论证（更高 SEW/VLEN/LMUL）

### P3 RTL 实现（赛题阶段二 2.2）
**交付物**：`rtl/chisel/`（新增模块源码）、`rtl/patch/*.patch`（对上游的改动）、`rtl/verilog/`（生成的 Verilog）、`docs/stage2/11_RTL实现说明.md`

**验收标准**
1. `mill` 精化通过，无错误；日志存档
2. 成功生成 vdot 功能单元的 Verilog，文件存在且可读
3. 改动以标准 patch 形式交付，`git apply` 可在干净的 kunminghu-v2 上应用成功（验收方实测）
4. 代码风格与香山一致；关键逻辑有中文注释
5. 确实复用了 YunSuan 现有乘法/加法结构，而非另起炉灶（验收方核对）
6. 三条指令均实现；译码、uop 拆分、FU 路由、写回全链路打通

### P4 功能测试（赛题阶段二 2.3.1/2.3.2/2.3.3）
**交付物**：`tests/unit/`、`scripts/20_run_func_tests.sh`、`docs/stage2/12_基础功能测试报告.md`、`logs/stage2/`

**验收标准**
1. 正数测试：≥20 组用例，全 PASS，日志为真实仿真输出
2. 负数测试：≥20 组（含全负、正负混合），全 PASS
3. 边界测试：覆盖 `+127/-128/0`、全 0、全 ±128、vl=0/1/15/16、`vstart≠0` 触发非法指令、vm 掩码、vta 两种取值，全 PASS（跳过项须说明原因与条数）
4. 另有 ≥10000 组随机差分测试对比 `tests/golden/vdot_ref.c`，0 失配。**禁止重写 golden model**，必须直接复用该实现
5. 测试报告含：用例表（输入/期望/实际）、波形截图、复现命令
6. 验收方独立重跑脚本，结果一致

### P5 NEMU 指令扩展（赛题阶段三 3.1.1）
**交付物**：`nemu/patch/*.patch`、`docs/stage3/20_NEMU指令扩展说明.md`、`logs/stage3/`

**验收标准**
1. NEMU 在本机实际编译成功（riscv64-xs-kmhv2 配置），日志存档
2. patch 可干净应用到 NEMU master，验收方实测
3. 三条指令在 NEMU 中执行结果与独立 C 参考模型一致（≥10000 随机 + 全部定向用例）
4. 正确处理 vl/vstart/vm/vta
5. 文档说明 NEMU 译码机制（INSTPAT/def_INSTR_TAB）与本次改动的对应关系，标注 `文件:行号`

### P6 NEMU↔RTL 协同仿真（赛题阶段三 3.1.2）
**交付物**：`scripts/30_run_cosim.sh`、`docs/stage3/21_协同仿真验证报告.md`、`logs/stage3/cosim/`

**验收标准**
1. 协同仿真实际运行，REF 侧确为 NEMU 的真实实现代码（非重写），在文档中给出代码引用证据
2. ≥10000 随机激励 + 全部定向用例，0 失配；日志存档
3. 文档讲清 difftest 机制：DUT commit → DPI-C → diffstate → ref_regcpy → compare（标注 difftest 源码 `文件:行号`），以及本方案的协同层级与全核 difftest 的异同
4. 故障注入自测：人为改坏 RTL 一位，协同仿真必须报错（证明比对有效），日志存档
5. 若全核 difftest 未运行，明确写明原因与已做的等价性论证

### P7 基线实现与加速比分析（赛题阶段三 3.2/3.3）
**交付物**：`bench/baseline/`、`bench/results/`、`scripts/40_run_bench.sh`、`docs/stage3/22_基线实现与延迟加速分析.md`

**验收标准**
1. 基线用现有 RVV 1.0 指令组合实现完全相同的功能（`vwmul`+`vwredsum` 等），在 NEMU 上验证与 vdot 结果逐位一致
2. 给出基线的指令序列、指令条数、各指令在昆明湖V2 上的延迟来源（引用香山 `LatDecoder`/FuConfig `文件:行号`）
3. vdot 延迟来自**实测 RTL 周期数**，非估算；估算部分明确标注
4. 加速比分析含：单次点积延迟对比、长向量（如 1024/4096 元素）循环吞吐对比、指令条数对比、关键路径/面积代价讨论
5. 至少一张数据图表，数据文件（CSV）与绘图脚本一并提交
6. 结论诚实：不夸大，列出所有假设与误差来源

### P8 交付整合（README/PPT/仓库整理）
**交付物**：`README.md`、`docs/ppt/讲解大纲.md`、`docs/00_项目总览.md`、提交清单

**验收标准**
1. README 含：赛题、方案概述、仓库导航、一键复现步骤、成果摘要表
2. 交付物与赛题 1.1–3.3 每一条逐项对照表，无遗漏
3. PPT 大纲覆盖三阶段解题思路、微架构亮点、数据结论
4. 全仓库检索：署名与作者信息统一为团队，文档用语规范；无占位符残留（TODO/TBD/xxx）
5. git 历史整洁，commit message 规范中文
6. 评分表四个一级指标逐项自评并给出证据位置

---

## 2. 执行纪律（全体成员必须遵守）
1. **禁止伪造**：所有日志、波形、数据必须来自真实执行。无法执行的必须标注「未执行」及原因。
2. **署名统一**：文件、注释、commit message 的署名与作者信息统一为团队。
3. **证据优先**：任何技术结论须附 `文件:行号` 或日志行号。
4. **只提交本地 commit**，不推送远端。
5. **不修改 `work/` 下上游仓库的 git 历史**；改动以 patch 形式沉淀到交付仓库。
