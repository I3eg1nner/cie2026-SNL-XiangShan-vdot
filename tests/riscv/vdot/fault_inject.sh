#!/usr/bin/env bash
# =============================================================================
# fault_inject.sh —— 故障注入自测：证明 tests/riscv/vdot 的比对确实在起作用
#
# "全部用例 PASS" 本身不能证明测试有效 —— 也可能是比对逻辑形同虚设。
# 本脚本把 NEMU 的 vdot 实现（${NEMU_HOME}/src/isa/riscv64/instr/rvv/vdot.c）
# 人为改坏若干处，每次重新编译 NEMU 并重跑完整语料，要求**每一次都必须 FAIL**。
# 跑完后把源码还原并重新编译，恢复到干净状态。
#
# 由 scripts/21_build_nemu_vdot.sh 调用（Linux 宿主机或 xsdev 容器，需要 gcc），须先 make。
#   NEMU_HOME=<work>/NEMU bash tests/riscv/vdot/fault_inject.sh
# =============================================================================
set -uo pipefail

NEMU_HOME="${NEMU_HOME:?请设置 NEMU_HOME=<work>/NEMU}"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VDOT_C="${NEMU_HOME}/src/isa/riscv64/instr/rvv/vdot.c"
BACKUP="$(mktemp)"
NEMU_BIN="${NEMU_HOME}/build/riscv64-nemu-interpreter"
IMG="${TEST_DIR}/build/vdot_test.bin"

cp "${VDOT_C}" "${BACKUP}"

restore() {
    cp "${BACKUP}" "${VDOT_C}"
}
trap 'restore' EXIT

rebuild() {
    make -C "${NEMU_HOME}" -j"$(nproc)" >/dev/null 2>&1
}

# inject <编号> <描述> <python 替换脚本>
#   python 脚本从 stdin 拿不到参数，直接写死 old/new；必须断言命中 1 次，
#   否则说明源码已变、注入失效，脚本立即报错退出（不允许"假装注入成功"）。
run_inject() {
    local id="$1" desc="$2" pyscript="$3"
    echo
    echo "=============================================================="
    echo "inject #${id}  ${desc}"
    echo "=============================================================="
    restore
    if ! python3 -c "${pyscript}" "${VDOT_C}"; then
        echo "  !! 注入失败：源码中找不到目标代码片段"
        FAILED_SETUP=$((FAILED_SETUP + 1))
        return
    fi
    echo "--- 改动（与干净版本的 diff）---"
    diff -u "${BACKUP}" "${VDOT_C}" | sed -n '/^@@/,$p' | head -30
    echo "--- 重新编译 NEMU ---"
    if ! rebuild; then
        echo "  !! 编译失败"
        FAILED_SETUP=$((FAILED_SETUP + 1))
        return
    fi
    echo "--- 重跑全部语料 ---"
    local out rc
    out="$("${NEMU_BIN}" -b --log=/dev/null "${IMG}" 2>&1)"
    rc=$?
    echo "${out}" | grep -E '^(TOTAL|  must-trap|  missing-trap|RESULT)' || true
    echo "${out}" | grep -c '^FAIL #' | sed 's/^/打印出的失败用例条数（上限 20）: /'
    if [ "${EQUIV_ID:-}" = "${id}" ]; then
        # 等价变异体：按设计不可观测，单独计数，不计入检出率
        if echo "${out}" | grep -q '^RESULT: FAIL'; then
            echo "  => 被检出（预期为等价变异体却被检出 —— 说明分析有误，计为异常）"
            MISSED=$((MISSED + 1))
        else
            echo "  => 未被检出，符合预期：这是等价变异体（见上方说明），不计入检出率"
            EQUIV=$((EQUIV + 1))
        fi
    elif echo "${out}" | grep -q '^RESULT: FAIL'; then
        echo "  => 被检出 OK"
        DETECTED=$((DETECTED + 1))
    else
        echo "  => **未被检出**（nemu 退出码 ${rc}）"
        MISSED=$((MISSED + 1))
    fi
}

DETECTED=0
EQUIV=0
MISSED=0
FAILED_SETUP=0
TOTAL=0

echo "=============================================================="
echo " cie2026-vdot / P5-T3  NEMU vdot 故障注入自测"
echo " $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
echo "=============================================================="
echo "被改坏的文件 : ${VDOT_C}"
echo "测试镜像     : ${IMG}"
echo "NEMU 解释器  : ${NEMU_BIN}"
test -f "${IMG}" || { echo "ERROR: 测试镜像不存在，请先 make"; exit 1; }

# ---- #1 丢掉 int8 的符号扩展（改成零扩展） ----
TOTAL=$((TOTAL + 1))
run_inject 1 "[丢掉源操作数的符号扩展：SIGNED -> UNSIGNED]" '
import sys
p = sys.argv[1]; s = open(p).read()
old = "  get_vreg(reg, idx, tmp, VDOT_SRC_VSEW, vtype->vlmul, SIGNED, 0);\n  rtl_sext(s, tmp, tmp, 1 << VDOT_SRC_VSEW);"
new = "  get_vreg(reg, idx, tmp, VDOT_SRC_VSEW, vtype->vlmul, UNSIGNED, 0);  /* FAULT #1 */"
assert s.count(old) == 1, "pattern not found"
open(p, "w").write(s.replace(old, new))
'

# ---- #2 归约主循环 vl 差一（漏掉最后一个元素） ----
TOTAL=$((TOTAL + 1))
run_inject 2 "[vl 差一：归约主循环少算最后一个元素]" '
import sys
p = sys.argv[1]; s = open(p).read()
old = "  for (word_t idx = vstart->val; idx < vl->val; idx++) {\n    rtlreg_t mask = get_mask(0, idx);\n    if (s->vm == 0 && mask == 0) {\n      continue;\n    }"
new = "  for (word_t idx = vstart->val; idx + 1 < vl->val; idx++) {  /* FAULT #2 */\n    rtlreg_t mask = get_mask(0, idx);\n    if (s->vm == 0 && mask == 0) {\n      continue;\n    }"
assert s.count(old) == 1, "pattern not found"
open(p, "w").write(s.replace(old, new))
'

# ---- #3 忽略掩码（vm=0 时也把全部元素算进去 / vdot4a 不做 vma 处理） ----
TOTAL=$((TOTAL + 1))
run_inject 3 "[忽略掩码：vm=0 时不再排除 inactive 元素]" '
import sys
p = sys.argv[1]; s = open(p).read()
old1 = "    rtlreg_t mask = get_mask(0, idx);\n    if (s->vm == 0 && mask == 0) {\n      continue;\n    }"
new1 = "    /* FAULT #3: 掩码被忽略 */"
old2 = "    rtlreg_t mask = get_mask(0, idx);\n    if (s->vm == 0 && mask == 0) {\n      if (RVV_AGNOSTIC && vtype->vma) {"
new2 = "    rtlreg_t mask = get_mask(0, idx);\n    if (0 && s->vm == 0 && mask == 0) {  /* FAULT #3: 掩码被忽略 */\n      if (RVV_AGNOSTIC && vtype->vma) {"
assert s.count(old1) == 1 and s.count(old2) == 1, "pattern not found"
open(p, "w").write(s.replace(old1, new1).replace(old2, new2))
'

# ---- #4 去掉 S-1 的 vstart!=0 非法指令检查 ----
TOTAL=$((TOTAL + 1))
run_inject 4 "[破坏裁定 S-1：归约形态不再对 vstart!=0 抛 Illegal Instruction]" '
import sys
p = sys.argv[1]; s = open(p).read()
old = "  check_vstart_exception(s);\n  if (check_vstart_ignore(s)) {"
new = "  /* FAULT #4: check_vstart_exception(s) 被删除 */\n  if (check_vstart_ignore(s)) {"
assert s.count(old) == 1, "pattern not found"
open(p, "w").write(s.replace(old, new))
'

# ---- #5 去掉 S-9 的 vstart 越界检查 ----
# 裁定 S-7' 之后这是一个**等价变异体**：三条指令都会在 vdot_check() 之后调用
# check_vstart_exception()，而 vstart 越界（>= VLMAX）必然意味着 vstart != 0，
# 于是删掉 S-9 的检查后，这些用例仍然以同样的 mcause=2 trap —— 架构上不可观测。
# S-7' 之前它是可检出的（vdot4a 的 vstart ∈ [4,15] 只能由 S-9 拦下）。
# 这里照跑，用来**实测确认**它确实变成了等价变异体，但不计入检出率。
# S-9 与 S-1/S-7' 在参考模型里仍是不同的状态码（ERR_VSTART_RANGE / ILLEGAL_VSTART），
# 其区分由 tests/golden/test_golden 的回环比对（比对 status 字段）守住。
EQUIV_ID=5
run_inject 5 "[破坏裁定 S-9：vstart 超出当前 SEW 最大元素下标时不再报错]" '
import sys
p = sys.argv[1]; s = open(p).read()
old = "  if (vstart->val + 1 > (uint64_t)get_vlen_max(vtype->vsew, vtype->vlmul, 0)) {\n    longjmp_exception(EX_II);\n  }"
new = "  /* FAULT #5: S-9 的 vstart 越界检查被删除 */"
assert s.count(old) == 1, "pattern not found"
open(p, "w").write(s.replace(old, new))
'

# ---- #6 去掉 S-7' 的 vdot4a vstart!=0 非法指令检查（回退到原裁定 S-7）----
TOTAL=$((TOTAL + 1))
run_inject 6 "[回退裁定 S-7'：vdot4a 不再对 vstart!=0 抛 Illegal Instruction]" '
import sys
p = sys.argv[1]; s = open(p).read()
old = "  check_vstart_exception(s);   // 裁定 S-7\x27"
new = "  /* FAULT #6: S-7 check removed */ //"
assert s.count(old) == 1, "pattern not found"
open(p, "w").write(s.replace(old, new))
'

# ---- #7 回退裁定 S-3'：归约形态元素 1..3 不再无条件清零，改回旧 S-3（按 vta 处理）----
TOTAL=$((TOTAL + 1))
run_inject 7 "[回退裁定 S-3'：vdot/vdotacc 元素 1..3 改回按 vta 处理（vta=1 写全 1，vta=0 保持）]" '
import sys
p = sys.argv[1]; s = open(p).read()
old = "    for (int idx = 1; idx < vlmax_d; idx++) {\n      set_vreg(id_dest->reg, idx, 0, VDOT_DEST_VSEW, vtype->vlmul, 0);\n    }"
new = "    (void)vlmax_d;  /* FAULT #7 */\n    if (RVV_AGNOSTIC && vtype->vta) set_vreg_tail(id_dest->reg);"
assert s.count(old) == 1, "pattern not found"
open(p, "w").write(s.replace(old, new))
'

# ---- 还原并重新编译，确认回到干净状态 ----
echo
echo "=============================================================="
echo " 还原 vdot.c 并重新编译，确认回到全 PASS"
echo "=============================================================="
restore
diff -u "${BACKUP}" "${VDOT_C}" | sed 's/^/  /'
echo "  （上面没有 diff 输出即表示源码已完全还原）"
rebuild || { echo "ERROR: 还原后编译失败"; exit 1; }
CLEAN_OUT="$("${NEMU_BIN}" -b --log=/dev/null "${IMG}" 2>&1)"
echo "${CLEAN_OUT}" | grep -E '^(TOTAL|  must-trap|  missing-trap|RESULT)'

echo
echo "=============================================================="
echo "等价变异体（按设计不可观测，未计入）: ${EQUIV} 个（#5，S-7' 之后 S-9 被 S-1/S-7' 覆盖）"
printf 'FAULT-INJECTION: %d/%d 被检出' "${DETECTED}" "${TOTAL}"
if [ "${MISSED}" -ne 0 ] || [ "${FAILED_SETUP}" -ne 0 ]; then
    printf '  (漏检 %d, 注入/编译失败 %d)\n' "${MISSED}" "${FAILED_SETUP}"
    echo "FAULT-INJECTION: FAIL"
    echo "=============================================================="
    exit 1
fi
printf '\n'
if echo "${CLEAN_OUT}" | grep -q '^RESULT: PASS'; then
    echo "还原后复测: PASS"
    echo "FAULT-INJECTION: PASS"
    echo "=============================================================="
    exit 0
fi
echo "还原后复测: FAIL（异常，请检查）"
echo "FAULT-INJECTION: FAIL"
echo "=============================================================="
exit 1
