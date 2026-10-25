#!/usr/bin/env bash
# =============================================================================
# 01_setup_env_docker.sh
#   构建 xsdev 容器镜像（香山/NEMU 软件侧可复现环境），并提供在容器内
#   执行命令的辅助入口。
#
# 用法：
#   ./scripts/01_setup_env_docker.sh build          # 构建镜像（日志 tee 到 logs/stage1/）
#   ./scripts/01_setup_env_docker.sh info           # 打印镜像与工具链版本
#   ./scripts/01_setup_env_docker.sh shell          # 进入交互式容器
#   ./scripts/01_setup_env_docker.sh xsdev <cmd...> # 在容器内执行一条命令
#
# 也可以 source 本脚本后直接使用 xsdev 函数：
#   source ./scripts/01_setup_env_docker.sh
#   xsdev riscv64-linux-gnu-gcc --version
#
# 约定：交付仓库根目录与 WORK_DIR 以宿主机上的**同一绝对路径**挂载进容器，
#       NEMU_HOME=${WORK_DIR}/NEMU 通过 -e 传入（与 scripts/lib/common.sh 的 xrun 一致）。
#
# 镜像与平台默认按宿主架构选择（x86_64 -> linux/amd64，arm64 -> linux/arm64），
# 可用 XSDEV_IMAGE / XSDEV_PLATFORM 覆盖。Linux x86_64 宿主机上不需要本镜像：
# 交付脚本默认直接在宿主机执行（XS_RUNNER=host），只有设置 XS_RUNNER=docker 时才会用到。
# =============================================================================
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/common.sh"
IMAGE_NAME="${XSDEV_IMAGE}"
DOCKERFILE="${REPO_ROOT}/scripts/docker/Dockerfile.xsdev"
LOG_DIR="${LOG_ROOT}/stage1"

# 在容器内执行命令（Linux 宿主上以当前 uid/gid 运行，避免产出 root 所属文件）。
_docker_args() {
    local args=(--platform "${XSDEV_PLATFORM}" -v "${REPO_ROOT}:${REPO_ROOT}" -w "${REPO_ROOT}"
                -e NEMU_HOME="${NEMU_DIR}" -e WORK_DIR="${WORK_DIR}" -e XS_RUNNER=host)
    case "${WORK_DIR}/" in "${REPO_ROOT}/"*) ;; *) args+=(-v "${WORK_DIR}:${WORK_DIR}") ;; esac
    if [ "${HOST_OS}" = "Linux" ]; then args+=(--user "$(id -u):$(id -g)" -e HOME=/tmp); fi
    printf '%s\0' "${args[@]}"
}

xsdev() {
    local a=(); while IFS= read -r -d '' x; do a+=("$x"); done < <(_docker_args)
    docker run --rm -i "${a[@]}" "${IMAGE_NAME}" bash -lc "$*"
}

xsdev_tty() {
    local a=(); while IFS= read -r -d '' x; do a+=("$x"); done < <(_docker_args)
    docker run --rm -it "${a[@]}" "${IMAGE_NAME}" "$@"
}

do_build() {
    mkdir -p "${LOG_DIR}"
    echo "[xsdev] building ${IMAGE_NAME} from ${DOCKERFILE}"
    docker build \
        --platform "${XSDEV_PLATFORM}" \
        --progress=plain \
        -f "${DOCKERFILE}" \
        -t "${IMAGE_NAME}" \
        "${REPO_ROOT}/scripts/docker" 2>&1 | tee "${LOG_DIR}/p1_docker_build.log"
    echo "[xsdev] image size:"
    docker images "${IMAGE_NAME}" --format '{{.Repository}}:{{.Tag}}  {{.Size}}' \
        | tee -a "${LOG_DIR}/p1_docker_build.log"
}

do_info() {
    docker images "${IMAGE_NAME}" --format 'IMAGE  {{.Repository}}:{{.Tag}}  ID={{.ID}}  SIZE={{.Size}}'
    xsdev 'echo "uname      : $(uname -m) $(uname -s)";
           echo "ubuntu     : $(. /etc/os-release; echo $PRETTY_NAME)";
           echo "gcc        : $(gcc --version | head -n1)";
           echo "rv64-gcc   : $(riscv64-linux-gnu-gcc --version | head -n1)";
           echo "rv64-gcc14 : $(riscv64-linux-gnu-gcc-14 --version | head -n1)";
           echo "rv64-elf   : $(riscv64-unknown-elf-gcc --version | head -n1)";
           echo "rv64-ld    : $(riscv64-linux-gnu-ld --version | head -n1)";
           echo "make       : $(make --version | head -n1)";
           echo "cmake      : $(cmake --version | head -n1)";
           echo "python3    : $(python3 --version)";
           echo "dtc        : $(dtc --version | head -n1)"'
}

case "${1:-}" in
    build) do_build ;;
    info)  do_info ;;
    shell) xsdev_tty /bin/bash ;;
    xsdev) shift; xsdev "$@" ;;
    "")    : ;;  # 被 source 时不做任何事，只导出 xsdev 函数
    *)     echo "unknown subcommand: $1" >&2; exit 1 ;;
esac
