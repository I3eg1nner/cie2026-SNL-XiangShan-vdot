#!/usr/bin/env bash
# =============================================================================
# 21_build_nemu_vdot.sh —— 赛题阶段三 3.1.1（P5）一键复现
#
#   [1] 把 nemu/patch/0001-add-vdot-instruction-family.patch 应用到 work/NEMU
#       （幂等：已应用则跳过，不会重复打）
#   [2] 构建 NEMU 两种形态
#         riscv64-xs-kmhv2_defconfig      -> build/riscv64-nemu-interpreter
#         riscv64-xs-kmhv2-ref_defconfig  -> build/riscv64-nemu-interpreter-so
#       两者都带 CONFIG_CUSTOM_XVDOT=y
#   [3] 交叉编译 tests/riscv/vdot 并在独立解释器上跑完全部语料
#       （tests/vectors 的 30703 条共享语料 + tests/riscv/vdot/extra_vectors 的
#        55 条补充定向语料 = 30758 条，裁定 S-7' 传播后），输出 PASS/FAIL 统计
#   [4] 用 NEMU 自带的 tools/ref-so-runner 把同一套语料在 **difftest 参考
#       共享库** 里再跑一遍，证明 .so 侧也实现了 vdot（P6 协同仿真的前提）
#   [5] 把工作区配置恢复成独立解释器形态
#
# 执行位置：Linux 宿主机直接执行；macOS 进 xsdev 容器（XS_RUNNER，见 scripts/lib/common.sh）。
# 路径：NEMU 在 ${WORK_DIR}/NEMU；tests/riscv/vdot 同步到 ${BUILD_ROOT}/src 下构建，
#       产物不落进交付仓库。
#
# 日志（${LOG_ROOT}/stage3/，LOG_ROOT 默认 logs/）：
#   logs/stage3/p5_nemu_build.log     构建全过程
#   logs/stage3/p5_vdot_tests.log     两次语料实跑
#   logs/stage3/p5_fault_injection.log  故障注入（需显式 `fault` 子命令）
#
# 用法：
#   ./scripts/21_build_nemu_vdot.sh           # [1]~[5]
#   ./scripts/21_build_nemu_vdot.sh fault     # 故障注入自测（T3）
#   ./scripts/21_build_nemu_vdot.sh verify-patch  # 在干净副本上验证 patch 可应用
# =============================================================================
set -euo pipefail

MODE="${1:-all}"

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/common.sh"

# -----------------------------------------------------------------------------
# 分阶段执行体（在宿主机或容器内运行）
# -----------------------------------------------------------------------------
if [ "${MODE}" = "__phase" ]; then
    PHASE="$2"
    export NEMU_HOME="${NEMU_DIR}"
    PATCH="${REPO_ROOT}/nemu/patch/0001-add-vdot-instruction-family.patch"
    TESTDIR="${STAGE_DIR}/tests/riscv/vdot"
    CROSS="${CROSS:-riscv64-linux-gnu-}"

    banner() {
        echo "=============================================================="
        echo " $*   $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
        echo "=============================================================="
    }

    case "${PHASE}" in
    patch)
        banner "[1] 应用 vdot patch（幂等）"
        cd "${NEMU_HOME}"
        echo "\$ git log --oneline -1"; git log --oneline -1
        echo "\$ sha256sum ${PATCH}"; sha256sum "${PATCH}"
        if git apply --check --reverse "${PATCH}" >/dev/null 2>&1; then
            echo "patch 已处于已应用状态（git apply --check --reverse 通过），跳过"
        elif git apply --check "${PATCH}" >/dev/null 2>&1; then
            git apply "${PATCH}"
            echo "patch 应用成功"
        else
            echo "ERROR: patch 既不能正向应用，也不是已应用状态。工作区状态："
            git status --short
            exit 1
        fi
        echo "\$ git status --short"; git status --short
        echo "\$ git log --oneline -1   （上游 git 历史未被改写）"; git log --oneline -1
        ;;

    build-standalone)
        banner "[2A] 构建独立解释器 riscv64-xs-kmhv2_defconfig"
        cd "${NEMU_HOME}"
        echo "\$ uname -m"; uname -m
        echo "\$ gcc --version"; gcc --version | head -1
        echo "\$ make riscv64-xs-kmhv2_defconfig"
        make riscv64-xs-kmhv2_defconfig
        echo "--- 确认 CONFIG_CUSTOM_XVDOT 进入生成配置 ---"
        grep -n 'CONFIG_CUSTOM_XVDOT' include/generated/autoconf.h
        echo "\$ make -j${JOBS}"
        make -j"${JOBS}"
        ls -l build/riscv64-nemu-interpreter
        file build/riscv64-nemu-interpreter
        echo "--- vdot.c 确实被编译进这一形态 ---"
        ls -l build/obj-riscv64-nemu-interpreter/src/isa/riscv64/instr/rvv/vdot.o
        ;;

    build-ref)
        banner "[2B] 构建 difftest 参考共享库 riscv64-xs-kmhv2-ref_defconfig"
        cd "${NEMU_HOME}"
        echo "\$ make riscv64-xs-kmhv2-ref_defconfig"
        make riscv64-xs-kmhv2-ref_defconfig
        echo "--- 确认 CONFIG_CUSTOM_XVDOT 进入 ref 形态的生成配置 ---"
        grep -n 'CONFIG_CUSTOM_XVDOT' include/generated/autoconf.h
        echo "\$ make -j${JOBS}"
        make -j"${JOBS}"
        ls -l build/riscv64-nemu-interpreter-so
        file build/riscv64-nemu-interpreter-so
        echo "--- vdot.c 确实被编译进 .so 形态 ---"
        ls -l build/obj-riscv64-nemu-interpreter-so/src/isa/riscv64/instr/rvv/vdot.o
        echo "--- 构建 NEMU 自带的 ref-so-runner（dlopen 驱动 .so 跑扁平镜像） ---"
        make -C tools/ref-so-runner
        ls -l tools/ref-so-runner/runner
        ;;

    restore)
        banner "[5] 恢复工作区为独立解释器配置"
        cd "${NEMU_HOME}"
        echo "\$ make riscv64-xs-kmhv2_defconfig"
        make riscv64-xs-kmhv2_defconfig
        echo "\$ make -j${JOBS}"
        make -j"${JOBS}"
        grep -E 'CONFIG_MBASE|CONFIG_UARTLITE_MMIO|CONFIG_CUSTOM_XVDOT' include/generated/autoconf.h
        echo "--- build/ 目录一览 ---"
        ls -l build/ | grep -v '^d'
        ;;

    test-standalone)
        banner "[3] 独立解释器上跑完整共享语料"
        cd "${TESTDIR}"
        echo "（构建目录：${TESTDIR}，为 tests/riscv/vdot 的同步副本）"
        echo "\$ ${CROSS}gcc --version"; "${CROSS}gcc" --version | head -1
        echo "\$ make clean && make NEMU_HOME=${NEMU_HOME} CROSS=${CROSS}"
        make clean >/dev/null
        make NEMU_HOME="${NEMU_HOME}" CROSS="${CROSS}"
        echo
        echo "--- 证据：6 条被测指令确实以 OPIVV 自定义编码出现在镜像的 .text 里 ---"
        echo "\$ grep -E 'e62081d7|e42081d7|ea2081d7|e82081d7|ee2081d7|ec2081d7' build/vdot_test.dis"
        grep -E 'e62081d7|e42081d7|ea2081d7|e82081d7|ee2081d7|ec2081d7' build/vdot_test.dis
        echo
        echo "--- 实跑 ---"
        echo "\$ \$NEMU_HOME/build/riscv64-nemu-interpreter -b --log=build/nemu-run.log build/vdot_test.bin"
        echo "------------------- 以下为模拟器实际输出 -------------------"
        set +e
        "${NEMU_HOME}/build/riscv64-nemu-interpreter" -b --log=build/nemu-run.log build/vdot_test.bin
        rc=$?
        set -e
        echo "------------------- 模拟器输出结束 -------------------"
        echo "NEMU 进程退出码 = ${rc}"
        echo
        echo "--- NEMU 自身运行日志（尾部） ---"
        tail -8 build/nemu-run.log
        exit "${rc}"
        ;;

    test-ref)
        banner "[4] difftest 参考共享库上跑同一套共享语料"
        cd "${TESTDIR}"
        echo "ref 配置关掉了全部串口设备，故使用静默变体 vdot_test_quiet.bin："
        echo "  计算与比对逻辑完全相同，只是不输出，结果以 main 的返回值"
        echo "  （失败条数）经 nemu_trap 作为 halt_ret 报告。"
        echo "\$ \$NEMU_HOME/tools/ref-so-runner/runner --so \$NEMU_HOME/build/riscv64-nemu-interpreter-so -b build/vdot_test_quiet.bin"
        echo "------------------- 以下为 .so 实际输出 -------------------"
        set +e
        "${NEMU_HOME}/tools/ref-so-runner/runner" \
            --so "${NEMU_HOME}/build/riscv64-nemu-interpreter-so" \
            -b build/vdot_test_quiet.bin
        rc=$?
        set -e
        echo "------------------- .so 输出结束 -------------------"
        echo "runner 退出码 = ${rc}  （0 = HIT GOOD TRAP = 失败条数为 0）"
        echo
        echo "判读："
        echo "  * 'HIT GOOD TRAP' + 'trap code:0'  => main 返回 0 => 全部用例 0 失配"
        echo "  * 'vst count' 等于用例总数          => 确实逐条执行并回读了每一次 vd"
        exit "${rc}"
        ;;

    fault)
        bash "${TESTDIR}/fault_inject.sh"
        ;;

    verify-patch)
        banner "[V] 在干净副本上验证 patch 可应用"
        WORK=$(mktemp -d)
        cd "${WORK}"
        echo "\$ git clone --shared --no-checkout ${NEMU_HOME} NEMU-fresh"
        git clone --quiet --shared --no-checkout "${NEMU_HOME}" NEMU-fresh
        cd NEMU-fresh
        echo "\$ git checkout 9090839 -- . （检出干净的上游 commit，不带任何本地改动）"
        git -c advice.detachedHead=false checkout --quiet 9090839
        echo "\$ git log --oneline -1"; git log --oneline -1
        echo "\$ git status --short  （应为空）"; git status --short
        echo "\$ git apply --check --verbose ${PATCH}"
        git apply --check --verbose "${PATCH}"
        echo "\$ git apply ${PATCH}"
        git apply "${PATCH}"
        echo "\$ git apply --stat ${PATCH}"
        git apply --stat "${PATCH}"
        echo "\$ git status --short"; git status --short
        echo
        echo "--- 在这份全新副本上实际构建一次（独立解释器形态） ---"
        # NEMU 的 Makefile 会在解析阶段浅克隆 resource/ 下的第三方源码（需要网络）。
        # 这里直接从已有工作区复制过来，使本验证可离线进行。
        if [ -d "${NEMU_DIR}/resource" ]; then
            cp -a "${NEMU_DIR}/resource" "${WORK}/NEMU-fresh/"
            echo "（已从现有工作区复制 resource/，避免重复联网浅克隆）"
        fi
        export NEMU_HOME="${WORK}/NEMU-fresh"
        cd "${NEMU_HOME}"
        make riscv64-xs-kmhv2_defconfig >/dev/null
        grep -n CONFIG_CUSTOM_XVDOT include/generated/autoconf.h
        make -j"${JOBS}" >/dev/null 2>&1 || { echo "ERROR: 干净副本构建失败"; exit 1; }
        ls -l build/riscv64-nemu-interpreter
        echo
        echo "--- 用干净副本的解释器重跑全部语料 ---"
        set +e
        ./build/riscv64-nemu-interpreter -b --log=/dev/null \
            "${TESTDIR}/build/vdot_test.bin" 2>&1 \
            | grep -E '^(TOTAL|  must-trap|  missing-trap|RESULT)'
        set -e
        cd /
        rm -rf "${WORK}"
        echo "PATCH-VERIFY: OK"
        ;;

    *)
        echo "unknown phase: ${PHASE}" >&2; exit 1 ;;
    esac
    exit 0
fi

# -----------------------------------------------------------------------------
# 宿主机侧：编排各阶段，分别 tee 到对应日志
# -----------------------------------------------------------------------------
LOG_DIR="${LOG_ROOT}/stage3"
mkdir -p "${LOG_DIR}"

[ -d "${NEMU_DIR}" ] || die "找不到 ${NEMU_DIR}，请先执行 scripts/00_setup_env_host.sh"
setup_nemu_host_deps
detect_cross
need_cmd python3
stage_tests

in_container() {   # 名字沿用旧版；实际按 XS_RUNNER 在宿主机或容器内执行
    xrun "bash '${REPO_ROOT}/scripts/21_build_nemu_vdot.sh' __phase '$1'"
}

BUILD_LOG="${LOG_DIR}/p5_nemu_build.log"
TEST_LOG="${LOG_DIR}/p5_vdot_tests.log"
FAULT_LOG="${LOG_DIR}/p5_fault_injection.log"

case "${MODE}" in
all)
    : > "${BUILD_LOG}"
    : > "${TEST_LOG}"
    in_container patch            2>&1 | tee -a "${BUILD_LOG}"; echo "" | tee -a "${BUILD_LOG}" >/dev/null
    in_container build-standalone 2>&1 | tee -a "${BUILD_LOG}"
    test_rc=0
    in_container test-standalone  2>&1 | tee -a "${TEST_LOG}" || test_rc=1
    in_container build-ref        2>&1 | tee -a "${BUILD_LOG}"
    in_container test-ref         2>&1 | tee -a "${TEST_LOG}" || test_rc=1
    in_container restore          2>&1 | tee -a "${BUILD_LOG}"
    echo
    echo "完成。日志："
    echo "  ${BUILD_LOG}"
    echo "  ${TEST_LOG}"
    grep -E '^TOTAL|^RESULT:|^runner 退出码' "${TEST_LOG}" || true
    exit "${test_rc}"
    ;;
fault)
    # fault_inject.sh 只执行 `make -C NEMU`，沿用当前 .config。若之前跑过 30_run_cosim.sh
    # （.config 为 ref 形态），重建的是 .so 而不是独立解释器，注入会全部"漏检"。
    # 因此先把工作区恢复为独立解释器形态，并确保语料镜像已构建。
    {
        in_container restore
        if [ ! -f "${STAGE_DIR}/tests/riscv/vdot/build/vdot_test.bin" ]; then
            in_container test-standalone
        fi
    } > "${LOG_DIR}/p5_fault_prepare.log" 2>&1 || { tail -20 "${LOG_DIR}/p5_fault_prepare.log"; die "故障注入前的准备失败"; }
    info "准备完成（独立解释器形态 + 语料镜像），详见 ${LOG_DIR}/p5_fault_prepare.log"
    in_container fault 2>&1 | tee "${FAULT_LOG}"
    ;;
verify-patch)
    in_container verify-patch 2>&1 | tee "${LOG_DIR}/p5_patch_verify.log"
    ;;
*)
    echo "unknown mode: ${MODE}（可选 all / fault / verify-patch）" >&2
    exit 1
    ;;
esac
