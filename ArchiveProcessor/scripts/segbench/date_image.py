#!/usr/bin/env python3
"""W46.date-image, the open cluster arm (B test 2): explicit dates on the page that are not in the text.

    <lab venv>/bin/python date_image.py pack --out DIR    # the 131 unprinted-year documents' pages, two variants
    run-guarded.sh --label date-image --need-gb 8 -- <lab venv>/bin/python date_image.py collect-mac [--side 1400]
    python3 date_image.py vision             # Apple Vision text of the targets' pages, for the scorer's check
    python3 date_image.py score              # segbench-results/date-image.md and .json
    <lab venv>/bin/python date_image.py prints   # Vision feature prints of the targets' folder neighbours (JPEGs)
    python3 date_image.py retrieve           # look-alike retrieval, appended to the same results (run after score)

<lab venv> is ~/.local/share/visionocr-ocrlab/venv (numpy for the pairing test, mlx_vlm for the Mac arm). The pack
for the Mac arm is rebuilt into PACK with the same command and checked against the cluster's image digests.

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
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
# The truth builder's own test (ocr_truth.orient_like_pdf: the best of four turns, grey thumbnails correlated): the
# 20 known pairs among the 96's originals measured 0.69-0.98, the 5 non-matching candidates 0.16-0.48 (2026-10-22).
# corpus_pairs.py's difference hash is not used to confirm: its true pairs spread from 8 to 61 bits.
MIN_CORR = 0.65
PACK = Path(os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/date-image"))      # a local copy of the pack
CLUSTER = Path(os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/sherlock-results/date-image-20261022"))
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


def load_requests(pack):
    return [json.loads(l) for l in open(pack / "requests.jsonl", encoding="utf-8")]


def check_pack(pack, cluster):
    """The local pack must be the one the cluster read: same requests, same image bytes."""
    mine = {r["id"]: r["image_sha256s"] for r in load_requests(pack)}
    theirs = {r["id"]: r["image_sha256s"] for r in load_requests(cluster)}
    same = sum(1 for k, v in theirs.items() if mine.get(k) == v)
    return same, len(theirs)


def cmd_collect_mac(a):
    """The Mac arm: the cluster's requests through a small MLX model, images shrunk to --side."""
    import mlx.core as mx
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    from PIL import Image
    import date_draft as DD
    os.environ.setdefault("HF_HOME", os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/mlx-hf"))
    small = a.pack / f"images-{a.side}"; small.mkdir(exist_ok=True)
    out = a.pack / "mac" / f"{a.model}-{a.side}"; out.mkdir(parents=True, exist_ok=True)
    reqs = [r for r in load_requests(a.pack) if a.variant in (None, r["variant"])]
    reqs.sort(key=lambda r: (r["variant"] != "image", r["cls"] != "D", r["doc"]))   # images alone first, D first
    todo = [r for r in reqs if not (out / (r["id"] + ".json")).exists()][: a.limit or None]
    print(f"{a.model} at {a.side} px: {len(todo)} requests to send", flush=True)
    if not todo:
        return
    mx.set_cache_limit(256 * 2**20)
    model, processor = load(DD.MODELS[a.model][0])
    for k, r in enumerate(todo, 1):
        paths = []
        for p in r["images"]:
            dst = small / os.path.basename(p)
            if not dst.exists():
                with Image.open(a.pack / "images" / os.path.basename(p)) as im:
                    im.thumbnail((a.side, a.side), Image.Resampling.LANCZOS)
                    im.save(dst, "JPEG", quality=90)
            paths.append(str(dst))
        try:
            chat = apply_chat_template(processor, model.config, r["prompt"], num_images=len(paths), enable_thinking=False)
        except TypeError:
            chat = apply_chat_template(processor, model.config, r["prompt"], num_images=len(paths))
        start, text, last = time.time(), [], None
        for g in stream_generate(model, processor, chat, image=paths, max_tokens=MAX_TOKENS, temperature=0.0):
            text.append(g.text)
            last = g
        raw = re.sub(r"<think>.*?</think>", "", "".join(text), flags=re.S)
        gen = getattr(last, "generation_tokens", 0)
        rec = {"id": r["id"], "text": raw, "finish": "length" if gen >= MAX_TOKENS else "stop",
               "seconds": round(time.time() - start, 2), "tokens": [getattr(last, "prompt_tokens", 0), gen],
               "model": a.model, "side": a.side}
        (out / (r["id"] + ".json")).write_text(json.dumps(rec, ensure_ascii=False))
        print(f"[{k}/{len(todo)}] {r['id']} {rec['seconds']}s {rec['tokens']}", flush=True)


# ---------------------------------------------------------------------------------------------------------- scoring

def reply(raw):
    """The reply's JSON object, or None."""
    m = re.search(r"\{.*\}", re.sub(r"```(?:json)?", "", raw or ""), re.S)
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
    except ValueError:
        return None
    return d if isinstance(d, dict) else None


def _year(v):
    try:
        y = int(str(v)[:4])
    except (TypeError, ValueError):
        return None
    return y if 1500 <= y <= 2030 else None


def year_in_quote(year, quote):
    """The year is written in the quote, in full or as '58 / 58 (date_draft.year_in_reading's rule)."""
    y, q = str(year), str(quote or "")
    return y in q or bool(re.search(r"(?<![0-9])'?" + y[2:] + r"(?![0-9])", q))


def quoted_year(quote):
    """The year written in a quote when the reply left the year field out (the 8B often does): a four-digit year,
    or the two-digit year closing a numeric date (8/4/68), read as 19xx."""
    q = str(quote or "")
    m = re.search(r"(?<![0-9])(1[89][0-9][0-9]|20[0-3][0-9])(?![0-9])", q)
    if m:
        return int(m.group(1))
    m = re.search(r"(?<![0-9])[0-9]{1,2}[/.-][0-9]{1,2}[/.-]([0-9]{2})(?![0-9])", q)
    return 1900 + int(m.group(1)) if m else None


def _norm(s):
    return re.sub(r"[^0-9a-z]", "", (s or "").lower())


def read(rec):
    """One reply as {ok, doc_year, dates: [{quote, page, where, kind, year, written}]}; written = the year is in the
    quote (a year the model supplied from elsewhere, as on the owner's d06, is not written)."""
    d = reply(rec.get("text")) if rec else None
    if d is None:
        return {"ok": False, "doc_year": None, "dates": []}
    dates = []
    for x in d.get("dates") or []:
        if not isinstance(x, dict):
            continue
        y = _year(x.get("year")) or quoted_year(x.get("quote"))
        dates.append({"quote": str(x.get("quote") or ""), "page": x.get("page"), "where": str(x.get("where") or "other"),
                      "kind": str(x.get("kind") or "?"), "year": y, "written": y is not None and year_in_quote(y, x.get("quote"))})
    dd = d.get("document_date") if isinstance(d.get("document_date"), dict) else {}
    return {"ok": True, "doc_year": _year(dd.get("year")), "doc_quote": str(dd.get("quote") or ""), "dates": dates}


ARMS = (("qwen3.6-27b", "Qwen3.6-27B (Sherlock, vLLM, 2,400 px)"),)


def outputs(cluster, mac_dirs):
    """{(arm, request id): record}; arm labels in arm order."""
    got, arms = {}, []
    for label, name in ARMS:
        arms.append((label, name))
        for f in (cluster / "out").glob("*.json"):
            rec = json.loads(f.read_text())
            got[(label, rec["id"])] = rec
    for m in mac_dirs:
        label = "mac:" + m.name
        recs = [json.loads(f.read_text()) for f in m.glob("*.json")]
        if not recs:
            continue
        import date_draft as DD
        key, side = m.name.rsplit("-", 1)
        arms.append((label, f"{DD.MODELS.get(key, (None, key))[1]} (this Mac, {int(side):,} px)"))
        for rec in recs:
            got[(label, rec["id"])] = rec
    for g in sorted((PACK / "gateway").glob("gemini*")) if mac_dirs else []:     # date_image_gateway.py run
        recs = [json.loads(f.read_text()) for f in g.glob("*.json")]
        if recs:
            arms.append(("gw:" + g.name, f"Gemini 3.7 Flash (gateway, {int(g.name.rsplit('-', 1)[1]):,} px)"))
            got.update({("gw:" + g.name, rec["id"]): rec for rec in recs})
    return got, arms


def page_sources():
    """{document id: (ABBYY text of the whole document, Apple Vision text of its first pages or None)}."""
    import date_traceable as T
    import enclosure_split as ES
    _, found = ES.load()
    out = {}
    for d in T.owner_docs("abbyy"):
        info = found.get(d["id"][2:])
        pages = info["segs"][info["k"]]["pages"][:PAGES] if info else []
        out[d["id"]] = (d["text"], T.vision_text(pages) if pages else None)
    return out


def owner_page_truth():
    """{document id: page_date} for the owner's dating cases answered from the document's own page."""
    import date_tagging as DT
    p = os.path.join(DT.CACHE, "cases", "truth-sets.json")
    if not os.path.exists(p):
        return {}
    return {"o:" + r["doc"]: r for r in json.load(open(p, encoding="utf-8"))["records"] if r.get("page_date")}


def score_one(req, rec, texts):
    """The measures of one reply against the owner's year."""
    truth = req["truth"].get("year")
    r = read(rec)
    hits = [x for x in r["dates"] if x["year"] == truth and x["written"]]
    abbyy, vision = texts.get(req["doc"], ("", None))
    na, nv = _norm(abbyy), _norm(vision) if vision is not None else None
    first = hits[0] if hits else None
    return {"ok": r["ok"], "doc_year": r["doc_year"], "exact": r["doc_year"] == truth,
            "within1": r["doc_year"] is not None and truth is not None and abs(r["doc_year"] - truth) <= 1,
            "answered": r["doc_year"] is not None, "n_dates": len(r["dates"]),
            "on_page": bool(hits), "hit": first,
            "hit_in_abbyy": bool(first) and len(_norm(first["quote"])) >= 4 and _norm(first["quote"]) in na,
            "year_in_abbyy": truth is not None and str(truth) in abbyy,
            "vision": None if nv is None else (str(truth) in vision or (bool(first) and len(_norm(first["quote"])) >= 4
                                                                         and _norm(first["quote"]) in nv)),
            "wrong_written": sorted({x["year"] for x in r["dates"] if x["written"] and x["year"] != truth}),
            "written": sorted({x["year"] for x in r["dates"] if x["written"]})}


CLASSES = ("D", "C", "B", "A", "A'")


def pct(n, d):
    return f"{n}/{d} ({100 * n / d:.0f}%)" if d else "-"


def cmd_score(a):
    reqs = load_requests(a.cluster)
    mac_dirs = sorted(p for p in (a.pack / "mac").glob("*") if p.is_dir()) if a.pack else []
    got, arms = outputs(a.cluster, mac_dirs)
    texts = page_sources()
    owner = owner_page_truth()
    rows = []
    for label, _ in arms:
        for q in reqs:
            rec = got.get((label, q["id"]))
            if rec is None:
                continue
            s = score_one(q, rec, texts)
            s.update(arm=label, id=q["id"], doc=q["doc"], cls=q["cls"], variant=q["variant"], seconds=rec.get("seconds"))
            rows.append(s)
    docs = {q["doc"]: q for q in reqs}
    nvis = sum(1 for d in docs if texts.get(d, ("", None))[1] is not None)
    L = ["# Dating: dates on the page that are not in the text (W46.date-image)", "",
         "Written by `scripts/segbench/date_image.py score`. B test 2 (`execution-plans/processing-review/B-dating.md`): "
         f"the owner's unprinted-year documents (the year not in the ABBYY text; classes A to D), {len(docs)} of the 131 "
         "with a confirmed JPEG original of at least one of their first two pages (the other 9 have none; the corpus PDFs "
         "are never sent, owner 2026-10-22). Each model was asked to quote every date on the pages, say where it is and "
         "what kind, and give the document's own date; once with the images alone and once with the ABBYY text as well. "
         "The owner's year is never in the prompt. The open arms cost $0; Gemini 3.7 Flash (W46.date-image-paid, "
         "`date_image_gateway.py`) read the images alone through the Stanford gateway, about $0.34 for the 122 at "
         "3.8's list price taken as a ceiling.", "",
         "Measures, per document: **doc year** the document date the model gave equals the owner's year (exact; "
         "within one); **on the page** some quoted date has the owner's year written in it (a year the model "
         "supplied, not written in the quote, does not count); **not in ABBYY** of those, the quote is not in the "
         "ABBYY text either (spacing and punctuation ignored); **Vision agrees** of those, Apple Vision's reading of "
         f"the same pages has the year or the quote (Vision text is cached for {nvis} of the {len(docs)}), a check that "
         "the date is really there rather than invented.", ""]
    L += ["## By arm and variant", "",
          "| arm | variant | parsed | doc year exact | within one | on the page | not in ABBYY | Vision agrees | median s |",
          "|---|---|---|---|---|---|---|---|---|"]
    summary = {}
    for label, name in arms:
        for v in ("image", "image+text"):
            R = [r for r in rows if r["arm"] == label and r["variant"] == v]
            if not R:
                continue
            hits = [r for r in R if r["on_page"]]
            vis = [r for r in hits if r["vision"] is not None]
            secs = sorted(r["seconds"] for r in R if r["seconds"] is not None)
            summary[f"{label}|{v}"] = {"n": len(R), "exact": sum(r["exact"] for r in R),
                                       "within1": sum(r["within1"] for r in R), "on_page": len(hits),
                                       "not_in_abbyy": sum(not r["hit_in_abbyy"] for r in hits),
                                       "vision_checked": len(vis), "vision_agrees": sum(r["vision"] for r in vis)}
            L.append(f"| {name} | {v} | {pct(sum(r['ok'] for r in R), len(R))} | {pct(sum(r['exact'] for r in R), len(R))} "
                     f"| {pct(sum(r['within1'] for r in R), len(R))} | {pct(len(hits), len(R))} "
                     f"| {pct(sum(not r['hit_in_abbyy'] for r in hits), len(hits))} "
                     f"| {pct(sum(r['vision'] for r in vis), len(vis))} | {secs[len(secs) // 2] if secs else '-'} |")
    L += ["", "## By class (doc year exact / on the page)", "",
          "D has no printed carrier anywhere near it; A had a previous document printing the year (the strict class).", "",
          "| arm | variant | " + " | ".join(f"{c}" for c in CLASSES) + " |", "|---|---|" + "---|" * len(CLASSES)]
    for label, name in arms:
        for v in ("image", "image+text"):
            R = [r for r in rows if r["arm"] == label and r["variant"] == v]
            if not R:
                continue
            cells = []
            for c in CLASSES:
                C = [r for r in R if r["cls"] == c]
                cells.append(f"{sum(r['exact'] for r in C)} / {sum(r['on_page'] for r in C)} of {len(C)}")
            L.append(f"| {name} | {v} | " + " | ".join(cells) + " |")
    L += ["", "## What the page dates are", "",
          "Of the documents whose owner year was found written on the page (either variant), the first such date: its "
          "kind, where it is, and which page. The handwritten share decides whether the handwritten-date reader "
          "(B test 8) is worth filing.", ""]
    kinds = {}
    for label, name in arms:
        H = {}
        for r in rows:
            if r["arm"] == label and r["on_page"] and (r["doc"] not in H or r["variant"] == "image"):
                H[r["doc"]] = r["hit"]
        if not H:
            continue
        kc = collections.Counter(h["kind"] for h in H.values())
        wc = collections.Counter(h["where"] for h in H.values())
        pc = collections.Counter(str(h["page"]) for h in H.values())
        kinds[label] = {"docs": len(H), "kind": dict(kc), "where": dict(wc), "page": dict(pc)}
        f = lambda c: ", ".join(f"{k} {n}" for k, n in c.most_common())
        L += [f"- **{name}**, {len(H)} documents. Kind: {f(kc)}. Where: {f(wc)}. Page: {f(pc)}."]
    L += ["", "## Images alone against images with the text", ""]
    for label, name in arms:
        by = {(r["doc"], r["variant"]): r for r in rows if r["arm"] == label}
        both = [d for d in docs if (d, "image") in by and (d, "image+text") in by]
        if not both:
            continue
        c = collections.Counter((by[(d, "image")]["exact"], by[(d, "image+text")]["exact"]) for d in both)
        L.append(f"- **{name}**, {len(both)} documents: right in both {c[(True, True)]}, only with images alone "
                 f"{c[(True, False)]}, only with the text added {c[(False, True)]}, neither {c[(False, False)]}.")
    own = [d for d in docs if d in owner and owner[d]["basis"] == "own page"]
    L += ["", "## Against the owner's own reading of the page", "",
          f"{len(own)} of these documents are among the owner's 54 dating cases answered as a date on the document's own "
          "page (`date-truth-sets.md`); the owner said what kind it is and whether it is legible.", ""]
    for label, name in arms:
        by = {(r["doc"], r["variant"]): r for r in rows if r["arm"] == label}
        found = [d for d in own if any(by.get((d, v), {}).get("on_page") for v in ("image", "image+text"))]
        if not any((d, "image") in by for d in own):
            continue
        kind_ok = 0
        for d in found:
            h = (by.get((d, "image")) if by.get((d, "image"), {}).get("on_page") else by[(d, "image+text")])["hit"]
            ok = owner[d]["page_date"].get("kind") or ""
            kind_ok += (h["kind"] in ("typed", "printed")) if "print" in ok or "typed" in ok else h["kind"] == ok
        L.append(f"- **{name}**: found the owner's year on the page for {pct(len(found), len(own))}; kind as the owner "
                 f"gave it for {kind_ok} of those {len(found)}. Missed: "
                 + (", ".join(f"{owner[d]['id']} ({owner[d]['page_date'].get('kind')}, "
                              f"{'legible' if owner[d]['page_date'].get('legible') else 'illegible'})"
                              for d in own if d not in found) or "none") + ".")
        diff = [d for d in own if owner[d]["page_date"].get("year") not in (None, owner[d]["owner_year"])]
        same = [d for d in diff if any(owner[d]["page_date"]["year"] in by.get((d, v), {}).get("written", ())
                                       for v in ("image", "image+text"))]
        if diff:
            L.append(f"  Where the owner's tag differs from the year the owner read on the page ("
                     + ", ".join(f"{owner[d]['id']} tag {owner[d]['owner_year']}, read {owner[d]['page_date']['year']}"
                                 for d in diff) + f"), the model quoted the year the owner read on {len(same)} of {len(diff)}.")
    out = Path(RESULTS)
    old = out.read_text() if out.exists() else ""
    kept = next((old[old.index(h):] for h in (RETRIEVAL_HEAD, READING_HEAD) if h in old),
                READING_HEAD + "\n(written by hand; a rerun keeps everything below this heading)\n")
    out.write_text("\n".join(L) + "\n" + kept)       # retrieve's section and the reading survive a rescore
    jf = Path(RESULTS[:-3] + ".json")
    prev = json.loads(jf.read_text()) if jf.exists() else {}
    jf.write_text(json.dumps({"summary": summary, "kinds": kinds, "documents": len(docs),
        "rows": [{k: v for k, v in r.items() if k not in ("hit",)} | {"hit_kind": (r["hit"] or {}).get("kind")}
                 for r in rows]} | ({"retrieval": prev["retrieval"]} if "retrieval" in prev else {}), indent=1) + "\n")
    print("\n".join(L[:40]))


RETRIEVAL_HEAD = "\n## Look-alike retrieval (B test 6)\n"
READING_HEAD = "\n## Reading it\n"


# ------------------------------------------------------------------------------------------ look-alike retrieval

WINDOW = 30          # documents either side in the same folder (a box's run of papers) searched for a look-alike
THUMB_PX = 768       # features.py's EMBED_IMG_PX: the feature print the segmenter features already use
TOPK = 3


def retrieval_targets():
    """[(target request, folder info, candidate segment indices)] for the documents the image arms read."""
    import enclosure_split as ES
    _, found = ES.load()
    docs = {}
    for r in load_requests(CLUSTER):
        docs.setdefault(r["doc"], r)
    out = []
    for d, r in sorted(docs.items()):
        info = found[d[2:]]
        k = info["k"]
        js = [j for j in range(max(0, k - WINDOW), min(len(info["segs"]), k + WINDOW + 1))
              if j != k and info["segs"][j]["kind"] == "doc"]
        out.append((r, info, js))
    return out


def jpeg_pairs():
    import corpus_pairs as CP
    pairs = {}
    for line in open(os.path.join(CP.CACHE, "pairs.tsv"), encoding="utf-8").read().splitlines()[1:]:
        pdf, jpeg, method = line.split("\t")[:3]
        if jpeg and method != "none":
            pairs[pdf] = os.path.join(CP.JPEGS, jpeg)
    return pairs


def cmd_prints(a):
    """Vision feature prints of each target's first page and of every document's first page within WINDOW of it,
    from the JPEG originals (corpus_pairs's pairing; the target's own page is the pack's confirmed, upright one when
    it has one). Thumbnails at THUMB_PX into PACK/thumbs, prints cached in PACK/prints.json."""
    import subprocess
    from PIL import Image
    import features as F
    pairs = jpeg_pairs()
    thumbs = a.pack / "thumbs"; thumbs.mkdir(exist_ok=True)
    cache_f = a.pack / "prints.json"
    cache = json.loads(cache_f.read_text()) if cache_f.exists() else {}
    want = {}
    for r, info, js in retrieval_targets():
        p0 = info["segs"][info["k"]]["pages"][0]
        own = a.pack / "images" / (hashlib.sha1(p0.encode()).hexdigest() + ".jpg")
        if own.exists():
            want[p0] = str(own)
        elif p0 in pairs:
            want.setdefault(p0, pairs[p0])
        for j in js:
            p = info["segs"][j]["pages"][0]
            if p in pairs:
                want.setdefault(p, pairs[p])
    todo = [(p, src) for p, src in want.items() if p not in cache]
    print(f"{len(want)} first pages, {len(todo)} to print", flush=True)
    tool = str(F.build_embed_tool())
    for i in range(0, len(todo), 200):
        jobs = []
        for p, src in todo[i:i + 200]:
            th = thumbs / (hashlib.sha1(p.encode()).hexdigest() + ".jpg")
            if not th.exists():
                try:
                    with Image.open(src) as im:
                        im.draft("RGB", (THUMB_PX * 2, THUMB_PX * 2))
                        im = im.convert("RGB")
                        im.thumbnail((THUMB_PX, THUMB_PX))
                        im.save(th, "JPEG", quality=85)
                except Exception:
                    cache[p] = None
                    continue
            jobs.append((p, th))
        r = subprocess.run([tool], input="".join(f"image\t{th}\n" for _, th in jobs), capture_output=True, text=True,
                           check=True)
        res = [json.loads(l) for l in r.stdout.splitlines() if l.strip()]
        assert len(res) == len(jobs), (len(res), len(jobs))
        for (p, _), o in zip(jobs, res):
            cache[p] = o.get("vec")
        cache_f.write_text(json.dumps(cache))
        print(f"{min(i + 200, len(todo))}/{len(todo)}", flush=True)


def cmd_retrieve(a):
    """Look-alike retrieval as dating evidence: each target takes the text-rule year of the most similar dated
    document's first page within WINDOW (nn1), or the majority of the TOPK nearest (knn), against two positional
    baselines: the nearest dated document before (date_traceable's propagation) and the nearest either side."""
    import math
    import date_traceable as T
    cache = json.loads((a.pack / "prints.json").read_text())
    owner = owner_page_truth()
    rows = []
    for r, info, js in retrieval_targets():
        k, truth = info["k"], r["truth"].get("year")
        v0 = cache.get(info["segs"][k]["pages"][0])
        dated = []
        for j in js:
            y = T.rule_pick(T.candidates(info["texts"][j]))[0]
            if y is not None:
                dated.append((j, y, cache.get(info["segs"][j]["pages"][0])))
        before = [x for x in dated if x[0] < k]
        prev = max(before, key=lambda x: x[0]) if before else None
        near = min(dated, key=lambda x: (abs(x[0] - k), x[0] > k)) if dated else None
        sims = sorted((math.dist(v0, v), j, y) for j, y, v in dated if v) if v0 else []
        knn = None
        if sims:
            c = collections.Counter(y for _, _, y in sims[:TOPK])
            knn = next(y for _, _, y in sims[:TOPK] if c[y] == max(c.values()))
        nn1 = sims[0] if sims else None
        row = {"doc": r["doc"], "cls": r["cls"], "truth": truth, "printed": bool(v0), "dated_near": len(dated),
               "prev": prev and prev[1], "near": near and near[1], "nn1": nn1 and nn1[2], "knn": knn,
               "nn1_offset": nn1 and nn1[1] - k, "nn1_dist": nn1 and round(nn1[0], 3),
               "same_as_prev": bool(nn1 and prev and nn1[1] == prev[0])}
        o = owner.get(r["doc"])
        if o:
            row["owner_case"], row["owner_basis"] = o["id"], o["basis"]
        rows.append(row)
    arms = (("prev", "nearest dated before (propagation)"), ("near", "nearest dated either side"),
            ("nn1", "most similar page (feature print)"), ("knn", f"majority of the {TOPK} most similar"))
    L = [RETRIEVAL_HEAD.strip("\n"), "",
         "Each document takes the year the text rule (`date_traceable.rule_pick`) gives the document whose first page "
         f"looks most like its own, among the dated documents within {WINDOW} either side in the same folder: Apple "
         f"Vision feature prints of the JPEG originals at {THUMB_PX} px (corpus_pairs's pairing), the print the "
         "segmenter features already use, by Euclidean distance. The positional baselines are the same rule's year of "
         "the nearest dated document before (what date_traceable propagates) and either side. $0, this Mac.", "",
         "| class | n | " + " | ".join(n for _, n in arms) + " |", "|---|---|" + "---|" * len(arms)]
    summary = {}
    for c in CLASSES + ("all",):
        R = [x for x in rows if c in ("all", x["cls"])]
        cells = []
        for key, _ in arms:
            ex = sum(x[key] == x["truth"] for x in R)
            w1 = sum(x[key] is not None and abs(x[key] - x["truth"]) <= 1 for x in R)
            cells.append(f"{ex} / {w1}")
            summary.setdefault(c, {})[key] = {"exact": ex, "within1": w1, "n": len(R)}
        L.append(f"| {c} | {len(R)} | " + " | ".join(cells) + " |")
    nn = [x for x in rows if x["nn1"] is not None]
    offs = collections.Counter(min(abs(x["nn1_offset"]), 6) for x in nn)
    gain = [x for x in nn if x["nn1"] == x["truth"] and x["prev"] != x["truth"] and x["near"] != x["truth"]]
    loss = [x for x in nn if x["nn1"] != x["truth"] and (x["prev"] == x["truth"] or x["near"] == x["truth"])]
    L += ["", f"Cells are exact / within one year, of n. {sum(x['printed'] for x in rows)} of {len(rows)} targets "
          f"have a print; the most similar page is the nearest dated document before on "
          f"{sum(x['same_as_prev'] for x in nn)} of {len(nn)}. Its distance in documents from the target: "
          + ", ".join(f"{'6+' if d == 6 else d} {n}" for d, n in sorted(offs.items())) + ". Right by look-alike where "
          f"both positional baselines are wrong: {len(gain)}; wrong by look-alike where a baseline is right: {len(loss)}."]
    covers = [x for x in rows if x.get("owner_basis") == "cover"]
    if covers:
        L.append("The owner-confirmed covers (the document came with the one before it, so −1 is the cover): " + ", ".join(
            f"{x['owner_case']} most similar page {x['nn1_offset']:+d}" if x["nn1_offset"] is not None
            else f"{x['owner_case']} no print" for x in covers) + ".")
    res = Path(RESULTS)
    text = res.read_text()
    head, _, tail = text.partition(READING_HEAD)
    head = head.split(RETRIEVAL_HEAD)[0].rstrip("\n")
    res.write_text(head + "\n\n" + "\n".join(L) + "\n" + READING_HEAD + tail)
    jf = Path(RESULTS[:-3] + ".json")
    j = json.loads(jf.read_text())
    j["retrieval"] = {"window": WINDOW, "thumb_px": THUMB_PX, "topk": TOPK, "summary": summary, "rows": rows}
    jf.write_text(json.dumps(j, indent=1) + "\n")
    print("\n".join(L))


def cmd_vision(a):
    """Apple Vision text of the targets' first pages, for the scorer's check, into date_traceable's cache (its renderer
    and reader; the corpus is only read). That cache may have moved to the owner's backup (2026-10-30); this rebuilds
    only the pages page_sources() reads. Resumable."""
    import subprocess
    import corpus_survey as CS
    import data as D
    import date_traceable as T
    import enclosure_split as ES
    _, found = ES.load()
    pages = []
    for d in T.owner_docs("abbyy"):
        info = found.get(d["id"][2:])
        pages += info["segs"][info["k"]]["pages"][:PAGES] if info else []
    tool = D.build_ocr_tool()
    if tool is None:
        raise SystemExit("ocr.swift did not compile")
    for sub in ("img", "txt"):
        os.makedirs(os.path.join(T.VISION, sub), exist_ok=True)
    jobs = os.path.join(T.VISION, "jobs-date-image.tsv")
    with open(jobs, "w", encoding="utf-8") as fh:
        for p in pages:
            img, txt = T.vision_page(p)
            if os.path.exists(txt):
                continue
            if not os.path.exists(img):
                subprocess.run(["/usr/bin/sips", "-Z", str(T.VISION_PX), "-s", "format", "jpeg",
                                os.path.join(CS.CORPUS, p), "--out", img], capture_output=True, check=False)
            if os.path.exists(img):
                fh.write(f"{img}\t{txt}\n")
    subprocess.run([str(tool), jobs], check=False)
    print(f"{sum(os.path.exists(T.vision_page(p)[1]) for p in pages)} of {len(pages)} pages have Vision text")


RESULTS = str(HERE.parent.parent / "segbench-results" / "date-image.md")
MAX_TOKENS = 700


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pack"); p.add_argument("--out", type=Path, required=True)
    p.add_argument("--remote", default="/scratch/users/cp1/fs-ocr/date-image-20261022")
    p = sub.add_parser("collect-mac"); p.add_argument("--pack", type=Path, default=PACK)
    p.add_argument("--model", default="qwen3-vl-8b-mlx4"); p.add_argument("--side", type=int, default=1400)
    p.add_argument("--variant", choices=("image", "image+text")); p.add_argument("--limit", type=int)
    p = sub.add_parser("score"); p.add_argument("--cluster", type=Path, default=CLUSTER)
    p.add_argument("--pack", type=Path, default=PACK)
    sub.add_parser("vision")
    for name in ("prints", "retrieve"):
        p = sub.add_parser(name); p.add_argument("--pack", type=Path, default=PACK)
    a = ap.parse_args()
    {"pack": cmd_pack, "collect-mac": cmd_collect_mac, "score": cmd_score, "prints": cmd_prints,
     "retrieve": cmd_retrieve, "vision": cmd_vision}[a.cmd](a)


if __name__ == "__main__":
    main()
