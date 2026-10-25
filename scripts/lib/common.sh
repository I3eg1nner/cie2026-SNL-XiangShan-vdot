# shellcheck shell=bash
# =============================================================================
# scripts/lib/common.sh —— 交付脚本公共部分：路径、平台判别、执行方式、依赖检查
#
# 由 scripts/0*.sh ~ 4*.sh 在开头 source。只定义变量和函数，不产生副作用
# （唯一例外：确保 WORK_DIR 目录存在）。
#
# ---- 可配置的环境变量（均有默认值）----------------------------------------
#   WORK_DIR      上游仓库与构建产物所在目录        默认 <仓库根>/work
#   LOG_ROOT      日志根目录（下分 stage1/2/3）     默认 <仓库根>/logs
#   RESULTS_DIR   P7 的 CSV 输出目录                默认 <仓库根>/bench/results
#   FIG_DIR       P7 的图表输出目录                 默认 <仓库根>/docs/stage3/figures
#   BUILD_ROOT    交付仓库内测试程序的树外构建目录  默认 ${WORK_DIR}/build
#   XS_RUNNER     NEMU / 交叉编译 / cosim 在哪里执行：
#                   auto（默认）：Linux 宿主机直接执行；macOS 进 Docker 容器
#                   host        ：强制宿主机执行
#                   docker      ：强制进 Docker 容器（镜像见 scripts/docker/）
#   XSDEV_IMAGE   Docker 镜像名     默认 xsdev:ubuntu24.04-<amd64|arm64>（按宿主架构）
#   XSDEV_PLATFORM Docker 平台      默认 linux/<amd64|arm64>（按宿主架构）
#   CROSS         RISC-V 交叉工具链前缀（需支持 -march=rv64gcv_zve64x，GCC >= 12）
#                   宿主机模式下未设置时自动探测；容器模式默认 riscv64-linux-gnu-
#   NEMU_SYSROOT  readline / SDL2 开发包的本地解包目录（无 root 权限时使用，
#                   由 `LOCAL_SYSROOT=1 bash scripts/00_setup_env_host.sh` 生成）
#                   默认 ${WORK_DIR}/sysroot（存在时自动启用）
#   JOBS          并行度                            默认 CPU 核数
#   PYTHON        Python 解释器                     默认 python3
# =============================================================================

[ -n "${_CIE_COMMON_LOADED:-}" ] && return 0
_CIE_COMMON_LOADED=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
mkdir -p "${WORK_DIR}"
WORK_DIR="$(cd "${WORK_DIR}" && pwd)"
export WORK_DIR

LOG_ROOT="${LOG_ROOT:-${REPO_ROOT}/logs}"
RESULTS_DIR="${RESULTS_DIR:-${REPO_ROOT}/bench/results}"
FIG_DIR="${FIG_DIR:-${REPO_ROOT}/docs/stage3/figures}"
BUILD_ROOT="${BUILD_ROOT:-${WORK_DIR}/build}"
export LOG_ROOT RESULTS_DIR FIG_DIR BUILD_ROOT

TOOLS_DIR="${WORK_DIR}/tools"
XS_PRISTINE="${WORK_DIR}/XiangShan-kmhv2"   # 按 pin 克隆的纯净基线
XS_VDOT="${WORK_DIR}/XiangShan-vdot"        # 阶段二：基线 + 三份补丁（L1 功能测试用）
XS_COSIM="${WORK_DIR}/XiangShan-cosim"      # 阶段三：基线 + 三份补丁（协同仿真 / P7 用）
NEMU_DIR="${WORK_DIR}/NEMU"
NEMU_SYSROOT="${NEMU_SYSROOT:-${WORK_DIR}/sysroot}"

# 00_setup_env_host.sh 按本机探测结果生成的设置（JAVA_HOME / CROSS），位于 work/ 下，不入库
if [ -f "${TOOLS_DIR}/env.local.sh" ]; then
  # shellcheck disable=SC1091
  . "${TOOLS_DIR}/env.local.sh"
fi

HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
case "${HOST_ARCH}" in
  x86_64|amd64)  _DOCKER_ARCH=amd64 ;;
  arm64|aarch64) _DOCKER_ARCH=arm64 ;;
  *)             _DOCKER_ARCH="${HOST_ARCH}" ;;
esac
XSDEV_IMAGE="${XSDEV_IMAGE:-xsdev:ubuntu24.04-${_DOCKER_ARCH}}"
XSDEV_PLATFORM="${XSDEV_PLATFORM:-linux/${_DOCKER_ARCH}}"

XS_RUNNER="${XS_RUNNER:-auto}"
if [ "${XS_RUNNER}" = "auto" ]; then
  if [ -f /.dockerenv ] || [ "${HOST_OS}" = "Linux" ]; then XS_RUNNER=host; else XS_RUNNER=docker; fi
fi
export XS_RUNNER

JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
PYTHON="${PYTHON:-python3}"
export JOBS PYTHON

step() { printf '\n\033[1;34m==> [%s] %s\033[0m\n' "$(date '+%H:%M:%S')" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# 便携的临时文件（GNU mktemp 的 -t 要求模板里带 XXX，BSD 不要求，这里统一用完整模板）
mktemp_f() { mktemp "${TMPDIR:-/tmp}/$1.XXXXXX"; }
mktemp_d() { mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX"; }

# 把仓库根以外的路径缩写成相对写法，只用于打印
relpath() { local p="$1"; p="${p#"${REPO_ROOT}"/}"; echo "${p}"; }

# -----------------------------------------------------------------------------
# 依赖提示
# -----------------------------------------------------------------------------
APT_PKGS_LINUX="build-essential git curl rsync file bison flex python3 python3-venv \
openjdk-17-jdk verilator libreadline-dev libsdl2-dev zlib1g-dev libzstd-dev libncurses-dev \
device-tree-compiler"

hint_install() {
  if [ "${HOST_OS}" = "Darwin" ]; then
    echo "  macOS：brew install verilator openjdk@17 gnu-sed cmake，并安装 Docker Desktop，"
    echo "         然后执行 bash scripts/01_setup_env_docker.sh build"
  else
    echo "  Ubuntu/Debian：sudo apt-get install -y ${APT_PKGS_LINUX}"
    echo "  RISC-V 交叉编译器（需支持 -march=rv64gcv_zve64x，即 GCC >= 12）："
    echo "    Ubuntu 24.04：sudo apt-get install -y gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu"
    echo "    Ubuntu 22.04：apt 自带的 riscv64-linux-gnu-gcc 是 11.4，不支持 RVV 1.0。请从"
    echo "      https://github.com/riscv-collab/riscv-gnu-toolchain/releases 下载"
    echo "      riscv64-elf-ubuntu-22.04-gcc-nightly-*.tar.xz，解压到 /opt/riscv，"
    echo "      并 export CROSS=/opt/riscv/bin/riscv64-unknown-elf-"
    echo "  没有 root 权限时，readline/SDL2 开发包可解包到本地：LOCAL_SYSROOT=1 bash scripts/00_setup_env_host.sh"
  fi
}

need_cmd() {  # need_cmd <命令> [说明]
  command -v "$1" >/dev/null 2>&1 && return 0
  printf '\033[1;31mERROR: 缺少命令 %s%s\033[0m\n' "$1" "${2:+（$2）}" >&2
  hint_install >&2
  exit 1
}

# -----------------------------------------------------------------------------
# 工具链环境（JDK 17 / mill / espresso）
# -----------------------------------------------------------------------------
load_host_env() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/env_host.sh"
}

# -----------------------------------------------------------------------------
# RISC-V 交叉工具链探测：必须能汇编 RVV 1.0（vsetvli / vle8.v）
# -----------------------------------------------------------------------------
cross_ok() {  # cross_ok <前缀>
  local pfx="$1" t
  command -v "${pfx}gcc" >/dev/null 2>&1 || return 1
  command -v "${pfx}objcopy" >/dev/null 2>&1 || return 1
  t="$(mktemp_d crossprobe)"
  printf '    .text\n    .globl p\np:\n    vsetvli t0, a0, e8, m1, ta, ma\n    vle8.v v1, (a1)\n    ret\n' > "${t}/p.S"
  if "${pfx}gcc" -march=rv64gcv_zve64x -mabi=lp64d -c "${t}/p.S" -o "${t}/p.o" >/dev/null 2>&1; then
    rm -rf "${t}"; return 0
  fi
  rm -rf "${t}"; return 1
}

detect_cross() {
  if [ "${XS_RUNNER}" = "docker" ]; then
    CROSS="${CROSS:-riscv64-linux-gnu-}"; export CROSS; return 0
  fi
  if [ -n "${CROSS:-}" ]; then
    cross_ok "${CROSS}" || { echo "ERROR: CROSS=${CROSS} 不可用或不支持 -march=rv64gcv_zve64x（需要 GCC >= 12）：$("${CROSS}gcc" --version 2>/dev/null | head -1)" >&2; hint_install >&2; exit 1; }
    export CROSS; return 0
  fi
  local c
  for c in riscv64-linux-gnu- riscv64-unknown-elf- riscv64-elf- \
           /opt/riscv/bin/riscv64-unknown-elf- /opt/riscv/bin/riscv64-unknown-linux-gnu- \
           /opt/riscv/bin/riscv64-linux-gnu-; do
    if cross_ok "${c}"; then CROSS="${c}"; export CROSS; return 0; fi
  done
  echo "ERROR: 找不到支持 -march=rv64gcv_zve64x 的 RISC-V 交叉编译器（需要 GCC >= 12）。" >&2
  for c in riscv64-linux-gnu- riscv64-unknown-elf-; do
    command -v "${c}gcc" >/dev/null 2>&1 && echo "  已找到但版本过旧：$(command -v "${c}gcc")  $("${c}gcc" --version | head -1)" >&2
  done
  hint_install >&2
  exit 1
}

# -----------------------------------------------------------------------------
# NEMU 宿主机构建依赖：readline / SDL2 / zlib / zstd 头文件
# 系统未安装时，若存在 ${NEMU_SYSROOT}（apt-get download + dpkg -x 解包而来），
# 通过 CFLAGS / LDFLAGS（NEMU 的 Makefile 以 += 追加）引入，不改 NEMU 源码。
# -----------------------------------------------------------------------------
_hdr_ok() { printf '#include <%s>\n' "$1" | gcc ${CFLAGS:-} -E -x c - >/dev/null 2>&1; }

setup_nemu_host_deps() {
  [ "${XS_RUNNER}" = "host" ] || return 0
  need_cmd gcc "build-essential"
  need_cmd g++ "build-essential"
  need_cmd make "build-essential"
  need_cmd bison
  need_cmd flex
  if [ -d "${NEMU_SYSROOT}/usr/include" ]; then
    local triple; triple="$(gcc -print-multiarch 2>/dev/null || true)"
    [ -n "${triple}" ] || triple="$(gcc -dumpmachine | sed 's/-pc-/-/; s/-unknown-/-/')"
    local inc="${NEMU_SYSROOT}/usr/include"
    local lib="${NEMU_SYSROOT}/usr/lib/${triple}"
    local lib2="${NEMU_SYSROOT}/lib/${triple}"
    case " ${CFLAGS:-} " in *" -I${inc} "*) ;; *)
      export CFLAGS="${CFLAGS:-} -I${inc} -I${inc}/${triple}"
      export LDFLAGS="${LDFLAGS:-} -L${lib} -Wl,-rpath,${lib} -Wl,-rpath-link,${lib} -Wl,-rpath,${lib2} -Wl,-rpath-link,${lib2}"
      export LD_LIBRARY_PATH="${lib}:${lib}/pulseaudio:${lib2}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
      ;;
    esac
  fi
  local missing=()
  _hdr_ok readline/readline.h || missing+=("libreadline-dev")
  _hdr_ok SDL2/SDL.h          || missing+=("libsdl2-dev")
  _hdr_ok zlib.h              || missing+=("zlib1g-dev")
  _hdr_ok zstd.h              || missing+=("libzstd-dev")
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: NEMU 构建缺少开发包：${missing[*]}" >&2
    echo "  有 root 权限：sudo apt-get install -y ${missing[*]}" >&2
    echo "  无 root 权限：LOCAL_SYSROOT=1 bash scripts/00_setup_env_host.sh   （解包到 ${NEMU_SYSROOT}）" >&2
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# xrun "<shell 命令串>" —— 在宿主机或 xsdev 容器里执行一段 bash
#   容器模式下把 REPO_ROOT / WORK_DIR / BUILD_ROOT 以**相同路径**挂载进容器，
#   因此命令串里可以直接使用宿主机绝对路径，不再有 /work 之类的路径换算。
# -----------------------------------------------------------------------------
xrun() {
  local cmd="$1"
  if [ "${XS_RUNNER}" = "host" ]; then
    NEMU_HOME="${NEMU_DIR}" bash -c "set -euo pipefail; ${cmd}"
    return $?
  fi
  command -v docker >/dev/null 2>&1 || die "XS_RUNNER=docker 但找不到 docker 命令"
  docker image inspect "${XSDEV_IMAGE}" >/dev/null 2>&1 \
    || die "找不到镜像 ${XSDEV_IMAGE}，请先执行 bash scripts/01_setup_env_docker.sh build"
  local mounts=(-v "${REPO_ROOT}:${REPO_ROOT}")
  local d
  for d in "${WORK_DIR}" "${BUILD_ROOT}"; do
    mkdir -p "${d}"
    case "${d}/" in "${REPO_ROOT}/"*) ;; *) mounts+=(-v "${d}:${d}") ;; esac
  done
  local user=()
  if [ "${HOST_OS}" = "Linux" ]; then user=(--user "$(id -u):$(id -g)" -e HOME=/tmp); fi
  docker run --rm -i --platform "${XSDEV_PLATFORM}" "${user[@]}" "${mounts[@]}" \
    -w "${REPO_ROOT}" \
    -e NEMU_HOME="${NEMU_DIR}" -e WORK_DIR="${WORK_DIR}" -e BUILD_ROOT="${BUILD_ROOT}" \
    -e CROSS="${CROSS:-riscv64-linux-gnu-}" -e XS_RUNNER=host -e JOBS="${JOBS}" \
    "${XSDEV_IMAGE}" \
    bash -c "git config --global --add safe.directory '*' >/dev/null 2>&1 || true; set -euo pipefail; ${cmd}"
}

# 把需要构建的测试源码（tests/riscv、tests/vectors、tests/golden、bench/baseline）
# 同步到 ${BUILD_ROOT}/src 下，保持相对目录结构，在副本里 make。
# 这样构建产物不落进交付仓库，多个工作目录之间也互不干扰。
STAGE_DIR="${BUILD_ROOT}/src"
stage_tests() {
  mkdir -p "${STAGE_DIR}/tests" "${STAGE_DIR}/bench"
  local d
  for d in tests/riscv tests/vectors tests/golden bench/baseline; do
    mkdir -p "${STAGE_DIR}/${d}"
    rsync -a --delete --exclude 'build/' "${REPO_ROOT}/${d}/" "${STAGE_DIR}/${d}/"
  done
}

# 当某个 scripts/tools/*.sh 仍然写死 ${REPO_ROOT}/work 时，确认它与 WORK_DIR 指向同一处
require_tool_workdir() {  # require_tool_workdir <tool 脚本路径>
  local tool="$1"
  grep -q 'WORK_DIR' "${tool}" && return 0
  local a b
  a="$(cd "${REPO_ROOT}/work" 2>/dev/null && pwd -P || echo "<不存在>")"
  b="$(cd "${WORK_DIR}" && pwd -P)"
  [ "${a}" = "${b}" ] && return 0
  die "$(relpath "${tool}") 写死使用 ${REPO_ROOT}/work，与 WORK_DIR=${WORK_DIR} 不一致。
       请不设 WORK_DIR，或建立符号链接：ln -s '${WORK_DIR}' '${REPO_ROOT}/work'"
}

# 上游 yunsuan emu.cpp 的 timestamp_filename() 用 getcwd(cwd, 64) 取当前目录并把 VCD 写到
# <cwd>/build/；目录超过 63 字节时 getcwd 失败，VCD 被写到不存在的 /build/ 而静默丢失。
# 在 yunsuan 目录里带 --dump-wave 运行 emu 之前调用本函数做检查。
require_short_emu_cwd() {  # require_short_emu_cwd <yunsuan 目录>
  local d; d="$(cd "$1" && pwd -P)"
  [ "${#d}" -le 63 ] && return 0
  die "yunsuan 目录路径 ${d} 长 ${#d} 字节，超过上游 emu 的 63 字节限制（emu.cpp getcwd(cwd, 64)），
       波形会丢失。请把 WORK_DIR 设到更短的路径后重跑（例如 WORK_DIR=\$HOME/xswork）。"
}
