#!/usr/bin/env bash
# =============================================================================
# run_vimacu_latency.sh —— 直接驱动 VIMacU 测量功能单元延迟（P7 / 赛题 3.3）
#
# 与 run_vimacu_tb.sh 的分工：
#   run_vimacu_tb.sh      证明 **功能** 一致（VIMacU 与参考模型逐位相同）
#   run_vimacu_latency.sh 测 **时序**：
#                         * out.valid 延迟 —— harness 按 VimacCfg.latency 搭的寄存器链
#                           产生，属平台构造值，只作与声明值的对照；
#                         * 数据成形拍 —— 逐拍采 io_vd 与参考模型比较（不读 out.valid），
#                           是独立观测（下界型，判读规则见 tb 文件头注释）。
#                         同时覆盖上游既有的 vmul / vwmul / vmacc，用来回答
#                         「新增 vdot 有没有把既有 vimac 指令变慢」
#
# 工作树：默认 work/XiangShan-cosim（P7 专用；不触碰 work/XiangShan-vdot）；
#         可用 XS_DIR=<路径> 指向一份私有副本
#
# 用法： bash scripts/tools/run_vimacu_latency.sh
#        SKIP_ELAB=1 跳过 mill 精化（沿用已有的 build/vdot/VIMacUHarness.v）
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
XS_DIR="${XS_DIR:-${REPO_ROOT}/work/XiangShan-cosim}"
VEC_DIR="${REPO_ROOT}/tests/vectors"
GOLDEN="${REPO_ROOT}/tests/golden"
OBJ_DIR="${XS_DIR}/build/vimacu-lat-tb"
SKIP_ELAB="${SKIP_ELAB:-0}"

# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/scripts/env_host.sh" ] && source "${REPO_ROOT}/scripts/env_host.sh"
# env_host.sh 由生成它的那台机器决定；JAVA_HOME 指向不存在的目录时回退到 PATH 上的 java
if [ -n "${JAVA_HOME:-}" ] && [ ! -x "${JAVA_HOME}/bin/java" ]; then unset JAVA_HOME; fi

echo "=== VIMacU 延迟测量  $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
echo "    主机: $(uname -sm)   $(verilator --version 2>/dev/null | head -1)"
echo ""
echo "--- (0) 把交付仓库里的 harness 源码同步进工作树 ---"
HARNESS_DST="${XS_DIR}/src/test/scala/xiangshan/backend/fu"
mkdir -p "${HARNESS_DST}"
cp -f "${REPO_ROOT}/tests/unit/VIMacUHarness.scala" "${HARNESS_DST}/VIMacUHarness.scala"
echo "    tests/unit/VIMacUHarness.scala -> ${HARNESS_DST#${REPO_ROOT}/}/"

echo ""
echo "--- (1) 精化 VIMacUHarness（内部例化真正的 VIMacU）---"
if [ "${SKIP_ELAB}" = "1" ] && [ -f "${XS_DIR}/build/vdot/VIMacUHarness.v" ] && \
   [ ! "${HARNESS_DST}/VIMacUHarness.scala" -nt "${XS_DIR}/build/vdot/VIMacUHarness.v" ]; then
  echo "    SKIP_ELAB=1 且 Verilog 不旧于 harness 源码，沿用已有的 build/vdot/VIMacUHarness.v"
else
  bash "${REPO_ROOT}/scripts/tools/mill_state_guard.sh" "${XS_DIR}" || true
  ( cd "${XS_DIR}" && mill -i -D jvm-xmx=6G xiangshan.test.runMain \
      xiangshan.backend.fu.VIMacUHarnessMain --target-dir build/vdot --target verilog ) \
    2>&1 | grep -vE "^\s+at " | tail -3
fi
echo "    VIMacUHarness.v : $(wc -l < "${XS_DIR}/build/vdot/VIMacUHarness.v" | tr -d ' ') 行"
# 声明值出处：在 FuConfig.scala 里定位 `val VimacCfg` 定义块内的第一行 latency，
# 打印其真实行号与内容（不按全文件第 N 个匹配取，避免取到 MulCfg 等其它 FU 的配置）
FUCFG="${XS_DIR}/src/main/scala/xiangshan/backend/fu/FuConfig.scala"
echo "    声明值来源（VimacCfg 定义块内的 latency 行）："
awk '/^[[:space:]]*val VimacCfg[[:space:]:=]/ {inblk=1; start=NR}
     inblk && /latency[[:space:]]*=/ {printf "      FuConfig.scala:%d:%s   （VimacCfg 定义始于 :%d）\n", NR, $0, start; exit}' \
  "${FUCFG}" || true

echo ""
echo "--- (2) Verilator 构建 ---"
mkdir -p "${OBJ_DIR}"
cp -f "${GOLDEN}/vdot_ref.c" "${GOLDEN}/vdot_ref.h" "${OBJ_DIR}/"
cp -f "${REPO_ROOT}/tests/unit/vimacu_latency_tb.cpp" "${OBJ_DIR}/"
verilator --cc --exe --build -j 0 \
  --top-module VIMacUHarness \
  --assert --output-split 5000 -Wno-fatal \
  -CFLAGS "-I${OBJ_DIR} -std=c++17 -O2" \
  -o "${OBJ_DIR}/vimacu_latency_tb" \
  -Mdir "${OBJ_DIR}/obj" \
  "${XS_DIR}/build/vdot/VIMacUHarness.v" \
  "${OBJ_DIR}/vimacu_latency_tb.cpp" 2>&1 | grep -vE "^%Warning|^ *[0-9]+ \||^ *\||^ *\.\.\." | tail -10 || true
[ -x "${OBJ_DIR}/vimacu_latency_tb" ] || { echo "构建失败"; exit 1; }

echo ""
echo "--- (3) 运行 ---"
SUITES=""
for f in positive negative boundary \
         vdotacc_positive vdotacc_negative vdotacc_boundary \
         vdot4a_positive vdot4a_negative vdot4a_boundary; do
  SUITES="${SUITES} ${VEC_DIR}/${f}.txt"
done
set +e
# shellcheck disable=SC2086
VIMACU_LAT_OPS="${VIMACU_LAT_OPS:-64}" "${OBJ_DIR}/vimacu_latency_tb" ${SUITES}
RC=$?
set -e
exit ${RC}
