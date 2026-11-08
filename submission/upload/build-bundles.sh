#!/usr/bin/env bash
# 生成四个上传包（文件名 ASCII，各 < 500 MB）及 提交清单.md、SHA256SUMS、bundle-contents.tsv：
#   SNL-XiangShan-vdot-1-source.zip    源码、脚本与文档 Markdown（git archive HEAD 去掉 logs/、mp4、pptx 与清单）
#   SNL-XiangShan-vdot-2-evidence.zip  logs/、bench/results/、docs/stage*/figures/（与①同根目录，解压到一处即完整仓库）
#   SNL-XiangShan-vdot-3-docs.zip      三册 PDF + 讲解 PPT（pptx 取自 HEAD，PDF 为已生成成品）
#   SNL-XiangShan-vdot-4-video.zip     三段 mp4 + srt（视频一/二与字幕取自 HEAD，视频三为生成物），不压缩
# 前提：按「三册 PDF → PPT / 视频 → 四个包」的顺序，先跑 build-pdf.sh、render_deck.sh（视频见 demo/video/storyboard.md），
#       并把文档改动提交到仓库（①②只取 HEAD，未提交的改动不入包）。本脚本不重建 PDF / PPT / 视频。
# 用法：bash submission/upload/build-bundles.sh             正式生成，写入 submission/upload/
#       bash submission/upload/build-bundles.sh --dry-run   试运行：在临时目录完整打包并核验，不改动 submission/upload/
# 依赖：git、python3、pdfinfo、unzip、sha256sum；可选 FFMPEG=<ffmpeg 路径>（清单里的视频时长与参数）。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
DRY=""; [ "${1:-}" = "--dry-run" ] && DRY=1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
if [ -z "${FFMPEG:-}" ]; then
  FFMPEG=$(command -v ffmpeg || /tmp/videoenv/bin/python -c 'import imageio_ffmpeg as m; print(m.get_ffmpeg_exe())' 2>/dev/null || true)
fi
export FFMPEG

for f in SNL-XiangShan-vdot-vol1-stage1.pdf SNL-XiangShan-vdot-vol2-stage2.pdf SNL-XiangShan-vdot-vol3-stage3.pdf SNL-XiangShan-vdot-slides.pdf; do
  [ -s "$HERE/$f" ] || { echo "missing $HERE/$f (run build-pdf.sh / render_deck.sh first)" >&2; exit 1; }
done
[ -s "$ROOT/demo/video/SNL-XiangShan-vdot-video3-stage3.mp4" ] || { echo "missing video3 mp4 (see demo/video/storyboard.md)" >&2; exit 1; }
[ -z "$(git -C "$ROOT" status --porcelain -- docs README.md demo/video logs bench)" ] || echo "warn: uncommitted changes under docs/README/demo/logs/bench are NOT in the bundles" >&2

# 内容提交号：最后一次改动「清单类文件以外」内容的提交。只改清单的提交不改变它，重打包得到相同的包。
SELF=(':!submission/upload/提交清单.md' ':!submission/upload/SHA256SUMS' ':!submission/upload/bundle-contents.tsv')
SRC_ID=$(git -C "$ROOT" log -1 --format=%h -- . "${SELF[@]}")
SRC_TIME=$(git -C "$ROOT" log -1 --format=%ct "$SRC_ID")
mkdir -p "$TMP/src"
git -C "$ROOT" archive --format=tar HEAD | tar -x -C "$TMP/src"

OUT="$HERE"; [ -n "$DRY" ] && { OUT="$TMP/out"; mkdir -p "$OUT"; }
python3 -I "$HERE/pdf/bundles.py" "$TMP/src" "$HERE" "$SRC_ID" "$SRC_TIME" "$OUT"

# 核验：四个包都能完整解开；①②包内逐文件 sha256 通过；①②合并后与 HEAD 快照逐文件一致（清单类文件除外）
P=SNL-XiangShan-vdot
for b in 1-source 2-evidence 3-docs 4-video; do unzip -tq "$OUT/$P-$b.zip" > /dev/null; done
mkdir -p "$TMP/x"
unzip -q "$OUT/$P-1-source.zip" -d "$TMP/x"; unzip -qo "$OUT/$P-2-evidence.zip" -d "$TMP/x"
(cd "$TMP/x/$P" && sha256sum -c --quiet SHA256SUMS-source && sha256sum -c --quiet SHA256SUMS-evidence)
missing=$(cd "$TMP/src" && git -C "$ROOT" -c core.quotepath=off ls-files -- . "${SELF[@]}" | grep -v -E '^(demo/video/.*\.mp4|docs/submission/.*\.pptx)$' \
          | while IFS= read -r f; do cmp -s "$TMP/src/$f" "$TMP/x/$P/$f" || echo "$f"; done)
[ -z "$missing" ] || { echo "files of HEAD missing/different in ①+②:" >&2; echo "$missing" >&2; exit 1; }
echo "bundles ①+② = HEAD snapshot ($SRC_ID); per-file SHA256SUMS ok"
[ -n "$DRY" ] && for f in "$HERE"/*.pdf; do ln -sf "$f" "$OUT/"; done
(cd "$OUT" && sha256sum -c --quiet SHA256SUMS) && echo "SHA256SUMS ok"
if [ -n "$DRY" ]; then
  ls -l "$OUT"; echo "dry run: nothing written to $HERE"
else
  cat "$OUT/SHA256SUMS"
fi
