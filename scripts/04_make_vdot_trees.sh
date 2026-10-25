#!/usr/bin/env bash
# =============================================================================
# 04_make_vdot_trees.sh —— 从纯净基线生成打了 vdot 补丁的 XiangShan 工作树（幂等）
#
#   ${WORK_DIR}/XiangShan-vdot   阶段二 L1 功能测试用（11_ / 20_ / scripts/tools/run_*_tb.sh）
#   ${WORK_DIR}/XiangShan-cosim  阶段三协同仿真与 P7 延迟实测用（30_ / 40_）
#
# 两棵树的组成完全相同：
#   XiangShan-kmhv2（a4eeaab，含全部子模块）的副本
#     + rtl/patch/0001-xiangshan-vdot.patch        （XiangShan 根）
#     + rtl/patch/0002-yunsuan-vdot.patch          （yunsuan 子模块）
#     + tests/unit/yunsuan_vdot_testbench.patch    （yunsuan 子模块，L1 测试平台）
# 分成两棵是为了让 mill out/ 与 build/（带 / 不带 --trace 的 emu）互不干扰。
#
# 做法：rsync 复制基线（排除 out/、build/ 构建产物）到临时目录 → 把副本里已跟踪文件
# 还原到 HEAD（基线若被 10_build_yunsuan_sim.sh 打过 env_select 补丁，这里会去掉）→
# git apply --check 后依次应用三份补丁 → 成功后原子改名为目标目录。
# 基线工作树全程只读。目标目录已存在时只校验三份补丁处于已应用状态。
#
# 用法：
#   bash scripts/04_make_vdot_trees.sh [vdot|cosim|all]   # 默认 all
# =============================================================================
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

WHICH="${1:-all}"
P_XS="${REPO_ROOT}/rtl/patch/0001-xiangshan-vdot.patch"
P_YS="${REPO_ROOT}/rtl/patch/0002-yunsuan-vdot.patch"
P_TB="${REPO_ROOT}/tests/unit/yunsuan_vdot_testbench.patch"

need_cmd rsync
need_cmd git
[ -f "${XS_PRISTINE}/yunsuan/build.sc" ] \
  || die "找不到纯净基线 ${XS_PRISTINE}（含 yunsuan 子模块），请先执行 scripts/00_setup_env_host.sh"

patched() {  # patched <仓库> <补丁>：补丁处于已应用状态则返回 0
  git -C "$1" apply --check --reverse "$2" >/dev/null 2>&1
}

make_tree() {
  local dst="$1" name; name="$(basename "$1")"
  if [ -d "${dst}" ]; then
    if patched "${dst}" "${P_XS}" && patched "${dst}/yunsuan" "${P_YS}" && patched "${dst}/yunsuan" "${P_TB}"; then
      info "${name}: 已存在，三份补丁均处于已应用状态，跳过"
      return 0
    fi
    die "${dst} 已存在，但补丁状态不符（可能是旧版补丁或手工改动）。确认无用后删除该目录再重跑。"
  fi
  local tmp="${dst}.tmp.$$"
  rm -rf "${tmp}"
  trap 'rm -rf "'"${tmp}"'"' EXIT
  info "${name}: 复制基线 $(relpath "${XS_PRISTINE}") -> ${tmp}（排除 out/ build/）"
  rsync -a --exclude '/out/' --exclude '/build/' --exclude '/yunsuan/out/' --exclude '/yunsuan/build/' \
    "${XS_PRISTINE}/" "${tmp}/"
  # 副本里的已跟踪文件还原到 HEAD（只作用于副本）
  git -C "${tmp}" checkout -- .
  git -C "${tmp}/yunsuan" checkout -- .
  info "  基线 XiangShan $(git -C "${tmp}" rev-parse --short HEAD) / yunsuan $(git -C "${tmp}/yunsuan" rev-parse --short HEAD)"
  local repo p
  for p in "${P_XS}" "${P_YS}" "${P_TB}"; do
    if [ "${p}" = "${P_XS}" ]; then repo="${tmp}"; else repo="${tmp}/yunsuan"; fi
    git -C "${repo}" apply --check "${p}" || die "补丁无法干净应用：$(relpath "${p}") -> ${repo}"
    git -C "${repo}" apply "${p}"
    info "  已应用 $(relpath "${p}")（$(grep -c '^diff --git' "${p}") 个文件）"
  done
  mv "${tmp}" "${dst}"
  trap - EXIT
  info "${name}: 完成 -> ${dst}"
  git -C "${dst}" status --short | sed 's/^/    XiangShan: /'
  git -C "${dst}/yunsuan" status --short | sed 's/^/    yunsuan  : /'
}

case "${WHICH}" in
  vdot)  make_tree "${XS_VDOT}" ;;
  cosim) make_tree "${XS_COSIM}" ;;
  all)   make_tree "${XS_VDOT}"; make_tree "${XS_COSIM}" ;;
  *) die "未知参数 ${WHICH}（可选 vdot / cosim / all）" ;;
esac
