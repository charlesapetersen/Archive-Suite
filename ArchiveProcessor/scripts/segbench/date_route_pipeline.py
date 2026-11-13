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
    python3 date_route_pipeline.py rerender / check  # rebuild img/ from orient.json; requests against the 3.7 hashes
    python3 date_route_pipeline.py run38 [--limit N] # step 2 on Gemini 3.8, direct key (paid, CAP38; -pipeline-38)
    python3 date_route_pipeline.py export --out DIR [--remote R]   # the same requests for the 27B on Sherlock
    python3 date_route_pipeline.py pack --src DIR    # the export as a frozen Sherlock pack (sherlock/date-route-27b/)
    python3 date_route_pipeline.py collect           # the pack's returned answers -> CACHE/answers-27b.jsonl
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
# W46.date-route-pipeline-38: the image pass on a direct Gemini key (3.8; real money on the owner's key).
GEMINI38 = "gemini3.8-flash-direct-image"
DIRECT_MODEL = DT.MODEL                     # gemini-3.8-flash, the app's default
LEDGER38 = CACHE / "calls-38.jsonl"
CAP38 = 1.50          # the item's total; estimate about $0.55 (about 180 image replies at $0.003)
WORST_IMAGE_38 = (6000 * DT.PRICE_IN + DU.DI_MAX * DT.PRICE_OUT) / 1e6
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


# --- the image pass on Gemini 3.8, direct key (W46.date-route-pipeline-38) --------------------------------------
# The gateway serves only 3.7, so step 2 on a direct Gemini key (the app's default, 3.8) had no row (P7-4). The same
# images and prompt as date_undated.image_body, on the Gemini API's own request (what the app's direct-key client
# sends): temperature 0, thinkingLevel low, 4,096 output tokens. Steps 1 and 4 keep the gateway's 3.7 trace replies,
# so the row differs from Gemini 3.7's in the image pass alone.

def image_body_38(images):
    import base64
    parts = [{"inline_data": {"mime_type": "image/jpeg", "data": base64.b64encode(b).decode()}} for b in images]
    return {"contents": [{"role": "user", "parts": parts + [{"text": DI.PROMPT}]}],
            "generationConfig": {"temperature": 0, "maxOutputTokens": DU.DI_MAX,
                                 "thinkingConfig": {"thinkingLevel": "low"}}}


def image38_dest(d):
    return CACHE / "image-38" / (d["id"].replace(":", "_") + ".json")


def spent38():
    return sum(r.get("cost") or 0 for r in ledger(LEDGER38))


def cost38(u):
    """Thinking is billed as output (date_tagging.PRICE_IN/OUT, 3.8 Flash's list price)."""
    return ((u.get("promptTokenCount") or 0) * DT.PRICE_IN +
            ((u.get("candidatesTokenCount") or 0) + (u.get("thoughtsTokenCount") or 0)) * DT.PRICE_OUT) / 1e6


_key = []


def direct_key():
    """The Processor's Gemini key, read once from the Keychain into memory (method_gemini.api_key's lookup, without its
    imports). Never printed or written."""
    with _lock:
        if not _key:
            r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "com.archiveprocessor.app", "-a",
                                "Gemini", "-w"], capture_output=True, text=True, timeout=30)
            if r.returncode != 0 or not r.stdout.strip():
                raise SystemExit("no Gemini key in the Keychain (com.archiveprocessor.app / Gemini)")
            _key.append(r.stdout.strip())
        return _key[0]


def call38(key, b, dest: Path):
    """One direct-key reply, cached by destination; the ledger line is written before the reply is used."""
    if dest.exists():
        return json.loads(dest.read_text())
    import requests
    with _lock:
        if spent38() + WORST_IMAGE_38 > CAP38:
            raise SystemExit(f"cap: ${spent38():.4f} spent of ${CAP38}")
    t = time.time()
    r = None
    for attempt in range(4):
        try:
            r = requests.post(DT.API.format(model=DIRECT_MODEL), json=b, timeout=180,
                              headers={"x-goog-api-key": direct_key(), "Content-Type": "application/json"})
        except requests.RequestException as e:
            print(key, "network", type(e).__name__, flush=True)
            r = None
        if r is not None and r.status_code not in (429, 500, 502, 503, 504):
            break
        time.sleep(10 * (attempt + 1))
    status = r.status_code if r is not None else 0
    got = r.json() if r is not None and r.headers.get("content-type", "").startswith("application/json") else {}
    usage = got.get("usageMetadata") or {}
    rec = {"id": key, "http": status, "t": t, "wall_s": round(time.time() - t, 3), "model": got.get("modelVersion"),
           "usage": usage, "cost": round(cost38(usage), 6),
           "request_sha256": hashlib.sha256(json.dumps(b, sort_keys=True).encode()).hexdigest()}
    with _lock:
        CACHE.mkdir(parents=True, exist_ok=True)
        with LEDGER38.open("a") as fh:
            fh.write(json.dumps(rec) + "\n")
    cand = (got.get("candidates") or [{}])[0]
    text = "".join(p.get("text", "") for p in (cand.get("content") or {}).get("parts") or []
                   if not p.get("thought")) or None
    out = {"id": key, "text": text if status == 200 else None, "finish": cand.get("finishReason"),
           "seconds": rec["wall_s"], "tokens": [usage.get("promptTokenCount"), usage.get("candidatesTokenCount"),
                                                usage.get("thoughtsTokenCount")], "model": DIRECT_MODEL}
    if status == 200 and text:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    else:
        print(key, status, out["finish"], json.dumps(got)[:300], flush=True)
    return out


def wants_image_38(d, doc):
    """Where step 2 runs (no year candidate in the own text, either set), and the owner's 122 that W46.date-image-paid
    sent to Gemini 3.7, so the two image readers are also compared image for image."""
    return not T.candidates(doc["text"]) or (d["set"] == "owner" and
                                             (CACHED_OWNER_IMAGE / ("image|" + d["id"] + ".json")).exists())


def cmd_rerender(a):
    """Rebuild the upright 2,400 px images run38 sends whose files are gone (the cache's img/ is rebuildable), from the
    orientation verdicts cmd_vision kept, the same way it wrote them. `check` then compares the rebuilt requests with
    the 3.7 ledger's hashes."""
    from PIL import Image
    import corpus_pairs as CP
    orient = json.loads((CACHE / "orient.json").read_text())
    pairs = DU.jpeg_pairs()
    (CACHE / "img").mkdir(parents=True, exist_ok=True)
    n = skipped = 0
    for d in targets():
        if not (readable(d) and wants_image_38(d, doc_of(d))):
            continue
        for p in d["pages"][:DI.PAGES]:
            if img_path(p) is not None:
                continue
            o = orient.get(p) or {}
            if "deg" not in o or not pairs.get(p):
                skipped += 1; continue
            with Image.open(os.path.join(CP.JPEGS, pairs[p])) as im:
                im = im.convert("RGB").rotate(o["deg"], expand=True)
                im.thumbnail((DU.LONG_SIDE, DU.LONG_SIDE), Image.Resampling.LANCZOS)
                im.save(CACHE / "img" / (_name(p) + ".jpg"), "JPEG", quality=90)
            n += 1
    print(f"{n} pages rendered, {skipped} without a verdict")


def cmd_check(a):
    """The rebuilt image requests against the hashes of the 3.7 requests already sent: same images, same bytes."""
    sent = {r["id"]: r["request_sha256"] for r in ledger() + ledger(CACHED_OWNER_IMAGE_LEDGER) +
            ledger(DU.CACHE / "calls.jsonl") if r["id"].startswith("image|") and r.get("http") == 200
            and r.get("request_sha256")}
    same = diff = 0
    for d in targets():
        k = "image|" + d["id"]
        if k in sent and readable(d) and wants_image_38(d, doc_of(d)):
            got = hashlib.sha256(json.dumps(DU.image_body(images_of(d)), sort_keys=True).encode()).hexdigest()
            same += got == sent[k]; diff += got != sent[k]
    print(f"{same} requests byte-identical to the ones sent to 3.7, {diff} different")


def cmd_run38(a):
    jobs = []
    for d in targets():
        if readable(d) and wants_image_38(d, doc_of(d)) and not image38_dest(d).exists():
            imgs = images_of(d)
            if imgs:
                jobs.append(("image|" + d["id"], image_body_38(imgs), image38_dest(d)))
    jobs = jobs[: a.limit or None]
    print(f"{len(jobs)} requests to send; ${spent38():.4f} spent so far (cap ${CAP38})", flush=True)
    with ThreadPoolExecutor(4) as ex:
        res = list(ex.map(lambda j: call38(*j), jobs))
    print(f"{sum(bool(r.get('text')) for r in res)}/{len(res)} answered, ${spent38():.4f} spent in all", flush=True)


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


PACK = Path(os.path.expanduser("~/.local/state/archive-autonomous/artifacts/date-route-27b-20261112"))   # the hand-over
REMOTE_ROOT = "/scratch/users/cp1/fs-ocr/date-route-27b-20261112"      # $FS_ROOT/<pack> (sherlock/sh.env)
BACK = Path(os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/sherlock-results/date-route-27b-20261112"))
TRACE_MAX_27B = 512   # the old kit's text mode, as fs-tracepack-vision ran (restart-20261022.sh)


def cmd_pack(a):
    """The export as a frozen pack in ent-robust's form: trace/ and image/ arms for postcorrect_cluster.py, image paths
    under the staged root, the support files, every file hashed in freeze.json (check_pack.py reads it). Images are
    hard-linked from the export (same disk, no second copy)."""
    import shutil
    src = Path(a.src)
    if PACK.exists():
        sys.exit(f"{PACK} exists: a frozen pack is never rebuilt in place")
    for arm in ("trace", "image"):
        (PACK / arm).mkdir(parents=True)
    (PACK / "image" / "images").mkdir()
    trace = [json.loads(l) for l in open(src / "requests.jsonl", encoding="utf-8")]
    for r in trace:
        r["max_tokens"] = TRACE_MAX_27B
    image = []
    for line in open(src / "image-requests.jsonl", encoding="utf-8"):
        r = json.loads(line)
        names = [Path(p).name for p in r["images"]]
        for n, digest in zip(names, r["image_sha256s"]):
            dst = PACK / "image" / "images" / n
            if not dst.exists():
                os.link(src / "images" / n, dst)
            if hashlib.sha256(dst.read_bytes()).hexdigest() != digest:
                sys.exit(f"{n}: the exported image differs from its request's hash")
        r["images"] = [f"{REMOTE_ROOT}/image/images/{n}" for n in names]
        image.append(r)
    for arm, rows in (("trace", trace), ("image", image)):
        with open(PACK / arm / "requests.jsonl", "w", encoding="utf-8") as fh:
            fh.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    sh = HERE / "sherlock"
    job = PACK / "support" / "job"
    (job / "bin").mkdir(parents=True)
    shutil.copy2(HERE / "postcorrect_cluster.py", PACK / "support")
    shutil.copy2(sh / "ent-robust" / "check_pack.py", PACK / "support")
    for f in ("submit.sh", "stage-job.sh", "job.sh"):
        shutil.copy2(sh / "date-route-27b" / f, job)
    shutil.copy2(sh / "sh.env", job)
    for f in (sh / "bin").iterdir():
        shutil.copy2(f, job / "bin")
    shutil.copy2(src / "pack.json", PACK / "pack.json")
    files = {}
    for dp, dns, fns in os.walk(PACK):
        rel = os.path.relpath(dp, PACK)
        dns[:] = [d for d in dns if d not in ("out", "logs")]     # answers are never frozen
        for fn in fns:
            if rel == "." and fn == "freeze.json":
                continue
            files[os.path.normpath(os.path.join(rel, fn))] = hashlib.sha256(Path(dp, fn).read_bytes()).hexdigest()
    (PACK / "freeze.json").write_text(json.dumps({"item": "W46.date-route-pipeline-27b", "arms": ["trace", "image"],
                                                  "files": dict(sorted(files.items()))}, indent=1) + "\n")
    size = sum((PACK / f).stat().st_size for f in files)
    print(f"froze {len(files)} files, {size / 1e6:.1f} MB: {len(trace)} trace, {len(image)} image requests -> {PACK}")


def cmd_collect(a):
    """The returned replies (the Mac artifact's <arm>/out, else BACK's) as CACHE/answers-27b.jsonl {id, raw, finish,
    seconds}; every request must have a reply."""
    rows, missing = [], []
    for arm in ("trace", "image"):
        out = next((d for d in (PACK / arm / "out", BACK / arm / "out") if d.is_dir()), None)
        for line in open(PACK / arm / "requests.jsonl", encoding="utf-8"):
            rid = json.loads(line)["id"]
            f = out / f"{rid}.json" if out else None
            if f is None or not f.exists():
                missing.append(rid)
                continue
            r = json.loads(f.read_text())
            rows.append({"id": rid, "raw": r.get("text"), "finish": r.get("finish"), "seconds": r.get("seconds")})
    if missing:
        sys.exit(f"{len(missing)} requests have no reply, e.g. {missing[:3]}")
    with open(QWEN_ANSWERS, "w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    print(dict(collections.Counter(r["finish"] for r in rows)), f"-> {QWEN_ANSWERS}")


# --- the route --------------------------------------------------------------------------------------------------

def route(doc, trace_raw, image_rec, self_only=False):
    """The route's answer for one document: {year, du, cls, evidence, ...}. cls is the evidence class: "text"
    (explicit from the own text), "image" (explicit from the page image), "estimate" (from a neighbour, checked,
    Date Uncertain), or "none" (no year written). image_rec is None where the image pass was not sent. self_only: step 1
    also needs the reply to cite the document itself ("self"), as the trace prompt asks for a printed own date; by
    default a year any own rule candidate carries is explicit whatever the reply cites (08-dating.md section 3, step 1)."""
    cands = T.candidates(doc["text"])
    own = {c["year"] for c in cands}
    tr = T.parse_trace(trace_raw)
    verdict, reason = SC.evidence_check(tr["y"], tr["evidence"], T.context_of(doc, "neigh")) if tr["parsed"] else (
        "none", "unparsed")
    cited = (tr["evidence"] or {}).get("neighbour", "self") if tr["evidence"] else None
    base = {"trace_y": tr["y"], "verdict": verdict, "reason": reason, "cited": cited, "lo": tr["lo"], "hi": tr["hi"],
            "has_candidate": bool(cands), "image_sent": image_rec is not None, "model_du": tr["du"] if tr["parsed"] else None}
    if tr["y"] is not None and (tr["y"] in own or verdict == "valid") and (cited == "self" or (
            not self_only and tr["y"] in own)):
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
        r["trace_only_year"] = route(doc, traw, None)["year"]     # the same route without step 2, paired
        v = route(doc, traw, sent, self_only=True)                  # step 1 needing a quote from "self"
        r["self_only"] = {"year": v["year"], "du": v["du"], "cls": v["cls"]}
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
    S["step2_paired"] = paired(nit, "year", "trace_only_year")
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


def paired(rows, a, b):
    """Exact year with a against b on the same documents: both counts, the discordant pairs and a two-sided exact sign
    test on them."""
    ra = sum(r[a] == r["truth_y"] for r in rows)
    rb = sum(r[b] == r["truth_y"] for r in rows)
    up = sum(r[a] == r["truth_y"] and r[b] != r["truth_y"] for r in rows)
    down = sum(r[b] == r["truth_y"] and r[a] != r["truth_y"] for r in rows)
    n, k = up + down, min(up, down)
    p = min(1.0, 2 * sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n) if n else 1.0
    return {"n": len(rows), "a_exact": ra, "b_exact": rb, "a_only": up, "b_only": down, "sign_p": round(p, 4)}


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
        alt = [{**r, **r["self_only"], "image_sent": r["image_sent"]} for r in rows]
        A = summarise(model, alt, ts)
        S["self_only"] = {k: A[k] for k in ("by_stratum", "not_in_text", "all_owner", "by_class", "du_vs_owner",
                                            "undated")}
        # The model's own flag demoting an explicit text year to Date Uncertain (one way only; the year is kept).
        flg = [{**r, "du": r["du"] or (r["cls"] == "text" and r["model_du"] is True)} for r in rows]
        F = summarise(model, flg, ts)
        S["flag_demotes"] = {"du_vs_owner": F["du_vs_owner"], "undated": F["undated"],
                             "owner_text_flagged": sum(1 for r in rows if r["set"] == "owner" and r["truth_y"] is not None
                                                       and r["cls"] == "text" and r["model_du"] is True),
                             "owner_text_flagged_exact": sum(1 for r in rows if r["set"] == "owner" and r["cls"] == "text"
                                                             and r["model_du"] is True and r["truth_y"] is not None
                                                             and r["year"] == r["truth_y"]),
                             "owner_text_flagged_owner_du": sum(1 for r in rows if r["set"] == "owner" and r["cls"] == "text"
                                                                and r["model_du"] is True and r["truth_du"] is True
                                                                and r["truth_y"] is not None)}
        own = [r for r in rows if r["set"] == "owner" and r["truth_y"] is not None]
        for r in own:
            r["self_only_year"] = r["self_only"]["year"]
        S["self_only"]["paired_all_owner"] = paired(own, "year", "self_only_year")
        if model == GEMINI:
            S["cost"] = gemini_cost()
            S["per_1000"] = per_1000(S, S["cost"])
        out["models"][model] = S
        with open(CACHE / f"rows-{model}.jsonl", "w", encoding="utf-8") as fh:
            fh.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    RESULTS_JSON.write_text(json.dumps(out, indent=1) + "\n")
    write_md(out)
    print(json.dumps({m: {"not_in_text": s["not_in_text"], "by_class": s["by_class"]} for m, s in out["models"].items()},
                     indent=1))
    print(f"-> {RESULTS_JSON}")


# --- the report -------------------------------------------------------------------------------------------------

LABELS = {GEMINI: "Gemini 3.7 Flash (gateway)", QWEN: "Qwen3.6 27B (Sherlock)"}


def pc(f):
    return f"{f['pct']:.1f}% ({f['k']}/{f['n']})" if f and f["n"] else "–"


def ci(f):
    return f"{f['ci'][0]:.0f}-{f['ci'][1]:.0f}" if f and f.get("ci") else "–"


def write_md(out):
    from seg_card import card, keep_card
    M = out["models"]
    L = ["# The restated dating route end to end (W46.date-route-pipeline)", "",
         "Written by `scripts/segbench/date_route_pipeline.py score`. The route of `13-stage-rules/08-dating.md` section 3 "
         "as one pipeline: (1) the trace prompt with the neighbours' dates on the app's own OCR text, the year explicit when "
         "the document's own text carries it; (2) the image pass (first two pages, images alone) only where the own text "
         "has no year candidate; (3) inheritance, not measured; (4) the same trace reply's neighbour estimate, written only "
         "when `date_scorers.evidence_check` passes, always with Date Uncertain. Date Uncertain is set by the step, never by "
         "the model's flag. Text: Apple Vision (macOS 27.2) on the JPEG originals, upright, 2,400 px; no ABBYY text is an "
         f"input. Sets: the owner's 300 ({out['readable'].get('owner', 0)} with a confirmed JPEG original of the first page; "
         f"the rest are left out) and the undated 100 of W46.date-undated ({out['readable'].get('undated', 0)} readable).", ""]
    if QWEN not in M:
        L += ["The 27B half runs on Sherlock and is not in yet: `export` wrote its pack, held as "
              "W46.date-route-pipeline-27b; `score` adds its rows when its answers land in the cache.", ""]
    L += findings(out)
    L += ["## Exact year by where the year is (the owner's documents)", "",
          "\"In text\": the owner's year is written in the document's own Vision text (3,000 characters). \"On the page\": "
          "not in the text, but the Gemini image pass (sent on every owner document for this split) quotes a date with "
          "that year. \"Not on the page\": neither. \"Not in text\" is the last two together, the stage's metric, now "
          "defined from the app's own text and the image pass, not from the ABBYY text (DAT-1). Decade-tagged documents "
          "are scored apart. 95% Wilson intervals.", "",
          "| route | in text | on the page | not on the page | not in text | interval | wrong year written, not in text |",
          "|---|---|---|---|---|---|---|"]
    for m, S in M.items():
        b = S["by_stratum"]
        nitw = sum(b[s]["wrong"]["k"] for s in STRATA[1:])
        L.append(f"| {LABELS[m]} | {pc(b['in text']['exact'])} | {pc(b['on the page']['exact'])} | "
                 f"{pc(b['not on the page']['exact'])} | {pc(S['not_in_text'])} | {ci(S['not_in_text'])} | "
                 f"{nitw}/{S['not_in_text']['n']} |")
    L += ["", "## By evidence class (the owner's documents)", "",
          "The class is the step that wrote the year: explicit from the text or the image (no Date Uncertain), estimated "
          "from a neighbour with checked evidence (Date Uncertain), or none written.", "",
          "| route | text | image | estimate | none | certain years flagged | uncertain years unflagged | estimate interval covers, median width |",
          "|---|---|---|---|---|---|---|---|"]
    for m, S in M.items():
        c, du, ei = S["by_class"], S["du_vs_owner"], S["estimate_interval"]
        L.append(f"| {LABELS[m]} | " + " | ".join(
            f"{c[k]['n']}, {pc(c[k]['exact'])} exact" if k != "none" else f"{c[k]['n']}" for k in CLASSES) +
            f" | {pc(du['certain_flagged'])} | {pc(du['uncertain_unflagged'])} | "
            f"{pc(ei['covered'])}, {ei['median_width']} y |")
    L += ["", "## Step 1 needing a quote from the document itself (a variant, in-sample)", "",
          "Section 3 makes a year explicit when any rule candidate in the own text carries it, whatever the reply cites. "
          "The variant also needs the reply to cite \"self\", as the trace prompt asks for a printed own date; a year "
          "the reply takes from a neighbour is then an estimate, with Date Uncertain, even when the text mentions it. "
          "Chosen after reading this run's undated false years, so it is an in-sample comparison, not a tested rule.", "",
          "| route | step 1 | in text | not in text | all owner, paired: default only / variant only, p | explicit / estimated years on the undated | false-year rate |",
          "|---|---|---|---|---|---|---|"]
    for m, S in M.items():
        for lab, X in (("any own candidate (section 3)", S), ("a quote from self", S["self_only"])):
            p2 = S["self_only"]["paired_all_owner"]
            pair = f"{X['all_owner']['k']}/{X['all_owner']['n']}" + (
                f"; {p2['a_only']} / {p2['b_only']}, p {p2['sign_p']}" if X is not S else "")
            u = X["undated"]
            L.append(f"| {LABELS[m]} | {lab} | {pc(X['by_stratum']['in text']['exact'])} | {pc(X['not_in_text'])} | "
                     f"{pair} | {u['explicit']} / {u['estimates']} | {pc(u['false_year'])} |")
    L += ["", "## The model's own flag on an explicit text year (a variant, in-sample)", "",
          "Section 3 never takes Date Uncertain from the model. Here the trace reply's own `date_uncertain` is allowed one "
          "thing only: to add Date Uncertain to a year step 1 made explicit (the year is kept, nothing is removed). A year "
          "with Date Uncertain is not a false year. Like the self-quote variant, it was chosen after reading this run's "
          "undated false years and is evaluated on the same replies, so it is an in-sample comparison, not a tested rule; "
          "and part of its undated false-year rate is judged by the Gemini image pass, the scored route's own step 2 "
          "(split below the table).", "",
          "| route | owner text years the model flagged: n, exact, owner-uncertain | certain years flagged | uncertain years unflagged | false-year rate, undated |",
          "|---|---|---|---|---|"]
    for m, S in M.items():
        F = S["flag_demotes"]
        L.append(f"| {LABELS[m]}, section 3 | – | {pc(S['du_vs_owner']['certain_flagged'])} | "
                 f"{pc(S['du_vs_owner']['uncertain_unflagged'])} | {pc(S['undated']['false_year'])} |")
        L.append(f"| {LABELS[m]}, the flag demotes | {F['owner_text_flagged']}, {F['owner_text_flagged_exact']}, "
                 f"{F['owner_text_flagged_owner_du']} | {pc(F['du_vs_owner']['certain_flagged'])} | "
                 f"{pc(F['du_vs_owner']['uncertain_unflagged'])} | {pc(F['undated']['false_year'])} |")
    for m, S in M.items():
        U = S["flag_demotes"]["undated"]
        L += ["", f"{LABELS[m]}, the flag demotes: of its {U['false_year']['k']} undated false years, "
              f"{U['owner_ruled']['false']} are on documents the owner ruled ({U['owner_ruled']['false']} of "
              f"{U['owner_ruled']['explicit_ruled']} explicit years there) and {U['model_scored']['false']} are judged "
              f"by the Gemini image pass ({U['model_scored']['false']} of {U['model_scored']['explicit_unruled']})."]
    L += ["", "## What the image step adds (paired, not in text)", "",
          "The same documents and trace replies, the route with and without step 2.", "",
          "| route | with step 2 | without | only with | only without | sign test p |", "|---|---|---|---|---|---|"]
    for m, S in M.items():
        p = S["step2_paired"]
        L.append(f"| {LABELS[m]} | {p['a_exact']}/{p['n']} | {p['b_exact']}/{p['n']} | {p['a_only']} | {p['b_only']} | "
                 f"{p['sign_p']} |")
    L += ["", "## The evidence checker on fresh replies (P13-5)", "",
          "Every trace reply with a year on the owner's documents, checked by the widened checker of "
          "W46.date-evidence-check, which was written on the 27B's earlier replies: these are its first counts off them. "
          "\"Right refused\": the year is the owner's but the citation fails; \"wrong accepted\": the citation passes but "
          "the year is not the owner's.", "",
          "| route | valid | unsupported | none | right years refused | wrong years accepted | valid by form |",
          "|---|---|---|---|---|---|---|"]
    for m, S in M.items():
        c, by = S["checker"]["counts"], S["checker"]["by"]
        forms = ", ".join(f"{k} {by[k].get('valid', 0)} ({by[k].get('wrong accepted', 0)} wrong)"
                          for k in QUOTE_CLASSES if k in by)
        L.append(f"| {LABELS[m]} | {c.get('valid', 0)} | {c.get('unsupported', 0)} | {c.get('none', 0)} | "
                 f"{c.get('right years refused', 0)} | {c.get('wrong years accepted', 0)} | {forms} |")
    for m, S in M.items():
        refused = {k: v["right refused"] for k, v in S["checker"]["by"].items() if v.get("right refused")}
        if refused:
            L.append(f"\n{LABELS[m]}, right years refused by reason: " +
                     "; ".join(f"{k} {v}" for k, v in sorted(refused.items(), key=lambda x: -x[1])) + ".")
    L += ["", "## The undated documents (false years)", "",
          "A false year is a year written without Date Uncertain where the document has no own date of that year. Truth: "
          "the owner's ruling on the documents he ruled (W46.date-undated-fold), else the Gemini image pass's reading of "
          "the page (model-scored).", "",
          "| route | documents | years written, explicit / estimated | false, owner-ruled | false, model-scored | false-year rate | interval |",
          "|---|---|---|---|---|---|---|"]
    for m, S in M.items():
        u = S["undated"]
        L.append(f"| {LABELS[m]} | {u['n']} | {u['explicit']} / {u['estimates']} | "
                 f"{u['owner_ruled']['false']} of {u['owner_ruled']['explicit_ruled']} ruled explicit "
                 f"({u['owner_ruled']['documents_ruled']} ruled) | {u['model_scored']['false']} of "
                 f"{u['model_scored']['explicit_unruled']} | {pc(u['false_year'])} | {ci(u['false_year'])} |")
    L += ["", "## The image pass where the text has a year (item 8.2)", "",
          "Sent on the owner's documents whose own text has a year candidate, which the route does not send it to. "
          "\"Changes the year\": the pass names a document date, written in a date it quoted, other than the route's year.", "",
          "| route | documents | own date found | changes the year | of them right | wrong → right | right → wrong | a stamp date found |",
          "|---|---|---|---|---|---|---|---|"]
    for m, S in M.items():
        x = S["intext_image"]
        L.append(f"| {LABELS[m]} | {x['n']} | {x['own_date_found']} | {x['changes_year']} | {x['change_right']} | "
                 f"{x['change_wrong_to_right']} | {x['change_right_to_wrong']} | {x['stamp_dates']} |")
    if GEMINI in M:
        c, p = M[GEMINI]["cost"], M[GEMINI]["per_1000"]
        L += ["", "## Cost and time (Gemini)", "",
              f"Per call, from every ledger row behind the replies used: trace {c['trace-neigh']['calls']} calls, "
              f"${c['trace-neigh']['usd']:.5f} mean, {c['trace-neigh']['median_s']} s median; image {c['image']['calls']} "
              f"calls, ${c['image']['usd']:.5f} mean, {c['image']['median_s']} s median (3.8's list price as a ceiling; "
              f"{c['billed_note']}). Per 1,000 documents of the owner's mix, one trace call each and the image pass on "
              f"{100 * p['image_share']:.0f}% of them: about ${p['usd']:.2f} and {p['seconds']:,} s of calls in sequence. "
              f"This item spent ${c['item_spent']:.2f}.", ""]
    v = out.get("vision")
    if v:
        L += [f"Vision: {v['read_now']} pages read now in {v['read_s']} s on macOS {v['os']} "
              f"(the rest reused from date_undated's 27.2 readings), {v['oriented_now']} oriented in {v['orient_s']} s.", ""]
    L += card(
        "the owner's date tags on his 300 (year, and Date Uncertain for the two flag rates); for the undated set, his "
        "page-date rulings on the documents he ruled and the Gemini image pass's own reading on the rest, the latter "
        "the scored model's own reader and reported apart. The tag differs from the page for 4 of 26 own-page cases "
        "(date-truth-sets.md), so a route quoting the page can score wrong against the tag.",
        "the owner's 300 as date_tagging drew them and the undated 100 as W46.date-undated drew them, never by a tested "
        "route or the ABBYY text; documents whose first page has no confirmed JPEG original are left out (the app would "
        "have its own photo). The strata come from the app's own Vision text and the Gemini image pass, so \"on the "
        "page\" is defined by the Gemini reader that one route uses as its step 2.",
        "every route on the same documents, the same Vision text, the same prompts and images; the step-2 effect is "
        "paired on the same trace replies. The older step rows were on ABBYY-defined sets and corpus text and are not "
        "compared figure for figure.",
        "one run (temperature 0, reasoning low); the dating rerun floor is a same-year rate of 94% (85/90) between two "
        "identical runs (date-undated.md), so a gap of a few points between routes is inside it. Wilson intervals on "
        "single rates; the step-2 gap by an exact sign test on its discordant pairs.",
        "Gemini 3.7 on the gateway (3.8 on a direct key is unmeasured here); inheritance (step 3) is not measured; "
        "the checker counts are off its writing set but on one prompt; the false-year rate is a share of the "
        "collection-balanced undated sample, not a corpus rate (P3-1).")
    RESULTS.write_text(keep_card(RESULTS, "\n".join(L) + "\n"))
    print(f"-> {RESULTS}")


def findings(out):
    """The run's reading, from the figures in `out` (Gemini; the 27B's rows are read the same way when they land)."""
    S = out["models"].get(GEMINI)
    if not S:
        return []
    b, c, u, F = S["by_stratum"], S["by_class"], S["undated"], S["flag_demotes"]
    p2, x, k, cost = S["step2_paired"], S["intext_image"], S["checker"], S["per_1000"]
    kc, ref = k["counts"], {r: v["right refused"] for r, v in k["by"].items() if v.get("right refused")}
    return ["## Findings", "",
            f"- **The route on Gemini 3.7: {pc(S['not_in_text'])} where the year is not in the app's own text, "
            f"{pc(b['in text']['exact'])} where it is.** Not in text splits into the year on the page "
            f"({pc(b['on the page']['exact'])}) and nowhere on the page ({pc(b['not on the page']['exact'])}). By the "
            f"step that wrote the year: {c['text']['n']} explicit from the text ({pc(c['text']['exact'])} exact), "
            f"{c['image']['n']} from the image ({pc(c['image']['exact'])}), {c['estimate']['n']} estimated from a "
            f"neighbour with checked evidence ({pc(c['estimate']['exact'])}), {c['none']['n']} with no year written. "
            "These combined rows replace the hand-summed one-shot-plus-image row (F-1); they are on Vision-defined sets "
            "and not comparable figure for figure with the ABBYY-defined 131.",
            f"- **The image step adds a little and takes nothing:** {p2['a_exact']} against {p2['b_exact']} of "
            f"{p2['n']} with and without it, {p2['a_only']} documents right only with it, {p2['b_only']} only without "
            f"(sign test p {p2['sign_p']}), a direction inside the rerun floor.",
            f"- **Undated documents get a false year {pc(u['false_year'])} of the time under section 3's rule**, against "
            "6.7% for the app's own call restated on the owner's rulings (date-undated.md): step 1 writes any year a rule "
            "candidate in the own text carries as explicit, and an undated document's text often mentions a year (a "
            "citation, a table heading). Requiring the reply to quote it from the document itself changes little (see "
            f"the variant). The model knew on most of them: letting its own flag add Date Uncertain to an explicit text "
            f"year, never remove it, gives {pc(F['undated']['false_year'])} false years, and on the owner's documents "
            f"flags {F['owner_text_flagged']} more text years, of which {F['owner_text_flagged_exact']} are the "
            f"owner's year and {F['owner_text_flagged_owner_du']} he himself marked uncertain (uncertain years left "
            f"unflagged {pc(S['du_vs_owner']['uncertain_unflagged'])} to {pc(F['du_vs_owner']['uncertain_unflagged'])}). "
            "Section 3 forbids taking the flag from the model; whether this one-way use is allowed is the owner's call.",
            f"- **The evidence checker off its writing set (P13-5):** {kc.get('valid', 0)} valid, "
            f"{kc.get('unsupported', 0)} unsupported, {kc.get('none', 0)} with no evidence on Gemini's replies; "
            f"{kc.get('right years refused', 0)} right years refused ("
            + "; ".join(f"{r} {v}" for r, v in sorted(ref.items(), key=lambda z: -z[1])) +
            f"), {kc.get('wrong years accepted', 0)} wrong years accepted, since the check is for traceability, not truth.",
            f"- **The image pass on documents whose text has a year (item 8.2):** on {x['n']} it finds an own date on "
            f"{x['own_date_found']}; that date differs from the route's year on {x['changes_year']}, of which "
            f"{x['change_right']} are the owner's year ({x['change_wrong_to_right']} wrong to right, "
            f"{x['change_right_to_wrong']} right to wrong); it quotes a stamp date on {x['stamp_dates']} (second-role "
            "dates for the sidecar). Sending it everywhere would cost the image call on every document.",
            f"- **Cost and time:** about ${cost['usd']:.2f} per 1,000 documents of the owner's mix at 3.8's list price "
            f"as a ceiling, and {cost['seconds'] / 1000:.1f} s of calls a document in sequence (one trace call each, the "
            f"image pass on {100 * cost['image_share']:.0f}% of them).", ""]


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sample")
    v = sub.add_parser("vision"); v.add_argument("--limit", type=int, default=0)
    r = sub.add_parser("run"); r.add_argument("--limit", type=int, default=0)
    r = sub.add_parser("run38"); r.add_argument("--limit", type=int, default=0)
    sub.add_parser("rerender")
    sub.add_parser("check")
    e = sub.add_parser("export"); e.add_argument("--out", required=True)
    e.add_argument("--remote", default="$GROUP_HOME/$USER/archive-suite/date-route-pipeline")
    k = sub.add_parser("pack"); k.add_argument("--src", default=str(CACHE / "sherlock-pack"))
    sub.add_parser("collect")
    sub.add_parser("score")
    a = ap.parse_args()
    {"sample": cmd_sample, "vision": cmd_vision, "run": cmd_run, "run38": cmd_run38, "rerender": cmd_rerender, "check": cmd_check, "export": cmd_export, "pack": cmd_pack,
     "collect": cmd_collect, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
