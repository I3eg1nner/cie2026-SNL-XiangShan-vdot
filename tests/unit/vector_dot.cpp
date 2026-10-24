/*
 * vector_dot.cpp —— vdot 指令族（vdot.vv / vdotacc.vv / vdot4a.vv）的 L1 平台参考模型
 *
 * 【重要】本文件**不实现任何指令语义**，只做 VecInput/VecOutput 与 vreg128_t 之间的
 * 字节搬运，真正的语义来自项目的唯一事实来源 tests/golden/vdot_ref.c —— 它被下面
 * 直接 #include 进来，与 NEMU 扩展、测试向量生成器用的是同一份代码。
 * 严禁在本文件里重写 / 复制粘贴语义逻辑（MASTER_PLAN P4 验收标准第 4 条）。
 *
 * vdot_ref.c / vdot_ref.h 由 scripts/11_build_vdot_sim.sh 从 tests/golden/ 复制到本目录，
 * 保证两边永远一致；复制步骤是幂等的，重跑脚本即可刷新。
 */
#include "../include/gm_common.h"
#include <stdio.h>
#include <cstdlib>

/* 语义唯一事实来源：tests/golden/vdot_ref.c（由构建脚本复制到本目录） */
#include "vdot_ref.c"

/* ---------------------------------------------------------------- *
 * 平台 IO <-> vreg128_t 的字节搬运
 *
 * 平台侧：VecInput.srcN[0] 是向量寄存器的低 64 位（字节 0..7），
 *         srcN[1] 是高 64 位（字节 8..15）。
 * 模型侧：vreg128_t.v[i] 就是第 i 个字节（见 vdot_ref.h §1）。
 * 逐字节移位而不是 memcpy，保证不依赖宿主机字节序。
 * ---------------------------------------------------------------- */
static void vdot_pack_vreg(const uint64_t src[2], vreg128_t *r) {
  for (int i = 0; i < 8; i++) {
    r->v[i]     = (uint8_t)((src[0] >> (8 * i)) & 0xffu);
    r->v[i + 8] = (uint8_t)((src[1] >> (8 * i)) & 0xffu);
  }
}

static void vdot_unpack_vreg(const vreg128_t *r, uint64_t dst[2]) {
  dst[0] = 0;
  dst[1] = 0;
  for (int i = 0; i < 8; i++) {
    dst[0] |= ((uint64_t)r->v[i])     << (8 * i);
    dst[1] |= ((uint64_t)r->v[i + 8]) << (8 * i);
  }
}

/* 平台的 8 位紧凑 fuOpType -> enum vdot_op（编号一一对应，见 vpu_constant.h） */
static int vdot_op_of(uint8_t fuOpType) {
  switch (fuOpType) {
    case VDOT_VV:     return VDOT_OP_VDOT;
    case VDOTACC_VV:  return VDOT_OP_VDOTACC;
    case VDOT4A_VV:   return VDOT_OP_VDOT4A;
    default:
      printf("VGMDot: unsupported fuOpType %d\n", fuOpType);
      exit(1);
  }
}

VecOutput VGMDot::get_expected_output(VecInput input) {
  VecOutput output;   /* result/fflags/vxsat 由 iotype.h 的默认初值清零 */

  vreg128_t vs2, vs1, vd, v0;
  vdot_pack_vreg(input.src1, &vs2);   /* SimTop 的 src(0) -> VDotTop.vs2 */
  vdot_pack_vreg(input.src2, &vs1);   /* SimTop 的 src(1) -> VDotTop.vs1 */
  vdot_pack_vreg(input.src3, &vd);    /* SimTop 的 src(2) -> VDotTop.oldVd */
  vdot_pack_vreg(input.src4, &v0);    /* SimTop 的 src(3) -> VDotTop.mask  */

  const vreg128_t *mask = input.vinfo.vm ? NULL : &v0;
  const int op   = vdot_op_of(input.fuOpType);
  const int vsew = (op == VDOT_OP_VDOT4A) ? 32 : 8;

  /* vstart 策略取 SKIP：
   * FU 级平台不建模异常，而 RTL 的归约数据通路（active 使能带 begin=vstart）天然实现的
   * 就是 §5.4 的 prestart 跳过语义。架构层面的 STRICT 行为（vstart!=0 -> Illegal Instruction，
   * 裁定 S-1）由 XiangShan 的 VecExceptionGen.scala:275 在译码阶段实现，不在本层验证。
   * 本平台的 TestDriver 对 VDot 恒置 vstart=0，两种策略在默认激励下完全等价。 */
  const int st = vdot_exec(op, vsew, &vd, &vs2, &vs1,
                           (uint32_t)input.vinfo.vstart,
                           (uint32_t)input.vinfo.vl,
                           mask,
                           input.vinfo.ta ? 1 : 0,
                           input.vinfo.ma ? 1 : 0,
                           VDOT_VSTART_SKIP);
  if (st != VDOT_OK) {
    /* 到这里说明激励越过了架构约束（例如 vl > VLMAX），属于 TestDriver 的配置错误 */
    printf("VGMDot: vdot_ref returned %s (op=%s vsew=%d vstart=%d vl=%d)\n",
           vdot_status_name(st), vdot_op_name(op), vsew,
           input.vinfo.vstart, input.vinfo.vl);
    exit(1);
  }

  vdot_unpack_vreg(&vd, output.result);
  if (verbose) {
    printf("VGMDot: op=%s vl=%d vm=%d ta=%d ma=%d -> result %016lx_%016lx\n",
           vdot_op_name(op), input.vinfo.vl, input.vinfo.vm,
           input.vinfo.ta, input.vinfo.ma, output.result[1], output.result[0]);
  }
  return output;
}

/* 下面四个是 VPUGoldenModel 的纯虚接口（逐元素模型），vdot 走整寄存器模型，
 * 不经过 select_element 通路，故这里只提供不会被调用的占位实现。 */
ElementOutput VGMDot::calculation_e8(ElementInput input)  { ElementOutput o = {0, 0, false}; (void)input; return o; }
ElementOutput VGMDot::calculation_e16(ElementInput input) { ElementOutput o = {0, 0, false}; (void)input; return o; }
ElementOutput VGMDot::calculation_e32(ElementInput input) { ElementOutput o = {0, 0, false}; (void)input; return o; }
ElementOutput VGMDot::calculation_e64(ElementInput input) { ElementOutput o = {0, 0, false}; (void)input; return o; }
