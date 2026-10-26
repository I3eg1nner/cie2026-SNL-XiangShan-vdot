/*
 * baseline_ref.h —— RVV 1.0 基线指令序列的宿主端（纯 C）仿真
 *
 * 目的（对应赛题 3.2「基线实现」）：
 *   1. 用**只属于 RVV 1.0 标准**的指令组合实现与 vdot 指令族完全相同的功能；
 *   2. 该实现是一个**微型 RVV 解释器**：逐条模拟 vwmul.vv / vwredsum.vs /
 *      vsll.vi / vsra.vi / vmacc.vv / vmv.s.x / vmv.v.i / vslideup.vi /
 *      vslidedown.vi / vwadd.wv / vredsum.vs 的
 *      vstart / vl / mask / vta / vma 语义，再把它们按 baseline_rvv.S 中
 *      的指令顺序组合起来；
 *   3. 因此它与 tests/golden/vdot_ref.c 是**两份相互独立编写的实现**，
 *      两者在 10000 组随机激励上逐位一致，才是真正的正确性证据。
 *
 * 与 vdot_ref 的共享面：仅共用 16 字节容器类型 vreg128_t 与十六进制 I/O
 * 辅助函数，**不共用任何一行算术 / 掩码 / 尾部策略代码**。
 */
#ifndef BASELINE_REF_H
#define BASELINE_REF_H

#include <stdint.h>
#include <stddef.h>
#include "../../tests/golden/vdot_ref.h"   /* 仅为 vreg128_t 与状态码枚举 */

#ifdef __cplusplus
extern "C" {
#endif

/* ---- 微型向量寄存器堆（VLEN=128，32 个寄存器） ---- */
#define RVV_VLENB 16
#define RVV_NREG  32
typedef struct { uint8_t x[RVV_NREG][RVV_VLENB]; } rvv_vrf_t;

/* ---- 单条 RVV 指令的仿真 ----
 * 公共参数：
 *   sew       源元素位宽（8/16/32）
 *   lmul      源寄存器组的 LMUL（1/2/4/8），用于算 VLMAX = VLEN/sew*lmul
 *   vstart,vl CSR 值
 *   mask_on   1 = 指令 vm 位为 0（用 v0 掩码）；0 = 不用掩码
 *   vta,vma   尾部 / 非活跃元素策略
 * 返回 0 成功，返回 VDOT_ILLEGAL_VSTART 表示该指令在此 vstart 下非法。
 */
int rvv_vmv_s_x   (rvv_vrf_t *s, int vd, uint64_t x,
                   int sew, uint32_t vstart, uint32_t vl, int vta);
int rvv_vmv_v_i   (rvv_vrf_t *s, int vd, int imm,
                   int sew, int lmul, uint32_t vstart, uint32_t vl, int vta);
int rvv_vslideup_vi(rvv_vrf_t *s, int vd, int vs2, uint32_t off,
                   int sew, int lmul, uint32_t vstart, uint32_t vl,
                   int mask_on, int vta, int vma);
int rvv_vslidedown_vi(rvv_vrf_t *s, int vd, int vs2, uint32_t off,
                   int sew, int lmul, uint32_t vstart, uint32_t vl,
                   int mask_on, int vta, int vma);
int rvv_vwmul_vv  (rvv_vrf_t *s, int vd, int vs2, int vs1,
                   int sew, int lmul, uint32_t vstart, uint32_t vl,
                   int mask_on, int vta, int vma);
int rvv_vwredsum_vs(rvv_vrf_t *s, int vd, int vs2, int vs1,
                   int sew, uint32_t vstart, uint32_t vl,
                   int mask_on, int vta);
int rvv_vredsum_vs(rvv_vrf_t *s, int vd, int vs2, int vs1,
                   int sew, uint32_t vstart, uint32_t vl,
                   int mask_on, int vta);
int rvv_vwadd_wv  (rvv_vrf_t *s, int vd, int vs2, int vs1,
                   int sew, int lmul, uint32_t vstart, uint32_t vl,
                   int mask_on, int vta, int vma);
int rvv_vsll_vi   (rvv_vrf_t *s, int vd, int vs2, int imm,
                   int sew, int lmul, uint32_t vstart, uint32_t vl,
                   int mask_on, int vta, int vma);
int rvv_vsra_vi   (rvv_vrf_t *s, int vd, int vs2, int imm,
                   int sew, int lmul, uint32_t vstart, uint32_t vl,
                   int mask_on, int vta, int vma);
int rvv_vmacc_vv  (rvv_vrf_t *s, int vd, int vs1, int vs2,
                   int sew, int lmul, uint32_t vstart, uint32_t vl,
                   int mask_on, int vta, int vma);

/* ---- 组合后的基线序列：接口与 tests/golden/vdot_ref.h 完全一致 ---- */
int baseline_vdot_vv   (vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
                        uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
                        int vta, int vma);
int baseline_vdotacc_vv(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
                        uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
                        int vta, int vma);
int baseline_vdot4a_vv (vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
                        uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
                        int vta, int vma);
int baseline_exec(int op, int vsew,
                  vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
                  uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
                  int vta, int vma);

/* ---- 长向量循环（N >> 16）：两种实现各算一遍，用于循环体等价性验证 ---- */
/* 基线 L-D：vwmul.vv + vwadd.wv，循环内无串行归约 */
int32_t baseline_long_dot_i8(const int8_t *a, const int8_t *b, size_t n);
/* vdot 版：vdotacc.vv，循环体 4 条向量指令 */
int32_t vdot_long_dot_i8(const int8_t *a, const int8_t *b, size_t n);
/* vdot4a 版：vdot4a.vv + 循环外一次 vredsum.vs */
int32_t vdot4a_long_dot_i8(const int8_t *a, const int8_t *b, size_t n);

#ifdef __cplusplus
}
#endif

#endif /* BASELINE_REF_H */
