#!/usr/bin/env python3
"""verilog_module_diff.py —— 逐 module 比较两份 Verilog，证明「既有模块一行没动」。

用法：
    python3 scripts/tools/verilog_module_diff.py <基线.v> <改动后.v>

做法：把每个文件切成 `module X ... endmodule` 片段，去掉行尾注释（firtool 会在注释里
写源码行号，插入几行 Scala 就会整体平移，不是真正的逻辑差异），再逐 module 比较文本。
输出三类：两边都有且逐字节相同 / 两边都有但不同 / 只在一边出现。
"""
import re
import sys


def split_modules(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    text = re.sub(r"//[^\n]*", "", text)        # 去掉行尾注释（含源码行号）
    mods, cur, buf = {}, None, []
    for line in text.split("\n"):
        m = re.match(r"\s*module\s+(\w+)", line)
        if m:
            cur, buf = m.group(1), [line.rstrip()]
            continue
        if cur is not None:
            buf.append(line.rstrip())
            if re.match(r"\s*endmodule", line):
                mods[cur] = "\n".join(buf)
                cur = None
    return mods


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    base, new = sys.argv[1], sys.argv[2]
    a, b = split_modules(base), split_modules(new)
    common = sorted(set(a) & set(b))
    same = [m for m in common if a[m] == b[m]]
    diff = [m for m in common if a[m] != b[m]]
    only_new = sorted(set(b) - set(a))
    only_old = sorted(set(a) - set(b))
    print(f"    基线   : {base}  ({len(a)} 个 module)")
    print(f"    改动后 : {new}  ({len(b)} 个 module)")
    print(f"    共有 module                 : {len(common)}")
    print(f"    其中去注释后逐字节相同      : {len(same)}")
    print(f"    其中存在差异                : {len(diff)}  {diff if diff else ''}")
    print(f"    仅出现在改动后（新增模块）  : {len(only_new)}  {only_new if only_new else ''}")
    print(f"    仅出现在基线（被删除模块）  : {len(only_old)}  {only_old if only_old else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
