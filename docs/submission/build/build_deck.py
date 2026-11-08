#!/usr/bin/env python3
"""Build docs/submission/SNL-XiangShan-vdot-slides.pptx from docs/ppt/讲解大纲.md (python-pptx 1.0.2).

    python3 docs/submission/build/build_deck.py            # pptx only
    bash   docs/submission/build/render_deck.sh            # pptx + PDF + PNG pages

The outline is the single source: for every "## P…" section the generator takes the title
(**标题**), the bullet points (**要点**), the headline line (**主结论**, P17), the Markdown table
(P17 / P21), the evidence line (**证据出处**) and the speaker notes (**讲者备注**). This file only
adds layout: which figure goes on which page, the evidence level of the page
(实测 / 源码推导 / 建模 / 声明值), and the cover. Numbers are not recomputed or retyped, except
the three headline tiles on the cover, which are asserted against README.md §1.2 below.

Every text box and table is measured with the real font metrics before it is written; if the text
does not fit even at the minimum font size the build stops with an error (FitError) instead of
producing an overflowing slide.
"""
import os
import re
import sys

from PIL import Image, ImageFont
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, MSO_AUTO_SIZE, PP_ALIGN
from pptx.oxml.ns import qn
from pptx.util import Emu, Inches, Pt

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OUTLINE = os.path.join(ROOT, "docs", "ppt", "讲解大纲.md")
README = os.path.join(ROOT, "README.md")
OUT = os.environ.get("DECK_OUT", os.path.join(ROOT, "docs", "submission", "SNL-XiangShan-vdot-slides.pptx"))

TEAM = "SNL"
WORK = "XiangShan-vdot"
REPO = "https://github.com/I3eg1nner/cie2026-SNL-XiangShan-vdot"

# Linux: the CJK face is WenQuanYi Zen Hei (fc-list :lang=zh). The same face is written into
# <a:latin> and <a:ea> so LibreOffice and PowerPoint pick one font for mixed runs.
FONT = os.environ.get("DECK_FONT", "WenQuanYi Zen Hei")
MONO = os.environ.get("DECK_MONO", "WenQuanYi Zen Hei Mono")
FONT_FILE = os.environ.get("DECK_FONT_FILE", "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc")
MONO_INDEX = 2  # index of "WenQuanYi Zen Hei Mono" inside wqy-zenhei.ttc

INK = RGBColor(0x14, 0x14, 0x14)
INK2 = RGBColor(0x4A, 0x4A, 0x4A)
MUTED = RGBColor(0x80, 0x80, 0x80)
BLUE = RGBColor(0x2A, 0x78, 0xD6)
NAVY = RGBColor(0x10, 0x42, 0x81)
ORANGE = RGBColor(0xC8, 0x50, 0x1E)
GREEN = RGBColor(0x1B, 0x8F, 0x5A)
PANEL = RGBColor(0xF0, 0xF1, 0xF4)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)
LEVEL_COLOR = {"实测": GREEN, "源码推导": BLUE, "建模": ORANGE, "声明值": MUTED}

W, H = Inches(13.333), Inches(7.5)
prs = Presentation()
prs.slide_width, prs.slide_height = W, H
BLANK = prs.slide_layouts[6]
PAGE = [0]
PAGE_OF = {}  # outline id -> first page number

LEFT = Inches(0.45)
FULL_W = Inches(12.43)
BODY_Y = Inches(1.15)
BODY_BOTTOM = Inches(6.80)


# ----------------------------------------------------------------------------- fit check
class FitError(RuntimeError):
    pass


_FONTS = {}


def _font(mono=False):
    key = MONO_INDEX if mono else 0
    if key not in _FONTS:
        _FONTS[key] = ImageFont.truetype(FONT_FILE, 200, index=key)
    return _FONTS[key]


ASC, DESC = _font().getmetrics()
LINE_FACTOR = (ASC + DESC) / 200.0  # natural line height / font size (≈1.27 for WQY Zen Hei)
TOKEN = re.compile(r"[A-Za-z0-9_.\-/:@#%+*=<>|\\~^$&'\"\[\]{}(),;!?]+|\s+|.", re.S)


def _width_pt(s, size, mono=False, bold=False):
    w = _font(mono).getlength(s) * size / 200.0
    return w * (1.06 if bold else 1.0)


def wrap_count(s, size, width_pt, mono=False, bold=False):
    """Number of lines `s` needs in a box `width_pt` wide (Latin runs break at spaces, CJK anywhere)."""
    lines, cur = 1, 0.0
    for tok in TOKEN.findall(s):
        tw = _width_pt(tok, size, mono, bold)
        if tok.isspace():
            cur += tw
            continue
        if cur + tw <= width_pt:
            cur += tw
        elif tw <= width_pt:
            lines += 1
            cur = tw
        else:  # a token longer than the line: broken by characters
            for ch in tok:
                cw = _width_pt(ch, size, mono, bold)
                if cur + cw > width_pt:
                    lines += 1
                    cur = 0.0
                cur += cw
    return lines


def text_height_pt(paras, width_pt, spacing):
    """paras: list of (text, size, bold, mono, gap_pt). Height in pt with 4 % safety margin."""
    h = 0.0
    for t, size, bold, mono, gap in paras:
        n = wrap_count(t, size, width_pt * 0.97, mono, bold)
        h += n * size * LINE_FACTOR * spacing + gap
    return h * 1.04


# ----------------------------------------------------------------------------- helpers
def _run(p, text, size, bold=False, color=INK, font=FONT):
    r = p.add_run()
    r.text = text
    r.font.size = Pt(size)
    r.font.bold = bold
    r.font.name = font
    rpr = r._r.get_or_add_rPr()
    for tag in ("a:ea", "a:cs"):  # python-pptx writes only <a:latin>; CJK uses <a:ea>
        el = rpr.find(qn(tag))
        if el is None:
            el = rpr.makeelement(qn(tag), {})
            rpr.append(el)
        el.set("typeface", font)
    r.font.color.rgb = color
    return r


MARGIN_LR = Inches(0.08)
MARGIN_TB = Inches(0.04)


def text(slide, x, y, w, h, lines, size=14, min_size=None, color=INK, bold=False, font=FONT,
         align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP, spacing=1.12, fill=None, what="text"):
    """lines: list of str | (str, dict) ; dict keys: size,bold,color,font,bullet,level,gap.

    Shrinks the base size in 0.5 pt steps down to min_size until the text fits; raises FitError otherwise.
    Per-line sizes given in dict are scaled with the same factor."""
    min_size = min_size or size
    mono = font == MONO
    width_pt = (w - 2 * MARGIN_LR) / 12700.0
    height_pt = (h - 2 * MARGIN_TB) / 12700.0
    s = size
    while True:
        k = s / size
        paras = []
        for ln in lines:
            o = ln[1] if isinstance(ln, tuple) else {}
            t = ln[0] if isinstance(ln, tuple) else ln
            pre = ("• " if o.get("level", 0) == 0 else "– ") if o.get("bullet") else ""
            if o.get("level", 0):
                pre = "    " + pre
            paras.append((pre + t, o.get("size", size) * k, o.get("bold", bold), o.get("font", font) == MONO,
                          o.get("gap", 0) * k))
        need = text_height_pt(paras, width_pt, spacing)
        if need <= height_pt:
            break
        if s - 0.5 < min_size - 1e-6:
            raise FitError(f"[slide {PAGE[0]}] {what}: needs {need:.0f} pt, box {height_pt:.0f} pt at {s} pt "
                           f"(min {min_size}); first line: {paras[0][0][:40]!r}")
        s -= 0.5
    tb = slide.shapes.add_textbox(x, y, w, h)
    tf = tb.text_frame
    tf.word_wrap = True
    tf.auto_size = MSO_AUTO_SIZE.NONE
    tf.vertical_anchor = anchor
    tf.margin_left = tf.margin_right = MARGIN_LR
    tf.margin_top = tf.margin_bottom = MARGIN_TB
    if fill is not None:
        tb.fill.solid()
        tb.fill.fore_color.rgb = fill
    for i, (ln, (t, sz, b, m, gap)) in enumerate(zip(lines, paras)):
        o = ln[1] if isinstance(ln, tuple) else {}
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align
        p.line_spacing = spacing
        if gap:
            p.space_before = Pt(gap)
        _run(p, t, round(sz * 2) / 2, b, o.get("color", color), o.get("font", font))
    return tb, s


def picture(slide, path, x, y, max_w, max_h, align="center"):
    if not os.path.isfile(path):
        raise FileNotFoundError(path)
    with Image.open(path) as im:
        pw, ph = im.size
    scale = min(max_w / pw, max_h / ph)
    w, h = int(pw * scale), int(ph * scale)
    if align == "center":
        x = x + (max_w - w) // 2
    return slide.shapes.add_picture(path, x, y, w, h), h


def table(slide, rows, x, y, w, col_w, max_h, size=11, min_size=8, emph_rows=()):
    """Table whose height is measured; shrinks the font until rows fit max_h, else FitError."""
    nrows, ncols = len(rows), len(rows[0])
    tot = sum(col_w)
    widths = [int(w * c / tot) for c in col_w]
    cell_m = Inches(0.05)
    s = size
    while True:
        heights = []
        for i, row in enumerate(rows):
            hmax = 0.0
            for j, cell in enumerate(row):
                wpt = (widths[j] - 2 * cell_m) / 12700.0
                hh = text_height_pt([(str(cell), s, i == 0 or i in emph_rows, False, 0)], wpt, 1.0) + 4
                hmax = max(hmax, hh)
            heights.append(hmax)
        if sum(heights) * 12700 <= max_h:
            break
        if s - 0.5 < min_size:
            raise FitError(f"[slide {PAGE[0]}] table: needs {sum(heights):.0f} pt, box {max_h / 12700:.0f} pt "
                           f"at {s} pt (min {min_size})")
        s -= 0.5
    shp = slide.shapes.add_table(nrows, ncols, x, y, w, int(sum(heights) * 12700))
    tbl = shp.table
    for j, cw in enumerate(widths):
        tbl.columns[j].width = cw
    for i, row in enumerate(rows):
        tbl.rows[i].height = int(heights[i] * 12700)
        for j, cell in enumerate(row):
            c = tbl.cell(i, j)
            c.margin_left = c.margin_right = cell_m
            c.margin_top = c.margin_bottom = Inches(0.02)
            tf = c.text_frame
            tf.word_wrap = True
            head = i == 0
            _run(tf.paragraphs[0], str(cell), s, head or i in emph_rows, WHITE if head else INK)
            c.fill.solid()
            c.fill.fore_color.rgb = NAVY if head else (RGBColor(0xFF, 0xF4, 0xE0) if i in emph_rows
                                                       else (PANEL if i % 2 == 0 else WHITE))
    return shp, int(sum(heights) * 12700)


def rect(slide, x, y, w, h, color):
    r = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, x, y, w, h)
    r.fill.solid()
    r.fill.fore_color.rgb = color
    r.line.fill.background()
    return r


def footer(slide, sources, level):
    """Data-source line (as many outline items as fit in two lines, rest in the notes) + evidence level."""
    items = [i.strip() for i in re.split(r"[；;]\s*", sources) if i.strip()]
    box_w, box_h = Inches(8.45), Inches(0.42)
    width_pt = (box_w - 2 * MARGIN_LR) / 12700.0
    height_pt = (box_h - 2 * MARGIN_TB) / 12700.0
    shown = []
    for k in range(len(items), 0, -1):
        cand = "数据来源：" + "；".join(items[:k]) + ("" if k == len(items) else "；其余出处见讲者备注")
        if text_height_pt([(cand, 8, False, False, 0)], width_pt, 1.0) <= height_pt:
            shown = cand
            break
    if not shown:
        raise FitError(f"[slide {PAGE[0]}] footer: first source item does not fit: {items[0][:60]!r}")
    text(slide, LEFT, Inches(6.98), box_w, box_h, [shown], size=8, color=MUTED, spacing=1.0,
         anchor=MSO_ANCHOR.MIDDLE, what="footer")
    lv = [x.strip() for x in level.split("/")]
    for x in lv:
        assert x in LEVEL_COLOR, f"unknown evidence level {x!r}"
    text(slide, Inches(8.95), Inches(6.98), Inches(3.45), Inches(0.42), [f"证据等级：{' / '.join(lv)}"],
         size=9, min_size=7.5, color=LEVEL_COLOR[lv[0]], bold=True, align=PP_ALIGN.RIGHT,
         anchor=MSO_ANCHOR.MIDDLE, what="level")
    text(slide, Inches(12.4), Inches(6.98), Inches(0.5), Inches(0.42), [str(PAGE[0])], size=10, color=MUTED,
         align=PP_ALIGN.RIGHT, anchor=MSO_ANCHOR.MIDDLE, what="page number")


def new_slide(title, sources, level):
    s = prs.slides.add_slide(BLANK)
    PAGE[0] += 1
    text(s, LEFT, Inches(0.2), FULL_W, Inches(0.8), [title], size=24, min_size=17, bold=True, color=NAVY,
         anchor=MSO_ANCHOR.MIDDLE, spacing=1.0, what="title")
    rect(s, Inches(0.5), Inches(1.02), Inches(12.33), Emu(12000), BLUE)
    footer(s, sources, level)
    return s


def notes(slide, txt):
    slide.notes_slide.notes_text_frame.text = txt


# ----------------------------------------------------------------------------- outline parser
def md_plain(s):
    s = re.sub(r"\*\*(.+?)\*\*", r"\1", s)
    s = s.replace("`", "")
    return s.strip()


def parse_outline(path):
    src = open(path, encoding="utf-8").read()
    secs = re.split(r"^## (?=P\d|备用页)", src, flags=re.M)[1:]
    out = {}
    for sec in secs:
        sec = sec.split("\n---")[0]
        head = sec.split("\n", 1)[0]
        m = re.match(r"(?:备用页 )?(P\w+)\s*　?(.*)", head)
        pid, name = m.group(1), m.group(2).strip()
        d = {"id": pid, "name": name, "bullets": [], "table": [], "code": []}
        field = None
        in_code = False
        for ln in sec.split("\n")[1:]:
            if ln.strip().startswith("```"):
                in_code = not in_code
                continue
            if in_code:
                d["code"].append(ln.strip("\n")[4:] if ln.startswith("    ") else ln)
                continue
            fm = re.match(r"^- \*\*(.+?)\*\*(?:（[^）]*）)?[：:]?\s*(.*)$", ln)
            if fm:
                field = fm.group(1)
                val = fm.group(2).strip()
                if field == "讲者备注":
                    val = re.sub(r"^（约[^）]*）[：:]\s*", "", val)
                if val:
                    d.setdefault(field, val)
                continue
            if ln.startswith("|"):
                cells = [md_plain(c) for c in ln.strip().strip("|").split("|")]
                if not all(re.fullmatch(r":?-+:?", c) for c in cells):
                    d["table"].append(cells)
                continue
            bm = re.match(r"^(\s+)- (.*)$", ln)
            if bm and field == "要点":
                lvl = 0 if len(bm.group(1)) <= 2 else 1
                d["bullets"].append((md_plain(bm.group(2)), lvl))
        for k in ("标题", "证据出处", "讲者备注", "主结论"):
            if k in d:
                d[k] = md_plain(d[k]) if k != "证据出处" else d[k].replace("`", "")
        out[pid] = d
    return out


O = parse_outline(OUTLINE)
EXPECTED = ["P1", "P2", "P3", "P4", "P5", "P5A", "P6", "P7", "P8", "P9", "P10", "P11", "P12", "P12A",
            "P13", "P14", "P15", "P16", "P17", "P18", "P19", "P20", "P21"]
assert list(O) == EXPECTED, f"outline sections changed: {list(O)}"


def _pages_of(pid):
    return 2 if pid == "P17" else len(CFG.get(pid, {}).get("pages", [None]))


def page_map():
    m, n = {}, 1
    for pid in EXPECTED:
        m[pid] = n
        n += _pages_of(pid)
    return m


def pref(t):
    """Outline page ids (P5A, P17 …) -> deck page numbers."""
    pm = page_map()
    return re.sub(r"\bP(\d+A?)\b", lambda m: f"第 {pm['P' + m.group(1)]} 页" if "P" + m.group(1) in pm
                  else m.group(0), t)


def fig(rel):
    return os.path.join(ROOT, rel)


def speaker_notes(d, extra_bullets=()):
    t = f"【{d['id']}】" + d.get("讲者备注", "")
    if extra_bullets:
        t += "\n\n页面未展开的要点：\n" + "\n".join("· " + pref(b) for b in extra_bullets)
    if d.get("证据出处"):
        t += "\n\n证据出处（完整）：" + d["证据出处"]
    return t


# ----------------------------------------------------------------------------- headline check
HEADLINE = [("1.70×", "单次 16 元素点积", "函数整体（含装载与取回），52 → 30.5 拍；低于建模 2.00×（未达建模值）"),
            ("1.81×", "长向量稳态 · 单累加器", "vdotacc，12.64 → 7.00 拍 / 16 个 int8；高于建模 1.50×"),
            ("2.25×", "长向量稳态 · 2 累加器", "12.64 → 5.63 拍 / 16 个 int8；低于建模 3.00×（未达建模值）")]
_readme = open(README, encoding="utf-8").read()
_main = re.search(r"\*\*主结论\*\*.*?\n>.*?\n", _readme, re.S).group(0)
for num, _, sub in HEADLINE:
    assert num.replace("×", "") in _main, f"headline {num} not in README §1.2 主结论"
for frag in ("52 → 30.5", "12.64 → 7.00", "5.63"):
    assert frag in _main, frag
assert "1.70×" in O["P17"]["主结论"] and "1.81×" in O["P17"]["主结论"] and "2.25×" in O["P17"]["主结论"]

# ----------------------------------------------------------------------------- page layout config
# figs: list of figure paths (stacked in the right column, or full width when layout="wide")
# keep: indices of outline bullets shown on the page (default all); the others go to the notes
# level: evidence level(s) of the numbers on the page
S1 = "docs/stage1/figures/"
S2 = "docs/stage2/figures/"
S3 = "docs/stage3/figures/"
CFG = {
    "P2": dict(level="实测 / 源码推导 / 建模"),
    "P3": dict(level="实测 / 声明值"),
    "P4": dict(level="实测 / 源码推导", figs=[S1 + "fig1_handshake_latency.png", S1 + "fig7_fullcore_vadd_pipeline.png"],
               fig_w=5.0),
    "P5": dict(level="源码推导", figs=[S1 + "fig3_sew_carry_boundary.png"], fig_w=5.2),
    "P5A": dict(level="实测 / 源码推导", pages=[
        dict(keep=[0, 1, 2], code=True, figs=["docs/_recon/figures/vdot_official_semantics.jpg"], fig_w=5.6),
        dict(keep=[3, 4, 5, 6, 7], figs=[S3 + "fig10_fullcore_vdot_vl8_wave.png"], fig_w=6.0,
             sub="清零取舍、等价证据与全核 vl=8 实测"),
    ]),
    "P6": dict(level="源码推导 / 实测"),
    "P7": dict(level="实测 / 源码推导"),
    "P8": dict(level="实测 / 源码推导", figs=[S2 + "fig1_vdot_wave.png"], fig_w=6.4),
    "P9": dict(level="实测 / 源码推导", figs=[S2 + "fig2_vdotacc_wave.png", S2 + "fig3_vdot4a_wave.png"], fig_w=4.6),
    "P10": dict(level="实测", figs=[S2 + "fig1_vdot_wave.png"], fig_w=5.4),
    "P11": dict(level="实测"),
    "P12": dict(level="实测"),
    "P12A": dict(level="实测", pages=[
        dict(keep=[0, 1, 2, 3, 6, 7], figs=[S3 + "fig10_fullcore_vdot_vl8_wave.png"], fig_w=6.0),
        dict(keep=[4, 5], figs=[S3 + "fig8_fullcore_vdot_wave.png"], fig_w=6.4,
             sub="全核波形（vl=8 主演示与 vl=16 满寄存器版本）"),
    ]),
    "P13": dict(level="实测"),
    "P14": dict(level="实测"),
    "P15": dict(level="实测", figs=[S3 + "fig1_instr_count.png"], fig_w=5.6),
    "P16": dict(level="实测 / 声明值", figs=[S3 + "fig5_latency_wave_vdot.png", S3 + "fig3_latency.png"], fig_w=6.2),
    "P18": dict(level="建模 / 实测", figs=[S3 + "fig4_sensitivity.png", S3 + "fig9_fullcore_cycles.png"], fig_w=5.4),
    "P19": dict(level="源码推导 / 实测"),
    "P20": dict(level="实测 / 建模 / 声明值 / 源码推导"),
}


def bullets_box(s, items, x, y, w, h, size=19, min_size=10.5):
    lines = [(pref(t), dict(bullet=True, level=lvl, size=size if lvl == 0 else size - 1.5, gap=5 if lvl == 0 else 1))
             for t, lvl in items]
    return text(s, x, y, w, h, lines, size=size, min_size=min_size, what="bullets")


def figs_column(s, figs, x, y, w, h):
    gap = Inches(0.12)
    each = (h - gap * (len(figs) - 1)) // len(figs)
    cy = y
    for f in figs:
        _, ph = picture(s, fig(f), x, cy, w, each)
        cy += ph + gap


def standard(pid):
    d = O[pid]
    cfg = CFG.get(pid, {})
    pages = cfg.get("pages", [dict(keep=cfg.get("keep"), figs=cfg.get("figs", []), fig_w=cfg.get("fig_w"))])
    shown = set()
    for k, pg in enumerate(pages):
        keep = pg.get("keep")
        idx = list(range(len(d["bullets"]))) if keep is None else keep
        # nested (level 1) bullets follow their parent: keep them when the parent is kept
        items = []
        parent_kept = False
        for i, (t, lvl) in enumerate(d["bullets"]):
            if lvl == 0:
                parent_kept = i in idx
            if (lvl == 0 and i in idx) or (lvl == 1 and parent_kept):
                items.append((t, lvl))
                shown.add(i)
        title = d["标题"] if k == 0 else f"{d['name']}（续）：{pg['sub']}"
        s = new_slide(title, d.get("证据出处", ""), cfg.get("level", "实测"))
        figs = pg.get("figs", [])
        y, h = BODY_Y + Inches(0.08), BODY_BOTTOM - BODY_Y - Inches(0.08)
        if figs:
            fw = Inches(pg.get("fig_w") or 5.2)
            tw = FULL_W - fw - Inches(0.2)
            if pg.get("code"):  # first bullet is the caption of the pseudocode block
                text(s, LEFT, y, tw, Inches(0.4), [pref(items[0][0])], size=14, bold=True, what="code caption")
                text(s, LEFT, y + Inches(0.45), tw, Inches(2.3), d["code"], size=13, min_size=9, font=MONO,
                     fill=PANEL, spacing=1.0, what="code")
                code_h = Inches(2.9)
                bullets_box(s, items[1:], LEFT, y + code_h, tw, h - code_h, size=16)
            else:
                bullets_box(s, items, LEFT, y, tw, h)
            figs_column(s, figs, LEFT + tw + Inches(0.2), y, fw, h)
        else:
            bullets_box(s, items, LEFT, y, FULL_W, h, size=22, min_size=11)
        PAGE_OF.setdefault(pid, PAGE[0])
        last = k == len(pages) - 1
        dropped = [d["bullets"][i][0] for i in range(len(d["bullets"])) if i not in shown] if last else []
        extra = ("\n\n页面未展开的要点：\n" + "\n".join("· " + pref(b) for b in dropped)) if dropped else ""
        if k == 0:
            notes(s, speaker_notes(d) + extra)
        else:
            notes(s, f"【{pid}（续）】接上一页，讲者备注见上一页。" + extra)


# ============================================================================= slides
P17_PAGE = 21  # referenced from the cover note; asserted when P17 is laid out
# P1 cover
d = O["P1"]
s = prs.slides.add_slide(BLANK)
PAGE[0] += 1
rect(s, 0, 0, W, Inches(3.35), NAVY)
title_main, title_sub = d["标题"].split("——", 1)
text(s, Inches(0.6), Inches(0.45), Inches(12.1), Inches(1.95),
     [title_main, (title_sub, dict(size=20, bold=False))], size=32, min_size=24, bold=True, color=WHITE,
     what="cover title")
text(s, Inches(0.6), Inches(2.4), Inches(12.1), Inches(0.85),
     [f"参赛团队：{TEAM}　｜　作品：{WORK}　｜　作品仓库：{REPO}",
      ("平台：XiangShan kunminghu-v2 @ a4eeaab，YunSuan @ 9559211，NEMU @ 9090839", dict(size=13))],
     size=14, color=WHITE, what="cover meta")
text(s, Inches(0.6), Inches(3.55), Inches(12.1), Inches(0.45),
     ["主结论：香山 MinimalConfig 全核实测 latency 加速比（实测，全核 MinimalConfig，热态，带 difftest；默认配置未测）"],
     size=15, bold=True, color=INK, what="cover headline")
for i, (num, label, sub) in enumerate(HEADLINE):
    x = Inches(0.6) + i * Inches(4.1)
    rect(s, x, Inches(4.1), Inches(3.9), Inches(2.25), PANEL)
    rect(s, x, Inches(4.1), Inches(0.08), Inches(2.25), BLUE)
    text(s, x + Inches(0.2), Inches(4.12), Inches(3.6), Inches(0.92), [num], size=40, bold=True, color=NAVY,
         what="tile number")
    text(s, x + Inches(0.2), Inches(5.0), Inches(3.6), Inches(0.45), [label], size=15, bold=True, what="tile label")
    text(s, x + Inches(0.2), Inches(5.45), Inches(3.6), Inches(0.85), [sub], size=11.5, min_size=10, color=INK2,
         what="tile sub")
text(s, Inches(0.6), Inches(6.45), Inches(12.1), Inches(0.5),
     [f"其余口径（指令条数 3.00× 实测、uop 4.67× 源码推导、关键路径 2.00× 与吞吐 1.50× / 3.00× 建模）量纲不同，不替代主结论，见第 {P17_PAGE} 页。"],
     size=11, color=INK2, what="cover note")
footer(s, "README.md §1.2 主结论；docs/stage3/22_基线实现与延迟加速分析.md §5.5；bench/results/speedup.csv；"
          "bench/results/cycles_fullcore.csv；版本号 README.md:4", "实测")
notes(s, speaker_notes(d))

for pid in EXPECTED[1:EXPECTED.index("P17")]:
    standard(pid)


# P17 speed-up: headline + table, then the explanatory bullets with the full-core figure
d = O["P17"]
s = new_slide(d["标题"], d["证据出处"], "实测 / 建模 / 源码推导")
PAGE_OF["P17"] = PAGE[0]
assert PAGE_OF["P17"] == P17_PAGE, f"cover note points to page {P17_PAGE}, P17 is on page {PAGE[0]}"
text(s, LEFT, BODY_Y + Inches(0.05), FULL_W, Inches(0.95), ["主结论：" + d["主结论"]], size=14, min_size=11,
     bold=False, color=INK, fill=RGBColor(0xE6, 0xEF, 0xFA), what="P17 headline")
rows = d["table"]
emph = [i for i, r in enumerate(rows) if "主结论" in r[3]]
table(s, rows, LEFT, BODY_Y + Inches(1.1), FULL_W, [2.4, 2.0, 2.0, 4.0, 2.4], BODY_BOTTOM - BODY_Y - Inches(1.1),
      size=14, min_size=8.5, emph_rows=emph)
notes(s, speaker_notes(d))
s = new_slide("加速比（续）：全核计时方法与实测对模型", d["证据出处"], "实测 / 建模")
y, h = BODY_Y + Inches(0.08), BODY_BOTTOM - BODY_Y - Inches(0.08)
bullets_box(s, d["bullets"], LEFT, y, Inches(6.0), h, size=15)
figs_column(s, [S3 + "fig9_fullcore_cycles.png", S3 + "fig2_speedup.png"], LEFT + Inches(6.2), y, Inches(6.23), h)
notes(s, "【P17（续）】接上一页，讲者备注见上一页。\n\n证据出处（完整）：" + d["证据出处"])

for pid in ("P18", "P19", "P20"):
    standard(pid)

# P21 backup Q&A
d = O["P21"]
s = new_slide("备用页：预期追问与答法", "docs/ppt/讲解大纲.md 备用页 P21（各行依据列）", "实测 / 源码推导 / 建模")
table(s, d["table"], LEFT, BODY_Y + Inches(0.08), FULL_W, [2.6, 6.6, 2.6], BODY_BOTTOM - BODY_Y - Inches(0.08),
      size=15, min_size=8.5)
notes(s, "【备用页 P21】不放进正式讲解，答辩追问时翻到此页。")

prs.save(OUT)
print("saved", OUT, "slides:", len(prs.slides))
