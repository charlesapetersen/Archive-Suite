#!/usr/bin/env python3
"""W46.ent-score: what the entity fields the app extracts are worth, scored against W46.fix-ent-truth's truth.

    python3 ent_score.py nltag                    # Apple NLTagger name spans + the position rule (nltag_names.swift)
    GLINER_PY ent_score.py gliner --size small    # GLiNER2.5 small|base|multi, schema and label calls (venv below)
    python3 ent_score.py nowhere                  # replies' names found nowhere in the prompt: classify, judge, audit
    python3 ent_score.py report                   # segbench-results/ent-score.md and .json

GLINER_PY is ~/Library/Caches/ArchiveSuiteRehearsal/ent-score/gliner-venv/bin/python, a uv venv holding
`gliner2[local]` (2.1.0; the 2.5 checkpoints load through `AutoExtractor`, which picks the boundary architecture).

The extractors (gap audit section 5 item 31, G-entities.md tests 1, 5 and 8):
- The app's tagging replies already cached by W41's date-tagging sample: Gemini 3.8 Flash, Qwen3.6 27B, Qwen3.5 4B
  (both no-think) and Qwen3-VL 8B, text-only, on the tagging prompt. author_name is scored as the sender,
  recipient_name as the recipient, author_location as the sending place. They exist for the date sample's 82
  correspondence documents only; the 56 additions have none (their Gemini run is W46.ent-score-paid).
- GLiNER2.5 small (74M), base (194M) and multi (287M), on the same ABBYY text the truth readers saw (its first
  TEXT_CAP characters), two ways: the schema call (`create_schema().structure("letter")` with three described
  fields, the first instance taken) and the label call (`extract_entities` with the three fields as described
  labels). Threshold: the package default.
- Apple NLTagger (`nameType`, joined names) gives person, place and organisation spans, not roles, so a position
  rule assigns them (G-entities R1): the sender is the last person after a closing phrase, else the last person in
  the final lines, else the first organisation in the letterhead lines; the recipient is the person in the lines
  between the top and the salutation (the inside address), else the person on the salutation line; the sending
  place is the first place in the letterhead lines. The same rule over GLiNER's plain person / organisation /
  location spans is scored too, so the rule's share of the error can be told from the tagger's.

Scoring is ent_truth.score_rows unchanged (exact, overlap and edit-distance-2 F1 per field over named truth
entities, null and wrong-when-filled counts, evidence validity). The replies give a single string per field, so a
document with several truth recipients caps their recall; the report counts those documents.

Names found nowhere in the prompt (G test 8). A reply's name is "nowhere" when ent_truth.in_text fails on the
prompt the model was given. Each is first classed against the truth: it matches (ed2) a truth entity whose quote is
in the text, so the model corrected or completed a name the text has (text_corrected); it matches a truth entity not written in the text (image-only
or inferred), so the model inferred it from knowledge or context and was right; or it matches nothing, which is
doubtful (a place is looked for by its city alone, since the prompt asks for "City, State"). Every doubtful name goes to Claude Sonnet 5 through the Stanford gateway with the document's text and its
first and last page images, which classes it as ocr_garble, knowledge (right), knowledge (wrong), wrong_role or
invention; a second family, GPT 5.6 Luna, audits each one blind, and the two are reported with their agreement.
The judges share families with the truth's drafters but not with any scored model.

The gateway is real money on a Stanford PTA: CAP bounds this item's spend, counted from token usage at the PRICE
table of ent_truth (an estimate; the gateway returns no cost). Texts, images, predictions and judgements stay in
the bench cache; the committed report has aggregates only.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ent_truth as ET  # noqa: E402  (stdlib-only at import, so the GLiNER venv can load it)

CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/ent-score")
DT_CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/date-tagging")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "ent-score.md")
NLTAG_SRC = os.path.join(HERE, "nltag_names.swift")
NLTAG_BIN = os.path.join(CACHE, "nltag_names")
GLINER = {"small": "fastino/gliner2.5-small-v1", "base": "fastino/gliner2.5-base-v1",
          "multi": "fastino/gliner2.5-multi-v1"}
REPLIES = {"gemini-3.8-flash": None, "qwen3.6-27b": "qwen3.6-27b-nothink", "qwen3.5-4b": "qwen3.5-4b-nothink",
           "qwen3-vl-8b": "qwen3-vl-8b"}
REPLY_FIELD = {"sender": "author_name", "recipient": "recipient_name", "sending_place": "author_location"}
DESC = {"sender": "the person who wrote and signed the letter, or the organisation sending it if no person is named",
        "recipient": "the person or organisation the letter is addressed to",
        "sending_place": "the city or town the letter was sent from"}
JUDGES = {"claude": "claude-sonnet-5", "luna": "gpt-5.6-luna"}
CAP = 3.00                # this item's gateway spend; the owner's rule is $7 a piece of work
CLOSING = re.compile(r"\b(sincerely|faithfully|truly|cordially|respectfully|regards|yours|affectionately|"
                     r"gratefully|best wishes|as ever|love)\b", re.I)
SALUTATION = re.compile(r"^\s*(dear|my dear|gentlemen|sir|madam|to whom|mr\.? president|memorandum to|to:)", re.I)
TOP_LINES, FOOT_LINES = 10, 12


# --- inputs -------------------------------------------------------------------------------------

def truth_rows():
    """The correspondence documents of the truth, each with its doc (text, prompt, pages)."""
    docs = {d["id"]: d for d in ET.load_docs()}
    rows = [json.loads(x) for x in open(os.path.join(ET.CACHE, "truth.jsonl"), encoding="utf-8")]
    return [(r, docs[r["id"]]) for r in rows if r["is_correspondence"]]


def text_of(d):
    return d["text"][:ET.TEXT_CAP]


def reply_json(path):
    if not os.path.exists(path):
        return None
    try:
        parts = json.load(open(path))["candidates"][0]["content"]["parts"]
    except (KeyError, IndexError, TypeError, ValueError):
        return None
    s = "".join(p.get("text", "") for p in parts).strip()
    i, j = s.find("{"), s.rfind("}")
    try:
        js = json.loads(s[i:j + 1]) if 0 <= i <= j else None
    except ValueError:
        return None
    return js if isinstance(js, dict) else None


def split_names(v):
    """A reply's one string may name several people ("A and B", "A; B", "A, B"): split it, on commas only when
    every part has two or more words, and only when every part looks like a person's name (two to five capitalised
    words), so "Smith, John" and "Committee on X and Y" survive whole."""
    if not isinstance(v, str):
        return v
    parts = [x.strip() for x in re.split(r";| & | and ", v) if x.strip()]
    out = []
    for x in parts:
        c = [y.strip() for y in x.split(",") if y.strip()]
        out += c if len(c) > 1 and all(len(y.split()) >= 2 for y in c) else [x]
    personal = all(2 <= len(x.split()) <= 5 and all(w[:1].isupper() for w in x.split()) for x in out)
    return out if len(out) > 1 and personal else v    # "Committee on Admissions and Aid" stays one name


def answer_path(prompt, label):
    import date_tagging as DT
    return DT.answer_path(prompt, label)


def reply_preds():
    """{model: {doc_id: pred or None}} for the documents with a cached tagging reply (the sample's 82)."""
    out = {}
    for name, label in REPLIES.items():
        got = {}
        for r, d in truth_rows():
            if r["set"] != "sample88":
                continue
            js = reply_json(answer_path(d["prompt"], label))
            got[r["id"]] = None if js is None else {f: split_names(js.get(k)) if f != "sending_place" else js.get(k)
                                                    for f, k in REPLY_FIELD.items()}
        out[name] = got
    return out


def load_preds(name):
    p = os.path.join(CACHE, "preds", name + ".jsonl")
    if not os.path.exists(p):
        return None
    return {x["id"]: x for x in map(json.loads, open(p, encoding="utf-8"))}


def save_preds(name, recs):
    os.makedirs(os.path.join(CACHE, "preds"), exist_ok=True)
    p = os.path.join(CACHE, "preds", name + ".jsonl")
    with open(p + ".tmp", "w", encoding="utf-8") as fh:
        for x in recs:
            fh.write(json.dumps(x, ensure_ascii=False) + "\n")
    os.replace(p + ".tmp", p)


# --- the position rule over name spans ----------------------------------------------------------

def merge_spans(spans, text):
    """Join neighbouring spans of one tag separated only by initials and spaces ("John" "K." "Galbraith"), and
    places separated by a comma ("Cambridge" "Massachusetts")."""
    out = []
    for s in sorted(spans, key=lambda s: s["start"]):
        if out and out[-1]["tag"] == s["tag"]:
            gap = text[out[-1]["end"]:s["start"]]
            joins = (len(gap) <= 6 and re.fullmatch(r"[ \t]*([A-Z]\.?[ \t]*)*", gap)) or \
                (s["tag"] == "place" and re.fullmatch(r"[ \t]*,[ \t]*", gap))
            if joins:
                out[-1] = {**out[-1], "end": s["end"], "text": text[out[-1]["start"]:s["end"]]}
                continue
        out.append(dict(s))
    return out


def line_of(text, pos):
    return text.count("\n", 0, pos)


def position_rule(spans, text):
    """Person / place / organisation spans -> sender, recipient, sending place (G-entities R1)."""
    spans = merge_spans(spans, text)
    lines = text.split("\n")
    n = len(lines)
    nonblank = [i for i, x in enumerate(lines) if x.strip()]
    top = set(nonblank[:TOP_LINES])
    foot = set(nonblank[-FOOT_LINES:])
    sal = next((i for i in nonblank[:40] if SALUTATION.match(lines[i])), None)
    close = next((i for i in reversed(nonblank) if i > (sal or 0) and CLOSING.search(lines[i])
                  and len(lines[i].split()) <= 8), None)
    for s in spans:
        s["line"] = line_of(text, s["start"])
    person = [s for s in spans if s["tag"] == "person"]
    org = [s for s in spans if s["tag"] == "organization"]
    place = [s for s in spans if s["tag"] == "place"]
    sender = None
    if close is not None:
        sender = next((s for s in person if s["line"] >= close), None)
    if sender is None:
        after = [s for s in person if s["line"] in foot and (sal is None or s["line"] > sal)]
        sender = after[-1] if after else None
    if sender is None:
        sender = next((s for s in org if s["line"] in top), None)
    recipient = None
    if sal is not None:
        before = [s for s in person if s["line"] < sal and s is not sender]
        recipient = before[-1] if before else next((s for s in person if s["line"] == sal), None)
    else:
        recipient = next((s for s in person if s["line"] in top and s is not sender), None)
    where = next((s for s in place if s["line"] in top), None)
    return {"sender": sender and sender["text"], "recipient": recipient and recipient["text"],
            "sending_place": where and where["text"], "n_lines": n,
            "spans": [[x["tag"], x["text"]] for x in spans]}


NL_TAG = {"PersonalName": "person", "PlaceName": "place", "OrganizationName": "organization"}


def cmd_nltag(a):
    if not os.path.exists(NLTAG_BIN) or os.path.getmtime(NLTAG_BIN) < os.path.getmtime(NLTAG_SRC):
        os.makedirs(CACHE, exist_ok=True)
        subprocess.run(["swiftc", "-O", NLTAG_SRC, "-o", NLTAG_BIN], check=True)
    rows = truth_rows()
    inp = "".join(json.dumps({"id": r["id"], "text": text_of(d)}) + "\n" for r, d in rows)
    t = time.time()
    out = subprocess.run([NLTAG_BIN], input=inp, capture_output=True, text=True, check=True).stdout
    wall = time.time() - t
    spans = {x["id"]: x["spans"] for x in map(json.loads, out.splitlines())}
    recs = []
    for r, d in rows:
        sp = [{**s, "tag": NL_TAG[s["tag"]]} for s in spans.get(r["id"], [])]
        recs.append({"id": r["id"], "pred": position_rule(sp, text_of(d))})
    save_preds("nltagger", recs)
    json.dump({"docs": len(rows), "wall_s": round(wall, 2)}, open(os.path.join(CACHE, "preds", "nltagger.time"), "w"))
    print(f"nltagger: {len(recs)} documents, {wall:.2f} s in all")


# --- GLiNER2.5 (run with the venv's python) ------------------------------------------------------

def first_text(v):
    if isinstance(v, dict):
        return v.get("text")
    if isinstance(v, list):
        return [x.get("text") if isinstance(x, dict) else x for x in v]
    return v


def cmd_gliner(a):
    import gliner2
    m = gliner2.AutoExtractor.from_pretrained(GLINER[a.size])
    rows = truth_rows()
    out = {"schema": [], "labels": [], "spans-rule": []}
    secs = collections.Counter()
    for r, d in rows:
        text = text_of(d)
        t = time.time()
        s = m.create_schema()
        b = s.structure("letter")
        b.field("sender", dtype="list", description=DESC["sender"]) \
         .field("recipient", dtype="list", description=DESC["recipient"]) \
         .field("sending_place", dtype="str", description=DESC["sending_place"])
        inst = (m.extract(text, s).get("letter") or [{}])[0] or {}
        out["schema"].append({"id": r["id"], "pred": {f: first_text(inst.get(f)) for f in ET.FIELDS}})
        secs["schema"] += time.time() - t
        t = time.time()
        ents = m.extract_entities(text, {f.replace("_", " "): DESC[f] for f in ET.FIELDS}).get("entities", {})
        out["labels"].append({"id": r["id"], "pred": {f: ents.get(f.replace("_", " ")) or [] for f in ET.FIELDS}})
        secs["labels"] += time.time() - t
        t = time.time()
        sp = m.extract_entities(text, ["person", "organization", "location"], include_spans=True).get("entities", {})
        spans = [{"tag": "place" if k == "location" else k, "start": e["start"], "end": e["end"], "text": e["text"]}
                 for k, v in sp.items() for e in v if isinstance(e, dict) and "start" in e]
        out["spans-rule"].append({"id": r["id"], "pred": position_rule(spans, text)})
        secs["spans-rule"] += time.time() - t
    for mode, recs in out.items():
        save_preds(f"gliner2.5-{a.size}-{mode}", recs)
        json.dump({"docs": len(rows), "wall_s": round(secs[mode], 2)},
                  open(os.path.join(CACHE, "preds", f"gliner2.5-{a.size}-{mode}.time"), "w"))
    print(f"gliner2.5-{a.size}: {len(rows)} documents;", {k: round(v, 1) for k, v in secs.items()}, "s")


# --- names found nowhere in the prompt (G test 8) ------------------------------------------------

JUDGE = """A model read the OCR text below (it may be noisy; handwriting may be garbled or missing in it) and named \
"{name}" as the document's {role}. That name is not in the OCR text. Using the page images and the text, say what \
it is. Reply with JSON only: {{"class": CLASS, "reason": "one short sentence"}}, where CLASS is one of:
- "ocr_garble": the name is written on the page (legible in an image, or garbled in the text) and it is the {role}.
- "knowledge_right": the name is not written as such, but it is a correct inference of the {role} (a full name for \
initials, a nickname or a role, the person who held an office at the time, the letterhead's organisation).
- "knowledge_wrong": an inference from knowledge or context that is wrong or unsupported by the document.
- "wrong_role": the name, or a form of it, is on the page, but it is not the {role}.
- "invention": it is not on the page and nothing in the document supports it.

OCR text:
---
{text}
---"""
ROLE = {"sender": "sender (who wrote and sent it)", "recipient": "recipient (to whom it is addressed)",
        "sending_place": "sending place (where it was sent from)"}
NOWHERE_CLASSES = ("ocr_garble", "knowledge_right", "knowledge_wrong", "wrong_role", "invention")


def ledger():
    f = os.path.join(CACHE, "calls.jsonl")
    return [json.loads(x) for x in open(f)] if os.path.exists(f) else []


def spent():
    return sum(r.get("cost", 0) for r in ledger())


def call(model, key, b, dest):
    """One gateway call, cached by destination; the ledger line is written before the reply is used."""
    import gateway_gemini as G
    if os.path.exists(dest):
        return json.load(open(dest))
    if spent() + ET.cost(model, {"prompt_tokens": 12000, "completion_tokens": ET.MAX_TOKENS}) > CAP:
        raise SystemExit(f"cap: ${spent():.4f} spent of ${CAP}")
    t = time.time()
    for attempt in range(3):
        r = G.request("/chat/completions", b)
        if r.status_code in (429, 500, 502, 503, 504) and attempt < 2:
            time.sleep(10 * (attempt + 1)); continue
        break
    got = r.json() if r.headers.get("content-type", "").startswith("application/json") else {"raw": r.text[:2000]}
    usage = got.get("usage") or {}
    rec = {"stage": "judge", "key": key, "http": r.status_code, "t": t, "model": got.get("model") or model,
           "usage": usage, "cost": round(ET.cost(model, usage), 6)}
    with open(os.path.join(CACHE, "calls.jsonl"), "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    choice = (got.get("choices") or [{}])[0]
    out = {"meta": rec, "raw": (choice.get("message") or {}).get("content") if r.status_code == 200 else None}
    if r.status_code == 200:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        json.dump(out, open(dest, "w"), ensure_ascii=False, indent=1)
    else:
        print(key, r.status_code, json.dumps(got)[:300])
    return out


def nowhere_names():
    """Every reply name not found in its prompt, classed against the truth where the truth settles it."""
    rows = {r["id"]: (r, d) for r, d in truth_rows()}
    out = []
    for model, got in reply_preds().items():
        for i, p in got.items():
            if not p:
                continue
            r, d = rows[i]
            for f in ET.FIELDS:
                for e in ET.ent_names(p.get(f)):
                    core = e["name"].split(",")[0] if f == "sending_place" else e["name"]
                    if ET.in_text(core, d["prompt"]):
                        continue          # a place counts by its city: an added state or country is normalising
                    hit = next((t for t in r[f] if ET.match(e["name"], t["name"], "ed2", t.get("alternates", ()))),
                               None)
                    if hit is None:
                        how = None
                    elif hit.get("quote"):
                        how = "text_corrected"
                    else:
                        how = "knowledge_right"
                    out.append({"model": model, "id": i, "field": f, "name": e["name"], "by_truth": how})
    return out


def judge_path(judge, n):
    h = __import__("hashlib").sha1(json.dumps([n["id"], n["field"], n["name"]]).encode()).hexdigest()[:16]
    return os.path.join(CACHE, "judged", judge, h + ".json")


def judged(judge, n):
    p = judge_path(judge, n)
    if not os.path.exists(p):
        return None
    js = ET.parse_json(json.load(open(p)).get("raw"))
    c = js.get("class") if isinstance(js, dict) else None
    return c if c in NOWHERE_CLASSES else None


def cmd_nowhere(a):
    from concurrent.futures import ThreadPoolExecutor
    rows = {r["id"]: (r, d) for r, d in truth_rows()}
    names = nowhere_names()
    todo = {(n["id"], n["field"], n["name"]): n for n in names if n["by_truth"] is None}
    jobs = [(j, n) for j in JUDGES for n in todo.values()]

    def one(job):
        j, n = job
        d = rows[n["id"]][1]
        imgs = [p for p in ET.images_of(d)[0] if os.path.exists(p)]
        text = JUDGE.format(name=n["name"], role=ROLE[n["field"]], text=text_of(d))
        return call(JUDGES[j], n["id"], ET.body(JUDGES[j], imgs, text, "low"), judge_path(j, n))
    with ThreadPoolExecutor(4) as ex:
        list(ex.map(one, jobs))
    bad = [(j, n["name"]) for j, n in jobs if judged(j, n) is None]
    print(f"{len(names)} nowhere names, {len(todo)} doubtful; {len(jobs) - len(bad)}/{len(jobs)} judged; "
          f"${spent():.4f} spent; unparsed {bad}")


# --- the report ---------------------------------------------------------------------------------

LOCAL = ["nltagger"] + [f"gliner2.5-{s}-{m}" for s in ("small", "base", "multi")
                        for m in ("schema", "labels", "spans-rule")]


def scored(preds, rows):
    rs = [{"truth": r, "pred": (preds.get(r["id"]) or {}), "text": d["text"]} for r, d in rows if r["id"] in preds]
    return ET.score_rows(rs), len(rs)


def city(name):
    return name.split(",")[0].strip()


def span_ceiling(preds, rows):
    """How many named truth entities a perfect position rule could have found: matched (ed2) by any span of the
    tagger's (a person or organisation for sender and recipient; a place, by its city, for the sending place)."""
    out = {}
    for f in ET.FIELDS:
        want = ("place",) if f == "sending_place" else ("person", "organization")
        hit = tot = 0
        for r, _ in rows:
            sp = [t for tag, t in (preds.get(r["id"]) or {}).get("spans", []) if tag in want]
            for e in r[f]:
                if e["class"] != "named":
                    continue
                tot += 1
                name = city(e["name"]) if f == "sending_place" else e["name"]
                hit += any(ET.match(t, name, "ed2", e.get("alternates", ())) for t in sp)
        out[f] = [hit, tot]
    return out


def cmd_report(a):
    rows = truth_rows()
    s88 = [(r, d) for r, d in rows if r["set"] == "sample88"]
    ext = {m: dict(got) for m, got in reply_preds().items()}
    secs = {}
    for name in LOCAL:
        p = load_preds(name)
        if p is None:
            continue
        ext[name] = {i: x["pred"] for i, x in p.items()}
        secs[name] = json.load(open(os.path.join(CACHE, "preds", name + ".time")))
    out = {"documents": len(rows), "sample88": len(s88), "unparsed_replies": {
        m: sum(v is None for v in ext[m].values()) for m in REPLIES}, "scores_82": {}, "scores_138": {},
        "seconds_per_doc": {k: round(v["wall_s"] / v["docs"], 4) for k, v in secs.items()},
        "multi_recipient_docs_82": sum(sum(e["class"] == "named" for e in r["recipient"]) > 1 for r, _ in s88)}
    for m, p in ext.items():
        out["scores_82"][m] = scored(p, s88)[0]
        if m not in REPLIES:
            out["scores_138"][m] = scored(p, rows)[0]
    out["place_city_82"], out["place_city_138"], out["span_ceiling_138"] = {}, {}, {}
    for m, p in ext.items():
        cp = {i: {"sending_place": [city(n["name"]) for n in ET.ent_names((v or {}).get("sending_place"))]}
              for i, v in p.items()}
        ct = [({**r, "sending_place": [{**e, "name": city(e["name"])} for e in r["sending_place"]]}, d)
              for r, d in rows]
        x = scored(cp, [t for t in ct if t[0]["set"] == "sample88"])[0]["sending_place"]["ed2"]
        out["place_city_82"][m] = x["f1"]
        if m not in REPLIES:
            out["place_city_138"][m] = scored(cp, ct)[0]["sending_place"]["ed2"]["f1"]
        if m.endswith("spans-rule") or m == "nltagger":
            out["span_ceiling_138"][m] = span_ceiling(p, rows)
    strata = {"handwritten or mixed hand": lambda r: r["hand"] in ("handwritten", "mixed"),
              "role-addressed": lambda r: r["role_addressed"], "unsigned": lambda r: not r["signed"],
              "typed, signed, addressed by name": lambda r: r["hand"] in ("typed", "printed") and r["signed"]
              and not r["role_addressed"]}
    out["strata"] = {}
    for st, keep in strata.items():
        sub88 = [(r, d) for r, d in s88 if keep(r)]
        sub = [(r, d) for r, d in rows if keep(r)]
        out["strata"][st] = {"docs_82": len(sub88), "docs_138": len(sub), "ed2_f1": {
            m: {f: scored(p, sub88 if m in REPLIES else sub)[0][f]["ed2"]["f1"] for f in ET.FIELDS}
            for m, p in ext.items()}}
    names = nowhere_names()
    rows_by_id = {r["id"]: r for r, _ in rows}
    tab = collections.defaultdict(collections.Counter)
    agree = collections.Counter()
    for n in names:
        if n["by_truth"]:
            tab[n["model"]]["truth: " + n["by_truth"]] += 1
            continue
        c, l = judged("claude", n), judged("luna", n)
        tab[n["model"]]["judged: " + (c or "unjudged")] += 1
        truth = [e for e in rows_by_id[n["id"]][n["field"]] if e["class"] == "named"]
        if c in ("ocr_garble", "knowledge_right") and truth and not any(
                ET.match(n["name"], e["name"], "overlap", e.get("alternates", ())) for e in truth):
            tab[n["model"]]["judged right, truth disagrees"] += 1
        if c and l:
            agree["agree" if c == l else "disagree"] += 1
            if c != l:
                tab[n["model"]]["auditor disagrees"] += 1
    out["nowhere"] = {"by_model": {m: dict(v) for m, v in tab.items()},
                      "totals": {m: sum(1 for n in names if n["model"] == m) for m in REPLIES},
                      "judge_agreement": dict(agree),
                      "disagreements": dict(collections.Counter(
                          f"{judged('claude', n)} / {judged('luna', n)}" for n in
                          {(n["id"], n["field"], n["name"]): n for n in names if not n["by_truth"]}.values()
                          if judged("claude", n) != judged("luna", n)))}
    out["spend_usd"] = round(spent(), 4)
    out["calls"] = len(ledger())
    json.dump(out, open(RESULTS[:-3] + ".json", "w"), indent=1)
    open(RESULTS, "w").write(report(out))
    print(open(RESULTS).read())


def f3(x):
    return "–" if x is None else f"{x:.3f}"


def score_table(scores):
    L = ["| extractor | field | exact F1 | overlap F1 | ed2 F1 | null when truth | wrong-when-filled docs (ed2) "
         "| names in the text |", "|---|---|---|---|---|---|---|---|"]
    for m, s in scores.items():
        for f in ET.FIELDS:
            x = s[f]
            L.append(f"| {m} | {f} | {f3(x['exact']['f1'])} | {f3(x['overlap']['f1'])} | {f3(x['ed2']['f1'])} "
                     f"| {x['null_when_truth']}/{x['truth_nonempty']} | {x['ed2']['wrong_when_filled_docs']} "
                     f"| {x['names_in_text']}/{x['names']} |")
    return L


def report(s):
    L = ["# What the entity fields are worth (W46.ent-score)", "",
         "Generated by `scripts/segbench/ent_score.py report`; method in its header. Truth: W46.fix-ent-truth's "
         f"{s['documents']} correspondence documents (`ent-truth.md`), scored with its `score_rows`. Figures are over "
         "named truth entities; a prediction matching a role- or correspondence-inferred truth entity is neither a "
         "hit nor a false positive.", "",
         f"## The app's tagging replies and the local extractors, on the {s['sample88']} documents with cached replies",
         "", "The replies are text-only answers to the app's tagging prompt (author_name, recipient_name, "
         "author_location). Unparsed replies: " + ", ".join(f"{m} {n}" for m, n in s["unparsed_replies"].items())
         + f". {s['multi_recipient_docs_82']} of the documents have more than one named recipient.", ""]
    L += score_table(s["scores_82"])
    L += ["", f"## The local extractors on all {s['documents']} documents", ""]
    L += score_table(s["scores_138"])
    L += ["", "Seconds a document on this Mac (M3 Pro, CPU; GLiNER through PyTorch, NLTagger compiled Swift):", "",
          "| extractor | s/doc |", "|---|---|"]
    L += [f"| {k} | {v:.3f} |" for k, v in s["seconds_per_doc"].items()]
    L += ["", "The ed2 level compares the whole normalised place, so \"Cambridge\" misses \"Cambridge, "
          "Massachusetts\"; overlap passes any shared word, \"California\" included. The city alone, at ed2 "
          "(truth and prediction cut at the first comma):", "",
          "| extractor | city ed2 F1 (82) | city ed2 F1 (138) |", "|---|---|---|"]
    L += [f"| {m} | {f3(v)} | {f3(s['place_city_138'].get(m))} |" for m, v in s["place_city_82"].items()]
    L += ["", "How much a better position rule could buy: named truth entities matched (ed2) by any of the "
          "tagger's spans, over all 138 (a person or organisation span for sender and recipient, a place span by "
          "its city).", "", "| tagger | sender | recipient | sending place |", "|---|---|---|---|"]
    L += [f"| {m} | " + " | ".join(f"{h}/{t}" for h, t in v.values()) + " |"
          for m, v in s["span_ceiling_138"].items()]
    L += ["", "## By kind of letter (ed2 F1: sender / recipient / place)", "",
          "| extractor | " + " | ".join(f"{k} ({v['docs_82']} / {v['docs_138']})" for k, v in s["strata"].items())
          + " |", "|---|" + "---|" * len(s["strata"])]
    for m in s["scores_82"]:
        L.append(f"| {m} | " + " | ".join(
            " / ".join(f3(v["ed2_f1"][m][f]) for f in ET.FIELDS) for v in s["strata"].values()) + " |")
    L += ["", "Document counts in the header are (with replies / all); the replies are scored on the first, the "
          "local extractors on the second.", "",
          "## Names found nowhere in the prompt", "",
          "A reply's name is counted here when some word of three or more letters in it is not in the prompt the "
          "model was given (`ent_truth.in_text`); "
          "classed by the truth where a truth entity matches it, otherwise judged with the page images by Claude "
          "Sonnet 5 and audited blind by GPT 5.6 Luna.", "",
          "| model | nowhere names | " + " | ".join(
              ["truth: text_corrected", "truth: knowledge_right"] + [f"judged: {c}" for c in NOWHERE_CLASSES]
              + ["auditor disagrees", "judged right, truth disagrees"]) + " |",
          "|---|---|" + "---|" * (len(NOWHERE_CLASSES) + 4)]
    for m in REPLIES:
        t = s["nowhere"]["by_model"].get(m, {})
        L.append(f"| {m} | {s['nowhere']['totals'][m]} | " + " | ".join(str(t.get(k, 0)) for k in (
            ["truth: text_corrected", "truth: knowledge_right"] + [f"judged: {c}" for c in NOWHERE_CLASSES]
            + ["auditor disagrees", "judged right, truth disagrees"])) + " |")
    L += ["", f"Judge agreement over the doubtful names: {s['nowhere']['judge_agreement']}; disagreements (Claude / "
          f"Luna): {s['nowhere']['disagreements']}.", "",
          f"Spend: ${s['spend_usd']:.2f} estimated over {s['calls']} gateway calls at ceiling prices.", ""]
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("nltag")
    g = sub.add_parser("gliner")
    g.add_argument("--size", choices=sorted(GLINER), required=True)
    sub.add_parser("nowhere")
    sub.add_parser("report")
    a = ap.parse_args()
    {"nltag": cmd_nltag, "gliner": cmd_gliner, "nowhere": cmd_nowhere, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    main()
