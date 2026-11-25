#!/usr/bin/env python3
"""W49.proc-gemma-request-verify: the current and revised Gemma label requests through the Processor.

    python3 ct_gemma_request_verify.py prepare        # scratch label copies at four corrections + the manifest
    heavy-run.py run -- <lab venv>/bin/python ct_gemma_request_verify.py run [--pairs N]   # mlx-vlm on :8080 + the app driver
    heavy-run.py run -- <lab venv>/bin/python ct_gemma_request_verify.py unavailable       # no server: the Vision fallback
    python3 ct_gemma_request_verify.py --report       # segbench-results/ct-gemma-request-verify.md

The app's own label path reads every photo (`LabelGemmaVerifyTestDriver`, which calls
`ContainerLabelCapture.readLabel` with no gateway): it finds Gemma on the mlx-vlm preset port, sends the current or
the revised request, and falls back to Vision + parser. Labels are 16 held-out photos of the ct-gemma-route-fields
panel, chosen by truth alone (type, written collection number), seeded. Each is read at the bench size (1280 px,
the paired validation's input) and as its full-size JPEG original, each turned losslessly (jpegtran) so the run must
supply a 0, 90, 180 or 270 degree correction. Copies live in the bench cache, never the corpus. The cache keeps
correctness flags, timings and image checks only, no label text.
"""
import argparse
import json
import os
from pathlib import Path
import random
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time

import ct_read as R
import ct_gemma_route as G

TAG = "W49.proc-gemma-request-verify"
SCRATCH = Path(os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal")) / TAG
PHOTOS = SCRATCH / "photos"
SENT = SCRATCH / "sent"
MANIFEST = SCRATCH / "manifest.json"
RESULTS = SCRATCH / "results.jsonl"
MEMORY = SCRATCH / "footprint.jsonl"
IMAGES = SCRATCH / "image-checks.json"
UNAVAILABLE = SCRATCH / "unavailable.jsonl"
REPORT = Path(__file__).resolve().parents[2] / "segbench-results/ct-gemma-request-verify.md"
APP = Path(__file__).resolve().parents[2] / "macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
# The turn that made each bench page: final's re-turns, else rev2's (pool-jpeg/sample.jsonl holds the first pass).
SAMPLES = (Path(R.CT.POOL) / "final/sample.jsonl", Path(R.CT.POOL) / "rev2/sample.jsonl")
SCORED = ("repository", "collection_title", "collection_number", "date")
CORRECTIONS = (0, 90, 180, 270)
SIZES = ("bench", "original")
STYLES = ("current", "revised")
PER_STRATUM = 4
SEED = 4949
PORT = 8080   # LocalModelRoute.Server.mlxVLM, the preset the app asks
GEMMA = "gemma-3-12b"


def holdout():
    """The held-out ids in panel order, with each one's scored cells (eligibility and truth presence)."""
    rec = json.load(open(Path(R.OUT) / "gemma-route-fields.json"))
    ids = G.sample(195)[60:]
    if len(rec["holdout"]) != len(ids):
        raise RuntimeError("The ct-gemma-route-fields held-out panel is incomplete")
    return {mid: h for mid, h in zip(ids, rec["holdout"])}


def choose(cells):
    """Four labels for each type and written/blank collection number, by truth only."""
    strata = {}
    for mid, h in cells.items():
        number = h["cells"].get("collection_number")
        if number is None:
            continue
        strata.setdefault((h["folder"], number["truth_filled"]), []).append(mid)
    rng = random.Random(SEED)
    picked = []
    for key in sorted(strata):
        pool = sorted(strata[key])
        rng.shuffle(pool)
        picked += pool[:PER_STRATUM]
    return picked


def jpegtran(*args):
    subprocess.run(["jpegtran", *args], check=True)


def dims(path):
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
                         capture_output=True, text=True, check=True).stdout.split()
    return int(out[out.index("pixelWidth:") + 1]), int(out[out.index("pixelHeight:") + 1])


def orientation(path):
    out = subprocess.run(["exiftool", "-s3", "-Orientation#", str(path)], capture_output=True, text=True).stdout.strip()
    return int(out) if out else 1


def prepare(_args):
    if not shutil.which("jpegtran") or not shutil.which("exiftool"):
        raise RuntimeError("jpegtran and exiftool are needed (brew install jpeg exiftool)")
    cells = holdout()
    picked = choose(cells)
    rows = {r["id"]: r for r in R.truth()}
    for mid in picked:
        # The panel is stored by position: check it still lines up with the truth on the stratifying field.
        if bool(rows[mid]["fields"].get("collection_number")) != cells[mid]["cells"]["collection_number"]["truth_filled"]:
            raise RuntimeError(f"{mid}: the stored panel no longer matches the truth")
    sample = {}
    for path in reversed(SAMPLES):
        sample.update({json.loads(line)["id"]: json.loads(line) for line in open(path, encoding="utf-8")})
    PHOTOS.mkdir(parents=True, exist_ok=True)
    SENT.mkdir(parents=True, exist_ok=True)
    entries, labels = [], []
    for index, mid in enumerate(picked):
        sources = {"bench": (Path(R.page_of(mid)), 0), "original": (Path(sample[mid]["jpeg"]), sample[mid]["turn"])}
        for size, (source, turn) in sources.items():
            if orientation(source) != 1:
                raise RuntimeError(f"{mid}: EXIF orientation is not handled by this harness")
            # PIL's turn is counter-clockwise; the app's correction is clockwise.
            natural = (360 - turn) % 360
            w, h = dims(source)
            base = PHOTOS / f"{mid}-{size}-crop.jpg"
            # Crop to whole 16 px blocks from the top-left, so every turn below is lossless.
            jpegtran("-copy", "none", "-crop", f"{w // 16 * 16}x{h // 16 * 16}+0+0", "-outfile", str(base), str(source))
            for correction in CORRECTIONS:
                turn_by = (natural - correction) % 360
                photo = PHOTOS / f"{mid}-{size}-c{correction}.jpg"
                if turn_by:
                    jpegtran("-copy", "none", "-perfect", "-rotate", str(turn_by), "-outfile", str(photo), str(base))
                else:
                    shutil.copyfile(base, photo)
                order = list(STYLES)
                random.Random(f"{SEED}-{mid}-{size}-{correction}").shuffle(order)
                for style in order:
                    key = f"{mid}/{size}/c{correction}/{style}"
                    entries.append(dict(key=key, photo=str(photo), rotation=correction,
                                        type="Folder" if cells[mid]["folder"] else "Box", style=style,
                                        imageOut=str(SENT / (key.replace("/", "-") + ".jpg"))))
            base.unlink()
        labels.append(dict(id=mid, folder=cells[mid]["folder"],
                           truth_filled={f: c["truth_filled"] for f, c in cells[mid]["cells"].items()}))
    # Pairs of one label, size and correction are adjacent; labels follow the strata in turn.
    MANIFEST.write_text(json.dumps(entries, indent=1), encoding="utf-8")
    (SCRATCH / "labels.json").write_text(json.dumps(labels, indent=1), encoding="utf-8")
    print(f"{len(picked)} labels, {len(entries)} reads ({len(entries) // 2} pairs); {MANIFEST}")


def done_keys(path):
    if not path.exists():
        return set()
    return {json.loads(line)["key"] for line in path.read_text().splitlines() if line.strip()}


def run_app(manifest, out, timeout):
    """The app driver over `manifest`, until it writes `<out>.done`. Returns its exit state."""
    if not APP.exists():
        raise RuntimeError("Build the Processor Debug app in this worktree first")
    done = Path(str(out) + ".done")
    done.unlink(missing_ok=True)
    work = Path(tempfile.mkdtemp(prefix="gemma-verify-app-"))
    env = dict(os.environ, ARCHIVEPROC_HEADLESS="1", ARCHIVEPROC_TEST_BACKUP_ROOT=str(work / "backup"),
               LABELGEMMA_VERIFY=str(manifest), LABELGEMMA_VERIFY_OUT=str(out))
    with open(work / "app.log", "w") as log:
        child = subprocess.Popen([str(APP)], env=env, stdout=log, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + timeout
    try:
        while not done.exists():
            if child.poll() is not None:
                raise RuntimeError(f"The app exited ({child.returncode}); log in {work}")
            if time.monotonic() > deadline:
                raise RuntimeError(f"The app driver timed out; log in {work}")
            time.sleep(1)
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(30)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
    shutil.rmtree(work, ignore_errors=True)


def subset(entries, keys_done, pairs):
    todo = [e for e in entries if e["key"] not in keys_done]
    return todo if pairs is None else todo[:2 * pairs]


def run(args):
    import ct_gemma_route_fields as F
    entries = json.loads(MANIFEST.read_text())
    todo = subset(entries, done_keys(RESULTS), args.pairs)
    if not todo:
        print("All reads done")
        return check_images()
    with F.server(PORT, with_pid=True) as (base, pid):
        footprint = F.footprint_reader(pid)
        # Warm the model outside the measured reads with both orders, as the paired validation did.
        warm = next(Path(e["photo"]).read_bytes() for e in entries if e["rotation"] == 0 and "/bench/" in e["key"])
        for text_first in (False, True):
            F.read_server(base, warm, text_first)
        stop = threading.Event()

        def sample():
            with open(MEMORY, "a") as out:
                while not stop.wait(0.1):
                    out.write(json.dumps([time.time(), footprint()]) + "\n")
        thread = threading.Thread(target=sample, daemon=True)
        thread.start()
        try:
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
                json.dump(todo, handle)
            run_app(Path(handle.name), RESULTS, timeout=240 * len(todo) + 120)
        finally:
            stop.set()
            thread.join()
            os.unlink(handle.name)
    print(f"{len(done_keys(RESULTS))}/{len(entries)} reads done", flush=True)
    check_images()


def unavailable(_args):
    """No server on any preset: one label per type and size, both styles, must fall back to Vision."""
    entries = json.loads(MANIFEST.read_text())
    first = {}
    for e in entries:
        mid, size, correction, _ = e["key"].split("/")
        if correction == "c90":
            first.setdefault((e["type"], size), mid)
    todo = [dict(e, imageOut=None) for e in entries
            if e["key"].split("/")[2] == "c90" and first.get((e["type"], e["key"].split("/")[1])) == e["key"].split("/")[0]]
    import socket
    for port in (1234, 11434, PORT):
        with socket.socket() as probe:
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                raise RuntimeError(f"Something listens on {port}; the unavailable check needs no server")
    UNAVAILABLE.unlink(missing_ok=True)
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(todo, handle)
    try:
        run_app(Path(handle.name), UNAVAILABLE, timeout=60 * len(todo) + 60)
    finally:
        os.unlink(handle.name)
    print(f"{len(done_keys(UNAVAILABLE))} reads with no server")


def check_images():
    """Each sent image against the upright bench page: upright (best of four turns) and, for bench-size photos,
    its fidelity to the lossless upright crop."""
    import numpy as np
    from PIL import Image
    checks = json.loads(IMAGES.read_text()) if IMAGES.exists() else {}

    def grey(img, size):
        return np.asarray(img.convert("L").resize(size, Image.Resampling.BILINEAR), dtype=float).ravel()

    def corr(a, b):
        a, b = a - a.mean(), b - b.mean()
        return float((a @ b) / (np.sqrt((a @ a) * (b @ b)) or 1))

    upright_crops = {}
    for e in json.loads(MANIFEST.read_text()):
        if e["key"] in checks or not Path(e["imageOut"]).exists():
            continue
        mid, size, correction, style = e["key"].split("/")
        ref = Image.open(R.page_of(mid))
        sent = Image.open(e["imageOut"])
        shape = (64, round(64 * ref.height / ref.width))
        r = grey(ref, shape)
        scores = {turn: corr(grey(sent.rotate(-turn, expand=True), shape), r) for turn in CORRECTIONS}
        check = dict(upright=max(scores, key=scores.get) == 0, corr=round(scores[0], 3),
                     long_edge=max(sent.size))
        if size == "bench":
            crop = PHOTOS / f"{mid}-bench-c0.jpg"
            if mid not in upright_crops:
                upright_crops[mid] = np.asarray(Image.open(crop).convert("RGB"), dtype=float)
            a = np.asarray(sent.convert("RGB"), dtype=float)
            b = upright_crops[mid]
            if a.shape == b.shape:
                mse = float(((a - b) ** 2).mean())
                check["psnr"] = None if mse == 0 else round(10 * np.log10(255 ** 2 / mse), 1)
            else:
                check["psnr"] = "shape"
        checks[e["key"]] = check
    IMAGES.write_text(json.dumps(checks, indent=0), encoding="utf-8")
    bad = [k for k, c in checks.items() if not c["upright"]]
    print(f"{len(checks)} sent images checked, {len(bad)} not upright {bad[:5]}")


# --- report ------------------------------------------------------------------------------------------------------

def load():
    rows = {r["id"]: r for r in R.truth()}
    labels = {l["id"]: l for l in json.loads((SCRATCH / "labels.json").read_text())}
    reads = {}
    for line in RESULTS.read_text().splitlines():
        if line.strip():
            d = json.loads(line)
            reads[d["key"]] = d
    return rows, labels, reads


def score(rows, labels, read, mid, field, gemma_only):
    value = (read["fields"].get(field) or {})
    if gemma_only and value.get("reader") != GEMMA:
        value = {}
    want = rows[mid]["fields"].get(field)
    return dict(right=R.same(field, value.get("value"), want), filled=bool(value.get("value")),
                truth_filled=labels[mid]["truth_filled"][field])


def pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, round(q * (len(values) - 1)))]


def report(_args):
    rows, labels, reads = load()
    entries = json.loads(MANIFEST.read_text())
    pairs = {}
    for e in entries:
        mid, size, correction, style = e["key"].split("/")
        if e["key"] in reads:
            pairs.setdefault((mid, size, correction), {})[style] = reads[e["key"]]
    complete = {k: v for k, v in pairs.items() if len(v) == 2}
    images = json.loads(IMAGES.read_text()) if IMAGES.exists() else {}
    unavailable = [json.loads(l) for l in UNAVAILABLE.read_text().splitlines() if l.strip()] \
        if UNAVAILABLE.exists() else []
    memory = [json.loads(l) for l in MEMORY.read_text().splitlines() if l.strip()] if MEMORY.exists() else []
    n_labels = len(labels)
    folders = sum(l["folder"] for l in labels.values())

    def tally(keys, gemma_only):
        out = {}
        for field in SCORED:
            for style in STYLES:
                right = filled_false = eligible = present = present_right = blank = 0
                for k in keys:
                    mid = k[0]
                    if field not in labels[mid]["truth_filled"]:
                        continue
                    s = score(rows, labels, complete[k][style], mid, field, gemma_only)
                    eligible += 1
                    right += s["right"]
                    if s["truth_filled"]:
                        present += 1
                        present_right += s["right"]
                    else:
                        blank += 1
                        filled_false += s["filled"]
                out[(field, style)] = dict(right=right, eligible=eligible, present=present,
                                           present_right=present_right, blank=blank, false=filled_false)
        return out

    def field_table(keys, gemma_only):
        t = tally(keys, gemma_only)
        lines = ["| Field | Eligible | Current correct | Revised correct | Current where written | "
                 "Revised where written | Current false fills | Revised false fills |",
                 "| --- | --- | --- | --- | --- | --- | --- | --- |"]
        for field in SCORED:
            c, r = t[(field, "current")], t[(field, "revised")]
            lines.append(f"| {field.replace('_', ' ').capitalize()} | {c['eligible']} | {c['right']}/{c['eligible']} | "
                         f"{r['right']}/{r['eligible']} | {c['present_right']}/{c['present']} | "
                         f"{r['present_right']}/{r['present']} | {c['false']}/{c['blank']} | {r['false']}/{r['blank']} |")
        return lines

    def consistency(style, size):
        """Labels whose four corrections gave the same correctness on every scored field."""
        same = total = 0
        for mid in labels:
            per = [complete.get((mid, size, f"c{c}")) for c in CORRECTIONS]
            if any(p is None for p in per):
                continue
            total += 1
            flags = [tuple(score(rows, labels, p[style], mid, f, False)["right"] for f in SCORED
                           if f in labels[mid]["truth_filled"]) for p in per]
            same += len(set(flags)) == 1
        return same, total

    def window_peak(read):
        values = [b for t, b in memory if read["start"] <= t <= read["end"]]
        return max(values) if values else None

    def resource_rows():
        out = []
        for size in SIZES:
            for style in STYLES:
                rs = [v[style] for k, v in complete.items() if k[1] == size]
                if not rs:
                    continue
                secs = [r["seconds"] for r in rs]
                kb = [r["imageBytes"] / 1e6 for r in rs]
                peaks = [p / 2 ** 30 for p in (window_peak(r) for r in rs) if p]
                through = sum(r["passThrough"] for r in rs)
                model = sum(r["modelAnswered"] for r in rs)
                out.append(f"| {size} | {style} | {len(rs)} | {model}/{len(rs)} | {through} | "
                           f"{statistics.median(kb):.2f} / {pct(kb, .95):.2f} | "
                           f"{statistics.median(secs):.2f} / {pct(secs, .95):.2f} | "
                           + (f"{statistics.median(peaks):.2f} / {max(peaks):.2f} |" if peaks else "n/a |"))
        return out

    keys_by_size = {size: [k for k in complete if k[1] == size] for size in SIZES}
    intact = sum(r["sourceIntact"] for v in complete.values() for r in v.values())
    reads_n = 2 * len(complete)
    upright_bad = [k for k, c in images.items() if not c["upright"]]
    psnr_rotated = [c["psnr"] for k, c in images.items() if "/bench/" in k and "/c0/" not in k
                    and isinstance(c.get("psnr"), (int, float))]
    psnr_current0 = [c["psnr"] for k, c in images.items() if "/bench/c0/current" in k
                     and isinstance(c.get("psnr"), (int, float))]
    through0 = sum(1 for k, v in complete.items() if k[1] == "bench" and k[2] == "c0" and v["revised"]["passThrough"])
    bench0 = sum(1 for k in complete if k[1] == "bench" and k[2] == "c0")
    other_through = sum(1 for k, v in complete.items() if not (k[1] == "bench" and k[2] == "c0")
                        and v["revised"]["passThrough"])
    fallback_numbers = {}
    for style in STYLES:
        n = sum(1 for k, v in complete.items() if (v[style]["fields"].get("collection_number") or {}).get("reader")
                not in (None, "", GEMMA))
        fallback_numbers[style] = n

    L = ["# Gemma label request through the Processor: current against revised (W49.proc-gemma-request-verify)", "",
         "Generated by `scripts/segbench/ct_gemma_request_verify.py --report` from the run's correctness flags, "
         "timings and image checks.", "",
         "## What was run", "",
         f"The Processor's own label path (`ContainerLabelCapture.readLabel`, the call Process Files and Live Capture "
         f"share) read {n_labels} held-out label photos ({n_labels - folders} box, {folders} folder) from the "
         f"ct-gemma-route-fields panel, each at the bench size (1280 px, the paired validation's input) and as its "
         f"full-size JPEG original, and each stored turned so that the run had to supply a 0, 90, 180 or 270 degree "
         f"correction. That is {len(complete)} complete pairs of {len(pairs)} started. Each pair read one copy with "
         f"the current request (photo first, re-encoded) and the revised one (prompt first; the file itself when it "
         f"is an upright JPEG within the 1,600 px cap, else the same re-encoding), in a seeded order. Gemma 3 12B "
         f"(4-bit MLX, pinned snapshot) ran alone on mlx-vlm 0.7.4's server on the app's preset port, found by the "
         f"app's own server lookup.", "",
         "## Accuracy by field, the proposals the user gets", "",
         "Bench-size photos, all four corrections:", ""]
    L += field_table(keys_by_size["bench"], False) + ["", "Full-size originals, all four corrections:", ""]
    L += field_table(keys_by_size["original"], False)
    L += ["", "Bench-size photos needing no correction (the paired validation's condition):", ""]
    L += field_table([k for k in keys_by_size["bench"] if k[2] == "c0"], False)
    L += ["", "Gemma's own values only (a field Vision supplied counts as blank), all photos:", ""]
    L += field_table(list(complete), True)
    L += ["", "## Consistency across corrections", "",
          "Labels whose four corrections gave the same correctness on every scored field:", "",
          "| Size | Current | Revised |", "| --- | --- | --- |"]
    for size in SIZES:
        c, r = consistency("current", size), consistency("revised", size)
        L.append(f"| {size} | {c[0]}/{c[1]} | {r[0]}/{r[1]} |")
    L += ["", "## Photo handling", "",
          f"- The revised request sent the file itself for {through0}/{bench0} bench-size photos needing no correction "
          f"and for {other_through} of the others (it must turn or scale those).",
          f"- Every sent image was checked against the upright bench page at four turns: "
          f"{len(images) - len(upright_bad)}/{len(images)} were upright." + (f" Not upright: {upright_bad}." if upright_bad else ""),
          (f"- Turned bench-size photos, re-encoded upright: PSNR against the lossless upright crop median "
           f"{statistics.median(psnr_rotated):.1f} dB (min {min(psnr_rotated):.1f}); the current request's re-encoding "
           f"of the unturned photo, median {statistics.median(psnr_current0):.1f} dB. Both use the app's exact 90 degree "
           f"turn and JPEG quality 0.9 at the photo's own size." if psnr_rotated and psnr_current0 else
           "- Fidelity figures are missing."),
          f"- Source files unchanged after their reads (SHA-256 before and after): {intact}/{reads_n}.",
          f"- Collection numbers proposed from Vision + parser where Gemma gave none: current {fallback_numbers['current']}, "
          f"revised {fallback_numbers['revised']} reads.", "",
          "## Time and memory", "",
          "Seconds are the whole label read in the app (Vision OCR, preparing the photo, the request and parsing). "
          "Server memory is mlx-vlm's physical footprint, sampled every 100 ms across the run, highest during each read.", "",
          "| Size | Request | Reads | Gemma answered | File sent as is | Image MB (median / p95) | Read s (median / p95) | "
          "Server GiB (median / highest) |", "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    L += resource_rows()
    L += ["", "## No server", ""]
    if unavailable:
        vision = sum(1 for u in unavailable if u["fallback"] == "vision" and not u["modelAnswered"])
        props = sum(1 for u in unavailable if u["fields"])
        intact_u = sum(u["sourceIntact"] for u in unavailable)
        L.append(f"With nothing listening on the three preset ports, {len(unavailable)} reads ({', '.join(sorted({u['style'] for u in unavailable}))}) "
                 f"each fell back to Vision + parser: {vision}/{len(unavailable)} recorded the Vision fallback with no model "
                 f"answer, {props}/{len(unavailable)} still proposed fields, and {intact_u}/{len(unavailable)} sources "
                 f"were unchanged.")
    else:
        L.append("Not run.")
    L += ["", "## Measurement card", "",
          "- **Truth.** The ct-read truth (three-reader drafts, owner sheet rulings) as the earlier route reports "
          "scored it; the same eligibility per cell. Neither request drafted it.",
          f"- **Selection.** {PER_STRATUM} labels for each type and written or blank collection number, seeded "
          f"({SEED}) from the 135 held-out photos, by truth alone. These photos also supplied the paired validation.",
          "- **Comparison.** Same app build, server, model snapshot, prompt, temperature 0 and 640-token cap; each pair "
          "read the same scratch file. Only the request differs. Full-size originals and turned copies are lossless "
          "crops and turns of the same JPEGs (jpegtran, cropped to whole 16 px blocks).",
          "- **Noise.** Small n: one read per pair, no intervals. The paired validation (135 photos) is the accuracy "
          "estimate; this run checks that the app reproduces its direction and that turned and full-size photos keep "
          "the revised request's behaviour. A difference of a few cells is inside rerun variation.",
          "- **Scope.** mlx-vlm 0.7.4 only; Ollama and LM Studio were not tested. Serial label reads with no OCR model "
          "loaded alongside. Model switching is W49.proc-gemma-swap-time. The app-managed reader was not exercised "
          "(it keeps the re-encoded photo). The production default stays the current request."]
    REPORT.write_text("\n".join(L) + "\n", encoding="utf-8")
    print(REPORT)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("step", nargs="?", choices=("prepare", "run", "unavailable", "images"))
    p.add_argument("--pairs", type=int)
    p.add_argument("--report", action="store_true")
    a = p.parse_args()
    if a.report:
        return report(a)
    {"prepare": prepare, "run": run, "unavailable": unavailable, "images": lambda _a: check_images()}[a.step](a)


if __name__ == "__main__":
    main()
