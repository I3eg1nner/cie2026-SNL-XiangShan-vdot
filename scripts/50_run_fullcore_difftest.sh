#!/usr/bin/env bash
# =============================================================================
# 50_run_fullcore_difftest.sh —— 赛题 3.1.2 全核 difftest 一键复现（HANDOFF T1）
#
#   DUT：打了 vdot 补丁的香山昆明湖V2 全核（MinimalConfig，Verilator emu，带 difftest）
#   REF：打了 vdot 补丁的 NEMU，riscv64-xs-kmhv2-ref_defconfig 构建的 riscv64-nemu-interpreter-so
#   每提交一条指令，difftest 比对整数 / 浮点 / 向量寄存器堆、CSR（含 vstart/vl/vtype、
#   mcause/mepc/mtval）与访存，失配立即中止并打印双方状态。
#
#   步骤：
#     [0] 生成专用全核工作树 ${WORK_DIR}/XiangShan-fullcore
#         = XiangShan-kmhv2（a4eeaab）副本 + rtl/patch/0001（XS）+ rtl/patch/0002（yunsuan）
#     [1] 私有 NEMU 副本 ${WORK_DIR}/NEMU-fullcore（不触碰共享的 work/NEMU/.config），
#         确认 vdot 补丁已应用，按 ref_defconfig 构建 .so
#     [2] make emu（MinimalConfig，EMU_TRACE=1，EMU_THREADS=16）
#     [3] 交叉编译测试镜像（tests/riscv/fullcore/）
#     [4] 语料批次：全部定向 + 3×10000 随机 + 必须 trap 的非法用例，切成 ${BATCHES} 批并行跑
#     [5] 依赖测试：vdot 与其他向量指令背靠背（RAW/WAR/WAW、掩码、访存、异常、分支冲刷）
#     [6] 波形：最小程序上抓 vdot 从译码到 ROB 提交的窗口，导出文本轨迹
#   fault 模式：在 ${WORK_DIR}/XiangShan-fullcore-fault 中把 VIMacU 的 vdot 结果 bit0 翻转，
#         重建 emu，期望 difftest 报错；随后还原源码并核对与全核树一致。
#
#   用法：
#     bash scripts/50_run_fullcore_difftest.sh            # [0]..[5]（波形与故障注入另行执行）
#     bash scripts/50_run_fullcore_difftest.sh build      # 只做 [0]..[2]
#     bash scripts/50_run_fullcore_difftest.sh run        # 只做 [3]..[5]（要求 emu 已构建）
#     bash scripts/50_run_fullcore_difftest.sh wave       # 只做 [6]
#     bash scripts/50_run_fullcore_difftest.sh fault      # 故障注入
#
#   可调参数（环境变量）：
#     FC_CONFIG=MinimalConfig  EMU_THREADS=16  JVM_XMX=200G  BUILD_JOBS=${JOBS}
#     BATCHES=6（语料分批数，与依赖测试一起并行运行；每个 emu 进程 EMU_THREADS 个线程）
#     DEP_ITERS=200  WAVE_BEGIN=0 WAVE_END=2000（波形窗口，单位：周期）
#     PLOT_PYTHON（装有 matplotlib 的 Python，用于渲染时序图；缺省时跳过绘图）
#     FC_LOG_DIR（默认 ${LOG_ROOT}/stage3/fullcore；已存在的同名日志不会被覆盖，改写到带时间戳的子目录）
#
#   C++ 编译器：默认 clang++（CXX/LINK 覆盖 verilated.mk 中的 g++）。上游 difftest 的
#         OPT_FAST 默认带 clang 专有选项 -fno-slp-vectorize（difftest/verilator.mk:76），
#         而且实测 g++ 11.4 -O3 编译 Verilator 生成的一个 15.9 MB 单函数文件超过 85 分钟未结束、
#         clang++ 14 只需 1m48s。没有 clang++ 时退回 g++ 并把 OPT_FAST 换成 GCC 等价选项。
#   资源：MinimalConfig 实测耗时与峰值内存见 docs/stage3/23_全核difftest验证报告.md §3。
#   日志：emu 退出时打印数万行 [PERF ] 性能计数器，归档日志中过滤掉这些行（其余输出原样保留）。
# =============================================================================
set -euo pipefail

MODE="${1:-all}"
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/common.sh"

XS="${WORK_DIR}/XiangShan-fullcore"
XS_FAULT="${WORK_DIR}/XiangShan-fullcore-fault"
NEMU_FC="${WORK_DIR}/NEMU-fullcore"
NEMU_SO="${NEMU_FC}/ref/riscv64-nemu-interpreter-so"
TESTS="${REPO_ROOT}/tests/riscv/fullcore"
BUILD="${BUILD_ROOT}/fullcore"

P_XS="${REPO_ROOT}/rtl/patch/0001-xiangshan-vdot.patch"
P_YS="${REPO_ROOT}/rtl/patch/0002-yunsuan-vdot.patch"
P_NEMU="${REPO_ROOT}/nemu/patch/0001-add-vdot-instruction-family.patch"

FC_CONFIG="${FC_CONFIG:-MinimalConfig}"
EMU_THREADS="${EMU_THREADS:-16}"
JVM_XMX="${JVM_XMX:-200G}"
BUILD_JOBS="${BUILD_JOBS:-${JOBS}}"
BATCHES="${BATCHES:-6}"
DEP_ITERS="${DEP_ITERS:-200}"
# 依赖测试的随机种子：第一个与语料批次同轮运行，其余在第二轮并行运行
DEP_SEEDS="${DEP_SEEDS:-0x20261025cafef00d 0x0000000000c1e026 0x5eed00000000beef 0x0123456789abcdef}"

FC_LOG_DIR="${FC_LOG_DIR:-${LOG_ROOT}/stage3/fullcore}"
mkdir -p "${FC_LOG_DIR}" "${BUILD}"
# 不覆盖已有日志：目标文件已存在时，本次运行的日志改写到带时间戳的子目录
newlog() {   # newlog <文件名> -> 打印本次应写入的路径
  local f="${FC_LOG_DIR}/$1"
  if [ -e "${f}" ]; then
    local d="${FC_LOG_DIR}/rerun_${RUN_STAMP}"
    mkdir -p "${d}"; f="${d}/$1"
  fi
  echo "${f}"
}
RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

banner() {
  echo "=============================================================="
  echo " $*   $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
  echo "=============================================================="
}

[ "${XS_RUNNER}" = "host" ] || die "全核 difftest 只支持在 Linux x86_64 宿主机上运行（XS_RUNNER=host）"
need_cmd rsync
need_cmd git
need_cmd verilator
need_cmd python3
load_host_env
detect_cross

# -----------------------------------------------------------------------------
# [0] 全核工作树
# -----------------------------------------------------------------------------
patched() { git -C "$1" apply --check --reverse "$2" >/dev/null 2>&1; }

make_tree() {
  banner "[0] 全核工作树 $(relpath "${XS}")"
  if [ -d "${XS}" ]; then
    patched "${XS}" "${P_XS}" && patched "${XS}/yunsuan" "${P_YS}" \
      || die "${XS} 已存在但补丁状态不符；确认无用后删除再重跑"
    info "已存在，两份补丁均处于已应用状态"
    return 0
  fi
  [ -f "${XS_PRISTINE}/yunsuan/build.sc" ] || die "找不到纯净基线 ${XS_PRISTINE}，请先执行 scripts/00_setup_env_host.sh"
  local tmp="${XS}.tmp.$$"
  rm -rf "${tmp}"
  rsync -a --exclude '/out/' --exclude '/build/' --exclude '/yunsuan/out/' --exclude '/yunsuan/build/' \
    "${XS_PRISTINE}/" "${tmp}/"
  git -C "${tmp}" checkout -- .
  git -C "${tmp}/yunsuan" checkout -- .
  git -C "${tmp}" apply "${P_XS}"
  git -C "${tmp}/yunsuan" apply "${P_YS}"
  mv "${tmp}" "${XS}"
  info "基线 $(git -C "${XS}" rev-parse --short HEAD) + $(relpath "${P_XS}") + $(relpath "${P_YS}")"
  git -C "${XS}" status --short | sed 's/^/    XiangShan: /'
  git -C "${XS}/yunsuan" status --short | sed 's/^/    yunsuan  : /'
}

# -----------------------------------------------------------------------------
# [1] 私有 NEMU 副本 + ref .so
# -----------------------------------------------------------------------------
build_nemu_ref() {
  banner "[1] NEMU 参考共享库（私有副本 $(relpath "${NEMU_FC}")）"
  setup_nemu_host_deps
  if [ ! -d "${NEMU_FC}" ]; then
    [ -d "${NEMU_DIR}/src" ] || die "找不到 ${NEMU_DIR}"
    rsync -a --exclude '/build/' "${NEMU_DIR}/" "${NEMU_FC}/"
  fi
  if patched "${NEMU_FC}" "${P_NEMU}"; then
    info "vdot 补丁已处于已应用状态"
  else
    git -C "${NEMU_FC}" apply --check "${P_NEMU}" || die "NEMU 补丁无法应用"
    git -C "${NEMU_FC}" apply "${P_NEMU}"
  fi
  if [ -z "${FORCE_NEMU:-}" ] && [ -f "${NEMU_SO}" ] && \
     [ "${NEMU_SO}" -nt "${NEMU_FC}/src/isa/riscv64/instr/rvv/vdot.c" ]; then
    info "已存在：${NEMU_SO}（FORCE_NEMU=1 可强制重建）"
  else
    ( cd "${NEMU_FC}" && export NEMU_HOME="${NEMU_FC}" &&
      make riscv64-xs-kmhv2-ref_defconfig >/dev/null &&
      grep -n 'CONFIG_CUSTOM_XVDOT' include/generated/autoconf.h &&
      make -j"${JOBS}" >/dev/null )
    mkdir -p "$(dirname "${NEMU_SO}")"
    cp -f "${NEMU_FC}/build/riscv64-nemu-interpreter-so" "${NEMU_SO}"
  fi
  ls -l "${NEMU_SO}"
  echo "NEMU commit: $(git -C "${NEMU_FC}" log --oneline -1)"
  nm -D --defined-only "${NEMU_SO}" | grep -cE ' difftest_' | sed 's/^/difftest_* 导出符号数: /'
}

# -----------------------------------------------------------------------------
# [2] 全核 emu
# -----------------------------------------------------------------------------
build_emu_in() {   # build_emu_in <树> <日志>
  local tree="$1" log="$2"
  local cxx_args=(CXX=clang++ LINK=clang++)
  if ! command -v clang++ >/dev/null 2>&1; then
    warn "找不到 clang++，退回 g++（Verilator 生成的超大函数在 g++ -O3 下可能编译数小时）"
    cxx_args=(OPT_FAST="-O3 -fno-tree-slp-vectorize")
  fi
  (
    cd "${tree}"
    export NOOP_HOME="${tree}"
    {
      date -R
      echo "host: $(nproc) cores, $(free -g | awk '/Mem/{print $2}') GB"
      verilator --version; java -version 2>&1 | head -1
      echo "cmd: make emu CONFIG=${FC_CONFIG} EMU_THREADS=${EMU_THREADS} EMU_TRACE=1 JVM_XMX=${JVM_XMX} WITH_CHISELDB=0 WITH_CONSTANTIN=0 ${cxx_args[*]} -j${BUILD_JOBS}"
      local rc=0
      /usr/bin/time -v make emu CONFIG="${FC_CONFIG}" EMU_THREADS="${EMU_THREADS}" EMU_TRACE=1 \
        JVM_XMX="${JVM_XMX}" WITH_CHISELDB=0 WITH_CONSTANTIN=0 "${cxx_args[@]}" -j"${BUILD_JOBS}" || rc=$?
      echo "exit=${rc}"
      date -R
    } > "${log}" 2>&1
  )
  grep -q '^exit=0' "${log}" || die "emu 构建失败，见 ${log}"
}

build_emu() {
  banner "[2] 构建全核 emu（${FC_CONFIG}）"
  if [ -x "${XS}/build/emu" ] && [ -z "${FORCE_EMU:-}" ]; then
    info "已存在：${XS}/build/emu（FORCE_EMU=1 可强制重建）"
  else
    local log; log="$(newlog build_emu.log)"
    info "构建日志：$(relpath "${log}")（MinimalConfig 在 128 核机器上实测约 23 分钟，峰值内存约 59 GB）"
    build_emu_in "${XS}" "${log}"
  fi
  ls -l "${XS}/build/emu"
}

# -----------------------------------------------------------------------------
# [3] 测试镜像
# -----------------------------------------------------------------------------
build_images() {
  banner "[3] 交叉编译测试镜像（CROSS=${CROSS}）"
  local mk=(make -s -C "${TESTS}" BUILD="${BUILD}" CROSS="${CROSS}" NEMU_HOME="${NEMU_FC}")
  "${mk[@]}" corpus-full
  local total
  total="$(python3 -c "import struct,sys;print(struct.unpack_from('<I',open(sys.argv[1],'rb').read(),8)[0])" "${BUILD}/corpus_full.bin")"
  local per=$(( (total + BATCHES - 1) / BATCHES )) i b e
  for ((i = 0; i < BATCHES; i++)); do
    b=$((i * per)); e=$(((i + 1) * per)); [ "${e}" -gt "${total}" ] && e="${total}"
    "${mk[@]}" corpus-batch NAME="$(printf 'b%02d' "${i}")" BEGIN="${b}" END="${e}" 2>&1 | grep -v 'RWX permissions' || true
  done
  local j=0 sd
  for sd in ${DEP_SEEDS}; do
    "${mk[@]}" dep DEP_ITERS="${DEP_ITERS}" DEP_SEED="${sd}" DEP_NAME="dep${j}" 2>&1 | grep -v 'RWX permissions' || true
    j=$((j + 1))
  done
  "${mk[@]}" wave 2>&1 | grep -v 'RWX permissions' || true
  ls -l "${BUILD}"/b*/vdot_test.bin "${BUILD}"/dep*/vdot_dep.bin "${BUILD}/wave/vdot_wave.bin"
}

# -----------------------------------------------------------------------------
# 运行一个镜像：emu -i <bin> --diff <so>
# -----------------------------------------------------------------------------
run_emu() {   # run_emu <emu> <bin> <日志> [额外参数...]
  local emu="$1" bin="$2" log="$3"; shift 3
  {
    echo "\$ ${emu} -i ${bin} --diff ${NEMU_SO} $*"
    echo "start: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local t0 t1 rc=0
    t0=$(date +%s)
    echo "（下面先是 emu 的 stdout，再是 stderr；stderr 中 emu 退出时打印的 [PERF ] 性能计数器行已滤掉）"
    local errf; errf="$(mktemp_f emu_stderr)"
    "${emu}" -i "${bin}" --diff "${NEMU_SO}" "$@" 2> "${errf}" || rc=$?
    echo "------------------------------ emu stderr ------------------------------"
    grep -av '^\[PERF \]' "${errf}" || true
    rm -f "${errf}"
    t1=$(date +%s)
    echo "end: $(date -u '+%Y-%m-%dT%H:%M:%SZ')  wall=$((t1 - t0))s  emu-exit=${rc}"
  } > "${log}" 2>&1
}

summarize_corpus() {   # 从各批日志汇总
  local d="$1" f n_total=0 n_pass=0 n_fail=0 n_trap=0 n_trapok=0 good=0 nb=0
  printf '%-6s %8s %8s %6s %10s %12s  %s\n' batch cases pass fail must-trap trapped-ok emu
  for f in "${d}"/corpus_b*.log; do
    nb=$((nb + 1))
    local line tl c p fl t to g
    line="$(grep -a '^TOTAL cases=' "${f}" | tail -1)"
    tl="$(grep -a 'must-trap cases' "${f}" | tail -1)"
    c="$(sed -E 's/.*cases=([0-9]+).*/\1/' <<<"${line}")"
    p="$(sed -E 's/.*pass=([0-9]+).*/\1/' <<<"${line}")"
    fl="$(sed -E 's/.*fail=([0-9]+).*/\1/' <<<"${line}")"
    t="$(sed -E 's/.*= ([0-9]+) ,.*/\1/' <<<"${tl}")"
    to="$(sed -E 's/.*mcause=2 = ([0-9]+).*/\1/' <<<"${tl}")"
    if grep -aq 'HIT GOOD TRAP' "${f}"; then g="HIT_GOOD_TRAP"; good=$((good + 1)); else g="NOT_GOOD"; fi
    printf '%-6s %8s %8s %6s %10s %12s  %s\n' "$(basename "${f}" .log | sed 's/corpus_//')" "${c:-?}" "${p:-?}" "${fl:-?}" "${t:-?}" "${to:-?}" "${g}"
    n_total=$((n_total + ${c:-0})); n_pass=$((n_pass + ${p:-0})); n_fail=$((n_fail + ${fl:-0}))
    n_trap=$((n_trap + ${t:-0})); n_trapok=$((n_trapok + ${to:-0}))
  done
  echo "CORPUS TOTAL cases=${n_total} pass=${n_pass} fail=${n_fail} must-trap=${n_trap} trapped-mcause2=${n_trapok} batches=${nb} hit-good-trap=${good}/${nb}"
  echo "difftest 失配报告行数（'different at' / 'ABORT'）：$(cat "${d}"/corpus_b*.log | grep -acE 'different at|ABORT' || true)"
}

run_tests() {
  banner "[4] 语料批次（${BATCHES} 批并行，DUT=${XS}/build/emu）"
  local d; d="$(dirname "$(newlog corpus_b00.log)")"
  local i pids=()
  for ((i = 0; i < BATCHES; i++)); do
    local n; n="$(printf 'b%02d' "${i}")"
    run_emu "${XS}/build/emu" "${BUILD}/${n}/vdot_test.bin" "${d}/corpus_${n}.log" &
    pids+=($!)
  done
  banner "[5] 依赖测试（DEP_ITERS=${DEP_ITERS}，种子：${DEP_SEEDS}）"
  info "第一轮：dep0 与 ${BATCHES} 个语料批次同时运行"
  run_emu "${XS}/build/emu" "${BUILD}/dep0/vdot_dep.bin" "${d}/dep0.log" &
  pids+=($!)
  for p in "${pids[@]}"; do wait "${p}" || true; done
  local j=0 sd
  pids=()
  info "第二轮：其余种子并行运行"
  for sd in ${DEP_SEEDS}; do
    if [ "${j}" -gt 0 ]; then
      run_emu "${XS}/build/emu" "${BUILD}/dep${j}/vdot_dep.bin" "${d}/dep${j}.log" &
      pids+=($!)
    fi
    j=$((j + 1))
  done
  for p in "${pids[@]}"; do wait "${p}" || true; done
  summarize_corpus "${d}" | tee "${d}/summary.log"
  {
    local f
    for f in "${d}"/dep[0-9]*.log; do
      echo "--- $(basename "${f}") ---"
      grep -aE 'seed=|^DEP TOTAL|^RESULT|HIT GOOD TRAP|ABORT|different at|instrCnt|wall=' "${f}"
    done
  } | tee -a "${d}/summary.log"
}

# -----------------------------------------------------------------------------
# [6] 波形
# -----------------------------------------------------------------------------
run_wave() {
  banner "[6] 全核波形（vdot 从译码到 ROB 提交）"
  local d; d="$(dirname "$(newlog wave_run.log)")"
  local vcd="${BUILD}/wave/vdot_wave.vcd"
  # 先不抓波形跑一遍，拿到被测指令的提交周期
  # 先不抓波形跑一遍：逐条提交轨迹 + HIT GOOD TRAP
  run_emu "${XS}/build/emu" "${BUILD}/wave/vdot_wave.bin" "${d}/wave_run.log" --dump-commit-trace
  grep -aq 'HIT GOOD TRAP' "${d}/wave_run.log" || die "波形程序未 HIT GOOD TRAP，见 ${d}/wave_run.log"
  rm -f "${vcd}"
  local b="${WAVE_BEGIN:-0}" e="${WAVE_END:-2000}"
  run_emu "${XS}/build/emu" "${BUILD}/wave/vdot_wave.bin" "${d}/wave_dump.log" \
    --dump-wave -b "${b}" -e "${e}" --wave-path "${vcd}"
  ls -l "${vcd}" | tee -a "${d}/wave_dump.log"
  python3 "${TESTS}/wave_trace.py" "${vcd}" > "${d}/wave_trace.txt"
  info "文本轨迹：$(relpath "${d}/wave_trace.txt")（VCD 体积大，不入库：${vcd}）"
  # 可选：渲染时序图（需要 matplotlib；PLOT_PYTHON 指向装有 matplotlib 的解释器）
  local py="${PLOT_PYTHON:-${PYTHON}}"
  if "${py}" -c 'import matplotlib' >/dev/null 2>&1; then
    local P=TOP.SimTop.cpu.l_soc.core_with_l2.core.backend
    local IQ0="${P}.inner_vfScheduler.IssueQueueVfmaVialuFixVimacVppuVfaluVfcvtVipuVsetrvfwvf"
    local MAC="${P}.inner_vfExuBlock.exus.Vimac"
    "${py}" "${REPO_ROOT}/scripts/tools/vcd_plot.py" --vcd "${vcd}" --out "${d}/wave_fullcore_vdot.png" \
      --from "${PLOT_FROM:-1483}" --to "${PLOT_TO:-1516}" \
      --title "全核 MinimalConfig：vadd → vdot → vdotacc → vdot4a 背靠背（RAW 链）" \
      --subtitle "以 vdot（robIdx=22）为例：1494 发射 → 1497 进 VIMacU → 1499 写回 → 1501 提交；同拍 vdotacc 发射" \
      --xlabel "emu 周期号（--dump-wave 每周期记录一个时间点，VCD 时刻 = 周期号）" \
      --mark "1494|发射" --mark "1497|进FU" --mark "1499|写回" --mark "1501|提交" \
      --signal "${P}.inner_ctrlBlock.decode.io_out_0_valid|decode.out0.valid|wave" \
      --signal "${P}.inner_ctrlBlock.decode.io_out_0_bits_instr|decode.out0.instr|hex" \
      --signal "${P}.inner_ctrlBlock.rob.io_enq_req_0_valid|rob.enq0.valid|wave" \
      --signal "${IQ0}.io_deqDelay_0_valid|IQ0.issue.valid|wave" \
      --signal "${IQ0}.io_deqDelay_0_bits_common_robIdx_value|IQ0.issue.robIdx|dec" \
      --signal "${P}.inner_vfExuBlock.exus_2.VialuFix.io_out_valid|VialuFix.out.valid (vadd)|wave" \
      --signal "${MAC}.io_in_valid|Vimac.in.valid|wave" \
      --signal "${MAC}.io_in_bits_ctrl_fuOpType|Vimac.in.fuOpType|hex" \
      --signal "${MAC}.io_out_valid|Vimac.out.valid|wave" \
      --signal "${MAC}.io_out_bits_res_data|Vimac.out.res|hex2" \
      --signal "${P}.inner_ctrlBlock.rob.io_commits_commitValid_0|rob.commit0.valid|wave" \
      --signal "${P}.inner_ctrlBlock.rob.io_commits_info_0_debug_instr|rob.commit0.instr|hex" 2>&1 | grep -v findfont || true
  else
    warn "${py} 没有 matplotlib，跳过时序图（文本轨迹已生成）"
  fi
}

# -----------------------------------------------------------------------------
# fault：VIMacU 的 vdot 结果 bit0 翻转
# -----------------------------------------------------------------------------
FAULT_FILE="src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala"
FAULT_ORIG='  private val dotVd = vdotTree.io.dotVd'
FAULT_BAD='  private val dotVd = vdotTree.io.dotVd ^ 1.U  // FAULT-INJECTION T1-F1: flip bit0 of the vdot result'

run_fault() {
  banner "[F] 故障注入：${FAULT_FILE} 中 vdot 结果 bit0 翻转"
  local d; d="$(dirname "$(newlog fault_run.log)")"
  if [ ! -d "${XS_FAULT}" ]; then
    rsync -a --exclude '/out/' --exclude '/build/' "${XS}/" "${XS_FAULT}/"
  fi
  local f="${XS_FAULT}/${FAULT_FILE}"
  if ! grep -qxF "${FAULT_BAD}" "${f}"; then
    [ "$(grep -cxF "${FAULT_ORIG}" "${f}")" = 1 ] || die "注入点命中次数不是 1，源码已变动，拒绝假装注入成功"
    python3 - "${f}" "${FAULT_ORIG}" "${FAULT_BAD}" <<'PY'
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
assert s.count(a + "\n") == 1
open(p, "w").write(s.replace(a + "\n", b + "\n"))
PY
  fi
  diff "${XS}/${FAULT_FILE}" "${f}" | tee "${d}/fault_diff.txt" || true
  if [ ! -x "${XS_FAULT}/build/emu" ] || [ -n "${FORCE_EMU:-}" ]; then
    build_emu_in "${XS_FAULT}" "$(newlog build_emu_fault.log)"
  fi
  local rc=0
  run_emu "${XS_FAULT}/build/emu" "${BUILD}/wave/vdot_wave.bin" "${d}/fault_wave.log"
  run_emu "${XS_FAULT}/build/emu" "${BUILD}/dep0/vdot_dep.bin" "${d}/fault_dep.log"
  run_emu "${XS_FAULT}/build/emu" "${BUILD}/b00/vdot_test.bin" "${d}/fault_corpus_b00.log"
  {
    local x
    for x in fault_wave fault_dep fault_corpus_b00; do
      if grep -aq 'HIT GOOD TRAP' "${d}/${x}.log"; then
        echo "${x}: 未检出（HIT GOOD TRAP）"
      else
        echo "${x}: 检出 —— $(grep -anE 'ABORT|different at' "${d}/${x}.log" | head -3 | tr '\n' ' ')"
      fi
    done
    # 还原：源码改回，与全核树逐字节一致
    python3 - "${f}" "${FAULT_BAD}" "${FAULT_ORIG}" <<'PY'
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
open(p, "w").write(s.replace(a + "\n", b + "\n"))
PY
    if cmp "${XS}/${FAULT_FILE}" "${f}"; then echo "还原：${FAULT_FILE} 与全核树逐字节一致"; else echo "还原失败"; fi
  } | tee "${d}/fault_summary.log"
  if grep -qE '未检出|还原失败' "${d}/fault_summary.log"; then rc=1; fi
  echo "FAULT-INJECTION: $(grep -c ': 检出' "${d}/fault_summary.log") / 3 个程序检出" | tee -a "${d}/fault_summary.log"
  return "${rc}"
}

case "${MODE}" in
  build) make_tree; build_nemu_ref; build_emu ;;
  run)   build_nemu_ref; build_images; run_tests ;;
  wave)  build_images; run_wave ;;
  fault) build_nemu_ref; build_images; run_fault ;;
  all)   make_tree; build_nemu_ref; build_emu; build_images; run_tests ;;
  *) die "未知模式 ${MODE}（可选 all / build / run / wave / fault）" ;;
esac
