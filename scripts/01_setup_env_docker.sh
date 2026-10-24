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
# 约定：交付仓库根目录挂载到容器内 /work（读写），容器内：
#   NEMU_HOME=/work/work/NEMU
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
IMAGE_NAME="${XSDEV_IMAGE:-xsdev:ubuntu24.04-arm64}"
DOCKERFILE="${REPO_ROOT}/scripts/docker/Dockerfile.xsdev"
LOG_DIR="${REPO_ROOT}/logs/stage1"

# 在容器内执行命令。
# 属主说明：这里【没有】传 --user。在 macOS / Docker Desktop 下，virtiofs 会把容器内
# 写出的文件映射成宿主当前用户所属，实测 build/ 产物属主正常；但容器内 `ls -l` 仍显示
# root（见 logs/stage1/p1_nemu_build.log:126 的 `root root`）。
# 在 Linux 宿主上没有这层映射，会真的生成 root 所属文件 —— 此时请自行加上
#   --user "$(id -u):$(id -g)"
# 并注意容器内 HOME 不可写与 git 的 safe.directory 两个副作用。
xsdev() {
    docker run --rm -i \
        --platform linux/arm64 \
        -v "${REPO_ROOT}:/work" \
        -w /work \
        -e NEMU_HOME=/work/work/NEMU \
        -e XS_PROJECT_ROOT=/work/work \
        "${IMAGE_NAME}" \
        bash -lc "$*"
}

xsdev_tty() {
    docker run --rm -it \
        --platform linux/arm64 \
        -v "${REPO_ROOT}:/work" \
        -w /work \
        -e NEMU_HOME=/work/work/NEMU \
        -e XS_PROJECT_ROOT=/work/work \
        "${IMAGE_NAME}" \
        "$@"
}

do_build() {
    mkdir -p "${LOG_DIR}"
    echo "[xsdev] building ${IMAGE_NAME} from ${DOCKERFILE}"
    docker build \
        --platform linux/arm64 \
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
