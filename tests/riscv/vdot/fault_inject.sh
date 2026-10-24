#!/usr/bin/env bash
# =============================================================================
# fault_inject.sh —— 故障注入自测：证明 tests/riscv/vdot 的比对确实在起作用
#
# "30663 条全 PASS" 本身不能证明测试有效 —— 也可能是比对逻辑形同虚设。
# 本脚本把 NEMU 的 vdot 实现（work/NEMU/src/isa/riscv64/instr/rvv/vdot.c）
# 人为改坏若干处，每次重新编译 NEMU 并重跑完整语料，要求**每一次都必须 FAIL**。
# 跑完后把源码还原并重新编译，恢复到干净状态。
#
# 必须在 xsdev 容器内执行（需要 gcc 与 riscv64-linux-gnu-gcc）。
#   NEMU_HOME=/work/work/NEMU bash /work/tests/riscv/vdot/fault_inject.sh
# =============================================================================
set -uo pipefail

NEMU_HOME="${NEMU_HOME:-/work/work/NEMU}"
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
    if echo "${out}" | grep -q '^RESULT: FAIL'; then
        echo "  => 被检出 OK"
        DETECTED=$((DETECTED + 1))
    else
        echo "  => **未被检出**（nemu 退出码 ${rc}）"
        MISSED=$((MISSED + 1))
    fi
}

DETECTED=0
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
TOTAL=$((TOTAL + 1))
run_inject 5 "[破坏裁定 S-9：vstart 超出当前 SEW 最大元素下标时不再报错]" '
import sys
p = sys.argv[1]; s = open(p).read()
old = "  if (vstart->val + 1 > (uint64_t)get_vlen_max(vtype->vsew, vtype->vlmul, 0)) {\n    longjmp_exception(EX_II);\n  }"
new = "  /* FAULT #5: S-9 的 vstart 越界检查被删除 */"
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
