#!/usr/bin/env bash
# =============================================================================
# fault_inject_vdot.sh —— vdot RTL 故障注入自测
#
# 目的：证明 P4 的功能测试「真的会失败」。依次在 RTL 上人为制造 5 个语义不同的
# 缺陷，每次重建 emu 并回放全部定向语料 + 随机激励，要求每个缺陷都被检出
# （至少一个 suite 报 EMU BADTRAP）。每轮结束后自动还原源码。
#
# 用法： bash scripts/tools/fault_inject_vdot.sh
# 日志： logs/stage2/p5_fault_injection.log（由调用方 tee，或本脚本直接写）
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
YS_DIR="${REPO_ROOT}/work/XiangShan-vdot/yunsuan"
VEC_DIR="${REPO_ROOT}/tests/vectors"
TREE="${YS_DIR}/src/main/scala/yunsuan/vector/vectorIMAC/VDotTree.scala"
TOP="${YS_DIR}/src/main/scala/yunsuan/vector/vectorIMAC/VDotTop.scala"
BK="${REPO_ROOT}/work/.fault_backup"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/env_host.sh"

mkdir -p "${BK}"
cp -f "${TREE}" "${BK}/VDotTree.scala"
cp -f "${TOP}"  "${BK}/VDotTop.scala"

restore() { cp -f "${BK}/VDotTree.scala" "${TREE}"; cp -f "${BK}/VDotTop.scala" "${TOP}"; }
trap 'restore' EXIT

# 重建 emu。返回非 0 表示构建失败。
# 另外校验 build/emu 的内容确实变了 —— 否则「故障没被检出」可能只是因为根本没重编。
rebuild() {
  local expect_change="${1:-yes}"
  local before=""
  [ -f "${YS_DIR}/build/emu" ] && before=$(md5 -q "${YS_DIR}/build/emu")
  bash "${REPO_ROOT}/scripts/tools/mill_state_guard.sh" "${YS_DIR}" >/dev/null 2>&1 || true
  if ! make -C "${YS_DIR}" emu > /tmp/fault_rebuild.log 2>&1; then
    echo "    [BUILD FAILED] 见 /tmp/fault_rebuild.log"
    tail -25 /tmp/fault_rebuild.log | sed 's/^/      /'
    return 1
  fi
  local after; after=$(md5 -q "${YS_DIR}/build/emu")
  echo "    emu md5: ${before:-<none>} -> ${after}"
  if [ "${expect_change}" = "yes" ] && [ -n "${before}" ] && [ "${before}" = "${after}" ]; then
    echo "    [警告] emu 二进制没有变化，故障可能没有真正进入构建"
    return 1
  fi
  return 0
}

# 跑一遍完整检测集，打印每个 suite 的判定，返回被检出的 suite 数
run_detect() {
  local caught=0 total=0
  for f in positive negative boundary vdotacc_positive vdotacc_negative vdotacc_boundary \
           vdot4a_positive vdot4a_negative vdot4a_boundary vstart_relaxed; do
    local VF="${VEC_DIR}/${f}.txt"
    local N; N=$(awk '!/^#/ && NF>0 && $NF=="OK"' "${VF}" | wc -l | tr -d ' ')
    local R; R=$( cd "${YS_DIR}" && YS_VDOT_VECTORS="${VF}" ./build/emu -O "${N}" -s 7 2>&1 | grep -oE "EMU (EXCEEDED LIMIT|BADTRAP)" | head -1 )
    total=$((total+1))
    if [ "${R}" = "EMU BADTRAP" ]; then caught=$((caught+1)); printf '      %-18s DETECTED (EMU BADTRAP)\n' "${f}"; 
    else printf '      %-18s not detected (%s)\n' "${f}" "${R}"; fi
  done
  for op in 0 1 2; do
    local name; name=$(echo "vdot vdotacc vdot4a" | cut -d' ' -f$((op+1)))
    local R; R=$( cd "${YS_DIR}" && YS_FUTYPE=10 YS_FUOPTYPE=${op} ./build/emu -O 20000 -s 11 2>&1 | grep -oE "EMU (EXCEEDED LIMIT|BADTRAP)" | head -1 )
    total=$((total+1))
    if [ "${R}" = "EMU BADTRAP" ]; then caught=$((caught+1)); printf '      %-18s DETECTED (EMU BADTRAP)\n' "random/${name}";
    else printf '      %-18s not detected (%s)\n' "random/${name}" "${R}"; fi
  done
  echo "    -> 被检出的检测项：${caught}/${total}"
  [ ${caught} -gt 0 ]
}

NFAULT=0; NCAUGHT=0
inject() {   # $1=编号 $2=描述 $3=文件 $4..=sed 表达式
  local id="$1"; shift
  local desc="$1"; shift
  local file="$1"; shift
  NFAULT=$((NFAULT+1))
  echo ""
  echo "============================================================================"
  echo "故障 #${id}：${desc}"
  echo "  目标文件：${file#${REPO_ROOT}/}"
  restore
  for e in "$@"; do
    if ! perl -0777 -i -pe "${e}" "${file}"; then echo "  perl 替换失败"; return 1; fi
  done
  echo "  --- 注入后的源码差异 ---"
  diff -u "${BK}/$(basename "${file}")" "${file}" | sed -n '3,40p' | sed 's/^/  /'
  echo "  --- 重建 emu ---"
  rebuild || { echo "  跳过（构建失败）"; return 1; }
  echo "  --- 检测结果 ---"
  if run_detect; then echo "  [故障 #${id}] CAUGHT"; NCAUGHT=$((NCAUGHT+1)); else echo "  [故障 #${id}] *** ESCAPED ***"; fi
  restore
}

echo "=== vdot RTL 故障注入自测  $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
echo "基线：先确认未注入故障时全部检测项 PASS"
rebuild no || exit 1
echo "  --- 基线检测结果（期望全部 not detected，即全 PASS）---"
run_detect || true

inject 1 "丢掉乘积的符号扩展（VDotTree 符号扩展改为零扩展）" "${TREE}" \
  's{val signExtended = Cat\(Fill\(accWidth - prodWidth, io\.prod\(i\)\(prodWidth - 1\)\), io\.prod\(i\)\)}{val signExtended = Cat(0.U((accWidth - prodWidth).W), io.prod(i))  /* FAULT#1 */}'

inject 2 "vl 边界 off-by-one（active 判据 i < vl 改为 i <= vl）" "${TOP}" \
  's{\(i\.U >= vstart\) && \(i\.U < vl\)}{(i.U >= vstart) \&\& (i.U <= vl)  /* FAULT#2 */}'

inject 3 "忽略 v0 掩码（active 判据去掉 (vm || mask(i))）" "${TOP}" \
  's{\(io\.info\.vm \|\| io\.mask\(i\)\)}{true.B  /* FAULT#3 */}'

inject 4 "加法树第 2 级蝶形折叠（Fold L2，S2 级）永久关闭" "${TREE}" \
  's{csNodeS2 = foldStage\(csNodeS2, 1 << k, foldLevelsS2 > k\.U\)}{csNodeS2 = foldStage(csNodeS2, 1 << k, false.B)  /* FAULT#4 */}'

inject 5 "归约结果取错 lane（元素 0 由 lane0 改成 lane1）" "${TOP}" \
  's{private val redVdTailOne = Cat\(~0\.U\(\(VLEN - 32\)\.W\), dotVd\(31, 0\)\)}{private val redVdTailOne = Cat(~0.U((VLEN - 32).W), dotVd(63, 32))  /* FAULT#5 */}' \
  's{private val redVdTailOld = Cat\(oldVdS2\(VLEN - 1, 32\), dotVd\(31, 0\)\)}{private val redVdTailOld = Cat(oldVdS2(VLEN - 1, 32), dotVd(63, 32))  /* FAULT#5 */}'

echo ""
echo "============================================================================"
echo "还原源码并重建干净的 emu"
restore
rebuild || exit 1
echo "  --- 还原后的回归（期望全部 PASS / not detected）---"
run_detect || true
echo ""
echo "=== 故障注入汇总：注入 ${NFAULT} 个，被检出 ${NCAUGHT} 个 ==="
[ "${NCAUGHT}" -eq "${NFAULT}" ] && echo "FAULT-INJECTION: PASS (${NCAUGHT}/${NFAULT})" || echo "FAULT-INJECTION: 有 $((NFAULT-NCAUGHT)) 个故障未被检出，见上文 ESCAPED 标记"
