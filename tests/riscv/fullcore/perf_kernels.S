/* =========================================================================
 * perf_kernels.S —— 全核周期实测（HANDOFF T3）用的测量窗口
 *
 * 计时方法：被测代码前后各读一次 mcycle（csrr），差值即窗口周期数；
 *           窗口两端再各读一次 minstret，差值即窗口内提交的指令条数。
 *   读出顺序：fence -> minstret(始) -> mcycle(始) -> [被测代码] -> fence -> mcycle(终) -> minstret(终)
 *   * 为什么每次读计数器前都要 fence：这一版昆明湖V2 对「只读 CSRR」（rs1 = x0）做了乱序优化——
 *     Rename 阶段把不在 CSROoORead 白名单里的 CSR 的 csrr 的 waitForward / blockBackward 去掉
 *     （XiangShan Rename.scala:290-307，白名单 NewCSR/CSROoORead.scala:10-38，mcycle / minstret 不在其中），
 *     所以裸的 csrr mcycle 会和前后指令乱序执行，两次读数之差甚至可能为负（本目录试验中观测到 -2）。
 *     FENCE 译码为 noSpec + blockBack + flushPipe（DecodeUnit.scala:231）：它等所有更老的指令提交、
 *     存储缓冲排空后才执行，并冲刷流水线让其后的 csrr 重新取指。于是
 *       mcycle(始) 在窗口前的一切（含上一次打印的串口写）完成之后读出；
 *       mcycle(终) 在被测代码的最后一条指令提交之后读出。
 *     差值 = 被测代码从进入流水线到最后一条提交的周期数 + 一个固定开销（fence 等待 + 冲刷后重新取指 + csrr 执行）。
 *     固定开销用空窗口（perf_empty：两端 fence + csrr 之间什么都没有）实测，分析时扣除。
 *   * 被测代码紧跟在 mcycle(始) 之后取指，前端不需要额外重定向；被测代码开始时后端是空的
 *     （刚被 fence 冲刷过），所以单次点积测到的是「从空流水线开始」的端到端延迟。
 *   * 读 mcycle/minstret 在香山里属于 isPerfCnt（NewCSR.scala:942-945、Bundle.scala:369
 *     isSkipDiff），difftest 不比对这两条指令的结果，而是把 DUT 的读数同步给 NEMU，
 *     所以带 --diff 运行不会因为周期数不同而误报。
 *   * minstret 差值包含窗口内的 csrr mcycle ×2 与 fence ×1，用空窗口的读数扣除。
 *
 * 函数一律返回 mcycle 差值（a0），并写 out[0] = minstret 差值，out[1] = 计算结果
 * （int32 符号扩展，供 C 侧与标量参考比对）。
 *
 * 三类窗口：
 *   1) 单次 16 元素点积（赛题 3.2 的序列本体，与 bench/baseline/baseline_rvv.S 的
 *      baseline_vdot_single / vdot_single 中间段逐条相同）：
 *        perf_s_base  / perf_s_vdot   ：窗口只含序列本体（6 条 vs 2 条），操作数已在 v1/v2；
 *        perf_s_base_x / perf_s_vdot_x：本体后再加 vsetvli e32 + vmv.x.s（结果到标量寄存器）。
 *   2) 依赖链 / 独立指令串（每次调用执行 CNT 条同一指令，CNT 取两档求斜率）：
 *        chain_vdotacc  vdotacc.vv v8,v2,v1        —— 同一 vd 串行累加（循环携带依赖）
 *        chain_vwaddwv  vwadd.wv  v8,v8,v4 (e16,m2) —— 基线 D 的循环携带依赖
 *        chain_vwredsum vwredsum.vs v8,v4,v8 (e16,m2) —— 基线 A 的循环携带依赖
 *        chain_vadd     vadd.vv   v8,v8,v1 (e8,m1)  —— 单 uop 的 1 拍 ALU 对照
 *        indep_vdot     vdot.vv 写 v16..v23 轮转，相互独立 —— VIMacU 端口吞吐
 *        chain_vsetadd  (vsetvli e8 ; vadd.vv v8,v8,v1) 成对重复 —— 依赖链中插入 vsetvli 的代价
 *   3) 函数调用窗口 perf_call(fn, a, b, n, out)：窗口内是一次 jalr 调用
 *      （bench/baseline/baseline_rvv.S 的 kernel 原样调用）；perf_nop 为空函数，用于标定调用开销。
 *      skel_vdotacc / skel_seqD 是两个「骨架循环」：分别与 vdot_dot_i8、baseline_dot_i8_seqD 的
 *      循环控制、vsetvli、装载完全相同，只是删掉了计算指令（不是点积，结果恒为 0），
 *      用来区分循环周期中「骨架」与「计算依赖链」各占多少。
 * ========================================================================= */

    .macro VDOT vd, vs2, vs1, vm=1
    .4byte (0x39 << 26) | (\vm << 25) | (\vs2 << 20) | (\vs1 << 15) | (\vd << 7) | 0x57
    .endm
    .macro VDOTACC vd, vs2, vs1, vm=1
    .4byte (0x3a << 26) | (\vm << 25) | (\vs2 << 20) | (\vs1 << 15) | (\vd << 7) | 0x57
    .endm

    /* 窗口开始：t3 = minstret(始)，t4 = mcycle(始) */
    .macro WIN_BEGIN
    fence
    csrr    t3, minstret
    csrr    t4, mcycle
    .endm
    /* 窗口结束：a0 = mcycle 差，out[0] = minstret 差；out 指针在 \outreg */
    .macro WIN_END outreg
    fence
    csrr    t5, mcycle
    csrr    t6, minstret
    sub     a0, t5, t4
    sub     t6, t6, t3
    sd      t6, 0(\outreg)
    .endm

    .text

/* u64 perf_empty(u64 *out) —— 空窗口：标定 fence + csrr 的固定开销 */
    .globl perf_empty
perf_empty:
    mv      a5, a0
    WIN_BEGIN
    WIN_END a5
    sd      zero, 8(a5)
    ret

/* 单次点积公共序幕：a0 = A，a1 = B，a2 = out；装载 v1 = A[0..15]，v2 = B[0..15] */
    .macro SINGLE_PROLOGUE
    mv      a5, a2
    li      a2, 16
    vsetvli zero, a2, e8, m1, ta, ma
    vle8.v  v1, (a0)
    vle8.v  v2, (a1)
    vmv.v.i v4, 0
    vmv.v.i v5, 0
    vmv.v.i v8, 0
    .endm
    /* 公共尾声：窗口外取回 v8[0] 作为结果 */
    .macro SINGLE_EPILOGUE
    vsetvli t1, x0, e32, m1, ta, ma
    vmv.x.s t0, v8
    sd      t0, 8(a5)
    ret
    .endm

    /* 基线序列本体：baseline_rvv.S:282-288（baseline_vdot_single 中「序列 A 本体：6 条」） */
    .macro BASE_BODY
    vsetvli     zero, a2, e32, m1, ta, ma
    vmv.s.x     v8, x0
    vsetvli     zero, a2, e8,  m1, ta, ma
    vwmul.vv    v4, v2, v1
    vsetvli     zero, a2, e16, m2, ta, ma
    vwredsum.vs v8, v4, v8
    .endm
    /* vdot 序列本体：baseline_rvv.S:303-306（vdot_single 的 vsetvli + 本体 1 条） */
    .macro VDOT_BODY
    vsetvli     zero, a2, e8,  m1, ta, ma
    VDOT        8, 2, 1
    .endm

/* u64 perf_s_base(const i8 *a, const i8 *b, u64 *out) */
    .globl perf_s_base
perf_s_base:
    SINGLE_PROLOGUE
    WIN_BEGIN
    BASE_BODY
    WIN_END a5
    SINGLE_EPILOGUE

    .globl perf_s_vdot
perf_s_vdot:
    SINGLE_PROLOGUE
    WIN_BEGIN
    VDOT_BODY
    WIN_END a5
    SINGLE_EPILOGUE

/* _x 版：窗口内多一段 vsetvli e32 + vmv.x.s（两侧相同），量到「结果进入标量寄存器」为止 */
    .globl perf_s_base_x
perf_s_base_x:
    SINGLE_PROLOGUE
    WIN_BEGIN
    BASE_BODY
    vsetvli t1, x0, e32, m1, ta, ma
    vmv.x.s t0, v8
    WIN_END a5
    sd      t0, 8(a5)
    ret

    .globl perf_s_vdot_x
perf_s_vdot_x:
    SINGLE_PROLOGUE
    WIN_BEGIN
    VDOT_BODY
    vsetvli t1, x0, e32, m1, ta, ma
    vmv.x.s t0, v8
    WIN_END a5
    sd      t0, 8(a5)
    ret

/* -------------------------------------------------------------------------
 * 依赖链 / 独立串：u64 name_CNT(const i8 *a, const i8 *b, u64 *out)
 * 结果 out[1] 取 v8[0]（indep 取 v16[0]），只作为 difftest 之外的「确实执行了」标记，
 * C 侧不与参考比对（链式累加的数值正确性由 difftest 逐条保证）。
 * ---------------------------------------------------------------------- */
    .macro CHAIN name, cnt, sew, lmul, body:vararg
    .globl \name\()_\cnt
\name\()_\cnt:
    SINGLE_PROLOGUE
    vmv.v.i v16, 0
    vsetvli zero, a2, \sew, \lmul, ta, ma
    WIN_BEGIN
    .rept \cnt
    \body
    .endr
    WIN_END a5
    SINGLE_EPILOGUE
    .endm

    /* vsetvli 与依赖链交错：每个单位 = vsetvli（rs1 = a2，写 vl）+ 依赖上一单位的 vadd.vv */
    .macro VSET_VADD
    vsetvli zero, a2, e8, m1, ta, ma
    vadd.vv v8, v8, v1
    .endm

    .macro INDEP_VDOT8
    VDOT 16, 2, 1
    VDOT 17, 2, 1
    VDOT 18, 2, 1
    VDOT 19, 2, 1
    VDOT 20, 2, 1
    VDOT 21, 2, 1
    VDOT 22, 2, 1
    VDOT 23, 2, 1
    .endm

    .irp n, 16, 48
    CHAIN chain_vdotacc,  \n, e8,  m1, VDOTACC 8, 2, 1
    CHAIN chain_vwaddwv,  \n, e16, m2, vwadd.wv v8, v8, v4
    CHAIN chain_vwredsum, \n, e16, m2, vwredsum.vs v8, v4, v8
    CHAIN chain_vadd,     \n, e8,  m1, vadd.vv v8, v8, v1
    CHAIN chain_vsetadd,  \n, e8,  m1, VSET_VADD
    .endr
    /* 独立串：每个 .rept 单位 8 条，16/48 条分别为 2/6 个单位 */
    .macro CHAIN8 name, cnt, units
    .globl \name\()_\cnt
\name\()_\cnt:
    SINGLE_PROLOGUE
    vmv.v.i v16, 0
    WIN_BEGIN
    .rept \units
    INDEP_VDOT8
    .endr
    WIN_END a5
    vsetvli t1, x0, e32, m1, ta, ma
    vmv.x.s t0, v16
    sd      t0, 8(a5)
    ret
    .endm
    CHAIN8 indep_vdot, 16, 2
    CHAIN8 indep_vdot, 48, 6

/* -------------------------------------------------------------------------
 * u64 perf_call(fn, a, b, n, out)：窗口内一次 jalr fn(a, b, n)
 *   a0 = fn, a1 = a, a2 = b, a3 = n, a4 = out
 * fn 是 bench/baseline/baseline_rvv.S 的叶子函数（不用栈，ABI 见该文件头）；
 * fn 与 out 保存在 s0 / s1，起始读数保存在 s2 / s3（均先压栈）。窗口内 = jalr + fn 本体（含 ret）。
 * ---------------------------------------------------------------------- */
    .globl perf_call
perf_call:
    addi    sp, sp, -48
    sd      ra, 0(sp)
    sd      s0, 8(sp)
    sd      s1, 16(sp)
    sd      s2, 24(sp)
    sd      s3, 32(sp)
    mv      s0, a0
    mv      s1, a4
    mv      a0, a1
    mv      a1, a2
    mv      a2, a3
    fence                          /* 与 WIN_BEGIN 相同，只是读数存进被调函数不会改写的 s2/s3 */
    csrr    s2, minstret
    csrr    s3, mcycle
    jalr    ra, 0(s0)
    fence
    csrr    t5, mcycle
    csrr    t6, minstret
    sub     t5, t5, s3
    sub     t6, t6, s2
    sd      t6, 0(s1)
    sd      a0, 8(s1)
    mv      a0, t5
    ld      ra, 0(sp)
    ld      s0, 8(sp)
    ld      s1, 16(sp)
    ld      s2, 24(sp)
    ld      s3, 32(sp)
    addi    sp, sp, 48
    ret

/* 骨架循环：vdot_dot_i8（baseline_rvv.S）去掉 vdotacc.vv */
    .globl skel_vdotacc
skel_vdotacc:
    beqz        a2, 3f
1:  vsetvli     t0, a2, e8,  m1, tu, mu
    vle8.v      v1, (a0)
    vle8.v      v2, (a1)
    add         a0, a0, t0
    add         a1, a1, t0
    sub         a2, a2, t0
    bnez        a2, 1b
3:  li          a0, 0
    ret

/* 骨架循环：baseline_dot_i8_seqD（baseline_rvv.S）去掉 vwmul.vv 与 vwadd.wv */
    .globl skel_seqD
skel_seqD:
    beqz        a2, 3f
1:  vsetvli     t0, a2, e8,  m1, tu, mu
    vle8.v      v1, (a0)
    vle8.v      v2, (a1)
    vsetvli     zero, t0, e16, m2, tu, mu
    add         a0, a0, t0
    add         a1, a1, t0
    sub         a2, a2, t0
    bnez        a2, 1b
3:  li          a0, 0
    ret

/* 空函数：标定 perf_call 的调用开销（jalr + li + ret） */
    .globl perf_nop
perf_nop:
    li      a0, 0
    ret
