#!/bin/sh
# ==========================================================================
# fault_inject.sh —— 自检有效性验证（故障注入）
#
# 差分测试全 PASS 本身不能证明"测试有效"，也可能是比对逻辑形同虚设。
# 本脚本把参考模型 / 基线仿真**人为改坏**三处，重新编译并重跑自检，
# 要求每一次都必须 FAIL。只有三次全部 FAIL，才说明自检确实在比对。
#
# 用法： sh fault_inject.sh
# 退出码：0 = 三次注入全部被检出；1 = 有漏检（自检失效）
# ==========================================================================
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CC=${CC:-cc}
CFLAGS="-std=c11 -O2 -w"
VEC="$ROOT/tests/vectors/positive.txt $ROOT/tests/vectors/negative.txt \
     $ROOT/tests/vectors/boundary.txt $ROOT/tests/vectors/random.txt \
     $ROOT/tests/vectors/vdotacc_random.txt $ROOT/tests/vectors/vdot4a_random.txt"

rc=0
for M in 1 2 3; do
    TMP=$(mktemp -d)
    mkdir -p "$TMP/bench/baseline" "$TMP/tests/golden"
    cp "$HERE/vdot_ref.c" "$HERE/vdot_ref.h" "$HERE/test_golden.c" "$TMP/tests/golden/"
    cp "$ROOT/bench/baseline/baseline_ref.c" "$ROOT/bench/baseline/baseline_ref.h" \
       "$TMP/bench/baseline/"
    case $M in
      1) DESC="参考模型：int8 改为零扩展（丢掉符号）"
         sed -i.bak 's|return (int32_t)(b ^ 0x80u) - 128;|return (int32_t)b;|' \
             "$TMP/tests/golden/vdot_ref.h" ;;
      2) DESC="参考模型：vdot/vdotacc 元素 1..3 写全 1 而不是清零（退回旧 S-3 的 vta=1 行为）"
         sed -i.bak 's|for (i = 1; i < VDOT_VLEN / 32; i++) vreg_set_u32(vd, (int)i, 0u);|for (i = 1; i < VDOT_VLEN / 32; i++) vreg_set_u32(vd, (int)i, 0xFFFFFFFFu);|' \
             "$TMP/tests/golden/vdot_ref.c" ;;
      3) DESC="基线仿真：vwredsum.vs 丢掉标量初值（vs1[0]）"
         sed -i.bak 's|sum = vrf_get(s, vs1, dew, 0);|sum = 0;|' \
             "$TMP/bench/baseline/baseline_ref.c" ;;
    esac
    $CC $CFLAGS "$TMP/tests/golden/test_golden.c" "$TMP/tests/golden/vdot_ref.c" \
        "$TMP/bench/baseline/baseline_ref.c" -o "$TMP/tg" 2>/dev/null
    if [ ! -x "$TMP/tg" ]; then
        echo "  inject #$M [$DESC]: BUILD ERROR -> 视为漏检"
        rc=1; rm -rf "$TMP"; continue
    fi
    out=$("$TMP/tg" $VEC 2>&1); st=$?
    nfail=$(printf '%s\n' "$out" | grep -c '  FAIL')
    if [ $st -ne 0 ]; then
        echo "  inject #$M [$DESC]: 被检出 (exit=$st, 失配行数>=$nfail)  OK"
    else
        echo "  inject #$M [$DESC]: 未被检出 (exit=0)  <<< 自检失效"
        rc=1
    fi
    rm -rf "$TMP"
done
if [ $rc -eq 0 ]; then echo "FAULT-INJECTION: PASS (3/3 被检出)";
else echo "FAULT-INJECTION: FAIL"; fi
exit $rc
