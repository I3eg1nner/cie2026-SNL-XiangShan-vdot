#!/usr/bin/env bash
# =============================================================================
# sync_rtl_sources.sh —— 从「pristine 基线 + 补丁」重建 rtl/chisel/ 交付副本
#
# 背景：rtl/chisel/ 是给评委直接阅读的 Chisel 源码副本。它必须与 rtl/patch/ 下的
#       补丁逐字节一致，否则评委读到的源码与真正被测/被交付的 RTL 不是同一份
#       （阶段二独立验收 I-2 即为此类缺陷：副本停留在 dotEmulIllegal 修复之前）。
#
# 权威来源：**pristine 基线 + 补丁**，而不是任何实现工作树。
#   work/XiangShan-kmhv2            @ a4eeaab   （只用 git archive 导出只读副本）
#   work/XiangShan-kmhv2/yunsuan    @ 9559211
#   + rtl/patch/0001-xiangshan-vdot.patch
#   + rtl/patch/0002-yunsuan-vdot.patch
#   + tests/unit/yunsuan_vdot_testbench.patch
# 选择这一来源的理由：补丁是对上游的正式交付形式，且已由 verify_patches.sh 证明
# 可干净应用、应用结果与实现工作树逐字节一致；实现工作树则可能正被并发改动。
#
# 用法：
#   bash scripts/tools/sync_rtl_sources.sh            重建 rtl/chisel/（会覆盖）
#   bash scripts/tools/sync_rtl_sources.sh --check    只校验，不写入；有漂移则退出码 1
#
# 全程不写入 work/ 下的任何工作树。
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRISTINE="${REPO_ROOT}/work/XiangShan-kmhv2"
DEST="${REPO_ROOT}/rtl/chisel"
MANIFEST_NAME="MANIFEST.md"

MODE="sync"
case "${1:-}" in
  --check) MODE="check" ;;
  "")      MODE="sync" ;;
  -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "未知参数：$1（只接受 --check）" >&2; exit 2 ;;
esac

TMP="$(mktemp -d -t rtlsync)"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

RC=0
fail() { echo "  [DRIFT] $*"; RC=1; }

# --- 补丁清单：  <补丁路径>|<上游仓库>|<导出目录>|<交付子目录>|<中文说明> ----------
#     顺序即应用顺序；同一上游仓库的多个补丁按此顺序叠加。
PATCH_SPECS=(
  "rtl/patch/0001-xiangshan-vdot.patch|${PRISTINE}|xs|xiangshan|XiangShan 侧（译码链路 + VIMacU 包装 + 测试入口）"
  "rtl/patch/0002-yunsuan-vdot.patch|${PRISTINE}/yunsuan|ys|yunsuan|YunSuan 侧（乘法阵列抽头 + 新建加法树与 FU 顶层）"
  "tests/unit/yunsuan_vdot_testbench.patch|${PRISTINE}/yunsuan|ys|yunsuan-testbench|YunSuan L1 测试平台（Chisel 部分）"
)

# ---------------------------------------------------------------- 1. 导出基线
declare_exported=""
echo "=== rtl/chisel 交付副本 ${MODE}  ==="
echo "pristine 基线 : ${PRISTINE} @ $(git -C "${PRISTINE}" rev-parse --short HEAD)"
echo "               yunsuan @ $(git -C "${PRISTINE}/yunsuan" rev-parse --short HEAD)"

for spec in "${PATCH_SPECS[@]}"; do
  IFS='|' read -r rel repo exp sub desc <<< "${spec}"
  if [ ! -d "${TMP}/${exp}" ]; then
    mkdir -p "${TMP}/${exp}"
    ( cd "${repo}" && git archive HEAD src | tar -x -C "${TMP}/${exp}" ) || {
      echo "  [ERROR] git archive 失败：${repo}" >&2; exit 3; }
    ( cd "${TMP}/${exp}" && git init -q . )
    declare_exported="${declare_exported} ${exp}"
  fi
done

# ---------------------------------------------------------------- 2. 应用补丁
for spec in "${PATCH_SPECS[@]}"; do
  IFS='|' read -r rel repo exp sub desc <<< "${spec}"
  p="${REPO_ROOT}/${rel}"
  if ! ( cd "${TMP}/${exp}" && git apply --check "${p}" && git apply "${p}" ); then
    echo "  [ERROR] 补丁无法应用：${rel}" >&2; exit 3
  fi
  echo "  应用成功 ${rel}"
done

# ------------------------------------------------- 3. 抽取 Chisel 源码到 staging
#   交付副本按 basename 平铺；上游全路径记录在 MANIFEST 里。
STAGE="${TMP}/stage"
MANIFEST_BODY="${TMP}/manifest_body"
: > "${MANIFEST_BODY}"

n_total=0
for spec in "${PATCH_SPECS[@]}"; do
  IFS='|' read -r rel repo exp sub desc <<< "${spec}"
  p="${REPO_ROOT}/${rel}"
  mkdir -p "${STAGE}/${sub}"

  {
    echo ""
    echo "### \`rtl/chisel/${sub}/\` —— ${desc}"
    echo ""
    echo "来源补丁：\`${rel}\`"
    echo ""
    echo "| 交付文件 | 上游路径 | 状态 | 补丁改动 | 交付副本行数 |"
    echo "|---|---|---|---:|---:|"
  } >> "${MANIFEST_BODY}"

  # git apply --numstat 输出： <增> <删> <路径>
  while read -r add del path; do
    case "${path}" in *.scala) ;; *) continue ;; esac
    base="$(basename "${path}")"
    src="${TMP}/${exp}/${path}"
    [ -f "${src}" ] || { echo "  [ERROR] 补丁声明的文件不存在：${path}" >&2; exit 3; }
    if [ -e "${STAGE}/${sub}/${base}" ]; then
      echo "  [ERROR] 同名冲突：${sub}/${base}" >&2; exit 3
    fi
    cp "${src}" "${STAGE}/${sub}/${base}"

    # 新建 / 修改：看补丁里该文件是否带 `new file mode`
    is_new="$(awk -v f="${path}" '
      $0 == "diff --git a/" f " b/" f { inblk=1; next }
      /^diff --git / { inblk=0 }
      inblk && /^new file mode/ { print "yes"; exit }
    ' "${p}")"
    lines="$(wc -l < "${src}" | tr -d ' ')"
    if [ "${is_new}" = "yes" ]; then
      status="**新建**"; delta="+${add}"
    else
      status="修改"; delta="+${add} / −${del}"
    fi
    printf '| `%s` | `%s` | %s | %s | %s |\n' \
      "${base}" "${path}" "${status}" "${delta}" "${lines}" >> "${MANIFEST_BODY}"
    n_total=$((n_total+1))
  done < <( cd "${TMP}/${exp}" && git apply --numstat "${p}" )
done

# ---------------------------------------------------------------- 4. 生成 MANIFEST
MANIFEST_FILE="${STAGE}/${MANIFEST_NAME}"
{
  cat <<EOF
# \`rtl/chisel/\` 交付副本清单

本目录是 vdot 指令族全部新增/修改 **Chisel 源码**的只读副本，供评委直接阅读，
不参与任何构建。可综合的改动以 \`rtl/patch/\` 下的补丁为正式交付形式。

| 项 | 值 |
|---|---|
| 生成方式 | pristine 基线 \`git archive\` 导出 + 依次 \`git apply\` 补丁 |
| XiangShan 基线 | \`work/XiangShan-kmhv2\` @ \`$(git -C "${PRISTINE}" rev-parse --short HEAD)\` |
| YunSuan 基线 | \`work/XiangShan-kmhv2/yunsuan\` @ \`$(git -C "${PRISTINE}/yunsuan" rev-parse --short HEAD)\` |
| 重建命令 | \`bash scripts/tools/sync_rtl_sources.sh\` |
| 一致性自检 | \`bash scripts/tools/sync_rtl_sources.sh --check\`（有漂移则退出码 1） |
| 文件总数 | ${n_total} |

> 本文件由 \`scripts/tools/sync_rtl_sources.sh\` 自动生成，请勿手工编辑；
> 改了补丁就重跑一次重建命令。\`--check\` 会同时校验本清单本身。

## 文件清单
EOF
  cat "${MANIFEST_BODY}"
  cat <<'EOF'

## 说明

- **行数**列是交付副本（已打补丁）的 `wc -l`，不是改动行数；**补丁改动**列才是
  `git apply --numstat` 实测的增/删行数。两列口径不同，不要混用。
- 三个子目录对应三份补丁，互不重叠：`xiangshan/` 与 `yunsuan/` 是 RTL 本体
  （`rtl/patch/`），`yunsuan-testbench/` 是 L1 功能测试平台的 Chisel 部分，
  其补丁按交付结构放在 `tests/unit/` 下，这里只做阅读副本，避免评委漏看。
- 补丁里的非 Chisel 文件（C++ 参考模型薄壳、测试驱动、头文件）不复制到本目录，
  它们属于 `tests/` 交付物；完整改动见对应补丁。
- 生成的 Verilog 在 `rtl/verilog/`，不在本目录。
EOF
} > "${MANIFEST_FILE}"

# ---------------------------------------------------------------- 5. 落盘 / 校验
if [ "${MODE}" = "sync" ]; then
  for spec in "${PATCH_SPECS[@]}"; do
    IFS='|' read -r rel repo exp sub desc <<< "${spec}"
    rm -rf "${DEST:?}/${sub}"
  done
  mkdir -p "${DEST}"
  ( cd "${STAGE}" && tar -cf - . ) | ( cd "${DEST}" && tar -xf - )
  echo ""
  echo "已重建 ${DEST}：${n_total} 个 Chisel 文件 + ${MANIFEST_NAME}"
  find "${DEST}" -name '*.scala' | sed "s@${REPO_ROOT}/@  @" | sort
  echo "RTL-SYNC: DONE"
  exit 0
fi

# --check
echo ""
echo "--- 交付副本一致性自检 ---"
n_same=0
while IFS= read -r f; do
  relf="${f#${STAGE}/}"
  if [ ! -f "${DEST}/${relf}" ]; then
    fail "交付副本缺失 rtl/chisel/${relf}"
  elif ! cmp -s "${f}" "${DEST}/${relf}"; then
    fail "内容不一致 rtl/chisel/${relf}"
  else
    n_same=$((n_same+1))
  fi
done < <(find "${STAGE}" -type f | sort)

# 反向：交付目录里不应有补丁之外的多余 Chisel 文件
while IFS= read -r f; do
  relf="${f#${DEST}/}"
  [ -f "${STAGE}/${relf}" ] || fail "交付副本多出 rtl/chisel/${relf}（补丁里没有）"
done < <(find "${DEST}" -type f \( -name '*.scala' -o -name "${MANIFEST_NAME}" \) | sort)

echo "  逐字节相同 ${n_same} 个文件（含 ${MANIFEST_NAME}）"
if [ "${RC}" -eq 0 ]; then
  echo "RTL-SYNC-CHECK: PASS"
else
  echo "RTL-SYNC-CHECK: FAIL  —— 请运行 bash scripts/tools/sync_rtl_sources.sh 重建"
fi
exit ${RC}
