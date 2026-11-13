#!/usr/bin/env python3
"""W46.ent-feature: the entity feature's own prompt, its evidence check and its correspondence gate, measured before
they ship in the Processor (EntityExtractor.swift).

    python3 ent_feature.py run-noncorr     # the 21 non-correspondence documents: pages, Vision text, two calls each
                                           # (paid, capped; run it under heavy-run.py, Vision reads the pages)
    python3 ent_feature.py report          # segbench-results/ent-feature.md and .json

The prompt is the dedicated entity prompt with the sending-place rule, at 3,000 characters: ent_score_paid.ENTITY_PROMPT
with ent_place_rule.ENTITY_PLACE, byte for byte the prompt the cached entity3k-place replies answered
(W46.ent-place-rule-paid), so its figures on the 138 correspondence documents cost nothing here. Its sender rule is
"a person, or the issuing organisation when no person is named" (owner call 10 left the rule to this feature).

What this item adds, all offline on those cached replies except the last:
- the evidence check as the app makes it (`evidence`, mirrored by EntityExtractor.evidence; test_ent_feature checks
  the two agree on the shared cases): a quote found in the document's own text, whitespace folded and case ignored,
  exactly or at edit distance 2 when the quote has five letters or more, is read; anything else is written marked
  inferred. Precision of each class against the truth.
- the inside-address check (P11-3's open point, 09-entities.md item 2): how many written places are quoted from the
  recipient's inside address rather than the letterhead or the dateline, and how many of those are wrong.
- the correspondence gate: the app runs the feature only where the tagging call's `format` is a letter, memo or
  telegram (the app has no correspondence classifier). Its recall on the 138 from the cached tagging replies.
- the sender convention on non-correspondence (P6-3's unmet condition): the gate's leak on the 21 non-correspondence
  documents of the entity set, and what the entity prompt writes there. These 21 had no Vision text, so run-noncorr
  reads their pages (JPEG originals, as W46.ent-score-paid did) and makes 42 calls (tagging + entity), under CAP.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ent_place_rule as R  # noqa: E402
import ent_score_paid as P  # noqa: E402
import ent_truth as ET  # noqa: E402

CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/ent-feature")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "ent-feature.md")
SWIFT = os.path.join(HERE, "..", "..", "macOS", "Sources", "ArchiveProcessor", "Tagging", "EntityExtractor.swift")
CAP = 1.00                # this item's spend, under the owner's $7 a piece of work
TEXT_CAP = 3000
NEAR_LETTERS = 5          # a quote of this many letters or more may be found at edit distance 2
NEAR_DISTANCE = 2
TEMPLATE = P.with_rules(P.ENTITY_PROMPT, {"sending_place": R.ENTITY_PLACE})
# EntityRunPolicy.correspondenceFormats: the tagging call's `format` values the feature runs on.
CORRESPONDENCE = ("letter", "memo", "memorandum", "telegram", "cable", "cablegram", "postcard", "telex")
UNKNOWN = ("", "null", "none", "unknown", "n/a")


def prompt(text):
    """EntityExtractor.prompt(text:)."""
    return TEMPLATE.format(text=text[:TEXT_CAP])


# --- the evidence check (EntityExtractor.evidence) ---------------------------------------------------

def norm(s):
    return re.sub(r"\s+", " ", s or "").strip().lower()


def letters(s):
    return sum(c.isalpha() for c in s)


def best_distance(q, t, cap=NEAR_DISTANCE + 1):
    """The smallest edit distance between q and any stretch of t (Sellers), capped."""
    if not q:
        return 0
    prev = [0] * (len(t) + 1)
    for i, cq in enumerate(q, 1):
        cur = [i] + [0] * len(t)
        for j, ct in enumerate(t, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (cq != ct))
        prev = cur
        if min(prev) >= cap:
            return cap
    return min(min(prev), cap)


def evidence(quote, text):
    """(evidence, distance, why): ("quoted", 0|1|2, None) or ("inferred", None, "no quote" | "quote not in the
    text")."""
    q = norm(quote)
    if not q:
        return "inferred", None, "no quote"
    t = norm(text[:TEXT_CAP])
    if q in t:
        return "quoted", 0, None
    if letters(q) >= NEAR_LETTERS:
        d = best_distance(q, t)
        if d <= NEAR_DISTANCE:
            return "quoted", d, None
    return "inferred", None, "quote not in the text"


def confidence(ev, d):
    return "low" if ev == "inferred" else ("high" if d == 0 else "medium")


def names(v):
    """A reply field as [{name, quote}] the way EntityExtractor.parse reads it: a list of objects or strings, or one
    string; empty and "Unknown"-like names dropped, a repeated name kept once."""
    if v is None:
        return []
    items = v if isinstance(v, list) else [v]
    out, seen = [], set()
    for e in items:
        if isinstance(e, str):
            n, q = e, None
        elif isinstance(e, dict):
            n, q = e.get("name"), e.get("quote")
            n = n if isinstance(n, str) else None
            q = q if isinstance(q, str) else None
        else:
            continue
        n = re.sub(r"\s+", " ", n or "").strip()
        if n.lower() in UNKNOWN or n.lower() in seen:
            continue
        seen.add(n.lower())
        out.append({"name": n, "quote": q})
    return out


# --- data --------------------------------------------------------------------------------------------

def noncorr_docs():
    docs = {d["id"]: d for d in ET.load_docs()}
    tr = [json.loads(x) for x in open(os.path.join(ET.CACHE, "truth.jsonl"), encoding="utf-8")]
    return [docs[r["id"]] for r in tr if not r["is_correspondence"]]


def page_img(p):
    return os.path.join(CACHE, "pages", P.key(p) + ".jpg")


def page_txt(p):
    return os.path.join(CACHE, "vision", P.key(p) + ".txt")


def vision_text(d):
    return "\n\n".join(open(page_txt(p), encoding="utf-8").read().strip() for p in d["pages"])


def tagging_format(raw):
    js = P.parse(raw)
    f = (js or {}).get("format")
    return f.strip().lower() if isinstance(f, str) else None


# --- run-noncorr -------------------------------------------------------------------------------------

def cmd_run_noncorr(_a):
    import corpus_pairs as CP
    import corpus_survey as CS
    import data
    import ocr_truth as OT
    from pathlib import Path
    docs = noncorr_docs()
    pair = {pdf: j for pdf, j, _m, _t in CP.read_pairs()}
    os.makedirs(os.path.join(CACHE, "pages"), exist_ok=True)
    os.makedirs(os.path.join(CACHE, "vision"), exist_ok=True)
    mp = os.path.join(CACHE, "pages.json")
    metas = json.load(open(mp)) if os.path.exists(mp) else {}
    todo = [p for d in docs for p in d["pages"] if not os.path.exists(page_img(p))]

    def one(p):
        # The JPEG original where the pair exists, else the PDF's own image (W46.ent-score-paid's sources). The
        # corpus is only read: OT.extract writes under CACHE.
        if pair.get(p):
            return p, {**OT.extract("original", Path(CP.JPEGS) / pair[p], Path(page_img(p)), Path(CS.CORPUS) / p),
                       "source": "original"}
        return p, {**OT.extract("pdf", Path(CS.CORPUS) / p, Path(page_img(p))), "source": "pdf"}
    with ThreadPoolExecutor(4) as ex:
        for p, m in ex.map(one, todo):
            metas[p] = m
    json.dump(metas, open(mp, "w"), indent=1)
    jobs = os.path.join(CACHE, "vision-jobs.tsv")
    with open(jobs, "w") as fh:
        for d in docs:
            for p in d["pages"]:
                if not os.path.exists(page_txt(p)):
                    fh.write(f"{page_img(p)}\t{page_txt(p)}\n")
    binp = data.build_ocr_tool()
    if binp is None:
        raise SystemExit("ocr.swift did not compile")
    if os.path.getsize(jobs):
        subprocess.run([str(binp), jobs], check=True)

    def calls(d):
        t = vision_text(d)
        P.call("tagging", d["id"], P.tagging_prompt_before(t, P.context_of(d["prompt"])), CACHE, CAP)
        P.call("entity", d["id"], prompt(t), CACHE, CAP)
    with ThreadPoolExecutor(P.WORKERS) as ex:
        list(ex.map(calls, docs))
    print(f"{len(docs)} documents; ${P.spent(CACHE):.4f} spent of ${CAP}")


# --- report ------------------------------------------------------------------------------------------

def inside_address(text, place_quote, recipient_quotes):
    """True when the place's quote sits in the recipient's inside address: after a recipient's quote and before the
    salutation (or within 200 characters of the recipient's quote when no salutation follows)."""
    t = norm(text[:TEXT_CAP])
    pq = norm(place_quote)
    if not pq or pq not in t:
        return False
    for rq in recipient_quotes:
        rq = norm(rq)
        if not rq or rq not in t:
            continue
        r = t.index(rq)
        m = re.search(r"\b(dear|gentlemen|sir|madam)\b", t[r:])
        end = r + (m.start() if m else 200)
        start = t.find(pq, r)
        if 0 <= start < end:
            return True
    return False


def cmd_report(_a):
    import ent_truth_owner as EO
    truth = {r["id"]: r for r in ET.load_truth()}
    rows = P.rows()
    # The app's prompt is the measured one, document by document.
    for _r, d in rows:
        assert prompt(P.vision_text(d)) == R.prompt_entity(d), d["id"]
    P.check_replies(R.ENT, R.CACHE, R.prompt_entity)
    P.check_replies("tagging", P.CACHE, lambda d: P.label_prompt("tagging", d))
    texts = {r["id"]: P.vision_text(d) for r, d in rows}
    raw = {r["id"]: json.load(open(P.reply_path(R.ENT, d["id"], R.CACHE))).get("raw") for r, d in rows}
    fmt = {r["id"]: tagging_format(json.load(open(P.reply_path("tagging", d["id"], P.CACHE))).get("raw"))
           for r, d in rows}
    pr = {}
    for i, rw in raw.items():
        js = P.parse(rw)
        if js is not None:
            pr[i] = {f: names(js.get(f)) for f in ET.FIELDS}
    s = {"docs": len(rows), "parsed": len(pr), "scores": {}, "gate": {}, "evidence": {}, "inside_address": {},
         "noncorr": {}}
    s["scores"]["entity prompt"] = EO.scores(pr, truth)
    gated = {i: (p if fmt[i] in CORRESPONDENCE else {f: [] for f in ET.FIELDS}) for i, p in pr.items()}
    s["scores"]["entity prompt behind the gate"] = EO.scores(gated, truth)
    s["gate"]["formats"] = dict(collections.Counter(fmt.values()).most_common())
    s["gate"]["passed"] = sum(f in CORRESPONDENCE for f in fmt.values())
    s["gate"]["named_senders_lost"] = sum(bool(truth[i]["sender"]) for i, f in fmt.items() if f not in CORRESPONDENCE)

    # Evidence classes: precision at ed2 against the truth's named entries (role- or correspondence-inferred truth
    # names set aside, as ent_score_paid.evidence does).
    for f in ET.FIELDS:
        g = collections.defaultdict(lambda: [0, 0])
        for i, p in pr.items():
            tr = truth[i].get(f) or []
            for e in p[f]:
                ev, dist, why = evidence(e["quote"], texts[i])
                grp = f"read, distance {dist}" if ev == "quoted" else f"inferred: {why}"
                if any(ET.match(e["name"], x["name"], "ed2", x.get("alternates", ())) for x in tr
                       if x.get("class") == "named"):
                    g[grp][0] += 1
                elif any(ET.match(e["name"], x["name"], "ed2", x.get("alternates", ())) for x in tr):
                    g[grp + " (truth inferred)"][0] += 1
                else:
                    g[grp][1] += 1
        s["evidence"][f] = {k: {"right": v[0], "wrong": v[1]} for k, v in sorted(g.items())}

    # Inside address: written places quoted from the recipient's address block.
    ia = {"places_written": 0, "quoted": 0, "inside_address": 0, "inside_right": 0, "inside_wrong": 0}
    for i, p in pr.items():
        rq = [e["quote"] for e in p["recipient"] if e["quote"]]
        for e in p["sending_place"]:
            ia["places_written"] += 1
            if evidence(e["quote"], texts[i])[0] == "quoted":
                ia["quoted"] += 1
            if e["quote"] and inside_address(texts[i], e["quote"], rq):
                ia["inside_address"] += 1
                right = any(ET.match(e["name"], x["name"], "ed2", x.get("alternates", ()))
                            for x in truth[i].get("sending_place") or [])
                ia["inside_right" if right else "inside_wrong"] += 1
    s["inside_address"] = ia

    # Non-correspondence: the gate's leak and what the entity prompt writes there.
    nc = noncorr_docs()
    have = [d for d in nc if os.path.exists(P.reply_path("entity", d["id"], CACHE))
            and os.path.exists(P.reply_path("tagging", d["id"], CACHE))]
    if have:
        for d in have:
            P.cached(P.reply_path("entity", d["id"], CACHE), prompt(vision_text(d)), P.request_settings())
        nf = {d["id"]: tagging_format(json.load(open(P.reply_path("tagging", d["id"], CACHE))).get("raw"))
              for d in have}
        ent = {d["id"]: names_all(json.load(open(P.reply_path("entity", d["id"], CACHE))).get("raw")) for d in have}
        leak = [i for i, f in nf.items() if f in CORRESPONDENCE]
        filled = lambda ids, f: sum(bool(ent[i] and ent[i][f]) for i in ids)  # noqa: E731
        quoted = lambda ids, f: sum(1 for i in ids if ent[i] for e in ent[i][f]  # noqa: E731
                                    if evidence(e["quote"], vision_text(next(x for x in have if x["id"] == i)))[0]
                                    == "quoted")
        s["noncorr"] = {
            "docs": len(nc), "answered": len(have), "formats": dict(collections.Counter(nf.values()).most_common()),
            "gate_leak": len(leak), "unparsed": sum(ent[i] is None for i in ent),
            "all": {f: {"filled": filled(list(ent), f), "names_quoted": quoted(list(ent), f)} for f in ET.FIELDS},
            "behind_gate": {f: {"filled": filled(leak, f), "names_quoted": quoted(leak, f)} for f in ET.FIELDS},
            "spent_usd": round(P.spent(CACHE), 4)}
    json.dump(s, open(RESULTS[:-3] + ".json", "w"), indent=1, sort_keys=True)
    report(s)


def names_all(raw):
    js = P.parse(raw)
    return None if js is None else {f: names(js.get(f)) for f in ET.FIELDS}


def pct(a, b):
    return f"{a}/{b}" + (f" ({a / b:.0%})" if b else "")


def report(s):
    sc = s["scores"]
    L = ["# The entity feature's prompt, evidence check and gate (W46.ent-feature)", "",
         "The Processor's entity feature (EntityExtractor.swift) sends the dedicated entity prompt with the "
         "sending-place rule on the first 3,000 characters, byte for byte the prompt of W46.ent-place-rule-paid's "
         "entity3k-place arm, so its figures here are those cached replies (Gemini 3.7 Flash, Vision text, "
         f"{s['docs']} correspondence documents, {s['parsed']} parsed) scored on the truth as it now stands. "
         "`python3 ArchiveProcessor/scripts/segbench/ent_feature.py report`.", "",
         "## Scores (ed2 F1)", "",
         "| arm | n | sender | recipient | place P / R / F1 | place by city |", "|---|---|---|---|---|---|"]
    for k, v in sc.items():
        pl = v["sending_place"]
        f = lambda x: "-" if x is None else f"{x:.2f}"  # noqa: E731
        L.append(f"| {k} | {v['n']} | {f(v['sender']['f1'])} | {f(v['recipient']['f1'])} | "
                 f"{f(pl['precision'])} / {f(pl['recall'])} / {f(pl['f1'])} | {f(v['city']['f1'])} |")
    g = s["gate"]
    L += ["", "## The correspondence gate", "",
          "The app has no correspondence classifier, so the feature runs where the tagging call's `format` is one of "
          f"{', '.join(CORRESPONDENCE)}. On the 138 the cached tagging replies (the app's reverted prompt) pass "
          f"{pct(g['passed'], s['docs'])}; formats {g['formats']}. The documents it stops carry "
          f"{g['named_senders_lost']} named senders, which the gated row above counts as missed."]
    L += ["", "## The evidence check", "",
          "Each name's quote is looked for in the document's own text (the 3,000 characters sent; whitespace folded, "
          "case ignored; at edit distance 2 when the quote has five letters or more). Right and wrong at ed2 against "
          "the truth's named entries; a name matching only a role- or correspondence-inferred truth entry is "
          "counted apart.", "", "| field | class | right | wrong |", "|---|---|---|---|"]
    for f, groups in s["evidence"].items():
        for k, v in groups.items():
            L.append(f"| {f} | {k} | {v['right']} | {v['wrong']} |")
    ia = s["inside_address"]
    L += ["", "## The inside address", "",
          f"Places written: {ia['places_written']}, of which {ia['quoted']} are read by the check. Quoted from the "
          f"recipient's inside address (after a recipient's quote and before the salutation): {ia['inside_address']}, "
          f"{ia['inside_right']} right and {ia['inside_wrong']} wrong against the truth."]
    nc = s.get("noncorr") or {}
    L += ["", "## Non-correspondence", ""]
    if nc:
        L += [f"{nc['answered']} of the entity set's {nc['docs']} non-correspondence documents read (Vision text from "
              f"their JPEG originals, read for this item) and sent to both prompts, ${nc['spent_usd']:.4f}. The "
              f"tagging call's formats: {nc['formats']}. The gate lets {nc['gate_leak']} through. Entity replies "
              f"unparsed: {nc['unparsed']}.", "",
              "| field | documents with a name, all | names read by the check, all | with a name, behind the gate | "
              "read, behind the gate |", "|---|---|---|---|---|"]
        for f in ET.FIELDS:
            a, b = nc["all"][f], nc["behind_gate"][f]
            L.append(f"| {f} | {a['filled']} | {a['names_quoted']} | {b['filled']} | {b['names_quoted']} |")
    else:
        L.append("Not run yet (`run-noncorr`).")
    L += ["", READING, "", CARD]
    open(RESULTS, "w").write("\n".join(L) + "\n")
    print(RESULTS)


READING = """## Reading

- **The prompt ships as measured.** The app's prompt is the entity3k-place prompt byte for byte (`report` asserts it
  for each of the 138, `test_ent_feature` against the Swift literal), so its figures are sender 0.69, recipient 0.88,
  place 0.80 and 0.88 by city. Against the tagging call with both November rules, the arm the old route row describes,
  every field is a tie (`ent-place-rule.md`: sender +0.04 [-0.00, +0.08] for the tagging call, recipient -0.06
  [-0.13, +0.00], place -0.07 [-0.17, +0.02], city +0.00); the rerun floor of this prompt is sender +0.00, recipient
  +0.01, place -0.03 [-0.22, +0.16] on 40.
- **The sender convention.** Owner call 10 left it to this prompt: "a person, or the issuing organisation when no
  person is named", the truth's own convention. On non-correspondence it rarely fires: across the 21 documents the
  entity prompt names a sender on 5, and on the 4 the gate lets through (all called "memo" by the tagging call) on 1.
- **The gate.** With no correspondence classifier in the app, the tagging call's `format` decides: 134 of the 138
  correspondence documents pass, the 4 it stops carry 3 named senders, and the gated scores move by at most 0.01. It
  lets 4 of 21 non-correspondence documents through.
- **Evidence.** Every name the prompt returned on the 138 carried a quote the check finds exactly in the text; none
  needed the edit-distance allowance and none was inferred. Read names are right 85 of 112 times on the sender, 148
  of 164 on the recipient and 55 of 66 on the place: a quote proves the words are on the page, not that they are the
  sender (each of the 27 wrong senders is written on the page, but is not the one the truth takes). The inferred path is exercised by the app's test and
  by the earlier arms' unquoted names (`ent-score.md`: 38 of Gemini's 56 unquoted names confirmed by the truth).
- **The inside address.** 5 of the 66 written places are quoted from a recipient's inside address block, and all 5
  are right (0 of 5 wrong, Wilson 0% to 43%): on this set "an address" in the place rule does not pull in the
  recipient's address as the sending place. The bound is loose because the case is rare.
- **Non-correspondence dates.** The entity prompt asks for no date, and the tagging prompt is back to its pre-November
  name lines (W46.tagging-prompt-revert), so the open point about dates under the new lines no longer applies.
- **Cost.** The feature is one more call per correspondence document: $2.37 per 1,000 at Gemini 3.7 Flash's list
  price (the 138 calls' metered tokens), about 58% of the tagging call's $4.07; median 5.1 s through the gateway. Owner
  call 11's "extracted always on a cloud route" was made when the fields came with the tagging call at no cost."""

CARD = """## Measurement card

**Truth.** `ent_truth.load_truth()`: W46.fix-ent-truth (two model families drafting, Sonnet ruling 86 documents) with
the owner's answers and the sending-place rule; 138 correspondence documents, 72 named places. The owner overturned 3
of 7 asked rulings (P11-5), so about 2-3% of the fields are wrong in the truth; the 18 rule-emptied places nobody
checked are the weakest rows. Gemini drafted part of the truth and is the scored family (a relative, as in every entity
report). The non-correspondence documents have no name truth: their figures are counts, not accuracy.

**Selection.** The entity truth set (W46.fix-ent-truth's 300-document sample and its stratified top-up), chosen before
any route here; never by a tested route or ABBYY text. The 21 non-correspondence documents are that set's own.

**Comparison.** The same Vision text (macOS 27.2) and the first 3,000 characters for every arm; Gemini 3.7 Flash,
temperature 0, 8,192 tokens, through the Stanford gateway; replies keyed by prompt hash and settings. The 21's Vision
text was read for this item from their JPEG originals (or the PDF's image where no pair exists) with the same
`ocr.swift`, without W46.ent-score-paid's pair check by ABBYY words.

**Noise.** n 138 (21 for the non-correspondence counts). Paired 95% bootstrap intervals are `ent-place-rule.md`'s; the
rerun floor of this prompt on 40: sender +0.00, recipient +0.01, place -0.03 [-0.22, +0.16]. The gate's changes (at
most 0.01) are inside that floor.

**Scope.** Gemini 3.7 Flash, not the app's 3.8; Vision text, while on Vision text the app withholds the sender (rule
ent-vision-hands), so the sender figure applies to text a model read, which was not measured here. Not the Mac or
cluster models on this prompt (W46.ent-local-shipped-prompt). Handwritten letters are 5 of the 138. The inside-address
bound rests on 5 cases. Spent $0.094 (42 calls on the 21); the 138's replies were W46.ent-place-rule-paid's."""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("run-noncorr").set_defaults(fn=cmd_run_noncorr)
    sub.add_parser("report").set_defaults(fn=cmd_report)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
