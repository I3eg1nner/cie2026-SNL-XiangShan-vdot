/* =========================================================================
 * perf_cycles.c —— 全核周期实测（HANDOFF T3，赛题 3.3）
 *
 * 在香山 MinimalConfig 全核 emu 上（带 difftest）实测基线序列与 vdot 序列的周期数：
 *   [S] 单次 16 元素点积：序列本体窗口（perf_kernels.S）与 baseline_rvv.S 函数整体调用；
 *   [C] 依赖链 / 独立串：每跳依赖的周期（两档长度求斜率）；
 *   [L] 长向量循环：直接调用交付件 bench/baseline/baseline_rvv.S 的 kernel，
 *       N = 16/64/256/1024/4096，每个点重复 PERF_REPS 次；
 *   [K] 骨架循环：同样的循环控制与装载、去掉计算指令，用于拆分循环周期的来源。
 * 计时口径见 perf_kernels.S 文件头（fence + mcycle 前后差；空窗口 / 空函数标定开销）。
 *
 * 输出：每次测量一行
 *   PERF,<组>,<名字>,<N>,<rep>,<cycles>,<instret>,<result>,<ok>
 * cycles / instret 是原始读数（未扣开销），扣除与回归由 bench/collect_results.py 完成，
 * 本程序不做任何处理，便于从日志直接复核。
 * ok：结果与本文件的标量参考 naive_dot() 一致为 1，不一致为 0，不比对为 -。
 * 数值正确性另由 difftest 逐条保证（失配会直接中止仿真，不会走到 HIT GOOD TRAP）。
 * 本文件不实现任何 vdot 语义；naive_dot() 是普通的 int8 乘加。
 * ========================================================================= */

typedef unsigned long  u64;
typedef long           i64;
typedef unsigned int   u32;
typedef int            i32;
typedef signed char    i8;
typedef unsigned char  u8;

#ifndef UART_BASE
#define UART_BASE 0x40600000UL      /* XiangShan SoC.scala:163 UARTLiteRange */
#endif
#ifndef PERF_REPS
#define PERF_REPS 5
#endif
#define NMAX 4096

static inline void putch(char c) { *(volatile u8 *)(UART_BASE + 4) = (u8)c; }
static void put_str(const char *s) { while (*s) putch(*s++); }
static void put_dec(u64 v) {
    char b[24]; int n = 0;
    if (!v) { putch('0'); return; }
    while (v) { b[n++] = (char)('0' + v % 10); v /= 10; }
    while (n--) putch(b[n]);
}
static void put_sdec(i64 v) { if (v < 0) { putch('-'); put_dec((u64)(-v)); } else put_dec((u64)v); }

/* start.S（tests/riscv/vdot/start.S:trap_entry）写入的三个量；本程序不应触发任何异常 */
volatile u64 vdot_trap_flag;
volatile u64 vdot_trap_mcause;
volatile u64 vdot_trap_mepc;

static i8 A[NMAX] __attribute__((aligned(64)));
static i8 B[NMAX] __attribute__((aligned(64)));

static i32 naive_dot(const i8 *a, const i8 *b, u64 n) {
    u32 s = 0;
    for (u64 i = 0; i < n; i++) s += (u32)((i32)a[i] * (i32)b[i]);
    return (i32)s;
}

/* ---- perf_kernels.S ---- */
typedef u64 (*wfn)(const i8 *, const i8 *, u64 *);
u64 perf_empty(u64 *out);
u64 perf_s_base(const i8 *, const i8 *, u64 *);
u64 perf_s_vdot(const i8 *, const i8 *, u64 *);
u64 perf_s_base_x(const i8 *, const i8 *, u64 *);
u64 perf_s_vdot_x(const i8 *, const i8 *, u64 *);
#define DECL2(n) u64 n##_16(const i8 *, const i8 *, u64 *); u64 n##_48(const i8 *, const i8 *, u64 *);
DECL2(chain_vdotacc) DECL2(chain_vwaddwv) DECL2(chain_vwredsum) DECL2(chain_vadd) DECL2(indep_vdot) DECL2(chain_vsetadd)
typedef i32 (*kfn)(const i8 *, const i8 *, u64);
u64 perf_call(kfn f, const i8 *a, const i8 *b, u64 n, u64 *out);
i32 perf_nop(const i8 *, const i8 *, u64);
i32 skel_vdotacc(const i8 *, const i8 *, u64);
i32 skel_seqD(const i8 *, const i8 *, u64);

/* ---- bench/baseline/baseline_rvv.S（交付件，原样链接） ---- */
i32 baseline_dot_i8_seqA(const i8 *, const i8 *, u64);
i32 baseline_dot_i8_seqB(const i8 *, const i8 *, u64);
i32 baseline_dot_i8_seqD(const i8 *, const i8 *, u64);
i32 vdot_dot_i8(const i8 *, const i8 *, u64);
i32 vdot_dot_i8_acc2(const i8 *, const i8 *, u64);
i32 vdot4a_dot_i8(const i8 *, const i8 *, u64);
i32 baseline_vdot_single(const i8 *, const i8 *, u64);
i32 vdot_single(const i8 *, const i8 *, u64);

static u32 n_meas, n_bad;

/* 打印一行；check: 1 = 与参考比对，0 = 不比对 */
static void emit(const char *grp, const char *name, u64 n, u32 rep, u64 cyc, u64 ins,
                 i64 res, int check, i32 ref) {
    put_str("PERF,"); put_str(grp); putch(','); put_str(name); putch(',');
    put_dec(n); putch(','); put_dec(rep); putch(','); put_dec(cyc); putch(',');
    put_dec(ins); putch(','); put_sdec(res); putch(',');
    if (check) {
        int ok = ((i32)res == ref);
        putch(ok ? '1' : '0');
        if (!ok) n_bad++;
    } else putch('-');
    putch('\n');
    n_meas++;
}

static void run_window(const char *grp, const char *name, u64 n, wfn f, int check) {
    u64 out[2];
    i32 ref = naive_dot(A, B, 16);
    for (u32 r = 0; r < PERF_REPS; r++) {
        u64 c = f(A, B, out);
        emit(grp, name, n, r, c, out[0], (i64)(i32)out[1], check, ref);
    }
}

static void run_call(const char *grp, const char *name, kfn f, u64 n, int check) {
    u64 out[2];
    i32 ref = naive_dot(A, B, n);
    for (u32 r = 0; r < PERF_REPS; r++) {
        u64 c = perf_call(f, A, B, n, out);
        emit(grp, name, n, r, c, out[0], (i64)(i32)out[1], check, ref);
    }
}

int main(void) {
    /* 与 tests/golden/test_golden.c:176-181 相同的 LCG（种子不同），数据覆盖 -128..127 */
    u32 s = 0x2026c1e5u;
    for (u32 i = 0; i < NMAX; i++) {
        s = s * 1103515245u + 12345u; A[i] = (i8)(s >> 16);
        s = s * 1103515245u + 12345u; B[i] = (i8)(s >> 16);
    }
    /* 预热：A/B 共 8 KiB，DCache 32 KiB（MinimalConfig，Configs.scala:117）；
     * 每个测量点重复 PERF_REPS 次，rep 0 为该代码段第一次执行（ICache / 分支预测器冷），
     * rep 1.. 为热态。数据在初始化时已写入 DCache。 */
    put_str("======================================================================\n");
    put_str(" cie2026-vdot / T3  full-core cycle measurement (mcycle, MinimalConfig)\n");
    put_str("   reps per point = "); put_dec(PERF_REPS); putch('\n');
    put_str("   line format: PERF,group,name,N,rep,cycles,instret,result,ok\n");
    put_str("======================================================================\n");

    u64 out[2];
    for (u32 r = 0; r < PERF_REPS; r++) {
        u64 c = perf_empty(out);
        emit("cal", "empty_window", 0, r, c, out[0], 0, 0, 0);
    }
    run_call("cal", "nop_call", perf_nop, 0, 0);

    /* [S] 单次 16 元素点积 */
    run_window("single", "base_body", 16, perf_s_base, 1);
    run_window("single", "vdot_body", 16, perf_s_vdot, 1);
    run_window("single", "base_body_x", 16, perf_s_base_x, 1);
    run_window("single", "vdot_body_x", 16, perf_s_vdot_x, 1);
    run_call("single", "baseline_vdot_single", baseline_vdot_single, 16, 1);
    run_call("single", "vdot_single", vdot_single, 16, 1);

    /* [C] 依赖链 / 独立串（16 与 48 条，斜率 = 每条的周期） */
    run_window("chain", "vdotacc", 16, chain_vdotacc_16, 0);
    run_window("chain", "vdotacc", 48, chain_vdotacc_48, 0);
    run_window("chain", "vwaddwv", 16, chain_vwaddwv_16, 0);
    run_window("chain", "vwaddwv", 48, chain_vwaddwv_48, 0);
    run_window("chain", "vwredsum", 16, chain_vwredsum_16, 0);
    run_window("chain", "vwredsum", 48, chain_vwredsum_48, 0);
    run_window("chain", "vadd", 16, chain_vadd_16, 0);
    run_window("chain", "vadd", 48, chain_vadd_48, 0);
    run_window("chain", "indep_vdot", 16, indep_vdot_16, 0);
    run_window("chain", "indep_vdot", 48, indep_vdot_48, 0);
    run_window("chain", "vsetadd", 16, chain_vsetadd_16, 0);
    run_window("chain", "vsetadd", 48, chain_vsetadd_48, 0);

    /* [L] 长向量循环 */
    static const u64 NS[] = { 16, 64, 256, 1024, 4096 };
    static const struct { kfn f; const char *name; } L[] = {
        { baseline_dot_i8_seqD, "seqD" },
        { baseline_dot_i8_seqA, "seqA" },
        { baseline_dot_i8_seqB, "seqB" },
        { vdot_dot_i8,          "vdotacc" },
        { vdot_dot_i8_acc2,     "vdotacc_acc2" },
        { vdot4a_dot_i8,        "vdot4a" },
    };
    for (u32 k = 0; k < sizeof(L) / sizeof(L[0]); k++)
        for (u32 j = 0; j < sizeof(NS) / sizeof(NS[0]); j++)
            run_call("loop", L[k].name, L[k].f, NS[j], 1);
    /* 骨架循环（不是点积，不比对结果） */
    for (u32 j = 0; j < sizeof(NS) / sizeof(NS[0]); j++) {
        run_call("skel", "skel_vdotacc", skel_vdotacc, NS[j], 0);
        run_call("skel", "skel_seqD", skel_seqD, NS[j], 0);
    }

    put_str("----------------------------------------------------------------------\n");
    put_str("PERF TOTAL measurements="); put_dec(n_meas); put_str(" result-mismatch="); put_dec(n_bad);
    put_str(" unexpected-trap="); put_dec(vdot_trap_flag); putch('\n');
    put_str(n_bad == 0 && vdot_trap_flag == 0 ? "RESULT: PASS\n" : "RESULT: FAIL\n");
    return (n_bad == 0 && vdot_trap_flag == 0) ? 0 : 1;
}
