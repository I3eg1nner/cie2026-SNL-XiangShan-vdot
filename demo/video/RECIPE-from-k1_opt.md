# How the k1_opt demo video was made (read-only study, 2026-11-07)

Source: `~/code/k1_opt/research/20261105/video.md`, `submission/upload/storyboard.md`,
`submission/upload/video-src/{make_video.py,render.py,slides.py,record.py,logcast.py}`,
`项目演示视频.{mp4,srt}` (ffprobe + 10 extracted frames), `目录说明.pdf`, `比赛要求.md`.

## Deliverable shape

- `项目演示视频.mp4`: 1920×1080, 30 fps, H.264 yuv420p, **silent** stereo AAC track (anullsrc), faststart;
  6 min 32 s (391.8 s), 19.6 MB. Contest limit is one file ≤ 500 MB; the video is uploaded on its own, not inside a zip.
- `项目演示视频.srt`: the same Chinese captions that are burned into the frames, one entry per caption.
- `storyboard.md`: scene table (number, scene id, what is on screen, data source), per-scene durations, how the
  terminal footage was obtained, and the exact regeneration commands.
- `video-src/`: the generator (scripts + raw casts + board scripts), checked in; `build/` intermediates are not.
- No narration. The owner may record a voice track later against the `.srt` timeline and swap the audio with
  `ffmpeg -map 0:v -map 1:a -c:v copy` without re-rendering.

## Toolchain

Python 3 + Pillow + fontTools (via matplotlib) + ffmpeg only. Fonts: macOS `Menlo` (monospace ASCII) and
`Hiragino Sans GB` (CJK, W3/W6). Charts: matplotlib with the same dark palette, or the submission's own PNGs.
Each scene is rendered to raw RGB frames and piped into `ffmpeg -c:v libx264 -crf 20` as `build/seg-XX.mp4`;
the scenes are concatenated with the concat demuxer (`-c:v copy`) and the silent AAC track is added at the end.

## Structure (18 scenes)

Title card with the project name, task, platform, team name and four headline tiles → section cards numbered ①–⑨
following the organiser's chain → terminal scenes (board environment, one-click deploy, chat, side-by-side
comparisons) → result slides (bars, decay curves, TTFT) → optimisation tables → quality card → closing card with the
deliverables list and "谢谢观看". Durations 8–55 s per scene; slides 10–15 s; terminal scenes as long as the
(sped-up) real run needs.

## Terminal scenes are rendered, not screen-recorded

- `record.py` runs each command on the board over ssh (`-tt`, `TERM=dumb`), records the output chunks with real
  arrival times as an asciinema v2 `.cast`, synthesises the prompt and a 30 ms/char typing animation, and writes a
  `cmd:N` marker per command for caption anchoring.
- `render.py` has a tiny terminal emulator (newline, CR, EL, SGR colours), a `TimeMap` that plays output bursts at
  ×1–×3 and gaps longer than ~1 s at ×6–×20 (time-lapse), and a badge in the top-right corner that always shows the
  **real elapsed time and the current speed factor**. Side-by-side scenes share one clock and one speed.
- Caption anchors: `cmd:N`, `re:<regex>` (first appearance in the output), `t:` real seconds or `v:` video seconds.
- `logcast.py` turns a host-side `run.log` (stage timestamps + wall seconds) into a cast for a long pipeline.

## Style rules

- Dark theme (`#18181a` background, `#101114` terminal), one accent per arm (legacy blue / ours green / amber for
  emphasis); 34 px bold title bar with a right-aligned data-source note; 36 px bold white captions on a black
  128 px band at the bottom, ≤ 2 lines, word-wrapped so ASCII words and paths are never split and CJK closing
  punctuation never starts a line.
- Stat tiles: small label, big number, grey sub-line; numbers in slides are typed into `slides.py` from the
  performance report sections and the storyboard names the section for every number.
- Nothing in the frames or the generator reveals credentials, proxy settings or the developer's home directory
  (grep'd before delivery); missing glyphs (`−`, `ᵀ`, emoji) are replaced or dropped.
- Honesty markers in captions: "现场单次复测，计分以报告为准", warnings printed by the scripts are explained, not cut.
- QA: ffprobe spec, `ffmpeg -f null` full decode, a dozen extracted frames inspected for missing glyphs, overflow
  and occlusion; the title card states how the terminal footage was produced.

## What we keep / change for riscv-db-opt

Same toolchain, frame geometry, caption band, badge and encoding settings. Differences: our terminal footage is
the existing rehearsal-3 asciinema recording of `demo/run_all.sh` (split per segment by `splitcast.py`, board
address and developer paths scrubbed) instead of a fresh `record.py` session; our charts are the submission's own
`docs/submission/charts/*.png` rather than matplotlib drawn inside `slides.py`; the storyline follows the
organiser's four-step chain (组件选型 → QEMU 跑通 → 架构创新 → 生态闭环); and every card carries the ledger label,
k/N and τ of each number because that is how the written submission reports them.
