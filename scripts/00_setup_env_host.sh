#!/usr/bin/env bash
# =============================================================================
# 00_setup_env_host.sh —— 宿主机工具链与上游仓库一键准备（幂等，可重复执行）
#
# 支持两种宿主：
#   * Linux x86_64 / aarch64（Ubuntu 22.04 / 24.04 实测 x86_64）：检查系统依赖，缺什么就
#     打印对应的 apt-get 命令后退出；无 root 权限时可用 LOCAL_SYSROOT=1 把 readline / SDL2
#     开发包解包到 ${WORK_DIR}/sysroot（不需要 sudo）。NEMU / 交叉编译 / 协同仿真直接
#     在宿主机执行，不需要 Docker。
#   * macOS / Apple Silicon：用 Homebrew 安装 verilator / openjdk@17 / gnu-sed / cmake，
#     并自建 arm64 原生 espresso；NEMU 一侧在 Docker 容器里执行（见 01_setup_env_docker.sh）。
#
# 步骤：
#   0 检查运行环境   1 系统依赖   2 mill 启动脚本   3 按 pin 克隆 XiangShan / NEMU
#   4 espresso       5 生成 ${WORK_DIR}/tools/env.local.sh（本机路径，不入库）
#   6 生成打了 vdot 补丁的两棵工作树（scripts/04_make_vdot_trees.sh）  7 版本核对
#
# 用法：
#   bash scripts/00_setup_env_host.sh
#   WORK_DIR=/path/to/work bash scripts/00_setup_env_host.sh   # 指定另一个工作目录
#
# 可选环境变量：
#   WORK_DIR=<dir>   上游仓库与构建产物目录（默认 <仓库根>/work）
#   SKIP_CLONE=1     跳过克隆（仓库已就位时用；缺仓库仍会报错退出）
#   SKIP_TREES=1     跳过第 6 步
#   LOCAL_SYSROOT=1  （Linux）无 root 时把 libreadline-dev / libsdl2-dev 及其运行库
#                    用 apt-get download + dpkg -x 解包到 ${WORK_DIR}/sysroot
#   XS_REF=<sha>     覆盖 XiangShan 的锁定 commit
#   NEMU_REF=<sha>   覆盖 NEMU 的锁定 commit
#
# 执行后，后续脚本会自动 source scripts/env_host.sh；交互使用时：
#   source scripts/env_host.sh
# =============================================================================
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

XS_DIR="${XS_PRISTINE}"

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
SKIP_TREES="${SKIP_TREES:-0}"
LOCAL_SYSROOT="${LOCAL_SYSROOT:-0}"

# -----------------------------------------------------------------------------
step "0/7 检查运行环境"
info "uname    : $(uname -srm)"
info "WORK_DIR : ${WORK_DIR}"
case "${HOST_OS}" in
  Darwin)
    info "macOS    : $(sw_vers -productVersion) (build $(sw_vers -buildVersion))"
    info "CPU 核数 : $(sysctl -n hw.ncpu)"
    info "物理内存 : $(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 )) GB"
    command -v brew >/dev/null 2>&1 || die "需要 Homebrew，请先安装：https://brew.sh"
    info "brew     : $(brew --version | head -1)"
    ;;
  Linux)
    info "发行版   : $( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}") || echo unknown)"
    info "CPU 核数 : $(getconf _NPROCESSORS_ONLN)"
    info "物理内存 : $(awk '/MemTotal/{printf "%d GB", $2/1024/1024}' /proc/meminfo)"
    ;;
  *) die "不支持的宿主系统：${HOST_OS}" ;;
esac

# -----------------------------------------------------------------------------
fetch_local_sysroot() {
  # 无 root 权限时，把 NEMU 需要的开发包与它们在本机缺失的运行库解包到 ${NEMU_SYSROOT}。
  # 只下载「本机未安装」的包，dpkg -x 解包，不执行任何安装脚本，不写系统目录。
  need_cmd apt-get; need_cmd apt-cache; need_cmd dpkg
  local deb="${WORK_DIR}/sysroot-debs"
  mkdir -p "${deb}" "${NEMU_SYSROOT}"
  local want=() p
  for p in libreadline-dev libsdl2-dev; do
    dpkg -s "${p}" >/dev/null 2>&1 || want+=("${p}")
  done
  # 运行库闭包（链接 -lSDL2 时 ld 需要找到 libSDL2 依赖的全部 .so）
  while read -r p; do
    case "${p}" in lib*) dpkg -s "${p}" >/dev/null 2>&1 || want+=("${p}") ;; esac
  done < <(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
             --no-breaks --no-replaces --no-enhances libsdl2-2.0-0 libreadline8 2>/dev/null \
           | grep -E '^[a-zA-Z0-9]' | sort -u)
  if [ "${#want[@]}" -eq 0 ]; then info "所需开发包均已安装，无需本地 sysroot"; return 0; fi
  info "apt-get download → dpkg -x ${NEMU_SYSROOT}：${want[*]}"
  ( cd "${deb}" && apt-get download "${want[@]}" ) || die "apt-get download 失败（需要能访问 apt 源）"
  for p in "${deb}"/*.deb; do dpkg -x "${p}" "${NEMU_SYSROOT}"; done
  info "已解包到 ${NEMU_SYSROOT}"
}

step "1/7 系统依赖"
if [ "${HOST_OS}" = "Darwin" ]; then
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
  [ -x "$(brew --prefix openjdk@17)/bin/java" ] || die "openjdk@17 安装异常"
  command -v docker >/dev/null 2>&1 || warn "未找到 docker：NEMU / 交叉编译在 macOS 上需要 Docker Desktop（见 01_setup_env_docker.sh）"
else
  # Linux：本脚本不调用 sudo，缺什么列出来，由使用者决定怎么装。
  missing=()
  for c in git curl rsync file make gcc g++ bison flex python3 verilator; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [ "${#missing[@]}" -eq 0 ] || { echo "ERROR: 缺少命令：${missing[*]}" >&2; hint_install >&2; exit 1; }
  info "基础命令齐全：git curl rsync file make gcc g++ bison flex python3 verilator"

  # JDK 17
  load_host_env
  case "$(java -version 2>&1)" in *'version "17.'*|*'version "17"'*) true ;; *) false ;; esac \
    || { echo "ERROR: 需要 JDK 17（当前：$(java -version 2>&1 | head -1)）" >&2; hint_install >&2; exit 1; }
  info "java     : $(java -version 2>&1 | head -1)  (JAVA_HOME=${JAVA_HOME:-})"

  # Verilator：本项目在 5.024（Linux）与 5.052（macOS）上实测；4.x 未验证
  vmaj="$(verilator --version | awk '{print $2}' | cut -d. -f1)"
  [ "${vmaj:-0}" -ge 5 ] || warn "verilator $(verilator --version) 未经验证，建议 >= 5.0（Ubuntu 24.04 apt 为 5.020；22.04 需源码编译 v5.024）"
  info "verilator: $(verilator --version)"

  # readline / SDL2 / zlib / zstd 开发包
  if [ "${LOCAL_SYSROOT}" = "1" ]; then fetch_local_sysroot; fi
  setup_nemu_host_deps
  info "NEMU 开发包：readline / SDL2 / zlib / zstd 头文件均可用${CFLAGS:+（经 ${NEMU_SYSROOT}）}"

  # RISC-V 交叉编译器
  detect_cross
  info "CROSS    : ${CROSS}  ($("${CROSS}gcc" --version | head -1))"

  "${PYTHON}" -c 'import matplotlib' 2>/dev/null \
    || warn "${PYTHON} 缺 matplotlib：40_run_bench.sh 的绘图步骤会跳过。安装：pip install matplotlib（或 python3 -m venv 后安装，并用 PYTHON=<venv>/bin/python 指定）"
  if command -v fc-list >/dev/null 2>&1 && ! grep -qiE 'Noto Sans CJK|WenQuanYi|Droid Sans Fallback' <<<"$(fc-list 2>/dev/null)"; then
    warn "未找到 CJK 字体：40_run_bench.sh 绘出的中文标注会显示为方框。安装：sudo apt-get install -y fonts-noto-cjk"
  fi
fi

# -----------------------------------------------------------------------------
step "2/7 安装 mill 启动脚本（实际版本由各仓库 .mill-version 决定）"
# XiangShan 根仓库 .mill-version = 0.12.3；yunsuan 子模块 .mill-version = 0.11.1。
# 官方 mill 启动脚本会读取当前目录的 .mill-version 并自动下载对应 assembly，
# 因此只需装启动脚本本身，版本由仓库决定。
mkdir -p "${TOOLS_DIR}/mill" "${TOOLS_DIR}/bin"
for V in 0.11.1 0.12.3; do
  TGT="${TOOLS_DIR}/mill/mill-${V}"
  if [ -s "$TGT" ]; then
    info "已存在，跳过: mill-${V}"
  else
    info "下载 mill 启动脚本 ${V}"
    curl -fL --retry 3 --no-progress-meter \
      -o "$TGT.part" "https://github.com/com-lihaoyi/mill/releases/download/${V}/${V}"
    mv "$TGT.part" "$TGT"
    chmod +x "$TGT"
  fi
done
# 统一入口 `mill`：由 .mill-version 决定实际版本
ln -sf "${TOOLS_DIR}/mill/mill-0.11.1" "${TOOLS_DIR}/mill/mill"

# -----------------------------------------------------------------------------
step "3/7 克隆并校验上游仓库（XiangShan-kmhv2 / NEMU）"
# 规则：
#   * 已存在的仓库【只读校验、绝不改动】—— 这些目录可能正被其他人的在制工作占用。
#   * 不存在的仓库才 clone；clone/检出失败一律 die。
#   * SKIP_CLONE=1 时不 clone，但仓库缺失仍然 die。

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
    || { rm -rf "${dir}"; die "${name} clone 失败：${url}"; }
  if ! git -C "${dir}" -c advice.detachedHead=false checkout --quiet "${pin}"; then
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
  git -C "${XS_DIR}" submodule update --init --recursive --jobs 8 "${missing[@]}" \
    || die "submodule update --init --recursive ${missing[*]} 失败"
fi
# rocket-chip 的嵌套子模块（cde / hardfloat / torture）单独兜底
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

[ -f "${XS_DIR}/yunsuan/build.sc" ] \
  || die "yunsuan 子模块检出异常：${XS_DIR}/yunsuan/build.sc 不存在"
info "XiangShan: $(git -C "${XS_DIR}" rev-parse HEAD)"
info "yunsuan  : $(git -C "${XS_DIR}/yunsuan" rev-parse HEAD)"
info "NEMU     : $(git -C "${NEMU_DIR}" rev-parse HEAD)"

# -----------------------------------------------------------------------------
step "4/7 espresso（Chisel decoder 的逻辑最小化器）"
# yunsuan/src/main/resources/espresso 是上游自带的 Linux x86-64 ELF，yunsuan 的 build.sc
# 把该目录追加在 PATH 末尾。为了让 XiangShan 侧的精化也用同一个 espresso，统一放一份到
# ${TOOLS_DIR}/bin（env_host.sh 会把它放在 PATH 最前）：
#   * Linux x86_64：直接复制上游自带的那一份；
#   * macOS / Linux aarch64：上游那份无法执行（返回 126），从源码自建原生版本。
ESP_UPSTREAM="${XS_DIR}/yunsuan/src/main/resources/espresso"
if [ -x "${TOOLS_DIR}/bin/espresso" ] && \
   printf '.i 2\n.o 1\n.p 2\n01 1\n10 1\n.e\n' | "${TOOLS_DIR}/bin/espresso" >/dev/null 2>&1; then
  info "已存在可执行的 espresso，跳过"
elif [ "${HOST_OS}" = "Linux" ] && [ "${HOST_ARCH}" = "x86_64" ] && [ -f "${ESP_UPSTREAM}" ]; then
  cp -f "${ESP_UPSTREAM}" "${TOOLS_DIR}/bin/espresso"
  chmod +x "${TOOLS_DIR}/bin/espresso"
  info "复制上游自带的 x86-64 espresso"
else
  [ -d "${TOOLS_DIR}/espresso-logic" ] || \
    git clone --depth=1 https://github.com/classabbyamp/espresso-logic "${TOOLS_DIR}/espresso-logic"
  make -C "${TOOLS_DIR}/espresso-logic/espresso-src" >/dev/null
  cp "${TOOLS_DIR}/espresso-logic/bin/espresso" "${TOOLS_DIR}/bin/espresso"
fi
printf '.i 2\n.o 1\n.p 2\n01 1\n10 1\n.e\n' | "${TOOLS_DIR}/bin/espresso" >/dev/null \
  || die "espresso 自检失败"
info "espresso : $(file -b "${TOOLS_DIR}/bin/espresso" | cut -d, -f1-2)"

# -----------------------------------------------------------------------------
step "5/7 生成本机环境文件 ${TOOLS_DIR}/env.local.sh（位于 work/ 下，不入库）"
load_host_env
{
  echo "# 由 scripts/00_setup_env_host.sh 于 $(date '+%Y-%m-%d %H:%M:%S') 按本机探测结果生成，不入库。"
  echo "# 被 scripts/env_host.sh 自动载入。"
  [ -n "${JAVA_HOME:-}" ] && echo "export JAVA_HOME=\"${JAVA_HOME}\""
  if [ "${HOST_OS}" = "Linux" ] && [ -n "${CROSS:-}" ]; then
    echo "export CROSS=\"\${CROSS:-${CROSS}}\""
  fi
} > "${TOOLS_DIR}/env.local.sh"
sed 's/^/    /' "${TOOLS_DIR}/env.local.sh"

# -----------------------------------------------------------------------------
if [ "${SKIP_TREES}" = "1" ]; then
  step "6/7 跳过补丁工作树（SKIP_TREES=1）"
else
  step "6/7 生成补丁工作树 XiangShan-vdot / XiangShan-cosim"
  bash "${REPO_ROOT}/scripts/04_make_vdot_trees.sh" all
fi

# -----------------------------------------------------------------------------
step "7/7 版本核对"
printf '%-16s %s\n' "uname"     "$(uname -srm)"
[ "${HOST_OS}" = "Darwin" ] && printf '%-16s %s\n' "macOS" "$(sw_vers -productVersion)"
printf '%-16s %s\n' "verilator" "$(verilator --version 2>/dev/null || echo N/A)"
printf '%-16s %s\n' "java"      "$(java -version 2>&1 | head -1)"
printf '%-16s %s\n' "JAVA_HOME" "${JAVA_HOME:-}"
printf '%-16s %s\n' "gcc"       "$(gcc --version 2>/dev/null | head -1)"
[ -n "${CROSS:-}" ] && printf '%-16s %s\n' "CROSS" "${CROSS} ($("${CROSS}gcc" --version | head -1))"
printf '%-16s %s\n' "espresso"  "$(command -v espresso)"
printf '%-16s %s\n' "mill(启动)" "$(command -v mill)"
if [ -f "${XS_DIR}/yunsuan/.mill-version" ]; then
  printf '%-16s %s\n' "mill(yunsuan)" "$(cat "${XS_DIR}/yunsuan/.mill-version")"
  printf '%-16s %s\n' "mill(XiangShan)" "$(cat "${XS_DIR}/.mill-version" 2>/dev/null)"
fi

printf '\n\033[1;32m环境搭建完成（WORK_DIR=%s）。交互使用前请执行： source %s/scripts/env_host.sh\033[0m\n' "${WORK_DIR}" "${REPO_ROOT}"
