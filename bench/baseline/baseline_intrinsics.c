/*
 * baseline_intrinsics.c —— 赛题 3.2 基线实现的 RVV 1.0 intrinsics 版本
 *
 * 与 baseline_rvv.S 中的候选 A / B / D 一一对应，便于用 C 编译器做
 * 调度/展开实验，并作为 NEMU 上跑基线程序的源码。
 *
 * 只在定义了 __riscv_v_intrinsic 时编译（即目标为 RISC-V 且启用 V 扩展），
 * 其余平台编译为空翻译单元，以便整个 bench/ 目录能在 x86/arm 宿主上
 * 一起过一遍编译检查。
 *
 * 本机验证：riscv64-elf-gcc 16.2.0 -march=rv64gcv -mabi=lp64d -ffreestanding -O2
 */

#if defined(__riscv_v_intrinsic)

#include <stdint.h>
#include <stddef.h>
#include <riscv_vector.h>

/* ---------------------------------------------------------------- *
 * 候选 A：vwmul.vv(8->16) + vwredsum.vs(16->32)，循环内串行归约
 * ---------------------------------------------------------------- */
int32_t baseline_dot_i8_seqA_intr(const int8_t *a, const int8_t *b, size_t n)
{
    vint32m1_t acc = __riscv_vmv_s_x_i32m1(0, 1);
    while (n > 0) {
        size_t vl = __riscv_vsetvl_e8m1(n);
        vint8m1_t  va = __riscv_vle8_v_i8m1(a, vl);
        vint8m1_t  vb = __riscv_vle8_v_i8m1(b, vl);
        vint16m2_t p  = __riscv_vwmul_vv_i16m2(va, vb, vl);
        acc = __riscv_vwredsum_vs_i16m2_i32m1(p, acc, vl);   /* 串行归约 */
        a += vl; b += vl; n -= vl;
    }
    return __riscv_vmv_x_s_i32m1_i32(acc);
}

/* ---------------------------------------------------------------- *
 * 候选 B：vsext.vf4 ×2 + vmacc.vv，循环内无归约，寄存器压力大
 * ---------------------------------------------------------------- */
int32_t baseline_dot_i8_seqB_intr(const int8_t *a, const int8_t *b, size_t n)
{
    size_t vlmax = __riscv_vsetvlmax_e32m4();
    vint32m4_t acc = __riscv_vmv_v_x_i32m4(0, vlmax);
    while (n > 0) {
        size_t vl = __riscv_vsetvl_e8m1(n);
        vint8m1_t  va = __riscv_vle8_v_i8m1(a, vl);
        vint8m1_t  vb = __riscv_vle8_v_i8m1(b, vl);
        vint32m4_t wa = __riscv_vsext_vf4_i32m4(va, vl);
        vint32m4_t wb = __riscv_vsext_vf4_i32m4(vb, vl);
        acc = __riscv_vmacc_vv_i32m4_tu(acc, wa, wb, vl);    /* tu：保住尾部 lane */
        a += vl; b += vl; n -= vl;
    }
    {
        vint32m1_t z = __riscv_vmv_s_x_i32m1(0, 1);
        return __riscv_vmv_x_s_i32m1_i32(
                   __riscv_vredsum_vs_i32m4_i32m1(acc, z, vlmax));
    }
}

/* ---------------------------------------------------------------- *
 * 候选 D（选定基线）：vwmul.vv(8->16) + vwadd.wv(16->32)
 *   循环内无归约、无 EMUL=4 的中间符号扩展结果
 * ---------------------------------------------------------------- */
int32_t baseline_dot_i8_seqD_intr(const int8_t *a, const int8_t *b, size_t n)
{
    size_t vlmax = __riscv_vsetvlmax_e32m4();
    vint32m4_t acc = __riscv_vmv_v_x_i32m4(0, vlmax);
    while (n > 0) {
        size_t vl = __riscv_vsetvl_e8m1(n);
        vint8m1_t  va = __riscv_vle8_v_i8m1(a, vl);
        vint8m1_t  vb = __riscv_vle8_v_i8m1(b, vl);
        vint16m2_t p  = __riscv_vwmul_vv_i16m2(va, vb, vl);
        acc = __riscv_vwadd_wv_i32m4_tu(acc, acc, p, vl);    /* tu：保住尾部 lane */
        a += vl; b += vl; n -= vl;
    }
    {
        vint32m1_t z = __riscv_vmv_s_x_i32m1(0, 1);
        return __riscv_vmv_x_s_i32m1_i32(
                   __riscv_vredsum_vs_i32m4_i32m1(acc, z, vlmax));
    }
}

/* ---------------------------------------------------------------- *
 * 候选 D 的 4 路累加器展开版：用于说明"循环携带依赖"才是瓶颈，
 * 指令条数不变但可填满流水线。作为 P7 做延迟/吞吐分析时的对照组。
 * ---------------------------------------------------------------- */
int32_t baseline_dot_i8_seqD_unroll4_intr(const int8_t *a, const int8_t *b, size_t n)
{
    size_t vlmax8  = __riscv_vsetvlmax_e8m1();
    size_t vlmax32 = __riscv_vsetvlmax_e32m4();
    vint32m4_t a0 = __riscv_vmv_v_x_i32m4(0, vlmax32);
    vint32m4_t a1 = a0, a2 = a0, a3 = a0;
    while (n >= 4 * vlmax8) {
        size_t vl = __riscv_vsetvl_e8m1(vlmax8);
        a0 = __riscv_vwadd_wv_i32m4_tu(a0, a0,
                __riscv_vwmul_vv_i16m2(__riscv_vle8_v_i8m1(a + 0 * vl, vl),
                                       __riscv_vle8_v_i8m1(b + 0 * vl, vl), vl), vl);
        a1 = __riscv_vwadd_wv_i32m4_tu(a1, a1,
                __riscv_vwmul_vv_i16m2(__riscv_vle8_v_i8m1(a + 1 * vl, vl),
                                       __riscv_vle8_v_i8m1(b + 1 * vl, vl), vl), vl);
        a2 = __riscv_vwadd_wv_i32m4_tu(a2, a2,
                __riscv_vwmul_vv_i16m2(__riscv_vle8_v_i8m1(a + 2 * vl, vl),
                                       __riscv_vle8_v_i8m1(b + 2 * vl, vl), vl), vl);
        a3 = __riscv_vwadd_wv_i32m4_tu(a3, a3,
                __riscv_vwmul_vv_i16m2(__riscv_vle8_v_i8m1(a + 3 * vl, vl),
                                       __riscv_vle8_v_i8m1(b + 3 * vl, vl), vl), vl);
        a += 4 * vl; b += 4 * vl; n -= 4 * vl;
    }
    while (n > 0) {
        size_t vl = __riscv_vsetvl_e8m1(n);
        a0 = __riscv_vwadd_wv_i32m4_tu(a0, a0,
                __riscv_vwmul_vv_i16m2(__riscv_vle8_v_i8m1(a, vl),
                                       __riscv_vle8_v_i8m1(b, vl), vl), vl);
        a += vl; b += vl; n -= vl;
    }
    {
        vint32m1_t z = __riscv_vmv_s_x_i32m1(0, 1);
        vint32m4_t s = __riscv_vadd_vv_i32m4(
                           __riscv_vadd_vv_i32m4(a0, a1, vlmax32),
                           __riscv_vadd_vv_i32m4(a2, a3, vlmax32), vlmax32);
        return __riscv_vmv_x_s_i32m1_i32(
                   __riscv_vredsum_vs_i32m4_i32m1(s, z, vlmax32));
    }
}

#else   /* !__riscv_v_intrinsic */

/* 非 RISC-V 目标：保留一个符号避免空翻译单元（C11 不允许空的翻译单元） */
int baseline_intrinsics_unavailable(void);
int baseline_intrinsics_unavailable(void) { return 0; }

#endif
