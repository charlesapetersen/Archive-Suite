#!/usr/bin/env python3
"""transient-frames.py — scan a screen video of the GUI VM for flickers (W40.e13, the confirmation instrument).

The transient recorder (packages/UITestSupport/App/TransientRecorder.swift) reads the accessibility tree after
each committed run-loop pass; it cannot see a layer painted out of place, and a state it reports may never have
reached the screen. This reads the pixels instead: `vm-gui-runner.sh` with TRANSIENT_VIDEO=1 records the guest's
display across a UI-test run, and this script looks for a region of the screen that changes and then returns
to what it was within a short time — the A→B→A of a flicker.

    ops/gui/transient-frames.py <artifact dir>      # e.g. ~/.tart-mirror/vm-artifacts/notes
    ops/gui/transient-frames.py <dir> --max-ms 250 --tile 16 --frames 12

Reads <dir>/transient.mov (its creation_time places it on the guest's clock) and the
`transient-mark: <epoch> <name>` lines TransientCheck prints into <dir>/xcuitest.log, so each finding is named
by the transition it followed. Writes <dir>/transient-frames.txt and, for the first --frames findings, the frame
before, during and after each one as PNGs in <dir>/transient-frames/.

HOW. ffmpeg decodes every frame (variable frame rate, no frames dropped or duplicated) to grey, averaged down to
one value per --tile×--tile block. A block whose value moves more than --diff from its settled value and comes
back within --same of it, inside --max-ms, is a return. Returns that start and end on the same two frames are
one finding, with the bounding box of their blocks. A moving element (a sidebar sliding across) also passes
over blocks and leaves them as they were, but staggered: each column starts and ends on different frames, so it
shows as a run of small findings on neighbouring frames; the report marks those as `sweep`. A finding of more
than eight blocks is never a sweep.

LIMITS. A state shown for less than one frame of the video is invisible to it. The recording's frame rate is
what the guest's display offers to screencapture, measured in ops/gui/README.md §"Screen video". The text cursor
blinks slower than --max-ms, so it does not register; a caret or spinner faster than that would.

Needs ffmpeg and ffprobe on the host (Homebrew); no Python packages.
"""
import argparse
import bisect
import json
import os
import re
import subprocess
import sys


def probe(mov):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height,avg_frame_rate,r_frame_rate:format_tags=creation_time"
         ":frame=best_effort_timestamp_time",
         "-of", "json", mov], check=True, capture_output=True, text=True).stdout
    data = json.loads(out)
    stream = data["streams"][0]
    times = [float(f["best_effort_timestamp_time"]) for f in data["frames"]
             if f.get("best_effort_timestamp_time") not in (None, "N/A")]
    created = (data.get("format", {}).get("tags", {}) or {}).get("creation_time")
    if created:
        import datetime
        created = datetime.datetime.fromisoformat(created.replace("Z", "+00:00")).timestamp()
    return stream, times, created


def frames(mov, gw, gh):
    proc = subprocess.Popen(
        # -v fatal: screencapture repeats a timestamp now and then, and the rawvideo muxer logs each one as an
        # error while still writing the frame (decoded and probed counts match; checked below).
        ["ffmpeg", "-v", "fatal", "-i", mov, "-fps_mode", "passthrough",
         "-vf", f"scale={gw}:{gh}:flags=area,format=gray", "-f", "rawvideo", "-"],
        stdout=subprocess.PIPE)
    size = gw * gh
    while True:
        buf = proc.stdout.read(size)
        if len(buf) < size:
            break
        yield buf
    proc.wait()


def marks(log):
    found = []
    if os.path.exists(log):
        for line in open(log, errors="replace"):
            m = re.search(r"transient-mark: ([0-9.]+) (.+)$", line.rstrip("\n"))
            if m:
                found.append((float(m.group(1)), m.group(2)))
    found.sort()
    return found


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("dir")
    ap.add_argument("--tile", type=int, default=16, help="block size in video pixels (default 16)")
    ap.add_argument("--diff", type=float, default=4.0, help="grey levels a block must move to count (default 4)")
    ap.add_argument("--same", type=float, default=1.5, help="grey levels within which it has come back (1.5)")
    ap.add_argument("--max-ms", type=float, default=250.0, help="longest flicker, in ms (default 250)")
    ap.add_argument("--frames", type=int, default=12, help="findings to save frames for (default 12)")
    ap.add_argument("--ignore-bottom", type=int, default=120,
                    help="video pixels at the bottom to skip (default 120: the Dock, and the recorder's report "
                         "panel, which changes on every pass by design)")
    args = ap.parse_args()

    mov = os.path.join(args.dir, "transient.mov")
    if not os.path.exists(mov):
        sys.exit(f"no {mov} — run vm-gui-runner.sh with TRANSIENT_VIDEO=1 first")
    stream, times, created = probe(mov)
    # Where the movie starts on the guest's clock. screencapture writes no start time of its own, and the file
    # appears only once it is being finished, so the creation_time tag is all there is: whole seconds,
    # truncated, so the first frame is within [created, created + 1). The middle of that second puts each
    # finding within half a second, which is enough when the transitions are seconds apart. A
    # transient.start file beside the movie (one epoch) overrides it, for a recording made some other way.
    start, start_note = None, ""
    start_file = os.path.join(args.dir, "transient.start")
    if os.path.exists(start_file):
        start = float(open(start_file).read().strip())
    elif created is not None:
        start, start_note = created + 0.5, " (aligned on the movie's creation_time, ±0.5 s)"
    w, h = int(stream["width"]), int(stream["height"])
    gw, gh = max(1, w // args.tile), max(1, h // args.tile)
    duration = times[-1] - times[0] if len(times) > 1 else 0.0
    gaps = sorted(b - a for a, b in zip(times, times[1:]))
    median_gap = gaps[len(gaps) // 2] if gaps else 0.0
    max_s = args.max_ms / 1000.0
    rows = max(0, gh - (args.ignore_bottom + args.tile - 1) // args.tile)

    base = None            # settled value per block
    pending = {}           # block -> (start frame, settled value, max distance reached)
    returns = {}           # (start frame, end frame) -> list of blocks
    prev = None
    count = 0
    for i, cur in enumerate(frames(mov, gw, gh)):
        count += 1
        if base is None:
            base = bytearray(cur)
            prev = cur
            continue
        t = times[i] if i < len(times) else times[-1]
        # Blocks to look at: every pending one, and every one in a row that changed since the last frame.
        touched = set(pending)   # only ever blocks in the first `rows` rows
        if cur != prev:
            for r in range(rows):
                a, b = r * gw, (r + 1) * gw
                if cur[a:b] != prev[a:b]:
                    pr, cr = prev[a:b], cur[a:b]
                    touched.update(a + c for c in range(gw) if pr[c] != cr[c])
        for k in touched:
            v = cur[k]
            d = abs(v - base[k])
            if k in pending:
                s, b0, reached = pending[k]
                if abs(v - b0) <= args.same:
                    if reached > args.diff and t - times[s] <= max_s:
                        returns.setdefault((s, i), []).append(k)
                    del pending[k]
                    base[k] = v
                elif t - times[s] > max_s:
                    del pending[k]
                    base[k] = v
                else:
                    pending[k] = (s, b0, max(reached, abs(v - b0)))
            elif d > args.diff:
                pending[k] = (i, base[k], d)
            else:
                base[k] = v
        prev = cur

    if count != len(times):
        print(f"warning: decoded {count} frames but the stream lists {len(times)}; times may be off", file=sys.stderr)
    tmarks = marks(os.path.join(args.dir, "xcuitest.log"))
    mark_times = [m[0] for m in tmarks]

    findings = []
    for (s, e), blocks in sorted(returns.items()):
        xs = [k % gw for k in blocks]
        ys = [k // gw for k in blocks]
        box = (min(xs) * args.tile, min(ys) * args.tile,
               (max(xs) - min(xs) + 1) * args.tile, (max(ys) - min(ys) + 1) * args.tile)
        findings.append({"start": s, "end": e, "t": times[s], "ms": (times[e] - times[s]) * 1000,
                         "blocks": len(blocks), "box": box})
    # A sweep: a small finding (a few blocks) among two or more others starting within two frames of it — the
    # trail a moving element leaves. A large region that changed and came back together is never a sweep: that
    # is the shape of a real flicker (the planted blink is ~900 blocks returning on one frame).
    for f in findings:
        near = [g for g in findings if abs(g["start"] - f["start"]) <= 2 and g is not f]
        f["sweep"] = f["blocks"] <= 8 and len(near) >= 2

    lines = [f"video: {w}x{h}, {count} frames over {duration:.1f} s, median frame gap {median_gap * 1000:.1f} ms "
             f"(≈ {1 / median_gap:.0f} fps)" if median_gap else f"video: {w}x{h}, {count} frames",
             f"stream frame rate: avg {stream.get('avg_frame_rate')}, r {stream.get('r_frame_rate')}",
             f"settings: tile {args.tile}px, diff {args.diff}, same {args.same}, max {args.max_ms:.0f} ms, "
             f"bottom {args.ignore_bottom}px skipped",
             f"transitions marked: {len(tmarks)}{'' if start is not None else ' (no transient.start: times are video-relative)'}"
             f"{start_note}",
             f"findings: {len(findings)} ({sum(1 for f in findings if not f['sweep'])} not part of a sweep)", ""]
    big = sorted((f for f in findings if not f["sweep"]), key=lambda f: -f["blocks"])[:5]
    if big:
        lines.append("largest not part of a sweep: " + ", ".join(f"#{findings.index(f)} ({f['blocks']} blocks)"
                                                              for f in big))
        lines.append("")
    for n, f in enumerate(findings):
        when = f"video {f['t']:.3f}s"
        name = ""
        if start is not None:
            epoch = start + f["t"]
            idx = bisect.bisect_right(mark_times, epoch) - 1
            if idx >= 0:
                name = f" after '{tmarks[idx][1]}' +{epoch - tmarks[idx][0]:.2f}s"
            else:
                name = " before the first transition"
        x, y, bw, bh = f["box"]
        lines.append(f"#{n} {when}{name}: {f['ms']:.0f} ms, {f['blocks']} block(s) at x={x} y={y} {bw}x{bh}"
                     f" (frames {f['start']}→{f['end']}){' sweep' if f['sweep'] else ''}")
    report = "\n".join(lines) + "\n"
    open(os.path.join(args.dir, "transient-frames.txt"), "w").write(report)
    sys.stdout.write(report)

    out = os.path.join(args.dir, "transient-frames")
    if findings and args.frames > 0:
        os.makedirs(out, exist_ok=True)
        for old in os.listdir(out):
            os.remove(os.path.join(out, old))
        for n, f in [(n, f) for n, f in enumerate(findings) if not f["sweep"]][:args.frames]:
            for label, idx in (("before", f["start"] - 1), ("during", f["start"]), ("after", f["end"])):
                subprocess.run(["ffmpeg", "-v", "error", "-i", mov, "-fps_mode", "passthrough",
                                "-vf", f"select=eq(n\\,{idx})", "-frames:v", "1", "-y",
                                os.path.join(out, f"{n:02d}-{label}.png")], check=False)
        print(f"frames of the first findings: {out}")


if __name__ == "__main__":
    main()
