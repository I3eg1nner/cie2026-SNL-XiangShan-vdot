# =============================================================================
# tests/riscv/vdot —— vdot 指令族在 NEMU 上的一致性测试（裸机 RV64）
#
# 与 tests/riscv/hello 同一套模式：编译参数不写死，而是从 NEMU 当前的构建
# 配置里抽出来（CONFIG_MBASE / CONFIG_UARTLITE_MMIO / VLEN），并用
# check-config 守卫；difftest ref 配置关掉了所有串口设备，抽不到值会立刻失败。
#
# 额外一步：把 tests/vectors/*.txt 打包成 build/corpus.bin，由 corpus.S
# 用 .incbin 嵌进镜像。
#
# 用法：
#   make NEMU_HOME=/work/work/NEMU
#   make run NEMU_HOME=/work/work/NEMU
# =============================================================================

NEMU_HOME   ?= /work/work/NEMU
CROSS       ?= riscv64-linux-gnu-
BUILD       ?= build
VECTORS_DIR ?= ../../vectors

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
           -fno-tree-vectorize -O2 -g -Wall -Wextra -I$(BUILD)
# -no-pie 是必需的：Ubuntu 的 gcc 默认 -pie，产出的 ELF 带 .rela.dyn 动态重定位。
# 对纯 PC 相对的代码没影响，但编译器为 switch 生成的指针表（CSWTCH.*）里是
# **绝对地址**，要靠装载器施加 R_RISCV_RELATIVE 才正确。NEMU 把 objcopy 出来的
# 扁平 bin 原样读进 pmem，不会做任何重定位，于是那些指针全是垃圾 ——
# 表现为 put_str() 拿到野指针后无限输出。必须链接成非 PIE。
LDFLAGS := -nostdlib -nostartfiles -no-pie -Wl,--build-id=none \
           -Wl,-Map,$(BUILD)/vdot_test.map

SRCS    := start.S vdot_test.c corpus.S
EXTRA_DIR   ?= extra_vectors
VECTORS := $(wildcard $(VECTORS_DIR)/*.txt) $(wildcard $(EXTRA_DIR)/*.txt)
GOLDEN_DIR  ?= ../../golden

.PHONY: all clean run run-ref check-config corpus quiet

all: check-config $(BUILD)/vdot_test.bin $(BUILD)/vdot_test.dis $(BUILD)/vdot_test_quiet.bin

quiet: check-config $(BUILD)/vdot_test_quiet.bin

check-config:
	@test -n "$(NEMU_MBASE)"         || { echo "ERROR: 读不到 CONFIG_MBASE，请先执行 make riscv64-xs-kmhv2_defconfig && make (NEMU_HOME=$(NEMU_HOME))"; exit 1; }
	@test -n "$(NEMU_UARTLITE_MMIO)" || { echo "ERROR: 当前 NEMU 配置没有 CONFIG_UARTLITE_MMIO（difftest ref 配置关掉了所有串口设备）。请切回 riscv64-xs-kmhv2_defconfig"; exit 1; }
	@test -n "$(NEMU_VLEN)"          || { echo "ERROR: 读不到 VLEN ($(VREG_H))"; exit 1; }
	@test "$(NEMU_XVDOT)" != "0"     || { echo "ERROR: 当前 NEMU 构建没有 CONFIG_CUSTOM_XVDOT，请先应用 nemu/patch/0001-add-vdot-instruction-family.patch 并重新构建"; exit 1; }
	@echo "NEMU_HOME            = $(NEMU_HOME)"
	@echo "NEMU_COMMIT          = $(NEMU_COMMIT)"
	@echo "CONFIG_MBASE         = $(NEMU_MBASE)"
	@echo "CONFIG_UARTLITE_MMIO = $(NEMU_UARTLITE_MMIO)"
	@echo "CONFIG_CUSTOM_XVDOT  = enabled"
	@echo "VLEN                 = $(NEMU_VLEN)"

corpus: $(BUILD)/corpus.bin

$(BUILD)/corpus.bin: pack_corpus.py $(VECTORS)
	@mkdir -p $(BUILD)
	@echo "PACK $@"
	@python3 pack_corpus.py $(VECTORS_DIR) $@ $(EXTRA_DIR)

# 重新生成补充定向语料（覆盖裁定 S-9）。期望值由参考模型 vdot_cli 现算，
# 本目标需要宿主 cc，平时不必执行——生成结果已随仓库提交。
.PHONY: extra-vectors
extra-vectors:
	@mkdir -p $(EXTRA_DIR)
	cc -std=c11 -O2 -Wall -Wextra -o $(BUILD)/vdot_cli \
	    $(GOLDEN_DIR)/vdot_cli.c $(GOLDEN_DIR)/vdot_ref.c
	python3 gen_extra_vectors.py $(BUILD)/vdot_cli $(EXTRA_DIR)/vstart_range.txt

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

$(BUILD)/vdot_test.ld: vdot.ld.in Makefile
	@mkdir -p $(BUILD)
	@sed 's/@MBASE@/$(NEMU_MBASE)/g' $< > $@
	@echo "GEN  $@"

$(BUILD)/vdot_test.elf: $(SRCS) $(BUILD)/nemu_config.h $(BUILD)/vdot_test.ld $(BUILD)/corpus.bin
	$(CROSS)gcc $(CFLAGS) $(LDFLAGS) -T $(BUILD)/vdot_test.ld -o $@ start.S vdot_test.c corpus.S
	@echo "LD   $@"

$(BUILD)/vdot_test.bin: $(BUILD)/vdot_test.elf
	$(CROSS)objcopy -O binary $< $@
	@echo "BIN  $@  ($$(stat -c %s $@ 2>/dev/null || stat -f %z $@) bytes)"

# 静默变体：不写 UART，结果只通过 nemu_trap 的退出码（= 失败条数）报告。
# 用于在 difftest 参考共享库（riscv64-nemu-interpreter-so）里跑同一套语料，
# 因为 ref 配置把所有串口设备都关掉了。
$(BUILD)/vdot_test_quiet.elf: $(SRCS) $(BUILD)/nemu_config.h $(BUILD)/vdot_test.ld $(BUILD)/corpus.bin
	$(CROSS)gcc $(CFLAGS) -DVDOT_QUIET $(LDFLAGS) -T $(BUILD)/vdot_test.ld -o $@ start.S vdot_test.c corpus.S
	@echo "LD   $@"

$(BUILD)/vdot_test_quiet.bin: $(BUILD)/vdot_test_quiet.elf
	$(CROSS)objcopy -O binary $< $@
	@echo "BIN  $@  ($$(stat -c %s $@ 2>/dev/null || stat -f %z $@) bytes)"

$(BUILD)/vdot_test.dis: $(BUILD)/vdot_test.elf
	$(CROSS)objdump -d -M no-aliases --section=.text --section=.text.init $< > $@
	@echo "DIS  $@"

run: all
	$(NEMU_HOME)/build/riscv64-nemu-interpreter -b \
	    --log=$(BUILD)/nemu-run.log $(BUILD)/vdot_test.bin

# 在 difftest 参考共享库里跑同一套语料（需要先构建 -ref 形态与 ref-so-runner）
run-ref: $(BUILD)/vdot_test_quiet.bin
	$(NEMU_HOME)/tools/ref-so-runner/runner \
	    --so $(NEMU_HOME)/build/riscv64-nemu-interpreter-so \
	    -b $(BUILD)/vdot_test_quiet.bin

clean:
	rm -rf $(BUILD)
