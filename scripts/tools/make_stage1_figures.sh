#!/usr/bin/env bash
# =============================================================================
# make_stage1_figures.sh —— 由阶段一的两份真实 VCD 生成文档用波形图
#
# 产物：docs/stage1/figures/*.png，嵌入 docs/stage1/02_向量加法指令执行过程分析.md
# 渲染器：scripts/tools/vcd_plot.py（与 vcd_extract.py 共用同一个 VCD 解析器，
#         所以图上的值与 logs/stage1/waveform/vadd_signal_trace.txt 必然同源）
#
# 用法： bash scripts/tools/make_stage1_figures.sh          # 图 1–6，并在全核 VCD 存在时补图 7
#        bash scripts/tools/make_stage1_figures.sh fig7     # 只画图 7
# 图 1–6 只读 logs/stage1/waveform/ 下的 VCD；图 7（可选）只读全核 VCD
#   ${FULLCORE_VCD:-${WORK_DIR:-<仓库根>/work}/build/fullcore/wave/vdot_wave.vcd}
# （由 `bash scripts/50_run_fullcore_difftest.sh wave` 生成，382 MB，不入库；不存在时跳过并提示）。
# 都不重跑仿真。需要装有 matplotlib 的解释器：PYTHON=<venv>/bin/python。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W="${ROOT}/logs/stage1/waveform"
OUT="${ROOT}/docs/stage1/figures"
PLOT="${PYTHON:-python3} ${ROOT}/scripts/tools/vcd_plot.py"

V5="${W}/vaddvv_vialufwrapper_fuType5_seed2.vcd"   # VIAluFWrapper → VIntFixpAlu
V3="${W}/vadd_vintadder_fuType3_seed1.vcd"         # VectorIntAdder（对照）

A="TOP.SimTop.viaf.vIntFixpAlu"
ADD="${A}.vIntFixpAlu64bs_0.vIntAdder64b"

mkdir -p "${OUT}"
ONLY_FIG7=0
[ "${1:-}" = "fig7" ] && ONLY_FIG7=1

if [ "${ONLY_FIG7}" = 0 ]; then
for f in "${V5}" "${V3}"; do
  [ -f "${f}" ] || { echo "缺少波形文件：${f}" >&2; exit 1; }
done

# updateType_15..0（高字节在前）拼成一行
UPD="updateType[15:0]|"
for i in 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 0; do
  UPD="${UPD}${A}.updateType_${i},"
done
UPD="${UPD%,}"

# ---------------------------------------------------------------- 图 1：握手与延迟
${PLOT} --vcd "${V5}" --out "${OUT}/fig1_handshake_latency.png" \
  --from 18 --to 30 \
  --title "图 1　vadd.vv 的输入/输出握手与实测延迟（in.fire → out.valid = 1 个时钟周期）" \
  --subtitle "vaddvv_vialufwrapper_fuType5_seed2.vcd　DUT = VIAluFWrapper → VIntFixpAlu　事务 #0（e32, vl=1）与事务 #1" \
  --signal 'TOP.clock|clock' \
  --signal 'TOP.reset|reset' \
  --signal 'TOP.io_in_valid|io_in_valid' \
  --signal 'TOP.io_in_ready|io_in_ready' \
  --signal 'TOP.io_out_valid|io_out_valid' \
  --signal 'TOP.SimTop.busy|SimTop.busy' \
  --signal 'TOP.SimTop.counter|SimTop.counter|dec' \
  --signal 'TOP.SimTop.in_vinfo_vl|SimTop.in_vinfo_vl|dec' \
  --signal 'TOP.SimTop.in_sew|SimTop.in_sew (2=e32)|dec' \
  --signal 'TOP.SimTop.io_out_bits_result_0|io_out_bits_result_0' \
  --mark '20|valid & ready' --mark '21|in.fire' --mark '23|out.valid' \
  --mark '27|in.fire #1' --mark '29|out.valid #1' \
  --span '21|23|事务 #0：1 个时钟周期' \
  --span '27|29|事务 #1：1 个时钟周期'

# ------------------------------------------------- 图 2：fuType=3 对照（0 周期组合逻辑）
${PLOT} --vcd "${V3}" --out "${OUT}/fig2_latency_vintadder.png" \
  --from 18 --to 30 \
  --title "图 2　对照波形：VectorIntAdder（fuType=3）为纯组合逻辑，in.fire 与 out.valid 同一时刻" \
  --subtitle "vadd_vintadder_fuType3_seed1.vcd　VIA_latency = 0（VectorSimTop.scala:16）；该 FU 不在 XiangShan 的 vadd.vv 路径上，仅作延迟口径对照" \
  --signal 'TOP.clock|clock' \
  --signal 'TOP.io_in_valid|io_in_valid' \
  --signal 'TOP.io_in_ready|io_in_ready' \
  --signal 'TOP.io_out_valid|io_out_valid' \
  --signal 'TOP.SimTop.busy|SimTop.busy' \
  --signal 'TOP.SimTop.counter|SimTop.counter|dec' \
  --signal 'TOP.SimTop.io_out_bits_result_0|io_out_bits_result_0' \
  --mark '21|in.fire = out.valid' --mark '25|第 2 笔' --mark '29|第 3 笔'

# ---------------------------------------------------------- 图 3：SEW 分段进位链
${PLOT} --vcd "${V5}" --out "${OUT}/fig3_sew_carry_boundary.png" \
  --from 30 --to 38 --left 0.30 \
  --title "图 3　SEW 分段的硬证据：e16 时字节 1 产生进位，但字节 2 的 cin_2 = 0（进位在 16 位段边界被切断）" \
  --subtitle "vaddvv_vialufwrapper_fuType5_seed2.vcd　事务 #2（e16, vl=2）　in.fire @ #33 / out.valid @ #35　进位链见 VIntAdder64b.scala:66-102" \
  --signal 'TOP.clock|clock' \
  --signal 'TOP.io_in_valid|io_in_valid' \
  --signal 'TOP.io_out_valid|io_out_valid' \
  --signal 'TOP.SimTop.in_sew|SimTop.in_sew (1=e16)|dec' \
  --signal 'TOP.SimTop.in_src_0_0|in_src_0_0 = vs1[63:0]' \
  --signal 'TOP.SimTop.in_src_1_0|in_src_1_0 = vs2[63:0]' \
  --signal "${ADD}.cin_1|vIntAdder64b.cin_1" \
  --signal "${ADD}.cin_2|vIntAdder64b.cin_2" \
  --signal "${ADD}.cin_3|vIntAdder64b.cin_3" \
  --signal "${ADD}.cin_4|vIntAdder64b.cin_4" \
  --signal "${ADD}.cin_5|vIntAdder64b.cin_5" \
  --signal "${ADD}.cin_6|vIntAdder64b.cin_6" \
  --signal "${ADD}.cin_7|vIntAdder64b.cin_7" \
  --signal 'TOP.SimTop.io_out_bits_result_0|io_out_bits_result_0' \
  --mark '33|in.fire（e16）' --mark '35|out.valid'

# ------------------------------------- 图 4：mask-agnostic + tail-agnostic（事务 #0）
${PLOT} --vcd "${V5}" --out "${OUT}/fig4_mask_tail_agnostic.png" \
  --from 20 --to 27 --left 0.30 \
  --title "图 4　mask-agnostic 写全 1 + tail-agnostic 写全 1（事务 #0，ta=1 / ma=1）：updateType 全 3，vd 全 f" \
  --subtitle "vaddvv_vialufwrapper_fuType5_seed2.vcd　e32, vl=1, vm=0　in.fire @ #21 / out.valid @ #23　判定逻辑 VIntFixpAlu.scala:268-281" \
  --signal 'TOP.clock|clock' \
  --signal 'TOP.io_in_valid|io_in_valid' \
  --signal 'TOP.io_out_valid|io_out_valid' \
  --signal 'TOP.SimTop.in_vinfo_vm|SimTop.in_vinfo_vm' \
  --signal "${A}.taS1|vIntFixpAlu.taS1" \
  --signal "${A}.maS1|vIntFixpAlu.maS1" \
  --signal "${A}.io_in_mask16b|io_in_mask16b (S0)" \
  --signal "${A}.mask16bS1|mask16bS1" \
  --signal "${A}.tailS1|tailS1" \
  --signal "${A}.prestartS1|prestartS1" \
  --signal "${A}.mask16bReorg|mask16bReorg" \
  --signal "${A}.tailReorg|tailReorg" \
  --concat "${UPD}" \
  --signal "${A}.vIntFixpAlu64bs_0.io_vd|64b[0].io_vd（ALU 原始和）" \
  --signal "${A}.vIntFixpAlu64bs_1.io_vd|64b[1].io_vd（ALU 原始和）" \
  --signal "${A}.io_out_vd|io_out_vd（最终 vd）|hex2" \
  --mark '21|in.fire（S0 锁存）' --mark '23|out.valid（S1 合并后）'

# -------------------------------- 图 5：mask-agnostic + tail-undisturbed（事务 #1）
${PLOT} --vcd "${V5}" --out "${OUT}/fig5_tail_undisturbed.png" \
  --from 26 --to 33 --left 0.30 \
  --title "图 5　mask-agnostic 写全 1 + tail-undisturbed 保留 old_vd（事务 #1，ta=0 / ma=1）：updateType = 2×12 ∥ 3×4" \
  --subtitle "vaddvv_vialufwrapper_fuType5_seed2.vcd　e32, vl=1, vm=0　in.fire @ #27 / out.valid @ #29　ALU 原始和 0x0863f253_59ba2b72 被改写成 0xffffffff" \
  --signal 'TOP.clock|clock' \
  --signal 'TOP.io_in_valid|io_in_valid' \
  --signal 'TOP.io_out_valid|io_out_valid' \
  --signal "${A}.taS1|vIntFixpAlu.taS1" \
  --signal "${A}.maS1|vIntFixpAlu.maS1" \
  --signal "${A}.mask16bS1|mask16bS1" \
  --signal "${A}.tailS1|tailS1" \
  --signal "${A}.mask16bReorg|mask16bReorg" \
  --signal "${A}.tailReorg|tailReorg" \
  --concat "${UPD}" \
  --signal "${A}.vIntFixpAlu64bs_0.io_vd|64b[0].io_vd（ALU 原始和）" \
  --signal "${A}.vIntFixpAlu64bs_1.io_vd|64b[1].io_vd（ALU 原始和）" \
  --signal "${A}.old_vd_S1_r|old_vd_S1_r|hex2" \
  --signal "${A}.io_out_vd|io_out_vd（最终 vd）|hex2" \
  --mark '27|in.fire' --mark '29|out.valid'

# -------------------- 图 6：mask-undisturbed + tail-undisturbed（事务 #6，vd ≡ old_vd）
${PLOT} --vcd "${V5}" --out "${OUT}/fig6_mask_tail_undisturbed.png" \
  --from 56 --to 63 --left 0.30 \
  --title "图 6　mask-undisturbed + tail-undisturbed（事务 #6，ta=0 / ma=0）：updateType 全 2，整 128 位 vd ≡ old_vd" \
  --subtitle "vaddvv_vialufwrapper_fuType5_seed2.vcd　e32, vl=2, vm=0　in.fire @ #57 / out.valid @ #59　ALU 照样算出了和，但一个字节都没被采用" \
  --signal 'TOP.clock|clock' \
  --signal 'TOP.io_in_valid|io_in_valid' \
  --signal 'TOP.io_out_valid|io_out_valid' \
  --signal "${A}.taS1|vIntFixpAlu.taS1" \
  --signal "${A}.maS1|vIntFixpAlu.maS1" \
  --signal "${A}.mask16bS1|mask16bS1" \
  --signal "${A}.tailS1|tailS1" \
  --signal "${A}.mask16bReorg|mask16bReorg" \
  --signal "${A}.tailReorg|tailReorg" \
  --concat "${UPD}" \
  --signal "${A}.vIntFixpAlu64bs_0.io_vd|64b[0].io_vd（ALU 原始和）" \
  --signal "${A}.vIntFixpAlu64bs_1.io_vd|64b[1].io_vd（ALU 原始和）" \
  --signal "${A}.old_vd_S1_r|old_vd_S1_r|hex2" \
  --signal "${A}.io_out_vd|io_out_vd（最终 vd）|hex2" \
  --mark '57|in.fire' --mark '59|out.valid'

fi  # ONLY_FIG7

# ------------------------- 图 7（可选）：全核 MinimalConfig 中一条 vadd.vv 的完整流水
# 信号层次名与 tests/riscv/fullcore/wave_trace.py、scripts/50_run_fullcore_difftest.sh 的 run_wave() 一致；
# 各阶段时刻与 logs/stage3/fullcore/wave_trace.txt:150-181 逐条对应。
FULLCORE_VCD="${FULLCORE_VCD:-${WORK_DIR:-${ROOT}/work}/build/fullcore/wave/vdot_wave.vcd}"
if [ -f "${FULLCORE_VCD}" ]; then
  P=TOP.SimTop.cpu.l_soc.core_with_l2.core.backend
  DEC="${P}.inner_ctrlBlock.decode"
  REN="${P}.inner_ctrlBlock.rename"
  ROB="${P}.inner_ctrlBlock.rob"
  IQ1="${P}.inner_vfScheduler.IssueQueueVfmaVialuFixVfalu"
  ALU="${P}.inner_vfExuBlock.exus_2.VialuFix"
  WB="${P}.inner_dataPath.io_fromVfWb_1"
  ${PLOT} --vcd "${FULLCORE_VCD}" --out "${OUT}/fig7_fullcore_vadd_pipeline.png" \
    --from 1482 --to 1495 --left 0.25 \
    --title "图 7　全核 MinimalConfig：vadd.vv v1, v8, v9（pc=0x8000003e）从译码到 ROB 提交" \
    --subtitle "vdot_wave.vcd（50_run_fullcore_difftest.sh wave）　vdot 测试程序中紧跟 fence 之后的那条 vadd，单次执行，e8 / vl=16　robIdx=21，pdest=59" \
    --xlabel "emu 周期号（--dump-wave 每周期记录一个时间点，VCD 时刻 = 周期号；轨迹见 logs/stage3/fullcore/wave_trace.txt:150-181）" \
    --mark "1483|译码入" --mark "1484|译码出" --mark "1485|重命名" --mark "1486|入IQ1" \
    --mark "1487|入ROB" --mark "1488|发射" --mark "1491|进FU" --mark "1492|FU出/写VRF" \
    --mark "1493|ROB写回" --mark "1494|提交" \
    --signal "${DEC}.io_in_0_valid|decode.in0.valid" \
    --signal "${DEC}.io_in_0_bits_instr|decode.in0.instr|hex" \
    --signal "${DEC}.io_out_0_valid|decode.out0.valid" \
    --signal "${DEC}.io_out_0_bits_instr|decode.out0.instr|hex" \
    --signal "${DEC}.io_out_0_bits_fuOpType|decode.out0.fuOpType|hex" \
    --signal "${REN}.io_in_0_valid|rename.in0.valid" \
    --signal "${REN}.io_in_0_bits_instr|rename.in0.instr|hex" \
    --signal "${IQ1}.io_enq_0_valid|IQ1.enq0.valid" \
    --signal "${IQ1}.io_enq_0_bits_instr|IQ1.enq0.instr|hex" \
    --signal "${ROB}.io_enq_req_0_valid|rob.enq0.valid" \
    --signal "${ROB}.io_enq_req_0_bits_pc|rob.enq0.pc|hex" \
    --signal "${IQ1}.io_deqDelay_0_valid|IQ1.issue0.valid" \
    --signal "${IQ1}.io_deqDelay_0_bits_common_robIdx_value|IQ1.issue0.robIdx|dec" \
    --signal "${IQ1}.io_deqDelay_0_bits_common_pdest|IQ1.issue0.pdest|dec" \
    --signal "${ALU}.io_in_valid|VialuFix.in.valid" \
    --signal "${ALU}.io_in_bits_ctrl_fuOpType|VialuFix.in.fuOpType|hex" \
    --signal "${ALU}.io_out_valid|VialuFix.out.valid" \
    --signal "${ALU}.io_out_bits_res_data|VialuFix.out.res|hex2" \
    --signal "${WB}_wen|dataPath.fromVfWb1.wen" \
    --signal "${WB}_addr|dataPath.fromVfWb1.addr|dec" \
    --signal "${ROB}.io_writeback_15_valid|rob.writeback15.valid" \
    --signal "${ROB}.io_writeback_15_bits_robIdx_value|rob.writeback15.robIdx|dec" \
    --signal "${ROB}.io_commits_commitValid_0|rob.commit0.valid" \
    --signal "${ROB}.io_commits_info_0_debug_pc|rob.commit0.pc|hex" \
    2>&1 | grep -v findfont || true
else
  echo "跳过图 7：全核 VCD 不存在（${FULLCORE_VCD}）。先运行 bash scripts/50_run_fullcore_difftest.sh wave，或用 FULLCORE_VCD=<路径> 指定。"
fi

echo ""
echo "生成完毕："
ls -1 "${OUT}"/*.png | sed "s@${ROOT}/@  @"
echo "STAGE1-FIGURES: DONE"
