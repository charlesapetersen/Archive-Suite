#!/usr/bin/env python3
"""W47.ct-truth: the container-label truth set, the owner's disagreement sheet and a folder-tree test set.

    python3 ct_truth.py sample                      # ~120 box + ~120 folder marker photos, stratified by repository
    python3 ct_truth.py render                      # each photo's page as JPEG into the cache (sips, read-only)
    python3 ct_truth.py lines                       # Apple Vision text lines with boxes (layout_order.py's helper)
    run-guarded.sh --label ct-truth --need-gb 8 -- <lab venv>/bin/python ct_truth.py collect --model K
    python3 ct_truth.py compare                     # segbench-results/ct-truth.md; the owner's sheet; draft truth
    python3 ct_truth.py fold ANSWERS.json           # the owner's answers -> pool/truth.jsonl (W47.ct-read's truth)
    python3 ct_truth.py trees                       # writes ct_trees.json, the synthetic Route B set (committed)
    python3 ct_truth.py owner-tree                  # the corpus's level-1 and level-2 names, private, in the cache

<lab venv> is ~/.local/share/visionocr-ocrlab/venv (mlx_vlm 0.7.4). --model is a key of MODELS; both are run.

The corpus is read, never written: tags with getxattr(2) (corpus_survey.read_tags), pages with sips into the
cache. A marker is a Red (box) or Purple (folder) photo; the seven carrying both are left out. The stratum is the
level-1 directory, which names the repository, or level 2 under a workflow folder ("05 Final Tagging",
"03 Unconverted…"). There level 2 turned out to be a priority folder ("5 Priority 5") or "Re-OCR", with the
collection below it and no repository level at all, so those strata are flagged `workflow` and stand for no
repository. Each class is allocated across strata with a floor of two, the rest in proportion to the square root of the marker count,
so the large Harvard and Stanford sets do not swamp the small repositories; inside a repository the photos are
drawn round-robin across collection directories with a fixed seed.

Two open models on this Mac (temperature 0, $0, no network once cached, no plan route) each read every photo blind
into the nine fields of execution-plans/containers/00-plan.md, plus what the photo is (box label, folder label,
divider or other, document page) and the label's region. A field is agreed when both give the same value after
normalising case, punctuation and the "Box No."/"Box" spellings; both empty is agreed too. Agreed values are the
draft truth; the owner's sheet lists only the disputed fields, with a box around each one's place on the photo:
the Vision lines matching either reading, else the label region a model gave, else the sheet says so. The
readings are shown in a fixed shuffled order with no model names, and a box never says which reading it matched.
"""
import argparse
import collections
import difflib
import hashlib
import json
import math
import os
import random
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import corpus_survey as CS

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/ct-truth")
POOL = os.path.join(CACHE, "pool")
PAGES = os.path.join(POOL, "pages")
LINES = os.path.join(POOL, "lines")
SHEET = os.path.join(POOL, "sheet")
SAMPLE = os.path.join(POOL, "sample.jsonl")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "ct-truth.md")
TREES = os.path.join(HERE, "ct_trees.json")
OWNER_TREE = os.path.join(POOL, "owner-tree.json")

PER_CLASS = 120
FLOOR = 2
SEED = 4701
MAX_SIDE = 1280
MAX_TOKENS = 420
WORKFLOW = re.compile(r"^\d\d ")  # "05 Final Tagging", "03 Unconverted (…)": the repository is one level down

MODELS = {"qwen3-vl-8b-mlx4": ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "Qwen3-VL 8B, 4-bit MLX", 8),
          "qwen3.5-4b-mlx4": ("lmstudio-community/Qwen3.5-4B-MLX-4bit", "Qwen3.5 4B, 4-bit MLX", 5)}
FIRST = "qwen3-vl-8b-mlx4"   # the agreed value is taken from this reader's spelling

FIELDS = ["repository", "place", "collection_title", "collection_number", "accession", "series", "container",
          "folder", "folder_title"]
LABELS = {"repository": "Repository", "place": "Place", "collection_title": "Collection title",
          "collection_number": "Collection number", "accession": "Accession", "series": "Series",
          "container": "Container (box, carton…)", "folder": "Folder number", "folder_title": "Folder title",
          "kind": "What the photo is"}
KINDS = ["box label", "folder label", "divider or other", "document page"]

PROMPT = (
    "This photo was taken in an archive reading room. It may show a box label, a folder label or tab, a divider "
    "sheet, or a page of a document. Read what is written on the label, if there is one, into these fields. Use "
    "null for anything not written there; do not guess from general knowledge. Reply with JSON only:\n"
    "{\"kind\": one of \"box label\", \"folder label\", \"divider or other\", \"document page\",\n"
    " \"repository\": the archive or library, e.g. \"Hoover Institution Archives\",\n"
    " \"place\": the city or state of the repository if written,\n"
    " \"collection_title\": e.g. \"Irving Kristol Papers, 1946-2001\",\n"
    " \"collection_number\": a call or collection number, e.g. \"Mss 1036\", \"SC0122\", \"RG 165\",\n"
    " \"accession\": an accession number, e.g. \"91006-10.V\",\n"
    " \"series\": e.g. \"Series II, Manuscripts\",\n"
    " \"container\": the container type and number exactly as written, e.g. \"Box 17\", \"Carton 9\",\n"
    " \"folder\": the folder number, e.g. \"8\",\n"
    " \"folder_title\": the folder's title, e.g. \"Reports 1959-1960\",\n"
    " \"label_box\": [x1, y1, x2, y2] the label's region on a 0-1000 scale, or null}")


# --- sampling ---------------------------------------------------------------------------------------------------

def repository_of(folder):
    parts = folder.split(os.sep)
    if WORKFLOW.match(parts[0]) and len(parts) > 1:
        return parts[1]
    return parts[0]


def collection_dir(folder):
    parts = folder.split(os.sep)
    k = 3 if WORKFLOW.match(parts[0]) else 2
    return os.sep.join(parts[:k])


def allocate(counts, total, floor=FLOOR):
    """{stratum: n} for `total` draws: a floor each, the rest by the square root of the count, never over a count."""
    alloc = {k: min(c, floor) for k, c in counts.items()}
    left = total - sum(alloc.values())
    while left > 0:
        room = {k: math.sqrt(c) for k, c in counts.items() if alloc[k] < c}
        if not room:
            break
        weight = sum(room.values())
        # largest remainder, one at a time, so the sum is exact and no stratum passes its count
        want = {k: total * w / weight for k, w in room.items()}
        k = max(room, key=lambda s: (want[s] - alloc[s], s))
        alloc[k] += 1
        left -= 1
    return alloc


def draw(rows, n, rng):
    """n rows round-robin across collection directories (each shuffled), so one collection cannot fill a stratum."""
    by = collections.defaultdict(list)
    for r in rows:
        by[r["collection"]].append(r)
    groups = [by[k] for k in sorted(by)]
    for g in groups:
        rng.shuffle(g)
    rng.shuffle(groups)
    out = []
    while len(out) < n and any(groups):
        for g in groups:
            if g and len(out) < n:
                out.append(g.pop())
    return out


def marker_id(path):
    return hashlib.sha1(path.encode("utf-8")).hexdigest()[:12]


def cmd_sample(a):
    rows = []
    for folder, names in CS.walk(CS.CORPUS):
        for i, n in enumerate(names):
            got = set(CS.read_tags(os.path.join(CS.CORPUS, folder, n))) & CS.LABEL_COLOURS
            if len(got) != 1:
                continue
            rel = os.path.join(folder, n)
            rows.append({"id": marker_id(rel), "path": rel, "colour": got.pop(), "position": i, "of": len(names),
                         "repository": repository_of(folder), "collection": collection_dir(folder),
                         "workflow": bool(WORKFLOW.match(folder.split(os.sep)[0]))})
    rng = random.Random(SEED)
    picked = []
    for colour in ("Red", "Purple"):
        mine = [r for r in rows if r["colour"] == colour]
        counts = collections.Counter(r["repository"] for r in mine)
        alloc = allocate(counts, a.per_class)
        for rep in sorted(alloc):
            picked += draw([r for r in mine if r["repository"] == rep], alloc[rep], rng)
    os.makedirs(POOL, exist_ok=True)
    with open(SAMPLE, "w", encoding="utf-8") as fh:
        for r in picked:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    c = collections.Counter(r["colour"] for r in picked)
    print(f"{len(rows)} single-colour markers; sampled {c['Red']} Red, {c['Purple']} Purple across "
          f"{len({r['repository'] for r in picked})} strata; {SAMPLE}")


def sample():
    return [json.loads(l) for l in open(SAMPLE, encoding="utf-8")]


def image_of(mid):
    return os.path.join(PAGES, mid + ".jpg")


def cmd_render(a):
    os.makedirs(PAGES, exist_ok=True)
    bad = 0
    for r in sample():
        out = image_of(r["id"])
        if not os.path.exists(out):
            subprocess.run(["sips", "-s", "format", "jpeg", "-Z", str(MAX_SIDE), os.path.join(CS.CORPUS, r["path"]),
                            "--out", out], capture_output=True, check=False)
        bad += not os.path.exists(out)
    print(f"{len(sample())} photos, {bad} not rendered; {PAGES}")


def cmd_lines(a):
    import layout_order as LO
    LO.build_helper()
    os.makedirs(LINES, exist_ok=True)
    args = []
    for r in sample():
        out = os.path.join(LINES, r["id"] + ".json")
        if os.path.exists(image_of(r["id"])) and not os.path.exists(out):
            args += [image_of(r["id"]), out]
    for k in range(0, len(args), 80):
        subprocess.run([str(LO.HELPER), "lines", *args[k:k + 80]], check=True)
    print(f"{len(args) // 2} photos read; {LINES}")


def lines_of(mid):
    p = os.path.join(LINES, mid + ".json")
    return json.load(open(p, encoding="utf-8")).get("lines", []) if os.path.exists(p) else []


# --- the drafts -------------------------------------------------------------------------------------------------

def draft_dir(key):
    return os.path.join(POOL, "draft", key)


def cmd_collect(a):
    import mlx.core as mx
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    os.environ.setdefault("HF_HOME", os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/mlx-hf"))
    out = draft_dir(a.model)
    os.makedirs(out, exist_ok=True)
    todo = [r["id"] for r in sample() if os.path.exists(image_of(r["id"]))
            and not os.path.exists(os.path.join(out, r["id"] + ".json"))][: a.limit or None]
    print(f"{a.model}: {len(todo)} photos to read", flush=True)
    if not todo:
        return
    mx.set_cache_limit(256 * 2**20)
    model, processor = load(MODELS[a.model][0])
    try:  # Qwen3.5 thinks unless told not to; Qwen3-VL's template takes no such switch
        chat = apply_chat_template(processor, model.config, PROMPT, num_images=1, enable_thinking=False)
    except TypeError:
        chat = apply_chat_template(processor, model.config, PROMPT, num_images=1)
    for k, mid in enumerate(todo, 1):
        start, text, last = time.time(), [], None
        for r in stream_generate(model, processor, chat, image=[image_of(mid)], max_tokens=MAX_TOKENS, temperature=0.0):
            text.append(r.text)
            last = r
        raw = re.sub(r"<think>.*?</think>", "", "".join(text), flags=re.S)
        rec = {"id": mid, "raw": raw, "parsed": parse(raw), "wall_s": round(time.time() - start, 2),
               "tokens": [getattr(last, "prompt_tokens", 0), getattr(last, "generation_tokens", 0)]}
        with open(os.path.join(out, mid + ".json"), "w", encoding="utf-8") as fh:
            json.dump(rec, fh, ensure_ascii=False)
        print(f"[{k}/{len(todo)}] {mid} {rec['wall_s']}s {'ok' if rec['parsed'] else 'unparsed'}", flush=True)


def clean(v):
    if v is None:
        return None
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        v = str(int(v)) if float(v).is_integer() else str(v)
    if not isinstance(v, str):
        return None
    v = re.sub(r"\s+", " ", v).strip()
    return None if v.lower() in ("", "null", "none", "n/a", "unknown", "not visible", "-") else v


def parse(raw):
    """The reply's fields, every one a cleaned string or None, `kind` one of KINDS or None, `label_box` or None."""
    m = re.search(r"\{.*\}", raw or "", re.S)
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
    except ValueError:
        return None
    if not isinstance(d, dict):
        return None
    out = {f: clean(d.get(f)) for f in FIELDS}
    k = clean(d.get("kind"))
    out["kind"] = k.lower() if k and k.lower() in KINDS else None
    out["label_box"] = box_of(d.get("label_box"))
    return out


def box_of(b):
    """[x, y, w, h] fractions of the photo from a 0-1000 [x1, y1, x2, y2], or None when malformed."""
    try:
        x1, y1, x2, y2 = (float(v) for v in b)
    except (TypeError, ValueError):
        return None
    if not (0 <= x1 < x2 <= 1000 and 0 <= y1 < y2 <= 1000):
        return None
    return [round(x1 / 1000, 4), round(y1 / 1000, 4), round((x2 - x1) / 1000, 4), round((y2 - y1) / 1000, 4)]


def draft_of(mid, key):
    p = os.path.join(draft_dir(key), mid + ".json")
    return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else None


# --- agreement ----------------------------------------------------------------------------------------------------

CONTAINER = re.compile(r"\b(box|carton|folio|volume|vol|reel|drawer|oversize|flat\s*file|bin|case|item)\b\.?"
                       r"\s*(?:no\.?|number|#)?\s*([0-9]+[a-z]?)", re.I)


def norm(field, v):
    """The comparable form of a value: case, punctuation and spacing dropped; containers as (type, number)."""
    if v is None:
        return None
    s = v.lower()
    if field == "container":
        m = CONTAINER.search(s)
        if m:
            kind = {"vol": "volume"}.get(m.group(1).lower(), re.sub(r"\s+", "", m.group(1).lower()))
            return f"{kind} {m.group(2).lower()}"
        bare = re.fullmatch(r"\s*(?:no\.?|#)?\s*(\d+[a-z]?)\s*", s)
        if bare:  # a bare number is read as a box, the usual container
            return f"box {bare.group(1)}"
    if field == "folder":
        s = re.sub(r"\b(folder|fol|fld|fd|f)\b\.?\s*(no\.?|#)?", "", s)
    s = s.replace("&", "and")
    return re.sub(r"[^a-z0-9]", "", s) or None


def agree(field, a, b):
    return norm(field, a) == norm(field, b)


def disputes(da, db):
    """The fields (and `kind`) on which two parsed drafts differ, in FIELDS order, `kind` first."""
    out = []
    if (da or {}).get("kind") != (db or {}).get("kind"):
        out.append("kind")
    for f in FIELDS:
        if not agree(f, (da or {}).get(f), (db or {}).get(f)):
            out.append(f)
    return out


# --- where each disputed field sits on the photo --------------------------------------------------------------

def _lnorm(s):
    return re.sub(r"[^a-z0-9 ]", "", s.lower()).strip()


def place_of(value, lines):
    """[x, y, w, h] around the Vision lines that carry `value`, or None. A line matches when it holds the value, the
    value holds it, or they are close (difflib ratio 0.75); a value spread over adjacent lines matches each part."""
    v = _lnorm(value or "")
    if len(v.replace(" ", "")) < 1:
        return None
    hits = []
    for ln in lines:
        t = _lnorm(ln.get("text", ""))
        if not t:
            continue
        short = len(v.replace(" ", "")) <= 3
        if short:  # a bare number: only a line where it stands as its own token
            ok = re.search(rf"(?<![a-z0-9]){re.escape(v)}(?![a-z0-9])", t) is not None
        else:
            ok = v in t or (len(t) >= 4 and t in v) or difflib.SequenceMatcher(None, v, t).ratio() >= 0.75
        if ok:
            hits.append(ln["box"])
    if not hits:
        return None
    x0 = min(b[0] for b in hits); y0 = min(b[1] for b in hits)
    x1 = max(b[2] for b in hits); y1 = max(b[3] for b in hits)
    pad = 0.01
    x0, y0, x1, y1 = max(0, x0 - pad), max(0, y0 - pad), min(1, x1 + pad), min(1, y1 + pad)
    return [round(x0, 4), round(y0, 4), round(x1 - x0, 4), round(y1 - y0, 4)]


def field_place(field, readings, lines, label_boxes):
    """(box, how): the matched lines for any reading, else a model's label region, else (None, 'none')."""
    boxes = [b for b in (place_of(r, lines) for r in readings if r) if b]
    if field != "kind" and boxes:
        x0 = min(b[0] for b in boxes); y0 = min(b[1] for b in boxes)
        x1 = max(b[0] + b[2] for b in boxes); y1 = max(b[1] + b[3] for b in boxes)
        return [round(x0, 4), round(y0, 4), round(x1 - x0, 4), round(y1 - y0, 4)], "lines"
    for b in label_boxes:
        if b:
            return b, "label"
    return None, "none"


# --- compare, sheet, fold -----------------------------------------------------------------------------------------

def order_readings(mid, field, vals):
    """The two readings in an order fixed by the photo and field, not by which model gave them; one when equal."""
    uniq = []
    for v in vals:
        if not any(agree(field if field != "kind" else "x", v, u) for u in uniq):
            uniq.append(v)
    flip = int(hashlib.sha1(f"{mid}/{field}".encode()).hexdigest(), 16) & 1
    return uniq[::-1] if flip else uniq


def build(rows, keys=(FIRST, "qwen3.5-4b-mlx4")):
    """Per photo: both drafts, the agreed fields, and the disputed ones with their readings and place."""
    out = []
    for r in rows:
        ra, rb = draft_of(r["id"], keys[0]), draft_of(r["id"], keys[1])
        da, db = (ra or {}).get("parsed"), (rb or {}).get("parsed")
        rec = dict(r, drafted=[ra is not None, rb is not None], parsed=[da is not None, db is not None],
                   agreed={}, disputed=[], wall_s=[(ra or {}).get("wall_s"), (rb or {}).get("wall_s")])
        if da is None or db is None:
            out.append(rec)
            continue
        lines = lines_of(r["id"])
        for f in ["kind"] + FIELDS:
            if f in disputes(da, db):
                vals = order_readings(r["id"], f, [da.get(f), db.get(f)])
                box, how = field_place(f, vals, lines, [da.get("label_box"), db.get("label_box")])
                rec["disputed"].append({"field": f, "readings": vals, "box": box, "placed": how})
            else:
                rec["agreed"][f] = da.get(f)
        out.append(rec)
    return out


def cmd_compare(a):
    rows = build(sample())
    os.makedirs(POOL, exist_ok=True)
    with open(os.path.join(POOL, "draft-truth.jsonl"), "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    write_sheet(rows)
    write_results(rows)
    print(f"{RESULTS}; sheet {os.path.join(SHEET, 'index.html')}")


def sheet_items(rows):
    out = []
    for n, r in enumerate((r for r in rows if r["disputed"]), 1):
        out.append({"id": r["id"], "n": n, "img": os.path.relpath(image_of(r["id"]), SHEET),
                    "colour": "box (Red)" if r["colour"] == "Red" else "folder (Purple)",
                    "agreed": {f: v for f, v in r["agreed"].items() if v},
                    "fields": [{"field": d["field"], "label": LABELS[d["field"]], "readings": d["readings"],
                                "box": d["box"], "placed": d["placed"]} for d in r["disputed"]]})
    return out


def write_sheet(rows):
    os.makedirs(SHEET, exist_ok=True)
    with open(os.path.join(SHEET, "index.html"), "w", encoding="utf-8") as fh:
        fh.write(SHEET_HTML.replace("__DATA__", json.dumps(sheet_items(rows), ensure_ascii=False))
                 .replace("__KINDS__", json.dumps(KINDS)))


def fold(rows, answers):
    """W47.ct-read's truth: per photo, the agreed fields, then each disputed field as the owner answered it.
    An answer is {"pick": "<a reading>" | "other" | "not on the label", "text": "<typed value>"}; an unanswered
    disputed field stays out of the truth and is counted. Returns (truth rows, unanswered count)."""
    truth, missing = [], 0
    for r in rows:
        if not all(r["parsed"]):
            continue
        fields = dict(r["agreed"])
        for d in r["disputed"]:
            ans = (answers.get(r["id"]) or {}).get(d["field"])
            if not ans or not ans.get("pick"):
                missing += 1
                continue
            pick = ans["pick"]
            if pick == "not on the label":
                fields[d["field"]] = None
            elif pick == "other":
                fields[d["field"]] = clean(ans.get("text"))
            else:
                fields[d["field"]] = pick
        truth.append({"id": r["id"], "path": r["path"], "colour": r["colour"], "stratum": r["repository"],
                      "fields": fields, "complete": len(fields) == len(FIELDS) + 1})
    return truth, missing


def cmd_fold(a):
    rows = [json.loads(l) for l in open(os.path.join(POOL, "draft-truth.jsonl"), encoding="utf-8")]
    truth, missing = fold(rows, json.load(open(a.answers, encoding="utf-8")))
    with open(os.path.join(POOL, "truth.jsonl"), "w", encoding="utf-8") as fh:
        for t in truth:
            fh.write(json.dumps(t, ensure_ascii=False) + "\n")
    print(f"{len(truth)} photos in the truth, {sum(t['complete'] for t in truth)} complete; "
          f"{missing} disputed fields unanswered")


def write_results(rows):
    drafted = [r for r in rows if all(r["parsed"])]
    unparsed = [r for r in rows if not all(r["parsed"])]
    by_class = {c: [r for r in drafted if r["colour"] == c] for c in ("Red", "Purple")}
    lines_n = sum(1 for r in rows if lines_of(r["id"]))
    L = ["# Container labels: the truth set's two-reader draft (W47.ct-truth)", "",
         f"Written by `scripts/segbench/ct_truth.py compare`. {len(rows)} marker photos from the corpus (read-only; "
         f"pages copied as JPEG at {MAX_SIDE} px), stratified by repository (floor {FLOOR}, then by the square root "
         f"of each repository's marker count, round-robin across collection directories, seed {SEED}). Each was read "
         f"blind into the nine fields of `execution-plans/containers/00-plan.md` plus what the photo is, by "
         f"{MODELS[FIRST][1]} and {MODELS['qwen3.5-4b-mlx4'][1]} (this Mac, temperature 0, $0, no plan route). "
         f"A field is agreed when both readings match after case, punctuation and \"Box No.\" spellings are "
         f"normalised; both empty counts as agreed. Agreement is not truth: two readers can make the same miss, "
         f"and the owner sees only the disputes.", "",
         f"Drafted by both: {len(drafted)}; a reply that did not parse: {len(unparsed)}. Apple Vision lines for "
         f"the sheet's boxes: {lines_n} photos.", "",
         "## Strata in the sample", "",
         "A stratum is the repository's directory, except under a workflow folder, where the level below it is a "
         "priority folder or Re-OCR and the corpus has no repository level (marked *workflow*).", "",
         "| stratum | box (Red) | folder (Purple) |", "|---|---|---|"]
    reps = collections.Counter((r["repository"], r["colour"]) for r in rows)
    wf = {r["repository"] for r in rows if r.get("workflow")}
    for rep in sorted({r["repository"] for r in rows}):
        L.append(f"| {rep}{' (*workflow*)' if rep in wf else ''} | {reps[(rep, 'Red')]} | {reps[(rep, 'Purple')]} |")
    L += ["", "## Agreement per field", "",
          "Disputed / with a value from both readers agreed / both empty, out of the photos both drafted.", "",
          "| field | box: disputed | box: agreed, a value | box: agreed, empty | folder: disputed | "
          "folder: agreed, a value | folder: agreed, empty |", "|---|---|---|---|---|---|---|"]
    for f in ["kind"] + FIELDS:
        cells = []
        for c in ("Red", "Purple"):
            rs = by_class[c]
            dis = sum(any(d["field"] == f for d in r["disputed"]) for r in rs)
            val = sum(f in r["agreed"] and r["agreed"][f] is not None for r in rs)
            emp = sum(f in r["agreed"] and r["agreed"][f] is None for r in rs)
            cells += [str(dis), str(val), str(emp)]
        L.append(f"| {LABELS[f]} | " + " | ".join(cells) + " |")
    kinds = collections.Counter((r["colour"], r["agreed"].get("kind", "disputed")) for r in drafted if
                                "kind" in r["agreed"] or any(d["field"] == "kind" for d in r["disputed"]))
    L += ["", "## What the photos are, where both readers agree", "", "| reading | box (Red) | folder (Purple) |",
          "|---|---|---|"]
    for k in KINDS + [None, "disputed"]:
        L.append(f"| {k or 'no answer'} | {kinds[('Red', k)]} | {kinds[('Purple', k)]} |")
    sheet = [r for r in drafted if r["disputed"]]
    placed = collections.Counter(d["placed"] for r in sheet for d in r["disputed"] if d["field"] != "kind")
    walls = {k: [r["wall_s"][i] for r in rows if r["wall_s"][i]] for i, k in enumerate((FIRST, "qwen3.5-4b-mlx4"))}
    L += ["", "## The owner's sheet", "",
          f"{len(sheet)} photos carry at least one dispute, {sum(len(r['disputed']) for r in sheet)} disputed "
          f"fields in all, {sum(1 for r in drafted if not r['disputed'])} photos fully agreed. Boxes on the sheet "
          f"(fields other than what the photo is): {placed['lines']} drawn from the Vision lines matching a "
          f"reading, {placed['label']} from a reader's label region, {placed['none']} with no box (the sheet "
          f"says so). The sheet is `pool/sheet/index.html` in the cache (private: corpus images); its answers fold "
          f"into `pool/truth.jsonl` with `ct_truth.py fold`.", "",
          "## Cost", "",
          " ".join(f"{MODELS[k][1]}: {len(w)} photos, {sum(w) / len(w):.1f} s a photo on average, "
                   f"{sum(w) / 60:.0f} min in all." for k, w in walls.items() if w) + " $0.", ""]
    with open(RESULTS, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>W47 container labels: disagreements</title>
<style>body{font:15px -apple-system,sans-serif;margin:0}header{position:sticky;top:0;background:#fff;padding:8px 16px;
border-bottom:1px solid #ccc;z-index:9}.doc{border-bottom:2px solid #888;padding:12px 16px;display:flex;gap:18px}
.frame{position:relative;display:inline-block;flex:none}.frame img{max-height:82vh;max-width:52vw;display:block}
.box{position:absolute;border:3px solid #f0a;border-radius:4px;pointer-events:none}
.tag{position:absolute;background:#f0a;color:#fff;font:bold 12px sans-serif;padding:0 4px;transform:translateY(-100%)}
.q{margin:8px 0 14px}.q label{display:block;margin-left:12px}.agreed{color:#555;font-size:13px}.nobox{color:#a05;font-size:13px}
</style>
<header><b>Container labels.</b> Two readers disagree on the fields below. Each pink box is where the field is
written (it can be off; it does not say which reading is right). Pick what the label says, type it under "other",
or say it is not on the label. Answers save in this browser; <button id="dl">download answers</button>
<span id="prog"></span></header>
<div id="root"></div>
<script>
const DATA=__DATA__;const KINDS=__KINDS__;const KEY='w47-ct-truth';const ans=JSON.parse(localStorage.getItem(KEY)||'{}');
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const total=DATA.reduce((n,d)=>n+d.fields.length,0);
function prog(){let n=0;for(const d of DATA)for(const f of d.fields)if(ans[d.id]?.[f.field]?.pick)n++;
 document.getElementById('prog').textContent=n+' of '+total+' fields answered'}
let h='';DATA.forEach(d=>{h+=`<div class="doc"><div class="frame"><img src="${esc(d.img)}">`;
 d.fields.forEach((f,i)=>{if(f.box&&f.field!=='kind')h+=`<div class="box" style="left:${100*f.box[0]}%;top:${100*f.box[1]}%;width:${100*f.box[2]}%;height:${100*f.box[3]}%"></div><div class="tag" style="left:${100*f.box[0]}%;top:${100*f.box[1]}%">${i+1}</div>`});
 h+=`</div><div><b>${d.n}. Photo ${d.id}</b>, tagged ${esc(d.colour)}`;
 const ag=Object.entries(d.agreed);if(ag.length)h+=`<div class="agreed">Both readers agree: ${ag.map(([k,v])=>esc(k)+' = '+esc(v)).join('; ')}</div>`;
 d.fields.forEach((f,i)=>{const nm=d.id+'/'+f.field;const cur=ans[d.id]?.[f.field]||{};
  h+=`<div class="q"><b>${i+1}. ${esc(f.label)}</b>`;
  if(f.field!=='kind'&&f.placed==='label')h+=` <span class="nobox">(box ${i+1} is the whole label: neither reading was found on a line)</span>`;
  if(f.field!=='kind'&&f.placed==='none')h+=` <span class="nobox">(no box: neither reading was found on the photo; look over the whole label)</span>`;
  const opts=f.field==='kind'?KINDS:[...f.readings.filter(r=>r!==null),'other','not on the label'];
  for(const o of opts)h+=`<label><input type="radio" name="${esc(nm)}" value="${esc(o)}" ${cur.pick===o?'checked':''}> ${o==='other'?'other:':esc(o)}${o==='other'?` <input data-t="${esc(nm)}" value="${esc(cur.text)}" size="40">`:''}</label>`;
  h+='</div>'});h+='</div></div>'});
document.getElementById('root').innerHTML=h;
const set=(nm,k,v)=>{const [id,f]=nm.split('/');ans[id]=ans[id]||{};ans[id][f]={...(ans[id][f]||{}),[k]:v};localStorage.setItem(KEY,JSON.stringify(ans));prog()};
document.querySelectorAll('input[type=radio]').forEach(e=>e.onchange=()=>set(e.name,'pick',e.value));
document.querySelectorAll('[data-t]').forEach(e=>e.oninput=()=>set(e.dataset.t,'text',e.value));prog();
document.getElementById('dl').onclick=()=>{const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify(ans,null,1)],{type:'application/json'}));a.download='W47-ct-truth-answers.json';a.click()};
</script>"""


# --- Route B: synthetic folder trees ----------------------------------------------------------------------------

REPOS = [("Hoover Institution Archives", "Albert Glotzer papers", None, "91006"),
         ("Wisconsin Historical Society", "Irving Kristol papers", "Mss 1036", None),
         ("Stanford University Archives", "Stanford News Service records", "SC0122", None),
         ("University of Chicago Library", "Edward Shils papers", None, None),
         ("National Archives", "Records of the War Department General Staff", "RG 165", None),
         ("Harvard University Archives", "Papers of Talcott Parsons", "HUG(FP) 15.2", None)]
FOLDER_TITLES = ["Correspondence 1952", "Reports 1959-1960", "Speeches", "Clippings", "Minutes, 1948"]


def _files(n, stem="IMG", start=1):
    return [f"{stem}_{k:04d}.pdf" for k in range(start, start + n)]


def make_trees():
    """About 30 synthetic Route B trees: each the files' relative paths, the expected level map and, per file, the
    expected fields (only the ones the tree carries; every other field is absent, not empty)."""
    rng = random.Random(SEED)
    trees = []

    def add(tid, convention, levels, files):
        trees.append({"id": tid, "convention": convention, "levels": levels,
                      "files": [{"path": p, "expect": e} for p, e in files]})

    for i, (repo, coll, num, acc) in enumerate(REPOS):
        cname = f"{coll}, {num}" if num else coll
        # 1. Repository/Collection/Box N/Folder M/
        files = []
        for b in rng.sample(range(1, 40), 2):
            for f in (1, 2):
                e = {"repository": repo, "collection_title": coll, "container": f"Box {b}", "folder": str(f)}
                if num:
                    e["collection_number"] = num
                files += [(f"{repo}/{cname}/Box {b}/Folder {f}/{n}", e) for n in _files(2)]
        add(f"t{i + 1:02d}a", "Repository/Collection/Box N/Folder M",
            ["repository", "collection", "container", "folder"], files)
        # 2. Collection/B17F8/ with box and folder in one name
        files = []
        for b, f in ((rng.randint(1, 99), rng.randint(1, 30)), (rng.randint(1, 99), rng.randint(1, 30))):
            e = {"collection_title": coll, "container": f"Box {b}", "folder": str(f)}
            if num:
                e["collection_number"] = num
            files += [(f"{cname}/B{b}F{f}/{n}", e) for n in _files(3)]
        add(f"t{i + 1:02d}b", "Collection/B17F8", ["collection", "container+folder"], files)
        # 3. "Box 10 - Folder 3", with a folder title on some
        files = []
        for j, (b, f) in enumerate(((rng.randint(1, 60), rng.randint(1, 20)), (rng.randint(1, 60), rng.randint(1, 20)))):
            t = FOLDER_TITLES[(i + j) % len(FOLDER_TITLES)] if j else None
            name = f"Box {b} - Folder {f}" + (f" - {t}" if t else "")
            e = {"collection_title": coll, "container": f"Box {b}", "folder": str(f)}
            if t:
                e["folder_title"] = t
            if num:
                e["collection_number"] = num
            files += [(f"{cname}/{name}/{n}", e) for n in _files(2)]
        add(f"t{i + 1:02d}c", '"Box 10 - Folder 3"', ["collection", "container+folder"], files)
        # 4. box and folder in the filenames, flat in the collection
        files = []
        short = coll.split()[-2] if len(coll.split()) > 1 else coll
        for b, f in ((2, 4), (2, 5), (3, 1)):
            e = {"repository": repo, "collection_title": coll, "container": f"Box {b}", "folder": str(f)}
            if num:
                e["collection_number"] = num
            files += [(f"{repo}/{cname}/{short}, Box {b}, Folder {f} - {k:04d}.pdf", e) for k in (1, 2)]
        add(f"t{i + 1:02d}d", "filenames carry box and folder", ["repository", "collection"], files)
        # 5. workflow levels to skip, and series or accession levels where the collection has them
        files = []
        mid = f"Accession {acc}" if acc else ("Series II" if i % 2 else "Series 1")
        for b in (1, 2):
            e = {"repository": repo, "collection_title": coll, "container": f"Box {b}"}
            if acc:
                e["accession"] = acc
            else:
                e["series"] = mid
            if num:
                e["collection_number"] = num
            files += [(f"05 Final Tagging/{repo}/{cname}/{mid}/Box {b}/scans/{n}", e) for n in _files(2)]
        add(f"t{i + 1:02d}e", "workflow levels to skip, with a series or accession level",
            ["ignore", "repository", "collection", "accession" if acc else "series", "container", "ignore"], files)
    # Other spellings, one tree each
    other = [("SC0122/B82/F15", "Stanford University Archives", {"collection_number": "SC0122", "container": "Box 82",
                                                                  "folder": "15"}, ["collection", "container", "folder"]),
             ("Kristol, Mss 1036/Carton 9", None, {"collection_title": "Kristol", "collection_number": "Mss 1036",
                                                    "container": "Carton 9"}, ["collection", "container"]),
             ("Parsons/Folio 3/f. 5", None, {"collection_title": "Parsons", "container": "Folio 3", "folder": "5"},
              ["collection", "container", "folder"]),
             ("RG 165/Entry 77/Box 412", None, {"collection_number": "RG 165", "series": "Entry 77",
                                                "container": "Box 412"}, ["collection", "series", "container"]),
             ("glotzer/box_17/folder_08", None, {"collection_title": "glotzer", "container": "Box 17", "folder": "8"},
              ["collection", "container", "folder"]),
             ("Shils/Bx 3 Fd 12", None, {"collection_title": "Shils", "container": "Box 3", "folder": "12"},
              ["collection", "container+folder"])]
    for k, (path, repo, e, levels) in enumerate(other, 1):
        add(f"u{k:02d}", "other spellings: " + path.split("/", 1)[1], levels,
            [(f"{path}/{n}", e) for n in _files(2)])
    return trees


def cmd_trees(a):
    trees = make_trees()
    with open(TREES, "w", encoding="utf-8") as fh:
        json.dump({"about": "W47.ct-truth Route B test set: synthetic trees, written by ct_truth.py trees. "
                            "`levels` is the expected level map (a field, 'container+folder' for a name that "
                            "carries both, or 'ignore'); `expect` lists only the fields the tree carries.",
                   "trees": trees}, fh, ensure_ascii=False, indent=1)
        fh.write("\n")
    print(f"{len(trees)} trees, {sum(len(t['files']) for t in trees)} files; {TREES}")


def cmd_owner_tree(a):
    """The corpus's level-1 names and, under each, its level-2 names, with PDF counts. Private: in the cache."""
    count = collections.Counter()
    for folder, names in CS.walk(CS.CORPUS):
        parts = folder.split(os.sep)
        count[(parts[0], parts[1] if len(parts) > 1 else "")] += len(names)
    tree = collections.defaultdict(dict)
    for (l1, l2), n in count.items():
        tree[l1][l2] = tree[l1].get(l2, 0) + n
    os.makedirs(POOL, exist_ok=True)
    with open(OWNER_TREE, "w", encoding="utf-8") as fh:
        json.dump({"level1": {k: {"pdfs": sum(v.values()), "workflow": bool(WORKFLOW.match(k)), "level2": v}
                              for k, v in sorted(tree.items())}}, fh, ensure_ascii=False, indent=1)
    print(f"{len(tree)} level-1 names, {sum(len(v) for v in tree.values())} level-2 names; {OWNER_TREE}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sample")
    s.add_argument("--per-class", type=int, default=PER_CLASS)
    s.set_defaults(fn=cmd_sample)
    for name, fn in (("render", cmd_render), ("lines", cmd_lines), ("compare", cmd_compare), ("trees", cmd_trees),
                     ("owner-tree", cmd_owner_tree)):
        sub.add_parser(name).set_defaults(fn=fn)
    c = sub.add_parser("collect")
    c.add_argument("--limit", type=int)
    c.add_argument("--model", choices=sorted(MODELS), default=FIRST)
    c.set_defaults(fn=cmd_collect)
    f = sub.add_parser("fold")
    f.add_argument("answers")
    f.set_defaults(fn=cmd_fold)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
