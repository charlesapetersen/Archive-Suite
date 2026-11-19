#!/usr/bin/env python3
"""W47.ct-folder-date: does a dated folder photo date the undated documents inside it? Measured, $0.

The owner, on the page-date sheet (2026-10-31, D06, D14, D18): "A date is given, so all the documents inside can be
assumed to come from this date if otherwise undated." Before the rule goes into the run inheritance this counts, on the
labelled folders (corpus_pairs' labels, as W46.date-undated drew its 425 agreed undated documents):

- the folder photos (Purple) whose run holds an undated document, and how many carry a date Vision + parser reads;
- the undated documents in a folder run, and in a dated one: what the rule would date;
- how often the folder's date holds where a document in its run has a year of its own: the owner's year tag on the
  dated documents of the same runs (the main check, owner truth), and for the undated ones the year the page gives,
  from W46.date-undated's image pass and the owner's sheet rulings where the document was sampled.

The folder run is SPEC/containers.md's: a Purple photo starts it, it covers the files after it in the directory until
the next Purple or a Red (a new box ends the folder run). The date is ct_read.vision_read's `date` on the photo's
cached Vision lines (ct_read corpus-lines, the first turn that reads one), parsed to a year range. Vision + parser is
the $0 route; the design reads the date with GPT 5.6 Luna (else Gemma 3 12B), which scored higher on label dates
(ct-read.md), so the counts of dated folders here are a floor. No ABBYY text (owner, 2026-10-30), no call, no upload.

    python3 folder_date.py     # segbench-results/folder-date.md and .json

READ ONLY on the corpus (tags read with corpus_survey.read_tags). Run from scripts/segbench.
"""
import collections
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import corpus_pairs as CP
import corpus_survey as CS
import ct_read as CR
import date_tagging as DT

UNDATED = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/date-undated")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "folder-date.md")
YEARS = range(1900, 2030)   # the corpus's span, generously; a read outside it ("1684") is a misread
TURNS = (0, 90, 270, 180)


def parse_range(s):
    """A label date -> (lo, hi) years, or None. "1965-1967", "1966-70", "1939- 78", "1960s", "6/2/61", "1953".
    "1958-02" (an end before the start) is read as the start year alone: a month or a misread, not a range."""
    s = s.strip()
    m = re.match(r"^(\d{4})\s*[-–—]\s*(\d{4}|\d\d)$", s)
    if m:
        lo, end = int(m.group(1)), m.group(2)
        hi = int(end) if len(end) == 4 else lo // 100 * 100 + int(end)
        if len(end) == 2 and hi < lo:
            hi = lo
        return (lo, hi) if lo in YEARS and hi in YEARS and hi >= lo else None
    m = re.match(r"^(\d{4})s$", s)
    if m:
        lo = int(m.group(1))
        return (lo, lo + 9) if lo in YEARS else None
    m = re.match(r"^\d{1,2}/\d{1,2}/(\d{2}|\d{4})$", s)
    if m:
        y = int(m.group(1))
        y = y if y > 99 else 1900 + y
        return (y, y) if y in YEARS else None
    m = re.match(r"^(\d{4})$", s)
    if m and int(s) in YEARS:
        return int(s), int(s)
    return None


def folder_date(path, inv):
    """(the raw read, (lo, hi) or None, the turn) for a folder photo, from its cached Vision lines."""
    m = inv.get(path)
    if not m:
        return None, None, None
    for t in TURNS:
        lines = CR.corpus_lines(CR.corpus_key(m["id"], t))
        if lines is None:
            continue
        got = CR.vision_read(lines, m["colour"])["date"]
        if got:
            return got, parse_range(got), t
    return None, None, None


def sampled():
    """W46.date-undated's undated documents: id -> the image pass's own year (or None), and the owner's rulings."""
    import date_undated as DU
    own = {}
    for d in DU.targets():
        if d["set"] != "undated":
            continue
        rec = DU.image_dest(d)
        if os.path.exists(rec):
            ok, y, _ = DU.own_date(json.load(open(rec, encoding="utf-8")))
            own[d["id"]] = y if ok else "unread"
    rulings = {}
    rp = os.path.join(UNDATED, "sheet", "rulings.json")
    if os.path.exists(rp):
        for k, x in json.load(open(rp, encoding="utf-8"))["documents"].items():
            rulings[x["id"]] = {**x["owner"], "sheet": k, "note": (x.get("answer") or {}).get("note", "")}
    return own, rulings


def within(y, r, slack=0):
    return r[0] - slack <= y <= r[1] + slack


def label_truth():
    """W47.ct-truth-final's owner-checked label dates: photo path -> the truth date (None where the label has none),
    for the Purple photos whose date cell is in the truth (not cut off, illegible or unanswered)."""
    out = {}
    for line in open(CR.TRUTH, encoding="utf-8"):
        r = json.loads(line)
        if r["colour"] != "Purple" or r["id"] in CR.LEFT_OUT or r.get("illegible_photo"):
            continue
        if any("date" in r.get(k, []) for k in ("cut_off", "illegible", "unanswered", "open", "unsure")):
            continue
        out[r["path"]] = r["fields"].get("date")
    return out


def check(runs, date_of):
    """The owner's year tags in the runs of the photos date_of dates, against the folder's range."""
    rows = []
    for p, run in runs.items():
        rng = date_of(p)
        if rng:
            rows += [{"photo": p, "year": y, "range": rng} for y in run["years"]]
    single = [x for x in rows if x["range"][0] == x["range"][1]]
    span = [x for x in rows if x["range"][0] != x["range"][1]]
    by_photo = collections.defaultdict(list)
    for x in rows:
        by_photo[x["photo"]].append(within(x["year"], x["range"]))
    def share(xs, slack=0):
        return [len(xs), sum(within(x["year"], x["range"], slack) for x in xs)]
    return {"documents": share(rows), "within_1": share(rows, 1), "single_year": share(single),
            "single_year_within_1": share(single, 1), "range": share(span),
            "folders": len(by_photo), "folders_all": sum(all(v) for v in by_photo.values()),
            "folders_none": sum(not any(v) for v in by_photo.values()),
            "undated_dated": sum(len(runs[p]["undated"]) for p in runs if date_of(p))}


def main():
    lab = {}
    for line in open(os.path.join(CP.CACHE, "labels.jsonl"), encoding="utf-8"):
        g = json.loads(line)
        lab[(g["folder_id"], g["n"])] = g
    folders = sorted({os.path.dirname(g["left"]) for g in lab.values()})
    inv = {m["path"]: m for d in CR.inventory() for m in d["markers"]}
    own, rulings = sampled()
    c = collections.Counter()
    runs = {}              # folder photo -> its run's owner years, decades and undated document ids
    for f in folders:
        cur = None
        for s in DT.folder_documents(f, lab):
            if s["kind"] == "Box":
                cur = None
                continue
            if s["kind"] == "Folder":
                cur = s["pages"][0]
                runs.setdefault(cur, {"years": [], "decades": [], "undated": []})
                continue
            if not s["agreed"]:
                continue
            cls, truth = DT.truth_of(CS.read_tags(os.path.join(CS.CORPUS, s["pages"][0])))
            if cls == "undated":
                c["undated agreed"] += 1
                c["undated, in a folder run" if cur else "undated, no folder run"] += 1
            if not cur:
                continue
            if cls == "undated":
                runs[cur]["undated"].append(hashlib.sha1(s["pages"][0].encode()).hexdigest()[:16])
            elif truth and "year" in truth:
                runs[cur]["years"].append(truth["year"])
            elif truth and "decade" in truth:
                runs[cur]["decades"].append(truth["decade"])
    vision = {p: folder_date(p, inv) for p in runs}
    truth = label_truth()
    over = [p for p in runs if runs[p]["undated"]]
    c["folder photos in the labelled folders"] = len(runs)
    c["  a year or range read by Vision + parser"] = sum(1 for p in runs if vision[p][1])
    c["folder photos over an undated document"] = len(over)
    c["  a date read by Vision + parser"] = sum(1 for p in over if vision[p][0])
    c["  of which a year or range"] = sum(1 for p in over if vision[p][1])
    c["undated, in a dated folder run (Vision + parser)"] = sum(len(runs[p]["undated"]) for p in over if vision[p][1])
    vis = check(runs, lambda p: vision[p][1])
    in_truth = {p for p in runs if p in truth}
    tru = check({p: runs[p] for p in in_truth}, lambda p: parse_range(truth[p]) if truth[p] else None)
    vis_t = check({p: runs[p] for p in in_truth}, lambda p: vision[p][1])
    dec = [(d, vision[p][1]) for p in runs if vision[p][1] for d in runs[p]["decades"]]

    # The undated documents' own page years, where W46.date-undated sampled them.
    und = [(i, vision[p][1]) for p in over if vision[p][1] for i in runs[p]["undated"]]
    samp = [(i, r) for i, r in und if i in own]
    pass_year = [(own[i], r) for i, r in samp if isinstance(own[i], int)]
    ruled = {rulings[i]["sheet"]: [rulings[i]["lo"], rulings[i]["hi"], list(r)] for i, r in und
             if i in rulings and rulings[i]["own"]}
    widths = collections.Counter("one year" if r[0] == r[1] else ("ten years or less" if r[1] - r[0] <= 9 else
                                 "over ten years") for p in over for r in [vision[p][1]] if r)
    out = {
        "item": "W47.ct-folder-date", "counts": dict(c),
        "vision_check": vis, "truth_photos": {"in_runs": len(in_truth), "dated": sum(1 for p in in_truth if truth[p])},
        "truth_check": tru, "vision_on_truth_photos": vis_t,
        "decade_check": [len(dec), sum(r[0] <= d + 9 and d <= r[1] for d, r in dec)],
        "undated_page_years": {"in_dated_runs": len(und), "sampled": len(samp), "pass_year": len(pass_year),
                               "pass_within": sum(within(y, r) for y, r in pass_year),
                               "pass_within_1": sum(within(y, r, 1) for y, r in pass_year), "owner_ruled": ruled},
        "range_widths": dict(widths),
        "sheet_folder_photos": sorted(x["sheet"] for x in rulings.values() if "folder" in x["note"].lower()),
    }
    with open(RESULTS.replace(".md", ".json"), "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    print(json.dumps(out, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
