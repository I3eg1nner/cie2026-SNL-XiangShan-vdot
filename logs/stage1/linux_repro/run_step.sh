#!/usr/bin/env bash
# 用法：run_step.sh <日志名> <脚本相对路径>
# 用 script -q 在伪终端中记录完整终端输出，前后附时间戳、命令行、rc 与耗时
set -u
name="$1"; shift
R=/data/my/cie-stage1-repro
export WORK_DIR=$R/work LOG_ROOT=$R/logs RESULTS_DIR=$R/results FIG_DIR=$R/figures LOCAL_SYSROOT=1
cmd="cd /data/my/cie2026-vdot-xiangshan && bash $*"
out="$R/term/${name}.log"
mkdir -p "$R/term"
t0=$(date +%s)
{
  echo "### 开始时间 : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "### 主机     : $(hostname) / $(uname -srm)"
  echo "### 环境变量 : WORK_DIR=$WORK_DIR LOG_ROOT=$LOG_ROOT RESULTS_DIR=$RESULTS_DIR FIG_DIR=$FIG_DIR LOCAL_SYSROOT=$LOCAL_SYSROOT"
  echo "### 交付仓库 : $(git -C /data/my/cie2026-vdot-xiangshan rev-parse HEAD)"
  echo "### 命令行   : script -q -e -c \"$cmd\" <本文件>"
  echo "### ---------------- 以下为 script 记录的终端原始输出 ----------------"
} > "$out"
script -q -e -a -c "$cmd" "$out"
rc=$?
t1=$(date +%s)
{
  echo
  echo "### ---------------- 终端输出结束 ----------------"
  echo "### 结束时间 : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "### rc       : $rc"
  echo "### 耗时     : $((t1-t0)) s"
} >> "$out"
echo "$name rc=$rc elapsed=$((t1-t0))s" >> "$R/term/summary.txt"
exit $rc
