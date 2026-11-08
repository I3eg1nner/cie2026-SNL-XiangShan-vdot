#!/usr/bin/env python3
"""Rendering library for the demo video: asciinema casts -> 1920x1080 frames (terminal panel,
title bar, real-time / speed badge, burned-in Chinese captions), slide frames, ffmpeg encoding.

Dependencies: Pillow, fontTools, ffmpeg (FFMPEG env var, else imageio-ffmpeg's bundled binary, else PATH).
Fonts (Linux): DejaVu Sans Mono (terminal ASCII) and WenQuanYi Zen Hei (CJK; bold = 1 px stroke).
Every string drawn through `text()` is checked against the font cmaps, so a missing glyph fails the
build instead of rendering as a box.
"""
import bisect, json, os, re, subprocess, unicodedata
from functools import lru_cache
from PIL import Image, ImageDraw, ImageFont
from fontTools.ttLib import TTCollection, TTFont

W, H, FPS = 1920, 1080, 30
def _ffmpeg():
    if os.environ.get('FFMPEG'): return os.environ['FFMPEG']
    try:
        import imageio_ffmpeg; return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError: return 'ffmpeg'
FFMPEG = _ffmpeg()
MONO = os.environ.get('VIDEO_MONO', '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf')
MONOB = os.environ.get('VIDEO_MONOB', '/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf')
CJK = os.environ.get('VIDEO_CJK', '/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc')   # index 0 = Zen Hei
TOP_H, CAP_H = 72, 128
BG = (24, 24, 26); TERM_BG = (16, 17, 20); FG = (215, 218, 222); PANEL = (36, 38, 44); EDGE = (60, 62, 70)
C_BASE = (150, 154, 160)      # baseline / scalar arms
C_OURS = (77, 143, 224)       # this project's arms (blue, as in the deck)
C_ACC = (240, 190, 70)        # emphasis (amber)
C_OK = (98, 200, 120)         # pass / positive
C_NEG = (235, 95, 90)         # negative / reject
MUTED = (150, 154, 160)
ANSI = {30: (90, 90, 90), 31: C_NEG, 32: C_OK, 33: (235, 200, 90), 34: (100, 150, 240),
        35: (200, 120, 220), 36: (90, 200, 220), 37: (240, 240, 240)}

_menlo_cmap = set(TTFont(MONO).getBestCmap())
_hira_cmap = set(TTCollection(CJK).fonts[0].getBestCmap())
_BOLD = set()

@lru_cache(None)
def font(kind, size):
    if kind == 'mono': return ImageFont.truetype(MONO, size)
    if kind == 'monob': return ImageFont.truetype(MONOB, size)
    if kind == 'cjk': return ImageFont.truetype(CJK, size, index=0)
    if kind == 'cjkb':
        f = ImageFont.truetype(CJK, size, index=0); _BOLD.add(id(f)); return f
    raise KeyError(kind)

def check_glyphs(s, f):
    cmap = _menlo_cmap if f.path in (MONO, MONOB) else _hira_cmap
    bad = sorted({ch for ch in s if ord(ch) >= 32 and ord(ch) not in cmap and ch not in '\n'})
    if bad: raise ValueError(f'glyphs missing in {os.path.basename(f.path)}: {bad!r} in {s[:60]!r}')

def text(d, xy, s, f, fill, anchor='la'):
    """ImageDraw.text with a glyph check (the one place slides draw text through); bold CJK = 1 px stroke."""
    check_glyphs(s, f)
    if id(f) in _BOLD: d.text(xy, s, font=f, fill=fill, anchor=anchor, stroke_width=1, stroke_fill=fill)
    else: d.text(xy, s, font=f, fill=fill, anchor=anchor)

def char_kind(ch):
    o = ord(ch)
    if o < 0x2E80 and o in _menlo_cmap: return 'm', 1
    if o in _hira_cmap: return 'c', 2 if unicodedata.east_asian_width(ch) in 'WF' else 1
    if o in _menlo_cmap: return 'm', 1
    return None, 0

# result lines highlighted green/bold in terminal scenes (the scripts' own PASS / summary lines)
KEYLINES = ('HIT GOOD TRAP', 'RESULT: PASS', 'RESULT(VALUE)', 'RESULT(LEGALITY)', 'OFFICIAL-PSEUDOCODE-EQUIV', 'TOTAL cases=',
            'FAULT-INJECTION', 'RTL-SYNC-CHECK: PASS', 'CORPUS TOTAL', '---- case #0 : MATCH', 'hello xiangshan, I am', '合计 ')

# ---------------------------------------------------------------- terminal emulation (newline, CR, EL, SGR colours)
CSI = re.compile(r'\x1b\[([0-9;?]*)([A-Za-z])')

class Term:
    def __init__(self, cols):
        self.cols = cols; self.lines = [[]]; self.col = 0; self.color = FG; self.bold = False
    def _nl(self):
        self.lines.append([]); self.col = 0
        if len(self.lines) > 2000: self.lines = self.lines[-1000:]
    def _put(self, ch):
        k, w = char_kind(ch)
        if not k: return
        if self.col + w > self.cols: self._nl()
        line = self.lines[-1]; cell = (ch, k, w, self.color, self.bold)
        pos = 0; i = 0
        while i < len(line) and pos < self.col: pos += line[i][2]; i += 1
        if pos == self.col and i < len(line): line[i] = cell
        else: line.append(cell)
        self.col += w
    def write(self, s):
        i = 0
        while i < len(s):
            ch = s[i]
            if ch == '\x1b':
                m = CSI.match(s, i)
                if m:
                    args, cmd = m.group(1), m.group(2)
                    if cmd == 'm':
                        for a in (args or '0').split(';'):
                            a = int(a) if a.isdigit() else 0
                            if a == 0: self.color, self.bold = FG, False
                            elif a == 1: self.bold = True
                            elif a in ANSI: self.color = ANSI[a]
                    elif cmd == 'K':
                        line = self.lines[-1]; pos = 0; j = 0
                        while j < len(line) and pos < self.col: pos += line[j][2]; j += 1
                        del line[j:]
                    i = m.end(); continue
                i += 1; continue
            if ch == '\n': self._nl()
            elif ch == '\r':
                if s[i + 1:i + 2] == '\n': self._nl(); i += 1
                else: self.col = 0
            elif ch == '\t':
                for _ in range(8 - self.col % 8): self._put(' ')
            elif ch == '\b': self.col = max(0, self.col - 1)
            elif ord(ch) >= 32: self._put(ch)
            i += 1
    def snapshot(self, rows):
        """Last `rows` logical lines, with the demo scripts' own line conventions highlighted:
        notes keep their own ANSI colour (yellow), `$ ` command lines white bold, `==`/`##` headers cyan, result lines (KEYLINES) green."""
        out = []
        for l in self.lines[-rows:]:
            head = ''.join(c[0] for c in l[:12])
            if head.startswith('$ '): l = tuple((c[0], c[1], c[2], (245, 245, 245), True) for c in l)
            elif head.startswith('== ') or head.startswith('####') or head.startswith('SUMMARY'): l = tuple((c[0], c[1], c[2], ANSI[36], True) for c in l)
            elif head.startswith('PASS'): l = tuple((c[0], c[1], c[2], C_OK if i < 4 else c[3], c[4]) for i, c in enumerate(l))
            elif any(k in ''.join(c[0] for c in l) for k in KEYLINES):
                col = C_ACC if 'FAIL (' in ''.join(c[0] for c in l) else C_OK
                l = tuple((c[0], c[1], c[2], col, True) for c in l)
            out.append(tuple(l))
        return tuple(out)

@lru_cache(4096)
def render_line(line, size, cw, lh):
    if not line: return None
    width = sum(c[2] for c in line) * cw + 4
    im = Image.new('RGBA', (int(width), lh), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    x = 0
    for ch, k, w, color, bold in line:
        if k == 'm':
            d.text((x, lh - 6), ch, font=font('monob' if bold else 'mono', size), fill=color, anchor='ls')
        else:
            d.text((x + w * cw / 2, lh - 6), ch, font=font('cjk', int(size * 1.08)), fill=color, anchor='ms',
                   **({'stroke_width': 1, 'stroke_fill': color} if bold else {}))
        x += w * cw
    return im

class Cast:
    """asciinema v2 cast (absolute seconds). `find()` maps a caption anchor to real time."""
    def __init__(self, path):
        lines = open(path, encoding='utf-8').read().splitlines()
        self.events = [json.loads(l) for l in lines[1:]]
        out = []; last = -1.0
        for e in self.events:          # ties (same ms) get distinct times so a hold can stop between two events
            if e[1] != 'o': continue
            t = max(e[0], last + 1e-5); out.append((t, e[2])); last = t
        self.out = out
        self.marks = {e[2]: e[0] for e in self.events if e[1] == 'm'}
        self.end = max(self.events[-1][0], self.out[-1][0])
        self.times = [t for t, _ in self.out]
    def find(self, anchor):
        """anchor -> real seconds: re:<regex> (first output event after which the regex matches the
        accumulated output) | t:<seconds> | end"""
        if anchor == 'end': return self.end
        if anchor.startswith('t:'): return float(anchor[2:])
        if anchor.startswith('re:'):
            rx = re.compile(anchor[3:]); acc = ''
            for t, s in self.out:
                acc = (acc + s)[-6000:]
                if rx.search(acc): return t
            raise KeyError(anchor)
        raise KeyError(anchor)

class TermView:
    """Draws the cast's screen at any real time into a region; advances incrementally."""
    def __init__(self, cast, cols, rows, size):
        self.cast, self.cols, self.rows, self.size = cast, cols, rows, size
        self.cw = font('mono', size).getlength('M'); self.lh = int(size * 1.38)
        self.term = Term(cols); self.i = 0; self.t = -1
    def advance(self, t):
        assert t >= self.t; self.t = t
        while self.i < len(self.cast.out) and self.cast.out[self.i][0] <= t:
            self.term.write(self.cast.out[self.i][1]); self.i += 1
    def draw(self, img, x0, y0, cursor=True):
        snap = self.term.snapshot(self.rows)
        for r, line in enumerate(snap):
            li = render_line(line, self.size, self.cw, self.lh)
            if li is not None: img.paste(li, (x0, y0 + r * self.lh), li)
        if cursor and snap:
            last = snap[-1]; cx = x0 + sum(c[2] for c in last) * self.cw
            ImageDraw.Draw(img).rectangle([cx + 2, y0 + (len(snap) - 1) * self.lh + 6, cx + self.cw - 1, y0 + len(snap) * self.lh - 4], fill=(200, 200, 200))

# ---------------------------------------------------------------- real time <-> video time
class TimeMap:
    """Output bursts play at `active` x; a silent gap longer than `thresh` s plays at `idle` x
    (time-lapse) after its first `thresh` seconds. `holds` = [(real_s, video_s)]: the picture freezes
    at that real time for that many video seconds (a reading pause; the badge shows 定格)."""
    def __init__(self, times, end, active=1.0, idle=10.0, thresh=1.2, start=0.0, holds=()):
        hold = {}
        for r, d in holds: hold[r] = hold.get(r, 0.0) + d
        ts = sorted(set([start] + [t for t in times if t >= start] + [end] + list(hold)))
        self.r = [start]; self.v = [0.0]; self.hold_v = {}
        if start in hold: self.hold_v[start] = 0.0; self._add(start, hold[start])
        for a, b in zip(ts, ts[1:]):
            g = b - a
            if g <= thresh: self._add(b, g / active)
            else: self._add(a + thresh, thresh / active); self._add(b, (g - thresh) / idle)
            if b in hold: self.hold_v[b] = self.v[-1]; self._add(b, hold[b])
        self.dur = self.v[-1]
    def _add(self, r, dv):
        self.r.append(r); self.v.append(self.v[-1] + dv)
    def real(self, v):
        if v >= self.dur: return self.r[-1]
        i = max(0, bisect.bisect_right(self.v, v) - 1)
        if self.v[i + 1] == self.v[i]: return self.r[i + 1]
        return self.r[i] + (v - self.v[i]) * (self.r[i + 1] - self.r[i]) / (self.v[i + 1] - self.v[i])
    def speed(self, v):
        i = min(max(0, bisect.bisect_right(self.v, v) - 1), len(self.v) - 2)
        dv = self.v[i + 1] - self.v[i]
        return (self.r[i + 1] - self.r[i]) / dv if dv > 0 else 1.0
    def video(self, r):
        if r in self.hold_v: return self.hold_v[r]
        i = min(max(0, bisect.bisect_right(self.r, r) - 1), len(self.r) - 2)
        dr = self.r[i + 1] - self.r[i]
        return self.v[i] + ((r - self.r[i]) / dr * (self.v[i + 1] - self.v[i]) if dr > 0 else 0)

# ---------------------------------------------------------------- shared frame elements
def wrap_words(text_, f, maxw):
    """Word wrap: ASCII words (paths, numbers, punctuation) stay whole, CJK breaks per character;
    no CJK closing punctuation at a line start, no opening bracket at a line end."""
    toks = re.findall(r"[A-Za-z0-9_./+:=×%…→·'^\-]+ ?|\s|.", text_)
    out, cur = [], ''
    for t in toks:
        if f.getlength(cur + t.rstrip()) > maxw and cur.strip() and t[0] not in '，。；：、）」！？,;:)':
            carry = ''
            while cur and cur[-1] in '（「(': carry = cur[-1] + carry; cur = cur[:-1]
            out.append(cur.rstrip()); cur = carry + t.lstrip()
        else: cur += t
    if cur.strip(): out.append(cur.rstrip())
    return out

def draw_top(img, title, right=''):
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, TOP_H], fill=(34, 36, 42)); d.rectangle([0, TOP_H - 3, W, TOP_H], fill=C_OURS)
    rw = font('cjk', 24).getlength(right) + 40 if right else 0
    fs = 34
    while font('cjkb', fs).getlength(title) > W - 80 - rw and fs > 24: fs -= 1
    assert font('cjkb', fs).getlength(title) <= W - 80 - rw, f'title too long: {title}'
    text(d, (40, TOP_H // 2), title, font('cjkb', fs), (245, 245, 245), 'lm')
    if right: text(d, (W - 40, TOP_H // 2), right, font('cjk', 24), MUTED, 'rm')

def draw_caption(img, s):
    if not s: return
    d = ImageDraw.Draw(img)
    d.rectangle([0, H - CAP_H, W, H], fill=(8, 8, 10))
    f = font('cjkb', 36); lines = wrap_words(s, f, W - 160)
    assert len(lines) <= 2, f'caption needs {len(lines)} lines: {s}'
    y = H - CAP_H / 2 - (len(lines) - 1) * 24
    for i, l in enumerate(lines):
        text(d, (W / 2, y + i * 48), l, f, (255, 255, 255), 'mm')

def draw_badge(img, x_right, y, real_s, speed):
    d = ImageDraw.Draw(img)
    mm, ss = divmod(int(real_s), 60)
    sv = f'{speed:.0f}' if speed >= 2.5 or abs(speed - round(speed)) < 0.05 else f'{speed:.1f}'
    if speed < 0.01: arrows, rest = ('||', '定格')
    else: arrows, rest = ('>>', f'加速 ×{sv}') if speed > 1.05 else ('>', '实时 ×1')
    txt = f'实际耗时 {mm:02d}:{ss:02d}'
    f = font('cjkb', 26); fm = font('monob', 24)
    w1 = f.getlength(txt); w2 = fm.getlength(arrows) + 8 + f.getlength(rest)
    x0 = x_right - w1 - w2 - 46
    d.rounded_rectangle([x0, y, x_right, y + 46], radius=10, fill=(40, 40, 46), outline=(80, 80, 90))
    text(d, (x0 + 16, y + 23), txt, f, (240, 240, 240), 'lm')
    col = C_ACC if speed > 1.05 else (150, 200, 240) if speed < 0.01 else (150, 220, 160)
    xx = x0 + 30 + w1
    text(d, (xx, y + 23), arrows, fm, col, 'lm')
    text(d, (xx + fm.getlength(arrows) + 8, y + 23), rest, f, col, 'lm')

# ---------------------------------------------------------------- captions timeline (srt)
class Captions:
    def __init__(self): self.items = []   # (start, end, text) in global video seconds
    def srt(self, path):
        def ts(x):
            ms = int(round(x * 1000)); h, ms = divmod(ms, 3600000); m, ms = divmod(ms, 60000); s, ms = divmod(ms, 1000)
            return f'{h:02d}:{m:02d}:{s:02d},{ms:03d}'
        with open(path, 'w', encoding='utf-8') as f:
            for i, (a, b, t) in enumerate(self.items, 1): f.write(f'{i}\n{ts(a)} --> {ts(b)}\n{t}\n\n')

def caption_at(caps, v):
    cur = ''
    for t, s in sorted(caps):
        if t <= v: cur = s
    return cur

# ---------------------------------------------------------------- encoding
class Encoder:
    def __init__(self, path):
        self.p = subprocess.Popen([FFMPEG, '-y', '-loglevel', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{W}x{H}',
                                   '-r', str(FPS), '-i', '-', '-c:v', 'libx264', '-preset', 'medium', '-crf', '20', '-pix_fmt', 'yuv420p',
                                   '-r', str(FPS), path], stdin=subprocess.PIPE)
        self.n = 0
    def frame(self, img):
        self.p.stdin.write(img.tobytes()); self.n += 1
    def repeat(self, img, n):
        b = img.tobytes()
        for _ in range(n): self.p.stdin.write(b)
        self.n += n
    def close(self):
        self.p.stdin.close(); assert self.p.wait() == 0
