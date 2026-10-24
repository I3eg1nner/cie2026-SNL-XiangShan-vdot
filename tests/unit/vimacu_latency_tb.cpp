// =============================================================================
// vimacu_latency_tb.cpp —— 直接驱动 VIMacU（真正被集成进香山的向量整数乘法功能
//                          单元）测量 in.fire -> out.valid 的**实测周期数**
//                          （赛题阶段三 3.3 / P7 T2）
//
// 为什么在这里测
//   L1 的 YunSuan 平台（SimTop）的 io_out_valid 是由测试平台自己的计数器
//   `counter >= latency` 产生的（VectorSimTop.scala:117-124），latency 来自
//   平台常量 VDOT_latency，因此它只能证明「平台按声明值收结果」，不能单独证明
//   DUT 本身的流水深度。
//   VIMacUHarness 则不同：它照搬 ExeUnit.scala 的 pipelineReg 链
//   （validPipe/ctrlPipe/dataPipe，链长 = VimacCfg.latency + 1），
//   io_outValid 直接来自 VIMacU 自己的 io.out.valid，
//   所以这里测到的就是**这条功能单元在昆明湖 V2 流水线里的真实延迟**。
//
// 同时测三类 fuOpType：
//   * vdot / vdotacc / vdot4a —— 本方案新增，结果与 tests/golden/vdot_ref.c 逐位比对
//   * vwmul / vmul / vmacc    —— 上游既有指令，用于证明「新增 vdot 没有把既有
//                                vimac 指令变慢」，也给基线里的 vwmul.vv 一个实测值
//
// 用法： ./vimacu_latency_tb <vdot语料文件>
//        VIMACU_LAT_OPS=N 控制既有指令每条跑多少笔（默认 32，要求 >= 8）
//        退出码 0 = 全部一致且延迟一致；1 = 有失配
// =============================================================================
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

#include "verilated.h"
#include "VVIMacUHarness.h"

/* 语义唯一事实来源（由 scripts/tools/run_vimacu_latency.sh 复制到构建目录） */
#include "vdot_ref.c"

/* VimacType 的 9 位编码
 * （work/XiangShan-cosim/yunsuan/src/main/scala/yunsuan/package.scala
 *   vmul:425 vwmul:426 vmacc:432 vdot:451 vdotacc:452 vdot4a:453）
 *   位域： [8:7]pad  [6]vs2Sign [5]vs1Sign [4]vdSign [3]format [2:0]opcode */
static const uint32_t FUOP_VMUL    = 0x060;  // b00_110_0_000
static const uint32_t FUOP_VWMUL   = 0x068;  // b00_110_1_000
static const uint32_t FUOP_VMACC   = 0x072;  // b00_111_0_010
static const uint32_t FUOP_VDOT    = 0x0E7;  // b01_110_0_111
static const uint32_t FUOP_VDOTACC = 0x177;  // b10_111_0_111
static const uint32_t FUOP_VDOT4A  = 0x1F7;  // b11_111_0_111

static VVIMacUHarness *dut = nullptr;

static void eval_low()  { dut->clock = 0; dut->eval(); }
static void eval_high() { dut->clock = 1; dut->eval(); }

static void do_reset() {
  dut->reset = 1; dut->io_valid = 0;
  for (int i = 0; i < 5; i++) { eval_low(); eval_high(); }
  dut->reset = 0;
  eval_low(); eval_high();
}

static void pack(const vreg128_t *r, uint64_t *lo, uint64_t *hi) {
  *lo = 0; *hi = 0;
  for (int i = 0; i < 8; i++) {
    *lo |= ((uint64_t)r->v[i])     << (8 * i);
    *hi |= ((uint64_t)r->v[i + 8]) << (8 * i);
  }
}
static void unpack(uint64_t lo, uint64_t hi, vreg128_t *r) {
  for (int i = 0; i < 8; i++) {
    r->v[i]     = (uint8_t)((lo >> (8 * i)) & 0xffu);
    r->v[i + 8] = (uint8_t)((hi >> (8 * i)) & 0xffu);
  }
}

struct Stim {
  uint32_t fuOpType;
  int vsew, vstart, vl, vm, vta, vma;
  vreg128_t vs1, vs2, vd_in, v0;
};

/* 送一笔事务，返回 io_valid 拉高的那个上升沿到 io_outValid 拉高之间的周期数。
 * -1 表示 8 拍之内没有 outValid。 */
static int issue(const Stim &s, vreg128_t *out) {
  uint64_t lo, hi;
  dut->io_valid    = 1;
  dut->io_fuOpType = s.fuOpType;
  dut->io_vsew     = (uint8_t)s.vsew;
  dut->io_vstart   = (uint8_t)s.vstart;
  dut->io_vl       = (uint8_t)s.vl;
  dut->io_vm       = s.vm;
  dut->io_vta      = s.vta;
  dut->io_vma      = s.vma;
  pack(&s.vs2,   &lo, &hi); dut->io_vs2Lo   = lo; dut->io_vs2Hi   = hi;
  pack(&s.vs1,   &lo, &hi); dut->io_vs1Lo   = lo; dut->io_vs1Hi   = hi;
  pack(&s.vd_in, &lo, &hi); dut->io_oldVdLo = lo; dut->io_oldVdHi = hi;
  pack(&s.v0,    &lo, &hi); dut->io_maskLo  = lo; dut->io_maskHi  = hi;

  eval_low();
  eval_high();                 /* 这一拍 fire（io_valid & 上升沿） */
  dut->io_valid = 0;

  for (int t = 1; t <= 8; t++) {
    eval_low();
    if (dut->io_outValid) {
      unpack(dut->io_vdLo, dut->io_vdHi, out);
      eval_high();
      for (int k = 0; k < 2; k++) { eval_low(); eval_high(); }   /* 排空 */
      return t;
    }
    eval_high();
  }
  return -1;
}

/* ---- 延迟直方图 ---- */
struct LatHist {
  const char *name;
  long n = 0, data_ok = 0, data_bad = 0, timeout = 0;
  long cnt[10] = {0};
  void add(int l) { if (l >= 0 && l < 10) cnt[l]++; else timeout++; n++; }
  int unique_lat() const {
    int u = -1, k = 0;
    for (int i = 0; i < 10; i++) if (cnt[i]) { u = i; k++; }
    return k == 1 ? u : -1;
  }
};

static void print_hist(const LatHist &h) {
  printf("  %-10s  事务=%-5ld  延迟分布: ", h.name, h.n);
  for (int i = 0; i < 10; i++) if (h.cnt[i]) printf("%d拍×%ld ", i, h.cnt[i]);
  if (h.timeout) printf("timeout×%ld ", h.timeout);
  int u = h.unique_lat();
  if (u >= 0) printf(" => 实测延迟 = %d 拍（%ld/%ld 一致）", u, h.cnt[u], h.n);
  else printf(" => 延迟不唯一");
  if (h.data_ok || h.data_bad)
    printf("；数据比对 ok=%ld bad=%ld", h.data_ok, h.data_bad);
  printf("\n");
}

/* ---- 语料解析（与 tests/unit/vimacu_tb.cpp 同一格式） ---- */
struct TestCase {
  std::string op;
  int vsew, vstart, vl, vm, vta, vma;
  vreg128_t vs1, vs2, vd_in, vd_exp, v0;
};
static int parse_line(const char *line, TestCase *c) {
  char op[32], vs1h[72], vs2h[72], vdh[72], vdeh[72], v0h[72], st[32];
  int vsew, vstart, vl, vm, vta, vma;
  int n = sscanf(line, "%31s %d %d %d %d %d %d %71s %71s %71s %71s %71s %31s",
                 op, &vsew, &vstart, &vl, &vm, &vta, &vma,
                 vs1h, vs2h, vdh, vdeh, v0h, st);
  if (n != 13) return -1;
  if (strcmp(st, "OK") != 0) return 1;
  c->op = op; c->vsew = vsew; c->vstart = vstart; c->vl = vl;
  c->vm = vm; c->vta = vta; c->vma = vma;
  if (vdot_hex_parse(vs1h, &c->vs1)  != 0) return -1;
  if (vdot_hex_parse(vs2h, &c->vs2)  != 0) return -1;
  if (vdot_hex_parse(vdh,  &c->vd_in)!= 0) return -1;
  if (vdot_hex_parse(vdeh, &c->vd_exp)!= 0) return -1;
  if (vdot_hex_parse(v0h,  &c->v0)   != 0) return -1;
  return 0;
}

/* ---- 既有指令的随机激励 ---- */
static uint32_t rng_state = 0x2026u;
static uint32_t rng(void) {
  rng_state = rng_state * 1103515245u + 12345u;
  return rng_state >> 8;
}

/* vwmul.vv 的两种候选模型（SEW=8、LMUL=1、vuopIdx=0）：
 * 加宽指令的目的寄存器组 EMUL=2，一个 uop 产出 8 个 16 位积。
 * 这里不预设 uopIdx=0 对应低半还是高半，两种都算，报告哪一种命中。 */
static void vwmul_model(const vreg128_t *vs2, const vreg128_t *vs1,
                        int base, vreg128_t *out) {
  for (int i = 0; i < 8; i++) {
    int a = (int8_t)vs2->v[base + i];
    int b = (int8_t)vs1->v[base + i];
    int32_t p = a * b;
    out->v[2 * i]     = (uint8_t)(p & 0xff);
    out->v[2 * i + 1] = (uint8_t)((p >> 8) & 0xff);
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  long nops = 32;
  if (const char *e = getenv("VIMACU_LAT_OPS")) nops = strtol(e, nullptr, 0);
  if (nops < 8) nops = 8;

  dut = new VVIMacUHarness;
  do_reset();

  printf("=====================================================================\n");
  printf(" VIMacU 功能单元延迟实测（in.fire -> out.valid）\n");
  printf(" DUT  : VIMacUHarness -> VIMacU(VimacCfg)  （真正被集成进香山的那一个）\n");
  printf(" 声明值: FuConfig.scala:563  VimacCfg.latency = CertainLatency(2)\n");
  printf("=====================================================================\n\n");

  int exit_code = 0;
  LatHist hv[3] = {};
  hv[0].name = "vdot";  hv[1].name = "vdotacc"; hv[2].name = "vdot4a";

  /* ---------- (1) vdot 指令族：定向语料 + 数据逐位比对 ---------- */
  printf("--- (1) vdot 指令族（激励来自共享语料，结果与 tests/golden/vdot_ref.c 逐位比对）---\n");
  for (int a = 1; a < argc; a++) {
    FILE *f = fopen(argv[a], "r");
    if (!f) { printf("无法打开 %s\n", argv[a]); return 2; }
    char line[1024];
    while (fgets(line, sizeof(line), f)) {
      if (line[0] == '#' || line[0] == '\n' || line[0] == '\r') continue;
      TestCase c;
      int r = parse_line(line, &c);
      if (r != 0) continue;
      int k = (c.op == "vdot") ? 0 : (c.op == "vdotacc") ? 1 : 2;
      Stim s;
      s.fuOpType = (k == 0) ? FUOP_VDOT : (k == 1) ? FUOP_VDOTACC : FUOP_VDOT4A;
      s.vsew = (k == 2) ? 2 : 0;
      s.vstart = c.vstart; s.vl = c.vl; s.vm = c.vm; s.vta = c.vta; s.vma = c.vma;
      s.vs1 = c.vs1; s.vs2 = c.vs2; s.vd_in = c.vd_in; s.v0 = c.v0;

      vreg128_t ref = c.vd_in;
      int st = vdot_exec((k == 0) ? VDOT_OP_VDOT : (k == 1) ? VDOT_OP_VDOTACC : VDOT_OP_VDOT4A,
                         c.vsew, &ref, &c.vs2, &c.vs1,
                         (uint32_t)c.vstart, (uint32_t)c.vl,
                         c.vm ? NULL : &c.v0, c.vta, c.vma, VDOT_VSTART_SKIP);
      if (st != VDOT_OK) continue;

      vreg128_t got;
      int lat = issue(s, &got);
      hv[k].add(lat);
      if (memcmp(&got, &ref, sizeof(got)) == 0) hv[k].data_ok++;
      else { hv[k].data_bad++; exit_code = 1; }
    }
    fclose(f);
  }
  for (int k = 0; k < 3; k++) print_hist(hv[k]);

  /* ---------- (2) 上游既有 vimac 指令 ---------- */
  printf("\n--- (2) 上游既有 vimac 指令（每条 %ld 笔随机激励）---\n", nops);
  struct { const char *name; uint32_t op; int vsew; } olds[] = {
    { "vmul.vv",  FUOP_VMUL,  0 },
    { "vwmul.vv", FUOP_VWMUL, 0 },
    { "vmacc.vv", FUOP_VMACC, 0 },
  };
  LatHist ho[3] = {};
  for (int oi = 0; oi < 3; oi++) {
    LatHist &h = ho[oi]; h.name = olds[oi].name;
    long wmul_lo = 0, wmul_hi = 0, wmul_none = 0;
    for (long i = 0; i < nops; i++) {
      Stim s;
      s.fuOpType = olds[oi].op; s.vsew = olds[oi].vsew;
      s.vstart = 0; s.vl = 16; s.vm = 1; s.vta = 1; s.vma = 1;
      for (int b = 0; b < 16; b++) {
        s.vs1.v[b] = (uint8_t)rng(); s.vs2.v[b] = (uint8_t)rng();
        s.vd_in.v[b] = (uint8_t)rng(); s.v0.v[b] = 0xff;
      }
      vreg128_t got;
      int lat = issue(s, &got);
      h.add(lat);
      if (olds[oi].op == FUOP_VWMUL && lat >= 0) {
        vreg128_t mlo, mhi;
        vwmul_model(&s.vs2, &s.vs1, 0, &mlo);
        vwmul_model(&s.vs2, &s.vs1, 8, &mhi);
        if      (memcmp(&got, &mlo, sizeof(got)) == 0) { wmul_lo++;   h.data_ok++; }
        else if (memcmp(&got, &mhi, sizeof(got)) == 0) { wmul_hi++;   h.data_ok++; }
        else                                           { wmul_none++; h.data_bad++; }
      }
    }
    print_hist(h);
    if (olds[oi].op == FUOP_VWMUL) {
      printf("              vwmul 数据核对： 命中「元素0..7 的 16 位积」%ld 笔，"
             "命中「元素8..15」%ld 笔，两者皆不命中 %ld 笔\n",
             wmul_lo, wmul_hi, wmul_none);
      if (wmul_lo + wmul_hi == 0) {
        printf("              （两种模型都不命中：本 tb 只认定其延迟实测值，"
               "不对 vwmul 的数值正确性下结论）\n");
      }
    }
    if (h.unique_lat() < 0) exit_code = 1;
  }

  /* ---------- 汇总 ---------- */
  printf("\n--- 汇总（供 bench/results/latency_measured.csv 使用）---\n");
  printf("CSVHDR,instruction,fu,measured_latency_cycles,transactions,data_checked\n");
  const char *nm[3] = { "vdot.vv", "vdotacc.vv", "vdot4a.vv" };
  for (int k = 0; k < 3; k++)
    printf("CSVROW,%s,VIMacU,%d,%ld,%ld\n", nm[k], hv[k].unique_lat(),
           hv[k].n, hv[k].data_ok);
  for (int k = 0; k < 3; k++)
    printf("CSVROW,%s,VIMacU,%d,%ld,%ld\n", ho[k].name, ho[k].unique_lat(),
           ho[k].n, ho[k].data_ok);
  printf("\nRESULT: %s\n", exit_code == 0 ? "PASS" : "FAIL");
  return exit_code;
}
