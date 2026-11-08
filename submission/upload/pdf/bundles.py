#!/usr/bin/env python3
"""生成四个上传包与清单（入口：submission/upload/build-bundles.sh）。

用法：bundles.py <src_tree> <upload_dir> <src_id> <src_time> [out_dir]
  src_tree   `git archive HEAD` 解出的干净目录；①②两包与③④中的 pptx、视频一/二、字幕都取自这里
  upload_dir submission/upload/（三册 PDF 与 PPT 的 PDF 已生成在此）
  src_id     内容提交号：最后一次改动「清单类文件以外」内容的提交（见 build-bundles.sh）
  src_time   该提交的 Unix 时间，用作包内全部条目的时间戳（同一内容重打包得到相同的 sha256）
  out_dir    可选；四个包与清单写到这里（试运行用），默认 upload_dir
环境变量：FFMPEG（可选，读视频时长与参数）、PDFINFO（默认 pdfinfo）。

四个包（文件名 ASCII，包内路径 UTF-8）：
  SNL-XiangShan-vdot-1-source.zip    源码、脚本与文档 Markdown（git archive HEAD，去掉日志、成品与清单）
  SNL-XiangShan-vdot-2-evidence.zip  证据：真实终端日志、波形 VCD 与文本轨迹、结果 CSV、文档中的图
  SNL-XiangShan-vdot-3-docs.zip      技术文档三册 PDF + 讲解 PPT（pptx 与 PDF）
  SNL-XiangShan-vdot-4-video.zip     演示视频三段（mp4）+ 外挂字幕（srt），不压缩存储
①②的根目录同为 SNL-XiangShan-vdot/，两包解压到同一目录即得到完整的仓库快照。
"""
import hashlib
import os
import re
import subprocess
import sys
import time
import zipfile
from pathlib import Path

SRC = Path(sys.argv[1]).resolve()
UP = Path(sys.argv[2]).resolve()
SRC_ID = sys.argv[3]
SRC_TIME = int(sys.argv[4])
OUT = Path(sys.argv[5]).resolve() if len(sys.argv) > 5 else None  # 试运行：包与清单写到这里，不动 upload_dir
OUT = OUT or UP
ROOT = UP.parent.parent
FFMPEG = os.environ.get("FFMPEG", "")
PDFINFO = os.environ.get("PDFINFO", "pdfinfo")
REPO_URL = "https://github.com/I3eg1nner/cie2026-SNL-XiangShan-vdot"
P = "SNL-XiangShan-vdot"
ZT = time.localtime(SRC_TIME)[:6]
LIMIT = 500 * 1000 * 1000

# 描述这些包本身的清单类文件：不进①（否则包里永远是上一轮的旧清单），其改动也不改变内容提交号
SELF = ["submission/upload/提交清单.md", "submission/upload/SHA256SUMS", "submission/upload/bundle-contents.tsv"]
# 任何包里都不得出现的字符串（按片段拼接：本脚本也在①里）
FORBID = re.compile("|".join([r"\bCl" r"aude\b", r"Anth" r"ropic", r"Chat" r"GPT", r"Co" r"pilot\b", r"Gem" r"ini\b",
                              r"Open" r"AI\b", r"\bag" r"ent", "脱" "网"]).encode(), re.I)
TEXT_EXT = {".md", ".txt", ".log", ".csv", ".tsv", ".srt", ".sh", ".py", ".c", ".h", ".cpp", ".S", ".s", ".ld",
            ".scala", ".sv", ".v", ".patch", ".json", ".yml", ".yaml", ".mk", ".lua", ".css", ".html", ".cast", ""}

DOCS = [  # 包内文件名, 来源（相对仓库根）, 是否取自 git archive, 标题, 对应赛题提交内容
    (f"{P}-vol1-stage1.pdf", "submission/upload/" + f"{P}-vol1-stage1.pdf", False,
     "技术文档第一册　阶段一：环境部署与 vadd.vv 执行过程分析", "阶段一执行日志与过程文档（日志原件见②）"),
    (f"{P}-vol2-stage2.pdf", "submission/upload/" + f"{P}-vol2-stage2.pdf", False,
     "技术文档第二册　阶段二：vdot 指令设计、RTL 实现与基础功能测试", "阶段二设计与基础测试文档"),
    (f"{P}-vol3-stage3.pdf", "submission/upload/" + f"{P}-vol3-stage3.pdf", False,
     "技术文档第三册　阶段三：NEMU 扩展、协同仿真与延迟加速比分析", "阶段三协同仿真与性能分析文档"),
    (f"{P}-slides.pptx", f"docs/submission/{P}-slides.pptx", True,
     "讲解 PPT（选拔赛 / 总决赛答辩，每页带讲者备注）", "PPT"),
    (f"{P}-slides.pdf", "submission/upload/" + f"{P}-slides.pdf", False,
     "讲解 PPT（PDF 版）", "PPT"),
]
VIDEOS = [
    ("video1-stage1", "视频一　阶段一操作过程：环境部署、NEMU 构建、hello 验证与 vadd.vv 波形分析", "阶段一操作过程录屏"),
    ("video2-stage2", "视频二　阶段二解题思路：vdot 语义、官方伪代码对照、微架构、数据通路、RTL 与三项测试", "阶段二解题思路讲解录屏"),
    ("video3-stage3", "视频三　阶段三波形仿真与性能分析：NEMU 扩展、协同仿真、全核 difftest、波形与加速比", "阶段三波形仿真与性能分析录屏"),
]
rows = []  # bundle-contents.tsv：包, 包内路径, 来源, 大小, sha256


def sha(b):
    return hashlib.sha256(b).hexdigest()


def mb(n):
    return f"{n:,} B（{n / 1e6:.1f} MB）" if n >= 100_000 else f"{n:,} B（{n / 1e3:.1f} KB）"


def tracked(prefixes=None, exclude=()):
    out = []
    for dp, dns, fns in os.walk(SRC):
        dns.sort()
        for fn in sorted(fns):
            rel = (Path(dp) / fn).relative_to(SRC).as_posix()
            if rel in SELF or any(rel.startswith(e) or re.fullmatch(e, rel) for e in exclude):
                continue
            if prefixes is None or any(rel.startswith(p) for p in prefixes):
                out.append(rel)
    return sorted(out)


def check(name, arc, data):
    if Path(arc).suffix in TEXT_EXT and FORBID.search(data):
        m = FORBID.search(data).group(0).decode(errors="replace")
        sys.exit(f"forbidden string {m!r} in {name}:{arc}")


def write_zip(name, top, items, extra, stored=False):
    """items: [(arcname, bytes, source)]; extra: [(arcname, text)]，extra 写在最后。"""
    comp = zipfile.ZIP_STORED if stored else zipfile.ZIP_DEFLATED
    sums = []
    with zipfile.ZipFile(OUT / name, "w", comp, compresslevel=None if stored else 9) as z:
        for arc, data, src in items:
            check(name, arc, data)
            zi = zipfile.ZipInfo(f"{top}/{arc}", ZT)
            zi.compress_type = comp
            zi.external_attr = 0o644 << 16
            z.writestr(zi, data)
            h = sha(data)
            sums.append(f"{h}  {arc}")
            rows.append((name, f"{top}/{arc}", src, len(data), h))
        for arc, text in extra:
            data = text.encode()
            check(name, arc, data)
            zi = zipfile.ZipInfo(f"{top}/{arc}", ZT)
            zi.compress_type = comp
            zi.external_attr = 0o644 << 16
            z.writestr(zi, data)
            rows.append((name, f"{top}/{arc}", "本脚本生成", len(data), sha(data)))
    size = (OUT / name).stat().st_size
    assert size < LIMIT, name
    return sums


def pdf_pages(path):
    out = subprocess.run([PDFINFO, str(path)], capture_output=True, text=True, check=True).stdout
    return int(re.search(r"^Pages:\s+(\d+)", out, re.M).group(1))


def pptx_slides(data):
    import io
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        return sum(1 for n in z.namelist() if re.fullmatch(r"ppt/slides/slide\d+\.xml", n))


def video_info(path):
    if not FFMPEG:
        return ""
    err = subprocess.run([FFMPEG, "-hide_banner", "-i", str(path)], capture_output=True, text=True).stderr
    d = re.search(r"Duration: (\d+):(\d+):(\d+)\.(\d+)", err)
    v = re.search(r"Video: (\w+).*?, (\d+)x(\d+).*?, ([\d.]+) fps", err)
    if not d or not v:
        return ""
    secs = int(d.group(1)) * 3600 + int(d.group(2)) * 60 + int(d.group(3)) + (int(d.group(4)) >= 50)
    return f"{secs // 60} 分 {secs % 60:02d} 秒，{v.group(2)}×{v.group(3)}，{v.group(1).upper()}，{v.group(4)} fps"


# ---------------------------------------------------------------- ① 源码与脚本
EV_PREFIX = ["logs/", "bench/results/", "docs/stage1/figures/", "docs/stage2/figures/", "docs/stage3/figures/"]
src_ex = ["logs/", r"demo/video/.*\.mp4", r"docs/submission/.*\.pptx"]
src_files = tracked(exclude=src_ex)
excluded = [r for r in tracked() if r not in src_files]
items1 = [(r, (SRC / r).read_bytes(), "git archive HEAD") for r in src_files]
n1 = sum(len(d) for _, d, _ in items1)
manifest1 = f"""# {P} 源码与脚本包（①）

作品：XiangShan-vdot（面向边缘 AI 大语言模型推理的 RISC-V 自定义 vdot 指令设计），参赛团队 SNL，目标平台香山昆明湖 V2（`kunminghu-v2`）。
作品仓库：{REPO_URL}

- 内容：仓库提交 `{SRC_ID}` 的 `git archive` 快照，共 {len(src_files)} 个文件、{n1:,} B；逐文件 sha256 见同目录 `SHA256SUMS-source`
  （校验：`cd {P} && sha256sum -c SHA256SUMS-source`）。
- 从仓库快照中移出的内容（{len(excluded)} 个文件，均在其他三个包中，或为描述这些包本身的清单）：
  - `logs/`（真实终端日志、波形 VCD 与文本轨迹）→ 证据包 ②（`{P}-2-evidence.zip`）；
  - `docs/submission/{P}-slides.pptx` → 文档包 ③（`{P}-3-docs.zip`）；
  - `demo/video/*.mp4` → 视频包 ④（`{P}-4-video.zip`）；外挂字幕 `.srt` 与生成脚本仍在本包 `demo/video/`；
  - `submission/upload/提交清单.md`、`SHA256SUMS`、`bundle-contents.tsv`：描述四个包本身，见仓库或 GitHub Release。
- ② 的根目录与本包相同（`{P}/`），两包解压到同一目录即恢复完整的仓库快照，文档中「日志文件:行号」形式的引用随即可查。
- 入口：`README.md`（主结论、复现命令与仓库导航）、`docs/00_项目总览.md`（赛题逐条对照与评分表自评）；
  编号一键脚本在 `scripts/`，上游补丁在 `rtl/patch/` 与 `nemu/patch/`，C 参考模型在 `tests/golden/vdot_ref.c`。
- 文档 Markdown 为唯一来源；三册 PDF、讲解 PPT 与演示视频由 `submission/upload/`、`docs/submission/build/`、`demo/video/` 中的脚本生成，
  命令见 `submission/upload/README.md` 与 `demo/video/storyboard.md`。
"""
s1 = write_zip(f"{P}-1-source.zip", P, items1, [])
with zipfile.ZipFile(OUT / f"{P}-1-source.zip", "a", zipfile.ZIP_DEFLATED) as z:
    for arc, text in [("MANIFEST-source.md", manifest1), ("SHA256SUMS-source", "\n".join(s1) + "\n")]:
        zi = zipfile.ZipInfo(f"{P}/{arc}", ZT); zi.compress_type = zipfile.ZIP_DEFLATED; zi.external_attr = 0o644 << 16
        z.writestr(zi, text.encode())
        rows.append((f"{P}-1-source.zip", f"{P}/{arc}", "本脚本生成", len(text.encode()), sha(text.encode())))

# ---------------------------------------------------------------- ② 证据
ev_files = tracked(prefixes=EV_PREFIX)
items2 = [(r, (SRC / r).read_bytes(), "git archive HEAD") for r in ev_files]
n2 = sum(len(d) for _, d, _ in items2)


def count(prefix, suffix=""):
    return sum(1 for r in ev_files if r.startswith(prefix) and r.endswith(suffix))


readme2 = f"""# {P} 证据包（②）：真实终端日志、波形与结果数据

作品 XiangShan-vdot · 参赛团队 SNL · 仓库提交 `{SRC_ID}` 的 `git archive` 快照中的证据部分，共 {len(ev_files)} 个文件、{n2:,} B；
逐文件 sha256 见同目录 `SHA256SUMS-evidence`（校验：`cd {P} && sha256sum -c SHA256SUMS-evidence`）。
路径与仓库一致；根目录与源码包 ① 相同，两包解压到同一目录即恢复完整仓库快照。

| 目录 | 文件数 | 内容 |
|---|---:|---|
| `logs/stage1/` | {count("logs/stage1/")} | 阶段一真实终端日志（环境部署、构建、hello 验证、FU 级仿真，含失败与修复过程）、`linux_repro/` 全新目录复现记录、`waveform/` 下 `vadd.vv` 波形 VCD 与文本轨迹 |
| `logs/stage2/` | {count("logs/stage2/")} | 阶段二 RTL 构建、官方伪代码逐位等价核对、三项基础功能测试与故障注入日志、`waveform/` 下 vdot 三条指令的功能波形 |
| `logs/stage3/` | {count("logs/stage3/")} | 阶段三 NEMU 扩展、协同仿真（`cosim/`）、基线等价、FU 延迟实测（`waveform/`）、全核 difftest 与周期实测（`fullcore/`）日志 |
| `bench/results/` | {count("bench/results/")} | 延迟、周期与加速比结果 CSV（由日志解析得到） |
| `docs/stage1,2,3/figures/` | {count("docs/stage")} | 文档中的波形图、流水图与数据图（PNG），由上述 VCD 与 CSV 生成 |

其中波形 VCD 共 {sum(1 for r in ev_files if r.endswith('.vcd'))} 份（全核 VCD 体积过大不入库，全核波形以文本轨迹与时序图交付，见 `logs/stage3/fullcore/`）。
各文档引用日志时写作「文件:行号」，可直接对照；每份日志与波形的重新生成命令见对应技术文档与仓库 `README.md`。
"""
s2 = write_zip(f"{P}-2-evidence.zip", P, items2, [])
with zipfile.ZipFile(OUT / f"{P}-2-evidence.zip", "a", zipfile.ZIP_DEFLATED) as z:
    for arc, text in [("README-evidence.md", readme2), ("SHA256SUMS-evidence", "\n".join(s2) + "\n")]:
        zi = zipfile.ZipInfo(f"{P}/{arc}", ZT); zi.compress_type = zipfile.ZIP_DEFLATED; zi.external_attr = 0o644 << 16
        z.writestr(zi, text.encode())
        rows.append((f"{P}-2-evidence.zip", f"{P}/{arc}", "本脚本生成", len(text.encode()), sha(text.encode())))

# ---------------------------------------------------------------- ③ 文档与 PPT
items3, doc_rows = [], []
for arc, src, from_git, title, req in DOCS:
    path = (SRC if from_git else ROOT) / src
    data = path.read_bytes()
    pages = pptx_slides(data) if arc.endswith(".pptx") else pdf_pages(path)
    source = f"`{src}`（git archive HEAD）" if from_git else f"`{src}`（生成物）"
    items3.append((arc, data, source))
    doc_rows.append((arc, title, req, pages, len(data), sha(data), source))
readme3 = f"# {P} 技术文档与讲解 PPT（③）\n\n作品 XiangShan-vdot · 参赛团队 SNL · 作品仓库 {REPO_URL}\n\n" \
          "| 文件 | 标题 | 对应赛题提交内容 | 页数 | sha256 |\n|---|---|---|---:|---|\n" + \
          "".join(f"| `{a}` | {t} | {q} | {p} | `{h}` |\n" for a, t, q, p, n, h, s in doc_rows) + \
          "\n主结论（三册封面与 PPT 封面一致）：MinimalConfig 全核实测 latency 加速比，单次 16 元素点积 1.70×（函数整体），" \
          "长向量稳态 1.81× / 2.25×（单累加器 / 2 累加器）；后两项中低于建模值的标「未达建模值」。\n" \
          "每册 PDF 有封面、目录、页码与书签，各自独立成书。\n"
write_zip(f"{P}-3-docs.zip", f"{P}-docs", items3, [("README.md", readme3)])

# ---------------------------------------------------------------- ④ 演示视频
items4, vid_rows = [], []
for key, title, req in VIDEOS:
    for ext in ("mp4", "srt"):
        rel = f"demo/video/{P}-{key}.{ext}"
        if (SRC / rel).exists():
            path, source = SRC / rel, f"`{rel}`（git archive HEAD）"
            disk = ROOT / rel
            if disk.exists() and disk.read_bytes() != path.read_bytes():
                sys.exit(f"{rel}: working tree differs from HEAD; commit or restore it first")
        else:
            path, source = ROOT / rel, f"`{rel}`（生成物，因体积不入库）"
        data = path.read_bytes()
        items4.append((f"{P}-{key}.{ext}", data, source))
        vid_rows.append((f"{P}-{key}.{ext}", title if ext == "mp4" else "外挂字幕（与画面烧录字幕同内容）", req,
                         video_info(path) if ext == "mp4" else "UTF-8 SRT", len(data), sha(data), source))
readme4 = f"# {P} 演示视频（④）\n\n作品 XiangShan-vdot · 参赛团队 SNL\n\n" \
          "| 文件 | 内容 | 对应赛题提交内容 | 参数 | sha256 |\n|---|---|---|---|---|\n" + \
          "".join(f"| `{a}` | {t} | {q} | {i} | `{h}` |\n" for a, t, q, i, n, h, s in vid_rows) + \
          "\n中文字幕已烧录在画面中；同内容的外挂字幕为同名 `.srt`。分镜与每张卡片的数据出处见作品仓库 `demo/video/storyboard.md`。\n"
write_zip(f"{P}-4-video.zip", f"{P}-video", items4, [("README.md", readme4)], stored=True)

# ---------------------------------------------------------------- 清单
B = [f"{P}-{k}.zip" for k in ("1-source", "2-evidence", "3-docs", "4-video")]
bs = {b: ((OUT / b).stat().st_size, sha((OUT / b).read_bytes())) for b in B}
LOOSE = [f"{P}-vol1-stage1.pdf", f"{P}-vol2-stage2.pdf", f"{P}-vol3-stage3.pdf", f"{P}-slides.pdf"]
with open(OUT / "SHA256SUMS", "w") as f:
    for n in B + LOOSE:
        f.write(f"{sha(((OUT if n in B else UP) / n).read_bytes())}  {n}\n")
with open(OUT / "bundle-contents.tsv", "w") as f:
    f.write("bundle\tpath_in_bundle\tsource\tbytes\tsha256\n")
    for r in rows:
        f.write("\t".join(str(x).replace("`", "") for x in r) + "\n")

desc = {
    B[0]: f"源码、脚本与文档 Markdown：仓库提交 `{SRC_ID}` 的 `git archive` 快照去掉日志与成品，{len(src_files)} 个文件；包内 `MANIFEST-source.md` 与逐文件 `SHA256SUMS-source`",
    B[1]: f"证据：`logs/`（真实终端日志、{sum(1 for r in ev_files if r.endswith('.vcd'))} 份波形 VCD 与文本轨迹）、`bench/results/`、文档中的图，{len(ev_files)} 个文件，路径与仓库一致；包内 `README-evidence.md` 与 `SHA256SUMS-evidence`",
    B[2]: "技术文档三册 PDF + 讲解 PPT（pptx 与 PDF），明细见下节",
    B[3]: "演示视频三段（mp4）+ 外挂字幕（srt），不压缩存储，明细见下节",
}
req = {B[0]: "代码仓库（补充材料）", B[1]: "文档提交 ①（阶段一执行日志）及全部证据", B[2]: "文档提交 ①②③、PPT", B[3]: "视频 ①②③"}
md = [f"# 上传包清单（XiangShan-vdot · SNL）", "",
      f"赛题：面向边缘 AI 大语言模型推理的 RISC-V 自定义 vdot 指令设计。作品仓库：{REPO_URL} 。",
      f"由 `bash submission/upload/build-bundles.sh` 生成；包内容取自仓库提交 `{SRC_ID}`（`git archive`）与已生成的成品文件，"
      "本清单、`SHA256SUMS`、`bundle-contents.tsv` 三个文件描述这些包本身，不放入包内，其后续提交不改变包内容。",
      "四个包的 sha256 与 `submission/upload/SHA256SUMS` 一致；每个包内每个文件的来源、大小与 sha256 逐行列在 `bundle-contents.tsv`。",
      "加密提交与 PR 流程见 `docs/ppt/提交清单.md`；大赛系统的各上传栏目与格式要求**待确认**。", "",
      "## 四个上传包", "",
      "| 包（附件文件名） | 内容 | 对应赛题提交内容 | 大小 | sha256 |", "|---|---|---|---:|---|"]
md += [f"| `{b}` | {desc[b]} | {req[b]} | {mb(bs[b][0])} | `{bs[b][1]}` |" for b in B]
md += ["", f"## {B[2]} 内容（根目录 `{P}-docs/`）", "",
       "| 包内文件 | 标题 | 对应赛题提交内容 | 页数 | 大小 | sha256 | 来源 |", "|---|---|---|---:|---:|---|---|"]
md += [f"| `{a}` | {t} | {q} | {p} | {mb(n)} | `{h}` | {s} |" for a, t, q, p, n, h, s in doc_rows]
md += ["", f"## {B[3]} 内容（根目录 `{P}-video/`）", "",
       "| 包内文件 | 内容 | 对应赛题提交内容 | 参数 | 大小 | sha256 | 来源 |", "|---|---|---|---|---:|---|---|"]
md += [f"| `{a}` | {t} | {q} | {i} | {mb(n)} | `{h}` | {s} |" for a, t, q, i, n, h, s in vid_rows]
md += ["", "## 主结论口径", "",
       "MinimalConfig 全核实测 latency 加速比：单次 16 元素点积 1.70×（函数整体，52 → 30.5 拍），长向量稳态 1.81×（单累加器，12.64 → 7.00 拍/迭代）/ "
       "2.25×（2 累加器，12.64 → 5.63 拍/迭代）；1.70× 与 2.25× 未达建模值（2.00× / 3.00×）。出处 `README.md` §1.2、"
       "`docs/stage3/22_基线实现与延迟加速分析.md` §5.5、`bench/results/speedup.csv`、`bench/results/cycles_fullcore.csv`。", "",
       "## 本地复核", "",
       "```sh", "cd submission/upload && sha256sum -c SHA256SUMS", "```", "",
       "`submission/upload/` 下散放的三册 PDF 与 PPT 的 PDF 与 `" + B[2] + "` 内的完全相同（见 `SHA256SUMS`）；各包均远小于 500 MB。",
       "文档、证据或视频有改动时：先提交到仓库，按「三册 PDF → PPT / 视频 → 四个包」的顺序重新生成，再提交新的清单与 `SHA256SUMS`。", ""]
(OUT / "提交清单.md").write_text("\n".join(md))
for b in B:
    print(f"{b:38s} {bs[b][0]:>11,} B  {bs[b][1]}")
