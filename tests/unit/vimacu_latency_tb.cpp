// =============================================================================
// vimacu_latency_tb.cpp —— 直接驱动 VIMacU（真正被集成进香山的向量整数乘法功能
//                          单元）测量 in.fire -> out.valid 的**实测周期数**
//                          （赛题阶段三 3.3 / P7 T2）
//
// 本 tb 输出两类数字，性质不同，必须分开读
//   (a) out.valid 延迟 —— **平台构造值，不是独立证据**。
//       VIMacUHarness 按 ExeUnit.scala:228-241 搭 validPipe/ctrlPipe/dataPipe，
//       链长取自 VimacCfg.latency（VIMacUHarness.scala 中 nLat =
//       VimacCfg.latency.latencyVal.get）；VIMacU 的 out.valid =
//       validPipe(nLat) & validVecThisFu(nLat)，即 io_valid 经 harness 自己的
//       nLat 级寄存器。因此「out.valid 在第 2 拍」按构造必然成立，与 DUT 数据通路
//       深度无关（与 L1 平台 counter >= latency 是同一类问题）。保留它只为与声明值
//       对照，不能用它「证实」延迟。
//   (b) 数据成形拍 —— **独立观测**，不读 out.valid：
//       每笔事务在 fire 前（第 0 拍）与 fire 后第 1..MAXW 拍的下降沿各采一次 io_vd，
//       与参考模型（vdot 族：tests/golden/vdot_ref.c；vmul/vwmul/vmacc：本文件内的
//       逐元素 C 模型）比较：
//         * 第 2 拍（固定拍，不看 valid）io_vd 与参考逐位一致 => 数据通路深度 <= 2；
//         * 第 1 拍 io_vd 仍不等于参考                      => 该笔数据通路深度 >= 2。
//       「第 1 拍已等于参考」只能说明该笔观测到的成形拍 <= 1，可能是真成形，也可能
//       只是输出端残留的上一笔结果恰好与本笔相同（例如 vl=0 或全掩码时结果 = oldVd）。
//       所以成形拍是**下界型证据**：只在「fire 前输出 != 参考」的事务上才可判定；
//       不可判定的事务会换一笔「扰动前驱」事务后重测一次，仍不可判定的单独计数，
//       一律不计入「第 1 拍未成形」。
//
// 同时测两类 fuOpType：
//   * vdot / vdotacc / vdot4a —— 本方案新增，激励来自共享语料
//   * vmul / vwmul / vmacc    —— 上游既有指令，随机激励；用于回答「新增 vdot 有没有
//                                把既有 vimac 指令变慢」，也给基线里的 vwmul.vv 一个观测值
//
// 用法： ./vimacu_latency_tb <vdot语料文件>
//        VIMACU_LAT_OPS=N 控制既有指令每条跑多少笔（默认 32，要求 >= 8）
//        退出码 0 = 数据全部一致且 out.valid 延迟唯一；1 = 有失配
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

#define MAXW 4
/* 送一笔事务。seen[t] 为 fire 后第 t 拍（下降沿）采到的 io_vd，seen[0] 为 fire 那拍
 * 上升沿之前的输出（即上一笔残留在输出端的值）。返回 out.valid 第一次为 1 的拍数，
 * -1 表示 MAXW 拍内没有 out.valid。数据采样不依赖 out.valid。 */
static void set_inputs(const Stim &s) {
  uint64_t lo, hi;
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
}

static int issue(const Stim &s, vreg128_t seen[MAXW + 1]) {
  dut->io_valid = 1;
  set_inputs(s);

  eval_low();
  unpack(dut->io_vdLo, dut->io_vdHi, &seen[0]);
  eval_high();                 /* 这一拍 fire（io_valid & 上升沿） */
  dut->io_valid = 0;

  int lat = -1;
  for (int t = 1; t <= MAXW; t++) {
    eval_low();
    unpack(dut->io_vdLo, dut->io_vdHi, &seen[t]);
    if (lat < 0 && dut->io_outValid) lat = t;
    eval_high();
  }
  for (int k = 0; k < 2; k++) { eval_low(); eval_high(); }   /* 排空 */
  return lat;
}

static int eq128(const vreg128_t *a, const vreg128_t *b) {
  return memcmp(a, b, sizeof(vreg128_t)) == 0;
}
/* 第一次等于参考值的拍（1..MAXW），-1 = 从未等于 */
static int first_match(const vreg128_t seen[MAXW + 1], const vreg128_t *ref) {
  for (int t = 1; t <= MAXW; t++) if (eq128(&seen[t], ref)) return t;
  return -1;
}

/* ---- 统计 ---- */
struct LatHist {
  const char *name;
  long n = 0, timeout = 0;
  long cnt[MAXW + 2] = {0};          /* out.valid 延迟（harness 构造值） */
  long data_ok = 0, data_bad = 0;    /* out.valid 那拍的数据 vs 参考 */
  long fix2_ok = 0;                  /* 固定第 2 拍（不看 valid）的数据 vs 参考 */
  /* 数据成形（独立观测） */
  long dec = 0;                      /* 可判定：fire 前输出 != 参考 */
  long dec_retry = 0;                /* 其中经扰动前驱重测后才可判定的 */
  long st[MAXW + 2] = {0};           /* 可判定事务的成形拍分布；st[0] 记「从未成形」 */
  long undec = 0;                    /* 扰动后仍不可判定 */
  void add(int l) { if (l >= 1 && l <= MAXW) cnt[l]++; else timeout++; n++; }
  int unique_lat() const {
    int u = -1, k = 0;
    for (int i = 0; i <= MAXW; i++) if (cnt[i]) { u = i; k++; }
    return (k == 1 && !timeout) ? u : -1;
  }
  int unique_settle() const {
    int u = -1, k = 0;
    for (int i = 0; i <= MAXW; i++) if (st[i]) { u = i; k++; }
    return k == 1 ? u : -1;
  }
};

static void print_hist(const LatHist &h) {
  printf("  %-10s  事务=%-5ld\n", h.name, h.n);
  printf("      [平台构造] out.valid 延迟: ");
  for (int i = 0; i <= MAXW; i++) if (h.cnt[i]) printf("%d拍×%ld ", i, h.cnt[i]);
  if (h.timeout) printf("timeout×%ld ", h.timeout);
  printf("（harness 寄存器链长 = VimacCfg.latency，按构造成立，非独立证据）\n");
  printf("      [独立观测] 固定第 2 拍数据与参考一致: %ld/%ld", h.fix2_ok, h.n);
  if (h.data_ok || h.data_bad)
    printf("；out.valid 那拍数据比对 ok=%ld bad=%ld", h.data_ok, h.data_bad);
  printf("\n");
  printf("      [独立观测] 数据成形拍（仅统计可判定事务）: 可判定 %ld/%ld（其中经扰动前驱重测 %ld）；",
         h.dec, h.n, h.dec_retry);
  for (int i = 1; i <= MAXW; i++) if (h.st[i]) printf("第%d拍成形×%ld ", i, h.st[i]);
  if (h.st[0]) printf("未成形×%ld ", h.st[0]);
  printf("；不可判定 %ld\n", h.undec);
  printf("      => 第 1 拍未成形 %ld/%ld 笔（数据通路深度 >= 2 的直接证据）；"
         "第 2 拍数据正确 %ld/%ld 笔（深度 <= 2）\n",
         h.dec - h.st[1], h.dec, h.fix2_ok, h.n);
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

/* vmul.vv / vmacc.vv（SEW=8、LMUL=1、vl=16、vm=1、vta=1：16 个元素全为 body）
 * 乘积只取低 8 位，与有/无符号无关。 */
static void vmul_model(const vreg128_t *vs2, const vreg128_t *vs1, vreg128_t *out) {
  for (int i = 0; i < 16; i++) out->v[i] = (uint8_t)(vs2->v[i] * vs1->v[i]);
}
static void vmacc_model(const vreg128_t *vs2, const vreg128_t *vs1,
                        const vreg128_t *vd, vreg128_t *out) {
  for (int i = 0; i < 16; i++) out->v[i] = (uint8_t)(vd->v[i] + vs1->v[i] * vs2->v[i]);
}

/* 扰动前驱：与目标同一 fuOpType，但操作数取反/异或，使输出端残留值大概率不同于目标结果 */
static Stim scrub_of(const Stim &s, int k) {
  Stim z = s;
  static const uint8_t pat[4] = { 0xff, 0x5a, 0xa5, 0x3c };
  for (int b = 0; b < 16; b++) {
    z.vs1.v[b]   = (uint8_t)(s.vs1.v[b]   ^ pat[k & 3]);
    z.vs2.v[b]   = (uint8_t)(s.vs2.v[b]   ^ pat[(k + 1) & 3]);
    z.vd_in.v[b] = (uint8_t)(s.vd_in.v[b] ^ pat[(k + 2) & 3] ^ (uint8_t)b);
    z.v0.v[b]    = 0xff;
  }
  z.vstart = 0; z.vm = 1;
  z.vl = (s.fuOpType == FUOP_VDOT4A) ? 4 : 16;
  return z;
}

/* 一笔事务的完整测量。ref = 参考结果；返回 out.valid 延迟。
 * 若 fire 前输出已等于 ref（不可判定），换扰动前驱重测，最多 4 次。 */
static int measure(LatHist &h, const Stim &s, const vreg128_t &ref, int *exit_code) {
  vreg128_t seen[MAXW + 1];
  int lat = issue(s, seen);
  h.add(lat);
  if (lat >= 1) {
    if (eq128(&seen[lat], &ref)) h.data_ok++;
    else { h.data_bad++; *exit_code = 1; }
  } else {
    *exit_code = 1;
  }
  if (eq128(&seen[2], &ref)) h.fix2_ok++;

  if (!eq128(&seen[0], &ref)) {
    int f = first_match(seen, &ref);
    h.dec++; h.st[f < 0 ? 0 : f]++;
    return lat;
  }
  for (int k = 0; k < 4; k++) {
    vreg128_t sz[MAXW + 1], s2[MAXW + 1];
    issue(scrub_of(s, k), sz);
    issue(s, s2);
    if (!eq128(&s2[0], &ref)) {
      int f = first_match(s2, &ref);
      h.dec++; h.dec_retry++; h.st[f < 0 ? 0 : f]++;
      return lat;
    }
  }
  h.undec++;
  return lat;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  long nops = 32;
  if (const char *e = getenv("VIMACU_LAT_OPS")) nops = strtol(e, nullptr, 0);
  if (nops < 8) nops = 8;

  dut = new VVIMacUHarness;
  do_reset();

  printf("=====================================================================\n");
  printf(" VIMacU 功能单元延迟测量\n");
  printf(" DUT  : VIMacUHarness -> VIMacU(VimacCfg)  （真正被集成进香山的那一个）\n");
  printf(" 声明值: FuConfig.scala:563  VimacCfg.latency = CertainLatency(2)\n");
  printf(" 注意 : out.valid 由 harness 按 VimacCfg.latency 搭的寄存器链产生，\n");
  printf("        其「2 拍」是平台构造值；独立证据是下面的「数据成形拍」\n");
  printf("        （fire 后第 0..%d 拍逐拍采 io_vd，与参考模型比较，不读 out.valid）。\n", MAXW);
  printf("        成形拍是下界型证据：fire 前输出已等于参考的事务不可判定，\n");
  printf("        先换扰动前驱重测，仍不可判定的单独计数。\n");
  printf("=====================================================================\n\n");

  int exit_code = 0;
  LatHist hv[3] = {};
  hv[0].name = "vdot";  hv[1].name = "vdotacc"; hv[2].name = "vdot4a";

  /* ---------- (1) vdot 指令族：定向语料 + 数据逐位比对 ---------- */
  printf("--- (1) vdot 指令族（激励来自共享语料，参考 = tests/golden/vdot_ref.c）---\n");
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
      measure(hv[k], s, ref, &exit_code);
    }
    fclose(f);
  }
  for (int k = 0; k < 3; k++) print_hist(hv[k]);

  /* ---------- (2) 上游既有 vimac 指令 ---------- */
  printf("\n--- (2) 上游既有 vimac 指令（每条 %ld 笔随机激励；参考 = 本文件内逐元素 C 模型）---\n", nops);
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
      vreg128_t ref;
      if (olds[oi].op == FUOP_VMUL) {
        vmul_model(&s.vs2, &s.vs1, &ref);
      } else if (olds[oi].op == FUOP_VMACC) {
        vmacc_model(&s.vs2, &s.vs1, &s.vd_in, &ref);
      } else {
        /* vwmul：uopIdx=0 对应低半还是高半不预设，先探一次再选参考 */
        vreg128_t mlo, mhi, probe[MAXW + 1];
        vwmul_model(&s.vs2, &s.vs1, 0, &mlo);
        vwmul_model(&s.vs2, &s.vs1, 8, &mhi);
        issue(s, probe);
        if      (eq128(&probe[2], &mlo)) { wmul_lo++;   ref = mlo; }
        else if (eq128(&probe[2], &mhi)) { wmul_hi++;   ref = mhi; }
        else                             { wmul_none++; ref = mlo; }
        /* 让正式测量的前驱不是同一笔：插一笔扰动事务 */
        issue(scrub_of(s, 0), probe);
      }
      measure(h, s, ref, &exit_code);
    }
    print_hist(h);
    if (olds[oi].op == FUOP_VWMUL) {
      printf("              vwmul 参考模型选择： 命中「元素0..7 的 16 位积」%ld 笔，"
             "命中「元素8..15」%ld 笔，两者皆不命中 %ld 笔\n",
             wmul_lo, wmul_hi, wmul_none);
    }
    if (h.unique_lat() < 0) exit_code = 1;
  }

  /* ---------- 汇总 ---------- */
  printf("\n--- 汇总（供 bench/collect_results.py 使用）---\n");
  printf("CSVHDR,instruction,fu,outvalid_latency_cycles(harness构造),data_settle_cycles,transactions,data_checked\n");
  printf("CSVHDR2,instruction,settle_decidable,settle_decidable_after_scrub,not_settled_at_1,settled_at_1,undecidable,data_ok_at_fixed_cycle2\n");
  const char *nm[3] = { "vdot.vv", "vdotacc.vv", "vdot4a.vv" };
  const LatHist *all[6] = { &hv[0], &hv[1], &hv[2], &ho[0], &ho[1], &ho[2] };
  for (int k = 0; k < 6; k++) {
    const LatHist &h = *all[k];
    const char *name = (k < 3) ? nm[k] : h.name;
    printf("CSVROW,%s,VIMacU,%d,%d,%ld,%ld\n", name, h.unique_lat(), h.unique_settle(),
           h.n, h.data_ok);
    printf("CSVSETTLE,%s,%ld,%ld,%ld,%ld,%ld,%ld\n", name, h.dec, h.dec_retry,
           h.dec - h.st[1], h.st[1], h.undec, h.fix2_ok);
  }
  printf("\nRESULT: %s\n", exit_code == 0 ? "PASS" : "FAIL");
  return exit_code;
}
