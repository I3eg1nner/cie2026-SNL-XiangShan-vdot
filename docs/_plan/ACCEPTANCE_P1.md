# P1 环境部署与验证 —— 独立验收报告

| 项 | 值 |
|---|---|
| 验收对象 | `docs/stage1/00~03`、`scripts/00~03`、`scripts/10`、`scripts/tools/vcd_extract.py`、`logs/stage1/**`、`tests/riscv/hello/` |
| 验收依据 | `docs/_plan/MASTER_PLAN.md` §P1 六条验收标准 + §2 执行纪律 |
| 验收方式 | 实跑脚本、独立重解析 VCD（自写第二套解析器交叉验证）、逐条打开被引用的 `文件:行号`、全仓检索 |
| 验收时间 | 2026-10-24 |
| 验收人立场 | 独立第三方，未参与任何交付物的编写；目标是**证伪** |
| 约束 | `work/` 视为只读，未在其中执行任何构建（其他工程师正在使用） |

---

## 一、六条验收标准逐条判定

| # | 验收标准 | 判定 | 我亲自取得的证据 |
|---|---|---|---|
| 1 | 脚本可从零复现，验收方独立执行成功 | **部分通过** | `./scripts/03_run_hello.sh` 我实跑成功（exit 0，耗时约 60 s），产出与归档日志**逐行一致**（仅时间戳 / NEMU build time / host time / pmem 地址 4 处差异，见 §四）。但：① 没有任何脚本会 clone 上游仓库，`00_setup_env_host.sh` 只在仓库缺失时**打印** clone 命令就继续走完，真正"从零"仍需人工三步 clone（XiangShan-kmhv2 + 11 个子模块、NEMU、xs-env）；② `01_setup_env_docker.sh build`（18 min）与 `10_build_yunsuan_sim.sh`（需在 `work/` 内构建）受审计约束未重跑，**此两条无法验证**。脚本本身质量良好：四个脚本全部 `set -euo pipefail`，路径由 `BASH_SOURCE` 推导无硬编码，IP 自动探测且可 `HOST_IP=` 覆盖，无交互式提示，幂等检查到位（brew 包、mill 启动器、espresso、test_driver patch、forkEnv 缓存、trace 模式标记均有"已存在则跳过"分支） |
| 2 | 日志为真实终端输出（含时间戳、命令、真实报错与修复），非编造 | **部分通过** | 17726 行日志我抽查了 9 个文件的 40 余处引用行，**全部为真实输出**：`p1_t3_yunsuan_sim.log` 含 4 次真实失败（espresso exit 126 ×2、mill forkEnv 缓存、chiseltest 11 个用例全败）与修复过程；`p1_fullcore_feasibility.log` 含真实 `docker manifest` / `uname -m` / 计时输出；`p1_hello_config_guard.log` 是一次真实被 `make` 拦截的失败（exit 2）。**但发现 1 处伪造级缺陷**：`01_环境部署报告.md:415` 把一段 `SPECIALIZE_TYPE=RISCV ... Linux-x86_64-GCC` 的输出标注为"`p1_nemu_build.log:150` 显示"，而我 `grep -i softfloat logs/stage1/p1_nemu_build.log` **零命中**、`grep -rn Linux-x86_64 logs/` 唯一命中是 `p1_t3_yunsuan_sim.log:9`（**另一位工程师的 yunsuan 构建日志**）。这是把 A 日志的输出冒充 B 日志的观察，违反执行纪律第 1 条 |
| 3 | hello 信息确由仿真器实际执行 RISC-V 程序产生，附日志行号证据 | **PASS** | 证据链完整且我**独立重跑复现**：`readelf -h` → `Machine: RISC-V` / `Entry 0x80000000`（:42-43）；`strings -t x build/hello.bin` 在偏移 `0xbd0` 命中整串（:46）；反汇编 `lui a3,0x40600` + `c.addi a3,4 # 40600004` + `sb a4,0(a3)`（:48-57）即 UARTLITE TX FIFO 的字节写；RVV 自检段 `vle8.v/vadd.vv/vse8.v` 真实存在（:60-67）；`HIT GOOD TRAP at pc=0x80000038`、`trap code:0`、`total guest instructions = 8115`（:114-118）。横幅里的 `misa=0x80000000003411af`、`vlenb=16`、`marchid=0x19`、`mvendorid=0x86f` 全部来自 `csrr`，与 `NEMU/src/isa/riscv64/init.c:193,233-235` 逐项吻合，宿主 shell 无从伪造。**加强证据**：我重跑时 `work/NEMU` 的二进制已被 P5 工程师重建过（文件时间 19:56 > 原日志 18:42，且已打 vdot patch），**换了一个二进制仍输出完全相同的 8115 条指令与同一行横幅**，这比原始日志更能排除"回放录像"的可能 |
| 4 | 波形文件真实存在且可打开；分析文档中每个结论都能在波形上找到对应信号与时刻 | **部分通过** | 两份 VCD 真实、可解析（11543 个 `$var` / 724 个 `$scope`，timescale 1ps），且与 `work/.../yunsuan/build/` 下 emu 实际产出的两份 VCD **md5 完全一致**（`1fc0c61c…` / `8c088ac9…`），来源无疑。`02_向量加法指令执行过程分析.md` 的波形论断我**用自写的第二套 VCD 解析器独立复算**，结论：事务表（16 笔的 `t_fire/t_out/sew/vl/vlmul/vm/ta/ma` 与四路 128 位 payload）、1 周期延迟（8/8）、0 周期延迟（8/8）、`cin_1..7 @#33 = 0,0,1,0,0,0,0`、`@#21 = 1,1,0,0,1,0,0`、`updateType`/`tailS1`/`mask16bReorg`/`64b[*].vd(raw)` @#23/#29/#41/#47/#59、`--verify` 的 40+38=78 元素 0 失配、`--sew-crosscheck` 全表 —— **逐项命中，一处不差**。**但 `03_仿真平台搭建报告.md` §6.4 与 §4.3 的波形数字与同一批 VCD 相矛盾**（时刻、事务序号、延迟三项全错，详见问题 P-02），两份阶段一文档对同一波形给出互斥结论 |
| 5 | 覆盖 编码→译码→uop 拆分→发射→VIAlu 数据通路→mask/tail→写回，并标注香山源码 `文件:行号` | **PASS** | 七个环节全覆盖且层层有据。我抽查了 **32 处 `文件:行号`**（XiangShan 18 处、yunsuan 8 处、NEMU 6 处），**26 处精确命中**，含最关键的 `Instructions.scala:407`、`VecDecoder.scala:189` 与 `:28-43`、`UopInfoGen.scala:201`、`DecodeUnitComp.scala:359-367`、`DecodeUnit.scala:858-866/1081-1082`、`FuConfig.scala:532-549`（latency 确在 `:544`）、`VIAluFix.scala:147-149`、`Mgu.scala:89-94`、`VIntAdder64b.scala:88-96`、`VIntFixpAlu.scala:268-281`、`VecExceptionGen.scala:275`、`Parameters.scala:449/453`。另核实了文档的关键去伪论断 `grep -rn "VectorIntAdder\|VIAluFWrapper" src/` → **确为 0 命中**，而 `VIAluFix.scala:147` 例化的 `VIntFixpAlu64b` 与波形中的是同一个 Chisel 类 —— 这是整篇分析成立的支点，成立。`VialuFixType.vadd_vv = 0x40` 的推导我按 `FMT.VVV=b00`(:71) + `SINT=b1`(:108) + `VialuOpcode.vadd=0` 复算，**文档正确，反倒是上游 `package.scala:113` 的行尾注释 `"b00_0_000000"` 是错的** | 
| 6 | 文档中明确标注本层级的局限（hello 跑在 NEMU 而非全核 RTL 必须写明） | **PASS** | 三份文档各有独立且不回避的局限性章节，交叉一致，无一处暗示跑过全核：`01` §6.1 开头即"**必须明确写明**…不是由香山 RTL 的 Verilator 全核仿真产生"；`01` §6.2 用 6 行实测表说明全核不可行，并主动声明"**没有真的去跑 40 GB 堆的全核构建**，上述判定来自公开资源要求与本机实测的对照，不是一次失败构建的事后解释"；`02` 在正文第一屏就把证据分成【波形证据】/【源码证据】两类并声明"全文**没有任何**基于全核波形的断言"，§10.2 逐条列出 7 项未做/做不到（无全核波形、被观测的壳不是 `VIAluFix`、`VectorIntAdder` 不在全核路径上、`uop_idx` 恒 0、e8 未观测、`vstart≠0` 未观测、本阶段未运行任何构建）；`03` §8 列 6 项局限，并把 `make test` 失败明确标为 ❌。我把这些局限逐条对照日志，**没有发现任何被埋起来的限制**，反而发现文档对自己不利的事实（上游 `ALL_FUTYPES` 不含 fuType=5、gen_random_sew 取不到 e8、chiseltest 全败）都主动写了出来 |

**总判定：6 条中 3 条 PASS、3 条部分通过，无 FAIL。核心主张（hello 真实、波形真实、分析可追溯）全部经独立复算成立；扣分集中在"旁支文档的陈述与证据脱节"与"从零复现链条缺首段"。**

---

## 二、对赛题 1.1 / 1.2 / 1.3 的完备性判断与预测分数

| 赛题条目 | 要求 | 完备性 | 依据 |
|---|---|---|---|
| **1.1 环境部署验证** | 输出 `hello xiangshan, I am xxx, IP address` | **完备，且超出要求** | 字符串格式完全符合（`hello xiangshan, I am cie2026-vdot, IP address 192.168.30.213`）。超出部分有三点真实价值：① 串口基址 / 内存基址 / VLEN 三个常量是**编译期从被测 NEMU 的 `autoconf.h` 抽取**的，配置不符则一个字符都打不出；② 横幅里 5 个 CSR 由 `csrr` 实读，并做 `vlenb×8 == VLEN 宏` 的交叉校验；③ 顺带跑了一段 16 路 `vadd.vv` 自检（含负数）并与 C 参考逐元素比对。IP 的取法（默认路由网卡 `en1` 而非 APIPA 的 `en0`）有交叉验证与说明。唯一扣分项：运行在 NEMU 而非香山 RTL —— 但赛题只说"环境部署验证"，且文档已如实标注 |
| **1.2 操作日志** | 完整的开发环境部署与操作过程日志 | **完备** | 9 个文件 17726 行，覆盖容器镜像构建（2013 行）、NEMU 双形态构建（342 行）、宿主工具链安装（466 行）、mill 精化（195 行）、L1 仿真平台（14243 行）、全核可行性调查（290 行）、验证程序实跑（125 行）。带 UTC/CST 时间戳、带 `$ 命令` 回显、**带 4 次真实失败与修复**（espresso 架构不符、mill forkEnv 缓存、NEMU `.config` 全局状态互相覆盖、chiseltest 与 Verilator 版本不兼容），还有一次故意的故障注入自测证明比对器有效。这不是"成功录像"，是真实工程过程。扣分：1 处日志出处张冠李戴（P-01），3 处行数统计差 1~3 行 |
| **1.3 向量加法指令执行过程文档** | 依据仿真波形和参考文档，描述 `vadd.vv` 在香山中的执行过程 | **完备（功能单元级），全核级为源码论证** | 1391 行，覆盖 编码→取指→译码→uop 拆分→重命名→分发→发射→5 源读取→FU 数据通路→mask/tail→写回→ROB→difftest 全链，附完整流水线路径图。"依据仿真波形"这一条是实打实的：8 笔事务的 4 路 128 位输入 / 输出、`VIntAdder64b` 的 7 根进位线、`VIntFixpAlu` 的 `updateType[16]`、ALU 原始和与最终 vd 的两级关系，全部从真实 VCD 抽出且我**独立复算无误**；并给出了"进位在 SEW 边界被切断（`cin_2=0`）"这一**结构级而非数值级**的硬证据。局限也诚实：取指/译码/拆分/重命名/分发/写回/提交七段**只有源码证据**，文档在每一节开头都标了"【源码级，无波形】"。这与赛题"依据仿真波形**和参考文档**"的措辞是吻合的 |

### 预测分数（阶段一满分 15）

**13 / 15 —— 优秀带（13-15）下沿。**

给分理由：
- 1.1 的"自证性"设计（编译期抽配置 + 运行期读 CSR + 交叉校验）会让评委很难怀疑真实性，这类细节在同类提交里罕见，是明确的加分项。
- 1.2 的日志含真实失败与修复，而不是清一色的成功输出，可信度高。
- 1.3 的深度（结构级进位证据 + 32 处源码行号 + 78 元素逐元素核验）明显超过"描述执行过程"的最低要求。
- 诚实性处理得体：全核跑不了这件事被摆在最显眼处并给出实测论证，而不是糊过去。

扣 2 分的理由：
- **没有全核波形**。评委若严格理解"在香山中的执行过程"，会认为观测点停在功能单元级（yunsuan 的 `SimTop`，无前端/译码器/ROB/寄存器堆），译码与 uop 拆分那几段只是读代码。这是硬伤，哪怕理由充分。
- **`03_仿真平台搭建报告.md` §6.4 的波形数字与交付的 VCD 对不上**（见 P-02）。评委只要打开 VCD 对一眼就会发现两份文档自相矛盾，而"波形证据"恰恰是本阶段最硬的卖点，一处自相矛盾会连带动摇对 `02` 的信任。
- 1 处日志出处张冠李戴（P-01）。

**风险提示**：若评委先翻到 `03` §6.4 并与 `02` §5.3 对照，印象分可能把这一项拉到 **11-12（良好带上沿）**。P-01/P-02 都是 10 分钟内可修的文字问题，不修可惜。

---

## 三、问题清单

### 阻塞（0 项）

无。没有任何一条验收标准的核心证据被证伪。

### 重要（4 项）

| # | 等级 | 位置 | 问题 | 建议修法 |
|---|---|---|---|---|
| **P-01** | 重要 | `docs/stage1/01_环境部署报告.md:415`（§5.3） | **日志出处张冠李戴，触犯执行纪律第 1 条。** 文档写"**现象**：`p1_nemu_build.log:150` 显示 `SPECIALIZE_TYPE=RISCV make -s -C .../resource/softfloat/repo/build/Linux-x86_64-GCC all`"。实测：`grep -i softfloat logs/stage1/p1_nemu_build.log` → **0 命中**；`grep -rn 'Linux-x86_64' logs/` → **唯一命中 `p1_t3_yunsuan_sim.log:9`**，那是 yunsuan/Verilator 侧的构建日志，路径是 `yunsuan/resource/softfloat/...` 而非 NEMU 的。`p1_nemu_build.log:150` 的真实内容是 `+ CC src/monitor/image_loader.c`。技术结论本身没错（`work/NEMU/scripts/softfloat.mk:10` 确实写死 `build/Linux-x86_64-GCC`，`CONFIG_FPU_SOFT=y` 确实会编译它），但**作为"现象"呈现的日志证据不存在** | 二选一：① 删掉这段"现象"的日志引用，改写成纯源码论证（"`NEMU/scripts/softfloat.mk:10` 把构建目录名写死为 `Linux-x86_64-GCC`，在 aarch64 上容易误判"）；② 若要保留日志证据，重跑一次 `make clean-softfloat && ./scripts/02_build_nemu.sh` 让该行真的出现在 NEMU 日志里，再更新行号。**不要**把别的日志的行当成本日志的行 |
| **P-02** | 重要 | `docs/stage1/03_仿真平台搭建报告.md:437-470`（§6.4）与 `:291,293`（§4.3 延迟列） | **波形描述与交付的 VCD 矛盾，且与 `02` 号文档互斥。** 我用两套独立解析器（交付的 `vcd_extract.py` 与自写的第二套）得到同一结果：<br>· fuType3 第一笔：`in.fire @#21`、`out.valid @#21`、**0 周期**。`03:437,443` 写"时刻 #23"、"@#25（1 个时钟后）"——时刻与延迟都错。<br>· fuType5：`03:451` 称"第一笔事务（时刻 #25）"，但它引用的数据（`src0=416f59b3…`、`old_vd=622d3130…`、`vd=…2de65e87ffffffff`）实际是**第 2 笔**，真实时刻 `#27→#29`，**1 周期**；`03:459` 写"@#29（2 个时钟后）"——序号、起点、延迟三错。<br>· `03:449/467` 的"第二笔事务 sew=e16"实际都是**第三笔**（fuType3 的第二笔与第一笔激励完全相同，均为 e64）。<br>· `03:291` 把 fuType=3 写成"实测 1 个时钟"（真实 0），`03:293` 把 fuType=5 写成"实测 2 个时钟"（真实 1）。<br>`02` 号文档对同一批 VCD 给出的全部数字**完全正确**，所以这是 `03` 单方面的陈旧/错误记录，但它直接削弱 P1 验收标准 4 | 用 `python3 scripts/tools/vcd_extract.py --vcd <file> --transactions` 的真实输出重写 §6.4 整节与 §4.3 的"实测"列；或者直接删掉 §6.4 的数值段落，改为指向 `02` 号文档 §5.3/§5.5（避免同一事实两处维护） |
| **P-03** | 重要 | `scripts/00_setup_env_host.sh:118-130`（步骤 5/6）；`MASTER_PLAN.md:90` | **"从零复现"链条缺首段。** 三个上游仓库（XiangShan-kmhv2 + 11 个子模块 + rocket-chip 的 6 个嵌套子模块、NEMU、xs-env）没有任何脚本会去 clone。`00_setup_env_host.sh` 在 `work/XiangShan-kmhv2` 不存在时只 `info` 打印一行建议命令然后**继续执行完毕并以 0 退出**，随后 `10_build_yunsuan_sim.sh` 才会 `die`。评委在干净机器上照 `00 → source → 10` 跑会在第三步才失败，且 `00` 打印的建议命令只列了 5 个子模块，缺 `ChiselAIA/ChiselIOPMP/coupledL2/fudian/huancun/openLLC` 与 `rocket-chip --recursive`（这两组正是 `03` §7.1 实测踩过的坑）。另：计划书 `MASTER_PLAN.md:90` 约定的交付物名是 `scripts/00_setup_env.sh`，实际拆成 `00_setup_env_host.sh` + `01_setup_env_docker.sh`，两边未对齐 | 在 `00_setup_env_host.sh` 步骤 5 加一个 `CLONE=1` 分支（默认关闭、显式开启时执行），把 `03` §7.1 实测验证过的完整 clone 序列固化进去；或新增 `scripts/_bootstrap_repos.sh` 并在 `README`/`MASTER_PLAN` 的复现清单里列为第 0 步。同时把 `MASTER_PLAN.md:90` 的交付物名改成实际的两个文件名 |
| **P-04** | 重要 | `docs/stage1/01_环境部署报告.md:196-198`、`00_环境版本锁定.md:203-204` | **"零 patch / 工作区干净"的断言现已失效，且无法再被验收方复核。** 文档称"`git -C work/NEMU status --short` 为空"。我实测该命令输出 7 个 `M` + 1 个 `??`（`configs/*_defconfig`、`src/isa/riscv64/Kconfig`、`isa-all-instr.h`、`rvv/decode.h`、`rvv/vcompute*.h`、新增 `rvv/vdot.c`）—— 是 P5 工程师的在制品。同理 `00:203-204` 记录的产物体积 589,080 B / 1,570,888 B，现盘上是 589,272 B / 1,570,936 B（19:56 重建）。这不是写文档时的错，但**阶段一"NEMU 零改动即可构建"这一主张在当前仓库状态下已不可复验**，评委若照做会得到相反结论 | 在 `01` §3.4 与 `00` §N2/§N6 各加一句时间锚："以上状态为 2026-10-24 18:2x 采集；P5 阶段起 `work/NEMU` 会带 vdot 改动，复核阶段一的零改动主张请用 `git -C work/NEMU stash` 或另起一份 `master` 浅克隆"。另建议在 `02_build_nemu.sh` 开头打印 `git status --short` 并存进日志，让每次构建都自带状态快照 |

### 次要（11 项）

| # | 等级 | 位置 | 问题 | 建议修法 |
|---|---|---|---|---|
| P-05 | 次要 | `docs/stage1/00_环境版本锁定.md:214,215,216` | 三处日志行号整体偏移约 9 行：`misa` 标为 `p1_hello_xiangshan.log:78`（真实 **:87**）、`vlenb` 标为 `:79`（真实 **:88**）、`marchid`/`mvendorid` 标为"第 75-76 行"（真实 **:84-85**）。`:78/:79` 实际指向的是 `NEMU commit` 与 `image base` 两行 | 改为 `:87`、`:88`、`:84-85` |
| P-06 | 次要 | `docs/stage1/01_环境部署报告.md:14,15,16` | 日志行数表三处与实际不符：`p1_nemu_build.log` 标 341（实 **342**）、`p1_hello_xiangshan.log` 标 124（实 **125**）、`p1_hello_config_guard.log` 标 24（实 **27**）。`p1_docker_build.log`(2013)、`p1_fullcore_feasibility.log`(290) 正确 | 用 `wc -l logs/stage1/*.log` 重新生成该表 |
| P-07 | 次要 | `docs/stage1/01_环境部署报告.md:111` | `-lz` 标为 `NEMU/Makefile:115`，实际在 **`:116`**（`:115` 是 `endif`）。同节其余 5 处 Makefile 引用（`:120`、`:121-124`、`:125-128`、`:17-18`、`:156-158`）与 `scripts/git.mk`、`softfloat.mk:6-8/:10`、`nanopb.mk:5-7` 全部正确 | 改为 `:116` |
| P-08 | 次要 | `docs/stage1/01_环境部署报告.md:479` | `release.yml:175,189` 未注明仓库。`work/XiangShan-kmhv2/.github/workflows/release.yml` 只有 93 行且不含 `fallocate`/`JVM_XMX`；该两行实际在 **`work/XiangShan`（kunminghu-v3 克隆）** 的 `release.yml`（我已核实 `:175` = `fallocate -l 32G`、`:189` = `JVM_XMX=10g`，数值无误）。`p1_fullcore_feasibility.log:195` 里写清了路径，文档里丢了 | 写成 `work/XiangShan(kunminghu-v3)/.github/workflows/release.yml:175,189`，并补一句"v2 分支的 release.yml 不含该步骤，此处引 v3 作为官方资源需求的旁证" |
| P-09 | 次要 | `docs/stage1/03_仿真平台搭建报告.md:299` | `finish_fixLatency` 标为 `VectorSimTop.scala:378`，实际在 **`:122`**（`:378` 是 `vid_fflags_1` 赋值）。同文件其余引用（`:13-24`、`:26-43`、`:40`、`:85`、`:104-115`、`:400`）均正确 | 改为 `:122`（判定表达式）或 `:384`（`io.out.valid` 使用处） |
| P-10 | 次要 | `docs/stage1/03_仿真平台搭建报告.md:266` | `vs1 = Mux(needReverse, src(1), src(0))` 标为 `VIAluFWrapper.scala:66-67`，实际在 **`:63-64`**；`:66-67` 是其后的 `vIntFixpAlu.io.in.vs1/vs2 :=` 赋值。`02` 号文档同一事实标为 `:61-67`（含正确行） | 改为 `:63-64` |
| P-11 | 次要 | `tests/riscv/hello/start.S:25` | 注释称 `mstatus.FS/VS` 复位清零见 `src/isa/riscv64/init.c:69-70`，实际在 **`:72-73`**（`:69-70` 是注释行）。`01` 号文档 §4.2 引的 `:72-73` 是对的，源码注释与文档不一致 | 注释改为 `:72-73` |
| P-12 | 次要 | `tests/riscv/hello/hello.c:16,32` | 两处注释行号偏移：寄存器布局标 `uartlite.c:18-21`（真实 **:20-23**，`:18` 是 `CH_OFFSET`，且漏掉 `STAT_REG`）；`putc` 转发标 `uartlite.c:120-124`（真实 **:126-129**，`:120-124` 是 `CONFIG_UARTLITE_ASSERT_FOUR` 的断言块）。`01` 号文档 §4.1 引的 `:126-129` 是对的 | 注释分别改为 `:20-23` 与 `:126-129` |
| P-13 | 次要 | `docs/stage1/02_向量加法指令执行过程分析.md:524` | §5.4 握手时间线表里 `#20` 行的 `in_vinfo_vl` 抄成 `01`，归档文件 `vadd_signal_trace.txt` 第 8 节的真实值是 **`00`**（`01` 要到 `#21` 锁存后才出现）。该表以"引自 trace 文件"的形式呈现，逐字节一致性被破坏 | 按 `vadd_signal_trace.txt` 原样改回 `00` |
| P-14 | 次要 | `docs/stage1/02_向量加法指令执行过程分析.md:713-719` | §5.7 的表以"命令 `--sew-crosscheck` 的输出"形式给出，但**静默删掉了事务 #1/#4/#5 三行**（我重跑得到 8 行）。被删的三行不影响结论（#1 与 #0 激励相同、#4/#5 非唯一解），但未标"节选" | 加一句"（节选，完整 8 行见 `vadd_signal_trace.txt` 第 3/6 节）"，或直接贴全 |
| P-15 | 次要 | `scripts/01_setup_env_docker.sh:30` | 注释"宿主 UID/GID 透传，避免产生 root 所属文件"与代码不符 —— `docker run` 没有 `--user` 参数。在 macOS/Docker Desktop 下靠 virtiofs 的属主映射碰巧没问题（我实跑产出的 `build/*` 属主是本机用户），但在 Linux 宿主上会生成 root 文件；`p1_nemu_build.log:126` 里 `root root` 的产物属主就是旁证 | 要么补 `--user "$(id -u):$(id -g)"`（注意容器内 HOME 与 git safe.directory），要么把注释改成"macOS/Docker Desktop 下由 virtiofs 做属主映射；Linux 宿主需自行加 `--user`" |

### 附：被我专门尝试证伪但**站得住**的点

列出来是为了说明哪些结论可以放心对外讲：

1. `hello` 那行**不是** shell `echo`。字符串在 bin 的 `0xbd0`、经 `sb` 写 `0x40600004`、NEMU `uartlite.c:128` 转发到 stderr，整条链我逐环打开过；换一个重建过的 NEMU 二进制重跑，输出字节级相同。
2. 两份 VCD **不是**手工编造或从别处拷来的：与 `yunsuan/build/` 下 emu 当场产出的文件 md5 相同。
3. `02` 号文档的 `cin_1..7 = 0,0,1,0,0,0,0 @#33` **不是**凑出来的：我手算 `0x64+0xef=0x153` 确有进位，而 e16 边界使 `cin_2` 被切断，与 `VIntAdder64b.scala:92-93` 的 `Mux(is64||is32, cout(i-1), carryIn(i))` 一致；若进位传过去，元素 1 会是 `0xC31D` 而非 DUT 实测的 `0xC31C`。这是结构级证据，不是数值巧合。
4. "波形里的加法器就是全核里的那一个"这一支点成立：`grep -rn "VectorIntAdder\|VIAluFWrapper" src/` 在 XiangShan 侧 0 命中，而 `VIAluFix.scala:147` 与 `VIntFixpAlu.scala:157` 例化的是同一个 `VIntFixpAlu64b` 类。
5. 所有 commit SHA 真实：`XiangShan-kmhv2 = a4eeaabb…`（分支 `kunminghu-v2`）、`yunsuan = 95592118…`、`NEMU = 90908390…`、`xs-env = 81346b8d…`，11 个子模块 SHA 与 `00` 号文档表格**逐行一致**。
6. `03` 号文档的 Verilog 产物统计全部精确：`VIAlu.sv` 4567 行 / 19 module、`VIMac.sv` 3069 行 / 2 module、`SimTop.v` 47790 行 / 164 module。
7. 署名与作者信息统一、无 `TODO/TBD/FIXME/xxx/lorem` 残留（`.git` 与 `work/` 除外）；git 作者统一为 `cie2026-vdot`，8 条 commit message 均为规范中文。
8. `02` 号文档说 `VialuFixType.vadd_vv = 0x40`（sign=1），与上游 `package.scala:113` 行尾注释 `"b00_0_000000"` 冲突 —— 复算后**文档对、上游注释错**，且文档已就该符号位是否影响模加法给出了正确的分析。

---

## 四、复现记录（我实际执行的命令与真实结果）

```bash
# [1] 环境确认
$ docker images xsdev:ubuntu24.04-arm64
xsdev  ubuntu24.04-arm64  e6437c4c6d10  2 hours ago  2.78GB          # 与 00 号文档 §N4 的 ID/体积一致
$ docker info --format '{{.Architecture}} {{.OSType}} NCPU={{.NCPU}} MemTotal={{.MemTotal}}'
aarch64 linux NCPU=10 MemTotal=8217575424                            # 与 00 号文档 §N1 一致
$ route -n get default | awk '/interface:/{print $2}' ; ipconfig getifaddr en1
en1
192.168.30.213                                                       # 与文档记录的 IP 一致
```

```bash
# [2] 赛题 1.1 验证程序 —— 完整重跑（事先把原日志与 build/ 备份到 /tmp，跑完已原样还原）
$ ./scripts/03_run_hello.sh
EXIT=0

# 模拟器实际输出（新日志第 97 行）：
hello xiangshan, I am cie2026-vdot, IP address 192.168.30.213
# 同次运行的关键行：
#   :42-43  Machine: RISC-V / Entry point address: 0x80000000
#   :46     bd0 hello xiangshan, I am cie2026-vdot, IP address 192.168.30.213
#   :52-54  8000003e lui a3,0x40600 / 8000004e c.addi a3,4 # 40600004 / 80000052 sb a4,0(a3)
#   :62-65  vle8.v v1,(t1) / vle8.v v2,(t3) / vadd.vv v3,v1,v2 / vse8.v v3,(a4)
#   :87-89  misa 0x80000000003411af (RV64 ABCDFHIMSUV) / vlenb 16 -> VLEN 128 / MATCH
#   :95     result = PASS (16/16 lanes match the C reference)
#   :114-118 nemu_trap case 0 / HIT GOOD TRAP at pc = 0x0000000080000038 / trap code:0
#            total guest instructions = 8115

$ diff <归档日志> <重跑日志>
# 仅 7 行差异，全部是不可避免的非确定性量：
#   UTC 时间戳 ×2、bin 的 ls 时间、NEMU "Build time" (10:21:58 -> 11:56:16)、
#   pmem 映射地址 (0xf80039000000 -> 0xf8002ca00000)、host time (1260us -> 767us)、
#   simulation frequency。
# 横幅全文、CSR 全部取值、8115 条指令数、HIT GOOD TRAP 的 pc —— 完全一致。
```

```bash
# [3] 波形独立复算 —— 先用交付脚本，再用我自写的第二套解析器交叉验证
$ python3 scripts/tools/vcd_extract.py --vcd logs/stage1/waveform/vaddvv_vialufwrapper_fuType5_seed2.vcd --transactions
   #  t_fire   t_out  cyc fuT  fuOp  sew  vl vlmul vm ta ma ui
   0      21      23    1   5     0  e32   1     7  0  1  1  0
   1      27      29    1   5     0  e32   1     0  0  0  1  0
   2      33      35    1   5     0  e16   2     1  1  1  1  0
   3      39      41    1   5     0  e64   4     3  0  0  0  0
   4      45      47    1   5     0  e16   2     6  1  1  0  0
   5      51      53    1   5     0  e64   4     3  1  1  1  0
   6      57      59    1   5     0  e32   2     7  0  0  0  0
   7      63      65    1   5     0  e16   3     0  1  1  1  0
#   -> 与 02 号文档 §5.3 的表格逐格相同；延迟 8/8 笔都是 1 周期

$ python3 scripts/tools/vcd_extract.py --vcd logs/stage1/waveform/vadd_vintadder_fuType3_seed1.vcd --transactions
   0      21      21    0 ...   7      49      49    0
#   -> 与 02 号文档 §5.5 相同；延迟 8/8 笔都是 0 周期
#   -> 与 03 号文档 §6.4（#23->#25，1 周期）矛盾  ==> 问题 P-02

$ python3 /tmp/audit_p1/indep.py <两份 vcd>      # 我自写的最小 VCD 解析器，不复用交付代码
fire@21 out_valid@23 cyc=1 sew=2 vl=1 vm=0 ta=1 ma=1 vlmul=7
  src0=60b7acd93ab50c2a_000041a710d63af1  src1=06058ed856e509fe_4431b7821c06dac8
  oldvd=31169898427c3c55_56f32f4377a4044d mask=06d7d4b343cd3747_6a5d128c046cdbe2
  res=ffffffffffffffff_ffffffffffffffff
... （8 笔全部与上表一致，fuType3 的 8 笔亦然）
#   -> 结论：交付脚本的采样约定没有问题，02 号文档的时刻号可信
```

```bash
# [4] 逐元素核验与 SEW 交叉验证
$ python3 scripts/tools/vcd_extract.py --vcd <fuType5> --verify | grep -c ' OK$'   ->  40
$ python3 scripts/tools/vcd_extract.py --vcd <fuType5> --verify | grep -c MISMATCH ->   0
$ python3 scripts/tools/vcd_extract.py --vcd <fuType3> --verify | grep -c ' OK$'   ->  38
$ python3 scripts/tools/vcd_extract.py --vcd <fuType3> --verify | grep -c MISMATCH ->   0
#   -> 40+38=78，与 02 号文档 §0 第 9 条和 §5.6 核验 5 的表完全一致

$ python3 scripts/tools/vcd_extract.py --vcd <fuType3> --sew-crosscheck
   0 e64 21   9/16  6/8  4/4  2/2
   1 e64 25   9/16  6/8  4/4  2/2      <- 02 号文档的表中被略去
   2 e16 29  13/16  8/8  2/4  0/2      <- e16 唯一全中，与文档一致
   3 e16 33  14/16  8/8  4/4  2/2
   4 e64 37  11/16  6/8  4/4  2/2      <- 被略去
   5 e32 41   9/16  6/8  4/4  2/2      <- 被略去
   6 e16 45  13/16  8/8  2/4  0/2      <- e16 唯一全中，与文档一致
   7 e32 49   8/16  4/8  4/4  2/2
#   -> 文档列出的 5 行数值全对；3 行被静默省略  ==> 问题 P-14
```

```bash
# [5] 内部信号：mask/tail 四种策略 + SEW 分段进位链
$ python3 scripts/tools/vcd_extract.py --vcd <fuType5> --internal
事务#0 @#23: mask16bS1=0x0002 tailS1=0xfffe prestartS1=0x0000
             mask16bReorg=0x00f0 tailReorg=0xfff0 taS1=1 maS1=1
             64b[0].vd(raw)=0x4431f9292cdd15b9  64b[1].vd(raw)=0x66bd3bb1919a1628
             updateType[15..0]= 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3
             out.vd=0xffffffff...ffffffff                       -> 与文档 §6.3(A) 逐字段相同
事务#1 @#29: taS1=0 maS1=1 mask16bS1=0x0004 mask16bReorg=0x0f00 tailReorg=0xfff0
             64b[0].vd(raw)=0x0863f25359ba2b72
             updateType = 2×12 ∥ 3×4   out.vd=0x622d313004f878ab2de65e87ffffffff
                                                                -> 与文档 §6.3(B) 相同
事务#3 @#41: taS1=0 maS1=0 mask16bReorg=0xff00 tailReorg=0x0000
             updateType = 0×8 ∥ 2×8   out.vd=0x82af1b0cb618f3da5bf8ca282aa03744
                                                                -> 与文档 §6.3(C) 相同
事务#4 @#47: updateType = 3×12 ∥ 0×4                             -> 与文档 §6.3 小结相同
事务#6 @#59: updateType 全 2，out.vd ≡ old_vd                     -> 与文档 §6.3(D) 相同
事务 #0..#7 的 prestartS1 全为 0x0000                             -> 与文档 §10.2 第 6 条相同

# SEW 分段进位链（文档最硬的一条结构级证据）
in.fire @#33 (sew=e16): cin_1..cin_7 = 0,0,1,0,0,0,0            -> 与文档 §5.6 核验 1 / W6 相同
in.fire @#21 (sew=e32): cin_1..cin_7 = 1,1,0,0,1,0,0            -> 与文档 W9 相同
```

```bash
# [6] 波形来源溯源
$ md5 -q "work/XiangShan-kmhv2/yunsuan/build/2026-10-24@18:40:50_dump_wave_seed_1.vcd" \
         logs/stage1/waveform/vadd_vintadder_fuType3_seed1.vcd
1fc0c61c15e659cc88806e79f5361837
1fc0c61c15e659cc88806e79f5361837        # 一致
$ md5 -q "...seed_2.vcd" logs/stage1/waveform/vaddvv_vialufwrapper_fuType5_seed2.vcd
8c088ac9194e8f6d514eef28cd14d8fb
8c088ac9194e8f6d514eef28cd14d8fb        # 一致
$ grep -c '\$var' <两份vcd>   -> 11543 / 11543
$ grep -c '\$scope' <两份vcd> ->   724 /   724
```

```bash
# [7] commit SHA 核对
$ git -C work/XiangShan-kmhv2 rev-parse HEAD ; git -C work/XiangShan-kmhv2 rev-parse --abbrev-ref HEAD
a4eeaabb4c12349259094a8b55f3ba1c03a9d993
kunminghu-v2
$ git -C work/XiangShan-kmhv2 submodule status
 955921186e34bb8915806582a238181a6dc3435c yunsuan      # 11 个子模块 SHA 与 00 号文档逐行一致
 46f1efefa1ff431bffe3262e4830bc50316842f4 rocket-chip
 ... （略）
$ git -C work/NEMU  rev-parse HEAD -> 90908390002fb7da885e5d880bba3bef2a225b2a   # 一致
$ git -C work/xs-env rev-parse HEAD -> 81346b8de58d9d6f5d944d1d720c1be4d85d1ebb   # 一致

$ git -C work/NEMU status --short
 M configs/riscv64-xs-kmhv2-ref_defconfig      # <- 01 号文档称此处应为空  ==> 问题 P-04
 M configs/riscv64-xs-kmhv2_defconfig
 M src/isa/riscv64/Kconfig
 M src/isa/riscv64/include/isa-all-instr.h
 M src/isa/riscv64/instr/rvv/decode.h
 M src/isa/riscv64/instr/rvv/vcompute.h
 M src/isa/riscv64/instr/rvv/vcompute_impl.h
?? src/isa/riscv64/instr/rvv/vdot.c
```

```bash
# [8] 源码引用抽查（32 处，仅列出判定为错的 6 处，其余 26 处命中）
sed -n '407p' work/XiangShan-kmhv2/rocket-chip/src/main/scala/rocket/Instructions.scala
   -> def VADD_VV = BitPat("b000000???????????000?????1010111")              OK
sed -n '189p' .../backend/decode/VecDecoder.scala
   -> VADD_VV -> OPIVV(FuType.vialuF, VialuFixType.vadd_vv, T, F, F)          OK
sed -n '544p' .../backend/fu/FuConfig.scala      -> latency = CertainLatency(1)   OK
sed -n '147,149p' .../backend/fu/wrapper/VIAluFix.scala
   -> Seq.fill(numVecModule)(Module(new VIntFixpAlu64b)) / Mgu / Mgtu         OK
sed -n '88,96p' .../yunsuan/.../VIntAdder64b.scala -> cin 断链三分支           OK
sed -n '268,281p' .../yunsuan/.../VIntFixpAlu.scala -> updateType 5 路判定     OK
sed -n '275p'  .../backend/decode/VecExceptionGen.scala -> vstartIllegal       OK
sed -n '449p;453p' work/XiangShan-kmhv2/src/main/scala/xiangshan/Parameters.scala
   -> VFEX0 / VFEX2 均含 VialuCfg                                              OK
grep -rn 'VectorIntAdder\|VIAluFWrapper' work/XiangShan-kmhv2/src/  -> 0 命中   OK
sed -n '16,17p' .../yunsuan/src/test/scala/top/VectorSimTop.scala
   -> VIA_latency = 0 / VIAF_latency = 1                                       OK
sed -n '146,157p;240p;307p' .../yunsuan/src/test/csrc/test_driver.cpp
   -> gen_random_sew default=(rand()%3)+1 / vstart=0 / uop_idx=0               OK
sed -n '107p' work/NEMU/src/isa/riscv64/instr/decode.c -> nemu_trap INSTPAT     OK
sed -n '128p' work/NEMU/src/device/uartlite.c -> putc(serial_base[TX], stderr)  OK
sed -n '193p;233,235p' work/NEMU/src/isa/riscv64/init.c -> vlenb / mvendorid…   OK
--------------------------------------------------------------------------- 以下为错
sed -n '115p' work/NEMU/Makefile                 -> "endif"（-lz 在 :116）      NG  P-07
sed -n '378p' .../VectorSimTop.scala             -> vid_fflags_1（非 finish_…） NG  P-09
sed -n '66,67p' .../VIAluFWrapper.scala          -> io.in.vs1/vs2 赋值（非 Mux）NG  P-10
sed -n '69,70p' work/NEMU/src/isa/riscv64/init.c -> 注释行（fs/vs=0 在 :72-73） NG  P-11
sed -n '120,124p' work/NEMU/src/device/uartlite.c-> ASSERT_FOUR 块（非 putc）   NG  P-12
grep -rn 'Linux-x86_64' logs/                    -> 仅 p1_t3_yunsuan_sim.log:9  NG  P-01
```

```bash
# [9] 日志真实性抽查
$ for n in 13718 13734 13751 13761 13766 13799 13841; do sed -n "${n}p" logs/stage1/p1_t3_yunsuan_sim.log; done
exit=0 / EMU EXCEEDED LIMIT / EMU EXCEEDED LIMIT / EMU EXCEEDED LIMIT
=== [18:11:59] 比对有效性自测（故障注入）… / rebuild exit=0 / === [18:17:40] CI 第一条命令：make test …
#   -> 03 号文档 §1/§3.3/§6.5/§8.1 引的行号全部对得上
$ grep -nE '#6 DONE|#7 DONE' logs/stage1/p1_docker_build.log -> 1768:#6 DONE 855.1s / 1984:#7 DONE 226.5s
$ sed -n '1995p' logs/stage1/p1_docker_build.log
#8 0.162 RVV 1.0 assembler probe OK: riscv64-linux-gnu-gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
#   -> 01 号文档 §2.4 引的行号、内容全对
$ sed -n '126,127p;228,229p;231p' logs/stage1/p1_nemu_build.log -> 产物尺寸/file 输出/[C] 恢复步骤，全对
$ sed -n '14p;60p;88p;104p;169p;179p;206p;214p' logs/stage1/p1_fullcore_feasibility.log -> 八个小节标题全对
$ sed -n '81p' work/XiangShan-kmhv2/Makefile -> JVM_XMX ?= 40G                  OK
$ sed -n '175p;189p' work/XiangShan/.github/workflows/release.yml
  sudo fallocate -l 32G /mnt/xs-swapfile ；… JVM_XMX=10g                        数值 OK，仓库名缺失 P-08
```

```bash
# [10] 署名与占位符检索（排除 .git 与 work/）
$ grep -rniE 'generated by|co-authored-by' . \
      --exclude-dir=.git --exclude-dir=work
（无输出）
$ grep -rnE 'TODO|TBD|FIXME|XXX|lorem ipsum|占位' docs/stage1 scripts tests/riscv/hello
（无输出）
$ git log --format='%an <%ae>' | sort -u   -> cie2026-vdot <cie2026-vdot@users.noreply.github.com>
$ git log --oneline -8                     -> 8 条规范中文 commit message
```

```bash
# [11] 未能执行的项目（如实记录）
./scripts/00_setup_env_host.sh      # 未执行：会动宿主 brew 与 work/tools，且环境已就绪，重跑无增量信息
./scripts/01_setup_env_docker.sh build  # 未执行：约 18 min 且会覆盖 p1_docker_build.log（交付证据）
./scripts/02_build_nemu.sh          # 未执行：会在 work/NEMU 内构建，与 P5 工程师的在制品冲突
./scripts/10_build_yunsuan_sim.sh   # 未执行：会在 work/XiangShan-kmhv2/yunsuan 内构建
(cd work/.../yunsuan && ./build/emu -O 10000)   # 尝试执行，被沙箱以"可能干扰他人工作负载"拒绝
#   -> 因此「10000 组随机激励全 PASS」这三条结论我**无法独立复验**，只能确认：
#      归档日志 p1_t3_yunsuan_sim.log:13734/13751/13761 与 p1_t3_yunsuan_sim_rerun.log
#      是两次独立运行（时间戳 18:11 与 18:57、emu 编译时间 18:08:09 与 18:56:40 不同）
#      且周期数完全相同（57063 / 20019 / 30019），具备自洽性。
```

---

## 五、给执行方的最高价值建议（按性价比排序）

1. **先修 P-02（30 分钟）**：用 `vcd_extract.py --transactions` 的真实输出重写 `03` §6.4 与 §4.3 的"实测"列。这是唯一会被评委"打开波形对一眼就发现"的自相矛盾，且会连带损害 `02` 号文档这个真正的亮点。
2. **再修 P-01（10 分钟）**：删掉或重取 `01` §5.3 的日志引用。这是全仓唯一一处触碰"禁止伪造"红线的地方，技术结论不变、代价极低。
3. **P-03（1 小时）**：补上 clone 引导，让"从零复现"真的从零开始。
4. **P-05~P-15（1 小时）**：批量修行号。建议写一个一次性校验脚本（读文档里的 `` `path:line` `` 模式 → `sed -n` 取行 → 人工过一遍），P8 阶段对 `docs/stage2`、`docs/stage3` 复用，收益会放大。
5. **可选加分项**：若能在任意一台 ≥64 GiB 的 x86_64 Linux 机器上跑出一段**全核** `vadd.vv` 的波形（哪怕只有 20 个周期），阶段一就能稳进 14-15 分；这是当前与满分之间唯一的实质性差距。
