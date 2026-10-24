/*
 * vdot_cli.c —— 参考模型的批处理命令行外壳
 *
 * 存在的唯一理由：让 tests/vectors/gen_vectors.py 能够**调用 C 参考模型**
 * 来计算期望值，而不是在 Python 里重写一遍语义。
 * 这样整个项目里 vdot 的语义只有 vdot_ref.c 一份实现。
 *
 * 用法：  vdot_cli < 请求流 > 响应流
 *   请求每行（空白分隔，以 '#' 开头的行与空行原样跳过）：
 *     op vsew vstart vl vm vta vma vs1_hex vs2_hex vd_in_hex v0_hex policy
 *       op     : vdot | vdotacc | vdot4a
 *       vsew   : 8 | 16 | 32 | 64（元素位宽）
 *       vm     : 1 = 指令 vm 位为 1（不使用掩码）；0 = 使用 v0 掩码
 *       policy : strict | skip
 *       *_hex  : 32 个十六进制字符，v[0] 在最左
 *   响应每行：
 *     vd_out_hex status_name
 */
#include <stdio.h>
#include <string.h>
#include "vdot_ref.h"

#define LINEMAX 1024

int main(void)
{
    char line[LINEMAX];
    char op_s[32], pol_s[32];
    char h1[64], h2[64], hd[64], h0[64];
    unsigned vsew, vstart, vl, vm, vta, vma;
    long lineno = 0;

    while (fgets(line, sizeof(line), stdin)) {
        vreg128_t vs1, vs2, vd, v0;
        char out[33];
        int st, op, policy;
        const char *p = line;

        lineno++;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\r' || *p == '\0') continue;

        if (sscanf(line, "%31s %u %u %u %u %u %u %63s %63s %63s %63s %31s",
                   op_s, &vsew, &vstart, &vl, &vm, &vta, &vma,
                   h1, h2, hd, h0, pol_s) != 12) {
            fprintf(stderr, "vdot_cli: malformed request at line %ld\n", lineno);
            return 2;
        }

        op = vdot_op_from_name(op_s);
        if (op < 0) {
            fprintf(stderr, "vdot_cli: unknown op '%s' at line %ld\n", op_s, lineno);
            return 2;
        }
        if      (strcmp(pol_s, "strict") == 0) policy = VDOT_VSTART_STRICT;
        else if (strcmp(pol_s, "skip")   == 0) policy = VDOT_VSTART_SKIP;
        else {
            fprintf(stderr, "vdot_cli: unknown policy '%s' at line %ld\n", pol_s, lineno);
            return 2;
        }
        if (vdot_hex_parse(h1, &vs1) || vdot_hex_parse(h2, &vs2) ||
            vdot_hex_parse(hd, &vd)  || vdot_hex_parse(h0, &v0)) {
            fprintf(stderr, "vdot_cli: bad hex operand at line %ld\n", lineno);
            return 2;
        }

        st = vdot_exec(op, (int)vsew, &vd, &vs2, &vs1,
                       vstart, vl, vm ? NULL : &v0,
                       (int)vta, (int)vma, policy);
        vdot_hex_format(&vd, out);
        printf("%s %s\n", out, vdot_status_name(st));
    }
    return 0;
}
