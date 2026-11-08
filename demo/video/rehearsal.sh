#!/usr/bin/env bash
# 三段视频终端画面的正式演练：在本机一次性跑完所有短命令，由 asciinema 录成一份 .cast，
# 再由 splitcast.py 按「################  segment <名>」标记切成各场景。
#
#   asciinema rec --overwrite -q -c 'bash demo/video/rehearsal.sh' --cols 150 --rows 40 demo/video/casts/rehearsal.cast
#
# 只跑短命令（03 / 02 / 21 / wave-vl8 / 参考模型核对 / 读存档 VCD）；长任务（全核构建、20、30、40、全核 run/perf）
# 只用 sed / grep 展示仓库里已存档的运行结果，并在画面上写明「已存档的运行结果」。
# 日志、CSV、图一律写到 /tmp/rec，不覆盖仓库存档；录完用 git status 确认 logs/ bench/ docs/ 无变化。
set -u
cd "$(dirname "$0")/../.."
export REC=/tmp/rec LOG_ROOT=/tmp/rec/logs RESULTS_DIR=/tmp/rec/results FIG_DIR=/tmp/rec/figures
export NEMU_SYSROOT="${NEMU_SYSROOT:-/data/my/cie2026-vdot-xiangshan-linuxrepro/work/sysroot}"
export PLOT_PYTHON="${PLOT_PYTHON:-/tmp/vizenv/bin/python}"
mkdir -p "$LOG_ROOT" "$RESULTS_DIR" "$FIG_DIR"

seg()  { sleep 0.3; printf '################  segment %s\n' "$1"; sleep 0.3; }
note() { printf '\033[33m# %s\033[0m\n' "$*"; sleep 0.8; }
run()  {   # 打出命令（逐字），再执行
    printf '\033[1m$ \033[0m'
    local s="$*" i
    for ((i = 0; i < ${#s}; i++)); do printf '%s' "${s:i:1}"; sleep 0.012; done
    printf '\n'; sleep 0.3
    eval "$s"
    sleep 1.2
}

# ============================================================ 视频一：阶段一
seg v1-env
note "录制环境：Linux x86_64；日志写到 /tmp/rec，不覆盖仓库存档"
run 'export LOG_ROOT=/tmp/rec/logs RESULTS_DIR=/tmp/rec/results FIG_DIR=/tmp/rec/figures'
run "sed -n '28p;34p;145p' docs/stage1/00_环境版本锁定.md"
run 'for d in XiangShan-kmhv2 XiangShan-kmhv2/yunsuan NEMU; do printf "%-26s %s\n" $d $(git -C work/$d rev-parse --short=7 HEAD); done'
run 'source scripts/env_host.sh >/dev/null && java -version 2>&1 | head -1 && verilator --version'
note "已存档的运行结果：Linux 全新目录一键部署 00_setup_env_host.sh（216 s）"
run "sed -n '558,560p;644,645p' logs/stage1/linux_repro/00_setup_env_host.term.log"

seg v1-nemu
run 'bash scripts/02_build_nemu.sh 2>&1 | grep -v "^+ \(CC\|CXX\|LD\)"'

seg v1-hello
run 'bash scripts/03_run_hello.sh'
run "grep -n 'hello xiangshan\|HIT GOOD TRAP\|total guest instructions' \$LOG_ROOT/stage1/p1_hello_xiangshan.log"
note "已存档的运行结果：同一 hello 程序在香山 MinimalConfig 全核 emu + difftest 上（50_run_fullcore_difftest.sh hello）"
run "grep -an 'hello xiangshan\|HIT GOOD TRAP\|instrCnt' logs/stage1/p1_hello_xiangshan_fullcore.log"

seg v1-wave
note "读仓库存档 VCD（YunSuan L1 平台，WAVE=1 bash scripts/10_build_yunsuan_sim.sh 生成）"
run 'python3 scripts/tools/vcd_extract.py --vcd logs/stage1/waveform/vaddvv_vialufwrapper_fuType5_seed2.vcd --transactions | head -20'
run 'python3 scripts/tools/vcd_extract.py --vcd logs/stage1/waveform/vaddvv_vialufwrapper_fuType5_seed2.vcd --verify | tail -12'
note "已存档的运行结果：MinimalConfig 全核波形中单条 vadd.vv 的流水线时刻"
run "sed -n '150,181p' logs/stage3/fullcore/wave_trace.txt"

# ============================================================ 视频二：阶段二
seg v2-official
run 'python3 tests/golden/check_official_pseudocode.py --cli tests/golden/vdot_cli --vectors tests/vectors --random 10000 | tail -14'
note "已存档的运行结果：阴性对照（修订前 S-3 语料）"
run "sed -n '62p' logs/stage2/p3_official_pseudocode_equiv.log"

seg v2-rtl
run 'git apply --stat rtl/patch/0001-xiangshan-vdot.patch && git apply --stat rtl/patch/0002-yunsuan-vdot.patch'
run 'bash scripts/tools/sync_rtl_sources.sh --check'

seg v2-dut
run 'cd work/XiangShan-vdot/yunsuan && VF=../../../tests/vectors/negative.txt'
run "{ head -1 \$VF; awk '!/^#/ && NF>0 && \$8==\"80808080808080808080808080808080\" && \$9==\"80808080808080808080808080808080\"' \$VF | head -1; } > /tmp/rec/one.txt"
run 'YS_DUMP=1 YS_VDOT_VECTORS=/tmp/rec/one.txt ./build/emu -O 1 -s 7'
run 'cd - >/dev/null'

seg v2-tests
note "已存档的运行结果：bash scripts/20_run_func_tests.sh（约 5 分钟）"
run "sed -n '5,43p' logs/stage2/p5_summary.log"
run "tail -3 logs/stage2/p5_fault_injection.log && grep -n 'PASS 38' logs/stage2/p5_decode_prove_fail.log"

seg v2-wave
note "读仓库存档 VCD：vdot.vv，全 0x80 × 0x80"
run 'python3 scripts/tools/vcd_extract.py --vcd logs/stage2/waveform/vdotvv_vdottop_fuType10_seed1.vcd --transactions | head -12'
run 'python3 scripts/tools/vcd_extract.py --vcd logs/stage2/waveform/vdotvv_vdottop_fuType10_seed1.vcd --signals TOP.SimTop.vdot.vdotTree.io_prod_0 TOP.SimTop.vdot.vdotTree.io_foldLevels TOP.SimTop.vdot.vdotTree.sumRegS2_0 TOP.SimTop.vdot.vdotTree.io_dotVd TOP.SimTop.vdot.io_vd --at 21 23 25'

# ============================================================ 视频三：阶段三
seg v3-nemu
run 'bash scripts/21_build_nemu_vdot.sh 2>&1 | grep -v "^+ \(CC\|CXX\|LD\)"'

seg v3-cosim
note "已存档的运行结果：bash scripts/30_run_cosim.sh（约 4 分钟）"
run "sed -n '45,52p' logs/stage3/cosim/p6_cosim_run.log"
run "grep -n '被检出' logs/stage3/cosim/p6_fault_injection.log | tail -4"

seg v3-fullcore
note "已存档的运行结果：bash scripts/50_run_fullcore_difftest.sh run（MinimalConfig 全核 + difftest，约 1 小时）"
run "sed -n '1,13p' logs/stage3/fullcore/summary.log"
run 'tail -1 logs/stage3/fullcore/fault_summary.log; tail -1 logs/stage3/fullcore/fault_summary_s3old.log'
note "现场运行：vl=8 主演示（只需已构建的全核 emu，约 10 秒）"
run 'bash scripts/50_run_fullcore_difftest.sh wave-vl8'
run "grep -a 'csrr\|HIT GOOD TRAP\|instrCnt' \$LOG_ROOT/stage3/fullcore/wave_vl8_run.log"

seg v3-perf
note "已存档的运行结果：bash scripts/40_run_bench.sh 与 50_run_fullcore_difftest.sh perf"
run "sed -n '232,236p' logs/stage3/p7_latency_measure.log"
run "sed -n '110,117p' logs/stage3/p7_baseline_equiv.log"
run "grep -n 'PERF TOTAL\\|^RESULT' logs/stage3/fullcore/perf_cycles.log"
run "grep -E '函数整体|全核每 16' bench/results/speedup.csv | cut -d, -f1-5 | column -s, -t"

seg end
