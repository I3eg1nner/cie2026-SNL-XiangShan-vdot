#!/usr/bin/env bash
# =============================================================================
# 40_run_bench.sh —— 赛题阶段三 3.2 / 3.3（P7）一键复现
#
# 一条命令重跑报告 docs/stage3/22_基线实现与延迟加速分析.md 里的**每一个数字**。
# 幂等：已经构建好的东西不会重复构建（可用 FORCE=1 强制全部重来）。
#
#   bash scripts/40_run_bench.sh
#
# 环境开关：
#   FORCE=1          强制重建 NEMU / trace 版 emu / mill 精化
#   SKIP_NEMU=1      跳过 [1]
#   SKIP_RTL=1       跳过 [2][3][4]（无 verilator / mill 时）
#   VECFU_LAT_OPS=N  FU 延迟实测每条指令的事务数（默认 64，要求 >= 8）
#
# 路径（均可用环境变量改到别处，见 scripts/lib/common.sh）：
#   WORK_DIR      工作树 ${WORK_DIR}/XiangShan-cosim、${WORK_DIR}/NEMU
#   LOG_ROOT      日志根目录（默认 logs/）
#   RESULTS_DIR   CSV 输出（默认 bench/results/）
#   FIG_DIR       图表输出（默认 docs/stage3/figures/）
#   PYTHON        绘图用的 Python（需 matplotlib；缺失时跳过绘图并告警）
# 执行位置：[1] Linux 宿主机直接执行 / macOS 进 xsdev 容器；[2]-[6] 宿主机。
#
# 产物：
#   logs/stage3/p7_baseline_equiv.log    [1] 基线 <-> vdot 等价性 + NEMU 指令数实测
#   logs/stage3/p7_latency_measure.log   [2][3][4] 延迟实测（波形 + 三个 FU harness）
#   logs/stage3/p7_bench_run.log         本脚本的完整终端日志
#   logs/stage3/waveform/*.vcd           vdot 三条指令的真实波形
#   bench/results/*.csv                  报告中每个数字的原始数据
#   docs/stage3/figures/*.png            图表
#
# 分层说明（诚实性要求）：
#   * [1] 在 NEMU（功能级模拟器）上跑，给出的是**动态指令条数**，不是周期数；
#   * [2][3][4] 在 Verilator 上跑**功能单元级**的 RTL，给出的是 FU 延迟周期数，
#     不是乱序核的端到端 issue-to-commit 延迟；
#   * 全核 Verilator 仿真在本机不可行（见 docs/stage1/03 §7.1），因此报告中
#     凡涉及全核行为的数字一律标注为「建模估算」。
# =============================================================================
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
XS_DIR="${XS_COSIM}"
YS_DIR="${XS_DIR}/yunsuan"
VEC_DIR="${REPO_ROOT}/tests/vectors"
LOG_DIR="${LOG_ROOT}/stage3"
WAVE_DIR="${LOG_DIR}/waveform"
RES_DIR="${RESULTS_DIR}"
BASE_DIR="${STAGE_DIR}/tests/riscv/baseline"

FORCE="${FORCE:-0}"
SKIP_NEMU="${SKIP_NEMU:-0}"
SKIP_RTL="${SKIP_RTL:-0}"
VECFU_LAT_OPS="${VECFU_LAT_OPS:-64}"

EQUIV_LOG="${LOG_DIR}/p7_baseline_equiv.log"
LAT_LOG="${LOG_DIR}/p7_latency_measure.log"
RUN_LOG="${LOG_DIR}/p7_bench_run.log"

mkdir -p "${LOG_DIR}" "${WAVE_DIR}" "${RES_DIR}" "${FIG_DIR}"

load_host_env
need_cmd python3
if [ "${SKIP_NEMU}" != "1" ]; then
  [ -d "${NEMU_DIR}" ] || die "找不到 ${NEMU_DIR}，请先执行 scripts/00_setup_env_host.sh 与 scripts/21_build_nemu_vdot.sh"
  setup_nemu_host_deps
  detect_cross
fi
if [ "${SKIP_RTL}" != "1" ]; then
  need_cmd verilator
  need_cmd java "JDK 17"
  need_cmd mill "由 scripts/00_setup_env_host.sh 安装到 \${WORK_DIR}/tools/mill"
  if [ ! -d "${XS_DIR}" ]; then
    info "找不到 ${XS_DIR}，调用 scripts/04_make_vdot_trees.sh cosim 生成"
    bash "${REPO_ROOT}/scripts/04_make_vdot_trees.sh" cosim
  fi
fi
TMPW="$(mktemp_d p7)"
trap 'rm -rf "${TMPW}"' EXIT

exec > >(tee "${RUN_LOG}") 2>&1

echo "=============================================================="
echo " P7 基线实现与延迟加速分析 —— 一键复现"
echo " 开始时间 : $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
echo " 仓库根   : ${REPO_ROOT}"
echo " RTL 工作树: ${XS_DIR}  ($(git -C "${XS_DIR}" rev-parse --short=12 HEAD 2>/dev/null || echo '?'))"
echo " NEMU     : ${NEMU_DIR}  ($(git -C "${NEMU_DIR}" rev-parse --short=12 HEAD 2>/dev/null || echo '?'))"
echo " verilator: $(verilator --version 2>/dev/null || echo 'N/A')"
echo "=============================================================="

# ---------------------------------------------------------------------------
# [1] NEMU：基线 <-> vdot 等价性 + 动态指令数实测
# ---------------------------------------------------------------------------
if [ "${SKIP_NEMU}" != "1" ]; then
step "1/6 NEMU：RVV 1.0 基线序列 <-> vdot 指令族等价性 + 动态指令数实测"
stage_tests
{
  echo "=============================================================="
  echo " P7 / 赛题 3.2  基线功能实现与等价性验证"
  echo " $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
  echo "=============================================================="
  xrun "
      cd '${NEMU_DIR}'
      echo '\$ git log --oneline -1'; git log --oneline -1
      if [ '${FORCE}' = '1' ] || [ ! -x build/riscv64-nemu-interpreter ] || \
         ! grep -q 'CONFIG_UARTLITE_MMIO' include/generated/autoconf.h 2>/dev/null; then
        echo '\$ make riscv64-xs-kmhv2_defconfig && make -j'
        make riscv64-xs-kmhv2_defconfig >/dev/null
        make -j${JOBS} 2>&1 | tail -2
      else
        echo '（已存在 riscv64-xs-kmhv2 形态的解释器，跳过重建；FORCE=1 可强制重来）'
      fi
      grep -E 'CONFIG_MBASE |CONFIG_UARTLITE_MMIO |CONFIG_CUSTOM_XVDOT ' include/generated/autoconf.h
      cd '${BASE_DIR}'
      echo ''
      echo '（构建目录：${BASE_DIR}，为 tests/riscv/baseline 的同步副本）'
      echo '\$ ${CROSS}gcc --version'; ${CROSS}gcc --version | head -1
      echo '\$ make NEMU_HOME=${NEMU_DIR} CROSS=${CROSS}'
      make NEMU_HOME='${NEMU_DIR}' CROSS='${CROSS}' 2>&1 | grep -vE '^${CROSS}(gcc|objdump|objcopy) |LOAD segment' || true
      test -f build/baseline_test.bin
      echo ''
      echo '--- 证据：基线序列确实以标准 RVV 1.0 编码出现在镜像的 .text 里 ---'
      grep -E 'vwmul.vv|vwredsum.vs|vwadd.wv|vmv.s.x|vmacc.vv' build/baseline_test.dis | head -8 || true
      echo '--- 证据：vdot 自定义编码也在同一个镜像里 ---'
      grep -E 'e62081d7|ea2081d7|ee2081d7|e6208457' build/baseline_test.dis | head -4 || true
      echo ''
      echo '--- 单次点积两个 kernel 的静态指令数（反汇编逐条） ---'
      for f in baseline_vdot_single vdot_single; do
        n=\$(awk -v f=\"<\$f>:\" 'index(\$0,f){p=1;next} p&&/^\$/{exit} p&&/:\t/{c++} END{print c}' build/baseline_test.dis)
        echo \"    \$f : \$n 条\"
      done
      echo ''
      echo '--- 实跑 ---'
      echo '\$ \$NEMU_HOME/build/riscv64-nemu-interpreter -b --log=build/nemu-run.log build/baseline_test.bin'
      echo '------------------- 以下为模拟器实际输出 -------------------'
      set +e
      '${NEMU_DIR}/build/riscv64-nemu-interpreter' -b --log=build/nemu-run.log build/baseline_test.bin
      rc=\$?
      set -e
      echo '------------------- 模拟器输出结束 -------------------'
      echo \"NEMU 进程退出码 = \$rc\"
      exit \$rc
    "
} 2>&1 | tee "${EQUIV_LOG}"
grep -E "^\[A\] TOTAL|^RESULT:" "${EQUIV_LOG}" || true
else
  info "SKIP_NEMU=1，跳过 [1]；沿用已有的 ${EQUIV_LOG}"
fi

# ---------------------------------------------------------------------------
# [2][3][4] RTL 延迟实测
# ---------------------------------------------------------------------------
if [ "${SKIP_RTL}" != "1" ]; then
: > "${LAT_LOG}"
{
  echo "=============================================================="
  echo " P7 / 赛题 3.3  功能单元延迟实测"
  echo " $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
  echo "=============================================================="
} | tee -a "${LAT_LOG}"

step "2/6 L1 YunSuan 平台：抓 vdot 三条指令的真实波形并抽取事务"
command -v verilator >/dev/null || die "需要 verilator"
TRACE_MARK="${YS_DIR}/build/.trace_mode"
if [ "${FORCE}" = "1" ] || [ ! -x "${YS_DIR}/build/emu" ] || \
   [ "$(cat "${TRACE_MARK}" 2>/dev/null || echo 0)" != "1" ]; then
  info "重建带 --trace 的 emu（EMU_TRACE=1），约 3-5 分钟"
  cp -f "${REPO_ROOT}/tests/golden/vdot_ref.c" "${YS_DIR}/src/test/csrc/golden_model/vdot_ref.c"
  cp -f "${REPO_ROOT}/tests/golden/vdot_ref.h" "${YS_DIR}/src/test/csrc/golden_model/vdot_ref.h"
  bash "${REPO_ROOT}/scripts/tools/mill_state_guard.sh" "${YS_DIR}" >/dev/null || true
  rm -rf "${YS_DIR}/build/emu-compile" "${YS_DIR}/build/emu"
  make -C "${YS_DIR}" emu EMU_TRACE=1 > "${TMPW}/p7_trace_build.log" 2>&1 || {
    tail -30 "${TMPW}/p7_trace_build.log"; die "trace 版 emu 构建失败"; }
  echo "1" > "${TRACE_MARK}"
fi
info "emu(trace) : $(ls -l "${YS_DIR}/build/emu" | awk '{print $5}') bytes"

mkslice() {  # $1=输出 $2=语料 $3=awk 条件（取前 12 条可执行用例）
  head -1 "$2" > "$1"
  awk -v want=12 "!/^#/&&NF>0&&\$NF==\"OK\"&&$3 {print; if(++k>=want) exit}" "$2" >> "$1"
}
mkslice "${TMPW}/p7_w_vdot.txt"    "${VEC_DIR}/random.txt"         '$1=="vdot"&&$3==0&&$4==16'
mkslice "${TMPW}/p7_w_vdotacc.txt" "${VEC_DIR}/vdotacc_random.txt" '$1=="vdotacc"&&$3==0&&$4==16'
mkslice "${TMPW}/p7_w_vdot4a.txt"  "${VEC_DIR}/vdot4a_random.txt"  '$1=="vdot4a"&&$3==0&&$4==4'

{
echo ""
echo "##############################################################"
echo "# [2] L1 YunSuan 平台（VDotTop）波形实测"
echo "#     判读约定见 docs/stage1/02_向量加法指令执行过程分析.md §8.2，"
echo "#     与 vadd.vv 用的是同一套方法与同一个工具。"
echo "##############################################################"
# 上游 emu.cpp 的 timestamp_filename() 用 getcwd(cwd, 64) 取当前目录，再把 VCD 写到
# <cwd>/build/ 下；当前目录超过 63 字节时 getcwd 失败，VCD 会被写到不存在的 /build/ 而丢失。
# 因此在短路径的临时目录 ${TMPW}/wave 里运行 emu（emu 本身不依赖当前目录）。
WRUN="${TMPW}/wave"
for n in vdot vdotacc vdot4a; do
  rm -rf "${WRUN}"; mkdir -p "${WRUN}/build"
  echo ""
  echo "--- ${n}.vv ---"
  echo "\$ YS_VDOT_VECTORS=${TMPW}/p7_w_${n}.txt ./build/emu --dump-wave -b 0 -e 400 -O 12 -s 1"
  ( cd "${WRUN}" && YS_VDOT_VECTORS="${TMPW}/p7_w_${n}.txt" \
      "${YS_DIR}/build/emu" --dump-wave -b 0 -e 400 -O 12 -s 1 ) 2>&1 | sed 's/^/    /'
  vlist=( "${WRUN}"/build/*.vcd ); v="${vlist[0]}"
  [ -f "${v}" ] || die "emu 未生成 VCD（${WRUN}/build/）"
  cp "${v}" "${WAVE_DIR}/p7_${n}vv_vdottop_fuType10_seed1.vcd"
  echo "    VCD -> $(relpath "${WAVE_DIR}")/p7_${n}vv_vdottop_fuType10_seed1.vcd"
  echo ""
  echo "\$ python3 scripts/tools/vcd_extract.py --vcd <vcd> --transactions"
  python3 "${REPO_ROOT}/scripts/tools/vcd_extract.py" \
    --vcd "${WAVE_DIR}/p7_${n}vv_vdottop_fuType10_seed1.vcd" --transactions \
    | sed -n '1,20p'
  echo ""
  echo "--- DUT 内部：io_fire -> VDotTree 的 S1/S2 流水寄存器 -> io_vd 成形 ---"
  echo "    （L1 平台的 io_out_valid 由平台计数器 counter>=VDOT_latency 产生"
  echo "      [VectorSimTop.scala:117-124]，因此这里再看一遍 DUT 自己的信号："
  echo "      VDotTop.scala:44 fireS1 = GatedValidRegNext(fire)，"
  echo "      VDotTree.scala:127-129 sumRegS2/carRegS2 = RegEnable(..., io.fire)，"
  echo "      io.vd 由 S2 寄存器组合产生 -> 结果应在 fire 后第 2 个上升沿可见）"
  python3 "${REPO_ROOT}/scripts/tools/vcd_extract.py" \
    --vcd "${WAVE_DIR}/p7_${n}vv_vdottop_fuType10_seed1.vcd" --changes-only \
    --signals TOP.io_in_valid TOP.io_in_ready TOP.io_out_valid \
              TOP.SimTop.vdot.io_fire TOP.SimTop.vdot.vdotTree.io_fire \
              TOP.SimTop.vdot.vdotTree.sumRegS2_0 TOP.SimTop.vdot.io_vd \
    | sed -n '1,16p' 
done
} 2>&1 | tee -a "${LAT_LOG}"

step "3/6 直驱 VIMacU 测量数据成形拍（vdot 族 + 上游既有 vmul/vwmul/vmacc）"
{
echo ""
echo "##############################################################"
echo "# [3] VIMacU 直驱测量（out.valid 构造值 + 数据成形拍；真正被集成进香山的功能单元）"
echo "##############################################################"
SKIP_ELAB="$([ "${FORCE}" = "1" ] && echo 0 || echo 1)" \
VIMACU_LAT_OPS="${VECFU_LAT_OPS}" \
  XS_DIR="${XS_DIR}" bash "${REPO_ROOT}/scripts/tools/run_vimacu_latency.sh"
} 2>&1 | tee -a "${LAT_LOG}"

step "4/6 直驱 VIAluFix / VIPU（基线序列的另外两个功能单元）"
{
echo ""
echo "##############################################################"
echo "# [4] VIAluFix / VIPU 直驱延迟实测"
echo "##############################################################"
SKIP_ELAB="$([ "${FORCE}" = "1" ] && echo 0 || echo 1)" \
VECFU_LAT_OPS="${VECFU_LAT_OPS}" \
  XS_DIR="${XS_DIR}" bash "${REPO_ROOT}/scripts/tools/run_vecfu_latency.sh"
} 2>&1 | tee -a "${LAT_LOG}"
else
  info "SKIP_RTL=1，跳过 [2][3][4]；沿用已有的 ${LAT_LOG}"
fi

# ---------------------------------------------------------------------------
# [5] 汇总成 CSV
# ---------------------------------------------------------------------------
step "5/6 从日志抽取原始数据 -> $(relpath "${RES_DIR}")/*.csv"
# 全核周期实测日志（scripts/50_run_fullcore_difftest.sh perf 产生）存在时一并解析，生成 cycles_fullcore.csv
FC_PERF_LOG="${FC_PERF_LOG:-${LOG_ROOT}/stage3/fullcore/perf_cycles.log}"
FC_ARGS=()
[ -f "${FC_PERF_LOG}" ] && FC_ARGS=(--fullcore-perf-log "${FC_PERF_LOG}")
python3 "${REPO_ROOT}/bench/collect_results.py" \
  --equiv-log "${EQUIV_LOG}" --latency-log "${LAT_LOG}" --out "${RES_DIR}" ${FC_ARGS[@]+"${FC_ARGS[@]}"}
ls -l "${RES_DIR}"

# ---------------------------------------------------------------------------
# [6] 绘图
# ---------------------------------------------------------------------------
step "6/6 绘图 -> $(relpath "${FIG_DIR}")/*.png"
# 绘图依赖：matplotlib + 至少一种 CJK 字体（图中有中文标注；候选列表与 bench/plot_results.py 一致）
PLOT_OK=1
PLOT_CHECK='
import sys
try:
    import matplotlib.font_manager as fm
except Exception:
    print("NO_MPL"); sys.exit(1)
want = ["Arial Unicode MS", "Hiragino Sans GB", "STHeiti", "Songti SC",
        "Noto Sans CJK SC", "WenQuanYi Zen Hei", "Droid Sans Fallback"]
have = {f.name for f in fm.fontManager.ttflist}
hit = [w for w in want if w in have]
print("CJK=" + (hit[0] if hit else "NONE"))
'
PLOT_DEP="$("${PYTHON}" -c "${PLOT_CHECK}" 2>/dev/null || true)"
if [ "${PLOT_DEP}" = "CJK=NONE" ]; then
  warn "未找到 CJK 字体，图中中文会显示为方框。Ubuntu：sudo apt-get install -y fonts-noto-cjk（或 fonts-wqy-zenhei）"
fi
if [ -n "${PLOT_DEP}" ] && [ "${PLOT_DEP}" != "NO_MPL" ]; then
  info "绘图 Python：${PYTHON}（${PLOT_DEP}）"
  "${PYTHON}" "${REPO_ROOT}/bench/plot_results.py" --results "${RES_DIR}" --out "${FIG_DIR}"
  ls -l "${FIG_DIR}"
else
  PLOT_OK=0
  warn "${PYTHON} 缺少 matplotlib，绘图未执行（CSV 已生成）。安装：pip install matplotlib，
         或 python3 -m venv <dir> && <dir>/bin/pip install matplotlib 后用 PYTHON=<dir>/bin/python 重跑；
         中文标注另需 CJK 字体（Ubuntu：sudo apt-get install -y fonts-noto-cjk）。
         可加 SKIP_NEMU=1 SKIP_RTL=1 只重做 [5][6]"
fi

echo ""
echo "=============================================================="
echo " 完成  $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
echo "   ${EQUIV_LOG}"
echo "   ${LAT_LOG}"
echo "   ${RUN_LOG}"
echo "   ${RES_DIR}/*.csv"
if [ "${PLOT_OK}" = "1" ]; then echo "   ${FIG_DIR}/*.png"; else echo "   （图表未生成：缺 matplotlib）"; fi
echo "=============================================================="
grep -E "^\[A\] TOTAL|^\[B\] long-vector" "${EQUIV_LOG}" 2>/dev/null || true
