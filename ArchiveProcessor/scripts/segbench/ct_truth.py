#!/usr/bin/env python3
"""W47.ct-truth: the container-label truth set, the owner's disagreement sheet and a folder-tree test set.

    python3 ct_truth.py sample                      # ~120 box + ~120 folder markers whose JPEG original is confirmed
    python3 ct_truth.py render                      # each marker's JPEG original, upright, into the cache (read-only)
    python3 ct_truth.py lines                       # Apple Vision text lines with boxes (layout_order.py's helper)
    heavy-run.py run -- <lab venv>/bin/python ct_truth.py collect --model K
    python3 ct_truth.py gateway                     # the third reader, Gemini 3.7 Flash through the gateway (real money)
    python3 ct_truth.py compare                     # segbench-results/ct-truth.md; the owner's sheet; draft truth
    python3 ct_truth.py fold ANSWERS.json           # the owner's answers -> pool-jpeg/truth.jsonl (W47.ct-read's truth)
    python3 ct_truth.py trees                       # writes ct_trees.json, the synthetic Route B set (committed)
    python3 ct_truth.py owner-tree                  # the corpus's level-1 and level-2 names, private, in the cache

The revision (W47.ct-truth-revise, from the owner's sheet notes of 2026-11-05), in pool-jpeg/rev2/:
    python3 ct_truth.py upright                     # Gemini's upright turn for each kept photo (real money); rev2 sample
    python3 ct_truth.py --rev render | lines        # the photos turned upright, and their Vision lines
    heavy-run.py run -- <lab venv>/bin/python ct_truth.py --rev collect --model K
    python3 ct_truth.py --rev gateway               # the readers on the revised fields and prompt
    python3 ct_truth.py --rev revise                # revised truth, second sheet, segbench-results/ct-truth-revised.md
    python3 ct_truth.py --rev fold ANSWERS.json     # the second sheet's answers -> rev2/truth.jsonl (W47.ct-read's truth)

<lab venv> is ~/.local/share/visionocr-ocrlab/venv (mlx_vlm 0.7.4). --model is a key of MODELS; both are run.

JPEG originals (W47.ct-truth-jpeg; owner, 2026-10-22 and the 2026-10-29 walkthrough): every image a model or the
sheet sees is the marker's JPEG original, never the corpus PDF. Each sampled PDF is paired through corpus_pairs.py's
pairs.tsv and confirmed by ocr_truth.orient_like_pdf (correlation at least MIN_CORR), whose best turn makes the
JPEG upright. A marker with no confirmed JPEG is left out and the next marker of its stratum and colour in the same
draw order takes its place; the draw is the PDF build's, so the markers that were confirmed are the same photos.
The PDF-built draft stays in the cache's `pool/` and in segbench-results/ct-truth-pdf.md.

Three blind readers (measurement audit FLD-9, owner 2026-10-30): the two open models and Gemini 3.7 Flash through
the Stanford gateway. The owner's sheet holds every field where the three are not unanimous, plus CONTROLS fields
where they are, mixed in unmarked. The fold records which fields the owner ruled: the three are the truth's
drafters, so W47.ct-read scores any of them only on those fields, or reports the rest as agreement.

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
PDF_POOL = os.path.join(CACHE, "pool")          # the first build, on the corpus PDFs: kept for comparison
POOL = os.path.join(CACHE, "pool-jpeg")
PAGES = os.path.join(POOL, "pages")
LINES = os.path.join(POOL, "lines")
SHEET = os.path.join(POOL, "sheet")
SAMPLE = os.path.join(POOL, "sample.jsonl")
SAMPLING = os.path.join(POOL, "sampling.json")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "ct-truth.md")
TREES = os.path.join(HERE, "ct_trees.json")
OWNER_TREE = os.path.join(POOL, "owner-tree.json")

FLOOR = 2
SEED = 4701
MAX_SIDE = 1280
MAX_TOKENS = 420
WORKFLOW = re.compile(r"^\d\d ")  # "05 Final Tagging", "03 Unconverted (…)": the repository is one level down

MODELS = {"qwen3-vl-8b-mlx4": ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "Qwen3-VL 8B, 4-bit MLX", 8),
          "qwen3.5-4b-mlx4": ("lmstudio-community/Qwen3.5-4B-MLX-4bit", "Qwen3.5 4B, 4-bit MLX", 5)}
FIRST = "qwen3-vl-8b-mlx4"   # the agreed value is taken from this reader's spelling
GATEWAY = "gemini3.7-flash-gw"
READERS = (FIRST, "qwen3.5-4b-mlx4", GATEWAY)
NAMES = {**{k: v[1] for k, v in MODELS.items()}, GATEWAY: "Gemini 3.7 Flash (Stanford gateway, low reasoning)"}
# The gateway reader's spend: counted at gateway_gemini.PRICE (Gemini 3.8 Flash list, a ceiling for 3.7) or the
# gateway's own figure, whichever is larger. The owner approved about $0.70 (FLD-9); this cap is under the $7 rule.
GATEWAY_CAP = 2.00
GATEWAY_MAX_TOKENS = 4096
MIN_CORR = 0.65   # ocr_truth.orient_like_pdf: true pairs measured 0.69-0.98, mismatches 0.16-0.48 (2026-10-22)
NOTES = "_notes"   # the sheet's per-photo notes, kept beside the field answers
CONTROLS = 20     # unanimous fields put on the sheet unmarked: half with a value, half agreed empty

FIELDS = ["repository", "place", "collection_title", "collection_number", "accession", "series", "container",
          "folder", "folder_title"]
FIELDS_FIRST = FIELDS   # the first build's nine; the revision's are FIELDS_REV
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

# --- the revision (W47.ct-truth-revise, from the owner's sheet notes of 2026-11-05) ------------------------------
# `ct_truth.py --rev <command>` runs render, lines, collect, gateway and the rest on rev2/ with these fields and this
# prompt; without --rev every command is the first build's, unchanged, so its sheet and fold stay reproducible.

REV = os.path.join(POOL, "rev2")
REV_RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "ct-truth-revised.md")
NOTE_RULINGS = os.path.join(REV, "note-rulings.json")   # the owner's notes, transcribed per field (private)
OWNER_ANSWERS = os.path.join(POOL, "answers-owner-20261105.json")
REV_CAP = 2.00   # the item's whole gateway spend, the upright check and the readers together; under the $7 rule
FIELDS_REV = ["repository", "place", "collection_title", "collection_subtitle", "collection_number", "accession",
              "series", "series_title", "container", "box_title", "folder", "folder_title", "date", "other"]
LABELS.update({"collection_subtitle": "Collection subtitle", "series_title": "Series title",
               "box_title": "Box title", "date": "Date or time period", "other": "Other identifying marks",
               "_turn": "Which way up is this photo now?"})
NEW_FIELDS = [f for f in FIELDS_REV if f not in FIELDS]
# The photos the owner took out (his notes, 2026-11-05): early photos taken a different way, and the exceptions.
DROPPED = {**{k: "early photo, taken a different way" for k in (
    "a3abdc5d5a8c", "825962d17684", "576eaf2d9cd9", "47bba9e86c7a", "55e90dfd2101", "6b6d21a17459",
    "325e0792e894", "49ccbdf39b1f")},
    "60502414e3e2": "request slip", "b99aad847c3e": "volume spine", "337fb83b2842": "volume spine",
    "791a6ebe670b": "a loose folder standing for its box", "42fda0c32ccd": "temporary box",
    "8fd31a6cac1f": "\"No Folder\" sheet", "dc8d80b17987": "\"No Folder\" sheet",
    "f1573d9c08ba": "\"don't train on this\"", "96ef09b20998": "\"don't train on this\"",
    "3a0193ec9415": "\"don't train on this\""}

PROMPT_REV = (
    "This photo was taken in an archive reading room. It may show a box label, a folder label or tab, a divider "
    "sheet, or a page of a document. Read what is written on the label, if there is one, into these fields. Copy "
    "only what is written: never infer or fill in anything, such as a repository or a place the label does not "
    "name. Use null for anything not written there. Rules:\n"
    "- series: only when the label says \"Series\" (e.g. \"Series III\"); the series' name goes in series_title. "
    "Without the word \"Series\", put that text under other.\n"
    "- accession: only when the label says \"Accession\" or \"ACCN\"; an unlabelled number goes under other.\n"
    "- container: the container type and its own number only: \"Box 34\" for \"Box 34 of 201\", \"Box #186\" or "
    "\"Box 34/201\".\n"
    "- A folder marked with two numbers such as \"5-9\" or \"8.5\" is box 5 folder 9, or box 8 folder 5: "
    "container \"Box 5\", folder \"9\".\n"
    "- folder_title: only on a folder; never read a folder title off a box label. A box label's own title is "
    "box_title.\n"
    "- A title cut off by the edge of the photo or hidden ends with \"...\".\n"
    "Reply with JSON only:\n"
    "{\"kind\": one of \"box label\", \"folder label\", \"divider or other\", \"document page\",\n"
    " \"repository\": the archive or library, e.g. \"Hoover Institution Archives\",\n"
    " \"place\": the city or state of the repository, if written,\n"
    " \"collection_title\": e.g. \"Irving Kristol Papers, 1946-2001\",\n"
    " \"collection_subtitle\": a further line naming a part of the collection, e.g. a record group's office,\n"
    " \"collection_number\": a call or collection number, e.g. \"Mss 1036\", \"SC0122\", \"RG 165\",\n"
    " \"accession\": an accession number, e.g. \"91006-10.V\",\n"
    " \"series\": e.g. \"Series II\",\n"
    " \"series_title\": the series' name, e.g. \"Correspondence\",\n"
    " \"container\": e.g. \"Box 17\", \"Carton 9\",\n"
    " \"box_title\": the title a box label gives the box's contents, e.g. \"Correspondence with Specific "
    "Individuals\",\n"
    " \"folder\": the folder number, e.g. \"8\",\n"
    " \"folder_title\": the folder's title, e.g. \"Reports 1959-1960\",\n"
    " \"date\": the date or time period written for this box or folder, e.g. \"1950-1980\", \"3/5/57\",\n"
    " \"other\": any other identifying mark, e.g. a shelf or location mark \"40-E-5\" or an unlabelled number "
    "\"84-044\"; several joined with \"; \",\n"
    " \"label_box\": [x1, y1, x2, y2] the label's region on a 0-1000 scale, or null}")


def use_revision():
    """Point the shared steps at rev2/: its sample, pages, lines, drafts, ledger and sheet, the revised fields and
    prompt. The gateway readers' cap is what the upright check left of REV_CAP."""
    global POOL, PAGES, LINES, SHEET, SAMPLE, FIELDS, PROMPT, MAX_TOKENS, GATEWAY_CAP, RESULTS
    POOL, PAGES, LINES, SHEET = REV, os.path.join(REV, "pages"), os.path.join(REV, "lines"), os.path.join(REV, "sheet")
    SAMPLE, FIELDS, PROMPT, MAX_TOKENS, RESULTS = os.path.join(REV, "sample.jsonl"), FIELDS_REV, PROMPT_REV, 640, REV_RESULTS
    GATEWAY_CAP = REV_CAP - upright_spent()


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
    import tempfile
    pairs = load_pairs()
    os.makedirs(POOL, exist_ok=True)
    tmp = tempfile.mkdtemp(dir=POOL)
    # The PDF build's 240 are the sample (the corpus has changed since, so a fresh draw would not give them back).
    # Each keeps its place when its JPEG is confirmed; a stratum's left-out markers are refilled in a fresh draw
    # order over the stratum's current markers of that colour, skipping any already sampled or not confirmed.
    base = [json.loads(l) for l in open(os.path.join(PDF_POOL, "sample.jsonl"), encoding="utf-8")]
    taken = {r["path"] for r in base}
    present = {r["path"] for r in rows}
    rng = random.Random(SEED)
    picked, stats = [], {"min_corr": MIN_CORR, "classes": {}, "markers_now": len(rows)}
    for colour in ("Red", "Purple"):
        mine = [r for r in base if r["colour"] == colour]
        st = {"pdf_sample": len(mine), "left_out": collections.Counter(), "refilled": 0, "short": {},
              "checked": 0, "rejected_corr": []}
        for rep in sorted({r["repository"] for r in mine}):
            want, got = [r for r in mine if r["repository"] == rep], 0
            for r in want:
                if r["path"] not in present:
                    st["left_out"]["no longer a marker in the corpus"] += 1
                    continue
                st["checked"] += 1
                jpeg, turn, corr = confirm(r["path"], pairs, tmp)
                if jpeg is None:
                    st["left_out"][turn] += 1
                    if corr is not None:
                        st["rejected_corr"].append(round(corr, 3))
                    continue
                picked.append(dict(r, jpeg=jpeg, turn=turn, corr=round(corr, 3), refill=False))
                got += 1
            pool = [r for r in rows if r["colour"] == colour and r["repository"] == rep and r["path"] not in taken]
            for r in draw(pool, len(pool), rng):
                if got == len(want):
                    break
                st["checked"] += 1
                jpeg, turn, corr = confirm(r["path"], pairs, tmp)
                if jpeg is None:
                    continue
                picked.append(dict(r, jpeg=jpeg, turn=turn, corr=round(corr, 3), refill=True))
                st["refilled"] += 1
                got += 1
            if got < len(want):
                st["short"][rep] = len(want) - got
        st["sampled"] = sum(1 for r in picked if r["colour"] == colour)
        st["left_out"] = dict(st["left_out"])
        st["rejected_corr"].sort()
        stats["classes"][colour] = st
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)
    with open(SAMPLE, "w", encoding="utf-8") as fh:
        for r in picked:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    with open(SAMPLING, "w", encoding="utf-8") as fh:
        json.dump(stats, fh, ensure_ascii=False, indent=1)
    c = collections.Counter(r["colour"] for r in picked)
    print(f"{len(rows)} single-colour markers; sampled {c['Red']} Red, {c['Purple']} Purple across "
          f"{len({r['repository'] for r in picked})} strata; {json.dumps(stats['classes'])}; {SAMPLE}")


def load_pairs():
    """{corpus-relative PDF: absolute JPEG path} for every PDF corpus_pairs.py paired (method other than none)."""
    import corpus_pairs as CP
    return {pdf: os.path.join(CP.JPEGS, jpeg) for pdf, jpeg, method, _ in CP.read_pairs() if jpeg and method != "none"}


def confirm(rel, pairs, tmp):
    """(JPEG path, turn, correlation) when the marker's paired JPEG is the same photo as its PDF, else
    (None, why, correlation). The turn (degrees counter-clockwise, after EXIF) makes the JPEG upright like the PDF."""
    import ocr_truth as OT
    from pathlib import Path
    from PIL import Image, ImageOps
    jpeg = pairs.get(rel)
    if not jpeg:
        return None, "no JPEG paired", None
    if not os.path.exists(os.path.join(CS.CORPUS, rel)) or not os.path.exists(jpeg):
        return None, "comparison failed", None   # orient_like_pdf would score a missing page as correlation 0
    try:
        with Image.open(jpeg) as im:
            turn, corr = OT.orient_like_pdf(ImageOps.exif_transpose(im), Path(CS.CORPUS) / rel, Path(tmp))
    except Exception:
        return None, "comparison failed", None
    if corr < MIN_CORR:
        return None, "JPEG not the same photo", corr
    return jpeg, turn, corr


def sample():
    return [json.loads(l) for l in open(SAMPLE, encoding="utf-8")]


def image_of(mid):
    return os.path.join(PAGES, mid + ".jpg")


def cmd_render(a):
    """Each marker's JPEG original, EXIF applied, turned upright, MAX_SIDE on the long side. Read-only on the tree."""
    from PIL import Image, ImageOps
    os.makedirs(PAGES, exist_ok=True)
    bad = 0
    for r in sample():
        out = image_of(r["id"])
        if not os.path.exists(out):
            try:
                with Image.open(r["jpeg"]) as im:
                    up = ImageOps.exif_transpose(im).convert("RGB").rotate(r["turn"], expand=True)
                up.thumbnail((MAX_SIDE, MAX_SIDE), Image.Resampling.LANCZOS)
                up.save(out + ".tmp", "JPEG", quality=90)
                os.replace(out + ".tmp", out)
            except Exception as e:
                print(r["id"], e)
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
    import model_store
    model_store.use()   # before mlx_vlm imports huggingface_hub, which reads HF_HOME once
    import mlx.core as mx
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
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


def gateway_ledger():
    p = os.path.join(POOL, "gateway-calls.jsonl")
    return [json.loads(x) for x in open(p, encoding="utf-8")] if os.path.exists(p) else []


def cmd_gateway(a):
    """The third blind reader: Gemini 3.7 Flash through the Stanford gateway, the same image and prompt, temperature
    0, low reasoning. Real money: every call is in pool-jpeg/gateway-calls.jsonl before its reply is used, and
    GATEWAY_CAP stops the run. Replies stay in the cache (the owner's material)."""
    import base64
    import threading
    from concurrent.futures import ThreadPoolExecutor
    import gateway_gemini as G
    out = draft_dir(GATEWAY)
    os.makedirs(out, exist_ok=True)
    todo = [r["id"] for r in sample() if os.path.exists(image_of(r["id"]))
            and not os.path.exists(os.path.join(out, r["id"] + ".json"))][: a.limit or None]
    worst = (4000 * G.PRICE[0] + GATEWAY_MAX_TOKENS * G.PRICE[1]) / 1e6
    lock = threading.Lock()
    print(f"{GATEWAY}: {len(todo)} photos to read", flush=True)

    def one(mid):
        with lock:
            spent = sum(G.charge(r) for r in gateway_ledger())
            if spent + worst > GATEWAY_CAP:
                return mid, f"cap: ${spent:.4f} spent of ${GATEWAY_CAP}"
        with open(image_of(mid), "rb") as fh:
            img = fh.read()
        body = {"model": G.MODEL, "temperature": 0, "max_tokens": GATEWAY_MAX_TOKENS, "reasoning_effort": "low",
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
        rec = G.with_gateway_cost({"id": mid, "http": r.status_code, "t": t, "wall_s": round(time.time() - t, 2),
                                   "model": got.get("model"), "usage": usage, "cost": round(G.cost(usage), 6)}, r)
        with lock:
            with open(os.path.join(POOL, "gateway-calls.jsonl"), "a", encoding="utf-8") as fh:
                fh.write(json.dumps(rec) + "\n")
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
    led = gateway_ledger()
    print(f"{len(res) - len(bad)}/{len(res)} parsed; ${sum(G.charge(r) for r in led):.4f} charged in all "
          f"({G.billed_note(led)}); not ok: {bad[:10]}")


# --- the revision's upright step ----------------------------------------------------------------------------------
# The first build turned each JPEG to match its PDF (orient_like_pdf), and the owner's sheet showed 36 photos turned:
# those PDFs are not upright either. Apple Vision's text scores (ocr_orient.swift, all four turns) gave no clear win on
# any of the 218 labels (2026-11-05: handwriting and short labels, and it reads upside-down text too), so the turn is
# Gemini's pick among the four turns shown together, measured against the owner's notes: the photos he called turned
# must move, the direction he gave must match, and the photos he did not flag should stay. Where the pick and his notes
# disagree, the second sheet asks him which way up.

BUILD1_PAGES, BUILD1_SAMPLE = PAGES, SAMPLE
UPRIGHT = os.path.join(REV, "upright.jsonl")
UPRIGHT_LEDGER = os.path.join(REV, "upright-calls.jsonl")
UPRIGHT_SIDE = 512
UPRIGHT_PROMPT = ("These four images are the same photo from an archive reading room (a box label, a folder label, "
                  "a divider or a document page), each turned a different way. Which image shows it the right way "
                  "up, so that its main writing reads normally, left to right? Reply with the image's number only: "
                  "1, 2, 3 or 4.")
TURN_OPTIONS = ["the right way up", "needs a quarter turn clockwise", "upside down",
                "needs a quarter turn anticlockwise"]   # the sheet's answers: index * 90 is the further turn, clockwise


def upright_spent():
    import gateway_gemini as G
    return sum(G.charge(json.loads(x)) for x in open(UPRIGHT_LEDGER, encoding="utf-8")) \
        if os.path.exists(UPRIGHT_LEDGER) else 0.0


def owner_turn_flags():
    """{photo: the further anticlockwise turn the owner's note implies (90, 180, 270), or 'turned' when it gives no
    direction}, from the 2026-11-05 notes. "Rotated to the left" is upright after a quarter turn clockwise (270)."""
    answers = json.load(open(OWNER_ANSWERS, encoding="utf-8"))
    out = {}
    for mid, v in answers.items():
        t = (((v or {}).get(NOTES) or {}).get("text") or "").lower()
        if "upside down" in t:
            out[mid] = 180
        elif "rotated to the left" in t:
            out[mid] = 270
        elif "rotated to the right" in t:
            out[mid] = 90
        elif re.search(r"\brotated\b|sideways", t):
            out[mid] = "turned"
    return out


def kept_rows():
    return [r for r in (json.loads(l) for l in open(BUILD1_SAMPLE, encoding="utf-8")) if r["id"] not in DROPPED]


def cmd_upright(a):
    """Gemini's pick of the upright turn for every photo kept, then rev2/sample.jsonl with the turns combined. Real
    money, in rev2/upright-calls.jsonl before a reply is used; REV_CAP stops the run."""
    import base64
    import io
    import threading
    from concurrent.futures import ThreadPoolExecutor
    from PIL import Image
    import gateway_gemini as G
    os.makedirs(REV, exist_ok=True)
    done = {json.loads(l)["id"] for l in open(UPRIGHT, encoding="utf-8")} if os.path.exists(UPRIGHT) else set()
    todo = [r["id"] for r in kept_rows() if r["id"] not in done][: a.limit or None]
    worst = (4 * 1200 * G.PRICE[0] + 2048 * G.PRICE[1]) / 1e6
    lock = threading.Lock()
    print(f"upright: {len(todo)} photos to ask", flush=True)

    def one(mid):
        with lock:
            if upright_spent() + worst > REV_CAP:
                return mid, "cap"
        order = [0, 90, 180, 270]
        random.Random(f"{SEED}/{mid}").shuffle(order)
        content = []
        with Image.open(os.path.join(BUILD1_PAGES, mid + ".jpg")) as im:
            im = im.convert("RGB")
            im.thumbnail((UPRIGHT_SIDE, UPRIGHT_SIDE))
            for k, deg in enumerate(order, 1):
                buf = io.BytesIO()
                im.rotate(deg, expand=True).save(buf, "JPEG", quality=85)
                content += [{"type": "text", "text": f"Image {k}:"},
                            {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,"
                                                                       + base64.b64encode(buf.getvalue()).decode()}}]
        content.append({"type": "text", "text": UPRIGHT_PROMPT})
        body = {"model": G.MODEL, "temperature": 0, "max_tokens": 2048, "reasoning_effort": "low",
                "messages": [{"role": "user", "content": content}]}
        t = time.time()
        for attempt in range(3):
            r = G.request("/chat/completions", body)
            if r.status_code in (429, 500, 502, 503, 504) and attempt < 2:
                time.sleep(10 * (attempt + 1))
                continue
            break
        got = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
        usage = got.get("usage") or {}
        rec = G.with_gateway_cost({"id": mid, "http": r.status_code, "t": t, "usage": usage,
                                   "cost": round(G.cost(usage), 6)}, r)
        with lock:
            with open(UPRIGHT_LEDGER, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(rec) + "\n")
        reply = ((got.get("choices") or [{}])[0].get("message") or {}).get("content") if r.status_code == 200 else None
        m = re.search(r"\b([1-4])\b", reply or "")
        if not m:
            return mid, f"http {r.status_code}: {str(reply)[:80]}"
        with lock:
            with open(UPRIGHT, "a", encoding="utf-8") as fh:
                fh.write(json.dumps({"id": mid, "order": order, "reply": reply.strip()[:40],
                                     "pick": order[int(m.group(1)) - 1]}) + "\n")
        return mid, "ok"

    with ThreadPoolExecutor(4) as ex:
        res = list(ex.map(one, todo))
    bad = [x for x in res if x[1] != "ok"]
    print(f"{len(res) - len(bad)}/{len(res)} answered; ${upright_spent():.4f} spent on the upright check; "
          f"not ok: {bad[:10]}")
    write_rev_sample()


def upright_picks():
    return {r["id"]: r["pick"] for r in (json.loads(l) for l in open(UPRIGHT, encoding="utf-8"))} \
        if os.path.exists(UPRIGHT) else {}


def write_rev_sample():
    """rev2/sample.jsonl: the kept photos, each `turn` now the PDF match and Gemini's further turn together."""
    picks = upright_picks()
    with open(os.path.join(REV, "sample.jsonl"), "w", encoding="utf-8") as fh:
        for r in kept_rows():
            extra = picks.get(r["id"])
            fh.write(json.dumps(dict(r, turn_pdf=r["turn"], upright=extra, turn=(r["turn"] + (extra or 0)) % 360),
                                ensure_ascii=False) + "\n")


def upright_check():
    """The pick measured against the owner's notes: counts, and the photos whose pick and notes disagree (with the
    direction the owner gave, if any), which the second sheet asks about."""
    picks, flags = upright_picks(), owner_turn_flags()
    kept = [r["id"] for r in kept_rows()]
    c = collections.Counter(asked=len(picks), kept=len(kept))
    disagree = {}
    for mid in kept:
        p, f = picks.get(mid), flags.get(mid)
        if p is None:
            c["no pick"] += 1
            disagree[mid] = "no pick"
            continue
        if f is None:
            c["not flagged"] += 1
            c["not flagged, left as it was"] += p == 0
            if p:
                disagree[mid] = "turned, the owner did not flag it"
        else:
            c["flagged"] += 1
            c["flagged, turned"] += p != 0
            if f != "turned":
                c["flagged with a direction"] += 1
                c["flagged with a direction, matched"] += p == f
            if p == 0:
                disagree[mid] = "left as it was, the owner flagged it"
            elif f != "turned" and p != f:
                disagree[mid] = "turned another way than the owner said"
    return c, disagree


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
            return f"{kind} {re.sub(r'^0+(?=[0-9])', '', m.group(2).lower())}"
        bare = re.fullmatch(r"\s*(?:no\.?|#)?\s*(\d+[a-z]?)\s*", s)
        if bare:  # a bare number is read as a box, the usual container
            return f"box {bare.group(1)}"
    if field == "folder":
        s = re.sub(r"\b(folder|fol|fld|fd|f)\b\.?\s*(no\.?|#)?", "", s)
    if field == "series" and "series_title" in FIELDS:   # the revision: "Series III" and "III" are one series
        s = re.sub(r"^\s*series\b\.?\s*", "", s)
    if field == "other":   # several marks joined with "; ": the same marks in another order are the same reading
        parts = sorted(p for p in (re.sub(r"[^a-z0-9]", "", x.replace("&", "and")) for x in re.split(r"[;\n|]", s)) if p)
        return "|".join(parts) or None
    s = s.replace("&", "and")
    return re.sub(r"[^a-z0-9]", "", s) or None


def agree(field, a, b):
    return norm(field, a) == norm(field, b)


def disputes(*drafts):
    """The fields (and `kind`) on which the parsed drafts are not unanimous, in FIELDS order, `kind` first."""
    ds = [d or {} for d in drafts]
    out = []
    if len({d.get("kind") for d in ds}) > 1:
        out.append("kind")
    for f in FIELDS:
        if not all(agree(f, ds[0].get(f), d.get(f)) for d in ds[1:]):
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
    """The distinct readings in an order fixed by the photo and field, not by which model gave them."""
    uniq = []
    for v in vals:
        if not any(agree(field if field != "kind" else "x", v, u) for u in uniq):
            uniq.append(v)
    random.Random(hashlib.sha1(f"{mid}/{field}".encode()).hexdigest()).shuffle(uniq)
    return uniq


def build(rows, keys=READERS):
    """Per photo: every reader's draft, the unanimous fields, and the rest with their readings and place."""
    out = []
    for r in rows:
        recs = [draft_of(r["id"], k) for k in keys]
        ds = [(x or {}).get("parsed") for x in recs]
        rec = dict(r, readers=list(keys), drafted=[x is not None for x in recs], parsed=[d is not None for d in ds],
                   agreed={}, disputed=[], controls=[], wall_s=[(x or {}).get("wall_s") for x in recs],
                   odd=None)
        if any(d is None for d in ds):
            out.append(rec)
            continue
        lines = lines_of(r["id"])
        rec["_place"] = (lines, [d.get("label_box") for d in ds])
        split = disputes(*ds)
        odd = {}
        for f in ["kind"] + FIELDS:
            vals = [d.get(f) for d in ds]
            if f in split:
                box, how = field_place(f, order_readings(r["id"], f, vals), lines, rec["_place"][1])
                rec["disputed"].append({"field": f, "readings": order_readings(r["id"], f, vals), "box": box,
                                        "placed": how})
                odd[f] = odd_one(f, vals, keys)
            else:
                rec["agreed"][f] = ds[0].get(f)
        rec["odd"] = odd
        out.append(rec)
    pick_controls(out)
    for r in out:
        r.pop("_place", None)
    return out


def odd_one(field, vals, keys):
    """The reader that alone disagrees with the other two, or None when no two agree."""
    g = "x" if field == "kind" else field
    for i, k in enumerate(keys):
        rest = [v for j, v in enumerate(vals) if j != i]
        if agree(g, rest[0], rest[1]) and not agree(g, vals[i], rest[0]):
            return k
    return None


def pick_controls(rows, n=CONTROLS):
    """Put n unanimous fields on the sheet unmarked, half with a value and half agreed empty, drawn with the seed.
    A control keeps its agreed value in the truth unless the owner answers it."""
    cands = sorted((r["id"], f) for r in rows if "_place" in r for f, v in r["agreed"].items() if v is not None)
    empty = sorted((r["id"], f) for r in rows if "_place" in r for f, v in r["agreed"].items()
                   if v is None and f != "kind")
    rng = random.Random(SEED)
    chosen = rng.sample(cands, min(n - n // 2, len(cands))) + rng.sample(empty, min(n // 2, len(empty)))
    by = {r["id"]: r for r in rows}
    for mid, f in chosen:
        r = by[mid]
        v = r["agreed"][f]
        box, how = field_place(f, [v] if v else [], *r["_place"])
        r["controls"].append({"field": f, "readings": [v] if v else [], "box": box, "placed": how})
    for r in rows:   # in field order, so a control sits among the disputes like one of them
        r["controls"].sort(key=lambda d: (["kind"] + FIELDS).index(d["field"]))


def cmd_compare(a):
    rows = build(sample())
    os.makedirs(POOL, exist_ok=True)
    with open(os.path.join(POOL, "draft-truth.jsonl"), "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    write_sheet(rows)
    write_results(rows)
    print(f"{RESULTS}; sheet {os.path.join(SHEET, 'index.html')}")


def asked(r):
    """The fields the sheet asks about on one photo, disputes and controls together, in field order, unmarked."""
    order = ["kind"] + FIELDS
    return sorted(r["disputed"] + r.get("controls", []), key=lambda d: order.index(d["field"]))


def sheet_items(rows):
    out = []
    for n, r in enumerate((r for r in rows if asked(r)), 1):
        ask = asked(r)
        on = {d["field"] for d in ask}
        out.append({"id": r["id"], "n": n, "img": os.path.relpath(image_of(r["id"]), SHEET),
                    "colour": "box (Red)" if r["colour"] == "Red" else "folder (Purple)",
                    "agreed": {f: v for f, v in r["agreed"].items() if v and f not in on},
                    "fields": [{"field": d["field"], "label": LABELS[d["field"]], "readings": d["readings"],
                                "box": d["box"], "placed": d["placed"]} for d in ask]})
    return out


SHEET1_HEADER = """<b>Container labels.</b> Three readers do not all agree on most of the fields below; a few are fields
where they did agree, mixed in as a check. Each pink box is where the field is written (it can be off; it does not
say which reading is right). Pick what the label says, type it under "other", or say it is not on the label.
The grey line on each photo lists the fields all three readers agreed on; they are not asked and go into the truth
as written. Use the photo's notes box when one of them is wrong, or when the label carries something no field
caught (a second series line, a date range, a subseries). Fields nobody read are not listed."""


def sheet_html(items, key, header, settled, dl):
    return (SHEET_HTML.replace("__DATA__", json.dumps(items, ensure_ascii=False))
            .replace("__KINDS__", json.dumps(KINDS)).replace("__LABELS__", json.dumps(LABELS))
            .replace("__NOTES__", json.dumps(NOTES)).replace("__SETTLED__", json.dumps(settled))
            .replace("__KEY__", json.dumps(key)).replace("__DLNAME__", json.dumps(dl)).replace("__HEADER__", header))


def write_sheet(rows):
    os.makedirs(SHEET, exist_ok=True)
    with open(os.path.join(SHEET, "index.html"), "w", encoding="utf-8") as fh:
        fh.write(sheet_html(sheet_items(rows), key="w47-ct-truth-jpeg", header=SHEET1_HEADER,
                            settled="Not asked, all three agree", dl="W47-ct-truth-jpeg-answers.json"))


def cmd_sheet(a):
    """Rewrite the sheet from draft-truth.jsonl as it stands: no reader runs, and answers already saved in the
    browser stay (same storage key). With --rev, the second sheet from rev2/draft-truth.jsonl."""
    if getattr(a, "rev", False):
        write_sheet2([json.loads(l) for l in open(os.path.join(REV, "draft-truth.jsonl"), encoding="utf-8")])
        print(os.path.join(SHEET, "index.html"))
        return
    write_sheet([json.loads(l) for l in open(os.path.join(POOL, "draft-truth.jsonl"), encoding="utf-8")])
    print(os.path.join(SHEET, "index.html"))


def fold(rows, answers):
    """W47.ct-read's truth: per photo, the agreed fields, then each disputed field as the owner answered it.
    An answer is {"pick": "<a reading>" | "other" | "not on the label", "text": "<typed value>"}; an unanswered
    disputed field stays out of the truth and is counted; the owner's free notes on a photo (answers[id][NOTES]) are
    carried as `notes`, None when blank: they can say an agreed field is wrong or something on the label has no
    field, and the scoring session reads them before it scores that photo; an unanswered control keeps its agreed value. `ruled` lists
    the fields the owner answered: the drafters (`drafters`) may be scored only on those (FLD-9), and a control the
    owner overturned is counted in `controls_overturned`. Returns (truth rows, unanswered count)."""
    truth, missing = [], 0
    for r in rows:
        if not all(r["parsed"]):
            continue
        fields, ruled, overturned = dict(r["agreed"]), [], []
        notes = clean(((answers.get(r["id"]) or {}).get(NOTES) or {}).get("text"))
        for d in r["disputed"] + r.get("controls", []):
            ans = (answers.get(r["id"]) or {}).get(d["field"])
            if not ans or not ans.get("pick"):
                missing += d in r["disputed"]
                continue
            pick = ans["pick"]
            if pick == "not on the label":
                v = None
            elif pick == "other":
                v = clean(ans.get("text"))
            else:
                v = pick
            if d in r.get("controls", []) and not agree("x" if d["field"] == "kind" else d["field"], v,
                                                          fields.get(d["field"])):
                overturned.append(d["field"])
            fields[d["field"]] = v
            ruled.append(d["field"])
        truth.append({"id": r["id"], "path": r["path"], "colour": r["colour"], "stratum": r["repository"],
                      "fields": fields, "ruled": ruled, "controls_overturned": overturned,
                      "drafters": r.get("readers", []), "complete": len(fields) == len(FIELDS) + 1,
                      "notes": notes})
    return truth, missing


def cmd_fold(a):
    if FIELDS is FIELDS_REV:
        return cmd_fold_rev(a)
    rows = [json.loads(l) for l in open(os.path.join(POOL, "draft-truth.jsonl"), encoding="utf-8")]
    truth, missing = fold(rows, json.load(open(a.answers, encoding="utf-8")))
    with open(os.path.join(POOL, "truth.jsonl"), "w", encoding="utf-8") as fh:
        for t in truth:
            fh.write(json.dumps(t, ensure_ascii=False) + "\n")
    print(f"{len(truth)} photos in the truth, {sum(t['complete'] for t in truth)} complete; "
          f"{missing} disputed fields unanswered; {sum(len(t['ruled']) for t in truth)} fields owner-ruled; "
          f"controls overturned: {sum(len(t['controls_overturned']) for t in truth)} of {CONTROLS}")


# --- the revised truth ----------------------------------------------------------------------------------------------
# Per photo and field, the first source that has it: the owner's ruling on the first sheet, a value his notes give,
# his rules (a box label carries no folder title), then the three readers' unanimous reading on the revised prompt.
# The first build's unruled agreed values are not carried: the prompt changed under them, so the readers read again.
# What is left is open and goes on the second sheet, with CONTROLS unanimous reader fields mixed in unmarked, and a
# which-way-up question wherever the upright pick and the owner's notes disagree.

OWNER = ("sheet", "note", "rule", "sheet2")   # the sources that are the owner's, so a drafter may be scored on them


def canon(field, v):
    """The truth's spelling of a container: the type and its own number ("Box 34", from "Box 34 of 201", "BOX #34",
    "Box 34/201" or a bare "34"). Other fields are kept as written; the scoring compares them case-folded."""
    if field != "container" or v is None:
        return v
    m = CONTAINER.search(v)
    if m:
        kind = {"vol": "volume"}.get(m.group(1).lower(), re.sub(r"\s+", " ", m.group(1).lower()))
        num = re.sub(r"^0+(?=\d)", "", m.group(2))   # "Box 9", not "Box 09" (owner, 2026-11-05)
        return f"{kind.capitalize()} {num.upper() if num[-1:].isalpha() else num}"
    bare = re.fullmatch(r"\s*(?:no\.?|#)?\s*(\d+[a-z]?)\s*", v, re.I)
    return f"Box {bare.group(1)}" if bare else v


def jsonl(path):
    return [json.loads(l) for l in open(path, encoding="utf-8")] if os.path.exists(path) else []


def _txt(v):
    return re.sub(r"[^a-z0-9]+", " ", str(v).lower()).strip()


# Fields the repeat rule leaves alone: a folder or series number legitimately repeats a number elsewhere on the
# label ("5" as the folder of "Box 5"), and a container is the label's own subject.
REPEAT_EXEMPT = {"kind", "folder", "container", "series"}
TITLE_FIELDS = {"collection_title", "collection_subtitle", "box_title", "series_title", "folder_title"}


COUNT_REST = re.compile(r"(?:of|/)\s*\d+[a-z]?", re.I)   # "of 201" in "Box 34 of 201": the count the box number drops


def _part_in(part, fields, only):
    t = _txt(part)
    if not t:
        return []
    hit = [k for k, w in fields.items() if w and k != "kind" and (only is None or k in only)
           and re.search(r"(?<![a-z0-9])" + re.escape(t) + r"(?![a-z0-9])", _txt(w))]
    if only is None and not hit:
        # Pieces of several settled fields together ("Series III, Correspondence": the series and its title; "5-9":
        # the box and folder the owner's mark rule reads) are extraneous as well (owner, 2026-11-05: "I don't need to
        # be shown already settled extraneous things"): every word of the part is already in the settled text.
        words = set(re.findall(r"[a-z0-9]+", t))
        have = set()
        for k, w in fields.items():
            if w and k != "kind":
                have |= set(re.findall(r"[a-z0-9]+", _txt(w)))
        if words and words <= have:
            hit = [k for k, w in fields.items() if w and k != "kind" and words & set(re.findall(r"[a-z0-9]+", _txt(w)))]
    if only is None and not hit and fields.get("container"):
        # The owner's box-number rule: "Box 34 of 201" is the settled "Box 34", and "of 201" is the count it drops,
        # not a mark of its own (owner, 2026-11-05, photo d6c863c11630 on the second sheet).
        if canon("container", part) == fields["container"] or COUNT_REST.fullmatch(part.strip()):
            hit = ["container"]
    return hit


def repeats_in(v, fields, only=None):
    """The settled fields (of `only`, if given) that hold reading v, word-bounded after case and punctuation are
    folded. A reading joined with ";" ("Records; Box 34 of 201") repeats when each of its parts does."""
    parts = [x for x in re.split(r"\s*;\s*", v or "") if x.strip()]
    if not parts:
        return []
    found = []
    for x in parts:
        hit = _part_in(x, fields, only)
        if not hit:
            return []
        found += [k for k in hit if k not in found]
    return found


def repeat_of(readings, fields):
    """Owner, 2026-11-05, on the second sheet: one piece of label text goes in one field. True when every reading
    offered for a field only repeats text already settled in another field on the photo (the collection title
    offered again as the box title, "CBI 154" as an other mark when it is the collection number), so the field is
    settled as not on the label instead of asked. A reading that adds anything to the settled text stays asked."""
    vals = [r for r in readings if r]
    return bool(vals) and all(repeats_in(v, fields) for v in vals)


def drop_repeats(readings, fields):
    """The owner, the same evening: a field still asked does not offer a reading that only repeats settled text
    ("91/115 c", the collection number, offered as an other mark beside a new reading). The empty reading stays."""
    return [r for r in readings if not r or not repeats_in(r, fields)]


def revise_rows():
    rows = build(sample())
    old = {t["id"]: t for t in jsonl(os.path.join(CACHE, "pool-jpeg", "truth.jsonl"))}
    first = {t["id"]: t for t in jsonl(os.path.join(CACHE, "pool-jpeg", "draft-truth.jsonl"))}
    notes = json.load(open(NOTE_RULINGS, encoding="utf-8"))
    _, turn_q = upright_check()
    order = ["kind"] + FIELDS
    st = collections.Counter()
    out = []
    for r in rows:
        n, o = notes.get(r["id"], {}), old.get(r["id"], {})
        fields, src = {}, {}

        def put(f, v, how):
            if f in order and f not in fields and f not in n.get("unsure", []):
                fields[f], src[f] = canon(f, v), how
        for f in o.get("ruled", []):
            put(f, o["fields"].get(f), "sheet")
        for f, v in n.get("fields", {}).items():
            if f not in n.get("confirm", []):
                put(f, v, "note")
        ok = all(r["parsed"])
        if ok:
            for f, v in r["agreed"].items():
                put(f, v, "readers")
        if fields.get("kind") == "box label" and src.get("folder_title") != "note" and \
                not (src.get("folder_title") == "readers" and fields["folder_title"] is None):
            if src.get("folder_title") == "sheet" and fields["folder_title"] is not None:
                st["sheet rulings of a folder title on a box label, overridden by the rule"] += 1
            fields.pop("folder_title", None)
            src.pop("folder_title", None)
            put("folder_title", None, "rule")
        open_ = []
        disputed = {d["field"]: d for d in r["disputed"]} if ok else {}
        lines, boxes = lines_of(r["id"]), [((draft_of(r["id"], k) or {}).get("parsed") or {}).get("label_box")
                                           for k in READERS]
        for f in order:
            if f in fields or f in n.get("unsure", []):
                continue
            readings = disputed[f]["readings"] if f in disputed else []
            if f in n.get("confirm", []):
                v = n["fields"][f]
                readings = [v] + [x for x in readings if not agree(f, x, v)]
                if not disputed.get(f) and ok and r["agreed"].get(f) is not None and not agree(f, r["agreed"][f], v):
                    readings.append(r["agreed"][f])
            if f not in REPEAT_EXEMPT and f not in n.get("confirm", []):
                if f == "date":
                    # The exception, the owner's: a date inside a settled title (the collection's "1959-1987") is
                    # the date as well, when the readings give one value. Only inside a title: "2007-119" repeats
                    # an accession and is no date, so it stays asked.
                    dates = list(dict.fromkeys(x for x in readings if x))
                    if len(dates) == 1 and repeats_in(dates[0], fields, TITLE_FIELDS):
                        put(f, dates[0], "rule")
                        st["date inside a settled title, taken as the date (rule)"] += 1
                        continue
                elif repeat_of(readings, fields):
                    put(f, None, "rule")
                    st["reading only repeats settled text, not on the label (rule)"] += 1
                    continue
                else:
                    kept = drop_repeats(readings, fields)
                    st["repeated readings dropped from a question still asked"] += len(readings) - len(kept)
                    readings = kept
            box, how = field_place(f, readings, lines, boxes)
            open_.append({"field": f, "readings": readings, "box": box, "placed": how})
        if not ok:
            st["a reader's reply did not parse"] += 1
        f1 = first.get(r["id"], {})
        for f, v in (f1.get("agreed") or {}).items():
            if f in FIELDS_REV or f == "kind":
                if src.get(f) == "readers" and f not in o.get("ruled", []):
                    st["first build agreed, unruled, unanimous again"] += 1
                    st["first build agreed, unruled, same value again"] += agree("x" if f == "kind" else f,
                                                                                fields[f], v)
                elif f not in o.get("ruled", []):
                    st["first build agreed, unruled, now open or the owner's"] += 1
        out.append({"id": r["id"], "path": r["path"], "colour": r["colour"], "stratum": r["repository"],
                    "turn": r["turn"], "upright": r.get("upright"), "turn_question": turn_q.get(r["id"]),
                    "fields": fields, "src": src, "open": open_, "controls": [],
                    "cut_off": n.get("cut_off", []), "unsure": n.get("unsure", []), "notes": o.get("notes"),
                    "drafters": list(READERS), "first_build_notes": bool(o.get("notes"))})
    # the controls: unanimous reader fields, half with a value and half agreed empty, drawn with the seed
    cands = sorted((x["id"], f) for x in out for f, s in x["src"].items() if s == "readers" and f != "kind"
                   and x["fields"][f] is not None)
    empty = sorted((x["id"], f) for x in out for f, s in x["src"].items() if s == "readers" and f != "kind"
                   and x["fields"][f] is None)
    rng = random.Random(SEED + 1)
    by = {x["id"]: x for x in out}
    for mid, f in rng.sample(cands, min(CONTROLS - CONTROLS // 2, len(cands))) + \
            rng.sample(empty, min(CONTROLS // 2, len(empty))):
        x, v = by[mid], by[mid]["fields"][f]
        boxes = [((draft_of(mid, k) or {}).get("parsed") or {}).get("label_box") for k in READERS]
        box, how = field_place(f, [v] if v else [], lines_of(mid), boxes)
        x["controls"].append({"field": f, "readings": [v] if v else [], "box": box, "placed": how})
    return out, st


def asked_rev(x):
    order = ["kind"] + FIELDS
    return sorted(x["open"] + x["controls"], key=lambda d: order.index(d["field"]))


def sheet2_items(rows):
    out = []
    for x in rows:
        ask = asked_rev(x)
        if not ask and not x["turn_question"]:
            continue
        on = {d["field"] for d in ask}
        fields = []
        if x["turn_question"]:
            fields.append({"field": "_turn", "label": LABELS["_turn"], "readings": [], "box": None,
                           "placed": "turn", "options": TURN_OPTIONS})
        fields += [{"field": d["field"], "label": LABELS[d["field"]], "readings": d["readings"], "box": d["box"],
                    "placed": d["placed"]} for d in ask]
        out.append({"id": x["id"], "n": len(out) + 1, "img": os.path.relpath(image_of(x["id"]), SHEET),
                    "colour": "box (Red)" if x["colour"] == "Red" else "folder (Purple)",
                    "agreed": {f: v for f, v in x["fields"].items() if v and f not in on}, "fields": fields})
    return out


SHEET2_HEADER = """<b>Container labels, second round.</b> Your answers and notes from the first sheet are in: the
field list now has a box title, a series title, a collection subtitle, a date or time period and other identifying
marks; Series and Accession only when the label says so; the box number alone; nothing inferred; and the photos you
took out are gone. The photos were turned upright again and three readers read them again. What is left is below:
fields the readers do not all agree on, values you typed in a note that are worth checking letter by letter, and a
few fields where they did agree, mixed in as a check. Where a photo asks which way up it is, the turning step and your
notes disagreed. Each pink box is roughly where the field is written; it does not say which reading is right. The grey
line lists what is already settled (your answers, your notes, all three readers, or your rules). A reading that only
repeats text settled in another field is not asked: that field is settled as not on the label, except a date inside
a title, which is taken as the date. "Turn photo" turns a photo still
shown the wrong way, with its boxes; say so in its notes too."""


def cmd_revise(a):
    """The revised truth (rev2/truth.jsonl: settled fields only), the second sheet and segbench-results/ct-truth-revised.md."""
    rows, st = revise_rows()
    with open(os.path.join(REV, "draft-truth.jsonl"), "w", encoding="utf-8") as fh:
        for x in rows:
            fh.write(json.dumps(x, ensure_ascii=False) + "\n")
    write_rev_truth(rows)
    write_sheet2(rows)
    write_rev_results(rows, st)
    print(f"{REV_RESULTS}; sheet {os.path.join(SHEET, 'index.html')}")


def write_sheet2(rows):
    os.makedirs(SHEET, exist_ok=True)
    with open(os.path.join(SHEET, "index.html"), "w", encoding="utf-8") as fh:
        fh.write(sheet_html(sheet2_items(rows), key="w47-ct-truth-revise", header=SHEET2_HEADER,
                            settled="Already settled", dl="W47-ct-truth-revise-answers.json"))


def prompt_examples(x):
    """The fields whose truth value is one of PROMPT_REV's examples. Several examples were taken from the owner's
    notes ("Box 34", "3/5/57", the 5-9 and 8.5 folder marks...), so the drafters, which read with that prompt, may
    have copied them: W47.ct-read leaves these fields out when it scores the drafters. Generic examples are included
    too, the same way."""
    ex = set(re.findall(r'"([^"]+)"', PROMPT_REV)) | {"Box 5", "9", "Box 8", "5"}
    return [f for f, v in x["fields"].items() if v and f != "kind" and any(norm(f, v) == norm(f, e) for e in ex)]


def write_rev_truth(rows):
    with open(os.path.join(REV, "truth.jsonl"), "w", encoding="utf-8") as fh:
        for x in rows:
            ruled = [f for f, s in x["src"].items() if s in OWNER]
            fh.write(json.dumps({"id": x["id"], "path": x["path"], "colour": x["colour"], "stratum": x["stratum"],
                                 "fields": x["fields"], "src": x["src"], "ruled": ruled,
                                 "open": [d["field"] for d in x["open"]], "unsure": x["unsure"],
                                 "cut_off": x["cut_off"], "drafters": x["drafters"], "notes": x["notes"],
                                 "prompt_example": prompt_examples(x),
                                 "turn_question": x["turn_question"], "reread": x.get("reread", False),
                                 "complete": not x["open"] and len(x["fields"]) + len(x["unsure"]) == len(FIELDS) + 1},
                                ensure_ascii=False) + "\n")


def cmd_fold_rev(a):
    """The second sheet's answers into rev2/truth.jsonl: an open field or control answered becomes the owner's
    (`sheet2`); an answered which-way-up question that turns the photo further marks it `reread` (its reader
    readings were made on the wrong turn, so its reader-settled fields are open again until the readers rerun)."""
    rows = jsonl(os.path.join(REV, "draft-truth.jsonl"))
    answers = json.load(open(a.answers, encoding="utf-8"))
    c = collections.Counter()
    for x in rows:
        ans = answers.get(x["id"]) or {}
        t = (ans.get("_turn") or {}).get("pick")
        if t in TURN_OPTIONS and TURN_OPTIONS.index(t):
            x["reread"] = True
            c["photos to reread"] += 1
            for f in [f for f, s in x["src"].items() if s == "readers"]:
                x["fields"].pop(f)
                x["src"].pop(f)
                x["open"].append({"field": f, "readings": [], "box": None, "placed": "none"})
        keep = []
        for d in x["open"] + x["controls"]:
            got = ans.get(d["field"]) or {}
            pick = got.get("pick")
            if not pick:
                keep += [d] if d in x["open"] else []
                c["open, unanswered"] += d in x["open"]
                continue
            v = None if pick == "not on the label" else clean(got.get("text")) if pick == "other" else pick
            if d in x["controls"]:
                c["controls answered"] += 1
                c["controls overturned"] += not agree("x" if d["field"] == "kind" else d["field"], v,
                                                      x["fields"].get(d["field"]))
            x["fields"][d["field"]], x["src"][d["field"]] = canon(d["field"], v), "sheet2"
            c["fields ruled"] += 1
        x["open"] = keep
        note = clean((ans.get(NOTES) or {}).get("text"))
        if note:
            x["notes2"] = note
            c["notes"] += 1
    with open(os.path.join(REV, "draft-truth.jsonl"), "w", encoding="utf-8") as fh:
        for x in rows:
            fh.write(json.dumps(x, ensure_ascii=False) + "\n")
    write_rev_truth(rows)
    print(dict(c))


def write_rev_results(rows, st):
    import gateway_gemini as G
    uc, turn_q = upright_check()
    items = sheet2_items(rows)
    srcs = collections.Counter(s for x in rows for s in x["src"].values())
    n_ctl = sum(len(x["controls"]) for x in rows)
    drop = collections.Counter(DROPPED.values())
    led = gateway_ledger()
    walls = {k: [w for w in ((draft_of(x["id"], k) or {}).get("wall_s") for x in rows) if w] for k in READERS}
    L = ["# Container labels: the truth revised from the owner's sheet notes (W47.ct-truth-revise)", "",
         f"Written by `scripts/segbench/ct_truth.py --rev revise`. The owner answered the first sheet "
         f"(`ct-truth.md`) on 2026-11-05 and left notes on 127 photos. Those notes changed the field list and the "
         f"reading rules, took photos out and showed that 36 were shown turned; this build carries all of it. Label "
         f"values stay in the cache: this page gives counts only.", "",
         "## What changed", "",
         f"- **Fields.** {len(FIELDS_REV)} fields, up from {len(FIELDS_FIRST)}: added "
         + ", ".join(LABELS[f].lower() for f in NEW_FIELDS) + ". The owner records these on many labels.",
         "- **Rules** (in the prompt and in the truth): nothing inferred; Series and Accession only when the label "
         "says so (\"ACCN\" counts), otherwise the text is an other identifying mark; the container is the box "
         "number alone; a folder mark like \"5-9\" or \"8.5\" is box 5 folder 9, box 8 folder 5; no folder title "
         "is read off a box label; a cut-off title is flagged. The scoring compares values case-folded, so title "
         "case is not part of the truth; title case and the user's standard names for repositories and "
         "collections are Processor features (W47.ct-normalise).",
         f"- **Photos taken out:** {len(DROPPED)} ("
         + ", ".join(f"{v} {k}" for k, v in sorted(drop.items(), key=lambda kv: -kv[1])) + f"), leaving "
         f"{len(rows)}: {sum(x['colour'] == 'Red' for x in rows)} box (Red), "
         f"{sum(x['colour'] == 'Purple' for x in rows)} folder (Purple).", "",
         "## Upright", "",
         "The first build turned each JPEG to match its PDF, and those PDFs are not always upright. Apple Vision's "
         "text scores at the four turns (`ocr_orient.swift`) gave no clear win on any of the 218 photos: the labels "
         "are short or handwritten, and Vision reads upside-down text too. So the turn is Gemini 3.7 Flash's pick "
         "among the four turns shown side by side (in an order shuffled per photo), measured against the owner's "
         "notes.", "",
         "| | photos | as the notes say |", "|---|---|---|",
         f"| the owner called it turned | {uc['flagged']} | {uc['flagged, turned']} turned |",
         f"| ... and gave the direction | {uc['flagged with a direction']} | "
         f"{uc['flagged with a direction, matched']} turned that way |",
         f"| the owner did not flag it | {uc['not flagged']} | {uc['not flagged, left as it was']} left as they were |",
         "",
         f"The {len(turn_q)} photos where the pick and the notes disagree ("
         + ", ".join(f"{v} {k}" for k, v in collections.Counter(turn_q.values()).most_common())
         + ") are asked on the second sheet; the readers read them at the pick's turn, and a photo the owner turns "
         "further is reread (its reader-settled fields go back to open at the fold). An unflagged photo the pick "
         "turned may also be one the owner saw turned and did not note, so the second row is a floor on the "
         "pick's agreement, not an error count.", "",
         "## Where each settled field came from", "",
         "| source | fields |", "|---|---|"]
    for s, label in (("sheet", "the owner's ruling on the first sheet"), ("note", "a value the owner's notes give"),
                     ("rule", "the owner's rules (no folder title on a box label; text already settled is not a "
                              "second field; a date inside a title is the date too)"),
                     ("readers", "the three readers, unanimous on the revised prompt")):
        L.append(f"| {label} | {srcs[s]} |")
    pe = [f for x in rows for f in prompt_examples(x)]
    L += ["", f"**Prompt examples.** {len(pe)} settled fields ({sum(x['src'][f] in OWNER for x in rows for f in prompt_examples(x))} "
          f"of them the owner's) hold a value that is also one of the prompt's examples, and several examples were "
          f"taken from the owner's notes, so the drafters may have copied them; each truth row lists them as "
          f"`prompt_example`, and W47.ct-read leaves them out when it scores the drafters. A route W47.ct-read "
          f"tests reads with invented examples.", "",
          f"Fields left out of scoring because the owner could not read them: "
          f"{sum(len(x['unsure']) for x in rows)}. Titles the owner marked cut off: "
          f"{sum(len(x['cut_off']) for x in rows)}."]
    L += ["", "The first build's agreed fields that the owner did not rule, read again on the revised prompt "
          "(a measure of how much the new fields and rules moved the readers):", ""]
    for k, v in sorted(st.items()):
        L.append(f"- {k}: {v}")
    L += ["", "## Open, per field (the second sheet)", "",
          "| field | open on box photos | open on folder photos | settled by the readers |", "|---|---|---|---|"]
    for f in ["kind"] + FIELDS:
        o = collections.Counter(x["colour"] for x in rows for d in x["open"] if d["field"] == f)
        rd = sum(x["src"].get(f) == "readers" for x in rows)
        L.append(f"| {LABELS[f]} | {o['Red']} | {o['Purple']} | {rd} |")
    asked_n = sum(len(i["fields"]) for i in items)
    L += ["", f"The second sheet asks {asked_n} questions on {len(items)} photos: "
          f"{sum(len(x['open']) for x in rows)} open fields, {n_ctl} controls (unanimous reader fields, unmarked) "
          f"and {len(turn_q)} which-way-up questions. It is `pool-jpeg/rev2/sheet/index.html` in the cache "
          f"(private: corpus images); `ct_truth.py --rev fold ANSWERS.json` folds it into `rev2/truth.jsonl`.", "",
          "## Cost", "",
          f"Upright check: {len(jsonl(UPRIGHT_LEDGER))} calls, ${upright_spent():.2f}. Readers on the gateway: "
          f"{len(led)} calls, ${sum(G.charge(r) for r in led):.2f} ({G.billed_note(led)}). Item total "
          f"${upright_spent() + sum(G.charge(r) for r in led):.2f} of its ${REV_CAP:.2f} cap, real money on the "
          f"Stanford gateway. "
          + " ".join(f"{NAMES[k]}: {sum(w) / 60:.0f} min on this Mac, $0." for k, w in walls.items()
                     if w and k != GATEWAY), "",
          "## Measurement card", "",
          "- **Truth:** the owner's rulings on the first sheet and the values his notes give, his reading rules, "
          "and, for the rest, the three readers' unanimous reading on the revised prompt (agreement, not truth, "
          f"checked by {n_ctl} controls on the second sheet). The readers are the truth's drafters: W47.ct-read "
          "scores any of them only on the owner's fields (`ruled`), and reports the rest as agreement (FLD-9). "
          "The note values were transcribed from his notes by this session, field by field; long typed titles go "
          "back to him on the second sheet to check. Fields whose value is a prompt example are marked and not "
          "scored against the drafters.",
          "- **Selection:** the first build's stratified draw by repository from the Finder tags, less the photos "
          "the owner took out. The pairing cut's lean stands: 54 photos (43 of the 120 Red) were left out at "
          f"correlation under {MIN_CORR}, and the ones checked were true pairs whose PDF was cropped or deskewed, "
          "so the set leans to little-changed PDFs. They were not recovered here; W47.ct-read reports the lean "
          "beside every figure.",
          "- **Comparison:** the same upright JPEG, prompt and settings for all three readers.",
          "- **Noise:** one pass at temperature 0; no rerun floor.",
          "- **Scope:** a truth under construction. Settles which fields W47.ct-read can score now; says nothing "
          "about which reader is right.", ""]
    with open(REV_RESULTS, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))


# --- the final truth (W47.ct-truth-final, from the owner's second-sheet answers and notes of 2026-11-05) ------------
# `ct_truth.py --final <command>` works in pool-jpeg/final/: `upright` (the photos read at the wrong turn, at the
# owner's turn, checked by Gemini), `render`, `lines`, `collect`, `gateway` (the three readers on those photos only),
# `finish` (final/truth.jsonl, the third sheet, segbench-results/ct-truth-final.md) and `fold ANSWERS.json`.

FINAL = os.path.join(POOL, "final")
FINAL_RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "ct-truth-final.md")
FINAL_NOTES = os.path.join(FINAL, "note-rulings.json")   # values the second sheet's notes give (private)
REV_ANSWERS = os.path.join(REV, "answers-owner-20261105.json")
FINAL_CAP = 0.50   # the item's gateway spend, the upright check and the readers together; under the $7 rule
FIELDS_FINAL = [f for f in FIELDS_REV if f != "place"]   # "I don't think Place is a relevant field for boxes and folders"
DROPPED_FINAL = {"aad3358690bb": "\"exclude this from training\"", "6756d60908a3": "\"exclude this from training\"",
                 "1dac6accbfb7": "\"very unusual\"", "ee7bd7e7d59f": "\"just a document\""}
CARRY = ("a3d642a470d9", "a2c277485aa5", "6446f85e887f", "4dcb24712d18", "6ad51db0c192")  # "Fill in per last few boxes"
CARRY_FROM = 4   # the last few: the four box photos before it on the sheet, in its directory
CUT_NOTES = {"e05ca8dcd0d4": "folder_title", "4691dd8b79b9": "folder_title", "13fb82409b02": "folder_title",
             "fb9626e4077a": "folder_title"}   # "the title should not simply be provided as the cut off text"
ILLEGIBLE = {"fb9626e4077a": ["folder_title"]}   # "cut off and illegible"
ILLEGIBLE_PHOTO = {"532774989cd1"}   # "blurred and can't be read ... crucial information for the user"
UNLABELLED = {"4a9f2210cb6d"}   # "a folder with no label ... an untitled and unnumbered folder"
TURN_NOTES = {"6034e86e328f": 90, "556fdc267d90": None}   # further PIL turn (anticlockwise); None: no direction given
# Internal marks (the owner's notes on seven photos and more): text beside a serial number, "Archival Media", location
# notes, the archive's logos, barcodes and notes about the box itself are not identifying marks.
INTERNAL = re.compile(r"archival\s+media|acid[\s-]*free|\bbar\s*code\b|^\s*(shelf\s+)?location\b|\bCHF\b|\blogo\b", re.I)
LOCATION_MARK = re.compile(r"^\s*\d{2,3}-[A-Z]-\d+\s*$")   # a shelf mark such as "40-E-5"
BARCODE = re.compile(r"^\s*\d(?:\s?\d){9,}\s*$")           # ten or more digits, a library barcode's number
OWNER_FINAL = ("sheet", "note", "sheet2", "note2", "sheet3")   # the owner's own answers; "rule" is reported apart
PROMPT_FINAL = (PROMPT_REV
                .replace(" \"place\": the city or state of the repository, if written,\n", "")
                .replace("e.g. a shelf or location mark \"40-E-5\" or an unlabelled number \"84-044\"",
                         "e.g. an unlabelled number \"84-044\"")
                .replace("- A title cut off by the edge of the photo or hidden ends with \"...\".\n",
                         "- A title cut off by the edge of the photo or hidden ends with \"...\".\n"
                         "- Leave out the archive's internal marks: text or numbers beside a serial number, "
                         "\"Archival Media\", location or shelf-location notes, the archive's logo, barcodes and their "
                         "numbers, and notes about the box itself such as \"Acid Free\".\n"))
assert PROMPT_FINAL.count("Leave out the archive's internal marks") == 1 and "\"place\"" not in PROMPT_FINAL
FINAL_MODE = False


def use_final():
    """Point the shared steps at final/: the reread photos at the owner's turn, the final fields and prompt."""
    global POOL, PAGES, LINES, SHEET, SAMPLE, FIELDS, PROMPT, MAX_TOKENS, GATEWAY_CAP, RESULTS, FINAL_MODE
    POOL, PAGES, LINES, SHEET = FINAL, os.path.join(FINAL, "pages"), os.path.join(FINAL, "lines"), \
        os.path.join(FINAL, "sheet")
    SAMPLE, FIELDS, PROMPT, MAX_TOKENS, RESULTS = os.path.join(FINAL, "sample.jsonl"), FIELDS_FINAL, PROMPT_FINAL, \
        640, FINAL_RESULTS
    GATEWAY_CAP = FINAL_CAP - final_upright_spent()
    FINAL_MODE = True


def final_upright_spent():
    import gateway_gemini as G
    return sum(G.charge(r) for n in ("upright-calls.jsonl", "check-calls.jsonl") for r in jsonl(os.path.join(FINAL, n)))


def further_of(pick):
    """The sheet's which-way-up answer as the further PIL turn (anticlockwise degrees): a quarter turn clockwise is
    270. TURN_OPTIONS' index times 90 is the turn clockwise."""
    return (-90 * TURN_OPTIONS.index(pick)) % 360


def ask_upright(mid, image_path, ledger, cap, exclude=()):
    """Gemini's pick of the upright turn among the four (or those not in `exclude`), as in cmd_upright: the turn,
    in PIL degrees, that makes `image_path` upright, or None. Every call is in `ledger` before its reply is used."""
    import base64
    import io
    from PIL import Image
    import gateway_gemini as G
    worst = (4 * 1200 * G.PRICE[0] + 2048 * G.PRICE[1]) / 1e6
    if final_upright_spent() + sum(G.charge(r) for r in jsonl(os.path.join(FINAL, "gateway-calls.jsonl"))) + worst > cap:
        raise SystemExit(f"cap: ${cap:.2f} would be passed")
    order = [d for d in (0, 90, 180, 270) if d not in exclude]
    random.Random(f"{SEED}/final/{mid}").shuffle(order)
    content = []
    with Image.open(image_path) as im:
        im = im.convert("RGB")
        im.thumbnail((UPRIGHT_SIDE, UPRIGHT_SIDE))
        for k, deg in enumerate(order, 1):
            buf = io.BytesIO()
            im.rotate(deg, expand=True).save(buf, "JPEG", quality=85)
            content += [{"type": "text", "text": f"Image {k}:"},
                        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,"
                                                                   + base64.b64encode(buf.getvalue()).decode()}}]
    n = len(order)
    content.append({"type": "text", "text": UPRIGHT_PROMPT.replace("These four images", f"These {n} images")
                    .replace("1, 2, 3 or 4", ", ".join(str(k) for k in range(1, n)) + f" or {n}")})
    body = {"model": G.MODEL, "temperature": 0, "max_tokens": 2048, "reasoning_effort": "low",
            "messages": [{"role": "user", "content": content}]}
    t = time.time()
    for attempt in range(3):
        r = G.request("/chat/completions", body)
        if r.status_code in (429, 500, 502, 503, 504) and attempt < 2:
            time.sleep(10 * (attempt + 1))
            continue
        break
    got = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
    usage = got.get("usage") or {}
    rec = G.with_gateway_cost({"id": mid, "http": r.status_code, "t": t, "usage": usage,
                               "cost": round(G.cost(usage), 6), "order": order}, r)
    reply = ((got.get("choices") or [{}])[0].get("message") or {}).get("content") if r.status_code == 200 else None
    m = re.search(rf"\b([1-{n}])\b", reply or "")
    rec.update(reply=(reply or "")[:40], pick=order[int(m.group(1)) - 1] if m else None)
    with open(ledger, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec) + "\n")
    return rec["pick"]


def cmd_upright_final(a):
    """final/sample.jsonl: the photos read at the wrong turn, each at the owner's turn: the 13 he turned on the second
    sheet, 6034e86e328f a quarter turn anticlockwise, and 556fdc267d90 ("needs to be rotated", no direction), whose
    turn is Gemini's pick among the three it was not shown at. Then the rendered photos are checked: Gemini picks the
    upright turn of each among all four, and a photo whose pick is not "as it is" gets a which-way-up question."""
    os.makedirs(FINAL, exist_ok=True)
    answers = json.load(open(REV_ANSWERS, encoding="utf-8"))
    rev = {r["id"]: r for r in jsonl(os.path.join(REV, "sample.jsonl"))}
    ledger = os.path.join(FINAL, "upright-calls.jsonl")
    out = []
    for mid, r in rev.items():
        if mid in DROPPED_FINAL:
            continue
        pick = ((answers.get(mid) or {}).get("_turn") or {}).get("pick")
        if pick in TURN_OPTIONS and TURN_OPTIONS.index(pick):
            further, how = further_of(pick), "sheet"
        elif mid in TURN_NOTES and TURN_NOTES[mid] is not None:
            further, how = TURN_NOTES[mid], "note"
        elif mid in TURN_NOTES:
            done = [x for x in jsonl(ledger) if x["id"] == mid and x.get("pick") is not None]
            further = done[-1]["pick"] if done else ask_upright(mid, os.path.join(REV, "pages", mid + ".jpg"),
                                                                ledger, FINAL_CAP, exclude=(0,))
            how = "gemini, among the three other turns"
        else:
            continue
        out.append(dict(r, turn_rev2=r["turn"], further=further, further_how=how, turn=(r["turn"] + (further or 0)) % 360))
    with open(os.path.join(FINAL, "sample.jsonl"), "w", encoding="utf-8") as fh:
        for r in out:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"{len(out)} photos to reread: " + ", ".join(f"{k} {v}" for k, v in
                                                      collections.Counter(r["further_how"] for r in out).items()))


def cmd_check_final(a):
    """The rendered photos at the final turn, checked: Gemini's pick among all four turns of each. Real money,
    about half a cent a photo, in final/check.jsonl."""
    import gateway_gemini as G
    ledger = os.path.join(FINAL, "check-calls.jsonl")
    done = {x["id"]: x for x in jsonl(os.path.join(FINAL, "check.jsonl"))}
    for r in sample():
        if r["id"] in done:
            continue
        if final_upright_spent() + sum(G.charge(x) for x in gateway_ledger()) > FINAL_CAP - 0.01:
            raise SystemExit("cap")
        p = ask_upright(r["id"], image_of(r["id"]), ledger, FINAL_CAP)
        with open(os.path.join(FINAL, "check.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"id": r["id"], "pick": p}) + "\n")
    c = collections.Counter(x["pick"] for x in jsonl(os.path.join(FINAL, "check.jsonl")))
    print(f"check: {dict(c)}; ${final_upright_spent():.4f} spent on the upright steps")


def _readings_rev2(mid, f):
    """The three readers' rev2 readings of field f, in the photo's fixed order (the readers read at rev2's turn)."""
    vals = [((json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}).get("parsed") or {}).get(f)
            for p in (os.path.join(REV, "draft", k, mid + ".json") for k in READERS)]
    return order_readings(mid, f, vals)


def strip_internal(v):
    """A reading with its internal-mark parts left out ("; "-joined parts), None when nothing is left."""
    if v is None:
        return None
    keep = [p for p in re.split(r"\s*;\s*", v) if p.strip() and not internal(p)]
    return "; ".join(keep) or None


def internal(part):
    return bool(INTERNAL.search(part) or LOCATION_MARK.match(part) or BARCODE.match(part))


def settle_open(x, f, readings, st, lines, boxes):
    """The second sheet's rules on a field left open: a reading only repeating settled text is not on the label, a
    date inside a settled title is the date, a box label has no folder title, internal marks are left out; what is
    left is asked. Returns True when the field was settled."""
    fields, src = x["fields"], x["src"]
    if f == "other":
        readings = list(dict.fromkeys(strip_internal(r) for r in readings))
    if f == "folder_title" and fields.get("kind") == "box label":
        fields[f], src[f] = None, "rule"
        st["box label, no folder title (rule)"] += 1
        return True
    if f not in REPEAT_EXEMPT:
        if f == "date":
            dates = list(dict.fromkeys(r for r in readings if r))
            if len(dates) == 1 and repeats_in(dates[0], fields, TITLE_FIELDS):
                fields[f], src[f] = dates[0], "rule"
                st["date inside a settled title (rule)"] += 1
                return True
        elif repeat_of(readings, fields):
            fields[f], src[f] = None, "rule"
            st["reading only repeats settled text (rule)"] += 1
            return True
        else:
            readings = drop_repeats(readings, fields)
    if f == "other" and readings == [None]:
        fields[f], src[f] = None, "rule"
        st["only internal marks read, not on the label (rule)"] += 1
        return True
    box, how = field_place(f, readings, lines, boxes)
    x["open"].append({"field": f, "readings": readings, "box": box, "placed": how})
    return False


def final_rows():
    """The final truth from rev2/draft-truth.jsonl as the second sheet's fold left it, with the owner's second-sheet
    notes applied in this order: the four photos out; Place dropped; a typed answer whose button was not pressed taken
    as typed; corrections the notes give; the reread photos refilled from the readers at the right turn; internal
    marks left out; cut-off and illegible titles flagged; carried fields filled from the boxes before on the sheet."""
    rows = [x for x in jsonl(os.path.join(REV, "draft-truth.jsonl")) if x["id"] not in DROPPED_FINAL]
    answers = json.load(open(REV_ANSWERS, encoding="utf-8"))
    notes = json.load(open(FINAL_NOTES, encoding="utf-8"))["fields"]
    reread = {r["id"]: r for r in sample()}
    st = collections.Counter()
    for x in rows:
        mid, fields, src = x["id"], x["fields"], x["src"]
        ans = answers.get(mid) or {}
        x.update(carried={}, illegible=[], cut_text={}, unlabelled=mid in UNLABELLED, controls=[],
                 illegible_photo=mid in ILLEGIBLE_PHOTO, reread_final=mid in reread, turn_question=None)
        in_rev = mid not in reread
        lines = lines_of_in(REV if in_rev else FINAL, mid)
        boxes = label_boxes_in(REV if in_rev else FINAL, mid)
        # Place is not a field for boxes and folders
        if "place" in fields:
            st[f"Place cells dropped ({src['place']})"] += 1
            fields.pop("place"), src.pop("place")
        st["Place cells dropped (open)"] += sum(d["field"] == "place" for d in x["open"])
        x["open"] = [d for d in x["open"] if d["field"] != "place"]
        if fields.get("container") and canon("container", fields["container"]) != fields["container"]:
            fields["container"] = canon("container", fields["container"])
            st["container number's leading zero dropped (\"Box 9\", not \"Box 09\")"] += 1
        # a value typed under "other" whose button was not pressed is the answer typed
        for d in list(x["open"]):
            g = ans.get(d["field"]) or {}
            if not g.get("pick") and clean(g.get("text")):
                fields[d["field"]], src[d["field"]] = canon(d["field"], clean(g["text"])), "sheet2"
                x["open"].remove(d)
                st["typed with the button not pressed, taken as typed"] += 1
        # what the owner left unanswered stays out and is counted, not asked a third time (the reread photos' open
        # cells are the fold's reopened reader cells, refilled below)
        x["unanswered"] = [] if mid in reread else [d["field"] for d in x["open"]]
        st["left unanswered on the second sheet, kept out"] += len(x["unanswered"])
        if mid not in reread:
            x["open"] = []
        # "other" pressed with nothing typed: carried (the five "fill in" photos), flagged (a cut-off title), or
        # asked again; folded as "not on the label" it would say the wrong thing
        x["_carry"] = []
        for f, g in ans.items():
            if f in (NOTES, "_turn") or f not in FIELDS_FINAL or not isinstance(g, dict):
                continue
            if g.get("pick") == "other" and not clean(g.get("text")) and src.get(f) == "sheet2":
                fields.pop(f), src.pop(f)
                if mid in CARRY:
                    x["_carry"].append(f)
                elif CUT_NOTES.get(mid) == f:
                    pass
                else:
                    st["\"other\" pressed with nothing typed, asked again"] += 1
                    x["_reask"] = x.get("_reask", []) + [f]
        # corrections the notes give; a rule cell on that photo is judged again against the corrected fields
        for f, v in notes.get(mid, {}).items():
            had = fields.get(f)
            fields[f], src[f] = canon(f, v), "note2"
            x["open"] = [d for d in x["open"] if d["field"] != f]
            st["corrected from the second sheet's notes"] += 1
            if had is not None and v is None:
                for g in [g for g, s in src.items() if s == "rule"]:
                    fields.pop(g), src.pop(g)
                    x["_reask"] = x.get("_reask", []) + [g]
                    st["rule cell judged again after a correction"] += 1
        # one piece of label text in one field (the owner's rule): an owner value repeating another owner field
        # word for word is asked again with the carried or reader reading beside it
        own = [(f, v) for f, v in fields.items() if v and f != "kind" and src[f] in OWNER_FINAL and f not in TITLE_FIELDS]
        for f, v in own:
            if any(g != f and w and norm(g, w) == norm(f, v) for g, w in fields.items()):
                x["_recheck"] = x.get("_recheck", []) + [f]
                st["owner value repeating another field word for word, asked again"] += 1
        # owner values the new internal-mark rule would drop: asked once more, never dropped silently
        if fields.get("other") and src.get("other") in OWNER_FINAL and \
                any(internal(p) for p in re.split(r"\s*;\s*", fields["other"])):
            x["_recheck"] = x.get("_recheck", []) + ["other"]
            st["owner value the internal-mark rule would drop, asked again"] += 1
        elif fields.get("other") and src.get("other") in ("readers", "rule") and \
                strip_internal(fields["other"]) != fields["other"]:
            fields["other"], src["other"] = strip_internal(fields["other"]), "rule"
            st["reader value with internal marks left out (rule)"] += 1
        # the reread: reader-settled fields and the fields reopened at the fold come from the readers at the right turn
        if mid in reread:
            for f in [f for f, s in src.items() if s in ("readers", "rule")]:
                fields.pop(f), src.pop(f)
            x["open"] = []
            ds = [((draft_of(mid, k) or {}).get("parsed")) for k in READERS]
            ok = all(d is not None for d in ds)
            st["reread photos"] += 1
            st["reread photos, a reply did not parse"] += not ok
            for f in ["kind"] + FIELDS_FINAL:
                if f in fields or f in x["unsure"] or f in x["cut_off"] or f in x["_carry"]:
                    continue
                # a reply that did not parse (a repetition loop at temperature 0 repeats on a rerun) settles nothing:
                # the field is asked, with the readings of the readers that did parse
                vals = [d.get(f) for d in ds if d is not None]
                g = "x" if f == "kind" else f
                if ok and all(agree(g, vals[0], v) for v in vals[1:]) and (f != "other" or strip_internal(vals[0]) == vals[0]):
                    fields[f], src[f] = canon(f, vals[0]), "readers"
                    st["reread: the three readers unanimous"] += 1
                elif settle_open(x, f, order_readings(mid, f, vals), st, lines, boxes):
                    pass
                else:
                    st["reread: open"] += 1
            # The owner's turn stands even where the check disagrees (it undid his turn on 9 of 15 and never picked a
            # half turn, so the arithmetic is not reversed: it is Gemini disagreeing with him, as on the second sheet).
            # The one photo turned by Gemini's own pick is asked.
            if reread[mid].get("further_how", "").startswith("gemini"):
                x["turn_question"] = "turned by the gateway's pick, the owner gave no direction"
        for f in x.pop("_reask", []):
            if f in fields:
                continue
            settle_open(x, f, _readings_rev2(mid, f), st, lines, boxes)
        for f in x.pop("_recheck", []):
            v = fields.pop(f)
            src.pop(f)
            readings = list(dict.fromkeys([v] + [r for r in _readings_rev2(mid, f) if r is not None]))
            box, how = field_place(f, readings, lines, boxes)
            x["open"].append({"field": f, "readings": readings, "box": box, "placed": how, "recheck": True})
        # cut off and illegible: the visible text is not the value; the field is flagged
        if mid in CUT_NOTES:
            f = CUT_NOTES[mid]
            v = fields.pop(f, None)
            src.pop(f, None)
            x["open"] = [d for d in x["open"] if d["field"] != f]
            if v:
                x["cut_text"][f] = v
            if f not in x["cut_off"]:
                x["cut_off"].append(f)
            st["titles flagged cut off"] += 1
        for f in ILLEGIBLE.get(mid, []):
            x["illegible"].append(f)
            st["fields flagged illegible"] += 1
        if mid in ILLEGIBLE_PHOTO:
            for f in FIELDS_FINAL:
                if f not in x["illegible"]:
                    fields.pop(f, None), src.pop(f, None)
                    x["illegible"].append(f)
            x["open"] = []
            st["photos flagged illegible"] += 1
    # carried: the field the label leaves out is the one the boxes before it on the sheet give (owner, "per last few
    # boxes"): the most common owner value among the CARRY_FROM box photos before it in its directory
    for i, x in enumerate(rows):
        for f in x.pop("_carry", []):
            d = os.path.dirname(x["path"])
            prev = [y for y in rows[:i] if os.path.dirname(y["path"]) == d and y["colour"] == "Red"
                    and y["id"] not in CARRY][-CARRY_FROM:]
            vals = [y["fields"][f] for y in prev if y["fields"].get(f) and y["src"].get(f) in OWNER_FINAL]
            groups = collections.Counter(norm(f, v) for v in vals)
            if vals and groups.most_common(1)[0][1] * 2 > len(vals):
                top = groups.most_common(1)[0][0]
                pick = collections.Counter(v for v in vals if norm(f, v) == top).most_common(1)[0][0]
                x["fields"][f], x["src"][f] = pick, "carried"
                x["carried"][f] = [y["id"] for y in prev if y["fields"].get(f) and norm(f, y["fields"][f]) == top]
                st["carried from the boxes before"] += 1
            else:
                lines, boxes = lines_of_in(REV, x["id"]), label_boxes_in(REV, x["id"])
                readings = [r for r in _readings_rev2(x["id"], f)]
                box, how = field_place(f, readings, lines, boxes)
                x["open"].append({"field": f, "readings": readings, "box": box, "placed": how, "carry": "none before"})
                st["to carry, but the boxes before give no value: asked"] += 1
    return rows, st


def _parsed_final(mid):
    return [((draft_of(mid, k) or {}).get("parsed")) is not None for k in READERS]


def _check_pick(mid):
    got = [x["pick"] for x in jsonl(os.path.join(FINAL, "check.jsonl")) if x["id"] == mid]
    return got[-1] if got else None


def lines_of_in(pool, mid):
    p = os.path.join(pool, "lines", mid + ".json")
    return json.load(open(p, encoding="utf-8")).get("lines", []) if os.path.exists(p) else []


def label_boxes_in(pool, mid):
    out = []
    for k in READERS:
        p = os.path.join(pool, "draft", k, mid + ".json")
        out.append(((json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}).get("parsed") or {})
                   .get("label_box"))
    return out


FINAL_CONTROLS = 10   # rule-settled cells put on the third sheet unmarked (P11-7: the rules had no control)


def pick_final_controls(rows):
    cands = sorted((x["id"], f) for x in rows for f, s in x["src"].items() if s == "rule" and not x["illegible_photo"])
    for mid, f in random.Random(SEED + 3).sample(cands, min(FINAL_CONTROLS, len(cands))):
        x = next(y for y in rows if y["id"] == mid)
        v = x["fields"][f]
        pool = FINAL if x["reread_final"] else REV
        box, how = field_place(f, [v] if v else [], lines_of_in(pool, mid), label_boxes_in(pool, mid))
        x["controls"].append({"field": f, "readings": [v] if v else [], "box": box, "placed": how})


def shown_settled(x, on):
    """Every truth the photo has that the sheet does not ask, with the value going into the truth."""
    out = {}
    for f in ["kind"] + FIELDS_FINAL:
        if f in on:
            continue
        if f in x["illegible"]:
            out[f] = "illegible (flagged)"
        elif f in x["cut_off"]:
            out[f] = "cut off (flagged, not transcribed)"
        elif f in x["unsure"]:
            out[f] = "left out, you could not read it"
        elif f in x.get("unanswered", []):
            out[f] = "left out, unanswered on the second sheet"
        elif f in x["fields"]:
            v = x["fields"][f]
            out[f] = (v if v is not None else "not on the label") + (" (carried from the boxes before)"
                                                                     if x["src"][f] == "carried" else "")
    return out


def sheet3_items(rows):
    out = []
    order = ["kind"] + FIELDS_FINAL
    for x in rows:
        ask = sorted(x["open"] + x["controls"], key=lambda d: order.index(d["field"]))
        if not ask and not x["turn_question"]:
            continue
        pool = FINAL if x["reread_final"] else REV
        fields = [{"field": "_turn", "label": LABELS["_turn"], "readings": [], "box": None, "placed": "turn",
                   "options": TURN_OPTIONS}] if x["turn_question"] else []
        fields += [{"field": d["field"], "label": LABELS[d["field"]] + (" (check again)" if d.get("recheck") else ""),
                    "readings": d["readings"], "box": d["box"], "placed": d["placed"]} for d in ask]
        out.append({"id": x["id"], "n": len(out) + 1,
                    "img": os.path.relpath(os.path.join(pool, "pages", x["id"] + ".jpg"), os.path.join(FINAL, "sheet")),
                    "colour": "box (Red)" if x["colour"] == "Red" else "folder (Purple)",
                    "agreed": shown_settled(x, {d["field"] for d in ask}), "fields": fields})
    return out


SHEET3_HEADER = """<b>Container labels, third round (short).</b> Your second-sheet answers and notes are in: Place is
gone; internal marks (text beside serial numbers, Archival Media, location notes, logos, barcodes, Acid Free) are left
out; cut-off and illegible titles are flagged rather than transcribed; the five "fill in" photos take their missing
fields from the boxes before them; four photos are out; the photos you turned were read again the right way up. What is
left: fields still open after that, values marked "check again" (one of your answers repeats another field word for
word, or a mark the new internal-mark rule would leave out), and a few fields settled by your rules, mixed in as a
check. The grey line lists everything else going into the truth, carried and flagged fields included; correct any of
it in the notes. "Turn photo" turns a photo with its boxes, and the turn is saved with your answers."""


def write_final_truth(rows, path):
    with open(path, "w", encoding="utf-8") as fh:
        for x in rows:
            n = len(x["fields"]) + len(set(x["unsure"]) | set(x["cut_off"]) | set(x["illegible"]))
            fh.write(json.dumps({
                "id": x["id"], "path": x["path"], "colour": x["colour"], "stratum": x["stratum"],
                "fields": x["fields"], "src": x["src"],
                "ruled": [f for f, s in x["src"].items() if s in OWNER_FINAL],
                "by_rule": [f for f, s in x["src"].items() if s == "rule"],
                "carried": x["carried"], "open": [d["field"] for d in x["open"]], "unsure": x["unsure"],
                "cut_off": x["cut_off"], "cut_text": x["cut_text"], "illegible": x["illegible"],
                "unanswered": x.get("unanswered", []),
                "illegible_photo": x["illegible_photo"], "unlabelled": x["unlabelled"], "drafters": x["drafters"],
                "notes": x["notes"], "notes2": x.get("notes2"), "notes3": x.get("notes3"),
                "prompt_example": prompt_examples_final(x), "reread_final": x["reread_final"],
                "turn_question": x["turn_question"], "turn3": x.get("turn3"),
                "complete": not x["open"] and n == len(FIELDS_FINAL) + 1}, ensure_ascii=False) + "\n")


def prompt_examples_final(x):
    ex = set(re.findall(r'"([^"]+)"', PROMPT_REV)) | set(re.findall(r'"([^"]+)"', PROMPT_FINAL)) | {"Box 5", "9", "Box 8", "5"}
    return [f for f, v in x["fields"].items() if v and f != "kind" and any(norm(f, v) == norm(f, e) for e in ex)]


def cmd_finish(a):
    """final/draft-truth.jsonl and final/truth.jsonl, the third sheet (only what stays open, with controls) and
    segbench-results/ct-truth-final.md."""
    rows, st = final_rows()
    pick_final_controls(rows)
    with open(os.path.join(FINAL, "draft-truth.jsonl"), "w", encoding="utf-8") as fh:
        for x in rows:
            fh.write(json.dumps(x, ensure_ascii=False) + "\n")
    write_final_truth(rows, os.path.join(FINAL, "truth.jsonl"))
    items = sheet3_items(rows)
    os.makedirs(os.path.join(FINAL, "sheet"), exist_ok=True)
    with open(os.path.join(FINAL, "sheet", "index.html"), "w", encoding="utf-8") as fh:
        fh.write(sheet_html(items, key="w47-ct-truth-final", header=SHEET3_HEADER, settled="Not asked, going in as",
                            dl="W47-ct-truth-final-answers.json"))
    write_final_results(rows, st, items)
    print(dict(st))
    print(f"{FINAL_RESULTS}; sheet {os.path.join(FINAL, 'sheet', 'index.html')}: {len(items)} photos, "
          f"{sum(len(i['fields']) for i in items)} questions")


def cmd_fold_final(a):
    """The third sheet's answers into final/truth.jsonl: an open field or control answered becomes the owner's
    (`sheet3`); "other" with nothing typed stays open; a typed answer whose button was not pressed is taken as typed;
    a turn the owner gave (button or question) is recorded as `turn3`, and a photo turned further has its reader
    fields reopened, to be reread."""
    rows = jsonl(os.path.join(FINAL, "draft-truth.jsonl"))
    answers = json.load(open(a.answers, encoding="utf-8"))
    c = collections.Counter()
    for x in rows:
        ans = answers.get(x["id"]) or {}
        t = (ans.get("_turn") or {}).get("pick")
        deg = further_of(t) if t in TURN_OPTIONS else None
        if deg is None and (ans.get("_rot") or {}).get("deg"):
            deg = (-int(ans["_rot"]["deg"])) % 360   # the button turns clockwise in CSS degrees
        if deg:
            x["turn3"] = deg
            c["photos turned further (reread)"] += 1
            for f in [f for f, s in x["src"].items() if s in ("readers", "rule", "carried")]:
                x["fields"].pop(f), x["src"].pop(f)
                x["open"].append({"field": f, "readings": [], "box": None, "placed": "none"})
        keep = []
        for d in x["open"] + x["controls"]:
            g = ans.get(d["field"]) or {}
            pick, text = g.get("pick"), clean(g.get("text"))
            if not pick and text:
                pick = "other"
            if not pick or (pick == "other" and not text):
                keep += [d] if d in x["open"] else []
                c["open, unanswered"] += d in x["open"]
                continue
            v = None if pick == "not on the label" else text if pick == "other" else pick
            if d in x["controls"]:
                c["controls answered"] += 1
                c["controls overturned"] += not agree("x" if d["field"] == "kind" else d["field"], v,
                                                      x["fields"].get(d["field"]))
            x["fields"][d["field"]], x["src"][d["field"]] = canon(d["field"], v), "sheet3"
            c["fields ruled"] += 1
        x["open"] = keep
        note = clean((ans.get(NOTES) or {}).get("text"))
        if note:
            x["notes3"] = note
            c["notes"] += 1
    with open(os.path.join(FINAL, "draft-truth.jsonl"), "w", encoding="utf-8") as fh:
        for x in rows:
            fh.write(json.dumps(x, ensure_ascii=False) + "\n")
    write_final_truth(rows, os.path.join(FINAL, "truth.jsonl"))
    print(dict(c))


def write_final_results(rows, st, items):
    import gateway_gemini as G
    srcs = collections.Counter(s for x in rows for s in x["src"].values())
    led = jsonl(os.path.join(FINAL, "gateway-calls.jsonl"))
    up = jsonl(os.path.join(FINAL, "upright-calls.jsonl")) + jsonl(os.path.join(FINAL, "check-calls.jsonl"))
    reread = [x for x in rows if x["reread_final"]]
    chk = collections.Counter(x["pick"] for x in jsonl(os.path.join(FINAL, "check.jsonl")))
    n_ctl = sum(len(x["controls"]) for x in rows)
    n_open = sum(len(x["open"]) for x in rows)
    n_turn = sum(bool(x["turn_question"]) for x in rows)
    spent = sum(G.charge(r) for r in led) + sum(G.charge(r) for r in up)
    L = ["# Container labels: the truth finished from the owner's second sheet (W47.ct-truth-final)", "",
         "Written by `scripts/segbench/ct_truth.py --final finish`. The owner answered the second sheet "
         "(`ct-truth-revised.md`) on 2026-11-05: 411 of its 417 questions, with notes on 32 photos. This build "
         "applies the notes' rules and rereads the photos that were read at the wrong turn. Label values stay in the "
         "cache: this page gives counts and photo ids only.", "",
         "## What each rule changed", "",
         "| rule | cells or photos |", "|---|---|",
         f"| photos taken out ({', '.join(sorted(set(DROPPED_FINAL.values())))}) | {len(DROPPED_FINAL)} |"]
    for k, v in sorted(st.items()):
        L.append(f"| {k} | {v} |")
    L += ["",
          f"{len(rows)} photos remain: {sum(x['colour'] == 'Red' for x in rows)} box (Red), "
          f"{sum(x['colour'] == 'Purple' for x in rows)} folder (Purple), {len(FIELDS_FINAL)} fields and the kind.", "",
          "- **Place** is not a field for boxes and folders (the owner's note); it is gone from the fields, the prompt "
          "and the truth, and W47.ct-read does not score it.",
          "- **Internal marks** are not identifying marks: text beside a serial number, \"Archival Media\", location "
          "and shelf-location notes, the archive's logos, barcodes and notes about the box itself. They are in the "
          "prompt the reread used; reader values have them left out; an owner value the rule would change is asked "
          "once more rather than dropped (on the third sheet, marked \"check again\").",
          "- **Cut off and illegible.** A cut-off title is flagged (`cut_off`) and its visible text kept apart "
          "(`cut_text`), not given as the value; a title that cannot be read is flagged `illegible`; the blurred "
          "photo has every field flagged `illegible` (`illegible_photo`), which is itself what the user needs to "
          "know, not an empty label. The folder with no label is `unlabelled`: its empty fields are true empties.",
          "- **Carried.** On the five photos the owner marked \"fill in per last few boxes\", a field he answered "
          f"\"other\" with nothing typed takes the most common owner value of the {CARRY_FROM} box photos before it on "
          "the sheet in its directory (a strict majority), with `src` `carried` and the photos it came from in "
          "`carried`. A carried cell is not a reading: W47.ct-read leaves carried cells out of every reading score "
          "and never uses them to score carry-forward.",
          "- **\"Other\" pressed with nothing typed** elsewhere is not \"not on the label\" (the second fold read it "
          "so); it is asked again. A value typed with no button pressed is taken as typed. The third sheet's fold "
          "does both, and its turn button records the turn in the answers.", "",
          "## The reread", "",
          f"{len(reread)} photos were read at the wrong turn: the {sum(1 for r in sample() if r.get('further_how') == 'sheet')} "
          "the owner turned on the second sheet, one his note gave the turn for, and one he said needs turning with no "
          "direction (Gemini 3.7 Flash picked among the three turns it had not been shown at). All three readers read "
          "them again at that turn with the final prompt. Gemini's upright pick among all four turns of each "
          f"rendered photo, as a check: {chk.get(0, 0)} of {sum(chk.values())} as they are, "
          f"{chk.get(180, 0)} upside down, {sum(chk.values()) - chk.get(0, 0) - chk.get(180, 0)} a quarter turn off. "
          "Every quarter-turn pick undoes the owner's own turn and none is a half turn, so the turn arithmetic is not "
          "reversed: Gemini disagrees with the owner on these photos, as its first pick did (the reason they were on "
          "the second sheet). The owner's turn stands. The photo turned by Gemini's pick alone is asked which way up "
          "on the third sheet.", "",
          "## Where each settled cell came from", "", "| source | cells |", "|---|---|"]
    for s, label in (("sheet", "the owner, first sheet"), ("note", "the owner's first-sheet notes"),
                     ("sheet2", "the owner, second sheet"), ("note2", "the owner's second-sheet notes"),
                     ("rule", "the owner's rules, applied to the readers' readings (reported apart; no owner check "
                              "but the third sheet's controls)"),
                     ("carried", "carried from the boxes before"), ("readers", "the three readers, unanimous")):
        L.append(f"| {label} | {srcs[s]} |")
    complete = sum(1 for x in rows if not x["open"] and len(x["fields"]) + len(set(x["unsure"]) | set(x["cut_off"])
                                                                                 | set(x["illegible"])) == len(FIELDS_FINAL) + 1)
    L += ["", f"Flagged: {sum(len(x['cut_off']) for x in rows)} cut off, {sum(len(x['illegible']) for x in rows)} "
          f"illegible, {sum(len(x['unsure']) for x in rows)} the owner could not read. Of the second sheet's 6 "
          f"unanswered cells, 4 were on photos now out, one was typed with its button not pressed (taken as typed) "
          f"and {sum(len(x.get('unanswered', [])) for x in rows)} stays out of the truth, unasked (`unanswered`). "
          f"{complete} of {len(rows)} photos are complete.", "",
          "## The third sheet", ""]
    if items:
        L += [f"{n_open} cells stay open, so a short third sheet asks {sum(len(i['fields']) for i in items)} questions on "
              f"{len(items)} photos: the {n_open} open cells, {n_ctl} rule-settled cells as controls (drawn at random "
              f"with a fixed seed, unmarked) and {n_turn} which-way-up question{'s' if n_turn != 1 else ''}. "
              f"{sum(len(x['open']) for x in rows if x['reread_final'] and not all(_parsed_final(x['id'])))} of the "
              "open cells are on the reread photo where one reader's reply did not parse (a repetition loop, which "
              "a rerun at temperature 0 repeats): two readers settle nothing, so those cells are asked with the two "
              "readings. It follows the sheet rule: a notes box "
              "per photo, every unasked truth listed with its value, the photos upright with a turn button that is "
              "saved. `pool-jpeg/final/sheet/index.html` in the cache (private); `ct_truth.py --final fold "
              "ANSWERS.json` folds it into `final/truth.jsonl`.", "",
              "| field | open |", "|---|---|"]
        for f in ["kind"] + FIELDS_FINAL:
            k = sum(d["field"] == f for x in rows for d in x["open"])
            if k:
                L.append(f"| {LABELS[f]} | {k} |")
    else:
        L += ["Nothing stays open; W47.ct-read scores against `final/truth.jsonl`."]
    L += ["", "## Cost", "",
          f"Gateway (Gemini 3.7 Flash, real money on the Stanford PTA): {len(up)} upright calls (the one pick and "
          f"the check) and {len(led)} reader "
          f"calls, ${spent:.3f} of this item's ${FINAL_CAP:.2f} cap. The two open models ran on this Mac, $0.", "",
          "## Measurement card", "",
          "- **Truth:** the owner's answers on two sheets and his notes, his rules applied to the readers' readings, "
          "values carried from the boxes before, and for the rest the three readers unanimous. `ruled` lists the "
          "owner's own cells; `by_rule` the rule-settled ones, reported apart, whose only check is the third sheet's "
          f"{n_ctl} controls; carried cells are marked and are no reader's reading. The drafters are scored only on "
          "`ruled` (FLD-9); `prompt_example` cells are left out of their scores.",
          "- **Selection:** the first build's stratified draw by repository, less the photos the owner took out (now "
          f"{len(DROPPED) + len(DROPPED_FINAL)}). The pairing cut's lean stands (54 photos left out, 43 Red, toward "
          "little-changed PDFs); W47.ct-read reports it beside every figure.",
          "- **Comparison:** the reread photos were read by the same three readers, at the right turn, with the final "
          "prompt (the second-sheet prompt less Place, plus the internal-mark rule); the other photos' reader cells "
          "are from the second-sheet prompt, whose difference the rules applied here cover.",
          "- **Noise:** one pass at temperature 0; no rerun floor.",
          "- **Scope:** a truth. Says nothing about which reader is right; that is W47.ct-read.", ""]
    with open(FINAL_RESULTS, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))


def pdf_comparison(rows):
    """The PDF build beside this one, on the markers both read: how often the PDF-built two-reader agreement held
    on the JPEGs, and how often Qwen3-VL 8B's own reading changed between the PDF and the JPEG."""
    p = os.path.join(PDF_POOL, "draft-truth.jsonl")
    if not os.path.exists(p):
        return None
    old = {r["id"]: r for r in (json.loads(l) for l in open(p, encoding="utf-8")) if all(r["parsed"])}
    both = [r for r in rows if all(r["parsed"]) and r["id"] in old]
    c = collections.Counter()
    for r in both:
        o = old[r["id"]]
        da = (draft_of(r["id"], FIRST) or {}).get("parsed") or {}
        oa = ((json.load(open(os.path.join(PDF_POOL, "draft", FIRST, r["id"] + ".json"), encoding="utf-8"))
               if os.path.exists(os.path.join(PDF_POOL, "draft", FIRST, r["id"] + ".json")) else {})
              .get("parsed") or {})
        for f in ["kind"] + FIELDS:
            c["fields"] += 1
            c["8b same"] += agree("x" if f == "kind" else f, da.get(f), oa.get(f))
            if f in o["agreed"]:
                c["pdf agreed"] += 1
                if f in r["agreed"]:
                    c["pdf agreed, jpeg unanimous"] += 1
                    c["pdf agreed, jpeg same value"] += agree("x" if f == "kind" else f, r["agreed"][f], o["agreed"][f])
    return len(both), c


def write_results(rows):
    drafted = [r for r in rows if all(r["parsed"])]
    unparsed = [r for r in rows if not all(r["parsed"])]
    by_class = {c: [r for r in drafted if r["colour"] == c] for c in ("Red", "Purple")}
    lines_n = sum(1 for r in rows if lines_of(r["id"]))
    st = json.load(open(SAMPLING, encoding="utf-8")) if os.path.exists(SAMPLING) else {"classes": {}}
    names = ", ".join(NAMES[k] for k in READERS)
    L = ["# Container labels: the truth set's three-reader draft, on the JPEG originals (W47.ct-truth-jpeg)", "",
         f"Written by `scripts/segbench/ct_truth.py compare`. {len(rows)} marker photos (Red for a box, Purple for a "
         f"folder), each the JPEG original of a corpus PDF, upright, at {MAX_SIDE} px. Read blind into the nine "
         f"fields of `execution-plans/containers/00-plan.md` plus what the photo is, by {names}; temperature 0, "
         f"the same image and prompt for each. A field is agreed when all three readings match after case, "
         f"punctuation and \"Box No.\" spellings are normalised; all empty counts as agreed. Agreement is not truth: "
         f"three readers can make the same miss, which is what the sheet's controls measure.", "",
         "The first build read the corpus PDFs; it stays beside this one (`ct-truth-pdf.md`, and `pool/` in the "
         "cache) and is compared below.", "",
         "## The sample: the PDF build's 240, on their JPEG originals", "",
         f"Each of the PDF build's 240 markers was paired through `corpus_pairs.py`'s pairs.tsv and confirmed by "
         f"`ocr_truth.orient_like_pdf` (grey thumbnails at four turns, correlation at least {MIN_CORR}), whose best "
         f"turn makes the JPEG upright like the PDF. A marker left out was refilled from its stratum and colour "
         f"(a fresh draw, seed {SEED}, over the corpus's current markers, each confirmed the same way). The corpus "
         f"now holds {st.get('markers_now', '?')} single-colour markers; some of the 240 have moved since.", "",
         "| | box (Red) | folder (Purple) |", "|---|---|---|"]
    cl = st["classes"]
    reasons = sorted({k for c in cl.values() for k in c["left_out"]})
    get = lambda c, k: cl.get(c, {}).get(k, 0)
    L.append(f"| in the PDF build | {get('Red', 'pdf_sample')} | {get('Purple', 'pdf_sample')} |")
    for k in reasons:
        L.append(f"| left out: {k} | {cl.get('Red', {}).get('left_out', {}).get(k, 0)} | "
                 f"{cl.get('Purple', {}).get('left_out', {}).get(k, 0)} |")
    L.append(f"| refilled from the stratum | {get('Red', 'refilled')} | {get('Purple', 'refilled')} |")
    L.append(f"| short (a stratum with no confirmed marker left) | "
             f"{sum(cl.get('Red', {}).get('short', {}).values())} | {sum(cl.get('Purple', {}).get('short', {}).values())} |")
    L.append(f"| in this build | {get('Red', 'sampled')} | {get('Purple', 'sampled')} |")
    turns = collections.Counter(r.get("turn", 0) for r in rows)
    corr = sorted(r["corr"] for r in rows if r.get("corr") is not None)
    rej = sorted(v for c in cl.values() for v in c.get("rejected_corr", []))
    L += ["", f"Turned to match the PDF: {sum(v for k, v in turns.items() if k)} of {len(rows)} "
          f"({', '.join(f'{v} by {k}°' for k, v in sorted(turns.items()) if k)}). Correlation of the kept pairs "
          f"{corr[0]:.2f}–{corr[-1]:.2f}, median {corr[len(corr) // 2]:.2f}." if corr else "",
          "",
          f"**The cut is conservative on label photos.** The {len(rej)} pairs under the cut ran "
          f"{rej[0] if rej else '–'} to {rej[-1] if rej else '–'} in an unbroken spread, not the two clusters "
          f"the cut was set on (true document pages 0.69–0.98, mismatches 0.16–0.48). An eye check of eight Red "
          f"rejects spread across that range (−0.03 to 0.645) found all eight the same photo as their PDF: the PDF "
          f"had been cropped, deskewed or straightened (one PDF is upside down), which lowers a whole-image "
          f"correlation. So most of the \"not the same photo\" left-outs are true pairs, and the refills lean "
          f"toward markers whose PDF was little changed. The cut was kept, as the item asks; a label-photo "
          f"confirmation that tolerates cropping (text overlap, feature matching) would recover them.", "",
          "## Strata in the sample", "",
          "A stratum is the repository's directory, except under a workflow folder, where the level below it is a "
          "priority folder or Re-OCR and the corpus has no repository level (marked *workflow*).", "",
          "| stratum | box (Red) | folder (Purple) | of them refilled |", "|---|---|---|---|"]
    reps = collections.Counter((r["repository"], r["colour"]) for r in rows)
    refills = collections.Counter(r["repository"] for r in rows if r.get("refill"))
    wf = {r["repository"] for r in rows if r.get("workflow")}
    for rep in sorted({r["repository"] for r in rows}):
        L.append(f"| {rep}{' (*workflow*)' if rep in wf else ''} | {reps[(rep, 'Red')]} | {reps[(rep, 'Purple')]} "
                 f"| {refills[rep]} |")
    L += ["", f"Drafted by all three: {len(drafted)}; a reply that did not parse: {len(unparsed)}. Apple Vision "
          f"lines for the sheet's boxes: {lines_n} photos.", "",
          "## Agreement per field", "",
          "Not unanimous / unanimous with a value / unanimous empty, out of the photos all three drafted; then which "
          "reader was the odd one out where the other two agreed.", "",
          "| field | box: split | box: agreed, a value | box: agreed, empty | folder: split | folder: agreed, a value "
          "| folder: agreed, empty | odd one out: " + " / ".join(NAMES[k].split(",")[0].split(" (")[0] for k in READERS)
          + " / no two agree |", "|---|---|---|---|---|---|---|---|"]
    for f in ["kind"] + FIELDS:
        cells = []
        for c in ("Red", "Purple"):
            rs = by_class[c]
            cells += [str(sum(any(d["field"] == f for d in r["disputed"]) for r in rs)),
                      str(sum(f in r["agreed"] and r["agreed"][f] is not None for r in rs)),
                      str(sum(f in r["agreed"] and r["agreed"][f] is None for r in rs))]
        odd = collections.Counter((r.get("odd") or {}).get(f, "none") for r in drafted if f in (r.get("odd") or {}))
        cells.append(" / ".join(str(odd[k]) for k in READERS) + f" / {odd['none'] + odd[None]}")
        L.append(f"| {LABELS[f]} | " + " | ".join(cells) + " |")
    kinds = collections.Counter((r["colour"], r["agreed"].get("kind", "disputed")) for r in drafted)
    L += ["", "## What the photos are, where all three agree", "", "| reading | box (Red) | folder (Purple) |",
          "|---|---|---|"]
    for k in KINDS + [None, "disputed"]:
        L.append(f"| {k or 'no answer'} | {kinds[('Red', k)]} | {kinds[('Purple', k)]} |")
    sheet = [r for r in drafted if asked(r)]
    ctl = [d for r in drafted for d in r.get("controls", [])]
    placed = collections.Counter(d["placed"] for r in sheet for d in asked(r) if d["field"] != "kind")
    L += ["", "## The owner's sheet", "",
          f"{sum(1 for r in drafted if r['disputed'])} photos carry at least one split field, "
          f"{sum(len(r['disputed']) for r in drafted)} split fields in all; "
          f"{sum(1 for r in drafted if not r['disputed'])} photos are unanimous on every field. The sheet adds "
          f"{len(ctl)} unanimous fields as unmarked controls ({sum(1 for d in ctl if d['readings'])} with a value, "
          f"{sum(1 for d in ctl if not d['readings'])} agreed empty), so it asks {sum(len(asked(r)) for r in sheet)} "
          f"fields on {len(sheet)} photos. Boxes (fields other than what the photo is): {placed['lines']} from the "
          f"Vision lines matching a reading, {placed['label']} from a reader's label region, {placed['none']} with "
          f"no box (the sheet says so). The sheet is `pool-jpeg/sheet/index.html` in the cache (private: corpus "
          f"images); its answers fold into `pool-jpeg/truth.jsonl` with `ct_truth.py fold`, which records the "
          f"fields the owner ruled and how many controls the owner overturned.", ""]
    cmp_ = pdf_comparison(rows)
    if cmp_:
        n, c = cmp_
        L += ["## Beside the PDF build", "",
              f"On the {n} markers both builds read: Qwen3-VL 8B gave the same reading from the JPEG as from the PDF "
              f"on {c['8b same']} of {c['fields']} fields ({100 * c['8b same'] / max(1, c['fields']):.0f}%). Of the "
              f"{c['pdf agreed']} fields the two Qwen readers agreed on from the PDFs, {c['pdf agreed, jpeg unanimous']} "
              f"are unanimous among the three readers on the JPEGs, {c['pdf agreed, jpeg same value']} with the same "
              f"value; the rest now go to the owner.", ""]
    led = gateway_ledger()
    walls = {k: [r["wall_s"][i] for r in rows if r.get("wall_s") and r["wall_s"][i]] for i, k in enumerate(READERS)}
    import gateway_gemini as G
    L += ["## The drafters W47.ct-read may not score", "",
          f"{names} drafted this truth. W47.ct-read scores any of them only on the fields the owner ruled (the fold's "
          f"`ruled`: the split fields and the controls answered); on the rest a figure is agreement with the "
          f"drafters, and is reported as that (measurement audit FLD-9).", "",
          "## Cost", "",
          " ".join(f"{NAMES[k]}: {len(w)} photos, {sum(w) / len(w):.1f} s a photo on average, "
                   f"{sum(w) / 60:.0f} min in all." for k, w in walls.items() if w and k != GATEWAY) + " $0.", "",
          f"{NAMES[GATEWAY]}: {len(led)} calls, ${sum(G.charge(r) for r in led):.2f} real money on the Stanford "
          f"gateway ({G.billed_note(led)}), against the owner's approval of about $0.70.", "",
          "## Measurement card", "",
          "- **Truth:** none yet. This is a draft for the owner's sheet: unanimous fields go in unchecked except the "
          f"{CONTROLS} controls, split fields wait for the owner's ruling. The three drafters are named above.",
          "- **Selection:** the PDF build's stratified draw by repository from the Finder tags (no tested route, no "
          "ABBYY text), less the markers with no confirmed JPEG; refills come from the same strata. The cut's "
          "losses are not random (see the sample), and they fall mostly on Red.",
          "- **Comparison:** the same JPEG, prompt and settings for all three readers.",
          "- **Noise:** a single pass at temperature 0; no rerun floor. The counts above describe this sample, not "
          "the corpus.",
          "- **Scope:** reports agreement only; says nothing about which reader is right until the sheet is "
          "answered and W47.ct-read scores it.", ""]
    with open(RESULTS, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>W47 container labels: disagreements</title>
<style>body{font:15px -apple-system,sans-serif;margin:0}header{position:sticky;top:0;background:#fff;padding:8px 16px;
border-bottom:1px solid #ccc;z-index:9}.doc{border-bottom:2px solid #888;padding:12px 16px;display:flex;gap:18px}
.turn{font-size:12px;margin:0 0 4px}.frame{position:relative;display:inline-block;flex:none}.frame img{max-height:82vh;max-width:52vw;display:block}
.box{position:absolute;border:3px solid #f0a;border-radius:4px;pointer-events:none}
.tag{position:absolute;background:#f0a;color:#fff;font:bold 12px sans-serif;padding:0 4px;transform:translateY(-100%)}
.q{margin:8px 0 14px}.q label{display:block;margin-left:12px}.agreed{color:#555;font-size:13px}.nobox{color:#a05;font-size:13px}
.notes textarea{width:100%;max-width:560px;height:4.5em;font:14px -apple-system,sans-serif}
</style>
<header>__HEADER__
Answers save in this browser; <button id="dl">download answers</button>
<span id="prog"></span></header>
<div id="root"></div>
<script>
const DATA=__DATA__;const KINDS=__KINDS__;const LABELS=__LABELS__;const NOTES=__NOTES__;const SETTLED=__SETTLED__;const KEY=__KEY__;const ans=JSON.parse(localStorage.getItem(KEY)||'{}'); // gitleaks:allow (a storage key name, not a secret)
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const total=DATA.reduce((n,d)=>n+d.fields.length,0);
function prog(){let n=0;for(const d of DATA)for(const f of d.fields)if(ans[d.id]?.[f.field]?.pick)n++;
 document.getElementById('prog').textContent=n+' of '+total+' fields answered'}
let h='';DATA.forEach(d=>{h+=`<div class="doc"><div><button class="turn" data-t="${esc(d.id)}">turn photo ↻</button><br><div class="frame" data-f="${esc(d.id)}"><img src="${esc(d.img)}">`;
 d.fields.forEach((f,i)=>{if(f.box&&f.field!=='kind'&&!f.options)h+=`<div class="box" style="left:${100*f.box[0]}%;top:${100*f.box[1]}%;width:${100*f.box[2]}%;height:${100*f.box[3]}%"></div><div class="tag" style="left:${100*f.box[0]}%;top:${100*f.box[1]}%">${i+1}</div>`});
 h+=`</div></div><div><b>${d.n}. Photo ${d.id}</b>, tagged ${esc(d.colour)}`;
 const ag=Object.entries(d.agreed);h+=`<div class="agreed">${esc(SETTLED)}: ${ag.length?ag.map(([k,v])=>esc(LABELS[k]||k)+' = '+esc(v)).join('; '):'nothing beyond the fields below'}</div>`;
 d.fields.forEach((f,i)=>{const nm=d.id+'/'+f.field;const cur=ans[d.id]?.[f.field]||{};
  h+=`<div class="q"><b>${i+1}. ${esc(f.label)}</b>`;
  if(f.field!=='kind'&&f.placed==='none')h+=` <span class="nobox">(no box: no reading was found on the photo; look over the whole label)</span>`;
  const opts=f.options?f.options:f.field==='kind'?KINDS:[...f.readings.filter(r=>r!==null),'other','not on the label'];
  for(const o of opts)h+=`<label><input type="radio" name="${esc(nm)}" value="${esc(o)}" ${cur.pick===o?'checked':''}> ${o==='other'?'other:':esc(o)}${o==='other'?` <input data-t="${esc(nm)}" value="${esc(cur.text)}" size="40">`:''}</label>`;
  h+='</div>'});
  h+=`<div class="q notes"><b>Notes on this photo</b> (optional)<br><textarea data-n="${esc(d.id)}">${esc(ans[d.id]?.[NOTES]?.text)}</textarea></div>`;
  h+='</div></div>'});
document.getElementById('root').innerHTML=h;
const set=(nm,k,v)=>{const [id,f]=nm.split('/');ans[id]=ans[id]||{};ans[id][f]={...(ans[id][f]||{}),[k]:v};localStorage.setItem(KEY,JSON.stringify(ans));prog()};
// the turn is saved with the answers as _rot.deg (clockwise, as shown), and restored on reload
const turnTo=(f,d)=>{f.dataset.deg=d;f.style.transform=d?`rotate(${d}deg)`:'';
 const side=d%180?(f.offsetWidth-f.offsetHeight)/2:0;f.style.margin=side?`${Math.max(side,0)}px ${Math.max(-side,0)}px`:''};
document.querySelectorAll('button.turn').forEach(b=>{const f=document.querySelector(`.frame[data-f="${b.dataset.t}"]`);
 const saved=+(ans[b.dataset.t]?._rot?.deg||0);if(saved)f.querySelector('img').addEventListener('load',()=>turnTo(f,saved),{once:true});
 b.onclick=()=>{const d=((+f.dataset.deg||0)+90)%360;turnTo(f,d);set(b.dataset.t+'/_rot','deg',d)}});
document.querySelectorAll('input[type=radio]').forEach(e=>e.onchange=()=>set(e.name,'pick',e.value));
// typing under "other" presses "other": a typed answer with no button pressed was lost on the second sheet
document.querySelectorAll('input[data-t]').forEach(e=>e.oninput=()=>{set(e.dataset.t,'text',e.value);
 const r=[...document.getElementsByName(e.dataset.t)].find(x=>x.value==='other');if(r&&e.value.trim()&&!r.checked){r.checked=true;set(e.dataset.t,'pick','other')}});
document.querySelectorAll('[data-n]').forEach(e=>e.oninput=()=>set(e.dataset.n+'/'+NOTES,'text',e.value));prog();
document.getElementById('dl').onclick=()=>{const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify(ans,null,1)],{type:'application/json'}));a.download=__DLNAME__;a.click()};
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
    ap.add_argument("--rev", action="store_true", help="the revision: rev2/, the revised fields and prompt")
    ap.add_argument("--final", action="store_true", help="the final truth: final/, the reread and the third sheet")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sample").set_defaults(fn=cmd_sample)
    u = sub.add_parser("upright")
    u.add_argument("--limit", type=int)
    u.set_defaults(fn=cmd_upright)
    for name, fn in (("render", cmd_render), ("lines", cmd_lines), ("compare", cmd_compare), ("revise", cmd_revise),
                     ("sheet", cmd_sheet), ("trees", cmd_trees), ("finish", cmd_finish), ("check", cmd_check_final),
                     ("owner-tree", cmd_owner_tree)):
        sub.add_parser(name).set_defaults(fn=fn)
    g = sub.add_parser("gateway")
    g.add_argument("--limit", type=int)
    g.set_defaults(fn=cmd_gateway)
    c = sub.add_parser("collect")
    c.add_argument("--limit", type=int)
    c.add_argument("--model", choices=sorted(MODELS), default=FIRST)
    c.set_defaults(fn=cmd_collect)
    f = sub.add_parser("fold")
    f.add_argument("answers")
    f.set_defaults(fn=cmd_fold)
    a = ap.parse_args()
    if a.rev:
        use_revision()
    if a.final:
        use_final()
        a.fn = {cmd_upright: cmd_upright_final, cmd_fold: cmd_fold_final}.get(a.fn, a.fn)
    elif a.fn in (cmd_finish, cmd_check_final):
        ap.error(f"{a.cmd} needs --final")
    a.fn(a)


if __name__ == "__main__":
    main()
