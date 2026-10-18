#!/usr/bin/env python3
"""W41.date-model: a dated public set, from documents outside the owner's corpus, to train and test dating on.

The owner's tags rarely carry a day, so the day is learned and judged here. Source: the Library of Congress's By the
People transcriptions (the comprehensive data package, 2026395156_csv.zip on tile.loc.gov, fetched through
corpus/fetch.sh's host list, read-only, once). Each LoC item is one catalogue record; its title is the catalogue's
own heading and, for document-level items such as the Lincoln Papers letters, ends in the item's date ("John Hay to
Abraham Lincoln, Monday, May 20, 1861"). That date is the truth. Items whose title gives no single date (a folder,
a range, "undated", two years) are left out. CIA CREST is not used: cia.gov is not on the fetch host list, and
W43.seg-corpus-build, which would add it, waits on its own gates.

    python3 public_dates.py build            # -> cache public.jsonl + public-summary.json (no model call)
    python3 public_dates.py train-data       # cache train/public-{train,val}.jsonl, the test kept out
    python3 public_dates.py mix [--public-max N]   # cache train/mixed/: corpus + public rows for train_seg.py
    python3 public_dates.py export --out DIR # the test prompts as requests.jsonl, for farmshare/fs_text.py
    python3 public_dates.py import --answers FILE --label L
    python3 public_dates.py score --label L  # year, month and day apart -> segbench-results/date-tagging-public.json

DOCUMENTS. An item is one document: its completed assets' transcriptions in asset order, joined by a blank line as
DocumentSegment.combinedText joins pages, cleaned as corpus/src_btp.truth cleans them. An item with any page not
completed is left out (its text would be partial). The prompt is the app's own (date_tagging.build_prompt), with the
three items before and after it in the same project, in item-id order, as context at 300 characters each.

ONE DOCUMENT. An item of more than MAX_PAGES pages, or whose title calls it correspondence, a diary, a journal,
clippings or the like, is a folder rather than a document and is left out.

TRUTH. year, month where the title gives one, day where it gives one. A date in square brackets or with "ca."/"?"
is one the cataloguer supplied, not the document: it is kept with `supplied` set and its target's date_uncertain
true (the prompt's rule: the year cannot be determined from the document itself). Everything else is certain.

SPLIT. Whole projects (a campaign's series or volume), by a hash of the project name: about 15% test, 10% val, the
rest train, so no test document shares a project with a training one. The test is up to 300 documents, round-robin
across test projects within each precision (day, month, year), seed 41.
"""
import argparse
import collections
import csv
import hashlib
import io
import json
import os
import random
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "corpus"))
import common  # noqa: E402  (corpus/common.py: the bench-corpus cache)
import src_btp  # noqa: E402
import date_tagging as D  # noqa: E402

PACKAGE = "https://tile.loc.gov/storage-services/master/gdc/gdcdatasets/2026395156/2026395156_csv.zip"
PACKAGE_DEST = "raw/btp/2026395156_csv.zip"
CACHE = os.path.join(D.CACHE, "public")
RESULTS_JSON = os.path.join(HERE, "..", "..", "segbench-results", "date-tagging-public.json")
SEED = 41
TEST_N = 300
PER_PRECISION = {"day": 150, "month": 90, "year": 60}

MONTHS = {m.lower()[:3]: k + 1 for k, m in enumerate(D.MONTH_NAMES)}
MON = r"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?"
YEAR = r"(1[5-9]\d\d|20[0-2]\d)"
WEEKDAY = r"(?:(?:Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day,?\s+)?"
DAYN = r"(\d{1,2})(?:st|nd|rd|th)?"
# Most specific first. Each gives (year, month, day) group names.
PATTERNS = [
    (re.compile(rf"\b{WEEKDAY}{MON}\s+{DAYN},?\s+{YEAR}\b", re.I), ("y", 3, 1, 2)),     # Monday, May 20, 1861
    (re.compile(rf"\b{DAYN}\s+{MON},?\s+{YEAR}\b", re.I), ("y", 3, 2, 1)),               # 20 May 1861
    (re.compile(rf"\b{YEAR},?\s+{DAYN}\s+{MON}(?!\w)", re.I), ("y", 1, 3, 2)),           # 1902, 24 Feb.
    (re.compile(rf"\b{YEAR}[,;]?\s+{MON}\s+{DAYN}\b", re.I), ("y", 1, 2, 3)),            # 1853; Apr. 17
    (re.compile(rf"\b{MON},?\s+{YEAR}\b", re.I), ("m", 2, 1, None)),                     # May 1861
    (re.compile(rf"\b{YEAR},?\s+{MON}(?!\w)", re.I), ("m", 1, 2, None)),                 # 1861, May
    (re.compile(rf"\b{YEAR}\b"), ("Y", 1, None, None)),                                  # 1861
]
RANGE = re.compile(rf"{YEAR}\s*[-–/]\s*(\d{{2,4}})?|\b{MON}\s*[-–]\s*{MON}|\bundated\b|\bn\.d\.|\bbetween\b", re.I)
# A catalogue item is not always one document: some are a folder (a correspondent's letters for a year, a diary
# volume, an events file). Those are left out by length and by the title's own words.
MAX_PAGES = 6
FOLDER = re.compile(r"^correspondence\b|\bdiar(y|ies)\b|\bdaybooks?\b|\bscrapbooks?\b|\bjournals?\b|\bnotebooks?\b"
                    r"|\bevents\b|\bclippings\b|\bmiscellan", re.I)
SUPPLIED = re.compile(r"\[[^\]]*\d{4}[^\]]*\]|\b(ca|circa|c)\.\s*\d{4}|\d{4}\s*\?|\?\s*\]", re.I)


def tail_of(title):
    """The item's own part of a catalogue title: after the last ';' or, failing that, the last ':' (the series
    and collection headings before it carry their own year ranges). A last ';' part with no year takes the part
    before it too ("…; 1853; Apr. 17 , Maine Law")."""
    t = title.strip()
    if ";" in t:
        parts = t.split(";")
        tail = parts[-1].strip()
        if not re.search(rf"\b{YEAR}\b", tail) and len(parts) > 2:
            tail = parts[-2].strip() + "; " + tail
        return tail
    return t.rsplit(":", 1)[1].strip() if ":" in t else t


def date_of(title):
    """(truth dict or None, reason). truth = {year, month|None, day|None, supplied}."""
    t = tail_of(title)
    if RANGE.search(t):
        return None, "range or undated"
    years = set(re.findall(rf"\b{YEAR}\b", t))
    if len(years) != 1:
        return None, "no year" if not years else "two years"
    for rx, (kind, gy, gm, gd) in PATTERNS:
        ms = list(rx.finditer(t))
        if not ms:
            continue
        if len({m.group(0) for m in ms}) > 1:
            return None, "two dates"
        m = ms[0]
        year = int(m.group(gy))
        month = MONTHS.get(m.group(gm).lower()[:3]) if gm else None
        day = int(m.group(gd)) if gd else None
        if day is not None and not 1 <= day <= 31:
            return None, "bad day"
        return {"year": year, "month": month, "day": day, "supplied": bool(SUPPLIED.search(t))}, kind
    return None, "no year"


def precision(truth):
    return "day" if truth["day"] else ("month" if truth["month"] else "year")


def target_of(truth):
    """The app's JSON reply with the catalogue's date: year, month, day, date_uncertain (supplied dates)."""
    m, d = truth["month"], truth["day"]
    return json.dumps({"year": str(truth["year"]), "month": f"{m:02d} {D.MONTH_NAMES[m - 1]}" if m else None,
                       "day": f"Day {d}" if d else None, "date_uncertain": truth["supplied"]}, ensure_ascii=False)


def split_of(project):
    h = int(hashlib.sha1(project.encode()).hexdigest()[:8], 16) % 100
    return "test" if h < 15 else ("val" if h < 25 else "train")


# --- build -------------------------------------------------------------------------------------

def package_rows():
    z = common.download(PACKAGE, PACKAGE_DEST)
    seen = set()
    with zipfile.ZipFile(z) as zf:
        for name in sorted(zf.namelist()):
            if not name.lower().endswith(".csv"):
                continue
            with zf.open(name) as fh:
                for r in csv.DictReader(io.TextIOWrapper(fh, encoding="utf-8-sig", newline="")):
                    a = r.get("Asset") or r.get("AssetId")
                    if a and a not in seen:
                        seen.add(a)
                        yield r


def asset_order(r):
    """Assets of an item sort by their trailing page number (…-0003), else by name."""
    a = r.get("Asset") or ""
    m = re.search(r"(\d+)\D*$", a)
    return (int(m.group(1)) if m else 0, a)


def cmd_build(a):
    csv.field_size_limit(1 << 30)
    items = collections.OrderedDict()
    for r in package_rows():
        items.setdefault(r["ItemId"], []).append(r)
    counts = collections.Counter()
    by_project = collections.defaultdict(list)
    for iid, rs in items.items():
        counts["items"] += 1
        rs.sort(key=asset_order)
        title = rs[0].get("Item") or ""
        project = f"{rs[0].get('Campaign', '')}/{rs[0].get('Project', '')}"
        complete = all(r.get("AssetStatus", "").lower() == "completed" for r in rs)
        text = "\n\n".join(src_btp.truth(r.get("Transcription") or "") for r in rs if
                           (r.get("Transcription") or "").strip().lower().strip(" .") != "nothing to transcribe").strip()
        truth, why = date_of(title)
        by_project[project].append({"id": iid, "title": title, "text": text if complete else "", "truth": truth,
                                    "complete": complete, "pages": len(rs), "why": why,
                                    "campaign": rs[0].get("Campaign", ""), "project": project})
    docs = []
    for project, its in by_project.items():
        its.sort(key=lambda d: d["id"])
        texts = [d["text"] for d in its]
        for k, d in enumerate(its):
            if not d["complete"]:
                counts["not completed"] += 1; continue
            if not d["text"]:
                counts["no text"] += 1; continue
            if d["truth"] is None:
                counts[f"no date: {d['why']}"] += 1; continue
            if d["pages"] > MAX_PAGES or FOLDER.search(tail_of(d["title"])):
                counts["dated, but a folder"] += 1; continue
            near = (texts[max(0, k - 3):k] + texts[k + 1:k + 4])[:3]
            context = "\n---\n".join(t[:300] for t in near if t)
            y = str(d["truth"]["year"])
            prec = precision(d["truth"])
            counts[f"dated {prec}"] += 1
            counts["dated supplied"] += d["truth"]["supplied"]
            docs.append({"id": d["id"], "source": "loc-btp", "item_url": f"https://www.loc.gov/item/{d['id']}/",
                         "title": d["title"], "campaign": d["campaign"], "collection": project,
                         "split": split_of(project), "precision": prec, "truth": d["truth"], "pages": d["pages"],
                         "year_in_text": y in d["text"][:3000],
                         "prompt": D.build_prompt(d["text"], context)})
    os.makedirs(CACHE, exist_ok=True)
    rng = random.Random(SEED)
    test = []
    for prec, want in PER_PRECISION.items():
        by_col = collections.defaultdict(list)
        for d in docs:
            if d["split"] == "test" and d["precision"] == prec:
                by_col[d["collection"]].append(d)
        cols = sorted(by_col)
        rng.shuffle(cols)
        for c in cols:
            rng.shuffle(by_col[c])
        got = []
        while len(got) < want and any(by_col[c] for c in cols):
            for c in cols:
                if by_col[c] and len(got) < want:
                    got.append(by_col[c].pop())
        test += got
    test_ids = {d["id"] for d in test}
    for d in docs:
        d["test"] = d["id"] in test_ids
    write_jsonl(os.path.join(CACHE, "public.jsonl"), docs)
    summary = {"counts": dict(sorted(counts.items())),
               "splits": {s: {"documents": sum(d["split"] == s for d in docs),
                              "projects": len({d["collection"] for d in docs if d["split"] == s}),
                              "precision": dict(collections.Counter(d["precision"] for d in docs if d["split"] == s))}
                          for s in ("train", "val", "test")},
               "test_sample": {"documents": len(test), "projects": len({d["collection"] for d in test}),
                               "precision": dict(collections.Counter(d["precision"] for d in test)),
                               "supplied": sum(d["truth"]["supplied"] for d in test),
                               "year_in_text": sum(d["year_in_text"] for d in test)},
               "campaigns": dict(collections.Counter(d["campaign"] for d in docs).most_common())}
    json.dump(summary, open(os.path.join(CACHE, "public-summary.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in summary.items() if k != "campaigns"}, indent=1))


def write_jsonl(path, rows):
    with open(path + ".tmp", "w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    os.replace(path + ".tmp", path)


def load():
    return [json.loads(l) for l in open(os.path.join(CACHE, "public.jsonl"), encoding="utf-8")]


def cmd_train_data(a):
    """Train and val rows in date_tagging train-data's shape; the test projects are left out whole."""
    out = a.out or os.path.join(D.CACHE, "train")
    os.makedirs(out, exist_ok=True)
    for split in ("train", "val"):
        rs = [{"id": d["id"], "collection": d["collection"], "class": "public " + d["precision"],
               "year_in_text": d["year_in_text"], "prompt": d["prompt"], "target": target_of(d["truth"])}
              for d in load() if d["split"] == split]
        random.Random(SEED).shuffle(rs)
        write_jsonl(os.path.join(out, f"public-{split}.jsonl"), rs)
        print(split, len(rs))


def without_day(target):
    """A corpus target with its "day" key taken out. The owner's tags carry no day, so a corpus target's null day
    would teach "no day" for documents that state one; with the key absent the reply's day is not trained on
    there, and parseTagResponse reads a missing day as none."""
    j = json.loads(target)
    j.pop("day", None)
    return json.dumps(j, ensure_ascii=False)


def cmd_mix(a):
    """train_seg.py's text set: date_tagging train-data's corpus rows (day key removed) and public rows, the public
    ones capped at the corpus count by default so the owner's tags stay at least half of what is learned."""
    src = os.path.join(D.CACHE, "train")
    out = os.path.join(src, "mixed")
    os.makedirs(out, exist_ok=True)
    summary = {}
    for split in ("train", "val"):
        corpus = [json.loads(l) for l in open(os.path.join(src, f"{split}.jsonl"), encoding="utf-8")]
        public = [json.loads(l) for l in open(os.path.join(src, f"public-{split}.jsonl"), encoding="utf-8")]
        cap = len(corpus) if a.public_max is None else a.public_max
        rows = [{**r, "target": without_day(r["target"]), "source": "corpus"} for r in corpus]
        rows += [{**r, "source": "public"} for r in public[:cap]]
        random.Random(SEED).shuffle(rows)
        write_jsonl(os.path.join(out, f"{split}.jsonl"), rows)
        summary[split] = {"corpus": len(corpus), "public": min(cap, len(public)), "public_available": len(public)}
    json.dump({"rows": summary, "text_only": True}, open(os.path.join(out, "data.json"), "w"), indent=1)
    print(json.dumps(summary, indent=1))


def cmd_export(a):
    test = [d for d in load() if d["test"]]
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "requests.jsonl"), "w", encoding="utf-8") as f:
        for d in test:
            f.write(json.dumps({"id": D.prompt_id(d["prompt"]), "prompt": d["prompt"]}, ensure_ascii=False) + "\n")
    print(f"{len(test)} prompts -> {a.out}/requests.jsonl")


def answer_path(prompt, label):
    return os.path.join(CACHE, "answers-" + label, D.prompt_id(prompt) + ".json")


def cmd_import(a):
    d = os.path.join(CACHE, "answers-" + a.label)
    os.makedirs(d, exist_ok=True)
    n = 0
    for line in open(a.answers, encoding="utf-8"):
        r = json.loads(line)
        if "raw" in r:
            json.dump({"candidates": [{"content": {"parts": [{"text": D.strip_reasoning(r["raw"])}]}}],
                       "finish": r.get("finish")}, open(os.path.join(d, r["id"] + ".json"), "w"))
            n += 1
    print(f"{n} answers -> {d}")


# --- score -------------------------------------------------------------------------------------

def reply_day(resp):
    """TagGenerator's day: GeneratedTags.dayNumber of the reply's "day" ("Day 15", "15", 15)."""
    try:
        s = "".join(p.get("text", "") for p in resp["candidates"][0]["content"]["parts"])
        js = json.loads(s[s.find("{"):s.rfind("}") + 1])
    except (KeyError, IndexError, TypeError, ValueError):
        return None
    v = js.get("day") if isinstance(js, dict) else None
    if isinstance(v, bool) or v is None:
        return None
    m = re.search(r"\d{1,2}", str(v))
    return int(m.group(0)) if m and 1 <= int(m.group(0)) <= 31 else None


def score_rows(rows):
    def frac(rs, f):
        return [sum(1 for r in rs if f(r)), len(rs)]
    mo = [r for r in rows if r["truth"]["month"]]
    dy = [r for r in rows if r["truth"]["day"]]
    year_ok = lambda r: r["y"] == r["truth"]["year"]
    return {"documents": len(rows),
            "year": {"exact": frac(rows, year_ok),
                     "within1": frac(rows, lambda r: r["y"] is not None and abs(r["y"] - r["truth"]["year"]) <= 1),
                     "in text": frac([r for r in rows if r["year_in_text"]], year_ok),
                     "not in text": frac([r for r in rows if not r["year_in_text"]], year_ok)},
            "month": {"exact": frac(mo, lambda r: r["m"] == r["truth"]["month"]),
                      "none": frac(mo, lambda r: r["m"] is None),
                      "given_where_source_has_none": frac([r for r in rows if not r["truth"]["month"]],
                                                          lambda r: r["m"] is not None)},
            "day": {"exact": frac(dy, lambda r: r["d"] == r["truth"]["day"]),
                    "full_date": frac(dy, lambda r: year_ok(r) and r["m"] == r["truth"]["month"] and r["d"] == r["truth"]["day"]),
                    "none": frac(dy, lambda r: r["d"] is None),
                    "given_where_source_has_none": frac([r for r in rows if not r["truth"]["day"]],
                                                        lambda r: r["d"] is not None)},
            "parse_failures": sum(not r["parsed"] for r in rows)}


def cmd_score(a):
    rows = []
    for d in load():
        if not d["test"]:
            continue
        p = answer_path(d["prompt"], a.label)
        if not os.path.exists(p):
            continue
        resp = json.load(open(p))
        year, month, _, ok = D.app_parse(resp)
        rows.append({**d, "y": int(year) if year and re.fullmatch(r"\d{4}", year) else None,
                     "m": month if isinstance(month, int) else None, "d": reply_day(resp), "parsed": ok})
    j = json.load(open(RESULTS_JSON)) if os.path.exists(RESULTS_JSON) else {}
    j.setdefault("models", {})[a.label] = score_rows(rows)
    with open(RESULTS_JSON, "w", encoding="utf-8") as fh:
        json.dump(j, fh, indent=1)
        fh.write("\n")
    print(json.dumps(j["models"][a.label], indent=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("build")
    p = sub.add_parser("train-data"); p.add_argument("--out")
    p = sub.add_parser("mix"); p.add_argument("--public-max", type=int)
    p = sub.add_parser("export"); p.add_argument("--out", required=True)
    p = sub.add_parser("import"); p.add_argument("--answers", required=True); p.add_argument("--label", required=True)
    p = sub.add_parser("score"); p.add_argument("--label", required=True)
    a = ap.parse_args()
    {"build": cmd_build, "train-data": cmd_train_data, "mix": cmd_mix, "export": cmd_export, "import": cmd_import,
     "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
