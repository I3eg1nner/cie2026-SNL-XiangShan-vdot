// =============================================================================
// vimacu_tb.cpp —— 直接驱动 VIMacU（真正被集成进香山的功能单元）的 Verilator 测试平台
//
// 为什么需要它
//   L1 的 YunSuan 平台测的是 VDotTop：算术通路（VIMac64b.prod16 + VDotTree + accOperand）
//   与 VIMacU 完全相同，但掩码/尾部成形是另一份手写实现。也就是说
//   「被验证的东西」≠「被集成的东西」（docs/stage2/11_RTL实现说明.md §10 第 1 条）。
//   本测试平台把同一份定向语料直接灌进 VIMacU 本体（经 VIMacUHarness 窄 IO 包装，
//   harness 只做连线、不含任何 vdot 逻辑），从而把这个缺口堵上。
//
// 语义来源
//   与 L1 平台一样 #include tests/golden/vdot_ref.c，不重写任何语义。
//
// 用法
//   ./vimacu_tb <语料文件> [更多语料文件...]
//   退出码 0 = 全部一致；1 = 有失配
// =============================================================================
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

#include "verilated.h"
#include "VVIMacUHarness.h"

/* 语义唯一事实来源（由 scripts/tools/run_vimacu_tb.sh 复制到构建目录）。
   vdot_ref.h 自带 extern "C" 包裹，这里与 L1 平台的 vector_dot.cpp 写法一致，
   整体编进同一个翻译单元，严禁在本文件重写任何语义。 */
#include "vdot_ref.c"

/* VimacType 的 9 位编码（yunsuan/src/main/scala/yunsuan/package.scala:407-409） */
static const uint32_t FUOP_VDOT    = 0x0E7;  // "b01_110_0_111"
static const uint32_t FUOP_VDOTACC = 0x177;  // "b10_111_0_111"
static const uint32_t FUOP_VDOT4A  = 0x1F7;  // "b11_111_0_111"

struct TestCase {
  std::string op;
  int vsew, vstart, vl, vm, vta, vma;
  vreg128_t vs1, vs2, vd_in, vd_exp, v0;
};

static VVIMacUHarness *dut = nullptr;
static uint64_t main_time = 0;

static void eval_low()  { dut->clock = 0; dut->eval(); }
static void eval_high() { dut->clock = 1; dut->eval(); main_time++; }

static void do_reset() {
  dut->reset  = 1;
  dut->io_valid = 0;
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

/* 把一条用例送进 DUT，返回观察到的 vd；返回 false 表示 io_outValid 一直没拉起来 */
static bool run_one(const TestCase &c, vreg128_t *out, int *latency) {
  uint64_t lo, hi;
  dut->io_valid    = 1;
  dut->io_fuOpType = (c.op == "vdot") ? FUOP_VDOT
                   : (c.op == "vdotacc") ? FUOP_VDOTACC : FUOP_VDOT4A;
  dut->io_vsew     = (c.op == "vdot4a") ? 2 : 0;   // e32 / e8
  dut->io_vstart   = (uint8_t)c.vstart;
  dut->io_vl       = (uint8_t)c.vl;
  dut->io_vm       = c.vm;
  dut->io_vta      = c.vta;
  dut->io_vma      = c.vma;
  pack(&c.vs2,   &lo, &hi); dut->io_vs2Lo   = lo; dut->io_vs2Hi   = hi;
  pack(&c.vs1,   &lo, &hi); dut->io_vs1Lo   = lo; dut->io_vs1Hi   = hi;
  pack(&c.vd_in, &lo, &hi); dut->io_oldVdLo = lo; dut->io_oldVdHi = hi;
  pack(&c.v0,    &lo, &hi); dut->io_maskLo  = lo; dut->io_maskHi  = hi;

  eval_low();
  eval_high();                 // 这一拍 fire：输入进入流水线
  dut->io_valid = 0;

  for (int t = 1; t <= 8; t++) {
    eval_low();
    if (dut->io_outValid) {
      unpack(dut->io_vdLo, dut->io_vdHi, out);
      *latency = t;
      eval_high();
      /* 再空转几拍，确保流水线排空，下一条用例从干净状态开始 */
      for (int k = 0; k < 2; k++) { eval_low(); eval_high(); }
      return true;
    }
    eval_high();
  }
  return false;
}

static int parse_line(const char *line, TestCase *c) {
  char op[32], vs1h[72], vs2h[72], vdh[72], vdeh[72], v0h[72], st[32];
  int vsew, vstart, vl, vm, vta, vma;
  int n = sscanf(line, "%31s %d %d %d %d %d %d %71s %71s %71s %71s %71s %31s",
                 op, &vsew, &vstart, &vl, &vm, &vta, &vma,
                 vs1h, vs2h, vdh, vdeh, v0h, st);
  if (n != 13) return -1;
  if (strcmp(st, "OK") != 0) return 1;            // 非 OK：译码级异常，FU 级跳过
  c->op = op; c->vsew = vsew; c->vstart = vstart; c->vl = vl;
  c->vm = vm; c->vta = vta; c->vma = vma;
  if (vdot_hex_parse(vs1h, &c->vs1)  != 0) return -1;
  if (vdot_hex_parse(vs2h, &c->vs2)  != 0) return -1;
  if (vdot_hex_parse(vdh,  &c->vd_in)!= 0) return -1;
  if (vdot_hex_parse(vdeh, &c->vd_exp)!= 0) return -1;
  if (vdot_hex_parse(v0h,  &c->v0)   != 0) return -1;
  return 0;
}

static void print_reg(const char *tag, const vreg128_t *r) {
  char buf[33];
  vdot_hex_format(r, buf);
  printf("  %-14s %s\n", tag, buf);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) { printf("用法: %s <语料文件> [...]\n", argv[0]); return 2; }

  long dump_n = 0;
  const char *envd = getenv("VIMACU_DUMP");
  if (envd) dump_n = strtol(envd, nullptr, 0);

  dut = new VVIMacUHarness;
  do_reset();

  long g_total = 0, g_run = 0, g_pass = 0, g_fail = 0, g_skip = 0, g_bad = 0;
  int  exit_code = 0;

  for (int a = 1; a < argc; a++) {
    FILE *f = fopen(argv[a], "r");
    if (!f) { printf("无法打开 %s\n", argv[a]); return 2; }
    long total = 0, run = 0, pass = 0, fail = 0, skip = 0, bad = 0;
    char line[1024];
    while (fgets(line, sizeof(line), f)) {
      if (line[0] == '#' || line[0] == '\n' || line[0] == '\r') continue;
      TestCase c;
      int r = parse_line(line, &c);
      total++;
      if (r == 1) { skip++; continue; }
      if (r < 0) { bad++; continue; }

      /* 期望值：现场调参考模型（与 L1 平台的 vector_dot.cpp 用同一份 vdot_ref.c、
         同一个 vstart 策略），同时再与语料文件里记录的 vd_expected 交叉校验 */
      vreg128_t ref = c.vd_in;
      int st = vdot_exec(
          (c.op == "vdot") ? VDOT_OP_VDOT : (c.op == "vdotacc") ? VDOT_OP_VDOTACC : VDOT_OP_VDOT4A,
          c.vsew, &ref, &c.vs2, &c.vs1,
          (uint32_t)c.vstart, (uint32_t)c.vl,
          c.vm ? NULL : &c.v0, c.vta, c.vma, VDOT_VSTART_SKIP);
      if (st != VDOT_OK) { bad++; continue; }
      if (memcmp(&ref, &c.vd_exp, sizeof(ref)) != 0) {
        printf("[语料自校验失败] 文件记录的 vd_expected 与参考模型现算结果不一致：\n");
        print_reg("file", &c.vd_exp); print_reg("model", &ref);
        bad++; exit_code = 1; continue;
      }

      vreg128_t got; int lat = 0;
      if (!run_one(c, &got, &lat)) {
        printf("[超时] io_outValid 未拉起： %s", line);
        fail++; exit_code = 1; continue;
      }
      run++;
      if (memcmp(&got, &ref, sizeof(got)) == 0) {
        pass++;
        if (dump_n > 0) {
          printf("---- VIMacU 用例 MATCH （延迟 %d 拍）----\n", lat);
          printf("  op=%s vsew=%d vstart=%d vl=%d vm=%d vta=%d vma=%d\n",
                 c.op.c_str(), c.vsew, c.vstart, c.vl, c.vm, c.vta, c.vma);
          print_reg("vs1", &c.vs1); print_reg("vs2", &c.vs2);
          print_reg("vd_in", &c.vd_in); print_reg("v0", &c.v0);
          print_reg("expected", &ref); print_reg("VIMacU 实测", &got);
          dump_n--;
        }
      } else {
        fail++; exit_code = 1;
        printf("[失配] %s", line);
        printf("  op=%s vsew=%d vstart=%d vl=%d vm=%d vta=%d vma=%d\n",
               c.op.c_str(), c.vsew, c.vstart, c.vl, c.vm, c.vta, c.vma);
        print_reg("vs1", &c.vs1); print_reg("vs2", &c.vs2);
        print_reg("vd_in", &c.vd_in); print_reg("v0", &c.v0);
        print_reg("expected", &ref); print_reg("VIMacU 实测", &got);
        if (fail > 10) { printf("  失配过多，停止打印\n"); }
      }
    }
    fclose(f);
    printf("%-46s 总 %-6ld 执行 %-6ld 通过 %-6ld 失败 %-4ld 跳过 %-4ld 解析/模型异常 %ld\n",
           argv[a], total, run, pass, fail, skip, bad);
    g_total += total; g_run += run; g_pass += pass; g_fail += fail; g_skip += skip; g_bad += bad;
  }

  printf("----------------------------------------------------------------------\n");
  printf("VIMacU 直驱汇总： 总计 %ld 条，执行 %ld 条，通过 %ld 条，失败 %ld 条，跳过 %ld 条，异常 %ld 条\n",
         g_total, g_run, g_pass, g_fail, g_skip, g_bad);
  if (exit_code == 0 && g_fail == 0 && g_bad == 0 && g_run > 0)
    printf("VIMACU-TB: PASS\n");
  else
    printf("VIMACU-TB: FAIL\n");

  dut->final();
  delete dut;
  return exit_code;
}
