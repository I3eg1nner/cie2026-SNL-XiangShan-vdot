#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_official_pseudocode.py —— 「参考模型与赛题官方伪代码逐位等价」的独立核对

赛题给出的 vdot.vv 官方伪代码（SEW=8）：

    def vdot_vv(vs1, vs2, sew=8):
        result = 0
        for i in range(8):
            result += sign_extend(vs1[i]) * sign_extend(vs2[i])
        vd[0] = result
        vd[1..VLEN-1] = 0  # 其他通道清零

本脚本**按字面**实现上面这段伪代码（下方 official_vdot_vv()，不调用、不引用
tests/golden/vdot_ref.c 的任何代码），然后在「vl=8、vm=1、vstart=0」这一与伪代码
对应的配置上，与参考模型比对 128 位目的寄存器的全部比特：

  [1] 共享语料 tests/vectors/*.txt 中全部 op=vdot、vl=8、vm=1、vstart=0、
      status=OK 的用例：比对语料里记录的 vd_expected（即参考模型的输出）；
  [2] 另造 N 组随机激励（源操作数、vd 初值、vta、vma 全随机，源寄存器第 8..15
      个元素也随机），经 tests/golden/vdot_cli 现场调用参考模型，逐条比对。
      伪代码的输出与 vd 初值、vta、vma 无关，这一组同时检验了这一点。
  [3] vdotacc.vv（伪代码的累加变体，vd[0] = vd_old[0] + result，32 位回绕，
      其余清零）在同一配置下做同样的 [1][2] 比对，单列统计。

字面实现的约定：
  * vs1[i] / vs2[i] 是寄存器的第 i 个 int8 元素（字节 i，寄存器内小端，
    RVV §4，与 tests/golden/vdot_ref.h 的布局约定相同）；
  * vd[0] 是 SEW=8 源对应的四倍宽结果元素（32 位，字节 0..3）——赛题文档
    「int8 点积结果写 int32」；result 恒落在 int32 范围内（|Σ| <= 8*16384）；
  * 「vd[1..VLEN-1] = 0」理解为目的寄存器除 vd[0] 以外的全部比特清零。

退出码：0 = 全部一致；1 = 有失配；2 = 用法 / IO 错误。
用法：
  python3 tests/golden/check_official_pseudocode.py --cli tests/golden/vdot_cli \
      [--vectors tests/vectors] [--random 10000] [--seed 20261026]
"""

import argparse
import glob
import os
import random
import subprocess
import sys

VLENB = 16


# ---------------------------------------------------------------- 字面实现
def sign_extend(b):
    """int8 位模式 -> Python 整数"""
    return b - 256 if b >= 128 else b


def official_vdot_vv(vs1, vs2):
    """赛题伪代码逐行翻译。vs1/vs2 为 16 字节寄存器，返回 16 字节 vd。"""
    result = 0
    for i in range(8):
        result += sign_extend(vs1[i]) * sign_extend(vs2[i])
    vd = bytearray(VLENB)                                  # vd[1..VLEN-1] = 0
    vd[0:4] = (result & 0xFFFFFFFF).to_bytes(4, "little")  # vd[0] = result
    return bytes(vd)


def official_vdotacc_vv(vs1, vs2, vd_old):
    """累加变体：vd[0] = vd_old[0] + result（32 位回绕），其余清零。"""
    acc = int.from_bytes(vd_old[0:4], "little")
    result = 0
    for i in range(8):
        result += sign_extend(vs1[i]) * sign_extend(vs2[i])
    vd = bytearray(VLENB)
    vd[0:4] = ((acc + result) & 0xFFFFFFFF).to_bytes(4, "little")
    return bytes(vd)


def expect(op, vs1, vs2, vd_in):
    return official_vdot_vv(vs1, vs2) if op == "vdot" else official_vdotacc_vv(vs1, vs2, vd_in)


# ---------------------------------------------------------------- 工具
def h2b(s):
    return bytes.fromhex(s)


def run_cli(cli, reqs):
    p = subprocess.run([cli], input="".join(r + "\n" for r in reqs),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       universal_newlines=True)
    if p.returncode != 0:
        sys.stderr.write(p.stderr)
        sys.exit(2)
    out = [l.split() for l in p.stdout.splitlines() if l.strip()]
    if len(out) != len(reqs):
        sys.stderr.write("vdot_cli 返回行数不符\n")
        sys.exit(2)
    return out


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--cli", default=os.path.join(here, "vdot_cli"))
    ap.add_argument("--vectors", default=os.path.join(here, "..", "vectors"))
    ap.add_argument("--random", type=int, default=10000)
    ap.add_argument("--seed", type=int, default=20261026)
    a = ap.parse_args()
    if not os.access(a.cli, os.X_OK):
        sys.stderr.write("找不到 vdot_cli：%s（先 make -C tests/golden vdot_cli）\n" % a.cli)
        return 2

    print("=== 参考模型 vs 赛题官方伪代码（字面实现）逐位核对 ===")
    print("配置：vl=8, vm=1, vstart=0, SEW=8, LMUL=1, VLEN=128；比对 vd 全部 128 位")
    rc = 0
    stats = {}

    # [1] 共享语料
    print("\n--- [1] 共享语料中 vl=8 / vm=1 / vstart=0 / status=OK 的用例 ---")
    shown = {}
    for path in sorted(glob.glob(os.path.join(a.vectors, "*.txt"))):
        name = os.path.basename(path)
        for ln, line in enumerate(open(path, encoding="utf-8"), 1):
            if line.startswith("#") or not line.strip():
                continue
            f = line.split()
            op, vsew, vstart, vl, vm = f[0], int(f[1]), int(f[2]), int(f[3]), int(f[4])
            if op not in ("vdot", "vdotacc") or vsew != 8 or vl != 8 or vm != 1 \
               or vstart != 0 or f[12] != "OK":
                continue
            vs1, vs2, vd_in, vd_exp = h2b(f[7]), h2b(f[8]), h2b(f[9]), h2b(f[10])
            want = expect(op, vs1, vs2, vd_in)
            key = ("corpus", op)
            st = stats.setdefault(key, [0, 0])
            st[0] += 1
            if want != vd_exp:
                st[1] += 1
                rc = 1
                print("  MISMATCH %s:%d op=%s pseudo=%s model=%s" % (name, ln, op, want.hex(), vd_exp.hex()))
            elif op == "vdot" and shown.get(name, 0) < 6 and \
                    f[9] == "a5a5a5a5efbeaddebebafeca78563412":
                # 只展示 gen_vectors.py 的 vl=8 定向用例（vd 初值四字非零，vta=0/1 各一）
                shown[name] = shown.get(name, 0) + 1
                r = int.from_bytes(want[0:4], "little")
                r = r - (1 << 32) if r >= (1 << 31) else r
                print("  例 %-14s 行%-4d vta=%s vd_in=%s -> vd=%s (vd[0]=%d)"
                      % (name, ln, f[5], f[9], vd_exp.hex(), r))
    for op in ("vdot", "vdotacc"):
        n, bad = stats.get(("corpus", op), [0, 0])
        print("  [1] %-8s 语料用例 %5d 条，失配 %d" % (op, n, bad))

    # [2] 随机激励，现场调用参考模型
    print("\n--- [2] 随机激励 %d 组 / 指令（vd 初值、vta、vma、源寄存器高 8 个元素全随机），"
          "经 vdot_cli 调用参考模型 ---" % a.random)
    rng = random.Random(a.seed)
    for op in ("vdot", "vdotacc"):
        reqs, ins = [], []
        for _ in range(a.random):
            vs1 = bytes(rng.randrange(256) for _ in range(VLENB))
            vs2 = bytes(rng.randrange(256) for _ in range(VLENB))
            vd_in = bytes(rng.randrange(256) for _ in range(VLENB))
            v0 = bytes(rng.randrange(256) for _ in range(VLENB))
            vta, vma = rng.randrange(2), rng.randrange(2)
            reqs.append("%s 8 0 8 1 %d %d %s %s %s %s strict"
                        % (op, vta, vma, vs1.hex(), vs2.hex(), vd_in.hex(), v0.hex()))
            ins.append((vs1, vs2, vd_in))
        out = run_cli(a.cli, reqs)
        bad = 0
        for (vs1, vs2, vd_in), (vd_hex, status) in zip(ins, out):
            want = expect(op, vs1, vs2, vd_in)
            if status != "OK" or h2b(vd_hex) != want:
                bad += 1
                if bad <= 5:
                    print("  MISMATCH op=%s pseudo=%s model=%s status=%s" % (op, want.hex(), vd_hex, status))
        if bad:
            rc = 1
        stats[("random", op)] = [a.random, bad]
        print("  [2] %-8s 随机用例 %5d 条，失配 %d" % (op, a.random, bad))

    print("\n--- 汇总 ---")
    tot = sum(v[0] for v in stats.values())
    totbad = sum(v[1] for v in stats.values())
    print("  vdot.vv  （官方伪代码本体）: 语料 %d + 随机 %d 条，失配 %d"
          % (stats[("corpus", "vdot")][0], stats[("random", "vdot")][0],
             stats[("corpus", "vdot")][1] + stats[("random", "vdot")][1]))
    print("  vdotacc.vv（伪代码累加变体）: 语料 %d + 随机 %d 条，失配 %d"
          % (stats[("corpus", "vdotacc")][0], stats[("random", "vdotacc")][0],
             stats[("corpus", "vdotacc")][1] + stats[("random", "vdotacc")][1]))
    print("OFFICIAL-PSEUDOCODE-EQUIV: %s (%d cases, %d mismatches)"
          % ("PASS" if rc == 0 else "FAIL", tot, totbad))
    return rc


if __name__ == "__main__":
    sys.exit(main())
