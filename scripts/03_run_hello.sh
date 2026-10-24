#!/usr/bin/env bash
# =============================================================================
# 03_run_hello.sh —— 赛题阶段一 1.1 环境验证
#   交叉编译 tests/riscv/hello 并在 NEMU(riscv64-xs-kmhv2 独立解释器) 上真实执行，
#   由 RISC-V 程序自己通过 UARTLITE 串口打印：
#       hello xiangshan, I am cie2026-vdot, IP address <本机IP>
#
# 本机 IP 的取得方式（宿主机 macOS 上执行，不在容器里取，容器取到的是容器 IP）：
#   iface=$(route -n get default | awk '/interface:/{print $2}')
#   ipconfig getifaddr "$iface"
#
# 用法： ./scripts/03_run_hello.sh            # 自动探测本机 IP
#        HOST_IP=10.0.0.5 ./scripts/03_run_hello.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
IMAGE="${XSDEV_IMAGE:-xsdev:ubuntu24.04-arm64}"
LOG_DIR="${REPO_ROOT}/logs/stage1"
mkdir -p "${LOG_DIR}"

# ---------- 1. 在宿主机取得本机真实 IP ----------
detect_host_ip() {
    if [ "$(uname -s)" = "Darwin" ]; then
        local iface
        iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
        [ -n "${iface}" ] && ipconfig getifaddr "${iface}"
    else
        ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
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
echo "\$ route -n get default | awk '/interface:/{print \$2}'"
route -n get default 2>/dev/null | awk '/interface:/{print $2}'
echo "\$ ipconfig getifaddr \$(route -n get default | awk '/interface:/{print \$2}')"
echo "${HOST_IP}"
echo "\$ ifconfig \$(route -n get default | awk '/interface:/{print \$2}') | grep 'inet '"
ifconfig "$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')" 2>/dev/null | grep 'inet ' || true
echo
echo "### [1] 容器内交叉编译验证程序（tests/riscv/hello）"
docker run --rm --platform linux/arm64 -v "${REPO_ROOT}:/work" -w /work/tests/riscv/hello "${IMAGE}" \
    bash -lc "git config --global --add safe.directory /work/work/NEMU >/dev/null 2>&1;
              echo '\$ riscv64-linux-gnu-gcc --version'; riscv64-linux-gnu-gcc --version | head -1;
              echo '\$ make clean && make NEMU_HOME=/work/work/NEMU HOST_IP=${HOST_IP}';
              make clean >/dev/null; make NEMU_HOME=/work/work/NEMU HOST_IP=${HOST_IP}"
echo
echo "### [2] 证据：产物是 RISC-V 机器码，字符串与串口写操作都在程序里"
docker run --rm --platform linux/arm64 -v "${REPO_ROOT}:/work" -w /work/tests/riscv/hello "${IMAGE}" \
    bash -lc "echo '\$ file build/hello.elf'; file build/hello.elf;
              echo; echo '\$ ls -l build/hello.bin'; ls -l build/hello.bin;
              echo; echo '\$ riscv64-linux-gnu-readelf -h build/hello.elf | grep -E \"Machine|Entry\"';
              riscv64-linux-gnu-readelf -h build/hello.elf | grep -E 'Machine|Entry';
              echo; echo '\$ strings -t x build/hello.bin | grep \"hello xiangshan\"   (验证串只存在于程序的只读数据里)';
              strings -t x build/hello.bin | grep 'hello xiangshan';
              echo; echo '\$ grep -n -B4 -A4 40600004 build/hello.dis   (putch 被内联：lui 0x40600 + addi 4 得到 TX FIFO 地址，再 sb 写字节)';
              grep -n -B4 -A4 '40600004' build/hello.dis | head -10;
              echo; echo '\$ grep -n -B2 -A3 vadd.vv build/hello.dis   (RVV 1.0 向量加法自检段)';
              grep -n -B2 -A3 'vadd.vv' build/hello.dis | head -10"
echo
echo "### [3] 在 NEMU 上实际执行（独立解释器，batch 模式）"
echo "\$ \$NEMU_HOME/build/riscv64-nemu-interpreter -b --log=build/nemu-run.log build/hello.bin"
echo "--------------------- 以下为模拟器实际输出 ---------------------"
docker run --rm --platform linux/arm64 -v "${REPO_ROOT}:/work" -w /work/tests/riscv/hello "${IMAGE}" \
    bash -lc "stdbuf -o0 -e0 /work/work/NEMU/build/riscv64-nemu-interpreter -b \
                  --log=build/nemu-run.log build/hello.bin;
              rc=\$?;
              echo;
              echo '--------------------- 模拟器输出结束 ---------------------';
              echo \"NEMU 进程退出码 = \$rc\";
              echo;
              echo '### [4] NEMU 自身运行日志（--log=build/nemu-run.log）';
              cat build/nemu-run.log"
echo
echo "=============================================================="
echo " 结束 $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
echo "=============================================================="
}

run_all 2>&1 | tee "${LOG_DIR}/p1_hello_xiangshan.log"
