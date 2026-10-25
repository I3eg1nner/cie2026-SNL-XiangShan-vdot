#!/usr/bin/env bash
# =============================================================================
# capture_vdot_waves.sh —— 抓取 vdot 三条指令的真实波形并抽出可核对的信号轨迹
#
# 做法：
#   1) 以 EMU_TRACE=1 重建 L1 仿真器（Verilator --trace）
#   2) 用定向单条语料驱动，每条指令抓一份 VCD（放 logs/stage2/waveform/）
#   3) 用 scripts/tools/vcd_extract.py 把握手与数据通路信号导出成文本轨迹，
#      使报告里的「某信号在第 N 拍等于 X」可以不开波形查看器就核对
#   4) 还原成不带 trace 的 emu（功能测试跑得快）
#
# 用法： bash scripts/tools/capture_vdot_waves.sh
#        KEEP_TRACE=1 保留带 trace 的 emu（不还原）
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
YS_DIR="${WORK_DIR:-${REPO_ROOT}/work}/XiangShan-vdot/yunsuan"
VEC_DIR="${REPO_ROOT}/tests/vectors"
WAVE_DIR="${LOG_ROOT:-${REPO_ROOT}/logs}/stage2/waveform"
KEEP_TRACE="${KEEP_TRACE:-0}"
EXTRACT_ONLY="${EXTRACT_ONLY:-0}"   # 1 = 复用已有 VCD，只重新导出信号轨迹

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/env_host.sh"
mkdir -p "${WAVE_DIR}"

echo "=== vdot 波形抓取  $(date '+%Y-%m-%d %H:%M:%S %Z') ==="

echo ""
echo "--- (1) 以 EMU_TRACE=1 重建仿真器 ---"
if [ "${EXTRACT_ONLY}" = "1" ]; then
  echo "    EXTRACT_ONLY=1，跳过重建，复用 ${WAVE_DIR} 下已有的 VCD"
else
bash "${REPO_ROOT}/scripts/tools/mill_state_guard.sh" "${YS_DIR}" || true
rm -rf "${YS_DIR}/build/emu-compile" "${YS_DIR}/build/emu"
make -C "${YS_DIR}" emu EMU_TRACE=1 > /tmp/wave_build.log 2>&1 || { tail -30 /tmp/wave_build.log; exit 1; }
echo "0" > "${YS_DIR}/build/.trace_mode.wave"   # 记录当前是 trace 版（供 11_build 脚本识别）
rm -f "${YS_DIR}/build/.trace_mode"; echo "1" > "${YS_DIR}/build/.trace_mode"
echo "    emu（trace 版）: $(ls -l "${YS_DIR}/build/emu" | awk '{print $5}') bytes"
fi

# 一条用例一个文件，便于把波形与具体数值对上
mk_single() {   # $1=源语料 $2=awk 过滤 $3=输出文件
  head -1 "$1" > "$3"
  awk "!/^#/ && NF>0 && $2" "$1" | head -1 >> "$3"
  echo "    用例： $(tail -1 "$3")"
}

capture() {     # $1=名字 $2=语料文件
  local name="$1" vf="$2"
  echo ""
  echo "--- 抓取 ${name} ---"
  if [ "${EXTRACT_ONLY}" != "1" ]; then
    rm -f "${YS_DIR}"/build/*.vcd
    ( cd "${YS_DIR}" && YS_VDOT_VECTORS="${vf}" ./build/emu --dump-wave -b 0 -e 200 -O 1 -s 1 ) \
      | sed 's/^/    /'
    local v
    for v in "${YS_DIR}"/build/*.vcd; do
      cp "$v" "${WAVE_DIR}/${name}.vcd"
      break
    done
  fi
  echo "    VCD: ${WAVE_DIR}/${name}.vcd  ($(wc -l < "${WAVE_DIR}/${name}.vcd" | tr -d ' ') 行, $(ls -l "${WAVE_DIR}/${name}.vcd" | awk '{print $5}') bytes)"
  {
    echo "================================================================"
    echo "信号轨迹： ${name}"
    echo "VCD     ： logs/stage2/waveform/${name}.vcd"
    echo "激励     ： $(tail -1 "${vf}")"
    echo "生成命令： python3 scripts/tools/vcd_extract.py --vcd <vcd> --transactions"
    echo "================================================================"
    python3 "${REPO_ROOT}/scripts/tools/vcd_extract.py" --vcd "${WAVE_DIR}/${name}.vcd" --transactions
    echo ""
    echo "---- 顶层握手 + 数据通路逐拍（只打印有变化的时刻）----"
    python3 "${REPO_ROOT}/scripts/tools/vcd_extract.py" --vcd "${WAVE_DIR}/${name}.vcd" --changes-only \
      --signals TOP.io_in_valid TOP.io_in_ready TOP.io_out_valid \
                TOP.io_in_bits_fuType TOP.io_in_bits_fuOpType TOP.io_in_bits_sew \
                TOP.io_in_bits_vinfo_vl TOP.io_in_bits_vinfo_vstart TOP.io_in_bits_vinfo_vm \
                TOP.io_in_bits_vinfo_ta \
                TOP.io_in_bits_src_0_0 TOP.io_in_bits_src_0_1 \
                TOP.io_in_bits_src_1_0 TOP.io_in_bits_src_1_1 \
                TOP.io_in_bits_src_2_0 TOP.io_in_bits_src_2_1 \
                TOP.io_out_bits_result_0 TOP.io_out_bits_result_1
    echo ""
    echo "---- VDotTop 层次：控制面（证明流水级与指令模式）----"
    python3 "${REPO_ROOT}/scripts/tools/vcd_extract.py" --vcd "${WAVE_DIR}/${name}.vcd" --changes-only \
      --signals TOP.SimTop.vdot.io_fire TOP.SimTop.vdot.fireS1_last_r \
                TOP.SimTop.vdot.io_fuOpType TOP.SimTop.vdot.io_info_vl \
                TOP.SimTop.vdot.io_info_vstart TOP.SimTop.vdot.io_info_vm \
                TOP.SimTop.vdot.io_info_ta TOP.SimTop.vdot.isDot4aS2 TOP.SimTop.vdot.isDotAccS2 \
                TOP.SimTop.vdot.vdotTree.io_fire TOP.SimTop.vdot.vdotTree.io_foldLevels \
                TOP.SimTop.vdot.vdotTree.foldLevelsS2 TOP.SimTop.vdot.vdotTree.io_activeEn
    echo ""
    echo "---- VDotTree 层次：16 个 16 位乘积（符号扩展前的原始乘积）----"
    python3 "${REPO_ROOT}/scripts/tools/vcd_extract.py" --vcd "${WAVE_DIR}/${name}.vcd" --changes-only \
      --signals TOP.SimTop.vdot.vdotTree.io_prod_0 TOP.SimTop.vdot.vdotTree.io_prod_1 \
                TOP.SimTop.vdot.vdotTree.io_prod_2 TOP.SimTop.vdot.vdotTree.io_prod_3 \
                TOP.SimTop.vdot.vdotTree.io_prod_4 TOP.SimTop.vdot.vdotTree.io_prod_5 \
                TOP.SimTop.vdot.vdotTree.io_prod_6 TOP.SimTop.vdot.vdotTree.io_prod_7 \
                TOP.SimTop.vdot.vdotTree.io_prod_8 TOP.SimTop.vdot.vdotTree.io_prod_9 \
                TOP.SimTop.vdot.vdotTree.io_prod_10 TOP.SimTop.vdot.vdotTree.io_prod_11 \
                TOP.SimTop.vdot.vdotTree.io_prod_12 TOP.SimTop.vdot.vdotTree.io_prod_13 \
                TOP.SimTop.vdot.vdotTree.io_prod_14 TOP.SimTop.vdot.vdotTree.io_prod_15
    echo ""
    echo "---- VDotTree 层次：S1->S2 carry-save 流水寄存器 + 累加操作数 + 树输出 ----"
    python3 "${REPO_ROOT}/scripts/tools/vcd_extract.py" --vcd "${WAVE_DIR}/${name}.vcd" --changes-only \
      --signals TOP.SimTop.vdot.vdotTree.sumRegS2_0 TOP.SimTop.vdot.vdotTree.carRegS2_0 \
                TOP.SimTop.vdot.vdotTree.sumRegS2_1 TOP.SimTop.vdot.vdotTree.carRegS2_1 \
                TOP.SimTop.vdot.vdotTree.io_accOperand_0 TOP.SimTop.vdot.vdotTree.io_accOperand_1 \
                TOP.SimTop.vdot.vdotTree.io_accOperand_2 TOP.SimTop.vdot.vdotTree.io_accOperand_3 \
                TOP.SimTop.vdot.vdotTree.io_dotVd
    echo ""
    echo "---- VDotTop 写回成形：oldVd / mask / 最终 vd ----"
    python3 "${REPO_ROOT}/scripts/tools/vcd_extract.py" --vcd "${WAVE_DIR}/${name}.vcd" --changes-only \
      --signals TOP.SimTop.vdot.io_vs2 TOP.SimTop.vdot.io_vs1 TOP.SimTop.vdot.io_oldVd \
                TOP.SimTop.vdot.io_mask TOP.SimTop.vdot.oldVdS2 TOP.SimTop.vdot.io_vd
  } > "${WAVE_DIR}/${name}_signal_trace.txt" 2>&1
  echo "    轨迹: ${WAVE_DIR}/${name}_signal_trace.txt  ($(wc -l < "${WAVE_DIR}/${name}_signal_trace.txt" | tr -d ' ') 行)"
}

echo ""
echo "--- (2) 构造单条定向语料 ---"
T1="$(mktemp "${TMPDIR:-/tmp}/wvdot.XXXXXX")"; T2="$(mktemp "${TMPDIR:-/tmp}/wvdotacc.XXXXXX")"; T3="$(mktemp "${TMPDIR:-/tmp}/wvdot4a.XXXXXX")"
echo "  vdot.vv（全 0x80 × 全 0x80，期望 0x00040000 = 262144）"
mk_single "${VEC_DIR}/negative.txt" \
  '$8=="80808080808080808080808080808080" && $9=="80808080808080808080808080808080" && $6==1' "${T1}"
echo "  vdotacc.vv（vl=16，带累加器）"
mk_single "${VEC_DIR}/vdotacc_positive.txt" '$4==16 && $6==1' "${T2}"
echo "  vdot4a.vv（vl=4，4 组分组点积）"
mk_single "${VEC_DIR}/vdot4a_positive.txt"  '$4==4  && $6==1' "${T3}"

capture "vdotvv_vdottop_fuType10_seed1"    "${T1}"
capture "vdotaccvv_vdottop_fuType10_seed1" "${T2}"
capture "vdot4avv_vdottop_fuType10_seed1"  "${T3}"
rm -f "${T1}" "${T2}" "${T3}"

echo ""
echo "--- (3) 波形产物清单 ---"
ls -la "${WAVE_DIR}"

if [ "${KEEP_TRACE}" != "1" ] && [ "${EXTRACT_ONLY}" != "1" ]; then
  echo ""
  echo "--- (4) 还原不带 trace 的 emu ---"
  rm -rf "${YS_DIR}/build/emu-compile" "${YS_DIR}/build/emu"
  make -C "${YS_DIR}" emu > /tmp/wave_restore.log 2>&1 || { tail -30 /tmp/wave_restore.log; exit 1; }
  echo "0" > "${YS_DIR}/build/.trace_mode"
  rm -f "${YS_DIR}/build/.trace_mode.wave"
  echo "    emu（非 trace 版）: $(ls -l "${YS_DIR}/build/emu" | awk '{print $5}') bytes"
fi
echo ""
echo "=== 波形抓取完成 ==="
