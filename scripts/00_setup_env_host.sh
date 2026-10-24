#!/usr/bin/env bash
# =============================================================================
# 00_setup_env_host.sh —— 宿主机（macOS / Apple Silicon）Chisel + Verilator 侧
#                        工具链一键搭建脚本（幂等，可重复执行）
#
# 覆盖范围：L0（mill 精化）+ L1（YunSuan 独立 FU 仿真平台）所需的全部工具。
# 不覆盖：NEMU / Docker / riscv 交叉工具链（由另一条线负责）。
#
# 用法：
#   bash scripts/00_setup_env_host.sh
#   source scripts/00_setup_env_host.sh   # 同时把 PATH/JAVA_HOME 导入当前 shell
#
# 可选环境变量：
#   SKIP_CLONE=1   跳过第 5 步的上游仓库克隆（仓库已就位时用；缺仓库仍会报错退出）
#   XS_REF=<sha>   覆盖 XiangShan 的锁定 commit（默认见下方 XS_PIN）
#   NEMU_REF=<sha> 覆盖 NEMU 的锁定 commit（默认见下方 NEMU_PIN）
#
# 执行后请用以下方式进入构建环境：
#   source <仓库根>/scripts/env_host.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${REPO_ROOT}/work"
TOOLS_DIR="${WORK_DIR}/tools"
XS_DIR="${WORK_DIR}/XiangShan-kmhv2"
NEMU_DIR="${WORK_DIR}/NEMU"

# --- 上游仓库锁定版本（与 docs/stage1/00_环境版本锁定.md 一致）-----------------
XS_URL="https://github.com/OpenXiangShan/XiangShan.git"
XS_BRANCH="kunminghu-v2"
XS_PIN="${XS_REF:-a4eeaabb4c12349259094a8b55f3ba1c03a9d993}"     # a4eeaab
NEMU_URL="https://github.com/OpenXiangShan/NEMU.git"
NEMU_BRANCH="master"
NEMU_PIN="${NEMU_REF:-90908390002fb7da885e5d880bba3bef2a225b2a}"  # 9090839
# XiangShan kunminghu-v2 的 11 个子模块（取自 `git -C work/XiangShan-kmhv2 submodule status`）。
# rocket-chip 另有 cde / hardfloat / torture 三个嵌套子模块，必须 --recursive，
# 否则 XiangShan 的 build.sc:109/118 用 $file 导入 common.sc 时会 NoSuchFileException
# （实测记录见 docs/stage1/03_仿真平台搭建报告.md §7.1）。
XS_SUBMODULES=(ChiselAIA ChiselIOPMP coupledL2 difftest fudian huancun
               openLLC ready-to-run rocket-chip utility yunsuan)
SKIP_CLONE="${SKIP_CLONE:-0}"

step() { printf '\n\033[1;34m==> [%s] %s\033[0m\n' "$(date '+%H:%M:%S')" "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
step "0/6 检查运行环境"
info "uname    : $(uname -srm)"
[ "$(uname -s)" = "Darwin" ] || die "本脚本只针对 macOS；Linux 请直接用 apt 安装 verilator/openjdk-17 后跳到第 3 步"
info "macOS    : $(sw_vers -productVersion) (build $(sw_vers -buildVersion))"
info "CPU 核数 : $(sysctl -n hw.ncpu)"
info "物理内存 : $(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 )) GB"
command -v brew >/dev/null 2>&1 || die "需要 Homebrew，请先安装：https://brew.sh"
info "brew     : $(brew --version | head -1)"

# -----------------------------------------------------------------------------
step "1/6 安装 Homebrew 包：verilator / openjdk@17 / gnu-sed / cmake"
# 说明：
#   * 系统自带/用户已装的 JDK 25 对 mill 0.11.x + Scala 2.13.15 过新，必须固定到 17。
#   * verilator 走 Homebrew 当前版本即可（本项目实测 5.052 可用）。
BREW_PKGS=(verilator openjdk@17 gnu-sed cmake)
for p in "${BREW_PKGS[@]}"; do
  if brew list --formula "$p" >/dev/null 2>&1; then
    info "已安装，跳过: $p"
  else
    info "安装: $p"
    brew install "$p"
  fi
done

JAVA_HOME_17="$(brew --prefix openjdk@17)"
[ -x "${JAVA_HOME_17}/bin/java" ] || die "openjdk@17 安装异常：${JAVA_HOME_17}/bin/java 不存在"

# -----------------------------------------------------------------------------
step "2/6 安装 mill（严格按各仓库 .mill-version 指定的版本）"
# XiangShan 根仓库 .mill-version = 0.12.3；yunsuan 子模块 .mill-version = 0.11.1。
# 官方 mill 启动脚本会读取当前目录的 .mill-version 并自动下载对应 assembly，
# 因此只需装启动脚本本身，版本由仓库决定。
mkdir -p "${TOOLS_DIR}/mill"
for V in 0.11.1 0.12.3; do
  TGT="${TOOLS_DIR}/mill/mill-${V}"
  if [ -s "$TGT" ]; then
    info "已存在，跳过: mill-${V}"
  else
    info "下载 mill 启动脚本 ${V}"
    curl -fL --retry 3 --no-progress-meter \
      -o "$TGT" "https://github.com/com-lihaoyi/mill/releases/download/${V}/${V}"
    chmod +x "$TGT"
  fi
done
# 统一入口 `mill`：由 .mill-version 决定实际版本
ln -sf "${TOOLS_DIR}/mill/mill-0.11.1" "${TOOLS_DIR}/mill/mill"

# -----------------------------------------------------------------------------
step "3/6 构建 arm64 原生 espresso（逻辑最小化器）"
# 背景：yunsuan/src/main/resources/espresso 是 Linux x86-64 ELF，
#       在 macOS/arm64 上执行会返回 126（cannot execute binary file），
#       Chisel 的 decoder 调 EspressoMinimizer 时直接抛 SubprocessException 中止精化。
#       yunsuan 的 build.sc 把该 resources 目录【追加】在 PATH 末尾，
#       所以只要把原生 espresso 放在 PATH 前部即可覆盖它。
mkdir -p "${TOOLS_DIR}/bin"
if [ -x "${TOOLS_DIR}/bin/espresso" ] && \
   file "${TOOLS_DIR}/bin/espresso" | grep -q "Mach-O.*arm64"; then
  info "已存在原生 espresso，跳过"
else
  [ -d "${TOOLS_DIR}/espresso-logic" ] || \
    git clone --depth=1 https://github.com/classabbyamp/espresso-logic "${TOOLS_DIR}/espresso-logic"
  make -C "${TOOLS_DIR}/espresso-logic/espresso-src" >/dev/null
  cp "${TOOLS_DIR}/espresso-logic/bin/espresso" "${TOOLS_DIR}/bin/espresso"
fi
printf '.i 2\n.o 1\n.p 2\n01 1\n10 1\n.e\n' | "${TOOLS_DIR}/bin/espresso" >/dev/null \
  || die "espresso 自检失败"
info "espresso : $(file -b "${TOOLS_DIR}/bin/espresso")"

# -----------------------------------------------------------------------------
step "4/6 生成环境变量脚本 scripts/env_host.sh"
cat > "${REPO_ROOT}/scripts/env_host.sh" <<EOF
# 由 scripts/00_setup_env_host.sh 自动生成，请勿手工编辑。
# 用法： source scripts/env_host.sh
export JAVA_HOME="${JAVA_HOME_17}"
export PATH="${TOOLS_DIR}/bin:${TOOLS_DIR}/mill:\${JAVA_HOME}/bin:\${PATH}"
EOF
info "已写出 ${REPO_ROOT}/scripts/env_host.sh"

# shellcheck disable=SC1090
source "${REPO_ROOT}/scripts/env_host.sh"

# -----------------------------------------------------------------------------
step "5/6 克隆并校验上游仓库（XiangShan-kmhv2 / NEMU）"
# 本步骤让「从零复现」真的从零开始：干净机器上会把两个上游仓库按锁定 commit 拉下来。
# 规则：
#   * 已存在的仓库【只读校验、绝不改动】—— 这些目录可能正被其他人的在制工作占用。
#   * 不存在的仓库才 clone；clone/检出失败一律 die（set -e 之外再显式判一次）。
#   * SKIP_CLONE=1 时不 clone，但仓库缺失仍然 die，不会"打印建议后以 0 退出"。

is_git_repo() { [ -d "$1/.git" ] || [ -f "$1/.git" ]; }

# $1=目录 $2=URL $3=分支 $4=锁定 commit $5=显示名
clone_pinned() {
  local dir="$1" url="$2" branch="$3" pin="$4" name="$5"
  if is_git_repo "${dir}"; then
    local head; head="$(git -C "${dir}" rev-parse HEAD)"
    if [ "${head}" = "${pin}" ]; then
      info "${name}: 已存在且 commit 匹配锁定版本 ${pin:0:7}，跳过"
    else
      info "${name}: 已存在，但 HEAD=${head:0:7} != 锁定 ${pin:0:7}"
      info "         本脚本不会改动已有工作区。要精确复现请另起干净检出："
      info "         git clone -b ${branch} ${url} <新目录> && git -C <新目录> checkout ${pin}"
    fi
    return 0
  fi
  if [ "${SKIP_CLONE}" = "1" ]; then
    die "${name} 不存在（${dir}），且 SKIP_CLONE=1。请去掉 SKIP_CLONE 重跑，或手工 clone 后再执行。"
  fi
  info "${name}: 克隆 ${url} (${branch}) -> ${dir}"
  mkdir -p "$(dirname "${dir}")"
  git clone -b "${branch}" "${url}" "${dir}" \
    || die "${name} clone 失败：${url}"
  if ! git -C "${dir}" checkout --quiet "${pin}"; then
    # 把半成品删干净，免得下次重跑时被当成"已存在的仓库"而静默放过
    rm -rf "${dir}"
    die "${name} 检出锁定 commit ${pin} 失败（上游可能已 force-push，请核对 docs/stage1/00_环境版本锁定.md）"
  fi
  info "${name}: HEAD=$(git -C "${dir}" rev-parse HEAD)"
}

clone_pinned "${XS_DIR}"   "${XS_URL}"   "${XS_BRANCH}"   "${XS_PIN}"   "XiangShan-kmhv2"
clone_pinned "${NEMU_DIR}" "${NEMU_URL}" "${NEMU_BRANCH}" "${NEMU_PIN}" "NEMU"

# --- XiangShan 子模块：逐个检查，只补缺失的（已检出的不碰）-------------------
is_git_repo "${XS_DIR}" || die "${XS_DIR} 不是 git 仓库，无法初始化子模块"
missing=()
for m in "${XS_SUBMODULES[@]}"; do
  if is_git_repo "${XS_DIR}/${m}"; then
    info "子模块已检出，跳过: ${m}"
  else
    missing+=("${m}")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  if [ "${SKIP_CLONE}" = "1" ]; then
    die "以下子模块未检出且 SKIP_CLONE=1：${missing[*]}"
  fi
  info "检出缺失子模块（--recursive）：${missing[*]}"
  git -C "${XS_DIR}" submodule update --init --recursive "${missing[@]}" \
    || die "submodule update --init --recursive ${missing[*]} 失败"
fi
# rocket-chip 的嵌套子模块（cde / hardfloat / torture）单独兜底：
# 即便 rocket-chip 本体早已存在，嵌套层也可能没检出，这正是 §7.1 踩过的坑。
if is_git_repo "${XS_DIR}/rocket-chip"; then
  for n in cde hardfloat torture; do
    if ! is_git_repo "${XS_DIR}/rocket-chip/${n}"; then
      if [ "${SKIP_CLONE}" = "1" ]; then
        die "rocket-chip 的嵌套子模块 ${n} 未检出且 SKIP_CLONE=1"
      fi
      info "检出 rocket-chip 嵌套子模块: ${n}"
      git -C "${XS_DIR}" submodule update --init --recursive rocket-chip \
        || die "rocket-chip --recursive 检出失败"
      break
    fi
  done
fi

# --- 校验结果 ---------------------------------------------------------------
[ -f "${XS_DIR}/yunsuan/build.sc" ] \
  || die "yunsuan 子模块检出异常：${XS_DIR}/yunsuan/build.sc 不存在"
info "XiangShan: $(git -C "${XS_DIR}" rev-parse HEAD) ($(git -C "${XS_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null))"
info "yunsuan  : $(git -C "${XS_DIR}/yunsuan" rev-parse HEAD)"
info "NEMU     : $(git -C "${NEMU_DIR}" rev-parse HEAD)"
info "（xs-env 仅作为官方部署流程的参考读物，本项目的构建链不依赖它，故不克隆；
     见 docs/stage1/01_环境部署报告.md §1）"

# -----------------------------------------------------------------------------
step "6/6 版本核对"
printf '%-16s %s\n' "macOS"     "$(sw_vers -productVersion)"
printf '%-16s %s\n' "brew"      "$(brew --version | head -1)"
printf '%-16s %s\n' "verilator" "$(verilator --version)"
printf '%-16s %s\n' "java"      "$(java -version 2>&1 | head -1)"
printf '%-16s %s\n' "JAVA_HOME" "${JAVA_HOME}"
printf '%-16s %s\n' "cmake"     "$(cmake --version | head -1)"
printf '%-16s %s\n' "gsed"      "$(gsed --version | head -1)"
printf '%-16s %s\n' "espresso"  "$(command -v espresso) ($(file -b "$(command -v espresso)" | cut -d, -f1))"
printf '%-16s %s\n' "mill(启动)" "$(command -v mill)"
if [ -f "${XS_DIR}/yunsuan/.mill-version" ]; then
  printf '%-16s %s\n' "mill(yunsuan)" "$(cd "${XS_DIR}/yunsuan" && mill --version 2>/dev/null | head -1)"
fi

printf '\n\033[1;32m环境搭建完成。后续构建前请执行： source %s/scripts/env_host.sh\033[0m\n' "${REPO_ROOT}"
