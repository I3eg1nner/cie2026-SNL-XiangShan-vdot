#!/usr/bin/env bash
# =============================================================================
# mill_state_guard.sh —— 修复 mill 增量编译状态与磁盘实际内容不一致的情况
#
# 现象：某些系统清理工具会把 out/**/compile.dest/classes 目录整个删掉，而
# mill/zinc 的 compile.json 仍然记录「已编译」，于是 mill 报
#   java.lang.ClassNotFoundException: millbuild.build$          （mill 0.11）
#   java.lang.ClassNotFoundException: build_.package_$          （mill 0.12）
#   java.lang.NoClassDefFoundError: yunsuan/vector/VectorFloatAdder
# 本脚本检查每个 compile.dest 是否真的有 classes 目录，没有就把对应的
# compile.dest / compile.json 删掉，强制 mill 重新编译。幂等。
#
# 用法： bash scripts/tools/mill_state_guard.sh <mill 工程根目录> [更多目录...]
# =============================================================================
set -uo pipefail
for root in "$@"; do
  [ -d "${root}/out" ] || continue
  n=0
  while IFS= read -r d; do
    if [ ! -d "${d}/classes" ]; then
      rm -rf "${d}" "${d%.dest}.json"
      n=$((n+1))
    fi
  done < <(find "${root}/out" -maxdepth 4 -name "compile.dest" -type d)
  echo "[mill-state-guard] ${root}: 清理了 ${n} 个失效的增量编译状态"
done
