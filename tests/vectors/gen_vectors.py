#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_vectors.py —— vdot 指令族共享测试向量语料生成器（python3 标准库，无第三方依赖）

设计原则（最重要的一条）：
    本脚本 **不包含任何一行 vdot 语义实现**。
    它只负责构造「输入激励」，期望值一律通过管道交给 tests/golden/vdot_cli
    （即 C 参考模型 tests/golden/vdot_ref.c）计算。
    因此全项目里 vdot 的语义只有唯一一份实现，Python 侧不可能与之漂移。

输出格式（每个 suite 一个纯文本文件，一行一个用例，字段以空白分隔）：

    # fields: op vsew vstart vl vm vta vma vs1_hex(32) vs2_hex(32) \
      vd_in_hex(32) vd_expected_hex(32) v0_hex(32) status

      op      vdot | vdotacc | vdot4a
      vsew    元素位宽（十进制 8/16/32/64）。vdot/vdotacc 要求 8，vdot4a 要求 32
      vstart  vstart CSR（十进制）
      vl      vl CSR（十进制）
      vm      指令编码中的 vm 位：1 = 不使用掩码；0 = 使用 v0 掩码
      vta     vtype.vta（0/1）
      vma     vtype.vma（0/1）
      *_hex   32 个小写十六进制字符，**v[0] 在最左**（字节序约定见 vdot_ref.h）
      v0_hex  掩码寄存器 v0 的完整 128 位内容（vm=1 时无意义，仍然给出）
      status  参考模型返回的状态名：OK / ILLEGAL_VSTART / ERR_SEW / ...
              非 OK 时 vd_expected 恒等于 vd_in（规范要求不写回目的寄存器）
              注：裁定 S-7' 之后 vdot4a 的 vstart!=0 也返回 ILLEGAL_VSTART

用法：
    python3 gen_vectors.py --cli <vdot_cli 路径> [--outdir <目录>]
"""

import argparse
import os
import random
import subprocess
import sys

VLENB = 16
FIELDS = ("# fields: op vsew vstart vl vm vta vma vs1_hex(32) vs2_hex(32) "
          "vd_in_hex(32) vd_expected_hex(32) v0_hex(32) status")

# 每个 suite 固定的 RNG 种子，保证可复现（请勿随意改动，改动会使语料全部变化）
SEEDS = {
    "positive":          20260101,
    "negative":          20260102,
    "boundary":          20260103,
    "random":            20260104,
    "vdotacc_positive":  20260201,
    "vdotacc_negative":  20260202,
    "vdotacc_boundary":  20260203,
    "vdotacc_random":    20260204,
    "vdot4a_positive":   20260301,
    "vdot4a_negative":   20260302,
    "vdot4a_boundary":   20260303,
    "vdot4a_random":     20260304,
    "vstart_relaxed":    20260401,
}

RANDOM_CASES = 10000

ZERO16 = bytes(VLENB)


# ----------------------------------------------------------------------
# 基础工具
# ----------------------------------------------------------------------
def hx(b):
    """16 字节 -> 32 个十六进制字符，v[0] 在最左。"""
    assert len(b) == VLENB
    return b.hex()


def u32le(words):
    """4 个 32 位无符号数 -> 16 字节（寄存器内小端）。"""
    out = bytearray()
    for w in words:
        w &= 0xFFFFFFFF
        out += bytes((w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF, (w >> 24) & 0xFF))
    return bytes(out)


def mask_reg(bits, fill=0):
    """由 16 个 0/1 构造 v0 寄存器；fill 为 v0 高位字节的填充值。"""
    b = bytearray([fill]) * VLENB
    b[0] = 0
    b[1] = 0
    for i, v in enumerate(bits):
        if v:
            b[i >> 3] |= 1 << (i & 7)
    return bytes(b)


def rnd_bytes(rng, lo, hi):
    return bytes(rng.randint(lo, hi) for _ in range(VLENB))


class Case(object):
    __slots__ = ("op", "vsew", "vstart", "vl", "vm", "vta", "vma",
                 "vs1", "vs2", "vd_in", "v0", "note")

    def __init__(self, op, vsew, vstart, vl, vm, vta, vma,
                 vs1, vs2, vd_in, v0=ZERO16, note=""):
        self.op, self.vsew = op, vsew
        self.vstart, self.vl = vstart, vl
        self.vm, self.vta, self.vma = vm, vta, vma
        self.vs1, self.vs2, self.vd_in, self.v0 = vs1, vs2, vd_in, v0
        self.note = note

    def request(self, policy):
        return "%s %d %d %d %d %d %d %s %s %s %s %s" % (
            self.op, self.vsew, self.vstart, self.vl, self.vm, self.vta,
            self.vma, hx(self.vs1), hx(self.vs2), hx(self.vd_in),
            hx(self.v0), policy)


# ----------------------------------------------------------------------
# 调用 C 参考模型（唯一的语义来源）
# ----------------------------------------------------------------------
def evaluate(cli, cases, policy):
    req = "\n".join(c.request(policy) for c in cases) + "\n"
    p = subprocess.run([cli], input=req, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, universal_newlines=True)
    if p.returncode != 0:
        sys.stderr.write(p.stderr)
        raise SystemExit("vdot_cli failed with exit code %d" % p.returncode)
    lines = [l for l in p.stdout.splitlines() if l.strip()]
    if len(lines) != len(cases):
        raise SystemExit("vdot_cli returned %d lines for %d cases"
                         % (len(lines), len(cases)))
    out = []
    for c, l in zip(cases, lines):
        vd_exp, status = l.split()
        out.append((c, vd_exp, status))
    return out


def write_suite(path, name, policy, seed, cases, results, rationale):
    with open(path, "w") as f:
        f.write("# vdot instruction family shared test-vector corpus\n")
        f.write("# suite: %s\n" % name)
        f.write("# cases: %d\n" % len(cases))
        f.write("# policy: %s   (vstart 策略，见 docs/stage2/13 语义裁定记录 S-1)\n"
                % policy)
        f.write("# seed: %d\n" % seed)
        f.write("# vlen: 128\n")
        f.write("# lmul: 1\n")
        f.write("# generator: tests/vectors/gen_vectors.py\n")
        f.write("# oracle: tests/golden/vdot_ref.c (via tests/golden/vdot_cli)\n")
        f.write("# hex layout: 32 chars per register, v[0] leftmost "
                "(see tests/golden/vdot_ref.h)\n")
        for line in rationale.strip().splitlines():
            f.write("# rationale: %s\n" % line.strip())
        f.write(FIELDS + "\n")
        for c, vd_exp, status in results:
            f.write("%s %d %d %d %d %d %d %s %s %s %s %s %s\n" % (
                c.op, c.vsew, c.vstart, c.vl, c.vm, c.vta, c.vma,
                hx(c.vs1), hx(c.vs2), hx(c.vd_in), vd_exp, hx(c.v0), status))


# ----------------------------------------------------------------------
# suite 构造：正数（赛题 2.3.1）
# ----------------------------------------------------------------------
def build_positive(op, rng):
    vsew = 32 if op == "vdot4a" else 8
    vlmax = 4 if op == "vdot4a" else 16
    cases = []
    # 1) 确定性小样本：便于人工核对
    fixed = [
        (bytes(range(1, 17)), bytes(range(1, 17))),            # 1..16 自乘
        (bytes([1] * 16), bytes([1] * 16)),                    # 全 1
        (bytes([127] * 16), bytes([1] * 16)),                  # 最大正数 × 1
        (bytes([1] * 16), bytes([127] * 16)),
        (bytes([127] * 16), bytes([127] * 16)),                # 最大正积 16129*16
        (bytes([2] * 16), bytes([64] * 16)),
        (bytes(range(1, 17)), bytes(range(16, 0, -1))),
        (bytes([100] * 16), bytes([100] * 16)),
    ]
    for a, b in fixed:
        vd = u32le([0, 0, 0, 0]) if op != "vdotacc" else u32le([1000, 0, 0, 0])
        cases.append(Case(op, vsew, 0, vlmax, 1, 1, 1, a, b, vd,
                          note="fixed positive"))
    # 2) 随机正数，遍历 vl / vta / vd 初值
    for k in range(32):
        a = rnd_bytes(rng, 1, 127)
        b = rnd_bytes(rng, 1, 127)
        vl = rng.randint(1, vlmax)
        vta = k & 1
        vd = u32le([rng.randint(0, 0xFFFF) for _ in range(4)])
        cases.append(Case(op, vsew, 0, vl, 1, vta, 1, a, b, vd,
                          note="random positive"))
    return cases


# ----------------------------------------------------------------------
# suite 构造：负数 / 混合符号（赛题 2.3.2）
# ----------------------------------------------------------------------
def build_negative(op, rng):
    vsew = 32 if op == "vdot4a" else 8
    vlmax = 4 if op == "vdot4a" else 16
    cases = []
    fixed = [
        (bytes([0x80] * 16), bytes([0x80] * 16)),   # -128 * -128 = +16384（符号扩展陷阱）
        (bytes([0x80] * 16), bytes([0x7F] * 16)),   # -128 * +127 = -16256（最小乘积）
        (bytes([0x7F] * 16), bytes([0x80] * 16)),
        (bytes([0xFF] * 16), bytes([0xFF] * 16)),   # -1 * -1 = +1
        (bytes([0xFF] * 16), bytes([0x01] * 16)),   # -1 * +1 = -1，结果为负
        (bytes([0x80] * 16), bytes([0x01] * 16)),   # 和 = -2048
        (bytes(range(0xF0, 0x100)), bytes(range(0xF0, 0x100))),
        (bytes([0x80, 0x7F] * 8), bytes([0x7F, 0x80] * 8)),  # 交替符号
        (bytes([0xFE] * 16), bytes([0x02] * 16)),
        (bytes([0x81] * 16), bytes([0x81] * 16)),   # -127 * -127
    ]
    for a, b in fixed:
        vd = u32le([0, 0, 0, 0]) if op != "vdotacc" else u32le([0xFFFFFFFF, 0, 0, 0])
        cases.append(Case(op, vsew, 0, vlmax, 1, 1, 1, a, b, vd,
                          note="fixed negative / sign-extension trap"))
    # 全负
    for k in range(10):
        a = rnd_bytes(rng, 0x80, 0xFF)
        b = rnd_bytes(rng, 0x80, 0xFF)
        vd = u32le([rng.randint(0, 0xFFFFFFFF) for _ in range(4)])
        cases.append(Case(op, vsew, 0, vlmax, 1, k & 1, 1, a, b, vd,
                          note="all negative"))
    # 正负混合（结果可正可负）
    for k in range(16):
        a = rnd_bytes(rng, 0, 255)
        b = rnd_bytes(rng, 0, 255)
        vl = rng.randint(1, vlmax)
        vd = u32le([rng.randint(0, 0xFFFFFFFF) for _ in range(4)])
        cases.append(Case(op, vsew, 0, vl, 1, k & 1, 1, a, b, vd,
                          note="mixed sign"))
    # 单点符号扩展陷阱：只有一个元素是 0x80，其余为 0
    for i in range(0, 16, 2):
        a = bytearray(16); b = bytearray(16)
        a[i] = 0x80; b[i] = 0x80
        cases.append(Case(op, vsew, 0, vlmax, 1, 1, 1,
                          bytes(a), bytes(b), ZERO16,
                          note="single 0x80*0x80 at lane %d" % i))
    return cases


# ----------------------------------------------------------------------
# suite 构造：边界（赛题 2.3.3）
# ----------------------------------------------------------------------
def build_boundary(op, rng):
    vsew = 32 if op == "vdot4a" else 8
    vlmax = 4 if op == "vdot4a" else 16
    cases = []
    allz = ZERO16
    all7f = bytes([0x7F] * 16)
    all80 = bytes([0x80] * 16)
    allff = bytes([0xFF] * 16)

    # A. +127 / -128 / 0 的两两组合
    combos = [allz, all7f, all80, allff,
              bytes([0x7F, 0x80] * 8), bytes([0x00, 0x80] * 8),
              bytes([0x7F, 0x00] * 8)]
    for a in combos:
        for b in combos:
            cases.append(Case(op, vsew, 0, vlmax, 1, 1, 1, a, b, allz,
                              note="extreme combo"))
    # B. 最大幅值和：16 * 128 * 128 = 262144 = 0x40000
    cases.append(Case(op, vsew, 0, vlmax, 1, 1, 1, all80, all80, allz,
                      note="max magnitude sum 0x40000"))
    cases.append(Case(op, vsew, 0, vlmax, 1, 0, 0, all80, all80,
                      u32le([0, 0xDEADBEEF, 0xCAFEBABE, 0x12345678]),
                      note="max magnitude, vta=0 tail undisturbed"))

    # C. vl 全扫描（vdot/vdotacc: 0..16；vdot4a: 0..4）
    vls = list(range(0, vlmax + 1))
    if op != "vdot4a":
        vls = [0, 1, 2, 3, 4, 15, 16]
    for vl in vls:
        for vta in (0, 1):
            cases.append(Case(op, vsew, 0, vl, 1, vta, 1,
                              bytes(range(1, 17)), bytes(range(0x70, 0x80)),
                              u32le([0xA5A5A5A5, 0x5A5A5A5A, 0x11111111, 0x22222222]),
                              note="vl=%d vta=%d" % (vl, vta)))

    # D. vstart ∈ {0,1,15}（vdot4a 用 {0,1,3}）
    vstarts = [0, 1, 3] if op == "vdot4a" else [0, 1, 15]
    for vs in vstarts:
        for vl in (vlmax, max(1, vlmax // 2), 0):
            cases.append(Case(op, vsew, vs, vl, 1, 1, 1,
                              bytes(range(1, 17)), bytes([2] * 16),
                              u32le([0x100, 0x200, 0x300, 0x400]),
                              note="vstart=%d vl=%d" % (vs, vl)))

    # E. 掩码变体（vm=0）：全 0 掩码、全 1 掩码、交替、单 bit
    patterns = {
        "all-zero":   [0] * 16,
        "all-one":    [1] * 16,
        "alternate":  [i % 2 for i in range(16)],
        "low-half":   [1 if i < 8 else 0 for i in range(16)],
        "single-lsb": [1 if i == 0 else 0 for i in range(16)],
        "single-msb": [1 if i == 15 else 0 for i in range(16)],
    }
    for pname, bits in patterns.items():
        for vta in (0, 1):
            for vma in (0, 1):
                cases.append(Case(op, vsew, 0, vlmax, 0, vta, vma,
                                  bytes([0x7F] * 16), bytes([0x02] * 16),
                                  u32le([0x1, 0x2, 0x3, 0x4]),
                                  mask_reg(bits, fill=0xA5),
                                  note="mask %s vta=%d vma=%d" % (pname, vta, vma)))

    # F. vdot4a 的分组边界：每个 32 位元素内 4 个子字节的定位
    if op == "vdot4a":
        for g in range(4):
            for j in range(4):
                a = bytearray(16); b = bytearray(16)
                a[4 * g + j] = 0x7F
                b[4 * g + j] = 0x02
                cases.append(Case(op, vsew, 0, 4, 1, 1, 1,
                                  bytes(a), bytes(b), allz,
                                  note="group %d sub-byte %d" % (g, j)))
        # 组内 4 个子字节分别取 ±极值
        cases.append(Case(op, vsew, 0, 4, 1, 1, 1,
                          bytes([0x80, 0x7F, 0x00, 0xFF] * 4),
                          bytes([0x80, 0x7F, 0x7F, 0xFF] * 4),
                          allz, note="per-group extremes"))
        # 累加器回绕
        cases.append(Case(op, vsew, 0, 4, 1, 1, 1, all80, all80,
                          u32le([0xFFFFFFFF] * 4), note="accumulator wrap"))
    else:
        # vdotacc 的 32 位回绕
        cases.append(Case(op, vsew, 0, 16, 1, 1, 1, all80, all80,
                          u32le([0xFFFFFFFF, 0, 0, 0]), note="acc wrap"))
        cases.append(Case(op, vsew, 0, 16, 1, 1, 1, all80, all7f,
                          u32le([0x00000000, 0, 0, 0]), note="negative sum"))

    # G. 非法 vsew（架构上可达：vtype.vsew 与指令要求不符 -> Illegal Instruction）
    bad_sews = [8, 16, 64] if op == "vdot4a" else [16, 32, 64]
    for s in bad_sews:
        cases.append(Case(op, s, 0, 1, 1, 1, 1,
                          bytes(range(1, 17)), bytes(range(1, 17)),
                          u32le([0x5A5A5A5A] * 4), note="illegal vsew=%d" % s))
    return cases


# ----------------------------------------------------------------------
# suite 构造：随机
# ----------------------------------------------------------------------
def build_random(op, rng, n=RANDOM_CASES):
    vsew = 32 if op == "vdot4a" else 8
    vlmax = 4 if op == "vdot4a" else 16
    cases = []
    for _ in range(n):
        a = rnd_bytes(rng, 0, 255)
        b = rnd_bytes(rng, 0, 255)
        vd = rnd_bytes(rng, 0, 255)
        v0 = rnd_bytes(rng, 0, 255)         # 高位字节也随机，检验消费端是否忽略无关位
        vl = rng.randint(0, vlmax)
        # 15% 的用例带非零 vstart（归约指令据此验证 Illegal Instruction 行为）
        if rng.random() < 0.15:
            vstart = rng.randint(1, vlmax - 1)
        else:
            vstart = 0
        vm = 0 if rng.random() < 0.5 else 1
        cases.append(Case(op, vsew, vstart, vl, vm,
                          rng.randint(0, 1), rng.randint(0, 1),
                          a, b, vd, v0, note="random"))
    return cases


# ----------------------------------------------------------------------
# suite 构造：vstart 放宽策略（非规范，供 RTL 侧可选的数据通路测试）
# ----------------------------------------------------------------------
def build_vstart_relaxed(rng):
    cases = []
    for op in ("vdot", "vdotacc"):
        for vstart in (0, 1, 2, 7, 15):
            for vl in (0, 1, 8, 15, 16):
                a = rnd_bytes(rng, 0, 255)
                b = rnd_bytes(rng, 0, 255)
                vd = u32le([rng.randint(0, 0xFFFFFFFF) for _ in range(4)])
                cases.append(Case(op, 8, vstart, vl, 1, 1, 1, a, b, vd,
                                  note="relaxed vstart"))
        for k in range(20):
            a = rnd_bytes(rng, 0, 255)
            b = rnd_bytes(rng, 0, 255)
            vd = rnd_bytes(rng, 0, 255)
            v0 = rnd_bytes(rng, 0, 255)
            vl = rng.randint(0, 16)
            vstart = rng.randint(0, 15)
            cases.append(Case(op, 8, vstart, vl, k & 1, (k >> 1) & 1,
                              (k >> 2) & 1, a, b, vd, v0,
                              note="relaxed vstart random"))
    # vdot4a：裁定 S-7' 之后，vstart!=0 在**架构层**已是非法指令，规范语料里
    # 原有的 1545 条 vstart!=0 用例全部转为 ILLEGAL_VSTART、不再进入 FU。
    # 但 RTL 数据通路本身仍然实现了 §5.4 的 prestart 门控（S-7' 是平台约束，
    # 不是数据通路缺陷），为避免这部分逻辑完全失去 L1 覆盖，在本非规范语料里
    # 补上 vdot4a 的 prestart 用例 —— 它们同时也是「将来若实现 vstart 重启，
    # 语义应当是什么」的可执行说明。
    for vstart in (0, 1, 2, 3):
        for vl in (0, 1, 2, 3, 4):
            a = rnd_bytes(rng, 0, 255)
            b = rnd_bytes(rng, 0, 255)
            vd = u32le([rng.randint(0, 0xFFFFFFFF) for _ in range(4)])
            cases.append(Case("vdot4a", 32, vstart, vl, 1, 1, 1, a, b, vd,
                              note="relaxed vstart (vdot4a prestart)"))
    for k in range(20):
        a = rnd_bytes(rng, 0, 255)
        b = rnd_bytes(rng, 0, 255)
        vd = rnd_bytes(rng, 0, 255)
        v0 = rnd_bytes(rng, 0, 255)
        vl = rng.randint(0, 4)
        vstart = rng.randint(0, 3)
        cases.append(Case("vdot4a", 32, vstart, vl, k & 1, (k >> 1) & 1,
                          (k >> 2) & 1, a, b, vd, v0,
                          note="relaxed vstart random (vdot4a)"))
    return cases


# ----------------------------------------------------------------------
RATIONALE = {
    "positive": """
        对应赛题 2.3.1「正数测试」。全部源操作数取 [1,127]，覆盖 1×1、127×1、
        127×127 等极值，以及 32 组随机正数（遍历 vl 与 vta）。
        结果必为正，用于验证乘法阵列与加法树在无符号路径上的基本正确性。
    """,
    "negative": """
        对应赛题 2.3.2「负数测试」。含全负、正负混合，以及符号扩展陷阱：
        0x80×0x80=+16384（最易写成 -16384 或 +32768 的位置）、
        0x80×0x7F=-16256（最小乘积）、0xFF×0xFF=+1。
        另含单 lane 置 0x80 的定位用例，可直接定位出错的乘法器通道。
    """,
    "boundary": """
        对应赛题 2.3.3「边界测试」。覆盖：
        A +127/-128/0 的 7×7 两两组合；
        B 最大幅值和 16×128×128 = 262144 = 0x40000；
        C vl 全扫描（含 vl=0 不写回）与 vta 两种取值；
        D vstart ∈ {0,1,15}（归约指令据此验证 Illegal Instruction）；
        E 6 种掩码图样 × vta × vma；
        F vdot4a 的分组/子字节定位与累加器回绕；
        G vtype.vsew 与指令不匹配时的 Illegal Instruction。
    """,
    "random": """
        10000 组均匀随机：源操作数全字节随机、vd 初值随机、v0 全 128 位随机
        （含 vl 以外的无关掩码位，用于检验消费端是否正确忽略）、
        vl/vstart/vm/vta/vma 随机。用于 RTL 与 NEMU 的大规模差分比对。
    """,
    "vstart_relaxed": """
        非规范补充语料：采用 SKIP 策略（三条指令都不抛 Illegal Instruction，
        而是按 RVV v1.0 §5.4 的 prestart 规则跳过 i<vstart 的源元素）。
        仅供 RTL 侧在实现了可重启执行时做数据通路测试，不参与规范一致性判定。
        规范语义见裁定 S-1（vdot/vdotacc，RVV §14）与 S-7'（vdot4a，平台约束
        优先原则）：两者在 STRICT 策略下 vstart!=0 一律 Illegal Instruction。
        vdot4a 的 40 条是 S-7' 之后补入的，用于保住 prestart 门控的数据通路覆盖。
    """,
}


def main():
    ap = argparse.ArgumentParser(description="generate vdot shared test vectors")
    ap.add_argument("--cli", required=True,
                    help="path to tests/golden/vdot_cli (the C reference model)")
    ap.add_argument("--outdir", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--random-cases", type=int, default=RANDOM_CASES)
    args = ap.parse_args()

    cli = os.path.abspath(args.cli)
    if not os.path.isfile(cli) or not os.access(cli, os.X_OK):
        raise SystemExit("vdot_cli not found or not executable: %s\n"
                         "run `make -C tests/golden vdot_cli` first" % cli)
    os.makedirs(args.outdir, exist_ok=True)

    builders = []
    for op, prefix in (("vdot", ""), ("vdotacc", "vdotacc_"), ("vdot4a", "vdot4a_")):
        builders.append((prefix + "positive", "strict", op, build_positive, "positive"))
        builders.append((prefix + "negative", "strict", op, build_negative, "negative"))
        builders.append((prefix + "boundary", "strict", op, build_boundary, "boundary"))
        builders.append((prefix + "random",   "strict", op, build_random,   "random"))

    total = 0
    for name, policy, op, fn, rkey in builders:
        seed = SEEDS[name]
        rng = random.Random(seed)
        if fn is build_random:
            cases = fn(op, rng, args.random_cases)
        else:
            cases = fn(op, rng)
        results = evaluate(cli, cases, policy)
        path = os.path.join(args.outdir, name + ".txt")
        write_suite(path, name, policy, seed, cases, results, RATIONALE[rkey])
        total += len(cases)
        print("  %-22s %6d cases -> %s" % (name, len(cases), path))

    name = "vstart_relaxed"
    seed = SEEDS[name]
    rng = random.Random(seed)
    cases = build_vstart_relaxed(rng)
    results = evaluate(cli, cases, "skip")
    path = os.path.join(args.outdir, name + ".txt")
    write_suite(path, name, "skip", seed, cases, results, RATIONALE[name])
    total += len(cases)
    print("  %-22s %6d cases -> %s" % (name, len(cases), path))
    print("  total %d cases" % total)


if __name__ == "__main__":
    main()
