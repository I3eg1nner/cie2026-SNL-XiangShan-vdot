// =============================================================================
// vecfu_latency_tb.cpp —— 直接驱动 VIAluFix / VIPU 实测功能单元延迟
//                         （赛题阶段三 3.3 / P7 T2）
//
// 为什么需要它
//   RVV 1.0 基线序列的三条核心指令分别落在三个不同的功能单元上：
//       vmv.s.x / vwadd.wv  -> FuType.vialuF -> VIAluFix (VialuCfg, latency=1)
//       vwmul.vv            -> FuType.vimac  -> VIMacU   (VimacCfg, latency=2)
//       vwredsum.vs         -> FuType.vipu   -> VIPU     (VipuCfg,  latency=2)
//   YunSuan 的 L1 平台只例化了 YunSuan 自己的 VIAluFWrapper，既没有 VIMacU 也
//   没有 VIPU；而且它的 io_out_valid 由平台计数器按常量产生。本 tb 通过
//   VecFuLatHarness 直接驱动**真正被集成进香山的**功能单元，io_outValid 来自
//   FU 自己的 io.out.valid（经与 ExeUnit.scala:228-241 完全一致的 pipelineReg 链）。
//
// 测什么
//   1) in.fire -> out.valid 的周期数（延迟）
//   2) 结果数据真正出现在第几拍（settle cycle）——证明不只是 valid 位在打拍，
//      数据通路深度也是同一个值
//   3) 对能用几行 C 写清语义的指令（vadd.vv / vwadd.wv / vmv.s.x）再做逐位数值
//      比对，使延迟数字不是空洞的握手观测
//
// 编译时用 -DTOPMOD=VIAluFixHarness 或 -DTOPMOD=VIPUHarness 选择 DUT。
// =============================================================================
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>

#include "verilated.h"

#define STR2(x) #x
#define STR(x)  STR2(x)
#define CONCAT2(a, b) a##b
#define CONCAT(a, b)  CONCAT2(a, b)
#define DUTCLASS CONCAT(V, TOPMOD)
#include STR(CONCAT(V, TOPMOD).h)

typedef struct { uint8_t v[16]; } reg128_t;

static DUTCLASS *dut = nullptr;

static void eval_low()  { dut->clock = 0; dut->eval(); }
static void eval_high() { dut->clock = 1; dut->eval(); }

static void do_reset() {
  dut->reset = 1; dut->io_valid = 0;
  for (int i = 0; i < 5; i++) { eval_low(); eval_high(); }
  dut->reset = 0;
  eval_low(); eval_high();
}

static void pack(const reg128_t *r, uint64_t *lo, uint64_t *hi) {
  *lo = 0; *hi = 0;
  for (int i = 0; i < 8; i++) {
    *lo |= ((uint64_t)r->v[i])     << (8 * i);
    *hi |= ((uint64_t)r->v[i + 8]) << (8 * i);
  }
}
static void unpack(uint64_t lo, uint64_t hi, reg128_t *r) {
  for (int i = 0; i < 8; i++) {
    r->v[i]     = (uint8_t)((lo >> (8 * i)) & 0xffu);
    r->v[i + 8] = (uint8_t)((hi >> (8 * i)) & 0xffu);
  }
}
static int eq128(const reg128_t *a, const reg128_t *b) {
  return memcmp(a, b, sizeof(reg128_t)) == 0;
}
static void hex128(const reg128_t *r, char *out) {
  for (int i = 0; i < 16; i++) sprintf(out + 2 * i, "%02x", r->v[i]);
  out[32] = 0;
}

struct Stim {
  uint32_t fuOpType;
  int vsew, vlmul, vstart, vl, vuopIdx, lastUop, vm, vta, vma;
  reg128_t vs1, vs2, oldVd, v0;
};

#define MAXW 6
/* 送一笔事务。返回 out.valid 拉高的周期数（-1 = 超时）。
 * seen[t] 记录第 t 拍（下降沿采样）的 vd，用于判定数据真正在第几拍成形。 */
static int issue(const Stim &s, reg128_t *out, reg128_t seen[MAXW + 1]) {
  uint64_t lo, hi;
  dut->io_valid    = 1;
  dut->io_fuOpType = s.fuOpType;
  dut->io_vsew     = (uint8_t)s.vsew;
  dut->io_vlmul    = (uint8_t)s.vlmul;
  dut->io_vstart   = (uint8_t)s.vstart;
  dut->io_vl       = (uint8_t)s.vl;
  dut->io_vuopIdx  = (uint8_t)s.vuopIdx;
  dut->io_lastUop  = s.lastUop;
  dut->io_vm       = s.vm;
  dut->io_vta      = s.vta;
  dut->io_vma      = s.vma;
  pack(&s.vs2,   &lo, &hi); dut->io_vs2Lo   = lo; dut->io_vs2Hi   = hi;
  pack(&s.vs1,   &lo, &hi); dut->io_vs1Lo   = lo; dut->io_vs1Hi   = hi;
  pack(&s.oldVd, &lo, &hi); dut->io_oldVdLo = lo; dut->io_oldVdHi = hi;
  pack(&s.v0,    &lo, &hi); dut->io_maskLo  = lo; dut->io_maskHi  = hi;

  eval_low();
  eval_high();                 /* 这一拍 fire */
  dut->io_valid = 0;

  int lat = -1;
  for (int t = 1; t <= MAXW; t++) {
    eval_low();
    unpack(dut->io_vdLo, dut->io_vdHi, &seen[t]);
    if (lat < 0 && dut->io_outValid) { lat = t; *out = seen[t]; }
    eval_high();
  }
  for (int k = 0; k < 2; k++) { eval_low(); eval_high(); }   /* 排空 */
  return lat;
}

struct Hist {
  const char *name = "";
  long n = 0, timeout = 0, data_ok = 0, data_bad = 0, data_unchecked = 0;
  long lat[MAXW + 2] = {0};
  long settle[MAXW + 2] = {0};
  int uniq(const long *a) const {
    int u = -1, k = 0;
    for (int i = 0; i <= MAXW; i++) if (a[i]) { u = i; k++; }
    return k == 1 ? u : -1;
  }
};

static void report(const Hist &h) {
  printf("  %-12s 事务=%-4ld  out.valid 延迟: ", h.name, h.n);
  for (int i = 0; i <= MAXW; i++) if (h.lat[i]) printf("%d拍×%ld ", i, h.lat[i]);
  if (h.timeout) printf("timeout×%ld ", h.timeout);
  int u = h.uniq(h.lat);
  printf("=> %s", u >= 0 ? "" : "不唯一");
  if (u >= 0) printf("实测 %d 拍", u);
  printf(" | 数据成形: ");
  for (int i = 0; i <= MAXW; i++) if (h.settle[i]) printf("%d拍×%ld ", i, h.settle[i]);
  if (h.data_ok || h.data_bad)
    printf("| 数值比对 ok=%ld bad=%ld", h.data_ok, h.data_bad);
  else
    printf("| 数值比对：未建模 (%ld 笔)", h.data_unchecked);
  printf("\n");
}

static uint32_t rs = 0x20261024u;
static uint32_t rng(void) { rs = rs * 1103515245u + 12345u; return rs >> 8; }
static void randreg(reg128_t *r) { for (int i = 0; i < 16; i++) r->v[i] = (uint8_t)rng(); }

static uint32_t get32(const reg128_t *r, int i) {
  return (uint32_t)r->v[4*i] | ((uint32_t)r->v[4*i+1] << 8)
       | ((uint32_t)r->v[4*i+2] << 16) | ((uint32_t)r->v[4*i+3] << 24);
}
static void put32(reg128_t *r, int i, uint32_t v) {
  r->v[4*i] = (uint8_t)v; r->v[4*i+1] = (uint8_t)(v >> 8);
  r->v[4*i+2] = (uint8_t)(v >> 16); r->v[4*i+3] = (uint8_t)(v >> 24);
}
static uint16_t get16(const reg128_t *r, int i) {
  return (uint16_t)((uint16_t)r->v[2*i] | ((uint16_t)r->v[2*i+1] << 8));
}

/* ---- fuOpType 编码（yunsuan/src/main/scala/yunsuan/package.scala） ----
 *   VialuFixType = format(2) ++ sign(1) ++ VialuOpcode(6)
 *     vadd_vv  = 00_1_000000 = 0x040   (VialuOpcode.vadd = 0)
 *     vwadd_wv = 10_1_000000 = 0x140
 *     vmv_s_x  = 00_1_101110 = 0x06E   (VialuOpcode.vmvsx = 46)
 *   VipuType（直接写死的 8 位串）
 *     vredsum_vs  = b00111001 = 0x039
 *     vwredsum_vs = b01000010 = 0x042                                        */
static const uint32_t OP_VADD_VV     = 0x040;
static const uint32_t OP_VWADD_WV    = 0x140;
static const uint32_t OP_VMV_S_X     = 0x06E;
static const uint32_t OP_VREDSUM_VS  = 0x039;
static const uint32_t OP_VWREDSUM_VS = 0x042;

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  long nops = 32;
  if (const char *e = getenv("VECFU_LAT_OPS")) nops = strtol(e, nullptr, 0);
  if (nops < 8) nops = 8;

  dut = new DUTCLASS;
  do_reset();

  printf("=====================================================================\n");
  printf(" %s —— 功能单元延迟实测（in.fire -> out.valid）\n", STR(TOPMOD));
  printf(" harness: src/test/scala/xiangshan/backend/fu/VecFuLatHarness.scala\n");
  printf(" 每条指令 %ld 笔随机激励\n", nops);
  printf("=====================================================================\n\n");

  int exit_code = 0;
  int ncase = 0;
  struct Case { const char *name; uint32_t op; int vsew, vlmul, vl; int model; };
  /* model: 0=不建模 1=vadd.vv(e8) 2=vwadd.wv(e16->e32) 3=vmv.s.x(e32) */
#if defined(VIALU_MODE)
  Case cases[] = {
    { "vadd.vv",     OP_VADD_VV,  0, 0, 16, 1 },   /* e8 , LMUL=1 —— 数值可建模的锚点 */
    { "vwadd.wv",    OP_VWADD_WV, 1, 1, 16, 2 },   /* e16, LMUL=2 —— 基线 D 的循环携带指令 */
    { "vmv.s.x",     OP_VMV_S_X,  2, 0,  4, 3 },   /* e32, LMUL=1 —— 基线的累加器清零指令 */
  };
  ncase = 3;
#else
  Case cases[] = {
    { "vredsum.vs",  OP_VREDSUM_VS,  2, 2, 16, 0 },  /* e32, LMUL=4（基线 D 循环外的一次归约） */
    { "vwredsum.vs", OP_VWREDSUM_VS, 1, 1, 16, 0 },  /* e16, LMUL=2（单次点积基线的归约） */
  };
  ncase = 2;
#endif

  printf("CSVHDR,instruction,fu,measured_latency_cycles,data_settle_cycles,transactions,data_checked\n");
  for (int ci = 0; ci < ncase; ci++) {
    Hist h; h.name = cases[ci].name;
    char badbuf[3][80]; int nbad = 0;
    for (long i = 0; i < nops; i++) {
      Stim s;
      s.fuOpType = cases[ci].op;
      s.vsew = cases[ci].vsew; s.vlmul = cases[ci].vlmul;
      s.vstart = 0; s.vl = cases[ci].vl;
      s.vuopIdx = 0; s.lastUop = 1;
      s.vm = 1; s.vta = 1; s.vma = 1;
      randreg(&s.vs1); randreg(&s.vs2); randreg(&s.oldVd);
      for (int b = 0; b < 16; b++) s.v0.v[b] = 0xff;

      reg128_t got, seen[MAXW + 1];
      memset(&got, 0, sizeof(got));
      int lat = issue(s, &got, seen);
      h.n++;
      if (lat < 0) { h.timeout++; exit_code = 1; continue; }
      h.lat[lat]++;
      /* 数据成形拍：vd 第一次等于 out.valid 那拍的值 */
      int sc = lat;
      for (int t = 1; t <= lat; t++) if (eq128(&seen[t], &got)) { sc = t; break; }
      h.settle[sc]++;

      reg128_t ref; int have_ref = 1;
      memset(&ref, 0, sizeof(ref));
      switch (cases[ci].model) {
        case 1:  /* vadd.vv, SEW=8, vl=16, vta=1, vm=1：全 body，无 tail */
          for (int e = 0; e < 16; e++)
            ref.v[e] = (uint8_t)(s.vs2.v[e] + s.vs1.v[e]);
          break;
        case 2:  /* vwadd.wv, SEW=16->32, uopIdx=0：4 个 32 位结果 */
          for (int e = 0; e < 4; e++)
            put32(&ref, e, get32(&s.vs2, e) + (uint32_t)(int32_t)(int16_t)get16(&s.vs1, e));
          break;
        case 3:  /* vmv.s.x, SEW=32, vl=4, vta=1：vd[0]=vs1[0]，其余为 tail */
          put32(&ref, 0, get32(&s.vs1, 0));
          for (int e = 1; e < 4; e++) put32(&ref, e, 0xffffffffu);
          break;
        default: have_ref = 0; break;
      }
      if (!have_ref) { h.data_unchecked++; continue; }
      if (eq128(&got, &ref)) h.data_ok++;
      else {
        h.data_bad++;
        if (nbad < 3) {
          char g[40], r2[40];
          hex128(&got, g); hex128(&ref, r2);
          snprintf(badbuf[nbad], sizeof(badbuf[0]), "got=%s ref=%s", g, r2);
          nbad++;
        }
      }
    }
    report(h);
    for (int k = 0; k < nbad; k++) printf("        %s\n", badbuf[k]);
    printf("CSVROW,%s,%s,%d,%d,%ld,%ld\n", cases[ci].name, STR(TOPMOD),
           h.uniq(h.lat), h.uniq(h.settle), h.n, h.data_ok);
  }

  printf("\nRESULT: %s\n", exit_code == 0 ? "PASS" : "FAIL");
  return exit_code;
}
