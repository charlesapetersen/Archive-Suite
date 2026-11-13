#!/usr/bin/env python3
"""W47.ct-read: reading the box and folder labels and the folder trees, scored per field.

    heavy-run.py run -- <lab venv>/bin/python ct_read.py collect --model gemma3-12b-mlx4   # a fresh open reader
    python3 ct_read.py score                 # the label routes against the truth, per field
    python3 ct_read.py trees                 # the Route B name patterns on ct_trees.json and the owner's tree
    heavy-run.py run -- python3 ct_read.py corpus-lines   # Vision lines on every Red marker's JPEG original
    python3 ct_read.py corpus                # carry-forward and Purple's meaning, measured on the corpus
    python3 ct_read.py gateway --model luna-gw   # W47.ct-read-paid: the gateway arm, real money, under PAID_CAP
    python3 ct_read.py report                # segbench-results/ct-read.md from the four steps' JSON

The truth is W47.ct-truth-final's `pool-jpeg/final/truth.jsonl` (196 photos), less 8026393c1fcf, which the owner's
third-sheet note drops as too unusual. Thirteen fields and the kind. Scoring rules (measurement audit FLD-9, review
passes P10-6 and P11-7):
- the three drafters of the truth (Qwen3-VL 8B, Qwen3.5 4B, Gemini 3.7 Flash) are scored only on the owner's own
  cells (`ruled`), less each row's `prompt_example` fields; on the rest they are reported as agreement;
- rule-settled cells (`by_rule`) are reported apart from owner-ruled and reader-unanimous ones;
- carried cells, cut-off and illegible cells, the blurred photo and unanswered cells are in no score.

Routes: Apple Vision (accurate, language correction, the app's settings; the truth build's lines) plus a parser
written here, and Gemma 3 12B on this Mac, which drafted nothing, read with a prompt whose examples are invented.
The corpus PDFs' ABBYY text layer is not a route (owner, 2026-10-30: no arm takes it as input), although the
item's text, filed on 2026-10-21, named it. No plan-route arm (root CLAUDE.md).

W47.ct-read-paid adds the gateway arm: GPT 5.6 Luna through the Stanford AI API gateway, the cheapest gateway vision
model the bench has used ($0.20 / $1.20 a million tokens against Gemini 3.7 Flash's $0.75 / $3.75), and one that
drafted none of the truth, so it is scored on every cell like Gemma. Same upright photo, same invented-example prompt,
temperature 0, low reasoning. Real money on the PTA: every call is in CACHE/gateway-calls.jsonl before its reply is
used, and PAID_CAP ($0.50, the item's ceiling, under the $7 rule) stops the run before a call could pass it.
"""
import argparse
import collections
import json
import math
import os
import random
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ct_truth as CT

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/ct-read")
TRUTH = os.path.join(CT.POOL, "final", "truth.jsonl")
REV_PAGES, FINAL_PAGES = os.path.join(CT.POOL, "rev2", "pages"), os.path.join(CT.POOL, "final", "pages")
REV_LINES, FINAL_LINES = os.path.join(CT.POOL, "rev2", "lines"), os.path.join(CT.POOL, "final", "lines")
REV_DRAFT, FINAL_DRAFT = os.path.join(CT.POOL, "rev2", "draft"), os.path.join(CT.POOL, "final", "draft")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "ct-read.md")
OUT = os.path.join(CACHE, "results")   # the steps' JSON: counts and figures only, no label text
LEFT_OUT = {"8026393c1fcf": "the owner's third-sheet note: too unusual"}
FIELDS = CT.FIELDS_FINAL
CT.FIELDS = FIELDS   # CT.norm reads it: in the final fields "Series III" and "III" are one series
SEED = 4702
MAX_TOKENS = 640

MODELS = {"gemma3-12b-mlx4": ("mlx-community/gemma-3-12b-it-4bit", "Gemma 3 12B, 4-bit MLX")}
# W47.ct-read-paid: key -> (gateway model id, name, $ per million tokens in and out, the bench's list figures)
PAID = {"luna-gw": ("gpt-5.6-luna", "GPT 5.6 Luna (Stanford gateway, low reasoning)", (0.20, 1.20))}
PAID_CAP = 0.50                 # the item's total, every paid key together
PAID_MAX_TOKENS = 4096          # reasoning comes first; a small cap returns no text
PAID_WORST_IN = 6000            # a photo's prompt tokens, generously: the cap check's worst case
PAID_LEDGER = os.path.join(CACHE, "gateway-calls.jsonl")

# The final prompt's rules with every example invented (the item: "read with a prompt whose examples are invented").
# The truth build's examples came from real labels, which is why the drafters' `prompt_example` cells are left out.
PROMPT = (
    "This photo was taken in an archive reading room. It may show a box label, a folder label or tab, a divider "
    "sheet, or a page of a document. Read what is written on the label, if there is one, into these fields. Copy "
    "only what is written: never infer or fill in anything, such as a repository the label does not name. Use null "
    "for anything not written there. Rules:\n"
    "- series: only when the label says \"Series\" (e.g. \"Series IV\"); the series' name goes in series_title. "
    "Without the word \"Series\", put that text under other.\n"
    "- accession: only when the label says \"Accession\" or \"ACCN\"; an unlabelled number goes under other.\n"
    "- container: the container type and its own number only: \"Box 7\" for \"Box 7 of 90\", \"Box #7\" or "
    "\"Box 7/90\".\n"
    "- A folder marked with two numbers such as \"3-11\" or \"6.2\" is box 3 folder 11, or box 6 folder 2: "
    "container \"Box 3\", folder \"11\".\n"
    "- folder_title: only on a folder; never read a folder title off a box label. A box label's own title is "
    "box_title.\n"
    "- A title cut off by the edge of the photo or hidden ends with \"...\".\n"
    "- Leave out the archive's internal marks: text or numbers beside a serial number, \"Archival Media\", location "
    "or shelf-location notes, the archive's logo, barcodes and their numbers, and notes about the box itself such "
    "as \"Acid Free\".\n"
    "Reply with JSON only:\n"
    "{\"kind\": one of \"box label\", \"folder label\", \"divider or other\", \"document page\",\n"
    " \"repository\": the archive or library, e.g. \"Riverside County Historical Library\",\n"
    " \"collection_title\": e.g. \"Jane Doe Papers, 1931-1977\",\n"
    " \"collection_subtitle\": a further line naming a part of the collection, e.g. a record group's office,\n"
    " \"collection_number\": a call or collection number, e.g. \"MS 0482\", \"XC0071\", \"RG 27\",\n"
    " \"accession\": an accession number, e.g. \"2004-118\",\n"
    " \"series\": e.g. \"Series IV\",\n"
    " \"series_title\": the series' name, e.g. \"Speeches and Writings\",\n"
    " \"container\": e.g. \"Box 23\", \"Carton 4\",\n"
    " \"box_title\": the title a box label gives the box's contents, e.g. \"Committee Minutes, A-F\",\n"
    " \"folder\": the folder number, e.g. \"12\",\n"
    " \"folder_title\": the folder's title, e.g. \"Budget Hearings 1962\",\n"
    " \"date\": the date or time period written for this box or folder, e.g. \"1940-1955\", \"6/2/61\",\n"
    " \"other\": any other identifying mark, e.g. an unlabelled number \"72-031\"; several joined with \"; \",\n"
    " \"label_box\": [x1, y1, x2, y2] the label's region on a 0-1000 scale, or null}")


def jsonl(path):
    return CT.jsonl(path)


def truth():
    return [r for r in jsonl(TRUTH) if r["id"] not in LEFT_OUT]


def page_of(mid):
    p = os.path.join(FINAL_PAGES, mid + ".jpg")
    return p if os.path.exists(p) else os.path.join(REV_PAGES, mid + ".jpg")


def lines_of(mid):
    for d in (FINAL_LINES, REV_LINES):
        p = os.path.join(d, mid + ".json")
        if os.path.exists(p):
            return json.load(open(p, encoding="utf-8")).get("lines", [])
    return []


def draft_dir(key):
    return os.path.join(CACHE, "draft", key)


# --- a fresh open reader ------------------------------------------------------------------------------------------

def cmd_collect(a):
    import model_store
    model_store.use()   # before mlx_vlm imports huggingface_hub
    import mlx.core as mx
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    out = draft_dir(a.model)
    os.makedirs(out, exist_ok=True)
    todo = [r["id"] for r in truth() if os.path.exists(page_of(r["id"]))
            and not os.path.exists(os.path.join(out, r["id"] + ".json"))][: a.limit or None]
    print(f"{a.model}: {len(todo)} photos to read", flush=True)
    if not todo:
        return
    mx.set_cache_limit(256 * 2**20)
    model, processor = load(MODELS[a.model][0])
    chat = apply_chat_template(processor, model.config, PROMPT, num_images=1)
    for k, mid in enumerate(todo, 1):
        start, text, last = time.time(), [], None
        for r in stream_generate(model, processor, chat, image=[page_of(mid)], max_tokens=MAX_TOKENS, temperature=0.0):
            text.append(r.text)
            last = r
        raw = "".join(text)
        rec = {"id": mid, "raw": raw, "parsed": parse(raw), "wall_s": round(time.time() - start, 2),
               "tokens": [getattr(last, "prompt_tokens", 0), getattr(last, "generation_tokens", 0)],
               "peak_gb": round(mx.get_peak_memory() / 2**30, 2)}
        with open(os.path.join(out, mid + ".json"), "w", encoding="utf-8") as fh:
            json.dump(rec, fh, ensure_ascii=False)
        print(f"[{k}/{len(todo)}] {mid} {rec['wall_s']}s {'ok' if rec['parsed'] else 'unparsed'}", flush=True)


# --- W47.ct-read-paid: the gateway arm ------------------------------------------------------------------------------

def paid_ledger():
    return jsonl(PAID_LEDGER) if os.path.exists(PAID_LEDGER) else []


def paid_cost(key, usage):
    price = PAID[key][2]
    return ((usage.get("prompt_tokens") or 0) * price[0] + (usage.get("completion_tokens") or 0) * price[1]) / 1e6


def paid_spent():
    """What every paid call so far counts against PAID_CAP: the larger of the token estimate and the gateway's own
    figure, per call (gateway_gemini.charge)."""
    import gateway_gemini as G
    return sum(G.charge(x) for x in paid_ledger())


def cmd_gateway(a):
    """One blind reading per truth photo through the gateway. The ledger line is written before the reply is used;
    the cap check reserves a worst-case call for every one in flight, so the cap holds with four at once."""
    import base64
    import threading
    from concurrent.futures import ThreadPoolExecutor
    import gateway_gemini as G
    model, name, price = PAID[a.model]
    out = draft_dir(a.model)
    os.makedirs(out, exist_ok=True)
    todo = [r["id"] for r in truth() if os.path.exists(page_of(r["id"]))
            and not os.path.exists(os.path.join(out, r["id"] + ".json"))][: a.limit or None]
    worst = (PAID_WORST_IN * price[0] + PAID_MAX_TOKENS * price[1]) / 1e6
    lock = threading.Lock()
    state = {"in_flight": 0, "stopped": None}
    print(f"{a.model}: {len(todo)} photos to read; ${paid_spent():.4f} spent of ${PAID_CAP:.2f}", flush=True)

    def one(mid):
        with lock:
            if state["stopped"]:
                return mid, state["stopped"]
            spent = paid_spent()
            if spent + worst * (state["in_flight"] + 1) > PAID_CAP:
                state["stopped"] = f"cap: ${spent:.4f} spent of ${PAID_CAP:.2f}"
                return mid, state["stopped"]
            state["in_flight"] += 1
        try:
            with open(page_of(mid), "rb") as fh:
                img = fh.read()
            body = {"model": model, "temperature": 0, "max_tokens": PAID_MAX_TOKENS, "reasoning_effort": "low",
                    "messages": [{"role": "user", "content": [
                        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(img).decode()}},
                        {"type": "text", "text": PROMPT}]}]}
            t = time.time()
            for attempt in range(3):
                r = G.request("/chat/completions", body)
                if r.status_code in (429, 500, 502, 503, 504) and attempt < 2:
                    time.sleep(10 * (attempt + 1))
                    continue
                break
            got = r.json() if r.headers.get("content-type", "").startswith("application/json") else {"raw": r.text[:2000]}
            usage = got.get("usage") or {}
            rec = G.with_gateway_cost({"key": a.model, "id": mid, "http": r.status_code, "t": t,
                                       "wall_s": round(time.time() - t, 2), "model": got.get("model"), "usage": usage,
                                       "cost": round(paid_cost(a.model, usage), 6)}, r)
            with lock:
                with open(PAID_LEDGER, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps(rec) + "\n")
        finally:
            with lock:
                state["in_flight"] -= 1
        choice = (got.get("choices") or [{}])[0]
        raw = (choice.get("message") or {}).get("content") if r.status_code == 200 else None
        if not raw:
            return mid, f"http {r.status_code} {choice.get('finish_reason')} {json.dumps(got)[:200]}"
        d = {"id": mid, "raw": raw, "parsed": parse(raw), "wall_s": rec["wall_s"],
             "tokens": [usage.get("prompt_tokens"), usage.get("completion_tokens")], "finish": choice.get("finish_reason")}
        with open(os.path.join(out, mid + ".json"), "w", encoding="utf-8") as fh:
            json.dump(d, fh, ensure_ascii=False)
        return mid, "ok" if d["parsed"] else "unparsed"

    with ThreadPoolExecutor(4) as ex:
        res = list(ex.map(one, todo))
    bad = [(m, s) for m, s in res if s != "ok"]
    led = paid_ledger()
    print(f"{len(res) - len(bad)}/{len(res)} parsed; ${paid_spent():.4f} charged in all ({G.billed_note(led)}); "
          f"not ok: {bad[:10]}")


def parse(raw):
    m = re.search(r"\{.*\}", raw or "", re.S)
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
    except ValueError:
        return None
    if not isinstance(d, dict):
        return None
    out = {f: CT.clean(d.get(f)) for f in FIELDS}
    k = CT.clean(d.get("kind"))
    out["kind"] = k.lower() if k and k.lower() in CT.KINDS else None
    return out


# --- Apple Vision lines plus a parser -------------------------------------------------------------------------------
# Written from the plan's list of label patterns before the first score was run; the report gives that first score.
# The marker's colour is known in Route A (the Box or Folder button), so the parser takes it as the kind.

YEAR = r"(?:1[6-9]\d\d|20[0-4]\d)"
P_DATE = re.compile(rf"\b{YEAR}\s*[-–—]\s*(?:{YEAR}|\d\d)\b|\b\d{{1,2}}/\d{{1,2}}/\d{{2,4}}\b|\b{YEAR}s?\b")
P_FOLDER = re.compile(r"\b(?:folder|fol|fldr?|fd|ff?)\b\.?\s*(?:no\.?|#|number)?\s*(\d+[a-z]?)\b", re.I)
P_PAIR = re.compile(r"^\s*(\d{1,3})\s*[-.:/]\s*(\d{1,3})\s*$")   # "5-9", "8.5": box 5 folder 9 (the reading rule)
P_COLLNO = re.compile(r"\b((?:mss?|sc|rg|ru|r-mc|cbi|mc|hug(?:\s*\(fp\))?|m|coll(?:ection)?\.?\s*(?:no\.?)?)"
                      r"\s?\.?\s?\d{2,}(?:[.\-]\d+)?)\b", re.I)
P_ACCN = re.compile(r"\b(?:accession|accn|acc)\b\.?\s*(?:no\.?|#|number)?\s*:?\s*([0-9][\w\-.]*)", re.I)
P_SERIES = re.compile(r"\bseries\s+([IVXLC]+|\d+[a-z]?)\b\.?\s*[,:.\-–]?\s*(.*)$", re.I)
P_REPO = re.compile(r"\b(archives?|library|libraries|institution|institute|society|museum|university|college|"
                    r"center|centre|foundation)\b", re.I)
P_COLL = re.compile(r"\b(papers|records|collection|files|diaries|manuscripts)\b", re.I)
P_BARE = re.compile(r"^\s*(?:no\.?|#)?\s*(\d{1,3}[a-z]?)\s*$", re.I)


def vision_read(lines, colour):
    """The thirteen fields and the kind from a photo's Vision lines, by pattern. Titles: a repository line, a
    collection line, and on a folder its longest unused line."""
    texts = [CT.clean(l.get("text")) for l in lines]
    texts = [t for t in texts if t]
    out = {f: None for f in FIELDS}
    out["kind"] = "box label" if colour == "Red" else "folder label"
    used = set()

    def take(field, value, i):
        if out[field] is None and value:
            out[field] = value
            used.add(i)

    for i, t in enumerate(texts):
        m = CT.CONTAINER.search(t)
        if m:
            take("container", CT.canon("container", m.group(0)), i)
        m = P_FOLDER.search(t)
        if m and not re.search(r"\bfiles?\b", t, re.I):
            take("folder", m.group(1), i)
        m = P_ACCN.search(t)
        if m:
            take("accession", m.group(1), i)
        m = P_SERIES.search(t)
        if m:
            take("series", "Series " + m.group(1), i)
            if m.group(2).strip():
                take("series_title", m.group(2).strip(), i)
        m = P_COLLNO.search(t)
        if m and not CT.CONTAINER.search(m.group(1)):
            take("collection_number", m.group(1), i)
        m = P_DATE.search(t)
        if m:
            take("date", m.group(0), i)
    for i, t in enumerate(texts):   # a folder's "5-9", and a lone number standing for the container or the folder
        m = P_PAIR.match(t)
        if m and colour == "Purple" and out["container"] is None and out["folder"] is None:
            take("container", "Box " + m.group(1), i)
            take("folder", m.group(2), i)
    for i, t in enumerate(texts):
        m = P_BARE.match(t)
        if m and i not in used:
            if colour == "Red":
                take("container", "Box " + m.group(1), i)
            else:
                take("folder", m.group(1), i)
    for i, t in enumerate(texts):
        if i in used:
            continue
        if P_REPO.search(t) and not P_COLL.search(t):
            take("repository", t, i)
        elif P_COLL.search(t):
            take("collection_title", t, i)
    if colour == "Purple":
        rest = [(len(t), i, t) for i, t in enumerate(texts) if i not in used and sum(c.isalpha() for c in t) >= 3]
        if rest:
            _, i, t = max(rest)
            take("folder_title", t, i)
    return out


# --- scoring ------------------------------------------------------------------------------------------------------

DRAFTERS = CT.READERS
OWNER_SRC = set(CT.OWNER_FINAL)
NAMES = {**CT.NAMES, "vision": "Apple Vision (accurate) + parser", **{k: v[1] for k, v in MODELS.items()},
         **{k: v[1] for k, v in PAID.items()}}
# a paid arm is scored once it has read (W47.ct-read-paid); until then the scores are the free routes'
PAID_RUN = [k for k in PAID if os.path.isdir(draft_dir(k)) and any(n.endswith(".json") for n in os.listdir(draft_dir(k)))]
ROUTES = ["vision", *MODELS, *PAID_RUN, *DRAFTERS]
SCORED = ["kind", *FIELDS]


def same(field, a, b):
    if field == "kind":
        return (a or None) == (b or None)
    if field == "container":
        a, b = CT.canon(field, a), CT.canon(field, b)
    return CT.norm(field, a) == CT.norm(field, b)


def drafter_reading(mid, key):
    for d in (FINAL_DRAFT, REV_DRAFT):
        p = os.path.join(d, key, mid + ".json")
        if os.path.exists(p):
            return (json.load(open(p, encoding="utf-8")).get("parsed") or None)
    return None


def reading(r, route):
    if route == "vision":
        return vision_read(lines_of(r["id"]), r["colour"])
    if route in MODELS or route in PAID:
        p = os.path.join(draft_dir(route), r["id"] + ".json")
        return (json.load(open(p, encoding="utf-8")).get("parsed") or None) if os.path.exists(p) else "missing"
    return drafter_reading(r["id"], route)


def cell_class(r, f):
    """'owner', 'rule' or 'readers' for a scored cell, or why it is out of every score."""
    if r["illegible_photo"]:
        return "out: the blurred photo"
    if f in r["cut_off"]:
        return "out: cut off"
    if f in r["illegible"]:
        return "out: illegible"
    if f in r["unanswered"] or f in r["open"]:
        return "out: unanswered or open"
    if f in r["carried"] or r["src"].get(f) == "carried":
        return "out: carried"
    s = r["src"].get(f)
    return "owner" if s in OWNER_SRC else "rule" if s == "rule" else "readers"


def cells(rows):
    """Every (row, field, class) the scores use, and the count of the cells left out, by reason."""
    keep, out = [], collections.Counter()
    for r in rows:
        for f in SCORED:
            c = cell_class(r, f)
            if c.startswith("out"):
                out[c] += 1
            else:
                keep.append((r, f, c))
    return keep, out


def wilson(k, n, z=1.96):
    if not n:
        return None
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return [round(max(0, c - h), 3), round(min(1, c + h), 3)]


def tally(pairs):
    """pairs: [(truth value, reading value, right?)] -> counts: n, right, and on cells with a value / empty."""
    t = {"n": len(pairs), "right": sum(ok for _, _, ok in pairs),
         "filled": sum(1 for v, _, _ in pairs if v is not None),
         "filled_right": sum(1 for v, _, ok in pairs if v is not None and ok),
         "filled_missed": sum(1 for v, p, _ in pairs if v is not None and p is None),
         "empty": sum(1 for v, _, _ in pairs if v is None),
         "false_fill": sum(1 for v, p, _ in pairs if v is None and p is not None)}
    t["acc"] = round(t["right"] / t["n"], 3) if t["n"] else None
    t["ci"] = wilson(t["right"], t["n"])
    return t


def paired_gap(rows_cells, a, b, reads, reps=2000):
    """The accuracy gap a - b on the same cells, with a 95% bootstrap interval over photos."""
    by = collections.defaultdict(list)
    for r, f, _ in rows_cells:
        ra, rb = reads[a].get(r["id"]), reads[b].get(r["id"])
        if ra in (None, "missing") or rb in (None, "missing"):
            continue
        v = r["fields"].get(f)
        by[r["id"]].append((same(f, v, ra.get(f)), same(f, v, rb.get(f))))
    ids = sorted(by)
    if not ids:
        return None
    def gap(sel):
        xs = [x for i in sel for x in by[i]]
        return (sum(p for p, _ in xs) - sum(q for _, q in xs)) / len(xs) if xs else 0
    rng = random.Random(SEED)
    boots = sorted(gap([rng.choice(ids) for _ in ids]) for _ in range(reps))
    return {"gap": round(gap(ids), 3), "ci": [round(boots[int(.025 * reps)], 3), round(boots[int(.975 * reps)], 3)],
            "cells": sum(len(v) for v in by.values())}


def cmd_score(a):
    rows = truth()
    keep, out = cells(rows)
    reads = {route: {r["id"]: reading(r, route) for r in rows} for route in ROUTES}
    res = {"photos": len(rows), "left_out_photos": LEFT_OUT, "cells_out": dict(out),
           "cells": dict(collections.Counter(c for _, _, c in keep)), "routes": {}, "gaps": {},
           "unparsed": {k: sum(1 for v in reads[k].values() if v is None) for k in ROUTES},
           "missing": {k: sum(1 for v in reads[k].values() if v == "missing") for k in ROUTES}}
    for route in ROUTES:
        drafter = route in DRAFTERS
        per = {}
        for f in SCORED:
            groups = collections.defaultdict(list)
            for r, ff, c in keep:
                if ff != f:
                    continue
                rd = reads[route].get(r["id"])
                if rd == "missing":
                    continue
                if drafter and (c != "owner" or f in r["prompt_example"]):
                    continue   # FLD-9: a drafter is scored on the owner's cells only, less its prompt's examples
                p = (rd or {}).get(f)
                v = r["fields"].get(f)
                groups[c].append((v, p, same(f, v, p)))
                if c != "rule":
                    groups["scored"].append((v, p, same(f, v, p)))
            per[f] = {g: tally(x) for g, x in groups.items()}
        res["routes"][route] = per
    # Paired gaps between the two routes that drafted nothing, on the owner's and the unanimous cells
    base = [(r, f, c) for r, f, c in keep if c != "rule"]
    for f in SCORED:
        res["gaps"][f] = paired_gap([x for x in base if x[1] == f], next(iter(MODELS)), "vision", reads)
    # the drafters on the owner's cells, against the fresh reader on the same cells
    res["gaps_owner"] = {}
    for d in DRAFTERS:
        res["gaps_owner"][d] = {}
        for f in SCORED:
            sel = [x for x in keep if x[1] == f and x[2] == "owner" and f not in x[0]["prompt_example"]]
            res["gaps_owner"][d][f] = paired_gap(sel, d, next(iter(MODELS)), reads)
    # W47.ct-read-paid: the gateway arm against the two free routes on every cell, and against Gemini 3.7 Flash (a
    # drafter) on the owner's cells less Gemini's prompt examples, the only cells where Gemini may be scored
    gem, gemini = next(iter(MODELS)), CT.GATEWAY
    res["gaps_paid"], res["paid"] = {}, {}
    for k in PAID_RUN:
        res["gaps_paid"][k] = {f: {"vision": paired_gap([x for x in base if x[1] == f], k, "vision", reads),
                                   gem: paired_gap([x for x in base if x[1] == f], k, gem, reads),
                                   gemini: paired_gap([x for x in keep if x[1] == f and x[2] == "owner"
                                                       and f not in x[0]["prompt_example"]], k, gemini, reads)}
                               for f in SCORED}
        led = [x for x in paid_ledger() if x.get("key") == k]
        import gateway_gemini as G
        w = sorted(x["wall_s"] for x in led if x.get("http") == 200)
        b = G.billed(led)
        res["paid"][k] = {"calls": len(led), "ok": len(w), "charged": b["charged"], "estimate": b["estimate"],
                          "gateway": b["gateway"], "gateway_calls": b["gateway_calls"],
                          "per_photo": round(b["charged"] / len(w), 6) if w else None,
                          "median_s": w[len(w) // 2] if w else None,
                          "prompt_tokens_median": sorted((x["usage"].get("prompt_tokens") or 0) for x in led
                                                         if x.get("http") == 200)[len(w) // 2] if w else None,
                          "completion_tokens_median": sorted((x["usage"].get("completion_tokens") or 0) for x in led
                                                             if x.get("http") == 200)[len(w) // 2] if w else None}
    # time per photo for the local readers
    res["speed"] = {}
    for k in MODELS:
        recs = [json.load(open(os.path.join(draft_dir(k), r["id"] + ".json"))) for r in rows
                if os.path.exists(os.path.join(draft_dir(k), r["id"] + ".json"))]
        if recs:
            w = sorted(x["wall_s"] for x in recs)
            res["speed"][k] = {"n": len(w), "median_s": w[len(w) // 2], "mean_s": round(sum(w) / len(w), 2),
                               "peak_gb": max(x.get("peak_gb", 0) for x in recs)}
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "score.json"), "w") as fh:
        json.dump(res, fh, indent=1)
    for route in ROUTES:
        print(f"{route:22}", " ".join(f"{f[:6]}={(res['routes'][route][f].get('scored') or {}).get('acc')}"
                                      for f in SCORED))
    print(json.dumps({k: res[k] for k in ("cells", "cells_out", "unparsed", "missing")}))


# --- Route B: the folder-tree name patterns -------------------------------------------------------------------------
# The plan's list ("Box 17", "B17F8", "Carton 9", "Folder 8", "f. 5", "Series II", "Accession 91006", "Mss 1036",
# "SC0122", "RG 165"), a workflow level ("05 Final Tagging") skipped, and a level map per root: each depth takes the
# class most of its names have; a depth of unrecognised names is the repository when the collection is below it, the
# collection when a container or folder is, and is ignored below the container.

N_CF = [re.compile(r"^b\s?(\d+[a-z]?)\s?f\s?(\d+[a-z]?)$", re.I),
        re.compile(r"^(?:box|bx)\.?\s*(\d+[a-z]?)\s*[-,;]?\s*(?:folder|fd|fldr?|f)\.?\s*(\d+[a-z]?)(?:\s*[-–,]\s*(.+))?$",
                   re.I)]
N_CONT = re.compile(r"^(box|bx|carton|folio|volume|reel|drawer|oversize)\.?\s*(?:no\.?|#)?\s*(\d+[a-z]?)$", re.I)
N_CONT_B = re.compile(r"^b(\d+[a-z]?)$", re.I)
N_FOLD = re.compile(r"^(?:folder|fd|fldr?|f|ff)\.?\s*(?:no\.?|#)?\s*(\d+[a-z]?)(?:\s*[-–,]\s*(.+))?$", re.I)
N_SERIES = re.compile(r"^(?:series|entry|subseries)\s+\S+.*$", re.I)
N_ACCN = re.compile(r"^(?:accession|accn)\.?\s*(?:no\.?|#)?\s*([0-9][\w\-.]*)$|^(\d{4})\s+accession$", re.I)
N_COLLNO = re.compile(r"^(?:mss?|sc|rg|ru|r-mc|cbi|mc|m)\s?\d{2,}(?:[.\-]\d+)?$|^hug\s*\(fp\)\s*\d+(?:\.\d+)?$", re.I)
N_COLLNO_TAIL = re.compile(r"^(.*\S)\s*,\s*((?:mss?|sc|rg|ru|r-mc|cbi|mc|m)\s?\d{2,}(?:[.\-]\d+)?|hug\s*\(fp\)\s*\d+"
                           r"(?:\.\d+)?)$", re.I)
N_FILE = re.compile(r"\b(?:box|bx)\.?\s*(\d+[a-z]?)\s*,?\s*(?:folder|fd|f)\.?\s*(\d+[a-z]?)\b", re.I)


def name_class(n):
    s = n.replace("_", " ").strip()
    if CT.WORKFLOW.match(n):
        return "ignore"
    if any(p.match(s) for p in N_CF):
        return "container+folder"
    if N_CONT.match(s) or N_CONT_B.match(s):
        return "container"
    if N_FOLD.match(s):
        return "folder"
    if N_SERIES.match(s):
        return "series"
    if N_ACCN.match(s):
        return "accession"
    if N_COLLNO.match(s) or N_COLLNO_TAIL.match(s) or P_COLL.search(s):
        return "collection"
    if P_REPO.search(s):
        return "repository"
    return None


def level_map(dirs):
    """The pre-filled level map for one root: a class per depth."""
    depth = max((len(d) for d in dirs), default=0)
    got = []
    for k in range(depth):
        c = collections.Counter(name_class(d[k]) for d in dirs if len(d) > k)
        known = [(n, cls) for cls, n in c.items() if cls]
        got.append(max(known)[1] if known and max(known)[0] * 2 >= sum(c.values()) else None)
    for k in range(depth):
        if got[k] is None:
            below = [g for g in got[k + 1:] if g not in (None, "ignore")]
            above = got[:k]
            if any(g in ("container", "folder", "container+folder") for g in above):
                got[k] = "ignore"
            elif "collection" in above:
                got[k] = "ignore"
            elif below and below[0] == "collection":
                got[k] = "repository"
            elif below and below[0] in ("container", "container+folder", "folder", "series", "accession"):
                got[k] = "collection"
            elif "repository" in above:
                got[k] = "collection"
            else:
                got[k] = "repository" if len(below) else "collection"
    return got


def tree_fields(path, levels):
    parts = path.split("/")
    dirs, stem = parts[:-1], os.path.splitext(parts[-1])[0]
    out = {}
    for name, cls in zip(dirs, levels):
        s = name.replace("_", " ").strip()
        if cls == "repository":
            out["repository"] = name
        elif cls == "collection":
            m = N_COLLNO_TAIL.match(s)
            if m:
                out["collection_title"], out["collection_number"] = m.group(1), m.group(2)
            elif N_COLLNO.match(s):
                out["collection_number"] = s
            else:
                out["collection_title"] = name
        elif cls == "series":
            out["series"] = s
        elif cls == "accession":
            m = N_ACCN.match(s)
            out["accession"] = (m.group(1) or m.group(2)) if m else s
        elif cls in ("container", "folder", "container+folder"):
            for p in N_CF:
                m = p.match(s)
                if m:
                    out["container"], out["folder"] = "Box " + m.group(1), m.group(2)
                    if m.lastindex >= 3 and m.group(3):
                        out["folder_title"] = m.group(3).strip()
                    break
            else:
                m = N_CONT.match(s) or N_CONT_B.match(s)
                if m:
                    out["container"] = CT.canon("container", s if N_CONT.match(s) else "Box " + m.group(1))
                m = N_FOLD.match(s)
                if m:
                    out["folder"] = m.group(1)
                    if m.group(2):
                        out["folder_title"] = m.group(2).strip()
    m = N_FILE.search(stem.replace("_", " "))
    if m:
        out.setdefault("container", "Box " + m.group(1))
        out.setdefault("folder", m.group(2))
    if "folder" in out:
        out["folder"] = re.sub(r"^0+(?=\d)", "", out["folder"])
    return out


def cmd_trees(a):
    trees = json.load(open(CT.TREES, encoding="utf-8"))["trees"]
    per = collections.defaultdict(list)
    maps_right, by_conv = 0, collections.defaultdict(lambda: [0, 0])
    for t in trees:
        dirs = [f["path"].split("/")[:-1] for f in t["files"]]
        lv = level_map(dirs)
        want = [{"collection": "collection"}.get(x, x) for x in t["levels"]]
        ok_map = lv[:len(want)] == want
        maps_right += ok_map
        for f in t["files"]:
            got = tree_fields(f["path"], lv)
            for field in sorted(set(f["expect"]) | set(got)):
                v, p = f["expect"].get(field), got.get(field)
                per[field].append((v, p, same(field, v, p)))
                by_conv[t["convention"]][0] += same(field, v, p)
                by_conv[t["convention"]][1] += 1
    res = {"trees": len(trees), "files": sum(len(t["files"]) for t in trees), "maps_right": maps_right,
           "fields": {f: tally(x) for f, x in sorted(per.items())},
           "conventions": {k: {"right": v[0], "n": v[1]} for k, v in by_conv.items()}}
    # The owner's own tree: no expected fields, so what the patterns recognise, by level, in PDFs
    ot = json.load(open(os.path.join(CT.PDF_POOL, "owner-tree.json"), encoding="utf-8"))["level1"]
    l1 = collections.Counter()
    l2 = collections.Counter()
    for name, v in ot.items():
        l1[(name_class(name) or "unrecognised", v["workflow"])] += v["pdfs"]
        for n2, k in v["level2"].items():
            c2 = name_class(n2) if n2 else "no level 2"
            no = bool(N_COLLNO_TAIL.match(n2) or N_COLLNO.match(n2) or P_COLLNO.search(n2 or ""))
            l2[(c2 or "unrecognised", no)] += k
    res["owner_tree"] = {"level1_names": len(ot), "pdfs": sum(v["pdfs"] for v in ot.values()),
                         "level1_pdfs": {f"{c}{' (workflow)' if w else ''}": n for (c, w), n in l1.items()},
                         "level1_names_by_class": dict(collections.Counter(name_class(n) or "unrecognised"
                                                                           for n in ot)),
                         "level2_pdfs": {f"{c}{', a collection number' if no else ''}": n for (c, no), n in l2.items()}}
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "trees.json"), "w") as fh:
        json.dump(res, fh, indent=1)
    print(json.dumps({k: res[k] for k in ("trees", "files", "maps_right")}),
          {f: (x["acc"], x["n"]) for f, x in res["fields"].items()})
    for k, v in res["conventions"].items():
        print(f"  {k}: {v['right']}/{v['n']}")
    print(json.dumps(res["owner_tree"], indent=1))


# --- carry-forward and Purple, on the corpus ------------------------------------------------------------------------
# Read-only on the corpus: tags with getxattr(2), each marker's paired JPEG original opened and rendered into the
# cache. Vision lines on every marker (Red and Purple), at the EXIF turn and, when that reads no box or folder number,
# at the other three. A folder label often repeats its box number ("Box 18", "5-9"), so a Purple whose box differs
# from the last Red before it in its directory is a box change with no box photo, or a misread: the truth set's
# Vision score on that field bounds the second.

CORPUS_DIR = os.path.join(CACHE, "corpus")
INVENTORY = os.path.join(CORPUS_DIR, "inventory.json")   # private: corpus paths


def inventory():
    if os.path.exists(INVENTORY):
        return json.load(open(INVENTORY, encoding="utf-8"))
    import corpus_survey as CS
    dirs = []
    for folder, names in CS.walk(CS.CORPUS):
        marks = []
        for i, n in enumerate(names):
            got = set(CS.read_tags(os.path.join(CS.CORPUS, folder, n))) & CS.LABEL_COLOURS
            if len(got) == 1:
                rel = os.path.join(folder, n)
                marks.append({"id": CT.marker_id(rel), "path": rel, "pos": i, "colour": got.pop()})
        dirs.append({"folder": folder, "n": len(names), "markers": marks})
    os.makedirs(CORPUS_DIR, exist_ok=True)
    with open(INVENTORY, "w", encoding="utf-8") as fh:
        json.dump(dirs, fh, ensure_ascii=False)
    return dirs


def corpus_key(mid, turn):
    return mid if turn == 0 else f"{mid}-{turn}"


def corpus_lines(key):
    p = os.path.join(CORPUS_DIR, "lines", key + ".json")
    return json.load(open(p, encoding="utf-8")).get("lines", []) if os.path.exists(p) else None


def numbers_of(lines, colour):
    got = vision_read(lines, colour)
    return got["container"], got["folder"]


def cmd_corpus_lines(a):
    import layout_order as LO
    from PIL import Image, ImageOps
    LO.build_helper()
    dirs = inventory()
    pairs = CT.load_pairs()
    pages, lines = os.path.join(CORPUS_DIR, "pages"), os.path.join(CORPUS_DIR, "lines")
    os.makedirs(pages, exist_ok=True)
    os.makedirs(lines, exist_ok=True)
    marks = [m for d in dirs for m in d["markers"] if pairs.get(m["path"])]
    t0, done = time.time(), 0
    for turn in (0, 90, 270, 180):
        todo = []
        for m in marks:
            key = corpus_key(m["id"], turn)
            if os.path.exists(os.path.join(lines, key + ".json")):
                continue
            if turn and any(x is not None for t in (0, 90, 270, 180) if t != turn
                            for x in [corpus_lines(corpus_key(m["id"], t))] if x is not None
                            and any(numbers_of(x, m["colour"]))):
                continue   # an earlier turn read a box or folder number
            if turn and corpus_lines(m["id"]) is None:
                continue   # the photo did not render at all
            todo.append((m, key))
        print(f"turn {turn}: {len(todo)} photos", flush=True)
        for k in range(0, len(todo), 40):
            args = []
            for m, key in todo[k:k + 40]:
                out = os.path.join(pages, key + ".jpg")
                try:
                    with Image.open(pairs[m["path"]]) as im:
                        up = ImageOps.exif_transpose(im).convert("RGB")
                        up.thumbnail((CT.MAX_SIDE, CT.MAX_SIDE), Image.Resampling.LANCZOS)
                        (up.rotate(turn, expand=True) if turn else up).save(out, "JPEG", quality=90)
                    args += [out, os.path.join(lines, key + ".json")]
                except Exception as e:
                    print(m["id"], e, flush=True)
            if args:   # the helper has hung on a batch at 0% CPU (twice on 2026-11-06): give up on that batch
                try:
                    subprocess.run([str(LO.HELPER), "lines", *args], check=False, timeout=300)
                except subprocess.TimeoutExpired:
                    print(f"  batch at {k} timed out; its photos stay unread at turn {turn}", flush=True)
            for i in range(0, len(args), 2):
                os.remove(args[i])   # the rendered page is scratch; the lines are kept
            done += len(args) // 2
            print(f"  {k + len(args) // 2}/{len(todo)} {round(time.time() - t0)}s", flush=True)
    print(f"{done} readings in {round(time.time() - t0)}s; {lines}")


def best_numbers(m):
    for t in (0, 90, 270, 180):
        x = corpus_lines(corpus_key(m["id"], t))
        if x is not None:
            got = numbers_of(x, m["colour"])
            if any(got):
                return got, t
    return (None, None), None


def box_no(container):
    m = re.fullmatch(r"(\w+) (\d+)[A-Z]?", container or "")
    return (m.group(1), int(m.group(2))) if m else None


def cmd_corpus(a):
    dirs = inventory()
    pairs = CT.load_pairs()
    res = {"directories": len(dirs), "pdfs": sum(d["n"] for d in dirs),
           "markers": dict(collections.Counter(m["colour"] for d in dirs for m in d["markers"])),
           "with_jpeg": dict(collections.Counter(m["colour"] for d in dirs for m in d["markers"] if pairs.get(m["path"]))),
           "read": collections.Counter(), "turns": collections.Counter(), "red_steps": collections.Counter(),
           "purple_vs_box": collections.Counter(), "dirs_with_red": 0, "dirs_with_markers": 0}
    for d in dirs:
        marks = d["markers"]
        res["dirs_with_markers"] += bool(marks)
        res["dirs_with_red"] += any(m["colour"] == "Red" for m in marks)
        last_box = None   # the last Red's read box number in this directory
        last_red = False  # a Red was seen, read or not
        for m in marks:
            if not pairs.get(m["path"]):
                if m["colour"] == "Red":
                    last_box, last_red = None, True
                continue
            (cont, fold), t = best_numbers(m)
            b = box_no(cont)
            res["read"][f"{m['colour']}: {'box' if b else 'no box'}{', folder' if fold else ''}"] += 1
            res["turns"][f"{m['colour']} {t}"] += 1
            if m["colour"] == "Red":
                if b and last_box:
                    if b[0] != last_box[0]:
                        step = "another container type"
                    elif b[1] == last_box[1]:
                        step = "same box again"
                    elif b[1] == last_box[1] + 1:
                        step = "next box"
                    elif b[1] > last_box[1]:
                        step = "boxes skipped"
                    else:
                        step = "lower number"
                    res["red_steps"][step] += 1
                last_box, last_red = (b or None), True
            elif b:
                if not last_red:
                    res["purple_vs_box"]["folder gives a box, no box photo before it in its directory"] += 1
                elif last_box is None:
                    res["purple_vs_box"]["folder gives a box, the box photo before it unread"] += 1
                elif b[1] == last_box[1]:
                    res["purple_vs_box"]["same box as the box photo before it"] += 1
                else:
                    res["purple_vs_box"]["another box than the box photo before it"] += 1
    # Purple's meaning: the truth sample's Purple photos as drawn, with the ones the owner took out and why
    pool = jsonl(os.path.join(CT.POOL, "sample.jsonl"))
    final = {r["id"]: r for r in jsonl(TRUTH)}
    why_out = {**CT.DROPPED, **CT.DROPPED_FINAL, **LEFT_OUT}
    purple = collections.Counter()
    for r in pool:
        if r["colour"] != "Purple":
            continue
        if r["id"] in final:
            t = final[r["id"]]
            purple["folder label, unlabelled folder" if t["unlabelled"] else t["fields"]["kind"]] += 1
        else:
            purple[f"taken out: {why_out.get(r['id'], 'not in the revised sample')}"] += 1
    res["purple_sample"] = dict(purple)
    # How far to trust a read box number: on the truth set, of the photos where Vision + parser gives a container, how
    # many give the right one (owner-ruled and unanimous cells alike), by colour
    prec = collections.Counter()
    for r in truth():
        if r["illegible_photo"] or "container" in r["carried"]:
            continue
        got = vision_read(lines_of(r["id"]), r["colour"])["container"]
        if got is not None:
            prec[(r["colour"], "given")] += 1
            prec[(r["colour"], "right")] += same("container", r["fields"].get("container"), got)
    res["vision_box_precision"] = {c: {"given": prec[(c, "given")], "right": prec[(c, "right")]}
                                   for c in ("Red", "Purple")}
    for k in ("read", "turns", "red_steps", "purple_vs_box"):
        res[k] = dict(res[k])
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "corpus.json"), "w") as fh:
        json.dump(res, fh, indent=1)
    print(json.dumps(res, indent=1))


# --- the report -----------------------------------------------------------------------------------------------------

def pc(x):
    return "–" if x is None else f"{100 * x:.0f}%"


def ci(t):
    return "" if not t or not t.get("ci") else f" ({100 * t['ci'][0]:.0f}–{100 * t['ci'][1]:.0f})"


def cell(t):
    if not t or not t["n"]:
        return "–"
    return f"{pc(t['acc'])}{ci(t)}, n {t['n']}"


def load(name):
    p = os.path.join(OUT, name)
    return json.load(open(p)) if os.path.exists(p) else None


def corpus_speed():
    """(photos, seconds) of the first, EXIF-turn pass: the later turns' clock holds a helper that hung for 14
    minutes on one batch on 2026-11-06 and was stopped (its 40 photos are unread at that turn)."""
    p = os.path.join(CACHE, "corpus-lines-run1.log")   # the first run's log, kept when the run was restarted
    m = re.findall(r"^\s+(\d+)/\1 (\d+)s$", open(p).read(), re.M) if os.path.exists(p) else []
    return (int(m[0][0]), int(m[0][1])) if m else None


def cmd_report(a):
    S, T, C = load("score.json"), load("trees.json"), load("corpus.json")
    first = load("score-vision-firstpass.json")
    gem = next(iter(MODELS))
    L = ["# Container labels and folder trees: the routes scored per field (W47.ct-read)", "",
         "Written by `scripts/segbench/ct_read.py report`. The truth is W47.ct-truth-final's (`ct-truth-final.md`): "
         f"{S['photos']} box and folder marker photos (its 196 less the one the owner's third-sheet note drops). Label values "
         "stay in the cache; this page gives counts only.", ""]
    L += ["## The routes", "",
          "- **Apple Vision + parser:** the app's Vision settings (accurate, language correction), the truth build's "
          "lines on the upright photo, and a pattern parser written in `ct_read.py` from the plan's list of label "
          "forms. The marker's colour gives the kind (the companions' Box or Folder button). The parser was written "
          "before its first score and is scored as written.",
          f"- **{NAMES[gem]}** on this Mac, which drafted none of the truth, read blind with the final reading rules "
          "and a prompt whose every example is invented. Scored on every cell.",
          "- **The truth's three drafters** (Qwen3-VL 8B, Qwen3.5 4B, Gemini 3.7 Flash) are scored only on the owner's "
          "own cells, less their prompt's example fields (FLD-9). Those are the cells the three disagreed on, so the "
          "figures are on the hard cells, not a fair whole-set score.",
          "- **Not run:** the corpus PDFs' text layer (owner, 2026-10-30: no arm takes the ABBYY text as input; the "
          "item, filed on 2026-10-21, named it) and any plan route (root CLAUDE.md). The gateway arm is "
          "W47.ct-read-paid.", ""]
    c = S["cells"]
    L += [f"Cells scored: {c.get('owner', 0)} the owner's, {c.get('readers', 0)} the three readers' unanimous, "
          f"{c.get('rule', 0)} settled by the owner's rules (reported apart, P11-7). Out of every score: "
          + ", ".join(f"{n} {k[5:]}" for k, n in sorted(S["cells_out"].items())) + ".", ""]
    L += ["## Per field: the two routes that drafted nothing", "",
          "On the owner's and the unanimous cells. Accuracy with its 95% interval and the cell count; then, of the "
          "cells with a value, how many were read right, and of the empty ones, how many the route filled. The "
          f"gap is {NAMES[gem]} less Vision on the same cells, with a 95% bootstrap interval over photos; an "
          "interval across zero is a tie.", "",
          f"| field | Vision + parser | right of filled | filled when empty | {NAMES[gem]} | right of filled | "
          "filled when empty | gap |", "|---|---|---|---|---|---|---|---|"]
    for f in SCORED:
        v, g = S["routes"]["vision"][f].get("scored"), S["routes"][gem][f].get("scored")
        gp = S["gaps"].get(f)
        gs = "–" if not gp else f"{100 * gp['gap']:+.0f} ({100 * gp['ci'][0]:+.0f} to {100 * gp['ci'][1]:+.0f})"
        def fe(t):
            return ("–", "–") if not t else (f"{t['filled_right']}/{t['filled']}", f"{t['false_fill']}/{t['empty']}")
        L.append(f"| {CT.LABELS.get(f, f)} | {cell(v)} | {fe(v)[0]} | {fe(v)[1]} | {cell(g)} | {fe(g)[0]} | "
                 f"{fe(g)[1]} | {gs} |")
    L += ["", "### On the rule-settled cells, apart", "", f"| field | Vision + parser | {NAMES[gem]} |", "|---|---|---|"]
    for f in SCORED:
        r1, r2 = S["routes"]["vision"][f].get("rule"), S["routes"][gem][f].get("rule")
        if r1 or r2:
            L.append(f"| {CT.LABELS.get(f, f)} | {cell(r1)} | {cell(r2)} |")
    for k in PAID_RUN:
        pd, gp = S["paid"][k], S["gaps_paid"][k]
        def gs(x):
            return "–" if not x else f"{100 * x['gap']:+.0f} ({100 * x['ci'][0]:+.0f} to {100 * x['ci'][1]:+.0f})"
        L += ["", f"## Per field: the gateway arm, {NAMES[k]} (W47.ct-read-paid)", "",
              f"{NAMES[k]} drafted none of the truth, so like {NAMES[gem]} it is scored on the owner's and the "
              "unanimous cells, with the same prompt (invented examples) on the same upright photos. "
              f"{pd['ok']} of {pd['calls']} calls answered; ${pd['charged']:.4f} charged in all, real money on the "
              f"gateway (the larger of the token estimate at ${PAID[k][2][0]:.2f} / ${PAID[k][2][1]:.2f} a million "
              f"tokens and the gateway's own figure, which it gave on {pd['gateway_calls']} calls). The gaps are this "
              "arm less each other route on the same cells (95% bootstrap over photos).", "",
              f"| field | {NAMES[k]} | right of filled | filled when empty | less Vision | less {NAMES[gem]} |",
              "|---|---|---|---|---|---|"]
        for f in SCORED:
            t = S["routes"][k][f].get("scored")
            fe = ("–", "–") if not t else (f"{t['filled_right']}/{t['filled']}", f"{t['false_fill']}/{t['empty']}")
            L.append(f"| {CT.LABELS.get(f, f)} | {cell(t)} | {fe[0]} | {fe[1]} | {gs(gp[f]['vision'])} | "
                     f"{gs(gp[f][gem])} |")
        L += ["", f"On the owner's cells, {NAMES[k]} less {NAMES[CT.GATEWAY]} (a drafter, so only there, less its "
              "prompt's example fields): " + "; ".join(f"{CT.LABELS.get(f, f).lower()} {gs(gp[f][CT.GATEWAY])}"
                                                      for f in SCORED) + "."]
        rr = [(f, S["routes"][k][f].get("rule")) for f in SCORED if S["routes"][k][f].get("rule")]
        if rr:
            L += ["", "On the rule-settled cells, apart: " + "; ".join(f"{CT.LABELS.get(f, f).lower()} {cell(t)}"
                                                                     for f, t in rr) + "."]
    L += ["", "## Per field: the owner's own cells, every route", "",
          "The cells the three drafters split on, which the owner ruled: the hard cells. Every route on the same "
          "cells, less each row's prompt-example fields for the drafters.", "",
          "| field | " + " | ".join(NAMES[k] for k in ROUTES) + " |", "|---|" + "---|" * len(ROUTES)]
    for f in SCORED:
        L.append(f"| {CT.LABELS.get(f, f)} | " + " | ".join(cell(S["routes"][k][f].get("owner")) for k in ROUTES) + " |")
    L += ["", "Paired gaps on the owner's cells, each drafter less " + NAMES[gem] + " (95% bootstrap over photos):", "",
          "| field | " + " | ".join(NAMES[d] for d in DRAFTERS) + " |", "|---|" + "---|" * len(DRAFTERS)]
    for f in SCORED:
        row = []
        for d in DRAFTERS:
            gp = S["gaps_owner"][d].get(f)
            row.append("–" if not gp else f"{100 * gp['gap']:+.0f} ({100 * gp['ci'][0]:+.0f} to {100 * gp['ci'][1]:+.0f})")
        L.append(f"| {CT.LABELS.get(f, f)} | " + " | ".join(row) + " |")
    L += ["", f"Replies that did not parse: " + ", ".join(f"{NAMES[k]} {n}" for k, n in S["unparsed"].items()) + ".", ""]
    if T:
        L += ["## Route B: the folder-tree name patterns", "",
              f"On the synthetic tree set (`ct_trees.json`, {T['trees']} trees, {T['files']} files in the plan's "
              f"naming conventions): the pre-filled level map was right for {T['maps_right']} of {T['trees']} trees, "
              "and per field:", "", "| field | right | cells |", "|---|---|---|"]
        for f, t in T["fields"].items():
            L.append(f"| {CT.LABELS.get(f, f)} | {pc(t['acc'])} | {t['n']} |")
        o = T["owner_tree"]
        L += ["", "That set was written to the conventions the patterns cover, and the patterns were written after its "
              "list of conventions was seen, so a perfect score says the patterns cover the conventions; it is not a "
              "measure on a stranger's tree. The owner's own tree is the real case. Its names are informal, so the "
              "patterns recognise little of it and the level map rests on the user's confirmation (the design's "
              "once-per-root sheet), as the plan expected:", "",
              f"- Level 1 (the tree as listed by W47.ct-truth on 2026-10-29), {o['level1_names']} names over {o['pdfs']:,} PDFs: " +
              ", ".join(f"{k} {n:,}" for k, n in sorted(o["level1_pdfs"].items(), key=lambda x: -x[1])) +
              " PDFs (names: " + ", ".join(f"{k} {n}" for k, n in o["level1_names_by_class"].items()) + ").",
              "- Level 2, in PDFs: " + ", ".join(f"{k} {n:,}" for k, n in sorted(o["level2_pdfs"].items(),
                                                                                    key=lambda x: -x[1])) + ".", ""]
    if C:
        rs, pv = C["red_steps"], C["purple_vs_box"]
        L += ["## Carry-forward, on the corpus", "",
              f"Every single-colour marker in the corpus: {C['markers'].get('Red', 0):,} Red and "
              f"{C['markers'].get('Purple', 0):,} Purple in {C['directories']} directories ({C['dirs_with_markers']} "
              f"with a marker, {C['dirs_with_red']} with a box photo); {C['with_jpeg'].get('Red', 0):,} and "
              f"{C['with_jpeg'].get('Purple', 0):,} have a paired JPEG original, which is what was read (Vision "
              "+ parser, at the EXIF turn and then the other three until a number reads).", "",
              "| what Vision read | photos |", "|---|---|"]
        L += [f"| {k} | {n:,} |" for k, n in sorted(C["read"].items())]
        n_steps = sum(rs.values())
        L += ["", f"From one box photo to the next in a directory, where both read a box number ({n_steps} steps):", "",
              "| step | count | share |", "|---|---|---|"]
        L += [f"| {k} | {n} | {pc(n / n_steps)} |" for k, n in sorted(rs.items(), key=lambda x: -x[1])]
        n_pv = sum(pv.values())
        L += ["", f"A folder label that reads a box number ({n_pv:,} Purple photos), against the last box photo before "
              "it in its directory:", "", "| folder's box | count | share |", "|---|---|---|"]
        L += [f"| {k} | {n:,} | {pc(n / n_pv)} |" for k, n in sorted(pv.items(), key=lambda x: -x[1])]
        vp = C["vision_box_precision"]
        L += ["", f"How far a read box number can be trusted: on the truth set, where Vision + parser gives a container "
              f"it is right on {vp['Red']['right']} of {vp['Red']['given']} box photos and {vp['Purple']['right']} of "
              f"{vp['Purple']['given']} folder photos. A folder giving another box than the box photo before it is a "
              "box change with no box photo, or a misread of either photo. "
              "Boxes skipped are most likely boxes not requested, not missed photos. Box photos are so rarely misread "
              "that a lower number is, nearly always, a box photographed out of numeric order.", ""]
        ps = C["purple_sample"]
        n = sum(ps.values())
        L += ["## What Purple marks", "", f"The truth sample's Purple photos as drawn ({n}, stratified by repository; "
              "the owner's rulings and the photos he took out, with his reason):", "",
              "| what it is | photos | share |", "|---|---|---|"]
        L += [f"| {k} | {v} | {pc(v / n)}{'' if not v else ''} |" for k, v in sorted(ps.items(), key=lambda x: -x[1])]
        L.append("")
    sp = corpus_speed()
    gsp = S["speed"].get(gem, {})
    n_marks = sum(C["markers"].values()) if C else 4399
    L += ["## Speed and the price of the corpus's markers", "",
          f"The corpus holds {n_marks:,} single-colour markers."]
    if sp:
        L.append(f"- Vision + parser: the corpus's {sp[0]:,} paired markers at the EXIF turn in {sp[1] / 60:.0f} "
                 f"minutes on this Mac, {sp[1] / max(sp[0], 1):.2f} s a photo, rendering the JPEG included; $0. "
                 "Trying the other turns where no number read roughly doubled it.")
    if gsp:
        L.append(f"- {NAMES[gem]}: median {gsp['median_s']} s a photo (mean {gsp['mean_s']}), peak "
                 f"{gsp['peak_gb']} GB; the corpus's markers in about {n_marks * gsp['mean_s'] / 3600:.1f} hours; $0.")
    for k in PAID_RUN:
        pd = S["paid"][k]
        if pd["per_photo"]:
            L.append(f"- {NAMES[k]}: ${pd['per_photo']:.5f} a photo charged on its {pd['ok']} truth photos (median "
                     f"{pd['prompt_tokens_median']:,} tokens in, {pd['completion_tokens_median']:,} out, reasoning "
                     f"included; median {pd['median_s']} s a call, four at once), so about "
                     f"${n_marks * pd['per_photo']:.2f} for the corpus's markers.")
    L += [f"- Gemini 3.7 Flash through the gateway (the truth's third reader, for W47.ct-read-paid's price): "
          f"$0.0023 a photo measured on the truth build's 215 calls, so about ${n_marks * 0.0023:.0f} for the "
          "corpus: over the $7 line, so a full backfill read asks the owner first.", "",
          "Timings were taken inside an engine session, which macOS runs at background priority; such timings have "
          "measured several times slower than an interactive run, so read them as upper bounds.", ""]
    if C:
        vp, rs = C["vision_box_precision"]["Red"], C["red_steps"]
        low = rs.get("lower number", 0) / max(sum(rs.values()), 1)
        kind = S["routes"]["vision"]["kind"]["scored"]
        acc_v, acc_g = S["routes"]["vision"]["accession"]["scored"], S["routes"][gem]["accession"]["scored"]
        acc_gap = S["gaps"]["accession"]
        acc_gs = f"{100 * acc_gap['gap']:+.0f} ({100 * acc_gap['ci'][0]:+.0f} to {100 * acc_gap['ci'][1]:+.0f})"
        fp = C["vision_box_precision"]["Purple"]
        f_wrong = fp["given"] - fp["right"]
        f_ci = wilson(f_wrong, fp["given"])
        pv = C["purple_vs_box"]
        comparable = pv.get("same box as the box photo before it", 0) + pv.get("another box than the box photo before it", 0)
        disagree = pv.get("another box than the box photo before it", 0)
        red_turns = {k: n for k, n in C["turns"].items() if k.startswith("Red ") and k != "Red None"}
        red_read, red_other = sum(red_turns.values()), sum(n for k, n in red_turns.items() if k != "Red 0")
        L += ["## What it recommends, per field (for W47.ct-design-ok)", "",
              "Free routes only; W47.ct-read-paid adds the gateway arm before the design review. On the hard cells "
              "the owner ruled, Gemini 3.7 Flash is ahead of every free route on almost every field, but those are "
              "the cells where the drafters split, and choosing them favours the strongest drafter rather than "
              "handicapping it. The paid arm (W47.ct-read-paid) confirms it on the owner's cells (FLD-9), not on the "
              f"whole set: Gemini 3.7 co-drafted the {S['cells'].get('readers', 0):,} unanimous cells, so a whole-set "
              "figure for it would be "
              "agreement with itself.", "",
              f"- **What the photo is:** the marker's colour (the Box or Folder button), right on {kind['right']} of "
              f"{kind['n']}; no reader is needed, and Gemma's own call is worse.",
              "- **Container and folder number:** Vision + parser. It ties Gemma on both, takes a fraction of the "
              f"time, and on a box photo the box number it gives is right {vp['right']} of {vp['given']} times. It "
              "misses about a quarter of the box numbers that are there, so the capture card asks when it reads none.",
              "- **Repository, collection title, collection number, date:** Gemma 3 12B, ahead of Vision + parser on "
              "each with an interval above zero, but still wrong or empty on a third to a half of the filled cells: "
              "proposed values the user confirms once per run, not facts.",
              "- **Series, series title:** Vision + parser; they are anchored by their keyword, and Gemma's "
              "difference is a tie.",
              f"- **Accession:** not a tie: Gemma less Vision is {acc_gs}, an interval clear of zero. But Vision's "
              f"lead comes from leaving the field empty: it reads {acc_v['filled_right']} of the {acc_v['filled']} "
              "accessions present, the same pattern as the fields below, while Gemma fills an accession where there is "
              f"none ({acc_g['false_fill']} of {acc_g['empty']}).",
              "- **Collection subtitle, box title, other identifying marks, folder title:** no free route reads them. "
              "Vision's high accuracy on the first three comes from leaving them empty, and Gemma fills them where "
              "there is nothing. Leave them to the user, or to the paid arm if it reads them.",
              "- **Route B:** the name patterns cover every convention the plan names; the owner's informal names need "
              "the once-per-root level-map sheet, as designed.",
              f"- **Carry-forward:** box photos come in no fixed order. {pc(low)} of the steps between box photos go to "
              "a lower number, and box photos are rarely misread, so the plan's warning \"a box number goes "
              "backwards\" would fire on about one step in four; it should not be a warning. Nor is a folder label "
              "that names its box a check on the run as measured: Vision's box read on folder photos is right on "
              f"{fp['right']} of {fp['given']} on the truth set (5 another number, 2 a box where there is none), "
              f"{f_wrong} wrong with a Wilson interval of {f_ci[0]:.2f} to {f_ci[1]:.2f}. Only {comparable:,} folder "
              "reads can be compared with a box photo before them, so about "
              f"{comparable * f_wrong / fp['given']:.0f} misreads ({comparable * f_ci[0]:.0f} to "
              f"{comparable * f_ci[1]:.0f}) are expected among them, against {disagree} disagreements observed: a "
              "flag on disagreement would mostly fire on misreads.",
              "- **Purple:** a folder label for nearly all of the drawn photos; two were \"No Folder\" sheets and one "
              "a document page. Purple can be taken as a folder start, with \"No Folder\" sheets recognised by their "
              "text.",
              "- **The corpus's markers:** Vision + parser reads them all in minutes for $0, Gemma in most of a day for "
              "$0; Gemini would cost about $10, over the $7 line.", ""]
    L += ["## Measurement card", "",
          "- **Truth:** W47.ct-truth-final's: the owner's answers on three sheets and his notes, his rules applied to "
          "the readers' readings (reported apart), and for the rest the three drafters unanimous. Drafters are scored "
          "only on the owner's cells, less prompt examples; the routes that drafted nothing on every cell. The "
          "truth's checks: 0 of 20 reader-unanimous controls overturned on the second sheet (upper bound about "
          f"{100 * wilson(0, 20)[1]:.0f}%) and 0 of 10 rule-settled ones on the third (about "
          f"{100 * wilson(0, 10)[1]:.0f}%).",
          "- **Selection:** the truth build's stratified draw by repository (square-root allocation, a floor of two), "
          "less the photos the owner took out. The pairing cut's lean stands beside every figure here (P10-6): 54 "
          "photos left out, 43 of them Red, toward little-changed PDFs. The sample is not weighted to the corpus, so "
          "a figure is the sample's.",
          "- **Comparison:** every route on the same upright photos; Vision lines are the truth build's (the reread "
          "photos' own lines for the 15 reread). Same cells for every paired gap.",
          "- **Noise:** one pass at temperature 0; Wilson intervals on each figure, bootstrap intervals over photos "
          "on each gap; no rerun floor was measured, so a gap near zero is a tie.",
          "- **Scope:** the routes on this sample of one researcher's photos; the tree patterns on a synthetic set "
          "and the owner's names; carry-forward measured with Vision's own misreads mixed in. It settles no design: "
          "that is W47.ct-design-ok."]
    if C:
        vp = C["vision_box_precision"]["Red"]
        L[-1] += (f" The carry-forward's {vp['right']} of {vp['given']} box-number precision is on the truth set's "
                  f"upright photos, while {red_other} of the {red_read} Red reads on the corpus came from another turn "
                  "than the EXIF one, which the truth set does not test.")
    L += [""]
    if first:
        L += [f"The Vision parser's score is its first pass (`score-vision-firstpass.json` in the cache)."]
    open(RESULTS, "w", encoding="utf-8").write("\n".join(L) + "\n")
    print(RESULTS)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--model", required=True, choices=sorted(MODELS))
    c.add_argument("--limit", type=int, default=0)
    g = sub.add_parser("gateway")
    g.add_argument("--model", required=True, choices=sorted(PAID))
    g.add_argument("--limit", type=int, default=0)
    for name in ("score", "trees", "corpus-lines", "corpus", "report"):
        sub.add_parser(name)
    a = ap.parse_args()
    {"collect": cmd_collect, "gateway": cmd_gateway, "score": cmd_score, "trees": cmd_trees, "corpus-lines": cmd_corpus_lines,
     "corpus": cmd_corpus, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    main()
