/*
 * vdot_ref.c —— vdot 指令族位精确参考模型实现
 *
 * 见 vdot_ref.h 头部的规范依据与布局约定。
 *
 * 【溢出证明（vdot.vv 为何不需要饱和逻辑）】
 *   单个乘积 p = sext32(a) * sext32(b)，a,b ∈ [-128, +127]：
 *     max p = (-128) * (-128) = +16384
 *     min p = (-128) * (+127) = -16256
 *   因此 |p| <= 16384 = 2^14。
 *   VLEN=128、SEW=8、LMUL=1 时最多 VLMAX = 16 个有效元素，故
 *     |Σ p| <= 16 * 16384 = 262144 = 2^18 < 2^31 - 1
 *   即 vdot.vv 的结果恒落在 int32 范围内，不可能溢出，无需饱和逻辑，
 *   也不会置位 vxsat。（与 MASTER_PLAN D2「溢出分析」一致）
 *
 *   vdotacc.vv / vdot4a.vv 把外部累加值并入，可能超出 int32：
 *   按 RVV 整数运算惯例（§11 "overflows wrap around"）做 2^32 模回绕，
 *   不饱和。本文件全部累加在 uint32_t 上完成，故不存在 C 的有符号溢出 UB。
 */
#include "vdot_ref.h"

/* ---------------- 内部公共检查 ---------------- */

static int check_common(const vreg128_t *vd, const vreg128_t *vs2,
                        const vreg128_t *vs1, int vta, int vma,
                        int policy)
{
    if (vd == NULL || vs2 == NULL || vs1 == NULL)         return VDOT_ERR_ARG;
    if ((vta != 0 && vta != 1) || (vma != 0 && vma != 1)) return VDOT_ERR_ARG;
    if (policy != VDOT_VSTART_STRICT && policy != VDOT_VSTART_SKIP)
        return VDOT_ERR_POLICY;
    return VDOT_OK;
}

/* mask(x) = unmasked || v0.mask[x] == 1   （RVV v1.0 §5.4） */
static inline int elem_active(const vreg128_t *vm_mask, uint32_t i)
{
    return (vm_mask == NULL) ? 1 : vreg_mask_bit(vm_mask, (int)i);
}

uint32_t vdot_vlmax(int op)
{
    switch (op) {
        case VDOT_OP_VDOT:
        case VDOT_OP_VDOTACC: return VDOT_VLEN / 8;   /* SEW=8 , LMUL=1 -> 16 */
        case VDOT_OP_VDOT4A:  return VDOT_VLEN / 32;  /* SEW=32, LMUL=1 -> 4  */
        default:              return 0;
    }
}

/* ================================================================== *
 * vdot.vv / vdotacc.vv —— 归约形态（SEW=8）
 *
 * 行为表（逐条对应 RVV v1.0 条文，详见 docs/stage2/13）：
 *   1) vsew != 8                      -> Illegal Instruction (VDOT_ERR_SEW)
 *   2) vstart != 0                    -> Illegal Instruction（§14），
 *                                        STRICT 策略；SKIP 策略下按 §5.4
 *                                        跳过 i < vstart 的源元素
 *   3) vstart >= vl（含 vl==0）       -> 不写回任何元素，连 tail 也不写（§5.4）
 *   4) body 内 mask=0 的源元素        -> 排除出归约（§14 "Inactive elements
 *                                        from the source vector register group
 *                                        are excluded from the reduction"）
 *   5) 目的元素 0（EEW=32）           -> vl!=0 时总是写回，不受掩码影响
 *                                        （§14 标量操作数始终参与）
 *   6) 目的元素 1..3（EEW=32）        -> tail：vta=1 写全 1，vta=0 保持不变（§3.4.3）
 *   7) vma                            -> 对归约无意义（无 inactive 目的元素），忽略
 *   8) 执行结束 vstart 置 0           -> 由调用方（NEMU/RTL）负责，模型不持有 CSR
 * ================================================================== */
static int vdot_reduce_common(vreg128_t *vd, const vreg128_t *vs2,
                              const vreg128_t *vs1,
                              uint32_t vstart, uint32_t vl,
                              const vreg128_t *vm_mask,
                              int vta, int vma, int policy,
                              int accumulate)
{
    const uint32_t vlmax = VDOT_VLEN / 8;   /* 16 */
    uint32_t sum, i;
    int st;

    (void)vma;   /* 归约指令无 inactive 目的元素，vma 不参与 */

    st = check_common(vd, vs2, vs1, vta, vma, policy);
    if (st != VDOT_OK) return st;
    if (vl > vlmax)        return VDOT_ERR_VL;
    if (vstart > vlmax - 1) return VDOT_ERR_VSTART_RANGE;   /* §3.7 reserved */

    /* 规则 2：先于 vstart>=vl 判断，与 NEMU reduction_instr 的
     * check_vstart_exception() 先于 check_vstart_ignore() 的顺序一致
     * （work/NEMU/src/isa/riscv64/instr/rvv/vcompute_impl.c:1531-1536） */
    if (vstart != 0 && policy == VDOT_VSTART_STRICT)
        return VDOT_ILLEGAL_VSTART;

    /* 规则 3 */
    if (vstart >= vl) return VDOT_OK;

    /* 规则 4：在 uint32_t 上累加，避免有符号溢出 UB */
    sum = accumulate ? vreg_u32(vd, 0) : 0u;
    for (i = vstart; i < vl; i++) {
        if (!elem_active(vm_mask, i)) continue;
        sum += (uint32_t)(vreg_i8(vs2, (int)i) * vreg_i8(vs1, (int)i));
    }

    /* 规则 6：先铺 tail 再写元素 0（两者不相交，顺序无影响） */
    if (vta) {
        for (i = 1; i < VDOT_VLEN / 32; i++) vreg_set_u32(vd, (int)i, 0xFFFFFFFFu);
    }
    /* 规则 5 */
    vreg_set_u32(vd, 0, sum);
    return VDOT_OK;
}

int vdot_vv_ex(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
               uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
               int vta, int vma, int vstart_policy)
{
    return vdot_reduce_common(vd, vs2, vs1, vstart, vl, vm_mask,
                              vta, vma, vstart_policy, 0);
}

int vdotacc_vv_ex(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
                  uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
                  int vta, int vma, int vstart_policy)
{
    return vdot_reduce_common(vd, vs2, vs1, vstart, vl, vm_mask,
                              vta, vma, vstart_policy, 1);
}

/* ================================================================== *
 * vdot4a.vv —— 分组点积累加形态（SEW=32），逐元素指令，非归约
 *
 * 行为表：
 *   1) vsew != 32               -> Illegal Instruction (VDOT_ERR_SEW)
 *   2) vstart >= vl（含 vl==0） -> 不写回任何元素，连 tail 也不写（§5.4）
 *   3) i < vstart（prestart）   -> 目的元素保持不变（§3.7 / §5.4）
 *   4) body & mask=1（active）  -> vd.u32[i] += Σ_{j<4} sext(vs2.i8[4i+j])*sext(vs1.i8[4i+j])
 *   5) body & mask=0（inactive）-> vma=1 写全 1，vma=0 保持不变（§3.4.3 / §5.4）
 *   6) i >= vl（tail）          -> vta=1 写全 1，vta=0 保持不变（§3.4.3）
 *   7) 掩码粒度 = 32 位元素（每个结果 1 个 mask bit），与 Zvdot4a8i 一致
 *   8) 子元素 j 取字节 4i+j（寄存器内小端）；4 个乘积相加，字节顺序不影响结果
 * ================================================================== */
int vdot4a_vv_ex(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
                 uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
                 int vta, int vma, int vstart_policy)
{
    const uint32_t vlmax = VDOT_VLEN / 32;   /* 4 */
    uint32_t i;
    int j, st;

    st = check_common(vd, vs2, vs1, vta, vma, vstart_policy);
    if (st != VDOT_OK) return st;
    if (vl > vlmax)         return VDOT_ERR_VL;
    if (vstart > vlmax - 1) return VDOT_ERR_VSTART_RANGE;   /* §3.7 reserved */

    /* 规则 2 */
    if (vstart >= vl) return VDOT_OK;

    for (i = vstart; i < vl; i++) {
        if (!elem_active(vm_mask, i)) {          /* 规则 5 */
            if (vma) vreg_set_u32(vd, (int)i, 0xFFFFFFFFu);
            continue;
        }
        {                                        /* 规则 4 */
            uint32_t acc = vreg_u32(vd, (int)i);
            for (j = 0; j < 4; j++) {
                acc += (uint32_t)(vreg_i8(vs2, (int)(4*i + (uint32_t)j))
                                * vreg_i8(vs1, (int)(4*i + (uint32_t)j)));
            }
            vreg_set_u32(vd, (int)i, acc);
        }
    }
    /* 规则 6 */
    if (vta) {
        for (i = vl; i < vlmax; i++) vreg_set_u32(vd, (int)i, 0xFFFFFFFFu);
    }
    return VDOT_OK;
}

/* ---------------- 默认策略包装 ---------------- */

int vdot_vv(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
            uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
            int vta, int vma)
{
    return vdot_vv_ex(vd, vs2, vs1, vstart, vl, vm_mask, vta, vma,
                      VDOT_VSTART_STRICT);
}

int vdotacc_vv(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
               uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
               int vta, int vma)
{
    return vdotacc_vv_ex(vd, vs2, vs1, vstart, vl, vm_mask, vta, vma,
                         VDOT_VSTART_STRICT);
}

int vdot4a_vv(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
              uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
              int vta, int vma)
{
    return vdot4a_vv_ex(vd, vs2, vs1, vstart, vl, vm_mask, vta, vma,
                        VDOT_VSTART_STRICT);
}

/* ---------------- 统一派发 ---------------- */

int vdot_exec(int op, int vsew,
              vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
              uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
              int vta, int vma, int vstart_policy)
{
    switch (op) {
        case VDOT_OP_VDOT:
            if (vsew != 8) return VDOT_ERR_SEW;
            return vdot_vv_ex(vd, vs2, vs1, vstart, vl, vm_mask, vta, vma,
                              vstart_policy);
        case VDOT_OP_VDOTACC:
            if (vsew != 8) return VDOT_ERR_SEW;
            return vdotacc_vv_ex(vd, vs2, vs1, vstart, vl, vm_mask, vta, vma,
                                 vstart_policy);
        case VDOT_OP_VDOT4A:
            if (vsew != 32) return VDOT_ERR_SEW;
            return vdot4a_vv_ex(vd, vs2, vs1, vstart, vl, vm_mask, vta, vma,
                                vstart_policy);
        default:
            return VDOT_ERR_OP;
    }
}

/* ---------------- 文本 I/O ---------------- */

static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

int vdot_hex_parse(const char *s, vreg128_t *out)
{
    int i, hi, lo;
    if (s == NULL || out == NULL) return -1;
    for (i = 0; i < VDOT_VLENB; i++) {
        hi = hexval(s[2*i]);
        lo = hexval(s[2*i + 1]);
        if (hi < 0 || lo < 0) return -1;
        out->v[i] = (uint8_t)((hi << 4) | lo);
    }
    if (s[2 * VDOT_VLENB] != '\0' && s[2 * VDOT_VLENB] != ' ' &&
        s[2 * VDOT_VLENB] != '\t' && s[2 * VDOT_VLENB] != '\n' &&
        s[2 * VDOT_VLENB] != '\r')
        return -1;
    return 0;
}

void vdot_hex_format(const vreg128_t *r, char out[33])
{
    static const char d[] = "0123456789abcdef";
    int i;
    for (i = 0; i < VDOT_VLENB; i++) {
        out[2*i]     = d[(r->v[i] >> 4) & 0xF];
        out[2*i + 1] = d[r->v[i] & 0xF];
    }
    out[2 * VDOT_VLENB] = '\0';
}

static const char *const k_status_names[] = {
    "OK", "ILLEGAL_VSTART", "ERR_SEW", "ERR_VL",
    "ERR_VSTART_RANGE", "ERR_ARG", "ERR_POLICY", "ERR_OP"
};
static const char *const k_op_names[] = { "vdot", "vdotacc", "vdot4a" };

static int str_eq(const char *a, const char *b)
{
    while (*a && *b) { if (*a != *b) return 0; a++; b++; }
    return *a == *b;
}

const char *vdot_status_name(int status)
{
    if (status < 0 || status > VDOT_ERR_OP) return "UNKNOWN";
    return k_status_names[status];
}

int vdot_status_from_name(const char *name)
{
    int i;
    if (name == NULL) return -1;
    for (i = 0; i <= VDOT_ERR_OP; i++)
        if (str_eq(name, k_status_names[i])) return i;
    return -1;
}

const char *vdot_op_name(int op)
{
    if (op < 0 || op > VDOT_OP_VDOT4A) return "unknown";
    return k_op_names[op];
}

int vdot_op_from_name(const char *name)
{
    int i;
    if (name == NULL) return -1;
    for (i = 0; i <= VDOT_OP_VDOT4A; i++)
        if (str_eq(name, k_op_names[i])) return i;
    return -1;
}
