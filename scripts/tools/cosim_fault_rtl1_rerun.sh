#!/usr/bin/env bash
# =============================================================================
# cosim_fault_rtl1_rerun.sh —— 协同仿真 RTL 侧故障注入 T3-RTL-1 的补充重跑
#
# 背景：scripts/30_run_cosim.sh 的 T3-RTL-1 把
#         "  assign io_vd ="  替换成  "  assign io_vd = 128'h1 ^"
#       而生成的 VDotTop.sv 中 io_vd 是 `isDot4aS2 ? {...} : ...` 的条件表达式。
#       Verilog 里 `^` 的优先级高于 `?:`，实际得到的是
#         (128'h1 ^ isDot4aS2) ? {...} : ...
#       即「输出格式选择取反」（vdot4a 格式与归约格式互换），不是写回结果的 bit0 翻转。
#       p6_fault_injection.log 中的 WIDTHEXPAND / WIDTHTRUNC 警告就是这一点的旁证。
#
# 本脚本在私有副本上依次跑：
#   [BASE]       未注入基线
#   [T3-RTL-1]   原注入（如实更名为「输出格式选择取反」），与 30 号脚本逐字相同
#   [T3-RTL-1b]  真正的 bit0 翻转：assign io_vd = 128'h1 ^ ( <原表达式> );
#   [RESTORE]    还原后复测，并 cmp 校验私有副本与共享源一致
# 小规模激励与 30 号脚本 small_run() 完全相同（5 份定向 + random 2000 + illegal 500，
# seed 20260324）。
#
# 只读取共享的 ${WORK_DIR:-<仓库根>/work} 树（VDotTop.sv、VdotDecodeProbe.v、NEMU 参考 .so），
# 所有修改、verilate、编译都发生在 ${PRIV} 私有目录里，不改动 work/。
#
# 用法： bash scripts/tools/cosim_fault_rtl1_rerun.sh [PRIV_DIR]
#        | tee logs/stage3/cosim/p6_fault_rtl1_rerun.log
# 依赖： verilator（已在 5.024 上验证）、g++、python3；宿主机可直接 dlopen NEMU .so
#        （即 .so 与宿主机同架构）。
# =============================================================================
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRIV="${1:-${REPO_ROOT}/../cosim-faultinj-copy}"
SRC_SV="${SRC_SV:-${WORK_DIR:-${REPO_ROOT}/work}/XiangShan-cosim/yunsuan/build/vdot/VDotTop.sv}"
SRC_DP="${SRC_DP:-${WORK_DIR:-${REPO_ROOT}/work}/XiangShan-cosim/build/vdot/VdotDecodeProbe.v}"
SRC_SO="${SRC_SO:-${WORK_DIR:-${REPO_ROOT}/work}/NEMU/build/riscv64-nemu-interpreter-so}"
SEED="${SEED:-20260324}"
VEC="${REPO_ROOT}/tests/vectors"

banner() { echo "=============================================================="; echo " $*   $(date -u +%Y-%m-%dT%H:%M:%SZ) UTC"; echo "=============================================================="; }

banner "[T3-RTL-1 补充重跑] 私有副本：${PRIV}"
echo "host      : $(uname -sm)"
echo "verilator : $(verilator --version 2>/dev/null)"
echo "g++       : $(g++ --version | head -1)"
for f in "${SRC_SV}" "${SRC_DP}" "${SRC_SO}"; do
    [ -f "$f" ] || { echo "缺少输入：$f"; exit 1; }
done

case "$(realpath -m "${PRIV}")" in
    "$(realpath -m "${REPO_ROOT}")"|"$(realpath -m "${REPO_ROOT}")"/*|/) echo "PRIV 不能位于仓库内或为根目录：${PRIV}"; exit 1 ;;
esac
rm -rf "${PRIV}"
mkdir -p "${PRIV}/src"
cp -f "${REPO_ROOT}"/tests/cosim/{Makefile,cosim_main.cpp,ref_nemu.h} "${PRIV}/"
cp -f "${SRC_SV}" "${PRIV}/src/VDotTop.sv.orig"
cp -f "${SRC_DP}" "${PRIV}/src/VdotDecodeProbe.v"
cp -f "${SRC_SO}" "${PRIV}/src/riscv64-nemu-interpreter-so"
cp -f "${PRIV}/src/VDotTop.sv.orig" "${PRIV}/src/VDotTop.sv"
echo "输入 md5："
( cd "${PRIV}/src" && md5sum VDotTop.sv.orig VdotDecodeProbe.v riscv64-nemu-interpreter-so )

SV="${PRIV}/src/VDotTop.sv"
VROOT="$(verilator --getenv VERILATOR_ROOT)"
cd "${PRIV}" || exit 1
mkdir -p build

verilator --cc --Mdir build/ddut --prefix DecodeProbeDut --top-module VdotDecodeProbe \
    -Wno-fatal src/VdotDecodeProbe.v >/dev/null 2>&1 || { echo "verilate ddut 失败"; exit 1; }

rebuild_dut() { # 重新 verilate VDotTop 并编译 cosim；只回显 WIDTH 类警告
    rm -rf build/vdut build/cosim
    verilator --cc --Mdir build/vdut --prefix VDotTopDut --top-module VDotTop -Wno-fatal \
        "${SV}" 2>&1 | grep -E '^%Warning-WIDTH' | sed "s#${PRIV}/##"
    make -s VERILATOR_INC="${VROOT}/include" >build/make.log 2>&1 || { echo "cosim 编译失败"; tail -20 build/make.log; exit 1; }
    echo "cosim md5: $(md5sum build/cosim | cut -d' ' -f1)"
}

small_run() { # 与 scripts/30_run_cosim.sh small_run() 激励相同
    ./build/cosim --so src/riscv64-nemu-interpreter-so \
        --vectors "${VEC}/positive.txt" \
        --vectors "${VEC}/negative.txt" \
        --vectors "${VEC}/boundary.txt" \
        --vectors "${VEC}/vdotacc_boundary.txt" \
        --vectors "${VEC}/vdot4a_boundary.txt" \
        --random 2000 --illegal 500 --seed "${SEED}" > build/last.txt 2>&1
    local rc=$?
    grep -E '^TOTAL|^  \[A\]|^  \[B\]|^RESULT' build/last.txt || tail -5 build/last.txt
    echo "cosim exit code = ${rc}"
    return ${rc}
}

show_io_vd() { # 打印注入点前后几行，作为「注入了什么」的直接证据
    local n; n=$(grep -n '^  assign io_vd =' "${SV}" | cut -d: -f1)
    echo "--- ${SV#${PRIV}/}:${n} 起 3 行 ---"
    sed -n "${n},$((n+2))p" "${SV}"
    local e; e=$(awk -v s="${n}" 'NR>=s && /;/ {print NR; exit}' "${SV}")
    echo "--- 表达式结束于 :${e} ---"
    sed -n "${e}p" "${SV}"
}

detected=0; total=0

banner "[BASE] 注入前基线（期望 RESULT(VALUE): PASS）"
rebuild_dut
small_run || { echo "基线不过，环境有问题"; exit 1; }

banner "[T3-RTL-1] 原注入（与 30 号脚本相同）：实际效果是 io_vd 输出格式选择取反"
python3 - "${SV}" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old, new = "  assign io_vd =", "  assign io_vd = 128'h1 ^"
assert s.count(old) == 1, s.count(old)
open(p, 'w').write(s.replace(old, new)); print("注入成功（1 处）：%s -> %s" % (old.strip(), new.strip()))
PY
show_io_vd
rebuild_dut
total=$((total+1))
if small_run; then echo ">>> T3-RTL-1 未被检出 => FAIL"; else echo ">>> T3-RTL-1 被检出 => OK"; detected=$((detected+1)); fi
cp -f src/VDotTop.sv.orig "${SV}"

banner "[T3-RTL-1b] 真正的写回结果 bit0 翻转：assign io_vd = 128'h1 ^ ( <原表达式> );"
python3 - "${SV}" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
head = "  assign io_vd ="
assert s.count(head) == 1, s.count(head)
i = s.index(head); j = s.index(';', i)
s = s[:i] + head + " 128'h1 ^ (" + s[i + len(head):j] + ");" + s[j + 1:]
open(p, 'w').write(s); print("注入成功（1 处）：整个 io_vd 表达式加括号后与 128'h1 异或")
PY
show_io_vd
rebuild_dut
total=$((total+1))
if small_run; then echo ">>> T3-RTL-1b 未被检出 => FAIL"; else echo ">>> T3-RTL-1b 被检出 => OK"; detected=$((detected+1)); fi
cp -f src/VDotTop.sv.orig "${SV}"

banner "[RESTORE] 还原后复测（期望 RESULT(VALUE): PASS）"
cmp src/VDotTop.sv.orig "${SV}" && echo "私有副本 VDotTop.sv 已还原（cmp 一致）"
cmp "${SRC_SV}" "${SV}" && echo "私有副本与共享源 VDotTop.sv 一致（共享源未被改动）"
rebuild_dut
if small_run; then echo ">>> 还原后复测 PASS"; else echo ">>> 还原后复测 FAIL"; exit 1; fi
echo
echo "FAULT-INJECTION (T3-RTL-1 补充重跑): ${detected}/${total} 被检出"
[ "${detected}" -eq "${total}" ] || exit 1
