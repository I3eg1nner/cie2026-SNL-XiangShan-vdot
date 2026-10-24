#!/usr/bin/env bash
# =============================================================================
# 02_build_nemu.sh —— 在 xsdev 容器内构建 NEMU 的两种形态
#   [A] 独立解释器      riscv64-xs-kmhv2_defconfig      -> build/riscv64-nemu-interpreter
#   [B] difftest 参考库 riscv64-xs-kmhv2-ref_defconfig  -> build/riscv64-nemu-interpreter-so
#
# 本脚本在宿主机执行时会自动把自己放进容器里再跑一遍（见 __IN_CONTAINER__ 判断）。
# 用法： ./scripts/02_build_nemu.sh            # 两种形态都构建
#        ./scripts/02_build_nemu.sh standalone # 只构建 [A]
#        ./scripts/02_build_nemu.sh ref        # 只构建 [B]
# =============================================================================
set -euo pipefail

TARGET="${1:-all}"

if [ ! -f /.dockerenv ]; then
    # ---- 宿主机侧：转入容器 ----
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
    mkdir -p "${REPO_ROOT}/logs/stage1"
    docker run --rm --platform linux/arm64 \
        -v "${REPO_ROOT}:/work" -w /work \
        "${XSDEV_IMAGE:-xsdev:ubuntu24.04-arm64}" \
        bash /work/scripts/02_build_nemu.sh "${TARGET}" \
        2>&1 | tee "${REPO_ROOT}/logs/stage1/p1_nemu_build.log"
    exit "${PIPESTATUS[0]}"
fi

# ---- 容器内 ----
export NEMU_HOME=/work/work/NEMU

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
    echo "\$ make -j\$(nproc)"
    make -j"$(nproc)"
    echo "--- 产物 ---"
    ls -l build/riscv64-nemu-interpreter
    file build/riscv64-nemu-interpreter
}

build_ref() {
    echo
    echo "######## [B] difftest 参考实现：riscv64-xs-kmhv2-ref_defconfig ########"
    echo "\$ make riscv64-xs-kmhv2-ref_defconfig"
    make riscv64-xs-kmhv2-ref_defconfig
    echo "\$ make -j\$(nproc)"
    make -j"$(nproc)"
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
    echo "\$ make -j\$(nproc)"
    make -j"$(nproc)"
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
echo "DONE $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
