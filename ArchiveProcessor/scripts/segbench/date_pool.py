#!/usr/bin/env python3
"""W46.fix-date-truth-score, the larger dating set: every unprinted-year document of the agreed pool classed A to D,
a stratified 200 of them for drafting and audit, and the masked-date set (B-dating.md test 7).

    python3 date_pool.py            # writes the bench cache's date-tagging/pool/ and segbench-results/date-pool.md

The agreed pool is `date_tagging.document_pool`'s: every tag-rule document whose gaps the owner's labels agree on,
with a year tag and ABBYY text (Stanton and RG 165 copies excluded there). Classes are `date_truth.structural_class`
over the same folder segments, so a pool document and a sampled one are classed alike. The 300 of the W41 sample
are left out of both sets (they are the test already scored, and the 54 owner cases are among them).

  pool/classes.jsonl   one line per unprinted-year pool document: id, class, folder, position, truth
  pool/stratified.jsonl  the 200: an equal share per class (40), a class with fewer gives its rest to the others;
                       each with the app's prompt, the previous document's id and the folder for the drafting pass
  pool/masked.jsonl    200 printed-year documents (seed 46, stratified by tag class) whose text has the owner's year
                       removed in every form found (1958, '58, 5/24/58, 24.5.58) as `[…]`; truth exact. `context_prints`
                       says whether the neighbours' 300 characters still print it, so a scorer can split on it.

Read-only on the corpus (tags and the text cache). No model call, $0. Private outputs stay in the cache; the
committed summary has counts only.
"""
import collections
import hashlib
import json
import os
import random
import re
import sys

sys.path.insert(0, os.getcwd())
import corpus_pairs as CP
import corpus_survey as CS
import date_tagging as DT
import date_truth as DTR
import enclosure_split as ES

OUT = os.path.join(DT.CACHE, "pool")
RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "segbench-results", "date-pool.md")
SEED = 46
N_STRAT = 200
N_MASK = 200
UNPRINTED = ("A", "A'", "B", "C", "D")


def mask_year(text, year):
    """The text with the year removed in every written form: 1958, '58, and a numeric date ending in 58."""
    yy = f"{year % 100:02d}"
    t = re.sub(rf"(?<!\d){year}(?!\d)", "[…]", text)
    t = re.sub(rf"\b\d{{1,2}}[-/.]\d{{1,2}}[-/.]{yy}(?!\d)", "[…]", t)
    t = re.sub(rf"['’‘]{yy}(?!\d)", "[…]", t)
    return t


def allocate(counts, n):
    """An equal share of n per class; a class with fewer documents gives its remainder to the others."""
    left, out = n, {c: 0 for c in counts}
    open_ = [c for c in counts if counts[c] > 0]
    while left > 0 and open_:
        share = max(1, left // len(open_))
        for c in list(open_):
            take = min(share, counts[c] - out[c], left)
            out[c] += take
            left -= take
            if out[c] >= counts[c]:
                open_.remove(c)
            if left == 0:
                break
    return out


def walk(exclude_sample=True):
    """(unprinted, printed): pool documents with a year tag, as dicts, classed or masked-ready."""
    lab = {}
    for line in open(os.path.join(CP.CACHE, "labels.jsonl"), encoding="utf-8"):
        g = json.loads(line)
        lab[(g["folder_id"], g["n"])] = g
    sampled = {json.loads(l)["id"] for l in open(os.path.join(DT.CACHE, "sample.jsonl"), encoding="utf-8")} if exclude_sample else set()
    folders = sorted({os.path.dirname(g["left"]) for g in lab.values()})
    unprinted, printed = [], []
    for f in folders:
        if DT.STANTON_RG165.search(f):
            continue
        segs = DT.folder_documents(f, lab)
        texts = ["\n\n".join(DT.page_text(p) for p in s["pages"]) for s in segs]
        truths = [DT.truth_of(CS.read_tags(os.path.join(CS.CORPUS, s["pages"][0]))) if s["kind"] == "doc" else None
                  for s in segs]
        ids = [hashlib.sha1(s["pages"][0].encode()).hexdigest()[:16] if s["kind"] == "doc" else None for s in segs]
        for k, s in enumerate(segs):
            if s["kind"] != "doc" or not s["agreed"] or ids[k] in sampled:
                continue
            cls, tr = truths[k]
            if not tr or "year" not in tr or not texts[k].strip():
                continue
            info = {"folder": f, "k": k, "segs": segs, "texts": texts, "truths": truths}
            near_texts = (texts[max(0, k - 3):k] + texts[k + 1:k + 4])[:3]
            context = "\n---\n".join(t[:300] for t in near_texts)
            d = {"id": ids[k], "tag_class": cls, "truth": tr, "folder": f, "collection": CP.collection_of(f),
                 "position": k, "pages": len(s["pages"]), "first_pages": s["pages"][:2],
                 "year_in_text": str(tr["year"]) in texts[k][:3000]}
            if d["year_in_text"]:
                d["_text"], d["_context"] = texts[k], context
                printed.append(d)
                continue
            r = {**d, **ES.classify(d, info)}
            d["class"] = DTR.structural_class(r, info, {d["id"]: info})
            j = ES.neighbour(info, k, -1)
            d["previous"] = ids[j] if j is not None else None
            d["prompt"] = DT.build_prompt(texts[k], context)
            unprinted.append(d)
    return unprinted, printed


def main():
    unprinted, printed = walk()
    os.makedirs(OUT, exist_ok=True)
    counts = collections.Counter(d["class"] for d in unprinted)
    with open(os.path.join(OUT, "classes.jsonl"), "w", encoding="utf-8") as fh:
        for d in unprinted:
            fh.write(json.dumps({k: d[k] for k in ("id", "class", "tag_class", "folder", "position", "truth")},
                                ensure_ascii=False) + "\n")
    rng = random.Random(SEED)
    alloc = allocate({c: counts[c] for c in UNPRINTED}, N_STRAT)
    strat = []
    for c in UNPRINTED:
        ds = sorted((d for d in unprinted if d["class"] == c), key=lambda d: d["id"])
        strat += rng.sample(ds, alloc[c])
    with open(os.path.join(OUT, "stratified.jsonl"), "w", encoding="utf-8") as fh:
        for d in strat:
            fh.write(json.dumps(d, ensure_ascii=False) + "\n")
    mcounts = collections.Counter(d["tag_class"] for d in printed)
    malloc = allocate(dict(mcounts), N_MASK)
    masked = []
    for c in sorted(mcounts):
        ds = sorted((d for d in printed if d["tag_class"] == c), key=lambda d: d["id"])
        for d in rng.sample(ds, malloc[c]):
            y = d["truth"]["year"]
            text = mask_year(d["_text"], y)
            m = {k: v for k, v in d.items() if not k.startswith("_")}
            m["prompt"] = DT.build_prompt(text, d["_context"])
            m["text_still_prints"] = str(y) in text[:3000]
            m["context_prints"] = str(y) in d["_context"]
            masked.append(m)
    with open(os.path.join(OUT, "masked.jsonl"), "w", encoding="utf-8") as fh:
        for d in masked:
            fh.write(json.dumps(d, ensure_ascii=False) + "\n")
    sc = collections.Counter(d["class"] for d in strat)
    du = collections.Counter(d["class"] for d in unprinted if d["truth"]["du"])
    L = ["# Dating: the agreed pool classed A to D, the stratified 200 and the masked-date set (W46.fix-date-truth-score)",
         "", "Written by `scripts/segbench/date_pool.py` (B-dating.md test 7). The pool is the W41 date-tagging pool "
         "(documents whose gaps the owner's labels agree on, with a year tag and text), less the 300 already sampled. "
         "Classes as in `date-truth.md`. The sets themselves stay private in the bench cache (`date-tagging/pool/`). "
         "No model call, $0.", "",
         f"Year-tagged pool documents with text: {len(unprinted) + len(printed)}; the year is printed in the first "
         f"3,000 characters of {len(printed)} and not printed in {len(unprinted)}.", "",
         "| class | unprinted-year documents | of them Date Uncertain | in the stratified 200 |", "|---|---|---|---|"]
    for c in UNPRINTED:
        L.append(f"| {c} | {counts[c]} | {du[c]} | {sc[c]} |")
    L += ["", f"The stratified 200 takes an equal share per class, seed {SEED}, so the rare classes are not drowned by "
          "the common one; per-class figures from it are unweighted, and a pool-wide figure needs the class weights "
          "above. Per the owner's Phase 2 decision 2 (labelling: judgement sets to the owner, the rest drafted by "
          "models and audited), the 200 are drafted by models, then audited; the owner's 54 answers "
          "(`date-truth-sets.md`) are the calibration for that draft. The 54 showed that most unprinted years sit "
          "on the page itself, so the draft asks first for a date on the document's own pages.", "",
          f"The masked-date set: {len(masked)} printed-year documents, stratified by tag class "
          + ", ".join(f"{c} {sum(1 for d in masked if d['tag_class'] == c)}" for c in sorted(mcounts))
          + ", with the owner's year removed from the document's text in every written form. The year survives in "
          f"the text on {sum(d['text_still_prints'] for d in masked)} (a form the masker does not catch) and in the "
          f"neighbours' context on {sum(d['context_prints'] for d in masked)}; scorers split on both flags. "
          "Truth is exact: the year was printed.", ""]
    with open(RESULTS, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))
    print(f"unprinted {len(unprinted)} {dict(counts)}; stratified {dict(sc)}; masked {len(masked)}; {RESULTS}")


if __name__ == "__main__":
    main()
