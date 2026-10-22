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
          "The sheet (private, in the bench cache's `date-tagging/pool/audit-sheet/index.html`) shows each disputed "
          "page with the boxes and asks what year the date says, offering every year read and the owner's tag in "
          "numeric order, unlabelled, so it does not say which is the current truth.", ""]
    with open(AUDIT_RESULTS, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))
    print(f"{dict(n)}; sheet {len(sheet)}; {AUDIT_RESULTS}")


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
