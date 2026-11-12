#!/usr/bin/env python3
"""W46.date-route-pipeline: the restated dating route end to end (13-stage-rules/08-dating.md item 8.1, with 8.2).

The route of 08-dating.md section 3, measured as one pipeline instead of separate step rows (caveat F-1):

  1. explicit, from the text: the trace prompt with the neighbours' dates (date_traceable.trace_prompt "neigh") on the
     app's own OCR text; the year is explicit when the document's own text carries it (a rule candidate of
     date_traceable.candidates, or the reply's own quote from "self" passing date_scorers.evidence_check);
  2. explicit, from the image: on a document whose own text gives no year candidate, the image pass
     (date_image.PROMPT, the first two pages, images alone); its document date counts when the year is written in a
     date it quoted (date_undated.own_date);
  3. inherited: not measured here (the enclosure marker is close to inert, B-enc; the folder date is W47.ct-folder-date);
  4. estimated from neighbours: the same trace reply, written only when its evidence passes the checker, always with
     Date Uncertain; a reply whose evidence fails writes no year.

Date Uncertain is set by the step (explicit off, estimated on), never by the model's flag. One trace call per document
serves steps 1 and 4; the image call is made only where step 2 runs. Item 8.2 rides along: the image pass is also sent
for the owner's documents whose text has a year candidate, to count how often it would change the year or find a
second-role date (stamps), which the route itself does not send.

Sets: the owner's 300 (date_tagging's sample, owner tags) and the 90 undated documents of W46.date-undated (no date
tag; the owner's rulings on 20 of them, W46.date-undated-fold). Text: Apple Vision (segbench's ocr.swift, the app's
settings, macOS 27.2) on the JPEG originals, confirmed against the PDF and turned upright (date_undated's procedure,
2,400 px), the document's first DOC_PAGES pages and each neighbour's first NEAR_PAGES; no ABBYY text is an input (owner,
2026-10-30). A document whose first page has no confirmed JPEG original is left out and counted. Pages date_undated or
date_image already read or rendered the same way are reused from their caches, not read again.

    python3 date_route_pipeline.py sample            # the two sets and their neighbours -> CACHE/targets.jsonl ($0)
    python3 ops/autonomous/heavy-run.py run -- python3 date_route_pipeline.py vision    # orient + Vision, resumable
    python3 date_route_pipeline.py run [--limit N]   # Gemini 3.7 Flash through the gateway (paid, CAP)
    python3 date_route_pipeline.py export --out DIR [--remote R]   # the same requests for the 27B on Sherlock
    python3 date_route_pipeline.py score             # segbench-results/date-route-pipeline.md and .json

The gateway is real money on a Stanford PTA (root CLAUDE.md): spend is counted at gateway_gemini.PRICE (3.8's list
price, a ceiling) into CACHE/calls.jsonl before a reply is used; CAP bounds the item. Gemini replies W46.date-image-paid
and W46.date-undated already made with the same prompt, body and image bytes are reused. The 27B half runs on Sherlock
(no engine session contacts it): `export` writes the pack, and `score` adds the 27B's rows once its answers are in
CACHE/answers-27b.jsonl. READ ONLY on the corpus and the JPEG originals; everything written stays in the private bench
cache. Run from scripts/segbench, with numpy and PIL (~/.local/share/visionocr-ocrlab/venv) for vision.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import math
import os
import statistics
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import date_image as DI
import date_scorers as SC
import date_tagging as DT
import date_traceable as T
import date_undated as DU
import gateway_gemini as G

CACHE = Path(os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/date-route-pipeline"))
RESULTS = HERE.parent.parent / "segbench-results" / "date-route-pipeline.md"
RESULTS_JSON = RESULTS.with_suffix(".json")
DOC_PAGES, NEAR_PAGES = DU.DOC_PAGES, DU.NEAR_PAGES
CAP = 3.00            # the item's total; estimate about $1.70 (390 trace replies, about 180 new image replies)
TRACE_MAX = 4096      # date_traceable_gateway.MAX_TOKENS: 3.7 reasons first
WORST_TRACE = (12000 * G.PRICE[0] + TRACE_MAX * G.PRICE[1]) / 1e6
WORST_IMAGE = DU.WORST_IMAGE
GEMINI = "gemini3.7-flash-gw"
QWEN = "qwen3.6-27b"
QWEN_ANSWERS = CACHE / "answers-27b.jsonl"
# Replies already made with the same request: W46.date-image-paid's for the owner's 122, W46.date-undated's for the 90.
CACHED_OWNER_IMAGE = DI.PACK / "gateway" / "gemini3.7-flash-gw-2400"
CACHED_OWNER_IMAGE_LEDGER = DI.PACK / "gateway" / "calls.jsonl"
CACHED_QWEN_IMAGE = DI.CLUSTER / "out"
_lock = threading.Lock()


# --- the sets ---------------------------------------------------------------------------------------------------

def _labels():
    import corpus_pairs as CP
    lab = {}
    for line in open(os.path.join(CP.CACHE, "labels.jsonl"), encoding="utf-8"):
        g = json.loads(line)
        lab[(g["folder_id"], g["n"])] = g
    return lab


def neighbours(segs, k):
    """[{label, dist, pages}] for up to three documents either side, Box/Folder labels skipped (date_traceable's
    rule): P1 is the document just before, N1 just after."""
    before = [j for j in range(k - 1, -1, -1) if segs[j]["kind"] == "doc"][:T.NEAR]
    after = [j for j in range(k + 1, len(segs)) if segs[j]["kind"] == "doc"][:T.NEAR]
    return ([{"label": f"P{i}", "dist": i, "pages": segs[j]["pages"]} for i, j in enumerate(before, 1)]
            + [{"label": f"N{i}", "dist": -i, "pages": segs[j]["pages"]} for i, j in enumerate(after, 1)])


def cmd_sample(a):
    import enclosure_split as ES
    sample, found = ES.load()
    out, counts = [], collections.Counter()
    for d in sample:
        info = found.get(d["id"])
        if not info:
            counts["owner, not located"] += 1
            continue
        k, segs = info["k"], info["segs"]
        out.append({"id": "o:" + d["id"], "set": "owner", "kind": d["class"], "truth": d["truth"],
                    "collection": d["collection"], "folder": info["folder"], "position": k,
                    "pages": segs[k]["pages"], "near": neighbours(segs, k)})
    lab, segs_of = _labels(), {}
    for d in DU.targets():
        if d["set"] != "undated":
            continue
        f = d["folder"]
        if f not in segs_of:
            segs_of[f] = DT.folder_documents(f, lab)
        segs = segs_of[f]
        k = next((j for j, s in enumerate(segs) if s["pages"][:1] == d["pages"][:1]), None)
        if k is None:
            counts["undated, not located"] += 1
            continue
        out.append({"id": "u:" + d["id"], "set": "undated", "collection": d["collection"], "folder": f, "position": k,
                    "pages": d["pages"], "near": neighbours(segs, k)})
    counts.update(collections.Counter(d["set"] for d in out))
    CACHE.mkdir(parents=True, exist_ok=True)
    with open(CACHE / "targets.jsonl", "w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(d, ensure_ascii=False) + "\n" for d in out)
    print(dict(counts))


def targets():
    return [json.loads(l) for l in open(CACHE / "targets.jsonl", encoding="utf-8")]


# --- Vision text and images of the JPEG originals ---------------------------------------------------------------

def _name(page):
    return hashlib.sha1(page.encode()).hexdigest()


def txt_path(page):
    """This item's reading of a page, else date_undated's (the same procedure, macOS 27.2, 2026-10-31), else None."""
    for p in (CACHE / "txt" / (_name(page) + ".txt"), DU.page_files(page)[1]):
        if p.exists():
            return p
    return None


def img_path(page):
    """The upright 2,400 px JPEG of a page: this item's, else date_image's pack (the same procedure), else None."""
    for p in (CACHE / "img" / (_name(page) + ".jpg"), DI.PACK / "images" / (_name(page) + ".jpg")):
        if p.exists():
            return p
    return None


def pages_wanted(ts):
    """(pages to read, pages whose image the image pass sends)."""
    read, image = [], []
    for d in ts:
        read += d["pages"][:DOC_PAGES]
        image += d["pages"][:DI.PAGES]
        for n in d["near"]:
            read += n["pages"][:NEAR_PAGES]
    return list(dict.fromkeys(read)), list(dict.fromkeys(image))


def cmd_vision(a):
    """Orient and render each wanted page that no cache holds (date_undated.cmd_vision's procedure and thresholds),
    then read the unread ones with ocr.swift. Resumable; the verdicts are kept in CACHE/orient.json."""
    import tempfile
    from PIL import Image
    import corpus_pairs as CP
    import corpus_survey as CS
    import data as D
    import ocr_truth as OT
    pairs = DU.jpeg_pairs()
    read, image = pages_wanted(targets())
    need = [p for p in dict.fromkeys(read + image)
            if img_path(p) is None and (txt_path(p) is None or p in set(image))][: a.limit or None]
    for sub in ("img", "txt", "tmp"):
        (CACHE / sub).mkdir(parents=True, exist_ok=True)
    op = CACHE / "orient.json"
    orient = json.loads(op.read_text()) if op.exists() else {}
    du_orient = json.loads((DU.CACHE / "orient.json").read_text()) if (DU.CACHE / "orient.json").exists() else {}
    tmp = Path(tempfile.mkdtemp(dir=CACHE / "tmp"))
    t0 = time.monotonic()
    for k, p in enumerate(need, 1):
        if p in orient or "why" in du_orient.get(p, {}):
            continue
        j = pairs.get(p)
        if not j:
            orient[p] = {"why": "no JPEG paired"}
        else:
            try:
                with Image.open(os.path.join(CP.JPEGS, j)) as im:
                    deg, corr = OT.orient_like_pdf(im, Path(os.path.join(CS.CORPUS, p)), tmp)
                    if corr < DI.MIN_CORR:
                        orient[p] = {"why": "JPEG not the same photo", "corr": round(corr, 3)}
                    else:
                        im = im.convert("RGB").rotate(deg, expand=True)
                        im.thumbnail((DU.LONG_SIDE, DU.LONG_SIDE), Image.Resampling.LANCZOS)
                        im.save(CACHE / "img" / (_name(p) + ".jpg"), "JPEG", quality=90)
                        orient[p] = {"deg": deg, "corr": round(corr, 3)}
            except Exception as e:
                orient[p] = {"why": "comparison failed", "error": type(e).__name__}
        if k % 50 == 0:
            op.write_text(json.dumps(orient))
            print(f"oriented {k}/{len(need)}, {time.monotonic() - t0:.0f} s", flush=True)
    op.write_text(json.dumps(orient))
    orient_s = time.monotonic() - t0
    tool = D.build_ocr_tool()
    if tool is None:
        raise SystemExit("ocr.swift did not compile")
    jobs, n = CACHE / "jobs.tsv", 0
    with open(jobs, "w", encoding="utf-8") as fh:
        for p in read:
            img = CACHE / "img" / (_name(p) + ".jpg")
            if txt_path(p) is None and img.exists():
                fh.write(f"{img}\t{CACHE / 'txt' / (_name(p) + '.txt')}\n"); n += 1
    t1 = time.monotonic()
    subprocess.run([str(tool), str(jobs)], check=False)
    rec = {"pages_read": len(read), "pages_imaged": len(image), "oriented_now": len(need), "read_now": n,
           "orient_s": round(orient_s, 1), "read_s": round(time.monotonic() - t1, 1),
           "have_text": sum(txt_path(p) is not None for p in read), "have_image": sum(img_path(p) is not None for p in image),
           "os": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()}
    with open(CACHE / "timing.jsonl", "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    print(rec)


def text_of(pages, n):
    """The segment's Vision text as DocumentSegment.combinedText joins it; an unread page reads as empty."""
    return "\n\n".join((txt_path(p).read_text(encoding="utf-8") if txt_path(p) else "") for p in pages[:n])


def readable(d):
    """The document's first page has Vision text of a confirmed JPEG original."""
    return txt_path(d["pages"][0]) is not None


def doc_of(d):
    """date_traceable's document shape on Vision text: {id, text, near: [{label, dist, text, pick}]}."""
    near = []
    for n in d["near"]:
        t = text_of(n["pages"], NEAR_PAGES)
        near.append({"label": n["label"], "dist": n["dist"], "text": t, "pick": T.rule_pick(T.candidates(t))})
    return {**d, "text": text_of(d["pages"], DOC_PAGES), "near": near}


def images_of(d):
    got = [img_path(p) for p in d["pages"][:DI.PAGES]]
    return [g.read_bytes() for g in got if g is not None]


# --- the gateway ------------------------------------------------------------------------------------------------

def ledger(path=None):
    p = path or CACHE / "calls.jsonl"
    return [json.loads(x) for x in p.read_text().splitlines() if x.strip()] if p.exists() else []


def spent():
    return sum(G.charge(r) for r in ledger())


def trace_body(prompt):
    """date_traceable_gateway's request: temperature 0, reasoning low."""
    return {"model": G.MODEL, "temperature": 0, "max_tokens": TRACE_MAX, "reasoning_effort": "low",
            "messages": [{"role": "user", "content": prompt}]}


def trace_dest(d):
    return CACHE / "trace" / (d["id"].replace(":", "_") + ".json")


def image_dest(d):
    """Where the Gemini image reply is or goes: a reply already made for the same request is reused."""
    if d["set"] == "undated":
        return DU.CACHE / "image" / (d["id"][2:] + ".json")
    cached = CACHED_OWNER_IMAGE / ("image|" + d["id"] + ".json")
    return cached if cached.exists() else CACHE / "image" / (d["id"].replace(":", "_") + ".json")


def call(key, b, worst, dest: Path):
    """One reply, cached by destination; the ledger line is written before the reply is used."""
    if dest.exists():
        return json.loads(dest.read_text())
    with _lock:
        if spent() + worst > CAP:
            raise SystemExit(f"cap: ${spent():.4f} spent of ${CAP}")
    t = time.time()
    for attempt in range(3):
        r = G.request("/chat/completions", b)
        if r.status_code in (429, 500, 502, 503, 504) and attempt < 2:
            time.sleep(10 * (attempt + 1)); continue
        break
    got = r.json() if r.headers.get("content-type", "").startswith("application/json") else {"raw": r.text[:2000]}
    usage = got.get("usage") or {}
    rec = {"id": key, "http": r.status_code, "t": t, "wall_s": round(time.time() - t, 3), "model": got.get("model"),
           "usage": usage, "cost": round(G.cost(usage), 6),
           "request_sha256": hashlib.sha256(json.dumps(b, sort_keys=True).encode()).hexdigest()}
    rec = G.with_gateway_cost(rec, r)
    with _lock:
        CACHE.mkdir(parents=True, exist_ok=True)
        with (CACHE / "calls.jsonl").open("a") as fh:
            fh.write(json.dumps(rec) + "\n")
    choice = (got.get("choices") or [{}])[0]
    text = (choice.get("message") or {}).get("content") if r.status_code == 200 else None
    out = {"id": key, "text": text, "finish": choice.get("finish_reason"), "seconds": rec["wall_s"],
           "tokens": [usage.get("prompt_tokens"), usage.get("completion_tokens")], "model": G.MODEL}
    if r.status_code == 200 and text:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    else:
        print(key, r.status_code, out["finish"], json.dumps(got)[:300], flush=True)
    return out


def wants_image(d, doc):
    """The route sends the image pass where the own text has no year candidate; item 8.2 adds the owner's others."""
    return d["set"] == "owner" or not T.candidates(doc["text"])


def cmd_run(a):
    jobs = []
    for d in targets():
        if not readable(d):
            continue
        doc = doc_of(d)
        jobs.append(("trace-neigh|" + d["id"], trace_body(T.trace_prompt(doc, "neigh")), WORST_TRACE, trace_dest(d)))
        if wants_image(d, doc):
            imgs = images_of(d)
            if imgs:
                jobs.append(("image|" + d["id"], DU.image_body(imgs), WORST_IMAGE, image_dest(d)))
    jobs = [j for j in jobs if not j[3].exists()][: a.limit or None]
    print(f"{len(jobs)} requests to send; ${spent():.4f} spent so far", flush=True)
    with ThreadPoolExecutor(4) as ex:
        res = list(ex.map(lambda j: call(*j), jobs))
    print(f"{sum(bool(r.get('text')) for r in res)}/{len(res)} answered, ${spent():.4f} spent in all "
          f"({G.billed_note(ledger())})", flush=True)


# --- the 27B pack (Sherlock) ------------------------------------------------------------------------------------

def cmd_export(a):
    """requests.jsonl for the old FarmShare kit's text mode ({id, prompt}: the trace replies) and image-requests.jsonl
    in date_image's pack form (remote image paths, sha256 of each image), images copied beside them. The 27B's image
    replies on W46.date-image's 122 (same prompt and image bytes, Sherlock 2026-10-22) are reused, not re-asked."""
    import shutil
    out = Path(a.out)
    (out / "images").mkdir(parents=True, exist_ok=True)
    text, image, reused = [], [], 0
    for d in targets():
        if not readable(d):
            continue
        doc = doc_of(d)
        text.append({"id": "trace-neigh|" + d["id"], "prompt": T.trace_prompt(doc, "neigh")})
        if not wants_image(d, doc):
            continue
        if (CACHED_QWEN_IMAGE / ("image|" + d["id"] + ".json")).exists():
            reused += 1
            continue
        paths, digests = [], []
        for p in d["pages"][:DI.PAGES]:
            src = img_path(p)
            if src is None:
                continue
            shutil.copyfile(src, out / "images" / src.name)
            paths.append(f"{a.remote}/images/{src.name}")
            digests.append(hashlib.sha256(src.read_bytes()).hexdigest())
        if paths:
            image.append({"id": "image|" + d["id"], "doc": d["id"], "variant": "image", "pages": len(paths),
                          "images": paths, "image_sha256s": digests, "image": None, "prompt": DI.PROMPT})
    for name, rows in (("requests.jsonl", text), ("image-requests.jsonl", image)):
        with open(out / name, "w", encoding="utf-8") as fh:
            fh.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    meta = {"trace_requests": len(text), "image_requests": len(image), "image_replies_reused": reused,
            "prompt_sha256": hashlib.sha256(DI.PROMPT.encode()).hexdigest(), "max_tokens_text": 512,
            "thinking": "off (date-tagging.md: with thinking on the 27B ran to the cap on 300 of 300)"}
    (out / "pack.json").write_text(json.dumps(meta, indent=1) + "\n")
    print(meta)


# --- the route --------------------------------------------------------------------------------------------------

def route(doc, trace_raw, image_rec):
    """The route's answer for one document: {year, du, cls, evidence, ...}. cls is the evidence class: "text"
    (explicit from the own text), "image" (explicit from the page image), "estimate" (from a neighbour, checked,
    Date Uncertain), or "none" (no year written). image_rec is None where the image pass was not sent."""
    cands = T.candidates(doc["text"])
    own = {c["year"] for c in cands}
    tr = T.parse_trace(trace_raw)
    verdict, reason = SC.evidence_check(tr["y"], tr["evidence"], T.context_of(doc, "neigh")) if tr["parsed"] else (
        "none", "unparsed")
    cited = (tr["evidence"] or {}).get("neighbour", "self") if tr["evidence"] else None
    base = {"trace_y": tr["y"], "verdict": verdict, "reason": reason, "cited": cited, "lo": tr["lo"], "hi": tr["hi"],
            "has_candidate": bool(cands), "image_sent": image_rec is not None}
    if tr["y"] is not None and (tr["y"] in own or (verdict == "valid" and cited == "self")):
        return {**base, "year": tr["y"], "du": False, "cls": "text", "step": 1}
    if cands:
        if tr["y"] is not None and verdict == "valid":
            return {**base, "year": tr["y"], "du": True, "cls": "estimate", "step": 4}
        # an unparsed or unchecked reply: the rule stage's explicit year stands (08-dating.md, "Fallback")
        y = T.rule_pick(cands)[0]
        return {**base, "year": y, "du": y is None, "cls": "text" if y is not None else "none", "step": 1}
    if image_rec is not None:
        ok, own_y, _ = DU.own_date(image_rec)
        if own_y is not None:
            return {**base, "year": own_y, "du": False, "cls": "image", "step": 2}
    if tr["y"] is not None and verdict == "valid":
        return {**base, "year": tr["y"], "du": True, "cls": "estimate", "step": 4}
    return {**base, "year": None, "du": True, "cls": "none", "step": None}


def load(path):
    return json.loads(path.read_text()) if path.exists() else None


def qwen_answers():
    """{request id: {"text": raw}} from the 27B's Sherlock answers (the kit's answers.jsonl rows carry "raw"), with
    W46.date-image's cached image replies for the 122."""
    out = {}
    if QWEN_ANSWERS.exists():
        for l in open(QWEN_ANSWERS, encoding="utf-8"):
            if l.strip():
                r = json.loads(l)
                out[r["id"]] = {"text": r.get("raw", r.get("text")), "seconds": r.get("seconds")}
    if CACHED_QWEN_IMAGE.is_dir():
        for f in CACHED_QWEN_IMAGE.iterdir():
            if f.name.startswith("image|"):
                r = json.loads(f.read_text())
                out.setdefault(f.name[:-5], {"text": r.get("text", r.get("raw")), "seconds": r.get("seconds")})
    return out


def replies(model, d):
    """(trace raw or None, image rec or None) for one document under one model."""
    if model == GEMINI:
        t, im = load(trace_dest(d)), load(image_dest(d))
        return (t or {}).get("text") if t else None, im
    q = _QWEN.get("cache")
    if q is None:
        q = _QWEN["cache"] = qwen_answers()
    t, im = q.get("trace-neigh|" + d["id"]), q.get("image|" + d["id"])
    return (t or {}).get("text") if t else None, im


_QWEN = {}


# --- scoring ----------------------------------------------------------------------------------------------------

def wilson(k, n, z=1.96):
    if not n:
        return None
    p = k / n
    c = (p + z * z / (2 * n)) / (1 + z * z / n)
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return [round(100 * (c - h), 1), round(100 * (c + h), 1)]


def frac(k, n):
    return {"k": k, "n": n, "pct": round(100 * k / n, 1) if n else None, "ci": wilson(k, n)}


def stratum(doc, truth_y, image_rec):
    """The owner document's class by where its year is: "in text" (written in its own Vision text, 3,000 characters),
    "on the page" (not in the text, but the image pass quotes a date with that year), "not on the page". Defined from
    the Gemini image pass sent on every owner document, so the same for every route scored."""
    if str(truth_y) in doc["text"][:T.TEXT_CHARS]:
        return "in text"
    if image_rec is not None:
        _, _, written = DU.own_date(image_rec)
        if truth_y in written:
            return "on the page"
        return "not on the page"
    return "no image reply"


STRATA = ("in text", "on the page", "not on the page")
CLASSES = ("text", "image", "estimate", "none")
QUOTE_CLASSES = ("four digits", "two digits", "ocr damage")


def checker_counts(rows):
    """The evidence checker on the fresh trace replies (P13-5): valid / unsupported / none; right years refused and
    wrong years accepted; each by how the quote carries the year (valid) and by the reply's year class."""
    out = collections.Counter()
    by = collections.defaultdict(collections.Counter)
    for r in rows:
        if r["trace_y"] is None:
            continue
        v, right = r["verdict"], r["truth_y"] is not None and r["trace_y"] == r["truth_y"]
        out[v] += 1
        how = next((c for c in QUOTE_CLASSES[1:] if f"({c})" in r["reason"]), "four digits") if v == "valid" else None
        if v == "valid":
            by[how]["valid"] += 1
            if r["truth_y"] is not None and not right:
                out["wrong years accepted"] += 1; by[how]["wrong accepted"] += 1
        elif right:
            out["right years refused"] += 1
            by[r["reason"]]["right refused"] += 1
        if v != "valid":
            by[r["reason"]]["refused"] += 1
    return {"counts": dict(out), "by": {k: dict(v) for k, v in by.items()}}


def score_model(model, ts, gem_image):
    """Rows for every readable document under one model; None when the model has no trace replies."""
    rows = []
    for d in ts:
        if not readable(d):
            continue
        doc = doc_of(d)
        traw, im = replies(model, d)
        if traw is None:
            continue
        sent = im if (im is not None and not T.candidates(doc["text"])) else None
        r = route(doc, traw, sent)
        truth = d.get("truth") or {}
        r.update({"id": d["id"], "set": d["set"], "kind": d.get("kind"), "truth_y": truth.get("year"),
                  "truth_du": truth.get("du"), "decade": truth.get("decade")})
        if d["set"] == "owner" and r["truth_y"] is not None:
            r["stratum"] = stratum(doc, r["truth_y"], gem_image.get(d["id"]))
        if im is not None and r["has_candidate"]:
            ok, own_y, written = DU.own_date(im)
            parsed = DI.read(im)
            r["intext_image"] = {"ok": ok, "own": own_y, "stamps": sum(1 for x in parsed["dates"] if x["written"] and (
                x["where"] == "stamp" or x["kind"] == "stamped"))}
        if d["set"] == "undated" and im is not None:
            r["page_own"] = DU.own_date(im)[1]
        rows.append(r)
    return rows or None


def summarise(model, rows, ts):
    owner = [r for r in rows if r["set"] == "owner" and r["truth_y"] is not None]
    S = {"documents": len(rows), "owner_scored": len(owner)}
    S["by_stratum"] = {s: {"n": len(g), "exact": frac(sum(r["year"] == r["truth_y"] for r in g), len(g)),
                           "wrong": frac(sum(r["year"] is not None and r["year"] != r["truth_y"] for r in g), len(g)),
                           "no_year": frac(sum(r["year"] is None for r in g), len(g))}
                       for s in STRATA for g in [[r for r in owner if r.get("stratum") == s]]}
    nit = [r for r in owner if r.get("stratum") in ("on the page", "not on the page")]
    S["not_in_text"] = frac(sum(r["year"] == r["truth_y"] for r in nit), len(nit))
    S["all_owner"] = frac(sum(r["year"] == r["truth_y"] for r in owner), len(owner))
    S["by_class"] = {c: {"n": len(g), "exact": frac(sum(r["year"] == r["truth_y"] for r in g), len(g))}
                     for c in CLASSES for g in [[r for r in owner if r["cls"] == c]]}
    # Date Uncertain by step against the owner's flag (two error rates, DAT-7)
    cert = [r for r in owner if r["truth_du"] is False and r["year"] is not None]
    unc = [r for r in owner if r["truth_du"] is True and r["year"] is not None]
    S["du_vs_owner"] = {"certain_flagged": frac(sum(r["du"] for r in cert), len(cert)),
                        "uncertain_unflagged": frac(sum(not r["du"] for r in unc), len(unc))}
    est = [r for r in owner if r["cls"] == "estimate" and r["lo"] is not None]
    S["estimate_interval"] = {"covered": frac(sum(r["lo"] <= r["truth_y"] <= r["hi"] for r in est), len(est)),
                              "median_width": statistics.median([r["hi"] - r["lo"] for r in est]) if est else None}
    S["checker"] = checker_counts([r for r in rows if r["set"] == "owner"])
    S["checker_by_stratum"] = {s: checker_counts([r for r in owner if r.get("stratum") == s])["counts"] for s in STRATA}
    dec = [r for r in rows if r["set"] == "owner" and r["decade"] is not None]
    S["decade"] = {"n": len(dec), "in_decade": sum(r["year"] is not None and r["year"] // 10 * 10 == r["decade"]
                                                   for r in dec),
                   "year_written": sum(r["year"] is not None for r in dec),
                   "flagged": sum(r["du"] for r in dec if r["year"] is not None)}
    S["undated"] = undated_summary([r for r in rows if r["set"] == "undated"])
    S["intext_image"] = intext_image([r for r in owner if "intext_image" in r])
    S["calls"] = route_calls(rows)
    return S


def undated_summary(rows):
    """False years on the undated 90: a year written without Date Uncertain where the document has no own date of that
    year. Truth: the owner's ruling where he ruled (20 documents, W46.date-undated-fold), else the Gemini image pass's
    reading of the page (model-scored; reported apart)."""
    rp = DU.SHEET / DU.RULINGS_NAME
    rul = {v["id"]: v["owner"] for v in json.loads(rp.read_text())["documents"].values()} if rp.exists() else {}
    out = {"n": len(rows), "by_class": dict(collections.Counter(r["cls"] for r in rows)),
           "explicit": sum(not r["du"] and r["year"] is not None for r in rows)}
    ruled, model = [], []
    for r in rows:
        i = r["id"][2:]
        if r["year"] is None or r["du"]:
            continue
        if i in rul:
            o = rul[i]
            ruled.append(not (o["own"] and o["lo"] is not None and o["lo"] <= r["year"] <= o["hi"]))
        else:
            model.append(r.get("page_own") != r["year"])
    out["owner_ruled"] = {"documents_ruled": sum(r["id"][2:] in rul for r in rows), "explicit_ruled": len(ruled),
                          "false": sum(ruled)}
    out["model_scored"] = {"explicit_unruled": len(model), "false": sum(model)}
    out["false_year"] = frac(sum(ruled) + sum(model), len(rows))
    out["estimates"] = sum(r["cls"] == "estimate" for r in rows)
    return out


def intext_image(rows):
    """Item 8.2: the image pass on owner documents whose text has a year candidate (the route does not send it)."""
    ch = [r for r in rows if r["intext_image"]["own"] is not None and r["intext_image"]["own"] != r["year"]]
    return {"n": len(rows), "own_date_found": sum(r["intext_image"]["own"] is not None for r in rows),
            "changes_year": len(ch), "change_right": sum(r["intext_image"]["own"] == r["truth_y"] for r in ch),
            "change_wrong_to_right": sum(r["intext_image"]["own"] == r["truth_y"] and r["year"] != r["truth_y"]
                                         for r in ch),
            "change_right_to_wrong": sum(r["year"] == r["truth_y"] and r["intext_image"]["own"] != r["truth_y"]
                                         for r in ch),
            "stamp_dates": sum(r["intext_image"]["stamps"] > 0 for r in rows)}


def route_calls(rows):
    return {"trace": sum(1 for r in rows), "image": sum(1 for r in rows if r["image_sent"])}


def gemini_cost():
    """Mean cost and median seconds per call, trace and image, from every ledger row behind the replies used: this
    item's and the two reused ledgers (W46.date-image-paid, W46.date-undated)."""
    rows = ledger() + [r for r in ledger(CACHED_OWNER_IMAGE_LEDGER) if r["id"].startswith("image|o:")] + \
        [r for r in ledger(DU.CACHE / "calls.jsonl") if r["id"].startswith("image|")]
    out = {}
    for kind in ("trace-neigh", "image"):
        g = [r for r in rows if r["id"].startswith(kind + "|") and r.get("http") == 200]
        out[kind] = {"calls": len(g), "usd": round(statistics.mean(G.charge(r) for r in g), 6) if g else None,
                     "median_s": round(statistics.median(r["wall_s"] for r in g), 2) if g else None}
    out["item_spent"] = round(spent(), 4)
    out["billed_note"] = G.billed_note(ledger())
    return out


def per_1000(S, cost):
    """Cost and seconds per 1,000 documents of the owner's 300 mix: one trace call each, an image call where sent."""
    n = S["documents"] or 1
    c = S["calls"]
    tr, im = cost.get("trace-neigh") or {}, cost.get("image") or {}
    usd = (c["trace"] * (tr.get("usd") or 0) + c["image"] * (im.get("usd") or 0)) / n * 1000
    s = (c["trace"] * (tr.get("median_s") or 0) + c["image"] * (im.get("median_s") or 0)) / n * 1000
    return {"usd": round(usd, 2), "seconds": round(s), "image_share": round(c["image"] / n, 3)}


def cmd_score(a):
    ts = targets()
    gem_image = {}
    for d in ts:
        if d["set"] == "owner":
            gem_image[d["id"]] = load(image_dest(d))
    out = {"sets": dict(collections.Counter(d["set"] for d in ts)),
           "readable": dict(collections.Counter(d["set"] for d in ts if readable(d))), "models": {}}
    timing = ledger(CACHE / "timing.jsonl")
    out["vision"] = timing[-1] if timing else None
    for model in (GEMINI, QWEN):
        rows = score_model(model, ts, gem_image)
        if rows is None:
            continue
        S = summarise(model, rows, ts)
        if model == GEMINI:
            S["cost"] = gemini_cost()
            S["per_1000"] = per_1000(S, S["cost"])
        out["models"][model] = S
        with open(CACHE / f"rows-{model}.jsonl", "w", encoding="utf-8") as fh:
            fh.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    RESULTS_JSON.write_text(json.dumps(out, indent=1) + "\n")
    print(json.dumps({m: {"not_in_text": s["not_in_text"], "by_class": s["by_class"]} for m, s in out["models"].items()},
                     indent=1))
    print(f"-> {RESULTS_JSON}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sample")
    v = sub.add_parser("vision"); v.add_argument("--limit", type=int, default=0)
    r = sub.add_parser("run"); r.add_argument("--limit", type=int, default=0)
    e = sub.add_parser("export"); e.add_argument("--out", required=True)
    e.add_argument("--remote", default="$GROUP_HOME/$USER/archive-suite/date-route-pipeline")
    sub.add_parser("score")
    a = ap.parse_args()
    {"sample": cmd_sample, "vision": cmd_vision, "run": cmd_run, "export": cmd_export, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
