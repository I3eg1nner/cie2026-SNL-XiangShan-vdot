#!/usr/bin/env bash
# =============================================================================
# 30_run_cosim.sh —— 赛题阶段三 3.1.2（P6）NEMU <-> RTL 协同仿真一键复现
#
#   一条命令完成：
#     [1] 构建 / 复用 NEMU difftest 参考共享库 riscv64-nemu-interpreter-so
#         （riscv64-xs-kmhv2-ref_defconfig + CONFIG_CUSTOM_XVDOT=y）
#     [2] 从 work/XiangShan-cosim 精化出两个被测 RTL 模块的 Verilog
#           yunsuan VDotTop          —— vdot 功能单元数据通路
#           xiangshan VdotDecodeProbe —— DecodeUnit + VecExceptionGen 串接探针
#     [3] 宿主机 verilator --cc 把它们转成 C++
#     [4] 容器内 g++ 把 C++ + 协同仿真驱动编成 build/cosim
#     [5] 跑完整激励：全部定向语料（tests/vectors + extra_vectors）
#         + 每条指令 10000 条架构内随机 + 三类非法面随机各 3000 条
#     [6] 打印汇总表
#
#   为什么要用容器：NEMU 的参考共享库是 linux/aarch64 ELF，必须在 Linux 里
#   dlopen；而 verilator / mill 装在 macOS 宿主机上。于是「精化 + verilate」
#   在宿主机做，「编译 + dlopen + 运行」在容器里做。
#
#   用法：
#     ./scripts/30_run_cosim.sh                 # 构建 + 跑完整协同仿真
#     ./scripts/30_run_cosim.sh fault           # 故障注入自测（RTL 侧 + NEMU 侧）
#     FORCE_NEMU=1 ./scripts/30_run_cosim.sh    # 强制重建 NEMU 参考共享库
#
#   日志：
#     logs/stage3/cosim/p6_build.log
#     logs/stage3/cosim/p6_cosim_run.log
#     logs/stage3/cosim/p6_fault_injection.log
# =============================================================================
set -euo pipefail

MODE="${1:-all}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
IMAGE="${XSDEV_IMAGE:-xsdev:ubuntu24.04-arm64}"

XS="${REPO_ROOT}/work/XiangShan-cosim"
YS="${XS}/yunsuan"
NEMU="${REPO_ROOT}/work/NEMU"
COSIM="${REPO_ROOT}/tests/cosim"
BUILD="${COSIM}/build"
LOG_DIR="${REPO_ROOT}/logs/stage3/cosim"
NEMU_SO="${NEMU}/build/riscv64-nemu-interpreter-so"
PATCH="${REPO_ROOT}/nemu/patch/0001-add-vdot-instruction-family.patch"

RANDOM_N="${RANDOM_N:-10000}"
ILLEGAL_N="${ILLEGAL_N:-3000}"
SEED="${SEED:-20260324}"

mkdir -p "${LOG_DIR}" "${BUILD}"

banner() {
    echo "=============================================================="
    echo " $*   $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
    echo "=============================================================="
}

in_container() {
    docker run --rm --platform linux/arm64 \
        -v "${REPO_ROOT}:/work" -w /work \
        -e NEMU_HOME=/work/work/NEMU \
        "${IMAGE}" bash -lc "$1"
}

# -----------------------------------------------------------------------------
# [1] NEMU difftest 参考共享库
# -----------------------------------------------------------------------------
build_nemu_ref() {
    banner "[1] NEMU difftest 参考共享库（riscv64-xs-kmhv2-ref_defconfig + XVDOT）"
    local vdot_obj="${NEMU}/build/obj-riscv64-nemu-interpreter-so/src/isa/riscv64/instr/rvv/vdot.o"
    if [ -z "${FORCE_NEMU:-}" ] && [ -f "${NEMU_SO}" ] && [ -f "${vdot_obj}" ] &&
       [ "${NEMU_SO}" -nt "${NEMU}/src/isa/riscv64/instr/rvv/vdot.c" ]; then
        echo "已存在且比 vdot.c 新，跳过重建（FORCE_NEMU=1 可强制重建）："
        ls -l "${NEMU_SO}" "${vdot_obj}"
        return 0
    fi
    in_container '
set -euo pipefail
cd /work/work/NEMU
git config --global --add safe.directory /work/work/NEMU >/dev/null 2>&1 || true
echo "$ git log --oneline -1"; git log --oneline -1
if git apply --check --reverse /work/nemu/patch/0001-add-vdot-instruction-family.patch >/dev/null 2>&1; then
  echo "vdot patch 已处于已应用状态，跳过"
elif git apply --check /work/nemu/patch/0001-add-vdot-instruction-family.patch >/dev/null 2>&1; then
  git apply /work/nemu/patch/0001-add-vdot-instruction-family.patch
  echo "vdot patch 应用成功"
else
  echo "ERROR: patch 既不能正向应用也不是已应用状态"; git status --short; exit 1
fi
make riscv64-xs-kmhv2-ref_defconfig
grep -n CONFIG_CUSTOM_XVDOT include/generated/autoconf.h
make -j"$(nproc)" 2>&1 | tail -5
ls -l build/riscv64-nemu-interpreter-so
file build/riscv64-nemu-interpreter-so
ls -l build/obj-riscv64-nemu-interpreter-so/src/isa/riscv64/instr/rvv/vdot.o
nm -D --defined-only build/riscv64-nemu-interpreter-so | grep -E "difftest_init$|difftest_exec$|difftest_regcpy$|difftest_memcpy$|DIFFTEST_REG_SIZE"
'
}

# -----------------------------------------------------------------------------
# [2] mill 精化出两个被测模块
# -----------------------------------------------------------------------------
elaborate_rtl() {
    banner "[2] 从 work/XiangShan-cosim 精化 RTL"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/scripts/env_host.sh"
    echo "java      : $(java -version 2>&1 | head -1)"
    echo "verilator : $(verilator --version)"

    # 译码探针的 Scala 源码随交付仓库走，这里同步进工作树
    mkdir -p "${XS}/src/test/scala/xiangshan/backend/decode"
    cp -f "${COSIM}/VdotDecodeProbe.scala" \
          "${XS}/src/test/scala/xiangshan/backend/decode/VdotDecodeProbe.scala"

    echo "--- yunsuan: VDotTop ---"
    ( cd "${YS}" && mill -i YunSuan.runMain yunsuan.vector.mac.VerilogVDotTop )
    ls -l "${YS}/build/vdot/VDotTop.sv"

    echo "--- xiangshan: VdotDecodeProbe (DecodeUnit + VecExceptionGen) ---"
    ( cd "${XS}" && mill -i -D jvm-xmx=8G \
        xiangshan.test.runMain xiangshan.backend.decode.VdotDecodeProbeMain \
        --target-dir build/vdot --target verilog )
    ls -l "${XS}/build/vdot/VdotDecodeProbe.v"
}

# -----------------------------------------------------------------------------
# [3] verilator --cc（宿主机）
# -----------------------------------------------------------------------------
verilate() {
    banner "[3] verilator --cc（宿主机 verilator 5.052）"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/scripts/env_host.sh"
    rm -rf "${BUILD}/vdut" "${BUILD}/ddut"
    verilator --cc --Mdir "${BUILD}/vdut" --prefix VDotTopDut --top-module VDotTop -Wno-fatal \
        "${YS}/build/vdot/VDotTop.sv"
    verilator --cc --Mdir "${BUILD}/ddut" --prefix DecodeProbeDut --top-module VdotDecodeProbe \
        -Wno-fatal "${XS}/build/vdot/VdotDecodeProbe.v"
    # verilator 运行时源码（verilated.cpp 等）要在容器里编译，Docker 只共享仓库目录，
    # 因此把它复制进 build/（已被 .gitignore 排除）
    local vroot
    vroot="$(verilator --getenv VERILATOR_ROOT)"
    rm -rf "${BUILD}/verilator"
    mkdir -p "${BUILD}/verilator"
    cp -R "${vroot}/include" "${BUILD}/verilator/"
    echo "verilator runtime <- ${vroot}/include"
    ls "${BUILD}/vdut" | head -3
    ls "${BUILD}/ddut" | head -3
}

# -----------------------------------------------------------------------------
# [4] 容器内编译
# -----------------------------------------------------------------------------
compile_cosim() {
    banner "[4] 容器内 g++ 编译协同仿真驱动"
    in_container '
set -euo pipefail
cd /work/tests/cosim
uname -m; g++ --version | head -1
make clean
make VERILATOR_INC=/work/tests/cosim/build/verilator/include
ls -l build/cosim
file build/cosim
'
}

# -----------------------------------------------------------------------------
# [5] 跑完整激励
# -----------------------------------------------------------------------------
run_campaign() {
    banner "[5] 协同仿真实跑"
    local vec_args=""
    for f in "${REPO_ROOT}"/tests/vectors/*.txt; do
        vec_args="${vec_args} --vectors /work/tests/vectors/$(basename "$f")"
    done
    vec_args="${vec_args} --vectors /work/tests/riscv/vdot/extra_vectors/vstart_range.txt"
    in_container "
set -euo pipefail
cd /work/tests/cosim
./build/cosim --so /work/work/NEMU/build/riscv64-nemu-interpreter-so \
  ${vec_args} --random ${RANDOM_N} --illegal ${ILLEGAL_N} --seed ${SEED} --dbg 6
"
}

# -----------------------------------------------------------------------------
# 故障注入
# -----------------------------------------------------------------------------
fault_injection() {
    banner "[T3] 故障注入自测：比对链路必须能检出人为错误"

    local SV="${YS}/build/vdot/VDotTop.sv"
    local VDOTC="${NEMU}/src/isa/riscv64/instr/rvv/vdot.c"
    cp -f "${SV}" "${BUILD}/VDotTop.sv.orig"
    cp -f "${VDOTC}" "${BUILD}/vdot.c.orig"
    # shellcheck disable=SC2064
    trap "echo '--- 异常退出，恢复源文件 ---'; cp -f '${BUILD}/VDotTop.sv.orig' '${SV}'; cp -f '${BUILD}/vdot.c.orig' '${VDOTC}'" EXIT

    inject() { # inject <file> <old> <new> <expect_count>
        python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
path, old, new, want = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
s = open(path).read()
n = s.count(old)
assert n == want, "注入点命中 %d 次，期望 %d 次 —— 源码已变动，拒绝假装注入成功" % (n, want)
open(path, 'w').write(s.replace(old, new))
print("注入成功：%s  (%d 处)" % (path, n))
PY
    }

    local LAST="${BUILD}/fi_last.txt"
    small_run() { # 跑一轮小规模协同仿真，输出存到 ${LAST}，返回 cosim 的真实退出码
        set +e
        in_container "
cd /work/tests/cosim
./build/cosim --so /work/work/NEMU/build/riscv64-nemu-interpreter-so \
  --vectors /work/tests/vectors/positive.txt \
  --vectors /work/tests/vectors/negative.txt \
  --vectors /work/tests/vectors/boundary.txt \
  --vectors /work/tests/vectors/vdotacc_boundary.txt \
  --vectors /work/tests/vectors/vdot4a_boundary.txt \
  --random 2000 --illegal 500 --seed ${SEED}
" > "${LAST}" 2>&1
        local rc=$?
        set -e
        grep -E '^TOTAL|^  \[A\]|^  \[B\]|^RESULT' "${LAST}" || tail -5 "${LAST}"
        return ${rc}
    }
    divergence() { grep -E '^RESULT\(LEGALITY\)' "${LAST}" | grep -oE '[0-9]+' | tail -1; }

    rebuild_nemu_so() {
        in_container '
set -euo pipefail
cd /work/work/NEMU
make riscv64-xs-kmhv2-ref_defconfig >/dev/null
make -j"$(nproc)" 2>&1 | tail -2
'
    }

    local detected=0 injections=0

    # ---------------- 基线 ----------------
    banner "[T3-BASE] 注入前基线（期望 RESULT(VALUE): PASS）"
    small_run || { echo "基线就不过，环境有问题"; exit 1; }
    local base_div
    base_div="$(divergence)"
    echo ">>> 基线：值比对 PASS，已知判定分歧 ${base_div} 条"

    # ---------------- RTL 侧注入 1：写回值翻一位 ----------------
    banner "[T3-RTL-1] 在生成的 VDotTop.sv 里把写回结果的 bit0 翻转"
    inject "${SV}" "  assign io_vd =" "  assign io_vd = 128'h1 ^" 1
    verilate >/dev/null
    compile_cosim >/dev/null
    injections=$((injections + 1))
    echo "--- 注入后实跑（期望 RESULT(VALUE): FAIL）---"
    if small_run; then
        echo ">>> T3-RTL-1 未被检出  => 比对链路失效，FAIL"
    else
        echo ">>> T3-RTL-1 被检出  => OK"
        detected=$((detected + 1))
    fi
    cp -f "${BUILD}/VDotTop.sv.orig" "${SV}"

    # ---------------- RTL 侧注入 2：tail-agnostic 填充值翻一位 ----------------
    banner "[T3-RTL-2] 把 vdot4a 最高元素的 tail-agnostic 填充 32'hFFFFFFFF 改成 32'hFFFFFFFE"
    inject "${SV}" "? (vtaS2 ? 32'hFFFFFFFF : oldVdS2[127:96])" \
                   "? (vtaS2 ? 32'hFFFFFFFE : oldVdS2[127:96])" 1
    verilate >/dev/null
    compile_cosim >/dev/null
    injections=$((injections + 1))
    echo "--- 注入后实跑（期望 RESULT(VALUE): FAIL）---"
    if small_run; then
        echo ">>> T3-RTL-2 未被检出  => FAIL"
    else
        echo ">>> T3-RTL-2 被检出  => OK"
        detected=$((detected + 1))
    fi
    cp -f "${BUILD}/VDotTop.sv.orig" "${SV}"
    verilate >/dev/null
    compile_cosim >/dev/null

    # ---------------- NEMU 侧注入 1：乘积翻一位 ----------------
    banner "[T3-NEMU-1] 在 NEMU 的 vdot.c 里把每个乘积的 bit0 翻转，并重建参考共享库"
    inject "${VDOTC}" "acc += (uint64_t)(a * b);" "acc += (uint64_t)(a * b) ^ 1;" 2
    rebuild_nemu_so
    injections=$((injections + 1))
    echo "--- 注入后实跑（期望 RESULT(VALUE): FAIL）---"
    if small_run; then
        echo ">>> T3-NEMU-1 未被检出  => FAIL"
    else
        echo ">>> T3-NEMU-1 被检出  => OK"
        detected=$((detected + 1))
    fi
    cp -f "${BUILD}/vdot.c.orig" "${VDOTC}"

    # ------- NEMU 侧注入 2：删掉 vstart!=0 的非法判定（裁定 S-1），考察非法判定通道 -------
    banner "[T3-NEMU-2] 删掉 vdot_reduce() 里的 check_vstart_exception()，破坏裁定 S-1"
    inject "${VDOTC}" "  check_vstart_exception(s);" "  /* injected: S-1 check removed */" 1
    rebuild_nemu_so
    injections=$((injections + 1))
    echo "--- 注入后实跑（本项考察的是非法判定通道：REF 不再抛异常，"
    echo "     vdot/vdotacc 的 vstart!=0 用例必然从「非法一致」翻成「RTL非法/REF合法」）---"
    small_run || true
    local inj_div
    inj_div="$(divergence)"
    echo ">>> 判定分歧：基线 ${base_div} 条 -> 注入后 ${inj_div} 条"
    if [ "${inj_div}" -gt "${base_div}" ]; then
        echo ">>> T3-NEMU-2 被检出  => OK"
        detected=$((detected + 1))
    else
        echo ">>> T3-NEMU-2 未被检出  => FAIL"
    fi

    # ---------------- 恢复 ----------------
    banner "[T3] 恢复源文件并重建"
    cp -f "${BUILD}/vdot.c.orig" "${VDOTC}"
    trap - EXIT
    rebuild_nemu_so
    echo "$ diff <(git -C ${NEMU} diff --stat -- src/isa/riscv64/instr/rvv/vdot.c)"
    ( cd "${NEMU}" && git status --short -- src/isa/riscv64/instr/rvv/vdot.c ) || true
    diff "${BUILD}/vdot.c.orig" "${VDOTC}" && echo "vdot.c 已恢复（diff 为空）"
    diff "${BUILD}/VDotTop.sv.orig" "${SV}" && echo "VDotTop.sv 已恢复（diff 为空）"
    echo "--- 恢复后复测（期望 RESULT(VALUE): PASS 且判定分歧回到 ${base_div} 条）---"
    if small_run; then
        echo ">>> 恢复后复测 PASS，判定分歧 $(divergence) 条"
    else
        echo ">>> 恢复后复测 FAIL —— 环境未回到干净状态！"
        exit 1
    fi
    echo
    echo "FAULT-INJECTION: ${detected}/${injections} 被检出"
    [ "${detected}" -eq "${injections}" ] || exit 1
}

# -----------------------------------------------------------------------------
case "${MODE}" in
all)
    {
        build_nemu_ref
        elaborate_rtl
        verilate
        compile_cosim
    } 2>&1 | tee "${LOG_DIR}/p6_build.log"
    run_campaign 2>&1 | tee "${LOG_DIR}/p6_cosim_run.log"
    echo
    echo "完成。日志："
    echo "  ${LOG_DIR}/p6_build.log"
    echo "  ${LOG_DIR}/p6_cosim_run.log"
    grep -E '^RESULT' "${LOG_DIR}/p6_cosim_run.log" || true
    ;;
fault)
    fault_injection 2>&1 | tee "${LOG_DIR}/p6_fault_injection.log"
    ;;
*)
    echo "unknown mode: ${MODE}（可选 all / fault）" >&2
    exit 1
    ;;
esac
