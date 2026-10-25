#!/usr/bin/env bash
# =============================================================================
# 10_build_yunsuan_sim.sh —— 构建并运行 YunSuan 独立功能单元仿真平台（L1）
#
# 这是 YunSuan 官方自带的 per-FU 测试平台：
#   Chisel 顶层 yunsuan.top.SimTop（VLEN=128）
#   + Verilator 生成 VSimTop
#   + src/test/csrc 下的 C++ golden model 逐次比对
#
# 用法：
#   bash scripts/10_build_yunsuan_sim.sh                 # 构建 + 跑上游 CI 的随机测试
#   WAVE=1 bash scripts/10_build_yunsuan_sim.sh          # 构建带波形版本并抓一段 vadd 波形
#   OPS=100000 bash scripts/10_build_yunsuan_sim.sh      # 改随机激励次数
#   CLEAN=1  bash scripts/10_build_yunsuan_sim.sh        # 先 make clean
#
# 环境变量：
#   WAVE=1      以 EMU_TRACE=1 构建（verilator --trace），并 dump VCD
#   OPS=<N>     随机测试的操作数，默认 10000
#   WAVE_OPS    波形模式下的操作数，默认 8
#   WAVE_END    波形模式下 dump 的结束周期，默认 120
#   SEED        随机种子，默认 0（波形模式默认 1）
# =============================================================================
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
YS_DIR="${XS_PRISTINE}/yunsuan"
LOG_DIR="${LOG_ROOT}/stage1"
WAVE_DIR="${LOG_DIR}/waveform"
PATCH="${REPO_ROOT}/tests/unit/yunsuan_testdriver_env_select.patch"

WAVE="${WAVE:-0}"
OPS="${OPS:-10000}"
WAVE_OPS="${WAVE_OPS:-8}"
WAVE_END="${WAVE_END:-120}"
CLEAN="${CLEAN:-0}"


[ -d "${YS_DIR}" ] || die "找不到 ${YS_DIR}，请先执行 scripts/00_setup_env_host.sh 并检出 yunsuan 子模块"
mkdir -p "${LOG_DIR}" "${WAVE_DIR}"

# -----------------------------------------------------------------------------
step "0/5 载入工具链环境"
load_host_env
need_cmd verilator
need_cmd java "JDK 17"
info "java      : $(java -version 2>&1 | head -1)"
info "verilator : $(verilator --version)"
info "espresso  : $(command -v espresso || echo '未找到')"
command -v espresso >/dev/null || die "PATH 中没有可执行的 espresso，精化会失败（请先执行 scripts/00_setup_env_host.sh）"
printf '.i 2\n.o 1\n.p 2\n01 1\n10 1\n.e\n' | espresso >/dev/null 2>&1 \
  || die "espresso 无法在本机执行（架构不符？返回 126 时请重跑 00_setup_env_host.sh）"

# -----------------------------------------------------------------------------
step "1/5 应用 test_driver 运行时选择补丁（幂等）"
# 作用：让 TestDriver::set_test_type() 支持 YS_FUTYPE / YS_FUOPTYPE 环境变量，
#       从而无需改源码即可定向驱动某个功能单元（例如 vadd）。
#       不设置这两个变量时行为与上游完全一致。
if grep -q "YS_FUTYPE" "${YS_DIR}/src/test/csrc/test_driver.cpp"; then
  info "补丁已应用，跳过"
else
  git -C "${YS_DIR}" apply "${PATCH}"
  info "已应用 ${PATCH}"
fi
info "如需还原上游状态： git -C ${YS_DIR} checkout -- src/test/csrc/test_driver.cpp"

# -----------------------------------------------------------------------------
step "1.5/5 校验 mill 的 forkEnv 缓存"
# mill 把 build.sc 里 `sys.env("PATH")` 算出的 forkEnv 缓存在 out/YunSuan/forkEnv.json，
# 之后不再跟随外部 PATH 变化。若缓存里没有我们的 espresso 目录，精化会报
# "Result of espresso: 126"，必须先把缓存删掉。
FORKENV="${YS_DIR}/out/YunSuan/forkEnv.json"
ESPRESSO_DIR="$(dirname "$(command -v espresso)")"
if [ -f "${FORKENV}" ] && ! grep -q "${ESPRESSO_DIR}" "${FORKENV}"; then
  info "forkEnv 缓存中的 PATH 不含 ${ESPRESSO_DIR}，删除缓存"
  rm -f "${FORKENV}"
else
  info "forkEnv 缓存正常（或尚未生成）"
fi

# -----------------------------------------------------------------------------
step "2/5 清理（可选）"
if [ "${CLEAN}" = "1" ]; then
  info "make clean"
  make -C "${YS_DIR}" clean
fi
# WAVE 开关会改变 verilator 的编译选项，但 Makefile 的依赖里不含该开关，
# 必须手动删掉 emu-compile 才能让 --trace 生效/失效。
WANT_TRACE_MARK="${YS_DIR}/build/.trace_mode"
CUR_MARK="$(cat "${WANT_TRACE_MARK}" 2>/dev/null || echo "none")"
if [ "${CUR_MARK}" != "${WAVE}" ]; then
  info "波形开关从 '${CUR_MARK}' 变为 '${WAVE}'，删除 build/emu-compile 以强制重跑 verilator"
  rm -rf "${YS_DIR}/build/emu-compile" "${YS_DIR}/build/emu"
fi

# -----------------------------------------------------------------------------
step "3/5 构建 emu（mill 精化 SimTop -> verilator -> C++ 链接）"
if [ "${WAVE}" = "1" ]; then
  info "make emu EMU_TRACE=1"
  make -C "${YS_DIR}" emu EMU_TRACE=1
else
  info "make emu"
  make -C "${YS_DIR}" emu
fi
mkdir -p "${YS_DIR}/build" && echo "${WAVE}" > "${WANT_TRACE_MARK}"
[ -x "${YS_DIR}/build/emu" ] || die "build/emu 未生成"
info "emu      : $(ls -l "${YS_DIR}/build/emu" | awk '{print $5" bytes"}')"
info "SimTop.v : $(wc -l < "${YS_DIR}/build/SimTop.v") 行"

# -----------------------------------------------------------------------------
if [ "${WAVE}" = "1" ]; then
  step "4/5 抓取 vadd 波形"
  require_short_emu_cwd "${YS_DIR}"
  # 注意：emu.cpp 的 reset_ncycles() 在 VM_TRACE==1 时【无条件】调 tfp->dump()，
  #       所以带 trace 编译的 emu 必须始终带 --dump-wave 运行，否则会用未初始化指针崩溃。
  SEED="${SEED:-1}"
  rm -f "${YS_DIR}"/build/*.vcd
  ( cd "${YS_DIR}" && \
    YS_FUTYPE=3 YS_FUOPTYPE=0 ./build/emu --dump-wave -b 0 -e "${WAVE_END}" -O "${WAVE_OPS}" -s "${SEED}" )
  ( cd "${YS_DIR}" && \
    YS_FUTYPE=5 YS_FUOPTYPE=0 ./build/emu --dump-wave -b 0 -e "${WAVE_END}" -O "${WAVE_OPS}" -s $((SEED+1)) )
  i=0
  for v in "${YS_DIR}"/build/*.vcd; do
    i=$((i+1))
    case $i in
      1) cp "$v" "${WAVE_DIR}/vadd_vintadder_fuType3_seed${SEED}.vcd" ;;
      2) cp "$v" "${WAVE_DIR}/vaddvv_vialufwrapper_fuType5_seed$((SEED+1)).vcd" ;;
    esac
  done
  info "波形已复制到 ${WAVE_DIR}/"
  ls -la "${WAVE_DIR}"

  step "5/5 完成（波形模式）"
  info "用 GTKWave / Surfer 打开： gtkwave ${WAVE_DIR}/vaddvv_vialufwrapper_fuType5_seed$((SEED+1)).vcd"
  exit 0
fi

# -----------------------------------------------------------------------------
step "4/5 运行测试"
RUNLOG="${LOG_DIR}/p1_t3_yunsuan_sim_rerun.log"
{
  echo "=== 运行时间 $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
  echo
  echo "--- (a) 上游 CI 的随机混合测试： ./build/emu -O ${OPS} ---"
  ( cd "${YS_DIR}" && ./build/emu -O "${OPS}" )
  echo "exit=$?"
  echo
  echo "--- (b) 定向 vadd：fuType=3 (VIntegerALU -> VectorIntAdder), fuOpType=0 (VADD) ---"
  ( cd "${YS_DIR}" && YS_FUTYPE=3 YS_FUOPTYPE=0 ./build/emu -O "${OPS}" )
  echo "exit=$?"
  echo
  echo "--- (c) 定向 vadd.vv：fuType=5 (VIntegerALUV2 -> VIAluFWrapper -> VIntFixpAlu), fuOpType=0 (VADD_VV) ---"
  ( cd "${YS_DIR}" && YS_FUTYPE=5 YS_FUOPTYPE=0 ./build/emu -O "${OPS}" )
  echo "exit=$?"
} 2>&1 | tee "${RUNLOG}"

step "5/5 完成"
info "日志： ${RUNLOG}"
info "判读： 'EMU EXCEEDED LIMIT' = 跑满指定操作数且与 golden model 全部一致（PASS）"
info "       'EMU BADTRAP'        = 出现失配或卡死（FAIL），日志里会打印 REF/DUT 的具体数值"
