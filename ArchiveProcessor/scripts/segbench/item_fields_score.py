#!/usr/bin/env python3
"""W47.item-fields-retruth-score: fold the owner's item-field sheet into W47.item-fields-retruth's truth, measure the
truth's own error, score every route, and give each field's fill verdict (measurement audit 2026-10-30, FLD-1, 2, 6,
7, 8; measurement review pass 10, P10-1). W47.item-fields-more-score folds the later sheets too and judges the
drafter-family routes on a stratified precision (measurement review pass 11, P11-2 and P11-6).

    python3 item_fields_score.py      # CACHE/truth-owner.jsonl and CACHE/note-answers.md (private), the report

Offline and $0: every reading it scores is already in the bench cache. It reads the corpus's Finder tags with
getxattr(2) (corpus_survey.read_tags), nothing else there, and writes nothing in it.

The fold. The sheet's answers (sheet/answers.json against sheet/key.json): a kind answer is the owner's kind; a
dispute answer is the reading he picked (Gemini 3.7's or Luna's value); a control confirms the truth's value; "?" and
an unanswered question change nothing. The later sheets (sheet2, the random draw from the image prompt's readings,
W47.item-fields-more-checks; sheet3, the draw that continues it) fold the same way, each with its own key, answers,
and note-fixes.json, their question ids distinct and their notes kept apart (`note2`, `note3` on the truth row); a
typed answer the date reader cannot parse is read by hand into note-fixes' `answer`, which keeps the question's part.
The owner's notes (`_notes/<doc>`) were read one by one by the scoring session
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

The fill rule (FLD-7): fill when the precision's lower bound is at least LOWER and the point at least POINT, on at
least FLOOR documents with a true value. A drafter-family route's precision is the stratified one (`stratified`): the
pairs the owner settled other than by the draw counted exactly at their own number, the rest at theirs from the
uniform draw, so the first sheet's hard cases weigh no more than their share; its pooled owner-checked figure is shown
beside it. A route judged on the drafted truth has the truth error's upper bound taken off its lower bound for a fill
(P11-6). Otherwise "too close (n)" when the floor is not met, "below the bar" when
the interval's upper bound, plus the truth error's upper bound on the drafted truth, is under POINT, and "too close"
between.

Publication date (FLD-6) is also scored against the owner's own year and month tags on each printed piece's first
page. The two owner truths are different dates: the item field is the printed issue date, the tag the document's date,
and the app's call returns the document's date, the readers the printed issue date. W47.ct-zotero's export takes
Zotero's `issued` from the owner's or the app's date, not the item field. The image prompt's misses against the tags
are split by where his sheet stands (`tag_conflicts`), and the pieces whose sheet value differs from the tag while the
reading equals the sheet are listed. Documents with a page the drafters read sideways or upside down are scored apart.
3.8 against 3.7 is paired on the documents 3.8 answered (base only).
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
# The later sheets, each folded once its answers.json is saved: the random draw from the image prompt's readings
# (W47.item-fields-more-checks) and the third sheet that continues it for kind, title and publication
# (W47.item-fields-more-score).
SHEET2 = os.path.join(CACHE, "sheet2")
SHEET3 = os.path.join(CACHE, "sheet3")
MORE_SHEETS = [(SHEET2, "_notes2"), (SHEET3, "_notes3")]
THIRD_FIELDS = ("kind", "title", "publication")   # what the third sheet draws more of (item_fields_more.THIRD)
DRAW = "draw"
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "item-fields-score.md")
RETRUTH_JSON = IR.RESULTS.replace(".md", ".json")
FLOOR, LOWER, POINT = 40, 0.85, 0.90
FIELDS = IF.FIELDS
PRINTED = IF.PUBLISHED
LUNA_TAKEN = "luna's reading"

# (key, label, family route?) in the report's order: drafter-family rows first, as the item asks.
ROUTES = [("draft-gemini", "Gemini 3.7 Flash, item prompt on the page images (drafter A)", True),
          # the app's call as of 2026-11-05, before W46.tagging-prompt-revert took the November name rules out
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

def merge_fixes(a, b):
    """Two sheets' note fixes for one truth: per document, the second's set and answer win, drops add up."""
    out = {d: dict(v) for d, v in a.items()}
    for d, fx in b.items():
        m = out.setdefault(d, {})
        for k in ("set", "answer"):
            if fx.get(k):
                m[k] = {**(m.get(k) or {}), **fx[k]}
        for k in ("drop", "themes"):
            if fx.get(k):
                m[k] = list(m.get(k) or []) + [x for x in fx[k] if x not in (m.get(k) or [])]
    return out


def load_sheet(path, note_prefix):
    """(key, answers, fixes) of one answered sheet, its notes renamed `<note_prefix>/<doc>` so two sheets' notes on one
    document stay apart; every note must be in the sheet's own note-fixes.json."""
    key = json.load(open(os.path.join(path, "key.json"), encoding="utf-8"))["items"]
    answers = json.load(open(os.path.join(path, "answers.json"), encoding="utf-8"))
    fp = os.path.join(path, "note-fixes.json")
    fixes = {k: v for k, v in json.load(open(fp, encoding="utf-8")).items() if not k.startswith("_")} \
        if os.path.exists(fp) else {}
    notes = [k.split("/", 1)[1] for k in answers if k.startswith("_notes/")]
    missing = [d for d in notes if d not in fixes]
    if missing:
        sys.exit(f"{path}: {len(missing)} notes not read into note-fixes.json: {', '.join(missing[:5])}")
    answers = {(note_prefix + k[len("_notes"):] if k.startswith("_notes/") else k): v for k, v in answers.items()}
    return key, answers, fixes


def load(more=True):
    """The truth rows, the documents, and every answered sheet folded into one key, answers and fixes. more=False:
    the first sheet only (what W47.item-fields-more-checks drew the second sheet against)."""
    rows = [json.loads(x) for x in open(os.path.join(CACHE, "truth.jsonl"), encoding="utf-8")]
    docs = IR.load_docs()
    key, answers, fixes = load_sheet(SHEET, "_notes")
    for path, prefix in (MORE_SHEETS if more else ()):
        if not os.path.exists(os.path.join(path, "answers.json")):
            continue
        k2, a2, f2_ = load_sheet(path, prefix)
        clash = set(k2) & set(key)
        if clash:
            sys.exit(f"{path}: question ids already on an earlier sheet: {', '.join(sorted(clash)[:5])}")
        key, answers, fixes = {**key, **k2}, {**answers, **a2}, merge_fixes(fixes, f2_)
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
        for f, v in (fx.get("answer") or {}).items():   # a typed answer read by hand: the value, not how it came
            if f in out[d]:
                out[d][f] = (typed(f, v) if isinstance(v, str) else norm(f, v), out[d][f][1])
        for f, v in (fx.get("set") or {}).items():
            out[d][f] = (typed(f, v) if isinstance(v, str) else norm(f, v), "note")
        for f in fx.get("drop") or []:
            out[d].pop(f, None)
    return out


def fold(rows, key, answers, fixes):
    """The folded truth rows: label, owner (field -> how), unknown fields, self-ruled-unchecked, note."""
    chk = checked_values(rows, key, answers, fixes)
    notes = {k.split("/", 1)[1]: v for k, v in answers.items() if k.startswith("_notes/")}
    notes2 = {k.split("/", 1)[1]: v for k, v in answers.items() if k.startswith("_notes2/")}
    notes3 = {k.split("/", 1)[1]: v for k, v in answers.items() if k.startswith("_notes3/")}
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
                    "note": notes.get(r["id"]), "note2": notes2.get(r["id"]),
                    "note3": notes3.get(r["id"])})
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


def stratified(pred, gem, frows, field, skip, controls_out=False):
    """A route's precision over every pair it filled, from the owner's values (measurement review pass 11, P11-2).
    The pairs split in two: the ones the owner settled other than by the draw (the first sheet's kind crossings,
    disputes and controls, and the notes), known exactly, a census; and the rest, the pool the second sheet drew from
    uniformly, split again by whether the image prompt (the drawn route) filled the field, since the draw took its
    filled and empty pairs at different rates. Each part of the pool counts at its own size, its precision the drawn
    pairs' there, so neither the hard-leaning census nor the draw weighs more than its share. The interval sets each
    part of the pool at its Wilson bounds (a part with no drawn pair the route filled, at 0 and 1): exact for the image
    prompt, whose filled pairs are all in one part, and conservative for a route that fills in both. The point leaves
    out a part with no drawn pair (its pairs are in the interval only). None when the route filled nothing.
    controls_out (Gemini 3.8): the controls drawn where it agrees with the truth are its false credit, not
    owner-checked evidence for its own row (the module docstring), so they leave its census and count in the pool as
    pairs no answer settled."""
    census, pool = [0, 0], {True: [0, 0, 0], False: [0, 0, 0]}   # pool: [route filled, of them drawn, drawn right]
    for t in frows:
        p = pred.get(t["id"])
        ks = IF.SCOPE[field]
        if p is None or t["id"] in skip or field in t["unknown"] or (ks is not None and t["label"]["kind"] not in ks):
            continue
        pv, tv = p.get(field), t["label"][field]
        if not IF.filled(field, pv):
            continue
        right = IF.filled(field, tv) and IF.field_match(field, pv, tv, "ed2")
        how = t["owner"].get(field)
        if controls_out and how == "control":
            how = None
        if how and how != DRAW:
            census[0] += right
            census[1] += 1
            continue
        g = gem.get(t["id"])
        c = pool[bool(g and IF.filled(field, g.get(field)))]
        c[0] += 1
        if how == DRAW:
            c[1] += 1
            c[2] += right
    filled = census[1] + sum(c[0] for c in pool.values())
    if not filled:
        return None
    parts = [(c[0], c[2], c[1]) for c in pool.values() if c[0]]
    bounds = [wilson(k, n) if n else (0.0, 1.0) for _N, k, n in parts]
    seen = [(N, k, n) for N, k, n in parts if n]
    point = (census[0] + sum(N * k / n for N, k, n in seen)) / (census[1] + sum(N for N, _k, _n in seen))
    return {"precision": point, "lo": (census[0] + sum(N * b[0] for (N, _k, _n), b in zip(parts, bounds))) / filled,
            "hi": (census[0] + sum(N * b[1] for (N, _k, _n), b in zip(parts, bounds))) / filled,
            "filled": filled, "census": census, "pool": {"image prompt filled": pool[True],
                                                         "image prompt empty": pool[False]}}


def verdict(s, err_hi=0.0, agreement=None, strat=None):
    """strat: the stratified precision (above), which a drafter-family route is judged on; its owner-checked pairs
    pooled lean to the hard cases, which the strata undo, so `agreement` is not consulted then. Without strat, a
    drafter-family route is below the bar only when its agreement with the drafted truth is too. err_hi, the
    drafted truth's error bound, widens both ends for a route judged on the drafted truth (P11-6): the fill branch's
    lower bound as well as the below-the-bar upper bound."""
    if not s["docs"]:
        return "not scored"
    if not s["pred_filled"]:
        return "never filled"
    if strat is not None:
        lo, hi, point = strat["lo"], strat["hi"], strat["precision"]
    else:
        (lo, hi), point = wilson(s["ed2"], s["pred_filled"]), s["precision_ed2"]
    if s["truth_filled"] >= FLOOR and lo - err_hi >= LOWER and point >= POINT:
        return "fill"
    if hi + err_hi < POINT and (strat is not None or agreement is None or not agreement["pred_filled"]
                                or wilson(agreement["ed2"], agreement["pred_filled"])[1] < POINT):
        return "below the bar"
    return f"too close (n {s['truth_filled']})" if s["truth_filled"] < FLOOR else "too close"


def draws_to_fill(st, cap=200):
    """For the image prompt: how many more drawn pairs, every one right, its stratified figure needs to fill (the
    lower bound at LOWER and the point at POINT), or None when no number up to cap would do."""
    if not st:
        return None
    N, n, k = st["pool"]["image prompt filled"]
    a, m = st["census"]
    for x in range(cap + 1):
        lo = (a + N * wilson(k + x, n + x)[0]) / (m + N)
        if lo >= LOWER and (a + N * (k + x) / (n + x)) / (m + N) >= POINT:
            return x
    return None


def draw_summary(frows, gem, skip, only=None):
    """The second and third sheets' draw for the image prompt alone, per field: its filled pairs right / answered, and
    its empty pairs the owner found empty / answered (sideways documents never drawn). only: a set of (doc, field),
    the third sheet's pairs alone."""
    out = {}
    for f in FIELDS:
        c = collections.Counter()
        for t in frows:
            if t["owner"].get(f) != DRAW or t["id"] in skip or f in t["unknown"] or (only and (t["id"], f) not in only):
                continue
            gv, tv = (gem.get(t["id"]) or {}).get(f), t["label"][f]
            if IF.filled(f, gv):
                c["filled"] += 1
                c["right"] += IF.filled(f, tv) and IF.field_match(f, gv, tv, "ed2")
            else:
                c["empty"] += 1
                c["truly empty"] += not IF.filled(f, tv)
        out[f] = dict(c)
    return out


def draw_routes(P, frows, skip):
    """Every route on the drawn pairs alone: right / filled. The pairs were drawn on the image prompt's filling, so
    for any other route they are a sample conditioned on it, not on its own values."""
    out = {}
    for rk, *_ in ROUTES:
        for f in FIELDS:
            c = [0, 0]
            for t in frows:
                p = P[rk].get(t["id"])
                if p is None or t["owner"].get(f) != DRAW or t["id"] in skip or f in t["unknown"]:
                    continue
                pv, tv = p.get(f), t["label"][f]
                if IF.filled(f, pv):
                    c[1] += 1
                    c[0] += IF.filled(f, tv) and IF.field_match(f, pv, tv, "ed2")
            out[f"{rk}|{f}"] = c
    return out


def unasked_disputes(frows, skip):
    """{field: [pairs, in base]}: in-scope disputed pairs no sheet settled, which keep the judge's ruling."""
    out = {}
    for f in FIELDS:
        ts = [t for t in frows if f in t["disputed"] and not t["owner"].get(f) and t["id"] not in skip
              and f not in t["unknown"] and (IF.SCOPE[f] is None or t["label"]["kind"] in IF.SCOPE[f])]
        out[f] = [len(ts), sum(t["part"] == "base" for t in ts)]
    return out


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


def tag_conflicts(pred, frows, tags, skip):
    """The image prompt's misses against the owner's date tags (`tag_score`), split by where his sheet stands: the
    owner-checked pieces whose sheet value differs from the tag while the reading equals the sheet (listed: piece, sheet
    value, tag, by year or month), the owner-checked misses on the sheet too, and the drafted pieces where the truth and
    the reading agree and both differ from the tag. Also every owner-checked tagged piece whose sheet differs from the
    tag, whatever the reading."""
    out = {"conflicts": [], "sheet miss": 0, "drafted agree": 0, "other": 0, "sheet differs": 0}
    for t in frows:
        if t["id"] in skip or t["label"]["kind"] not in PRINTED or t["id"] not in tags:
            continue
        y, m, _ = tags[t["id"]]
        lab, how = t["label"]["publication_date"], t["owner"].get("publication_date")
        on_tag = lambda v: bool(v) and v[0] == y and (m is None or v[1] == m)  # noqa: E731
        if how and lab and not on_tag(lab):
            out["sheet differs"] += 1
        v = (pred.get(t["id"]) or {}).get("publication_date")
        if not v or on_tag(v):
            continue
        eq = bool(lab) and IF.field_match("publication_date", v, lab, "ed2")
        if how and eq and not on_tag(lab):
            out["conflicts"].append({"doc": t["id"], "sheet": list(lab), "tag": [y, m],
                                     "by": "year" if lab[0] != y else "month"})
        elif how and not eq:
            out["sheet miss"] += 1
        elif not how and eq and not on_tag(lab):
            out["drafted agree"] += 1
        else:
            out["other"] += 1
    return out


def season_year_only(frows, fixes, gem):
    """Drawn publication dates the owner typed as a season or a two-month issue, which the hand reading folds to the
    year alone, and of them the ones the image prompt read as a bare year, so right on the sheet."""
    typed, right = [], []
    for t in frows:
        v = ((fixes.get(t["id"]) or {}).get("answer") or {}).get("publication_date")
        v = typed("publication_date", v) if isinstance(v, str) else norm("publication_date", v)
        if not v or t["owner"].get("publication_date") != DRAW or v[1] is not None:
            continue
        typed.append(t["id"])
        g = (gem.get(t["id"]) or {}).get("publication_date")
        if g and g[0] == v[0] and g[1] is None:
            right.append(t["id"])
    return {"typed": typed, "year-only right": right}


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
    notes = [k for k in answers if k.startswith("_notes")]
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
    scores, verdicts, by_part, strat = {}, {}, {}, {}
    third_open = not os.path.exists(os.path.join(SHEET3, "answers.json"))
    for rk, _label, fam in ROUTES:
        for which in ("owner", "drafted"):
            for f in FIELDS:
                scores[f"{rk}|{which}|{f}"] = IF.score(pairs(rk, fam, P[rk], frows, f, which, skip), f)
        for f in FIELDS:
            so, sd = scores[f"{rk}|owner|{f}"], scores[f"{rk}|drafted|{f}"]
            strat[f"{rk}|{f}"] = st = stratified(P[rk], P["draft-gemini"], frows, f, skip,
                                                 controls_out=rk == "app-gemini-3.8-flash")
            v = verdict(so, 0.0, sd, st) if fam and st else verdict(sd, err_hi)
            if fam and f in THIRD_FIELDS and third_open and v not in ("fill", "below the bar", "never filled"):
                v = "waits on the third sheet"   # kind: 3 drawn pairs cannot carry its pool (P11-2)
            verdicts[f"{rk}|{f}"] = v
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
    insc = lambda t, f: t["id"] not in skip and (IF.SCOPE[f] is None or t["label"]["kind"] in IF.SCOPE[f])  # noqa: E731
    owner_n = {f: [sum(1 for t in frows if t["owner"].get(f) and insc(t, f)),
                   sum(1 for t in frows if t["owner"].get(f) and insc(t, f) and IF.filled(f, t["label"][f])),
                   sum(1 for t in frows if t["owner"].get(f) == DRAW and insc(t, f) and IF.filled(f, t["label"][f]))]
               for f in FIELDS}
    themes = collections.Counter(th for fx in fixes.values() for th in fx.get("themes") or [])
    o = {"counts": {
        "documents": len(frows), "notes": len(notes), "answered": sum(1 for k, v in answers.items()
                                                                     if not k.startswith("_") and v is not None),
        "questions": len(key), "sheets": {"first": sum(":more-" not in n and ":third-" not in n for n in key),
                                          "second": sum(":more-" in n for n in key),
                                          "third": sum(":third-" in n for n in key)},
        "notes_by_sheet": {"first": sum(k.startswith("_notes/") for k in notes),
                           "second": sum(k.startswith("_notes2/") for k in notes),
                           "third": sum(k.startswith("_notes3/") for k in notes)},
        "typed_by_hand": sum(len(fx.get("answer") or {}) for fx in fixes.values()),
        "note_sets": sum(len(fx.get("set") or {}) for fx in fixes.values()),
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
        "verdicts": verdicts, "by_part": by_part, "sideways": side_scores, "stratified": strat,
        "draw": draw_summary(frows, P["draft-gemini"], skip),
        "draw3": draw_summary(frows, P["draft-gemini"], skip, {(k["doc"], k["field"]) for n, k in key.items()
                                                                 if ":third-" in n}), "draw_routes": draw_routes(P, frows, skip),
        "unasked_disputes": unasked_disputes(frows, skip), "third_sheet_open": third_open,
        "tags": {rk: tag_score(P[rk], frows, tags, skip) for rk, *_ in ROUTES},
        "tag_conflicts": tag_conflicts(P["draft-gemini"], frows, tags, skip),
        "season_year_only": season_year_only(frows, fixes, P["draft-gemini"]),
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


def strat_cell(st):
    if not st:
        return "-"
    return f"{f2(st['precision'])} [{f2(st['lo'])}, {f2(st['hi'])}] of {st['filled']}"


def report(o):
    c, e, sh = o["counts"], o["truth_error"], o["sheet"]
    sc, ns = c["sheets"], c["notes_by_sheet"]
    L = ["# Item fields: the owner's sheets folded in, every route scored, the fill verdict "
         "(W47.item-fields-retruth-score; the second sheet, W47.item-fields-more-score; the third, "
         "W47.item-fields-third-score)", "",
         "Generated by `scripts/segbench/item_fields_score.py`; method in its header. Truth from "
         "W47.item-fields-retruth (`item-fields-retruth.md`) with the owner's answers and notes folded in; the "
         "labels, notes and readings stay in the bench cache, and this page has counts only, apart from the "
         "publication dates listed by piece under FLD-6. Offline, $0.", ""]
    L += ["## The fold", "",
          f"{c['answered']} of {c['questions']} sheet questions answered ({sc['first']} on the first sheet, "
          f"{sc['second']} on the second, a random draw from the image prompt's readings"
          + (f", {sc['third']} on the third" if sc["third"] else "") + f"), notes on {c['notes']} documents "
          f"({ns['first']} first sheet, {ns['second']} second" + (f", {ns['third']} third" if ns["third"] else "")
          + "; a document on two sheets keeps both notes apart). Every note "
          f"was read before scoring, and {c['typed_by_hand']} typed dates the reader cannot parse (\"22 May 1967\", "
          f"a season, a two-month issue) were read by hand, a season or a two-month issue as its year: {c['note_sets']} values set from a note and {c['note_drops']} fields dropped as "
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
          f"fill rule needs {FLOOR} with a true value.", "", "| field | owner-checked | with a true value | of them "
          "from the draw |", "|---|---|---|---|"]
    for f in FIELDS:
        L.append(f"| {f} | {c['owner_n'][f][0]} | {c['owner_n'][f][1]} | {c['owner_n'][f][2]} |")
    L += ["", "## The random draw, the image prompt alone", "",
          "The second sheet (and the third, continuing it for kind, title and publication) drew uniformly from the pairs no earlier answer settled, split by whether the image prompt "
          "(Gemini 3.7 Flash, the item prompt on the page images) filled the field: its filled draw measures the "
          "image prompt's precision on that pool directly, and its empty draw how often an empty reading hides a "
          "value. Apart from the first sheet's pairs, which lean to the hard cases.", "",
          "| field | filled drawn: right | empty drawn: truly empty |", "|---|---|---|"]
    for f in FIELDS:
        d = o["draw"][f]
        L.append(f"| {f} | {frac(d.get('right', 0), d.get('filled', 0))} | "
                 + (f"{d.get('truly empty', 0)}/{d['empty']}" if d.get("empty") else "-") + " |")
    L += ["", "## Every route, field by field", "",
          "Precision at the loose level (ed2; kind at the Zotero item type). Owner-checked, pooled: right / filled "
          "over every owner-checked pair, with its Wilson interval; it weighs the first sheet's hard cases (kind "
          "crossings, disputes) 2.5 to 5 times their share (measurement review pass 11, P11-2), so it is shown for "
          "comparison only. Stratified: the route's precision over every pair it filled, the first sheet's pairs "
          "counted exactly at their own number and the rest at theirs from the draw (the method in "
          "`stratified`'s docstring), with its interval. A drafter-family row (Gemini 3.7, 3.8 and Luna) is judged "
          "on the stratified figure and the owner-checked n; its drafted-truth figure is agreement with the "
          "drafters. For any route but the image prompt the drawn pairs were chosen on the image prompt's filling, "
          "so its stratified figure weighs them by that split and its interval is conservative. The other rows "
          "are judged on the drafted truth, whose error is the controls' above "
          f"(upper bound {f2(e['wilson'][1])}, taken off the lower bound for a fill and added to the upper for "
          "below the bar). Replies per route: "
          + ", ".join(f"{SHORT[rk]} {c['replies'][rk]}" for rk, *_ in ROUTES) + ".", ""]
    for f in FIELDS:
        L += [f"### {f}", "", "| route | owner-checked precision, pooled | stratified precision | recall | "
              "drafted-truth precision | recall | verdict |", "|---|---|---|---|---|---|---|"]
        for rk, label, fam in ROUTES:
            so, sd = o["scores"][f"{rk}|owner|{f}"], o["scores"][f"{rk}|drafted|{f}"]
            if not so["docs"] and not sd["docs"]:
                continue
            st = o["stratified"].get(f"{rk}|{f}")
            L.append(f"| {label} | {frac(so['ed2'], so['pred_filled'])} | {strat_cell(st)} | "
                     f"{so['ed2']}/{so['truth_filled']} | "
                     f"{frac(sd['ed2'], sd['pred_filled'])}{' (agreement)' if fam else ''} | "
                     f"{sd['ed2']}/{sd['truth_filled']} | {o['verdicts'][f'{rk}|{f}']} |")
        L.append("")
    L += ["## The drawn pairs, every route", "",
          "Right / filled on the second sheet's drawn pairs alone. They were drawn on the image prompt's filling, so "
          "for every other route they are conditioned on it: a sample of the pairs the image prompt filled or left "
          "empty, not of the route's own values.", "", "| route | " + " | ".join(FIELDS) + " |",
          "|---|" + "---|" * len(FIELDS)]
    for rk, *_ in ROUTES:
        cells = [o["draw_routes"][f"{rk}|{f}"] for f in FIELDS]
        if any(x[1] for x in cells):
            L.append(f"| {SHORT[rk]} | " + " | ".join(f"{x[0]}/{x[1]}" if x[1] else "-" for x in cells) + " |")
    L += ["", "## By part (drafted truth, right / filled)", "", "| route | field | base | clippings | handwritten |",
          "|---|---|---|---|---|"]
    for rk in ("draft-gemini", "tagging", "draft-luna"):
        for f in FIELDS:
            cells = [o["by_part"].get(f"{rk}|{p}|{f}") for p in ("base", "clippings", "handwritten")]
            L.append(f"| {SHORT[rk]} | {f} | " + " | ".join(f"{x[0]}/{x[1]}" if x else "-" for x in cells) + " |")
    L += ["", "## Publication date against the owner's date tags (FLD-6)", "",
          f"{c['owner_tags_printed']} of the {c['printed']} printed pieces carry the owner's year tag on their first "
          "page. Right means the same year, and the same month where he tagged one. The two owner truths are two "
          "different dates: the tag is the document's date, which the app's call returns; the item field, which the "
          "image prompt and Luna read and the owner's sheets answer, is the printed issue date. W47.ct-zotero's "
          "export takes Zotero's `issued` from the owner's or the app's date, not the item field, so no conflicting "
          "date is written.", "", "| route | tagged pieces | filled | right | precision |", "|---|---|---|---|---|"]
    for rk, label, _f in ROUTES:
        t = o["tags"][rk]
        if t.get("docs"):
            L.append(f"| {label} | {t['docs']} | {t.get('filled', 0)} | {t.get('right', 0)} | "
                     f"{frac(t.get('right', 0), t.get('filled', 0))} |")
    tg, tc = o["tags"], o["tag_conflicts"]
    gst = o["stratified"].get("draft-gemini|publication_date")
    conf = tc["conflicts"]
    nby = collections.Counter(x["by"] for x in conf)
    miss = len(conf) + tc["sheet miss"] + tc["drafted agree"] + tc["other"]
    ymd = lambda v: "-".join([str(v[0])] + [f"{x:02d}" for x in v[1:] if x])  # noqa: E731
    L += ["", "Against the tags, every route: "
          + "; ".join(f"{SHORT[rk]} {frac(tg[rk].get('right', 0), tg[rk].get('filled', 0))}"
                      for rk, *_ in ROUTES if tg[rk].get("filled"))
          + (f". The image prompt's {f2(gst['precision'])} [{f2(gst['lo'])}, {f2(gst['hi'])}] above is its stratified "
             "precision against the sheets' printed issue date; the figure here is against the document's date."
             if gst else "."), "",
          f"The image prompt's {miss} misses against the tags, read against the owner's sheets: on {len(conf)} the "
          "owner-checked sheet value differs from his own tag and the reading equals the sheet "
          f"({nby['year']} by year, {nby['month']} by month, listed below); {tc['sheet miss']} "
          f"{'is a miss' if tc['sheet miss'] == 1 else 'are misses'} on the sheet too; {tc['drafted agree']} "
          f"{'is a drafted piece' if tc['drafted agree'] == 1 else 'are drafted pieces'} where the truth and the "
          "reading agree and both differ from the tag"
          + (f"; {tc['other']} other" if tc["other"] else "") + ". In all, the sheet differs from the tag on "
          f"{tc['sheet differs']} of the owner-checked tagged pieces, whatever the reading. The sheet gives the "
          "printed issue date and the tag the document's date, so these are two dates, not one truth wrong; the tag "
          f"figure counts the {len(conf)} listed against the reading only because it scores the other date.", "",
          "| piece | sheet (printed issue date) | tag (document's date) | differs by |", "|---|---|---|---|"]
    for x in conf:
        L.append(f"| {x['doc']} | {ymd(x['sheet'])} | {ymd(x['tag'])} | {x['by']} |")
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
    L += ["## The verdict", ""]
    for f in FIELDS:
        vs = [(SHORT[rk], o["verdicts"][f"{rk}|{f}"]) for rk, *_ in ROUTES]
        L.append(f"- **{f}**: " + "; ".join(f"{n} {v}" for n, v in vs) + ".")
    ud = o["unasked_disputes"]
    udn, udb = sum(v[0] for v in ud.values()), sum(v[1] for v in ud.values())
    gem = [f for f in FIELDS if o["verdicts"][f"draft-gemini|{f}"] == "fill"]
    close = [(f, draws_to_fill(o["stratified"][f"draft-gemini|{f}"])) for f in FIELDS if f != "kind"
             and o["verdicts"][f"draft-gemini|{f}"] in ("too close", "waits on the third sheet")]
    L += ["", (("Fields the image prompt fills by the rule: " + ", ".join(gem) + ".") if gem else
               "The image prompt clears the rule on no field.")
          + ("".join(f" On {f} its point is {f2(o['stratified'][f'draft-gemini|{f}']['precision'])} and the lower "
                     f"bound {f2(o['stratified'][f'draft-gemini|{f}']['lo'])}: "
                     + (f"about {x} more drawn pairs, every one right, would let it fill." if x is not None else
                        "no further draw of right readings would let it fill.") for f, x in close)), "",
          "The verdicts rest on the stratified precision: the first sheet's pairs, which lean to the hard cases, at "
          "their own share, and the pool the second sheet drew from at its share. "
          + ("The third sheet (W47.item-fields-third-score) continued the same seeded draw for kind, title and "
             "publication; on its pairs alone the image prompt was right on "
             + ", ".join(f"{f} {frac(o['draw3'][f].get('right', 0), o['draw3'][f].get('filled', 0))}"
                         for f in THIRD_FIELDS)
             + ". Its wrong kind called a journal article a newsletter; its wrong titles took a kicker line into the headline and gave only the first page's half of a "
               "title the owner noted runs over two pages. " if not o["third_sheet_open"] else "")
          + ("Kind, title and publication wait on the third sheet (W47.item-fields-third-score), which continues "
             "the same seeded draw: the second sheet drew 3 of kind's 254 unsettled pairs, too few to carry the "
             "pool (P11-2), and title's and publication's lower bounds fall short as above, so it draws 35 kind, 31 "
             "title and 22 publication pairs more, each the fewest with which one wrong new reading still lets the "
             "image prompt fill. " if o["third_sheet_open"] else "") +
          "The app's call on Vision text gives no title and returns the document's date rather than the printed "
          "issue date, so the image prompt is the route for the item fields. The local routes and the extractor "
          "ran on ABBYY text, which the app will not use (owner, 2026-10-30): their rows are a record rather than a "
          "candidate.", "",
          "## Measurement card", "",
          "- **Truth:** W47.item-fields-retruth's (Gemini 3.7 and GPT 5.6 Luna drafting, Gemini 3.7 ruling) with "
          "both owner sheets' answers and notes folded in. The random controls' error above covers the agreed cells "
          f"only. The disputes no sheet asked keep the judge's ruling: in scope, sideways documents out, {udn} pairs "
          "(" + ", ".join(f"{f} {v[0]}" for f, v in ud.items() if v[0]) + f"), {udb} of them in base, where the "
          f"non-drafter routes score. The owner upheld the judge on {tot['judge right']} of the {tot['answered']} "
          f"disputes he answered, an error of {frac(tot['answered'] - tot['judge right'], tot['answered'])} on that "
          "stratum beside the controls', so a few points of truth error per field beyond the controls' on the "
          "drafted truth (P11-6); it moves no verdict, since the rows judged on the drafted truth are ABBYY "
          "records. The drafter-family rows are judged on the owner's values only. The fold reads a typed season or "
          f"two-month issue as its year ({len(o['season_year_only']['typed'])} drawn publication dates were typed "
          "so), which makes a year-only reading of such a piece right: the image prompt is right that way on "
          f"{len(o['season_year_only']['year-only right'])} drawn "
          f"pair{'' if len(o['season_year_only']['year-only right']) == 1 else 's'}"
          + (f" ({', '.join(o['season_year_only']['year-only right'])})" if o["season_year_only"]["year-only right"]
             else "")
          + "".join(f"; {d} is also a month conflict with the owner's tag (FLD-6)"
                    for d in o["season_year_only"]["year-only right"]
                    if any(x["doc"] == d for x in o["tag_conflicts"]["conflicts"])) + ".",
          "- **Selection:** base by Gemini 3.8's format and ABBYY cues (inherited, FLD-3); clippings and handwritten "
          "by the owner's tags. The first sheet's owner-checked pairs are kind crossings, a seeded sample of "
          "disputes per field, the 3.8-agreeing controls (left out of 3.8's pooled row, and out of its stratified "
          "census, where they count in the pool as pairs no answer settled) and the random controls, so "
          "they lean toward the hard cases; the second sheet's are a seeded uniform draw (W47.item-fields-more-checks, "
          "seed 4750) from the rest, split by the image prompt's filling, chosen by no other route and no ABBYY "
          "text. The stratified figure counts each part at its own size.",
          "- **Comparison:** the image prompt and the app's call on Vision text ran on the same pages; the cached "
          "app replies and the extractor ran on ABBYY text (FLD-4), base only.",
          "- **Noise:** Wilson intervals; the stratified interval sets each drawn part at its Wilson bounds, exact "
          "for the image prompt (one part) and conservative for the other routes; no rerun of any route here, so a "
          "route's run-to-run spread is not in the intervals.",
          "- **Scope:** these 299 documents and six fields; it does not settle sender, recipient or the document "
          "date (W46), nor kinds and fields outside the list"
          + (", nor (until the third sheet is folded) kind, title and publication" if o["third_sheet_open"] else "")
          + ". Inference "
          "(a place from an address, a name from initials) is left out, not scored either way.", ""]
    return "\n".join(L)


if __name__ == "__main__":
    build()
