/* =========================================================================
 * vdot_dep.c —— 全核 difftest 用：vdot 指令族与其他向量指令的背靠背依赖测试
 *
 * 对每个内核（vdot_dep_kernels.S 中的 K1..K10），每次迭代：
 *   1. 用 xorshift64 生成随机输入：32 个向量寄存器初值 + 64 B 访存缓冲；
 *      随机 AVL（SEW=8 取 0..17，SEW=32 取 0..5，覆盖 vl=0 与 AVL>VLMAX）
 *      与随机 vta / vma；
 *   2. 背靠背版本 kN_fast 与 fence 隔离版本 kN_slow 各跑一次（各自使用输入的独立副本）；
 *   3. 逐字节比较 32 个向量寄存器的终值与 4 个标量结果（含 trap 次数与 mcause 之和）。
 * 判定：
 *   * fast 与 slow 不一致 → 流水线内的旁路 / 唤醒 / 重命名有错（与 NEMU 无关的自洽检查）；
 *   * 两者一致但与 NEMU 不同 → difftest 在提交处直接报错并中止仿真；
 *   * K8 每次必须恰好 trap 3 次、mcause 之和 = 3×2。
 * 本文件不实现任何点积语义；数值正确性由 difftest 与 NEMU 逐条比对给出。
 * ========================================================================= */

typedef unsigned long  u64;
typedef unsigned int   u32;
typedef unsigned char  u8;

#ifndef UART_BASE
#define UART_BASE 0x40600000UL      /* XiangShan SoC.scala:163 UARTLiteRange */
#endif
#ifndef DEP_ITERS
#define DEP_ITERS 200
#endif
#ifndef DEP_SEED
#define DEP_SEED 0x20261025cafef00dUL
#endif

static inline void putch(char c) { *(volatile u8 *)(UART_BASE + 4) = (u8)c; }
static void put_str(const char *s) { while (*s) putch(*s++); }
static void put_dec(u64 v) {
    char b[24]; int n = 0;
    if (!v) { putch('0'); return; }
    while (v) { b[n++] = (char)('0' + v % 10); v /= 10; }
    while (n--) putch(b[n]);
}
static void put_hex(u64 v, int d) {
    const char *t = "0123456789abcdef";
    for (int i = d - 1; i >= 0; i--) putch(t[(v >> (4 * i)) & 0xf]);
}

/* start.S（tests/riscv/vdot/start.S:trap_entry）写入的三个量 */
volatile u64 vdot_trap_flag;
volatile u64 vdot_trap_mcause;
volatile u64 vdot_trap_mepc;

typedef void (*kfn)(const u8 *in, u8 *out, u64 avl8, u64 vt8, u64 avl32, u64 vt32);
#define DECL(n) void k##n##_fast(const u8*, u8*, u64, u64, u64, u64); \
                void k##n##_slow(const u8*, u8*, u64, u64, u64, u64);
DECL(1) DECL(2) DECL(3) DECL(4) DECL(5) DECL(6) DECL(7) DECL(8) DECL(9) DECL(10)

static const struct { kfn fast, slow; const char *name; } K[] = {
    { k1_fast,  k1_slow,  "K1  alu->vdot(vs1,vs2)->vmv.x.s" },
    { k2_fast,  k2_slow,  "K2  vdot->vdotacc chain on vd" },
    { k3_fast,  k3_slow,  "K3  vdot->vadd/vdot4a/vredsum e32" },
    { k4_fast,  k4_slow,  "K4  vmul->vdot4a->vmslt->vdot4a.m" },
    { k5_fast,  k5_slow,  "K5  vmslt->vdot.m->vmsne->vdotacc.m" },
    { k6_fast,  k6_slow,  "K6  vle->vdot->vse->vle->vdotacc" },
    { k7_fast,  k7_slow,  "K7  WAR/WAW rename around vdot" },
    { k8_fast,  k8_slow,  "K8  illegal vdot in pipeline (trap)" },
    { k9_fast,  k9_slow,  "K9  8 indep vdot + 2 merge chains" },
    { k10_fast, k10_slow, "K10 vdotacc loop + branch flush" },
};
#define NK (sizeof(K) / sizeof(K[0]))

#define IN_BYTES  (512 + 64)
#define OUT_BYTES (512 + 32)
static u8 in_master[IN_BYTES] __attribute__((aligned(16)));
static u8 in_fast[IN_BYTES]   __attribute__((aligned(16)));
static u8 in_slow[IN_BYTES]   __attribute__((aligned(16)));
static u8 out_fast[OUT_BYTES] __attribute__((aligned(16)));
static u8 out_slow[OUT_BYTES] __attribute__((aligned(16)));

static u64 rng = DEP_SEED;
static u64 rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

static void copy(u8 *d, const u8 *s, u32 n) {          /* n 为 8 的倍数，按双字搬运 */
    for (u32 i = 0; i < n; i += 8) *(u64 *)(d + i) = *(const u64 *)(s + i);
}
static int differ(const u8 *a, const u8 *b, u32 n) {
    for (u32 i = 0; i < n; i += 8) if (*(const u64 *)(a + i) != *(const u64 *)(b + i)) return 1;
    return 0;
}

static u32 n_fail[NK], n_run[NK], n_trap_bad;

int main(void) {
    put_str("======================================================================\n");
    put_str(" cie2026-vdot / T1  full-core back-to-back dependency test\n");
    put_str("   kernels="); put_dec(NK); put_str(" iters/kernel="); put_dec(DEP_ITERS);
    put_str(" seed=0x"); put_hex(DEP_SEED, 16); putch('\n');
    put_str("======================================================================\n");

    for (u32 it = 0; it < DEP_ITERS; it++) {
        for (u32 k = 0; k < NK; k++) {
            for (u32 i = 0; i < IN_BYTES; i += 8) {
                *(u64 *)(in_master + i) = rnd();
            }
            /* 偶尔放入全 0x80 / 0x7f 的极值寄存器，覆盖乘积符号边界 */
            if ((rnd() & 7) == 0) for (u32 j = 0; j < 16; j++) in_master[8 * 16 + j] = 0x80;
            if ((rnd() & 7) == 0) for (u32 j = 0; j < 16; j++) in_master[9 * 16 + j] = 0x7f;
            u64 r = rnd();
            /* 四分之三的迭代用满 vl，剩下的随机 AVL（含 0 与超过 VLMAX） */
            u64 avl8  = ((r & 3) != 0) ? 16 : ((r >> 2) % 18);
            u64 avl32 = ((r & 3) != 0) ? 4  : ((r >> 8) % 6);
            u64 vtab  = ((r >> 16) & 3) << 6;          /* vma<<7 | vta<<6 */
            u64 vt8   = vtab;                          /* vsew=e8,  LMUL=1 */
            u64 vt32  = vtab | (2u << 3);              /* vsew=e32, LMUL=1 */

            copy(in_fast, in_master, IN_BYTES);
            copy(in_slow, in_master, IN_BYTES);
            K[k].fast(in_fast, out_fast, avl8, vt8, avl32, vt32);
            K[k].slow(in_slow, out_slow, avl8, vt8, avl32, vt32);
            n_run[k]++;

            int bad = 0;
            if (differ(out_fast, out_slow, OUT_BYTES)) bad = 1;
            if (differ(in_fast + 512, in_slow + 512, 64)) bad = 1;
            if (k == 7) {   /* K8：每次恰好 3 次非法指令异常，mcause 均为 2 */
                const u64 *sf = (const u64 *)(out_fast + 512);
                const u64 *ss = (const u64 *)(out_slow + 512);
                if (sf[1] != 3 || sf[2] != 6 || ss[1] != 3 || ss[2] != 6) { n_trap_bad++; bad = 1; }
            }
            if (bad) {
                if (n_fail[k] < 3) {
                    put_str("FAIL "); put_str(K[k].name); put_str(" iter="); put_dec(it);
                    put_str(" avl8="); put_dec(avl8); put_str(" avl32="); put_dec(avl32);
                    put_str(" vtab=0x"); put_hex(vtab, 2); putch('\n');
                    for (u32 v = 0; v < 32; v++) {
                        int d = 0;
                        for (u32 j = 0; j < 16; j++) if (out_fast[16 * v + j] != out_slow[16 * v + j]) d = 1;
                        if (!d) continue;
                        put_str("   v"); put_dec(v); put_str(" fast=");
                        for (int j = 15; j >= 0; j--) put_hex(out_fast[16 * v + j], 2);
                        put_str(" slow=");
                        for (int j = 15; j >= 0; j--) put_hex(out_slow[16 * v + j], 2);
                        putch('\n');
                    }
                    for (u32 s = 0; s < 4; s++) {
                        put_str("   scalar"); put_dec(s); put_str(" fast=0x");
                        put_hex(((const u64 *)(out_fast + 512))[s], 16);
                        put_str(" slow=0x"); put_hex(((const u64 *)(out_slow + 512))[s], 16);
                        putch('\n');
                    }
                }
                n_fail[k]++;
            }
        }
    }

    u32 tot_run = 0, tot_fail = 0;
    put_str("----------------------------------------------------------------------\n");
    put_str("kernel                                   runs(fast+slow)   fail\n");
    for (u32 k = 0; k < NK; k++) {
        put_str(K[k].name);
        put_str("   "); put_dec(n_run[k]); put_str("x2   "); put_dec(n_fail[k]); putch('\n');
        tot_run += n_run[k]; tot_fail += n_fail[k];
    }
    put_str("----------------------------------------------------------------------\n");
    put_str("DEP TOTAL runs="); put_dec(tot_run); put_str("x2 fail="); put_dec(tot_fail);
    put_str(" k8-trap-count-bad="); put_dec(n_trap_bad); putch('\n');
    put_str(tot_fail == 0 ? "RESULT: PASS\n" : "RESULT: FAIL\n");
    return tot_fail == 0 ? 0 : 1;
}
