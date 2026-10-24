#!/usr/bin/env bash
# =============================================================================
# 20_run_func_tests.sh —— vdot 指令族 L1 功能测试总入口（赛题阶段二 2.3.1/2.3.2/2.3.3）
#
# 一条命令重跑整个功能验证战役，并在最后打印汇总表。所有数字都来自本次真实执行。
#
#   bash scripts/20_run_func_tests.sh
#
# 可选开关（默认关闭的两项耗时较长，单独提供）：
#   WITH_WAVE=1    额外重建带 trace 的 emu 并抓三条指令的波形（会重建两次 emu）
#   WITH_FAULT=1   额外跑 5 个故障注入（每个故障重建一次 emu）
#   RANDOM_OPS=N   每条指令的随机激励条数（默认 20000，验收要求 >= 10000）
#   RANDOM_SEEDS="a b c"   随机种子列表（默认 "11 12 13"）
#
# 输出日志（logs/stage2/）：
#   p5_func_positive.log   2.3.1 正数测试
#   p5_func_negative.log   2.3.2 负数测试
#   p5_func_boundary.log   2.3.3 边界值测试
#   p5_func_random.log     随机差分测试
#   p5_regression.log      既有指令/既有功能单元回归
#   p5_vimacu_equiv.log    VIMacU（真正被集成的模块）等价性验证
#   p5_fault_injection.log 故障注入（WITH_FAULT=1 时刷新）
#   p5_summary.log         汇总表
#
# 判读规则（来自 yunsuan/src/test/csrc/emu.cpp:205-210）：
#   EMU EXCEEDED LIMIT = 跑满指定条数且每一条都与 golden model 逐位一致  -> PASS
#   EMU BADTRAP        = 出现失配或 DUT 卡死，并打印 REF/DUT 数值        -> FAIL
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YS_DIR="${REPO_ROOT}/work/XiangShan-vdot/yunsuan"
XS_DIR="${REPO_ROOT}/work/XiangShan-vdot"
VEC_DIR="${REPO_ROOT}/tests/vectors"
LOG_DIR="${REPO_ROOT}/logs/stage2"
WAVE_DIR="${LOG_DIR}/waveform"
EMU="${YS_DIR}/build/emu"
PRISTINE_EMU="${REPO_ROOT}/work/XiangShan-kmhv2/yunsuan/build/emu"

WITH_WAVE="${WITH_WAVE:-0}"
WITH_FAULT="${WITH_FAULT:-0}"
RANDOM_OPS="${RANDOM_OPS:-20000}"
RANDOM_SEEDS="${RANDOM_SEEDS:-11 12 13}"
CORPUS_SEED="${CORPUS_SEED:-7}"

SUMMARY="${LOG_DIR}/p5_summary.log"
ROWS="$(mktemp -t vdotrows)"
trap 'rm -f "${ROWS}"' EXIT

mkdir -p "${LOG_DIR}" "${WAVE_DIR}"

step() { printf '\n\033[1;34m==> [%s] %s\033[0m\n' "$(date '+%H:%M:%S')" "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/env_host.sh"

# ---------------------------------------------------------------------------
# 0. 准备 emu
# ---------------------------------------------------------------------------
step "0/7 准备 L1 仿真器"
if [ ! -x "${EMU}" ]; then
  info "build/emu 不存在，调用 scripts/11_build_vdot_sim.sh 构建"
  BUILD_ONLY=1 bash "${REPO_ROOT}/scripts/11_build_vdot_sim.sh"
fi
[ -x "${EMU}" ] || die "build/emu 仍然不存在"
info "emu        : ${EMU} ($(ls -l "${EMU}" | awk '{print $5}') bytes)"
info "参考模型   : tests/golden/vdot_ref.c（由 vector_dot.cpp 直接 #include，未重写语义）"
info "语料       : ${VEC_DIR}"

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
# corpus_counts <file> -> "total ok skip"
corpus_counts() {
  local f="$1" total ok
  total=$(awk '!/^#/ && NF>0' "$f" | wc -l | tr -d ' ')
  ok=$(awk '!/^#/ && NF>0 && $NF=="OK"' "$f" | wc -l | tr -d ' ')
  echo "${total} ${ok} $((total - ok))"
}

# 跑一个定向语料 suite，打印全部原始输出，并把一行结果写进 ${ROWS}
# 用法： run_corpus <分类> <suite名> <语料文件> [额外说明]
run_corpus() {
  local cat="$1" name="$2" f="$3" note="${4:-}"
  local total ok skip reasons out verdict ops
  read -r total ok skip <<<"$(corpus_counts "$f")"
  reasons=$(awk '!/^#/ && NF>0 && $NF!="OK" {print $NF}' "$f" | sort | uniq -c | awk '{printf "%s×%s ", $2, $1}')
  echo ""
  echo "########################################################################"
  echo "# suite  : ${name}"
  echo "# file   : ${f#${REPO_ROOT}/}"
  echo "# 用例数 : 总 ${total}，可执行 ${ok}，跳过 ${skip} ${reasons:+（${reasons}）}"
  echo "# 命令   : YS_VDOT_VECTORS=${f#${REPO_ROOT}/} ./build/emu -O ${ok} -s ${CORPUS_SEED}"
  echo "########################################################################"
  out=$( cd "${YS_DIR}" && YS_VDOT_VECTORS="${f}" ./build/emu -O "${ok}" -s "${CORPUS_SEED}" 2>&1 || true )
  echo "${out}"
  verdict=$(echo "${out}" | grep -oE "EMU (EXCEEDED LIMIT|BADTRAP)" | head -1)
  ops=$(echo "${out}" | sed -n 's/.*Operations:\([0-9]*\).*/\1/p' | head -1)
  ops="${ops:-0}"
  local pass fail res
  if [ "${verdict}" = "EMU EXCEEDED LIMIT" ] && [ "${ops}" = "${ok}" ]; then
    pass="${ok}"; fail=0; res="PASS"
  else
    pass=$((ops > 0 ? ops - 1 : 0)); fail=$((ok - pass)); res="FAIL"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${cat}" "${name}" "${ok}" "${pass}" "${fail}" "${skip}" "${res}" "${note}" >> "${ROWS}"
  echo "# 判定   : ${res}（attempted=${ok} passed=${pass} failed=${fail} skipped=${skip}）"
}

# 跑一次随机激励，写一行结果
# 用法： run_random <分类> <名字> <YS_FUOPTYPE 或 all> <条数> <seed>
run_random() {
  local cat="$1" name="$2" op="$3" n="$4" s="$5"
  local out verdict ops cmd
  echo ""
  echo "########################################################################"
  if [ "${op}" = "all" ]; then
    cmd="YS_FUTYPE=10 ./build/emu -O ${n} -s ${s}"
    echo "# ${name}：命令 ${cmd}"
    out=$( cd "${YS_DIR}" && YS_FUTYPE=10 ./build/emu -O "${n}" -s "${s}" 2>&1 || true )
  else
    cmd="YS_FUTYPE=10 YS_FUOPTYPE=${op} ./build/emu -O ${n} -s ${s}"
    echo "# ${name}：命令 ${cmd}"
    out=$( cd "${YS_DIR}" && YS_FUTYPE=10 YS_FUOPTYPE="${op}" ./build/emu -O "${n}" -s "${s}" 2>&1 || true )
  fi
  echo "########################################################################"
  echo "${out}"
  verdict=$(echo "${out}" | grep -oE "EMU (EXCEEDED LIMIT|BADTRAP)" | head -1)
  ops=$(echo "${out}" | sed -n 's/.*Operations:\([0-9]*\).*/\1/p' | head -1); ops="${ops:-0}"
  local pass fail res
  if [ "${verdict}" = "EMU EXCEEDED LIMIT" ] && [ "${ops}" = "${n}" ]; then
    pass="${n}"; fail=0; res="PASS"
  else
    pass=$((ops > 0 ? ops - 1 : 0)); fail=$((n - pass)); res="FAIL"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${cat}" "${name}" "${n}" "${pass}" "${fail}" "0" "${res}" "${cmd}" >> "${ROWS}"
  echo "# 判定   : ${res}（attempted=${n} passed=${pass} failed=${fail}）"
}

# 从某个语料文件里挑一条，单独跑并打印「输入 / 期望 / DUT 实测」三元组
# 用法： worked_example <语料文件> <awk 过滤表达式> <说明>
worked_example() {
  local f="$1" filter="$2" desc="$3"
  local tmp; tmp="$(mktemp -t vdotcase)"
  head -1 "$f" > "${tmp}"
  awk "!/^#/ && NF>0 && ${filter}" "$f" | head -1 >> "${tmp}"
  echo ""
  echo "======================================================================"
  echo "== 代表性用例：${desc}"
  echo "== 来源：${f#${REPO_ROOT}/}   过滤：${filter}"
  echo "== 语料原文（op vsew vstart vl vm vta vma vs1 vs2 vd_in vd_expected v0 status）："
  tail -1 "${tmp}" | sed 's/^/==   /'
  echo "======================================================================"
  ( cd "${YS_DIR}" && YS_DUMP=1 YS_VDOT_VECTORS="${tmp}" ./build/emu -O 1 -s "${CORPUS_SEED}" 2>&1 || true )
  rm -f "${tmp}"
}

# ---------------------------------------------------------------------------
# 1. 2.3.1 正数测试
# ---------------------------------------------------------------------------
step "1/7 2.3.1 正数测试"
{
  echo "=== 2.3.1 正数测试  $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
  echo "=== emu: ${EMU} ==="
  run_corpus "2.3.1 正数" "positive(vdot.vv)"        "${VEC_DIR}/positive.txt"
  run_corpus "2.3.1 正数" "positive(vdotacc.vv)"     "${VEC_DIR}/vdotacc_positive.txt"
  run_corpus "2.3.1 正数" "positive(vdot4a.vv)"      "${VEC_DIR}/vdot4a_positive.txt"
  worked_example "${VEC_DIR}/positive.txt" '$8=="0102030405060708090a0b0c0d0e0f10" && $9==$8' \
    "vdot.vv：vs1=vs2=[1..16]，Σ i² = 1496 = 0x5D8"
  worked_example "${VEC_DIR}/vdotacc_positive.txt" '$4==16 && $6==1' \
    "vdotacc.vv：带累加器的正数点积"
  worked_example "${VEC_DIR}/vdot4a_positive.txt" '$4==4 && $6==1' \
    "vdot4a.vv：4 组分组点积累加"
} 2>&1 | tee "${LOG_DIR}/p5_func_positive.log"

# ---------------------------------------------------------------------------
# 2. 2.3.2 负数测试
# ---------------------------------------------------------------------------
step "2/7 2.3.2 负数测试"
{
  echo "=== 2.3.2 负数测试  $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
  run_corpus "2.3.2 负数" "negative(vdot.vv)"        "${VEC_DIR}/negative.txt"
  run_corpus "2.3.2 负数" "negative(vdotacc.vv)"     "${VEC_DIR}/vdotacc_negative.txt"
  run_corpus "2.3.2 负数" "negative(vdot4a.vv)"      "${VEC_DIR}/vdot4a_negative.txt"
  worked_example "${VEC_DIR}/negative.txt" '$8=="80808080808080808080808080808080" && $9=="80808080808080808080808080808080"' \
    "vdot.vv 符号扩展陷阱：全 0x80 × 全 0x80 = 16×(-128)×(-128) = 262144 = 0x40000"
  worked_example "${VEC_DIR}/negative.txt" '$8=="80808080808080808080808080808080" && $9=="7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f"' \
    "vdot.vv 正负混合：16×(-128)×(+127) = -260096 = 0xFFFC0800"
  worked_example "${VEC_DIR}/vdot4a_negative.txt" '$4==4 && $6==1' \
    "vdot4a.vv：负数分组点积"
} 2>&1 | tee "${LOG_DIR}/p5_func_negative.log"

# ---------------------------------------------------------------------------
# 3. 2.3.3 边界值测试
# ---------------------------------------------------------------------------
step "3/7 2.3.3 边界值测试"
{
  echo "=== 2.3.3 边界值测试  $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
  run_corpus "2.3.3 边界" "boundary(vdot.vv)"     "${VEC_DIR}/boundary.txt" \
    "跳过项为 ILLEGAL_VSTART / ERR_SEW，FU 级平台不建模异常"
  run_corpus "2.3.3 边界" "boundary(vdotacc.vv)"  "${VEC_DIR}/vdotacc_boundary.txt" \
    "同上"
  run_corpus "2.3.3 边界" "boundary(vdot4a.vv)"   "${VEC_DIR}/vdot4a_boundary.txt" \
    "跳过项为 ERR_SEW；vstart!=0 的 6 条 prestart 用例全部真实执行"
  run_corpus "2.3.3 边界" "vstart_relaxed(vdot/vdotacc)" "${VEC_DIR}/vstart_relaxed.txt" \
    "非规范 SKIP 策略语料，专门激励归约通路的 prestart 门控"
  echo ""
  echo "---- 边界覆盖点自查（直接从语料文件统计，不依赖仿真）----"
  for f in boundary vdotacc_boundary vdot4a_boundary; do
    VF="${VEC_DIR}/${f}.txt"
    echo "[${f}]"
    echo "  vl 取值     : $(awk '!/^#/ && NF>0 {print $4}' "${VF}" | sort -n | uniq | tr '\n' ' ')"
    echo "  vstart 取值 : $(awk '!/^#/ && NF>0 {print $3}' "${VF}" | sort -n | uniq | tr '\n' ' ')"
    echo "  vta 取值    : $(awk '!/^#/ && NF>0 {print $6}' "${VF}" | sort -n | uniq | tr '\n' ' ')"
    echo "  vma 取值    : $(awk '!/^#/ && NF>0 {print $7}' "${VF}" | sort -n | uniq | tr '\n' ' ')"
    echo "  vm  取值    : $(awk '!/^#/ && NF>0 {print $5}' "${VF}" | sort -n | uniq | tr '\n' ' ')"
    echo "  带掩码(vm=0)用例数 : $(awk '!/^#/ && NF>0 && $5==0' "${VF}" | wc -l | tr -d ' ')"
    echo "  vstart!=0 且可执行 : $(awk '!/^#/ && NF>0 && $3!=0 && $NF=="OK"' "${VF}" | wc -l | tr -d ' ')"
    echo "  全零操作数用例数   : $(awk '!/^#/ && NF>0 && $8=="00000000000000000000000000000000" && $9=="00000000000000000000000000000000"' "${VF}" | wc -l | tr -d ' ')"
    echo "  全 0x80 操作数用例 : $(awk '!/^#/ && NF>0 && $8=="80808080808080808080808080808080" && $9=="80808080808080808080808080808080"' "${VF}" | wc -l | tr -d ' ')"
  done
  worked_example "${VEC_DIR}/boundary.txt" '$4==0' \
    "vdot.vv vl=0：裁定 S-5，连 tail 都不写，vd 原样保留"
  worked_example "${VEC_DIR}/boundary.txt" '$5==0 && $12 ~ /^0000a5a5/ && $6==1' \
    "vdot.vv 全 0 掩码（v0 低 16 位全 0、高位填 0xA5 用于检验无关掩码位被忽略）：裁定 S-4，仍然写 vd[0]=0"
  worked_example "${VEC_DIR}/vdot4a_boundary.txt" '$3==1 && $4==4' \
    "vdot4a.vv vstart=1：prestart 元素 0 保持不变（裁定 S-7，RTL 实现说明 §10 第 3 条的缺口）"
} 2>&1 | tee "${LOG_DIR}/p5_func_boundary.log"

# ---------------------------------------------------------------------------
# 4. 随机差分测试
# ---------------------------------------------------------------------------
step "4/7 随机差分测试（每条指令 >= ${RANDOM_OPS} × $(echo ${RANDOM_SEEDS} | wc -w | tr -d ' ') 个种子）"
{
  echo "=== 随机差分测试  $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
  echo "=== 参考模型 = tests/golden/vdot_ref.c（直接 #include，禁止重写）==="
  echo ""
  echo "--- (A) 共享随机语料回放（tests/vectors/*_random.txt，期望值由同一份参考模型现场复算）---"
  run_corpus "随机差分" "random.txt(vdot.vv)"        "${VEC_DIR}/random.txt" \
    "跳过项为 ILLEGAL_VSTART（归约类 vstart!=0，FU 级不建模异常）"
  run_corpus "随机差分" "random.txt(vdotacc.vv)"     "${VEC_DIR}/vdotacc_random.txt" "同上"
  run_corpus "随机差分" "random.txt(vdot4a.vv)"      "${VEC_DIR}/vdot4a_random.txt" \
    "vdot4a 的 vstart!=0 合法，10000 条全部可执行，其中 1539 条 vstart!=0"
  echo ""
  echo "--- (B) 测试平台随机激励（每次重新随机，与语料文件互相独立）---"
  for s in ${RANDOM_SEEDS}; do
    run_random "随机差分" "driver/vdot.vv seed=${s}"    0 "${RANDOM_OPS}" "${s}"
  done
  for s in ${RANDOM_SEEDS}; do
    run_random "随机差分" "driver/vdotacc.vv seed=${s}" 1 "${RANDOM_OPS}" "${s}"
  done
  for s in ${RANDOM_SEEDS}; do
    run_random "随机差分" "driver/vdot4a.vv seed=${s}"  2 "${RANDOM_OPS}" "${s}"
  done
  run_random "随机差分" "driver/三条混合 seed=14"      all "$((RANDOM_OPS + RANDOM_OPS / 2))" 14
} 2>&1 | tee "${LOG_DIR}/p5_func_random.log"

# ---------------------------------------------------------------------------
# 5. 既有指令 / 既有功能单元回归
# ---------------------------------------------------------------------------
step "5/7 既有指令回归"
{
  echo "=== 既有指令 / 既有功能单元回归  $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
  echo ""
  echo "--- (A) 上游 CI 的随机混合测试（.github/workflows/main.yml:42 原样命令）---"
  echo "命令： ./build/emu -O 10000"
  out=$( cd "${YS_DIR}" && ./build/emu -O 10000 -s 0 2>&1 || true )
  echo "${out}"
  v=$(echo "${out}" | grep -oE "EMU (EXCEEDED LIMIT|BADTRAP)" | head -1)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "既有回归" "上游CI混合随机(含VDot)" 10000 \
    "$([ "$v" = "EMU EXCEEDED LIMIT" ] && echo 10000 || echo 0)" \
    "$([ "$v" = "EMU EXCEEDED LIMIT" ] && echo 0 || echo 10000)" 0 \
    "$([ "$v" = "EMU EXCEEDED LIMIT" ] && echo PASS || echo FAIL)" "./build/emu -O 10000 -s 0" >> "${ROWS}"
  echo ""
  echo "--- (B) 逐个既有功能单元定向回归（2000 条 / 个）---"
  echo "    fuType 对照表见 docs/stage1/03_仿真平台搭建报告.md §4.3"
  for FT in 1 2 3 4 6 7 8 9; do
    out=$( cd "${YS_DIR}" && YS_FUTYPE=${FT} ./build/emu -O 2000 -s 0 2>&1 || true )
    v=$(echo "${out}" | grep -oE "EMU (EXCEEDED LIMIT|BADTRAP)" | head -1)
    c=$(echo "${out}" | sed -n 's/.*Cycles:\([0-9]*\).*/\1/p' | head -1)
    printf '    fuType=%-2s  %-20s cycles=%-8s\n' "${FT}" "${v}" "${c}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "既有回归" "fuType=${FT} 定向 2000 条" 2000 \
      "$([ "$v" = "EMU EXCEEDED LIMIT" ] && echo 2000 || echo 0)" \
      "$([ "$v" = "EMU EXCEEDED LIMIT" ] && echo 0 || echo 2000)" 0 \
      "$([ "$v" = "EMU EXCEEDED LIMIT" ] && echo PASS || echo FAIL)" "cycles=${c}" >> "${ROWS}"
  done
  echo ""
  echo "--- (C) fuType=5（VIAluFWrapper / vadd.vv）需要钉住 fuOpType ---"
  echo "    上游 gen_random_optype() 对 fuType=5 会生成 golden model 不支持的 optype 3，"
  echo "    这是上游既有限制，与 vdot 无关；阶段一的做法同样是钉 YS_FUOPTYPE=0。"
  out=$( cd "${YS_DIR}" && YS_FUTYPE=5 YS_FUOPTYPE=0 ./build/emu -O 2000 -s 0 2>&1 || true )
  v=$(echo "${out}" | grep -oE "EMU (EXCEEDED LIMIT|BADTRAP)" | head -1)
  c=$(echo "${out}" | sed -n 's/.*Cycles:\([0-9]*\).*/\1/p' | head -1)
  printf '    fuType=5 fuOpType=0  %-20s cycles=%-8s\n' "${v}" "${c}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "既有回归" "fuType=5(vadd.vv) 2000 条" 2000 \
    "$([ "$v" = "EMU EXCEEDED LIMIT" ] && echo 2000 || echo 0)" \
    "$([ "$v" = "EMU EXCEEDED LIMIT" ] && echo 0 || echo 2000)" 0 \
    "$([ "$v" = "EMU EXCEEDED LIMIT" ] && echo PASS || echo FAIL)" "cycles=${c}" >> "${ROWS}"
  echo ""
  echo "--- (D) 与 pristine 基线逐 FU 对拍（证明差异为零）---"
  if [ -x "${PRISTINE_EMU}" ]; then
    echo "    pristine emu: ${PRISTINE_EMU}（只读运行，不修改该工作树）"
    printf '    %-7s %-44s %-44s %s\n' "fuType" "pristine 基线" "vdot 工作树" "逐字相同?"
    for FT in 0 1 2 3 4 6 7 8 9; do
      # emu 在 BADTRAP 时返回 1（fuType=0 两棵树上都会 BADTRAP），这里显式容错
      pa=$( cd /tmp && YS_FUTYPE=${FT} "${PRISTINE_EMU}" -O 2000 -s 0 2>&1 || true )
      vb=$( cd "${YS_DIR}" && YS_FUTYPE=${FT} ./build/emu -O 2000 -s 0 2>&1 || true )
      # 只取判定行与周期/条数行；"EMU has executed N ms" 是 wall-clock，必须排除
      pa=$( echo "${pa}" | grep -E "^(EMU (EXCEEDED LIMIT|BADTRAP)|HAS Executed)" | tr '\n' ' ' || true )
      vb=$( echo "${vb}" | grep -E "^(EMU (EXCEEDED LIMIT|BADTRAP)|HAS Executed)" | tr '\n' ' ' || true )
      if [ "${pa}" = "${vb}" ]; then eq="YES"; else eq="NO"; fi
      printf '    %-7s %-44s %-44s %s\n' "${FT}" "${pa}" "${vb}" "${eq}"
    done
    echo ""
    echo "    注：fuType=0（VFloatAdder）在 pristine 基线上同样 BADTRAP（同一条用例、同一拍），"
    echo "        属于上游既有缺陷（它本来就不在上游 ALL_FUTYPES 随机集合里），与 vdot 无关。"
    echo "    下面给出两棵树在 fuType=0 上的完整输出 diff（应当只差 wall-clock 行）："
    ( cd /tmp && YS_FUTYPE=0 "${PRISTINE_EMU}" -O 20 -s 0 2>&1 || true ) \
      | grep -v "compiled at" | grep -v "executed" > /tmp/ft0_pristine.txt
    ( cd "${YS_DIR}" && YS_FUTYPE=0 ./build/emu -O 20 -s 0 2>&1 || true ) \
      | grep -v "compiled at" | grep -v "executed" > /tmp/ft0_vdot.txt
    if diff /tmp/ft0_pristine.txt /tmp/ft0_vdot.txt; then
      echo "    => 两棵树在 fuType=0 上的输出逐字节相同（含失配的 REF/DUT 数值），"
      echo "       说明该失配是上游既有缺陷，与 vdot 改动无关"
    else
      echo "    => 两棵树输出不同（见上面的 diff），需要进一步排查"
    fi
  else
    echo "    [跳过] 未找到 pristine 基线 emu：${PRISTINE_EMU}"
  fi
  echo ""
  echo "--- (E) 生成 Verilog 的逐模块比对（阶段一基线 vs 本阶段）---"
  echo "命令： diff <(sed -E 's@//.*@@' rtl/verilog/baseline/VIMac.sv) <(sed -E 's@//.*@@' rtl/verilog/vdot/VIMac.sv)"
  n=$(diff <(sed -E 's@//.*@@; s/[[:space:]]+$//' "${REPO_ROOT}/rtl/verilog/baseline/VIMac.sv") \
           <(sed -E 's@//.*@@; s/[[:space:]]+$//' "${REPO_ROOT}/rtl/verilog/vdot/VIMac.sv") | wc -l | tr -d ' ')
  echo "    VIMac.sv 去注释后差异行数： ${n}"
  python3 "${REPO_ROOT}/scripts/tools/verilog_module_diff.py" \
    "${REPO_ROOT}/rtl/verilog/baseline/SimTop.v" "${REPO_ROOT}/rtl/verilog/vdot/SimTop_with_vdot.v"
} 2>&1 | tee "${LOG_DIR}/p5_regression.log"

# ---------------------------------------------------------------------------
# 5.5 补丁可应用性 + 译码级非法指令判定（含本阶段修复的 LMUL 守卫）
# ---------------------------------------------------------------------------
step "5.5/7 补丁可应用性与译码级非法指令判定"
{
  bash "${REPO_ROOT}/scripts/tools/verify_patches.sh" || true
  echo ""
  bash "${REPO_ROOT}/scripts/tools/run_decode_tb.sh" || true
} 2>&1 | tee "${LOG_DIR}/p5_decode_illegal.log"
if grep -q "^VECEXC-TB: PASS" "${LOG_DIR}/p5_decode_illegal.log"; then
  nd=$(grep -oE "共 [0-9]+ 条" "${LOG_DIR}/p5_decode_illegal.log" | head -1 | grep -oE "[0-9]+")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "译码级" "VecExceptionGen 定向" "${nd:-0}" "${nd:-0}" 0 0 "PASS" \
    "scripts/tools/run_decode_tb.sh" >> "${ROWS}"
else
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "译码级" "VecExceptionGen 定向" 0 0 0 0 "FAIL" \
    "见 p5_decode_illegal.log" >> "${ROWS}"
fi
if grep -q "^PATCH-VERIFY: PASS" "${LOG_DIR}/p5_decode_illegal.log"; then
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "交付物" "三份补丁干净应用到 pristine" 3 3 0 0 "PASS" \
    "scripts/tools/verify_patches.sh" >> "${ROWS}"
else
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "交付物" "三份补丁干净应用到 pristine" 3 0 3 0 "FAIL" \
    "见 p5_decode_illegal.log" >> "${ROWS}"
fi

# ---------------------------------------------------------------------------
# 6. VIMacU 等价性（真正被集成进香山的模块）
# ---------------------------------------------------------------------------
step "6/7 VIMacU 等价性验证"
( bash "${REPO_ROOT}/scripts/tools/run_vimacu_tb.sh" || true ) 2>&1 | tee "${LOG_DIR}/p5_vimacu_equiv.log"
if grep -q "^VIMACU-TB: PASS" "${LOG_DIR}/p5_vimacu_equiv.log"; then
  VL=$(grep -E "^VIMacU 直驱汇总" "${LOG_DIR}/p5_vimacu_equiv.log" | head -1)
  nrun=$(echo  "${VL}" | sed -n 's/.*执行 \([0-9]*\) 条.*/\1/p')
  npass=$(echo "${VL}" | sed -n 's/.*通过 \([0-9]*\) 条.*/\1/p')
  nfail=$(echo "${VL}" | sed -n 's/.*失败 \([0-9]*\) 条.*/\1/p')
  nskip=$(echo "${VL}" | sed -n 's/.*跳过 \([0-9]*\) 条.*/\1/p')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "VIMacU 等价" "VIMacU 直驱语料回放" \
    "${nrun:-0}" "${npass:-0}" "${nfail:-0}" "${nskip:-0}" "PASS" \
    "scripts/tools/run_vimacu_tb.sh" >> "${ROWS}"
else
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "VIMacU 等价" "VIMacU 直驱语料回放" "0" "0" "0" "0" "FAIL" \
    "见 p5_vimacu_equiv.log" >> "${ROWS}"
fi

# ---------------------------------------------------------------------------
# 7. 可选：波形 / 故障注入
# ---------------------------------------------------------------------------
if [ "${WITH_WAVE}" = "1" ]; then
  step "7a/7 波形抓取（重建带 trace 的 emu）"
  ( bash "${REPO_ROOT}/scripts/tools/capture_vdot_waves.sh" || true ) 2>&1 | tee "${LOG_DIR}/p5_waveform.log"
else
  info "跳过波形抓取（WITH_WAVE=1 开启；已存档波形见 ${WAVE_DIR}）"
fi

if [ "${WITH_FAULT}" = "1" ]; then
  step "7b/7 故障注入（5 个故障，每个重建一次 emu）"
  ( bash "${REPO_ROOT}/scripts/tools/fault_inject_vdot.sh" || true ) 2>&1 | tee "${LOG_DIR}/p5_fault_injection.log"
else
  info "跳过故障注入（WITH_FAULT=1 开启；已存档结果见 ${LOG_DIR}/p5_fault_injection.log）"
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
step "汇总"
{
  echo "=== vdot 功能测试汇总  $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
  echo ""
  printf '%-14s %-34s %9s %9s %8s %8s %6s\n' "分类" "suite" "attempted" "passed" "failed" "skipped" "结果"
  printf '%s\n' "--------------------------------------------------------------------------------------------------"
  awk -F'\t' '{printf "%-14s %-34s %9s %9s %8s %8s %6s\n", $1,$2,$3,$4,$5,$6,$7}' "${ROWS}"
  printf '%s\n' "--------------------------------------------------------------------------------------------------"
  awk -F'\t' '{a+=$3; p+=$4; f+=$5; s+=$6; if($7!="PASS") bad++} END {
    printf "%-49s %9d %9d %8d %8d\n", "合计", a, p, f, s;
    printf "\n失败的 suite 数：%d\n", bad+0;
  }' "${ROWS}"
  echo ""
  echo "日志："
  for l in p5_func_positive p5_func_negative p5_func_boundary p5_func_random p5_regression p5_decode_illegal p5_vimacu_equiv p5_fault_injection p5_waveform; do
    [ -f "${LOG_DIR}/${l}.log" ] && printf "  %-26s %s\n" "${l}.log" "$(wc -l < "${LOG_DIR}/${l}.log" | tr -d ' ') 行"
  done
} 2>&1 | tee "${SUMMARY}"

FAILED=$(awk -F'\t' '$7!="PASS"' "${ROWS}" | wc -l | tr -d ' ')
if [ "${FAILED}" != "0" ]; then
  printf '\n\033[1;31m有 %s 个 suite 未通过，见上表\033[0m\n' "${FAILED}"
  exit 1
fi
printf '\n\033[1;32m全部 suite 通过\033[0m\n'
