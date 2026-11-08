# submission/upload/ — 评审材料（三册 PDF + 讲解 PPT）

全部由脚本从仓库文档生成，不手工排版；Markdown 与讲稿大纲是唯一来源，生成过程不改动任何数值。

| 成品 | 来源 | 生成脚本 |
|---|---|---|
| `SNL-XiangShan-vdot-vol1-stage1.pdf`　技术文档第一册 阶段一：环境部署与 vadd.vv 执行过程分析 | `docs/stage1/*.md` | `build-pdf.sh` |
| `SNL-XiangShan-vdot-vol2-stage2.pdf`　技术文档第二册 阶段二：vdot 指令设计、RTL 实现与基础功能测试 | `docs/stage2/*.md` | `build-pdf.sh` |
| `SNL-XiangShan-vdot-vol3-stage3.pdf`　技术文档第三册 阶段三：NEMU 扩展、协同仿真与延迟加速比分析 | `docs/stage3/*.md` | `build-pdf.sh` |
| `docs/submission/SNL-XiangShan-vdot-slides.pptx`　讲解 PPT（16:9，正文 25 页 + 备用页 1 页，每页带讲者备注） | `docs/ppt/讲解大纲.md` | `docs/submission/build/build_deck.py` |
| `SNL-XiangShan-vdot-slides.pdf`　讲解 PPT 的 PDF 版 | 上面的 pptx | `docs/submission/build/render_deck.sh` |

## 生成命令

```sh
# 三册 PDF（约 1 分钟）
PYTHON=/tmp/vizenv/bin/python bash submission/upload/build-pdf.sh
# 讲解 PPT + PDF；PAGES=1 时另把每页转成 PNG（/tmp/deck-pages/）供逐页检查
PYTHON=/tmp/vizenv/bin/python PAGES=1 bash docs/submission/build/render_deck.sh
```

`PYTHON` 指向装有 `python-pptx`、`Pillow`、`weasyprint` 的解释器（例：`uv venv /tmp/vizenv && uv pip install -p /tmp/vizenv python-pptx pillow weasyprint`）。
其他依赖：pandoc ≥ 3、LibreOffice（`soffice`，只用 Impress 组件）、poppler-utils（`pdfinfo` / `pdftoppm` / `pdffonts`）、字体 WenQuanYi Zen Hei（`fc-list :lang=zh`）。
没有 root 权限时，poppler 可用 `apt-get download poppler-utils libpoppler118` + `dpkg -x` 解包到本地目录，再用一个设置
`LD_LIBRARY_PATH` 的小包装脚本放进 `PATH`（不要全局导出 `LD_LIBRARY_PATH`，否则 `soffice` 会加载失败）。

## 做法

- **三册 PDF**（沿用 `riscv-db-opt` 模板的 md → pandoc HTML → 打印 PDF 流程，打印引擎由 headless Chrome 换为 WeasyPrint）：
  `pdf/assemble.py` 按文件名顺序拼接一个阶段目录下的全部文档，把图片路径改为绝对路径（三个 `figures/` 目录里有同名文件）；
  pandoc `gfm` → HTML（`pdf/template.html` 封面：赛题、团队、作品、仓库、平台版本、本册内容与收录文档、三册划分、主结论与出处；
  `pdf/style.css` 中文字体、A4、页码、带页码的目录；`pdf/links.lua` 把仓库内相对链接改成「文字（路径）」纯文本、`<br>` 改为换行）；
  WeasyPrint 输出 PDF（书签来自标题）。每册独立成书，各文档以一级标题起新页。
- **讲解 PPT**：`build_deck.py` 解析 `docs/ppt/讲解大纲.md` 的每个 `## P…` 小节，取「标题」「要点」「主结论」「证据出处」「讲者备注」与表格，
  脚本本身只决定版式（配图、证据等级、分页）。每页页脚为数据来源行（证据出处中放得下的部分，其余写进讲者备注）与证据等级
  （实测 / 源码推导 / 建模 / 声明值）；讲者备注 = 大纲的讲者备注 + 完整证据出处。所有文字同时写入 `<a:latin>` 与 `<a:ea>`。
  大纲中的页号（P5A、P17 …）自动换算成本 PPT 的页码；大纲有 22 页正文，其中 P5A、P12A、P17 内容较多，各拆成两页，共 25 页 + 备用页。
- **放得下断言**：每个文本框与表格写入前都用 WenQuanYi Zen Hei 的字形宽度按实际换行估算高度（留 4 % 余量），
  放不下就在规定下限内逐级缩小字号，到下限仍放不下即抛出 `FitError` 终止生成。
- **口径断言**：封面三个主结论数字（1.70× / 1.81× / 2.25×）及其周期（52 → 30.5、12.64 → 7.00、5.63）在生成时与 `README.md` §1.2「主结论」逐项比对，
  不一致即终止；低于建模值的两项标「未达建模值」。

## 入库范围

| 入库 | 文件 |
|---|---|
| 是 | 本目录 `README.md`、`提交清单.md`、`build-pdf.sh`、`pdf/{assemble.py,template.html,style.css,links.lua}`；`docs/submission/build/{build_deck.py,render_deck.sh}`；`docs/submission/SNL-XiangShan-vdot-slides.pptx` |
| 否（生成物，`.gitignore`） | 本目录下的 `*.pdf`、`*.html`；随 GitHub Release 发布 |
