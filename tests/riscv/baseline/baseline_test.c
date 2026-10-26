/* =========================================================================
 * baseline_test.c —— 赛题 3.2「基线功能实现」：RVV 1.0 基线序列 vs vdot 指令族
 *                    在 NEMU 上的逐位等价性验证 + 动态指令数实测
 *
 * 做三件事：
 *
 *  [A] 单次点积等价性
 *      对共享语料（tests/vectors，经 pack_corpus.py 打包）中每一条 status==OK
 *      的用例，在同一台 NEMU 上分别执行
 *        (1) 只用 RVV 1.0 标准指令的基线序列（本文件 run_baseline()）
 *        (2) 自定义指令 vdot / vdotacc / vdot4a（本文件 run_vdot()）
 *      再把两者同时与语料里的 vd_expected（由 tests/golden/vdot_ref.c 产生）
 *      逐字节比对。三方全等才算 PASS。
 *
 *      本文件**不含任何点积语义实现**：基线侧是 RVV 1.0 指令本身，vdot 侧是
 *      被测的自定义指令，期望值来自语料，比对只是 memcmp。
 *
 *  [B] 长向量循环等价性
 *      直接链接交付件 bench/baseline/baseline_rvv.S 里的五个 kernel
 *      （基线 A / B / D、vdotacc 版、vdot4a 版），对 N = 64/256/1024/4096
 *      以及若干非 16 整数倍的 N，与本文件里的纯标量 C 参考实现比对。
 *
 *  [C] 动态指令数实测
 *      用 M 态 CSR `minstret` 在 kernel 前后各读一次，差值即该 kernel 真实
 *      执行的指令条数。NEMU 的配置是 CONFIG_INSTR_CNT_BY_INSTR=1
 *      （work/NEMU/include/generated/autoconf.h:17），
 *      get_minstret() = minstret->val + get_abs_instr_count_csr()
 *      （work/NEMU/src/isa/riscv64/system/priv.c:991-993），
 *      get_abs_instr_count_csr() 在 BY_INSTR 下直接返回 g_nr_guest_instr
 *      （work/NEMU/src/cpu/cpu-exec.c:132-137），即逐条精确计数。
 *      两次 csrr 自身的开销由 measure_overhead() 现场标定后扣除。
 *
 * 寄存器分配（固定）：
 *      v0 = 掩码, v1 = vs1, v2 = vs2, v3 = vdot 侧的 vd, v8 = 基线侧的 vd
 *      v4:v5 = 基线的中间结果（vwmul 的加宽积 / vdot4a 的移位临时量）
 *      v9 = 基线 vdotacc 的滑动临时量
 * ========================================================================= */

#include "nemu_config.h"   /* 构建期由 Makefile 从 NEMU 实际构建配置生成 */

typedef unsigned long  u64;
typedef unsigned int   u32;
typedef signed   int   i32;
typedef signed   char  i8;
typedef unsigned char  u8;

/* ---- UARTLITE 设备寄存器布局，见 NEMU src/device/uartlite.c:19-23 ---- */
#define UARTLITE_TX_FIFO 0x4

#ifdef VDOT_QUIET
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
static void put_decw(u64 v, int w) {
    char b[24]; int n = 0;
    if (!v) b[n++] = '0';
    while (v) { b[n++] = (char)('0' + (v % 10)); v /= 10; }
    for (int i = n; i < w; i++) putch(' ');
    while (n--) putch(b[n]);
}
static void put_i32(i32 v) {
    if (v < 0) { putch('-'); put_dec((u64)(-(long)v)); } else put_dec((u64)v);
}
static void put_hex(u64 v, int digits) {
    const char *t = "0123456789abcdef";
    put_str("0x");
    for (int i = digits - 1; i >= 0; i--) putch(t[(v >> (i * 4)) & 0xf]);
}
static void put_vreg_hex(const u8 *p) {
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

/* =========================================================================
 * vdot 指令族机器码（与 tests/riscv/vdot/vdot_test.c 完全同源，vd=v3）
 * ======================================================================= */
#define VD_REG   3
#define VS2_REG  2
#define VS1_REG  1
#define VENC(funct6, vm) ( ((u32)(funct6) << 26) | ((u32)(vm) << 25) \
                         | ((u32)VS2_REG << 20) | ((u32)VS1_REG << 15) \
                         | (0u << 12) | ((u32)VD_REG << 7) | 0x57u )
#define F6_VDOT     0x39
#define F6_VDOTACC  0x3a
#define F6_VDOT4A   0x3b
_Static_assert(VENC(F6_VDOT,    1) == 0xe62081d7u, "vdot.vv  vm=1 encoding");
_Static_assert(VENC(F6_VDOTACC, 1) == 0xea2081d7u, "vdotacc.vv vm=1 encoding");
_Static_assert(VENC(F6_VDOT4A,  1) == 0xee2081d7u, "vdot4a.vv vm=1 encoding");

/* =========================================================================
 * 语料 blob，布局见 tests/riscv/vdot/pack_corpus.py 文件头注释
 * ======================================================================= */
extern const u8 vdot_corpus[];

typedef struct {
    u8 op, vsew_code, vstart, vl, flags, status, suite_id, pad;
    u8 vs1[16], vs2[16], vd_in[16], vd_exp[16], v0[16];
} rec_t;

static u32 rd32(const u8 *p) {
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}

/* =========================================================================
 * minstret 读数（M 态）
 * ======================================================================= */
static inline u64 rd_minstret(void) {
    u64 v; __asm__ volatile("csrr %0, minstret" : "=r"(v) :: "memory"); return v;
}

/* =========================================================================
 * 公共：把 v0/v1/v2/v3/v8 灌进向量寄存器（纯字节搬运，与 vtype 无关）
 * ======================================================================= */
static inline void load_operands(const rec_t *r) {
    __asm__ volatile(
        "vsetivli x0, 16, e8, m1, ta, ma\n\t"
        "vle8.v  v0, (%0)\n\t"
        "vle8.v  v1, (%1)\n\t"
        "vle8.v  v2, (%2)\n\t"
        "vle8.v  v3, (%3)\n\t"
        "vle8.v  v8, (%3)\n\t"
        :
        : "r"(r->v0), "r"(r->vs1), "r"(r->vs2), "r"(r->vd_in)
        : "memory");
}

/* 回读某个向量寄存器（只支持 v3 / v8 两个固定编号，避免动态编码） */
static inline void store_v3(u8 *out) {
    __asm__ volatile(
        "csrw vstart, zero\n\t"
        "vsetivli x0, 16, e8, m1, ta, ma\n\t"
        "vse8.v v3, (%0)\n\t" :: "r"(out) : "memory");
}
static inline void store_v8(u8 *out) {
    __asm__ volatile(
        "csrw vstart, zero\n\t"
        "vsetivli x0, 16, e8, m1, ta, ma\n\t"
        "vse8.v v8, (%0)\n\t" :: "r"(out) : "memory");
}

/* 设置 vtype/vl：vsetvl x0, a4, a5（rd=x0 且 rs1!=x0 -> 普通 stripmining） */
static inline u64 set_vtype(u64 avl, u64 vtype) {
    register u64 a_avl __asm__("a4") = avl;
    register u64 a_vt  __asm__("a5") = vtype;
    u64 vl_rb;
    __asm__ volatile("vsetvl x0, %1, %2\n\tcsrr %0, vl"
                     : "=r"(vl_rb) : "r"(a_avl), "r"(a_vt));
    return vl_rb;
}
static inline void set_vstart(u64 v) {
    __asm__ volatile("csrw vstart, %0" :: "r"(v));
}

/* =========================================================================
 * run_vdot —— 执行被测的自定义指令，结果留在 v3
 * ======================================================================= */
static u64 run_vdot(const rec_t *r, u8 *vd_out) {
    const u64 vma  = (r->flags >> 2) & 1;
    const u64 vta  = (r->flags >> 1) & 1;
    const u64 vm   =  r->flags       & 1;
    const u64 vtype = (vma << 7) | (vta << 6) | ((u64)r->vsew_code << 3);
    u64 vl_rb;

    load_operands(r);
    vl_rb = set_vtype(r->vl, vtype);
    set_vstart(r->vstart);

    vdot_trap_flag = 0; vdot_trap_mcause = 0;
    switch ((u32)r->op * 2u + (u32)vm) {
        case 0: __asm__ volatile(".4byte %0" :: "i"(VENC(F6_VDOT,    0)) : "memory"); break;
        case 1: __asm__ volatile(".4byte %0" :: "i"(VENC(F6_VDOT,    1)) : "memory"); break;
        case 2: __asm__ volatile(".4byte %0" :: "i"(VENC(F6_VDOTACC, 0)) : "memory"); break;
        case 3: __asm__ volatile(".4byte %0" :: "i"(VENC(F6_VDOTACC, 1)) : "memory"); break;
        case 4: __asm__ volatile(".4byte %0" :: "i"(VENC(F6_VDOT4A,  0)) : "memory"); break;
        case 5: __asm__ volatile(".4byte %0" :: "i"(VENC(F6_VDOT4A,  1)) : "memory"); break;
        default: break;
    }
    store_v3(vd_out);
    return vl_rb;
}

/* =========================================================================
 * run_baseline —— 只用 RVV 1.0 标准指令完成同样的功能，结果留在 v8
 *
 * 序列严格照抄 bench/baseline/baseline_ref.c 的 baseline_vdot_vv /
 * baseline_vdotacc_vv / baseline_vdot4a_vv（那是宿主端的微型 RVV 解释器，
 * 本函数是同一序列的**真机汇编**版本）：
 *
 *   vdot.vv   : vsetvli(AVL=vl<<2) e32,m1 -> vmv.v.i v8,0
 *               vsetvli e8 ,m1 -> vwmul.vv v4,v2,v1
 *               vsetvli e16,m2,tu -> vwredsum.vs v8,v4,v8[,v0.t]   共 6 条
 *   vdotacc.vv: vsetvli(AVL=vl<<2) e32,m1 -> vslideup.vi v9,v8,3
 *               -> vslidedown.vi v8,v9,3（保留 v8[0]、清零 v8[1..3]）
 *               + 与 vdot 相同的后 4 条                              共 7 条
 *   vdot4a.vv : vsetvli e32,m1 + 4 组「移位抽子字节 + vmacc」        共 19 条
 *
 * vdot / vdotacc 的写回按裁定 S-3'：vl!=0 时 vd = {结果, 0, 0, 0}，与 vta/vma
 * 无关；vl==0 时 vd 不写。基线为此：
 *   - 第 1 条 vsetvli 用 AVL = vl<<2：vl==0 时 vl32=0（其后 e32 指令全部不写），
 *     vl>=1 时 AVL ∈ {4,8,...,64}，按 RVV §6.3 必得 vl32 = VLMAX = 4（AVL 不会落在
 *     实现可自定的 (VLMAX, 2*VLMAX) 区间），于是清零覆盖整个寄存器、没有 tail；
 *   - 归约 vwredsum.vs 强制 tu（vtype 的 vta 位清 0），元素 1..3 保持上一步清出的 0。
 *   修订前（原裁定 S-3）vdotacc 只需 4 条；RVV 1.0 没有「保留元素 0、其余清零」的
 *   单条指令，多出的 3 条（vsetvli + 两条滑动）是新语义的真实代价。
 *
 * 返回执行过的**向量指令条数**（不含操作数装载/回读），供指令数对照使用。
 * ======================================================================= */
static int run_baseline(const rec_t *r, u8 *vd_out) {
    const u64 vma = (r->flags >> 2) & 1;
    const u64 vta = (r->flags >> 1) & 1;
    const u64 vm  =  r->flags       & 1;
    const u64 vtype8   = (vma << 7) | (vta << 6) | (0ul << 3) | 0ul;  /* e8 , LMUL=1 */
    const u64 vtype16tu = (vma << 7) | (1ul << 3) | 1ul;              /* e16, LMUL=2, tu（S-3'） */
    const u64 vtype32  = (vma << 7) | (vta << 6) | (2ul << 3) | 0ul;  /* e32, LMUL=1 */
    int nvec = 0;

    load_operands(r);
    vdot_trap_flag = 0; vdot_trap_mcause = 0;

    if (r->op == 0 || r->op == 1) {              /* vdot / vdotacc */
        /* AVL = vl<<2：vl==0 -> vl32=0；vl>=1 -> vl32=VLMAX=4（见函数头注释），
         * 与参考模型 baseline_ref.c 的 vl32_of() 一致 */
        set_vtype((u64)r->vl << 2, vtype32);     nvec++;
        if (r->op == 0) {
            __asm__ volatile("vmv.v.i v8, 0" ::: "memory");          nvec++;
        } else {
            __asm__ volatile("vslideup.vi v9, v8, 3" ::: "memory");   nvec++;
            __asm__ volatile("vslidedown.vi v8, v9, 3" ::: "memory"); nvec++;
        }
        set_vtype(r->vl, vtype8);                nvec++;
        __asm__ volatile("vwmul.vv v4, v2, v1" ::: "memory"); nvec++;
        set_vtype(r->vl, vtype16tu);             nvec++;
        if (vm) __asm__ volatile("vwredsum.vs v8, v4, v8"      ::: "memory");
        else    __asm__ volatile("vwredsum.vs v8, v4, v8, v0.t" ::: "memory");
        nvec++;
    } else {                                     /* vdot4a */
        set_vtype(r->vl, vtype32);               nvec++;
        /* 每条向量指令前都要重置 vstart：RVV 规定指令执行完毕会把 vstart 清零，
         * 而参考模型是把同一个 vstart 传给序列中的每一条指令。基线要表达
         * vstart != 0 的语义，就必须额外插入 19 条 csrw —— 这本身就是
         * 「RVV 1.0 没有子字节点积原语」的代价之一。 */
#define VS() set_vstart(r->vstart)
        VS(); __asm__ volatile("vsll.vi v4, v1, 24" ::: "memory"); nvec++;
        VS(); __asm__ volatile("vsra.vi v4, v4, 24" ::: "memory"); nvec++;
        VS(); __asm__ volatile("vsll.vi v5, v2, 24" ::: "memory"); nvec++;
        VS(); __asm__ volatile("vsra.vi v5, v5, 24" ::: "memory"); nvec++;
        VS();
        if (vm) __asm__ volatile("vmacc.vv v8, v4, v5"       ::: "memory");
        else    __asm__ volatile("vmacc.vv v8, v4, v5, v0.t" ::: "memory");
        nvec++;

        VS(); __asm__ volatile("vsll.vi v4, v1, 16" ::: "memory"); nvec++;
        VS(); __asm__ volatile("vsra.vi v4, v4, 24" ::: "memory"); nvec++;
        VS(); __asm__ volatile("vsll.vi v5, v2, 16" ::: "memory"); nvec++;
        VS(); __asm__ volatile("vsra.vi v5, v5, 24" ::: "memory"); nvec++;
        VS();
        if (vm) __asm__ volatile("vmacc.vv v8, v4, v5"       ::: "memory");
        else    __asm__ volatile("vmacc.vv v8, v4, v5, v0.t" ::: "memory");
        nvec++;

        VS(); __asm__ volatile("vsll.vi v4, v1, 8"  ::: "memory"); nvec++;
        VS(); __asm__ volatile("vsra.vi v4, v4, 24" ::: "memory"); nvec++;
        VS(); __asm__ volatile("vsll.vi v5, v2, 8"  ::: "memory"); nvec++;
        VS(); __asm__ volatile("vsra.vi v5, v5, 24" ::: "memory"); nvec++;
        VS();
        if (vm) __asm__ volatile("vmacc.vv v8, v4, v5"       ::: "memory");
        else    __asm__ volatile("vmacc.vv v8, v4, v5, v0.t" ::: "memory");
        nvec++;

        VS(); __asm__ volatile("vsra.vi v4, v1, 24" ::: "memory"); nvec++;
        VS(); __asm__ volatile("vsra.vi v5, v2, 24" ::: "memory"); nvec++;
        VS();
        if (vm) __asm__ volatile("vmacc.vv v8, v4, v5"       ::: "memory");
        else    __asm__ volatile("vmacc.vv v8, v4, v5, v0.t" ::: "memory");
        nvec++;
#undef VS
    }
    store_v8(vd_out);
    return nvec;
}

static int mem16_eq(const u8 *a, const u8 *b) {
    for (int i = 0; i < 16; i++) if (a[i] != b[i]) return 0;
    return 1;
}
static const char *op_name(u32 op) {
    return op == 0 ? "vdot" : (op == 1 ? "vdotacc" : "vdot4a");
}

/* =========================================================================
 * [B] 长向量循环 —— 直接调用交付件 bench/baseline/baseline_rvv.S 的 kernel
 * ======================================================================= */
extern i32 baseline_dot_i8_seqA(const i8 *a, const i8 *b, u64 n);
extern i32 baseline_dot_i8_seqB(const i8 *a, const i8 *b, u64 n);
extern i32 baseline_dot_i8_seqD(const i8 *a, const i8 *b, u64 n);
extern i32 vdot_dot_i8        (const i8 *a, const i8 *b, u64 n);
extern i32 vdot4a_dot_i8      (const i8 *a, const i8 *b, u64 n);
extern i32 vdot_dot_i8_acc2   (const i8 *a, const i8 *b, u64 n);
extern i32 baseline_vdot_single(const i8 *a, const i8 *b, u64 n);
extern i32 vdot_single         (const i8 *a, const i8 *b, u64 n);

/* 空 kernel：用于标定「调用约定 + 实参装填 + ret」的固有开销，
 * 使单次点积的指令数对照只剩下 kernel 本体。 */
__asm__(".text\n.balign 4\n.globl bench_nop_kernel\nbench_nop_kernel:\n\tret\n");
extern i32 bench_nop_kernel(const i8 *a, const i8 *b, u64 n);

#define NMAX 4096
static i8 g_a[NMAX], g_b[NMAX];

/* 与 tests/golden/test_golden.c:176-181 完全相同的 LCG，保证宿主端与
 * NEMU 端用的是同一组数据 */
static void gen_vectors(void) {
    u32 rs = 0x1234567u;
    for (int i = 0; i < NMAX; i++) {
        rs = rs * 1103515245u + 12345u;  g_a[i] = (i8)((rs >> 16) & 0xFF);
        rs = rs * 1103515245u + 12345u;  g_b[i] = (i8)((rs >> 16) & 0xFF);
    }
}
/* 纯标量 C 参考（32 位回绕，与 vdot 语义一致） */
static i32 naive_dot(const i8 *a, const i8 *b, u64 n) {
    u32 s = 0;
    for (u64 i = 0; i < n; i++) s += (u32)((i32)a[i] * (i32)b[i]);
    return (i32)s;
}

/* 两次 csrr minstret 之间的固有开销（条） */
static u64 g_ovh;
static void measure_overhead(void) {
    u64 t0 = rd_minstret();
    u64 t1 = rd_minstret();
    g_ovh = t1 - t0;
}

typedef i32 (*kern_t)(const i8 *, const i8 *, u64);
typedef struct { const char *name; kern_t fn; } kern_ent_t;

/* 静态指令条数：从函数入口逐条解码到第一条 ret（含）为止。
 * 只用于 baseline_vdot_single / vdot_single 这类无分支的直线型函数。
 * RVC：低 2 位 != 0b11 为 16 位指令，c.jr ra = 0x8082；否则为 32 位指令，
 * jalr x0, 0(ra) = 0x00008067。上限 256 条，超出返回 0（视为测量失败）。 */
static u64 count_static_until_ret(kern_t fn) {
    const volatile unsigned short *p = (const volatile unsigned short *)(unsigned long)fn;
    for (u64 n = 1; n <= 256; n++) {
        unsigned short lo = p[0];
        if ((lo & 3u) != 3u) {
            if (lo == 0x8082u) return n;
            p += 1;
        } else {
            unsigned int w = (unsigned int)lo | ((unsigned int)p[1] << 16);
            if (w == 0x00008067u) return n;
            p += 2;
        }
    }
    return 0;
}

static const kern_ent_t KERNS[] = {
    { "baseline_A",  baseline_dot_i8_seqA },
    { "baseline_B",  baseline_dot_i8_seqB },
    { "baseline_D",  baseline_dot_i8_seqD },
    { "vdotacc",     vdot_dot_i8          },
    { "vdot4a",      vdot4a_dot_i8        },
    { "vdotacc_acc2", vdot_dot_i8_acc2    },   /* 2 路累加器轮转（排在最后，不影响前五行的输出顺序） */
};
#define NKERN (int)(sizeof(KERNS) / sizeof(KERNS[0]))

static const u64 N_PERF[] = { 64, 256, 1024, 4096 };
#define NPERF (int)(sizeof(N_PERF) / sizeof(N_PERF[0]))
/* 等价性检查还要覆盖非 16 整数倍（vdot4a 要求 4 的倍数，单列） */
static const u64 N_EQ[]   = { 0, 4, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 };
#define NEQ (int)(sizeof(N_EQ) / sizeof(N_EQ[0]))
static const u64 N_ODD[]  = { 1, 2, 3, 5, 15, 17, 31, 33, 63, 127, 255, 1023, 4095 };
#define NODD (int)(sizeof(N_ODD) / sizeof(N_ODD[0]))

#define MAX_SUITES 32
static u32 suite_total[MAX_SUITES], suite_run[MAX_SUITES];
static u32 suite_pass[MAX_SUITES], suite_skip[MAX_SUITES];

#define MAX_REPORTED_FAILURES 20

int main(void) {
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
        put_str("FATAL: corpus layout mismatch\n");
        return 2;
    }
    const char *suite_names = (const char *)(vdot_corpus + 24);
    const rec_t *recs = (const rec_t *)(vdot_corpus + hdr_size);

    put_str("======================================================================\n");
    put_str(" cie2026-vdot / P7  RVV 1.0 baseline <-> vdot equivalence on NEMU\n");
    put_str("----------------------------------------------------------------------\n");
    put_str("   NEMU defconfig   : " NEMU_DEFCONFIG "\n");
    put_str("   NEMU commit      : " NEMU_COMMIT "\n");
    {
        u64 vlenb; __asm__ volatile("csrr %0, vlenb" : "=r"(vlenb));
        put_str("   csrr vlenb       : "); put_dec(vlenb);
        put_str(" byte -> VLEN = "); put_dec(vlenb * 8); put_str(" bit (");
        put_str(vlenb * 8 == NEMU_VLEN ? "MATCH" : "MISMATCH"); put_str(")\n");
    }
    put_str("   corpus           : "); put_dec(n_suites); put_str(" suites, ");
    put_dec(n_cases); put_str(" cases\n");
    put_str("   baseline         : RVV 1.0 only (vmv.v.i / vslideup.vi / vslidedown.vi /\n");
    put_str("                      vwmul.vv / vwredsum.vs,\n");
    put_str("                      vsll.vi / vsra.vi / vmacc.vv for vdot4a)\n");
    put_str("   vdot encodings   : vdot "); put_hex(VENC(F6_VDOT, 1), 8);
    put_str("  vdotacc ");         put_hex(VENC(F6_VDOTACC, 1), 8);
    put_str("  vdot4a ");          put_hex(VENC(F6_VDOT4A, 1), 8); putch('\n');
    put_str("======================================================================\n\n");

    /* ================= [A0] 对照实验：vstart != 0 下标准 RVV 算术指令的行为 ==== */
    put_str("--- [A0] control experiment: vstart != 0 on standard RVV-1.0 arithmetic ---\n");
    put_str("    (NEMU arithmetic_instr() calls check_vstart_exception()，\n");
    put_str("     work/NEMU/src/isa/riscv64/instr/rvv/vcompute_impl.c:544；\n");
    put_str("     对照香山 VecExceptionGen.scala 的 vstartIllegal = isVArith && vstart != 0)\n\n");
    {
        static const u8 zero16[16] = {0};
        rec_t probe;
        for (u32 z = 0; z < sizeof(probe); z++) ((u8 *)&probe)[z] = 0;
        for (int z = 0; z < 16; z++) {
            probe.vs1[z] = (u8)(z + 1); probe.vs2[z] = 2;
            probe.vd_in[z] = 0; probe.v0[z] = 0xff;
        }
        (void)zero16;
        probe.vl = 4; probe.flags = 1 /*vm=1*/ | 2 /*vta*/ | 4 /*vma*/;
        put_str("    instruction        vstart=0 -> trap?   vstart=1 -> trap?(mcause)\n");
#define PROBE(label, VTYPE, VL, ASMSTR)                                        \
        do {                                                                   \
            int t0_, t1_; u64 c1_;                                             \
            load_operands(&probe);                                             \
            set_vtype((VL), (VTYPE)); set_vstart(0);                           \
            vdot_trap_flag = 0; __asm__ volatile(ASMSTR ::: "memory");         \
            t0_ = (int)vdot_trap_flag;                                         \
            load_operands(&probe);                                             \
            set_vtype((VL), (VTYPE)); set_vstart(1);                           \
            vdot_trap_flag = 0; __asm__ volatile(ASMSTR ::: "memory");         \
            t1_ = (int)vdot_trap_flag; c1_ = vdot_trap_mcause;                 \
            set_vstart(0);                                                     \
            put_str("    "); put_pad(label, 19);                               \
            put_pad(t0_ ? "TRAP" : "no trap", 20);                             \
            if (t1_) { put_str("TRAP  mcause="); put_dec(c1_); } else put_str("no trap"); \
            putch('\n');                                                       \
        } while (0)
        /* e8/m1 */
        PROBE("vadd.vv",     (2ul<<6)|(0ul<<3)|0ul, 16, "vadd.vv v4, v2, v1");
        PROBE("vwmul.vv",    (2ul<<6)|(0ul<<3)|0ul, 16, "vwmul.vv v4, v2, v1");
        /* e16/m2 */
        PROBE("vwredsum.vs", (2ul<<6)|(1ul<<3)|1ul, 16, "vwredsum.vs v8, v4, v8");
        /* e32/m1 */
        PROBE("vmv.s.x",     (2ul<<6)|(2ul<<3)|0ul,  4, "vmv.s.x v8, x0");
        PROBE("vsll.vi",     (2ul<<6)|(2ul<<3)|0ul,  4, "vsll.vi v4, v1, 24");
        PROBE("vsra.vi",     (2ul<<6)|(2ul<<3)|0ul,  4, "vsra.vi v4, v4, 24");
        PROBE("vmacc.vv",    (2ul<<6)|(2ul<<3)|0ul,  4, "vmacc.vv v8, v4, v5");
        PROBE("vdot4a.vv",   (2ul<<6)|(2ul<<3)|0ul,  4, ".4byte " "0xee2081d7");
#undef PROBE
        putch('\n');
    }

    /* ================= [A] 单次点积等价性 ================= */
    put_str("--- [A] single dot product: baseline(RVV1.0) vs vdot vs corpus golden ---\n\n");
    u8 vd_base[16], vd_vd[16];
    u32 n_run = 0, n_pass = 0, n_skip = 0;
    u32 n_base_vs_golden = 0, n_vdot_vs_golden = 0, n_base_vs_vdot = 0;
    u32 n_base_trap = 0, n_vdot_trap = 0, n_vl_mismatch = 0;
    u32 n_reported = 0, n_inexpressible = 0;
    int base_instr_vdot = 0, base_instr_vdotacc = 0, base_instr_vdot4a = 0;

    for (u32 i = 0; i < n_cases; i++) {
        const rec_t *r = &recs[i];
        suite_total[r->suite_id]++;
        if (r->status != 0) {
            /* 架构上必须抛 Illegal Instruction 的配置：RVV 1.0 基线侧的
             * vwredsum.vs 同样禁止 vstart!=0，没有可对照的指令编码。
             * 这些用例已在 P5 (tests/riscv/vdot) 中单独验证过 trap 行为。 */
            n_skip++; suite_skip[r->suite_id]++;
            continue;
        }
        if (r->vstart != 0) {
            /* 语料判定该配置可正常执行（status==OK）且 vstart!=0。
             * 这只可能是 vdot4a（裁定 S-7）。基线**无法表达**：见 [A0]，
             * NEMU 对所有标准向量算术指令在 vstart!=0 时都判 Illegal
             * Instruction（vcompute_impl.c:544），香山译码侧同理
             * （VecExceptionGen.scala vstartIllegal = isVArith && vstart != 0）。
             * 单列统计，不计入 pass/fail。 */
            n_inexpressible++; suite_skip[r->suite_id]++;
            continue;
        }

        int nvec = run_baseline(r, vd_base);
        int base_trapped = (vdot_trap_flag != 0);
        u64 vl_rb = run_vdot(r, vd_vd);
        int vdot_trapped = (vdot_trap_flag != 0);

        if (r->op == 0) base_instr_vdot    = nvec;
        if (r->op == 1) base_instr_vdotacc = nvec;
        if (r->op == 2) base_instr_vdot4a  = nvec;

        int ok = 1;
        if (vl_rb != r->vl)                     { n_vl_mismatch++;    ok = 0; }
        if (base_trapped)                       { n_base_trap++;      ok = 0; }
        if (vdot_trapped)                       { n_vdot_trap++;      ok = 0; }
        if (!mem16_eq(vd_base, r->vd_exp))      { n_base_vs_golden++; ok = 0; }
        if (!mem16_eq(vd_vd,   r->vd_exp))      { n_vdot_vs_golden++; ok = 0; }
        if (!mem16_eq(vd_base, vd_vd))          { n_base_vs_vdot++;   ok = 0; }

        n_run++; suite_run[r->suite_id]++;
        if (ok) { n_pass++; suite_pass[r->suite_id]++; }
        else if (n_reported < MAX_REPORTED_FAILURES) {
            n_reported++;
            put_str("FAIL #"); put_dec(i);
            put_str("  suite="); put_str(suite_names + 32 * r->suite_id);
            put_str("  op="); put_str(op_name(r->op));
            put_str("  vsew="); put_dec(8u << r->vsew_code);
            put_str(" vstart="); put_dec(r->vstart);
            put_str(" vl="); put_dec(r->vl);
            put_str(" vm="); put_dec(r->flags & 1);
            put_str(" vta="); put_dec((r->flags >> 1) & 1);
            put_str(" vma="); put_dec((r->flags >> 2) & 1); putch('\n');
            put_str("        vs1      = "); put_vreg_hex(r->vs1);    putch('\n');
            put_str("        vs2      = "); put_vreg_hex(r->vs2);    putch('\n');
            put_str("        v0       = "); put_vreg_hex(r->v0);     putch('\n');
            put_str("        vd_in    = "); put_vreg_hex(r->vd_in);  putch('\n');
            put_str("        golden   = "); put_vreg_hex(r->vd_exp); putch('\n');
            put_str("        baseline = "); put_vreg_hex(vd_base);   putch('\n');
            put_str("        vdot     = "); put_vreg_hex(vd_vd);     putch('\n');
            put_str("        base_trap="); put_dec((u64)base_trapped);
            put_str(" vdot_trap=");        put_dec((u64)vdot_trapped);
            put_str(" mcause=");           put_dec(vdot_trap_mcause);
            put_str(" vl_readback=");      put_dec(vl_rb); putch('\n');
        }
    }

    putch('\n');
    put_str("suite                      cases     run    pass    fail    skip\n");
    put_str("---------------------------------------------------------------------\n");
    for (u32 s = 0; s < n_suites; s++) {
        put_pad(suite_names + 32 * s, 25);
        put_decw(suite_total[s], 8);
        put_decw(suite_run[s], 8);
        put_decw(suite_pass[s], 8);
        put_decw(suite_run[s] - suite_pass[s], 8);
        put_decw(suite_skip[s], 8);
        putch('\n');
    }
    put_str("---------------------------------------------------------------------\n");
    put_str("[A] TOTAL cases="); put_dec(n_cases);
    put_str(" run=");  put_dec(n_run);
    put_str(" pass="); put_dec(n_pass);
    put_str(" fail="); put_dec(n_run - n_pass);
    put_str(" skip(illegal-by-spec)="); put_dec(n_skip);
    put_str(" skip(baseline-inexpressible,vstart!=0)="); put_dec(n_inexpressible);
    putch('\n');
    put_str("    baseline-vs-golden mismatch = "); put_dec(n_base_vs_golden);
    put_str(" , vdot-vs-golden mismatch = ");      put_dec(n_vdot_vs_golden);
    put_str(" , baseline-vs-vdot mismatch = ");    put_dec(n_base_vs_vdot); putch('\n');
    put_str("    unexpected baseline trap = ");    put_dec(n_base_trap);
    put_str(" , unexpected vdot trap = ");         put_dec(n_vdot_trap);
    put_str(" , vl readback mismatch = ");         put_dec(n_vl_mismatch); putch('\n');
    put_str("    baseline vector-instruction count per case: vdot=");
    put_dec((u64)base_instr_vdot); put_str("  vdotacc=");
    put_dec((u64)base_instr_vdotacc); put_str("  vdot4a=");
    put_dec((u64)base_instr_vdot4a); put_str("   (vdot side = 1 each)\n\n");

    /* ================= [B] 长向量循环等价性 ================= */
    put_str("--- [B] long-vector loop: baseline_rvv.S kernels vs scalar C reference ---\n\n");
    gen_vectors();
    u32 n_long_fail = 0, n_long_chk = 0;
    put_str("      N   scalar_ref   base_A   base_B   base_D  vdotacc   vdot4a  vdacc2  verdict\n");
    for (int k = 0; k < NEQ; k++) {
        u64 n = N_EQ[k];
        i32 r0 = naive_dot(g_a, g_b, n);
        i32 rA = baseline_dot_i8_seqA(g_a, g_b, n);
        i32 rB = baseline_dot_i8_seqB(g_a, g_b, n);
        i32 rD = baseline_dot_i8_seqD(g_a, g_b, n);
        i32 rV = vdot_dot_i8(g_a, g_b, n);
        i32 r4 = vdot4a_dot_i8(g_a, g_b, n);
        i32 rW = vdot_dot_i8_acc2(g_a, g_b, n);
        int bad = (r0 != rA) || (r0 != rB) || (r0 != rD) || (r0 != rV) || (r0 != r4) || (r0 != rW);
        n_long_chk++;
        if (bad) n_long_fail++;
        put_decw(n, 7); put_str("  "); put_decw((u64)(u32)r0, 11);
        put_str("  "); put_decw((u64)(u32)rA, 7);
        put_str("  "); put_decw((u64)(u32)rB, 7);
        put_str("  "); put_decw((u64)(u32)rD, 7);
        put_str("  "); put_decw((u64)(u32)rV, 7);
        put_str("  "); put_decw((u64)(u32)r4, 7);
        put_str("  "); put_decw((u64)(u32)rW, 7);
        put_str("  "); put_str(bad ? "FAIL" : "OK"); putch('\n');
    }
    /* 非 4 的倍数：vdot4a kernel 按定义只处理 floor(n/4)*4 个元素，不参与比对 */
    for (int k = 0; k < NODD; k++) {
        u64 n = N_ODD[k];
        i32 r0 = naive_dot(g_a, g_b, n);
        i32 rA = baseline_dot_i8_seqA(g_a, g_b, n);
        i32 rB = baseline_dot_i8_seqB(g_a, g_b, n);
        i32 rD = baseline_dot_i8_seqD(g_a, g_b, n);
        i32 rV = vdot_dot_i8(g_a, g_b, n);
        i32 rW = vdot_dot_i8_acc2(g_a, g_b, n);
        int bad = (r0 != rA) || (r0 != rB) || (r0 != rD) || (r0 != rV) || (r0 != rW);
        n_long_chk++;
        if (bad) n_long_fail++;
        put_decw(n, 7); put_str("  "); put_decw((u64)(u32)r0, 11);
        put_str("  "); put_decw((u64)(u32)rA, 7);
        put_str("  "); put_decw((u64)(u32)rB, 7);
        put_str("  "); put_decw((u64)(u32)rD, 7);
        put_str("  "); put_decw((u64)(u32)rV, 7);
        put_str("        -  "); put_decw((u64)(u32)rW, 7);
        put_str("  "); put_str(bad ? "FAIL" : "OK"); putch('\n');
    }
    put_str("[B] long-vector sizes checked = "); put_dec(n_long_chk);
    put_str(" , mismatches = "); put_dec(n_long_fail); putch('\n');
    put_str("    (N not a multiple of 4 excludes vdot4a: that kernel is defined on int8x4 groups)\n\n");

    /* ================= [C] 动态指令数实测 ================= */
    put_str("--- [C] measured dynamic instruction count (CSR minstret, NEMU) ---\n\n");
    measure_overhead();
    put_str("    csrr-pair overhead = "); put_dec(g_ovh); put_str(" instr (subtracted below)\n\n");
    put_str("CSVHDR,kernel,N,instr_retired\n");
    for (int ki = 0; ki < NKERN; ki++) {
        for (int pi = 0; pi < NPERF; pi++) {
            u64 n = N_PERF[pi];
            u64 t0 = rd_minstret();
            i32 res = KERNS[ki].fn(g_a, g_b, n);
            u64 t1 = rd_minstret();
            u64 d = t1 - t0 - g_ovh;
            put_str("CSVROW,"); put_str(KERNS[ki].name); putch(',');
            put_dec(n); putch(','); put_dec(d);
            put_str(",result="); put_i32(res); putch('\n');
        }
    }
    /* 单次 16 元素点积（操作数在内存里）的指令数对照。
     *
     * 单次调用的 minstret 差值里混着「实参装填 + call + ret」的开销，而且两个
     * 调用点的装填指令数可能差 1 条（编译器复用寄存器）。为了得到**精确**值，
     * 这里改用斜率法：同一个 kernel 分别跑 R=1 与 R=1+K 次，
     *     slope = (m[1+K] - m[1]) / K
     * 即「一次调用 + 一次循环迭代」的指令数，循环开销对三者完全相同，
     * 于是 slope(kernel) - slope(nop) 就是 kernel 本体（不含 ret）的精确条数。 */
    put_str("CSVHDR,single16,variant,slope_instr_per_call,body_instr,static_instr\n");
    {
#define K_REP 64
        u64 slope[3]; i32 res3[3] = {0, 0, 0};
        for (int w = 0; w < 3; w++) {
            kern_t f = (w == 0) ? bench_nop_kernel
                     : (w == 1) ? baseline_vdot_single : vdot_single;
            u64 m1, m2; i32 acc = 0;
            m1 = rd_minstret();
            for (int t = 0; t < 1; t++) acc = f(g_a, g_b, 16);
            m1 = rd_minstret() - m1 - g_ovh;
            m2 = rd_minstret();
            for (int t = 0; t < 1 + K_REP; t++) acc = f(g_a, g_b, 16);
            m2 = rd_minstret() - m2 - g_ovh;
            slope[w] = (m2 - m1) / K_REP;
            res3[w] = acc;
        }
        i32 rr = naive_dot(g_a, g_b, 16);
        u64 st_nop  = count_static_until_ret(bench_nop_kernel);
        u64 st_base = count_static_until_ret(baseline_vdot_single);
        u64 st_vdot = count_static_until_ret(vdot_single);
        put_str("CSVROW,single16,call_loop_overhead,"); put_dec(slope[0]);
        put_str(",0,"); put_dec(st_nop); putch('\n');
        put_str("CSVROW,single16,baseline,"); put_dec(slope[1]); putch(',');
        put_dec(slope[1] - slope[0] + 1); putch(','); put_dec(st_base);
        put_str("   result="); put_i32(res3[1]); putch('\n');
        put_str("CSVROW,single16,vdot,");     put_dec(slope[2]); putch(',');
        put_dec(slope[2] - slope[0] + 1); putch(','); put_dec(st_vdot);
        put_str("   result="); put_i32(res3[2]); putch('\n');
        put_str("CSVROW,single16,scalar_ref,0,0,0   result="); put_i32(rr); putch('\n');
        put_str("    (static_instr 由本程序运行时从函数入口逐条解码到第一条 ret（含）计数；"
                "与 build/baseline_test.dis 的反汇编计数互为对照)\n");
        if (st_base == 0 || st_vdot == 0 || st_nop == 0) {
            n_long_fail++; put_str("FAIL: static_instr scan did not find ret\n");
        }
        if (res3[1] != rr || res3[2] != rr) { n_long_fail++; put_str("FAIL: single16 mismatch\n"); }
#undef K_REP
    }

    putch('\n');
    put_str("=====================================================================\n");
    put_str("RESULT: ");
    int fail = (n_run != n_pass) || (n_long_fail != 0);
    put_str(fail ? "FAIL" : "PASS");
    putch('\n');
    put_str("=====================================================================\n");
    return fail ? 1 : 0;
}
