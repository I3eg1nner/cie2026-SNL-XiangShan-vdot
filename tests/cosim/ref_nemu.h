// =============================================================================
// ref_nemu.h —— NEMU difftest 参考共享库（riscv64-nemu-interpreter-so）的 C++ 门面
//
// 本文件只做两件事：
//   1. 复刻 NEMU 的 difftest 寄存器同步窗口结构体（isa-def.h 中从 gpr 到
//      difftest_state_end 的那一段），字段顺序/条件编译必须与
//      configs/riscv64-xs-kmhv2-ref_defconfig 完全一致；
//      运行期用 .so 导出的 DIFFTEST_REG_SIZE 做硬校验，不一致立即退出。
//   2. 用 dlopen/dlsym 取出 difftest 的标准 C API
//      （difftest_init / difftest_memcpy / difftest_regcpy / difftest_exec ...），
//      与 difftest 框架 C++ 侧 refproxy.cpp 的做法完全相同。
//
// 这里**没有任何 vdot 语义**：参考行为 100% 来自 .so 内部 NEMU 自己编译出来的
// src/isa/riscv64/instr/rvv/vdot.c，本进程只负责送状态、按一次 exec、取状态。
// =============================================================================
#ifndef COSIM_REF_NEMU_H
#define COSIM_REF_NEMU_H

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <string>

namespace cosim {

enum { DIFFTEST_TO_DUT = 0, DIFFTEST_TO_REF = 1 };

enum { NEMU_RUNNING = 0, NEMU_STOP = 1, NEMU_END = 2, NEMU_ABORT = 3, NEMU_QUIT = 4 };

struct NemuState {
  int state;
  uint64_t halt_pc;
  uint32_t halt_ret;
};

// -----------------------------------------------------------------------------
// riscv64_CPU_state 的 difftest 同步窗口
//   对照 work/NEMU/src/isa/riscv64/include/isa-def.h:92-160
//   启用的宏（configs/riscv64-xs-kmhv2-ref_defconfig）：
//     CONFIG_FPU_NONE        未设  -> fpr[32] 存在
//     CONFIG_RVH=y                 -> 虚拟化影子 CSR 存在
//     CONFIG_RVV=y                 -> vr[32] 存在
//     CONFIG_DIFFTEST_CHECK_VCSR=y -> vstart/vxsat/vxrm/vcsr/vl/vtype/vlenb
//     CONFIG_DIFFTEST_CHECK_FCSR=y -> fcsr
//     CONFIG_DIFFTEST_CHECK_SDTRIG=y -> tselect/tdata1/tinfo
//     CONFIG_RV_AME          未设  -> 矩阵扩展字段不存在
// -----------------------------------------------------------------------------
struct RefRegState {
  uint64_t gpr[32];
  uint64_t fpr[32];

  uint64_t mode;
  uint64_t mstatus, sstatus;
  uint64_t mepc, sepc;
  uint64_t mtval, stval;
  uint64_t mtvec, stvec;
  uint64_t mcause, scause;
  uint64_t satp;
  uint64_t mip, mie;
  uint64_t mscratch, sscratch;
  uint64_t mideleg, medeleg;
  uint64_t pc;

  // CONFIG_RVH
  uint64_t v;
  uint64_t mtval2, mtinst, hstatus, hideleg, hedeleg;
  uint64_t hcounteren, htval, htinst, hgatp, vsstatus;
  uint64_t vstvec, vsepc, vscause, vstval, vsatp, vsscratch;

  // CONFIG_RVV: 32 个 128-bit 向量寄存器，vr[i]._64[0] 为低 64 位
  uint64_t vr[32][2];

  // CONFIG_DIFFTEST_CHECK_VCSR
  uint64_t vstart;
  uint64_t vxsat, vxrm, vcsr;
  uint64_t vl, vtype, vlenb;

  // CONFIG_DIFFTEST_CHECK_FCSR
  uint64_t fcsr;

  // CONFIG_DIFFTEST_CHECK_SDTRIG
  uint64_t tselect, tdata1, tinfo;
};

// -----------------------------------------------------------------------------
// NemuRefProxy —— 与 difftest 框架 src/test/csrc/difftest/refproxy.cpp 同构的加载器
// -----------------------------------------------------------------------------
class NemuRefProxy {
public:
  explicit NemuRefProxy(const std::string &so_path) : so_path_(so_path) {
    handle_ = dlopen(so_path.c_str(), RTLD_LAZY | RTLD_DEEPBIND);
    if (handle_ == nullptr) {
      fprintf(stderr, "[REF] dlopen(%s) failed: %s\n", so_path.c_str(), dlerror());
      exit(1);
    }
    init_fn_   = reinterpret_cast<void (*)()>(sym("difftest_init"));
    exec_fn_   = reinterpret_cast<void (*)(uint64_t)>(sym("difftest_exec"));
    regcpy_fn_ = reinterpret_cast<void (*)(void *, bool)>(sym("difftest_regcpy"));
    memcpy_fn_ = reinterpret_cast<void (*)(uint64_t, void *, size_t, bool)>(sym("difftest_memcpy"));
    reg_size_  = reinterpret_cast<const unsigned *>(sym("DIFFTEST_REG_SIZE"));
    nemu_state_ = reinterpret_cast<NemuState *>(sym("nemu_state"));
    close_fn_  = reinterpret_cast<void (*)()>(dlsym(handle_, "difftest_close"));
    // NEMU 只在 CSR 被写过时才把影子 CSR 刷进同步窗口
    // （src/isa/riscv64/difftest/ref.c:135-137 csr_prepare_if_dirty）。
    // 本平台每条激励都重灌状态，必须显式置脏，否则读回的 mcause/mepc 是上一轮的值。
    mark_csr_dirty_fn_ = reinterpret_cast<void (*)()>(dlsym(handle_, "csr_difftest_mark_dirty"));

    if (*reg_size_ != sizeof(RefRegState)) {
      fprintf(stderr,
              "[REF] FATAL: DIFFTEST_REG_SIZE=%u 而本进程的 RefRegState=%zu，"
              "结构体布局与 .so 不一致，拒绝继续。\n",
              *reg_size_, sizeof(RefRegState));
      exit(1);
    }
    init_fn_();
  }

  ~NemuRefProxy() {
    if (close_fn_ != nullptr) close_fn_();
    if (handle_ != nullptr) dlclose(handle_);
  }

  // 把一段字节写进 REF 的 guest 物理内存（difftest 框架用它装载 workload）
  void mem_to_ref(uint64_t gpa, const void *buf, size_t n) {
    memcpy_fn_(gpa, const_cast<void *>(buf), n, DIFFTEST_TO_REF);
  }
  // 把 DUT 侧的架构状态灌进 REF（difftest 框架用它做初始同步 / 失配后重同步）
  void regs_to_ref(RefRegState *st) { regcpy_fn_(st, DIFFTEST_TO_REF); }
  // 把 REF 的架构状态读回来（difftest 框架 RefProxy::sync() 的动作）
  void regs_from_ref(RefRegState *st) {
    if (mark_csr_dirty_fn_ != nullptr) mark_csr_dirty_fn_();
    regcpy_fn_(st, DIFFTEST_TO_DUT);
  }
  // 让 REF 真正执行 n 条指令（difftest 框架 Difftest::step() 里的 ref_exec(1)）
  void exec(uint64_t n) { exec_fn_(n); }

  const std::string &so_path() const { return so_path_; }
  unsigned reg_size() const { return *reg_size_; }
  const NemuState *state() const { return nemu_state_; }

private:
  void *sym(const char *name) {
    dlerror();
    void *p = dlsym(handle_, name);
    const char *err = dlerror();
    if (err != nullptr || p == nullptr) {
      fprintf(stderr, "[REF] dlsym(%s) failed: %s\n", name, err ? err : "null");
      exit(1);
    }
    return p;
  }

  std::string so_path_;
  void *handle_ = nullptr;
  void (*init_fn_)() = nullptr;
  void (*exec_fn_)(uint64_t) = nullptr;
  void (*regcpy_fn_)(void *, bool) = nullptr;
  void (*memcpy_fn_)(uint64_t, void *, size_t, bool) = nullptr;
  void (*close_fn_)() = nullptr;
  void (*mark_csr_dirty_fn_)() = nullptr;
  const unsigned *reg_size_ = nullptr;
  NemuState *nemu_state_ = nullptr;
};

} // namespace cosim

#endif // COSIM_REF_NEMU_H
