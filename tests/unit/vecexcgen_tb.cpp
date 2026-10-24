// =============================================================================
// vecexcgen_tb.cpp —— VecExceptionGen（译码级合法性判定）的定向测试平台
//
// 覆盖目标
//   1) 【本阶段新增的修复】dotEmulIllegal：vdot 指令族本版本固定 LMUL = 1
//      （总体方案裁定 S-6），vtype.vlmul != 0 必须触发 Illegal Instruction。
//      修复前 VecExceptionGen 不拦截，LMUL>1 的 vdot.vv 会静默算错
//      （docs/stage2/11_RTL实现说明.md §10 第 8 条登记的缺口）。
//   2) dotEewIllegal 回归：vdot/vdotacc 只许 SEW=8，vdot4a 只许 SEW=32。
//   3) vstartIllegal 回归：归约类 vstart!=0 触发非法（裁定 S-1）。
//   4) 既有向量指令不受影响：vadd.vv / vmacc.vv 在各种 SEW/LMUL 下仍然合法。
//
// DUT 是 VecExceptionGenHarness（src/test/scala/xiangshan/backend/decode/
// VecExceptionGenTest.scala），它只是把 VecExceptionGen 真正用到的 4 个
// DecodedInst 字段按「向量算术指令」写死，不含任何判定逻辑。
//
// 用法： ./vecexcgen_tb        （退出码 0 = 全部符合预期）
// =============================================================================
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "verilated.h"
#include "VVecExceptionGenHarness.h"

static VVecExceptionGenHarness *dut = nullptr;

/* 指令字拼接。寄存器统一取 vd=8 / vs1=16 / vs2=24：
 *   三者互不重叠，且都是 8 的倍数，LMUL 最大到 8 时寄存器号仍然对齐，
 *   从而把「寄存器号不对齐 / 重叠」这两条无关判据排除在外。 */
static uint32_t enc(uint32_t funct6, uint32_t vm, uint32_t funct3) {
  const uint32_t vs2 = 24, vs1 = 16, vd = 8, opcode = 0x57;
  return (funct6 << 26) | (vm << 25) | (vs2 << 20) | (vs1 << 15) |
         (funct3 << 12) | (vd << 7) | opcode;
}

static const uint32_t INST_VDOT    = enc(0b111001, 1, 0b000);  // vdot.vv    v8, v24, v16
static const uint32_t INST_VDOTACC = enc(0b111010, 1, 0b000);  // vdotacc.vv v8, v24, v16
static const uint32_t INST_VDOT4A  = enc(0b111011, 1, 0b000);  // vdot4a.vv  v8, v24, v16
static const uint32_t INST_VADD    = enc(0b000000, 1, 0b000);  // vadd.vv    v8, v24, v16
static const uint32_t INST_VMACC   = enc(0b101101, 1, 0b010);  // vmacc.vv   v8, v24, v16 (OPMVV)

static int n_pass = 0, n_fail = 0;

static void check(const char *name, uint32_t inst, int vsew, int vlmul,
                  int vstart, int expect_illegal) {
  dut->io_inst   = inst;
  dut->io_vsew   = vsew;
  dut->io_vlmul  = vlmul;
  dut->io_vill   = 0;
  dut->io_vstart = vstart;
  dut->eval();
  int got = dut->io_illegal ? 1 : 0;
  const char *r = (got == expect_illegal) ? "PASS" : "FAIL";
  if (got == expect_illegal) n_pass++; else n_fail++;
  printf("  %-4s  %-26s inst=%08x vsew=%d vlmul=%d vstart=%-2d  期望 illegal=%d 实测 illegal=%d\n",
         r, name, inst, vsew, vlmul, vstart, expect_illegal, got);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new VVecExceptionGenHarness;

  printf("DUT: VecExceptionGenHarness（内部例化真正的 VecExceptionGen）\n");
  printf("vlmul 编码： 0=m1  1=m2  2=m4  3=m8  5=mf8  6=mf4  7=mf2（4 为保留）\n");
  printf("vsew  编码： 0=e8  1=e16 2=e32 3=e64\n\n");

  printf("[A] vdot.vv —— 唯一合法组合 SEW=8 & LMUL=1\n");
  check("vdot 合法基准", INST_VDOT, 0, 0, 0, 0);
  printf("\n[B] vdot.vv —— LMUL>1 必须非法（本阶段新增的 dotEmulIllegal）\n");
  check("vdot LMUL=2",  INST_VDOT, 0, 1, 0, 1);
  check("vdot LMUL=4",  INST_VDOT, 0, 2, 0, 1);
  check("vdot LMUL=8",  INST_VDOT, 0, 3, 0, 1);
  printf("\n[C] vdot.vv —— 分数 LMUL 同样非法（本版本只定义 LMUL=1）\n");
  check("vdot LMUL=1/8", INST_VDOT, 0, 5, 0, 1);
  check("vdot LMUL=1/4", INST_VDOT, 0, 6, 0, 1);
  check("vdot LMUL=1/2", INST_VDOT, 0, 7, 0, 1);
  check("vdot vlmul=保留", INST_VDOT, 0, 4, 0, 1);

  printf("\n[D] vdotacc.vv —— 同样的 LMUL 约束\n");
  check("vdotacc 合法基准", INST_VDOTACC, 0, 0, 0, 0);
  check("vdotacc LMUL=2",  INST_VDOTACC, 0, 1, 0, 1);
  check("vdotacc LMUL=8",  INST_VDOTACC, 0, 3, 0, 1);
  check("vdotacc LMUL=1/2",INST_VDOTACC, 0, 7, 0, 1);

  printf("\n[E] vdot4a.vv —— SEW=32 & LMUL=1\n");
  check("vdot4a 合法基准", INST_VDOT4A, 2, 0, 0, 0);
  check("vdot4a LMUL=2",  INST_VDOT4A, 2, 1, 0, 1);
  check("vdot4a LMUL=4",  INST_VDOT4A, 2, 2, 0, 1);
  check("vdot4a LMUL=1/2",INST_VDOT4A, 2, 7, 0, 1);

  printf("\n[F] dotEewIllegal 回归 —— vdot/vdotacc 只许 SEW=8\n");
  check("vdot SEW=16",    INST_VDOT, 1, 0, 0, 1);
  check("vdot SEW=32",    INST_VDOT, 2, 0, 0, 1);
  check("vdot SEW=64",    INST_VDOT, 3, 0, 0, 1);
  check("vdotacc SEW=32", INST_VDOTACC, 2, 0, 0, 1);

  printf("\n[G] dotEewIllegal 回归 —— vdot4a 只许 SEW=32\n");
  check("vdot4a SEW=8",  INST_VDOT4A, 0, 0, 0, 1);
  check("vdot4a SEW=16", INST_VDOT4A, 1, 0, 0, 1);
  check("vdot4a SEW=64", INST_VDOT4A, 3, 0, 0, 1);

  printf("\n[H] vstartIllegal 回归 —— 裁定 S-1（归约类 vstart!=0 非法）\n");
  check("vdot vstart=1",   INST_VDOT, 0, 0, 1,  1);
  check("vdot vstart=15",  INST_VDOT, 0, 0, 15, 1);
  check("vdotacc vstart=1",INST_VDOTACC, 0, 0, 1, 1);

  printf("\n[I] 既有向量指令不受影响 —— vadd.vv 在各 SEW × LMUL 下仍然合法\n");
  for (int sew = 0; sew <= 3; sew++)
    for (int lmul = 0; lmul <= 3; lmul++) {
      char nm[64]; snprintf(nm, sizeof(nm), "vadd SEW=%d LMUL=%d", 8 << sew, 1 << lmul);
      check(nm, INST_VADD, sew, lmul, 0, 0);
    }

  printf("\n[J] 既有 vimac 指令不受影响 —— vmacc.vv LMUL>1 仍然合法\n");
  check("vmacc SEW=8  LMUL=1", INST_VMACC, 0, 0, 0, 0);
  check("vmacc SEW=8  LMUL=2", INST_VMACC, 0, 1, 0, 0);
  check("vmacc SEW=32 LMUL=8", INST_VMACC, 2, 3, 0, 0);
  check("vmacc SEW=64 LMUL=4", INST_VMACC, 3, 2, 0, 0);

  printf("\n----------------------------------------------------------------------\n");
  printf("VecExceptionGen 定向测试： 共 %d 条，PASS %d，FAIL %d\n",
         n_pass + n_fail, n_pass, n_fail);
  printf("%s\n", n_fail == 0 ? "VECEXC-TB: PASS" : "VECEXC-TB: FAIL");

  dut->final();
  delete dut;
  return n_fail == 0 ? 0 : 1;
}
