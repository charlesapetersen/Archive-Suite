#!/usr/local/bin/python3
"""W46.truth-jpeg-upgrade: fifteen of the truth pages from their JPEG originals instead of the corpus PDF's image.

    truth_jpeg_upgrade.py build     # the 15 originals -> ocr-truth/pages-jpeg/<page>.jpg (+ jpeg-upgrade.json)
    truth_jpeg_upgrade.py swap      # pages/<page>.jpg -> pages-pdf/, pages-jpeg/<page>.jpg -> pages/ (reversible)
    truth_jpeg_upgrade.py unswap    # the reverse

Owner, 2026-10-22: the truth images are the JPEG originals, never the ABBYY-processed corpus PDFs. 33 of the
truth pages were built from the image inside the PDF because ocr_truth.source_of found no original with the PDF's
stem. Eight are paired by corpus_pairs.py and confirmed by ocr_truth.orient_like_pdf (>= MIN_CORR; true pairs
measure 0.69-0.98); seven more the owner named on the 2026-10-23 sheet (segbench-results/truth-jpeg-owner-answers.tsv,
paths relative to ~/Desktop/Google Drive). The owner-named pages skip the correlation test: p083 and p084 score
0.43-0.48 only because the PDF is cropped and deskewed (checked by eye).

Each image is made the way ocr_truth.extract makes an original (EXIF orientation applied, then the turn that best
matches the PDF's page 1; a HEIC goes through sips first). READ ONLY on both trees; everything is written under
ocr_truth.CACHE, outside git. pages.tsv is not changed (the panels freeze its hash); the swap is recorded in
jpeg-upgrade.json, and the PDF images stay in pages-pdf/ so the old runs remain comparable.
"""
from __future__ import annotations

import argparse
import csv
import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import corpus_pairs as CP  # noqa: E402
import ocr_truth as T  # noqa: E402

DRIVE = Path.home() / "Desktop/Google Drive"
ANSWERS = HERE.parents[1] / "segbench-results" / "truth-jpeg-owner-answers.tsv"
PAIRED = ("p023", "p025", "p058", "p061", "p062", "p063", "p077", "p098")
MIN_CORR = 0.65
RECORD = T.CACHE / "jpeg-upgrade.json"
PANEL = Path.home() / "Library/Caches/ArchiveSuiteRehearsal"
PACK = PANEL / "ocr-panel-jpeg"        # OCR_PANEL_CACHE for the free Mac routes on the new images
GW = PANEL / "truth-jpeg-gateway"      # this item's gateway ledger and replies
NEW, OLD, LIVE = T.CACHE / "pages-jpeg", T.CACHE / "pages-pdf", T.CACHE / "pages"
# the PDF image is a ~2x FineReader upscale of these originals, so the original is smaller, not sharper
UPSCALED = ("p008", "p028", "p088", "p091", "p093")


def rows():
    return {r["page"]: r for r in csv.DictReader((T.CACHE / "pages.tsv").open(), delimiter="\t")}


def sources():
    """page -> (original path, how it was found)."""
    rs, out = rows(), {}
    pairs = {}
    for line in Path(CP.CACHE, "pairs.tsv").read_text(encoding="utf-8").splitlines()[1:]:
        p, j, m = line.split("\t")[:3]
        if j and m != "none":
            pairs[p] = j
    for page in PAIRED:
        r = rs[page]
        out[page] = (Path(CP.JPEGS) / pairs[f"{r['folder']}/{r['name']}"], "paired")
    for a in csv.DictReader(ANSWERS.open(), delimiter="\t"):
        if a["use"] == "swap in":
            out[a["page"]] = (DRIVE / a["original"], "owner-named")
    return dict(sorted(out.items()))


def cmd_build(_):
    rs, rec = rows(), {}
    NEW.mkdir(exist_ok=True)
    for page, (src, how) in sources().items():
        r = rs[page]
        pdf = T.CORPUS / r["folder"] / r["name"]
        meta = T.extract("original", src, NEW / f"{page}.jpg", pdf)
        ok = how == "owner-named" or meta["orient_corr"] >= MIN_CORR
        if not ok:
            (NEW / f"{page}.jpg").unlink()
        old = LIVE / f"{page}.jpg" if not (OLD / f"{page}.jpg").exists() else OLD / f"{page}.jpg"
        from PIL import Image
        with Image.open(old) as im:
            old_px = im.size
        rec[page] = {"how": how, "original": str(src.relative_to(DRIVE)), "pdf": f"{r['folder']}/{r['name']}",
                     "kept": ok, "upscaled_pdf": page in UPSCALED, "pdf_image_px": old_px,
                     "sharpness": round(T.sharpness(NEW / f"{page}.jpg"), 1) if ok else None,
                     "pdf_sharpness": round(T.sharpness(old), 1), **meta}
        print(f"{page} {how:11} corr {meta['orient_corr']:.2f} turn {meta['rotated']:3} "
              f"{meta['width']}x{meta['height']} (pdf {old_px[0]}x{old_px[1]}){'' if ok else '  REJECTED'}")
    prev = json.loads(RECORD.read_text()) if RECORD.exists() else {}
    RECORD.write_text(json.dumps({"swapped": prev.get("swapped", False), "pages": rec}, indent=1))


def ladder(page, keep):
    """A ladder page's half and quarter rungs remade from the new image as ocr_truth.cmd_ladder makes them; the
    PDF image's rungs are kept beside its page in `keep`."""
    from PIL import Image
    if page not in json.loads((T.CACHE / "ladder.json").read_text()):
        return
    with Image.open(LIVE / f"{page}.jpg") as im:
        for f, tag in ((2, "half"), (4, "quarter")):
            rung = T.CACHE / "ladder" / f"{page}-{tag}.jpg"
            if not (keep / rung.name).exists():
                shutil.copy2(rung, keep / rung.name)
            im.resize((im.width // f, im.height // f), Image.LANCZOS).save(rung, "JPEG", quality=92)


def cmd_swap(_):
    rec = json.loads(RECORD.read_text())
    OLD.mkdir(exist_ok=True)
    for page, r in rec["pages"].items():
        if not r["kept"]:
            continue
        if not (OLD / f"{page}.jpg").exists():
            shutil.copy2(LIVE / f"{page}.jpg", OLD / f"{page}.jpg")
        shutil.copy2(NEW / f"{page}.jpg", LIVE / f"{page}.jpg")
        (T.CACHE / "draft-img" / f"{page}.jpg").unlink(missing_ok=True)   # rebuilt from pages/ on demand
        ladder(page, OLD)
    rec["swapped"] = True
    RECORD.write_text(json.dumps(rec, indent=1))
    print(f"{sum(r['kept'] for r in rec['pages'].values())} pages now from their JPEG original")


def cmd_unswap(_):
    rec = json.loads(RECORD.read_text())
    for page in rec["pages"]:
        if (OLD / f"{page}.jpg").exists():
            shutil.copy2(OLD / f"{page}.jpg", LIVE / f"{page}.jpg")
            (T.CACHE / "draft-img" / f"{page}.jpg").unlink(missing_ok=True)
            for f in OLD.glob(f"{page}-*.jpg"):
                shutil.copy2(f, T.CACHE / "ladder" / f.name)
    rec["swapped"] = False
    RECORD.write_text(json.dumps(rec, indent=1))


def kept():
    return [p for p, r in json.loads(RECORD.read_text())["pages"].items() if r["kept"]]


def cmd_pack(_):
    """A scratch copy of the local panel (OCR_PANEL_CACHE=PACK) holding only the new images, made the way
    ocr_panel._prepare makes the frozen ones (2,400 px ceiling, JPEG q90). Its manifest is the local panel's with
    the jobs swapped, so ocr_panel.manifest()'s prompt, model and truth checks still hold."""
    import io
    from PIL import Image
    import ocr_panel as P
    if Path(P.CACHE) != PANEL / "ocr-panel-local":
        raise SystemExit("run pack without OCR_PANEL_CACHE set")
    m = json.loads((P.CACHE / "manifest.json").read_text())
    jobs = []
    for page in kept():
        with Image.open(NEW / f"{page}.jpg") as im:
            im = im.convert("RGB")
            im.thumbnail((P.SIDE, P.SIDE), Image.Resampling.LANCZOS)
            out = io.BytesIO(); im.save(out, "JPEG", quality=90)
            b = out.getvalue()
            jobs.append({"page": page, "scale": "original", "id": page + "-original", "sha256": P.digest(b),
                         "width": im.width, "height": im.height})
        dest = PACK / "images" / f"{page}-original.jpg"
        if dest.exists() and dest.read_bytes() != b:
            raise SystemExit("existing frozen image changed: " + str(dest))
        dest.parent.mkdir(parents=True, exist_ok=True); dest.write_bytes(b)
    P.save(PACK / "manifest.json", {**m, "jobs": jobs})
    print(f"{len(jobs)} images in {PACK}")


def cmd_gateway(_):
    """Gemini 3.7 Flash through the Stanford gateway (gateway_gemini's request, prompt and settings: the cloud
    panel's), on the new images. Its own ledger under GW, so gateway_gemini's CAP counts only this item."""
    import gateway_gemini as G
    G.CACHE = GW
    m = json.loads((G.PANEL / "manifest.json").read_text())
    jobs = json.loads((PACK / "manifest.json").read_text())["jobs"]
    G.run("truth-jpeg", [(j["id"], (PACK / "images" / (j["id"] + ".jpg")).read_bytes(), GW / "panel" / (j["id"] + ".json"))
                         for j in jobs], m["prompt"])


ROUTES = ("apple-vision", "qwen3-vl-8b-mlx4", "lightonocr-3-4b-mlx8", "qwen3.5-9b-mlx4", "gemini3.7-flash-gw")
OUT = HERE.parents[1] / "segbench-results" / "truth-jpeg-upgrade"


def reading(route, base, job):
    """(ok, text) of one cached reading; base is the panel cache (old images) or the scratch pack (new)."""
    if route == "apple-vision":
        f = base / "vision" / f"{job}.txt"
        return (f.exists(), f.read_text() if f.exists() else "")
    if route == "gemini3.7-flash-gw":
        f = (PANEL / "gateway-gemini" if base != PACK else GW) / "panel" / f"{job}.json"
        got = T.parse_draft(json.loads(f.read_text()).get("raw") or "") if f.exists() else None
    else:
        f = base / "local" / route / f"{job}.json"
        got = json.loads(f.read_text()).get("parsed") if f.exists() else None
    return (bool(got), got["text"] if got else "")


def cmd_score(_):
    """NES of each route on the PDF image and on the JPEG original, page by page, and what that does to the route's
    96-page mean. Aggregates and page ids only (as ocr-pages.csv): no text."""
    import statistics
    import ocr_panel as P
    import ocr_panel_score as S
    rec = json.loads(RECORD.read_text())["pages"]
    pages = kept()
    scored = [r["page"] for r in P.rows() if r["page"] not in P.AGREEMENT]
    truth = {p: (T.CACHE / "truth" / f"{p}.txt").read_text() for p in scored}
    old_base = PANEL / "ocr-panel-local"
    out = {"pages": {p: {"how": rec[p]["how"], "upscaled_pdf": rec[p]["upscaled_pdf"],
                         "pdf_px": rec[p]["pdf_image_px"], "jpeg_px": [rec[p]["width"], rec[p]["height"]],
                         "pdf_sharpness": rec[p]["pdf_sharpness"], "jpeg_sharpness": rec[p]["sharpness"]}
                     for p in pages}, "routes": {}}

    def mean(xs):
        return round(statistics.fmean(xs), 4) if xs else None
    for route in ROUTES:
        old = {p: S.score(truth[p], reading(route, old_base, p + "-original")[1])["nes"] for p in scored}
        new = {}
        for p in pages:
            ok, text = reading(route, PACK, p + "-original")
            new[p] = S.score(truth[p], text)["nes"] if ok else None
        done = [p for p in pages if new[p] is not None]
        if not done:
            continue
        sharper = [p for p in done if not rec[p]["upscaled_pdf"]]
        smaller = [p for p in done if rec[p]["upscaled_pdf"]]
        mix = {p: new[p] if new.get(p) is not None else old[p] for p in scored}
        out["routes"][route] = {
            "n": len(done), "pdf_mean": mean([old[p] for p in done]), "jpeg_mean": mean([new[p] for p in done]),
            "sharper_n": len(sharper), "sharper_pdf": mean([old[p] for p in sharper]),
            "sharper_jpeg": mean([new[p] for p in sharper]),
            "upscaled_n": len(smaller), "upscaled_pdf": mean([old[p] for p in smaller]),
            "upscaled_jpeg": mean([new[p] for p in smaller]),
            "all96_pdf": mean(list(old.values())), "all96_jpeg": mean(list(mix.values())),
            "per_page": {p: [round(old[p], 4), round(new[p], 4) if new[p] is not None else None] for p in pages}}
    OUT.with_suffix(".json").write_text(json.dumps(out, indent=1) + "\n")
    L = ["| route | pages | PDF image | JPEG original | change | sharper: PDF → JPEG | upscaled: PDF → JPEG "
         "| 96-page mean: PDF → JPEG |", "|---|---|---|---|---|---|---|---|"]
    for route, r in out["routes"].items():
        L.append(f"| {route} | {r['n']} | {r['pdf_mean']:.3f} | {r['jpeg_mean']:.3f} | {r['jpeg_mean'] - r['pdf_mean']:+.3f} "
                 f"| {r['sharper_pdf']:.3f} → {r['sharper_jpeg']:.3f} ({r['sharper_n']}) "
                 f"| {r['upscaled_pdf']:.3f} → {r['upscaled_jpeg']:.3f} ({r['upscaled_n']}) "
                 f"| {r['all96_pdf']:.3f} → {r['all96_jpeg']:.3f} |")
    print("\n".join(L))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("build", "swap", "unswap", "pack", "gateway", "score"):
        sub.add_parser(c)
    a = ap.parse_args(argv)
    globals()["cmd_" + a.cmd](a)


if __name__ == "__main__":
    main()
