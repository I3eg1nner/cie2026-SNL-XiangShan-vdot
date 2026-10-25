/* =========================================================================
 * perf_csrr_probe.S —— 计时方法的对照试验（为什么 perf_kernels.S 要在 csrr mcycle 前加 fence）
 *
 * 同一段被测代码各写两个版本：
 *   nf_*：裸的 csrr mcycle 前后各读一次；
 *   f_* ：每次读 mcycle 之前先执行 fence（perf_kernels.S 的做法）。
 * 被测代码：空、50 条相互依赖的 addi、50 条相互依赖的 mul。
 * 若 csrr 是串行化的，nf_add50 至少要 50 拍；若读数比这小甚至为负，说明 csrr mcycle 在乱序执行。
 * ========================================================================= */
    .text
    .macro PROBE name, pre, body:vararg
    .globl \name
\name:
    li      t0, 3
    \pre
    csrr    t4, mcycle
    .rept 50
    \body
    .endr
    \pre
    csrr    t5, mcycle
    sub     a0, t5, t4
    ret
    .endm
    .macro NOTHING
    .endm
    .globl nf_empty, f_empty
nf_empty:
    csrr    t4, mcycle
    csrr    t5, mcycle
    sub     a0, t5, t4
    ret
f_empty:
    fence
    csrr    t4, mcycle
    fence
    csrr    t5, mcycle
    sub     a0, t5, t4
    ret
    PROBE nf_add50, NOTHING, addi t0, t0, 1
    PROBE nf_mul50, NOTHING, mul t0, t0, t0
    PROBE f_add50, fence, addi t0, t0, 1
    PROBE f_mul50, fence, mul t0, t0, t0
