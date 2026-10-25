#!/usr/bin/env bash
# =============================================================================
# verify_patches.sh —— 验证三份补丁能干净地应用到 pristine 上游，并且应用结果
#                      与本项目的实现工作树逐字节一致。
#
#   rtl/patch/0001-xiangshan-vdot.patch        XiangShan 侧 RTL + 译码 + 测试入口
#   rtl/patch/0002-yunsuan-vdot.patch          YunSuan 侧 RTL
#   tests/unit/yunsuan_vdot_testbench.patch    L1 测试平台（已包含 env_select 补丁）
#
# 做法：从 pristine 基线 work/XiangShan-kmhv2 用 `git archive HEAD` 导出一份**只读副本**
# 到临时目录（绝不改动该工作树），在副本上 git apply，再与 work/XiangShan-vdot 对比。
#
# 用法： bash scripts/tools/verify_patches.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRISTINE="${WORK_DIR:-${REPO_ROOT}/work}/XiangShan-kmhv2"
VDOT="${WORK_DIR:-${REPO_ROOT}/work}/XiangShan-vdot"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vdotpatch.XXXXXX")"
RC=0

cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

echo "=== 补丁可应用性验证  $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
echo "pristine 基线 : ${PRISTINE}  @ $(git -C "${PRISTINE}" rev-parse --short HEAD)"
echo "               yunsuan @ $(git -C "${PRISTINE}/yunsuan" rev-parse --short HEAD)"
echo "实现工作树     : ${VDOT}  @ $(git -C "${VDOT}" rev-parse --short HEAD)"
echo "               yunsuan @ $(git -C "${VDOT}/yunsuan" rev-parse --short HEAD)"
echo "（pristine 工作树只用 git archive 导出只读副本，全程不写入）"

check_one() {   # $1=标签 $2=pristine 仓库 $3=对照工作树 $4..=补丁列表
  local tag="$1" src="$2" ref="$3"; shift 3
  local dir="${TMP}/${tag}"
  echo ""
  echo "--- ${tag} ---"
  mkdir -p "${dir}"
  ( cd "${src}" && git archive HEAD src | tar -x -C "${dir}" )
  ( cd "${dir}" && git init -q . )
  local p
  for p in "$@"; do
    echo "  git apply --check ${p#${REPO_ROOT}/}"
    if ! ( cd "${dir}" && git apply --check "${p}" ); then
      echo "  [FAIL] --check 未通过"; RC=1; return 1
    fi
    if ! ( cd "${dir}" && git apply "${p}" ); then
      echo "  [FAIL] 应用失败"; RC=1; return 1
    fi
    echo "    应用成功"
  done
  # 逐文件对比
  local nsame=0 ndiff=0 f
  for p in "$@"; do
    while IFS= read -r f; do
      if diff -q "${dir}/${f}" "${ref}/${f}" > /dev/null 2>&1; then
        nsame=$((nsame+1))
      else
        ndiff=$((ndiff+1)); echo "    [DIFF] ${f}"
      fi
    done < <(grep '^diff --git' "${p}" | sed 's@^diff --git a/@@; s@ b/.*@@')
  done
  echo "  应用结果与实现工作树对比： 相同 ${nsame} 个文件，不同 ${ndiff} 个"
  [ "${ndiff}" -ne 0 ] && RC=1
  return 0
}

check_one "xiangshan" "${PRISTINE}" "${VDOT}" \
  "${REPO_ROOT}/rtl/patch/0001-xiangshan-vdot.patch"

check_one "yunsuan" "${PRISTINE}/yunsuan" "${VDOT}/yunsuan" \
  "${REPO_ROOT}/rtl/patch/0002-yunsuan-vdot.patch" \
  "${REPO_ROOT}/tests/unit/yunsuan_vdot_testbench.patch"

echo ""
if [ "${RC}" -eq 0 ]; then echo "PATCH-VERIFY: PASS"; else echo "PATCH-VERIFY: FAIL"; fi
exit ${RC}
