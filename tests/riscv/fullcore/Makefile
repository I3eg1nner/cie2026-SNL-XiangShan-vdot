# =============================================================================
# tests/riscv/fullcore —— 全核 difftest（香山 MinimalConfig emu <-> NEMU .so）用裸机镜像
#
# 两类镜像：
#   corpus  : 复用 tests/riscv/vdot/ 的一致性测试程序（start.S / vdot_test.c / corpus.S
#             不做任何修改），只是把共享语料切成若干批（slice_corpus.py），
#             每批编成一个镜像，便于在多个 emu 进程上并行运行。
#   dep     : vdot_dep.c + vdot_dep_kernels.S，vdot 与其他向量指令的背靠背依赖测试。
#   perf    : perf_cycles.c + perf_kernels.S + bench/baseline/baseline_rvv.S（交付件原样链接），
#             用 mcycle 实测单次点积、依赖链与长向量循环的周期数（HANDOFF T3）。
#   hello   : tests/riscv/hello/ 的 start.S / hello.c 原样编译，只把 nemu_config.h 中的
#             地址常量换成香山 SoC 的值（与 NEMU riscv64-xs-kmhv2_defconfig 的取值恰好相同：
#             MBASE 0x80000000、UARTLITE 0x40600000、VLEN 128），HOST_IP 由调用者传入。
#
# 与 tests/riscv/vdot/Makefile 的区别：地址常量不从 NEMU 配置里抽取，而是固定为
# 香山 SoC 的实际地址（DRAM 0x80000000；UARTLite 0x40600000，见 XiangShan
# src/main/scala/system/SoC.scala:163）。香山 emu 自带 UARTLite，
# 程序的串口输出直接出现在 emu 标准输出中；difftest 对 MMIO 访问按惯例跳过比对。
#
# 用法：
#   make corpus-full BUILD=<dir>                              # 打包全部语料
#   make corpus-batch BUILD=<dir> NAME=b00 BEGIN=0 END=4000   # 第 b00 批镜像
#   make dep BUILD=<dir> [DEP_ITERS=200] [DEP_SEED=..] [DEP_NAME=dep]  # 依赖测试镜像
#   make wave BUILD=<dir>                                     # 波形抓取用最小程序
#   make perf BUILD=<dir> [PERF_REPS=5]                       # 周期实测（HANDOFF T3）
#   make perf-probe BUILD=<dir>                               # 计时方法对照（裸 csrr vs fence+csrr）
#   make hello BUILD=<dir> HOST_IP=<本机IP>                   # 赛题 1.1 hello 在全核 emu 上运行
# =============================================================================

CROSS       ?= riscv64-unknown-elf-
BUILD       ?= build
VDOT_DIR    := ../vdot
VECTORS_DIR ?= ../../vectors
EXTRA_DIR   ?= $(VDOT_DIR)/extra_vectors
NEMU_HOME   ?= ../../../work/NEMU
NEMU_COMMIT := $(shell git -C $(NEMU_HOME) rev-parse --short=12 HEAD 2>/dev/null || echo unknown)

MBASE     := 0x80000000
UART_MMIO := 0x40600000
VLEN      := 128

DEP_ITERS ?= 200
DEP_SEED  ?= 0x20261025cafef00d
DEP_NAME  ?= dep
PERF_REPS ?= 5
HOST_IP   ?=
BASELINE_S := ../../../bench/baseline/baseline_rvv.S
HELLO_DIR  := ../hello
NAME      ?= all
BEGIN     ?= 0
END       ?= -1

ARCH_FLAGS := -march=rv64gcv_zve64x -mabi=lp64d -mcmodel=medany
CFLAGS  := $(ARCH_FLAGS) -ffreestanding -nostdlib -nostartfiles -fno-builtin -fno-pic \
           -fno-tree-vectorize -O2 -g -Wall -Wextra
# -no-pie：见 tests/riscv/vdot/Makefile 中的说明（switch 指针表需要绝对地址）
LDFLAGS := -nostdlib -nostartfiles -no-pie -Wl,--build-id=none

.PHONY: corpus-full corpus-batch dep wave perf perf-probe hello clean

$(BUILD)/vdot.ld: $(VDOT_DIR)/vdot.ld.in
	@mkdir -p $(@D)
	sed 's/@MBASE@/$(MBASE)/g' $< > $@

# vdot_test.c 期待的 nemu_config.h：这里填的是香山 SoC 的地址
$(BUILD)/inc/nemu_config.h: Makefile
	@mkdir -p $(@D)
	@{ echo '/* 自动生成：tests/riscv/fullcore/Makefile。地址取香山 SoC（全核 difftest）。 */'; \
	   echo '#ifndef NEMU_CONFIG_H'; echo '#define NEMU_CONFIG_H'; \
	   echo '#define NEMU_DEFCONFIG      "XiangShan MinimalConfig emu (DUT) / riscv64-xs-kmhv2-ref_defconfig (REF)"'; \
	   echo '#define NEMU_COMMIT         "$(NEMU_COMMIT)"'; \
	   echo '#define NEMU_MBASE          $(MBASE)UL'; \
	   echo '#define NEMU_UARTLITE_MMIO  $(UART_MMIO)UL'; \
	   echo '#define NEMU_VLEN           $(VLEN)'; \
	   echo '#endif'; } > $@

corpus-full: $(BUILD)/corpus_full.bin
$(BUILD)/corpus_full.bin: $(VDOT_DIR)/pack_corpus.py $(wildcard $(VECTORS_DIR)/*.txt) $(wildcard $(EXTRA_DIR)/*.txt)
	@mkdir -p $(@D)
	python3 $(VDOT_DIR)/pack_corpus.py $(VECTORS_DIR) $@ $(EXTRA_DIR)

corpus-batch: $(BUILD)/corpus_full.bin $(BUILD)/vdot.ld $(BUILD)/inc/nemu_config.h
	@mkdir -p $(BUILD)/$(NAME)
	python3 slice_corpus.py $(BUILD)/corpus_full.bin $(BUILD)/$(NAME)/corpus.bin $(BEGIN) $(END)
	$(CROSS)gcc $(CFLAGS) -I$(BUILD)/inc -DCORPUS_BIN='"$(abspath $(BUILD))/$(NAME)/corpus.bin"' \
	    $(LDFLAGS) -T $(BUILD)/vdot.ld -o $(BUILD)/$(NAME)/vdot_test.elf \
	    $(VDOT_DIR)/start.S $(VDOT_DIR)/vdot_test.c $(VDOT_DIR)/corpus.S
	$(CROSS)objcopy -O binary $(BUILD)/$(NAME)/vdot_test.elf $(BUILD)/$(NAME)/vdot_test.bin
	$(CROSS)objdump -d -M no-aliases $(BUILD)/$(NAME)/vdot_test.elf > $(BUILD)/$(NAME)/vdot_test.dis

dep: $(BUILD)/vdot.ld
	@mkdir -p $(BUILD)/$(DEP_NAME)
	$(CROSS)gcc $(CFLAGS) -DDEP_ITERS=$(DEP_ITERS) -DDEP_SEED=$(DEP_SEED)UL $(LDFLAGS) -T $(BUILD)/vdot.ld \
	    -o $(BUILD)/$(DEP_NAME)/vdot_dep.elf $(VDOT_DIR)/start.S vdot_dep.c vdot_dep_kernels.S
	$(CROSS)objcopy -O binary $(BUILD)/$(DEP_NAME)/vdot_dep.elf $(BUILD)/$(DEP_NAME)/vdot_dep.bin
	$(CROSS)objdump -d -M no-aliases $(BUILD)/$(DEP_NAME)/vdot_dep.elf > $(BUILD)/$(DEP_NAME)/vdot_dep.dis

wave: $(BUILD)/vdot.ld
	@mkdir -p $(BUILD)/wave
	$(CROSS)gcc $(ARCH_FLAGS) $(LDFLAGS) -T $(BUILD)/vdot.ld -o $(BUILD)/wave/vdot_wave.elf vdot_wave.S
	$(CROSS)objcopy -O binary $(BUILD)/wave/vdot_wave.elf $(BUILD)/wave/vdot_wave.bin
	$(CROSS)objdump -d -M no-aliases $(BUILD)/wave/vdot_wave.elf > $(BUILD)/wave/vdot_wave.dis

perf: $(BUILD)/vdot.ld
	@mkdir -p $(BUILD)/perf
	$(CROSS)gcc $(CFLAGS) -DPERF_REPS=$(PERF_REPS) $(LDFLAGS) -T $(BUILD)/vdot.ld \
	    -o $(BUILD)/perf/perf_cycles.elf $(VDOT_DIR)/start.S perf_cycles.c perf_kernels.S $(BASELINE_S)
	$(CROSS)objcopy -O binary $(BUILD)/perf/perf_cycles.elf $(BUILD)/perf/perf_cycles.bin
	$(CROSS)objdump -d -M no-aliases $(BUILD)/perf/perf_cycles.elf > $(BUILD)/perf/perf_cycles.dis

# 计时方法对照试验：裸 csrr mcycle 与 fence + csrr mcycle
perf-probe: $(BUILD)/vdot.ld
	@mkdir -p $(BUILD)/perf
	$(CROSS)gcc $(CFLAGS) $(LDFLAGS) -T $(BUILD)/vdot.ld \
	    -o $(BUILD)/perf/perf_csrr_probe.elf $(VDOT_DIR)/start.S perf_csrr_probe.c perf_csrr_probe.S
	$(CROSS)objcopy -O binary $(BUILD)/perf/perf_csrr_probe.elf $(BUILD)/perf/perf_csrr_probe.bin
	$(CROSS)objdump -d -M no-aliases $(BUILD)/perf/perf_csrr_probe.elf > $(BUILD)/perf/perf_csrr_probe.dis

# hello.c 期待的 nemu_config.h（字段与 tests/riscv/hello/Makefile 生成的完全相同）
hello:
	@test -n "$(HOST_IP)" || { echo "ERROR: HOST_IP 为空，请显式传入 HOST_IP=<本机IP>"; exit 1; }
	@mkdir -p $(BUILD)/hello
	@{ echo '/* 自动生成：tests/riscv/fullcore/Makefile（hello 目标）。地址取香山 SoC（全核 emu）。 */'; \
	   echo '#ifndef NEMU_CONFIG_H'; echo '#define NEMU_CONFIG_H'; \
	   echo '#define NEMU_DEFCONFIG      "XiangShan MinimalConfig emu (DUT) / riscv64-xs-kmhv2-ref_defconfig (REF)"'; \
	   echo '#define NEMU_COMMIT         "$(NEMU_COMMIT)"'; \
	   echo '#define NEMU_MBASE          $(MBASE)UL'; \
	   echo '#define NEMU_UARTLITE_MMIO  $(UART_MMIO)UL'; \
	   echo '#define NEMU_VLEN           $(VLEN)'; \
	   echo '#define HOST_IP             "$(HOST_IP)"'; \
	   echo '#endif'; } > $(BUILD)/hello/nemu_config.h
	sed 's/@MBASE@/$(MBASE)/g' $(HELLO_DIR)/hello.ld.in > $(BUILD)/hello/hello.ld
	$(CROSS)gcc $(ARCH_FLAGS) -ffreestanding -nostdlib -nostartfiles -fno-builtin -fno-pic \
	    -fno-tree-vectorize -O2 -g -Wall -Wextra -I$(BUILD)/hello \
	    -nostdlib -nostartfiles -Wl,--build-id=none -T $(BUILD)/hello/hello.ld \
	    -o $(BUILD)/hello/hello.elf $(HELLO_DIR)/start.S $(HELLO_DIR)/hello.c
	$(CROSS)objcopy -O binary $(BUILD)/hello/hello.elf $(BUILD)/hello/hello.bin
	$(CROSS)objdump -d -M no-aliases $(BUILD)/hello/hello.elf > $(BUILD)/hello/hello.dis

clean:
	rm -rf $(BUILD)
