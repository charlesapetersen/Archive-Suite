#!/usr/bin/env python3
"""W47.item-fields-retruth-score: fold the owner's item-field sheet into W47.item-fields-retruth's truth, measure the
truth's own error, score every route, and give each field's fill verdict (measurement audit 2026-10-30, FLD-1, 2, 6,
7, 8; measurement review pass 10, P10-1).

    python3 item_fields_score.py      # CACHE/truth-owner.jsonl and CACHE/note-answers.md (private), the report

Offline and $0: every reading it scores is already in the bench cache. It reads the corpus's Finder tags with
getxattr(2) (corpus_survey.read_tags), nothing else there, and writes nothing in it.

The fold. The sheet's answers (sheet/answers.json against sheet/key.json): a kind answer is the owner's kind; a
dispute answer is the reading he picked (Gemini 3.7's or Luna's value); a control confirms the truth's value; "?" and
an unanswered question change nothing. The owner's notes (`_notes/<doc>`) were read one by one by the scoring session
and turned into sheet/note-fixes.json: `set` a value a note states plainly, `drop` a field it leaves unsettled (two
pieces in one document, a name only inference gives, a value he questions), which then leaves every score. A kind the
owner changed across the correspondence line (item_fields.by_definition) leaves the printed-piece fields the old kind
forbade unknown, unless a note gives them. Dispute questions on a field out of scope for the truth's kind
("ignore" in the key) and the entity controls (W46.fix-ent-truth's, reported apart) do not enter the item truth.

The truth's error. The random agreed controls (key part "random", W47.item-fields-random-controls) are a seeded
uniform draw from the agreed in-scope pairs, so the share the owner corrected is the agreed truth's error; each is
weighted by its (part, field) stratum's size. A note that answers a control's field counts as its answer. The 30
controls drawn where Gemini 3.8 agrees are Gemini 3.8's false credit, reported apart, and are not owner-checked
evidence for Gemini 3.8's own row. Disputes measure the judge: how often its ruling (and its self-rulings) the owner
upheld.

Two truths per route. "Owner-checked": the (document, field) pairs the owner answered or a note settled, scored
against his value. "Drafted": the folded truth on every document. A drafter-family route (Gemini 3.7 and GPT 5.6
Luna's readings, Gemini 3.7's app call, Gemini 3.8, a relative of the drafter and judge) is ranked and given its fill
verdict on owner-checked pairs only, and its drafted figure, with every disputed field the owner did not check left
out (the 55 self-rulings P10-1 counts among them), is reported as agreement with the drafters. The other routes
(the local models and the extractor, which no drafter shares a family with) are judged on the drafted truth, with the
truth's measured error beside. The image-reading item-field prompt test (moved here from W47.item-fields-build) is the
drafters' own rows on owner-checked pairs: the candidate prompt is the item's PROMPT on the page images.

The fill rule (FLD-7): fill when the precision's Wilson lower bound is at least LOWER and the point at least POINT, on
at least FLOOR documents with a true value. Otherwise "too close (n)" when the floor is not met, "below the bar" when
the interval's upper bound, plus the truth error's upper bound on the drafted truth, is under POINT, and "too close"
between. A drafter-family route's owner-checked pairs lean to the hard cases (kind crossings, disputes) while its
agreement with the drafted truth leans its way, so it is "below the bar" only when both upper bounds are under POINT.

Publication date (FLD-6) is also scored against the owner's own year and month tags on each printed piece's first
page, which the Zotero export's date would carry; the app's field is the document's date, the readers' the printed
issue date. Documents with a page the drafters read sideways or upside down are scored apart. 3.8 against 3.7 is
paired on the documents 3.8 answered (base only).
"""
from __future__ import annotations

import collections
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import corpus_survey as CS  # noqa: E402
import date_tagging as DT  # noqa: E402
import ent_truth as ET  # noqa: E402
import item_fields as IF  # noqa: E402
import item_fields_retruth as IR  # noqa: E402

CACHE = IR.CACHE
SHEET = os.path.join(CACHE, "sheet")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "item-fields-score.md")
RETRUTH_JSON = IR.RESULTS.replace(".md", ".json")
FLOOR, LOWER, POINT = 40, 0.85, 0.90
FIELDS = IF.FIELDS
PRINTED = IF.PUBLISHED
LUNA_TAKEN = "luna's reading"

# (key, label, family route?) in the report's order: drafter-family rows first, as the item asks.
ROUTES = [("draft-gemini", "Gemini 3.7 Flash, item prompt on the page images (drafter A)", True),
          ("tagging", "Gemini 3.7 Flash, the app's call on Vision text", True),
          ("app-gemini-3.8-flash", "Gemini 3.8 Flash, the app's call on ABBYY text (cached)", True),
          ("draft-luna", "GPT 5.6 Luna, item prompt on the page images (drafter B)", True),
          ("app-qwen3.6-27b", "Qwen3.6 27B, the app's call on ABBYY text (cached)", False),
          ("app-qwen3-vl-8b", "Qwen3-VL 8B, the app's call on ABBYY text (cached)", False),
          ("app-qwen3.5-4b", "Qwen3.5 4B, the app's call on ABBYY text (cached)", False),
          ("extractor", "Qwen3.5 4B extractor, item prompt on ABBYY text (cached)", False)]
SHORT = {"draft-gemini": "Gemini 3.7 image prompt", "tagging": "Gemini 3.7 app call", "app-gemini-3.8-flash":
         "Gemini 3.8 app call", "draft-luna": "Luna image prompt", "app-qwen3.6-27b": "Qwen3.6 27B",
         "app-qwen3-vl-8b": "Qwen3-VL 8B", "app-qwen3.5-4b": "Qwen3.5 4B", "extractor": "Qwen3.5 4B extractor"}


# --- values ------------------------------------------------------------------------------------------------------

def norm(f, v):
    if f == "publication_date":
        return tuple(v) if v else None
    if f in IF.LISTS:
        return list(v or [])
    return v


def typed(f, t):
    """A value the owner typed ("0" on the sheet; empty is the field empty)."""
    if f == "kind":
        k = (t or "").strip().lower()
        return k if k in IF.KINDS else ("other" if k else None)
    if f in IF.LISTS:
        return IF.names(t) if t.strip() else []
    if f == "publication_date":
        return IF.date_of(t)
    return IF.clean(t)


def answer_value(k, a, row):
    """(status, value) of one answer: status "value", "cant" or None (unanswered)."""
    if a is None:
        return None, None
    if a == "?":
        return "cant", None
    f = k["field"]
    if a.startswith("="):
        return "value", typed(f, a[1:])
    src = k["options"][int(a) - 1]
    if k["part"] == "kind":
        return "value", src
    if src in ("gemini", "luna"):
        return "value", norm(f, (row["readers"][src] or {}).get(f))
    if src == "truth":
        return "value", norm(f, row[f])
    raise ValueError(f"answer {a!r} to {k}")


def allowed(kind, f):
    """Whether item_fields.by_definition lets a document of this kind have the field."""
    if kind in IF.CORRESP and f in ("byline", "publication", "publication_date"):
        return False
    return not (kind in ("letter", "telegram") and f == "title")


def same(f, a, b):
    return IF.agree(f, norm(f, a), norm(f, b))


# --- the fold ------------------------------------------------------------------------------------------------------

def load():
    rows = [json.loads(x) for x in open(os.path.join(CACHE, "truth.jsonl"), encoding="utf-8")]
    docs = IR.load_docs()
    key = json.load(open(os.path.join(SHEET, "key.json"), encoding="utf-8"))["items"]
    answers = json.load(open(os.path.join(SHEET, "answers.json"), encoding="utf-8"))
    fixes = {k: v for k, v in json.load(open(os.path.join(SHEET, "note-fixes.json"), encoding="utf-8")).items()
             if not k.startswith("_")}
    return rows, docs, key, answers, fixes


def checked_values(rows, key, answers, fixes):
    """{doc: {field: (value, how)}}: what the owner settled, how being the sheet part or "note"."""
    by = {r["id"]: r for r in rows}
    out = collections.defaultdict(dict)
    for n, k in key.items():
        if k["part"] == "entity" or k["doc"] not in by:
            continue
        src = k.get("same_as", n)
        st, v = answer_value(key[src], answers.get(src), by[k["doc"]])
        if st == "value":   # an "ignore" dispute counts only if the owner's kind brings its field in scope (fold)
            out[k["doc"]].setdefault(k["field"], (v, "ignored" if k.get("ignore") else k["part"]))
    for d, fx in fixes.items():
        for f, v in (fx.get("set") or {}).items():
            out[d][f] = (typed(f, v) if isinstance(v, str) else norm(f, v), "note")
        for f in fx.get("drop") or []:
            out[d].pop(f, None)
    return out


def fold(rows, key, answers, fixes):
    """The folded truth rows: label, owner (field -> how), unknown fields, self-ruled-unchecked, note."""
    chk = checked_values(rows, key, answers, fixes)
    notes = {k.split("/", 1)[1]: v for k, v in answers.items() if k.startswith("_notes/")}
    out = []
    for r in rows:
        c = chk.get(r["id"], {})
        kind0 = r["kind"]
        kind = c["kind"][0] if "kind" in c else kind0
        lab = IF.by_definition({**{f: norm(f, r[f]) for f in FIELDS}, "kind": kind})
        unknown = set(r.get("unknown_fields") or [])
        if kind != kind0:
            unknown |= {f for f in FIELDS if f != "kind" and allowed(kind, f) and not allowed(kind0, f)}
        ks = lambda f: IF.SCOPE[f] is None or kind in IF.SCOPE[f]  # noqa: E731
        c = {f: x for f, x in c.items() if x[1] != "ignored" or (ks(f) and allowed(kind, f))}
        for f, (v, _how) in c.items():
            if f != "kind":
                lab[f] = v
                unknown.discard(f)
        unknown |= set((fixes.get(r["id"]) or {}).get("drop") or [])
        out.append({"id": r["id"], "part": r["part"], "label": {f: lab.get(f) for f in FIELDS},
                    "owner": {f: how for f, (_v, how) in c.items() if f not in unknown},
                    "unknown": sorted(unknown), "disputed": r.get("disputed") or [],
                    "field_sides": r.get("field_sides") or {}, "kind_changed": kind != kind0,
                    "note": notes.get(r["id"])})
    return out, chk


# --- the truth's error -------------------------------------------------------------------------------------------

def wilson(k, n):
    return CS.wilson(k, n) if n else (None, None)


def truth_error(rows, key, chk):
    """Random controls: [(part, field, filled, wrong, stratum size)] for the answered ones; the open count."""
    by = {r["id"]: r for r in rows}
    got, open_ = [], 0
    for k in key.values():
        if k["part"] != "random":
            continue
        d, f = k["doc"], k["field"]
        if f not in chk.get(d, {}):
            open_ += 1
            continue
        got.append((by[d]["part"], f, bool(k["filled"]), not same(f, chk[d][f][0], by[d][f]), k["stratum_pairs"]))
    return got, open_


def error_summary(got):
    n, k = len(got), sum(x[3] for x in got)
    strata = collections.defaultdict(list)
    for part, f, _fl, wrong, size in got:
        strata[part, f].append((wrong, size))
    tot = sum(v[0][1] for v in strata.values())
    weighted = sum(v[0][1] * sum(w for w, _ in v) / len(v) for v in strata.values()) / tot if tot else None
    lo, hi = wilson(k, n)
    sub = lambda pred: [x for x in got if pred(x)]  # noqa: E731
    return {"answered": n, "wrong": k, "share": k / n if n else None, "wilson": [lo, hi], "weighted": weighted,
            "by_part": {p: [sum(x[3] for x in sub(lambda x: x[0] == p)), len(sub(lambda x: x[0] == p))]
                        for p in ("base", "clippings", "handwritten")},
            "by_filled": {"with a value": [sum(x[3] for x in sub(lambda x: x[2])), len(sub(lambda x: x[2]))],
                          "empty": [sum(x[3] for x in sub(lambda x: not x[2])), len(sub(lambda x: not x[2]))]},
            "wrong_fields": sorted(f"{x[0]} {x[1]}" for x in got if x[3])}


def sheet_measures(rows, key, answers, chk):
    by = {r["id"]: r for r in rows}
    out = {}
    ctl = [(k, chk.get(k["doc"], {}).get(k["field"])) for k in key.values() if k["part"] == "control"]
    out["g38_controls"] = [sum(1 for k, c in ctl if c and not same(k["field"], c[0], by[k["doc"]][k["field"]])),
                           sum(1 for _k, c in ctl if c)]
    kinds = [(k, chk.get(k["doc"], {}).get("kind")) for k in key.values() if k["part"] == "kind"]
    kinds = [(k, c) for k, c in kinds if c]
    out["kind_crossings"] = {"answered": len(kinds), "of": sum(k["part"] == "kind" for k in key.values()),
                             "truth_exact": sum(c[0] == by[k["doc"]]["kind"] for k, c in kinds),
                             "truth_loose": sum(IF.kind_match(c[0], by[k["doc"]]["kind"], "ed2") for k, c in kinds)}
    dis = collections.defaultdict(collections.Counter)
    for k in key.values():
        if k["part"] != "dispute" or k.get("ignore"):
            continue
        r, f = by[k["doc"]], k["field"]
        dis[f]["asked"] += 1
        c = chk.get(k["doc"], {}).get(f)
        if not c:
            continue
        v = c[0]
        dis[f]["answered"] += 1
        g, lu = norm(f, r["readers"]["gemini"].get(f)), norm(f, r["readers"]["luna"].get(f))
        sg, sl = same(f, v, g), same(f, v, lu)
        dis[f]["owner " + ("gemini" if sg and not sl else "luna" if sl and not sg else "both" if sg else "neither")] += 1
        right = same(f, v, r[f])
        dis[f]["judge right"] += right
        if r["field_sides"].get(f) == "gemini":
            dis[f]["self-ruled"] += 1
            dis[f]["self-ruled right"] += right
    out["disputes"] = {f: dict(v) for f, v in dis.items()}
    ent = collections.Counter()
    for n, k in key.items():
        if k["part"] != "entity":
            continue
        a = answers.get(n)
        if a is None or a == "?" or a.startswith("="):
            ent["open"] += 1
            continue
        ent["answered"] += 1
        took = "truth upheld" if k["options"][int(a) - 1] == "claude" else LUNA_TAKEN
        ent[took] += 1
        ent[f"{k['field']}: {took}"] += 1
        if took == LUNA_TAKEN and not k.get("luna"):
            ent[f"{k['field']}: owner says none is given"] += 1
    out["entity"] = dict(ent)
    return out


# --- routes ------------------------------------------------------------------------------------------------------

def predictions(rows, docs):
    by_doc = {d["id"]: d for d in docs}
    ids = [r["id"] for r in rows]
    rd = {r["id"]: r for r in rows}
    P = {"draft-gemini": {i: {f: norm(f, (rd[i]["readers"]["gemini"] or {}).get(f)) for f in FIELDS}
                          if rd[i]["readers"]["gemini"] else None for i in ids},
         "draft-luna": {i: {f: norm(f, (rd[i]["readers"]["luna"] or {}).get(f)) for f in FIELDS}
                        if rd[i]["readers"]["luna"] else None for i in ids},
         "tagging": {i: IR.tagging_reading(i) for i in ids}}
    for name, label in IF.APP.items():
        P["app-" + name] = {i: IF.app_reading(by_doc[i]["prompt"], label) if rd[i]["part"] == "base" else None
                            for i in ids}
    P["extractor"] = {}
    for i in ids:
        r = IF.reading(IF.EXTRACTOR, i, "extract") if rd[i]["part"] == "base" else None
        P["extractor"][i] = IF.parse(r["raw"]) if r else None
    for k in P:
        for i, v in P[k].items():
            if v:
                P[k][i] = {f: norm(f, v.get(f)) for f in FIELDS}
    return P


def pairs(route, family, pred, frows, field, which, skip):
    """[(pred, truth label)] for one field. which: owner | drafted."""
    out = []
    for t in frows:
        p = pred.get(t["id"])
        if p is None or t["id"] in skip or field in t["unknown"]:
            continue
        ks = IF.SCOPE[field]
        if ks is not None and t["label"]["kind"] not in ks:
            continue
        how = t["owner"].get(field)
        if which == "owner":
            if not how or (route == "app-gemini-3.8-flash" and how == "control"):
                continue
        elif family and field in t["disputed"] and not how:
            continue
        out.append((p, t["label"]))
    return out


def verdict(s, err_hi=0.0, agreement=None):
    """agreement: a drafter-family route's drafted-truth score. Its owner-checked pairs lean to the hard cases (kind
    crossings, disputes) and its agreement with the drafted truth leans its way, so it is below the bar only when
    both intervals are."""
    if not s["docs"]:
        return "not scored"
    if not s["pred_filled"]:
        return "never filled"
    lo, hi = wilson(s["ed2"], s["pred_filled"])
    if s["truth_filled"] >= FLOOR and lo >= LOWER and s["precision_ed2"] >= POINT:
        return "fill"
    if hi + err_hi < POINT and (agreement is None or not agreement["pred_filled"]
                                or wilson(agreement["ed2"], agreement["pred_filled"])[1] < POINT):
        return "below the bar"
    return f"too close (n {s['truth_filled']})" if s["truth_filled"] < FLOOR else "too close"


def owner_tags(docs):
    """{doc: (year, month or None)} from the owner's tags on its first page (date_tagging.truth_of); read only."""
    out = {}
    for d in docs:
        cls, t = DT.truth_of(CS.read_tags(os.path.join(CS.CORPUS, d["pages"][0])))
        if t and "year" in t:
            out[d["id"]] = (t["year"], t["month"], cls)
    return out


def tag_score(pred, frows, tags, skip):
    c = collections.Counter()
    for t in frows:
        p = pred.get(t["id"])
        if p is None or t["id"] in skip or t["label"]["kind"] not in PRINTED or t["id"] not in tags:
            continue
        y, m, _ = tags[t["id"]]
        v = p.get("publication_date")
        c["docs"] += 1
        c["filled"] += bool(v)
        c["right"] += bool(v) and v[0] == y and (m is None or v[1] == m)
    return dict(c)


def paired(P, frows, skip, which):
    """3.7's app call against 3.8's on the documents 3.8 answered: per field, both / only 3.7 / only 3.8 / neither
    right, where right is the ed2 match or both empty."""
    out = {}
    a, b = P["tagging"], P["app-gemini-3.8-flash"]
    for f in FIELDS:
        c = collections.Counter()
        for t in frows:
            if b.get(t["id"]) is None or a.get(t["id"]) is None or t["id"] in skip or f in t["unknown"]:
                continue
            ks = IF.SCOPE[f]
            if ks is not None and t["label"]["kind"] not in ks:
                continue
            how = t["owner"].get(f)
            if which == "owner" and (not how or how == "control"):
                continue
            if which == "drafted" and f in t["disputed"] and not how:
                continue
            tv = t["label"][f]

            def right(p):
                pv = p.get(f)
                if not IF.filled(f, pv):
                    return not IF.filled(f, tv)
                return IF.filled(f, tv) and IF.field_match(f, pv, tv, "ed2")
            ra, rb = right(a[t["id"]]), right(b[t["id"]])
            c["both" if ra and rb else "only 3.7" if ra else "only 3.8" if rb else "neither"] += 1
        out[f] = dict(c)
    return out


def note_answers(frows, docs, fixes, tags, P):
    """The private file answering each note that asks about the date, sender or recipient, from W46.fix-ent-truth's
    truth, the owner's date tags and the app's call on Vision text; and the counts the report gives."""
    ent = {}
    p = os.path.join(ET.CACHE, "truth.jsonl")
    if os.path.exists(p):
        ent = {e["id"]: e for e in (json.loads(x) for x in open(p, encoding="utf-8"))}
    raw = {}
    for d in docs:
        q = IR.reply_path("tagging", d["id"])
        if os.path.exists(q):
            js = ET.parse_json(DT.strip_reasoning(json.load(open(q, encoding="utf-8")).get("raw") or "")) or {}
            raw[d["id"]] = js
    nm = lambda v: "; ".join(n["name"] for n in ET.ent_names(v)) or "-"  # noqa: E731
    lines, c = ["# Notes that ask about the date, sender or recipient (private; W47.item-fields-retruth-score)", ""], \
        collections.Counter()
    for t in frows:
        fx = fixes.get(t["id"]) or {}
        if "entity or date asked" not in (fx.get("themes") or []):
            continue
        c["notes"] += 1
        e, js, tg = ent.get(t["id"]), raw.get(t["id"], {}), tags.get(t["id"])
        c["in the entity truth"] += bool(e)
        c["entity truth has a sender"] += bool(e and e.get("sender"))
        c["entity truth has a recipient"] += bool(e and e.get("recipient"))
        c["owner date tag"] += bool(tg)
        c["app call gave a year"] += bool(js.get("year"))
        c["app year matches the tag"] += bool(tg and str(js.get("year") or "") == str(tg[0]))
        c["app call gave a sender"] += bool(js.get("author_name"))
        c["app call gave a recipient"] += bool(js.get("recipient_name"))
        lines += [f"## {t['id']} ({t['part']}, {t['label']['kind']})", "", f"Note: {t['note']}", ""]
        if e:
            lines.append(f"- Entity truth (W46.fix-ent-truth): sender {nm(e.get('sender'))}; recipient "
                         f"{nm(e.get('recipient'))}; sending place {nm(e.get('sending_place'))}")
        else:
            lines.append("- Not in W46.fix-ent-truth's set: no entity truth.")
        lines.append(f"- Owner's date tags: {tg[0]}{'-%02d' % tg[1] if tg and tg[1] else ''}" if tg
                     else "- Owner's date tags: none")
        lines.append(f"- The app's call on Vision text: year {js.get('year') or '-'}, month {js.get('month') or '-'},"
                     f" day {js.get('day') or '-'}; sender {js.get('author_name') or '-'}; recipient "
                     f"{js.get('recipient_name') or '-'}; recipient place {js.get('recipient_location') or '-'}")
        lines.append("")
    with open(os.path.join(CACHE, "note-answers.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    return dict(c)


# --- build --------------------------------------------------------------------------------------------------------

def build():
    rows, docs, key, answers, fixes = load()
    notes = [k.split("/", 1)[1] for k in answers if k.startswith("_notes/")]
    missing = [d for d in notes if d not in fixes]
    if missing:
        sys.exit(f"{len(missing)} notes not read into note-fixes.json: {', '.join(missing[:5])}")
    frows, chk = fold(rows, key, answers, fixes)
    with open(os.path.join(CACHE, "truth-owner.jsonl"), "w", encoding="utf-8") as fh:
        for t in frows:
            fh.write(json.dumps(t, ensure_ascii=False) + "\n")
    got, open_ = truth_error(rows, key, chk)
    err = error_summary(got)
    err["open"] = open_
    err_hi = err["wilson"][1] or 0.0
    side = json.load(open(RETRUTH_JSON, encoding="utf-8"))["counts"]["sideways"]
    skip = {x["doc"] for x in side}
    P = predictions(rows, docs)
    tags = owner_tags(docs)
    scores, verdicts, by_part = {}, {}, {}
    for rk, _label, fam in ROUTES:
        for which in ("owner", "drafted"):
            for f in FIELDS:
                scores[f"{rk}|{which}|{f}"] = IF.score(pairs(rk, fam, P[rk], frows, f, which, skip), f)
        for f in FIELDS:
            so, sd = scores[f"{rk}|owner|{f}"], scores[f"{rk}|drafted|{f}"]
            verdicts[f"{rk}|{f}"] = verdict(so, 0.0, sd) if fam else verdict(sd, err_hi)
        for part in ("base", "clippings", "handwritten"):
            fr = [t for t in frows if t["part"] == part]
            for f in FIELDS:
                s = IF.score(pairs(rk, fam, P[rk], fr, f, "drafted", skip), f)
                if s["docs"]:
                    by_part[f"{rk}|{part}|{f}"] = [s["ed2"], s["pred_filled"]]
    side_scores = {}
    for rk, _l, fam in ROUTES:
        fr = [t for t in frows if t["id"] in skip]
        tot = [0, 0]
        for f in FIELDS:
            s = IF.score(pairs(rk, fam, P[rk], fr, f, "drafted", set()), f)
            tot[0] += s["ed2"]
            tot[1] += s["pred_filled"]
        side_scores[rk] = tot
    owner_n = {f: [sum(1 for t in frows if t["owner"].get(f) and t["id"] not in skip
                       and (IF.SCOPE[f] is None or t["label"]["kind"] in IF.SCOPE[f])),
                   sum(1 for t in frows if t["owner"].get(f) and t["id"] not in skip
                       and (IF.SCOPE[f] is None or t["label"]["kind"] in IF.SCOPE[f])
                       and IF.filled(f, t["label"][f]))] for f in FIELDS}
    themes = collections.Counter(th for fx in fixes.values() for th in fx.get("themes") or [])
    o = {"counts": {
        "documents": len(frows), "notes": len(notes), "answered": sum(1 for k, v in answers.items()
                                                                     if not k.startswith("_") and v is not None),
        "questions": len(key), "note_sets": sum(len(fx.get("set") or {}) for fx in fixes.values()),
        "note_drops": sum(len(fx.get("drop") or []) for fx in fixes.values()),
        "note_themes": dict(themes.most_common()),
        "owner_changed": {f: sum(1 for t in frows if t["owner"].get(f) and not same(
            f, t["label"][f], next(r for r in rows if r["id"] == t["id"])[f])) for f in FIELDS},
        "owner_checked": {f: sum(1 for t in frows if t["owner"].get(f)) for f in FIELDS},
        "owner_n": owner_n, "kind_changed": sum(t["kind_changed"] for t in frows),
        "sideways_docs": len(skip), "replies": {rk: sum(v is not None for v in P[rk].values()) for rk, *_ in ROUTES},
        "owner_tags_printed": sum(1 for t in frows if t["label"]["kind"] in PRINTED and t["id"] in tags),
        "printed": sum(1 for t in frows if t["label"]["kind"] in PRINTED),
        "note_answers": note_answers(frows, docs, fixes, tags, P)},
        "truth_error": err, "sheet": sheet_measures(rows, key, answers, chk), "scores": scores,
        "verdicts": verdicts, "by_part": by_part, "sideways": side_scores,
        "tags": {rk: tag_score(P[rk], frows, tags, skip) for rk, *_ in ROUTES},
        "paired": {w: paired(P, frows, skip, w) for w in ("drafted", "owner")},
        "rule": {"floor": FLOOR, "lower": LOWER, "point": POINT}}
    json.dump(o, open(RESULTS.replace(".md", ".json"), "w"), indent=1, sort_keys=True)
    open(RESULTS, "w").write(report(o))
    print(report(o))


# --- the report -----------------------------------------------------------------------------------------------------

def f2(x):
    return "-" if x is None else f"{x:.2f}"


def frac(k, n):
    if not n:
        return "-"
    lo, hi = wilson(k, n)
    return f"{k}/{n} {k / n:.2f} [{lo:.2f}, {hi:.2f}]"


def report(o):
    c, e, sh = o["counts"], o["truth_error"], o["sheet"]
    L = ["# Item fields: the owner's sheet folded in, every route scored, the fill verdict "
         "(W47.item-fields-retruth-score)", "",
         "Generated by `scripts/segbench/item_fields_score.py`; method in its header. Truth from "
         "W47.item-fields-retruth (`item-fields-retruth.md`) with the owner's answers and notes folded in; the "
         "labels, notes and readings stay in the bench cache, and this page has counts only. Offline, $0.", ""]
    L += ["## The fold", "",
          f"{c['answered']} of {c['questions']} sheet questions answered, notes on {c['notes']} documents. Every note "
          f"was read before scoring: {c['note_sets']} values set from a note and {c['note_drops']} fields dropped as "
          "unsettled (two pieces in one document, a name only inference gives, a value the owner questions); the "
          f"owner changed the kind of {c['kind_changed']} documents. Owner-checked (document, field) pairs: "
          + ", ".join(f"{f} {c['owner_checked'][f]}" for f in FIELDS) + "; of them the owner's value differs from "
          "the drafted truth on " + ", ".join(f"{f} {c['owner_changed'][f]}" for f in FIELDS) + ".", "",
          "What the notes raise, by document (a note can raise several): "
          + "; ".join(f"{k} {v}" for k, v in c["note_themes"].items()) + ". Title case is a display matter (the "
          "matcher folds case). Inference (a name from a first name or initials, a paper from its initials, a "
          "letterhead taken for a place) is left to a user-set level, which W47.item-fields-build should offer; "
          "fields that need it are dropped here rather than scored either way. Kinds outside the list (minutes, "
          "a circular, realia) and extra fields (volume and number, subtitles, subject line, cc) are not scored.", ""]
    na = c["note_answers"]
    L += ["### The notes that ask whether the date, sender or recipient were read", "",
          f"{na.get('notes', 0)} notes ask it. The sheet asked item fields only; those three are measured by "
          "W46.fix-ent-truth (sender, recipient, sending place) and the date items, and each such note is answered "
          "document by document in the cache's `note-answers.md`. In counts: "
          f"{na.get('in the entity truth', 0)} of the documents are in W46's entity truth "
          f"({na.get('entity truth has a sender', 0)} with a sender, {na.get('entity truth has a recipient', 0)} with "
          f"a recipient); {na.get('owner date tag', 0)} carry the owner's year tag. The app's call on Vision text gave "
          f"a year on {na.get('app call gave a year', 0)} ({na.get('app year matches the tag', 0)} matching the tag), "
          f"a sender on {na.get('app call gave a sender', 0)} and a recipient on "
          f"{na.get('app call gave a recipient', 0)}. So the date, sender and recipient were mostly read; they were "
          "not shown on the sheet, which is what the notes were asking about.", ""]
    w = e["weighted"]
    L += ["## The truth's own error", "",
          f"Random agreed controls: {e['answered']} answered ({e['open']} open), {e['wrong']} wrong: "
          f"{frac(e['wrong'], e['answered'])}; weighted by stratum size {f2(w)}. By part: "
          + ", ".join(f"{p} {v[0]}/{v[1]}" for p, v in e["by_part"].items()) + "; with a value "
          f"{e['by_filled']['with a value'][0]}/{e['by_filled']['with a value'][1]}, agreed empty "
          f"{e['by_filled']['empty'][0]}/{e['by_filled']['empty'][1]}"
          + (f" (wrong: {', '.join(e['wrong_fields'])})" if e["wrong_fields"] else "") + ". Too few to give by "
          "part with any precision; the interval's upper bound is what the drafted-truth verdicts allow for.", "",
          f"Gemini 3.8's false credit: of the 30 controls drawn where 3.8 agrees with the truth, "
          f"{sh['g38_controls'][1]} answered, {sh['g38_controls'][0]} wrong.", "",
          f"Kind crossings (W46's correspondence ruling): {sh['kind_crossings']['answered']} of "
          f"{sh['kind_crossings']['of']} answered; the truth's kind upheld on {sh['kind_crossings']['truth_exact']} "
          f"exactly, {sh['kind_crossings']['truth_loose']} at the Zotero item type.", "",
          "| disputed field | asked | answered | judge upheld | self-rulings upheld | owner took Gemini / Luna / both "
          "/ neither |", "|---|---|---|---|---|---|"]
    for f, v in sh["disputes"].items():
        L.append(f"| {f} | {v.get('asked', 0)} | {v.get('answered', 0)} | {v.get('judge right', 0)} | "
                 f"{v.get('self-ruled right', 0)} of {v.get('self-ruled', 0)} | {v.get('owner gemini', 0)} / "
                 f"{v.get('owner luna', 0)} / {v.get('owner both', 0)} / {v.get('owner neither', 0)} |")
    tot = collections.Counter()
    for v in sh["disputes"].values():
        tot.update(v)
    ent = sh["entity"]
    L += ["", f"Over all disputes the judge (Gemini 3.7) was upheld on {frac(tot['judge right'], tot['answered'])}, "
          f"its self-rulings on {frac(tot['self-ruled right'], tot['self-ruled'])}. The disputed fields are where "
          "the drafted truth is weakest; they are the fields a Gemini row is never scored on unless the owner "
          "answered them.", "",
          f"Entity controls (W46.fix-ent-truth's rulings Claude Sonnet made for its own draft, not item fields): "
          f"{ent.get('answered', 0)} answered, the truth upheld on {ent.get('truth upheld', 0)}, Luna's reading "
          f"taken on {ent.get(LUNA_TAKEN, 0)}. By field: "
          + "; ".join(f"{f} {ent.get(f + ': truth upheld', 0)} upheld, {ent.get(f + ': ' + LUNA_TAKEN, 0)} Luna's "
                      f"({ent.get(f + ': owner says none is given', 0)} of them none given)"
                      for f in ET.FIELDS if ent.get(f + ": truth upheld") or ent.get(f + ": " + LUNA_TAKEN))
          + ". On the sending places the owner rejected, his notes say the place is not given in the text, or is "
          "only the letterhead's, which is not always where a letter was sent from; that bears on W46.fix-ent-truth's sending place and the scores made against it "
          "(W46.ent-truth-owner-fold). It changes no item field here.", ""]
    L += ["## Owner-checked n per field", "",
          "Pairs the owner answered or a note settled, in scope for the folded kind, sideways documents out; the "
          f"fill rule needs {FLOOR} with a true value.", "", "| field | owner-checked | with a true value |",
          "|---|---|---|"]
    for f in FIELDS:
        L.append(f"| {f} | {c['owner_n'][f][0]} | {c['owner_n'][f][1]} |")
    L += ["", "## Every route, field by field", "",
          "Precision at the loose level (ed2; kind at the Zotero item type) as right / filled, with its Wilson "
          "interval, then recall (right / with a true value) and the verdict. Drafter-family rows (Gemini 3.7, 3.8 "
          "and Luna) are judged on owner-checked pairs only, their drafted-truth figure is agreement with the "
          "drafters, and they are below the bar only when that agreement is too (the owner-checked pairs lean to "
          "the hard cases, the agreement the route's way); the other rows are judged on the drafted truth, whose "
          "error is the controls' above "
          f"(upper bound {f2(e['wilson'][1])} allowed for). Replies per route: "
          + ", ".join(f"{SHORT[rk]} {c['replies'][rk]}" for rk, *_ in ROUTES) + ".", ""]
    for f in FIELDS:
        L += [f"### {f}", "", "| route | owner-checked precision | recall | drafted-truth precision | recall | "
              "verdict |", "|---|---|---|---|---|---|"]
        for rk, label, fam in ROUTES:
            so, sd = o["scores"][f"{rk}|owner|{f}"], o["scores"][f"{rk}|drafted|{f}"]
            if not so["docs"] and not sd["docs"]:
                continue
            L.append(f"| {label} | {frac(so['ed2'], so['pred_filled'])} | {so['ed2']}/{so['truth_filled']} | "
                     f"{frac(sd['ed2'], sd['pred_filled'])}{' (agreement)' if fam else ''} | "
                     f"{sd['ed2']}/{sd['truth_filled']} | {o['verdicts'][f'{rk}|{f}']} |")
        L.append("")
    L += ["## By part (drafted truth, right / filled)", "", "| route | field | base | clippings | handwritten |",
          "|---|---|---|---|---|"]
    for rk in ("draft-gemini", "tagging", "draft-luna"):
        for f in FIELDS:
            cells = [o["by_part"].get(f"{rk}|{p}|{f}") for p in ("base", "clippings", "handwritten")]
            L.append(f"| {SHORT[rk]} | {f} | " + " | ".join(f"{x[0]}/{x[1]}" if x else "-" for x in cells) + " |")
    L += ["", "## Publication date against the owner's date tags (FLD-6)", "",
          f"{c['owner_tags_printed']} of the {c['printed']} printed pieces carry the owner's year tag on their first "
          "page. Right means the same year, and the same month where he tagged one; this is the date the Zotero "
          "export's `date` would carry. The app's call returns the document's date, the image prompt the printed "
          "issue date.", "", "| route | tagged pieces | filled | right | precision |", "|---|---|---|---|---|"]
    for rk, label, _f in ROUTES:
        t = o["tags"][rk]
        if t.get("docs"):
            L.append(f"| {label} | {t['docs']} | {t.get('filled', 0)} | {t.get('right', 0)} | "
                     f"{frac(t.get('right', 0), t.get('filled', 0))} |")
    L += ["", "## Gemini 3.7 on Vision text against Gemini 3.8 on ABBYY text, paired", "",
          f"On the {c['replies']['app-gemini-3.8-flash']} documents 3.8 answered (base only); right is the ed2 match "
          "or both empty.", "", "| field | truth | both right | only 3.7 | only 3.8 | neither |", "|---|---|---|---|---|---|"]
    for wch in ("owner", "drafted"):
        for f in FIELDS:
            v = o["paired"][wch][f]
            if v:
                L.append(f"| {f} | {wch} | {v.get('both', 0)} | {v.get('only 3.7', 0)} | {v.get('only 3.8', 0)} | "
                         f"{v.get('neither', 0)} |")
    L += ["", "## Pages read sideways or upside down", "",
          f"{c['sideways_docs']} documents (listed in `item-fields-retruth.md`) are out of every figure above. On "
          "them, right / filled over all fields against the drafted truth: "
          + ", ".join(f"{SHORT[rk]} {v[0]}/{v[1]}" for rk, v in o["sideways"].items() if v[1]) + ".", ""]
    fills = sorted({k.split("|")[1] for k, v in o["verdicts"].items() if v == "fill"})
    L += ["## The verdict", ""]
    for f in FIELDS:
        vs = [(SHORT[rk], o["verdicts"][f"{rk}|{f}"]) for rk, *_ in ROUTES]
        L.append(f"- **{f}**: " + "; ".join(f"{n} {v}" for n, v in vs) + ".")
    L += ["", ("Fields that clear the rule: " + ", ".join(fills) + ".") if fills else
          "No field clears the fill rule for any route. For the drafter-family routes that is the owner-checked n "
          f"(the floor is {FLOOR} documents with a true value) as much as the precision: it is \"too close\", not "
          "\"leave empty\", and W47.item-fields-build should not take it as a measured failure.", "",
          "What the figures do show. "
          + "; ".join(f"{f}: the image prompt {frac(o['scores'][f'draft-gemini|owner|{f}']['ed2'], o['scores'][f'draft-gemini|owner|{f}']['pred_filled'])}"
                      f", the app's call {frac(o['scores'][f'tagging|owner|{f}']['ed2'], o['scores'][f'tagging|owner|{f}']['pred_filled'])}"
                      for f in FIELDS) + " (owner-checked). The image prompt (the item's prompt on the page images, "
          "the test moved here from W47.item-fields-build) is the only Gemini route that gives a title; on the "
          "other fields the two overlap within their intervals at these n. The app's call is below the bar on "
          "publication date against the printed date and against the owner's tags "
          f"({frac(o['tags']['tagging'].get('right', 0), o['tags']['tagging'].get('filled', 0))}), since it returns "
          "the document's date. The local routes and the extractor ran on ABBYY text, which the app will not use "
          "(owner, 2026-10-30), so their rows are a record rather than a candidate. Reaching the floor needs more owner-checked values, drawn at random "
          "from the image prompt's filled fields so they measure its precision directly: W47.item-fields-more-checks.",
          "",
          "## Measurement card", "",
          "- **Truth:** W47.item-fields-retruth's (Gemini 3.7 and GPT 5.6 Luna drafting, Gemini 3.7 ruling) with "
          "the owner's sheet answers and notes folded in. Its error is the random controls' above; the disputed "
          "fields are owner-checked on a seeded sample. Gemini 3.7 drafted and ruled, and 3.8 is its relative, so "
          "their rows are judged on owner-checked pairs only.",
          "- **Selection:** base by Gemini 3.8's format and ABBYY cues (inherited, FLD-3); clippings and handwritten "
          "by the owner's tags. The owner-checked pairs are the sheet's: kind crossings, a seeded sample of "
          "disputes per field, the 3.8-agreeing controls (left out of 3.8's own row) and the random controls, so "
          "they lean toward the hard cases.",
          "- **Comparison:** the image prompt and the app's call on Vision text ran on the same pages; the cached "
          "app replies and the extractor ran on ABBYY text (FLD-4), base only.",
          "- **Noise:** Wilson intervals throughout; no rerun of any route here.",
          "- **Scope:** these 299 documents and six fields; it does not settle sender, recipient or the document "
          "date (W46), nor kinds and fields outside the list.", ""]
    return "\n".join(L)


if __name__ == "__main__":
    build()
