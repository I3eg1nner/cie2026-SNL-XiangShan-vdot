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
#   执行位置：
#     * Linux 宿主机（默认）：全部步骤直接在宿主机执行（NEMU .so 与宿主同架构，可直接 dlopen）。
#     * macOS：NEMU 的参考共享库是 linux ELF，必须在 Linux 里 dlopen，而 verilator / mill
#       装在宿主机上。于是「精化 + verilate」在宿主机做，「NEMU 构建 + 编译 + dlopen + 运行」
#       进 xsdev 容器（XS_RUNNER=docker，见 scripts/lib/common.sh）。
#
#   工作树：${WORK_DIR}/XiangShan-cosim（不存在时自动调用 scripts/04_make_vdot_trees.sh cosim 生成）
#   构建目录：${BUILD_ROOT}/cosim（默认 ${WORK_DIR}/build/cosim，不落进交付仓库）
#
#   用法：
#     ./scripts/30_run_cosim.sh                 # 构建 + 跑完整协同仿真
#     ./scripts/30_run_cosim.sh fault           # 故障注入自测（RTL 侧 3 次 + NEMU 侧 3 次）
#     FORCE_NEMU=1 ./scripts/30_run_cosim.sh    # 强制重建 NEMU 参考共享库
#
#   日志（${LOG_ROOT}/stage3/cosim/，LOG_ROOT 默认 logs/）：
#     p6_build.log / p6_cosim_run.log / p6_fault_injection.log
# =============================================================================
set -euo pipefail

MODE="${1:-all}"
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/common.sh"

XS="${XS_COSIM}"
YS="${XS}/yunsuan"
NEMU="${NEMU_DIR}"
COSIM="${REPO_ROOT}/tests/cosim"
BUILD="${BUILD_ROOT}/cosim"
LOG_DIR="${LOG_ROOT}/stage3/cosim"
NEMU_SO="${NEMU}/build/riscv64-nemu-interpreter-so"
PATCH="${REPO_ROOT}/nemu/patch/0001-add-vdot-instruction-family.patch"

RANDOM_N="${RANDOM_N:-10000}"
ILLEGAL_N="${ILLEGAL_N:-3000}"
SEED="${SEED:-20260324}"

mkdir -p "${LOG_DIR}" "${BUILD}"

[ -d "${NEMU}" ] || die "找不到 ${NEMU}，请先执行 scripts/00_setup_env_host.sh"
if [ ! -d "${XS}" ]; then
    info "找不到 ${XS}，调用 scripts/04_make_vdot_trees.sh cosim 生成"
    bash "${REPO_ROOT}/scripts/04_make_vdot_trees.sh" cosim
fi
setup_nemu_host_deps
load_host_env
need_cmd verilator
need_cmd java "JDK 17"
need_cmd mill "由 scripts/00_setup_env_host.sh 安装到 \${WORK_DIR}/tools/mill"
need_cmd python3

banner() {
    echo "=============================================================="
    echo " $*   $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
    echo "=============================================================="
}

in_container() {   # 名字沿用旧版；实际按 XS_RUNNER 在宿主机或容器内执行
    xrun "$1"
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
    in_container "
cd '${NEMU}'
echo '\$ git log --oneline -1'; git log --oneline -1
if git apply --check --reverse '${PATCH}' >/dev/null 2>&1; then
  echo 'vdot patch 已处于已应用状态，跳过'
elif git apply --check '${PATCH}' >/dev/null 2>&1; then
  git apply '${PATCH}'
  echo 'vdot patch 应用成功'
else
  echo 'ERROR: patch 既不能正向应用也不是已应用状态'; git status --short; exit 1
fi
make riscv64-xs-kmhv2-ref_defconfig
grep -n CONFIG_CUSTOM_XVDOT include/generated/autoconf.h
make -j${JOBS} 2>&1 | tail -5
ls -l build/riscv64-nemu-interpreter-so
file build/riscv64-nemu-interpreter-so
ls -l build/obj-riscv64-nemu-interpreter-so/src/isa/riscv64/instr/rvv/vdot.o
nm -D --defined-only build/riscv64-nemu-interpreter-so | grep -E 'difftest_init\$|difftest_exec\$|difftest_regcpy\$|difftest_memcpy\$|DIFFTEST_REG_SIZE'
"
}

# -----------------------------------------------------------------------------
# [2] mill 精化出两个被测模块
# -----------------------------------------------------------------------------
elaborate_rtl() {
    banner "[2] 从 ${XS} 精化 RTL"
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
    banner "[3] verilator --cc（宿主机 $(verilator --version | awk '{print $1, $2}')）"
    rm -rf "${BUILD}/vdut" "${BUILD}/ddut"
    verilator --cc --Mdir "${BUILD}/vdut" --prefix VDotTopDut --top-module VDotTop -Wno-fatal \
        "${YS}/build/vdot/VDotTop.sv"
    verilator --cc --Mdir "${BUILD}/ddut" --prefix DecodeProbeDut --top-module VdotDecodeProbe \
        -Wno-fatal "${XS}/build/vdot/VdotDecodeProbe.v"
    # verilator 运行时源码（verilated.cpp 等）要在执行环境里编译；容器模式下宿主机的
    # verilator 安装目录不在挂载范围内，因此统一复制一份到 ${BUILD}/verilator
    local vroot
    vroot="$(verilator --getenv VERILATOR_ROOT)"
    rm -rf "${BUILD}/verilator"
    mkdir -p "${BUILD}/verilator"
    cp -R "${vroot}/include" "${BUILD}/verilator/"
    echo "verilator runtime <- ${vroot}/include"
    ls "${BUILD}/vdut" | head -3 || true
    ls "${BUILD}/ddut" | head -3 || true
}

# -----------------------------------------------------------------------------
# [4] 容器内编译
# -----------------------------------------------------------------------------
compile_cosim() {
    banner "[4] g++ 编译协同仿真驱动（执行环境：${XS_RUNNER}）"
    in_container "
cd '${COSIM}'
uname -m; g++ --version | head -1
make clean BUILD='${BUILD}'
make -j${JOBS} BUILD='${BUILD}' VERILATOR_INC='${BUILD}/verilator/include'
ls -l '${BUILD}/cosim'
file '${BUILD}/cosim'
"
}

# -----------------------------------------------------------------------------
# [5] 跑完整激励
# -----------------------------------------------------------------------------
run_campaign() {
    banner "[5] 协同仿真实跑"
    local vec_args=""
    for f in "${REPO_ROOT}"/tests/vectors/*.txt; do
        vec_args="${vec_args} --vectors ${f}"
    done
    vec_args="${vec_args} --vectors ${REPO_ROOT}/tests/riscv/vdot/extra_vectors/vstart_range.txt"
    in_container "
cd '${COSIM}'
'${BUILD}/cosim' --so '${NEMU_SO}' \
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
cd '${COSIM}'
'${BUILD}/cosim' --so '${NEMU_SO}' \
  --vectors '${REPO_ROOT}/tests/vectors/positive.txt' \
  --vectors '${REPO_ROOT}/tests/vectors/negative.txt' \
  --vectors '${REPO_ROOT}/tests/vectors/boundary.txt' \
  --vectors '${REPO_ROOT}/tests/vectors/vdotacc_boundary.txt' \
  --vectors '${REPO_ROOT}/tests/vectors/vdot4a_boundary.txt' \
  --random 2000 --illegal 500 --seed ${SEED}
" > "${LAST}" 2>&1
        local rc=$?
        set -e
        grep -E '^TOTAL|^  \[A\]|^  \[B\]|^RESULT' "${LAST}" || tail -5 "${LAST}"
        return ${rc}
    }
    divergence() { grep -E '^RESULT\(LEGALITY\)' "${LAST}" | grep -oE '[0-9]+' | tail -1; }

    rebuild_nemu_so() {
        in_container "
cd '${NEMU}'
make riscv64-xs-kmhv2-ref_defconfig >/dev/null
make -j${JOBS} 2>&1 | tail -2
"
    }

    local detected=0 injections=0

    # ---------------- 基线 ----------------
    banner "[T3-BASE] 注入前基线（期望 RESULT(VALUE): PASS）"
    small_run || { echo "基线就不过，环境有问题"; exit 1; }
    local base_div
    base_div="$(divergence)"
    echo ">>> 基线：值比对 PASS，已知判定分歧 ${base_div} 条"

    # ---------------- RTL 侧注入 1：输出格式选择取反 ----------------
    # 历史说明：此项早期被描述为「写回结果 bit0 翻转」，但生成的 VDotTop.sv 中 io_vd 是
    # `isDot4aS2 ? {...} : ...` 条件表达式，Verilog 的 `^` 优先级高于 `?:`，实际得到
    # `(128'h1 ^ isDot4aS2) ? ... : ...`，即 vdot4a 格式与归约格式互换（verilator 的
    # WIDTHEXPAND / WIDTHTRUNC 警告即旁证）。注入文本保持不变，以便与存档结果对照；
    # 真正的 bit0 翻转见下面的 T3-RTL-1b。
    banner "[T3-RTL-1] 在生成的 VDotTop.sv 里把 io_vd 的输出格式选择取反（vdot4a 格式与归约格式互换）"
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

    # ---------------- RTL 侧注入 1b：写回结果真正的 bit0 翻转 ----------------
    banner "[T3-RTL-1b] 把整个 io_vd 表达式加括号后与 128'h1 异或（写回结果 bit0 翻转）"
    python3 - "${SV}" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
head = "  assign io_vd ="
assert s.count(head) == 1, "注入点命中 %d 次，期望 1 次 —— 源码已变动，拒绝假装注入成功" % s.count(head)
i = s.index(head); j = s.index(';', i)
s = s[:i] + head + " 128'h1 ^ (" + s[i + len(head):j] + ");" + s[j + 1:]
open(p, 'w').write(s)
print("注入成功：%s  (1 处，整个 io_vd 表达式加括号后与 128'h1 异或)" % p)
PY
    verilate >/dev/null
    compile_cosim >/dev/null
    injections=$((injections + 1))
    echo "--- 注入后实跑（期望 RESULT(VALUE): FAIL）---"
    if small_run; then
        echo ">>> T3-RTL-1b 未被检出  => 比对链路失效，FAIL"
    else
        echo ">>> T3-RTL-1b 被检出  => OK"
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

    # ------- NEMU 侧注入 2：删掉归约形态 vstart!=0 的非法判定（裁定 S-1） -------
    banner "[T3-NEMU-2] 删掉 vdot_reduce() 里的 check_vstart_exception()，破坏裁定 S-1"
    # 注意锚点要带上函数头：裁定 S-7' 之后 vdot4a_exec() 里也有一行
    # check_vstart_exception(s);，裸字符串会命中两处。
    inject "${VDOTC}" \
        "static void vdot_reduce(Decode *s, int accumulate) {
  check_vstart_exception(s);" \
        "static void vdot_reduce(Decode *s, int accumulate) {
  /* injected: S-1 check removed */" 1
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
    cp -f "${BUILD}/vdot.c.orig" "${VDOTC}"

    # ------- NEMU 侧注入 3：删掉 vdot4a 的 vstart!=0 判定（裁定 S-7'）-------
    # 这一项直接守护本次语义收敛的成果：S-7' 一旦被回退，协同仿真必须立刻报出
    # 「RTL 非法 / REF 合法」的分歧 —— 这正是 §7.3 当初发现 G5b 的那条通路。
    banner "[T3-NEMU-3] 删掉 vdot4a_exec() 里的 check_vstart_exception()，回退裁定 S-7'"
    inject "${VDOTC}" \
        "  check_vstart_exception(s);   // 裁定 S-7'：vstart != 0 -> Illegal Instruction" \
        "  /* injected: S-7' check removed (回退到原裁定 S-7) */" 1
    rebuild_nemu_so
    injections=$((injections + 1))
    echo "--- 注入后实跑（期望判定分歧由 ${base_div} 条上升：vdot4a 且 vstart!=0 的用例"
    echo "     会从「非法一致」翻成「RTL非法/REF合法」）---"
    small_run || true
    local inj3_div
    inj3_div="$(divergence)"
    echo ">>> 判定分歧：基线 ${base_div} 条 -> 注入后 ${inj3_div} 条"
    if [ "${inj3_div}" -gt "${base_div}" ]; then
        echo ">>> T3-NEMU-3 被检出  => OK（证明 S-7' 的收敛是被实测守住的，不是口头约定）"
        detected=$((detected + 1))
    else
        echo ">>> T3-NEMU-3 未被检出  => FAIL"
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
