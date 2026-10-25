# shellcheck shell=bash
# =============================================================================
# env_host.sh —— 硬件侧（mill / Chisel / Verilator）构建环境变量
#
# 用法： source scripts/env_host.sh
#
# 本文件可移植、不含任何本机绝对路径：
#   * WORK_DIR 未设置时取 <仓库根>/work；
#   * 若存在 ${WORK_DIR}/tools/env.local.sh（由 scripts/00_setup_env_host.sh 按本机
#     探测结果生成，位于被 .gitignore 排除的 work/ 下，不入库），先载入它；
#   * JAVA_HOME 若未指向 JDK 17，按平台自动寻找 JDK 17
#     （mill 0.11.x / 0.12.x + Scala 2.13.15 在 JDK 21/25 下会失败）；
#   * 把 ${WORK_DIR}/tools/bin（espresso 等）和 ${WORK_DIR}/tools/mill 放到 PATH 最前。
# 可在 `set -euo pipefail` 的脚本中安全 source。
# =============================================================================

_cie_env_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-${_cie_env_repo}/work}"
export WORK_DIR

if [ -f "${WORK_DIR}/tools/env.local.sh" ]; then
  # shellcheck disable=SC1091
  . "${WORK_DIR}/tools/env.local.sh"
fi

_cie_is_jdk17() {
  [ -x "$1/bin/java" ] || return 1
  case "$("$1/bin/java" -version 2>&1)" in *'version "17.'*|*'version "17"'*) return 0 ;; esac
  return 1
}

if ! _cie_is_jdk17 "${JAVA_HOME:-/nonexistent}"; then
  _cie_jh=""
  if [ "$(uname -s)" = "Darwin" ]; then
    for _c in "$(/usr/libexec/java_home -v 17 2>/dev/null || true)" \
              "$(brew --prefix openjdk@17 2>/dev/null || true)" \
              /opt/homebrew/opt/openjdk@17 /usr/local/opt/openjdk@17; do
      if [ -n "${_c}" ] && _cie_is_jdk17 "${_c}"; then _cie_jh="${_c}"; break; fi
    done
  else
    for _c in /usr/lib/jvm/java-17-openjdk-* /usr/lib/jvm/java-1.17.0-openjdk-* \
              /usr/lib/jvm/temurin-17* /usr/lib/jvm/jdk-17* /usr/lib/jvm/*17*; do
      if [ -d "${_c}" ] && _cie_is_jdk17 "${_c}"; then _cie_jh="${_c}"; break; fi
    done
  fi
  if [ -n "${_cie_jh}" ]; then
    export JAVA_HOME="${_cie_jh}"
  else
    echo "WARNING: 找不到 JDK 17（mill 需要）。Ubuntu: sudo apt-get install -y openjdk-17-jdk；macOS: brew install openjdk@17" >&2
  fi
  unset _cie_jh _c
fi

if [ -n "${JAVA_HOME:-}" ]; then
  export PATH="${WORK_DIR}/tools/bin:${WORK_DIR}/tools/mill:${JAVA_HOME}/bin:${PATH}"
else
  export PATH="${WORK_DIR}/tools/bin:${WORK_DIR}/tools/mill:${PATH}"
fi
unset _cie_env_repo
