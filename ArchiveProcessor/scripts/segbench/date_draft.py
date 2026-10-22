#!/usr/bin/env python3
"""W46.fix-date-truth-score: the model draft of the stratified 200, calibrated on the owner's 54 and audited.

    python3 date_draft.py render                    # first pages as JPEG into the bench cache (sips, read-only)
    run-guarded.sh --label date-draft --need-gb 8 -- <lab venv>/bin/python date_draft.py collect [--model K] [--limit N]
    python3 date_draft.py score [--model K]         # segbench-results/date-draft.md; pool/draft-truth.jsonl (private)

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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("render").set_defaults(fn=cmd_render)
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
