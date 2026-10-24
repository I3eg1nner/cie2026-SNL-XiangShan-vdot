# =============================================================================
# tests/cosim/Makefile —— 在 Linux/aarch64 容器内编译协同仿真驱动
#
#   前置：verilator 已经在宿主机把两个 RTL 模块转成 C++（build/vdut、build/ddut），
#         本 Makefile 只用 g++ 把它们和 cosim_main.cpp、verilator 运行时一起编译。
#         这样做的原因：NEMU 的 difftest 参考共享库是 linux/aarch64 ELF，
#         必须在容器里 dlopen；而 verilator 装在 macOS 宿主机上。
#
#   变量：
#     VERILATOR_INC  verilator 的 include 目录（含 verilated.cpp）
#     BUILD          生成目录，默认 build
# =============================================================================
BUILD         ?= build
VERILATOR_INC ?= /opt/verilator/include

VDUT_DIR := $(BUILD)/vdut
DDUT_DIR := $(BUILD)/ddut

VDUT_SRCS := $(wildcard $(VDUT_DIR)/*.cpp)
DDUT_SRCS := $(wildcard $(DDUT_DIR)/*.cpp)
VRT_SRCS  := $(VERILATOR_INC)/verilated.cpp $(VERILATOR_INC)/verilated_threads.cpp

CXX      ?= g++
CXXFLAGS := -O2 -std=c++17 -Wno-attributes \
            -I$(VERILATOR_INC) -I$(VERILATOR_INC)/vltstd \
            -I$(VDUT_DIR) -I$(DDUT_DIR) -I.
LDFLAGS  := -ldl -lpthread

TARGET := $(BUILD)/cosim

.PHONY: all clean
all: $(TARGET)

$(TARGET): cosim_main.cpp ref_nemu.h $(VDUT_SRCS) $(DDUT_SRCS)
	@test -n "$(VDUT_SRCS)" || { echo "ERROR: $(VDUT_DIR) 为空，请先在宿主机跑 verilator --cc"; exit 1; }
	@test -n "$(DDUT_SRCS)" || { echo "ERROR: $(DDUT_DIR) 为空，请先在宿主机跑 verilator --cc"; exit 1; }
	$(CXX) $(CXXFLAGS) -o $@ cosim_main.cpp $(VDUT_SRCS) $(DDUT_SRCS) $(VRT_SRCS) $(LDFLAGS)

clean:
	rm -f $(TARGET)
