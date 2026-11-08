#!/usr/bin/env python3
"""Cards for the three videos (PIL). A card is drawn from a spec dict that lives in the scene table
(storyboard.py), next to the captions of the same scene, so a number on a card and the caption that reads it
come from one place. Every number in a spec names its document section in the spec's `src` line.

Layout rule: everything must fit. Tiles, bullets, tables and footers assert their bottom edge against the
area left above the caption band; an overflow raises during `make_video.py --cards`, never clips silently.
"""
import os
from PIL import Image, ImageDraw
from render import (W, H, TOP_H, CAP_H, BG, FG, PANEL, EDGE, MUTED, C_BASE, C_OURS, C_ACC, C_OK, C_NEG,
                    font, text, draw_top, wrap_words)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
PROJECT = 'XiangShan-vdot'
PROJECT_CN = '面向边缘 AI 大语言模型推理的 RISC-V 自定义 vdot 指令设计'
TEAM = 'SNL'
PLATFORM = '香山昆明湖 V2（XiangShan kunminghu-v2 @ a4eeaab · YunSuan @ 9559211 · NEMU @ 9090839）'
WHITE = (250, 250, 250)
COLORS = {'base': C_BASE, 'ours': C_OURS, 'acc': C_ACC, 'ok': C_OK, 'neg': C_NEG}
BOTTOM = H - CAP_H - 44          # lowest y for card content (the source line sits below it)

# ---------------------------------------------------------------- primitives
def base(title, right=None):
    img = Image.new('RGB', (W, H), BG); draw_top(img, title, right); return img

def tile(d, x, y, w, h, big, small, col=C_OURS, sub=''):
    """Stat tile: label, big number, sub lines. Overflow raises."""
    d.rounded_rectangle([x, y, x + w, y + h], radius=16, fill=PANEL, outline=EDGE, width=2)
    d.rectangle([x, y + 18, x + 6, y + h - 18], fill=col)
    fs = 24
    while font('cjk', fs).getlength(small) > w - 50 and fs > 17: fs -= 1
    assert font('cjk', fs).getlength(small) <= w - 50, f'tile label too long: {small}'
    text(d, (x + 30, y + 18), small, font('cjk', fs), MUTED)
    fb = 44
    while font('cjkb', fb).getlength(big) > w - 50: fb -= 2
    assert fb >= 26, f'tile number too long: {big}'
    yb = y + 18 + fs + 10
    text(d, (x + 30, yb), big, font('cjkb', fb), WHITE)
    if sub:
        ys = yb + int(fb * 1.15) + 8
        ls = wrap_words(sub, font('cjk', 21), w - 50)
        assert ys + len(ls) * 27 <= y + h - 8, f'tile sub does not fit ({len(ls)} lines, h={h}): {sub}'
        for i, l in enumerate(ls): text(d, (x + 30, ys + i * 27), l, font('cjk', 21), MUTED)

def bullets(d, x, y, w, items, size=26, gap=None, col=FG, limit=BOTTOM):
    """Bullets; an item starting with '!' is amber (a negative / unmet / caveat line). Overflow raises."""
    if gap is None: gap = int(size * 0.5)
    f = font('cjk', size); lh = int(size * 1.45); ind = int(f.getlength('· '))
    for p in items:
        c = col
        if p.startswith('!'): p, c = p[1:], C_ACC
        ls = wrap_words(p, f, w - ind - 10)
        for i, l in enumerate(ls):
            text(d, (x + (ind if i else 0), y), ('· ' if i == 0 else '') + l, f, c); y += lh
        y += gap
    assert y - gap <= limit, f'bullets overflow by {y - gap - limit}px: {items[-1][:40]}'
    return y

def bullets_h(w, items, size, gap=10):
    f = font('cjk', size); lh = int(size * 1.45); ind = int(f.getlength('· '))
    return sum(len(wrap_words(p.lstrip('!'), f, w - ind - 10)) * lh + gap for p in items) - gap

def fit_size(w, h, items, lo, hi):
    """Largest font size in [lo, hi] at which the bullets fit into w x h (lo is asserted by bullets())."""
    for s in range(hi, lo - 1, -1):
        if bullets_h(w, items, s, gap=int(s * 0.5)) <= h: return s
    return lo

def figure(img, path, x, y, w, h, pad=12):
    """Paste a repository figure scaled into the box on a light panel; returns the box actually used."""
    im = Image.open(os.path.join(ROOT, path)).convert('RGB')
    s = min((w - 2 * pad) / im.width, (h - 2 * pad) / im.height)
    im = im.resize((int(im.width * s), int(im.height * s)), Image.LANCZOS)
    d = ImageDraw.Draw(img)
    bw, bh = im.width + 2 * pad, im.height + 2 * pad
    bx, by = x + (w - bw) // 2, y + (h - bh) // 2
    d.rounded_rectangle([bx, by, bx + bw, by + bh], radius=12, fill=(252, 252, 252), outline=EDGE, width=2)
    img.paste(im, (bx + pad, by + pad))
    return bx, by, bw, bh

def table(d, x, y, cols, rows, head_size=25, size=24, line=34, limit=BOTTOM):
    """cols: [(x_offset, width, header)], rows: [[cell, ...]]; a cell may be (text, colour_key). Overflow raises."""
    for ox, w, hd in cols: text(d, (x + ox, y), hd, font('cjkb', head_size), C_ACC)
    y += head_size + 18; d.line([x, y, x + cols[-1][0] + cols[-1][1], y], fill=(80, 82, 90), width=2); y += 10
    f = font('cjk', size); fb = font('cjkb', size)
    for r in rows:
        hs = []
        for (ox, w, _), cell in zip(cols, r):
            s, col, bold = cell, FG, False
            if isinstance(cell, tuple): s, col, bold = cell[0], COLORS.get(cell[1], FG), True
            ls = wrap_words(s, fb if bold else f, w - 16); hs.append(len(ls))
            for i, l in enumerate(ls): text(d, (x + ox, y + i * line), l, fb if bold else f, col)
        y += max(hs) * line + 12; d.line([x, y - 6, x + cols[-1][0] + cols[-1][1], y - 6], fill=(48, 50, 56), width=1)
    assert y <= limit, f'table overflow by {y - limit}px'
    return y

def foot_h(s, size=25):
    return 26 + len(wrap_words(s, font('cjkb', size), W - 170)) * int(size * 1.5)

def foot(d, y, s, size=25, col=(235, 240, 245), fill=(30, 48, 62)):
    fl = wrap_words(s, font('cjkb', size), W - 170); hh = foot_h(s, size)
    d.rounded_rectangle([50, y, W - 50, y + hh], radius=12, fill=fill)
    for i, l in enumerate(fl): text(d, (80, y + 13 + i * int(size * 1.5)), l, font('cjkb', size), col)
    return y + hh

def source(d, s):
    if not s: return
    f = font('cjk', 20)
    assert f.getlength('出处：' + s) <= W - 80, f'source line too long: {s}'
    text(d, (W - 40, H - CAP_H - 12), '出处：' + s, f, MUTED, 'rs')

# ---------------------------------------------------------------- generic card from a spec
def card(spec):
    """spec keys: title, right, src, tiles [(big, label, sub, colour)], tile_h, bullets, bsize, figs [path],
    split (left fraction for bullets when figs present), fig_layout 'col'|'row', table {cols, rows, size, line}, foot."""
    img = base(spec['title'], spec.get('right')); d = ImageDraw.Draw(img)
    y = TOP_H + 28; x0, x1 = 50, W - 50
    bottom = BOTTOM
    if spec.get('foot'): bottom -= foot_h(spec['foot']) + 16
    if spec.get('tiles'):
        n = len(spec['tiles']); gap = 26; tw = (x1 - x0 - gap * (n - 1)) // n; th = spec.get('tile_h', 190)
        for i, t in enumerate(spec['tiles']):
            big, label, sub, col = (tuple(t) + ('', 'ours'))[:4]
            tile(d, x0 + i * (tw + gap), y, tw, th, big, label, COLORS[col], sub)
        y += th + 26
    figs = spec.get('figs', []); bl = spec.get('bullets', []); tb = spec.get('table')
    if tb:
        y = table(d, x0 + 10, y, tb['cols'], tb['rows'], size=tb.get('size', 24), line=tb.get('line', 34), limit=bottom) + 10
    if figs and bl:
        lw = int((x1 - x0) * spec.get('split', 0.42))
        bullets(d, x0, y + 4, lw, bl, size=fit_size(lw, bottom - y - 4, bl, spec.get('bsize', 24), 32), limit=bottom)
        fx, fw = x0 + lw + 30, x1 - x0 - lw - 30
        _figs(img, figs, fx, y, fw, bottom - y, spec.get('fig_layout', 'col'))
    elif figs:
        _figs(img, figs, x0, y, x1 - x0, bottom - y, spec.get('fig_layout', 'row'))
    elif bl:
        bullets(d, x0, y + 4, x1 - x0, bl, size=fit_size(x1 - x0, bottom - y - 4, bl, spec.get('bsize', 24), 36), limit=bottom)
    if spec.get('foot'): foot(d, bottom + 16, spec['foot'])
    source(d, spec.get('src', ''))
    return img

def _figs(img, figs, x, y, w, h, layout):
    n = len(figs); gap = 18
    for i, p in enumerate(figs):
        if layout == 'col': figure(img, p, x, y + i * (h + gap) // n, w, (h - gap * (n - 1)) // n)
        else: figure(img, p, x + i * (w + gap) // n, y, (w - gap * (n - 1)) // n, h)

# ---------------------------------------------------------------- title / closing cards
def title_card(spec):
    img = Image.new('RGB', (W, H), (18, 20, 24)); d = ImageDraw.Draw(img)
    d.rectangle([0, 0, 16, H], fill=C_OURS)
    text(d, (120, 78), spec['video'], font('cjkb', 64), WHITE)
    assert font('cjkb', 64).getlength(spec['video']) <= W - 200, 'title too long'
    text(d, (120, 172), spec['sub'], font('cjkb', 36), (225, 228, 232))
    assert font('cjkb', 36).getlength(spec['sub']) <= W - 200, 'subtitle too long'
    text(d, (120, 240), f'作品：{PROJECT}（{PROJECT_CN}）', font('cjk', 28), (205, 210, 215))
    text(d, (120, 288), '平台：' + PLATFORM, font('cjk', 26), MUTED)
    text(d, (120, 342), f'参赛队伍：{TEAM}', font('cjkb', 34), C_ACC)
    n = len(spec['tiles']); gap = 26; tw = (W - 240 - gap * (n - 1)) // n
    for i, t in enumerate(spec['tiles']):
        big, label, sub, col = (tuple(t) + ('', 'ours'))[:4]
        tile(d, 120 + i * (tw + gap), 430, tw, 250, big, label, COLORS[col], sub)
    y = 720
    for l in spec.get('notes', []):
        ls = wrap_words(l, font('cjk', 25), W - 240)
        for s in ls: text(d, (120, y), s, font('cjk', 25), MUTED); y += 38
    assert y <= H - CAP_H - 10, 'title notes overflow'
    return img

def closing_card(spec):
    img = Image.new('RGB', (W, H), (18, 20, 24)); d = ImageDraw.Draw(img)
    d.rectangle([0, 0, 16, H], fill=C_OURS)
    text(d, (120, 80), spec['title'], font('cjkb', 50), WHITE)
    lim = H - CAP_H - 150
    y = bullets(d, 120, 185, W - 240, spec['bullets'], size=fit_size(W - 240, lim - 185, spec['bullets'], 26, 38), limit=lim)
    text(d, (120, H - CAP_H - 120), f'{PROJECT} · 参赛队伍 {TEAM}', font('cjkb', 34), C_ACC)
    text(d, (W - 120, H - CAP_H - 120), '谢谢观看', font('cjkb', 34), WHITE, 'ra')
    return img
