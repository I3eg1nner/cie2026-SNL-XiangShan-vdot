#!/usr/bin/env bash
# 生成技术文档三册（独立 PDF，按赛题三阶段分册），写到 OUTDIR（默认 submission/upload/）：
#   SNL-XiangShan-vdot-vol1-stage1.pdf  第一册 阶段一：环境部署与 vadd.vv 执行过程分析（docs/stage1/*.md）
#   SNL-XiangShan-vdot-vol2-stage2.pdf  第二册 阶段二：vdot 指令设计、RTL 实现与基础功能测试（docs/stage2/*.md）
#   SNL-XiangShan-vdot-vol3-stage3.pdf  第三册 阶段三：NEMU 扩展、协同仿真与延迟加速比分析（docs/stage3/*.md）
# 流程：docs/stageN/*.md -> pdf/assemble.py（按文件顺序拼接、图片路径改为绝对路径）
#       -> pandoc gfm -> HTML（pdf/template.html 封面 + pdf/style.css 中文字体 / A4 / 页码，pdf/links.lua 把仓库内相对链接改成纯文本）
#       -> WeasyPrint 输出 PDF（封面、带页码的目录、页码、书签）。
# md 文件是唯一来源；本脚本只做拼接与排版，数值不改。
# 依赖：pandoc ≥ 3、python3、WeasyPrint（PYTHON=… 指定装有 weasyprint 的解释器）、pdfinfo（poppler-utils）、字体 WenQuanYi Zen Hei。
# 用法：bash submission/upload/build-pdf.sh            （KEEP_HTML=1 留下中间 HTML；VOLS="2 3" 只做部分册）
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
PROJECT_NAME=${PROJECT_NAME:-XiangShan-vdot：在香山昆明湖 V2 上新增 RISC-V 自定义 vdot 指令族}
TEAM_NAME=${TEAM_NAME:-SNL}
WORK_NAME=${WORK_NAME:-XiangShan-vdot}
REPO_URL=${REPO_URL:-https://github.com/I3eg1nner/cie2026-SNL-XiangShan-vdot}
DATE=${DATE:-$(date +%Y-%m-%d)}
OUTDIR=${OUTDIR:-$HERE}
PYTHON=${PYTHON:-python3}
VOLS=${VOLS:-1 2 3}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
"$PYTHON" -c "import weasyprint" 2>/dev/null || { echo "weasyprint not importable with $PYTHON (set PYTHON=…)" >&2; exit 1; }
fc-list :lang=zh family | grep -q "WenQuanYi Zen Hei" || { echo "font WenQuanYi Zen Hei not installed" >&2; exit 1; }

for v in $VOLS; do
  name="SNL-XiangShan-vdot-vol$v-stage$v"
  meta=$(python3 -I "$HERE/pdf/assemble.py" "$ROOT" "$v" "$TMP/vol$v.md")
  get() { printf '%s\n' "$meta" | sed -n "s/^$1=//p"; }
  pandoc "$TMP/vol$v.md" -f gfm+pipe_tables -t html5 -s \
    --template "$HERE/pdf/template.html" --css "$HERE/pdf/style.css" \
    --toc --toc-depth=2 --section-divs \
    --lua-filter "$HERE/pdf/links.lua" \
    -M pagetitle="$(get volno) $(get voltitle)（$WORK_NAME）" \
    -V project="$PROJECT_NAME" -V team="$TEAM_NAME" -V work="$WORK_NAME" -V repo="$REPO_URL" -V date="$DATE" \
    -V volno="$(get volno)" -V voltitle="$(get voltitle)" -V scope="$(get scope)" -V contents="$(get contents)" \
    -o "$TMP/vol$v.html"
  "$PYTHON" -I -c 'import sys, weasyprint; weasyprint.HTML(sys.argv[1]).write_pdf(sys.argv[2])' \
    "$TMP/vol$v.html" "$OUTDIR/$name.pdf" 2> "$TMP/weasy$v.log" || { cat "$TMP/weasy$v.log" >&2; exit 1; }
  [ -n "${KEEP_HTML:-}" ] && cp "$TMP/vol$v.html" "$OUTDIR/$name.html"
  pages=$(pdfinfo "$OUTDIR/$name.pdf" | awk '/^Pages:/{print $2}')
  printf '%-36s %4s 页  %10s B  %s %s\n' "$name.pdf" "$pages" "$(wc -c < "$OUTDIR/$name.pdf" | tr -d ' ')" "$(get volno)" "$(get voltitle)"
done
