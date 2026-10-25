#!/usr/bin/env python3
"""
slice_corpus.py —— 从 tests/riscv/vdot/pack_corpus.py 生成的完整语料 blob 中
                   截取用例区间 [begin, end)，输出格式完全相同的子 blob。

用途：全核 Verilator 仿真速度远低于 NEMU，把 3 万余条用例切成若干批，
      每批编成一个独立镜像，在多个 emu 进程上并行跑 difftest。

只做截取，不改动任何字段：头部的 suite 名表原样保留（suite_id 仍然有效），
n_cases 改为区间长度，用例记录逐字节复制。

用法：slice_corpus.py <full.bin> <out.bin> <begin> <end>
      end 取 -1 表示到末尾；输出一行 "n_cases=<N> begin=<b> end=<e>"。
"""
import struct
import sys

MAGIC = b"VDOTCORP"


def main():
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    begin, end = int(sys.argv[3]), int(sys.argv[4])
    blob = open(src, "rb").read()
    if blob[:8] != MAGIC:
        print("ERROR: magic mismatch in %s" % src, file=sys.stderr)
        return 1
    n_cases, n_suites, rec_size, hdr_size = struct.unpack_from("<IIII", blob, 8)
    if len(blob) != hdr_size + n_cases * rec_size:
        print("ERROR: blob size mismatch", file=sys.stderr)
        return 1
    if end < 0 or end > n_cases:
        end = n_cases
    if not (0 <= begin <= end):
        print("ERROR: bad range [%d, %d)" % (begin, end), file=sys.stderr)
        return 1
    out = bytearray(blob[:hdr_size])
    struct.pack_into("<I", out, 8, end - begin)
    out += blob[hdr_size + begin * rec_size: hdr_size + end * rec_size]
    with open(dst, "wb") as fh:
        fh.write(out)
    print("n_cases=%d begin=%d end=%d total=%d" % (end - begin, begin, end, n_cases))
    return 0


if __name__ == "__main__":
    sys.exit(main())
