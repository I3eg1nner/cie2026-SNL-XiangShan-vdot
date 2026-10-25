/* =========================================================================
 * vdot_dep_kernels.S —— vdot 指令族与其他向量指令背靠背依赖的全核测试内核
 *
 * 每个内核 KERNEL_n 以宏的形式写一次，实例化成两个函数：
 *   kn_fast ：指令背靠背排列，RAW / WAR / WAW 依赖全部落在乱序流水线内部，
 *             生产者结果须经旁路（或唤醒后读物理寄存器堆）交给消费者；
 *   kn_slow ：同一指令序列，相邻两条之间插 `fence`。
 *             昆明湖V2 的 FENCE 译码为 noSpec + blockBack + flushPipe
 *             （XiangShan DecodeUnit.scala:231）：它等所有更老指令提交后才执行，
 *             并冲刷流水线让更年轻的指令重新取指，于是每条消费者都只能读到
 *             已提交的架构状态，不存在任何流水线内转发。
 * 驱动程序（vdot_dep.c）对同一份随机输入各跑一次，逐字节比较 32 个向量寄存器
 * 和 4 个标量结果；与此同时 difftest 把每一条提交与 NEMU 逐条比对。
 *
 * 调用约定（C 原型见 vdot_dep.c）：
 *   a0 = 输入块（32 个向量寄存器 × 16 B = 512 B，其后 64 B 供向量 load 使用）
 *   a1 = 输出块（32 × 16 B = 512 B，其后 4 个 u64：t3 t4 t5 t6）
 *   a2 / a3 = SEW=8  时的 AVL / vtype（vtype 只含 vta/vma 位，vsew=e8，LMUL=1）
 *   a4 / a5 = SEW=32 时的 AVL / vtype（vsew=e32，LMUL=1）
 *   t4 = 本次调用中观测到的 trap 次数，t5 = mcause 之和（由 TRAPCHK 累加）
 *
 * 被测指令无汇编助记符（自定义编码），由下面三个宏按 OPIVV 位域拼出：
 *   [31:26] funct6 | [25] vm | [24:20] vs2 | [19:15] vs1 | [14:12] 000 | [11:7] vd | 1010111
 * 与 tests/riscv/vdot/vdot_test.c 的 VENC() 同一公式（funct6 = 111001/111010/111011）。
 * ========================================================================= */

    .macro VDOT vd, vs2, vs1, vm=1
    .4byte (0x39 << 26) | (\vm << 25) | (\vs2 << 20) | (\vs1 << 15) | (\vd << 7) | 0x57
    .endm
    .macro VDOTACC vd, vs2, vs1, vm=1
    .4byte (0x3a << 26) | (\vm << 25) | (\vs2 << 20) | (\vs1 << 15) | (\vd << 7) | 0x57
    .endm
    .macro VDOT4A vd, vs2, vs1, vm=1
    .4byte (0x3b << 26) | (\vm << 25) | (\vs2 << 20) | (\vs1 << 15) | (\vd << 7) | 0x57
    .endm

    /* 慢速实例在相邻指令之间插入 fence；快速实例展开为空 */
    .macro S
    .if SLOW
    fence
    .endif
    .endm

    .macro E8
    vsetvl  x0, a2, a3
    .endm
    .macro E32
    vsetvl  x0, a4, a5
    .endm

    /* 读出并清零 trap handler（tests/riscv/vdot/start.S:trap_entry）留下的记录 */
    .macro TRAPCHK
    la      t0, vdot_trap_flag
    ld      t1, 0(t0)
    add     t4, t4, t1
    sd      zero, 0(t0)
    la      t0, vdot_trap_mcause
    ld      t1, 0(t0)
    add     t5, t5, t1
    sd      zero, 0(t0)
    .endm

    .macro PROLOGUE
    addi    a6, a0, 512
    addi    a7, a0, 528
    li      t3, 0
    li      t4, 0
    li      t5, 0
    li      t6, 0
    csrw    vstart, zero
    vsetivli x0, 16, e8, m1, tu, mu
    mv      t0, a0
    .irp r, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    vle8.v  v\r, (t0)
    addi    t0, t0, 16
    .endr
    .endm

    .macro EPILOGUE
    csrw    vstart, zero
    vsetivli x0, 16, e8, m1, tu, mu
    mv      t0, a1
    .irp r, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    vse8.v  v\r, (t0)
    addi    t0, t0, 16
    .endr
    sd      t3, 512(a1)
    sd      t4, 520(a1)
    sd      t5, 528(a1)
    sd      t6, 536(a1)
    ret
    .endm

/* ---- K1：整数向量 ALU -> vdot 的两个源操作数（vs1 / vs2 均 RAW），
 *          vdot 结果 -> vmv.x.s 进整数域（向量 -> 标量跨域旁路） ---- */
    .macro KERNEL_1
    E8
    vadd.vv v1, v8, v9
    S
    vsub.vv v2, v10, v11
    S
    VDOT    3, 2, 1
    S
    E32
    vmv.x.s t3, v3
    S
    add     t6, t3, t3
    .endm

/* ---- K2：vdot -> vdotacc -> vdotacc ... 对同一 vd 的累加链（vd 既是源也是目的），
 *          倒数第二条 vs2 = vs1 = v3（累加链结果）、vd = v4；末条 vs2 = vd = v4（上一条结果）、vs1 = v3 ---- */
    .macro KERNEL_2
    E8
    VDOT    3, 9, 8
    S
    VDOTACC 3, 11, 10
    S
    VDOTACC 3, 13, 12
    S
    VDOTACC 3, 15, 14
    S
    VDOTACC 4, 3, 3
    S
    VDOTACC 4, 4, 3
    .endm

/* ---- K3：vdot 结果 -> SEW=32 的消费者：vadd.vv / vdot4a(vs2 与 vd 均为前序结果)
 *          / vredsum.vs（vs1 取 vdot 结果作为标量种子） ---- */
    .macro KERNEL_3
    E8
    VDOT    3, 9, 8
    S
    E32
    vadd.vv v4, v3, v12
    S
    VDOT4A  4, 3, 13
    S
    vredsum.vs v5, v4, v3
    S
    vmv.x.s t3, v5
    .endm

/* ---- K4：vmul -> vdot4a 累加（vd RAW）-> vdot4a（vs1 = vd）-> vmslt 生成掩码
 *          -> 带掩码 vdot4a（v0 RAW）-> vadd ---- */
    .macro KERNEL_4
    E32
    vmul.vv v5, v8, v9
    S
    VDOT4A  5, 10, 11
    S
    VDOT4A  5, 12, 5
    S
    vmslt.vv v0, v5, v13
    S
    VDOT4A  5, 14, 15, 0
    S
    vadd.vv v7, v5, v5
    .endm

/* ---- K5：SEW=8 下比较指令生成掩码 -> 带掩码 vdot（v0 RAW）
 *          -> 用 vdot 结果再生成掩码 -> 带掩码 vdotacc ---- */
    .macro KERNEL_5
    E8
    vmslt.vv v0, v8, v9
    S
    VDOT    3, 10, 11, 0
    S
    vmsne.vv v0, v3, v12
    S
    VDOTACC 3, 13, 14, 0
    S
    VDOT    6, 3, 3, 0
    .endm

/* ---- K6：向量 load -> vdot -> 向量 store -> 向量 load -> vdotacc（经访存的依赖） ---- */
    .macro KERNEL_6
    E8
    vle8.v  v1, (a6)
    S
    vle8.v  v2, (a7)
    S
    VDOT    3, 2, 1
    S
    vsetivli x0, 4, e32, m1, tu, mu
    vse32.v v3, (a6)
    S
    vle32.v v4, (a6)
    S
    E8
    VDOTACC 4, 1, 4
    S
    ld      t3, 0(a6)
    .endm

/* ---- K7：WAR / WAW（重命名）：源寄存器在 vdot 之后立即被覆写，
 *          结果寄存器被连续多条指令写 ---- */
    .macro KERNEL_7
    E8
    VDOT    3, 2, 1
    S
    vadd.vv v1, v1, v9
    S
    VDOT    4, 2, 1
    S
    VDOT    3, 4, 3
    S
    VDOTACC 3, 3, 4
    S
    vxor.vv v4, v4, v3
    S
    VDOT    4, 4, 4
    .endm

/* ---- K8：流水线中的异常投递：合法 vdot 之后紧跟非法 vdot / vdot4a，
 *          以及 vstart != 0 的 vdotacc；trap handler 跳过后继续消费前序结果 ---- */
    .macro KERNEL_8
    E8
    vadd.vv v1, v8, v9
    S
    VDOT    3, 1, 1
    S
    E32
    VDOT    4, 1, 3             /* SEW=32 下 vdot：非法 */
    TRAPCHK
    vadd.vv v5, v4, v3
    S
    VDOT4A  6, 3, 1             /* SEW=32 下 vdot4a：合法 */
    S
    E8
    VDOT4A  7, 1, 1             /* SEW=8 下 vdot4a：非法 */
    TRAPCHK
    VDOT    7, 6, 1
    S
    li      t0, 1
    csrw    vstart, t0
    VDOTACC 7, 3, 3             /* vstart != 0：非法 */
    TRAPCHK
    csrw    vstart, zero
    VDOTACC 7, 7, 3
    .endm

/* ---- K9：8 条互相独立的 vdot 同时在发射队列中，随后两条依赖链收拢；
 *          再在 SEW=32 下让 vdot4a 读这些归约结果 ---- */
    .macro KERNEL_9
    E8
    VDOT    16, 8, 9
    VDOT    17, 9, 10
    VDOT    18, 10, 11
    VDOT    19, 11, 12
    VDOT    20, 12, 13
    VDOT    21, 13, 14
    VDOT    22, 14, 15
    VDOT    23, 15, 8
    S
    VDOTACC 24, 16, 17
    S
    VDOTACC 24, 18, 19
    S
    VDOTACC 24, 20, 21
    S
    VDOTACC 24, 22, 23
    S
    E32
    VDOT4A  25, 16, 17
    S
    VDOT4A  25, 18, 24
    S
    VDOT4A  25, 25, 25
    .endm

/* ---- K10：循环携带依赖 + 分支：16 次迭代的 vdotacc 累加循环，
 *          循环退出时的分支预测失败会冲刷已投机发射的 vdotacc ---- */
    .macro KERNEL_10
    E8
    li      t1, 16
1:
    VDOTACC 3, 8, 9
    S
    VDOTACC 3, 3, 10
    S
    vadd.vv v8, v8, v11
    S
    addi    t1, t1, -1
    bnez    t1, 1b
    E32
    vmv.x.s t3, v3
    .endm

/* ---- 实例化：每个内核生成 kN_fast / kN_slow 两个函数 ---- */
    .text
    .macro INSTANTIATE n
    .set SLOW, 0
    .balign 4
    .globl k\n\()_fast
    .type  k\n\()_fast, @function
k\n\()_fast:
    PROLOGUE
    KERNEL_\n
    EPILOGUE
    .size k\n\()_fast, . - k\n\()_fast

    .set SLOW, 1
    .balign 4
    .globl k\n\()_slow
    .type  k\n\()_slow, @function
k\n\()_slow:
    PROLOGUE
    KERNEL_\n
    EPILOGUE
    .size k\n\()_slow, . - k\n\()_slow
    .endm

    INSTANTIATE 1
    INSTANTIATE 2
    INSTANTIATE 3
    INSTANTIATE 4
    INSTANTIATE 5
    INSTANTIATE 6
    INSTANTIATE 7
    INSTANTIATE 8
    INSTANTIATE 9
    INSTANTIATE 10
