#!/usr/bin/env bash
# =============================================================================
# 02_build_nemu.sh —— 构建 NEMU 的两种形态（Linux 宿主机直接构建 / macOS 进 xsdev 容器）
#   [A] 独立解释器      riscv64-xs-kmhv2_defconfig      -> build/riscv64-nemu-interpreter
#   [B] difftest 参考库 riscv64-xs-kmhv2-ref_defconfig  -> build/riscv64-nemu-interpreter-so
#
# 执行位置：Linux 宿主机直接执行；macOS 自动进 xsdev 容器（见 scripts/lib/common.sh 的
# XS_RUNNER / xrun）。脚本会把自己以 __inner 模式在目标环境里再跑一遍。
# 用法： ./scripts/02_build_nemu.sh            # 两种形态都构建
#        ./scripts/02_build_nemu.sh standalone # 只构建 [A]
#        ./scripts/02_build_nemu.sh ref        # 只构建 [B]
# 环境变量：WORK_DIR（NEMU 在 ${WORK_DIR}/NEMU）、LOG_ROOT、XS_RUNNER、JOBS，见 scripts/lib/common.sh
# =============================================================================
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/common.sh"

if [ "${1:-}" != "__inner" ]; then
    # ---- 编排侧：检查依赖后转入执行环境 ----
    TARGET="${1:-all}"
    [ -d "${NEMU_DIR}" ] || die "找不到 ${NEMU_DIR}，请先执行 scripts/00_setup_env_host.sh"
    setup_nemu_host_deps
    mkdir -p "${LOG_ROOT}/stage1"
    xrun "bash '${REPO_ROOT}/scripts/02_build_nemu.sh' __inner '${TARGET}'" \
        2>&1 | tee "${LOG_ROOT}/stage1/p1_nemu_build.log"
    exit "${PIPESTATUS[0]}"
fi

# ---- 执行环境内（宿主机或容器） ----
TARGET="${2:-all}"
export NEMU_HOME="${NEMU_DIR}"

echo "=============================================================="
echo " P1-T2 NEMU 构建   $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
echo "=============================================================="
echo "\$ uname -a";            uname -a
echo "\$ cat /etc/os-release"; sed -n '1,2p' /etc/os-release
echo "\$ gcc --version";       gcc --version | head -1
echo "\$ nproc";               nproc
echo "\$ free -h";             free -h
echo "NEMU_HOME=${NEMU_HOME}"
cd "${NEMU_HOME}"
echo "\$ git log --oneline -1"; git log --oneline -1
echo "\$ git rev-parse HEAD";   git rev-parse HEAD

build_standalone() {
    echo
    echo "######## [A] 独立解释器：riscv64-xs-kmhv2_defconfig ########"
    echo "\$ make riscv64-xs-kmhv2_defconfig"
    make riscv64-xs-kmhv2_defconfig
    echo "\$ make -j${JOBS}"
    make -j"${JOBS}"
    echo "--- 产物 ---"
    ls -l build/riscv64-nemu-interpreter
    file build/riscv64-nemu-interpreter
}

build_ref() {
    echo
    echo "######## [B] difftest 参考实现：riscv64-xs-kmhv2-ref_defconfig ########"
    echo "\$ make riscv64-xs-kmhv2-ref_defconfig"
    make riscv64-xs-kmhv2-ref_defconfig
    echo "\$ make -j${JOBS}"
    make -j"${JOBS}"
    echo "--- 产物 ---"
    ls -l build/riscv64-nemu-interpreter-so
    file build/riscv64-nemu-interpreter-so
}

# 两种形态共用同一个 build/ 目录但产物名不同，可以共存；
# 但 .config / include/generated 只反映"最后一次配置"。
# 运行 RISC-V 程序用的是独立解释器，且 tests/riscv/hello 的 Makefile 要从
# include/generated/autoconf.h 里取 CONFIG_MBASE / CONFIG_UARTLITE_MMIO，
# 所以 all 模式最后把配置恢复成独立解释器配置。
restore_standalone_config() {
    echo
    echo "######## [C] 把工作区配置恢复为独立解释器（供运行 RISC-V 程序使用）########"
    echo "\$ make riscv64-xs-kmhv2_defconfig"
    make riscv64-xs-kmhv2_defconfig
    echo "\$ make -j${JOBS}"
    make -j"${JOBS}"
    echo "--- 恢复后 include/generated/autoconf.h 的关键项 ---"
    grep -E 'CONFIG_MBASE|CONFIG_UARTLITE_MMIO|CONFIG_MMIO_RESET_VECTOR' include/generated/autoconf.h
}

case "${TARGET}" in
    standalone) build_standalone ;;
    ref)        build_ref ;;
    all)        build_standalone; build_ref; restore_standalone_config ;;
    *) echo "unknown target: ${TARGET}" >&2; exit 1 ;;
esac

echo
echo "######## 构建完成，build/ 目录一览 ########"
ls -l "${NEMU_HOME}/build/" | grep -v '^d' || true

# 工作区状态快照：让每份构建日志都自带「这次构建用的是哪个 commit、带没带改动」。
# 阶段一应为「零改动」（无 M/?? 行）；阶段三起会看到 vdot patch 的改动。
# 追加在日志末尾，不影响前文已被文档引用的行号。
echo
echo "######## 工作区状态快照（供复核「零 patch」主张）########"
echo "\$ git rev-parse HEAD";     git -C "${NEMU_HOME}" rev-parse HEAD
echo "\$ git status --short";     git -C "${NEMU_HOME}" status --short || true
echo "（空输出 = 工作区干净；非空见 nemu/patch/ 与 docs/stage1/01_环境部署报告.md §3.4）"
echo "DONE $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
