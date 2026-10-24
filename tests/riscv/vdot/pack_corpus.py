#!/usr/bin/env python3
"""
pack_corpus.py —— 把 tests/vectors/*.txt 共享语料打包成裸机测试程序可直接
                  .incbin 的二进制 blob。

为什么要打包：
  NEMU 上跑的是裸机 RV64 程序，没有文件系统、没有 libc。三万余条用例若以
  C 源码数组形式嵌入，编译器要处理 ~270 万个初始化项，编译极慢；打成二进制
  后用 .incbin 嵌入，汇编器一次 read 即可，编译时间可忽略。

语义来源：本脚本**不计算任何期望值**，只做文本 → 二进制的格式转换，
  vd_expected / status 字段原样来自语料文件（全部由 tests/golden/vdot_ref.c
  生成）。唯一的例外见下面 `vstart_relaxed` 一段。

可选的第三个参数 extra_dir 用于追加 P5 的补充定向语料
  （tests/riscv/vdot/extra_vectors/，由 gen_extra_vectors.py 调用同一个参考模型
  生成，覆盖共享语料未触及的裁定 S-9）。suite 名会加 `(extra)` 后缀以示区分。

vstart_relaxed.txt 的处理：
  该语料是 MASTER_PLAN 裁定 S-1 的「备用策略」语料，采用非规范的
  VDOT_VSTART_SKIP 策略（vstart!=0 时不抛异常，按 §5.4 跳过 prestart 元素）。
  本项目绑定的是 STRICT 策略，因此打包时把其中 vstart != 0 的用例按 STRICT
  语义重新标注为 `ILLEGAL_VSTART` 且 vd_expected = vd_in（这正是参考模型
  STRICT 策略下的行为，见 vdot_ref.c:vdot_reduce_common 规则 2 与
  vdot4a_vv_ex 规则 2）。vstart == 0 的用例两种策略结果相同，原样保留。
  文件头的 `# policy: skip` 是触发条件。
  注意：裁定 S-7' 之前这条重标注只对 vdot/vdotacc 生效（vdot4a 的 vstart
  按原 S-7 正常生效）；S-7' 之后三条指令统一适用。

blob 布局（全部小端）：
  0x00  char[8]  magic = "VDOTCORP"
  0x08  u32      n_cases
  0x0c  u32      n_suites
  0x10  u32      rec_size (= 88)
  0x14  u32      hdr_size (= 24 + n_suites*32)
  0x18  char[32] × n_suites   suite 名字（NUL 填充）
  hdr_size 起，每条用例 88 字节：
    +0  u8  op        0=vdot 1=vdotacc 2=vdot4a
    +1  u8  vsew_code log2(vsew/8)，即 vtype.vsew
    +2  u8  vstart
    +3  u8  vl
    +4  u8  flags     bit0=vm(1 表示不使用掩码) bit1=vta bit2=vma
    +5  u8  status    0=OK 1=ILLEGAL_VSTART 2=ERR_SEW 4=ERR_VSTART_RANGE
                  （与 tests/golden/vdot_ref.h 的 enum vdot_status 同值；
                    非 0 一律表示"该配置必须触发 Illegal Instruction"）
    +6  u8  suite_id
    +7  u8  pad
    +8  u8[16] vs1
    +24 u8[16] vs2
    +40 u8[16] vd_in
    +56 u8[16] vd_expected
    +72 u8[16] v0
"""
import os
import struct
import sys

REC_SIZE = 88
OPS = {"vdot": 0, "vdotacc": 1, "vdot4a": 2}
# 取值与 tests/golden/vdot_ref.h 的 enum vdot_status 一致
STATUS = {"OK": 0, "ILLEGAL_VSTART": 1, "ERR_SEW": 2, "ERR_VSTART_RANGE": 4}
# 语料文件的固定顺序：定向用例在前，随机用例在后，便于日志阅读
SUITE_ORDER = [
    "positive.txt", "negative.txt", "boundary.txt",
    "vdotacc_positive.txt", "vdotacc_negative.txt", "vdotacc_boundary.txt",
    "vdot4a_positive.txt", "vdot4a_negative.txt", "vdot4a_boundary.txt",
    "vstart_relaxed.txt",
    "random.txt", "vdotacc_random.txt", "vdot4a_random.txt",
]


def parse_hex(s):
    """32 个十六进制字符，v[0] 在最左（与 vdot_hex_parse() 同约定）。"""
    if len(s) != 32:
        raise ValueError("bad hex length %d: %r" % (len(s), s))
    return bytes.fromhex(s)


def main():
    if len(sys.argv) not in (3, 4):
        print("usage: pack_corpus.py <vectors_dir> <out.bin> [extra_dir]",
              file=sys.stderr)
        return 2
    vdir, out = sys.argv[1], sys.argv[2]
    extra_dir = sys.argv[3] if len(sys.argv) == 4 else None

    present = sorted(f for f in os.listdir(vdir) if f.endswith(".txt"))
    unknown = [f for f in present if f not in SUITE_ORDER]
    if unknown:
        print("ERROR: 语料目录出现未登记的 suite: %s" % unknown, file=sys.stderr)
        return 1
    missing = [f for f in SUITE_ORDER if f not in present]
    if missing:
        print("ERROR: 缺少 suite: %s" % missing, file=sys.stderr)
        return 1

    # 共享语料（tests/vectors/）在前，P5 补充定向语料（由同一个参考模型生成）在后
    todo = [(vdir, f) for f in SUITE_ORDER]
    if extra_dir and os.path.isdir(extra_dir):
        todo += [(extra_dir, f)
                 for f in sorted(x for x in os.listdir(extra_dir) if x.endswith(".txt"))]

    suites, records = [], []
    for sid, (sdir, fname) in enumerate(todo):
        path = os.path.join(sdir, fname)
        policy = "strict"
        n = 0
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                if line.startswith("#"):
                    if line.startswith("# policy:"):
                        policy = line.split(":", 1)[1].split()[0].strip()
                    continue
                f = line.split()
                if len(f) != 13:
                    raise ValueError("%s: 字段数 %d != 13: %r" % (fname, len(f), line))
                op = OPS[f[0]]
                vsew = int(f[1])
                if vsew not in (8, 16, 32, 64):
                    raise ValueError("bad vsew %d" % vsew)
                vsew_code = {8: 0, 16: 1, 32: 2, 64: 3}[vsew]
                vstart, vl, vm, vta, vma = (int(x) for x in f[2:7])
                vs1, vs2, vd_in, vd_exp, v0 = (parse_hex(x) for x in f[7:12])
                status = STATUS[f[11 + 1]]

                # vstart_relaxed：SKIP 策略语料，按本项目绑定的 STRICT 策略重标注。
                # 裁定 S-7' 之后三条指令（op 0/1/2）一律适用，不再只限归约形态。
                if policy == "skip" and vstart != 0:
                    status = STATUS["ILLEGAL_VSTART"]
                    vd_exp = vd_in

                if not (0 <= vstart < 256 and 0 <= vl < 256):
                    raise ValueError("vstart/vl 超出 1 字节")
                flags = (vm & 1) | ((vta & 1) << 1) | ((vma & 1) << 2)
                records.append(struct.pack(
                    "<8B16s16s16s16s16s",
                    op, vsew_code, vstart, vl, flags, status, sid, 0,
                    vs1, vs2, vd_in, vd_exp, v0))
                n += 1
        name = fname[:-4]
        if policy == "skip":
            name += "(strict)"
        if sdir is extra_dir:
            name += "(extra)"
        suites.append((name, n))
        print("  %-24s %6d cases   policy=%-6s  (%s)" % (fname, n, policy, sdir))

    assert all(len(r) == REC_SIZE for r in records)
    hdr_size = 24 + 32 * len(suites)
    blob = b"VDOTCORP"
    blob += struct.pack("<IIII", len(records), len(suites), REC_SIZE, hdr_size)
    for name, _ in suites:
        nb = name.encode()
        if len(nb) > 31:
            raise ValueError("suite 名过长: %s" % name)
        blob += nb + b"\0" * (32 - len(nb))
    assert len(blob) == hdr_size
    blob += b"".join(records)

    with open(out, "wb") as fh:
        fh.write(blob)
    print("  -> %s  (%d suites, %d cases, %d bytes)"
          % (out, len(suites), len(records), len(blob)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
