#!/usr/bin/env python3
"""Assemble the Markdown of one technical volume from docs/stage{1,2,3}/*.md.

The stage documents stay the single source; this only concatenates them in file order and makes
image paths absolute (several stage directories contain a figures/fig1_*.png). Text and numbers are
not changed. The cover and the table of contents come from template.html (pandoc --toc).
Writes <out.md> and prints the cover fields as KEY=VALUE lines for build-pdf.sh.
Usage: assemble.py <repo_root> <1|2|3> <out.md>
"""
import re
import sys
from pathlib import Path

root, vol, out = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])

VOLS = {
    "1": ("第一册", "阶段一：环境部署与 vadd.vv 执行过程分析", "stage1",
          "环境版本锁定、环境部署（NEMU / 工具链 / hello 验证）、vadd.vv 在昆明湖 V2 中的执行过程分析（FU 级波形 + 源码级论证 + 全核时刻锚点）、仿真平台搭建（L0 + L1）"),
    "2": ("第二册", "阶段二：vdot 指令设计、RTL 实现与基础功能测试", "stage2",
          "vdot 指令族规范与微架构设计（含赛题官方伪代码逐行对照与裁定 S-3'）、RTL 实现说明、正数 / 负数 / 边界值基础功能测试报告、参考模型与测试向量说明"),
    "3": ("第三册", "阶段三：NEMU 扩展、协同仿真与延迟加速比分析", "stage3",
          "NEMU 指令扩展、NEMU↔RTL 协同仿真（Level 1）、RVV 1.0 基线实现与延迟加速比分析、MinimalConfig 全核 difftest（Level 2）"),
}
vno, vtitle, sdir, scope = VOLS[vol]


docs = sorted((root / "docs" / sdir).glob("[0-9][0-9]_*.md"))
assert docs, sdir
# cover fields consumed by template.html (pandoc -V); printed by build-pdf.sh as KEY=VALUE lines
meta = {"volno": vno, "voltitle": vtitle, "scope": scope, "contents": "；".join(d.stem for d in docs)}
parts = []


def absimg(text, base):
    def rep(m):
        target = m.group(2)
        if re.match(r"[a-z]+://", target) or target.startswith("/"):
            return m.group(0)
        p = (base / target).resolve()
        assert p.is_file(), f"missing image {p}"
        return f"![{m.group(1)}]({p})"
    return re.sub(r"!\[([^\]]*)\]\(([^)\s]+)\)", rep, text)


for d in docs:
    parts.append(absimg(d.read_text(encoding="utf-8"), d.parent))
out.write_text("\n\n".join(p.rstrip() + "\n" for p in parts), encoding="utf-8")
for k, v in meta.items():
    print(f"{k}={v}")
