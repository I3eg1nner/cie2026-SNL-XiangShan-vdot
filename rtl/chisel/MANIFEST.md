# `rtl/chisel/` 交付副本清单

本目录是 vdot 指令族全部新增/修改 **Chisel 源码**的只读副本，供评委直接阅读，
不参与任何构建。可综合的改动以 `rtl/patch/` 下的补丁为正式交付形式。

| 项 | 值 |
|---|---|
| 生成方式 | pristine 基线 `git archive` 导出 + 依次 `git apply` 补丁 |
| XiangShan 基线 | `work/XiangShan-kmhv2` @ `a4eeaab` |
| YunSuan 基线 | `work/XiangShan-kmhv2/yunsuan` @ `9559211` |
| 重建命令 | `bash scripts/tools/sync_rtl_sources.sh` |
| 一致性自检 | `bash scripts/tools/sync_rtl_sources.sh --check`（有漂移则退出码 1） |
| 文件总数 | 14 |

> 本文件由 `scripts/tools/sync_rtl_sources.sh` 自动生成，请勿手工编辑；
> 改了补丁就重跑一次重建命令。`--check` 会同时校验本清单本身。

## 文件清单

### `rtl/chisel/xiangshan/` —— XiangShan 侧（译码链路 + VIMacU 包装 + 测试入口）

来源补丁：`rtl/patch/0001-xiangshan-vdot.patch`

| 交付文件 | 上游路径 | 状态 | 补丁改动 | 交付副本行数 |
|---|---|---|---:|---:|
| `DecodeUnit.scala` | `src/main/scala/xiangshan/backend/decode/DecodeUnit.scala` | 修改 | +6 / −0 | 1201 |
| `Instructions.scala` | `src/main/scala/xiangshan/backend/decode/Instructions.scala` | 修改 | +11 / −0 | 38 |
| `VecDecoder.scala` | `src/main/scala/xiangshan/backend/decode/VecDecoder.scala` | 修改 | +9 / −0 | 833 |
| `VecExceptionGen.scala` | `src/main/scala/xiangshan/backend/decode/VecExceptionGen.scala` | 修改 | +34 / −4 | 332 |
| `VIMacU.scala` | `src/main/scala/xiangshan/backend/fu/wrapper/VIMacU.scala` | 修改 | +84 / −9 | 226 |
| `VecExceptionGenTest.scala` | `src/test/scala/xiangshan/backend/decode/VecExceptionGenTest.scala` | **新建** | +89 | 89 |
| `VIMacUHarness.scala` | `src/test/scala/xiangshan/backend/fu/VIMacUHarness.scala` | **新建** | +164 | 164 |
| `VIMacUTest.scala` | `src/test/scala/xiangshan/backend/fu/VIMacUTest.scala` | **新建** | +49 | 49 |

### `rtl/chisel/yunsuan/` —— YunSuan 侧（乘法阵列抽头 + 新建加法树与 FU 顶层）

来源补丁：`rtl/patch/0002-yunsuan-vdot.patch`

| 交付文件 | 上游路径 | 状态 | 补丁改动 | 交付副本行数 |
|---|---|---|---:|---:|
| `VimacOpcode.scala` | `src/main/scala/yunsuan/encoding/Opcode/VimacOpcode.scala` | 修改 | +4 / −0 | 28 |
| `package.scala` | `src/main/scala/yunsuan/package.scala` | 修改 | +17 / −0 | 629 |
| `VDotTop.scala` | `src/main/scala/yunsuan/vector/vectorIMAC/VDotTop.scala` | **新建** | +149 | 149 |
| `VDotTree.scala` | `src/main/scala/yunsuan/vector/vectorIMAC/VDotTree.scala` | **新建** | +161 | 161 |
| `VIMac64b.scala` | `src/main/scala/yunsuan/vector/vectorIMAC/VIMac64b.scala` | 修改 | +7 / −0 | 302 |

### `rtl/chisel/yunsuan-testbench/` —— YunSuan L1 测试平台（Chisel 部分）

来源补丁：`tests/unit/yunsuan_vdot_testbench.patch`

| 交付文件 | 上游路径 | 状态 | 补丁改动 | 交付副本行数 |
|---|---|---|---:|---:|
| `VectorSimTop.scala` | `src/test/scala/top/VectorSimTop.scala` | 修改 | +41 / −3 | 442 |

## 说明

- **行数**列是交付副本（已打补丁）的 `wc -l`，不是改动行数；**补丁改动**列才是
  `git apply --numstat` 实测的增/删行数。两列口径不同，不要混用。
- 三个子目录对应三份补丁，互不重叠：`xiangshan/` 与 `yunsuan/` 是 RTL 本体
  （`rtl/patch/`），`yunsuan-testbench/` 是 L1 功能测试平台的 Chisel 部分，
  其补丁按交付结构放在 `tests/unit/` 下，这里只做阅读副本，避免评委漏看。
- 补丁里的非 Chisel 文件（C++ 参考模型薄壳、测试驱动、头文件）不复制到本目录，
  它们属于 `tests/` 交付物；完整改动见对应补丁。
- 生成的 Verilog 在 `rtl/verilog/`，不在本目录。
