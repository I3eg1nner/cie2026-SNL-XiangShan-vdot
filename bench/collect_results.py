#!/usr/bin/env python3
"""
collect_results.py —— 把 P7 两份真实运行日志解析成 bench/results/*.csv

输入（都由脚本产生，不接受手工编辑的日志）：
  logs/stage3/p7_baseline_equiv.log    NEMU 上的等价性验证 + minstret 实测指令数（scripts/40_run_bench.sh）
  logs/stage3/p7_latency_measure.log   波形事务表 + 三个 FU harness 的延迟实测（scripts/40_run_bench.sh）
  logs/stage3/fullcore/perf_cycles.log 全核 MinimalConfig emu 上的 mcycle / minstret 实测
                                       （可选，scripts/50_run_fullcore_difftest.sh perf）
源码（只读，用于静态计数，不是常量表）：
  tests/riscv/fullcore/perf_kernels.S  单次点积序列本体 BASE_BODY / VDOT_BODY 两个宏
  bench/baseline/baseline_rvv.S        核对 BASE_BODY 与交付件中的序列本体逐条相同

输出（bench/results/）：
  equivalence.csv        每个 suite 的用例数 / 通过数 / 跳过数（实测）
  latency_fu.csv         每条指令的功能单元延迟：实测值 + 声明值 + 证据出处
  instr_count_loop.csv   长向量循环的动态指令数（实测）与每次迭代的回归斜率
  instr_count_single.csv 单次 16 元素点积的指令数（长表：每个数值单独标注来源）
  cycles_fullcore.csv    全核 MinimalConfig 周期实测（有 --fullcore-perf-log 时生成）
  uop_count.csv          译码级 uop 条数（源码推导，非实测，逐条标注出处）
  critical_path.csv      依赖链关键路径（用实测 FU 延迟拼出的建模值）
  speedup.csv            各口径的加速比
  sensitivity.csv        敏感性分析

每张表都有 `kind` 列，以「实测 / 声明值 / 建模估算 / 源码推导 / 静态计数」开头，
括号里注明平台（NEMU、全核 MinimalConfig 等）。
"""
import argparse
import csv
import os
import re
import sys

# ---------------------------------------------------------------------------
# 常量：全部来自香山源码，逐条标注 文件:行号。kind 一律为「声明值」或「源码推导」。
# ---------------------------------------------------------------------------
FU_DECLARED = {
    # instruction -> (FuType, FuConfig 名, 声明延迟, 证据)
    "vsetvli":     ("vsetiwi/vsetiwf", "VSetRiWiCfg / VSetRiWvfCfg", 0,
                    "FuConfig.scala:415 / FuConfig.scala:402"),
    "vmv.s.x":     ("vialuF", "VialuCfg", 1, "FuConfig.scala:544"),
    "vwmul.vv":    ("vimac",  "VimacCfg", 2, "FuConfig.scala:563"),
    "vwadd.wv":    ("vialuF", "VialuCfg", 1, "FuConfig.scala:544"),
    "vwredsum.vs": ("vipu",   "VipuCfg",  2, "FuConfig.scala:615"),
    "vredsum.vs":  ("vipu",   "VipuCfg",  2, "FuConfig.scala:615"),
    "vadd.vv":     ("vialuF", "VialuCfg", 1, "FuConfig.scala:544"),
    "vmul.vv":     ("vimac",  "VimacCfg", 2, "FuConfig.scala:563"),
    "vmacc.vv":    ("vimac",  "VimacCfg", 2, "FuConfig.scala:563"),
    "vdot.vv":     ("vimac",  "VimacCfg", 2, "FuConfig.scala:563"),
    "vdotacc.vv":  ("vimac",  "VimacCfg", 2, "FuConfig.scala:563"),
    "vdot4a.vv":   ("vimac",  "VimacCfg", 2, "FuConfig.scala:563"),
}

# 每条指令能在哪几个执行单元上发射（Parameters.scala:409 / 449-456）
FU_PORTS = {
    "vsetiwi/vsetiwf": ("BJU2", 1, "Parameters.scala:409"),
    "vialuF":          ("VFEX0, VFEX2", 2, "Parameters.scala:449,453"),
    "vimac":           ("VFEX0", 1, "Parameters.scala:449"),
    "vipu":            ("VFEX1", 1, "Parameters.scala:450"),
}

# 译码级 uop 条数（LMUL 按各指令在基线序列里实际使用的值）
# 全部来自 UopInfoGen.scala:197-235 的 numOfUop MuxLookup + VecDecoder.scala 的 UopSplitType
# VecDecoder 行号：先给上游 pristine 树，括号内为打了 rtl/patch/0001 的实现树（补丁插入 vdot 三行导致后移）
UOPS = [
    # instruction, 场景, UopSplitType, vlmul, uops, 出处
    ("vsetvli",     "任意",            "VSET",      "-",   2, "UopInfoGen.scala:199"),
    ("vmv.s.x",     "e32/m1",          "VEC_0XV",   "m1",  2, "UopInfoGen.scala:200 + VecDecoder.scala:457 (实现树 :466)"),
    ("vwmul.vv",    "e8/m1 -> e16/m2", "VEC_VVW",   "m1",  2, "UopInfoGen.scala:214 (numOfUopWV, vlmul=000 -> 2) + VecDecoder.scala:427 (实现树 :436)"),
    ("vwadd.wv",    "e16/m2 -> e32/m4","VEC_WVW",   "m2",  4, "UopInfoGen.scala:215 (numOfUopWV, vlmul=001 -> 4) + VecDecoder.scala:421 (实现树 :430)"),
    ("vwredsum.vs", "e16/m2",          "VEC_VWW",   "m2",  4, "UopInfoGen.scala:229 (Cat(lmul,0) = 2*lmul = 4) + VecDecoder.scala:243 (实现树 :244)"),
    ("vredsum.vs",  "e32/m4",          "VEC_VRED",  "m4",  4, "UopInfoGen.scala:224 (lmul = 4) + VecDecoder.scala:410 (实现树 :419)"),
    ("vdot.vv",     "e8/m1",           "VEC_VVV",   "m1",  1, "UopInfoGen.scala:201 (lmul = 1) + VecDecoder.scala:256 (仅实现树)"),
    ("vdotacc.vv",  "e8/m1",           "VEC_VVV",   "m1",  1, "UopInfoGen.scala:201 (lmul = 1) + VecDecoder.scala:257 (仅实现树)"),
    ("vdot4a.vv",   "e32/m1",          "VEC_VVV",   "m1",  1, "UopInfoGen.scala:201 (lmul = 1) + VecDecoder.scala:258 (仅实现树)"),
]


def parse_equiv(path):
    """解析 NEMU 等价性日志。"""
    out = {"suites": [], "total": {}, "long": {}, "loop": [], "single": [],
           "probe": [], "static": {}}
    if not os.path.exists(path):
        return out
    txt = open(path, encoding="utf-8", errors="replace").read()

    # 控制实验 [A0]
    for m in re.finditer(r"^    (\S+)\s{2,}(no trap|TRAP)\s{2,}(no trap|TRAP  mcause=\d+)\s*$",
                         txt, re.M):
        out["probe"].append((m.group(1), m.group(2), m.group(3)))

    # suite 表
    in_tbl = False
    for line in txt.splitlines():
        if line.startswith("suite ") and "cases" in line:
            in_tbl = True
            continue
        if in_tbl:
            if line.startswith("---"):
                continue
            m = re.match(r"^(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$", line)
            if m:
                out["suites"].append(tuple(m.groups()))
            else:
                in_tbl = False

    m = re.search(r"^\[A\] TOTAL cases=(\d+) run=(\d+) pass=(\d+) fail=(\d+) "
                  r"skip\(illegal-by-spec\)=(\d+) skip\(baseline-inexpressible,vstart!=0\)=(\d+)",
                  txt, re.M)
    if m:
        out["total"] = dict(zip(
            ["cases", "run", "pass", "fail", "skip_illegal", "skip_inexpressible"],
            [int(x) for x in m.groups()]))
    m = re.search(r"baseline-vs-golden mismatch = (\d+) , vdot-vs-golden mismatch = (\d+) "
                  r", baseline-vs-vdot mismatch = (\d+)", txt)
    if m:
        out["total"].update(dict(zip(
            ["mm_base_golden", "mm_vdot_golden", "mm_base_vdot"],
            [int(x) for x in m.groups()])))
    m = re.search(r"^\[B\] long-vector sizes checked = (\d+) , mismatches = (\d+)", txt, re.M)
    if m:
        out["long"] = {"sizes": int(m.group(1)), "mismatch": int(m.group(2))}

    # 静态指令数（反汇编逐条）
    for m in re.finditer(r"^    (baseline_vdot_single|vdot_single) : (\d+) 条", txt, re.M):
        out["static"][m.group(1)] = int(m.group(2))

    # CSVROW
    for line in txt.splitlines():
        if not line.startswith("CSVROW,"):
            continue
        f = line.split(",")
        if len(f) >= 4 and f[1] not in ("single16",):
            # kernel,N,instr
            try:
                out["loop"].append((f[1], int(f[2]), int(f[3])))
            except ValueError:
                pass
        elif len(f) >= 5 and f[1] == "single16":
            out["single"].append((f[2], f[3], f[4].split()[0]))
    return out


def parse_latency(path):
    """解析延迟实测日志。"""
    out = {"vcd": {}, "fu": []}
    if not os.path.exists(path):
        return out
    txt = open(path, encoding="utf-8", errors="replace").read()

    # 波形事务表：--- vdot.vv --- 之后的 "# 时钟上升沿共 N 个；检出 in.fire 事务 M 笔"
    cur = None
    for line in txt.splitlines():
        m = re.match(r"^--- (vdot|vdotacc|vdot4a)\.vv ---$", line.strip())
        if m:
            cur = m.group(1)
            out["vcd"].setdefault(cur, {"n": 0, "cyc": {}})
            continue
        if cur:
            m = re.match(r"^\s*\d+\s+(\d+)\s+(\d+)\s+(\d+)\s+10\s", line)
            if m:
                c = int(m.group(3))
                out["vcd"][cur]["cyc"][c] = out["vcd"][cur]["cyc"].get(c, 0) + 1
                out["vcd"][cur]["n"] += 1

    # 三个 harness 的 CSVROW；VIMacU 另有 CSVSETTLE（数据成形拍的可判定性统计）
    settle_detail = {}
    for line in txt.splitlines():
        if line.startswith("CSVSETTLE,"):
            f = [x.strip() for x in line.split(",")]
            # instr, 可判定, 其中扰动重测后可判定, 第1拍未成形, 第1拍已成形, 不可判定, 固定第2拍一致
            settle_detail[f[1]] = dict(zip(
                ["dec", "dec_retry", "not1", "at1", "undec", "fix2"], [int(x) for x in f[2:8]]))
    out["settle_detail"] = settle_detail
    for line in txt.splitlines():
        if not line.startswith("CSVROW,"):
            continue
        f = [x.strip() for x in line.split(",")]
        if len(f) == 6:      # 旧版 vimacu: instr,fu,lat,txn,checked
            out["fu"].append({"instr": f[1], "harness": f[2], "lat": int(f[3]),
                              "settle": "", "txn": int(f[4]), "checked": int(f[5])})
        elif len(f) == 7:    # vecfu / 新版 vimacu: instr,fu,lat,settle,txn,checked
            out["fu"].append({"instr": f[1], "harness": f[2], "lat": int(f[3]),
                              "settle": int(f[4]), "txn": int(f[5]), "checked": int(f[6])})
    return out


def parse_fullcore_perf(path):
    """解析全核周期实测日志 perf_cycles.log 的 PERF 行。
    返回 {(group, name, N): [(rep, cycles, instret, ok, 行号), ...]}，以及汇总行。"""
    out = {"pts": {}, "total": None, "good_trap": False, "path": path}
    if not path or not os.path.exists(path):
        return None
    for ln, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        line = line.rstrip("\n")
        m = re.match(r"^PERF,(\w+),(\w+),(\d+),(\d+),(\d+),(\d+),(-?\d+),([01-])$", line)
        if m:
            g, nm, n, rep, cyc, ins, res, ok = m.groups()
            out["pts"].setdefault((g, nm, int(n)), []).append(
                (int(rep), int(cyc), int(ins), ok, ln))
            continue
        m = re.match(r"^PERF TOTAL measurements=(\d+) result-mismatch=(\d+) unexpected-trap=(\d+)", line)
        if m:
            out["total"] = tuple(int(x) for x in m.groups()) + (ln,)
        if "HIT GOOD TRAP" in line:
            out["good_trap"] = True
    return out if out["pts"] else None


def parse_body_macros(kernels_s, baseline_s):
    """从 perf_kernels.S 的 BASE_BODY / VDOT_BODY 宏里静态计数序列本体的指令条数，
    并核对 BASE_BODY 与 baseline_rvv.S 中「序列 A 本体」逐条相同。"""
    res = {}
    if not os.path.exists(kernels_s):
        return res
    txt = open(kernels_s, encoding="utf-8").read()
    for mac in ("BASE_BODY", "VDOT_BODY"):
        m = re.search(r"^\s*\.macro\s+%s\s*\n(.*?)^\s*\.endm" % mac, txt, re.M | re.S)
        if not m:
            continue
        ins = [l.split("#")[0].strip() for l in m.group(1).splitlines()]
        ins = [l for l in ins if l and not l.startswith("/*")]
        nvset = sum(1 for l in ins if l.startswith("vsetvli"))
        res[mac] = {"instr": ins, "n": len(ins), "vsetvli": nvset, "arith": len(ins) - nvset,
                    "line": txt[:m.start()].count("\n") + 1}
    if "BASE_BODY" in res and os.path.exists(baseline_s):
        b = open(baseline_s, encoding="utf-8").read()
        m = re.search(r"序列 A 本体：\d+ 条 ---- \*/\n(.*?)\n\s*/\* -+ \*/", b, re.S)
        if m:
            ref = [l.split("/*")[0].strip() for l in m.group(1).splitlines()]
            ref = [l for l in ref if l]
            norm = lambda xs: [re.sub(r"\s+", " ", x) for x in xs]
            res["BASE_BODY"]["matches_baseline_rvv"] = norm(ref) == norm(res["BASE_BODY"]["instr"])
    return res


def median(xs):
    xs = sorted(xs)
    n = len(xs)
    return (xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0) if n else None


def regress(points):
    """points = [(N, instr)]；返回 (每 16 字节迭代的指令数, 截距)。"""
    if len(points) < 2:
        return None, None
    pts = sorted(points)
    (n0, y0), (n1, y1) = pts[0], pts[-1]
    it0, it1 = n0 // 16, n1 // 16
    if it1 == it0:
        return None, None
    slope = (y1 - y0) / (it1 - it0)
    return slope, y0 - slope * it0


def w(path, header, rows):
    with open(path, "w", newline="", encoding="utf-8") as fh:
        cw = csv.writer(fh)
        cw.writerow(header)
        cw.writerows(rows)
    print("  WROTE %-28s %d 行" % (os.path.basename(path), len(rows)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--equiv-log", required=True)
    ap.add_argument("--latency-log", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--fullcore-perf-log", default=None,
                    help="全核 MinimalConfig 周期实测日志（scripts/50_run_fullcore_difftest.sh perf）")
    a = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(here)
    perf_kernels_s = os.path.join(repo, "tests", "riscv", "fullcore", "perf_kernels.S")
    baseline_s = os.path.join(here, "baseline", "baseline_rvv.S")

    os.makedirs(a.out, exist_ok=True)
    eq = parse_equiv(a.equiv_log)
    lat = parse_latency(a.latency_log)

    if not eq["total"]:
        print("ERROR: 没能从 %s 解析出 [A] TOTAL 行" % a.equiv_log, file=sys.stderr)
        return 1
    if not lat["fu"]:
        print("ERROR: 没能从 %s 解析出 FU 延迟 CSVROW" % a.latency_log, file=sys.stderr)
        return 1

    # ---------------- equivalence.csv ----------------
    rows = [list(s) + ["实测", os.path.basename(a.equiv_log)] for s in eq["suites"]]
    rows.append(["TOTAL", eq["total"]["cases"], eq["total"]["run"], eq["total"]["pass"],
                 eq["total"]["fail"],
                 eq["total"]["skip_illegal"] + eq["total"]["skip_inexpressible"],
                 "实测", os.path.basename(a.equiv_log)])
    w(os.path.join(a.out, "equivalence.csv"),
      ["suite", "cases", "run", "pass", "fail", "skip", "kind", "evidence"], rows)

    # ---------------- latency_fu.csv ----------------
    meas = {}
    for r in lat["fu"]:
        meas[r["instr"]] = r
    vcd_note = {}
    for k, v in lat["vcd"].items():
        if v["n"]:
            cyc = ",".join("%d拍x%d" % (c, n) for c, n in sorted(v["cyc"].items()))
            vcd_note[k + ".vv"] = "L1 VCD %s (%d 笔: %s)" % (
                "logs/stage3/waveform/p7_%svv_vdottop_fuType10_seed1.vcd" % k, v["n"], cyc)

    rows = []
    order = ["vsetvli", "vmv.s.x", "vwmul.vv", "vwadd.wv", "vwredsum.vs", "vredsum.vs",
             "vadd.vv", "vmul.vv", "vmacc.vv", "vdot.vv", "vdotacc.vv", "vdot4a.vv"]
    for ins in order:
        fut, cfgname, dec, dsrc = FU_DECLARED[ins]
        port, nport, psrc = FU_PORTS[fut]
        m = meas.get(ins)
        if m:
            kind = "实测"
            mval = m["lat"]
            sd = lat["settle_detail"].get(ins)
            if sd is not None:
                # 新版 VIMacU tb：out.valid 是 harness 构造值，独立证据是数据成形拍
                ev = ("%s harness：out.valid %d 笔全部 %d 拍（harness 按 %s.latency 构造，非独立证据）；"
                      "独立观测：第 1 拍数据未成形 %d/%d 笔（可判定 %d/%d，其中经扰动前驱重测 %d，"
                      "不可判定 %d），固定第 2 拍数据与参考一致 %d/%d；" % (
                          m["harness"], m["txn"], m["lat"], cfgname,
                          sd["not1"], sd["dec"], sd["dec"], m["txn"], sd["dec_retry"],
                          sd["undec"], sd["fix2"], m["txn"]))
            elif m["settle"] != "":
                # VecFuLatHarness：out.valid 同样来自按 cfg.latency 搭的寄存器链
                ev = ("%s harness：out.valid %d 笔全部 %d 拍（harness 按 %s.latency 构造，非独立证据）；"
                      "独立观测：数据成形在第 %s 拍（下界型）；" % (
                          m["harness"], m["txn"], m["lat"], cfgname, m["settle"]))
            else:
                ev = "%s harness, %d 笔事务全部 %d 拍，" % (m["harness"], m["txn"], m["lat"])
            if m["checked"] > 0:
                ev += "数值比对 %d 笔一致" % m["checked"]
            else:
                ev += "数值未建模（未做数值比对）"
            if ins in vcd_note:
                ev += "；另有 " + vcd_note[ins]
        else:
            kind = "声明值"
            mval = ""
            ev = "本机无可驱动该功能单元的测试平台" if ins == "vsetvli" else "未实测"
        rows.append([ins, fut, cfgname, dec, dsrc, mval, kind,
                     port, nport, psrc, ev])
    w(os.path.join(a.out, "latency_fu.csv"),
      ["instruction", "fu_type", "fu_config", "declared_latency_cycles",
       "declared_source", "measured_latency_cycles", "kind",
       "issue_ports", "num_issue_ports", "port_source", "evidence"], rows)

    # ---------------- instr_count_loop.csv ----------------
    bykern = {}
    for k, n, v in eq["loop"]:
        bykern.setdefault(k, []).append((n, v))
    rows = []
    slopes = {}
    for k, pts in bykern.items():
        s, b = regress(pts)
        slopes[k] = s
        for n, v in sorted(pts):
            rows.append([k, n, n // 16, v, "%.3f" % s if s else "",
                         "%.1f" % b if b is not None else "", "实测",
                         "NEMU CSR minstret, " + os.path.basename(a.equiv_log)])
    w(os.path.join(a.out, "instr_count_loop.csv"),
      ["kernel", "N_int8", "iterations", "instr_retired_measured",
       "instr_per_iteration_slope", "prologue_epilogue_intercept", "kind", "evidence"], rows)

    # ---------------- 全核周期实测（可选） ----------------
    fc = parse_fullcore_perf(a.fullcore_perf_log)
    fcname = ("logs/stage3/fullcore/" + os.path.basename(a.fullcore_perf_log)) if fc else ""
    body = parse_body_macros(perf_kernels_s, baseline_s)
    fcv = {}            # (group, name, N) -> 扣除开销后的热态净周期 / 净指令数等

    def pts(key):
        return fc["pts"].get(key, []) if fc else []

    def evid(key):
        p = pts(key)
        return "%s:%d-%d" % (fcname, p[0][4], p[-1][4]) if p else ""

    if fc:
        if not fc["good_trap"] or not fc["total"] or fc["total"][1] or fc["total"][2]:
            print("ERROR: %s 未 HIT GOOD TRAP 或有结果失配 / 异常" % a.fullcore_perf_log, file=sys.stderr)
            return 1
        cal = {}
        for k in (("cal", "empty_window", 0), ("cal", "nop_call", 0)):
            p = pts(k)
            cal[k[1]] = (median([x[1] for x in p[1:]]), median([x[2] for x in p[1:]]), p[0][1])
        rows = []
        for key in sorted(fc["pts"], key=lambda k: (["cal", "single", "chain", "loop", "skel"].index(k[0]), k[1], k[2])):
            g, nm, n = key
            p = pts(key)
            warm = [x[1] for x in p[1:]]
            wins = [x[2] for x in p[1:]]
            if g in ("single", "chain") and nm not in ("baseline_vdot_single", "vdot_single"):
                c0, i0, _ = cal["empty_window"]
                calname = "empty_window"
            elif g == "cal":
                c0, i0, calname = 0, 0, "-"
            else:
                c0, i0, _ = cal["nop_call"]
                calname = "nop_call"
            net = median(warm) - c0
            nins = median(wins) - i0
            fcv[key] = {"net": net, "ins": nins, "cold": p[0][1] - c0, "ev": evid(key)}
            rows.append([g, nm, n, p[0][1], median(warm), min(warm), max(warm), len(p),
                         calname, c0 if g != "cal" else "", "%g" % net if g != "cal" else "",
                         "%g" % nins if g != "cal" else "",
                         "实测(全核 MinimalConfig, mcycle/minstret)", evid(key)])
        # 派生：依赖链每条指令的周期（48 条与 16 条之差 / 32），循环每次迭代的周期（N=1024 与 4096 之差 / 192）
        for nm in sorted(set(k[1] for k in fc["pts"] if k[0] == "chain")):
            a16, a48 = fcv.get(("chain", nm, 16)), fcv.get(("chain", nm, 48))
            if a16 and a48:
                fcv[("chain_slope", nm, 0)] = (a48["net"] - a16["net"]) / 32.0
                rows.append(["chain_slope", nm, "16->48", "", "", "", "", "", "-", "",
                             "%.3f" % fcv[("chain_slope", nm, 0)], "",
                             "实测(全核 MinimalConfig, 两档长度之差 / 32)",
                             evid(("chain", nm, 16)) + " ; " + evid(("chain", nm, 48))])
        for g in ("loop", "skel"):
            for nm in sorted(set(k[1] for k in fc["pts"] if k[0] == g)):
                a1, a4 = fcv.get((g, nm, 1024)), fcv.get((g, nm, 4096))
                if a1 and a4:
                    fcv[(g + "_slope", nm, 0)] = (a4["net"] - a1["net"]) / 192.0
                    rows.append([g + "_slope", nm, "1024->4096", "", "", "", "", "", "-", "",
                                 "%.3f" % fcv[(g + "_slope", nm, 0)],
                                 "%.3f" % ((a4["ins"] - a1["ins"]) / 192.0),
                                 "实测(全核 MinimalConfig, 两点之差 / 192 次迭代)",
                                 evid((g, nm, 1024)) + " ; " + evid((g, nm, 4096))])
        w(os.path.join(a.out, "cycles_fullcore.csv"),
          ["group", "name", "N_int8", "cold_cycles_raw_rep0", "warm_cycles_raw_median",
           "warm_cycles_raw_min", "warm_cycles_raw_max", "reps", "overhead_calibration",
           "overhead_cycles", "net_cycles_warm", "net_instr_warm", "kind", "evidence"], rows)

    # ---------------- instr_count_single.csv（长表，每个数值单独标注来源） ----------------
    single = {v[0]: v for v in eq["single"]}
    equiv_name = os.path.basename(a.equiv_log)
    uops = dict((u[0], u[4]) for u in UOPS)
    rows = []
    for variant, fn, mac, seq_uops in (
            ("baseline", "baseline_vdot_single", "BASE_BODY",
             ["vsetvli", "vmv.s.x", "vsetvli", "vwmul.vv", "vsetvli", "vwredsum.vs"]),
            ("vdot", "vdot_single", "VDOT_BODY", ["vsetvli", "vdot.vv"])):
        if fn in eq["static"]:
            rows.append([variant, "static_instr_function", "函数整体静态指令数（含装载、取回与 ret）",
                         eq["static"][fn], "静态计数(反汇编逐条, 日志解析)",
                         equiv_name + " 「单次点积两个 kernel 的静态指令数」段"])
        if variant in single:
            rows.append([variant, "instr_per_call_nemu", "每次调用的动态指令数（minstret 斜率，含调用开销）",
                         single[variant][1], "实测(NEMU minstret 斜率)", equiv_name + " CSVROW,single16"])
        b = body.get(mac)
        key = ("single", "base_body" if variant == "baseline" else "vdot_body", 16)
        if fc and key in fcv:
            rows.append([variant, "sequence_instr", "序列本体指令数（操作数已在寄存器；含必需的 vsetvli）",
                         "%g" % fcv[key]["ins"], "实测(全核 MinimalConfig minstret 窗口差)", fcv[key]["ev"]])
        elif b:
            rows.append([variant, "sequence_instr", "序列本体指令数（操作数已在寄存器；含必需的 vsetvli）",
                         b["n"], "静态计数(源码宏)", "tests/riscv/fullcore/perf_kernels.S:%d %s" % (b["line"], mac)])
        if b:
            rows.append([variant, "sequence_vector_arith_instr", "序列本体中的向量算术指令数（不含 vsetvli）",
                         b["arith"], "静态计数(源码宏)", "tests/riscv/fullcore/perf_kernels.S:%d %s" % (b["line"], mac)])
            rows.append([variant, "sequence_vsetvli", "序列本体中的 vsetvli 条数",
                         b["vsetvli"], "静态计数(源码宏)", "tests/riscv/fullcore/perf_kernels.S:%d %s" % (b["line"], mac)])
        rows.append([variant, "sequence_decoded_uops", "序列本体的译码级 uop 条数",
                     sum(uops[x] for x in seq_uops), "源码推导(UopInfoGen 查找表, 非实测)",
                     "uop_count.csv：" + " + ".join("%s %d" % (x, uops[x]) for x in seq_uops)])
    w(os.path.join(a.out, "instr_count_single.csv"),
      ["variant", "metric", "description", "value", "kind", "evidence"], rows)
    if body.get("BASE_BODY") and body["BASE_BODY"].get("matches_baseline_rvv") is False:
        print("WARNING: perf_kernels.S 的 BASE_BODY 与 baseline_rvv.S 的序列 A 本体不一致", file=sys.stderr)

    # ---------------- uop_count.csv ----------------
    rows = [[i, sc, st, lm, u, "源码推导(非实测)", src] for (i, sc, st, lm, u, src) in UOPS]
    w(os.path.join(a.out, "uop_count.csv"),
      ["instruction", "scenario", "uop_split_type", "vlmul", "uops", "kind", "source"], rows)

    # ---------------- critical_path.csv ----------------
    def L(ins):
        m = meas.get(ins)
        return m["lat"] if m else FU_DECLARED[ins][2]

    cp = [
        # case, step, instruction, latency, kind, note
        ("单次点积-基线", 1, "vsetvli e32,m1", L("vsetvli"), "声明值", "并行分支起点"),
        ("单次点积-基线", 2, "vmv.s.x v8,x0",  L("vmv.s.x"), "实测", "并行分支, 累加器清零"),
        ("单次点积-基线", 3, "vsetvli e8,m1",  L("vsetvli"), "声明值", "关键路径起点"),
        ("单次点积-基线", 4, "vwmul.vv v4,v2,v1", L("vwmul.vv"), "实测", "关键路径"),
        ("单次点积-基线", 5, "vsetvli e16,m2", L("vsetvli"), "声明值", "与 #4 并行"),
        ("单次点积-基线", 6, "vwredsum.vs v8,v4,v8", L("vwredsum.vs"), "实测", "关键路径终点"),
        ("单次点积-vdot", 1, "vsetvli e8,m1",  L("vsetvli"), "声明值", "关键路径起点"),
        ("单次点积-vdot", 2, "vdot.vv v8,v2,v1", L("vdot.vv"), "实测", "关键路径终点"),
    ]
    rows = [[c, s, i, l, k, n] for (c, s, i, l, k, n) in cp]
    w(os.path.join(a.out, "critical_path.csv"),
      ["case", "step", "instruction", "fu_latency_cycles", "latency_kind", "note"], rows)

    base_cp = L("vsetvli") + L("vwmul.vv") + L("vwredsum.vs")
    vdot_cp = L("vsetvli") + L("vdot.vv")

    # ---------------- speedup.csv ----------------
    sp = []

    def add(case, metric, b, v, kind, note):
        sp.append([case, metric, b, v, "%.3f" % (b / v) if v else "", kind, note])

    add("单次点积 (16 int8)", "FU 延迟关键路径 (cycle)", base_cp, vdot_cp, "建模估算",
        "用实测 FU 延迟拼依赖链；假设完美前递、无发射冲突、vsetvli 延迟 0")
    bb, vb = body.get("BASE_BODY"), body.get("VDOT_BODY")
    kb, kv = ("single", "base_body", 16), ("single", "vdot_body", 16)
    if fc and kb in fcv and kv in fcv:
        add("单次点积 (16 int8)", "架构指令条数 (条)", int(round(fcv[kb]["ins"])), int(round(fcv[kv]["ins"])),
            "实测(全核 minstret 窗口差)",
            "序列本体（操作数已在寄存器，两侧都含必需的 vsetvli）；%s ; %s；与源码宏静态计数 %s / %s 条一致"
            % (fcv[kb]["ev"], fcv[kv]["ev"], bb["n"] if bb else "?", vb["n"] if vb else "?"))
    elif bb and vb:
        add("单次点积 (16 int8)", "架构指令条数 (条)", bb["n"], vb["n"], "静态计数(源码宏)",
            "tests/riscv/fullcore/perf_kernels.S BASE_BODY / VDOT_BODY；基线含 3 条 vsetvli，vdot 含 1 条")
    if bb and vb:
        add("单次点积 (16 int8)", "向量算术指令条数 (条)", bb["arith"], vb["arith"], "静态计数(源码宏)",
            "不含 vsetvli：基线 vmv.s.x/vwmul.vv/vwredsum.vs，vdot 只有 vdot.vv（perf_kernels.S BASE_BODY / VDOT_BODY）")
    ub = sum(dict((u[0], u[4]) for u in UOPS)[x] for x in
             ["vsetvli", "vmv.s.x", "vsetvli", "vwmul.vv", "vsetvli", "vwredsum.vs"])
    uv = sum(dict((u[0], u[4]) for u in UOPS)[x] for x in ["vsetvli", "vdot.vv"])
    add("单次点积 (16 int8)", "译码级 uop 条数 (个)", ub, uv, "源码推导",
        "UopInfoGen.scala:197-235（由 uop_count.csv 逐条相加）")
    for n in (64, 256, 1024, 4096):
        b = dict((x[0], x[1]) for x in [(nn, vv) for (kk, nn, vv) in eq["loop"] if kk == "baseline_D"])
        v = dict((x[0], x[1]) for x in [(nn, vv) for (kk, nn, vv) in eq["loop"] if kk == "vdotacc"])
        if n in b and n in v:
            add("长向量循环 N=%d" % n, "动态指令总数 (条)", b[n], v[n], "实测",
                "NEMU CSR minstret；两侧用同一组数据、同一份 baseline_rvv.S")
    if slopes.get("baseline_D") and slopes.get("vdotacc"):
        add("长向量循环 (稳态)", "每 16 个 int8 的指令数 (条)",
            slopes["baseline_D"], slopes["vdotacc"], "实测",
            "对 N=64..4096 四个点做线性回归得到的斜率")
    # 吞吐模型（§5.3，建模估算）：端口下界与循环携带依赖下界取大者，单位 拍 / 16 个 int8
    U = dict((u[0], u[4]) for u in UOPS)
    port_D = max(U["vwmul.vv"], -(-(U["vwmul.vv"] + U["vwadd.wv"]) // 2))   # vwmul 只能在 VFEX0；vialuF 有 2 个端口
    thr_D = max(port_D, L("vwadd.wv"))
    thr_acc = max(U["vdotacc.vv"], L("vdotacc.vv"))
    thr_acc2 = max(U["vdotacc.vv"], L("vdotacc.vv") / 2.0)
    for label, v in (("vdotacc", thr_acc), ("vdotacc 2 累加器", thr_acc2)):
        add("长向量循环 (稳态)", "吞吐模型 拍/16 个 int8 (cycle)，基线 D vs %s" % label, thr_D, v, "建模估算",
            "端口下界与循环携带依赖下界取大者（§5.3）；FU 延迟为实测值，uop 条数为源码推导，不含读寄存器堆/唤醒开销")

    if fc:
        K = "实测(全核 MinimalConfig)"

        def fadd(case, metric, kb, kv, note):
            if kb in fcv and kv in fcv:
                b, v = fcv[kb], fcv[kv]
                bn = b["net"] if isinstance(b, dict) else b
                vn = v["net"] if isinstance(v, dict) else v
                ev = (" ; ".join(x["ev"] for x in (b, v) if isinstance(x, dict))) or "cycles_fullcore.csv"
                sp.append([case, metric, "%g" % round(bn, 3), "%g" % round(vn, 3),
                           "%.3f" % (bn / vn) if vn else "", K, note + "；" + ev])
        fadd("单次点积 (16 int8)", "全核周期·序列本体 (cycle)", kb, kv,
             "fence+mcycle 窗口扣除空窗口；操作数已在寄存器，基线 6 条 vs vdot 2 条，热态中位数")
        fadd("单次点积 (16 int8)", "全核周期·序列+取回标量 (cycle)",
             ("single", "base_body_x", 16), ("single", "vdot_body_x", 16),
             "序列后两侧都加 vsetvli e32 + vmv.x.s，量到结果进入标量寄存器")
        fadd("单次点积 (16 int8)", "全核周期·函数整体 (cycle)",
             ("single", "baseline_vdot_single", 16), ("single", "vdot_single", 16),
             "baseline_rvv.S 的 baseline_vdot_single / vdot_single 整体调用（含 2 条 vle8.v、取回与 ret），扣除空函数调用")
        for n in (1024, 4096):
            for kern, label in (("vdotacc", "vdotacc"), ("vdotacc_acc2", "vdotacc 2 累加器"),
                                ("vdot4a", "vdot4a")):
                fadd("长向量循环 N=%d" % n, "全核周期 (cycle)，基线 D vs %s" % label,
                     ("loop", "seqD", n), ("loop", kern, n),
                     "baseline_rvv.S kernel 整体调用，扣除空函数调用，热态中位数")
        for kern, label in (("vdotacc", "vdotacc"), ("vdotacc_acc2", "vdotacc 2 累加器"),
                            ("vdot4a", "vdot4a")):
            fadd("长向量循环 (稳态)", "全核每 16 个 int8 的周期 (cycle)，基线 D vs %s" % label,
                 ("loop_slope", "seqD", 0), ("loop_slope", kern, 0),
                 "N=1024 与 N=4096 的净周期之差 / 192 次迭代（cycles_fullcore.csv 的 loop_slope 行）")

    w(os.path.join(a.out, "speedup.csv"),
      ["case", "metric", "baseline", "vdot", "speedup", "kind", "assumption"], sp)

    # ---------------- sensitivity.csv ----------------
    sens = []

    def sadd(scen, assum, b, v):
        sens.append([scen, assum, b, v, "%.3f" % (b / v) if v else ""])

    sadd("基准（本次实测值）",
         "vsetvli=0, vwmul=2, vwredsum=2, vdot=2；完美前递、无发射冲突",
         base_cp, vdot_cp)
    sadd("vdot 延迟退化为 3", "若加法树无法在 2 级内收敛（例如 VLEN 加倍后）",
         base_cp, L("vsetvli") + 3)
    sadd("vdot 延迟退化为 4", "更保守的综合结果", base_cp, L("vsetvli") + 4)
    sadd("vsetvli 实际花 1 拍", "把 vsetvli 的唤醒开销计入两侧（各 +1）",
         base_cp + 1, vdot_cp + 1)
    sadd("基线三条 vsetvli 全部串行", "最坏情况：vtype 写后读无旁路，每条 vsetvli 多 1 拍",
         base_cp + 3, vdot_cp + 1)
    sadd("vwredsum 按 4 个 uop 串行展开",
         "VEC_VWW 在 LMUL=2 下拆 4 个 uop，若后继 uop 依赖前一个 uop 的部分和则为 4x2=8 拍",
         L("vsetvli") + L("vwmul.vv") + 4 * L("vwredsum.vs"), vdot_cp)
    sadd("基线的 vsetvli 可与向量指令双发射", "BJU2 与 VFEX0/1 并行，vsetvli 完全隐藏",
         L("vwmul.vv") + L("vwredsum.vs"), L("vdot.vv"))
    w(os.path.join(a.out, "sensitivity.csv"),
      ["scenario", "assumption", "baseline_cycles", "vdot_cycles", "speedup"], sens)

    # ---------------- vstart 对照实验 ----------------
    if eq["probe"]:
        rows = [[p[0], p[1], p[2], "实测",
                 "NEMU vcompute_impl.c:544 check_vstart_exception()"] for p in eq["probe"]]
        w(os.path.join(a.out, "vstart_control.csv"),
          ["instruction", "vstart=0", "vstart=1", "kind", "evidence"], rows)

    if fc:
        print("\n  全核实测（MinimalConfig，热态，扣除开销）：")
        for k in sorted(fcv):
            v = fcv[k]
            if isinstance(v, dict):
                print("    %-6s %-22s N=%-5d net=%-8g instr=%g" % (k[0], k[1], k[2], v["net"], v["ins"]))
            else:
                print("    %-12s %-16s %.3f cycle" % (k[0], k[1], v))
    print("\n  关键派生量：")
    print("    基线单次点积 FU 延迟关键路径 = %d cycle" % base_cp)
    print("    vdot 单次点积 FU 延迟关键路径 = %d cycle" % vdot_cp)
    for k in sorted(slopes):
        if slopes[k]:
            print("    %-12s 每 16 个 int8 实测 %.2f 条指令" % (k, slopes[k]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
