#!/usr/bin/env python3
"""
wave_trace.py —— 从全核 emu 的 VCD 中抽取 vdot 指令族从译码到 ROB 提交的文本轨迹

只依赖 Python 标准库，流式解析（几百 MB 的全核 VCD 也只需一次顺序扫描）。

关注的信号（层次名均来自 MinimalConfig 的 SimTop，见 --list 的输出）：
  译码    ctrlBlock.decode.io_in_k_{valid,bits_instr}       k = 0..5（DecodeWidth=6）
          ctrlBlock.decode.io_out_k_{valid,bits_instr,bits_fuType,bits_fuOpType,bits_exceptionVec_2}
  入 ROB  ctrlBlock.rob.io_enq_req_k_{valid,bits_instr,bits_pc}
  执行    vfExuBlock.exus.Vimac.io_in_{valid,bits_ctrl_fuOpType,bits_ctrl_vpu_vsew,bits_data_src_0..2}
          vfExuBlock.exus.Vimac.io_out_{valid,bits_res_data,bits_ctrl_robIdx_value,bits_ctrl_pdest}
          vfExuBlock.exus{,_2}.VialuFix.io_{in,out}_*（vadd.vv 所在的定点 ALU，用来观察生产者）
  重命名  ctrlBlock.rename.io_in_k_{valid,bits_instr}
  发射    vfScheduler.IssueQueueVfmaVialuFixVimacVppuVfaluVfcvtVipuVsetrvfwvf（IQ0，含 Vimac）
          vfScheduler.IssueQueueVfmaVialuFixVfalu（IQ1）
            .io_enq_k_{valid,bits_instr}                         入发射队列
            .io_deqDelay_k_{valid,bits_common_*,bits_rf_i_0_addr} 出发射队列（物理源寄存器号）
  提交    ctrlBlock.rob.io_commits_{isCommit,commitValid_k,info_k_debug_pc,info_k_debug_instr} k = 0..7

用法：
  wave_trace.py <file.vcd>                 打印被测指令（默认 vdot/vdotacc/vdot4a 与 vadd.vv）的事件轨迹
  wave_trace.py <file.vcd> --list REGEX    列出层次名匹配 REGEX 的信号
时刻：emu 的 --dump-wave（不加 --dump-wave-full）每个时钟周期只写一个时间点，
VCD 时间戳即 emu 周期号；每个时间点上的值是该周期内的稳定值。
"""
import re
import sys

PFX = "TOP.SimTop.cpu.l_soc.core_with_l2.core.backend."
DEC = PFX + "inner_ctrlBlock.decode."
ROB = PFX + "inner_ctrlBlock.rob."
MAC = PFX + "inner_vfExuBlock.exus.Vimac."
ALUS = [("VIALUFIX#0", PFX + "inner_vfExuBlock.exus.VialuFix."),
        ("VIALUFIX#2", PFX + "inner_vfExuBlock.exus_2.VialuFix.")]
REN = PFX + "inner_ctrlBlock.rename."
IQS = [("IQ0", PFX + "inner_vfScheduler.IssueQueueVfmaVialuFixVimacVppuVfaluVfcvtVipuVsetrvfwvf."),
       ("IQ1", PFX + "inner_vfScheduler.IssueQueueVfmaVialuFixVfalu.")]

F6 = {0x39: "vdot.vv", 0x3a: "vdotacc.vv", 0x3b: "vdot4a.vv"}


def instr_name(x):
    if x & 0x7f == 0x57 and (x >> 12) & 7 == 0 and (x >> 26) in F6:
        return "%s v%d, v%d, v%d%s" % (F6[x >> 26], (x >> 7) & 31, (x >> 20) & 31,
                                      (x >> 15) & 31, "" if (x >> 25) & 1 else ", v0.t")
    if x & 0x7f == 0x57 and (x >> 12) & 7 == 0 and (x >> 26) == 0:
        return "vadd.vv v%d, v%d, v%d" % ((x >> 7) & 31, (x >> 20) & 31, (x >> 15) & 31)
    return None


def wanted():
    w = {"TOP.clock": "clock"}
    for k in range(6):
        for s in ("valid", "bits_instr"):
            w[DEC + "io_in_%d_%s" % (k, s)] = "dec_in%d_%s" % (k, s)
        for s in ("valid", "bits_instr", "bits_fuType", "bits_fuOpType", "bits_exceptionVec_2"):
            w[DEC + "io_out_%d_%s" % (k, s)] = "dec_out%d_%s" % (k, s)
        for s in ("valid", "bits_instr", "bits_pc"):
            w[ROB + "io_enq_req_%d_%s" % (k, s)] = "rob_enq%d_%s" % (k, s)
        for s in ("valid", "bits_instr"):
            w[REN + "io_in_%d_%s" % (k, s)] = "ren%d_%s" % (k, s)
    for q, iq in IQS:
        for k in range(2):
            for s in ("valid", "bits_instr"):
                w[iq + "io_enq_%d_%s" % (k, s)] = "%s_enq%d_%s" % (q, k, s)
            for s in ("valid", "bits_common_fuType", "bits_common_fuOpType", "bits_common_robIdx_value",
                      "bits_common_pdest", "bits_rf_0_0_addr", "bits_rf_1_0_addr", "bits_rf_2_0_addr"):
                w[iq + "io_deqDelay_%d_%s" % (k, s)] = "%s_deq%d_%s" % (q, k, s)
    for a, alu in ALUS:
        for s in ("io_in_valid", "io_in_bits_ctrl_fuOpType", "io_out_valid", "io_out_bits_res_data",
                  "io_out_bits_ctrl_robIdx_value", "io_out_bits_ctrl_pdest"):
            w[alu + s] = a + "_" + s[3:]
    for k in range(8):
        w[ROB + "io_commits_commitValid_%d" % k] = "cmt%d_valid" % k
        w[ROB + "io_commits_info_%d_debug_pc" % k] = "cmt%d_pc" % k
        w[ROB + "io_commits_info_%d_debug_instr" % k] = "cmt%d_instr" % k
    w[ROB + "io_commits_isCommit"] = "cmt_isCommit"
    for s in ("io_in_valid", "io_in_bits_ctrl_fuOpType", "io_in_bits_ctrl_vpu_vsew",
              "io_in_bits_ctrl_vpu_vta", "io_in_bits_ctrl_vpu_vm",
              "io_in_bits_data_src_0", "io_in_bits_data_src_1", "io_in_bits_data_src_2",
              "io_out_valid", "io_out_bits_res_data", "io_out_bits_ctrl_robIdx_value",
              "io_out_bits_ctrl_pdest"):
        w[MAC + s] = "mac_" + s[3:]
    return w


def parse_header(fh, want, list_re=None):
    scope, ids = [], {}
    for line in fh:
        s = line.strip()
        if s.startswith("$scope"):
            scope.append(s.split()[2])
        elif s.startswith("$upscope"):
            scope.pop()
        elif s.startswith("$var"):
            p = s.split()
            name = ".".join(scope + [p[4]])
            if list_re is not None:
                if list_re.search(name):
                    print("%4s %s" % (p[2], name))
                continue
            if name in want:
                ids.setdefault(p[3], []).append(want[name])
        elif s.startswith("$enddefinitions"):
            break
    return ids


def main():
    if len(sys.argv) >= 4 and sys.argv[2] == "--list":
        with open(sys.argv[1]) as fh:
            parse_header(fh, {}, re.compile(sys.argv[3]))
        return 0
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    want = wanted()
    fh = open(sys.argv[1])
    ids = parse_header(fh, want)
    found = {n for v in ids.values() for n in v}
    missing = sorted(set(want.values()) - found)
    print("# VCD: %s" % sys.argv[1])
    print("# signals found %d / %d%s" % (len(found), len(want),
          ("  (missing: %s)" % ", ".join(missing)) if missing else ""))

    val = {n: 0 for n in want.values()}
    t = 0
    events = []

    def sample(t_edge):
        """在上升沿到来时，按沿前的稳定值采样（与寄存器看到的值一致）"""
        cyc = t_edge
        for k in range(6):
            if val["dec_in%d_valid" % k]:
                nm = instr_name(val["dec_in%d_bits_instr" % k])
                if nm:
                    events.append((cyc, t_edge, "DECODE-IN  slot%d" % k, nm, ""))
            if val["dec_out%d_valid" % k]:
                nm = instr_name(val["dec_out%d_bits_instr" % k])
                if nm:
                    events.append((cyc, t_edge, "DECODE-OUT slot%d" % k, nm,
                                   "fuType=0x%x fuOpType=0x%x illegalInstr=%d" % (
                                       val["dec_out%d_bits_fuType" % k], val["dec_out%d_bits_fuOpType" % k],
                                       val["dec_out%d_bits_exceptionVec_2" % k])))
            if val["ren%d_valid" % k]:
                nm = instr_name(val["ren%d_bits_instr" % k])
                if nm:
                    events.append((cyc, t_edge, "RENAME-IN  slot%d" % k, nm, ""))
            if val["rob_enq%d_valid" % k]:
                nm = instr_name(val["rob_enq%d_bits_instr" % k])
                if nm:
                    events.append((cyc, t_edge, "ROB-ENQ    slot%d" % k, nm,
                                   "pc=0x%x" % val["rob_enq%d_bits_pc" % k]))
        if val["mac_in_valid"]:
            events.append((cyc, t_edge, "VIMACU-IN", "fuOpType=0x%x" % val["mac_in_bits_ctrl_fuOpType"],
                           "vsew=%d vta=%d vm=%d src0(vs1)=%032x src1(vs2)=%032x src2(oldVd)=%032x" % (
                               val["mac_in_bits_ctrl_vpu_vsew"], val["mac_in_bits_ctrl_vpu_vta"],
                               val["mac_in_bits_ctrl_vpu_vm"], val["mac_in_bits_data_src_0"],
                               val["mac_in_bits_data_src_1"], val["mac_in_bits_data_src_2"])))
        if val["mac_out_valid"]:
            events.append((cyc, t_edge, "VIMACU-OUT", "robIdx=%d pdest=%d" % (
                val["mac_out_bits_ctrl_robIdx_value"], val["mac_out_bits_ctrl_pdest"]),
                "res=%032x" % val["mac_out_bits_res_data"]))
        for a, _ in ALUS:
            if val[a + "_in_valid"]:
                events.append((cyc, t_edge, a + "-IN", "fuOpType=0x%x" % val[a + "_in_bits_ctrl_fuOpType"], ""))
            if val[a + "_out_valid"]:
                events.append((cyc, t_edge, a + "-OUT", "robIdx=%d pdest=%d" % (
                    val[a + "_out_bits_ctrl_robIdx_value"], val[a + "_out_bits_ctrl_pdest"]),
                    "res=%032x" % val[a + "_out_bits_res_data"]))
        for q, _ in IQS:
            for k in range(2):
                p = "%s_enq%d_" % (q, k)
                if val[p + "valid"]:
                    nm = instr_name(val[p + "bits_instr"])
                    if nm:
                        events.append((cyc, t_edge, "%s-ENQ  port%d" % (q, k), nm, ""))
                p = "%s_deq%d_" % (q, k)
                if val[p + "valid"]:
                    events.append((cyc, t_edge, "%s-ISSUE port%d" % (q, k),
                                   "robIdx=%d pdest=%d" % (val[p + "bits_common_robIdx_value"],
                                                           val[p + "bits_common_pdest"]),
                                   "fuType=0x%x fuOpType=0x%x psrc(rf0,rf1,rf2)=(%d,%d,%d)" % (
                                       val[p + "bits_common_fuType"], val[p + "bits_common_fuOpType"],
                                       val[p + "bits_rf_0_0_addr"], val[p + "bits_rf_1_0_addr"],
                                       val[p + "bits_rf_2_0_addr"])))
        if val["cmt_isCommit"]:
            for k in range(8):
                if val["cmt%d_valid" % k]:
                    nm = instr_name(val["cmt%d_instr" % k])
                    if nm:
                        events.append((cyc, t_edge, "ROB-COMMIT slot%d" % k, nm,
                                       "pc=0x%x" % val["cmt%d_pc" % k]))

    started = False
    for line in fh:
        c = line[0]
        if c == "#":
            if started:
                sample(t)
            t = int(line[1:])
            started = True
        elif c in "01xzXZ":
            idc = line[1:].strip()
            if idc in ids:
                v = 1 if c == "1" else 0
                for n in ids[idc]:
                    val[n] = v
        elif c == "b":
            bits, idc = line[1:].split()
            if idc in ids:
                try:
                    v = int(bits, 2)
                except ValueError:
                    v = 0
                for n in ids[idc]:
                    val[n] = v
    if started:
        sample(t)
    print("# emu 默认每个时钟周期只记录一个时间点（未加 --dump-wave-full），")
    print("# 因此 VCD 时间戳 = emu 周期号（-b 起点为 0 时）；每行是该周期的稳定值")
    print("%-6s %-18s %-32s %s" % ("cycle", "stage", "instr / uop", "detail"))
    for cyc, te, st, nm, d in events:
        print("%-6d %-18s %-32s %s" % (te, st, nm, d))
    return 0


if __name__ == "__main__":
    sys.exit(main())
