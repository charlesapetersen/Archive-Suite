#!/usr/bin/env python3
"""W46.date-image, the open cluster arm (B test 2): explicit dates on the page that are not in the text.

    python3 date_image.py pack --out DIR     # on the Mac: the 131 unprinted-year documents' pages, two variants

The 131 are date_traceable.owner_docs()'s owner documents whose year is not in the text (classes A, A', B, C, D; the
21 D documents, with no printed carrier, first). Each document's first two pages are sent to Qwen3.6-27B on the cluster
twice: the images alone, and the images with the ABBYY text. The reply must quote every date string it sees and say
where it is, so a later scorer can check the quote against the page and the year against the owner's.

Images (owner, 2026-10-22): the JPEG originals, never the corpus PDFs ABBYY processed. Each PDF page's JPEG comes from
corpus_pairs.py's pairs.tsv and is confirmed by the truth builder's correlation test (ocr_truth.orient_like_pdf, at
least MIN_CORR), whose best turn makes it upright (the PDFs were turned upright, the JPEGs were not). A page without a confident JPEG is left out and counted; a document left with no page is left out. Images are
written at the panel's 2,400 px long side.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
# The truth builder's own test (ocr_truth.orient_like_pdf: the best of four turns, grey thumbnails correlated): the
# 20 known pairs among the 96's originals measured 0.69-0.98, the 5 non-matching candidates 0.16-0.48 (2026-10-22).
# corpus_pairs.py's difference hash is not used to confirm: its true pairs spread from 8 to 61 bits.
MIN_CORR = 0.65
LONG_SIDE = 2400
PAGES = 2

PROMPT = (
    "These are the first pages of one archival document, in order (page 1, then page 2 if given). Find every date "
    "written on them: full dates, a month and year, or a year alone, wherever it is (letterhead, dateline, body, "
    "signature, stamp, handwriting in a margin). Copy each exactly as it appears, and say where it is. Then give the "
    "date the document itself was written or sent, if the pages show it; a date merely mentioned in the text is not it.\n"
    "Respond with ONLY a JSON object:\n"
    '{"dates": [{"quote": "<exactly as on the page>", "page": 1, "where": "letterhead|dateline|body|signature|stamp|'
    'margin|other", "kind": "printed|typed|handwritten|stamped", "year": 1968, "month": 3}], '
    '"document_date": {"year": 1968, "month": 3, "quote": "<the quote it comes from>"}}\n'
    "Use null for an unknown month or year, and \"document_date\": null if the pages do not show the document's own date.")
TEXT_INTRO = "\n\nThe document's OCR text (from a lower-quality scan; it may miss or misread dates):\n"


def cmd_pack(a):
    from PIL import Image
    import tempfile
    import corpus_pairs as CP
    import ocr_truth as OT
    import date_traceable as T
    import enclosure_split as ES
    pairs = {}
    for line in open(os.path.join(CP.CACHE, "pairs.tsv"), encoding="utf-8").read().splitlines()[1:]:
        pdf, jpeg, method = line.split("\t")[:3]
        if jpeg and method != "none":
            pairs[pdf] = jpeg
    docs = [d for d in T.owner_docs("abbyy") if d["cls"] not in (None, "in text", "decade")]
    docs.sort(key=lambda d: (d["cls"] != "D", d["id"]))          # the 21 with no printed carrier first
    _, found = ES.load()
    pages_of = {"o:" + i: info["segs"][info["k"]]["pages"] for i, info in found.items() if info}
    out = a.out; (out / "images").mkdir(parents=True, exist_ok=True)
    os.makedirs(os.path.join(CP.CACHE, "tmp"), exist_ok=True)
    tmp = Path(tempfile.mkdtemp(dir=os.path.join(CP.CACHE, "tmp")))
    reqs, why = [], collections.Counter()
    for d in docs:
        imgs, digests = [], []
        for p in pages_of[d["id"]][:PAGES]:
            j = pairs.get(p)
            if not j:
                why["no JPEG paired"] += 1; continue
            pdf, jpg = os.path.join(CP.CS.CORPUS, p), os.path.join(CP.JPEGS, j)
            try:
                with Image.open(jpg) as im:
                    deg, corr = OT.orient_like_pdf(im, Path(pdf), tmp)
            except Exception:
                why["comparison failed"] += 1; continue
            if corr < MIN_CORR:
                why["JPEG not the same photo"] += 1; continue
            name = hashlib.sha1(p.encode()).hexdigest() + ".jpg"
            dst = out / "images" / name
            if not dst.exists():
                with Image.open(jpg) as im:
                    im = im.convert("RGB").rotate(deg, expand=True)
                    im.thumbnail((LONG_SIDE, LONG_SIDE), Image.Resampling.LANCZOS)
                    im.save(dst, "JPEG", quality=90)
            imgs.append(f"{a.remote}/images/{name}"); digests.append(hashlib.sha256(dst.read_bytes()).hexdigest())
            why["page from JPEG"] += 1
        if not imgs:
            why["document left out"] += 1; continue
        for variant in ("image", "image+text"):
            prompt = PROMPT + (TEXT_INTRO + d["text"][:6000] if variant == "image+text" else "")
            reqs.append({"id": f"{variant}|{d['id']}", "doc": d["id"], "cls": d["cls"], "variant": variant,
                         "pages": len(imgs), "images": imgs, "image_sha256s": digests, "image": None,
                         "prompt": prompt, "truth": d["truth"]})
    with (out / "requests.jsonl").open("w") as f:
        for r in reqs:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    (out / "pack.json").write_text(json.dumps({"documents": len({r["doc"] for r in reqs}), "requests": len(reqs),
        "counts": dict(why), "classes": dict(collections.Counter(r["cls"] for r in reqs if r["variant"] == "image")),
        "min_corr": MIN_CORR, "long_side": LONG_SIDE, "pages": PAGES,
        "prompt_sha256": hashlib.sha256(PROMPT.encode()).hexdigest()}, indent=1) + "\n")
    print(dict(why), len(reqs), "requests")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pack"); p.add_argument("--out", type=Path, required=True)
    p.add_argument("--remote", default="/scratch/users/cp1/fs-ocr/date-image-20261022")
    a = ap.parse_args()
    {"pack": cmd_pack}[a.cmd](a)


if __name__ == "__main__":
    main()
