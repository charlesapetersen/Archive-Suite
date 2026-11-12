#!/usr/bin/env python3
"""W41.date-tag-measure: how well the app's tagger dates a document, scored against the owner's Finder tags.

Segmentation only proposes boundaries; TagGenerator.generateTags (the default, "automatic" tagging mode) then asks
the run's model for a year (always), a month (only if stated) and date_uncertain. Nothing in the bench had scored
that. This sends whole corpus documents through the app's exact prompt and compares the answer with the owner's
own year, month and Date Uncertain tags.

    python3 date_tagging.py sample           # documents -> cache sample.jsonl (no model call)
    python3 date_tagging.py run [--limit N]  # each sampled document through the app's prompt (paid, capped)
    python3 date_tagging.py score            # cache answers -> segbench-results/date-tagging.md (numbers only)
    python3 date_tagging.py export --out DIR # the sampled prompts as requests.jsonl, for FarmShare's cluster_text.py
    python3 date_tagging.py import --answers FILE --label L   # cluster_text.py's answers, as the local route reads them
    python3 date_tagging.py score --label L  # an open model's figures, beside Gemini's, in date-tagging.md
    python3 date_tagging.py train-data [--out DIR]   # W41.date-model's train/val sets (no model call)

OPEN MODELS (2026-10-17). The same prompts through FarmShare's vLLM (institutional-compute/cluster_text.py), sent as the app's local
route sends a text call: one user message, 512 tokens, temperature 0, no reasoning switch; the reply's reasoning
stripped as LocalModelRoute.strippingReasoning strips it, then parsed as TagGenerator parses it. A label ending
"-nothink" was sent with thinking switched off, which the app does not do.

DOCUMENTS. A document is a run of page photos with one identity tag set (corpus_pairs.folder_pages' rule: New,
then Cont), from the folders corpus_pairs windowed (its EXCLUDE already sets aside the corpus copies of the
development and test boxes, Stanton and RG 165 among them). Kept only where every gap that bounds or splits it is
one the teacher and the tags agree on (labels.jsonl `keep`, W41.seg-label-clean), so the truth is a real document.
Its text is ABBYY's layer (corpus_pairs' text cache), page texts joined by a blank line as
DocumentSegment.combinedText joins them. The app would send its own OCR, not ABBYY's.

CONTEXT. As OCRProcessor+Tagging builds it: the three segments before, then after, each cut to 300 characters,
joined by "\\n---\\n". Segments here are the tag rule's, with Box and Folder photos as their own segments.

TRUTH CLASSES, from the document's first page's tags (Unread and colours dropped):
  year+month   one year tag, one "MM Month" tag
  year         one year tag, no month tag
  year+DU      one year tag and Date Uncertain (with or without a month)
  decade       one "1970s"-style tag, no year tag
Documents with no date tag, two years or two months are counted and not sampled.

READ ONLY on the corpus: tags through corpus_survey.read_tags (getxattr). Model answers are cached by the request's
hash, so a rerun costs nothing. Python slices the text by code point where Swift's prefix counts characters; the
two differ only on combining marks.
"""
import argparse
import collections
import concurrent.futures as cf
import hashlib
import json
import os
import random
import re
import subprocess
import sys
import threading
import time

import corpus_pairs as CP
import corpus_survey as CS

CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/date-tagging")
RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "segbench-results", "date-tagging.md")
RESULTS_JSON = RESULTS[:-3] + ".json"   # the same figures for ArchiveOCRBench/build.py
SWIFT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "macOS", "Sources", "ArchiveProcessor",
                     "Tagging", "TagGenerator.swift")
# The app's default model (ProviderModels.geminiModels[0]) and its price, per million tokens; thinking is billed as
# output. Tagging passes thinkingLevel nil, so LLMTextClient.callGemini sends no generationConfig at all.
MODEL = "gemini-3.8-flash"
PRICE_IN, PRICE_OUT = 0.75, 3.75
API = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
CAP_USD = 2.50            # the run stops before passing this (the owner's rule is $3 a piece of work)
WORKERS = 6               # OCRProcessor+Tagging's maxConcurrent
SEED = 41
PER_CLASS = {"year+month": 120, "year": 80, "year+DU": 50, "decade": 50}
STANTON_RG165 = re.compile(r"stanton|rg ?165", re.I)
MONTH = re.compile(r"^(\d\d) [A-Z][a-z]+$")
DECADE = re.compile(r"^(1[5-9]\d0|20\d0)s$")

# TagGenerator.generateTags' prompt, verbatim (test_date_tagging.py compares it with the Swift). {text}, {context}
# and {subject_rule} stand for its three interpolations; the subject rule is the empty-vocabulary branch, the
# app's default (OCRProcessor.tagVocabulary = []).
PROMPT = """You are a metadata tagging assistant for a historical archive.

Here is the OCR text of a document:
---
{text}
---

Nearby documents for date estimation context (use only if this document's date is unclear):
---
{context}
---

Please respond with ONLY a valid JSON object in this exact format:
{{
  "year": "1987",
  "month": "03 March",
  "day": "Day 15",
  "date_uncertain": false,
  "subject_tags": ["Democratic Party", "elections", "legislation"],
  "format": "letter",
  "author_name": "John Smith",
  "recipient_name": "Jane Doe",
  "author_location": "Washington, D.C.",
  "recipient_location": "New York, NY",
  "publication_name": null
}}

Rules:
- "year": 4-digit year string. ALWAYS provide a year — if not stated in the document, estimate from nearby documents or contextual clues. Never return null for year.
- "month": format "MM MonthName" (e.g. "03 March"). Provide ONLY if the month is explicitly stated in THIS document. NEVER infer or estimate the month from context or nearby documents. Return null otherwise.
- "day": format "Day D" (e.g. "Day 15", "Day 3"), or null if not determinable
- "date_uncertain": true if year cannot be determined from the document itself (even if estimated from context)
- "subject_tags": {subject_rule}
- "format": document type, e.g. "letter", "memo", "newspaper article", "magazine article", "report", "draft", "speech", "press release", "telegram", "photograph", or null if unclear
- "author_name": author, sender, or writer name if identifiable, or null
- "recipient_name": recipient or addressee name if identifiable, or null
- "author_location": author's or sender's location if identifiable, or null
- "recipient_location": recipient's location if identifiable, or null
- "publication_name": newspaper, magazine, or publication name if applicable, or null
- Respond with ONLY the JSON object. No commentary."""
SUBJECT_RULE = ('2–6 general-but-specific subject tags (e.g. "Democratic Party", "taxes", "education", '
                '"transportation", "business", "literature", "economics", "foreign policy", "civil rights", '
                '"military", "journalism", "science", "health care", "labor unions"). Do NOT use overly broad '
                'terms like "politics" or "history".')


def build_prompt(text, context):
    return PROMPT.format(text=text[:3000], context=context if context else "(none)", subject_rule=SUBJECT_RULE)


# --- documents --------------------------------------------------------------------------------

def page_text(pdf):
    p = os.path.join(CP.CACHE, "text", hashlib.sha1(pdf.encode()).hexdigest() + ".txt")
    if not os.path.exists(p):
        return ""
    t = open(p, encoding="utf-8").read()
    return "" if t.startswith("\x00") else t


def truth_of(tags):
    t = set(tags) - CS.IGNORED
    years = [int(x) for x in t if CS.YEAR.match(x)]
    decades = [int(DECADE.match(x).group(1)) for x in t if DECADE.match(x)]
    months = [int(MONTH.match(x).group(1)) for x in t if MONTH.match(x) and 1 <= int(MONTH.match(x).group(1)) <= 12]
    du = "Date Uncertain" in t
    if len(years) > 1 or len(months) > 1:
        return "ambiguous", None
    if years:
        cls = "year+DU" if du else ("year+month" if months else "year")
        return cls, {"year": years[0], "month": months[0] if months else None, "du": du}
    if len(decades) == 1 and not months:
        return "decade", {"decade": decades[0], "du": du}
    return "undated" if not decades and not months else "ambiguous", None


def folder_documents(folder, lab):
    """[(segment dict)] for every tag-rule segment of the folder, in order; a document segment carries `agreed`."""
    fid = hashlib.sha1(folder.encode()).hexdigest()[:12]
    ps = CP.folder_pages(folder, {})
    segs, i = [], 0
    while i < len(ps):
        kind = ps[i][2]
        if kind in ("Box", "Folder"):
            segs.append({"kind": kind, "pages": [ps[i][0]]}); i += 1; continue
        j = i
        while j + 1 < len(ps) and ps[j + 1][2] == "Cont":
            j += 1
        # Gap n (1-based) is the gap after page n: page index k's gap before it is n = k.
        gaps = ([i] if i > 0 else []) + list(range(i + 1, j + 1)) + ([j + 1] if j + 1 < len(ps) else [])
        agreed = all((g := lab.get((fid, n))) is not None and g["keep"] for n in gaps)
        segs.append({"kind": "doc", "pages": [p for p, _, _ in ps[i:j + 1]], "agreed": agreed})
        i = j + 1
    return segs


def document_pool():
    """Every agreed, dated document with text, by truth class, as the prompt the app would send; and the counts."""
    lab = {}
    for line in open(os.path.join(CP.CACHE, "labels.jsonl"), encoding="utf-8"):
        g = json.loads(line)
        lab[(g["folder_id"], g["n"])] = g
    folders = sorted({os.path.dirname(g["left"]) for g in lab.values()})
    assert not any(STANTON_RG165.search(f) for f in folders), "a Stanton or RG 165 copy is in the labels"
    pool = collections.defaultdict(list)
    counts = collections.Counter()
    for f in folders:
        segs = folder_documents(f, lab)
        texts = ["\n\n".join(page_text(p) for p in s["pages"]) for s in segs]
        for k, s in enumerate(segs):
            if s["kind"] != "doc":
                continue
            counts["documents"] += 1
            if not s["agreed"]:
                counts["not agreed"] += 1
                continue
            cls, truth = truth_of(CS.read_tags(os.path.join(CS.CORPUS, s["pages"][0])))
            counts[f"agreed {cls}"] += 1
            if truth is None:
                continue
            if not texts[k].strip():
                counts[f"agreed {cls} no text"] += 1
                continue
            near = segs[max(0, k - 3):k] + segs[k + 1:k + 4]
            near_texts = (texts[max(0, k - 3):k] + texts[k + 1:k + 4])[:3]
            context = "\n---\n".join(t[:300] for t in near_texts)
            context_ids = [hashlib.sha1(n["pages"][0].encode()).hexdigest()[:16] for n in near[:3]]
            year_s = str(truth.get("year", ""))
            pool[cls].append({"id": hashlib.sha1(s["pages"][0].encode()).hexdigest()[:16], "class": cls,
                              "collection": CP.collection_of(f), "pages": len(s["pages"]), "truth": truth,
                              "year_in_text": bool(year_s) and year_s in texts[k][:3000],
                              "prompt": build_prompt(texts[k], context), "n_near": len(near),
                              "context_ids": context_ids, "folder": f, "position": k})
    counts["folders"] = len(folders)
    return pool, counts


def cmd_sample(a):
    pool, counts = document_pool()
    rng = random.Random(SEED)
    sample = []
    for cls, want in PER_CLASS.items():
        by_col = collections.defaultdict(list)
        for d in pool[cls]:
            by_col[d["collection"]].append(d)
        cols = sorted(by_col)
        rng.shuffle(cols)
        for c in cols:
            rng.shuffle(by_col[c])
        got = []
        while len(got) < want and any(by_col[c] for c in cols):
            for c in cols:
                if by_col[c] and len(got) < want:
                    got.append(by_col[c].pop())
        sample += got
        counts[f"sampled {cls}"] = len(got)
        counts[f"collections {cls}"] = len({d['collection'] for d in got})
    os.makedirs(CACHE, exist_ok=True)
    with open(os.path.join(CACHE, "sample.jsonl.tmp"), "w", encoding="utf-8") as fh:
        for d in sample:
            fh.write(json.dumps({k: v for k, v in d.items() if k not in ("context_ids", "folder", "position")}, ensure_ascii=False) + "\n")
    os.replace(os.path.join(CACHE, "sample.jsonl.tmp"), os.path.join(CACHE, "sample.jsonl"))
    json.dump(dict(sorted(counts.items())), open(os.path.join(CACHE, "sample-summary.json"), "w"), indent=1)
    print(json.dumps(dict(sorted(counts.items())), indent=1))


def target_of(truth):
    """The reply a dating model is trained to give (W41.date-model): the app's JSON with the owner's year, month and
    Date Uncertain, and nothing else. Subjects and the other fields are omitted (parseTagResponse reads a missing
    key as none); day is null because the owner's tags carry no day."""
    m = truth["month"]
    return json.dumps({"year": str(truth["year"]), "month": f"{m:02d} {MONTH_NAMES[m - 1]}" if m else None,
                       "day": None, "date_uncertain": truth["du"]}, ensure_ascii=False)


def cmd_train_data(a):
    """W41.date-model's training set: every pooled document with a year, less the 300 sampled (the test), split into
    corpus_pairs' held-out collections (val) and the rest (train). Decade documents have no year to train to. A
    document whose context snippets include a test document is dropped too, so no test text is trained on."""
    pool, _ = document_pool()
    test = {json.loads(l)["id"] for l in open(os.path.join(CACHE, "sample.jsonl"), encoding="utf-8")}
    held = set(json.load(open(os.path.join(CP.CACHE, "holdout.json"))))
    test_prompts = {d["prompt"] for ds in pool.values() for d in ds if d["id"] in test}
    rows = {"train": [], "val": []}
    why = collections.Counter()
    for cls in ("year+month", "year", "year+DU", "decade"):
        for d in pool[cls]:
            if d["id"] in test:
                why["test"] += 1; continue
            if cls == "decade":
                why["decade"] += 1; continue
            if d["prompt"] in test_prompts:
                why["same prompt as a test document"] += 1; continue
            if test & set(d["context_ids"]):
                why["a test document in its context"] += 1; continue
            split = "val" if d["collection"] in held else "train"
            rows[split].append({"id": d["id"], "collection": d["collection"], "class": cls,
                                "year_in_text": d["year_in_text"], "prompt": d["prompt"], "target": target_of(d["truth"])})
    out = a.out or os.path.join(CACHE, "train")
    os.makedirs(out, exist_ok=True)
    for split, rs in rows.items():
        random.Random(SEED).shuffle(rs)
        with open(os.path.join(out, split + ".jsonl"), "w", encoding="utf-8") as fh:
            fh.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in rs)
    summary = {"dropped": dict(why),
               **{split: {"documents": len(rs), "collections": len({r["collection"] for r in rs}),
                          "classes": dict(collections.Counter(r["class"] for r in rs)),
                          "year_not_in_text": sum(not r["year_in_text"] for r in rs)} for split, rs in rows.items()},
               "test_in_held_collections": sum(d["collection"] in held for ds in pool.values() for d in ds
                                               if d["id"] in test)}
    json.dump(summary, open(os.path.join(out, "data.json"), "w"), indent=1)
    print(json.dumps(summary, indent=1))


# --- the model ---------------------------------------------------------------------------------

def api_key():
    r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "com.archiveprocessor.app",
                        "-a", "Gemini", "-w"], capture_output=True, text=True)
    k = r.stdout.strip()
    if r.returncode != 0 or not k:
        raise SystemExit("no Gemini key in the Keychain (com.archiveprocessor.app / Gemini)")
    return k


def body_of(prompt):
    return {"contents": [{"parts": [{"text": prompt}]}]}


def answer_path(prompt, label=None):
    """Gemini's answers by the request's hash; an open model's (label) by the prompt's id."""
    if label:
        return os.path.join(CACHE, "answers-" + label, prompt_id(prompt) + ".json")
    h = hashlib.sha256(json.dumps([MODEL, body_of(prompt)], sort_keys=True).encode()).hexdigest()
    return os.path.join(CACHE, "answers", h + ".json")


def prompt_id(prompt):
    return hashlib.sha256(prompt.encode()).hexdigest()[:24]


def strip_reasoning(s):
    """LocalModelRoute.strippingReasoning: every closed <think> block, then text up to a stray </think>."""
    while "<think>" in s and "</think>" in s[s.index("<think>"):]:
        i = s.index("<think>"); j = s.index("</think>", i) + len("</think>")
        s = s[:i] + s[j:]
    if "<think>" not in s and "</think>" in s:
        s = s[s.index("</think>") + len("</think>"):]
    return s.strip()


def cmd_export(a):
    docs = [json.loads(l) for l in open(os.path.join(CACHE, "sample.jsonl"), encoding="utf-8")]
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "requests.jsonl"), "w", encoding="utf-8") as f:
        for d in docs:
            f.write(json.dumps({"id": prompt_id(d["prompt"]), "prompt": d["prompt"]}, ensure_ascii=False) + "\n")
    print(f"{len(docs)} prompts -> {a.out}/requests.jsonl")


def cmd_import(a):
    """cluster_text.py's answers, stored in Gemini's reply shape so app_parse reads them unchanged."""
    d = os.path.join(CACHE, "answers-" + a.label)
    os.makedirs(d, exist_ok=True)
    n = 0
    for line in open(a.answers, encoding="utf-8"):
        r = json.loads(line)
        if "raw" not in r:
            continue
        u = r.get("usage") or {}
        with open(os.path.join(d, r["id"] + ".json"), "w") as fh:
            json.dump({"candidates": [{"content": {"parts": [{"text": strip_reasoning(r["raw"])}]},
                                       "finishReason": r.get("finish")}],
                       "usageMetadata": {"promptTokenCount": u.get("prompt_tokens", 0),
                                         "candidatesTokenCount": u.get("completion_tokens", 0)},
                       "finish": r.get("finish"), "raw_chars": len(r["raw"])}, fh)
        n += 1
    print(f"{n} answers -> {d}")


def cost(u):
    return (u.get("promptTokenCount", 0) * PRICE_IN
            + (u.get("candidatesTokenCount", 0) + u.get("thoughtsTokenCount", 0)) * PRICE_OUT) / 1e6


def spent():
    d = os.path.join(CACHE, "answers")
    if not os.path.isdir(d):
        return 0.0, 0
    tot = n = 0
    for name in os.listdir(d):
        if name.endswith(".json"):
            tot += cost(json.load(open(os.path.join(d, name))).get("usageMetadata") or {}); n += 1
    return tot, n


def cmd_run(a):
    import requests
    docs = [json.loads(l) for l in open(os.path.join(CACHE, "sample.jsonl"), encoding="utf-8")]
    if a.limit:
        docs = docs[:a.limit] if not a.spread else [d for k, d in enumerate(docs) if k % (len(docs) // a.limit) == 0][:a.limit]
    todo = [d for d in docs if not os.path.exists(answer_path(d["prompt"]))]
    total, n = spent()
    print(f"{len(docs)} documents, {len(todo)} to send; ${total:.4f} spent on {n} answers so far", flush=True)
    key = api_key()
    lock = threading.Lock()
    state = {"usd": total, "stop": False}
    os.makedirs(os.path.join(CACHE, "answers"), exist_ok=True)

    def one(d):
        with lock:
            if state["stop"] or state["usd"] >= CAP_USD:
                state["stop"] = True
                return "capped"
        for attempt in range(4):
            try:
                r = requests.post(API.format(model=MODEL), params={"key": key}, json=body_of(d["prompt"]), timeout=120)
            except requests.RequestException as e:
                err = type(e).__name__
            else:
                if r.status_code == 200:
                    resp = r.json()
                    p = answer_path(d["prompt"])
                    with open(p + ".tmp", "w") as fh:
                        json.dump(resp, fh)
                    os.replace(p + ".tmp", p)
                    with lock:
                        state["usd"] += cost(resp.get("usageMetadata") or {})
                    return "ok"
                err = f"HTTP {r.status_code}"
                if r.status_code not in (429, 500, 502, 503, 504):
                    return err
            time.sleep(5 * 2 ** attempt)
        return err
    res = collections.Counter()
    with cf.ThreadPoolExecutor(WORKERS) as ex:
        for k, out in enumerate(ex.map(one, todo), 1):
            res[out] += 1
            if k % 25 == 0:
                print(f"{k}/{len(todo)} ${state['usd']:.4f}", flush=True)
    print(dict(res), f"${state['usd']:.4f} spent in all", flush=True)


# --- scoring -----------------------------------------------------------------------------------

def app_parse(resp):
    """What TagGenerator.parseTagResponse keeps of a reply: (year string or None, month number or None, uncertain,
    parsed). An unusable reply is the app's GeneratedTags(dateUncertain: true)."""
    try:
        parts = resp["candidates"][0]["content"]["parts"]
        raw = "".join(p.get("text", "") for p in parts)
    except (KeyError, IndexError, TypeError):
        return None, None, True, False
    s = raw.strip()
    if s.startswith("```"):
        s = "\n".join(s.split("\n")[1:-1])
    i, j = s.find("{"), s.rfind("}")
    if i >= 0 and j >= i:
        s = s[i:j + 1]
    try:
        js = json.loads(s)
    except ValueError:
        return None, None, True, False
    if not isinstance(js, dict):
        return None, None, True, False

    def field(v):
        if isinstance(v, bool):
            return None
        if isinstance(v, str):
            return v.strip() or None
        if isinstance(v, (int, float)):
            return str(int(v))
        return None
    year = field(js.get("year"))
    m = field(js.get("month"))
    month = None
    if m is not None:
        t = m.strip()
        if t[:2].isdigit() and 1 <= int(t[:2]) <= 12:
            month = int(t[:2])
        elif t.isdigit() and 1 <= int(t) <= 12:
            month = int(t)
        else:
            names = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                     "october", "november", "december"]
            month = next((k + 1 for k, n in enumerate(names) if n in t.lower()), "other")
    du = js.get("date_uncertain") is True
    return year, month, du, True


MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
               "November", "December"]


def doc_text(prompt):
    """The document text inside a rendered prompt (between its first two --- lines)."""
    head = "Here is the OCR text of a document:\n---\n"
    i = prompt.index(head) + len(head)
    return prompt[i:prompt.index("\n---\n\nNearby documents", i)]


def month_named(text, m):
    """The month's name, or its three-letter abbreviation, stands as a word in the text (case-insensitive). Numeric
    dates (3/15/68) are not looked for, and "May" also matches the verb."""
    name = MONTH_NAMES[m - 1]
    return re.search(rf"\b({name}|{name[:3]}\.?)\b", text, re.I) is not None


def pct(a, b):
    return f"{100 * a / b:.1f}% ({a}/{b})" if b else "–"


def metrics(rows, usd, model):
    """The figures ArchiveOCRBench reads, for one model's rows."""
    n = len(rows)
    yr = [r for r in rows if r["class"] != "decade"]
    dec = [r for r in rows if r["class"] == "decade"]
    ym = [r for r in rows if r["class"] == "year+month"]
    dated = [r for r in rows if r["class"] in ("year+month", "year")]
    du_rows = [r for r in rows if r["class"] == "year+DU"]
    def frac(rs, f):
        return [sum(1 for r in rs if f(r)), len(rs)]
    within1 = lambda r: r["y"] is not None and abs(r["y"] - r["truth"]["year"]) <= 1
    out = {"model": model, "documents": n, "usd": round(usd, 2), "usd_per_1000": round(1000 * usd / n, 2) if n else None,
           "year": {cls: {"exact": frac(rs, lambda r: r["y"] == r["truth"]["year"]), "within1": frac(rs, within1)}
                    for cls, rs in [(c, [r for r in yr if r["class"] == c]) for c in ("year+month", "year", "year+DU")]
                    + [("in text", [r for r in yr if r["year_in_text"]]), ("not in text", [r for r in yr if not r["year_in_text"]]),
                       ("all", yr)]},
           "decade": frac(dec, lambda r: r["y"] is not None and r["truth"]["decade"] <= r["y"] < r["truth"]["decade"] + 10),
           "month": {"owner": frac(ym, lambda r: r["m"] == r["truth"]["month"]),
                     "other": frac(ym, lambda r: r["m"] is not None and r["m"] != r["truth"]["month"]),
                     "none": frac(ym, lambda r: r["m"] is None),
                     "untagged_given": frac([r for r in rows if r["class"] == "year"], lambda r: r["m"] is not None),
                     "untagged_given_named": sum(r["m_named"] for r in rows if r["class"] == "year" and r["m"] is not None)},
           "uncertain": {"owner_certain": frac(dated, lambda r: r["du_pred"]),
                         "owner_certain_in_text": frac([r for r in dated if r["year_in_text"]], lambda r: r["du_pred"]),
                         "owner_certain_not_in_text": frac([r for r in dated if not r["year_in_text"]], lambda r: r["du_pred"]),
                         "owner_uncertain": frac(du_rows, lambda r: r["du_pred"]),
                         "certain_and_wrong": frac(dated, lambda r: not r["du_pred"] and r["y"] != r["truth"]["year"])},
           "parse_failures": sum(not r["parsed"] for r in rows)}
    return out


def pool_weighted(rows, summary):
    """The year-tagged strata's exact and within-one rates, weighted by each stratum's agreed count in the pool."""
    weights = {cls: summary.get("agreed " + cls, 0) for cls in ("year+month", "year", "year+DU")}
    out = {"weights": weights}
    for m, hit in (("exact", lambda r: r["y"] == r["truth"]["year"]),
                   ("within1", lambda r: r["y"] is not None and abs(r["y"] - r["truth"]["year"]) <= 1)):
        num = den = 0
        for cls, w in weights.items():
            rs = [r for r in rows if r["class"] == cls]
            if rs:
                num += w * sum(map(hit, rs)) / len(rs); den += w
        out[m] = 100 * num / den if den else 0.0
    return out


def cmd_score(a):
    docs = [json.loads(l) for l in open(os.path.join(CACHE, "sample.jsonl"), encoding="utf-8")]
    summary = json.load(open(os.path.join(CACHE, "sample-summary.json")))
    rows = []
    usd = 0.0
    tokens = collections.Counter()
    for d in docs:
        p = answer_path(d["prompt"], a.label)
        if not os.path.exists(p):
            continue
        resp = json.load(open(p))
        u = resp.get("usageMetadata") or {}
        usd += cost(u) if not a.label else 0.0
        tokens["in"] += u.get("promptTokenCount", 0)
        tokens["out"] += u.get("candidatesTokenCount", 0)
        tokens["thought"] += u.get("thoughtsTokenCount", 0)
        year, month, du, ok = app_parse(resp)
        y = int(year) if year and re.fullmatch(r"\d{4}", year) else None
        t = doc_text(d["prompt"])
        rows.append({**d, "y": y, "m": month, "du_pred": du, "parsed": ok,
                     "m_named": isinstance(month, int) and month_named(t, month),
                     "owner_m_named": bool(d["truth"].get("month")) and month_named(t, d["truth"]["month"])})
    n = len(rows)
    if a.label:
        return score_open(a.label, rows)
    L = ["# Date tagging, scored against the owner's Finder tags (W41.date-tag-measure)", "",
         f"Generated by `scripts/segbench/date_tagging.py score`. The app's default tagging call, "
         f"`TagGenerator.generateTags` (the automatic mode), with its prompt verbatim and its default model "
         f"`{MODEL}`, no thinking setting (as the app sends it), on whole corpus documents. Truth is the owner's "
         "own tags on the document's first page: a year tag, a `MM Month` tag, a decade tag, `Date Uncertain`.", "",
         "Documents are runs of page photos with one identity tag set, kept only where the label-clean teacher and "
         "the tags agree on every bounding gap, so each is a real document. Sampled round-robin across collections "
         "within each truth class (seed 41). Corpus copies of the development and test boxes are left out (Stanton, "
         "RG 165, Deaver, Dean, Herrnstein, as `corpus_pairs` sets aside). The text is ABBYY's layer, not the app's "
         "own OCR; context is the three neighbouring tag-rule segments at 300 characters each, as the app builds it.",
         "", "## The documents", "",
         f"{summary.get('folders', 0)} per-document folders, {summary.get('documents', 0):,} documents, "
         f"{summary.get('documents', 0) - summary.get('not agreed', 0):,} with every bounding gap agreed.", "",
         "| truth class | agreed documents | with no text | sampled | collections | answered |",
         "|---|---:|---:|---:|---:|---:|"]
    for cls in list(PER_CLASS) + ["undated", "ambiguous"]:
        L.append(f"| {cls} | {summary.get('agreed ' + cls, 0):,} | {summary.get('agreed ' + cls + ' no text', 0)} | "
                 f"{summary.get('sampled ' + cls, 0)} | {summary.get('collections ' + cls, 0)} | "
                 f"{sum(r['class'] == cls for r in rows)} |")
    L += ["", "`undated`: no date tag at all; `ambiguous`: two year or two month tags. Neither is scored.", "",
          f"Replies the app could not parse (it then writes no year and `Date Uncertain`): "
          f"{sum(not r['parsed'] for r in rows)} of {n}. Replies with no 4-digit year: "
          f"{sum(r['y'] is None for r in rows)}.", ""]
    # Year.
    L += ["## Year", "", "| truth class | year exact | within 1 | no year in reply | owner's year in the text |",
          "|---|---:|---:|---:|---:|"]
    yr = [r for r in rows if r["class"] != "decade"]
    for cls, rs in [(c, [r for r in yr if r["class"] == c]) for c in ("year+month", "year", "year+DU")] + [("all with a year tag", yr)]:
        L.append(f"| {cls} | {pct(sum(r['y'] == r['truth']['year'] for r in rs), len(rs))} | "
                 f"{pct(sum(r['y'] is not None and abs(r['y'] - r['truth']['year']) <= 1 for r in rs), len(rs))} | "
                 f"{pct(sum(r['y'] is None for r in rs), len(rs))} | {pct(sum(r['year_in_text'] for r in rs), len(rs))} |")
    pw = pool_weighted(rows, summary)
    L.append(f"| all, weighted to the pool | {pw['exact']:.1f}% | {pw['within1']:.1f}% | – | – |")
    L += ["", "The pooled row is over the 120/80/50 sample, which does not match the pool; the weighted row weights "
          "each stratum's rate by its agreed count (" + ", ".join(f"{cls} {n:,}" for cls, n in pw["weights"].items())
          + "; W46.date-undated, measurement audit DAT-6).", "",
          "By whether the owner's year appears as a string in the text the model was sent (first 3,000 "
          "characters), all classes with a year tag:", "", "| year in text | documents | year exact | within 1 |",
          "|---|---:|---:|---:|"]
    for flag in (True, False):
        rs = [r for r in yr if r["year_in_text"] == flag]
        L.append(f"| {'yes' if flag else 'no'} | {len(rs)} | {pct(sum(r['y'] == r['truth']['year'] for r in rs), len(rs))} | "
                 f"{pct(sum(r['y'] is not None and abs(r['y'] - r['truth']['year']) <= 1 for r in rs), len(rs))} |")
    errs = [abs(r["y"] - r["truth"]["year"]) for r in yr if r["y"] is not None and r["y"] != r["truth"]["year"]]
    if errs:
        errs.sort()
        L += ["", f"Of the {len(errs)} wrong years: off by 2-5 years {sum(2 <= e <= 5 for e in errs)}, 6-20 "
              f"{sum(6 <= e <= 20 for e in errs)}, more than 20 {sum(e > 20 for e in errs)}; median "
              f"{errs[len(errs) // 2]}."]
    dec = [r for r in rows if r["class"] == "decade"]
    L += ["", f"Decade-tagged documents (the owner knew only the decade): the reply's year falls in the owner's "
          f"decade for {pct(sum(r['y'] is not None and r['truth']['decade'] <= r['y'] < r['truth']['decade'] + 10 for r in dec), len(dec))}.", ""]
    # Month.
    ym = [r for r in rows if r["class"] == "year+month"]
    L += ["## Month", "", f"Where the owner tagged a month (year+month, {len(ym)} documents):", "",
          "| reply | documents |", "|---|---:|",
          f"| the owner's month | {pct(sum(r['m'] == r['truth']['month'] for r in ym), len(ym))} |",
          f"| another month | {pct(sum(r['m'] is not None and r['m'] != r['truth']['month'] for r in ym), len(ym))} |",
          f"| no month | {pct(sum(r['m'] is None for r in ym), len(ym))} |", "",
          f"Of the {sum(r['m'] is None for r in ym)} with no month in the reply, the owner's month is named in the text "
          f"sent for {sum(r['m'] is None and r['owner_m_named'] for r in ym)}. Across all {len(ym)}, it is named "
          f"for {sum(r['owner_m_named'] for r in ym)}. \"Named\" is the full name or its three-letter "
          "abbreviation as a word; numeric dates are not looked for.", "",
          "Where the owner tagged no month, any month in the reply is one the owner did not record. The prompt "
          "allows a month only when the document states it, so some of these may be months the document states and "
          "the owner left untagged; the bench cannot tell which without reading them.", "",
          "| truth class | reply gives a month | that month named in the text | not named |", "|---|---:|---:|---:|"]
    for cls, rs in (("year", [r for r in rows if r["class"] == "year"]),
                    ("decade", [r for r in rows if r["class"] == "decade"]),
                    ("year+DU, no month tag", [r for r in rows if r["class"] == "year+DU" and r["truth"]["month"] is None])):
        g = [r for r in rs if r["m"] is not None]
        L.append(f"| {cls} | {pct(len(g), len(rs))} | {sum(r['m_named'] for r in g)} | {sum(not r['m_named'] for r in g)} |")
    # Date uncertain.
    L += ["", "## Date Uncertain", "",
          "The app writes `Date Uncertain` when the reply's `date_uncertain` is true (or the reply is unusable). "
          "The owner's tag is the truth.", "",
          "| truth class | owner's tag | reply uncertain | reply certain |", "|---|---|---:|---:|"]
    for cls in ("year+month", "year", "year+DU", "decade"):
        rs = [r for r in rows if r["class"] == cls]
        for owner in (True, False):
            s = [r for r in rs if r["truth"]["du"] == owner]
            if s:
                L.append(f"| {cls} | {'Date Uncertain' if owner else 'none'} | {sum(r['du_pred'] for r in s)} | "
                         f"{sum(not r['du_pred'] for r in s)} |")
    dated = [r for r in rows if r["class"] in ("year+month", "year")]
    du_rows = [r for r in rows if r["class"] == "year+DU"]
    L += ["", f"Agreement with the owner, year-tagged documents: {pct(sum(r['du_pred'] == r['truth']['du'] for r in dated + du_rows), len(dated + du_rows))}. "
          f"Among the owner's certain years, the reply was certain and right for "
          f"{pct(sum(not r['du_pred'] and r['y'] == r['truth']['year'] for r in dated), len(dated))}, "
          f"certain and wrong for {pct(sum(not r['du_pred'] and r['y'] != r['truth']['year'] for r in dated), len(dated))}.", "",
          "The prompt asks for `date_uncertain` when the year cannot be determined from the document itself, which "
          "is not the owner's test (the owner knows the box). By whether the owner's year is in the text sent, "
          "documents the owner tagged with a certain year (year+month and year):", "",
          "| owner's year in the text | documents | reply uncertain | year exact when certain | year exact when uncertain |",
          "|---|---:|---:|---:|---:|"]
    for flag in (True, False):
        rs = [r for r in dated if r["year_in_text"] == flag]
        c = [r for r in rs if not r["du_pred"]]
        u = [r for r in rs if r["du_pred"]]
        L.append(f"| {'yes' if flag else 'no'} | {len(rs)} | {pct(len(u), len(rs))} | "
                 f"{pct(sum(r['y'] == r['truth']['year'] for r in c), len(c))} | "
                 f"{pct(sum(r['y'] == r['truth']['year'] for r in u), len(u))} |")
    L += ["",
          "## Cost", "",
          f"{n} calls, {tokens['in']:,} input tokens, {tokens['out']:,} answer tokens, {tokens['thought']:,} thinking "
          f"tokens: ${usd:.2f} at ${PRICE_IN}/${PRICE_OUT} per million (thinking billed as output), "
          f"${1000 * usd / n if n else 0:.2f} per 1,000 documents.", ""]
    with open(RESULTS, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))

    out = metrics(rows, usd, MODEL)
    pw = pool_weighted(rows, summary)
    out["pool_weighted"] = {"exact": round(pw["exact"], 1), "within1": round(pw["within1"], 1), "weights": pw["weights"]}
    old = json.load(open(RESULTS_JSON)) if os.path.exists(RESULTS_JSON) else {}
    if old.get("open_models"):
        out["open_models"] = old["open_models"]
    with open(RESULTS_JSON, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=1)
        fh.write("\n")
    write_open_section(out)     # the score above rewrote the file without the open models and the card
    print("\n".join(L))


OPEN_HEAD = "\n## Open-weight models on FarmShare\n"
CARD_HEAD = "\n## Measurement card\n"
UNDATED_JSON = os.path.join(os.path.dirname(RESULTS), "date-undated.json")   # W46.date-undated's rerun, the floor


def score_open(label, rows):
    j = json.load(open(RESULTS_JSON))
    m = metrics(rows, 0.0, label)
    m["finish_length"] = sum(1 for r in rows if (json.load(open(answer_path(r["prompt"], label))).get("finish") == "length"))
    j.setdefault("open_models", {})[label] = m
    with open(RESULTS_JSON, "w", encoding="utf-8") as fh:
        json.dump(j, fh, indent=1)
        fh.write("\n")
    write_open_section(j)
    print(json.dumps(m, indent=1))


def card(j):
    """The report's measurement card (root CLAUDE.md), from the scored figures and W46.date-undated's rerun."""
    y = j["year"]
    strata = ", ".join(f"{c} {y[c]['exact'][1]}" for c in ("year+month", "year", "year+DU")) + f", decade {j['decade'][1]}"
    floor = "W46.date-undated has not been scored, so there is no rerun floor"
    if os.path.exists(UNDATED_JSON):
        und = json.load(open(UNDATED_JSON))
        same = und.get("rerun_same_year")
        if same and same[1]:
            floor = (f"the only measured floor is W46.date-undated's rerun (`date-undated.md`): the same year "
                     f"{100 * same[0] / same[1]:.0f}% ({same[0]}/{same[1]}) between two identical runs, on Vision text "
                     f"of undated documents with {und.get('model')}, so it is a guide, not this set's floor")
    opens = j.get("open_models", {})
    return [CARD_HEAD.strip(), "",
            "- **Truth.** The owner's own date tags on each document's first page (year, `MM Month`, decade, "
            "`Date Uncertain`). The owner knows the box, so a year he tagged may not be on the pages.",
            f"- **Selection.** Round-robin across collections within each truth class, seed {SEED}, among documents "
            "where the label-clean teacher and the tags agree on every bounding gap; the development and test boxes "
            "are left out, and undated and ambiguous documents are not scored. Never by a route's reply.",
            f"- **Comparison.** Every row is ABBYY's text layer, which is banned as an input since 2026-10-30 (no new "
            f"run takes it); the rows stay as scored. {j.get('model', MODEL)} direct and the {len(opens)} open-model "
            f"rows ran on the same {j['documents']} prompts.",
            f"- **Noise.** n per stratum: {strata} ({y['in text']['exact'][1]} with the owner's year in the text, "
            f"{y['not in text']['exact'][1]} without). No rerun of this set; {floor}. A gap inside it is a tie.",
            "- **Scope.** The rows stay as scored: the dated set was not rerun on Vision text, so these figures do not "
            "say how the app does on its own OCR.", ""]


def write_open_section(j):
    """The open models beside Gemini, then the measurement card, rewritten in place at the end of date-tagging.md."""
    with open(RESULTS, encoding="utf-8") as fh:
        text = fh.read().split(OPEN_HEAD)[0].split(CARD_HEAD)[0].rstrip("\n") + "\n"
    if not j.get("open_models"):
        with open(RESULTS, "w", encoding="utf-8") as fh:
            fh.write(text + "\n" + "\n".join(card(j)))
        return

    def f(x):
        return f"{100 * x[0] / x[1]:.1f}%" if x[1] else "–"
    L = [OPEN_HEAD.strip(), "",
         "The same 300 prompts, sent as the app's local route sends a text call (`institutional-compute/cluster_text.py`: one user "
         "message, 512 tokens, temperature 0, no reasoning switch, reasoning text stripped), to vLLM on one L40S, "
         "parsed and scored as above. `-nothink` rows were sent with thinking switched off, which the app does not "
         "do (`KNOWN_ISSUES.md`: the local route sends no reasoning switch). No money.", "",
         "| model | year exact | within 1 | year, in text | year, not in text | owner's month | no month | "
         "Date Uncertain agrees | unparsed | ran to 512 tokens |", "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    rows = [(j.get("model", MODEL) + " (the app's default)", j)] + sorted(j.get("open_models", {}).items())
    for name, m in rows:
        y = m["year"]; u = m["uncertain"]
        agree = [u["owner_certain"][1] - u["owner_certain"][0] + u["owner_uncertain"][0],
                 u["owner_certain"][1] + u["owner_uncertain"][1]]
        L.append(f"| {name} | {f(y['all']['exact'])} | {f(y['all']['within1'])} | {f(y['in text']['exact'])} | "
                 f"{f(y['not in text']['exact'])} | {f(m['month']['owner'])} | {f(m['month']['none'])} | {f(agree)} | "
                 f"{m['parse_failures']} | {m.get('finish_length', '–')} |")
    with open(RESULTS, "w", encoding="utf-8") as fh:
        fh.write(text + "\n".join(L) + "\n\n" + "\n".join(card(j)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sample")
    p = sub.add_parser("train-data"); p.add_argument("--out")
    p = sub.add_parser("run")
    p.add_argument("--limit", type=int, default=0)
    p.add_argument("--spread", action="store_true", help="with --limit, take documents spread across the sample")
    p = sub.add_parser("score"); p.add_argument("--label")
    p = sub.add_parser("export"); p.add_argument("--out", required=True)
    p = sub.add_parser("import"); p.add_argument("--answers", required=True); p.add_argument("--label", required=True)
    a = ap.parse_args()
    {"sample": cmd_sample, "train-data": cmd_train_data, "run": cmd_run, "score": cmd_score, "export": cmd_export, "import": cmd_import}[a.cmd](a)


if __name__ == "__main__":
    main()
