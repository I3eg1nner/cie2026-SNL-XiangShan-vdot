/*
 * test_golden.c —— 宿主端自检（macOS/arm64 与 Linux/arm64 均可直接运行）
 *
 * 三项检查：
 *   [1] 回环检查：把 tests/vectors 下每一条用例重新喂给 C 参考模型，
 *       确认文件里记录的 vd_expected / status 与模型现算结果逐位一致。
 *       —— 证明测试向量确实由参考模型生成，没有被手工篡改。
 *   [2] 差分检查：对同一批用例再跑一遍 bench/baseline/baseline_ref.c 中
 *       **独立编写**的 RVV 1.0 基线序列仿真，比对两者结果。
 *       —— 两份独立实现在 10000 组随机激励上一致，才是真正的正确性证据。
 *   [3] 长向量循环等价：基线 L-D 循环、vdotacc 循环、vdot4a 循环、
 *       以及朴素标量点积，四者在多种 N 下结果一致。
 *
 * 退出码：0 = 全部通过；1 = 有失败；2 = 用法/IO 错误。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "vdot_ref.h"
#include "../../bench/baseline/baseline_ref.h"

#define LINEMAX 2048

static const char *k_expect_fields =
  "# fields: op vsew vstart vl vm vta vma vs1_hex(32) vs2_hex(32) "
  "vd_in_hex(32) vd_expected_hex(32) v0_hex(32) status";

typedef struct {
    long total, roundtrip_fail, diff_checked, diff_fail, diff_skipped;
} stat_t;

static int vreg_eq(const vreg128_t *a, const vreg128_t *b)
{
    int i;
    for (i = 0; i < VDOT_VLENB; i++) if (a->v[i] != b->v[i]) return 0;
    return 1;
}

static void dump_case(const char *file, long lineno, const char *what,
                      const vreg128_t *got, const vreg128_t *want,
                      int got_st, int want_st)
{
    char g[33], w[33];
    vdot_hex_format(got, g);
    vdot_hex_format(want, w);
    printf("  FAIL %s %s:%ld\n", what, file, lineno);
    printf("       got  vd=%s status=%s\n", g, vdot_status_name(got_st));
    printf("       want vd=%s status=%s\n", w, vdot_status_name(want_st));
}

static int run_file(const char *path, stat_t *st)
{
    FILE *f = fopen(path, "r");
    char line[LINEMAX];
    long lineno = 0;
    int policy = -1;
    int fields_seen = 0;
    long file_total = 0, file_rt_fail = 0, file_df_fail = 0;
    long file_df_ok = 0, file_df_skip = 0;

    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 2; }

    while (fgets(line, sizeof(line), f)) {
        char op_s[32], h1[64], h2[64], hdi[64], hde[64], h0[64], st_s[32];
        unsigned vsew, vstart, vl, vm, vta, vma;
        vreg128_t vs1, vs2, vd_in, vd_exp, v0, vd_got;
        int op, want_st, got_st;

        lineno++;
        if (line[0] == '#') {
            if (strncmp(line, "# policy:", 9) == 0) {
                if (strstr(line, "strict")) policy = VDOT_VSTART_STRICT;
                else if (strstr(line, "skip")) policy = VDOT_VSTART_SKIP;
            } else if (strncmp(line, "# fields:", 9) == 0) {
                char *nl = strchr(line, '\n'); if (nl) *nl = '\0';
                if (strcmp(line, k_expect_fields) != 0) {
                    printf("  FAIL header %s:%ld field list mismatch\n", path, lineno);
                    printf("       got  %s\n", line);
                    printf("       want %s\n", k_expect_fields);
                    file_rt_fail++;
                }
                fields_seen = 1;
            }
            continue;
        }
        if (line[0] == '\n' || line[0] == '\r' || line[0] == '\0') continue;

        if (sscanf(line, "%31s %u %u %u %u %u %u %63s %63s %63s %63s %63s %31s",
                   op_s, &vsew, &vstart, &vl, &vm, &vta, &vma,
                   h1, h2, hdi, hde, h0, st_s) != 13) {
            printf("  FAIL parse %s:%ld\n", path, lineno);
            file_rt_fail++; file_total++;
            continue;
        }
        op      = vdot_op_from_name(op_s);
        want_st = vdot_status_from_name(st_s);
        if (op < 0 || want_st < 0 ||
            vdot_hex_parse(h1, &vs1) || vdot_hex_parse(h2, &vs2) ||
            vdot_hex_parse(hdi, &vd_in) || vdot_hex_parse(hde, &vd_exp) ||
            vdot_hex_parse(h0, &v0)) {
            printf("  FAIL decode %s:%ld\n", path, lineno);
            file_rt_fail++; file_total++;
            continue;
        }
        file_total++;

        /* ---- [1] 回环：参考模型重算 ---- */
        vd_got = vd_in;
        got_st = vdot_exec(op, (int)vsew, &vd_got, &vs2, &vs1, vstart, vl,
                           vm ? NULL : &v0, (int)vta, (int)vma,
                           policy < 0 ? VDOT_VSTART_STRICT : policy);
        if (got_st != want_st || !vreg_eq(&vd_got, &vd_exp)) {
            dump_case(path, lineno, "roundtrip", &vd_got, &vd_exp, got_st, want_st);
            file_rt_fail++;
        }

        /* ---- [2] 差分：RVV 1.0 基线序列仿真 ---- */
        if (policy == VDOT_VSTART_SKIP && vstart != 0) {
            /* RVV 1.0 的 vwredsum.vs 自身禁止 vstart!=0，基线无法表达该语义 */
            file_df_skip++;
        } else if (want_st == VDOT_ERR_SEW || want_st == VDOT_ERR_VL ||
                   want_st == VDOT_ERR_VSTART_RANGE) {
            file_df_skip++;   /* 非法配置：基线侧无对应指令编码，不比对 */
        } else {
            vreg128_t vd_bl = vd_in;
            int bl_st = baseline_exec(op, (int)vsew, &vd_bl, &vs2, &vs1,
                                      vstart, vl, vm ? NULL : &v0,
                                      (int)vta, (int)vma);
            file_df_ok++;
            if (bl_st != got_st || !vreg_eq(&vd_bl, &vd_got)) {
                dump_case(path, lineno, "diff(ref vs baseline)",
                          &vd_bl, &vd_got, bl_st, got_st);
                file_df_fail++;
            }
        }
    }
    fclose(f);

    if (!fields_seen) {
        printf("  FAIL header %s: missing '# fields:' line\n", path);
        file_rt_fail++;
    }
    printf("  %-34s cases=%-6ld roundtrip_fail=%-4ld diff_checked=%-6ld "
           "diff_fail=%-4ld diff_skipped=%ld\n",
           path, file_total, file_rt_fail, file_df_ok, file_df_fail, file_df_skip);

    st->total          += file_total;
    st->roundtrip_fail += file_rt_fail;
    st->diff_checked   += file_df_ok;
    st->diff_fail      += file_df_fail;
    st->diff_skipped   += file_df_skip;
    return 0;
}

/* ---- [3] 长向量循环等价 ---- */
static int32_t naive_dot(const int8_t *a, const int8_t *b, size_t n)
{
    uint32_t s = 0; size_t i;
    for (i = 0; i < n; i++) s += (uint32_t)((int32_t)a[i] * (int32_t)b[i]);
    return (int32_t)s;
}

static int run_long_vector_check(void)
{
    static const size_t Ns[] = {0, 1, 2, 3, 4, 5, 15, 16, 17, 31, 32, 33,
                                63, 64, 127, 128, 255, 1024, 4096};
    const size_t nN = sizeof(Ns) / sizeof(Ns[0]);
    size_t k, i;
    int fail = 0;
    uint32_t rs = 0x1234567u;
    int8_t *a = (int8_t *)malloc(4096), *b = (int8_t *)malloc(4096);
    if (!a || !b) { free(a); free(b); return 1; }
    for (i = 0; i < 4096; i++) {
        rs = rs * 1103515245u + 12345u;  a[i] = (int8_t)((rs >> 16) & 0xFF);
        rs = rs * 1103515245u + 12345u;  b[i] = (int8_t)((rs >> 16) & 0xFF);
    }
    for (k = 0; k < nN; k++) {
        size_t n = Ns[k];
        int32_t r0 = naive_dot(a, b, n);
        int32_t r1 = baseline_long_dot_i8(a, b, n);
        int32_t r2 = vdot_long_dot_i8(a, b, n);
        int32_t r3 = vdot4a_long_dot_i8(a, b, n);
        if (r0 != r1 || r0 != r2 || r0 != r3) {
            printf("  FAIL long-vector N=%zu naive=%d baseline=%d vdotacc=%d vdot4a=%d\n",
                   n, r0, r1, r2, r3);
            fail++;
        }
    }
    free(a); free(b);
    printf("  long-vector loop equivalence: %zu sizes, %d mismatch\n", nN, fail);
    return fail;
}

int main(int argc, char **argv)
{
    stat_t st;
    int i, rc = 0, longfail;
    memset(&st, 0, sizeof(st));

    if (argc < 2) {
        fprintf(stderr, "usage: %s <vector_file>...\n", argv[0]);
        return 2;
    }
    printf("== vdot golden model self-test ==\n");
    printf("-- per-file results --\n");
    for (i = 1; i < argc; i++) {
        int r = run_file(argv[i], &st);
        if (r == 2) return 2;
    }
    printf("-- long vector loop --\n");
    longfail = run_long_vector_check();

    printf("-- summary --\n");
    printf("  total cases            : %ld\n", st.total);
    printf("  roundtrip failures     : %ld\n", st.roundtrip_fail);
    printf("  differential checked   : %ld\n", st.diff_checked);
    printf("  differential failures  : %ld\n", st.diff_fail);
    printf("  differential skipped   : %ld\n", st.diff_skipped);
    printf("  long-vector failures   : %d\n", longfail);
    rc = (st.roundtrip_fail || st.diff_fail || longfail) ? 1 : 0;
    printf("RESULT: %s\n", rc ? "FAIL" : "PASS");
    return rc;
}
