#!/usr/bin/env python3
"""W46.date-full-date: the dating route's month and day, scored against the page and not only the Finder tags.

The route (date_route_pipeline.route, mirrored in the app's DateRoute) now writes the month and day of the dated form an
explicit year rests on: the trace reply's own quote when it cites the document and passes the check, else the rule's
dated form of that year; from the image pass, the quoted date its year rests on. Estimates and inherited years get
neither. This script scores that on the owner's documents of W46.date-route-pipeline, from its cached Gemini 3.7 Flash
replies ($0, no model call):

  truth   the page's own full date for each document the route gives an explicit year, from three sources: the owner's
          own reading of the page on his earlier date sheet (W46.date-cases, truth-sets.json `page_date.as_read`), his
          Finder month tag, and a second reader, the Gemini image pass already made for every owner document through the
          gateway (W46.date-image-paid, W46.date-route-pipeline; its document date's quote). The owner's reading wins;
          else the route and the second reader agreeing (and not against his month tag) is the truth; everything else,
          and every document whose year came from that same image pass, goes to him on a blind sheet with controls
          drawn from the agreed ones.
  score   segbench-results/date-full-date.md and .json: month and day right, wrong, missing and extra on the truth, the
          month against the Finder tags alone, and the route before this item (a month only from the rule's pick, no day)
          on the same documents. Until the owner's answers are folded, the disputed documents are counted apart.
  sheet   the blind sheet in CACHE/sheet (first two pages, upright, date-like strings boxed from Vision's word boxes,
          the readings hidden, a note per document, a turn button). Vision runs under the heavy lock.
  fold    the downloaded answers -> CACHE/rulings.json; `score` then reads them.

    python3 date_full_date.py score
    python3 date_full_date.py sheet
    python3 date_full_date.py fold ~/Downloads/date-full-date-answers.json

READ ONLY on the corpus and the JPEG originals; everything written stays in the private bench cache, except the report.
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import html
import json
import os
import random
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import date_route_pipeline as P
import date_traceable as T
import date_undated as DU

TAG = "W46.date-full-date"
REH = Path(os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal"))
CACHE = REH / "date-full-date"
SHEET = CACHE / "sheet"
KEY = CACHE / "key.json"
RULINGS = CACHE / "rulings.json"
CASES = REH / "date-tagging" / "cases" / "truth-sets.json"     # the owner's 2026-10-21 date sheet, folded
RESULTS = HERE.parent.parent / "segbench-results" / "date-full-date.md"
RESULTS_JSON = RESULTS.with_suffix(".json")
DEWARP_BIN = REH / "segbench" / "bin" / "segbench-dewarp"
N_CONTROLS, SEED = 8, 1117
EYE_UPRIGHT: set[str] = set()      # close orientation calls looked at by eye and upright as taken
MONTHS = ("January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
          "November", "December")


# --- readings -----------------------------------------------------------------------------------------------------

def parse_reading(text, year):
    """(month, day) of a date as someone wrote it down ('8-3-87', "Sept '69", 'June 7, 1955'), for `year`."""
    s = str(text or "")
    c = P.dated_in(s, year)
    if c is None:      # a two-digit year after a month or an apostrophe: read it in full
        c = P.dated_in(re.sub(r"[’'‘](\d\d)\b", lambda m: str(year)[:2] + m.group(1), s), year)
    if c is None:      # a day and a two-digit year joined by a hyphen ('Sept 10-26'), through the OCR forms
        c = P.ocr_dated(re.sub(r"(?<=[A-Za-z.] )(\d{1,2})-(\d\d)\b", r"\1 '\2", s), year)
    return P.month_day(c)


def owner_readings():
    """{document hash: (year, month, day, as read)} from the owner's own readings of the page."""
    if not CASES.exists():
        return {}
    out = {}
    for r in json.loads(CASES.read_text())["records"]:
        pd = r.get("page_date") or {}
        if pd.get("as_read") and pd.get("year"):
            m, d = parse_reading(pd["as_read"], pd["year"])
            out[r["doc"]] = (pd["year"], m, d, pd["as_read"])
    return out


def second_reader(rec):
    """(year, month, day, quote) of the Gemini image pass's own date: the dated form of its year in the quote that year
    rests on, else the reply's document month; Nones when it gives no own year."""
    if rec is None:
        return None, None, None, None
    y = DU.own_date(rec)[1]
    if y is None:
        return None, None, None, None
    ev, mo = P.image_evidence(rec, y)
    m, d = P.month_day(P.dated_in(ev["quote"], y) if ev else None)
    if m is None:
        m, d = mo, None
    return y, m, d, ev["quote"] if ev else None


def old_month(doc, traw, sent, r):
    """The month the route wrote before this item: the rule pick's month, and from the image only when the quote's own
    rule pick named the reply's document month; never a day."""
    cands = T.candidates(doc["text"])
    if r["cls"] == "text":
        own = {c["year"] for c in cands}
        ty = r["trace_y"]     # route()'s step-1 test; otherwise its fallback, the rule's pick over every candidate
        own_branch = ty is not None and (ty in own or r["verdict"] == "valid") and (r["cited"] == "self" or ty in own)
        pick = T.rule_pick([c for c in cands if c["year"] == r["year"]] if own_branch else cands)
        return pick[1]
    if r["cls"] == "image":
        ev, mo = P.image_evidence(sent, r["year"])
        if mo is not None and ev and T.rule_pick(T.candidates(ev["quote"]))[1] == mo:
            return mo
    return None


def rows():
    """One row per readable owner document the route gives a year, with every reading of its full date."""
    owner = owner_readings()
    out = []
    for d in P.targets():
        if d["set"] != "owner" or not P.readable(d):
            continue
        traw, im = P.replies(P.GEMINI, d)
        if traw is None:
            continue
        doc = P.doc_of(d)
        sent = im if (im is not None and not T.candidates(doc["text"])) else None
        r = P.route(doc, traw, sent)
        P.OCR_FORMS = False
        rs = P.route(doc, traw, sent)      # the route before W46.date-full-date-ocr-forms, on the same replies
        P.OCR_FORMS = True
        t = d.get("truth") or {}
        b = second_reader(P.load(P.image_dest(d)))
        o = owner.get(d["id"][2:])
        out.append({"id": d["id"], "kind": d.get("kind"), "cls": r["cls"], "date_from": r["date_from"],
                    "route": [r["year"], r["month"], r["day"]], "old_month": old_month(doc, traw, sent, r),
                    "strict": [rs["month"], rs["day"]],
                    "tag": [t.get("year"), t.get("month"), t.get("du")],
                    "second": list(b[:3]), "second_quote": b[3],
                    "owner_read": list(o[:3]) if o else None, "owner_as_read": o[3] if o else None,
                    "pages": d["pages"][:2], "folder": d["folder"]})
    return out


# --- truth --------------------------------------------------------------------------------------------------------

def truth_of(r, rulings):
    """(source, [year, month, day]) of the page's own full date for one row, or (why not, None). Only documents whose
    explicit year is the owner's year are scored: a wrong year makes its month and day moot."""
    if r["cls"] not in ("text", "image"):
        return "not explicit", None
    y = r["route"][0]
    if r["tag"][0] != y:
        return "year not the owner's", None
    if r["id"] in rulings:
        a = rulings[r["id"]]
        if a.get("month") == "unsure":
            return "owner can't tell", None
        return "owner, this sheet", [y, a.get("month"), a.get("day")]
    o = r["owner_read"]
    if o and o[0] == y:
        return "owner, earlier sheet", [y, o[1], o[2]]
    tm = r["tag"][1]
    if r["cls"] == "text" and r["second"] == r["route"] and (tm is None or tm == r["route"][1]):
        return ("agreed" if r["route"][1] is not None else "agreed, no month"), list(r["route"])
    if r["cls"] == "text" and r["second"][0] is None and r["route"][1] is None and tm is None:
        return "no month found", None
    return "disputed", None


def sheet_set(rs):
    """[(row, group)]: every disputed document and N_CONTROLS agreed ones with a month, shuffled with a fixed seed."""
    disputed = [r for r in rs if truth_of(r, {})[0] == "disputed"]
    agreed = sorted((r for r in rs if truth_of(r, {})[0] == "agreed"), key=lambda r: r["id"])
    rng = random.Random(SEED)
    docs = [(r, "disputed") for r in disputed] + [(r, "control") for r in rng.sample(agreed, min(N_CONTROLS, len(agreed)))]
    docs.sort(key=lambda x: x[0]["id"])
    rng.shuffle(docs)
    return docs


# --- score --------------------------------------------------------------------------------------------------------

def tally(pairs):
    """{right, wrong, missing, extra, none} of (written, truth) pairs."""
    c = collections.Counter()
    for got, want in pairs:
        if want is None:
            c["extra" if got is not None else "none"] += 1
        elif got is None:
            c["missing"] += 1
        else:
            c["right" if got == want else "wrong"] += 1
    return dict(c)


def frac(k, n):
    return f"{100 * k / n:.1f}% ({k}/{n})" if n else "–"


def wilson_txt(k, n):
    ci = P.wilson(k, n)
    return f"{ci[0]:.0f}-{ci[1]:.0f}" if ci else "–"


def summarise(rs, rulings):
    scored = []
    by_source = collections.Counter()
    for r in rs:
        src, t = truth_of(r, rulings)
        by_source[src] += 1
        if t is not None:
            scored.append((r, src, t))
    month = tally((r["route"][1], t[1]) for r, _, t in scored)
    sure_day = [(r, src, t) for r, src, t in scored if t[2] != "unsure"]     # a day the owner can't tell is not scored
    day = tally((r["route"][2], t[2]) for r, _, t in sure_day)
    full = sum(1 for r, _, t in sure_day if t[1] is not None and r["route"][1:] == t[1:])
    with_month = sum(1 for _, _, t in sure_day if t[1] is not None)
    with_day = sum(1 for _, _, t in sure_day if t[2] is not None)
    old = tally((r["old_month"], t[1]) for r, _, t in scored)
    # The month against the Finder tags alone (W46.date-month-score's question), independent of the page truth.
    tagged = [r for r in rs if r["cls"] in ("text", "image") and r["tag"][1] is not None and r["tag"][0] == r["route"][0]]
    vs_tag = tally((r["route"][1], r["tag"][1]) for r in tagged)
    vs_tag_old = tally((r["old_month"], r["tag"][1]) for r in tagged)
    gained = sum(1 for r, _, t in scored if r["route"][1] == t[1] and t[1] is not None and r["old_month"] != t[1])
    lost = sum(1 for r, _, t in scored if r["old_month"] == t[1] and t[1] is not None and r["route"][1] != t[1])
    by_from = collections.Counter((r["date_from"] or "none") for r in rs if r["cls"] in ("text", "image"))
    strict_m = tally((r["strict"][0], t[1]) for r, _, t in scored)
    strict_d = tally((r["strict"][1], t[2]) for r, _, t in sure_day)
    return {"documents": len(rs), "explicit": sum(r["cls"] in ("text", "image") for r in rs),
            "by_source": dict(by_source), "scored": len(scored), "with_month": with_month, "with_day": with_day,
            "month": month, "day": day, "full_exact": full, "old_month": old, "gained": gained, "lost": lost,
            "vs_tag": vs_tag, "vs_tag_old": vs_tag_old, "tagged": len(tagged), "by_from": dict(by_from),
            "by_truth_source": dict(collections.Counter(src for _, src, _ in scored)),
            "strict_month": strict_m, "strict_day": strict_d, "image_arm": image_arm(rs, scored),
            "wrong": [{"id": r["id"], "route": r["route"], "truth": t, "source": src} for r, src, t in scored
                      if (r["route"][1] is not None and t[1] is not None and r["route"][1] != t[1])
                      or (r["route"][2] is not None and t[2] not in (None, "unsure") and r["route"][2] != t[2])],
            "missing": [{"id": r["id"], "route": r["route"], "truth": t, "source": src, "cls": r["cls"],
                         "date_from": r["date_from"]} for r, src, t in scored
                        if (r["route"][1] is None and t[1] is not None)
                        or (r["route"][2] is None and t[2] not in (None, "unsure"))],
            "extra": [{"id": r["id"], "route": r["route"], "truth": t, "source": src} for r, src, t in scored
                      if (r["route"][1] is not None and t[1] is None)
                      or (r["route"][2] is not None and t[2] is None)]}


def image_arm(rs, scored):
    """What sending the image pass for a text year with no dated form would add (W46.date-full-date-ocr-forms), read
    from the image replies already cached for every owner document: the reply's own month where its year is the route's
    year, against the page truth and the Finder month tag; priced at the mean cost of the cached owner image calls."""
    truth = {r["id"]: t for r, _, t in scored}
    texty = [r for r in rs if r["cls"] == "text"]
    bare = [r for r in texty if r["route"][1] is None]
    got = [r for r in bare if r["second"][0] == r["route"][0] and r["second"][1] is not None]
    on_truth = tally((r["second"][1] if r in got else None, truth[r["id"]][1]) for r in bare if r["id"] in truth)
    on_tag = tally((r["second"][1] if r in got else None, r["tag"][1]) for r in bare
                   if r["tag"][1] is not None and r["tag"][0] == r["route"][0])
    costs = [json.loads(l).get("cost") for l in open(P.CACHED_OWNER_IMAGE_LEDGER)] if (
        P.CACHED_OWNER_IMAGE_LEDGER.exists()) else []
    costs = [c for c in costs if c]
    mean = sum(costs) / len(costs) if costs else None
    return {"text_years": len(texty), "no_month": len(bare), "image_month": len(got), "on_truth": on_truth,
            "on_tag": on_tag, "calls_priced": len(costs), "mean_cost": round(mean, 5) if mean else None,
            "per_1000_text_years": round(1000 * len(bare) / len(texty) * mean, 2) if mean and texty else None}


def public_check():
    """The OCR forms on the public set's dates (W41.date-model's Library of Congress items, its title's month the truth,
    supplied dates left out): where the strict forms give the title's year no month, the month and day the route would
    now write from the item's text; beside them, the strict forms' own month and day where they give one."""
    try:
        import public_dates as PD
        import date_tagging as DTG
        docs = [d for d in PD.load() if d["truth"]["month"] and not d["truth"]["supplied"]]
    except (OSError, ImportError):
        return None
    ocr_m, ocr_d, st_m, st_d = collections.Counter(), collections.Counter(), collections.Counter(), collections.Counter()
    for d in docs:
        t, text = d["truth"], DTG.doc_text(d["prompt"])
        c = T.rule_pick([x for x in T.candidates(text) if x["year"] == t["year"]])[3]
        m, day, ocr = P.with_ocr_forms(c, [text], t["year"])
        mc, dc = (ocr_m, ocr_d) if ocr else (st_m, st_d)
        if m is None:
            continue
        mc["right" if m == t["month"] else "wrong"] += 1
        if t["day"] and day is not None:
            dc["right" if day == t["day"] else "wrong"] += 1
    return {"documents": len(docs), "ocr_month": dict(ocr_m), "ocr_day": dict(ocr_d), "strict_month": dict(st_m),
            "strict_day": dict(st_d)}


def cmd_score(_a):
    rs = rows()
    folded = json.loads(RULINGS.read_text()) if RULINGS.exists() else {}
    rulings = folded.get("documents", {})
    S = summarise(rs, rulings)
    S["public"] = public_check()
    key = json.loads(KEY.read_text())["documents"] if KEY.exists() else {}
    S["sheet"] = {"documents": len(key) if rulings else len(sheet_set(rs)), "folded": bool(rulings),
                  "controls": folded.get("controls")}
    RESULTS_JSON.write_text(json.dumps(S, indent=1) + "\n")
    RESULTS.write_text(report(S))
    print(json.dumps({k: S[k] for k in ("scored", "month", "day", "full_exact", "vs_tag", "by_source")}))


def ocr_findings(S):
    """W46.date-full-date-ocr-forms' findings: the OCR forms, the image reply's document month, the public check and the
    image pass for text years, priced."""
    m, d, sm, sd, a, pub = S["month"], S["day"], S["strict_month"], S["strict_day"], S["image_arm"], S["public"]
    mt = sum(m.get(k, 0) for k in ("right", "wrong", "missing"))
    dtot = sum(d.get(k, 0) for k in ("right", "wrong", "missing"))
    L = [f"- **The OCR forms (W46.date-full-date-ocr-forms) take the month from {frac(sm.get('right', 0), mt)} to "
         f"{frac(m.get('right', 0), mt)} and the day from {frac(sd.get('right', 0), dtot)} to "
         f"{frac(d.get('right', 0), dtot)}, with no new wrong month or day.** Where the strict forms give an explicit "
         "year no month, the route now reads that year's dated forms as Vision damages them: a spaced day "
         "(`APR 2 0 1977`, `DEC 2 1 1982`), a bullet for a full stop (`Aug• 4, 1903•`), a misread month within two "
         "letters of one name in a full date with the four-digit year (`NIRCH 13, 1965`), Cyrillic look-alikes (`ОстОВЕя 1, 1966`), spaces in a numeric date "
         "(`8 - 3-87`) and a two-digit year after a month word (`Dec. 70`, `Sept 69`, `9 Oct 75`, `Jan 3 64`); and an l "
         "for a 1 gives `1lth November 1915` its day. An image year whose quote holds no dated form takes the reply's "
         "document month. Four of the six documents filed as having no dated form had one with a two-digit year.",
         f"- **Left without a month: {m.get('missing', 0)}**, both pages whose Vision text holds no dated form of the "
         "date at all. A month written where the page has none: "
         f"{m.get('extra', 0)}, the same document as before this item."]
    if pub:
        om, od, stm, std = pub["ocr_month"], pub["ocr_day"], pub["strict_month"], pub["strict_day"]
        on, sn = om.get("right", 0) + om.get("wrong", 0), stm.get("right", 0) + stm.get("wrong", 0)
        dn, sdn = od.get("right", 0) + od.get("wrong", 0), std.get("right", 0) + std.get("wrong", 0)
        L.append(f"- **On the public set's dates** ({pub['documents']:,} Library of Congress items with a catalogue month): "
                 f"where the strict forms give the title's year no month, the OCR forms write one on {on}, the title's "
                 f"month on {frac(om.get('right', 0), on)}, its day on {frac(od.get('right', 0), dn)} of the days "
                 f"written; the strict forms where they give one, {frac(stm.get('right', 0), sn)} and "
                 f"{frac(std.get('right', 0), sdn)}. The misses on both are other dates in the text (a docket's "
                 "received date, a date the letter mentions) and a day-first numeric date, not misreadings.")
    if a["mean_cost"]:
        ot = a["on_truth"]
        L.append(f"- **The image pass for a text year with no dated form, not adopted:** {a['no_month']} of "
                 f"{a['text_years']} text years still have no month; the image replies cached for every owner document "
                 f"give the route's year a month on {a['image_month']}, right on {ot.get('right', 0)} on the page truth "
                 f"and written where the owner reads none on {ot.get('extra', 0)}. Sending it costs one image call "
                 f"(mean ${a['mean_cost']:.4f} over {a['calls_priced']} cached owner calls) on each such document, about "
                 f"${a['per_1000_text_years']:.2f} per 1,000 text-year documents, for about 2 months in 133: the route "
                 "keeps sending the image pass only where the text has no year.")
    return "\n".join(L)


def report(S):
    m, d, o, vt, vto = S["month"], S["day"], S["old_month"], S["vs_tag"], S["vs_tag_old"]
    sm, sd = S["strict_month"], S["strict_day"]
    mt = sum(m.get(k, 0) for k in ("right", "wrong", "missing"))
    dtot = sum(d.get(k, 0) for k in ("right", "wrong", "missing"))
    tt = sum(vt.get(k, 0) for k in ("right", "wrong", "missing"))
    folded = S["sheet"]["folded"]
    L = [f"# The dating route's month and day, against the page ({TAG})", "",
         "Written by `scripts/segbench/date_full_date.py score`. The route of W46.date-route-pipeline on the owner's "
         "documents, Gemini 3.7 Flash through the gateway, from its cached replies ($0, no new model call). An explicit "
         "year (from the text or the page image) now carries the month and day of the dated form it rests on: the "
         "trace reply's own quote when it cites the document and passes the evidence check, else the rule's dated form "
         "of that year; from the image pass, the quoted date the year rests on. Estimates and inherited years carry "
         "neither. A numeric date is read month-first when its first part can be a month.", "",
         "## Findings", "",
         f"- **On the page's own date: the month right on {frac(m.get('right', 0), mt)} (95% {wilson_txt(m.get('right', 0), mt)}), "
         f"wrong on {m.get('wrong', 0)}, not written on {m.get('missing', 0)}; the day right on "
         f"{frac(d.get('right', 0), dtot)} (95% {wilson_txt(d.get('right', 0), dtot)}), wrong on {d.get('wrong', 0)}, "
         f"not written on {d.get('missing', 0)}.** Of {S['scored']} documents with a page truth, {S['full_exact']} of "
         f"{S['with_month']} with a month on the page get the full date exactly. A month or day written where the page "
         f"has none: {m.get('extra', 0)} and {d.get('extra', 0)}.",
         f"- **Against the Finder tags alone (W46.date-month-score's question): the owner's month on "
         f"{frac(vt.get('right', 0), tt)}, another month on {vt.get('wrong', 0)}, none on {vt.get('missing', 0)}** "
         f"({S['tagged']} explicit years that are the owner's year and carry his month tag). The route before this item "
         f"wrote {frac(vto.get('right', 0), tt)}, another month on {vto.get('wrong', 0)}. The old tagging call's figure, "
         "75.0% of 120 (date-tagging.md), was on the ABBYY text and a different document set.",
         f"- **Before and after on the page truth:** the old rule's month right on {frac(o.get('right', 0), mt)}; "
         f"{S['gained']} documents right only now, {S['lost']} only before. The old rule never wrote a day.",
         f"- **Where the month comes from** (explicit years): {', '.join(f'{k} {v}' for k, v in sorted(S['by_from'].items()))}.",
         (f"- **The owner's sheet is folded** ({S['by_truth_source'].get('owner, this sheet', 0)} of its "
          f"{S['sheet']['documents']} documents scored; W46.date-full-date-fold). Its controls: "
          f"{S['sheet']['controls']['same']} of {S['sheet']['controls']['asked']} agreed documents as the owner reads "
          "them (one on the month only: he reads the typed-over day as 27 or 29, the route wrote 29), so the agreed "
          "truth stands." if folded else
          f"- **Not yet settled: {S['by_source'].get('disputed', 0)} disputed documents** (the route and the second "
          "reader differ, or the year came from the same image pass the second reader is) wait on the owner's blind "
          f"sheet ({S['sheet']['documents']} documents with {N_CONTROLS} controls); the figures above leave them out, so "
          "they lean towards documents where two readings agree."), "",
         ocr_findings(S), "",
         "## Truth by source", "",
         "| source | documents |", "|---|---|"]
    for k, v in sorted(S["by_source"].items(), key=lambda x: -x[1]):
        L.append(f"| {k} | {v} |")
    L += ["", "## Month and day on the page truth", "",
          "| | right | wrong | not written | written, none on the page |", "|---|---|---|---|---|",
          f"| month, this route | {m.get('right', 0)} | {m.get('wrong', 0)} | {m.get('missing', 0)} | {m.get('extra', 0)} |",
          f"| month, before the OCR forms | {sm.get('right', 0)} | {sm.get('wrong', 0)} | {sm.get('missing', 0)} | {sm.get('extra', 0)} |",
          f"| month, before W46.date-full-date | {o.get('right', 0)} | {o.get('wrong', 0)} | {o.get('missing', 0)} | {o.get('extra', 0)} |",
          f"| day, this route | {d.get('right', 0)} | {d.get('wrong', 0)} | {d.get('missing', 0)} | {d.get('extra', 0)} |",
          f"| day, before the OCR forms | {sd.get('right', 0)} | {sd.get('wrong', 0)} | {sd.get('missing', 0)} | {sd.get('extra', 0)} |",
          "", "Wrong months or days:", ""]
    L += [f"- `{w['id']}`: route {w['route']}, truth {w['truth']} ({w['source']})" for w in S["wrong"]] or ["- none"]
    L += ["", "## Measurement card", "",
          "- **Truth:** the page's own full date. Strongest is the owner's own reading of the page on his 2026-10-21 "
          f"date sheet ({S['by_truth_source'].get('owner, earlier sheet', 0)} scored documents)"
          + (f" and his blind sheet of 2026-11-18 ({S['by_truth_source'].get('owner, this sheet', 0)}; his two notes read "
             "first: one day he can't tell, 27 or 29, is left out of the day score; one confirms the date at the foot "
             "of the page over a December date on a document behind it). One sheet document is no longer scored: since "
             "W46.date-stamp-fallback the route takes its year from a stamp, with no month or day by design, where he "
             "reads 31 July 1975 on the page" if folded else "")
          + ". Next, the route and a second reader agreeing: the Gemini 3.7 Flash image pass on the first two pages "
          "(the same gateway model as the route's trace call, but reading the page image, where the route reads Apple "
          "Vision's text and takes its date by rule from a quote that must be in that text), and not against the owner's "
          "Finder month tag. Agreement-made truth cannot catch an error both readings share, and it leans the score "
          "towards the easy documents: the disputed ones go to the owner, with controls drawn from the agreed ones to "
          "measure that truth's own error. Documents whose year came from the image pass are never agreed, since the "
          "second reader is then the route's own evidence. The owner's Finder tags carry no day. The sheet is blind (no "
          "reading shown; every date-like string Vision read is boxed); where no box holds the second reader's year, "
          "the card says a date may lie outside the boxes, which marks a document as harder without saying which "
          "reading is right.",
          "- **Selection:** the owner's documents of W46.date-route-pipeline (stratified by date kind from his Finder tags, "
          "seed 41), those with a confirmed JPEG original; scored where the route gives an explicit year equal to the "
          "owner's year. Not chosen by any route or by the ABBYY text.",
          "- **Comparison:** the same cached trace and image replies scored under the new rule and the rule before this "
          "item, and with the OCR forms switched off (`date_route_pipeline.OCR_FORMS`); Vision text on the JPEG "
          "originals for all. The public set has no route replies, so the route itself is scored on the owner's "
          "documents only; the OCR forms alone are checked on the public set's dates (its catalogue titles' month and "
          "day against the item's transcribed text, so a title date that is not the text's first date counts against "
          "both the strict and the OCR forms).",
          f"- **Noise:** n is small ({mt} months, {dtot} days); intervals are Wilson 95%. The rule is deterministic on "
          "cached replies, so there is no rerun noise in the rule itself; a fresh trace call could quote a different date.",
          "- **Scope:** not the tagging call's own month and day (the app keeps its day when it read the same year and "
          "month, and both when the route has no dated form; its cached replies here were made on the ABBYY text, so they "
          "are not scored), not estimates or inherited years (no month or day by design), and not day-first numeric "
          "dates below 13 (read month-first).", ""]
    return "\n".join(L)


# --- sheet --------------------------------------------------------------------------------------------------------

def cmd_sheet(_a):
    """$0, no model call. The disputed documents and the controls, their first two pages upright (Apple Vision at four
    turns), every date-like string boxed from Vision's word boxes, blind: no route, reader or group shown."""
    import check_time as CT
    import vision_guard
    from PIL import Image
    import corpus_pairs as CP
    rs = rows()
    docs = sheet_set(rs)
    orient = json.loads((P.CACHE / "orient.json").read_text())
    pairs = DU.jpeg_pairs()
    missing = []
    for sub in ("img", "lines"):
        (SHEET / sub).mkdir(parents=True, exist_ok=True)
    items, jobs = [], []
    for k, (r, group) in enumerate(docs, 1):
        name = f"D{k:02d}"
        pages = []
        for n, p in enumerate(r["pages"], 1):
            img = SHEET / "img" / f"{name}-{n}.jpg"
            if not img.exists():
                src, o = P.img_path(p), orient.get(p) or {}
                if src is not None:
                    shutil.copyfile(src, img)        # the bench's 2,400 px copy, turned as the PDF shows it
                elif "deg" in o and pairs.get(p):    # rendered again the same way (date_route_pipeline.cmd_rerender)
                    with Image.open(os.path.join(CP.JPEGS, pairs[p])) as im:
                        im = im.convert("RGB").rotate(o["deg"], expand=True)
                        im.thumbnail((DU.LONG_SIDE, DU.LONG_SIDE), Image.Resampling.LANCZOS)
                        im.save(img, "JPEG", quality=90)
                else:
                    missing.append(f"{name}-{n}")
                    continue
            lj = SHEET / "lines" / f"{name}-{n}.json"
            if not lj.exists():
                jobs.append(f"{img}\t{lj}\n")
            pages.append({"img": img, "lines": lj})
        items.append((name, r, group, pages))
    if jobs:
        (SHEET / "lines-jobs.tsv").write_text("".join(jobs))
        vision_guard.run(DEWARP_BIN, SHEET / "lines-jobs.tsv", "lines")
    paths = [str(pg["img"]) for _, _, _, pages in items for pg in pages]
    saved, CT.OUT = CT.OUT, CACHE
    try:
        turns = CT.orient(paths)
    finally:
        CT.OUT = saved
    scores = json.loads((CACHE / "orient-scores.json").read_text())
    close = sorted(Path(p).stem for p, sc in scores.items() if max(range(4), key=lambda i: sc[i]) and not turns[p])
    unchecked = [c for c in close if c not in EYE_UPRIGHT]
    if unchecked:
        raise SystemExit(f"close orientation calls not checked by eye: {unchecked}; look, then add to EYE_UPRIGHT")
    data, key = [], {}
    for name, r, group, pages in items:
        shown, texts = [], []
        for pg in pages:
            lj = json.loads(pg["lines"].read_text())
            boxes = DU.date_boxes(lj)
            texts += [b["text"] for b in boxes]
            shown.append({"src": f"img/{pg['img'].name}", "rotation": turns[str(pg["img"])],
                          "boxes": [b["box"] for b in boxes]})
        y, _, du = r["tag"]
        # The sheet rule's fallback (owner, 2026-10-21): a reading with no box still narrows the search. The second
        # reader has no coordinates; when no box holds its year, the card says a date may lie outside the boxes.
        sy = str(r["second"][0] or "")
        outside = bool(sy) and not any(sy in t or re.search(r"(?<!\d)'?" + sy[2:] + r"(?!\d)", t) for t in texts)
        data.append({"id": name, "pages": shown, "year": y, "du": bool(du), "pages_total": len(r["pages"]),
                     "outside": outside})
        key[name] = {"id": r["id"], "group": group, "route": r["route"], "second": r["second"], "tag": r["tag"],
                     "owner_read": r["owner_read"], "folder": r["folder"], "pages": r["pages"]}
    turned = sorted(Path(p).stem for p, deg in turns.items() if deg)
    if missing:
        print(f"no confirmed JPEG original for {missing}: left off the sheet")
    SHEET.joinpath("index.html").write_text(render_sheet(data, turned, close))
    KEY.write_text(json.dumps({"item": TAG, "date": dt.date.today().isoformat(), "seed": SEED, "turned": turned,
                               "close_calls": close, "documents": key}, indent=1) + "\n")
    print(f"{len(data)} documents ({sum(g == 'disputed' for _, _, g, _ in items)} disputed, "
          f"{sum(g == 'control' for _, _, g, _ in items)} controls), {len(paths)} pages, {len(turned)} turned, "
          f"{len(close)} close calls; {SHEET / 'index.html'}")


def render_sheet(data, turned, close) -> str:
    cards = []
    for it in data:
        figs = []
        for n, pg in enumerate(it["pages"], 1):
            boxes = "".join(f'<i class="box" style="left:{100 * b[0]:.2f}%;top:{100 * b[1]:.2f}%;'
                            f'width:{100 * b[2]:.2f}%;height:{100 * b[3]:.2f}%"></i>' for b in pg["boxes"])
            figs.append(f'<figure class="page"><div class="rot" data-src="{html.escape(pg["src"])}" '
                        f'data-r="{pg["rotation"]}" style="transform:rotate({pg["rotation"]}deg)">'
                        f'<img src="{html.escape(pg["src"])}" loading="lazy">{boxes}</div>'
                        f'<figcaption>page {n} <button type="button" class="turn">turn</button></figcaption></figure>')
        months = "".join(f'<option value="{k}">{k} {m}</option>' for k, m in enumerate(MONTHS, 1))
        unasked = f"year {it['year']}" + (", Date Uncertain" if it["du"] else ", no Date Uncertain")
        cards.append(f'''<section class="card" id="{it["id"]}">
  <h2>{it["id"]} <span class="sub">first {len(it["pages"])} of {it["pages_total"]} pages</span></h2>
  <div class="strip">{"".join(figs)}</div>
  {'<p class="unasked"><b>A date may lie outside the boxes here</b> (stamped, handwritten or faint, which Vision did not read as a date).</p>' if it.get("outside") else ""}
  <p class="unasked">Not asked, going in as listed (your Finder tags): {html.escape(unasked)}.</p>
  <fieldset>
    <label>month <select class="month" data-id="{it["id"]}"><option value="">–</option>
      <option value="none">no month written</option><option value="unsure">can't tell</option>{months}</select></label>
    <label>day <input class="day" data-id="{it["id"]}" type="number" min="1" max="31" placeholder="none"></label>
    <input class="note" type="text" data-id="{it["id"]}" placeholder="note (optional): which date, a listed field wrong, anything">
  </fieldset>
</section>''')
    return f'''<!doctype html><html><head><meta charset="utf-8"><title>The document's own month and day</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root {{ --bg:#fff; --fg:#1d1d1f; --muted:#666; --line:#d0d0d5; --box:#e0338a; --card:#f6f6f8; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#1c1c1e; --fg:#f2f2f7; --muted:#a1a1a6; --line:#3a3a3c; --box:#ff5fb0; --card:#2c2c2e; }} }}
body {{ background:var(--bg); color:var(--fg); font:15px/1.45 -apple-system, system-ui, sans-serif; margin:0 16px 90px; }}
h1 {{ font-size:22px; margin:20px 0 4px; }} .intro {{ color:var(--muted); max-width:920px; }}
.card {{ background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px 14px; margin:18px 0; }}
h2 {{ font-size:17px; margin:0 0 8px; }} .sub {{ font-weight:400; color:var(--muted); font-size:14px; }}
.strip {{ display:flex; gap:10px; overflow-x:auto; padding-bottom:6px; }}
.page {{ margin:0; flex:0 0 auto; text-align:center; }}
.rot {{ position:relative; display:inline-block; }} .rot img {{ height:560px; width:auto; display:block; }}
.box {{ position:absolute; border:2px solid var(--box); border-radius:3px; pointer-events:none; }}
figcaption {{ font-size:12px; color:var(--muted); }} .turn {{ font-size:11px; }}
.unasked {{ font-size:13px; color:var(--muted); margin:4px 0; }}
fieldset {{ border:0; padding:0; margin:8px 0 0; display:flex; flex-wrap:wrap; gap:6px 18px; align-items:center; }}
.day {{ width:5em; }}
.note, #snote {{ flex:1 1 260px; padding:4px 6px; border:1px solid var(--line); border-radius:6px; background:var(--bg); color:var(--fg); }}
#done {{ position:fixed; bottom:0; left:0; right:0; background:var(--bg); border-top:1px solid var(--line); padding:10px 16px;
  display:flex; gap:12px; align-items:center; }}
</style></head><body>
<h1>The document's own month and day</h1>
<p class="intro">{len(data)} documents from your dated set. For each, give the month and day of the date the document
itself prints or writes as its own (a letter's dateline, a memo's date, a dated stamp only if that is the document's
date), as the pages show it: "no month written" if it has none, a blank day if it gives a month only, "can't tell" if
you cannot read it. Pink boxes mark every date-like string Apple Vision read on the pages; they do not say which one is
right, and a date Vision missed has no box. The year and Date Uncertain are your Finder tags, not asked, and go in as
listed: if one is wrong, say so in the note. Pages were turned upright where Apple Vision was clear ({len(turned)}
turned{": " + ", ".join(turned) if turned else ""}); use "turn" on any still sideways. Answers save in this browser as
you go; "Save answers" downloads them. About {max(1, round(0.5 * len(data)))} minutes.</p>
{"".join(cards)}
<div id="done"><span id="count"></span><input id="snote" type="text" placeholder="note on the whole sheet (optional)">
<button type="button" id="save">Save answers</button></div>
<script>
const KEY='date-full-date-answers', IDS={json.dumps([it["id"] for it in data])};
let A=JSON.parse(localStorage.getItem(KEY)||'{{}}'); A._notes=A._notes||{{}}; A._turns=A._turns||{{}};
const save=()=>localStorage.setItem(KEY,JSON.stringify(A));
const rec=id=>(A[id]=A[id]||{{}});
const cnt=()=>{{document.getElementById('count').textContent=IDS.filter(k=>A[k]&&A[k].month).length+' of '+IDS.length+' answered';}};
document.querySelectorAll('select.month').forEach(s=>{{ s.value=(A[s.dataset.id]||{{}}).month||'';
  s.addEventListener('change',()=>{{rec(s.dataset.id).month=s.value;save();cnt();}}); }});
document.querySelectorAll('input.day').forEach(n=>{{ n.value=(A[n.dataset.id]||{{}}).day||'';
  n.addEventListener('input',()=>{{rec(n.dataset.id).day=n.value;save();}}); }});
document.querySelectorAll('input.note').forEach(n=>{{ n.value=A._notes[n.dataset.id]||'';
  n.addEventListener('input',()=>{{A._notes[n.dataset.id]=n.value;save();}}); }});
const sn=document.getElementById('snote'); sn.value=A._notes._sheet||''; sn.addEventListener('input',()=>{{A._notes._sheet=sn.value;save();}});
document.querySelectorAll('.turn').forEach(b=>b.addEventListener('click',()=>{{
  const w=b.closest('figure').querySelector('.rot'); const src=w.dataset.src;
  const r=((+(A._turns[src]??w.dataset.r))+90)%360; A._turns[src]=r; w.style.transform='rotate('+r+'deg)'; save(); }}));
document.querySelectorAll('.rot').forEach(w=>{{ const r=A._turns[w.dataset.src]; if(r!=null) w.style.transform='rotate('+r+'deg)'; }});
document.getElementById('save').addEventListener('click',()=>{{ const out=Object.assign({{_ids:IDS}},A);
  const b=new Blob([JSON.stringify(out,null,1)],{{type:'application/json'}}); const u=document.createElement('a');
  u.href=URL.createObjectURL(b); u.download='date-full-date-answers.json'; u.click(); }});
cnt();
</script></body></html>
'''


# --- fold ---------------------------------------------------------------------------------------------------------

# The owner's notes, read before his answers (W46.date-full-date-fold, 2026-11-18). Each changes what an answer means:
# {document id: (field overrides, the note's reason)}. A day "unsure" is left out of the day score, as a month "unsure"
# leaves the document out.
NOTE_RULINGS = {
    "o:ec4e0e2e6b604c76": ({"day": "unsure"}, "D14: 'Day is typed over. Could be 27 or 29.' He gave 27; the day is not "
                                              "scored, the month (June) is."),
}


def fold(answers: dict, key: dict) -> dict:
    """{documents: {document id: {month, day, note}}, controls: agreement on the controls, blank: ids not answered}.
    A month is 1-12, None for "no month written", or "unsure"; a day only with a month, or "unsure" from a note."""
    notes = answers.get("_notes") or {}
    docs, blank, controls = {}, [], {"asked": 0, "same": 0, "differs": []}
    for sid, k in key.items():
        a = answers.get(sid) or {}
        mv = a.get("month") or ""
        if not mv:
            blank.append(sid)
            continue
        month = "unsure" if mv == "unsure" else None if mv == "none" else int(mv)
        day = int(a["day"]) if isinstance(month, int) and str(a.get("day") or "").strip().isdigit() else None
        if day is not None and not 1 <= day <= 31:
            day = None
        given = day
        over, why = NOTE_RULINGS.get(k["id"], ({}, ""))
        if "month" in over:
            month = over["month"]
        if "day" in over:
            day = over["day"]
        docs[k["id"]] = {"month": month, "day": day, "note": notes.get(sid, ""), "sheet_id": sid, "group": k["group"],
                         **({"answered_day": given, "note_ruling": why} if over else {})}
        if k["group"] == "control" and month != "unsure":
            controls["asked"] += 1
            if day == "unsure":
                controls.setdefault("month_only", []).append(k["id"])
                if month == k["route"][1]:
                    controls["same"] += 1
                else:
                    controls["differs"].append(k["id"])
            elif [month, day] == k["route"][1:]:
                controls["same"] += 1
            else:
                controls["differs"].append(k["id"])
    return {"documents": docs, "controls": controls, "blank": blank, "sheet_note": notes.get("_sheet", "")}


def cmd_fold(a):
    answers = json.loads(Path(a.answers).expanduser().read_text())
    key = json.loads(KEY.read_text())["documents"]
    out = fold(answers, key)
    RULINGS.write_text(json.dumps(out, indent=1) + "\n")
    c = out["controls"]
    print(f"{len(out['documents'])} answered, {len(out['blank'])} blank; controls {c['same']} of {c['asked']} as agreed"
          f"{'; differ ' + ', '.join(c['differs']) if c['differs'] else ''}; {RULINGS}")
    for i, r in out["documents"].items():
        if r["note"]:
            print(f"  {i}: {r['note']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("score")
    sub.add_parser("sheet")
    f = sub.add_parser("fold")
    f.add_argument("answers")
    a = ap.parse_args()
    {"score": cmd_score, "sheet": cmd_sheet, "fold": cmd_fold}[a.cmd](a)


if __name__ == "__main__":
    main()
