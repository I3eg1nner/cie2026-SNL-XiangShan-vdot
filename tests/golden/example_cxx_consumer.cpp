// ===========================================================================
// example_cxx_consumer.cpp —— 给 RTL 侧 C++ 测试平台（Verilator / YunSuan）
//                              的 15 行最小消费示例
//
// 说明：测试向量文件是纯文本，每行一个用例，字段以空白分隔。
//       寄存器字段是 32 个十六进制字符，**v[0] 在最左**；
//       直接用 vdot_ref.h 提供的 vdot_hex_parse / vdot_hex_format 解析与打印，
//       不要自己写 strtoull，否则极易把字节序搞反。
//
// 编译：c++ -std=c++17 -O2 example_cxx_consumer.cpp vdot_ref.c -o example_cxx
// 运行：./example_cxx ../vectors/boundary.txt
// ===========================================================================
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include "vdot_ref.h"      // 已用 extern "C" 包裹，可直接在 C++ 中包含

int main(int argc, char **argv)
{
    if (argc < 2) { std::fprintf(stderr, "usage: %s <vector_file>\n", argv[0]); return 2; }
    std::ifstream in(argv[1]);
    if (!in) { std::fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }

    std::string line;
    long n = 0, bad = 0;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream is(line);
        std::string op, h_vs1, h_vs2, h_vd_in, h_vd_exp, h_v0, status;
        unsigned vsew, vstart, vl, vm, vta, vma;
        is >> op >> vsew >> vstart >> vl >> vm >> vta >> vma
           >> h_vs1 >> h_vs2 >> h_vd_in >> h_vd_exp >> h_v0 >> status;

        vreg128_t vs1, vs2, vd, vd_exp, v0;
        vdot_hex_parse(h_vs1.c_str(), &vs1);
        vdot_hex_parse(h_vs2.c_str(), &vs2);
        vdot_hex_parse(h_vd_in.c_str(), &vd);
        vdot_hex_parse(h_vd_exp.c_str(), &vd_exp);
        vdot_hex_parse(h_v0.c_str(), &v0);

        // 这里把 vs1/vs2/vd/v0/vstart/vl/vm/vta/vma 驱动给 DUT，
        // 再把 DUT 的写回结果与 vd_exp 比较即可。
        // 本示例用参考模型本身代替 DUT，仅演示解析流程。
        int st = vdot_exec(vdot_op_from_name(op.c_str()), (int)vsew,
                           &vd, &vs2, &vs1, vstart, vl, vm ? nullptr : &v0,
                           (int)vta, (int)vma, VDOT_VSTART_STRICT);
        char got[33]; vdot_hex_format(&vd, got);
        if (h_vd_exp != got || vdot_status_name(st) != status) ++bad;
        ++n;
    }
    std::printf("%s: %ld cases, %ld mismatch\n", argv[1], n, bad);
    return bad ? 1 : 0;
}
