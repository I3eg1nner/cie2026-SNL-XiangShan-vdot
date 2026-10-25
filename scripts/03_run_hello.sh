#!/usr/bin/env bash
# =============================================================================
# 03_run_hello.sh —— 赛题阶段一 1.1 环境验证
#   交叉编译 tests/riscv/hello 并在 NEMU(riscv64-xs-kmhv2 独立解释器) 上真实执行，
#   由 RISC-V 程序自己通过 UARTLITE 串口打印：
#       hello xiangshan, I am cie2026-vdot, IP address <本机IP>
#
# 本机 IP 的取得方式（在宿主机上取，不在容器里取，容器取到的是容器 IP）：
#   macOS：iface=$(route -n get default | awk '/interface:/{print $2}'); ipconfig getifaddr "$iface"
#   Linux：ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
#
# 执行位置：Linux 宿主机直接执行；macOS 进 xsdev 容器（XS_RUNNER，见 scripts/lib/common.sh）。
# 构建产物放在 ${BUILD_ROOT}/hello（默认 ${WORK_DIR}/build/hello），不落进交付仓库。
#
# 用法： ./scripts/03_run_hello.sh            # 自动探测本机 IP
#        HOST_IP=10.0.0.5 ./scripts/03_run_hello.sh
# =============================================================================
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/common.sh"
LOG_DIR="${LOG_ROOT}/stage1"
HELLO_SRC="${REPO_ROOT}/tests/riscv/hello"
HELLO_BUILD="${BUILD_ROOT}/hello"
mkdir -p "${LOG_DIR}" "${HELLO_BUILD}"

[ -x "${NEMU_DIR}/build/riscv64-nemu-interpreter" ] \
    || die "找不到 ${NEMU_DIR}/build/riscv64-nemu-interpreter，请先执行 scripts/02_build_nemu.sh"
detect_cross
setup_nemu_host_deps   # 运行用 sysroot 构建的解释器时需要其 LD_LIBRARY_PATH

# ---------- 1. 在宿主机取得本机真实 IP ----------
default_iface() { route -n get default 2>/dev/null | awk '/interface:/{print $2}'; }
detect_host_ip() {
    if [ "${HOST_OS}" = "Darwin" ]; then
        local iface; iface="$(default_iface)"
        [ -n "${iface}" ] && ipconfig getifaddr "${iface}"
    else
        local a=""
        if command -v ip >/dev/null 2>&1; then
            a="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || true)"
        fi
        # 没有 iproute2（精简容器 / 最小化安装）时退回 hostname -I 的第一个地址
        [ -n "${a}" ] || a="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
        echo "${a}"
    fi
}
HOST_IP="${HOST_IP:-$(detect_host_ip)}"
if [ -z "${HOST_IP}" ]; then
    echo "ERROR: 无法自动探测本机 IP，请用 HOST_IP=<ip> 显式指定" >&2
    exit 1
fi

run_all() {
echo "=============================================================="
echo " 2026CIE 阶段一 1.1 环境验证   $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
echo " 团队标识 cie2026-vdot"
echo "=============================================================="
echo
echo "### [0] 宿主机取本机 IP（真实网络接口，非人为填写）"
if [ "${HOST_OS}" = "Darwin" ]; then
    echo "\$ route -n get default | awk '/interface:/{print \$2}'"
    default_iface
    echo "\$ ipconfig getifaddr \$(route -n get default | awk '/interface:/{print \$2}')"
    echo "${HOST_IP}"
    echo "\$ ifconfig \$(route -n get default | awk '/interface:/{print \$2}') | grep 'inet '"
    ifconfig "$(default_iface)" 2>/dev/null | grep 'inet ' || true
else
    if command -v ip >/dev/null 2>&1; then
        echo "\$ ip -4 route get 1.1.1.1"
        ip -4 route get 1.1.1.1 2>/dev/null | head -1 || true
        echo "${HOST_IP}"
        echo "\$ ip -4 addr show | grep 'inet ${HOST_IP}/'"
        ip -4 addr show 2>/dev/null | grep "inet ${HOST_IP}/" || true
    else
        echo "\$ hostname -I   （本机无 iproute2 的 ip 命令）"
        hostname -I 2>/dev/null || true
        echo "${HOST_IP}"
    fi
fi
echo
echo "### [1] 交叉编译验证程序（tests/riscv/hello，执行环境：${XS_RUNNER}）"
xrun "cd '${HELLO_SRC}';
      echo '\$ ${CROSS}gcc --version'; ${CROSS}gcc --version | head -1;
      echo '\$ make clean && make NEMU_HOME=${NEMU_DIR} CROSS=${CROSS} BUILD=${HELLO_BUILD} HOST_IP=${HOST_IP}';
      make clean BUILD='${HELLO_BUILD}' >/dev/null; make NEMU_HOME='${NEMU_DIR}' CROSS='${CROSS}' BUILD='${HELLO_BUILD}' HOST_IP='${HOST_IP}'"
echo
echo "### [2] 证据：产物是 RISC-V 机器码，字符串与串口写操作都在程序里"
xrun "cd '${HELLO_BUILD}';
      echo '\$ file hello.elf'; file hello.elf;
      echo; echo '\$ ls -l hello.bin'; ls -l hello.bin;
      echo; echo '\$ ${CROSS}readelf -h hello.elf | grep -E \"Machine|Entry\"';
      ${CROSS}readelf -h hello.elf | grep -E 'Machine|Entry';
      echo; echo '\$ strings -t x hello.bin | grep \"hello xiangshan\"   (验证串只存在于程序的只读数据里)';
      strings -t x hello.bin | grep 'hello xiangshan';
      echo; echo '\$ grep -n -B4 -A4 40600004 hello.dis   (putch 被内联：lui 0x40600 + addi 4 得到 TX FIFO 地址，再 sb 写字节)';
      grep -n -B4 -A4 '40600004' hello.dis | head -10 || true;
      echo; echo '\$ grep -n -B2 -A3 vadd.vv hello.dis   (RVV 1.0 向量加法自检段)';
      grep -n -B2 -A3 'vadd.vv' hello.dis | head -10 || true"
echo
echo "### [3] 在 NEMU 上实际执行（独立解释器，batch 模式）"
echo "\$ \$NEMU_HOME/build/riscv64-nemu-interpreter -b --log=nemu-run.log hello.bin"
echo "--------------------- 以下为模拟器实际输出 ---------------------"
xrun "cd '${HELLO_BUILD}';
      set +e;
      stdbuf -o0 -e0 '${NEMU_DIR}/build/riscv64-nemu-interpreter' -b --log=nemu-run.log hello.bin;
      rc=\$?;
      echo;
      echo '--------------------- 模拟器输出结束 ---------------------';
      echo \"NEMU 进程退出码 = \$rc\";
      echo;
      echo '### [4] NEMU 自身运行日志（--log=nemu-run.log）';
      cat nemu-run.log"
echo
echo "=============================================================="
echo " 结束 $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
echo "=============================================================="
}

run_all 2>&1 | tee "${LOG_DIR}/p1_hello_xiangshan.log"
