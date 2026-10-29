#!/usr/bin/env python3
"""W46.fix-ent-truth: the entity truth set (sender, recipient, sending place) and its scorer.

    python3 ent_truth.py select                 # the 88 letters/memos/telegrams of the 300 + the stratified additions
    python3 ent_truth.py render                 # first and last page of each as JPEG (sips, read-only on the corpus)
    python3 ent_truth.py draft --model luna     # reader A: GPT 5.6 Luna through the Stanford gateway
    python3 ent_truth.py draft --model claude   # reader B: Claude Sonnet 5 through the Stanford gateway
    python3 ent_truth.py adjudicate             # Claude Sonnet 5 rules every document the two readers disagree on
    python3 ent_truth.py build                  # CACHE/truth.jsonl (private) and segbench-results/ent-truth.md/.json

The set (G-entities.md section 5, gap audit section 4 fix 7). The 88 are the documents of the W41 date-tagging
sample whose cached Gemini 3.8 reply calls them a letter, memo, memorandum or telegram (entity_probe.py's rule); they
already carry four models' tagging replies, which W46.ent-score scores against this truth. The additions are drawn
from the same agreed document pool (`date_tagging.document_pool`, the 300 left out), seeded, spread over the
collections, into four strata G16 and G17 found hardest: handwritten, role-addressed ("Dear Mr. President", "Dear
Sir"), unsigned, and no dateline. The strata are picked by text cues and then checked by the readers, who see the
pages; the report counts each stratum as the adjudicated truth has it, not as the cue guessed.

Labels per document: sender, recipient and sending place, each a list of {name, quote, class}. The name is
normalised ("Given Surname", no titles; an organisation where no person is named; a place as "City, State" or
"City, Country"); the quote is the name as it stands in the OCR text, errors and all, or null when it is only in the
image or not written at all; the class is G18's: named, role-inferred (only a role is written; the reader knows who
held it then), correspondence-inferred (not written; inferred from the rest of the document). Plus the document's
form: correspondence or not, hand, dateline, signed, role-addressed.

Drafting and adjudication (STATE Phase 2 decision 2: drafted by models and audited, no owner pass). Two families
draft blind, each with the OCR text and the first and last page images: OpenAI's GPT 5.6 Luna and Anthropic's Claude
Sonnet 5, both on the gateway. Neither family is scored by W46.ent-score, which scores Gemini and Qwen replies, so
the truth carries no bias toward a scored model. The plan routes the audit named wait for the gateway (root
CLAUDE.md, owner 2026-10-21), and W46.gateway-models-ok is ticked, so this arm runs there. Both draft at low reasoning
effort (Sonnet 5's default thinking doubled its cost for no change in kind on the trial page). A document whose two
drafts agree on the three fields (names matched at the scorer's edit-distance-2 level, classes equal) and on whether
it is correspondence is taken as drafted, reader B's form flags standing where the other flags differ (they only
count the strata); every other document goes to Claude Sonnet 5 again, at its default reasoning, shown both drafts as readers A and B, the text
and the images, and its ruling is the truth. The adjudicator shares a family with reader B; the report says how
often it sided with each.

The scorer (`score_rows`) is G-entities.md's: exact set match with alternate spellings (G17), overlap on a shared
surname or name token (Ehrmann's fuzzy level), edit distance at most 2 on the normalised name (Hamdi), per field
precision, recall and F1 over the named truth entities; role- and correspondence-inferred truth entities are scored
apart (G18), a prediction matching one is counted there and is neither a hit nor a false positive in the main
figure; wrong-when-filled (a document where the prediction names someone and no truth entity matches) is reported
beside the null rate, since a wrong name is worse than a null; evidence validity is the share of predicted quotes
that are substrings of the OCR text, and for replies without quotes the share of predicted names found in it.

The gateway is real money on a Stanford PTA: CAP bounds this item's spend, counted from the returned token usage
at the PRICE table (an estimate: the gateway returns no cost and publishes no price). The key is read from the
Keychain into memory once by gateway_gemini.api_key, never printed or written. Texts, images, drafts and the truth
stay in the bench cache (the owner's material; the repo is public); the committed report has aggregates only.
"""
from __future__ import annotations

import argparse
import base64
import collections
import hashlib
import json
import os
import random
import re
import subprocess
import sys
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/ent-truth")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "ent-truth.md")
FIELDS = ("sender", "recipient", "sending_place")
CLASSES = ("named", "role-inferred", "correspondence-inferred")
HANDS = ("typed", "handwritten", "mixed", "printed")
FORM = ("is_correspondence", "hand", "dateline", "signed", "role_addressed")
STRATA = ("handwritten", "role-addressed", "unsigned", "no dateline")
PER_STRATUM = 18          # drawn per stratum; the readers drop what is not correspondence
SEED = 47
MAX_SIDE = 1000
TEXT_CAP = 8000
MODELS = {"luna": "gpt-5.6-luna", "claude": "claude-sonnet-5"}
# $ per million tokens (input, output incl. reasoning): ceilings, labelled estimates. Luna's is OpenRouter's catalog
# rate in ocr-panel-local.md; Sonnet 5's is taken at Sonnet's long-standing $3 / $15, above Sonnet 5.5's $2 / $10.
PRICE = {"gpt-5.6-luna": (0.20, 1.20), "claude-sonnet-5": (3.00, 15.00)}
CAP = 6.50                # the item's total, under the owner's $7 a piece of work
MAX_TOKENS = 4000

FORMATS = ("letter", "memo", "memorandum", "telegram")

PROMPT = """You are labelling correspondence metadata for a test set built from a historical archive. You get the OCR \
text of one document (it may be noisy, and handwriting may be garbled or missing in it) and images of its first and \
last page. Read the images as well as the text.

Reply with JSON only, in this form:
{"is_correspondence": true or false,
 "hand": "typed" | "handwritten" | "mixed" | "printed",
 "dateline": true or false,
 "signed": true or false,
 "role_addressed": true or false,
 "sender": [ENTITY, ...],
 "recipient": [ENTITY, ...],
 "sending_place": [ENTITY, ...]}
where ENTITY is {"name": "...", "quote": "..." or null, "class": "named" | "role-inferred" | "correspondence-inferred"}.

Definitions.
- is_correspondence: a letter, memo, telegram, note, postcard or similar sent by someone to someone.
- hand: how the body of the document is written.
- dateline: the document carries its own date (a date line, a dated heading, a telegram's date).
- signed: the sender's signature or typed name appears at the close.
- role_addressed: the recipient is addressed by role or title only ("Dear Mr. President", "Dear Sir", "To the Editor").
- sender: who sent it (the person; an organisation only where no person is given). recipient: to whom it is \
addressed (the addressees, not carbon-copy lines). sending_place: where it was sent from (the dateline's place, or \
the letterhead address), as "City, State" for the United States or "City, Country" elsewhere.
- name: normalised. A person as "Given Surname" (initials as written, no titles such as Mr., Dr., Hon., Senator); an \
organisation by its name; a place as above. Correct obvious OCR errors in the name.
- quote: the name exactly as it stands in the OCR text, copied character for character with its errors, so that it \
is a substring of the text. null when the name is not in the OCR text (only legible in an image, or not written).
- class: "named" when the document writes the name (in the text or legibly in an image); "role-inferred" when only \
a role is written and you know who held it at the document's date; "correspondence-inferred" when it is not \
written and you infer it from the rest of the document.
- Do not guess. An empty list when the document does not say and you cannot infer it with confidence. For a \
document that is not correspondence, give the form fields and empty lists.

OCR text:
---
{text}
---"""

ADJUDICATE = """Two readers labelled the same document independently, following the instructions below, and \
disagreed somewhere. Rule on every field: take reader A's answer, reader B's, or your own where both are wrong. \
Check names against the images and the quotes against the OCR text. Reply with the same JSON form and one more \
key, "basis": a short phrase saying what decided the disputed fields.

Reader A:
{a}

Reader B:
{b}

The instructions both readers had:
"""


# --- the scorer ---------------------------------------------------------------------------------

TITLES = {"mr", "mrs", "ms", "miss", "dr", "hon", "honorable", "honourable", "rev", "reverend", "sir", "prof",
          "professor", "senator", "sen", "gov", "governor", "president", "pres", "gen", "general", "col", "colonel",
          "capt", "captain", "lt", "major", "maj", "judge", "justice", "rep", "representative", "congressman",
          "secretary", "the", "dear", "esq", "jr", "sr", "ii", "iii"}


def fold(s):
    s = unicodedata.normalize("NFKD", s or "")
    return "".join(c for c in s if not unicodedata.combining(c)).lower()


def tokens(name):
    """A name's comparable tokens: folded, punctuation and titles dropped, sorted (so "Smith, John" = "John Smith")."""
    t = [re.sub(r"[^a-z0-9]", "", x) for x in re.split(r"[\s,.;:/\-]+", fold(name))]
    return tuple(sorted(x for x in t if x and x not in TITLES))


def lev(a, b, cap=3):
    if abs(len(a) - len(b)) >= cap:
        return cap
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return min(prev[-1], cap)


def match(pred, truth, level, alternates=()):
    """Does a predicted name match a truth name at level exact | overlap | ed2? alternates: other truth spellings."""
    p = tokens(pred)
    if not p:
        return False
    forms = [tokens(truth)] + [tokens(a) for a in alternates]
    forms = [f for f in forms if f]
    if level == "exact":
        return p in forms
    if level == "ed2":
        return any(lev(" ".join(p), " ".join(f)) <= 2 for f in forms)
    if level == "overlap":
        return any({x for x in p if len(x) >= 3} & {x for x in f if len(x) >= 3} for f in forms)
    raise ValueError(level)


def ent_names(v):
    """Predicted entities in any of the shapes the bench has: a string, a list of strings or of {name, quote}."""
    if v is None:
        return []
    if isinstance(v, str):
        v = v.strip()
        if not v or v.lower() in ("null", "none", "unknown", "n/a"):
            return []
        return [{"name": v, "quote": None}]
    out = []
    for e in v if isinstance(v, list) else [v]:
        if isinstance(e, str):
            out += ent_names(e)
        elif isinstance(e, dict) and isinstance(e.get("name"), str) and e["name"].strip():
            out.append({"name": e["name"].strip(), "quote": e.get("quote") if isinstance(e.get("quote"), str) else None})
    return out


def squash(s):
    return re.sub(r"\s+", " ", s or "").strip()


def in_text(name, text):
    """A predicted name counts as found in the text when every token of it of 3+ letters is a word there."""
    t = set(re.findall(r"[a-z0-9]+", fold(text)))
    toks = [x for x in tokens(name) if len(x) >= 3]
    return bool(toks) and all(x in t for x in toks)


def score_rows(rows, levels=("exact", "overlap", "ed2")):
    """rows: [{"truth": truth row, "pred": {field: value}}], value in any `ent_names` shape. Returns per field and
    level: tp, fp, fn, precision, recall, f1; plus null, wrong-when-filled, inferred and evidence counts."""
    out = {}
    for f in FIELDS:
        res = {"docs": len(rows)}
        for lv in levels:
            tp = fp = fn = inf_hit = wrong_docs = 0
            for r in rows:
                truth = r["truth"].get(f) or []
                named = [e for e in truth if e.get("class") == "named"]
                inferred = [e for e in truth if e.get("class") != "named"]
                pred = ent_names(r["pred"].get(f))
                used = set()
                doc_wrong = False
                for p in pred:
                    k = next((i for i, e in enumerate(named) if i not in used
                              and match(p["name"], e["name"], lv, e.get("alternates", ()))), None)
                    if k is not None:
                        used.add(k); tp += 1; continue
                    if any(match(p["name"], e["name"], lv, e.get("alternates", ())) for e in inferred):
                        inf_hit += 1; continue
                    fp += 1; doc_wrong = True
                fn += len(named) - len(used)
                wrong_docs += doc_wrong
            pr = tp / (tp + fp) if tp + fp else None
            rc = tp / (tp + fn) if tp + fn else None
            f1 = 2 * pr * rc / (pr + rc) if pr and rc else (0.0 if pr is not None and rc is not None else None)
            res[lv] = {"tp": tp, "fp": fp, "fn": fn, "precision": pr, "recall": rc, "f1": f1,
                       "inferred_matched": inf_hit, "wrong_when_filled_docs": wrong_docs}
        has_truth = [r for r in rows if r["truth"].get(f)]
        res["truth_nonempty"] = len(has_truth)
        res["null_when_truth"] = sum(not ent_names(r["pred"].get(f)) for r in has_truth)
        res["filled_when_empty"] = sum(bool(ent_names(r["pred"].get(f))) for r in rows if not r["truth"].get(f))
        q = [(p["quote"], r["text"]) for r in rows for p in ent_names(r["pred"].get(f)) if p.get("quote")]
        res["quotes"] = len(q)
        res["quotes_valid"] = sum(squash(a) in squash(t) for a, t in q)
        n = [(p["name"], r["text"]) for r in rows for p in ent_names(r["pred"].get(f))]
        res["names"] = len(n)
        res["names_in_text"] = sum(in_text(a, t) for a, t in n)
        out[f] = res
    return out


# --- drafts ---------------------------------------------------------------------------------------

def parse(raw):
    """A reader's reply as a normalised label dict, or None."""
    js = parse_json(raw)
    if js is None:
        return None
    out = {"is_correspondence": bool(js.get("is_correspondence")),
           "hand": js.get("hand") if js.get("hand") in HANDS else None,
           "dateline": bool(js.get("dateline")), "signed": bool(js.get("signed")),
           "role_addressed": bool(js.get("role_addressed"))}
    for f in FIELDS:
        ents = []
        for e in js.get(f) or []:
            if not isinstance(e, dict) or not isinstance(e.get("name"), str) or not e["name"].strip():
                continue
            q = e.get("quote")
            ents.append({"name": e["name"].strip(), "quote": q.strip() if isinstance(q, str) and q.strip() else None,
                         "class": e.get("class") if e.get("class") in CLASSES else "named"})
        out[f] = ents
    if isinstance(js.get("basis"), str):
        out["basis"] = js["basis"]
    return out


def same_field(a, b):
    """Two readers agree on a field when the entities pair one to one at the ed2 level with the same class."""
    if len(a) != len(b):
        return False
    left = list(b)
    for e in a:
        k = next((i for i, x in enumerate(left) if x["class"] == e["class"] and match(e["name"], x["name"], "ed2")), None)
        if k is None:
            return False
        left.pop(k)
    return True


def disagreements(a, b, flags=FORM):
    """The fields and form flags two drafts differ on."""
    d = [k for k in flags if a.get(k) != b.get(k)]
    return d + [f for f in FIELDS if not same_field(a[f], b[f])]


RULED = ("is_correspondence",)   # the flags a ruling is asked for; the others only count strata, and B's stands


def needs_ruling(a, b):
    return bool(disagreements(a, b, RULED))


def with_valid_quotes(label, text):
    """A label whose quotes that are not substrings of the text are set to null (the name stays)."""
    t = squash(text)
    out = dict(label)
    for f in FIELDS:
        out[f] = [{**e, "quote": e["quote"] if e["quote"] and squash(e["quote"]) in t else None} for e in label[f]]
    return out


# --- selection --------------------------------------------------------------------------------------

SALUTE = re.compile(r"(?im)^\W{0,3}(dear|my dear|gentlemen|sirs?|madam|to whom it may concern)\b")
ROLE = re.compile(r"(?im)^\W{0,3}(dear\s+(mr\.?|madam|mister|mme\.?)?\s*(president|senator|governor|editor|sir|"
                  r"secretary|chairman|professor|dean|congressman|judge)\b|dear sir|gentlemen\b|to the editor\b|"
                  r"to whom it may concern)")
MEMO = re.compile(r"(?i)\b(memorandum|telegram|western union|office memo)\b")
CLOSE = re.compile(r"(?i)\b(sincerely|yours|respectfully|cordially|regards|faithfully|affectionately|love,)")
DATE = re.compile(r"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}\b|"
                  r"\b\d{1,2}\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)|\b\d{1,2}/\d{1,2}/\d{2,4}\b")
_WORDS = None


def words():
    global _WORDS
    if _WORDS is None:
        p = "/usr/share/dict/words"
        _WORDS = set()
        if os.path.exists(p):
            with open(p) as fh:
                _WORDS = {w.strip().lower() for w in fh}
    return _WORDS


def word_ratio(text):
    toks = re.findall(r"[A-Za-z]+", text[:4000])
    return sum(t.lower() in words() for t in toks) / len(toks) if toks else 0.0


def stratum_of(text):
    """The text-cue stratum of a pool document, or None when it does not look like correspondence."""
    head, tail = text[:1500], text[-900:]
    if word_ratio(text) < 0.55:
        return "handwritten"           # garbled OCR: mostly handwriting; the readers decide if it is a letter
    if not (SALUTE.search(head) or MEMO.search(head)):
        return None
    if ROLE.search(head):
        return "role-addressed"
    if not CLOSE.search(tail):
        return "unsigned"
    if not DATE.search(text[:500]):
        return "no dateline"
    return None


def gemini_format(prompt):
    """The cached Gemini 3.8 tagging reply's `format`, lowercased, as entity_probe.py reads it ("" when none)."""
    import date_tagging as DT
    p = DT.answer_path(prompt, None)
    if not os.path.exists(p):
        return ""
    try:
        raw = "".join(x.get("text", "") for x in json.load(open(p))["candidates"][0]["content"]["parts"])
    except (KeyError, IndexError, TypeError):
        return ""
    js = parse_json(raw)
    v = js.get("format") if js else None
    return v.strip().lower() if isinstance(v, str) else ""


def parse_json(raw):
    s = (raw or "").strip()
    if s.startswith("```"):
        s = "\n".join(s.split("\n")[1:-1])
    i, j = s.find("{"), s.rfind("}")
    if i < 0 or j < i:
        return None
    try:
        js = json.loads(s[i:j + 1])
    except ValueError:
        return None
    return js if isinstance(js, dict) else None


def cmd_select(a):
    import corpus_pairs as CP
    import date_tagging as DT
    sample = [json.loads(l) for l in open(os.path.join(DT.CACHE, "sample.jsonl"), encoding="utf-8")]
    letters = {d["id"] for d in sample if gemini_format(d["prompt"]) in FORMATS}
    in_sample = {d["id"] for d in sample}
    pool, _ = DT.document_pool()
    lab = {}
    for line in open(os.path.join(CP.CACHE, "labels.jsonl"), encoding="utf-8"):
        g = json.loads(line)
        lab[(g["folder_id"], g["n"])] = g
    segs_of = {}

    def pages_of(d):
        if d["folder"] not in segs_of:
            segs_of[d["folder"]] = DT.folder_documents(d["folder"], lab)
        return segs_of[d["folder"]][d["position"]]["pages"]

    def text_of(pages):
        return "\n\n".join(DT.page_text(p) for p in pages)

    docs, extra = [], collections.defaultdict(list)
    for cls in sorted(pool):
        for d in pool[cls]:
            if d["id"] in letters:
                pg = pages_of(d)
                docs.append({"id": d["id"], "set": "sample88", "stratum": None, "collection": d["collection"],
                             "pages": pg, "text": text_of(pg), "prompt": d["prompt"]})
            elif d["id"] not in in_sample:
                pg = pages_of(d)
                st = stratum_of(text_of(pg))
                if st:
                    extra[st].append((d, pg))
    rng = random.Random(SEED)
    counts = {"sample88": len(docs)}
    for st in STRATA:
        by_col = collections.defaultdict(list)
        for d, pg in sorted(extra[st], key=lambda x: x[0]["id"]):
            by_col[d["collection"]].append((d, pg))
        cols = sorted(by_col)
        rng.shuffle(cols)
        for c in cols:
            rng.shuffle(by_col[c])
        got = []
        while len(got) < PER_STRATUM and any(by_col[c] for c in cols):
            for c in cols:
                if by_col[c] and len(got) < PER_STRATUM:
                    got.append(by_col[c].pop())
        for d, pg in got:
            docs.append({"id": d["id"], "set": "added", "stratum": st, "collection": d["collection"], "pages": pg,
                         "text": text_of(pg), "prompt": d["prompt"]})
        counts[f"candidates {st}"] = len(extra[st])
        counts[f"drawn {st}"] = len(got)
    os.makedirs(CACHE, exist_ok=True)
    with open(os.path.join(CACHE, "docs.jsonl.tmp"), "w", encoding="utf-8") as fh:
        for d in docs:
            fh.write(json.dumps(d, ensure_ascii=False) + "\n")
    os.replace(os.path.join(CACHE, "docs.jsonl.tmp"), os.path.join(CACHE, "docs.jsonl"))
    json.dump(counts, open(os.path.join(CACHE, "select-summary.json"), "w"), indent=1)
    print(json.dumps(counts, indent=1))


def load_docs():
    return [json.loads(l) for l in open(os.path.join(CACHE, "docs.jsonl"), encoding="utf-8")]


def images_of(d):
    """The first page's image, and the last page's when the document has more than one."""
    ends = [d["pages"][0]] + ([d["pages"][-1]] if len(d["pages"]) > 1 else [])
    return [os.path.join(CACHE, "pages", hashlib.sha1(p.encode()).hexdigest()[:16] + ".jpg") for p in ends], ends


def cmd_render(a):
    import corpus_survey as CS
    os.makedirs(os.path.join(CACHE, "pages"), exist_ok=True)
    n = bad = 0
    for d in load_docs():
        outs, ends = images_of(d)
        for out, page in zip(outs, ends):
            n += 1
            if not os.path.exists(out):
                subprocess.run(["sips", "-s", "format", "jpeg", "-Z", str(MAX_SIDE), os.path.join(CS.CORPUS, page),
                                "--out", out], capture_output=True, check=False)
            bad += not os.path.exists(out)
    print(f"{n} page images, {bad} not rendered")


# --- gateway calls ------------------------------------------------------------------------------------

def ledger():
    f = os.path.join(CACHE, "calls.jsonl")
    return [json.loads(x) for x in open(f)] if os.path.exists(f) else []


def spent():
    return sum(r.get("cost", 0) for r in ledger())


def cost(model, usage):
    pi, po = PRICE[model]
    return ((usage.get("prompt_tokens") or 0) * pi + (usage.get("completion_tokens") or 0) * po) / 1e6


def body(model, images, text, effort=None):
    content = [{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(
        open(p, "rb").read()).decode()}} for p in images]
    b = {"model": model, "temperature": 0, "max_tokens": MAX_TOKENS,
         "messages": [{"role": "user", "content": content + [{"type": "text", "text": text}]}]}
    if effort:
        b["reasoning_effort"] = effort
    return b


def call(stage, model, doc_id, b, dest):
    """One call, cached by destination; the ledger line is written before the reply is used."""
    import gateway_gemini as G
    if os.path.exists(dest):
        return json.load(open(dest))
    worst = cost(model, {"prompt_tokens": 12000, "completion_tokens": MAX_TOKENS})
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
    rec = {"stage": stage, "doc": doc_id, "http": r.status_code, "t": t, "wall_s": round(time.time() - t, 3),
           "model": got.get("model") or model, "usage": usage, "cost": round(cost(model, usage), 6)}
    with open(os.path.join(CACHE, "calls.jsonl"), "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    choice = (got.get("choices") or [{}])[0]
    out = {"meta": {**rec, "finish": choice.get("finish_reason")},
           "raw": (choice.get("message") or {}).get("content") if r.status_code == 200 else None}
    if r.status_code == 200:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        json.dump(out, open(dest, "w"), ensure_ascii=False, indent=1)
    else:
        print(doc_id, r.status_code, json.dumps(got)[:300])
    return out


def draft_path(key, doc_id):
    return os.path.join(CACHE, "drafts", key, doc_id + ".json")


def prompt_for(d):
    return PROMPT.replace("{text}", d["text"][:TEXT_CAP])


def cmd_draft(a):
    model = MODELS[a.model]
    docs = load_docs()[: a.limit or None]

    def one(d):
        imgs = [p for p in images_of(d)[0] if os.path.exists(p)]
        return d["id"], call("draft", model, d["id"], body(model, imgs, prompt_for(d), "low"),
                            draft_path(a.model, d["id"]))
    with ThreadPoolExecutor(4) as ex:
        res = list(ex.map(one, docs))
    bad = [i for i, r in res if not parse(r.get("raw"))]
    print(f"{a.model}: {len(res) - len(bad)}/{len(res)} parsed, ${spent():.4f} spent in all; unparsed: {bad}")


def drafts(d):
    out = []
    for k in ("luna", "claude"):
        p = draft_path(k, d["id"])
        out.append(parse(json.load(open(p)).get("raw")) if os.path.exists(p) else None)
    return out


def cmd_adjudicate(a):
    model = MODELS["claude"]
    todo = []
    for d in load_docs():
        x, y = drafts(d)
        if x and y and needs_ruling(x, y):
            todo.append((d, x, y))
    print(f"{len(todo)} documents to adjudicate")

    def strip(lbl):
        return json.dumps({k: v for k, v in lbl.items() if k != "basis"}, ensure_ascii=False, indent=1)

    def one(t):
        d, x, y = t
        imgs = [p for p in images_of(d)[0] if os.path.exists(p)]
        text = ADJUDICATE.format(a=strip(x), b=strip(y)) + prompt_for(d)
        return d["id"], call("adjudicate", model, d["id"], body(model, imgs, text),
                             os.path.join(CACHE, "adjudicated", d["id"] + ".json"))
    with ThreadPoolExecutor(4) as ex:
        res = list(ex.map(one, todo[: a.limit or None]))
    bad = [i for i, r in res if not parse(r.get("raw"))]
    print(f"adjudicated {len(res) - len(bad)}/{len(res)}, ${spent():.4f} spent in all; unparsed: {bad}")


# --- the truth and the report --------------------------------------------------------------------------

def side(final, x, y):
    """Which reader the ruling took on the disputed parts: A, B, both (it matches each on some), or neither."""
    dis = disagreements(x, y, RULED)
    ta = sum(k not in disagreements(final, x, RULED) for k in dis)
    tb = sum(k not in disagreements(final, y, RULED) for k in dis)
    if ta == len(dis) and tb < len(dis):
        return "A"
    if tb == len(dis) and ta < len(dis):
        return "B"
    return "mixed" if ta or tb else "neither"


def cmd_build(a):
    rows, stats = [], collections.Counter()
    sides = collections.Counter()
    disputed = collections.Counter()
    for d in load_docs():
        x, y = drafts(d)
        if not (x and y):
            stats["missing draft"] += 1
            continue
        dis = disagreements(x, y)
        for k in dis:
            disputed[k] += 1
        if not needs_ruling(x, y):
            final, how = y, "agreed"
            stats["agreed, form flags differ"] += bool(dis)
        else:
            p = os.path.join(CACHE, "adjudicated", d["id"] + ".json")
            final = parse(json.load(open(p)).get("raw")) if os.path.exists(p) else None
            if final is None:
                stats["missing ruling"] += 1
                continue
            how = "adjudicated"
            sides[side(final, x, y)] += 1
        stats[how] += 1
        final = with_valid_quotes(final, d["text"])
        final.pop("basis", None)
        rows.append({"id": d["id"], "set": d["set"], "cue_stratum": d["stratum"], "collection": d["collection"],
                     "how": how, **final, "readers": {"luna": x, "claude": y}})
    kept = [r for r in rows if r["is_correspondence"]]
    os.makedirs(CACHE, exist_ok=True)
    with open(os.path.join(CACHE, "truth.jsonl.tmp"), "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(os.path.join(CACHE, "truth.jsonl.tmp"), os.path.join(CACHE, "truth.jsonl"))
    by_id = {d["id"]: d for d in load_docs()}

    def reader_rows(key):
        return [{"truth": r, "pred": r["readers"][key], "text": by_id[r["id"]]["text"]} for r in kept]
    summary = {
        "documents": len(rows), "correspondence": len(kept), "stats": dict(stats), "sides": dict(sides),
        "disputed": dict(disputed),
        "by_set": dict(collections.Counter(r["set"] for r in kept)),
        "dropped_not_correspondence": dict(collections.Counter(r["set"] for r in rows if not r["is_correspondence"])),
        "strata_truth": {
            "handwritten": sum(r["hand"] in ("handwritten", "mixed") for r in kept),
            "role-addressed": sum(r["role_addressed"] for r in kept),
            "unsigned": sum(not r["signed"] for r in kept),
            "no dateline": sum(not r["dateline"] for r in kept)},
        "cue_hits": {st: [sum(1 for r in rows if r["cue_stratum"] == st),
                          sum(1 for r in kept if r["cue_stratum"] == st and {
                              "handwritten": r["hand"] in ("handwritten", "mixed"), "role-addressed": r["role_addressed"],
                              "unsigned": not r["signed"], "no dateline": not r["dateline"]}[st])] for st in STRATA},
        "entities": {f: {c: sum(1 for r in kept for e in r[f] if e["class"] == c) for c in CLASSES} for f in FIELDS},
        "empty": {f: sum(not r[f] for r in kept) for f in FIELDS},
        "quoted": {f: sum(1 for r in kept for e in r[f] if e["quote"]) for f in FIELDS},
        "readers_vs_truth": {k: score_rows(reader_rows(k)) for k in ("luna", "claude")},
        "spend_usd": round(spent(), 4), "calls": len(ledger()),
        "spend_by_stage": {s: round(sum(c["cost"] for c in ledger() if c["stage"] == s), 4)
                           for s in ("draft", "adjudicate")},
    }
    json.dump(summary, open(RESULTS[:-3] + ".json", "w"), indent=1)
    open(RESULTS, "w").write(report(summary))
    print(json.dumps({k: summary[k] for k in ("documents", "correspondence", "stats", "sides", "spend_usd")}))


def f3(x):
    return "–" if x is None else f"{x:.3f}"


def report(s):
    L = ["# The entity truth set (W46.fix-ent-truth)", "",
         "Generated by `scripts/segbench/ent_truth.py build`; method in its header. The labels themselves are the "
         "owner's material and stay in the bench cache (`~/Library/Caches/ArchiveSuiteRehearsal/ent-truth/"
         "truth.jsonl`); this page has counts only. W46.ent-score scores the app's extractors against it with "
         "`ent_truth.score_rows`.", "",
         "## The set", "",
         f"{s['documents']} documents drafted, {s['correspondence']} of them correspondence by the adjudicated "
         f"labels and kept for scoring: {s['by_set'].get('sample88', 0)} of the date-tagging sample's 88 letters, "
         f"memos and telegrams and {s['by_set'].get('added', 0)} stratified additions. Dropped as not "
         f"correspondence: {s['dropped_not_correspondence']}.", "",
         "| stratum (adjudicated) | documents |", "|---|---|"]
    L += [f"| {k} | {v} |" for k, v in s["strata_truth"].items()]
    L += ["", "How well the text cues picked the strata (drawn, kept and confirmed in the stratum):", "",
          "| cue stratum | drawn | confirmed |", "|---|---|---|"]
    L += [f"| {k} | {v[0]} | {v[1]} |" for k, v in s["cue_hits"].items()]
    L += ["", "| field | named | role-inferred | correspondence-inferred | documents with none | quoted in the OCR text |",
          "|---|---|---|---|---|---|"]
    L += [f"| {f} | {e['named']} | {e['role-inferred']} | {e['correspondence-inferred']} | {s['empty'][f]} | "
          f"{s['quoted'][f]} |" for f, e in s["entities"].items()]
    st = s["stats"]
    L += ["", "## Drafting and adjudication", "",
          f"Two readers drafted every document blind (A: GPT 5.6 Luna, B: Claude Sonnet 5, both through the "
          f"Stanford gateway, temperature 0, low reasoning effort, OCR text and first and last page images). They agreed on the three fields "
          f"and on whether it is correspondence for {st.get('agreed', 0)} documents (B's hand, dateline, signed and role flags standing on the "
          f"{st.get('agreed, form flags differ', 0)} of them where those differed); Claude Sonnet 5 ruled the other {st.get('adjudicated', 0)}, siding "
          f"with A on {s['sides'].get('A', 0)}, with B on {s['sides'].get('B', 0)}, partly with each on "
          f"{s['sides'].get('mixed', 0)} and with neither on {s['sides'].get('neither', 0)}. The adjudicator shares "
          f"B's family, so B's figures below lean its way on the disputed documents.", "",
          "Disputed fields and flags (documents): " + ", ".join(f"{k} {v}" for k, v in
                                                                 sorted(s["disputed"].items(), key=lambda x: -x[1])) + ".",
          "", f"Spend: ${s['spend_usd']:.2f} estimated over {s['calls']} gateway calls (drafts "
          f"${s['spend_by_stage']['draft']:.2f}, adjudication ${s['spend_by_stage']['adjudicate']:.2f}), at "
          f"ceiling prices (Luna $0.20 / $1.20, Sonnet 5 $3 / $15 a million tokens); the gateway returns no cost.", "",
          "## Each reader against the truth (the scorer's self-check)", "",
          "Named truth entities; a reader's own draft is part of how the truth was made, so these are agreement "
          "figures, an upper bound, not accuracy.", "",
          "| reader | field | exact F1 | overlap F1 | ed2 F1 | null when truth | wrong-when-filled docs (ed2) | quotes valid |",
          "|---|---|---|---|---|---|---|---|"]
    for k, res in s["readers_vs_truth"].items():
        for f, r in res.items():
            L.append(f"| {k} | {f} | {f3(r['exact']['f1'])} | {f3(r['overlap']['f1'])} | {f3(r['ed2']['f1'])} | "
                     f"{r['null_when_truth']}/{r['truth_nonempty']} | {r['ed2']['wrong_when_filled_docs']} | "
                     f"{r['quotes_valid']}/{r['quotes']} |")
    L += ["", "## Limits", "",
          "- Model-drafted and model-adjudicated (STATE Phase 2 decision 2); no owner pass. The session that built it "
          "spot-checked a sample against the page images (W46.fix-ent-truth's DONE entry).",
          "- Only the first and last page images were shown; a name only legible on a middle page is missed.",
          "- The additions come from the agreed, year-tagged pool with ABBYY text, as the 300 did: undated documents "
          "and documents without text are not in it.",
          "- The cached tagging replies W46.ent-score reads cover the 88 only; the additions need fresh replies.", ""]
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("select").set_defaults(fn=cmd_select)
    sub.add_parser("render").set_defaults(fn=cmd_render)
    p = sub.add_parser("draft"); p.add_argument("--model", choices=sorted(MODELS), required=True)
    p.add_argument("--limit", type=int); p.set_defaults(fn=cmd_draft)
    p = sub.add_parser("adjudicate"); p.add_argument("--limit", type=int); p.set_defaults(fn=cmd_adjudicate)
    sub.add_parser("build").set_defaults(fn=cmd_build)
    a = ap.parse_args()
    os.chdir(HERE)
    a.fn(a)


if __name__ == "__main__":
    main()
