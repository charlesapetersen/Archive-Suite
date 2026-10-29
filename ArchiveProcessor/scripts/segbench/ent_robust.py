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

Scoring. Names are compared with ent_truth.match at ed2 (tokens folded, titles dropped, whole-name edit distance 2),
exactly when either side is four letters or fewer, and within one type; each truth-text name is matched to at most one route name, greedily in text order. Per page
the reference is the extractor's names on the truth text; precision, recall and F1 are micro-averaged over names.
A page whose truth text yields no names for that extractor is left out for it. A route reading that failed (no text:
length-capped or unparsed; the OCR scorer gives it CER 1.0) counts as a reading with no names, for every extractor. CER bins: 0-2, 2-5, 5-10, 10-20,
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
        out[(r["set"], r["route"], r["page"])]["pc-" + r["arm"]] = (rec["text"], r["prompt"])
    return out


def pc_for(pc, st, route, page, raw):
    """The corrected readings of this route's reading of the page. The pack's owner route "qwen3-vl-8b" mixes the
    Mac MLX reading and a FarmShare one, so it counts for qwen3-vl-8b-mlx4 only where the prompt carries that very
    reading."""
    got = dict(pc.get((st, route, page), {}))
    if route == "qwen3-vl-8b-mlx4" and raw and raw.strip():
        for arm, (ct, prompt) in pc.get((st, "qwen3-vl-8b", page), {}).items():
            if re.sub(r"\s+", " ", raw).strip() in re.sub(r"\s+", " ", prompt):
                got[arm] = (ct, prompt)
    return {arm: ct for arm, (ct, _) in got.items()}


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
            if ("owner96", cr, page) not in cer:
                missing[("owner96", route)] += 1
                continue
            # A reading that failed (length-capped, unparsed) is scored as a page that yields no names, as the
            # OCR scorer scores it at CER 1.0, so a route is not flattered by the pages it could not read.
            recs.append({"set": "owner96", "page": page, "group": kind, "source": route, "failed": t is None,
                         "cer": cer[("owner96", cr, page)], "text": clean(t)})
            for arm, ct in pc_for(pc, "owner96", route, page, t).items():
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
            if ("public895", cr, job) not in cer:
                missing[("public-latin", route)] += 1
                continue
            # A reading that failed (length-capped, unparsed) is scored as a page that yields no names, as the
            # OCR scorer scores it at CER 1.0, so a route is not flattered by the pages it could not read.
            recs.append({"set": "public-latin", "page": job, "group": stratum, "source": route, "failed": t is None,
                         "cer": cer[("public895", cr, job)], "text": clean(t)})
            for arm, ct in pc_for(pc, "public895", route, job, t).items():
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
                     "text_sha256": hashlib.sha256(r["text"].encode()).hexdigest(),
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
    now = {r["id"]: hashlib.sha256(r["text"].encode()).hexdigest() for r in texts()}
    out, bad = {}, 0
    for q in map(json.loads, open(p, encoding="utf-8")):
        if now.get(q["key"]) != q["text_sha256"]:
            raise SystemExit(f"{q['key']}: the text changed since the pack was built; its reply cannot be scored")
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


def same_name(a, b):
    """ent_truth.match at ed2, except that a name of four letters or fewer (folded, titles dropped) must match
    exactly: two edits of a short name turn "Kerr" into "Bert" and "K" into "Ko"."""
    ta, tb = " ".join(ET.tokens(a)), " ".join(ET.tokens(b))
    if min(len(ta), len(tb)) <= 4:
        return ta == tb
    return ET.match(a, b, "ed2")


def match_count(ref, hyp):
    """Greedy one-to-one matches within a type (same_name)."""
    used = set()
    hits = 0
    for tag, n in ref:
        for j, (t2, m) in enumerate(hyp):
            if j not in used and t2 == tag and same_name(m, n):
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
        if r["source"] == "truth" or (r["id"] not in names and r["text"].strip()):
            continue
        t = by_page.get((r["set"], r["page"]))
        if t is None or t["id"] not in names:
            continue
        ref = norm_names([x for x in names[t["id"]] if types is None or x[0] in types])
        if not ref:
            continue
        hyp = norm_names([x for x in names.get(r["id"], []) if types is None or x[0] in types])
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
    res["failed"] = {st: dict(collections.Counter(x[0]["source"] for x in ps if x[0]["set"] == st and x[0].get("failed")))
                     for st in ("owner96", "public-latin")}
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
                c["same"] += bool(hyp and same_name(hyp[0], ref[0]))
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
            want = [r["id"] for r in rows if name == "nltagger" or GLINER_SET[r["set"]] == name.split("-")[-1]]
            lacking = [i for i in want if i not in n]
            if lacking:      # a run still going or stopped part-way: never report it as if complete
                print(f"{name}: {len(lacking)} of {len(want)} texts have no spans; left out of the report")
                continue
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


def pack_requests():
    p = os.path.join(PACK, "ent", "requests.jsonl")
    return sum(1 for _ in open(p, encoding="utf-8")) if os.path.exists(p) else 0


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
                  "| route | pages | failed readings | mean CER | names on truth | names on route | P | R | F1 |",
                  "|---|---|---|---|---|---|---|---|---|"]
            for src, v in routes.items():
                L.append(f"| {src} | {v['pages']} | {r['failed'][st].get(src, 0)} | {r['route_cer'][st].get(src, 0):.3f} | "
                         f"{v['ref']} | {v['hyp']} | "
                         f"{v['p']:.3f} | {v['r']:.3f} | {v['f1']:.3f} |")
            L.append("")
        L += ["By page CER, every route pooled (route readings / F1):", "",
              "| CER | " + " | ".join(bin_label(b) for b in BINS) + " |", "|---|" + "---|" * len(BINS)]
        sets = [st for st in ("owner96", "public-latin") if r["by_route"].get(st)]
        for st in sets + (["both"] if len(sets) == 2 else []):
            bins = r["by_bin"].get(st) or {}
            L.append(f"| {SET_NAME.get(st, 'both sets')} | " + " | ".join(
                f"{bins[bin_label(b)]['pages']} / {bins[bin_label(b)]['f1']:.2f}" if bins[bin_label(b)]["pages"] else "–"
                for b in BINS) + " |")
        L += ["", "First CER bin (10 readings or more) below F1 " + f"{SWITCH_F1}: " + ", ".join(
            f"{SET_NAME.get(k, 'both sets')} {r['switch_off'][k] or 'none'}"
            for k in sets + (["both"] if len(sets) == 2 else [])) + ".", ""]
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
        if any(v["raw"]["pages"] >= 10 for v in r["postcorrect"].values()):
            L += ["Post-correction by the 27B (W46.ocr-postcorrect's readings, on the pages it corrected):", "",
                  "| set, arm | pages | raw F1 | corrected F1 |", "|---|---|---|---|"]
            for k, v in r["postcorrect"].items():
                if v["raw"]["pages"] < 10:
                    continue
                L.append(f"| {k} | {v['raw']['pages']} | {v['raw']['f1']:.3f} | {v['corrected']['f1']:.3f} |")
            L.append("")
        if r.get("roles"):
            L += ["Letter fields (owner 96): the reply on the route against its reply on the truth text.", "",
                  "| route | field | truth reply named | same (ed2) | null on route | named only on route |",
                  "|---|---|---|---|---|---|"]
            for k, v in r["roles"].items():
                L.append(f"| {k} | {v.get('ref', 0)} | {v.get('same', 0)} | {v.get('null', 0)} | {v.get('extra', 0)} |")
            L += ["", f"Unparsed replies: {r.get('unparsed', 0)}.", ""]
    if "qwen3.6-27b-entity-prompt" not in ex:
        L += ["## Qwen3.6 27B through the entity prompt", "",
              f"Not yet run: the Sherlock pack ({pack_requests():,} requests) waits for an owner session "
              "(`execution-plans/items/W46.ent-robust.md`). Its replies go into this page when they are home.", ""]
    if "office" in s:
        o = s["office"]["overall"]
        L += ["## Office holders as dating evidence (G test 7)", "",
              f"`ent_office.py` on the {o['documents']} owner-answered dating documents (33 class A, 21 class D): "
              f"{o['mentions']} person mentions with an office in {o['documents_with_mention']} documents; "
              f"{o['linked']} linked unambiguously to Wikidata, {o['ambiguous']} ambiguous, {o['nil']} not found "
              f"({o.get('nil_no_search_hit', 0)} no search hit, {o.get('nil_no_human_with_P39', 0)} no person with a "
              f"position held, {o.get('nil_no_matching_position', 0)} no matching position). Of the links, "
              f"{o['bracket']} bracket the owner's year (median width {o.get('bracket_width_median'):g} years) and "
              f"{o['exclude']} excludes it. Documents dated by a "
              f"bracketing link: {o['documents_bracketed']} of {o['documents']}. Wikidata calls: "
              f"{s['office']['spend']['wikidata_calls']}, $0.", ""]
    if "g17" in s:
        L += ["## G17 Business Letters", ""]
        for label, v in s["g17"].items():
            L.append(f"- {label}: F1 macro {v.get('f1_macro')}, F1 micro {v.get('f1_micro')} (published median 0.55, "
                     f"IQR 0.51-0.59, over 96 configurations); {v.get('letters')} letters, "
                     f"{v.get('unparsed', 0)} unparsed, {v.get('truncated', 0)} truncated")
            for part in ("signed", "unsigned"):
                if part in v:
                    L.append(f"  - {part} ({v[part]['letters']} letters): F1 macro {v[part]['f1_macro']}, "
                             f"micro {v[part]['f1_micro']}")
            cats = v.get("categories", {})
            if cats:
                L.append("  - by field: " + ", ".join(f"{c} {x['f1']:.2f} ({x['tp']} right, {x['fp']} wrong or extra, "
                                                     f"{x['fn']} missed)" for c, x in cats.items()))
        L.append("")
    else:
        L += ["## G17 Business Letters", "", "Not yet run: its 27B arm is in the same Sherlock pack; Gemini is "
              "W46.ent-robust-paid; Claude through the plan waits for W46.gateway-models-ok.", ""]
    L += READING
    return "\n".join(L) + "\n"


READING = ["## Reading", "", """\
**The LLM extractor the app would use holds up better than the taggers, one CER bin longer.** Qwen3.6 27B through
the page entity prompt (Sherlock job 50126556, one L40S, 26 minutes for 2,078 texts and 57 G17 letters; 10 replies
unparsed) is the extractor the laptop route would ship, as W46.ent-score found the taggers unusable (ed2 F1 0.24 at
best). On the owner's 96, its names on a route agree with its names on the truth text at F1 0.95 to 0.96 for Claude
Sonnet 5.5 and Gemini 3.8 Flash, 0.92 for Qwen3-VL 8B, 0.90 for the 27B's own reading and 0.83 for Apple Vision,
against the taggers' 0.74 to 0.78 for Vision. By page CER: 0.96 under 2%, 0.93 at 2 to 5%, 0.81 at 5 to 10%, 0.74
at 10 to 40% and 0.63 over 40%, so it first drops below 0.8 at 10 to 20%, where the taggers drop at 5 to 10%. The
gain is largest where the text is worst: on handwritten pages the 27B keeps 0.52 of Vision's names (the taggers 0.28
to 0.31), 0.79 of the 8B's, 0.82 of its own and 0.88 to 0.94 of the API routes'.""", "", """\
**The letter fields are where Vision's text still fails.** Sender, recipient and place from the 27B's reply on a
route against its reply on the truth text: through Claude, Gemini, the 8B and the 27B, 11 to 18 of 13 to 18 named
fields match on each route; through Vision only 12 of 18 recipients, 8 of 17 senders and 11 of 14 places, with 4 to 5
recipients and senders lost outright. A sender is often a signature or letterhead, exactly what Vision misreads.""", "", """\
**G17 places the 27B at the published median.** On Business Letters' 57 letters (all pages in one request, the
harness's own prompt and scorer) the 27B scores F1 macro 0.54, micro 0.55, against a published median of 0.55 over
96 configurations. Dates are nearly solved (0.93); recipients 0.59; senders 0.11, because it names the firm on the
letterhead (the benchmark wants the signing person), which is the same sender/firm ambiguity W46.ent-score met.
So the prompt is an ordinary one by an external measure, not a weak one, and the switch-off rule below does not hang
on a poor extractor.""", "", """\
**The taggers, for comparison.** These measure how much a route's text changes what a name tagger sees, not what
the app's fields would lose.""", "", """\
**On the owner's pages the names survive the API and 27B routes and not Apple Vision.** Against the names a tagger
finds in the truth text, the names it finds in Gemini 3.8 Flash's and Claude Sonnet 5.5's readings agree at F1 0.93
to 0.95, Qwen3.6 27B's and Qwen3-VL 8B's at 0.89 to 0.91, Apple Vision's at 0.74 to 0.78. By page CER the agreement
is 0.96 under 2%, 0.86 to 0.87 at 2 to 5%, and falls below 0.8 at 5 to 10% (0.76 to 0.78), to about 0.5 over 40%. The
kind of page carries most of it: on handwritten pages Vision's text keeps 0.28 to 0.31 of the names, the 8B's 0.66
to 0.70, the 27B's 0.74 and Gemini's 0.84 to 0.89; on typed and printed pages every route but Vision keeps 0.89 or
more and Vision 0.76 to 0.83.""", "", """\
**The switch-off rule, confirmed by the LLM arm.** The app does not know a page's CER, but it knows the page's kind
and route. So: show extracted names from the API and 27B routes on every kind; from the Mac route's Vision text only
on typed and printed pages (the 27B's agreement there 0.85 to 0.88), marked as read from OCR, and never on handwritten
pages, where about half the names would be lost or wrong even through the LLM (0.52), and never the sender field from
Vision text on any kind; from the 8B on handwritten pages (0.79) only with the quote check W46.ent-score set. A page whose route reading
failed (length-capped or unparsed: the 8B 4 of 96 here) gives no names at all and should say so.""", "", """\
**Post-correction pays for names when it sees the image.** On the 30 to 32 owner pages W46.ocr-postcorrect corrected
(Vision and the 8B, in its 0.7 to 0.9 NES band), the 27B's image-grounded correction lifts the tagger agreement
from 0.74-0.76 to 0.92; the text-only correction to 0.82 to 0.87. The 27B extractor shows the same on its 29 pages:
0.84 raw, 0.94 after the image-grounded correction, 0.88 after the text-only one. That is the OCR finding again,
measured on names: where a page is corrected anyway, extract after the image-grounded correction.""", "", """\
**The public Latin pages are another matter.** The same comparison on the 440's Latin strata gives 0.09 to 0.53 by
route: early print (L8) keeps 0.60 to 0.70 through the model routes, the medieval and early-modern hands (L5, L7)
0.02 to 0.37 and the nineteenth-century hands (L6) up to 0.56 through Gemini. The taggers were not built for
medieval Latin and the routes' CER there is 0.35 to 0.72, so this says only that entity extraction is not a feature
for such pages on any route tested, which matches what the readers make of them. The 27B extractor does no better
there (0.15 to 0.46 by route; early print 0.44 to 0.74, the hands 0.05 to 0.57), and even its under-2% bin is only
0.79 on 11 readings, so on these pages the LLM's own disagreement with itself is part of the figure.""", "", """\
**Office holders do not date this corpus.** Of the 54 owner-answered dating documents, 9 name a person with an office,
3 of those 19 mentions link unambiguously to Wikidata and 2 documents are bracketed by a term (median 14 years wide);
one link excludes the year, a past officeholder named in retrospect, so a link is weak evidence, not a constraint.
Most named people (business, university and local figures) have no position held in Wikidata. Linking for dating does
not earn a line in Phase 4.""", "", """\
**The noise-aware fine-tune (G test 9) is not run.** It was conditional on a gap worth closing for profile 1 or 5.
Noise costs a tagger 0.03 to 0.09 on typed pages through the model routes, while W46.ent-score found the taggers 30
points short on clean text, because they do not mark most names in letter text at all; a fine-tune against OCR
degradation cannot close that, and the laptop route for these fields is the local LLM through the prompt.""", "", """\
**Limits.** The reference is the extractor's own output on the truth text, so a name it misses on both sides is
invisible here. Gemini on the scans and on G17 is W46.ent-robust-paid; Claude through the plan
waits for W46.gateway-models-ok (owner, 2026-10-21), so the only G17 row is the 27B's. Readings that failed count as pages with no names, which lowers the 8B's public figure most (77 to 94
of 232 to 302 public pages failed). Two edits are allowed only on names of five letters or more. Post-correction rows
come from W46.ocr-postcorrect's band sample, so they say what correction buys where it is applied, not on an average
page. Not an OCR or segmentation result, so ArchiveOCRBench is unchanged.""", ""]


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
