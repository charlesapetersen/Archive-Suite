#!/usr/bin/env python3
"""W46.date-traceable: the staged dating pipeline against one shot, with the evidence checked.

Stages (10-gap-audit.md §5 item 14, R8 in the Stage 8 table):
  1. rules       every date the text prints, each with its line (`candidates`), and a pick among them (`rule_pick`)
  2. chooser     where the rule is not sure: the 2B's cached one-shot reply kept only when it names a candidate
                 (Mac, $0), or Qwen3.6-27B choosing from the numbered candidates (FarmShare, the `choose` arm)
  3. propagation a document that prints no date takes the rule pick of the nearest document before it (the
                 relation classifier of W46.date-enclosure has not shipped, so nothing decides whether it is an
                 enclosure; every propagated year is marked Date Uncertain)
  4. residue     what propagation does not reach within the threshold goes to Qwen3.6-27B with a prompt that asks
                 for year, interval, Date Uncertain, the cited document's id and a quote (`trace` arms: plain,
                 with the neighbours' rule dates added, and with five labelled same-collection examples)
Scored by class (date_truth's in text / A / A' / B / C / D, decade), evidence validity (date_scorers.evidence_check),
split-conformal coverage by class with swapped halves, the invalid-reply rate, and GPU-seconds per 1,000 documents at
each escalation threshold. The owner's 300 and the public 300 (Library of Congress By the People) side by side.

    python3 date_traceable.py rules                  # stage 1 alone, both sets; prints, writes nothing
    python3 date_traceable.py export --out DIR       # the FarmShare pack (requests.jsonl), private: prompts carry text
    python3 date_traceable.py import --answers F --label L
    python3 date_traceable.py score                  # segbench-results/date-traceable.md and .json

Read-only on the corpus (tags and the text cache, through enclosure_split.load). No paid call: the Gemini arm is
W46.date-traceable-paid and the claude -p arm waits for W46.gateway-models-ok. Run from scripts/segbench.
"""
import argparse
import collections
import json
import math
import os
import random
import re
import sys
import time

sys.path.insert(0, os.getcwd())
import date_scorers as S
import date_tagging as DT

CACHE = os.path.join(DT.CACHE, "traceable")
LTS_2B = os.path.expanduser("~/Claude/Long term storage/FarmShare-20261018/date-cache")
RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "segbench-results", "date-traceable.md")
RESULTS_JSON = RESULTS[:-3] + ".json"
LABEL_27B = "qwen3.6-27b-nothink"
LABEL_VISION = LABEL_27B + "-vision"     # the same model on prompts built from Apple Vision text
LO, HI = 1800, 2030
TEXT_CHARS = 3000          # what the app sends of a document
NEAR_CHARS = 600           # of each neighbour in the trace prompt (the app's context sends 300 of three)
NEAR = 3                   # neighbours each side
SHOTS = 5
SEED = 46
ALPHA = 0.1
THRESHOLDS = (0, 1, 2, 3)   # propagate when the nearest dated document before is at most t away, else escalate;
                            # propagation looks NEAR back, so t=3 escalates only what it cannot reach

MONTHS = ("january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
          "november", "december")
MON = r"(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?"
Y = r"(1[89]\d\d|20[0-3]\d)"
FORMS = (   # most specific first; a span claimed by one form is not read again by a later one
    ("full", re.compile(rf"\b{MON}\s+(\d{{1,2}})(?:st|nd|rd|th)?,?\s*{Y}\b", re.I)),
    ("full", re.compile(rf"\b(\d{{1,2}})(?:st|nd|rd|th)?\s+(?:of\s+)?{MON},?\s*{Y}\b", re.I)),
    ("numeric", re.compile(r"\b(\d{1,2})[/.-](\d{1,2})[/.-](\d{4}|\d{2})\b")),
    ("month", re.compile(rf"\b{MON},?\s+{Y}\b", re.I)),
    ("year", re.compile(rf"\b{Y}\b")),
)
WEIGHT = {"full": 3, "numeric": 2, "month": 2, "year": 1}


# ---- stage 1: rule candidates ---------------------------------------------------------------------------------------

def _month_of(word):
    w = word.lower().rstrip(".")
    return next((k + 1 for k, m in enumerate(MONTHS) if m.startswith(w[:3])), None)


def candidates(text, limit=TEXT_CHARS):
    """Every date printed in the first `limit` characters: [{year, month, kind, line_no, line}] in text order. A
    two-digit numeric year is read as 19YY (the corpus is twentieth-century); years outside 1800-2030 are dropped."""
    out = []
    for n, line in enumerate(text[:limit].splitlines()):
        taken = []
        for kind, rx in FORMS:
            for m in rx.finditer(line):
                if any(m.start() < b and a < m.end() for a, b in taken):
                    continue
                g = m.groups()
                month = None
                if kind == "full":
                    if g[0].isdigit():
                        day, month, year = int(g[0]), _month_of(g[1]), int(g[2])
                    else:
                        month, day, year = _month_of(g[0]), int(g[1]), int(g[2])
                    if not 1 <= day <= 31:
                        continue
                elif kind == "numeric":
                    a, b, yy = int(g[0]), int(g[1]), g[2]
                    year = int(yy) if len(yy) == 4 else 1900 + int(yy)
                    if not (1 <= a <= 12 and 1 <= b <= 31 or 1 <= b <= 12 and 1 <= a <= 31):
                        continue
                    month = a if 1 <= a <= 12 else b
                elif kind == "month":
                    month, year = _month_of(g[0]), int(g[1])
                else:
                    year = int(g[0])
                if not LO <= year <= HI:
                    continue
                taken.append((m.start(), m.end()))
                out.append({"year": year, "month": month, "kind": kind, "line_no": n, "line": line.strip()[:200],
                            "pos": m.start()})
    out.sort(key=lambda c: (c["line_no"], c["pos"]))
    return out


def rule_pick(cands, head_lines=15, mode="first"):
    """(year, month, confidence, evidence candidate) or (None, None, "none", None).

    The pick is the first dated form (full, numeric or month-year) in the first `head_lines` lines, where a letter or
    memo prints its own date; else the year with the highest weighted count (full 3, numeric and month 2, bare 1),
    earliest on a tie. Confidence: "sure" when every dated form names the picked year, "single" when the text holds one
    distinct year and no dated form, else "ambiguous" (the chooser's cases).

    mode "latest" changes only the fallback: the latest dated form, else the latest bare year, since a document
    mostly refers back to earlier years. It was written after reading the "first" rule's misses on the owner's 300,
    so its owner figure is tuned on that set; the public 300 is its check."""
    if not cands:
        return None, None, "none", None
    dated = [c for c in cands if c["kind"] != "year"]
    head = [c for c in dated if c["line_no"] < head_lines]
    if head:
        best = head[0]
    elif mode == "latest":
        pool = dated or cands
        top = max(c["year"] for c in pool)
        best = next(c for c in pool if c["year"] == top)
    else:
        w = collections.Counter()
        for c in cands:
            w[c["year"]] += WEIGHT[c["kind"]]
        top = max(w.values())
        best = next(c for c in cands if w[c["year"]] == top)
        best = next((c for c in cands if c["year"] == best["year"] and c["kind"] != "year"), best)
    years = {c["year"] for c in cands}
    if dated and all(c["year"] == best["year"] for c in dated):
        conf = "sure"
    elif not dated and len(years) == 1:
        conf = "single"
    else:
        conf = "ambiguous"
    month = best["month"] if best["kind"] != "year" else None
    return best["year"], month, conf, best


def distinct(cands, cap=8):
    """One candidate a year, its strongest form (earliest within a form), in text order, at most `cap`."""
    best = {}
    for c in cands:
        b = best.get(c["year"])
        if b is None or WEIGHT[c["kind"]] > WEIGHT[b["kind"]]:
            best[c["year"]] = c
    return sorted(best.values(), key=lambda c: (c["line_no"], c["pos"]))[:cap]


# ---- the Vision-text arm (R1) ---------------------------------------------------------------------------------------

VISION = os.path.join(CACHE, "vision")
VISION_PAGES = 2           # the rule reads 3,000 characters: the first two pages hold them
VISION_PX = 2400


def vision_page(page):
    import hashlib
    h = hashlib.sha1(page.encode()).hexdigest()
    return os.path.join(VISION, "img", h + ".jpg"), os.path.join(VISION, "txt", h + ".txt")


def vision_text(pages):
    """Apple Vision text of a document's first pages, or None if any is not cached."""
    out = []
    for p in pages[:VISION_PAGES]:
        t = vision_page(p)[1]
        if not os.path.exists(t):
            return None
        out.append(open(t, encoding="utf-8").read())
    return "\n\n".join(out)


def cmd_vision(a):
    """Render (sips, into the cache; the corpus is only read) and read (segbench's ocr.swift, the app's Vision
    settings) the first two pages of each owner document and of the three documents before it and, with --after, the
    three after it (the trace prompt shows them; the re-classing reads the year within three either side). Resumable."""
    import subprocess
    import corpus_survey as CS
    import data as D
    import enclosure_split as ES
    sample, found = ES.load()
    pages = []
    for d in sample:
        info = found.get(d["id"])
        if not info:
            continue
        k, segs = info["k"], info["segs"]
        js = [k] + [j for j in range(k - 1, -1, -1) if segs[j]["kind"] == "doc"][:NEAR]
        if a.after:
            js += [j for j in range(k + 1, len(segs)) if segs[j]["kind"] == "doc"][:NEAR]
            js += [j for j in range(max(0, k - NEAR), min(len(segs), k + NEAR + 1)) if segs[j]["kind"] == "doc"]
        for j in js:
            pages += [p for p in segs[j]["pages"][:VISION_PAGES] if p not in pages]
    pages = pages[:a.limit or None]
    tool = D.build_ocr_tool()
    if tool is None:
        raise SystemExit("ocr.swift did not compile")
    os.makedirs(os.path.join(VISION, "img"), exist_ok=True)
    os.makedirs(os.path.join(VISION, "txt"), exist_ok=True)
    t0, n = time.monotonic(), 0
    jobs = os.path.join(VISION, "jobs.tsv")
    with open(jobs, "w", encoding="utf-8") as fh:
        for p in pages:
            img, txt = vision_page(p)
            if os.path.exists(txt):
                continue
            if not os.path.exists(img):
                subprocess.run(["/usr/bin/sips", "-Z", str(VISION_PX), "-s", "format", "jpeg",
                                os.path.join(CS.CORPUS, p), "--out", img], capture_output=True, check=False)
            if os.path.exists(img):
                fh.write(f"{img}\t{txt}\n")
                n += 1
    render_s = time.monotonic() - t0
    t1 = time.monotonic()
    subprocess.run([str(tool), jobs], check=False)
    read_s = time.monotonic() - t1
    done = sum(os.path.exists(vision_page(p)[1]) for p in pages)
    rec = {"pages": len(pages), "read_now": n, "cached": done, "render_s": round(render_s, 1), "read_s": round(read_s, 1)}
    with open(os.path.join(VISION, "timing.jsonl"), "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    print(rec)


# ---- documents ------------------------------------------------------------------------------------------------------

def union_cands(primary, other, mode="union"):
    """Rule candidates from two readings of one document. "union": the primary text's, then the other's; rule_pick keeps
    list order, so the primary's head date wins, the other's head date comes next, and the weighted fallback counts a
    year printed in both texts twice. "fallback": the primary's alone, the other's only when the primary has none."""
    cs = candidates(primary)
    if mode == "fallback":
        return cs or candidates(other or "")
    return cs + candidates(other or "")


SOURCES = ("abbyy", "vision", "union-abbyy", "union-vision", "fallback-abbyy", "fallback-vision")


def owner_docs(source="abbyy"):
    """The owner's 300 with each one's folder neighbours: [{id, set, cls, truth, text, collection, folder, near}],
    near = [(label, id, text, rule pick)] for up to three documents either side (Box/Folder labels skipped, not counted).
    source "vision": Apple Vision text of the first two pages instead of the corpus text cache, for the document and
    the three before it (propagation looks only back); a document with any of those pages unread is left out. The
    three after are kept where Vision read them (`vision --after`). "union-abbyy" / "union-vision": the same documents,
    the rule reading both texts' candidates with the named one first (`union_cands`), text and prompts the primary's,
    `alt` the other text (the evidence check accepts a quote from either). "fallback-abbyy" / "fallback-vision": the
    named text's candidates alone, the other's only where it has none."""
    import date_truth as DTr
    import enclosure_split as ES
    assert source in SOURCES, source
    sample, found = ES.load()
    rows = ES.build_rows(sample, found, labels=())
    cls = {r["id"]: DTr.structural_class(r, found[r["id"]], found) for r in rows}
    out = []
    for d in sample:
        info = found.get(d["id"])
        if not info:
            continue
        k, segs, texts = info["k"], info["segs"], info["texts"]
        before = [j for j in range(k - 1, -1, -1) if segs[j]["kind"] == "doc"][:NEAR]
        after = [j for j in range(k + 1, len(segs)) if segs[j]["kind"] == "doc"][:NEAR]
        ctexts, alt = dict(enumerate(texts)), {}
        if source != "abbyy":
            vt = {j: vision_text(segs[j]["pages"]) for j in [k] + before}
            if any(v is None for v in vt.values()):
                continue
            va = {j: vision_text(segs[j]["pages"]) for j in after}
            after = [j for j in after if va[j] is not None]
            vt.update({j: va[j] for j in after})
            if source.endswith("-abbyy"):
                alt = vt
            else:
                texts, alt = {**ctexts, **vt}, ({j: ctexts[j] for j in vt} if source != "vision" else {})
        mode = source.split("-")[0]
        near = []
        for lab, js in (("P", before), ("N", after)):
            for i, j in enumerate(js, 1):
                cs = union_cands(texts[j], alt[j], mode) if alt else candidates(texts[j])
                near.append({"label": f"{lab}{i}", "dist": i if lab == "P" else -i, "text": texts[j],
                             "alt": alt.get(j), "pick": rule_pick(cs)})
        doc = {"id": "o:" + d["id"], "set": "owner", "cls": cls.get(d["id"], "decade" if d["class"] == "decade" else None),
               "kind": d["class"], "truth": d["truth"], "text": texts[k], "collection": d["collection"],
               "folder": info["folder"], "position": k, "near": near, "prompt": d["prompt"]}
        if alt:
            doc["alt"], doc["cands"] = alt[k], union_cands(texts[k], alt[k], mode)
        out.append(doc)
    return out


def reread_classes():
    """date_truth's classes with a year counting as printed when it is in the corpus text OR in Apple Vision's text of
    the document's first two pages ({id: class}, owner ids "o:…"). Vision text exists for the 300 and the three
    documents either side of each, so a class that looks further (C against D, the nearest printed same-year document
    anywhere in the folder) reads the corpus text alone beyond them. The definitions are date_truth's and
    enclosure_split's own, called with their printed-year test swapped."""
    import date_truth as DTr
    import enclosure_split as ES
    sample, found = ES.load()
    orig = ES.own_year_in_text

    def printed(k, info):
        if orig(k, info):
            return True
        tr = info["truths"][k][1]
        if not tr or "year" not in tr:
            return False
        vt = vision_text(info["segs"][k]["pages"])
        return vt is not None and str(tr["year"]) in vt[:TEXT_CHARS]

    ES.own_year_in_text = printed
    try:
        rows = ES.build_rows(sample, found, labels=())
        for r in rows:
            r["year_in_text"] = printed(found[r["id"]]["k"], found[r["id"]])
        cls = {r["id"]: DTr.structural_class(r, found[r["id"]], found) for r in rows}
    finally:
        ES.own_year_in_text = orig
    return {"o:" + d["id"]: cls.get(d["id"], "decade" if d["class"] == "decade" else None)
            for d in sample if d["id"] in found}


def public_docs():
    p = os.path.join(DT.CACHE, "public", "public.jsonl")
    out = []
    for line in open(p, encoding="utf-8"):
        d = json.loads(line)
        if not d.get("test", True):
            continue
        t = d["truth"]
        out.append({"id": "p:" + d["id"], "set": "public", "cls": "in text" if d["year_in_text"] else "not in text",
                    "kind": d["precision"], "truth": {"year": t["year"], "month": t["month"], "du": False},
                    "text": DT.doc_text(d["prompt"]), "collection": d["collection"], "folder": None, "position": None, "near": [],
                    "prompt": d["prompt"]})
    return out


def shots_for(doc, pool):
    """Five labelled documents from the same collection, as a user's already-tagged documents would be: other folders
    first, then the document's own folder at more than three positions away (the neighbours the prompt already
    shows are never repeated as examples), each group in a seeded shuffle of the pool."""
    rng = random.Random(f"{SEED}:{doc['id']}")
    same = pool.get(doc["collection"], [])
    other = [p for p in same if p["folder"] != doc["folder"]]
    own = [p for p in same if p["folder"] == doc["folder"] and abs(p["position"] - doc["position"]) > NEAR]
    rng.shuffle(other)
    rng.shuffle(own)
    return (other + own)[:SHOTS]


def shot_pool(exclude):
    """date_tagging's agreed, year-tagged pool less the 300, by collection: [{text, year, folder}]."""
    pool, _ = DT.document_pool()
    out = collections.defaultdict(list)
    for cls_, ds in pool.items():
        if cls_ == "decade":
            continue
        for d in ds:
            if d["id"] in exclude:
                continue
            out[d["collection"]].append({"text": DT.doc_text(d["prompt"])[:300], "year": d["truth"]["year"],
                                         "folder": d["folder"], "position": d["position"]})
    return out


# ---- prompts --------------------------------------------------------------------------------------------------------

CHOOSE = """A rule found these dates in the OCR text of a document from a historical archive. Which one is the date the document itself was written (not a date it mentions, quotes or refers back to)?

The document's OCR text:
---
{text}
---

Candidates (each with the line it appears on):
{cands}

Respond with ONLY a JSON object: {{"choice": 2}} giving the candidate's number, or {{"choice": null}} if none of them is the document's own date."""

TRACE = """You are dating a document from a historical archive for a scholar who will check your evidence.

The document's OCR text (id "self"):
---
{text}
---

Nearby documents from the same folder, in folder order (P1 is just before this document, N1 just after), each headed by its id:
{near}
{extra}
Give the year this document was written.
- If the document prints its own date, use that year and quote the date from "self".
- Otherwise estimate it from the nearby documents: quote the nearby text that carries the year and give that document's id.
- Give an interval lo to hi that you are 90% sure contains the year (lo = hi when the document prints its date).
- date_uncertain is true when this document does not print its own year.
- A quote must be copied exactly from the document you cite and must contain the year. If nothing supports any year, give "year": null.

Respond with ONLY a JSON object, for example:
{{"year": 1947, "lo": 1946, "hi": 1948, "date_uncertain": true, "evidence": {{"neighbour": "P1", "quote": "March 3, 1947"}}}}"""


def cand_lines(cs):
    return "\n".join(f'{i}. {c["year"]} (line {c["line_no"] + 1}: "{c["line"]}")' for i, c in enumerate(cs, 1))


def choose_prompt(doc, cs):
    return CHOOSE.format(text=doc["text"][:TEXT_CHARS], cands=cand_lines(cs))


def near_block(doc):
    if not doc["near"]:
        return "(none)\n"
    order = sorted(doc["near"], key=lambda n: -n["dist"])     # P3 P2 P1 N1 N2 N3
    return "".join(f"[{n['label']}]\n{n['text'][:NEAR_CHARS]}\n---\n" for n in order)


def trace_prompt(doc, variant, shots=()):
    extra = ""
    if variant == "neigh":
        ls = []
        for n in sorted(doc["near"], key=lambda n: -n["dist"]):
            y, _, conf, c = n["pick"]
            if y is not None:
                ls.append(f'[{n["label"]}] {y} ("{c["line"]}")')
        extra = ("\nDates a rule found printed in the nearby documents (id, year, the line):\n"
                 + ("\n".join(ls) if ls else "(none found)") + "\n")
    elif variant == "shots":
        extra = (f"\nOther documents from the same collection, with the year the archivist gave each (examples of "
                 f"the collection's span, not neighbours of this document):\n"
                 + ("".join(f"Example {i} ({s['year']}):\n{s['text']}\n---\n" for i, s in enumerate(shots, 1))
                    or "(none tagged yet)\n"))
    return TRACE.format(text=doc["text"][:TEXT_CHARS], near=near_block(doc), extra=extra)


def reply_json(raw):
    s = DT.strip_reasoning(raw or "").strip()
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


def _int(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return int(v)
    if isinstance(v, str) and re.fullmatch(r"\s*\d{4}\s*", v):
        return int(v)
    return None


def parse_trace(raw):
    """{parsed, y, lo, hi, du, evidence} of a trace reply. An interval that does not contain the year, or is missing,
    becomes the point year (reported as `bad_interval`)."""
    js = reply_json(raw)
    if js is None:
        return {"parsed": False, "y": None, "lo": None, "hi": None, "du": True, "evidence": None, "bad_interval": False,
                "short_evidence": False}
    y = _int(js.get("year"))
    if y is not None and not LO <= y <= HI:
        y = None
    lo, hi, bad = _int(js.get("lo")), _int(js.get("hi")), False
    if y is not None and (lo is None or hi is None or not lo <= y <= hi):
        bad, lo, hi = True, y, y
    if y is None:
        lo = hi = None
    ev = js.get("evidence") if isinstance(js.get("evidence"), dict) else None
    short = False
    if ev and "quote" not in ev and len(ev) == 1:
        (k, v), = ev.items()
        if isinstance(v, str) and re.fullmatch(r"self|[PN]\d", k):
            ev, short = {"neighbour": k, "quote": v}, True     # {"P1": "May 2, 1947"}: the same citation, shortened
    return {"parsed": True, "y": y, "lo": lo, "hi": hi, "du": js.get("date_uncertain") is not False,
            "evidence": ev, "bad_interval": bad, "short_evidence": short}


def parse_choice(raw, cs):
    js = reply_json(raw)
    if js is None:
        return None, False
    c = js.get("choice")
    if isinstance(c, bool) or c is None:
        return None, True
    try:
        c = int(c)
    except (TypeError, ValueError):
        return None, False
    return (cs[c - 1] if 1 <= c <= len(cs) else None), True


def context_of(doc, variant="plain"):
    """What a trace prompt gave the model, by the ids it may cite (evidence_check's context). "neigh" adds each
    neighbour's rule line, which that prompt shows; "rules" is what the rule stage read (3,000 characters of each)."""
    ctx = {"self": doc["text"][:TEXT_CHARS]}
    if variant == "rules" and doc.get("alt"):
        ctx["self"] += "\n" + doc["alt"][:TEXT_CHARS]
    for n in doc["near"]:
        ctx[n["label"]] = n["text"][:TEXT_CHARS if variant == "rules" else NEAR_CHARS]
        if variant == "rules" and n.get("alt"):
            ctx[n["label"]] += "\n" + n["alt"][:TEXT_CHARS]
        if variant == "neigh" and n["pick"][3] is not None:
            ctx[n["label"]] += "\n" + n["pick"][3]["line"]
    return ctx


# ---- the pack and the answers ---------------------------------------------------------------------------------------

def all_docs(with_shots=True):
    owner = owner_docs()
    pub = public_docs()
    pool = shot_pool({d["id"][2:] for d in owner}) if with_shots else {}
    return owner, pub, pool


def requests(owner, pub, pool):
    """[(id, prompt)]: choose on every ambiguous rule pick; trace-plain on all 600; trace-neigh and trace-shots on the
    owner's 300 (the public set has neither folder neighbours nor a labelled same-collection pool)."""
    out = []
    for d in owner + pub:
        cs = candidates(d["text"])
        if rule_pick(cs)[2] == "ambiguous":
            out.append(("choose|" + d["id"], choose_prompt(d, distinct(cs))))
        out.append(("trace-plain|" + d["id"], trace_prompt(d, "plain")))
    for d in owner:
        out.append(("trace-neigh|" + d["id"], trace_prompt(d, "neigh")))
        out.append(("trace-shots|" + d["id"], trace_prompt(d, "shots", shots_for(d, pool))))
    # A wave's pilot answers the first three: make them three different prompts (choose, trace-neigh, trace-shots).
    for arm in ("trace-shots|", "trace-neigh|", "choose|"):
        i = next(k for k, (i_, _) in enumerate(out) if i_.startswith(arm))
        out.insert(0, out.pop(i))
    return out


def requests_vision(vis):
    """[(id, prompt)] of the Vision-text pack (W46.date-traceable-vision): choose on every ambiguous rule pick and
    trace-neigh on all of the owner's documents, both built from Apple Vision text. Same ids as the corpus-text pack;
    the replies are imported under LABEL_VISION."""
    out = []
    for d in vis:
        cs = candidates(d["text"])
        if rule_pick(cs)[2] == "ambiguous":
            out.append(("choose|" + d["id"], choose_prompt(d, distinct(cs))))
        out.append(("trace-neigh|" + d["id"], trace_prompt(d, "neigh")))
    i = next(k for k, (i_, _) in enumerate(out) if i_.startswith("choose|"))
    out.insert(0, out.pop(i))
    return out


def cmd_export(a):
    if a.source == "vision":
        reqs = requests_vision(owner_docs("vision"))
    else:
        owner, pub, pool = all_docs()
        reqs = requests(owner, pub, pool)
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "requests.jsonl"), "w", encoding="utf-8") as fh:
        for i, p in reqs:
            fh.write(json.dumps({"id": i, "prompt": p}, ensure_ascii=False) + "\n")
    c = collections.Counter(i.split("|")[0] for i, _ in reqs)
    print(f"{len(reqs)} prompts -> {a.out}/requests.jsonl", dict(c))


def cmd_import(a):
    os.makedirs(CACHE, exist_ok=True)
    rows = [json.loads(l) for l in open(a.answers, encoding="utf-8") if l.strip()]
    rows = [r for r in rows if "raw" in r]
    dest = os.path.join(CACHE, f"answers-{a.label}.jsonl")
    with open(dest, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    if a.summary:
        import shutil
        shutil.copyfile(a.summary, os.path.join(CACHE, f"summary-{a.label}.json"))
    print(f"{len(rows)} answers -> {dest}")


def load_answers(label):
    p = os.path.join(CACHE, f"answers-{label}.jsonl")
    if not os.path.exists(p):
        return {}
    return {r["id"]: r for r in (json.loads(l) for l in open(p, encoding="utf-8") if l.strip())}


def one_shot(doc, label):
    """A cached one-shot reply to the app's prompt: (y, du, parsed) or None when not cached. Gemini is label None; the
    2B's answers live in Long term storage (date-model.md)."""
    if label and label.startswith("mlx-") or label and label.startswith("fs-"):
        sub = "public/" if doc["set"] == "public" else ""
        p = os.path.join(LTS_2B, sub + "answers-" + label, DT.prompt_id(doc["prompt"]) + ".json")
    else:
        p = DT.answer_path(doc["prompt"], label)
        if doc["set"] == "public":
            p = p.replace(DT.CACHE, os.path.join(DT.CACHE, "public"), 1)
    if not os.path.exists(p):
        return None
    year, _, du, parsed = DT.app_parse(json.load(open(p)))
    y = int(year) if year and re.fullmatch(r"\d{4}", year) else None
    return y, du, parsed


# ---- the pipeline ---------------------------------------------------------------------------------------------------

def propagate(doc):
    """(year, dist, evidence) from the nearest earlier document whose text prints a date, or (None, None, None)."""
    for n in sorted((n for n in doc["near"] if n["dist"] > 0), key=lambda n: n["dist"]):
        y, _, _, c = n["pick"]
        if y is not None:
            return y, n["dist"], {"neighbour": n["label"], "quote": c["line"]}
    return None, None, None


def row(doc, stage, y, du, parsed=True, lo=None, hi=None, evidence=None, verdict=None):
    r = {"id": doc["id"], "set": doc["set"], "cls": doc["cls"], "truth": doc["truth"], "stage": stage, "y": y,
         "parsed": parsed, "du_pred": du, "evidence": evidence, "verdict": verdict}
    if y is not None:
        r["lo"], r["hi"] = (lo if lo is not None else y), (hi if hi is not None else y)
    return r


def pipeline(doc, chooser, residue, threshold, variant="plain"):
    """One document through the stages. chooser: None (rule pick stands), "2b" or a dict of 27B choose replies.
    residue: a dict of trace replies for one variant, or None (no residue stage: unreached documents get no year)."""
    cs = doc.get("cands") or candidates(doc["text"])
    y, _, conf, c = rule_pick(cs)
    calls = []
    if y is not None:
        stage = "rule"
        if conf == "ambiguous" and chooser is not None:
            calls.append("2b" if chooser == "2b" else "choose")
            if chooser == "2b":
                got = one_shot(doc, "mlx-date-2b-8bit-nothink")
                if got and got[0] in {x["year"] for x in cs}:
                    pick = next(x for x in distinct(cs) if x["year"] == got[0])
                    y, c, stage = got[0], pick, "chooser"
            else:
                ans = chooser.get("choose|" + doc["id"])
                if ans:
                    pick, ok = parse_choice(ans["raw"], distinct(cs))
                    if pick is not None:
                        y, c, stage = pick["year"], pick, "chooser"
        ev = {"neighbour": "self", "quote": c["line"]}
        return {**row(doc, stage, y, False, evidence=ev, verdict=S.evidence_check(y, ev, context_of(doc, "rules"))[0]),
                "calls": calls}
    py, dist, ev = propagate(doc)
    if py is not None and dist <= threshold:
        return {**row(doc, "propagated", py, True, evidence=ev,
                      verdict=S.evidence_check(py, ev, context_of(doc, "rules"))[0]),
                "calls": calls}
    if residue is None:
        return {**row(doc, "none", None, True), "calls": calls}
    calls.append("trace-" + variant)
    ans = residue.get(doc["id"])
    if ans is None:
        return {**row(doc, "residue-missing", None, True, parsed=False), "calls": calls}
    t = parse_trace(ans["raw"])
    v = S.evidence_check(t["y"], t["evidence"], context_of(doc, variant))[0]
    return {**row(doc, "residue", t["y"], t["du"], t["parsed"], t["lo"], t["hi"], t["evidence"], v), "calls": calls}


def trace_rows(docs, answers, variant):
    out = []
    for d in docs:
        a = answers.get(f"trace-{variant}|{d['id']}")
        if a is None:
            continue
        t = parse_trace(a["raw"])
        v = S.evidence_check(t["y"], t["evidence"], context_of(d, variant))[0]
        r = row(d, "one-shot-trace", t["y"], t["du"], t["parsed"], t["lo"], t["hi"], t["evidence"], v)
        r["bad_interval"] = t["bad_interval"]
        r["short_evidence"] = t["short_evidence"]
        r["wall_s"] = a.get("wall_s")
        out.append(r)
    return out


# ---- scoring --------------------------------------------------------------------------------------------------------

OWNER_STRATA = ("in text", "A", "A'", "B", "C", "D", "decade")


def strata_of(rows, setname):
    if setname == "public":
        return {"in text": [r for r in rows if r["cls"] == "in text"],
                "not in text": [r for r in rows if r["cls"] == "not in text"], "all": rows}
    by = {c: [r for r in rows if r["cls"] == c] for c in OWNER_STRATA}
    yr = [r for r in rows if "year" in r["truth"]]
    return {**by, "A+A'+B": by["A"] + by["A'"] + by["B"], "C+D": by["C"] + by["D"],
            "not in text": [r for r in yr if r["cls"] != "in text"], "all year-tagged": yr, "all": rows}


def summary(rows, setname):
    st = strata_of(rows, setname)
    ev = collections.Counter(r["verdict"] or "none" for r in rows if r["y"] is not None)
    return {"n": len(rows),
            "exact": {k: S.tolerance_curve(v, 1)[0] for k, v in st.items()},
            "within1": {k: S.tolerance_curve(v, 1)[1] for k, v in st.items()},
            "invalid": S.invalid_rate(rows),
            "stages": dict(collections.Counter(r["stage"] for r in rows)),
            "evidence": dict(ev),
            "right_unsupported": sum(1 for r in rows if r["verdict"] == "unsupported" and r["y"] is not None
                                     and S.interval_distance(r["y"], *S.truth_interval(r["truth"])) == 0),
            "conformal": {k: S.conformal(v, ALPHA) for k, v in st.items()
                          if k in ("in text", "A+A'+B", "C+D", "not in text", "all")},
            "du": S.du_error_rates([r for r in rows if "du" in r["truth"]]) if setname == "owner" else None}


def stage_rule_report(docs):
    """Stage 1 alone: candidate recall (the truth year among the candidates) and the pick, by class and confidence."""
    out = {}
    for setname in ("owner", "public"):
        ds = [d for d in docs if d["set"] == setname and "year" in d["truth"]]
        by = collections.defaultdict(lambda: collections.Counter())
        t0 = time.monotonic()
        for d in ds:
            cs = candidates(d["text"])
            y, _, conf, _ = rule_pick(cs)
            k = by[d["cls"]]
            k["latest right"] += rule_pick(cs, mode="latest")[0] == d["truth"]["year"]
            k["n"] += 1
            k["with candidates"] += bool(cs)
            k["truth among candidates"] += d["truth"]["year"] in {c["year"] for c in cs}
            k["pick right"] += y == d["truth"]["year"]
            k[f"{conf}"] += 1
            k[f"{conf} right"] += y == d["truth"]["year"]
        out[setname] = {"by_class": {c: dict(v) for c, v in by.items()},
                        "ms_per_doc": round(1000 * (time.monotonic() - t0) / max(1, len(ds)), 2)}
    return out


def cmd_rules(a):
    owner, pub, _ = all_docs(with_shots=False)
    print(json.dumps(stage_rule_report(owner + pub), indent=1))


MAC_2B_S = 1.39     # the 8-bit 2B on this Mac, seconds a document (date-model.md)


def arm_seconds(answers, label):
    """GPU-seconds a reply for each arm: the full job's wall time (cluster_text's summary, one L40S, 16 concurrent)
    shared out over the replies by tokens (prompt plus completion). An estimate of the split; the total is measured."""
    p = os.path.join(CACHE, f"summary-{label}.json")
    if not answers or not os.path.exists(p):
        return {}
    wall = json.load(open(p))["wall_s"]
    tok = collections.Counter()
    n = collections.Counter()
    for i, a in answers.items():
        u = a.get("usage") or {}
        arm = i.split("|")[0]
        tok[arm] += u.get("prompt_tokens", 0) + u.get("completion_tokens", 0)
        n[arm] += 1
    total = sum(tok.values()) or 1
    return {arm: wall * tok[arm] / total / n[arm] for arm in n}


def per_1000(rows, secs):
    """{gpu_s, mac_s} per 1,000 documents of a configuration: each call its arm's seconds; the 2B runs on the Mac."""
    gpu = sum(secs.get(c, 0) for r in rows for c in r.get("calls", ()) if c != "2b")
    mac = sum(MAC_2B_S for r in rows for c in r.get("calls", ()) if c == "2b")
    k = 1000 / max(1, len(rows))
    return {"gpu_s": round(gpu * k, 1), "mac_s": round(mac * k, 1),
            "calls": dict(collections.Counter(c for r in rows for c in r.get("calls", ())))}


def cmd_score(a):
    owner, pub, _ = all_docs(with_shots=False)
    ans = load_answers(LABEL_27B)
    secs = arm_seconds(ans, LABEL_27B)
    out = {"alpha": ALPHA, "label": LABEL_27B, "answers": len(ans), "rules": stage_rule_report(owner + pub),
           "one_shot": {}, "trace": {}, "pipeline": {}, "cost": {}}
    for setname, docs in (("owner", owner), ("public", pub)):
        for lab, name in ((None, DT.MODEL), ("qwen3.6-27b-nothink", "qwen3.6-27b-nothink (app prompt)"),
                          ("mlx-date-2b-8bit-nothink", "mlx-date-2b-8bit-nothink (app prompt)")):
            rs = []
            for d in docs:
                got = one_shot(d, lab)
                if got is None:
                    continue
                rs.append(row(d, "one-shot", got[0], got[1], got[2]))
            if len(rs) == len(docs):
                out["one_shot"][f"{setname}|{name}"] = summary(rs, setname)
        for v in ("plain", "neigh", "shots"):
            rs = trace_rows(docs, ans, v)
            if rs and len(rs) == len(docs):
                s = summary(rs, setname)
                s["bad_interval"] = sum(r["bad_interval"] for r in rs)
                s["short_evidence"] = sum(r["short_evidence"] for r in rs)
                out["trace"][f"{setname}|{v}"] = s
        choosers = [("rules only", None), ("2B chooser", "2b")] + ([("27B chooser", ans)] if ans else [])
        residues = [("no residue stage", None)] + [(f"27B trace-{v}", {d["id"]: ans[f"trace-{v}|{d['id']}"]
                                                                         for d in docs if f"trace-{v}|{d['id']}" in ans})
                                                    for v in (("plain", "neigh", "shots") if setname == "owner" else ("plain",))
                                                    if ans]
        for cn, ch in choosers:
            for rn, res in residues:
                for t in THRESHOLDS if setname == "owner" and res is not None else (NEAR,):
                    v = rn.rsplit("-", 1)[-1] if res is not None else "plain"
                    rs = [pipeline(d, ch, res, t, v) for d in docs]
                    key = f"{setname}|{cn}|{rn}|t={t}"
                    out["pipeline"][key] = {**summary(rs, setname), "per_1000": per_1000(rs, secs)}
    vis = owner_docs("vision")
    if vis:
        ids = {d["id"] for d in vis}
        out["vision"] = {"documents": len(vis), "rules": stage_rule_report(vis)["owner"]}
        for cn, ch in (("rules only", None), ("2B chooser", "2b")):
            out["vision"][cn] = summary([pipeline(d, ch, None, NEAR) for d in vis], "owner")
            out["vision"][cn + " (corpus text, same documents)"] = summary(
                [pipeline(d, ch, None, NEAR) for d in owner if d["id"] in ids], "owner")
        tf = os.path.join(VISION, "timing.jsonl")
        if os.path.exists(tf):
            ts = [json.loads(l) for l in open(tf)]
            n = sum(t["read_now"] for t in ts)
            out["vision"]["seconds_per_page"] = round(sum(t["render_s"] + t["read_s"] for t in ts) / max(1, n), 2)
        out["vision_arms"] = vision_arms(owner, vis, ans)
    for arm in ("choose", "trace-plain", "trace-neigh", "trace-shots"):
        out["cost"][arm] = {"gpu_s_per_reply": secs.get(arm), "n": sum(1 for i in ans if i.startswith(arm + "|"))}
    os.makedirs(os.path.dirname(RESULTS_JSON), exist_ok=True)
    with open(RESULTS_JSON, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=1)
    write_md(out)
    print(f"{len(out['pipeline'])} pipeline configurations scored -> {RESULTS}")


def vision_arms(owner, vis, ans):
    """W46.date-traceable-vision: the 27B's chooser and residue on Vision text, the rules on the union of both texts,
    and every configuration scored twice, on date_truth's classes and on the classes re-read with Vision text
    (`reread_classes`). The 300 one-shot replies and the corpus-text pipeline are re-scored on the same documents so
    the two class tables compare like with like."""
    va = load_answers(LABEL_VISION)
    ids = {d["id"] for d in vis}
    corpus = [d for d in owner if d["id"] in ids]
    rc = reread_classes()
    union = {s: owner_docs(s) for s in SOURCES[2:]}
    res_c = {d["id"]: ans[f"trace-neigh|{d['id']}"] for d in corpus if f"trace-neigh|{d['id']}" in ans}
    res_v = {d["id"]: va[f"trace-neigh|{d['id']}"] for d in vis if f"trace-neigh|{d['id']}" in va}
    cfg = []
    for lab, name in ((None, DT.MODEL), (LABEL_27B, "27B one shot, app prompt"),
                      ("mlx-date-2b-8bit-nothink", "2B one shot, app prompt")):
        rs = [row(d, "one-shot", *got) for d in corpus for got in [one_shot(d, lab)] if got is not None]
        if len(rs) == len(corpus):
            cfg.append((f"{name} (corpus text)", rs))
    cfg.append(("27B trace-neigh one shot (corpus text)", trace_rows(corpus, ans, "neigh")))
    if len(res_v) == len(vis):
        cfg.append(("27B trace-neigh one shot (Vision text)", trace_rows(vis, va, "neigh")))
    cfg.append(("corpus text: 2B chooser|27B trace-neigh|t=3", [pipeline(d, "2b", res_c, NEAR, "neigh") for d in corpus]))
    choosers = [("rules only", None), ("2B chooser", "2b")] + ([("27B chooser", va)] if va else [])
    for cn, ch in choosers:
        for rn, res, ts in (("no residue stage", None, (NEAR,)), ("27B trace-neigh", res_v if va else None, (0, NEAR))):
            if res is None and rn != "no residue stage":
                continue
            for t in ts:
                cfg.append((f"Vision text: {cn}|{rn}|t={t}", [pipeline(d, ch, res, t, "neigh") for d in vis]))
    for src, docs in union.items():
        first = "corpus" if src.endswith("-abbyy") else "Vision"
        how = "first" if src.startswith("union") else "else the other"
        for cn, ch in (("rules only", None), ("2B chooser", "2b")):
            # the residue's replies are the ones whose prompt carried the primary text, so their quotes check against it
            for rn, res in (("no residue stage", None),
                            ("27B trace-neigh", res_c if src.endswith("-abbyy") else (res_v if va else None))):
                if res is None and rn != "no residue stage":
                    continue
                cfg.append((f"{src.split('-')[0]}, {first} {how}: {cn}|{rn}|t={NEAR}",
                            [pipeline(d, ch, res, NEAR, "neigh") for d in docs]))
    secs = {**arm_seconds(va, LABEL_VISION)}
    out = {"documents": len(vis), "answers": len(va), "configs": {},
           "classes": {"corpus": dict(collections.Counter(d["cls"] for d in vis)),
                       "reread": dict(collections.Counter(rc[d["id"]] for d in vis))},
           "moved": dict(collections.Counter(f"{d['cls']} -> {rc[d['id']]}" for d in vis if d["cls"] != rc[d["id"]])),
           "cost": {arm: {"gpu_s_per_reply": secs.get(arm), "n": sum(1 for i in va if i.startswith(arm + "|"))}
                    for arm in ("choose", "trace-neigh")}}
    for name, rs in cfg:
        rr = [{**r, "cls": rc[r["id"]]} for r in rs]
        out["configs"][name] = {"corpus": summary(rs, "owner"), "reread": summary(rr, "owner"),
                                "per_1000": per_1000(rs, secs) if any(r.get("calls") for r in rs) else None}
    return out


def pc(x):
    return f"{100 * x[0] / x[1]:.1f}%" if x and x[1] else "–"


def findings(out):
    """The run's reading, from the figures in `out`; empty until the 27B's replies are in."""
    P, O = out["pipeline"], out["one_shot"]
    need = ("owner|2B chooser|no residue stage|t=3", "owner|2B chooser|27B trace-neigh|t=3",
            "owner|2B chooser|27B trace-neigh|t=0", "owner|27B chooser|no residue stage|t=3")
    if not all(k in P for k in need) or "owner|neigh" not in out["trace"]:
        return []

    def f(s, c):
        return pc(s["exact"][c])
    g, q = O["owner|" + DT.MODEL], O["owner|qwen3.6-27b-nothink (app prompt)"]
    base, t3, t0, c27 = (P[k] for k in need)
    tn, tp = out["trace"]["owner|neigh"], out["trace"]["owner|plain"]
    cost = out["cost"]
    L = ["## Findings", "",
         f"- **The staged pipeline does not beat one shot on the years that matter.** On the 131 documents whose year "
         f"is not in the corpus text, the best staged configuration (rules, the 2B chooser, the 27B with neighbour "
         f"dates on what propagation cannot reach, t=3) gets {f(t3, 'not in text')}; Gemini 3.8 Flash one shot gets "
         f"{f(g, 'not in text')}, the 27B one shot {f(q, 'not in text')} with the app's prompt and "
         f"{f(tn, 'not in text')} with the trace prompt and neighbour dates. Sending every undated document to the 27B "
         f"(t=0) gives {f(t0, 'not in text')}.",
         f"- **It is far cheaper.** The t=3 configuration makes {t3['per_1000']['calls'].get('trace-neigh', 0) * 1000 // 300} "
         f"27B calls per 1,000 documents ({t3['per_1000']['gpu_s']:.0f} GPU-seconds) against 1,000 for one shot "
         f"(about {1000 * (cost['trace-neigh']['gpu_s_per_reply'] or 0):.0f} GPU-seconds with the same prompt).",
         f"- **On printed years the rules plus a small chooser come close to the models.** Rules alone "
         f"{pc(P['owner|rules only|no residue stage|t=3']['exact']['in text'])}, "
         f"with the 2B's reply as chooser {f(base, 'in text')} (Gemini {f(g, 'in text')}). The 27B as chooser is worse "
         f"than the 2B ({f(c27, 'in text')}): where the 2B named the document's own year, the 27B kept or chose a year "
         f"the text mentions in passing (\"in the spring of 1961\").",
         f"- **Propagation alone is as good as the models on class A, at no cost.** Taking the nearest earlier dated document's "
         f"year gets A {f(base, 'A')} and A' {f(base, chr(65) + chr(39))} (Gemini {f(g, 'A')}, the 27B {f(q, 'A')}), "
         f"but B {f(base, 'B')}, C {f(base, 'C')}: beyond the previous document it mostly propagates a wrong year, "
         f"and escalating more (lower t) trades A for B. W46.date-enclosure's relation classifier is what would decide "
         f"which documents to propagate to; it has not shipped.",
         f"- **A third of the 27B's citations fail the check, and many of those years are right.** Trace-plain: "
         f"{tp['evidence'].get('valid', 0)} valid, {tp['evidence'].get('unsupported', 0)} unsupported, "
         f"{tp['right_unsupported']} of them with the right year. Reading the failures, most are a quote that does not "
         f"carry the year as four digits, often because the model read through OCR damage (\"27 April I 96I4\", \"feb, 2 4 , >964\", "
         f"\"September 22, 19gS\") or a two-digit date, and the checker, which wants the four digits in the quote, "
         f"refuses them. The rest quote text that is not in the cited document. {tp.get('short_evidence', 0)} of 300 "
         f"replies wrote the citation as {{\"self\": quote}} rather than the asked shape and were read as the same "
         f"citation. Conformal intervals reach about 90% coverage, but the widths (decades on the pipelines) come "
         f"from a few far-wrong rule picks (1800 from a figure, 2026 from a capture footer), not from honest uncertainty."]
    v = out.get("vision")
    if v and "rules only" in v:
        L.append(f"- **Apple Vision text dates more of the 'unprinted' documents than the corpus text does.** The rule "
                 f"stage and propagation on Vision text of the first two pages get {f(v['rules only'], 'not in text')} of "
                 f"the 131 (corpus text {f(v['rules only (corpus text, same documents)'], 'not in text')}), on the Mac "
                 f"at about {v.get('seconds_per_page', 1):.0f} s a page and $0: many of these documents do print their "
                 f"date, and ABBYY's layer garbled it (\"ISIS\" for 1915, \"19gS\"). The classes A to D are defined on "
                 f"the corpus text, so part of the 'not in text' gap is OCR, not dating. On printed years Vision rules "
                 f"read fewer ({f(v['rules only'], 'in text')} against {f(v['rules only (corpus text, same documents)'], 'in text')}). "
                 f"Filed: W46.date-traceable-vision, the residue and chooser on Vision text.")
    L += ["- Not in this run: the Gemini arm (W46.date-traceable-paid, waits for W46.gateway-models-ok), the claude -p "
          "arm (held for the gateway, CLAUDE.md), the relation classifier (W46.date-enclosure), Foundation Models as "
          "the R1 chooser. The latest-year rule variant was written after reading the first rule's misses on the "
          "owner's set, so its owner figure is tuned; the public set is its check.", ""]
    return L


def write_md(out):
    L = ["# Dating: the staged pipeline against one shot, with the evidence checked (W46.date-traceable)", "",
         "Written by `scripts/segbench/date_traceable.py score`. The owner's 300 (W41's sample: 119 print their year, "
         "131 do not, 50 decade tags) and the public 300 (Library of Congress By the People transcriptions, catalogue "
         "dates). Classes are date_truth's: A the previous document prints the same year, A' chained through it, B a "
         "printed same-year document within three, C four or more away, D none in the folder. $0: the 27B ran on "
         "FarmShare, the 2B's replies are W41's cached ones; the Gemini arm is W46.date-traceable-paid, the claude -p "
         "arm waits for W46.gateway-models-ok.", ""]
    L += findings(out)
    L += ["## Stage 1: rule candidates", "",
          "Every date printed in the first 3,000 characters (full dates, numeric dates, month-year, bare years "
          "1800-2030), each with its line. The pick is the first dated form in the first 15 lines, else the most "
          "weighted year. Sure = every dated form agrees; ambiguous = the chooser's cases.", "",
          "| set | class | n | any candidate | truth among them | pick right | sure (right) | single (right) | ambiguous (right) | latest-year rule right |",
          "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for setname, rep in out["rules"].items():
        for c, k in sorted(rep["by_class"].items(), key=lambda kv: (OWNER_STRATA + ("not in text",)).index(kv[0])
                           if kv[0] in OWNER_STRATA + ("not in text",) else 99):
            n = k["n"]
            L.append(f"| {setname} | {c} | {n} | {k.get('with candidates', 0)} | {k.get('truth among candidates', 0)} | "
                     f"{k.get('pick right', 0)} ({pc([k.get('pick right', 0), n])}) | "
                     + " | ".join(f"{k.get(x, 0)} ({k.get(x + ' right', 0)})" for x in ("sure", "single", "ambiguous"))
                     + f" | {k.get('latest right', 0)} ({pc([k.get('latest right', 0), n])}) |")
        L.append(f"| {setname} | rule time | | | | {rep['ms_per_doc']} ms a document on this Mac | | | | |")
    L += [""]

    def table(title, items, owner_cols, note=""):
        L.extend([f"## {title}", ""] + ([note, ""] if note else []))
        cols = ("in text", "A", "A'", "B", "C", "D", "not in text", "decade") if owner_cols else ("in text", "not in text", "all")
        L.append("| configuration | " + " | ".join(cols) + " | within 1, all | invalid | evidence valid / unsupported | right but unsupported | 90% conformal coverage, width (not in text) |")
        L.append("|---|" + "---:|" * (len(cols) + 5))
        for k, s in items:
            cf = s["conformal"].get("not in text")
            if not cf:
                cov = "–"
            elif any(math.isinf(q) for q in cf["q"]):
                cov = f"{pc(cf['coverage'])}, unbounded ({cf['no_year']} with no year)"
            else:
                cov = f"{pc(cf['coverage'])}, {cf['width']:.1f} y"
            ev = s["evidence"]
            evs = (f"{ev.get('valid', 0)} / {ev.get('unsupported', 0)} | {s['right_unsupported']}"
                   if ev.get("valid") or ev.get("unsupported") else "none asked | –")
            L.append(f"| {k} | " + " | ".join(pc(s['exact'].get(c)) for c in cols)
                     + f" | {pc(s['within1'].get('all'))} | {s['invalid'][0]}/{s['invalid'][1]} | {evs} | {cov} |")
        L.append("")

    for setname in ("owner", "public"):
        oc = setname == "owner"
        table(f"One shot, {setname} set (exact year)", [(k.split("|", 1)[1], s) for k, s in out["one_shot"].items()
                                                         if k.startswith(setname + "|")]
              + [("27B trace-" + k.split("|", 1)[1], s) for k, s in out["trace"].items() if k.startswith(setname + "|")],
              oc, "The app's prompt (cached W41 replies) and the trace prompt sent to every document.")
        table(f"The staged pipeline, {setname} set (exact year)",
              [(k.split("|", 1)[1], s) for k, s in out["pipeline"].items() if k.startswith(setname + "|")], oc,
              "t = the escalation threshold: a document printing no date takes the year of the nearest earlier "
              "document printing one when that is at most t documents back, else goes to the residue stage. t=0 "
              "sends every undated document there; t=3 only those propagation cannot reach (it looks three back). "
              "A row with no residue stage gives no year to what propagation does not reach.")
    if out.get("vision"):
        v = out["vision"]
        table("The Vision-text arm (R1), owner set (exact year)",
              [(k, v[k]) for k in ("rules only", "rules only (corpus text, same documents)", "2B chooser",
                                   "2B chooser (corpus text, same documents)")], True,
              f"The rule stage and propagation on Apple Vision text (the app's settings, segbench `ocr.swift`) of the "
              f"first two pages of each document and of the three before it, {v['documents']} documents, beside the "
              f"corpus text cache on the same documents. Rendering and reading took {v.get('seconds_per_page', '–')} s "
              f"a page on this Mac. The 2B chooser's replies were made from the corpus text; on Vision text it is kept "
              f"only when it names a Vision candidate. The route's own chooser (Foundation Models) is not measured.")
    va = out.get("vision_arms")
    if va:
        order = OWNER_STRATA
        L += ["## The chooser and the residue on Vision text, and the classes re-read on it (W46.date-traceable-vision)", "",
              f"The 27B's choose and trace-neigh prompts built from Apple Vision text ({va['answers']} replies, the "
              f"same model and settings as the corpus-text run); the rule stage reading the candidates of both texts "
              f"(union, the named text's first); and the classes re-read with a year counting as printed when it is in "
              f"the corpus text or in Vision's text of the first two pages. Vision text covers the 300 and the three "
              f"documents either side of each, so C against D (the nearest printed same-year document anywhere in the "
              f"folder) still reads the corpus text beyond them. {va['documents']} documents.", "",
              "| classes | " + " | ".join(order) + " |", "|---|" + "---:|" * len(order)]
        for k in ("corpus", "reread"):
            L.append(f"| {'corpus text (date_truth)' if k == 'corpus' else 're-read with Vision text'} | "
                     + " | ".join(str(va["classes"][k].get(c, 0)) for c in order) + " |")
        L += ["", "Moved: " + ", ".join(f"{k} {v}" for k, v in sorted(va["moved"].items(), key=lambda kv: -kv[1])) + ".", ""]
        for k, title in (("corpus", "scored on the corpus-text classes"), ("reread", "scored on the classes re-read with Vision text")):
            table(f"Vision-text arms, owner set, {title} (exact year)",
                  [(name, c[k]) for name, c in va["configs"].items()], True,
                  "" if k == "corpus" else "The same rows; only the class each document is counted under changes. "
                  "'not in text' is now the documents whose year neither text prints.")
        L += ["| arm (Vision text) | replies | GPU-seconds a reply |", "|---|---:|---:|"]
        for arm, c in va["cost"].items():
            v = c["gpu_s_per_reply"]
            L.append(f"| {arm} | {c['n']} | {v:.2f} |" if v is not None else f"| {arm} | {c['n']} | – |")
        L += ["", "| configuration | 27B calls per 1,000 | GPU-seconds per 1,000 | Mac seconds per 1,000 (2B) |",
              "|---|---:|---:|---:|"]
        for name, c in va["configs"].items():
            p = c["per_1000"]
            if p:
                n = sum(v for a, v in p["calls"].items() if a != "2b") * 1000 / max(1, c["corpus"]["n"])
                L.append(f"| {name} | {n:.0f} | {p['gpu_s']:.0f} | {p['mac_s']:.0f} |")
        L.append("")
    L += ["## Cost", "", "GPU-seconds a reply: the job's measured wall time on one L40S (16 requests at once), shared "
          "over the arms by tokens. A configuration's cost per 1,000 documents is its calls times these; the 2B "
          "chooser runs on the Mac at 1.39 s a document. No money on any arm.", "",
          "| arm | replies | GPU-seconds a reply |", "|---|---:|---:|"]
    for arm, c in out["cost"].items():
        v = c["gpu_s_per_reply"]
        L.append(f"| {arm} | {c['n']} | {v:.2f} |" if v is not None else f"| {arm} | {c['n']} | – |")
    L += ["", "| configuration | 27B calls per 1,000 | GPU-seconds per 1,000 | Mac seconds per 1,000 |", "|---|---:|---:|---:|"]
    for k, s in out["pipeline"].items():
        c = s["per_1000"]
        n = sum(v for a, v in c["calls"].items() if a != "2b") * 1000 / max(1, s["n"])
        L.append(f"| {k} | {n:.0f} | {c['gpu_s']:.0f} | {c['mac_s']:.0f} |")
    L.append("")
    open(RESULTS, "w", encoding="utf-8").write("\n".join(L))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("rules")
    e = sub.add_parser("export"); e.add_argument("--out", required=True)
    e.add_argument("--source", choices=("abbyy", "vision"), default="abbyy")
    i = sub.add_parser("import"); i.add_argument("--answers", required=True); i.add_argument("--label", default=LABEL_27B)
    i.add_argument("--summary", help="cluster_text's summary-*.json of the full run (its wall time prices the arms)")
    sub.add_parser("score")
    v = sub.add_parser("vision"); v.add_argument("--limit", type=int, default=0); v.add_argument("--after", action="store_true")
    a = ap.parse_args()
    {"rules": cmd_rules, "export": cmd_export, "import": cmd_import, "score": cmd_score, "vision": cmd_vision}[a.cmd](a)


if __name__ == "__main__":
    main()
