# =============================================================================
# tests/riscv/baseline —— RVV 1.0 基线序列与 vdot 指令族在 NEMU 上的等价性验证
#                          （赛题阶段三 3.2）
#
# 与 tests/riscv/vdot 同一套模式：编译参数不写死，而是从 NEMU 当前的构建配置里
# 抽出来（CONFIG_MBASE / CONFIG_UARTLITE_MMIO / VLEN），并用 check-config 守卫。
#
# 与 tests/riscv/vdot 的两点不同：
#   1. 额外链接交付件 bench/baseline/baseline_rvv.S（长向量循环 kernel 本体，
#      不是为测试另写的副本）；
#   2. 语料打包直接复用 ../vdot/pack_corpus.py，保证两套测试跑的是同一批用例。
#
# 用法：
#   make NEMU_HOME=<work>/NEMU [CROSS=<前缀>] [BUILD=<构建目录>]
#   make run NEMU_HOME=<work>/NEMU
# （scripts/40_run_bench.sh 会自动传入这些变量）
# =============================================================================

NEMU_HOME   ?= ../../../work/NEMU
CROSS       ?= riscv64-linux-gnu-
BUILD       ?= build
VECTORS_DIR ?= ../../vectors
VDOT_DIR    ?= ../vdot
BASELINE_S  ?= ../../../bench/baseline/baseline_rvv.S

AUTOCONF := $(NEMU_HOME)/include/generated/autoconf.h
VREG_H   := $(NEMU_HOME)/src/isa/riscv64/instr/rvv/vreg.h

NEMU_DEFCONFIG ?= riscv64-xs-kmhv2_defconfig
NEMU_COMMIT    := $(shell git -C $(NEMU_HOME) rev-parse --short=12 HEAD 2>/dev/null || echo unknown)

NEMU_MBASE         := $(shell grep -E '^\#define CONFIG_MBASE[ \t]' $(AUTOCONF) 2>/dev/null | awk '{print $$3}')
NEMU_UARTLITE_MMIO := $(shell grep -E '^\#define CONFIG_UARTLITE_MMIO[ \t]' $(AUTOCONF) 2>/dev/null | awk '{print $$3}')
NEMU_VLEN          := $(shell grep -E '^\#define VLEN[ \t]' $(VREG_H) 2>/dev/null | awk '{print $$3}')
NEMU_XVDOT         := $(shell grep -cE '^\#define CONFIG_CUSTOM_XVDOT[ \t]' $(AUTOCONF) 2>/dev/null || echo 0)

CFLAGS  := -march=rv64gcv_zve64x -mabi=lp64d -mcmodel=medany \
           -ffreestanding -nostdlib -nostartfiles -fno-builtin -fno-pic \
           -fno-tree-vectorize -O2 -g -Wall -Wextra -I$(BUILD) \
           -DCORPUS_BIN='"$(abspath $(BUILD))/corpus.bin"'
LDFLAGS := -nostdlib -nostartfiles -no-pie -Wl,--build-id=none \
           -Wl,-Map,$(BUILD)/baseline_test.map

SRCS    := $(VDOT_DIR)/start.S baseline_test.c corpus.S $(BASELINE_S)
EXTRA_DIR   ?= $(VDOT_DIR)/extra_vectors
VECTORS := $(wildcard $(VECTORS_DIR)/*.txt) $(wildcard $(EXTRA_DIR)/*.txt)

.PHONY: all clean run check-config corpus

all: check-config $(BUILD)/baseline_test.bin $(BUILD)/baseline_test.dis

check-config:
	@test -n "$(NEMU_MBASE)"         || { echo "ERROR: 读不到 CONFIG_MBASE，请先执行 make riscv64-xs-kmhv2_defconfig && make (NEMU_HOME=$(NEMU_HOME))"; exit 1; }
	@test -n "$(NEMU_UARTLITE_MMIO)" || { echo "ERROR: 当前 NEMU 配置没有 CONFIG_UARTLITE_MMIO。请切回 riscv64-xs-kmhv2_defconfig"; exit 1; }
	@test -n "$(NEMU_VLEN)"          || { echo "ERROR: 读不到 VLEN ($(VREG_H))"; exit 1; }
	@test "$(NEMU_XVDOT)" != "0"     || { echo "ERROR: 当前 NEMU 构建没有 CONFIG_CUSTOM_XVDOT"; exit 1; }
	@echo "NEMU_HOME            = $(NEMU_HOME)"
	@echo "NEMU_COMMIT          = $(NEMU_COMMIT)"
	@echo "CONFIG_MBASE         = $(NEMU_MBASE)"
	@echo "CONFIG_UARTLITE_MMIO = $(NEMU_UARTLITE_MMIO)"
	@echo "CONFIG_CUSTOM_XVDOT  = enabled"
	@echo "VLEN                 = $(NEMU_VLEN)"

corpus: $(BUILD)/corpus.bin

$(BUILD)/corpus.bin: $(VDOT_DIR)/pack_corpus.py $(VECTORS)
	@mkdir -p $(BUILD)
	@echo "PACK $@"
	@python3 $(VDOT_DIR)/pack_corpus.py $(VECTORS_DIR) $@ $(EXTRA_DIR)

$(BUILD)/nemu_config.h: $(AUTOCONF) $(VREG_H) Makefile
	@mkdir -p $(BUILD)
	@{ \
	  echo '/* 自动生成，请勿手工编辑。来源：'; \
	  echo ' *   $(AUTOCONF)'; \
	  echo ' *   $(VREG_H)'; \
	  echo ' */'; \
	  echo '#ifndef NEMU_CONFIG_H'; \
	  echo '#define NEMU_CONFIG_H'; \
	  echo '#define NEMU_DEFCONFIG      "$(NEMU_DEFCONFIG)"'; \
	  echo '#define NEMU_COMMIT         "$(NEMU_COMMIT)"'; \
	  echo '#define NEMU_MBASE          $(NEMU_MBASE)UL'; \
	  echo '#define NEMU_UARTLITE_MMIO  $(NEMU_UARTLITE_MMIO)UL'; \
	  echo '#define NEMU_VLEN           $(NEMU_VLEN)'; \
	  echo '#endif'; \
	} > $@
	@echo "GEN  $@"

$(BUILD)/baseline_test.ld: $(VDOT_DIR)/vdot.ld.in Makefile
	@mkdir -p $(BUILD)
	@sed 's/@MBASE@/$(NEMU_MBASE)/g' $< > $@
	@echo "GEN  $@"

$(BUILD)/baseline_test.elf: $(SRCS) $(BUILD)/nemu_config.h $(BUILD)/baseline_test.ld $(BUILD)/corpus.bin
	$(CROSS)gcc $(CFLAGS) $(LDFLAGS) -T $(BUILD)/baseline_test.ld -o $@ $(SRCS)
	@echo "LD   $@"

$(BUILD)/baseline_test.bin: $(BUILD)/baseline_test.elf
	$(CROSS)objcopy -O binary $< $@
	@echo "BIN  $@  ($$(stat -c %s $@ 2>/dev/null || stat -f %z $@) bytes)"

$(BUILD)/baseline_test.dis: $(BUILD)/baseline_test.elf
	$(CROSS)objdump -d -M no-aliases --section=.text --section=.text.init $< > $@
	@echo "DIS  $@"

run: all
	$(NEMU_HOME)/build/riscv64-nemu-interpreter -b \
	    --log=$(BUILD)/nemu-run.log $(BUILD)/baseline_test.bin

clean:
	rm -rf $(BUILD)
