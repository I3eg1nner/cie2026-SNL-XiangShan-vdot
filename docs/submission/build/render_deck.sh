#!/usr/bin/env bash
# 生成讲解 PPT 并导出 PDF：
#   docs/ppt/讲解大纲.md --build_deck.py--> docs/submission/SNL-XiangShan-vdot-slides.pptx
#   --soffice --headless--> submission/upload/SNL-XiangShan-vdot-slides.pdf
#   PAGES=1 时另用 pdftoppm 把每页转成 PNG（$PNGDIR，默认 /tmp/deck-pages/），供逐页目视检查。
# 依赖：python3 + python-pptx + Pillow（PYTHON=… 指定解释器）、LibreOffice（SOFFICE=…）、poppler-utils（pdfinfo/pdftoppm）、
#       字体 WenQuanYi Zen Hei（fc-list :lang=zh）。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
PYTHON=${PYTHON:-python3}
SOFFICE=${SOFFICE:-soffice}
OUTDIR=${OUTDIR:-$ROOT/submission/upload}
PNGDIR=${PNGDIR:-/tmp/deck-pages}
NAME=SNL-XiangShan-vdot-slides
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

fc-list :lang=zh family | grep -q "WenQuanYi Zen Hei" || { echo "font WenQuanYi Zen Hei not installed" >&2; exit 1; }
"$PYTHON" -I "$HERE/build_deck.py"
mkdir -p "$OUTDIR"
"$SOFFICE" -env:UserInstallation="file://$TMP/lo-profile" --headless --convert-to pdf \
  --outdir "$TMP" "$ROOT/docs/submission/$NAME.pptx" > /dev/null
mv "$TMP/$NAME.pdf" "$OUTDIR/$NAME.pdf"
pages=$(pdfinfo "$OUTDIR/$NAME.pdf" | awk '/^Pages:/{print $2}')
printf '%-36s %3s 页  %9s B\n' "$NAME.pdf" "$pages" "$(wc -c < "$OUTDIR/$NAME.pdf" | tr -d ' ')"
# 字体核对：PDF 里只应出现 WenQuanYi 字体（出现其他 CJK 字体说明发生了字体替换）
if pdffonts "$OUTDIR/$NAME.pdf" | awk 'NR>2{print $1}' | grep -v -i wenquanyi | grep -q .; then
  echo "warn: non-WenQuanYi fonts embedded:" >&2; pdffonts "$OUTDIR/$NAME.pdf" | awk 'NR>2{print $1}' | sort -u >&2
fi
if [ -n "${PAGES:-}" ]; then
  rm -rf "$PNGDIR"; mkdir -p "$PNGDIR"
  pdftoppm -r 80 -png "$OUTDIR/$NAME.pdf" "$PNGDIR/p"
  echo "pages rendered to $PNGDIR"
fi
