/*
 * baseline_rvv.S —— 赛题 3.2「基线实现」：只用 RVV 1.0 标准指令完成
 *                   与 vdot 指令族等价的 int8 点积，外加 vdot 版本用于对照
 *
 * 目标：RV64GCV，VLEN=128，LP64D ABI
 * 汇编方式：riscv64-elf-gcc -march=rv64gcv -mabi=lp64d -c baseline_rvv.S
 *           （见 bench/baseline/Makefile 的 check 目标，本机已实测通过）
 *
 * 【候选序列总览】——  详细对比表见 docs/stage2/13_参考模型与测试向量说明.md
 *   候选 A  vwmul.vv(8->16) + vwredsum.vs(16->32)   循环内含串行归约
 *   候选 B  vsext.vf4(8->32) ×2 + vmacc.vv(32)      循环内无归约，寄存器压力大
 *   候选 D  vwmul.vv(8->16) + vwadd.wv(16->32)      循环内无归约，寄存器压力小 ← 选定
 *
 * 【ABI】 int32_t f(const int8_t *a, const int8_t *b, size_t n)
 *         入参 a0 = a，a1 = b，a2 = n；返回值在 a0。
 *         所有函数都是叶子函数，不使用栈。
 *
 * 【溢出】 累加器为 int32。|单个乘积| <= 16384，故 n <= 131071 时绝不溢出；
 *          超过时按 2 的补码回绕（与 vdot 的 32 位回绕语义一致）。
 */

    .text
    .attribute arch, "rv64gc_v"

/* ------------------------------------------------------------------ *
 * vdot 指令族的机器码宏（GNU as 不认识这三条自定义指令）
 *   编码： funct6 | vm | vs2 | vs1 | funct3=000(OPIVV) | vd | 1010111
 *   vdot.vv    funct6 = 0b111001 = 0x39
 *   vdotacc.vv funct6 = 0b111010 = 0x3a
 *   vdot4a.vv  funct6 = 0b111011 = 0x3b
 *   参数一律用**寄存器编号**（0..31），不要写 v8 这种名字。
 *   自校验：VDOT_VV 3, 1, 2 (vm=1) 应产生 0xe61101d7
 * ------------------------------------------------------------------ */
    .macro VDOT_VV vd, vs2, vs1, vm=1
    .word (0x39 << 26) | ((\vm) << 25) | ((\vs2) << 20) | ((\vs1) << 15) | (0 << 12) | ((\vd) << 7) | 0x57
    .endm

    .macro VDOTACC_VV vd, vs2, vs1, vm=1
    .word (0x3a << 26) | ((\vm) << 25) | ((\vs2) << 20) | ((\vs1) << 15) | (0 << 12) | ((\vd) << 7) | 0x57
    .endm

    .macro VDOT4A_VV vd, vs2, vs1, vm=1
    .word (0x3b << 26) | ((\vm) << 25) | ((\vs2) << 20) | ((\vs1) << 15) | (0 << 12) | ((\vd) << 7) | 0x57
    .endm

/* 编码自校验锚点：objdump 应在 .rodata 里看到 d7 01 11 e6（小端） */
    .section .rodata
    .globl vdot_encoding_probe
    .align 2
vdot_encoding_probe:
    VDOT_VV    3, 1, 2          /* 期望 0xe61101d7 */
    VDOTACC_VV 3, 1, 2          /* 期望 0xea1101d7 */
    VDOT4A_VV  3, 1, 2          /* 期望 0xee1101d7 */
    .text

/* ================================================================== *
 * 候选 A —— vwmul.vv + vwredsum.vs（循环内串行归约）
 *
 * 循环体指令表（向量 6 / 标量 4）：
 *   #  指令              依赖于           说明
 *   1  vsetvli t0,a2,e8  a2(标量循环变量)  设置 vl<=16
 *   2  vle8.v  v1,(a0)   #1(vtype) a0      load A
 *   3  vle8.v  v2,(a1)   #1(vtype) a1      load B
 *   4  vwmul.vv v4,v1,v2 #2,#3             16 个 int16 乘积
 *   5  vsetvli zero,t0,e16 #1(t0)          切 vtype 到 e16/m2
 *   6  vwredsum.vs v8,v4,v8 #4,#5,上轮#6   ★串行归约 + 循环携带依赖
 * 关键路径：#1 -> #2/#3 -> #4 -> #6，且 #6 对上一轮 #6 存在循环携带依赖。
 * ================================================================== */
    .globl baseline_dot_i8_seqA
    .type  baseline_dot_i8_seqA, @function
baseline_dot_i8_seqA:
    vsetvli     t1, x0, e32, m1, ta, ma
    vmv.s.x     v8, x0                  /* int32 累加器 v8[0] = 0 */
    beqz        a2, 2f
1:  vsetvli     t0, a2, e8,  m1, ta, ma
    vle8.v      v1, (a0)
    vle8.v      v2, (a1)
    vwmul.vv    v4, v1, v2              /* EMUL=2 -> v4:v5 */
    vsetvli     zero, t0, e16, m2, ta, ma
    vwredsum.vs v8, v4, v8              /* 串行归约，循环携带依赖 */
    add         a0, a0, t0
    add         a1, a1, t0
    sub         a2, a2, t0
    bnez        a2, 1b
2:  vsetvli     t1, x0, e32, m1, ta, ma
    vmv.x.s     a0, v8
    ret
    .size baseline_dot_i8_seqA, .-baseline_dot_i8_seqA

/* ================================================================== *
 * 候选 B —— vsext.vf4 ×2 + vmacc.vv（循环内无归约，但要 3 组 EMUL=4）
 *
 * 循环体指令表（向量 7 / 标量 4）：
 *   1  vsetvli t0,a2,e8,m1,tu,mu   a2
 *   2  vle8.v  v1,(a0)             #1,a0
 *   3  vle8.v  v2,(a1)             #1,a1
 *   4  vsetvli zero,t0,e32,m4      #1(t0)
 *   5  vsext.vf4 v4,v1             #2,#4      v4..v7
 *   6  vsext.vf4 v8,v2             #3,#4      v8..v11
 *   7  vmacc.vv v16,v4,v8          #5,#6,上轮#7
 * 寄存器占用 v1,v2,v4-v7,v8-v11,v16-v19 共 14 个，寄存器压力最大。
 * ================================================================== */
    .globl baseline_dot_i8_seqB
    .type  baseline_dot_i8_seqB, @function
baseline_dot_i8_seqB:
    vsetvli     t1, x0, e32, m4, ta, ma
    vmv.v.i     v16, 0                  /* 16 个 int32 累加器 v16..v19 */
    beqz        a2, 3f
1:  vsetvli     t0, a2, e8,  m1, tu, mu
    vle8.v      v1, (a0)
    vle8.v      v2, (a1)
    vsetvli     zero, t0, e32, m4, tu, mu
    vsext.vf4   v4, v1
    vsext.vf4   v8, v2
    vmacc.vv    v16, v4, v8
    add         a0, a0, t0
    add         a1, a1, t0
    sub         a2, a2, t0
    bnez        a2, 1b
3:  vsetvli     t1, x0, e32, m4, ta, ma
    vmv.s.x     v24, x0
    vredsum.vs  v24, v16, v24
    vmv.x.s     a0, v24
    ret
    .size baseline_dot_i8_seqB, .-baseline_dot_i8_seqB

/* ================================================================== *
 * 候选 D（选定基线）—— vwmul.vv + vwadd.wv（循环内无归约，寄存器压力小）
 *
 * 循环体指令表（向量 6 / 标量 4）：
 *   #  指令                     依赖于            说明
 *   1  vsetvli t0,a2,e8,m1,tu,mu  a2              vl<=16
 *   2  vle8.v  v1,(a0)            #1, a0
 *   3  vle8.v  v2,(a1)            #1, a1
 *   4  vwmul.vv v4,v1,v2          #2,#3           16 个 int16 乘积（v4:v5）
 *   5  vsetvli zero,t0,e16,m2,tu,mu #1(t0)
 *   6  vwadd.wv v8,v8,v4          #4,#5,上轮#6    16 个 int32 累加器（v8..v11）
 *   （标量 add/add/sub/bnez 与向量链并行）
 * 循环携带依赖只有一条宽加法（#6 -> 下轮 #6），没有串行归约。
 *
 * ★ 必须用 tu（tail undisturbed）：最后一次迭代 vl<16 时，
 *   若用 ta 则 lane[vl..15] 的累加值会被写成全 1，结果错误。
 * ================================================================== */
    .globl baseline_dot_i8_seqD
    .type  baseline_dot_i8_seqD, @function
baseline_dot_i8_seqD:
    vsetvli     t1, x0, e32, m4, ta, ma
    vmv.v.i     v8, 0                   /* 16 个 int32 累加器 v8..v11 清零 */
    beqz        a2, 3f
1:  vsetvli     t0, a2, e8,  m1, tu, mu
    vle8.v      v1, (a0)
    vle8.v      v2, (a1)
    vwmul.vv    v4, v1, v2
    vsetvli     zero, t0, e16, m2, tu, mu
    vwadd.wv    v8, v8, v4
    add         a0, a0, t0
    add         a1, a1, t0
    sub         a2, a2, t0
    bnez        a2, 1b
3:  vsetvli     t1, x0, e32, m4, ta, ma
    vmv.s.x     v16, x0
    vredsum.vs  v16, v8, v16            /* 归约只做一次，在循环外 */
    vmv.x.s     a0, v16
    ret
    .size baseline_dot_i8_seqD, .-baseline_dot_i8_seqD

/* ================================================================== *
 * vdot 版本（DOTR 模式，使用 vdotacc.vv）
 *
 * 循环体指令表（向量 4 / 标量 4）：
 *   1  vsetvli t0,a2,e8,m1,tu,mu  a2
 *   2  vle8.v  v1,(a0)            #1,a0
 *   3  vle8.v  v2,(a1)            #1,a1
 *   4  vdotacc.vv v8,v2,v1        #2,#3,上轮#4   16 次 MAC 直接累加进 v8[0]
 * 相对候选 D：少 2 条向量指令，少 1 次 vtype 切换，循环内无中间加宽结果。
 * 代价：循环携带依赖 #4->#4 是完整的「乘法阵列+加法树」延迟，
 *       需要用多累加器展开（v8/v9/v10/v11 轮转）才能填满流水。
 * ================================================================== */
    .globl vdot_dot_i8
    .type  vdot_dot_i8, @function
vdot_dot_i8:
    vsetvli     t1, x0, e32, m1, ta, ma
    vmv.s.x     v8, x0                  /* 累加器 v8[0] = 0 */
    beqz        a2, 3f
1:  vsetvli     t0, a2, e8,  m1, tu, mu
    vle8.v      v1, (a0)
    vle8.v      v2, (a1)
    VDOTACC_VV  8, 2, 1                 /* vdotacc.vv v8, v2, v1 */
    add         a0, a0, t0
    add         a1, a1, t0
    sub         a2, a2, t0
    bnez        a2, 1b
3:  vsetvli     t1, x0, e32, m1, ta, ma
    vmv.x.s     a0, v8
    ret
    .size vdot_dot_i8, .-vdot_dot_i8

/* ================================================================== *
 * vdot 版本，2 路累加器轮转（v8 / v9）
 *
 * 与 vdot_dot_i8 的唯一区别：相邻两块 16 字节分别累加进 v8[0] 与 v9[0]，
 * 循环结束后再把两个 32 位部分和相加。每个累加器的循环携带依赖链
 * 因此每 2 块才走一次，用来缓解 §5.4 所述「vdotacc 携带依赖 2 拍」问题。
 * 每 16 个 int8 的指令数与单累加器版相同（向量 4 / 标量 4）：
 *   1  vsetvli t0,a2,e8,m1,tu,mu   2-3 vle8.v ×2   4 vdotacc.vv v8|v9
 *   5-7 add/add/sub                8  beqz（前半块）/ bnez（后半块）
 * 对任意 n（含 n 非 16、非 32 的整数倍）结果与单累加器版逐位相同
 * （32 位回绕加法满足结合律）。
 * ================================================================== */
    .globl vdot_dot_i8_acc2
    .type  vdot_dot_i8_acc2, @function
vdot_dot_i8_acc2:
    vsetvli     t1, x0, e32, m1, ta, ma
    vmv.s.x     v8, x0                  /* 累加器 0：v8[0] = 0 */
    vmv.s.x     v9, x0                  /* 累加器 1：v9[0] = 0 */
    beqz        a2, 3f
1:  vsetvli     t0, a2, e8,  m1, tu, mu
    vle8.v      v1, (a0)
    vle8.v      v2, (a1)
    VDOTACC_VV  8, 2, 1                 /* vdotacc.vv v8, v2, v1 */
    add         a0, a0, t0
    add         a1, a1, t0
    sub         a2, a2, t0
    beqz        a2, 3f
    vsetvli     t0, a2, e8,  m1, tu, mu
    vle8.v      v3, (a0)
    vle8.v      v4, (a1)
    VDOTACC_VV  9, 4, 3                 /* vdotacc.vv v9, v4, v3 */
    add         a0, a0, t0
    add         a1, a1, t0
    sub         a2, a2, t0
    bnez        a2, 1b
3:  vsetvli     t1, x0, e32, m1, ta, ma
    vmv.x.s     a0, v8
    vmv.x.s     t2, v9
    addw        a0, a0, t2              /* 两个 32 位部分和相加（回绕） */
    ret
    .size vdot_dot_i8_acc2, .-vdot_dot_i8_acc2

/* ================================================================== *
 * vdot4a 版本（SEW=32 模式）—— 要求 n 为 4 的倍数
 *
 * 循环体指令表（向量 4 / 标量 5）：
 *   1  vsetvli t0,a2,e32,m1,tu,mu  a2           t0 = 32 位组数
 *   2  vle32.v v1,(a0)             #1,a0
 *   3  vle32.v v2,(a1)             #1,a1
 *   4  vdot4a.vv v8,v2,v1          #2,#3,上轮#4  4 个独立 int32 累加器
 * 4 条 lane 累加器相互独立，加法树只有 3 级（vs. DOTR 的 4 级），
 * 循环携带依赖链比 vdotacc 版更短。
 * ================================================================== */
    .globl vdot4a_dot_i8
    .type  vdot4a_dot_i8, @function
vdot4a_dot_i8:
    vsetvli     t1, x0, e32, m1, ta, ma
    vmv.v.i     v8, 0                   /* 4 个 int32 累加器 */
    srli        a2, a2, 2               /* 字节数 -> 32 位元素个数 */
    beqz        a2, 3f
1:  vsetvli     t0, a2, e32, m1, tu, mu
    vle32.v     v1, (a0)
    vle32.v     v2, (a1)
    VDOT4A_VV   8, 2, 1                 /* vdot4a.vv v8, v2, v1 */
    slli        t1, t0, 2
    add         a0, a0, t1
    add         a1, a1, t1
    sub         a2, a2, t0
    bnez        a2, 1b
3:  vsetvli     t1, x0, e32, m1, ta, ma
    vmv.s.x     v16, x0
    vredsum.vs  v16, v8, v16            /* 归约只做一次，在循环外 */
    vmv.x.s     a0, v16
    ret
    .size vdot4a_dot_i8, .-vdot4a_dot_i8

/* ================================================================== *
 * 单次 16 元素点积（操作数在内存里，vl 由 a2 给出，要求 1 <= a2 <= 16）
 * 用于「单条 vdot 对 N 条基线指令」的指令条数对照。
 * ================================================================== */

/* 基线：装载 2 条 + 序列 A 本体 6 条 + 取回 2 条
 * 本体与 vdot.vv 的完整写回逐位相同（裁定 S-3'：v8 = {Σ, 0, 0, 0}）：
 *   vsetivli 4 / vmv.v.i 把 v8 整体清零（本函数约定 a2 >= 1，故无需处理 vl=0；
 *   要处理 vl=0 时改用 AVL = a2<<2，见 baseline_ref.c 与 baseline_test.c），
 *   vwredsum.vs 用 tu，元素 1..3 保持 0。 */
    .globl baseline_vdot_single
    .type  baseline_vdot_single, @function
baseline_vdot_single:
    vsetvli     zero, a2, e8,  m1, ta, ma
    vle8.v      v1, (a0)
    vle8.v      v2, (a1)
    /* ---- 序列 A 本体：6 条 ---- */
    vsetivli    zero, 4, e32, m1, ta, ma
    vmv.v.i     v8, 0
    vsetvli     zero, a2, e8,  m1, ta, ma
    vwmul.vv    v4, v2, v1
    vsetvli     zero, a2, e16, m2, tu, ma
    vwredsum.vs v8, v4, v8
    /* ------------------------- */
    vsetvli     t1, x0, e32, m1, ta, ma
    vmv.x.s     a0, v8
    ret
    .size baseline_vdot_single, .-baseline_vdot_single

/* vdot：装载 2 条 + 本体 1 条 */
    .globl vdot_single
    .type  vdot_single, @function
vdot_single:
    vsetvli     zero, a2, e8,  m1, ta, ma
    vle8.v      v1, (a0)
    vle8.v      v2, (a1)
    /* ---- 本体：1 条 ---- */
    VDOT_VV     8, 2, 1                 /* vdot.vv v8, v2, v1 */
    /* ------------------- */
    vsetvli     t1, x0, e32, m1, ta, ma
    vmv.x.s     a0, v8
    ret
    .size vdot_single, .-vdot_single
