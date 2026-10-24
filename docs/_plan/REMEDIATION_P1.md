# P1 验收问题整改报告

| 项 | 值 |
|---|---|
| 整改依据 | `docs/_plan/ACCEPTANCE_P1.md`（独立验收报告，4 项重要 + 11 项次要） |
| 整改时间 | 2026-10-24 |
| 整改范围 | `docs/stage1/00~03`、`docs/_plan/MASTER_PLAN.md`、`scripts/00~02`、`tests/riscv/hello/` |
| 未改动 | `logs/stage1/**`（证据，只改引用它的文档）、`docs/_plan/ACCEPTANCE_P1.md`（验收记录）、`work/XiangShan-vdot`、`work/XiangShan-cosim`、`work/NEMU`（他人在制工作区；`work/XiangShan-kmhv2` 仅只读访问） |
| 核验原则 | 每条改后的 `文件:行号` 都用 `sed -n '<n>p'` 实际打开过；每个波形数字都用 `scripts/tools/vcd_extract.py` 现场重跑取得 |

---

## 一、重要级（4 项）

| # | 位置（改后） | 做了什么 | 如何核验 |
|---|---|---|---|
| **P-01** | `docs/stage1/01_环境部署报告.md:435-443`（§5.3） | 删除"**现象**：`p1_nemu_build.log:150` 显示 `SPECIALIZE_TYPE=RISCV … Linux-x86_64-GCC`"这段**不存在的日志引用**，整节改写为**纯源码论证**：① 开头显式声明本节不引用构建日志，并说明原因（本次构建时 `softfloat.a` 已存在，make 跳过了该目标，所以日志里没有 softfloat 输出）；② 引 `work/NEMU/scripts/softfloat.mk:10`（目录名写死）、`:17`（`SPECIALIZE_TYPE = RISCV`）、`:29`（配方行）、`:1`（`ifdef CONFIG_FPU_SOFT`）；③ 引 `configs/riscv64-xs-kmhv2_defconfig:228` / `-ref_defconfig:205`（并注明行号以 `git show HEAD:` 的基线版本为准，避免被 P5 在制改动带偏）；④ 另加一条**真实存在**的旁证 `logs/stage1/p1_t3_yunsuan_sim.log:9`，并明确标注"这是 yunsuan 仓库的 softfloat，不是 NEMU 的"。技术结论（不是问题、无需修改）原样保留，未削弱 | `grep -i softfloat logs/stage1/p1_nemu_build.log` → **0 命中**（确认旧引用确为伪证据）；`sed -n '1p;10p;17p;29p' work/NEMU/scripts/softfloat.mk` → 四行逐字命中；`git -C work/NEMU show HEAD:configs/riscv64-xs-kmhv2_defconfig \| grep -n FPU_SOFT` → `228:CONFIG_FPU_SOFT=y`，ref 版 → `205`；`sed -n '9p' logs/stage1/p1_t3_yunsuan_sim.log` → 确为 `SPECIALIZE_TYPE=RISCV … /yunsuan/resource/softfloat/repo/build/Linux-x86_64-GCC all` |
| **P-02** | `docs/stage1/03_仿真平台搭建报告.md:292,294,300-311`（§4.3）与 `:449-569`（§6.4 整节重写） | **用现场重跑 `vcd_extract.py` 的真实输出重写，而不是抄 `02` 号文档。**<br>· §4.3 延迟表：fuType=3 由"实测 1 个时钟"改为"实测 **0 个时钟**，8/8 笔"；fuType=5 由"实测 2 个时钟"改为"实测 **1 个时钟**，8/8 笔"；并在表下贴出两条取数命令，注明同一组数字见 `02` §5.3/§5.5/§8.2。<br>· §6.4 整节重写为三小节：**(1)** fuType=3 —— 贴 8 笔完整事务表 + 事务 #0 明细，时刻由"#23→#25（1 个时钟后）"改为真实的 **`in.fire @#21` → `out.valid @#21`，0 周期**；补上"事务 #1 与 #0 激励完全相同、第一笔 e16 事务是 **#2**（`#29`，`vl=17`）"的如实说明（原文误称"第二笔事务 sew=e16"）。**(2)** 贴 `--sew-crosscheck` 的**完整 8 行**，指出 #2/#6 是唯一全中 e16 的两笔。**(3)** fuType=5 —— 贴 8 笔事务表；原文称"第一笔事务（时刻 #25）"的那组数据实际是**第 2 笔**，改为 **事务 #1，`in.fire @#27` → `out.valid @#29`，1 周期**；原文"第二笔事务（e16, vl=2）"改为 **事务 #2，`@#33` → `@#35`**。<br>· 节首列出三条可复现命令并说明时刻换算约定（`周期数 = (t_out − t_fire)/2`），节尾加一条"本节与 `02` 讲的是同一批 VCD，重抓波形时两份文档须同步重生成"。<br>· 顺带把"各含 11543 / 更多个信号、724+ 个 scope"改为实测的"各含 **11543 个 `$var`、724 个 `$scope`**（两份相同）" | 现场执行三条命令取数（输出原样粘贴，未改写）：<br>`python3 scripts/tools/vcd_extract.py --vcd logs/stage1/waveform/vadd_vintadder_fuType3_seed1.vcd --transactions` → 8 笔 `cyc` 列**全 0**，`t_fire`/`t_out` = 21/21, 25/25, 29/29, 33/33, 37/37, 41/41, 45/45, 49/49<br>`… --vcd logs/stage1/waveform/vaddvv_vialufwrapper_fuType5_seed2.vcd --transactions` → 8 笔 `cyc` 列**全 1**，`t_fire→t_out` = 21→23, 27→29, 33→35, 39→41, 45→47, 51→53, 57→59, 63→65<br>`… --vcd <fuType3> --sew-crosscheck` → 8 行，与粘贴内容逐格相同<br>算术复核：`0x000041a710d63af1 + 0x4431b7821c06dac8 = 0x4431f9292cdd15b9`、`0x60b7acd93ab50c2a + 0x06058ed856e509fe = 0x66bd3bb1919a1628`（python 实算）<br>一致性复核：与 `02` §5.3 / §5.5 / §8.2 的表逐格比对，两份文档现已完全一致**且**都等于 VCD 实测 |
| **P-03** | `scripts/00_setup_env_host.sh:13-16,27-42,131-209`；`docs/_plan/MASTER_PLAN.md:90-91`；`docs/stage1/00_环境版本锁定.md:102-112,228-246` | **让"从零复现"真的从零开始。** 把步骤 5 从"打印一行建议后以 0 退出"改成真正的克隆与校验：<br>· 在脚本头部固化锁定版本：`XS_PIN=a4eeaabb4c12349259094a8b55f3ba1c03a9d993`（分支 `kunminghu-v2`）、`NEMU_PIN=90908390002fb7da885e5d880bba3bef2a225b2a`，可用 `XS_REF=`/`NEMU_REF=` 覆盖。<br>· `XS_SUBMODULES` 取自 `git -C work/XiangShan-kmhv2 submodule status` 的**完整 11 项**：`ChiselAIA ChiselIOPMP coupledL2 difftest fudian huancun openLLC ready-to-run rocket-chip utility yunsuan`（原建议只列了 5 项，缺 6 项）；统一用 `submodule update --init --recursive`，并对 rocket-chip 的 `cde`/`hardfloat`/`torture` 三个嵌套子模块单独兜底（即便 rocket-chip 本体早已存在）——这正是 `03` §7.1 实测踩过的坑。<br>· **幂等**：已存在的仓库/子模块只做只读校验后跳过；commit 与锁定值不符时只告警并给出"另起干净检出"的命令，**绝不改动已有工作区**（`work/NEMU`、`work/XiangShan-kmhv2` 正被他人使用）。<br>· **失败真的失败**：clone 失败 `die`；检出锁定 commit 失败时先 `rm -rf` 半成品再 `die`（否则重跑会把半成品当成"已存在"而静默放过）；`SKIP_CLONE=1` 时仓库/子模块缺失一律 `die`，不再出现"打印建议后 exit 0"；末尾用 `[ -f yunsuan/build.sc ]` 做最终校验。全程保留 `set -euo pipefail`。<br>· 同步更新 `MASTER_PLAN.md:90` 的交付物名（`scripts/00_setup_env.sh` → 实际的 `00_setup_env_host.sh` + `01_setup_env_docker.sh`），以及 `00_环境版本锁定.md` 两处"复现入口"（补上第 0 步与 `source scripts/env_host.sh`） | **实际跑过的测试**（不重新下载任何上游仓库）：<br>① `bash -n` 语法检查通过；本机是 bash 3.2.57，数组/`${#arr[@]}` 写法已验证兼容。<br>② **全部就位**：对真实的 `work/XiangShan-kmhv2` + `work/NEMU` 跑步骤 5 → 两个仓库"commit 匹配锁定版本，跳过"，11 个子模块逐个"已检出，跳过"，`EXIT=0`，**无任何网络访问**；跑完 `git -C work/XiangShan-kmhv2 status --short` 与跑前一致（仅既有的 ` m yunsuan`，来自 `test_driver.cpp` 的既有 patch），确认未动他人工作区。<br>③ **缺仓库 + `SKIP_CLONE=1`** → XiangShan 缺失 `EXIT=1`、NEMU 缺失 `EXIT=1`（都带明确报错）。<br>④ **commit 不匹配**（`XS_REF=000…0`）→ 打印告警 + 另起检出的命令，`EXIT=0`，不改工作区。<br>⑤ **缺子模块 + `SKIP_CLONE=1`** → 用 `/tmp` 下的假仓库触发，`EXIT=1` 并列出全部缺失项。<br>⑥ **真实 clone 路径**：在 `/tmp` 造了一套本地 git fixture（分支 `kunminghu-v2` + `yunsuan` 子模块 + `rocket-chip` 子模块 + `cde/hardfloat/torture` 三个嵌套子模块），用 `file://` 当上游跑完整流程 → clone、按 pin 检出、`--recursive` 拉齐嵌套子模块、`yunsuan/build.sc` 校验全部成功，`EXIT=0`；对同一目录重跑 → 全部"跳过"，`EXIT=0`（幂等）；删掉 `rocket-chip/cde` 后重跑 → 嵌套兜底分支正确触发并补回。<br>⑦ **坏 pin**：clone 成功但 `checkout` 失败 → 报错、`EXIT=1`、半成品目录已被删除（`dir exists? NO`）。<br>**只做了推理、未实测的部分**：在真正干净的机器上从 GitHub 拉取 XiangShan（约 GB 级）与 NEMU 的端到端耗时与网络失败行为；`submodule update --init --recursive` 对这 11 个真实子模块的实际下载量。克隆逻辑本身已用本地 fixture 等价验证，未验证的只是"对 github.com 的真实网络往返" |
| **P-04** | `docs/stage1/01_环境部署报告.md:196-212`（§3.4）、`docs/stage1/00_环境版本锁定.md:201-213`（§N6）；另加 `scripts/02_build_nemu.sh:94-100` | **把"零 patch"的论据从瞬时工作区状态改成对 patch 的断言。**<br>· `01` §3.4：删除"`git -C work/NEMU status --short` 为空"这一已失效的复核方式，改为——阶段一 patch 数为零，基线 commit `9090839`；**复核方法**是 `ls nemu/patch/`（只有 `0001-add-vdot-instruction-family.patch`，属阶段三，`nemu/README.md` 已写明目标 commit 同为 `9090839`）＋ `git -C work/NEMU rev-parse HEAD`；并加显式警告：**不要**用 `status --short` 复核，`work/NEMU` 是共享工作区，阶段三起会带 vdot 在制改动（7 个 `M` + 新增 `vdot.c`），要重建阶段一环境请从 `9090839` 另起干净检出或先 `git stash`。<br>· `00` §N6：表头"体积"改为"体积（阶段一基线）"，表上方加一句基线与零 patch 说明并交叉引用 `nemu/patch/`；表下加注说明这两个数字是**归档日志的观测值**（出处 `p1_nemu_build.log:126` 与 `:228`，另见 `:340-341`），**不是**对当前盘上文件的断言，阶段三重建后会变大，复现方法是在 `9090839` 干净检出上重跑 `02_build_nemu.sh`。<br>· 采纳验收方的附加建议：在 `02_build_nemu.sh` **末尾**追加"工作区状态快照"（`git rev-parse HEAD` + `git status --short`），让今后每份构建日志自带状态快照。**刻意放在末尾**，是为了不移动 `p1_nemu_build.log` 中已被文档引用的 `:126` / `:228` / `:231` / `:340-341` 等行号 | `ls nemu/patch/` → 仅 `0001-add-vdot-instruction-family.patch`；`head -30 nemu/README.md` → 目标 commit `9090839`、对应阶段三 P5；`git -C work/NEMU rev-parse HEAD` → `90908390002fb7da885e5d880bba3bef2a225b2a`（HEAD 未被改写，原主张成立）；`sed -n '126p;228p;340,341p' logs/stage1/p1_nemu_build.log` → `589080` / `1570888` 两个 `ls -l` 行确在该处（原文把 `-so` 的出处记成 `:229`，实为 `file` 输出行，一并改正为 `:228`）；`bash -n scripts/02_build_nemu.sh` 通过，追加块位于最后一个 `ls -l` 之后、`DONE` 之前 |

---

## 二、次要级（11 项，全部已修）

| # | 位置（改后） | 做了什么 | 如何核验 |
|---|---|---|---|
| P-05 | `docs/stage1/00_环境版本锁定.md:224,225,226` | `misa` 的日志行号 `:78`→**`:87`**；`vlenb` `:79`→**`:88`**；`marchid`/`mvendorid` "第 75-76 行"→**"第 84-85 行"**，并补注 `:84` = `mvendorid`、`:85` = `marchid` | `sed -n '84p;85p;87p;88p' logs/stage1/p1_hello_xiangshan.log` → 四行分别为 `mvendorid : 0x0000086f`、`marchid : 0x00000019`、`misa : 0x80000000003411af`、`vlenb : 16 byte` |
| P-06 | `docs/stage1/01_环境部署报告.md:14,15,16`，并在表下新增 `:19` | `p1_nemu_build.log` 341→**342**；`p1_hello_xiangshan.log` 124→**125**；`p1_hello_config_guard.log` 24→**27**；新增一句"行数由 `wc -l logs/stage1/*.log` 生成，可直接复核" | `wc -l logs/stage1/*.log` → 342 / 125 / 27；`p1_docker_build.log` 2013、`p1_fullcore_feasibility.log` 290 原本就对，未动 |
| P-07 | `docs/stage1/01_环境部署报告.md:113` | `-lz` 的出处 `NEMU/Makefile:115`→**`:116`** | `sed -n '115,116p' work/NEMU/Makefile` → `:115` 是 `endif`，`:116` 是 `LDFLAGS += -lz` |
| P-08 | `docs/stage1/01_环境部署报告.md:518` | 补上仓库名：`release.yml:175,189` → **`work/XiangShan(kunminghu-v3)/.github/workflows/release.yml:175,189`**，并补一句"v2 分支的 `release.yml` 只有 93 行、不含该步骤，此处引 v3 作为官方资源需求的旁证"，日志出处写为 `p1_fullcore_feasibility.log:193-195`（grep 命令行 + 两行输出） | `sed -n '175p;189p' work/XiangShan/.github/workflows/release.yml` → `sudo fallocate -l 32G /mnt/xs-swapfile` / `… JVM_XMX=10g`（数值无误）；`wc -l work/XiangShan-kmhv2/.github/workflows/release.yml` → 93；`grep -c fallocate` 该文件 → 0；`sed -n '193,195p' logs/stage1/p1_fullcore_feasibility.log` → grep 命令及其两行输出 |
| P-09 | `docs/stage1/03_仿真平台搭建报告.md:300-301` | `finish_fixLatency` 的出处 `VectorSimTop.scala:378`→**`:122`**（判定表达式），并补注使用处在 **`:384`** | `sed -n '122p;384p' work/XiangShan-kmhv2/yunsuan/src/test/scala/top/VectorSimTop.scala` → `val finish_fixLatency = busy && (counter >= latency)` / `io.out.valid := Mux(is_uncertain, finish_uncertain, finish_fixLatency)` |
| P-10 | `docs/stage1/03_仿真平台搭建报告.md:266` | `vs1 = Mux(needReverse, …)` 的出处 `VIAluFWrapper.scala:66-67`→**`:63-64`**，并注明 `:66-67` 是其后的 `vIntFixpAlu.io.in.vs1/vs2 :=` 赋值 | `sed -n '63,64p;66,67p' …/VIAluFWrapper.scala` → `:63-64` 为两行 `Mux`，`:66-67` 为两行 `:=` 赋值 |
| P-11 | `tests/riscv/hello/start.S:25` | 注释里 `mstatus.FS/VS` 复位清零的出处 `init.c:69-70`→**`:72-73`**（与 `01` §4.2 一致） | `sed -n '72,73p' work/NEMU/src/isa/riscv64/init.c` → `mstatus->fs = 0;` / `mstatus->vs = 0;`（`:69-70` 确为注释行） |
| P-12 | `tests/riscv/hello/hello.c:16` 与 `:32` | 寄存器布局 `uartlite.c:18-21`→**`:20-23`**；`putc` 转发 `uartlite.c:120-124`→**`:126-129`**（与 `01` §4.1 一致） | `sed -n '20,23p' work/NEMU/src/device/uartlite.c` → RX/TX/STAT/CTRL 四个 `#define`；`sed -n '126,129p'` → `case UARTLITE_TX_FIFO:` … `putc(serial_base[UARTLITE_TX_FIFO], stderr);` |
| P-13 | `docs/stage1/02_向量加法指令执行过程分析.md:525`（另 `:518-519`） | §5.4 握手时间线表 `#20` 行的 `in_vinfo_vl` 由 `01` 改回原始值 **`00`**；同时把表头标注为"**节选**：只摘 #18–#29，并略去 `has_issued`/`in_vinfo_ma`/`in_vinfo_ta` 三列，完整 #18–#38 全列表见 trace 文件原文"，消除"逐字引自 trace"的误导 | `sed -n '685,705p' logs/stage1/waveform/vadd_signal_trace.txt`（§8 原表）→ `#20` 行 `in_vinfo_vl = 00`，`01` 到 `#21` 锁存后才出现 |
| P-14 | `docs/stage1/02_向量加法指令执行过程分析.md:713-728` | §5.7 的 `--sew-crosscheck` 表由 5 行补成**完整 8 行**（补回被静默删掉的 #1/#4/#5），并加一句"上表为命令的完整 8 行输出，未作删节；原始输出另存于 `vadd_signal_trace.txt` 第 3/6 节；事务 #1 的激励与 #0 相同故两行数值一致" | 现场重跑 `vcd_extract.py --sew-crosscheck` → 8 行，与补齐后的表逐格相同；`sed -n '173,195p' logs/stage1/waveform/vadd_signal_trace.txt` → 第 3 节确为同一张 8 行表 |
| P-15 | `scripts/01_setup_env_docker.sh:27-33` | 把与代码矛盾的注释"宿主 UID/GID 透传，避免产生 root 所属文件"改为如实描述：此处**没有**传 `--user`；macOS/Docker Desktop 下由 virtiofs 做属主映射（实测产物属主正常，但容器内 `ls -l` 仍显示 root，见 `p1_nemu_build.log:126`）；**Linux 宿主需自行加 `--user "$(id -u):$(id -g)"`**，并提示容器内 `HOME` 与 git `safe.directory` 两个副作用 | `sed -n '126p' logs/stage1/p1_nemu_build.log` → `-rwxr-xr-x 1 root root 589080 …`（旁证成立）；`bash -n scripts/01_setup_env_docker.sh` 通过；确认脚本两个 `docker run` 均无 `--user`（未改行为，只改注释） |

---

## 三、未修改的项及理由

| 事项 | 决定 | 理由 |
|---|---|---|
| 验收报告 §一·1 提到的 `01_setup_env_docker.sh build`（约 18 min）与 `10_build_yunsuan_sim.sh` 未被验收方重跑 | **不重跑** | 重跑 `docker build` 会覆盖 `logs/stage1/p1_docker_build.log`（2013 行交付证据）；`10_build_yunsuan_sim.sh` 必须在 `work/XiangShan-kmhv2/yunsuan` 内构建，与其他工程师的在制工作冲突。两者都不是验收指出的缺陷，重跑只会破坏证据 |
| 验收报告 §五·5 的"在 ≥64 GiB x86_64 Linux 机器上抓一段全核波形" | **不做** | 这是加分项而非缺陷；本机不具备条件，`01` §6.2 与 `02` §10.2 已如实写明"未执行"及原因，符合执行纪律第 1 条。无条件执行而伪造结果是红线 |
| `work/NEMU` 当前的 7 个 `M` + 1 个 `??` | **不清理** | P5 工程师的在制工作区，任务约束明确禁止改动。P-04 的修法是让文档不再依赖该工作区的瞬时状态，而非去改动它 |
| `logs/stage1/**` 任何一行 | **不改** | 日志是证据。所有行号/行数偏差一律通过改文档解决（P-05/P-06/P-08/P-13/P-14 均如此） |
| `02` 号文档的其余波形论断 | **不改** | 验收方用自写的第二套 VCD 解析器逐项复算，"一处不差"；本次整改只在 `:518-519` / `:525` / `:713-728` 三处加节选标注与补齐表格，未触碰任何结论 |
| `docs/_plan/ACCEPTANCE_P1.md` | **不改** | 验收记录，任务约束明确禁止改动 |

---

## 四、整改后的自检命令（可一次性复核本文件的全部主张）

```bash
# P-02：两份 VCD 的真实事务表与交叉验证（03 §6.4 / §4.3 与 02 §5.3/§5.5/§8.2 必须三方一致）
python3 scripts/tools/vcd_extract.py --vcd logs/stage1/waveform/vadd_vintadder_fuType3_seed1.vcd     --transactions
python3 scripts/tools/vcd_extract.py --vcd logs/stage1/waveform/vaddvv_vialufwrapper_fuType5_seed2.vcd --transactions
python3 scripts/tools/vcd_extract.py --vcd logs/stage1/waveform/vadd_vintadder_fuType3_seed1.vcd     --sew-crosscheck

# P-01：确认 01 §5.3 不再引用不存在的日志行
grep -i softfloat logs/stage1/p1_nemu_build.log        # 应为 0 命中
grep -rn 'p1_nemu_build.log:150' docs/                 # 应为 0 命中
sed -n '1p;10p;17p;29p' work/NEMU/scripts/softfloat.mk

# P-03：幂等性与失败行为（不会重新下载已有仓库）
bash -n scripts/00_setup_env_host.sh
SKIP_CLONE=1 bash scripts/00_setup_env_host.sh         # 全部就位时应一路"跳过"

# P-04：零 patch 的新复核方式
ls nemu/patch/ ; git -C work/NEMU rev-parse HEAD
sed -n '126p;228p' logs/stage1/p1_nemu_build.log

# P-05~P-12：被修正的 文件:行号
sed -n '84p;85p;87p;88p' logs/stage1/p1_hello_xiangshan.log
wc -l logs/stage1/*.log
sed -n '116p' work/NEMU/Makefile
sed -n '175p;189p' work/XiangShan/.github/workflows/release.yml
sed -n '122p;384p' work/XiangShan-kmhv2/yunsuan/src/test/scala/top/VectorSimTop.scala
sed -n '63,64p'   work/XiangShan-kmhv2/yunsuan/src/main/scala/yunsuan/vector/VectorALU/VIAluFWrapper.scala
sed -n '72,73p'   work/NEMU/src/isa/riscv64/init.c
sed -n '20,23p;126,129p' work/NEMU/src/device/uartlite.c

# P-13/P-14：与 trace 文件原文逐字比对
sed -n '173,195p;685,705p' logs/stage1/waveform/vadd_signal_trace.txt
```
