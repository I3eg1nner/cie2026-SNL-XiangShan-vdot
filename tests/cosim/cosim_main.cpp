// =============================================================================
// cosim_main.cpp —— NEMU <-> RTL 逐指令锁步协同仿真驱动（赛题阶段三 3.1.2 / P6）
//
//   REF 侧 = 真实的 NEMU difftest 参考共享库 riscv64-nemu-interpreter-so，
//            经 dlopen + difftest 标准 C API 驱动（见 ref_nemu.h）。
//            每条激励都让 NEMU **真正取指译码执行一条 vdot 机器指令**，
//            参考结果来自 .so 内部的 src/isa/riscv64/instr/rvv/vdot.c，
//            本程序不含任何 vdot 语义实现。
//
//   DUT 侧 = 两个 Verilated 的香山 RTL 模块（均由 work/XiangShan-cosim 精化）：
//            * VDotTop    —— vdot 功能单元数据通路（值比对）
//            * VdotDecodeProbe —— 香山 DecodeUnit + VecExceptionGen 串接探针
//                                 （非法指令判定比对，接线见 VdotDecodeProbe.scala）
//
//   每条激励的锁步流程（与全核 difftest 的 Difftest::step() 同构）：
//     1. 组装架构状态 -> difftest_regcpy(DUT_TO_REF)
//     2. 把 32 位 vdot 指令写进 REF 的 guest 内存 -> difftest_memcpy(TO_REF)
//     3. difftest_exec(1) x2                  （fence.i + 被测指令，REF 真正执行）
//     4. difftest_regcpy(REF_TO_DUT)          （读回全部架构状态）
//     5. 同一条激励喂给 DecodeUnit / VDotTop，比对非法标志与 vd
// =============================================================================
#include "ref_nemu.h"

#include "VDotTopDut.h"
#include "DecodeProbeDut.h"
#include <verilated.h>

#include <algorithm>
#include <cinttypes>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <random>
#include <sstream>
#include <string>
#include <vector>

using namespace cosim;

// -----------------------------------------------------------------------------
// 常量
// -----------------------------------------------------------------------------
static const uint64_t GUEST_PC    = 0x80000000ull;  // fence.i 放在 CONFIG_MBASE 开头
static const uint64_t GUEST_PC_OP = 0x80000004ull;  // 被测的 vdot 指令
static const uint64_t GUEST_MTVEC = 0x80001000ull;  // 异常入口（direct 模式）
static const uint32_t INSTR_FENCE_I = 0x0000100fu;  // Zifencei: fence.i

// NEMU 的解释器对「已译码指令」按 PC 做缓存
// （work/NEMU/src/cpu/cpu-exec.c:784-793 `tcache_lookup_instr(cpu.pc)`），
// 而 `decode_OP_V` 会把当时的 `vtype->vsew` 固化进 `s->v_width`
// （work/NEMU/src/isa/riscv64/instr/rvv/decode.h:41）。
// 本协同仿真在同一个 PC 上反复改写指令和 vtype，因此必须像真实软件那样
// 先执行一条 `fence.i` 让 NEMU 作废译码缓存
// （work/NEMU/src/isa/riscv64/instr/rvi/fence.h:22 `set_sys_state_flag(SYS_STATE_FLUSH_TCACHE)`），
// 再执行被测指令。于是每条激励固定两次 difftest_exec(1)。

// VimacType 9 位编码（yunsuan/src/main/scala/yunsuan/package.scala）
// [8:7]=pad(1/2/3) [6]=vs2Sign [5]=vs1Sign [4]=vdSign [3]=format(VVV=0) [2:0]=VimacOpcode.vdot(b111)
static const uint16_t FUOP_VDOT    = 0x0E7;
static const uint16_t FUOP_VDOTACC = 0x177;
static const uint16_t FUOP_VDOT4A  = 0x1F7;

// OPIVV funct6（nemu/patch 与 rtl 两侧一致）
static const uint32_t F6_VDOT    = 0x39; // 0b111001
static const uint32_t F6_VDOTACC = 0x3a; // 0b111010
static const uint32_t F6_VDOT4A  = 0x3b; // 0b111011

// 默认寄存器编号：vd=v1, vs1=v2, vs2=v3, 掩码恒为 v0（刻意取非 2 的幂对齐，
// 以便在 LMUL>1 时触发香山的寄存器组对齐检查）。
// 「lmul-aligned」诊断 suite 会改用 v8/v16/v24，使对齐检查不再生效，
// 从而把「香山究竟有没有针对 vdot 的 LMUL 判定」这件事单独暴露出来。
static const uint32_t RN_VD = 1, RN_VS1 = 2, RN_VS2 = 3;

enum OpKind { OP_VDOT = 0, OP_VDOTACC = 1, OP_VDOT4A = 2 };
static const char *OP_NAME[3] = {"vdot", "vdotacc", "vdot4a"};

struct U128 {
  uint64_t lo = 0, hi = 0;
  bool operator==(const U128 &o) const { return lo == o.lo && hi == o.hi; }
  bool operator!=(const U128 &o) const { return !(*this == o); }
};

struct Stim {
  int op = OP_VDOT;
  int vsew_bits = 8;   // 8/16/32/64
  int vstart = 0;
  int vl = 16;
  int vm = 1;          // 1 = unmasked（与指令编码的 vm 位一致）
  int vta = 0, vma = 0;
  int vlmul_code = 0;  // 0 = LMUL=1
  uint32_t rn_vd = RN_VD, rn_vs1 = RN_VS1, rn_vs2 = RN_VS2;
  U128 vs1, vs2, vd_in, v0;
  std::string origin;  // 来源（文件:行号 或 random#N）
};

// -----------------------------------------------------------------------------
// 小工具
// -----------------------------------------------------------------------------
static FILE *g_log = nullptr;
static void say(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vprintf(fmt, ap);
  va_end(ap);
  if (g_log) {
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
  }
  fflush(stdout);
  if (g_log) fflush(g_log);
}

static int sew_code(int bits) {
  switch (bits) {
    case 8: return 0;
    case 16: return 1;
    case 32: return 2;
    default: return 3;
  }
}

// 语料的 hex 布局：32 个 hex 字符，v[0] 在最左边 => 第 i 个字节 = hex[2i..2i+1]
static bool parse_hex128(const std::string &s, U128 *out) {
  if (s.size() != 32) return false;
  uint8_t b[16];
  for (int i = 0; i < 16; i++) {
    auto hv = [](char c) -> int {
      if (c >= '0' && c <= '9') return c - '0';
      if (c >= 'a' && c <= 'f') return c - 'a' + 10;
      if (c >= 'A' && c <= 'F') return c - 'A' + 10;
      return -1;
    };
    int h = hv(s[2 * i]), l = hv(s[2 * i + 1]);
    if (h < 0 || l < 0) return false;
    b[i] = (uint8_t)((h << 4) | l);
  }
  U128 r;
  r.lo = 0;
  r.hi = 0;
  for (int i = 0; i < 8; i++) r.lo |= (uint64_t)b[i] << (8 * i);
  for (int i = 0; i < 8; i++) r.hi |= (uint64_t)b[8 + i] << (8 * i);
  *out = r;
  return true;
}

static std::string hex128(const U128 &v) {
  char buf[33];
  for (int i = 0; i < 8; i++) snprintf(buf + 2 * i, 3, "%02x", (unsigned)((v.lo >> (8 * i)) & 0xff));
  for (int i = 0; i < 8; i++) snprintf(buf + 16 + 2 * i, 3, "%02x", (unsigned)((v.hi >> (8 * i)) & 0xff));
  return std::string(buf, 32);
}

static uint32_t encode_instr(const Stim &s) {
  uint32_t f6 = (s.op == OP_VDOT) ? F6_VDOT : (s.op == OP_VDOTACC) ? F6_VDOTACC : F6_VDOT4A;
  return (f6 << 26) | ((uint32_t)(s.vm & 1) << 25) | (s.rn_vs2 << 20) | (s.rn_vs1 << 15) |
         (0u << 12) | (s.rn_vd << 7) | 0x57u;
}

// -----------------------------------------------------------------------------
// REF 侧：组装状态 -> memcpy 指令 -> exec -> 读回状态
// -----------------------------------------------------------------------------
struct RefResult {
  bool trapped = false;   // NEMU 是否抛出了异常
  uint64_t mcause = 0;
  U128 vd;                // 未抛异常时的 vr[RN_VD]
  uint64_t vstart_after = 0, vl_after = 0, vtype_after = 0;
};

static void ref_run(NemuRefProxy &ref, const Stim &s, RefResult *out) {
  RefRegState st;
  memset(&st, 0, sizeof(st));

  // M 模式；mstatus: MPP=3, FS=Initial, VS=Dirty, SXL=UXL=2(64bit)
  st.mode = 3;
  st.mstatus = (2ull << 34) | (2ull << 32) | (3ull << 11) | (1ull << 13) | (3ull << 9);
  st.mtvec = GUEST_MTVEC;   // direct 模式
  st.stvec = GUEST_MTVEC;
  st.pc = GUEST_PC;
  st.satp = 0;              // bare

  st.vlenb = 16;            // VLEN=128
  st.vstart = (uint64_t)s.vstart;
  st.vl = (uint64_t)s.vl;
  st.vtype = ((uint64_t)(s.vma & 1) << 7) | ((uint64_t)(s.vta & 1) << 6) |
             ((uint64_t)sew_code(s.vsew_bits) << 3) | (uint64_t)(s.vlmul_code & 7);
  st.vcsr = 0;

  st.vr[0][0] = s.v0.lo;           st.vr[0][1] = s.v0.hi;
  st.vr[s.rn_vs1][0] = s.vs1.lo;   st.vr[s.rn_vs1][1] = s.vs1.hi;
  st.vr[s.rn_vs2][0] = s.vs2.lo;   st.vr[s.rn_vs2][1] = s.vs2.hi;
  st.vr[s.rn_vd][0] = s.vd_in.lo;  st.vr[s.rn_vd][1] = s.vd_in.hi;

  uint32_t words[2] = {INSTR_FENCE_I, encode_instr(s)};
  ref.mem_to_ref(GUEST_PC, words, sizeof(words));
  ref.regs_to_ref(&st);
  // 共享库形态下 cpu_exec() 断言每次只能走 1 条指令
  // （work/NEMU/src/cpu/cpu-exec.c:884 `assert(ref_is_fast() || n <= 1)`），
  // 因此分两次调用：① fence.i 置起 tcache 作废请求；
  // ② 下一次 execute() 在循环顶部服务该请求后再译码执行 vdot。
  ref.exec(1);              // ① fence.i
  ref.exec(1);              // ② 被测的 vdot 指令
  ref.regs_from_ref(&st);

  out->trapped = (st.pc != GUEST_PC_OP + 4);
  out->mcause = st.mcause;
  out->vd.lo = st.vr[s.rn_vd][0];
  out->vd.hi = st.vr[s.rn_vd][1];
  out->vstart_after = st.vstart;
  out->vl_after = st.vl;
  out->vtype_after = st.vtype;
}

// -----------------------------------------------------------------------------
// DUT 侧
// -----------------------------------------------------------------------------
static void wide_set(uint32_t *w, const U128 &v) {
  w[0] = (uint32_t)(v.lo & 0xffffffffu);
  w[1] = (uint32_t)(v.lo >> 32);
  w[2] = (uint32_t)(v.hi & 0xffffffffu);
  w[3] = (uint32_t)(v.hi >> 32);
}
static U128 wide_get(const uint32_t *w) {
  U128 v;
  v.lo = (uint64_t)w[0] | ((uint64_t)w[1] << 32);
  v.hi = (uint64_t)w[2] | ((uint64_t)w[3] << 32);
  return v;
}

class DutVDot {
public:
  DutVDot() {
    top_ = new VDotTopDut();
    top_->clock = 0;
    top_->reset = 1;
    top_->io_fire = 0;
    for (int i = 0; i < 6; i++) tick();
    top_->reset = 0;
    for (int i = 0; i < 2; i++) tick();
  }
  ~DutVDot() {
    top_->final();
    delete top_;
  }

  U128 run(const Stim &s) {
    top_->io_fuOpType =
        (s.op == OP_VDOT) ? FUOP_VDOT : (s.op == OP_VDOTACC) ? FUOP_VDOTACC : FUOP_VDOT4A;
    top_->io_info_vm = (uint8_t)(s.vm & 1);
    top_->io_info_ma = (uint8_t)(s.vma & 1);
    top_->io_info_ta = (uint8_t)(s.vta & 1);
    top_->io_info_vlmul = (uint8_t)(s.vlmul_code & 7);
    top_->io_info_vl = (uint8_t)s.vl;
    top_->io_info_vstart = (uint8_t)(s.vstart & 0x7f);
    top_->io_info_uopIdx = 0;
    top_->io_info_vxrm = 0;
    wide_set(top_->io_vs1.data(), s.vs1);
    wide_set(top_->io_vs2.data(), s.vs2);
    wide_set(top_->io_oldVd.data(), s.vd_in);
    wide_set(top_->io_mask.data(), s.v0);

    top_->io_fire = 1;
    tick();             // posedge #1 : S0 -> S1
    top_->io_fire = 0;
    tick();             // posedge #2 : S1 -> S2
    top_->eval();
    U128 vd = wide_get(top_->io_vd.data());
    tick();             // 回到空闲
    return vd;
  }

private:
  void tick() {
    top_->clock = 0;
    top_->eval();
    top_->clock = 1;
    top_->eval();
  }
  VDotTopDut *top_;
};

class DutDecode {
public:
  DutDecode() {
    top_ = new DecodeProbeDut();
    top_->clock = 0;
    top_->reset = 1;
    tick();
    tick();
    top_->reset = 0;
    tick();
  }
  ~DutDecode() {
    top_->final();
    delete top_;
  }

  uint64_t last_fu_type = 0;
  uint32_t last_fu_op = 0;
  bool last_illegal_simple = false;
  bool last_illegal_vec = false;
  bool last_is_complex = false;

  // 返回最终送进 ROB 的 exceptionVec(illegalInstr)
  bool illegal(const Stim &s) {
    top_->io_instr = encode_instr(s);
    top_->io_vtype_illegal = 0;
    top_->io_vtype_vma = (uint8_t)(s.vma & 1);
    top_->io_vtype_vta = (uint8_t)(s.vta & 1);
    top_->io_vtype_vsew = (uint8_t)sew_code(s.vsew_bits);
    top_->io_vtype_vlmul = (uint8_t)(s.vlmul_code & 7);
    top_->io_vstart = (uint8_t)s.vstart;
    top_->eval();
    bool r = top_->io_illegal != 0;
    last_illegal_simple = top_->io_illegalSimple != 0;
    last_illegal_vec = top_->io_illegalVec != 0;
    last_is_complex = top_->io_isComplex != 0;
    last_fu_type = top_->io_fuType;
    last_fu_op = top_->io_fuOpType;
    tick();
    return r;
  }

private:
  void tick() {
    top_->clock = 0;
    top_->eval();
    top_->clock = 1;
    top_->eval();
  }
  DecodeProbeDut *top_;
};

// -----------------------------------------------------------------------------
// 统计
// -----------------------------------------------------------------------------
struct SuiteStat {
  std::string name;
  long attempted = 0;
  long legal_agree = 0;        // 两侧都判合法
  long illegal_agree = 0;      // 两侧都判非法
  long dis_ref_only = 0;       // REF 非法、RTL 合法
  long dis_dut_only = 0;       // RTL 非法、REF 合法
  long value_checked = 0;      // 做了 vd 值比对
  long value_pass = 0;
  long value_fail = 0;
  long skip_value_ref_trap = 0;    // REF 抛异常 -> FU 级不建模异常，跳过值比对
  long skip_value_dut_illegal = 0; // RTL 译码判非法 -> 该指令不会进入 FU，跳过值比对
  std::map<std::string, long> dis_reason;
};

static long g_fail_print_budget = 20;
static long g_dbg_budget = 0;

static void check_one(NemuRefProxy &ref, DutVDot &dut, DutDecode &dec, const Stim &s,
                      SuiteStat *st) {
  st->attempted++;

  RefResult rr;
  ref_run(ref, s, &rr);
  bool dut_illegal = dec.illegal(s);

  if (g_dbg_budget > 0) {
    g_dbg_budget--;
    say("  [DBG] %s instr=%08x sew=%d vstart=%d vl=%d vm=%d lmul=%d | "
        "REF trap=%d mcause=%" PRIu64 " | DUT illegal=%d (simple=%d vec=%d complex=%d) "
        "fuType=0x%" PRIx64 " fuOpType=0x%x\n",
        s.origin.c_str(), encode_instr(s), s.vsew_bits, s.vstart, s.vl, s.vm, s.vlmul_code,
        (int)rr.trapped, rr.mcause, (int)dut_illegal, (int)dec.last_illegal_simple,
        (int)dec.last_illegal_vec, (int)dec.last_is_complex, dec.last_fu_type, dec.last_fu_op);
  }

  if (rr.trapped && dut_illegal) {
    st->illegal_agree++;
  } else if (!rr.trapped && !dut_illegal) {
    st->legal_agree++;
  } else if (rr.trapped && !dut_illegal) {
    st->dis_ref_only++;
    char k[256];
    snprintf(k, sizeof(k), "REF非法/RTL合法 op=%s sew=%d vstart=%d lmul=%d vd=v%u",
             OP_NAME[s.op], s.vsew_bits, s.vstart, s.vlmul_code, s.rn_vd);
    st->dis_reason[k]++;
  } else {
    st->dis_dut_only++;
    char k[256];
    snprintf(k, sizeof(k), "RTL非法/REF合法 op=%s sew=%d vstart=%d lmul=%d vd=v%u",
             OP_NAME[s.op], s.vsew_bits, s.vstart, s.vlmul_code, s.rn_vd);
    st->dis_reason[k]++;
  }

  if (rr.trapped) {
    st->skip_value_ref_trap++;
    return;
  }
  if (dut_illegal) {
    st->skip_value_dut_illegal++;
    return;
  }

  U128 dv = dut.run(s);
  st->value_checked++;
  if (dv == rr.vd) {
    st->value_pass++;
  } else {
    st->value_fail++;
    if (g_fail_print_budget-- > 0) {
      say("  [MISMATCH] %s  op=%s sew=%d vstart=%d vl=%d vm=%d vta=%d vma=%d lmul=%d\n",
          s.origin.c_str(), OP_NAME[s.op], s.vsew_bits, s.vstart, s.vl, s.vm, s.vta, s.vma,
          s.vlmul_code);
      say("             vs1   = %s\n", hex128(s.vs1).c_str());
      say("             vs2   = %s\n", hex128(s.vs2).c_str());
      say("             oldVd = %s\n", hex128(s.vd_in).c_str());
      say("             v0    = %s\n", hex128(s.v0).c_str());
      say("             REF(NEMU) vd = %s\n", hex128(rr.vd).c_str());
      say("             DUT(RTL)  vd = %s\n", hex128(dv).c_str());
    }
  }
}

// -----------------------------------------------------------------------------
// 语料加载
// -----------------------------------------------------------------------------
static bool load_vectors(const std::string &path, std::vector<Stim> *out) {
  std::ifstream f(path);
  if (!f.good()) return false;
  std::string line;
  long lineno = 0;
  while (std::getline(f, line)) {
    lineno++;
    if (line.empty() || line[0] == '#') continue;
    std::istringstream is(line);
    std::string op, vs1, vs2, vdin, vdexp, v0, status;
    int sew, vstart, vl, vm, vta, vma;
    if (!(is >> op >> sew >> vstart >> vl >> vm >> vta >> vma >> vs1 >> vs2 >> vdin >> vdexp >>
          v0 >> status))
      continue;
    Stim s;
    if (op == "vdot") s.op = OP_VDOT;
    else if (op == "vdotacc") s.op = OP_VDOTACC;
    else if (op == "vdot4a") s.op = OP_VDOT4A;
    else continue;
    s.vsew_bits = sew;
    s.vstart = vstart;
    s.vl = vl;
    s.vm = vm;
    s.vta = vta;
    s.vma = vma;
    s.vlmul_code = 0;  // 共享语料全部为 LMUL=1
    if (!parse_hex128(vs1, &s.vs1) || !parse_hex128(vs2, &s.vs2) ||
        !parse_hex128(vdin, &s.vd_in) || !parse_hex128(v0, &s.v0))
      continue;
    char buf[320];
    snprintf(buf, sizeof(buf), "%s:%ld", path.c_str(), lineno);
    s.origin = buf;
    out->push_back(s);
  }
  return true;
}

// -----------------------------------------------------------------------------
// 随机激励
// -----------------------------------------------------------------------------
static U128 rnd128(std::mt19937_64 &rng) {
  U128 v;
  v.lo = rng();
  v.hi = rng();
  return v;
}

// 架构内可执行激励：LMUL=1、SEW 合法、vstart=0
static Stim gen_random_inscope(std::mt19937_64 &rng, int op, long idx) {
  Stim s;
  s.op = op;
  s.vsew_bits = (op == OP_VDOT4A) ? 32 : 8;
  s.vstart = 0;
  int vlmax = (op == OP_VDOT4A) ? 4 : 16;
  s.vl = (int)(rng() % (uint64_t)(vlmax + 1));
  s.vm = (int)(rng() & 1);
  s.vta = (int)(rng() & 1);
  s.vma = (int)(rng() & 1);
  s.vlmul_code = 0;
  s.vs1 = rnd128(rng);
  s.vs2 = rnd128(rng);
  s.vd_in = rnd128(rng);
  s.v0 = rnd128(rng);
  char buf[64];
  snprintf(buf, sizeof(buf), "random/%s#%ld", OP_NAME[op], idx);
  s.origin = buf;
  return s;
}

// 非法面激励：故意制造 SEW 不匹配 / vstart 越界 / LMUL != 1
static Stim gen_random_illegal(std::mt19937_64 &rng, long idx, int kind) {
  int op = (int)(rng() % 3);
  Stim s = gen_random_inscope(rng, op, idx);
  const char *tag = "";
  switch (kind) {
    case 0: {  // SEW 不匹配
      static const int sews[4] = {8, 16, 32, 64};
      int want = (op == OP_VDOT4A) ? 32 : 8;
      int got;
      do { got = sews[rng() % 4]; } while (got == want);
      s.vsew_bits = got;
      tag = "sewmix";
      break;
    }
    case 1: {  // vstart 非零 / 越界
      int vlmax = (op == OP_VDOT4A) ? 4 : 16;
      s.vstart = (int)(1 + rng() % (uint64_t)(2 * vlmax));
      tag = "vstart";
      break;
    }
    case 2: {  // LMUL != 1（默认寄存器编号 v1/v2/v3，对齐检查会起作用）
      static const int lmuls[6] = {1, 2, 3, 5, 6, 7}; // m2 m4 m8 mf8 mf4 mf2
      s.vlmul_code = lmuls[rng() % 6];
      tag = "lmul";
      break;
    }
    default: {  // LMUL != 1，但寄存器编号对 LMUL=8 也对齐，屏蔽掉对齐检查的副作用
      static const int lmuls[6] = {1, 2, 3, 5, 6, 7};
      s.vlmul_code = lmuls[rng() % 6];
      s.rn_vd = 8;
      s.rn_vs1 = 16;
      s.rn_vs2 = 24;
      tag = "lmul-aligned";
      break;
    }
  }
  char buf[64];
  snprintf(buf, sizeof(buf), "illegal/%s/%s#%ld", tag, OP_NAME[op], idx);
  s.origin = buf;
  return s;
}

// -----------------------------------------------------------------------------
static void print_suite(const SuiteStat &st) {
  say("%-28s attempted=%-7ld 合法一致=%-7ld 非法一致=%-6ld 判定分歧=%-6ld "
      "值比对=%-7ld PASS=%-7ld FAIL=%-5ld 跳过值比对=%ld(REF异常 %ld / RTL非法 %ld)\n",
      st.name.c_str(), st.attempted, st.legal_agree, st.illegal_agree,
      st.dis_ref_only + st.dis_dut_only, st.value_checked, st.value_pass, st.value_fail,
      st.skip_value_ref_trap + st.skip_value_dut_illegal, st.skip_value_ref_trap,
      st.skip_value_dut_illegal);
  for (const auto &kv : st.dis_reason) {
    say("    · 分歧 %6ld 条 : %s\n", kv.second, kv.first.c_str());
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  std::string so_path;
  std::vector<std::string> vec_files;
  long n_random = 10000;      // 每条指令的架构内随机条数
  long n_illegal = 3000;      // 非法面随机条数
  uint64_t seed = 20260324;
  std::string logfile;

  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if (a == "--so" && i + 1 < argc) so_path = argv[++i];
    else if (a == "--vectors" && i + 1 < argc) vec_files.push_back(argv[++i]);
    else if (a == "--random" && i + 1 < argc) n_random = atol(argv[++i]);
    else if (a == "--illegal" && i + 1 < argc) n_illegal = atol(argv[++i]);
    else if (a == "--seed" && i + 1 < argc) seed = strtoull(argv[++i], nullptr, 0);
    else if (a == "--log" && i + 1 < argc) logfile = argv[++i];
    else if (a == "--dbg" && i + 1 < argc) g_dbg_budget = atol(argv[++i]);
  }
  if (so_path.empty()) {
    fprintf(stderr, "usage: %s --so <riscv64-nemu-interpreter-so> [--vectors FILE]... "
                    "[--random N] [--illegal N] [--seed S] [--log FILE]\n", argv[0]);
    return 2;
  }
  if (!logfile.empty()) g_log = fopen(logfile.c_str(), "w");

  say("==============================================================\n");
  say(" NEMU <-> RTL 逐指令锁步协同仿真 (P6 / 赛题 3.1.2)\n");
  say("==============================================================\n");

  NemuRefProxy ref(so_path);
  say("[REF] 共享库          : %s\n", so_path.c_str());
  say("[REF] DIFFTEST_REG_SIZE = %u B（与本进程 RefRegState 一致）\n", ref.reg_size());
  say("[REF] difftest_init() 完成，nemu_state.state=%d\n", ref.state()->state);

  // ---- REF 自检：证明这个 .so 真的实现了 vdot，而不是把未知编码当非法指令 ----
  {
    Stim s;
    s.op = OP_VDOT;
    s.vsew_bits = 8;
    s.vstart = 0;
    s.vl = 16;
    s.vm = 1;
    s.vta = 1;
    s.vma = 0;
    parse_hex128("0102030405060708090a0b0c0d0e0f10", &s.vs1);
    parse_hex128("0102030405060708090a0b0c0d0e0f10", &s.vs2);
    parse_hex128("00000000000000000000000000000000", &s.vd_in);
    parse_hex128("00000000000000000000000000000000", &s.v0);
    s.origin = "selfcheck";
    RefResult rr;
    ref_run(ref, s, &rr);
    uint32_t got = (uint32_t)(rr.vd.lo & 0xffffffffu);
    // 裁定 S-3'：vd[127:32] 必须清零（即使 vta=1 也不写全 1）
    bool upper_zero = (rr.vd.lo >> 32) == 0 && rr.vd.hi == 0;
    say("[REF] 自检 vdot.vv (vs1=vs2=1..16, vl=16, vta=1): trap=%d  vd.u32[0]=0x%08x "
        "(期望 0x%08x = Σ i^2, i=1..16)  vd[127:32]=%s（期望全 0，裁定 S-3'）\n",
        (int)rr.trapped, got, 1496u, upper_zero ? "全 0" : "非 0");
    if (rr.trapped || got != 1496u || !upper_zero) {
      say("[REF] FATAL: 该共享库没有实现 vdot（或语义不符），拒绝继续。\n");
      return 3;
    }
  }

  DutVDot dut;
  DutDecode dec;
  say("[DUT] VDotTop    : Verilated（work/XiangShan-cosim/yunsuan 精化）\n");
  say("[DUT] 译码探针   : Verilated VdotDecodeProbe = DecodeUnit + VecExceptionGen\n");
  say("[STIM] seed=%" PRIu64 "  每指令随机 %ld 条  非法面随机 %ld 条\n\n", seed, n_random,
      n_illegal);

  std::vector<SuiteStat> suites;

  // ---- 1) 定向语料 ----
  for (const auto &vf : vec_files) {
    std::vector<Stim> cases;
    if (!load_vectors(vf, &cases)) {
      say("[WARN] 无法读取语料 %s，跳过\n", vf.c_str());
      continue;
    }
    SuiteStat st;
    size_t slash = vf.find_last_of('/');
    st.name = (slash == std::string::npos) ? vf : vf.substr(slash + 1);
    for (const auto &c : cases) check_one(ref, dut, dec, c, &st);
    suites.push_back(st);
  }

  // ---- 2) 架构内随机（每条指令独立统计）----
  for (int op = 0; op < 3; op++) {
    std::mt19937_64 rng(seed + 1000 * op);
    SuiteStat st;
    st.name = std::string("random:") + OP_NAME[op];
    for (long i = 0; i < n_random; i++) {
      Stim s = gen_random_inscope(rng, op, i);
      check_one(ref, dut, dec, s, &st);
    }
    suites.push_back(st);
  }

  // ---- 3) 非法面随机（三类：SEW 不匹配 / vstart 越界 / LMUL != 1）----
  {
    const char *kind_name[4] = {"illegal:sew-mismatch", "illegal:vstart", "illegal:lmul!=1",
                                "illegal:lmul!=1(对齐寄存器)"};
    for (int kind = 0; kind < 4; kind++) {
      std::mt19937_64 rng(seed + 7000 + kind);
      SuiteStat st;
      st.name = kind_name[kind];
      for (long i = 0; i < n_illegal; i++) {
        Stim s = gen_random_illegal(rng, i, kind);
        check_one(ref, dut, dec, s, &st);
      }
      suites.push_back(st);
    }
  }

  // ---- 汇总 ----
  say("\n------------------------- 分 suite 结果 -------------------------\n");
  SuiteStat total;
  total.name = "TOTAL";
  for (const auto &st : suites) {
    print_suite(st);
    total.attempted += st.attempted;
    total.legal_agree += st.legal_agree;
    total.illegal_agree += st.illegal_agree;
    total.dis_ref_only += st.dis_ref_only;
    total.dis_dut_only += st.dis_dut_only;
    total.value_checked += st.value_checked;
    total.value_pass += st.value_pass;
    total.value_fail += st.value_fail;
    total.skip_value_ref_trap += st.skip_value_ref_trap;
    total.skip_value_dut_illegal += st.skip_value_dut_illegal;
    for (const auto &kv : st.dis_reason) total.dis_reason[kv.first] += kv.second;
  }
  say("-----------------------------------------------------------------\n");
  say("TOTAL  attempted = %ld\n", total.attempted);
  say("  [A] 值比对（REF 与 RTL 都判合法）: 比对 %ld 条, PASS %ld, FAIL %ld\n",
      total.value_checked, total.value_pass, total.value_fail);
  say("  [B] 非法指令判定一致性          : 合法一致 %ld, 非法一致 %ld, 分歧 %ld\n",
      total.legal_agree, total.illegal_agree, total.dis_ref_only + total.dis_dut_only);
  say("      其中 REF 非法/RTL 合法 = %ld,  RTL 非法/REF 合法 = %ld\n", total.dis_ref_only,
      total.dis_dut_only);
  say("  [C] 跳过值比对 %ld 条 : REF 抛异常 %ld（FU 级平台不建模异常）, "
      "RTL 译码判非法 %ld（该指令不会进入 FU）\n",
      total.skip_value_ref_trap + total.skip_value_dut_illegal, total.skip_value_ref_trap,
      total.skip_value_dut_illegal);
  if (!total.dis_reason.empty()) {
    say("  [D] 判定分歧明细：\n");
    for (const auto &kv : total.dis_reason) say("      %7ld 条 : %s\n", kv.second, kv.first.c_str());
  }

  bool ok = (total.value_fail == 0);
  say("\nRESULT(VALUE)   : %s   (值比对失配 %ld 条)\n", ok ? "PASS" : "FAIL", total.value_fail);
  say("RESULT(LEGALITY): %s   (判定分歧 %ld 条)\n",
      (total.dis_ref_only + total.dis_dut_only) == 0 ? "PASS" : "DIVERGENT",
      total.dis_ref_only + total.dis_dut_only);
  if (g_log) fclose(g_log);
  return ok ? 0 : 1;
}
