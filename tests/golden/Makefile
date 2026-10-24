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

.PHONY: all test log vectors clean riscv cxxcheck

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

log: test_golden
	@mkdir -p $(LOGDIR)
	@{ echo "### host: $$(uname -srm)"; \
	   echo "### date: $$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; \
	   echo "### cc  : $$($(CC) --version | head -1)"; \
	   echo "### cmd : ./test_golden <13 suites>"; \
	   echo ""; } | tee $(LOGDIR)/p3_golden_selftest.log
	./test_golden $(VECFILES) 2>&1 | tee -a $(LOGDIR)/p3_golden_selftest.log; \
	  echo "exit_code=$${PIPESTATUS[0]}" | tee -a $(LOGDIR)/p3_golden_selftest.log

# 以 C++ 方式编译参考模型，验证 extern "C" 包裹可用于 Verilator/YunSuan 测试平台
cxxcheck:
	c++ -std=c++17 -O2 -Wall -Wextra -x c++ -c vdot_ref.c -o /tmp/vdot_ref_cxx.o
	@echo "C++ compile of vdot_ref.c: OK"

# RISC-V 侧的基线实现只做编译/汇编检查（本机无 RISC-V 执行环境）
riscv:
	$(MAKE) -C $(BASEDIR) check

clean:
	rm -f *.o vdot_cli test_golden
