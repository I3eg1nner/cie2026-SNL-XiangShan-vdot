#!/usr/bin/env python3
"""
plot_results.py —— 由 bench/results/*.csv 生成报告用图表

设计约束（刻意遵守，避免「图表骗人」）：
  * 单一 y 轴，y 轴从 0 起（加速比图），绝不用双 y 轴放大差距；
  * 每根柱子都在图例里注明是「实测」还是「建模」；
  * 灰度可读：颜色全部取自灰阶，且每个系列再叠一种填充花纹，
    黑白打印/复印后仍能区分；
  * 坐标轴标题带单位。

用法： python3 bench/plot_results.py --results bench/results --out docs/stage3/figures
"""
import argparse
import csv
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

# 中日韩字体候选：前四个为 macOS 自带，后三个为常见 Linux 发行版字体
# （python3 -c "import matplotlib.font_manager" 可查）
plt.rcParams["font.sans-serif"] = ["Arial Unicode MS", "Hiragino Sans GB",
                                   "STHeiti", "Songti SC",
                                   "Noto Sans CJK SC", "WenQuanYi Zen Hei",
                                   "Droid Sans Fallback", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False
plt.rcParams["figure.dpi"] = 150
plt.rcParams["savefig.dpi"] = 150
plt.rcParams["axes.grid"] = True
plt.rcParams["grid.alpha"] = 0.3
plt.rcParams["grid.linestyle"] = ":"

# 灰阶 + 花纹：黑白打印仍可区分
STYLE = [
    ("#ffffff", "///"),
    ("#cfcfcf", "\\\\\\"),
    ("#9a9a9a", ""),
    ("#5f5f5f", "xxx"),
    ("#2b2b2b", "..."),
]


def rd(path):
    with open(path, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def fig_instr_count(res, out):
    rows = rd(os.path.join(res, "instr_count_loop.csv"))
    kerns, Ns = [], []
    for r in rows:
        if r["kernel"] not in kerns:
            kerns.append(r["kernel"])
        n = int(r["N_int8"])
        if n not in Ns:
            Ns.append(n)
    Ns.sort()
    data = {(r["kernel"], int(r["N_int8"])): int(r["instr_retired_measured"]) for r in rows}
    slope = {r["kernel"]: float(r["instr_per_iteration_slope"]) for r in rows
             if r["instr_per_iteration_slope"]}

    label = {"baseline_A": "基线 A (vwmul+vwredsum，归约在循环内)",
             "baseline_B": "基线 B (vsext.vf4 x2 + vmacc)",
             "baseline_D": "基线 D (vwmul+vwadd.wv) ← 选定基线",
             "vdotacc":    "vdotacc.vv (本方案)",
             "vdot4a":     "vdot4a.vv (本方案)",
             "vdotacc_acc2": "vdotacc.vv 2 路累加器 (本方案)"}

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13.5, 5.2),
                                   gridspec_kw={"width_ratios": [1.45, 1]})
    nk = len(kerns)
    bw = 0.8 / nk
    xs = range(len(Ns))
    for i, k in enumerate(kerns):
        c, h = STYLE[i % len(STYLE)]
        vals = [data[(k, n)] for n in Ns]
        pos = [x - 0.4 + bw * (i + 0.5) for x in xs]
        ax1.bar(pos, vals, bw, color=c, hatch=h, edgecolor="black", linewidth=0.7,
                label=label.get(k, k))
        for p, v in zip(pos, vals):
            ax1.text(p, v * 1.06, str(v), ha="center", va="bottom", fontsize=6.5,
                     rotation=90)
    ax1.set_yscale("log")
    ax1.set_xticks(list(xs))
    ax1.set_xticklabels([str(n) for n in Ns])
    ax1.set_xlabel("向量长度 N（int8 元素个数）")
    ax1.set_ylabel("动态执行指令数（条，对数刻度）")
    ax1.set_title("(a) 长向量点积：NEMU 实测动态指令总数\n全部为实测值（CSR minstret）",
                  fontsize=10)
    ax1.set_ylim(20, 8000)
    ax1.legend(fontsize=7.5, loc="upper left")

    ks = [k for k in kerns if k in slope]
    vals = [slope[k] for k in ks]
    ypos = range(len(ks))
    for i, (k, v) in enumerate(zip(ks, vals)):
        c, h = STYLE[kerns.index(k) % len(STYLE)]
        ax2.barh(i, v, 0.6, color=c, hatch=h, edgecolor="black", linewidth=0.7)
        ax2.text(v + 0.12, i, "%.1f" % v, va="center", fontsize=9)
    ax2.set_yticks(list(ypos))
    ax2.set_yticklabels(ks, fontsize=8)
    ax2.invert_yaxis()
    ax2.set_xlabel("每处理 16 个 int8 的指令数（条/迭代）")
    ax2.set_title("(b) 稳态循环体指令数\n由 (a) 四个数据点线性回归得到，仍是实测量",
                  fontsize=10)
    ax2.set_xlim(0, max(vals) * 1.25)

    fig.suptitle("图 1  RVV 1.0 基线 vs vdot 指令族：指令条数对比（NEMU 实测）",
                 fontsize=12, y=0.99)
    fig.tight_layout(rect=(0, 0, 1, 0.95))
    p = os.path.join(out, "fig1_instr_count.png")
    fig.savefig(p)
    plt.close(fig)
    return p


def fig_speedup(res, out):
    rows = rd(os.path.join(res, "instr_count_loop.csv"))
    data = {(r["kernel"], int(r["N_int8"])): int(r["instr_retired_measured"]) for r in rows}
    Ns = sorted(set(int(r["N_int8"]) for r in rows))
    slope = {r["kernel"]: float(r["instr_per_iteration_slope"]) for r in rows
             if r["instr_per_iteration_slope"]}

    sp_D = [data[("baseline_D", n)] / data[("vdotacc", n)] for n in Ns]
    sp_A = [data[("baseline_A", n)] / data[("vdotacc", n)] for n in Ns]
    sp_4 = [data[("baseline_D", n)] / data[("vdot4a", n)] for n in Ns]
    # 建模：稳态每迭代指令数之比（N -> 无穷 的渐近值）
    asym = slope["baseline_D"] / slope["vdotacc"] if slope.get("vdotacc") else None

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13.5, 5.2))
    xs = range(len(Ns))
    series = [("基线 D / vdotacc（实测指令数之比）", sp_D, 0, "-", "o", 9),
              ("基线 A / vdotacc（实测指令数之比）", sp_A, 1, "-", "s", -15),
              ("基线 D / vdot4a （实测指令数之比）", sp_4, 2, "-", "^", -15)]
    for name, ys, i, ls, mk, dy in series:
        c, _ = STYLE[i + 1]
        ax1.plot(list(xs), ys, ls, marker=mk, color="black", markerfacecolor=c,
                 markersize=7, linewidth=1.4, label=name)
        for x, y in zip(xs, ys):
            ax1.annotate("%.3f" % y, (x, y), textcoords="offset points",
                         xytext=(0, dy), ha="center", fontsize=7)
    if asym:
        ax1.axhline(asym, color="black", linestyle="--", linewidth=1.2,
                    label="稳态渐近值 %.3f（建模：斜率之比）" % asym)
    ax1.axhline(1.0, color="black", linestyle=":", linewidth=1.0)
    ax1.text(0.35, 0.97, "1.0 = 没有加速", fontsize=7.5, va="top")
    ax1.set_xticks(list(xs))
    ax1.set_xticklabels([str(n) for n in Ns])
    ax1.set_xlabel("向量长度 N（int8 元素个数）")
    ax1.set_ylabel("加速比（倍，基线指令数 ÷ vdot 指令数）")
    ax1.set_ylim(0, 1.6)
    ax1.set_title("(a) 指令条数口径的加速比 vs N\n实线=实测；虚线=由实测斜率外推的稳态值",
                  fontsize=10)
    ax1.legend(fontsize=7.5, loc="lower right")

    # (b) 单次点积的多口径加速比
    sp = rd(os.path.join(res, "speedup.csv"))
    single = [r for r in sp if r["case"].startswith("单次点积")]
    names = [r["metric"].split(" (")[0] for r in single]
    vals = [float(r["speedup"]) for r in single]
    kinds = [r["kind"] for r in single]
    for i, (nm, v, kd) in enumerate(zip(names, vals, kinds)):
        c, h = (("#9a9a9a", "") if kd == "实测" else ("#ffffff", "///"))
        ax2.barh(i, v, 0.6, color=c, hatch=h, edgecolor="black", linewidth=0.8)
        ax2.text(v + 0.1, i, "%.2fx  [%s]" % (v, kd), va="center", fontsize=8.5)
    ax2.set_yticks(range(len(names)))
    ax2.set_yticklabels(names, fontsize=8.5)
    ax2.invert_yaxis()
    ax2.set_xlim(0, max(vals) * 1.45)
    ax2.set_xlabel("加速比（倍）")
    ax2.set_title("(b) 单次 16 元素点积的四种口径\n注意四根柱子量纲不同，不可互相替代",
                  fontsize=10)
    ax2.legend(handles=[Patch(facecolor="#9a9a9a", edgecolor="black", label="实测"),
                        Patch(facecolor="#ffffff", hatch="///", edgecolor="black",
                              label="建模/源码推导")],
               fontsize=8, loc="upper right")

    fig.suptitle("图 2  加速比：实测口径与建模口径分开呈现", fontsize=12, y=0.99)
    fig.tight_layout(rect=(0, 0, 1, 0.95))
    p = os.path.join(out, "fig2_speedup.png")
    fig.savefig(p)
    plt.close(fig)
    return p


def fig_latency(res, out):
    rows = rd(os.path.join(res, "latency_fu.csv"))
    names, dec, mea, kinds = [], [], [], []
    for r in rows:
        names.append(r["instruction"])
        dec.append(int(r["declared_latency_cycles"]))
        mea.append(int(r["measured_latency_cycles"]) if r["measured_latency_cycles"] else None)
        kinds.append(r["kind"])

    fig, ax = plt.subplots(figsize=(11.5, 4.6))
    xs = range(len(names))
    ax.bar([x - 0.2 for x in xs], dec, 0.38, color="#ffffff", hatch="///",
           edgecolor="black", linewidth=0.8, label="声明值（FuConfig.scala）")
    mx = [x + 0.2 for x, m in zip(xs, mea) if m is not None]
    mv = [m for m in mea if m is not None]
    ax.bar(mx, mv, 0.38, color="#5f5f5f", edgecolor="black", linewidth=0.8,
           label="实测值（Verilator FU 直驱：按数据成形拍判定，非 out.valid）")
    for x, d in zip(xs, dec):
        ax.text(x - 0.2, d + 0.06, str(d), ha="center", fontsize=8)
    for x, m in zip(xs, mea):
        if m is None:
            ax.text(x + 0.2, 0.06, "未实测", ha="center", fontsize=7.5, rotation=90)
        else:
            ax.text(x + 0.2, m + 0.06, str(m), ha="center", fontsize=8, color="black")
    ax.set_xticks(list(xs))
    ax.set_xticklabels(names, rotation=30, ha="right", fontsize=9)
    ax.set_ylabel("功能单元延迟（时钟周期）")
    ax.set_ylim(0, 2.9)
    ax.set_title("图 3  功能单元延迟：声明值 vs 实测值\n"
                 "vdot 三条指令与既有 vmul/vwmul/vmacc 的数据均在第 2 拍成形（第 1 拍未成形、第 2 拍正确）",
                 fontsize=11)
    ax.legend(fontsize=8.5, loc="upper left")
    fig.tight_layout()
    p = os.path.join(out, "fig3_latency.png")
    fig.savefig(p)
    plt.close(fig)
    return p


def fig_sensitivity(res, out):
    rows = rd(os.path.join(res, "sensitivity.csv"))
    names = [r["scenario"] for r in rows]
    vals = [float(r["speedup"]) for r in rows]
    fig, ax = plt.subplots(figsize=(10.5, 4.8))
    for i, v in enumerate(vals):
        c, h = ("#5f5f5f", "") if i == 0 else ("#ffffff", "///")
        ax.barh(i, v, 0.62, color=c, hatch=h, edgecolor="black", linewidth=0.8)
        ax.text(v + 0.03, i, "%.2fx" % v, va="center", fontsize=9)
    ax.axvline(1.0, color="black", linestyle=":", linewidth=1.0)
    ax.set_yticks(range(len(names)))
    ax.set_yticklabels(names, fontsize=8.5)
    ax.invert_yaxis()
    ax.set_xlim(0, max(vals) * 1.3)
    ax.set_xlabel("单次点积的 FU 延迟关键路径加速比（倍）")
    ax.set_title("图 4  敏感性分析：加速比在不同假设下的取值\n"
                 "深色=基准情形（用实测 FU 延迟）；浅色斜纹=改变假设后的建模值",
                 fontsize=11)
    fig.tight_layout()
    p = os.path.join(out, "fig4_sensitivity.png")
    fig.savefig(p)
    plt.close(fig)
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default="bench/results")
    ap.add_argument("--out", default="docs/stage3/figures")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    made = []
    for f in (fig_instr_count, fig_speedup, fig_latency, fig_sensitivity):
        made.append(f(a.results, a.out))
    for p in made:
        print("  PNG %s  (%d bytes)" % (p, os.path.getsize(p)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
