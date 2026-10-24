#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_funct6.py —— OPIVV funct6 编码空间占用枚举与冲突检查

用途
    证明 vdot 指令族拟用的 funct6（111001 / 111010 / 111011）在目标代码树
    （XiangShan kunminghu-v2 + rocket-chip 子模块）已实现的 RVV 1.0 / Zvbb
    指令集合中未被占用。

方法
    扫描所有 Scala 源文件中形如
        def <NAME> = BitPat("b<32 位 0/1/? 串>")
    的指令位模式声明，按 RVV 的 OP-V 位域切分：
        [31:26] funct6   [25] vm   [24:20] vs2   [19:15] vs1
        [14:12] funct3   [11:7] vd  [6:0] opcode
    筛选 opcode == 1010111（OP-V）的条目，按 funct3 分组统计。
    funct3 = 000 即 OPIVV，是本设计使用的子空间。

输出
    - 每个 funct3 子空间的已占用 funct6 列表（含指令名）
    - OPIVV 空闲 funct6 全集
    - 对三条目标指令逐条给出 FREE / TAKEN 判定；任一 TAKEN 则退出码非 0

用法
    python3 scripts/tools/check_funct6.py [XiangShan 仓库根目录]
    默认根目录 work/XiangShan-kmhv2（相对本仓库根）
"""

import os
import re
import sys

# ---- 被检查的目标编码（与 MASTER_PLAN D2 一致） -----------------------------
TARGETS = [
    ("111001", "vdot.vv"),
    ("111010", "vdotacc.vv"),
    ("111011", "vdot4a.vv"),
]

OPV_OPCODE = "1010111"
FUNCT3_NAME = {
    "000": "OPIVV", "001": "OPFVV", "010": "OPMVV", "011": "OPIVI",
    "100": "OPIVX", "101": "OPFVF", "110": "OPMVX", "111": "OPCFG",
}

# def NAME = BitPat("b....")  —— 允许 def 前有修饰符、等号两侧任意空白
PAT = re.compile(r'def\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*BitPat\(\s*"b([01?]{32})"\s*\)')

# 只扫描真正包含指令位模式的文件，避免把注释/测试里的字符串算进来
SCAN_FILES = [
    "rocket-chip/src/main/scala/rocket/Instructions.scala",
    "src/main/scala/xiangshan/backend/decode/Instructions.scala",
]
# 兜底：全树扫描（用于发现新增的自定义指令文件）
SCAN_TREE_DIRS = [
    "src/main/scala",
    "rocket-chip/src/main/scala",
    "yunsuan/src/main/scala",
]


def iter_scala_files(root):
    seen = set()
    for rel in SCAN_FILES:
        p = os.path.join(root, rel)
        if os.path.isfile(p):
            seen.add(os.path.realpath(p))
            yield p
    for d in SCAN_TREE_DIRS:
        base = os.path.join(root, d)
        for dirpath, _dirnames, filenames in os.walk(base):
            for fn in filenames:
                if not fn.endswith(".scala"):
                    continue
                p = os.path.join(dirpath, fn)
                rp = os.path.realpath(p)
                if rp in seen:
                    continue
                seen.add(rp)
                yield p


def collect(root):
    """返回 {funct3: {funct6: set(指令名)}} 与扫描到的文件数/位模式数"""
    table = {}
    n_files = 0
    n_pats = 0
    for path in iter_scala_files(root):
        n_files += 1
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        for name, bits in PAT.findall(text):
            n_pats += 1
            opcode = bits[25:32]
            if opcode != OPV_OPCODE:
                continue
            funct6 = bits[0:6]
            funct3 = bits[17:20]
            if "?" in funct6:
                # funct6 含通配位：展开成全部具体取值，保守记为已占用
                expand = [""]
                for ch in funct6:
                    if ch == "?":
                        expand = [p + "0" for p in expand] + [p + "1" for p in expand]
                    else:
                        expand = [p + ch for p in expand]
            else:
                expand = [funct6]
            for f6 in expand:
                for f3 in (["000", "001", "010", "011", "100", "101", "110", "111"]
                           if "?" in funct3 else [funct3]):
                    if "?" in funct3 and not _f3_match(funct3, f3):
                        continue
                    table.setdefault(f3, {}).setdefault(f6, set()).add(name)
    return table, n_files, n_pats


def _f3_match(pat, val):
    return all(p == "?" or p == v for p, v in zip(pat, val))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.abspath(os.path.join(here, "..", ".."))
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        repo_root, "work", "XiangShan-kmhv2")
    root = os.path.abspath(root)

    print("=" * 72)
    print("OPIVV funct6 编码空间占用检查")
    print("=" * 72)
    print("代码树根目录 : %s" % root)
    if not os.path.isdir(root):
        print("错误：目录不存在")
        return 2

    table, n_files, n_pats = collect(root)
    print("扫描 .scala  : %d 个文件，%d 条 BitPat 指令位模式" % (n_files, n_pats))
    print("")

    for f3 in sorted(table.keys()):
        occ = table[f3]
        print("-- funct3=%s (%-5s)  已占用 funct6 共 %d 个 --"
              % (f3, FUNCT3_NAME.get(f3, "?"), len(occ)))
        if f3 != "000":
            print("   %s" % " ".join(sorted(occ.keys())))
            print("")
            continue
        for f6 in sorted(occ.keys()):
            print("   %s  %s" % (f6, ", ".join(sorted(occ[f6]))))
        print("")

    opivv = table.get("000", {})
    allf6 = ["{:06b}".format(i) for i in range(64)]
    free = [f for f in allf6 if f not in opivv]
    print("-- OPIVV 空闲 funct6 共 %d 个 --" % len(free))
    for i in range(0, len(free), 9):
        print("   " + " ".join(free[i:i + 9]))
    print("")

    print("-- 目标编码判定 --")
    bad = 0
    for f6, mnem in TARGETS:
        if f6 in opivv:
            print("   funct6=%s  %-12s  TAKEN  <-- 冲突：%s"
                  % (f6, mnem, ", ".join(sorted(opivv[f6]))))
            bad += 1
        else:
            print("   funct6=%s  %-12s  FREE" % (f6, mnem))
    print("")
    if bad:
        print("结论：存在 %d 处冲突，必须改用其它编码。" % bad)
        return 1
    print("结论：三条 vdot 指令的 funct6 在本代码树 OPIVV 空间内全部空闲。")
    print("注意：本检查覆盖范围 = 本代码树已实现的指令集合（RVV 1.0 + Zvbb）；")
    print("      对尚未实现的外部扩展（如 Zvdot4a8i 草案）不构成证明。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
