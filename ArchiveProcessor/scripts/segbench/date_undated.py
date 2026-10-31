#!/usr/bin/env python3
"""W46.date-undated: the app's false-year and Date Uncertain rates on undated documents (measurement audit DAT-6/DAT-7).

The app's tagging call (TagGenerator.generateTags, date_tagging.PROMPT verbatim) always gives a year; W41.date-tag-measure
scored it only on documents the owner dated. This sends it about 100 of the 425 agreed documents the owner left with no
date tag, and W46.date-image's 122 unprinted-year documents, on Apple Vision text read from the JPEG originals (no ABBYY
text, owner 2026-10-30), through the Stanford gateway (Gemini 3.7 Flash). Date Uncertain is scored against "a date is on
the document's own pages" from the image pass (date_image.PROMPT, images alone), not against the owner's tag: for the
122 the cached W46.date-image-paid replies, for the undated ones the same request sent here.

    <lab venv>/bin/python date_undated.py sample     # the two sets, their pages and the neighbours' -> CACHE (no call)
    <lab venv>/bin/python date_undated.py vision     # upright JPEG originals -> Apple Vision text (ocr.swift), resumable
    <lab venv>/bin/python date_undated.py run [--set S] [--rerun] [--limit N]   # the app call, the image pass (paid)
    <lab venv>/bin/python date_undated.py score      # segbench-results/date-undated.md and .json
    <lab venv>/bin/python date_undated.py sheet      # the blind owner sheet of page dates -> CACHE/sheet ($0, no call)

SHEET (W46.date-undated-sheet, measurement review 2026-10-31 R-1). The page-date truth above is the scored model's own
reading, so the owner rules on the 12 false-year documents and 8 controls where the app's year equals the page's: their
first DOC_PAGES pages re-rendered upright from the JPEG originals, every date-like string in Vision's text boxed on all
20 (word boxes from dewarp.swift `lines`; boxing only the controls' quoted dates would tell the groups apart), blind.
key.json beside index.html holds the groups; W46.date-undated-fold scores the exported answers.

<lab venv> is ~/.local/share/visionocr-ocrlab/venv (numpy and PIL for ocr_truth.orient_like_pdf, requests).

TEXT. As the app builds it from its own OCR: the document's page texts joined by a blank line (DocumentSegment
.combinedText), cut to 3,000 characters by build_prompt; context the first three of the three segments before and the
three after (date_tagging.document_pool's rule), each cut to 300. Every page's text is Vision's reading of its JPEG
original, confirmed and turned upright by ocr_truth.orient_like_pdf (date_image.MIN_CORR), at 2,400 px; a page with no
confirmed JPEG reads as empty and is counted. Only the first DOC_PAGES pages of a document and NEAR_PAGES of a
neighbour are read: the prompt keeps 3,000 and 300 characters.

THE CALL. The app's Gemini call sends no generationConfig and its OpenAI-compatible client sends no reasoning_effort
unless one is set, so the app call here sends neither temperature nor reasoning_effort: Gemini's defaults, as the app
gets them. max_tokens is set high only so reasoning cannot cut the answer off. `--rerun` sends the undated set a second
time (a separate cache) for the rerun floor, with the gateway's no-cache field (its response cache returned a
byte-identical copy of the first run otherwise; that copy is kept aside in CACHE/app-rerun-gateway-cached). The image
pass is sent as W46.date-image-paid sent it (temperature 0, reasoning low), so the two sets' page dates come from one
reader.

The gateway is real money on a Stanford PTA (root CLAUDE.md): spend is counted at gateway_gemini.PRICE (3.8's list
price, a ceiling) into CACHE/calls.jsonl before a reply is used, and CAP bounds the item. Replies, images and text stay
in the private bench cache. READ ONLY on the corpus and the JPEG originals. Run from scripts/segbench.
"""
from __future__ import annotations

import argparse
import base64
import collections
import hashlib
import json
import math
import os
import random
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import date_image as DI
import date_tagging as DT
import gateway_gemini as G

CACHE = Path(os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/date-undated"))
RESULTS = HERE.parent.parent / "segbench-results" / "date-undated.md"
RESULTS_JSON = RESULTS.with_suffix(".json")
SEED = 46
N_UNDATED = 100
DOC_PAGES, NEAR_PAGES = 4, 2
LONG_SIDE = 2400
CAP = 3.00            # the item's total; estimate about $1.60 with the rerun, under the $7 rule
APP_MAX_TOKENS = 8192
WORST_APP = (4000 * G.PRICE[0] + APP_MAX_TOKENS * G.PRICE[1]) / 1e6
DI_MAX = 4096         # date_image_gateway.MAX_TOKENS: 3.7 reasons first
WORST_IMAGE = (6000 * G.PRICE[0] + DI_MAX * G.PRICE[1]) / 1e6
CACHED_IMAGE_PASS = DI.PACK / "gateway" / "gemini3.7-flash-gw-2400"     # W46.date-image-paid's replies for the 122
_lock = threading.Lock()


# --- the sets ---------------------------------------------------------------------------------------------------

def jpeg_pairs():
    import corpus_pairs as CP
    pairs = {}
    for line in open(os.path.join(CP.CACHE, "pairs.tsv"), encoding="utf-8").read().splitlines()[1:]:
        pdf, jpeg, method = line.split("\t")[:3]
        if jpeg and method != "none":
            pairs[pdf] = jpeg
    return pairs


def cmd_sample(a):
    import corpus_pairs as CP
    import corpus_survey as CS
    pairs = jpeg_pairs()
    lab = {}
    for line in open(os.path.join(CP.CACHE, "labels.jsonl"), encoding="utf-8"):
        g = json.loads(line)
        lab[(g["folder_id"], g["n"])] = g
    folders = sorted({os.path.dirname(g["left"]) for g in lab.values()})
    dated = {r["doc"][2:]: r for r in DI.load_requests(DI.PACK) if r["variant"] == "image"}
    undated, found, counts = [], {}, collections.Counter()

    def record(segs, k, f):
        s = segs[k]
        near = (segs[max(0, k - 3):k] + segs[k + 1:k + 4])[:3]
        return {"id": hashlib.sha1(s["pages"][0].encode()).hexdigest()[:16], "collection": CP.collection_of(f),
                "folder": f, "position": k, "pages": s["pages"], "near": [n["pages"] for n in near]}

    for f in folders:
        segs = DT.folder_documents(f, lab)
        for k, s in enumerate(segs):
            if s["kind"] != "doc" or not s["agreed"]:
                continue
            i = hashlib.sha1(s["pages"][0].encode()).hexdigest()[:16]
            if i in dated:
                found[i] = record(segs, k, f)
                continue
            cls, _ = DT.truth_of(CS.read_tags(os.path.join(CS.CORPUS, s["pages"][0])))
            if cls != "undated":
                continue
            counts["undated agreed"] += 1
            if s["pages"][0] not in pairs:
                counts["undated, first page has no JPEG paired"] += 1
                continue
            undated.append(record(segs, k, f))
    # Round-robin across collections, as date_tagging's sample: no document is chosen by its text or a route's reply.
    rng = random.Random(SEED)
    by_col = collections.defaultdict(list)
    for d in undated:
        by_col[d["collection"]].append(d)
    cols = sorted(by_col)
    rng.shuffle(cols)
    for c in cols:
        rng.shuffle(by_col[c])
    got = []
    while len(got) < N_UNDATED and any(by_col[c] for c in cols):
        for c in cols:
            if by_col[c] and len(got) < N_UNDATED:
                got.append(by_col[c].pop())
    out = [{**d, "set": "undated"} for d in got]
    for i, r in sorted(dated.items()):
        if i in found:
            out.append({**found[i], "set": "dated", "cls": r["cls"], "truth": r["truth"], "image_request": r["id"]})
        else:
            counts["dated, not located"] += 1
    counts.update({"undated sampled": len(got), "undated collections": len({d["collection"] for d in got}),
                   "undated candidates": len(undated), "dated": sum(d["set"] == "dated" for d in out)})
    CACHE.mkdir(parents=True, exist_ok=True)
    with open(CACHE / "targets.jsonl", "w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(d, ensure_ascii=False) + "\n" for d in out)
    (CACHE / "sample.json").write_text(json.dumps(dict(sorted(counts.items())), indent=1) + "\n")
    print(json.dumps(dict(sorted(counts.items())), indent=1))


def targets():
    return [json.loads(l) for l in open(CACHE / "targets.jsonl", encoding="utf-8")]


# --- Vision text of the JPEG originals --------------------------------------------------------------------------

def page_files(page):
    h = hashlib.sha1(page.encode()).hexdigest()
    return CACHE / "img" / (h + ".jpg"), CACHE / "txt" / (h + ".txt")


def pages_to_read(ts):
    want = []
    for d in ts:
        want += d["pages"][:DOC_PAGES]
        for n in d["near"]:
            want += n[:NEAR_PAGES]
    return list(dict.fromkeys(want))


def cmd_vision(a):
    """Each page's JPEG original, confirmed against its PDF and turned upright (orient.json keeps the verdict), then
    read by segbench's ocr.swift (the app's Vision settings). Resumable."""
    import tempfile
    from PIL import Image
    import corpus_survey as CS
    import data as D
    import corpus_pairs as CP
    import ocr_truth as OT
    pairs = jpeg_pairs()
    pages = pages_to_read(targets())
    for sub in ("img", "txt", "tmp"):
        (CACHE / sub).mkdir(parents=True, exist_ok=True)
    op = CACHE / "orient.json"
    orient = json.loads(op.read_text()) if op.exists() else {}
    tmp = Path(tempfile.mkdtemp(dir=CACHE / "tmp"))
    for k, p in enumerate(pages, 1):
        img, _ = page_files(p)
        if p in orient:
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
                        im.thumbnail((LONG_SIDE, LONG_SIDE), Image.Resampling.LANCZOS)
                        im.save(img, "JPEG", quality=90)
                        orient[p] = {"deg": deg, "corr": round(corr, 3)}
            except Exception as e:
                orient[p] = {"why": "comparison failed", "error": type(e).__name__}
        if k % 50 == 0:
            op.write_text(json.dumps(orient))
            print(f"oriented {k}/{len(pages)}", flush=True)
    op.write_text(json.dumps(orient))
    tool = D.build_ocr_tool()
    if tool is None:
        raise SystemExit("ocr.swift did not compile")
    jobs = CACHE / "jobs.tsv"
    with open(jobs, "w", encoding="utf-8") as fh:
        for p in pages:
            img, txt = page_files(p)
            if img.exists() and not txt.exists():
                fh.write(f"{img}\t{txt}\n")
    subprocess.run([str(tool), str(jobs)], check=False)
    print(f"{sum(page_files(p)[1].exists() for p in pages)} of {len(pages)} pages have Vision text; "
          f"{dict(collections.Counter(v.get('why', 'ok') for v in orient.values()))}")


def text_of(pages, n):
    """The segment's Vision text as combinedText joins it, and how many of its first n pages had none."""
    out, missing = [], 0
    for p in pages[:n]:
        t = page_files(p)[1]
        if t.exists():
            out.append(t.read_text(encoding="utf-8"))
        else:
            out.append(""); missing += 1
    return "\n\n".join(out), missing


def readable(d):
    """The document's first page has a confirmed JPEG original, so Vision read it (the others are left out of the
    undated set and counted: the app would have its own photo; the bench has no confirmed one)."""
    return page_files(d["pages"][0])[1].exists()


def prompt_of(d):
    text, missing = text_of(d["pages"], DOC_PAGES)
    context = "\n---\n".join(text_of(n, NEAR_PAGES)[0][:300] for n in d["near"])
    return DT.build_prompt(text, context), text, missing


# --- the gateway ------------------------------------------------------------------------------------------------

def ledger():
    p = CACHE / "calls.jsonl"
    return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []


def spent():
    return sum(r.get("cost", 0) for r in ledger())


def app_body(prompt, rerun=False):
    """The app's request. A rerun carries LiteLLM's no-cache field: the gateway answers a byte-identical request from
    its response cache (W46.ocr-rerun-noise), and the field never reaches the model."""
    b = {"model": G.MODEL, "max_tokens": APP_MAX_TOKENS, "messages": [{"role": "user", "content": prompt}]}
    if rerun:
        b["cache"] = {"no-cache": True}
    return b


def image_body(images):
    content = [{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(b).decode()}}
               for b in images]
    return {"model": G.MODEL, "temperature": 0, "max_tokens": DI_MAX, "reasoning_effort": "low",
            "messages": [{"role": "user", "content": content + [{"type": "text", "text": DI.PROMPT}]}]}


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
    with _lock:
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


def app_dest(d, rerun=False):
    return CACHE / ("app-rerun" if rerun else "app") / (d["id"] + ".json")


def image_dest(d):
    if d["set"] == "dated":
        return CACHED_IMAGE_PASS / (d["image_request"] + ".json")
    return CACHE / "image" / (d["id"] + ".json")


def cmd_run(a):
    ts = [d for d in targets() if a.set in (None, d["set"])]
    jobs = []
    for d in ts:
        if (a.rerun and d["set"] != "undated") or (d["set"] == "undated" and not readable(d)):
            continue
        prompt = prompt_of(d)[0]
        jobs.append((d["id"], app_body(prompt, a.rerun), WORST_APP, app_dest(d, a.rerun)))
        if not a.rerun and d["set"] == "undated":
            imgs = [page_files(p)[0] for p in d["pages"][:DI.PAGES]]
            imgs = [i.read_bytes() for i in imgs if i.exists()]
            if imgs:
                jobs.append(("image|" + d["id"], image_body(imgs), WORST_IMAGE, image_dest(d)))
    jobs = [j for j in jobs if not j[3].exists()][: a.limit or None]
    print(f"{len(jobs)} requests to send; ${spent():.4f} spent so far", flush=True)
    with ThreadPoolExecutor(4) as ex:
        res = list(ex.map(lambda j: call(*j), jobs))
    print(f"{sum(bool(r.get('text')) for r in res)}/{len(res)} answered, ${spent():.4f} spent in all", flush=True)


# --- scoring ----------------------------------------------------------------------------------------------------

def app_reply(dest):
    """date_tagging.app_parse on a gateway reply: (year int or None, month, uncertain, parsed); None if not sent."""
    if not dest.exists():
        return None
    raw = json.loads(dest.read_text()).get("text")
    year, month, du, ok = DT.app_parse({"candidates": [{"content": {"parts": [{"text": raw or ""}]}}]})
    y = int(year) if year and year.isdigit() and len(year) == 4 else None
    return {"y": y, "m": month, "du": du, "parsed": ok}


def own_date(rec):
    """The image pass's reading: (parsed, the document's own year when the reply gives one AND that year is written in
    one of the dates it quoted, every written year). A year the reader supplied but did not quote does not count."""
    r = DI.read(rec)
    written = sorted({x["year"] for x in r["dates"] if x["written"]})
    own = r["doc_year"] if r["doc_year"] is not None and r["doc_year"] in written else None
    return r["ok"], own, written


def wilson(k, n, z=1.96):
    if not n:
        return (0.0, 0.0)
    p = k / n
    c = (p + z * z / (2 * n)) / (1 + z * z / n)
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return (max(0.0, c - h), min(1.0, c + h))


def pct(k, n):
    if not n:
        return "–"
    lo, hi = wilson(k, n)
    return f"{100 * k / n:.0f}% ({k}/{n}; {100 * lo:.0f}-{100 * hi:.0f})"


def rows():
    out = []
    for d in targets():
        _, text, missing = prompt_of(d)
        rec = json.loads(image_dest(d).read_text()) if image_dest(d).exists() else None
        ok, own, written = own_date(rec) if rec else (False, None, [])
        out.append({**d, "app": app_reply(app_dest(d)), "rerun": app_reply(app_dest(d, True)), "image_ok": ok,
                    "own": own, "written": written, "chars": len(text), "missing_pages": missing,
                    "own_in_vision": own is not None and str(own) in text[:3000]})
    return out


def pool_weighted():
    """W41.date-tag-measure's year figures weighted to the pool (date_tagging.py score writes them), and pooled."""
    j = json.load(open(DT.RESULTS_JSON))
    pw = dict(j["pool_weighted"])
    for m in ("exact", "within1"):
        k, n = j["year"]["all"][m]
        pw[m + "_pooled"] = round(100 * k / n, 1)
    return pw


def cmd_score(a):
    rs = rows()
    smp = json.loads((CACHE / "sample.json").read_text())
    und = [r for r in rs if r["set"] == "undated" and r["app"] and readable(r)]
    unread = sum(r["set"] == "undated" and not readable(r) for r in rs)
    dat = [r for r in rs if r["set"] == "dated" and r["app"]]
    usd = spent()
    calls = ledger()
    L = ["# Dating undated documents: the app's false years and Date Uncertain (W46.date-undated)", "",
         "Written by `scripts/segbench/date_undated.py score`. Measurement audit DAT-6 and DAT-7 "
         "(`execution-plans/processing-review/11-measurement-audit.md`). The app's tagging call (`TagGenerator.generateTags`, "
         "the prompt verbatim) always gives a year; W41.date-tag-measure scored it only where the owner had dated the "
         "document. Here it reads documents the owner left with no date tag, and W46.date-image's unprinted-year "
         "documents, on Apple Vision's reading of the JPEG originals (no ABBYY text), with the app's context of three "
         "neighbouring segments, through the Stanford gateway (Gemini 3.7 Flash; the app's default is 3.8, which the "
         "gateway does not serve), with no temperature or reasoning setting, as the app sends it.", "",
         "**A date on the document's own pages** is the image pass's reading (`date_image.py`'s prompt, the JPEG "
         "originals' first two pages, images alone, Gemini 3.7 Flash at temperature 0, reasoning low): the reply names "
         "the document's own date, and its year is written in one of the dates it quoted. For the dated set these are "
         "W46.date-image-paid's cached replies; for the undated set the same request was sent here.", ""]
    # Undated.
    certain = [r for r in und if not r["app"]["du"]]
    with_own = [r for r in und if r["own"] is not None]
    no_own = [r for r in und if r["own"] is None and r["image_ok"]]
    false_year = [r for r in und if not r["app"]["du"] and (r["own"] is None or r["app"]["y"] != r["own"])]
    L += ["## Undated documents", "",
          f"{smp.get('undated agreed', 0)} agreed documents carry no date tag at all"
          + (f"; {smp['undated, first page has no JPEG paired']} of them have no JPEG original paired to their first "
             "page and were left out" if smp.get("undated, first page has no JPEG paired") else
             ", every one with a JPEG original paired to its first page")
          + f". {smp.get('undated sampled', 0)} were drawn round-robin across "
          f"{smp.get('undated collections', 0)} collections (seed {SEED}). {unread} of those have no JPEG original confirmed "
          f"as their first page's photo (ocr_truth.orient_like_pdf below {DI.MIN_CORR}), so Vision has nothing to read "
          f"and they are left out; {len(und)} answered.", "",
          "| measure | documents |", "|---|---:|",
          f"| the reply gives a year | {pct(sum(r['app']['y'] is not None for r in und), len(und))} |",
          f"| the app writes Date Uncertain | {pct(sum(r['app']['du'] for r in und), len(und))} |",
          f"| the app writes a year without Date Uncertain | {pct(len(certain), len(und))} |",
          f"| the image pass finds the document's own date on its pages | {pct(len(with_own), len(und))} |",
          f"| **false year**: a year without Date Uncertain, and no own date on the pages or a different one | "
          f"{pct(len(false_year), len(und))} |", ""]
    if with_own:
        L += [f"Where the image pass found the document's own date on the page ({len(with_own)}), the owner left "
              f"it untagged; there the app's year equals the page's for "
              f"{pct(sum(r['app']['y'] == r['own'] for r in with_own), len(with_own))}, and the app writes Date Uncertain "
              f"for {pct(sum(r['app']['du'] for r in with_own), len(with_own))}. The page's year is in Vision's text "
              f"for {sum(r['own_in_vision'] for r in with_own)} of them.", ""]
    if no_own:
        L += [f"Where it found none ({len(no_own)}), the app writes Date Uncertain for "
              f"{pct(sum(r['app']['du'] for r in no_own), len(no_own))}; the rest is a confident year the pages do not "
              "carry.", ""]
    # Dated set: Date Uncertain against a date on the page.
    L += ["## Date Uncertain against a date on the document's own pages", "",
          "The prompt's test for `date_uncertain` is whether the year can be determined from the document itself. "
          "Scored here against the image pass, not the owner's tag (the owner knows the box; DAT-7).", "",
          "| set | own date on the pages | documents | app writes Date Uncertain | app's year equals the page's |",
          "|---|---|---:|---:|---:|"]
    du_json = {}
    for name, rs_ in (("undated", und), ("dated (unprinted-year)", dat)):
        for has in (True, False):
            s = [r for r in rs_ if (r["own"] is not None) == has and r["image_ok"]]
            du_json[f"{name.split()[0]}|{'yes' if has else 'no'}"] = [sum(r["app"]["du"] for r in s), len(s)]
            same = pct(sum(r["app"]["y"] == r["own"] for r in s), len(s)) if has else "–"
            L.append(f"| {name} | {'yes' if has else 'no'} | {len(s)} | {pct(sum(r['app']['du'] for r in s), len(s))} | {same} |")
    both = [r for r in und + dat if r["image_ok"]]
    agree = sum(r["app"]["du"] == (r["own"] is None) for r in both)
    L += ["", f"Agreement of Date Uncertain with \"no own date on the pages\", both sets: {pct(agree, len(both))}. "
          f"The dated set is W46.date-image's: documents whose owner year is not in the ABBYY text (that is how they "
          "were chosen; ABBYY text is not sent).", ""]
    # Dated set: year against the owner.
    L += ["## The dated set's years, on Vision text", "",
          f"The same {len(dat)} documents, the app's year against the owner's tag, by W46.date-image's classes "
          "(D has no printed carrier near it).", "",
          "| class | documents | year exact | within one | Date Uncertain |", "|---|---:|---:|---:|---:|"]
    for cls in DI.CLASSES + ("all",):
        s = [r for r in dat if cls in ("all", r["cls"])]
        L.append(f"| {cls} | {len(s)} | {pct(sum(r['app']['y'] == r['truth']['year'] for r in s), len(s))} | "
                 f"{pct(sum(r['app']['y'] is not None and abs(r['app']['y'] - r['truth']['year']) <= 1 for r in s), len(s))} | "
                 f"{pct(sum(r['app']['du'] for r in s), len(s))} |")
    # Rerun.
    pairs = [r for r in und if r["rerun"]]
    L += ["", "## Rerun", "",
          f"The undated set sent a second time ({len(pairs)} answered both times), at the app's default sampling, with "
          "the gateway's no-cache field (without it the gateway returned the first run's replies byte for byte): "
          f"the same year {pct(sum(r['app']['y'] == r['rerun']['y'] for r in pairs), len(pairs))}, the same Date "
          f"Uncertain {pct(sum(r['app']['du'] == r['rerun']['du'] for r in pairs), len(pairs))}; false year in the "
          f"rerun {pct(sum(not r['rerun']['du'] and (r['own'] is None or r['rerun']['y'] != r['own']) for r in pairs), len(pairs))}.", ""]
    pw = pool_weighted()
    L += ["## W41.date-tag-measure, weighted to the pool", "",
          f"Its year figures were pooled over a 120/80/50 sample; weighted to the pool's agreed counts "
          f"({pw['weights']['year+month']:,} year+month, {pw['weights']['year']:,} year, {pw['weights']['year+DU']} year+DU) "
          f"they are {pw['exact']}% exact (pooled {pw['exact_pooled']}%) and {pw['within1']}% within one (pooled "
          f"{pw['within1_pooled']}%). Per stratum: `date-tagging.md`. Those were ABBYY text and Gemini 3.8 direct.", ""]
    # Card.
    vis_short = sum(r["missing_pages"] > 0 for r in und + dat)
    L += ["## Measurement card", "",
          "- **Truth.** Undated: the owner's tags carry no date (truth that the owner could not or did not date it, not "
          "that no date exists). \"Own date on the pages\": Gemini 3.7 Flash's image pass, the same model family as the "
          "route scored, so the Date Uncertain agreement is relative to a Gemini reader, not to a human; the owner "
          "checked none of these. Dated set: the owner's year tag.",
          f"- **Selection.** Undated: round-robin across collections, seed {SEED}, among those whose first page has a "
          "paired JPEG; never by a route's reply or the ABBYY text. Dated: W46.date-image's 122, chosen as owner years "
          "not in the ABBYY text.",
          f"- **Comparison.** One route, one prompt, one text source (Vision on the JPEG originals at {LONG_SIDE:,} px). "
          f"{vis_short} documents had a page without a confirmed JPEG, read as empty. Not compared with ABBYY-text runs "
          "(different model version and text).",
          f"- **Noise.** n as given, Wilson 95% intervals in brackets; the rerun section is the floor between two "
          "identical runs. A gap inside it is a tie.",
          "- **Scope.** It does not say how often a date is truly on an undated document's pages (a Gemini reading), "
          "nor how the app would do with 3.8 or its own OCR's settings beyond Vision's defaults.", "",
          "## Cost", "",
          f"{len(calls)} gateway calls, {sum((c.get('usage') or {}).get('prompt_tokens', 0) for c in calls):,} input "
          f"and {sum((c.get('usage') or {}).get('completion_tokens', 0) for c in calls):,} output tokens: about "
          f"${usd:.2f} at 3.8 Flash's list price taken as a ceiling (the gateway returns no price), plus the 122 cached "
          "image replies of W46.date-image-paid.", ""]
    RESULTS.write_text("\n".join(L))
    out = {"model": G.MODEL, "usd": round(usd, 2), "undated": {
        "n": len(und), "du": [sum(r["app"]["du"] for r in und), len(und)],
        "certain_year": [len(certain), len(und)], "false_year": [len(false_year), len(und)],
        "own_date": [len(with_own), len(und)]}, "du_by_own_date": du_json,
        "du_agrees_own_date": [agree, len(both)],
        "dated_year_exact": [sum(r["app"]["y"] == r["truth"]["year"] for r in dat), len(dat)],
        "rerun_same_year": [sum(r["app"]["y"] == r["rerun"]["y"] for r in pairs), len(pairs)],
        "rerun_same_du": [sum(r["app"]["du"] == r["rerun"]["du"] for r in pairs), len(pairs)],
        "pool_weighted": pw}
    RESULTS_JSON.write_text(json.dumps(out, indent=1) + "\n")
    print("\n".join(L))


# --- the blind owner sheet (W46.date-undated-sheet) -------------------------------------------------------------

SHEET = CACHE / "sheet"
N_CONTROLS = 8
SHEET_SEED = 4631
DEWARP_BIN = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/segbench/bin/segbench-dewarp"
_MONTH = (r"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sept?(?:ember)?|"
          r"Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)")
_FULL_MONTH = r"(?:January|February|March|April|June|July|August|September|October|November|December)"
DATE_LIKE = [
    r"\b(?:1[89]\d\d|20[0-2]\d)\b",                                            # a year
    r"\b\d{1,2}\s*[/.-]\s*\d{1,2}\s*[/.-]\s*\d{2,4}\b",                         # 5/12/67, 12.5.1967
    r"[’'‘]\d\d\b",                                                             # '67
    _MONTH + r"\.?\s+\d{1,2}(?:st|nd|rd|th)?\b,?(?:\s+[’'‘]?\d{2,4}\b)?",       # May 12, 1967
    r"\b\d{1,2}(?:st|nd|rd|th)?\s+" + _MONTH + r"\b\.?(?:,?\s+[’'‘]?\d{2,4}\b)?",  # 12 May 1967
    _MONTH + r"\.?,?\s+[’'‘]?\d{2,4}\b",                                        # Dec. 1967
    r"\b" + _FULL_MONTH + r"\b",                                                # a month alone, written in full
]


def date_spans(text):
    """Character spans of every date-like string in one line, overlapping matches merged. Deliberately loose: the
    sheet boxes what might be a date and the owner judges it; over-boxing is the same on every document."""
    import re
    spans = sorted((m.start(), m.end()) for pat in DATE_LIKE for m in re.finditer(pat, text))
    out = []
    for s, e in spans:
        if out and s <= out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [tuple(x) for x in out]


def _bbox(quad):
    xs, ys = [p[0] for p in quad], [p[1] for p in quad]
    return [min(xs), min(ys), max(xs), max(ys)]


def date_boxes(lines_json):
    """[{text, box: [x, y, w, h]}] in the image's normalised coordinates (top-left origin) for every date-like string
    in segbench-dewarp's `lines` output: the union of the Vision word boxes the string overlaps, the line's own box
    when no word box falls on it."""
    out = []
    for ln in lines_json.get("lines", []):
        text = ln["text"]
        spans = date_spans(text)
        if not spans:
            continue
        placed, cur = [], 0
        for w in ln.get("words", []):
            i = text.find(w["text"], cur)
            if i < 0:
                continue
            placed.append((i, i + len(w["text"]), _bbox(w["quad"])))
            cur = i + len(w["text"])
        for s, e in spans:
            hit = [b for ws, we, b in placed if ws < e and we > s]
            if hit:
                x0, y0 = min(b[0] for b in hit), min(b[1] for b in hit)
                x1, y1 = max(b[2] for b in hit), max(b[3] for b in hit)
            else:
                x0, y0, x1, y1 = _bbox(ln["quad"])
            out.append({"text": text[s:e], "box": [round(x0, 4), round(y0, 4), round(x1 - x0, 4), round(y1 - y0, 4)]})
    return out


def sheet_documents(rs):
    """The false-year documents (as cmd_score counts them) and N_CONTROLS drawn with a fixed seed from those where the
    app's year equals the page's, shuffled together so the order tells nothing. [(document, group)]."""
    und = [r for r in rs if r["set"] == "undated" and r["app"] and readable(r)]
    false_year = [r for r in und if not r["app"]["du"] and (r["own"] is None or r["app"]["y"] != r["own"])]
    same = sorted((r for r in und if r["own"] is not None and r["app"]["y"] == r["own"]), key=lambda r: r["id"])
    rng = random.Random(SHEET_SEED)
    docs = [(r, "false year") for r in false_year] + [(r, "control") for r in rng.sample(same, min(N_CONTROLS, len(same)))]
    docs.sort(key=lambda x: x[0]["id"])
    rng.shuffle(docs)
    return docs, len(false_year), len(same)


def build_dewarp_tool():
    src = HERE / "dewarp.swift"
    if not (DEWARP_BIN.exists() and DEWARP_BIN.stat().st_mtime >= src.stat().st_mtime):
        DEWARP_BIN.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["/usr/bin/swiftc", "-O", str(src), "-o", str(DEWARP_BIN)], check=True)
    return DEWARP_BIN


def cmd_sheet(a):
    """$0, no model call. The 12 false-year documents and 8 controls, each with its first DOC_PAGES pages re-rendered
    upright from the JPEG originals (orient.json's verdict, as cmd_vision made them), every date-like string in Vision's
    text boxed from segbench-dewarp's word boxes, blind: no app year, no image-pass reading, no group. The key goes
    beside the sheet. READ ONLY on the JPEG originals."""
    from PIL import Image
    import corpus_pairs as CP
    pairs = jpeg_pairs()
    orient = json.loads((CACHE / "orient.json").read_text())
    docs, n_false, n_same = sheet_documents(rows())
    for sub in ("img", "lines"):
        (SHEET / sub).mkdir(parents=True, exist_ok=True)
    plan, jobs = [], []
    for k, (d, group) in enumerate(docs, 1):
        name = f"D{k:02d}"
        pages = []
        for n, p in enumerate(d["pages"][:DOC_PAGES], 1):
            o = orient.get(p, {})
            img, lj = SHEET / "img" / f"{name}-{n}.jpg", SHEET / "lines" / f"{name}-{n}.json"
            if "deg" in o and p in pairs:
                if not img.exists():
                    with Image.open(os.path.join(CP.JPEGS, pairs[p])) as im:
                        im = im.convert("RGB").rotate(o["deg"], expand=True)
                        im.thumbnail((LONG_SIDE, LONG_SIDE), Image.Resampling.LANCZOS)
                        im.save(img, "JPEG", quality=90)
                jobs.append(f"{img}\t{lj}\n")
                pages.append({"page": p, "img": img, "lines": lj})
            else:
                pages.append({"page": p, "img": None, "why": o.get("why", "no JPEG paired")})
        plan.append((name, d, group, pages))
    (SHEET / "lines-jobs.tsv").write_text("".join(jobs))
    subprocess.run([str(build_dewarp_tool()), "lines", str(SHEET / "lines-jobs.tsv")], check=True)
    data, key = [], {}
    for name, d, group, pages in plan:
        shown = []
        for pg in pages:
            if pg["img"] is None:
                shown.append({"img": None, "file": os.path.basename(pg["page"]), "why": pg["why"], "boxes": []})
                continue
            lj = json.loads(pg["lines"].read_text())
            shown.append({"img": f"img/{pg['img'].name}", "boxes": [b["box"] for b in date_boxes(lj)],
                          "aspect": lj["height"] / lj["width"]})
        data.append({"doc": name, "pages_total": len(d["pages"]), "pages": shown})
        key[name] = {"id": d["id"], "group": group, "folder": d["folder"], "pages": d["pages"][:DOC_PAGES],
                     "app_year": d["app"]["y"], "app_date_uncertain": d["app"]["du"], "pass_own_year": d["own"],
                     "pass_written_years": d["written"]}
    minutes = max(1, round(0.5 * len(data)))
    (SHEET / "index.html").write_text(SHEET_HTML.replace("__DATA__", json.dumps(data, ensure_ascii=False))
                                      .replace("__N__", str(len(data))).replace("__MINUTES__", str(minutes)))
    (SHEET / "key.json").write_text(json.dumps({
        "item": "W46.date-undated-sheet", "seed": SHEET_SEED, "false_year": n_false, "control_pool": n_same,
        "controls": sum(v["group"] == "control" for v in key.values()), "documents": key}, indent=1))
    boxed = sum(bool(p["boxes"]) for x in data for p in x["pages"])
    no_box = [x["doc"] for x in data if not any(p["boxes"] for p in x["pages"])]
    size = sum(f.stat().st_size for f in SHEET.rglob("*") if f.is_file())
    print(f"{len(data)} documents ({n_false} false year, {len(data) - n_false} controls of {n_same}), "
          f"{sum(len(x['pages']) for x in data)} pages, {boxed} with a box; no date-like string on {no_box or 'none'}; "
          f"{size / 1e6:.1f} MB; about {minutes} minutes -> {SHEET / 'index.html'}")


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>W46 page dates, blind</title>
<style>
body{font:14px -apple-system,sans-serif;margin:0;background:#fff;color:#111;color-scheme:light}
header{position:sticky;top:0;background:#fff;border-bottom:1px solid #ccc;padding:6px 12px;z-index:2}
.doc{display:flex;gap:12px;border-bottom:3px solid #999;padding:10px}
.imgs{flex:1 1 65%}.q{flex:1 1 35%;position:sticky;top:var(--head,60px);align-self:flex-start}
.frame{position:relative;width:100%;margin-bottom:8px;cursor:zoom-in}.frame.zoom{width:220%;cursor:zoom-out}
.frame img{width:100%;display:block}.wrap{overflow:auto;max-height:calc(100vh - var(--head,60px) - 20px)}
.box{position:absolute;border:3px solid #f0a;border-radius:4px;pointer-events:none}
.none{color:#a40;font-size:13px}.missing{border:1px dashed #a40;padding:20px;color:#a40;margin-bottom:8px}
.done{background:#e6f6e6}label{display:block;margin:4px 0}input[type=text]{width:8em}textarea{width:95%;height:3em}
</style>
<header><b>Page dates, blind</b> — __N__ documents, about __MINUTES__ minutes. For each document: <b>is a date
written or printed on the document's own pages, and which year?</b> Not when you know the document is from, only what
the pages carry. Pink boxes mark every date-like string Apple Vision read on the page (a year, a numeric date, a month
with a number); a box can be a false alarm and Vision can miss a date, so look at the whole page. Click a page to zoom.
Answers stay in this browser; <button onclick="exportAnswers()">Export answers</button><span id="prog"></span></header>
<div id="root"></div>
<script>
const DATA=__DATA__;const KEY='w46-date-undated-sheet';
let A=JSON.parse(localStorage.getItem(KEY)||'{}');
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function save(){localStorage.setItem(KEY,JSON.stringify(A));prog()}
function prog(){const d=DATA.filter(x=>(A[x.doc]||{}).date).length;document.getElementById('prog').textContent=` ${d} / ${DATA.length} answered`;
 DATA.forEach(x=>document.getElementById(x.doc).classList.toggle('done',!!(A[x.doc]||{}).date))}
const root=document.getElementById('root');
for(const x of DATA){const div=document.createElement('div');div.className='doc';div.id=x.doc;
 let h='<div class="imgs">';
 x.pages.forEach((p,i)=>{
  if(!p.img){h+=`<div class="missing">Page ${i+1}: no photograph to show (${esc(p.why)}; file ${esc(p.file)}).</div>`;return}
  h+=`<div class="wrap"><div class="frame"><img src="${p.img}" alt="${x.doc} page ${i+1}">`+
   p.boxes.map(b=>`<div class="box" style="left:${100*b[0]-.6}%;top:${100*(b[1]-.006/p.aspect)}%;width:${100*b[2]+1.2}%;height:${100*(b[3]+.012/p.aspect)}%"></div>`).join('')+
   '</div></div>'});
 const any=x.pages.some(p=>p.boxes.length);
 h+='</div><div class="q"><b>'+x.doc+'</b>'+(x.pages_total>x.pages.length?` (pages 1-${x.pages.length} of ${x.pages_total})`:'')+
  (any?'':'<p class="none">Vision read no date-like string on these pages, so nothing is boxed.</p>')+
  '<p>Is a date written or printed on the document\'s own pages?</p>'+
  ['yes','no','cannot tell'].map(v=>`<label><input type="radio" name="${x.doc}" value="${v}"> ${v}</label>`).join('')+
  '<p>Which year does it give? <input type="text" data-f="year" placeholder="e.g. 1967"></p>'+
  '<p>Note (optional, e.g. "only the month", "year partly torn off"):<br><textarea data-f="note"></textarea></p></div>';
 div.innerHTML=h;root.appendChild(div);
 const a=A[x.doc]||{};
 div.querySelectorAll('input[type=radio]').forEach(r=>{r.checked=a.date===r.value;r.onchange=()=>{(A[x.doc]=A[x.doc]||{}).date=r.value;save()}});
 div.querySelectorAll('[data-f]').forEach(f=>{f.value=a[f.dataset.f]||'';f.oninput=()=>{(A[x.doc]=A[x.doc]||{})[f.dataset.f]=f.value;save()}});
 div.querySelectorAll('.frame').forEach(f=>f.onclick=()=>f.classList.toggle('zoom'))}
function head(){document.documentElement.style.setProperty('--head',document.querySelector('header').offsetHeight+'px')}
addEventListener('resize',head);head();
function exportAnswers(){const b=new Blob([JSON.stringify(A,null,1)],{type:'application/json'});
 const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='date-undated-sheet-answers.json';a.click()}
prog();
</script>"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sample")
    sub.add_parser("vision")
    p = sub.add_parser("run"); p.add_argument("--set", choices=("undated", "dated"))
    p.add_argument("--rerun", action="store_true"); p.add_argument("--limit", type=int)
    sub.add_parser("score")
    sub.add_parser("sheet")
    a = ap.parse_args()
    {"sample": cmd_sample, "vision": cmd_vision, "run": cmd_run, "score": cmd_score, "sheet": cmd_sheet}[a.cmd](a)


if __name__ == "__main__":
    main()
