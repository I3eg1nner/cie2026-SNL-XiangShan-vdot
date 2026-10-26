# NEMU vdot 指令族扩展

> 对应赛题：阶段三 3.1.1 ｜ 对应总体方案：`docs/_plan/MASTER_PLAN.md` 阶段 P5
> 详细说明文档：`docs/stage3/20_NEMU指令扩展说明.md`
> 真实运行日志：`logs/stage3/p5_nemu_build.log`、`p5_vdot_tests.log`、`p5_fault_injection.log`、`p5_patch_verify.log`

本目录交付的是对 **NEMU**（香山官方 difftest 参考模型）的指令集扩展，为
`vdot.vv` / `vdotacc.vv` / `vdot4a.vv` 三条自定义 int8 点积指令提供位精确的
软件实现，使它们既能在 NEMU 独立解释器上执行，也能作为 difftest 参考库
（`riscv64-nemu-interpreter-so`）参与后续的 NEMU↔RTL 协同仿真。

```
nemu/
└── patch/
    └── 0001-add-vdot-instruction-family.patch
```

| 项目 | 值 |
|---|---|
| 目标仓库 | `OpenXiangShan/NEMU` |
| 目标 commit | `9090839`（`feat(difftest): support fast shared reference execution (#1247)`） |
| patch sha256 | `cb9194f8050d8594d8a5cea6fdc7f67dec05ef0b47c7289742ff6b6ea8319503`（`logs/stage3/p5_nemu_build.log:7`） |
| 改动规模 | 8 个文件，+285 / -1 行（其中新增文件 `vdot.c` 228 行；`git apply --stat` 实测，`logs/stage3/p5_patch_verify.log:19-28`）。历史值：裁定 S-7' 之前 +258 / 201 行，S-7' 之后、S-3' 之前 +278 / 221 行 |
| 配置开关 | `CONFIG_CUSTOM_XVDOT`，已在 `riscv64-xs-kmhv2_defconfig` 与 `riscv64-xs-kmhv2-ref_defconfig` 中置 `y` |

---

## 1. 一键复现（推荐）

前置条件：已按 `docs/stage1/01_环境部署报告.md` 构建 `xsdev:ubuntu24.04-arm64`
容器镜像，且 `work/NEMU` 已克隆到 commit `9090839`。

```bash
# 应用 patch -> 构建两种形态 -> 跑完 30794 条语料（独立解释器 + difftest .so）
./scripts/21_build_nemu_vdot.sh

# 故障注入自测：把实现改坏 7 次（6 次必须检出 + 1 个经论证的等价变异体），见 docs/stage3/20 §5
./scripts/21_build_nemu_vdot.sh fault

# 在全新的干净副本上验证 patch 可应用、可构建、可通过全部语料
./scripts/21_build_nemu_vdot.sh verify-patch
```

脚本幂等：patch 已应用时会跳过（`git apply --check --reverse`），不会重复打。
运行结束后工作区被恢复为 `riscv64-xs-kmhv2_defconfig`（独立解释器形态），
这样可以直接跑 RISC-V 测试程序。

---

## 2. 手工操作步骤

### 2.1 应用 patch

```bash
cd work/NEMU
git log --oneline -1            # 应为 9090839
git apply --check ../../nemu/patch/0001-add-vdot-instruction-family.patch
git apply        ../../nemu/patch/0001-add-vdot-instruction-family.patch
git status --short              # 7 个 M + 1 个 ?? (新增 vdot.c)
```

patch 以 `git diff` 形式生成，上游 git 历史未被改写（`git log -1` 仍是 `9090839`）。

### 2.2 构建两种形态

两种形态共用一个工作区，但 `.config` / `include/generated/autoconf.h` 只反映
**最后一次** `make <name>_defconfig`，这是 NEMU 的全局可变状态，必须注意顺序。

```bash
export NEMU_HOME=$(pwd)          # 必须；NEMU/Makefile:17-18 据此校验仓库

# [A] 独立解释器（可直接执行 RISC-V 扁平二进制）
make riscv64-xs-kmhv2_defconfig
make -j$(nproc)
#   -> build/riscv64-nemu-interpreter

# [B] difftest 参考共享库
make riscv64-xs-kmhv2-ref_defconfig
make -j$(nproc)
#   -> build/riscv64-nemu-interpreter-so

# [C] 收尾：恢复成 [A]，否则后续跑测试程序时抽不到 CONFIG_UARTLITE_MMIO
make riscv64-xs-kmhv2_defconfig
make -j$(nproc)
```

确认扩展已编译进去：

```bash
grep CONFIG_CUSTOM_XVDOT include/generated/autoconf.h      # -> #define CONFIG_CUSTOM_XVDOT 1
ls build/obj-riscv64-nemu-interpreter/src/isa/riscv64/instr/rvv/vdot.o
ls build/obj-riscv64-nemu-interpreter-so/src/isa/riscv64/instr/rvv/vdot.o
```

若用 `make menuconfig`，开关位于
`RISC-V → RISC-V Xvdot Custom Vector Integer Dot-Product Extension`
（`src/isa/riscv64/Kconfig:147`，`depends on RVV`）。

### 2.3 跑一致性测试

```bash
export NEMU_HOME=<WORK_DIR>/NEMU      # 默认 WORK_DIR 为 <仓库根>/work
cd tests/riscv/vdot
make NEMU_HOME=$NEMU_HOME [CROSS=<交叉工具链前缀>] [BUILD=<构建目录>]
$NEMU_HOME/build/riscv64-nemu-interpreter -b --log=build/nemu-run.log build/vdot_test.bin
```

测试程序会把 `tests/vectors/` 下 13 个共享 suite（30739 条）加上
`tests/riscv/vdot/extra_vectors/` 的 1 个补充 suite（55 条，同样由参考模型生成），
共 **30794 条**用例（逐 suite 条数见 `logs/stage3/p5_vdot_tests.log:17-31`，结果见 `:90-93`）逐条喂给真实的 `vdot` / `vdotacc` / `vdot4a` 指令，
并与参考模型 `tests/golden/vdot_ref.c` 产生的 `vd_expected` 逐字节比对，
最后打印 PASS/FAIL 统计。`Makefile` 带 `check-config`
守卫，若当前 NEMU 配置没有 `CONFIG_CUSTOM_XVDOT` 或没有串口设备会立即失败。

在 difftest 参考共享库里跑同一套语料（需要先构建 [B] 形态）：

```bash
make -C $NEMU_HOME/tools/ref-so-runner
make run-ref NEMU_HOME=$NEMU_HOME
```

---

## 3. 指令编码速查

全部为 OPIVV：`funct3 = 000`，`opcode = 1010111`。

```
 31        26 25  24    20 19    15 14  12 11     7 6            0
+------------+--+--------+--------+-----+--------+--------------+
|   funct6   |vm|  vs2   |  vs1   | 000 |   vd   |   1010111    |
+------------+--+--------+--------+-----+--------+--------------+
```

| 指令 | funct6 | 要求 `vtype.vsew` | 语义 |
|---|---|---|---|
| `vdot.vv    vd, vs2, vs1, vm` | `111001` | 8  | `vd.u32[0]  = Σ_{i∈active} sext32(vs2.i8[i])·sext32(vs1.i8[i])`；`vd.u32[1..3] = 0`（`vstart < vl` 时无条件清零，与 `vta`/`vma` 无关，裁定 S-3'；`vl = 0` 时 `vd` 不写，裁定 S-5） |
| `vdotacc.vv vd, vs2, vs1, vm` | `111010` | 8  | `vd.u32[0] += Σ ...`（`vd` 作为第三源）；`vd.u32[1..3] = 0`（同上，S-3'） |
| `vdot4a.vv  vd, vs2, vs1, vm` | `111011` | 32 | `∀i∈active: vd.u32[i] += Σ_{j<4} sext32(vs2.i8[4i+j])·sext32(vs1.i8[4i+j])` |

本版本固定 `LMUL = 1`，其余 `vlmul` 取值抛 Illegal Instruction；
三条指令在 `vstart != 0` 时一律抛 Illegal Instruction（`vdot`/`vdotacc` 依裁定 S-1，`vdot4a` 依裁定 S-7'，
见 `docs/_plan/MASTER_PLAN.md` D2.3）；`vstart` 超出当前 SEW 的最大元素下标（vdot/vdotacc > 15、vdot4a > 3）
由裁定 S-9 单独检查，S-7' 之后它已被「非零即非法」蕴含。

汇编器尚不认识这三条助记符，测试程序用 `.word` 发射；编码由位域宏现场拼出
并有 `_Static_assert` 锚定（`tests/riscv/vdot/vdot_test.c`）。以
`vd=v3, vs2=v2, vs1=v1` 为例：

| 指令 | `vm=1`（不掩码） | `vm=0`（用 v0 掩码） |
|---|---|---|
| `vdot.vv v3, v2, v1`    | `0xe62081d7` | `0xe42081d7` |
| `vdotacc.vv v3, v2, v1` | `0xea2081d7` | `0xe82081d7` |
| `vdot4a.vv v3, v2, v1`  | `0xee2081d7` | `0xec2081d7` |

---

## 4. 卸载

```bash
cd work/NEMU
git apply -R ../../nemu/patch/0001-add-vdot-instruction-family.patch
rm -f src/isa/riscv64/instr/rvv/vdot.c     # git apply -R 会删除它；若残留手工删
make riscv64-xs-kmhv2_defconfig && make -j$(nproc)
```
