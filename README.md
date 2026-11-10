# XiangShan-vdot：面向边缘 AI 大语言模型推理的 RISC-V 自定义 vdot 指令设计

**团队**：SNL（仓库技术标识 `cie2026-vdot`）　｜　**作品**：XiangShan-vdot　｜　**赛题**：2026CIE「面向边缘AI大语言模型推理的RISC-V自定义vdot指令设计」（`target.md`，评分表 `score.md`）
**目标平台**：香山昆明湖 V2（XiangShan `kunminghu-v2` @ `a4eeaab`，YunSuan @ `9559211`，NEMU @ `9090839`）

**一句话**：在最大限度复用昆明湖 V2 既有向量实现的前提下（乘法阵列零新增，调度与写回网络一行未改），新增 int8 点积指令 `vdot.vv`
及共享同一数据通路的 `vdotacc.vv` / `vdot4a.vv`，完成赛题三个阶段（环境与 `vadd.vv` 分析 → 设计、RTL 与测试 → NEMU、协同仿真与加速比）的全部技术交付。

> **主结论**：MinimalConfig 全核实测 latency 加速比——单次 16 元素点积 **1.70×**（函数整体，52 → 30.5 拍），长向量稳态 **1.81× / 2.25×**（单累加器 / 2 路累加器，12.64 → 7.00 / 5.63 拍每 16 个 int8）。
> **适用范围**：只对香山 MinimalConfig 全核 emu（热态、带 difftest）成立，默认配置（KunminghuV2Config）未测、未综合；建模值等其余口径只作参考（§1.2）。
> **与赛题官方语义的关系**：`vl = 8` 时与赛题官方 `vdot_vv` 伪代码逐位等价（伪代码字面实现对参考模型 20570 条 0 失配，`logs/stage2/p3_official_pseudocode_equiv.log:40`）；`vl = 16` 为满寄存器版本（裁定 S-3'）。

**阅读路径**：本页 → [`docs/00_项目总览.md`](docs/00_项目总览.md)（详细版：逐条证据、完整数据表、局限详细说明）→ 各阶段文档开头的「本文速览」→ 正文。
复现见 [`docs/01_复现指南.md`](docs/01_复现指南.md)。所有数字均来自真实运行，证据写作「文件:行号」；无法执行的部分标注「未执行」。

---

## 1. 成果摘要

### 1.1 赛题 1.1–3.3 对照

| 条目 | 状态 | 结果 | 关键证据 |
|---|---|---|---|
| 1.1 环境部署验证 | ✅ | NEMU 打印验证串、`HIT GOOD TRAP`（8115 条）；全核 emu 复跑 8369 条 / 68522 拍 | `logs/stage1/p1_hello_xiangshan.log:97,115,118` |
| 1.2 操作日志 | ✅ | 11 个日志 17826 行，含 4 次真实失败；Linux 全新目录复现记录 | [`logs/stage1/linux_repro/`](logs/stage1/linux_repro/README.md) |
| 1.3 `vadd.vv` 执行过程 | ✅ | FU 级波形 + 源码级论证 + 全核一条 `vadd.vv` 的逐级时刻 | [`docs/stage1/02`](docs/stage1/02_向量加法指令执行过程分析.md) §0 |
| 2.1 设计文档 | ✅ | 三条指令语义、微架构、数据通路；官方伪代码逐行对照 | [`docs/stage2/10`](docs/stage2/10_vdot指令设计文档.md) §1 开头 |
| 2.2 RTL 实现 | ✅ | Chisel 补丁两份，乘法阵列零新增，`FuConfig` 不改 | [`rtl/patch/`](rtl/patch/)、[`docs/stage2/11`](docs/stage2/11_RTL实现说明.md) |
| 2.3.1 正数测试 | ✅ | FU 级 132 条、全核 132 条全 PASS | `logs/stage3/fullcore/corpus_b00.log:22,25,28` |
| 2.3.2 负数测试 | ✅ | FU 级 144 条、全核 144 条全 PASS（含 `0x80×0x80`） | `logs/stage3/fullcore/corpus_b00.log:23,26,29` |
| 2.3.3 边界值测试 | ✅ | FU 级 436 条、全核 333 条全 PASS（27 条必须 trap） | `logs/stage3/fullcore/corpus_b00.log:24,27,30,38-39` |
| 2.3 合计 | ✅ | FU 级 290175 条执行 0 失败；RTL 故障注入 6/6 检出 | `logs/stage2/p5_summary.log:43,45` |
| 3.1.1 NEMU 扩展 | ✅ | 30794 条语料 0 失配，4834 条必须 trap 全部 `mcause=2` | `logs/stage3/p5_vdot_tests.log:90-93` |
| 3.1.2 协同仿真 Level 1 | ✅ | 72794 条激励，值比对 55960/55960，判定分歧 0 | `logs/stage3/cosim/p6_cosim_run.log:45-52` |
| 3.1.2 全核 difftest Level 2 | ✅ | MinimalConfig 24,524,262 条提交 0 失配 | `logs/stage3/fullcore/summary.log:1-37` |
| 3.2 基线实现 | ✅ | RVV 1.0 基线与 vdot 25960 条用例逐位相同 | `logs/stage3/p7_baseline_equiv.log:114-117` |
| 3.3 延迟加速分析 | ⚠️ | 全核实测 1.70× / 1.81× / 2.25×；只测 MinimalConfig | [`docs/stage3/22`](docs/stage3/22_基线实现与延迟加速分析.md) §5.5 |

逐条交付物、判定理由与全部证据见 [`docs/00_项目总览.md`](docs/00_项目总览.md) §1（对照表）、§5.1（功能与一致性详表）。

### 1.2 延迟与加速比（赛题 3.3）

| 主结论口径（MinimalConfig 全核实测） | 基线 | vdot | 加速比 | 与建模值比较 |
|---|---:|---:|---:|---|
| 单次 16 元素点积（函数整体，含 2 条装载与结果取回） | 52 拍 | 30.5 拍 | **1.70×** | 低于建模 2.00× |
| 长向量稳态，`vdotacc` 单累加器（每 16 个 int8） | 12.64 拍 | 7.00 拍 | **1.81×** | 高于建模 1.50× |
| 长向量稳态，2 路累加器展开（每 16 个 int8） | 12.64 拍 | 5.63 拍 | **2.25×** | 低于建模 3.00× |

证据：`logs/stage3/fullcore/perf_cycles.log:9-48,109-133,184-233`、`bench/results/cycles_fullcore.csv`。参考口径（指令条数 3.00×、uop 4.67×、
FU 关键路径 2.00× 与吞吐 1.50× / 3.00× 建模、序列本体 5.17× / 加取回 2.81×、长向量指令数 1.249×）量纲不同，不替代主结论，全表见 `docs/00_项目总览.md` §5.2。

---

## 2. 亮点

1. **最大限度复用**：16 路 8×8 乘法阵列零新增（取自既有 `VIMac64b` 部分积），`FuConfig` / Dispatch / IQ / WbArbiter 一行未改，164 个共有 module 中 163 个网表逐字节相同。
2. **XOR 蝶形折叠加法树**：同一组 12 个 `CSA4to2(32)` 覆盖 16 路全归约与 4 组×4 路，三条指令共享一条数据通路，数据成形拍同为 2 拍（`docs/stage2/10` §4.4）。
3. **与官方语义逐位对齐且保留 `vl` 机制**（裁定 S-3'）：RTL 只改写回成形两处，`vl = 8` 与伪代码 20570 条 0 失配（`docs/stage2/10` §1 开头）。
4. **验证暴露规范缺陷**：协同仿真把裁定 S-7 与上游 `vstartIllegal` 的冲突量化为 1946 条确定性分歧，修订为 S-7'，RTL 一行未改（`docs/stage3/21` §7.5）。
5. **测试会红**：故障注入 FU 级 6/6、NEMU 6/6、协同仿真 7/7、全核 3/3 + 3/3 全部检出；L0–L5 每层写明证明了什么、证明不了什么（`docs/00_项目总览.md` §4）。

详细说明见 `docs/00_项目总览.md` §6。

---

## 3. 局限性

1. 全核 difftest 与全核周期实测只跑了 **MinimalConfig**；默认配置（KunminghuV2Config）未运行，周期数只对 MinimalConfig 有效。
2. **未综合**：`latency = 2` 只有静态逻辑级估算 + FU 级实测；时序收敛、真实面积（13.7% 为结构计数上界）与功耗未知。
3. **未达建模值**：2.25× 低于建模 3.00×，1.70× 低于建模 2.00×；基线 D 每迭代 12.64 拍的瓶颈未定位。
4. 2.00×、1.50× / 3.00× 为**建模值**，uop 条数为源码推导，`vsetvli` 延迟为声明值，均单独标注。
5. LMUL 固定为 1（LMUL≠1 只在 Level 1 验证）；全核依赖测试是 10 个固定模板，不是随机指令流；未做真实 LLM 负载评测。
6. 提交状态：GitHub Release `v1.0-submission` 已于 2026-11-08 发布（四个上传包、三册技术文档 PDF、讲解 PPT PDF 与 `SHA256SUMS`）；加密提交（`submit.sh` 生成的 `submission.asc`）已通过 XiangShanLab PR #171 提交（截至 2026-11-10 为 open）；大赛官网材料上传由团队完成。

各条详细说明与后续工作排序见 `docs/00_项目总览.md` §8。

---

## 4. 快速复现

Linux x86_64，需 JDK 17、Verilator 5.x、RISC-V 交叉 GCC ≥ 12；全核 difftest 另需 clang++ 与 ≥64 GB 内存。复跑默认覆盖仓库存档，只想验证时把 `LOG_ROOT` / `RESULTS_DIR` / `FIG_DIR` 指到别处。

```bash
bash scripts/00_setup_env_host.sh     # 依赖检查、按锁定 commit 克隆上游到 work/、生成补丁工作树
for s in 02_build_nemu 03_run_hello 10_build_yunsuan_sim 11_build_vdot_sim 20_run_func_tests \
         21_build_nemu_vdot 30_run_cosim 40_run_bench; do bash scripts/$s.sh || break; done   # 1.1 → 3.3（FU 级 / NEMU / Level 1 / 基线）
bash scripts/50_run_fullcore_difftest.sh build && bash scripts/50_run_fullcore_difftest.sh run   # Level 2 全核 difftest
bash scripts/50_run_fullcore_difftest.sh perf                                                    # 3.3 全核周期实测
```

依赖清单、每个脚本的作用与实测耗时、已知差异与提交前自检见 [`docs/01_复现指南.md`](docs/01_复现指南.md)。

---

## 5. 仓库导航

| 路径 | 内容 |
|---|---|
| `docs/00_项目总览.md` | 详细版：赛题逐条对照、评分表自评、语义裁定史、验证体系、成果详表、亮点与局限详细说明 |
| `docs/01_复现指南.md` | 依赖、一键复现命令、各脚本实测记录与已知差异 |
| `docs/stage1/`、`docs/stage2/`、`docs/stage3/` | 三个阶段的技术文档（每篇开头有「本文速览」） |
| `docs/ppt/`、`docs/submission/` | 讲解大纲、录屏脚本、提交清单；讲解 PPT 及其生成脚本 |
| `rtl/` | `patch/` 对上游的正式补丁，`chisel/` 打补丁后的 Chisel 源码副本，`verilog/` 生成的 Verilog |
| `nemu/` | NEMU 扩展补丁与使用说明 |
| `tests/` | `golden/` C 参考模型，`vectors/` 共享语料，`unit/` FU 级平台，`riscv/` 裸机程序，`cosim/` 协同仿真驱动 |
| `bench/` | RVV 1.0 基线实现、结果 CSV、绘图脚本 |
| `scripts/` | 编号一键复现脚本与辅助工具 |
| `logs/` | 真实终端日志、波形 VCD 与文本轨迹 |
| `demo/video/`、`submission/upload/` | 演示视频生成脚本与成品；技术文档 PDF 与上传包的生成脚本 |
| `target.md`、`score.md` | 赛题原文、评分表 |
| `docs/_plan/`、`docs/_recon/` | 过程记录（审计、调研），评审无需阅读 |

---

## 6. 评审材料

| 材料 | 位置 |
|---|---|
| 讲解 PPT | `docs/submission/SNL-XiangShan-vdot-slides.pptx`（PDF 版随上传包及 Release 提供） |
| 演示视频 ①②③ | `demo/video/SNL-XiangShan-vdot-video{1,2,3}-stage{1,2,3}.mp4` 与同名 `.srt`；视频三 mp4 因体积不入库，随上传包及 Release 提供 |
| 技术文档三册 PDF | `SNL-XiangShan-vdot-vol{1,2,3}-stage{1,2,3}.pdf`，随上传包及 Release 提供 |

生成命令见 `submission/upload/README.md`（PDF、PPT）与 `demo/video/storyboard.md`（视频）。
