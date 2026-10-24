#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vcd_plot.py —— 把 VCD 里的信号渲染成「数字时序图」PNG（GTKWave 风格）

与 `vcd_extract.py` 配套：`vcd_extract.py` 负责解析与文本抽取（可机读证据），
本脚本负责把同一批信号画成评委能直接看的图（可视证据）。两者共用同一个
`vcd_extract.VCD` 解析器，所以图上画的值与文本轨迹里的值必然同源，不会打架。

渲染规则
  * 1 位信号      → 方波（高/低两档，跳变为竖直边沿）
  * 多位信号      → 六边形值框，值居中标注，跳变处收腰；相邻相同值合并成一段
  * 信号名在左侧，VCD 时刻在 x 轴
  * 纯黑白线条 + 浅灰填充，**不依赖颜色**，灰度打印与小尺寸下均可辨认

用法
  python3 scripts/tools/vcd_plot.py \
      --vcd logs/stage1/waveform/xxx.vcd --out docs/stage1/figures/fig.png \
      --from 18 --to 30 --title "标题" \
      --signal 'TOP.clock|clock' \
      --signal 'TOP.SimTop.counter|counter|dec' \
      --signal 'TOP.SimTop.viaf.vIntFixpAlu.io_out_vd|io_out_vd (vd)|hex2' \
      --concat 'updateType[15:0]|TOP...updateType_15,...,TOP...updateType_0' \
      --mark '21|in.fire' --mark '23|out.valid' \
      --span '21|23|1 个时钟周期'

信号规格（`--signal`）：`层次名|显示名|格式`，后两段可省略。
  格式： hex（默认，多位）/ hex2（128 位分两行写）/ dec / bin / wave（强制方波）
`--concat LABEL|sig_hi,...,sig_lo`：把多个窄信号按高位在前拼成一行字符串
  （每个子信号渲染成一个数字，用于 updateType_15..0 这类分散端口）。
"""

from __future__ import annotations

import argparse
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vcd_extract import VCD  # noqa: E402

# ------------------------------------------------------------------ 字体与配色
# 中文标签需要 CJK 字体；按可用性依次回退。
plt.rcParams["font.sans-serif"] = [
    "Heiti TC", "Songti SC", "STHeiti", "PingFang SC",
    "Arial Unicode MS", "Noto Sans CJK SC", "WenQuanYi Zen Hei",
    "Droid Sans Fallback", "DejaVu Sans",
]
plt.rcParams["font.monospace"] = [
    "Menlo", "DejaVu Sans Mono", "Courier New",
    "Heiti TC", "Songti SC", "Arial Unicode MS",   # 等宽字体缺中文字形时的回退
    "Noto Sans CJK SC", "WenQuanYi Zen Hei",       # Linux 上的中文回退
]
plt.rcParams["axes.unicode_minus"] = False

INK = "#000000"          # 线条：纯黑，灰度安全
BUS_FILL = "#e8e8e8"     # 值框填充：浅灰
BUS_FILL_ALT = "#ffffff" # 交替填充，便于区分相邻段
GRID = "#bfbfbf"
MARK = "#404040"

ROW_H = 1.0              # 单行逻辑高度
WAVE_PAD = 0.26          # 方波上下留白（占行高比例）


# ------------------------------------------------------------------ 信号规格
class Sig(object):
    def __init__(self, name, label=None, fmt=None, members=None):
        self.name = name
        self.label = label or name.split(".")[-1]
        self.fmt = fmt
        self.members = members      # 非 None 表示是 --concat 拼接行
        self.width = 1
        self.rows = 1               # 占几个逻辑行（hex2 占 2 行）

    @staticmethod
    def parse(spec):
        parts = spec.split("|")
        name = parts[0].strip()
        label = parts[1].strip() if len(parts) > 1 and parts[1].strip() else None
        fmt = parts[2].strip() if len(parts) > 2 and parts[2].strip() else None
        return Sig(name, label, fmt)

    @staticmethod
    def parse_concat(spec):
        parts = spec.split("|")
        if len(parts) < 2:
            raise SystemExit("--concat 需要 'LABEL|sig_hi,...,sig_lo' 形式：%s" % spec)
        label = parts[0].strip()
        members = [s.strip() for s in parts[1].split(",") if s.strip()]
        return Sig(members[0], label, "concat", members=members)


def fmt_value(sig, vcd, t):
    """返回 (文本, 是否有效)。"""
    if sig.members is not None:
        chars = []
        for m in sig.members:
            v = vcd.int_at(m, t)
            chars.append("-" if v is None else ("%x" % v))
        return "".join(chars), True
    v = vcd.int_at(sig.name, t)
    if v is None:
        return "-", False
    if sig.fmt == "dec":
        return str(v), True
    if sig.fmt == "bin":
        return format(v, "0%db" % sig.width), True
    nib = (sig.width + 3) // 4
    s = format(v, "0%dx" % nib)
    if sig.fmt == "hex2" and len(s) > 16:
        half = len(s) // 2
        return s[:half] + "\n" + s[half:], True
    return s, True


def segments(sig, vcd, t0, t1):
    """把 [t0, t1] 上的取值压成 (起点, 终点, 文本) 段；终点为开区间右端。"""
    out = []
    cur_txt, cur_start = None, t0
    for t in range(t0, t1 + 1):
        txt, _ = fmt_value(sig, vcd, t)
        if cur_txt is None:
            cur_txt, cur_start = txt, t
        elif txt != cur_txt:
            out.append((cur_start, t, cur_txt))
            cur_txt, cur_start = txt, t
    if cur_txt is not None:
        out.append((cur_start, t1 + 1, cur_txt))
    return out


# ------------------------------------------------------------------ 绘制
def draw_wave(ax, sig, vcd, t0, t1, ybase, h):
    """1 位信号：方波。"""
    lo = ybase + WAVE_PAD * h
    hi = ybase + (1.0 - WAVE_PAD) * h
    xs, ys = [], []
    prev = None
    for t in range(t0, t1 + 1):
        v = vcd.int_at(sig.name, t)
        y = hi if v else lo
        if prev is not None and y != prev:
            xs.append(t); ys.append(prev)      # 竖直边沿
        xs.append(t); ys.append(y)
        prev = y
    xs.append(t1 + 1); ys.append(prev if prev is not None else lo)
    # 先画高/低两条淡色参考轨，方波落在哪条轨上一眼可辨（常低信号不会被误读成分隔线）
    for rail in (lo, hi):
        ax.plot([t0, t1 + 1], [rail, rail], color=GRID, lw=0.6, ls=":", zorder=1)
    ax.plot(xs, ys, color=INK, lw=1.5, solid_joinstyle="miter", zorder=3)


def draw_bus(ax, sig, vcd, t0, t1, ybase, h, ax_w_pts, span_t, idx_offset=0):
    """多位信号：六边形值框 + 居中文本。"""
    lo = ybase + WAVE_PAD * 0.55 * h
    hi = ybase + (1.0 - WAVE_PAD * 0.55) * h
    mid = (lo + hi) / 2.0
    k = min(0.22, 0.35 * (t1 - t0) / max(1, span_t))   # 收腰宽度（时间单位）
    segs = segments(sig, vcd, t0, t1)
    for i, (a, b, txt) in enumerate(segs):
        ka = k if a > t0 else 0.0
        kb = k if b <= t1 else 0.0
        poly = [(a, mid), (a + ka, hi), (b - kb, hi), (b, mid),
                (b - kb, lo), (a + ka, lo)]
        ax.add_patch(Polygon(poly, closed=True,
                             facecolor=BUS_FILL if (i + idx_offset) % 2 == 0 else BUS_FILL_ALT,
                             edgecolor=INK, lw=1.3, zorder=3))
        # 字号：按段宽自适应（等宽字体，字符宽 ≈ 0.6 em）
        avail = ax_w_pts * (b - a) / float(span_t) - 4.0
        nchar = max(len(l) for l in txt.split("\n"))
        nline = len(txt.split("\n"))
        size = 7.6 if nline == 1 else 6.4
        if nchar > 0:
            size = min(size, avail / (0.62 * nchar))
        shown = txt
        if size < 4.2:
            size = 4.2
            maxc = max(1, int(avail / (0.62 * size)))
            if nchar > maxc:
                shown = "\n".join(l[:max(1, maxc - 1)] + "…" for l in txt.split("\n"))
        ax.text((a + b) / 2.0, mid, shown, ha="center", va="center",
                fontsize=size, family="monospace", color=INK, zorder=4,
                linespacing=1.05)


def render(args):
    sigs = [Sig.parse(s) for s in (args.signal or [])]
    concats = [Sig.parse_concat(s) for s in (args.concat or [])]
    # --signal / --concat 按命令行给出的顺序混排：用 order 标记
    ordered = []
    si, ci = 0, 0
    for kind in args._order:
        if kind == "s":
            ordered.append(sigs[si]); si += 1
        else:
            ordered.append(concats[ci]); ci += 1
    if not ordered:
        raise SystemExit("至少要给一个 --signal 或 --concat")

    wanted = set()
    for s in ordered:
        if s.members:
            wanted.update(s.members)
        else:
            wanted.add(s.name)
    vcd = VCD(args.vcd, wanted=wanted)

    missing = [n for n in wanted if n not in vcd.name2id]
    if missing:
        raise SystemExit("VCD 中找不到这些信号：\n  " + "\n  ".join(sorted(missing)))

    for s in ordered:
        if s.members:
            s.width = 0
            s.rows = 1
        else:
            s.width = vcd.id2width[vcd.name2id[s.name]]
            if s.fmt is None:
                s.fmt = "wave" if s.width == 1 else "hex"
            if s.fmt == "hex2":
                s.rows = 2

    t0, t1 = args.t_from, args.t_to
    span_t = (t1 + 1) - t0
    total_rows = sum(s.rows for s in ordered)

    # 版面：按英寸算好上下留白，避免标题 / 标记 / 区间箭头互相压字
    n_mark = len(args.mark or [])
    n_span = len(args.span or [])
    row_in = 0.40
    plot_in = row_in * total_rows
    bottom_in = 0.66                                   # x 轴刻度 + 轴标题
    top_in = (0.30 if args.title else 0.04) \
             + (0.34 if n_mark else 0.04) \
             + (0.21 * n_span + 0.14 if n_span else 0.0) \
             + (0.18 if args.subtitle else 0.0)
    fig_w = args.width
    fig_h = plot_in + bottom_in + top_in
    fig, ax = plt.subplots(figsize=(fig_w, fig_h))
    fig.subplots_adjust(left=args.left, right=0.985,
                        top=1.0 - top_in / fig_h, bottom=bottom_in / fig_h)

    # 行的 y 基线：第一个信号在最上面
    ybases, ylabels, yticks = [], [], []
    y = 0.0
    layout = []
    for s in reversed(ordered):
        layout.append((s, y))
        yticks.append(y + s.rows * ROW_H / 2.0)
        ylabels.append(s.label)
        y += s.rows * ROW_H
    total_h = y

    ax.set_xlim(t0, t1 + 1)
    ax.set_ylim(0, total_h)
    ax.set_yticks(yticks)
    ax.set_yticklabels(ylabels, fontsize=8.2, family="monospace")
    # 含中日韩字符的标签改用无衬线族（等宽字体通常没有中文字形，会渲染成豆腐块）
    for lab, text in zip(ax.get_yticklabels(), ylabels):
        if any(ord(ch) > 0x2E7F for ch in text):
            lab.set_fontfamily("sans-serif")
    ax.tick_params(axis="y", length=0, pad=4)
    for sp in ("top", "right", "left"):
        ax.spines[sp].set_visible(False)
    ax.spines["bottom"].set_color(INK)

    # 竖向网格 = 每个 VCD 时刻
    for t in range(t0, t1 + 2):
        ax.axvline(t, color=GRID, lw=0.5, ls="-", zorder=0)
    # 行分隔
    for (_, yb) in layout:
        ax.axhline(yb, color=GRID, lw=0.35, zorder=0)

    ax_w_pts = fig_w * 72.0 * (0.985 - args.left)
    for i, (s, yb) in enumerate(layout):
        h = s.rows * ROW_H
        if s.fmt == "wave":
            draw_wave(ax, s, vcd, t0, t1, yb, h)
        else:
            draw_bus(ax, s, vcd, t0, t1, yb, h, ax_w_pts, span_t, idx_offset=i)

    # x 轴刻度：VCD 时刻，刻度标在格子中心
    xt = list(range(t0, t1 + 1))
    ax.set_xticks([t + 0.5 for t in xt])
    ax.set_xticklabels(["#%d" % t for t in xt], fontsize=7.4, family="monospace")
    ax.set_xlabel(args.xlabel, fontsize=8.2)

    # 标记线
    for spec in (args.mark or []):
        p = spec.split("|")
        t = int(p[0])
        lab = p[1] if len(p) > 1 else ""
        ax.axvline(t + 0.5, color=MARK, lw=1.2, ls=(0, (4, 2)), zorder=5)
        ax.annotate(lab, xy=(t + 0.5, total_h), xytext=(t + 0.5, total_h + 0.30),
                    ha="center", va="bottom", fontsize=8.0, color=INK,
                    annotation_clip=False,
                    arrowprops=dict(arrowstyle="-|>", color=MARK, lw=1.0,
                                    shrinkA=0, shrinkB=0))

    # 区间标注（双箭头），叠在标记线之上
    span_base = total_h + (0.85 if n_mark else 0.25)
    for j, spec in enumerate(args.span or []):
        p = spec.split("|")
        a, b = int(p[0]) + 0.5, int(p[1]) + 0.5
        lab = p[2] if len(p) > 2 else ""
        yy = span_base + 0.52 * j
        ax.annotate("", xy=(a, yy), xytext=(b, yy), annotation_clip=False,
                    arrowprops=dict(arrowstyle="<|-|>", color=INK, lw=1.1,
                                    shrinkA=0, shrinkB=0))
        ax.text((a + b) / 2.0, yy + 0.06, lab, ha="center", va="bottom",
                fontsize=8.4, color=INK, clip_on=False)

    y_cursor = 1.0
    if args.title:
        y_cursor -= 0.26 / fig_h
        fig.text(0.5, y_cursor, args.title, ha="center", va="bottom",
                 fontsize=10.6)
    if args.subtitle:
        y_cursor -= 0.16 / fig_h
        fig.text(0.5, y_cursor, args.subtitle, ha="center", va="bottom",
                 fontsize=7.8, color="#333333")

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    fig.savefig(args.out, dpi=args.dpi, facecolor="white")
    plt.close(fig)
    print("wrote %s  (%d 行信号, 时刻 #%d..#%d, %d dpi)"
          % (args.out, total_rows, t0, t1, args.dpi))


class OrderedAction(argparse.Action):
    """记录 --signal / --concat 的相对顺序。"""
    def __call__(self, parser, ns, values, option_string=None):
        items = getattr(ns, self.dest) or []
        items.append(values)
        setattr(ns, self.dest, items)
        order = getattr(ns, "_order", None) or []
        order.append("s" if self.dest == "signal" else "c")
        setattr(ns, "_order", order)


def main():
    ap = argparse.ArgumentParser(
        description="把 VCD 信号渲染成数字时序图 PNG",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vcd", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--from", dest="t_from", type=int, required=True, help="起始 VCD 时刻")
    ap.add_argument("--to", dest="t_to", type=int, required=True, help="结束 VCD 时刻（含）")
    ap.add_argument("--signal", action=OrderedAction, default=[],
                    help="'层次名|显示名|格式'，可重复")
    ap.add_argument("--concat", action=OrderedAction, default=[],
                    help="'显示名|sig_hi,...,sig_lo'，可重复")
    ap.add_argument("--mark", action="append", default=[], help="'时刻|标签'")
    ap.add_argument("--span", action="append", default=[], help="'时刻a|时刻b|标签'")
    ap.add_argument("--title", default="")
    ap.add_argument("--subtitle", default="")
    ap.add_argument("--xlabel", default="VCD 时刻（偶数 = clock 低、已写入新激励；奇数 = clock 高、上升沿之后）")
    ap.add_argument("--width", type=float, default=13.0, help="图宽（英寸）")
    ap.add_argument("--left", type=float, default=0.17, help="左侧信号名栏占比")
    ap.add_argument("--dpi", type=int, default=200)
    args = ap.parse_args()
    if not hasattr(args, "_order"):
        args._order = []
    if args.t_to < args.t_from:
        raise SystemExit("--to 必须 >= --from")
    render(args)


if __name__ == "__main__":
    main()
