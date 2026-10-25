/* perf_csrr_probe.c —— 驱动 perf_csrr_probe.S：每个版本连续测 8 次（中间不打印），最后统一输出 */
typedef unsigned long u64; typedef long i64; typedef unsigned char u8;
#define UART_BASE 0x40600000UL      /* XiangShan SoC.scala:163 UARTLiteRange */
static inline void putch(char c) { *(volatile u8 *)(UART_BASE + 4) = (u8)c; }
static void put_str(const char *s) { while (*s) putch(*s++); }
static void put_dec(u64 v) { char b[24]; int n = 0; if (!v) { putch('0'); return; }
    while (v) { b[n++] = (char)('0' + v % 10); v /= 10; } while (n--) putch(b[n]); }
static void put_sdec(i64 v) { if (v < 0) { putch('-'); put_dec((u64)(-v)); } else put_dec((u64)v); }
volatile u64 vdot_trap_flag, vdot_trap_mcause, vdot_trap_mepc;
u64 nf_empty(void), nf_add50(void), nf_mul50(void), f_empty(void), f_add50(void), f_mul50(void);
static i64 res[6][8];
int main(void) {
    static u64 (*const f[6])(void) = { nf_empty, nf_add50, nf_mul50, f_empty, f_add50, f_mul50 };
    static const char *const nm[6] = { "nofence_empty", "nofence_add50", "nofence_mul50",
                                       "fence_empty", "fence_add50", "fence_mul50" };
    for (int k = 0; k < 6; k++) for (int r = 0; r < 8; r++) res[k][r] = (i64)f[k]();
    for (int k = 0; k < 6; k++) {
        put_str("PROBE,"); put_str(nm[k]);
        for (int r = 0; r < 8; r++) { putch(','); put_sdec(res[k][r]); }
        putch('\n');
    }
    return 0;
}
