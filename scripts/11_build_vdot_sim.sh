#!/usr/bin/env bash
# =============================================================================
# 11_build_vdot_sim.sh —— 构建并运行带 vdot 功能单元的 YunSuan L1 仿真平台
#
# 与 scripts/10_build_yunsuan_sim.sh 的区别：
#   * 作用在 work/XiangShan-vdot/yunsuan（含 vdot RTL），而不是 pristine 基线
#   * 构建前把语义唯一事实来源 tests/golden/vdot_ref.{c,h} 同步到 golden_model/，
#     保证 C++ 参考模型与 NEMU / 测试向量生成器用的是同一份实现
#
# 用法：
#   bash scripts/11_build_vdot_sim.sh                      # 构建 + 冒烟测试
#   WAVE=1 bash scripts/11_build_vdot_sim.sh               # 构建带波形版本并抓 vdot.vv 波形
#   OPS=10000 bash scripts/11_build_vdot_sim.sh            # 改随机激励条数
#   BUILD_ONLY=1 bash scripts/11_build_vdot_sim.sh         # 只构建
#
# 手工定向驱动：
#   YS_FUTYPE=10 YS_FUOPTYPE=0 ./build/emu -O 10000                     # 只跑 vdot.vv
#   YS_FUTYPE=10 YS_FUOPTYPE=1 ./build/emu -O 10000                     # 只跑 vdotacc.vv
#   YS_FUTYPE=10 YS_FUOPTYPE=2 ./build/emu -O 10000                     # 只跑 vdot4a.vv
#   YS_VDOT_VECTORS=<file> ./build/emu -O <N>                           # 回放定向语料
# =============================================================================
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
YS_DIR="${XS_VDOT}/yunsuan"
LOG_DIR="${LOG_ROOT}/stage2"
WAVE_DIR="${LOG_DIR}/waveform"
GOLDEN_SRC="${REPO_ROOT}/tests/golden"

WAVE="${WAVE:-0}"
OPS="${OPS:-2000}"
WAVE_OPS="${WAVE_OPS:-8}"
WAVE_END="${WAVE_END:-120}"
CLEAN="${CLEAN:-0}"
BUILD_ONLY="${BUILD_ONLY:-0}"


if [ ! -d "${YS_DIR}" ]; then
  info "找不到 ${YS_DIR}，调用 scripts/04_make_vdot_trees.sh vdot 生成"
  bash "${REPO_ROOT}/scripts/04_make_vdot_trees.sh" vdot
fi
mkdir -p "${LOG_DIR}" "${WAVE_DIR}"

step "0/5 载入工具链环境"
load_host_env
need_cmd verilator
need_cmd java "JDK 17"
info "java      : $(java -version 2>&1 | head -1)"
info "verilator : $(verilator --version)"
command -v espresso >/dev/null || die "PATH 中没有可执行的 espresso，精化会失败（请先执行 scripts/00_setup_env_host.sh）"
printf '.i 2\n.o 1\n.p 2\n01 1\n10 1\n.e\n' | espresso >/dev/null 2>&1 \
  || die "espresso 无法在本机执行（架构不符？返回 126 时请重跑 00_setup_env_host.sh）"

step "1/5 同步参考模型（tests/golden/vdot_ref.{c,h} -> golden_model/）"
# 关键一步：C++ 参考模型 vector_dot.cpp 直接 #include 这份 .c，不重写任何语义。
cp -f "${GOLDEN_SRC}/vdot_ref.c" "${YS_DIR}/src/test/csrc/golden_model/vdot_ref.c"
cp -f "${GOLDEN_SRC}/vdot_ref.h" "${YS_DIR}/src/test/csrc/golden_model/vdot_ref.h"
info "vdot_ref.c : $(wc -l < "${GOLDEN_SRC}/vdot_ref.c") 行"
info "vdot_ref.h : $(wc -l < "${GOLDEN_SRC}/vdot_ref.h") 行"

step "1.5/5 校验 mill 的 forkEnv 缓存"
FORKENV="${YS_DIR}/out/YunSuan/forkEnv.json"
ESPRESSO_DIR="$(dirname "$(command -v espresso)")"
if [ -f "${FORKENV}" ] && ! grep -q "${ESPRESSO_DIR}" "${FORKENV}"; then
  info "forkEnv 缓存中的 PATH 不含 ${ESPRESSO_DIR}，删除缓存"
  rm -f "${FORKENV}"
else
  info "forkEnv 缓存正常（或尚未生成）"
fi

step "2/5 清理（可选）"
if [ "${CLEAN}" = "1" ]; then make -C "${YS_DIR}" clean; fi
WANT_TRACE_MARK="${YS_DIR}/build/.trace_mode"
CUR_MARK="$(cat "${WANT_TRACE_MARK}" 2>/dev/null || echo "none")"
if [ "${CUR_MARK}" != "${WAVE}" ]; then
  info "波形开关从 '${CUR_MARK}' 变为 '${WAVE}'，删除 build/emu-compile 以强制重跑 verilator"
  rm -rf "${YS_DIR}/build/emu-compile" "${YS_DIR}/build/emu"
fi

step "3/5 构建 emu（mill 精化 SimTop -> verilator -> C++ 链接）"
if [ "${WAVE}" = "1" ]; then
  make -C "${YS_DIR}" emu EMU_TRACE=1
else
  make -C "${YS_DIR}" emu
fi
mkdir -p "${YS_DIR}/build" && echo "${WAVE}" > "${WANT_TRACE_MARK}"
[ -x "${YS_DIR}/build/emu" ] || die "build/emu 未生成"
info "emu      : $(ls -l "${YS_DIR}/build/emu" | awk '{print $5" bytes"}')"
info "SimTop.v : $(wc -l < "${YS_DIR}/build/SimTop.v") 行"

if [ "${BUILD_ONLY}" = "1" ]; then step "完成（仅构建）"; exit 0; fi

if [ "${WAVE}" = "1" ]; then
  step "4/5 抓取 vdot.vv 波形"
  require_short_emu_cwd "${YS_DIR}"
  SEED="${SEED:-1}"
  rm -f "${YS_DIR}"/build/*.vcd
  ( cd "${YS_DIR}" && \
    YS_FUTYPE=10 YS_FUOPTYPE=0 ./build/emu --dump-wave -b 0 -e "${WAVE_END}" -O "${WAVE_OPS}" -s "${SEED}" )
  for v in "${YS_DIR}"/build/*.vcd; do
    cp "$v" "${WAVE_DIR}/vdotvv_vdottop_fuType10_seed${SEED}.vcd"
    break
  done
  info "波形已复制到 ${WAVE_DIR}/"
  ls -la "${WAVE_DIR}"
  step "5/5 完成（波形模式）"
  exit 0
fi

step "4/5 冒烟测试"
RUNLOG="${LOG_DIR}/p4_smoke_test.log"
{
  echo "=== 运行时间 $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
  echo "=== emu: ${YS_DIR}/build/emu ==="
  echo
  echo "--- (a) 定向 vdot.vv   : fuType=10 (VDot -> VDotTop), fuOpType=0, SEW=8  , ${OPS} 条随机 ---"
  ( cd "${YS_DIR}" && YS_FUTYPE=10 YS_FUOPTYPE=0 ./build/emu -O "${OPS}" -s 0 )
  echo "exit=$?"
  echo
  echo "--- (b) 定向 vdotacc.vv: fuType=10, fuOpType=1, SEW=8  , ${OPS} 条随机 ---"
  ( cd "${YS_DIR}" && YS_FUTYPE=10 YS_FUOPTYPE=1 ./build/emu -O "${OPS}" -s 1 )
  echo "exit=$?"
  echo
  echo "--- (c) 定向 vdot4a.vv : fuType=10, fuOpType=2, SEW=32 , ${OPS} 条随机 ---"
  ( cd "${YS_DIR}" && YS_FUTYPE=10 YS_FUOPTYPE=2 ./build/emu -O "${OPS}" -s 2 )
  echo "exit=$?"
  echo
  echo "--- (d) 三条指令混合随机：fuType=10，optype 随机 ---"
  ( cd "${YS_DIR}" && YS_FUTYPE=10 ./build/emu -O "${OPS}" -s 3 )
  echo "exit=$?"
  echo
  for SUITE in positive negative boundary; do
    VF="${REPO_ROOT}/tests/vectors/${SUITE}.txt"
    # 只统计 status==OK 的行：非 OK 用例（归约类 vstart!=0 的 ILLEGAL_VSTART）在 FU 级
    # 平台无法建模异常，加载时已被跳过，-O 必须用跳过之后的条数，否则会绕回重复执行
    N=$(awk '!/^#/ && NF>0 && $NF=="OK"' "${VF}" | wc -l | tr -d ' ')
    echo "--- (e-${SUITE}) 定向语料回放 ${VF}（${N} 条 OK 用例，非 OK 用例自动跳过）---"
    ( cd "${YS_DIR}" && YS_VDOT_VECTORS="${VF}" ./build/emu -O "${N}" -s 7 )
    echo "exit=$?"
    echo
  done
  echo "--- (f) 上游既有功能单元回归（证明改动没有破坏原有 FU）---"
  ( cd "${YS_DIR}" && YS_FUTYPE=5 YS_FUOPTYPE=0 ./build/emu -O 2000 -s 0 )
  echo "exit=$?"
} 2>&1 | tee "${RUNLOG}"

step "5/5 完成"
info "日志： ${RUNLOG}"
info "判读： 'EMU EXCEEDED LIMIT' = 跑满指定条数且与 golden model 全部一致（PASS）"
info "       'EMU BADTRAP'        = 出现失配或卡死（FAIL）"
