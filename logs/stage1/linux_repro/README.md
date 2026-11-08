# Linux x86_64 全新目录复现记录（阶段一 00 / 02 / 03）

在一个**全新的空目录**里，按交付仓库的一键脚本依次执行 `00_setup_env_host.sh`（含从 GitHub 按 pin 克隆
XiangShan 与 NEMU）、`02_build_nemu.sh`、`03_run_hello.sh`，完整记录终端输出。本目录内的日志均为真实运行的原始输出，
未做任何删改（体积都远小于 2 MB，没有截断）；终端控制字符（`\r` 进度刷新、ANSI 颜色）原样保留，
用 `less -R` 或 `sed 's/\x1b\[[0-9;]*m//g' | tr '\r' '\n'` 查看更清楚。

## 机器环境

| 项 | 值 |
|---|---|
| 日期 | 2026-10-26（UTC 14:33:18 – 14:37:25） |
| 系统 | Ubuntu 22.04.5 LTS，Linux 6.8.0-124-generic x86_64（`00_setup_env_host.term.log:10-12`） |
| CPU / 内存 | AMD EPYC 7543，128 核 / 1007 GB（`00_setup_env_host.term.log:13-14`） |
| 工具 | git 2.34.1、宿主 GCC 11.4.0、Verilator 5.024、OpenJDK 17.0.20、交叉 GCC 15.2.0（`/opt/riscv/bin/riscv64-unknown-elf-`）（`00_setup_env_host.term.log:627-632`） |
| 权限 | 无 root、无 Docker；readline / SDL2 开发包经 `LOCAL_SYSROOT=1` 用 `apt-get download` + `dpkg -x` 解包到 `${WORK_DIR}/sysroot`（`00_setup_env_host.term.log:48-59`） |
| 交付仓库版本 | `4272246d2ecf0df6d6bd40aa5ee2433c59ea5306`（每份日志第 4 行） |

## 命令

工作目录与输出目录全部指向仓库外的新目录，不覆盖仓库内存档：

```bash
export WORK_DIR=/data/my/cie-stage1-repro/work          # 执行前为空目录
export LOG_ROOT=/data/my/cie-stage1-repro/logs
export RESULTS_DIR=/data/my/cie-stage1-repro/results
export FIG_DIR=/data/my/cie-stage1-repro/figures
export LOCAL_SYSROOT=1
cd /data/my/cie2026-vdot-xiangshan
bash scripts/00_setup_env_host.sh
bash scripts/02_build_nemu.sh
bash scripts/03_run_hello.sh
```

每一步都由 `run_step.sh`（本目录，即实际使用的记录脚本）包一层：先写开始时间、主机、环境变量、交付仓库 commit
与完整命令行，再用 `script -q -e -a -c "<命令>"` 在伪终端中记录终端原始输出，最后追加结束时间、rc 与耗时。
三步串行执行，前一步 rc≠0 即停止。记录会话在后台运行，所以 `script` 的首行写着 `[<not executed on terminal>]`；
被记录的命令本身运行在 `script` 分配的伪终端里，因此 `git clone` 的进度输出也被完整记下。

## 结果

| 步骤 | 终端日志 | rc | 耗时 | 关键行 |
|---|---|---:|---:|---|
| `00_setup_env_host.sh` | `00_setup_env_host.term.log`（645 行） | 0 | 216 s | 克隆 XiangShan `:68-76`（`HEAD=a4eeaab…`）、克隆 NEMU `:77-85`（`HEAD=9090839…`）、11 个子模块 `--recursive` 检出 `:86-557`、版本核对 `:558-560`、生成补丁工作树 `:572-624`、rc/耗时 `:644-645` |
| `02_build_nemu.sh` | `02_build_nemu.term.log`（396 行） | 0 | 31 s | 独立解释器 `:162`（537,344 B）、difftest 参考 `.so` `:269`（1,467,680 B）、恢复独立配置后的 `build/` 一览 `:379-382`、rc/耗时 `:395-396` |
| `03_run_hello.sh` | `03_run_hello.term.log`（136 行） | 0 | 0 s（亚秒级） | 验证信息 `:101` `hello xiangshan, I am cie2026-vdot, IP address 172.100.0.6`、NEMU 退出码 `:104`、`HIT GOOD TRAP` `:119`、rc/耗时 `:135-136` |

`log_root/` 是两支脚本按 `LOG_ROOT` 写出的自身日志（与仓库内 `logs/stage1/p1_nemu_build.log`、`p1_hello_xiangshan.log` 同名同格式，
本次输出到仓库外目录后复制到这里，未覆盖仓库内存档）：

| 文件 | 行数 | 说明 |
|---|---:|---|
| `log_root/p1_nemu_build.log` | 382 | `02_build_nemu.sh` 写出的构建日志 |
| `log_root/p1_hello_xiangshan.log` | 122 | `03_run_hello.sh` 写出的 1.1 验证日志 |

耗时取自日志末尾 `### 耗时` 行（`date +%s` 之差，秒级取整）。原 README「一键复现」表（现已迁至 `docs/01_复现指南.md` §4「各脚本做什么与实测记录」）早先填写的 226 s / 29 s / 2 s
来自之前一次没有归档终端记录的实测；本目录是重新实测并入库的记录，该表（现 `docs/01_复现指南.md` §4）已改用本次数值并注明日志位置。

已知的无害输出：`00` 的 `:19-46` 是本机未生成 `en_US.UTF-8` locale，`LOCAL_SYSROOT` 步骤中的 apt/dpkg 工具调用 perl 时打出的警告；
`:61` 提示默认 `python3` 没有 matplotlib（只影响 `40` 号脚本绘图）；`02` 的 `:38-39` 是 NEMU 首次构建前
`.config` 尚未生成时上游 Makefile 的固定提示。
