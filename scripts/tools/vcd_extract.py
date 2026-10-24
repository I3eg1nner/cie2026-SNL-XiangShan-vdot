#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vcd_extract.py —— 轻量级 VCD 解析 / 信号抽取工具（仅依赖 Python 标准库）

用途：
  从 YunSuan L1 仿真平台（Verilator）产生的 VCD 波形中，按信号名抽取若干信号，
  打印「时刻 × 信号」的紧凑表格，并可按 SEW 把 128 位 payload 切成逐元素十六进制，
  用于手工核对向量加法的逐元素运算。

设计要点：
  * VCD 是纯文本格式：`$var <type> <width> <id> <name> [bitrange] $end` 声明标识符，
    值变化段里 `#<time>` 给出时刻，`0<id>` / `1<id>` 为 1 位信号，`b<bits> <id>` 为多位信号。
  * 同一个 Verilator 展平端口在层次树里会重复出现多次（TOP / TOP.SimTop / ...），
    但**共享同一个 VCD 标识符**，所以只需按「最短层次名」匹配一次即可。
  * 不把整个文件读进内存按行流式处理，1.4 MB 的波形在 0.1 s 内解析完。

典型用法：
  # 1) 列出顶层 IO 信号
  python3 scripts/tools/vcd_extract.py --vcd <file.vcd> --list --scope TOP

  # 2) 抽取顶层握手 + 数据通路信号，打印每次 in.fire / out.valid 的事务
  python3 scripts/tools/vcd_extract.py --vcd <file.vcd> --transactions

  # 3) 自定义信号集的逐时刻表
  python3 scripts/tools/vcd_extract.py --vcd <file.vcd> \
      --signals TOP.io_in_valid TOP.io_in_ready TOP.io_out_valid --changes-only

  # 4) 把 128 位结果按 SEW 切成逐元素并做加法核验
  python3 scripts/tools/vcd_extract.py --vcd <file.vcd> --verify
"""

import argparse
import re
import sys

# ----------------------------------------------------------------------------- 解析


class VCD(object):
    """最小 VCD 解析器：只保留我们关心的信号的值变化序列。"""

    def __init__(self, path, wanted=None, wanted_re=None):
        """
        wanted    : 完整层次名集合（精确匹配），None 表示全部
        wanted_re : 正则，命中层次名即保留
        """
        self.path = path
        self.timescale = None
        # id -> set(层次名)
        self.id2names = {}
        # id -> 位宽
        self.id2width = {}
        # 层次名 -> id
        self.name2id = {}
        # id -> [(time, value_str)]
        self.changes = {}
        self.times = []
        self._parse(wanted, wanted_re)

    def _parse(self, wanted, wanted_re):
        scope = []
        in_defs = True
        cur_time = -1
        tracked = None  # None = 全部；否则是 id 集合
        pat = re.compile(wanted_re) if wanted_re else None
        times_seen = set()

        with open(self.path, "r", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                if in_defs:
                    if line.startswith("$timescale"):
                        self.timescale = line
                    elif line.startswith("$scope"):
                        # $scope module TOP $end
                        parts = line.split()
                        if len(parts) >= 3:
                            scope.append(parts[2])
                    elif line.startswith("$upscope"):
                        if scope:
                            scope.pop()
                    elif line.startswith("$var"):
                        # $var wire 64 C&! io_in_bits_src_0_0 [63:0] $end
                        parts = line.split()
                        width = int(parts[2])
                        vid = parts[3]
                        name = parts[4]
                        full = ".".join(scope + [name])
                        self.id2width[vid] = width
                        self.id2names.setdefault(vid, set()).add(full)
                        # 只记录**最短**层次名 -> id（顶层优先）
                        prev = self.name2id.get(full)
                        if prev is None:
                            self.name2id[full] = vid
                    elif line.startswith("$enddefinitions"):
                        in_defs = False
                        # 构造 tracked 集合
                        if wanted is None and pat is None:
                            tracked = None
                        else:
                            tracked = set()
                            for full, vid in self.name2id.items():
                                if wanted and full in wanted:
                                    tracked.add(vid)
                                elif pat and pat.search(full):
                                    tracked.add(vid)
                    continue

                # ---- 值变化段 ----
                c = line[0]
                if c == "#":
                    cur_time = int(line[1:])
                    if cur_time not in times_seen:
                        times_seen.add(cur_time)
                        self.times.append(cur_time)
                elif c in "01xzXZ":
                    vid = line[1:]
                    if tracked is None or vid in tracked:
                        self.changes.setdefault(vid, []).append((cur_time, c))
                elif c in "bB":
                    # b0101 id
                    sp = line.split()
                    if len(sp) != 2:
                        continue
                    val, vid = sp[0][1:], sp[1]
                    if tracked is None or vid in tracked:
                        self.changes.setdefault(vid, []).append((cur_time, val))
                elif c in "rR":
                    continue
                else:
                    continue

    # ------------------------------------------------------------------ 查询接口

    def value_at(self, name, t):
        """返回信号 name 在时刻 t（含）之前最后一次变化的值字符串（二进制），无则 None。"""
        vid = self.name2id.get(name)
        if vid is None:
            return None
        seq = self.changes.get(vid)
        if not seq:
            return None
        last = None
        for (tt, vv) in seq:
            if tt <= t:
                last = vv
            else:
                break
        return last

    def int_at(self, name, t):
        v = self.value_at(name, t)
        if v is None:
            return None
        v = v.replace("x", "0").replace("z", "0").replace("X", "0").replace("Z", "0")
        if v == "":
            return None
        try:
            return int(v, 2)
        except ValueError:
            return None

    def change_times(self, names):
        """返回这些信号任一发生变化的时刻列表（升序去重）。"""
        ts = set()
        for n in names:
            vid = self.name2id.get(n)
            if vid is None:
                continue
            for (t, _) in self.changes.get(vid, []):
                ts.add(t)
        return sorted(ts)


# ----------------------------------------------------------------------------- 工具


def h(v, bits):
    if v is None:
        return "-" * 2
    return "{:0{w}x}".format(v, w=(bits + 3) // 4)


def split_elems(lo, hi, sew_code):
    """把 (hi:lo) 组成的 128 位数按 sew 切成元素列表（低位元素在前）。"""
    if lo is None or hi is None:
        return []
    val = (hi << 64) | lo
    bits = {0: 8, 1: 16, 2: 32, 3: 64}[sew_code]
    n = 128 // bits
    mask = (1 << bits) - 1
    return [(val >> (i * bits)) & mask for i in range(n)]


SEW_NAME = {0: "e8", 1: "e16", 2: "e32", 3: "e64"}

# 顶层 IO 信号名（Verilator 展平后的 TOP 作用域）
TOP = "TOP."
IN_SIGS = [
    "io_in_valid", "io_in_ready",
    "io_in_bits_src_0_0", "io_in_bits_src_0_1",
    "io_in_bits_src_1_0", "io_in_bits_src_1_1",
    "io_in_bits_src_2_0", "io_in_bits_src_2_1",
    "io_in_bits_src_3_0", "io_in_bits_src_3_1",
    "io_in_bits_fuType", "io_in_bits_fuOpType", "io_in_bits_sew",
    "io_in_bits_uop_idx", "io_in_bits_widen",
    "io_in_bits_vinfo_vstart", "io_in_bits_vinfo_vl", "io_in_bits_vinfo_vlmul",
    "io_in_bits_vinfo_vm", "io_in_bits_vinfo_ta", "io_in_bits_vinfo_ma",
]
OUT_SIGS = ["io_out_valid", "io_out_ready",
            "io_out_bits_result_0", "io_out_bits_result_1", "io_out_bits_vxsat"]

# SimTop 内部的输入锁存寄存器（VectorSimTop.scala:93 `val in = Reg(new VSTInputIO)`，
# :103 `when (io.in.fire) { in := io.in.bits }`）。功能单元实际看到的就是这组信号，
# 因此事务的输入一律从这里采样，避免顶层端口 trace 的时序歧义。
SIMTOP = "TOP.SimTop."
LATCH = {
    "io_in_bits_src_0_0": "in_src_0_0", "io_in_bits_src_0_1": "in_src_0_1",
    "io_in_bits_src_1_0": "in_src_1_0", "io_in_bits_src_1_1": "in_src_1_1",
    "io_in_bits_src_2_0": "in_src_2_0", "io_in_bits_src_2_1": "in_src_2_1",
    "io_in_bits_src_3_0": "in_src_3_0", "io_in_bits_src_3_1": "in_src_3_1",
    "io_in_bits_fuType": "in_fuType", "io_in_bits_fuOpType": "in_fuOpType",
    "io_in_bits_sew": "in_sew", "io_in_bits_uop_idx": "in_uop_idx",
    "io_in_bits_widen": "in_widen",
    "io_in_bits_vinfo_vstart": "in_vinfo_vstart", "io_in_bits_vinfo_vl": "in_vinfo_vl",
    "io_in_bits_vinfo_vlmul": "in_vinfo_vlmul", "io_in_bits_vinfo_vm": "in_vinfo_vm",
    "io_in_bits_vinfo_ta": "in_vinfo_ta", "io_in_bits_vinfo_ma": "in_vinfo_ma",
}


def collect_transactions(vcd):
    """
    解码 in.fire / out.valid 事务。

    采样约定（由 yunsuan/src/test/csrc/emu.cpp:104-139 的 single_cycle() 决定）：
      偶数时刻 2k : clock=0 求值后 **再** 写入新激励（emu.cpp:110 assign_input_raising
                    在 :115 的 dump 之前），因此 2k 时刻的 io_in_bits_* 就是
                    「即将在 2k+1 上升沿被 SimTop 的 `in` 寄存器锁存」的那一拍激励，
                    而 io_in_ready = !busy 仍是上升沿**之前**的旧值。
                    => (io_in_valid & io_in_ready) @ 2k  <=>  in.fire @ 上升沿 2k+1
      奇数时刻 2k+1: clock=1 求值后 dump，是上升沿**之后**的状态，
                    io_out_valid / io_out_bits_result_* 在此处采样（与
                    emu.cpp:134 diff_output_falling 的比对时刻一致）。
    """
    times = vcd.times
    txns = []
    posedges = [t for t in times if t % 2 == 1]
    for te in times:
        if te % 2 != 0:
            continue
        if vcd.int_at(TOP + "reset", te):
            continue
        if vcd.int_at(TOP + "io_in_valid", te) == 1 and \
           vcd.int_at(TOP + "io_in_ready", te) == 1:
            tf = te + 1
            rec = {"t_sample": te, "t_fire": tf}
            for s in IN_SIGS:
                if s in LATCH:
                    # 功能单元看到的是 SimTop 的 `in` 锁存寄存器（上升沿之后已更新）
                    rec[s] = vcd.int_at(SIMTOP + LATCH[s], tf)
                else:
                    rec[s] = vcd.int_at(TOP + s, te)
            txns.append(rec)
    # 为每笔事务找随后的第一个 out.valid（奇数时刻）
    for i, rec in enumerate(txns):
        tf = rec["t_fire"]
        limit = txns[i + 1]["t_fire"] if i + 1 < len(txns) else None
        for t in posedges:
            if t < tf:
                continue
            if limit is not None and t > limit:
                break
            if vcd.int_at(TOP + "io_out_valid", t) == 1:
                rec["t_out"] = t
                for s in OUT_SIGS:
                    rec[s] = vcd.int_at(TOP + s, t)
                break
    return txns, posedges


def fmt_txn_table(txns, posedges):
    lines = []
    hdr = ("{:>4} {:>7} {:>7} {:>4} {:>3} {:>5} {:>4} {:>3} {:>5} {:>2} {:>2} {:>2} {:>2}"
           .format("#", "t_fire", "t_out", "cyc", "fuT", "fuOp", "sew", "vl", "vlmul",
                   "vm", "ta", "ma", "ui"))
    lines.append(hdr)
    lines.append("-" * len(hdr))
    for i, x in enumerate(txns):
        tf = x["t_fire"]
        to = x.get("t_out")
        # 以时钟上升沿个数计算延迟
        cyc = None if to is None else (to - tf) // 2
        lines.append("{:>4} {:>7} {:>7} {:>4} {:>3} {:>5} {:>4} {:>3} {:>5} {:>2} {:>2} {:>2} {:>2}"
                     .format(i, tf, to if to is not None else "-",
                             cyc if cyc is not None else "-",
                             x["io_in_bits_fuType"], x["io_in_bits_fuOpType"],
                             SEW_NAME.get(x["io_in_bits_sew"], "?"),
                             x["io_in_bits_vinfo_vl"], x["io_in_bits_vinfo_vlmul"],
                             x["io_in_bits_vinfo_vm"], x["io_in_bits_vinfo_ta"],
                             x["io_in_bits_vinfo_ma"], x["io_in_bits_uop_idx"]))
    return "\n".join(lines)


def fmt_txn_detail(txns, posedges):
    out = []
    for i, x in enumerate(txns):
        tf = x["t_fire"]
        to = x.get("t_out")
        cyc = (to - tf) // 2 if to is not None else None
        sew = x["io_in_bits_sew"]
        out.append("==== 事务 #{}  in.fire @ #{}   out.valid @ #{}   延迟 {} 个时钟周期 ===="
                   .format(i, tf, to if to is not None else "-",
                           cyc if cyc is not None else "-"))
        out.append("  fuType={} fuOpType={} sew={}({}) uop_idx={} widen={}"
                   .format(x["io_in_bits_fuType"], x["io_in_bits_fuOpType"],
                           sew, SEW_NAME.get(sew, "?"), x["io_in_bits_uop_idx"],
                           x["io_in_bits_widen"]))
        out.append("  vstart={} vl={} vlmul={} vm={} ta={} ma={}"
                   .format(x["io_in_bits_vinfo_vstart"], x["io_in_bits_vinfo_vl"],
                           x["io_in_bits_vinfo_vlmul"], x["io_in_bits_vinfo_vm"],
                           x["io_in_bits_vinfo_ta"], x["io_in_bits_vinfo_ma"]))
        out.append("  src_0 (vs1) = {}_{}".format(h(x["io_in_bits_src_0_1"], 64),
                                                  h(x["io_in_bits_src_0_0"], 64)))
        out.append("  src_1 (vs2) = {}_{}".format(h(x["io_in_bits_src_1_1"], 64),
                                                  h(x["io_in_bits_src_1_0"], 64)))
        out.append("  src_2 (old_vd)={}_{}".format(h(x["io_in_bits_src_2_1"], 64),
                                                   h(x["io_in_bits_src_2_0"], 64)))
        out.append("  src_3 (mask) = {}_{}".format(h(x["io_in_bits_src_3_1"], 64),
                                                   h(x["io_in_bits_src_3_0"], 64)))
        if to is not None:
            out.append("  result (vd) = {}_{}   vxsat={}"
                       .format(h(x["io_out_bits_result_1"], 64),
                               h(x["io_out_bits_result_0"], 64),
                               x["io_out_bits_vxsat"]))
        out.append("")
    return "\n".join(out)


def verify_elements(txns, policy="auto"):
    """逐事务把 vs1/vs2/old_vd/mask/vd 按 sew 切元素，打印 a+b 与实际 vd 的对比。"""
    out = []
    for i, x in enumerate(txns):
        if "t_out" not in x:
            continue
        sew = x["io_in_bits_sew"]
        bits = {0: 8, 1: 16, 2: 32, 3: 64}[sew]
        n = 128 // bits
        mask_bits_w = bits
        vs1 = split_elems(x["io_in_bits_src_0_0"], x["io_in_bits_src_0_1"], sew)
        vs2 = split_elems(x["io_in_bits_src_1_0"], x["io_in_bits_src_1_1"], sew)
        ovd = split_elems(x["io_in_bits_src_2_0"], x["io_in_bits_src_2_1"], sew)
        vd = split_elems(x["io_out_bits_result_0"], x["io_out_bits_result_1"], sew)
        m128 = ((x["io_in_bits_src_3_1"] or 0) << 64) | (x["io_in_bits_src_3_0"] or 0)
        vl = x["io_in_bits_vinfo_vl"]
        vm = x["io_in_bits_vinfo_vm"]
        ta = x["io_in_bits_vinfo_ta"]
        ma = x["io_in_bits_vinfo_ma"]
        allone = (1 << bits) - 1
        ft = x["io_in_bits_fuType"]
        pol = policy
        if pol == "auto":
            # fuType=3 的 DUT 是裸的 VectorIntAdder（VectorSimTop.scala:158/190-191），
            # 内部完全不做 mask / tail 处理；fuType=5 的 VIAluFWrapper→VIntFixpAlu 才做。
            pol = "raw" if ft == 3 else "mgu"
        out.append("==== 事务 #{} @ in.fire #{} / out.valid #{}  fuType={} sew={} vl={} vm={} ta={} ma={}  判定模型={} ===="
                   .format(i, x["t_fire"], x["t_out"], ft, SEW_NAME[sew], vl, vm, ta, ma, pol))
        out.append("  {:>3} {:>17} {:>17} {:>17} {:>17} {:>5} {:>8} {}"
                   .format("idx", "vs1", "vs2", "(vs1+vs2)%2^sew", "vd(DUT)",
                           "mbit", "类别", "判定"))
        for e in range(n):
            if e >= len(vd):
                break
            s = (vs1[e] + vs2[e]) & allone
            mbit = (m128 >> e) & 1
            if pol == "raw":
                kind = "elem"
                exp = s
            elif e >= vl:
                kind = "tail"
                exp = allone if ta else ovd[e]
            elif vm == 0 and mbit == 0:
                kind = "masked"
                exp = allone if ma else ovd[e]
            else:
                kind = "body"
                exp = s
            ok = "OK" if exp == vd[e] else "MISMATCH"
            out.append("  {:>3} {:>17} {:>17} {:>17} {:>17} {:>5} {:>8} {}"
                       .format(e, h(vs1[e], bits), h(vs2[e], bits),
                               h(s, bits), h(vd[e], bits), mbit, kind, ok))
        out.append("")
    return "\n".join(out)



# ----------------------------------------------------------------- 内部信号抽取

VIAF = "TOP.SimTop.viaf."
VIFA = VIAF + "vIntFixpAlu."
B0 = VIFA + "vIntFixpAlu64bs_0."
B1 = VIFA + "vIntFixpAlu64bs_1."

# 在 in.fire 时刻采样的组合逻辑信号（VIAluFWrapper.scala / VIntFixpAlu.scala 的 S0 侧）
FIRE_SIGS = [
    (VIFA + "io_in_opcode_op", "opcode.op"),
    (VIFA + "io_in_srcType_0", "srcType(0)=vs2"),
    (VIFA + "io_in_srcType_1", "srcType(1)=vs1"),
    (VIFA + "io_in_vdType", "vdType"),
    (VIAF + "narrow", "narrow"),
    (VIAF + "maskIdx", "maskIdx"),
    (VIFA + "io_in_mask16b", "mask16b"),
    (VIFA + "io_ctrl_vstart_gte_vl", "vstart_gte_vl"),
    (B0 + "io_vmask", "64b[0].vmask"),
    (B1 + "io_vmask", "64b[1].vmask"),
    (B0 + "vIntAdder64b.cin_1", "64b[0].cin1"),
    (B0 + "vIntAdder64b.cin_2", "64b[0].cin2"),
    (B0 + "vIntAdder64b.cin_3", "64b[0].cin3"),
    (B0 + "vIntAdder64b.cin_4", "64b[0].cin4"),
    (B0 + "vIntAdder64b.cin_5", "64b[0].cin5"),
    (B0 + "vIntAdder64b.cin_6", "64b[0].cin6"),
    (B0 + "vIntAdder64b.cin_7", "64b[0].cin7"),
]

# 在 out.valid 时刻采样的 S1 寄存器 / 输出信号
OUT_SIGS_INT = [
    (VIFA + "uopIdxS1", "uopIdxS1"),
    (VIFA + "taS1", "taS1"),
    (VIFA + "maS1", "maS1"),
    (VIFA + "mask16bS1", "mask16bS1"),
    (VIFA + "tailS1", "tailS1"),
    (VIFA + "prestartS1", "prestartS1"),
    (VIFA + "mask16bReorg", "mask16bReorg"),
    (VIFA + "tailReorg", "tailReorg"),
    (VIFA + "prestartReorg", "prestartReorg"),
    (B0 + "io_vd", "64b[0].vd(raw)"),
    (B1 + "io_vd", "64b[1].vd(raw)"),
    (VIFA + "io_out_vd", "out.vd(final)"),
]
UPDATE_SIGS = [(VIFA + "updateType_%d" % i, "uT%d" % i) for i in range(16)]


def dump_internal(path):
    want = set([TOP + s for s in IN_SIGS + OUT_SIGS] + [TOP + "clock", TOP + "reset"])
    want |= set(SIMTOP + v for v in LATCH.values())
    want |= set(n for (n, _) in FIRE_SIGS + OUT_SIGS_INT + UPDATE_SIGS)
    vcd = VCD(path, wanted=want)
    txns, posedges = collect_transactions(vcd)
    print("# VCD: {}".format(path))
    print("# VIAluFWrapper / VIntFixpAlu 内部信号（层次名见 TOP.SimTop.viaf.*）")
    print("# 源码对应：VIAluFWrapper.scala:39-86 / VIntFixpAlu.scala:112-313")
    print()
    for i, x in enumerate(txns):
        tf, to = x["t_fire"], x.get("t_out")
        print("==== 事务 #{}  in.fire @ #{}  out.valid @ #{} ====".format(i, tf, to))
        print("  --- S0（in.fire 上升沿 #{} 之后的组合逻辑，采样于 #{}） ---".format(tf, tf))
        for (n, lab) in FIRE_SIGS:
            if n not in vcd.name2id:
                print("    {:<22} <该信号不在本 VCD 中>".format(lab))
                continue
            w = vcd.id2width[vcd.name2id[n]]
            print("    {:<22} = {} (0x{})".format(lab, vcd.value_at(n, tf),
                                                  h(vcd.int_at(n, tf), w)))
        if to is None:
            print()
            continue
        print("  --- S1（out.valid #{}，寄存器输出） ---".format(to))
        for (n, lab) in OUT_SIGS_INT:
            if n not in vcd.name2id:
                print("    {:<22} <该信号不在本 VCD 中>".format(lab))
                continue
            w = vcd.id2width[vcd.name2id[n]]
            print("    {:<22} = 0x{}".format(lab, h(vcd.int_at(n, to), w)))
        ut = []
        for (n, lab) in UPDATE_SIGS:
            v = vcd.int_at(n, to)
            ut.append("-" if v is None else str(v))
        print("    updateType[15..0]      = " + " ".join(reversed(ut)))
        print("      （00=保留运算结果 10=写 old_vd 11=写全 1，VIntFixpAlu.scala:268-281）")
        print()


def sew_crosscheck(txns):
    """
    交叉验证：把同一笔事务的 128 位 payload 分别按 e8/e16/e32/e64 切分并逐元素相加，
    只有与 DUT 实际 sew 相符的那一种切分才能复现 vd。用于证明 RTL 真的按 `sew`
    端口指示的元素宽度做加法，而不是碰巧对上。
    为排除 mask/tail 的干扰，只统计「body」元素（idx < vl 且未被掩掉）。
    """
    out = []
    out.append("{:>4} {:>6} {:>7} {:>9} {:>9} {:>9} {:>9}".format(
        "事务", "真sew", "t_out", "按e8", "按e16", "按e32", "按e64"))
    out.append("-" * 62)
    for i, x in enumerate(txns):
        if "t_out" not in x:
            continue
        real = x["io_in_bits_sew"]
        vl = x["io_in_bits_vinfo_vl"]
        vm = x["io_in_bits_vinfo_vm"]
        m128 = ((x["io_in_bits_src_3_1"] or 0) << 64) | (x["io_in_bits_src_3_0"] or 0)
        cols = []
        for sew in range(4):
            bits = {0: 8, 1: 16, 2: 32, 3: 64}[sew]
            n = 128 // bits
            allone = (1 << bits) - 1
            vs1 = split_elems(x["io_in_bits_src_0_0"], x["io_in_bits_src_0_1"], sew)
            vs2 = split_elems(x["io_in_bits_src_1_0"], x["io_in_bits_src_1_1"], sew)
            vd = split_elems(x["io_out_bits_result_0"], x["io_out_bits_result_1"], sew)
            tot = ok = 0
            raw = (x["io_in_bits_fuType"] == 3)
            for e in range(n):
                if not raw:
                    if e >= vl:
                        continue
                    if vm == 0 and ((m128 >> e) & 1) == 0:
                        continue
                tot += 1
                if ((vs1[e] + vs2[e]) & allone) == vd[e]:
                    ok += 1
            cols.append("{}/{}".format(ok, tot) if tot else "n/a")
        out.append("{:>4} {:>6} {:>7} {:>9} {:>9} {:>9} {:>9}".format(
            i, SEW_NAME[real], x["t_out"], *cols))
    out.append("")
    out.append("说明：x/y = 该切分下成立的元素数 / 参与比较的元素数。")
    out.append("      fuType=3（VectorIntAdder，无 mask/tail）比较全部 128 位；")
    out.append("      fuType=5（VIntFixpAlu）只比较 body 元素（idx<vl 且未被掩掉）。")
    out.append("      只有『真sew』那一列应当全中；其余列的部分命中源于")
    out.append("      『窄切分恰好没有跨段进位』，属正常现象。")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description="VCD 信号抽取 / 向量加法核验工具")
    ap.add_argument("--vcd", required=True, help="VCD 文件路径")
    ap.add_argument("--list", action="store_true", help="列出信号名")
    ap.add_argument("--scope", default=None, help="--list 时只列该作用域前缀下的信号")
    ap.add_argument("--signals", nargs="*", default=None, help="要抽取的完整层次信号名")
    ap.add_argument("--regex", default=None, help="按正则匹配信号名")
    ap.add_argument("--changes-only", action="store_true", help="只打印发生变化的时刻")
    ap.add_argument("--transactions", action="store_true",
                    help="解码顶层 in.fire / out.valid 事务并打印表格 + 明细")
    ap.add_argument("--verify", action="store_true",
                    help="按 sew 逐元素核验 vd = (vs1+vs2) / mask / tail 语义")
    ap.add_argument("--sew-crosscheck", action="store_true",
                    help="按 e8/e16/e32/e64 四种切分交叉验证，证明 RTL 依 sew 分段")
    ap.add_argument("--policy", default="auto", choices=["auto", "raw", "mgu"],
                    help="核验模型：raw=纯逐元素加法（VectorIntAdder）；"
                         "mgu=带 mask/tail（VIntFixpAlu）；auto=按 fuType 自动选择")
    ap.add_argument("--at", nargs="*", type=int, default=None,
                    help="只在这些 VCD 时刻采样（配合 --signals / --regex）")
    ap.add_argument("--internal", action="store_true",
                    help="dump VIAluFWrapper/VIntFixpAlu 内部的 mask/tail/updateType 信号")
    args = ap.parse_args()

    if args.list:
        vcd = VCD(args.vcd)
        names = sorted(vcd.name2id.keys())
        if args.scope:
            names = [n for n in names if n.startswith(args.scope)]
        for n in names:
            print("{:<70} id={:<6} width={}".format(
                n, vcd.name2id[n], vcd.id2width[vcd.name2id[n]]))
        print("# 共 {} 个信号名，{} 个 VCD 标识符".format(len(names), len(vcd.id2width)))
        return

    if args.transactions or args.verify or args.sew_crosscheck:
        want = set([TOP + s for s in IN_SIGS + OUT_SIGS] +
                   [TOP + "clock", TOP + "reset"] +
                   [SIMTOP + v for v in LATCH.values()])
        vcd = VCD(args.vcd, wanted=want)
        txns, posedges = collect_transactions(vcd)
        print("# VCD: {}".format(args.vcd))
        print("# timescale: {}".format(vcd.timescale))
        print("# 时钟上升沿共 {} 个；检出 in.fire 事务 {} 笔".format(len(posedges), len(txns)))
        print()
        if args.transactions:
            print(fmt_txn_table(txns, posedges))
            print()
            print(fmt_txn_detail(txns, posedges))
        if args.verify:
            print(verify_elements(txns, policy=args.policy))
        if args.sew_crosscheck:
            print(sew_crosscheck(txns))
        return

    if args.internal:
        dump_internal(args.vcd)
        return

    # 通用模式：自定义信号的逐时刻表
    wanted = set(args.signals) if args.signals else None
    vcd = VCD(args.vcd, wanted=wanted, wanted_re=args.regex)
    names = sorted(args.signals) if args.signals else \
        sorted([n for n in vcd.name2id if vcd.name2id[n] in vcd.changes])
    if not names:
        print("没有匹配到任何信号", file=sys.stderr)
        return
    if args.at:
        ts = sorted(args.at)
    else:
        ts = vcd.change_times(names) if args.changes_only else vcd.times
    short = [n.split(".")[-1] for n in names]
    print("{:>9}  ".format("time") + "  ".join("{:>18}".format(s[:18]) for s in short))
    prev = {}
    for t in ts:
        row = []
        for n in names:
            v = vcd.int_at(n, t)
            w = vcd.id2width[vcd.name2id[n]]
            row.append("{:>18}".format(h(v, w) if v is not None else "-"))
        line = "{:>9}  ".format("#" + str(t)) + "  ".join(row)
        print(line)


if __name__ == "__main__":
    main()
