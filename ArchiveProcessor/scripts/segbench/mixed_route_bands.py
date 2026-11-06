#!/usr/bin/env python3
"""W46.mixed-route's results by handwriting band, with time and cost (W46.mixed-route-bands).

  <lab venv>/bin/python mixed_route_bands.py report     # segbench-results/mixed-route-bands.{json,md}

The bands are mixed-def-score.md's four (owner, 2026-10-28): a signature, initials or handwritten date only; under
about 10 words; about 10-29 words; 30 or more. Each page's band is taken from the owner core (MRK-1), not from the
Qwen3.6-27B pre-flag band the B-core was drawn by: the words of its owner-reviewed handwritten marks (annotations and
marginal notes; stamps and "other" marks are not handwriting), a page whose handwriting is signatures, initials or
date-only texts falling in the first band. A page with a handwritten mark the owner left unread has no known word
count and is reported apart. The pre-flag band is set against it (the guessed-against-true agreement).

Per band and route: marks read (mixed_route.py's whole-page and owner's-box scores, unchanged), seconds a page from
the runs' own receipts, and output tokens a page (what a paid route's price scales with). The share of each band in
the 2,000-page bulk-pilot draw is mixed-def's post-stratified estimate, with an interval from resampling the owner's
170 answers within each sheet stratum (KND-3). Descriptive only (P3-3): the core is an enriched set, so no band
figure is weighted to the corpus. Aggregates only; texts stay in the private cache. No network, no money.
"""
from __future__ import annotations

import json
import random
import re
import sys
from pathlib import Path

import marks_detect as D
import marks_read as R
import mixed_route as M
import mixed_def as MD

BANDS = ("none", "signature", "few", "passage", "long", "unread")
BAND_TEXT = {"none": "No handwriting (print or stamps only)", "signature": "Signature, initials or date only",
             "few": "Under about 10 words", "passage": "About 10-29 words", "long": "30 words or more",
             "unread": "Handwriting the owner left unread"}
# The pre-flag's band names (marks_set.py) in the same order.
GUESS = {"none": "none", "signature_initials_date": "signature", "under_10_words": "few", "10_29_words": "passage",
         "30_plus_words": "long", "handwritten_page": "long"}
WRITTEN = {"annotation", "marginal_note"}
MONTHS = r"jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|january|february|march|april|june|july|august|" \
         r"september|october|november|december"
DATE_WORD = re.compile(rf"^(\d[\d./-]*,?|({MONTHS})\.?,?)$", re.I)


def is_date(text):
    words = R.norm(text).split()
    return bool(words) and all(DATE_WORD.match(w) for w in words)


def owner_band(marks):
    """(band, handwritten words) from a page's owner-core marks."""
    hand = [m for m in marks if m["cls"] in WRITTEN]
    if any(m["transcription_status"] != "owner_reviewed" for m in hand):
        return "unread", None
    words = sum(len(R.norm(m["text"]).split()) for m in hand)
    if not hand:
        return ("signature" if any(m["cls"] == "signature_initials" for m in marks) else "none"), 0
    if all(is_date(m["text"]) for m in hand):
        return "signature", words
    return ("few" if words < 10 else "passage" if words < 30 else "long"), words


def pages():
    rec = json.loads((D.RECORD / "reconciled.json").read_text())["pages"]
    out = {}
    for pid, p in sorted(rec.items()):
        if p["detector_evaluable"]:
            band, words = owner_band(p["marks"])
            out[pid] = dict(band=band, words=words, guess=GUESS.get(p["band"], p["band"]), core=p["core_support"])
    return out


# ---------------------------------------------------------------- time and tokens

def timing(reader, pid):
    """(seconds, output tokens) for a whole-page read; None where the run kept no per-page figure."""
    if reader == "lighton":
        d = json.loads((M.WORK / "whole" / "lighton" / f"{pid}.json").read_text())
        return d["wall_s"], d.get("tokens")
    if reader in M.CLUSTER_ROUTES:
        rec = M.receipts(reader, "whole", pid)[0]
        return rec["wall_s"], rec["usage"]["completion_tokens"]
    return None, None


def median(v):
    v = sorted(x for x in v if x is not None)
    return v[len(v) // 2] if v else None


# ---------------------------------------------------------------- the mixed share's interval (KND-3)

def share_boot(n=2000, seed=46):
    """95% intervals on mixed-def's post-stratified share at each threshold, resampling the owner's answers within
    each sheet stratum (the disagreements' pattern weights as mixed_def.score applies them)."""
    rows = MD.read_csv(MD.CACHE / "labels.tsv", "\t")
    key = json.loads((MD.CACHE / "sheet" / "key.json").read_text())
    answers = json.loads((MD.CACHE / "sheet" / "answers.json").read_text())
    pages = key["pages"]
    got = {p: a for p, a in answers.items() if p in pages and a.get("hand")}
    by = {}
    for p in got:
        by.setdefault(pages[p]["stratum"], []).append(p)
    point = {t["at_least"]: t["share"] for t in MD.score(answers, key, rows)["by_threshold"]}
    rng = random.Random(seed)
    draws = {h: [] for h in MD.ORDER}
    for _ in range(n):
        k2, a2 = dict(key, pages={}), {}
        for s, ps in by.items():
            for j in range(len(ps)):
                p = ps[rng.randrange(len(ps))]
                new = f"{p}~{s}~{j}"
                k2["pages"][new], a2[new] = pages[p], got[p]
        for t in MD.score(a2, k2, rows)["by_threshold"]:
            draws[t["at_least"]].append(t["share"])
    ci = lambda v: [round(sorted(v)[int(0.025 * len(v))], 4), round(sorted(v)[int(0.975 * len(v)) - 1], 4)]
    out = {h: dict(share=point[h], ci=ci(draws[h])) for h in MD.ORDER}
    # A band's own share: at least this band, less at least the next.
    for i, h in enumerate(MD.ORDER):
        nxt = MD.ORDER[i + 1] if i + 1 < len(MD.ORDER) else None
        band = [a - b for a, b in zip(draws[h], draws[nxt])] if nxt else draws[h]
        out[h]["band_share"] = round(point[h] - (point[nxt] if nxt else 0), 4)
        out[h]["band_ci"] = ci(band)
    return out


# ---------------------------------------------------------------- body text on the 96 (the typed-text cost)

# The marks core has no body truth, so the cost of sending a page's typed text through a handwriting reader is read
# off the owner's 96 OCR truth pages (ocr-scorers-pages.csv, the current scorer; kinds from ocr-pages.csv): each
# reader against Apple Vision on the same typed and printed pages, which is what a signature-only or few-word page
# mostly is. Only 2 of the 96 are mixed, so mixed pages get no figure of their own.
BODY = {"apple-vision": "Apple Vision (the app's settings)", "lightonocr-3-4b-mlx8": "LightOnOCR-3 4B 8-bit (Mac)",
        "glm-ocr": "GLM-OCR", "qwen3.6-27b": "Qwen3.6-27B (hosted)",
        "gemini3.7-flash-gw": "Gemini 3.7 Flash (gateway) †"}
TYPED = {"typewritten", "printed"}


def body(n=2000, seed=46):
    import csv
    kind = {r["page"]: r["kind"] for r in csv.DictReader(open(M.RESULTS / "ocr-pages.csv")) if r["route"] == "claude-sonnet5.5"}
    cost = {}
    for r in csv.DictReader(open(M.RESULTS / "ocr-pages.csv")):
        if r["route"] in BODY:
            cost.setdefault(r["route"], []).append((float(r["cost"] or 0), int(r["completion_tokens"] or 0) or None))
    nes = {}
    for r in csv.DictReader(open(M.RESULTS / "ocr-scorers-pages.csv")):
        if r["set"] == "owner96" and r["route"] in BODY:
            nes.setdefault(r["route"], {})[r["page"]] = float(r["nes"])
    rng = random.Random(seed)
    out = dict(kinds={k: sum(v == k for v in kind.values()) for k in sorted(set(kind.values()))}, routes={})
    for group, keep in (("typed", TYPED), ("mixed", {"mixed"})):
        pages = sorted(p for p, k in kind.items() if k in keep and all(p in nes[r] for r in BODY))
        draws = [[pages[rng.randrange(len(pages))] for _ in pages] for _ in range(n)]
        for route in BODY:
            mean = lambda ps: sum(nes[route][p] for p in ps) / len(ps)
            diff = lambda ps: mean(ps) - sum(nes["apple-vision"][p] for p in ps) / len(ps)
            d = sorted(diff(ps) for ps in draws)
            s = out["routes"].setdefault(route, {})
            s[group] = dict(pages=len(pages), nes=round(mean(pages), 4),
                            minus_vision=round(diff(pages), 4),
                            minus_vision_ci=[round(d[int(0.025 * n)], 4), round(d[int(0.975 * n) - 1], 4)],
                            worse_pages=sum(nes[route][p] < nes["apple-vision"][p] - 0.02 for p in pages))
        for route, c in cost.items():
            out["routes"][route]["cost_per_page"] = round(sum(x for x, _ in c) / len(c), 5)
            out["routes"][route]["median_tokens"] = median([t for _, t in c])
    return out


# ---------------------------------------------------------------- report

def report():
    pg = pages()
    todo = R.marks()[0]
    text = {f"{pid}#{i}": m["text"] for pid, i, m in todo}
    cls = {f"{pid}#{i}": m["cls"] for pid, i, m in todo}
    whole = M.score_whole(todo, text)
    region = M.score_region(todo, text)
    agree = {}
    for p in pg.values():
        agree.setdefault(p["guess"], {}).setdefault(p["band"], 0)
        agree[p["guess"]][p["band"]] += 1
    res = dict(pages={b: sum(p["band"] == b for p in pg.values()) for b in BANDS},
               pages_by_core={b: {c: sum(p["band"] == b and p["core"] == c for p in pg.values()) for c in M.CORES}
                              for b in BANDS},
               agreement=agree, agree_n=sum(p["band"] == p["guess"] for p in pg.values()), n_pages=len(pg),
               marks={}, time={}, share=share_boot(), body=body())
    routes = [(f"whole/{r}", w["rows"]) for r, w in whole.items() if "rows" in w] + \
             [(f"box/{k.split('/')[0]}", rows) for k, rows in region.items() if k.endswith("/oracle")]
    for key, rows in routes:
        per = {}
        for b in BANDS:
            rs = [r for r in rows if pg[r["page"]]["band"] == b]
            hs = [r for r in rs if cls[r["mark"]] in WRITTEN]
            per[b] = dict(n=len(rs), read=sum(r["nes"] >= R.READ for r in rs), hand_n=len(hs),
                          hand_read=sum(r["nes"] >= R.READ for r in hs),
                          mean_nes=round(sum(r["nes"] for r in rs) / len(rs), 3) if rs else None)
        res["marks"][key] = per
    for reader in M.WHOLE:
        if reader == "vision":
            wall = json.loads((M.WORK / "whole" / "vision-wall.json").read_text())
            res["time"][reader] = dict(batch_s_per_page=round(wall["wall_s"] / wall["pages"], 2))
            continue
        per = {}
        for b in BANDS:
            got = [timing(reader, pid) for pid, p in pg.items() if p["band"] == b]
            per[b] = dict(pages=len(got), median_s=median([g[0] for g in got]), median_tokens=median([g[1] for g in got]))
        res["time"][reader] = per
    res["unread_known_words"] = sorted(sum(len(R.norm(m["text"]).split()) for m in rec["marks"]
                                           if m["cls"] in WRITTEN and m["transcription_status"] == "owner_reviewed")
                                       for pid, rec in json.loads((D.RECORD / "reconciled.json").read_text())["pages"].items()
                                       if pid in pg and pg[pid]["band"] == "unread")
    (M.RESULTS / "mixed-route-bands.json").write_text(json.dumps(res, indent=1) + "\n")
    (M.RESULTS / "mixed-route-bands.md").write_text(markdown(res))
    print(json.dumps({k: {b: (v[b]["read"], v[b]["n"]) for b in BANDS} for k, v in res["marks"].items()}))
    return res


SHOWN = [b for b in BANDS if b != "none"]
NAMES = {**{f"whole/{k}": v for k, v in M.WHOLE.items()},
         **{f"box/{k}": f"{v}, the owner's box (oracle)" for k, v in M.REGION.items()}}


def pc(v, scale=100, fmt="{:+.1f}"):
    return fmt.format(scale * v)


def markdown(res):
    n = res["n_pages"]
    L = ["# Mixed-page routing by handwriting amount, with cost and time (W46.mixed-route-bands)", "",
         "W46.mixed-route's scores cut by the four handwriting bands of `mixed-def-score.md` (owner, 2026-10-28), with "
         "each route's time and cost a page and the typed-text cost of a handwriting reader (`mixed_route_bands.py`; "
         "figures in `mixed-route-bands.json`). No new model was run and nothing was spent: every reading is "
         "W46.mixed-route's or the 96-page OCR panel's. W46.mixed-route-paid (Gemini) was retired by the owner on "
         "2026-11-05, so it has no row.", "",
         "## The bands on the marks core", "",
         f"Each of the {n} detector-eligible core pages is banded by its owner-reviewed handwriting (MRK-1): the words "
         "of its annotations and marginal notes (stamps and \"other\" marks are not handwriting). Signatures, "
         "initials and date-only notes make the first band. A page with a handwritten mark the owner left unread has "
         "no known count.", "",
         "| Band (owner core) | Pages | A-core | B-core |", "|---|---:|---:|---:|"]
    for b in BANDS:
        c = res["pages_by_core"][b]
        L.append(f"| {BAND_TEXT[b]} | {res['pages'][b]} | {c['A-core']} | {c['B-core']} |")
    known = [b for b in SHOWN if b != "unread"]
    banded = sum(res["pages"][b] for b in known)
    right = sum(res["agreement"].get(b, {}).get(b, 0) for b in known)
    L += ["", f"The unread pages' known words: {', '.join(map(str, res['unread_known_words']))} (so one of the three "
          "is at least the 10-29 band).", "",
          "The Qwen3.6-27B pre-flag band the pages were drawn by (rows) against the owner-core band (columns):", "",
          "| Pre-flag \\ owner | " + " | ".join(BAND_TEXT[b] for b in BANDS) + " |",
          "|---|" + "---:|" * len(BANDS)]
    for g in BANDS:
        if g in res["agreement"]:
            L.append(f"| {BAND_TEXT[g]} | " + " | ".join(str(res["agreement"][g].get(b, 0)) for b in BANDS) + " |")
    L += ["", f"The pre-flag band agrees with the owner core on {res['agree_n']} of {n} pages, but 15 of those are pages "
          f"with no handwriting; on the {banded} pages with handwriting of a known band it is right on {right}. So a "
          "result cut by the pre-flag band would be cut by the wrong band about half the time.", "",
          "## Marks read, by band", "",
          "Marks read at NES >= 0.8 (all owner-reviewed marks on the band's pages, stamps included; the handwritten "
          "annotations and marginal notes alone in brackets). The no-handwriting band's marks are stamps only.", "",
          "| Route | " + " | ".join(BAND_TEXT[b] for b in BANDS) + " |", "|---|" + "---|" * len(BANDS)]
    for key, per in res["marks"].items():
        cells = [f"{per[b]['read']} of {per[b]['n']}" + (f" ({per[b]['hand_read']} of {per[b]['hand_n']})"
                                                         if per[b]["hand_n"] else "") for b in BANDS]
        flag = " ‡" if key.split("/")[1] in M.PREFLAGGED else ""
        L.append(f"| {NAMES[key]}{flag} | " + " | ".join(cells) + " |")
    L += ["", "‡ Not ranked (MRK-1): it chose the B-core pages by its own pre-flag, and every page in the 10-29 and "
          "30-plus bands is a B-core page.", "",
          "## Time and tokens a page, by band", "",
          "Whole-page reads of the 32 pages. Apple Vision ran as one batch, "
          f"{res['time']['vision']['batch_s_per_page']} s a page on average: the batch's wall time with the "
          "program's launch and setup, divided by 32. LightOnOCR-3 4B on the M3 Pro, each page's generation wall "
          "with the model's load left out; both in one engine session at background priority, so neither is a clean "
          "figure and the two are not measured alike. GLM-OCR and Qwen3.6-27B on one Sherlock GPU each at "
          "concurrency 16, so a request's latency under load, not its share of the GPU. Median seconds (median "
          "output tokens):", "",
          "| Reader | " + " | ".join(BAND_TEXT[b] for b in BANDS) + " |", "|---|" + "---|" * len(BANDS)]
    for reader in ("lighton", "glm", "qwen27"):
        t = res["time"][reader]
        L.append(f"| {M.WHOLE[reader]} | " + " | ".join(
            f"{t[b]['median_s']:.1f} s" + (f" ({t[b]['median_tokens']})" if t[b]["median_tokens"] else "") for b in BANDS) + " |")
    L += ["", "Time follows the page's text, not its handwriting: the pages with the most handwriting carry the least "
          "print and are read fastest. A band adds no time of its own; what adds time is sending the page to a slower "
          "reader at all.", "",
          "## The typed-text cost of a handwriting reader", "",
          "The marks core has no body-text truth, so this is read off the owner's 96 OCR truth pages "
          "(`ocr-scorers-pages.csv`, the current scorer): each reader against Apple Vision on the same typed and "
          "printed pages, which is what a signature-only or few-word page mostly is. Body NES in points, paired by page "
          "(95% page bootstrap); *worse pages* are pages more than 2 points below Vision's. Cost is the panel's "
          "per-page price (an estimate from tokens and list price; Mac and Sherlock routes cost no money).", ""]
    body = res["body"]
    L += [f"| Route | Typed and printed pages | Body NES | Against Vision | Worse pages | Cost a page |",
          "|---|---:|---:|---|---:|---:|"]
    for route, name in BODY.items():
        s = body["routes"][route]
        t = s["typed"]
        cost = s.get("cost_per_page")
        L.append(f"| {name} | {t['pages']} | {100 * t['nes']:.1f} | "
                 + ("(reference)" if route == "apple-vision" else
                    f"{pc(t['minus_vision'])} ({pc(t['minus_vision_ci'][0])} to {pc(t['minus_vision_ci'][1])})")
                 + f" | {t['worse_pages']} | " + (f"${cost:.4f}" if cost else "$0") + " |")
    mx = body["routes"]["lightonocr-3-4b-mlx8"]["mixed"]
    L += ["", "† Gemini 3.7 Flash is a relative of Gemini 3.8 Flash, one of the 96's two truth drafters, so its gain "
          "is partly agreement with its relative's text; it is shown for its cost, not ranked.", "",
          f"Only {body['kinds'].get('mixed', 0)} of the 96 are mixed pages, so mixed pages have no body figure of their own "
          f"(LightOnOCR-3 4B is {pc(mx['minus_vision'])} points against Vision on those two, "
          f"{pc(mx['minus_vision_ci'][0])} to {pc(mx['minus_vision_ci'][1])}, {mx['worse_pages']} of "
          f"{mx['pages']} pages worse: two pages, not a result, but the only mixed pages measured).", "",
          "## How many pages each band is", "",
          "Post-stratified share of the 2,000-page bulk-pilot draw (mixed-def-score.md's estimator), with a 95% "
          "interval from resampling the owner's 170 answers within each sheet stratum (KND-3); the unsampled "
          "strata's assumptions stay as mixed-def-score.md states them.", "",
          "| Band | The band alone | This band or more |", "|---|---|---|"]
    for h, b in zip(MD.ORDER, ("signature", "few", "passage", "long")):
        s = res["share"][h]
        L.append(f"| {BAND_TEXT[b]} | {100 * s['band_share']:.1f}% ({100 * s['band_ci'][0]:.1f}-{100 * s['band_ci'][1]:.1f}%) "
                 f"| {100 * s['share']:.1f}% ({100 * s['ci'][0]:.1f}-{100 * s['ci'][1]:.1f}%) |")
    L += ["", WHAT, "", CARD]
    return "\n".join(L) + "\n"


WHAT = """## What this says

**On typed pages, a handwriting reader is not shown to lower the typed text's accuracy; on mixed pages it is
unmeasured.** On the 96's 78 typed and printed pages every handwriting-capable reader is level with Apple Vision or
better on body NES: LightOnOCR-3 4B +1.8 points (a tie, -2.2 to +5.9), GLM-OCR +4.3, Qwen3.6-27B +7.3. The per-page
spread is real: LightOnOCR is more than 2 points below Vision on 14 of the 78 pages and GLM-OCR on 20, so a given page
can lose even where the average gains, and for the Mac reader the average itself is a tie, not a gain. The setting is
for mixed pages, and those are not measured: only 2 of the 96 are mixed, and on them LightOnOCR-3 4B is -12.1 points
against Vision (-20.7 to -3.6), both pages worse. Two pages are not a result, but they are the only evidence on the
pages the setting is for, and they point the other way. So "a page loses no typed accuracy for being routed for its
handwriting" is measured on typed pages only.

**What it costs is time, or money.** On the Mac, Vision read the 32 pages at about 1.3 s a page and LightOnOCR-3 4B at
about 24 s, which would make the Mac handwriting reader about 19 times the time, at no money. That ratio sets unlike
walls side by side: Vision's 1.3 s is a batch's wall with the program's launch and setup, LightOnOCR's 24 s a page's
generation with the model's load left out, both from an engine session at background priority; the bench's own Vision
row (0.21 s a page, as measurement review pass 11 reads it) would make it nearer 100 times than 19. So the time cost is large but not yet measured like for
like (W46.mixed-route-setting measures it before a figure is shown). Hosted, Qwen3.6-27B costs about $0.002 a page and
Gemini 3.7 Flash about $0.004. The band does not change the time: a page's time follows its print, and the pages with
the most handwriting were read fastest. With mixed pages an estimated 33% (24-44%) of the draw, routing all of them on
the Mac adds about 2.1 hours a thousand pages (1.6-2.8) on these walls; leaving out the signature-only band (8.7%,
4.0-16.7%) saves about a quarter of that.

**On marks, the bands are too small to tell routes apart, and the signature-only band gains little.** The
signature-only band's handwriting is three dates, which Vision reads as often as LightOnOCR-3 4B (2 of 3 whole
page; GLM-OCR 1). The one 30-plus page is the only place the whole page reads more than the owner's box (whole page
2-4 of its 7 handwritten marks, from the box 0-1): one page of 7 marks, not a lead, and every 10-29 and 30-plus page is a B-core page, chosen by Qwen3.6-27B's
pre-flag. Per band there are 3-9 marks: no band figure is a ranking.

**Recommendation: give users the choice, with the trade-off stated, not a default that hides it.** A setting such as
"Read handwriting on typed pages (signatures, dates, notes in the margin)" with a note of what it costs in reading time
on this Mac (many times Vision's; the figure waits on a like-for-like timing) or about $0.002-0.004 a page hosted, and
that the typed text was measured level on typed pages and is unmeasured on mixed pages (W46.mixed-route-setting
carries both conditions). A
finer choice by band (leave out signature-only pages) saves about a quarter of the time on these estimates but
needs a page's band before it is read, and the pre-flag guessed the band right on 7 of 14 pages; it is not worth a
setting of its own on this evidence. The setting is filed as W46.mixed-route-setting, behind Phase 4 and the
settings research, which decide the settings layer."""

CARD = """## Measurement card

- **Truth.** Marks: the 35 owner-reviewed mark texts of W46.mixed-route (drafted by Gemini 3.7 Flash and Qwen3-VL 8B,
  kept or corrected by the owner); bands from the owner core's own marks and texts, not the pre-flag (MRK-1). Body:
  the owner's 96 OCR truth pages, drafted by Claude Opus 5.5 and Gemini 3.8 Flash and adjudicated by the owner
  (`ocr-truth.md`); Gemini 3.7 Flash is a drafter's relative and is not ranked. Share: the owner's 170 answers
  (`mixed-def-score.md`).
- **Selection.** No page chosen here. The marks core is W46.marks-set's (A-core independent of any reader, B-core by
  Qwen3.6-27B's pre-flag band); every 10-29 and 30-plus page is B-core, and Qwen3.6-27B is not ranked on it. The 96
  are the panel's fixed draw (seed 41). None chosen by a tested route or ABBYY text.
- **Comparison.** W46.mixed-route's settings unchanged for the marks; the 96-page panel's settings for the body
  figures (every route on the same 78 pages). Times come from three machines and load conditions and are stated as
  such; they compare routes, not hardware, and Vision's batch wall (launch included) against LightOnOCR-3 4B's
  per-page wall (model load left out) is not a like-for-like ratio (measurement review pass 11, P11-4).
- **Noise.** Marks: 3-9 marks a band, too few for any band-level difference to be more than a tie. Body: paired page
  bootstrap, 2,000 resamples, seed 46; LightOnOCR-3 4B's gain is inside it, GLM-OCR's and Qwen3.6-27B's are not. No
  rerun floor is measured for the open readers (W46.ocr-rerun-noise covers Vision and the gateway). Share: within-
  stratum resampling of the owner's answers; the unsampled strata's assumptions are not in the interval.
- **Scope.** Descriptive only (P3-3): no band figure is weighted to the corpus. Not settled: the typed-text cost on
  mixed pages themselves (no body truth there), Gemini on mixed pages (retired), a two-reader cascade, and the
  setting's form (Phase 4, W46.settings-design-research)."""


def main(argv):
    if argv == ["report"]:
        report()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
