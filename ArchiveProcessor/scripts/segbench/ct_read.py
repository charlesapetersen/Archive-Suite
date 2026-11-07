#!/usr/bin/env python3
"""W47.ct-read: reading the box and folder labels and the folder trees, scored per field.

    heavy-run.py run -- <lab venv>/bin/python ct_read.py collect --model gemma3-12b-mlx4   # a fresh open reader
    python3 ct_read.py score                 # the label routes against the truth, per field
    python3 ct_read.py trees                 # the Route B name patterns on ct_trees.json and the owner's tree
    heavy-run.py run -- python3 ct_read.py corpus-lines   # Vision lines on every Red marker's JPEG original
    python3 ct_read.py corpus                # carry-forward and Purple's meaning, measured on the corpus
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
NAMES = {**CT.NAMES, "vision": "Apple Vision (accurate) + parser", **{k: v[1] for k, v in MODELS.items()}}
ROUTES = ["vision", *MODELS, *DRAFTERS]
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
    if route in MODELS:
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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--model", required=True, choices=sorted(MODELS))
    c.add_argument("--limit", type=int, default=0)
    for name in ("score", "trees"):
        sub.add_parser(name)
    a = ap.parse_args()
    {"collect": cmd_collect, "score": cmd_score, "trees": cmd_trees}[a.cmd](a)


if __name__ == "__main__":
    main()
