/* =========================================================================
 * hello.c —— 2026CIE 赛题阶段一 1.1 环境验证程序
 *
 * 目标：在 NEMU(riscv64-xs-kmhv2 独立解释器) 上真实执行一段 RV64 裸机程序，
 *       由程序自己通过 UARTLITE 串口 MMIO 打印出规定的验证字符串：
 *         hello xiangshan, I am cie2026-vdot, IP address <本机IP>
 *
 * 自证性设计：横幅中的 mvendorid/marchid/mimpid/misa/vlenb 全部由 csrr 从
 * 模拟器实时读出，宿主机无法伪造；串口基址、内存基址、VLEN 三个常量则在
 * 编译期从 NEMU 的生成配置中抽取（见同目录 Makefile），若与实际构建配置
 * 不符，程序连一个字符都打印不出来。
 * ========================================================================= */

#include "nemu_config.h"   /* 构建期由 Makefile 从 NEMU 配置生成 */

/* --- UARTLITE 设备寄存器布局，见 NEMU src/device/uartlite.c:18-21 --- */
#define UARTLITE_RX_FIFO  0x0
#define UARTLITE_TX_FIFO  0x4
#define UARTLITE_STAT_REG 0x8

typedef unsigned long uint64;
typedef unsigned int  uint32;
typedef signed char   int8;

#define read_csr(csr) ({                      \
    uint64 __v;                               \
    __asm__ volatile ("csrr %0, " #csr : "=r"(__v)); \
    __v; })

static inline void putch(char c) {
    /* 1 字节写入 TX FIFO；NEMU 的 serial_io_handler 把它转发到宿主 stderr
     * (src/device/uartlite.c:120-124) */
    *(volatile unsigned char *)(NEMU_UARTLITE_MMIO + UARTLITE_TX_FIFO) =
        (unsigned char)c;
}

static void put_str(const char *s) {
    while (*s) putch(*s++);
}

static void put_hex(uint64 v, int digits) {
    const char *tbl = "0123456789abcdef";
    put_str("0x");
    for (int i = digits - 1; i >= 0; i--)
        putch(tbl[(v >> (i * 4)) & 0xf]);
}

static void put_dec(uint64 v) {
    char buf[24];
    int n = 0;
    if (v == 0) { putch('0'); return; }
    while (v) { buf[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) putch(buf[n]);
}

static void put_i8_array(const char *name, const int8 *p, int n) {
    put_str("     ");
    put_str(name);
    put_str(" = [");
    for (int i = 0; i < n; i++) {
        long v = p[i];
        if (v < 0) { putch('-'); v = -v; }
        put_dec((uint64)v);
        if (i != n - 1) put_str(", ");
    }
    put_str("]\n");
}

/* --- misa 扩展位解码，用于证明模拟器确实带 V 扩展 --- */
static void put_misa_exts(uint64 misa) {
    put_str("(RV");
    put_dec(((misa >> 62) & 3) == 2 ? 64 : 32);
    putch(' ');
    for (int i = 0; i < 26; i++)
        if (misa & (1UL << i)) putch((char)('A' + i));
    putch(')');
}

/* --- RVV 1.0 自检：vsetivli + vadd.vv，与赛题阶段一的向量加法要求对应 --- */
static int8 va[16] __attribute__((aligned(16)));
static int8 vb[16] __attribute__((aligned(16)));
static int8 vc[16] __attribute__((aligned(16)));

static int rvv_vadd_selftest(void) {
    for (int i = 0; i < 16; i++) {
        va[i] = (int8)(i - 8);        /* -8 .. 7，含负数 */
        vb[i] = (int8)(2 * i + 1);    /*  1 .. 31        */
    }
    __asm__ volatile (
        "vsetivli t0, 16, e8, m1, ta, ma \n\t"
        "vle8.v   v1, (%0)              \n\t"
        "vle8.v   v2, (%1)              \n\t"
        "vadd.vv  v3, v1, v2            \n\t"
        "vse8.v   v3, (%2)              \n\t"
        :
        : "r"(va), "r"(vb), "r"(vc)
        : "t0", "memory"
    );
    for (int i = 0; i < 16; i++)
        if (vc[i] != (int8)(va[i] + vb[i])) return i;   /* 返回首个失配下标 */
    return -1;
}

#define LINE "======================================================================\n"
#define SEP  "----------------------------------------------------------------------\n"

int main(void) {
    uint64 mvendorid = read_csr(mvendorid);
    uint64 marchid   = read_csr(marchid);
    uint64 mimpid    = read_csr(mimpid);
    uint64 misa      = read_csr(misa);
    uint64 vlenb     = read_csr(0xc22);   /* vlenb，见 NEMU local-include/csr.h:106 */

    put_str(LINE);
    put_str(" cie2026-vdot / 2026CIE RISC-V vdot  --  Stage-1 environment check\n");
    put_str(SEP);
    put_str(" build config (baked in from the NEMU build that runs this program)\n");
    put_str("   NEMU defconfig  : " NEMU_DEFCONFIG "\n");
    put_str("   NEMU commit     : " NEMU_COMMIT "\n");
    put_str("   image base      : "); put_hex(NEMU_MBASE, 16);         put_str("  (CONFIG_MBASE)\n");
    put_str("   serial MMIO     : "); put_hex(NEMU_UARTLITE_MMIO, 8);  put_str("  (CONFIG_UARTLITE_MMIO, UARTLITE)\n");
    put_str("   NEMU VLEN macro : "); put_dec(NEMU_VLEN);              put_str(" bit\n");
    put_str(SEP);
    put_str(" machine state read back from the simulator via csrr\n");
    put_str("   mvendorid       : "); put_hex(mvendorid, 8);  put_str("\n");
    put_str("   marchid         : "); put_hex(marchid, 8);    put_str("\n");
    put_str("   mimpid          : "); put_hex(mimpid, 8);     put_str("\n");
    put_str("   misa            : "); put_hex(misa, 16);      putch(' ');
                                      put_misa_exts(misa);    put_str("\n");
    put_str("   vlenb           : "); put_dec(vlenb);
                                      put_str(" byte -> VLEN = ");
                                      put_dec(vlenb * 8);     put_str(" bit\n");
    put_str("   VLEN cross-check: ");
    put_str(vlenb * 8 == NEMU_VLEN ? "MATCH (csrr vlenb == NEMU VLEN macro)\n"
                                   : "MISMATCH !!\n");
    put_str(SEP);
    put_str(" RVV 1.0 self-test : vsetivli t0,16,e8,m1,ta,ma ; vadd.vv v3,v1,v2\n");
    int bad = rvv_vadd_selftest();
    put_i8_array("vs2(v1)", va, 16);
    put_i8_array("vs1(v2)", vb, 16);
    put_i8_array("vd (v3)", vc, 16);
    put_str("     result  = ");
    if (bad < 0) put_str("PASS (16/16 lanes match the C reference)\n");
    else { put_str("FAIL at lane "); put_dec((uint64)bad); put_str("\n"); }
    put_str(LINE);

    /* ---- 赛题 1.1 要求的验证字符串 ---- */
    put_str("hello xiangshan, I am cie2026-vdot, IP address " HOST_IP "\n");

    return 0;
}
