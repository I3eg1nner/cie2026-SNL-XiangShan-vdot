#!/usr/bin/env bash
# =============================================================================
# run_decode_tb.sh —— VecExceptionGen（译码级合法性判定）的定向测试
#
# 重点验证本阶段修复的缺陷：vdot 指令族在 vtype.vlmul != 0（即 LMUL != 1）时
# 必须触发 Illegal Instruction（裁定 S-6）。修复前 VecExceptionGen 不拦截，
# LMUL>1 的 vdot.vv 会静默给出错误结果。
#
# 另含裁定 S-7' 的 [I] 组：vdot4a 在 vstart!=0 时必须非法 —— 由上游 vstartIllegal
# 天然满足，用例的作用是用实测证明「RTL 无需改动」。
#
# 用法： bash scripts/tools/run_decode_tb.sh
#        PROVE_FAIL=1 追加反向验证（scripts/20_run_func_tests.sh 5.6 步会自动执行并
#        存档为 logs/stage2/p5_decode_prove_fail.log）
#        SKIP_ELAB=1 跳过 mill 精化
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
XS_DIR="${REPO_ROOT}/work/XiangShan-vdot"
OBJ_DIR="${XS_DIR}/build/decode-tb"
SKIP_ELAB="${SKIP_ELAB:-0}"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/env_host.sh"

echo "=== VecExceptionGen 译码级合法性定向测试  $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
echo ""
echo "--- (1) 精化 VecExceptionGenHarness ---"
if [ "${SKIP_ELAB}" = "1" ] && [ -f "${XS_DIR}/build/vdot/VecExceptionGenHarness.v" ]; then
  echo "    SKIP_ELAB=1，沿用已有 Verilog"
else
  bash "${REPO_ROOT}/scripts/tools/mill_state_guard.sh" "${XS_DIR}" || true
  ( cd "${XS_DIR}" && mill -i -D jvm-xmx=6G xiangshan.test.runMain \
      xiangshan.backend.decode.VecExceptionGenMain --target-dir build/vdot --target verilog ) \
    2>&1 | grep -vE "^\s+at " | tail -4
fi
echo "    VecExceptionGenHarness.v : $(wc -l < "${XS_DIR}/build/vdot/VecExceptionGenHarness.v" | tr -d ' ') 行"

echo ""
echo "--- (2) Verilator 构建 ---"
mkdir -p "${OBJ_DIR}"
cp -f "${REPO_ROOT}/tests/unit/vecexcgen_tb.cpp" "${OBJ_DIR}/"
verilator --cc --exe --build -j 0 \
  --top-module VecExceptionGenHarness \
  --assert --output-split 5000 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  -o "${OBJ_DIR}/vecexcgen_tb" \
  -Mdir "${OBJ_DIR}/obj" \
  "${XS_DIR}/build/vdot/VecExceptionGenHarness.v" \
  "${OBJ_DIR}/vecexcgen_tb.cpp" 2>&1 | tail -8
[ -x "${OBJ_DIR}/vecexcgen_tb" ] || { echo "构建失败"; exit 1; }

echo ""
echo "--- (3) 运行定向用例 ---"
set +e
"${OBJ_DIR}/vecexcgen_tb"
RC=$?
set -e

# ---------------------------------------------------------------------------
# 反向验证：临时撤掉 dotEmulIllegal，证明上面的 LMUL 用例确实能失败
# （「全 PASS」本身不能说明测试有效，必须证明它会红）
# ---------------------------------------------------------------------------
if [ "${PROVE_FAIL:-0}" = "1" ]; then
  echo ""
  echo "--- (4) 反向验证：临时撤掉 dotEmulIllegal，确认 LMUL 用例会失败 ---"
  SRC="${XS_DIR}/src/main/scala/xiangshan/backend/decode/VecExceptionGen.scala"
  BK="$(mktemp -t vecexcgen)"
  cp "${SRC}" "${BK}"
  restore_src() { cp "${BK}" "${SRC}"; rm -f "${BK}"; }
  trap restore_src EXIT
  perl -0777 -i -pe 's{\|\| lsSegIllegal \|\| dotEmulIllegal}{|| lsSegIllegal  /* dotEmulIllegal 临时移除（反向验证） */}' "${SRC}"
  diff -u "${BK}" "${SRC}" | sed -n '3,12p' | sed 's/^/    /' || true
  ( cd "${XS_DIR}" && mill -i -D jvm-xmx=6G xiangshan.test.runMain \
      xiangshan.backend.decode.VecExceptionGenMain --target-dir build/vdot-nofix --target verilog ) \
    2>&1 | grep -vE "^\s+at " | tail -3
  rm -rf "${OBJ_DIR}-nofix"; mkdir -p "${OBJ_DIR}-nofix"
  cp -f "${REPO_ROOT}/tests/unit/vecexcgen_tb.cpp" "${OBJ_DIR}-nofix/"
  verilator --cc --exe --build -j 0 --top-module VecExceptionGenHarness \
    --assert --output-split 5000 -Wno-fatal -CFLAGS "-std=c++17 -O2" \
    -o "${OBJ_DIR}-nofix/vecexcgen_tb" -Mdir "${OBJ_DIR}-nofix/obj" \
    "${XS_DIR}/build/vdot-nofix/VecExceptionGenHarness.v" \
    "${OBJ_DIR}-nofix/vecexcgen_tb.cpp" > /dev/null 2>&1
  set +e
  "${OBJ_DIR}-nofix/vecexcgen_tb" | grep -E "FAIL|定向测试|VECEXC-TB"
  NOFIX_RC=$?
  set -e
  restore_src; trap - EXIT
  echo "    源码已还原（dotEmulIllegal 恢复）"
  # 还原后重新生成一份正确的 Verilog，避免留下带缺陷的产物
  ( cd "${XS_DIR}" && mill -i -D jvm-xmx=6G xiangshan.test.runMain \
      xiangshan.backend.decode.VecExceptionGenMain --target-dir build/vdot --target verilog ) \
    2>&1 | grep -vE "^\s+at " | tail -2
  rm -rf "${XS_DIR}/build/vdot-nofix" "${OBJ_DIR}-nofix"
fi

exit ${RC}
