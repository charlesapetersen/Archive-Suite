#!/usr/bin/env python3
"""W46.ent-score-paid: Gemini 3.7 Flash with a dedicated entity prompt, on Apple Vision text, against W46.fix-ent-truth.

    TORCH_PY ent_score_paid.py pages                  # each page's JPEG original, upright (ocr_truth.extract)
    heavy-run.py run -- python3 ent_score_paid.py vision   # Apple Vision text per page (ocr.swift, the app's settings)
    python3 ent_score_paid.py run --arm tagging|entity3k|entity8k [--limit N] [--rerun]
    python3 ent_score_paid.py report                  # segbench-results/ent-score-paid.md and .json
    python3 ent_score_paid.py stamp                   # record prompt hash and settings on old replies

TORCH_PY is the shared environment's python (torch-env.sh; it holds numpy and Pillow, which extract needs).

Why (gap audit section 5 item 31; measurement audit ENT-3). W46.ent-score scored the app's tagging replies, which
were made from the corpus PDFs' ABBYY text and exist for 82 of the 138 correspondence documents. The app reads its
own OCR, Apple Vision on the photo, and the owner ruled ABBYY text out as an input (2026-10-30). So every arm here
reads Vision text of the JPEG originals (owner, 2026-10-22), on all 138, and the question is the one the ent-score
report left: does a dedicated entity prompt, or the whole text, close the 20-30 points the tagging prompt leaves?

Text. Each page of each document: its JPEG original from corpus_pairs' pairs.tsv (all 261 pages of the 138 pair),
EXIF orientation applied and turned to match the PDF page (ocr_truth.orient_like_pdf: 51 of the originals were
photographed sideways). A pair whose image correlates under PAIR_CORR and whose Vision text holds under PAIR_WORDS
of the ABBYY page's words is a wrong pair (a number match across folders) and the PDF page's own image is read
instead (ocr_truth.extract's no-original path). Then ocr.swift (.accurate, language correction, en-US: VisionClient.swift's defaults). The
document's text is its pages' texts joined by a blank line, as the ABBYY text was. Read only on both trees.

Arms, all Gemini 3.7 Flash through the Stanford gateway, text only, temperature 0, the gateway's default reasoning
(the app sends no thinking setting for tagging):
- tagging: the app's tagging prompt (date_tagging.build_prompt) with the Vision text in place of the ABBYY text, its
  first 3,000 characters as the app sends; the nearby documents' context block is the one the cached prompt carried
  (ABBYY snippets: the dating sample's context, kept fixed so only the document text changes). author_name,
  recipient_name and author_location are scored as sender, recipient and sending place, as in W46.ent-score.
- entity3k: the dedicated prompt (ENTITY_PROMPT) on the same first 3,000 characters, so the prompt's effect is
  read apart from the text's length.
- entity8k: the dedicated prompt on the first 8,000 characters (TEXT_CAP, what the truth readers saw), so the
  length's effect is read apart from the prompt's.
The dedicated prompt asks for lists of {name, quote}, the truth's own shape, so the evidence rule is measured
directly: precision of names whose quote is in the text, of names given with no quote, and of names whose quote is
not in the text. --rerun repeats entity8k on the first RERUN documents under a separate cache key, for a rerun floor.

Scoring is ent_truth.score_rows unchanged. Differences between arms are paired by document: a bootstrap (SEED,
BOOT draws) of the difference in ed2 F1 over the documents both arms answered; a gap whose 95% interval spans zero,
or that sits inside the rerun floor, is a tie.

The gateway is real money on a Stanford PTA: CAP bounds this item's spend, counted from the returned token usage at
gateway_gemini.PRICE (an estimate; the gateway's own figure per call is recorded beside it). Texts, images and
replies stay in the bench cache (the owner's material; the repo is public); the committed report has aggregates only.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import random
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ent_truth as ET  # noqa: E402

CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/ent-score-paid")
ENT_SCORE_JSON = os.path.join(HERE, "..", "..", "segbench-results", "ent-score.json")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "ent-score-paid.md")
ARMS = {"tagging": 3000, "entity3k": 3000, "entity8k": ET.TEXT_CAP}
CAP = 4.00                # the item's total, under the owner's $7 a piece of work
WORKERS = 4
RERUN = 40
SEED = 46
BOOT = 2000
# A JPEG pair is checked when its image correlates under PAIR_CORR with the PDF page (W46.truth-jpeg-upgrade measured
# true pairs at 0.69-0.98 and wrong ones at 0.16-0.48, and a cropped PDF lowers a true pair's figure), and rejected
# for the PDF's own image when Vision's text of it also holds under PAIR_WORDS of the ABBYY page's 4+ letter words.
PAIR_CORR = 0.5
PAIR_WORDS = 0.4

ENTITY_PROMPT = """You are extracting correspondence metadata from one document in a historical archive: a letter, \
memo or telegram. The text below was read from a photograph by machine OCR and may contain recognition errors.

---
{text}
---

Respond with ONLY a JSON object of this shape:
{{"sender": [{{"name": "...", "quote": "..."}}], "recipient": [{{"name": "...", "quote": "..."}}], \
"sending_place": [{{"name": "...", "quote": "..."}}]}}

Rules:
- "sender": the person who wrote or signed the document (a signature, a typed name under the closing, a "From:" \
line). If no person is named as its writer, the organisation it comes from. Typist's initials and enclosures are not \
senders.
- "recipient": the person or people it is addressed to (the inside address, a "To:" line, the salutation). List each \
addressee. Copies ("cc") are not recipients.
- "sending_place": where it was sent from (the letterhead's or the dateline's city), as "City, State" or \
"City, Country".
- "name": the normalised name, as "Given Surname" without titles (no Mr., Dr., Professor, President); correct \
obvious OCR errors in it.
- "quote": the name exactly as it is written in the OCR text above, recognition errors included, copied character \
for character; null when the name is not written in the text (for example only a role is written, such as \
"Dear Mr. President", and you know who held it).
- Use an empty list for a field the document does not let you fill. Use only this document."""


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def key(p):
    return hashlib.sha1(p.encode()).hexdigest()[:16]


def rows():
    """[(truth row, doc)] for the 138 correspondence documents."""
    docs = {d["id"]: d for d in ET.load_docs()}
    tr = [json.loads(x) for x in open(os.path.join(ET.CACHE, "truth.jsonl"), encoding="utf-8")]
    return [(r, docs[r["id"]]) for r in tr if r["is_correspondence"]]


def words4(s):
    return set(re.findall(r"[a-z]{4,}", ET.fold(s)))


def page_img(p):
    return os.path.join(CACHE, "pages", key(p) + ".jpg")


def page_txt(p):
    return os.path.join(CACHE, "vision", key(p) + ".txt")


def vision_text(d):
    return "\n\n".join(open(page_txt(p), encoding="utf-8").read().strip() for p in d["pages"])


# --- pages and Vision text ---------------------------------------------------------------------------

def cmd_pages(a):
    import corpus_pairs as CP
    import corpus_survey as CS
    import ocr_truth as OT
    from pathlib import Path
    pair = {pdf: j for pdf, j, _m, _t in CP.read_pairs()}
    os.makedirs(os.path.join(CACHE, "pages"), exist_ok=True)
    metas = {}
    mp = os.path.join(CACHE, "pages.json")
    if os.path.exists(mp):
        metas = json.load(open(mp))
    todo = [p for _r, d in rows() for p in d["pages"] if not os.path.exists(page_img(p))]
    missing = [p for p in todo if not pair.get(p)]
    if missing:
        raise SystemExit(f"{len(missing)} pages have no JPEG original: {missing[:3]}")

    def one(p):
        return p, OT.extract("original", Path(CP.JPEGS) / pair[p], Path(page_img(p)), Path(CS.CORPUS) / p)
    with ThreadPoolExecutor(4) as ex:
        for p, m in ex.map(one, todo):
            metas[p] = m
    # A pair can be wrong (a number match across folders): neither the image nor the words agree with the PDF.
    import date_tagging as DT
    for p, m in metas.items():
        if m.get("source") or (m.get("orient_corr") or 0) >= PAIR_CORR:
            continue
        a = words4(DT.page_text(p))
        if len(a) < 15:
            continue    # too little ABBYY text to judge by; the image check alone does not reject
        with open(os.path.join(CACHE, "tmp-ocr.tsv"), "w") as fh:
            fh.write(f"{page_img(p)}\t{os.path.join(CACHE, 'tmp-ocr.txt')}\n")
        if os.path.exists(os.path.join(CACHE, "tmp-ocr.txt")):
            os.remove(os.path.join(CACHE, "tmp-ocr.txt"))
        import data
        subprocess.run([str(data.build_ocr_tool()), os.path.join(CACHE, "tmp-ocr.tsv")], check=True,
                       capture_output=True)
        share = len(a & words4(open(os.path.join(CACHE, "tmp-ocr.txt"), encoding="utf-8").read())) / len(a)
        if share < PAIR_WORDS:
            m2 = OT.extract("pdf", Path(CS.CORPUS) / p, Path(page_img(p)))
            metas[p] = {**m2, "source": "pdf", "rejected_pair": pair[p], "orient_corr": m.get("orient_corr"),
                        "word_share": round(share, 3)}
            if os.path.exists(page_txt(p)):
                os.remove(page_txt(p))
        else:
            metas[p] = {**m, "source": "original", "word_share": round(share, 3)}
    json.dump(metas, open(mp, "w"), indent=1)
    print(f"{sum(m.get('source') == 'pdf' for m in metas.values())} pairs rejected for the PDF's own image")
    turned = collections.Counter(m.get("rotated") for m in metas.values())
    low = sum((m.get("orient_corr") or 0) < 0.5 for m in metas.values())
    print(f"{len(metas)} pages; turns {dict(turned)}; {low} with orientation correlation under 0.5")


def cmd_vision(a):
    import data
    binp = data.build_ocr_tool()
    if binp is None:
        raise SystemExit("ocr.swift did not compile")
    os.makedirs(os.path.join(CACHE, "vision"), exist_ok=True)
    jobs = os.path.join(CACHE, "vision-jobs.tsv")
    with open(jobs, "w") as fh:
        for _r, d in rows():
            for p in d["pages"]:
                fh.write(f"{page_img(p)}\t{page_txt(p)}\n")
    subprocess.run([str(binp), jobs], check=True)


# --- the gateway ------------------------------------------------------------------------------------

def ledger(cache=CACHE):
    f = os.path.join(cache, "calls.jsonl")
    return [json.loads(x) for x in open(f)] if os.path.exists(f) else []


def spent(cache=CACHE):
    import gateway_gemini as G
    return sum(G.charge(r) for r in ledger(cache))


def context_of(prompt):
    head = "Nearby documents for date estimation context (use only if this document's date is unclear):\n---\n"
    i = prompt.index(head) + len(head)
    c = prompt[i:prompt.index("\n---\n\nPlease respond", i)]
    return None if c == "(none)" else c


# The three rules of the tagging prompt as this item sent them; W46.ent-prompt-app replaced them in TagGenerator, so
# the tagging arm puts them back to stay the prompt its cached replies answered.
TAGGING_RULES_BEFORE = {
    "author_name": '- "author_name": author, sender, or writer name if identifiable, or null',
    "recipient_name": '- "recipient_name": recipient or addressee name if identifiable, or null',
    "author_location": '- "author_location": author\'s or sender\'s location if identifiable, or null',
}


def with_rules(prompt, rules):
    """The prompt with each named rule line replaced ({field: the whole line})."""
    lines = prompt.split("\n")
    for k, v in rules.items():
        i = next(j for j, x in enumerate(lines) if x.startswith(f'- "{k}":'))
        lines[i] = v
    return "\n".join(lines)


def tagging_prompt_before(text, context):
    import date_tagging as DT
    return with_rules(DT.build_prompt(text, context), TAGGING_RULES_BEFORE)


def prompt_for(arm, d):
    t = vision_text(d)
    if arm == "tagging":
        return tagging_prompt_before(t, context_of(d["prompt"]))
    return ENTITY_PROMPT.format(text=t[:ARMS[arm]])


def label_prompt(label, d):
    """The prompt a reply under label was sent: its arm's, and for the rerun one extra newline (cmd_run)."""
    if label == "entity8k-rerun":
        return prompt_for("entity8k", d) + "\n"
    return prompt_for(label, d)


def reply_path(arm, doc_id, cache=CACHE):
    return os.path.join(cache, "replies", arm, doc_id + ".json")


# The reply cache is keyed by label and document, so each reply records the SHA-256 of the prompt it answered, and a
# cached reply is returned only for that prompt: otherwise a prompt edit and a rerun would score the old replies
# (measurement review 2026-11-03, P6-5). Replies made before the hash was recorded carry one rebuilt from the known
# prompts by `stamp` ("prompt_hash": "reconstructed"); one whose prompt cannot be rebuilt is labelled "unknown" with
# no hash, and is refused, never re-called.
# The same holds for the request's settings, the model id, temperature and token cap ("request"): a cached reply is
# returned only for the settings it was made with, so a model change calls again rather than scoring the old model's
# replies (measurement review 2026-11-04, P7-7). Replies made before the settings were recorded get them from `stamp`
# ("request_settings": "reconstructed"), only where the ledger has the reply's own call under REQUEST_BEFORE's model.
def prompt_sha(prompt):
    return hashlib.sha256(prompt.encode("utf-8")).hexdigest()


def request_settings():
    """The settings every call sends (and every cached reply must have been made with)."""
    import gateway_gemini as G
    return {"model": G.MODEL, "temperature": 0, "max_tokens": G.MAX_TOKENS}


# What the 810 replies cached before the settings were recorded were sent with: W46.ent-score-paid (b958a87b,
# 705f32f7) and W46.ent-prompt-app (4cdbba41) all called with gateway_gemini's MODEL 'gemini-3.7-flash', temperature
# 0 and MAX_TOKENS 8192 (unchanged since 1baafbe7, 2026-10-23). The ledger records the model of each call; the
# temperature and token cap are the code's at those commits.
REQUEST_BEFORE = {"model": "gemini-3.7-flash", "temperature": 0, "max_tokens": 8192}


def cached(dest, prompt, request):
    """The cached reply at dest if it answered this prompt with these request settings; None if there is none;
    refuses any other."""
    if not os.path.exists(dest):
        return None
    with open(dest, encoding="utf-8") as fh:
        out = json.load(fh)
    m = out.get("meta", {})
    if not m.get("prompt_sha256"):
        raise SystemExit(f"{dest}: cached reply with no prompt hash ({m.get('prompt_hash', 'not stamped')}); "
                         "run `stamp`, or move it aside to call again")
    if m["prompt_sha256"] != prompt_sha(prompt):
        raise SystemExit(f"{dest}: cached reply answered a different prompt; move it aside to call again")
    if not m.get("request"):
        raise SystemExit(f"{dest}: cached reply with no recorded settings "
                         f"({m.get('request_settings', 'not stamped')}); run `stamp`, or move it aside to call again")
    if m["request"] != request:
        raise SystemExit(f"{dest}: cached reply was made with {m['request']}, not {request}; "
                         "move it aside to call again")
    return out


def check_replies(label, cache, prompt_of, request=None):
    """Refuses unless every reply under label answered prompt_of(doc) as it now stands, with the settings calls now
    send (a report scores no other)."""
    request = request or request_settings()
    for _r, d in rows():
        cached(reply_path(label, d["id"], cache), prompt_of(d), request)


def write_reply(dest, out):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest + ".tmp", "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    os.replace(dest + ".tmp", dest)


def stamp(labels, cache=CACHE):
    """Writes the rebuilt prompt hash into each reply under labels ({label: prompt_of(doc), or None where the prompt
    is not known}) that has none, or labels it "unknown"; and REQUEST_BEFORE as its settings into each reply that has
    none, where the ledger holds its own call (same document and send time) under that model, or labels it
    "unknown". A recorded hash or settings are compared, never changed. Returns {label: Counter of outcomes}."""
    got = {}
    calls = {(r["doc"], r["t"]): r for r in ledger(cache)}
    for label, prompt_of in labels.items():
        c = got[label] = collections.Counter()
        d_ = os.path.join(cache, "replies", label)
        docs = {d["id"]: d for _r, d in rows()}
        for f in sorted(os.listdir(d_)) if os.path.isdir(d_) else []:
            if not f.endswith(".json"):
                continue
            dest = os.path.join(d_, f)
            with open(dest, encoding="utf-8") as fh:
                out = json.load(fh)
            m = out.setdefault("meta", {})
            changed = False
            try:
                h = prompt_sha(prompt_of(docs[f[:-5]])) if prompt_of else None
            except (OSError, KeyError, ValueError, StopIteration):
                h = None
            if m.get("prompt_sha256"):
                c["had a hash, " + ("same" if m["prompt_sha256"] == h else "DIFFERENT")] += 1
            else:
                m["prompt_sha256"], m["prompt_hash"] = h, "reconstructed" if h else "unknown"
                c[m["prompt_hash"]] += 1
                changed = True
            if m.get("request"):
                c["had settings, " + ("same" if m["request"] == REQUEST_BEFORE else "DIFFERENT")] += 1
            else:
                r = calls.get((f[:-5], m.get("t")))
                ok = r is not None and r.get("http") == 200 and r.get("model") == REQUEST_BEFORE["model"]
                m["request"], m["request_settings"] = ((dict(REQUEST_BEFORE), "reconstructed") if ok
                                                       else (None, "unknown"))
                c["settings " + m["request_settings"]] += 1
                changed = True
            if changed:
                write_reply(dest, out)
    return got


def cmd_stamp(a):
    print(json.dumps(stamp({label: (lambda d, L=label: label_prompt(L, d)) for label in replies_labels(CACHE)}),
                     indent=1))


def replies_labels(cache):
    d = os.path.join(cache, "replies")
    return sorted(os.listdir(d)) if os.path.isdir(d) else []


def call(arm, doc_id, prompt, cache=CACHE, cap=CAP):
    """One call, cached by destination, prompt hash and settings; the ledger line is written before the reply is
    used."""
    import gateway_gemini as G
    dest = reply_path(arm, doc_id, cache)
    request = request_settings()
    hit = cached(dest, prompt, request)
    if hit is not None:
        return hit
    worst = G.cost({"prompt_tokens": 6000, "completion_tokens": G.MAX_TOKENS})
    if spent(cache) + worst > cap:
        raise SystemExit(f"cap: ${spent(cache):.4f} spent of ${cap}")
    b = {**request, "messages": [{"role": "user", "content": prompt}]}
    t = time.time()
    for attempt in range(3):
        r = G.request("/chat/completions", b)
        if r.status_code in (429, 500, 502, 503, 504) and attempt < 2:
            time.sleep(10 * (attempt + 1)); continue
        break
    got = r.json() if r.headers.get("content-type", "").startswith("application/json") else {"raw": r.text[:2000]}
    usage = got.get("usage") or {}
    rec = {"arm": arm, "doc": doc_id, "http": r.status_code, "t": t, "wall_s": round(time.time() - t, 3),
           "model": got.get("model") or G.MODEL, "usage": usage, "cost": round(G.cost(usage), 6),
           "prompt_sha256": prompt_sha(prompt), "prompt_hash": "sent", "request": request, "request_settings": "sent"}
    rec = G.with_gateway_cost(rec, r)
    with open(os.path.join(cache, "calls.jsonl"), "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    choice = (got.get("choices") or [{}])[0]
    out = {"meta": {**rec, "finish": choice.get("finish_reason")},
           "raw": (choice.get("message") or {}).get("content") if r.status_code == 200 else None}
    if r.status_code == 200:
        write_reply(dest, out)
    else:
        print(doc_id, r.status_code, json.dumps(got)[:300])
    return out


def cmd_run(a):
    rs = rows()[: a.limit or None]
    arm = a.arm
    # The gateway answers a byte-identical request from a cache (the pilot's repeats came back in 0.3 s with the
    # same reply), so the rerun's prompt ends in one extra newline: the smallest change that makes it a new call.
    tail = ""
    if a.rerun:
        if arm != "entity8k":
            raise SystemExit("--rerun repeats entity8k only")
        rs, label, tail = rows()[:RERUN], "entity8k-rerun", "\n"
    else:
        label = arm
    with ThreadPoolExecutor(WORKERS) as ex:
        list(ex.map(lambda rd: call(label, rd[1]["id"], prompt_for(arm, rd[1]) + tail), rs))
    n = sum(os.path.exists(reply_path(label, d["id"])) for _r, d in rs)
    print(f"{label}: {n}/{len(rs)} answered; ${spent():.4f} spent of ${CAP}")


# --- scoring ----------------------------------------------------------------------------------------

def parse(raw):
    if not raw:
        return None
    s = raw.strip()
    i, j = s.find("{"), s.rfind("}")
    try:
        js = json.loads(s[i:j + 1]) if 0 <= i <= j else None
    except ValueError:
        return None
    return js if isinstance(js, dict) else None


def preds(label, cache=CACHE):
    """{doc_id: pred} for the answered and parsed documents; unparsed ones counted apart. A tagging reply's name list
    (an array where the prompt asks for one string) is joined with "; ", as TagGenerator.names joins it."""
    import ent_score as ES
    out, bad = {}, 0
    joined = lambda v: "; ".join(x for x in v if isinstance(x, str) and x.strip()) or None if isinstance(v, list) else v  # noqa: E731
    for r, d in rows():
        p = reply_path(label, d["id"], cache)
        if not os.path.exists(p):
            continue
        js = parse(json.load(open(p)).get("raw"))
        if js is None:
            bad += 1; continue
        if label.startswith("tagging"):
            out[r["id"]] = {f: ES.split_names(joined(js.get(k))) if f != "sending_place" else joined(js.get(k))
                            for f, k in ES.REPLY_FIELD.items()}
        else:
            out[r["id"]] = {f: js.get(f) for f in ET.FIELDS}
    return out, bad


def doc_counts(r, pred, f):
    """tp, fp, fn at ed2 for one document and field, exactly as score_rows counts them."""
    s = ET.score_rows([{"truth": r, "pred": pred or {}, "text": ""}], levels=("ed2",))[f]["ed2"]
    return s["tp"], s["fp"], s["fn"]


def f1(c):
    tp, fp, fn = c
    return 2 * tp / (2 * tp + fp + fn) if tp + fp + fn else None


def paired(pa, pb, ids, truth, f):
    """The difference in ed2 F1 (b minus a) over ids, with a document bootstrap's 95% interval."""
    ca = [doc_counts(truth[i], pa[i], f) for i in ids]
    cb = [doc_counts(truth[i], pb[i], f) for i in ids]
    tot = lambda cs: tuple(map(sum, zip(*cs))) if cs else (0, 0, 0)  # noqa: E731
    d = (f1(tot(cb)) or 0) - (f1(tot(ca)) or 0)
    rng = random.Random(SEED)
    ds = []
    for _ in range(BOOT):
        k = [rng.randrange(len(ids)) for _ in ids]
        ds.append((f1(tot([cb[j] for j in k])) or 0) - (f1(tot([ca[j] for j in k])) or 0))
    ds.sort()
    return {"n": len(ids), "diff": d, "lo": ds[int(0.025 * BOOT)], "hi": ds[int(0.975 * BOOT) - 1]}


def evidence(pr, truth, texts, cap):
    """Precision (ed2, inferred-truth matches set aside) of names by their quote: in the text, none, not in it."""
    out = {}
    for f in ET.FIELDS:
        g = collections.defaultdict(lambda: [0, 0])     # group -> [right, wrong]
        for i, p in pr.items():
            t = ET.squash(texts[i][:cap])
            tr = truth[i].get(f) or []
            for e in ET.ent_names(p.get(f)):
                q = e.get("quote")
                grp = "no quote" if not q else ("quote in text" if ET.squash(q) in t else "quote not in text")
                if any(ET.match(e["name"], x["name"], "ed2", x.get("alternates", ())) for x in tr
                       if x.get("class") == "named"):
                    g[grp][0] += 1
                elif any(ET.match(e["name"], x["name"], "ed2", x.get("alternates", ())) for x in tr):
                    continue
                else:
                    g[grp][1] += 1
        out[f] = {k: v for k, v in g.items()}
    return out


def by_city(pr, truth):
    """The sending place cut to its city on both sides (ent_score.city), as W46.ent-score's place_city figures: the
    full string counts "Springfield, IL" against "Springfield, Illinois" as a miss, a format and not a reading."""
    import ent_score as ES
    pc = {i: {"sending_place": [ES.city(n["name"]) for n in ET.ent_names((p or {}).get("sending_place"))
                                if n.get("name")]} for i, p in pr.items()}
    tc = {i: {**r, "sending_place": [{**e, "name": ES.city(e["name"]),
                                      "alternates": [ES.city(x) for x in e.get("alternates", ())]}
                                     for e in r["sending_place"]]} for i, r in truth.items()}
    return pc, tc


def cmd_report(a):
    import ent_score as ES
    import gateway_gemini as G
    rs = rows()
    truth = {r["id"]: r for r, _d in rs}
    texts = {d["id"]: vision_text(d) for _r, d in rs}
    abbyy = {d["id"]: d["text"] for _r, d in rs}
    sample = {r["id"] for r, _d in rs if r["set"] == "sample88"}
    P, bad = {}, {}
    for arm in list(ARMS) + ["entity8k-rerun"]:
        check_replies(arm, CACHE, lambda d, L=arm: label_prompt(L, d))
        P[arm], bad[arm] = preds(arm)
    s = {"docs": len(rs), "sample_docs": len(sample), "unparsed": bad,
         "answered": {k: len(v) for k, v in P.items()}, "scores": {}, "scores_82": {}, "paired": {}, "evidence": {}}
    for arm in ARMS:
        cap = ARMS[arm]
        sc = [{"truth": truth[i], "pred": p, "text": texts[i][:cap]} for i, p in P[arm].items()]
        s["scores"][arm] = ET.score_rows(sc)
        s["scores_82"][arm] = ET.score_rows([x for x in sc if x["truth"]["id"] in sample])
        if arm != "tagging":
            s["evidence"][arm] = evidence(P[arm], truth, texts, cap)
    # the W46.ent-score reply on ABBYY text (Gemini 3.8 Flash, the app's default then), on its 82
    prior = ES.reply_preds()["gemini-3.8-flash"]
    prior = {i: p for i, p in prior.items() if p is not None}
    s["scores_82"]["gemini-3.8-flash on ABBYY (W46.ent-score)"] = ET.score_rows(
        [{"truth": truth[i], "pred": p, "text": ES.seen_text(dict(next(d for _r, d in rs if d["id"] == i)))}
         for i, p in prior.items()])
    pairs = [("tagging", "entity3k", "the prompt, at 3,000 characters"),
             ("entity3k", "entity8k", "the length, dedicated prompt"),
             ("tagging", "entity8k", "prompt and length together")]
    for a_, b_, what in pairs:
        ids = sorted(set(P[a_]) & set(P[b_]))
        s["paired"][f"{b_} vs {a_}"] = {"what": what, **{f: paired(P[a_], P[b_], ids, truth, f) for f in ET.FIELDS}}
    ids = sorted(set(P["entity8k"]) & set(P["entity8k-rerun"]))
    if ids:
        s["paired"]["rerun floor: entity8k again"] = {"what": "the same calls repeated",
                                                     **{f: paired(P["entity8k"], P["entity8k-rerun"], ids, truth, f)
                                                        for f in ET.FIELDS}}
    ids = sorted(set(P["tagging"]) & set(prior))
    s["paired"]["tagging on Vision (3.7) vs the 3.8 reply on ABBYY"] = {
        "what": "text source and model version", **{f: paired(prior, P["tagging"], ids, truth, f) for f in ET.FIELDS}}
    # the sending place by its city: F1 per arm on the 138 (and the 82 beside the 3.8 reply), and the paired diffs
    s["place_city"], s["paired_city"] = {}, {}
    for arm in list(ARMS) + ["prior"]:
        pr = prior if arm == "prior" else P[arm]
        pc, tc = by_city(pr, truth)
        c = [doc_counts(tc[i], pc[i], "sending_place") for i in pc]
        c82 = [doc_counts(tc[i], pc[i], "sending_place") for i in pc if i in sample]
        tot = lambda cs: tuple(map(sum, zip(*cs))) if cs else (0, 0, 0)  # noqa: E731
        s["place_city"][arm] = {"138": None if arm == "prior" else f1(tot(c)) or 0, "82": f1(tot(c82)) or 0}
    for a_, b_ in [("tagging", "entity3k"), ("entity3k", "entity8k"), ("tagging", "entity8k"),
                   ("entity8k", "entity8k-rerun"), ("prior", "tagging")]:
        pa, ta = by_city(prior if a_ == "prior" else P[a_], truth)
        pb, _tb = by_city(P[b_], truth)
        ids = sorted(set(pa) & set(pb))
        s["paired_city"][f"{b_} vs {a_}"] = paired(pa, pb, ids, ta, "sending_place")
    # how much of the truth is written in each text at all
    s["truth_in_text"] = {}
    for name, src, cap in (("Vision, first 3,000", texts, 3000), ("Vision, first 8,000", texts, ET.TEXT_CAP),
                           ("ABBYY, first 3,000", abbyy, 3000), ("ABBYY, first 8,000", abbyy, ET.TEXT_CAP)):
        c = {}
        for f in ET.FIELDS:
            named = [(i, e) for i in truth for e in truth[i][f] if e["class"] == "named"]
            c[f] = [sum(ET.in_text(ES.city(e["name"]) if f == "sending_place" else e["name"], src[i][:cap])
                        for i, e in named), len(named)]
        s["truth_in_text"][name] = c
    s["chars"] = {"vision_median": sorted(len(t) for t in texts.values())[len(texts) // 2],
                  "abbyy_median": sorted(len(t) for t in abbyy.values())[len(abbyy) // 2],
                  "vision_over_3000": sum(len(t) > 3000 for t in texts.values())}
    led = ledger()
    s["calls"] = {"n": len(led), "ok": sum(r["http"] == 200 for r in led), "spent": round(spent(), 4),
                  "note": G.billed_note(led)}
    pm = json.load(open(os.path.join(CACHE, "pages.json")))
    s["pages"] = {"n": len(pm), "turned": sum(bool(m.get("rotated")) for m in pm.values()),
                  "low_corr": sum((m.get("orient_corr") or 0) < 0.5 for m in pm.values())}
    json.dump(s, open(RESULTS[:-3] + ".json", "w"), indent=1)
    open(RESULTS, "w").write(report(s))
    print(RESULTS)


def report(s):
    import ent_score as ES
    L = ["# Gemini with a dedicated entity prompt, on Apple Vision text (W46.ent-score-paid)", "",
         "Generated by `scripts/segbench/ent_score_paid.py report`; method in its header. Truth: W46.fix-ent-truth's "
         f"{s['docs']} correspondence documents, scored with its `score_rows` (ed2 = edit distance 2 on the normalised "
         "name). Every arm is Gemini 3.7 Flash through the Stanford gateway, text only, reading Apple Vision's text of "
         f"the JPEG originals ({s['pages']['n']} pages, {s['pages']['turned']} turned upright to match the PDF page).", ""]
    L += ["## The three arms on all 138", "",
          f"Answered / unparsed: " + ", ".join(f"{k} {s['answered'][k]}/{s['unparsed'][k]}" for k in ARMS) + ".", ""]
    L += ES.score_table(s["scores"])
    L += ["", "## On the 82 with a W46.ent-score reply, beside that reply (Gemini 3.8 Flash on ABBYY text)", ""]
    L += ES.score_table(s["scores_82"])
    L += ["", "## Paired differences in ed2 F1 (documents both arms answered; 95% bootstrap interval)", "",
          "| comparison | what changes | n | sender | recipient | sending place |", "|---|---|---|---|---|---|"]
    for k, v in s["paired"].items():
        c = [f"{v[f]['diff']:+.3f} [{v[f]['lo']:+.3f}, {v[f]['hi']:+.3f}]" for f in ET.FIELDS]
        L.append(f"| {k} | {v['what']} | {v['sender']['n']} | " + " | ".join(c) + " |")
    L += ["", "## The sending place by its city", "",
          "Both sides cut to the city (`ent_score.city`), as W46.ent-score's place figures: the full string above counts "
          "\"Springfield, IL\" against \"Springfield, Illinois\" as a miss.", "",
          "| extractor | ed2 F1, 138 | ed2 F1, 82 |", "|---|---|---|"]
    for k, v in s["place_city"].items():
        name = "gemini-3.8-flash on ABBYY (W46.ent-score)" if k == "prior" else k
        L.append(f"| {name} | " + (f"{v['138']:.3f}" if v["138"] is not None else "-") + f" | {v['82']:.3f} |")
    L += ["", "| comparison | n | city ed2 F1 difference [95%] |", "|---|---|---|"]
    for k, v in s["paired_city"].items():
        k = k.replace("prior", "the 3.8 reply on ABBYY")
        L.append(f"| {k} | {v['n']} | {v['diff']:+.3f} [{v['lo']:+.3f}, {v['hi']:+.3f}] |")
    L += ["", "## The evidence rule: precision (ed2) of the dedicated prompt's names by their quote", "",
          "A name matching a role- or correspondence-inferred truth entity is set aside, as in the scorer.", "",
          "| arm | field | quote in text | no quote | quote not in text |", "|---|---|---|---|---|"]
    for arm, ev in s["evidence"].items():
        for f in ET.FIELDS:
            cell = []
            for g in ("quote in text", "no quote", "quote not in text"):
                r, w = ev[f].get(g, [0, 0])
                cell.append(f"{r}/{r + w}" + (f" ({r / (r + w):.2f})" if r + w else ""))
            L.append(f"| {arm} | {f} | " + " | ".join(cell) + " |")
    L += ["", "## How much of the truth each text carries", "",
          "Named truth entities whose every 3+ letter word is in the text (a place by its city): the ceiling for a "
          "name the model is to read rather than infer.", "",
          "| text | sender | recipient | sending place |", "|---|---|---|---|"]
    for k, c in s["truth_in_text"].items():
        L.append(f"| {k} | " + " | ".join(f"{a}/{b}" for a, b in (c[f] for f in ET.FIELDS)) + " |")
    L += ["", f"Median characters a document: Vision {s['chars']['vision_median']}, ABBYY {s['chars']['abbyy_median']}; "
          f"{s['chars']['vision_over_3000']} Vision texts run past 3,000.", "",
          f"Spend: ${s['calls']['spent']:.2f} estimated over {s['calls']['n']} gateway calls ({s['calls']['ok']} "
          f"answered). {s['calls']['note']}", ""]
    L += READING
    return "\n".join(L) + "\n"


READING = """## Reading

- **Recipients: the dedicated prompt is better, and it is the prompt, not the length.** ed2 F1 0.72 with the app's
  tagging prompt, 0.87 with the dedicated one on the same 3,000 characters (+0.15, interval +0.01 to +0.31); 8,000
  characters add nothing (+0.01). The gain is in listing every addressee: the dedicated arms name 168 recipients
  to the tagging arm's 124, and the multi-addressee letters are where the tagging prompt's single `recipient_name`
  loses them. On the rerun the recipients did not move at all.
- **Sending place: a format effect only.** On the full string the dedicated prompt gains 0.23, but cut to the city
  on both sides, as W46.ent-score scored it, every arm is 0.90-0.91 and the differences are ties (+0.01, interval
  -0.02 to +0.05). The full-string gap is "City, State" against the tagging reply's own forms; the rerun alone moved
  it -0.16 ("Springfield, IL" against "Springfield, Illinois"), all one way (interval -0.338 to 0.000: a drift between
  identical calls, as the sender's and the city's are).
- **Senders: no prompt gain, and a cost the dedicated prompt's own rule causes.** 0.71 tagging, 0.67 dedicated at
  3,000 (-0.03, a tie), 0.76 at 8,000. The dedicated prompt nulls far less (9 or 19 of 129 against 31) but is wrong
  on more documents (27-28 against 16): 15 of entity8k's 27 wrong senders are the organisation fallback its rule asks for
  (an office or institution where the truth has the signer), the rest a surname or first name alone where the truth has the full name, or a garbled
  signature. Length helps the dedicated prompt's sender (+0.09, interval +0.02 to +0.17; 12 more named senders sit
  past 3,000 in the Vision text), but the sender rerun of the same calls moved +0.04 on 40 documents, all one way
  (interval 0.000 to +0.115: a drift between identical calls, not noise around zero), so read it as a likely small
  gain, not a measured size.
- **Vision text against ABBYY: no loss.** The tagging prompt on Vision text with Gemini 3.7 is level with
  W46.ent-score's Gemini 3.8 reply on ABBYY on the 82 (sender +0.03, recipient +0.01, city +0.00, all ties), and Vision
  text holds more of the truth's names (sender 78 against 64 of 138 in the first 3,000, recipient 146 against 112).
- **The evidence rule is satisfiable.** Every quoted name the dedicated prompt gave was found verbatim in the text
  it read (whitespace folded): 364 at 8,000 characters and 347 at 3,000, 711 in both arms; 2 in each arm came without
  a quote. A quote check in the app would therefore pass the model's own reads and catch only inferred names, which
  this prompt almost never offers.

What it means for the app: the tagging prompt's recipient field should ask for every addressee, as a list, and its
place for "City, State"; the sender should stay a person, null rather than the letterhead's organisation. Filed as
W46.ent-prompt-app, which has to check the dates the same prompt returns do not move. No route or default changes on
the sending place, and the 8,000-character window is not worth its tokens for the tagging call on this evidence.

## Measurement card

- **Truth:** W46.fix-ent-truth's 138 correspondence documents, drafted blind by GPT 5.6 Luna and Claude Sonnet 5
  with the OCR text and the first and last page images, and ruled by Claude Sonnet 5 where they differed. It is
  model truth: the owner has not checked it (the building session spot-checked 4 rows against the images). No
  Gemini drafted or ruled, so no scored route is a drafter or a relative of one.
- **Selection:** 82 of the date-tagging sample's 88 correspondence documents plus 56 additions stratified by text
  cues (handwritten, role-addressed, unsigned, no dateline) read from the ABBYY text, so the additions were chosen
  by the ABBYY text, though not by any route tested here. The 82 are the documents W46.ent-score had replies for.
- **Comparison:** the same Vision text of the same JPEG originals (3 wrong pairs read from the PDF page image
  instead), the same model, temperature 0 and gateway settings in every arm; tagging and entity3k see the same
  3,000 characters. The 3.8 reply on ABBYY differs in text source and model version together, and is reported only
  as that pair.
- **Noise:** n 138 (82, 40 for the floor); paired document bootstrap, 2,000 draws, 95% intervals. Rerun floor
  (entity8k repeated, one changed newline to pass the gateway's cache): recipient 0.00; sender +0.04 (0.000 to
  +0.115), city -0.03 (-0.111 to 0.000) and full-string place -0.16 (-0.338 to 0.000) are each one-signed: a drift
  between identical calls, not a floor around zero. A gap inside its interval or the floor is a tie.
- **Scope:** text-only, one model (Gemini 3.7 Flash), one prompt wording per arm; it does not settle a multimodal
  read, a local model on the dedicated prompt, or how the dates move if the tagging prompt changes (W46.ent-prompt-app).
  The plan-route Claude arm planned for this item is dropped, not moved (owner, 2026-10-30).
""".splitlines()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("pages")
    sub.add_parser("vision")
    r = sub.add_parser("run")
    r.add_argument("--arm", choices=list(ARMS), required=True)
    r.add_argument("--limit", type=int)
    r.add_argument("--rerun", action="store_true")
    sub.add_parser("report")
    sub.add_parser("stamp")
    a = ap.parse_args()
    {"pages": cmd_pages, "vision": cmd_vision, "run": cmd_run, "report": cmd_report, "stamp": cmd_stamp}[a.cmd](a)


if __name__ == "__main__":
    main()
