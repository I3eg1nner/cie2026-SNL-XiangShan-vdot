#!/usr/bin/env bash
# =============================================================================
# make_stage23_figures.sh —— 由阶段二、阶段三已入库的 VCD 生成文档用波形图
#
# 产物：
#   docs/stage2/figures/fig1_vdot_wave.png      嵌入 docs/stage2/12_基础功能测试报告.md §10.2
#   docs/stage2/figures/fig2_vdotacc_wave.png   嵌入 §10.3
#   docs/stage2/figures/fig3_vdot4a_wave.png    嵌入 §10.4
#   docs/stage3/figures/fig5_latency_wave_vdot.png     嵌入 docs/stage3/22_基线实现与延迟加速分析.md §4.2
#   docs/stage3/figures/fig6_latency_wave_vdotacc.png
#   docs/stage3/figures/fig7_latency_wave_vdot4a.png
# 渲染器：scripts/tools/vcd_plot.py（与 vcd_extract.py 共用同一个 VCD 解析器，
#         所以图上的值与 *_signal_trace.txt、p7_latency_measure.log 必然同源）
#
# 用法： bash scripts/tools/make_stage23_figures.sh
#        PYTHON=/path/to/python bash scripts/tools/make_stage23_figures.sh   # 指定带 matplotlib 的解释器
# 本脚本只读 logs/stage2/waveform/、logs/stage3/waveform/ 下的 VCD，不重跑仿真。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W2="${ROOT}/logs/stage2/waveform"
W3="${ROOT}/logs/stage3/waveform"
OUT2="${ROOT}/docs/stage2/figures"
OUT3="${ROOT}/docs/stage3/figures"
PLOT="${PYTHON:-python3} ${ROOT}/scripts/tools/vcd_plot.py"

D="TOP.SimTop.vdot"
T="${D}.vdotTree"

mkdir -p "${OUT2}" "${OUT3}"
for f in "${W2}"/{vdotvv,vdotaccvv,vdot4avv}_vdottop_fuType10_seed1.vcd \
         "${W3}"/p7_{vdotvv,vdotaccvv,vdot4avv}_vdottop_fuType10_seed1.vcd; do
  [ -f "${f}" ] || { echo "缺少波形文件：${f}" >&2; exit 1; }
done

# 三张阶段二图共用的握手 + 控制面信号
COMMON=(
  --signal 'TOP.clock|clock'
  --signal 'TOP.io_in_valid|io_in_valid'
  --signal 'TOP.io_in_ready|io_in_ready'
  --signal "${D}.io_fire|vdot.io_fire"
  --signal "${D}.io_fuOpType|vdot.io_fuOpType"
  --signal 'TOP.io_in_bits_sew|io_in_bits_sew|dec'
  --signal 'TOP.io_in_bits_vinfo_vl|io_in_bits_vinfo_vl|dec'
  --signal "${T}.io_foldLevels|vdotTree.io_foldLevels|dec"
  --signal "${T}.io_activeEn|vdotTree.io_activeEn"
)
MARKS=(--mark '21|in.fire' --mark '23|上升沿 1：S1' --mark '25|上升沿 2：S2 / vd 成形')

# ------------------------------------------------------------ 阶段二 图 1：vdot.vv
${PLOT} --vcd "${W2}/vdotvv_vdottop_fuType10_seed1.vcd" --out "${OUT2}/fig1_vdot_wave.png" \
  --from 18 --to 28 --left 0.27 \
  --title "图 1　vdot.vv：全 0x80 × 全 0x80（vl=16, vta=1），16 个乘积均为 0x4000，4 个 lane 同持总和 0x40000" \
  --subtitle "logs/stage2/waveform/vdotvv_vdottop_fuType10_seed1.vcd　DUT = VDotTop　io_out_valid 由平台计数器产生（VectorSimTop.scala:127），不作为 DUT 延迟证据" \
  "${COMMON[@]}" \
  --signal "${T}.io_prod_0|vdotTree.io_prod_0" \
  --signal "${T}.io_prod_1|vdotTree.io_prod_1" \
  --signal "${T}.io_prod_15|vdotTree.io_prod_15" \
  --signal "${T}.sumRegS2_0|vdotTree.sumRegS2_0" \
  --signal "${T}.carRegS2_0|vdotTree.carRegS2_0" \
  --signal "${T}.io_dotVd|vdotTree.io_dotVd|hex2" \
  --signal "${D}.io_vd|vdot.io_vd（最终 vd）|hex2" \
  --signal 'TOP.io_out_valid|io_out_valid（平台）' \
  "${MARKS[@]}"

# --------------------------------------------------------- 阶段二 图 2：vdotacc.vv
${PLOT} --vcd "${W2}/vdotaccvv_vdottop_fuType10_seed1.vcd" --out "${OUT2}/fig2_vdotacc_wave.png" \
  --from 18 --to 28 --left 0.27 \
  --title "图 2　vdotacc.vv：vs1=vs2=[1..16]，累加器 0x3E8 只注入 lane 0 —— lane0 = 0x9C0（2496），lane1..3 = 0x5D8（1496）" \
  --subtitle "logs/stage2/waveform/vdotaccvv_vdottop_fuType10_seed1.vcd　DUT = VDotTop　io_out_valid 由平台计数器产生，不作为 DUT 延迟证据" \
  "${COMMON[@]}" \
  --signal "${T}.io_prod_0|vdotTree.io_prod_0" \
  --signal "${T}.io_prod_15|vdotTree.io_prod_15" \
  --signal "${T}.io_accOperand_0|vdotTree.io_accOperand_0" \
  --signal "${T}.io_accOperand_1|vdotTree.io_accOperand_1" \
  --signal "${D}.isDotAccS2|vdot.isDotAccS2" \
  --signal "${T}.io_dotVd|vdotTree.io_dotVd|hex2" \
  --signal "${D}.io_vd|vdot.io_vd（最终 vd）|hex2" \
  --signal 'TOP.io_out_valid|io_out_valid（平台）' \
  "${MARKS[@]}"

# ---------------------------------------------------------- 阶段二 图 3：vdot4a.vv
${PLOT} --vcd "${W2}/vdot4avv_vdottop_fuType10_seed1.vcd" --out "${OUT2}/fig3_vdot4a_wave.png" \
  --from 18 --to 28 --left 0.27 \
  --title "图 3　vdot4a.vv：vs1=vs2=[1..16]，SEW=32，foldLevels=0（不折叠）—— 4 组结果 30 / 174 / 446 / 846" \
  --subtitle "logs/stage2/waveform/vdot4avv_vdottop_fuType10_seed1.vcd　DUT = VDotTop　io_out_valid 由平台计数器产生，不作为 DUT 延迟证据" \
  "${COMMON[@]}" \
  --signal "${T}.sumRegS2_0|vdotTree.sumRegS2_0" \
  --signal "${T}.carRegS2_0|vdotTree.carRegS2_0" \
  --signal "${T}.sumRegS2_1|vdotTree.sumRegS2_1" \
  --signal "${T}.carRegS2_1|vdotTree.carRegS2_1" \
  --signal "${D}.isDot4aS2|vdot.isDot4aS2" \
  --signal "${T}.io_dotVd|vdotTree.io_dotVd|hex2" \
  --signal 'TOP.io_out_bits_result_0|io_out_bits_result_0' \
  --signal 'TOP.io_out_bits_result_1|io_out_bits_result_1' \
  --signal 'TOP.io_out_valid|io_out_valid（平台）' \
  "${MARKS[@]}"

# ------------------------------------------- 阶段三 图 5–7：延迟实测（前 3 笔事务）
# 关注点：DUT 自己的 S2 寄存器 sumRegS2_0 与 io_vd 在每次 in.fire 后第 2 个上升沿才取得新值。
# io_out_valid 一并画出但明确标为平台信号（counter >= VDOT_latency），只作对照。
LAT=(
  --signal 'TOP.clock|clock'
  --signal 'TOP.io_in_valid|io_in_valid'
  --signal 'TOP.io_in_ready|io_in_ready'
  --signal "${D}.io_fire|vdot.io_fire"
  --signal "${D}.fireS1_last_r|vdot.fireS1_last_r"
  --signal "${T}.sumRegS2_0|vdotTree.sumRegS2_0（DUT S2 寄存器）"
  --signal "${T}.carRegS2_0|vdotTree.carRegS2_0（DUT S2 寄存器）"
  --signal "${D}.io_vd|vdot.io_vd（DUT 输出）|hex2"
  --signal 'TOP.SimTop.counter|SimTop.counter（平台）|dec'
  --signal 'TOP.io_out_valid|io_out_valid（平台）'
)
LATMARK=(--mark '21|fire #0' --mark '25|vd #0' --mark '29|fire #1' --mark '33|vd #1'
         --mark '37|fire #2' --mark '41|vd #2'
         --span '21|25|2 拍' --span '29|33|2 拍' --span '37|41|2 拍')

i=5
for ins in vdotvv:vdot.vv vdotaccvv:vdotacc.vv vdot4avv:vdot4a.vv; do
  tag="${ins%%:*}"; name="${ins#*:}"
  short="${name%.vv}"
  ${PLOT} --vcd "${W3}/p7_${tag}_vdottop_fuType10_seed1.vcd" \
    --out "${OUT3}/fig${i}_latency_wave_${short}.png" \
    --from 18 --to 44 --left 0.27 --width 15 \
    --title "图 ${i}　${name} 延迟实测：DUT 内部 S2 寄存器与 io_vd 在每次 in.fire 后第 2 个上升沿取得新值（前 3 / 12 笔事务）" \
    --subtitle "logs/stage3/waveform/p7_${tag}_vdottop_fuType10_seed1.vcd　sumRegS2/carRegS2 = RegEnable(..., io.fire)（VDotTree.scala:127-129）　counter / io_out_valid 为平台常量计数器，仅作对照" \
    "${LAT[@]}" "${LATMARK[@]}"
  i=$((i + 1))
done

echo ""
echo "生成完毕："
ls -1 "${OUT2}"/*.png "${OUT3}"/fig[567]_*.png | sed "s@${ROOT}/@  @"
echo "STAGE23-FIGURES: DONE"
