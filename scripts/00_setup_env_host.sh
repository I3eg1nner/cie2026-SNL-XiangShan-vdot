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
# 执行后请用以下方式进入构建环境：
#   source <仓库根>/scripts/env_host.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${REPO_ROOT}/work"
TOOLS_DIR="${WORK_DIR}/tools"
XS_DIR="${WORK_DIR}/XiangShan-kmhv2"

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
step "5/6 检查上游仓库"
if [ -d "${XS_DIR}/.git" ] || [ -f "${XS_DIR}/.git" ]; then
  info "XiangShan: $(git -C "${XS_DIR}" rev-parse HEAD) ($(git -C "${XS_DIR}" rev-parse --abbrev-ref HEAD))"
  if [ -f "${XS_DIR}/yunsuan/build.sc" ]; then
    info "yunsuan  : $(git -C "${XS_DIR}/yunsuan" rev-parse HEAD)"
  else
    info "yunsuan 子模块未检出，执行： git -C ${XS_DIR} submodule update --init yunsuan"
  fi
else
  info "未找到 ${XS_DIR}；请先 clone：
    git clone -b kunminghu-v2 https://github.com/OpenXiangShan/XiangShan.git ${XS_DIR}
    git -C ${XS_DIR} submodule update --init yunsuan rocket-chip utility difftest ready-to-run"
fi

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
