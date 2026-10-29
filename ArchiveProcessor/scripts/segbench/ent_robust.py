#!/usr/bin/env python3
"""W46.ent-robust: at what OCR error level entity extraction stops paying (gap audit section 5 item 32, G tests 2, 6, 7, 9).

    python3 ent_robust.py texts                    # the page texts: truth, each route, the post-corrected readings
    python3 ent_robust.py nltag                    # Apple NLTagger name spans on every text
    GLINER_PY ent_robust.py gliner --size base     # GLiNER2.5 person / organisation / location spans
    python3 ent_robust.py pack                     # the Sherlock pack: the 27B's entity prompt on every text
    python3 ent_g17.py pack --root PACK/g17 ...    # its G17 Business Letters arm (ent_g17.py)
    python3 ent_robust.py freeze                   # support files in, every file hashed (freeze.json)
    python3 ent_robust.py report                   # segbench-results/ent-robust.md and .json

The question is not whether an extractor is right (W46.ent-score answers that on its 138 letters) but how much the
OCR route changes what it extracts. Each extractor runs on the adjudicated truth text of a page and on each route's
reading of the same page; the names it finds in the truth text are the reference, and a route's names are scored
against them, so a perfect reading scores 1.0 whatever the extractor's own accuracy. Read beside the page's
character error rate, that gives the error level at which a route's entities stop matching what the page says.

Pages. The owner's 96 truth pages (ocr_rescore's scored set: the 99 done pages less p086, p094, p096), with their
kind from ocr-truth/pages.tsv (typewritten, printed, handwritten, mixed); and the public set's Latin-script pages of
the 440-page reference manifest (strata L5 to L8, 320 pages: medieval and early-modern Latin and vernacular hands,
L6 nineteenth-century hands, L8 early print), by stratum.

Routes. Owner 96: Apple Vision, Qwen3-VL 8B MLX 4-bit, Qwen3.6 27B, Gemini 3.8 Flash, Claude Sonnet 5.5 (the
panel's cached readings, page scale "original"). Public Latin: Apple Vision, Gemini 3.8 Flash, Qwen3.6 27B and
Qwen3-VL 8B (FarmShare panel records). The character error rate of each reading is 1 - nb_overall from
ocr-scorers-pages.csv (NewsBench: lower-case a-z and 0-9 only, [illegible] dropped), so it is the scorer's figure,
not recomputed here. Post-correction: the 27B's corrected readings from W46.ocr-postcorrect (Sherlock pack
postcorrect-20261022, text-only and image-grounded arms) for the pages it covered, scored as routes
"<route>+pc-text" and "<route>+pc-image" beside the same pages' raw reading.

Extractors. Apple NLTagger nameType (person, place, organisation; joined names; language fixed to English, as in
ent_score, which on the Latin pages means the tagger reads them as English: a robustness reference, not a fair
tagger), GLiNER2.5 base on the owner pages and multi on the public pages (person, organization, location labels,
the package's default threshold), and Qwen3.6 27B no-think through a page entity prompt (ENTITY_PROMPT; Sherlock,
temperature 0) whose replies the report reads once the pack is collected. Every text has its whitespace flattened
to single spaces (the owner's truth is one line a page and the readings are not, so layout would otherwise count as
an OCR error) and is cut at TEXT_CAP characters.

Scoring. Names are compared with ent_truth.match at ed2 (tokens folded, titles dropped, edit distance 2 per token)
and within one type; each truth-text name is matched to at most one route name, greedily in text order. Per page
the reference is the extractor's names on the truth text; precision, recall and F1 are micro-averaged over names.
A page whose truth text yields no names for that extractor is left out for it. CER bins: 0-2, 2-5, 5-10, 10-20,
20-40, over 40 percent. The switch-off level is the lowest CER bin whose F1 falls below SWITCH_F1.
Texts, spans and replies stay in the bench cache; the committed report carries aggregates only.
"""
from __future__ import annotations

import argparse
import collections
import csv
import hashlib
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ent_truth as ET  # noqa: E402  (stdlib-only at import, so the GLiNER venv can load it)

RC = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal")
CACHE = os.path.join(RC, "ent-robust")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results")
PAGES_CSV = os.path.join(RESULTS, "ocr-scorers-pages.csv")
REF440 = os.path.join(RESULTS, "bench-corpus", "manifest-reference-440.jsonl")
OCR_TRUTH = os.path.join(RC, "ocr-truth")
FROZEN = os.path.expanduser("~/Library/Application Support/ArchiveSuiteRehearsal/bench-corpus-frozen")
FARMSHARE = os.path.expanduser("~/Claude/Long term storage")
POSTCORRECT = os.path.join(RC, "sherlock-results", "postcorrect-20261022")
NLTAG_SRC = os.path.join(HERE, "nltag_names.swift")
NLTAG_BIN = os.path.join(CACHE, "nltag_names")
GLINER = {"base": "fastino/gliner2.5-base-v1", "multi": "fastino/gliner2.5-multi-v1"}
GLINER_SET = {"owner96": "base", "public-latin": "multi"}
AGREEMENT = {"p086", "p094", "p096"}          # ocr_rescore's agreement pages, not scored
LATIN = ("L5", "L6", "L7", "L8")
TEXT_CAP = 8000
SWITCH_F1 = 0.8
BINS = [(0, .02), (.02, .05), (.05, .10), (.10, .20), (.20, .40), (.40, 9)]
TEXTS = os.path.join(CACHE, "texts.jsonl")

OWNER_ROUTES = {   # route -> (csv route name, reader of the page's text)
    "apple-vision": ("apple-vision", lambda p: _txt(os.path.join(RC, "ocr-panel-local", "vision", f"{p}-original.txt"))),
    "qwen3-vl-8b-mlx4": ("qwen3-vl-8b-mlx4", lambda p: _parsed(os.path.join(RC, "ocr-panel-local", "local",
                                                                            "qwen3-vl-8b-mlx4", f"{p}-original.json"))),
    "qwen3.6-27b": ("qwen3.6-27b", lambda p: _parsed(os.path.join(RC, "ocr-panel-local", "responses", "qwen3.6-27b",
                                                                  f"{p}-original.json"))),
    "gemini3.8-flash": ("gemini3.8-flash", lambda p: _parsed(os.path.join(RC, "ocr-panel-cloud", "responses",
                                                                          "gemini3.8-flash", f"{p}-original.json"))),
    "claude-sonnet5.5": ("claude-sonnet5.5", lambda p: _parsed(os.path.join(RC, "ocr-panel-cloud", "sub",
                                                                            "claude-sonnet5.5", f"{p}-original.json"))),
}
FS19 = os.path.join(FARMSHARE, "FarmShare-20261019", "results", "ocr")
FS_OPEN = os.path.join(FARMSHARE, "FarmShare-open-sweep-20261019", "outputs", "qwen3-vl-8b", "results", "ocr", "qwen3-vl-8b")
PUBLIC_ROUTES = {
    "apple-vision": ("apple-vision", lambda j: _txt(os.path.join(RC, "bench-corpus", "routes", "vision", f"{j}.txt"))),
    "gemini3.8-flash": ("gemini3.8-flash", lambda j: _parsed(os.path.join(RC, "bench-corpus", "routes", "responses",
                                                                          "gemini3.8-flash", f"{j}.json"))),
    "qwen3.6-27b": ("qwen3.6-27b", lambda j: _farmshare(os.path.join(FS19, "qwen3.6-27b", f"{j}.json"))),
    "qwen3-vl-8b": ("qwen3-vl-8b", lambda j: _farmshare(os.path.join(FS_OPEN, f"{j}.json"))),
}

ENTITY_PROMPT = """Below is the text of one page from a historical archive, as an OCR program read it; it may hold \
reading errors. List the names of people, places and organisations written on the page, each once, spelled as the \
page spells them (correct an obvious misreading only when you are sure of the name). If the page is a letter, memo or \
telegram, also give its sender, its recipient and the place it was sent from, or null for any the page does not \
show. Do not add names that are not on the page.

Reply with JSON only:
{{"persons": ["..."], "places": ["..."], "organizations": ["..."], "sender": null, "recipient": null, \
"sending_place": null}}

Page text:
<<<
{text}
>>>"""


def _txt(path):
    try:
        return open(path, encoding="utf-8").read()
    except FileNotFoundError:
        return None


def _parsed(path):
    try:
        d = json.load(open(path, encoding="utf-8"))
    except FileNotFoundError:
        return None
    t = (d.get("parsed") or {}).get("text")
    return t if isinstance(t, str) else None


def _farmshare(path):
    try:
        rec = json.load(open(path, encoding="utf-8"))
    except FileNotFoundError:
        return None
    if not rec or rec.get("status") != "ok" or rec.get("finish") != "stop":
        return None
    # farmshare_results.reading's panel branch (ocr_truth.parse_draft), inlined: that module needs `regex`
    m = re.search(r"KIND:\s*(\w+)\s*\n\s*TABLE:\s*(\w+)\s*\n\s*TEXT:[ \t]*\n?(.*)\Z", rec.get("raw", "").strip(),
                  re.S | re.I)
    if not m or m.group(1).lower() not in ("printed", "typewritten", "handwritten", "mixed"):
        return None
    return re.sub(r"^```\w*\n|\n```$", "", m.group(3).strip()).strip() or None


def clean(t):
    """[illegible] dropped, as the scorer drops it; whitespace flattened, because the owner's truth is one line a
    page and the readings keep their line breaks, which the taggers would otherwise read as name boundaries."""
    t = re.sub(r"\[illegible\]", " ", t or "", flags=re.I)
    return re.sub(r"\s+", " ", t).strip()[:TEXT_CAP]


def cer_table():
    out = {}
    for r in csv.DictReader(open(PAGES_CSV, encoding="utf-8")):
        if r["set"] in ("owner96", "public895") and r["nb_overall"] not in ("", None):
            out[(r["set"], r["route"], r["page"])] = round(1 - float(r["nb_overall"]), 6)
    return out


def owner_pages():
    kinds = {}
    for r in csv.DictReader(open(os.path.join(OCR_TRUTH, "pages.tsv"), encoding="utf-8"), delimiter="\t"):
        if r["status"] == "done" and r["page"] not in AGREEMENT:
            kinds[r["page"]] = r["kind"]
    return kinds


def public_pages():
    out = {}
    for line in open(REF440, encoding="utf-8"):
        d = json.loads(line)
        if d["stratum"] in LATIN:
            out[f"{d['source']}__{d['page_id']}".replace("/", "_")] = d["stratum"]
    return out


def postcorrected():
    """(set, route, page) -> {"pc-text": text, "pc-image": text} from the W46.ocr-postcorrect pack."""
    out = collections.defaultdict(dict)
    reqs = {}
    for line in open(os.path.join(POSTCORRECT, "requests.jsonl"), encoding="utf-8"):
        r = json.loads(line)
        reqs[r["id"]] = r
    for rid, r in reqs.items():
        p = os.path.join(POSTCORRECT, "out", rid + ".json")
        if not os.path.exists(p):
            continue
        rec = json.load(open(p, encoding="utf-8"))
        if rec.get("finish") != "stop" or not rec.get("text"):
            continue
        out[(r["set"], r["route"], r["page"])]["pc-" + r["arm"]] = rec["text"]
    return out


def cmd_texts(a):
    cer = cer_table()
    pc = postcorrected()
    recs, missing = [], collections.Counter()
    for page, kind in sorted(owner_pages().items()):
        truth = _txt(os.path.join(OCR_TRUTH, "truth", f"{page}.txt"))
        if truth is None:
            raise SystemExit(f"no truth text for {page}")
        recs.append({"set": "owner96", "page": page, "group": kind, "source": "truth", "cer": 0.0, "text": clean(truth)})
        for route, (cr, read) in OWNER_ROUTES.items():
            t = read(page)
            if t is None or (("owner96", cr, page) not in cer):
                missing[("owner96", route)] += 1
                continue
            recs.append({"set": "owner96", "page": page, "group": kind, "source": route,
                         "cer": cer[("owner96", cr, page)], "text": clean(t)})
            for arm, ct in pc.get(("owner96", route, page), {}).items():
                recs.append({"set": "owner96", "page": page, "group": kind, "source": f"{route}+{arm}",
                             "cer": cer[("owner96", cr, page)], "text": clean(ct)})
    for job, stratum in sorted(public_pages().items()):
        truth = _txt(os.path.join(FROZEN, stratum, f"{job}.txt"))
        if truth is None:
            missing[("public-latin", "truth")] += 1
            continue
        recs.append({"set": "public-latin", "page": job, "group": stratum, "source": "truth", "cer": 0.0,
                     "text": clean(truth)})
        for route, (cr, read) in PUBLIC_ROUTES.items():
            t = read(job)
            if t is None or (("public895", cr, job) not in cer):
                missing[("public-latin", route)] += 1
                continue
            recs.append({"set": "public-latin", "page": job, "group": stratum, "source": route,
                         "cer": cer[("public895", cr, job)], "text": clean(t)})
            for arm, ct in pc.get(("public895", route, job), {}).items():
                recs.append({"set": "public-latin", "page": job, "group": stratum, "source": f"{route}+{arm}",
                             "cer": cer[("public895", cr, job)], "text": clean(ct)})
    for r in recs:
        r["id"] = f"{r['set']}|{r['page']}|{r['source']}"
    os.makedirs(CACHE, exist_ok=True)
    with open(TEXTS + ".tmp", "w", encoding="utf-8") as fh:
        for r in recs:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(TEXTS + ".tmp", TEXTS)
    c = collections.Counter((r["set"], r["source"]) for r in recs)
    print(json.dumps({"texts": len(recs), "by_source": {f"{k[0]}/{k[1]}": v for k, v in sorted(c.items())},
                      "missing": {f"{k[0]}/{k[1]}": v for k, v in sorted(missing.items())}}, indent=1))


def texts():
    return [json.loads(x) for x in open(TEXTS, encoding="utf-8")]


def save_spans(name, recs):
    p = os.path.join(CACHE, "spans", name + ".jsonl")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".tmp", "w", encoding="utf-8") as fh:
        for x in recs:
            fh.write(json.dumps(x, ensure_ascii=False) + "\n")
    os.replace(p + ".tmp", p)


def load_spans(name):
    p = os.path.join(CACHE, "spans", name + ".jsonl")
    if not os.path.exists(p):
        return None
    return {x["id"]: x["names"] for x in map(json.loads, open(p, encoding="utf-8"))}


NL_TAG = {"PersonalName": "person", "PlaceName": "place", "OrganizationName": "organization"}


def cmd_nltag(a):
    if not os.path.exists(NLTAG_BIN) or os.path.getmtime(NLTAG_BIN) < os.path.getmtime(NLTAG_SRC):
        os.makedirs(CACHE, exist_ok=True)
        subprocess.run(["swiftc", "-O", NLTAG_SRC, "-o", NLTAG_BIN], check=True)
    rows = texts()
    inp = "".join(json.dumps({"id": r["id"], "text": r["text"]}) + "\n" for r in rows)
    t = time.time()
    out = subprocess.run([NLTAG_BIN], input=inp, capture_output=True, text=True, check=True).stdout
    spans = {x["id"]: x["spans"] for x in map(json.loads, out.splitlines())}
    missing = [r["id"] for r in rows if r["id"] not in spans]
    if missing:
        raise SystemExit(f"nltag_names returned nothing for {len(missing)} texts: {missing[:5]}")
    save_spans("nltagger", [{"id": r["id"], "names": [[NL_TAG[s["tag"]], s["text"]] for s in spans[r["id"]]]}
                            for r in rows])
    print(f"nltagger: {len(rows)} texts, {time.time() - t:.1f} s")


def cmd_gliner(a):
    import gliner2
    m = gliner2.AutoExtractor.from_pretrained(GLINER[a.size])
    rows = [r for r in texts() if GLINER_SET[r["set"]] == a.size]
    name = f"gliner2.5-{a.size}"
    done = load_spans(name) or {}
    recs = [{"id": k, "names": v} for k, v in done.items()]
    todo = [r for r in rows if r["id"] not in done]
    t = time.time()
    for i, r in enumerate(todo, 1):
        names = []
        if r["text"].strip():
            sp = m.extract_entities(r["text"], ["person", "organization", "location"],
                                    include_spans=True).get("entities", {})
            names = [["place" if k == "location" else k, e["text"]]
                     for k, v in sp.items() for e in v if isinstance(e, dict) and e.get("text")]
        recs.append({"id": r["id"], "names": names})
        if i % 100 == 0 or i == len(todo):
            save_spans(name, recs)
            print(f"{name}: {i}/{len(todo)} ({time.time() - t:.0f} s)", flush=True)
    save_spans(name, recs)


# --- the 27B's page entity prompt, as a Sherlock pack ------------------------------------------------

PACK = os.path.expanduser("~/.local/state/archive-autonomous/artifacts/ent-robust-20261029")   # the hand-over
BACK = os.path.join(RC, "sherlock-results", "ent-robust-20261029")      # where the owner's session puts the answers


def cmd_pack(a):
    rows = texts()
    os.makedirs(os.path.join(PACK, "ent"), exist_ok=True)
    reqs = []
    for r in rows:
        if not r["text"].strip():
            continue
        h = hashlib.sha256(r["id"].encode()).hexdigest()[:16]
        reqs.append({"id": f"ent-{h}", "key": r["id"], "set": r["set"], "source": r["source"],
                     "prompt": ENTITY_PROMPT.format(text=r["text"])})
    with open(os.path.join(PACK, "ent", "requests.jsonl"), "w", encoding="utf-8") as fh:
        for q in reqs:
            fh.write(json.dumps(q, ensure_ascii=False) + "\n")
    chars = sum(len(q["prompt"]) for q in reqs)
    meta = {"item": "W46.ent-robust", "requests": len(reqs), "prompt_chars": chars,
            "prompt_sha256": hashlib.sha256(ENTITY_PROMPT.encode()).hexdigest(), "model": "qwen3.6-27b",
            "thinking": False, "temperature": 0,
            "counts": dict(collections.Counter(f"{q['set']}/{q['source']}" for q in reqs))}
    json.dump(meta, open(os.path.join(PACK, "ent", "pack.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in meta.items() if k != "counts"}))


def cmd_freeze(a):
    """Copy the cluster support files into the pack and hash every file (sherlock/ent-robust/check_pack.py reads it)."""
    import shutil
    sh = os.path.join(HERE, "sherlock")
    job = os.path.join(PACK, "support", "job")
    os.makedirs(os.path.join(job, "bin"), exist_ok=True)
    shutil.copy2(os.path.join(HERE, "postcorrect_cluster.py"), os.path.join(PACK, "support"))
    shutil.copy2(os.path.join(sh, "ent-robust", "check_pack.py"), os.path.join(PACK, "support"))
    for f in ("submit.sh", "stage-job.sh", "job.sh"):
        shutil.copy2(os.path.join(sh, "ent-robust", f), job)
    shutil.copy2(os.path.join(sh, "sh.env"), job)
    for f in os.listdir(os.path.join(sh, "bin")):
        shutil.copy2(os.path.join(sh, "bin", f), os.path.join(job, "bin"))
    arms = [x for x in ("ent", "g17") if os.path.exists(os.path.join(PACK, x, "requests.jsonl"))]
    files = {}
    for dp, dns, fns in os.walk(PACK):
        rel = os.path.relpath(dp, PACK)
        dns[:] = [d for d in dns if d not in ("out", "logs")]     # answers are never frozen
        for fn in fns:
            if rel == "." and fn == "freeze.json":
                continue
            path = os.path.join(dp, fn)
            files[os.path.normpath(os.path.join(rel, fn))] = hashlib.sha256(open(path, "rb").read()).hexdigest()
    json.dump({"item": "W46.ent-robust", "arms": arms, "files": dict(sorted(files.items()))},
              open(os.path.join(PACK, "freeze.json"), "w"), indent=1)
    size = sum(os.path.getsize(os.path.join(PACK, f)) for f in files)
    print(f"froze {len(files)} files, {size / 1e6:.1f} MB, arms {arms}: {PACK}")


def llm_names(rec):
    """A reply of the entity prompt -> [[type, name], ...]; None when it does not parse."""
    raw = (rec or {}).get("text") or ""
    raw = re.sub(r"(?s)<think>.*?</think>", "", raw).strip()
    m = re.search(r"\{.*\}", raw, re.S)
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
    except json.JSONDecodeError:
        return None
    out = []
    for field, tag in (("persons", "person"), ("places", "place"), ("organizations", "organization")):
        for v in d.get(field) or []:
            if isinstance(v, str) and v.strip():
                out.append([tag, v.strip()])
    for f in ET.FIELDS:
        v = d.get(f)
        if isinstance(v, str) and v.strip() and v.strip().lower() != "null":
            out.append([f, v.strip()])
    return out


def load_llm():
    p = os.path.join(PACK, "ent", "requests.jsonl")
    if not os.path.exists(p):
        return None
    out, bad = {}, 0
    for q in map(json.loads, open(p, encoding="utf-8")):
        op = os.path.join(BACK, "ent", "out", q["id"] + ".json")
        if not os.path.exists(op):
            continue
        names = llm_names(json.load(open(op, encoding="utf-8")))
        if names is None:
            bad += 1
            continue
        out[q["key"]] = names
    return (out, bad) if out else None


# --- scoring -------------------------------------------------------------------------------------

def norm_names(names):
    """Distinct (type, name) pairs, a name with no token dropped."""
    seen, out = set(), []
    for tag, n in names:
        k = (tag, " ".join(ET.tokens(n)))
        if k[1] and k not in seen:
            seen.add(k)
            out.append((tag, n))
    return out


def match_count(ref, hyp):
    """Greedy one-to-one ed2 matches within a type."""
    used = set()
    hits = 0
    for tag, n in ref:
        for j, (t2, m) in enumerate(hyp):
            if j not in used and t2 == tag and ET.match(m, n, "ed2"):
                used.add(j)
                hits += 1
                break
    return hits


def page_scores(rows, names, types=None):
    """[(row, tp, n_ref, n_hyp)] for every non-truth text whose truth text has names."""
    by_page = {}
    for r in rows:
        if r["source"] == "truth":
            by_page[(r["set"], r["page"])] = r
    out = []
    for r in rows:
        if r["source"] == "truth" or r["id"] not in names:
            continue
        t = by_page.get((r["set"], r["page"]))
        if t is None or t["id"] not in names:
            continue
        ref = norm_names([x for x in names[t["id"]] if types is None or x[0] in types])
        if not ref:
            continue
        hyp = norm_names([x for x in names[r["id"]] if types is None or x[0] in types])
        out.append((r, match_count(ref, hyp), len(ref), len(hyp)))
    return out


def prf(items):
    tp = sum(x[1] for x in items)
    nr = sum(x[2] for x in items)
    nh = sum(x[3] for x in items)
    p = tp / nh if nh else 0.0
    r = tp / nr if nr else 0.0
    f = 2 * p * r / (p + r) if p + r else 0.0
    return {"pages": len(items), "ref": nr, "hyp": nh, "p": round(p, 3), "r": round(r, 3), "f1": round(f, 3)}


def bin_of(c):
    for lo, hi in BINS:
        if lo <= c < hi:
            return lo, hi
    return BINS[-1]


def bin_label(b):
    lo, hi = b
    return f"{lo * 100:g}-{hi * 100:g}%" if hi < 9 else f"over {lo * 100:g}%"


def score_all(rows, names):
    ps = page_scores(rows, names, types={"person", "place", "organization"})
    res = {"by_route": {}, "by_group": {}, "by_bin": {}, "postcorrect": {}}
    for st in ("owner96", "public-latin"):
        sub = [x for x in ps if x[0]["set"] == st]
        raw = [x for x in sub if "+" not in x[0]["source"]]
        res["by_route"][st] = {s: prf([x for x in raw if x[0]["source"] == s])
                               for s in sorted({x[0]["source"] for x in raw})}
        res["by_group"][st] = {f"{s} | {g}": prf([x for x in raw if x[0]["source"] == s and x[0]["group"] == g])
                               for s in sorted({x[0]["source"] for x in raw})
                               for g in sorted({x[0]["group"] for x in raw})
                               if any(x[0]["source"] == s and x[0]["group"] == g for x in raw)}
        res["by_bin"][st] = {bin_label(b): prf([x for x in raw if bin_of(x[0]["cer"]) == b]) for b in BINS}
        pcs = {}
        for x in sub:
            if "+" in x[0]["source"]:
                base, arm = x[0]["source"].split("+")
                pcs.setdefault(arm, []).append(x)
        for arm, items in pcs.items():
            keys = {(x[0]["page"], x[0]["source"].split("+")[0]) for x in items}
            same = [x for x in raw if (x[0]["page"], x[0]["source"]) in keys]
            res["postcorrect"][f"{st}, {arm}"] = {"raw": prf(same), "corrected": prf(items)}
    allraw = [x for x in ps if "+" not in x[0]["source"]]
    res["by_bin"]["both"] = {bin_label(b): prf([x for x in allraw if bin_of(x[0]["cer"]) == b]) for b in BINS}
    res["switch_off"] = {}
    for st, bins in res["by_bin"].items():
        res["switch_off"][st] = next((bin_label(b) for b in BINS
                                      if bins[bin_label(b)]["pages"] >= 10 and bins[bin_label(b)]["f1"] < SWITCH_F1), None)
    res["route_cer"] = {st: {src: round(sum(x[0]["cer"] for x in ps if x[0]["set"] == st and x[0]["source"] == src)
                                        / max(1, sum(1 for x in ps if x[0]["set"] == st and x[0]["source"] == src)), 3)
                             for src in sorted({x[0]["source"] for x in ps if x[0]["set"] == st and "+" not in x[0]["source"]})}
                        for st in ("owner96", "public-latin")}
    return res


def role_scores(rows, names):
    """The 27B's sender / recipient / place on a route against its answer on the truth text (owner 96)."""
    by_page = {(r["set"], r["page"]): r for r in rows if r["source"] == "truth"}
    out = collections.defaultdict(lambda: collections.Counter())
    for r in rows:
        if r["set"] != "owner96" or r["source"] == "truth" or r["id"] not in names:
            continue
        t = by_page.get((r["set"], r["page"]))
        if t is None or t["id"] not in names:
            continue
        for f in ET.FIELDS:
            ref = [n for tag, n in names[t["id"]] if tag == f]
            hyp = [n for tag, n in names[r["id"]] if tag == f]
            c = out[(r["source"], f)]
            if ref:
                c["ref"] += 1
                c["same"] += bool(hyp and ET.match(hyp[0], ref[0], "ed2"))
                c["null"] += not hyp
            elif hyp:
                c["extra"] += 1
    return {f"{s} | {f}": dict(c) for (s, f), c in sorted(out.items())}


def cmd_report(a):
    rows = texts()
    s = {"texts": dict(collections.Counter(f"{r['set']}/{r['source']}" for r in rows)), "extractors": {}}
    for name in ("nltagger", "gliner2.5-base", "gliner2.5-multi"):
        n = load_spans(name)
        if n:
            s["extractors"][name] = score_all(rows, n)
    llm = load_llm()
    if llm:
        names, bad = llm
        s["extractors"]["qwen3.6-27b-entity-prompt"] = score_all(rows, names)
        s["extractors"]["qwen3.6-27b-entity-prompt"]["roles"] = role_scores(rows, names)
        s["extractors"]["qwen3.6-27b-entity-prompt"]["unparsed"] = bad
    office = os.path.join(CACHE, "office-summary.json")
    if os.path.exists(office):
        s["office"] = json.load(open(office))
    g17 = os.path.join(CACHE, "g17-summary.json")
    if os.path.exists(g17):
        s["g17"] = json.load(open(g17))
    json.dump(s, open(os.path.join(RESULTS, "ent-robust.json"), "w"), indent=1, sort_keys=True)
    open(os.path.join(RESULTS, "ent-robust.md"), "w").write(markdown(s))
    print(json.dumps({k: v.get("switch_off") for k, v in s["extractors"].items()}))


SET_NAME = {"owner96": "the owner's 96", "public-latin": "the public Latin pages"}


def markdown(s):
    L = ["# At what OCR error level entity extraction stops paying (W46.ent-robust)", "",
         "Generated by `scripts/segbench/ent_robust.py report`; method in its header. Each extractor's names on a "
         "route's reading are scored against the same extractor's names on the page's truth text (ed2 within a "
         "type), so 1.0 means the OCR changed nothing the extractor finds; whether the extractor is right is "
         "W46.ent-score's question. CER is the OCR scorer's page figure (1 - NewsBench overall).", ""]
    ex = s["extractors"]
    for name, r in ex.items():
        L += [f"## {name}", ""]
        for st in ("owner96", "public-latin"):
            routes = r["by_route"].get(st) or {}
            if not routes:
                continue
            L += [f"By route, {SET_NAME[st]} (mean page CER of the scored pages):", "",
                  "| route | pages | mean CER | names on truth | names on route | P | R | F1 |", "|---|---|---|---|---|---|---|---|"]
            for src, v in routes.items():
                L.append(f"| {src} | {v['pages']} | {r['route_cer'][st].get(src, 0):.3f} | {v['ref']} | {v['hyp']} | "
                         f"{v['p']:.3f} | {v['r']:.3f} | {v['f1']:.3f} |")
            L.append("")
        L += ["By page CER, every route pooled (pages / F1):", "",
              "| CER | " + " | ".join(bin_label(b) for b in BINS) + " |", "|---|" + "---|" * len(BINS)]
        for st in ("owner96", "public-latin", "both"):
            bins = r["by_bin"].get(st) or {}
            L.append(f"| {SET_NAME.get(st, 'both sets')} | " + " | ".join(
                f"{bins[bin_label(b)]['pages']} / {bins[bin_label(b)]['f1']:.2f}" if bins[bin_label(b)]["pages"] else "–"
                for b in BINS) + " |")
        L += ["", "First CER bin (10 pages or more) below F1 " + f"{SWITCH_F1}: " + ", ".join(
            f"{SET_NAME.get(k, 'both sets')} {v or 'none'}" for k, v in r["switch_off"].items()) + ".", ""]
        L += ["By kind (owner) and stratum (public), F1 per route:", ""]
        for st in ("owner96", "public-latin"):
            g = r["by_group"].get(st) or {}
            groups = sorted({k.split(" | ")[1] for k in g})
            srcs = sorted({k.split(" | ")[0] for k in g})
            if not g:
                continue
            L += ["| route | " + " | ".join(groups) + " |", "|---|" + "---|" * len(groups)]
            for src in srcs:
                L.append(f"| {src} | " + " | ".join(
                    f"{g[f'{src} | {gr}']['f1']:.2f} ({g[f'{src} | {gr}']['pages']})" if f"{src} | {gr}" in g else "–"
                    for gr in groups) + " |")
            L.append("")
        if r["postcorrect"]:
            L += ["Post-correction by the 27B (W46.ocr-postcorrect's readings, on the pages it corrected):", "",
                  "| set, arm | pages | raw F1 | corrected F1 |", "|---|---|---|---|"]
            for k, v in r["postcorrect"].items():
                L.append(f"| {k} | {v['raw']['pages']} | {v['raw']['f1']:.3f} | {v['corrected']['f1']:.3f} |")
            L.append("")
        if r.get("roles"):
            L += ["Letter fields (owner 96): the reply on the route against its reply on the truth text.", "",
                  "| route, field | truth reply named | same (ed2) | null on route | named only on route |",
                  "|---|---|---|---|---|"]
            for k, v in r["roles"].items():
                L.append(f"| {k} | {v.get('ref', 0)} | {v.get('same', 0)} | {v.get('null', 0)} | {v.get('extra', 0)} |")
            L += ["", f"Unparsed replies: {r.get('unparsed', 0)}.", ""]
    if "qwen3.6-27b-entity-prompt" not in ex:
        L += ["## Qwen3.6 27B through the entity prompt", "",
              "Not yet run: the Sherlock pack (2,066 requests) waits for an owner session "
              "(`execution-plans/items/W46.ent-robust.md`). Its replies go into this page when they are home.", ""]
    if "office" in s:
        o = s["office"]["overall"]
        L += ["## Office holders as dating evidence (G test 7)", "",
              f"`ent_office.py` on the {o['documents']} owner-answered dating documents (33 class A, 21 class D): "
              f"{o['mentions']} person mentions with an office in {o['documents_with_mention']} documents; "
              f"{o['linked']} linked unambiguously to Wikidata, {o['ambiguous']} ambiguous, {o['nil']} not found "
              f"({o.get('nil_no_search_hit', 0)} no search hit, {o.get('nil_no_human_with_P39', 0)} no person with a "
              f"position held, {o.get('nil_no_matching_position', 0)} no matching position). Of the links, "
              f"{o['bracket']} brackets the owner's year (width {o.get('bracket_width_median')} years) and "
              f"{o['exclude']} excludes it (a past office holder named in retrospect). Documents dated by a "
              f"bracketing link: {o['documents_bracketed']} of {o['documents']}. Wikidata calls: "
              f"{s['office']['spend']['wikidata_calls']}, $0.", ""]
    if "g17" in s:
        L += ["## G17 Business Letters", ""]
        for label, v in s["g17"].items():
            L.append(f"- {label}: F1 macro {v.get('f1_macro')}, F1 micro {v.get('f1_micro')} (published median 0.55, "
                     f"IQR 0.51-0.59, over 96 configurations)")
        L.append("")
    else:
        L += ["## G17 Business Letters", "", "Not yet run: its 27B arm is in the same Sherlock pack; Gemini is "
              "W46.ent-robust-paid; Claude through the plan waits for W46.gateway-models-ok.", ""]
    L += READING
    return "\n".join(L) + "\n"


READING = []


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("texts")
    sub.add_parser("nltag")
    g = sub.add_parser("gliner")
    g.add_argument("--size", choices=sorted(GLINER), required=True)
    sub.add_parser("pack")
    sub.add_parser("freeze")
    sub.add_parser("report")
    a = ap.parse_args()
    {"texts": cmd_texts, "nltag": cmd_nltag, "gliner": cmd_gliner, "pack": cmd_pack, "freeze": cmd_freeze, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    main()
