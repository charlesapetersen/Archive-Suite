"""Read-only analysis for strand B: split the sampled 'year not in text' documents by whether a dated
document with the same owner year sits beside them in folder order, and score the cached model answers
on each side. Writes nothing outside stdout. Run from scripts/segbench so the bench modules import."""
import collections, hashlib, json, os, re, sys
sys.path.insert(0, os.getcwd())
import date_tagging as DT
import corpus_pairs as CP
import corpus_survey as CS

CUES = re.compile(r"enclos|attach|herewith|transmit|forward(ing)? (you|to you|a copy)|copy of|for your (information|files|review)", re.I)

sample = [json.loads(l) for l in open(os.path.join(DT.CACHE, "sample.jsonl"), encoding="utf-8")]
by_id = {d["id"]: d for d in sample}
want = set(by_id)

lab = {}
for line in open(os.path.join(CP.CACHE, "labels.jsonl"), encoding="utf-8"):
    g = json.loads(line)
    lab[(g["folder_id"], g["n"])] = g
folders = sorted({os.path.dirname(g["left"]) for g in lab.values()})

found = {}
for f in folders:
    segs = DT.folder_documents(f, lab)
    ids = [hashlib.sha1(s["pages"][0].encode()).hexdigest()[:16] if s["kind"] == "doc" else None for s in segs]
    hits = [k for k, i in enumerate(ids) if i in want]
    if not hits:
        continue
    texts = ["\n\n".join(DT.page_text(p) for p in s["pages"]) for s in segs]
    truths = [None] * len(segs)
    for k, s in enumerate(segs):
        if s["kind"] == "doc":
            cls, tr = DT.truth_of(CS.read_tags(os.path.join(CS.CORPUS, s["pages"][0])))
            truths[k] = (cls, tr)
    for k in hits:
        found[ids[k]] = {"folder": f, "k": k, "segs": segs, "texts": texts, "truths": truths}

print(f"sampled {len(sample)}, located in folders {len(found)}")

def own_year_in_text(k, info):
    cls, tr = info["truths"][k]
    if not tr or "year" not in tr:
        return False
    return str(tr["year"]) in info["texts"][k][:3000]

def neighbour(info, k, step):
    """The adjacent segment in direction step if it is a document; None if none or a Box/Folder label."""
    j = k + step
    segs = info["segs"]
    if j < 0 or j >= len(segs) or segs[j]["kind"] != "doc":
        return None
    return j

def classify(d, info):
    k = info["k"]
    cls, tr = info["truths"][k]
    y = tr["year"]
    m = tr.get("month")
    out = {"prev_doc": False, "prev_dated_same_year": False, "prev_dated_same_year_month": False,
           "prev_dated_other_year": False, "prev_undated_same_year": False, "prev_cue": False,
           "next_dated_same_year": False, "any3_dated_same_year": False, "prev_year": None}
    j = neighbour(info, k, -1)
    if j is not None:
        out["prev_doc"] = True
        pcls, ptr = info["truths"][j]
        pin = own_year_in_text(j, info)
        py = ptr.get("year") if ptr else None
        out["prev_year"] = py
        out["prev_cue"] = bool(CUES.search(info["texts"][j][-1500:] + " " + info["texts"][j][:1500]))
        if py == y and pin:
            out["prev_dated_same_year"] = True
            pm = ptr.get("month")
            if m and pm and pm == m:
                out["prev_dated_same_year_month"] = True
        elif py == y and not pin:
            out["prev_undated_same_year"] = True
        elif py is not None and pin:
            out["prev_dated_other_year"] = True
    j = neighbour(info, k, +1)
    if j is not None:
        ncls, ntr = info["truths"][j]
        if ntr and ntr.get("year") == y and own_year_in_text(j, info):
            out["next_dated_same_year"] = True
    for step in (-3, -2, -1, 1, 2, 3):
        jj = k + step
        if 0 <= jj < len(info["segs"]) and info["segs"][jj]["kind"] == "doc":
            t = info["truths"][jj][1]
            if t and t.get("year") == y and own_year_in_text(jj, info):
                out["any3_dated_same_year"] = True
    return out

def answers(d, label):
    p = DT.answer_path(d["prompt"], label)
    if not os.path.exists(p):
        return None
    resp = json.load(open(p))
    year, month, du, ok = DT.app_parse(resp)
    y = int(year) if year and re.fullmatch(r"\d{4}", year) else None
    return {"y": y, "du": du}

rows = []
for d in sample:
    if "year" not in d["truth"]:
        continue
    info = found.get(d["id"])
    if not info:
        continue
    c = classify(d, info)
    rows.append({**d, **c, "ans": {lab_: answers(d, lab_) for lab_ in (None, "qwen3.6-27b-nothink", "qwen3.5-4b-nothink", "qwen3-vl-8b")}})

def pct(a, b):
    return f"{100.0 * a / b:.1f}% ({a}/{b})" if b else "–"

def report(name, rs):
    print(f"\n== {name}: {len(rs)} documents")
    for lab_ in (None, "qwen3.6-27b-nothink", "qwen3.5-4b-nothink", "qwen3-vl-8b"):
        got = [r for r in rs if r["ans"][lab_]]
        ex = sum(r["ans"][lab_]["y"] == r["truth"]["year"] for r in got)
        w1 = sum(r["ans"][lab_]["y"] is not None and abs(r["ans"][lab_]["y"] - r["truth"]["year"]) <= 1 for r in got)
        du = sum(r["ans"][lab_]["du"] for r in got)
        prevy = sum(r["ans"][lab_]["y"] is not None and r["prev_year"] is not None and r["ans"][lab_]["y"] == r["prev_year"] for r in got)
        print(f"  {lab_ or 'gemini-3.8-flash':22s} exact {pct(ex, len(got)):16s} within1 {pct(w1, len(got)):16s} "
              f"DU {pct(du, len(got)):16s} reply==prev doc's year {pct(prevy, len(got))}")

not_in = [r for r in rows if not r["year_in_text"]]
in_t = [r for r in rows if r["year_in_text"]]
print(f"\nyear-tagged rows {len(rows)}: in text {len(in_t)}, not in text {len(not_in)}")
c = collections.Counter()
for r in not_in:
    c["prev segment is a document"] += r["prev_doc"]
    c["prev doc dated in its own text, same owner year"] += r["prev_dated_same_year"]
    c["  ... and same owner month"] += r["prev_dated_same_year_month"]
    c["prev doc has same owner year but its year not in its text"] += r["prev_undated_same_year"]
    c["prev doc dated in its own text, different year"] += r["prev_dated_other_year"]
    c["prev doc text has an enclosure cue word"] += r["prev_cue"]
    c["prev dated same year AND cue"] += r["prev_dated_same_year"] and r["prev_cue"]
    c["next doc dated in its own text, same year"] += r["next_dated_same_year"]
    c["some doc within 3 dated in its own text, same year"] += r["any3_dated_same_year"]
    c[f"class {r['class']}"] += 1
for k_, v in c.items():
    print(f"  {k_}: {v} of {len(not_in)}")

report("ALL year-tagged", rows)
report("year in text", in_t)
report("year NOT in text", not_in)
report("NOT in text, prev doc dated same year (enclosure-consistent, strict)", [r for r in not_in if r["prev_dated_same_year"]])
report("NOT in text, some doc within 3 dated same year (loose)", [r for r in not_in if r["any3_dated_same_year"]])
report("NOT in text, no dated same-year doc within 3 (the rest)", [r for r in not_in if not r["any3_dated_same_year"]])
report("NOT in text, owner certain (year, year+month)", [r for r in not_in if r["class"] in ("year", "year+month")])
report("NOT in text, owner Date Uncertain", [r for r in not_in if r["class"] == "year+DU"])
for cls_ in ("year+month", "year", "year+DU"):
    rs = [r for r in not_in if r["class"] == cls_]
    print(f"\n  class {cls_}: {len(rs)} not-in-text; strict enclosure-consistent {sum(r['prev_dated_same_year'] for r in rs)}, "
          f"loose {sum(r['any3_dated_same_year'] for r in rs)}, prev cue {sum(r['prev_cue'] for r in rs)}")

# --- extension: distance to the nearest dated same-year document anywhere in the folder
def nearest_same_year(r):
    info = found[r["id"]]; k = info["k"]; y = r["truth"]["year"]
    best = None
    for jj, s in enumerate(info["segs"]):
        if jj == k or s["kind"] != "doc":
            continue
        t = info["truths"][jj][1]
        if t and t.get("year") == y and own_year_in_text(jj, info):
            d = abs(jj - k)
            best = d if best is None or d < best else best
    return best

print("\n== nearest dated same-year document in the folder, for the 131 not-in-text")
hist = collections.Counter()
for r in not_in:
    d = nearest_same_year(r)
    hist["adjacent (1)" if d == 1 else "2-3" if d is not None and d <= 3 else "4-10" if d is not None and d <= 10 else ">10" if d is not None else "none in folder"] += 1
for k_ in ("adjacent (1)", "2-3", "4-10", ">10", "none in folder"):
    print(f"  {k_}: {hist[k_]}")
rest = [r for r in not_in if not r["any3_dated_same_year"]]
print(f"  of the {len(rest)} with none within 3: none anywhere in folder = {sum(nearest_same_year(r) is None for r in rest)}")
# folder spread: how many distinct owner years among dated documents of the folder
print("\n== folder year spread for the 131 (distinct owner years among the folder's documents with a year tag)")
sp = collections.Counter()
for r in not_in:
    info = found[r["id"]]
    ys = {t[1]["year"] for t in info["truths"] if t and t[1] and "year" in t[1]}
    sp["1 year" if len(ys) <= 1 else "2 years" if len(ys) == 2 else "3-5 years" if len(ys) <= 5 else ">5 years"] += 1
for k_ in ("1 year", "2 years", "3-5 years", ">5 years"):
    print(f"  {k_}: {sp[k_]}")
report("NOT in text, folder has a single owner year", [r for r in not_in if len({t[1]['year'] for t in found[r['id']]['truths'] if t and t[1] and 'year' in t[1]}) <= 1])
report("NOT in text, folder has 3+ owner years", [r for r in not_in if len({t[1]['year'] for t in found[r['id']]['truths'] if t and t[1] and 'year' in t[1]}) >= 3])
