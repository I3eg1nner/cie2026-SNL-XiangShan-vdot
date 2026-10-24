# 交接文档：后续工作规划（面向 x86_64 Linux / ≥64GB 内存机器）

本文件面向接手本项目的下一台机器。请先读 `docs/_plan/MASTER_PLAN.md`（唯一事实来源），再读本文件。

---

## 一、当前状态速览

### 赛题要求完成情况

| 赛题条目 | 状态 | 主要产物 |
|---|---|---|
| 1.1 环境部署验证 | ✅ | `logs/stage1/p1_hello_xiangshan.log`，裸机 RV64 程序经 UARTLITE 实输出，HIT GOOD TRAP 收尾 |
| 1.2 操作日志 | ✅ | `logs/stage1/*.log`（含 4 次真实失败与修复） |
| 1.3 向量加法执行过程文档 | ✅ | `docs/stage1/02_*.md` + 6 张波形图 + `logs/stage1/waveform/` |
| 2.1 vdot.vv 设计文档 | ✅ | `docs/stage2/10_*.md`（1414 行） |
| 2.2 vdot.vv RTL 实现 | ✅ | `rtl/patch/*.patch`、`rtl/chisel/`、`rtl/verilog/` |
| 2.3.1/2.3.2/2.3.3 三项功能测试 | ✅ | `docs/stage2/12_*.md`，29 万+ 条执行 0 失败 |
| 3.1.1 NEMU 指令扩展 | ✅ | `nemu/patch/0001-*.patch`、`docs/stage3/20_*.md` |
| 3.1.2 协同仿真验证 | ⚠️ Level 1（FU+译码级） | `docs/stage3/21_*.md`；**全核 difftest 未做，见 T1** |
| 3.2 基线功能实现 | ✅ | `bench/baseline/`，NEMU 实测三方比对 0 失配 |
| 3.3 延迟加速分析 | ⚠️ 部分建模 | `docs/stage3/22_*.md` + 4 张图表；**吞吐 1.50× 为建模值，见 T1/T3** |
| 提交要求：三段录屏 | ❌ **未做** | 见 T6，必须由人完成 |
| 提交要求：PPT | ❌ **未做** | 见 T6 |

### 独立验收预测分数（评分表满分 100）

| 一级指标 | 二级指标 | 满分 | 预测 | 依据 |
|---|---|---:|---:|---|
| 完整性 | 阶段一 | 15 | 13–14 | `ACCEPTANCE_P1.md`（整改后） |
| 完整性 | 阶段二 | 20 | 17–19 | `ACCEPTANCE_P2.md`（整改后） |
| 完整性 | 阶段三 | 25 | 待审计 | 全核缺位是主要扣分点 |
| 可行性 | 技术路径合理性 | 10 | 9 | 复用极强；扣分因 latency=2 仅静态估算 → **T2 可补到 10** |
| 可行性 | 功能验证有效性 | 10 | 9 | 扣分因异常语义仅到译码级 → **T1 可补到 10** |
| 探索性 | 微架构优化分析 | 5 | 待审计 | **T1/T3 可显著提升** |
| 探索性 | 软硬件协同理解 | 5 | 待审计 | Level 1 协同 + 机制剖析已完备 |
| 创新性 | 设计优化独特性 | 5 | — | XOR 蝶形折叠树、三指令共享阵列 |
| 创新性 | 扩展应用潜力 | 5 | — | 现固定 LMUL=1 → **T4 可提升** |

> **结论：后续工作的投入产出比，T1（全核 difftest）远高于其他所有项。**

---

## 二、环境重建（第一步，约 1–2 小时）

### 版本锁定（务必一致，否则补丁不适用）

| 仓库 | 分支/commit |
|---|---|
| XiangShan | `kunminghu-v2` @ `a4eeaab` |
| └ yunsuan | `9559211` |
| NEMU | `9090839` |
| 其余子模块 | 以 kunminghu-v2 的 pin 为准（11 个） |

### 工具链

JDK **17**（JDK 21/25 会失败）、mill **0.12.3**（XiangShan）与 **0.11.1**（yunsuan，两个版本并存且不可混用）、Scala 2.13.15、Chisel 6.7.0、firtool 1.62.1（mill 自动下载）、Verilator、RISC-V 交叉工具链（需支持 `-march=rv64gcv_zve64x`，gcc ≥13）。

### 已有脚本与其适用性

| 脚本 | Linux 可用性 |
|---|---|
| `scripts/00_setup_env_host.sh` | ❌ **macOS/brew 专用，需改写**。其中按 commit pin 克隆上游的 step 5 逻辑可直接复用 |
| `scripts/01_setup_env_docker.sh` + `scripts/docker/Dockerfile.xsdev` | ✅ 改 `FROM --platform=linux/amd64` 即可 |
| `scripts/02_build_nemu.sh` / `03_run_hello.sh` | ✅ |
| `scripts/10_build_yunsuan_sim.sh` / `11_build_vdot_sim.sh` | ✅ |
| `scripts/20_run_func_tests.sh` / `21_build_nemu_vdot.sh` / `30_run_cosim.sh` / `40_run_bench.sh` | ✅ |
| `scripts/tools/*` | ✅ 纯 Python/Shell |

### 平台差异带来的两点好处

1. `yunsuan/src/main/resources/espresso` 是 **Linux x86-64 ELF**。本机为此自建了 arm64 版本；**你那台机器可直接用上游自带的，`env_host.sh` 里相关的 PATH 前置和 `forkEnv.json` 清理逻辑都可以删掉。**
2. 官方镜像 `ghcr.io/openxiangshan/xs-env` 仅有 amd64 —— **你那台机器可以直接用官方镜像**，不必像本机那样自建。

---

## 三、TODO（按投入产出比排序）

### T1 — 全核 difftest 【最高优先级】

**为什么**：当前唯一的得分天花板。现有协同仿真是 Level 1——把全核 difftest 的 **REF 侧原样搬了过来**（`dlopen` 真实 `riscv64-nemu-interpreter-so`，走 difftest 原生 C API），只把 DUT 从整个乱序核换成「vdot 功能单元 + 译码单元」。因此它能证明「一条 vdot 该算出什么、该不该报非法」，**不能**证明「它在乱序流水线里被正确发射、旁路、提交，异常被正确投递」。直接影响：3.1.2、功能验证有效性、微架构优化分析。

**前置**：T0 环境重建。注意 `work/XiangShan-kmhv2/Makefile:81` 的 `JVM_XMX ?= 40G`。

**步骤**
1. 纯净基线上应用 `rtl/patch/0001-xiangshan-vdot.patch` 与 `0002-yunsuan-vdot.patch`（`scripts/tools/verify_patches.sh` 可验证可应用性）。
2. NEMU 应用 `nemu/patch/0001-add-vdot-instruction-family.patch`，按 `riscv64-xs-kmhv2-ref_defconfig` 构建 `-so`。
3. 构建全核 emu（Verilator，带 difftest）。
4. 写带 vdot 的 RISC-V 测试程序（可直接复用 `tests/riscv/vdot/` 的语料打包方式与 `tests/vectors/` 语料），在全核上跑 difftest。
5. 抓 vdot 在真实流水线中的波形。

**验收标准**
- 全核 difftest 跑通，全部语料 0 mismatch；日志存档
- **故障注入**：改坏 RTL 一位，全核 difftest 必须报错（证明比对有效）
- 抓到 vdot 从译码到 ROB 提交的全核波形，并据此更新 `docs/stage1/02_*.md` 与 `docs/stage3/21_*.md` 的局限性章节
- 验证本项目 Level 1 协同仿真的等价性论证是否成立，如实记录

**预估**：构建 1–3 小时（含首次 Verilator 编译），调试 0.5–1 天。

---

### T2 — 综合，拿到真实面积与时序

**为什么**：`latency=2` 目前**只有静态逻辑级估算**支撑（设计文档已明确标注为估算而非综合结果），审计为此扣了 1 分；`13.7% 新增逻辑`也只是全加器等价结构计数的上界。一次综合可把两者从估算变成实测，直接提升「技术路径合理性」。

**步骤**：用 `rtl/verilog/vdot/VIMacU.v` 与基线 `rtl/verilog/baseline/VIMac.sv` 对照综合（yosys + Nangate45/Sky130 开源 PDK 即可，不必商业工具）。报告 vdot 路径的关键路径延迟、与 SEW=64 既有最长路径的对比、以及面积增量。

**验收标准**：给出综合脚本、真实报告、面积与 Fmax 对比表；回答「latency=2 是否真的收敛」；更新设计文档 §3 与 §8，把估算值旁边补上实测值。

---

### T3 — 真实 LLM 负载端到端评测

**为什么**：赛题动机是**边缘 LLM 推理**，当前只有微基准。一个 int8 GEMM 或 attention kernel 的端到端数据，是「探索性」和「创新性」最有说服力的材料，也能回答 T3 遗留的最大威胁。

**遗留威胁（必须解决）**：`vdotacc` 的循环携带依赖是 **2 拍**，比基线 `vwadd.wv` 的 1 拍更长。若循环是延迟受限且软件不做多累加器展开，长向量吞吐**可能不升反降**。现有 1.50× 吞吐是建模值，依赖「基线端口下界 3 拍压过其依赖下界」这一假设，FU 级平台无法验证。

**步骤**：在全核上跑 int8 矩阵乘 / 注意力打分 kernel，vdot 版 vs 基线版，测真实周期数；做 2/4 路累加器展开的对比；给出随 N 变化的曲线。

**验收标准**：真实周期数（非指令数）对比；明确回答上述威胁成立与否；更新 `docs/stage3/22_*.md`，把建模值替换为实测值或保留并标注差异。

---

### T4 — 支持 LMUL > 1

**为什么**：当前按裁定 S-6 固定 LMUL=1（SEW=8/VLEN=128 场景恰为单 uop），LMUL≠1 由 `dotEmulIllegal` 守卫拦截。放开它直接提升「扩展应用潜力」。

**已有基础**：设计文档 §8.3 已论证可行性并给出**源码证据**——Rename 支持 bundle 内旁路（`Rename.scala:546-583`）、现成先例 `VEC_SLIDEUP` 在一条指令内对同一寄存器多次读写（`DecodeUnitComp.scala:1412-1426`）、空闲 `UopSplitType` 实测 19 个（推荐 `101011`）。方案：uop0 = `vdot`，uop1..n-1 = `vdotacc` 累加进同一 `vd`。

**注意**：现有 `VEC_VWW` 不可复用——其末 uop 会把 `lsrc(0)` 覆写成 `vs1`（`DecodeUnitComp.scala:1520`），对 `vwredsum` 是标量种子，对 `vdot` 是真正的第二向量源。

**验收标准**：参考模型、语料、NEMU、RTL 四方同步放开；全核 difftest 覆盖 LMUL=2/4/8；性能数据补充。

---

### T5 — 修复 chiseltest，跑通上游单元测试

**为什么**：`make test` 的 11 个用例全挂，根因是 chiseltest 6.0.0 生成的 harness 使用裸类型 `WData`，而 Verilator 5.052 已删除它（**版本不兼容，非本项目引入**）。Linux 上装 Verilator 4.x 或升级 chiseltest 即可绕开。价值中等——本项目已用 L1 差分测试替代，但跑通上游测试能增强「未破坏既有功能」的说服力。

---

### T6 — 提交物（必须由人完成）

**三段录屏**（赛题明文要求，当前完全缺失）：

| 录屏 | 内容 | 可依赖的现有产物 |
|---|---|---|
| ① 阶段一操作过程 | 环境部署、构建、hello 验证 | `scripts/00~03`、`logs/stage1/*.log` |
| ② 阶段二解题思路讲解 | vdot 语义、微架构、数据通路、RTL、三项测试 | `docs/stage2/10~13`、`docs/stage1/figures/` |
| ③ 阶段三波形仿真与性能分析 | 协同仿真机制、波形、加速比 | `docs/stage3/20~22`、`docs/stage3/figures/` |

**PPT**：需覆盖三阶段解题思路、微架构亮点（XOR 蝶形折叠树、三指令共享 16 路乘法阵列、零回退证据）、数据结论。

**加密提交流程**（见根目录 PDF 操作手册）：
1. 本作品仓库转为 **public**（大赛硬性要求）
2. Fork `OpenXiangShan/XiangShanLab`
3. 在 `2026-CIE-RISC-V-Contest-Application-Track/` 下写 `my_submission.txt`（团队名、repo-url、GitHub 用户名、邮箱、项目描述 ≤100 字）
4. `source ./submit.sh my_submission.txt` 生成 `submission.asc`
5. 提 PR，标题格式 `[2026CIE大赛] 团队名称 - 项目名称`

---

## 四、必读陷阱清单（都是本项目踩过的真坑）

1. **分支**：赛题要的是 `kunminghu-v2`。`master` 是 KunminghuV3，向量单元被**完全重写**（新增 `backend/vector/` 区域），两者集成路径毫无共同之处。
2. **死代码**：`src/main/scala/xiangshan/backend/fu/vector/{VIPU,VIMacU,VIAluFix,...}.scala` 六个文件**整文件被注释**，改动必须落在 `backend/fu/wrapper/`。
3. **NEMU `.config` 是全局可变状态**：构建 `-ref` 会关掉所有串口，跑程序前必须 `make riscv64-xs-kmhv2_defconfig` 恢复。
4. **NEMU 按 PC 缓存译码**（`cpu-exec.c:784-793`），同一 PC 反复改写指令会复用首条译码结果。协同仿真中每条激励前需执行一条真 `fence.i` 刷 TCACHE。
5. **firtool 死代码消除**：昆明湖V2 的 FU 不自存流水副本，靠外部 `ctrlPipe/dataPipe/validPipe`。未驱动时整条 vdot 通路会被当死逻辑删掉（生成的 Verilog 里连 `VDotTree` 都没有）。
6. **L1 平台的 `io_out_valid` 由平台常量计数器产生**，不能用它"证实"DUT 延迟（循环论证）。须观测 DUT 内部寄存器与数据真正成形的拍。
7. **寄存器组对齐会掩盖缺陷**：用 `v1/v2/v3` 测 LMUL 守卫看似一致，实为对齐检查的副作用；必须用对齐的 `v8/v16/v24`。
8. **`gen_random_sew()`**：上游默认取不到 e8，不改就永远测不到 `vdot.vv`。
9. **裸机镜像需 `-no-pie`**：Ubuntu gcc 默认 `-pie`，`switch` 指针表靠动态重定位，objcopy 扁平镜像不会重定位。
10. **复位后 `mstatus.FS/VS=Off`**（`init.c:72-73`），不置位则 `vsetvli` 触发非法指令。

---

## 五、交接时的仓库约定

- `work/` 被 `.gitignore` 排除，**不入库**。上游仓库由 `scripts/00_setup_env_host.sh`（需 Linux 改写）按 pin 克隆。
- 所有对上游的改动以 **patch 形式**沉淀在 `rtl/patch/`、`nemu/patch/`、`tests/unit/`，严禁直接提交上游工作树。
- `scripts/tools/sync_rtl_sources.sh --check` 校验 `rtl/chisel/` 与补丁是否漂移，**请纳入提交前检查**。
- 执行纪律（`MASTER_PLAN.md` 第 2 节）对接手方同样有效：**禁止伪造日志与数据，无法执行的必须标注「未执行」及原因**。本项目全部产物均满足该标准，请勿破坏。
