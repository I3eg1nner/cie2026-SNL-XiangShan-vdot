# 最终独立复审报告（第二轮，S-3' 之后）

| 项 | 内容 |
|---|---|
| 复审对象 | 仓库 `main` @ `6b3e499`（工作区干净） |
| 复审日期 | 2026-10-26 |
| 立场 | 站在评委角度证伪；不采信文档自述，结论一律追到文件、日志原始行与代码 |
| 依据 | `target.md`、`score.md`、官方语义图 `docs/_recon/figures/vdot_official_semantics.jpg`（复审者亲自看图）、`docs/_plan/MASTER_PLAN.md` §2 执行纪律 |
| 复审方式 | 只读；所有复跑输出放在 `/tmp/review4/`，未覆盖任何已跟踪文件，未改动 `work/` 下任何工作树（复审前后各工作树 `git status` 条数相同） |

---

## 0. 总评

**结论：仓库内容可以公开提交，没有发现阻断级的技术缺陷。** 语义修订 S-3' 在参考模型、NEMU、两份 RTL 写回成形、生成的 Verilog、语料、各层日志之间做到了一致，并且与官方伪代码在 `vl = 8` 时逐位等价；这一点复审者用自己写的、不依赖项目代码的脚本独立复核过。README 与 `docs/00` 的关键数字在日志原始行中全部能找到并对上，CSV 可以从日志逐字节重新生成，补丁可以干净应用。

剩余问题集中在三类：
1. **提交流程本身未完成**（三段录屏、PPT、加密提交、`docs/ppt` 中的「待确认」）。这不是仓库缺陷，但在提交层面是阻断项。
2. **个别文件没有跟上 S-3'**：`nemu/README.md` 整份停留在 S-3' 之前（语料条数、patch 的 sha256 与行数都是旧值，sha256 还与它自己引用的日志行矛盾）；`docs/_recon` 中一份调研笔记残留了一个自动化工具的内部名称。
3. **若干次要的过时表述**：阶段二「未附波形截图」、VCD 体积、背靠背间隔「未实测」等。

语义上唯一需要向评委主动说明的风险是：项目保留了 `vl` 机制，官方伪代码则把元素个数写死为 8。`vl = 16`（VLMAX）时本项目求 16 项之和，与伪代码不同。项目文档已经如实说明并给出了理由，但答辩和录屏应把 `vl = 8` 的用例放在最前面。

---

## 1. 语义一致性核查（重点）

### 1.1 官方语义（复审者看图转录）

```
def vdot_vv(vs1, vs2, sew=8):
    result = 0
    for i in range(8):
        result += sign_extend(vs1[i]) * sign_extend(vs2[i])
    vd[0] = result
    vd[1..VLEN-1] = 0  # 其他通道清零
```

`docs/stage2/10_vdot指令设计文档.md` §1 的逐字转录与图片一致；图片 sha256 实测为 `4d255095…1a6c`，与 `target.md` 注记、设计文档中记载的值相同。

### 1.2 (a) 三处实现的写回逻辑

| 层 | 位置 | `vstart < vl` 时 | `vstart >= vl`（含 `vl = 0`） | 与 `vta`/`vma` 的关系 | 判定 |
|---|---|---|---|---|---|
| 参考模型 | `tests/golden/vdot_ref.c:103-112` | `sum` 只累加 active 元素；`vd.u32[1..3] = 0`，`vd.u32[0] = sum` | `:100` 提前返回，`vd` 不写 | `vta` 只做取值校验，不参与写回（`:85-86`） | 符合 |
| NEMU | `nemu/patch/0001-add-vdot-instruction-family.patch:270-305`（`vdot_reduce()`） | 元素 1..3 用 `set_vreg(...,0,...)` 清零，再写元素 0；不调用 `set_vreg_tail()` | `check_vstart_ignore()` 提前返回 | 无关 | 符合 |
| RTL（XiangShan `VIMacU`） | `rtl/patch/0001-xiangshan-vdot.patch:276-277`；交付副本 `rtl/chisel/xiangshan/VIMacU.scala:192-193` | `Cat(0.U((VLEN-32).W), dotVd(31,0))` | 保持 `outOldVd` | 归约形态不走 `Mgu`，与 `vta`/`vma` 无关 | 符合 |
| RTL（YunSuan `VDotTop`） | `rtl/patch/0002-yunsuan-vdot.patch:184`；`rtl/chisel/yunsuan/VDotTop.scala:128` | 同上 | 保持 `oldVdS2` | 无关 | 符合 |
| 生成的 Verilog | `rtl/verilog/vdot/VIMacU.v:4850-4855`、`rtl/verilog/vdot/VDotTop.sv:1439` | `{96'h0, _vdotTree_io_dotVd[31:0]}` | `src_2`（oldVd）/ `oldVdS2` | — | 与 Chisel 一致 |

补充核对：
- 工作区 `work/NEMU/src/isa/riscv64/instr/rvv/vdot.c` 与从补丁中抽出的 `vdot.c` 逐字节相同；`work/NEMU-fullcore` 与之相同；`work/XiangShan-fullcore`、`work/XiangShan-cosim` 的 `VIMacU.scala` 与 `work/XiangShan-vdot` 相同（`diff -q` 无输出）。
- 累加形态 `vdotacc` 在三处都是先读 `vd.u32[0]` 再清零写回，顺序正确（NEMU 补丁 `:277-283` 有专门注释）。
- 掩码：三处都把被掩元素排除出求和；伪代码对应 `vm = 1`。
- 结果宽度：伪代码的 `vd[0]` 在 SEW=8 下字面上是 8 位元素，但 8 项和的范围（最大幅值 131072）放不进 8 位。项目把 `vd[0]` 解释为 32 位元素，设计文档 §1 逐行对照表第 6 行写明了这一点，解释合理。

### 1.3 (b) 按伪代码字面计算并抽查语料

复审者另写了一个脚本（`/tmp/review4/my_check.py`，不调用、不引用项目的任何代码），对 `tests/vectors/*.txt` 中**所有** `op ∈ {vdot, vdotacc}` 且 `status = OK` 的行重新计算期望值。`vl = 8, vm = 1, vstart = 0` 的行按伪代码字面计算；其余行按同一规则推广到 `vl`、掩码与 `vstart`（`vstart >= vl` 时保持原值）。同时检查：凡是 `vstart < vl` 的行，`vd_expected` 的高 96 位必须为 0。

| 类别 | 行数 | 失配 |
|---|---:|---:|
| `vdot`，`vl=8/vm=1/vstart=0`（官方伪代码本体） | 285 | 0 |
| `vdotacc`，同上配置（伪代码累加变体） | 285 | 0 |
| `vdot`，其余配置 | 8415 | 0 |
| `vdotacc`，其余配置 | 8384 | 0 |
| `vstart < vl` 但高 96 位非 0 的行 | — | **0** |

另外手工核算了 3 条：`positive.txt` 第 1 行（1..16 自乘求和 1496 = `0x5d8`，期望 `d8050000…`）；`vdotacc_positive.txt:61`（`0xa5a5a5a5 + 8×127×127 = 0xa5a79dad`，期望 `ad9da7a5 000…`）；`boundary.txt:126` 对应的 `vdotacc` 用例在 FU 级 DUT 的实测输出 `…_00000000a5a3a9a5`（`logs/stage2/p5_func_boundary.log:224,226`，旧 `vd` 高位为 `12345678cafebabe_deadbeef`，DUT 输出高位为 0）。三条全部正确。

项目自带的字面实现脚本也复跑过：`python3 tests/golden/check_official_pseudocode.py --cli /tmp/review4/golden/vdot_cli`，`vdot_cli` 由复审者在 `/tmp` 下重新编译。输出 `OFFICIAL-PSEUDOCODE-EQUIV: PASS (20570 cases, 0 mismatches)`，与存档 `logs/stage2/p3_official_pseudocode_equiv.log:40` 一致。

### 1.4 (c) 各层日志是否为修订后的结果

| 层 | 日志 | 时间 | 修订后的直接证据 | 判定 |
|---|---|---|---|---|
| 官方伪代码等价 | `logs/stage2/p3_official_pseudocode_equiv.log` | 15:07Z | 头部如实写明「工作区含 S-3' 修订，未提交」；阴性对照（旧语料）532/532 失配 | 修订后 |
| FU 级（L1 `VDotTop` / `VIMacU` 直驱） | `logs/stage2/p5_func_*.log`、`p5_vimacu_equiv.log`、`p5_summary.log` | 17:37–17:40Z，由 `b2484a2`（17:41）提交 | 逐条 DUT 输出高 64 位为 0（如 `p5_func_positive.log:73-75`、`p5_func_boundary.log:224-226`）；语料即 S-3' 语料 | 修订后 |
| RTL 故障注入 | `logs/stage2/p5_fault_injection.log:273-274` | 15:21Z | 6/6，包含「回退 S-3'」一项 | 修订后 |
| NEMU | `logs/stage3/p5_vdot_tests.log`、`p5_nemu_build.log` | 15:11Z | 构建日志记录的 patch sha256 `cb9194f8…`（`p5_nemu_build.log:7`）与现仓库中补丁的 sha256 相同；30794/30794 对 S-3' 语料逐字节比对通过 | 修订后 |
| Level 1 协同仿真 | `logs/stage3/cosim/p6_*.log` | 15:18–15:25Z | `p6_fault_rtl1_rerun.log:50` 中被注入的 `VDotTop.sv` 表达式是 `{96'h0, _vdotTree_io_dotVd[31:0]}`；`T3-NEMU-4`（回退 S-3'）被检出 | 修订后 |
| 全核 difftest | `logs/stage3/fullcore/*` | 15:41–17:07Z，由 `9d3409e`（17:10）提交 | `wave_trace.txt:183`：`VIMACU-OUT res=000000000000000000000000ffffff58`（高 96 位为 0，而该指令 `vta=1`）；`fault_summary_s3old.log:1-3` 把尾部改回全 1 后 `v3_high` 立刻失配，说明全核比对确实落在高位上；语料 30794/30794 0 失配 | 修订后 |
| 全核周期 | `logs/stage3/fullcore/perf_cycles.log` | 16:10Z | 反汇编 `work/build/fullcore/perf/perf_cycles.dis:984-989` 中基线本体已是 `vmv.v.i v8,0` + `tu` 归约。PERF 行与修订前逐行相同，与文档「各点周期逐拍相同」一致 | 修订后 |

**时间顺序与提交顺序吻合**：所有 S-3' 日志都早于提交它们的 commit，晚于修订开始（`d79623a`，14:44Z）。唯一的细节是 `work/NEMU/.../vdot.c` 的 mtime（15:24Z）晚于 NEMU 测试日志（15:11Z）。复审者核对后认为这是协同仿真故障注入（15:22–15:25Z）改写源文件后又还原造成的：内容与补丁逐字节相同，15:11 的构建日志也证明当时补丁已处于「已应用」状态。不构成问题。

**仍在库中的修订前日志**：`logs/stage2/p4_*.log`（阶段二 P4 的首次构建与冒烟测试，2026-10-24，macOS 路径），以及 `logs/stage3/fullcore/fault_diff.txt`（bit0 翻转注入的 diff，与语义无关）。这些日志中没有 vdot 的期望值或高位取值，不构成旧语义残留；但 `docs/00` 中 2.2 一行仍以 `p4_rtl_build.log` 作为编译证据，见问题 M-7。

### 1.5 (d) 文档中的旧语义残留

检索词：`按 vta`、`写全 1`、`ffffffff`、`语义自定`、`语义图缺失` 等，范围为 README、`docs/00`、`docs/stage*`、`docs/ppt`、`nemu/`、`rtl/chisel`、`tests`、`scripts`、`bench`。

- `docs/stage*` 与 `docs/ppt` 中所有涉及「vta / 全 1」的 vdot 表述，都已标注为「修订前 / 原 S-3 / 已被 S-3' 取代 / 故障注入」，或者讲的是 `vdot4a` 与标准指令（这些本来就按 `vta` 处理）。例如 `docs/stage3/22:384`、`docs/stage3/20:39`、`docs/stage2/13:598-610` 都是带标注的历史对照。`ffffffff` 的命中全部出自阶段一 `vadd` 的 mask/tail 分析，与 vdot 无关。
- `docs/_recon/vdot-semantics-research.md` 中「找不到语义图」的表述都已补记「2026-10-26 已取得」，不算过时说法。
- **残留**：`docs/_recon/kmhv2-vector-integration.md:690,783` 仍写「其余按 vta 处理」，没有 S-3' 标注（侦察笔记，影响很小，见 M-4）；`nemu/README.md` §3 的语义表没有写出 `vd.u32[1..3] = 0`（见 I-1）。

**语义一致性结论：通过。** 参考模型、NEMU、`VIMacU`、`VDotTop` 与生成的 Verilog 写回逻辑一致，`vl = 8` 时与官方伪代码逐位等价；各层日志都是修订后的结果。

---

## 2. 逐条对照表（赛题 1.1–3.3）

| 条目 | 交付物（存在性已核） | 字面要求是否满足 | 关键数字与原始行 | 判定 |
|---|---|---|---|---|
| 1.1 环境部署验证 | `tests/riscv/hello/`、`scripts/03_run_hello.sh` | 输出 `hello xiangshan, I am cie2026-vdot, IP address 192.168.30.213` | `logs/stage1/p1_hello_xiangshan.log:97,115,118`（输出串、`HIT GOOD TRAP`、8115 条）；全核 `p1_hello_xiangshan_fullcore.log:67,76-77`（8369 条 / 68522 周期） | 满足 |
| 1.2 操作日志 | `logs/stage1/` 11 个 `.log` 共 17826 行（实数），另有 `linux_repro/` | 含部署全过程与 4 次失败修复；Linux 空目录复现记录包含克隆过程（`00_setup_env_host.term.log:68-85`，HEAD pin 在 `:76,85`），rc/耗时在 `:644-645` | 数字吻合 | 满足 |
| 1.3 向量加法执行过程 | `docs/stage1/02_*.md`、7 张图、VCD 与文本轨迹 | 依据 FU 级波形与全核波形描述执行过程 | 全核时刻 1483→1494 与 `logs/stage3/fullcore/wave_trace.txt:150-181` 逐行吻合 | 满足（IFU/IBuffer 内部仍是源码论证，已如实列出） |
| 2.1 设计文档 | `docs/stage2/10_*.md`、`13_*.md` | 语义、微架构、数据通路齐全；§1 开头有官方伪代码逐行对照 | 对照表引用的 `vdot_ref.c`、`VIMacU.scala`、`VDotTop.scala`、`VDotTree.scala`、检查脚本行号 8/8 命中 | 满足 |
| 2.2 RTL | `rtl/patch/*.patch`、`rtl/chisel/`、`rtl/verilog/vdot/` | Chisel 实现并接入 `VIMacU` | `sync_rtl_sources.sh --check` PASS、`verify_patches.sh` PASS（本次复跑） | 满足 |
| 2.3.1 正数 | `tests/vectors/*positive.txt` | 基于香山仿真环境（FU 级 + 全核） | FU 级 46+46+40=132（`p5_summary.log:5-7`）；全核 132（`corpus_b00.log:22,25,28`） | 满足 |
| 2.3.2 负数 | `*negative.txt` | 同上 | 50+50+44=144（`p5_summary.log:8-10`、`corpus_b00.log:23,26,29`） | 满足 |
| 2.3.3 边界 | `*boundary.txt`、`vstart_relaxed.txt` | 最大/最小/零/非法均覆盖 | FU 级 100+100+106+130=436；全核 109+109+115=333，其中 27 条 must-trap 全部 `mcause=2`（`corpus_b00.log:24,27,30,38-39`） | 满足 |
| 3.1.1 NEMU 扩展 | `nemu/patch/0001-*.patch`、`docs/stage3/20_*.md` | 新增 vdot 族指令 | 30794/30794、4834 条 trap（`p5_vdot_tests.log:90-93`）；`.so` 形态 `trap code:0`（`:119,129`） | 满足（`nemu/README.md` 过时，见 I-1） |
| 3.1.2 协同仿真 | `tests/cosim/`、`docs/stage3/21_*.md`；全核 `docs/stage3/23_*.md` | NEMU↔RTL 一致性 | Level 1：72794 / 55960 / 分歧 0（`p6_cosim_run.log:45-52`）。Level 2：30794/30794，24,524,262 条提交 / 27,104,437 周期（复审者把 10 份日志的 `instrCnt`/`cycleCnt` 逐份相加复算，结果吻合），故障注入 3/3 + 3/3 | 满足（只构建了 MinimalConfig） |
| 3.2 基线 | `bench/baseline/`、`tests/riscv/baseline/` | 用 RVV 已有指令组合实现相同功能 | 25960/25960 三方 0 失配，long-vector 24 种长度 0 失配（`p7_baseline_equiv.log:114-117,146`）；基线本体已改为 `vmv.v.i` 清零 + `tu` 归约，高位与 S-3' 一致 | 满足 |
| 3.3 延迟加速比 | `docs/stage3/22_*.md`、`bench/results/*.csv`、图 1–9 | 对比基线与 vdot 的 latency | 全核 1.70×：(90−38)/(68.5−38) = 52/30.5，由 `perf_cycles.log:14-18,39-48` 的中位数复算。1.81× = 12.64/7.00，2.25× = 12.64/5.63；FU 2 拍（`p7_latency_measure.log:232-246`）。CSV 全部可复现 | 满足（默认配置未测、未综合，已如实标注） |
| 提交要求：录屏 ×3、PPT、加密提交 | `docs/ppt/` 只有大纲、分镜与清单 | **未做** | `docs/00:46-50` 如实标 ❌ | **未满足**（见 B-1） |

---

## 3. 问题清单

### 阻断

**B-1　提交流程未完成（不是仓库缺陷，但在提交层面是阻断项）**
- 证据：`docs/00_项目总览.md:46-50`、`README.md` §5 第 5 条：三段录屏、PPT、`submit.sh` 加密同步到 XiangShanLab 均为「未做」；`docs/ppt/提交清单.md:13-20,42,46,70,87,91-92,143,150,157-158,160`、`docs/ppt/讲解大纲.md:57,59`、`docs/ppt/录屏脚本.md:15,29,271` 共 24 处「待确认」需要团队填写。这些「待确认」按约定可以接受，此处一并列出。
- 建议：按 `docs/ppt/录屏脚本.md` 录制。录屏②③开头先演示 `vl = 8` 用例，参照 `docs/stage2/12` §3.2、`positive.txt:59-64`。填完「待确认」后，再跑一遍 `git grep -n 待确认 -- docs/ppt` 确认清零。

### 重要

**I-1　`nemu/README.md` 整份停留在 S-3' 之前，sha256 与它自己引用的日志行矛盾**
- 证据：该文件最后一次提交是 `75aa818`（10-25），S-3' 之后未更新。
  - `nemu/README.md:22`：patch sha256 写 `fb003c54…8838`，并标注出处 `logs/stage3/p5_nemu_build.log:7`；但该日志行与现补丁实测的 sha256 都是 `cb9194f8…9503`。
  - `:23`：「+278 / -1 行，`vdot.c` 221 行」；实测为 +285 / -1、`vdot.c` 228 行（`git apply --stat`），`docs/stage3/20:22,136,145` 已是新值。
  - `:34,108-110`：「13 个共享 suite（30703 条）…共 30758 条」；现为 30739 / 30794。
  - `:137-139` 的语义表只写 `vd.u32[0] = Σ…`，没有写元素 1..3 清零。
- 影响：评委按 3.1.1 打开 NEMU 目录时，第一份读到的就是一组与日志对不上的数字。
- 建议：把 sha256、行数、语料条数改成现值，语义表补上「`vd.u32[1..3] = 0`，与 `vta`/`vma` 无关（S-3'）」。

**I-2　调研笔记中残留自动化工具的内部名称**
- 证据：`docs/_recon/vdot-semantics-research.md:14`，「页面正文和 `<img>` 全部由 JS 渲染，」之后紧跟一个英文驼峰工具名（反引号包裹，以 Fetch 结尾），用来描述抓取网页的手段。`git log --all -p` 中同样存在。全仓及历史中没有其它 AI 工具名称、co-authored 署名或智能体类流程用语；git 作者统一为 `cie2026-vdot <cie2026-vdot@users.noreply.github.com>`（41 个提交）。
- 建议：把该词改为中性表述，例如「直接 HTTP 抓取只拿到 `<title>`」。历史中的残留需由团队决定是否改写（改写会影响已记录的提交号引用）。

**I-3　（语义风险，需在答辩中主动说明）`vl` 机制与伪代码写死的 8**
- 证据：伪代码 `for i in range(8)`，与 `vl` 无关；本项目对元素 `0..vl-1` 求和，`vl = 16`（`vsetvli e8,m1` 取 VLMAX 时的默认值）求 16 项。全核波形演示用例（`wave_trace.txt:182-183`，`vs1 = 3..18`，结果 −168）是 16 项和。项目在 README 引言、`docs/stage2/10` §1「取舍 1」、`讲解大纲.md:149` 中都已如实说明并给出「64 位切片装 8 个 int8」的理由，属于有据可查的设计选择，不是缺陷。
- 风险：评委若用 VLMAX 写测试程序，按伪代码会期望 8 项和。
- 建议：README §1.1 的语义一致性一行注明「需 `vl = 8`」；录屏与 PPT 的主演示改用 `vl = 8` 用例（语料中已有，FU 级与全核都已执行）；全核波形图保留 `vl = 16` 版本时，在图注中说明它是满寄存器版本。

### 次要

**M-1　「阶段二未附波形截图」已过时**：`README.md` §5 第 6 条（「阶段二波形以 VCD + 文本轨迹交付，未另附截图」）、`docs/00_项目总览.md` §2 阶段二一行（「仍未整改：I-3 未附波形截图」）。实际上 `docs/stage2/figures/fig1-3_*.png` 存在，并已嵌入 `docs/stage2/12:1022,1078,1095`（提交 `91163b8`）。建议删去或改为「已附图」。

**M-2　VCD 体积说明过时**：`.gitignore:29-30` 与 `docs/stage2/11_RTL实现说明.md:653-660` 写「8 份、10.5 MB，单份 ≤ 2 MB（最大 1.85 MB），阶段三 5.4 MB」。S-3' 重跑后实测共 15,200,156 B，阶段三 3 份为 2.62 / 2.74 / 2.84 MB，超出文件里自定的「单份 ≤ 2 MB」判据。建议更新数字，或放宽判据并说明理由。

**M-3　`docs/stage2/10_vdot指令设计文档.md:671`** 仍写「真实的背靠背间隔未实测……需全核仿真（T1）」；全核实测已经给出「每跳依赖 = FU 延迟 + 5 拍」（`docs/stage3/22` §5.5.5，README:80）。建议补一句指向全核结果。

**M-4　`docs/_recon/kmhv2-vector-integration.md:690,783`** 写 vdot「其余按 vta 处理」，没有 S-3' 标注，也没有文件级「历史笔记」提示（同目录的 `vdot-semantics-research.md` 已补记）。建议在文件头加一行「写于 S-3' 之前，vdot 尾部语义以 `docs/stage2/10` 为准」。

**M-5　隐私信息（低风险）**：本地用户路径 `/Users/i3eg1nner/...` 出现在 11 个已跟踪文件中，共 1116 处（`logs/stage1/p1_t1/t2/t3*.log`、`logs/stage2/p4_*.log`、`check_funct6.log`、`docs/_recon/*.md`、`docs/stage2/10`、`docs/_plan/ACCEPTANCE_P3.md`、`FINAL_REVIEW.md`）；该用户名与公开的 GitHub 账号相同。日志中还有局域网 IP `192.168.30.213`（赛题 1.1 要求输出 IP，可以接受）与服务器 IP `172.100.0.6`。没有发现口令、令牌、邮箱、电话。日志按「禁止伪造」原则不应改写，建议保持现状，在提交清单中由团队确认可以接受。

**M-6　仓库外的引用没有路径**：`README.md:71` 与 `bench/results/speedup.csv` 引用 `UopInfoGen.scala:197-235`，该文件属于上游、不在仓库内，也没有给出 `$XS/src/main/scala/xiangshan/backend/decode/` 前缀，评委无法定位。建议补全路径（`uop_count.csv` 已带「实现树」行号，可以参照）。

**M-7　2.2 的编译证据是 S-3' 之前的构建**：`docs/00_项目总览.md:31` 以 `logs/stage2/p4_rtl_build.log:13,32`（2026-10-24）作为「82 / 382 个 Scala 源文件编译通过」的证据。S-3' 之后的构建证据在 `logs/stage3/cosim/p6_build.log`、`logs/stage3/fullcore/build_emu.log` 与 `p5_*` 中。建议并列给出 S-3' 之后的构建日志。

**M-8　`target.md`（赛题原文）中插入了团队注记**：`target.md` 第 17 行的 HTML 注释（`6b3e499` 加入），虽然标明了「团队补记」，但改动了标称为「原文」的文件。建议把注记移到 README 或 `docs/stage2/10`，保持原文不变。

---

## 4. 引用抽样表

抽样范围：README 全部 47 处与 `docs/00` 全部 39 处 `文件:行号` 引用；`docs/stage*`、`docs/ppt` 中的日志/CSV/语料类引用按固定种子随机抽 34 处；设计文档 §1 对照表中的代码行号引用 8 处。**合计 128 处，命中 127 处，无法定位 1 处**（`UopInfoGen.scala:197-235`，上游文件，不在仓库内，见 M-6），**数值不符 0 处**。命中率 99.2%；只计仓库内可解析的引用为 127/127。

抽样之外另发现 1 处引用与原始行不符：`nemu/README.md:22` 所引 `p5_nemu_build.log:7` 的 sha256（见 I-1）。

> 注：最初用 Python 通用换行模式读日志时，`00_setup_env_host.term.log:68-85` 显示为 apt 进度行，原因是该日志含 `\r`。改用 `newline=''` 后，行号与 `grep -n` 一致，引用命中。下表全部按 `\n` 计行。

| # | 引用位置 | 被引 `文件:行` | 原始行内容（摘） | 文档中的数字 | 结果 |
|---|---|---|---|---|---|
| 1 | README:16 | `p3_official_pseudocode_equiv.log:40` | `PASS (20570 cases, 0 mismatches)` | 20570 / 0 | 命中 |
| 2 | README:35 | `p1_hello_xiangshan.log:97,115,118` | hello 串 / `HIT GOOD TRAP` / `total guest instructions = 8115` | 8115 | 命中 |
| 3 | README:36 | `p1_hello_xiangshan_fullcore.log:67,76-77` | IP `172.100.0.6`；`instrCnt = 8369, cycleCnt = 68522` | 8369 / 68522 | 命中 |
| 4 | README:37 | `p3_…equiv.log:30-31,34-35,62` | 285 / 285 / 10000 / 10000；`FAIL (532 cases, 532 mismatches)` | 同 | 命中 |
| 5 | README:38 | `p5_summary.log:5-43,45` | 合计 `290175 290175 0 9358` | 290175 / 9358 | 命中（拆分 712+235348+26060+51=262171，加 28004 得 290175，复算成立） |
| 6 | README:39 | `corpus_b00.log:22-30,38-39` | 46/50/109/46/50/109/40/44/115；must-trap 809=809 | 132 / 144 / 333 | 命中 |
| 7 | README:39 | `fullcore/summary.log:8-9` | `CORPUS TOTAL cases=30794 … trapped-mcause2=4834`；失配行数 0 | 同 | 命中 |
| 8 | README:41 | `p5_summary.log:41` / `p5_vimacu_equiv.log:86` | 26060 执行 / 26060 通过 | 26060 | 命中 |
| 9 | README:42 | `p5_decode_illegal.log:123` / `p5_decode_prove_fail.log:144` | 51 PASS / PASS 38 FAIL 13 | 51 / 13 | 命中 |
| 10 | README:43 | `p5_regression.log:31-39,52-54` | 9 行 YES；164 / 163 / `['SimTop']` | 同 | 命中 |
| 11 | README:44 | `stage2/p5_fault_injection.log:273-274` | 注入 6 个，检出 6 个 | 6/6 | 命中 |
| 12 | README:45 | `p5_vdot_tests.log:90-93,119,129` | 30794 / 4834 / `trap code:0` / 退出码 0 | 同 | 命中 |
| 13 | README:46 | `p5_patch_verify.log:47,51` | 30794 / `PATCH-VERIFY: OK` | 同 | 命中 |
| 14 | README:46 | `stage3/p5_fault_injection.log:191-192` | 等价变异体 1 个；6/6 | 同 | 命中 |
| 15 | README:47 | `p6_cosim_run.log:45-52` | 72794 / 55960 / 分歧 0 | 同 | 命中 |
| 16 | README:48 | `fullcore/summary.log:1-9` | 6 批 HIT_GOOD_TRAP | 同 | 命中 |
| 17 | README:48 | `fault_summary.log:1-5` | bit0 翻转 3/3 | 3/3 | 命中 |
| 18 | README:48 | `fault_summary_s3old.log:1-5` | `v3_high … wrong = 0xffff…`，3/3 | 3/3 | 命中 |
| 19 | README:49 | `p6_fault_injection.log:358` | `7/7 被检出` | 7/7 | 命中 |
| 20 | README:49 | `p6_fault_rtl1_rerun.log:41-58` | T3-RTL-1b，`{96'h0, …}` | 同 | 命中 |
| 21 | README:50 | `p7_baseline_equiv.log:114-117,146` | 25960 / 0 / `vdotacc=7` / 24 种长度 | 同 | 命中 |
| 22 | README:60 | `uop_count.csv:3-4` | `vmv.s.x … 2`、`vmv.v.i … 2` | 2 / 2 | 命中 |
| 23 | README:66 | `p7_latency_measure.log:232-246` | 196/196/190 笔第 2 拍成形 | 同 | 命中 |
| 24 | README:67 | `p7_latency_measure.log:254-258,319,321,335` | vwmul 2 拍；vmv.s.x / vmv.v.i 1 拍；vwredsum 2 拍「未建模」 | 同 | 命中 |
| 25 | README:69 | `perf_cycles.log:19-28` | minstret 9 / 5，减去空窗口 3 得 6 / 2 | 6 / 2 | 命中 |
| 26 | README:71 | `UopInfoGen.scala:197-235` | 上游文件，仓库内无 | 14 / 3 | **无法定位**（M-6） |
| 27 | README:73 | `p7_baseline_equiv.log:162-169` | 2577 / 2063 | 1.249× | 命中 |
| 28 | README:75 | `perf_cycles.log:9-48` | 中位数复算 52 / 30.5 | 1.70× | 命中 |
| 29 | README:76 | `perf_cycles.log:109-133,184-233` | seqD / vdotacc / acc2 原始周期 | 1.81× / 2.25× | 命中（与 `cycles_fullcore.csv` 一致） |
| 30 | README:110 | `rtl/patch/0001-xiangshan-vdot.patch:276-277` | `redVd = … Cat(0.U((VLEN - 32).W), dotVd(31, 0))` | — | 命中 |
| 31 | README:111 | `rtl/patch/0002-yunsuan-vdot.patch:184` | 同上（`VDotTop`） | — | 命中 |
| 32 | README:140 | `p1_t1_toolchain.log:113,115` | 折叠说明 81 行 / 137 行 | 同 | 命中 |
| 33 | README:168,229 | `build_emu.log:2434` | `Maximum resident set size (kbytes): 56445000` | 同 | 命中 |
| 34 | README:198 | `02_build_nemu.term.log:395-396`、`03_run_hello.term.log:135-136` | rc 0 / 31 s；rc 0 / 0 s | 同 | 命中 |
| 35 | README:205 | `build_emu.log:2429,2448`、`build_driver.log:40`、`run_driver.log:76` | 24:31.63 / exit=0 / 24m45s / 60m33s | 同 | 命中 |
| 36 | README:209 | `p7_baseline_equiv.log:13-14` | GCC 15.2.0 | 同 | 命中 |
| 37 | README:211 | `docs/stage3/22:632-639` | +2 条与斜率不变的说明 | 同 | 命中 |
| 38 | docs/00:27 | `p1_hello_xiangshan.log:97` 等 | 同 #2 | — | 命中 |
| 39 | docs/00:28 | `00_setup_env_host.term.log:68-85` | 克隆 XiangShan / NEMU，HEAD pin 在 `:76,85` | — | 命中 |
| 40 | docs/00:28 | `02_build_nemu.term.log:162,269`、`03_run_hello.term.log:101,119` | 两种形态产物；hello / GOOD TRAP | — | 命中 |
| 41 | docs/00:29 | `wave_trace.txt:150-181` | 1483 译码入 … 1494 提交 | 时刻序列 | 命中 |
| 42 | docs/00:31 | `p4_rtl_build.log:13,32` | compiling 82 / 382 Scala sources | 82 / 382 | 命中（S-3' 之前，见 M-7） |
| 43 | docs/00:32 | `p5_func_positive.log:19,36,53` | 46 / 46 / 40 PASS | 132 | 命中 |
| 44 | docs/00:35 | `p5_summary.log:28-38,40` | 28000 + 1 + 3 | 28004 | 命中 |
| 45 | docs/00:37 | `p6_fault_injection.log:151-156` | 6402 FAIL，T3-RTL-1b 检出 | 6402 | 命中 |
| 46 | docs/00:37 | `fullcore/summary.log:1-37` | 10 份 instrCnt / cycleCnt 相加 = 24524262 / 27104437 | 同 | 命中（复算） |
| 47 | stage2/12:210 | `p5_vimacu_equiv.log:72,75,78` | 46 / 46 / 40 通过 | 132 | 命中 |
| 48 | stage2/12:257 | `positive.txt:63-64` | `cc000000 000…`（=204） | 204 | 命中 |
| 49 | stage2/12:259 | `vdotacc_positive.txt:61` | `ad9da7a5 000…` | 复算一致 | 命中 |
| 50 | stage2/12:284 | `p5_func_positive.log:67-75` | DUT `…_00000000000005d8`，与期望一致 | 1496 | 命中 |
| 51 | stage2/12:320 | `p5_func_positive.log:117-125` | vdot4a DUT = 期望 | — | 命中 |
| 52 | stage2/12:387 | `negative.txt:63-64` | `00000200 000…`（=131072） | 131072 | 命中 |
| 53 | stage2/12:567 | `p5_func_boundary.log:224,226`、`p5_vimacu_equiv.log:77` | `…a5a3a9a5`；100 / 100 | 同 | 命中 |
| 54 | stage2/12:88 | `corpus_b02.log:33` | `vdotacc_random 4660 4660 0 681` | 4660+5133+207 / 681+862+29 | 命中（复算） |
| 55 | stage2/12:92 | `summary.log:2-8` | 6/6 批 GOOD TRAP | — | 命中 |
| 56 | stage2/12:1244 | `p7_latency_measure.log:46-63` | `#21 fire → #25 成形` | 2 拍 | 命中 |
| 57 | stage2/12:1252 | `wave_trace.txt:159,162,170` | 三条 vdot 的 DECODE-OUT，`fuOpType 0xe7/0x177/0x1f7` | — | 命中 |
| 58 | stage2/10:104 | `p3_…equiv.log:30-31` | 285 / 285 | 同 | 命中 |
| 59 | stage2/10:1331 | `p3_…equiv.log:40` | 20570 | 同 | 命中 |
| 60 | stage1/02:450 | `wave_trace.txt:160,165,168,173` | 重命名 / IQ1 / ROB / 发射，`psrc=(50,48,1)` | 同 | 命中 |
| 61 | stage1/02:1168,1246,1248 | `wave_trace.txt:178,173,165,168` | 1491 进 VialuFix 等 | 同 | 命中 |
| 62 | stage1/01:309,406 | `p1_hello_xiangshan.log:7-12,20-22` | IP 获取命令；`MBASE/UARTLITE/VLEN` | 同 | 命中 |
| 63 | stage3/20:315 | `p5_vdot_tests.log:17-30` | 逐 suite 条数 | 同 | 命中 |
| 64 | stage3/21:537 | `p6_cosim_run.log:45-52` | 同 #15 | — | 命中 |
| 65 | stage3/21:801 | `wave_trace.txt:173-192` | 物理寄存器号逐级传递 | — | 命中 |
| 66 | stage3/21:974 | `p6_fault_rtl1_rerun.log:41-58` | 同 #20 | — | 命中 |
| 67 | stage3/23:110 | `build_emu.log:2385,2409` | 15:50:33 → 16:04:35 | 约 14:02 | 命中 |
| 68 | stage3/23:234 | `fault_summary.log:2` | `…468 → …469` | 同 | 命中 |
| 69 | stage3/23:275 | `wave_dump.log:19` | 382179562 B | 382 MB | 命中 |
| 70 | stage3/23:332 | `corpus_b00.log:7` | defconfig 标题行 | 同 | 命中 |
| 71 | ppt/讲解大纲:75,106,238 | `p7_baseline_equiv.log:114-117`、`p1_hello_xiangshan_fullcore.log:67,76-77`、`p5_vdot_tests.log:90-93`、`p5_patch_verify.log:47,51` | 同上各行 | 同 | 命中 |
| 72 | stage2/10 §1 对照表 | `vdot_ref.c:236,103-106,109-112,63-65`、`VIMacU.scala:192-193`、`VDotTop.scala:128`、`VDotTree.scala:77`、`check_official_pseudocode.py:56-63` | SEW 检查 / 求和循环 / 清零 / 规则 5 / `redVd` / 符号扩展 / 字面实现 | — | 8/8 命中 |

（表中行 61、62、71、72 各合并了多处引用，所以表行数少于 128；未单列的其余 README / `docs/00` 引用都与上表同一日志行重复，已逐条核对，全部命中。）

---

## 5. 复现记录

全部只读执行，输出放在 `/tmp/review4/`。

| 命令 | 结果 |
|---|---|
| `bash scripts/tools/sync_rtl_sources.sh --check` | pristine `a4eeaab` / yunsuan `9559211`，3 份补丁应用成功；`逐字节相同 15 个文件（含 MANIFEST.md）`，`RTL-SYNC-CHECK: PASS`，退出码 0 |
| `bash scripts/tools/verify_patches.sh` | xiangshan 8 个文件、yunsuan 11 个文件与实现工作树相同，不同 0 个；`PATCH-VERIFY: PASS`，退出码 0 |
| `python3 bench/collect_results.py --equiv-log logs/stage3/p7_baseline_equiv.log --latency-log logs/stage3/p7_latency_measure.log --fullcore-perf-log logs/stage3/fullcore/perf_cycles.log --out /tmp/review4/results` | 退出码 0；生成 10 份 CSV，与 `bench/results/` **10/10 逐字节相同**（`cmp`） |
| `gcc … vdot_cli.c vdot_ref.c -o /tmp/review4/golden/vdot_cli`，然后 `python3 tests/golden/check_official_pseudocode.py --cli /tmp/review4/golden/vdot_cli --vectors tests/vectors --random 10000` | `OFFICIAL-PSEUDOCODE-EQUIV: PASS (20570 cases, 0 mismatches)`，退出码 0 |
| 复审者独立脚本 `/tmp/review4/my_check.py tests/vectors` | vdot / vdotacc 合计 17369 条 OK 用例 0 失配，高位非 0 的行 0 条（见 §1.3） |
| `diff` 补丁抽出的 `vdot.c` 与 `work/NEMU` 工作区中的版本 | 相同 |
| `git show 9d3409e^:logs/stage3/fullcore/perf_cycles.log` 与现日志的 `PERF` 行对比；`cycles_fullcore.csv` 新旧对比 | 均相同，与「S-3' 后周期逐拍相同」的表述一致 |
| 收尾 `git status --short` | 已跟踪文件无改动，唯一变化是本报告这个新增文件；`work/` 下各工作树的 `git status` 条数与复审前相同 |

说明：复审者手工编译 `test_golden.c` 时漏链了 `bench/baseline/baseline_ref.c`（项目 `Makefile` 会一并链接），属于复审操作疏漏，与仓库无关，因此该自检未计入上表。

---

## 6. 全仓一致性与收尾检查

- **数字一致性**：20570、290175、262171、30794、4834、72794、55960、25960、24,524,262、26060、235348、1.70× / 1.81× / 2.25× / 5.17× / 2.81× / 2.00× / 1.50× / 3.00× / 4.67× / 1.249× 在 README、`docs/00`、`docs/stage2/12`、`docs/stage3/20-23`、`docs/ppt/讲解大纲.md`、`录屏脚本.md` 之间没有冲突值。旧值（30710、30758、72758、55924、30663 等）只出现在带「修订前 / 供核对」标注的段落里；例外是 `nemu/README.md`（I-1）。故障注入计数 6/6（RTL）、6/6（NEMU）、7/7（Level 1）、3/3 + 3/3（全核）各处一致。
- **「实测 / 建模 / 源码推导」标注**：抽查 README §1.2 的每一行都与 `bench/results/speedup.csv` 的 `kind` 列一致；2.00× / 1.50× / 3.00× 标为建模，4.67× 标为源码推导，13.7% 标为结构计数上界，均无夸大。主结论限定在 MinimalConfig，并注明默认配置未测、未综合。
- **AI 工具名称 / 流程用语**：当前文件中只有 I-2 一处；其余命中都是无关子串（`p1_docker_build.log` 中的 apt 软件包名、`scripts/tools/vcd_plot.py` 中的一个绘图变量名、赛题背景中作为模型名提到的 GPT-2）。没有智能体类流程用语。
- **git 作者**：41 个提交的作者与提交者都是 `cie2026-vdot`；只有 `main` 一个分支，没有 tag 和 stash。
- **占位符**：除 `docs/ppt` 中按约定保留的 24 处「待确认」（见 B-1）外，`TODO/FIXME` 只出现在上游派生文件（`tests/unit/VectorSimTop.scala` 等，README §5 第 6 条已说明）与历史审计记录的描述文字中；`docs/_plan/HANDOFF_TODO.md` 的文件名含 TODO，是交接文档，可以接受。
- **大文件**：最大的已跟踪文件是 4.09 MB 的生成 Verilog；`.git` 打包后 11.8 MB；没有 `.o/.so/build/` 误入库。VCD 体积说明过时（M-2）。

---

## 7. 评分预测（按 `score.md` 四个一级指标）

预测以仓库现状为准，假定提交前完成录屏与 PPT。若录屏/PPT 缺失，完整性三项各自可能被下调 1–2 分。

| 一级指标 | 二级指标 | 满分 | 预测 | 主要依据 |
|---|---|---:|---:|---|
| 完整性（60） | 阶段一交付物 | 15 | 13–14 | 三项交付物齐全，全核时刻锚点补上了「依据波形」的证据；IFU 等内部仍是源码论证 |
| | 阶段二交付物 | 20 | 18–19 | 设计文档含官方伪代码逐行对照，RTL 补丁可复现，三项测试在 FU 级与全核双平台通过；扣分点：M-1 等过时表述 |
| | 阶段三交付物 | 25 | 21–23 | NEMU、两级协同仿真、基线、全核周期实测齐全；扣分点：只有 MinimalConfig、未综合、`nemu/README.md` 过时（I-1） |
| 可行性（20） | 技术路径合理性 | 10 | 9 | 乘法阵列零新增、调度写回网络零改动、补丁逐字节可复现；时序只有静态估算 |
| | 功能验证有效性 | 10 | 9–10 | 正/负/边界覆盖充分，故障注入证明比对有区分力；协同仿真与全核 difftest 0 失配 |
| 探索性（10） | 微架构优化分析 | 5 | 4–5 | 多口径加速比，实测与建模分开标注，主动披露不利结论 |
| | 软硬件协同理解 | 5 | 4–5 | Level 1 机制剖析加上 Level 2 全核验证，S-7' 由协同仿真发现并收敛 |
| 创新性（10） | 设计优化独特性 | 5 | 4 | XOR 蝶形折叠树、三指令共享数据通路、`prod16` 抽头保持 2 拍 |
| | 扩展应用潜力 | 5 | 3–4 | `vdot4a` 体现 SEW=32 扩展；LMUL>1 只做了论证，未实现 |
| **合计** | | **100** | **85–92（中位约 88）** | |

修完 I-1、I-2，并把答辩主演示改为 `vl = 8`（I-3）之后，预测区间不变，但被评委当场质疑的风险明显降低。
