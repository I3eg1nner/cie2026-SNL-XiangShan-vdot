#!/usr/bin/env bash
# =============================================================================
# run_vimacu_tb.sh —— 构建并运行「直接驱动 VIMacU」的独立 Verilator 测试平台
#
# 解决 docs/stage2/11_RTL实现说明.md §10 第 1 条登记的最大验证缺口：
#   L1 的 YunSuan 平台测的是 VDotTop，而真正被集成进香山的是 VIMacU
#   （掩码/尾部成形用的是 ByteMaskTailGen + Mgu + RedTailGen，另一套实现）。
# 本脚本把同一份定向语料直接回放进 VIMacU 本体。
#
# 流程：
#   1) mill 精化 VIMacUHarness（窄 IO 包装，内部例化真正的 VIMacU）-> Verilog
#   2) verilator --cc --exe --build，链接 tests/unit/vimacu_tb.cpp
#   3) 回放 tests/vectors/ 的全部语料
#   4) 逐 module 比对 VIMacUHarness.v 与独立精化的 VIMacU.v，证明共享算术核一致
#
# 用法： bash scripts/tools/run_vimacu_tb.sh
#        SKIP_ELAB=1 跳过 mill 精化（Verilog 已在）
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
XS_DIR="${WORK_DIR:-${REPO_ROOT}/work}/XiangShan-vdot"
VEC_DIR="${REPO_ROOT}/tests/vectors"
GOLDEN="${REPO_ROOT}/tests/golden"
OBJ_DIR="${XS_DIR}/build/vimacu-tb"
SKIP_ELAB="${SKIP_ELAB:-0}"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/env_host.sh"

echo "=== VIMacU 直驱等价性验证  $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
echo ""
echo "--- (1) 精化 VIMacUHarness（内部例化真正的 VIMacU）---"
if [ "${SKIP_ELAB}" = "1" ] && [ -f "${XS_DIR}/build/vdot/VIMacUHarness.v" ]; then
  echo "    SKIP_ELAB=1，沿用已有的 build/vdot/VIMacUHarness.v"
else
  bash "${REPO_ROOT}/scripts/tools/mill_state_guard.sh" "${XS_DIR}" || true
  ( cd "${XS_DIR}" && mill -i -D jvm-xmx=6G xiangshan.test.runMain \
      xiangshan.backend.fu.VIMacUHarnessMain --target-dir build/vdot --target verilog ) \
    2>&1 | grep -vE "^\s+at " | tail -5
  # 同时单独精化一份 VIMacU，用于证明两者共享的算术核逐字节相同
  ( cd "${XS_DIR}" && mill -i -D jvm-xmx=6G xiangshan.test.runMain \
      xiangshan.backend.fu.VIMacUMain --target-dir build/vdot2 --target verilog ) \
    2>&1 | grep -vE "^\s+at " | tail -3
fi
echo "    VIMacUHarness.v : $(wc -l < "${XS_DIR}/build/vdot/VIMacUHarness.v" | tr -d ' ') 行"
echo "    其中的模块      : $(grep -c '^module ' "${XS_DIR}/build/vdot/VIMacUHarness.v" | tr -d ' ') 个"
grep -oE '^module [A-Za-z0-9_]+' "${XS_DIR}/build/vdot/VIMacUHarness.v" | sed 's/^/      /'

echo ""
echo "--- (2) Verilator 构建 ---"
mkdir -p "${OBJ_DIR}"
cp -f "${GOLDEN}/vdot_ref.c" "${GOLDEN}/vdot_ref.h" "${OBJ_DIR}/"
cp -f "${REPO_ROOT}/tests/unit/vimacu_tb.cpp" "${OBJ_DIR}/"
verilator --cc --exe --build -j 0 \
  --top-module VIMacUHarness \
  --assert --output-split 5000 \
  -Wno-fatal \
  -CFLAGS "-I${OBJ_DIR} -std=c++17 -O2" \
  -o "${OBJ_DIR}/vimacu_tb" \
  -Mdir "${OBJ_DIR}/obj" \
  "${XS_DIR}/build/vdot/VIMacUHarness.v" \
  "${OBJ_DIR}/vimacu_tb.cpp" 2>&1 | grep -vE "^%Warning|^ *[0-9]+ \||^ *\||^ *\.\.\." | tail -15
[ -x "${OBJ_DIR}/vimacu_tb" ] || { echo "构建失败"; exit 1; }
echo "    vimacu_tb : $(ls -l "${OBJ_DIR}/vimacu_tb" | awk '{print $5}') bytes"

echo ""
echo "--- (3) 回放全部定向语料（与 L1 平台用的是同一批文件）---"
SUITES=""
for f in positive negative boundary \
         vdotacc_positive vdotacc_negative vdotacc_boundary \
         vdot4a_positive vdot4a_negative vdot4a_boundary \
         vstart_relaxed random vdotacc_random vdot4a_random; do
  SUITES="${SUITES} ${VEC_DIR}/${f}.txt"
done
# shellcheck disable=SC2086
VIMACU_DUMP="${VIMACU_DUMP:-3}" "${OBJ_DIR}/vimacu_tb" ${SUITES}
RC=$?

echo ""
echo "--- (4) 共享算术核的逐 module 比对 ---"
echo "    把「独立精化的 VIMacU.v」与「harness 里的 VIMacU」逐 module 对比。"
echo "    harness 把 flush / robIdx / vxrm / vlmul / vuopIdx 等端口接成常量，"
echo "    firtool 会据此做常量传播，所以 VIMacU / Mgu / VIMac64b 三个模块的网表会瘦身；"
echo "    但共享的算术核（VDotTree + CSA4to2 + CSA3to2）与掩码生成（ByteMaskTailGen）"
echo "    必须逐字节相同 —— 这正是「两条验证路径跑的是同一套算术」的硬证据。"
python3 "${REPO_ROOT}/scripts/tools/verilog_module_diff.py" \
  "${XS_DIR}/build/vdot2/VIMacU.v" "${XS_DIR}/build/vdot/VIMacUHarness.v"

echo ""
echo "--- (5) VDotTree / ByteMaskTailGen 单独校验 ---"
for M in VDotTree CSA4to2 CSA3to2 ByteMaskTailGen MaskExtractor UIntToContLow1s UIntToContLow0s VecDataSplitModule VIMacSrcTypeModule; do
  A=$(awk -v m="$M" 'BEGIN{p=0} $0 ~ "^module "m"\\(" {p=1} p{print} p && /^endmodule/{exit}' "${XS_DIR}/build/vdot2/VIMacU.v" | sed -E 's@//.*@@' | { md5sum 2>/dev/null || md5; } | cut -d' ' -f1)
  B=$(awk -v m="$M" 'BEGIN{p=0} $0 ~ "^module "m"\\(" {p=1} p{print} p && /^endmodule/{exit}' "${XS_DIR}/build/vdot/VIMacUHarness.v" | sed -E 's@//.*@@' | { md5sum 2>/dev/null || md5; } | cut -d' ' -f1)
  [ "$A" = "$B" ] && R="IDENTICAL" || R="DIFFERENT"
  printf '    %-22s %s  (%s)\n' "${M}" "${R}" "${A}"
done

exit ${RC}
