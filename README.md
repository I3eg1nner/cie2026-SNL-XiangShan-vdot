# 面向边缘 AI 大语言模型推理的 RISC-V 自定义 vdot 指令设计

**2026CIE 赛题**：「面向边缘AI大语言模型推理的RISC-V自定义vdot指令设计」（赛题原文 `target.md`，评分表 `score.md`）
**团队标识**：`cie2026-vdot`　｜　**目标平台**：香山昆明湖 V2（XiangShan `kunminghu-v2` @ `a4eeaab`，YunSuan @ `9559211`，NEMU @ `9090839`）

本项目在**最大限度复用昆明湖 V2 既有向量实现**的前提下，为其新增 int8 点积自定义指令族：赛题要求的
`vdot.vv`（SEW=8、VLEN=128，`vl` 个 int8×int8 乘积归约到 32 位，`vl=8` 即赛题官方伪代码，`vl=16` 为满寄存器 16 路）以及两条共享同一数据通路的扩展指令
`vdotacc.vv`（累加变体）与 `vdot4a.vv`（SEW=32 下的 4 组×4 路分组点积累加）。交付物覆盖赛题三个阶段：
环境部署与 `vadd.vv` 波形分析 → 指令设计、Chisel RTL 与正数/负数/边界值测试 → NEMU 指令扩展、
NEMU↔RTL 协同仿真（FU 级 Level 1 + MinimalConfig 全核 difftest Level 2）、RVV 1.0 基线实现与延迟加速比分析。所有日志、波形与数据均来自真实运行，
无法执行的部分一律标注「未执行」并说明原因。

> **与赛题官方语义的关系**：赛题页给出 `vdot_vv` 的 8 行 Python 伪代码（两个源寄存器各取 8 个 int8，符号扩展相乘求和写入 `vd[0]`，
> `vd[1..VLEN-1] = 0  # 其他通道清零`）。本项目据此把语义修订为**裁定 S-3'**：`vdot.vv` / `vdotacc.vv` 在 `vstart < vl` 时 `vd[31:0]` 写结果、
> `vd[VLEN-1:32]` 恒为 0，与 `vta` / `vma` 无关；`vl = 0` 时不写；`vdot4a.vv` 不变。保留 `vl` 机制作为字面语义的超集：
> **`vl = 8` 时与官方伪代码逐位等价**（伪代码字面实现对参考模型，20570 条 0 失配，`logs/stage2/p3_official_pseudocode_equiv.log:40`；
> 阴性对照：修订前语料 532 条全部失配，同日志 `:62`）。伪代码原文、逐行对照、「8」的来源与「清零」的取舍见
> `docs/stage2/10_vdot指令设计文档.md` §1 开头「赛题官方语义与逐行对照（S-3' 的依据）」，裁定见 `docs/_plan/MASTER_PLAN.md` D2.4。
> S-3' 之后参考模型、RTL、NEMU 与全部测试（FU 级、NEMU、协同仿真、基线、全核 difftest、周期实测）均已重跑，下文数字都是重跑后的结果。

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
| 　同一程序在香山全核 emu 上 | 源码不改，只把地址常量头文件换成香山 SoC 的值（与 NEMU 配置相同）；带 difftest 运行，打印 `hello xiangshan, I am cie2026-vdot, IP address 172.100.0.6`（运行 emu 的服务器的本机 IP），`HIT GOOD TRAP`，8369 条指令 / 68522 周期 | 实测（MinimalConfig 全核 emu + difftest） | `logs/stage1/p1_hello_xiangshan_fullcore.log:67,76-77` |
| 赛题官方语义一致性 | `vl=8`、`vm=1`、`vstart=0` 时参考模型与赛题官方伪代码的字面实现比对 128 位 `vd` 全部位：语料 285 + 285 条、随机 10000 + 10000 条（`vd` 初值、`vta`、`vma`、源寄存器第 8..15 个元素全随机），**20570 条 0 失配**；阴性对照（修订前 S-3 语料）532 条全部失配；**全核 `vl = 8` 主演示**：MinimalConfig 全核 emu + difftest 上执行 `vdot.vv` / `vdotacc.vv`（`vl=8`、`vta=1`，源寄存器第 8..15 个元素填 `0x7f`/`0x80` 干扰值），结果 `vd = …000000cc`（Σ i²，i=1..8 = 204）/ `…000004b4`（1000 + 204），元素 1..3 清零，`HIT GOOD TRAP`（instrCnt = 49） | 实测（Python 字面实现 vs C 参考模型；全核 Verilator） | `logs/stage2/p3_official_pseudocode_equiv.log:30-31,34-35,40,62`；对照见 `docs/stage2/10_vdot指令设计文档.md` §1 开头；全核：`logs/stage3/fullcore/wave_vl8_run.log:59-60`、`wave_vl8_trace.txt:76-81`、`docs/stage3/23` §7.3、`docs/stage3/figures/fig10_fullcore_vdot_vl8_wave.png` |
| 2.3 功能测试总计 | **290175 条执行，0 失败**，9358 条按规范跳过（全部为架构非法用例，逐条有据）。其中 **vdot 用例 262171 条**（定向 712 + 随机差分 235348 + 直驱 `VIMacU` 26060 + 译码级定向 51），**非 vdot 项 28004 条**（既有指令回归 28000 + 反向验证 1 + 补丁应用 3） | 实测（FU 级 Verilator） | `logs/stage2/p5_summary.log:5-43,45`；拆分见 `docs/stage2/12_基础功能测试报告.md` §0.1 |
| 　其中 2.3.1 正数 / 2.3.2 负数 / 2.3.3 边界 | **FU 级**：132 / 144 / 436 条全 PASS（436 = 规范边界 306 + 非规范 `vstart_relaxed` 130；规范边界另 27 条必须 trap，FU 级跳过；三类各含 `vdot`/`vdotacc` 的 `vl=8` 定向用例 12 条）。**全核**（香山昆明湖V2 MinimalConfig + difftest，逐条与 NEMU 比对）：132 / 144 / 333 条全 PASS（333 = 3 个规范边界文件全部行，其中 27 条必须 trap 全部 `mcause=2`），difftest 0 失配 | 实测（FU 级 Verilator；全核 Verilator） | `docs/stage2/12_基础功能测试报告.md` §0.1、§0.2；`logs/stage3/fullcore/corpus_b00.log:22-30,38-39`、`summary.log:8-9` |
| 　其中随机差分（对 `tests/golden/vdot_ref.c`） | 235348 条，0 失配 | 实测 | `logs/stage2/p5_func_random.log` |
| 　其中直驱真正被集成的 `VIMacU` | 26060 条，0 失配 | 实测 | `logs/stage2/p5_summary.log:41`、`p5_vimacu_equiv.log:86` |
| 译码级非法指令判定 | 51 条全 PASS；撤掉 LMUL 守卫后 13 条变红 | 实测 | `logs/stage2/p5_decode_illegal.log:123`、`p5_decode_prove_fail.log:144` |
| 既有指令零回归 | 9 个既有 FU 输出（含周期数）与 pristine 基线逐字相同；164 个共有 module 中 163 个去注释后逐字节相同（差异仅顶层 `SimTop`） | 实测 | `logs/stage2/p5_regression.log:31-39,52-54` |
| RTL 故障注入 | 6/6 被检出（含新增的「回退 S-3'」：把 `vdot`/`vdotacc` 写回尾部改回按 `vta` 处理） | 实测 | `logs/stage2/p5_fault_injection.log:273-274` |
| 3.1.1 NEMU 指令扩展 | **30794 条语料 0 失配**；4834 条必须 trap 的用例全部以 `mcause=2` trap；difftest 参考共享库上同一语料 `trap code:0` | 实测 | `logs/stage3/p5_vdot_tests.log:90-93,119,129` |
| 　NEMU 补丁干净应用 / 故障注入 | 干净副本上重跑 30794/30794；故障注入 6/6 被检出（含新增的「回退 S-3'」；另 1 个经论证的等价变异体） | 实测 | `logs/stage3/p5_patch_verify.log:47,51`、`logs/stage3/p5_fault_injection.log:191-192` |
| 3.1.2 协同仿真（**Level 1**：真实 NEMU `.so` ↔ Verilated 译码单元 + vdot 功能单元） | 72794 条激励；值比对 **55960/55960，0 失配**；非法判定 **分歧 0**（首轮 6415 条分歧经 G5a 补守卫 + 裁定 S-7' 后归零） | 实测 | `logs/stage3/cosim/p6_cosim_run.log:45-52`；首轮记录见 `docs/stage3/21_协同仿真验证报告.md` §7.4 |
| 3.1.2 协同仿真（**Level 2**：MinimalConfig 全核 emu ↔ 同一 NEMU `.so`，逐条提交 difftest） | 语料 **30794/30794**（4834 条必须 trap 的用例全部 `mcause=2`）；10 个依赖内核 × 4 个种子 **0 失败**；**24,524,262 条提交（27,104,437 周期）0 失配**，10/10 次 `HIT GOOD TRAP`；故障注入两种各 **3/3 检出**（`VIMacU` 结果 bit0 翻转；写回尾部退回旧 S-3 的全 1，`s3old`）；全核波形确认 `VIMacU` 2 拍（fig8 / `wave_trace.txt` 为 `vl=16` 满寄存器版本；`vl=8` 主演示见 `23` §7.3、fig10）。只构建了 MinimalConfig | 实测（全核 Verilator） | `logs/stage3/fullcore/summary.log:1-9`、`fault_summary.log:1-5`、`fault_summary_s3old.log:1-5`；`docs/stage3/23_全核difftest验证报告.md` |
| 　协同仿真故障注入（Level 1） | 7/7 被检出（RTL 侧 3、NEMU 侧 4，其中 `T3-NEMU-3` 守护 S-7'、`T3-NEMU-4` 守护 S-3'）；T3-RTL-1 实为输出格式选择取反，真正的 `io_vd` bit0 翻转是补充项 T3-RTL-1b，6402/6402 失配被检出 | 实测 | `logs/stage3/cosim/p6_fault_injection.log:358`；`logs/stage3/cosim/p6_fault_rtl1_rerun.log:41-58`；S-3' 之前的 6/6 存档 `p6_fault_injection_v2.log` 已删除，见 git 历史（`git show 0f62281^:logs/stage3/cosim/p6_fault_injection_v2.log`） |
| 3.2 基线等价性 | RVV 1.0 基线序列与 vdot 指令族在 NEMU 上 **25960 条实跑用例逐位相同，0 失配**（S-3' 后单次点积基线以 `vmv.v.i v8, 0` 清零整个 `v8`，`vdotacc` 基线由 4 条增为 7 条）；长向量循环 24 个长度 0 失配 | 实测 | `logs/stage3/p7_baseline_equiv.log:114-117,146` |

### 1.2 延迟与加速比（赛题 3.3）

> **主结论**：MinimalConfig 全核实测 latency 加速比——单次 16 元素点积 **1.70×**（函数整体，含 2 条装载与结果取回，52 → 30.5 拍）；
> 长向量稳态吞吐 **1.81×**（`vdotacc` 单累加器，12.64 → 7.00 拍/16 个 int8），2 路累加器展开 **2.25×**（5.63 拍/16 个 int8）。
> **适用范围**：香山 MinimalConfig 全核 emu、热态（每点重复 5 次取后 4 次中位数，数据已在 DCache）、带 difftest；默认配置（KunminghuV2Config）未测。
> **为什么选这三个口径**：它们最贴近实际调用（整函数调用、真实循环 kernel），且是全核实测周期，不依赖建模假设。
> 下表其余各行（序列本体 5.17×、加取回 2.81×、建模 2.00× / 1.50× / 3.00×、指令数与 uop 数等）都是参考口径，不替代主结论。
> **S-3' 修订后主结论不变**：全核周期实测按新基线重跑，各点周期逐拍相同。单次点积基线把清零指令 `vmv.s.x v8, x0` 换成了 `vmv.v.i v8, 0`：
> 两者在 `VIAluFix` 上都是 1 拍（`bench/results/latency_fu.csv`），m1 下都译码为 2 个 uop（`bench/results/uop_count.csv:3-4`），且都不在关键路径上；
> `vwredsum.vs` 的 `ta` 改为 `tu` 也不引入新依赖，因为 `vwredsum.vs v8, v4, v8` 的 `vs1` 本来就是 `v8`；长向量循环 kernel 未改动
> （`docs/stage3/22_基线实现与延迟加速分析.md` §5.5.2）。

| 项目 | 基线 | vdot | 结果 | 标注 | 证据 |
|---|---:|---:|---:|---|---|
| vdot 三条指令的 FU 延迟 | — | 2 拍 | 按**数据成形拍**判定（逐拍采 `io_vd` 与参考模型比较，不读 `out.valid`）：`VIMacU` 直驱 196/196/190 笔全部「第 1 拍未成形、第 2 拍逐位正确」；L1 `VDotTop` 波形 12×3 笔 DUT 内部 S2 寄存器与 `io_vd` 均在第 2 拍成形。两个平台的 `out.valid` 都由测试平台按声明延迟构造，不作证据 | 实测（FU 级） | `logs/stage3/p7_latency_measure.log:232-246`；`logs/stage3/waveform/p7_*.vcd` |
| 基线核心指令 FU 延迟 | `vmv.v.i` 1 拍、`vwmul.vv` 2 拍、`vwredsum.vs` 2 拍（S-3' 前基线用的 `vmv.s.x` 同为 1 拍） | — | 与 `FuConfig` 声明值一致（同样按数据成形拍判定；`vwredsum.vs` 未做数值比对） | 实测（FU 级） | `bench/results/latency_fu.csv`；`p7_latency_measure.log:254-258,319,321,335` |
| `vsetvli` 延迟 | 0 拍 | 0 拍 | 未实测（落在整数侧 BJU2，不在向量 FU 平台内） | 声明值 | `docs/stage3/22_基线实现与延迟加速分析.md` §4.5 |
| 单次 16 元素点积：架构指令条数 | 6 | 2 | **3.00×** | 实测（全核 `minstret` 窗口差，与源码静态计数一致） | `bench/results/speedup.csv`；`logs/stage3/fullcore/perf_cycles.log:19-28` |
| 单次点积：向量算术指令条数 | 3 | 1 | **3.00×** | 静态计数（源码） | 同上；`tests/riscv/fullcore/perf_kernels.S` |
| 单次点积：译码级 uop 条数 | 14 | 3 | **4.67×** | 源码推导 | 同上；`work/XiangShan-kmhv2/src/main/scala/xiangshan/backend/decode/UopInfoGen.scala:197-235` |
| 单次点积：FU 延迟关键路径 | 4 拍 | 2 拍 | **2.00×** | **建模**（实测 FU 延迟按依赖链相加，假设完美前递、无端口冲突） | `bench/results/critical_path.csv`、`sensitivity.csv` |
| 长向量循环 N=4096：动态指令数 | 2577 | 2063 | **1.249×**（渐近 1.250×，为实测回归斜率之比 10/8 的 N→∞ 外推，不是实测点；绝对值随编译器变化，见 §4） | 实测（NEMU `minstret`，是指令数不是周期数） | `bench/results/instr_count_loop.csv`；`p7_baseline_equiv.log:162-169` |
| 长向量稳态吞吐 | 3 拍/迭代 | 2 拍/迭代 | **1.50×**（2 路累加器展开时 3.00×） | **建模**（FU 级端口 + 依赖下界模型） | `docs/stage3/22_基线实现与延迟加速分析.md` §5.3 |
| **单次点积：全核周期**（MinimalConfig） | 52 拍（函数整体）；参考 31 / 38 拍 | 30.5 拍（函数整体）；参考 6 / 13.5 拍 | **1.70×**（函数整体含装载与取回，**主结论**）；参考口径：5.17×（序列本体）/ 2.81×（加取回标量），对窗口定义敏感（vdot 侧序列本体净值仅 6 拍，小于一跳依赖 7 拍，说明有一部分藏在空窗口固定开销里，vdot 侧被低估，见 `22` §5.5.1–§5.5.2） | **实测（全核 MinimalConfig，`fence`+`mcycle`，带 difftest，热态）**；三种窗口口径不同 | `logs/stage3/fullcore/perf_cycles.log:9-48`；`bench/results/cycles_fullcore.csv` |
| **长向量稳态：全核周期**（MinimalConfig） | 12.64 拍/迭代 | 7.00（`vdotacc`）/ 5.63（2 累加器）拍/迭代 | **1.81× / 2.25×**（**主结论**；N=4096 整体 1.80× / 2.22×） | **实测（全核 MinimalConfig）** | `perf_cycles.log:109-133,184-233`；`docs/stage3/22_基线实现与延迟加速分析.md` §5.5 |

> 上表各行**量纲不同、不可互相替代**，不能挑最大的一个当作「加速比」。2.00× 的敏感性区间为
> 1.00×–5.00×（`bench/results/sensitivity.csv`）。
> **建模与全核实测的对比**（`22` §5.5.5）：MinimalConfig 上每一跳向量依赖实测为 FU 延迟 + 5 拍（`vdotacc` 7 拍、`vwadd.wv` 6 拍），
> 模型的零气泡前递假设不成立。`vdotacc` 单累加器循环确实被循环携带依赖卡住（7.00 拍/迭代），但基线 D 更慢（12.64 拍/迭代，
> 瓶颈未定位），所以实测 1.81× **高于**模型 1.50×，没有出现不升反降；2 累加器只降到 5.63 拍（已贴近只含循环控制与装载的骨架循环 5.50 拍），
> 实测 2.25× **低于**模型 3.00×；单次点积函数整体口径 1.70× **低于**模型 2.00×。全核数字**只对 MinimalConfig 成立**，默认配置未测。

---

## 2. 设计亮点

1. **最大限度复用香山既有实现**
   * 16 路 8×8 乘法阵列**零新增**：直接取自既有 2 片 `VIMac64b` 的部分积，仅新增一个只读输出端口 `prod16`（`VIMac64b.scala` +7 行）；
   * 加法树全部例化 YunSuan 既有原语 `CSA4to2` / `CSA3to2`（生成网表实测 12 + 4 个实例）；
   * `Mgu`、`ByteMaskTailGen`、`VecPipedFuncUnit`、`VecDataSplitModule` 零改动复用；
   * **`FuConfig` / `FuType` / `Parameters` / Dispatch / IQ / WbArbiter 一行未改**——vdot 挂在既有 `VimacCfg`（`latency = CertainLatency(2)` 不变）上，调度、唤醒与写回网络完全不受影响；
   * 零回归有三重证据：既有 FU 输出逐字相同、163/164 module 网表去注释后逐字节相同、`vmul`/`vwmul`/`vmacc` 的数据成形拍实测仍为 2 拍（第 1 拍未成形、第 2 拍与参考逐位一致；`docs/stage2/11_RTL实现说明.md` §7、`docs/stage3/22` §7.2）。
   * 新增算术逻辑约 13.7%（全加器等价**结构计数上界**，非综合结果；`docs/stage2/10_vdot指令设计文档.md` §5.3）。
2. **XOR 蝶形折叠加法树**（`docs/stage2/10` §4.4）：同一组 12 个 `CSA4to2(32)` 由 2 bit `foldLevels` 控制，伙伴 lane 取 `g XOR Δ`，
   一棵树同时覆盖「16 路全归约」与「4 组×4 路」两种形态；结果路径上零选择器，模式切换只作用在加数输入端的 AND 门上，
   全折叠时每个 lane 都持有总和、元素 0 定位无需额外逻辑，向更大 VLEN 扩展只需增加折叠级数。
3. **三条指令共享一条数据通路**：`vdot.vv` / `vdotacc.vv` / `vdot4a.vv` 共用同一乘法阵列与同一棵可重构加法树，
   区别只在 `foldLevels` 与累加操作数注入；三者的数据成形拍实测同为 2 拍。
4. **把设计阶段已识别、但被判为不可达的冲突量化为确定性分歧（裁定 S-7'）**：原裁定 S-7 允许 `vdot4a` 在 `vstart != 0` 时正常执行；
   参考模型、NEMU、RTL 数据通路都按 S-7 实现，彼此「一致地正确」。设计文档 R-06 曾识别该风险但判为全核不可达；
   Level 1 协同仿真把 NEMU 与香山**上游原有、未被本项目修改的判据** `vstartIllegal = isVArith && vstart =/= 0`
   （所在的 `VecExceptionGen.scala` 本身打了补丁）直接比对，将其量化为 1946 条确定性分歧，迫使裁定修订——
   错的不是实现，而是 ISA 裁定比目标微架构更宽。按「平台约束优先原则」修订为 S-7'（`vdot4a` 在 `vstart != 0` 时同样非法），
   RTL 一行未改即收敛（`docs/stage3/21_协同仿真验证报告.md` §7.3–§7.5、`docs/_plan/MASTER_PLAN.md` D2.3）。
5. **与赛题官方语义逐位对齐，且保留 `vl` 机制（裁定 S-3'）**：取得赛题官方伪代码后逐行对照，主体（8 个 int8 有符号乘积求和写 `vd[0]`）与原设计一致，
   唯一差异是目的寄存器其余位：伪代码要求清零，原 S-3 按 `vta` 处理。「清零」不属于 RVV tail-agnostic 允许的取值（只能保留原值或写全 1），
   因此把 `vdot.vv` / `vdotacc.vv` 的目的定义为「整寄存器结果、无 tail」（先例：x86 `VPDPBUSD` 的 VEX/EVEX 编码清零高位、南湖 VDOTU 写满 `rd`）。
   RTL 改动只有 `VIMacU` / `VDotTop` 写回成形各一处 `Cat(0.U((VLEN - 32).W), dotVd(31, 0))`（`rtl/patch/0001-xiangshan-vdot.patch:276-277`、
   `rtl/patch/0002-yunsuan-vdot.patch:184`）；`vl = 8` 时与官方伪代码逐位等价（`logs/stage2/p3_official_pseudocode_equiv.log:40`），
   `vl = 16` 为满寄存器版本。「8」可理解为一个 64 位切片装 8 个 int8（题源南湖 VDOTU 的 64 位寄存器、昆明湖 V2 `VIMacU` 的 64 位乘法切片）。
   论证见 `docs/stage2/10_vdot指令设计文档.md` §1 开头与 §9 R-18。

---

## 3. 仓库导航

| 目录 / 文件 | 内容 |
|---|---|
| `target.md`、`score.md`、根目录 PDF | 官方赛题、评分表与提交操作手册 |
| `docs/00_项目总览.md` | 赛题逐条对照表、评分表自评、语义裁定史、验证体系总览 |
| `docs/_plan/` | `MASTER_PLAN.md`（唯一事实来源）、`HANDOFF_TODO.md`（交接与后续工作）、阶段一/二独立验收审计与整改记录（`ACCEPTANCE_*.md` 为历史记录，不随后续修订改写） |
| `docs/_recon/` | 动手前的源码侦察笔记（昆明湖 V2 向量集成点、NEMU/difftest、vdot 语义调研）；`figures/vdot_official_semantics.jpg` 为赛题官方语义图（`vdot_vv` 伪代码）的原样存档 |
| `docs/stage1/` | 环境版本锁定、部署报告、`vadd.vv` 执行过程分析、仿真平台搭建报告；`figures/` 7 张图：6 张 FU 级波形图（fig1–6）+ 图 7 全核 `vadd.vv` 流水图 |
| `docs/stage2/` | `10` 设计文档、`11` RTL 实现说明、`12` 基础功能测试报告、`13` 参考模型与测试向量说明；`figures/` 3 张 vdot 功能波形图 |
| `docs/stage3/` | `20` NEMU 指令扩展说明、`21` 协同仿真验证报告（Level 1）、`22` 基线实现与延迟加速分析、`23` 全核 difftest 验证报告（Level 2）；`figures/` 10 张图：5 张数据图（fig1–4、fig9 全核周期实测）+ 5 张波形图（fig5–7 FU 延迟实测、fig8 全核 vdot 波形（`vl=16` 满寄存器版本）、fig10 全核 `vl=8` 主演示） |
| `docs/ppt/` | 答辩与提交的准备材料：`讲解大纲.md`（逐页要点与证据出处）、`录屏脚本.md`（三段录屏分镜）、`提交清单.md`（加密提交流程与自检项）；讲解 PPT（`docs/submission/SNL-XiangShan-vdot-slides.pptx`）、三段演示视频（`demo/video/`）与三册技术文档 PDF 已由脚本从文档生成（命令见 `submission/upload/README.md`、`demo/video/storyboard.md`） |
| `rtl/patch/` | 对上游的正式交付：`0001-xiangshan-vdot.patch`、`0002-yunsuan-vdot.patch` |
| `rtl/chisel/` | 打完补丁后全部新增/修改 Chisel 源码的只读副本（`MANIFEST.md`），由 `scripts/tools/sync_rtl_sources.sh` 重建与校验 |
| `rtl/verilog/` | 生成的 Verilog：`vdot/`（`VDotTree.sv`、`VDotTop.sv`、`VIMacU.v`、`DecodeUnit.v` 等）与 `baseline/`（零回归对照） |
| `nemu/` | NEMU 扩展补丁 `patch/0001-add-vdot-instruction-family.patch` 与使用说明 |
| `tests/golden/` | C 参考模型 `vdot_ref.c`（语义唯一事实来源，各测试平台直接 `#include`，不重写） |
| `tests/vectors/` | 共享语料：13 个 suite、30739 条（S-3' 后重新生成，含三项基础测试各 6 条 `vl=8` 定向用例 × `vdot`/`vdotacc`），由参考模型生成 |
| `tests/unit/` | FU 级测试平台：L1 测试平台补丁、`VIMacU`/`VecExceptionGen` 直驱、FU 延迟实测 harness |
| `tests/riscv/` | 裸机 RV64 程序：`hello/`（1.1）、`vdot/`（NEMU 一致性）、`baseline/`（基线等价性与指令计数）、`fullcore/`（全核 difftest 的语料批次、背靠背依赖测试与波形程序） |
| `tests/cosim/` | NEMU↔RTL 协同仿真驱动与译码探针 |
| `bench/` | RVV 1.0 基线实现（`baseline/`）、结果数据（`results/*.csv`）、日志→CSV→图表脚本 |
| `scripts/` | 编号一键复现脚本；`tools/` 为辅助工具（波形抽取、补丁校验、故障注入等）；`docker/` 为容器镜像定义 |
| `logs/stage1,2,3/` | 真实终端日志（一处例外在日志文件内就地注明：`logs/stage1/p1_t1_toolchain.log:113,115` 把 brew update 自动输出的两段第三方软件清单（81 行、137 行，与本项目无关）各折叠为一行说明。`logs/stage3/p7_latency_measure.log` 原先混有两种运行环境，S-3' 后整份在 Linux x86_64 + Verilator 5.024 上重跑，已不再混合）；`logs/stage1/` 下另有 11 个 `*.log`（17826 行）与 `linux_repro/`（Linux 全新目录复现 `00`→`02`→`03` 的终端记录）；`waveform/` 下为被文档逐值引用的 8 份 VCD 与文本轨迹；`stage3/fullcore/` 为全核 difftest 日志、全核波形文本轨迹与时序图（全核 VCD 382 MB 不入库） |
| `work/` | 上游仓库工作区（`.gitignore` 排除，不入库），由 `scripts/00_setup_env_host.sh` 按锁定 commit 克隆 |

---

## 4. 复现快速上手

**验证平台**：阶段一与阶段二 P4 的存档日志产生于 macOS 15.5 arm64（16 GB）+ Docker 容器 `xsdev:ubuntu24.04-arm64`
（Verilator 5.052）。交付脚本随后在 **Linux x86_64**（Ubuntu 22.04.5，宿主 GCC 11.4，Verilator 5.024，
OpenJDK 17.0.20，交叉 GCC 15.2，无 Docker、无 root）上从全新目录**一键实测通过**，见下表（该复现在 S-3' 之前）。
语义修订 S-3'（2026-10-26）之后，`20`、`21`、`30`、`40`、`50` 号脚本在同一台 Linux 服务器上按新语义重跑并更新了存档（阶段二 P5 与阶段三全部日志），
没有再从全新目录复测。macOS + Docker 路径在脚本改为跨平台之后**未重新实测**。

**Linux 依赖**（Ubuntu/Debian）：

```bash
sudo apt-get install -y build-essential git curl rsync file bison flex python3 python3-venv \
  openjdk-17-jdk verilator libreadline-dev libsdl2-dev zlib1g-dev libzstd-dev libncurses-dev device-tree-compiler
pip install matplotlib && sudo apt-get install -y fonts-noto-cjk   # 仅 40 号脚本绘图需要（或 fonts-wqy-zenhei）
sudo apt-get install -y clang                                       # 仅 50 号全核脚本需要（clang++）
```

* **JDK 必须是 17**（mill + Scala 2.13.15 在 JDK 21/25 下失败；`scripts/env_host.sh` 会自动寻找 JDK 17）。
* **Verilator 建议 5.x**：实测 5.024 / 5.052；Ubuntu 22.04 apt 自带的 4.038 未验证。
* **RISC-V 交叉 GCC ≥ 12**（需支持 `-march=rv64gcv_zve64x`）：Ubuntu 24.04 用 apt 的 `gcc-riscv64-linux-gnu`；
  22.04 自带的是 11.4，需从 [riscv-collab/riscv-gnu-toolchain](https://github.com/riscv-collab/riscv-gnu-toolchain/releases)
  下载预编译包解压到 `/opt/riscv`（脚本自动探测），或用 `CROSS=<前缀>` 指定。
* **全核 difftest（`50` 号脚本）另需 clang++ 与 ≥64 GB 内存**：difftest 子模块把 clang 专有选项 `-fno-slp-vectorize` 写死在
  `difftest/verilator.mk:76`，g++ 直接报错；`make emu` 实测峰值 RSS 56445000 KiB（约 53.8 GiB，`logs/stage3/fullcore/build_emu.log:2434`；
  S-3' 之前首次构建中 Verilator 前端约 56.4 GiB，旧日志已删除，见 git 历史（提交 4674e08））。
* **没有 root**：`LOCAL_SYSROOT=1 bash scripts/00_setup_env_host.sh`，把 readline / SDL2 开发包解包到 `${WORK_DIR}/sysroot`。
* macOS：`brew install verilator openjdk@17 gnu-sed cmake` + Docker Desktop，并先执行 `./scripts/01_setup_env_docker.sh build`；
  NEMU 与交叉编译在容器内执行（`XS_RUNNER=auto` 自动选择）。

```bash
bash scripts/00_setup_env_host.sh        # 检查依赖、安装 mill / espresso、按锁定 commit 克隆上游到 work/，并生成两棵补丁工作树
bash scripts/02_build_nemu.sh            # 构建 NEMU 独立解释器与 difftest 参考共享库
bash scripts/03_run_hello.sh             # 1.1：裸机程序在 NEMU 上打印 hello 串
bash scripts/10_build_yunsuan_sim.sh     # L1：YunSuan 官方 FU 仿真平台（WAVE=1 抓 vadd 波形，1.3）
bash scripts/11_build_vdot_sim.sh        # L0/L1：带 vdot 的 RTL 精化、构建与冒烟测试
bash scripts/20_run_func_tests.sh        # 2.3：正数/负数/边界/随机/回归/译码级/VIMacU 直驱全套功能测试（WITH_FAULT=1 加跑 RTL 故障注入）
bash scripts/21_build_nemu_vdot.sh       # 3.1.1：打 NEMU 补丁、构建两种形态、跑 30794 条语料（子命令 verify-patch / fault）
bash scripts/30_run_cosim.sh             # 3.1.2：NEMU↔RTL Level 1 协同仿真（子命令 fault 跑故障注入）
bash scripts/40_run_bench.sh             # 3.2/3.3：基线等价性、FU 延迟实测、CSV 与图表
bash scripts/50_run_fullcore_difftest.sh build   # 3.1.2 Level 2：全核 emu 构建（clang++，≥64 GB 内存，约 25 分钟）
bash scripts/50_run_fullcore_difftest.sh run     # 全核 difftest：6 批语料 + 4 个种子依赖测试（45–60 分钟；另有 wave / fault 子命令）
bash scripts/50_run_fullcore_difftest.sh perf    # 3.3：全核周期实测（带 difftest，5–15 分钟）；之后 40 的 [5] 会解析出 cycles_fullcore.csv
bash scripts/50_run_fullcore_difftest.sh hello   # 1.1：hello 程序在全核 emu 上运行（带 difftest，20–60 秒）
bash scripts/50_run_fullcore_difftest.sh wave-vl8  # vl=8 主演示（与官方伪代码逐位等价；只需已构建的 emu 与 NEMU .so，约 10 秒）
```

所有脚本 `source scripts/lib/common.sh`，可配置变量见其文件头：`WORK_DIR`（上游仓库与构建产物，默认 `work/`）、
`LOG_ROOT` / `RESULTS_DIR` / `FIG_DIR`（日志、CSV、图表输出位置，默认即仓库内存档位置，**复跑会覆盖存档**，
只想验证时请指到别处）、`BUILD_ROOT`、`XS_RUNNER`、`CROSS`、`JOBS`、`PYTHON`。

| 脚本 | 做什么 | 主要产物 | Linux x86_64 全新目录实测 |
|---|---|---|---|
| `00_setup_env_host.sh` | 依赖检查、mill / espresso、按 pin 克隆 XiangShan（11 个子模块）与 NEMU，调用 `04` 生成补丁工作树 | `work/` | ✅ 216 s（终端记录 `logs/stage1/linux_repro/00_setup_env_host.term.log`，含克隆过程，rc/耗时见 `:644-645`） |
| `01_setup_env_docker.sh` | 构建并进入 xsdev 容器（仅 macOS 需要） | `logs/stage1/p1_docker_build.log` | 未实测（Linux 不需要） |
| `02_build_nemu.sh` / `03_run_hello.sh` | 构建 NEMU；运行 1.1 验证程序 | `logs/stage1/p1_nemu_build.log`、`p1_hello_xiangshan.log` | ✅ 31 s / <1 s（`logs/stage1/linux_repro/02_build_nemu.term.log:395-396`、`03_run_hello.term.log:135-136`；汇总见该目录 `README.md`、`docs/stage1/01_环境部署报告.md` §8） |
| `10_build_yunsuan_sim.sh` | YunSuan L1 平台 + `vadd.vv` 波形 | `logs/stage1/waveform/` | ✅ 105 s |
| `11_build_vdot_sim.sh` | vdot RTL 精化、Verilog、L1 冒烟 | `logs/stage2/p4_*.log`、`rtl/verilog/vdot/` | ✅ 105 s（S-3' 后以 `p4_rtl_build.log` 头部记录的 mill 命令重跑编译，另存 `logs/stage2/p4_rtl_build_s3p.log`，总 exit=0） |
| `20_run_func_tests.sh` | 阶段二全部功能测试并生成汇总表 | `logs/stage2/p5_*.log` | ✅ 317 s，当时 290103 条 0 失败（S-3' 后存档为 290175 条，`logs/stage2/p5_summary.log:43`） |
| `21_build_nemu_vdot.sh` | NEMU 扩展构建与一致性测试（`fault` / `verify-patch` 子命令） | `logs/stage3/p5_*.log` | ✅ 21 s（`verify-patch` 10 s、`fault` 21 s） |
| `30_run_cosim.sh` | 协同仿真（Verilator + 链接 NEMU `.so`） | `logs/stage3/cosim/` | ✅ 251 s（`fault` 96 s） |
| `40_run_bench.sh` | 基线等价性（NEMU）+ FU 延迟实测 + 绘图 | `logs/stage3/p7_*.log`、`bench/results/`、`docs/stage3/figures/` | ✅ 126 s |
| `50_run_fullcore_difftest.sh` | 全核 difftest（MinimalConfig emu + NEMU `.so`）：`build` / `run` / `wave` / `wave-vl8`（`vl=8` 主演示）/ `fault` / `perf`（周期实测）/ `hello`（1.1）；退出时把私有 NEMU 副本恢复为独立解释器形态 | `logs/stage3/fullcore/`、`logs/stage1/p1_hello_xiangshan_fullcore.log` | ✅ 在 128 核、约 1 TB 内存的服务器上实测（S-3' 后重跑，部分任务并行，耗时偏保守）：`build` 的 `make emu` 墙钟 24:31.63、峰值 RSS 约 53.8 GiB（`logs/stage3/fullcore/build_emu.log:2429,2434,2448`），脚本整体 24m45s（`build_driver.log:40`）；`run` 60m33s（`run_driver.log:76`）；`fault` 首次需另构建一次 emu；`perf` 894 s、`hello` 53 s（`logs/stage3/fullcore/perf_cycles.log:325`、`logs/stage1/p1_hello_xiangshan_fullcore.log:81`）。S-3' 之前从零构建的脚本复测日志已删除，见 git 历史（提交 4674e08）；不在上面「12 步」之内 |

以上 12 步（含 `21 verify-patch`、`21 fault`、`30 fault`）全部通过，功能与一致性数字与当时（S-3' 之前）的存档相同。两点已知差异与限制：

* **交叉 GCC 版本会改变 `minstret` 绝对值**：现存档（S-3' 后重跑，GCC 15.2 `riscv64-unknown-elf-gcc`，`logs/stage3/p7_baseline_equiv.log:13-14`）
  比 S-3' 之前的存档（xsdev 容器内的 `riscv64-linux-gnu-gcc` 13.3）每点多 2 条（N=4096：2575/2061 → 2577/2063，比值 1.249 不变；
  N=64：1.222 → 1.213），每 16 元素的斜率不变，与 S-3' 无关（`docs/stage3/22_基线实现与延迟加速分析.md:632-639`）。
  原补充日志 `p7_baseline_gcc15_supplement.log` 已删除，见 git 历史（`git show 0f62281^:logs/stage3/p7_baseline_gcc15_supplement.log`）。
* **波形模式要求 yunsuan 目录路径 ≤ 63 字节**：上游 `emu.cpp` 用 `getcwd(cwd, 64)` 拼 VCD 路径，超长时波形静默丢失。
  `40` 已改为在短路径临时目录里运行 emu；`10`/`11` 的 `WAVE=1` 与 `20` 的 `WITH_WAVE=1` 遇到长路径会直接报错，
  请把 `WORK_DIR` 设到较短的路径。

提交前自检：`bash scripts/tools/sync_rtl_sources.sh --check`（校验 `rtl/chisel/` 与补丁无漂移，只读）、
`bash scripts/tools/verify_patches.sh`（三份补丁可干净应用到 pristine 上游）。

---

## 5. 局限性（如实说明）

1. **全核 difftest 只跑了 MinimalConfig。** Level 1（FU + 译码单元）之外，已补做 Level 2 全核 difftest
   （`docs/stage3/23_全核difftest验证报告.md`），证明了 vdot 在乱序流水线中的发射、旁路、提交与异常投递与 NEMU 一致。
   但只构建了 `MinimalConfig`：`23` §3.1 论证了 vdot 经过的译码、向量调度、`VIMacU`、写回、提交逻辑在默认配置下是同一份参数化 RTL，
   功能结论可以推广，**但默认配置与 `KunminghuV2Config` 未实际运行，波形中的周期数只对 MinimalConfig 有效**。
   LMUL≠1 的非法判定未在全核上复测（只有 Level 1 的 6000/6000）；依赖测试是 10 个固定模板，不是随机指令流。
   全核构建需要 clang++ 与 ≥64 GB 内存（`make emu` 峰值 RSS 约 53.8 GiB，`logs/stage3/fullcore/build_emu.log:2434`），原 16 GB 开发机做不了。
   阶段二三项功能测试（2.3）的存档结果来自 FU 级平台（同一语料之后也在全核上 0 失配，见上）；阶段一的 hello 程序原先只运行在 NEMU 上，之后同一程序也在 MinimalConfig 全核 emu 上带 difftest 运行通过（`logs/stage1/p1_hello_xiangshan_fullcore.log`）。
2. **`latency = 2` 由静态逻辑级估算 + FU 级实测支撑，没有综合。** FU 级实测证明 RTL 在第 2 拍给出正确结果；
   能否在目标频率下时序收敛未经综合与静态时序分析验证。面积 13.7% 是结构计数上界，功耗未量化。
3. **LMUL 固定为 1**（裁定 S-6）：`LMUL != 1` 的 vdot 一律判非法；多 uop 累加链方案已在设计文档 §8.3 论证但未实现。
4. **周期加速比只在 MinimalConfig 上实测。** 1.50× / 3.00× / 2.00× 是 FU 级模型值；MinimalConfig 全核实测主结论为单次点积 1.70×（函数整体）、
   长向量稳态 1.81×（单累加器）/ 2.25×（2 累加器），5.17× / 2.81× 为口径敏感的参考值；与模型有高有低（`22` §5.5）。默认配置（KunminghuV2Config）的周期未测；
   基线 D 每迭代 12.64 拍的瓶颈、单次点积 31 拍的逐拍构成未用波形确认。`vsetvli` 的 FU 级延迟为声明值；uop 条数为源码推导。
5. **提交物部分完成**：讲解 PPT（`docs/submission/SNL-XiangShan-vdot-slides.pptx`，PDF 版随上传包提供）、三段演示视频（`demo/video/`，视频三因体积不入库，随上传包提供）与三册技术文档 PDF 已由脚本从仓库文档生成（命令见 `submission/upload/README.md`、`demo/video/storyboard.md`）；GitHub Release、大赛系统上传与加密提交流程（`submit.sh`）**尚未完成**。
6. 阶段二波形以 VCD + 文本轨迹交付，并已由同一份 VCD 渲染出 3 张波形图（`docs/stage2/figures/fig1-3_*.png`），嵌入 `docs/stage2/12` §10（`:1022,1078,1095`）；`tests/unit/VectorSimTop.scala` 等上游派生文件中保留了上游原有的
   `TODO`/`FIXME` 注释（本项目补丁未新增任何此类注释）。

后续工作（综合、默认配置上的周期实测、真实 LLM 负载、LMUL>1、提交物）按投入产出比排序见
[`docs/_plan/HANDOFF_TODO.md`](docs/_plan/HANDOFF_TODO.md)。
