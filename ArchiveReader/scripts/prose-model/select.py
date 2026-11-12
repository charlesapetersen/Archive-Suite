#!/usr/bin/env python3
"""W40.reader-prose-model: choose the 40 pages by geometry alone, never by either method's labels.

Reads `rules-all.jsonl` (prosebench rules over the whole sample) for each page's rows and boxes and its `geometry`
flag: the PDF's line boxes hold the page text word for word, which both methods need. The rules' labels are not read.
  typed:      8-70 rows (70 keeps a page inside the model's 8,192 tokens), 80+ words, median 5+ words a row, and
              even row heights (interquartile range under 35% of the median), as typewriting and print have;
  structured: two or more indents past the margin, each shared by 2+ rows (lists and sub-lists), or a narrow row
              (under 60% of the text width) set off by a gap above and below (a heading).
Writes `selection.txt` (40 ids, seed 4011) and prints the pool sizes.
usage: select.py CACHE_DIR
"""
import json
import random
import statistics
import sys

d = sys.argv[1]


def pct(xs, p):
    s = sorted(xs)
    return s[round((len(s) - 1) * p)]


def typed(rows):
    words = [len(r["t"].split()) for r in rows]
    hs = [r["h"] for r in rows]
    med = statistics.median(hs)
    return (8 <= len(rows) <= 70 and sum(words) >= 80 and statistics.median(words) >= 5 and med > 0
            and (pct(hs, 0.75) - pct(hs, 0.25)) < 0.35 * med)


def structured(rows):
    em = statistics.median(r["h"] for r in rows)
    left = pct([r["x"] for r in rows], 0.25)
    right = pct([r["x"] + r["w"] for r in rows], 0.8)
    width = max(right - left, em)
    indents = sorted(round((r["x"] - left) / em) for r in rows if r["x"] - left > 1.5 * em)
    clusters = {}
    for i in indents:   # indents within one line height of each other are one indent
        key = next((k for k in clusters if abs(k - i) <= 1), i)
        clusters[key] = clusters.get(key, 0) + 1
    if sum(1 for c in clusters.values() if c >= 2) >= 2:
        return True
    mids = [r["y"] + r["h"] / 2 for r in rows]
    gaps = [a - b for a, b in zip(mids, mids[1:])]
    usual = statistics.median(gaps) if gaps else 0
    if usual <= 0:
        return False
    for j in range(1, len(rows) - 1):
        if rows[j]["w"] / width < 0.6 and gaps[j - 1] > 1.6 * usual and gaps[j] > 1.6 * usual:
            return True
    return False


pages = [json.loads(x) for x in open(f"{d}/rules-all.jsonl", encoding="utf-8")]
geo = [p for p in pages if p["geometry"]]
ty = [p for p in geo if typed(p["rows"])]
pool = [p["id"] for p in ty if structured(p["rows"])]
pick = sorted(random.Random(4011).sample(sorted(pool), 40))
open(f"{d}/selection.txt", "w", encoding="utf-8").write("\n".join(pick) + "\n")
print(f"pages {len(pages)}, geometry path {len(geo)}, typed {len(ty)}, structured {len(pool)}, chosen {len(pick)}")
