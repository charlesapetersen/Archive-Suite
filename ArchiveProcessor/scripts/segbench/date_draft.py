#!/usr/bin/env python3
"""W46.fix-date-truth-score: the model draft of the stratified 200, calibrated on the owner's 54 and audited.

    python3 date_draft.py render                    # first pages as JPEG into the bench cache (sips, read-only)
    run-guarded.sh --label date-draft --need-gb 8 -- <lab venv>/bin/python date_draft.py collect [--model K] [--limit N]
    python3 date_draft.py score [--model K]         # segbench-results/date-draft.md; pool/draft-truth.jsonl (private)

W46.date-draft-audit, the second reader on the rows the first did not support, every page of each:
    python3 date_draft.py audit-render              # every page of the audit rows, plus a manifest
    run-guarded.sh --label date-audit --need-gb 8 -- <lab venv>/bin/python date_draft.py audit-collect [--model K]
    python3 date_draft.py audit-score [--model K]   # segbench-results/date-draft-audit.md; pool/audit-truth.jsonl
                                                    # and the owner's check sheet pool/audit-sheet/index.html
W46.date-audit-score: once the sheet's answers are saved (pool/audit-sheet/W46-date-audit-answers.json), audit-score
also folds them in, each classed by hand in OWNER, and writes the final count of the 200.

--model is a key of MODELS (default qwen3-vl-8b-mlx4; qwen3.5-4b-mlx4 runs under --need-gb 5).

The owner's 54 answers showed that most unprinted years are on the document's own page, missed or misread by the
OCR (`date-truth-sets.md`). So the draft asks one blind question of each document's first page: is a date written,
stamped or printed on it, and what does it say. Qwen3-VL 8B, 4-bit MLX, on this Mac, temperature 0: $0, no network
once the weights are cached, and no plan route (those wait for W46.gateway-models-ok). The owner's year is never
in the prompt.

Calibration: the same question on the 54 owner cases, scored against the owner's image-extraction truth (a page
date the owner read, with its year) for recall, and against the owner's other answers for how often the draft
claims a page date the owner did not use.

Audit, on the 200: a drafted page year that equals the owner's tag is two independent sources agreeing (the
owner's tag and a blind reading of the page), recorded `own page (supported)`. A drafted year that differs, or no
date found, is recorded as such and listed for the second-reader audit (a stronger model through the gateway once
W46.gateway-models-ok is ticked, or the owner). Only the first page is read: a19's illegible date on page 2 is the
kind this misses, and the scores say so.
"""
import argparse
import collections
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse

sys.path.insert(0, os.getcwd())
import corpus_survey as CS
import date_tagging as DT

POOL = os.path.join(DT.CACHE, "pool")
CASES = os.path.join(DT.CACHE, "cases")
PAGES = os.path.join(POOL, "pages")
# key -> (Hugging Face repo, label, --need-gb). The 8B was the first choice; on this 18 GB Mac the guard kept refusing
# it (5.9-6.1 GB reclaimable, 2026-10-21), so the 4B the bench already runs (method_local.py) is the second.
MODELS = {"qwen3-vl-8b-mlx4": ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "Qwen3-VL 8B, 4-bit MLX", 8),
          "qwen3.5-4b-mlx4": ("lmstudio-community/Qwen3.5-4B-MLX-4bit", "Qwen3.5 4B, 4-bit MLX", 5)}
KEY = "qwen3-vl-8b-mlx4"
MAX_SIDE = 1100
MAX_TOKENS = 160
def draft_dir(key):
    return os.path.join(POOL, "draft", key)


RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "segbench-results", "date-draft.md")
PROMPT = ("This is the first page of a document from a historical archive. Is a date written, stamped or printed "
          "anywhere on it (a letter's date line, a postmark or received stamp, a handwritten date, a printed issue "
          "date)? Reply with JSON only: {\"date_on_page\": true or false, \"as_read\": the date exactly as it "
          "appears or null, \"year\": the four-digit year it gives or null, \"kind\": one of \"handwritten\", "
          "\"stamped\", \"printed or typed\", or null, \"where\": where on the page, e.g. \"upper right\", or "
          "null}")


def items():
    """[(id, set, first page relative to the corpus, record)] for the 54 cases and the 200, in that order."""
    out = []
    for c in json.load(open(os.path.join(CASES, "cases.json"), encoding="utf-8")):
        url = c["this"]["links"][0]
        path = urllib.parse.unquote(urllib.parse.urlparse(url).path)
        out.append((c["id"], "owner", os.path.relpath(path, CS.CORPUS), c))
    for line in open(os.path.join(POOL, "stratified.jsonl"), encoding="utf-8"):
        d = json.loads(line)
        out.append((d["id"], "pool", d["first_pages"][0], d))
    return out


def image_of(iid):
    return os.path.join(PAGES, iid + ".jpg")


def cmd_render(a):
    os.makedirs(PAGES, exist_ok=True)
    bad = 0
    for iid, _, page, _ in items():
        out = image_of(iid)
        if not os.path.exists(out):
            subprocess.run(["sips", "-s", "format", "jpeg", "-Z", str(MAX_SIDE), os.path.join(CS.CORPUS, page),
                            "--out", out], capture_output=True, check=False)
        bad += not os.path.exists(out)
    print(f"{len(items())} first pages, {bad} not rendered; {PAGES}")


def cmd_collect(a):
    import mlx.core as mx
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    os.environ.setdefault("HF_HOME", os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/mlx-hf"))
    out = draft_dir(a.model)
    os.makedirs(out, exist_ok=True)
    todo = [(i, s) for i, s, _, _ in items() if os.path.exists(image_of(i))
            and not os.path.exists(os.path.join(out, i + ".json"))][: a.limit or None]
    print(f"{a.model}: {len(todo)} pages to read", flush=True)
    if not todo:
        return
    mx.set_cache_limit(256 * 2**20)
    model, processor = load(MODELS[a.model][0])
    try:  # Qwen3.5 thinks unless told not to; Qwen3-VL's template takes no such switch
        chat = apply_chat_template(processor, model.config, PROMPT, num_images=1, enable_thinking=False)
    except TypeError:
        chat = apply_chat_template(processor, model.config, PROMPT, num_images=1)
    for k, (iid, which) in enumerate(todo, 1):
        start, text, last = time.time(), [], None
        for r in stream_generate(model, processor, chat, image=[image_of(iid)], max_tokens=MAX_TOKENS, temperature=0.0):
            text.append(r.text)
            last = r
        raw = re.sub(r"<think>.*?</think>", "", "".join(text), flags=re.S)
        rec = {"id": iid, "set": which, "raw": raw, "parsed": parse(raw), "wall_s": round(time.time() - start, 2),
               "tokens": [getattr(last, "prompt_tokens", 0), getattr(last, "generation_tokens", 0)]}
        with open(os.path.join(out, iid + ".json"), "w", encoding="utf-8") as fh:
            json.dump(rec, fh, ensure_ascii=False)
        print(f"[{k}/{len(todo)}] {iid} {rec['wall_s']}s {'ok' if rec['parsed'] else 'unparsed'}", flush=True)


def parse(raw):
    m = re.search(r"\{.*\}", raw or "", re.S)
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
    except ValueError:
        return None
    y = d.get("year")
    try:
        y = int(str(y)[:4]) if y not in (None, "", "null") else None
    except ValueError:
        y = None
    d["year"] = y if y and 1500 <= y <= 2030 else None
    d["date_on_page"] = bool(d.get("date_on_page")) and (d["year"] is not None or bool(d.get("as_read")))
    return d


def draft_of(iid, key=KEY):
    p = os.path.join(draft_dir(key), iid + ".json")
    return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else None


def year_in_reading(parsed):
    """Whether the drafted year is in the date as read, in full or as '58: on the owner's d06 the model read
    "TUESDAY, MARCH 7" and supplied 1984 on its own."""
    y, read = str(parsed["year"]), str(parsed.get("as_read") or "")
    return y in read or bool(re.search(r"(?<![0-9])'?" + y[2:] + r"(?![0-9])", read))


def verdict(parsed, year):
    """The audited draft class of one document, given the owner's year tag."""
    if parsed is None:
        return "unreadable reply"
    if not parsed["date_on_page"]:
        return "no date found"
    if parsed["year"] is None or not year_in_reading(parsed):
        return "date without a year"
    return "own page (supported)" if parsed["year"] == year else "page year differs"


def calibrate(truth, drafts):
    """Draft against the owner's 54: recall on owner page dates with a year, and claims on the rest."""
    page = [r for r in truth if r["page_date"] and r["page_date"]["year"]]
    other = [r for r in truth if not r["page_date"]]
    def got(r):
        d = drafts.get(r["id"])
        return d and d["parsed"] and d["parsed"]["date_on_page"]
    def same(r):
        d = drafts.get(r["id"])
        return got(r) and d["parsed"]["year"] == r["page_date"]["year"]
    def tag(r):
        d = drafts.get(r["id"])
        return got(r) and d["parsed"]["year"] == r["owner_year"]
    return {"page_dates": len(page), "found": sum(1 for r in page if got(r)),
            "year_right": sum(1 for r in page if same(r)),
            "other": len(other), "other_claims": sum(1 for r in other if got(r)),
            "other_claims_tag_year": sum(1 for r in other if tag(r)),
            "missing": sum(1 for r in truth if r["id"] not in drafts)}


def misses(truth, drafts):
    """'a06 1971 for 1975 (as read: ...)' for each owner page date with a year the draft got wrong."""
    out = []
    for r in truth:
        d = drafts.get(r["id"])
        if not (r["page_date"] and r["page_date"]["year"] and d and d["parsed"]):
            continue
        p = d["parsed"]
        if p["year"] != r["page_date"]["year"]:
            out.append(f"{r['id']} {p['year'] or 'no year'} for {r['page_date']['year']}"
                       + (f" (read \"{p['as_read']}\")" if p.get("as_read") else ""))
    return out


def cmd_score(a):
    truth = json.load(open(os.path.join(CASES, "truth-sets.json"), encoding="utf-8"))["records"]
    its = items()
    drafts = {i: draft_of(i, a.model) for i, _, _, _ in its}
    drafts = {k: v for k, v in drafts.items() if v}
    cal = calibrate(truth, drafts)
    pool = [rec for i, s, _, rec in its if s == "pool"]
    rows = []
    for d in pool:
        dr = drafts.get(d["id"])
        v = verdict(dr["parsed"], d["truth"]["year"]) if dr else "not drafted"
        rows.append({"id": d["id"], "class": d["class"], "owner_year": d["truth"]["year"], "du": d["truth"]["du"],
                     "verdict": v, "draft": dr["parsed"] if dr else None, "audit": v != "own page (supported)"})
    with open(os.path.join(POOL, "draft-truth.jsonl"), "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    classes = ("A", "A'", "B", "C", "D")
    verdicts = ("own page (supported)", "page year differs", "date without a year", "no date found",
                "unreadable reply", "not drafted")
    tab = collections.Counter((r["class"], r["verdict"]) for r in rows)
    walls = [d["wall_s"] for d in drafts.values()]
    L = ["# Dating: the model draft of the stratified 200, calibrated on the owner's 54 (W46.fix-date-truth-score)", "",
         f"Written by `scripts/segbench/date_draft.py score --model {a.model}`. {MODELS[a.model][1]} (this Mac, temperature 0, "
         f"first page at {MAX_SIDE} px) asked blind whether a date is on the page; the owner's year is never in the "
         f"prompt. $0, no plan route. {len(drafts)} pages read"
         + (f", median {sorted(walls)[len(walls) // 2]:.1f} s a page" if walls else "") + ".", "",
         "## Calibration on the owner's 54", "",
         f"Of the {cal['page_dates']} owner cases with a legible page date and a year, the draft found a date on "
         f"{cal['found']} and read the owner's page year on {cal['year_right']}. On the {cal['other']} cases whose "
         f"year the owner took from somewhere other than the page, the draft claimed a page date on "
         f"{cal['other_claims']}, {cal['other_claims_tag_year']} of them with the owner's year (a date the owner may "
         "have had but did not name, or a misreading). "
         + (f"{cal['missing']} owner cases not yet drafted." if cal["missing"] else ""), "",
         "Where the draft's year differs from the owner's page year: "
         + ("; ".join(misses(truth, drafts)) or "none") + ".", "",
         "## The 200, drafted and audited", "",
         "`own page (supported)`: the blind reading of the page gives the owner's year, so two independent sources "
         "agree; accepted as truth with the owner's tag. A year the model gave that is not in the date it read "
         "counts as `date without a year`. Every other row goes to the second-reader audit list "
         "(`audit: true` in the private `pool/draft-truth.jsonl`).", "",
         "| class | " + " | ".join(verdicts) + " |", "|---|" + "---|" * len(verdicts)]
    for c in classes:
        L.append(f"| {c} | " + " | ".join(str(tab[(c, v)]) for v in verdicts) + " |")
    L.append("| all | " + " | ".join(str(sum(tab[(c, v)] for c in classes)) for v in verdicts) + " |")
    sup = sum(1 for r in rows if not r["audit"])
    L += ["", f"{sup} of {len(rows)} are supported; {len(rows) - sup} await the audit. Only the first page is read, "
          "so a date on a later page (as on the owner's a19) counts as not found; the calibration's recall is the "
          "figure to read this table through.", ""]
    with open(RESULTS, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))
    print(f"calibration {cal}; supported {sup}/{len(rows)}; {RESULTS}")


# W46.date-draft-audit: a second reader for the rows the first did not support, on every page, blind.
AUDIT_PAGES = os.path.join(POOL, "audit-pages")
SHEET = os.path.join(POOL, "audit-sheet")
AUDIT_RESULTS = RESULTS[:-3] + "-audit.md"
AUDIT_PROMPT = ("This is page {k} of {n} of a document from a historical archive. Is a date written, stamped or "
                "printed anywhere on this page (a letter's date line, a postmark or received stamp, a handwritten "
                "date, a printed issue date)? Reply with JSON only: {{\"date_on_page\": true or false, \"as_read\": "
                "the date exactly as it appears or null, \"year\": the four-digit year it gives or null, \"kind\": "
                "one of \"handwritten\", \"stamped\", \"printed or typed\", or null, \"where\": where on the page, "
                "e.g. \"upper right\", or null, \"box\": [x1, y1, x2, y2] around the date in thousandths of the page "
                "width and height (0 to 1000, top left origin), or null}}")
FIRST = "qwen3.5-4b-mlx4"   # the first reader, whose rows the audit takes


def audit_rows():
    """The draft-truth rows marked for the audit, each with its stratified record."""
    st = {json.loads(l)["id"]: json.loads(l) for l in open(os.path.join(POOL, "stratified.jsonl"), encoding="utf-8")}
    rows = [json.loads(l) for l in open(os.path.join(POOL, "draft-truth.jsonl"), encoding="utf-8")]
    return [(r, st[r["id"]]) for r in rows if r["audit"]]


def all_pages(d, lab, cache):
    """Every page of a stratified document, from the same tag-rule segmentation date_pool.py drew it from."""
    if d["folder"] not in cache:
        cache[d["folder"]] = DT.folder_documents(d["folder"], lab)
    pages = cache[d["folder"]][d["position"]]["pages"]
    assert pages[:2] == d["first_pages"] and len(pages) == d["pages"], d["id"]
    return pages


def audit_image(iid, k):
    return os.path.join(AUDIT_PAGES, f"{iid}-{k:02d}.jpg")


def audit_manifest():
    return json.load(open(os.path.join(AUDIT_PAGES, "manifest.json"), encoding="utf-8"))


def cmd_audit_render(a):
    import corpus_pairs as CP
    lab = {}
    for line in open(os.path.join(CP.CACHE, "labels.jsonl"), encoding="utf-8"):
        g = json.loads(line)
        lab[(g["folder_id"], g["n"])] = g
    os.makedirs(AUDIT_PAGES, exist_ok=True)
    man, cache, bad = {}, {}, 0
    for _, d in audit_rows():
        pages = all_pages(d, lab, cache)
        man[d["id"]] = pages
        for k, page in enumerate(pages, 1):
            out = audit_image(d["id"], k)
            if not os.path.exists(out):
                subprocess.run(["sips", "-s", "format", "jpeg", "-Z", str(MAX_SIDE), os.path.join(CS.CORPUS, page),
                                "--out", out], capture_output=True, check=False)
            bad += not os.path.exists(out)
    with open(os.path.join(AUDIT_PAGES, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(man, fh, ensure_ascii=False)
    print(f"{len(man)} documents, {sum(map(len, man.values()))} pages, {bad} not rendered; {AUDIT_PAGES}")


def audit_dir(key):
    return os.path.join(POOL, "audit", key)


def audit_of(iid, k, key):
    p = os.path.join(audit_dir(key), f"{iid}-{k:02d}.json")
    return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else None


def cmd_audit_collect(a):
    import mlx.core as mx
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    os.environ.setdefault("HF_HOME", os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/mlx-hf"))
    out = audit_dir(a.model)
    os.makedirs(out, exist_ok=True)
    todo = [(i, k, len(ps)) for i, ps in audit_manifest().items() for k in range(1, len(ps) + 1)
            if os.path.exists(audit_image(i, k)) and not audit_of(i, k, a.model)][: a.limit or None]
    print(f"{a.model} audit: {len(todo)} pages to read", flush=True)
    if not todo:
        return
    mx.set_cache_limit(256 * 2**20)
    model, processor = load(MODELS[a.model][0])
    for j, (iid, k, n) in enumerate(todo, 1):
        prompt = AUDIT_PROMPT.format(k=k, n=n)
        try:
            chat = apply_chat_template(processor, model.config, prompt, num_images=1, enable_thinking=False)
        except TypeError:
            chat = apply_chat_template(processor, model.config, prompt, num_images=1)
        start, text, last = time.time(), [], None
        for r in stream_generate(model, processor, chat, image=[audit_image(iid, k)], max_tokens=MAX_TOKENS + 40,
                                 temperature=0.0):
            text.append(r.text)
            last = r
        raw = re.sub(r"<think>.*?</think>", "", "".join(text), flags=re.S)
        rec = {"id": iid, "page": k, "of": n, "raw": raw, "parsed": parse(raw), "wall_s": round(time.time() - start, 2),
               "tokens": [getattr(last, "prompt_tokens", 0), getattr(last, "generation_tokens", 0)]}
        with open(os.path.join(out, f"{iid}-{k:02d}.json"), "w", encoding="utf-8") as fh:
            json.dump(rec, fh, ensure_ascii=False)
        print(f"[{j}/{len(todo)}] {iid} p{k}/{n} {rec['wall_s']}s {'ok' if rec['parsed'] else 'unparsed'}", flush=True)


def box_of(parsed):
    """The reader's box as [x, y, w, h] fractions of the page, or None when it gave none or a malformed one."""
    b = (parsed or {}).get("box")
    try:
        x1, y1, x2, y2 = (float(v) for v in b)
    except (TypeError, ValueError):
        return None
    if not (0 <= x1 < x2 <= 1000 and 0 <= y1 < y2 <= 1000):
        return None
    return [round(x1 / 1000, 4), round(y1 / 1000, 4), round((x2 - x1) / 1000, 4), round((y2 - y1) / 1000, 4)]


def second_reading(pages, year):
    """(verdict, readings) of the second reader over every page of one document. readings: the pages where it read
    a date, as {page, as_read, year (None unless the year is in the date as read), where, box}."""
    if not pages or any(p is None for p in pages):
        return "not read", []
    if any(p["parsed"] is None for p in pages):
        return "unreadable reply", []
    readings = []
    for p in pages:
        q = p["parsed"]
        if q["date_on_page"]:
            y = q["year"] if q["year"] is not None and year_in_reading(q) else None
            readings.append({"page": p["page"], "as_read": q.get("as_read"), "year": y, "where": q.get("where"),
                             "box": box_of(q)})
    years = {r["year"] for r in readings} - {None}
    if year in years:
        return "own page (supported)", readings
    if years:
        return "page year differs", readings
    return ("date without a year" if readings else "no date found"), readings


def outcome(first, second):
    """The audit's call on one document from the first reader's verdict (first page) and the second's (all pages).
    The 4B misread digits on the owner's 54 (1971 for 1975, 1957 for 1967), so a second reader that finds the
    owner's year settles the row; a year either reader read that differs from the tag, and is not settled so,
    is a dispute for the owner; neither reader finding a year on the page leaves the tag unsupported, not
    disputed (the owner took 24 of his 54 years from elsewhere)."""
    if second in ("not read", "unreadable reply"):
        return "not audited"
    if second == "own page (supported)":
        return "supported by the second reader"
    if "page year differs" in (first, second):
        return "disputed: to the owner"
    return "no year on the page: tag unsupported"


OUTCOMES = ("supported by the second reader", "disputed: to the owner", "no year on the page: tag unsupported",
            "not audited")


# W46.date-audit-score: the owner's answers to the sheet, every note read by hand (2026-10-22). Key: document ->
# (the year picked, the note's sha1[:8] or None, class, the page's year(s), why). The pick and the hash stop the score
# when an answer changes, so a new note is read before it counts; the notes themselves stay in the private
# pool/audit-truth.jsonl. Classes: 'dated' the page's dating year; 'context' the same, read with knowledge the page
# alone does not give; 'inferred' a dating year the owner infers from the page's text; 'mention' a year the page
# mentions that does not date it; 'bound' only an earliest year; 'illegible' the date is there, its year is one of
# the candidates. A 1900 tag is judged like any other, from its answer (W46.date-audit-owner-ok).
ANSWERS = os.path.join(SHEET, "W46-date-audit-answers.json")
OWNER = {
    "b7679fc9c60ef2f9": (None, "9359a1d5", "mention", [1985], "the 1985 is mentioned in the text, not a date"),
    "0f250089c527a25b": ("1981", "e57a5aa2", "dated", [1981], "handwritten in the left margin; both readers missed it"),
    "e52be3d43346f3a6": ("no date on these pages", "48577ba7", "mention", [1933, 1924],
                         "the years read are mentioned in passing, not a date for these pages"),
    "15c3057d93639e52": (None, "72511192", "dated", [1927], "no pick; the note reads 5.11/27 as November 1927"),
    "904df6db7437826e": ("1969", "dc43fe66", "dated", [1969], "the date as read, September 3, 1969"),
    "84c3c2cd8bc297fa": ("1981", "541701db", "dated", [1981], "the date as read, June 29, 1981"),
    "a699e0eeb964511b": ("1984", "01087d98", "mention", [1984], "picked 1984 but the note says it is mentioned, not a date"),
    "705a5d475e7d4b2d": ("1960", "729c448e", "bound", [1960],
                         "a review of a book published in 1960: the review is 1960 or later; the note overrides the pick"),
    "8b8336ab42e50a24": ("1985", "d5fe0072", "mention", [1985], "picked 1985, noted as a mention, not a dating year"),
    "65622dd6c8a653c5": ("1958", "cd3bd3da", "inferred", [1958],
                         "a 1957-58 annual report, usually published in 1958"),
    "cd01d8390ef89fa7": ("1948", "a6a6bf00", "dated", [1948], "March 4, 1948; both readers read 1968"),
    "4a8775c6635a29b0": ("no year legible", "ac5f9bec", "illegible", [1919, 1929], "obscured: 1919 or 1929"),
    "60df3c077d20a2d4": ("1916", "efd30267", "dated", [1916], "the date as read, October 6, 1916"),
    "745940a3485ac18a": ("1973", "2e1d235b", "dated", [1973], "January 31, 1973; both readers read 1978"),
    "88962ea9b8eabd83": ("1970", "d5fe0072", "mention", [1970], "picked 1970, noted as a mention, not a dating year"),
    "b5a8fc0a15e7e60f": ("1961", "d5fe0072", "mention", [1961], "picked 1961, noted as a mention, not a dating year"),
    "18589d1c06105ec7": (None, "3da1fe98", "mention", [1982], "no pick; 1982-3 is a mention, not a dating year"),
    "63d998727a5ff0ff": ("1979", "85cde903", "context", [1979],
                         "2-3-79; it looks like 19, and only context makes it 79"),
    "85c74ee4bbd28c1b": ("1983", "c6a3b7d2", "dated", [1983], "a copyright line, which the owner counts as a dating year"),
    "172f76141bf8de82": ("1981", "9ab5ea85", "dated", [1981], "the date as read, February 17, 1981"),
    "2a1a3caec99509a6": (None, "d5d524b0", "dated", [1998],
                         "no pick; the 1997 read is a mention, the dating year is at the bottom, January 1998"),
    "ab20e83f94bff0dd": ("1978", "9f29c60c", "dated", [1978], "the date as read, August 1978"),
    "486fe66f6af2dcbc": ("1982", "93d937cb", "dated", [1982], "the date as read, 01/05/82"),
    "725b969266e6f40d": ("1983", "d5fe0072", "mention", [1983], "picked 1983, noted as a mention, not a dating year"),
    "8232d2197e2a0654": (None, "11c7541a", "mention", [1956], "no pick; the owner reads 1956 (the readers 1957), a mention"),
    "e4be28828f7fd155": ("1976", "96fa5a85", "dated", [1976],
                         "the boxed date is the manuscript's receipt; the dating year is the citation at the top, June 1976"),
    "ce070071532a5616": ("1969", "eb3fe3e9", "dated", [1969], "August 26, 1969; the readers read 1953 or no year"),
    "aeead1cf06ba4269": ("no year legible", "30fb47bf", "illegible", list(range(1970, 1980)),
                         "September 197x, the last digit not legible"),
    "692927d512142b83": ("1981", None, "dated", [1981], "picked 1981, no note (the second reader's copyright line)"),
}
TAG_VERDICTS = ("supported by the page", "the page's date differs from the tag", "no dating year on the page")


def owner_verdict(cls, years, tag):
    """The tag against the owner's answer. An illegible date whose candidates all differ from the tag still shows
    the tag is not the page's year; a bound or a mention says nothing against it."""
    if cls in ("dated", "context", "inferred"):
        return TAG_VERDICTS[0] if years == [tag] else TAG_VERDICTS[1]
    if cls == "illegible":
        return TAG_VERDICTS[2] if tag in years else TAG_VERDICTS[1]
    return TAG_VERDICTS[2]


def fold_answers(rows):
    """Write the owner's answer, its class and the page's year beside the tag of every disputed row; stop on an
    answer not read by hand. Rows outside the sheet get the page year the audit gave them."""
    import hashlib
    ans = json.load(open(ANSWERS, encoding="utf-8")) if os.path.exists(ANSWERS) else None
    for r in rows:
        if r["outcome"] == "supported by the second reader":
            r.update(page_year=r["owner_year"], tag_verdict=TAG_VERDICTS[0])
        elif r["outcome"] == "no year on the page: tag unsupported":
            r.update(page_year=None, tag_verdict=TAG_VERDICTS[2])
        elif ans is not None and r["outcome"] == "disputed: to the owner":
            a = ans.get(r["id"])
            if a is None or r["id"] not in OWNER:
                raise SystemExit(f"{r['id']}: no answer, or an answer not classed by hand in OWNER: {a!r}")
            pick, h, cls, years, why = OWNER[r["id"]]
            got = hashlib.sha1(a["note"].encode()).hexdigest()[:8] if a.get("note") else None
            if a.get("year") != pick or got != h:
                raise SystemExit(f"{r['id']}: the answer changed since it was read by hand; read it again: {a!r}")
            r.update(owner_answer=a, answer_class=cls, answer_years=years, reason=why,
                     page_year=years[0] if cls in ("dated", "context", "inferred") else None,
                     tag_verdict=owner_verdict(cls, years, r["owner_year"]))
    if ans is not None and set(ans) - {r["id"] for r in rows}:
        raise SystemExit(f"answers for documents not on the sheet: {sorted(set(ans) - {r['id'] for r in rows})}")
    return ans is not None


def cmd_audit_score(a):
    man = audit_manifest()
    rows, sheet = [], []
    walls = []
    for r, d in audit_rows():
        pages = [audit_of(r["id"], k, a.model) for k in range(1, len(man.get(r["id"], [])) + 1)]
        walls += [p["wall_s"] for p in pages if p]
        sv, readings = second_reading(pages, r["owner_year"])
        oc = outcome(r["verdict"], sv)
        rows.append({"id": r["id"], "class": r["class"], "owner_year": r["owner_year"], "du": r["du"],
                     "first": r["verdict"], "first_draft": r["draft"], "second": sv, "second_readings": readings,
                     "outcome": oc, "pages": len(pages)})
        if oc == "disputed: to the owner":
            sheet.append(rows[-1])
    answered = fold_answers(rows)
    with open(os.path.join(POOL, "audit-truth.jsonl"), "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    write_sheet(sheet)
    tab = collections.Counter((r["first"], r["outcome"]) for r in rows)
    firsts = ("page year differs", "date without a year", "no date found")
    agree = collections.Counter()
    for r in rows:
        if r["first"] == "page year differs" and r["second"] == "page year differs":
            fy = r["first_draft"]["year"]
            agree["same" if fy in {x["year"] for x in r["second_readings"]} else "other"] += 1
    found_later = sum(1 for r in rows if r["outcome"] == "supported by the second reader"
                      and min(x["page"] for x in r["second_readings"] if x["year"] == r["owner_year"]) > 1)
    boxed = sum(1 for r in sheet for x in r["second_readings"] if x["box"])
    # a disputed year one off the tag reads as the tag's year coming from a neighbouring date (publication, filing),
    # not a misreading; a tag of 1900 is sometimes a placeholder and sometimes a real year (5 of the 200 carry it)
    near = sum(1 for r in sheet if r["owner_year"] != 1900 and any(
        x["year"] and abs(x["year"] - r["owner_year"]) == 1 for x in r["second_readings"]))
    placeholder = sum(1 for r in sheet if r["owner_year"] == 1900)
    L = ["# Dating: the second reader on the 95 the first did not support (W46.date-draft-audit)", "",
         f"Written by `scripts/segbench/date_draft.py audit-score --model {a.model}`. {MODELS[a.model][1]} (this Mac, "
         f"temperature 0, every page at {MAX_SIDE} px, not only the first) asked the same blind question page by page, "
         f"with a box around any date it reads; the owner's year is never in the prompt. $0, no plan route. "
         f"{len(walls)} pages read" + (f", median {sorted(walls)[len(walls) // 2]:.1f} s a page" if walls else "")
         + f". The first reader was {MODELS[FIRST][1]} on the first page only (`date-draft.md`).", "",
         "A year counts only when it is in the date as read. The second reader settles a row when it reads the "
         "owner's year on any page. A year either reader read that differs from the tag, not so settled, is a "
         "dispute and goes to the owner's check sheet. Neither reader finding a year on any page leaves the owner's "
         "tag standing but unsupported by the page: the year came from somewhere else, as 24 of the owner's 54 did.",
         "", "| first reader (page 1) | " + " | ".join(OUTCOMES) + " |", "|---|" + "---|" * len(OUTCOMES)]
    for f in firsts:
        L.append(f"| {f} | " + " | ".join(str(tab[(f, o)]) for o in OUTCOMES) + " |")
    L.append("| all | " + " | ".join(str(sum(tab[(f, o)] for f in firsts)) for o in OUTCOMES) + " |")
    n = collections.Counter(r["outcome"] for r in rows)
    L += ["", f"{n[OUTCOMES[0]]} of {len(rows)} are now supported ({found_later} of them on a later page than the "
          f"first), bringing the stratified 200 to {105 + n[OUTCOMES[0]]} supported. {n[OUTCOMES[1]]} are disputed "
          f"and on the owner's sheet; {n[OUTCOMES[2]]} have no year on the page.",
          "", f"Where both readers read a year that differs from the tag, they read the same year on "
          f"{agree['same']} and different years on {agree['other']}. {boxed} of the disputed readings carry the "
          "second reader's box on the sheet; the rest are placed by the reader's own words for where the date is.", "",
          f"Of the {len(sheet)} disputes, {near} have the second reader one year from the tag (the page's date is "
          f"probably right and the tag took a neighbouring year), and {placeholder} carry the tag 1900, sometimes a "
          "placeholder and sometimes a real year (owner, 2026-10-22); both kinds are on the sheet, since only the owner "
          "can say what the tag should hold.", "",
          "The sheet (private, in the bench cache's `date-tagging/pool/audit-sheet/index.html`) shows each disputed "
          "page with the boxes and asks what year the date says, offering every year read and the owner's tag in "
          "numeric order, unlabelled, so it does not say which is the current truth.", ""]
    if answered:
        L += owner_section(rows, sheet)
    with open(AUDIT_RESULTS, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))
    print(f"{dict(n)}; sheet {len(sheet)}; {AUDIT_RESULTS}")


def years_text(ys):
    """An answer's year(s): one year, a decade (197x), or the candidates."""
    if len(ys) == 1:
        return str(ys[0])
    if ys[0] % 10 == 0 and ys == list(range(ys[0], ys[0] + 10)):
        return f"{ys[0] // 10}x"
    return " or ".join(map(str, ys))


def owner_section(rows, sheet):
    """The owner's answers folded in: what each says, the tags it shows wrong, and the final count of the 200."""
    classes = ("dated", "context", "inferred", "illegible", "bound", "mention")
    tab = collections.Counter((r["answer_class"], r["tag_verdict"]) for r in sheet)
    overridden = sum(1 for r in sheet if r["owner_answer"].get("year", "").isdigit()
                     and r["answer_class"] in ("mention", "bound"))
    L = ["## The owner's answers (W46.date-audit-score)", "",
         f"The owner answered all {len(sheet)} on 2026-10-22. "
         f"{sum(1 for r in sheet if r['owner_answer'].get('note'))} answers carry a note and "
         f"{sum(1 for r in sheet if not r['owner_answer'].get('year'))} are a note with no year picked, so each was "
         "read by hand and classed with its reason in `OWNER` (`date_draft.py`); the score stops on an answer that "
         f"changes. A note overrides the pick: {overridden} picks of a year carry a note that the year is only "
         "mentioned, or only an earliest year. "
         "The notes are kept verbatim only in the private `pool/audit-truth.jsonl`, beside the tag and the page's year.",
         "", "| the answer | " + " | ".join(TAG_VERDICTS) + " |", "|---|" + "---|" * len(TAG_VERDICTS)]
    for c in classes:
        L.append(f"| {c} | " + " | ".join(str(tab[(c, v)]) for v in TAG_VERDICTS) + " |")
    L.append("| all | " + " | ".join(str(sum(tab[(c, v)] for c in classes)) for v in TAG_VERDICTS) + " |")
    L += ["", "`dated`: the page's dating year; `context`: the same, though the page alone reads otherwise (2-3-79 "
          "looks like 19); `inferred`: a year the owner infers from the text (a 1957-58 annual report, published "
          "1958); `illegible`: a date whose year is one of a few (1919 or 1929; 197x); `bound`: only an earliest year "
          "(a review of a 1960 book); `mention`: a year the page mentions that does not date it.", ""]
    wrong = [r for r in sheet if r["tag_verdict"] == TAG_VERDICTS[1]]
    L += [f"### The {len(wrong)} tags the answers show wrong", "",
          "The page's own date gives another year. The tag may still have come from somewhere else, but it is not "
          "the page's year; which the tag should hold is the owner's call, and nothing here changes a tag.", "",
          "| document | tag | the page's year | the answer |", "|---|---|---|---|"]
    for r in sorted(wrong, key=lambda r: r["id"]):
        L.append(f"| {r['id']} | {r['owner_year']} | {years_text(r['answer_years'])} | {r['reason']} |")
    off1 = sum(1 for r in wrong if r["page_year"] and abs(r["page_year"] - r["owner_year"]) == 1)
    t1900 = [r for r in sheet if r["owner_year"] == 1900]
    L += ["", f"{off1} of them are one year from the tag. Of the {len(t1900)} tagged 1900, each settled from its "
          f"answer: " + "; ".join(f"{r['id'][:8]} {r['tag_verdict']} ({years_text(r['answer_years'])})"
                                    for r in t1900) + ".", ""]
    # how the readers fared on the rows the owner settled with a dating year
    dated = [r for r in sheet if r["page_year"]]
    read = lambda r: {x["year"] for x in r["second_readings"]} | (
        {r["first_draft"]["year"]} if (r["first_draft"] or {}).get("year") else set())
    hit = sum(1 for r in dated if r["page_year"] in read(r))
    sup = [r for r in sheet if r["tag_verdict"] == TAG_VERDICTS[0]]
    mentions = sum(1 for r in sheet if r["answer_class"] in ("mention", "bound"))
    L += [f"On the {len(dated)} the owner dated, a reader had read the page's year on {hit}. The {len(sup)} the owner "
          f"found supported are tags the readers disputed by misreading or missing the date (1948 read as 1968, "
          f"1973 as 1978, a margin date not seen). {mentions} of the {len(sheet)} disputes were a year the page "
          "mentions rather than a date of it, or only bounds: the blind question does not tell the two apart, which is the readers' "
          "main fault here.", ""]
    n = collections.Counter(r["tag_verdict"] for r in rows)
    first = sum(1 for l in open(os.path.join(POOL, "draft-truth.jsonl"), encoding="utf-8")
                if not json.loads(l)["audit"])
    L += ["### The stratified 200, final", "",
          "| | documents |", "|---|---|",
          f"| supported by the page: the first reader | {first} |",
          f"| supported by the page: the second reader | {sum(1 for r in rows if r['outcome'] == OUTCOMES[0])} |",
          f"| supported by the page: the owner's answer | {len(sup)} |",
          f"| the page's date differs from the tag | {n[TAG_VERDICTS[1]]} |",
          f"| no dating year on the page (the tag stands, unsupported) | {n[TAG_VERDICTS[2]]} |",
          f"| all | {first + len(rows)} |", "",
          f"{first + n[TAG_VERDICTS[0]]} of the 200 tags are supported by a date on the document's own pages, "
          f"{n[TAG_VERDICTS[1]]} are contradicted by it, and {n[TAG_VERDICTS[2]]} have no dating year on the page "
          f"({sum(1 for r in rows if r['outcome'] == OUTCOMES[2])} where neither reader found a year, "
          f"{mentions} where the year found was only a mention or a bound).", ""]
    return L


def sheet_items(rows):
    """The check sheet's data: per disputed document, the pages with a reading, the boxes, and the choices."""
    out = []
    for r in rows:
        f = r["first_draft"] or {}
        fy = f.get("year") if f.get("date_on_page") and f.get("year") and year_in_reading(f) else None
        years = sorted({r["owner_year"], fy, *(x["year"] for x in r["second_readings"])} - {None})
        pages = collections.defaultdict(list)
        for x in r["second_readings"]:
            pages[x["page"]].append({"box": x["box"], "where": x["where"], "as_read": x["as_read"]})
        if fy:  # the first reader read page 1 only, and gave no box
            pages[1].append({"box": None, "where": f.get("where"), "as_read": f.get("as_read")})
        out.append({"id": r["id"], "of": r["pages"], "choices": years,
                    "pages": [{"img": os.path.relpath(audit_image(r["id"], k), SHEET), "page": k, "marks": m}
                              for k, m in sorted(pages.items())]})
    return out


def write_sheet(rows):
    os.makedirs(SHEET, exist_ok=True)
    data = sheet_items(rows)
    with open(os.path.join(SHEET, "index.html"), "w", encoding="utf-8") as fh:
        fh.write(SHEET_HTML.replace("__DATA__", json.dumps(data, ensure_ascii=False)))


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>W46 date audit check</title>
<style>body{font:15px -apple-system,sans-serif;margin:0}header{position:sticky;top:0;background:#fff;padding:8px 16px;
border-bottom:1px solid #ccc;z-index:9}.doc{border-bottom:2px solid #888;padding:12px 16px}.pg{display:inline-block;
vertical-align:top;margin:6px}.frame{position:relative;display:inline-block}.frame img{max-height:80vh;max-width:46vw}
.box{position:absolute;border:3px solid #f0a;border-radius:4px;pointer-events:none}.where{color:#a05;font-size:13px}
.q label{margin-right:14px}</style>
<header><b>Date audit.</b> Two readers disagree about the year written on these documents. For each, look at the
marked place (pink box: where a reader saw a date; it can be off) and pick the year the date on the page gives.
Answers save in this browser; <button id="dl">download answers</button> <span id="prog"></span></header>
<div id="root"></div>
<script>
const DATA=__DATA__;const KEY='w46-date-audit';const ans=JSON.parse(localStorage.getItem(KEY)||'{}');
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function prog(){document.getElementById('prog').textContent=Object.keys(ans).length+' of '+DATA.length+' answered'}
let h='';DATA.forEach((d,i)=>{h+=`<div class="doc"><b>${i+1}. Document ${d.id}</b> (${d.of} page${d.of>1?'s':''})<br>`;
 for(const p of d.pages){h+=`<div class="pg">Page ${p.page}<br><div class="frame"><img src="${esc(p.img)}">`;
  for(const m of p.marks)if(m.box)h+=`<div class="box" style="left:${100*m.box[0]}%;top:${100*m.box[1]}%;width:${100*m.box[2]}%;height:${100*m.box[3]}%"></div>`;
  h+='</div>';for(const m of p.marks)if(!m.box)h+=`<div class="where">No box for one reading: the reader placed it "${esc(m.where||'somewhere on the page')}".</div>`;h+='</div>'}
 h+=`<div class="q">The date on the page gives the year: `;for(const y of [...d.choices,'another year','no year legible','no date on these pages'])
  h+=`<label><input type="radio" name="${d.id}" value="${esc(y)}" ${ans[d.id]&&ans[d.id].year==y?'checked':''}> ${esc(y)}</label>`;
 h+=` <input placeholder="note (e.g. the year you read)" data-note="${d.id}" value="${esc(ans[d.id]?.note)}" size="40"></div></div>`});
document.getElementById('root').innerHTML=h;
document.querySelectorAll('input[type=radio]').forEach(e=>e.onchange=()=>{ans[e.name]={...(ans[e.name]||{}),year:e.value};save()});
document.querySelectorAll('[data-note]').forEach(e=>e.oninput=()=>{const k=e.dataset.note;ans[k]={...(ans[k]||{}),note:e.value};save()});
function save(){localStorage.setItem(KEY,JSON.stringify(ans));prog()}prog();
document.getElementById('dl').onclick=()=>{const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify(ans,null,1)],{type:'application/json'}));a.download='W46-date-audit-answers.json';a.click()};
</script>"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("render").set_defaults(fn=cmd_render)
    sub.add_parser("audit-render").set_defaults(fn=cmd_audit_render)
    for name, fn in (("audit-collect", cmd_audit_collect), ("audit-score", cmd_audit_score)):
        s = sub.add_parser(name)
        s.add_argument("--model", choices=sorted(MODELS), default=KEY)
        if name == "audit-collect":
            s.add_argument("--limit", type=int)
        s.set_defaults(fn=fn)
    c = sub.add_parser("collect")
    c.add_argument("--limit", type=int)
    c.add_argument("--model", choices=sorted(MODELS), default=KEY)
    c.set_defaults(fn=cmd_collect)
    sc = sub.add_parser("score")
    sc.add_argument("--model", choices=sorted(MODELS), default=KEY)
    sc.set_defaults(fn=cmd_score)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
