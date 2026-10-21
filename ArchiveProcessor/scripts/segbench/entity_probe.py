"""Read-only analysis for strand G (entities). Three questions, all from caches already on disk; writes nothing but
stdout. Run from scripts/segbench so the bench modules import.

1. What the app's tagging prompt already extracts: non-null rates of author_name / recipient_name / author_location /
   recipient_location / format in the cached replies of Gemini 3.8 Flash and the open models on the 300 sampled
   documents, and surname agreement between the open models and Gemini.
2. Whether names carry an enclosure signal: for the 131 documents whose owner year is not in their text, split as
   B-dating's enclosure_split.py splits them (strict: previous document dated in its own text with the same owner
   year; loose: a dated same-year document within three positions; rest), how often the current document's extracted
   author or recipient surname appears in the previous document's text.
3. Whether letter openings and closings are boundary cues: over every cleaned gap label in corpus-pairs (tag new/cont,
   keep=True), the rate of a salutation pattern at the top of the right page and a closing pattern at the foot of the
   left page, by label.
"""
import collections, hashlib, json, os, re, sys
sys.path.insert(0, os.getcwd())
import date_tagging as DT
import corpus_pairs as CP
import corpus_survey as CS

LABELS = (None, "qwen3.6-27b-nothink", "qwen3.5-4b-nothink", "qwen3-vl-8b")
NAME = {None: "gemini-3.8-flash", "qwen3.6-27b-nothink": "qwen3.6-27b", "qwen3.5-4b-nothink": "qwen3.5-4b",
        "qwen3-vl-8b": "qwen3-vl-8b"}
FIELDS = ("author_name", "recipient_name", "author_location", "recipient_location", "format", "publication_name")


def reply_json(resp):
    try:
        parts = resp["candidates"][0]["content"]["parts"]
        raw = "".join(p.get("text", "") for p in parts)
    except (KeyError, IndexError, TypeError):
        return None
    s = raw.strip()
    if s.startswith("```"):
        s = "\n".join(s.split("\n")[1:-1])
    i, j = s.find("{"), s.rfind("}")
    if i >= 0 and j >= i:
        s = s[i:j + 1]
    try:
        js = json.loads(s)
    except ValueError:
        return None
    return js if isinstance(js, dict) else None


def val(js, k):
    v = js.get(k) if js else None
    if isinstance(v, str):
        v = v.strip()
        return None if not v or v.lower() in ("null", "none", "unknown", "n/a") else v
    return None


GENERIC = {"the", "and", "of", "inc", "co", "company", "committee", "department", "office", "university", "jr", "sr",
           "esq", "mr", "mrs", "ms", "dr", "president", "editor", "secretary", "director", "staff", "unknown"}


def surname(name):
    toks = [re.sub(r"[^A-Za-z\-']", "", t) for t in name.replace(",", " ").split()]
    toks = [t for t in toks if len(t) >= 3 and t.lower() not in GENERIC]
    if not toks:
        return None
    # "Smith, John" -> Smith; "John Smith" -> Smith
    return toks[0] if "," in name else toks[-1]


def in_text(sn, text):
    return sn is not None and re.search(r"(?<![A-Za-z])" + re.escape(sn) + r"(?![A-Za-z])", text, re.I) is not None


sample = [json.loads(l) for l in open(os.path.join(DT.CACHE, "sample.jsonl"), encoding="utf-8")]
answers = {}
for d in sample:
    answers[d["id"]] = {}
    for lab in LABELS:
        p = DT.answer_path(d["prompt"], lab)
        answers[d["id"]][lab] = reply_json(json.load(open(p))) if os.path.exists(p) else None


def pct(a, b):
    return f"{100.0 * a / b:.1f}% ({a}/{b})" if b else "–"


print("== 1. What the tagging prompt already extracts, 300 sampled documents")
for lab in LABELS:
    got = [answers[d["id"]][lab] for d in sample if answers[d["id"]][lab] is not None]
    print(f"  {NAME[lab]:18s} parsed replies {len(got)}/{len(sample)}:",
          "  ".join(f"{f} {pct(sum(val(j, f) is not None for j in got), len(got))}" for f in FIELDS))
fmt = collections.Counter((val(answers[d["id"]][None], "format") or "null").lower() for d in sample)
print("  Gemini format field:", ", ".join(f"{k} {v}" for k, v in fmt.most_common(12)))
letters = [d for d in sample if (val(answers[d["id"]][None], "format") or "").lower() in ("letter", "memo", "memorandum", "telegram")]
g = [answers[d["id"]][None] for d in letters]
print(f"  Gemini on the {len(letters)} letters/memos/telegrams: author {pct(sum(val(j,'author_name') is not None for j in g), len(g))}, "
      f"recipient {pct(sum(val(j,'recipient_name') is not None for j in g), len(g))}, "
      f"author_location {pct(sum(val(j,'author_location') is not None for j in g), len(g))}, "
      f"recipient_location {pct(sum(val(j,'recipient_location') is not None for j in g), len(g))}")
print("  Surname agreement with Gemini (both non-null | one null, other not):")
for lab in LABELS[1:]:
    for f in ("author_name", "recipient_name"):
        both = agree = onenull = 0
        for d in sample:
            a, b = answers[d["id"]][None], answers[d["id"]][lab]
            if a is None or b is None:
                continue
            x, y = val(a, f), val(b, f)
            if x and y:
                both += 1
                sx, sy = surname(x), surname(y)
                agree += sx is not None and sy is not None and sx.lower() == sy.lower()
            elif (x is None) != (y is None):
                onenull += 1
        print(f"    {NAME[lab]:14s} {f:15s} agree {pct(agree, both)}   one-sided null {onenull}")

print("\n== 2. Name continuity as an enclosure signal, the 131 unprinted-year documents")
by_id = {d["id"]: d for d in sample}
lab_ = {}
for line in open(os.path.join(CP.CACHE, "labels.jsonl"), encoding="utf-8"):
    gg = json.loads(line)
    lab_[(gg["folder_id"], gg["n"])] = gg
folders = sorted({os.path.dirname(gg["left"]) for gg in lab_.values()})
found = {}
for f in folders:
    segs = DT.folder_documents(f, lab_)
    ids = [hashlib.sha1(s["pages"][0].encode()).hexdigest()[:16] if s["kind"] == "doc" else None for s in segs]
    hits = [k for k, i in enumerate(ids) if i in by_id]
    if not hits:
        continue
    texts = ["\n\n".join(DT.page_text(p) for p in s["pages"]) for s in segs]
    truths = [DT.truth_of(CS.read_tags(os.path.join(CS.CORPUS, s["pages"][0]))) if s["kind"] == "doc" else None for s in segs]
    for k in hits:
        found[ids[k]] = {"k": k, "segs": segs, "texts": texts, "truths": truths}


def year_in(k, info):
    t = info["truths"][k]
    return bool(t and t[1] and "year" in t[1] and str(t[1]["year"]) in info["texts"][k][:3000])


rows = []
for d in sample:
    if "year" not in d["truth"] or d["year_in_text"] or d["id"] not in found:
        continue
    info = found[d["id"]]; k = info["k"]; y = d["truth"]["year"]
    prev = k - 1 if k > 0 and info["segs"][k - 1]["kind"] == "doc" else None
    strict = prev is not None and info["truths"][prev][1] and info["truths"][prev][1].get("year") == y and year_in(prev, info)
    loose = any(0 <= k + s < len(info["segs"]) and info["segs"][k + s]["kind"] == "doc" and info["truths"][k + s][1]
                and info["truths"][k + s][1].get("year") == y and year_in(k + s, info) for s in (-3, -2, -1, 1, 2, 3))
    cls = "strict" if strict else "loose" if loose else "rest"
    js = answers[d["id"]][None]
    a, r = surname(val(js, "author_name") or "") if val(js, "author_name") else None, \
        surname(val(js, "recipient_name") or "") if val(js, "recipient_name") else None
    ptext = info["texts"][prev] if prev is not None else ""
    rows.append({"cls": cls, "prev": prev is not None, "a": a, "r": r,
                 "a_in_prev": in_text(a, ptext), "r_in_prev": in_text(r, ptext),
                 "format": (val(js, "format") or "null").lower(),
                 "a_in_own": in_text(a, info["texts"][k]), "r_in_own": in_text(r, info["texts"][k])})
print(f"  located {len(rows)} of the unprinted-year documents")
for cls in ("strict", "loose", "rest"):
    rs = [x for x in rows if x["cls"] == cls]
    withprev = [x for x in rs if x["prev"]]
    named = [x for x in withprev if x["a"] or x["r"]]
    print(f"  {cls:6s} n={len(rs):3d} prev is a doc {len(withprev):3d}; Gemini named an author or recipient on {len(named):3d}; "
          f"author surname in prev text {pct(sum(x['a_in_prev'] for x in withprev), sum(bool(x['a']) for x in withprev))}; "
          f"recipient surname in prev text {pct(sum(x['r_in_prev'] for x in withprev), sum(bool(x['r']) for x in withprev))}; "
          f"either {pct(sum(x['a_in_prev'] or x['r_in_prev'] for x in named), len(named))}")
    fm = collections.Counter(x["format"] for x in rs)
    print(f"         formats: {', '.join(f'{k} {v}' for k, v in fm.most_common(8))}")
print("  Sanity: extracted surname found in the document's own text (hallucination check), all 131:",
      f"author {pct(sum(x['a_in_own'] for x in rows if x['a']), sum(bool(x['a']) for x in rows))}, "
      f"recipient {pct(sum(x['r_in_own'] for x in rows if x['r']), sum(bool(x['r']) for x in rows))}")
# the same hallucination check on the 300
ha = hr = na = nr = 0
for d in sample:
    js = answers[d["id"]][None]
    if not js or d["id"] not in found:
        continue
    own = found[d["id"]]["texts"][found[d["id"]]["k"]]
    a = surname(val(js, "author_name")) if val(js, "author_name") else None
    r = surname(val(js, "recipient_name")) if val(js, "recipient_name") else None
    if a: na += 1; ha += in_text(a, own)
    if r: nr += 1; hr += in_text(r, own)
print(f"  Same check on all located sampled documents: author surname in own text {pct(ha, na)}, recipient {pct(hr, nr)}")

print("\n== 3. Letter openings and closings as boundary cues, every cleaned gap in corpus-pairs")
SAL = re.compile(r"^\s*(dear\b|my dear\b|gentlemen\b|dear sirs?\b|sirs?\s*[:,]|madam|to\s*:|memorandum|memo\b|"
                 r"honorable|hon\.|the honorable|mr\.? president|your excellency|messrs)", re.I | re.M)
CLO = re.compile(r"(sincerely|cordially|yours (very )?truly|very truly yours|yours (sincerely|faithfully|respectfully)|"
                 r"respectfully( yours| submitted)?|faithfully yours|with (best|kind|warm|all good) (regards|wishes)|"
                 r"best (regards|wishes)|affectionately|as ever|yours,|yours ever|\benc(l|los)?[s.]|\bcc\s*:|/s/|"
                 r"kind regards|warm regards|with love)", re.I)


def head(text, n=12):
    lines = [l for l in text.splitlines() if l.strip()]
    return "\n".join(lines[:n])


def foot(text, n=12):
    lines = [l for l in text.splitlines() if l.strip()]
    return "\n".join(lines[-n:])


c = collections.Counter()
for (fid, n), gg in lab_.items():
    if not gg.get("keep") or gg["tag"] not in ("new", "cont"):
        continue
    lt, rt = DT.page_text(gg["left"]), DT.page_text(gg["right"])
    if not lt.strip() or not rt.strip():
        c[(gg["tag"], "notext")] += 1
        continue
    s = bool(SAL.search(head(rt)))
    e = bool(CLO.search(foot(lt)))
    c[(gg["tag"], "n")] += 1
    c[(gg["tag"], "sal")] += s
    c[(gg["tag"], "clo")] += e
    c[(gg["tag"], "either")] += s or e
    c[(gg["tag"], "both")] += s and e
tot = {t: c[(t, "n")] for t in ("new", "cont")}
print(f"  gaps with text on both pages: new {tot['new']}, cont {tot['cont']}; dropped for a blank side: new {c[('new','notext')]}, cont {c[('cont','notext')]}")
for cue in ("sal", "clo", "either", "both"):
    n_new, n_cont = c[("new", cue)], c[("cont", cue)]
    prec = n_new / (n_new + n_cont) if n_new + n_cont else 0
    print(f"  {cue:6s} fires on true boundaries {pct(n_new, tot['new']):18s} on continuations {pct(n_cont, tot['cont']):18s} "
          f"P(new | cue) {100*prec:.1f}%  (base rate P(new) {100*tot['new']/(tot['new']+tot['cont']):.1f}%)")
