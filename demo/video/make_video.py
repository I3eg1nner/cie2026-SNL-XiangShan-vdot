#!/usr/bin/env python3
"""Render the three contest videos scene by scene (build/v<N>/seg-<scene>.mp4), concatenate, add a silent
audio track, write each mp4 and its matching .srt. Scene table (cards + captions): storyboard.py.

  python3 make_video.py                     # all three videos
  python3 make_video.py --video 2           # only video 2
  python3 make_video.py --video 2 --only v2-05,v2-11   # re-render these scenes of video 2, then concatenate
  python3 make_video.py --cards             # export every card to build/cards/<scene>.png; overflow -> error
  python3 make_video.py --qa                # extract frames from the finished mp4s into build/qa/
  python3 make_video.py --md                # print the scene table (markdown) used in storyboard.md

Terminal scenes come from casts/<scene>.cast (splitcast.py over casts/rehearsal-2026-11-08.cast).
"""
import argparse, json, os, re, subprocess, sys
from PIL import Image, ImageDraw
from render import (W, H, FPS, TOP_H, CAP_H, BG, TERM_BG, MUTED, font, text, Cast, TermView, TimeMap,
                    draw_top, draw_caption, draw_badge, caption_at, Captions, Encoder, FFMPEG, wrap_words)
import slides
from storyboard import VIDEOS

HERE = os.path.dirname(os.path.abspath(__file__))
CASTS = os.path.join(HERE, 'casts'); BUILD = os.path.join(HERE, 'build')
OUT_DIR = os.environ.get('VIDEO_OUT', HERE)

# ---------------------------------------------------------------- scene renderers
def save_meta(path, caps, nframes):
    dur = nframes / FPS; caps = sorted(caps)
    items = [(a, caps[i + 1][0] if i + 1 < len(caps) else dur, t) for i, (a, t) in enumerate(caps)]
    json.dump({'frames': nframes, 'caps': [x for x in items if x[2] and x[1] > x[0]]},
              open(path.replace('.mp4', '.json'), 'w'), ensure_ascii=False)

def check_caps(caps):
    for _, s in caps: draw_caption(Image.new('RGB', (W, H)), s)    # asserts <= 2 lines

def seg_slide(path, img, dur, caps):
    check_caps(caps)
    enc = Encoder(path)
    pts = sorted(set([0.0] + [c[0] for c in caps if c[0] < dur]))
    for i, a in enumerate(pts):
        b = pts[i + 1] if i + 1 < len(pts) else dur
        fr = img.copy(); draw_caption(fr, caption_at(caps, a + 1e-6)); enc.repeat(fr, round(b * FPS) - round(a * FPS))
    enc.close(); save_meta(path, caps, enc.n)

MIN_CAP = 3.5   # a caption without a hold stays at least this long

def seg_term(path, sc):
    cast = Cast(os.path.join(CASTS, sc['cast']))
    raw = sc['caps']; check_caps([(0, c[1]) for c in raw])
    anchors = [(cast.find(c[0]), c[1], c[2] if len(c) > 2 else 0.0) for c in raw]
    holds = [(t, h) for t, _, h in anchors if h > 0]
    tm = TimeMap(cast.times, cast.end, sc.get('active', 1.0), sc.get('idle', 4.0), sc.get('thresh', 1.5), holds=holds)
    caps = []; used = {}      # captions sharing one hold point follow each other inside that hold
    for t, s, h in sorted(anchors, key=lambda a: a[0]):
        v = tm.video(t) + used.get(t, 0.0); used[t] = used.get(t, 0.0) + h
        if caps and v < caps[-1][0] + MIN_CAP: v = caps[-1][0] + MIN_CAP
        caps.append((v, s))
    tail = max(sc.get('tail', 3.0), caps[-1][0] + MIN_CAP - tm.dur)
    size = 20
    x0, y0 = 30, TOP_H + 14; x1, y1 = W - 30, H - CAP_H - 14
    cw = font('mono', size).getlength('M'); lh = int(size * 1.36)
    cols = int((x1 - x0 - 40) / cw); rows = int((y1 - y0 - 64) / lh)
    tv = TermView(cast, cols, rows, size)
    basei = Image.new('RGB', (W, H), BG); draw_top(basei, sc['title'], right=sc.get('right', '本机演练录制 2026-11-08 · Linux x86_64'))
    d = ImageDraw.Draw(basei); d.rounded_rectangle([x0, y0, x1, y1], radius=14, fill=TERM_BG, outline=(60, 62, 70), width=2)
    for i, c in enumerate([(235, 95, 90), (235, 190, 70), (98, 200, 120)]):
        d.ellipse([x0 + 22 + i * 30, y0 + 20, x0 + 38 + i * 30, y0 + 36], fill=c)
    text(d, (x0 + 130, y0 + 28), sc.get('host', '$ cd cie2026-vdot-xiangshan   （仓库根目录；日志写到 /tmp/rec）'), font('cjk', 22), MUTED, 'lm')
    dur = tm.dur + tail; n = int(round(dur * FPS)); enc = Encoder(path)
    for k in range(n):
        v = k / FPS; r = tm.real(v); tv.advance(r)
        fr = basei.copy(); tv.draw(fr, x0 + 20, y0 + 56, cursor=v < tm.dur)
        draw_badge(fr, x1 - 14, y0 + 6, r, tm.speed(v) if v < tm.dur else 1.0)
        draw_caption(fr, caption_at(caps, v)); enc.frame(fr)
    enc.close(); save_meta(path, caps, enc.n)

def card_image(sc):
    k = sc['kind']
    if k == 'title': return slides.title_card(sc['spec'])
    if k == 'closing': return slides.closing_card(sc['spec'])
    return slides.card(sc['spec'])

def render_scene(path, sc):
    if sc['kind'] == 'term': return seg_term(path, sc)
    return seg_slide(path, card_image(sc), sc['dur'], sc['caps'])

# ---------------------------------------------------------------- main
def run_ffmpeg(args):
    subprocess.check_call([FFMPEG, '-y', '-loglevel', 'error'] + args)

def build_video(num, only):
    vd = VIDEOS[num]; bdir = os.path.join(BUILD, f'v{num}'); os.makedirs(bdir, exist_ok=True)
    for sc in vd['scenes']:
        p = os.path.join(bdir, f"seg-{sc['id']}.mp4")
        if only and sc['id'] not in only and os.path.exists(p): continue
        print(f"rendering {sc['id']} …", file=sys.stderr, flush=True); render_scene(p, sc)
    caps = Captions(); t = 0.0; lst = os.path.join(bdir, 'concat.txt')
    with open(lst, 'w') as f:
        for sc in vd['scenes']:
            f.write(f"file 'seg-{sc['id']}.mp4'\n")
            meta = json.load(open(os.path.join(bdir, f"seg-{sc['id']}.json")))
            dur = meta['frames'] / FPS
            for (s0, s1, s) in meta['caps']: caps.items.append((t + s0, t + min(s1, dur), s))
            print(f"  {sc['id']:12s} {dur:6.1f} s  starts at {t:6.1f} s", file=sys.stderr); t += dur
    out = os.path.join(OUT_DIR, vd['file'] + '.mp4')
    run_ffmpeg(['-f', 'concat', '-safe', '0', '-i', lst, '-f', 'lavfi', '-i', 'anullsrc=channel_layout=stereo:sample_rate=48000',
                '-map', '0:v', '-map', '1:a', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '64k', '-shortest',
                '-movflags', '+faststart', '-metadata', f"title={slides.PROJECT} {vd['title']}", out])
    caps.srt(os.path.splitext(out)[0] + '.srt')
    json.dump({'duration': t, 'scenes': [sc['id'] for sc in vd['scenes']]}, open(os.path.join(bdir, 'total.json'), 'w'))
    print(f'wrote {out}  total {t:.1f} s', file=sys.stderr)

def qa(num):
    vd = VIDEOS[num]; bdir = os.path.join(BUILD, f'v{num}'); qdir = os.path.join(BUILD, 'qa'); os.makedirs(qdir, exist_ok=True)
    out = os.path.join(OUT_DIR, vd['file'] + '.mp4'); t = 0.0
    for sc in vd['scenes']:
        dur = json.load(open(os.path.join(bdir, f"seg-{sc['id']}.json")))['frames'] / FPS
        for frac in ((0.3, 0.85) if sc['kind'] == 'term' else (0.6,)):
            run_ffmpeg(['-ss', f'{t + dur * frac:.2f}', '-i', out, '-frames:v', '1', os.path.join(qdir, f"{sc['id']}-{int(frac * 100)}.png")])
        t += dur
    print('qa frames in', qdir, file=sys.stderr)

def md():
    for num, vd in VIDEOS.items():
        print(f"\n### 视频{'一二三'[num - 1]}：{vd['title']}（`{vd['file']}.mp4`）\n")
        print('| # | 分镜 | 画面 | 数据来源 |\n|---|---|---|---|')
        for i, sc in enumerate(vd['scenes'], 1):
            print(f"| {i} | {sc['id']} | {sc['desc']} | {sc['src']} |")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--video', default='all'); ap.add_argument('--only', default='')
    ap.add_argument('--cards', action='store_true'); ap.add_argument('--qa', action='store_true'); ap.add_argument('--md', action='store_true')
    a = ap.parse_args(); os.makedirs(BUILD, exist_ok=True)
    nums = list(VIDEOS) if a.video == 'all' else [int(x) for x in a.video.split(',')]
    if a.md: return md()
    if a.cards:
        cdir = os.path.join(BUILD, 'cards'); os.makedirs(cdir, exist_ok=True); bad = 0
        for num in nums:
            for sc in VIDEOS[num]['scenes']:
                try:
                    if sc['kind'] == 'term': check_caps([(0, c[1]) for c in sc['caps']]); continue
                    check_caps(sc['caps'])
                    im = card_image(sc)
                    for c in sc['caps']: assert c[0] < sc['dur'] - 2, f'caption starts too late: {c[1][:20]}'
                    im.save(os.path.join(cdir, sc['id'] + '.png')); print('card', sc['id'], file=sys.stderr)
                except (AssertionError, ValueError) as e: bad += 1; print('card', sc['id'], 'FAILED:', e, file=sys.stderr)
        if bad: sys.exit(f'{bad} card(s) failed')
        return
    if a.qa:
        for num in nums: qa(num)
        return
    only = set(a.only.split(',')) if a.only else None
    for num in nums: build_video(num, only)

if __name__ == '__main__':
    main()
