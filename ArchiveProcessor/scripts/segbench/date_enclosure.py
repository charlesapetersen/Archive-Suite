#!/usr/bin/env python3
"""W46.date-enclosure: precision and recall of the app's [enclosure] marker, and a relation classifier.

    python3 date_enclosure.py set         # the evaluation set (private, bench cache date-tagging/enclosure/); counts
    python3 date_enclosure.py render      # each candidate's first page as JPEG (sips, read-only on the corpus)
    run-guarded.sh --label date-enclosure --need-gb 8 -- <lab venv>/bin/python date_enclosure.py marker [--model K]
    run-guarded.sh --label date-enclosure --need-gb 4 -- <lab venv>/bin/python date_enclosure.py relate [--model K]
    python3 date_enclosure.py export --out DIR             # the cluster pack (relation prompts; private)
    python3 date_enclosure.py import --answers F --label L
    python3 date_enclosure.py score       # segbench-results/date-enclosure.md and .json

The unit is a document segment of the agreed pool (date_tagging.folder_documents, tag-rule segments in folder order)
whose previous segment is a document; a relation never crosses a box or folder label (enclosure_split.neighbour).
Three groups (10-gap-audit.md §5 item 15, B-dating.md §3):
  owner     the 15 documents of the owner's relation truth (date_truth_sets: 3 sent with the previous document,
            12 not); the only real truth, so its figures carry their counts
  A, A'     unprinted-year documents of the strict and chained classes (date_truth.structural_class): the owner's
            300 sample's own and the pool's stratified 200's. Their year matches the document before, which is
            what a relation would propagate, but the owner's 54 answers refute most of the strict class as covers
            (2 of 33), so a firing rate here is not recall; it is reported as the structural proxy
  neg       matched non-enclosure starts: documents printing their own year, the owner year of the document before
            differing, one per A/A' candidate from the same collection where one exists (seed 46). The owner did not
            give these the previous document's year, so a proposal on one propagates a Sent With the owner did not
            use
Arms (all $0, no plan route, CLAUDE.md "Plan routes wait for the gateway"):
  marker    the app's OCR prompt (OCRPrompt.build, compiled from the app source by enclosure_prompt.swift, previous
            page text = the cover's last page, no previous image) on the candidate's first page through a local VLM
            on this Mac; only the header is generated (the marker sits on line 1), parsed by the app's own
            parseEnclosureFlag. The Gemini arm is W46.date-enclosure-paid.
  relate    a relation classifier over the cover's text and the candidate's first page, yes or no with the quoted cue
            and a confidence: the trained 2B on this Mac (MLX), Qwen3.6-27B on Sherlock (export/import)
  cue       the rule baseline: the cover's last 600 characters announce an enclosure (enclose, attached, herewith, Enc.)
Propagation: for each proposal, whether the cover's own rule-picked year (date_traceable.rule_pick) equals the
candidate's owner year, i.e. whether the Sent With year and the Year tag the app would write match the owner's.

Read-only on the corpus. Private outputs stay in the bench cache; the committed summary carries counts and case ids
only. Run from scripts/segbench.
"""
import argparse
import collections
import hashlib
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.getcwd())
import corpus_pairs as CP
import corpus_survey as CS
import date_tagging as DT

OUT = os.path.join(DT.CACHE, "enclosure")
SET = os.path.join(OUT, "set.jsonl")
PAGES = os.path.join(OUT, "pages")
RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "segbench-results", "date-enclosure.md")
RESULTS_JSON = RESULTS[:-3] + ".json"
APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "macOS", "Sources", "ArchiveProcessor", "OCR",
                   "OCRPrompt.swift")
HELPER_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "enclosure_prompt.swift")
HELPER = os.path.join(OUT, "enclosure-prompt")
SEED = 46
MAX_SIDE = 1100            # date_draft's render size; the app sends 2048 px, which this 18 GB Mac does not hold for
                           # an 8B VLM beside the image tokens
MARKER_TOKENS = 24         # line 1 is the classification tag and the marker; nothing after it is read
RELATE_TOKENS = 200
COVER_HEAD, COVER_TAIL, CAND_CHARS = 1200, 1200, 2000
LTS = os.path.expanduser("~/Claude/Long term storage/FarmShare-20261018")
MODELS = {  # key -> (weights, label, arm)
    "qwen3-vl-8b-mlx4": ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "Qwen3-VL 8B, 4-bit MLX", "marker"),
    "qwen3.5-4b-mlx4": ("lmstudio-community/Qwen3.5-4B-MLX-4bit", "Qwen3.5 4B, 4-bit MLX", "marker"),
    "date-2b-mlx8": (os.path.join(LTS, "date-2b-8bit"), "the trained 2B date model, 8-bit MLX", "relate"),
}
LABEL_27B = "qwen3.6-27b-nothink"
GATEWAY = {  # W46.date-enclosure-paid's arms (date_enclosure_gateway.py) -> (label, arm)
    "gemini3.7-flash-gw-marker": ("Gemini 3.7 Flash, the page at 2048 px (gateway)", "marker"),
    "gemini3.7-flash-gw-relate": ("Gemini 3.7 Flash with both pages' images (gateway)", "relate"),
}
CUE = re.compile(r"\b(enclos\w*|attach\w*|herewith|enc\.|encl\.?|encs?\b)", re.I)


# ---------------------------------------------------------------------------------------------------------- the set
def owner_relation():
    """{doc id: truth-sets record} for the owner's answers that say whether the previous document was the cover."""
    p = os.path.join(DT.CACHE, "cases", "truth-sets.json")
    return {r["doc"]: r for r in json.load(open(p, encoding="utf-8"))["records"] if r.get("sent_with") is not None}


def walk():
    """Every agreed document segment with a year tag, text and a document before it, as dicts (texts included)."""
    import date_truth as DTR
    import enclosure_split as ES
    lab = {}
    for line in open(os.path.join(CP.CACHE, "labels.jsonl"), encoding="utf-8"):
        g = json.loads(line)
        lab[(g["folder_id"], g["n"])] = g
    folders = sorted({os.path.dirname(g["left"]) for g in lab.values()})
    out = []
    for f in folders:
        if DT.STANTON_RG165.search(f):
            continue
        segs = DT.folder_documents(f, lab)
        texts = ["\n\n".join(DT.page_text(p) for p in s["pages"]) for s in segs]
        truths = [DT.truth_of(CS.read_tags(os.path.join(CS.CORPUS, s["pages"][0]))) if s["kind"] == "doc" else None
                  for s in segs]
        ids = [hashlib.sha1(s["pages"][0].encode()).hexdigest()[:16] if s["kind"] == "doc" else None for s in segs]
        for k, s in enumerate(segs):
            if s["kind"] != "doc" or not s["agreed"]:
                continue
            j = ES.neighbour({"segs": segs}, k, -1)
            tr = truths[k][1]
            if j is None or not tr or "year" not in tr or not texts[k].strip() or not texts[j].strip():
                continue
            info = {"folder": f, "k": k, "segs": segs, "texts": texts, "truths": truths}
            d = {"id": ids[k], "truth": tr, "folder": f, "collection": CP.collection_of(f), "position": k,
                 "year_in_text": str(tr["year"]) in texts[k][:3000]}
            r = {**d, **ES.classify(d, info)}
            d["class"] = DTR.structural_class(r, info, {d["id"]: info})
            ptr = truths[j][1]
            d.update({"cover": ids[j], "cover_year": ptr.get("year") if ptr else None, "cover_text": texts[j],
                      "cover_last_page": DT.page_text(segs[j]["pages"][-1]), "first_page": s["pages"][0],
                      "first_page_text": DT.page_text(s["pages"][0]) or texts[k]})
            out.append(d)
    return out


def build_set(docs):
    """The evaluation set: the owner's 15, the A and A' of the 300 and of the stratified 200, a matched negative each."""
    rel = owner_relation()
    sampled = {json.loads(l)["id"] for l in open(os.path.join(DT.CACHE, "sample.jsonl"), encoding="utf-8")}
    strat = {json.loads(l)["id"] for l in open(os.path.join(DT.CACHE, "pool", "stratified.jsonl"), encoding="utf-8")}
    chosen, seen = [], set()
    for d in docs:
        if d["id"] in rel:
            r = rel[d["id"]]
            chosen.append({**d, "group": "owner", "case": r["id"], "sent_with": r["sent_with"],
                           "relation": r.get("relation")})
            seen.add(d["id"])
    for d in docs:
        if d["id"] not in seen and d["class"] in ("A", "A'") and (d["id"] in sampled or d["id"] in strat):
            chosen.append({**d, "group": d["class"], "source": "sample" if d["id"] in sampled else "pool"})
            seen.add(d["id"])
    rng = random.Random(SEED)
    negs = [d for d in docs if d["year_in_text"] and d["cover_year"] is not None and d["cover_year"] != d["truth"]["year"]
            and d["id"] not in seen]
    rng.shuffle(negs)
    by_coll = collections.defaultdict(list)
    for d in negs:
        by_coll[d["collection"]].append(d)
    used = set()
    for c in [x for x in chosen if x["group"] in ("A", "A'")]:
        pool = [d for d in by_coll[c["collection"]] if d["id"] not in used] or [d for d in negs if d["id"] not in used]
        if pool:
            n = pool[0]
            used.add(n["id"])
            chosen.append({**n, "group": "neg", "matched": c["id"], "same_collection": n["collection"] == c["collection"]})
    return chosen


def load_set():
    return [json.loads(l) for l in open(SET, encoding="utf-8")]


def cmd_set(a):
    items = build_set(walk())
    os.makedirs(OUT, exist_ok=True)
    with open(SET, "w", encoding="utf-8") as fh:
        for d in items:
            fh.write(json.dumps(d, ensure_ascii=False) + "\n")
    c = collections.Counter(d["group"] for d in items)
    same = sum(d.get("same_collection", False) for d in items)
    print(f"{len(items)} candidates -> {SET}", dict(c), f"negatives from the same collection {same}")


def image_of(iid):
    return os.path.join(PAGES, iid + ".jpg")


def cmd_render(a):
    os.makedirs(PAGES, exist_ok=True)
    bad = 0
    for d in load_set():
        out = image_of(d["id"])
        if not os.path.exists(out):
            subprocess.run(["sips", "-s", "format", "jpeg", "-Z", str(MAX_SIDE), os.path.join(CS.CORPUS, d["first_page"]),
                            "--out", out], capture_output=True, check=False)
        bad += not os.path.exists(out)
    print(f"{len(load_set())} first pages, {bad} not rendered; {PAGES}")


# -------------------------------------------------------------------------------------------------------- prompts
def helper():
    """The compiled app prompt builder; rebuilt when OCRPrompt.swift or the helper is newer than the binary."""
    if not os.path.exists(HELPER) or max(os.path.getmtime(APP), os.path.getmtime(HELPER_SRC)) > os.path.getmtime(HELPER):
        os.makedirs(OUT, exist_ok=True)
        subprocess.run(["swiftc", "-swift-version", "6", "-warnings-as-errors", APP, HELPER_SRC, "-o", HELPER], check=True)
    return HELPER


def run_helper(mode, rows):
    inp = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    p = subprocess.run([helper(), mode], input=inp, capture_output=True, text=True, check=True)
    return {r["id"]: r for r in (json.loads(l) for l in p.stdout.splitlines() if l.strip())}


def marker_prompts(items):
    return {i: r["prompt"] for i, r in run_helper("build", [{"id": d["id"], "previous": d["cover_last_page"]}
                                                           for d in items]).items()}


def cover_excerpt(text):
    t = text.strip()
    if len(t) <= COVER_HEAD + COVER_TAIL:
        return t
    return t[:COVER_HEAD] + "\n[…]\n" + t[-COVER_TAIL:]


def relate_prompt(d):
    return ("You are checking two adjacent documents from a folder in a historical archive. Document 1 comes first in "
            "the folder; Document 2 follows it.\n\n"
            "Was Document 2 sent WITH Document 1, as its enclosure or attachment (a report, memo, list, clipping or "
            "someone else's letter that the writer of Document 1 sent along with it)? Answer false when Document 2 is "
            "simply the next item in the folder: a reply, a later letter, or an unrelated paper.\n\n"
            "Look at whether Document 1 announces something enclosed or attached (\"I enclose\", \"attached\", "
            "\"herewith\", \"Enc.\"); whether Document 2 is a separate item with its own heading or form; whether "
            "Document 1 names Document 2's title, subject or author; who wrote and who received each; how Document 1 "
            "closes and how Document 2 opens.\n\n"
            f"Document 1 (its start and its end):\n\"\"\"\n{cover_excerpt(d['cover_text'])}\n\"\"\"\n\n"
            f"Document 2 (its first page):\n\"\"\"\n{d['first_page_text'].strip()[:CAND_CHARS]}\n\"\"\"\n\n"
            "Reply with JSON only: {\"sent_with\": true or false, \"cue\": the words in either document that decide "
            "it, quoted exactly, or null, \"confidence\": your confidence that Document 2 was sent with Document 1, "
            "from 0 to 1}")


def parse_relate(raw):
    """{"sent_with": bool, "cue": str|None, "confidence": float|None} or None when the reply has no usable verdict."""
    s = re.sub(r"<think>.*?</think>", "", raw or "", flags=re.S)
    m = re.search(r"\{.*\}", s, flags=re.S)
    if not m:
        return None
    try:
        j = json.loads(m.group(0))
    except json.JSONDecodeError:
        # Qwen3.6-27B often quotes two cues unjoined ("cue": "Dear Michael:" and "Dear Dave,"), which is not JSON but
        # still carries a verdict; salvage the verdict and confidence rather than counting the reply as none.
        j = _salvage_relate(m.group(0))
        if j is None:
            return None
    v = j.get("sent_with")
    if isinstance(v, str):
        v = {"true": True, "false": False, "yes": True, "no": False}.get(v.strip().lower())
    if not isinstance(v, bool):
        return None
    c = j.get("confidence")
    try:
        c = min(1.0, max(0.0, float(c))) if c is not None else None
    except (TypeError, ValueError):
        c = None
    cue = j.get("cue") if isinstance(j.get("cue"), str) and j.get("cue").strip() else None
    return {"sent_with": v, "cue": cue, "confidence": c}


def _salvage_relate(s):
    """The fields of a malformed reply object, read one by one; None without a literal true/false verdict."""
    v = re.search(r'"sent_with"\s*:\s*(true|false)\b', s)
    if not v:
        return None
    c = re.search(r'"confidence"\s*:\s*([0-9]*\.?[0-9]+)', s)
    cue = re.search(r'"cue"\s*:\s*(.*?)\s*,\s*"confidence"', s, flags=re.S)
    cue = cue.group(1) if cue and cue.group(1) != "null" else None
    return {"sent_with": v.group(1) == "true", "cue": cue, "confidence": c.group(1) if c else None}


def _norm(s):
    return re.sub(r"\s+", " ", s or "").strip().lower()


def cue_found(cue, d):
    """Whether the quoted cue is in either document's text as sent (whitespace and case folded)."""
    if not cue:
        return None
    q = _norm(cue).strip("\"'“”‘’ .")
    return bool(q) and (q in _norm(cover_excerpt(d["cover_text"])) or q in _norm(d["first_page_text"][:CAND_CHARS]))


# ----------------------------------------------------------------------------------------------------- Mac arms
def answers_dir(label):
    return os.path.join(OUT, "answers-" + label)


def _mlx(key):
    import mlx.core as mx
    from mlx_vlm import load
    os.environ.setdefault("HF_HOME", os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/mlx-hf"))
    mx.set_cache_limit(256 * 2**20)
    return load(MODELS[key][0])


def _chat(processor, model, prompt, images):
    from mlx_vlm.prompt_utils import apply_chat_template
    try:  # Qwen3.5 thinks unless told not to; Qwen3-VL's template takes no such switch
        return apply_chat_template(processor, model.config, prompt, num_images=images, enable_thinking=False)
    except TypeError:
        return apply_chat_template(processor, model.config, prompt, num_images=images)


def _generate(model, processor, chat, image, max_tokens):
    from mlx_vlm import stream_generate
    start, text, last = time.time(), [], None
    kw = {"image": [image]} if image else {}
    for r in stream_generate(model, processor, chat, max_tokens=max_tokens, temperature=0.0, **kw):
        text.append(r.text)
        last = r
    return "".join(text), round(time.time() - start, 2), [getattr(last, "prompt_tokens", 0),
                                                         getattr(last, "generation_tokens", 0)]


def _todo(items, label, limit):
    out = answers_dir(label)
    os.makedirs(out, exist_ok=True)
    return out, [d for d in items if not os.path.exists(os.path.join(out, d["id"] + ".json"))][: limit or None]


def cmd_marker(a):
    assert MODELS[a.model][2] == "marker", a.model
    items = [d for d in load_set() if os.path.exists(image_of(d["id"]))]
    out, todo = _todo(items, a.model, a.limit)
    print(f"{a.model}: {len(todo)} pages", flush=True)
    if not todo:
        return
    prompts = marker_prompts(todo)
    model, processor = _mlx(a.model)
    for k, d in enumerate(todo, 1):
        raw, secs, toks = _generate(model, processor, _chat(processor, model, prompts[d["id"]], 1), image_of(d["id"]),
                                    MARKER_TOKENS)
        rec = {"id": d["id"], "raw": raw, "wall_s": secs, "tokens": toks}
        with open(os.path.join(out, d["id"] + ".json"), "w", encoding="utf-8") as fh:
            json.dump(rec, fh, ensure_ascii=False)
        print(f"[{k}/{len(todo)}] {d['id']} {secs}s {raw.splitlines()[0][:60] if raw else ''!r}", flush=True)


def cmd_relate(a):
    assert MODELS[a.model][2] == "relate", a.model
    out, todo = _todo(load_set(), a.model, a.limit)
    print(f"{a.model}: {len(todo)} pairs", flush=True)
    if not todo:
        return
    model, processor = _mlx(a.model)
    for k, d in enumerate(todo, 1):
        raw, secs, toks = _generate(model, processor, _chat(processor, model, relate_prompt(d), 0), None, RELATE_TOKENS)
        rec = {"id": d["id"], "raw": raw, "wall_s": secs, "tokens": toks}
        with open(os.path.join(out, d["id"] + ".json"), "w", encoding="utf-8") as fh:
            json.dump(rec, fh, ensure_ascii=False)
        print(f"[{k}/{len(todo)}] {d['id']} {secs}s {'ok' if parse_relate(raw) else 'unparsed'}", flush=True)


# ---------------------------------------------------------------------------------------------------- cluster
def cmd_export(a):
    os.makedirs(a.out, exist_ok=True)
    items = load_set()
    with open(os.path.join(a.out, "requests.jsonl"), "w", encoding="utf-8") as fh:
        for d in items:
            fh.write(json.dumps({"id": "relate|" + d["id"], "prompt": relate_prompt(d)}, ensure_ascii=False) + "\n")
    print(f"{len(items)} prompts -> {a.out}/requests.jsonl")


def cmd_import(a):
    out = answers_dir(a.label)
    os.makedirs(out, exist_ok=True)
    n = 0
    for line in open(a.answers, encoding="utf-8"):
        r = json.loads(line) if line.strip() else {}
        if "raw" not in r:
            continue
        iid = r["id"].split("|", 1)[-1]
        with open(os.path.join(out, iid + ".json"), "w", encoding="utf-8") as fh:
            json.dump({"id": iid, "raw": r["raw"], **{k: r[k] for k in ("seconds", "usage") if k in r}}, fh,
                      ensure_ascii=False)
        n += 1
    if a.summary:
        import shutil
        shutil.copyfile(a.summary, os.path.join(out, "summary.json"))
    print(f"{n} answers -> {out}")


def load_answers(label):
    d = answers_dir(label)
    if not os.path.isdir(d):
        return {}
    return {f[:-5]: json.load(open(os.path.join(d, f), encoding="utf-8")) for f in os.listdir(d)
            if f.endswith(".json") and f != "summary.json"}


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("set")
    sub.add_parser("render")
    for name, default in (("marker", "qwen3-vl-8b-mlx4"), ("relate", "date-2b-mlx8")):
        s = sub.add_parser(name)
        s.add_argument("--model", choices=sorted(MODELS), default=default)
        s.add_argument("--limit", type=int, default=0)
    e = sub.add_parser("export"); e.add_argument("--out", required=True)
    i = sub.add_parser("import"); i.add_argument("--answers", required=True); i.add_argument("--label", default=LABEL_27B)
    i.add_argument("--summary")
    sub.add_parser("score")
    a = ap.parse_args()
    {"set": cmd_set, "render": cmd_render, "marker": cmd_marker, "relate": cmd_relate, "export": cmd_export,
     "import": cmd_import, "score": lambda a: cmd_score(a)}[a.cmd](a)


# --------------------------------------------------------------------------------------------------------- scoring
def cue_rule(d, tail=600):
    t = d["cover_text"].strip()
    return bool(CUE.search(t[-tail:] if tail else t))


def arm_predictions(items):
    """{arm: {id: {"yes": bool|None, "score": float|None, "cue": str|None, "cue_found": bool|None, "secs": float|None,
    "cls": str|None}}} for every arm with answers; "yes" None = no usable reply."""
    arms = {name: {d["id"]: {"yes": cue_rule(d, tail), "score": float(cue_rule(d, tail)), "cue": None,
                             "cue_found": None, "secs": None, "cls": None} for d in items}
            for name, tail in (("cue", 600), ("cue-any", 0))}
    by_id = {d["id"]: d for d in items}
    for key, kind in [(k, v[2]) for k, v in MODELS.items()] + [(k, v[1]) for k, v in GATEWAY.items()]:
        ans = load_answers(key)
        if kind == "marker" and ans:
            parsed = run_helper("parse", [{"id": i, "raw": r["raw"]} for i, r in ans.items()])
            arms["marker:" + key] = {i: {"yes": parsed[i]["enclosure"], "score": float(parsed[i]["enclosure"]),
                                         "cue": None, "cue_found": None, "secs": r.get("wall_s"),
                                         "cls": parsed[i]["classification"]} for i, r in ans.items() if i in by_id}
    relate = [k for k, v in MODELS.items() if v[2] == "relate"] + [LABEL_27B] + [k for k, v in GATEWAY.items()
                                                                                 if v[1] == "relate"]
    for key in relate:
        ans = load_answers(key)
        if not ans:
            continue
        out = {}
        for i, r in ans.items():
            if i not in by_id:
                continue
            p = parse_relate(r["raw"])
            if p is None:
                out[i] = {"yes": None, "score": None, "cue": None, "cue_found": None, "secs": r.get("wall_s"), "cls": None}
                continue
            out[i] = {"yes": p["sent_with"], "score": relation_score(p), "cue": p["cue"],
                      "cue_found": cue_found(p["cue"], by_id[i]), "secs": r.get("wall_s", r.get("seconds")), "cls": None}
        arms["relate:" + key] = out
    return arms


def relation_score(p):
    """P(sent with) for ranking. The prompt asks for the confidence that Document 2 was sent with Document 1, but the
    2B answers false with 0.99, i.e. its confidence in the verdict; the reading that agrees with the verdict is taken
    (a confidence on the verdict's side of 0.5 is P(sent with), else confidence in the verdict)."""
    conf, yes = p["confidence"], p["sent_with"]
    if conf is None:
        return float(yes)
    return conf if (conf >= 0.5) == yes else 1.0 - conf


def wilson(k, n, z=1.96):
    if n == 0:
        return None
    p = k / n
    den = 1 + z * z / n
    mid = (p + z * z / (2 * n)) / den
    half = z * ((p * (1 - p) / n + z * z / (4 * n * n)) ** 0.5) / den
    return [round(max(0.0, mid - half), 3), round(min(1.0, mid + half), 3)]


def auc(pos, neg):
    """Mann-Whitney AUC of scores, ties counted half; None without both sides."""
    if not pos or not neg:
        return None
    s = sum((p > q) + 0.5 * (p == q) for p in pos for q in neg)
    return round(s / (len(pos) * len(neg)), 3)


def confusion(rows):
    c = collections.Counter()
    for truth, yes in rows:
        if yes is None:
            c["no reply"] += 1
        else:
            c[("T" if yes == truth else "F") + ("P" if yes else "N")] += 1
    return dict(c)


def score_arm(items, pred):
    by_group = collections.defaultdict(list)
    for d in items:
        by_group[d["group"]].append(d)
    out = {"n": sum(1 for d in items if d["id"] in pred)}
    # The owner's truth, all 15 and without the two bound-issue cases (date-truth-sets.md: their own relation).
    for name, keep in (("owner", lambda d: True), ("owner_no_bound", lambda d: d.get("relation") != "bound issue")):
        rows = [(d["sent_with"], pred[d["id"]]["yes"]) for d in by_group["owner"] if keep(d) and d["id"] in pred]
        c = confusion(rows)
        tp, fp, fn = c.get("TP", 0), c.get("FP", 0), c.get("FN", 0)
        out[name] = {"confusion": c, "precision": [tp, tp + fp], "recall": [tp, tp + fn]}
    # The structural proxy: firing rate per group; A and A' against the matched negatives.
    rate = {}
    for g in ("A", "A'", "neg", "owner"):
        got = [pred[d["id"]]["yes"] for d in by_group[g] if d["id"] in pred]
        k = sum(1 for y in got if y)
        rate[g] = {"fired": k, "of": len(got), "no_reply": sum(1 for y in got if y is None), "ci": wilson(k, len(got))}
    out["rate"] = rate
    pos = [pred[d["id"]]["score"] for g in ("A", "A'") for d in by_group[g] if d["id"] in pred and pred[d["id"]]["score"] is not None]
    neg = [pred[d["id"]]["score"] for d in by_group["neg"] if d["id"] in pred and pred[d["id"]]["score"] is not None]
    out["auc_proxy"] = auc(pos, neg)
    # Propagation: a proposal writes Sent With <cover's own date> and the cover's year as the Year tag.
    import date_traceable as TR
    prop = collections.Counter()
    for d in items:
        p = pred.get(d["id"])
        if not p or not p["yes"]:
            continue
        cy = TR.rule_pick(TR.candidates(d["cover_text"]))[0]
        key = "neg" if d["group"] == "neg" else "pos"
        prop[key + "_proposed"] += 1
        prop[key + "_cover_dated"] += cy is not None
        prop[key + "_year_right"] += cy == d["truth"]["year"]
    out["propagation"] = dict(prop)
    yes = [p for p in pred.values() if p["yes"]]
    if any(p["cue"] for p in yes):
        out["cue_quoted"] = [sum(1 for p in yes if p["cue"]), len(yes)]
        out["cue_found"] = [sum(1 for p in yes if p["cue_found"]), sum(1 for p in yes if p["cue"])]
    secs = [p["secs"] for p in pred.values() if p["secs"]]
    out["seconds_mean"] = round(sum(secs) / len(secs), 2) if secs else None
    if any(p["cls"] for p in pred.values()):
        out["classified"] = dict(collections.Counter(p["cls"] or "unparsed" for p in pred.values()))
    # The false positives, for inspection: does the cover announce anything at all?
    fps = [d for d in by_group["neg"] if pred.get(d["id"], {}).get("yes")]
    out["neg_fired_cover_cue"] = [sum(1 for d in fps if cue_rule(d)), len(fps)]
    return out


def arm_name(arm):
    kind, _, key = arm.partition(":")
    if kind == "cue":
        return "cue words in the cover's last 600 characters (rule)"
    if kind == "cue-any":
        return "cue words anywhere in the cover (rule)"
    label = (MODELS[key][1] if key in MODELS else GATEWAY[key][0] if key in GATEWAY
             else "Qwen3.6-27B, thinking off (Sherlock, one L40S)")
    return ("[enclosure] marker, app OCR prompt, " if kind == "marker" else "relation classifier, ") + label


def cmd_score(a):
    items = load_set()
    arms = arm_predictions(items)
    out = {"set": dict(collections.Counter(d["group"] for d in items)),
           "same_collection_negatives": sum(d.get("same_collection", False) for d in items),
           "arms": {arm: {"name": arm_name(arm), **score_arm(items, pred)} for arm, pred in arms.items()}}
    for arm, cost in gateway_cost().items():
        if arm in out["arms"]:
            out["arms"][arm]["cost"] = cost
    # Private: every proposal on a negative and every owner case, with the reply, for reading.
    by_id = {d["id"]: d for d in items}
    with open(os.path.join(OUT, "inspect.jsonl"), "w", encoding="utf-8") as fh:
        for arm, pred in arms.items():
            for i, p in pred.items():
                d = by_id[i]
                if (d["group"] == "neg" and p["yes"]) or d["group"] == "owner":
                    fh.write(json.dumps({"arm": arm, "id": i, "group": d["group"], "case": d.get("case"),
                                         "truth": d.get("sent_with"), "pred": p, "folder": d["folder"],
                                         "cover_tail": d["cover_text"].strip()[-400:],
                                         "head": d["first_page_text"].strip()[:400]}, ensure_ascii=False) + "\n")
    with open(RESULTS_JSON, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=1, ensure_ascii=False)
    write_md(out)
    print(f"-> {RESULTS} and {RESULTS_JSON}; private inspection {os.path.join(OUT, 'inspect.jsonl')}")


def gateway_cost():
    """{arm: {"calls", "usd", "per_1000"}} from the gateway ledger (date_enclosure_gateway.py): token usage at the list
    price taken as a ceiling, an estimate (the gateway returns no cost); failed calls are counted, retries included."""
    p = os.path.join(OUT, "gateway", "calls.jsonl")
    if not os.path.exists(p):
        return {}
    acc = collections.defaultdict(lambda: [0, 0.0])
    for line in open(p, encoding="utf-8"):
        r = json.loads(line)
        k = next(v[1] + ":" + key for key, v in GATEWAY.items() if v[1] == r["arm"])
        acc[k][0] += 1
        acc[k][1] += r.get("cost", 0)
    return {k: {"calls": n, "usd": round(c, 4), "per_1000": round(1000 * c / n, 2)} for k, (n, c) in acc.items()}


def frac(kn):
    k, n = kn
    return f"{k} of {n}" if n else "–"


def pc(k, n):
    return f"{100 * k / n:.1f}%" if n else "–"


FINDINGS = [   # written by hand from the scored runs of 2026-10-22 (Mac) and 2026-10-23 (Sherlock), one string per bullet
    "The marker, on the local route: Qwen3-VL 8B 4-bit, given the app's exact OCR prompt (compiled from "
    "`OCRPrompt.swift`), wrote `[enclosure]` on none of the 225 pages, including none of the owner's 3 confirmed "
    "enclosures. On the Mac route the app therefore proposes no relation at all: recall 0 of 3, precision undefined. "
    "It also called 53 of the 225 tag-rule document starts continuations (owner 8 of 15, A 19 of 60, A' 12 of 45, "
    "negatives 14 of 105), and the marker can only stand on a start; one of the 3 enclosures (a10) was among them.",
    "The trained 2B as a relation classifier answered false on all 225, with an AUC of 0.48 for its confidence on "
    "A and A' against the negatives: no signal. Its cue is often a sentence of the prompt rather than of either "
    "document. It was trained to date documents, not to relate them, so this measures the shipped model's reach, not "
    "what a small model could learn (R7's fine-tune on the A-D truth).",
    "Cue words are not a relation signal on this material. Read in the cover's last 600 characters they fire on "
    "1.7% of A, 6.7% of A' and 3.8% of the negatives; read anywhere in the cover, 13.3%, 13.3% and 23.8%, more on "
    "the negatives than on A and A' (AUC 0.45). None of the owner's 3 enclosures is announced in its cover's tail. "
    "This fits the owner's answers: most strict-class documents are not enclosures (date-truth-sets.md), so a "
    "cover that says \"I enclose\" is usually followed by something other than what it enclosed, or by nothing.",
    "Qwen3.6-27B (FP8, thinking off, one L40S on Sherlock, job 49088017; 225 pairs in 151 s at 32 at a time, after "
    "201 s to start the server) is the only free arm that proposes a relation, and it does so rarely: 2 of 60 A, 1 of "
    "45 A' and 1 of 105 negatives, AUC 0.67 for its confidence. On the owner's 15 it found 1 of the 3 enclosures "
    "(a22, quoting the enclosed document's own heading) and wrote one false Sent With (a25, a reply that discusses "
    "the draft it answers rather than enclosing it); precision 1 of 2 is a count, not a rate. Every yes quoted a "
    "cue, and the cue was in the documents on 5 of 6. Of its 5 proposals on A, A' and the owner's set, 4 covers "
    "print a year and all 4 are the owner's year; its one negative proposal would have written a wrong year. 43 of "
    "its 225 replies quoted two cues unjoined (not valid JSON); all were false verdicts, and `parse_relate` reads "
    "their verdict rather than counting them as no reply.",
    "The limit is the truth, not the arms: 3 owner-confirmed enclosures cannot give a precision for any arm that "
    "fires, and the structural classes are not relation truth. Still to run: the Gemini arm with images "
    "(W46.date-enclosure-paid). For the app now: on local routes the marker is inert, so `Sent With` is never "
    "proposed there, and nothing the free arms showed argues for proposing it by rule instead. A 27B relation pass "
    "is conservative enough not to hurt (one wrong Sent With among the 105 negatives and one among the owner's 12 noes) but finds too little to "
    "be worth a stage of its own on a laptop route, where it cannot run anyway.",
]


def write_md(out):
    s = out["set"]
    L = ["# Dating: the enclosure marker and a relation classifier (W46.date-enclosure)", "",
         "Written by `scripts/segbench/date_enclosure.py score`. The first measurement of the app's `[enclosure]` "
         "marker (10-gap-audit.md §5 item 15, B-dating.md §3). All arms $0: local models on this Mac and Qwen3.6-27B "
         "on Sherlock; no plan route (CLAUDE.md, \"Plan routes wait for the gateway\"); the Gemini arm is "
         "W46.date-enclosure-paid. The set and the replies stay private in the bench cache "
         "(`date-tagging/enclosure/`); this page carries counts only.", "",
         "## The set", "",
         f"{sum(s.values())} document starts of the agreed pool whose previous segment is a document (a relation never "
         "crosses a box or folder label):", "",
         f"- **owner** {s.get('owner', 0)}: the owner's relation truth (`date-truth-sets.md`), 3 sent with the previous "
         "document and 12 not. Two (a05, d10) are pages of one bound magazine issue, scored also without them.",
         f"- **A** {s.get('A', 0)} and **A'** {s.get(chr(65) + chr(39), 0)}: the strict and chained classes of the "
         "owner's 300 and of the pool's stratified 200, outside the owner's 15. Their year matches the document "
         "before, but the owner's answers refuted the strict class as covers (2 of 33), so a firing rate here is a "
         "structural proxy, not recall.",
         f"- **neg** {s.get('neg', 0)}: matched non-enclosure starts, one per A/A' candidate, documents printing their "
         f"own year where the owner gave the document before a different one; {out['same_collection_negatives']} "
         "from the same collection as their match. A proposal here writes a Sent With the owner did not use.", "",
         "## Against the owner's truth", "",
         "| arm | TP | FP | FN | TN | no reply | precision | recall | recall without the bound issues |",
         "|---|---|---|---|---|---|---|---|---|"]
    for arm, r in out["arms"].items():
        c = r["owner"]["confusion"]
        L.append(f"| {r['name']} | {c.get('TP', 0)} | {c.get('FP', 0)} | {c.get('FN', 0)} | {c.get('TN', 0)} | "
                 f"{c.get('no reply', 0)} | {frac(r['owner']['precision'])} | {frac(r['owner']['recall'])} | "
                 f"{frac(r['owner_no_bound']['recall'])} |")
    L += ["", "## The structural proxy: how often each arm proposes a relation", "",
          "Rates with Wilson 95% intervals. A good relation detector fires more on A and A' than on the matched "
          "negatives; how much more is the most this set can show without more owner truth.", "",
          "| arm | A | A' | neg | AUC, A and A' against neg | seconds a document |", "|---|---|---|---|---|---|"]
    for arm, r in out["arms"].items():
        cells = []
        for g in ("A", "A'", "neg"):
            x = r["rate"][g]
            ci = f", {100 * x['ci'][0]:.0f}-{100 * x['ci'][1]:.0f}" if x["ci"] else ""
            cells.append(f"{x['fired']} of {x['of']} ({pc(x['fired'], x['of'])}{ci})" + (f", {x['no_reply']} no reply" if x["no_reply"] else ""))
        L.append(f"| {r['name']} | " + " | ".join(cells) + f" | {r['auc_proxy'] if r['auc_proxy'] is not None else '–'} | "
                 f"{r['seconds_mean'] if r['seconds_mean'] is not None else '–'} |")
    L += ["", "## Propagation", "",
          "For each proposal, whether the cover prints a year (the rule pick of `date_traceable.py`) and whether that "
          "year, which the app would write as Sent With and as the Year tag with Date Uncertain, is the owner's year.", "",
          "| arm | proposals on A, A' and owner | cover dated | year right | proposals on neg | year right on neg | "
          "neg proposals whose cover announces anything |", "|---|---|---|---|---|---|---|"]
    for arm, r in out["arms"].items():
        p = r["propagation"]
        L.append(f"| {r['name']} | {p.get('pos_proposed', 0)} | {p.get('pos_cover_dated', 0)} | {p.get('pos_year_right', 0)} | "
                 f"{p.get('neg_proposed', 0)} | {p.get('neg_year_right', 0)} | {frac(r['neg_fired_cover_cue'])} |")
    extra = [(arm, r) for arm, r in out["arms"].items() if "cue_found" in r or "classified" in r]
    if extra:
        L += ["", "## Replies", ""]
        for arm, r in extra:
            if "classified" in r:
                L.append(f"- {r['name']}: line 1 classified as " + ", ".join(f"{k} {v}" for k, v in sorted(r["classified"].items())) + ".")
            if "cue_found" in r:
                L.append(f"- {r['name']}: a cue quoted on {frac(r['cue_quoted'])} yes replies; the quote found in the "
                         f"documents as sent on {frac(r['cue_found'])}.")
    costed = [(arm, r) for arm, r in out["arms"].items() if "cost" in r]
    if costed:
        L += ["", "## Cost", "",
              "From the gateway's token usage at Gemini 3.8 Flash's list price taken as a ceiling (the gateway returns no "
              "cost), so an estimate; every call counted, the pilot's included.", ""]
        L += [f"- {r['name']}: {r['cost']['calls']} calls, ${r['cost']['usd']:.2f}, about ${r['cost']['per_1000']:.2f} "
              "per 1,000 documents." for arm, r in costed]
    if FINDINGS:
        L += ["", "## Findings", ""] + [f"- {f}" for f in FINDINGS]
    with open(RESULTS, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L) + "\n")


if __name__ == "__main__":
    main()
