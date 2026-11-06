#!/usr/bin/env python3
"""W47.item-fields-retruth: a stronger item-field truth through the gateway, the app's call on Vision text, and the
owner sheet (measurement audit 2026-10-30, FLD-1..FLD-9; execution-plans/processing-review/11-measurement-audit.md).

    python3 item_fields_retruth.py select                   # the set: the 219, 60 Clippings, 20 Handwritten
    heavy-run.py run -- TORCH_PY item_fields_retruth.py pages   # JPEG originals upright, Apple Vision lines, upload copies
    python3 item_fields_retruth.py draft --model gemini|luna [--limit N]
    python3 item_fields_retruth.py adjudicate [--limit N]   # Gemini 3.7 rules every disputed document
    python3 item_fields_retruth.py tagging [--limit N]      # the app's tagging call on Vision text (Gemini 3.7)
    python3 item_fields_retruth.py build                    # truth.jsonl (private), the sheet, the report

TORCH_PY is the shared environment's python (torch-env.sh; it holds numpy and Pillow, which ocr_truth.extract needs).

Why. W47.item-fields-truth's truth was drafted by Qwen3-VL 8B and Gemma 3 12B with Gemma ruling, on the first page
and 3,000 ABBYY characters, so its verdict "fill none" does not follow (FLD-1, FLD-4, FLD-5). This item rebuilds the
truth with stronger readers on the whole document, and builds the sheet the owner answers before
W47.item-fields-retruth-score scores any route against it.

The set (FLD-3), three parts reported apart:
- base: W47.item-fields-truth's 219 (W46.fix-ent-truth's 159, drawn by Gemini's format and text cues; 60 articles and
  reports drawn by Gemini 3.8's format).
- clippings: CLIPPINGS documents drawn from the agreed segments of the labelled folders by the owner's own
  "Clippings" Finder tag on their first page, round-robin over the collections with SEED. No scored route's label
  and no ABBYY text chose them.
- handwritten: HANDWRITTEN documents by the owner's "Handwritten" tag, the same way. The labelled folders hold 37,
  in two collections (Riesman, Kristol), so the part is two collections' hands.

Pages and text (FLD-4, FLD-5). Each document's pages, capped at the first 8 and the last 2: the JPEG original from
corpus_pairs' pairs.tsv, EXIF orientation applied and turned to match the PDF page (ocr_truth.extract), with
ent_score_paid's wrong-pair check (a pair under PAIR_CORR whose Vision text holds under PAIR_WORDS of the PDF page's
words reads the PDF page's own image instead; that check is the only use of ABBYY text, and no model sees it).
Apple Vision reads the full-resolution image with the app's settings (ocr_lines.swift: ocr.swift's text, plus line
boxes for the sheet); a copy at SEND_SIDE px is what the gateway is sent, and the full-resolution image is then
deleted (the bench cache budget). No ABBYY text goes to any model.

Drafts. Gemini 3.7 Flash (A) and GPT 5.6 Luna (B) through the Stanford gateway, blind, temperature 0, low reasoning
effort, each shown every capped page's image and the Vision text with page marks (first TEXT_CAP characters), with
PROMPT. The label definitions (item_fields.by_definition) are applied to every reading before agreement, and again
to the assembled label (truth_of), so a ruled kind decides which fields the label may have. A document whose readings
agree on every field takes A's. Otherwise Gemini 3.7, at its default reasoning, rules every field,
shown both readings in a seeded random order (it is not told which is its own) with the same images and text; the
report counts how often it sided with its own reading, with Luna's, mixed, or neither.

Kind for correspondence (FLD-2). On W46.fix-ent-truth's 159, its is_correspondence ruling (two other frontier
families, first and last pages) decides whether the kind is correspondence: a truth kind on the wrong side of it is
replaced by a reader's kind on the right side (A first), else "letter" or "other", and the document goes on the
sheet's kind part, with the 14 documents where the old truth's kind crossed that ruling. A kind taken from a reader
brings that reader's title, byline, publication and date; a default "other" marks them unknown (unknown_fields), so
the score item leaves them out.

The old Qwen3-VL 8B and Gemma 3 12B readings and the old truth are kept on each row as opinions, never as truth.

The app's call (FLD-4). The app's tagging prompt (date_tagging.build_prompt, which test_date_tagging holds equal to
TagGenerator's) on the document's Vision text, its first 3,000 characters as the app sends, with the nearby
documents' block built as the app builds it (up to three neighbouring segments in the folder, 300 characters each)
from the Vision text of each neighbour's first page (the app joins all of a neighbour's pages before cutting at 300,
so a neighbour whose first page holds under 300 characters gives a shorter block here). Gemini 3.7 Flash, temperature 0, the gateway's default reasoning
(the app sends no thinking setting); labelled "gemini-3.7-flash vision" in the score item. It replaces the deferred
74-document run in paid-runs-deferred.md.

The sheet (W47.item-fields-owner-ok): the kind conflicts; about SHEET_DISPUTES disputed fields, at least
MIN_PER_FIELD a field and the rest weighted to the fields whose Gemini 3.8 precision against this draft truth is
nearest the bar; CONTROLS agreed fields where Gemini 3.8's cached reply also agrees (the circularity a control
must catch); ENTITY_CONTROLS W46.fix-ent-truth documents whose ruling Claude Sonnet made for its own draft. Every
choice is shown as two readings in random order, or one value to confirm; boxes from the Vision lines the values
were quoted from, drawn for both readings so a box shows nothing about which is the truth.

The gateway is real money on a Stanford PTA: CAP bounds this item (owner, 2026-10-30: up to $5.30, under $7),
counted from the token usage at ceiling prices or the gateway's own figure, whichever is larger; a call that
never answers is counted at its worst case. The four workers check the cap without a lock, so the total could pass it
by up to three calls' worst case (about $0.15), still under $7. Texts, images,
readings, the truth and the sheet stay in the bench cache (the owner's material; the repo is public).
"""
from __future__ import annotations

import argparse
import base64
import collections
import hashlib
import html
import json
import math
import os
import random
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ent_truth as ET  # noqa: E402
import item_fields as IF  # noqa: E402

CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/item-fields-retruth")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "item-fields-retruth.md")
SEED = 4748
CLIPPINGS, HANDWRITTEN = 60, 20
HEAD_PAGES, TAIL_PAGES = 8, 2
SEND_SIDE = 1600
TEXT_CAP = 16000
CAP = 5.30
WORKERS = 4
MAX_TOKENS = 8192
PAIR_CORR, PAIR_WORDS = 0.5, 0.4
MODELS = {"gemini": "gemini-3.7-flash", "luna": "gpt-5.6-luna"}
READERS = ("gemini", "luna")
JUDGE = "gemini"
# $ per million tokens (input, output incl. reasoning), ceilings: Gemini's is gateway_gemini.PRICE, Luna's
# ent_truth.PRICE (OpenRouter's catalogue). Labelled estimates; the gateway's own figure is kept beside each.
PRICE = {"gemini-3.7-flash": (0.75, 3.75), "gpt-5.6-luna": (0.20, 1.20)}
BAR = 0.90
SHEET_DISPUTES, MIN_PER_FIELD, MAX_PER_FIELD, CONTROLS, ENTITY_CONTROLS = 85, 8, 20, 30, 20
# Seconds an owner takes, an estimate from ocr_truth's review rates (10 s a page, 6 s a span, 30 s for the 15% typed):
# a document's pages looked over once, then each question, slower than a span because the field has to be found.
SECONDS_PER_DOC, SECONDS_PER_ITEM = 20, 12

PROMPT = """You are labelling catalogue fields for a test set built from a historical archive. You get images of the \
pages of one document (all of them, or for a long document the first 8 and the last 2) and the text machine OCR read \
from them, with page marks (it may be noisy). Read the images as well as the text.

Reply with JSON only, in this form:
{"kind": one of "letter", "memo", "telegram", "newspaper article", "magazine article", "journal article", \
"newsletter", "clipping", "report", "speech", "press release", "photograph", "other",
 "title": "..." or null,
 "byline": ["...", ...],
 "publication": "..." or null,
 "publication_date": "YYYY-MM-DD" or "YYYY-MM" or "YYYY" or null,
 "recipient_place": ["...", ...],
 "quotes": {"title": "...", "byline": "...", "publication": "...", "publication_date": "...", \
"recipient_place": "..."}}

Definitions.
- kind: what the document is. "clipping" is a printed cutting whose kind of periodical cannot be told.
- title: the title or headline the document itself states, OCR errors corrected (a memo's subject line counts; a \
report's title page). null for a letter, telegram or note, and when no title is printed. A letterhead (the \
sender's organisation printed at the top) is not a title.
- byline: the authors credited on a published piece or a report ("By ...", an author line), as "Given Surname" \
without titles. A report, press release or speech that names no person as its author: the organisation that issued \
it. An unsigned newspaper or magazine piece: []. [] for correspondence (its sender is not a byline).
- publication: the newspaper, magazine, journal or newsletter the piece was printed in, as named in its masthead, \
running head, or a note written on the clipping. null when not stated, or when the document was not printed in one \
(a letterhead is not a publication; a column's or section's name is not the publication).
- publication_date: the issue date printed with the piece (masthead, running head, or a note on the clipping). \
null when not stated, and always null for a letter, memo or telegram (its own date is not a publication date).
- recipient_place: where the addressee is, from the inside address, a "To:" line or an envelope, on any page, as \
"City, State" for the United States or "City, Country" elsewhere. [] when not written or not correspondence.
- quotes: for each field you filled, the words in the OCR text it was read from, copied exactly as the OCR text has \
them (errors included); null when it is not in the OCR text (read from the image only).
- Do not guess from general knowledge. Use only this document.

OCR text:
---
{text}
---"""

JUDGE_PROMPT = """Two readers labelled the same document independently, following the instructions below, and \
disagreed on: {fields}. Rule on every field: take the first reader's value, the second's, or your own where both \
are wrong. Check against the images and the text. Reply with the same JSON form and one more key, "basis": a short \
phrase saying what decided the disputed fields.

First reader:
{a}

Second reader:
{b}

The instructions both readers had:
"""


def key(p):
    return hashlib.sha1(p.encode()).hexdigest()[:16]


def capped(pages):
    return list(pages) if len(pages) <= HEAD_PAGES + TAIL_PAGES else list(pages[:HEAD_PAGES]) + list(pages[-TAIL_PAGES:])


def lines_path(p):
    return os.path.join(CACHE, "vision", key(p) + ".json")


def send_path(p):
    return os.path.join(CACHE, "send", key(p) + ".jpg")


def full_path(p):
    return os.path.join(CACHE, "full", key(p) + ".jpg")


def page_lines(p):
    f = lines_path(p)
    return json.load(open(f, encoding="utf-8"))["lines"] if os.path.exists(f) else None


def page_text(p):
    """ocr.swift's text of the page: its lines joined by a newline."""
    ls = page_lines(p)
    return "\n".join(x["text"] for x in ls) if ls is not None else ""


def doc_text(d, marks=True):
    ps = capped(d["pages"])
    if not marks:
        return "\n\n".join(page_text(p).strip() for p in d["pages"] if page_lines(p) is not None)
    n = len(d["pages"])
    idx = {p: i + 1 for i, p in enumerate(d["pages"])}
    return "\n\n".join(f"[page {idx[p]} of {n}]\n{page_text(p).strip()}" for p in ps)


# --- selection ------------------------------------------------------------------------------------------------

def draw(pool, n, rng):
    by_col = collections.defaultdict(list)
    for d in sorted(pool, key=lambda x: x["id"]):
        by_col[d["collection"]].append(d)
    cols = sorted(by_col)
    rng.shuffle(cols)
    for c in cols:
        rng.shuffle(by_col[c])
    got = []
    while len(got) < n and any(by_col[c] for c in cols):
        for c in cols:
            if by_col[c] and len(got) < n:
                got.append(by_col[c].pop())
    return got


def labelled_segments():
    """{folder: [segment]} for the labelled folders, and their folder list (date_tagging.document_pool's walk)."""
    import corpus_pairs as CP
    import date_tagging as DT
    lab = {}
    for line in open(os.path.join(CP.CACHE, "labels.jsonl"), encoding="utf-8"):
        g = json.loads(line)
        lab[(g["folder_id"], g["n"])] = g
    folders = sorted({os.path.dirname(g["left"]) for g in lab.values()})
    return {f: DT.folder_documents(f, lab) for f in folders}


def neighbours(segs, k):
    """The first pages of the segments date_tagging.document_pool takes the nearby block from (at most three)."""
    near = (segs[max(0, k - 3):k] + segs[k + 1:k + 4])[:3]
    return [s["pages"][0] for s in near]


def cmd_select(a):
    import corpus_pairs as CP
    import corpus_survey as CS
    segs = labelled_segments()
    where = {}
    for f, ss in segs.items():
        for k, s in enumerate(ss):
            if s["kind"] == "doc":
                where[key(s["pages"][0])] = (f, k)
    base = IF.load_docs()
    docs, counts = [], collections.Counter()
    for d in base:
        f, k = where[d["id"]]
        docs.append({"id": d["id"], "part": "base", "set": d["set"], "group": d["group"],
                     "collection": d["collection"], "pages": d["pages"], "prompt": d["prompt"],
                     "near": neighbours(segs[f], k)})
    have = {d["id"] for d in docs}
    pools = {"clippings": [], "handwritten": []}
    for f, ss in segs.items():
        for k, s in enumerate(ss):
            if s["kind"] != "doc" or not s["agreed"] or key(s["pages"][0]) in have:
                continue
            tags = set(CS.read_tags(os.path.join(CS.CORPUS, s["pages"][0])))
            rec = {"id": key(s["pages"][0]), "collection": CP.collection_of(f), "pages": s["pages"],
                   "near": neighbours(ss, k)}
            if "Handwritten" in tags:
                pools["handwritten"].append(rec)
            elif "Clippings" in tags:
                pools["clippings"].append(rec)
    rng = random.Random(SEED)
    for part, n in (("clippings", CLIPPINGS), ("handwritten", HANDWRITTEN)):
        got = draw(pools[part], n, rng)
        counts[f"{part} candidates"] = len(pools[part])
        counts[f"{part} collections"] = len({d["collection"] for d in pools[part]})
        counts[f"{part} drawn"] = len(got)
        for d in got:
            docs.append({**d, "part": part, "set": part, "group": part, "prompt": None})
    counts["base"] = len(base)
    counts["documents"] = len(docs)
    counts["pages"] = sum(len(d["pages"]) for d in docs)
    counts["pages read"] = sum(len(capped(d["pages"])) for d in docs)
    counts["neighbour pages"] = len({p for d in docs for p in d["near"]} - {p for d in docs for p in capped(d["pages"])})
    os.makedirs(CACHE, exist_ok=True)
    with open(os.path.join(CACHE, "docs.jsonl.tmp"), "w", encoding="utf-8") as fh:
        for d in docs:
            fh.write(json.dumps(d, ensure_ascii=False) + "\n")
    os.replace(os.path.join(CACHE, "docs.jsonl.tmp"), os.path.join(CACHE, "docs.jsonl"))
    json.dump(dict(counts), open(os.path.join(CACHE, "select-summary.json"), "w"), indent=1)
    print(json.dumps(dict(counts), indent=1))


def load_docs():
    return [json.loads(x) for x in open(os.path.join(CACHE, "docs.jsonl"), encoding="utf-8")]


# --- pages and Vision lines (under the heavy lock) ------------------------------------------------------------

def ocr_tool():
    import data
    src = os.path.join(HERE, "ocr_lines.swift")
    out = os.path.join(os.path.dirname(str(data.OCR_BIN)), "segbench-ocr-lines")
    if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(src):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        r = subprocess.run(["/usr/bin/swiftc", "-O", src, "-o", out], capture_output=True, text=True)
        if r.returncode:
            raise SystemExit("ocr_lines.swift did not compile:\n" + r.stderr)
    return out


def vision(pages):
    jobs = os.path.join(CACHE, "vision-jobs.tsv")
    with open(jobs, "w") as fh:
        for p in pages:
            fh.write(f"{full_path(p)}\t{lines_path(p)}\n")
    subprocess.run([ocr_tool(), jobs], check=False)


def words4(s):
    return set(re.findall(r"[a-z]{4,}", ET.fold(s)))


def cmd_pages(a):
    """Batch by batch: extract the full-resolution upright image, Vision lines, the upload copy, delete the full
    image. Resumable: a page with lines and an upload copy is done."""
    import corpus_pairs as CP
    import corpus_survey as CS
    import date_tagging as DT
    import ocr_truth as OT
    from pathlib import Path
    from PIL import Image
    pair = {pdf: j for pdf, j, _m, _t in CP.read_pairs()}
    for sub in ("full", "send", "vision"):
        os.makedirs(os.path.join(CACHE, sub), exist_ok=True)
    mp = os.path.join(CACHE, "pages.json")
    metas = json.load(open(mp)) if os.path.exists(mp) else {}
    docs = load_docs()[: a.limit or None]
    read = {p for d in docs for p in capped(d["pages"])}   # a neighbour-only page needs its Vision text alone
    want = list(dict.fromkeys([p for d in docs for p in capped(d["pages"])] + [p for d in docs for p in d["near"]]))

    def finished(p):
        return os.path.exists(lines_path(p)) and (p not in read or os.path.exists(send_path(p)))
    todo = [p for p in want if not finished(p)]
    print(f"{len(want)} pages wanted, {len(todo)} to do", flush=True)

    def one(p):
        out = Path(full_path(p))
        try:
            if pair.get(p):
                m = OT.extract("original", Path(CP.JPEGS) / pair[p], out, Path(CS.CORPUS) / p)
                m["source"] = "original"
            else:
                m = {**OT.extract("pdf", Path(CS.CORPUS) / p, out), "source": "pdf", "unpaired": True}
        except Exception as e:  # noqa: BLE001 — a page that will not extract is reported, not fatal
            m = {"error": str(e)[:200]}
        return p, m

    for i in range(0, len(todo), a.batch):
        batch = todo[i:i + a.batch]
        with ThreadPoolExecutor(4) as ex:
            for p, m in ex.map(one, batch):
                metas[p] = m
        vision([p for p in batch if os.path.exists(full_path(p))])
        for p in batch:   # a wrong pair: neither the image nor the words agree with the PDF page
            m = metas[p]
            if m.get("source") != "original" or (m.get("orient_corr") or 0) >= PAIR_CORR or page_lines(p) is None:
                continue
            w = words4(DT.page_text(p))
            if len(w) < 15:
                continue    # too little PDF text to judge by; the image check alone does not reject
            share = len(w & words4(page_text(p))) / len(w)
            m["word_share"] = round(share, 3)
            if share < PAIR_WORDS:
                os.remove(lines_path(p))
                m2 = OT.extract("pdf", Path(CS.CORPUS) / p, Path(full_path(p)))
                metas[p] = {**m2, "source": "pdf", "rejected_pair": pair[p], "orient_corr": m.get("orient_corr"),
                            "word_share": round(share, 3)}
                vision([p])
        for p in batch:
            if os.path.exists(full_path(p)) and p in read:
                with Image.open(full_path(p)) as im:
                    im.thumbnail((SEND_SIDE, SEND_SIDE))
                    im.save(send_path(p), "JPEG", quality=85)
            if os.path.exists(full_path(p)):
                os.remove(full_path(p))
        json.dump(metas, open(mp + ".tmp", "w"), indent=1)
        os.replace(mp + ".tmp", mp)
        print(f"[{min(i + a.batch, len(todo))}/{len(todo)}] pages", flush=True)
    bad = [p for p in want if not finished(p)]
    print(f"done; {len(bad)} pages missing; {sum(m.get('source') == 'pdf' for m in metas.values())} read from the PDF")


# --- the gateway ----------------------------------------------------------------------------------------------

def ledger():
    f = os.path.join(CACHE, "calls.jsonl")
    return [json.loads(x) for x in open(f)] if os.path.exists(f) else []


def spent():
    import gateway_gemini as G
    return sum(G.charge(r) for r in ledger())


def cost(model, usage):
    pi, po = PRICE[model]
    return ((usage.get("prompt_tokens") or 0) * pi + (usage.get("completion_tokens") or 0) * po) / 1e6


def sha(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def request_of(model, images, text, effort):
    """The request body, and the settings and content hash a cached reply must match (ent_score_paid's P6-5/P7-7
    rule: a reply is reused only for the prompt, images and settings it answered)."""
    content = [{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(
        open(p, "rb").read()).decode()}} for p in images]
    settings = {"model": model, "temperature": 0, "max_tokens": MAX_TOKENS, "reasoning_effort": effort}
    b = {k: v for k, v in settings.items() if v is not None}
    b["messages"] = [{"role": "user", "content": content + [{"type": "text", "text": text}]}] if images else \
        [{"role": "user", "content": text}]
    digest = sha(text + "".join(hashlib.sha256(open(p, "rb").read()).hexdigest() for p in images))
    return b, settings, digest


def reply_path(stage, doc_id):
    return os.path.join(CACHE, stage, doc_id + ".json")


def cached(dest, settings, digest):
    if not os.path.exists(dest):
        return None
    with open(dest, encoding="utf-8") as fh:
        out = json.load(fh)
    m = out.get("meta", {})
    if m.get("content_sha256") != digest or m.get("request") != settings:
        raise SystemExit(f"{dest}: cached reply answered a different request; move it aside to call again")
    return out


def call(stage, doc_id, model, images, text, effort):
    """One call, cached by destination, content hash and settings; the ledger line is written before the reply is
    used, and the cap is checked against the worst case first."""
    import gateway_gemini as G
    dest = reply_path(stage, doc_id)
    b, settings, digest = request_of(model, images, text, effort)
    hit = cached(dest, settings, digest)
    if hit is not None:
        return hit
    worst = cost(model, {"prompt_tokens": 2000 * len(images) + len(text) // 3 + 1000, "completion_tokens": MAX_TOKENS})
    if spent() + worst > CAP:
        raise SystemExit(f"cap: ${spent():.4f} spent of ${CAP}")
    t = time.time()
    for attempt in range(3):
        try:
            r = G.request("/chat/completions", b)
        except Exception as e:  # noqa: BLE001 — a dropped connection is retried, then reported
            if attempt < 2:
                time.sleep(10 * (attempt + 1)); continue
            print(doc_id, "request failed:", str(e)[:200])
            rec = {"stage": stage, "doc": doc_id, "http": None, "t": t, "model": model, "usage": {},
                   "cost": round(worst, 6), "images": len(images), "content_sha256": digest, "request": settings,
                   "note": "no reply; counted at the worst case, since the gateway may have billed it"}
            with open(os.path.join(CACHE, "calls.jsonl"), "a") as fh:
                fh.write(json.dumps(rec) + "\n")
            return {"meta": rec, "raw": None}
        if r.status_code in (429, 500, 502, 503, 504) and attempt < 2:
            time.sleep(10 * (attempt + 1)); continue
        break
    got = r.json() if r.headers.get("content-type", "").startswith("application/json") else {"raw": r.text[:2000]}
    usage = got.get("usage") or {}
    rec = {"stage": stage, "doc": doc_id, "http": r.status_code, "t": t, "wall_s": round(time.time() - t, 3),
           "model": got.get("model") or model, "usage": usage, "cost": round(cost(model, usage), 6),
           "images": len(images), "content_sha256": digest, "request": settings}
    rec = G.with_gateway_cost(rec, r)
    with open(os.path.join(CACHE, "calls.jsonl"), "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    choice = (got.get("choices") or [{}])[0]
    out = {"meta": {**rec, "finish": choice.get("finish_reason")},
           "raw": (choice.get("message") or {}).get("content") if r.status_code == 200 else None}
    if r.status_code == 200 and out["raw"]:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest + ".tmp", "w", encoding="utf-8") as fh:
            json.dump(out, fh, ensure_ascii=False, indent=1)
        os.replace(dest + ".tmp", dest)
    else:
        print(doc_id, stage, r.status_code, json.dumps(got)[:300], flush=True)
    return out


def ready(d):
    return all(os.path.exists(send_path(p)) and page_lines(p) is not None for p in capped(d["pages"]))


def images(d):
    return [send_path(p) for p in capped(d["pages"])]


def prompt_for(d):
    return PROMPT.replace("{text}", doc_text(d)[:TEXT_CAP])


def parse(raw):
    r = IF.parse(raw)
    if r is None:
        return None
    js = ET.parse_json(raw) or {}
    q = js.get("quotes") if isinstance(js.get("quotes"), dict) else {}
    r["quotes"] = {k: IF.clean(v) if not isinstance(v, list) else IF.clean(" ".join(map(str, v))) for k, v in q.items()}
    return r


def reading(stage, doc_id):
    p = reply_path(stage, doc_id)
    return parse(json.load(open(p, encoding="utf-8")).get("raw")) if os.path.exists(p) else None


def run_all(todo, fn):
    with ThreadPoolExecutor(WORKERS) as ex:
        res = list(ex.map(fn, todo))
    return res


def cmd_draft(a):
    model = MODELS[a.model]
    docs = [d for d in load_docs() if ready(d)][: a.limit or None]
    res = run_all(docs, lambda d: (d["id"], call("drafts/" + a.model, d["id"], model, images(d), prompt_for(d),
                                                 "low")))
    bad = [i for i, r in res if not parse(r.get("raw"))]
    print(f"{a.model}: {len(res) - len(bad)}/{len(res)} parsed; ${spent():.4f} spent in all; unparsed: {bad}")


def show(r):
    return IF.show(r)


def both(d):
    return tuple(defined(reading("drafts/" + k, d["id"])) for k in READERS)


def order_of(doc_id):
    """True when the ruling is shown Gemini's own reading first (seeded per document)."""
    return random.Random(f"{SEED}:{doc_id}").random() < 0.5


def judge_text(d, pa, pb):
    first, second = (pa, pb) if order_of(d["id"]) else (pb, pa)
    head = JUDGE_PROMPT.format(fields=", ".join(IF.disputes(pa, pb)), a=show(first), b=show(second))
    return head + prompt_for(d)


def cmd_adjudicate(a):
    todo = []
    for d in load_docs():
        pa, pb = both(d)
        if pa and pb and IF.disputes(pa, pb):
            todo.append((d, pa, pb))
    todo = todo[: a.limit or None]
    print(f"{len(todo)} documents to rule on", flush=True)
    res = run_all(todo, lambda t: (t[0]["id"], call("adjudicated", t[0]["id"], MODELS[JUDGE], images(t[0]),
                                                    judge_text(*t), None)))
    bad = [i for i, r in res if not parse(r.get("raw"))]
    print(f"ruled {len(res) - len(bad)}/{len(res)}; ${spent():.4f} spent in all; unparsed: {bad}")


def tagging_prompt(d):
    import date_tagging as DT
    near = [page_text(p)[:300] for p in d["near"]]
    context = "\n---\n".join(near) if near else None
    return DT.build_prompt(doc_text(d, marks=False), context)


def cmd_tagging(a):
    docs = [d for d in load_docs() if ready(d) and all(page_lines(p) is not None for p in d["near"])]
    docs = docs[: a.limit or None]
    res = run_all(docs, lambda d: (d["id"], call("tagging", d["id"], MODELS["gemini"], [], tagging_prompt(d), None)))
    print(f"tagging: {sum(bool(r.get('raw')) for _i, r in res)}/{len(res)} answered; ${spent():.4f} spent in all")


# --- the truth --------------------------------------------------------------------------------------------------

def side(dis, pr, pa, pb):
    """Which reading the ruling took on the disputed fields: gemini (its own), luna, mixed, or neither."""
    sa = all(IF.agree(f, pr.get(f), pa.get(f)) for f in dis)
    sb = all(IF.agree(f, pr.get(f), pb.get(f)) for f in dis)
    some = any(IF.agree(f, pr.get(f), pa.get(f)) or IF.agree(f, pr.get(f), pb.get(f)) for f in dis)
    return "gemini" if sa and not sb else "luna" if sb and not sa else "mixed" if some else "neither"


def corr_side(kind, w46_corr):
    return (kind in IF.CORRESP) == w46_corr


def w46_kind(final, pa, pb, w46_corr):
    """The kind on W46's side of correspondence: the truth's if it is, else a reader's (A first), else a default."""
    if corr_side(final["kind"], w46_corr):
        return final["kind"], None
    for r in (pa, pb):
        if r and r.get("kind") and corr_side(r["kind"], w46_corr):
            return r["kind"], "reader"
    return ("letter" if w46_corr else "other"), "default"


DEFINED = ("title", "byline", "publication", "publication_date")   # the fields by_definition empties by kind


def defined(r):
    """A reading with the label definitions applied, its quotes kept."""
    return None if r is None else {**IF.by_definition(r), "quotes": r.get("quotes") or {}}


def truth_of(d):
    """(label, how, details) for one document; label None when a draft or the ruling is missing.

    Agreement is judged on the readings with the definitions applied; the label is assembled from the readings as
    given (Gemini's on agreed fields, the ruling's on disputed ones) and the definitions are applied to it last, so
    a ruling's kind decides which fields the kind allows, not the kind each reading had. Each field keeps the quote
    of the reading it was taken from (on a disputed field, the ruling's own, else the reader's it matched)."""
    ra, rb = (reading("drafts/" + k, d["id"]) for k in READERS)
    pa, pb = defined(ra), defined(rb)
    if not pa or not pb:
        return None, "missing draft", {}
    dis = IF.disputes(pa, pb)
    det = {"disputed": dis, "first_is_gemini": order_of(d["id"])}
    quotes = {f: (ra.get("quotes") or {}).get(f) for f in IF.FIELDS if f not in dis}
    if not dis:
        final, how = dict(ra), "agreed"
    else:
        rr = reading("adjudicated", d["id"])
        if not rr:
            return None, "missing ruling", det
        pr = defined(rr)
        how = "ruled"
        det["side"] = side(dis, pr, pa, pb)
        det["field_sides"] = {f: ("both" if IF.agree(f, pr.get(f), pa.get(f)) and IF.agree(f, pr.get(f), pb.get(f))
                                  else "gemini" if IF.agree(f, pr.get(f), pa.get(f))
                                  else "luna" if IF.agree(f, pr.get(f), pb.get(f)) else "neither") for f in dis}
        final = {f: (rr if f in dis else ra).get(f) for f in IF.FIELDS}
        src = {"gemini": ra, "luna": rb, "both": ra}
        for f in dis:
            quotes[f] = (rr.get("quotes") or {}).get(f) or (
                (src[det["field_sides"][f]].get("quotes") or {}).get(f) if det["field_sides"][f] in src else None)
        final["basis"] = rr.get("basis")
    if d["set"].startswith("ent-"):
        w46 = d["group"] == "correspondence"
        det["w46_correspondence"] = w46
        k, how_k = w46_kind(IF.by_definition(final), pa, pb, w46)
        if how_k:
            det["kind_before_w46"], det["kind_from"] = IF.by_definition(final)["kind"], "w46 " + how_k
            final["kind"] = k
            if how_k == "reader":   # the fields the new kind allows, from the reader the kind came from
                r = ra if pa.get("kind") == k else rb
                for f in DEFINED:
                    final[f] = r.get(f)
                    quotes[f] = (r.get("quotes") or {}).get(f)
            elif k not in IF.CORRESP:   # no reader read it as this kind: those fields are not known
                det["unknown_fields"] = list(DEFINED)
    out = IF.by_definition(final)
    out["quotes"] = {f: q for f, q in quotes.items() if q and IF.filled(f, out.get(f))}
    out["basis"] = final.get("basis")
    return out, how, det


def old_opinions(d):
    """W47.item-fields-truth's readings and truth for a base document, kept as opinions."""
    if d["part"] != "base":
        return None
    out = {}
    for k in IF.READERS:
        r = IF.reading(k, d["id"])
        out[k] = IF.by_definition(IF.parse(r["raw"])) if r else None
    return out


def old_truth():
    p = os.path.join(IF.CACHE, "truth.jsonl")
    return {r["id"]: r for r in (json.loads(x) for x in open(p, encoding="utf-8"))} if os.path.exists(p) else {}


def plain(r):
    """A reading as JSON-able fields only."""
    return None if r is None else {f: r.get(f) for f in IF.FIELDS}


def truth_rows():
    docs = load_docs()
    old = old_truth()
    rows, stats = [], collections.Counter()
    for d in docs:
        t, how, det = truth_of(d)
        stats[how] += 1
        if t is None:
            continue
        pa, pb = both(d)
        o = old.get(d["id"])
        rows.append({"id": d["id"], "part": d["part"], "set": d["set"], "group": d["group"],
                     "collection": d["collection"], "how": how, **{f: t[f] for f in IF.FIELDS},
                     "zotero": IF.ZOTERO.get(t["kind"]) if t["kind"] else None, "quotes": t.get("quotes") or {},
                     "basis": t.get("basis"), **det, "readers": {"gemini": plain(pa), "luna": plain(pb)},
                     "reader_quotes": {"gemini": pa.get("quotes") or {}, "luna": pb.get("quotes") or {}},
                     "opinions": {**{k: plain(v) for k, v in (old_opinions(d) or {}).items()},
                                  "old_truth": {f: o.get(f) for f in IF.FIELDS} if o else None}
                     if d["part"] == "base" else None})
    return rows, stats


def tagging_reading(doc_id):
    """The app's fields from this item's Vision-text tagging reply, as item_fields.app_reading reads a cached one."""
    p = reply_path("tagging", doc_id)
    if not os.path.exists(p):
        return None
    raw = json.load(open(p, encoding="utf-8")).get("raw") or ""
    return IF.app_reading_raw(raw)


# --- the sheet --------------------------------------------------------------------------------------------------

def tokens(s):
    return [t for t in re.findall(r"[a-z0-9]+", ET.fold(s or "")) if len(t) >= 3 or t.isdigit()]


def locate(d, value, quote):
    """[(page index in capped pages, [x, y, w, h])] for the Vision line that best holds the quote (or, failing it,
    the value), when at least MIN_SHARE of its words are on that line or that line and the next; else []."""
    want = tokens(quote) or tokens(value)
    if not want:
        return []
    best = (0.0, None)
    for i, p in enumerate(capped(d["pages"])):
        ls = page_lines(p) or []
        for j, x in enumerate(ls):
            for span in (ls[j:j + 1], ls[j:j + 2]):
                have = set(tokens(" ".join(y["text"] for y in span)))
                share = sum(t in have for t in want) / len(want)
                if share > best[0] + 1e-9:
                    bx = [min(y["box"][0] for y in span), min(y["box"][1] for y in span)]
                    bx += [max(y["box"][0] + y["box"][2] for y in span) - bx[0],
                           max(y["box"][1] + y["box"][3] for y in span) - bx[1]]
                    best = (share, (i, [round(v, 4) for v in bx]))
    return [best[1]] if best[0] >= MIN_SHARE else []


MIN_SHARE = 0.6


def shown(f, v):
    if v is None or v == []:
        return ""
    if f == "publication_date":
        return "-".join(f"{x:02d}" if i else str(x) for i, x in enumerate(v) if x is not None)
    if f in IF.LISTS:
        return "; ".join(v)
    return str(v)


def prelim_precision(rows, docs):
    """Gemini 3.8's cached reply against this draft truth, per field (only to weight the sheet)."""
    by_id = {d["id"]: d for d in docs}
    out = {}
    pairs = [(IF.app_reading(by_id[r["id"]]["prompt"], None), r) for r in rows if by_id[r["id"]].get("prompt")]
    pairs = [(p, t) for p, t in pairs if p is not None]
    for f in IF.FIELDS:
        s = IF.score(IF.scoped(pairs, f), f)
        out[f] = {"precision": s["precision_ed2"], "filled": s["pred_filled"], "n": s["docs"]}
    return out, {t["id"]: p for p, t in pairs}


def quotas(avail, prec):
    """Disputed items per field: at least MIN_PER_FIELD (or all there are), the rest of SHEET_DISPUTES by weight
    1 / (0.05 + |precision - BAR|), never more than MAX_PER_FIELD or than a field has. A field Gemini 3.8 never
    fills (title) has no precision and takes the other fields' mean weight."""
    q = {f: min(MIN_PER_FIELD, n) for f, n in avail.items()}
    w = {f: 1 / (0.05 + abs(prec[f] - BAR)) for f in avail if prec.get(f) is not None}
    mean = sum(w.values()) / len(w) if w else 1.0
    w = {f: w.get(f, mean) for f in avail}
    while sum(q.values()) < SHEET_DISPUTES:
        open_ = [f for f in avail if q[f] < min(avail[f], MAX_PER_FIELD)]
        if not open_:
            break
        f = max(open_, key=lambda f: w[f] / (q[f] + 1))
        q[f] += 1
    return q


def cmd_sheet_items(rows, docs, rng):
    by_id = {d["id"]: d for d in docs}
    truth = {r["id"]: r for r in rows}
    items, keyed = collections.defaultdict(list), {}
    old = old_truth()

    def add(doc_id, kind, field, options, meta):
        n = f"{doc_id}:{len(items[doc_id])}"
        d = by_id[doc_id]
        opts = []
        for o in options:
            boxes = locate(d, o["text"], o.get("quote")) if field not in ("kind",) and o["text"] else []
            opts.append({"text": o["text"], "boxes": boxes})
        items[doc_id].append({"id": n, "part": kind, "field": field, "options": opts})
        keyed[n] = {"doc": doc_id, "part": kind, "field": field, "options": [o.get("src") for o in options], **meta}

    # 1. kind: W46-crossing documents, now or in the old truth
    for r in rows:
        o = old.get(r["id"])
        old_cross = bool(o and r.get("w46_correspondence") is not None
                         and not corr_side(o["kind"], r["w46_correspondence"]))
        if r.get("kind_from") or old_cross:
            ks = list(dict.fromkeys(k for k in (r["kind"], (r["readers"]["gemini"] or {}).get("kind"),
                                                (r["readers"]["luna"] or {}).get("kind"), (o or {}).get("kind")) if k))
            rng.shuffle(ks)
            add(r["id"], "kind", "kind", [{"text": k, "src": k} for k in ks],
                {"truth": r["kind"], "new_cross": bool(r.get("kind_from")), "old_cross": old_cross})
    # 2. disputed fields
    prec, g38 = prelim_precision(rows, docs)
    cand = collections.defaultdict(list)
    for r in rows:
        for f in r.get("disputed", []):
            if f == "kind" and any(x["field"] == "kind" for x in items.get(r["id"], [])):
                continue
            cand[f].append(r)
    q = quotas({f: len(v) for f, v in cand.items()}, {f: prec[f]["precision"] for f in prec})
    for f in IF.FIELDS:
        for r in sorted(rng.sample(cand.get(f, []), q.get(f, 0)), key=lambda r: r["id"]):
            ga, lb = r["readers"]["gemini"], r["readers"]["luna"]
            rq = r["reader_quotes"]
            opts = [{"text": shown(f, ga[f]), "quote": rq["gemini"].get(f), "src": "gemini"},
                    {"text": shown(f, lb[f]), "quote": rq["luna"].get(f), "src": "luna"}]
            rng.shuffle(opts)
            add(r["id"], "dispute", f, opts, {"truth": shown(f, r[f]), "side": r["field_sides"].get(f),
                                              "gemini": shown(f, ga[f]), "luna": shown(f, lb[f])})
    # 3. agreed controls where Gemini 3.8 agrees with the truth
    ctl = collections.defaultdict(list)
    for r in rows:
        p = g38.get(r["id"])
        if not p:
            continue
        for f in IF.FIELDS:
            ks = IF.SCOPE[f]
            if f in r.get("disputed", []) or (ks is not None and r["kind"] not in ks) or not IF.filled(f, r[f]):
                continue
            if any(x["field"] == f for x in items.get(r["id"], [])):
                continue    # already asked on this document (a kind question)
            if IF.filled(f, p.get(f)) and IF.field_match(f, p.get(f), r[f], "ed2"):
                ctl[f].append(r)
    fields = [f for f in IF.FIELDS if ctl[f]]
    for f in fields:   # documents already on the sheet first (no extra pages to look over), at random within each
        rng.shuffle(ctl[f])
        ctl[f].sort(key=lambda r: r["id"] in items)
    got = 0
    while got < CONTROLS and any(ctl[f] for f in fields):
        for f in fields:
            if ctl[f] and got < CONTROLS:
                r = ctl[f].pop()
                add(r["id"], "control", f, [{"text": shown(f, r[f]), "quote": (r["quotes"] or {}).get(f),
                                             "src": "truth"}], {"truth": shown(f, r[f])})
                got += 1
    # 4. entity controls: W46.fix-ent-truth rulings Claude Sonnet made for its own draft
    ent = [json.loads(x) for x in open(os.path.join(ET.CACHE, "truth.jsonl"), encoding="utf-8")]
    sided = []
    for e in ent:
        if e["id"] not in by_id or e["how"] != "adjudicated":
            continue
        x, y = e["readers"]["luna"], e["readers"]["claude"]
        final = {k: e[k] for k in e if k not in ("readers",)}
        if ET.side(final, x, y) == "B":
            sided.append((e, x, y))
    rng.shuffle(sided)
    sided.sort(key=lambda t: t[0]["id"] not in items)   # documents already on the sheet first, as the controls
    nm = lambda v: "; ".join(n["name"] for n in ET.ent_names(v))  # noqa: E731
    qt = lambda v: " ".join(n.get("quote") or "" for n in ET.ent_names(v))  # noqa: E731
    took = []
    for e, x, y in sided:   # a field whose names read the same differs only in class, which the sheet does not ask
        fs = [f for f in ET.FIELDS if not ET.same_field(x.get(f), y.get(f)) and nm(x.get(f)) != nm(y.get(f))]
        if fs and len(took) < ENTITY_CONTROLS:
            took.append((e, x, y, fs))
    for e, x, y, fs in sorted(took, key=lambda t: t[0]["id"]):
        for f in fs:
            opts = [{"text": nm(x.get(f)), "quote": qt(x.get(f)), "src": "luna"},
                    {"text": nm(y.get(f)), "quote": qt(y.get(f)), "src": "claude"}]
            rng.shuffle(opts)
            add(e["id"], "entity", f, opts, {"truth": nm(e.get(f)), "luna": nm(x.get(f)), "claude": nm(y.get(f))})
    return items, keyed, prec, {f: len(v) for f, v in cand.items()}, q, len(sided)


ORIENT = os.path.join(CACHE, "sheet-orient.tsv")   # ocr_orient.swift over send/: Vision's score at each turn
ORIENT_EYE = os.path.join(CACHE, "sheet-orient-eye.tsv")   # "<page key>\t<degrees clockwise>", checked by eye
TURN_RATIO, TURN_MIN = 2.0, 20.0   # a turn wins only by twice every other turn's score and 20 weighted characters


def display_turns(path=ORIENT, eye=ORIENT_EYE):
    """{page key: degrees clockwise that show it upright}, from ocr_orient.swift's scores (up, right, down, left).
    W47.item-fields-owner-ok, 2026-11-05: the upload copies are turned to match the PDF page, and the owner's label
    sheet showed that a PDF page is not always upright. Only the sheet's display turns; the readings stand."""
    turns = {}
    if not os.path.exists(path):
        return turns
    for line in open(path, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if len(f) != 5:
            continue
        sc = [float(x) for x in f[1:]]
        best = max(range(4), key=lambda i: sc[i])
        rest = [sc[i] for i in range(4) if i != best]
        # Twice every other turn, not only upright: the two sideways turns can score close (61.5 against 71.9 on
        # 4372186e, which the larger turned upside down), and an upside-down page is worse than a sideways one.
        if best and all(sc[best] >= TURN_RATIO * x for x in rest) and sc[best] - max(rest) >= TURN_MIN:
            turns[os.path.splitext(os.path.basename(f[0]))[0]] = 90 * best
    if os.path.exists(eye):   # pages too short of text for the scores, turned as an eye check found them
        for line in open(eye, encoding="utf-8"):
            f = line.split()
            if len(f) >= 2 and f[1] in ("0", "90", "180", "270"):
                turns[f[0]] = int(f[1])
    return {k: v for k, v in turns.items() if v}


def turn_box(b, deg):
    """A normalised top-left [x, y, w, h] box on an image turned `deg` degrees clockwise."""
    x, y, w, h = b
    if deg == 90:
        return [1 - y - h, x, h, w]
    if deg == 180:
        return [1 - x - w, 1 - y - h, w, h]
    if deg == 270:
        return [y, 1 - x - w, h, w]
    return list(b)


def agreed_line(r, asked):
    """The item fields the sheet does not ask on one document, with the truth's values: the owner reads them and
    says in the notes when one is wrong or something is missing."""
    out = []
    for f in IF.FIELDS:
        if f in asked or not IF.filled(f, r.get(f)):
            continue
        ks = IF.SCOPE.get(f)
        if ks is not None and r.get("kind") not in ks:
            continue
        out.append([f, shown(f, r[f])])
    return out


def write_sheet(items, keyed, docs, rows=None, turns=None):
    out = os.path.join(CACHE, "sheet")
    if os.path.exists(os.path.join(out, "answers.json")):
        print(f"{out} is answered: sheet and key left as they are", file=sys.stderr)
        return False
    os.makedirs(out, exist_ok=True)
    by_id = {d["id"]: d for d in docs}
    truth = {r["id"]: r for r in rows or []}
    turns = display_turns() if turns is None else turns
    data = []
    for doc_id in sorted(items, key=lambda i: (by_id[i]["part"], by_id[i]["collection"], i)):
        d = by_id[doc_id]
        pages = capped(d["pages"])
        imgs, turned = [], {}
        for i, p in enumerate(pages):
            deg = turns.get(key(p), 0)
            src = send_path(p)
            if deg:
                os.makedirs(os.path.join(out, "upright"), exist_ok=True)
                dst = os.path.join(out, "upright", key(p) + ".jpg")
                if not os.path.exists(dst):
                    subprocess.run(["sips", "-r", str(deg), src, "--out", dst], check=True, capture_output=True)
                src, turned[i] = dst, deg
            imgs.append(os.path.relpath(src, out))
        its = [dict(x, options=[dict(o, boxes=[[pi, turn_box(b, turned.get(pi, 0))] for pi, b in o["boxes"]])
                                for o in x["options"]]) for x in items[doc_id]]
        asked = {x["field"] for x in items[doc_id]}
        data.append({"doc": doc_id, "label": f"{d['collection']} · {len(d['pages'])} page(s)", "imgs": imgs,
                     "turned": len(turned), "agreed": agreed_line(truth[doc_id], asked) if doc_id in truth else [],
                     "items": its})
    page = (SHEET_HTML.replace("__N__", str(sum(len(v) for v in items.values()))).replace("__DOCS__", str(len(items)))
            .replace("__MINUTES__", f"{minutes(items):.0f}").replace("__NAMES__", script_json(FIELD_NAMES))
            .replace("__DATA__", script_json(data)))   # the data last, so nothing in it is taken for a placeholder
    with open(os.path.join(out, "index.html"), "w", encoding="utf-8") as fh:
        fh.write(page)
    json.dump({"seed": SEED, "items": keyed}, open(os.path.join(out, "key.json"), "w"), indent=1, ensure_ascii=False)
    return True


def script_json(v):
    """JSON safe inside a <script> element: a "</" in a reading would otherwise end the script."""
    return json.dumps(v, ensure_ascii=False).replace("</", "<\\/")


def minutes(items):
    return (len(items) * SECONDS_PER_DOC + sum(len(v) for v in items.values()) * SECONDS_PER_ITEM) / 60


FIELD_NAMES = {"kind": "what kind of document this is", "title": "title or headline",
               "byline": "byline (credited authors; for a report with no person named, the issuing organisation)",
               "publication": "publication it was printed in", "publication_date": "issue date printed with it",
               "recipient_place": "where the addressee is", "sender": "sender (who wrote or signed it)",
               "recipient": "recipient (who it is addressed to)", "sending_place": "where it was sent from"}

SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>W47 item-field check</title>
<style>
body{font:14px -apple-system,sans-serif;margin:0;background:#fff;color:#111;color-scheme:light}
header{position:sticky;top:0;background:#fff;border-bottom:1px solid #ccc;padding:6px 12px;z-index:2}
.doc{display:flex;gap:12px;border-bottom:3px solid #999;padding:10px;min-height:90vh}
.img{flex:1 1 58%;position:sticky;top:var(--head,60px);height:calc(100vh - var(--head,60px) - 20px);overflow:auto}
.frame{position:relative;width:100%;margin-bottom:8px;cursor:zoom-in}.frame.zoom{width:250%;cursor:zoom-out}.frame img{width:100%;display:block}
.box{position:absolute;border:3px solid #f0a;border-radius:4px;pointer-events:none}
.list{flex:1 1 42%}.it{border:1px solid #ccc;border-radius:4px;padding:6px;margin:8px 0}
.it.cur{outline:3px solid #06f}.it.done{background:#e6f6e6;border-color:#4a4}
.q{font-weight:600}.opt{display:block;margin:4px 0;font-family:Georgia,serif}.opt.sel{font-weight:bold;color:#060}
.turn{font-size:12px;margin:0 0 4px}.agreed{color:#555;font-size:13px;margin:4px 0}.notes textarea{width:100%;height:5em;font:14px -apple-system,sans-serif}
.k{color:#888;font-size:12px;font-family:-apple-system,sans-serif}.typed{color:#a40}.where{color:#a40;font-size:12px}
</style>
<header><b>Item-field check</b> — __N__ questions on __DOCS__ documents, about __MINUTES__ minutes. Each question shows
one or more readings of a field; which source each came from is not shown. Pick the one the pages show.
Keys: <b>1</b>-<b>5</b> pick that reading · <b>0</b> none of them (type it; empty = the field is empty) ·
<b>9</b> can't tell · <b>n/p</b> next/previous · <b>z</b> zoom. A reading offered alone: <b>1</b> right, <b>0</b> wrong.
The grey line lists the fields not asked on that document (both readers agreed, or Gemini ruled), with what goes
into the truth; the notes box under each document is for one that is wrong, or anything the fields miss. Pages
photographed sideways or upside down are shown turned upright where a check found them; "turn page" turns any
other, with its boxes. Pink boxes mark where the readings were found in the text (from Apple Vision's line positions; they can be off, and
a reading with no box was not found). Answers stay in this browser;
<button onclick="exportAnswers()">Export answers</button><span id="prog"></span></header><div id="root"></div>
<script>
const DATA=__DATA__;const NAMES=__NAMES__;const KEY='w47-item-fields-sheet';const NOTE='_notes/';
let A=JSON.parse(localStorage.getItem(KEY)||'{}');const items=[];
function esc(s){return String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
function save(){localStorage.setItem(KEY,JSON.stringify(A));prog()}
function prog(){document.getElementById('prog').textContent=` ${items.filter(it=>A[it.id]!==undefined).length} / ${items.length} answered`}
function set(it,v){A[it.id]=v;save();paint(it)}
function paint(it){const v=A[it.id];it.el.classList.toggle('done',v!==undefined);
 it.el.querySelectorAll('.opt').forEach(o=>o.classList.toggle('sel',o.dataset.v===String(v)));
 it.el.querySelector('.typed').textContent=v===undefined?'':v==='?'?"can't tell":String(v).startsWith('=')?'typed: '+(v.slice(1)||'(empty)'):''}
const root=document.getElementById('root');
for(const d of DATA){const div=document.createElement('div');div.className='doc';
 let h='<div class="img">'+d.imgs.map((s,i)=>`<button class="turn" data-t="${i}">turn page ${i+1} ↻</button><div class="frame" data-p="${i}"><img src="${s}"></div>`).join('')+`</div><div class="list"><b>${esc(d.label)}</b>`+(d.turned?` <span class="k">(${d.turned} page(s) turned upright)</span>`:'')
  +`<div class="agreed">Not asked: ${d.agreed.length?d.agreed.map(([f,v])=>esc(NAMES[f]||f)+' = '+esc(v)).join('; '):'no other field is filled'}</div>`;
 for(const x of d.items){h+=`<div class="it" data-key="${x.id}"><div class="q">${esc(NAMES[x.field]||x.field)}</div>`;
  x.options.forEach((o,i)=>{h+=`<span class="opt" data-v="${i+1}"><span class="k">${i+1}</span> ${o.text?esc(o.text):'<i>(empty)</i>'}`+(o.text&&!o.boxes.length&&x.field!=='kind'?' <span class="where">(no box)</span>':'')+'</span>'});
  h+='<span class="typed"></span></div>'}
 h+=`<div class="notes"><b>Notes on this document</b> (optional)<textarea data-n="${esc(d.doc)}">${esc(A[NOTE+d.doc]||'')}</textarea></div>`;
 div.innerHTML=h+'</div>';root.appendChild(div);
 div.querySelector('textarea').addEventListener('input',e=>{const t=e.target.value;if(t)A[NOTE+d.doc]=t;else delete A[NOTE+d.doc];save()});
 div.querySelectorAll('.frame').forEach(f=>f.onclick=()=>f.classList.toggle('zoom'));
 div.querySelectorAll('.turn').forEach(b=>b.onclick=()=>{const f=div.querySelector(`.frame[data-p="${b.dataset.t}"]`);
  const d=((+f.dataset.deg||0)+90)%360;f.dataset.deg=d;f.style.transform=d?`rotate(${d}deg)`:'';
  const side=d%180?(f.offsetHeight-f.offsetWidth)/2:0;f.style.margin=side>0?`${side}px 0`:side<0?`${-side}px ${side}px`:'';});
 div.querySelectorAll('.it').forEach(el=>{const x=d.items.find(x=>x.id===el.dataset.key);
  const it={id:x.id,x,el,div};items.push(it);paint(it);el.addEventListener('click',()=>go(items.indexOf(it)))})}
let cur=0,first=true;
function show(it){it.div.querySelectorAll('.box').forEach(b=>b.remove());let top=null;
 it.x.options.forEach(o=>o.boxes.forEach(([p,b])=>{const f=it.div.querySelector(`.frame[data-p="${p}"]`);if(!f)return;
  const m=document.createElement('div');m.className='box';const P=.01;
  Object.assign(m.style,{left:100*Math.max(0,b[0]-P)+'%',top:100*Math.max(0,b[1]-P)+'%',width:100*(b[2]+2*P)+'%',height:100*(b[3]+2*P)+'%'});
  f.appendChild(m);if(top===null)top=f.offsetTop+b[1]*f.offsetHeight}));
 const pane=it.div.querySelector('.img');if(top!==null)pane.scrollTop=top-pane.clientHeight/3}
function go(i){if(i<0||i>=items.length)return;const prev=first?null:items[cur];first=false;items[cur].el.classList.remove('cur');cur=i;
 const it=items[cur];it.el.classList.add('cur');if(!prev||prev.div!==it.div)it.div.scrollIntoView({block:'start'});
 it.el.scrollIntoView({block:'nearest'});show(it)}
function head(){const h=document.querySelector('header').offsetHeight;document.documentElement.style.setProperty('--head',h+'px');
 document.querySelectorAll('.doc').forEach(d=>d.style.scrollMarginTop=h+'px')}
addEventListener('resize',head);head();
document.addEventListener('keydown',e=>{if(e.target.closest&&e.target.closest('textarea,input'))return;const it=items[cur];if(!it)return;const n=it.x.options.length;
 if(e.key==='n')go(cur+1);else if(e.key==='p')go(cur-1);else if(e.key==='z'){it.div.querySelectorAll('.frame').forEach(f=>f.classList.toggle('zoom'));show(it)}
 else if(/^[1-5]$/.test(e.key)&&+e.key<=n){set(it,e.key);go(cur+1)}
 else if(e.key==='9'){set(it,'?');go(cur+1)}
 else if(e.key==='0'){const t=prompt('What the pages show for this field (empty = the field is empty):','');if(t!==null){set(it,'='+t);go(cur+1)}}});
function exportAnswers(){const b=new Blob([JSON.stringify(A,null,1)],{type:'application/json'});
 const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='answers.json';a.click()}
prog();go(0);
</script>"""


# --- the report -------------------------------------------------------------------------------------------------

def cmd_sheet(a):
    """Rewrite the unanswered sheet from truth.jsonl as it stands: no reader runs. The questions must come out the
    same as key.json's (same seed, same truth), so answers already saved in the browser keep their ids."""
    docs = load_docs()
    rows = [json.loads(x) for x in open(os.path.join(CACHE, "truth.jsonl"), encoding="utf-8")]
    items, keyed, *_ = cmd_sheet_items(rows, docs, random.Random(SEED))
    old = os.path.join(CACHE, "sheet", "key.json")
    if os.path.exists(old) and json.loads(json.dumps(keyed)) != json.load(open(old, encoding="utf-8"))["items"]:
        sys.exit("the questions differ from key.json: not rewritten (rerun build instead)")
    if write_sheet(items, keyed, docs, rows):
        print(os.path.join(CACHE, "sheet", "index.html"), f"({sum(1 for v in display_turns().values() if v)} pages "
              "turned upright in the cache's orientation scores)")


def cmd_build(a):
    import gateway_gemini as G
    docs = load_docs()
    rows, stats = truth_rows()
    with open(os.path.join(CACHE, "truth.jsonl.tmp"), "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(os.path.join(CACHE, "truth.jsonl.tmp"), os.path.join(CACHE, "truth.jsonl"))
    rng = random.Random(SEED)
    items, keyed, prec, avail, q, n_sided = cmd_sheet_items(rows, docs, rng)
    wrote = write_sheet(items, keyed, docs, rows)
    parts = ("base", "clippings", "handwritten")
    by_part = lambda rs: {p: sum(r["part"] == p for r in rs) for p in parts}  # noqa: E731
    calls = ledger()
    meta = json.load(open(os.path.join(CACHE, "pages.json"))) if os.path.exists(os.path.join(CACHE, "pages.json")) else {}
    read = {p for d in docs for p in capped(d["pages"])}
    kinds = collections.Counter(x["part"] for v in items.values() for x in v)
    old = old_truth()
    agree_old = collections.Counter()
    for r in rows:
        o = old.get(r["id"])
        if o:
            for f in IF.FIELDS:
                agree_old[f] += IF.agree(f, r[f], tuple(o[f]) if f == "publication_date" and o[f] else o[f])
    counts = {
        "select": json.load(open(os.path.join(CACHE, "select-summary.json"))), "how": dict(stats),
        "labelled": len(rows), "by_part": by_part(rows),
        "disputed_fields": dict(collections.Counter(f for r in rows for f in r.get("disputed", []))),
        "disputed_docs_by_part": by_part([r for r in rows if r["how"] == "ruled"]),
        "sides": dict(collections.Counter(r["side"] for r in rows if r.get("side"))),
        "field_sides": dict(collections.Counter(s for r in rows for s in (r.get("field_sides") or {}).values())),
        "first_is_gemini_when_ruled": sum(r["first_is_gemini"] for r in rows if r["how"] == "ruled"),
        "kinds": dict(collections.Counter(r["kind"] for r in rows).most_common()),
        "kinds_by_part": {p: dict(collections.Counter(r["kind"] for r in rows if r["part"] == p).most_common())
                          for p in parts},
        "filled": {f: by_part([r for r in rows if IF.filled(f, r[f])]) for f in IF.FIELDS},
        "w46_kind_changed": sum(bool(r.get("kind_from")) for r in rows),
        "w46_kind_from": dict(collections.Counter(r["kind_from"] for r in rows if r.get("kind_from"))),
        "unknown_fields_docs": sum(bool(r.get("unknown_fields")) for r in rows),
        "w46_old_cross": sum(x["part"] == "kind" and keyed[x["id"]]["old_cross"] for v in items.values() for x in v),
        "agree_with_old_truth": {f: [agree_old[f], sum(r["id"] in old for r in rows)] for f in IF.FIELDS},
        "pages": {"read": len(read), "from_pdf": sum(meta.get(p, {}).get("source") == "pdf" for p in read),
                  "rejected_pairs": sum(bool(meta.get(p, {}).get("rejected_pair")) for p in read),
                  "turned": sum((meta.get(p, {}).get("rotated") or 0) != 0 for p in read),
                  "empty_vision": sum(not page_text(p).strip() for p in read)},
        "tagging": {"answered": sum(os.path.exists(reply_path("tagging", d["id"])) for d in docs),
                    "documents": len(docs)},
        "sheet": {"documents": len(items), "items": sum(len(v) for v in items.values()), "by_part": dict(kinds),
                  "minutes": round(minutes(items)), "disputes_available": avail, "disputes_quota": q,
                  "prelim_gemini38": prec, "entity_sonnet_sided": n_sided,
                  "boxed_options": sum(bool(o["boxes"]) for v in items.values() for x in v for o in x["options"]
                                       if o["text"] and x["field"] != "kind"),
                  "options_with_text": sum(1 for v in items.values() for x in v for o in x["options"]
                                           if o["text"] and x["field"] != "kind"), "written": wrote},
        "spend": {stage: G.billed([c for c in calls if c["stage"] == stage])
                  for stage in sorted({c["stage"] for c in calls})},
        "spend_total": G.billed(calls), "http_errors": sum(c["http"] != 200 for c in calls),
    }
    out = {"counts": counts, "settings": {"cap": CAP, "send_side": SEND_SIDE, "text_cap": TEXT_CAP,
                                          "pages": [HEAD_PAGES, TAIL_PAGES], "models": MODELS, "price": PRICE}}
    json.dump(out, open(RESULTS.replace(".md", ".json"), "w"), indent=1, sort_keys=True)
    open(RESULTS, "w").write(report(out))
    print(report(out))


def f2(x):
    return "-" if x is None else f"{x:.2f}"


def report(o):
    c = o["counts"]
    s, sh = c["select"], c["sheet"]
    parts = ("base", "clippings", "handwritten")
    L = ["# Item fields, re-truthed through the gateway, and the owner sheet (W47.item-fields-retruth)", "",
         "Generated by `scripts/segbench/item_fields_retruth.py build`; method in its header. The labels, the readings "
         "and the sheet are the owner's material and stay in the bench cache "
         "(`~/Library/Caches/ArchiveSuiteRehearsal/item-fields-retruth/`); this page has counts only. No route is "
         "scored here: W47.item-fields-retruth-score scores every route once the owner has answered the sheet "
         "(W47.item-fields-owner-ok), because the truth's own error is only known then.", "",
         "## The set", "",
         f"{s['documents']} documents in three parts, reported apart: **base**, W47.item-fields-truth's {s['base']} "
         "(chosen by Gemini 3.8's `format` and ABBYY-text cues, FLD-3); **clippings**, "
         f"{s['clippings drawn']} drawn from {s['clippings candidates']} agreed documents in {s['clippings collections']} "
         "collections by the owner's own Clippings tag; **handwritten**, "
         f"{s['handwritten drawn']} of the {s['handwritten candidates']} documents tagged Handwritten, which the "
         f"labelled folders hold in only {s['handwritten collections']} collections (Riesman and Kristol). No scored "
         "route's label and no ABBYY text chose the last two parts. "
         f"{s['pages read']} pages read of {s['pages']} (first {o['settings']['pages'][0]} and last "
         f"{o['settings']['pages'][1]} of a longer document).", "",
         f"Pages: the JPEG originals, turned upright ({c['pages']['turned']} turned); {c['pages']['from_pdf']} read "
         f"from the PDF page's image instead ({c['pages']['rejected_pairs']} wrong pairs rejected, the rest "
         f"unpaired); Apple Vision with the app's settings on the full-resolution image ({c['pages']['empty_vision']} "
         f"pages read as empty); the models were sent each page at {o['settings']['send_side']} px. No model saw ABBYY "
         "text.", "",
         "| part | labelled | ruled (readers differed) |", "|---|---|---|"]
    L += [f"| {p} | {c['by_part'][p]} | {c['disputed_docs_by_part'][p]} |" for p in parts]
    L += ["", "| kind (truth) | " + " | ".join(parts) + " |", "|---|---|---|---|"]
    for k in c["kinds"]:
        L.append(f"| {k} | " + " | ".join(str(c["kinds_by_part"][p].get(k, 0)) for p in parts) + " |")
    L += ["", "| field | documents with a value: " + " | ".join(parts) + " |", "|---|---|---|---|"]
    L += [f"| {f} | " + " | ".join(str(c["filled"][f][p]) for p in parts) + " |" for f in IF.FIELDS]
    sides = c["sides"]
    L += ["", "## Drafting and ruling", "",
          f"Gemini 3.7 Flash and GPT 5.6 Luna drafted every document blind through the Stanford gateway (temperature 0, "
          f"low reasoning effort, every page read as an image plus the Vision text with page marks). Outcomes: "
          + ", ".join(f"{k} {v}" for k, v in sorted(c["how"].items())) + ". "
          f"Gemini 3.7 ruled every document they differed on, at its default reasoning, shown both readings in a "
          f"seeded random order (its own first on {c['first_is_gemini_when_ruled']}) without being told which was its "
          f"own. Its rulings by document: its own reading {sides.get('gemini', 0)}, Luna's {sides.get('luna', 0)}, "
          f"mixed {sides.get('mixed', 0)}, neither {sides.get('neither', 0)}; by disputed field: "
          + ", ".join(f"{k} {v}" for k, v in sorted(c["field_sides"].items())) + ". "
          "Self-rulings are the leaning the owner's sheet measures: Gemini 3.7 is also the app's cloud route scored "
          "next, so a field where it ruled for itself is checked on the sheet before it counts.", "",
          "Disputed fields (documents): " + ", ".join(f"{k} {v}" for k, v in sorted(c["disputed_fields"].items(),
                                                                                  key=lambda x: -x[1])) + ".", "",
          f"Kind for correspondence: W46.fix-ent-truth's ruling decided whether each of its documents is "
          f"correspondence; it changed this truth's kind on {c['w46_kind_changed']} ("
          + ", ".join(f"{k} {v}" for k, v in sorted(c["w46_kind_from"].items())) + "; a reader's kind brings that "
          f"reader's printed-piece fields, a default kind leaves them unknown, {c['unknown_fields_docs']} documents). "
          "Against the old truth "
          "(W47.item-fields-truth's, kept on each row as an opinion with its two readers), the new truth agrees by "
          "field: " + ", ".join(f"{f} {v[0]} of {v[1]}" for f, v in c["agree_with_old_truth"].items()) + ".", "",
          "## The app's call on Vision text", "",
          f"The app's tagging prompt on the Vision text, nearby block from the neighbours' Vision text, Gemini 3.7 "
          f"Flash: {c['tagging']['answered']} of {c['tagging']['documents']} documents answered. Scored in "
          "W47.item-fields-retruth-score as \"Gemini 3.7 on Vision text\"; it replaces the deferred 74-document run.",
          "", "## The owner sheet (W47.item-fields-owner-ok)", "",
          f"{sh['items']} questions on {sh['documents']} documents, about {sh['minutes']} minutes: "
          + ", ".join(f"{k} {v}" for k, v in sorted(sh["by_part"].items())) + ". "
          "Kind: every document whose kind crossed W46's correspondence ruling, now or in the old truth "
          f"({c['w46_old_cross']} of them in the old one). Disputed fields: at least {MIN_PER_FIELD} a field, the "
          f"rest of {SHEET_DISPUTES} weighted to the fields where Gemini 3.8's cached reply sits nearest the {BAR:.2f} "
          "bar against this draft truth (" + ", ".join(
              f"{f} {f2(v['precision'])}" for f, v in sh["prelim_gemini38"].items()) + "; a weighting only, not a "
          "score); quotas " + ", ".join(f"{f} {sh['disputes_quota'].get(f, 0)} of {n}"
                                        for f, n in sh["disputes_available"].items()) + ". "
          f"Controls: {CONTROLS} agreed fields where Gemini 3.8 also agrees with the truth, the case a shared error "
          f"would hide. Entity controls: {ENTITY_CONTROLS} of the {sh['entity_sonnet_sided']} W46.fix-ent-truth "
          "documents whose ruling Claude Sonnet made for its own draft. Every choice is offered blind (readings in a "
          f"random order, or one value to confirm). {sh['boxed_options']} of {sh['options_with_text']} readings "
          "carry a box from the Vision line they were quoted from.", "",
          "## Spend", "",
          f"${c['spend_total']['charged']:.2f} charged against the ${o['settings']['cap']:.2f} cap over "
          f"{c['spend_total']['calls']} calls ({c['http_errors']} not answered); estimate at ceiling prices "
          f"${c['spend_total']['estimate']:.2f}, " + G_note(c["spend_total"]) + ". By stage: "
          + "; ".join(f"{k} ${v['charged']:.2f} over {v['calls']}" for k, v in c["spend"].items()) + ".", "",
          "## Measurement card", "",
          "- **Truth:** drafted by Gemini 3.7 Flash and GPT 5.6 Luna, ruled by Gemini 3.7 where they differ; W46's "
          "ruling for correspondence kind. Stronger than the routes the old truth judged, but model-made and not yet "
          "owner-checked: its error is measured from the sheet's controls in the score item. Gemini 3.7 is both a "
          "drafter and the judge and is the family of the app's cloud route, so its rows lean its way until the "
          "owner's answers are folded in; Luna's family is not a scored route.",
          "- **Selection:** base by Gemini 3.8's format and ABBYY cues (inherited, FLD-3); clippings and handwritten "
          "by the owner's own tags, no route and no ABBYY text. The handwritten part is two collections.",
          "- **Comparison:** not made here. Every route is scored on the same documents in the score item, the app's "
          "call on the same Vision text the drafters read.",
          "- **Noise:** no rerun here; the score item reports Wilson intervals and the controls' error.",
          "- **Scope:** item fields on these 299 documents; it settles no fill verdict.", ""]
    return "\n".join(L)


def G_note(b):
    import gateway_gemini as G
    return G.billed_note([]) if not b["gateway_calls"] else (
        f"the gateway's own figure ${b['gateway']:.2f} on {b['gateway_calls']} of {b['calls']} calls")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("select").set_defaults(fn=cmd_select)
    p = sub.add_parser("pages")
    p.add_argument("--limit", type=int)
    p.add_argument("--batch", type=int, default=40)
    p.set_defaults(fn=cmd_pages)
    p = sub.add_parser("draft")
    p.add_argument("--model", choices=READERS, required=True)
    p.add_argument("--limit", type=int)
    p.set_defaults(fn=cmd_draft)
    sub.add_parser("build").set_defaults(fn=cmd_build)
    sub.add_parser("sheet").set_defaults(fn=cmd_sheet)
    for name, fn in (("adjudicate", cmd_adjudicate), ("tagging", cmd_tagging)):
        p = sub.add_parser(name)
        p.add_argument("--limit", type=int)
        p.set_defaults(fn=fn)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
