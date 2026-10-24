/* =========================================================================
 * vdot_test.c —— NEMU 上 vdot / vdotacc / vdot4a 指令族的一致性测试程序
 *
 * 做什么：
 *   逐条读取嵌在镜像里的共享语料（tests/vectors 下的 .txt 经 pack_corpus.py 打包，
 *   期望值由 tests/golden/vdot_ref.c 产生），在 NEMU 上**真实执行**被测指令，
 *   把执行后的 vd 与语料中的 vd_expected 逐字节比对，并通过 UARTLITE 串口
 *   报告 PASS/FAIL 统计。
 *
 * 关键点：
 *   1. 本文件**不含任何点积语义实现**。期望值全部来自语料，比对只是 memcmp。
 *      因此 NEMU 实现一旦与参考模型有任何一位不同，立刻暴露。
 *   2. 语料中 status != OK 的用例表示该配置应当触发 Illegal Instruction
 *      （裁定 S-1 / R1）。测试程序装了 M 态 trap handler（start.S:trap_entry），
 *      会检查「是否真的 trap」「mcause 是否为 2」「vd 是否保持不变」三件事，
 *      缺一不可。反之 status == OK 的用例若发生 trap 也判 FAIL。
 *   3. 被测指令的机器码由 VENC() 宏按位域现场拼出，不是手抄的魔数；
 *      程序启动时会把 6 条编码打印出来，日志里可直接核对。
 *
 * 寄存器分配（固定）：v0 = 掩码, v1 = vs1, v2 = vs2, v3 = vd
 * ========================================================================= */

#include "nemu_config.h"   /* 构建期由 Makefile 从 NEMU 实际构建配置生成 */

typedef unsigned long  u64;
typedef unsigned int   u32;
typedef unsigned short u16;
typedef unsigned char  u8;

/* ---- UARTLITE 设备寄存器布局，见 NEMU src/device/uartlite.c:19-23 ---- */
#define UARTLITE_TX_FIFO 0x4

#ifdef VDOT_QUIET
/* 静默变体：供 difftest ref 共享库（riscv64-nemu-interpreter-so）使用。
 * ref 配置关掉了所有串口设备（configs/riscv64-xs-kmhv2-ref_defconfig 的
 * "# CONFIG_HAS_UARTLITE is not set"），往 UART MMIO 写会越界。
 * 改为写一个 RAM 里的汇点：全部计算与比对逻辑完全不变，只是不输出，
 * 最终以 main 的返回值（失败条数）经 nemu_trap 作为退出码报告结果。 */
static volatile unsigned char uart_sink;
static inline void putch(char c) { uart_sink = (unsigned char)c; }
#else
static inline void putch(char c) {
    *(volatile unsigned char *)(NEMU_UARTLITE_MMIO + UARTLITE_TX_FIFO) = (unsigned char)c;
}
#endif
static void put_str(const char *s) { while (*s) putch(*s++); }
static void put_dec(u64 v) {
    char b[24]; int n = 0;
    if (!v) { putch('0'); return; }
    while (v) { b[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) putch(b[n]);
}
static void put_decw(u64 v, int w) {           /* 右对齐十进制 */
    char b[24]; int n = 0;
    if (!v) b[n++] = '0';
    while (v) { b[n++] = (char)('0' + (v % 10)); v /= 10; }
    for (int i = n; i < w; i++) putch(' ');
    while (n--) putch(b[n]);
}
static void put_hex(u64 v, int digits) {
    const char *t = "0123456789abcdef";
    put_str("0x");
    for (int i = digits - 1; i >= 0; i--) putch(t[(v >> (i * 4)) & 0xf]);
}
static void put_vreg_hex(const u8 *p) {        /* v[0] 在最左，与语料同约定 */
    const char *t = "0123456789abcdef";
    for (int i = 0; i < 16; i++) { putch(t[p[i] >> 4]); putch(t[p[i] & 0xf]); }
}
static void put_pad(const char *s, int w) {
    int n = 0; while (s[n]) n++;
    put_str(s);
    for (int i = n; i < w; i++) putch(' ');
}

/* ---- start.S 中的 trap handler 写入的三个全局量 ---- */
volatile u64 vdot_trap_flag;
volatile u64 vdot_trap_mcause;
volatile u64 vdot_trap_mepc;

#define CAUSE_ILLEGAL_INSTRUCTION 2

/* =========================================================================
 * 被测指令的机器码：按 OPIVV 位域现场拼装
 *   [31:26] funct6 | [25] vm | [24:20] vs2 | [19:15] vs1 | [14:12] funct3=000
 *   | [11:7] vd | [6:0] opcode=1010111
 * ======================================================================= */
#define VD_REG   3
#define VS2_REG  2
#define VS1_REG  1
#define VENC(funct6, vm) ( ((u32)(funct6) << 26) | ((u32)(vm) << 25) \
                         | ((u32)VS2_REG << 20) | ((u32)VS1_REG << 15) \
                         | (0u << 12) | ((u32)VD_REG << 7) | 0x57u )

#define F6_VDOT     0x39   /* 111001 */
#define F6_VDOTACC  0x3a   /* 111010 */
#define F6_VDOT4A   0x3b   /* 111011 */

/* 与 bench/baseline/baseline_rvv.S 的编码自校验锚点同源（见 docs/stage2/13 S-8），
 * 那里用的寄存器是 vd=v3,vs2=v1,vs1=v2，本文件用 vd=v3,vs2=v2,vs1=v1。 */
_Static_assert(VENC(F6_VDOT,    1) == 0xe62081d7u, "vdot.vv  vm=1 encoding");
_Static_assert(VENC(F6_VDOT,    0) == 0xe42081d7u, "vdot.vv  vm=0 encoding");
_Static_assert(VENC(F6_VDOTACC, 1) == 0xea2081d7u, "vdotacc.vv vm=1 encoding");
_Static_assert(VENC(F6_VDOTACC, 0) == 0xe82081d7u, "vdotacc.vv vm=0 encoding");
_Static_assert(VENC(F6_VDOT4A,  1) == 0xee2081d7u, "vdot4a.vv vm=1 encoding");
_Static_assert(VENC(F6_VDOT4A,  0) == 0xec2081d7u, "vdot4a.vv vm=0 encoding");

/* =========================================================================
 * 语料 blob（corpus.S 用 .incbin 嵌入），布局见 pack_corpus.py 文件头注释
 * ======================================================================= */
extern const u8 vdot_corpus[];

typedef struct {
    u8 op, vsew_code, vstart, vl, flags, status, suite_id, pad;
    u8 vs1[16], vs2[16], vd_in[16], vd_exp[16], v0[16];
} rec_t;

static u32 rd32(const u8 *p) {
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}

#define MAX_SUITES 32
static u32 suite_total[MAX_SUITES];
static u32 suite_pass[MAX_SUITES];
static u32 suite_trapcase[MAX_SUITES];

/* =========================================================================
 * 执行一条用例
 *   返回 vl 回读值（供 harness 自检）；vd 执行后的内容写入 vd_out
 * ======================================================================= */
static u64 run_case(const rec_t *r, u8 *vd_out) {
    const u64 vma  = (r->flags >> 2) & 1;
    const u64 vta  = (r->flags >> 1) & 1;
    const u64 vm   =  r->flags       & 1;   /* 1 = 不使用掩码（指令 bit25） */
    /* vtype = vma<<7 | vta<<6 | vsew<<3 | vlmul(=0 -> LMUL=1) */
    const u64 vtype = (vma << 7) | (vta << 6) | ((u64)r->vsew_code << 3);
    u64 vl_rb;

    /* (1) 以 e8/m1/vl=16 把 4 个寄存器整体灌进去（与 vtype 无关的纯字节搬运） */
    __asm__ volatile(
        "vsetivli x0, 16, e8, m1, ta, ma\n\t"
        "vle8.v  v0, (%0)\n\t"
        "vle8.v  v1, (%1)\n\t"
        "vle8.v  v2, (%2)\n\t"
        "vle8.v  v3, (%3)\n\t"
        :
        : "r"(r->v0), "r"(r->vs1), "r"(r->vs2), "r"(r->vd_in)
        : "memory");

    /* (2) 设置本用例真正的 vtype / vl。用 vsetvl 的寄存器形式，
     *     这样 vta/vma/vsew 可以逐用例变化，不需要 16 份立即数变体。
     *     rd = x0 且 rs1 != x0 -> mode 0（普通 stripmining，AVL 取 rs1 的值），
     *     见 NEMU src/isa/riscv64/instr/rvv/vcommon.c:get_mode */
    {
        register u64 a_avl __asm__("a4") = r->vl;
        register u64 a_vt  __asm__("a5") = vtype;
        __asm__ volatile("vsetvl x0, %0, %1" : : "r"(a_avl), "r"(a_vt));
    }
    __asm__ volatile("csrr %0, vl" : "=r"(vl_rb));

    /* (3) 设置 vstart。必须在 vsetvl 之后：set_vtype_vl() 会把 vstart 清零
     *     （NEMU src/isa/riscv64/instr/rvv/vcommon.c:set_vtype_vl 末尾） */
    {
        register u64 a_vs __asm__("a6") = r->vstart;
        __asm__ volatile("csrw vstart, %0" : : "r"(a_vs));
    }

    /* (4) 执行被测指令 */
    vdot_trap_flag   = 0;
    vdot_trap_mcause = 0;
    switch ((u32)r->op * 2u + (u32)vm) {
        case 0: __asm__ volatile(".4byte %0" : : "i"(VENC(F6_VDOT,    0)) : "memory"); break;
        case 1: __asm__ volatile(".4byte %0" : : "i"(VENC(F6_VDOT,    1)) : "memory"); break;
        case 2: __asm__ volatile(".4byte %0" : : "i"(VENC(F6_VDOTACC, 0)) : "memory"); break;
        case 3: __asm__ volatile(".4byte %0" : : "i"(VENC(F6_VDOTACC, 1)) : "memory"); break;
        case 4: __asm__ volatile(".4byte %0" : : "i"(VENC(F6_VDOT4A,  0)) : "memory"); break;
        case 5: __asm__ volatile(".4byte %0" : : "i"(VENC(F6_VDOT4A,  1)) : "memory"); break;
        default: break;
    }

    /* (5) 回读 vd。先清 vstart：若指令因 vstart!=0 抛异常，vstart 按规范
     *     不被修改（§3.7），不清零会让 vse8.v 从元素 vstart 开始存。 */
    __asm__ volatile(
        "csrw vstart, zero\n\t"
        "vsetivli x0, 16, e8, m1, ta, ma\n\t"
        "vse8.v v3, (%0)\n\t"
        :
        : "r"(vd_out)
        : "memory");

    return vl_rb;
}

static int mem16_eq(const u8 *a, const u8 *b) {
    for (int i = 0; i < 16; i++) if (a[i] != b[i]) return 0;
    return 1;
}

static const char *op_name(u32 op) {
    return op == 0 ? "vdot" : (op == 1 ? "vdotacc" : "vdot4a");
}
/* 与 tests/golden/vdot_ref.h 的 enum vdot_status 同值 */
static const char *status_name(u32 st) {
    switch (st) {
        case 0: return "OK";
        case 1: return "ILLEGAL_VSTART";
        case 2: return "ERR_SEW";
        case 4: return "ERR_VSTART_RANGE";
        default: return "UNKNOWN";
    }
}

#define MAX_REPORTED_FAILURES 20

int main(void) {
    /* ---- 语料头部 ---- */
    if (!(vdot_corpus[0] == 'V' && vdot_corpus[1] == 'D' && vdot_corpus[2] == 'O' &&
          vdot_corpus[3] == 'T' && vdot_corpus[4] == 'C' && vdot_corpus[5] == 'O' &&
          vdot_corpus[6] == 'R' && vdot_corpus[7] == 'P')) {
        put_str("FATAL: corpus magic mismatch\n");
        return 2;
    }
    const u32 n_cases  = rd32(vdot_corpus + 8);
    const u32 n_suites = rd32(vdot_corpus + 12);
    const u32 rec_size = rd32(vdot_corpus + 16);
    const u32 hdr_size = rd32(vdot_corpus + 20);
    if (rec_size != sizeof(rec_t) || n_suites > MAX_SUITES) {
        put_str("FATAL: corpus layout mismatch, rec_size=");
        put_dec(rec_size); put_str(" sizeof(rec_t)="); put_dec(sizeof(rec_t));
        put_str(" n_suites="); put_dec(n_suites); putch('\n');
        return 2;
    }
    const char *suite_names = (const char *)(vdot_corpus + 24);
    const rec_t *recs = (const rec_t *)(vdot_corpus + hdr_size);

    /* ---- 环境自述 ---- */
    put_str("======================================================================\n");
    put_str(" cie2026-vdot / P5  NEMU vdot instruction-family conformance test\n");
    put_str("----------------------------------------------------------------------\n");
    put_str("   NEMU defconfig   : " NEMU_DEFCONFIG "\n");
    put_str("   NEMU commit      : " NEMU_COMMIT "\n");
    put_str("   NEMU VLEN macro  : "); put_dec(NEMU_VLEN); put_str(" bit\n");
    {
        u64 vlenb; __asm__ volatile("csrr %0, vlenb" : "=r"(vlenb));
        put_str("   csrr vlenb       : "); put_dec(vlenb);
        put_str(" byte -> VLEN = "); put_dec(vlenb * 8); put_str(" bit (");
        put_str(vlenb * 8 == NEMU_VLEN ? "MATCH" : "MISMATCH"); put_str(")\n");
    }
    put_str("   corpus           : "); put_dec(n_suites); put_str(" suites, ");
    put_dec(n_cases); put_str(" cases, "); put_dec(hdr_size + (u64)n_cases * rec_size);
    put_str(" bytes\n");
    put_str("   instr encodings  : vd=v3 vs2=v2 vs1=v1 (OPIVV, funct3=000)\n");
    put_str("       vdot.vv    vm=1 "); put_hex(VENC(F6_VDOT, 1), 8);
    put_str("   vm=0 "); put_hex(VENC(F6_VDOT, 0), 8); putch('\n');
    put_str("       vdotacc.vv vm=1 "); put_hex(VENC(F6_VDOTACC, 1), 8);
    put_str("   vm=0 "); put_hex(VENC(F6_VDOTACC, 0), 8); putch('\n');
    put_str("       vdot4a.vv  vm=1 "); put_hex(VENC(F6_VDOT4A, 1), 8);
    put_str("   vm=0 "); put_hex(VENC(F6_VDOT4A, 0), 8); putch('\n');
    put_str("======================================================================\n\n");

    u8 vd_out[16];
    u32 n_pass = 0, n_fail = 0;
    u32 n_trap_expected = 0, n_trap_ok = 0;
    u32 n_unexpected_trap = 0, n_missing_trap = 0;
    u32 n_value_mismatch = 0, n_wrong_cause = 0, n_vl_mismatch = 0;
    u32 n_reported = 0;

    for (u32 i = 0; i < n_cases; i++) {
        const rec_t *r = &recs[i];
        u64 vl_rb = run_case(r, vd_out);

        const int trapped   = (vdot_trap_flag != 0);
        const int want_trap = (r->status != 0);
        int ok = 1;

        if (vl_rb != r->vl) { n_vl_mismatch++; ok = 0; }

        if (want_trap) {
            n_trap_expected++;
            if (!trapped) { n_missing_trap++; ok = 0; }
            else if (vdot_trap_mcause != CAUSE_ILLEGAL_INSTRUCTION) { n_wrong_cause++; ok = 0; }
            else n_trap_ok++;
        } else if (trapped) {
            n_unexpected_trap++; ok = 0;
        }
        /* 语料保证 status != OK 时 vd_expected == vd_in，故两种情形统一比 vd_expected */
        if (!mem16_eq(vd_out, r->vd_exp)) { n_value_mismatch++; ok = 0; }

        suite_total[r->suite_id]++;
        if (r->status != 0) suite_trapcase[r->suite_id]++;
        if (ok) { suite_pass[r->suite_id]++; n_pass++; }
        else {
            n_fail++;
            if (n_reported < MAX_REPORTED_FAILURES) {
                n_reported++;
                put_str("FAIL #"); put_dec(i);
                put_str("  suite="); put_str(suite_names + 32 * r->suite_id);
                put_str("  op="); put_str(op_name(r->op));
                put_str("  vsew="); put_dec(8u << r->vsew_code);
                put_str(" vstart="); put_dec(r->vstart);
                put_str(" vl="); put_dec(r->vl);
                put_str(" vm="); put_dec(r->flags & 1);
                put_str(" vta="); put_dec((r->flags >> 1) & 1);
                put_str(" vma="); put_dec((r->flags >> 2) & 1);
                put_str(" status="); put_str(status_name(r->status)); putch('\n');
                put_str("        vs1      = "); put_vreg_hex(r->vs1);    putch('\n');
                put_str("        vs2      = "); put_vreg_hex(r->vs2);    putch('\n');
                put_str("        v0       = "); put_vreg_hex(r->v0);     putch('\n');
                put_str("        vd_in    = "); put_vreg_hex(r->vd_in);  putch('\n');
                put_str("        expected = "); put_vreg_hex(r->vd_exp); putch('\n');
                put_str("        actual   = "); put_vreg_hex(vd_out);    putch('\n');
                put_str("        trapped="); put_dec((u64)trapped);
                put_str(" mcause="); put_dec(vdot_trap_mcause);
                put_str(" vl_readback="); put_dec(vl_rb); putch('\n');
            } else if (n_reported == MAX_REPORTED_FAILURES) {
                n_reported++;
                put_str("... (更多失败用例不再逐条打印)\n");
            }
        }
    }

    /* ---- 分 suite 汇总 ---- */
    putch('\n');
    put_str("---------------------------------------------------------------------\n");
    put_str("suite                      cases    pass    fail   must-trap\n");
    put_str("---------------------------------------------------------------------\n");
    for (u32 s = 0; s < n_suites; s++) {
        put_pad(suite_names + 32 * s, 25);
        put_decw(suite_total[s], 8);
        put_decw(suite_pass[s], 8);
        put_decw(suite_total[s] - suite_pass[s], 8);
        put_decw(suite_trapcase[s], 12);
        putch('\n');
    }
    put_str("---------------------------------------------------------------------\n");
    put_str("TOTAL cases="); put_dec(n_cases);
    put_str(" pass=");       put_dec(n_pass);
    put_str(" fail=");       put_dec(n_fail);
    putch('\n');
    put_str("  must-trap cases (status != OK) = "); put_dec(n_trap_expected);
    put_str(" , trapped with mcause=2 = ");         put_dec(n_trap_ok); putch('\n');
    put_str("  missing-trap=");       put_dec(n_missing_trap);
    put_str("  unexpected-trap=");    put_dec(n_unexpected_trap);
    put_str("  wrong-mcause=");       put_dec(n_wrong_cause);
    put_str("  value-mismatch=");     put_dec(n_value_mismatch);
    put_str("  vl-readback-mismatch="); put_dec(n_vl_mismatch);
    putch('\n');
    put_str("RESULT: ");
    put_str(n_fail == 0 ? "PASS" : "FAIL");
    putch('\n');
    put_str("---------------------------------------------------------------------\n");

    return n_fail == 0 ? 0 : 1;
}
