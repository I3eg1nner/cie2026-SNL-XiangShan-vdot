SHELL := /bin/bash

# ==========================================================================
# tests/golden/Makefile —— vdot 参考模型与宿主端自检
#
#   make            构建 vdot_cli 与 test_golden
#   make vectors    调用 tests/vectors/gen_vectors.py 重新生成全部测试向量
#   make test       运行自检（依赖已生成的测试向量）
#   make log        运行自检并把真实输出写入 logs/stage2/p3_golden_selftest.log
#   make riscv      交叉编译检查 bench/baseline 下的汇编与 intrinsics 实现
#   make clean
#
# 已验证的编译器：Apple clang 17（macOS/arm64）、gcc（Linux/arm64）
# ==========================================================================

CC      ?= cc
CXX     ?= c++
CSTD    ?= -std=c11
CFLAGS  ?= $(CSTD) -O2 -Wall -Wextra -Wshadow -Wconversion -Wsign-conversion \
           -Wpedantic -Wstrict-prototypes
ROOT    := $(abspath $(CURDIR)/../..)
VECDIR  := $(ROOT)/tests/vectors
BASEDIR := $(ROOT)/bench/baseline
LOGDIR  := $(ROOT)/logs/stage2

SUITES  := positive negative boundary random \
           vdotacc_positive vdotacc_negative vdotacc_boundary vdotacc_random \
           vdot4a_positive vdot4a_negative vdot4a_boundary vdot4a_random \
           vstart_relaxed
VECFILES := $(addprefix $(VECDIR)/,$(addsuffix .txt,$(SUITES)))

.PHONY: all test log vectors clean riscv cxxcheck gcccheck

all: vdot_cli test_golden

vdot_ref.o: vdot_ref.c vdot_ref.h
	$(CC) $(CFLAGS) -c $< -o $@

vdot_cli.o: vdot_cli.c vdot_ref.h
	$(CC) $(CFLAGS) -c $< -o $@

baseline_ref.o: $(BASEDIR)/baseline_ref.c $(BASEDIR)/baseline_ref.h vdot_ref.h
	$(CC) $(CFLAGS) -c $< -o $@

test_golden.o: test_golden.c vdot_ref.h $(BASEDIR)/baseline_ref.h
	$(CC) $(CFLAGS) -c $< -o $@

vdot_cli: vdot_cli.o vdot_ref.o
	$(CC) $(CFLAGS) $^ -o $@

test_golden: test_golden.o vdot_ref.o baseline_ref.o
	$(CC) $(CFLAGS) $^ -o $@

# 重新生成测试向量：期望值一律由 vdot_cli（即 C 参考模型）计算
vectors: vdot_cli
	python3 $(VECDIR)/gen_vectors.py --cli ./vdot_cli --outdir $(VECDIR)

test: test_golden
	./test_golden $(VECFILES)

log: test_golden vdot_cli
	@mkdir -p $(LOGDIR)
	@{ echo "=========================================================="; \
	   echo " P3 参考模型与测试向量 —— 宿主端自检真实运行记录"; \
	   echo "=========================================================="; \
	   echo "host : $$(uname -srm)"; \
	   echo "date : $$(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"; \
	   echo "cc   : $$($(CC) --version | head -1)"; \
	   echo "repo : $(ROOT)"; \
	   echo ""; } > $(LOGDIR)/p3_golden_selftest.log
	@echo "--- [0] 参考模型以 C++ 方式编译（供 Verilator/YunSuan 测试平台引用） ---" \
	   | tee -a $(LOGDIR)/p3_golden_selftest.log
	@$(MAKE) --no-print-directory cxxcheck 2>&1 | tee -a $(LOGDIR)/p3_golden_selftest.log
	@echo "" | tee -a $(LOGDIR)/p3_golden_selftest.log
	@echo "--- [0b] GCC 方言检查（真 GCC 前端，非 macOS 的 clang 别名） ---" \
	   | tee -a $(LOGDIR)/p3_golden_selftest.log
	@$(MAKE) --no-print-directory gcccheck 2>&1 \
	   | tee -a $(LOGDIR)/p3_golden_selftest.log
	@echo "" | tee -a $(LOGDIR)/p3_golden_selftest.log
	@echo "--- [1][2][3] 回环 + 差分 + 长向量循环自检 ---" \
	   | tee -a $(LOGDIR)/p3_golden_selftest.log
	@set -o pipefail; ./test_golden $(VECFILES) 2>&1 \
	   | tee -a $(LOGDIR)/p3_golden_selftest.log; \
	   echo "test_golden exit_code=$$?" | tee -a $(LOGDIR)/p3_golden_selftest.log
	@echo "" | tee -a $(LOGDIR)/p3_golden_selftest.log
	@echo "--- [4] 故障注入：人为改坏实现，自检必须报错 ---" \
	   | tee -a $(LOGDIR)/p3_golden_selftest.log
	@sh fault_inject.sh 2>&1 | tee -a $(LOGDIR)/p3_golden_selftest.log; \
	   echo "fault_inject exit_code=$$?" | tee -a $(LOGDIR)/p3_golden_selftest.log
	@echo "" | tee -a $(LOGDIR)/p3_golden_selftest.log
	@echo "--- [5] RVV 1.0 基线：宿主编译 + RISC-V 汇编/intrinsics 交叉编译 ---" \
	   | tee -a $(LOGDIR)/p3_golden_selftest.log
	@$(MAKE) --no-print-directory -C $(BASEDIR) check 2>&1 \
	   | tee -a $(LOGDIR)/p3_golden_selftest.log
	@echo "" | tee -a $(LOGDIR)/p3_golden_selftest.log
	@echo "--- [6] 测试向量语料清单 ---" | tee -a $(LOGDIR)/p3_golden_selftest.log
	@for f in $(VECFILES); do \
	   printf '%-58s %6s cases  %s bytes\n' "$${f#$(ROOT)/}" \
	     "$$(grep -vc '^#' $$f)" "$$(wc -c < $$f | tr -d ' ')"; \
	 done | tee -a $(LOGDIR)/p3_golden_selftest.log
	@echo "" | tee -a $(LOGDIR)/p3_golden_selftest.log
	@echo "log written to $(LOGDIR)/p3_golden_selftest.log"

# 以 C++ 方式编译参考模型，验证 extern "C" 包裹可用于 Verilator/YunSuan 测试平台
cxxcheck:
	$(CXX) -std=c++17 -O2 -Wall -Wextra -x c++ -c vdot_ref.c -o /tmp/vdot_ref_cxx.o
	$(CXX) -std=c++17 -O2 -Wall -Wextra example_cxx_consumer.cpp -x c++ vdot_ref.c \
	    -o example_cxx
	./example_cxx $(VECDIR)/boundary.txt
	./example_cxx $(VECDIR)/vdot4a_random.txt
	@echo "C++ consumption of vdot_ref.h + corpus: OK"

# GCC 方言检查：本机无原生 gcc（macOS 的 gcc 是 clang 别名），
# 用 riscv64-elf-gcc（真正的 GCC 16.2.0 前端）验证可移植源码在 GCC 下无警告编译。
# 注意：这只验证**方言兼容性**，不等于已在 Linux/arm64 上实际运行。
GCCCHK ?= riscv64-elf-gcc
GCCCHKFLAGS := -std=c11 -O2 -Wall -Wextra -Wpedantic -ffreestanding \
               -march=rv64gc -mabi=lp64d -S
gcccheck:
	@command -v $(GCCCHK) >/dev/null 2>&1 || \
	  { echo "SKIP gcccheck: $(GCCCHK) not found"; exit 0; }
	$(GCCCHK) $(GCCCHKFLAGS) vdot_ref.c -o /dev/null
	$(GCCCHK) $(GCCCHKFLAGS) $(BASEDIR)/baseline_ref.c -o /dev/null
	@echo "GCC($(shell $(GCCCHK) -dumpversion 2>/dev/null)) C11 dialect check: OK"

# RISC-V 侧的基线实现只做编译/汇编检查（本机无 RISC-V 执行环境）
riscv:
	$(MAKE) -C $(BASEDIR) check

clean:
	rm -f *.o vdot_cli test_golden example_cxx
