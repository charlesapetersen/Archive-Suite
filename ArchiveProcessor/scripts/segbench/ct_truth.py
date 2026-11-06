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
            return f"{kind} {m.group(2).lower()}"
        bare = re.fullmatch(r"\s*(?:no\.?|#)?\s*(\d+[a-z]?)\s*", s)
        if bare:  # a bare number is read as a box, the usual container
            return f"box {bare.group(1)}"
    if field == "folder":
        s = re.sub(r"\b(folder|fol|fld|fd|f)\b\.?\s*(no\.?|#)?", "", s)
    if field == "series" and "series_title" in FIELDS:   # the revision: "Series III" and "III" are one series
        s = re.sub(r"^\s*series\b\.?\s*", "", s)
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
    browser stay (same storage key)."""
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
        return f"{kind.capitalize()} {m.group(2).upper() if m.group(2)[-1:].isalpha() else m.group(2)}"
    bare = re.fullmatch(r"\s*(?:no\.?|#)?\s*(\d+[a-z]?)\s*", v, re.I)
    return f"Box {bare.group(1)}" if bare else v


def jsonl(path):
    return [json.loads(l) for l in open(path, encoding="utf-8")] if os.path.exists(path) else []


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
        if fields.get("kind") == "box label" and src.get("folder_title") != "note":
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
line lists what is already settled (your answers, your notes, or all three readers)."""


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


def write_rev_truth(rows):
    with open(os.path.join(REV, "truth.jsonl"), "w", encoding="utf-8") as fh:
        for x in rows:
            ruled = [f for f, s in x["src"].items() if s in OWNER]
            fh.write(json.dumps({"id": x["id"], "path": x["path"], "colour": x["colour"], "stratum": x["stratum"],
                                 "fields": x["fields"], "src": x["src"], "ruled": ruled,
                                 "open": [d["field"] for d in x["open"]], "unsure": x["unsure"],
                                 "cut_off": x["cut_off"], "drafters": x["drafters"], "notes": x["notes"],
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
                     ("rule", "the owner's rules (no folder title on a box label)"),
                     ("readers", "the three readers, unanimous on the revised prompt")):
        L.append(f"| {label} | {srcs[s]} |")
    L += ["", f"Fields left out of scoring because the owner could not read them: "
          f"{sum(len(x['unsure']) for x in rows)}. Titles the owner marked cut off: "
          f"{sum(len(x['cut_off']) for x in rows)}."]
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
          "back to him on the second sheet to check.",
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
.frame{position:relative;display:inline-block;flex:none}.frame img{max-height:82vh;max-width:52vw;display:block}
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
let h='';DATA.forEach(d=>{h+=`<div class="doc"><div class="frame"><img src="${esc(d.img)}">`;
 d.fields.forEach((f,i)=>{if(f.box&&f.field!=='kind'&&!f.options)h+=`<div class="box" style="left:${100*f.box[0]}%;top:${100*f.box[1]}%;width:${100*f.box[2]}%;height:${100*f.box[3]}%"></div><div class="tag" style="left:${100*f.box[0]}%;top:${100*f.box[1]}%">${i+1}</div>`});
 h+=`</div><div><b>${d.n}. Photo ${d.id}</b>, tagged ${esc(d.colour)}`;
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
document.querySelectorAll('input[type=radio]').forEach(e=>e.onchange=()=>set(e.name,'pick',e.value));
document.querySelectorAll('[data-t]').forEach(e=>e.oninput=()=>set(e.dataset.t,'text',e.value));
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
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sample").set_defaults(fn=cmd_sample)
    u = sub.add_parser("upright")
    u.add_argument("--limit", type=int)
    u.set_defaults(fn=cmd_upright)
    for name, fn in (("render", cmd_render), ("lines", cmd_lines), ("compare", cmd_compare), ("revise", cmd_revise), ("sheet", cmd_sheet), ("trees", cmd_trees),
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
    a.fn(a)


if __name__ == "__main__":
    main()
