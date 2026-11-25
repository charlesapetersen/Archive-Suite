#!/usr/bin/env python3
"""W49.proc-metadata-consolidate-sherlock-prep: one structured metadata call in place of the app's separate ones, as a
frozen Sherlock pack for Qwen3.6 27B over the item-field set's Vision text.

    python3 metadata_unified.py check     # build every prompt, print sizes and the prior check; writes nothing
    python3 metadata_unified.py pack      # the frozen pack (sherlock/metadata-unified-27b/), in the hand-over folder
    python3 metadata_unified.py collect   # the pack's returned answers -> CACHE/replies/<CLUSTER>/, each parsed
    heavy-run.py run -- <lab venv>/bin/python metadata_unified.py mac-pilot [--limit N]   # the schema on this Mac

<lab venv> is ~/.local/share/visionocr-ocrlab/venv (mlx-vlm). mac-pilot answers N prompts, the three parts in turn, with Qwen3-VL 8B
(MLX 4-bit, text only, the settings above) only to show the reply parses and its quotes are found; it is not an arm.

Why. After OCR the app makes four calls on one document (prompts.md §5, §8, §9, §10): tagging (date, subjects, format,
names, places, publication; 3,000 characters and 300 of three neighbours), the dating trace (3,000 characters, 600 of
up to six neighbours, a quote for the year), entities (3,000 characters, sender, recipients and sending place with
quotes, correspondence only) and item fields (16,000 characters with page marks, plus the page images, kind, title,
byline, publication, issue date and recipient place with quotes). An enclosure is proposed only by the OCR prompt's
`[enclosure]` marker, so routes whose reader takes no prompt (Apple Vision, Mistral, classification-only) propose
none (KNOWN_ISSUES, W37.dual-date). W49.proc-metadata-consolidate asks whether one call (PROMPT) does as well as the
four, on the lead cloud model, and folds in this pack's results: the same prompt on the open cluster model.

The prompt (PROMPT, rendered by prompt()). One document's text and its neighbours' openings; every field the four
calls fill, under their measured definitions, and an enclosure proposal that reads text only, so it works after any
reader. Each filled value carries the words it was read from, copied from the text as the app's entity, dating and
item-field calls already ask, so the app's evidence checks (EntityExtractor.evidence, DateRoute.evidenceCheck) apply
unchanged. Deliberately left out, as US or owner-corpus priors (W49.proc-pipeline-prune point 5): US example names,
places and subjects (tagging's "Democratic Party", "Washington, D.C."), "City, State for the United States", example
years from the corpus's span, the tagging call's "never return null for year", and any day/month order for an
all-numeric date (the app's rule reads month first; here an order the document does not settle leaves month and day
null). The document may be in any language; names, titles and quotes stay as written.

Inputs, per document of W47.item-fields-retruth's 299 (219 base, which hold W46.fix-ent-truth's 138 correspondence
documents, 60 clippings and 20 handwritten; no ABBYY text, owner 2026-10-30):
- text: item_fields_retruth.doc_text, the Vision text of the first 8 and last 2 pages under `[page i of n]` marks, cut
  at TEXT_CAP (16,000, the item-field call's cap; the three 3,000-character calls see its start).
- neighbours: the up to three segments item_fields_retruth.neighbours took (the same ones as the tagging call's nearby
  block), split by folder order into P (before) and N (after); each its first page's Vision text, NEAR_CHARS long, and
  P1 PREV_CHARS long, since the enclosure question reads it. Below them, the trace's block of dates a rule found
  printed in each neighbour (date_traceable.candidates and rule_pick, year only), as the app's trace sends. The app's
  trace reads up to three neighbours each side and two pages each; the item-field set cached three neighbours' first
  pages, so this is the closer of the two nearby blocks to both calls, not either one exactly. As in the tagging
  call's block, a neighbour may be a folder or box label (the trace skips those), which the enclosure question then
  reads as P1.
Text only: the cluster arm reads no image, as the Mac's text route of the item-field call (item_fields_mac TEXT_PROMPT).

Model and settings. Qwen3.6 27B FP8 on one Sherlock GPU through vLLM, as ent-local-27b serves it; temperature 0,
thinking off, MAX_TOKENS. The job sends an 8-request pilot first and the rest only if 6 of 8 stop cleanly.

Truth for the scoring item: entities on the 138 (ent_truth_owner), item fields on the 299 (item_fields_score's folded
truth), year and month against the owner's Finder date tags on each document's first page (corpus_survey.read_tags),
and enclosure proposals have no truth on these documents (their relation truth is the 15 owner cases of
date_enclosure, whose texts are ABBYY text and so are not used): the scoring item reports their rate and the cues.
$0: the run is on Sherlock. Texts and replies stay in the bench cache; the repo holds code and aggregates only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import item_fields_retruth as IR  # noqa: E402

ITEM = "W49.proc-metadata-consolidate-sherlock-prep"
CACHE = Path(os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/metadata-unified"))
STAMP = "metadata-unified-27b-20261124"
PACK = Path(os.path.expanduser(f"~/.local/state/archive-autonomous/artifacts/{STAMP}"))   # the hand-over
BACK = Path(os.path.expanduser(f"~/Library/Caches/ArchiveSuiteRehearsal/sherlock-results/{STAMP}"))
SERVED = "Qwen/Qwen3.6-27B-FP8"
CLUSTER = "unified-qwen3.6-27b"
TEXT_CAP = 16000
NEAR_CHARS = 600
PREV_CHARS = 1500
MAX_TOKENS = 6144
KINDS = ("letter", "memo", "telegram", "newspaper article", "magazine article", "journal article", "newsletter",
         "clipping", "report", "speech", "press release", "photograph", "other")     # item_fields.KINDS

PROMPT = """You are cataloguing one document from an archive for a researcher who will check every value against \
the text. The text was read from photographs by machine OCR and may contain recognition errors. The document may be \
in any language and from any country or period; do not assume a country, language, period or subject that the text \
does not show.

The document's OCR text (id "self"), with page marks:
---
{text}
---

The documents next to it in the same folder, in folder order, each headed by its id (P1 is just before this \
document, N1 just after; P1 is given at more length):
{near}
Dates a rule found printed in the nearby documents (id, year, the line):
{rule_dates}

Reply with JSON only, in this form:
{{"kind": one of {kinds},
 "title": {{"value": "...", "quote": "..."}} or null,
 "byline": [{{"name": "...", "quote": "..."}}],
 "publication": {{"value": "...", "quote": "..."}} or null,
 "publication_date": {{"value": "YYYY-MM-DD" or "YYYY-MM" or "YYYY", "quote": "..."}} or null,
 "sender": [{{"name": "...", "quote": "..."}}],
 "recipient": [{{"name": "...", "quote": "..."}}],
 "sending_place": [{{"name": "...", "quote": "..."}}],
 "recipient_place": [{{"name": "...", "quote": "..."}}],
 "date": {{"year": 4-digit number or null, "month": 1-12 or null, "day": 1-31 or null, "lo": year, "hi": year,
          "date_uncertain": true or false, "source": "self" or a neighbour's id, "quote": "..."}},
 "subject_tags": ["...", ...],
 "enclosure": {{"announces": true or false, "announces_quote": "..." or null,
               "sent_with_previous": true or false, "sent_with_quote": "..." or null, "confidence": 0 to 1}}}}

Definitions.
- kind: what the document is. "clipping" is a printed cutting whose kind of periodical cannot be told.
- title: the title or headline the document itself states, OCR errors corrected (a memo's subject line counts; a \
report's title page). null for a letter, telegram or note, and when no title is printed. A letterhead (the sender's \
organisation printed at the top) is not a title.
- byline: the authors credited on a published piece or a report (an author line), without titles or honorifics. A \
report, press release or speech that names no person as its author: the organisation that issued it. An unsigned \
newspaper or magazine piece: []. [] for correspondence (its sender is not a byline).
- publication: the newspaper, magazine, journal or newsletter the piece was printed in, as named in its masthead, \
running head, or a note written on the clipping. null when not stated, or when the document was not printed in one \
(a letterhead is not a publication; a column's or section's name is not the publication).
- publication_date: the issue date printed with the piece (masthead, running head, or a note on the clipping). null \
when not stated, and always null for a letter, memo or telegram (its own date is not a publication date).
- sender: for a letter, memo or telegram, the person who wrote or signed it (a signature, a typed name under the \
closing, a "From" line); if no person is named as its writer, the organisation it comes from. Typists' initials and \
enclosures are not senders. [] for other kinds.
- recipient: for a letter, memo or telegram, the person or people it is addressed to (the inside address, a "To" \
line, the salutation), each addressee listed. Copies are not recipients. [] for other kinds.
- sending_place: for a letter, memo or telegram, where it was sent from, as the letterhead, dateline or address \
writes it. recipient_place: where the addressee is, from the inside address, a "To" line or an envelope. Give each \
place as its town or city followed by the larger place the document names with it (a region, state, province or \
country), and nothing the document does not write: never a place inferred from an institution's name or from other \
documents. [] when none is written or the document is not correspondence.
- name (in byline, sender, recipient): the person's full name as the document gives it, without titles or \
honorifics, OCR errors corrected; an organisation by its name.
- date: when this document was written or sent. If it prints its own date, give that date, quote it from "self", and \
set lo = hi = year and date_uncertain false. Otherwise estimate the year from the nearby documents: quote the nearby \
text that carries the year, give that document's id as source, set lo and hi to an interval you are 90% sure holds \
the year; month and day stay null unless this document prints them. date_uncertain is true whenever the year does \
not come from this document's own text (source is not "self"). If nothing supports \
any year, give year, lo, hi, source and quote as null. A date merely mentioned in the text (an event, a reply to \
an earlier letter) is not the document's date. An all-numeric date (day, month and year in figures) is read by the conventions \
the document itself shows (its language, its place, its other dates); when they do not settle which part is the \
month, give the year alone, with month and day null.
- subject_tags: 2 to 6 subject tags naming what the document is about, specific enough to find it again (a field, an \
issue, an institution's work, an event), in the document's own terms; not broad words such as "politics" or \
"history", and not the document's kind, date or people.
- enclosure: announces is true when this document says that it sends something with it (an enclosure, an \
attachment, a copy sent along), with the words that say so. sent_with_previous is true when this document was sent \
WITH P1, as its enclosure or attachment (a report, memo, list, clipping or someone else's letter that P1's writer \
sent along); false when it is simply the next item in the folder, such as a reply, a later letter or an unrelated \
paper. Most documents were not sent with the one before them: answer true only when the words of P1 or of this \
document show it (P1 announcing an enclosure that this document is, or this document saying it goes with P1); a \
shared subject, correspondent or date is not enough. sent_with_quote is those words, copied from the text (not an \
id), or null. confidence is how sure you are that it was sent with P1.
- quote (every "quote" field): the words the value was read from, copied character for character from the OCR text \
of the document it cites, recognition errors included; null when the value is not written there (for example only \
a role is written and you know who held it). A date's quote must contain its year.
- Use null or [] for a field the document does not let you fill. Use only these texts, not general knowledge."""


# --- inputs -----------------------------------------------------------------------------------------------------

def docs():
    """The 299 documents, each with every page and neighbour page read (item_fields_retruth's ready set)."""
    out = [d for d in IR.load_docs() if IR.ready(d) and all(IR.page_lines(p) is not None for p in d["near"])]
    if len(out) != 299:
        sys.exit(f"{len(out)} of the item-field set's documents are ready, not 299: run item_fields_retruth.py pages")
    return out


def neighbours(d):
    """[(label, page text)] in folder order, P3 P2 P1 N1 N2 N3. item_fields_retruth.neighbours lists the segments
    before the document first, then those after, all in folder order; the first page's path tells which is which."""
    first = d["pages"][0]
    before = [p for p in d["near"] if p < first]
    after = [p for p in d["near"] if p > first]
    if d["near"] != before + after or first in d["near"]:
        raise ValueError(f"{d['id']}: neighbours not in folder order")
    out = [(f"P{len(before) - i}", IR.page_text(p)) for i, p in enumerate(before)]
    return out + [(f"N{i + 1}", IR.page_text(p)) for i, p in enumerate(after)]


def near_block(ns):
    if not ns:
        return "(none)\n"
    return "".join(f"[{lab}]\n{t.strip()[:PREV_CHARS if lab == 'P1' else NEAR_CHARS]}\n---\n" for lab, t in ns)


def rule_dates(ns):
    import date_traceable as DTR
    ls = []
    for lab, t in ns:
        y, _m, _conf, c = DTR.rule_pick(DTR.candidates(t[:NEAR_CHARS]))
        if y is not None:
            ls.append(f'[{lab}] {y} ("{c["line"]}")')
    return "\n".join(ls) if ls else "(none found)"


def prompt(d):
    ns = neighbours(d)
    return PROMPT.format(text=IR.doc_text(d)[:TEXT_CAP], near=near_block(ns), rule_dates=rule_dates(ns),
                         kinds=", ".join(f'"{k}"' for k in KINDS))


def sha(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


# --- the reply --------------------------------------------------------------------------------------------------

FIELDS = ("kind", "title", "byline", "publication", "publication_date", "sender", "recipient", "sending_place",
          "recipient_place", "date", "subject_tags", "enclosure")


def parse(raw):
    """The reply's JSON object with every FIELDS key present, or None. Thinking blocks and a code fence are dropped;
    a missing list is [], a missing value null, an unknown kind "other"."""
    s = re.sub(r"<think>.*?</think>", "", raw or "", flags=re.S).strip()
    i, j = s.find("{"), s.rfind("}")
    if i < 0 or j < i:
        return None
    try:
        js = json.loads(s[i:j + 1])
    except ValueError:
        return None
    if not isinstance(js, dict) or not any(k in js for k in FIELDS):
        return None
    lists = ("byline", "sender", "recipient", "sending_place", "recipient_place", "subject_tags")
    out = {k: (js.get(k) if isinstance(js.get(k), list) else []) if k in lists else js.get(k) for k in FIELDS}
    if out["kind"] not in KINDS:
        out["kind"] = "other"
    for k in ("date", "enclosure", "title", "publication", "publication_date"):
        if not isinstance(out[k], dict):
            out[k] = None
    return out


def quote_found(quote, text):
    """Whether a quote is in the text, whitespace folded (the strict half of the app's evidence checks)."""
    if not quote:
        return False
    fold = lambda x: " ".join(x.split()).lower()  # noqa: E731
    return fold(quote) in fold(text)


# --- commands ---------------------------------------------------------------------------------------------------

PRIORS = ("Democratic Party", "Washington", "New York", "City, State", "United States", "1947", "1968", "1987",
          "Never return null", "Mr. President", "American")


def cmd_check(a):
    ds = docs()
    ps = [prompt(d) for d in ds]
    hits = [w for w in PRIORS if w in PROMPT]
    L = sorted(len(p) for p in ps)
    ns = [len(neighbours(d)) for d in ds]
    print(f"{len(ps)} prompts; characters median {statistics.median(L):.0f}, 90th percentile {L[int(.9 * len(L))]}, "
          f"max {L[-1]}; neighbours per document median {statistics.median(ns):.0f}, with a P1 "
          f"{sum(any(lab == 'P1' for lab, _ in neighbours(d)) for d in ds)}; "
          f"cut at {TEXT_CAP}: {sum(len(IR.doc_text(d)) > TEXT_CAP for d in ds)}")
    print("prior phrases in the template:", hits or "none")
    if hits:
        sys.exit(1)


def cmd_pack(a):
    """The 299 prompts as a frozen pack in ent-local-27b's form: unified/requests.jsonl for postcorrect_cluster.py
    (text only), the support files, every file hashed in freeze.json (check_pack.py reads it)."""
    if PACK.exists():
        sys.exit(f"{PACK} exists: a frozen pack is never rebuilt in place")
    rows = [{"id": d["id"], "prompt": prompt(d), "max_tokens": MAX_TOKENS} for d in docs()]
    (PACK / "unified").mkdir(parents=True)
    with open(PACK / "unified" / "requests.jsonl", "w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    sh = HERE / "sherlock"
    job = PACK / "support" / "job"
    (job / "bin").mkdir(parents=True)
    shutil.copy2(HERE / "postcorrect_cluster.py", PACK / "support")
    shutil.copy2(sh / "ent-robust" / "check_pack.py", PACK / "support")
    for f in ("submit.sh", "stage-job.sh", "job.sh"):
        shutil.copy2(sh / "metadata-unified-27b" / f, job)
    shutil.copy2(sh / "sh.env", job)
    for f in (sh / "bin").iterdir():
        shutil.copy2(f, job / "bin")
    meta = {"item": ITEM, "requests": len(rows), "model": SERVED, "max_tokens": MAX_TOKENS, "temperature": 0,
            "thinking": "off", "prompt": "metadata_unified.prompt(d)", "template_sha256": sha(PROMPT),
            "prompts_sha256": sha("".join(r["prompt"] for r in rows))}
    (PACK / "pack.json").write_text(json.dumps(meta, indent=1) + "\n")
    files = {}
    for dp, dns, fns in os.walk(PACK):
        rel = os.path.relpath(dp, PACK)
        dns[:] = [x for x in dns if x not in ("out", "logs")]     # answers are never frozen
        for fn in fns:
            if rel == "." and fn == "freeze.json":
                continue
            files[os.path.normpath(os.path.join(rel, fn))] = hashlib.sha256(Path(dp, fn).read_bytes()).hexdigest()
    (PACK / "freeze.json").write_text(json.dumps({"item": ITEM, "arms": ["unified"],
                                                  "files": dict(sorted(files.items()))}, indent=1) + "\n")
    size = sum((PACK / f).stat().st_size for f in files)
    print(f"froze {len(files)} files, {size / 1e6:.1f} MB: {len(rows)} requests -> {PACK}")


def cmd_collect(a):
    """The returned replies (the Mac artifact's unified/out, else BACK's) as CLUSTER replies in CACHE; every request
    needs one, and each must answer the prompt as it now stands."""
    out = next((x for x in (PACK / "unified" / "out", BACK / "unified" / "out") if x.is_dir()), None)
    if out is None:
        sys.exit("no returned answers: the pack waits for an owner session on Sherlock")
    now = {d["id"]: d for d in docs()}
    dest = CACHE / "replies" / CLUSTER
    dest.mkdir(parents=True, exist_ok=True)
    missing, unparsed, n = [], [], 0
    for line in open(PACK / "unified" / "requests.jsonl", encoding="utf-8"):
        q = json.loads(line)
        if sha(q["prompt"]) != sha(prompt(now[q["id"]])):
            sys.exit(f"{q['id']}: the prompt changed since the pack was built; its reply cannot be scored")
        f = out / f"{q['id']}.json"
        if not f.exists():
            missing.append(q["id"])
            continue
        r = json.loads(f.read_text())
        rec = {"meta": {"prompt_sha256": sha(q["prompt"]), "model": SERVED, "temperature": 0, "max_tokens": MAX_TOKENS,
                        "runtime": "vLLM on Sherlock", "finish": r.get("finish"), "wall_s": r.get("seconds")},
               "raw": r.get("text"), "parsed": parse(r.get("text"))}
        unparsed += [q["id"]] if rec["parsed"] is None else []
        (dest / f"{q['id']}.json").write_text(json.dumps(rec, ensure_ascii=False, indent=1))
        n += 1
    if missing:
        sys.exit(f"{len(missing)} requests have no reply, e.g. {missing[:3]}")
    print(f"{n} replies -> {dest}; {len(unparsed)} unparsed")


def cmd_mac_pilot(a):
    import model_store
    model_store.use()
    import mlx.core as mx
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    mx.set_cache_limit(256 * 2**20)
    model, processor = load("mlx-community/Qwen3-VL-8B-Instruct-4bit")
    dest = CACHE / "replies" / "pilot-qwen3-vl-8b-mlx4"
    dest.mkdir(parents=True, exist_ok=True)
    ds = docs()
    parts = [[d for d in ds if d["part"] == x] for x in ("base", "clippings", "handwritten")]
    for d in [d for k in range(len(ds)) for g in parts for d in g[k:k + 1]][: a.limit]:   # the parts in turn
        p = prompt(d)
        chat = apply_chat_template(processor, model.config, p, num_images=0)
        text, last = [], None
        for r in stream_generate(model, processor, chat, max_tokens=MAX_TOKENS, temperature=0.0):
            text.append(r.text); last = r
        raw = "".join(text)
        js = parse(raw)
        (dest / f"{d['id']}.json").write_text(json.dumps({"prompt_sha256": sha(p), "raw": raw, "parsed": js},
                                                         ensure_ascii=False, indent=1))
        own = IR.doc_text(d)[:TEXT_CAP]
        quotes = [] if js is None else [x.get("quote") for k in ("sender", "recipient", "byline") for x in js[k]
                                         if isinstance(x, dict)]
        print(f"{d['id']} {d['part']}: tokens {getattr(last, 'prompt_tokens', 0)}+{getattr(last, 'generation_tokens', 0)}, "
              f"parsed {js is not None}, kind {js and js['kind']}, year {js and (js['date'] or {}).get('year')}, "
              f"name quotes found {sum(quote_found(q, own) for q in quotes if q)}/{sum(1 for q in quotes if q)}",
              flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("check", "pack", "collect"):
        sub.add_parser(c)
    sub.add_parser("mac-pilot").add_argument("--limit", type=int, default=4)
    a = ap.parse_args()
    {"check": cmd_check, "pack": cmd_pack, "collect": cmd_collect, "mac-pilot": cmd_mac_pilot}[a.cmd](a)


if __name__ == "__main__":
    main()
