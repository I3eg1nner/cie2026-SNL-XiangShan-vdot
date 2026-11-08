#!/usr/bin/env python3
"""分镜表：三段视频的每一幕（卡片内容 + 字幕 + 数据来源）都只写在这里。
卡片由 slides.py 按 spec 绘制，字幕由 make_video.py 烧录并写入 .srt；改一句字幕只需 `--only <幕号>` 重渲染那一幕。
卡片上的数字逐个引自 spec['src'] 所列文档章节 / 日志行；终端幕的数字是画面里实际打印出的输出。

口径（全片统一）：headline 只用 MinimalConfig 全核实测 latency 加速比——单次 16 元素点积 1.70×（函数整体），
长向量稳态 1.81× / 2.25×（README.md §1.2、docs/stage3/22 §5.5 / §12、bench/results/speedup.csv）；
其余数字一律带性质标注（实测 / 源码推导 / 建模），未达或否定的结果照写。

终端幕的字幕锚点：('re:<正则>', 字幕, 定格秒数) —— 正则首次出现在输出里的时刻；定格秒数 > 0 时画面在该处停住供阅读，
右上角角标显示「定格」与录制时的实际耗时。
"""

TERM_RIGHT = '本机演练录制 2026-11-08 · Linux x86_64'

def term(id_, cast, title, caps, desc, src, **kw):
    return dict(id=id_, kind='term', cast=cast, title=title, caps=caps, desc=desc, src=src, right=kw.pop('right', TERM_RIGHT), **kw)

def card(id_, dur, spec, caps, desc, kind='card'):
    return dict(id=id_, kind=kind, dur=dur, spec=spec, caps=caps, desc=desc, src=spec.get('src', '—'))

# =====================================================================================================
# 视频一：阶段一操作过程
# =====================================================================================================
V1 = [
    card('v1-01', 12, dict(
        video='视频一　阶段一操作过程', sub='环境部署、NEMU 构建、hello 验证与 vadd.vv 波形分析',
        tiles=[('HIT GOOD TRAP', '1.1 环境验证（NEMU）', '裸机 RV64 程序经 UARTLITE 打印验证串；存档运行 8115 条指令', 'ok'),
               ('8369 条 / 68522 拍', '同一程序在 MinimalConfig 全核 emu', '带 difftest 运行，打印同一验证串，HIT GOOD TRAP', 'ok'),
               ('1 拍', 'vadd.vv 在 VIAluFix：in.fire → out.valid', '8/8 笔与香山声明值 CertainLatency(1) 一致', 'ours'),
               ('0 失配', 'vadd.vv 逐元素核验', '16 笔事务、78 个元素，掩码与尾部四种策略组合都在波形中', 'ours')],
        notes=['终端画面为本机一次完整演练的录制；全核构建（约 25 分钟）等长任务不在片中重跑，只展示仓库里已存档的运行结果，画面中逐处注明。',
               '加速与定格处右上角标出倍率和录制时的实际耗时。数字出处：README.md §1.1；docs/stage1/02_向量加法指令执行过程分析.md §0。'],
        src='README.md §1.1；docs/stage1/02 §0'),
        [(0, '视频一：阶段一操作过程。作品 XiangShan-vdot，参赛队伍 SNL，目标平台香山昆明湖 V2'),
         (6, '阶段一交付三样：环境验证输出、完整操作日志、vadd.vv 执行过程分析；先看结论，再看实际操作')],
        '片头：作品名、队伍、平台版本锁定；四个结果 tile', kind='title'),

    card('v1-02', 16, dict(
        title='阶段一思路：先选对分支，再按资源约束设计分层验证', src='docs/ppt/讲解大纲.md P3；docs/stage1/03 §7.1；docs/00_项目总览.md',
        tiles=[('kunminghu-v2', '赛题目标 = 昆明湖 V2 分支', 'master 已是昆明湖 V3，向量单元重写，不是赛题目标', 'ours'),
               ('40 GB 对 16 GB', '全核 Verilator 构建所需 JVM 堆 对 当时的建设机', '阶段一全核仿真如实标「未执行」；阶段三换服务器补做', 'acc'),
               ('L0–L5', '分层验证', '每层写明「证明了什么、证明不了什么」', 'ok')],
        bullets=['版本锁定：XiangShan a4eeaab（含 11 个子模块）、YunSuan 9559211、NEMU 9090839，一键脚本按 pin 克隆并核对',
                 '1.1 环境验证：裸机 RV64 程序在 NEMU 上自己通过 UARTLITE 串口打印验证串，横幅里的 CSR 由 csrr 实读',
                 '1.3 vadd.vv：执行与掩码 / 尾部段有 FU 级真实波形；取指、译码、重命名、写回的内部逻辑为源码级论证，标注文件行号',
                 '操作日志：logs/stage1/ 11 个文件、17826 行，含 4 次真实失败与修复；linux_repro/ 为 Linux 全新目录的一键复现记录',
                 '!阶段三在大内存服务器上补做全核仿真后，hello 与 vadd.vv 都补上了全核证据（构建峰值约 54–56 GiB 内存）']),
        [(0, '第一个决定是选对分支：赛题目标是昆明湖 V2，即 kunminghu-v2；master 已是昆明湖 V3，向量单元被重写'),
         (6, '第二个决定来自资源约束：全核仿真要约 40 GB JVM 堆，当时的机器只有 16 GB，所以设计了分层验证'),
         (11, '每层都写明能证明什么、不能证明什么；阶段三换到大内存服务器后补做了全核仿真')],
        '思路卡：分支选择、资源约束、分层验证、操作日志规模'),

    term('v1-03', 'v1-env.cast', '1.2 环境部署：纯阶段一工作目录，版本锁定与工具链核对',
         [('t:0', '工作目录是一套用一键脚本从零搭好的纯阶段一环境（NEMU 未打补丁）；日志、CSV、图都写到 /tmp/rec，不覆盖仓库存档', 0),
          ('re:NEMU\\s+9090839', '工作目录里三个仓库的 HEAD 与版本锁定文档一致：XiangShan a4eeaab、YunSuan 9559211、NEMU 9090839', 4),
          ('re:Verilator 5', 'JDK 必须是 17（21 / 25 会构建失败），Verilator 5.024 已就绪', 3),
          ('re:耗时     : 216', '已存档的运行结果：Linux 全新目录一键部署，按 pin 克隆并核对版本，rc 0，耗时 216 秒', 5)],
         '终端：export 日志目录、版本锁定表三行、work/ 三个仓库的 HEAD、JDK/Verilator 版本、存档的一键部署结尾',
         'docs/stage1/00_环境版本锁定.md；logs/stage1/linux_repro/00_setup_env_host.term.log:558-560,644-645'),

    term('v1-04', 'v1-nemu.cast', '1.2 NEMU 构建：独立解释器 + difftest 参考共享库',
         [('t:0', '02_build_nemu.sh 构建 NEMU 两种形态：独立解释器跑程序，difftest 参考共享库供阶段三协同仿真使用', 0),
          ('re:git rev-parse HEAD\\s+90908390', '构建前记录主机环境与 NEMU 提交号 9090839；配置 riscv64-xs-kmhv2', 3),
          ('re:riscv64-nemu-interpreter-so:', '两种形态都构建成功，最后把配置恢复为独立解释器；本机有编译缓存，现场约 8 秒（无缓存的全新目录存档为 31 秒）', 4),
          ('re:空输出 = 工作区干净', '工作区状态快照：NEMU 仍在 9090839，git status --short 为空输出，阶段一对上游 NEMU 零补丁', 5)],
         '终端：02_build_nemu.sh 现场运行（编译行已过滤）', 'scripts/02_build_nemu.sh；logs/stage1/linux_repro/README.md'),

    term('v1-05', 'v1-hello.cast', '1.1 环境验证：hello 程序在 NEMU 上运行，再看同一程序在全核 emu 上的存档',
         [('t:0', '03_run_hello.sh：先从真实网卡取本机 IP，再交叉编译一段裸机 RV64 程序', 0),
          ('re:grep -n -B2 -A3 vadd.vv', '证据：验证串只在程序的只读数据里，putch 内联为对 UARTLITE 发送寄存器的字节写', 4),
          ('re:result  = PASS', '在 NEMU 上实际执行：CSR 由 csrr 实读，VLEN = 128，vadd.vv 自检 16/16 通道一致', 5),
          ('re:total guest instructions = [0-9,]+', '打印 hello xiangshan, I am cie2026-vdot, IP address 172.100.0.6（本机网卡地址），HIT GOOD TRAP；本次 8,189 条指令', 4),
          ('re:\\d+:.*total guest instructions', '日志自动落盘，即 1.2 的操作日志；README 存档运行在另一台机器（IP 192.168.30.213）上，为 8115 条指令，与本次不同', 4),
          ('re:instrCnt = 8369', '已存档的运行结果：同一程序在 MinimalConfig 全核 emu 上带 difftest 运行，同一验证串，8369 条指令、68522 拍', 6)],
         '终端：03_run_hello.sh 现场运行（取 IP、交叉编译、strings/objdump 证据、NEMU 执行、HIT GOOD TRAP），grep 本次日志，grep 全核存档日志',
         'scripts/03_run_hello.sh；logs/stage1/p1_hello_xiangshan_fullcore.log:67,76-77'),

    term('v1-06', 'v1-wave.cast', '1.3 vadd.vv 执行过程：读存档波形（VCD）与全核文本轨迹',
         [('t:0', '读仓库存档的 VCD：YunSuan 功能单元级平台上 vadd.vv 走 VIAluFix 路径的真实波形', 0),
          ('re:7      63      65', '8 笔事务 in.fire → out.valid 都是 1 拍，与香山 VialuCfg 的 CertainLatency(1) 一致', 5),
          ('re:tail OK\\s+$', '按 SEW 切出元素逐个核对加法、掩码与尾部；两份波形 16 笔事务、78 个元素 0 失配', 5),
          ('re:1494   ROB-COMMIT slot0   vadd', '全核存档轨迹：1483 进译码，1488 发射，1491/1492 在 VIAluFix 1 拍，1494 提交', 6)],
         '终端：vcd_extract.py --transactions / --verify 读存档 VCD；sed 全核轨迹 wave_trace.txt:150-181',
         'logs/stage1/waveform/vaddvv_vialufwrapper_fuType5_seed2.vcd；logs/stage3/fullcore/wave_trace.txt:150-181'),

    card('v1-07', 18, dict(
        title='vadd.vv 波形：握手 1 拍、按 SEW 切断进位、掩码与尾部策略', src='docs/stage1/02 §0、§5.4、§6.3；docs/stage1/figures/fig1、fig3、fig4',
        figs=['docs/stage1/figures/fig1_handshake_latency.png', 'docs/stage1/figures/fig4_mask_tail_agnostic.png'], split=0.36,
        bullets=['图 1：in.fire → out.valid 1 拍，8/8 笔与 CertainLatency(1) 一致',
                 '加法链按 SEW 在段边界切断进位（8 个 Adder_8b 串成链，图 3）',
                 '图 4：ma=1 掩码位写全 1、ta=1 尾部写全 1；ta=0 保留旧值也在波形中直接看到',
                 '16 笔事务、78 个元素逐元素核验 0 失配',
                 '!FU 级平台的 out.valid 由平台计数器产生；延迟结论与源码声明值互相印证']),
        [(0, '图 1：握手与 1 拍延迟；8 笔事务都在 in.fire 后一个时钟沿给出结果'),
         (6, '图 4：mask-agnostic 与 tail-agnostic 写全 1；tail-undisturbed 保留旧值，四种组合都在波形里'),
         (12, 'vadd 的加法链按 SEW 在段边界切断进位，后面的 vdot 恰好相反，要跨段把乘积加起来')],
        '卡片：fig1 握手与延迟、fig4 掩码尾部 + 五条要点'),

    card('v1-08', 18, dict(
        title='阶段三补做：MinimalConfig 全核波形中一条 vadd.vv 从译码到提交', src='docs/stage1/02 §8.4.1；logs/stage3/fullcore/wave_trace.txt:150-181；fig7',
        figs=['docs/stage1/figures/fig7_fullcore_vadd_pipeline.png'], split=0.40,
        bullets=['1483 进译码 → 1484 译出 → 1485 重命名 → 1486 进发射队列',
                 '1488 发射 → 1491/1492 在 VIAluFix 中 1 拍 → 1492 写物理寄存器 → 1494 ROB 提交',
                 '全核里 FU 内仍是 1 拍，与 FU 级波形一致',
                 '每一级都有了全核时刻锚点；各级内部如何工作仍以源码论证为准',
                 '!这是 MinimalConfig 下一条 vadd 的单次执行，前面紧跟 fence，流水线几乎是空的；全核 VCD 约 382 MB，不入库']),
        [(0, '阶段三有了全核仿真器后，把全核波形中的一条 vadd.vv 从译码到提交完整画出，就是图 7'),
         (7, '1483 拍进译码，1488 拍发射，功能单元里同样是 1 拍，1494 拍提交'),
         (12, '需要说明：这是 MinimalConfig 下一次执行，流水线几乎为空；各级内部逻辑仍以源码论证为准')],
        '卡片：fig7 全核 vadd 流水线 + 要点'),

    card('v1-09', 12, dict(
        title='阶段一小结',
        bullets=['1.1 环境验证：NEMU 上 hello xiangshan + HIT GOOD TRAP；同一程序在 MinimalConfig 全核 emu + difftest 上同样通过',
                 '1.2 操作日志：logs/stage1/（11 个文件、17826 行，含 4 次真实失败与修复）与 linux_repro/ 一键复现记录',
                 '1.3 执行过程：docs/stage1/02_向量加法指令执行过程分析.md，FU 级真实波形 + 源码级论证 + 全核时刻锚点',
                 '通向阶段二：vadd 按 SEW 切断进位，vdot 要跨 16 个元素打通求和；控制骨架可以全部复用']),
        [(0, '阶段一小结：环境验证、操作日志、vadd.vv 执行过程三项交付齐备，全部可按文档里的命令复现'),
         (6, '下一段视频讲阶段二：vdot 的语义、与赛题官方伪代码的对照、微架构与三项测试')],
        '结尾卡：阶段一三项交付与通向阶段二', kind='closing'),
]

# =====================================================================================================
# 视频二：阶段二解题思路
# =====================================================================================================
V2 = [
    card('v2-01', 12, dict(
        video='视频二　阶段二解题思路', sub='vdot 语义、官方伪代码对照、微架构、数据通路、RTL 与三项测试',
        tiles=[('20570 条 0 失配', 'vl = 8 时与赛题官方伪代码逐位等价', '伪代码字面实现 对 C 参考模型；阴性对照 532 条全部失配', 'ok'),
               ('290175 条 0 失败', 'FU 级功能测试合计', '正数 132、负数 144、边界 436；随机差分 235348', 'ok'),
               ('零新增乘法阵列', '最大限度复用 VIMacU', 'FuConfig / FuType / Dispatch / IQ 一行未改，延迟保持 2 拍', 'ours'),
               ('6/6 检出', 'RTL 故障注入', '含「回退 S-3\'」；撤掉 LMUL 守卫 13 条立刻变红', 'acc')],
        notes=['数字出处：README.md §1.1；docs/stage2/10_vdot指令设计文档.md §1；docs/stage2/12_基础功能测试报告.md §0.1。',
               '终端画面为本机一次完整演练的录制；功能测试全集（约 5 分钟）不在片中重跑，只展示已存档的运行结果，画面中注明。'],
        src='README.md §1.1'),
        [(0, '视频二：阶段二解题思路。讲 vdot 的语义、与官方伪代码的对照、微架构、数据通路和三项测试'),
         (6, '核心思路两条：最大限度复用昆明湖 V2 的向量实现；每个数字都能在仓库日志里按行号找到')],
        '片头：四个结果 tile', kind='title'),

    card('v2-02', 16, dict(
        title='从 vadd 到 vdot：「切断跨段进位」与「打通跨段求和」', src='docs/stage1/02:1230-1233；docs/stage2/10 落点理由表',
        figs=['docs/stage1/figures/fig3_sew_carry_boundary.png'], split=0.44,
        bullets=['vadd.vv 的 64 位加法链按 SEW 在段边界切断进位；vdot 恰好相反，要跨 16 个元素打通求和',
                 '译码 → 拆分 → 重命名 → 分发 → 发射 → 写回这条控制骨架，vdot 可以完全复用',
                 '落点 VIMacU：昆明湖 V2 上 16 路 8×8 有符号乘法阵列唯一的现成实现（2 片 VIMac64b）',
                 '不新增 FuType：它是 one-hot 枚举，加一项会加宽 IQ / ROB / 旁路网络的字段']),
        [(0, '阶段一的波形分析直接决定了阶段二的落点：vadd 按 SEW 切断进位，vdot 要把 16 个乘积跨段加起来'),
         (6, '控制骨架全部复用，只需新建归约数据通路；最贵的乘法阵列在昆明湖 V2 上只有 VIMacU 里有'),
         (11, '所以 vdot 挂在 VIMacU 上，而不是新开一个功能单元类型')],
        '卡片：fig3 SEW 进位切断 + 落点理由'),

    card('v2-03', 22, dict(
        title='赛题官方伪代码逐行对照：vl = 8 时逐位等价（语义修订 S-3\'）', src='docs/stage2/10 §1「赛题官方语义与逐行对照」；docs/_recon/figures/vdot_official_semantics.jpg',
        figs=['docs/_recon/figures/vdot_official_semantics.jpg'], split=0.52, bsize=24,
        bullets=['第 1 行 sew=8 ↔ 只有 SEW = 8 合法',
                 '第 2、4 行「各取 8 个」↔ 取元素 0..vl-1，vl = 8 时恰为这 8 个',
                 '第 5 行 符号扩展相乘累加 ↔ 相同',
                 '第 7 行 vd[0] = result ↔ vd[31:0]（目的元素 EEW = 32）',
                 '第 8 行 vd[1..VLEN-1] = 0 ↔ vd[127:32] 恒为 0，与 vta / vma 无关（S-3\'）',
                 '「8」的来源：题源 VDOTU 一个 64 位寄存器装 8 个 int8；保留 vl，vl = 16 是满寄存器版本',
                 '!「清零」不属于 tail-agnostic 允许的取值（只能保留原值或写全 1），因此定义为整寄存器结果、无 tail']),
        [(0, '赛题页给出了 vdot.vv 的官方语义：8 行伪代码，两个源寄存器各取 8 个 int8，符号扩展相乘求和写 vd[0]'),
         (7, '逐行对照：主体与本项目一致；最后一行要求其余通道清零，本项目据此修订为 S-3\'，高 96 位恒为 0、与 vta 无关'),
         (14, '保留 vl 机制：vl = 8 就是官方伪代码，vl = 16 是 VLEN = 128 的满寄存器版本；伪代码没规定的部分才是工程化规定')],
        '卡片：官方语义图原图 + 逐行对照七条'),

    term('v2-04', 'v2-official.cast', '官方伪代码等价核对：伪代码字面实现 对 C 参考模型（现场运行）',
         [('t:0', '脚本按伪代码字面实现，不引用参考模型代码；在 vl = 8、vm = 1、vstart = 0 下比对 vd 的全部 128 位', 0),
          ('re:20570 cases, 0 mismatches', '语料 285 + 285 条、随机 10000 + 10000 条（vd 初值、vta、vma、高 8 个元素全随机），20570 条 0 失配', 6),
          ('re:532 mismatches', '已存档的阴性对照：拿修订前 S-3 的语料去比，532 条全部失配，说明检查能区分新旧语义', 5)],
         '终端：check_official_pseudocode.py 现场运行；sed 存档阴性对照行',
         'logs/stage2/p3_official_pseudocode_equiv.log:40,62'),

    card('v2-05', 18, dict(
        title='vdot 指令族：一条赛题指令 + 两条共享数据通路的扩展', src='docs/stage2/10 §1.0、§1.6、溢出证明；logs/stage2/check_funct6.log',
        table=dict(size=28, line=40, cols=[(0, 230, '指令'), (230, 170, 'funct6'), (400, 860, '语义'), (1260, 540, '定位')], rows=[
            [('vdot.vv', 'ours'), '111001', 'SEW = 8，元素 0..vl-1 的 int8×int8 乘积归约到 vd[31:0]，vd[127:32] 恒为 0', '赛题要求；vl = 8 即官方伪代码'],
            [('vdotacc.vv', 'ours'), '111010', '累加变体：vd[31:0] += Σ，其余位同样清零', '扩展：长向量循环省掉独立累加'],
            [('vdot4a.vv', 'ours'), '111011', 'SEW = 32 下 4 组 × 4 路分组点积累加', '扩展：对标 SDOT / VPDPBUSD 风格']]),
        bullets=['溢出证明：16 项和 |Σ| ≤ 262144 = 2^18 < 2^31，不需要饱和逻辑',
                 '编码由本项目选定（赛题语义图未给编码）：funct6 111001 / 111010 / 111011 在 OPIVV 空间未被 RVV 1.0 占用，由脚本枚举证明',
                 'vstart、掩码、vl = 0 等边角行为逐条裁定，写进 C 参考模型 tests/golden/vdot_ref.c，全项目唯一语义来源，各测试平台直接包含它']),
        [(0, '三条指令：赛题要求的 vdot.vv，以及共享同一套硬件的累加版 vdotacc 和 SEW = 32 的分组版 vdot4a'),
         (6, '16 项和最大 262144，即 2 的 18 次方，小于 2 的 31 次方，不需要饱和逻辑'),
         (12, '编码空间由脚本证明空闲；边角语义逐条裁定，写进唯一的 C 参考模型，所有测试平台直接包含它')],
        '卡片：三条指令表 + 溢出证明、编码证明、参考模型'),

    card('v2-06', 16, dict(
        title='微架构亮点一：最大限度复用——零新增乘法阵列', src='docs/stage2/10 复用清单、§结构计数；docs/stage2/11 §0；logs/stage2/p5_regression.log:52-53',
        tiles=[('0 个', '新增乘法阵列', '从 2 片 VIMac64b 引出 16 个部分积，只加只读端口 prod16（+7 行）', 'ok'),
               ('一行未改', 'FuConfig / FuType / Dispatch / IQ 等', 'vdot 挂在既有 VimacCfg，CertainLatency(2) 不变', 'ok'),
               ('163 / 164', '共有 module 去注释后逐字节相同', '差异仅顶层 SimTop；9 个既有 FU 输出与基线逐字相同', 'ours'),
               ('约 13.7%', '新增算术逻辑（结构计数上界）', '未综合；不是面积测量值', 'acc')], tile_h=210,
        bullets=['加法树全部例化 YunSuan 既有原语 CSA4to2 / CSA3to2',
                 '既有 vmul / vwmul / vmacc 的数据成形拍仍为 2 拍（实测），没有被拖慢',
                 '!13.7% 是全加器等价结构计数的上界，没有做综合；时序、面积、功耗都未知']),
        [(0, '赛题要求复用昆明湖 V2 的向量实现：点积最贵的乘法阵列一个都没造，从两片 VIMac64b 引出 16 个乘积'),
         (6, '调度相关配置一行未改，延迟仍是 2 拍，发射、唤醒、写回网络完全不受影响'),
         (11, '13.7% 是从结构里数出来的上界，没有做综合，这一点在局限里如实写明')],
        '卡片：四个 tile（零新增、一行未改、163/164、13.7% 上界）+ 要点'),

    term('v2-07', 'v2-rtl.cast', 'RTL 改动以标准补丁交付：改动统计与交付副本一致性自检（现场运行）',
         [('t:0', 'git apply --stat 只读统计两份补丁：改动集中在 VIMacU、VDotTree、译码表与异常判定', 0),
          ('re:5 files changed, 338', '调度相关的文件不在列表里；YunSuan 侧新增 VDotTop 与 VDotTree 两个模块', 5),
          ('re:RTL-SYNC-CHECK: PASS', 'rtl/chisel/ 是补丁打完后的只读阅读副本：三份补丁干净应用，15 个文件逐字节相同', 5)],
         '终端：git apply --stat 两份补丁；sync_rtl_sources.sh --check', 'rtl/patch/；scripts/tools/sync_rtl_sources.sh'),

    card('v2-08', 18, dict(
        title='微架构亮点二：XOR 蝶形折叠加法树——一棵树、两种形态', src='docs/stage2/10 §加法树；docs/stage2/12 §10.2；docs/stage2/figures/fig1',
        figs=['docs/stage2/figures/fig1_vdot_wave.png'], split=0.40, bsize=25,
        bullets=['同一组 12 个 CSA4to2(32) 同时覆盖 16 路全归约（foldLevels = 2）与 4 组 × 4 路（foldLevels = 0）',
                 '伙伴 lane 取 g XOR Δ（Δ = 1、2）：4 个 lane 做完全相同的运算，全折叠时都持有总和',
                 '取元素 0 无需选择逻辑；模式切换只作用在加数输入端的 AND 门，结果路径零选择器',
                 '波形：全 0x80 × 0x80 时 io_dotVd 的 4 个 lane 都是 0x40000 = 262144']),
        [(0, 'vdot 要把 16 个乘积加成 1 个数，vdot4a 要加成 4 个独立的数；我们用一棵树加两位折叠控制解决'),
         (6, '每一级伙伴 lane 用异或算出，4 个 lane 做同样的事，全折叠时每个 lane 都是总和，结果路径上没有选择器'),
         (12, '波形直接证据：全负数最大值输入时，四个 lane 都是 262144')],
        '卡片：fig1 vdot 波形 + 蝶形树要点'),

    card('v2-09', 16, dict(
        title='微架构亮点三：三条指令共享一条数据通路，延迟保持 2 拍', src='docs/stage2/12 §10.3–§10.4；docs/stage3/22 §7；docs/stage2/figures/fig2、fig3',
        figs=['docs/stage2/figures/fig2_vdotacc_wave.png', 'docs/stage2/figures/fig3_vdot4a_wave.png'], split=0.40, bsize=24,
        bullets=['区别只在两处：foldLevels（0 / 2）与累加注入（vdotacc 只注入 lane 0，vdot4a 注入 4 个 lane）',
                 '左：vdotacc lane 0 = 2496，其余 lane 1496',
                 '右：vdot4a 4 组结果 846 / 446 / 174 / 30',
                 '!延迟提到 3 拍的方案被否决：会让十几条既有乘法指令集体慢一拍；塞进 2 拍的依据是静态估算，未综合']),
        [(0, '三条指令共用同一乘法阵列和同一棵树，区别只是折叠几级、累加值注入哪个 lane'),
         (6, '左图 vdotacc 只有 lane 0 加上了累加值；右图 vdot4a 四个 lane 各出一个结果'),
         (11, '延迟保持 2 拍：提到 3 拍会拖慢十几条既有指令；能塞进 2 拍的依据是静态估算，没做综合')],
        '卡片：fig2 vdotacc、fig3 vdot4a 波形 + 要点'),

    term('v2-10', 'v2-dut.cast', '单条定向用例：0x80 × 0x80 符号扩展陷阱，输入 / 期望 / DUT 实测（现场运行）',
         [('t:0', '从负数语料里挑出全 0x80 × 0x80 的一条，用已构建的 FU 级 Verilator 平台单独跑', 0),
          ('re:case #0 : MATCH', '-128 × -128 = +16384，16 项和 262144 = 0x40000；期望与 DUT 输出逐位相同，高 96 位为 0', 7),
          ('re:EMU has executed', '期望值来自 tests/golden/vdot_ref.c，测试平台直接包含它，不重写语义', 3)],
         '终端：awk 选出 0x80×0x80 用例；YS_DUMP=1 ./build/emu 打印 REF 输入、期望、DUT 输出',
         'docs/stage2/12 §13.3；tests/vectors/negative.txt'),

    card('v2-11', 18, dict(
        title='三项基础功能测试：正数 / 负数 / 边界全覆盖，并证明测试「会红」', src='docs/stage2/12 §0.1–§0.2；logs/stage2/p5_summary.log:43；p5_fault_injection.log:273-274',
        tiles=[('132 / 144 / 436', '正数 / 负数 / 边界（FU 级）全 PASS', '边界 436 = 规范 306 + 非规范放宽 130；三项各含 vl = 8 定向用例 12 条', 'ok'),
               ('235348', '随机差分 0 失配', '对 tests/golden/vdot_ref.c', 'ok'),
               ('26060', '直驱真正集成的 VIMacU 0 失配', '不只测独立的 VDotTop', 'ok'),
               ('290175 / 0', 'FU 级合计：执行 / 失败', '其中 vdot 用例 262171 条；9358 条按规范跳过', 'ours')], tile_h=215,
        bullets=['全核（MinimalConfig + difftest）复跑同一语料：正数 132/132、负数 144/144、边界 333/333，27 条必须 trap 全部 mcause = 2',
                 '测试会红：故障注入 6/6 被检出（含把写回改回旧 S-3 的「回退 S-3\'」）；撤掉 LMUL 守卫后译码级 13 条立刻变红',
                 '!测试中发现并修复了一个 RTL 缺陷：香山译码侧原本不拦截 LMUL ≠ 1 的 vdot，会静默算错']),
        [(0, '正数 132 条、负数 144 条、边界 436 条全部通过，每项都含 vl = 8 的用例，即官方伪代码的配置'),
         (6, '随机差分 23 万多条、直驱 VIMacU 26060 条；这些是 FU 级 Verilator 结果，同一语料后来又在全核上 0 失配'),
         (12, '测试会红：6 个人为缺陷全部被抓到；测试中还真的发现并修复了 LMUL ≠ 1 不报非法的 RTL 缺陷')],
        '卡片：四个 tile + 全核复跑、故障注入、发现缺陷'),

    term('v2-12', 'v2-tests.cast', '功能测试汇总与故障注入（已存档的运行结果）',
         [('t:0', '功能测试全集约 5 分钟，片中不重跑，展示仓库里已存档的汇总表', 0),
          ('re:合计\\s+290175', '正数、负数、边界、随机差分、既有指令回归、VIMacU 直驱逐项 PASS；合计 290175 条执行、0 失败', 7),
          ('re:PASS 38，FAIL 13', '故障注入 6/6 被检出；撤掉 LMUL 守卫后，51 条译码级定向用例中 13 条变红', 5)],
         '终端：sed 存档 p5_summary.log；tail 故障注入汇总；grep 反向验证',
         'logs/stage2/p5_summary.log:5-43；p5_fault_injection.log；p5_decode_prove_fail.log:144'),

    term('v2-13', 'v2-wave.cast', 'vdot.vv 波形逐拍：读存档 VCD（全 0x80 × 0x80）',
         [('t:0', '读仓库存档 VCD：vdot.vv 一笔事务，in.fire 在 #21，结果在 #25 成形，2 个时钟周期', 0),
          ('re:#25\\s+0+40000', '#23：16 个乘积都是 0x4000、foldLevels = 2；#25：io_dotVd 四个 lane 都是 0x40000，XOR 蝶形的直接证据', 7),
          ('re:#25\\s+0+40000', 'io_vd 元素 0 = 262144，vd[127:32] 为 0：这笔激励 vta = 1，按 S-3\' 也不再写全 1', 5)],
         '终端：vcd_extract.py --transactions；--signals … --at 21 23 25',
         'logs/stage2/waveform/vdotvv_vdottop_fuType10_seed1.vcd；docs/stage2/12 §10.2'),

    card('v2-14', 12, dict(
        title='阶段二小结',
        bullets=['语义：与赛题官方伪代码逐行对照，vl = 8 时逐位等价（20570 条 0 失配，阴性对照 532 条全部失配）',
                 '复用：乘法阵列零新增，调度配置一行未改，延迟保持 2 拍；新增逻辑约 13.7%（结构计数上界，未综合）',
                 '数据通路：XOR 蝶形折叠加法树，三条指令共享一条通路，结果路径零选择器',
                 '测试：正数 132、负数 144、边界 436 全 PASS，合计 290175 条 0 失败；故障注入 6/6 检出']),
        [(0, '阶段二小结：语义对齐官方伪代码，复用为先，蝶形树共享通路，测试能发现错误'),
         (6, '下一段视频讲阶段三：NEMU 扩展、协同仿真、全核 difftest、波形与加速比')],
        '结尾卡：阶段二四条结论', kind='closing'),
]

# =====================================================================================================
# 视频三：阶段三波形仿真与性能分析
# =====================================================================================================
HEADLINE = 'MinimalConfig 全核实测 latency 加速比：单次 16 元素点积 1.70×（函数整体），长向量稳态 1.81× / 2.25×'

V3 = [
    card('v3-01', 14, dict(
        video='视频三　阶段三波形仿真与性能分析', sub='NEMU 扩展、协同仿真、全核 difftest、波形与加速比',
        tiles=[('1.70×', '单次 16 元素点积（函数整体）', 'MinimalConfig 全核实测：52 → 30.5 拍，含装载与取回', 'ours'),
               ('1.81× / 2.25×', '长向量稳态吞吐', 'vdotacc 单累加器 / 2 路累加器：12.64 → 7.00 / 5.63 拍每 16 个 int8', 'ours'),
               ('24,524,262', 'MinimalConfig 全核 difftest 提交数', '0 失配；语料 30794/30794，4834 条必须 trap 全部 mcause = 2', 'ok'),
               ('72794', 'NEMU ↔ RTL 协同仿真激励', '值比对 55960/55960，非法判定分歧 0', 'ok')],
        notes=['适用范围：香山 MinimalConfig 全核 emu、热态、带 difftest；默认配置（KunminghuV2Config）未测。出处：README.md §1.2；docs/stage3/22 §5.5、§12；bench/results/speedup.csv。',
               '终端画面为本机一次完整演练的录制；全核构建与全核长任务不在片中重跑，只展示已存档的运行结果，画面中注明。'],
        src='README.md §1.2'),
        [(0, '视频三：阶段三波形仿真与性能分析。先报主结论：' + HEADLINE),
         (7, '适用范围：MinimalConfig 全核、热态、带 difftest；默认配置未测。其余口径都是参考，后面逐项说明')],
        '片头：主结论三个数（1.70× / 1.81× / 2.25×）+ 全核 difftest + 协同仿真', kind='title'),

    card('v3-02', 14, dict(
        title='3.1.1 NEMU 指令扩展：30794 条语料 0 失配，两种形态', src='docs/stage3/20 §1；logs/stage3/p5_vdot_tests.log:90-93,119,129；p5_fault_injection.log:191-192',
        tiles=[('30794 / 0', '独立解释器：语料 / 失配', '14 个 suite，逐条回读 vd', 'ok'),
               ('4834', '必须 trap 的用例', '全部以 mcause = 2 trap', 'ok'),
               ('trap code:0', 'difftest 参考共享库 .so', '同一语料 HIT GOOD TRAP，协同仿真的前提', 'ok'),
               ('6/6', 'NEMU 故障注入检出', '含「回退 S-3\'」；另 1 个经论证的等价变异体', 'acc')],
        bullets=['按 NEMU 的 def_INSTR_TAB 译码机制接入三条指令，由 CONFIG_CUSTOM_XVDOT 开关控制',
                 '补丁在干净副本上重跑同样 30794/30794；补丁幂等应用']),
        [(0, 'NEMU 扩展按它自己的译码表机制接入三条指令；独立解释器跑 30794 条语料 0 失配'),
         (6, '4834 条必须 trap 的用例全部报非法指令；参考共享库上同一语料 HIT GOOD TRAP，这是协同仿真的前提')],
        '卡片：四个 tile + 两条要点'),

    term('v3-03', 'v3-nemu.cast', '3.1.1 NEMU 扩展：打补丁、构建两种形态、跑 30794 条语料（现场运行）',
         [('t:0', '21_build_nemu_vdot.sh：补丁幂等应用，再构建独立解释器与参考共享库两种形态（编译行已过滤）', 0),
          ('re:ee2081d7', '6 条被测指令以自定义 OPIVV 编码出现在镜像 .text 里', 4),
          ('re:vdot4a_boundary\\s+115', '独立解释器逐 suite 结果：14 个 suite、30794 条全部 pass，必须 trap 的用例全部按 mcause = 2 trap', 6),
          ('re:RESULT: PASS', '参考共享库上同一语料 HIT GOOD TRAP；TOTAL cases = 30794，pass = 30794，fail = 0', 5)],
         '终端：21_build_nemu_vdot.sh 现场运行（约 10 秒，编译缓存命中）', 'scripts/21_build_nemu_vdot.sh；logs/stage3/p5_vdot_tests.log'),

    card('v3-04', 20, dict(
        title='3.1.2 协同仿真 Level 1：真实 NEMU .so 对 Verilated 译码单元 + vdot 功能单元', src='docs/stage3/21 §2–§7；logs/stage3/cosim/p6_cosim_run.log:45-52；p6_fault_injection.log:358',
        bullets=['REF：dlopen 真实 riscv64-nemu-interpreter-so，经 difftest 原生 C API 逐条驱动；平台内不含任何 vdot 语义代码',
                 'DUT：Verilated VDotTop（算值）+ 真实 DecodeUnit 与 VecExceptionGen（判非法）',
                 '每条激励：拷指令 → 拷寄存器 → 执行 fence.i → 执行被测 vdot → 取回寄存器比对。fence.i 是踩过的坑：NEMU 按 PC 缓存译码',
                 '72794 条激励：值比对 55960/55960 0 失配；非法判定合法一致 55960、非法一致 16834、分歧 0',
                 '首轮 6415 条判定分歧 = LMUL 守卫未同步 4469 + vdot4a 在 vstart ≠ 0 时的 1946；设计阶段 R-06 已识别、当时判为不可达',
                 '裁定 S-7\'：vdot4a 在 vstart ≠ 0 时同样非法，RTL 一行未改，分歧 6415 → 0；故障注入 7/7 检出',
                 '!Level 1 证明不了乱序流水线里的发射、旁路、提交与异常投递，由下一级全核 difftest 补上']),
        [(0, '协同仿真 Level 1：参考端是真实 NEMU 共享库，被测端是 Verilated 的 vdot 功能单元和真实译码单元'),
         (7, '每条激励前先执行 fence.i：NEMU 按 PC 缓存译码，同一 PC 反复改写指令会复用旧译码'),
         (14, '首轮 6415 条分歧中 1946 条来自设计阶段已识别、判为不可达的 vstart 问题；裁定 S-7\' 后分歧归零')],
        '卡片：协同仿真机制、结果、S-7\' 来龙去脉'),

    term('v3-05', 'v3-cosim.cast', '协同仿真结果与故障注入（已存档的运行结果）',
         [('t:0', '协同仿真一次约 4 分钟，片中展示仓库存档的结果行', 0),
          ('re:RESULT\\(LEGALITY\\): PASS', '72794 条激励：值比对 55960 条全 PASS；非法判定分歧 0', 6),
          ('re:7/7 被检出', 'RTL 侧 3 次、NEMU 侧 4 次注入，7/7 被检出；T3-NEMU-3 守护 S-7\'，T3-NEMU-4 守护 S-3\'', 5)],
         '终端：sed 存档 p6_cosim_run.log:45-52；grep 故障注入', 'logs/stage3/cosim/p6_cosim_run.log:45-52；p6_fault_injection.log:358'),

    card('v3-06', 16, dict(
        title='3.1.2 Level 2：打了 vdot 补丁的昆明湖 V2 全核（MinimalConfig）与 NEMU 逐条提交比对', src='docs/stage3/23 §0、§3–§6；logs/stage3/fullcore/summary.log:1-9；fault_summary*.log',
        tiles=[('30794 / 30794', '全核语料', '4834 条必须 trap 全部 mcause = 2；6/6 HIT GOOD TRAP', 'ok'),
               ('0 失败', '10 个依赖内核 × 4 个种子', 'RAW / WAR / WAW、经访存、掩码依赖、分支冲刷等', 'ok'),
               ('24,524,262', '提交 0 失配（27,104,437 周期）', '10/10 次 HIT GOOD TRAP', 'ok'),
               ('3/3 + 3/3', '全核故障注入', 'VIMacU 结果 bit0 翻转；写回退回旧 S-3 的全 1（s3old）', 'acc')], tile_h=210,
        bullets=['每提交一条指令比对整数 / 浮点 / 向量寄存器堆与向量 CSR、mstatus、mcause',
                 '!只构建、运行了 MinimalConfig：功能结论有参数一致性论证，周期数只对 MinimalConfig 成立；LMUL ≠ 1 未在全核复测',
                 '!全核构建约 25 分钟、峰值 50 多 GiB 内存，全量运行约 1 小时，片中只展示存档结果']),
        [(0, 'Level 1 证明不了流水线行为，于是在大内存服务器上补做全核 difftest：MinimalConfig 全核与同一个 NEMU 逐条比对'),
         (7, '语料 30794 条全过，依赖测试 0 失败，合计 24,524,262 条提交 0 失配；两种故障注入各 3/3 检出'),
         (12, '只跑了 MinimalConfig，不说默认配置全核通过')],
        '卡片：四个 tile + 比对范围与局限'),

    term('v3-07', 'v3-fullcore.cast', '全核 difftest：存档汇总 + vl = 8 主演示现场运行',
         [('t:0', '已存档的运行结果：全核 difftest 一次约 1 小时，展示汇总', 0),
          ('re:RESULT: PASS', '6 批语料 30794/30794，必须 trap 的 4834 条全部 mcause = 2，6/6 HIT GOOD TRAP，失配报告 0 行；依赖测试 RESULT: PASS', 6),
          ('re:FAULT-INJECTION \\(s3old\\)', '故障注入两种各 3/3：bit0 翻转，以及把写回改回旧 S-3 的全 1，全核比对能区分新旧语义', 4),
          ('re:VIMACU-OUT\\s+robIdx=21', '现场运行 vl = 8 主演示（只需已构建的 emu）：vdot 出 VIMacU 得 0xcc = 204，vdotacc 得 0x4b4 = 1000 + 204', 6),
          ('re:instrCnt = 49', '程序自己比对结果、csrr 读回 vl = 8，HIT GOOD TRAP，difftest 0 失配', 4)],
         '终端：sed 存档 summary.log；tail 故障注入汇总；现场运行 50_run_fullcore_difftest.sh wave-vl8；grep 本次运行日志',
         'logs/stage3/fullcore/summary.log:1-13；fault_summary.log；fault_summary_s3old.log；docs/stage3/23 §7.3'),

    card('v3-08', 20, dict(
        title='全核波形主演示（vl = 8，与赛题官方伪代码同一配置）', src='docs/stage3/23 §7.3 图 10；logs/stage3/fullcore/wave_vl8_trace.txt:72-81；tests/riscv/fullcore/vdot_wave_vl8.S',
        figs=['docs/stage3/figures/fig10_fullcore_vdot_vl8_wave.png'],
        foot='vsetivli zero, 8, e8, m1, ta, ma（vta = 1）；vs1、vs2 低 8 字节 = 1..8，高 8 字节填无关值 0x7f / 0x80，vd 预填垃圾值。1497 进 VIMacU → 1499 出：vd = …000000cc（Σ i² = 204；若高 8 字节参与会是 0xfffe04cc），元素 1..3 清零 → 1501 提交；vdotacc 1000 + 204 = 0x4b4，1502 提交'),
        [(0, '与赛题官方伪代码同一配置：vl = 8，vta = 1；源寄存器高 8 字节故意填无关值，vd 预先填垃圾值'),
         (7, '1497 拍进 VIMacU，1499 拍出：vd 低 32 位是 0xcc，即 1 到 8 的平方和 204，高 8 字节没有参与'),
         (14, '元素 1 到 3 全部清零，与 vta 无关；1501 拍提交，vdotacc 在 1000 上累加得 0x4b4')],
        '卡片：fig10 全核 vl=8 波形 + 读图说明'),

    card('v3-09', 16, dict(
        title='补充：vl = 16 满寄存器版本，看流水线（vadd → vdot → vdotacc → vdot4a 依赖链）', src='docs/stage3/23 §7.2 图 8；logs/stage3/fullcore/wave_trace.txt:173-192',
        figs=['docs/stage3/figures/fig8_fullcore_vdot_wave.png'], split=0.34, bsize=25,
        bullets=['vadd 发射 1488 → vdot 发射 1494 → 进 VIMacU 1497 → 写回 1499 → 提交 1501',
                 'VIMacU 2 拍在真实流水线中确认',
                 '物理寄存器号 59 → 60 → 61 逐级传递',
                 '!相互依赖的 vdot 族发射间隔 7 拍，这只是一条依赖链的观测，不是吞吐测量']),
        [(0, '这张是 16 个元素全参与的满寄存器版本，用来看流水线：VIMacU 2 拍在真实流水线中确认'),
         (7, '相互依赖的 vdot 族发射间隔 7 拍，这只是一条依赖链的观测，不是吞吐测量')],
        '卡片：fig8 全核 vl=16 波形 + 要点'),

    card('v3-10', 18, dict(
        title='3.3 延迟实测：看「数据成形拍」，不看 valid', src='docs/stage3/22 §4.2–§4.4；logs/stage3/p7_latency_measure.log:232-264；fig5、fig3',
        figs=['docs/stage3/figures/fig5_latency_wave_vdot.png', 'docs/stage3/figures/fig3_latency.png'], split=0.36, bsize=24,
        bullets=['fire 后逐拍采 io_vd 与参考模型比较；两类平台的 out.valid 都由测试平台按声明值构造，只作对照',
                 '直驱 VIMacU：vdot / vdotacc / vdot4a 196 / 196 / 190 笔，全部「第 1 拍未成形、第 2 拍逐位正确」',
                 '既有 vmul / vwmul / vmacc 同样 2 拍，没被拖慢',
                 '13 条指令声明值与实测值 12 条一致；vsetvli 未实测，用声明值 0',
                 '!这些是 FU 级延迟，不是乱序核端到端延迟']),
        [(0, '延迟证据看数据成形拍：fire 后第 1 拍 io_vd 仍是旧值，第 2 拍才成形，所以是 2 拍'),
         (7, '直驱真正集成进香山的 VIMacU：三条指令共五百多笔全部第 2 拍成形；既有乘法指令同样 2 拍'),
         (12, '这些是功能单元级延迟，不是端到端；端到端看后面的全核周期实测')],
        '卡片：fig5 延迟波形、fig3 声明 vs 实测 + 要点'),

    card('v3-11', 16, dict(
        title='3.2 基线：RVV 1.0 标准指令，选有经验的程序员真会写的版本', src='docs/stage3/22 §2–§3；logs/stage3/p7_baseline_equiv.log:114-117,146；fig1',
        figs=['docs/stage3/figures/fig1_instr_count.png'], split=0.42, bsize=24,
        bullets=['单次 16 元素点积基线 6 条：vsetivli e32 → vmv.v.i v8,0 → vsetvli e8 → vwmul.vv → vsetvli e16,m2,tu → vwredsum.vs',
                 'vdot 侧 2 条：vsetvli e8 → vdot.vv',
                 '长向量循环选候选 D（vwmul.vv + vwadd.wv，归约移出循环）；A / B / D 都在 NEMU 实跑',
                 '等价性：NEMU 上 25960 条用例三方比对 0 失配；长向量 24 个长度 0 失配']),
        [(0, '基线只用 RVV 1.0 标准指令：单次点积 6 条，vdot 侧 2 条，两侧都计入必需的 vsetvli'),
         (6, '基线与 vdot 在 NEMU 上 25960 条用例三方比对 0 失配；加速比不依赖弱基线')],
        '卡片：fig1 指令条数 + 基线序列与等价性'),

    term('v3-12', 'v3-perf.cast', '延迟、基线等价、全核周期与加速比（已存档的运行结果）',
         [('t:0', '已存档的运行结果：40_run_bench.sh 与全核 perf 模式，展示关键行', 0),
          ('re:第 2 拍数据正确 196/196', '直驱 VIMacU 的 vdot：196 笔全部第 1 拍未成形、第 2 拍逐位正确', 4),
          ('re:vl readback mismatch = 0', '基线对 vdot：25960 条实跑用例，三方比对 0 失配', 4),
          ('re:311:RESULT: PASS', '全核周期实测 300 次测量，结果全对、无意外 trap（带 difftest）', 3),
          ('re:基线 D vs vdot4a', 'speedup.csv：单次点积函数整体 52 → 30.5 拍 1.70×；长向量稳态 12.64 → 7.00 / 5.63 拍，1.81× / 2.25×', 7)],
         '终端：sed 存档 p7_latency_measure.log、p7_baseline_equiv.log；grep perf_cycles.log；grep speedup.csv 主结论三行',
         'logs/stage3/p7_latency_measure.log:232-236；p7_baseline_equiv.log:110-117；perf_cycles.log:310-311；bench/results/speedup.csv'),

    card('v3-13', 22, dict(
        title='3.3 加速比：主结论与参考口径分开，各口径不可互相替代', src='README.md §1.2；docs/stage3/22 §5、§5.5、§12；bench/results/speedup.csv',
        tiles=[('1.70×', '主结论 · 单次 16 元素点积（函数整体）', '实测（全核 MinimalConfig）：52 → 30.5 拍，含 2 条装载与结果取回', 'ours'),
               ('1.81×', '主结论 · 长向量稳态（vdotacc 单累加器）', '实测（全核 MinimalConfig）：12.64 → 7.00 拍 / 16 个 int8', 'ours'),
               ('2.25×', '主结论 · 长向量稳态（2 路累加器展开）', '实测（全核 MinimalConfig）：12.64 → 5.63 拍 / 16 个 int8', 'ours')], tile_h=180,
        table=dict(size=26, line=38, cols=[(0, 560, '参考口径'), (560, 260, '基线 → vdot'), (820, 200, '比值'), (1020, 790, '性质')], rows=[
            ['单次点积：架构指令条数', '6 → 2', '3.00×', ('实测（全核 minstret 窗口差）', 'ok')],
            ['单次点积：译码级 uop 条数', '14 → 3', '4.67×', ('源码推导', 'acc')],
            ['单次点积：FU 延迟关键路径', '4 → 2 拍', '2.00×', ('建模（假设完美前递、无端口冲突）', 'acc')],
            ['单次点积：全核序列本体 / 加取回标量', '31 → 6 / 38 → 13.5', '5.17× / 2.81×', ('实测，对窗口定义敏感，只作参考', 'acc')],
            ['长向量 N = 4096：动态指令数', '2577 → 2063', '1.249×', ('实测（指令数不是周期数）', 'ok')],
            ['长向量稳态吞吐模型（单 / 2 累加器）', '3 → 2 / 3 → 1 拍', '1.50× / 3.00×', ('建模', 'acc')]]),
        foot='适用范围：MinimalConfig 全核 emu、热态（每点 5 次取后 4 次中位数）、带 difftest；默认配置（KunminghuV2Config）未测。S-3\' 修订后全核周期按新基线重跑，各点逐拍相同。'),
        [(0, '主结论：' + HEADLINE + '；三个数都是全核实测周期'),
         (8, '其余都是参考口径：指令条数 6 → 2 是 3.00×，uop 4.67× 是源码推导，2.00× 与 1.50× / 3.00× 是建模值'),
         (15, '序列本体 5.17× 与加取回 2.81× 对窗口定义敏感，只作参考；各口径量纲不同，不能互相替代')],
        '卡片：主结论三个 tile + 参考口径表 + 适用范围'),

    card('v3-14', 18, dict(
        title='全核实测对模型：哪些高于、哪些低于建模值', src='docs/stage3/22 §5.5.1–§5.5.5；logs/stage3/fullcore/perf_csrr_probe.log:4-9；fig9',
        figs=['docs/stage3/figures/fig9_fullcore_cycles.png'], split=0.36, bsize=24,
        bullets=['计时：香山把只读 csrr mcycle 乱序执行，裸读会出现 -2；每次读前加 fence，空窗口 35 拍扣除',
                 '单累加器 1.81× 高于模型 1.50×',
                 '!2 累加器 2.25× 低于模型 3.00×；函数整体单次点积 1.70× 低于模型 2.00×',
                 '每跳向量依赖实测 = FU 延迟 + 5 拍（零气泡前递的假设在全核里不成立）',
                 '!只对 MinimalConfig 成立；基线 D 12.64 拍 / 迭代的瓶颈未定位']),
        [(0, '计时方法：香山会把只读的 csrr mcycle 乱序执行，所以每次读之前加 fence，空窗口 35 拍扣除'),
         (6, '实测对模型：单累加器 1.81× 高于模型；2 累加器 2.25× 与单次点积 1.70× 都低于模型，照实报'),
         (12, '每跳依赖是功能单元延迟加 5 拍；这些周期数只对 MinimalConfig 成立')],
        '卡片：fig9 全核周期 + 实测对模型'),

    card('v3-15', 18, dict(
        title='敏感性分析与一个不利发现', src='docs/stage3/22 §6、§5.5.3–§5.5.5；bench/results/sensitivity.csv；fig4',
        figs=['docs/stage3/figures/fig4_sensitivity.png'], split=0.46, bsize=24,
        bullets=['单次点积 FU 关键路径 2.00× 的敏感性区间 1.00×–5.00×：vdot 退化到 4 拍时优势消失；5.00× 无证据，不采用',
                 '!不利发现（FU 级）：vdotacc 循环携带依赖 2 拍，长于基线的 1 拍；不做累加器展开时，长向量吞吐可能不升反降',
                 '全核实测：依赖每跳 7 拍对 6 拍，vdotacc 循环确实被它卡住，但基线 D 更慢，没有不升反降（1.81×）',
                 '!仍然不利：2 累加器只从 7.00 降到 5.63 拍，收益 1.24×；默认配置未测']),
        [(0, '2.00× 的敏感性区间是 1.00× 到 5.00×；vdot 退化到 4 拍时优势消失，5.00× 不采用'),
         (6, '不利发现：vdotacc 的循环携带依赖 2 拍，长于基线 1 拍，不做累加器展开时吞吐可能不升反降'),
         (12, '全核实测：vdotacc 循环确实被依赖卡住，但基线更慢，没有不升反降；2 累加器收益只有 1.24×')],
        '卡片：fig4 敏感性 + 不利发现与全核检验'),

    card('v3-16', 16, dict(
        title='如实说明：我们没有做什么', src='README.md 局限性；docs/stage3/22 §12；docs/stage3/23 §10',
        bullets=['!全核 difftest 与周期实测只跑了 MinimalConfig；默认配置与 KunminghuV2Config 未运行；LMUL ≠ 1 未在全核复测',
                 '!未综合：latency = 2 只有静态估算 + 实测；时序收敛、真实面积、功耗未知；13.7% 是结构计数上界',
                 '!2.00×、1.50× / 3.00× 是建模值；uop 条数是源码推导；vsetvli 延迟是声明值',
                 '!依赖测试是 10 个固定模板，不是随机指令流；未做真实 LLM 负载端到端评测；LMUL 固定为 1',
                 '后续优先级：综合 → 默认配置上的全核周期实测 / 真实 LLM 负载 → LMUL > 1']),
        [(0, '局限：全核只跑了 MinimalConfig，默认配置未测；没有综合，时序、面积、功耗未知'),
         (6, '建模值、源码推导值、声明值都单独标注；没有做真实大模型负载的端到端评测'),
         (11, '后续优先级：先综合，再在默认配置上实测周期和真实负载，最后做 LMUL 大于 1')],
        '卡片：局限性五条'),

    card('v3-17', 12, dict(
        title='阶段三小结',
        bullets=['NEMU 扩展：30794 条语料 0 失配，4834 条必须 trap 全部 mcause = 2',
                 '协同仿真 Level 1：72794 条激励，值比对 55960/55960，非法判定分歧 0；S-7\' 裁定把分歧 6415 → 0',
                 '全核 difftest Level 2（MinimalConfig）：24,524,262 条提交 0 失配；vl = 8 主演示与官方伪代码逐位一致',
                 '主结论：' + HEADLINE + '（MinimalConfig、热态、带 difftest）',
                 '基线等价 25960 条 0 失配；参考口径与建模值分列，未达模型处如实标注']),
        [(0, '阶段三小结：NEMU、协同仿真、全核 difftest 三层逐级加严，结果全部 0 失配'),
         (6, '主结论只用 MinimalConfig 全核实测：1.70×、1.81×、2.25×；谢谢观看')],
        '结尾卡：阶段三五条结论', kind='closing'),
]

VIDEOS = {
    1: dict(title='视频一 阶段一操作过程', file='SNL-XiangShan-vdot-video1-stage1', scenes=V1),
    2: dict(title='视频二 阶段二解题思路', file='SNL-XiangShan-vdot-video2-stage2', scenes=V2),
    3: dict(title='视频三 阶段三波形仿真与性能分析', file='SNL-XiangShan-vdot-video3-stage3', scenes=V3),
}
