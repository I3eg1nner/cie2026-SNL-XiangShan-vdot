#!/usr/bin/env python3
"""
gen_extra_vectors.py —— 生成 P5 补充定向语料（期望值一律由参考模型算出）

为什么需要补充语料
------------------
`tests/vectors/` 的 13 个 suite（30739 条）里只出现 OK / ILLEGAL_VSTART /
ERR_SEW 三种状态，**没有任何 `ERR_VSTART_RANGE` 用例**，也就是总体方案裁定
S-9（`vstart` 超出当前 SEW 的最大元素下标 → 报错）在共享语料中是未覆盖的。

裁定 S-7' 之后三条指令的 `vstart != 0` 都是非法指令，S-9（`vstart` 越界）
与 S-1/S-7'（`vstart != 0`）在**架构可观测行为**上因此重合：两者都是
Illegal Instruction。但二者在参考模型里仍是两个不同的状态码，且**判定次序
有区分度** —— 参考模型与 NEMU 都先判越界（S-9）、再判非零（S-1/S-7'）。
本 suite 的价值因此从"覆盖一组独有行为"变为：
  ① 覆盖 `ERR_VSTART_RANGE` 这条在 `tests/vectors/` 中完全缺席的状态码；
  ② 在**参考模型**层面钉住 S-9 与 S-1/S-7' 的判定次序（test_golden 回环比对
     status 字段，次序一旦颠倒参考模型会退化为只报 ILLEGAL_VSTART）。注意在 NEMU
     上二者都是 mcause=2，次序不可观测 —— S-7' 之后删掉 NEMU 的 S-9 检查成了
     等价变异体（见 tests/riscv/vdot/fault_inject.sh #5）；
  ③ 覆盖 `vstart ∈ [1,3]`（vdot4a 的架构内非零取值）与 `vstart ∈ [4,15]`
     （越界）两侧的边界，确认 NEMU 两种情形都 trap 且 mcause 均为 2。

语义来源
--------
本脚本**不计算任何期望值**：它只构造输入，然后把整批请求通过管道交给
`tests/golden/vdot_cli`（即 `tests/golden/vdot_ref.c` 的命令行外壳），
由参考模型算出 `vd_expected` 与 `status`。与 `tests/vectors/gen_vectors.py`
的做法完全一致，保证全项目只有一份 vdot 语义实现。

输出格式与 tests/vectors/*.txt 完全相同（13 字段），可被 pack_corpus.py 直接消费。

用法：
    python3 gen_extra_vectors.py <vdot_cli 可执行文件> <输出 .txt>
"""
import subprocess
import sys

VLENB = 16
POLICY = "strict"


def hx(byts):
    return "".join("%02x" % b for b in byts)


def ramp(start, step):
    return bytes(((start + i * step) & 0xFF) for i in range(VLENB))


def build_cases():
    """只构造输入。每项: (op, vsew, vstart, vl, vm, vta, vma, vs1, vs2, vd_in, v0)"""
    vs1 = ramp(1, 1)          # 01 02 03 ... 10
    vs2 = ramp(0xF0, 3)       # 含负数，便于暴露符号扩展问题
    vd = bytes([0x5A] * VLENB)
    v0 = bytes([0xA5] * VLENB)
    cases = []

    # --- A. vdot4a：VLMAX = 4，vstart ∈ [4,15] 属 §3.7 reserved（S-9） ---
    for vstart in (4, 5, 8, 15):
        for vl in (0, 1, 4):
            for vta in (0, 1):
                cases.append(("vdot4a", 32, vstart, vl, 1, vta, 0, vs1, vs2, vd, v0))
    # 紧邻越界门限的架构内取值（vstart = 3）：S-7' 之后它同样是 ILLEGAL_VSTART，
    # 但走的是另一条判据。保留这组用例可以证明两条判据都在、且次序正确。
    for vl in (0, 1, 3, 4):
        for vta in (0, 1):
            cases.append(("vdot4a", 32, 3, vl, 1, vta, 0, vs1, vs2, vd, v0))
    # vstart = 0 的合法对照组：确认没有把合法配置误判为非法
    for vl in (0, 1, 3, 4):
        for vta in (0, 1):
            cases.append(("vdot4a", 32, 0, vl, 1, vta, 0, vs1, vs2, vd, v0))

    # --- B. vdot / vdotacc：VLMAX = 16，vstart > 15 同样越界 ---
    for op in ("vdot", "vdotacc"):
        for vstart in (16, 17, 31):
            for vl in (0, 16):
                cases.append((op, 8, vstart, vl, 1, 1, 0, vs1, vs2, vd, v0))

    # --- C. 带掩码的越界用例，确认 vm/v0 不影响越界判定 ---
    for vstart in (4, 15):
        cases.append(("vdot4a", 32, vstart, 4, 0, 1, 1, vs1, vs2, vd, v0))
    cases.append(("vdot", 8, 16, 16, 0, 1, 1, vs1, vs2, vd, v0))

    return cases


def main():
    if len(sys.argv) != 3:
        print("usage: gen_extra_vectors.py <vdot_cli> <out.txt>", file=sys.stderr)
        return 2
    cli, out = sys.argv[1], sys.argv[2]
    cases = build_cases()

    req = "".join(
        "%s %d %d %d %d %d %d %s %s %s %s %s\n"
        % (op, vsew, vstart, vl, vm, vta, vma, hx(s1), hx(s2), hx(d), hx(m), POLICY)
        for (op, vsew, vstart, vl, vm, vta, vma, s1, s2, d, m) in cases)

    proc = subprocess.run([cli], input=req, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        return 1
    resp = [ln.split() for ln in proc.stdout.strip().split("\n")]
    if len(resp) != len(cases):
        print("ERROR: 参考模型返回 %d 行，期望 %d 行" % (len(resp), len(cases)),
              file=sys.stderr)
        return 1

    with open(out, "w") as fh:
        fh.write("# vdot instruction family supplementary corpus (P5 / NEMU)\n")
        fh.write("# suite: vstart_range\n")
        fh.write("# cases: %d\n" % len(cases))
        fh.write("# policy: strict\n")
        fh.write("# vlen: 128\n# lmul: 1\n")
        fh.write("# generator: tests/riscv/vdot/gen_extra_vectors.py\n")
        fh.write("# oracle: tests/golden/vdot_ref.c (via tests/golden/vdot_cli)\n")
        fh.write("# hex layout: 32 chars per register, v[0] leftmost\n")
        fh.write("# rationale: 覆盖 MASTER_PLAN 裁定 S-9（vstart 超出当前 SEW 的最大\n")
        fh.write("# rationale: 元素下标 -> 报错）。tests/vectors/ 的 13 个共享 suite 中\n")
        fh.write("# rationale: 没有任何 ERR_VSTART_RANGE 用例。裁定 S-7' 之后 vdot4a 的\n")
        fh.write("# rationale: vstart!=0 也是非法指令，本 suite 因此还负责钉住 S-9 与\n")
        fh.write("# rationale: S-1/S-7' 的判定次序（先判越界、再判非零），并给出\n")
        fh.write("# rationale: vstart=0 的合法对照组。\n")
        fh.write("# fields: op vsew vstart vl vm vta vma vs1_hex(32) vs2_hex(32) "
                 "vd_in_hex(32) vd_expected_hex(32) v0_hex(32) status\n")
        n_status = {}
        for (op, vsew, vstart, vl, vm, vta, vma, s1, s2, d, m), r in zip(cases, resp):
            fh.write("%s %d %d %d %d %d %d %s %s %s %s %s %s\n"
                     % (op, vsew, vstart, vl, vm, vta, vma,
                        hx(s1), hx(s2), hx(d), r[0], hx(m), r[1]))
            n_status[r[1]] = n_status.get(r[1], 0) + 1
    print("  -> %s  (%d cases, status: %s)"
          % (out, len(cases), ", ".join("%s=%d" % kv for kv in sorted(n_status.items()))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
