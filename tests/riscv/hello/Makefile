# =============================================================================
# tests/riscv/hello —— 阶段一环境验证程序（裸机 RV64，跑在 NEMU 上）
#
# 关键点：编译参数不是手写死的，而是从 NEMU 当前的构建配置里抽出来的。
#   CONFIG_MBASE / CONFIG_UARTLITE_MMIO  <- $(NEMU_HOME)/include/generated/autoconf.h
#   VLEN                                 <- $(NEMU_HOME)/src/isa/riscv64/instr/rvv/vreg.h
# 因此必须先把 NEMU 配置成 riscv64-xs-kmhv2_defconfig 并构建过一次。
#
# 用法：
#   make NEMU_HOME=/work/work/NEMU HOST_IP=192.168.30.213
#   make run NEMU_HOME=... HOST_IP=...
# =============================================================================

NEMU_HOME ?= /work/work/NEMU
CROSS     ?= riscv64-linux-gnu-
BUILD     ?= build

AUTOCONF  := $(NEMU_HOME)/include/generated/autoconf.h
VREG_H    := $(NEMU_HOME)/src/isa/riscv64/instr/rvv/vreg.h

# ---- 本机 IP：缺省自动探测（macOS 走默认路由网卡，Linux 走 ip route） ----
# 容器内探测到的是容器 IP，所以由上层脚本 scripts/03_run_hello.sh 在宿主机
# 探测后通过 HOST_IP=... 显式传入。
HOST_IP ?= $(shell \
  if command -v route >/dev/null 2>&1 && [ "$$(uname -s)" = "Darwin" ]; then \
    ipconfig getifaddr $$(route -n get default 2>/dev/null | awk '/interface:/{print $$2}'); \
  else \
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($$i=="src") print $$(i+1)}'; \
  fi)

NEMU_DEFCONFIG ?= riscv64-xs-kmhv2_defconfig
NEMU_COMMIT    := $(shell git -C $(NEMU_HOME) rev-parse --short=12 HEAD 2>/dev/null || echo unknown)

NEMU_MBASE         := $(shell grep -E '^\#define CONFIG_MBASE[ \t]' $(AUTOCONF) 2>/dev/null | awk '{print $$3}')
NEMU_UARTLITE_MMIO := $(shell grep -E '^\#define CONFIG_UARTLITE_MMIO[ \t]' $(AUTOCONF) 2>/dev/null | awk '{print $$3}')
NEMU_VLEN          := $(shell grep -E '^\#define VLEN[ \t]' $(VREG_H) 2>/dev/null | awk '{print $$3}')

CFLAGS  := -march=rv64gcv_zve64x -mabi=lp64d -mcmodel=medany \
           -ffreestanding -nostdlib -nostartfiles -fno-builtin -fno-pic \
           -fno-tree-vectorize -O2 -g -Wall -Wextra -I$(BUILD)
LDFLAGS := -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-Map,$(BUILD)/hello.map

SRCS := start.S hello.c

.PHONY: all clean run check-config

all: check-config $(BUILD)/hello.bin $(BUILD)/hello.dis

check-config:
	@test -n "$(NEMU_MBASE)"         || { echo "ERROR: 读不到 CONFIG_MBASE，请先执行 make riscv64-xs-kmhv2_defconfig && make (NEMU_HOME=$(NEMU_HOME))"; exit 1; }
	@test -n "$(NEMU_UARTLITE_MMIO)" || { echo "ERROR: 当前 NEMU 配置没有 CONFIG_UARTLITE_MMIO（difftest ref 配置关掉了所有串口设备）。请切回 riscv64-xs-kmhv2_defconfig"; exit 1; }
	@test -n "$(NEMU_VLEN)"          || { echo "ERROR: 读不到 VLEN ($(VREG_H))"; exit 1; }
	@test -n "$(HOST_IP)"            || { echo "ERROR: HOST_IP 为空，请显式传入 HOST_IP=<本机IP>"; exit 1; }
	@echo "NEMU_HOME          = $(NEMU_HOME)"
	@echo "NEMU_COMMIT        = $(NEMU_COMMIT)"
	@echo "CONFIG_MBASE       = $(NEMU_MBASE)"
	@echo "CONFIG_UARTLITE_MMIO = $(NEMU_UARTLITE_MMIO)"
	@echo "VLEN               = $(NEMU_VLEN)"
	@echo "HOST_IP            = $(HOST_IP)"

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
	  echo '#define HOST_IP             "$(HOST_IP)"'; \
	  echo '#endif'; \
	} > $@
	@echo "GEN  $@"

$(BUILD)/hello.ld: hello.ld.in Makefile
	@mkdir -p $(BUILD)
	@sed 's/@MBASE@/$(NEMU_MBASE)/g' $< > $@
	@echo "GEN  $@"

$(BUILD)/hello.elf: $(SRCS) $(BUILD)/nemu_config.h $(BUILD)/hello.ld
	$(CROSS)gcc $(CFLAGS) $(LDFLAGS) -T $(BUILD)/hello.ld -o $@ $(SRCS)
	@echo "LD   $@"

$(BUILD)/hello.bin: $(BUILD)/hello.elf
	$(CROSS)objcopy -O binary $< $@
	@echo "BIN  $@  ($$(stat -c %s $@ 2>/dev/null || stat -f %z $@) bytes)"

$(BUILD)/hello.dis: $(BUILD)/hello.elf
	$(CROSS)objdump -d -M no-aliases $< > $@
	@echo "DIS  $@"

run: all
	$(NEMU_HOME)/build/riscv64-nemu-interpreter -b \
	    --log=$(BUILD)/nemu-run.log $(BUILD)/hello.bin

clean:
	rm -rf $(BUILD)
