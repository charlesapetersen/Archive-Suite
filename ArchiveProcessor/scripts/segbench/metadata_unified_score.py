#!/usr/bin/env python3
"""W49.proc-metadata-consolidate: one unified structured metadata call against the app's separate calls, scored on the
item-field set's 299 documents.

    python3 metadata_unified_score.py            # segbench-results/metadata-unified.md and .json (aggregates only)

Offline and $0: every reply it scores is already in the bench cache. It reads the corpus's Finder tags with getxattr(2)
(corpus_survey.read_tags, through item_fields_score.owner_tags), nothing else there, and writes nothing in it.

The arms (metadata_unified.PROMPT, the frozen pack's prompt, on the Vision text of the 299 with three neighbours'
openings and the rule dates): every `replies/<arm>/` folder of the metadata-unified cache other than the Mac pilot's,
each reply checked against the prompt as it now renders (a reply to a changed prompt is refused). As of 2026-11-24:
`unified-gemini3.8-flash` (metadata_unified_gemini.py: AI Studio, personal key, thinking low) and, once the owner's
Sherlock session returns it, `unified-qwen3.6-27b` (metadata_unified.py collect).

The baselines, the app's separate calls as the bench cache already holds them on the same documents' Vision text:
- tagging: item_fields_retruth's `tagging` replies, the app's tagging prompt of 2026-11-05 on the first 3,000
  characters and three neighbours' 300 (Gemini 3.7 Flash, gateway, no thinking setting); gives the year, month and
  Date Uncertain the app would write before the dating call, the kind (format), and the one-string author, recipient
  and location fields.
- entity: ent_8k_paired's `shipped` arm, EntityExtractor's prompt on the first 3,000 characters (Gemini 3.8 Flash,
  AI Studio, no thinking setting), on the 138 correspondence documents; `shipped-b` is its rerun, the floor.
- item: item_fields_retruth's drafter A reading, the item-field prompt on the page images and the 16,000-character
  text (Gemini 3.7 Flash, gateway, low reasoning), which is the app's item-field call's shape (prompts.md §10) and
  also drafted the truth, so it is judged on the owner-checked pairs as item_fields_score judges it.
- the dating trace (prompts.md §9) has no run on this set: its measured set is date_traceable's owner 300
  (segbench-results/date-route-pipeline.md). Its cost and latency enter the per-document baseline from that ledger.

Truth. Entities: ent_truth.load_truth() as it now stands (the owner's answers and the sending-place rule), scored by
ent_truth_owner.scores (edit-distance-2 precision, recall and F1 per field, the place by city) and ent_score_paid's
paired bootstrap. Item fields: item_fields_score's folded truth (every answered sheet), its pairs, stratified
precision, fill verdict and by-part scores, so the unified rows read like item-fields-score.md's. Dates: the owner's
Finder year and month tags on the document's first page (date_tagging.truth_of), exact year, within one, month where
tagged; the unified call's quote is checked as DateRoute.evidenceCheck checks it (in the cited text, carrying the
year). Enclosure proposals have no truth here (the 15 owner cases of date_enclosure are ABBYY text): rates, cue words
and quote validity are reported. Subject tags have no truth: counts only.

Cost per 1,000 documents is each call's mean ledger cost (Gemini 3.8 Flash's list price, a ceiling for the 3.7
calls; the gateway's own figure where it was sent) times the share of documents the app sends it on: tagging, the
trace and item fields on every document, the entity call on correspondence (the set's share), the image pass on the
32% the pipeline measured. Latency is the mean wall time of each call; the baseline's calls run in sequence in the
app (tagging, then the trace, then entities and item fields), so their sum is the baseline's.
Run from scripts/segbench.
"""
from __future__ import annotations

import collections
import datetime
import json
import math
import os
import re
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ent_8k_paired as E8  # noqa: E402
import ent_score as ES  # noqa: E402
import ent_score_paid as P  # noqa: E402
import ent_truth as ET  # noqa: E402
import ent_truth_owner as EO  # noqa: E402
import item_fields as IF  # noqa: E402
import item_fields_retruth as IR  # noqa: E402
import item_fields_score as IFS  # noqa: E402
import metadata_unified as M  # noqa: E402
import metadata_unified_gemini as MG  # noqa: E402

RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "metadata-unified.md")
REHEARSAL = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal")
ARM_NAMES = {"unified-gemini3.8-flash": ("Gemini 3.8 Flash, unified call (AI Studio, thinking low)", True),
             "unified-qwen3.6-27b": ("Qwen3.6 27B FP8, unified call (Sherlock, thinking off)", False)}
TAGGING_LABEL = "Gemini 3.7 Flash, the app's tagging call (gateway)"
ENTITY_LABEL = "Gemini 3.8 Flash, the app's entity call (AI Studio)"
ITEM_LABEL = "Gemini 3.7 Flash, the app's item-field call on the page images (gateway; drafter A)"
IMAGE_PASS_SHARE = 0.32      # date-route-pipeline.md: the image pass is sent on 32% of the owner's mix
CUES = (("enclos", "enclose / enclosure"), ("attach", "attach"), ("herewith", "herewith"), ("inclos", "inclose"),
        ("copy", "copy / copies"), ("forward", "forward"), ("send", "send / sending"), ("accompan", "accompany"))


# --- replies ----------------------------------------------------------------------------------------------------

def arms():
    root = M.CACHE / "replies"
    return sorted(x for x in os.listdir(root) if os.path.isdir(root / x) and not x.startswith("pilot-")) \
        if root.is_dir() else []


def load_arm(arm, ds):
    """{doc id: parsed reply or None} for the documents answered; refuses a reply to another prompt."""
    out, unparsed, wall = {}, 0, []
    for d in ds:
        p = M.CACHE / "replies" / arm / f"{d['id']}.json"
        if not p.exists():
            continue
        r = json.loads(p.read_text(encoding="utf-8"))
        if r["meta"].get("prompt_sha256") != M.sha(M.prompt(d)):
            sys.exit(f"{p}: answered another prompt; move it aside or rerun")
        js = r.get("parsed")
        if js is None:
            js = M.parse(r.get("raw"))
        if js is None:
            unparsed += 1
        out[d["id"]] = js
        if r["meta"].get("wall_s") is not None:
            wall.append(r["meta"]["wall_s"])
    return out, unparsed, wall


# --- the unified reply in each truth's shape -------------------------------------------------------------------

def value(x):
    return x.get("value") if isinstance(x, dict) else (x if isinstance(x, str) else None)


def ent_pred(js):
    """The entity fields as ent_truth.ent_names reads them: lists of {name, quote}."""
    return {f: [e for e in (js.get(f) or []) if isinstance(e, dict)] for f in ET.FIELDS}


def item_pred(js):
    """The item fields as item_fields.parse gives a reading."""
    return {"kind": js.get("kind") if js.get("kind") in IF.KINDS else ("other" if js.get("kind") else None),
            "title": IF.clean(value(js.get("title"))), "byline": IF.names(js.get("byline")),
            "publication": IF.clean(value(js.get("publication"))),
            "publication_date": IF.date_of(value(js.get("publication_date"))),
            "recipient_place": IF.names(js.get("recipient_place"))}


def date_pred(js):
    """(year, month, date_uncertain, source, quote) from the unified reply's date object."""
    dt = js.get("date") or {}
    y, m = dt.get("year"), dt.get("month")
    y = int(y) if isinstance(y, (int, float)) and not isinstance(y, bool) and 1000 <= int(y) <= 2100 else None
    m = int(m) if isinstance(m, (int, float)) and not isinstance(m, bool) and 1 <= int(m) <= 12 else None
    return y, m, dt.get("date_uncertain") is True, dt.get("source"), dt.get("quote") if isinstance(dt.get("quote"), str) else None


def tagging_date(doc_id):
    """The tagging call's (year, month, date_uncertain), as TagGenerator parses it; None when no reply."""
    import date_tagging as DT
    p = IR.reply_path("tagging", doc_id)
    if not os.path.exists(p):
        return None
    raw = json.load(open(p, encoding="utf-8")).get("raw") or ""
    y, m, du, ok = DT.app_parse({"candidates": [{"content": {"parts": [{"text": raw}]}}]})
    if not ok:
        return None
    return (int(y) if y and str(y).isdigit() else None), (m if isinstance(m, int) else None), du


def tagging_entities(doc_id):
    """The tagging call's one-string name fields, split as the entity reports split them."""
    p = IR.reply_path("tagging", doc_id)
    if not os.path.exists(p):
        return None
    js = P.parse(json.load(open(p, encoding="utf-8")).get("raw"))
    if js is None:
        return None
    joined = lambda v: "; ".join(x for x in v if isinstance(x, str) and x.strip()) or None if isinstance(v, list) else v  # noqa: E731
    return {f: ES.split_names(joined(js.get(k))) if f != "sending_place" else joined(js.get(k))
            for f, k in ES.REPLY_FIELD.items()}


# --- scores -----------------------------------------------------------------------------------------------------

def binom_two_sided(k, n):
    """Exact two-sided sign test: P(at most min(k, n-k) of n at p = 1/2), doubled, capped at 1."""
    if n == 0:
        return None
    lo = min(k, n - k)
    p = sum(math.comb(n, i) for i in range(lo + 1)) / 2 ** n
    return min(1.0, 2 * p)


def date_scores(preds, tags, ds):
    """preds: {id: (year, month, du)}; tags: {id: (year, month, cls)}. Exact year, within one, month where tagged, by
    class, and the Date Uncertain rate on the documents with a year tag."""
    c = collections.Counter()
    by_cls = collections.defaultdict(collections.Counter)
    for d in ds:
        i = d["id"]
        if i not in tags or preds.get(i) is None:
            continue
        ty, tm, cls = tags[i]
        py, pm, du = preds[i]
        c["docs"] += 1
        c["year_given"] += py is not None
        c["year_exact"] += py == ty
        c["year_within_one"] += py is not None and abs(py - ty) <= 1
        c["false_year"] += py is not None and py != ty and not du
        c["uncertain"] += du
        by_cls[cls]["docs"] += 1
        by_cls[cls]["year_exact"] += py == ty
        by_cls[cls]["uncertain"] += du
        if tm is not None:
            c["month_docs"] += 1
            c["month_given"] += pm is not None
            c["month_exact"] += pm == tm
    out = dict(c)
    out["by_class"] = {k: dict(v) for k, v in by_cls.items()}
    return out


def date_paired(a, b, tags, ds):
    """Both right / only a / only b / neither on the exact year, with the sign test's p."""
    c = collections.Counter()
    for d in ds:
        i = d["id"]
        if i not in tags or a.get(i) is None or b.get(i) is None:
            continue
        ra, rb = a[i][0] == tags[i][0], b[i][0] == tags[i][0]
        c["both" if ra and rb else "only_a" if ra else "only_b" if rb else "neither"] += 1
    out = dict(c)
    out["p"] = binom_two_sided(c["only_a"], c["only_a"] + c["only_b"])
    return out


def cited_text(d, source, near):
    if source == "self" or source is None:
        return IR.doc_text(d)[:M.TEXT_CAP]
    for lab, t in near:
        if lab == source:
            return t.strip()[: M.PREV_CHARS if lab == "P1" else M.NEAR_CHARS]
    return ""


def date_evidence(preds_full, ds):
    """The unified date's source and quote: self / neighbour / none, and whether the quote is in the cited text and
    carries the year (DateRoute.evidenceCheck's two conditions)."""
    c = collections.Counter()
    for d in ds:
        r = preds_full.get(d["id"])
        if r is None:
            continue
        y, _m, du, src, q = r
        if y is None:
            c["no_year"] += 1
            continue
        kind = "self" if src == "self" else ("neighbour" if isinstance(src, str) and re.fullmatch(r"[PN]\d", src) else "other")
        c[f"source_{kind}"] += 1
        if kind == "neighbour":
            c["neighbour_marked_uncertain"] += du
        ok_text = M.quote_found(q, cited_text(d, src, M.neighbours(d)))
        ok_year = bool(q) and str(y) in q
        c["quote_in_text"] += ok_text
        c["quote_has_year"] += ok_year
        c["evidence_valid"] += ok_text and ok_year
    return dict(c)


def enclosure_stats(preds, ds):
    c = collections.Counter()
    cues = collections.Counter()
    conf = []
    for d in ds:
        js = preds.get(d["id"])
        if js is None:
            continue
        e = js.get("enclosure") or {}
        c["docs"] += 1
        near = M.neighbours(d)
        has_p1 = any(lab == "P1" for lab, _t in near)
        c["with_p1"] += has_p1
        own = IR.doc_text(d)[:M.TEXT_CAP]
        if e.get("announces") is True:
            c["announces"] += 1
            q = e.get("announces_quote")
            c["announces_quote_in_text"] += M.quote_found(q, own)
            for key, name in CUES:
                if q and key in q.lower():
                    cues[f"announces: {name}"] += 1
                    break
            else:
                cues["announces: other words"] += 1
        if e.get("sent_with_previous") is True:
            c["sent_with_previous"] += 1
            q = e.get("sent_with_quote")
            p1 = cited_text(d, "P1", near)
            c["sent_with_quote_in_text"] += M.quote_found(q, own) or M.quote_found(q, p1)
            for key, name in CUES:
                if q and key in q.lower():
                    cues[f"sent with P1: {name}"] += 1
                    break
            else:
                cues["sent with P1: other words"] += 1
        if isinstance(e.get("confidence"), (int, float)) and not isinstance(e.get("confidence"), bool):
            conf.append(float(e["confidence"]))
    out = dict(c)
    out["cues"] = dict(cues.most_common())
    out["confidence"] = {"n": len(conf), "median": statistics.median(conf) if conf else None,
                         "at_least_0.5": sum(x >= 0.5 for x in conf), "at_least_0.9": sum(x >= 0.9 for x in conf)}
    return out


def ledger_means(path, pick=lambda r: True):
    rows = [r for r in MG.ledger(path) if pick(r) and r.get("http") == 200]
    if not rows:
        return None
    gw = [r["gateway_cost"] for r in rows if r.get("gateway_cost") is not None]
    return {"n": len(rows), "cost_mean": statistics.mean(r.get("cost") or 0 for r in rows),
            "gateway_cost_mean": statistics.mean(gw) if gw else None,
            "wall_mean": statistics.mean(r.get("wall_s") or 0 for r in rows),
            "wall_median": statistics.median(r.get("wall_s") or 0 for r in rows),
            "prompt_mean": statistics.mean((r.get("usage") or {}).get("promptTokenCount") or
                                           (r.get("usage") or {}).get("prompt_tokens") or 0 for r in rows)}


def item_scores(P_all, frows, skip, routes):
    """item_fields_score's build() for the routes given: owner and drafted scores, stratified precision, verdict,
    by-part drafted scores."""
    scores, verdicts, strat, by_part = {}, {}, {}, {}
    for rk, fam in routes:
        for f in IFS.FIELDS:
            so = IF.score(IFS.pairs(rk, fam, P_all[rk], frows, f, "owner", skip), f)
            sd = IF.score(IFS.pairs(rk, fam, P_all[rk], frows, f, "drafted", skip), f)
            scores[f"{rk}|owner|{f}"], scores[f"{rk}|drafted|{f}"] = so, sd
            st = IFS.stratified(P_all[rk], P_all["draft-gemini"], frows, f, skip)
            strat[f"{rk}|{f}"] = st
            verdicts[f"{rk}|{f}"] = IFS.verdict(so, 0.0, sd, st) if fam and st else IFS.verdict(sd, 0.0)
            for part in ("base", "clippings", "handwritten"):
                s = IF.score(IFS.pairs(rk, fam, P_all[rk], [t for t in frows if t["part"] == part], f, "drafted", skip), f)
                if s["docs"]:
                    by_part[f"{rk}|{part}|{f}"] = s
    return scores, verdicts, strat, by_part


def item_paired(a, b, frows, skip):
    """Per field, on the owner-checked pairs both routes answered: both / only a / only b / neither right (right: the
    ed2 match, or both empty), with the sign test's p."""
    out = {}
    for f in IFS.FIELDS:
        c = collections.Counter()
        for t in frows:
            if a.get(t["id"]) is None or b.get(t["id"]) is None or t["id"] in skip or f in t["unknown"]:
                continue
            ks = IF.SCOPE[f]
            if ks is not None and t["label"]["kind"] not in ks:
                continue
            if not t["owner"].get(f):
                continue
            tv = t["label"][f]

            def right(p):
                pv = p.get(f)
                if not IF.filled(f, pv):
                    return not IF.filled(f, tv)
                return IF.filled(f, tv) and IF.field_match(f, pv, tv, "ed2")
            ra, rb = right(a[t["id"]]), right(b[t["id"]])
            c["both" if ra and rb else "only_a" if ra else "only_b" if rb else "neither"] += 1
        d = dict(c)
        d["p"] = binom_two_sided(c["only_a"], c["only_a"] + c["only_b"])
        out[f] = d
    return out


# --- the report -------------------------------------------------------------------------------------------------

def build():
    ds = M.docs()
    by_id = {d["id"]: d for d in ds}
    found = arms()
    if not found:
        sys.exit("no unified replies in the bench cache")
    U = {}
    for arm in found:
        preds, unparsed, wall = load_arm(arm, ds)
        U[arm] = {"preds": preds, "unparsed": unparsed, "wall": wall,
                  "name": ARM_NAMES.get(arm, (arm, False))[0], "family": ARM_NAMES.get(arm, (arm, False))[1]}

    # entities, the 138
    truth = {r["id"]: r for r in ET.load_truth()}
    texts = {i: IR.doc_text(by_id[i])[:M.TEXT_CAP] for i in truth if i in by_id}
    shipped, ship_bad = P.preds("shipped", E8.CACHE)
    shipped_b, _ = P.preds("shipped-b", E8.CACHE)
    tag_ent = {i: tagging_entities(i) for i in truth if i in by_id}
    tag_ent = {i: v for i, v in tag_ent.items() if v is not None}
    ent = {"truth_docs": len(truth), "baselines": {
        "entity": {"label": ENTITY_LABEL, "answered": len(shipped), "unparsed": ship_bad,
                   "scores": EO.scores(shipped, truth), "evidence": P.evidence(shipped, truth, texts, E8.SHIPPED_CAP)},
        "tagging": {"label": TAGGING_LABEL, "answered": len(tag_ent), "scores": EO.scores(tag_ent, truth)}},
        "rerun_floor": {f: P.paired(shipped, shipped_b, sorted(set(shipped) & set(shipped_b) & set(truth)), truth, f)
                        for f in ET.FIELDS}, "arms": {}}
    for arm, a in U.items():
        pr = {i: ent_pred(js) for i, js in a["preds"].items() if i in truth and js is not None}
        ids = sorted(set(pr) & set(shipped) & set(truth))
        ent["arms"][arm] = {"answered": len(pr), "scores": EO.scores(pr, truth),
                            "evidence": P.evidence(pr, truth, texts, M.TEXT_CAP),
                            "paired_vs_entity": {f: P.paired(shipped, pr, ids, truth, f) for f in ET.FIELDS},
                            "paired_city_vs_entity": EO.paired_city(shipped, pr, truth)["city"],
                            "paired_vs_tagging": {f: P.paired(tag_ent, pr, sorted(set(pr) & set(tag_ent) & set(truth)),
                                                              truth, f) for f in ET.FIELDS}}

    # item fields, the 299
    rows, docs, key, answers, fixes = IFS.load()
    frows, _chk = IFS.fold(rows, key, answers, fixes)
    skip = {x["doc"] for x in json.load(open(IFS.RETRUTH_JSON, encoding="utf-8"))["counts"]["sideways"]}
    P_all = IFS.predictions(rows, docs)
    routes = [("draft-gemini", True), ("tagging", True)]
    for arm, a in U.items():
        P_all[arm] = {t["id"]: ({f: IFS.norm(f, v) for f, v in item_pred(a["preds"][t["id"]]).items()}
                                if a["preds"].get(t["id"]) is not None else None) for t in frows}
        routes.append((arm, a["family"]))
    scores, verdicts, strat, by_part = item_scores(P_all, frows, skip, routes)
    item = {"docs": len(frows), "sideways": len(skip), "routes": {rk: {"family": fam, "answered": sum(
        v is not None for v in P_all[rk].values())} for rk, fam in routes}, "scores": scores, "verdicts": verdicts,
        "stratified": strat, "by_part": by_part, "shipped_verdicts": {}, "paired": {}}
    try:
        shipped_json = json.load(open(IFS.RESULTS.replace(".md", ".json"), encoding="utf-8"))
        item["shipped_verdicts"] = {k: v for k, v in shipped_json["verdicts"].items()
                                    if k.split("|")[0] in ("draft-gemini", "tagging")}
    except (OSError, KeyError):
        pass
    for arm in U:
        item["paired"][arm] = {"vs_item": item_paired(P_all["draft-gemini"], P_all[arm], frows, skip),
                               "vs_tagging": item_paired(P_all["tagging"], P_all[arm], frows, skip)}

    # dates, the 299
    tags = IFS.owner_tags(docs)
    tag_dates = {d["id"]: tagging_date(d["id"]) for d in ds}
    tag_dates = {i: v for i, v in tag_dates.items() if v is not None}
    dates = {"tagged_docs": sum(1 for d in ds if d["id"] in tags),
             "classes": dict(collections.Counter(tags[d["id"]][2] for d in ds if d["id"] in tags)),
             "baselines": {"tagging": {"label": TAGGING_LABEL, "answered": len(tag_dates),
                                       "scores": date_scores(tag_dates, tags, ds)}}, "arms": {}}
    for arm, a in U.items():
        full = {i: date_pred(js) for i, js in a["preds"].items() if js is not None}
        pr = {i: v[:3] for i, v in full.items()}
        dates["arms"][arm] = {"answered": len(pr), "scores": date_scores(pr, tags, ds),
                              "paired_vs_tagging": date_paired(tag_dates, pr, tags, ds),
                              "evidence": date_evidence(full, ds)}

    # enclosure and subject tags
    encl, subj = {}, {}
    for arm, a in U.items():
        encl[arm] = enclosure_stats(a["preds"], ds)
        ns = [len(js.get("subject_tags") or []) for js in a["preds"].values() if js is not None]
        subj[arm] = {"docs": len(ns), "mean_tags": statistics.mean(ns) if ns else None,
                     "in_2_to_6": sum(2 <= n <= 6 for n in ns)}

    # cost and latency
    corr_share = len(truth) / len(ds)
    base_calls = {
        "tagging": ledger_means(os.path.join(IR.CACHE, "calls.jsonl"), lambda r: r.get("stage") == "tagging"),
        "trace": ledger_means(os.path.join(REHEARSAL, "date-route-pipeline", "calls.jsonl"),
                              lambda r: str(r.get("id", "")).startswith("trace")),     # the image pass's rows start "image"
        "entity": ledger_means(os.path.join(E8.CACHE, "calls.jsonl"), lambda r: r.get("arm") == "shipped"),
        "item": ledger_means(os.path.join(IR.CACHE, "calls.jsonl"), lambda r: r.get("stage") == "drafts/gemini")}
    pipe = json.load(open(os.path.join(HERE, "..", "..", "segbench-results", "date-route-pipeline.json"), encoding="utf-8")) \
        if os.path.exists(os.path.join(HERE, "..", "..", "segbench-results", "date-route-pipeline.json")) else {}
    shares = {"tagging": 1.0, "trace": 1.0, "entity": corr_share, "item": 1.0}
    base_cost = sum((base_calls[k] or {}).get("cost_mean", 0) * shares[k] for k in base_calls)
    base_wall = sum((base_calls[k] or {}).get("wall_mean", 0) * shares[k] for k in base_calls)
    cost = {"baseline": {"calls": base_calls, "shares": shares, "per_1000_usd": 1000 * base_cost,
                         "wall_s_per_doc_sequential": base_wall, "image_pass_share": IMAGE_PASS_SHARE,
                         "image_pass_note": "The image pass (prompts.md §9) is not in the sum: it is sent only where "
                                            "the own text has no year candidate, and this set's text route is the same "
                                            "under either design", "pipeline_results": pipe.get("cost") if isinstance(pipe, dict) else None},
            "arms": {}}
    for arm, a in U.items():
        led = ledger_means(os.path.join(MG.CACHE, "calls.jsonl"), lambda r, arm=arm: r.get("arm") == arm) \
            if arm == MG.ARM else None
        cost["arms"][arm] = {"ledger": led, "per_1000_usd": 1000 * led["cost_mean"] if led else (0.0 if "qwen" in arm else None),
                             "wall_s_per_doc": led["wall_mean"] if led else (statistics.mean(a["wall"]) if a["wall"] else None),
                             "wall_s_median": led["wall_median"] if led else (statistics.median(a["wall"]) if a["wall"] else None),
                             "spent_usd": MG.spent() if arm == MG.ARM else 0.0,
                             "key_spent_usd": MG.key_spent() if arm == MG.ARM else None}

    o = {"item": "W49.proc-metadata-consolidate", "date": datetime.date.today().isoformat(),
         "arms": {arm: {"name": a["name"], "answered": len(a["preds"]), "unparsed": a["unparsed"]} for arm, a in U.items()},
         "docs": len(ds), "parts": dict(collections.Counter(d["part"] for d in ds)), "entities": ent, "item_fields": item,
         "dates": dates, "enclosure": encl, "subject_tags": subj, "cost": cost,
         "price": {"usd_per_million": list(MG.price()), "note": "Gemini 3.8 Flash list price to 31 Dec 2026, a ceiling for the 3.7 calls"}}
    json.dump(o, open(RESULTS[:-3] + ".json", "w"), indent=1, sort_keys=True, default=str)
    open(RESULTS, "w").write(report(o))
    print(RESULTS)


def pct(k, n):
    return f"{100 * k / n:.1f}%" if n else "-"


def f2(x):
    return "-" if x is None else f"{x:.2f}"


def f3(x):
    return "-" if x is None else f"{x:.3f}"


def ci(p):
    return f"{p['diff']:+.3f} ({p['lo']:+.3f} to {p['hi']:+.3f}, n {p['n']})"


def report(o):
    L = [f"# One unified metadata call against the app's separate calls (W49.proc-metadata-consolidate, {o['date']})", "",
         "Generated by `scripts/segbench/metadata_unified_score.py`; method in its header. The prompt is "
         "`metadata_unified.PROMPT` (the frozen Sherlock pack's), on the Vision text of the item-field set's "
         f"{o['docs']} documents ({', '.join(f'{v} {k}' for k, v in sorted(o['parts'].items()))}) with three "
         "neighbours' openings and the rule dates. Figures are counts and shares; the texts and replies stay in the "
         "bench cache.", ""]
    L.append("## Arms")
    L.append("")
    L.append("| arm | documents answered | unparsed replies |")
    L.append("|---|---|---|")
    for arm, a in o["arms"].items():
        L.append(f"| {a['name']} | {a['answered']}/{o['docs']} | {a['unparsed']} |")
    L.append("")
    L.append("Baselines, the app's separate calls already in the bench cache on the same documents' Vision text: "
             f"{TAGGING_LABEL}; {ENTITY_LABEL}, correspondence only; {ITEM_LABEL}. The dating trace has no run on "
             "this set (its own set: `date-route-pipeline.md`).")
    L.append("")

    # entities
    e = o["entities"]
    L.append(f"## Entities, the {e['truth_docs']} correspondence documents (ed2 precision / recall / F1; the place by city)")
    L.append("")
    L.append("| route | n | sender P / R / F1 | recipient P / R / F1 | sending place P / R / F1 | place by city F1 |")
    L.append("|---|---|---|---|---|---|")

    def erow(name, s):
        cells = [f"{f3(s[f]['precision'])} / {f3(s[f]['recall'])} / {f3(s[f]['f1'])}" for f in ET.FIELDS]
        return f"| {name} | {s['n']} | " + " | ".join(cells) + f" | {f3(s['city']['f1'])} |"
    L.append(erow(e["baselines"]["entity"]["label"], e["baselines"]["entity"]["scores"]))
    L.append(erow(e["baselines"]["tagging"]["label"], e["baselines"]["tagging"]["scores"]))
    for arm, a in e["arms"].items():
        L.append(erow(o["arms"][arm]["name"], a["scores"]))
    L.append("")
    L.append("Paired F1 difference, unified minus the entity call, document bootstrap 95% interval; the rerun floor is "
             "the entity call against its own rerun:")
    L.append("")
    L.append("| comparison | sender | recipient | sending place | place by city |")
    L.append("|---|---|---|---|---|")
    L.append("| entity call rerun (floor) | " + " | ".join(ci(e["rerun_floor"][f]) for f in ET.FIELDS) + " | - |")
    for arm, a in e["arms"].items():
        L.append(f"| {o['arms'][arm]['name']} minus the entity call | " + " | ".join(ci(a["paired_vs_entity"][f]) for f in ET.FIELDS)
                 + f" | {ci(a['paired_city_vs_entity'])} |")
        L.append(f"| {o['arms'][arm]['name']} minus the tagging call | " + " | ".join(ci(a["paired_vs_tagging"][f]) for f in ET.FIELDS) + " | - |")
    L.append("")
    L.append("The sending place's full-string gap is mostly form: the unified prompt asks for the place as the document "
             "writes it (\"Oxford\", \"NEW YORK, N.Y.\", \"Stanford University, Cal.\") where the entity call's place rule "
             "and the truth normalise it (\"Oxford, England\", \"New York, NY\", \"Stanford, California\"); by city the "
             "gap is inside the interval.")
    L.append("")
    L.append("Evidence (named truth matches by the quote's state: right / wrong):")
    L.append("")
    L.append("| route | field | quote in text | quote not in text | no quote |")
    L.append("|---|---|---|---|---|")
    for name, ev in [(e["baselines"]["entity"]["label"], e["baselines"]["entity"]["evidence"])] + \
            [(o["arms"][arm]["name"], a["evidence"]) for arm, a in e["arms"].items()]:
        for f in ET.FIELDS:
            g = ev.get(f, {})
            cell = lambda k: f"{g.get(k, [0, 0])[0]} / {g.get(k, [0, 0])[1]}"  # noqa: E731
            L.append(f"| {name} | {f} | {cell('quote in text')} | {cell('quote not in text')} | {cell('no quote')} |")
    L.append("")

    # item fields
    it = o["item_fields"]
    L.append(f"## Item fields, the {it['docs']} documents ({it['sideways']} sideways documents left out)")
    L.append("")
    L.append("Owner-checked pairs: precision (ed2) over the pairs the route filled, the stratified figure a "
             "drafter-family route is judged on, and the fill verdict under item-fields-score's rule (fill at a lower "
             "bound of 0.85 and a point of 0.90 on at least 40 documents with a true value). The shipped verdict is "
             "item-fields-score.md's for the same route, where it has one.")
    L.append("")
    L.append("| route | field | owner-checked filled / right | precision | stratified (lo to hi) | verdict | shipped verdict | drafted: filled / right / truth filled |")
    L.append("|---|---|---|---|---|---|---|---|")
    for rk, r in it["routes"].items():
        name = {"draft-gemini": ITEM_LABEL, "tagging": TAGGING_LABEL}.get(rk) or o["arms"][rk]["name"]
        for f in IFS.FIELDS:
            so, sd = it["scores"][f"{rk}|owner|{f}"], it["scores"][f"{rk}|drafted|{f}"]
            st = it["stratified"].get(f"{rk}|{f}")
            stc = f"{st['precision']:.3f} ({st['lo']:.3f} to {st['hi']:.3f})" if st else "-"
            L.append(f"| {name} | {f} | {so['pred_filled']} / {so['ed2']} | {f3(so['precision_ed2'])} | {stc} | "
                     f"{it['verdicts'][f'{rk}|{f}']} | {it['shipped_verdicts'].get(f'{rk}|{f}', '-')} | "
                     f"{sd['pred_filled']} / {sd['ed2']} / {sd['truth_filled']} |")
    L.append("")
    L.append("Paired on the owner-checked pairs both routes answered (right: the ed2 match, or both empty), unified "
             "against the item-field call and against the tagging call, with the exact sign test's p:")
    L.append("")
    L.append("| arm | against | field | both | only unified | only the other | neither | p |")
    L.append("|---|---|---|---|---|---|---|---|")
    for arm, pr in it["paired"].items():
        for key, other in (("vs_item", "item-field call"), ("vs_tagging", "tagging call")):
            for f in IFS.FIELDS:
                c = pr[key][f]
                L.append(f"| {o['arms'][arm]['name']} | {other} | {f} | {c.get('both', 0)} | {c.get('only_b', 0)} | "
                         f"{c.get('only_a', 0)} | {c.get('neither', 0)} | {f3(c['p'])} |")
    L.append("")
    L.append("By part (drafted truth; filled / right / truth filled):")
    L.append("")
    L.append("| route | field | base | clippings | handwritten |")
    L.append("|---|---|---|---|---|")
    for rk in it["routes"]:
        name = {"draft-gemini": ITEM_LABEL, "tagging": TAGGING_LABEL}.get(rk) or o["arms"][rk]["name"]
        for f in IFS.FIELDS:
            cells = []
            for part in ("base", "clippings", "handwritten"):
                s = it["by_part"].get(f"{rk}|{part}|{f}")
                cells.append(f"{s['pred_filled']} / {s['ed2']} / {s['truth_filled']}" if s else "-")
            L.append(f"| {name} | {f} | " + " | ".join(cells) + " |")
    L.append("")

    # dates
    dt = o["dates"]
    L.append(f"## Dates, the {dt['tagged_docs']} documents with a year tag ({', '.join(f'{v} {k}' for k, v in sorted(dt['classes'].items()))})")
    L.append("")
    L.append("Against the owner's Finder tags on the first page. A false year is a wrong year written without Date "
             "Uncertain. Month where the owner tagged one.")
    L.append("")
    L.append("| route | n | year given | year exact | within one | false year | Date Uncertain | month given / exact (of tagged) |")
    L.append("|---|---|---|---|---|---|---|---|")

    def drow(name, s):
        n = s.get("docs", 0)
        return (f"| {name} | {n} | {pct(s.get('year_given', 0), n)} | {pct(s.get('year_exact', 0), n)} | "
                f"{pct(s.get('year_within_one', 0), n)} | {pct(s.get('false_year', 0), n)} | {pct(s.get('uncertain', 0), n)} | "
                f"{s.get('month_given', 0)} / {s.get('month_exact', 0)} (of {s.get('month_docs', 0)}) |")
    L.append(drow(dt["baselines"]["tagging"]["label"], dt["baselines"]["tagging"]["scores"]))
    for arm, a in dt["arms"].items():
        L.append(drow(o["arms"][arm]["name"], a["scores"]))
    L.append("")
    L.append("By truth class, year exact (Date Uncertain written):")
    L.append("")
    cls = sorted(dt["classes"])
    L.append("| route | " + " | ".join(cls) + " |")
    L.append("|---|" + "---|" * len(cls))
    for name, s in [(dt["baselines"]["tagging"]["label"], dt["baselines"]["tagging"]["scores"])] + \
            [(o["arms"][arm]["name"], a["scores"]) for arm, a in dt["arms"].items()]:
        cells = []
        for c in cls:
            b = s["by_class"].get(c, {})
            cells.append(f"{b.get('year_exact', 0)}/{b.get('docs', 0)} ({b.get('uncertain', 0)})")
        L.append(f"| {name} | " + " | ".join(cells) + " |")
    L.append("")
    L.append("Paired on the exact year against the tagging call, and the unified date's evidence (DateRoute.evidenceCheck's "
             "conditions: the quote is in the cited text and carries the year):")
    L.append("")
    for arm, a in dt["arms"].items():
        p = a["paired_vs_tagging"]
        ev = a["evidence"]
        yrs = sum(v for k, v in ev.items() if k.startswith("source_"))
        L.append(f"- **{o['arms'][arm]['name']}:** both right {p.get('both', 0)}, only unified {p.get('only_b', 0)}, "
                 f"only tagging {p.get('only_a', 0)}, neither {p.get('neither', 0)}; p {f3(p['p'])}. Years given {yrs}: "
                 f"from the document itself {ev.get('source_self', 0)}, from a neighbour {ev.get('source_neighbour', 0)} "
                 f"(Date Uncertain on {ev.get('neighbour_marked_uncertain', 0)} of them), other source {ev.get('source_other', 0)}; "
                 f"no year {ev.get('no_year', 0)}. Quote in the cited text {ev.get('quote_in_text', 0)}, carrying the year "
                 f"{ev.get('quote_has_year', 0)}, both {ev.get('evidence_valid', 0)} of {yrs}.")
    L.append("")

    # enclosure
    L.append("## Enclosure proposals (no truth on these documents: rates and cues)")
    L.append("")
    for arm, s in o["enclosure"].items():
        c = s["confidence"]
        L.append(f"- **{o['arms'][arm]['name']}:** of {s.get('docs', 0)} documents ({s.get('with_p1', 0)} with a P1), "
                 f"announces an enclosure {s.get('announces', 0)} (quote in the text {s.get('announces_quote_in_text', 0)}); "
                 f"sent with P1 {s.get('sent_with_previous', 0)} (quote in the text {s.get('sent_with_quote_in_text', 0)}); "
                 f"confidence median {f2(c['median'])}, at least 0.5 on {c['at_least_0.5']}, at least 0.9 on {c['at_least_0.9']}. "
                 "Cue words in the quotes: " + (", ".join(f"{k} {v}" for k, v in s["cues"].items()) or "none") + ".")
    L.append("")
    L.append("Subject tags (no truth; the prompt asks for 2 to 6): " + "; ".join(
        f"{o['arms'][arm]['name']} mean {f2(s['mean_tags'])} a document, in range on {s['in_2_to_6']} of {s['docs']}"
        for arm, s in o["subject_tags"].items()) + ".")
    L.append("")

    # cost
    c = o["cost"]
    L.append("## Cost and latency")
    L.append("")
    L.append(f"Prices: Gemini 3.8 Flash's list rate to 31 Dec 2026 (${o['price']['usd_per_million'][0]:.2f} / "
             f"${o['price']['usd_per_million'][1]:.2f} per million tokens, thinking as output), a ceiling for the 3.7 calls; "
             "where the gateway sent its own figure it is shown beside.")
    L.append("")
    L.append("| call | ledger calls | prompt tokens mean | cost a call (gateway's figure) | wall s mean / median | share of documents |")
    L.append("|---|---|---|---|---|---|")
    for k, v in c["baseline"]["calls"].items():
        if v:
            L.append(f"| {k} | {v['n']} | {v['prompt_mean']:.0f} | ${v['cost_mean']:.5f} ({'$' + format(v['gateway_cost_mean'], '.5f') if v['gateway_cost_mean'] is not None else '-'}) | "
                     f"{v['wall_mean']:.1f} / {v['wall_median']:.1f} | {c['baseline']['shares'][k]:.2f} |")
        else:
            L.append(f"| {k} | - | - | - | - | {c['baseline']['shares'][k]:.2f} |")
    for arm, v in c["arms"].items():
        led = v["ledger"]
        if led:
            L.append(f"| {o['arms'][arm]['name']} | {led['n']} | {led['prompt_mean']:.0f} | ${led['cost_mean']:.5f} | "
                     f"{led['wall_mean']:.1f} / {led['wall_median']:.1f} | 1.00 |")
        else:
            L.append(f"| {o['arms'][arm]['name']} | - | - | $0 (cluster) | {f2(v['wall_s_per_doc'])} / {f2(v['wall_s_median'])} | 1.00 |")
    L.append("")
    L.append(f"**Per 1,000 documents:** the separate calls about ${c['baseline']['per_1000_usd']:.2f} "
             f"({c['baseline']['wall_s_per_doc_sequential']:.1f} s of calls a document in sequence); " + "; ".join(
                 f"{o['arms'][arm]['name']} ${v['per_1000_usd']:.2f} ({f2(v['wall_s_per_doc'])} s a document)"
                 if v["per_1000_usd"] is not None else f"{o['arms'][arm]['name']} no ledger" for arm, v in c["arms"].items()) +
             f". {c['baseline']['image_pass_note']}.")
    for arm, v in c["arms"].items():
        if v["spent_usd"]:
            L.append(f"Spent on the {o['arms'][arm]['name']} arm: ${v['spent_usd']:.4f} (the personal key's total to "
                     f"1 Dec now ${v['key_spent_usd']:.4f} of $5).")
    L.append("")
    L.append("## Measurement card")
    L.append("")
    L.append("- **Truth.** Entities: W46.fix-ent-truth's 138, drafted by two frontier families and ruled by a third, with "
             "the owner's sheet answers and the sending-place rule folded (ent_truth.load_truth). Item fields: "
             "W47.item-fields-retruth's truth, drafted by Gemini 3.7 Flash and GPT 5.6 Luna on the page images with "
             "Gemini 3.7 ruling, four owner sheets folded; the Gemini arms are drafter-family routes and are judged on "
             "the owner-checked pairs (stratified), the 27B on the drafted truth. Dates: the owner's own Finder year and "
             "month tags. Enclosure and subject tags: no truth.")
    L.append("- **Selection.** The item-field set: 219 base documents (W46.fix-ent-truth's, drawn by format and text "
             "cues; 60 articles and reports by Gemini 3.8's format), 60 clippings and 20 handwritten documents by the "
             "owner's own tags. No ABBYY text and no tested route chose them for this item.")
    L.append("- **Comparison.** The same Vision text (the first 8 and last 2 pages) and the same neighbours for every "
             "arm of the unified call. The baselines are the app's own calls as the cache holds them, each on its own "
             "input (tagging 3,000 characters and 300 of each neighbour; the entity call 3,000 characters; the "
             "item-field call the page images and 16,000 characters) and its own model and thinking setting (3.7 on "
             "the gateway for tagging and item fields, 3.8 on AI Studio for the entity call and the unified call; "
             "the unified call at thinking low, the tagging and entity calls with no thinking setting, the item-field "
             "call at low). The gateway's 3.7 ties 3.8 on OCR (gateway_gemini's report) and the key answers 3.7 by "
             "the 3.8 model; still, this is one provider's family, and the lead models wait for the gateway.")
    L.append("- **Noise.** Entity and item-field pairs carry document-bootstrap intervals or the exact sign test; the "
             "entity call's rerun gives its floor. The unified Gemini arm ran once (the key's remaining allowance "
             "left no room for a rerun), so its own rerun floor is not measured; ent_8k_paired's rerun of the same "
             "model moved F1 by under 0.03 a field. A gap inside those floors is a tie.")
    L.append("- **Scope.** One text route (Apple Vision), one set, one Gemini model at one thinking setting; the "
             "dating trace was not run on this set, so the date comparison is against the tagging call's year, the "
             "app's year before the dating call. Nothing here measures the lead cloud models or a user's own "
             "collection; the Sherlock arm, when collected, adds the open model.")
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    build()
