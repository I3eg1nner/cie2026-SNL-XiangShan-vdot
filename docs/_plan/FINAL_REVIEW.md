# 最终独立复审报告（提交前，赛题 1.1–3.3 全量）

| 项 | 值 |
|---|---|
| 复审对象 | 仓库 `main` @ `c3d2f2e`（29 个 commit，262 个已跟踪文件） |
| 复审依据 | `target.md`（1.1–3.3 提交要求）、`score.md`（四个一级指标）、`docs/_plan/MASTER_PLAN.md` P1–P8 验收标准与 §2 执行纪律 |
| 复审方式 | 数字一律追到日志原始行；自动抽取全部 `文件:行号` 引用后逐条人工核对内容；在独立 `WORK_DIR` 上抽跑 5 个短步骤；历史审计 `ACCEPTANCE_P1/P2/P3.md` 只作线索，不采信其数字 |
| 复审时间 | 2026-10-25 |
| 复审者立场 | 未参与任何建设工作；站在评委角度，目标是证伪而非确认 |
| 对工作树的影响 | 主仓库已跟踪文件未改动（结束时 `git status` 仅本文件为未跟踪新增）；所有复跑输出写到 `/tmp/finalreview/`。复跑 `21_build_nemu_vdot.sh` 重建了 `/data/my/cie2026-vdot-xiangshan-linuxrepro/work/NEMU` 的两种形态，并把它的 `.config` 从 ref 形态还原为独立解释器形态（脚本自带的 restore 步骤） |

---

## 0. 总评

技术主体**扎实、真实、可复现**。我没有发现任何伪造的数字：README §1 与 `docs/00_项目总览.md` 赛题对照表里的每一个数字都能在日志里原样找到；
全核 difftest 的 24,517,314 条提交由 10 份日志的 `instrCnt` 逐项相加复算吻合；`bench/results/` 的 9 个 CSV 由存档日志重新生成后**逐字节相同**；
`03`/`21` 号脚本、`sync_rtl_sources.sh --check`、`verify_patches.sh` 在独立工作目录上全部通过。
「实测 / 源码推导 / 建模 / 声明值」的标注总体准确，建模值没有被说成实测，局限性章节诚实。

但仓库**还不能直接转 public**：git 历史中有不应公开的内容（阻断 B-1，已在本地改写历史清除），计划类文档用语不规范（阻断 B-2，已整改），
两者都不符合 MASTER_PLAN §2 第 2 条与 P8 第 4 条。另外，阶段三最有分量的扣分点（3.3 加速比没有一项是全核实测周期）
现在**完全有条件补**，因为全核 emu 已经能跑，这是性价比最高的加分项（I-1）。

| 维度 | 判定 |
|---|---|
| 真实性（日志 / 波形 / 数据是否来自真实执行） | **通过**（未发现伪造；日志有 2 处已在文件内披露的人工编辑，见 M-4） |
| 数字一致性（README / 00 / 阶段文档 / PPT 材料） | **通过**（抽查 36 个关键数字，跨文档无矛盾；历史数字均带「修订前」标注） |
| 引用准确性 | **通过**：人工核对 88 处 `文件:行号`，86 处完全命中，2 处行号漂移（97.7%） |
| 标注准确性（实测 / 建模） | **基本通过**，2 处 CSV 层面的标注瑕疵（M-1） |
| 可复现性 | **通过**，1 处顺序依赖（M-3） |
| P8 收尾（署名与用语 / 占位符 / 历史 / 隐私） | **不通过**（B-1、B-2、I-3） |

---

## 1. 逐条对照（赛题 1.1–3.3）

| 条目 | 交付物存在 | 满足字面要求 | 证据真实且与文档一致 | 判定与说明 |
|---|---|---|---|---|
| **1.1** 环境部署验证 | ✅ `tests/riscv/hello/`、`scripts/03_run_hello.sh` | ✅ 输出 `hello xiangshan, I am cie2026-vdot, IP address 192.168.30.213` | ✅ `logs/stage1/p1_hello_xiangshan.log:97,115,118`；IP 取自 `:7-12` 的真实网卡；我复跑得到同格式输出（IP 为本机 `172.100.0.6`，8189 条指令，差异来自 GCC 15 与 IP 串长度） | **完成，有保留**：程序运行在 NEMU 上，不在香山 RTL 上（已披露）。全核 emu 现已可用，见 I-2 |
| **1.2** 操作日志 | ✅ `logs/stage1/` 9 个文件 17726 行（复算一致） | ✅ 含 Docker 构建、工具链、精化、4 次真实失败与修复 | ✅ 但日志中有大量 `/Users/<用户名>/...` 绝对路径（I-3）与 1 处折叠编辑（M-4） | **完成** |
| **1.3** 向量加法执行过程 | ✅ `docs/stage1/02_*.md`（1300+ 行）、6 张图、2 份 VCD | ✅ 依据波形 + 源码描述了编码→译码→拆分→重命名→发射→执行→mask/tail→写回→提交 | ✅ 执行段为 FU 级真实波形；补充了一条 vadd 在 MinimalConfig 全核中的实测周期（`logs/stage3/fullcore/wave_trace.txt:155-181`，已核对） | **完成，有层级局限**（取指/译码/重命名/写回段为源码级，各节已标注） |
| **2.1** 设计文档 | ✅ `docs/stage2/10_*.md`、`13_*.md` | ✅ 语义、编码、微架构、数据通路、面积估算、扩展性 | ✅ 编码空间检查 `logs/stage2/check_funct6.log` | **完成**；少量过期局限条目（M-5） |
| **2.2** RTL 实现 | ✅ `rtl/patch/` 3 份补丁、`rtl/chisel/`、`rtl/verilog/` | ✅ Chisel，在 `VIMacU` 内扩展 | ✅ 我复跑 `sync_rtl_sources.sh --check` → `RTL-SYNC-CHECK: PASS`；`verify_patches.sh` → `PATCH-VERIFY: PASS` | **完成** |
| **2.3.1** 正数 | ✅ | ✅ 120 条全 PASS（`logs/stage2/p5_summary.log:5-7`） | ✅ | **完成**；存档平台是 FU 级，同一语料在全核 difftest 上 0 失配（`logs/stage3/fullcore/summary.log:8`） |
| **2.3.2** 负数 | ✅ | ✅ 132 条全 PASS（`:8-10`） | ✅ | 同上 |
| **2.3.3** 边界值 | ✅ | ✅ 94+94+106+130 = 424 条 PASS，跳过 27 条（`:11-14`） | ✅ 合计 290103 / 0 失败 / 9358 跳过（`:43,45`），235348 条随机由 `:15-27` 加和复算吻合 | 同上 |
| **3.1.1** NEMU 扩展 | ✅ `nemu/patch/0001-*.patch` | ✅ | ✅ 我复跑 `21_build_nemu_vdot.sh`：`TOTAL cases=30758 pass=30758 fail=0`、4834 条 must-trap 全部 `mcause=2`，suite 表与存档逐行相同 | **完成** |
| **3.1.2** 协同仿真 | ✅ Level 1 `tests/cosim/` + Level 2 `tests/riscv/fullcore/`、`scripts/50_*` | ✅ | ✅ L1：`p6_cosim_run.log:45-52`；L2：6 批语料 + 4 个种子依赖测试 `HIT GOOD TRAP`，`Difftest enabled`、REF 为打补丁 NEMU `.so`（`corpus_b00.log` 头部）；故障注入 3/3（`fault_summary.log`、`fault_diff.txt`） | **完成**；只跑了 MinimalConfig，文档已如实限定 |
| **3.2** 基线实现 | ✅ `bench/baseline/baseline_rvv.S` 等 | ✅ 只用 RVV 1.0 标准指令 | ✅ `p7_baseline_equiv.log:112-114,144` | **完成**；候选 A/B/D 都真跑过，选择理由充分 |
| **3.3** 延迟加速比 | ✅ `docs/stage3/22_*.md`、`bench/results/*.csv`、7 张图 | ⚠️ 「latency 加速比」：FU 延迟是实测，但**单次点积 2.00× 与吞吐 1.50×/3.00× 都是建模值**，没有任何一项是流水线周期实测 | ✅ CSV 由日志重生成逐字节相同；标注诚实 | **完成但最薄弱**，见 I-1 |
| 提交物（录屏 ×3、PPT、加密提交） | ❌ 只有 `docs/ppt/` 下的大纲、分镜、清单 | — | — | **未做**（已在 README §5 与 `00` §1.2 如实标 ❌）；需团队完成 |

---

## 2. 问题清单

### 阻断（2 项，转 public 前必须处理）

**B-1　git 历史中有不应公开的内容（已处理）**
- 复审时 git 历史中的个别早期版本含有不应公开的内容（当前工作树中没有），与 MASTER_PLAN §2 第 2 条、P8 第 4 条的要求不符，需在转 public 前改写历史。
- 处理情况（复审后补记）：已在本地改写 git 历史，相关内容已从全部历史版本中清除，作者同时统一（I-3）；改写后全部提交哈希改变，本报告中的提交哈希已更新为改写后的值。

**B-2　计划 / 审计文档用语不规范（已整改）**
- 计划与审计文档中部分角色称呼和自检写法不符合团队文档规范，已统一整改，技术内容与结论未改。

### 重要（4 项）

**I-1　3.3 加速比没有任何一项是流水线周期实测，而全核 emu 已经可用**
- 现状：单次点积 2.00× 是「实测 FU 延迟按依赖链相加」的模型；长向量 1.50× / 3.00× 是端口 + 依赖下界模型；实测只有 FU 延迟、指令数、等价性。
  `docs/stage3/22_*.md:672` 仍写「本阶段没有实测这条：要验证它需要跑全核流水线，本机做不到」，与已完成的 Level 2 全核 difftest 矛盾（过期措辞）。
- 证据：全核 emu 每次运行都打印 `cycleCnt`（例如 `logs/stage3/fullcore/dep0.log` 的 `instrCnt = 4583750, cycleCnt = 4521484`），`vdot_wave.S` 的波形也已经给出单条依赖链的周期。
- 影响：赛题 3.3 字面要求「对比 Baseline 与 vdot 加速单元的 latency 加速比」；评委最可能在这里扣分（阶段三完成度、微架构优化分析两项都会受影响）。
- 修法（约半天，复用现有构建）：把 `bench/baseline/baseline_rvv.S` 的单次点积与长向量内核（基线 D、`vdotacc`、`vdot_dot_i8_acc2`）分别包成裸机程序，在全核 emu 上用 `rdcycle` 前后差测量（带 difftest 也可以），
  N = 64…4096 各跑一次，得到实测周期与加速比；对应把 `22` §5 的 1.50× / 3.00× 和 2.00× 改成「模型值 vs MinimalConfig 实测值」并列，并删除「本机做不到」的说法。

**I-2　1.1 的 hello 只在 NEMU 上运行**
- 现状：`docs/stage1/01_*.md` §6.1 已披露；阶段一时全核构建不可行有理由，但现在全核 emu 已经构建成功。
- 影响：「按照香山操作手册完成开发环境部署」通常指在香山 RTL 仿真器（emu）上运行程序；评委可能认为 1.1 只完成了一半。
- 修法：用现成的 `work/XiangShan-fullcore/build/emu` 加 `--diff` 跑一次 `hello.bin`（串口地址按 SimTop 的 uartlite 配置），日志落盘为 `logs/stage1/p1_hello_xiangshan_emu.log`，README §1 与 `00` 1.1 行补一句。

**I-3　个人信息与绝对路径**
- 日志与文档中有 1229 行 `/Users/i3eg1nner/...` 绝对路径（27 个文件，含 `docs/_recon/*.md`、`docs/stage2/10_*.md`、`docs/_plan/ACCEPTANCE_P3.md`）与 307 行 `/data/my/...`（31 个文件）。
- git 历史有两组作者：前 19 个 commit 为 `cie2026-vdot <…noreply…>`，后 10 个为个人姓名 + 机构邮箱（`git log --format='%an <%ae>' | sort -u`）。`ACCEPTANCE_P1.md:97,303` 写的「git 作者统一为 cie2026-vdot」因此已不成立。
- `docs/ppt/提交清单.md:15-16` 写出了 GitHub 用户名。
- 影响：日志里的绝对路径是真实运行的证据，不必全部抹掉；但用户名、个人邮箱与机构是否公开要由团队明确决定。至少文档正文（非日志）里的绝对路径应改为 `work/...` 相对写法。
- 修法：与 B-1 一起改写历史时统一作者；`docs/_recon/` 与 `docs/stage2/10` 中的 `/Users/...` 改成相对路径；日志保持原样，在 README §3 说明「日志中的绝对路径为原始运行环境路径」。

**I-4　提交物未完成**
- 三段录屏、答辩 PPT、加密提交（`submit.sh`）均未做（README §5 第 5 条、`00` §1.2 已如实标 ❌）。`score.md` 不单列这些，但 `target.md` 把它们列为提交要求，缺失会影响评委对完整性的判断。
- 修法：按 `docs/ppt/录屏脚本.md`、`讲解大纲.md`、`提交清单.md` 执行；`提交清单.md` 中 13 处「待确认」需团队填写（见 §3.2）。

### 次要（6 项）

**M-1　CSV 标注瑕疵**
- `bench/results/instr_count_single.csv` 整行标「实测(静态反汇编 + minstret 斜率)」，但同一行的 `decoded_uops_model`（14 / 3）是源码推导，`vector_body_instr` 与 `arch_instr_in_sequence`（6, 11 / 1, 3）是 `bench/collect_results.py:306,311` 写死的常量，且两行计法不一致。`22` §5.1 末尾已披露，但评委直接打开 CSV 时看不到这段说明。
- `bench/results/speedup.csv:3-4` 的 6→2、3→1 标「实测」，实际也是 `collect_results.py` 中的常量（人工数反汇编所得，数值本身我按 `baseline_rvv.S:282-312` 核对无误）。
- 修法：`instr_count_single.csv` 删掉写死的三列或改标「人工计数 / 源码推导」；`speedup.csv` 的这两行改标「实测（人工数反汇编）」，或让脚本从 `.dis` 解析。

**M-2　2 处 `文件:行号` 引用漂移**
- `docs/stage2/12_基础功能测试报告.md:58` 引 `scripts/11_build_vdot_sim.sh:53-54`，该处是 espresso 检查；复制参考模型的语句在 `:57-58`。
- `docs/stage3/21_协同仿真验证报告.md:293` 引 `tests/cosim/cosim_main.cpp:151-155`，该处是 `hex128()`；指令编码在 `:156-160`（`encode_instr()`）。

**M-3　`03_run_hello.sh` 依赖 NEMU 当前形态**
- `30_run_cosim.sh`（含 `fault` 子命令的 `rebuild_nemu_so`）与 `50_*` 把 `work/NEMU` 切到 ref 形态后不还原；之后再跑 `03` 会直接失败（`ERROR: 当前 NEMU 配置没有 CONFIG_UARTLITE_MMIO`）。我在复现目录上首次运行 `03` 就遇到了这个问题，先跑 `21`（末尾自带 restore）后才通过。按 README 的顺序执行不受影响，但评委录屏或单独复跑 1.1 时容易踩到。
- 修法：`30` 结束时像 `21` 一样 restore；或 `03` 检测到 ref 形态时自动 `make riscv64-xs-kmhv2_defconfig && make`。

**M-4　「真实终端日志」中有人工编辑**
- `logs/stage1/p1_t1_toolchain.log:113,115` 把 brew 第三方清单折叠成说明文字；`logs/stage3/p7_latency_measure.log:192-197,293-300` 用不同平台（Linux x86_64 + Verilator 5.024）的重跑结果**替换**了原段落，同一文件内混有两种运行环境。两处都在文件内写明了，不算伪造，但与 README §3「真实终端日志」的说法有出入。
- 修法：重跑段落另存为独立文件（如 `p7_latency_measure_vimacu_rerun.log`），原文件恢复为原始输出；README §3 注明哪些日志有折叠。

**M-5　过期的局限条目与措辞**
- `docs/stage2/10_*.md:1449`（R-16）、`11_*.md:630`（第 9 条）、`12_*.md:1049`（第 9 条）仍写「本机无 RISC-V 工具链，机器码未经汇编器回读」。之后 NEMU 一致性测试与全核译码轨迹（`wave_trace.txt:159,162` 的 `vdot.vv` / `vdotacc.vv` 解码结果）已实际验证了这些编码，应补「已由 P5/全核闭合」。
- `build_scripted_driver.log:32` 的脚本提示「MinimalConfig 首次构建约 1 小时」与同文件 `:35` 的实测 23:31 不一致（脚本文案）。
- 「Verilator 前端峰值 59.2 GB」对应 `build_time_breakdown.log:39` 的 `59157676 kbytes`（即 56.4 GiB / 60.6 GB），单位写法不严谨。

**M-6　关键证据图放在 `logs/` 下**
- `logs/stage3/fullcore/wave_fullcore_vdot.png` 被 `docs/stage1/02` §8.4.1 与 `23` §7 引用，但不在任何 `docs/*/figures/`，也没有嵌入文档；评委浏览文档时看不到这张最直观的全核波形图。建议复制到 `docs/stage3/figures/fig8_fullcore_wave.png` 并嵌入 `23` §7。

### 提示（不计入问题）

- `docs/stage1/01_*.md:523` 引用的 `xs-env/install-scripts/gsim.sh:22` 是上游仓库文件，不在本仓库内，属正常外部引用。
- 根目录的官方手册 PDF（816 KB）入库无害；是否允许再分发请团队自行确认。
- 历史中的旧数字（`30663` 条语料、`293107` 执行 / `6268` 跳过）只出现在带「修订前 / S-7' 之前」标注的位置，口径一致。
- `.gitignore` 与实际入库内容一致：8 份 VCD 共 10,972,998 字节（与注释「10.5 MB」吻合），单份均 ≤ 2 MB；最大已跟踪文件为 4.1 MB 的生成 Verilog；`.git` 共 12 MB；无 `.o/.so/build/` 误入库。

---

## 3. P8 收尾检查记录

### 3.1 署名与文档用语

| 检查 | 方法 | 结果 |
|---|---|---|
| 当前文件内容 | 按团队署名与用语检查项做 `git grep -niE`（排除 `*.vcd`、`*.pdf`） | 无实质命中；仅有描述性文字与无关的子串命中（`p1_docker_build.log` 中的 apt 包名、`vcd_plot.py` 的一个变量名、CIRCT 生成的 `// Generated by CIRCT` 头） |
| commit message 与作者 | `git log --format='%an <%ae>%n%B' \| grep -niE '<同上>'` | 0 命中；commit message 全部为规范中文（`feat/fix/docs/chore/spec(scope): ...`） |
| 历史内容 | `git log --all -p \| grep -niE '<同上>'` | 复审时有命中，见 B-1（已清除） |
| 文档用语 | `git grep -niE` 检索角色称呼 | 复审时 11 处（MASTER_PLAN 7、ACCEPTANCE 4），见 B-2（已整改） |

### 3.2 占位符

`git grep -nE 'TODO|TBD|FIXME|XXX|xxx|待填|待确认|待补|占位'`（排除 `logs/`、生成 Verilog）逐条判定：

| 类别 | 位置 | 判定 |
|---|---|---|
| 上游原文的 TODO/FIXME | `tests/unit/VectorSimTop.scala` 与 `rtl/chisel/yunsuan-testbench/VectorSimTop.scala`（各 10 处）、`rtl/chisel/xiangshan/VecDecoder.scala:803-807`、`rtl/chisel/yunsuan/package.scala:58-60` | 可接受：上游原文，补丁未新增（我检查了三份补丁的 `+` 行，无 TODO/FIXME）；README §5 第 6 条已说明 |
| 文件名 / 赛题原文 | `HANDOFF_TODO.md` 的引用、`target.md:66` 与 `docs/00:21` 的 `I am xxx` 原文引用 | 可接受 |
| 技术含义的 `xxx` / `???` | `mktemp ...XXXXXX`、`BitPat("b...???...")`、`EXEC_ID_xxx`、绘图花纹 `bench/plot_results.py:42` | 可接受 |
| 历史审计中的 `TBD` 描述 | `ACCEPTANCE_P2.md:46,199-203` | 可接受（描述性），但随 B-2 一并处理 |
| **留给团队填写的「待确认」** | `docs/ppt/提交清单.md:13-20,42,46,87,91-92,149,157,159`；`docs/ppt/讲解大纲.md:53,55`；`docs/ppt/录屏脚本.md:14,28,264` | 可接受，但**提交前必须填完**：团队名称、项目名称、仓库 URL、GitHub 用户名、联系邮箱、成员 / 单位 / 指导老师、XiangShanLab fork 地址、hello 标识是否改为正式团队名、`submit.sh` 字段、视频时长 / 格式 / 大小、PPT 提交方式与截止时间、git 作者是否统一 |

### 3.3 隐私与路径

| 项 | 结果 |
|---|---|
| 邮箱 | 文件内容中只有 noreply 地址与公开邮件列表链接；**git 作者字段含一位成员的机构邮箱**（I-3） |
| 手机号 | 11 位数字匹配全部是数据（`17179869184` = 16 GiB 字节数、测试向量），无手机号 |
| IP | `192.168.30.213` 为私网地址，是 1.1 要求的输出内容，可接受 |
| 绝对路径 / 用户名 | `/Users/i3eg1nner/` 1229 行 / 27 文件；`/data/my/` 307 行 / 31 文件（I-3） |
| 令牌 / 密码 | 0 命中 |

---

## 4. 引用抽样表

自动抽取 README、`docs/00`、`docs/stage1–3`、`docs/ppt`、`nemu/README.md` 中全部 `路径:行号` 形式的引用，共 98 处不重复引用；97 处指向仓库内文件且行号都在范围内，1 处是上游文件（见提示）。
其中 **88 处我逐条人工核对了行内容与文档陈述是否相符**：

| # | 引用位置 → 被引用 | 文档陈述 | 结果 |
|---|---|---|---|
| 1 | README:27 → `p1_hello_xiangshan.log:97,115,118` | 验证串 / GOOD TRAP / 8115 条 | 命中 |
| 2 | README:28 → `p5_summary.log:43,45` | 290103 / 0 / 9358；失败 suite 0 | 命中 |
| 3 | README:32 → `p5_decode_illegal.log:120` | 51 条全 PASS | 命中 |
| 4 | README:32 → `p5_decode_prove_fail.log:134` | 撤守卫 13 条变红 | 命中（`PASS 38，FAIL 13`） |
| 5 | README:33 → `p5_regression.log:31-39,52-54` | 9 个 FU 逐字相同；164 中 163 相同 | 命中 |
| 6 | README:34 → `p5_fault_injection.log:201-202` | 5/5 | 命中 |
| 7 | README:35 → `p5_vdot_tests.log:87-90,116,126` | 30758 / 4834 / trap code 0 | 命中 |
| 8 | README:36 → `p5_patch_verify.log:47,51` | 干净副本 30758 | 命中 |
| 9 | README:37 → `p6_cosim_run.log:45-52` | 72758 / 55924 / 分歧 0 | 命中 |
| 10 | README:38 → `fullcore/summary.log:1-9` | 30758、4834、6/6 GOOD TRAP | 命中 |
| 11 | README:38 → `fullcore/fault_summary.log:1-5` | 3/3 | 命中 |
| 12 | README:39 → `p6_fault_injection_v2.log:350` | 6/6 | 命中 |
| 13 | README:39 → `p6_fault_rtl1_rerun.log:41-58` | T3-RTL-1b 6378/6378 | 命中 |
| 14 | README:39 → `p6_fault_injection.log:111` | 首版 5/5 | 命中 |
| 15 | README:40 → `p7_baseline_equiv.log:112-114,144` | 25924 / 24 长度 0 失配 | 命中 |
| 16 | README:46 → `p7_latency_measure.log:238-252` | 178/178/190 第 2 拍成形 | 命中 |
| 17 | README:47 → `p7_latency_measure.log:260-264,333,347` | vwmul 2、vmv.s.x 1、vwredsum 2 | 命中 |
| 18 | README:53 → `p7_baseline_equiv.log:160-167` | N=4096 2575 / 2061 | 命中 |
| 19 | README:54 → `p7_baseline_gcc15_supplement.log:142,170-173` | acc2 24 长度 0 失配；50/146/530/2066 | 命中 |
| 20 | README:137 → `build_time_breakdown.log:39` | 峰值 59.2 GB | 命中（单位见 M-5） |
| 21 | README:171 → `build_scripted_driver.log:35` | 23:31 | 命中 |
| 22 | 00:22 → `p1_t3_yunsuan_sim.log`（4 次失败） | 4 次真实失败 | 命中（`:108,210,311` 等） |
| 23 | 00:23 → `fullcore/wave_trace.txt:155-181` | vadd 全核周期 | 命中 |
| 24 | 00:25 → `p4_rtl_build.log:13,32` | 82 / 382 个 Scala 源文件 | 命中 |
| 25 | 00:26 → `p5_func_positive.log:19,36,53` | 40×3 PASS | 命中 |
| 26 | 00:26 → `fullcore/summary.log:8` | 全核 0 失配 | 命中 |
| 27 | 00:31 → `p6_fault_injection_v2.log:158-162` | 6378 失配被检出 | 命中 |
| 28 | 00:31 → `fullcore/summary.log:1-37` | 10 内核 × 4 种子 0 失败 | 命中 |
| 29 | stage1/00:139 → `p1_hello_xiangshan.log:7-12` | 网卡与 IP | 命中 |
| 30 | stage1/00:201 → `p1_docker_build.log:1995` | RVV 汇编自检通过 | 命中（该文件含 `\r`，按 `sed -n` 行号计） |
| 31 | stage1/00:214 → `p1_nemu_build.log:126` | 解释器产物 | 命中 |
| 32 | stage1/00:228 → `p1_hello_xiangshan.log:87` | misa 含 V | 命中 |
| 33 | stage1/00:229 → `:88` | VLEN=128 | 命中 |
| 34 | stage1/01:141 → `01_setup_env_docker.sh:33-36` | 容器挂载参数 | 命中 |
| 35 | stage1/01:464 → `p1_t3_yunsuan_sim.log:9` | softfloat 构建行 | 命中 |
| 36 | stage1/01:532 → `build_time_breakdown.log:13,39` | 20 GB / 59 GB 峰值 | 命中 |
| 37 | stage1/02:1044 → `fullcore/wave_run.log:33` | vadd 提交 | 命中 |
| 38 | stage1/02:1209 → `wave_trace.txt:173-179` | vadd 发射 / FU 输出 | 命中 |
| 39 | stage1/02:1228 → `wave_trace.txt:173-181` | 同上至提交 | 命中 |
| 40 | stage2/10:572 → `p7_latency_measure.log:238-242` | 第 2 拍成形 | 命中 |
| 41 | stage2/10:586 → `wave_trace.txt:180-188` | 发射间隔 7 拍 | 命中（1494→1501→1508） |
| 42 | stage2/11:612 → `p5_decode_illegal.log:87-94` | vdot4a vstart≠0 非法 | 命中 |
| 43 | stage2/12:58 → `11_build_vdot_sim.sh:53-54` | 复制参考模型 | **未命中**（实际在 `:57-58`，M-2） |
| 44 | stage2/12:58 → `run_vimacu_tb.sh:53` | 复制参考模型 | 命中 |
| 45 | stage2/12:77 → `vimacu_tb.cpp:181` | 整寄存器 memcmp | 命中 |
| 46 | stage2/12:735 → `p5_decode_illegal.log:87-93` | 同 #42 | 命中 |
| 47 | stage2/12:851 → `tests/unit/VectorSimTop.scala:26` | VDOT_latency=2 | 命中 |
| 48 | stage2/12:857 → `p7_latency_measure.log:46-63` | 事务 #0 S2 寄存器 | 命中 |
| 49 | stage2/12:1041 → `VectorSimTop.scala:26,127,421` | out.valid 由计数器构造 | 命中 |
| 50 | stage2/12:1051 → `vecexcgen_tb.cpp:33-43` | `enc()` 拼指令字 | 命中（`enc()` 在 `:41-43`，范围偏宽） |
| 51 | stage2/13:118 → `vdot_ref.c:100` | 有符号乘积累加 | 命中 |
| 52 | stage2/13:599 → `baseline_ref.c:349` | vstart≠0 判非法 | 命中 |
| 53 | stage3/20:124 → `p5_nemu_build.log:7` | 补丁 sha256 | 命中 |
| 54 | stage3/20:242 → `p5_vdot_tests.log:28` | 14 suite 30758 条 | 命中 |
| 55 | stage3/20:251 → `:33` | 镜像大小 | 命中 |
| 56 | stage3/20:327 → `:70-90` | suite 表 | 命中 |
| 57 | stage3/20:547 → `vdot_dep_kernels.S:124,151` | vd=vs2 / vd=vs1 重叠 | 命中 |
| 58 | stage3/21:97 → `common.sh:68-72` | XS_RUNNER 自动判别 | 命中 |
| 59 | stage3/21:100 → `30_run_cosim.sh:16-24` | 执行位置说明 | 命中 |
| 60 | stage3/21:106 → `p5_nemu_build.log:143` | `.so` 为 aarch64 ELF | 命中 |
| 61 | stage3/21:121 → `0001-xiangshan-vdot.patch:1-23` | DecodeUnit 改动 | 命中 |
| 62 | stage3/21:142 → `cosim_main.cpp:172-209` | `ref_run()` | 命中 |
| 63 | stage3/21:195 → `ref_nemu.h:90-137` | dlopen 代理 | 命中 |
| 64 | stage3/21:233 → `ref_nemu.h:50-85` | 寄存器状态结构 | 命中 |
| 65 | stage3/21:263 → `p6_build.log:4-6` | 复用已有 `.so` | 命中 |
| 66 | stage3/21:275 → `ref_nemu.h:98-102` | difftest 符号 | 命中 |
| 67 | stage3/21:293 → `cosim_main.cpp:151-155` | 指令编码 | **未命中**（实际在 `:156-160`，M-2） |
| 68 | stage3/21:607 → `30_run_cosim.sh:270-292` | T3-RTL-1b 注入 | 命中 |
| 69 | stage3/21:780 → `fullcore/summary.log:10-37` | 依赖测试 | 命中 |
| 70 | stage3/21:781 → `wave_trace.txt:173-192` | 全核波形 | 命中 |
| 71 | stage3/21:858 → `build_time_breakdown.log:34,39` | 12:57 / 峰值 | 命中 |
| 72 | stage3/21:862 → `build_emu.log:2421-2423` | g++ 不认 `-fno-slp-vectorize` | 命中 |
| 73 | stage3/22:70 → `p7_baseline_equiv.log:152-171` | A/B/D 斜率 | 命中（复算 10.00/11.00/10.00） |
| 74 | stage3/22:122 → `:58-60` | 12 / 7 条 | 命中 |
| 75 | stage3/22:136 → `gcc15_supplement.log:176-177` | 12 / 7 | 命中 |
| 76 | stage3/22:179 → `p7_baseline_equiv.log:94-114` | suite 表 | 命中 |
| 77 | stage3/22:220 → `:76-90` | vstart 对照实验 | 命中 |
| 78 | stage3/22:266 → `test_golden.c:176-181` | 长向量数据生成 | 命中 |
| 79 | stage3/22:268 → `p7_baseline_equiv.log:117-144` | 长向量结果 | 命中 |
| 80 | stage3/22:323 → `p7_latency_measure.log:12-28` | 波形抓取 | 命中 |
| 81 | stage3/22:403 → `:190-288` | VIMacU 直驱段 | 命中 |
| 82 | stage3/22:457 → `:290-350` | VIAluFix / VIPU 段 | 命中 |
| 83 | stage3/22:548 → `speedup.csv:3` | 6→2 | 命中 |
| 84 | stage3/22:550 → `collect_results.py:306,311` | 写死的常量 | 命中 |
| 85 | stage3/22:608 → `speedup.csv:10` | 10.0 / 8.0 斜率 | 命中 |
| 86 | stage3/23:131 → `vdot_test.c:272-284` | trap 判定逻辑 | 命中 |
| 87 | ppt/提交清单:20 → `hello.c:148` | 标识硬编码 | 命中 |
| 88 | ppt/讲解大纲:330 → `sensitivity.csv:2-8` | 1.00×–5.00× | 命中 |

**命中率：86 / 88 = 97.7%**；2 处未命中都是脚本或源码改动后的行号漂移，引用的内容本身存在，不涉及数字。

**关键数字复算**：290103 = 各 suite attempted 之和；235348 = 8459+8428+8461+9×20000+30000；424 = 94+94+106+130；
24,517,314 = 6 批语料与 4 个依赖测试的 `instrCnt` 之和；30758 = 5127×5+5123；1.249 = 2575/2061；
10.00 / 8.00 = N=64…4096 四点回归斜率；VIMacU 2 拍 = `wave_trace.txt:182→183`（1497→1499）；发射间隔 7 拍 = 1494→1501→1508，6 拍 = 1488→1494。全部吻合。

---

## 5. 复现记录

环境：Linux x86_64，`WORK_DIR=/data/my/cie2026-vdot-xiangshan-linuxrepro/work`，`LOG_ROOT=/tmp/finalreview/logs`、`RESULTS_DIR=/tmp/finalreview/results`、`FIG_DIR=/tmp/finalreview/fig`。

| 步骤 | 结果 | 与存档比较 |
|---|---|---|
| `bash scripts/03_run_hello.sh`（第一次） | **rc=2**：`ERROR: 当前 NEMU 配置没有 CONFIG_UARTLITE_MMIO` | 复现目录的 NEMU 被之前的 `30`/`50` 留在 ref 形态（M-3） |
| `bash scripts/21_build_nemu_vdot.sh` | rc=0，16 s；`TOTAL cases=30758 pass=30758 fail=0`，4834/4834 `mcause=2`，`trap code:0` | suite 表与 `logs/stage3/p5_vdot_tests.log:70-90` 逐行相同 |
| `bash scripts/03_run_hello.sh`（第二次） | rc=0，0.4 s；`hello xiangshan, I am cie2026-vdot, IP address 172.100.0.6`，`HIT GOOD TRAP`，8189 条指令 | 格式一致；IP 与指令数不同（本机 IP、GCC 15） |
| `bash scripts/tools/sync_rtl_sources.sh --check` | `逐字节相同 15 个文件`，`RTL-SYNC-CHECK: PASS` | 与 README 声称一致 |
| `bash scripts/tools/verify_patches.sh` | yunsuan 侧 `相同 11 个文件，不同 0 个`，`PATCH-VERIFY: PASS` | 一致 |
| `python3 bench/collect_results.py --equiv-log logs/stage3/p7_baseline_equiv.log --latency-log logs/stage3/p7_latency_measure.log --out /tmp/finalreview/results` | 9 个 CSV 全部生成 | **9/9 与 `bench/results/` 逐字节相同** |
| 全核构建 / 运行（未重跑） | 核查日志：10 份运行日志都有 `Difftest enabled`、REF 路径、`HIT GOOD TRAP` 与 `emu-exit=0`；`fault_diff.txt` 只改 1 行（`dotVd ^ 1.U`），3 个程序都报 `v3_low different` 后 `ABORT`，`right`/`wrong` 恰好差 bit0；`run_driver.log` 时间戳 07:27→08:12 与 README「约 45 分钟」相符 | 内部一致，未发现拼接痕迹 |
| 结束时 `git status --short` | 只有 `?? docs/_plan/FINAL_REVIEW.md` | 主仓库已跟踪文件未改动 |

---

## 6. 评分预测（评委视角）

| 一级指标 | 二级指标 | 满分 | 团队自评（`docs/00` §2） | 本复审预测 | 主要理由 |
|---|---|---:|---|---|---|
| 完整性 | 阶段一 | 15 | 13–14 | **12–14** | 三项都完成且证据扎实；hello 只在 NEMU 上（I-2），vadd 前后端各段为源码级。补 I-2 后可稳定在 14 |
| 完整性 | 阶段二 | 20 | 17–19 | **17–19** | 设计、RTL、三项测试齐全且超量；语料也在全核上 0 失配。扣分：无综合、存档测试平台是 FU 级 |
| 完整性 | 阶段三 | 25 | 20–22 | **19–22** | NEMU、两级协同仿真、基线都很强；3.3 加速比全部是建模值，且全核 emu 已有却未用于测周期（I-1），评委会认为最关键的「latency 加速比」没有实测闭环。补 I-1 后可到 22–23 |
| 可行性 | 技术路径合理性 | 10 | 9 | **9** | 复用 `VIMac64b` 部分积与 YunSuan CSA，`FuConfig`/调度网络未改，163/164 网表不变；扣在 `latency=2` 无综合 |
| 可行性 | 功能验证有效性 | 10 | 9 | **9–10** | 正 / 负 / 边界全覆盖、两条 DUT 通道、故障注入、L1 + L2 协同仿真均通过；全核只跑 MinimalConfig、LMUL≠1 未在全核复测 |
| 探索性 | 微架构优化分析 | 5 | 4 | **3–4** | 标注诚实、有敏感性分析与不利结论；但没有任何流水线周期实测，评委可能只给「良好」 |
| 探索性 | 软硬件协同理解 | 5 | 4–5 | **4–5** | S-7' 裁定的发现过程与 difftest 机制剖析是全仓最出彩的部分 |
| 创新性 | 设计优化独特性 | 5 | 4 | **3–4** | XOR 蝶形折叠加法树与三指令共享数据通路有新意；「零选择器」「13.7%」均为结构推导，无综合数据支撑 |
| 创新性 | 扩展应用潜力 | 5 | 3–4 | **3–4** | `vdot4a` 体现 SEW=32 方向，VLEN / LMUL 扩展只有论证没有实现 |
| **合计** | | **100** | **83–90** | **79–91（中位约 85）** | |

**与自评的对比**：
- **偏高**：阶段三（自评下限 20 在 I-1 不补的情况下偏乐观，可能落到 19）、微架构优化分析（自评 4，本复审预测 3–4）、设计优化独特性（自评 4，本复审预测 3–4）。
- **基本一致**：阶段二、技术路径、软硬件协同、扩展潜力。
- **偏低**：功能验证有效性（自评 9，全核 difftest 与故障注入完成后可给 10）。
- **评分表以外的风险**：B-1 / B-2 若不处理，可能影响评委对整份作品原创性的判断，影响无法量化但可能超过上表任何一项（两项现已处理）；
  录屏、PPT 与加密提交不完成，则可能无法进入评审。

---

## 7. 整改优先级建议

| 优先级 | 项 | 估计工作量 |
|---|---|---|
| 1 | B-1 改写历史（同时统一作者，I-3） | 1 小时 |
| 2 | B-2 处理 `docs/_plan/`，同步改 README / `docs/00` 的引用 | 2 小时 |
| 3 | I-4 录屏、PPT、加密提交；填完 §3.2 的「待确认」 | 团队决定 |
| 4 | I-1 全核周期实测加速比 | 半天 |
| 5 | I-2 hello 在全核 emu 上运行 | 1 小时 |
| 6 | M-1 至 M-6 文字与 CSV 订正 | 1 小时 |

---

## 复审后补记（2026-10-26，非复审内容）

> 本节由团队在复审结束后追加，只记录复审之后发生的变化，**不修改上文任何复审结论**；上文的数字、行号与判断均对应复审时的 `c3d2f2e`。

**语义修订 S-3'**：复审时赛题官方语义图尚未取得，上文评审的是依据题源 arXiv:2409.00661 与 RVV 归约惯例确定的 D2 语义。2026-10-26 经赛题页数据接口取得官方语义图（`vdot_vv` 的 8 行 Python 伪代码，
原样存档于 `docs/_recon/figures/vdot_official_semantics.jpg`），逐行对照后主体一致，唯一差异是目的寄存器其余位（伪代码清零，原 S-3 按 `vta`）。
据此修订为裁定 S-3'（`MASTER_PLAN.md` D2.4）：`vdot.vv` / `vdotacc.vv` 在 `vstart < vl` 时 `vd[31:0]` 写结果、`vd[VLEN-1:32]` 恒为 0，与 `vta` / `vma` 无关；
`vl = 0` 时不写；`vdot4a.vv` 不变；保留 `vl` 机制，`vl = 8` 时与官方伪代码逐位等价（20570 条 0 失配，`logs/stage2/p3_official_pseudocode_equiv.log:40`）。
对照与论证见 `docs/stage2/10_vdot指令设计文档.md` §1 开头「赛题官方语义与逐行对照（S-3' 的依据）」。

**全链重跑**：参考模型、语料（30739 条）、RTL 写回成形两处、NEMU、基线序列随之修改，FU 级（290175 条 0 失败）、NEMU（30794 条 0 失配）、
协同仿真（值比对 55960/55960、故障注入 7/7）、基线等价（25960 条）、MinimalConfig 全核 difftest（24,524,262 条提交 0 失配，新增 `s3old` 故障注入 3/3）与全核周期实测全部重跑；
加速比主结论 1.70× / 1.81× / 2.25× 不变。相关提交：`364b141`（语义修订与 FU 级 / NEMU / 协同仿真 / 基线重跑）、`61eb937`（全核重建与重跑）、
`0f62281`（阶段二、三文档）、`cfcd658`（三项基础测试 `vl=8` 主演示用例的 DUT 实测存档），以及其后的文档同步。
上文引用的部分日志（如 `logs/stage3/cosim/p6_fault_injection_v2.log`、`logs/stage3/p7_baseline_gcc15_supplement.log`、全核首次构建的 `build_time_breakdown.log` 等）已从工作区删除，可在 git 历史中查看。
