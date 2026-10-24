/*
 * baseline_ref.c —— RVV 1.0 基线指令序列的宿主端仿真（微型 RVV 解释器）
 *
 * 本文件**不引用** tests/golden/vdot_ref.c 的任何算术逻辑，是对同一功能的
 * 第二份独立实现。两者在 tests/golden/test_golden.c 中做 10000 组随机差分。
 *
 * 所用的 RVV 1.0 指令及其规范出处：
 *   vmv.s.x      §16.1  目的元素 0 写入；1..VLEN/SEW-1 按 vta 作为 tail
 *   vwmul.vv     §11.12 2*SEW = sext(SEW) * sext(SEW)
 *   vwredsum.vs  §14.2  2*SEW = 2*SEW + Σ sext(SEW)，vstart!=0 非法
 *   vredsum.vs   §14.1  SEW   = SEW   + Σ SEW     ，vstart!=0 非法
 *   vwadd.wv     §11.2  2*SEW = 2*SEW + sext(SEW)
 *   vsll.vi      §11.6  逻辑左移立即数
 *   vsra.vi      §11.6  算术右移立即数
 *   vmacc.vv     §11.13 vd = +(vs1*vs2) + vd
 */
#include "baseline_ref.h"

#define RVV_VLEN 128

/* ---------------- 寄存器堆字节级访问 ---------------- */

static uint64_t vrf_get(const rvv_vrf_t *s, int base, int eew, uint32_t idx)
{
    uint32_t nb = (uint32_t)(eew / 8);
    uint32_t byteoff = idx * nb;
    uint32_t reg = (uint32_t)base + byteoff / RVV_VLENB;
    uint32_t off = byteoff % RVV_VLENB;
    uint64_t r = 0;
    uint32_t k;
    for (k = 0; k < nb; k++) r |= (uint64_t)s->x[reg][off + k] << (8 * k);
    return r;
}

static void vrf_put(rvv_vrf_t *s, int base, int eew, uint32_t idx, uint64_t val)
{
    uint32_t nb = (uint32_t)(eew / 8);
    uint32_t byteoff = idx * nb;
    uint32_t reg = (uint32_t)base + byteoff / RVV_VLENB;
    uint32_t off = byteoff % RVV_VLENB;
    uint32_t k;
    for (k = 0; k < nb; k++) s->x[reg][off + k] = (uint8_t)((val >> (8 * k)) & 0xFFu);
}

/* 把 eew 位的位模式按有符号解释 */
static int64_t vsext(uint64_t v, int eew)
{
    uint64_t sb = (uint64_t)1 << (eew - 1);
    uint64_t m  = (eew == 64) ? ~(uint64_t)0 : (((uint64_t)1 << eew) - 1);
    v &= m;
    return (int64_t)((v ^ sb) - sb);
}

static uint64_t vmaskbits(int eew)
{
    return (eew == 64) ? ~(uint64_t)0 : (((uint64_t)1 << eew) - 1);
}

/* 掩码寄存器恒为 v0；mask bit i 在 v0 的第 i 个比特（RVV §4.5） */
static int vrf_mbit(const rvv_vrf_t *s, uint32_t i)
{
    return (s->x[0][i >> 3] >> (i & 7)) & 1;
}

static int vrf_active(const rvv_vrf_t *s, int mask_on, uint32_t i)
{
    return mask_on ? vrf_mbit(s, i) : 1;
}

/* ---------------- 单条指令仿真 ---------------- */

int rvv_vmv_s_x(rvv_vrf_t *s, int vd, uint64_t x,
                int sew, uint32_t vstart, uint32_t vl, int vta)
{
    uint32_t i, dmax = (uint32_t)(RVV_VLEN / sew);
    if (vstart >= vl) return 0;                 /* §16.1 / §5.4 */
    if (vta) for (i = 1; i < dmax; i++) vrf_put(s, vd, sew, i, vmaskbits(sew));
    vrf_put(s, vd, sew, 0, x & vmaskbits(sew));
    return 0;
}

int rvv_vwmul_vv(rvv_vrf_t *s, int vd, int vs2, int vs1,
                 int sew, int lmul, uint32_t vstart, uint32_t vl,
                 int mask_on, int vta, int vma)
{
    uint32_t i, vlmax = (uint32_t)(RVV_VLEN / sew) * (uint32_t)lmul;
    int dew = sew * 2;
    if (vstart >= vl) return 0;                 /* §5.4 */
    for (i = vstart; i < vl; i++) {
        if (!vrf_active(s, mask_on, i)) {
            if (vma) vrf_put(s, vd, dew, i, vmaskbits(dew));
            continue;
        }
        {
            int64_t a = vsext(vrf_get(s, vs2, sew, i), sew);
            int64_t b = vsext(vrf_get(s, vs1, sew, i), sew);
            vrf_put(s, vd, dew, i, (uint64_t)(a * b) & vmaskbits(dew));
        }
    }
    if (vta) for (i = vl; i < vlmax; i++) vrf_put(s, vd, dew, i, vmaskbits(dew));
    return 0;
}

int rvv_vwredsum_vs(rvv_vrf_t *s, int vd, int vs2, int vs1,
                    int sew, uint32_t vstart, uint32_t vl,
                    int mask_on, int vta)
{
    int dew = sew * 2;
    uint32_t i, dmax = (uint32_t)(RVV_VLEN / dew);
    uint64_t sum;
    if (vstart != 0) return VDOT_ILLEGAL_VSTART;      /* §14 */
    if (vl == 0) return 0;                            /* §14 vl=0 不写回 */
    sum = vrf_get(s, vs1, dew, 0);                    /* 标量操作数恒参与 */
    for (i = 0; i < vl; i++) {
        if (!vrf_active(s, mask_on, i)) continue;     /* 非活跃源元素排除 */
        sum += (uint64_t)vsext(vrf_get(s, vs2, sew, i), sew);
    }
    if (vta) for (i = 1; i < dmax; i++) vrf_put(s, vd, dew, i, vmaskbits(dew));
    vrf_put(s, vd, dew, 0, sum & vmaskbits(dew));
    return 0;
}

int rvv_vredsum_vs(rvv_vrf_t *s, int vd, int vs2, int vs1,
                   int sew, uint32_t vstart, uint32_t vl,
                   int mask_on, int vta)
{
    uint32_t i, dmax = (uint32_t)(RVV_VLEN / sew);
    uint64_t sum;
    if (vstart != 0) return VDOT_ILLEGAL_VSTART;      /* §14 */
    if (vl == 0) return 0;
    sum = vrf_get(s, vs1, sew, 0);
    for (i = 0; i < vl; i++) {
        if (!vrf_active(s, mask_on, i)) continue;
        sum += vrf_get(s, vs2, sew, i);
    }
    if (vta) for (i = 1; i < dmax; i++) vrf_put(s, vd, sew, i, vmaskbits(sew));
    vrf_put(s, vd, sew, 0, sum & vmaskbits(sew));
    return 0;
}

int rvv_vwadd_wv(rvv_vrf_t *s, int vd, int vs2, int vs1,
                 int sew, int lmul, uint32_t vstart, uint32_t vl,
                 int mask_on, int vta, int vma)
{
    uint32_t i, vlmax = (uint32_t)(RVV_VLEN / sew) * (uint32_t)lmul;
    int dew = sew * 2;
    if (vstart >= vl) return 0;
    for (i = vstart; i < vl; i++) {
        if (!vrf_active(s, mask_on, i)) {
            if (vma) vrf_put(s, vd, dew, i, vmaskbits(dew));
            continue;
        }
        {
            uint64_t w = vrf_get(s, vs2, dew, i);
            uint64_t n = (uint64_t)vsext(vrf_get(s, vs1, sew, i), sew);
            vrf_put(s, vd, dew, i, (w + n) & vmaskbits(dew));
        }
    }
    if (vta) for (i = vl; i < vlmax; i++) vrf_put(s, vd, dew, i, vmaskbits(dew));
    return 0;
}

int rvv_vsll_vi(rvv_vrf_t *s, int vd, int vs2, int imm,
                int sew, int lmul, uint32_t vstart, uint32_t vl,
                int mask_on, int vta, int vma)
{
    uint32_t i, vlmax = (uint32_t)(RVV_VLEN / sew) * (uint32_t)lmul;
    if (vstart >= vl) return 0;
    for (i = vstart; i < vl; i++) {
        if (!vrf_active(s, mask_on, i)) {
            if (vma) vrf_put(s, vd, sew, i, vmaskbits(sew));
            continue;
        }
        vrf_put(s, vd, sew, i,
                (vrf_get(s, vs2, sew, i) << (imm & (sew - 1))) & vmaskbits(sew));
    }
    if (vta) for (i = vl; i < vlmax; i++) vrf_put(s, vd, sew, i, vmaskbits(sew));
    return 0;
}

int rvv_vsra_vi(rvv_vrf_t *s, int vd, int vs2, int imm,
                int sew, int lmul, uint32_t vstart, uint32_t vl,
                int mask_on, int vta, int vma)
{
    uint32_t i, vlmax = (uint32_t)(RVV_VLEN / sew) * (uint32_t)lmul;
    if (vstart >= vl) return 0;
    for (i = vstart; i < vl; i++) {
        if (!vrf_active(s, mask_on, i)) {
            if (vma) vrf_put(s, vd, sew, i, vmaskbits(sew));
            continue;
        }
        {
            int64_t v = vsext(vrf_get(s, vs2, sew, i), sew);
            vrf_put(s, vd, sew, i,
                    (uint64_t)(v >> (imm & (sew - 1))) & vmaskbits(sew));
        }
    }
    if (vta) for (i = vl; i < vlmax; i++) vrf_put(s, vd, sew, i, vmaskbits(sew));
    return 0;
}

int rvv_vmacc_vv(rvv_vrf_t *s, int vd, int vs1, int vs2,
                 int sew, int lmul, uint32_t vstart, uint32_t vl,
                 int mask_on, int vta, int vma)
{
    uint32_t i, vlmax = (uint32_t)(RVV_VLEN / sew) * (uint32_t)lmul;
    if (vstart >= vl) return 0;
    for (i = vstart; i < vl; i++) {
        if (!vrf_active(s, mask_on, i)) {
            if (vma) vrf_put(s, vd, sew, i, vmaskbits(sew));
            continue;
        }
        {
            uint64_t a = vrf_get(s, vs1, sew, i);
            uint64_t b = vrf_get(s, vs2, sew, i);
            uint64_t d = vrf_get(s, vd,  sew, i);
            vrf_put(s, vd, sew, i, (a * b + d) & vmaskbits(sew));
        }
    }
    if (vta) for (i = vl; i < vlmax; i++) vrf_put(s, vd, sew, i, vmaskbits(sew));
    return 0;
}

/* ---------------- 寄存器搬运辅助 ---------------- */

static void vrf_load(rvv_vrf_t *s, int reg, const vreg128_t *src)
{
    int i;
    for (i = 0; i < RVV_VLENB; i++) s->x[reg][i] = src->v[i];
}

static void vrf_store(const rvv_vrf_t *s, int reg, vreg128_t *dst)
{
    int i;
    for (i = 0; i < RVV_VLENB; i++) dst->v[i] = s->x[reg][i];
}

static void vrf_init(rvv_vrf_t *s)
{
    int r, i;
    /* 用 0x5a 填充，保证"未被指令写过的寄存器内容"不是 0，
     * 这样若组合序列误读未初始化的 lane，差分测试一定会失配。 */
    for (r = 0; r < RVV_NREG; r++)
        for (i = 0; i < RVV_VLENB; i++) s->x[r][i] = 0x5a;
}

/* ================================================================== *
 * 候选序列 A（选定）—— vdot.vv 等价基线
 *
 *   寄存器分配：v0=掩码  v1=vs1  v2=vs2  v4:v5=中间积  v8=vd
 *
 *   1  vsetvli  zero, a0, e32, m1, <vta>, <vma>   # vl32 = min(vl,4)
 *   2  vmv.s.x  v8, zero                          # v8[0] = 0（32 位）
 *   3  vsetvli  zero, a0, e8,  m1, <vta>, <vma>   # vl8  = min(vl,16)
 *   4  vwmul.vv v4, v2, v1                        # 16 个 int16 乘积（EMUL=2）
 *   5  vsetvli  zero, a0, e16, m2, <vta>, <vma>   # vl16 = min(vl,16)
 *   6  vwredsum.vs v8, v4, v8, v0.t               # v8[0] = Σ 活跃乘积
 * ================================================================== */
int baseline_vdot_vv(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
                     uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
                     int vta, int vma)
{
    rvv_vrf_t s;
    int mask_on = (vm_mask != NULL);
    uint32_t vl32;
    if (vd == NULL || vs2 == NULL || vs1 == NULL) return VDOT_ERR_ARG;
    if ((vta != 0 && vta != 1) || (vma != 0 && vma != 1)) return VDOT_ERR_ARG;
    if (vl > 16) return VDOT_ERR_VL;
    if (vstart > 15) return VDOT_ERR_VSTART_RANGE;
    /* vwredsum.vs 本身在 vstart!=0 时就是非法指令（§14），
     * 故本基线序列也无法实现 vstart!=0 的语义 —— 这正是 vdot 采用
     * 同一规则（STRICT）的旁证。 */
    if (vstart != 0) return VDOT_ILLEGAL_VSTART;

    vrf_init(&s);
    if (mask_on) vrf_load(&s, 0, vm_mask);
    vrf_load(&s, 1, vs1);
    vrf_load(&s, 2, vs2);
    vrf_load(&s, 8, vd);

    vl32 = (vl < 4) ? vl : 4;
    rvv_vmv_s_x(&s, 8, 0, 32, 0, vl32, vta);
    rvv_vwmul_vv(&s, 4, 2, 1, 8, 1, 0, vl, 0, vta, vma);
    rvv_vwredsum_vs(&s, 8, 4, 8, 16, 0, vl, mask_on, vta);

    vrf_store(&s, 8, vd);
    return VDOT_OK;
}

/* vdotacc.vv 等价基线 —— 去掉上面的第 1、2 条（累加初值已在 v8[0]）
 *   1  vsetvli  zero, a0, e8,  m1, <vta>, <vma>
 *   2  vwmul.vv v4, v2, v1
 *   3  vsetvli  zero, a0, e16, m2, <vta>, <vma>
 *   4  vwredsum.vs v8, v4, v8, v0.t
 */
int baseline_vdotacc_vv(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
                        uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
                        int vta, int vma)
{
    rvv_vrf_t s;
    int mask_on = (vm_mask != NULL);
    if (vd == NULL || vs2 == NULL || vs1 == NULL) return VDOT_ERR_ARG;
    if ((vta != 0 && vta != 1) || (vma != 0 && vma != 1)) return VDOT_ERR_ARG;
    if (vl > 16) return VDOT_ERR_VL;
    if (vstart > 15) return VDOT_ERR_VSTART_RANGE;
    if (vstart != 0) return VDOT_ILLEGAL_VSTART;

    vrf_init(&s);
    if (mask_on) vrf_load(&s, 0, vm_mask);
    vrf_load(&s, 1, vs1);
    vrf_load(&s, 2, vs2);
    vrf_load(&s, 8, vd);

    rvv_vwmul_vv(&s, 4, 2, 1, 8, 1, 0, vl, 0, vta, vma);
    rvv_vwredsum_vs(&s, 8, 4, 8, 16, 0, vl, mask_on, vta);

    vrf_store(&s, 8, vd);
    return VDOT_OK;
}

/* ================================================================== *
 * vdot4a.vv 等价基线 —— 移位抽取子字节 + vmacc.vv
 *
 *   RVV 1.0 没有"32 位元素内 4 路 int8 点积"的原语，只能逐子字节做：
 *     vsetvli zero, a0, e32, m1, <vta>, <vma>
 *     j=0: vsll.vi v4,v1,24 ; vsra.vi v4,v4,24 ;
 *          vsll.vi v5,v2,24 ; vsra.vi v5,v5,24 ; vmacc.vv v8,v4,v5,v0.t
 *     j=1: vsll.vi 16 ...  (5 条)
 *     j=2: vsll.vi  8 ...  (5 条)
 *     j=3: vsra.vi v4,v1,24 ; vsra.vi v5,v2,24 ; vmacc.vv v8,v4,v5,v0.t  (3 条)
 *   合计 1 + 5 + 5 + 5 + 3 = 19 条向量指令。
 * ================================================================== */
int baseline_vdot4a_vv(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
                       uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
                       int vta, int vma)
{
    rvv_vrf_t s;
    int mask_on = (vm_mask != NULL);
    int j;
    if (vd == NULL || vs2 == NULL || vs1 == NULL) return VDOT_ERR_ARG;
    if ((vta != 0 && vta != 1) || (vma != 0 && vma != 1)) return VDOT_ERR_ARG;
    if (vl > 4) return VDOT_ERR_VL;
    if (vstart > 3) return VDOT_ERR_VSTART_RANGE;

    vrf_init(&s);
    if (mask_on) vrf_load(&s, 0, vm_mask);
    vrf_load(&s, 1, vs1);
    vrf_load(&s, 2, vs2);
    vrf_load(&s, 8, vd);

    for (j = 0; j < 4; j++) {
        int shl = 24 - 8 * j;
        if (shl) {
            rvv_vsll_vi(&s, 4, 1, shl, 32, 1, vstart, vl, 0, vta, vma);
            rvv_vsra_vi(&s, 4, 4, 24,  32, 1, vstart, vl, 0, vta, vma);
            rvv_vsll_vi(&s, 5, 2, shl, 32, 1, vstart, vl, 0, vta, vma);
            rvv_vsra_vi(&s, 5, 5, 24,  32, 1, vstart, vl, 0, vta, vma);
        } else {
            rvv_vsra_vi(&s, 4, 1, 24,  32, 1, vstart, vl, 0, vta, vma);
            rvv_vsra_vi(&s, 5, 2, 24,  32, 1, vstart, vl, 0, vta, vma);
        }
        rvv_vmacc_vv(&s, 8, 4, 5, 32, 1, vstart, vl, mask_on, vta, vma);
    }

    vrf_store(&s, 8, vd);
    return VDOT_OK;
}

int baseline_exec(int op, int vsew,
                  vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
                  uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
                  int vta, int vma)
{
    switch (op) {
        case VDOT_OP_VDOT:
            if (vsew != 8) return VDOT_ERR_SEW;
            return baseline_vdot_vv(vd, vs2, vs1, vstart, vl, vm_mask, vta, vma);
        case VDOT_OP_VDOTACC:
            if (vsew != 8) return VDOT_ERR_SEW;
            return baseline_vdotacc_vv(vd, vs2, vs1, vstart, vl, vm_mask, vta, vma);
        case VDOT_OP_VDOT4A:
            if (vsew != 32) return VDOT_ERR_SEW;
            return baseline_vdot4a_vv(vd, vs2, vs1, vstart, vl, vm_mask, vta, vma);
        default:
            return VDOT_ERR_OP;
    }
}

/* ================================================================== *
 * 长向量循环（N >> 16）
 *
 * 关键工程细节：累加器所在指令必须用 **tu（tail undisturbed）**，
 * 否则最后一次不足 16 个元素的迭代会把 lane[vl..15] 的累加值写成全 1。
 * ================================================================== */

/* 基线 L-D：vwmul.vv(8->16) + vwadd.wv(16->32)，循环内无串行归约
 *   循环体：vsetvli e8 / vle8 / vle8 / vwmul.vv / vsetvli e16 / vwadd.wv
 *           = 6 条向量指令 + 4 条标量指令
 *   循环外：vsetvli e32,m4 / vmv.s.x / vredsum.vs / vmv.x.s
 */
int32_t baseline_long_dot_i8(const int8_t *a, const int8_t *b, size_t n)
{
    rvv_vrf_t s;
    size_t pos = 0;
    uint32_t i;
    vrf_init(&s);
    /* 累加器 v8..v11（e32，16 lane）清零：vsetvli e32,m4 + vmv.v.i v8,0 */
    for (i = 0; i < 16; i++) vrf_put(&s, 8, 32, i, 0);
    while (pos < n) {
        uint32_t vl = (uint32_t)((n - pos < 16) ? (n - pos) : 16);
        for (i = 0; i < vl; i++) {           /* vle8.v v1,(a1) / vle8.v v2,(a2) */
            vrf_put(&s, 1, 8, i, (uint64_t)(uint8_t)a[pos + i]);
            vrf_put(&s, 2, 8, i, (uint64_t)(uint8_t)b[pos + i]);
        }
        rvv_vwmul_vv(&s, 4, 2, 1, 8, 1, 0, vl, 0, 0 /*tu*/, 0);
        rvv_vwadd_wv(&s, 8, 8, 4, 16, 2, 0, vl, 0, 0 /*tu*/, 0);
        pos += vl;
    }
    vrf_put(&s, 16, 32, 0, 0);               /* vmv.s.x v16, zero */
    rvv_vredsum_vs(&s, 16, 8, 16, 32, 0, 16, 0, 0);
    return (int32_t)(uint32_t)vrf_get(&s, 16, 32, 0);
}

/* vdot 版（DOTR 模式）：循环体 vsetvli / vle8 / vle8 / vdotacc.vv = 4 条向量指令 */
int32_t vdot_long_dot_i8(const int8_t *a, const int8_t *b, size_t n)
{
    vreg128_t v1, v2, v8;
    size_t pos = 0;
    uint32_t i;
    for (i = 0; i < VDOT_VLENB; i++) { v1.v[i] = 0; v2.v[i] = 0; v8.v[i] = 0; }
    while (pos < n) {
        uint32_t vl = (uint32_t)((n - pos < 16) ? (n - pos) : 16);
        for (i = 0; i < vl; i++) {
            v1.v[i] = (uint8_t)a[pos + i];
            v2.v[i] = (uint8_t)b[pos + i];
        }
        (void)vdotacc_vv(&v8, &v2, &v1, 0, vl, NULL, 0 /*tu*/, 0);
        pos += vl;
    }
    return (int32_t)vreg_u32(&v8, 0);
}

/* vdot4a 版（SEW=32 模式）：循环体 vsetvli / vle32 / vle32 / vdot4a.vv = 4 条，
 * 归约只在循环外做一次。不足 4 个元素的尾巴按 0 填充（0 对点积无贡献）。 */
int32_t vdot4a_long_dot_i8(const int8_t *a, const int8_t *b, size_t n)
{
    vreg128_t v1, v2, v8;
    size_t pos = 0;
    uint32_t i;
    uint32_t sum = 0;
    for (i = 0; i < VDOT_VLENB; i++) { v1.v[i] = 0; v2.v[i] = 0; v8.v[i] = 0; }
    while (pos < n) {
        uint32_t nb = (uint32_t)((n - pos < 16) ? (n - pos) : 16);
        uint32_t groups = (nb + 3) / 4;      /* 向上取整到 32 位元素个数 */
        for (i = 0; i < VDOT_VLENB; i++) { v1.v[i] = 0; v2.v[i] = 0; }
        for (i = 0; i < nb; i++) {
            v1.v[i] = (uint8_t)a[pos + i];
            v2.v[i] = (uint8_t)b[pos + i];
        }
        (void)vdot4a_vv(&v8, &v2, &v1, 0, groups, NULL, 0 /*tu*/, 0);
        pos += nb;
    }
    for (i = 0; i < 4; i++) sum += vreg_u32(&v8, (int)i);   /* vredsum.vs */
    return (int32_t)sum;
}
