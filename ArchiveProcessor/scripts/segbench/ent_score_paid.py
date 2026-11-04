#!/usr/bin/env python3
"""W46.ent-score-paid: Gemini 3.7 Flash with a dedicated entity prompt, on Apple Vision text, against W46.fix-ent-truth.

    TORCH_PY ent_score_paid.py pages                  # each page's JPEG original, upright (ocr_truth.extract)
    heavy-run.py run -- python3 ent_score_paid.py vision   # Apple Vision text per page (ocr.swift, the app's settings)
    python3 ent_score_paid.py run --arm tagging|entity3k|entity8k [--limit N] [--rerun]
    python3 ent_score_paid.py report                  # segbench-results/ent-score-paid.md and .json

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

def ledger():
    f = os.path.join(CACHE, "calls.jsonl")
    return [json.loads(x) for x in open(f)] if os.path.exists(f) else []


def spent():
    import gateway_gemini as G
    return sum(G.charge(r) for r in ledger())


def context_of(prompt):
    head = "Nearby documents for date estimation context (use only if this document's date is unclear):\n---\n"
    i = prompt.index(head) + len(head)
    c = prompt[i:prompt.index("\n---\n\nPlease respond", i)]
    return None if c == "(none)" else c


def prompt_for(arm, d):
    import date_tagging as DT
    t = vision_text(d)
    if arm == "tagging":
        return DT.build_prompt(t, context_of(d["prompt"]))
    return ENTITY_PROMPT.format(text=t[:ARMS[arm]])


def reply_path(arm, doc_id):
    return os.path.join(CACHE, "replies", arm, doc_id + ".json")


def call(arm, doc_id, prompt):
    """One call, cached by destination; the ledger line is written before the reply is used."""
    import gateway_gemini as G
    dest = reply_path(arm, doc_id)
    if os.path.exists(dest):
        return json.load(open(dest))
    worst = G.cost({"prompt_tokens": 6000, "completion_tokens": G.MAX_TOKENS})
    if spent() + worst > CAP:
        raise SystemExit(f"cap: ${spent():.4f} spent of ${CAP}")
    b = {"model": G.MODEL, "temperature": 0, "max_tokens": G.MAX_TOKENS,
         "messages": [{"role": "user", "content": prompt}]}
    t = time.time()
    for attempt in range(3):
        r = G.request("/chat/completions", b)
        if r.status_code in (429, 500, 502, 503, 504) and attempt < 2:
            time.sleep(10 * (attempt + 1)); continue
        break
    got = r.json() if r.headers.get("content-type", "").startswith("application/json") else {"raw": r.text[:2000]}
    usage = got.get("usage") or {}
    rec = {"arm": arm, "doc": doc_id, "http": r.status_code, "t": t, "wall_s": round(time.time() - t, 3),
           "model": got.get("model") or G.MODEL, "usage": usage, "cost": round(G.cost(usage), 6)}
    rec = G.with_gateway_cost(rec, r)
    with open(os.path.join(CACHE, "calls.jsonl"), "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    choice = (got.get("choices") or [{}])[0]
    out = {"meta": {**rec, "finish": choice.get("finish_reason")},
           "raw": (choice.get("message") or {}).get("content") if r.status_code == 200 else None}
    if r.status_code == 200:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        json.dump(out, open(dest, "w"), ensure_ascii=False, indent=1)
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


def preds(label):
    """{doc_id: pred} for the answered and parsed documents; unparsed ones counted apart."""
    import ent_score as ES
    out, bad = {}, 0
    for r, d in rows():
        p = reply_path(label, d["id"])
        if not os.path.exists(p):
            continue
        js = parse(json.load(open(p)).get("raw"))
        if js is None:
            bad += 1; continue
        if label == "tagging":
            out[r["id"]] = {f: ES.split_names(js.get(k)) if f != "sending_place" else js.get(k)
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


READING = []   # filled in by hand once the figures are in (the report's reading and measurement card)


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
    a = ap.parse_args()
    {"pages": cmd_pages, "vision": cmd_vision, "run": cmd_run, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    main()
