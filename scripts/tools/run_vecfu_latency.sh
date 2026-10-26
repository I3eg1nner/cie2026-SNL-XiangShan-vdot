#!/usr/bin/env bash
# =============================================================================
# run_vecfu_latency.sh —— 直接驱动 VIAluFix / VIPU 实测功能单元延迟
#                         （P7 / 赛题 3.3，基线序列用到的另外两个功能单元）
#
#   vmv.s.x / vmv.v.i / vwadd.wv -> FuType.vialuF -> VIAluFix (VialuCfg, 声明 latency=1)
#   vwredsum.vs         -> FuType.vipu   -> VIPU     (VipuCfg,  声明 latency=2)
#
# 工作树：${WORK_DIR}/XiangShan-cosim（P7 专用；不触碰 XiangShan-vdot）
#
# 用法： bash scripts/tools/run_vecfu_latency.sh
#        SKIP_ELAB=1 跳过 mill 精化
#        XS_DIR=<树>    直接指定工作树；否则用 ${WORK_DIR:-<仓库根>/work}/XiangShan-cosim
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
XS_DIR="${XS_DIR:-${WORK_DIR:-${REPO_ROOT}/work}/XiangShan-cosim}"
SKIP_ELAB="${SKIP_ELAB:-0}"
OPS="${VECFU_LAT_OPS:-64}"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/env_host.sh"

echo "=== VIAluFix / VIPU 延迟实测  $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
echo ""
echo "声明值（香山源码）："
grep -n "name = \"vialuFix\"\|name = \"vipu\"" "${XS_DIR}/src/main/scala/xiangshan/backend/fu/FuConfig.scala" \
  | sed 's/^/    FuConfig.scala:/'
echo "    FuConfig.scala:544  VialuCfg.latency = CertainLatency(1)"
echo "    FuConfig.scala:615  VipuCfg.latency  = CertainLatency(2)"

echo ""
echo "--- (0) 把交付仓库里的 harness 源码同步进工作树 ---"
#     交付仓库 tests/unit/ 是唯一事实来源；work/ 被 .gitignore 排除，
#     所以验收者拿到的只有 tests/unit/ 下这一份。
HARNESS_DST="${XS_DIR}/src/test/scala/xiangshan/backend/fu"
mkdir -p "${HARNESS_DST}"
cp -f "${REPO_ROOT}/tests/unit/VecFuLatHarness.scala" "${HARNESS_DST}/VecFuLatHarness.scala"
echo "    tests/unit/VecFuLatHarness.scala -> ${HARNESS_DST#${REPO_ROOT}/}/"

echo ""
echo "--- (1) 精化 harness ---"
for M in VIAluFixHarness VIPUHarness; do
  # 只有当已生成的 Verilog 不比 harness 源码旧时才允许跳过精化
  if [ "${SKIP_ELAB}" = "1" ] && [ -f "${XS_DIR}/build/vdot/${M}.v" ] && \
     [ ! "${HARNESS_DST}/VecFuLatHarness.scala" -nt "${XS_DIR}/build/vdot/${M}.v" ]; then
    echo "    SKIP_ELAB=1 且 Verilog 不旧于 harness 源码，沿用已有的 build/vdot/${M}.v"
  else
    bash "${REPO_ROOT}/scripts/tools/mill_state_guard.sh" "${XS_DIR}" >/dev/null || true
    ( cd "${XS_DIR}" && mill -i -D jvm-xmx=6G xiangshan.test.runMain \
        "xiangshan.backend.fu.${M}Main" --target-dir build/vdot --target verilog ) \
      2>&1 | grep -vE "^\s+at " | tail -2
  fi
  echo "    ${M}.v : $(wc -l < "${XS_DIR}/build/vdot/${M}.v" | tr -d ' ') 行"
done

echo ""
echo "--- (2) Verilator 构建并运行 ---"
RC=0
for M in VIAluFixHarness VIPUHarness; do
  D="${XS_DIR}/build/vecfu-lat-${M}"
  mkdir -p "${D}"
  cp -f "${REPO_ROOT}/tests/unit/vecfu_latency_tb.cpp" "${D}/"
  EXTRA=""
  if [ "${M}" = "VIAluFixHarness" ]; then EXTRA="-DVIALU_MODE"; fi
  verilator --cc --exe --build -j 0 --top-module "${M}" \
    --assert --output-split 5000 -Wno-fatal \
    -CFLAGS "-std=c++17 -O2 -DTOPMOD=${M} ${EXTRA}" \
    -o "${D}/tb" -Mdir "${D}/obj" \
    "${XS_DIR}/build/vdot/${M}.v" "${D}/vecfu_latency_tb.cpp" 2>&1 | grep -iE "error" | sed -n '1,5p' || true
  [ -x "${D}/tb" ] || { echo "构建失败: ${M}"; exit 1; }
  echo ""
  set +e
  VECFU_LAT_OPS="${OPS}" "${D}/tb"
  r=$?
  set -e
  if [ ${r} -ne 0 ]; then RC=${r}; fi
done
exit ${RC}
