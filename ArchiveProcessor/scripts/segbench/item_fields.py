#!/usr/bin/env python3
"""W47.item-fields-truth: item fields (title, byline, publication, publication date, type, recipient place) — a truth
set, and how well the app's tagging call and JSON sidecar fill them now.

    python3 item_fields.py select        # W46.fix-ent-truth's 159 documents + ~60 articles and reports from the 300
    python3 item_fields.py render        # each document's first page as JPEG into the cache (sips, read-only)
    run-guarded.sh --label item-fields --need-gb 9 -- <lab venv>/bin/python item_fields.py collect --model K
    run-guarded.sh … -- <lab venv>/bin/python item_fields.py adjudicate      # the third model rules disputes
    run-guarded.sh … -- <lab venv>/bin/python item_fields.py extract         # the cheap open extractor
    python3 item_fields.py build         # CACHE/truth.jsonl (private), segbench-results/item-fields.md/.json

<lab venv> is ~/.local/share/visionocr-ocrlab/venv (mlx_vlm 0.7.4); run-guarded.sh is vision-ocr's
ops/ocrlab/run-guarded.sh, which takes the Mac-wide heavy lock and one model process at a time.

The set extends W46.fix-ent-truth's instead of building a second one (owner, 2026-10-21): its 159 drafted documents
(138 correspondence, 21 not) plus about 60 newspaper articles, magazine articles and reports drawn from the W41
date-tagging sample of 300, by the cached Gemini 3.8 tagging reply's `format`, a third from each group, round-robin
over the collections with a fixed seed. The 300's documents carry four models' cached tagging replies (Gemini 3.8
Flash, the app's cloud route; Qwen3.6 27B, Qwen3-VL 8B and Qwen3.5 4B, the local routes), which is what is scored:
the app's TagGenerator prompt and parse, whose fields are also exactly what SegmentJSONBuilder writes into the JSON
sidecar (`format`, `author_name`, `recipient_location`, `publication_name`, the date), so one score covers both.
W46.fix-ent-truth's 72 additions have no cached replies and enter the truth only; no fresh paid tagging run is made
(paid hosted benchmarking is on hold, owner 2026-10-17; execution-plans/paid-runs-deferred.md).

Labels on every document: kind (KINDS, mapped to a Zotero item type by ZOTERO), title (the stated title or
headline; a memo's subject line; none for a letter or telegram, since Zotero composes one), byline (credited
authors of a published piece or report; none for correspondence, whose sender W46 already measures), publication
(the periodical's name as printed or noted on the clipping), publication date (the issue date as printed) and
recipient place (the addressee's place from the inside address, a To: line or an envelope).

Drafting and adjudication (STATE Phase 2 decision 2, model-drafted and model-audited, no owner pass), all on this
Mac, open weights, temperature 0, $0 and no plan route (root CLAUDE.md). Two families read every document blind from
the OCR text's first TEXT_CAP characters and the first page's image: Alibaba's Qwen3-VL 8B (A) and Google's Gemma 3
12B (B). Gemma 3 12B, shown both readings with the text and the image, rules every document whose readings differ on
any field, and the report counts how often it sided with each. A document whose readings agree takes A's. Before
agreement, the label definitions are applied to every reading and ruling (by_definition: no byline, publication or
publication date on a letter, memo or telegram, no title on a letter or telegram), since Gemma gave most letters
their own date as a publication date. Two leanings the report states: Qwen3-VL 8B is also a scored local route (from
text alone, through the app's prompt), and Gemma is a relative of Gemini, the scored cloud route, and judges. A
third family was not fetched: the Mac had 19 GB of disk free and a second 12B model would have left about 4 GB.

The scorer, per field and predictor, over the documents with cached replies: fill rate, exact and edit-distance-2
match (ent_truth's name matcher for names and places; folded text for titles and publications), wrong-when-filled
(filled and no match, including filled where the truth is empty) beside null-when-truth, and precision and recall
at ed2. The bar for filling a field is BAR precision at ed2 on at least MIN_N truth-filled documents; a field under
it stays empty (W47.item-fields-build). The cheap open extractor is Qwen3.5 4B, text only, with this item's prompt,
on every document. Texts, images, readings and the truth stay in the bench cache; the report has aggregates only.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import random
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ent_truth as ET  # noqa: E402

CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/item-fields")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "item-fields.md")
SEED = 4747
ARTICLE_GROUPS = {"newspaper": ("newspaper article", "newspaper clipping", "article", "newsletter article"),
                  "magazine": ("magazine article",), "report": ("report",)}
PER_GROUP = 20
MAX_SIDE = 896
TEXT_CAP = 3000            # the app's tagging prompt carries 3,000 characters too
MAX_TOKENS = 400
BAR, MIN_N = 0.90, 20

MODELS = {"gemma3-12b": ("mlx-community/gemma-3-12b-it-4bit", "Gemma 3 12B, 4-bit MLX"),
          "qwen3-vl-8b": ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "Qwen3-VL 8B, 4-bit MLX"),
          "qwen3.5-4b": ("lmstudio-community/Qwen3.5-4B-MLX-4bit", "Qwen3.5 4B, 4-bit MLX")}
READERS = ("qwen3-vl-8b", "gemma3-12b")
JUDGE = "gemma3-12b"
EXTRACTOR = "qwen3.5-4b"
# The app's cached tagging replies (date_tagging.answer_path labels; None is Gemini 3.8 Flash).
# The Qwen3.5 and 3.6 replies with thinking left on ran out of tokens mid-thought on every document here, so the
# thinking-off replies stand for them, as in ent_score.REPLIES.
APP = {"gemini-3.8-flash": None, "qwen3.6-27b": "qwen3.6-27b-nothink", "qwen3-vl-8b": "qwen3-vl-8b",
       "qwen3.5-4b": "qwen3.5-4b-nothink"}

KINDS = ("letter", "memo", "telegram", "newspaper article", "magazine article", "journal article", "newsletter",
         "clipping", "report", "speech", "press release", "photograph", "other")
ZOTERO = {"letter": "letter", "telegram": "letter", "memo": "document", "newspaper article": "newspaperArticle",
          "clipping": "newspaperArticle", "magazine article": "magazineArticle", "newsletter": "magazineArticle",
          "journal article": "journalArticle", "report": "report", "speech": "document",
          "press release": "document", "photograph": "artwork", "other": "document"}
FIELDS = ("kind", "title", "byline", "publication", "publication_date", "recipient_place")
LISTS = ("byline", "recipient_place")

PROMPT = """You are labelling catalogue fields for a test set built from a historical archive. You get the OCR text \
of the start of one document (it may be noisy) and an image of its first page. Read the image as well as the text.

Reply with JSON only, in this form:
{"kind": one of "letter", "memo", "telegram", "newspaper article", "magazine article", "journal article", \
"newsletter", "clipping", "report", "speech", "press release", "photograph", "other",
 "title": "..." or null,
 "byline": ["...", ...],
 "publication": "..." or null,
 "publication_date": "YYYY-MM-DD" or "YYYY-MM" or "YYYY" or null,
 "recipient_place": ["...", ...]}

Definitions.
- kind: what the document is. "clipping" is a printed cutting whose kind of periodical cannot be told.
- title: the title or headline the document itself states, OCR errors corrected (a memo's subject line counts; a \
report's title page). null for a letter, telegram or note, and when no title is printed. A letterhead (the \
sender's organisation printed at the top) is not a title.
- byline: the people credited as authors of a published piece or a report ("By ...", an author line), as "Given \
Surname" without titles. [] for correspondence (its sender is not a byline) and when none is printed.
- publication: the newspaper, magazine, journal or newsletter the piece was printed in, as named in its masthead, \
running head, or a note written on the clipping. null when not stated, or when the document was not printed in one \
(a letterhead is not a publication).
- publication_date: the issue date printed with the piece (masthead, running head, or a note on the clipping). \
null when not stated, and always null for a letter, memo or telegram (its own date is not a publication date).
- recipient_place: where the addressee is, from the inside address, a "To:" line or an envelope, as "City, State" \
for the United States or "City, Country" elsewhere. [] when not written or not correspondence.
- Do not guess from general knowledge.

OCR text:
---
{text}
---"""

TEXT_ONLY = PROMPT.replace(" and an image of its first page. Read the image as well as the text.", ".")

JUDGE_PROMPT = """Two readers labelled the same document independently, following the instructions below, and \
disagreed on: {fields}. Rule on every field: take reader A's value, reader B's, or your own where both are wrong. \
Check against the image and the text. Reply with the same JSON form and one more key, "basis": a short phrase \
saying what decided the disputed fields.

Reader A:
{a}

Reader B:
{b}

The instructions both readers had:
"""


# --- normalising and matching ------------------------------------------------------------------------------------

def clean(v):
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        v = str(int(v))
    if not isinstance(v, str):
        return None
    v = re.sub(r"\s+", " ", v).strip().strip('"')
    return None if v.lower() in ("", "null", "none", "n/a", "unknown", "not stated", "-") else v


def names(v):
    return [e["name"] for e in ET.ent_names(v)]


DATE = re.compile(r"^(\d{4})(?:-(\d{1,2}))?(?:-(\d{1,2}))?$")


def date_of(v):
    """(year, month, day) with Nones, or None."""
    v = clean(v)
    m = DATE.match(v) if v else None
    if not m:
        return None
    y, mo, d = (int(x) if x else None for x in m.groups())
    if mo is not None and not 1 <= mo <= 12:
        mo = d = None
    if d is not None and not 1 <= d <= 31:
        d = None
    return (y, mo, d)


def parse(raw):
    """A reading: every field normalised (kind in KINDS or None; lists of names; a date tuple), or None."""
    js = ET.parse_json(re.sub(r"<think>.*?</think>", "", raw or "", flags=re.S))
    if js is None:
        return None
    k = clean(js.get("kind"))
    k = k.lower() if k else None
    return {"kind": k if k in KINDS else ("other" if k else None), "title": clean(js.get("title")),
            "byline": names(js.get("byline")), "publication": clean(js.get("publication")),
            "publication_date": date_of(js.get("publication_date")),
            "recipient_place": names(js.get("recipient_place")), "basis": clean(js.get("basis"))}


def text_key(s):
    t = re.sub(r"[^a-z0-9 ]", " ", ET.fold(s or ""))
    t = re.sub(r"\b(the|a|an)\b", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def text_match(pred, truth, level):
    p, t = text_key(pred), text_key(truth)
    if not p or not t:
        return False
    if level == "exact":
        return p == t
    return ET.lev(p, t) <= 2


def list_match(pred, truth, level):
    """A list field is right on a document when some predicted name matches some truth name."""
    lvl = "exact" if level == "exact" else "ed2"
    return any(ET.match(p, t, lvl) for p in pred for t in truth)


def date_match(pred, truth, level):
    """At the truth's precision: exact needs every part the truth gives; ed2 (the loose level) the year and month."""
    if not pred or not truth:
        return False
    n = sum(x is not None for x in truth) if level == "exact" else min(2, sum(x is not None for x in truth))
    return all(pred[i] == truth[i] for i in range(n))


def kind_match(pred, truth, level):
    """exact: the fine kind; ed2 (the loose level): the same Zotero item type."""
    if not pred or not truth:
        return False
    return pred == truth if level == "exact" else ZOTERO.get(pred) == ZOTERO.get(truth)


def field_match(field, pred, truth, level):
    if field in LISTS:
        return list_match(pred, truth, level)
    if field == "publication_date":
        return date_match(pred, truth, level)
    if field == "kind":
        return kind_match(pred, truth, level)
    return text_match(pred, truth, level)


def filled(field, v):
    return bool(v) if field in LISTS else v is not None


def agree(field, a, b):
    if not filled(field, a) and not filled(field, b):
        return True
    if not filled(field, a) or not filled(field, b):
        return False
    if field in LISTS:
        return list_match(a, b, "ed2") and list_match(b, a, "ed2") and len(a) == len(b)
    if field == "publication_date":
        return a == b
    if field == "kind":
        return a == b
    return text_match(a, b, "ed2")


def disputes(a, b):
    return [f for f in FIELDS if not agree(f, a.get(f), b.get(f))]


# --- the app's replies ----------------------------------------------------------------------------------------

def app_kind(fmt):
    f = (fmt or "").strip().lower()
    if not f:
        return None
    table = [("telegram", "telegram"), ("memo", "memo"), ("newsletter", "newsletter"), ("letter", "letter"),
             ("newspaper", "newspaper article"), ("magazine", "magazine article"), ("journal", "journal article"),
             ("clipping", "clipping"), ("report", "report"), ("speech", "speech"), ("press release", "press release"),
             ("photo", "photograph"), ("article", "clipping")]
    for cue, k in table:
        if cue in f:
            return k
    return "other"


def app_reading(prompt, label):
    """What the app keeps of a cached tagging reply, in this item's fields; None when there is no reply."""
    import date_tagging as DT
    p = DT.answer_path(prompt, label)
    if not os.path.exists(p):
        return None
    try:
        with open(p, encoding="utf-8") as fh:
            raw = "".join(x.get("text", "") for x in json.load(fh)["candidates"][0]["content"]["parts"])
    except (KeyError, IndexError, TypeError):
        raw = ""
    js = ET.parse_json(DT.strip_reasoning(raw)) or {}
    year, month, _, _ = DT.app_parse({"candidates": [{"content": {"parts": [{"text": raw}]}}]})
    day = clean(js.get("day"))
    dm = re.search(r"\d+", day or "")
    y = int(year) if year and str(year).isdigit() else None
    date = (y, month, int(dm.group(0)) if dm and month else None) if y else None
    return {"kind": app_kind(clean(js.get("format"))), "title": None,
            "byline": names(clean(js.get("author_name"))), "publication": clean(js.get("publication_name")),
            "publication_date": date, "recipient_place": names(clean(js.get("recipient_location")))}


# --- selection and images -------------------------------------------------------------------------------------

def cmd_select(a):
    import date_tagging as DT
    docs = []
    ent_docs = {d["id"]: d for d in ET.load_docs()}
    for line in open(os.path.join(ET.CACHE, "truth.jsonl"), encoding="utf-8"):
        t = json.loads(line)
        d = ent_docs[t["id"]]
        docs.append({"id": d["id"], "set": "ent-" + d["set"], "group": "correspondence" if t["is_correspondence"]
                     else "ent-other", "collection": d["collection"], "pages": d["pages"], "text": d["text"],
                     "prompt": d["prompt"]})
    have = {d["id"] for d in docs}
    sample = [json.loads(l) for l in open(os.path.join(DT.CACHE, "sample.jsonl"), encoding="utf-8")]
    import corpus_pairs as CP
    pool, _ = DT.document_pool()   # the sample keeps a page count; the pool has the folder and position
    where = {p["id"]: (p["folder"], p["position"]) for cls in pool for p in pool[cls]}
    lab = {}
    for line in open(os.path.join(CP.CACHE, "labels.jsonl"), encoding="utf-8"):
        g = json.loads(line)
        lab[(g["folder_id"], g["n"])] = g
    segs_of = {}

    class _Pages(dict):
        def __missing__(self, doc_id):
            folder, pos = where[doc_id]
            if folder not in segs_of:
                segs_of[folder] = DT.folder_documents(folder, lab)
            return segs_of[folder][pos]["pages"]
    pages = _Pages()
    rng = random.Random(SEED)
    counts = {"ent-truth": len(docs)}
    for group, fmts in ARTICLE_GROUPS.items():
        by_col = collections.defaultdict(list)
        for d in sorted(sample, key=lambda x: x["id"]):
            if d["id"] not in have and ET.gemini_format(d["prompt"]) in fmts:
                by_col[d["collection"]].append(d)
        cols = sorted(by_col)
        rng.shuffle(cols)
        for c in cols:
            rng.shuffle(by_col[c])
        got = []
        while len(got) < PER_GROUP and any(by_col[c] for c in cols):
            for c in cols:
                if by_col[c] and len(got) < PER_GROUP:
                    got.append(by_col[c].pop())
        for d in got:
            pg = pages[d["id"]]
            docs.append({"id": d["id"], "set": "articles", "group": group, "collection": d["collection"],
                         "pages": pg, "text": "\n\n".join(DT.page_text(p) for p in pg),
                         "prompt": d["prompt"]})
        counts[f"candidates {group}"] = sum(len(v) for v in by_col.values()) + len(got)
        counts[f"drawn {group}"] = len(got)
    os.makedirs(CACHE, exist_ok=True)
    with open(os.path.join(CACHE, "docs.jsonl.tmp"), "w", encoding="utf-8") as fh:
        for d in docs:
            fh.write(json.dumps(d, ensure_ascii=False) + "\n")
    os.replace(os.path.join(CACHE, "docs.jsonl.tmp"), os.path.join(CACHE, "docs.jsonl"))
    json.dump(counts, open(os.path.join(CACHE, "select-summary.json"), "w"), indent=1)
    print(json.dumps(counts, indent=1))


def load_docs():
    return [json.loads(l) for l in open(os.path.join(CACHE, "docs.jsonl"), encoding="utf-8")]


def image_of(d):
    return os.path.join(CACHE, "pages", hashlib.sha1(d["pages"][0].encode()).hexdigest()[:16] + ".jpg")


def cmd_render(a):
    import corpus_survey as CS
    os.makedirs(os.path.join(CACHE, "pages"), exist_ok=True)
    bad = 0
    for d in load_docs():
        out = image_of(d)
        if not os.path.exists(out):
            subprocess.run(["sips", "-s", "format", "jpeg", "-Z", str(MAX_SIDE), os.path.join(CS.CORPUS, d["pages"][0]),
                            "--out", out], capture_output=True, check=False)
        bad += not os.path.exists(out)
    print(f"{len(load_docs())} first pages, {bad} not rendered")


# --- the models (mlx_vlm, one process at a time under run-guarded.sh) -------------------------------------------

def reading_dir(key, stage="drafts"):
    return os.path.join(CACHE, stage, key)


def reading(key, doc_id, stage="drafts"):
    p = os.path.join(reading_dir(key, stage), doc_id + ".json")
    if not os.path.exists(p):
        return None
    return json.load(open(p, encoding="utf-8"))


def local_snapshot(repo):
    """The cached snapshot's directory when its weights are all there, else the repo id. Loading by id asks the Hub
    for the revision first, and that request hung for minutes on this Mac with every file already cached; offline,
    the Hub's check refused the complete snapshot."""
    import glob
    hub = os.path.join(os.environ.get("HF_HOME", ""), "hub", "models--" + repo.replace("/", "--"), "snapshots", "*")
    for d in sorted(glob.glob(hub)):   # mlx_vlm loads every *.safetensors; Gemma's index names stale shards
        shards = glob.glob(os.path.join(d, "*.safetensors"))
        if shards and all(os.path.exists(x) for x in shards) and os.path.exists(os.path.join(d, "config.json")):
            return d
    return repo


class Model:
    def __init__(self, key):
        import model_store
        model_store.use()   # before mlx_vlm imports huggingface_hub, which reads HF_HOME once
        import mlx.core as mx
        from mlx_vlm import load
        mx.set_cache_limit(256 * 2**20)
        self.key = key
        self.model, self.processor = load(local_snapshot(MODELS[key][0]))

    def run(self, prompt, image=None):
        from mlx_vlm import stream_generate
        from mlx_vlm.prompt_utils import apply_chat_template
        n = 1 if image else 0
        try:  # Qwen3.5 thinks unless told not to; the other templates take no such switch
            chat = apply_chat_template(self.processor, self.model.config, prompt, num_images=n, enable_thinking=False)
        except TypeError:
            chat = apply_chat_template(self.processor, self.model.config, prompt, num_images=n)
        start, text, last = time.time(), [], None
        kw = {"image": [image]} if image else {}
        for r in stream_generate(self.model, self.processor, chat, max_tokens=MAX_TOKENS, temperature=0.0, **kw):
            text.append(r.text)
            last = r
        return {"raw": "".join(text), "wall_s": round(time.time() - start, 2),
                "tokens": [getattr(last, "prompt_tokens", 0), getattr(last, "generation_tokens", 0)]}


def save(key, stage, doc_id, rec):
    os.makedirs(reading_dir(key, stage), exist_ok=True)
    p = os.path.join(reading_dir(key, stage), doc_id + ".json")
    with open(p + ".tmp", "w", encoding="utf-8") as fh:
        json.dump(rec, fh, ensure_ascii=False)
    os.replace(p + ".tmp", p)


def prompt_for(d, template=PROMPT):
    return template.replace("{text}", d["text"][:TEXT_CAP])


def loop(key, stage, todo, make):
    print(f"{key} {stage}: {len(todo)} documents", flush=True)
    if not todo:
        return
    m = Model(key)
    for k, d in enumerate(todo, 1):
        prompt, image = make(d)
        rec = m.run(prompt, image)
        rec["id"] = d["id"]
        save(key, stage, d["id"], rec)
        print(f"[{k}/{len(todo)}] {d['id']} {rec['wall_s']}s {'ok' if parse(rec['raw']) else 'unparsed'}", flush=True)


def cmd_collect(a):
    todo = [d for d in load_docs() if os.path.exists(image_of(d)) and reading(a.model, d["id"]) is None]
    loop(a.model, "drafts", todo[: a.limit or None], lambda d: (prompt_for(d), image_of(d)))


def show(r):
    out = {f: r[f] for f in FIELDS}
    out["publication_date"] = "-".join(f"{x:02d}" if i else str(x) for i, x in enumerate(r["publication_date"])
                                       if x is not None) if r["publication_date"] else None
    return json.dumps(out, ensure_ascii=False)


PLACEHOLDER = {"city, state", "city, country", "city"}


def by_definition(r):
    """The label definitions applied to a reader's or the judge's reading (never to a scored predictor): a letter,
    memo or telegram has no byline, publication or publication date, a letter or telegram no title, and a
    placeholder copied from the prompt is no place. Gemma 3 gave most letters a publication date (their own date)
    though the prompt says always null; left in, nearly every document went to a judge that is Gemma again."""
    if r is None:
        return None
    r = dict(r)
    if r.get("kind") in CORRESP:
        r["byline"], r["publication"], r["publication_date"] = [], None, None
        if r["kind"] != "memo":
            r["title"] = None
    r["recipient_place"] = [x for x in r.get("recipient_place") or [] if x.strip().lower() not in PLACEHOLDER]
    return r


def both(d):
    ra, rb = (reading(k, d["id"]) for k in READERS)
    pa, pb = (by_definition(parse(r["raw"])) if r else None for r in (ra, rb))
    return pa, pb


def cmd_adjudicate(a):
    todo = []
    for d in load_docs():
        pa, pb = both(d)
        if pa and pb and disputes(pa, pb) and reading(JUDGE, d["id"], "adjudicated") is None:
            todo.append(d)

    def make(d):
        pa, pb = both(d)
        head = JUDGE_PROMPT.format(fields=", ".join(disputes(pa, pb)), a=show(pa), b=show(pb))
        return head + prompt_for(d), image_of(d)
    loop(JUDGE, "adjudicated", todo[: a.limit or None], make)


def cmd_extract(a):
    todo = [d for d in load_docs() if reading(EXTRACTOR, d["id"], "extract") is None]
    loop(EXTRACTOR, "extract", todo[: a.limit or None], lambda d: (prompt_for(d, TEXT_ONLY), None))


# --- the truth and the score ------------------------------------------------------------------------------------

def truth_of(d):
    """(label, how) — how is agreed | ruled-A | ruled-B | ruled-mixed | ruled-neither | unparsed."""
    pa, pb = both(d)
    if not pa or not pb:
        return None, "unparsed"
    dis = disputes(pa, pb)
    if not dis:
        return pa, "agreed"
    r = reading(JUDGE, d["id"], "adjudicated")
    pr = by_definition(parse(r["raw"])) if r else None
    if not pr:
        return None, "unruled"
    sa = all(agree(f, pr.get(f), pa.get(f)) for f in dis)
    sb = all(agree(f, pr.get(f), pb.get(f)) for f in dis)
    some = any(agree(f, pr.get(f), pa.get(f)) or agree(f, pr.get(f), pb.get(f)) for f in dis)
    how = "ruled-A" if sa and not sb else "ruled-B" if sb and not sa else "ruled-mixed" if some else "ruled-neither"
    return pr, how


def score(pairs, field):
    """pairs: [(pred reading, truth label)]. Counts over documents."""
    s = collections.Counter()
    for p, t in pairs:
        pv, tv = p.get(field), t.get(field)
        pf, tf = filled(field, pv), filled(field, tv)
        s["docs"] += 1
        s["truth_filled"] += tf
        s["pred_filled"] += pf
        s["null_when_truth"] += tf and not pf
        if pf and tf:
            s["exact"] += field_match(field, pv, tv, "exact")
            s["ed2"] += field_match(field, pv, tv, "ed2")
        s["wrong_when_filled"] += pf and not (tf and field_match(field, pv, tv, "ed2"))
        s["filled_when_empty"] += pf and not tf
    s = {k: s[k] for k in ("docs", "truth_filled", "pred_filled", "null_when_truth", "exact", "ed2",
                           "wrong_when_filled", "filled_when_empty")}   # a Counter gives 0 for a missing key
    s["fill_rate"] = s["pred_filled"] / s["docs"] if s["docs"] else None
    s["precision_ed2"] = s["ed2"] / s["pred_filled"] if s["pred_filled"] else None
    s["recall_ed2"] = s["ed2"] / s["truth_filled"] if s["truth_filled"] else None
    return s


# The documents each field is scored on: a field belongs to some kinds of document only, and scoring it elsewhere
# would bury its misses under the documents where it is trivially empty. filled_when_empty is still counted there.
PUBLISHED = {"newspaper article", "magazine article", "journal article", "newsletter", "clipping", "report"}
CORRESP = {"letter", "memo", "telegram"}
SCOPE = {"kind": None, "title": None, "byline": PUBLISHED, "publication": None, "publication_date": PUBLISHED,
         "recipient_place": CORRESP}


def scoped(pairs, field):
    ks = SCOPE[field]
    return [(p, t) for p, t in pairs if ks is None or t.get("kind") in ks]


def verdict(s):
    if s and s.get("docs") and not s.get("pred_filled"):
        return "never filled"
    if not s or s.get("truth_filled", 0) < MIN_N or s.get("precision_ed2") is None:
        return "too few to tell"
    return "fill" if s["precision_ed2"] >= BAR else "leave empty"


def cmd_build(a):
    docs = load_docs()
    rows, hows = [], collections.Counter()
    disputed = collections.Counter()
    for d in docs:
        t, how = truth_of(d)
        hows[how] += 1
        pa, pb = both(d)
        if pa and pb:
            for f in disputes(pa, pb):
                disputed[f] += 1
        if t is None:
            continue
        rows.append({"id": d["id"], "set": d["set"], "group": d["group"], "collection": d["collection"], "how": how,
                     **{f: t[f] for f in FIELDS}, "zotero": ZOTERO.get(t["kind"]) if t["kind"] else None})
    os.makedirs(CACHE, exist_ok=True)
    with open(os.path.join(CACHE, "truth.jsonl"), "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    truth = {r["id"]: r for r in rows}
    by_id = {d["id"]: d for d in docs}
    preds = {}
    for name, label in APP.items():
        preds["app " + name] = {i: app_reading(by_id[i]["prompt"], label) for i in truth}
    preds["extractor " + EXTRACTOR] = {i: (lambda r: parse(r["raw"]) if r else None)(reading(EXTRACTOR, i, "extract"))
                                       for i in truth}
    for k in READERS:
        preds["reader " + k] = {i: (lambda r: parse(r["raw"]) if r else None)(reading(k, i)) for i in truth}
    with_reply = {i for i in truth if preds["app gemini-3.8-flash"][i] is not None}
    table = {}
    for pname, pm in preds.items():
        ids = sorted(with_reply) if pname.startswith("app ") else sorted(truth)
        for subset, sids in (("replied", sorted(with_reply)), ("all", ids)):
            if subset == "all" and pname.startswith("app "):
                continue
            pairs = [(pm[i] or {f: ([] if f in LISTS else None) for f in FIELDS}, truth[i]) for i in sids]
            for f in FIELDS:
                table[f"{pname}|{subset}|{f}"] = score(scoped(pairs, f), f)
    walls = {}
    for k in list(READERS) + [JUDGE, EXTRACTOR]:
        stage = "adjudicated" if k == JUDGE else "extract" if k == EXTRACTOR else "drafts"
        w = [reading(k, d["id"], stage)["wall_s"] for d in docs if reading(k, d["id"], stage)]
        walls[f"{k} {stage}"] = [len(w), round(sum(w) / len(w), 1) if w else None]
    counts = {
        "documents": len(docs), "labelled": len(rows), "how": dict(hows), "disputed_fields": dict(disputed),
        "by_set": dict(collections.Counter(r["set"] for r in rows)),
        "kinds": dict(collections.Counter(r["kind"] for r in rows).most_common()),
        "zotero": dict(collections.Counter(r["zotero"] for r in rows).most_common()),
        "filled": {f: sum(filled(f, r[f]) for r in rows) for f in FIELDS},
        "filled_articles": {f: sum(filled(f, r[f]) for r in rows if r["set"] == "articles") for f in FIELDS},
        "with_reply": len(with_reply), "select": json.load(open(os.path.join(CACHE, "select-summary.json"))),
        "walls": walls}
    out = {"counts": counts, "scores": table, "bar": [BAR, MIN_N]}
    json.dump(out, open(RESULTS.replace(".md", ".json"), "w"), indent=1, sort_keys=True)
    open(RESULTS, "w").write(report(out))
    print(report(out))


def f3(x):
    return "-" if x is None else f"{x:.2f}"


def report(o):
    c, sc = o["counts"], o["scores"]
    L = ["# Item fields: a truth set and how well they are filled now (W47.item-fields-truth)", "",
         "Generated by `scripts/segbench/item_fields.py build`; method in its header. The labels are the owner's "
         "material and stay in the bench cache (`~/Library/Caches/ArchiveSuiteRehearsal/item-fields/truth.jsonl`); "
         "this page has counts only.", "",
         "## The set", "",
         f"{c['documents']} documents: W46.fix-ent-truth's {c['select']['ent-truth']} and "
         + ", ".join(f"{c['select'][f'drawn {g}']} {g}" for g in ARTICLE_GROUPS)
         + " pieces from the date-tagging sample by Gemini's `format`. "
         f"{c['labelled']} labelled ({', '.join(f'{k} {v}' for k, v in sorted(c['how'].items()))}). "
         f"{c['with_reply']} carry the app's cached tagging replies and are what the app is scored on.", "",
         "| kind (truth) | documents |", "|---|---|"]
    L += [f"| {k} | {v} |" for k, v in c["kinds"].items()]
    L += ["", "| Zotero item type | documents |", "|---|---|"] + [f"| {k} | {v} |" for k, v in c["zotero"].items()]
    L += ["", "| field | documents with a value | of them in the 60 articles and reports |", "|---|---|---|"]
    L += [f"| {f} | {c['filled'][f]} | {c['filled_articles'][f]} |" for f in FIELDS]
    L += ["", "## Drafting and adjudication", "",
          f"Readers A {MODELS[READERS[0]][1]} and B {MODELS[READERS[1]][1]} read every document blind (OCR text's "
          f"first {TEXT_CAP:,} characters and the first page at {MAX_SIDE} px; this Mac, temperature 0, $0, no plan "
          f"route). {MODELS[JUDGE][1]}, reader B, ruled every document they differed on. Qwen3-VL 8B is also a "
          "scored local route (from text alone, through the app's prompt) and Gemma is a relative of Gemini, so those "
          "two app rows may lean their way on disputed documents. The label definitions were applied to every reading "
          "and ruling before agreement (no byline, publication or publication date on a letter, memo or telegram, no "
          "title on a letter or telegram): Gemma gave most letters their own date as a publication date.", "",
          "Disputed fields (documents): " + ", ".join(f"{k} {v}" for k, v in
                                                     sorted(c["disputed_fields"].items(), key=lambda x: -x[1])) + ".",
          "", "Seconds a document on average: " + "; ".join(f"{k} {v[1]} over {v[0]}" for k, v in c["walls"].items())
          + ".", ""]
    L += ["## What is filled now, against the truth", "",
          f"Per field, over the documents the field belongs to (byline and publication date: printed pieces and "
          f"reports; recipient place: letters, memos and telegrams; kind, title and publication: every document). "
          f"Loose = edit distance 2 for text and names, year and month for dates, the same Zotero type for kind. "
          f"Precision and recall at the loose level; wrong-when-filled counts a value where the truth has none too. "
          f"The bar to fill a field: precision {BAR:.2f} on at least {MIN_N} documents with a true value.", "",
          "| predictor | field | docs | true values | filled | exact | loose | null when true | wrong when filled "
          "| precision | recall | verdict |", "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for key in sorted(sc):
        pname, subset, f = key.split("|")
        if subset != "replied":
            continue
        s = sc[key]
        L.append(f"| {pname} | {f} | {s.get('docs', 0)} | {s.get('truth_filled', 0)} | {s.get('pred_filled', 0)} | "
                 f"{s.get('exact', 0)} | {s.get('ed2', 0)} | {s.get('null_when_truth', 0)} | "
                 f"{s.get('wrong_when_filled', 0)} | {f3(s.get('precision_ed2'))} | {f3(s.get('recall_ed2'))} | "
                 f"{verdict(s) if pname.startswith(('app', 'extractor')) else 'agreement'} |")
    L += ["", f"The extractor on every labelled document (the 72 additions have no app replies):", "",
          "| field | docs | true values | filled | loose | wrong when filled | precision | recall | verdict |",
          "|---|---|---|---|---|---|---|---|---|"]
    for f in FIELDS:
        s = sc.get(f"extractor {EXTRACTOR}|all|{f}", {})
        L.append(f"| {f} | {s.get('docs', 0)} | {s.get('truth_filled', 0)} | {s.get('pred_filled', 0)} | "
                 f"{s.get('ed2', 0)} | {s.get('wrong_when_filled', 0)} | {f3(s.get('precision_ed2'))} | "
                 f"{f3(s.get('recall_ed2'))} | {verdict(s)} |")
    L += ["", "## Which fields to fill", "",
          "The verdict per field for the app's cloud route (Gemini 3.8 Flash), its laptop route (Qwen3.5 4B through "
          "the app's prompt) and the dedicated extractor (Qwen3.5 4B with this item's prompt), on the documents with "
          "replies, with the precision in brackets. W47.item-fields-build fills a field only where its route clears "
          "the bar.", "",
          "| field | Gemini 3.8 Flash (app) | Qwen3.5 4B (app) | Qwen3.5 4B (extractor) |", "|---|---|---|---|"]
    for f in FIELDS:
        cells = []
        for key in ("app gemini-3.8-flash", "app qwen3.5-4b", f"extractor {EXTRACTOR}"):
            s = sc.get(f"{key}|replied|{f}", {})
            cells.append(f"{verdict(s)} ({f3(s.get('precision_ed2'))})")
        L.append(f"| {f} | " + " | ".join(cells) + " |")
    L += ["", "## Limits", "",
          "- The 60 articles and reports were drawn by Gemini's own `format`, so Gemini's kind on them is favoured; "
          "the 159 W46 documents were drawn by Gemini's format too (letters, memos, telegrams) or by text cues.",
          "- The 72 W46 additions have no cached app replies; the app is scored on the documents that have them. "
          "Their fresh Gemini replies are a deferred paid run (execution-plans/paid-runs-deferred.md).",
          f"- Readers saw the first page and the first {TEXT_CAP:,} characters only: titles, bylines and mastheads "
          "sit there, but a recipient address or a running head on a later page is missed.",
          "- The app's date is its estimate of the document's date, not a printed issue date; on a printed piece "
          "with no printed date it counts as filled where the truth is empty. Recall is the share right where a "
          "date is printed.",
          "- Model-drafted and model-adjudicated by two open 8-12B models (STATE Phase 2 decision 2), no owner pass; "
          "the session that built it spot-checked rows against the page images (the DONE entry).", ""]
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("select").set_defaults(fn=cmd_select)
    sub.add_parser("render").set_defaults(fn=cmd_render)
    c = sub.add_parser("collect")
    c.add_argument("--model", choices=READERS, required=True)
    c.add_argument("--limit", type=int)
    c.set_defaults(fn=cmd_collect)
    for name, fn in (("adjudicate", cmd_adjudicate), ("extract", cmd_extract)):
        p = sub.add_parser(name)
        p.add_argument("--limit", type=int)
        p.set_defaults(fn=fn)
    sub.add_parser("build").set_defaults(fn=cmd_build)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
