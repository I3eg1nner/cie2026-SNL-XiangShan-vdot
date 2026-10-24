SHELL := /bin/bash
# ==========================================================================
# bench/baseline/Makefile
#
#   make check      —— 全部检查：宿主端编译 + RISC-V 汇编/intrinsics 交叉编译
#   make host       —— 只做宿主端（macOS/arm64、Linux/arm64）编译检查
#   make riscv      —— 只做 RISC-V 交叉编译检查（需要 riscv64-elf-gcc）
#   make dis        —— 输出反汇编，用于核对循环体指令条数
#   make clean
#
# 本机无 RISC-V 执行环境，.S / intrinsics 只做**汇编与编译**验证，
# 不声称已在 RISC-V 上实际运行（见 docs/stage2/13 的「证据层级」一节）。
# ==========================================================================

CC        ?= cc
RVCC      ?= riscv64-elf-gcc
RVOBJDUMP ?= riscv64-elf-objdump
RVFLAGS   := -march=rv64gcv -mabi=lp64d -ffreestanding -O2 -Wall -Wextra
HOSTFLAGS := -std=c11 -O2 -Wall -Wextra -Wshadow -Wpedantic -Wstrict-prototypes
OUT       := build

.PHONY: check host riscv dis clean

check: host riscv

host:
	@mkdir -p $(OUT)
	$(CC) $(HOSTFLAGS) -c baseline_ref.c       -o $(OUT)/baseline_ref.host.o
	$(CC) $(HOSTFLAGS) -c baseline_intrinsics.c -o $(OUT)/baseline_intrinsics.host.o
	@echo "host build: OK"

riscv:
	@mkdir -p $(OUT)
	@command -v $(RVCC) >/dev/null 2>&1 || \
	  { echo "SKIP riscv: $(RVCC) not found"; exit 0; }
	$(RVCC) $(RVFLAGS) -c baseline_rvv.S        -o $(OUT)/baseline_rvv.o
	$(RVCC) $(RVFLAGS) -c baseline_intrinsics.c -o $(OUT)/baseline_intrinsics.o
	@echo "--- vdot 自定义指令编码自校验（期望 e61101d7 / ea1101d7 / ee1101d7）---"
	@$(RVOBJDUMP) -s -j .rodata $(OUT)/baseline_rvv.o | sed -n '/Contents/,$$p'
	@echo "riscv build: OK"

dis: riscv
	$(RVOBJDUMP) -d $(OUT)/baseline_rvv.o
	$(RVOBJDUMP) -d $(OUT)/baseline_intrinsics.o

clean:
	rm -rf $(OUT)
