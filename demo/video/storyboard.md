# 三段演示视频：分镜与数据来源

作品：XiangShan-vdot（面向边缘 AI 大语言模型推理的 RISC-V 自定义 vdot 指令设计），参赛队伍 SNL，目标平台香山昆明湖 V2。
赛题要求的三段视频全部由本目录的脚本从提交文档、仓库存档与一次终端演练录制生成，不录屏：

| 段 | 中文标题（片头卡片） | 文件 |
|---|---|---|
| ① | 视频一　阶段一操作过程：环境部署、NEMU 构建、hello 验证与 vadd.vv 波形分析 | `SNL-XiangShan-vdot-video1-stage1.{mp4,srt}` |
| ② | 视频二　阶段二解题思路：vdot 语义、官方伪代码对照、微架构、数据通路、RTL 与三项测试 | `SNL-XiangShan-vdot-video2-stage2.{mp4,srt}` |
| ③ | 视频三　阶段三波形仿真与性能分析：NEMU 扩展、协同仿真、全核 difftest、波形与加速比 | `SNL-XiangShan-vdot-video3-stage3.{mp4,srt}` |

格式：1920×1080，30 fps，H.264 yuv420p，静音 AAC 音轨，中文字幕烧录在画面里，同内容的外挂字幕为同名 `.srt`。
以后如需配音，可按 `.srt` 时间轴录音，再用 `ffmpeg -i 视频.mp4 -i 配音.m4a -map 0:v -map 1:a -c:v copy` 替换音轨，无需重渲染。

## 口径

- headline 只用一个口径：**MinimalConfig 全核实测 latency 加速比——单次 16 元素点积 1.70×（函数整体），长向量稳态 1.81× / 2.25×**
  （`README.md` §1.2，`docs/stage3/22_基线实现与延迟加速分析.md` §5.5 / §12，`bench/results/speedup.csv`）。适用范围（MinimalConfig、热态、带 difftest，默认配置未测）与 headline 同屏出现。
- 其余加速比（3.00× 指令条数、4.67× uop、2.00× / 1.50× / 3.00× 建模、5.17× / 2.81× 参考口径）只出现在「参考口径」表里，并带「实测 / 源码推导 / 建模」标注。
- 低于模型、未测、未综合、不利发现照写，卡片上用琥珀色标出。
- 每张卡片右下角写出数字的出处（文档章节或日志行号）；卡片与字幕的文字都在 `storyboard.py` 同一幕里，改数字时两处一起改。

## 终端画面怎么来的

- 2026-11-08 在本机（Linux x86_64）做了一次正式演练：`asciinema rec -c 'bash demo/video/rehearsal.sh'`，录成 `casts/rehearsal-2026-11-08.cast`（asciinema v2，150×40）。
  `rehearsal.sh` 只跑短命令：`02_build_nemu.sh`、`03_run_hello.sh`、`21_build_nemu_vdot.sh`、`50_run_fullcore_difftest.sh wave-vl8`、官方伪代码等价核对、0x80×0x80 单条 DUT 用例、读存档 VCD；
  长任务（全核构建约 25 分钟、`20` 功能测试约 5 分钟、`30` 协同仿真约 4 分钟、全核 `run` / `perf`）只用 `sed` / `grep` / `tail` 展示仓库里已存档的运行结果，画面上先打印一行「# 已存档的运行结果：…」。
- 视频一的 v1-env / v1-nemu / v1-hello 三幕另录一次：`bash demo/video/rehearsal.sh stage1`，录成 `casts/rehearsal-stage1-2026-11-08.cast`。
  这次的 `WORK_DIR=/data/my/cie-stage1-repro/work` 是一套用 `00`/`02`/`03` 在全新目录从零搭好的纯阶段一环境（NEMU 未打 vdot 补丁，见 `logs/stage1/linux_repro/README.md`），
  所以 `02` 末尾「零 patch」工作区快照为空；`02` 结束时已把 NEMU 恢复为独立解释器配置，录完 `git status --short` 仍为空。其余各幕用仓库默认 `work/`。
- 演练时 `LOG_ROOT`、`RESULTS_DIR`、`FIG_DIR` 都指向 `/tmp/rec`；录完 `git status --short logs bench docs` 确认仓库存档无变化。
- `splitcast.py` 按 `rehearsal.sh` 打印的 `################  segment <幕号>` 标记把录像切成 `casts/<幕号>.cast`，时间戳保持原样、输出不改写，标记行本身不显示。
- 回放规则：有输出时 ×1；超过 1.5 s 没有新输出的等待段按 ×4 延时；字幕锚点处画面定格若干秒供阅读。右上角角标始终显示录制时的实际耗时与当前倍率（或「定格」）。
- 本机编译缓存命中，`02` / `21` 现场只需约 8 / 10 秒；字幕同时给出全新目录的存档耗时。

## 分镜表

下表由 `python3 make_video.py --md` 从 `storyboard.py` 生成（卡片内容、字幕全文与每幕时长见 `storyboard.py`）。

### 视频一：视频一 阶段一操作过程（`SNL-XiangShan-vdot-video1-stage1.mp4`）

| # | 分镜 | 画面 | 数据来源 |
|---|---|---|---|
| 1 | v1-01 | 片头：作品名、队伍、平台版本锁定；四个结果 tile | README.md §1.1；docs/stage1/02 §0 |
| 2 | v1-02 | 思路卡：分支选择、资源约束、分层验证、操作日志规模 | docs/ppt/讲解大纲.md P3；docs/stage1/03 §7.1；docs/00_项目总览.md |
| 3 | v1-03 | 终端：export 日志目录、版本锁定表三行、work/ 三个仓库的 HEAD、JDK/Verilator 版本、存档的一键部署结尾 | docs/stage1/00_环境版本锁定.md；logs/stage1/linux_repro/00_setup_env_host.term.log:558-560,644-645 |
| 4 | v1-04 | 终端：02_build_nemu.sh 现场运行（编译行已过滤） | scripts/02_build_nemu.sh；logs/stage1/linux_repro/README.md |
| 5 | v1-05 | 终端：03_run_hello.sh 现场运行（取 IP、交叉编译、strings/objdump 证据、NEMU 执行、HIT GOOD TRAP），grep 本次日志，grep 全核存档日志 | scripts/03_run_hello.sh；logs/stage1/p1_hello_xiangshan_fullcore.log:67,76-77 |
| 6 | v1-06 | 终端：vcd_extract.py --transactions / --verify 读存档 VCD；sed 全核轨迹 wave_trace.txt:150-181 | logs/stage1/waveform/vaddvv_vialufwrapper_fuType5_seed2.vcd；logs/stage3/fullcore/wave_trace.txt:150-181 |
| 7 | v1-07 | 卡片：fig1 握手与延迟、fig4 掩码尾部 + 五条要点 | docs/stage1/02 §0、§5.4、§6.3；docs/stage1/figures/fig1、fig3、fig4 |
| 8 | v1-08 | 卡片：fig7 全核 vadd 流水线 + 要点 | docs/stage1/02 §8.4.1；logs/stage3/fullcore/wave_trace.txt:150-181；fig7 |
| 9 | v1-09 | 结尾卡：阶段一三项交付与通向阶段二 | — |

### 视频二：视频二 阶段二解题思路（`SNL-XiangShan-vdot-video2-stage2.mp4`）

| # | 分镜 | 画面 | 数据来源 |
|---|---|---|---|
| 1 | v2-01 | 片头：四个结果 tile | README.md §1.1 |
| 2 | v2-02 | 卡片：fig3 SEW 进位切断 + 落点理由 | docs/stage1/02:1230-1233；docs/stage2/10 落点理由表 |
| 3 | v2-03 | 卡片：官方语义图原图 + 逐行对照七条 | docs/stage2/10 §1「赛题官方语义与逐行对照」；docs/_recon/figures/vdot_official_semantics.jpg |
| 4 | v2-04 | 终端：check_official_pseudocode.py 现场运行；sed 存档阴性对照行 | logs/stage2/p3_official_pseudocode_equiv.log:40,62 |
| 5 | v2-05 | 卡片：三条指令表 + 溢出证明、编码证明、参考模型 | docs/stage2/10 §1.0、§1.6、溢出证明；logs/stage2/check_funct6.log |
| 6 | v2-06 | 卡片：四个 tile（零新增、一行未改、163/164、13.7% 上界）+ 要点 | docs/stage2/10 复用清单、§结构计数；docs/stage2/11 §0；logs/stage2/p5_regression.log:52-53 |
| 7 | v2-07 | 终端：git apply --stat 两份补丁；sync_rtl_sources.sh --check | rtl/patch/；scripts/tools/sync_rtl_sources.sh |
| 8 | v2-08 | 卡片：fig1 vdot 波形 + 蝶形树要点 | docs/stage2/10 §加法树；docs/stage2/12 §10.2；docs/stage2/figures/fig1 |
| 9 | v2-09 | 卡片：fig2 vdotacc、fig3 vdot4a 波形 + 要点 | docs/stage2/12 §10.3–§10.4；docs/stage3/22 §7；docs/stage2/figures/fig2、fig3 |
| 10 | v2-10 | 终端：awk 选出 0x80×0x80 用例；YS_DUMP=1 ./build/emu 打印 REF 输入、期望、DUT 输出 | docs/stage2/12 §13.3；tests/vectors/negative.txt |
| 11 | v2-11 | 卡片：四个 tile + 全核复跑、故障注入、发现缺陷 | docs/stage2/12 §0.1–§0.2；logs/stage2/p5_summary.log:43；p5_fault_injection.log:273-274 |
| 12 | v2-12 | 终端：sed 存档 p5_summary.log；tail 故障注入汇总；grep 反向验证 | logs/stage2/p5_summary.log:5-43；p5_fault_injection.log；p5_decode_prove_fail.log:144 |
| 13 | v2-13 | 终端：vcd_extract.py --transactions；--signals … --at 21 23 25 | logs/stage2/waveform/vdotvv_vdottop_fuType10_seed1.vcd；docs/stage2/12 §10.2 |
| 14 | v2-14 | 结尾卡：阶段二四条结论 | — |

### 视频三：视频三 阶段三波形仿真与性能分析（`SNL-XiangShan-vdot-video3-stage3.mp4`）

| # | 分镜 | 画面 | 数据来源 |
|---|---|---|---|
| 1 | v3-01 | 片头：主结论三个数（1.70× / 1.81× / 2.25×）+ 全核 difftest + 协同仿真 | README.md §1.2 |
| 2 | v3-02 | 卡片：四个 tile + 两条要点 | docs/stage3/20 §1；logs/stage3/p5_vdot_tests.log:90-93,119,129；p5_fault_injection.log:191-192 |
| 3 | v3-03 | 终端：21_build_nemu_vdot.sh 现场运行（约 10 秒，编译缓存命中） | scripts/21_build_nemu_vdot.sh；logs/stage3/p5_vdot_tests.log |
| 4 | v3-04 | 卡片：协同仿真机制、结果、S-7' 来龙去脉 | docs/stage3/21 §2–§7；logs/stage3/cosim/p6_cosim_run.log:45-52；p6_fault_injection.log:358 |
| 5 | v3-05 | 终端：sed 存档 p6_cosim_run.log:45-52；grep 故障注入 | logs/stage3/cosim/p6_cosim_run.log:45-52；p6_fault_injection.log:358 |
| 6 | v3-06 | 卡片：四个 tile + 比对范围与局限 | docs/stage3/23 §0、§3–§6；logs/stage3/fullcore/summary.log:1-9；fault_summary*.log |
| 7 | v3-07 | 终端：sed 存档 summary.log；tail 故障注入汇总；现场运行 50_run_fullcore_difftest.sh wave-vl8；grep 本次运行日志 | logs/stage3/fullcore/summary.log:1-13；fault_summary.log；fault_summary_s3old.log；docs/stage3/23 §7.3 |
| 8 | v3-08 | 卡片：fig10 全核 vl=8 波形 + 读图说明 | docs/stage3/23 §7.3 图 10；logs/stage3/fullcore/wave_vl8_trace.txt:72-81；tests/riscv/fullcore/vdot_wave_vl8.S |
| 9 | v3-09 | 卡片：fig8 全核 vl=16 波形 + 要点 | docs/stage3/23 §7.2 图 8；logs/stage3/fullcore/wave_trace.txt:173-192 |
| 10 | v3-10 | 卡片：fig5 延迟波形、fig3 声明 vs 实测 + 要点 | docs/stage3/22 §4.2–§4.4；logs/stage3/p7_latency_measure.log:232-264；fig5、fig3 |
| 11 | v3-11 | 卡片：fig1 指令条数 + 基线序列与等价性 | docs/stage3/22 §2–§3；logs/stage3/p7_baseline_equiv.log:114-117,146；fig1 |
| 12 | v3-12 | 终端：sed 存档 p7_latency_measure.log、p7_baseline_equiv.log；grep perf_cycles.log；grep speedup.csv 主结论三行 | logs/stage3/p7_latency_measure.log:232-236；p7_baseline_equiv.log:110-117；perf_cycles.log:310-311；bench/results/speedup.csv |
| 13 | v3-13 | 卡片：主结论三个 tile + 参考口径表 + 适用范围 | README.md §1.2；docs/stage3/22 §5、§5.5、§12；bench/results/speedup.csv |
| 14 | v3-14 | 卡片：fig9 全核周期 + 实测对模型 | docs/stage3/22 §5.5.1–§5.5.5；logs/stage3/fullcore/perf_csrr_probe.log:4-9；fig9 |
| 15 | v3-15 | 卡片：fig4 敏感性 + 不利发现与全核检验 | docs/stage3/22 §6、§5.5.3–§5.5.5；bench/results/sensitivity.csv；fig4 |
| 16 | v3-16 | 卡片：局限性五条 | README.md 局限性；docs/stage3/22 §12；docs/stage3/23 §10 |
| 17 | v3-17 | 结尾卡：阶段三五条结论 | — |

## 重新生成

```bash
cd demo/video
# 依赖：Python 3 + Pillow + fontTools + imageio-ffmpeg（自带 ffmpeg；也可用 FFMPEG=/path/to/ffmpeg），asciinema（只在重录时需要）
# 字体：DejaVu Sans Mono（终端 ASCII）、WenQuanYi Zen Hei（中文）
# 0) （可选）重录终端演练并切片；日志写到 /tmp/rec，不覆盖仓库存档
asciinema rec --overwrite -q --cols 150 --rows 40 -c 'bash demo/video/rehearsal.sh' casts/rehearsal-2026-11-08.cast   # 在仓库根目录执行
asciinema rec --overwrite -q --cols 150 --rows 40 -c 'bash demo/video/rehearsal.sh stage1' casts/rehearsal-stage1-2026-11-08.cast
python3 splitcast.py casts/rehearsal-2026-11-08.cast casts/          # 先切主录像
python3 splitcast.py casts/rehearsal-stage1-2026-11-08.cast casts/   # 再用纯阶段一录像覆盖 v1-env / v1-nemu / v1-hello
# 1) 预览全部卡片到 build/cards/；文字、表格、tile 溢出或缺字形会直接报错
python3 make_video.py --cards
# 2) 渲染并拼接三段视频与 .srt（--video 2 只做第二段；--only v2-05,v2-11 只重渲染这几幕再拼接）
python3 make_video.py
# 3) 抽帧到 build/qa/ 目检
python3 make_video.py --qa
```

文件：`rehearsal.sh`（终端演练脚本）、`splitcast.py`（录像切幕）、`render.py`（终端模拟、时间映射与定格、角标、字幕、编码；缺字形即报错）、
`slides.py`（卡片绘制与「必须放得下」断言）、`storyboard.py`（分镜表：卡片内容 + 字幕 + 出处）、`make_video.py`（渲染、拼接、`.srt`、抽帧、分镜表导出）、
`casts/`（原始录制与切片）、`RECIPE-from-k1_opt.md`（方法来源）。`build/` 为中间文件，不入库。
