#!/usr/bin/env python3
"""Split the rehearsal recording into one cast per terminal scene.

  python3 splitcast.py casts/rehearsal.cast casts/

Input: the asciinema v2 recording of `rehearsal.sh` (one run on the build machine, all three videos).
`rehearsal.sh` prints `################  segment <name>` before each scene; a scene runs from the event
after its marker to the next marker (the marker line itself is not shown). Timestamps are re-based to the
scene's first byte; no output line is rewritten. Output: casts/<name>.cast (asciinema v2).
The script asserts that no secret-looking string (token, password) appears in the output.
"""
import json, os, re, sys

MARK = re.compile(r'#{8,}  segment (\S+)')

def main():
    src, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    lines = open(src, encoding='utf-8').read().splitlines()
    hdr = json.loads(lines[0]); assert hdr.get('version') == 2, 'expected an asciinema v2 cast'
    events = [json.loads(l) for l in lines[1:]]
    events = [(e[0], e[2]) for e in events if e[1] == 'o']
    for _, s in events:
        assert not re.search(r'(?i)(token|passw(or)?d)\s*[:=]', s), s
    marks = [(i, MARK.search(s).group(1)) for i, (_, s) in enumerate(events) if MARK.search(s)]
    for k, (i0, name) in enumerate(marks):
        i1 = marks[k + 1][0] if k + 1 < len(marks) else len(events)
        seg = events[i0 + 1:i1]
        if name == 'end' or not seg: continue
        t0 = seg[0][0]
        path = os.path.join(outdir, f'{name}.cast')
        with open(path, 'w', encoding='utf-8') as f:
            f.write(json.dumps({'version': 2, 'width': hdr['width'], 'height': hdr['height'], 'timestamp': hdr.get('timestamp', 0),
                                'title': f'XiangShan-vdot rehearsal: scene {name}'}) + '\n')
            for tt, s in seg:
                f.write(json.dumps([round(tt - t0, 3), 'o', s], ensure_ascii=False) + '\n')
            f.write(json.dumps([round(seg[-1][0] - t0, 3), 'm', 'end'], ensure_ascii=False) + '\n')
        print(f'{path}: {len(seg)} events, {seg[-1][0] - t0:.1f} s (source {t0:.1f}..{seg[-1][0]:.1f} s)', file=sys.stderr)

if __name__ == '__main__':
    main()
